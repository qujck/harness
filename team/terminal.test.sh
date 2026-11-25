#!/usr/bin/env bash
# Tests for an agent attached to a terminal: the screen agents_web.py draws a shell's output on (TermScreen), and a real
# Bash behind a terminal keeper of the test's own: nothing printed before is given, what comes after is, a restart
# carries on where reading had reached, and nothing the server does types into the shell.
#   bash team/terminal.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d)
trap 'kill $(cat "$T/pid" 2>/dev/null) 2>/dev/null; rm -rf "$T"' EXIT
mkdir -p "$T/home/.local/state/agents"
HOME="$T/home" SHELL=/bin/bash AGENT_WEB_PORT=8999 PYTHONDONTWRITEBYTECODE=1 python3 - "$HERE/lib/agents_web.py" "$T" <<'EOF'
import importlib.machinery, importlib.util, json, os, subprocess, sys, threading, time
loader = importlib.machinery.SourceFileLoader("aw", sys.argv[1])
aw = importlib.util.module_from_spec(importlib.util.spec_from_loader("aw", loader)); loader.exec_module(aw)
bad = 0
def ok(what, got=True, want=True):
    global bad
    if got != want:
        bad += 1
    print(("ok   " if got == want else "FAIL ") + what + ("" if got == want else f"\n  got  {got!r}\n  want {want!r}"))
def screen(*chunks, cols=20, rows=5, old=b""):
    s = aw.TermScreen(cols, rows)
    s.feed(old); s.mark_old()
    for c in chunks:
        s.feed(c)
    return s
take = lambda *a, **k: screen(*a, **k).take()
ok("plain lines", take(b"one\r\ntwo\r\n"), "one\ntwo")
ok("colours and titles left out", take(b"\x1b]0;title\x07\x1b[1;31mred\x1b[0m\r\n"), "red")
ok("a sequence cut between two chunks", take(b"a\x1b[3", b"1mb\x1b]0;ti", b"tle\x1b\\c"), "abc")
ok("a letter cut between two chunks", take(b"caf\xc3", b"\xa9"), "café")
ok("a progress line is its last state", take(b"10%\r 50%\r100%\r\n"), "100%")
ok("a long line wraps and comes back whole", take(b"x" * 45 + b"\r\nend"), "x" * 45 + "\nend")
ok("a line's spaces at the wrap are kept", take(b"a" * 19 + b" " + b"bb\r\n"), "a" * 19 + " bb")
ok("lines that scrolled off are kept", take(b"".join(b"l%d\r\n" % i for i in range(30))), "\n".join(f"l{i}" for i in range(30)))
ok("blank lines between lines are kept", take(b"a\r\n\r\nb"), "a\n\nb")
ok("drawn by cursor moves", take(b"\x1b[3;1Hthird\x1b[1;1Hfirst\x1b[2;1Hsecond"), "first\nsecond\nthird")
ok("erase to the end of the line", take(b"hello world\x1b[6G\x1b[K"), "hello")
ok("delete and insert characters", take(b"abcdef\x1b[1G\x1b[2P\x1b[1@X"), "Xcdef")
ok("backspacing over a typo", take(b"lx\b \bs -l"), "ls -l")
ok("insert and delete lines", take(b"a\r\nb\r\nc\x1b[2;1H\x1b[Lnew\x1b[1;1H\x1b[M"), "new\nb\nc")
ok("a scroll region", take(b"top\x1b[2;3r\x1b[2;1Ha\r\nb\r\nc"), "top\nb\nc")
ok("cleared before it was read: still given", take(b"secret\r\nout\r\n\x1b[H\x1b[2Jafter"), "secret\nout\nafter")
ok("a wide character", take("日本 ok".encode()), "日本 ok")
ok("a combining mark", take("é".encode()), "é")
ok("the other screen is said to be one", take(b"a\r\n\x1b[?1049h\x1b[HVIM\x1b[2;1H~"), "a\n[a full-screen program is open and shows:]\nVIM\n~")
ok("and leaves nothing behind it", take(b"a\r\n\x1b[?1049h\x1b[HVIM\x1b[?1049lb"), "a\nb")
ok("repeat the last character", take(b"-\x1b[4b"), "-----")
ok("malformed sequences do no harm", take(b"a\x1b[\x01b\x1b\x1b\x1b[?;?c\x1b[99999999;1Hz")[-1:], "z")
ok("nothing old is given", take(b"", old=b"password hunter2\r\n$ "), "")
ok("old text on the line typed on is not given", take(b"ls\r\nfile\r\n", old=b"gone\r\n$ "), "ls\nfile")
ok("old lines scrolled off later are not given", take(b"n\r\n" * 8, old=b"o1\r\no2\r\no3\r\n"), "\n".join("n" * 8))
ok("old lines drawn over as they were stay old", take(b"\x1b[1;1Ho1\x1b[2;1Hnew", old=b"o1\r\n"), "new")
s = screen(b"one\r\n"); s.take()
ok("read once, not twice", s.take(), "")
s.feed(b"two\r\n"); ok("then only what is new", s.take(), "two")
# a terminal resized prints its screen again, as PowerShell does: what comes then is old, and what came before and after is not
def agent(old=b"hush one\r\nhush two\r\n$ "):
    t = aw.TermAgent("fake", "pwsh", "Fake", "Ann", "s1", 40, 6)
    t.since = time.time() - 100; t.replayed(old, None); t.got = time.time() - 60
    return t
def come(t, ago, kind, data):
    t.unread.append([time.time() - ago, kind, data])
t = agent(); come(t, 20, b"o", b"ls\r\nfile-a\r\n$ "); come(t, 15, b"r", (30, 5))
come(t, 14.99, b"o", b"\x1b[?25l\x1b[Hhush one\x1b[K\r\nhush two\x1b[K\r\n$ ls\x1b[K\r\nfile-a\x1b[K\r\n$ \x1b[K"); come(t, 5, b"o", b"pwd\r\n/home\r\n$ ")
got = t.read(); ok("a resize: nothing old", "hush" in got, False); ok("what came before and after is given, once", (got.count("file-a"), got.count("/home")), (1, 1)); ok("and that something was left out is said", got.startswith("[the terminal was resized"))
t = agent(); come(t, 15, b"r", (12, 4)); come(t, 14.9, b"o", b"\x1b[Hhush one\x1b[K\r\nhush two\x1b[K\r\n" + b"hush three\r\n" * 9); come(t, 14, b"r", (40, 6)); come(t, 13.9, b"o", b"\x1b[Hhush one\r\n" * 9); ok("two resizes, the screen run over: nothing", t.read(), "")
t = agent(); come(t, 15, b"r", (12, 4)); [come(t, 15 - i * .3, b"o", b"hush again\r\n") for i in range(1, 20)]; ok("an answer that goes on past its time is old to its first pause", t.read(), "")
t = agent(); come(t, 20, b"r", (12, 4)); [come(t, 20 - i * .4, b"o", b"tick%d\r\n" % i) for i in range(1, 40)]; got = t.read(); ok("a command that never pauses is given again after a while", ("tick39" in got, "tick3\n" in got), (True, False))
t = agent(); come(t, 15, b"o", b"\x1b[?1049h\x1b[Hless\x1b[?1049l\x1b[?25l\x1b[Hhush one\x1b[K\r\nhush two\x1b[K\r\n$ \x1b[K"); ok("a full-screen program closed prints the screen again: nothing old", "hush" in t.read(), False)
t = agent(); t.sent = time.time() - 15; come(t, 14.9, b"r", (30, 5)); come(t, 14.8, b"o", b"out\r\n$ "); ok("a command submitted as the terminal was resized ends a wait, saying so", t.read(2).startswith("[the terminal was resized"))
t = agent(); t.kind = "pwsh"; come(t, 30, b"o", b"ansible-playbook x\r\nPLAY [x] ***\r\n\r\nTASK [y] ***\r\n"); t.got = time.time() - 30; ok("a command printing nothing for a while is not over", t.read(2), "")
come(t, 9, b"o", b"ok: [x]\r\nroot@b8c276965649:/usr/src/imperius# "); t.got = time.time() - 9; ok("it is over once a prompt of any shape is back, and all of it is given", (lambda x: ("TASK [y]" in x, "ok: [x]" in x))(t.read(2)), (True, True))
t = agent(); come(t, 9, b"o", b"sudo x\r\nPassword: "); t.got = time.time() - 9; ok("a question ends a wait", "Password:" in t.read(2), True)
t = agent(); t.unread.append([time.time(), b"r", (30, 5)]); t0 = time.time(); t.read(); ok("a read waits for the answer to be over", time.time() - t0 > 2.5)
s = screen(old=b"a\r\nb\r\n"); s.resize(10, 2); s.resize(40, 9); s.feed(b"x" * 39 + b"\r\nok"); ok("resized small and large", s.take(), "x" * 39 + "\nok")
s = screen(b"$ ls\r\nout\r\n$ "); ok("a command is finished", (s.finished(), bool(aw.TERM_BARE["sh"].search(s.cursor_line()))), (True, True))
s = screen(b"ls -l", old=b"$ "); ok("one being typed is not", s.finished(), False)
ok("a percentage is no prompt", bool(aw.TERM_BARE["sh"].search("Downloading 45%")), False)
import random
r = random.Random(1)
s = aw.TermScreen(30, 8)
for i in range(3000):
    s.feed(r.choice([b"\x1b[%d;%dH" % (r.randint(0, 99), r.randint(0, 99)), b"\x1b[%d%c" % (r.randint(0, 99), r.choice(b"ABCDEFGHJKLMPSTXbdgru@")), os.urandom(20), b"text here\r\n",
                     b"\x1b[?1049%c" % r.choice(b"hl"), b"\x1b[%d;%dr" % (r.randint(0, 12), r.randint(0, 12)), "日本".encode()]))
    if i % 50 == 0: s.resize(r.randint(2, 60), r.randint(2, 20))
    if i % 70 == 0: s.take()
    if i % 10 == 0 and (len(s.lines) != s.rows or any(len(l.c) < s.cols or len(l.c) != len(l.o) for l in s.lines)):
        ok(f"random output, step {i}: the screen keeps its shape", False); break
else:
    ok("random output and sizes: the screen keeps its shape")
for text, why in (("ls -l", None), ("a\nb", None), ("a\x1b[201~b", "U+001B"), ("a\tb", "U+0009"), ("a‮b", "U+202E"), ("a​b", "U+200B"), ("a b", "U+00A0"), ("a\rb", "U+000D"), ("  ", "no command"), ("x" * 9000, "over")):
    got = aw.term_command_bad(text)
    ok(f"command {text[:12]!r}", (got is None) if why is None else (why in (got or "")))

# a real Bash behind this test's own keeper
told, live = [], {"Ann": {"sessionId": "s1", "status": "idle"}, "Bob": {"sessionId": "s2", "status": "idle"}}
aw.type_into = lambda n, t, i=(): told.append((n, t)) or True
aw.live_sessions = lambda: live
aw.panes = lambda: {"Ann": {"pane": "%1"}, "Bob": {"pane": "%2"}}
keeper = subprocess.Popen([sys.executable, sys.argv[1], "--term-keeper"]); open(sys.argv[2] + "/pid", "w").write(str(keeper.pid))
while not os.path.exists(aw.TERM_SOCK): time.sleep(.05)   # or the first joining would start another, left behind
def page(tid, cols=80, rows=24):   # a Terminal pane's own joining, which types as the owner
    k = aw.term_connect(); k.sendall(json.dumps({"op": "attach", "id": tid, "kind": "sh", "cols": cols, "rows": rows}).encode() + b"\n")
    aw._term_at[tid] = {"kind": "sh", "cols": cols, "rows": rows, "pages": 1}
    rf = k.makefile("rb"); box = {"x": False, "out": b""}
    def pump():
        while m := aw.term_get(rf):
            box["out"] += m[1]
            if m[0] == b"x": box["x"] = True
    threading.Thread(target=pump, daemon=True).start()
    return k, threading.Lock(), box
typed = lambda p, s: aw.term_put(p[0], p[1], b"i", s.encode())
p = page("shell1"); time.sleep(1)
typed(p, "PS1='$ '; echo hush-$((40+2))\r"); time.sleep(.7)
typed(p, "half-typed"); time.sleep(.5)
ok("attaching is refused for a terminal no page has open", aw.term_attach("nosuch", "x", "Ann"), "that terminal is not open on the page")
ok("and for an agent not running", aw.term_attach("shell1", "x", "Zed"), "that agent is not running in a pane")
ok("attached", aw.term_attach("shell1", 'My "shell"\n', "Ann"), None)
t = aw._term_agents["shell1"]; time.sleep(.3)
ok("its agent is told", (len(told), told[0][0], told[0][1].startswith("[team page, not the owner] The owner has attached you to their terminal \"My shell\"")), (1, "Ann", True))
ok("nothing from before is given", t.read(), "")
typed(p, "\x15echo one-$((1+1))\r")
ok("--wait gives a finished command", "one-2" in t.read(10), True)
ok("and not again", t.read(), "")
typed(p, "sleep 2; echo two-$((1+1))\r"); t0 = time.time()
got = t.read(15); ok("--wait waits for a slow one", ("two-2" in got, time.time() - t0 > 2), (True, True))
t0 = time.time(); ok("--wait with nothing printed gives up", (t.read(1.5), time.time() - t0 < 4), ("", True))
typed(p, "echo half"); ok("a command being typed does not end a wait", t.read(3), "")
typed(p, "\x15"); time.sleep(.3); t.read()
ok("one agent to a terminal: another takes its place", (aw.term_attach("shell1", "My shell", "Bob"), aw.term_agents()["shell1"]["agent"]), (None, "Bob"))
time.sleep(.4); ok("and the first is told", any(n == "Ann" and "another agent" in x for n, x in told))
ok("a detached one reads nothing more", t.read(), None)
q = page("shell2"); time.sleep(.8)
ok("one terminal to an agent", (aw.term_attach("shell2", "Two", "Bob"), list(aw.term_agents())), (None, ["shell2"]))
t = aw._term_agents["shell2"]
typed(q, "PS1='$ '; echo before-$((1+2))\r"); time.sleep(.7); ok("read there", "before-3" in t.read())
# the page's server restarted: another process's worth of state, joined again from what is on disk
disk = open(aw.TERM_AGENTS).read()
ok("what is on disk is the owner's alone and holds nothing printed", (oct(os.stat(aw.TERM_AGENTS).st_mode & 0o777), "before" in disk), ("0o600", False))
t.suggest = "ls"; t.n = 4; aw.term_agents_changed()
aw._term_agents.clear(); t.close(); time.sleep(.3)
typed(q, "echo during-$((2+2))\r"); time.sleep(.7)
aw.term_agents_start(); t = aw._term_agents["shell2"]; time.sleep(4)
ok("a place to go on from again", bool(t.mark))
ok("a restart keeps the command shown", aw.term_agents()["shell2"], {"agent": "Bob", "label": "Two", "text": "ls", "n": 4})
got = t.read(); ok("a restart gives what came during it and nothing from before", ("during-4" in got, "before-3" in got), (True, False))
typed(q, "stty size\r"); time.sleep(.7); ok("joining leaves the terminal's size as it was", "24 80" in t.read())
t.resize(60, 20); aw.term_put(q[0], q[1], b"r", json.dumps({"cols": 60, "rows": 20}).encode())
time.sleep(3.8); typed(q, "stty size\r"); time.sleep(.6); ok("a resize is followed", "20 60" in t.read())
typed(q, "head -c 3000000 /dev/zero | tr '\\0' 'y' | fold -w 59; echo fin-$((3+3))\r")
got = t.read(30); ok("a flood is cut to what is kept, its end whole", ("fin-6" in got, "more than is kept" in got, len(got) < 25000), (True, True, True))
typed(q, "exit\r"); time.sleep(1.5)
ok("the shell's end detaches", aw.term_agents(), {})
ok("and its agent is told", "the terminal has ended" in told[-1][1])
ok("nothing left on disk", os.path.exists(aw.TERM_AGENTS), False)
aw.term_attach("shell1", "One", "Ann"); time.sleep(.5); aw.term_detach("shell1", "the owner detached you"); time.sleep(.5)
ok("detached by the owner", (aw.term_agents(), "the owner detached you" in told[-1][1]), ({}, True))
# a shell that ended while the page's server was down is not made again
aw.term_attach("shell1", "One", "Ann"); t = aw._term_agents["shell1"]; aw._term_agents.clear(); t.close()
typed(p, "exit\r"); time.sleep(1.5)
aw.term_agents_start(); time.sleep(1); ok("a shell gone while the server was down is not made again", aw.term_agents(), {})
print("\n" + (f"{bad} failed" if bad else "all pass")); keeper.kill(); sys.exit(1 if bad else 0)
EOF
