#!/usr/bin/env python3
"""The review queue: what waits on the code reviewer and the test reviewer, in order. A developer or tester adds a
request in a fixed short form instead of asking the delivery lead to pass it on; the reviewer takes the next one and
closes it with a verdict. A clean verdict goes straight to whoever is next and wakes no lead (pr-gate shows the
approval); a verdict with a finding, a cut or a question goes to the delivery lead, who decides and passes it on, as
before. The team page's Work pane draws it.

  team/review-queue.py add code KEY --pr URL --head SHA --changed "words" --read-for "words" [--owner "words"]
                                       (developer or tester, for the code reviewer: a pull request at its head)
  team/review-queue.py add test KEY --head SHA --files "plan, specs, worktree" --changed "words" --read-for "words"
                       [--pr URL] [--owner "words"]   (tester, for the test reviewer: the plan and tests at that head)
                                       (a new request goes at the end; a new head is a new request)
  team/review-queue.py take code|test          (the reviewer: the request it has in hand, else the first waiting, not held)
  team/review-queue.py close ID --clean "words"      (the reviewer: approved or cleared, nothing to decide)
  team/review-queue.py close ID --findings "words"   (the reviewer: a finding, a cut or a question, for the delivery lead)
  team/review-queue.py up ID | down ID | hold ID | release ID    (the delivery lead: order among the waiting; held is skipped)
  team/review-queue.py passed ID               (the delivery lead: a findings verdict decided and passed on)
  team/review-queue.py drop ID [--taken]      (the requester or the delivery lead: no longer wanted; a request a
                                              reviewer has taken needs --taken, and the reviewer is told to stop)
  team/review-queue.py list [code|test]

Who is next after a clean verdict: after the code reviewer's, the delivery lead to arm it when a tester has signed the
ticket off at the request's head (`scripts/ledger-db.sh verdicts KEY`), else a tester (or the head of testing) holding
the ticket in the ledger (`scripts/ledger-db.sh agent-tickets`), else the delivery lead, to route one; after the test
reviewer's, whoever asked. Every wake is a notice in the file,
which the waiting-agents mod delivers once, as a queued prompt, in the session it names; it also reminds a reviewer
that sits idle with requests waiting.

The queue is $AGENT_REVIEW_QUEUE, else ~/.local/state/<project>/review-queue.json, the project being the main checkout
of the directory it is run in (project_root), whichever worktree or path it is run from:
  {"items": [item, ...], "notices": [{"id", "to", "text", "at"}, ...], "next": the next id, "at", "by"}
where an item is {"id", "kind": "code"|"test", "key", "pr", "head", "files", "changed", "read_for", "owner", "by", "added",
"state": "waiting"|"taken"|"lead"|"done", "held", "taken_by", "taken", "verdict": "clean"|"findings", "words", "closed"}.
A change is made under a lock and written whole, and a closed request is kept DONE_DAYS days. Who runs a command is
AGENT_NAME, else the name of the Claude session it runs in; the roles come from agents/roster.json ($ROSTER_FILE)."""
import fcntl
import functools
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import time

HOME = os.path.expanduser("~")


def main_checkout(path):
    """The main checkout of the git repository holding path, so every linked worktree of a project answers the same."""
    try:
        r = subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    common = r.stdout.strip()
    return os.path.dirname(common) if r.returncode == 0 and common.endswith("/.git") else None


def project_root():
    """$HARNESS_ROOT, else the main checkout of the directory it is run in, else of the script's own path, the first of
    those with a roster. A project's team/ is a symlink to the harness's, and each agent works in its own worktree, so
    neither the script's path nor the worktree names the project: run from any worktree of a project, or as the
    harness's own copy from inside one, it is that project's queue and roster."""
    if os.environ.get("HARNESS_ROOT"):
        return os.environ["HARNESS_ROOT"]
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for start in (os.getcwd(), here):
        root = main_checkout(start)
        if root and os.path.isfile(os.path.join(root, "agents/roster.json")):
            return root
    return main_checkout(here) or here


def env_file_value(root, name):
    """A NAME=value line from the project's harness.env, as the waiting-agents mod reads it."""
    try:
        for line in open(os.path.join(root, "harness.env")):
            m = re.match(r"\s*(?:export\s+)?" + name + r"=(.*)$", line)
            if m:
                return m.group(1).strip().strip("\"'") or None
    except OSError:
        pass
    return None


ROOT = project_root()
PROJECT = os.environ.get("HARNESS_PROJECT") or env_file_value(ROOT, "HARNESS_PROJECT") or os.path.basename(ROOT)
QUEUE = os.path.expanduser(os.environ.get("AGENT_REVIEW_QUEUE") or os.path.join(HOME, ".local/state", PROJECT, "review-queue.json"))
ROSTER = os.environ.get("ROSTER_FILE") or os.path.join(ROOT, "agents/roster.json")


def load_roster(path):
    """The roster at `path`, its people read from the file its `_people_file` names when it names one
    (strength keeps its people outside git, #7164; the rules and machines stay in the git file). A pointer
    to a file that cannot be read gives no people, never the git file's stale ones."""
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
    people = data.pop("_people_file", None) if isinstance(data, dict) else None
    if people:
        for k in ("agents", "humans", "assistants"):
            data.pop(k, None)
        try:
            with open(people, encoding="utf-8") as f:
                data.update(json.load(f))
        except (OSError, ValueError):
            data["agents"] = []
    return data
LEDGER_DB = os.environ.get("LEDGER_DB") or os.path.join(ROOT, "scripts/ledger-db.sh")
KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.#/-]{0,254}$")   # the ledger's id: a ticket's slug, or a key such as ABC-123
SHA = re.compile(r"^[0-9a-f]{7,40}$")
KINDS = {"code": "code-reviewer", "test": "test-reviewer"}
LEAD = "delivery-lead"
TESTERS = ("tester", "head-of-testing")
DONE_DAYS = 14
# The fixed form's limits: the request is the reviewer's whole brief, so it says what changed and what to read for,
# and the pull request says the rest.
LIMITS = {"changed": 400, "read_for": 400, "files": 400, "owner": 300, "words": 600}
NOTICE_DAYS = 1
TAG = "[review-queue, not the owner]"


def die(words):
    print(f"review-queue: {words}", file=sys.stderr)
    sys.exit(1)


@functools.lru_cache(maxsize=1)
def roster():
    """[(name, role id)] for the roster's active agents, in its order."""
    try:
        data = load_roster(ROSTER)
    except (OSError, ValueError):
        return []
    return [(a["name"], a.get("role", "")) for a in data.get("agents") or [] if a.get("status") == "active" and a.get("name")]


def said(role):
    """A role id as a sentence says it: "code-reviewer" -> "code reviewer"."""
    return role.replace("-", " ")


def role_of(name):
    return next((r for n, r in roster() if n == name), "")


def holder(role):
    """The first agent on the roster in that role ("" for none)."""
    return next((n for n, r in roster() if r == role), "")


def ledger(*args):
    """The ledger's output for `ledger-db.sh ARGS`, or None when it cannot be read (no such verb in this project's copy,
    or no ledger)."""
    try:
        out = subprocess.run(["bash", LEDGER_DB, *args], capture_output=True, text=True, timeout=30,
                             env={**os.environ, "HARNESS_PROJECT": PROJECT})
    except (OSError, subprocess.TimeoutExpired):
        return None
    return None if out.returncode else out.stdout


def holders(key):
    """Who holds ticket `key` in the ledger (`ledger-db.sh agent-tickets`: holder|id|status|park_kind rows); None when the
    ledger cannot say."""
    out = ledger("agent-tickets")
    if out is None:
        return None
    return [p[0] for p in (line.split("|") for line in out.splitlines()) if len(p) >= 2 and p[1] == key]


def signed_off(key, head):
    """The tester who signed ticket `key` off at `head`, from `ledger-db.sh verdicts KEY` ("sign-off SHA NAME (ROLE) ..."
    rows), else "". A project whose ledger has no verdicts verb has none."""
    for line in (ledger("verdicts", key) or "").splitlines():
        p = line.split()
        if len(p) >= 4 and p[0] == "sign-off" and SHA.match(p[1]) and (p[1].startswith(head) or head.startswith(p[1])) \
                and p[3].strip("()") in TESTERS:
            return p[2]
    return ""


def session_name():
    """The name of the Claude session this runs in: its ~/.claude/sessions/<pid>.json with this CLAUDE_CODE_SESSION_ID."""
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if sid:
        for f in glob.glob(os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude"), "sessions", "*.json")):
            try:
                with open(f) as fh:
                    s = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(s, dict) and s.get("sessionId") == sid and isinstance(s.get("name"), str):
                return s["name"].lstrip("/")
    return ""


def me():
    return os.environ.get("AGENT_NAME") or session_name()


def read():
    try:
        with open(QUEUE, encoding="utf-8") as f:
            q = json.load(f)
    except FileNotFoundError:
        return {"items": [], "notices": [], "next": 1}
    except ValueError:
        die(f"{QUEUE} is not JSON; fix or remove it")
    if not isinstance(q, dict) or not isinstance(q.get("items", []), list) or not isinstance(q.get("notices", []), list):
        die(f"{QUEUE} is not a review queue; fix or remove it")
    return {"next": 1, **q, "items": q.get("items", []), "notices": q.get("notices", [])}


def write(q, who):
    now = int(time.time())
    keep = DONE_DAYS * 86400
    q.update(at=now, by=who,
             items=[i for i in q["items"] if i.get("state") != "done" or now - i.get("closed", now) < keep],
             notices=[n for n in q["notices"] if now - n.get("at", now) < NOTICE_DAYS * 86400])
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(QUEUE), prefix=".review-queue.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(q, f, indent=1, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, QUEUE)


def notify(q, to, text):
    if to:
        q["notices"].append({"id": f"{int(time.time())}-{len(q['notices'])}-{to}", "to": to, "text": f"{TAG} {text}", "at": int(time.time())})


def find(q, ident):
    for item in q["items"]:
        if str(item.get("id")) == ident:
            return item
    die(f"no request {ident} in the queue ({QUEUE}, project {PROJECT}: run it from that project's checkout)")


def options(args, allowed):
    out, i = {}, 0
    while i < len(args):
        a = args[i]
        name = a[2:].replace("-", "_")
        if a.startswith("--") and name in allowed and i + 1 < len(args):
            out[name] = " ".join(args[i + 1].split())
            i += 2
        else:
            die(f"unexpected {a!r}")
    for k, v in out.items():
        if len(v) > LIMITS.get(k, 10_000):
            die(f"--{k.replace('_', '-')} is {len(v)} characters; keep it to {LIMITS[k]}: the pull request says the rest")
    return out


def brief(i):
    """The request as the reviewer reads it."""
    lines = [f"#{i['id']} {i['key']} for the {said(KINDS[i['kind']])}, from {i['by']}: {i.get('pr') or 'no pull request'} at {i['head']}",
             *([f"  Files: {i['files']}"] if i.get("files") else []), f"  Changed: {i['changed']}", f"  Read for: {i['read_for']}"]
    if i.get("owner"):
        lines.append(f"  The owner said: {i['owner']}")
    return "\n".join(lines)


def where(i):
    """The request's pull request and head, as a notice names them."""
    return f"{i['pr']} at {i['head']}" if i.get("pr") else f"at {i['head']}"


def waited(i, now):
    m = (now - i.get("added", now)) // 60
    return f"{m // 60}h{m % 60:02d}m" if m >= 60 else f"{m}m"


def show(q, kind=None):
    now = int(time.time())
    for k in ([kind] if kind else list(KINDS)):
        items = [i for i in q["items"] if i["kind"] == k and i["state"] != "done"]
        print(f"{said(KINDS[k]).capitalize()} ({holder(KINDS[k]) or 'nobody'})")
        for i in items:
            state = {"waiting": "held" if i.get("held") else "waiting", "taken": f"taken by {i.get('taken_by', '')}",
                     "lead": "findings, with the lead"}[i["state"]]
            print(f"  #{i['id']}  {i['key']}  from {i['by']}, {waited(i, now)}  ({state})")
        if not items:
            print("  (empty)")


def waiting(q, kind):
    return [i for i in q["items"] if i["kind"] == kind and i["state"] == "waiting"]


def need(who, *roles):
    if role_of(who) not in roles:
        die(f"{who or 'this session'} is not the {' or '.join(said(r) for r in roles)} (agents/roster.json)")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    cmd, args = argv[0], argv[1:]
    if cmd == "list":
        if args and args[0] not in KINDS:
            die("list takes code or test")
        show(read(), args[0] if args else None)
        return
    who = me()
    if not who:
        die("this is not a named Claude session (or set AGENT_NAME)")
    os.makedirs(os.path.dirname(QUEUE), exist_ok=True)
    with open(QUEUE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        q = read()
        now = int(time.time())
        out = None
        if cmd == "add":
            if len(args) < 2 or args[0] not in KINDS or not KEY.match(args[1]):
                die("add needs code or test and a ticket id: team/review-queue.py add code ABC-123 --pr URL --head SHA ...")
            need(who, "developer", *TESTERS)
            o = options(args[2:], ("pr", "head", "changed", "read_for", "files", "owner"))
            needed = ("pr", "head", "changed", "read_for") if args[0] == "code" else ("head", "files", "changed", "read_for")
            missing = [f"--{k.replace('_', '-')}" for k in needed if not o.get(k)]
            if missing:
                die(f"add needs {', '.join(missing)}")
            if not SHA.match(o["head"]):
                die(f"--head {o['head']!r} is not a commit sha")
            if any(i["kind"] == args[0] and i["key"] == args[1] and i.get("pr", "") == o.get("pr", "") and i["head"] == o["head"]
                   and i["state"] != "done" for i in q["items"]):
                die(f"{args[1]} at {o['head']} is already in the queue for the {said(KINDS[args[0]])}")
            item = {"id": q["next"], "kind": args[0], "key": args[1], "pr": o.get("pr", ""), "head": o["head"], "files": o.get("files", ""), "changed": o["changed"],
                    "read_for": o["read_for"], "owner": o.get("owner", ""), "by": who, "added": now, "state": "waiting", "held": False}
            q["next"] += 1
            q["items"].append(item)
            ahead = len(waiting(q, args[0])) - 1
            notify(q, holder(KINDS[args[0]]), f"A request is waiting for you ({ahead} ahead of it): {item['key']} from {who}. "
                                              f"Run `team/review-queue.py take {args[0]}` when you are free.")
            out = f"#{item['id']} added for the {said(KINDS[args[0]])}, {ahead} ahead of it"
        elif cmd == "take":
            if len(args) != 1 or args[0] not in KINDS:
                die("take needs code or test")
            need(who, KINDS[args[0]])
            item = next((i for i in q["items"] if i["kind"] == args[0] and i["state"] == "taken" and i.get("taken_by") == who), None)
            if not item:
                item = next((i for i in waiting(q, args[0]) if not i.get("held")), None)
                if not item:
                    print("nothing waiting")
                    return
                item.update(state="taken", taken_by=who, taken=now)
            out = brief(item) + f"\nClose it with: team/review-queue.py close {item['id']} --clean \"...\"  or  --findings \"...\""
        elif cmd == "close":
            if len(args) != 3 or args[1] not in ("--clean", "--findings"):
                die('close needs an id and --clean "words" or --findings "words"')
            item = find(q, args[0])
            need(who, KINDS[item["kind"]])
            if item["state"] not in ("taken", "waiting"):
                die(f"#{item['id']} is already closed")
            words = options(["--words", args[2]], ("words",))["words"]
            verdict = args[1][2:]
            item.update(verdict=verdict, words=words, closed=now, taken_by=item.get("taken_by") or who,
                        state="done" if verdict == "clean" else "lead")
            lead = holder(LEAD)
            if verdict == "findings":
                notify(q, lead, f"{who}, as {said(KINDS[item['kind']])}, has findings on {item['key']} ({where(item)}): "
                                f"{words} When you have decided and passed them on, run `team/review-queue.py passed {item['id']}`.")
                out = f"#{item['id']} closed with findings; the delivery lead is told"
            elif item["kind"] == "code":
                signer = signed_off(item["key"], item["head"])
                held = holders(item["key"]) if not signer else []
                tester = next((n for n, r in roster() if r in TESTERS and n in (held or [])), "")
                if signer:
                    notify(q, lead, f"{who}, as code reviewer, approved {item['key']} ({where(item)}) with nothing to "
                                    f"decide, and {signer} has signed it off at that head: it is ready to arm.")
                    out = (f"#{item['id']} closed clean; {signer} signed it off at {item['head'][:9]}, so the delivery lead "
                           f"is told it is ready to arm")
                elif tester:
                    notify(q, tester, f"{who}, as code reviewer, approved {item['key']} ({where(item)}) with nothing to "
                                      f"decide: {words} It is your turn to test it.")
                    out = f"#{item['id']} closed clean; {tester}, as tester, is told it is their turn"
                elif held is None:
                    notify(q, lead, f"{who}, as code reviewer, approved {item['key']} ({where(item)}) with nothing to "
                                    f"decide. The ledger could not say who holds it or whether a tester signed it off: "
                                    f"route it.")
                    out = (f"#{item['id']} closed clean; the ledger could not say who holds {item['key']}, so the delivery "
                           f"lead is told to route it")
                else:
                    notify(q, lead, f"{who}, as code reviewer, approved {item['key']} ({where(item)}) and no tester holds "
                                    f"the ticket: it is ready for one.")
                    out = f"#{item['id']} closed clean; no tester holds {item['key']}, so the delivery lead is told it needs one"
            else:
                notify(q, item["by"], f"{who}, as test reviewer, cleared your request on {item['key']} with nothing to change: {words} "
                                      f"Carry on.")
                out = f"#{item['id']} closed clean; {item['by']} is told"
        elif cmd in ("up", "down", "hold", "release", "passed"):
            if len(args) != 1:
                die(f"{cmd} needs a request id")
            item = find(q, args[0])
            need(who, LEAD)
            if cmd == "passed":
                if item["state"] != "lead":
                    die(f"#{item['id']} has no findings waiting on the lead")
                item.update(state="done", passed=now)
            elif cmd in ("hold", "release"):
                item["held"] = cmd == "hold"
            else:
                if item["state"] != "waiting":
                    die(f"#{item['id']} is not waiting")
                same = waiting(q, item["kind"])
                j = same.index(item) + (-1 if cmd == "up" else 1)
                if 0 <= j < len(same):
                    a, b = q["items"].index(item), q["items"].index(same[j])
                    q["items"][a], q["items"][b] = q["items"][b], q["items"][a]
        elif cmd == "drop":
            if len(args) not in (1, 2) or args[1:] not in ([], ["--taken"]):
                die("drop needs a request id, and --taken for one a reviewer has taken")
            item = find(q, args[0])
            if who != item["by"]:
                need(who, LEAD)
            if item["state"] == "done":
                die(f"#{item['id']} is already closed")
            if item["state"] == "taken" and args[1:] != ["--taken"]:
                die(f"#{item['id']} is taken by {item.get('taken_by', '')}, who may be reviewing it now: ask them, or run "
                    f"`team/review-queue.py drop {item['id']} --taken`, which tells them to stop")
            q["items"].remove(item)
            if item["state"] == "taken":
                notify(q, item.get("taken_by"), f"{who} dropped #{item['id']}, on {item['key']} ({where(item)}), while you had it: "
                                                f"it is no longer wanted. Stop reviewing it and do not close it.")
                out = f"#{item['id']} dropped; {item.get('taken_by', '')}, who had taken it, is told to stop"
        else:
            die(f"no command {cmd!r}; see team/review-queue.py --help")
        write(q, who)
    if out:
        print(out)
    else:
        show(q)


if __name__ == "__main__":
    main(sys.argv[1:])
