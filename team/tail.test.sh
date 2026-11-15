#!/usr/bin/env bash
# Tests the team page's transcript follower (agents_web.py's Tail): that a conversation read once is then read on only from
# where it stopped, gives the same turns as reading it whole, holds back a line still being written, starts again on a
# file cut short or replaced, keeps the model and last compaction up to date, keeps a bounded number of turns, and stops
# following a transcript nobody asks about. Every transcript is written here; nothing live is read.
#
#   bash team/tail.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
HOME="$T" python3 - "$HERE" "$T" <<'EOF'
import importlib.machinery, importlib.util, json, os, sys, time
from functools import partial
here, T = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("agents_web", os.path.join(here, "lib", "agents_web.py"))
spec = importlib.util.spec_from_loader("agents_web", loader)
aw = importlib.util.module_from_spec(spec); loader.exec_module(aw)
dumps = partial(json.dumps, separators=(",", ":"))   # as Claude Code writes them

fails = 0
def expect(what, got, want):
    global fails
    if got == want:
        print("ok  ", what)
    else:
        print("FAIL", what, f"\n     got {got!r}, want {want!r}")
        fails += 1

os.makedirs(os.path.join(T, "proj", "x"))
aw.PROJECTS = os.path.join(T, "proj")
SID = "s1"
P = os.path.join(T, "proj", "x", SID + ".jsonl")
n = [0]

def said(text, model="claude-opus-5-5"):
    n[0] += 1
    return dumps({"type": "assistant", "timestamp": f"2026-11-15T10:{n[0] // 60:02d}:{n[0] % 60:02d}Z",
                       "message": {"model": model, "content": [{"type": "text", "text": text}]}}).encode() + b"\n"

def tool(name):
    n[0] += 1
    return dumps({"type": "assistant", "timestamp": f"2026-11-15T11:{n[0] // 60 % 60:02d}:{n[0] % 60:02d}Z",
                       "message": {"content": [{"type": "tool_use", "name": "Bash", "input": {"command": name}}]}}).encode() + b"\n"

def compact(pre):
    return dumps({"type": "system", "subtype": "compact_boundary", "timestamp": "2026-11-15T12:00:00Z",
                       "compactMetadata": {"trigger": "auto", "preTokens": pre, "postTokens": 9, "durationMs": 5}}).encode() + b"\n"

def write(data, mode="ab"):
    with open(P, mode) as f:
        f.write(data)

def whole(limit):
    with open(P, "rb") as f:
        return aw.turns(f.read().split(b"\n"), limit)

texts = lambda items: [it.get("text") for it in items]

write(b"".join(said(f"one {i}") for i in range(5)), "wb")
expect("first read: the turns there", texts(aw.feed(SID, 300)), [f"one {i}" for i in range(5)])
t = aw._tails[P]

write(said("two"))
expect("an addition is read on from where reading stopped", texts(aw.feed(SID, 300))[-1], "two")
expect("reading stopped at the file's end", t.off, os.path.getsize(P))

half = said("three")
write(half[:20])
expect("a line still being written is held back", texts(aw.feed(SID, 300))[-1], "two")
write(half[20:])
expect("and read once its newline arrives", texts(aw.feed(SID, 300))[-1], "three")

write(b"".join(tool(f"t{i}") for i in range(4)) + said("four"))
expect("the same turns as reading the file whole", json.dumps(aw.feed(SID, 300)), json.dumps(whole(300)))
expect("a smaller limit is the newest of them", json.dumps(aw.feed(SID, 3)), json.dumps(whole(3)))

expect("model: from the transcript", aw.transcript_model(SID), "Opus 5.5")
write(said("five", "claude-sonnet-5-5"))
expect("model: follows a later answer", aw.transcript_model(SID), "Sonnet 5.5")
expect("compaction: none yet", aw.last_compact(SID), None)
write(compact(100))
expect("compaction: an added one is found", (aw.last_compact(SID) or {}).get("pre"), 100)

write(said("fresh"), "wb")   # cut short: the file is rewritten
expect("a file cut short is read again from the start", texts(aw.feed(SID, 300)), ["fresh"])
expect("its compaction is gone with it", aw.last_compact(SID), None)

os.replace(P, P + ".old")
write(said("replaced 1") + said("replaced 2"), "wb")
expect("a replaced file (new inode) is read again", texts(aw.feed(SID, 300)), ["replaced 1", "replaced 2"])

write(b"".join(said(f"many {i}") for i in range(aw.TAIL_KEEP * 4)))
aw.feed(SID, 300)
expect("only so many turns are kept", len(aw._tails[P].has["turns"][0]) <= aw.TAIL_KEEP * 3, True)
expect("and the newest 300 are still right", json.dumps(aw.feed(SID, 300)), json.dumps(whole(300)))

aw._tails[P].used = time.time() - aw.TAIL_IDLE - 1
aw._swept[0] = 0
aw._paths["other"] = None
os.makedirs(os.path.join(T, "proj", "y"))
with open(os.path.join(T, "proj", "y", "other.jsonl"), "wb") as f:
    f.write(said("other"))
aw._paths.pop("other")
aw.feed("other", 10)
expect("a transcript nobody asked about for an hour stops being followed", P in aw._tails, False)
expect("one asked about is followed", os.path.join(T, "proj", "y", "other.jsonl") in aw._tails, True)

sys.exit(1 if fails else 0)
EOF
