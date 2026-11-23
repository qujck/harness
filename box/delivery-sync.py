#!/usr/bin/env python3
"""Give each spawned agent its role's Claude Code colour. Every agent has its own tmux session (owner, 2026-11-23:
"give each agent their own byobu session"), so nothing is moved into a shared tab any more.

Run by the tmux session-created hook that restore-claude.sh sets, and safe to run by hand at any time: it never
starts, stops or moves an agent.

  - A spawned agent arrives in its own tmux session `strength-<name>` (harness team/agent-spawn.sh), and stays
    there. The harness finds it by that name (team/lib/agent-session.sh), so agent-bench.sh still stops it.
  - Each agent whose role has a colour gets its role's Claude Code colour (/color): a background helper waits until
    Claude Code is up with an empty prompt (so it never types over a draft or a startup dialog; busy is fine),
    then types the command and checks Claude Code confirmed it. A spawn is a fresh conversation, so this happens
    on every spawn.
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
PREFIX = "strength-"
# The owner's /color for each role that is spawned.
COLOURS = {"developer": "blue", "tester": "yellow"}
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


def roster():
    with open(ROSTER) as f:
        return [a for a in json.load(f).get("agents", []) if a.get("status") == "active"]


def main():
    # The hook that runs this: put back if anything removed it. The old layout's pane-died hook re-laid a shared
    # Delivery tab; there is none now, so it goes.
    me = f'run-shell -b "python3 {os.path.abspath(__file__)}"'
    if me not in tmux("show-hooks", "-g", "session-created"):
        tmux("set-hook", "-g", "session-created", me)
    if me in tmux("show-hooks", "-g", "pane-died"):
        tmux("set-hook", "-gu", "pane-died")
    roles = {a["name"].lower(): a["role"] for a in roster()}
    # Every agent session still without its role's colour gets a helper, unless one is already waiting: a spawned
    # agent can stay busy for hours, so this also picks up any helper that was lost.
    for s in tmux("list-sessions", "-F", "#{session_name}").split("\n"):
        role = roles.get(s[len(PREFIX):]) if s.startswith(PREFIX) else None
        if role in COLOURS:
            pane = tmux("list-panes", "-t", f"={s}:", "-F", "#{pane_id}").split()
            if len(pane) == 1:
                start_colour(pane[0], COLOURS[role])


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
