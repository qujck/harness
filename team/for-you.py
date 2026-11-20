#!/usr/bin/env python3
"""For you: what is waiting on the owner, one item per question, approval or decision. The delivery lead adds each one
as it comes up and clears it when the owner has answered; the owner reads them on the team page's For you pane, by
their ticket key (the owner, 2026-11-11: "they dont even need their own numbers, ideally just reference ticket ID, or
nothing if theres no ticket"), and can clear them there too. An empty list means the agents are working on
their own. Only the delivery lead adds items (owner, 2026-11-11: "just the lead should be able to add items").

  team/for-you.py add "question" [--ticket ID]
  team/for-you.py clear FYn|ID|N [--answer "words"]  (answered or dealt with: off the list, kept under Cleared; FY3
                                                      clears that item, a ticket id every open item for that ticket, N
                                                      the one numbered N)
  team/for-you.py list [--all]                    (--all: the cleared ones too)

Every open item has a short code, FY1, FY2 ..., which the page shows first on its row so the owner can name it to the
lead (owner, 2026-11-19: "i need [the lead] to know im immediately talking about the for-you"). It is the lowest number
no other open item has, kept until the item is cleared, then free for the next. An open item without one (from before
codes) gets one the next time the list is read. The numbers (n) are the command's own handle; the page does not show them.

ID is the work's id, as the ledger names it (a ticket's slug, or a key such as ABC-123). The list is $AGENT_FOR_YOU,
else ~/.local/state/<project>/for-you.json:
  {"next": the next number, "open": [item, ...], "cleared": [item, ...], "at": epoch seconds of the last change,
   "by": who made it}
where an item is {"n": 3, "ref": "FY1", "text": "...", "ticket": an ID or "", "from": "Name", "at": epoch seconds}, the text in
Markdown, and a cleared one also has "cleared" (epoch seconds), "by" and "answer" ("" for none). Cleared items are
kept CLEARED_DAYS days. A change is made under a lock and written whole, as work-queue's are, and the team page
clears an item the same way. Who made it is AGENT_NAME, else the name of the Claude session running the command, else
the user."""
import fcntl
import getpass
import glob
import json
import os
import re
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
ROOT = os.environ.get("HARNESS_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.environ.get("HARNESS_PROJECT") or os.path.basename(ROOT)
FILE = os.path.expanduser(os.environ.get("AGENT_FOR_YOU") or os.path.join(HOME, ".local/state", PROJECT, "for-you.json"))
KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.#/-]{0,254}$")
REF = re.compile(r"^FY([1-9]\d*)$")
CLEARED_DAYS = 14


def die(words):
    print(f"for-you: {words}", file=sys.stderr)
    sys.exit(1)


def read():
    try:
        with open(FILE, encoding="utf-8") as f:
            q = json.load(f)
    except FileNotFoundError:
        return {"next": 1, "open": [], "cleared": []}
    except ValueError:
        die(f"{FILE} is not JSON; fix or remove it")
    if not isinstance(q, dict) or not isinstance(q.get("open", []), list) or not isinstance(q.get("cleared", []), list):
        die(f"{FILE} is not a For you list; fix or remove it")
    return {**q, "next": q.get("next") if isinstance(q.get("next"), int) else 1, "open": q.get("open", []), "cleared": q.get("cleared", [])}


def give_refs(q):
    """Gives each open item without a code of its own the lowest free one, in list order; True if any was given."""
    taken, given = set(), False
    for i in q["open"]:
        m = REF.match(str(i.get("ref", "")))
        if m and int(m[1]) not in taken:
            taken.add(int(m[1]))
        else:
            i.pop("ref", None)
    for i in q["open"]:
        if "ref" not in i:
            k = next(k for k in range(1, len(taken) + 2) if k not in taken)
            taken.add(k)
            i["ref"], given = f"FY{k}", True
    return given


def session_name():
    """The name of the Claude session this runs in: its ~/.claude/sessions/<pid>.json with this CLAUDE_CODE_SESSION_ID."""
    sid = os.environ.get("CLAUDE_CODE_SESSION_ID")
    if sid:
        for f in glob.glob(os.path.join(HOME, ".claude", "sessions", "*.json")):
            try:
                with open(f) as fh:
                    s = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(s, dict) and s.get("sessionId") == sid and isinstance(s.get("name"), str):
                return s["name"]
    return ""


def who():
    return os.environ.get("AGENT_NAME") or session_name() or getpass.getuser()


def write(q):
    now = int(time.time())
    q.update(at=now, by=who(), cleared=[i for i in q["cleared"] if not isinstance(i.get("cleared"), int) or now - i["cleared"] < CLEARED_DAYS * 86400])
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(FILE), prefix=".for-you.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(q, f, indent=1, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, FILE)


def ago(t):
    m = max(0, int(time.time() - t) // 60)
    return f"{m}m" if m < 60 else f"{m // 60}h" if m < 1440 else f"{m // 1440}d"


def show(q, everything):
    if not q["open"]:
        print("Nothing for the owner.")
    for i in q["open"]:
        print(f"  {i.get('ref', ''):<5} {i['n']:>3}  {i.get('ticket') or '':<10} {i.get('text', '')}  ({i.get('from', '')}, {ago(i.get('at', 0))} ago)")
    if everything and q["cleared"]:
        print("Cleared")
        for i in q["cleared"]:
            answer = f"  -> {i['answer']}" if i.get("answer") else ""
            print(f"  {'':<5} {i['n']:>3}  {i.get('ticket') or '':<10} {i.get('text', '')}{answer}  (by {i.get('by', '')}, {ago(i.get('cleared', 0))} ago)")


def options(args, allowed):
    out, i = {}, 0
    while i < len(args):
        a = args[i]
        if a.startswith("--") and a[2:] in allowed and i + 1 < len(args):
            out[a[2:]] = args[i + 1].strip()
            i += 2
        else:
            die(f"unexpected {a!r}")
    return out


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    cmd, args = argv[0], argv[1:]
    if cmd == "list" and args not in ([], ["--all"]):
        die("list takes only --all")
    os.makedirs(os.path.dirname(FILE), exist_ok=True)
    with open(FILE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        q = read()
        if cmd == "list":
            if give_refs(q):
                write(q)
            show(q, bool(args))
            return
        if cmd == "add":
            if not args or not args[0].strip() or args[0].startswith("--"):
                die('add needs the question: team/for-you.py add "question" [--ticket ID]')
            o = options(args[1:], ("ticket",))
            if o.get("ticket") and not KEY.match(o["ticket"]):
                die(f"{o['ticket']!r} is not a ticket id")
            q["open"].append({"n": q["next"], "text": " ".join(args[0].split()), "ticket": o.get("ticket", ""), "from": who(), "at": int(time.time())})
            q["next"] += 1
            give_refs(q)
            print(f"Added as {q['open'][-1]['ref']}.")
        elif cmd == "clear":
            ref = args[0].upper() if args else ""
            if not args or not (args[0].isdigit() or REF.match(ref) or KEY.match(args[0])):
                die('clear needs an item\'s code, a ticket id or the number `list` shows: team/for-you.py clear FY3 [--answer "words"]')
            o = options(args[1:], ("answer",))
            give_refs(q)
            items = [i for i in q["open"] if (i.get("ref") == ref if REF.match(ref) else i.get("n") == int(args[0]) if args[0].isdigit() else i.get("ticket") == args[0])]
            if not items:
                die(f"nothing open for {args[0]}; team/for-you.py list shows what is")
            for item in items:
                q["open"].remove(item)
                q["cleared"].insert(0, {**item, "cleared": int(time.time()), "by": who(), "answer": o.get("answer", "")})
        else:
            die(f"no command {cmd!r}; see team/for-you.py --help")
        write(q)
    show(q, False)


if __name__ == "__main__":
    main(sys.argv[1:])
