#!/usr/bin/env python3
"""The work queue's Now, Next and Later: the work the team means to start, soonest first, each list in order;
Parked: work set aside, not planned for now; and Done: work delivered, each stamped with when, kept DONE_DAYS days.
Work stays in Now while it is worked and moves to Done when it is delivered. The delivery lead keeps it with this
command and the page's Work queue pane draws it, on two tabs: Doing (Now to Parked) and Done. Nothing fills it from
the ledger: it holds what the lead has put in it.

  team/work-queue.py add ID "title" [--now | --next | --later | --parked | --done] [--who NAME] [--note "words"] [--url URL]   (Next unless said)
  team/work-queue.py edit ID [--title "title"] [--who NAME] [--note "words"] [--url URL]   (an empty value clears it)
  team/work-queue.py move ID now|next|later|parked|done                                    (to the end of that list)
  team/work-queue.py done ID [--note "words"]                                 (delivered: to Done, stamped with when)
  team/work-queue.py up ID | down ID                                                       (one place, in its list)
  team/work-queue.py drop ID                                                                (no longer planned)
  team/work-queue.py list

ID is the work's id, as the ledger names it (a ticket's slug, or a key such as ABC-123). The queue is
$AGENT_WORK_QUEUE, else ~/.local/state/<project>/work-queue.json:
  {"now": [item, ...], "next": [item, ...], "later": [item, ...], "parked": [item, ...], "done": [item, ...],
   "at": epoch seconds of the last change, "by": who made it}
where an item is {"key": ID, "title": "...", "who": "Name" or "", "note": "..." or "", "url": an http(s) link or ""},
the title and note in Markdown (`code`, **bold**, web addresses; the page draws them so), and one in Done also has
"done": epoch seconds of when it got there.
A change is made under a lock and written whole, so two agents changing it at once both land. Who made it is
AGENT_NAME, else the name of the Claude session running the command, else the user."""
import fcntl
import glob
import getpass
import json
import os
import re
import sys
import tempfile
import time

HOME = os.path.expanduser("~")
ROOT = os.environ.get("HARNESS_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PROJECT = os.environ.get("HARNESS_PROJECT") or os.path.basename(ROOT)
QUEUE = os.path.expanduser(os.environ.get("AGENT_WORK_QUEUE") or os.path.join(HOME, ".local/state", PROJECT, "work-queue.json"))
KEY = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.#/-]{0,99}$")
LISTS = ("now", "next", "later", "parked", "done")
DONE_DAYS = 14


def die(words):
    print(f"work-queue: {words}", file=sys.stderr)
    sys.exit(1)


def read():
    try:
        with open(QUEUE, encoding="utf-8") as f:
            q = json.load(f)
    except FileNotFoundError:
        return {name: [] for name in LISTS}
    except ValueError:
        die(f"{QUEUE} is not JSON; fix or remove it")
    if not isinstance(q, dict) or not all(isinstance(q.get(k, []), list) for k in LISTS):
        die(f"{QUEUE} is not a work queue; fix or remove it")
    return {**q, **{name: q.get(name, []) for name in LISTS}}


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
                return s["name"]
    return ""


def write(q):
    now = int(time.time())
    q.update(at=now, by=os.environ.get("AGENT_NAME") or session_name() or getpass.getuser(),
             done=[i for i in q["done"] if not isinstance(i.get("done"), int) or now - i["done"] < DONE_DAYS * 86400])
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(QUEUE), prefix=".work-queue.")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(q, f, indent=1, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, QUEUE)


def find(q, key):
    for name in LISTS:
        for i, item in enumerate(q[name]):
            if item.get("key") == key:
                return name, i
    die(f"{key} is not in the queue")


def stamped(item, to):
    """The item as it goes into list `to`: Done stamps when it got there; any other list takes the stamp off."""
    item = {k: v for k, v in item.items() if k != "done"}
    return {**item, "done": int(time.time())} if to == "done" else item


def options(args, allowed):
    """--name value pairs (and a bare list: --now, --next, --later, --parked, --done), checked against what the command
    takes."""
    out, i = {}, 0
    while i < len(args):
        a = args[i]
        if a[2:] in LISTS and a.startswith("--") and "list" in allowed:
            out["list"] = a[2:]
            i += 1
        elif a.startswith("--") and a[2:] in allowed and i + 1 < len(args):
            out[a[2:]] = args[i + 1].strip()
            i += 2
        else:
            die(f"unexpected {a!r}")
    return out


def show(q):
    for name in LISTS:
        print(name.capitalize())
        for item in q[name]:
            extra = "".join(f"  ({x})" for x in (item.get("who"), item.get("note")) if x)
            print(f"  {item['key']}  {item.get('title', '')}{extra}")
        if not q[name]:
            print("  (empty)")


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    cmd, args = argv[0], argv[1:]
    if cmd == "list":
        show(read())
        return
    if not args or not KEY.match(args[0]):
        die(f"{cmd} needs the work's id, as the ledger names it")
    key = args[0]
    os.makedirs(os.path.dirname(QUEUE), exist_ok=True)
    with open(QUEUE + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        q = read()
        if cmd == "add":
            if len(args) < 2 or args[1].startswith("--"):
                die('add needs a title: work-queue.py add ID "title"')
            if any(item.get("key") == key for name in LISTS for item in q[name]):
                die(f"{key} is already in the queue; use edit or move")
            o = options(args[2:], ("list", "who", "note", "url"))
            q[o.get("list", "next")].append(stamped({"key": key, "title": args[1].strip(), "who": o.get("who", ""), "note": o.get("note", ""),
                                                     "url": o.get("url", "")}, o.get("list", "next")))
        elif cmd == "edit":
            name, i = find(q, key)
            q[name][i].update(options(args[1:], ("title", "who", "note", "url")))
        elif cmd == "move":
            if len(args) != 2 or args[1] not in LISTS:
                die("move needs now, next, later, parked or done: work-queue.py move ID now")
            name, i = find(q, key)
            q[args[1]].append(stamped(q[name].pop(i), args[1]))
        elif cmd == "done":
            name, i = find(q, key)
            q["done"].append(stamped({**q[name].pop(i), **options(args[1:], ("note",))}, "done"))
        elif cmd in ("up", "down"):
            name, i = find(q, key)
            j = i - 1 if cmd == "up" else i + 1
            if 0 <= j < len(q[name]):
                q[name][i], q[name][j] = q[name][j], q[name][i]
        elif cmd == "drop":
            name, i = find(q, key)
            q[name].pop(i)
        else:
            die(f"no command {cmd!r}; see work-queue.py --help")
        write(q)
    show(q)


if __name__ == "__main__":
    main(sys.argv[1:])
