#!/usr/bin/env python3
"""Keep the byobu Delivery tab in step with the strength team as agents are spawned and benched.

Run by tmux hooks (session-created, pane-died) that restore-claude.sh sets, and safe to run by hand at
any time: it only moves, adds and removes panes, never starts or stops an agent.

  - A spawned agent arrives in its own tmux session `strength-<name>` (harness scripts/agent-spawn.sh);
    its pane is moved into Delivery and that session closes. The harness still finds the agent (by the
    GIT_AUTHOR_EMAIL in its process), so agent-bench.sh still stops it.
  - A pane whose agent has exited (benched) stays dead in place (remain-on-exit) until this turns it
    back into an empty shell.
  - Layout: columns of two (top / bottom) in roster order: the developers, then the testers, then any
    other agent here, with the code reviewer always in the bottom-right pane. Developers and testers
    never share a column; a gap is an empty shell. Never fewer than 8 panes; more agents, more columns.
  - An empty shell with something running in it is never removed.
  - Each arriving agent gets its role's Claude Code colour (/color): a background helper waits until Claude
    Code is up with an empty prompt (so it never types over a draft or a startup dialog; busy is fine),
    then types the command and checks Claude Code confirmed it. A spawn is a fresh conversation, so
    this happens on every spawn.
"""
import fcntl
import glob
import json
import mmap
import os
import re
import shlex
import subprocess
import sys
import time

ROSTER = os.environ.get("ROSTER_FILE", "/home/peter/dev/strength/agents/roster.json")
SESSION = "Delivery"
PREFIX = "strength-"
# Roles that live in other tabs (Delivery Lead, Project, Ops), never in Delivery.
ELSEWHERE = {"delivery-lead", "head-of-testing", "process-improvement", "production-support", "head-of-operations"}
MIN_PANES = 8
# The owner's /color for each role that is spawned.
COLOURS = {"developer": "blue", "tester": "yellow"}
# What a gap runs: "empty slot" in the middle of the pane, a shell after Enter.
EMPTY = ["python3", os.path.join(os.path.dirname(os.path.abspath(__file__)), "empty-slot.py")]
SESSIONS = os.environ.get("DELIVERY_SYNC_SESSIONS", os.path.expanduser("~/.claude/sessions"))
PROJECTS = os.path.expanduser("~/.claude/projects")
LOCK = "/tmp/delivery-sync.lock"
# e.g. "-L restoretest" to drive a throwaway tmux server instead of the live one.
TMUX = ["tmux", *shlex.split(os.environ.get("DELIVERY_SYNC_TMUX_ARGS", ""))]


def tmux(*args, check=False):
    r = subprocess.run([*TMUX, *args], capture_output=True, text=True)
    if check and r.returncode:
        raise RuntimeError(f"tmux {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def children(pid):
    out = []
    try:
        for t in os.listdir(f"/proc/{pid}/task"):
            with open(f"/proc/{pid}/task/{t}/children") as f:
                out += [int(c) for c in f.read().split()]
    except OSError:
        pass
    return out


def agent_in(pid, depth=3):
    """The GIT_AUTHOR_NAME of the pane's process or one of its descendants, or None."""
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            for kv in f.read().split(b"\0"):
                if kv.startswith(b"GIT_AUTHOR_NAME="):
                    return kv.split(b"=", 1)[1].decode()
    except OSError:
        pass
    if depth:
        for c in children(pid):
            n = agent_in(c, depth - 1)
            if n:
                return n
    return None


def roster():
    with open(ROSTER) as f:
        return [a for a in json.load(f).get("agents", []) if a.get("status") == "active"]


def slots(running, agents):
    """The pane contents in column order (top, bottom, ...): a name, or None for an empty shell."""
    role = {a["name"]: a["role"] for a in agents}
    order = [a["name"] for a in agents if a["name"] in running]
    order += sorted(n for n in running if n not in role)  # off-roster: keep them, at the end of "other"
    out = []
    for group in ("developer", "tester"):
        names = [n for n in order if role.get(n) == group]
        out += names + ([None] if len(names) % 2 else [])
    out += [n for n in order if role.get(n) not in ("developer", "tester", "code-reviewer", "test-reviewer")]
    rev = [n for n in order if role.get(n) == "test-reviewer"] + [n for n in order if role.get(n) == "code-reviewer"]
    if (len(out) + len(rev)) % 2:
        out.append(None)
    out += rev
    while len(out) < MIN_PANES:  # pad with empty columns before the last one, so the reviewer stays put
        out = out[:-2] + [None, None] + out[-2:] if len(out) >= 2 else [None, None] + out
    return out


def layout(width, height, cols):
    """A tmux layout string: `cols` columns of two panes filling width x height."""
    usable = width - (cols - 1)
    widths = [usable // cols + (1 if i >= cols - usable % cols else 0) for i in range(cols)]
    top = (height - 1) // 2
    bottom = height - 1 - top
    parts, x, n = [], 0, 0
    for w in widths:
        parts.append(f"{w}x{height},{x},0[{w}x{top},{x},0,{n},{w}x{bottom},{x},{top + 1},{n + 1}]")
        x += w + 1
        n += 2
    body = f"{width}x{height},0,0{{{','.join(parts)}}}"
    csum = 0
    for ch in body:
        csum = ((csum >> 1) | ((csum & 1) << 15)) + ord(ch)
        csum &= 0xFFFF
    return f"{csum:04x},{body}"


def panes():
    rows = tmux("list-panes", "-t", f"={SESSION}:", "-F",
                "#{pane_id}\t#{pane_pid}\t#{pane_dead}\t#{@agent}")
    out = []
    for line in rows.splitlines():
        pid_, ppid, dead, tag = line.split("\t")
        out.append({"id": pid_, "pid": int(ppid), "dead": dead == "1",
                    "agent": None if dead == "1" else (tag or agent_in(int(ppid)))})
    return out


def largest():
    rows = [l.split() for l in tmux("list-panes", "-t", f"={SESSION}:", "-F",
                                     "#{pane_id} #{pane_width} #{pane_height}").splitlines()]
    return max(rows, key=lambda r: int(r[1]) * int(r[2]))[0]


def is_idle_shell(p):
    return not p["dead"] and not p["agent"] and not children(p["pid"])


def main():
    if subprocess.run([*TMUX, "has-session", "-t", f"={SESSION}"], capture_output=True).returncode:
        return
    # The hooks that run this: put back if anything removed them (pane-died once vanished, and benches stopped
    # re-laying the tab). Each run re-asserts both, so one surviving hook restores the other.
    me = f'run-shell -b "python3 {os.path.abspath(__file__)}"'
    for hook in ("session-created", "pane-died"):
        if me not in tmux("show-hooks", "-g", hook):
            tmux("set-hook", "-g", hook, me)
    agents = roster()
    by_lower = {a["name"].lower(): a["name"] for a in agents}
    tmux("set-option", "-w", "-t", f"={SESSION}:", "remain-on-exit", "on")

    # 1. A benched agent's pane: back to an empty shell.
    for p in panes():
        if p["dead"]:
            tmux("respawn-pane", "-k", "-t", p["id"], "-c", "/home/peter", *EMPTY)
            for tag in ("@agent", "@colour", "@colouring"):
                tmux("set-option", "-p", "-t", p["id"], "-u", tag)

    # 2. Spawned agents waiting in their own strength-<name> sessions.
    arriving = []
    for s in tmux("list-sessions", "-F", "#{session_name}").split():
        if s.startswith(PREFIX) and s[len(PREFIX):] in by_lower:
            pane = tmux("list-panes", "-t", f"={s}:", "-F", "#{pane_id}").split()
            if len(pane) == 1:
                arriving.append((by_lower[s[len(PREFIX):]], pane[0]))
    roles = {a["name"]: a["role"] for a in agents}
    current = panes()
    running = {p["agent"] for p in current if p["agent"]} | {n for n, _ in arriving}
    running = {n for n in running if roles.get(n) not in ELSEWHERE}
    want = slots(running, agents)

    # 3. Make room, bring the arrivals in, and match the number of empty shells to the gaps.
    tmux("select-layout", "-t", f"={SESSION}:", "tiled")
    for name, pane in arriving:
        if name not in want:
            continue
        tmux("join-pane", "-d", "-s", pane, "-t", largest(), check=True)
        tmux("set-option", "-p", "-t", pane, "@agent", name)
        tmux("select-layout", "-t", f"={SESSION}:", "tiled")
    current = panes()
    gaps = want.count(None)
    empties = [p for p in current if not p["agent"]]
    for p in empties[gaps:]:
        if is_idle_shell(p):
            tmux("kill-pane", "-t", p["id"])
    while len([p for p in panes() if not p["agent"]]) < gaps:
        tmux("split-window", "-d", "-t", largest(), "-c", "/home/peter", *EMPTY, check=True)
        tmux("select-layout", "-t", f"={SESSION}:", "tiled")

    # 4. Every agent here still without its role's colour gets a helper, unless one is already waiting:
    #    a spawned agent can stay busy for hours, so this also picks up any helper that was lost.
    current = panes()
    for p in current:
        if roles.get(p["agent"]) in COLOURS:
            start_colour(p["id"], COLOURS[roles[p["agent"]]])

    # 5. Lay out the columns and put each pane in its cell.
    if len(current) != len(want):  # an empty shell in use could not be removed: leave the tiling alone
        return
    size = tmux("display-message", "-p", "-t", f"={SESSION}:", "#{window_width} #{window_height}").split()
    tmux("select-layout", "-t", f"={SESSION}:", layout(int(size[0]), int(size[1]), len(want) // 2), check=True)
    spare = [p["id"] for p in current if not p["agent"]]
    owner = {p["agent"]: p["id"] for p in current if p["agent"]}
    target = [owner[n] if n else spare.pop(0) for n in want]
    for i, pid_ in enumerate(target):
        # The cells down each column in turn: sorted by left edge, then top.
        geo = [l.split() for l in tmux("list-panes", "-t", f"={SESSION}:", "-F",
                                        "#{pane_id} #{pane_left} #{pane_top}").splitlines()]
        here = sorted(geo, key=lambda g: (int(g[1]), int(g[2])))[i][0]
        if here != pid_:
            tmux("swap-pane", "-d", "-s", pid_, "-t", here)


def session_record(pid, depth=3):
    """The Claude Code session record (~/.claude/sessions/<pid>.json) for the pane's process tree, or None."""
    try:
        with open(os.path.join(SESSIONS, f"{pid}.json")) as f:
            return json.load(f)
    except (OSError, ValueError):
        pass
    if depth:
        for c in children(pid):
            rec = session_record(c, depth - 1)
            if rec:
                return rec
    return None


def session_colour(rec):
    """The colour the session's transcript last recorded (/color writes an agent-color line), or None.
    Read from the transcript, never the screen: a narrow pane wraps "Session color set to: <name>"."""
    sid = (rec or {}).get("sessionId")
    if not sid:
        return None
    for path in glob.glob(os.path.join(PROJECTS, "*", f"{sid}.jsonl")):
        try:
            with open(path, "rb") as f, mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as m:
                at = m.rfind(b'"type":"agent-color"')
                if at < 0:
                    continue
                start, end = m.rfind(b"\n", 0, at) + 1, m.find(b"\n", at)
                return json.loads(m[start:end if end >= 0 else len(m)]).get("agentColor")
        except (OSError, ValueError):
            continue
    return None


def prompt_line(pane):
    """What is typed at the agent's prompt. Dim text is Claude Code's suggested next message, not typed."""
    lines = [l for l in tmux("capture-pane", "-p", "-e", "-t", pane).splitlines()
             if re.sub(r"\x1b\[[0-9;]*m", "", l).lstrip().startswith("\u276f")]
    if not lines:
        return None
    typed = re.sub(r"\x1b\[2m.*?(\x1b\[(?:0|22)?m|$)", "", lines[-1])
    return re.sub(r"\x1b\[[0-9;]*m", "", typed).lstrip()[1:].strip()


def start_colour(pane, name):
    """Start a colour helper for the pane, unless it is coloured already or a helper is still waiting on it."""
    done, helper = tmux("display-message", "-p", "-t", pane, "#{@colour}\t#{@colouring}").rstrip("\n").split("\t")
    if done == name or (helper.isdigit() and os.path.exists(f"/proc/{helper}")):
        return
    h = subprocess.Popen([sys.executable, os.path.abspath(__file__), "--colour", pane, name],
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         start_new_session=True)
    tmux("set-option", "-p", "-t", pane, "@colouring", str(h.pid))


def colour(pane, name, every_s=3):
    """Type `/color <name>` into the pane once Claude Code is up with an empty prompt; confirm it.
    Busy is fine: /color runs at once mid-turn and starts no turn (tested 10-25), and a spawned agent goes
    straight to its ticket, so waiting for idle left it uncoloured for hours."""
    agent_pid, tries = None, 0
    while True:
        info = tmux("display-message", "-p", "-t", pane, "#{pane_pid} #{pane_dead}").split()
        if len(info) != 2 or info[1] == "1" or (agent_pid and info[0] != agent_pid):
            return  # the pane, or the agent it was started for, is gone
        agent_pid = info[0]
        rec = session_record(int(agent_pid))
        if rec and session_colour(rec) == name:  # set, by us or by hand: confirmed from the transcript
            tmux("set-option", "-p", "-t", pane, "@colour", name)
            return
        if rec and prompt_line(pane) == "":
            tmux("send-keys", "-t", pane, "-l", f"/color {name}")
            time.sleep(0.5)
            if prompt_line(pane) == f"/color {name}":
                tmux("send-keys", "-t", pane, "Enter")
                time.sleep(2)
                tries += 1
                if tries >= 5:  # it ran five times and the transcript never showed it: stop, and say so
                    tmux("display-message", f"delivery-sync: /color {name} in {pane} not confirmed after 5 tries")
                    return
                continue  # the next pass reads the transcript
            else:  # something else got into the prompt: take ours back out and try again later
                for _ in f"/color {name}":
                    tmux("send-keys", "-t", pane, "BSpace")
        time.sleep(every_s)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--colour"]:
        colour(sys.argv[2], sys.argv[3])
        sys.exit(0)
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            main()
        except Exception as e:  # a hook has nowhere to show an error but the tmux message line
            tmux("display-message", f"delivery-sync: {e}")
            sys.exit(1)
