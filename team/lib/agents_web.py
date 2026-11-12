#!/usr/bin/env python3
"""The team as a web page, on this machine only. Run through team/agents-web.sh, which loads harness.env.

  /                 the page: the week, the disk and every running agent on the roster, in sections by role, each
                    with its state, context, burn, ticket and the last turns of its conversation
  /api/state        everything the page draws, as JSON
                    (and the header's and footer's plug-ins: team/bar's and each executable in AGENT_BAR_PLUGINS,
                    else ~/.config/agents-web/bar, given the page's numbers, print a line or JSON; see plugins())
  /api/team         every message between the running agents, as one transcript
  /api/perf         the machine's CPU, memory, disks, network and GPUs, with their last ten minutes, for Performance panes
  /api/perf/history?key=cpu&span=3600   one of those over 2 minutes, 10, an hour or a day, for the enlarged graph
  /api/agent/NAME   one agent's longer conversation and its terminal as it is on screen now (HTML)
  /doc?p=PATH       a document an agent names by its full path, as text for the page to show over itself
  POST /api/agent/NAME/say   {"text": "...", "images": [pasted paths]} typed into the agent's tmux pane, then Enter
  POST /api/agent/NAME/answer  {"n": 3, "label": "Type something.", "text": "..."} the prompt open in its pane
                             answered with option n: its digit, or for a typed option the text, then Enter
  POST /api/agent/NAME/stop  Esc in the agent's pane, while it is working
  POST /api/paste    an image pasted into the page, or any file picked, kept under ~/.local/state/<project>/pasted for a message to attach
  POST /api/team/start       team/team-start.sh, leaving out a standing agent stopped on its own, then each agent the page stopped is compacted once it is up, and the
                             delivery lead is told the team is back up to start the day
  POST /api/team/stop        the delivery lead is asked to wind the team down, as the owner asks before a shutdown
  POST /api/nudger/pause     the waiting-agents nudger stops nudging until resumed; /api/nudger/resume starts it again
  POST /api/agent/NAME/start team/team-start.sh --only NAME, for an agent outside the developers and testers,
                             compacted once it is up if the page stopped it
  POST /api/agent/NAME/halt  the agent is asked to finish and stop; its pane closes once it has (not the lead's)
  POST /api/agent/NAME/compact  /compact typed into the agent's pane once it is not working
  /api/meetings      every meeting open or ended in the last hour, with what was said (see "meetings")
  /api/daylog        the Day log pane: days and what happened in each, as a program prints them (see "the day log")
  /api/workqueue     the Work queue pane: the work to start, Now, Next and Later, Parked, and Done, as the delivery lead keeps it
  /api/tokens        the Token usage pane: each agent's tokens by day, this week and the two before (see "token usage")
  POST /api/meeting  {"who": [names], "topic", "view"} starts a meeting: a meeting session for each agent in it
  POST /api/meeting/ID/say       {"text"} the owner's line, or meeting-say's {"as", "text", "handover"}
  POST /api/meeting/ID/add|pause|end|handover   bring someone in, pause, end, and send or skip a suggestion

It reads what team/agents-dash.sh reads - agents/roster.json, Claude Code's session records, the context rows
(docs/context-publisher.md), the panel's burn cache and claims board, team/agents-budget.sh - plus tmux for each
agent's pane (the session agent-spawn.sh starts, <project>-<name>) and the tail of each agent's transcript for its
conversation. What it does is type into an agent's pane, as agent-spawn.sh types a first prompt: a message (/say), an
answer to the question open in it (/answer) or Esc (/stop), and start or stop
the team or one of its standing agents (team/team-start.sh to start; a message, and then closing its pane, to
stop; team/team-paused.sh says when a wound-down team has stopped). Only this page can
send: the request must be addressed to this host and port, carry the X-Team-Say header (which another site's page
cannot send without a CORS preflight this server never answers), and, where the browser names an Origin, come from
here. It listens on 127.0.0.1 only: nothing off this machine can reach it.

On a phone (owner, 2026-11-01: "move to the mobile experience") it is reached through a Cloudflare tunnel that runs on
this machine, under a public name, AGENT_WEB_PUBLIC_HOST, behind a Cloudflare Access login. A request under that
name is answered only with Access's signed token for it: signed by AGENT_WEB_ACCESS_TEAM (its
<team>.cloudflareaccess.com), for the Access application AGENT_WEB_ACCESS_AUD, and in date. Without all three set
the name is refused like any other, so a tunnel route made before its Access login opens nothing.
"""
import base64
import calendar
import datetime
import glob
import hashlib
import html
import json
import os
import re
import shlex
import shutil
import stat
import subprocess
import threading
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
# Claude Code's scratchpads (/tmp/claude-<uid>/…/scratchpad), where agents are told to keep their working files.
SCRATCH = os.environ.get("AGENT_SCRATCH_ROOT") or f"/tmp/claude-{os.getuid()}"


def shown_file(real):
    """May the page show this file (a resolved path)? Under the home directory, or under the scratchpad root when that
    root is a real directory of this user's that nobody else can enter (so another user cannot plant one there)."""
    if real.startswith(HOME + os.sep):
        return True
    try:
        st = os.lstat(SCRATCH)
    except OSError:
        return False
    return (real.startswith(SCRATCH + os.sep) and stat.S_ISDIR(st.st_mode) and st.st_uid == os.getuid()
            and not st.st_mode & 0o077)
ROOT = os.environ.get("HARNESS_ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJECT = os.environ.get("HARNESS_PROJECT") or os.path.basename(ROOT)
STATE_DIR = os.path.join(HOME, ".local/state", PROJECT)
WANTED = os.environ.get("AGENT_WANTED_DIR") or os.path.join(STATE_DIR, "wanted")   # team/owner-wanted's flags, by session id
PORT = int(os.environ.get("AGENT_WEB_PORT") or "8787")
PUBLIC_HOST = os.environ.get("AGENT_WEB_PUBLIC_HOST") or ""
ACCESS_TEAM = (os.environ.get("AGENT_WEB_ACCESS_TEAM") or "").removeprefix("https://").split(".")[0]
ACCESS_AUD = os.environ.get("AGENT_WEB_ACCESS_AUD") or ""
ROSTER = os.environ.get("ROSTER_FILE") or os.path.join(ROOT, "agents/roster.json")
# {name: the name the page shows the owner}, for the agent's menu and tooltips only. A name is still one spelling
# everywhere else (the roster's rule), so this file is the page's, and an agent not in it shows its name.
FULL_NAMES = os.environ.get("AGENT_FULL_NAMES") or ""
# {name: how the page spells it}, for a name the roster's characters cannot hold (O’Brian is OBrian). What the page
# shows wherever it writes a name; data attributes, addresses and the agents' own words keep the roster's spelling.
SHOWN_NAMES = os.environ.get("AGENT_SHOWN_NAMES") or ""
BUDGET = os.environ.get("AGENTS_BUDGET") or os.path.join(ROOT, "team/agents-budget.sh")
DAY_BUDGET = os.environ.get("AGENTS_DAY_BUDGET") or os.path.join(ROOT, "team/agents-day-budget.sh")
LEDGER = os.environ.get("AGENTS_DASH_LEDGER") or os.path.join(ROOT, "scripts/ledger-db.sh")
CLAUDE = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
SESSIONS = os.path.join(CLAUDE, "sessions")
PROJECTS = os.path.join(CLAUDE, "projects")
ACTIVITY = os.environ.get("ACTIVITY_DIR") or os.path.join(STATE_DIR, "activity")   # "<state> <epoch>" per session id, from team/activity-hook.sh
CONTEXT_DIR = os.environ.get("CONTEXT_DIR") or os.path.join(STATE_DIR, "context")
CACHE = os.environ.get("AGENTS_DASH_CACHE") or os.path.join(STATE_DIR, "dash")
BURN = os.path.join(CACHE, "burn.json")
BOARD = os.path.join(CACHE, "board")   # the claims board as the panel caches it: id|area|claimed_by
BOARD_EVERY = 60
TEAM_START_SH = os.environ.get("TEAM_START") or os.path.join(ROOT, "team/team-start.sh")   # starts the team, or named agents
TEAM_PAUSED_SH = os.environ.get("TEAM_PAUSED") or os.path.join(ROOT, "team/team-paused.sh")   # exits 0 once it is wound down
TEAM_START_LOG = os.path.join(STATE_DIR, "team-start.log")   # what the page's starts printed
NUDGER_PAUSED = os.path.join(os.path.dirname(CONTEXT_DIR), "waiting-agents.paused")   # the nudger is off while this exists
TEAM_UP = os.path.join(STATE_DIR, "team-up")   # who was running when the page last stopped the team, one a line
STOPPED = os.environ.get("AGENTS_STOPPED") or os.path.join(STATE_DIR, "stopped")   # standing agents stopped one by one from the page, one a line
COMPACT_ON_START = os.path.join(STATE_DIR, "compact-on-start")   # a file per agent the page stopped
STANDING = {"lead", "hot", "ops", "support", "review", "process", "pa"}   # the roles started and stopped one by one; developers and testers come and go with tickets
# (the three chiefs, owner 2026-10-31: Carl development, Vera test, Ed operations; production support is Ed's role until the roster renames it)
SPARK_MINS = 15
TAIL_BYTES = 2_000_000    # how much of a transcript's end is read first for its conversation
TAIL_MAX = 64_000_000     # how far back it is read, four times further each time, while turns are short
# The roster's roles as the page knows them: a short key, the name shown, the section it sits in, and the
# AGENT_COLOUR_<ROLE> default (team/agents-dash.sh role_colour).
ROLES = {"delivery-lead": ("lead", "Delivery Lead", "Lead", "red"),
         "developer": ("dev", "Developer", "Developers", "blue"),
         "tester": ("tester", "Tester", "Testers", "yellow"),
         "head-of-testing": ("hot", "Head of Testing", "Testers", "purple"),
         "code-reviewer": ("review", "Code Reviewer", "Reviewer", "cyan"),
         "production-support": ("support", "Head of Operations", "Others", "orange"),   # Ed's title since 2026-10-31, until the roster renames the role
         "head-of-operations": ("ops", "Head of Operations", "Others", "orange"),   # production support's colour, as Ed carries it over
         "process-improvement": ("process", "Process Improvement", "Others", "pink"),
         "assistant": ("pa", "Assistant", "Others", "green")}
TAB_ORDER = ["Lead", "Developers", "Testers", "Reviewer", "Others"]
# The order agents are listed in, by role, as the panel groups them (agents-dash.sh role_rank, owner 2026-10-26:
# "Lead, Devs, Testers, Reviewer, Test Lead, Support, Improvement, Assistant"); any other role before the assistants.
ROLE_RANK = {"delivery-lead": 0, "developer": 1, "tester": 2, "code-reviewer": 3, "head-of-testing": 4,
             "production-support": 5, "head-of-operations": 5, "process-improvement": 6, "assistant": 9}
# Claude Code's /color names as the 256-colour shades it draws them in (agents-dash.sh role_colour)
CC_COLOUR = {"red": 167, "green": 35, "yellow": 178, "blue": 110, "cyan": 37, "pink": 175,
             "purple": 141, "orange": 209}

BASIC = ["#1b1e24", "#e5534b", "#57ab5a", "#c69026", "#539bf5", "#b083f0", "#39c5cf", "#d1d7e0",
         "#636e7b", "#ff938a", "#6bc46d", "#daaa3f", "#6cb6ff", "#dcbdfb", "#56d4dd", "#f0f6fc"]
FG, BG = "#d1d7e0", "#0d1117"


def xterm(n):
    """The hex colour of 256-colour index n."""
    if n < 16:
        return BASIC[n]
    if n < 232:
        n -= 16
        steps = [0, 95, 135, 175, 215, 255]
        return "#%02x%02x%02x" % (steps[n // 36], steps[n // 6 % 6], steps[n % 6])
    v = 8 + (n - 232) * 10
    return "#%02x%02x%02x" % (v, v, v)


# ── the pane on screen, ANSI to HTML ──────────────────────────────────────────
def sgr(st, params):
    codes = [int(p) if p.isdigit() else 0 for p in params.replace(":", ";").split(";")] if params else [0]
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:
            st.update(fg=None, bg=None, bold=False, dim=False, inv=False, it=False)
        elif c == 1:
            st["bold"] = True
        elif c == 2:
            st["dim"] = True
        elif c == 3:
            st["it"] = True
        elif c == 22:
            st.update(bold=False, dim=False)
        elif c == 23:
            st["it"] = False
        elif c == 7:
            st["inv"] = True
        elif c == 27:
            st["inv"] = False
        elif 30 <= c <= 37:
            st["fg"] = BASIC[c - 30]
        elif 90 <= c <= 97:
            st["fg"] = BASIC[c - 82]
        elif c == 39:
            st["fg"] = None
        elif 40 <= c <= 47:
            st["bg"] = BASIC[c - 40]
        elif 100 <= c <= 107:
            st["bg"] = BASIC[c - 92]
        elif c == 49:
            st["bg"] = None
        elif c in (38, 48) and i + 1 < len(codes):
            key = "fg" if c == 38 else "bg"
            if codes[i + 1] == 5 and i + 2 < len(codes):
                st[key] = xterm(codes[i + 2])
                i += 2
            elif codes[i + 1] == 2 and i + 4 < len(codes):
                st[key] = "#%02x%02x%02x" % tuple(min(255, v) for v in codes[i + 2:i + 5])
                i += 4
        i += 1


def spelled_screen(text, names):
    """Terminal text with each {name: spelling} written as spelled, where an agent means the person. A URL, a path and a
    name run into a longer word (strength-Ada, --to=Ada, Ada@host) are what a machine reads, so they keep the roster's."""
    for name, spelling in names.items():
        hit = rf"https?://\S+|(?<![\w.])[~/]\S+|(?<![\w./=-]){re.escape(name)}(?![\w/@=-])"
        text = re.sub(hit, lambda m, name=name, spelling=spelling: spelling if m.group(0) == name else m.group(0), text)
    return text


def ansi_html(text, names=None):
    """Terminal text with SGR colours as escaped HTML spans; any other escape sequence is dropped. A run of one colour is
    spelled whole, so the escape before a coloured name cannot hide it."""
    out, buf = [], []
    st = dict(fg=None, bg=None, bold=False, dim=False, inv=False, it=False)

    def flush():
        if not buf:
            return
        fg, bg = st["fg"], st["bg"]
        if st["inv"]:
            fg, bg = bg or BG, fg or FG
        css = ([f"color:{fg}"] if fg else []) + ([f"background:{bg}"] if bg else [])
        css += ["font-weight:600"] if st["bold"] else []
        css += ["opacity:.55"] if st["dim"] else []
        css += ["font-style:italic"] if st["it"] else []
        t = html.escape(spelled_screen("".join(buf), names or {}))
        out.append(f'<span style="{";".join(css)}">{t}</span>' if css else t)
        buf.clear()

    i = 0
    while i < len(text):
        ch = text[i]
        if ch == "\x1b" and text[i + 1:i + 2] == "[":
            j = i + 2
            while j < len(text) and not ("@" <= text[j] <= "~"):
                j += 1
            flush()
            if j < len(text) and text[j] == "m":
                sgr(st, text[i + 2:j])
            i = j + 1
            continue
        if ch == "\x1b":
            i += 2
            continue
        buf.append(ch)
        i += 1
    flush()
    return "".join(out)


# ── where the numbers come from ───────────────────────────────────────────────
def run(*cmd, timeout=5):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def setting(name):
    """A harness.env setting: team/agents-web.sh exports the file before the server starts."""
    return os.environ.get(name, "").strip()


def roster():
    """The active agents in the roster's order, then its assistants: name, role id and address."""
    try:
        with open(ROSTER) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return []
    rows = [{"name": a["name"], "role": a.get("role", ""), "email": (a.get("email") or "").lower()}
            for a in data.get("agents") or [] if a.get("status") == "active" and a.get("name")]
    rows += [{"name": a["name"], "role": "assistant", "email": (a.get("email") or "").lower()}
             for a in data.get("assistants") or [] if a.get("name")]
    full = full_names()
    for r in rows:
        r["fullName"] = full.get(r["name"], r["name"])
    return rows


def full_names():
    return name_file(FULL_NAMES)


def shown_names():
    return name_file(SHOWN_NAMES)


def name_file(path):
    """A file of {name: spelling}; empty when it is unset, unreadable or not an object, and only non-empty strings
    count, so a slip in that file leaves the page showing short names."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return {k: v for k, v in data.items() if isinstance(v, str) and v.strip()} if isinstance(data, dict) else {}


def team_roster():
    """The roster without its assistants, who are not on the team: the team's start and stop leave them alone."""
    return [r for r in roster() if r["role"] != "assistant"]


def grouped(rows):
    """Roster rows grouped by role in ROLE_RANK's order, file order kept within a role. A roster appends each new
    agent at the end, so in file order a new developer drew after the testers. roster() stays in file order."""
    return sorted(rows, key=lambda r: ROLE_RANK.get(r["role"], 8))


def role_of(role):
    """(key, name shown, section, default colour) for a roster role id."""
    return ROLES.get(role, (role[:7] or "other", role.replace("-", " ").title(), "Others", ""))


def proc_email(pid):
    """GIT_AUTHOR_EMAIL in a process's environment, which says whose session it is, or "" where it cannot be read."""
    try:
        with open(f"/proc/{pid}/environ", "rb") as f:
            for kv in f.read().split(b"\0"):
                if kv.startswith(b"GIT_AUTHOR_EMAIL="):
                    return kv[17:].decode(errors="replace").lower()
    except OSError:
        pass
    return ""


def pid_since(pid, started_ms):
    """True when the process started no later than its session did, a minute's grace (team/lib/agent-session.sh):
    Claude Code leaves a crashed session's record behind, and a process that took its pid over started after it."""
    started = proc_started(pid)
    return bool(started and started_ms) and started <= started_ms / 1000 + 60


def claude_for(pid, sid, name):
    """True when the process is Claude Code resuming that session's conversation (--resume <id>) or named for the agent
    (--name/-n <name>), as agent-spawn.sh starts it: the session's own whatever its start time reads
    (team/lib/agent-session.sh). Read from /proc, as proc_started is."""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            argv = f.read().decode(errors="replace").split("\0")
    except OSError:
        return False
    at = next((i for i, a in enumerate(argv) if os.path.basename(a) == "claude"), None)
    if at is None:
        return False
    pairs = set(zip(argv[at + 1:], argv[at + 2:]))
    return bool(sid) and ("--resume", sid) in pairs or bool(name) and bool({("--name", name), ("-n", name)} & pairs)


def proc_started(pid):
    """When a process started, in epoch seconds, read from /proc, or None when it cannot be read. Not ps: ps reads every
    process on the box, which on a busy one (thousands, with agent stacks up) took 50-500 ms a call, once per session
    on every request."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            ticks = int(f.read().rsplit(")", 1)[1].split()[19])   # field 22, starttime, in clock ticks since boot
        with open("/proc/stat") as f:
            boot = next(int(line.split()[1]) for line in f if line.startswith("btime "))
    except (OSError, ValueError, IndexError, StopIteration):
        return None
    return boot + ticks / os.sysconf("SC_CLK_TCK")


def wanted(sid):
    """The line owner-wanted left for this session, and the flag's age in seconds; (None, None) when it has none."""
    path = os.path.join(WANTED, sid)
    try:
        with open(path) as f:
            line = f.readline().strip()
        return (line or "wants you"), max(0, int(time.time() - os.path.getmtime(path)))
    except (OSError, ValueError):
        return None, None


def live_sessions():
    """Roster name -> Claude Code's own record of the session, for every session whose process and socket are live.
    A session is the agent whose roster address its process carries in GIT_AUTHOR_EMAIL, else the one its record is
    named, and only while its process is the session's own: Claude Code started for it, or else started no later than
    the session did (team/lib/agent-session.sh). An agent's meeting session, its record named "<Agent> · meeting", is
    keyed by that name (meeting_session)."""
    people = roster()
    by_email = {r["email"]: r["name"] for r in people if r["email"]}
    by_name = {r["name"].lower(): r["name"] for r in people}
    best = {}
    for f in glob.glob(os.path.join(SESSIONS, "*.json")):
        try:
            pid = int(os.path.basename(f)[:-5])
            os.kill(pid, 0)
            with open(f) as fh:
                rec = json.load(fh)
        except (ValueError, OSError, json.JSONDecodeError):
            continue
        sock, email = rec.get("messagingSocketPath"), proc_email(pid)
        name = by_email.get(email) if email else by_name.get((rec.get("name") or "").lower())
        said = rec.get("name") or ""
        if said.endswith(MEETING_SUFFIX) and said[:-len(MEETING_SUFFIX)].lower() in by_name:   # a meeting session is its own
            name = meeting_session(by_name[said[:-len(MEETING_SUFFIX)].lower()])
        if not name or not sock or not os.path.exists(sock) \
                or not (claude_for(pid, rec.get("sessionId"), name) or pid_since(pid, rec.get("startedAt"))):
            continue
        at = rec.get("statusUpdatedAt") or rec.get("updatedAt") or 0
        _socket_names[sock] = name
        if name not in best or at > best[name][0]:
            best[name] = (at, rec)
    return {n: r for n, (_, r) in best.items()}


_last = {}   # session record path -> (mtime, name, session id, when it last changed)


def last_sessions():
    """Name -> the session id of its newest session, running or not, from Claude Code's records (kept after a session
    ends); each record is read again only when it changes."""
    seen, best = set(), {}
    for f in glob.glob(os.path.join(SESSIONS, "*.json")):
        seen.add(f)
        try:
            m = os.stat(f).st_mtime
            if _last.get(f, (None,))[0] != m:
                with open(f) as fh:
                    rec = json.load(fh)
                _last[f] = (m, rec.get("name"), rec.get("sessionId"), rec.get("updatedAt") or rec.get("statusUpdatedAt") or 0)
        except (OSError, ValueError, json.JSONDecodeError):
            continue
    for f in set(_last) - seen:
        del _last[f]
    for _, name, sid, at in _last.values():
        if name and sid and (name not in best or at > best[name][0]):
            best[name] = (at, sid)
    return {n: sid for n, (_, sid) in best.items()}


def context_rows():
    rows = {}
    for f in glob.glob(os.path.join(CONTEXT_DIR, "*.json")):
        try:
            with open(f) as fh:
                r = json.load(fh)
            r["_ts"] = time.mktime(time.strptime(r.get("ts", ""), "%Y-%m-%dT%H:%M:%SZ")) - time.timezone
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        if r.get("session_id"):
            rows[r["session_id"]] = r
    return rows


def account_pct(rows, key):
    """The highest used % among the rows written within a minute of the freshest (agents-dash.sh week_used)."""
    vals = [(r["_ts"], (r.get(key) or {}).get("used_pct")) for r in rows.values()]
    vals = [(t, v) for t, v in vals if v is not None]
    if not vals:
        return None
    fresh = max(t for t, _ in vals)
    return max(v for t, v in vals if t >= fresh - 60)


def burn():
    try:
        with open(BURN) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def series(entry, now):
    cur = int(now // 60)
    b = (entry or {}).get("buckets") or {}
    return [int(b.get(str(m), 0)) for m in range(cur - SPARK_MINS + 1, cur + 1)]


def last_minute(ser, now):
    """Tokens in the last 60 s: this minute so far plus the part of last minute still inside it."""
    return int(ser[-1] + ser[-2] * (60 - now % 60) / 60) if len(ser) > 1 else 0


_board = {"at": 0, "busy": False}


# ── the day log ─────────────────────────────────────────────────────────────────────────────────────────────────
# The Day log pane: days, and what happened in each, newest first. The page only draws it. Its rows come from a
# program, AGENTS_DAY_LOG (else team/day-log.py, the harness's own), run in the background every DAY_LOG_EVERY seconds
# so a slow source never holds the page. The program is given {"days": DAY_LOG_DAYS} on stdin, the window it is asked
# to cover, and prints one JSON object:
#   {"rows": [row, ...], "summary": the header's words, "note": a line above the rows, "empty": said when no rows,
#    "kinds": {kind: {"name": "Released", "about": "A sentence."}} for a kind the page has no words for}
# where a row is
#   {"at": epoch seconds, "type": "day" (a day's heading) or "entry", "kind": a word for its icon and colour (a day with none shows its text alone),
#    "by": who (a roster name gets their badge's colour), "text": what happened,
#    "url": an http(s) link, "label": the link's words}
# Only "at" and "type" are needed. A row that breaks these rules is left out and the text is cut short. A program that
# exits non-zero says why on stderr: the pane keeps what it last had and says the program failed.
DAY_LOG_DAYS = 7
DAY_LOG_EVERY = 120
DAY_LOG_ROWS = 1000
DAY_LOG_FIRST_WAIT = 5   # seconds the first request waits for the first reading before saying it is still reading
DAY_LOG_PROGRAM = os.path.join(ROOT, "team", "day-log.py")
_daylog = {"at": 0, "busy": False, "data": None, "error": "", "thread": None}


def day_log_program():
    return setting("AGENTS_DAY_LOG") or DAY_LOG_PROGRAM


def day_log_clean(data):
    """A program's output kept to the shape above, each string bounded; raises ValueError when it is not that shape."""
    if not isinstance(data, dict) or not isinstance(data.get("rows"), list):
        raise ValueError("printed no rows")
    text = lambda v, n=300: v.strip()[:n] if isinstance(v, str) else ""
    rows = []
    for r in data["rows"][:DAY_LOG_ROWS]:
        if not isinstance(r, dict) or r.get("type") not in ("day", "entry") or isinstance(r.get("at"), bool) \
                or not isinstance(r.get("at"), (int, float)):
            continue
        url = text(r.get("url"), 500)
        rows.append({"at": r["at"], "type": r["type"], "kind": re.sub(r"[^\w-]", "", text(r.get("kind"), 40)),
                     "by": text(r.get("by"), 60), "text": text(r.get("text")),
                     "url": url if re.match(r"https?://", url) else "", "label": text(r.get("label"), 40)})
    kinds = data.get("kinds") if isinstance(data.get("kinds"), dict) else {}
    kinds = {re.sub(r"[^\w-]", "", k)[:40]: {"name": text(v.get("name"), 60), "about": text(v.get("about"))}
             for k, v in list(kinds.items())[:50] if isinstance(v, dict)}
    return {"rows": rows, "kinds": kinds, "summary": text(data.get("summary"), 120), "note": text(data.get("note")),
            "empty": text(data.get("empty"), 120)}


def refresh_day_log(program):
    try:
        p = subprocess.run([program], capture_output=True, text=True, timeout=90, cwd=os.path.dirname(program),
                           input=json.dumps({"days": DAY_LOG_DAYS}))
        if p.returncode:
            raise ValueError((p.stderr.strip() or f"exit {p.returncode}").splitlines()[-1][:200])
        try:
            data = json.loads(p.stdout)
        except ValueError:
            raise ValueError("printed something that is not JSON")
        _daylog.update(data=day_log_clean(data), error="")
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        _daylog["error"] = str(e) or "failed"
    _daylog.update(at=time.time(), busy=False)


def daylog_json():
    program = day_log_program()
    if not os.access(program, os.X_OK):
        return json.dumps({"state": "unset", "program": program, "rows": []}).encode()
    if not _daylog["busy"] and time.time() - _daylog["at"] > DAY_LOG_EVERY:
        _daylog["busy"] = True
        _daylog["thread"] = threading.Thread(target=refresh_day_log, args=(program,), daemon=True)
        _daylog["thread"].start()
    first = _daylog["thread"]
    if _daylog["data"] is None and first:
        first.join(DAY_LOG_FIRST_WAIT)   # the first reading: a quick program is answered at once
    data = _daylog["data"] or {"rows": []}
    names = shown_names()
    # The page's colours go by the roster's spelling; a row is signed with the short name, often spelled otherwise
    # ("O’Brian" for OBrian), or with the shown one. So a name matches on its letters alone, case aside.
    letters = lambda s: re.sub(r"[\W_]", "", s).lower()
    roster_name = {letters(k): k for k in names}
    roster_name.update({letters(v): k for k, v in names.items()})
    rows = [{**r, "by": roster_name.get(letters(r["by"]), r["by"]) if isinstance(r.get("by"), str) else r.get("by"), "text": spelled_screen(r["text"], names)} for r in data["rows"]]
    state = "failed" if _daylog["error"] else "reading" if _daylog["data"] is None else "ok"
    return json.dumps({**data, "rows": rows, "state": state, "error": _daylog["error"]}).encode()

# ── token usage ─────────────────────────────────────────────────────────────────────────────────────────────────
# The Token usage pane (owner, 2026-11-11): each agent's tokens by day, from every conversation whose name (its
# customTitle, as restore-claude.sh reads it) is the agent's, with the messages it sent (SendMessage calls). Each API
# response counts once, by its request id. Weighted is in input-token units at the API's relative prices (cache write
# 1.25x, cache read 0.1x, output 5x), so agents and days compare on one number. Days are UTC, as the transcripts are,
# from the Monday TOKENS_WEEKS - 1 weeks before this week's to today; the pane draws a box for each week.
# Each file is read once and then only from where it was last read, in a thread every TOKENS_EVERY seconds, so the
# first read of every transcript is the only slow one; files not written in the window are not read at all.
TOKENS_WEEKS = 3   # this week and the two before it, Monday to Sunday
TOKENS_EVERY = 60
TOKEN_TITLE = re.compile(r'"customTitle":"/?([^"]*)"')
_tokens = {"at": 0, "busy": False, "data": None, "files": {}}


def token_file(path, size, known):
    """A transcript's totals so far, read on from where `known` stopped: {title, off, seen, days: {day: [fresh in,
    cache write, cache read, out, calls, sent]}}. A file that shrank is read again from the start."""
    if not known or size < known["off"]:
        known = {"title": "", "off": 0, "seen": set(), "days": {}}
    with open(path, "rb") as f:
        f.seek(known["off"])
        data = f.read(size - known["off"])
    end = data.rfind(b"\n") + 1   # a line still being written is read next time
    for raw in data[:end].splitlines():
        line = raw.decode("utf-8", "replace")
        t = TOKEN_TITLE.findall(line)
        if t:
            known["title"] = t[-1]
        if '"assistant"' not in line:
            continue
        try:
            e = json.loads(line)
        except ValueError:
            continue
        msg = e.get("message") or {}
        if e.get("type") != "assistant" or not isinstance(msg, dict):
            continue
        d = known["days"].setdefault((e.get("timestamp") or "")[:10], [0] * 6)
        d[5] += sum(1 for b in msg.get("content") or [] if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "SendMessage")
        u, key = msg.get("usage"), e.get("requestId") or msg.get("id")
        if not u or key in known["seen"]:
            continue
        known["seen"].add(key)
        d[0] += u.get("input_tokens") or 0; d[1] += u.get("cache_creation_input_tokens") or 0
        d[2] += u.get("cache_read_input_tokens") or 0; d[3] += u.get("output_tokens") or 0; d[4] += 1
    known["off"] += end
    return known


def refresh_tokens():
    try:
        today = datetime.datetime.now(datetime.timezone.utc).date()
        first = today - datetime.timedelta(days=today.weekday() + 7 * (TOKENS_WEEKS - 1))
        days = [(first + datetime.timedelta(days=i)).isoformat() for i in range((today - first).days + 1)]
        start = time.time() - (len(days) + 1) * 86400
        files = _tokens["files"]
        for path in glob.glob(os.path.join(PROJECTS, "*", "*.jsonl")):
            try:
                st = os.stat(path)
            except OSError:
                continue
            if st.st_mtime < start or (path in files and files[path]["off"] == st.st_size):
                continue
            try:
                files[path] = token_file(path, st.st_size, files.get(path))
            except OSError:
                pass
        team = [r["name"] for r in roster()]
        per = {n: {} for n in team}
        for k in files.values():
            if k["title"] in per:
                for day, v in k["days"].items():
                    if day >= days[0]:
                        cell = per[k["title"]].setdefault(day, [0] * 6)
                        for i in range(6):
                            cell[i] += v[i]
        weigh = lambda v: round(v[0] + 1.25 * v[1] + 0.1 * v[2] + 5 * v[3])
        agents = [{"name": n, "days": {d: {"w": weigh(v), "calls": v[4], "sent": v[5], "in": v[0], "cw": v[1], "cr": v[2], "out": v[3]}
                                       for d, v in per[n].items()}} for n in team if per[n]]
        _tokens["data"] = {"days": days, "agents": agents}
    finally:
        _tokens.update(at=time.time(), busy=False)


def tokens_json():
    if not _tokens["busy"] and time.time() - _tokens["at"] > TOKENS_EVERY:
        _tokens["busy"] = True
        threading.Thread(target=refresh_tokens, daemon=True).start()
    return json.dumps({**(_tokens["data"] or {"days": [], "agents": []}), "state": "ok" if _tokens["data"] else "reading"}).encode()



# ── the work queue ──────────────────────────────────────────────────────────────────────────────────────────────
# The Work queue pane: the work the team means to start, Now, Next and Later, what is Parked, and what is Done, as
# the delivery lead keeps it with team/work-queue.py (see that command for the file's shape). The page draws the file;
# nothing here fills it. It is $AGENT_WORK_QUEUE, else work-queue.json in the state directory, read again only when it
# changes.
WORK_QUEUE = os.environ.get("AGENT_WORK_QUEUE") or os.path.join(STATE_DIR, "work-queue.json")
WORK_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.#/-]{0,254}$")   # as team/work-queue.py takes an id
_workqueue = {"key": None, "data": None}
# The Done tab splits by stand-up: the times the stand-ups were read, from a stand-up log's day headings
# ("# Stand-up, Tuesday 10 November 2026 (FINAL, 09:10Z)"; a FINAL with no time counts as 09:15Z). The log is
# $AGENT_STANDUPS, else standups.md in the state directory, read again only when it changes; with none, Done is one list.
STANDUPS = os.environ.get("AGENT_STANDUPS") or os.path.join(STATE_DIR, "standups.md")
STANDUP_LINE = re.compile(r"^# Stand-up, \w+ (\d{1,2} \w+ \d{4}) \(FINAL(?:, (\d{2}:\d{2})Z)?\)", re.M)
_standups = {"key": None, "times": []}


def standup_times():
    path = STANDUPS
    try:
        st = os.stat(path)
        key = (path, st.st_mtime_ns, st.st_size)
        if key != _standups["key"]:
            with open(path, encoding="utf-8") as f:
                log = f.read()
            times = set()
            for day, hhmm in STANDUP_LINE.findall(log):
                try:
                    times.add(calendar.timegm(time.strptime(f"{day} {hhmm or '09:15'}", "%d %B %Y %H:%M")))
                except ValueError:
                    continue
            _standups.update(key=key, times=sorted(times, reverse=True))
    except OSError:
        return []
    return _standups["times"]


def workqueue_json():
    path = WORK_QUEUE
    try:
        st = os.stat(path)
        key = (path, st.st_mtime_ns, st.st_size)
    except OSError:
        return json.dumps({"state": "empty", "file": path, "now": [], "next": [], "later": [], "parked": [], "done": [],
                           "standups": standup_times()[:10]}).encode()
    if key != _workqueue["key"]:
        try:
            with open(path, encoding="utf-8") as f:
                q = json.load(f)
            if not isinstance(q, dict):
                raise ValueError
            text = lambda v, n=200: v.strip()[:n] if isinstance(v, str) else ""
            names = shown_names()
            letters = lambda s: re.sub(r"[\W_]", "", s).lower()
            roster_name = {letters(k): k for k in names}
            roster_name.update({letters(v): k for k, v in names.items()})
            lists = {}
            stamp = lambda v: v if isinstance(v, (int, float)) and not isinstance(v, bool) else 0
            for name in ("now", "next", "later", "parked", "done"):
                items = q.get(name) if isinstance(q.get(name), list) else []
                lists[name] = [{"key": k, "title": text(i.get("title")), "note": text(i.get("note")), "fix": text(i.get("fix")),
                                "who": roster_name.get(letters(text(i.get("who"), 60)), text(i.get("who"), 60)),
                                "url": u if re.match(r"https?://", u) else "", "done": stamp(i.get("done"))}
                               for i in items[:100] if isinstance(i, dict)
                               for k, u in [(text(i.get("key"), 255), text(i.get("url"), 500))] if WORK_ID.match(k)]
            data = {"state": "ok", "file": path, **lists, "by": text(q.get("by"), 60),
                    "at": stamp(q.get("at"))}
        except (OSError, ValueError):
            data = {"state": "bad", "file": path, "now": [], "next": [], "later": [], "parked": [], "done": []}
        _workqueue.update(key=key, data=data)
    return json.dumps({**_workqueue["data"], "standups": standup_times()[:10]}).encode()


def refresh_board():
    out = run("bash", LEDGER, "board", timeout=30)
    if out.strip():
        os.makedirs(CACHE, exist_ok=True)
        with open(BOARD + ".tmp", "w") as f:
            f.write(out)
        os.replace(BOARD + ".tmp", BOARD)
    _board["busy"] = False


def claims():
    """Lower-case name -> the first ticket it holds on the claims board, read from the panel's cache; once that is
    BOARD_EVERY seconds old one read of the ledger starts in the background, so a page never waits for it."""
    try:
        age = time.time() - os.path.getmtime(BOARD)
    except OSError:
        age = BOARD_EVERY
    if age >= BOARD_EVERY and not _board["busy"] and os.path.exists(LEDGER):
        _board["busy"] = True
        threading.Thread(target=refresh_board, daemon=True).start()
    held = {}
    try:
        with open(BOARD) as f:
            for line in f:
                parts = line.rstrip("\n").split("|")
                who = parts[2].split()[0].lower() if len(parts) > 2 and parts[2].split() else ""
                if who and who != "-" and parts[0]:
                    held.setdefault(who, parts[0])
    except OSError:
        pass
    return held


def budget_plan():
    m = re.search(r" of (\d+)% planned", run(BUDGET))
    return int(m.group(1)) if m else None


def day_budget():
    """The day open now (team/agents-day-budget.sh), as {"used", "quota", "from"}: the points the day has spent, its
    share and the week's reading when it started, plus "nostop" on a verification day, which nothing stops at its share. Between days it counts
    from the last day's end, its share what the week's plan has grown by since (None with no plan). None otherwise:
    the week's even pacing applies."""
    out = run("bash", DAY_BUDGET)
    if m := re.search(r"^day  (?:on|over): (\d+)% of the day's (\d+)% used \(week \d+%, from (\d+)%.*$", out, re.M):
        day = dict(zip(("used", "quota", "from"), map(int, m.groups())))
        return {**day, "nostop": True} if m[0].endswith(": verification day, nothing stops at it") else day
    if m := re.search(r"^day  none: between days since .+?: (\d+)%(?: of the plan's (\d+)%)? used \(week \d+%, from (\d+)%", out, re.M):
        return {"used": int(m[1]), "quota": int(m[2]) if m[2] else None, "from": int(m[3])}
    return None


def even_plan(plan):
    """The plan with the week's contingency spread over the working hours too: the whole allowance shared out evenly.
    The working week plans AGENT_WEEK_PCT_PER_HOUR for each of its hours, and what it leaves of 100% is
    contingency; a week between the plan and this is spending it."""
    try:
        a, b = [int(h) * 60 + int(m) for h, m in re.findall(r"(\d+):(\d+)", setting("AGENT_WORK_HOURS"))]
        total = float(setting("AGENT_WEEK_PCT_PER_HOUR")) * (b - a) / 60 * len(setting("AGENT_WORK_DAYS").split())
    except ValueError:
        return None
    return round(plan * 100 / total, 1) if plan is not None and 0 < total < 100 else None


def disk():
    path = setting("AGENT_DISK_WATCH")
    if not path:
        return None
    label = path[5:].upper() + ":" if re.fullmatch(r"/mnt/[a-z]", path) else path
    try:
        u = shutil.disk_usage(path)
    except OSError:
        return {"label": label, "free_gb": None}
    return {"label": label, "free_gb": u.free // 2**30, "total_gb": u.total // 2**30,
            "warn": int(os.environ.get("AGENTS_DASH_DISK_WARN", "40")),
            "alert": int(os.environ.get("AGENTS_DASH_DISK_ALERT", "20"))}


# The machine's performance for Performance panes (/api/perf), as Task Manager shows it: CPU, memory, each disk's
# space and the disks' activity, each network interface and each GPU, every PERF_STEP seconds with the last
# PERF_KEEP readings for the lines under them, and for the enlarged graph (/api/perf/history) every reading of the last
# hour and each minute's average over the last day. Linux reads /proc (under WSL, the WSL machine's own figures, which is
# where the agents run, not Windows'), and nvidia-smi, else an AMD card's /sys figures, for the GPU; macOS reads one
# long-running top for the CPU and the disks' activity, sysctl for memory, netstat for the network and ioreg for the
# GPU. The sampling starts with the first request and then runs for as long as the page does, so the history is there
# whenever a graph is opened, while a page that never shows the figures costs nothing. nvidia-smi is run once after another in a thread of its own: a run takes seconds
# (four or five under WSL), and its own loop (-l) reports the GPU's use only on its first line under WSL.
PERF_STEP, PERF_KEEP = 10, 60
PERF_SPANS = (120, 600, 3600, 86400)   # the enlarged graph's timescales: every reading up to an hour, minutes beyond
MAC = os.uname().sysname == "Darwin"
NVIDIA_SMI = shutil.which("nvidia-smi") or ("/usr/lib/wsl/lib/nvidia-smi" if os.access("/usr/lib/wsl/lib/nvidia-smi", os.X_OK) else None)
WHOLE_DISK = re.compile(r"(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme\d+n\d+|mmcblk\d+)")
VIRTUAL_NET = re.compile(r"lo|lo0|docker\d*|veth.*|br-.*|virbr.*|cni.*|flannel.*|vxlan.*|tailscale.*|utun\d*|awdl\d*|llw\d*|gif\d*|stf\d*|anpi\d*|ap\d*|bridge\d*")
_perf = {"running": False, "now": None, "hist": {}}
_perf_long, _perf_mins = {}, {}   # per series: [time, value] for the last hour; [minute, sum, count] for the last day
_perf_lock = threading.Lock()
_children = {}   # the long-running nvidia-smi and (macOS) top, with the last reading each printed


def proc_cpu(text):
    """/proc/stat's first line as (busy, total) jiffies: idle and iowait are not busy."""
    f = [int(x) for x in text.split("\n", 1)[0].split()[1:9]]
    return sum(f) - f[3] - f[4], sum(f)


def proc_mem(text):
    """/proc/meminfo as bytes: used is what is not available, as Task Manager's In use; swap as Linux reports it."""
    kb = {k: int(v.split()[0]) * 1024 for k, v in (line.split(":", 1) for line in text.splitlines() if ":" in line)}
    return {"total": kb.get("MemTotal", 0), "used": kb.get("MemTotal", 0) - kb.get("MemAvailable", 0),
            "cached": kb.get("Cached", 0), "swap_total": kb.get("SwapTotal", 0),
            "swap_used": kb.get("SwapTotal", 0) - kb.get("SwapFree", 0)}


def proc_disks(text):
    """/proc/diskstats' whole disks (not partitions) as {name: (bytes read, bytes written, ms busy)}."""
    out = {}
    for line in text.splitlines():
        f = line.split()
        if len(f) >= 13 and WHOLE_DISK.fullmatch(f[2]):
            out[f[2]] = (int(f[5]) * 512, int(f[9]) * 512, int(f[12]))
    return out


def proc_net(text):
    """/proc/net/dev's real interfaces (not loopback, Docker's or VPN tunnels) as {name: (bytes in, bytes out)}."""
    out = {}
    for line in text.splitlines()[2:]:
        name, _, rest = line.partition(":")
        f, name = rest.split(), name.strip()
        if len(f) >= 9 and not VIRTUAL_NET.fullmatch(name):
            out[name] = (int(f[0]), int(f[8]))
    return out


def smi_line(line):
    """One line of nvidia-smi's CSV (index, name, utilization %, memory used MiB, memory total MiB, temperature)."""
    f = [x.strip() for x in line.split(",")]
    if len(f) < 6 or not f[0].isdigit():
        return None
    num = lambda x: float(x) if re.fullmatch(r"[\d.]+", x) else None
    mib = lambda x: num(x) * 2**20 if num(x) is not None else None
    return {"id": f[0], "name": f[1], "pct": num(f[2]), "mem_used": mib(f[3]), "mem_total": mib(f[4]), "temp": num(f[5])}


def mac_size(text):
    """top's sizes ("123M", "4567K", "1.2G", "890B") as bytes."""
    m = re.fullmatch(r"([\d.]+)([BKMGT]?)", text.strip())
    return float(m[1]) * 1024 ** "BKMGT".index(m[2] or "B") if m else None


def mac_top(block):
    """One sample of `top -l 0 -n 0`: CPU busy %, and the disks' bytes read and written since boot."""
    out = {}
    if m := re.search(r"CPU usage: [\d.]+% user, [\d.]+% sys, ([\d.]+)% idle", block):
        out["cpu"] = round(100 - float(m[1]), 1)
    if m := re.search(r"Disks: \d+/(\S+) read, \d+/(\S+) written", block):
        out["disk"] = (mac_size(m[1]), mac_size(m[2]))
    return out


def mac_mem(memsize, vm_stat, swapusage):
    """sysctl hw.memsize, vm_stat and sysctl vm.swapusage as bytes. Used is Activity Monitor's Memory Used: app
    memory (anonymous pages less purgeable) plus wired and compressed."""
    page = int(m[1]) if (m := re.search(r"page size of (\d+) bytes", vm_stat)) else 4096
    pages = {k.strip().strip('"'): int(v.strip().rstrip(".")) for k, v in
             (line.split(":", 1) for line in vm_stat.splitlines()[1:] if ":" in line) if v.strip().rstrip(".").isdigit()}
    app = pages.get("Anonymous pages", 0) - pages.get("Pages purgeable", 0)
    used = (app + pages.get("Pages wired down", 0) + pages.get("Pages occupied by compressor", 0)) * page
    swap = dict(re.findall(r"(total|used) = ([\d.]+[BKMGT]?)", swapusage))
    return {"total": int(memsize), "used": used, "cached": pages.get("File-backed pages", 0) * page,
            "swap_total": mac_size(swap.get("total", "0")) or 0, "swap_used": mac_size(swap.get("used", "0")) or 0}


def mac_net(netstat):
    """`netstat -ib`'s real interfaces as {name: (bytes in, bytes out)}, from each one's link row."""
    out = {}
    lines = netstat.splitlines()
    head = lines[0].split() if lines else []
    if "Ibytes" not in head:
        return out
    ib, ob = head.index("Ibytes"), head.index("Obytes")
    for line in lines[1:]:
        f = line.split()
        # a link row's Network is <Link#n>; an interface with no address has one column fewer, which leaves Ibytes
        # and Obytes counted from the end the same
        if len(f) < 7 or not f[2].startswith("<Link#") or VIRTUAL_NET.fullmatch(f[0].rstrip("*")) or f[0] in out:
            continue
        shift = len(head) - len(f)
        try:
            out[f[0].rstrip("*")] = (int(f[ib - shift]), int(f[ob - shift]))
        except (ValueError, IndexError):
            pass
    return out


def mac_gpu(ioreg):
    """`ioreg -r -d 1 -w 0 -c IOAccelerator`: each GPU's name and Device Utilization %."""
    out = []
    for i, part in enumerate(re.split(r"\n(?=\+-o )", ioreg.strip())):
        if m := re.search(r'"Device Utilization %"=(\d+)', part):
            name = re.search(r'"model"\s*=\s*"([^"]+)"', part)
            used = re.search(r'"In use system memory"=(\d+)', part)
            out.append({"id": str(i), "name": name[1] if name else "GPU", "pct": float(m[1]),
                        "mem_used": float(used[1]) if used else None, "mem_total": None, "temp": None})
    return out


def amd_gpus():
    """An AMD card's /sys figures, for a Linux machine with no nvidia-smi."""
    out = []
    for dev in sorted(glob.glob("/sys/class/drm/card[0-9]*/device")):
        try:
            with open(dev + "/gpu_busy_percent") as f:
                pct = float(f.read())
        except (OSError, ValueError):
            continue
        def num(name):
            try:
                with open(dev + "/" + name) as f:
                    return float(f.read())
            except (OSError, ValueError):
                return None
        out.append({"id": os.path.basename(os.path.dirname(dev)), "name": "GPU", "pct": pct,
                    "mem_used": num("mem_info_vram_used"), "mem_total": num("mem_info_vram_total"), "temp": None})
    return out


def read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""


def child_lines(key, cmd, on_line):
    """Run cmd for as long as Performance panes are asked for, handing each line it prints to on_line."""
    try:
        p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL, text=True)
    except OSError:
        return
    _children[key] = p
    for line in p.stdout:
        if _children.get(key) is p:   # a process told to stop says nothing more
            on_line(line)
    p.wait()


# The machine's temperatures, for the Heat row and the Heat bar: fan speed is not readable on most machines (Windows
# and macOS keep it from programs), so how hot the machine runs stands in for how hard its fans work. Linux reads the
# kernel's thermal zones and hwmon temperatures; WSL, which has none, Windows' thermal zones through powershell.exe
# (no admin needed; a second or two a run, so it is read in a thread of its own, as nvidia-smi is); macOS gives none
# without sudo, so it reads smctemp -c, else osx-cpu-temp, from Homebrew, if one is installed.
POWERSHELL = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
TEMP_TOOLS = (("smctemp", ["-c"]), ("osx-cpu-temp", []))


def sys_temps():
    """(name, °C) for each of the kernel's thermal zones and hwmon temperatures, which it gives in millidegrees."""
    out = []
    for z in sorted(glob.glob("/sys/class/thermal/thermal_zone*")):
        t = read_text(z + "/temp").strip()
        if t.lstrip("-").isdigit():
            out.append((read_text(z + "/type").strip() or os.path.basename(z), int(t) / 1000))
    for t in sorted(glob.glob("/sys/class/hwmon/hwmon*/temp*_input")):
        v, base = read_text(t).strip(), t[:-len("_input")]
        if v.lstrip("-").isdigit():
            out.append((read_text(base + "_label").strip() or read_text(os.path.dirname(t) + "/name").strip() or os.path.basename(base), int(v) / 1000))
    return out


_fans_seen = set()


def sys_fans(root="/sys/class/hwmon", seen=_fans_seen):
    """[{"name", "rpm", "duty"}] for each hwmon fan that has turned since the page started, named by its label, else its
    chip and number ("nct6799 fan2"). A header with nothing on it reads 0 for ever and is left out; a fan that stops
    when cool reads 0 for a while and stays in. duty is the chip's PWM output to it as a percentage, where it gives one.
    A board's fan chip needs its driver (nct6775, it87, ...) loaded, or there are no fans here to read."""
    out = []
    for f in sorted(glob.glob(root + "/hwmon*/fan*_input"), key=lambda p: [int(s) if s.isdigit() else s for s in re.split(r"(\d+)", p)]):
        v, base, d = read_text(f).strip(), f[:-len("_input")], os.path.dirname(f)
        if not v.isdigit():
            continue
        name = read_text(base + "_label").strip() or f"{read_text(d + '/name').strip()} {os.path.basename(base)}"
        if int(v) > 0:
            seen.add(name)
        if name in seen:
            pwm = read_text(d + "/pwm" + os.path.basename(base)[3:]).strip()
            out.append({"name": name, "rpm": int(v), "duty": round(100 * int(pwm) / 255) if pwm.isdigit() else None})
    return out


def windows_temps(text):
    """(zone, °C) from lines of "<zone>=<tenths of a kelvin>"; a zone with no reading gives 0."""
    out = []
    for line in text.splitlines():
        name, _, v = line.strip().rpartition("=")
        if v.isdigit() and int(v) > 0:
            out.append((name.split(".")[-1], round(int(v) / 10 - 273.15, 1)))
    return out


def mac_temps():
    for tool, args in TEMP_TOOLS:
        exe = shutil.which(tool) or next((os.path.join(d, tool) for d in ("/opt/homebrew/bin", "/usr/local/bin") if os.access(os.path.join(d, tool), os.X_OK)), None)
        m = exe and re.search(r"-?\d+(?:\.\d+)?", run(exe, *args, timeout=4))
        if m and float(m[0]) > 0:
            return [("CPU", float(m[0]))]
    return []


def read_temps():
    """[{"name", "c"}] for each sensor that reads, hottest first; a sensor not fitted reads 0 or nonsense."""
    if MAC:
        temps = mac_temps()
    else:
        temps = sys_temps()
        if not temps and os.access(POWERSHELL, os.X_OK):
            temps = windows_temps(run(POWERSHELL, "-NoProfile", "-NonInteractive", "-Command",
                                      "Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation | "
                                      "ForEach-Object { $_.Name + '=' + $_.HighPrecisionTemperature }", timeout=10))
    return [{"name": n, "c": round(c, 1)} for n, c in sorted(temps, key=lambda x: -x[1]) if 0 < c < 150]


def heat_loop():
    """The temperatures into _perf["temps"] and the fans into _perf["fans"], read again PERF_STEP seconds after each read
    ends, while sampling goes on."""
    while _perf["running"]:
        temps, fans = read_temps(), [] if MAC else sys_fans()
        if _perf["running"]:
            _perf["temps"], _perf["fans"] = temps, fans
        time.sleep(PERF_STEP)
    _perf["heat_on"] = False


def smi_loop():
    """nvidia-smi's GPUs into _perf["smi"], run again PERF_STEP seconds after each run ends, while sampling goes on."""
    while _perf["running"]:
        out = run(NVIDIA_SMI, "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu",
                  "--format=csv,noheader,nounits", timeout=20)
        gpus = [g for g in map(smi_line, out.splitlines()) if g]
        if gpus and _perf["running"]:
            _perf["smi"] = gpus
        time.sleep(PERF_STEP)
    _perf["smi_on"] = False


def start_children():
    if not _perf.get("heat_on"):
        _perf["heat_on"] = True
        threading.Thread(target=heat_loop, daemon=True).start()
    if NVIDIA_SMI and not MAC and not _perf.get("smi_on"):
        _perf["smi_on"] = True
        threading.Thread(target=smi_loop, daemon=True).start()
    if MAC and "top" not in _children:
        block = []
        def top(line):
            # a sample starts with its "Processes:" line; the one before it is then complete
            if line.startswith("Processes:") and block:
                _perf["top"] = mac_top("".join(block))
                block.clear()
            block.append(line)
        threading.Thread(target=child_lines, args=("top", ["top", "-l", "0", "-n", "0", "-s", str(PERF_STEP)], top), daemon=True).start()


def perf_counters():
    """The machine's counters now: CPU (busy, total) or busy %, memory, disks' (read, written, busy ms), the network's
    (in, out) per interface, and the GPUs."""
    if MAC:
        t = _perf.get("top") or {}
        return {"cpu_pct": t.get("cpu"), "mem": mac_mem(run("sysctl", "-n", "hw.memsize").strip() or 0, run("vm_stat"), run("sysctl", "-n", "vm.swapusage")),
                "disks": {"disk": t["disk"] + (None,)} if t.get("disk") and None not in t["disk"] else {},
                "net": mac_net(run("netstat", "-ib")), "gpus": mac_gpu(run("ioreg", "-r", "-d", "1", "-w", "0", "-c", "IOAccelerator"))}
    return {"cpu": proc_cpu(read_text("/proc/stat")), "mem": proc_mem(read_text("/proc/meminfo")),
            "disks": proc_disks(read_text("/proc/diskstats")), "net": proc_net(read_text("/proc/net/dev")),
            "gpus": _perf.get("smi") if NVIDIA_SMI else amd_gpus()}


def perf_spaces():
    """Each disk the page shows: the root, home if it is another, the watched disk (AGENTS_DISK_WATCH) and, under WSL,
    each Windows drive (/mnt/c, ...)."""
    drives = sorted(f[1] for f in (line.split() for line in read_text("/proc/mounts").splitlines())
                    if len(f) > 2 and re.fullmatch(r"/mnt/[a-z]", f[1]) and f[2] in ("9p", "drvfs"))
    paths = ["/", os.path.expanduser("~"), os.environ.get("AGENTS_DISK_WATCH") or setting("AGENTS_DISK_WATCH"), *drives]
    out, seen = [], set()
    for p in paths:
        try:
            dev, u = os.stat(p).st_dev, shutil.disk_usage(p)
        except (OSError, TypeError):
            continue
        if dev in seen:
            continue
        seen.add(dev)
        label = p[5:].upper() + ":" if re.fullmatch(r"/mnt/[a-z]", p) else p
        out.append({"label": label, "path": p, "used": u.total - u.free, "total": u.total})
    return out


def perf_reading(prev, cur, dt):
    """One reading for the page: what cur is, and how fast it moved since prev, dt seconds earlier."""
    out = {"mem": cur["mem"], "spaces": perf_spaces(), "gpus": cur["gpus"] or [], "temps": _perf.get("temps"),
           "fans": _perf.get("fans")}
    if "cpu_pct" in cur:
        if cur["cpu_pct"] is not None:
            out["cpu"] = cur["cpu_pct"]
    elif prev and cur["cpu"][1] > prev["cpu"][1]:
        out["cpu"] = round(100 * (cur["cpu"][0] - prev["cpu"][0]) / (cur["cpu"][1] - prev["cpu"][1]), 1)
    rate = lambda a, b: max(0, (a - b) / dt) if dt > 0 else 0
    if prev and dt > 0:
        d = [(n, v, prev["disks"][n]) for n, v in cur["disks"].items() if n in prev["disks"]]
        if d:
            busy = [100 * (v[2] - p[2]) / (dt * 1000) for _, v, p in d if v[2] is not None and p[2] is not None]
            out["disk"] = {"read": sum(rate(v[0], p[0]) for _, v, p in d), "write": sum(rate(v[1], p[1]) for _, v, p in d),
                           "active": min(100, round(max(busy), 1)) if busy else None}
        out["net"] = [{"name": n, "in": rate(v[0], prev["net"][n][0]), "out": rate(v[1], prev["net"][n][1])}
                      for n, v in sorted(cur["net"].items()) if n in prev["net"]]
    return out


def perf_record(key, t, value):
    """One reading of a series into its last hour and its last day's minutes."""
    raw = _perf_long.setdefault(key, [])
    raw.append([round(t), value])
    while raw[0][0] < t - 3600:
        raw.pop(0)
    mins, m = _perf_mins.setdefault(key, []), int(t // 60) * 60
    if mins and mins[-1][0] == m:
        mins[-1][1] += value
        mins[-1][2] += 1
    else:
        mins.append([m, value, 1])
    while mins[0][0] < t - 86400:
        mins.pop(0)


def perf_history(key, span):
    """A series over the last span seconds for the enlarged graph: every reading up to an hour, each minute's
    average beyond. None for a series or span there is none of."""
    if span not in PERF_SPANS or key not in _perf_long:
        return None
    since = time.time() - span
    if span <= 3600:
        points = [p for p in list(_perf_long[key]) if p[0] >= since]
    else:
        points = [[m + 30, round(total / n, 2)] for m, total, n in list(_perf_mins.get(key, [])) if m >= since - 60]
    return {"key": key, "span": span, "step": PERF_STEP if span <= 3600 else 60, "points": points}


def perf_loop():
    prev = None
    while True:
        t = time.time()
        cur = perf_counters()
        r = perf_reading(prev and prev[1], cur, t - prev[0] if prev else 0)
        hist = _perf["hist"]
        def keep(key, value):
            if value is not None:
                hist[key] = (hist.get(key, []) + [value])[-PERF_KEEP:]
                if prev:
                    perf_record(key, t, value)
        keep("cpu", r.get("cpu"))
        keep("mem", round(100 * r["mem"]["used"] / r["mem"]["total"], 1) if r["mem"]["total"] else None)
        if r.get("disk"):
            keep("disk", r["disk"]["active"] if r["disk"]["active"] is not None else r["disk"]["read"] + r["disk"]["write"])
        for n in r.get("net", []):
            keep("net:" + n["name"], n["in"] + n["out"])
        for g in r["gpus"]:
            keep("gpu:" + g["id"], g["pct"])
        keep("heat", r["temps"][0]["c"] if r["temps"] else None)
        for f in r["fans"] or []:
            keep("fan:" + f["name"], f["rpm"])
        r["hist"] = dict(hist)
        if prev:   # the first reading has nothing to measure a rate against
            _perf["now"] = r
        prev = (t, cur)
        time.sleep(max(0.1, PERF_STEP - (time.time() - t)))


def perf_json():
    with _perf_lock:
        if not _perf["running"]:
            _perf["running"] = True
            start_children()
            threading.Thread(target=perf_loop, daemon=True).start()
    info = {"system": "macOS" if MAC else "WSL" if "microsoft" in os.uname().release.lower() else "Linux",
            "cores": os.cpu_count(), "step": PERF_STEP, "keep": PERF_KEEP,
            "gpu_source": "ioreg" if MAC else "nvidia-smi" if NVIDIA_SMI else "amdgpu",
            "heat_source": "smctemp or osx-cpu-temp" if MAC else "sys" if glob.glob("/sys/class/thermal/thermal_zone*") or glob.glob("/sys/class/hwmon/hwmon*/temp*_input") else "windows"}
    return json.dumps({**info, **(_perf["now"] or {"warming": True})}).encode()

# Plug-ins for the page's header and footer (owner, 2026-11-01: "header should default to what we have, with other
# options addable as plug in style scripts"): each executable file in AGENT_BAR_PLUGINS, else ~/.config/agents-web/bar,
# is an item the page can add, named by its file name, and keyed "x:<name>". The harness's own are in team/bar - Week,
# Session, Team and Disk, slim forms of them and slim CPU, Memory, Network, GPU, Heat and Fans bars - keyed by their bare names,
# Week, Session, Team and Disk in the bar until taken out. Each is run in the background
# for at most five seconds, given the page's numbers as JSON on its input (bar_facts()), and what it prints is the
# item: a line of text, under its file name, or JSON:
#   label, title        the name it shows and what a rest on it says
#   value, colour       its value as text in one colour, or value as a list of parts, each text or
#                       {"text", "colour", "bold"}; a colour is any CSS colour, or green, amber, red, text or faint
#   meter               {"pct", "mark", "colour"}: a bar filled to pct, a mark at mark, in colour (else green)
#   spark               a list of numbers, drawn as a sparkline
#   every               seconds between runs, 2 to 3600 (60)
#   hidden              true: the item is not shown this time (Disk with nothing to watch)
#   slim                true: all on one low line, the label and value beside the meter or sparkline; a label of ""
#                       shows none, and name is what the bar's Add list calls it instead
#   icon                one of the page's bar icons, shown in place of the label, which stays in its title: week, day,
#                       disk, cpu, mem, net, gpu, tok, heat or fan
#   place               "header" or "footer": the only one of the two it can be put in (else either)
# With a meter or a sparkline the label and value share a line ("Week: 70%") above it; without, the label is over
# the value. A script that fails, or prints nothing, shows "?" and says why when the pointer rests on it.
SHIPPED_BAR = os.path.join(ROOT, "team", "bar")
_plugged, _plugging = {}, set()


def bar_dir():
    return os.environ.get("AGENT_BAR_PLUGINS") or os.path.join(HOME, ".config", "agents-web", "bar")


def num(v, lo=None, hi=None):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    if f != f:
        return None
    return max(lo, f) if lo is not None and f < lo else min(hi, f) if hi is not None and f > hi else f


def plug_item(j, name):
    """What a plug-in printed, parsed: a line becomes its value; JSON is kept to the fields above, each bounded."""
    if not isinstance(j, dict):
        return {"label": name[:40], "value": str(j).splitlines()[0][:80], "title": "", "colour": ""}
    col = lambda c: str(c or "")[:30]
    item = {"label": str(name if j.get("label") is None else j["label"])[:40], "title": str(j.get("title") or "")[:300], "colour": col(j.get("colour"))}
    v = j.get("value", "")
    if isinstance(v, list):
        item["parts"] = [{"text": str(x.get("text", ""))[:40], "colour": col(x.get("colour")), "bold": bool(x.get("bold"))}
                         if isinstance(x, dict) else {"text": str(x)[:40], "colour": "", "bold": False} for x in v[:8]]
        v = "".join(x["text"] for x in item["parts"])
    item["value"] = str(v)[:80]
    m = j.get("meter")
    if isinstance(m, dict) and num(m.get("pct")) is not None:
        item["meter"] = {"pct": num(m["pct"], 0, 100), "mark": num(m.get("mark"), 0, 100), "colour": col(m.get("colour"))}
    if isinstance(j.get("spark"), list):
        item["spark"] = [num(x, 0) or 0 for x in j["spark"][-60:]]
    if num(j.get("every")) is not None:
        item["every"] = int(num(j["every"], 2, 3600))
    if j.get("hidden") is True:
        item["hidden"] = True
    if j.get("slim") is True:
        item["slim"] = True
    if j.get("name"):
        item["name"] = str(j["name"])[:40]
    if isinstance(j.get("icon"), str) and re.fullmatch(r"[a-z]{1,12}", j["icon"]):
        item["icon"] = j["icon"]
    if j.get("place") in ("header", "footer"):
        item["place"] = j["place"]
    return item


def run_plugin(path, name, facts=None):
    try:
        p = subprocess.run([path], capture_output=True, text=True, timeout=5, cwd=os.path.dirname(path),
                           input=json.dumps(facts or {}))
        out = p.stdout.strip()
        if p.returncode or not out:
            raise ValueError((p.stderr.strip() or f"exit {p.returncode}, nothing printed").splitlines()[-1])
        try:
            j = json.loads(out) if out.startswith("{") else None
        except json.JSONDecodeError:
            j = None
        item = plug_item(j if isinstance(j, dict) else out, name)
    except (OSError, ValueError, subprocess.TimeoutExpired) as e:
        item = {"label": name[:40], "value": "?", "title": f"{name}: {e}"[:300], "colour": ""}
    _plugged[path] = {**item, "at": time.time()}
    _plugging.discard(path)


def bar_facts(st):
    """The page's numbers a plug-in is given: the account's week and session, the budget's plan and day, the disk, each
    running agent's state and activity, and the machine's latest performance reading (None while nothing samples it)."""
    return {**{k: st.get(k) for k in ("now", "week", "session", "plan", "even", "day", "disk")}, "perf": _perf["now"], "cores": os.cpu_count(),
            "agents": [{k: a.get(k) for k in ("name", "status", "rate", "series")} for a in st.get("agents", [])]}


def plugins(facts=None):
    """The bar's plug-ins, each as it last printed; one not yet run is "…" until its first run is in."""
    out, now = [], time.time()
    for d, prefix in ((SHIPPED_BAR, ""), (bar_dir(), "x:")):
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for f in names:
            path, name = os.path.join(d, f), re.sub(r"\.[A-Za-z0-9]+$", "", f)
            key = prefix + re.sub(r"[^a-z0-9_-]", "-", name.lower())
            if f.startswith(".") or not os.path.isfile(path) or not os.access(path, os.X_OK):
                continue
            was = _plugged.get(path)
            if (not was or now - was["at"] >= was.get("every", 60)) and path not in _plugging:
                _plugging.add(path)
                threading.Thread(target=run_plugin, args=(path, name, facts), daemon=True).start()
            item = {k: v for k, v in (was or {"label": name, "value": "…", "title": "", "colour": ""}).items() if k not in ("at", "every")}
            out.append({"key": key, **item})
    return out


def panes():
    """Roster name -> its tmux pane: the pane id and size of the session agent-spawn.sh starts for it,
    <project>-<name>, else of a pane titled with its name (a session started by hand); and "<name> · meeting" -> its
    meeting session's pane, titled so."""
    names = {r["name"].lower(): r["name"] for r in roster()}
    names.update({meeting_session(n).lower(): meeting_session(n) for n in list(names.values())})   # its meeting session's pane, by title
    out = run("tmux", "list-panes", "-a", "-F",
              "#{session_name}\t#{pane_id}\t#{pane_title}\t#{pane_current_command}\t#{pane_width}\t#{pane_height}")
    lines = [p for p in (line.split("\t") for line in out.splitlines()) if len(p) == 6]
    # A byobu client session (<name>-<n>, grouped with <name>) lists the same panes again: a pane's session is the
    # one it was made in, the name without the number.
    home = {}
    for sess, pid, *_ in lines:
        if pid not in home or (re.search(r"-\d+$", home[pid]) and not re.search(r"-\d+$", sess)):
            home[pid] = sess
    by_name = {}
    for sess, pid, title, cmd, cols, rows in lines:
        own = sess.startswith(PROJECT + "-") and names.get(sess[len(PROJECT) + 1:])
        name = own or names.get(re.sub(r"^[^A-Za-z]+", "", title).strip().lower())
        if name and (own or cmd == "claude") and (own or name not in by_name):
            by_name[name] = {"session": "" if own else home[pid], "pane": pid, "cols": int(cols), "rows": int(rows)}
    return by_name


# A message's whole body, a long paste included: Claude Code takes a paste of this size as one block.
SAY_MAX_BYTES = 4 << 20


def typed_lines(pane):
    """The lines typed in the pane's input box (between the two rules round its ❯ line), as many screen lines as it
    takes; 0 when it is empty or holds only Claude Code's dim suggestion (dim text is never typed text)."""
    dim = re.compile(r"\x1b\[2m[^\x1b]*")
    lines = [ESCAPES.sub("", dim.sub("", l)).rstrip() for l in run("tmux", "capture-pane", "-p", "-e", "-t", pane).splitlines()]
    rule = lambda l: l.startswith("──")
    for i in range(len(lines) - 1, 0, -1):
        if lines[i].startswith("❯") and rule(lines[i - 1]) and not re.match(r"❯\s*\d+\.", lines[i]):   # not a question's options
            end = next((j for j in range(i + 1, len(lines)) if rule(lines[j])), None)
            if end is None:
                return 0
            box = [lines[i][1:].strip()] + [l.strip() for l in lines[i + 1:end]]
            return len(box) if any(box) else 0
    return 0


def clear_input(pane):
    """Empties the pane's input box when something is in it, as Claude Code leaves a message there when its turn is
    stopped before any answer: Ctrl+U clears a line and Backspace joins the one above, so nothing here can stop a turn,
    send, or open a menu, whatever state the box is in."""
    for _ in range(3):
        n = typed_lines(pane)
        if not n:
            return True
        subprocess.run(["tmux", "send-keys", "-t", pane, "C-u", *["BSpace", "C-u"] * n])
        time.sleep(0.3)


def type_into(name, text, images=()):
    """Types a message into the agent's pane, then Enter; None when it is in no pane, else whether tmux took it.
    The text goes in as one bracketed paste, as a terminal pastes, so its line breaks stay line breaks in the agent's
    message box instead of sending it early. Each image follows as a paste of its path alone, which Claude Code
    attaches as an image, as when a file is dragged in; any other file stays as its path, for the agent to open,
    with a space after it so the next one does not run on. Anything already in the box (a stopped message Claude Code
    put back) is cleared first, so the message is not joined onto it."""
    where = panes().get(name)
    if not where:
        return None
    clear_input(where["pane"])
    ok = True
    parts = [i if os.path.splitext(i)[1].lower() in IMAGE_TYPES else i + " " for i in images]
    for i, part in enumerate(([text + " "] if text else []) + parts):
        if i:
            time.sleep(0.3)
        buf = "agents-web-" + uuid.uuid4().hex[:12]
        ok = ok and subprocess.run(["tmux", "load-buffer", "-b", buf, "-"], input=part.encode()).returncode == 0
        ok = ok and subprocess.run(["tmux", "paste-buffer", "-p", "-d", "-b", buf, "-t", where["pane"]]).returncode == 0
    time.sleep(0.2)   # an Enter in the same burst as the paste can be swallowed
    ok = ok and subprocess.run(["tmux", "send-keys", "-t", where["pane"], "Enter"]).returncode == 0
    with _lock:
        _state["at"] = 0
    return ok


# ── starting and stopping ─────────────────────────────────────────────────────
TEAM_STOP = ("Wind down the team for shutdown: ask everyone to stop at a clean point, mark the team paused (as "
             "team/team-paused.sh reads it), and tell me once all have stopped.")
TEAM_START = "The team is back up: start the day."
AGENT_STOP = ("Finish what you're on at a clean point, bring your durable record up to date, and stop: "
              "the owner is stopping you from the team page, and your pane closes once you are idle.")
_starting, _halting = set(), set()   # "team" or agent names being started; "team" or agent names being stopped
_team_stop = {"at": 0}   # when the page last asked the lead to wind the team down
COMPACT_NOW = ("/compact The owner asked for this compaction from the team page. Keep who you are and your role, "
               "what you are doing and what comes next.")
_compacting = set()   # agents the page is compacting


def compact_soon(name):
    """Once the agent is not working (up to ten minutes), types /compact into its pane and waits for it to finish."""
    try:
        status = lambda: (live_sessions().get(name) or {}).get("status")
        if wait_for(lambda: status() not in ("busy", "waiting"), 600) and type_into(name, COMPACT_NOW):
            wait_for(lambda: status() == "busy", 30, 1)
            wait_for(lambda: status() != "busy", 600)
    finally:
        _compacting.discard(name)
        with _lock:
            _state["at"] = 0


COMPACT = ("/compact The owner stopped you from the team page and has started you again. Keep who you are and your "
           "role, and that your durable record is up to date: read it first and carry on from it.")


def compact_later(names):
    """Marks agents the page is stopping, so the start that resumes their conversation compacts it first."""
    os.makedirs(COMPACT_ON_START, exist_ok=True)
    for n in names:
        open(os.path.join(COMPACT_ON_START, n), "w").close()


def compact_when_up(name, limit=180):
    """Once a marked agent is up and idle, types /compact into its pane and waits for the compaction to finish; returns
    once it is up and idle again, marked or not (False if it never came up)."""
    idle = lambda: (live_sessions().get(name) or {}).get("status") == "idle" and name in panes()
    if not wait_for(idle, limit):
        return False
    mark = os.path.join(COMPACT_ON_START, name)
    if os.path.exists(mark):
        os.remove(mark)
        if type_into(name, COMPACT):
            wait_for(lambda: (live_sessions().get(name) or {}).get("status") == "busy", 30, 1)
            return wait_for(idle, 600)
    return True


def wait_for(test, limit, step=2):
    """Polls test() until it is true or limit seconds pass; returns whether it came true."""
    end = time.time() + limit
    while time.time() < end:
        if test():
            return True
        time.sleep(step)
    return test()


def restore(*args):
    """team/team-start.sh through the owner's interactive login shell, so the agents it starts get the PATH and
    settings a terminal gives them, not this service's; its output is kept in TEAM_START_LOG."""
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(TEAM_START_LOG, "a") as log:
        log.write(f"\n{time.strftime('%Y-%m-%d %H:%M:%S')} team-start.sh {' '.join(args)}\n")
        log.flush()
        return subprocess.run(["bash", "-lic", 'exec bash "$0" "$@"', TEAM_START_SH, *args], stdin=subprocess.DEVNULL,
                              stdout=log, stderr=subprocess.STDOUT, timeout=300).returncode


def team_paused():
    """Whether team/team-paused.sh says the team is wound down."""
    try:
        return subprocess.run(["bash", TEAM_PAUSED_SH], stdin=subprocess.DEVNULL, capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def names_in(path):
    """The names in a file of one name a line; None with no such file."""
    try:
        with open(path) as f:
            return {n.strip() for n in f if n.strip()}
    except OSError:
        return None


def keep_stopped(name, stopped):
    """Records that a standing agent was stopped on its own, or started again. It stays stopped across a restart of the
    machine, which leaves no record of who was running, until its own Start."""
    names = names_in(STOPPED) or set()
    names = names | {name} if stopped else names - {name}
    os.makedirs(os.path.dirname(STOPPED), exist_ok=True)
    with open(STOPPED, "w") as f:
        f.write("".join(n + "\n" for n in sorted(names)))


LEAD_ORDER = ["lead", "hot", "ops", "support", "pa"]   # who leads, the first of them running (owner, 2026-11-09)


def lead_name(live=None):
    """The agent leading the team now: the first running of the delivery lead, the head of testing, the head of
    operations and the assistant (owner, 2026-11-09: "if delivery lead is running, otherwise if head of testing is
    running, otherwise if head of operations is running, otherwise it's the assistant"). With none of them running,
    the delivery lead, whom a team start brings up; None with no delivery lead on the roster either."""
    live = live_sessions() if live is None else live
    people = [(LEAD_ORDER.index(k), r["name"]) for r in roster() if (k := role_of(r["role"])[0]) in LEAD_ORDER]
    up = sorted(x for x in people if x[1] in live)
    return up[0][1] if up else next((n for k, n in sorted(people) if k == 0), None)


def team_up():
    """Who the next start brings back, the lead always among them: those running when the page last stopped the team
    who are still on the roster. With no such record, the roster except the agents stopped one by one; None if that is
    the whole team."""
    lead = lambda r: role_of(r["role"])[0] == "lead"
    names = names_in(TEAM_UP)
    if names is not None:
        return [r["name"] for r in team_roster() if r["name"] in names or lead(r)]
    stopped = names_in(STOPPED) or set()
    if not any(r["name"] in stopped and not lead(r) for r in team_roster()):
        return None
    return [r["name"] for r in team_roster() if r["name"] not in stopped or lead(r)]


def start_team(lead, names):
    """team/team-start.sh for the named agents (the whole team for None), then, once the lead is up and ready
    for a message, the lead is told to start the day. The record of who was running is used up."""
    started = names or [r["name"] for r in team_roster()]
    try:
        restore(*[a for n in names for a in ("--only", n)]) if names else restore()
        try:
            os.remove(TEAM_UP)
        except OSError:
            pass
        for n in started:
            if n != lead:
                threading.Thread(target=compact_when_up, args=(n,), daemon=True).start()
        if compact_when_up(lead):
            type_into(lead, TEAM_START)
    except (OSError, subprocess.SubprocessError):
        pass
    finally:
        _starting.difference_update(["team", *started])


def start_one(name):
    try:
        if restore("--only", name) == 0:   # one that did not start comes back at once, its reason in TEAM_START_LOG
            compact_when_up(name)
    except (OSError, subprocess.SubprocessError):
        pass
    finally:
        _starting.discard(name)


def halt_when_idle(name):
    """After the stop message: waits for the agent to take it up and finish (up to five minutes), then closes its pane,
    which ends its tmux session when it is the only one there."""
    try:
        status = lambda: (live_sessions().get(name) or {}).get("status")
        wait_for(lambda: status() == "busy", 30, 1)
        wait_for(lambda: status() != "busy", 300)
        where = panes().get(name)
        if where:
            subprocess.run(["tmux", "kill-pane", "-t", where["pane"]])
        wait_for(lambda: name not in live_sessions(), 20, 1)
    finally:
        _halting.discard(name)
        with _lock:
            _state["at"] = 0


# ── meetings ──────────────────────────────────────────────────────────────────
# A meeting is the owner and the agents in it, every line anyone says going to everyone else (owner, 2026-11-03: "in
# a real meeting each line would go to all attendees"). Each agent attends through a meeting session of its own, a
# fresh Claude session named "<Agent> · meeting" whose conversation holds only the meeting, so hearing a line costs
# little however long the agent's own conversation has grown, and the agent's own work carries on undisturbed. A
# session speaks to the meeting only with meeting-say; nothing else it says or does reaches the others. A line for a
# session that is working waits, and everything waiting goes to it together once it is idle. Pause holds the lines
# between sessions until the owner speaks or resumes. End asks each session to suggest what its agent should be told;
# each suggestion waits for the owner (send, edited or not, or skip), and once all are settled the sessions close.
# The meeting's state and its log (one JSON line per thing said) are kept in MEETINGS, and a readable record of it,
# written as it goes, in MEETING_RECORDS.
MEETINGS = os.environ.get("AGENTS_MEETINGS") or os.path.join(STATE_DIR, "meetings")
MEETING_RECORDS = os.environ.get("AGENTS_MEETING_RECORDS") or os.path.join(STATE_DIR, "meeting-records")
MEETING_SAY = os.environ.get("AGENTS_MEETING_SAY") or os.path.join(ROOT, "team/meeting-say")
# where meeting sessions start: the folder the projects sit in, which the owner has trusted once for all of them;
# a meeting needs no project of its own (it speaks only through MEETING_SAY) and trust is not inherited (folder_trusted)
MEETING_DIR = os.environ.get("AGENTS_MEETING_DIR") or os.path.dirname(ROOT)
MEETING_MODEL = os.environ.get("AGENTS_MEETING_MODEL") or ""   # every session on this model, else its agent's
_meetings = {}   # id -> its state, as kept in MEETINGS/<id>.json
_meet_lock = threading.RLock()


MEETING_SUFFIX = " · meeting"


def meeting_session(name):
    return name + MEETING_SUFFIX


def meeting_owner():
    return setting("AGENTS_OWNER_NAME") or "Owner"


def load_meetings():
    for f in glob.glob(os.path.join(MEETINGS, "*.json")):
        try:
            with open(f) as fh:
                m = json.load(fh)
            _meetings[m["id"]] = m
        except (OSError, ValueError, KeyError):
            pass


def meeting_log(m):
    try:
        with open(os.path.join(MEETINGS, m["id"] + ".jsonl")) as f:
            return [json.loads(line) for line in f if line.strip()]
    except (OSError, ValueError):
        return []


def save_meeting(m):
    """Its state, then its readable record from the state and the log."""
    os.makedirs(MEETINGS, exist_ok=True)
    tmp = os.path.join(MEETINGS, m["id"] + ".json.tmp")
    with open(tmp, "w") as f:
        json.dump(m, f, indent=1)
    os.replace(tmp, os.path.join(MEETINGS, m["id"] + ".json"))
    try:
        os.makedirs(MEETING_RECORDS, exist_ok=True)
        with open(os.path.join(MEETING_RECORDS, m["record"]), "w") as f:
            f.write(meeting_md(m, meeting_log(m)))
    except OSError:
        pass


def clock(ts):
    return time.strftime("%H:%M", time.localtime(ts))


def meeting_md(m, log):
    """The readable record: who attended and when, every line said, and what each agent was sent at the end."""
    out = [f"# Meeting: {m['topic'] or m['view'] or 'untitled'}", "",
           f"- **Started:** {time.strftime('%d %b %Y %H:%M', time.localtime(m['opened']))}"
           + (f"; **ended:** {clock(m['ended'])}" if m.get("ended") else ""),
           f"- **Attending:** {meeting_owner()}, " + ", ".join(
               n + (f" (brought in at {clock(m['joined'][n])})" if n in m["added"] else "") for n in m["who"]), "", "## Said", ""]
    for line in log:
        if line["kind"] == "say":
            text = line["text"].replace("\n", "\n  ")
            out.append(f"- **{line['who']}** ({clock(line['at'])}): {text}")
        else:
            out.append(f"- *{clock(line['at'])}: {line['text']}*")
    if m.get("handover"):
        out += ["", "## Sent to each agent at the end", ""]
        for n, h in m["handover"].items():
            state = {"asked": "no suggestion yet", "suggested": "waiting for you", "skipped": "skipped",
                     "queued": "waiting to be sent: its agent is busy or not running", "sent": "sent"}.get(h["state"], h["state"])
            if h["state"] == "skipped" and not h.get("suggested"):
                state = "nothing to send" if "suggested" in h else "not running at the end"
            out.append(f"- **{n}**: {state}" + (" (edited)" if h.get("edited") else ""))
            if h.get("suggested"):
                out.append(f"  - Suggested: {h['suggested']}")
            if h.get("sent") and h.get("edited"):
                out.append(f"  - Sent: {h['sent']}")
    return "\n".join(out) + "\n"


def meeting_add_line(m, who, text, kind="say"):
    """Adds a line to the log and the record; a thing said is held for every other attendee to hear."""
    line = {"at": time.time(), "who": who, "text": text, "kind": kind}
    os.makedirs(MEETINGS, exist_ok=True)
    with open(os.path.join(MEETINGS, m["id"] + ".jsonl"), "a") as f:
        f.write(json.dumps(line) + "\n")
    if kind == "say":
        for n in m["who"]:
            if n != who:
                m["held"].setdefault(n, []).append(f"{who}: {text}")
    save_meeting(m)


def meeting_prompt(m, name):
    others = [meeting_owner(), *[n for n in m["who"] if n != name]]
    role = next((r["role"] for r in roster() if r["name"] == name), "")
    return (f"You are {name}'s meeting session: {name}, the {role or 'agent'}, attending a meeting"
            f"{' about ' + m['topic'] if m['topic'] else ''} with {', '.join(others)}. {name} itself is a separate session that carries on its own work; "
            f"you are only here for the meeting. First read {name}'s durable record, its latest session entries "
            f"(bash scripts/ledger-db.sh session-entries --agent {name} --limit 5), and its role document in docs/roles/, "
            f"so you know what {name} knows.\n\n"
            f"How the meeting works:\n"
            f"- Everything said in the meeting reaches you as a message, each line headed with who said it.\n"
            f"- You speak to the meeting ONLY with: {MEETING_SAY} \"what you say\". Nothing else you write reaches anyone.\n"
            f"- Speak when you have something to add; you need not answer every line. Keep it short, as in a real meeting.\n"
            f"- You may read files and run read-only commands to inform the discussion. Change nothing: no edits, no git, "
            f"no messages to other agents, and do not write {name}'s durable record or any record of your own.\n\n"
            f"When you have read the record, tell the meeting you are here, with meeting-say.")


def open_meeting_session(m, name):
    """Starts the agent's meeting session in a byobu session of its own, on its agent's model (or MEETING_MODEL)."""
    model = MEETING_MODEL or (transcript_model(last_sessions().get(name)) or "").split(" ")[0].lower()
    os.makedirs(MEETINGS, exist_ok=True)
    prompt = os.path.join(MEETINGS, f"{m['id']}-{name}.prompt")
    with open(prompt, "w") as f:
        f.write(meeting_prompt(m, name))
    env = " ".join(f"{k}={shlex.quote(v)}" for k, v in (("MEETING_ID", m["id"]), ("MEETING_AS", name), ("AGENT_NAME", name), ("AGENTS_WEB_PORT", str(PORT))))
    cmd = (f"cd {shlex.quote(MEETING_DIR)} && exec env {env} claude{' --model ' + shlex.quote(model) if model else ''}"
           f" -n {shlex.quote(meeting_session(name))} --permission-mode auto --allowedTools {shlex.quote(f'Bash({MEETING_SAY}:*)')}"
           f" --disallowedTools Edit,Write,NotebookEdit -- \"$(cat {shlex.quote(prompt)})\"")   # -- ends the tool lists, which take every word after them
    tmux = f"meet-{m['id']}-{name}"
    m["tmux"][name] = tmux
    subprocess.run(["bash", "-lic", 'exec byobu new-session -d -s "$0" -x 200 -y 50 bash -c "$1"', tmux, cmd],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)


CLAUDE_JSON = os.environ.get("AGENTS_CLAUDE_JSON") or (os.path.join(os.environ["CLAUDE_CONFIG_DIR"], ".claude.json")
                                                     if os.environ.get("CLAUDE_CONFIG_DIR") else os.path.join(HOME, ".claude.json"))
MEETING_STUCK_AFTER = 90   # seconds a meeting session may take to say it is here before it shows as stuck


def folder_trusted(path):
    """Whether Claude Code will open a session in path without its trust prompt: True, False, or None when it cannot
    tell. Trust is kept per folder in .claude.json and is not inherited from a trusted parent (a session in a trusted
    ~/dev still asked, 2026-11-05); a git worktree takes its main checkout's, which is why the agents' trees never ask."""
    try:
        with open(CLAUDE_JSON) as f:
            projects = json.load(f).get("projects") or {}
    except (OSError, ValueError):
        return None
    paths = [os.path.realpath(path)]
    try:
        common = subprocess.run(["git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir"],
                                capture_output=True, text=True, timeout=5).stdout.strip()
        if common.endswith("/.git"):
            paths.append(os.path.dirname(common))
    except (OSError, subprocess.SubprocessError):
        pass
    return any((projects.get(x) or {}).get("hasTrustDialogAccepted") for x in paths)


def meeting_screen(tmux):
    """What a meeting session's byobu window shows, or None when it has gone."""
    r = subprocess.run(["tmux", "capture-pane", "-p", "-t", tmux], capture_output=True, text=True, timeout=5)
    return None if r.returncode else r.stdout


def meeting_stuck(m, name, live):
    """Why an attendee that has not said it is here after MEETING_STUCK_AFTER seconds has not, or None."""
    if m.get("ended") or m["present"].get(name) or time.time() - m["joined"].get(name, time.time()) < MEETING_STUCK_AFTER:
        return None
    tmux = m.get("tmux", {}).get(name)
    screen = meeting_screen(tmux) if tmux else None
    if screen is None:
        return "its session closed"
    if "trust this folder" in screen:
        return "waiting at Claude Code's folder trust prompt"
    return "not arrived" if meeting_session(name) not in live else "running but has not said it is here"


def start_meeting(who, topic, view):
    now = time.time()
    mid = time.strftime("%Y%m%d-%H%M", time.localtime(now)) + "-" + uuid.uuid4().hex[:4]
    slug = re.sub(r"[^a-z0-9]+", "-", (topic or view or "meeting").lower()).strip("-")[:40] or "meeting"
    m = {"id": mid, "topic": topic, "view": view, "opened": now, "ended": None, "ending": False, "paused": False,
         "who": [], "added": [], "joined": {}, "present": {}, "held": {}, "notice": {}, "handover": {}, "tmux": {},
         "record": time.strftime("%Y-%m-%d_%H-%M", time.localtime(now)) + f"_{slug}.md"}
    with _meet_lock:
        _meetings[mid] = m
        for n in who:
            meeting_join(m, n)
        save_meeting(m)
    return m


def meeting_join(m, name, added=False):
    """An attendee: one of those the meeting started with, or one brought in with Add."""
    if name in m["who"]:
        return
    m["who"].append(name)
    m["joined"][name] = time.time()
    if added:
        m["added"].append(name)
        meeting_add_line(m, "", f"{name} was brought in", "event")
    # what was said before they came in, so they join the conversation where it is
    said = [f"{x['who']}: {x['text']}" for x in meeting_log(m) if x["kind"] == "say"]
    if said:
        m["held"][name] = ["(said before you joined)", *said]
    threading.Thread(target=open_meeting_session, args=(m, name), daemon=True).start()


def meeting_said(m, name, text, handover=False):
    """What a session (or the owner, name None) says to the meeting; a session's first line is its arrival."""
    with _meet_lock:
        if name and name not in m["who"]:
            return False
        if handover and name:
            h = m["handover"].setdefault(name, {})
            nothing = text.strip().lower().rstrip(".") in ("nothing", "none", "")
            h.update(state="skipped" if nothing else "suggested", suggested="" if nothing else text)
            save_meeting(m)
            meeting_settle(m)
            return True
        if name and name not in m["present"]:
            m["present"][name] = time.time()
        if name is None:
            m["paused"] = False
        meeting_add_line(m, name or meeting_owner(), text)
    return True


def meeting_end(m):
    """Asks each session for what its agent should be told; a session not running has nothing to suggest."""
    with _meet_lock:
        m["ending"] = True
        live = live_sessions()
        for n in m["who"]:
            if meeting_session(n) in live:
                m["handover"][n] = {"state": "asked"}
                m["notice"][n] = ("The meeting is ending. Suggest the message your agent's own session should be sent about it: "
                                  f"what was decided and what {n} must act on, with: {MEETING_SAY} --handover \"the message\". "
                                  f"If there is nothing for {n}, run: {MEETING_SAY} --handover nothing")
            else:
                m["handover"][n] = {"state": "skipped"}
        meeting_add_line(m, "", "the meeting was ended", "event")
        meeting_settle(m)


def meeting_handover(m, name, action, text=None):
    """The owner's word on a session's suggestion: send it (edited or not) to the agent, or skip it."""
    with _meet_lock:
        h = m["handover"].get(name)
        if not h or h["state"] not in ("suggested", "asked"):
            return False
        if action == "skip":
            h["state"] = "skipped"
        else:
            text = (text or h.get("suggested") or "").strip()
            if not text:
                return False
            h.update(state="queued", sent=text, edited=text != h.get("suggested"))
        save_meeting(m)
        meeting_settle(m)
        return True


def meeting_settle(m):
    """Once every suggestion is settled, the sessions close and the meeting ends."""
    if not m["ending"] or m.get("ended") or any(h["state"] in ("asked", "suggested") for h in m["handover"].values()):
        return
    for tmux in m["tmux"].values():
        subprocess.run(["tmux", "kill-session", "-t", "=" + tmux], stderr=subprocess.DEVNULL)
    m["ended"] = time.time()
    save_meeting(m)


def meeting_deliver():
    """meeting_deliver_once every second and a half, for as long as the page runs."""
    while True:
        time.sleep(1.5)
        try:
            meeting_deliver_once()
        except Exception:   # the loop must outlive any one meeting's trouble
            time.sleep(5)


def meeting_deliver_once():
    """Each session's held lines (and any notice) to it once it is idle, all together; and each suggestion the owner
    sent to its agent once that agent is idle. Pause holds the lines between sessions."""
    with _meet_lock:
        todo = [m for m in _meetings.values() if not m.get("ended") or any(h["state"] == "queued" for h in m["handover"].values())]
    if not todo:
        return
    live = live_sessions()
    idle = lambda n: (live.get(n) or {}).get("status") == "idle"
    for m in todo:
        tag = f"[Meeting{': ' + m['topic'] if m['topic'] else ''}]"
        for n in m["who"]:
            s = meeting_session(n)
            with _meet_lock:
                lines = [] if m["paused"] or m.get("ended") else list(m["held"].get(n, []))
                notice = None if m.get("ended") else m["notice"].get(n)
            if (lines or notice) and idle(s) and type_into(s, "\n".join([tag, *lines] + ([notice] if notice else []))):
                with _meet_lock:
                    m["held"][n] = m["held"].get(n, [])[len(lines):]
                    m["notice"].pop(n, None)
                    save_meeting(m)
            h = m["handover"].get(n) or {}
            if h.get("state") == "queued" and idle(n) and type_into(n, f"{tag} {h['sent']}"):
                with _meet_lock:
                    h["state"] = "sent"
                    save_meeting(m)


def meetings_json():
    """Every meeting not yet ended, or ended in the last hour, with its log, for the page."""
    now = time.time()
    with _meet_lock:
        out = [{**{k: m[k] for k in ("id", "topic", "view", "opened", "ended", "ending", "paused", "who", "added", "joined", "present", "handover", "record")},
                "held": {n: len(v) for n, v in m["held"].items()}, "log": meeting_log(m)}
               for m in _meetings.values() if not m.get("ended") or now - m["ended"] < 3600]
    live = live_sessions()
    for m in out:
        m["live"] = [n for n in m["who"] if meeting_session(n) in live]
        m["busy"] = [n for n in m["who"] if (live.get(meeting_session(n)) or {}).get("status") == "busy"]
        with _meet_lock:
            mm = _meetings.get(m["id"])
        m["stuck"] = {n: why for n in m["who"] if mm and (why := meeting_stuck(mm, n, live))}
    return json.dumps({"meetings": out, "records": MEETING_RECORDS}).encode()


# ── the conversation ──────────────────────────────────────────────────────────
_paths, _feeds = {}, {}
_lock = threading.Lock()


def transcript(sid):
    if sid not in _paths or not os.path.exists(_paths[sid] or ""):
        hits = glob.glob(os.path.join(PROJECTS, "*", sid + ".jsonl"))
        _paths[sid] = hits[0] if hits else None
    return _paths[sid]


def hook_compacting(sid, now):
    """Whether the session's PreCompact hook has fired and its SessionStart has not yet followed: compacting. A mark
    older than half an hour is taken to be from a session that died mid-compaction."""
    try:
        with open(os.path.join(ACTIVITY, sid)) as f:
            st, at = f.read().split()[:2]
        return st == "compacting" and now - int(at) < 1800
    except (OSError, ValueError):
        return False


_models = {}   # transcript path -> ((size, mtime), the model it last answered with)
MODEL_ID = re.compile(rb'"model":"claude-([a-z]+)-(\d+)-(\d+)')


def transcript_model(sid):
    """The model a session last answered with, from the end of its transcript, as "Opus 5.5"; "" when none is found."""
    path = transcript(sid) if sid else None
    try:
        st = os.stat(path) if path else None
    except OSError:
        st = None
    if not st:
        return ""
    key = (st.st_size, st.st_mtime)
    with _lock:
        hit = _models.get(path)
    if hit and hit[0] == key:
        return hit[1]
    with open(path, "rb") as f:
        f.seek(max(0, st.st_size - 2_000_000))
        ids = MODEL_ID.findall(f.read())
    name = f"{ids[-1][0].decode().title()} {int(ids[-1][1])}.{int(ids[-1][2])}" if ids else ""
    with _lock:
        _models[path] = (key, name)
    return name


_compacts = {}   # transcript path -> ((size, mtime), its last compaction)
BOUNDARY = b'"subtype":"compact_boundary"'


def last_compact(sid):
    """The session's last compaction, from the compact_boundary entry it left in the transcript: when, manual or auto,
    the tokens before it and how long it took; None for none. The transcript is read backwards from its end until one
    is found, and the answer kept until the file changes."""
    path = transcript(sid) if sid else None
    try:
        st = os.stat(path) if path else None
    except OSError:
        st = None
    if not st:
        return None
    key = (st.st_size, st.st_mtime)
    with _lock:
        hit = _compacts.get(path)
    if hit and hit[0] == key:
        return hit[1]
    found, end, chunk = None, st.st_size, 4_000_000
    with open(path, "rb") as f:
        while end > 0 and not found:
            start = max(0, end - chunk)
            f.seek(start)
            lines = f.read(end - start).split(b"\n")
            # a chunk's first line may be cut short, so it is read whole as the end of the next chunk back; a line
            # longer than a chunk is a tool result or an image, never a compaction, and is stepped over
            first = lines.pop(0) if start else b""
            end = start + len(first) if len(first) < end - start else start
            for line in reversed(lines):
                if BOUNDARY not in line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:   # malformed, or bytes that are not text: a crash can leave a line of NULs
                    continue
                if e.get("subtype") == "compact_boundary":
                    m = e.get("compactMetadata") or {}
                    found = {"ts": e.get("timestamp"), "trigger": m.get("trigger"), "pre": m.get("preTokens"),
                             "post": m.get("postTokens"), "ms": m.get("durationMs")}
                    break
    with _lock:
        _compacts[path] = (key, found)
    return found


def short(s, n):
    s = re.sub(r"\s+", " ", s or "").strip()
    return s if len(s) <= n else s[:n - 1].rstrip() + "…"


_socket_names = {}


def tool_line(block):
    name, inp = block.get("name", "tool"), block.get("input") or {}
    if name == "SendMessage":
        to = str(inp.get("to", ""))
        to = _socket_names.get(to.removeprefix("uds:"), to)
        return {"kind": "sent", "who": to, "text": str(inp.get("message", ""))}
    if name == "Bash":
        what = inp.get("description") or inp.get("command", "")
    elif name in ("Read", "Edit", "Write", "NotebookEdit"):
        what = os.path.basename(str(inp.get("file_path", "")))
    elif name in ("Agent", "Task"):
        what = inp.get("description", "")
    elif name in ("Grep", "Glob"):
        what = inp.get("pattern", "")
    elif name in ("WebFetch",):
        what = inp.get("url", "")
    elif name in ("WebSearch", "ToolSearch"):
        what = inp.get("query", "")
    elif name == "Skill":
        what = inp.get("skill", "")
    else:
        what = ""
    return {"kind": "tool", "who": name.replace("mcp__", "").split("__")[-1], "text": short(str(what), 140)}


TAG = re.compile(r"<(system-reminder|local-command-stdout|local-command-caveat)>.*?</\1>", re.S)
PASTED_TEXT = re.compile(r'<pasted_content id="[^"]*">\n?(.*?)\n?</pasted_content(?: id="[^"]*")?>', re.S)   # a long paste, as Claude Code wraps it


def user_items(text):
    """What a user-side message says: the owner, another agent, a task finishing, or nothing worth showing."""
    m = re.search(r'<cross-session-message[^>]*from-name="([^"]+)"[^>]*>(.*?)(</cross-session-message>|$)', text, re.S)
    if m:
        return [{"kind": "peer", "who": m.group(1), "text": m.group(2).strip()}]
    if "<task-notification>" in text:
        s = re.search(r"<summary>(.*?)</summary>", text, re.S)
        return [{"kind": "event", "who": "task", "text": s.group(1).strip() if s else "background task finished"}]
    m = re.search(r"<command-name>(.*?)</command-name>", text, re.S)
    if m:
        a = re.search(r"<command-args>(.*?)</command-args>", text, re.S)
        return [{"kind": "event", "who": "command", "text": (m.group(1) + " " + (a.group(1) if a else "")).strip()}]
    # a shell command the owner ran with "!" in the agent's prompt, and what it printed
    m = re.match(r"\s*<bash-input>(.*?)</bash-input>", text, re.S)
    if m:
        return [{"kind": "owner", "who": setting("AGENT_OWNER_NAME") or "Owner", "text": "`! " + m.group(1).strip() + "`"}]
    if re.match(r"\s*<bash-std(out|err)>", text):
        out = "\n".join(x.strip("\n") for x in re.findall(r"<bash-std(?:out|err)>(.*?)</bash-std(?:out|err)>", text, re.S) if x.strip())
        return [{"kind": "shell", "who": "output", "text": "```\n" + out + "\n```" if out else "no output"}]
    if text.startswith("[Request interrupted"):
        return [{"kind": "event", "who": "interrupted", "text": "the turn was stopped"}]
    m = re.match(r"(?:\[[^\]]*\]\s*)?The ([\w-]+) plugin sent a message:\s*(.*)", text, re.S)
    if m:
        return [{"kind": "event", "who": m.group(1), "text": TAG.sub("", m.group(2)).strip()}]
    text = TAG.sub("", text).strip()
    wrapped = re.match(r"<([a-z][\w-]*)[\s>]", text)   # Claude Code's own tagged text; an email's <Message-ID> is the owner's
    if not text or wrapped and wrapped.group(1) != "pasted_content" and "</" + wrapped.group(1) in text \
            or text.startswith("This session is being continued"):
        return []
    text = PASTED_TEXT.sub(lambda m: m.group(1), text).strip()
    return [{"kind": "owner", "who": setting("AGENT_OWNER_NAME") or "Owner", "text": text}]


# Images pasted into a turn, by a short key the page asks for them by; the newest few hundred are kept.
_images = {}


def owner_turn(content):
    """A user-side turn as items: its text through user_items, and any images pasted into it kept in _images and
    named on the turn, which is the owner's even when it has no words."""
    if isinstance(content, str):
        return user_items(content)
    if not isinstance(content, list):
        return []
    items, keys = [], []
    for b in content:
        if not isinstance(b, dict):
            continue
        if b.get("type") == "text":
            items += user_items(b.get("text", ""))
        elif b.get("type") == "image" and (b.get("source") or {}).get("type") == "base64":
            src = b["source"]
            if src.get("media_type") not in IMAGE_TYPES.values():
                continue
            key = hashlib.sha1(src.get("data", "").encode()).hexdigest()[:16]
            with _lock:
                if key not in _images:
                    try:
                        _images[key] = (src["media_type"], base64.b64decode(src.get("data", "")))
                    except ValueError:
                        continue
                    while len(_images) > 300:
                        _images.pop(next(iter(_images)))
            keys.append(key)
    if keys:
        if not items or items[-1]["kind"] != "owner":
            items.append({"kind": "owner", "who": setting("AGENT_OWNER_NAME") or "Owner", "text": ""})
        items[-1]["images"] = keys
    return items


LANE = {"owner": "owner", "said": "owner", "shell": "owner", "peer": "team", "sent": "team", "event": "auto", "tool": "auto"}


# Queued text that is not the owner's: other agents' messages, task notices, nudges and mods' messages.
NOT_OWNER = re.compile(r"^(<[a-z-]+[ >]|\[(Automated nudge|Cross-session|[\w-]+ mod, not the owner))")


def queued(queue, e):
    """Applies one queue-operation record to the queue of messages waiting for the agent's next turn: an enqueue
    adds one; a dequeue takes the oldest; a remove (taken in mid-turn) or popAll (pulled back to the box) takes the
    one with its text."""
    op, text = e.get("operation"), e.get("content")
    if op == "enqueue":
        queue.append({"text": text or "", "ts": e.get("timestamp")})
    elif queue and op in ("dequeue", "remove", "popAll"):
        hit = next((q for q in queue if op != "dequeue" and q["text"] == text), queue[0])
        queue.remove(hit)


def turns(lines, limit):
    """The last `limit` turns in some transcript lines, oldest first, tool runs folded, then the owner's messages
    still queued for the agent, as pending turns."""
    items, queue = [], []
    for raw in lines:
        if not raw.strip():
            continue
        try:
            e = json.loads(raw)
        except ValueError:   # malformed, or bytes that are not text: a crash can leave a line of NULs
            continue
        if e.get("type") == "queue-operation":
            queued(queue, e)
            continue
        if e.get("type") not in ("user", "assistant", "attachment") or e.get("isSidechain"):
            continue
        ts, content = e.get("timestamp"), (e.get("message") or {}).get("content")
        new = []
        origin = e.get("origin") if isinstance(e.get("origin"), dict) else {}
        if e["type"] == "attachment":
            # a message that arrived while the agent was working, the owner's or another agent's, is queued as a command
            a = e.get("attachment") if isinstance(e.get("attachment"), dict) else {}
            if a.get("type") != "queued_command":
                continue
            o = a.get("origin") if isinstance(a.get("origin"), dict) else {}
            if o.get("kind") == "peer":
                new = [{"kind": "peer", "who": str(o.get("name") or "agent"), "text": str(o.get("body") or "").strip()}]
            elif o.get("kind") == "human":
                new = owner_turn(a.get("prompt"))
            else:
                continue
        elif e.get("isMeta"):
            # a message from another session is a meta turn whose origin names the sender
            if origin.get("kind") == "peer":
                new = [{"kind": "peer", "who": str(origin.get("name") or "agent"), "text": str(origin.get("body") or "").strip()}]
            else:
                continue
        elif e["type"] == "user":
            new = owner_turn(content)
        elif isinstance(content, list):
            for b in content:
                # words with no letter or digit in them ("—", ".") are an agent with nothing to say
                if b.get("type") == "text" and re.search(r"[^\W_]", b.get("text", "")):
                    new.append({"kind": "said", "who": "", "text": b["text"].strip()})
                elif b.get("type") == "tool_use":
                    new.append(tool_line(b))
        for it in new:
            it["ts"] = ts
            it["text"] = it["text"][:6000]
        items += new
    # Each turn's lane is who it belongs to: the owner (their messages, and the agent's words, which are written to
    # the owner's screen), the team (messages between agents) or automation (tools, plugins, tasks, commands).
    for it in items:
        it["lane"] = LANE[it["kind"]]
        it["with"] = it["who"] if it["lane"] == "team" else ""
    # Runs of tool calls fold into one line, so the words carry the flow.
    folded = []
    for it in items:
        if it["kind"] == "tool" and folded and folded[-1]["kind"] == "tools":
            folded[-1]["calls"].append(it)
            folded[-1]["ts"] = it["ts"]
        elif it["kind"] == "tool":
            folded.append({"kind": "tools", "ts": it["ts"], "lane": "auto", "with": "", "calls": [it]})
        else:
            folded.append(it)
    for it in folded:
        if it["kind"] == "tools":
            it["calls"] = it["calls"][-6:]
    pending = [{"kind": "pending", "who": "", "text": q["text"].strip()[:6000], "ts": q["ts"], "lane": "owner", "with": ""}
               for q in queue if q["text"].strip() and not NOT_OWNER.match(q["text"])]
    return folded[-limit:] + pending


def feed(sid, limit):
    """The last `limit` turns of a session's conversation, oldest first, from the end of its transcript."""
    path = transcript(sid) if sid else None
    if not path:
        return []
    try:
        st = os.stat(path)
    except OSError:
        return []
    key = (path, limit)
    with _lock:
        hit = _feeds.get(key)
        if hit and hit[0] == (st.st_size, st.st_mtime):
            return hit[1]
    # Tool output and images can fill the end of a transcript, so it is read further back until it holds `limit` turns.
    span = TAIL_BYTES
    while True:
        with open(path, "rb") as f:
            f.seek(max(0, st.st_size - span))
            lines = f.read().split(b"\n")[1:] if st.st_size > span else f.read().split(b"\n")
        out = turns(lines, limit)
        if len(out) >= limit or span >= st.st_size or span >= TAIL_MAX:
            break
        span *= 4
    with _lock:
        _feeds[key] = ((st.st_size, st.st_mtime), out)
    return out


# ── a prompt waiting on the owner ─────────────────────────────────────────────
SEPARATOR = re.compile(r"^\s*[╌─━]{10,}\s*$")
TOP_RULE = re.compile(r"^\s*[─━]{10,}\s*$")
OPTION = re.compile(r"^\s*(?:❯\s*)?(\d+)\.\s+(.*\S)")
CURSOR_ROW = re.compile(r"^(\s*❯\s+)(\S.*)$")   # an unnumbered choice's cursor row ("❯ No, exit"); its label starts where the text does
SUBMIT_ROW = re.compile(r"^\s*(?:❯\s*)?Submit$")   # the unnumbered row that ends a multi-select question
PREVIEW = re.compile(r"\s{2,}[┌│└].*$")   # a question with previews draws the cursor's option's preview to the right of the options
CHECKBOX = re.compile(r"^\[[ ✔]\]\s?")   # a multi-select option's tick box
DIM = re.compile(r"\x1b\[2m.*?\x1b\[(?:0|22)?m")   # a dim run: an empty field's placeholder
ESCAPES = re.compile(r"\x1b\[[0-9;:?]*[A-Za-z]")


def ask_of(pane):
    """The question an agent's pane is waiting on - a permission prompt or a choice - with its options, read
    from the screen: Claude Code writes a prompt to the transcript only once it is answered. Its text runs from just
    after the solid rule that opens the prompt to the end of the options, so a permission prompt keeps its
    heading and command; the dashed rules inside it become gaps. Its options are numbered from 1, each with its
    label; "Type something." is a field the owner's own words go into ("typed"). A multi-select question's options
    keep their tick boxes in their labels, its field is the one just above its Submit row, and Submit is an option
    numbered 0. A question with previews ("preview") draws the one for the option under the cursor beside the
    options; it is cut from their labels, which would otherwise change as the cursor moves.

    A prompt on screen ends in a footer naming Esc ("Esc to cancel"), and only options inside it - below the solid rule
    above that footer - are its own: a numbered list higher up, in the conversation or a prompt already answered, is
    not. Some prompts (trusting a folder, confirming a tool's action) list their options unnumbered, the cursor's row
    marked ❯ and the others lined up with its text; those are numbered here in order and answered by moving the cursor
    ("select", with "cursor" the option it is on). None when no prompt's options are on screen."""
    lines = [l.rstrip() for l in run("tmux", "capture-pane", "-p", "-t", pane).splitlines()]
    foot = next((i for i in range(len(lines) - 1, -1, -1) if "Esc to cancel" in lines[i]), None)
    # A rule with a later option under it ("5. Chat about this", below "4. Type something.") splits the options; it does
    # not open the prompt, which would leave option 1 above it and the prompt unread (Deacon's, 2026-11-10).
    def splits_options(i):
        below = next((l for l in lines[i + 1:foot] if l.strip()), "")
        m = OPTION.match(below)
        return bool(m) and int(m.group(1)) > 1
    top = 0 if foot is None else next((i + 1 for i in range(foot - 1, max(-1, foot - 80), -1)
                                       if TOP_RULE.match(lines[i]) and not splits_options(i)), 0)
    opts = [i for i, l in enumerate(lines) if re.match(r"^\s*(❯\s*)?1\.\s", l) and (foot is None or top <= i < foot)]
    if not opts:
        return select_of(lines, top, foot) if foot is not None else None
    first = opts[-1]
    above = range(first - 1, max(-1, first - 80), -1)
    start = next((i + 1 for i in above if TOP_RULE.match(lines[i])),
                 next((i + 1 for i in above if SEPARATOR.match(lines[i])), max(0, first - 12)))
    end = next((i + 1 for i in range(first, len(lines)) if "Esc to cancel" in lines[i]), len(lines))
    block = ["" if SEPARATOR.match(l) else l for l in lines[start:end] if l.strip()]
    block = [l for i, l in enumerate(block) if l or (0 < i < len(block) - 1 and block[i - 1])]
    boxed = re.compile(r"^\s*│ ?")
    pad = min((len(l) - len(l.lstrip()) for l in block if l and not boxed.match(l)), default=0)
    text = "\n".join(boxed.sub("", l) if boxed.match(l) else l[pad:] for l in block)
    if not text:
        return None
    # a field under the cursor shows what is written in it, not its placeholder, and the footer then offers an editor
    editing = "ctrl+g to edit" in lines[end - 1]
    options, rows = [], [boxed.sub("", l) for l in lines[first:end]]
    preview = any(PREVIEW.search(l) for l in rows)
    for i, l in enumerate(rows):
        if SUBMIT_ROW.match(l):
            options.append({"n": 0, "label": "Submit", "typed": False})
            continue
        m, n = OPTION.match(l), sum(1 for o in options if o["n"]) + 1
        if m and int(m.group(1)) == n:
            label = PREVIEW.sub("", m.group(2))
            typed = (label.startswith("Type something") or editing and l.lstrip().startswith("❯")
                     or bool(CHECKBOX.match(label)) and i + 1 < len(rows) and bool(SUBMIT_ROW.match(rows[i + 1])))
            options.append({"n": n, "label": label, "typed": typed})
    return {"text": text, "options": options, **({"preview": True} if preview else {})}


def select_of(lines, top, foot):
    """An unnumbered prompt between its rule (top) and its footer (foot): the cursor's row and the rows whose text lines
    up with its label, as options numbered in order; None when the prompt has no cursor row."""
    rows = [(i, ESCAPES.sub("", l)) for i, l in enumerate(lines[top:foot], top)]
    at = next((k for k, (_, l) in enumerate(rows) if CURSOR_ROW.match(l)), None)
    if at is None:
        return None
    col = len(CURSOR_ROW.match(rows[at][1]).group(1))
    lined = lambda l: bool(CURSOR_ROW.match(l)) or (len(l) - len(l.lstrip()) == col and bool(l.strip()))
    lo = at
    while lo > 0 and lined(rows[lo - 1][1]):
        lo -= 1
    hi = at
    while hi + 1 < len(rows) and lined(rows[hi + 1][1]):
        hi += 1
    options = [{"n": k + 1, "label": (CURSOR_ROW.match(l).group(2) if CURSOR_ROW.match(l) else l.strip()), "typed": False}
               for k, (_, l) in enumerate(rows[lo:hi + 1])]
    block = [l for _, l in rows[:lo] if l.strip() and not SEPARATOR.match(l)] + [lines[foot]]
    pad = min((len(l) - len(l.lstrip()) for l in block), default=0)
    text = "\n".join([l[pad:] for l in block[:-1]] + [r[1].strip() for r in rows[lo:hi + 1]] + [block[-1].strip()])
    return {"text": text, "options": options, "select": True, "cursor": at - lo + 1}


def by_lane(items, n):
    """The newest n turns of each lane, in order, so a filtered view still has n turns to show."""
    keep, seen = [], {}
    for it in reversed(items):
        seen[it["lane"]] = seen.get(it["lane"], 0) + 1
        if seen[it["lane"]] <= n:
            keep.append(it)
    return keep[::-1]


SPINNER = re.compile(r"^\s*[·✢✳✶✻✽*]\s+(\S[^()\n]*?…)\s*\(([^)]*)\)")


def working_of(pane):
    """The line a working agent's pane shows under its turn - "✢ Pollinating… (10s · ↓ 668 tokens)" - as
    "Pollinating… 10s · ↓ 668 tokens"; None when there is none on screen."""
    for line in reversed(run("tmux", "capture-pane", "-p", "-t", pane).splitlines()):
        m = SPINNER.match(line)
        if m:
            return m.group(1) + " " + m.group(2).strip()
    return None


OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")   # a terminal's own sequence, such as a link round /rc
BOX_RULE = re.compile(r"^\s*[╌─━]{10,}")   # the input box's edges; the top one can carry the session's name
FOOTER = re.compile(r"^(?:⏵⏵|⏸|\?\s+for shortcuts)|esc to interrupt")


def pane_footer(pane):
    """The words of Claude Code's footer under the pane's input box ("⏵⏵ auto mode on · 1 shell"), less its shift+tab
    hint, auto mode and anything right-aligned beside it ("1 shell"); "" when it says nothing else, None while there
    is no input box on screen, as when a prompt is open."""
    plain = [ESCAPES.sub("", OSC.sub("", l)).rstrip() for l in run("tmux", "capture-pane", "-p", "-e", "-t", pane).splitlines()]
    rules = [i for i, l in enumerate(plain) if BOX_RULE.match(l)]
    if len(rules) < 2 or not any(plain[i].lstrip().startswith("❯") for i in range(rules[-2] + 1, rules[-1])):
        return None
    for p in plain[rules[-1] + 1:]:
        if p.strip() and len(p) - len(p.lstrip()) < 10 and FOOTER.search(p.strip()):
            footer = re.sub(r"\s*\(shift\+tab to cycle\)", "", re.split(r"\s{3,}", p.strip())[0])
            return " · ".join(x for x in footer.split(" · ") if x != "⏵⏵ auto mode on")   # the team's usual mode
    return ""


def with_ask(items, status, pane):
    """The conversation, ending with the pane's open prompt while the agent is waiting on one, or with what its
    pane shows it doing while it works, then the owner's messages queued behind it."""
    pending = [it for it in items if it["kind"] == "pending"]
    items = [it for it in items if it["kind"] != "pending"]
    if not pane or status not in ("waiting", "busy"):
        return items   # a queue lasts only as long as the turn it waits behind
    if status == "waiting":
        ask = ask_of(pane["pane"])
        return items + ([{"kind": "ask", "who": "waiting for you", "text": ask["text"], "options": ask["options"], "cursor": ask.get("cursor"), "ts": None,
                          "lane": "owner"}] if ask else []) + pending
    now = working_of(pane["pane"])
    return items + ([{"kind": "live", "who": "working", "text": now, "ts": None, "lane": "owner"}] if now else []) + pending


def open_ask(name, pane):
    """The prompt open in the agent's pane, only while its session is waiting on one: a numbered list on screen at any
    other time is not a prompt."""
    return ask_of(pane) if (live_sessions().get(name) or {}).get("status") == "waiting" else None


def suggestion(pane):
    """The prompt Claude Code suggests in the pane: the dim text alone on its input line (❯), before anything is typed;
    "" for none."""
    for line in reversed(run("tmux", "capture-pane", "-p", "-e", "-t", pane).splitlines()):
        if "❯" not in ESCAPES.sub("", line):
            continue
        m = re.fullmatch(r"(?:\x1b\[[0-9;:]*m)*❯[\s\xa0]+\x1b\[2m([^\x1b]+)\x1b\[0m(?:\x1b\[[0-9;:]*m)*\s*", line.rstrip())
        return m[1].strip() if m else ""
    return ""


def frontmatter(path):
    """A command's or skill's name and description, from the front matter of its Markdown file; a value written over
    several indented lines (>- or |) is joined into one."""
    meta, key = {}, None
    try:
        with open(path) as f:
            if f.readline().strip() == "---":
                for line in f:
                    if line.strip() == "---":
                        break
                    if key and line[:1] in " \t":
                        meta[key] = (meta[key] + " " + line.strip()).strip()
                        continue
                    k, _, v = line.partition(":")
                    key, v = k.strip(), v.strip()
                    meta[key] = "" if v in (">", ">-", "|", "|-") else v.strip("\"'")
    except OSError:
        pass
    return meta


# Claude Code's own commands, for the message box's / list (its list in the terminal is not readable from here).
BUILTIN_COMMANDS = {
    "add-dir": "Add a working directory", "agents": "Manage subagents", "clear": "Clear the conversation",
    "compact": "Compact the conversation, with optional focus", "config": "Open the settings",
    "context": "Show what fills the context", "cost": "Show this session's cost and duration",
    "doctor": "Check the installation", "effort": "Set the reasoning effort", "exit": "Exit Claude Code",
    "export": "Export the conversation", "help": "Show help", "hooks": "Manage hooks", "init": "Write a CLAUDE.md",
    "mcp": "Manage MCP servers", "memory": "Edit memory files", "model": "Choose the model",
    "permissions": "Manage permissions", "plugin": "Manage plugins", "rename": "Rename the session",
    "resume": "Resume a conversation", "review": "Review a pull request", "rewind": "Rewind the conversation",
    "status": "Show status", "statusline": "Set up the status line", "todos": "Show the todo list",
    "usage": "Show plan usage",
}


def commands():
    """Every / command an agent's message box can offer: Claude Code's own, the user's and the team's commands and
    skills, and the skills and commands of the plugins on this machine (plugin:name), each once."""
    found = {n: {"name": n, "desc": d, "from": "built-in"} for n, d in BUILTIN_COMMANDS.items()}

    def add(name, path, src):
        if name and name not in found:
            found[name] = {"name": name, "desc": frontmatter(path).get("description", "")[:160], "from": src}
    for base, src in ((CLAUDE, "user"), (os.path.join(ROOT, ".claude"), "project")):
        for f in sorted(glob.glob(os.path.join(base, "commands", "**", "*.md"), recursive=True)):
            add(os.path.relpath(f, os.path.join(base, "commands"))[:-3].replace(os.sep, ":"), f, src)
        for f in sorted(glob.glob(os.path.join(base, "skills", "**", "SKILL.md"), recursive=True)):
            name = frontmatter(f).get("name") or os.path.basename(os.path.dirname(f))
            synced = os.sep + "synced" + os.sep in f   # the account's skills, which Claude Code names anthropic-skills:
            add(("anthropic-skills:" if synced else "") + name, f, "claude.ai" if synced else src)
    for pj in sorted(glob.glob(os.path.join(CLAUDE, "plugins", "**", ".claude-plugin", "plugin.json"), recursive=True)):
        if "/.trash/" in pj or "/marketplaces/" in pj:
            continue
        root = os.path.dirname(os.path.dirname(pj))
        try:
            with open(pj) as f:
                plugin = json.load(f).get("name") or os.path.basename(root).split("~")[0]
        except (OSError, ValueError):
            continue
        for f in sorted(glob.glob(os.path.join(root, "skills", "*", "SKILL.md"))):
            add(f"{plugin}:{frontmatter(f).get('name') or os.path.basename(os.path.dirname(f))}", f, plugin)
        for f in sorted(glob.glob(os.path.join(root, "commands", "*.md"))):
            add(f"{plugin}:{os.path.basename(f)[:-3]}", f, plugin)
    return sorted(found.values(), key=lambda c: c["name"])


def field_of(pane, n):
    """What option n's text field holds while the pane's cursor is on it, its dim placeholder left out; None while the
    cursor is elsewhere. The field runs on over the indented lines under it, to a gap, a rule, the next option or a
    Submit row; a multi-select field's tick box is not part of it."""
    raw = run("tmux", "capture-pane", "-p", "-e", "-t", pane).splitlines()
    plain = [ESCAPES.sub("", l).rstrip() for l in raw]
    at = next((i for i in range(len(plain) - 1, -1, -1) if re.match(rf"\s*❯\s*{n}\.(\s|$)", plain[i])), None)
    if at is None:
        return None
    # the option's number can be dim too, so the placeholder is dropped only from what follows it
    after = re.search(rf"{n}\.(?:\x1b\[[0-9;:]*m)*", raw[at])
    lines = [ESCAPES.sub("", DIM.sub("", l)).rstrip() for l in raw]
    text = [ESCAPES.sub("", DIM.sub("", raw[at][after.end():]))]
    for l in lines[at + 1:]:
        if not l.strip() or SEPARATOR.match(l) or OPTION.match(l) or SUBMIT_ROW.match(l):
            break
        text.append(l)
    return CHECKBOX.sub("", " ".join(t.strip() for t in text).strip())


def answer(name, n, label, text):
    """Answers the prompt open in the agent's pane with its option n, while that option still has this label. An
    ordinary option ("Chat about this" among them) is chosen with its digit alone, as a prompt takes it without Enter;
    a typed option gets the text written into its field, read back and sent with Enter. In a multi-select question
    a digit ticks its option, and works only with the cursor off the field and the Submit row, so the cursor is
    taken to the option first; the field is reached with the arrows and ticks itself once written in, as Enter
    there would untick it; and Submit is Enter on its row. Keys go in only while the prompt is the one the button
    was drawn for. Returns an HTTP status and what happened."""
    where = panes().get(name)
    if not where:
        return 404, "that agent is not in a pane"
    pane = where["pane"]
    ask = open_ask(name, pane)
    opt = next((o for o in (ask or {}).get("options", []) if o["n"] == n and o["label"] == label), None)
    if not opt:
        return 409, "that question has changed or closed: nothing was sent"
    if opt["typed"] and not text:
        return 400, "write the answer first"
    key = lambda *k: subprocess.run(["tmux", "send-keys", "-t", pane, *k]).returncode == 0

    def gone():
        """A test for the prompt, as it is on screen now, having closed or moved on to another question."""
        was = (ask_of(pane) or {}).get("text")
        return lambda: (ask_of(pane) or {}).get("text") != was

    def clear(m):
        """Empties option m's field a visual line at a time, as Ctrl+U clears to the start of the line it is on."""
        for _ in range(where["rows"]):
            if not field_of(pane, m):
                break
            key("C-u")
            time.sleep(0.15)
        return field_of(pane, m) == ""

    multi = any(o["n"] == 0 for o in ask["options"])
    order = {o["n"]: i for i, o in enumerate(ask["options"])}

    def cursor():
        """The option the pane's cursor is on (0 for Submit), or None when it is on none of them."""
        for l in reversed(run("tmux", "capture-pane", "-p", "-t", pane).splitlines()):
            m = re.match(r"\s*❯\s*(?:(\d+)\.(?:\s|$)|Submit$)", ESCAPES.sub("", l).rstrip())
            if m:
                return int(m.group(1) or 0)
        return None

    def move_to(m):
        """Moves the cursor to option m a row at a time; whether it got there."""
        for _ in range(2 * len(order)):
            at = cursor()
            if at == m or at not in order:
                break
            key("Up" if order[m] < order[at] else "Down")
            wait_for(lambda: cursor() != at, 1, 0.1)
        return cursor() == m

    try:
        if ask.get("select"):
            # unnumbered options: the cursor is taken to the option a row at a time, then Enter chooses it
            for _ in range(2 * len(order)):
                at = (open_ask(name, pane) or {}).get("cursor")
                if at == n or at not in order:
                    break
                key("Up" if n < at else "Down")
                wait_for(lambda: (open_ask(name, pane) or {}).get("cursor") != at, 1, 0.1)
            now = open_ask(name, pane) or {}
            if now.get("cursor") != n or now.get("options") != ask["options"]:
                return 500, f"the cursor did not reach option {n}: nothing was chosen"
            closed = gone()
            if not key("Enter") or not wait_for(closed, 3, 0.2):
                return 500, f"option {n} was not taken"
            return 200, "chosen"
        if multi and not opt["typed"]:
            closed = gone()
            if not move_to(n) or not key("Enter" if n == 0 else str(n)) or not wait_for(closed, 3, 0.2):
                return 500, "Submit was not taken" if n == 0 else f"option {n} was not taken"
            return 200, "submitted" if n == 0 else "ticked or unticked"
        if multi and not move_to(n):
            return 500, "the answer's field did not open: nothing was sent"
        # a digit pressed while the cursor is in a field is typed into it, so the cursor leaves any field it is in first
        for o in [] if multi else ask["options"]:
            if o["typed"] and o["n"] != n and field_of(pane, o["n"]) is not None:
                if not clear(o["n"]) or not key("Up") or not wait_for(lambda: field_of(pane, o["n"]) is None, 1, 0.1):
                    return 500, "the pane's cursor is stuck in another answer's field: nothing was sent"
        if not opt["typed"] and ask.get("preview"):
            # a question with previews is answered by Enter on the option, the cursor taken to it first; the
            # preview beside it changes as it moves, so the test for the prompt closing is taken after
            if not move_to(n):
                return 500, f"the cursor did not reach option {n}: nothing was sent"
            closed = gone()
            if not key("Enter") or not wait_for(closed, 3, 0.2):
                return 500, f"option {n} was not taken"
            return 200, "chosen"
        if not opt["typed"]:
            closed = gone()
            if not key("-l", str(n)) or not wait_for(closed, 3, 0.2):
                return 500, f"option {n} was not taken"
            return 200, "chosen"
        if field_of(pane, n) is None and (not key(str(n)) or not wait_for(lambda: field_of(pane, n) is not None, 2, 0.1)):
            return 500, "the answer's field did not open: nothing was sent"
        if field_of(pane, n) and not clear(n):
            return 500, "the answer's field held text that would not clear: nothing was sent"
        buf = "agents-web-" + uuid.uuid4().hex[:12]
        subprocess.run(["tmux", "load-buffer", "-b", buf, "-"], input=text.encode())
        subprocess.run(["tmux", "paste-buffer", "-p", "-r", "-d", "-b", buf, "-t", pane])
        squash = lambda s: re.sub(r"\s+", "", s or "")
        if not wait_for(lambda: squash(field_of(pane, n)) == squash(text), 2, 0.2):
            clear(n)
            return 500, "the answer did not go into its field as written, so the field was cleared: nothing was sent"
        if multi:
            return 200, "written and ticked: Submit sends it"
        time.sleep(0.2)   # an Enter in the same burst as the paste can be swallowed
        closed = gone()
        if not key("Enter") or not wait_for(closed, 3, 0.2):
            return 500, "the answer is in its field, but Enter was not taken"
        return 200, "answered"
    finally:
        with _lock:
            _state["at"] = 0


# ── the state the page draws ──────────────────────────────────────────────────
def colour(role):
    """The role's colour: AGENT_COLOUR_<ROLE> in harness.env, one of Claude Code's /color names, else the role's own."""
    key = "AGENT_COLOUR_" + role.upper().replace("-", "_")
    c = CC_COLOUR.get(os.environ[key].strip() if key in os.environ else role_of(role)[3])
    return xterm(c) if c else "#8b949e"


def state():
    now = time.time()
    live, rows, burns, last = live_sessions(), context_rows(), burn(), last_sessions()
    where, held = panes(), claims()
    agents, bench = [], []
    for r in grouped(roster()):
        name = r["name"]
        role, role_name, tab, _ = role_of(r["role"])
        rec = live.get(name)
        if not rec and not where.get(name):
            # a developer or tester with no session is on the bench, waiting for agent-spawn.sh; a standing agent with
            # none is there too, stopped, and its menu starts it (owner, 2026-10-31). One the page is starting leaves
            # the bench at once, as a stopped agent.
            if name not in _starting and (role in ("dev", "tester") or role in STANDING):
                # its model, effort and last compaction are its last session's, the model read from its transcript
                # once the session's context row has gone
                was = last.get(name)
                row = rows.get(was, {}) if was else {}
                bench.append({"name": name, "fullName": r["fullName"], "role": role, "roleName": role_name, "colour": colour(r["role"]), **portraits(name),
                              "model": row.get("model") or transcript_model(was), "effort": row.get("effort", ""),
                              "lastCompact": last_compact(was), "standing": role in STANDING})
            continue
        sid = (rec or {}).get("sessionId")
        # a stopped agent's model, effort, context and last compaction are its last session's, as it left them
        was = sid or last.get(name)
        row = rows.get(was, {}) if was else {}
        ctx = row.get("context") or {}
        used, window = ctx.get("used"), ctx.get("window") or 0
        ser = series(burns.get(sid), now) if sid else []
        since = ((rec or {}).get("statusUpdatedAt") or 0) / 1000
        want, want_held = wanted(sid) if sid else (None, None)
        agents.append({
            "name": name, "fullName": r["fullName"], "role": role, "roleName": role_name, "colour": colour(r["role"]),
            "tab": tab, "live": bool(rec), "status": (rec or {}).get("status") or ("off" if not rec else "?"),
            "held": int(now - since) if since else None,
            "wanted": want, "wantedHeld": want_held,
            "ctxUsed": used, "ctxWindow": window,
            "ctxPct": round(used * 100 / window) if used and window else None,
            "model": row.get("model", ""), "effort": row.get("effort", ""),
            "ticket": held.get(name.lower(), ""),
            "cwd": row.get("worktree") or os.path.basename((rec or row).get("cwd") or ""),
            "series": ser, "rate": last_minute(ser, now), **portraits(name),
            "compacting": bool(sid) and hook_compacting(sid, now), "lastCompact": last_compact(was),
            "feed": with_ask(by_lane(feed(sid, 300), 10) if sid else [], (rec or {}).get("status"), where.get(name)),
            "suggest": suggestion(where[name]["pane"]) if rec and rec.get("status") == "idle" and name in where else "",
            "pfoot": pane_footer(where[name]["pane"]) if rec and name in where else None,
        })
    # the team has stopped once team/team-paused.sh says so and no running agent on it is busy or waiting; a lead that has
    # not marked it paused ten minutes after being asked is taken not to be stopping it
    paused = team_paused()
    if paused and not any(a["live"] and a["role"] != "pa" and (a["status"] in ("busy", "waiting") or a["compacting"]) for a in agents) or not paused and now - _team_stop["at"] > 600:
        _halting.discard("team")
    # Sections as byobu has them: each agent in the session its pane is in, the sessions in byobu's (name) order; an
    # agent with no pane there (its own spawn session, or none) goes in its role's section, after them.
    sessions = sorted({where[a["name"]]["session"] for a in agents if where.get(a["name"], {}).get("session")})
    for a in agents:
        a["tab"] = where.get(a["name"], {}).get("session") or a["tab"]
    tabs = sessions + [t for t in TAB_ORDER if any(a["tab"] == t for a in agents)]
    tabs += sorted({a["tab"] for a in agents} - set(tabs))
    st = {
        "now": now, "week": account_pct(rows, "week"), "session": account_pct(rows, "five_hour"), "plan": (plan := budget_plan()), "even": even_plan(plan), "day": day_budget(),
        "disk": disk(),
        "tabs": tabs,
        "project": setting("AGENT_PROJECT_TITLE") or PROJECT, "agents": agents, "bench": bench, "owner": setting("AGENT_OWNER_NAME") or "Owner", "shownNames": shown_names(),
        "teamPaused": paused, "nudgerPaused": os.path.exists(NUDGER_PAUSED), "starting": sorted(_starting), "halting": sorted(_halting),
        "compacting": sorted(_compacting | {a["name"] for a in agents if a["compacting"]}), "teamUp": team_up(),
        "lead": lead_name({a["name"] for a in agents if a["live"]}),
    }
    return {**st, "plugins": plugins(bar_facts(st))}


# Portraits for the Characters pane: <name in lower case>.png, .webp or .jpg in this folder (AGENTS_PORTRAITS, else
# ~/.claude/agents-portraits), served at /portraits/. An agent can have a second, <name>-alt, shown in its menu
# instead.
PORTRAITS = os.environ.get("AGENTS_PORTRAITS") or os.path.join(HOME, ".claude", "agents-portraits")
PORTRAIT_TYPES = {".png": "image/png", ".webp": "image/webp", ".jpg": "image/jpeg"}


def portrait(name, kind=""):
    """The page's address for an agent's portrait (kind "-alt" for the second), with its change time so a new picture
    shows at once; "" for none."""
    for ext in PORTRAIT_TYPES:
        f = os.path.join(PORTRAITS, name.lower() + kind + ext)
        if os.path.isfile(f):
            return f"/portraits/{name.lower()}{kind}{ext}?v={int(os.path.getmtime(f))}"
    return ""


def portraits(name):
    """An agent's portrait fields: the one shown, and the one for its menu ("" for none)."""
    return {"portrait": portrait(name), "altPortrait": portrait(name, "-alt")}


_state = {"at": 0, "body": b""}
_state_build = threading.Lock()


def state_json():
    """The state, built at most once every two seconds. One request builds it at a time and those arriving meanwhile
    wait for its answer: each building its own would multiply the work while the page's polls kept coming, until no
    request finished."""
    with _lock:
        if time.time() - _state["at"] < 2:
            return _state["body"]
    with _state_build:
        with _lock:
            if time.time() - _state["at"] < 2:
                return _state["body"]
        body = json.dumps(state()).encode()
        with _lock:
            _state.update(at=time.time(), body=body)
    return body


def agent_json(name):
    rec = live_sessions().get(name)
    where = panes().get(name)
    screen = ""
    if where:
        screen = ansi_html(run("tmux", "capture-pane", "-p", "-e", "-t", where["pane"]).rstrip("\n"), shown_names())
    conv = with_ask(by_lane(feed(rec.get("sessionId"), 300), 60), rec.get("status"), where) if rec else []
    return json.dumps({"name": name, "feed": conv, "screen": screen,
                       "cols": (where or {}).get("cols", 0), "rows": (where or {}).get("rows", 0)}).encode()


def team_json():
    """Every message between running agents, oldest first, the last 200: each taken from its recipient's conversation,
    so a message is listed once, not again as its sender's. Only senders on the roster count, benched or not: a helper
    an agent starts for itself (Claude Code's Explore, say) hands its report back the same way, but it is not on the team."""
    try:
        with open(ROSTER) as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        data = {}
    team, msgs = {a.get("name") for a in (data.get("agents") or []) + (data.get("assistants") or [])} - {None}, []
    for name, rec in live_sessions().items():
        for it in feed(rec.get("sessionId"), 400):
            if it["kind"] == "peer" and it["who"] in team:
                msgs.append({"from": it["who"], "to": name, "text": it["text"], "ts": it["ts"]})
    msgs.sort(key=lambda m: m["ts"] or "")
    return json.dumps(msgs[-200:]).encode()


IMAGE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp"}
DOC_TYPES = {".md", ".markdown", ".txt", ".sql", ".log"}   # what /doc shows; the page links the same (DOC)
PASTED = os.path.join(STATE_DIR, "pasted")   # images and files added in the page, kept for the agents to read


# Access's signing certificates, fetched once an hour (and again for a key not yet seen), and the tokens already
# checked, until they expire.
_access = {"certs": {}, "at": 0.0, "ok": {}}


def access_certs():
    with urllib.request.urlopen(f"https://{ACCESS_TEAM}.cloudflareaccess.com/cdn-cgi/access/certs", timeout=10) as r:
        return {c["kid"]: c["cert"] for c in json.load(r).get("public_certs", [])}


def b64url(part):
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


def access_ok(token):
    """Whether a Cf-Access-Jwt-Assertion is Access's own for this page: RS256, signed with one of the team's
    certificates (checked with openssl, as the server keeps to the standard library), for this application, issued by
    the team and in date."""
    if not (PUBLIC_HOST and ACCESS_TEAM and ACCESS_AUD and token):
        return False
    now = time.time()
    with _lock:
        if _access["ok"].get(token, 0) > now:
            return True
    try:
        head, body, sig = token.split(".")
        hdr, claims = json.loads(b64url(head)), json.loads(b64url(body))
        aud = claims.get("aud") if isinstance(claims.get("aud"), list) else [claims.get("aud")]
        if hdr.get("alg") != "RS256" or ACCESS_AUD not in aud or claims.get("iss") != f"https://{ACCESS_TEAM}.cloudflareaccess.com" \
                or not now < float(claims.get("exp", 0)) or float(claims.get("nbf", 0)) > now + 60:
            return False
        with _lock:
            stale = now - _access["at"] > 3600 or hdr.get("kid") not in _access["certs"]
        if stale and now - _access["at"] > 10:
            certs = access_certs()
            with _lock:
                _access.update(certs=certs, at=now)
        with _lock:
            cert = _access["certs"].get(hdr.get("kid"))
        if not cert:
            return False
        with tempfile.TemporaryDirectory() as d:
            key = subprocess.run(["openssl", "x509", "-pubkey", "-noout"], input=cert.encode(), capture_output=True, timeout=10).stdout
            open(os.path.join(d, "key"), "wb").write(key)
            open(os.path.join(d, "sig"), "wb").write(b64url(sig))
            good = subprocess.run(["openssl", "dgst", "-sha256", "-verify", os.path.join(d, "key"), "-signature", os.path.join(d, "sig")],
                                  input=f"{head}.{body}".encode(), capture_output=True, timeout=10).returncode == 0
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, urllib.error.URLError):
        return False
    if good:
        with _lock:
            _access["ok"] = {k: v for k, v in _access["ok"].items() if v > now}
            _access["ok"][token] = float(claims["exp"])
    return good


class Handler(BaseHTTPRequestHandler):
    def here(self):
        """Whether the request is the page's own: addressed to this host and port, or to the public name with
        Access's token for it."""
        host = self.headers.get("Host")
        return host in {f"127.0.0.1:{PORT}", f"localhost:{PORT}"} or \
            bool(PUBLIC_HOST) and host == PUBLIC_HOST and access_ok(self.headers.get("Cf-Access-Jwt-Assertion"))

    def send(self, code, body, ctype, cache="no-store", save_as=None, version=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", cache)
        if version:   # a document's sha256, for a File pane's edit to say which version it began from
            self.send_header("X-Doc-Version", version)
        if save_as:   # a download, not a page: the browser saves it under this name
            self.send_header("Content-Disposition", "attachment; filename*=UTF-8''" + urllib.parse.quote(save_as))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if not self.here():   # any other name, the public one unset among them, is refused, reads as well as sends
            return self.send(403, b"sign in through Cloudflare Access\n", "text/plain")
        if path == "/":
            self.send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif path == "/api/team":
            self.send(200, team_json(), "application/json")
        elif path == "/api/state":
            self.send(200, state_json(), "application/json")
        elif path == "/api/perf":
            self.send(200, perf_json(), "application/json")
        elif path == "/api/perf/history":
            q = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            try:
                h = perf_history(q.get("key", [""])[0], int(q.get("span", ["0"])[0]))
            except ValueError:
                h = None
            self.send(200 if h else 404, json.dumps(h).encode() if h else b"no such series\n", "application/json" if h else "text/plain")
        elif path == "/api/meetings":
            self.send(200, meetings_json(), "application/json")
        elif path == "/api/daylog":
            self.send(200, daylog_json(), "application/json")
        elif path == "/api/tokens":
            self.send(200, tokens_json(), "application/json")
        elif path == "/api/workqueue":
            self.send(200, workqueue_json(), "application/json")
        elif path == "/api/commands":
            self.send(200, json.dumps(commands()).encode(), "application/json")
        elif path.startswith("/api/agent/") and re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", path[11:]):
            self.send(200, agent_json(path[11:]), "application/json")
        elif path == "/img":
            self.image()
        elif path == "/doc":
            self.doc()
        elif path == "/dir":
            self.listing()
        elif m := re.fullmatch(r"/portraits/([a-z][a-z0-9_-]*)(\.png|\.webp|\.jpg)", path):
            f = os.path.join(PORTRAITS, m[1] + m[2])
            if not os.path.isfile(f):
                return self.send(404, b"no such portrait\n", "text/plain")
            with open(f, "rb") as fh:
                self.send(200, fh.read(), PORTRAIT_TYPES[m[2]], "private, max-age=86400")
        else:
            self.send(404, b"not found\n", "text/plain")

    def doc(self):
        """A document an agent names by its full path ("~/…" or "/home/…"), as text for the page to show: only from the
        page itself (the Host check keeps other sites out), only Markdown, plain text, SQL or a log (never a settings
        or key file), and only from under the home directory or a scratchpad (shown_file)."""
        if not self.here():
            return self.send(403, b"only the team page\n", "text/plain")
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        real = os.path.realpath(os.path.expanduser(query.get("p", [""])[0]))
        if (os.path.splitext(real)[1].lower() not in DOC_TYPES or not shown_file(real)
                or not os.path.isfile(real) or os.path.getsize(real) > 2_000_000):
            return self.send(404, b"no such document\n", "text/plain")
        with open(real, "rb") as f:
            data = f.read()
        # "save" (the viewer's Save as…) sends it as a file to keep, under its own name.
        self.send(200, data, "text/plain; charset=utf-8", version=hashlib.sha256(data).hexdigest(),
                  save_as=os.path.basename(real) if query.get("save") else None)

    def listing(self):
        """What a folder under the home directory holds, for a File pane's path box to browse: its folders and the
        documents /doc shows, by name only (never their contents), on the same terms as /doc. "~/" names the folder
        as the page gave it, so the page can build paths on it."""
        if not self.here():
            return self.send(403, b"only the team page\n", "text/plain")
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        real = os.path.realpath(os.path.expanduser(query.get("p", [""])[0] or "~"))
        if not (real == HOME or real.startswith(HOME + os.sep)) or not os.path.isdir(real):
            return self.send(404, b"no such folder\n", "text/plain")
        out = []
        try:
            with os.scandir(real) as it:
                for e in it:
                    try:
                        if e.is_dir():
                            if not e.is_symlink() or os.path.realpath(e.path).startswith(HOME + os.sep):
                                out.append({"name": e.name, "dir": True})
                        elif os.path.splitext(e.name)[1].lower() in DOC_TYPES and e.is_file():
                            out.append({"name": e.name, "dir": False})
                    except OSError:
                        pass
                    if len(out) >= 2000:
                        break
        except OSError:
            return self.send(404, b"no such folder\n", "text/plain")
        out.sort(key=lambda e: (not e["dir"], e["name"].lower()))
        self.send(200, json.dumps(out).encode(), "application/json")

    def image(self):
        """An image an agent names by its path, full or from its own folder, for the page to show: only from the page
        itself (the Host check keeps other sites out), only an image file, and only from under the home directory or a scratchpad (shown_file)."""
        if not self.here():
            return self.send(403, b"only the team page\n", "text/plain")
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        if "k" in query:
            with _lock:
                hit = _images.get(query["k"][0])
            return self.send(200, hit[1], hit[0], "private, max-age=3600") if hit else self.send(404, b"no such image\n", "text/plain")
        want = os.path.expanduser(query.get("p", [""])[0])
        if not want.startswith("/"):   # a relative path is from the folder the agent named in "a" works in
            want = os.path.join((live_sessions().get(query.get("a", [""])[0]) or {}).get("cwd") or "/nowhere", want)
        real = os.path.realpath(want)
        kind = IMAGE_TYPES.get(os.path.splitext(real)[1].lower())
        if not kind or not shown_file(real) or not os.path.isfile(real) or os.path.getsize(real) > 25_000_000:
            return self.send(404, b"no such image\n", "text/plain")
        with open(real, "rb") as f:
            self.send(200, f.read(), kind, "private, max-age=300")

    def do_POST(self):
        m = re.fullmatch(r"/api/agent/([A-Za-z][A-Za-z0-9_-]*)/(say|answer|stop|start|halt|compact)", self.path)
        team = re.fullmatch(r"/api/team/(start|stop)", self.path)
        nudger = re.fullmatch(r"/api/nudger/(pause|resume)", self.path)
        meet = re.fullmatch(r"/api/meeting(?:/(\d{8}-\d{4}-[a-z0-9]{4})/(say|add|pause|end|handover))?", self.path)
        if not m and not team and not nudger and not meet and self.path not in ("/api/paste", "/api/doc"):
            return self.send(404, b"not found\n", "text/plain")
        origins = {f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"} | ({f"https://{PUBLIC_HOST}"} if PUBLIC_HOST else set())
        origin = self.headers.get("Origin")
        if not self.here() or self.headers.get("X-Team-Say") != "1" or (origin and origin not in origins):
            return self.send(403, b"only the team page can send\n", "text/plain")
        if team:
            return self.team(team.group(1))
        if meet:
            return self.meeting(meet.group(1), meet.group(2))
        if nudger:
            return self.nudger(nudger.group(1) == "pause")
        if self.path == "/api/doc":
            return self.save_doc()
        if not m:
            return self.paste()
        if m.group(2) == "stop":
            return self.stop(m.group(1))
        if m.group(2) == "compact":
            return self.compact(m.group(1))
        if m.group(2) in ("start", "halt"):
            return self.standing(m.group(1), m.group(2))
        if m.group(2) == "answer":
            return self.answer(m.group(1))
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > SAY_MAX_BYTES:
                while n > 0 and self.rfile.read(min(n, 1 << 20)):
                    n -= 1 << 20
                return self.send(413, b"too long to send: over %d MB\n" % (SAY_MAX_BYTES >> 20), "text/plain")
            body = json.loads(self.rfile.read(n) or b"{}")
            text, images = str(body.get("text", "")), [str(i) for i in body.get("images") or []][:8]
        except (ValueError, json.JSONDecodeError, AttributeError, TypeError):
            return self.send(400, b"bad request\n", "text/plain")
        text = re.sub(r"[\x00-\x09\x0b-\x1f\x7f]+", " ", text.replace("\r\n", "\n")).strip()
        if any(os.path.dirname(os.path.realpath(i)) != PASTED or not os.path.isfile(i) for i in images):
            return self.send(400, b"an image is not one pasted here\n", "text/plain")
        if not text and not images:
            return self.send(400, b"nothing to send\n", "text/plain")
        where = panes().get(m.group(1))
        # a prompt ignores a paste, so the Enter after it would only choose whichever option is highlighted
        if where and open_ask(m.group(1), where["pane"]):
            return self.send(409, b"a prompt is open in its pane: answer it with its buttons\n", "text/plain")
        ok = type_into(m.group(1), text, images)
        if ok is None:
            return self.send(404, b"that agent is not in a pane\n", "text/plain")
        self.send(200 if ok else 500, json.dumps({"sent": ok}).encode(), "application/json")

    def meeting(self, mid, what):
        """A meeting started ({"who": [...], "topic", "view"}), or one of an open meeting's: a line said ({"text"}, and
        "as" and "handover" from meeting-say), someone brought in ({"name"}), Pause ({"on"}), End, or the owner's word
        on a suggestion ({"name", "action": "send" or "skip", "text"})."""
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(min(n, SAY_MAX_BYTES)) or b"{}")
            assert isinstance(body, dict)
        except (ValueError, AssertionError):
            return self.send(400, b"bad request\n", "text/plain")
        names = {r["name"] for r in roster()}
        if not mid:
            who = [str(x) for x in body.get("who") or [] if str(x) in names]
            if not who:
                return self.send(400, b"nobody to meet\n", "text/plain")
            if folder_trusted(MEETING_DIR) is False:   # every meeting session would sit at the prompt, seen by nobody
                return self.send(409, (f"Claude Code has not trusted {MEETING_DIR}, where meeting sessions start, so each would wait at its "
                                       f"trust prompt. Trust it once: run claude in {MEETING_DIR} and choose \"Yes, I trust this folder\".\n").encode(),
                                 "text/plain")
            m = start_meeting(list(dict.fromkeys(who)), str(body.get("topic") or "").strip()[:80], str(body.get("view") or "")[:40])
            return self.send(200, json.dumps({"id": m["id"]}).encode(), "application/json")
        with _meet_lock:
            m = _meetings.get(mid)
        if not m or m.get("ended"):
            return self.send(404, b"no such meeting open\n", "text/plain")
        text = re.sub(r"[\x00-\x09\x0b-\x1f\x7f]+", " ", str(body.get("text") or "").replace("\r\n", "\n")).strip()
        ok = False
        if what == "say":
            who = body.get("as")
            if (not text and not body.get("handover")) or (who is not None and who not in names) or (m["ending"] and not body.get("handover")):
                return self.send(400, b"nothing to say, or not now\n", "text/plain")
            ok = meeting_said(m, who, text, bool(body.get("handover")))
        elif what == "add" and body.get("name") in names and not m["ending"]:
            with _meet_lock:
                meeting_join(m, body["name"], added=True)
                save_meeting(m)
            ok = True
        elif what == "pause":
            with _meet_lock:
                m["paused"] = bool(body.get("on"))
                meeting_add_line(m, "", "paused" if m["paused"] else "resumed", "event")
            ok = True
        elif what == "end" and not m["ending"]:
            meeting_end(m)
            ok = True
        elif what == "handover":
            ok = meeting_handover(m, str(body.get("name")), body.get("action"), text)
        self.send(200 if ok else 409, json.dumps({"ok": ok}).encode(), "application/json")

    def answer(self, name):
        """Answers the prompt open in the agent's pane with one of its options, {"n": 3, "label": "Type something.",
        "text": "..."}: the text is a typed option's answer, put on one line; any other option takes none."""
        try:
            body = json.loads(self.rfile.read(min(int(self.headers.get("Content-Length") or 0), SAY_MAX_BYTES)) or b"{}")
            n, label, text = int(body["n"]), str(body["label"]), " ".join(str(body.get("text", "")).split())
        except (ValueError, KeyError, json.JSONDecodeError, AttributeError, TypeError):
            return self.send(400, b"bad request\n", "text/plain")
        status, said = answer(name, n, label, text)
        self.send(status, json.dumps({"answered": said}).encode() if status == 200 else (said + "\n").encode(),
                  "application/json" if status == 200 else "text/plain")

    def stop(self, name):
        """Stops the agent's turn as Esc does in its terminal: only while it is working, so a question it is waiting
        on is never cancelled by it."""
        if (live_sessions().get(name) or {}).get("status") != "busy":
            return self.send(409, b"that agent is not working\n", "text/plain")
        where = panes().get(name)
        if not where:
            return self.send(404, b"that agent is not in a pane\n", "text/plain")
        ok = subprocess.run(["tmux", "send-keys", "-t", where["pane"], "Escape"]).returncode == 0
        with _lock:
            _state["at"] = 0
        self.send(200 if ok else 500, json.dumps({"stopped": ok}).encode(), "application/json")

    def team(self, what):
        """Starts the team (team/team-start.sh for those in TEAM_UP, else the whole team, then the lead is told to start
        the day once it is up), or asks the lead to wind it down, as the owner asks before a shutdown: the lead stops
        everyone and marks the team paused, and who was running is kept in TEAM_UP for the next start."""
        # the stop asks whoever leads now; the start brings the delivery lead up and tells them to start the day
        lead = lead_name() if what == "stop" else next((r["name"] for r in roster() if role_of(r["role"])[0] == "lead"), None)
        if not lead:
            return self.send(409, b"no lead on the roster\n", "text/plain")
        if what == "stop":
            running = [r["name"] for r in team_roster() if r["name"] in live_sessions()]
            ok = type_into(lead, TEAM_STOP)
            if ok is None:
                return self.send(409, f"{lead} is not running\n".encode(), "text/plain")
            if ok:
                os.makedirs(STATE_DIR, exist_ok=True)
                with open(TEAM_UP, "w") as f:
                    f.write("".join(n + "\n" for n in running))
                compact_later(running)
                _halting.add("team"); _team_stop["at"] = time.time()
            return self.send(200 if ok else 500, json.dumps({"asked": lead}).encode(), "application/json")
        if not os.path.isfile(TEAM_START_SH):
            return self.send(500, f"{TEAM_START_SH} is not there\n".encode(), "text/plain")
        names = team_up()
        _halting.discard("team")
        _starting.update(["team", *(names or [r["name"] for r in team_roster()])])
        threading.Thread(target=start_team, args=(lead, names), daemon=True).start()
        self.send(202, json.dumps({"starting": "team"}).encode(), "application/json")

    def nudger(self, pause):
        """Pauses the waiting-agents nudger (its pause file) or resumes it."""
        if pause:
            open(NUDGER_PAUSED, "a").close()
        else:
            try:
                os.remove(NUDGER_PAUSED)
            except FileNotFoundError:
                pass
        with _lock:
            _state["at"] = 0
        self.send(200, json.dumps({"nudgerPaused": pause}).encode(), "application/json")

    def compact(self, name):
        """Compacts a running agent's conversation once it is not working: /compact typed into its pane."""
        if not any(r["name"] == name for r in roster()) or name not in live_sessions():
            return self.send(409, b"that agent is not running\n", "text/plain")
        if name in _compacting:
            return self.send(409, b"already compacting\n", "text/plain")
        _compacting.add(name)
        threading.Thread(target=compact_soon, args=(name,), daemon=True).start()
        self.send(202, json.dumps({"compacting": name}).encode(), "application/json")

    def standing(self, name, what):
        """Starts one standing agent (team/team-start.sh --only), or asks it to finish and stop, closing its pane once it
        has. Developers and testers are not started or stopped here. Either lead is stopped like any other (owner,
        2026-10-31: "I should be able to stop Vera and Carl")."""
        r = next((r for r in roster() if r["name"] == name), None)
        if not r or role_of(r["role"])[0] not in STANDING:
            return self.send(409, b"only a standing agent on the roster\n", "text/plain")
        if what == "start":
            if name in live_sessions():
                return self.send(409, b"that agent is running\n", "text/plain")
            if not os.path.isfile(TEAM_START_SH):
                return self.send(500, f"{TEAM_START_SH} is not there\n".encode(), "text/plain")
            keep_stopped(name, False)
            _starting.add(name)
            threading.Thread(target=start_one, args=(name,), daemon=True).start()
            return self.send(202, json.dumps({"starting": name}).encode(), "application/json")
        if name in _halting:
            return self.send(409, b"already stopping\n", "text/plain")
        ok = type_into(name, AGENT_STOP)
        if ok is None:
            return self.send(409, b"that agent is not running\n", "text/plain")
        keep_stopped(name, True)
        _halting.add(name)
        compact_later([name])
        threading.Thread(target=halt_when_idle, args=(name,), daemon=True).start()
        self.send(202, json.dumps({"stopping": name}).encode(), "application/json")

    def save_doc(self):
        """A File pane's edit saved ({"p", "text", "version"}): only a document /doc shows (a Markdown, text, SQL or
        log file under the home directory, already there, and UTF-8 text), and only while it is still the version
        the edit started from, the sha256 /doc sent as X-Doc-Version; a document changed since is a 409, never
        overwritten. The new text replaces the file in one step, keeping its permissions and its line endings."""
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if n > 3_000_000:
                return self.send(413, b"too long to save\n", "text/plain")
            body = json.loads(self.rfile.read(n) or b"{}")
            want, text, version = str(body["p"]), str(body["text"]), str(body["version"])
        except (ValueError, KeyError, AttributeError, TypeError):
            return self.send(400, b"bad request\n", "text/plain")
        real = os.path.realpath(os.path.expanduser(want))
        if (os.path.splitext(real)[1].lower() not in DOC_TYPES or not real.startswith(HOME + os.sep)
                or not os.path.isfile(real) or os.path.getsize(real) > 2_000_000):
            return self.send(404, b"no such document\n", "text/plain")
        with open(real, "rb") as f:
            old = f.read()
        if hashlib.sha256(old).hexdigest() != version:
            return self.send(409, b"it has changed since you opened it\n", "text/plain")
        try:
            old.decode("utf-8")
        except UnicodeDecodeError:
            return self.send(415, b"not UTF-8 text, so it cannot be edited here\n", "text/plain")
        text = text.replace("\r\n", "\n")
        data = (text.replace("\n", "\r\n") if b"\r\n" in old else text).encode("utf-8")
        if len(data) > 2_000_000:
            return self.send(413, b"too long to save\n", "text/plain")
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(real), prefix="." + os.path.basename(real) + ".", suffix=".tmp")
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, os.stat(real).st_mode & 0o7777)
            os.replace(tmp, real)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return self.send(500, b"could not save it\n", "text/plain")
        self.send(200, json.dumps({"version": hashlib.sha256(data).hexdigest()}).encode(), "application/json")

    def paste(self):
        """Keeps an image pasted into the page, or any file picked, as a file in PASTED, for a message to attach;
        returns its path. A picked file keeps its own name after the stamp, so the agent can tell what it is."""
        ext = {v: k for k, v in IMAGE_TYPES.items()}.get((self.headers.get("Content-Type") or "").split(";")[0].strip())
        own = re.sub(r"[^A-Za-z0-9._-]+", "-", os.path.basename(urllib.parse.unquote(self.headers.get("X-File-Name") or ""))).strip(".-")[-80:]
        if ext and os.path.splitext(own)[1].lower() not in IMAGE_TYPES:
            own = (own + ext) if own else ""
        n = int(self.headers.get("Content-Length") or 0)
        if not (ext or own) or not 0 < n <= 100_000_000:
            return self.send(400, b"only a named file or an image, of up to 100 MB\n", "text/plain")
        os.makedirs(PASTED, exist_ok=True)
        path = os.path.join(PASTED, time.strftime("%Y-%m-%d_%H-%M-%S_") + uuid.uuid4().hex[:6] + ("_" + own if own else ext))
        with open(path, "wb") as f:
            while n > 0:
                chunk = self.rfile.read(min(n, 1 << 20))
                if not chunk:
                    break
                f.write(chunk); n -= len(chunk)
        image = os.path.splitext(path)[1].lower() in IMAGE_TYPES
        self.send(200, json.dumps({"path": path, "url": "/img?p=" + urllib.parse.quote(path), "name": own or os.path.basename(path),
                                   "image": image}).encode(), "application/json")

    def log_message(self, *args):
        pass


PAGE = r"""<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<!-- interactive-widget: the on-screen keyboard shrinks the page, not just the view, so the footer sits on the keyboard
     with no gap below it (owner, 2026-11-01) -->
<meta name="viewport" content="width=device-width, initial-scale=1, interactive-widget=resizes-content">
<title>Team</title>
<!-- The phone layout from the first paint: the same test as phoneOn(), made before the body draws, so a phone never
     shows the empty desktop page while the first state loads (owner, 2026-11-09). -->
<script>try { if (matchMedia("(max-width:700px)").matches && !new URLSearchParams(location.search).has("only") && localStorage.getItem("phone") !== "off") document.documentElement.classList.add("phone"); } catch (e) {}</script>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Oswald:wght@700&display=swap">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 200 200'%3E%3Crect width='200' height='200' rx='40' fill='%2312161C'/%3E%3Ccircle cx='52' cy='52' r='28' fill='%235EEAD4'/%3E%3Ccircle cx='148' cy='52' r='28' fill='%235EEAD4'/%3E%3Ccircle cx='52' cy='148' r='28' fill='%235EEAD4'/%3E%3Ccircle cx='148' cy='148' r='28' fill='%235EEAD4'/%3E%3Ccircle cx='100' cy='100' r='40' fill='%23F4F4F0'/%3E%3C/svg%3E">
<style>
:root{
  --track:#ffffff10; --soft:#ffffff06; --section:#0b0f15aa; --card1:#161b22f0; --card2:#0d1117f0; --hover:#ffffff40; --text2:#c9d1d9;
  --codebg:#ffffff12; --box:#0d1117; --glow1:#1f6feb22; --glow2:#a371f71c; --thumb:#ffffff1c; --ownerbg:#f0f6fc; --ownerfg:#000;
  --bg:#07090d; --panel:#0d1117cc; --line:#ffffff14; --line2:#ffffff22; --on:#ffffff38; --text:#e6edf3; --mute:#8b949e; --faint:#545d68;
  --green:#3fb950; --amber:#e3b341; --red:#f85149; --cyan:#39c5cf;
  --chpanel:#0c0e13; --chtile:#171b24; --chmute:#9aa3b2; --chhigh:#e3b341;
  --sans:"Segoe UI Variable Text","Segoe UI",Inter,system-ui,sans-serif; --mono:"Cascadia Code","JetBrains Mono",Consolas,ui-monospace,monospace;
  /* the page's one scale for type, corner radius and control height: every size, weight and corner below is one of these
     (two weights, 400 and 650), so like things come out alike */
  --t-xs:10px; --t-s:11px; --t-m:12px; --t-l:13px; --t-xl:17px; --t-xxl:20px;
  --r-xs:2px; --r-s:5px; --r-m:9px; --r-l:14px; --ctl:24px;
}
:root.light{
  --bg:#f3f5f8; --panel:#ffffffcc; --line:#0000000f; --line2:#0000001c; --on:#0000001c; --text:#1f2328; --mute:#59636e; --faint:#8c959f;
  --green:#1a7f37; --amber:#d29a00; --red:#cf222e; --cyan:#0969da;
  --track:#0000000f; --soft:#ffffff; --section:#ffffffb0; --card1:#ffffff; --card2:#fbfcfd; --hover:#00000033; --text2:#31373e;
  --codebg:#0000000c; --box:#ffffff; --glow1:#54aeff26; --glow2:#c297ff1f; --thumb:#00000024; --ownerbg:#1f2328; --ownerfg:#fff;
  --chpanel:#f6f7f9; --chtile:#ffffff; --chmute:#5b6472; --chhigh:#8a6100;
}
:root.light .card{box-shadow:0 1px 2px #0000000d,0 4px 14px -6px #0000001a}
:root.light .card.busy{box-shadow:0 0 0 1px #1a7f3733,0 6px 20px -8px #1a7f3755}
:root.light .meter u{box-shadow:none}
*{box-sizing:border-box;margin:0}
html,body{height:100%;overflow:hidden}
body{font:calc(var(--t-l)*var(--fs,1))/1.45 var(--sans);color:var(--text);background:var(--bg);display:flex;flex-direction:column;
  background-image:radial-gradient(1200px 600px at 10% -10%,var(--glow1),transparent 60%),radial-gradient(900px 500px at 110% 110%,var(--glow2),transparent 60%)}
header,footer{display:flex;align-items:center;gap:22px;padding:12px 18px;flex:none}
header{border-bottom:1px solid var(--line)}footer{border-top:1px solid var(--line)}
footer{padding:3px 14px;gap:18px;min-height:0}   /* the footer is a status bar: as low as its tallest item */
/* the bar's items, in the header or the footer; while the layout is unlocked each is outlined, dragged and taken out with its ✕ */
.bi{position:relative;display:flex;align-items:center;flex:none;min-width:0}
.bi[data-item=bench]{flex:1 1 auto}   /* its chips' whole width first, then a share of what is left; it shrinks, and overlaps, only past that (owner, 2026-11-02) */
/* a spacer takes the room left, so what comes after it keeps to the right; it shows only while the layout is unlocked */
.bi.gap{flex:1;min-width:0}
.editing > .bi.gap{min-width:60px;height:18px;justify-content:center;color:var(--faint);font-size:calc(var(--t-s)*var(--fs,1))}
.editing > .bi.gap::before{content:"Spacer"}
.bi.div{flex:none;align-self:stretch;width:1px;margin:4px 0;background:var(--line2)}
.editing > .bi.div{width:15px;padding:0 6px;background:var(--faint);background-clip:content-box}   /* wider while unlocked, to grab: a 3px line, the padding either side is grip */
.bi.tight + .bi.tight{margin-left:-14px}
.bi:not(.tight) + .bi.tight{margin-left:auto}   /* the buttons keep to the right, as the bench's room pushed them */
.bi > .bx{display:none}
:not(.editing) > .bi:is([data-item=cpubar],[data-item=membar],[data-item=netbar],[data-item=gpubar],[data-item=heatbar],[data-item=fanbar]){cursor:pointer}
.bi:has(> :first-child:is([style*="display: none"],[style*="display:none"])){display:none}   /* Session or Disk while it is not shown */
/* unlocked, a bar's items can be dragged and taken out; their outlines and ✕ show while the pointer is on that bar, and on
   both bars while an item is being dragged, so an unlocked page is not cluttered while its panes are worked on */
.editing > .bi{border-radius:var(--r-s);cursor:grab;touch-action:none}
:is(.editing:hover, .editing:focus-within, body:has(.bi.dragging) .editing) > .bi{outline:1px dashed var(--line2);outline-offset:3px}
.editing > .bi.tight + .bi.tight{margin-left:0}
.editing > .bi.dragging{opacity:.4}
:is(.editing:hover, .editing:focus-within, body:has(.bi.dragging) .editing) > .bi > .bx{display:flex;position:absolute;z-index:5;top:-10px;right:-10px;width:16px;height:16px;align-items:center;justify-content:center;border-radius:50%;
  background:var(--box);border:1px solid var(--line2);color:var(--mute);font:normal 10px/1 var(--sans);cursor:pointer}
.editing > .bi > .bx:hover{color:var(--red);border-color:var(--red)}
header.bare:not(.editing),footer.bare:not(.editing){display:none}   /* a bar with nothing showing takes no room */
html:not(.barsplaced) :is(header,footer){display:none}   /* nothing until the bars are where this browser keeps them, never the markup's order */
header.editing:not(:has(.bi))::before{content:"Header · drag items here";color:var(--faint);font-size:calc(var(--t-m)*var(--fs,1))}
footer.editing:not(:has(.bi))::before{content:"Footer · drag items here";color:var(--faint);font-size:calc(var(--t-m)*var(--fs,1))}
/* a bar the dragged item cannot go in: boxed and crossed through in red, saying where it can go */
:is(header,footer).refuse{position:relative;outline:2px solid var(--red);outline-offset:-2px}
:is(header,footer).refuse::after{content:attr(data-refuse);position:absolute;inset:0;z-index:5;display:flex;align-items:center;justify-content:center;
  background:linear-gradient(to top right,transparent calc(50% - 1px),color-mix(in srgb, var(--red) 55%, transparent) 50%,transparent calc(50% + 1px)),
    linear-gradient(to bottom right,transparent calc(50% - 1px),color-mix(in srgb, var(--red) 55%, transparent) 50%,transparent calc(50% + 1px)),
    color-mix(in srgb, var(--bg) 82%, transparent);
  color:var(--red);font-weight:650;font-size:calc(var(--t-m)*var(--fs,1));text-shadow:0 0 4px var(--bg),0 0 4px var(--bg);pointer-events:none}
.barplus{margin-left:auto;flex:none;display:flex;align-items:center;justify-content:center;width:28px;height:24px;padding:0;border:1px solid var(--line2);
  border-radius:var(--r-s);background:var(--soft);color:var(--mute);cursor:pointer}
.barplus svg{width:14px;height:14px}
.brand{display:flex;align-items:center;flex:none}
.brand .lt,html.light .brand .dk{display:none}html.light .brand .lt{display:block}   /* the logo drawn for the theme */
/* While an agent waits the logo flashes as the footer's badge does, and a click opens the agent waiting longest: the logo
   cannot be taken out of the bars, so the flag is on the screen even with the Agents item and every agent icon out. */
.brand.waiting{cursor:pointer;border-radius:10px;animation:brandflash 1s ease-in-out infinite}
@keyframes brandflash{0%,100%{background:transparent;box-shadow:none}50%{background:#ffc94d;box-shadow:0 0 0 3px #ffb020}}
.stat{display:flex;flex-direction:column;gap:4px;min-width:150px}
.stat .k{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:calc(var(--t-s)*var(--fs,1));letter-spacing:.12em;text-transform:uppercase;color:var(--mute)}
.stat .v{font:650 calc(var(--t-l)*var(--fs,1)) var(--mono)}
/* under its label a stat's meter or sparkline fills one 14px band, so Week and Team stand as tall as each other */
.pspark{width:190px;height:14px;color:var(--ownerbg)}.pspark svg.spark{height:14px}
.stat > .meter{margin:4px 0}
/* a slim plug-in is one low line: its label and value beside a shorter meter or sparkline */
.stat.slim{flex-direction:row;align-items:center;gap:7px;min-width:0}
.stat.slim .meter{width:110px;margin:0}
.stat.slim .pspark,.stat.slim .pspark svg.spark{width:110px;height:14px}
/* one with an icon in place of its label is tighter still: the icon, the value and a short meter or sparkline */
.stat.slim.ico{gap:4px}
.stat.slim.ico .k{letter-spacing:0;text-transform:none;color:var(--text);display:flex;align-items:center;gap:4px}
.stat.slim.ico .lab svg{width:14px;height:14px;color:var(--mute);display:block}
.stat.slim.ico .meter,.stat.slim.ico .pspark,.stat.slim.ico .pspark svg.spark{width:48px}
.meter{position:relative;height:6px;border-radius:var(--r-s);background:var(--track);overflow:visible;width:190px}
.meter i{position:absolute;inset:0 auto 0 0;border-radius:var(--r-s);transition:width .6s}
.meter u{position:absolute;top:-3px;bottom:-3px;width:2px;background:var(--text);border-radius:var(--r-xs);box-shadow:0 0 6px #fff8}
.counts{flex:none;display:flex;gap:8px}
.pill{display:flex;align-items:center;gap:6px;padding:5px 10px;border:1px solid var(--line2);border-radius:999px;font:650 calc(var(--t-m)*var(--fs,1)) var(--mono);background:var(--soft);color:var(--text)}
.pill.btn{cursor:pointer;color:var(--mute);font-family:var(--sans)}
.pill.btn:hover{color:var(--text);border-color:var(--hover)}
.pill.tally{position:relative;gap:5px}
.pill.tally b:first-of-type{margin-right:5px}
.pill.tally .dot.on{--reach:7px;animation:ping 1.4s infinite}
.pill.tally .wait{cursor:pointer;position:absolute;inset:-1px;display:flex;align-items:center;justify-content:center;border-radius:999px;border:2px solid #ffb020;color:#000;font:650 calc(var(--t-m)*var(--fs,1)) var(--sans);white-space:nowrap;animation:pillflash 1s ease-in-out infinite}
.bench{flex:1;min-width:0;display:grid;grid-template-columns:auto minmax(0,1fr);gap:4px 6px;align-items:center;color:var(--faint);font-size:calc(var(--t-s)*var(--fs,1))}
.bench .rrow{display:flex;gap:5px;min-width:0;overflow:hidden;padding:1px}   /* one row, overlapped to fit: fitBench; room for a stacked card's rim */
.bench .rrow > *{position:relative}
.bench .rrow.stack > [data-name]{box-shadow:0 0 0 1px var(--bg)}   /* a fine rim in the page's background colour parts each card of the stack */
.bench em.more{cursor:pointer}
.bench.favs{flex:none}   /* only as wide as its favourites, leaving the bench the room */
.favs > span:first-child{display:inline-flex;color:var(--text)}   /* the star in the text colour, as every other icon in the bar */
.favs > span:first-child svg{width:calc(14px*var(--fs,1));height:calc(14px*var(--fs,1))}
.favs .rrow [data-fav]{cursor:pointer}
.favs .rrow em.off{opacity:.55}
.favs .none{color:var(--faint)}
/* every row open, over the page rather than pushing it down, from where the folded rows sat */
.bench{position:relative}
.bench .rrow.all{position:absolute;z-index:30;flex-wrap:wrap;padding:6px;margin:-7px 0 0 -7px;border:1px solid var(--line2);border-radius:var(--r-m);background:var(--box);box-shadow:0 10px 28px #0008}
.bench em.more:hover{color:var(--text)}
.bench em{flex:none;font-style:normal;padding:1px 7px;border-radius:var(--r-s);border:2px solid var(--c);color:var(--mute)}
.face{position:relative;flex:none;width:34px;height:34px;overflow:hidden;border-radius:var(--r-s);background:var(--chtile)}   /* a Characters tile, smaller */
.face::after{content:"";position:absolute;inset:auto 0 0;height:3px;background:var(--c)}   /* its role colour laid over the portrait's foot, so the portrait stays square */
.face img,.face svg{display:block;width:100%;height:100%;object-fit:cover}
.face .ini{position:absolute;left:2px;bottom:2px;min-width:9px;padding:0 2px;border-radius:3px;border:1px solid var(--c);
  font:700 9px/10px var(--sans);text-align:center;color:var(--text);background:color-mix(in srgb,var(--c) 30%,var(--chtile))}   /* a shadow's initial, bottom left on every role */
.face.waiting,.face.wanted{animation:alarm 1s ease-in-out infinite}   /* as a Characters tile */
.face.benched > :is(img,svg){filter:grayscale(1);opacity:.55}   /* on the bench the portrait is greyed and its role colour kept (owner, 2026-11-11); not .bench, the bench bar's own grid */
.bench > span:first-child{display:flex;align-items:center;gap:2px}
.bench > span:first-child:empty{display:none}   /* no "bench" word (owner, 2026-11-02): only its filter button, while unlocked */
.bench:has(> span:first-child:empty){grid-template-columns:minmax(0,1fr)}
main{position:relative;flex:1;min-height:0;display:grid;grid-template-rows:minmax(0,1fr);gap:14px;padding:14px}
.colgrip{position:absolute;top:14px;bottom:14px;width:14px;cursor:col-resize;z-index:3}
.colgrip::after{content:"";position:absolute;inset:0 5px;border-radius:var(--r-xs);background:transparent;transition:background .15s}
.colgrip:hover::after,.colgrip.drag::after{background:var(--line2)}
body.resizing{cursor:col-resize;user-select:none}
/* Custom: the page split into panes, each an agent's card, every agent as a list, or a grid or tabs of roles */
.lay{min-width:0;min-height:0;display:flex}
.lay.col{flex-direction:column}
.lay > .half{min-width:0;min-height:0;flex:1 1 0;display:flex}
.lay > .half > *{flex:1}
.divider{flex:none;width:14px;position:relative}
.lay.col > .divider{width:auto;height:14px}
.divider.drag{cursor:col-resize}
.lay.col > .divider.drag{cursor:row-resize}
.divider.drag::after{content:"";position:absolute;inset:0 5px;border-radius:var(--r-xs);transition:background .15s}
.lay.col > .divider.drag::after{inset:5px 0}
.divider.drag:hover::after,.divider.moving::after{background:var(--line2)}
body.resizing-row{cursor:row-resize;user-select:none}
.snapguide{position:fixed;z-index:60;pointer-events:none;display:none;border:0 dashed var(--mute)}
.snapguide.on{display:block}
.pane{min-width:0;min-height:0;display:flex;flex-direction:column;border:1px solid var(--line);border-radius:var(--r-l);background:var(--section);backdrop-filter:blur(8px)}
.pbar{flex:none;display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;padding:7px 10px;border-bottom:1px solid var(--line);font-size:calc(var(--t-s)*var(--fs,1));color:var(--mute)}
.pbar select{font:calc(var(--t-m)*var(--fs,1)) var(--sans);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:var(--r-s);padding:1px 4px}
/* the browser draws a select's open list and an input's own parts in the page's theme, not its default light one */
.pbar :is(select, input){color-scheme:dark}
html.light .pbar :is(select, input){color-scheme:light}
.pbar option{background:var(--box);color:var(--text)}
.pbar input{flex:1 1 240px;min-width:0;font:calc(var(--t-m)*var(--fs,1)) var(--mono);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:var(--r-s);padding:2px 6px}
.pbar input::placeholder{color:var(--faint)}
/* a File pane: one document, as the document viewer shows it */
.fdoc{flex:1;min-height:0;overflow:auto;padding:12px 16px;color:var(--text);font-size:calc(var(--t-l)*var(--fs,1));line-height:1.5;white-space:pre-wrap;word-break:break-word}
.pbar .pacts{display:flex;gap:2px;margin-left:auto}
.pbar .pacts b{padding:1px 6px;border-radius:var(--r-s);font-size:calc(var(--t-l)*var(--fs,1));font-weight:400;cursor:pointer}
.pbar .pacts b:hover{background:var(--on);color:var(--text)}
/* a pane's grip drags it onto another pane, and the two swap places */
.pbar b.pmove{margin-left:-4px;padding:1px 4px;border-radius:var(--r-s);font-size:calc(var(--t-l)*var(--fs,1));font-weight:400;cursor:grab;touch-action:none}
.pbar b.pmove:hover{background:var(--on);color:var(--text)}
body.moving-pane,body.moving-pane *{cursor:grabbing !important;user-select:none}
.pane.lifted{opacity:.55}
.pane.drop{outline:2px dashed var(--cyan);outline-offset:-2px}
.pbody{flex:1;min-height:0;display:flex;flex-direction:column}
/* unlocked, a pane's tabs head its bar, and the showing tab's own settings are a row under them */
.pbar > .ctabs{display:flex;flex-wrap:wrap;align-items:center;gap:2px;min-width:0}
.pbar > .ctabs .ctab{padding:3px 6px 3px 8px;border-radius:var(--r-s);border:1px solid transparent}
.pbar > .ctabs .ctab.sel{background:var(--on);border-color:var(--line2)}
.ctabs .cti{display:flex;opacity:.8}
.ctabs .cti svg{width:13px;height:13px}
.ctabs .cv{display:flex;padding:1px;margin-left:-2px;border-radius:3px;opacity:.6}
.ctabs .cv:hover{opacity:1;background:var(--soft)}
.ctabs .cv svg{width:11px;height:11px}
.pbar .fbtn.cadd,.pbar .fbtn.pmore{padding:2px 4px}
.pbar .fbtn.pmore{margin-left:auto}
.pbar .pown{flex:1 1 100%;min-width:0;display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;margin:1px -10px -1px;padding:6px 10px 0;border-top:1px solid var(--line)}
.pown .seg{margin-left:auto}
.pown .chips{flex:1 1 0;min-width:0;display:flex;gap:4px;overflow:hidden}
.chip{flex:none;display:inline-flex;align-items:center;gap:5px;padding:1px 8px;border:1px solid var(--line2);border-radius:999px;font-weight:400;
  font-size:calc(var(--t-s)*var(--fs,1));color:var(--mute);cursor:pointer;white-space:nowrap;user-select:none}
.chip:hover{color:var(--text)}
.chip.on{background:var(--on);color:var(--text);border-color:var(--mute)}
.chip[hidden]{display:none}
.chip .cdot{width:7px;height:7px;border-radius:50%}
.chip svg{width:12px;height:12px}
.teamlog .thead > span.tsum{font-weight:400;color:var(--mute)}
.workq .wqwho{display:contents;cursor:pointer}
.workq .wqwho .who{cursor:pointer}
.workq .who.unset{opacity:.45;font-weight:400}
.frecent{display:flex;flex-direction:column;gap:2px;min-width:min(420px,80%);text-align:left}
.frecent > div{margin-bottom:4px;color:var(--faint)}
.frecent a{display:flex;flex-direction:column;padding:5px 9px;border-radius:var(--r-s);color:var(--text);cursor:pointer}
.frecent a:hover{background:var(--soft)}
.frecent a span{font:calc(var(--t-s)*var(--fs,1)) var(--mono);color:var(--mute);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pown .kchips{display:flex;flex-wrap:wrap;gap:4px}
.pbar .pown input.tfilter{flex:0 0 110px;font-family:var(--sans)}
.blank .pchoose{display:inline-flex;align-items:center;gap:6px;padding:5px 12px;font:inherit;color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:var(--r-s);cursor:pointer}
.blank .pchoose svg{width:12px;height:12px}
/* the view picker: the views in groups, each with its icon and a line on what it shows */
#menu .mg{padding:7px 8px 3px;font-size:calc(var(--t-s)*var(--fs,1));color:var(--faint);text-transform:uppercase;letter-spacing:.06em}
#menu .mg:not(:first-child){margin-top:3px;border-top:1px solid var(--line)}
#menu .pvi{padding:4px 8px}
#menu .pvico{display:flex}
#menu .pvt{display:flex;flex-direction:column;flex:1;line-height:1.25}
#menu .pvt b{font-weight:600}
#menu .pvt small{color:var(--mute);font-size:calc(var(--t-s)*var(--fs,1))}
/* an agent picked in a Combined pane, a little inside it, over the Combined view greyed out behind */
.pbody:has(> .paneover){position:relative}
.paneover{position:absolute;inset:0;z-index:6;display:flex;flex-direction:column;padding:18px;border-radius:0 0 var(--r-l) var(--r-l);
  background:color-mix(in srgb,var(--bg) 55%,transparent);backdrop-filter:grayscale(1) blur(1.5px)}
.paneover > .cards{flex:1;min-height:0;padding:0;cursor:default}
.teamlog .cnames .focal{position:relative;z-index:7}   /* the agent over its Combined view: above the greying */
.paneover > .cards > .card{box-shadow:0 12px 36px #0009;background-color:var(--box)}   /* solid: the Combined view does not show through */
.pbody .blank{margin:auto;color:var(--faint);font-size:calc(var(--t-m)*var(--fs,1))}
.others{flex:1;min-height:0;overflow:auto;padding:10px;display:flex;flex-direction:column;gap:8px}
.daylog{flex:1;min-height:0;overflow:auto;padding:10px 14px;color:var(--text);font-size:calc(13px*var(--fs,1));line-height:1.45}
.daylog .row{display:flex;gap:12px;padding:3px 8px}
.daylog .wh{flex:none;width:calc(var(--whw,62px)*var(--fs,1));display:flex;align-items:center;height:1.45em}
.daylog .who{font-weight:650;font-size:calc(10.5px*var(--fs,1));line-height:1.4;padding:0 6px;border-radius:4px;letter-spacing:.02em;white-space:nowrap;background:var(--pc);color:var(--ownerfg)}
.daylog .who.off{background:none;color:var(--mute);box-shadow:inset 0 0 0 1px var(--line2)}
.daylog .tx{flex:1;min-width:0;overflow-wrap:anywhere}
.daylog .ico{position:relative;flex:none;margin-left:auto;display:flex;align-items:center;height:1.45em;color:var(--mute);cursor:pointer}
.daylog .ico:hover{color:var(--text)}
.daylog .desc{position:absolute;top:100%;right:0;z-index:5;width:max-content;max-width:min(320px,70vw);margin-top:4px;padding:6px 9px;border:1px solid var(--line2);border-radius:6px;background:var(--box);color:var(--text2);font-weight:400;cursor:default;box-shadow:0 4px 14px rgba(0,0,0,.3)}
.daylog .desc b{display:block;color:var(--text);font-weight:650}
.daylog .ico svg{width:calc(14px*var(--fs,1));height:calc(14px*var(--fs,1))}
.daylog .at{flex:none;width:9em;color:var(--mute);font-variant-numeric:tabular-nums}
.daylog:not(.workq) .row:not(.day) .at{width:3.2em}
.daylog:not(.workq) .row:not(.day) .ico{margin-left:0;color:var(--text)}
.daylog:not(.workq) .row:not(.day) .desc{right:auto;left:0}
.daylog .day{margin:8px 0 4px;padding:6px 8px;border-radius:6px;background:var(--track);font-weight:600}
.daylog .day:first-child{margin-top:0}
.daylog .day.development{box-shadow:inset 3px 0 var(--green)}
.daylog .day.verification{box-shadow:inset 3px 0 var(--amber)}
.daylog a{color:var(--cyan);text-decoration:none;flex:none}
.daylog a:hover{text-decoration:underline}
/* one line an item: its note after its title, and the two cut short together; hovering shows them whole */
.workq{padding:6px 10px}
.teamlog[data-name="~workqueue"]{background:var(--bg)}   /* the page's grey behind the title bar and the section boxes */
.workq .row{align-items:center;padding:1px 6px;gap:10px}
.workq .row > a,.workq .key{flex:none;width:var(--wqk,5.5em);max-width:40%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-variant-numeric:tabular-nums}
.workq .tx{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
/* under a Done ticket: in a few words what the fix did, so the stand-up can say it */
.workq .fix{padding:0 6px 3px calc(5.5em + 22px);color:var(--fg);opacity:.85;font-size:.92em}
.workq .note{margin-left:10px;color:var(--mute)}
.workq .day{margin:8px 0 2px;padding:0 6px;background:none;color:var(--mute);font-size:.82em;font-weight:650;letter-spacing:.06em;text-transform:uppercase}
.workq .sect{margin-top:8px;padding:4px 0;border:1px solid var(--line2);border-radius:var(--r-m);background:linear-gradient(180deg,var(--card1),var(--card2))}   /* shaded as the Tabs view's agent cards */
.workq .sect:first-child{margin-top:0}
.workq .sect .day{display:flex;align-items:center;margin:2px 0 4px;padding:0 6px}
.workq .sect.shut .day{margin-bottom:2px}
.workq .wqfold{display:grid;place-items:center;width:22px;height:20px;margin-left:auto;border-radius:var(--r-s);color:var(--mute);cursor:pointer}   /* as a card's fold button */
.workq .wqfold:hover{background:var(--on);color:var(--text)}
.workq .day .n{margin-left:6px;font-weight:400}
.workq .row.none{color:var(--mute)}
.workq .row > .wh{justify-content:flex-end}
.workq .row > .at{width:auto;min-width:3.2em;text-align:right}
#phone .workq .tx{white-space:normal;overflow:visible;overflow-wrap:anywhere}
#phone .workq .tx code{white-space:normal;overflow-wrap:anywhere}
.daylog .note{padding:4px 0 8px;color:var(--mute)}
.teamlog[data-name="~tokens"]{background:var(--bg)}   /* the page's grey behind the week boxes, as the Work queue's */
.tokens{overflow-x:auto;padding:0 6px 2px;font-size:calc(var(--t-s)*var(--fs,1))}
.tokens table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}
.tokens th{font-weight:500;color:var(--mute);padding:2px 8px;text-align:right;line-height:1.2;white-space:nowrap}
.tokens td{padding:3px 8px;text-align:right;white-space:nowrap;border-top:1px solid var(--line)}
.tokens td:first-child{text-align:left;padding-left:0}
.tokens .who{font-weight:650;padding:0 6px;border-radius:4px;background:var(--pc);color:var(--ownerfg);cursor:pointer}
.tokens .tot,.tokens tr.tot td{font-weight:650;color:var(--text)}
.tokens tr:hover td{background:var(--track)}
.tokens :is(th, td).today{border-left:1px solid var(--mute);border-right:1px solid var(--mute)}
.tokens th.today{border-top:1px solid var(--mute);color:var(--text)}
.tokens tr:last-child td.today{border-bottom:1px solid var(--mute)}
@media (max-width:600px){.daylog .row{flex-wrap:wrap;gap:0 10px}.daylog .at{width:auto}.daylog .tx{flex-basis:100%;order:1}}
@media (max-width:600px){.workq .row > :is(.wh,.at){margin-left:auto}.workq .row > .wh{width:auto}.workq .row > .wh + .at{margin-left:0}}
section.tab{min-height:0;display:flex;flex-direction:column;border:1px solid var(--line);border-radius:var(--r-l);background:var(--section);backdrop-filter:blur(8px)}
section.tab h2{min-height:41px;display:flex;justify-content:space-between;align-items:center;padding:9px 14px;font-size:calc(var(--t-s)*var(--fs,1));letter-spacing:.16em;text-transform:uppercase;color:var(--mute);font-weight:650;border-bottom:1px solid var(--line)}
.seg{display:flex;border:1px solid var(--line2);border-radius:var(--r-s);overflow:hidden;letter-spacing:0;text-transform:none}
.seg b{padding:2px 9px;font-weight:400;font-size:calc(var(--t-s)*var(--fs,1));cursor:pointer;color:var(--mute)}
.seg b.on{background:var(--on);color:var(--text)}
#pagemode,#pagelanes{display:flex}
#help,#settings{width:30px;padding:0;font:650 calc(var(--t-l)*var(--fs,1)) var(--sans)}
#settings{display:inline-flex;align-items:center;justify-content:center}
#settings svg{flex:none;width:calc(var(--t-xl)*var(--fs,1));height:calc(var(--t-xl)*var(--fs,1))}
#teamctl{display:flex}
#teamctl{gap:6px}
#teamctl .fbtn{gap:6px}
#teamctl .fbtn svg{flex:none;width:16px;height:16px;stroke-width:1.7}
/* the team's play, pause and stop: off an outline in the text colour, on filled in its colour, fading in and out
   while the page waits for the change it was asked for */
#pagelanes .fbtn,#pagemode .fbtn,#help,#settings{height:var(--ctl);padding:0 12px;border:1px solid var(--line2);border-radius:999px;background:var(--soft);font-size:calc(var(--t-m)*var(--fs,1))}
#teamctl .fbtn{height:var(--ctl);padding:0 9px;white-space:nowrap;border:1.5px solid var(--text);border-radius:999px;background:none;color:var(--text);font-size:calc(var(--t-m)*var(--fs,1))}
#teamctl .fbtn:hover{background:var(--on)}
#teamctl .fbtn:is(.lit,.going){background:var(--c);border-color:var(--c);color:var(--bg)}
#teamctl .fbtn.going{animation:switching 1.4s ease-in-out infinite}
#teamctl .fbtn.warn{color:var(--red);border-color:var(--red);padding:0 12px}
#teamctl .fbtn.idle{cursor:default}
#pagemode .fbtn{color:var(--text)}
#viewbar{display:flex;gap:4px}
#viewbar .vtb{width:26px;height:22px;border:1px solid transparent;border-radius:var(--r-s)}
#viewbar .vtb:hover{background:var(--on);color:var(--text)}
#viewbar .vtb.on{border-color:var(--line2);background:var(--soft);color:var(--text)}
#viewbar .vtb svg{width:15px;height:15px}
#viewbar .vtmenu{width:18px;height:22px;margin-left:-2px}
#lock{height:var(--ctl);color:var(--text)}
.tabbar{display:flex;flex-wrap:wrap;gap:6px;padding:10px 10px 0}
.tabbar button{--c:#888;display:flex;align-items:center;gap:6px;padding:4px 11px;border-radius:var(--r-s);border:1px solid var(--c);background:var(--c);min-height:28px;   /* min-height: as tall with an unseen count as without */
  color:#000;font:650 calc(var(--t-m)*var(--fs,1)) var(--sans);cursor:pointer}
.tabbar button:hover{filter:brightness(1.15)}
.tabbar button.waiting,.tabbar button.wanted{border:2px solid #ffb020;animation:alarm 1s ease-in-out infinite}
.cards{flex:1;min-height:0;display:grid;gap:10px;padding:10px;grid-auto-rows:minmax(0,1fr)}
.card{--c:#888;position:relative;min-height:0;display:flex;flex-direction:column;border-radius:var(--r-m);border:1px solid var(--line2);
  background:linear-gradient(180deg,var(--card1),var(--card2));overflow:hidden;cursor:pointer;transition:transform .15s,border-color .2s,box-shadow .2s}
.card:hover{transform:translateY(-1px);border-color:var(--hover)}
.card::before{content:"";position:absolute;inset:0 0 auto 0;height:3px;background:var(--c);opacity:.9}
.card.busy{box-shadow:0 0 0 1px #3fb95033,0 0 24px -8px #3fb95066}
/* a waiting agent is loud: the card's border and glow pulse amber, and its open question flashes inside its own border */
.card.waiting,.card.wanted{border:2px solid #ffb020;animation:alarm 1s ease-in-out infinite}
.card.idle:not(.full) .feed{opacity:.8}
.card.off{opacity:.45}
/* an agent the page is stopping fades in and out until its pane closes; one it is starting pulses from grey to its
   colour until it is up */
@keyframes switching{0%,100%{opacity:1}50%{opacity:.4}}
.switching{animation:switching 2.4s ease-in-out infinite}
.switching.waiting,.tabbar button.switching.waiting,.chr.switching.waiting,.face.switching.waiting,.switching.wanted,.tabbar button.switching.wanted,.chr.switching.wanted,.face.switching.wanted{animation:alarm 1s ease-in-out infinite,switching 2.4s ease-in-out infinite}
.icontabs .face.switching.busy:not(.sel),.iconrow .face.switching.busy{animation:breathe 2.4s ease-in-out infinite,switching 2.4s ease-in-out infinite}
@keyframes waking{0%,100%{opacity:.45;filter:grayscale(1)}50%{opacity:1;filter:none}}
.waking{animation:waking 2.4s ease-in-out infinite}
@keyframes alarm{0%,100%{border-color:#b87400;box-shadow:0 0 0 0 #ffb02000,0 0 10px 0 #ffb02044}50%{border-color:#ffc94d;box-shadow:0 0 0 4px #ffb02088,0 0 46px 6px #ffb020cc}}
@keyframes wash{0%,100%{opacity:.06}50%{opacity:.3}}
@keyframes pillflash{0%,100%{background:#8a5a00}50%{background:#ffc94d}}
@keyframes ask{0%,100%{border-color:#c2410c;box-shadow:0 0 0 0 #ff7a1a00}50%{border-color:#ff9a3c;box-shadow:0 0 0 4px #ff7a1a99,0 0 22px 2px #ff7a1aaa}}
.top{display:flex;align-items:center;gap:8px;padding:10px 12px 6px}
/* a badge's text sits a pixel high of centre, as the font's descender space otherwise shows it low */
.name{white-space:nowrap;background:var(--c);color:#000;font-weight:650;padding:0 8px 2px;border-radius:var(--r-s);font-size:calc(var(--t-l)*var(--fs,1))}
/* Text on an agent's colour is the owner badge's: black in the dark theme, white in the light. */
.name,.tabbar button,#dbottom,.card .newest{color:var(--ownerfg)}
.role{color:var(--mute);font-size:calc(var(--t-m)*var(--fs,1));white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.ticket{white-space:nowrap;flex:none;margin-left:auto;font:650 calc(var(--t-m)*var(--fs,1)) var(--mono);color:var(--cyan);background:#39c5cf14;border:1px solid #39c5cf33;padding:1px 7px;border-radius:var(--r-s)}
.row2{display:flex;align-items:center;gap:10px;white-space:nowrap;min-width:0;padding:0 12px 8px;font:calc(var(--t-m)*var(--fs,1)) var(--mono);color:var(--mute)}
.state{display:flex;align-items:center;gap:6px;color:var(--text);font-family:var(--sans);font-weight:650}
.dot{width:8px;height:8px;border-radius:50%;background:var(--faint)}
.busy .dot{background:var(--green);animation:ping 1.4s infinite}
.waiting .dot,.wanted .dot{background:var(--amber)}
.waiting .state,.wanted .state,.state.wanted{color:var(--amber)}
.wantline{color:var(--amber);font-size:calc(var(--t-m)*var(--fs,1));margin:2px 0 4px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
/* compacting: a cyan dot pulsing cyan */
.compacting .dot{--pulse:var(--cyan);background:var(--cyan);animation:ping 1.4s infinite}
.compacting .state{color:var(--cyan)}
/* a pulse: a ring that grows out of the dot in its colour (--pulse, else green) and fades into the page's background as it
   spreads, to --reach (9px unless set) */
@keyframes ping{0%{box-shadow:0 0 0 0 var(--pulse,var(--green))}80%{box-shadow:0 0 0 var(--reach,9px) var(--bg)}100%{box-shadow:0 0 0 calc(var(--reach,9px) + 1px) color-mix(in srgb,var(--bg) 0%,transparent)}}
/* on an agent's coloured name box the ring is drawn in the name's own colour, which stands out against the box */
.tabbar button.busy .dot,.mini.busy .name .dot,.tabbar button.compacting .dot,.mini.compacting .name .dot{background:var(--faint);animation-name:pingfg}
/* an agent in its shell: on its name box, a dot in the name's colour pulsing the same */
.tabbar button.shell .dot,.mini.shell .name .dot{background:var(--ownerfg);animation:pingfg 1.4s infinite}
/* an agent that is not running: on its name box, a square in the name's colour */
.tabbar button.off .dot,.mini.off .name .dot{border-radius:var(--r-xs);background:var(--ownerfg)}
@keyframes pingfg{0%{box-shadow:0 0 0 0 var(--ownerfg)}80%{box-shadow:0 0 0 5px var(--c)}100%{box-shadow:0 0 0 6px color-mix(in srgb,var(--c) 0%,transparent)}}
.ctx{display:flex;align-items:center;gap:6px;margin-left:auto}
.ctx .meter{width:64px}
.model{color:var(--faint);overflow:hidden;text-overflow:ellipsis;min-width:0}
svg.spark{display:block;width:100%;height:26px;flex:none}
.feed{flex:1;min-height:0;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-end;gap:5px;padding:8px 12px 10px;border-top:1px solid var(--line);
  mask-image:linear-gradient(180deg,transparent,#000 28px)}
.it{display:flex;gap:7px;font-size:calc(var(--t-m)*var(--fs,1));line-height:1.4;min-width:0}
.it .who{flex:none;font-weight:650;font-size:calc(var(--t-s)*var(--fs,1));padding:1px 6px;border-radius:var(--r-s);height:fit-content;margin-top:1px;letter-spacing:.02em}
.it .tx{min-width:0;overflow:hidden;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:4;white-space:pre-line;color:var(--text2)}
.it.said .tx{color:var(--text)}
.it .tx > .heads{float:left;height:1lh;margin-right:7px;white-space:nowrap}   /* one line's height, so the next line runs beneath */
.it .tx > .heads .who{display:inline-block;vertical-align:top;line-height:1.1;margin-top:.5px}   /* inside the line it opens, so a one-line message never cuts it off */
.it .tx > .heads .who + .who{margin-left:4px}
.it.owner .who{background:var(--ownerbg);color:var(--ownerfg)}
.it.l-auto,.it.l-team{border-left:2px solid var(--lanec);padding-left:7px}
.it.l-owner{padding-left:9px}
.it.l-auto{--lanec:var(--ownerbg)}
.it.l-team{--lanec:var(--pc,var(--line2))}
.it.l-auto{opacity:.55}
.it.l-owner.owner .tx{color:var(--text);font-weight:650}
.it.folded .tx{font-style:italic;color:var(--mute);-webkit-line-clamp:1}
.it.folded .tx .n{font-style:normal;color:var(--faint)}
#detail .conv .it.folded{cursor:pointer}
.lanes{margin-left:auto;flex:none}
/* the maximise button docked in the head's top-right corner, so it stays there when a narrow head wraps */
.card > .top:has(> .maxbtn){padding-right:34px}   /* the maximise button, 10px in, and 2px before it */
.card > .top > .maxbtn{position:absolute;top:10px;right:10px}
.card > .top > .lanes{align-self:flex-start}
.card > .top > .foldbtn{flex:none;align-self:flex-start;display:grid;place-items:center;width:22px;height:20px;margin-left:auto;border-radius:var(--r-s);color:var(--mute);cursor:pointer}
.card > .top > .foldbtn:hover{background:var(--on);color:var(--text)}
.card > .top > .foldbtn + .lanes{margin-left:0}
.card.folded > .row2,.card.folded > svg.spark{display:none}   /* folded: the name line alone, on every screen */
.card .top{flex-wrap:wrap;row-gap:4px}
/* in a pane, a card's name, role and ticket keep to one line; its fold and lanes show over the head's end on a rest */
.pane .card .top{position:relative;flex-wrap:nowrap;min-width:0}
.pane .card .top .role{flex:0 20 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pane .card .top .name{flex:none}
.pane .card .top .ticket{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.pane .card .top > :last-child{flex:none;margin-left:auto}
.pane .card .top .cctl{display:none}
.pane .card:hover .top .cctl{position:absolute;right:34px;top:6px;z-index:3;display:flex;align-items:center;gap:6px;padding:2px 6px;border:1px solid var(--line2);border-radius:var(--r-s);background:var(--box);box-shadow:0 4px 14px rgba(0,0,0,.3)}
.card .top .cctl{display:contents}
.termseg b,.railseg b{padding:1px 5px;font-size:calc(var(--t-xs)*var(--fs,1))}
/* a filter button, flat like the maximise button; its sliders are in the text colour while something is left out */
.fbtn{flex:none;display:inline-flex;align-items:center;justify-content:center;gap:5px;min-width:22px;height:20px;border-radius:var(--r-s);color:var(--mute);cursor:pointer;font-weight:400}
.fbtn svg{width:13px;height:13px;stroke-width:1.5}
.fbtn:has(span){padding:0 6px}
.fbtn:hover{background:var(--on);color:var(--text)}
.fbtn.some{color:var(--text)}
.it.peer .who,.it.sent .who,.it.said .who{background:var(--pc,#444);color:var(--ownerfg)}
.it.sent .who::before{content:"→ "}
.it.event .tx{color:var(--mute);font-style:italic}
.it.event .who,.it.shell .who{color:var(--mute);border:1px solid var(--line2)}
.it.shell .tx{color:var(--mute)}
.it.ask{position:relative;z-index:1;flex-direction:column;gap:4px;padding:8px 10px;border:2px solid #ff7a1a;border-radius:var(--r-m);background:#ff7a1a1f;animation:ask 1s ease-in-out infinite}
.it.ask::after{content:"";position:absolute;inset:0;border-radius:var(--r-s);background:#ff7a1a;pointer-events:none;animation:wash 1s ease-in-out infinite}
.it.ask .who{align-self:flex-start;background:#ff7a1a;color:#000;text-transform:uppercase;letter-spacing:.06em}
.it.ask .tx{font:calc(var(--t-m)*var(--fs,1))/1.35 var(--mono);white-space:pre-wrap;-webkit-line-clamp:unset;color:var(--text)}
.it.ask .ago{display:none}
.it.ask .opts{position:relative;z-index:1;display:flex;flex-direction:column;align-items:flex-start;gap:4px;outline:none}
.it.ask .opt{padding:3px 10px;border-radius:var(--r-s);border:1px solid #ff7a1a;background:var(--box);color:var(--text);font:650 calc(var(--t-m)*var(--fs,1)) var(--sans);cursor:pointer}
.it.ask .opt:hover{background:#ff7a1a40}
.it.ask .opt::before,.it.ask .typed::before{content:"\00a0\00a0";font-family:var(--mono)}
.it.ask .typed::before{align-self:center;margin-right:4px}
.it.ask .opt.at{background:#ff7a1a59;box-shadow:0 0 0 2px #ff7a1a}
.it.ask .opt.at::before,.it.ask .typed.at::before{content:"❯\00a0";color:#ff7a1a}
.it.ask .opt:disabled{opacity:.5;cursor:progress}
.it.ask .typed{display:flex;align-self:stretch;max-width:520px;min-width:0}
.it.ask .askin{flex:1;min-width:0;padding:3px 8px;border:1px dashed #ff7a1a;border-right:0;border-radius:var(--r-s) 0 0 var(--r-s);background:var(--box);color:var(--text);font:calc(var(--t-m)*var(--fs,1)) var(--sans);outline:none}
.it.ask .askin:focus{border-style:solid;box-shadow:0 0 0 2px #ff7a1a40}
.it.ask .askin.failed{border-color:var(--red)}
.it.ask .opt.go{border-radius:0 var(--r-s) var(--r-s) 0;padding:3px 9px}
.it.ask .opt.go::before{content:none}
.it.ask .reply{font:calc(var(--t-m)*var(--fs,1)) var(--mono);color:var(--text2)}
.it.pending{align-items:flex-start;opacity:.8}
.it.pending .tx{flex:1}
.it.pending .badge{flex:none;font:650 calc(var(--t-xs)*var(--fs,1)) var(--mono);color:var(--amber);border:1px dashed var(--amber);border-radius:var(--r-s);padding:0 5px;margin-top:2px}
.it.live{align-items:center}
.it.live .who{color:var(--c,var(--green));border:1px solid var(--c,var(--green));animation:livepulse 1.4s ease-in-out infinite}
.it.live .tx{font:calc(var(--t-m)*var(--fs,1)) var(--mono);color:var(--c,var(--green));-webkit-line-clamp:1}
.it.live .ago{display:none}
@keyframes livepulse{0%,100%{opacity:.45;box-shadow:none}50%{opacity:1;box-shadow:0 0 10px 1px var(--c,var(--green))}}
.it.tools .tx{font:calc(var(--t-s)*var(--fs,1)) var(--mono);color:var(--faint);-webkit-line-clamp:1}
.it.tools .tx b{color:var(--mute);font-weight:650}
.it.tools .call{display:block}
.it.tools .call + .call{padding-left:1.35em}
.it.tools .call + .call{margin-top:2px}
.it .ago{flex:none;margin-left:auto;color:var(--faint);font:calc(var(--t-s)*var(--fs,1)) var(--mono);padding-left:4px;min-width:calc(3ch + 4px);text-align:right}   /* 9s to 10s does not move the line */
code{font:calc(var(--t-m)*var(--fs,1)) var(--mono);background:var(--codebg);padding:0 4px;border-radius:var(--r-s);color:var(--text)}
code.flat{padding:0;background:none;color:var(--mute)}
.it.pics{flex-wrap:wrap}
.it .thumbs{flex-basis:100%;display:flex;flex-wrap:wrap;gap:6px;padding:2px 0 2px 2px}
.it .thumbs img{display:block;height:56px;max-width:120px;object-fit:cover;border-radius:var(--r-s);border:1px solid var(--line2)}
.it .thumbs a:hover img{border-color:var(--c,var(--hover))}
#detail .conv .it .thumbs img{height:auto;max-height:220px;max-width:360px;object-fit:contain}
#pop{position:fixed;z-index:20;display:none;max-width:560px;max-height:60vh;overflow:auto;padding:10px 13px;border-radius:var(--r-m);
  border:1px solid var(--line2);background:var(--box);color:var(--text);font-size:calc(var(--t-m)*var(--fs,1));line-height:1.45;white-space:pre-line;box-shadow:0 14px 40px #0009}
#pop.on{display:block;cursor:pointer}
#lightbox{position:fixed;inset:0;z-index:40;display:none;align-items:center;justify-content:center;padding:40px;background:#000c;backdrop-filter:blur(3px)}
#lightbox.on{display:flex}
#lightbox figure{margin:0;display:flex;flex-direction:column;align-items:center;gap:8px;max-width:100%;max-height:100%}
#lbwrap{max-width:calc(100vw - 80px);max-height:calc(100vh - 130px);overflow:hidden;border-radius:var(--r-m);box-shadow:0 20px 60px #000a}
#lbwrap.zoomed{overflow:auto;cursor:grab}
#lbwrap.grab{cursor:grabbing}
#lightbox img{display:block;max-width:calc(100vw - 80px);max-height:calc(100vh - 130px);object-fit:contain;background:#fff;user-select:none}
#lbwrap.zoomed img{max-width:none;max-height:none}
#lightbox .zoom{display:flex;align-items:center;gap:4px}
#lightbox .zoom b{min-width:26px;padding:2px 8px;text-align:center;border:1px solid #fff4;border-radius:var(--r-s);color:#eee;cursor:pointer;font-weight:650}
#lightbox .zoom b:hover{background:#fff2}
#lbpct{min-width:44px;text-align:right;color:#aaa}
#lightbox figcaption{display:flex;gap:16px;font:calc(var(--t-m)*var(--fs,1)) var(--mono);color:#ccc}
#lightbox figcaption a{color:#9cf}
#lightbox .x{position:fixed;top:16px;right:22px;color:#ccc;cursor:pointer;font-size:calc(var(--t-xxl)*var(--fs,1));line-height:1}
#lightbox .x:hover{color:#fff}
#graphbox{position:fixed;inset:0;z-index:40;display:none;align-items:center;justify-content:center;padding:40px;background:#000c;backdrop-filter:blur(3px)}
#graphbox.on{display:flex}
#graphbox .doc{display:flex;flex-direction:column;width:min(1100px,100%);border:1px solid var(--line2);border-radius:var(--r-m);background:var(--box);box-shadow:0 14px 40px #0009}
#graphbox .dochead{display:flex;align-items:center;gap:14px;padding:10px 14px;border-bottom:1px solid var(--line);font:calc(var(--t-m)*var(--fs,1)) var(--mono);color:var(--mute)}
#graphname{font-weight:650;color:var(--text)}
#graphsum{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
#graphbox .x{cursor:pointer;font-size:calc(var(--t-xl)*var(--fs,1));line-height:1}
#graphbox .x:hover{color:var(--text)}
#graphbody{position:relative;height:min(360px,60vh);padding:14px 16px 10px}
#graphbody svg{display:block;width:100%;height:100%;overflow:visible}
#graphbody text{font:calc(var(--t-s)*var(--fs,1)) var(--mono);fill:var(--mute)}
#graphbody .grid{stroke:var(--line);stroke-width:1}
#graphbody .cursor{stroke:var(--mute);stroke-dasharray:3 3}
#graphtip{position:absolute;top:8px;padding:3px 7px;border-radius:var(--r-s);border:1px solid var(--line2);background:var(--box);font:calc(var(--t-s)*var(--fs,1)) var(--mono);color:var(--text);pointer-events:none;white-space:nowrap}
#graphbody .blank{display:grid;place-items:center;height:100%;color:var(--mute)}
.mini.perf[data-series]{cursor:pointer}
@media (max-width:600px){#graphbox{padding:12px}}
#docbox{position:fixed;inset:0;z-index:40;display:none;align-items:center;justify-content:center;padding:40px;background:#000c;backdrop-filter:blur(3px)}
#docbox.on{display:flex}
#docbox .doc{display:flex;flex-direction:column;width:min(920px,100%);max-height:100%;border:1px solid var(--line2);border-radius:var(--r-m);background:var(--box);box-shadow:0 14px 40px #0009}
#docbox .dochead{display:flex;align-items:center;gap:14px;padding:10px 14px;border-bottom:1px solid var(--line);font:calc(var(--t-m)*var(--fs,1)) var(--mono);color:var(--mute)}
#docname{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--text)}
#docbox .dochead b{cursor:pointer;font-weight:650}
#docbox .dochead b:hover,#docbox .x:hover{color:var(--text)}
#docbox .dochead b.done{color:var(--green)}
#docall[hidden]{display:none}
#docbox .dochead .di{display:inline-flex;cursor:pointer;color:var(--mute)}
#docbox .dochead .di svg{width:calc(16px*var(--fs,1));height:calc(16px*var(--fs,1))}
#docbox .dochead .di:hover{color:var(--text)}
#docbox .dochead .di.done{color:var(--green)}
#docbox .x{cursor:pointer;font-size:calc(var(--t-xl)*var(--fs,1));line-height:1}
#docbody{overflow:auto;padding:14px 18px;color:var(--text);font-size:calc(var(--t-l)*var(--fs,1));line-height:1.55;white-space:pre-wrap;word-break:break-word}
:is(#docbody, .fdoc) b.h{margin:18px 0 8px;font-weight:650;line-height:1.25}
:is(#docbody, .fdoc) b.h:first-child{margin-top:0}
:is(#docbody, .fdoc) b.h1{padding-bottom:.3em;border-bottom:1px solid var(--line2);font-size:2em}
:is(#docbody, .fdoc) b.h2{padding-bottom:.3em;border-bottom:1px solid var(--line2);font-size:1.5em}
:is(#docbody, .fdoc) b.h3{font-size:1.25em}
:is(#docbody, .fdoc) b.h4{font-size:1.05em}
@media (max-width:600px){#docbox{padding:12px}}
pre.code{display:block;margin:5px 0;padding:7px 10px;font:calc(var(--t-m)*var(--fs,1))/1.4 var(--mono);white-space:pre-wrap;word-break:break-word;background:var(--codebg);border:1px solid var(--line);border-radius:var(--r-s);color:var(--text)}
#detail pre.code{font-size:calc(var(--t-m)*var(--fs,1));margin:6px 0}
pre.code{position:relative}
pre.code .copy{position:absolute;top:5px;right:5px;display:none;place-items:center;width:26px;height:24px;padding:0;border-radius:var(--r-s);border:1px solid var(--line2);background:var(--box);color:var(--mute);cursor:pointer}
pre.code:hover .copy{display:grid}
pre.code .copy:hover{color:var(--text);border-color:var(--hover)}
pre.code .copy.done{color:var(--green);border-color:var(--green)}
#copied{position:fixed;z-index:50;pointer-events:none;padding:3px 8px;border-radius:var(--r-s);background:var(--green);color:#000;font:650 calc(var(--t-s)*var(--fs,1)) var(--sans);opacity:0;transition:opacity .25s}
#copied.on{opacity:1}
a.link{color:var(--cyan);text-decoration:underline;text-underline-offset:2px;word-break:break-all}
.mdtable{max-width:100%;overflow-x:auto;margin:4px 0}   /* a table wider than its turn scrolls sideways */
table.md{border-collapse:collapse;white-space:normal}
table.md th,table.md td{border:1px solid var(--line2);padding:2px 8px;text-align:left;vertical-align:top;min-width:8em}
table.md th{background:var(--line);font-weight:650}
.feed .it .tx{max-height:9em}
/* an agent pane's card: its longer conversation, every turn in full, scrolled */
.card.full .feed{overflow:auto;justify-content:flex-start;mask-image:none}
.card.full .feed > :first-child{margin-top:auto}
.card.full .it .tx{-webkit-line-clamp:unset;white-space:pre-wrap;max-height:none}
/* The Team pane: one transcript of the messages between agents, sender then recipient on each line. */
.teamlog{position:relative;flex:1;min-height:0;display:flex;flex-direction:column;border:1px solid var(--line2);border-radius:var(--r-l);background:var(--box);overflow:hidden}
.teamlog .thead{flex:none;display:flex;flex-wrap:wrap;align-items:center;gap:4px 8px;padding:10px 12px 6px;font-size:calc(var(--t-l)*var(--fs,1));font-weight:650}
.teamlog .thead{position:relative;padding-right:34px}
.teamlog .thead .maxbtn{position:absolute;top:10px;right:10px}
.filelog .ftools{margin-left:auto;display:flex;flex-wrap:wrap;align-items:center;justify-content:flex-end;gap:6px;font:500 calc(var(--t-s)*var(--fs,1)) var(--sans)}
.filelog .ftools b{cursor:pointer;padding:1px 8px;border:1px solid var(--line2);border-radius:6px;background:var(--soft);color:var(--text);font-weight:500}
.filelog .ftools b:hover{border-color:var(--mute)}
.filelog .ftools b.go{border-color:var(--green)}
.filelog .ftools .fdirty{color:var(--amber)}
.filelog .ftools .fmsg{color:var(--mute)}
.filelog .ftools .fmsg.bad{color:var(--red)}
.filelog textarea.fedit{flex:1;min-height:0;resize:none;margin:0;padding:12px 16px;border:0;border-top:1px solid var(--line2);outline:none;background:var(--soft);color:var(--text);font:calc(var(--t-s)*var(--fs,1))/1.5 var(--mono);tab-size:4}
.teamlog .thead > span:nth-child(2){flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font:calc(var(--t-s)*var(--fs,1)) var(--mono);font-weight:400;color:var(--mute)}
.teamlog:not(.summary) .feed{overflow:auto;justify-content:flex-start;mask-image:none}
/* what scrolls in a pane fades out at the top while there is more above and at the bottom while there is more below
   (edges() sets --ft and --fb), keeping a feed's line beneath its head */
.card.full .feed,.teamlog:not(.summary) .feed,.fdoc,.others,.chrs{
  mask-image:linear-gradient(180deg,#000 1px,transparent 1px,#000 calc(1px + var(--ft,0px)),#000 calc(100% - var(--fb,0px)),transparent)}
.teamlog:not(.summary) .feed > :first-child{margin-top:auto}
.teamlog:not(.summary) .it .tx{-webkit-line-clamp:unset;white-space:pre-wrap;max-height:none}
.teamlog .it .who.to::before{content:"→ "}
.teamlog .it .who.ag{background:var(--pc);color:var(--ownerfg)}
.teamlog .it .who.ag:not(.to)::before{content:none}
.teamlog .it.tools .who.ag{margin-right:6px}
.teamlog .clanes{flex:none;margin-left:auto;font-weight:400}
/* the names wrap onto more lines rather than push the lane buttons down, each line under the first */
.teamlog .thead:has(> .cnames .name, > .cnames .chr, > .cnames .face){align-items:flex-start}
.teamlog .thead > .cnames{flex:1 1 0;display:flex;flex-wrap:wrap;gap:4px;overflow:visible;margin-top:2px;font:650 calc(var(--t-m)*var(--fs,1)) var(--sans)}
.teamlog .thead .name{font-size:calc(var(--t-m)*var(--fs,1));line-height:13px;padding:0 6px 2px;cursor:pointer}
/* agents as their Characters tiles: a Tabs pane's tabs, the picked one ringed in its colour, or a Combined pane's agents under its header */
.tabbar.chrtabs{gap:8px}
.chrtabs .chr.sel{outline:2px solid var(--c);outline-offset:2px}
.tabbar.icontabs{gap:10px;padding:13px 13px 2px}   /* inset and spaced as a Combined pane's row of icons */
.icontabs .face,.iconrow .face{cursor:pointer}
.icontabs .face.sel{outline:2px solid var(--c);outline-offset:2px}
/* a working agent's icon: its outline fades in and out, fainter than the picked one's */
.icontabs .face.busy:not(.sel),.iconrow .face.busy{outline:2px solid transparent;outline-offset:2px;animation:breathe 2.4s ease-in-out infinite}
@keyframes breathe{0%,100%{outline-color:transparent}50%{outline-color:color-mix(in srgb,var(--c) 45%,transparent)}}
.icontabs .ftab{position:relative;display:flex}
.tabbar .away{opacity:.45;filter:grayscale(1)}   /* a meeting attendee whose meeting session is not running */
.tabbar button.away{cursor:default}   /* an icon with its unseen count on its corner, clear of its clipping */
.icontabs .ftab .unseen{position:absolute;z-index:1;top:-6px;right:-7px;min-width:15px;height:15px;padding:0 4px;font-size:calc(var(--t-xs)*var(--fs,1));line-height:15px;pointer-events:none;background:var(--ownerfg);color:var(--c);box-shadow:0 0 0 1px var(--c)}
.teamlog .thead > .cnames.iconrow{gap:10px}
.teamlog .thead > .cnames.chrrow{gap:8px;margin:0 0 4px}
.teamlog .it[data-agent]{cursor:pointer}
.teamlog.combined .it.said{border-left:2px solid var(--pc,var(--line2));padding-left:7px}
/* in a wide pane the card's name, state and model lines sit on one row, and in a middling one on two, with a slimmer
   burn line under them */
.pbody{container-type:inline-size}
/* A full card in a grid pane is measured on its own, not by the pane */
.cards > .cell{container-type:inline-size;min-height:0;display:flex;flex-direction:column}
.cards > .cell > .card{flex:1}
.maxbtn,.backbtn{flex:none;display:grid;place-items:center;width:22px;height:20px;border-radius:var(--r-s);color:var(--mute);cursor:pointer}
.maxbtn:hover,.backbtn:hover{background:var(--on);color:var(--text)}
.card > .top > .lead{display:flex;align-items:center;gap:6px}   /* the back button before the name, in a Combined pane showing one agent */
/* a maximised pane's card has its terminal at the top right of its conversation, as the agent's own view does */
.card.full > .termwrap{display:none}
.card.full:hover{transform:none}
.pane:has(.termwrap.big){backdrop-filter:none}
/* A card in a custom Grid or Tabs pane wide enough: its state and its model side by side, so the head is two lines
   (name, then the facts), as an agent pane's is. */
@container (min-width:440px){
  .pbody .card:not(.full){display:grid;grid-template-columns:auto minmax(0,1fr);grid-template-rows:auto auto auto minmax(0,1fr) auto auto}
  .pbody .card:not(.full) > *{grid-column:1/-1}
  .pbody .card:not(.full) > .top + .row2{grid-column:1;grid-row:2;padding-right:0}
  .pbody .card:not(.full) > .row2 + .row2{grid-column:2;grid-row:2}
}
@container (max-width:439.98px){
  .cell > .card.full{display:grid;grid-template-columns:auto minmax(0,1fr);grid-template-rows:auto auto auto minmax(0,1fr) auto auto}
  .cell > .card.full > *{grid-column:1/-1}
  .cell > .card.full > .top + .row2{grid-column:1;grid-row:2;padding-right:0}
  .cell > .card.full > .row2 + .row2{grid-column:2;grid-row:2}
  .cell > .card.full > svg.spark{height:16px}
}
@container (min-width:440px) and (max-width:719.98px){
  .card.full{display:grid;grid-template-columns:auto minmax(0,1fr);grid-template-rows:auto auto auto minmax(0,1fr) auto auto}
  .card.full > *{grid-column:1/-1}
  .card.full > .top .ticket{margin-left:0}
  .card.full > .top + .row2{grid-column:1;grid-row:2;padding-right:0}
  .card.full > .row2 + .row2{grid-column:2;grid-row:2}
  .card.full > .termwrap{display:block;grid-row:4;grid-column:1/-1}
  .card.full.term .feed{padding-right:calc(340px + 40px)}
  .card.full > svg.spark{height:16px}
}
@container (min-width:720px){
  .card.full{display:grid;grid-template-columns:auto auto auto auto minmax(0,1fr) auto auto auto auto;grid-template-rows:auto auto minmax(0,1fr) auto auto;column-gap:10px}
  .card.full > *{grid-column:1/-1}
  .card.full > .top{display:contents}
  .card.full > .top > *,.card.full > .row2{grid-row:1;align-self:center}
  .card.full > .top > .name,.card.full > .top > .lead{grid-column:1;margin:10px 0 8px 12px}
  .card.full > .top > .role{grid-column:2}
  .card.full > .top > .ticket{grid-column:3;margin:0}
  .card.full > .top + .row2{grid-column:4;padding:0}
  .card.full > .row2 + .row2{grid-column:5;padding:0}
  .card.full > .top > .termseg{grid-column:6}
  .card.full > .top > .lanes{grid-column:8;align-self:start;margin:10px -8px 0 4px}
  .card.full > .top > .maxbtn{grid-column:9;align-self:start;margin:10px 10px 0 0;position:static}
  .card.full > .top > .foldbtn{grid-column:7;align-self:start;margin:10px 0 0 4px}
  .card.full > .termwrap{display:block;grid-row:3;grid-column:1/-1}
  .card.full.term .feed{padding-right:calc(340px + 40px)}
  .card.full > svg.spark{height:16px}
}
/* folded: no facts or graph, so the conversation takes the second row and the rest follow, the message box in its own */
.pbody .card.folded,.card.full.folded,.cell > .card.full.folded{grid-template-rows:auto minmax(0,1fr) auto auto}
.card.full.folded > .termwrap{grid-row:2}
b.h{display:block;margin-top:2px;font-weight:650}
.empty{color:var(--faint);font-style:italic;font-size:calc(var(--t-m)*var(--fs,1))}
/* detail */
#detail{position:fixed;inset:0;display:none;background:#000a;backdrop-filter:blur(6px);z-index:9;padding:6vh 8vw}
#detail.open{display:flex}
#detail.docked{background:none;backdrop-filter:none;padding:14px;z-index:2}
#detail.docked .box{box-shadow:none;border-radius:var(--r-l)}
#detail.docked .head .x{display:none}
html.only header,html.only footer,html.only #main,html.only #detail #drail,html.only #dhead :is(.railseg, .x){display:none}
html.only #detail{background:none;backdrop-filter:none;padding:0}
html.only #detail .box{grid-template-columns:minmax(0,1fr);grid-template-rows:auto minmax(0,1fr);border:0;border-radius:0;box-shadow:none}
html.only #detail .box .left{grid-column:1;grid-row:2}
#detail .mini:not(.cur)::before,.others .mini::before{display:none}
#detail .box{--c:#888;--thumb:340px;--rail:220px;position:relative;flex:1;display:grid;grid-template-columns:minmax(0,1fr) var(--rail);grid-template-rows:auto minmax(0,1fr);border:1px solid var(--line2);border-radius:var(--r-l);background:var(--box);overflow:hidden;box-shadow:0 30px 80px #000c}
#detail .head{grid-column:1/-1;display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid var(--line);border-top:3px solid var(--c)}
#detail .head .lanes + .x{margin-left:14px}
#emo{position:fixed;display:none;z-index:60;min-width:220px;max-width:340px;padding:4px;border:1px solid var(--line2);border-radius:var(--r-m);background:var(--box);box-shadow:0 12px 30px #0008;font:calc(var(--t-m)*var(--fs,1)) var(--mono);color:var(--text2)}
#emo div{display:flex;align-items:center;gap:8px;padding:3px 8px;border-radius:var(--r-s);cursor:pointer;white-space:nowrap}
#emo div span{font-size:calc(var(--t-xl)*var(--fs,1));width:20px;text-align:center}
#emo div.on,#emo div:hover{background:var(--on);color:var(--text)}
#detail .head #dmore + .x{margin-left:10px}
#detail .head .termseg{margin-left:auto;flex:none}
#detail .head .termseg + .railseg,#detail .head .railseg + .lanes{margin-left:8px}
#detail .box.noterm .termwrap{display:none}
#detail .box.noterm .conv{padding-right:16px}
/* the header keeps its name, role and switches whole; the facts take the room left and drop whole, from the end,
   when there is not room for them all */
#detail .head > *{flex:none;white-space:nowrap}
#detail .head .facts{flex:1 1 0;display:flex;flex-wrap:wrap;align-items:center;gap:40px 14px;height:18px;margin-left:10px;min-width:0;overflow:hidden;white-space:nowrap;font:calc(var(--t-m)*var(--fs,1))/18px var(--mono);color:var(--mute)}
#detail .head .facts > *{flex:none}
#detail .head .facts .state{display:flex;align-items:center;gap:6px;color:var(--text)}
#detail .head .x{margin-left:auto;color:var(--mute);cursor:pointer;font-size:calc(var(--t-xxl)*var(--fs,1));line-height:1}
/* every other agent in a column on the right, compressed to its status; a click moves to it. The header's edge
   button moves the column to the bottom, the left or the top, where the cards wrap in rows across the view. */
#detail .rail{grid-column:2;grid-row:2;min-height:0;overflow:auto;padding:10px;display:flex;flex-direction:column;gap:8px;border-left:1px solid var(--line)}
#detail .left{grid-column:1;grid-row:2}
#detail .box.rail-left{grid-template-columns:var(--rail) minmax(0,1fr)}
/* Characters: every agent as a portrait tile, in a custom pane */
/* the tiles' panel follows the pane's rounded corners: the bottom two under the pane bar, all four when locked */
.chrs{border-radius:0 0 var(--r-l) var(--r-l);flex:1;min-height:0;overflow:auto;scrollbar-gutter:stable;display:grid;grid-template-columns:repeat(auto-fill,112px);grid-auto-rows:112px;gap:8px;padding:12px 3px 12px 12px;align-content:start;background:var(--chpanel)}
.pane > .pbody:first-child > .chrs{border-radius:var(--r-l)}
.chr{--c:#888;position:relative;width:112px;height:112px;padding:0;border-radius:var(--r-m);border:1px solid var(--line2);border-bottom:3px solid var(--c);
  background:var(--chtile);color:var(--chmute);font:calc(var(--t-xs)*var(--fs,1))/1 var(--mono);cursor:pointer;overflow:hidden}
.chr:hover{filter:brightness(1.08)}
.chr.off{opacity:.5}
.chr.bench{opacity:.4;filter:grayscale(.7)}
.chr.bench:hover{opacity:.7}
.chr.waiting,.chr.wanted{animation:alarm 1s ease-in-out infinite}
.chr .por{position:absolute;left:18px;top:12px;width:76px;height:76px}
.chr .por img{width:100%;height:100%;object-fit:cover;border-radius:var(--r-l);display:block}
.chr .por svg{width:100%;height:100%;display:block;overflow:visible}
/* the agent's name, on the chest of its portrait or shadow */
.chr .nm{position:absolute;left:50%;top:68px;transform:translateX(-50%);max-width:86px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  padding:1px 5px;border-radius:var(--r-s);border:1px solid var(--c);font:650 calc(var(--t-xs)*var(--fs,1))/1.3 var(--sans);color:var(--text);background:color-mix(in srgb,var(--c) 30%,var(--chtile))}
/* clear of a clipboard on the right */
.chr .nm.left{left:41px;max-width:50px}
.chr .tl{position:absolute;top:6px;left:7px;display:flex;align-items:center;gap:4px}
.chr .tl i{--reach:7px;width:6px;height:6px;border-radius:50%;background:var(--faint)}
.chr .tl i.now{background:var(--green)}
.chr.busy .tl i{background:var(--green);animation:ping 1.4s infinite}
.chr.waiting .tl i,.chr.wanted .tl i{--pulse:var(--amber);background:var(--amber);animation:ping 1.4s infinite}
.chr.compacting .tl i{--pulse:var(--cyan);background:var(--cyan);animation:ping 1.4s infinite}
.chr .tr{position:absolute;top:5px;right:6px;display:flex;flex-direction:column;align-items:flex-end;gap:3px}
.chr .tr b{font:650 calc(var(--t-s)*var(--fs,1))/1 var(--mono);color:var(--text)}
.chr .tr b.hi{color:var(--chhigh)}
.chr .tr .unseen{min-width:16px;height:16px;padding:0 4px;font:650 calc(var(--t-xs)*var(--fs,1))/16px var(--sans);background:var(--c);color:var(--ownerfg)}
/* the activity line runs the width of the tile; the ticket, whole, sits over its left end */
.chr .tk{position:absolute;z-index:1;left:5px;bottom:6px;max-width:calc(100% - 10px);white-space:nowrap;padding:2px 3px;border-radius:var(--r-s);
  font-size:calc(var(--t-xs)*var(--fs,1));color:var(--chmute);background:color-mix(in srgb,var(--chtile) 65%,transparent)}
.chr .sp{position:absolute;left:5px;right:5px;bottom:5px;height:16px}
.chr .sp svg.spark{height:16px}
/* the page's menu: a Characters tile's (the agent, then ways to open it) or a filter button's (the lanes, ticked when shown) */
#menu{position:fixed;z-index:60;min-width:150px;padding:5px;border:1px solid var(--line2);border-radius:var(--r-m);background:var(--box);
  box-shadow:0 12px 32px #0007;font:calc(var(--t-m)*var(--fs,1)) var(--sans);color:var(--text);display:none}
#menu.on{display:block}
#menu[data-key^="agent:"]{width:236px}
#menu .sep{margin:4px 0;border-top:1px solid var(--line)}
#menu .mi.off{cursor:default;color:var(--mute)}
#menu .mi.off:hover{background:none}
#menu .mi.warn{color:var(--red)}
#menu .mi.warn svg{color:var(--red)}
#menu .ask{padding:6px 8px 4px;font-size:calc(var(--t-m)*var(--fs,1));line-height:1.45;color:var(--mute);white-space:normal}
#menu .hd{padding:5px 8px 8px;margin-bottom:4px;border-bottom:1px solid var(--line)}
#menu .hd .name{display:inline-block;margin-bottom:4px}
#menu .hd div{font-size:calc(var(--t-m)*var(--fs,1));color:var(--mute);line-height:1.45}
#menu .mi{display:flex;align-items:center;gap:9px;padding:6px 8px;border-radius:var(--r-s);cursor:pointer;white-space:nowrap}
#menu .mi:hover,#menu .mi.at{background:var(--on)}
#menu[data-key="help"]{width:340px}
.it .tx{zoom:var(--conv,1)}
#menu .set{display:flex;align-items:center;gap:12px;padding:3px 8px;font-size:calc(var(--t-m)*var(--fs,1));color:var(--mute)}
#menu[data-key=theme]{max-height:calc(100vh - 12px);overflow:auto}
#menu .hd.sub{margin:6px 0 2px;padding-bottom:4px}
#menu .set input[type=color]{margin-left:auto;width:34px;height:20px;padding:0 2px;border:1px solid var(--line2);border-radius:var(--r-s);background:var(--soft);cursor:pointer}
#menu .set .unset{width:12px;font-weight:400;color:var(--faint);cursor:pointer}
#menu .set .unset.off{visibility:hidden}
#menu .set .unset:hover{color:var(--red)}
#menu .presets{margin-left:auto;display:flex;gap:4px}
#menu .presets button{margin:0}
#menu .set select{margin-left:auto;font:calc(var(--t-m)*var(--fs,1)) var(--sans);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:var(--r-s);padding:1px 4px}
#menu :is(button[data-reset],button[data-edit-theme],button[data-back],.presets button){margin:6px 8px 2px;font:calc(var(--t-m)*var(--fs,1)) var(--sans);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:var(--r-s);padding:2px 10px;cursor:pointer}
#slash{display:none;position:fixed;z-index:70;max-height:50vh;overflow:auto;padding:4px;border:1px solid var(--line2);border-radius:var(--r-m);background:var(--box);box-shadow:0 8px 28px #0006}
#slash .sl{display:flex;gap:10px;align-items:baseline;padding:4px 8px;border-radius:var(--r-s);cursor:pointer;font-size:calc(var(--t-m)*var(--fs,1)*var(--boxfs,1));min-width:0}
#slash .sl b{flex:none;font:650 calc(var(--t-m)*var(--fs,1)*var(--boxfs,1)) var(--mono);color:var(--text)}
#slash .sl span{color:var(--mute);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
#slash .sl.at{background:var(--soft)}
#fpick{display:none;position:fixed;z-index:70;max-height:50vh;overflow:auto;padding:4px;border:1px solid var(--line2);border-radius:var(--r-m);background:var(--box);box-shadow:0 8px 28px #0006}
#fpick .fp{display:flex;gap:8px;align-items:baseline;padding:3px 8px;border-radius:var(--r-s);cursor:pointer;font:calc(var(--t-m)*var(--fs,1)) var(--mono);color:var(--text);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#fpick .fp.dir{color:var(--accent,var(--text));font-weight:650}
#fpick .fp.at{background:var(--soft)}
#fpick .none{padding:3px 8px;color:var(--mute);font:calc(var(--t-m)*var(--fs,1)) var(--sans)}
#menu .sc{display:flex;align-items:baseline;gap:12px;padding:3px 8px;font-size:calc(var(--t-m)*var(--fs,1));color:var(--mute)}
#menu .sc kbd{flex:none;margin-left:auto;padding:1px 6px;border:1px solid var(--line2);border-radius:var(--r-s);font:calc(var(--t-s)*var(--fs,1)) var(--mono);color:var(--text);white-space:nowrap}
#menu .hd:has(.spark){min-width:200px}
#menu .hd .spark{width:100%;margin:5px 0 2px}
#menu .hd .hrow{display:flex;align-items:flex-start;gap:10px;color:inherit}
#menu:has(.hrow){min-width:264px}   /* room for a full name beside the portrait */
#menu .hd .htxt{flex:1;min-width:0;font-size:inherit;color:inherit}
#menu .hd .htxt .name{white-space:normal}   /* a name too long for its room wraps, not under the portrait */
#menu .mpor{flex:none;width:96px;height:96px}
#menu .mpor img{display:block;width:100%;height:100%;object-fit:cover;border-radius:var(--r-m);position:relative;transform-origin:top right;transition:transform .15s ease}
#menu .mpor:hover img{z-index:2;transform:scale(2.67);box-shadow:0 12px 32px #0009}   /* the mouse over it shows it at full size, in place */
#menu .hd:last-child{margin-bottom:0;border-bottom:0}
#menu .hd ~ .hd{margin-top:6px;border-top:1px solid var(--line);padding-top:8px}
#menu .mi svg{flex:none;width:14px;height:14px;color:var(--mute)}
#menu .mi svg.off{visibility:hidden}
#menu .mi svg.tick{margin-left:auto}
#menu .mi .dot{flex:none;width:10px;height:10px;margin:0 2px;border-radius:50%;background:var(--c)}
#menu .mi kbd{margin-left:auto;font:calc(var(--t-s)*var(--fs,1)) var(--mono);color:var(--mute)}
#detail .box.rail-left .rail{grid-column:1;border-left:0;border-right:1px solid var(--line)}
#detail .box.rail-left .left{grid-column:2}
#detail .box.rail-top,#detail .box.rail-bottom{grid-template-columns:minmax(0,1fr)}
#detail .box.rail-top{grid-template-rows:auto auto minmax(0,1fr)}
#detail .box.rail-bottom{grid-template-rows:auto minmax(0,1fr) auto}
#detail .box.rail-top .rail,#detail .box.rail-bottom .rail{grid-column:1;display:grid;grid-template-columns:repeat(auto-fill,minmax(calc(var(--rail) - 20px),1fr));max-height:35vh;border-left:0}
#detail .box.rail-top .rail{grid-row:2;border-bottom:1px solid var(--line)}
#detail .box.rail-top .left{grid-row:3}
#detail .box.rail-bottom .rail{grid-row:3;border-top:1px solid var(--line)}
/* opened over the page, the view is the agent alone: the other agents' column is only beside the Tabs page's docked view */
#detail:not(.docked) :is(#drail, #drailgrip, #dhead .railseg){display:none}
#detail:not(.docked) .box{grid-template-columns:minmax(0,1fr);grid-template-rows:auto minmax(0,1fr)}
#detail:not(.docked) .box .left{grid-column:1;grid-row:2}
.mini{--c:#888;position:relative;flex:none;padding:8px 10px 4px;border-radius:var(--r-m);border:1px solid var(--line2);background:linear-gradient(180deg,var(--card1),var(--card2));
  cursor:pointer;overflow:hidden;transition:border-color .15s}
.mini::before{content:"";position:absolute;inset:0 0 auto 0;height:2px;background:var(--c)}
.mini:hover{border-color:var(--c)}
.mini.waiting,.mini.wanted{border:2px solid #ffb020;animation:alarm 1s ease-in-out infinite}
.mini.off,.tabbar button.off{opacity:.45}
.mini.cur:not(.waiting):not(.wanted){border-color:var(--c)}
.mini.cur{box-shadow:inset 3px 0 0 var(--c);cursor:default}
.mini .mtop{display:flex;align-items:center;gap:6px;font:calc(var(--t-s)*var(--fs,1)) var(--mono);color:var(--mute);white-space:nowrap;min-width:0}
.unseen{flex:none;min-width:18px;height:18px;padding:0 5px;border-radius:var(--r-m);background:var(--c);color:var(--ownerfg);font:650 calc(var(--t-s)*var(--fs,1))/18px var(--sans);text-align:center}
.tabbar .unseen{margin-left:6px;background:var(--ownerfg);color:var(--c)}   /* the tab text's colour, so it follows the theme */
/* One line: name (with its state dot and unseen count, as a tab), ticket, how long, context; the ticket gives way. */
.mini .name{flex:none;display:flex;align-items:center;gap:5px;font-family:var(--sans);font-size:calc(var(--t-m)*var(--fs,1));line-height:13px;padding:2px 6px 2px;min-height:19px}   /* as tall with an unseen count as without, as a tab is */
.mini .name .dot{flex:none}
.mini .name .unseen{min-width:15px;height:15px;padding:0 4px;font-size:calc(var(--t-xs)*var(--fs,1));line-height:15px;background:var(--ownerfg);color:var(--c)}
.mini .ticket{flex:0 1 auto;min-width:0;margin-left:0;overflow:hidden;text-overflow:ellipsis;font-size:calc(var(--t-s)*var(--fs,1));padding:0 5px}
.mini .mtop .ago,.mini .mtop .pct{flex:none}
.mini .mtop .pct{margin-left:auto}
.mini svg.spark{height:16px;margin-top:3px}
.mini:not(:has(svg.spark)){padding-bottom:8px}
.mini.perf{cursor:default}
.mini.perf .name .dot{display:none}   /* an agent's state; a figure has none */
.mini .pdet{flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis}   /* with no sparkline, as much space below the name as above */
/* A Gauges pane: the Performance pane's figures as tiles side by side, each a half-circle with its figure inside and
   its name below. */
.others.perfs.dials{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));grid-auto-rows:max-content;align-content:start}   /* a short pane scrolls its gauges, never squeezes them */
.others.perfs.dials .mini.dial{min-height:0;padding:10px 10px 9px;display:flex;flex-direction:column;align-items:center;text-align:center}
.mini.dial svg.arc{flex:none;width:100%;max-width:150px;height:auto;display:block}
.mini.dial svg.arc path{fill:none;stroke-width:9;stroke-linecap:round}
.mini.dial svg.arc path.track{stroke:var(--line2)}
.mini.dial .dfig{margin-top:-30px;font:650 calc(var(--t-xl)*var(--fs,1)) var(--mono);line-height:22px}
.mini.dial .dfig.rate{margin-top:-39px}   /* raised by its unit's line, so its name sits where every gauge's does */
.mini.dial .dfig small{display:block;margin-top:-4px;font:400 calc(var(--t-xs)*var(--fs,1))/12px var(--mono)}
.mini.dial .dname{margin-top:6px;font:calc(var(--t-m)*var(--fs,1)) var(--sans);color:var(--text)}
.mini.dial .pdet{max-width:100%;margin-top:2px;font:calc(var(--t-s)*var(--fs,1))/1.35 var(--mono);color:var(--mute);white-space:normal;
  display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;min-height:2.7em}   /* two lines, kept for every gauge so a row's stand level */
/* The List pane's cards, and the pop-up's side rail, share their height: when there are more agents than room,
   each card's line shrinks first, down to its name row, and only then does the list scroll. */
.others .mini,#detail .box:not(.rail-top):not(.rail-bottom) .rail .mini{flex:0 1 auto;min-height:32px;display:flex;flex-direction:column}
.others .mini svg.spark,#detail .box:not(.rail-top):not(.rail-bottom) .rail .mini svg.spark{flex:0 1 16px;min-height:0;height:auto}
#detail .left{position:relative;display:flex;flex-direction:column;min-height:0;min-width:0}
#dbottom,.card .newest,.teamlog .newest{position:absolute;left:50%;bottom:64px;transform:translateX(-50%);z-index:3;display:none;padding:5px 14px;border-radius:var(--r-l);
  border:1px solid var(--c,var(--line2));background:var(--c,var(--line2));color:#000;font:650 calc(var(--t-m)*var(--fs,1)) var(--sans);cursor:pointer;box-shadow:0 6px 18px #0007}
#dbottom.on,.card .newest.on,.teamlog .newest.on{display:block}
#dbottom:hover,.card .newest:hover,.teamlog .newest:hover{filter:brightness(1.15)}
.teamlog .chat{flex:none;border-top:1px solid var(--line);padding-top:8px}
.teamlog .chead{display:flex;align-items:center;gap:6px;margin:0 10px 6px}
.teamlog .chead .face{width:26px;height:26px;border-radius:var(--r-s);border-bottom-width:2px}
.teamlog .chead .name{font-size:calc(var(--t-m)*var(--fs,1));line-height:13px;padding:0 6px 2px}
.teamlog .chead .pick{cursor:pointer}
.pbody > .ctabs{flex:none;display:flex;flex-wrap:wrap;align-items:flex-end;gap:2px;margin:6px 12px 6px;border-bottom:1px solid var(--line)}
.ctabs .ctab{display:flex;align-items:center;gap:6px;padding:4px 10px 5px;margin-bottom:-1px;border:1px solid transparent;border-bottom:none;
  border-radius:var(--r-s) var(--r-s) 0 0;font:650 calc(var(--t-m)*var(--fs,1)) var(--sans);color:var(--mute);cursor:pointer;user-select:none}
.ctabs .ctab:hover{color:var(--text)}
/* the custom views beside the View button: a row of small tabs with + at its end */
#menu .vmi .vname{flex:1}
.meetbar{display:flex;align-items:center;gap:8px;padding:6px 13px;font-size:calc(var(--t-m)*var(--fs,1));color:var(--mute)}
.meetbar span{margin-right:auto}
.meetbar.on b{color:var(--text)}
.meetbar.on{border-bottom:1px solid var(--line)}
.meetbar + .icontabs{padding:6px 13px 10px}   /* the faces under the bar, in line with its text and clear of the conversation below */
#menu .mi .mute{color:var(--mute)}
.meetbar .mbtn{display:inline-flex;align-items:center;gap:5px;padding:2px 10px;border:1px solid var(--line2);border-radius:999px;color:var(--text);cursor:pointer}
.meetbar .mbtn:hover{background:var(--on)}
.meetbar .mbtn.warn{color:var(--red);border-color:var(--red)}
.meetbar .mbtn svg{width:12px;height:12px}
/* the meeting's topic before it starts, how many are in it (amber above three, red above five), and the agents' faces:
   one on the way greyed, one whose meeting session is working pulsing */
.meetbar .mtopic{flex:1;min-width:0;margin-right:auto;font:inherit;color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:var(--r-s);padding:2px 8px}
.meetpick{flex-wrap:wrap;gap:8px 6px}
.pbody .blank:has(.agentpick){display:flex;flex-direction:column;align-items:center}
.agentpick{display:flex;flex-wrap:wrap;gap:6px;justify-content:center}
.agentpick.big{gap:12px 10px;max-width:640px;margin-top:10px}
.agentpick .ftab{display:flex;flex-direction:column;align-items:center;gap:3px;cursor:pointer}
.pown .agentpick{justify-content:flex-start;flex:1 1 0;min-width:0}
.pown .agentpick .face{width:22px;height:22px}
.agentpick .ftab:not(.sel) .face{opacity:.55}
.agentpick .ftab:hover .face,.agentpick.big .ftab .face{opacity:1}
.agentpick .ftab.sel .face{outline:2px solid var(--c);outline-offset:2px}
.agentpick small{max-width:64px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:calc(var(--t-xs)*var(--fs,1));color:var(--mute)}
.meetpick .ftab,.meetrow .ftab{display:flex;flex-direction:column;align-items:center;gap:3px}
.meetpick .ftab[data-invite]{cursor:pointer}
.meetpick .ftab small,.meetrow .ftab small{max-width:64px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:calc(var(--t-xs)*var(--fs,1));color:var(--mute)}
.meetpick .ftab.away{opacity:.4;filter:grayscale(1)}
.meetbar .mcount{margin-right:0;min-width:18px;padding:0 6px;border-radius:999px;text-align:center;font-weight:650;color:var(--text);background:var(--soft);border:1px solid var(--line2)}
.meetbar .mcount.amber{color:#000;background:var(--amber);border-color:var(--amber)}
.meetbar .mcount.red{color:#fff;background:var(--red);border-color:var(--red)}
/* a meeting session joining fades in and out; one there and thinking has the working agent's breathing outline */
.meetrow .ftab.away.mbusy .face{animation:switching 1.6s ease-in-out infinite}
.meetrow .ftab.mbusy:not(.away) .face{outline:2px solid transparent;outline-offset:2px;animation:breathe 2.4s ease-in-out infinite}
.teamlog.meeting .it.mevent .tx{font-style:italic;color:var(--faint)}
/* at the meeting's end, each agent's suggestion for its own session, to send as written or edited, or skip */
.teamlog.meeting .hands{display:flex;flex-direction:column;gap:8px;padding:8px 13px;border-top:1px solid var(--line)}
.teamlog.meeting .hand{display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;font-size:calc(var(--t-m)*var(--fs,1))}
.teamlog.meeting .hand .htext{flex:1 1 100%;min-height:3.5em;resize:vertical;font:calc(var(--t-m)*var(--fs,1)) var(--sans);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:var(--r-m);padding:6px 8px}
.teamlog.meeting .hand .hbtns{display:flex;gap:6px;margin-left:auto}
.teamlog.meeting .hand .mbtn{display:inline-flex;align-items:center;gap:5px;padding:2px 10px;border:1px solid var(--line2);border-radius:999px;color:var(--text);cursor:pointer}
.teamlog.meeting .hand .mbtn:hover{background:var(--on)}
.teamlog.meeting .hand .mbtn svg{width:12px;height:12px}
#menu .mi .dot.hollow{background:none;border:2px solid var(--c);width:8px;height:8px}
#menu .vmi .vico{display:inline-flex;align-items:center;border-radius:var(--r-s)}
#menu .vmi .vico.pick{padding:2px;margin:-3px;border:1px solid var(--line2);cursor:pointer}
#menu .vmi .vico.pick::after{content:"";margin-left:2px;border:3px solid transparent;border-top-color:var(--mute);transform:translateY(2px)}
#menu .vicons{display:grid;grid-template-columns:repeat(7,22px);gap:2px;padding:4px 8px 6px 28px}
#menu .vicons i{display:flex;align-items:center;justify-content:center;height:22px;border-radius:var(--r-s);cursor:pointer}
#menu .vicons i:hover{background:var(--on)}
#menu .vicons i.on{outline:1px solid var(--line2)}
#menu .vicons svg{width:14px;height:14px;color:var(--text)}
#menu .vmi .vname input{width:9em}
#menu .vmi .vbtn{display:inline-flex;width:14px;height:14px;opacity:.55}
#menu .vmi .vbtn:hover{opacity:1}
#menu .vmi svg.tick{margin-left:0}
.ctabs .ctab.sel{color:var(--text);background:var(--box);border-color:var(--line)}
.ctabs .cx{display:flex;opacity:.55}
.ctabs .cx:hover{opacity:1}
.ctabs .cx svg{width:11px;height:11px}
.ctabs .ctab.dragging{opacity:.4}
.ctabs .ctab.before{box-shadow:inset 2px 0 0 var(--text)}
.ctabs .ctab.after{box-shadow:inset -2px 0 0 var(--text)}
.ctabs .ctname{width:9em;padding:0 4px;font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--line2);border-radius:var(--r-s);outline:none}
#menu .mi .face{width:20px;height:20px;border-radius:var(--r-s);border-bottom-width:2px}
.teamlog.combined{container:sayroom/size}
.teamlog .chead .x{margin-left:auto;display:flex;padding:3px;border-radius:var(--r-s);color:var(--mute);cursor:pointer}
.teamlog .chead .x:hover{color:var(--text);background:var(--line2)}
.teamlog .chead .x svg{width:14px;height:14px}
.teamlog .newest{--c:var(--ownerbg);color:var(--ownerfg)}
#detail .conv{flex:1;min-height:0;overflow:auto;padding:14px calc(var(--thumb) + 40px) 14px 16px;display:flex;flex-direction:column;gap:9px}
.sayrow{flex:none;display:flex;align-items:flex-start;gap:6px;margin:0 10px 10px}
.say{flex:1;min-width:0;display:block;margin:0;padding:6px 10px;border-radius:var(--r-m);border:1px solid var(--line2);background:var(--soft);
  color:var(--text);font:calc(var(--t-m)*var(--fs,1)*var(--boxfs,1))/1.4 var(--sans);outline:none;transition:border-color .15s,box-shadow .15s;resize:none;overflow-y:hidden;max-height:120px}
.say::placeholder{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--faint)}
.say:focus{border-color:var(--c);box-shadow:0 0 0 3px color-mix(in srgb,var(--c) 25%,transparent)}
.say.sent{border-color:var(--green)}
.say.failed{border-color:var(--red)}
.say.dropping{border-color:var(--cyan);box-shadow:0 0 0 3px color-mix(in srgb,var(--cyan) 25%,transparent)}
.say{padding-right:34px}
.send{flex:none;align-self:flex-start;position:relative;z-index:1;width:25px;height:25px;margin:5px 3px 0 calc(-6px - 28px);padding:0;border:0;border-radius:var(--r-s);
  background:none;color:var(--mute);cursor:pointer}   /* inside the box: the row's gap and its own width pulled back over the box's end */
.send::before{content:"";position:absolute;inset:0;margin:auto;width:60%;height:60%;transform:translateX(-3px) rotate(45deg);background:currentColor;-webkit-mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath d='M2.5 11.2 21 3.5l-7.7 18.5-2.6-7.9z' fill='none' stroke='black' stroke-width='2' stroke-linejoin='round'/%3E%3Cpath d='M10.7 14.1 21 3.5' stroke='black' stroke-width='2' stroke-linecap='round'/%3E%3C/svg%3E") center/contain no-repeat;mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath d='M2.5 11.2 21 3.5l-7.7 18.5-2.6-7.9z' fill='none' stroke='black' stroke-width='2' stroke-linejoin='round'/%3E%3Cpath d='M10.7 14.1 21 3.5' stroke='black' stroke-width='2' stroke-linecap='round'/%3E%3C/svg%3E") center/contain no-repeat}   /* a paper plane (owner, 2026-11-01) */
.send:hover{color:var(--text)}
#detail .say{padding-right:42px}
#detail .send{width:31px;height:31px;margin:6px 4px 0 calc(-6px - 35px)}
#detail .sayrow{margin:0 14px 14px}
.mini .mtop .mstat{flex:0 1 auto;min-width:0;font:calc(var(--t-s)*var(--fs,1)) var(--sans);color:var(--mute);overflow:hidden;text-overflow:ellipsis}
.mini.busy .mtop .mstat{color:var(--green)}
.mini.waiting .mtop .mstat,.mini.wanted .mtop .mstat{color:var(--amber)}
#detail .box:not(.noterm) .sayrow{margin-right:calc(var(--thumb) + 40px)}
.add{flex:none;position:relative;width:31px;height:31px;padding:0;border-radius:var(--r-m);border:1px solid var(--line2);background:var(--soft);color:var(--mute);cursor:pointer}
.add::before,.add::after{content:"";position:absolute;inset:0;margin:auto;width:12px;height:1.5px;border-radius:var(--r-xs);background:currentColor}
.add::after{width:1.5px;height:12px}
.add:hover{color:var(--text);border-color:var(--hover)}
.att{display:flex;flex-wrap:wrap;gap:8px;margin:0 10px 6px}
.att:empty{display:none}
#detail .att{margin:0 14px 8px}
.att span{position:relative;flex:none}
.att img{display:block;height:48px;max-width:120px;object-fit:cover;border-radius:var(--r-s);border:1px solid var(--line2)}
.att b{position:absolute;top:3px;right:3px;width:18px;height:18px;display:grid;place-items:center;border-radius:var(--r-s);background:#000a;color:#fff;font-size:calc(var(--t-s)*var(--fs,1));font-weight:400;cursor:pointer}
.att b:hover{background:#000d}
.att .file{height:48px;display:inline-block;max-width:220px;padding:0 30px 0 10px;border-radius:var(--r-s);border:1px solid var(--line2);
  font:calc(var(--t-m)*var(--fs,1))/46px var(--mono);color:var(--mute);overflow:hidden;white-space:nowrap;text-overflow:ellipsis}   /* a file that is not an image: its name */
.att .file b{line-height:normal}
#detail .say{padding:9px 12px;font-size:calc(var(--t-l)*var(--fs,1)*var(--boxfs,1));max-height:35vh}
/* where a card or the agent's own view is tall enough, its box starts three lines tall */
.card,#detail .left{container:sayroom/size}
@container sayroom (min-height:360px){.say{min-height:calc(4.2em + 14px)} #dsay{min-height:calc(4.2em + 20px)}}
.stop.going{cursor:default;animation:stopping .9s ease-in-out infinite}
@keyframes stopping{50%{opacity:.3}}
.stop{flex:none;position:relative;width:31px;height:31px;border-radius:var(--r-m);border:1px solid var(--line2);background:var(--soft);cursor:pointer}
.stop::before{content:"";position:absolute;inset:0;margin:auto;width:10px;height:10px;border-radius:var(--r-xs);background:var(--text)}
.stop:hover{border-color:var(--red)}
.stop:hover::before{background:var(--red)}
#detail .stop,#detail .add{width:39px;height:39px}
#detail .stop::before{width:12px;height:12px}
#detail .conv .it{font-size:calc(var(--t-l)*var(--fs,1))}
#detail .conv .it .tx{-webkit-line-clamp:unset;white-space:pre-wrap}
/* text shown whole flows as a block, so a message's badges open its first line and its later lines run beneath them */
.card.full .it .tx,.teamlog:not(.summary) .it .tx,#detail .conv .it .tx,.it.ask .tx{display:block}
#detail .conv .it.tools .tx{white-space:normal}
/* the pane as a live thumbnail at the top right, in a terminal window of its own shape; a click expands it over
   the whole window over a dimmed page, as large as fits, as an image does */
:is(#detail,.card.full) .termwrap{position:absolute;top:14px;right:16px;z-index:2;cursor:zoom-in}
:is(#detail,.card.full) .termwrap:hover .term{border-color:var(--c)}
:is(#detail,.card.full) .termwrap.big{position:fixed;inset:0;z-index:40;display:flex;justify-content:center;align-items:center;padding:40px;cursor:default;
  background:#000c;backdrop-filter:blur(3px)}
:is(#detail,.card.full) .termwrap .x{display:none;position:fixed;top:16px;right:22px;color:#ccc;cursor:pointer;font-size:calc(var(--t-xxl)*var(--fs,1));line-height:1}
:is(#detail,.card.full) .termwrap.big .x{display:block}
:is(#detail,.card.full) .termwrap .x:hover{color:#fff}
:is(#detail,.card.full) .term{display:flex;flex-direction:column;border-radius:var(--r-m);overflow:hidden;background:#06080b;border:1px solid #ffffff1f;box-shadow:0 18px 50px #0008;transition:border-color .15s}
:is(#detail,.card.full) .bar{flex:none;display:flex;align-items:center;gap:7px;padding:8px 12px;background:#161b22;border-bottom:1px solid #ffffff14;font:calc(var(--t-m)*var(--fs,1)) var(--sans);color:#8b949e}
:is(#detail,.card.full) .bar i{width:11px;height:11px;border-radius:50%;background:#ff5f57}
:is(#detail,.card.full) .bar i:nth-child(2){background:#febc2e}:is(#detail,.card.full) .bar i:nth-child(3){background:#28c840;margin-right:8px}
:is(#detail,.card.full) .bar span{flex:1;text-align:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
:is(#detail,.card.full) .bar b{cursor:pointer;font-weight:400;font-size:calc(var(--t-l)*var(--fs,1));padding:0 2px;color:#8b949e}
:is(#detail,.card.full) .bar b:hover{color:#e6edf3}
:is(#detail,.card.full) .screen{overflow:hidden;padding:10px}
#dscreen,.card.full .termwrap pre{margin:0;font-family:var(--mono);line-height:1.25;color:#d1d7e0;white-space:pre;overflow:hidden}
::-webkit-scrollbar{width:9px;height:9px}::-webkit-scrollbar-thumb{background:var(--thumb);border-radius:var(--r-m)}
/* On a phone (owner, 2026-11-01: "move to the mobile experience"): the bars wrap; Grid's sections stand one under
   another, two cards across, and the page scrolls; an agent's view fills the screen, the others one row along its
   top to swipe, and no terminal; a custom view's panes stand one under another. A box's text is 16px, under which
   a phone zooms the page when it is tapped. */
@media (max-width:700px){
  header,footer{flex-wrap:wrap;gap:10px 14px;padding:8px 12px}
  .bi.tight + .bi.tight,.bi:not(.tight) + .bi.tight{margin-left:0}
  .bi[data-item=bench]{flex:1 1 100%}
  .editing > .bi.div{width:35px;padding:0 16px}   /* a finger's width to grab it by (owner, 2026-11-02: "impossible to grab on the phone") */
  .colgrip{display:none}
  main{display:block;overflow-y:auto;padding:10px}
  main > section.tab{margin-bottom:12px}
  main > section.tab .cards{grid-template-columns:repeat(2,minmax(0,1fr)) !important;grid-auto-rows:250px}
  #detail,#detail.docked{padding:0}
  #detail .box,#detail .box.rail-left,#detail .box.rail-top,#detail .box.rail-bottom{border-radius:0;grid-template-columns:minmax(0,1fr);grid-template-rows:auto auto minmax(0,1fr)}
  #detail .box .rail{grid-column:1;grid-row:2;display:flex;flex-direction:row;overflow:auto hidden;max-height:none;padding:8px;border:0;border-bottom:1px solid var(--line)}
  #detail .box .rail .mini{flex:none !important;width:130px}
  #detail .box .left{grid-column:1 !important;grid-row:3 !important}
  :is(#detail:not(.docked),html.only #detail) .box{grid-template-rows:auto minmax(0,1fr)}   /* no row of others: only a docked view has one */
  :is(#detail:not(.docked),html.only #detail) .box .left{grid-row:2 !important}
  #detail .termwrap,#detail .head :is(.termseg,.railseg),#detail .head .facts{display:none}
  #detail #dhead .lanes{margin-left:auto}   /* the facts, hidden, were what pushed it and the ✕ to the right */
  #detail .box .conv{padding-right:16px}
  #detail .box .sayrow{margin-right:14px !important}
  .card.full.term .feed{padding-right:0}
  main > .pane{height:100%;min-height:60vh}   /* a custom view of one pane fills the page, not just its tab strip */
  #main .lay{flex-direction:column}
  #main .lay > .half{flex:none;min-height:75vh}
  #main .divider{display:none}
  .say,#detail .say{font-size:16px}
  .say,#dsay{min-height:0 !important}   /* one line until typed into further: the keyboard leaves little room (owner, 2026-11-01) */
}
/* ── The phone (owner, 2026-11-08: "the real issue I have is on the phone"): at 700px or narrower the page is an app of
   its own. A list of the team, waiting agents first, or their portraits; a tap opens the agent full screen (the agent
   view); a menu for the team's controls. Header, panes and footer are the desktop's and are hidden. "Desktop layout"
   in the menu turns it off in this browser, and a button brings it back. */
#phone,#phoneback{display:none}
html.phone body > header,html.phone body > main,html.phone body > footer{display:none !important}
html.phone #phone{display:flex;flex-direction:column;flex:1;min-height:0;font-size:15px}
#phone > .ph-loading{margin:auto;color:var(--mute)}
#phone button{font:inherit;color:inherit}
#phone .ph-top{flex:none;display:flex;align-items:center;gap:10px;height:60px;padding:0 6px 0 14px;border-bottom:1px solid var(--line2);background:var(--card1)}
#phone .ph-title{flex:1;min-width:0;display:flex;flex-direction:column}
#phone .ph-title b{font-size:17px}
#phone .ph-title span{font-size:12px;color:var(--mute);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#phone .ph-week{flex:none;display:flex;align-items:center;gap:7px;height:44px;padding:0 11px;border:1px solid var(--line2);border-radius:22px;background:var(--card1);font:600 13px var(--mono)}
#phone .ph-week i{display:block;width:30px;height:6px;border-radius:3px;background:var(--track);overflow:hidden}
#phone .ph-week i{position:relative}
#phone .ph-week i u{display:block;height:100%;border-radius:3px}
#phone .ph-week i s{position:absolute;top:-2px;bottom:-2px;width:2px;background:var(--text);opacity:.6}
#phone .ph-week{max-width:52%;min-width:0;overflow:hidden}
#phone .ph-week .gl{font:600 11px var(--sans);color:var(--mute);text-transform:uppercase;letter-spacing:.04em}
#phone .ph-week .gv{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
#phone .ph-week .gv b{font-weight:600}
#phone .ph-icon{flex:none;width:44px;height:44px;border:0;border-radius:22px;background:none;display:grid;place-items:center;cursor:pointer}
#phone .ph-icon svg{width:22px;height:22px}
#phone .ph-body{flex:1;min-height:0;overflow-y:auto;padding:12px 12px 20px;display:flex;flex-direction:column;gap:16px;-webkit-overflow-scrolling:touch}
#phone h2{margin:0 4px 6px;font-size:12px;font-weight:600;letter-spacing:.08em;color:var(--mute);text-transform:uppercase}
#phone .ph-favs h2 svg{width:13px;height:13px;margin:0 5px -1px 0;fill:var(--amber);stroke:var(--amber)}
#phone .ph-list{display:flex;flex-direction:column;border-radius:14px;border:1px solid var(--line);background:var(--card1);overflow:hidden}
#phone .ph-row{display:flex;align-items:center;gap:12px;min-height:56px;padding:8px 14px;border:0;border-bottom:1px solid var(--line);background:none;text-align:left;cursor:pointer;width:100%}
#phone .ph-row:last-child{border-bottom:0}
#phone .ph-row.big{min-height:68px}
#phone .ph-mid{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px}
#phone .ph-line1{display:flex;align-items:center;gap:8px;min-width:0}
#phone .ph-name{font-weight:600;white-space:nowrap}
#phone .ph-role{font-size:13px;color:var(--mute);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#phone .ph-tk{font:500 11px var(--mono);padding:2px 6px;border-radius:6px;background:var(--codebg);color:var(--cyan);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
#phone .ph-right{margin-left:auto;flex:none;font:500 12px var(--mono);color:var(--mute);display:flex;align-items:center;gap:6px}
#phone .ph-sub{font-size:13px;color:var(--mute);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#phone .ph-sub.live{color:var(--green);font-family:var(--mono);font-size:12px}
/* a portrait: the agent's picture, else its role's shadow, framed in its colour, with its state as a dot */
#phone .ph-por{position:relative;flex:none;width:44px;height:44px}
#phone .ph-por.s{width:40px;height:40px}
#phone .ph-por.bench{display:block}   /* not the desktop bench's grid, whose gap narrowed a stopped agent's frame (owner, 2026-11-09) */
#phone .ph-por > .fr{display:block;width:100%;height:100%;box-sizing:border-box;border-radius:12px;border:2.5px solid var(--c);overflow:hidden;background:var(--chtile)}
#phone .ph-por img,#phone .ph-por svg{display:block;width:100%;height:100%;object-fit:cover}
#phone .ph-por i{position:absolute;right:-3px;bottom:-3px;width:12px;height:12px;border-radius:6px;border:2px solid var(--card1);background:var(--faint)}
#phone .busy i,#phone .compacting i{background:var(--green)}
#phone .waiting i{background:var(--amber)}
#phone .off .ph-por > .fr > *,#phone .bench > .fr > *{filter:grayscale(1);opacity:.55}   /* the portrait greyed, its frame keeping its role colour (owner, 2026-11-11) */
#phone .ph-wait{display:flex;align-items:center;gap:12px;min-height:64px;padding:10px 14px;border-radius:14px;border:1.5px solid var(--amber);background:color-mix(in srgb,var(--amber) 14%,var(--card1));text-align:left;cursor:pointer;width:100%}
#phone .ph-wait small{display:block;font-size:11px;font-weight:700;letter-spacing:.07em;color:var(--amber);text-transform:uppercase}
#phone .ph-wait b{display:block;font-weight:600;overflow:hidden;text-overflow:ellipsis;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical}
#phone .ph-chips{display:flex;flex-wrap:wrap;gap:8px}
#phone .ph-chip{display:flex;align-items:center;gap:8px;height:44px;padding:0 14px 0 4px;border-radius:22px;border:1px dashed var(--faint);background:none;color:var(--mute);cursor:pointer}
#phone .ph-chip .ph-por{width:36px;height:36px}
#phone .ph-chip .ph-por > .fr{border-radius:18px;border-width:2px}
#phone .unseen{position:static}
/* the Portraits tab: the faces large, three across */
#phone .ph-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px}
#phone .ph-grid.bench{grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}
#phone .ph-tile{display:flex;flex-direction:column;gap:6px;padding:0;border:0;background:none;text-align:left;cursor:pointer;-webkit-touch-callout:none;user-select:none}
#phone .ph-tile .ph-por{width:100%;height:auto;aspect-ratio:1}
#phone .ph-tile .ph-por > .fr{border-radius:16px;border-width:3px}
#phone .ph-tile.waiting .ph-por > .fr{box-shadow:0 0 0 3px var(--bg),0 0 0 6px var(--amber)}
#phone .ph-tile .ph-st{position:absolute;left:6px;bottom:6px;display:flex;align-items:center;gap:5px;height:22px;padding:0 8px;border-radius:11px;background:var(--card1);font:600 11px var(--sans);color:var(--mute)}
#phone .ph-tile .ph-st:before{content:"";width:7px;height:7px;border-radius:4px;background:currentColor}
#phone .ph-tile.busy .ph-st,#phone .ph-tile.compacting .ph-st{color:var(--green)}
#phone .ph-tile.waiting .ph-st{color:var(--amber)}
#phone .ph-tile .ph-name{font-size:14px;padding:0 2px}
#phone .ph-tile .ph-role{font-size:12px;padding:0 2px}
#phone .ph-tile .ph-un{position:absolute;right:6px;top:6px}
#phone .ph-grid.bench .ph-tile{align-items:center;font-size:12px;color:var(--mute)}
#phone .ph-tile.off .ph-por > .fr,#phone .ph-grid.bench .ph-por > .fr{border-style:dashed;border-color:var(--faint)}
#phone .ph-hint{font-size:12px;color:var(--mute);text-align:center}
#phone .ph-empty{padding:30px 10px;text-align:center;color:var(--mute)}
#phone .ph-pane{flex:1;min-height:0;display:flex;flex-direction:column}
#phone .ph-body[data-tab=mix]{padding:8px;overflow:hidden}
#phone .ph-pane .teamlog .thead.phmix{padding-right:48px}
#phone .ph-pane .thead .phmixmore{position:absolute;top:4px;right:4px;width:40px;height:40px;min-width:0;padding:0;border-radius:20px;color:var(--text)}
#phone .ph-pane .thead .phmixmore svg{width:22px;height:22px}
#phone .ph-pane .thead .phmixmore.some::after{content:"";position:absolute;top:8px;right:8px;width:7px;height:7px;border-radius:4px;background:var(--amber)}
#phone .ph-pane .thead .phmixmore:active{background:var(--on)}
#phone :is(.ph-row,.ph-wait),html.phone #drail .phf,#phone .teamlog .cnames .name{-webkit-touch-callout:none;-webkit-user-select:none;user-select:none}
/* on the phone every menu (an agent's card, a filter's choices) is a sheet from the bottom, over a dimmed page; it
   closes on a tap on the page or pulled down (owner, 2026-11-08) */
#phmenuback{display:none}
html.phone #phmenuback.on{display:block;position:fixed;inset:0;z-index:59;background:#0007}
html.phone #menu.on{left:0 !important;right:0;top:auto !important;bottom:0;width:auto !important;min-width:0;max-height:85vh;overflow-y:auto;overscroll-behavior:contain;
  box-sizing:border-box;padding:22px 12px calc(16px + env(safe-area-inset-bottom));border-width:1px 0 0;border-radius:20px 20px 0 0;box-shadow:0 -10px 30px #0004;
  font-size:15px;animation:phup .22s cubic-bezier(.2,.8,.2,1)}
html.phone #menu.on::before{content:"";position:absolute;top:8px;left:calc(50% - 20px);width:40px;height:5px;border-radius:3px;background:var(--line2)}
html.phone #menu .mi{min-height:48px;padding:0 10px;font-size:15px;border-radius:10px}
html.phone #menu .mi svg{width:18px;height:18px}
html.phone #menu .hd{padding:6px 10px 10px;font-size:13px}
html.phone #menu .hd.sec{margin-top:8px}
html.phone #menu kbd{display:none}
html.phone #menu .mpor{width:96px;height:96px}
/* a tap on the menu's portrait shows it over the sheet, not grown inside it: the sheet scrolls, so it clipped a portrait
   grown up from a short sheet, a stopped agent's (owner, 2026-11-09: "Stopped agents don't expand their image correctly") */
html.phone #menu .mpor:hover img{transform:none;box-shadow:none}
#phpor{position:fixed;inset:0;z-index:70;display:flex;align-items:center;justify-content:center;background:#000b}
#phpor img{width:min(84vw,420px);aspect-ratio:1;object-fit:cover;border-radius:16px;box-shadow:0 12px 40px #000a}
@keyframes phup{from{transform:translateY(100%)}}
#phone .ph-pane .teamlog{flex:1;min-height:0;border-radius:14px;display:flex;flex-direction:column}
#phone .ph-pane .teamlog .feed{flex:1;min-height:0;overflow-y:auto;-webkit-overflow-scrolling:touch}
#phone .ph-pane .teamlog .thead{flex-wrap:wrap;row-gap:4px}
#phone .ph-pane .cnames{flex-wrap:wrap;white-space:normal;overflow:visible}
#phone .ph-nav span{white-space:nowrap}
#phone .ph-nav{flex:none;display:grid;grid-template-columns:repeat(4,minmax(0,1fr));height:62px;border-top:1px solid var(--line2);background:var(--card1);padding-bottom:env(safe-area-inset-bottom)}
#phone .ph-nav button{border:0;background:none;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:3px;font-size:11px;color:var(--mute);cursor:pointer;position:relative}
#phone .ph-nav button.on{color:var(--text);font-weight:600}
#phone .ph-nav svg{width:22px;height:22px}
#phone .ph-dash{padding:12px}
#phone .ph-dash .dhead{display:flex;align-items:center;justify-content:space-between;margin:0 2px 10px}
#phone .ph-dash .dbtn,#phone .ph-dash .dedit button,#phone .ph-dash .dadd button{height:32px;padding:0 12px;border:1px solid var(--line2);border-radius:16px;background:none;color:var(--text);font:inherit;cursor:pointer}
#phone .ph-dash .dgrip{display:inline-grid;place-items:center;width:26px;height:26px;margin:-6px 4px -6px -8px;vertical-align:middle;color:var(--mute);cursor:grab;touch-action:none}
#phone .ph-dash .dtile.moving{border-color:var(--text);box-shadow:0 6px 18px #0006;position:relative;z-index:1}
#phone .ph-dash .dtile.moving .dgrip{cursor:grabbing}
#phone.dashedit .ph-top,#phone.dashedit .ph-nav{display:none}
#phone .ph-dash .dtune.dclose{position:fixed;top:calc(10px + env(safe-area-inset-top));right:10px;z-index:5;width:40px;height:40px}
#phone .ph-dash .dtally{display:flex;align-items:center;gap:6px}
#phone .ph-dash .dtally i{width:9px;height:9px;border-radius:50%;background:var(--faint)}
#phone .ph-dash .dtally b + i{margin-left:6px}
#phone .ph-dash .dtally span{margin-left:8px;font-size:.8em}
/* a row of portraits on one line: with more than fit, each gives up its width and they overlap, the last whole */
#phone .ph-dash .dfaces{display:flex;gap:6px;margin-top:8px}
#phone .ph-dash .dface{display:flex;flex:0 1 44px;min-width:0;padding:0;border:0;background:none;color:var(--text);cursor:pointer}
#phone .ph-dash .dface:last-child{flex:none}
#phone .ph-dash .dface .ph-por{width:44px;height:44px}
#phone .gico{display:inline-flex;color:var(--mute)}
#phone .gico svg{width:18px;height:18px}
#phone .ph-dash .dtune{display:grid;place-items:center;width:38px;padding:0;border:0}
#phone .ph-dash .dgrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
#phone .ph-dash .dtile{min-width:0;padding:10px 12px;border:1px solid var(--line2);border-radius:12px;background:var(--card1)}
#phone .ph-dash .dtile.wide{grid-column:span 2}
#phone .ph-dash .dlab{color:var(--mute);font-size:.8em;font-weight:650;letter-spacing:.06em;text-transform:uppercase;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#phone .ph-dash .dval{margin-top:4px;font-size:1.25em;font-weight:650;font-variant-numeric:tabular-nums;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#phone .ph-dash .dval > * + *{margin-left:6px}
#phone .ph-dash .dmeter{position:relative;height:6px;margin-top:8px;border-radius:3px;background:var(--track);overflow:hidden}
#phone .ph-dash .dmeter i{position:absolute;inset:0 auto 0 0;border-radius:3px}
#phone .ph-dash .dmeter u{position:absolute;top:0;bottom:0;width:2px;background:var(--text)}
#phone .ph-dash .dspark{margin-top:6px;height:26px;color:var(--ownerbg)}
#phone .ph-dash .dspark svg{width:100%;height:26px}
/* outside Edit, a tile's icon sits on the line of its value or portraits, and its meter or sparkline runs the full width under them */
#phone:not(.dashedit) .ph-dash .dtile{display:grid;grid-template-columns:auto minmax(0,1fr);column-gap:10px;align-items:center}
#phone:not(.dashedit) .ph-dash .dtile > .dlab{grid-column:1;grid-row:1;display:flex}
#phone:not(.dashedit) .ph-dash .dtile > :is(.dval,.dfaces){grid-column:2;grid-row:1;margin-top:0}
#phone:not(.dashedit) .ph-dash .dtile > :is(.dmeter,.dspark){grid-column:1 / -1}
#phone .ph-dash .dedit{display:flex;flex-wrap:wrap;gap:6px;margin-top:10px}
#phone .ph-dash .dedit button{height:30px;padding:0 10px}
#phone .ph-dash .dedit .dx{display:grid;place-items:center;width:30px;padding:0;margin-left:auto}
#phone .ph-dash .dedit .dx svg{width:14px;height:14px}
#phone .ph-dash .dedit button:disabled{opacity:.35;cursor:default}
#phone .ph-dash .dadd{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin-top:14px}
#phone .ph-dash .dadd span{color:var(--mute);font-size:.8em;font-weight:650;letter-spacing:.06em;text-transform:uppercase;margin-right:2px}
#phsheet .tbhead{display:flex;align-items:center;gap:6px}
#phsheet .tbhead h2{margin:0}
#phsheet .tbback{display:grid;place-items:center;width:34px;height:34px;margin-left:-8px;border:0;background:none;color:var(--text);cursor:pointer}
#phsheet .tbback svg{transform:scaleX(-1)}
#phsheet .tblist{display:flex;flex-direction:column;gap:8px}
#phsheet .tbrow{display:flex;align-items:center;gap:10px;height:48px;padding:0 6px 0 4px;border:1px solid var(--line2);border-radius:12px;background:var(--box)}
#phsheet .tbrow.moving{border-color:var(--text);box-shadow:0 6px 18px #0006;position:relative;z-index:1}
#phsheet .tbrow > svg{width:20px;height:20px;flex:none}
#phsheet .tbrow .tbname{flex:1;font-weight:600}
#phsheet .tbrow .tbnum{width:12px;color:var(--mute);font-size:.85em;text-align:center;font-variant-numeric:tabular-nums}
#phsheet .tbsheet h3{margin:4px 2px -8px;color:var(--mute);font-size:11px;font-weight:650;letter-spacing:.08em}
#phsheet .tbprev{display:grid;padding:8px 4px;border:1px solid var(--line2);border-radius:14px;background:var(--card1)}
#phsheet .tbprev span{display:flex;flex-direction:column;align-items:center;gap:3px;color:var(--mute);min-width:0}
#phsheet .tbprev span.on{color:var(--text)}
#phsheet .tbprev svg{width:20px;height:20px}
#phsheet .tbprev small{font-size:10.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}
#phsheet .tbgrip{display:grid;place-items:center;width:36px;height:44px;color:var(--mute);cursor:grab;touch-action:none}
#phsheet .tbrow.moving .tbgrip{cursor:grabbing}
#phsheet .tbrow button{display:grid;place-items:center;width:36px;height:34px;padding:0;border:0;background:none;color:var(--mute);cursor:pointer}
#phsheet .tbrow button:disabled{opacity:.3;cursor:default}
#phsheet .tbrow button svg{width:14px;height:14px}
#phsheet .tbopts{display:flex;flex-wrap:wrap;gap:8px}
#phsheet .tbopts button{display:flex;align-items:center;gap:6px;height:36px;padding:0 14px 0 10px;border:1px dashed var(--faint);border-radius:18px;background:none;color:var(--mute);font:inherit;cursor:pointer}
#phsheet .tbopts button:disabled{opacity:.4;cursor:default}
#phsheet .tbopts svg{width:16px;height:16px}
@keyframes phslidein{from{transform:translateX(100%);opacity:.4}to{transform:none;opacity:1}}
@keyframes phslideback{from{transform:translateX(-30%);opacity:.4}to{transform:none;opacity:1}}
#phsheet .sh.slidein{animation:phslidein .24s cubic-bezier(.2,.8,.2,1)}
#phsheet .sh.slideback{animation:phslideback .24s cubic-bezier(.2,.8,.2,1)}
#phone .ph-nav .unseen{position:absolute;top:6px;left:calc(50% + 6px)}
/* the team menu, a sheet from the bottom */
#phsheet{position:fixed;inset:0;z-index:30;display:none;flex-direction:column;justify-content:flex-end;background:#0007}
#phsheet.on{display:flex}
#phsheet .sh{display:flex;flex-direction:column;gap:16px;max-height:88vh;overflow-y:auto;padding:10px 16px calc(22px + env(safe-area-inset-bottom));border-radius:20px 20px 0 0;background:var(--box);color:var(--text);font:15px var(--sans);box-shadow:0 -10px 30px #0004}
#phsheet{transition:background .2s}
#phsheet .sh{transition:transform .22s cubic-bezier(.2,.8,.2,1);overscroll-behavior:contain}
#phsheet.closing{background:#0000;pointer-events:none}
#phsheet .grab{align-self:center;width:40px;height:5px;border-radius:3px;background:var(--line2);box-sizing:content-box;padding:8px 40px 10px;margin:-8px 0 -10px;background-clip:content-box;cursor:grab;touch-action:none}
#phsheet select{flex:none;max-width:55%;height:40px;padding:0 10px;border-radius:10px;border:1px solid var(--line2);background:var(--card1);color:var(--text);font:500 14px var(--sans)}
#phsheet h2{margin:0;font-size:12px;font-weight:600;letter-spacing:.08em;color:var(--mute)}
#phsheet .tstate{display:flex;align-items:center;gap:8px}
#phsheet .tstate i{width:10px;height:10px;border-radius:5px;background:var(--faint)}
#phsheet .two{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
#phsheet .big{height:52px;border-radius:12px;border:1.5px solid var(--line2);background:var(--card1);display:flex;align-items:center;justify-content:center;gap:10px;font:600 15px var(--sans);color:var(--text);cursor:pointer}
#phsheet .big svg{width:18px;height:18px}
#phsheet .big.go{border-color:var(--green);color:var(--green)}
#phsheet .big.warn{border-color:color-mix(in srgb,var(--red) 50%,transparent);color:var(--red);background:color-mix(in srgb,var(--red) 7%,var(--card1))}
#phsheet .big.sure{background:var(--red);color:#fff;border-color:var(--red)}
#phsheet .big[disabled]{opacity:.5;cursor:default}
#phsheet .note{font-size:13px;color:var(--mute)}
#phsheet .rows{display:flex;flex-direction:column;border-top:1px solid var(--line)}
#phsheet .r{display:flex;align-items:center;gap:12px;min-height:56px;border:0;border-bottom:1px solid var(--line);background:none;color:var(--text);font:600 15px var(--sans);text-align:left;padding:0;cursor:pointer;width:100%}
#phsheet .r:last-child{border-bottom:0}
#phsheet .r > span{flex:1;display:flex;flex-direction:column}
#phsheet .r small{font-weight:400;font-size:13px;color:var(--mute)}
#phsheet .r em{font-style:normal;font-weight:400;color:var(--mute)}
#phsheet .sw{flex:none;width:52px;height:32px;border-radius:16px;background:var(--line2);position:relative;transition:background .15s}
#phsheet .sw:after{content:"";position:absolute;top:3px;left:3px;width:26px;height:26px;border-radius:13px;background:#fff;box-shadow:0 1px 3px #0003;transition:left .15s}
#phsheet .sw.on{background:var(--green)}
#phsheet .sw.on:after{left:23px}
#phsheet .seg2{display:grid;grid-template-columns:1fr 1fr;padding:3px;border-radius:12px;background:var(--track)}
#phsheet .seg2 button{height:38px;padding:0 16px;border:0;border-radius:9px;background:none;font:500 14px var(--sans);color:var(--mute);cursor:pointer}
#phsheet .seg2 button.on{background:var(--card1);color:var(--text);font-weight:600;box-shadow:0 1px 2px #0002}
/* the agent view on the phone: a back arrow, its name and menus, one line of facts, the others' portraits to swipe
   along, the conversation, a suggested prompt to tap, the box, and Stop on a row of its own, away from Send */
html.phone #detail .head{flex-wrap:wrap;gap:0 4px;padding:4px 4px 0;border-top-width:3px}
html.phone #detail .head .x{order:-1;margin:0;width:44px;height:44px;display:grid;place-items:center;color:var(--text)}
html.phone #detail .head .x svg{width:22px;height:22px}
html.phone #detail .head :is(.lanes,#dmore){width:44px;height:44px;display:grid;place-items:center;margin-left:0}
/* the filter and the ⋯ at the right (owner, 2026-11-09); the rule above, through :is(#dmore), outranked a plain .lanes rule */
html.phone #detail #dhead .lanes.fbtn{margin-left:auto}
html.phone #detail #dhead #dmore svg{width:22px;height:22px}   /* the ⋯ at the standard size, as the team menu's */
html.phone #detail .head .ticket{min-width:0;overflow:hidden;text-overflow:ellipsis}
html.phone #detail .head .role{min-width:0;overflow:hidden;text-overflow:ellipsis;flex:0 1 auto}
html.phone #detail .head .facts{display:flex;order:10;flex:1 1 100%;height:32px;margin:4px -4px 0;padding:0 14px;align-items:center;gap:14px;flex-wrap:nowrap;overflow-x:auto;
  background:var(--codebg);border-top:1px solid var(--line);scrollbar-width:none}
html.phone #detail .head .facts > :last-child{display:none}
html.phone #detail .box{grid-template-rows:auto auto minmax(0,1fr) !important}
html.phone #detail .box .rail{display:flex !important;grid-column:1;grid-row:2 !important;gap:10px;padding:8px 12px;overflow-x:auto;overflow-y:hidden;border:0;border-bottom:1px solid var(--line);scrollbar-width:none}
html.phone #detail .box .left{grid-row:3 !important}
html.phone :is(#drail, #detail .head .facts){cursor:grab}
html.phone .sheetdrag{cursor:grab}   /* a sheet drags down to close under a mouse too */
html.phone .sheetdrag :is(button, a, select, label, [data-go], [data-act], [data-open], .mi){cursor:pointer}
html.phone .sheetdrag.grabbing, html.phone .sheetdrag.grabbing *{cursor:grabbing;user-select:none}
html.phone :is(#drail, #detail .head .facts).grabbing{cursor:grabbing;user-select:none}
html.phone #drail .phf{position:relative;flex:none;width:48px;height:48px;padding:0;border:0;border-radius:14px;background:none;cursor:pointer}
html.phone #drail .phf > span:not(.unseen){display:block;width:100%;height:100%;box-sizing:border-box;border-radius:14px;border:2.5px solid var(--c);overflow:hidden;background:var(--chtile)}
html.phone #drail .phf img,html.phone #drail .phf svg{display:block;width:100%;height:100%;object-fit:cover}
html.phone #drail .phf i{position:absolute;right:-3px;bottom:-3px;width:12px;height:12px;border-radius:6px;border:2px solid var(--box);background:var(--faint)}
html.phone #drail .phf.busy i,html.phone #drail .phf.compacting i{background:var(--green)}
html.phone #drail .phf.waiting i{background:var(--amber)}
html.phone #drail .phf.cur{box-shadow:0 0 0 2px var(--box),0 0 0 4.5px var(--text)}
html.phone #drail .phf .unseen{position:absolute;top:-4px;right:-4px}   /* the frame's rule is the portrait span's alone: the badge, a span too, once took it and covered the face (owner, 2026-11-09) */
html.phone #drail .phf .unseen[hidden]{display:none}
#dsug{display:none}
html.phone #dsug:not([hidden]){display:block;align-self:flex-start;max-width:calc(100% - 28px);margin:0 14px 8px;height:36px;padding:0 12px;border-radius:18px;border:1px solid var(--line2);
  background:var(--soft);color:var(--text2);font:500 13px var(--sans);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;cursor:pointer}
html.phone #detail .sayrow{flex-wrap:nowrap;align-items:flex-start;margin:0 12px 12px !important;gap:8px}
html.phone #detail .sayrow .add{width:44px;height:44px;border-radius:12px}
html.phone #detail .sayrow .say{min-height:44px !important;padding:11px 46px 11px 14px;border-radius:22px}
html.phone #detail .sayrow .send{width:44px;height:44px;margin:0 0 0 calc(-8px - 44px);align-self:flex-end}
html.phone #dstop{flex:none;width:44px;height:44px;align-self:flex-start;border-radius:12px;
  border-color:color-mix(in srgb,var(--red) 45%,transparent);background:color-mix(in srgb,var(--red) 7%,var(--box))}
html.phone #dstop::before{width:13px;height:13px;border-radius:3px;background:var(--red)}
html.phone #dstop[style*="none"]{display:none}
/* + and stop sit level with the box's top as it grows; send stays at its bottom right (owner, 2026-11-09) */
#pherr{position:fixed;left:10px;right:10px;top:10px;z-index:100;display:flex;flex-direction:column;gap:8px;padding:12px;border-radius:12px;border:2px solid var(--red);background:var(--box);color:var(--text);font:13px var(--sans);box-shadow:0 8px 30px #0005}
#pherr pre{margin:0;max-height:30vh;overflow:auto;white-space:pre-wrap;word-break:break-all;font:11px/1.4 var(--mono);color:var(--mute)}
#pherr div{display:flex;gap:8px}#pherr button{flex:1;height:44px;border-radius:10px;border:1px solid var(--line2);background:var(--card1);color:var(--text);font:600 14px var(--sans)}
#phoneback{position:fixed;left:10px;bottom:10px;z-index:15;height:40px;padding:0 14px;border-radius:20px;border:1px solid var(--line2);background:var(--box);color:var(--text);font:600 13px var(--sans);box-shadow:0 4px 14px #0003}
html.phoneoff #phoneback{display:block}
#phoneback{touch-action:none;user-select:none;-webkit-user-select:none;cursor:grab}
#phoneback.moving{cursor:grabbing;opacity:.85}
#phone .ph-logo{flex:none;width:44px;height:44px;margin-left:-8px;display:grid;place-items:center}
#phone .ph-logo svg{width:36px;height:36px}
</style>
</head>
<body>
<header>
  <div class="bi" data-item="brand"><div class="brand" title="Claude agents"><svg class="dk" width="40" height="40" aria-label="Agent hub" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><g stroke="#5EEAD4" stroke-width="6" stroke-linecap="round" opacity="0.5"><line x1="100" y1="100" x2="50" y2="50"/><line x1="100" y1="100" x2="141.5" y2="58.5"/><line x1="100" y1="100" x2="50" y2="150"/><line x1="100" y1="100" x2="150" y2="150"/></g><circle cx="50" cy="50" r="15" fill="#5EEAD4"/><circle cx="150" cy="50" r="12" fill="none" stroke="#5EEAD4" stroke-width="6"/><circle cx="50" cy="150" r="15" fill="#5EEAD4"/><circle cx="150" cy="150" r="15" fill="#5EEAD4"/><circle cx="100" cy="100" r="36" fill="#F4F4F0"/><path d="M85 87 L98 100 L85 113" fill="none" stroke="#12161C" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/><line x1="103" y1="114" x2="117" y2="114" stroke="#12161C" stroke-width="8" stroke-linecap="round"/></svg><svg class="lt" width="40" height="40" aria-label="Agent hub" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><g stroke="#0D9488" stroke-width="6" stroke-linecap="round" opacity="0.5"><line x1="100" y1="100" x2="50" y2="50"/><line x1="100" y1="100" x2="141.5" y2="58.5"/><line x1="100" y1="100" x2="50" y2="150"/><line x1="100" y1="100" x2="150" y2="150"/></g><circle cx="50" cy="50" r="15" fill="#0D9488"/><circle cx="150" cy="50" r="12" fill="none" stroke="#0D9488" stroke-width="6"/><circle cx="50" cy="150" r="15" fill="#0D9488"/><circle cx="150" cy="150" r="15" fill="#0D9488"/><circle cx="100" cy="100" r="36" fill="#12161C"/><path d="M85 87 L98 100 L85 113" fill="none" stroke="#F4F4F0" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/><line x1="103" y1="114" x2="117" y2="114" stroke="#F4F4F0" stroke-width="8" stroke-linecap="round"/></svg></div></div>
  <div class="bi" data-item="tally"><div class="counts" id="counts"></div><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi" data-item="bench"><div class="bench" id="bench"></div><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi" data-item="favs"><div class="bench favs" id="favs"></div><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi" data-item="active"><div class="bench favs" id="active"></div><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="controls"><span id="teamctl"></span><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="lanes"><span id="pagelanes"></span><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="view"><span id="pagemode"></span><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="lock"><b class="fbtn" id="lock"></b></div>
  <div class="bi tight" data-item="theme"><span class="pill btn" id="theme" title="The theme"></span><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="settings"><b class="fbtn" id="settings" data-menu="settings" title="Settings"><svg viewBox="0 0 16 16" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><path d="M13.16 6.40 L14.90 6.82 L14.90 9.18 L13.16 9.60 L12.78 10.52 L13.72 12.04 L12.04 13.72 L10.52 12.78 L9.60 13.16 L9.18 14.90 L6.82 14.90 L6.40 13.16 L5.48 12.78 L3.96 13.72 L2.28 12.04 L3.22 10.52 L2.84 9.60 L1.10 9.18 L1.10 6.82 L2.84 6.40 L3.22 5.48 L2.28 3.96 L3.96 2.28 L5.48 3.22 L6.40 2.84 L6.82 1.10 L9.18 1.10 L9.60 2.84 L10.52 3.22 L12.04 2.28 L13.72 3.96 L12.78 5.48 Z"/><circle cx="8" cy="8" r="2.2"/></svg></b><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="help"><b class="fbtn" id="help" data-menu="help" title="Keyboard shortcuts (?)">?</b><i class="bx" title="Take this out of the bar">✕</i></div>
</header>
<main id="main"></main>
<footer></footer>
<div id="phone"><div class="ph-loading">Loading…</div></div><button id="phoneback">Phone layout</button>
<div id="barbin" hidden><div class="bi tight" data-item="viewbar"><span id="viewbar"></span><i class="bx" title="Take this out of the bar">✕</i></div></div>
<div id="pop"></div><div id="menu"></div><div id="copied">Copied</div>
<div id="lightbox"><figure><div id="lbwrap"><img id="lbimg" alt="" draggable="false"></div><figcaption><span id="lbname"></span><span class="zoom"><b id="lbout" title="Zoom out (−)">−</b><b id="lbfit" title="Fit to the window (0)">Fit</b><b id="lbin" title="Zoom in (+)">+</b><span id="lbpct"></span></span><a id="lbtab" target="_blank" rel="noopener">Open in a new tab</a></figcaption></figure><span class="x" id="lbx" title="Close (Esc)">✕</span></div>
<div id="graphbox"><div class="doc"><div class="dochead"><span id="graphname"></span><span id="graphsum"></span><span class="seg" id="graphspan"></span><span class="x" id="graphx" title="Close (Esc)">✕</span></div><div id="graphbody"></div></div></div>
<div id="docbox"><div class="doc"><div class="dochead"><span id="docname"></span><b id="doccopy" class="di" title="Copy path"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6.8 9.2a2.8 2.8 0 0 0 4 0l2-2a2.8 2.8 0 0 0-4-4l-.9.9"/><path d="M9.2 6.8a2.8 2.8 0 0 0-4 0l-2 2a2.8 2.8 0 0 0 4 4l.9-.9"/></svg></b><b id="docall" class="di" title="Copy all" hidden><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 3.5v-1a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h1"/></svg></b><a id="docsave" class="di" title="Save as…"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M8 2v8M4.8 7 8 10.2 11.2 7M2.5 11v1.5a1.5 1.5 0 0 0 1.5 1.5h8a1.5 1.5 0 0 0 1.5-1.5V11"/></svg></a><a id="doctab" class="di" title="Open as text" target="_blank" rel="noopener"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M9 2h5v5M14 2 7.5 8.5M12 9.5V13a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h3.5"/></svg></a><span class="x" id="docx" title="Close (Esc)">✕</span></div><div id="docbody"></div></div></div>
<div id="detail"><div class="box"><div class="head" id="dhead"></div><div class="left"><div class="conv" id="dconv"></div><button id="dbottom" title="Back to the newest turn">↓ Newest</button><div class="att" id="datt"></div><button id="dsug" hidden></button><div class="sayrow" id="dsayrow"><button class="add" id="dadd" title="Add images or files (Ctrl+U)"></button><textarea class="say" id="dsay" rows="1" autocomplete="off"></textarea><button class="send" title="Send (Enter)"></button><button class="stop" id="dstop" title="Stop this turn, as Esc does in the terminal"></button></div><div class="termwrap" id="dterm" title="Expand"><div class="term"><div class="bar"><i></i><i></i><i></i><span id="dtitle"></span><b id="dzoom">⤢</b></div><div class="screen" id="dscr"><pre id="dscreen"></pre></div></div><span class="x" id="dtx" title="Close (Esc)">✕</span></div></div><div class="rail" id="drail"></div></div></div>
<script>
const $ = s => document.querySelector(s);
const ONLY = new URLSearchParams(location.search).has("only");
if (ONLY) document.documentElement.classList.add("only");
// Light or dark, remembered in this browser; dark unless chosen.
// The favicon follows the page's theme too: the dark icon is in the page head, the light one here.
const FAVICON = {dark: document.querySelector("link[rel=icon]").href, light: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 200 200'%3E%3Crect x='1.5' y='1.5' width='197' height='197' rx='39' fill='%23F4F4F0' stroke='%23D6D6CF' stroke-width='3'/%3E%3Ccircle cx='52' cy='52' r='28' fill='%230D9488'/%3E%3Ccircle cx='148' cy='52' r='28' fill='%230D9488'/%3E%3Ccircle cx='52' cy='148' r='28' fill='%230D9488'/%3E%3Ccircle cx='148' cy='148' r='28' fill='%230D9488'/%3E%3Ccircle cx='100' cy='100' r='40' fill='%2312161C'/%3E%3C/svg%3E"};
// The page's theme, kept in this browser: Dark, Light, or Custom (owner, 2026-11-05: "the 3rd theme option is just
// 'custom' and then you set your colours"), the theme editor's: the page's colours, each gauge's and each agent's,
// over a light or dark base, which sets the text on agents' colours, the logo and the browser's own controls.
const THEMES = ["dark", "light", "custom"], THEME_NAME = {dark: "☾ Dark", light: "☀ Light", custom: "◐ Custom"};
// The colours the editor sets; the page's other tokens follow from them (themeTokens).
const PAGE_COLOURS = [["bg", "Page"], ["section", "Panels"], ["card", "Cards"], ["text", "Text"], ["mute", "Muted text"],
  ["line", "Lines"], ["green", "Good"], ["amber", "Warning"], ["red", "Bad"], ["cyan", "Accent"]];
// Where the editor starts from: the page's own two themes, and a warm light one, cream where Light is white.
const THEME_PRESETS = {
  dark: {base: "dark", page: {bg: "#07090d", section: "#0b0f15", card: "#161b22", text: "#e6edf3", mute: "#8b949e", line: "#262c35",
    green: "#3fb950", amber: "#e3b341", red: "#f85149", cyan: "#39c5cf"}},
  light: {base: "light", page: {bg: "#f3f5f8", section: "#fbfbfc", card: "#ffffff", text: "#1f2328", mute: "#59636e", line: "#e3e6ea",
    green: "#1a7f37", amber: "#d29a00", red: "#cf222e", cyan: "#0969da"}},
  warm: {base: "light", page: {bg: "#efe8dc", section: "#f6f0e6", card: "#fbf7f0", text: "#2b2620", mute: "#6f655a", line: "#e0d5c4",
    green: "#3f7f3a", amber: "#b7791f", red: "#b5402f", cyan: "#2f7d86"}},
};
const themeNow = () => { const t = localStorage.getItem("theme"); return THEMES.includes(t) ? t : "dark"; };
// The custom theme as saved, Warm light until it is first changed; a gauge, role or agent it does not name keeps its own
// colour.
function customTheme() {
  let c = null;
  try { c = JSON.parse(localStorage.getItem("customTheme") || "null"); } catch (e) {}
  const from = THEME_PRESETS[c?.base === "dark" ? "dark" : "warm"];
  return {base: from.base, page: {...from.page, ...c?.page}, perf: {...c?.perf}, roles: {...c?.roles}, agents: {...c?.agents}};
}
const mixed = (a, b, pct) => `color-mix(in srgb, ${a} ${pct}%, ${b})`;
const themeTokens = p => ({"--bg": p.bg, "--section": p.section, "--panel": p.section, "--chpanel": p.section,
  "--card1": p.card, "--card2": mixed(p.card, p.bg, 92), "--box": p.card, "--soft": p.card, "--chtile": p.card,
  "--text": p.text, "--text2": mixed(p.text, p.card, 85), "--mute": p.mute, "--chmute": p.mute, "--faint": mixed(p.mute, p.section, 60),
  "--line": p.line, "--line2": mixed(p.line, p.text, 82), "--track": p.line, "--on": mixed(p.line, p.text, 75),
  "--hover": mixed(p.text, "transparent", 30), "--codebg": mixed(p.text, "transparent", 7), "--thumb": mixed(p.text, "transparent", 14),
  "--glow1": "transparent", "--glow2": "transparent", "--green": p.green, "--amber": p.amber, "--red": p.red, "--cyan": p.cyan, "--chhigh": p.amber});
function theme(t) {
  if (!THEMES.includes(t)) t = "dark";
  const c = t === "custom" && customTheme(), base = c ? c.base : t, root = document.documentElement, tokens = c ? themeTokens(c.page) : {};
  root.classList.toggle("light", base === "light");
  for (const k of Object.keys(themeTokens(THEME_PRESETS.dark.page))) tokens[k] ? root.style.setProperty(k, tokens[k]) : root.style.removeProperty(k);
  document.querySelector("link[rel=icon]").href = FAVICON[base] || FAVICON.dark;
  localStorage.setItem("theme", t);
  // the pill names the theme showing, and a rest on it the one a click moves to
  $("#theme").textContent = THEME_NAME[t]; $("#theme").title = "Click for " + THEME_NAME[THEMES[(THEMES.indexOf(t) + 1) % THEMES.length]].slice(2);
}
theme(new URLSearchParams(location.search).get("theme") || localStorage.getItem("theme") || "dark");
// a theme changed after the page has drawn: the agents' and gauges' colours are drawn into the page, so it is drawn again
function retheme(t) { theme(t); if (S) { paintAgents(); draw(); } }
$("#theme").onclick = () => retheme(THEMES[(THEMES.indexOf(themeNow()) + 1) % THEMES.length]);
// a theme chosen, or the custom one edited, in another of this browser's tabs of the page is shown in this one too
addEventListener("storage", e => { if (e.key === "theme" || e.key === "customTheme") retheme(themeNow()); });
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
// How the page writes an agent's name: the roster's spelling unless the server says otherwise. Attributes that name
// an agent for the code (data-name, data-tab) keep the roster's, as everything sent back to the server must.
const shown = name => S?.shownNames?.[name] || name;
// The little Markdown agents write: ``` fenced blocks, tables, # headings, - bullets, `code` and **bold**; web
// addresses become links, and so do full paths to documents the page can show (DOC_TYPES on the server).
const DOC = /(^|[\s(>])((?:~|\/home|\/tmp\/claude-\d+)\/[^\s<>"'`()]+\.(?:md|markdown|txt|sql|log))(?=$|[\s<).,;:!?])/gim;
// A name in an agent's words reads as the page spells it, on the page only: the words stored and sent are untouched,
// and so is anything meant literally, which is `code`, a web address or a path.
const spelled = html => Object.entries(S?.shownNames || {}).reduce((out, [name, as]) =>
  out.replace(new RegExp("`[^`\\n]+`|\\bhttps?://\\S+|(?<![\\w.])[~/]\\S+|\\b" + name + "\\b", "g"), hit => hit === name ? esc(as) : hit), html);
const inline = s => spelled(esc(s))
  .replace(/^(#{1,6}) +(.+)$/gm, (_, h, t) => `<b class="h h${h.length}">${t}</b>`)
  .replace(/^(\s*)[-*] +/gm, "$1• ")
  .replace(/`([^`\n]+)`/g, "<code>$1</code>")
  .replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>")
  .replace(/\bhttps?:\/\/[^\s<>"'`]*[^\s<>"'`.,;:!?)\]]/g, u => `<a class="link" href="${u}" target="_blank" rel="noopener">${u}</a>`)
  .replace(DOC, (_, pre, p) => `${pre}<a class="link" href="/doc?p=${encodeURIComponent(p)}" title="${p}" onclick="return showDoc(event, this)">${p}</a>`);
// A table is a header row, a row of dashes and its rows, each line between pipes.
const TABLE = /(^\|.*\|[ \t]*\n\|[ \t:|-]+\|[ \t]*(?:\n\|.*\|[ \t]*)*)\n?/gm;
const cells = (row, tag) => row.trim().slice(1, -1).split("|").map(c => `<${tag}>${inline(c.trim())}</${tag}>`).join("");
const table = t => { const [head, , ...rows] = t.trim().split("\n"); return `<div class="mdtable"><table class="md"><tr>${cells(head, "th")}</tr>${rows.map(r => `<tr>${cells(r, "td")}</tr>`).join("")}</table></div>`; };
const prose = s => s.split(TABLE).map((part, i) => i % 2 ? table(part) : inline(part)).join("");
// A code box copies what is in it from a button in its corner, shown while it is hovered.
const COPY = `<button class="copy" title="Copy"><svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.4"><rect x="5.5" y="5.5" width="8" height="8" rx="1.5"/><path d="M10.5 3.5v-1a1 1 0 0 0-1-1h-6a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h1"/></svg></button>`;
document.addEventListener("click", async e => {
  const b = e.target.closest("pre.code .copy");
  if (!b) return;
  e.stopPropagation(); e.preventDefault();
  await navigator.clipboard.writeText(b.parentElement.textContent);
  b.classList.add("done"); setTimeout(() => b.classList.remove("done"), 1200);
}, true);
// Text selected on the page goes straight to the clipboard and the selection is cleared, with a note by the pointer
// to say so. Text being selected in a message box is left alone, to edit.
document.addEventListener("mouseup", e => {
  if (e.button !== 0 || e.target.closest("textarea,input,select")) return;
  setTimeout(async () => {
    const sel = getSelection(), text = sel.toString();
    if (sel.isCollapsed || !text.trim() || document.activeElement?.matches("textarea,input")) return;
    try { await navigator.clipboard.writeText(text); } catch (err) { return; }
    sel.removeAllRanges();
    const note = $("#copied");
    note.style.left = Math.min(e.clientX + 12, innerWidth - 70) + "px"; note.style.top = Math.max(8, e.clientY - 28) + "px";
    note.classList.add("on"); clearTimeout(note.hide); note.hide = setTimeout(() => note.classList.remove("on"), 900);
  }, 0);
});
// A fenced block is a code box; on a card (flat) it is code-styled lines in the text instead, so the card's few-line
// cut ends on a whole line rather than slicing through a box.
// A block indented under a list item loses its fence's indent from every line, as Markdown has it, so what it shows
// and what its Copy copies start at the code's own first column; the closing fence's indent goes with it.
const unfence = (code, before) => {
  const n = /(?:^|\n)([ \t]*)$/.exec(before)?.[1].length || 0, strip = new RegExp(`^[ \\t]{0,${n}}`, "gm");
  return code.replace(/\n[ \t]*$/, "").replace(strip, "");
};
const md = (s, flat) => String(s ?? "").split(/```[^\n]*\n?/)
  .map((part, i, all) => !(i % 2) ? prose(part) : flat ? `<code class="flat">${esc(unfence(part, all[i - 1]))}</code>\n`
    : `<pre class="code">${esc(unfence(part, all[i - 1]))}${COPY}</pre>`).join("");
const ago = s => s == null ? "" : s < 60 ? s + "s" : s < 3600 ? Math.floor(s / 60) + "m" : s < 86400 ? Math.floor(s / 3600) + "h" : Math.floor(s / 86400) + "d";
const k = n => n == null ? "–" : n < 1000 ? "" + n : n < 1e6 ? (n / 1000).toFixed(n < 1e5 ? 1 : 0) + "k" : (n / 1e6).toFixed(1) + "M";
const gauge = p => p == null ? "var(--faint)" : p >= 85 ? "var(--red)" : p >= 60 ? "var(--amber)" : "var(--green)";
const STATE = {busy: "working", waiting: "waiting", wanted: "wants you", idle: "idle", shell: "in shell", off: "not running", compacting: "compacting", bench: "on the bench"};
// what an agent is doing, for its classes and words: not running, compacting, its session's own status, or - when it
// is not blocked on a prompt and has raised owner-wanted - wanting the owner
const stOf = a => !a.live ? "off" : a.compacting ? "compacting" : a.status !== "waiting" && a.wanted ? "wanted" : a.status;
// how long an agent has been in the state stOf gives it
const heldOf = a => stOf(a) === "wanted" ? a.wantedHeld : a.held;
// waiting on a prompt or wanting the owner: the agents the header's badge and Alt+W lead to, longest first
const needing = () => S.agents.filter(a => ["waiting", "wanted"].includes(stOf(a))).sort((x, y) => (heldOf(y) || 0) - (heldOf(x) || 0));
let S = null, colours = {}, paintKey = "", open = null;

function since(ts) { return ts ? ago(Math.max(0, Math.round(Date.now() / 1000 - Date.parse(ts) / 1000))) : ""; }

// One turn of a conversation. On a card (compact) blank lines are squeezed out, so its few lines go on words.
// Images a turn names by path - "/home/…/shot.png" or "~/…/shot.png" - or has pasted into it, as thumbnails under
// its text; a click opens one full size.
const IMG = /(?:^|[\s`(])((?:\/|~\/)[^\s`()'"<>]+\.(?:png|jpe?g|gif|webp)|[\w.][^\s`()'"<>:]*\.(?:png|jpe?g|gif|webp))(?=$|[\s`).,;:])/gim;
// Images pasted into a turn come by the key the server keeps them under.
// A path that names no image (an example, a file since deleted) shows nothing, and is not asked for again.
const noImage = new Set();
function lostImg(img) {
  noImage.add(img.getAttribute("src"));
  const box = img.closest(".thumbs");
  img.closest("a").remove();
  if (box && !box.children.length) box.remove();
}
function thumbs(text, keys, agent) {
  const paths = [...new Set([...String(text || "").matchAll(IMG)].map(m => m[1]))].slice(0, 8);
  const pics = [...(keys || []).map((k, i) => ["/img?k=" + k, "pasted image " + (i + 1)]),
    ...paths.map(p => ["/img?p=" + encodeURIComponent(p) + (/^[\/~]/.test(p) ? "" : "&a=" + encodeURIComponent(agent || "")), p])]
    .filter(([u]) => !noImage.has(u));
  return pics.length ? `<div class="thumbs">${pics.map(([u, name]) =>
    `<a href="${u}" target="_blank" rel="noopener" title="${esc(name)}" onclick="return showImg(event, this)"><img src="${u}" alt="${esc(name.split("/").pop())}" loading="lazy" onerror="lostImg(this)"></a>`).join("")}</div>` : "";
}
// An image opens over the page, fitted to the window; the cross, Esc or a click beside it closes it. It zooms with
// the buttons, the wheel or + / − / 0, and once larger than the window it is dragged to move around it.
let lbScale = 0;   // 0 is fitted to the window; otherwise the image's own size times this
function showImg(e, a) {
  e.preventDefault(); e.stopPropagation();
  lbScale = 0;
  $("#lbimg").onload = lbApply;
  $("#lbimg").src = a.href; $("#lbtab").href = a.href; $("#lbname").textContent = a.title;
  $("#lightbox").classList.add("on"); lbApply();
  return false;
}
const closeImg = () => $("#lightbox").classList.remove("on");
// A document opens over the page, Markdown rendered and anything else as it is; the cross, Esc or a click beside it
// closes it. Its headings are blocks with their own margins, so the blank lines around them go.
let docText = "";   // the open document as it is on disk, for Copy all
const docMd = text => md(text).replace(/\n*(<b class="h h\d">.*?<\/b>)\n*/g, "$1");
function showDoc(e, a) {
  e.preventDefault(); e.stopPropagation();
  const name = a.title;
  $("#docname").textContent = $("#docname").title = name; $("#doctab").href = a.href;
  $("#docsave").href = a.href + "&save=1"; $("#docsave").download = name.split("/").pop();
  $("#docbody").textContent = "Loading…";
  $("#docall").hidden = true;
  $("#docbox").classList.add("on");
  fetch(a.href).then(r => r.ok ? r.text() : Promise.reject(r.status)).then(
    text => { if ($("#docname").textContent === name) { docText = text; $("#docall").hidden = false; }
      return /\.(md|markdown)$/i.test(name) ? docMd(text) : `<pre class="code">${esc(text)}${COPY}</pre>`; },
    status => `<span style="color:var(--mute)">${status === 404 ? "No such document, or not one this page shows." : "Could not load it."}</span>`)
    .then(html => { if ($("#docname").textContent === name) { $("#docbody").innerHTML = html; $("#docbody").scrollTop = 0; } });
  return false;
}
const closeDoc = () => $("#docbox").classList.remove("on");
$("#docbox").onclick = e => { if (e.target.id === "docbox" || e.target.id === "docx") closeDoc(); };
// A header button copies, then reads "Copied" for a moment.
async function docCopy(b, text) {
  if (b.classList.contains("done")) return;
  await navigator.clipboard.writeText(text);
  const was = b.innerHTML, tip = b.title;   // an icon: a tick and "Copied" for a moment, then back
  b.innerHTML = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"><path d="M3 8.5 6.5 12 13 4.5"/></svg>';
  b.title = "Copied"; b.classList.add("done");
  setTimeout(() => { b.innerHTML = was; b.title = tip; b.classList.remove("done"); }, 1200);
}
$("#doccopy").onclick = e => docCopy(e.currentTarget, $("#docname").textContent);
$("#docall").onclick = e => docCopy(e.currentTarget, docText);
function lbFitScale() {
  const img = $("#lbimg");
  return img.naturalWidth ? Math.min(1, (innerWidth - 80) / img.naturalWidth, (innerHeight - 130) / img.naturalHeight) : 1;
}
function lbApply() {
  const img = $("#lbimg"), w = $("#lbwrap");
  w.classList.toggle("zoomed", !!lbScale);
  img.style.width = lbScale ? Math.round(img.naturalWidth * lbScale) + "px" : "";
  $("#lbpct").textContent = Math.round((lbScale || lbFitScale()) * 100) + "%";
}
function lbZoom(f, at) {
  const w = $("#lbwrap"), before = lbScale || lbFitScale(), r = w.getBoundingClientRect();
  const x = at ? at.clientX - r.left : w.clientWidth / 2, y = at ? at.clientY - r.top : w.clientHeight / 2;
  const fx = (w.scrollLeft + x) / before, fy = (w.scrollTop + y) / before;
  lbScale = f ? Math.max(0.05, Math.min(8, before * f)) : 0;
  lbApply();
  if (lbScale) { const now = lbScale; w.scrollLeft = fx * now - x; w.scrollTop = fy * now - y; }
}
$("#lbin").onclick = () => lbZoom(1.25); $("#lbout").onclick = () => lbZoom(0.8); $("#lbfit").onclick = () => lbZoom(0);
$("#lbwrap").addEventListener("wheel", e => { e.preventDefault(); lbZoom(e.deltaY < 0 ? 1.15 : 1 / 1.15, e); }, {passive: false});
$("#lbwrap").onpointerdown = e => {
  const w = $("#lbwrap"); if (!lbScale) return;
  e.preventDefault(); w.setPointerCapture(e.pointerId); w.classList.add("grab");
  const sx = e.clientX + w.scrollLeft, sy = e.clientY + w.scrollTop;
  w.onpointermove = m => { w.scrollLeft = sx - m.clientX; w.scrollTop = sy - m.clientY; };
  w.onpointerup = () => { w.onpointermove = null; w.classList.remove("grab"); };
};
$("#lightbox").onclick = e => { if (e.target.id === "lightbox" || e.target.tagName === "FIGURE" || e.target.id === "lbx") closeImg(); };
addEventListener("keydown", e => {
  if (!$("#lightbox").classList.contains("on")) return;
  if (e.key === "+" || e.key === "=") lbZoom(1.25); else if (e.key === "-") lbZoom(0.8); else if (e.key === "0") lbZoom(0);
});

// With tag, the item names the agent it came from (a pane mixing several agents): before it, or after the owner's
// words and another agent's message to it, as "→ agent".
function item(it, compact, agent, tag) {
  if (it.kind === "live" && stopping[agent]) it = {...it, text: "Stopping…"};
  const ag = to => tag ? (it._agents || [agent]).map(x => `<span class="who ag${to ? " to" : ""}" style="--pc:${colours[x] || "#888"}">${esc(shown(x))}</span>`).join("") : "";
  if (it.kind === "tools") {
    // on a card, one line run together; in a conversation shown whole, a line for each call
    const t = compact ? "⚙ " + it.calls.map(c => `<b>${esc(c.who)}</b> ${esc(c.text)}`).join(" · ")
      : it.calls.map((c, i) => `<span class="call">${i ? "" : "⚙ "}<b>${esc(c.who)}</b> ${esc(c.text)}</span>`).join("");
    const c = colours[it.with], pc = c ? ` style="--pc:${c}"` : "";
    return `<div class="it tools l-${it.lane}"${pc}${tag ? ` data-agent="${esc(agent)}"` : ""}>${ag(false)}<span class="tx">${t}</span><span class="ago" data-ts="${esc(it.ts || "")}">${since(it.ts)}</span></div>`;
  }
  // a message of the owner's still queued behind the agent's turn, which can be taken back out to edit
  if (it.kind === "echo") {
    return `<div class="it owner pending echo"><span class="who">${esc(S.owner || "Owner")}</span>${ag(true)}<span class="tx">${md(it.text, compact === true)}</span><span class="badge" title="Sent from this page; it shows as the agent's own turn once its transcript has it">${it.state}</span></div>`;
  }
  if (it.kind === "pending") {
    return `<div class="it owner pending"><span class="who">${esc(S.owner || "Owner")}</span><span class="tx">${md(it.text, compact === true)}</span><span class="badge" title="Queued: the agent reads it when its turn allows">pending</span></div>`;
  }
  // the agent's own words carry its name, as the owner's carry theirs
  const who = it.kind === "said" ? agent || "" : it.who;
  const c = colours[it.kind === "said" ? agent : it.with || it.who], pc = c ? ` style="--pc:${c}"` : "";
  const pics = thumbs(it.text, it.images, agent), own = who ? `<span class="who">${esc(shown(who))}</span>` : "";
  const heads = it.kind === "said" ? own : ["owner", "shell", "peer"].includes(it.kind) ? own + ag(true) : ag(false) + own;
  // the badges open the text's first line, and its later lines run the full width beneath them (not a live line's)
  const inline = !!heads && it.kind !== "live";
  return `<div class="it ${it.kind}${it.kind === "ask" || it.kind === "live" ? "" : " l-" + it.lane}${pics ? " pics" : ""}"${pc}${tag ? ` data-agent="${esc(agent)}"` : ""}>${inline ? "" : heads}<span class="tx">${inline ? `<span class="heads">${heads}</span>` : ""}${compact === true ? md(it.text.replace(/\n\s*\n+/g, "\n"), true) : md(it.text)}</span>${it.kind === "ask" ? askButtons(it, agent) : ""}<span class="ago" data-ts="${esc(it.ts || "")}">${since(it.ts)}</span>${pics}</div>`;
}
// An open prompt's options in the order shown, one under another, each naming its option by number and label so that it
// answers only the prompt it was drawn for: a button for each, and for a Type something option a box to write the answer
// in, sent with Enter or its ↵. As in the terminal, one option is highlighted (❯): ↑ and ↓ move it, Enter chooses it, and
// a digit chooses its option at once. The server's reply to the last answer shows beside them
// for a while.
let askReply = {name: "", text: "", at: 0};
// What is written in each Type something box, by agent and option, so that a redraw, which may replace the box, draws
// it again with its text; askFocus is the box being written in, with its caret, for a replaced box to take the focus back.
const askTyped = {};
let askFocus = null;
const askKey = (agent, n) => agent + "\n" + n;
// The highlighted option of each agent's prompt, kept across redraws for as long as that prompt is the one open; a new
// prompt starts where its pane's cursor is, else on its first option.
const askSel = {};
const askAt = (it, agent) => {
  const id = it.text + "\n" + (it.options || []).map(o => o.label).join("\n");
  if (askSel[agent]?.id !== id) askSel[agent] = {id, at: it.cursor || 1};
  return askSel[agent].at;
};
const askButtons = (it, agent) => {
  const opts = it.options || [], at = askAt(it, agent), on = o => o.n === at ? " at" : "", reply = askReply.name === agent && Date.now() - askReply.at < 15000 ? askReply.text : "";
  const attrs = o => `data-name="${esc(agent)}" data-n="${o.n}" data-label="${esc(o.label)}"`;
  return opts.length ? `<span class="opts" tabindex="-1" data-name="${esc(agent)}">${opts.map(o => o.typed
    ? `<span class="typed${on(o)}" data-n="${o.n}"><input class="askin" ${attrs(o)} placeholder="${o.n}. Type something" value="${esc(askTyped[askKey(agent, o.n)] || "")}" autocomplete="off" spellcheck="false">` +
      `<button class="opt go" ${attrs(o)} data-typed="1" title="Answer with what is written here (Enter)">↵</button></span>`
    : `<button class="opt${on(o)}" ${attrs(o)} title="Choose this (or ↑ ↓ to it and Enter, or its number)">${o.n ? o.n + ". " : ""}${esc(o.label)}</button>`).join("")}` +
    `${reply ? `<span class="reply">${esc(reply)}</span>` : ""}</span>` : "";
};
// An agent's open prompt: while it is open its message box is shut, as a prompt ignores a paste and the Enter after it
// would only choose the highlighted option; the prompt is answered with its own buttons.
const openAsk = a => a?.status === "waiting" && (a.feed || []).find(it => it.kind === "ask" && (it.options || []).length);
const ASK_SHUT = "A prompt is open in its pane: answer it with its buttons";
let sayHint = a => a.name?.startsWith(MEET) ? "Message the meeting…" : openAsk(a) ? ASK_SHUT : a.status === "waiting" ? "A prompt is open in its pane: this answers it"
  : a.suggest && settings().suggest !== "off" ? `${a.suggest}   ⇥ Tab` : `Message ${shown(a.name)}…`;
// a box is shut or opened again only when the prompt opens or closes, so a message on its way keeps its box disabled
function shutBox(box, a) {
  const shut = !!openAsk(a);
  if (box._shut !== shut) { box.disabled = shut; box._shut = shut; }
  box.placeholder = sayHint(a);
}
async function answerAsk(b) {
  const name = b.dataset.name, opts = b.closest(".opts"), input = b.dataset.typed ? b.parentElement.querySelector(".askin") : null;
  const text = input ? input.value.replace(/\s+/g, " ").trim() : "", all = [...opts.querySelectorAll(".opt, .askin")];
  const show = why => { askReply = {name, text: why, at: Date.now()}; const s = opts.querySelector(".reply") || opts.appendChild(Object.assign(document.createElement("span"), {className: "reply"})); s.textContent = why; };
  if (input && !text) { flash(input, "failed"); input.focus(); return; }
  all.forEach(x => x.disabled = true);
  const r = await fetch("/api/agent/" + encodeURIComponent(name) + "/answer", {method: "POST", headers: {"Content-Type": "application/json", "X-Team-Say": "1"},
    body: JSON.stringify({n: +b.dataset.n, label: b.dataset.label, text})}).catch(() => null);
  all.forEach(x => x.disabled = false);
  if (!r || !r.ok) { show(r ? (await r.text()).trim() : "the page could not be reached"); if (input) { flash(input, "failed"); input.focus(); } return; }
  show((await r.json()).answered);
  if (input) { delete askTyped[askKey(name, b.dataset.n)]; input.value = ""; askFocus = null; }
  load(); if (open === name) refreshDetail(false);
}
// Capturing, so a click on a button or in a Type something box is theirs alone and does not also open or focus the card
// or view it is on.
document.addEventListener("click", e => {
  if (e.target.closest(".it.ask .askin")) return e.stopPropagation();
  const b = e.target.closest(".it.ask .opt");
  if (!b) return;
  e.stopPropagation(); e.preventDefault();
  if (!b.disabled) answerAsk(b);
}, true);
document.addEventListener("dblclick", e => { if (e.target.closest(".it.ask .opts")) e.stopPropagation(); }, true);
// Keys in a Type something box are its own: Enter answers, and nothing reaches the page's shortcuts.
document.addEventListener("keydown", e => {
  const i = e.target.closest?.(".it.ask .askin");
  if (!i) return;
  e.stopPropagation();
  if (e.key === "Enter" && !e.isComposing) { e.preventDefault(); answerAsk(i.nextElementSibling); }
}, true);
// The prompt the keyboard answers: the one holding the focus, else the open view's, else the only one on the page. A view
// open on an agent with no prompt answers none, so a key pressed there never chooses for an agent out of sight.
function keyedAsk() {
  const f = document.activeElement?.closest?.(".it.ask .opts");
  if (f) return f;
  const shown = [...document.querySelectorAll(".it.ask .opts")].filter(x => x.offsetParent);
  if (open && $("#detail").classList.contains("open")) return shown.find(x => x.dataset.name === open && x.closest("#detail")) || null;
  return new Set(shown.map(x => x.dataset.name)).size === 1 ? shown[0] : null;
}
// Highlights option n of an agent's prompt wherever it is drawn; in the prompt being keyed (o), a Type something option
// takes the focus to be written in, and leaving one gives the focus back to the prompt.
function askMove(name, n, o) {
  if (askSel[name]) askSel[name].at = n;
  document.querySelectorAll(".it.ask .opts").forEach(x => { if (x.dataset.name === name) x.querySelectorAll(".opt:not(.go), .typed").forEach(r => r.classList.toggle("at", +r.dataset.n === n)); });
  const row = o?.querySelector(`.typed[data-n="${n}"]`);
  if (row) row.querySelector(".askin").focus();
  else if (o?.contains(document.activeElement)) o.focus();
}
// ↑, ↓, Enter and the digits answer the keyed prompt as they do in the terminal, unless something else has the keys: a
// menu, a box being typed in (in a Type something box only ↑ and ↓ are the prompt's), or a key with Alt, Ctrl or Cmd.
document.addEventListener("keydown", e => {
  if (e.altKey || e.ctrlKey || e.metaKey || e.isComposing || menu.classList.contains("on")) return;
  const box = e.target.closest?.(".it.ask .askin");
  if (box ? !plainArrow(e) : e.target.closest?.("textarea, input, select, [contenteditable]")) return;
  const o = box ? box.closest(".opts") : keyedAsk();
  if (!o) return;
  const name = o.dataset.name, ns = [...o.querySelectorAll(".opt:not(.go), .typed")].map(r => +r.dataset.n);
  const i = Math.max(0, ns.indexOf(askSel[name]?.at));
  let n;
  if (plainArrow(e)) n = ns[Math.min(ns.length - 1, Math.max(0, i + (e.key === "ArrowDown" ? 1 : -1)))];
  else if (e.key === "Enter" && !e.shiftKey) n = ns[i];
  else if (/^[1-9]$/.test(e.key) && ns.includes(+e.key)) n = +e.key;
  else return;
  e.preventDefault(); e.stopPropagation();
  askMove(name, n, o);
  const b = o.querySelector(`.opt:not(.go)[data-n="${n}"]`);
  if (!plainArrow(e) && b && !b.disabled) answerAsk(b);
}, true);
// Clicking into a Type something box highlights its option.
document.addEventListener("focusin", e => {
  const i = e.target.closest?.(".it.ask .askin");
  if (i && askSel[i.dataset.name]?.at !== +i.dataset.n) askMove(i.dataset.name, +i.dataset.n);
});
document.addEventListener("input", e => {
  const i = e.target.closest?.(".it.ask .askin");
  if (i) askTyped[askKey(i.dataset.name, i.dataset.n)] = i.value;
});
const noteCaret = i => { askFocus = {key: askKey(i.dataset.name, i.dataset.n), start: i.selectionStart, end: i.selectionEnd}; };
for (const ev of ["focusin", "keyup", "select", "input", "pointerup"]) document.addEventListener(ev, e => { const i = e.target.closest?.(".it.ask .askin"); if (i) noteCaret(i); });
// A box left for another part of the page lets go of the focus; one taken away by a redraw keeps it, for its new box.
document.addEventListener("focusout", e => {
  const i = e.target.closest?.(".it.ask .askin");
  if (i) setTimeout(() => { if (i.isConnected && document.activeElement !== i) askFocus = null; });
});
new MutationObserver(() => {
  if (!askFocus || document.activeElement?.matches?.(".askin")) return;
  const i = [...document.querySelectorAll(".it.ask .askin")].find(x => askKey(x.dataset.name, x.dataset.n) === askFocus.key && x.offsetParent);
  if (!i) return;
  const {start, end} = askFocus;
  i.value = askTyped[askFocus.key] || ""; i.focus(); i.setSelectionRange(start, end);
}).observe(document.body, {childList: true, subtree: true});

// Which lanes of an agent's conversation are shown - the owner's, the team's, automation's - each on or off, chosen
// per agent on its card or in its view, and remembered. The page's own set ("" here) sets every agent's when changed.
const LANES = [["owner", ""], ["team", "Team"], ["auto", "Auto"]], ALL = LANES.map(l => l[0]);
// The menus' icons, drawn in the text colour.
const MENU_ICON = Object.fromEntries(Object.entries({
  star: '<path d="M8 1.8l1.9 3.9 4.3.6-3.1 3 .7 4.3L8 11.6l-3.8 2 .7-4.3-3.1-3 4.3-.6z"/>',
  open: '<rect x="2" y="2" width="12" height="12" rx="2"/><path d="M5 8h6M8.5 5.5 11 8l-2.5 2.5"/>',
  tab: '<path d="M9 2h5v5M14 2 7.5 8.5M12 9.5V13a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1V5a1 1 0 0 1 1-1h3.5"/>',
  window: '<rect x="4.5" y="1.5" width="10" height="8" rx="1.5"/><path d="M11.5 12v1a1.5 1.5 0 0 1-1.5 1.5H3A1.5 1.5 0 0 1 1.5 13V7.5A1.5 1.5 0 0 1 3 6h1.5"/>',
  check: '<path d="M3 8.5 6.5 12 13 4.5"/>',
  power: '<path d="M8 1.5v6"/><path d="M4.3 3.6a5.5 5.5 0 1 0 7.4 0"/>',
  close: '<path d="M4 4l8 8M12 4l-8 8"/>',
  pencil: '<path d="M10.5 2.5l3 3L5.5 13.5H2.5v-3z"/>',
  calendar: '<rect x="2" y="3" width="12" height="11" rx="1.5"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/>',
  chart: '<path d="M2.5 13.5h11M4.5 11V7.5M8 11V4M11.5 11V9"/>',
  star: '<path d="M8 1.8l1.9 3.9 4.3.6-3.1 3 .7 4.3L8 11.6l-3.8 2 .7-4.3-3.1-3 4.3-.6z"/>',
  bell: '<path d="M4 11V7a4 4 0 0 1 8 0v4l1.5 1.5h-11zM6.5 14a1.5 1.5 0 0 0 3 0"/>',
  flag: '<path d="M3.5 14V2.5M3.5 3h8l-1.5 3 1.5 3h-8"/>',
  code: '<path d="M5.5 4.5 2 8l3.5 3.5M10.5 4.5 14 8l-3.5 3.5"/>',
  bug: '<rect x="5" y="5" width="6" height="8" rx="3"/><path d="M6 5a2 2 0 0 1 4 0M2.5 9h2.5M11 9h2.5M3 5l2 1.5M13 5l-2 1.5M3 13l2-1.5M13 13l-2-1.5"/>',
  plus: '<path d="M8 3v10M3 8h10"/>',
  down: '<path d="M4 6l4 4 4-4"/>',
  start: '<path d="M5 3.2v9.6L12.8 8z"/>',
  stop: '<rect x="3.5" y="3.5" width="9" height="9" rx="1.5"/>',
  pause: '<path d="M5.5 3v10M10.5 3v10"/>',
  grid: '<rect x="2.5" y="2.5" width="4.5" height="4.5" rx="1"/><rect x="9" y="2.5" width="4.5" height="4.5" rx="1"/><rect x="2.5" y="9" width="4.5" height="4.5" rx="1"/><rect x="9" y="9" width="4.5" height="4.5" rx="1"/>',
  tabs: '<path d="M2 6.5h12v7H2zM2 6.5V3h5.5v3.5"/>',
  custom: '<rect x="2" y="2.5" width="12" height="11" rx="1.5"/><path d="M7 2.5v11M7 8h7"/>',
  owner: '<circle cx="8" cy="5.5" r="2.7"/><path d="M2.8 14a5.2 5.2 0 0 1 10.4 0"/>',
  team: '<circle cx="6" cy="5.5" r="2.3"/><path d="M1.8 13.5a4.2 4.2 0 0 1 8.4 0M10.5 3.4a2.3 2.3 0 0 1 0 4.4M12 9.6a4.2 4.2 0 0 1 2.2 3.9"/>',
  said: '<path d="M3 3h10a1.5 1.5 0 0 1 1.5 1.5v5.5a1.5 1.5 0 0 1-1.5 1.5H7.5L4.5 14v-2.5H3A1.5 1.5 0 0 1 1.5 10V4.5A1.5 1.5 0 0 1 3 3z"/>',
  auto: '<rect x="3" y="5.5" width="10" height="8" rx="2"/><path d="M8 5.5V3"/><circle cx="8" cy="2.4" r=".7"/><circle cx="6" cy="9.5" r=".8"/><circle cx="10" cy="9.5" r=".8"/><path d="M1.5 8.5v2.5M14.5 8.5v2.5"/>',
  compact: '<path d="M2 2h12M2 14h12M8 4v3M6.3 5.3 8 7l1.7-1.7M8 12V9M6.3 10.7 8 9l1.7 1.7"/>',
  more: '<circle cx="3.5" cy="8" r=".9"/><circle cx="8" cy="8" r=".9"/><circle cx="12.5" cy="8" r=".9"/>',
  filter: '<path d="M1.5 4.5h4M9.5 4.5h5M1.5 11.5h7M12.5 11.5h2"/><circle cx="7.5" cy="4.5" r="2"/><circle cx="10.5" cy="11.5" r="2"/>',
}).map(([k, d]) => [k, `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`]));
// A filter button: its icon (and, on the page's, its name), lit while something is left out; a click opens its menu.
const filterBtn = (cls, key, on, all, list, label) => `<b class="${cls} fbtn${on.length < all.length ? " some" : ""}" data-menu="${esc(key)}" ` +
  `title="${esc("Showing: " + (list.filter(([l]) => on.includes(l)).map(([l, t]) => t || S.owner).join(", ") || "nothing"))}">${MENU_ICON.filter}${label ? `<span>${label}</span>` : ""}</b>`;
const LANE_TIP = {owner: "Your messages, and the agent's words to you", team: "Messages between this agent and the others",
  auto: "Tool calls, the nudger and other plugins, background tasks and commands"};
const lanes = () => JSON.parse(localStorage.getItem("lanes") || "{}");
function laneOf(name) {
  // an agent with no choice of its own follows the page's; a stored single lane is that lane alone; anything else, every lane
  const m = lanes(), v = name in m ? m[name] : m[""];
  return Array.isArray(v) ? v : ALL.includes(v) ? [v] : ALL;
}
function toggleLane(name, lane) {
  const set = laneOf(name).includes(lane) ? laneOf(name).filter(l => l !== lane) : [...laneOf(name), lane];
  const m = lanes();
  if (name === "") for (const a of S.agents) m[a.name] = set;
  m[name] = set;
  localStorage.setItem("lanes", JSON.stringify(m));
}
const laneSeg = name => filterBtn("lanes", "lanes:" + name, laneOf(name), ALL, LANES, "").replace("<b ", `<b data-name="${esc(name)}" `);
// A conversation as shown: the chosen lanes only (an open prompt and the working line always), with each run of automated events folded
// into one line; in the agent view a folded run opens on a click.
const openRuns = new Set();
function feedHtml(items, name, compact, on = laneOf(name)) {
  if (name) items = items.concat(echoItems(items, name));
  const shown = items.filter(it => on.includes(it.lane) || ["ask", "live", "pending", "echo"].includes(it.kind)), out = [];
  for (let i = 0; i < shown.length; i++) {
    let j = i;
    while (shown[i].kind === "event" && j + 1 < shown.length && shown[j + 1].kind === "event") j++;
    if (j === i) { out.push(item(shown[i], compact, shown[i]._agent || name, !!shown[i]._agent)); continue; }
    const run = shown.slice(i, j + 1), key = run[0].ts + run[0].who, n = {};
    run.forEach(it => n[it.who] = (n[it.who] || 0) + 1);
    const what = Object.entries(n).map(([w, c]) => `${esc(w)}${c > 1 ? ` <span class="n">×${c}</span>` : ""}`).join(" · ");
    out.push(`<div class="it event folded l-auto" data-run="${esc(key)}"><span class="who">${run.length} automated</span><span class="tx">${what}</span><span class="ago" data-ts="${esc(run[run.length - 1].ts || "")}">${since(run[run.length - 1].ts)}</span></div>`);
    if (!compact && openRuns.has(key)) out.push(...run.map(it => item(it, compact, it._agent || name, !!it._agent)));
    i = j;
  }
  return out.length ? out.join("") : `<div class="empty">${on.length ? "nothing here lately" : "nothing shown"}</div>`;
}
function laneClicks(root) {
  root.querySelectorAll(".lanes").forEach(b => {
    const name = b.dataset.name;
    filterButton(b, LANES, () => laneOf(name), l => `${LANE_TIP[l]}${name ? "" : ", on every agent"}`, l => {
      toggleLane(name, l);
      draw(); if (open) { renderConv(); $("#dhead .lanes").outerHTML = laneSeg(open); laneClicks($("#dhead")); }
    });
  });
}

function spark(series, ceil, colour) {
  if (!series.length) return "";
  const w = 300, h = 26, n = series.length, step = w / (n - 1 || 1);
  const pts = series.map((v, i) => [i * step, h - 2 - (v / ceil) * (h - 5)]);
  const line = pts.map((p, i) => (i ? "L" : "M") + p[0].toFixed(1) + " " + p[1].toFixed(1)).join(" ");
  const id = "g" + Math.random().toString(36).slice(2);
  return `<svg class="spark" viewBox="0 0 ${w} ${h}" preserveAspectRatio="none"><defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${colour}" stop-opacity=".45"/><stop offset="1" stop-color="${colour}" stop-opacity="0"/></linearGradient></defs><path d="${line} L${w} ${h} L0 ${h} Z" fill="url(#${id})"/><path d="${line}" fill="none" stroke="${colour}" stroke-width="1.5" vector-effect="non-scaling-stroke"/></svg>`;
}

// An agent's message box, with the images waiting to go above it.
// Send, inside the box at its bottom right: a tap or click is Enter in the box beside it, so it goes the way Enter goes.
const SEND = `<button class="send" title="Send (Enter)"></button>`;
document.addEventListener("click", e => {
  const b = e.target.closest?.(".sayrow .send"), box = b?.previousElementSibling;
  if (!box?.matches("textarea.say")) return;
  e.stopPropagation();
  box.dispatchEvent(new KeyboardEvent("keydown", {key: "Enter", bubbles: true, cancelable: true}));
  box.focus();
}, true);
const sayRow = a => `<div class="att" data-name="${esc(a.name)}"></div><div class="sayrow">${addButton(a.name)}<textarea class="say" rows="1" data-name="${esc(a.name)}" placeholder="${esc(sayHint(a))}" autocomplete="off"></textarea>${SEND}${a.status === "busy" ? stopButton(a.name) : ""}</div>`;
// A card given its conversation's key (an agent pane's) marks its feed with it; with keep, the feed is left empty,
// for the redraw to keep the one on screen.
// A narrow card's state, model and activity rows fold away under its ^ and come back with its v, for room on a phone
// (owner, 2026-11-01), kept per agent in this browser. A wide card has them on its name's line, so nothing to fold.
const folded = () => { try { return JSON.parse(localStorage.getItem("folded")) || []; } catch (e) { return []; } };
// The ^ that folds something away, a v once it is folded.
const foldIcon = on => `<svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6"><path d="${on ? "M2.5 4.5 6 8l3.5-3.5" : "M2.5 7.5 6 4l3.5 3.5"}"/></svg>`;
const foldButton = (name, on) => `<b class="foldbtn" data-name="${esc(name)}" title="${on ? "Show its state, model and activity" : "Hide its state, model and activity"}">${foldIcon(on)}</b>`;
document.addEventListener("click", e => {
  const b = e.target.closest?.(".foldbtn");
  if (!b) return;
  e.stopPropagation();
  const name = b.dataset.name, f = folded();
  try { localStorage.setItem("folded", JSON.stringify(f.includes(name) ? f.filter(x => x !== name) : [...f, name])); } catch (e) {}
  draw();
}, true);
function card(a, ceil, conv, extra = "", after = "", {key = "", keep = false, lead = ""} = {}) {
  const cls = stOf(a);
  const model = a.model ? a.model.split(" ").slice(0, 2).map((p, i) => i ? p : p[0]).join("") : "";
  const ctx = a.ctxPct == null ? "" : `<span class="ctx" title="${a.ctxPct}% of context used"><span class="meter"><i style="width:${Math.min(100, a.ctxPct)}%;background:${gauge(a.ctxPct)}"></i></span><span style="color:${gauge(a.ctxPct)}">${a.ctxPct}%</span></span>`;
  const turns = conv || a.feed;
  const feed = keep ? "" : turns.length ? feedHtml(turns, a.name, !conv) : `<div class="empty">${a.live ? "no conversation yet" : "not running"}</div>`;
  const fold = folded().includes(a.name);
  return `<div class="card ${cls}${switching(a)}${conv ? " full" : ""}${after ? " term" : ""}${fold ? " folded" : ""}" style="--c:${a.colour}" data-name="${esc(a.name)}">
    <div class="top">${lead ? `<span class="lead">${lead}<span class="name">${esc(shown(a.name))}</span></span>` : `<span class="name">${esc(shown(a.name))}</span>`}<span class="role">${esc(a.roleName)}</span>${a.ticket ? `<span class="ticket">${esc(a.ticket)}</span>` : ""}<span class="cctl">${foldButton(a.name, fold)}${a.feed.length ? laneSeg(a.name) : ""}</span>${extra}</div>
    <div class="row2"><span class="state"><span class="dot"></span>${STATE[cls] || esc(cls)}</span><span>${ago(heldOf(a))}</span>${ctx}</div>
    ${cls === "wanted" ? `<div class="wantline">${esc(a.wanted)}</div>` : ""}
    <div class="row2"><span class="model">${esc(model)} ${esc(a.effort)}</span><span class="model">${a.rate ? k(a.rate) + " tok/min" : ""}</span><span class="model" style="margin-left:auto">${esc(a.cwd)}</span></div>
    ${spark(a.series, ceil, a.colour)}
    <div class="feed"${key ? ` data-key="${esc(key)}"${keep ? " data-kept" : ""}` : ""}>${feed}</div>${conv ? `<button class="newest" title="Back to the newest turn">↓ Newest</button>` : ""}${after}
    ${a.live ? sayRow(a) : ""}</div>`;
}
// A List row's status, after its name and ticket: its state in words, then the pane's footer ("in shell · 1 shell").
const mstat = (a, st) => [st === "wanted" ? STATE.wanted : STATE[st] || st, a.live && a.pfoot].filter(Boolean).join(" · ");

function cols(n, w, h) {
  // the column count whose cards come out closest to a 4:5 shape in this section
  let best = 1, score = 1e9;
  for (let c = 1; c <= n; c++) { const r = Math.ceil(n / c), ratio = (w / c) / (h / r), s = Math.abs(Math.log(ratio / 0.8)) + (c * r - n) * 0.15; if (s < score) { score = s; best = c; } }
  return best;
}

// A grip in each gap between sections: drag to resize the two either side, double-click to go back to the default.
let resizing = false;
function grips(names) {
  const main = $("#main"), secs = [...main.querySelectorAll("section.tab")], m = main.getBoundingClientRect();
  secs.slice(0, -1).forEach((sec, i) => {
    const g = document.createElement("div");
    g.className = "colgrip"; g.title = "Drag to resize, double-click to reset";
    g.style.left = (sec.getBoundingClientRect().right - m.left) + "px";
    g.ondblclick = () => { localStorage.removeItem("cols"); draw(); };
    g.onpointerdown = e => {
      e.preventDefault(); g.setPointerCapture(e.pointerId); g.classList.add("drag"); document.body.classList.add("resizing"); resizing = true;
      const widths = secs.map(s => s.getBoundingClientRect().width), a = secs[i].getBoundingClientRect().left, b = secs[i + 1].getBoundingClientRect().right;
      let moved = false;
      g.onpointermove = mv => {
        moved = true;
        const left = Math.max(220, Math.min(b - a - 14 - 220, mv.clientX - a - 7));
        widths[i] = left; widths[i + 1] = b - a - 14 - left;
        main.style.gridTemplateColumns = widths.map(w => `minmax(0,${w.toFixed(0)}fr)`).join(" ");
        g.style.left = (a - m.left + left) + "px";
      };
      g.onpointerup = () => {
        g.onpointermove = null; g.classList.remove("drag"); document.body.classList.remove("resizing"); resizing = false;
        if (!moved) return;   // a click, perhaps the first of a double-click: the grip must survive it
        localStorage.setItem("cols", JSON.stringify(Object.fromEntries(names.map((n, k) => [n, Math.round(widths[k])]))));
        draw();
      };
    };
    main.append(g);
  });
}

// Hovering a turn that a card has cut short shows all of it beside the card; the box stays while the pointer
// is over it, so a long one can be scrolled, and a click on it opens the agent, as a click on the card does.
const pop = $("#pop");
let popFor = null, popHide = 0, popShow = 0;
document.addEventListener("mouseover", e => {
  if (e.target.closest("#pop")) { clearTimeout(popHide); return; }
  const tx = e.target.closest("#main .it .tx");
  if (!tx || tx.scrollHeight <= tx.clientHeight + 1) {
    clearTimeout(popShow);
    if (popFor) popHide = setTimeout(() => { pop.classList.remove("on"); popFor = null; }, 150);
    return;
  }
  clearTimeout(popHide);
  if (popFor === tx) return;
  // a short pause before it opens, so passing over a turn on the way elsewhere does not flash it up
  clearTimeout(popShow);
  popShow = setTimeout(() => showPop(tx), 350);
});
function showPop(tx) {
  if (!tx.isConnected) return;
  popFor = tx; pop.dataset.name = tx.closest(".card")?.dataset.name || ""; pop.innerHTML = tx.innerHTML; pop.classList.add("on");
  const r = tx.getBoundingClientRect(), w = Math.min(560, innerWidth - 24);
  pop.style.width = w + "px";
  pop.style.left = Math.max(12, Math.min(r.left, innerWidth - w - 12)) + "px";
  const h = pop.offsetHeight;
  pop.style.top = (r.bottom + 6 + h < innerHeight ? r.bottom + 6 : Math.max(12, r.top - 6 - h)) + "px";
}

pop.onclick = e => { if (e.target.closest("a")) return; const name = pop.dataset.name; pop.classList.remove("on"); popFor = null; if (name) openDetail(name); };

// The page's view, a button naming it whose menu picks Grid, Tabs or Custom; and a
// Grid / Tabs switch for one section.
const VIEW_TIP = {grid: "Every section side by side", tabs: "Every agent as one row of tabs, one at a time", custom: "Your own layout of panes"};
const viewButton = mode => `<b class="fbtn viewbtn" data-menu="view" title="${esc(VIEW_TIP[mode])}">${MENU_ICON[shownView().icon] || MENU_ICON[mode]}<span>${esc(shownView().name)}</span></b>`;
function seg(mode, sec) {
  const tip = {grid: `Every agent in ${sec} as a card`, tabs: `${sec} as tabs, one agent at a time`};
  return `<span class="seg mode" data-sec="${esc(sec)}">${["grid", "tabs"].map(m => `<b data-mode="${m}" class="${m === mode ? "on" : ""}" title="${esc(tip[m])}">${m[0].toUpperCase() + m.slice(1)}</b>`).join("")}</span>`;
}

// Text being selected is left alone: redrawing it would drop the selection's start, so while the mouse is down or a
// selection lies inside part of the page, that part is not redrawn.
let mouseDown = false;
addEventListener("pointerdown", () => { mouseDown = true; }, true);
addEventListener("pointerup", () => { mouseDown = false; }, true);
addEventListener("blur", () => { mouseDown = false; });
function holding(el) {
  if (mouseDown) return true;
  const s = getSelection();
  return !s.isCollapsed && (el.contains(s.anchorNode) || el.contains(s.focusNode));
}

// A redraw brings the page in line with new HTML by changing only the nodes that differ, so the browser lays out
// only what changed, and unchanged turns keep their place, focus and animations. A node that now stands for another
// agent is replaced, and a message box keeps what is typed in it, its height and the images pasted into it.
function patch(el, html) {
  const t = document.createElement("template");
  t.innerHTML = html;
  patchKids(el, t.content);
}
function patchKids(a, b) {
  const an = [...a.childNodes], bn = [...b.childNodes];
  // on the phone, agents' rows and portraits move as their states change: they are matched by name (patchByName)
  if (a.nodeType === 1 && a.closest("#phone, #drail") && bn.length && bn.every(x => x.nodeType === 1 && phKey(x))) return patchByName(a, b);
  if (an.length !== bn.length) { keepFeeds(a, b); a.replaceChildren(...b.childNodes); return; }
  an.forEach((x, i) => patchNode(x, bn[i]));
}
// patchByName: as patch, but children that carry a data-name are matched by it, not by place, so one that moves along
// (a row reordered by state) is moved, not rebuilt: a rebuilt portrait is a new image, which a phone shows blank until
// it has loaded again (owner, 2026-11-09: the phone's portrait strip "sometimes" a row of empty frames).
const phKey = x => x.dataset.name || x.dataset.open || x.dataset.menuName;
function patchByName(el, html) {
  let src = html;
  if (typeof html === "string") { const t = document.createElement("template"); t.innerHTML = html; src = t.content; }
  const old = new Map([...el.children].filter(phKey).map(x => [x.nodeName + phKey(x), x]));
  const kids = [...src.childNodes].map(b => { const a = b.nodeType === 1 && phKey(b) && old.get(b.nodeName + phKey(b)); if (!a) return b; old.delete(b.nodeName + phKey(b)); patchKeyed(a, b); return a; });
  if (kids.length !== el.childNodes.length || kids.some((k, i) => el.childNodes[i] !== k)) el.replaceChildren(...kids);
}
// patchNode for two that are the same agent's: its own name is not compared again (a row's data-name may be absent)
function patchKeyed(a, b) {
  if (a.isEqualNode(b)) return;
  for (const {name} of [...a.attributes]) if (!b.hasAttribute(name)) a.removeAttribute(name);
  for (const {name, value} of [...b.attributes]) if (a.getAttribute(name) !== value) a.setAttribute(name, value);
  patchKids(a, b);
}
// A feed left empty to be kept takes the one on screen with its key, when what holds it is replaced.
function keepFeeds(a, b) {
  if (a.nodeType !== 1 || b.nodeType !== 1 && b.nodeType !== 11) return;
  b.querySelectorAll(".feed[data-kept]").forEach(f => { const old = a.querySelector(`.feed[data-key="${CSS.escape(f.dataset.key)}"]`); if (old) f.replaceWith(old); });
}
function patchNode(a, b) {
  if (a.isEqualNode(b)) return;
  if (b.nodeType === 1 && "kept" in b.dataset && a.dataset?.key === b.dataset.key) return;
  if (a.nodeType !== b.nodeType || a.nodeName !== b.nodeName || a.nodeType === 1 && a.dataset.name !== b.dataset.name) { keepFeeds(a, b); a.replaceWith(b); return; }
  if (a.nodeType !== 1) { a.nodeValue = b.nodeValue; return; }
  const box = a.matches("textarea, .att"), kept = box ? ["style", "disabled", "title"] : [];
  for (const {name} of [...a.attributes]) if (!b.hasAttribute(name) && !kept.includes(name)) a.removeAttribute(name);
  for (const {name, value} of [...b.attributes]) if (a.getAttribute(name) !== value && !kept.includes(name)) a.setAttribute(name, value);
  // a menu once used shows its own choice whatever its options' selected attributes become, so it is set to the one marked
  const pick = a.nodeName === "SELECT" ? b.querySelector("option[selected]")?.value : undefined;
  if (!box) patchKids(a, b);
  if (pick !== undefined && a.value !== pick) a.value = pick;
}

function draw() {
  if (!S || resizing || holding($("#main")) || document.activeElement?.classList.contains("ctname")) return;   // nor while a tab is being named
  if (!barDrag) placeBar();
  const n = st => S.agents.filter(a => a.status === st).length;
  // Working and idle as a dot and a number each, with a flashing badge on top when any agent is waiting.
  const waiting = needing().length;
  // the badge opens the agent that has been waiting longest, on a prompt or on the owner
  const longest = needing()[0]?.name || "";
  // the working dot pulses while any agent works; the counts are rewritten only when they change, so the pulse runs on
  const tally = `<span class="pill tally" title="${n("busy")} working, ${n("idle")} idle${waiting ? `, ${waiting} waiting` : ""}">` +
    `<span class="dot${n("busy") ? " on" : ""}" style="background:var(--green)"></span><b>${n("busy")}</b><span class="dot"></span><b style="color:var(--mute)">${n("idle")}</b>` +
    (waiting ? `<span class="wait" data-name="${esc(longest)}" title="Open ${esc(longest)}, waiting longest">${waiting} waiting</span>` : "") + `</span>`;
  if ($("#counts").dataset.html !== tally) { $("#counts").innerHTML = tally; $("#counts").dataset.html = tally; }
  $("#counts").onclick = e => { const w = e.target.closest(".wait"); if (w) openDetail(w.dataset.name); };
  // the logo flags it too, and opens the same agent
  const brand = $(".brand");
  brand.classList.toggle("waiting", !!waiting);
  brand.title = waiting ? `Open ${longest}, waiting longest (${waiting} waiting)` : "Claude agents";
  brand.onclick = waiting ? () => openDetail(longest) : null;
  // The benched developers and testers, and the stopped standing agents, on one line in the header's free space, so the header never changes height;
  // those that do not fit are counted in a "+N" that names them. Its filter button, there only while a custom layout is
  // unlocked, shows them by name or as icons (their portrait, else their role's shadow, as a pane's Icon badge); until
  // one is picked, icons while a Characters pane is on the page.
  const style = benchStyle(), benchSel = localStorage.getItem("page") === "custom" && !pageLocked(), onBench = barWho("bench");
  $("#bench").innerHTML = onBench.length ? `<span>${benchSel ? filterBtn("benchsel", "bench", [style], ["name", "icon"], BENCH_STYLES, "") : ""}</span><span class="rrow">${onBench.map(b => {
    const tip = `data-name="${esc(b.name)}"`;
    return style === "icon" ? face(b, tip, " benched")
      : `<em style="--c:${b.colour}" ${tip}>${esc(b.name)}</em>`; }).join("")}</span>` : "";
  // each one's menu, its details only, on a rest or a right-click, as an agent's tile
  document.querySelectorAll("#bench .rrow [data-name]").forEach(m => {
    m.onmouseenter = () => menuSoon(m, 350); m.onmouseleave = () => { clearTimeout(menuShow); if (menu.dataset.rested) menuOff(); };
    m.oncontextmenu = e => { e.preventDefault(); menuSoon(m, 0); };
  });
  // The favourites (owner, 2026-11-10: "a bit like the bench, a favourites bar", "just the local favourites"): the agents
  // starred from their menu in this browser, by name A to Z; and those active (owner, 2026-11-11: "alongside favourites
  // bar can have an actives bar"). Each is drawn as the bench is, after its icon; a click opens a running one.
  for (const k of ["favs", "active"]) agentRow($("#" + k), k, style);
  if (onBench.length && benchSel) filterButton($("#bench .benchsel"), BENCH_STYLES, () => [benchStyle()], v => `The bench by ${v === "icon" ? "icon" : "name"}`,
    v => { menuOff(true); localStorage.setItem("bench", v); draw(); }, "Bench");


  const ceil = Math.max(1, ...S.agents.flatMap(a => a.series));
  const main = $("#main"), W = main.clientWidth, H = main.clientHeight;
  const tabs = S.tabs.map(name => ({name, agents: S.agents.filter(a => a.tab === name)}));
  const total = tabs.reduce((s, t) => s + t.agents.length, 0) || 1;
  // The page shows every section side by side (Grid), or one agent's view at a time, picked from the column of them
  // all beside it (Tabs).
  const pageMode = shownView().kind;
  // Developers and Testers, where agents come and go, are at most three cards wide and grow by rows; the other
  // sections take the shape that suits their few cards. Each section's width follows its columns, so every card
  // is about as wide as any other.
  const shares = tabs.map(t => {
    const n = t.agents.length, c = ["Developers", "Testers"].includes(t.name) ? Math.min(3, n) : cols(n, W * n / total, H - 50);
    return {c, share: c};
  });
  // Widths dragged with the grips between sections win, remembered per section; otherwise the lead's column is
  // half as wide again as its one card needs.
  const saved = JSON.parse(localStorage.getItem("cols") || "{}");
  main.style.gridTemplateColumns = pageMode !== "grid" ? "minmax(0,1fr)"
    : tabs.map((t, i) => `minmax(0,${saved[t.name] ?? (t.name === "Lead" ? 1.5 : shares[i].share)}fr)`).join(" ");
  $("#pagemode").innerHTML = viewButton(pageMode);
  // the Views toolbar: each view's icon, named with its key on a rest; a click shows it
  const vl = views(), vk = viewKeys(), bar = vl.views.map((x, i) => { const d = Object.keys(vk).find(k => vk[k] === i);
    return `<b class="fbtn vtb${i === vl.at ? " on" : ""}" data-v="${i}" title="${esc(x.name)}${d ? ` (${viewMod()}+${d})` : ""}">${MENU_ICON[x.icon] || MENU_ICON[x.kind]}</b>`; }).join("") +
    (pageLocked() ? "" : `<b class="fbtn vtmenu" data-menu="view" title="The View menu: rename, delete and add views">${MENU_ICON.down}</b>`);   // unlocked, its menu too
  if ($("#viewbar").dataset.html !== bar) { $("#viewbar").innerHTML = bar; $("#viewbar").dataset.html = bar; }
  if ($("#viewbar .vtmenu")) menuButton($("#viewbar .vtmenu"), rested => viewMenu($("#viewbar .vtmenu"), rested));
  menuButton($("#pagemode .viewbtn"), rested => viewMenu($("#pagemode .viewbtn"), rested));
  $("#lock").innerHTML = padlock(pageLocked()); $("#lock").title = pageLocked() ? "Locked: click to change the page" : "Click to lock the page";
  $("#pagelanes").innerHTML = laneSeg(""); laneClicks($("#pagelanes"));
  teamButton();
  const typed = {}, act = document.activeElement, focus = act && act.matches("#main .say") ? [act.dataset.name, act.selectionStart, act.selectionEnd, act.selectionDirection] : null;
  document.querySelectorAll("#main .say").forEach(i => { if (i.value) typed[i.dataset.name] = i.value; });
  // A row of tabs, one per agent; the picked one is remembered under "tab:" + key.
  const tabRow = (key, agents, badge, none) => {   // none: nobody is picked until one is (a Meeting's row)
    const sel = agents.find(a => a.name === localStorage.getItem("tab:" + key)) || (none ? null : agents[0]);
    if (badge === "icon")
      return [sel, `<div class="tabbar icontabs" data-sec="${esc(key)}">${agents.map(a => { const n = a === sel ? 0 : unseen(a);
        return `<span class="ftab" style="--c:${a.colour}">${face(a, `data-tab="${esc(a.name)}" data-name="${esc(a.name)}" title="${esc(a.fullName || a.name)}"`, a === sel ? " sel" : "")}${n ? unseenBadge(n) : ""}</span>`; }).join("")}</div>`];
    if (badge === "card")
      return [sel, `<div class="tabbar chrtabs" data-sec="${esc(key)}">${agents.map(a => tiles([a]).replace(/ title="[^"]*"/g, "")   // no tooltips: a rest shows the agent's menu
      .replace('<div class="chr ', `<div data-tab="${esc(a.name)}" class="chr${a === sel ? " sel" : ""} `)).join("")}</div>`];
    const tab = a => { const n = a === sel ? 0 : unseen(a);
      return `<button class="${stOf(a)}${switching(a)}" style="--c:${a.colour}" data-tab="${esc(a.name)}"><span class="dot"></span>${esc(shown(a.name))}${n ? unseenBadge(n) : ""}</button>`; };
    return [sel, `<div class="tabbar" data-sec="${esc(key)}">${agents.map(tab).join("")}</div>`];
  };
  let html;
  if (pageMode === "tabs") {
    html = "";   // the agent's view, docked over the page's body, takes its place
  } else if (pageMode === "custom") {
    html = customHtml(ceil, tabRow);
  } else {
    // A section of several agents shows them as a grid of cards or as tabs, one agent at a time; the choice and
    // the tab are remembered per section.
    html = tabs.map((t, i) => {
      const many = t.agents.length > 1, mode = many && localStorage.getItem("mode:" + t.name) || "grid";
      const sw = many ? seg(mode, t.name) : "";
      if (mode !== "tabs") {
        return `<section class="tab"><h2>${esc(t.name)}${sw}</h2>
          <div class="cards" style="grid-template-columns:repeat(${shares[i].c},minmax(0,1fr))">${t.agents.map(a => card(a, ceil)).join("")}</div></section>`;
      }
      const [sel, row] = tabRow(t.name, t.agents);
      return `<section class="tab"><h2>${esc(t.name)}${sw}</h2>${row}
        <div class="cards" style="grid-template-columns:minmax(0,1fr)">${sel ? card(sel, ceil) : ""}</div></section>`;
    }).join("");
  }
  main.querySelectorAll(".colgrip").forEach(g => g.remove());
  const ends = paneEnds(), scrolled = scrolls(main);
  patch(main, html);
  unscroll(main, scrolled);
  toPaneEnds(ends);
  dock(pageMode === "tabs" && (tabs.flatMap(t => t.agents).find(a => a.name === localStorage.getItem("tab:page")) || S.agents[0]));
  document.querySelectorAll(".seg.mode b").forEach(b => b.onclick = () => { localStorage.setItem("mode:" + b.parentElement.dataset.sec, b.dataset.mode); draw(); });
  // Picking a tab puts the cursor in that agent's message box, ready to type; a click on the tab already picked opens
  // (or shuts) its agent's menu, which data-menu keeps open past the press.
  document.querySelectorAll(".tabbar[data-sec] [data-tab]").forEach(b => { b.dataset.menu = "agent:" + b.dataset.tab; });
  document.querySelectorAll(".tabbar [data-tab]").forEach(b => b.onclick = () => {
    const sec = b.closest(".tabbar").dataset.sec, name = CSS.escape(b.dataset.tab);
    const picked = localStorage.getItem("tab:" + sec), first = b.closest(".tabbar").querySelector("[data-tab]");
    if (b.dataset.tab === (picked && b.closest(".tabbar").querySelector(`[data-tab="${CSS.escape(picked)}"]`) ? picked : first.dataset.tab)) {
      clearTimeout(menuShow); return agentMenu(b, b.dataset.tab, true, false);
    }
    menuOff(true);
    localStorage.setItem("tab:" + sec, b.dataset.tab);
    draw();
    aim(document.querySelector(`.tabbar[data-sec="${CSS.escape(sec)}"]`)?.parentElement.querySelector(`.say[data-name="${name}"]`));
  });
  // A tile in a card-badge tab row opens its agent's menu like any other tile: on a rest or a right-click.
  document.querySelectorAll(".chrtabs .chr, .icontabs .face").forEach(m => {
    m.onmouseenter = () => menuSoon(m, 350); m.onmouseleave = () => { clearTimeout(menuShow); if (menu.dataset.rested) menuOff(); };
    m.oncontextmenu = e => { e.preventDefault(); menuSoon(m, 0); };
  });
  if (pageMode === "grid") grips(tabs.map(t => t.name));
  if (pageMode === "custom") customClicks();
  if (!open) markSeen([...[...main.querySelectorAll(".card")].map(c => c.dataset.name), ...S.agents.filter(a => !seen[a.name]).map(a => a.name)]);
  rail(); facts(); syncStop();
  main.querySelectorAll(FADES).forEach(edges);
  document.querySelectorAll("#main .stop").forEach(b => b.onclick = e => { e.stopPropagation(); stopAgent(b.dataset.name, b); });
  main.querySelectorAll(".add").forEach(b => b.onclick = e => { e.stopPropagation(); pick(b.dataset.name, b.nextElementSibling); });
  // In a custom layout a click on a card puts the cursor in its message box, and a double-click opens it.
  document.querySelectorAll(".card").forEach(c => c.onclick = e => {
    if (!getSelection().isCollapsed || e.target.closest("a")) return;
    const box = c.closest(".pane") && c.querySelector(".say");
    if (box) { if (e.detail < 2 && document.activeElement !== box) aim(box); } else openDetail(c.dataset.name);
  });
  document.querySelectorAll(".pane .card").forEach(c => c.ondblclick = e => { if (!e.target.closest(".say,a")) openDetail(c.dataset.name); });
  laneClicks(main);
  document.querySelectorAll("#main .say").forEach(i => {
    i.value = typed[i.dataset.name] || draft(i.dataset.name); grow(i);
    shutBox(i, S.agents.find(a => a.name === i.dataset.name) || {name: i.dataset.name});
    i.onclick = e => e.stopPropagation();
    i.oninput = () => { emojify(i); suggest(i); grow(i); keep(i); };
    i.onkeydown = e => emoKey(e, i) || keys(e, i, i.dataset.name);
    i.onpaste = e => pasted(e, i.dataset.name);
    if (focus && focus[0] === i.dataset.name) { i.focus(); i.setSelectionRange(focus[1], focus[2], focus[3]); }   // the whole selection and its direction, so Shift+arrows carries on from it
    if (!i.parentElement.previousElementSibling.children.length) showAtt(i.dataset.name);
  });
  main.querySelectorAll(".chat .x").forEach(x => x.onclick = () => chatWith(x.dataset.chat, null));
  main.querySelectorAll(".chat .pick").forEach(b => b.onclick = () => chatPick(b));
  fitBench(); beat();
  if (tileGuess) { tileGuess = false; draw(); }   // a Characters pane drawn for the first time is sized again, now it can be measured
}
const BENCH_STYLES = [["name", "Name"], ["icon", "Icon"]];
const benchStyle = () => ({card: "icon"}[localStorage.getItem("bench")] || localStorage.getItem("bench"))   // "card" was the icon's old name
  || (localStorage.getItem("page") === "custom" && leaves(layout().root).some(([, n]) => n.show === "characters") ? "icon" : "name");
// A pane's scrolling part fades at an edge while there is more beyond it.
const FADES = ".card.full .feed, .teamlog:not(.summary) .feed, .fdoc, .others, .chrs";
function edges(el) {
  el.style.setProperty("--ft", el.scrollTop > 1 ? "28px" : "0px");
  el.style.setProperty("--fb", el.scrollTop + el.clientHeight < el.scrollHeight - 1 ? "28px" : "0px");
}
document.addEventListener("scroll", e => { if (e.target.matches?.(FADES)) edges(e.target); }, true);
addEventListener("resize", () => document.querySelectorAll("#main :is(" + FADES + ")").forEach(edges));
// The bench is one row. When it is too long the chips overlap, each later one over the right of the one before, as
// far as leaves every chip BENCH_PEEK px showing; what still does not fit is folded into a +N chip. The mouse over the
// stack spreads every benched agent out in a panel over the page, from where the stack sits, and leaving it stacks them
// again; a click on +N spreads them too.
let benchAll = false, benchFold = 0;
const benchSpread = all => { clearTimeout(benchFold); if (benchAll !== all) { benchAll = all; draw(); } };
const BENCH_PEEK = 14;
function fitBench() {
  const row = $("#bench .rrow"), chips = row ? [...row.children] : [];
  if (!row || !chips.length || row.scrollWidth <= row.clientWidth) return;
  const more = Object.assign(document.createElement("em"), {className: "more", style: "--c:var(--line2)"});
  more.onclick = e => { e.stopPropagation(); benchSpread(!benchAll); };
  row.onmouseenter = () => benchSpread(true);
  row.onmouseleave = () => { clearTimeout(benchFold); benchFold = setTimeout(() => benchSpread(false), 250); };
  if (benchAll) {
    $("#bench").style.minHeight = $("#bench").offsetHeight + "px";   // the header keeps its height
    const room = innerWidth - row.getBoundingClientRect().left - 16;   // as wide as the page allows, then wrapping
    Object.assign(row.style, {left: row.offsetLeft + "px", top: row.offsetTop + "px", width: "max-content", maxWidth: room + "px"});
    row.classList.add("all"); return;
  }
  const gap = parseFloat(getComputedStyle(row).columnGap) || 0, room = row.clientWidth, w = chips.map(c => c.offsetWidth);
  // the first k chips overlapped into the room left beside a +N chip of `side` px: how far each must slide under
  const slide = (k, side) => k < 2 ? 0 : (w.slice(0, k).reduce((a, b) => a + b, 0) + gap * (k - 1) - (room - side)) / (k - 1);
  const fits = (k, side) => w.slice(0, k - 1).every(x => x + gap - slide(k, side) >= BENCH_PEEK);
  let k = chips.length, side = 0;
  if (!fits(k, 0)) {
    row.append(more); more.textContent = "+" + chips.length;
    side = more.offsetWidth + gap;
    while (k > 1 && !fits(k, side)) k--;
    const off = chips.slice(k);
    off.forEach(c => c.remove());
    more.textContent = "+" + off.length;
    more.title = "Also on the bench: " + off.map(c => c.dataset.name).join(", ") + ". Click to show them";
  }
  const by = Math.max(0, slide(k, side));
  chips.slice(1, k).forEach(c => c.style.marginLeft = -by + "px");
  row.classList.toggle("stack", by > 0);
}

// The custom layout, kept in this browser: a tree whose inner nodes split their space in two, side by side ("row") or
// one above the other ("col"), at a fraction "at", and whose leaves are panes showing an agent's card ("agent"),
// every agent as a list ("others"), portrait tiles of every agent or those in some roles ("characters"), a grid or tabs
// of the agents in some roles, a document by its full path ("file"), or nothing yet. A pane is
// named by its path from the root ("r", then "a" or "b" for each split), which also keys its tabs. Locked, the panes
// lose their bars, so what each shows stays put; their dividers still move.
// A flat padlock in the text colour: the shackle closed when locked, swung open when not.
const padlock = locked => `<svg width="13" height="15" viewBox="0 0 13 15" fill="none" stroke="currentColor" stroke-width="1.6" style="display:block"><rect x="1.5" y="6.5" width="10" height="7.5" rx="1.5"/><path d="${locked ? "M3.75 6.5V4.25a2.75 2.75 0 0 1 5.5 0V6.5" : "M3.75 6.5V4.25a2.75 2.75 0 0 1 5.5 0V3.5"}"/></svg>`;
const PANE_TYPES = {agent: "Agent", characters: "Characters", combined: "Combined", file: "File", gauges: "Gauges", grid: "Grid", others: "List", meeting: "Meeting", perf: "Performance", machine: "Machine", tabs: "Agent tabs", team: "Team", daylog: "Day log", workqueue: "Work queue", tokens: "Token usage"};
// The view picker a tab's chevron and a pane's + open: the views in groups, each with its icon and a line on what it shows.
const PANE_GROUPS = [
  ["People", [["grid", "Each agent's conversation, side by side"], ["others", "Every agent in a compact list"], ["agent", "One agent's conversation"],
    ["tabs", "One agent at a time, picked from a row"], ["characters", "The agents as portrait tiles"], ["team", "The messages between agents"],
    ["combined", "Several agents' conversations as one feed"]]],
  ["Work", [["workqueue", "Doing and Done, a box per section"], ["daylog", "What happened, day by day"], ["meeting", "A meeting with the agents invited"],
    ["file", "One document, by its path"]]],
  ["Metrics", [["machine", "The machine's figures, as gauges or rows"], ["tokens", "Tokens each agent used, a box per week"]]],
];
const PANE_ICON = Object.fromEntries(Object.entries({
  grid: '<rect x="2.5" y="2.5" width="4.5" height="4.5" rx="1"/><rect x="9" y="2.5" width="4.5" height="4.5" rx="1"/><rect x="2.5" y="9" width="4.5" height="4.5" rx="1"/><rect x="9" y="9" width="4.5" height="4.5" rx="1"/>',
  others: '<path d="M6 4h8M6 8h8M6 12h8"/><circle cx="2.8" cy="4" r=".7"/><circle cx="2.8" cy="8" r=".7"/><circle cx="2.8" cy="12" r=".7"/>',
  agent: '<circle cx="8" cy="5.5" r="2.7"/><path d="M2.8 14a5.2 5.2 0 0 1 10.4 0"/>',
  tabs: '<path d="M2 6.5h12v7H2zM2 6.5V3h5.5v3.5"/>',
  characters: '<rect x="2" y="2.5" width="5" height="11" rx="1"/><rect x="9" y="2.5" width="5" height="11" rx="1"/><circle cx="4.5" cy="6.5" r="1.3"/><circle cx="11.5" cy="6.5" r="1.3"/>',
  team: '<circle cx="6" cy="5.5" r="2.3"/><path d="M1.8 13.5a4.2 4.2 0 0 1 8.4 0M10.5 3.4a2.3 2.3 0 0 1 0 4.4M12 9.6a4.2 4.2 0 0 1 2.2 3.9"/>',
  combined: '<path d="M3 3h10a1.5 1.5 0 0 1 1.5 1.5v5.5a1.5 1.5 0 0 1-1.5 1.5H7.5L4.5 14v-2.5H3A1.5 1.5 0 0 1 1.5 10V4.5A1.5 1.5 0 0 1 3 3z"/>',
  workqueue: '<path d="M2.3 4.3l1.3 1.3 2.2-2.4M2.3 10.3l1.3 1.3 2.2-2.4M8 4.5h6M8 10.5h6"/>',
  daylog: '<rect x="2" y="3" width="12" height="11" rx="1.5"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/>',
  meeting: '<rect x="4" y="6" width="8" height="4" rx="2"/><circle cx="8" cy="2.8" r="1.3"/><circle cx="8" cy="13.2" r="1.3"/><circle cx="2.2" cy="8" r="1.3"/><circle cx="13.8" cy="8" r="1.3"/>',
  file: '<path d="M4 1.5h5.5L13 5v9.5H4z"/><path d="M9.5 1.5V5H13M6.2 8.5h4.6M6.2 11h4.6"/>',
  gauges: '<path d="M2.5 12a5.5 5.5 0 1 1 11 0"/><path d="M8 12l2.6-3.6"/>',
  perf: '<path d="M2.5 13.5h11M4.5 11V7.5M8 11V4M11.5 11V9"/>',
  machine: '<path d="M2.5 12a5.5 5.5 0 1 1 11 0"/><path d="M8 12l2.6-3.6"/>',
  splitrow: '<rect x="2" y="2.5" width="12" height="11" rx="1.5"/><path d="M8 2.5v11"/>',
  splitcol: '<rect x="2" y="2.5" width="12" height="11" rx="1.5"/><path d="M2 8h12"/>',
  tokens: '<ellipse cx="8" cy="4.5" rx="5" ry="2"/><path d="M3 4.5v7c0 1.1 2.2 2 5 2s5-.9 5-2v-7M3 8c0 1.1 2.2 2 5 2s5-.9 5-2"/>',
}).map(([k, d]) => [k, `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`]));
const ROLE_ORDER = ["lead", "dev", "tester", "hot", "ops", "support", "review", "process", "pa"];
// The views, kept in this browser: each a name, a kind (grid, tabs or custom) and, for a custom one, a layout, one of
// them showing ("at"). Grid and Tabs are the first two, and can be renamed or deleted like any other. A browser from
// before there were views starts with Grid, Tabs and its one layout (kept under "custom") as the view "Custom", on the
// one it showed ("page"). "page" stays the showing view's kind, which is what the rest of the page reads.
// A pane or tab saved as Gauges or Performance opens as the Machine view, on Gauges or Rows.
function oldMachine(n) {
  if (n.split) { oldMachine(n.a); oldMachine(n.b); return; }
  for (const t of [n, ...(n.tabs || [])]) if (t.show === "gauges" || t.show === "perf") { t.machine = t.show === "perf" ? "rows" : "gauges"; t.show = "machine"; }
}
function views() {
  let v; try { v = JSON.parse(localStorage.getItem("views")); } catch (e) {}
  if (!v?.views?.length) {
    let one, some; try { one = JSON.parse(localStorage.getItem("custom")); } catch (e) {}
    try { some = JSON.parse(localStorage.getItem("customs")); } catch (e) {}   // the custom views alone, as the page kept them a day
    const mine = some?.views?.length ? some.views : [{name: "Custom", layout: one || {root: {}}}], page = localStorage.getItem("page");
    v = {views: [{name: "Grid", kind: "grid"}, {name: "Tabs", kind: "tabs"}, ...mine.map(x => ({...x, kind: "custom"}))],
         at: page === "tabs" ? 1 : page === "custom" ? 2 + (some?.at | 0) : 0};
  }
  v.at = Math.min(Math.max(0, v.at | 0), v.views.length - 1);
  v.views.forEach(x => x.layout?.root && oldMachine(x.layout.root));
  return v;
}
const saveViews = v => { localStorage.setItem("views", JSON.stringify(v)); localStorage.setItem("page", v.views[v.at].kind); };
const shownView = () => { const v = views(); return v.views[v.at]; };
const layout = () => shownView().layout || {root: {}};
// The padlock is the whole page's (owner, 2026-11-01: "the padlock now belongs to the whole page"): unlocked, every
// view's bars and a custom view's panes can be changed. Until first clicked it keeps what the custom view's own lock was.
const pageLocked = () => { const s = localStorage.getItem("locked"); return s ? s === "1" : localStorage.getItem("page") !== "custom" || !!layout().locked; };
$("#lock").onclick = () => { localStorage.setItem("locked", pageLocked() ? "0" : "1"); draw(); };
// The header and the footer (owner, 2026-11-01: "make the header a panel, and later create a footer panel too"): each
// view keeps which of the bar's items sit in each, in order (its bar: head, foot, and off for those taken out), every
// item in the header until chosen, the footer empty. While a custom view's layout is unlocked an item is dragged within
// or between the two, taken out with its ✕ and put back with the Add at the end of either. The logo and the
// padlock have no ✕ (owner, 2026-11-01: "Icon is not optional"), so the page can always be locked and unlocked again,
// and anything taken out put back. A shortcut for an item out of the bars still works; a menu it opens opens from the logo.
// Week, Session, Team and Disk are the harness's own plug-ins (team/bar), drawn as any plug-in is, and in the bar by default.
const BAR_ITEMS = {brand: "Logo", week: "Week", session: "Session", team: "Team", disk: "Disk", tally: "Agents", bench: "Bench", favs: "Favourites", active: "Active",
  controls: "Start and stop", lanes: "Lanes", view: "Views", viewbar: "Views toolbar", lock: "Lock", theme: "Theme", settings: "Settings", help: "Help"};
// Spacers (owner, 2026-11-01, to right-align the footer's items) take the room left, so the items after one sit to
// the right; two, to centre a group. Dividers are a thin upright line between the items either side, taking no room
// of their own. Each is its own item, keyed by its kind and a number ("gap-3", "div-k2x"; "gap1" from before), made by
// the + menu's Spacer or Divider, which stay there to add another, and gone when its ✕ is clicked.
const FREE = /^(gap|div)(\d+|-[a-z0-9]+)$/;
const FREE_KINDS = {"new:gap": "Spacer", "new:div": "Divider"};
// The Views toolbar, every view as its icon in a row, the one showing marked, is out of the bar until added.
const BAR_SPARE = ["viewbar", "active"];
// Any other plug-in (S.plugins, the server's AGENT_BAR_PLUGINS scripts) is one more item, out of the bar until added.
const plugs = () => S?.plugins || [];
const BAR_FIXED = ["brand", "lock"];
const barName = k => { const x = plugs().find(x => x.key === k); return BAR_ITEMS[k] || FREE_KINDS[k] || x?.name || x?.label || k; };
// A plug-in that says where it goes (its place, header or footer) can be put only there (owner, 2026-11-01: "each
// plug-in can say header, footer or both").
const fits = (k, foot) => { const p = plugs().find(x => x.key === k)?.place; return !p || p === (foot ? "footer" : "header"); };
// One header and footer for the whole page, the same in every view (owner, 2026-11-01), kept in this browser as "bar".
// Until it is first changed, the bar the shown view kept when each view had its own.
function pageBar() { try { const b = JSON.parse(localStorage.getItem("bar")); if (b) return b; } catch (e) {} return shownView().bar || {}; }
function barOf() {
  const b = pageBar(), mine = Object.keys(BAR_ITEMS), all = [...new Set([...mine, ...plugs().map(x => x.key)])];
  const ok = k => all.includes(k) || FREE.test(k);
  const foot = (b.foot || []).filter(k => ok(k) && fits(k, true)), off = (b.off || []).filter(k => all.includes(k) && !BAR_FIXED.includes(k) && !foot.includes(k));
  const head = (b.head || []).filter(k => ok(k) && fits(k, false) && !foot.includes(k) && !off.includes(k)), placed = k => head.includes(k) || foot.includes(k) || off.includes(k);
  // a built-in the view has not placed yet (one new to the page) goes in after the one before it in the default order,
  // or at the footer's end if it can only go there
  for (const [i, k] of mine.entries()) if (BAR_SPARE.includes(k) && !placed(k)) off.push(k); else if (!placed(k)) fits(k, false) ? head.splice(head.indexOf(mine[i - 1]) + 1, 0, k) : foot.push(k);
  return {head, foot, off: [...new Set([...off, ...all.filter(k => !mine.includes(k) && !placed(k))])]};
}
// Each plug-in drawn as a stat: its label over its value, or with a meter or a sparkline, "Label: value" over it; its
// title on a rest. A colour is a CSS colour or one of the page's own by name.
// The icons a plug-in can show in place of its label (its icon), drawn as the menus' are.
const BAR_ICON = Object.fromEntries(Object.entries({
  week: '<rect x="2" y="3" width="12" height="11" rx="1.5"/><path d="M2 6.5h12M5.5 1.5v3M10.5 1.5v3"/>',
  day: '<circle cx="8" cy="8" r="2.8"/><path d="M8 1.5v1.6M8 12.9v1.6M1.5 8h1.6M12.9 8h1.6M3.4 3.4l1.1 1.1M11.5 11.5l1.1 1.1M3.4 12.6l1.1-1.1M11.5 4.5l1.1-1.1"/>',
  disk: '<rect x="1.5" y="4" width="13" height="8" rx="1.5"/><path d="M4 9.5h5"/><circle cx="11.8" cy="9.5" r=".7"/>',
  cpu: '<rect x="4" y="4" width="8" height="8" rx="1"/><rect x="6.2" y="6.2" width="3.6" height="3.6"/><path d="M6 1.8V4M10 1.8V4M6 12v2.2M10 12v2.2M1.8 6H4M1.8 10H4M12 6h2.2M12 10h2.2"/>',
  mem: '<rect x="1.5" y="4.5" width="13" height="6" rx="1"/><path d="M4 6.8v1.7M6.7 6.8v1.7M9.3 6.8v1.7M12 6.8v1.7M3.5 10.5v2M12.5 10.5v2"/>',
  net: '<path d="M5 13.5V3M2.5 5.5 5 3l2.5 2.5M11 2.5V13M8.5 10.5 11 13l2.5-2.5"/>',
  gpu: '<rect x="1.5" y="4" width="13" height="8" rx="1.5"/><circle cx="6" cy="8" r="2.2"/><path d="M10.5 6.5h2M10.5 9.5h2M3 12v2"/>',
  tok: '<path d="M9 1.5 3.5 9H8l-1 5.5L12.5 7H8z"/>',
  heat: '<path d="M6.5 2.6a1.5 1.5 0 0 1 3 0v6.5a3 3 0 1 1-3 0z"/><path d="M8 6.5v4"/>',
  fan: '<circle cx="8" cy="8" r="1.4"/><path d="M8 6.6C6.6 4.6 7 2 9 2.2s1.4 2.8-1 4.4M9.4 8.4c2.4-.4 4.6.8 4 2.7s-2.9 1-4-1.4M6.8 8.9c-1 2.2-3.3 3.4-4.4 1.8s.9-3 4.2-2.6"/>',
}).map(([k, d]) => [k, `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`]));
// Active: a pulse.
const ICON_ACTIVE = '<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="M1.5 8.5h3l2-5 3 9 2-4h3"/></svg>';
// Each item's icon in a bar's + menu: a built-in's own, a plug-in's icon (BAR_ICON), else a chart.
const ADD_ICON = Object.fromEntries(Object.entries({
  session: '<circle cx="8" cy="8" r="6"/><path d="M8 4.5V8l2.5 1.5"/>',
  bench: '<path d="M4 3.5h8v3.5M2 7h12M2 10.5h12M3.5 7v6M12.5 7v6"/>',
  viewbar: '<rect x="1.5" y="5" width="3.5" height="6" rx="1"/><rect x="6.25" y="5" width="3.5" height="6" rx="1"/><rect x="11" y="5" width="3.5" height="6" rx="1"/>',
  theme: '<circle cx="8" cy="8" r="6"/><path d="M8 2a6 6 0 0 0 0 12z" fill="currentColor"/>',
  settings: '<path d="M13.16 6.40 L14.90 6.82 L14.90 9.18 L13.16 9.60 L12.78 10.52 L13.72 12.04 L12.04 13.72 L10.52 12.78 L9.60 13.16 L9.18 14.90 L6.82 14.90 L6.40 13.16 L5.48 12.78 L3.96 13.72 L2.28 12.04 L3.22 10.52 L2.84 9.60 L1.10 9.18 L1.10 6.82 L2.84 6.40 L3.22 5.48 L2.28 3.96 L3.96 2.28 L5.48 3.22 L6.40 2.84 L6.82 1.10 L9.18 1.10 L9.60 2.84 L10.52 3.22 L12.04 2.28 L13.72 3.96 L12.78 5.48 Z"/><circle cx="8" cy="8" r="2.2"/>',
  help: '<circle cx="8" cy="8" r="6.2"/><path d="M6.2 6.3a1.9 1.9 0 1 1 2.6 1.8c-.5.2-.8.6-.8 1.1v.4"/><circle cx="8" cy="11.6" r=".4"/>',
  "new:div": '<path d="M8 2v12"/>',
  "new:gap": '<path d="M2 8h12M4.5 5.5 2 8l2.5 2.5M11.5 5.5 14 8l-2.5 2.5"/>',
}).map(([k, d]) => [k, `<svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">${d}</svg>`]));
Object.assign(ADD_ICON, {favs: MENU_ICON.star, active: ICON_ACTIVE, week: BAR_ICON.week, team: BAR_ICON.tok, disk: BAR_ICON.disk, tally: MENU_ICON.team, controls: MENU_ICON.start,
  lanes: MENU_ICON.filter, view: MENU_ICON.grid});
const addIcon = k => ADD_ICON[k] || BAR_ICON[plugs().find(x => x.key === k)?.icon] || MENU_ICON.chart;
const PLUG_COLOUR = {green: "var(--green)", amber: "var(--amber)", red: "var(--red)", text: "var(--text)", faint: "var(--faint)"};
const plugColour = c => PLUG_COLOUR[c] || c || "";
// A plug-in's meter fill, the same in the bar, the phone's header gauge and its Dashboard: the colour the plug-in gives, else green
const meterFill = m => m.colour ? plugColour(m.colour) : "linear-gradient(90deg,#2ea043,#3fb950)";
function drawPlugs() {
  const keys = plugs().map(x => x.key);
  document.querySelectorAll(".bi.plug").forEach(e => keys.includes(e.dataset.item) || e.remove());
  for (const x of plugs()) {
    if (!$(`.bi[data-item="${x.key}"]`)) $("#barbin").insertAdjacentHTML("beforeend", `<div class="bi plug" data-item="${esc(x.key)}"><div class="stat">` +
      `<div class="k"><span class="lab"></span><span class="kv"></span></div><div class="v"></div><div class="meter"><i></i><u></u></div><div class="pspark"></div></div>` +
      (BAR_FIXED.includes(x.key) ? "" : `<i class="bx" title="Take this out of the bar">✕</i>`) + `</div>`);
    const e = $(`.bi[data-item="${x.key}"]`), st = e.querySelector(".stat"), m = x.meter, inline = !!(m || x.spark);
    st.style.display = x.hidden ? "none" : "";
    st.title = x.title;
    const icon = x.slim && BAR_ICON[x.icon];
    st.classList.toggle("slim", !!x.slim); st.classList.toggle("ico", !!icon);
    const parts = (x.parts || [{text: x.value, colour: x.colour}]).filter(p => p.text !== "");
    const els = parts.map(p => { const b = document.createElement(p.bold ? "b" : "span"); b.textContent = p.text; b.style.color = plugColour(p.colour || (x.parts ? "" : x.colour)); return b; });
    const lab = e.querySelector(".lab");
    if (icon) { if (lab.dataset.icon !== x.icon) { lab.dataset.icon = x.icon; lab.innerHTML = icon; } }
    else { delete lab.dataset.icon; lab.textContent = x.label; }
    e.querySelector(".kv").replaceChildren(...(inline && els.length ? [...(x.label && !icon ? [": "] : []), ...els] : []));
    e.querySelector(".k").style.display = icon || x.label || inline && els.length ? "" : "none";
    e.querySelector(".v").replaceChildren(...(inline ? [] : els));
    e.querySelector(".v").style.display = inline ? "none" : "";
    const mt = e.querySelector(".meter");
    mt.style.display = m ? "" : "none";
    if (m) {
      mt.querySelector("i").style.cssText = `width:${m.pct}%;background:${meterFill(m)}`;
      mt.querySelector("u").style.cssText = m.mark == null ? "display:none" : `left:calc(${m.mark}% - 1px)`;
    }
    const sp = e.querySelector(".pspark"), was = sp.dataset.s, now = x.spark ? x.spark.join() : "";
    sp.style.display = x.spark ? "" : "none";
    if (was !== now) { sp.dataset.s = now; sp.innerHTML = x.spark ? spark(x.spark, Math.max(1, ...x.spark), "currentColor") : ""; }
  }
}
const saveBar = b => { try { localStorage.setItem("bar", JSON.stringify(b)); } catch (e) {} };
const barEditing = () => !pageLocked();
function placeBar() {
  drawPlugs();
  const b = barOf(), edit = barEditing(), free = [...b.head, ...b.foot].filter(k => FREE.test(k));
  document.querySelectorAll(".bi.gap, .bi.div").forEach(e => free.includes(e.dataset.item) || e.remove());
  for (const k of free) if (!$(`.bi[data-item="${k}"]`)) $("#barbin").insertAdjacentHTML("beforeend",
    `<div class="bi ${k.startsWith("gap") ? "gap" : "div"}" data-item="${k}"><i class="bx" title="Take this out of the bar">✕</i></div>`);
  for (const [box, keys] of [[$("header"), b.head], [$("footer"), b.foot], [$("#barbin"), b.off]]) {
    if ([...box.querySelectorAll(":scope > .bi")].map(e => e.dataset.item).join() !== keys.join())
      for (const k of keys) if ($(`.bi[data-item="${k}"]`)) box.insertBefore($(`.bi[data-item="${k}"]`), box.querySelector(":scope > .barplus"));
    if (box.id !== "barbin") box.classList.toggle("editing", edit);
    box.querySelectorAll(":scope > .bi").forEach(e => e.draggable = edit && box.id !== "barbin");
    // the items out of the bars A to Z (owner, 2026-11-01), then Divider and Spacer, last
    const can = [...b.off.filter(k => fits(k, box.tagName === "FOOTER"))
      .sort((x, y) => barName(x).localeCompare(barName(y), undefined, {numeric: true, sensitivity: "base"})), ...Object.keys(FREE_KINDS).sort()];
    const plus = box.querySelector(":scope > .barplus"), want = edit && box.id !== "barbin" && can.length ? can.join() : "";
    if (plus && plus.dataset.k !== want) plus.remove();
    if (want && plus?.dataset.k !== want) box.insertAdjacentHTML("beforeend", `<button class="barplus" data-k="${want}" title="Add an item">${MENU_ICON.plus}</button>`);
  }
  // bare: nothing in it shows, only spacers, dividers or items hidden for now (Disk with nothing to watch). Read once every
  // item has moved: an item on its way out of a bar would keep it showing, empty, until the next placement.
  for (const box of [$("header"), $("footer")]) box.classList.toggle("bare", ![...box.querySelectorAll(":scope > .bi:not(.gap, .div)")].some(e => e.firstElementChild?.style.display !== "none"));
}
document.addEventListener("click", e => {
  const x = e.target.closest(".editing > .bi > .bx");
  if (!x) return;
  e.stopPropagation(); e.preventDefault();
  const b = barOf(), k = x.parentElement.dataset.item;
  saveBar({head: b.head.filter(i => i !== k), foot: b.foot.filter(i => i !== k), off: FREE.test(k) ? b.off : [...b.off, k]}); draw();
}, true);
// a bar's + opens a menu of the items it can take, A to Z, then a line and Divider and Spacer; a click on one puts it
// at the end of that bar
document.addEventListener("click", e => {
  const s = e.target.closest?.(".barplus");
  if (!s) return;
  e.stopPropagation();
  const foot = !!s.closest("footer"), key = "barplus:" + (foot ? "foot" : "head");
  if (menuOn(key)) return menuOff(true);
  const ks = s.dataset.k.split(",");
  menuAt(s, key, `<div class="hd"><div>Add</div></div>` +
    ks.map((k, i) => (FREE_KINDS[k] && i && !FREE_KINDS[ks[i - 1]] ? `<div class="sep"></div>` : "") +
      `<div class="mi" data-k="${esc(k)}">${addIcon(k)}${esc(barName(k))}</div>`).join(""), false);
  menu.querySelectorAll(".mi").forEach(mi => mi.onclick = () => {
    const b = barOf(), kind = FREE_KINDS[mi.dataset.k] && mi.dataset.k.slice(4), k = kind ? `${kind}-${Date.now().toString(36)}` : mi.dataset.k;
    menuOff(true);
    saveBar({head: foot ? b.head : [...b.head, k], foot: foot ? [...b.foot, k] : b.foot, off: b.off.filter(i => i !== k)}); draw();
  });
});
// a dragged item moves as the pointer does, before the item whose middle it is short of, and is kept where it is let go
let barDrag = null;
document.addEventListener("dragstart", e => {
  const b = e.target.closest?.(".editing > .bi");
  if (!b) return;
  barDrag = b; b.classList.add("dragging"); e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", "");
});
// whether the dragged item may go where the pointer is, having moved it there if so
function barOver(target, x, y) {
  const box = barDrag && target?.closest?.("header.editing, footer.editing");
  refuseIn(box && !fits(barDrag.dataset.item, box.tagName === "FOOTER") ? box : null);
  if (!box || box.classList.contains("refuse")) return false;
  // a bar wraps on a narrow screen: an item on a later row is not short of the pointer, whatever its left
  const at = [...box.querySelectorAll(":scope > .bi:not(.dragging)")].find(b => { const r = b.getBoundingClientRect();
    return y < r.top || y < r.bottom && x < r.left + r.width / 2; });
  const to = at || box.querySelector(":scope > .barplus");
  if (barDrag.parentElement !== box || barDrag.nextElementSibling !== to) box.insertBefore(barDrag, to);
  return true;
}
// the bar under the dragged item that it cannot go in, crossed out and saying why; none clears it
function refuseIn(box) {
  document.querySelectorAll("header.refuse, footer.refuse").forEach(b => b !== box && b.classList.remove("refuse"));
  if (!box) return;
  const foot = box.tagName === "FOOTER";
  box.dataset.refuse = `${barName(barDrag.dataset.item)} goes only in the ${foot ? "header" : "footer"}` + (foot && plugs().some(x => x.name === barName(barDrag.dataset.item) + " bar") ? `: add ${barName(barDrag.dataset.item)} bar from the footer's +` : "");
  box.classList.add("refuse");
}
function barDropped() {
  refuseIn(null);
  if (!barDrag) return;
  barDrag.classList.remove("dragging"); barDrag = null;
  const keys = sel => [...$(sel).querySelectorAll(":scope > .bi")].map(x => x.dataset.item);
  saveBar({head: keys("header"), foot: keys("footer"), off: barOf().off}); draw();
}
document.addEventListener("dragover", e => { if (barOver(e.target, e.clientX, e.clientY)) e.preventDefault(); });
document.addEventListener("drop", e => { if (barDrag) e.preventDefault(); });
document.addEventListener("dragend", barDropped);
// a finger: a phone starts no drag from a touch, so the item follows the touch itself (owner, 2026-11-01: "drag and
// drop not working with touch")
document.addEventListener("pointerdown", e => {
  const b = e.pointerType === "touch" && !e.target.closest(".bx, select") && e.target.closest(".editing > .bi");
  if (!b || b.closest("#barbin")) return;
  // a tap stays a tap (the padlock, the theme): the drag starts once the finger has moved, and then what it is let go
  // over is not clicked. It is followed from the document: moving the item in the page would drop a capture held on it.
  let moved = false;
  const move = m => {
    if (m.pointerId !== e.pointerId) return;
    if (!moved && Math.hypot(m.clientX - e.clientX, m.clientY - e.clientY) < 8) return;
    if (!moved) { moved = true; barDrag = b; b.classList.add("dragging"); }
    barOver(document.elementFromPoint(m.clientX, m.clientY), m.clientX, m.clientY);
  };
  const up = u => { if (u.pointerId !== e.pointerId) return;
    document.removeEventListener("pointermove", move); document.removeEventListener("pointerup", up); document.removeEventListener("pointercancel", up);
    if (!moved) return;
    const stop = c => { c.stopPropagation(); c.preventDefault(); };   // the click a lift can end in, if any comes
    document.addEventListener("click", stop, {capture: true, once: true});
    setTimeout(() => document.removeEventListener("click", stop, true), 400);
    barDropped(); };
  document.addEventListener("pointermove", move); document.addEventListener("pointerup", up); document.addEventListener("pointercancel", up);
});
const saveLayout = l => { const v = views(); v.views[v.at].layout = l; saveViews(v); };
// A message box is given the cursor only on a big screen: on a phone it would bring up the keyboard, which crushes
// the view (owner, 2026-11-01: "on a small screen the input box should never take focus"). Where the owner chose to
// type (a rename, a question's own box, a command picked into the box) the cursor still goes.
const small = () => matchMedia("(max-width:700px), (pointer:coarse)").matches;
const aim = el => { if (el && !small()) el.focus(); };
function nodeAt(root, path) { let n = root; for (const c of path.slice(1)) n = n[c]; return n; }
function putAt(l, path, node) { if (path === "r") l.root = node; else nodeAt(l.root, path.slice(0, -1))[path.slice(-1)] = node; }
function leaves(n, path = "r", out = []) { if (n.split) { leaves(n.a, path + "a", out); leaves(n.b, path + "b", out); } else out.push([path, n]); return out; }
function roleList() {
  const seen = {};
  for (const a of [...S.agents, ...S.bench]) seen[a.role] ??= {role: a.role, name: a.roleName || a.role, colour: a.colour};
  return Object.values(seen).sort((x, y) => (ROLE_ORDER.indexOf(x.role) + 1 || 99) - (ROLE_ORDER.indexOf(y.role) + 1 || 99));
}
// A grid, tabs or Combined pane's agents, role by role in the order the roles were picked (see rolesOn), A to Z
// within a role.
const byName = (x, y) => x.name.localeCompare(y.name, undefined, {sensitivity: "base"});
const paneAgents = n => PICK_VIEWS.includes(n.show) && Array.isArray(n.pick) ? byRole(S.agents.filter(a => n.pick.includes(a.name)))
  : rolesOn(n).flatMap(r => S.agents.filter(a => a.role === r).sort(byName));
// Agent tabs and Combined show the agents picked by name (n.pick), or, in a layout saved before, by role (n.roles), or
// all. Agents left out do not show.
const PICK_VIEWS = ["tabs", "combined"];
const inPick = (n, a) => Array.isArray(n.pick) ? n.pick.includes(a.name) : rolesOn(n).includes(a.role);
const pickedAny = n => Array.isArray(n.pick) || rolesPicked(n).length > 0;
// a role's chip on Agent tabs or Combined takes in all of that role (that role alone, from All), or leaves them all out
function pickRole(n, r) {
  const now = S.agents.filter(a => inPick(n, a)).map(a => a.name), them = S.agents.filter(a => a.role === r).map(a => a.name);
  const next = !r ? [] : !pickedAny(n) ? them : them.every(x => now.includes(x)) ? now.filter(x => !them.includes(x)) : [...new Set([...now, ...them])];
  delete n.roles;
  if (!next.length || S.agents.every(a => next.includes(a.name))) delete n.pick; else n.pick = next;
}
// A Meeting pane: those in the meeting along its top, role by role and A to Z within each, over what was said and the
// meeting's message box. Nobody along the top is picked to be talked to alone (owner, 2026-11-01: "I don't want to
// message a single agent in a meeting - that's not how meetings work"); a rest on one still shows its menu. Who is
// invited (n.who, "name:<agent>" keys, and "role:<role>" in a layout saved before, chosen with the meeting's chips and
// portraits while the layout is unlocked) is the whole team until chosen.
const byRole = list => [...list].sort((x, y) => ((ROLE_ORDER.indexOf(x.role) + 1 || 99) - (ROLE_ORDER.indexOf(y.role) + 1 || 99)) || byName(x, y));
const inMeeting = (n, a) => !Array.isArray(n.who) || n.who.includes("role:" + a.role) || n.who.includes("name:" + a.name);
// A meeting (owner, 2026-11-03) is the owner and the agents in it, every line said going to everyone; each agent
// attends through a meeting session of its own, which speaks with meeting-say (the server's meetings). The pane keeps
// the meeting it shows (n.meeting) and reads it from /api/meetings with every load while a Meeting pane is on the page.
const MEET = "~meeting:";
let dayLog = null;
async function loadDayLog() {
  if (!leaves(layout().root).some(([, n]) => n.show === "daylog")) return;
  try { dayLog = await (await fetch("/api/daylog", {cache: "no-store"})).json(); } catch (e) {}
}
const dayLogAt = at => { const d = new Date(at * 1000);
  return `${d.toLocaleDateString("en-GB", {weekday: "short"})} ${d.getDate()}, ${d.toLocaleTimeString("en-GB", {hour: "2-digit", minute: "2-digit"})}`; };
// A row's icon, by its kind: the kind of day it starts, or the word an entry's program gives it (a PR's ticket name opens
// with it in the harness's log). Hovering says it in words; a program's own "kinds" name the ones not here.
const DAY_LOG_ICONS = {
  development: ["Development day", "The team builds until the day's share of the week is spent.", '<path d="M5.5 4 1.5 8l4 4M10.5 4l4 4-4 4"/>'],
  verification: ["Verification day", "The full suite runs on main, and is fixed until it is green.", '<circle cx="7" cy="7" r="4.5"/><path d="M10.4 10.4 14.5 14.5"/>'],
  fix: ["Bug fix", "Something was wrong, and this PR puts it right.", '<ellipse cx="8" cy="9.5" rx="3.5" ry="4.5"/><path d="M6 5.6 4.5 3.5M10 5.6l1.5-2.1M4.5 8.5H2M11.5 8.5H14M4.8 11.5 2.8 13M11.2 11.5l2 1.5M8 5.5V14"/>'],
  feat: ["Feature", "Something new that the product can do.", '<path d="M8 1.5 9.6 6.4 14.5 8 9.6 9.6 8 14.5 6.4 9.6 1.5 8 6.4 6.4Z"/>'],
  infra: ["Infrastructure", "The scripts, checks and machinery behind the product.", '<rect x="2" y="2.5" width="12" height="4.5" rx="1"/><rect x="2" y="9" width="12" height="4.5" rx="1"/><path d="M4.5 4.75h.01M4.5 11.25h.01"/>'],
  docs: ["Documentation", "Written guidance rather than working code.", '<path d="M9.5 1.5H4a1 1 0 0 0-1 1v11a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1V5Z"/><path d="M9.5 1.5V5H13M5.5 8.5h5M5.5 11.5h5"/>'],
  ticket: ["Ticket raised", "", '<rect x="2" y="3.5" width="12" height="9" rx="1.5"/><path d="M5 7h6M5 9.5h3.5"/>'],
  started: ["Started", "", '<path d="M5 3.2v9.6L12.8 8z"/>'],
  pr: ["PR raised", "", '<circle cx="4.5" cy="3.5" r="1.6"/><circle cx="4.5" cy="12.5" r="1.6"/><circle cx="11.5" cy="12.5" r="1.6"/><path d="M4.5 5.1v5.8M11.5 10.9V7a2.5 2.5 0 0 0-2.5-2.5H7M8.5 3l-1.5 1.5L8.5 6"/>'],
  merged: ["Merged", "", '<circle cx="4.5" cy="3.5" r="1.6"/><circle cx="4.5" cy="12.5" r="1.6"/><circle cx="11.5" cy="8" r="1.6"/><path d="M4.5 5.1v5.8M4.5 5.5c0 2.5 2.5 2.5 5.4 2.5"/>'],
  released: ["Released", "", '<path d="M9 2.5c2.5 0 4.5 2 4.5 4.5L9.5 11 5 6.5 9 2.5zM5 6.5 2.5 7l1.5 1.5M9.5 11l-.5 2.5-1.5-1.5M3.5 12.5l1.5-1.5"/>'],
  done: ["Done", "", '<circle cx="8" cy="8" r="6"/><path d="M5.3 8.2 7.2 10l3.5-4"/>'],
  note: ["Note", "", '<path d="M3 2.5h10v8l-3 3H3z"/><path d="M10 13.5v-3h3M5.5 6h5M5.5 8.5h3"/>'],
  chore: ["Housekeeping", "Upkeep that changes nothing for the people using the product.", '<path d="M14 2 8.5 7.5"/><path d="M6.5 6.2 9.8 9.5C9.5 11.5 8.5 13 7 14 4.8 13.5 3 12 2 9.8 4 9.5 5.5 8.2 6.5 6.2Z"/>'],
};
// A click on an icon says what it means and a second click, or one elsewhere, closes it. dayLogTip is the open row's key,
// so that a redraw of the pane draws it open again.
let dayLogTip = "";
const dayLogKind = kind => {
  const own = DAY_LOG_ICONS[kind] || [], k = dayLog?.kinds?.[kind] || {};
  return [k.name || own[0] || kind || "Other", k.about || own[1] || "", own[2] || '<path d="M8 3.5 12.5 8 8 12.5 3.5 8Z"/>'];
};
const dayLogDesc = kind => {
  const [what, more] = dayLogKind(kind);
  return `<span class="desc"><b>${esc(what)}</b> ${esc(more)}</span>`;
};
const dayLogIcon = (kind, key) => {
  const [what, , d] = dayLogKind(kind);
  return `<span class="ico" role="button" title="${esc(what)}" data-kind="${esc(kind || "")}" data-key="${esc(key)}"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">${d}</svg>${dayLogTip === key ? dayLogDesc(kind) : ""}</span>`;
};
document.addEventListener("click", e => {
  const i = e.target.closest(".daylog .ico"), was = dayLogTip;
  if (!i && !was) return;
  document.querySelectorAll(".daylog .desc").forEach(x => x.remove());
  dayLogTip = i && i.dataset.key !== was ? i.dataset.key : "";
  if (i && dayLogTip) i.insertAdjacentHTML("beforeend", dayLogDesc(i.dataset.kind));
});
// A person's badge, as in the other views: their colour, or an outline for a name the page has no colour for.
const dayLogWho = by => {
  const c = colours[by];
  return `<span class="wh">${by ? `<span class="who${c ? "" : " off"}"${c ? ` style="--pc:${esc(c)}"` : ""}>${esc(shown(by))}</span>` : ""}</span>`;
};
// The pane draws what the server's program printed (see "the day log" there); with no program it says what one must print.
// The badge column is as wide as the widest name it shows (full names run long), measured in the badge's own font, so
// no badge runs into the time beside it and every row's time still starts in one column.
let dayLogCanvas;
const dayLogWhW = names => {
  const c = dayLogCanvas ||= document.createElement("canvas").getContext("2d");
  c.font = `650 10.5px ${getComputedStyle(document.body).fontFamily}`;
  return Math.ceil(Math.max(50, ...names.map(n => c.measureText(n).width + n.length * 0.21))) + 14;
};
// An entry's time, its day being the heading it sits under; who did it, from the log, or the releaser a release names,
// or else the system.
const dayLogTime = at => new Date(at * 1000).toLocaleTimeString("en-GB", {hour: "2-digit", minute: "2-digit"});
const dayLogBy = r => r.by || r.text?.match(/^Released by ([A-Z][\w-]*)/)?.[1] || "System";
// A Day log's own filters beside its role chips: the kinds of entry (n.kinds, every kind while none is picked) as chips
// with their icons, and a ticket (n.ticket), matched in its link's name or its words.
const dayLogFilters = n => { const on = Array.isArray(n.kinds) ? n.kinds : [], kinds = [...new Set((dayLog?.rows || []).filter(r => r.type !== "day").map(r => r.kind))];
  return `<span class="kchips"><b class="chip${on.length ? "" : " on"}" data-kind="" title="Every kind of entry">All types</b>${kinds.map(k => { const [what, , d] = dayLogKind(k);
    return `<b class="chip${on.includes(k) ? " on" : ""}" data-kind="${esc(k)}" title="Show or leave out: ${esc(what)}"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round">${d}</svg>${esc(what)}</b>`; }).join("")}</span>` +
    `<input data-act="ticket" class="tfilter" value="${esc(n.ticket || "")}" placeholder="Ticket" spellcheck="false" title="Only this ticket's entries: Enter to apply, empty for all">`; };
const dayLogKeep = (n, r) => byRoles(n, dayLogBy(r)) && (!Array.isArray(n?.kinds) || !n.kinds.length || n.kinds.includes(r.kind))
  && (!n?.ticket || `${r.label || ""} ${r.text || ""}`.toLowerCase().includes(n.ticket.toLowerCase()));
function dayLogHtml(n) {
  if (!dayLog) return `<div class="blank">Loading…</div>`;
  if (dayLog.state === "unset") return `<div class="blank">The Day log shows what a program prints, and there is none at ${esc(dayLog.program)}. Set AGENTS_DAY_LOG to a program that prints {"rows": [{"at", "type": "day" or "entry", "kind", "by", "text", "url", "label"}]} as JSON: see "the day log" in agents_web.py.</div>`;
  const notes = [dayLog.state === "failed" && `The Day log's program failed (${dayLog.error}), so this is what it last printed.`,
    dayLog.state === "reading" && "Reading the log…", dayLog.note].filter(Boolean).map(n => `<div class="note">${esc(n)}</div>`).join("");
  if (!dayLog.rows.length) return dayLog.state === "ok" ? `<div class="blank">${esc(dayLog.empty || "Nothing in the log yet")}</div>` : `<div class="daylog">${notes}</div>`;
  // a day heading stays while an entry under it does
  const rows = dayLog.rows.filter(r => r.type === "day" || dayLogKeep(n, r)).filter((r, i, all) => r.type !== "day" || (all[i + 1] && all[i + 1].type !== "day"));
  const days = dayLog.rows.filter(r => r.type === "day").length, entries = dayLog.rows.length - days;
  const sum = dayLog.summary || `${days} day${days === 1 ? "" : "s"}, ${entries} entr${entries === 1 ? "y" : "ies"}`;
  return `<div class="teamlog"><div class="thead"><span class="tsum">${esc(sum)}</span></div><div class="daylog" style="--whw:${dayLogWhW(rows.filter(r => r.type !== "day").map(r => shown(dayLogBy(r))))}px">${notes}${rows.map((r, i) => r.type === "day"
    ? (r.kind ? `<div class="row day ${esc(r.kind)}">${dayLogWho(r.by)}<span class="at">${dayLogAt(r.at)}</span><span class="tx">${esc(r.text)}</span>${dayLogIcon(r.kind, "d" + r.at)}</div>`
      : `<div class="row day"><span class="tx">${esc(r.text)}</span></div>`)   // a day of no kind is a plain calendar day: its name alone
    : `<div class="row">${dayLogWho(dayLogBy(r))}<span class="at">${dayLogTime(r.at)}</span>${dayLogIcon(r.kind, "e" + r.at + ":" + i)}${r.url ? `<a href="${esc(r.url)}" target="_blank" rel="noopener">${esc(r.label || "Open")}</a>` : r.label ? `<span>${esc(r.label)}</span>` : ""}<span class="tx">${esc(r.text)}</span></div>`).join("")}</div></div>`;
}
// The Token usage pane (owner, 2026-11-11): each agent's weighted tokens by day (see "token usage" on the server), in a
// box for each week, newest first, as the Work queue's sections: an agent a row in its colour, Monday to Sunday the
// columns, with each row's and each day's total. A cell's title has its calls, the messages it sent and the four token
// counts. A week folds under its ^ as a Work queue section does (its key "tokens:<Monday>").
let tokens = null;
async function loadTokens() {
  if (!leaves(layout().root).some(([, n]) => n.show === "tokens")) return;
  try { tokens = await (await fetch("/api/tokens", {cache: "no-store"})).json(); } catch (e) {}
}
function tokensHtml(big, n) {
  const pane = body => `<div class="teamlog" data-name="~tokens"><div class="thead"><span class="tsum">Weighted tokens a day, UTC days</span>${maxButton(big)}</div>${body}</div>`;
  if (!tokens || (tokens.state === "reading" && !tokens.agents.length)) return pane(`<div class="blank">Reading the conversations…</div>`);
  if (!tokens.agents.length) return pane(`<div class="blank">No tokens used in the last ${tokens.days.length} days</div>`);
  const sum = (xs, f) => xs.reduce((t, x) => t + (f(x) || 0), 0), at = d => new Date(d + "T12:00:00Z");
  const plus = (d, n) => { const t = at(d); t.setUTCDate(t.getUTCDate() + n); return t.toISOString().slice(0, 10); };
  const label = (d, o) => at(d).toLocaleDateString("en-GB", {timeZone: "UTC", ...o});
  const tip = (who, day, c) => c ? `${who}, ${label(day, {weekday: "short"})} ${at(day).getUTCDate()} ${label(day, {month: "short"})}: ${k(c.w)} weighted\n${c.calls} calls, ${c.sent} messages sent\nfresh in ${k(c.in)}, cache write ${k(c.cw)}, cache read ${k(c.cr)}, out ${k(c.out)}` : "";
  const shownK = n => n ? k(n) : "";
  const weeks = tokens.days.filter(d => at(d).getUTCDay() === 1).reverse(), today = new Date().toISOString().slice(0, 10);
  // a box of seven days: the last seven, ending today (owner, 2026-11-12: "just the rolling last 7 days"), or a week;
  // today's column is marked by a border either side
  const box = (days, title, key, allowance) => {
    const them = tokens.agents.filter(a => byRoles(n, a.name) && days.some(d => a.days[d]));
    const total = sum(them, a => sum(days, d => a.days[d]?.w)), fold = wqFolded().includes(key);
    const now1 = d => d === today ? ' class="today"' : "";
    // each agent's day shaded by its share of the week's heaviest agent-day, so heavy days stand out
    const top = Math.max(1, ...them.flatMap(a => days.map(d => a.days[d]?.w || 0)));
    const shade = v => v ? ` style="background:color-mix(in srgb, var(--amber) ${Math.round(6 + 44 * v / top)}%, transparent)"` : "";
    // the week showing now, with the account's share of its weekly allowance used (the toolbar's WEEK)
    const now = allowance && days.includes(today) && S?.week != null ? ` · ${Math.round(S.week)}% of the weekly allowance used` : "";
    const head = `<tr><th></th>${days.map(d => `<th${now1(d)}>${label(d, {weekday: "short"})}<br>${at(d).getUTCDate()}</th>`).join("")}<th>Total</th></tr>`;
    const rows = them.map(a => `<tr><td><span class="who" style="--pc:${esc(colours[a.name] || "#888")}" data-name="${esc(a.name)}">${esc(shown(a.name))}</span></td>` +
      days.map(d => `<td${now1(d)} title="${esc(tip(shown(a.name), d, a.days[d]))}"${shade(a.days[d]?.w)}>${shownK(a.days[d]?.w)}</td>`).join("") +
      `<td class="tot" title="${sum(days, d => a.days[d]?.sent)} messages sent">${k(sum(days, d => a.days[d]?.w))}</td></tr>`).join("");
    const foot = `<tr class="tot"><td>Total</td>${days.map(d => `<td${now1(d)}>${shownK(sum(them, a => a.days[d]?.w))}</td>`).join("")}<td>${k(total)}</td></tr>`;
    return `<div class="sect${fold ? " shut" : ""}"><div class="day">${title}<span class="n">${k(total)}${now}</span>` +
      `<b class="wqfold" data-sect="${esc(key)}" title="${fold ? "Show these days" : "Hide these days"}">${foldIcon(fold)}</b></div>` +
      (fold ? "" : them.length ? `<div class="tokens"><table>${head}${rows}${foot}</table></div>` : `<div class="row none">No tokens used</div>`) + `</div>`;
  };
  const last7 = box([6, 5, 4, 3, 2, 1, 0].map(i => plus(today, -i)), "Last 7 days", "tokens:last7", false);
  const week = mon => box([0, 1, 2, 3, 4, 5, 6].map(i => plus(mon, i)), `Week of ${label(mon, {weekday: "short"})} ${at(mon).getUTCDate()} ${label(mon, {month: "short"})}`, "tokens:" + mon, true);
  return pane(`<div class="daylog workq">${last7}${weeks.map(week).join("")}</div>`);
}
// The Work queue pane: the work to start, Now, Next and Later, and Parked, as the delivery lead keeps it with
// team/work-queue.py (see "the work queue" on the server), on a Doing tab, and what is Done on a second tab, split by
// stand-up. Titles and notes are Markdown, as an agent's words are: `code`, **bold**, web addresses and document
// paths. Read with every load while a Work queue pane is on the page. Which tab shows is the browser's, for every
// Work queue pane.
let workQueue = null;
const wqTab = () => localStorage.getItem("workqueue:tab") === "done" ? "done" : "work";
document.addEventListener("click", e => {
  const b = e.target.closest(".wqtabs b[data-tab]");
  if (!b || b.dataset.tab === wqTab()) return;
  localStorage.setItem("workqueue:tab", b.dataset.tab);
  phoneOn() ? phoneDraw() : draw();
});
// Done split by stand-up, newest first: what is done since the last stand-up, then what each of the two stand-ups
// before it covered (the owner, 2026-11-10: "it needs to be split by stand up, not calendar day"). The stand-up times
// are the server's, from the stand-up log; with none, Done is one list.
function doneByStandup(items, standups) {
  const newest = [...items].sort((x, y) => (y.done || 0) - (x.done || 0)), [s0, s1, s2] = standups || [];
  if (!s0) return [["Done", newest]];
  const day = t => new Date(t * 1000).toLocaleDateString("en-GB", {weekday: "long"}) + "'s stand-up";
  const between = (from, to) => newest.filter(i => (i.done || 0) >= (from || 0) && (to == null || (i.done || 0) < to));
  return [["Since " + day(s0), between(s0)], ...(s1 ? [[day(s0), between(s1, s0)]] : []), ...(s1 && s2 ? [[day(s1), between(s2, s1)]] : [])];
}
// Each section folds to its heading under its ^ and opens again under its v, kept per tab and section name in this browser.
const wqFolded = () => { try { return JSON.parse(localStorage.getItem("workqueue:folded")) || []; } catch (e) { return []; } };
document.addEventListener("click", e => {
  const b = e.target.closest(".wqfold");
  if (!b) return;
  const k = b.dataset.sect, f = wqFolded();
  try { localStorage.setItem("workqueue:folded", JSON.stringify(f.includes(k) ? f.filter(x => x !== k) : [...f, k])); } catch (e) {}
  phoneOn() ? phoneDraw() : draw();
});
async function loadWorkQueue() {
  if (!leaves(layout().root).some(([, n]) => n.show === "workqueue")) return;
  try { workQueue = await (await fetch("/api/workqueue", {cache: "no-store"})).json(); } catch (e) {}
}
// The id column is as wide as the longest id, measured in the row's font, so every title starts in one column.
const workQueueKeyW = keys => {
  const c = dayLogCanvas ||= document.createElement("canvas").getContext("2d");
  c.font = `${13 * (parseFloat(getComputedStyle(document.body).getPropertyValue("--fs")) || 1)}px ${getComputedStyle(document.body).fontFamily}`;
  return Math.ceil(Math.max(60, ...keys.map(k => c.measureText(k).width))) + 2;
};
function workQueueHtml(big, n) {
  const q = workQueue;
  if (!q) return `<div class="blank">Loading…</div>`;
  const done = wqTab() === "done", tabs = `<span class="seg wqtabs">${[["work", "Doing"], ["done", "Done"]].map(([v, label]) =>
    `<b data-tab="${v}" class="${(v === "done") === done ? "on" : ""}">${label}</b>`).join("")}</span>`;
  const pane = (head, body) => `<div class="teamlog" data-name="~workqueue"><div class="thead">${tabs}<span>${esc(head)}</span>${maxButton(big)}</div>${body}</div>`;
  if (q.state === "bad") return pane("", `<div class="blank">The work queue at ${esc(q.file)} cannot be read. The delivery lead keeps it with team/work-queue.py.</div>`);
  q.later ||= []; q.parked ||= []; q.done ||= [];
  const hhmm = t => new Date(t * 1000).toLocaleTimeString("en-GB", {hour: "2-digit", minute: "2-digit"});
  const isToday = t => new Date(t * 1000).toDateString() === new Date().toDateString();
  const when = q.at ? (isToday(q.at) ? hhmm(q.at) : dayLogAt(q.at)) : "";
  const head = (when ? `Updated ${when}${q.by ? ` by ${shown(q.by)}` : ""}` : "") + (n?.owner ? ` · only ${shown(n.owner)}'s: click the badge again for everyone's` : "");
  // a pane can be narrowed to one owner (n.owner) by a click on their badge, and a second click widens it again. Role
  // chips narrow it to the picked roles' items, but work no agent owns (unassigned, or the owner's) always stays.
  const owner = n?.owner, mine = items => items.filter(i => (!roleOf(i.who) || byRoles(n, i.who)) && (!owner || i.who === owner));
  const shownLists = (done ? doneByStandup(q.done, q.standups) : [["Now", q.now], ["Next", q.next], ["Later", q.later], ["Parked", q.parked]]).map(([name, items]) => [name, mine(items)]);
  if (!shownLists.some(([, items]) => items.length)) return pane(head, `<div class="blank">${done ? "Nothing done yet." : "Nothing in the work queue."} The delivery lead keeps it with team/work-queue.py.</div>`);
  const row = i => `<div class="row">${i.url ? `<a href="${esc(i.url)}" target="_blank" rel="noopener">${esc(i.key)}</a>` : `<span class="key">${esc(i.key)}</span>`}` +
    `<span class="tx" title="${esc(i.title + (i.note ? " — " + i.note : ""))}">${inline(i.title)}${i.note ? `<span class="note">${inline(i.note)}</span>` : ""}</span>` +
    (i.who ? `<span class="wqwho" data-owner="${esc(i.who)}" title="${owner ? "Show everyone's" : `Only ${esc(shown(i.who))}'s`}">${dayLogWho(i.who)}</span>` : `<span class="wh"><span class="who off unset">unassigned</span></span>`) +
    (done ? `<span class="at">${i.done ? (isToday(i.done) ? hhmm(i.done) : dayLogAt(i.done)) : ""}</span>` : "") + `</div>` +
    (i.fix ? `<div class="fix">↳ ${inline(i.fix)}</div>` : "");
  const list = (name, items) => {
    const k = (done ? "done:" : "work:") + name, fold = wqFolded().includes(k);
    return `<div class="sect${fold ? " shut" : ""}"><div class="day">${name}<span class="n">${items.length}</span>` +
      `<b class="wqfold" data-sect="${esc(k)}" title="${fold ? "Show this section" : "Hide this section"}">${foldIcon(fold)}</b></div>` +
      (fold ? "" : items.length ? items.map(row).join("") : `<div class="row none">Nothing here</div>`) + `</div>`;
  };
  const all = shownLists.flatMap(([, items]) => items);
  return pane(head, `<div class="daylog workq" style="--whw:${dayLogWhW(all.filter(i => i.who).map(i => shown(i.who)))}px;--wqk:${workQueueKeyW(all.map(i => i.key))}px">${shownLists.map(([name, items]) => list(name, items)).join("")}</div>`);
}
let meetNow = {}, meetRecords = "";
async function loadMeetings() {
  if (!leaves(layout().root).some(([, n]) => n.show === "meeting")) return;
  try { const d = await (await fetch("/api/meetings", {cache: "no-store"})).json(); meetNow = Object.fromEntries(d.meetings.map(m => [m.id, m])); meetRecords = d.records; } catch (e) {}
}
// (the empty .att before the box is where every box's attachments go; a meeting takes text only)
const meetRow = path => `<div class="att" data-name="${esc(MEET + path)}"></div><div class="sayrow"><textarea class="say" rows="1" data-name="${esc(MEET + path)}" placeholder="Message the meeting…" autocomplete="off"></textarea>${SEND}</div>`;
// The meeting's chips, the role chips' row: Invite all, and each role's, lit while all of that role are invited; a click
// on one invites all of that role (that role alone, from Invite all), or leaves them all out once they are. Who is invited is kept by name (n.who), the
// whole team while it is unset.
const meetTeam = () => [...S.agents, ...S.bench];
const meetChips = (path, n) => { const all = !Array.isArray(n.who), full = r => meetTeam().filter(a => a.role === r.role).every(a => inMeeting(n, a));
  return `<span class="chips"><b class="chip${all ? " on" : ""}" data-invite-role="" title="Invite the whole team">Invite all</b>${roleList().map(r =>
    `<b class="chip${!all && full(r) ? " on" : ""}" data-invite-role="${esc(r.role)}" data-role="${esc(r.role)}" title="Invite every ${esc(r.name)}, or leave them all out"><span class="cdot" style="background:${r.colour}"></span>${esc(r.name)}</b>`).join("")}` +
    `<b class="chip more" data-menu="chips:${path}" hidden></b></span>`; };
// invites or leaves out these agents; the whole team invited is kept as unset
function meetInvite(n, names, on) {
  const now = new Set(meetTeam().filter(a => inMeeting(n, a)).map(a => a.name));
  names.forEach(x => on ? now.add(x) : now.delete(x));
  if (meetTeam().every(a => now.has(a.name))) delete n.who; else n.who = [...now].map(x => "name:" + x);
}
// The meeting's bar. Before it starts: who is invited (Who, while the layout is unlocked), a topic and Start. While it
// is open: its topic and time, who is there, Add (anyone on the roster), Pause and End. The count of those in it, the
// owner among them, turns amber above three and red above five (owner, 2026-11-03: "more than me + 2: amber, more than
// me + 4: red"), as every line goes to every agent in it. End asks each session to suggest what its agent should be
// told; each suggestion waits under the meeting for Send (as written, or edited in its box) or Skip.
const meetAgent = name => S.agents.find(a => a.name === name) || S.bench.find(a => a.name === name) || {name, colour: colours[name] || "#888"};
const meetInvited = n => byRole([...S.agents, ...S.bench].filter(a => inMeeting(n, a)));
const meetOf = n => n.meeting && meetNow[n.meeting];
const andList = list => list.length < 2 ? list.join("") : list.slice(0, -1).join(", ") + " and " + list.at(-1);
const meetHhmm = t => new Date(t * 1000).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"});
function meetCount(agents) {
  const n = agents + 1, cls = n > 5 ? "red" : n > 3 ? "amber" : "";
  return `<span class="mcount${cls ? " " + cls : ""}" title="${n} in the meeting, you among them. Every line goes to every agent in it, so a big meeting is slow and costly: amber above 3, red above 5">${n} in the meeting</span>`;
}
function meetBar(path, n, big) {
  const m = meetOf(n), max = maxButton(big), btn = (what, icon, label, tip, cls = "") => `<b class="mbtn${cls}" data-meet="${what}" title="${esc(tip)}">${MENU_ICON[icon]}${label}</b>`;
  if (!m) {
    const who = meetInvited(n).map(a => a.name);
    return `<div class="meetbar"><input class="mtopic" data-name="mtopic:${esc(path)}" placeholder="Topic (optional)" autocomplete="off">${meetCount(who.length)}` +
      (who.length ? btn("start", "start", "Start", `Start a meeting with ${andList(who.map(shown))}: each joins through a meeting session of its own`) : `<span>Invite someone: a role's chip, or a portrait</span>`) + max + `</div>`;
  }
  const title = `<b>${esc(m.topic || "Meeting")}</b> ${m.ended ? `ended at ${meetHhmm(m.ended)}` : `since ${meetHhmm(m.opened)}`}`;
  if (m.ended) return `<div class="meetbar on"><span>${title} · the record is <a class="link" href="/doc?p=${encodeURIComponent(meetRecords + "/" + m.record)}" title="${esc(meetRecords + "/" + m.record)}" onclick="return showDoc(event, this)">${esc(m.record)}</a></span>${btn("new", "plus", "New meeting", "Set up the next meeting")}${max}</div>`;
  const here = m.who.filter(x => m.present[x]).length, stuck = Object.keys(m.stuck || {}).length;
  return `<div class="meetbar on"><span>${title} · ${here} of ${m.who.length} here${stuck ? ` · <b title="${esc(Object.entries(m.stuck).map(([x, why]) => `${shown(x)}: ${why}`).join("\n"))}">${stuck} stuck</b>` : ""}${m.paused ? " · <b>paused</b>" : ""}${m.ending ? " · ending" : ""}</span>${meetCount(m.who.length)}` +
    (m.ending ? "" : `<b class="mbtn" data-meet="add" data-menu="meetadd:${esc(path)}" title="Bring someone else into this meeting">${MENU_ICON.plus}Add</b>` +
      btn("pause", m.paused ? "start" : "pause", m.paused ? "Resume" : "Pause", m.paused ? "Let the agents hear each other again" : "Hold the agents' lines to each other until you speak or resume") +
      btn("end", "stop", "End", "End the meeting: each agent suggests what its own session should be told, for you to send or skip", " warn")) + max + `</div>`;
}
// Before the meeting starts, the whole team along its top, each named under its portrait: those invited in full colour,
// the rest dimmed, a click inviting one or not (while the layout is unlocked). Once it starts, everyone in it: one not
// yet arrived greyed, one whose session is working pulsing.
function meetFaces(n) {
  const m = meetOf(n);
  if (!m) { const all = byRole([...S.agents, ...S.bench]), edit = !pageLocked();
    return all.length ? `<div class="tabbar meetpick">${all.map(a => `<span class="ftab${inMeeting(n, a) ? "" : " away"}"${edit ? ` data-invite="${esc(a.name)}" title="${inMeeting(n, a) ? "Invited: click to leave out" : "Click to invite"}"` : ""}>` +
      `${face({...a, live: true, status: "idle"}, `data-name="${esc(a.name)}"`)}<small>${esc(shown(a.name))}</small></span>`).join("")}</div>` : ""; }
  const them = m.who.map(meetAgent);
  return them.length ? `<div class="tabbar icontabs meetrow">${them.map(a => {
    const on = m && !m.ended && m.live.includes(a.name), here = on && m.present[a.name], busy = on && m.busy.includes(a.name);
    const why = m && m.stuck?.[a.name];
    const tip = `${shown(a.name)}${m?.added.includes(a.name) ? ", brought in" : ""}${here ? (busy ? ", active, speaking or thinking" : ", active") : why ? ", stuck: " + why : on ? ", joining" : ", inactive"}`;
    return `<span class="ftab${here ? "" : " away"}${busy ? " mbusy" : ""}">${face({...a, live: true, status: "idle"}, `data-name="${esc(a.name)}" title="${esc(tip)}"`)}<small>${esc(shown(a.name))}</small></span>`; }).join("")}</div>` : "";
}
// The meeting as it was said, the owner's lines and each agent's, then, once it is ending, each agent's suggestion.
function meetingHtml(path, n) {
  const m = meetOf(n), iso = t => new Date(t * 1000).toISOString();
  const lines = !m ? `<div class="empty">${meetInvited(n).length ? "Start the meeting: each line anyone says goes to everyone in it" : "Invite someone: a role's chip, or a portrait"}</div>`
    : m.log.map(l => l.kind !== "say" ? `<div class="it mevent"><span class="tx">${esc(l.text)}</span><span class="ago" data-ts="${iso(l.at)}">${since(iso(l.at))}</span></div>`
      : l.who === S.owner || !m.who.includes(l.who) ? item({kind: "owner", who: l.who, text: l.text, ts: iso(l.at), lane: "owner"}, false, "")
      : item({kind: "said", text: l.text, ts: iso(l.at), lane: "owner"}, false, l.who)).join("") || `<div class="empty">Waiting for everyone to arrive</div>`;
  const hand = m && m.ending ? `<div class="hands">${m.who.map(x => { const h = m.handover[x] || {}, c = meetAgent(x).colour;
    const head = `<span class="name" style="--c:${c}">${esc(shown(x))}</span>`;
    if (h.state === "asked") return `<div class="hand">${head}<span class="mute">is writing what ${esc(x)} should be told…</span></div>`;
    if (h.state === "suggested") return `<div class="hand" data-n="${esc(x)}">${head}<span class="mute">suggests sending ${esc(x)}:</span>` +
      `<textarea class="htext" data-name="hand:${esc(m.id)}:${esc(x)}" rows="3">${esc(h.suggested)}</textarea>` +
      `<span class="hbtns"><b class="mbtn" data-hand="send" title="Send this, as it now reads, to ${esc(shown(x))}">${MENU_ICON.start}Send</b><b class="mbtn" data-hand="skip" title="Send nothing">${MENU_ICON.close}Skip</b></span></div>`;
    const said = {skipped: h.suggested ? "skipped" : "nothing to send", queued: `waiting for ${esc(x)} to be free`, sent: "sent"}[h.state] || esc(h.state || "");
    return `<div class="hand done">${head}<span class="mute">${said}${h.edited ? " (edited)" : ""}</span></div>`; }).join("")}</div>` : "";
  const box = m && !m.ending && !m.ended ? `<div class="chat">${meetRow(path)}</div>` : "";
  return `<div class="teamlog combined meeting" data-name="~meeting:${esc(path)}"><div class="feed">${lines}</div><button class="newest" title="Back to the newest line">↓ Newest</button>${hand}${box}</div>`;
}
// The open meeting's Add menu: everyone on the roster not in it; a pick brings them in through a meeting session.
function meetAdd(btn, path) {
  const key = "meetadd:" + path, m = meetOf(nodeAt(layout().root, path));
  if (!m) return;
  if (menuOn(key)) return menuOff(true);
  const them = byRole([...S.agents, ...S.bench]).filter(a => !m.who.includes(a.name));
  menuAt(btn, key, `<div class="hd"><div>Bring into this meeting</div></div>` + (them.length ? them.map(a => `<div class="mi" data-add="${esc(a.name)}">` +
    `<span class="dot" style="--c:${a.colour}"></span>${esc(shown(a.name))}</div>`).join("") : `<div class="mi off">Everyone is here</div>`), false);
  menu.querySelectorAll(".mi[data-add]").forEach(mi => mi.onclick = () => { menuOff(true); meetPost(m.id, "add", {name: mi.dataset.add}); });
}
async function meetPost(id, what, body = {}) {
  const r = await fetch(`/api/meeting${id ? "/" + id + "/" + what : ""}`, {method: "POST", headers: {"Content-Type": "application/json", "X-Team-Say": "1"},
    body: JSON.stringify(body)}).catch(() => null);
  const d = r && r.ok ? await r.json().catch(() => ({})) : {error: r ? (await r.text().catch(() => "")).trim() || `refused (${r.status})` : "the page's server did not answer"};
  await loadMeetings(); draw();
  return d;
}
// A Characters pane's agents: the whole team, benched ones too, role by role in its roles' order (every role until
// roles are chosen for it) and A to Z within a role.
const chrAgents = n => rolesOn(n).flatMap(r => [...S.agents, ...S.bench].filter(a => a.role === r).sort(byName));
// How a Tabs or Combined pane shows its agents (n.badge): by name ("name", the default), as the bench's small tiles
// ("icon"), or as their Characters tiles ("card").
const BADGES = [["name", "Name"], ["icon", "Icon"], ["card", "Card"]];
// An Agent view's pick of agent: the running agents as portraits, one click showing one. Large and named in the empty
// pane; small under its tabs while one is showing, to change it.
const agentPick = (n, big) => S.agents.length ? `<div class="tabbar agentpick${big ? " big" : ""}">${byRole(S.agents).map(a =>
  `<span class="ftab${a.name === n.name ? " sel" : ""}" data-agent="${esc(a.name)}" title="Show ${esc(shown(a.name))}">${face(a, `data-name="${esc(a.name)}"`)}${big ? `<small>${esc(shown(a.name))}</small>` : ""}</span>`).join("")}</div>` : "No agent is running";
// The documents File panes have shown, newest first, kept in this browser, offered in an empty File pane.
const fileRecent = () => { try { return JSON.parse(localStorage.getItem("file:recent")) || []; } catch (e) { return []; } };
const fileSeen = f => { if (f) localStorage.setItem("file:recent", JSON.stringify([f, ...fileRecent().filter(x => x !== f)].slice(0, 8))); };
// A pane's roles (n.roles, in the order they were picked), or every role while none is picked: "All".
const rolesPicked = n => Array.isArray(n.roles) ? n.roles : [];
const rolesOn = n => rolesPicked(n).length ? n.roles : roleList().map(r => r.role);
// The views that list people or what they did, each filtered by the same role chips. A row by someone in no picked
// role (the owner, or nobody) is left out while roles are picked.
const CHIP_VIEWS = ["grid", "others", "tabs", "combined", "characters", "meeting", "daylog", "workqueue", "tokens"];
const roleOf = name => [...S.agents, ...S.bench].find(a => a.name === name)?.role;
const byRoles = (n, name) => !rolesPicked(n || {}).length || n.roles.includes(roleOf(name));
const roleItems = () => roleList().map(r => [r.role, r.name, `<span class="dot" style="--c:${r.colour}"></span>`]);
// The role chips under a pane's tabs: All, then each role with a dot in its colour, lit while the pane shows it. Those
// that do not fit the row fold into a +N chip, which opens them as a menu (see fitChips).
const roleChips = (path, n) => { const on = rolesPicked(n), pickView = PICK_VIEWS.includes(n.show);
  const lit = r => pickView ? pickedAny(n) && S.agents.some(a => a.role === r.role) && S.agents.filter(a => a.role === r.role).every(a => inPick(n, a)) : on.includes(r.role);
  return `<span class="chips"><b class="chip${(pickView ? pickedAny(n) : on.length) ? "" : " on"}" data-role="" title="Every role">All</b>${roleList().map(r =>
    `<b class="chip${lit(r) ? " on" : ""}" data-role="${esc(r.role)}" title="Show or leave out the ${esc(r.name)}"><span class="cdot" style="background:${r.colour}"></span>${esc(r.name)}</b>`).join("")}` +
    `<b class="chip more" data-menu="chips:${path}" hidden></b></span>`; };
// A tab's name: the one given it (n.title), else one from what it shows: the agent an Agent view shows, the role when
// one role is picked, else the view.
const plural = w => /s$/.test(w) ? w : w + "s";
function autoName(p) {
  if (p.show === "agent" && p.name) return shown(p.name);
  if (p.show === "file" && p.path) return p.path.split("/").pop();
  const picked = PICK_VIEWS.includes(p.show) && Array.isArray(p.pick) ? [...new Set(S.agents.filter(a => p.pick.includes(a.name)).map(a => a.role))] : rolesPicked(p);
  const one = ["grid", "tabs", "characters", "combined"].includes(p.show) && picked.length === 1 && roleList().find(r => r.role === picked[0]);
  return one ? plural(one.name) : PANE_TYPES[p.show] || "Choose a view";
}
// Every tab's name on the page, by "path:index": two of the same name, given or not, are told apart by a number after
// the first ("Characters", "Characters 2"), in the layout's order.
let tabNamesNow = {};
function tabNames(root) {
  const out = {}, seen = {};
  for (const [path, n] of leaves(root)) {
    const sel = n.tab || 0, tabs = n.tabs ? n.tabs.map((t, i) => i === sel ? {...n, title: n.title ?? t.title} : t) : [n];
    tabs.forEach((t, i) => { const name = t.title || autoName(t), c = seen[name] = (seen[name] || 0) + 1; out[path + ":" + i] = c > 1 ? `${name} ${c}` : name; });
  }
  return out;
}
// A pane's tabs (n.tabs, n.tab the one showing; a pane without n.tabs is one tab), each with its view's icon and its
// name. While the layout is unlocked they head the pane's bar, each with a chevron that changes its view, and with
// two or more each can be dragged along the strip or closed; locked, they show over the body only when there are two.
function paneTabs(n, locked, path) {
  const sel = n.tab || 0, tabs = n.tabs ? n.tabs.map((t, i) => i === sel ? {...n, title: n.title ?? t.title} : t) : [n], many = tabs.length > 1;
  if (locked && !many) return "";
  return `<div class="ctabs">${tabs.map((t, i) => `<span class="ctab${i === sel ? " sel" : ""}" data-i="${i}"${!locked && many ? ' draggable="true"' : ""}${locked ? "" : ' title="Double-click to rename"'}>` +
    `${PANE_ICON[t.show] ? `<i class="cti">${PANE_ICON[t.show]}</i>` : ""}<span class="ctl">${esc(tabNamesNow[path + ":" + i] || t.title || autoName(t))}</span>` +
    (locked ? "" : `<i class="cv" data-cur="${esc(t.show || "")}" title="Change this tab's view">${MENU_ICON.down}</i>`) +
    (!locked && many ? `<i class="cx" title="Close this tab">${MENU_ICON.close}</i>` : "") + `</span>`).join("")}</div>`;
}
// The View menu: every view, Grid and Tabs among them, its kind's icon and its name, the showing one ticked. A click on
// one shows it; its pencil renames it in place (Enter or leaving the box keeps the name, Esc drops it) and its × deletes
// it (never the last) once asked in the menu, as an agent's Stop asks. Add a view, at the bottom, adds an empty custom one and names it straight away.
// Changes the views and shows the one they leave showing, as a pick from the View menu does.
function changeViews(f) { const v = views(); f(v); saveViews(v); localStorage.removeItem("custom:max"); localStorage.removeItem("custom:maxname"); paneBig = null; draw(); setTimeout(load); }
// The view keys: Ctrl+Alt (Ctrl+Option on a Mac) with 1 … 9 shows a view, the Nth in the View menu until any key is
// given a view in Settings, then only the keys given one. A key is given a view by its name, and follows it when renamed.
const viewMod = () => MAC ? "Ctrl+Option" : "Ctrl+Alt";   // a function: MAC is set further down
$("#viewbar").onclick = e => { const b = e.target.closest(".vtb"); if (!b) return; const i = +b.dataset.v; if (i !== views().at) changeViews(v => { v.at = i; }); };
function viewKeys() {
  const v = views().views, given = Object.entries(settings().viewKeys || {}).filter(([, n]) => n);
  const keys = given.length ? given.map(([d, n]) => [d, v.findIndex(x => x.name === n)]).filter(([, i]) => i >= 0)
    : v.slice(0, 9).map((x, i) => [String(i + 1), i]);
  return Object.fromEntries(keys);
}
function viewMenu(btn, rested, again, ask) {
  if (!again && menuOn("view")) { if (rested) return; if (menu.dataset.rested) delete menu.dataset.rested; else menuOff(true); return; }
  // renaming, deleting and adding views are for an unlocked page; locked, the menu only picks one
  const v = views(), edit = !pageLocked();
  menuAt(btn, "view", `<div class="hd"><div>View</div></div>` + v.views.map((x, i) =>
    `<div class="mi vmi" data-v="${i}" title="${esc(VIEW_TIP[x.kind])}"><i class="vico">${MENU_ICON[x.icon] || MENU_ICON[x.kind]}</i><span class="vname">${esc(x.name)}</span>` +
    MENU_ICON.check.replace("<svg", `<svg class="tick${i === v.at ? "" : " off"}"`) +
    (edit ? `<i class="vbtn ved" title="Rename this view">${MENU_ICON.pencil}</i>` +
      `${v.views.length > 1 ? `<i class="vbtn vdel" title="Delete this view">${MENU_ICON.close}</i>` : '<i class="vbtn"></i>'}` : "") + `</div>` +
    (ask === i ? `<div class="ask">Delete the view "${esc(x.name)}"?</div><div class="mi warn vyes" data-v="${i}">${MENU_ICON.close}Delete ${esc(x.name)}</div>` +
      `<div class="mi vno">${MENU_ICON.close}Cancel</div><div class="sep"></div>` : "")).join("") +
    (edit ? `<div class="mi vadd" title="Add an empty custom view">${MENU_ICON.plus}Add a view</div>` : ""), false, again);
  if (rested && !again) menu.dataset.rested = "1";
  const go = changeViews;
  const redraw = ask => viewMenu(btn, false, true, ask);
  menu.querySelectorAll(".vmi").forEach(el => el.onclick = e => {
    const i = +el.dataset.v;
    if (e.target.closest(".vname input")) return;
    if (e.target.closest(".ved")) renameView(el, i, () => redraw());
    else if (e.target.closest(".vdel")) { delete menu.dataset.rested; redraw(ask === i ? undefined : i); }
    else { menuOff(true); if (i !== views().at) go(v => { v.at = i; }); }
  });
  menu.querySelector(".vyes")?.addEventListener("click", () => {
    const i = ask; go(v => { v.views.splice(i, 1); if (i < v.at || v.at === v.views.length) v.at = Math.max(0, v.at - 1); }); redraw();
  });
  menu.querySelector(".vno")?.addEventListener("click", () => redraw());
  if (edit) menu.querySelector(".vadd").onclick = () => {
    go(v => { v.views.push({name: "View " + (v.views.length + 1), kind: "custom", layout: {root: {}}}); v.at = v.views.length - 1; });
    redraw(); renameView(menu.querySelector(`.vmi[data-v="${views().at}"]`), views().at, () => redraw());
  };
}
// A view's icon, picked while it is being named from its icon's dropdown: the views' own kinds and a few more.
const VIEW_ICONS = ["grid", "tabs", "custom", "team", "owner", "said", "calendar", "chart", "star", "bell", "flag", "code", "bug"];
function renameView(el, i, after) {
  const label = el?.querySelector(".vname"), ico = el?.querySelector(".vico");
  if (!label || label.querySelector("input")) return;
  const was = label.textContent, box = Object.assign(document.createElement("input"), {className: "ctname", value: was});
  const x = views().views[i], wasIcon = x.icon || x.kind;
  let done = false, icon = wasIcon;
  delete menu.dataset.rested;   // a menu opened by a rest stays while its view is being named
  // the icon becomes a dropdown of the icons; the name and the icon are kept together, or both dropped by Esc
  const pick = Object.assign(document.createElement("div"), {className: "vicons", hidden: true,
    innerHTML: VIEW_ICONS.map(k => `<i data-k="${k}"${k === icon ? ' class="on"' : ""}>${MENU_ICON[k]}</i>`).join("")});
  el.after(pick); ico.classList.add("pick"); ico.title = "Choose an icon";
  ico.onmousedown = pick.onmousedown = e => e.preventDefault();   // the name box keeps the focus
  ico.onclick = e => { e.stopPropagation(); pick.hidden = !pick.hidden; };
  pick.onclick = e => {
    e.stopPropagation(); const k = e.target.closest("[data-k]")?.dataset.k; if (!k) return;
    icon = k; ico.innerHTML = MENU_ICON[k]; pick.querySelectorAll("i").forEach(o => o.classList.toggle("on", o.dataset.k === k)); pick.hidden = true;
  };
  const end = keep => { if (done) return; done = true; const val = box.value.trim(); box.remove(); pick.remove();   // draw() waits while it has the focus
    if (keep && (val && val !== was || icon !== wasIcon)) {
      const v = views(); v.views[i].name = val || was; v.views[i].icon = icon; saveViews(v);
      const set = settings(), vk = set.viewKeys || {};   // a key given this view stays with it under its new name
      if (val && val !== was && Object.values(vk).includes(was)) {
        set.viewKeys = Object.fromEntries(Object.entries(vk).map(([d, n]) => [d, n === was ? val : n])); localStorage.setItem("settings", JSON.stringify(set));
      }
      draw();
    } after(); };
  // its keys are its own: the menu's arrows, Enter and Space, and Esc closing the menu, wait until it is done
  box.onkeydown = e => { e.stopPropagation(); if (e.key === "Enter") end(true); else if (e.key === "Escape") end(false); };
  box.onclick = e => e.stopPropagation();
  box.onblur = () => end(true);
  label.textContent = ""; label.append(box); box.focus(); box.select();
}
function customHtml(ceil, tabRow) {
  const l = layout();
  tabNamesNow = tabNames(l.root);
  // A maximised pane is one agent's card filling the layout (an agent pane's own, or one card of a grid or tabs pane),
  // or a Team, Combined, Meeting, File or Work queue pane.
  let maxed = localStorage.getItem("custom:max");
  const maxNode = maxed && leaves(l.root).find(([p]) => p === maxed)?.[1];
  const maxName = maxNode && (["team", "combined", "meeting", "file", "workqueue"].includes(maxNode.show) ? "~" + maxNode.show : maxNode.show === "agent" ? maxNode.name
    : paneAgents(maxNode).some(a => a.name === localStorage.getItem("custom:maxname")) && localStorage.getItem("custom:maxname"));
  if (maxed && !maxName) { localStorage.removeItem("custom:max"); localStorage.removeItem("custom:maxname"); maxed = null; }
  // A card shows the whole conversation unless its pane is set to the summary (the pane bar's Full/Summary, while the
  // layout is being changed); a maximised one always does. Every card has the maximise button docked at the end of its head.
  const paneCard = (n, a, path, lead = "") => {
    const big = path === maxed;
    if (!fullView(n) && !big) return card(a, ceil, null, maxButton(false), "", {lead});
    const t = big && termOn() && paneTerm[a.name];
    const key = paneConv[a.name] && [a.name, a.live, paneVer[a.name], laneOf(a.name), [...openRuns], noImage.size, echoKey(a.name), paintKey].join("|");
    const keep = !!key && $(`#main .pane[data-path="${path}"] .card.full[data-name="${CSS.escape(a.name)}"] .feed`)?.dataset.key === key;
    return card(a, ceil, paneConv[a.name] || a.feed,
      (big ? `<span class="seg termseg"><b class="${termOn() ? "on" : ""}" title="Show or hide its terminal">Terminal</b></span>` : "") + maxButton(big),
      t ? paneTermHtml(a.name, t) : "", {key, keep, lead});
  };
  const pane = (n, path) => {
    const of = paneAgents(n);
    let body = `<div class="blank">${pageLocked() ? "" : `<button class="pchoose" data-cur="">Choose a view${MENU_ICON.down}</button>`}</div>`;
    if (n.show === "agent") {
      const a = S.agents.find(x => x.name === n.name);
      body = a ? `<div class="cards" style="grid-template-columns:minmax(0,1fr)">${paneCard(n, a, path)}</div>`
        : `<div class="blank">${n.name ? `<span>${esc(shown(n.name))} is not running</span>` : ""}${agentPick(n, true)}</div>`;
    } else if (n.show === "others") {
      body = `<div class="others">${minis("", S.agents.filter(a => byRoles(n, a.name)))}</div>`;
    } else if (n.show === "characters") {
      const them = chrAgents(n);
      body = them.length ? `<div class="chrs">${tiles(them)}</div>` : `<div class="blank">No agent in these roles</div>`;
    } else if (n.show === "file") {
      // the document under a header as a Team pane's: its name, its full path, and the maximise button
      const d = n.path && fileDocs[n.path], ed = n.path && fileEdit[n.path];
      // a textarea drops a first newline, so one is put before the text
      const doc = ed ? `<textarea class="fedit" data-name="~edit:${esc(n.path)}" spellcheck="false">\n${esc(ed.text)}</textarea>`
        : !d ? `<div class="blank">Loading…</div>`
        : d.text == null ? `<div class="blank">${d.status === 404 ? "No such document, or not one this page shows" : "Could not load it"}</div>`
        : `<div class="fdoc">${/\.(md|markdown)$/i.test(n.path) ? docMd(d.text) : `<pre class="code">${esc(d.text)}</pre>`}</div>`;
      body = !n.path ? `<div class="blank">${pageLocked() ? "" : fileRecent().length ? `<div class="frecent"><div>Recently opened</div>${fileRecent().map(f =>
          `<a data-recent="${esc(f)}" title="${esc(f)}"><b>${esc(f.split("/").pop())}</b><span>${esc(f)}</span></a>`).join("")}</div>` : "Type a document's full path above: the folder's files are suggested as you type"}</div>`
        : `<div class="teamlog filelog" data-name="~file:${esc(path)}"><div class="thead"><span>${esc(n.path.split("/").pop())}</span><span title="${esc(n.path)}">${esc(n.path)}</span>${fileTools(n.path)}${maxButton(path === maxed)}</div>${doc}</div>`;
    } else if (n.show === "machine") {
      body = perfHtml(n);
    } else if (n.show === "daylog") {
      body = dayLogHtml(n);
    } else if (n.show === "tokens") {
      body = tokensHtml(path === maxed, n);
    } else if (n.show === "workqueue") {
      body = workQueueHtml(path === maxed, n);
    } else if (n.show === "combined") {
      // the agent picked in it over the Combined view, which shows greyed round it; maximised, the agent alone
      const one = paneFocus(path, n), card1 = one && `<div class="cards" style="grid-template-columns:minmax(0,1fr)">${paneCard(n, one, path, BACK_BUTTON)}</div>`;
      body = one && path === maxed ? card1
        : combinedHtml(path, n, fullView(n) || path === maxed, path === maxed) + (one ? `<div class="paneover">${card1}</div>` : "");
    } else if (n.show === "team") {
      body = teamHtml(path, fullView(n) || path === maxed, new Set(n.hide || []), path === maxed);
    } else if (n.show === "grid" && of.length) {
      const el = $(`#main .pane[data-path="${path}"] .pbody`), c = el ? cols(of.length, el.clientWidth, el.clientHeight) : Math.ceil(Math.sqrt(of.length));
      body = `<div class="cards" style="grid-template-columns:repeat(${c},minmax(0,1fr))">${of.map(a => fullView(n)
        ? `<div class="cell">${paneCard(n, a, path)}</div>` : paneCard(n, a, path)).join("")}</div>`;
    } else if (n.show === "tabs" && of.length) {
      const [sel, row] = tabRow("pane:" + path, of, n.badge);
      body = `${row}<div class="cards" style="grid-template-columns:minmax(0,1fr)">${paneCard(n, sel, path)}</div>`;
    } else if (n.show === "meeting") {
      body = `${meetBar(path, n, path === maxed)}${meetFaces(n)}${meetingHtml(path, n)}`;
    } else if (n.show === "grid" || n.show === "tabs") {
      body = `<div class="blank">No agent in these roles is running</div>`;
    }
    // unlocked, the bar: the grip, the tabs, + for another tab and the pane's menu; under them the showing tab's own
    // settings: its roles, agent, document, badges or gauges, and Full or Summary
    const locked = pageLocked(), full = n.show && !["others", "characters", "file", "machine", "daylog", "workqueue", "tokens"].includes(n.show);
    const own = [
      CHIP_VIEWS.includes(n.show) && n.show !== "meeting" ? roleChips(path, n) : "",
      n.show === "daylog" ? dayLogFilters(n) : "",
      n.show === "file" ? `<input data-act="path" value="${esc(n.path || "")}" placeholder="Type a file path" spellcheck="false" title="A document's full path: Enter to show it, or choose from the list of the folder typed so far">` : "",
      n.show === "agent" && S.agents.some(a => a.name === n.name) ? agentPick(n, false) : "",
      ["tabs", "combined"].includes(n.show) ? `<select data-act="badge" title="How agents are shown">${BADGES.map(([v, label]) => `<option value="${v}"${v === (n.badge || "name") ? " selected" : ""}>${label}</option>`).join("")}</select>` : "",
      n.show === "meeting" && !meetOf(n) ? meetChips(path, n) : "",
      n.show === "machine" ? `<span class="seg">${[["gauges", "Gauges"], ["rows", "Rows"]].map(([v, label]) =>
        `<b data-act="machine" data-v="${v}" class="${v === (n.machine || "gauges") ? "on" : ""}">${label}</b>`).join("")}</span>` : "",
      full ? `<span class="seg">${[["full", "Full", "The whole conversation"], ["summary", "Summary", "The newest turns"]].map(([v, label, title]) =>
        `<b data-act="view" data-v="${v}" class="${(v === "full") === fullView(n) ? "on" : ""}" title="${title}">${label}</b>`).join("")}</span>` : ""].join("");
    const bar = locked ? "" : `<div class="pbar">
      <b data-act="move" class="pmove" title="Drag onto another pane to swap the two">⠿</b>
      ${n.show ? paneTabs(n, false, path) + `<b class="fbtn cadd" title="Add a tab">${MENU_ICON.plus}</b>` : ""}
      <b class="fbtn pmore" data-menu="pane:${path}" title="Split or remove this pane">${MENU_ICON.more}</b>
      ${own ? `<div class="pown">${own}</div>` : ""}</div>`;
    return `<div class="pane" data-path="${path}">${bar}<div class="pbody">${locked ? paneTabs(n, true, path) : ""}${body}</div></div>`;
  };
  const node = (n, path) => {
    if (!n.split) return pane(n, path);
    const side = tileSide(n), count = side && chrAgents(n[side]).length;
    const size = side && (n.split === "row" ? tilesWidth(tileCols(n, path + side, count)) : tilesHeight(tileRows(n, path + side, count), path + side));
    const grow = s => side ? (s === side ? `flex:0 0 ${size}px` : "flex-grow:1") : `flex-grow:${s === "a" ? n.at : 1 - n.at}`;
    return `<div class="lay ${n.split}" data-path="${path}"><div class="half" style="${grow("a")}">${node(n.a, path + "a")}</div><div class="divider drag" data-path="${path}"></div><div class="half" style="${grow("b")}">${node(n.b, path + "b")}</div></div>`;
  };
  return !maxed ? node(l.root, "r") : ["team", "combined", "meeting", "file", "workqueue"].includes(maxNode.show) ? pane(maxNode, maxed) : pane({...maxNode, show: "agent", name: maxName}, maxed);
}
const fullView = n => n.view !== "summary";
// A Characters pane beside another is a whole number of tiles wide: one, two or three (two unless set) as its divider
// snaps between them, and more while its tiles would otherwise need scrolling. One above or below another is a whole
// number of rows high in the same way (one unless set).
const tileSide = n => !!n.split && (n.a.show === "characters" ? "a" : n.b.show === "characters" ? "b" : null);
const SNAP = 12;   // px within which a dragged divider snaps to a line (see the divider drag)
const tilesWidth = c => 18 + 120 * (c || 2);   // the pane's border, the grid's padding and scroll gutter, 112px tiles 8px apart
// the pane's border, its bar (none when locked), the grid's padding and the rows of 112px tiles 8px apart
const tilesHeight = (r, path) => 18 + ($(`#main .pane[data-path="${path}"] > .pbar`)?.offsetHeight ?? (pageLocked() ? 0 : 38)) + 120 * (r ?? 1);
// The columns a snapped Characters pane shows: its own setting, or more when the tiles would not fit its height in that many.
// A pane not yet on the page has no height to go by; tileGuess has the page draw again once it is.
let tileGuess = false;
function tileCols(n, path, count) {
  const h = $(`#main .pane[data-path="${path}"] .chrs`)?.clientHeight, rows = h ? Math.max(1, Math.floor((h - 16) / 120)) : 0;
  if (!h) tileGuess = true;
  return Math.max(n.tiles || 2, rows ? Math.ceil(count / rows) : 0);
}
// The rows a snapped Characters pane above or below another shows: its own setting, or more when the tiles would not fit its width.
function tileRows(n, path, count) {
  const w = $(`#main .pane[data-path="${path}"] .chrs`)?.clientWidth, cols = w ? Math.max(1, Math.floor((w - 7) / 120)) : 0;
  if (!w) tileGuess = true;
  return Math.max(n.tiles || 1, cols ? Math.ceil(count / cols) : 0);
}
// An agent's card, or a Team, Combined, Meeting, File or Work queue pane, can fill the whole layout for a while, from the button at the end of its header or Shift+F11
// (the pane being typed in, else the one under the pointer); Esc, the button or Shift+F11 again puts it back.
const maxButton = on => `<b class="maxbtn" title="${on ? "Restore (Esc)" : "Maximise"}"><svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5">${on
  ? '<path d="M4.5 1v3.5H1M7.5 1v3.5H11M4.5 11V7.5H1M7.5 11V7.5H11"/>' : '<path d="M1 4.5V1h3.5M11 4.5V1H7.5M1 7.5V11h3.5M11 7.5V11H7.5"/>'}</svg></b>`;
// An agent clicked in a Combined pane fills that pane with its card (kept in this browser as "focus:pane:<path>")
// until the card's back button; its maximise button then takes it over the page. One no longer running gives the pane
// back to the Combined view.
const BACK_BUTTON = `<b class="backbtn" title="Back to Combined"><svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M10.5 6h-9M5 2.5 1.5 6 5 9.5"/></svg></b>`;
const paneFocus = (path, n) => { const x = localStorage.getItem("focus:pane:" + path); return x && paneAgents(n).find(a => a.live && a.name === x) || null; };
let paneUnder = null;
document.addEventListener("mouseover", e => { paneUnder = e.target.closest?.("#main .pane") || paneUnder; });
addEventListener("keydown", e => { if (e.key === "F11" && e.shiftKey && maxToggle()) e.preventDefault(); });
function maxToggle() {
  if ((localStorage.getItem("page") || "grid") !== "custom" || open) return false;
  if (unmax()) return true;
  const at = document.activeElement?.closest?.("#main .pane .card") || (paneUnder?.isConnected ? paneUnder : null);
  at?.querySelector(".maxbtn")?.click();
  return true;
}
function unmax() { if (!localStorage.getItem("custom:max")) return false; localStorage.removeItem("custom:max"); localStorage.removeItem("custom:maxname"); paneBig = null; draw(); return true; }
// Each agent pane's longer conversation, as the agent's own view reads it, fetched with every load of the page, and
// its terminal as it is on screen, shown in a maximised pane. A conversation's version goes up only when it changes,
// so an unchanged one is not drawn again.
const paneConv = {}, paneTerm = {}, paneVer = {}, paneText = {};
let paneBig = null;   // the agent whose maximised pane's terminal is expanded over the page
function paneTermHtml(name, t) {
  measureChar();
  const big = paneBig === name, w = big ? innerWidth - 80 - PAD : THUMB_W - PAD;
  const h = big ? innerHeight - 80 - PAD - 33 : THUMB_H;
  const size = Math.max(1, Math.min(big ? BIG : 99, w / (t.cols * charW), h / (t.rows * 1.25)));
  return `<div class="termwrap${big ? " big" : ""}" title="${big ? "" : "Expand"}"><div class="term"><div class="bar"><i></i><i></i><i></i><span>${esc(shown(name))} — ${t.cols}×${t.rows}</span><b class="pzoom">${big ? "⤡" : "⤢"}</b></div>` +
    `<div class="screen"><pre style="font-size:${size.toFixed(2)}px;width:${(t.cols * charW * size).toFixed(1)}px;height:${(t.rows * 1.25 * size).toFixed(1)}px">${t.screen || ""}</pre></div></div><span class="x" title="Close (Esc)">✕</span></div>`;
}
// The Team pane's transcript: every message between agents, fetched with each load while a Team pane is laid out.
// Full scrolls through all of them, each whole; Summary shows the newest that fit, each cut to a few lines, as a card does.
// Its Agents menu, saved with the pane, leaves out or brings back the messages an agent sent or received.
let teamLog = [], teamVer = 0, teamText = "";
async function loadTeam() {
  if (!leaves(layout().root).some(([, n]) => n.show === "team")) return;
  try {
    const d = await (await fetch("/api/team", {cache: "no-store"})).json(), text = JSON.stringify(d);
    if (text !== teamText) { teamLog = d; teamText = text; teamVer++; }
  } catch (e) {}
}
// the agents in the Team transcript, in the roster's order, then any others by name
function teamNames() {
  const order = S.agents.map(a => a.name);
  return [...new Set(teamLog.flatMap(m => [m.from, m.to]))]
    .sort((a, b) => ((order.indexOf(a) + 1) || 999) - ((order.indexOf(b) + 1) || 999) || a.localeCompare(b));
}
const teamItems = () => teamNames().map(x => [x, x, `<span class="dot" style="--c:${colours[x] || "#888"}"></span>`]);
function teamHtml(path, full, hide, big) {
  const names = teamNames();
  const kept = teamLog.filter(m => !hide.has(m.from) && !hide.has(m.to)), log = full ? kept : kept.slice(-30);
  const key = ["team", teamVer, noImage.size, full, [...hide].sort(), paintKey].join("|");
  const keep = $(`#main .pane[data-path="${path}"] .teamlog .feed`)?.dataset.key === key;
  const row = m => `<div class="it peer l-team" style="--pc:${colours[m.from] || "#888"}" data-agent="${esc(m.from)}"><span class="who">${esc(shown(m.from))}</span>` +
    `<span class="who to" style="--pc:${colours[m.to] || "#888"}">${esc(shown(m.to))}</span><span class="tx">${md(m.text)}</span>` +
    `<span class="ago" data-ts="${esc(m.ts || "")}">${since(m.ts)}</span></div>`;
  return `<div class="teamlog${full ? "" : " summary"}" data-name="~team"><div class="thead"><span>Team</span><span>${kept.length} message${kept.length === 1 ? "" : "s"} between agents</span>${filterBtn("agents", "agents:" + path, names.filter(x => !hide.has(x)), names, teamItems(), "Agents")}${maxButton(big)}</div>` +
    `<div class="feed" data-key="${esc(key)}"${keep ? " data-kept" : ""}>${keep ? "" : log.length ? log.map(row).join("") : `<div class="empty">${teamLog.length ? "every message here is left out" : "no messages between agents lately"}</div>`}</div></div>`;
}
// The Combined pane: the conversations of the running agents in the roles chosen from its Roles menu as one, in time
// order, each turn naming its agent, through the pane's own lanes. A message between two of them is shown once, as its recipient has it.
// Full and Summary as the Team pane. The roles are chosen from the pane bar while the layout is being changed, as a grid's are.
// Its lanes split the owner's: Owner is the owner's messages, Said each agent's own words, so either can go alone.
const CLANES = [["owner", ""], ["said", "Said"], ["team", "Team"], ["auto", "Auto"]], CALL = CLANES.map(l => l[0]);
const CLANE_TIP = {owner: "Your messages to the agents", said: "Each agent's own words: its answers and its thinking aloud",
  team: LANE_TIP.team, auto: LANE_TIP.auto};
// a pane saved before Said had its own lane shows the agents' words wherever it showed the owner's
const clanesOf = n => Array.isArray(n.clanes) ? n.clanes : Array.isArray(n.lanes) ? [...n.lanes, ...(n.lanes.includes("owner") ? ["said"] : [])] : CALL;
// One message the owner sent to several agents at once (the meeting's box) shows once, to all of them: the same text
// of the same kind within two minutes is folded into the first.
const OWN = ["owner", "echo", "pending"];
function foldSent(out, it) {
  const t = Date.parse(it.ts), first = OWN.includes(it.kind) && out.findLast(p => p.kind === it.kind && p.text === it.text && t - Date.parse(p.ts) < 120000);
  if (first) { if (!(first._agents ||= [first._agent]).includes(it._agent)) first._agents.push(it._agent); } else out.push(it);
  return out;
}
function combinedHtml(path, n, full, big) {
  const chosen = paneAgents(n).map(a => a.name), on = clanesOf(n);
  const lanesOn = it => ["ask", "live", "pending", "echo"].includes(it.kind) || on.includes(it.kind === "said" ? "said" : it.lane);
  // a message sent from the pane shows at once, as in an agent's own view, until the agent's conversation has it
  const items = chosen.flatMap(a => (paneConv[a] || []).concat(echoItems(paneConv[a] || [], a)).filter(it => (it.ts || it.kind === "ask") && lanesOn(it) && !(it.kind === "sent" && chosen.includes(it.with || it.who)))
    .map(it => ({...it, _agent: a}))).sort((x, y) => !x.ts ? 1 : !y.ts ? -1 : x.ts < y.ts ? -1 : x.ts > y.ts ? 1 : 0)
    .reduce(foldSent, []);
  const log = full ? items : items.slice(-30);
  seenUpTo(log);
  const key = ["combined", chosen.map(a => a + ":" + paneVer[a] + echoKey(a)), on, full, [...openRuns], noImage.size, paintKey].join("|");
  const keep = $(`#main .pane[data-path="${path}"] .teamlog .feed`)?.dataset.key === key;
  const seg = filterBtn("clanes", "clanes:" + path, on, CALL, CLANES);
  // the chat opened from an agent's menu in this pane: its badge and its message box, under the conversation
  const talk = S.agents.find(a => a.live && a.name === n.chat && chosen.includes(a.name));
  const pick = `data-menu="chatpick:${esc(path)}" data-chat="${esc(path)}" title="Chat with another agent"`;
  const chat = talk ? `<div class="chat"><div class="chead">${n.badge === "icon" || n.badge === "card" ? face(talk, pick, " pick")
    : `<span class="name pick" style="--c:${talk.colour}" ${pick}>${esc(talk.name)}</span>`}<span class="x" data-chat="${esc(path)}" title="Close the chat">${MENU_ICON.close}</span></div>${sayRow(talk)}</div>` : "";
  return `<div class="teamlog combined${full ? "" : " summary"}" data-name="~combined:${path}"><div class="thead">${n.badge === "card" && chosen.length ? `<span class="cnames chrrow">${tiles(paneAgents(n))}</span>`
    : n.badge === "icon" && chosen.length ? `<span class="cnames iconrow">${paneAgents(n).map(a => face(a, `data-name="${esc(a.name)}" title="${esc(a.fullName || a.name)}"`)).join("")}</span>` : `<span class="cnames" title="${chosen.map(x => esc(shown(x))).join(", ")}">${chosen.length ? chosen.map(x => `<span class="name" style="--c:${colours[x] || "#888"}" data-name="${esc(x)}">${esc(shown(x))}</span>`).join("") : "no agents"}</span>`}${seg}${maxButton(big)}</div>` +
    `<div class="feed" data-key="${esc(key)}"${keep ? " data-kept" : ""}>${keep ? "" : !chosen.length ? `<div class="empty">no agent in these roles is running</div>` : feedHtml(log, "", !full, ALL)}</div>${full ? `<button class="newest" title="Back to the newest turn">↓ Newest</button>` : ""}${chat}</div>`;
}
async function loadPaneConvs() {
  if ((localStorage.getItem("page") || "grid") !== "custom") return;
  await Promise.all([loadTeam(), loadFiles(), loadPerf(), loadMeetings(), loadDayLog(), loadWorkQueue(), loadTokens()]);
  const max = localStorage.getItem("custom:max"), names = [...new Set(leaves(layout().root).flatMap(([p, n]) =>
    n.show === "combined" ? paneAgents(n).map(a => a.name) : !fullView(n) && p !== max ? [] : n.show === "agent" ? (n.name ? [n.name] : []) : paneAgents(n).map(a => a.name)))];
  await Promise.all(names.map(async name => {
    try {
      const d = await (await fetch("/api/agent/" + encodeURIComponent(name), {cache: "no-store"})).json();
      const text = JSON.stringify(d.feed);
      if (text !== paneText[name]) { paneConv[name] = d.feed; paneText[name] = text; paneVer[name] = (paneVer[name] || 0) + 1; }
      paneTerm[name] = {screen: d.screen, cols: d.cols || 80, rows: d.rows || 24};
    } catch (e) {}
  }));
}
// A pane dragged by its grip onto another swaps places with it, the pick of tab in a Tabs pane, and the agent a
// Combined pane shows, going with it.
// Redraws wait while it is held, as they do while a divider is dragged.
function movePane(e, grip, from, change) {
  e.preventDefault(); grip.setPointerCapture(e.pointerId);
  const src = grip.closest(".pane"); let over = null;
  src.classList.add("lifted"); document.body.classList.add("moving-pane"); resizing = true;
  const mark = t => { if (t !== over) { over?.classList.remove("drop"); over = t; over?.classList.add("drop"); } };
  grip.onpointermove = m => { const t = document.elementFromPoint(m.clientX, m.clientY)?.closest("#main .pane"); mark(t && t !== src ? t : null); };
  grip.onpointerup = grip.onpointercancel = u => {
    const to = u.type === "pointerup" && over?.dataset.path;
    mark(null); grip.onpointermove = grip.onpointerup = grip.onpointercancel = null;
    src.classList.remove("lifted"); document.body.classList.remove("moving-pane"); resizing = false;
    if (!to) return;
    for (const pre of ["tab:pane:", "focus:pane:"]) {
      const ta = localStorage.getItem(pre + from), tb = localStorage.getItem(pre + to);
      tb == null ? localStorage.removeItem(pre + from) : localStorage.setItem(pre + from, tb);
      ta == null ? localStorage.removeItem(pre + to) : localStorage.setItem(pre + to, ta);
    }
    change(l => { const a = nodeAt(l.root, from), b = nodeAt(l.root, to); putAt(l, from, b); putAt(l, to, a); });
  };
}
// The documents File panes show, by path, read again with every load so a change on disk shows within one refresh.
const fileDocs = {};
async function loadFiles() {
  const paths = [...new Set(leaves(layout().root).filter(([, n]) => n.show === "file" && n.path).map(([, n]) => n.path))];
  await Promise.all(paths.map(async p => {
    const at = Date.now();   // a read begun before a save, ending after it, is older than what was saved
    try {
      const r = await fetch("/doc?p=" + encodeURIComponent(p), {cache: "no-store"});
      if ((fileDocs[p]?.at || 0) <= at) fileDocs[p] = r.ok ? {text: await r.text(), version: r.headers.get("X-Doc-Version"), at} : {status: r.status, at};
    } catch (e) {}
  }));
}
// A File pane's Edit button swaps the document for its raw text in a box, by path while it is open: {orig, text,
// version, msg, bad}. Save (or Ctrl+S) writes it back through /api/doc, which refuses a document changed on disk since
// the edit began (version, the sha256 /doc sent); Close (or Esc) goes back to the document, asking first when there
// are unsaved changes, and Reload reads it again from disk.
const fileEdit = {};
function fileTools(p) {
  const d = fileDocs[p], ed = fileEdit[p];
  if (!ed) return d?.text == null ? "" : `<span class="ftools"><b data-fe="edit" title="Edit the raw text">Edit</b></span>`;
  const moved = !ed.saving && d?.version && d.version !== ed.version;
  const msg = moved && !ed.bad ? "Changed on disk since you began" : ed.msg;
  return `<span class="ftools">${msg ? `<span class="fmsg${ed.bad || moved ? " bad" : ""}">${esc(msg)}</span>` : ""}${ed.bad || moved ? `<b data-fe="reload" title="Read it again from disk, losing your changes">Reload</b>` : ""}` +
    `<span class="fdirty"${ed.text === ed.orig ? " hidden" : ""}>Unsaved</span><b class="go" data-fe="save" title="Save (Ctrl+S)">Save</b><b data-fe="close" title="Back to the document (Esc)">Close</b></span>`;
}
async function fileAct(what, p) {
  const ed = fileEdit[p], dirty = ed && ed.text !== ed.orig;
  if (!p) return;
  if (what === "edit" || what === "reload") {
    if (what === "reload" && dirty && !confirm("Read it again from disk and lose your changes?")) return;
    try {
      const r = await fetch("/doc?p=" + encodeURIComponent(p), {cache: "no-store"});
      if (!r.ok) throw r.status;
      const text = await r.text(), version = r.headers.get("X-Doc-Version");
      fileEdit[p] = {orig: text, text, version}; fileDocs[p] = {text, version, at: Date.now()};
    } catch (e) { if (ed) Object.assign(ed, {msg: "Could not read it", bad: true}); draw(); return; }
    draw();
    // a box already there keeps what was typed in it through a redraw, so it is given the text read
    const t = $("#main").querySelector(`textarea.fedit[data-name="~edit:${CSS.escape(p)}"]`);
    if (t) { t.value = fileEdit[p].text; t.focus(); t.setSelectionRange(0, 0); t.scrollTop = 0; }
  } else if (what === "close") {
    if (dirty && !confirm("Close without saving your changes?")) return;
    delete fileEdit[p]; draw();
  } else if (what === "save" && ed && !ed.saving) {
    ed.saving = true; Object.assign(ed, {msg: "Saving…", bad: false}); draw();
    const text = ed.text;
    const r = await fetch("/api/doc", {method: "POST", headers: {"Content-Type": "application/json", "X-Team-Say": "1"},
      body: JSON.stringify({p, text, version: ed.version})}).catch(() => null);
    ed.saving = false;
    if (r?.ok) {
      const {version} = await r.json();
      Object.assign(ed, {orig: text, version, msg: "Saved " + new Date().toLocaleTimeString("en-GB", {hour: "2-digit", minute: "2-digit"}), bad: false});
      fileDocs[p] = {text, version, at: Date.now()};
    } else Object.assign(ed, {msg: r?.status === 409 ? "Changed on disk since you began: not saved" : r ? (await r.text()).trim() || "Could not save it" : "Could not reach the page's server", bad: true});
    draw();
  }
}
addEventListener("beforeunload", e => { if (Object.values(fileEdit).some(ed => ed.text !== ed.orig)) e.preventDefault(); });
// The list under a File pane's path box: what the folder typed so far holds (/dir), its folders first and then the
// documents the pane can show, narrowed to the names that start with what follows the last "/". Names starting with
// a dot are left out until a dot is typed. A folder, or "..", opens in the box; a document is shown in the pane.
// ↑/↓ choose, Enter or Tab takes the one chosen (Tab the first when none is), Esc closes.
const pickEl = Object.assign(document.createElement("div"), {id: "fpick"});
document.body.append(pickEl);
let fpick = {box: null, at: -1, list: [], show: null};
const pickDirs = {};   // folder -> [when read, its entries], read again after ten seconds
let pickGen = 0;       // a read still in flight when the list is closed is not drawn
async function pickShow(box, show) {
  const gen = pickGen;
  const v = box.value || "~/", cut = v.lastIndexOf("/") + 1, dir = cut ? v.slice(0, cut) : "~/", q = v.slice(cut).toLowerCase();
  let got = pickDirs[dir];
  if (!got || Date.now() - got[0] > 10000) {
    try { const r = await fetch("/dir?p=" + encodeURIComponent(dir), {cache: "no-store"}); got = pickDirs[dir] = [Date.now(), r.ok ? await r.json() : null]; }
    catch (e) { return pickOff(); }
  }
  if (gen !== pickGen || document.activeElement !== box || (box.value || "~/") !== v) return;   // typed on, or left, while it was read
  const list = (got[1] || []).filter(e => e.name.toLowerCase().startsWith(q) && (q.startsWith(".") || !e.name.startsWith(".")))
    .map(e => ({...e, path: dir + e.name + (e.dir ? "/" : "")}));
  if (!q && got[1] && !/^(~|\/(home|Users)\/[^/]+)\/$/.test(dir)) list.unshift({name: "..", dir: true, path: dir.replace(/[^/]+\/$/, "")});
  fpick = {box, at: fpick.box === box ? Math.min(fpick.at, list.length - 1) : -1, list, show};
  pickDraw();
}
function pickDraw() {
  const box = fpick.box, r = box.getBoundingClientRect();
  pickEl.innerHTML = fpick.list.length ? fpick.list.map((e, i) => `<div class="fp${e.dir ? " dir" : ""}${i === fpick.at ? " at" : ""}" data-i="${i}" title="${esc(e.path)}">${esc(e.name)}${e.dir ? "/" : ""}</div>`).join("")
    : `<div class="none">Nothing here the pane can show</div>`;
  pickEl.style.cssText = `display:block;left:${r.left}px;width:${Math.max(r.width, 280)}px;top:${r.bottom + 4}px;max-height:${Math.max(120, innerHeight - r.bottom - 16)}px`;
  pickEl.querySelector(".fp.at")?.scrollIntoView({block: "nearest"});
  pickEl.querySelectorAll(".fp").forEach(el => el.onmousedown = e => { e.preventDefault(); fpick.at = +el.dataset.i; pickDone(); });
}
function pickOff() { pickGen++; fpick = {box: null, at: -1, list: [], show: null}; pickEl.style.display = "none"; }
function pickDone(i = fpick.at) {
  const {box, list, show} = fpick, e = list[i];
  if (!e) return;
  box.value = e.path;
  if (e.dir) { fpick.at = -1; box.setSelectionRange(e.path.length, e.path.length); pickShow(box, show); }
  else { pickOff(); show(); }
}
function pickKey(e, box) {
  if (e.key === "Enter" && fpick.at < 0) return pickOff();
  if (fpick.box !== box) return;
  const n = fpick.list.length;
  if ((e.key === "ArrowDown" || e.key === "ArrowUp") && n) { e.preventDefault(); fpick.at = e.key === "ArrowDown" ? (fpick.at + 1) % n : (fpick.at <= 0 ? n : fpick.at) - 1; pickDraw(); }
  else if (e.key === "Tab" && n) { e.preventDefault(); pickDone(fpick.at < 0 ? 0 : fpick.at); }
  else if (e.key === "Enter" && fpick.at >= 0) { e.preventDefault(); pickDone(); }
  else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); pickOff(); }
}
document.addEventListener("focusout", e => { if (e.target === fpick.box) setTimeout(() => document.activeElement !== fpick.box && pickOff(), 100); });
addEventListener("resize", () => fpick.box && pickDraw());
// Performance and Gauges panes: the machine's CPU, memory, disks, network, GPUs, heat and fans, read again with every load (/api/perf),
// one row each as the List pane has one per agent, with its last ten minutes under it; a click on one opens its graph. Which of them a pane shows
// (n.perf) is chosen with its Show button while the layout is unlocked: all of them until chosen. The CPU, Memory,
// Network, GPU, Heat and Fans bars in the header or footer read the same figures, so the reading also keeps the sampling going for them.
let perfNow = null;
const PERF_BARS = ["cpubar", "membar", "netbar", "gpubar", "heatbar", "fanbar"];
async function loadPerf() {
  const b = barOf();
  if (!leaves(layout().root).some(([, n]) => n.show === "machine") && ![...b.head, ...b.foot].some(k => PERF_BARS.includes(k))) return;
  try { perfNow = await (await fetch("/api/perf", {cache: "no-store"})).json(); } catch (e) {}
}
const PERF_ITEMS = [["cpu", "CPU"], ["mem", "Memory"], ["disk", "Disk"], ["net", "Network"], ["gpu", "GPU"], ["heat", "Heat"], ["fan", "Fans"]];
const PERF_COLOUR = {cpu: "#4f9dff", mem: "#b37feb", disk: "#3fb950", net: "#e3a33b", gpu: "#39c5cf", heat: "#f778ba", fan: "#ff9b72"};
// a figure's colour: the custom theme's for it, while that is the theme, else its own
const perfColour = k => (themeNow() === "custom" && customTheme().perf[k]) || PERF_COLOUR[k];
// sizes in Task Manager's way: 1024 to a K, a GB and so on; a disk's rate in bytes and the network's in bits
const perfSize = (b, unit = "B") => { if (b == null) return "–"; let i = 0; while (b >= 1000 && i < 4) { b /= 1024; i++; } return `${b < 10 && i ? b.toFixed(1) : Math.round(b)} ${["", "K", "M", "G", "T"][i]}${unit}`; };
// used and total in the total's unit: "23 / 31 GB"
const perfOf = (used, total) => { const t = perfSize(total), i = ["", "K", "M", "G", "T"].indexOf(t.split(" ")[1]?.[0] ?? ""), u = (used || 0) / 1024 ** Math.max(0, i);
  return `${u < 10 && i > 0 ? u.toFixed(1) : Math.round(u)} / ${t}`; };
function perfHtml(n) {
  const d = perfNow;
  if (!d || d.warming) return `<div class="blank">Reading…</div>`;
  const h = d.hist || {}, dials = n.machine !== "rows";
  // a label is in its figure's status colour (normal, warning or critical), grey for a rate, which has none;
  // pct is shown as a percentage, or, given unit and colour, as a figure in that unit and colour (the Heat row's °C);
  // a row with a series (sk, its key in the history) opens it as the enlarged graph, its values read as gunit
  const row = (key, name, detail, pct, sk, ceil, tip = "", unit = "%", colour = gauge(pct), gunit = "%") =>
    `<div class="mini perf${dials ? " dial" : ""}" style="--c:${pct == null || unit === " rpm" ? "#8b949e" : colour}" title="${esc(tip)}"${sk && h[sk] ? ` data-series="${esc(sk)}" data-label="${esc(name)}" data-unit="${gunit}"` : ""}>` +
    (dials ? dial(name, detail, pct, sk && h[sk], ceil, unit, colour, gunit, perfColour(key)) :
    `<div class="mtop"><span class="name"><span class="dot"></span>${esc(name)}</span>` +
    `<span class="pdet">${esc(detail)}</span>${pct == null ? "" : `<span class="pct" style="color:${colour}">${Math.round(pct)}${unit}</span>`}</div>` +
    `${sk && h[sk] ? spark(h[sk], ceil, perfColour(key)) : ""}`) + `</div>`;
  const rows = {
    cpu: () => row("cpu", "CPU", `${d.cores} cores`, d.cpu, "cpu", 100, `CPU busy over the last ${d.step * d.keep / 60} minutes`),
    mem: () => { const m = d.mem;
      return row("mem", "Memory", `${perfOf(m.used, m.total)}${m.swap_total ? ` · swap ${perfOf(m.swap_used, m.swap_total)}` : ""}`,
        m.total ? 100 * m.used / m.total : null, "mem", 100, "In use, as Task Manager counts it: what is not available to programs"); },
    disk: () => (d.disk ? row("disk", "Disk", `read ${perfSize(d.disk.read)}/s · write ${perfSize(d.disk.write)}/s`, d.disk.active, "disk",
        d.disk.active == null ? Math.max(1, ...h.disk) : 100, d.disk.active == null ? "Read and written" : "Active time, the busiest disk",
        "%", gauge(d.disk.active), d.disk.active == null ? "B" : "%") : "") +
      d.spaces.map(sp => row("disk", sp.label, `${perfOf(sp.used, sp.total)} · ${perfSize(sp.total - sp.used)} free`, 100 * sp.used / sp.total, null, 0, sp.path)).join(""),
    // an interface is shown while it has carried something in its sparkline's span: a Mac lists several that never do
    net: () => (d.net || []).filter(x => x.in + x.out > 0 || (h["net:" + x.name] || []).some(v => v > 0)).map(x => row("net", x.name, `↓ ${perfSize(x.in * 8, "b")}/s · ↑ ${perfSize(x.out * 8, "b")}/s`, null,
      "net:" + x.name, Math.max(1, ...(h["net:" + x.name] || [])), "Received and sent", "%", undefined, "b")).join("") || row("net", "Network", d.net?.length ? "no traffic" : "no interface", null),
    gpu: () => d.gpus.map(g => row("gpu", d.gpus.length > 1 ? `GPU ${g.id}` : "GPU", [g.name, g.mem_total ? perfOf(g.mem_used, g.mem_total) : g.mem_used ? perfSize(g.mem_used) : "",
      g.temp != null ? `${g.temp} °C` : ""].filter(Boolean).join(" · "), g.pct, "gpu:" + g.id, 100, [g.name, g.pct == null ? "Its use is not reported just now" : ""].filter(Boolean).join("\n"))).join("")
      || row("gpu", "GPU", d.gpu_source === "nvidia-smi" ? "reading…" : "no figures here: no nvidia-smi or AMD card", null),
    // the hottest sensor, green, amber from 80 °C and red from 90 °C, as the Heat bar is; every sensor on a rest
    heat: () => { const t = d.temps, hot = t?.[0]?.c;
      return t?.length ? row("heat", "Heat", `${t[0].name}${t.length > 1 ? ` · hottest of ${t.length} sensors` : ""}`, hot, "heat", 100,
          (d.fans?.length ? "The hottest sensor\n" : "The hottest sensor, standing in for the fans, whose speed is not reported\n") + t.map(x => `${x.name}: ${Math.round(x.c)} °C`).join("\n"),
          " °C", hot >= 90 ? "var(--red)" : hot >= 80 ? "var(--amber)" : "var(--green)", "°C")
        : row("heat", "Heat", t ? (d.heat_source === "windows" || d.heat_source === "sys" ? "no temperature sensors here" : "no temperature: install smctemp or osx-cpu-temp from Homebrew") : "reading…", null); },
    // each fan that has turned, its speed and the share of full power the board gives it; one that stops when cool reads 0
    fan: () => (d.fans || []).map(f => row("fan", f.name, f.duty == null ? (f.rpm ? "" : "stopped") : `${f.rpm ? "" : "stopped · "}power ${f.duty}%`,
        f.rpm, "fan:" + f.name, Math.max(1, ...(h["fan:" + f.name] || [])), "Its speed in turns a minute", " rpm", "var(--text)", "rpm")).join("")
      || "",   // no Fans row while there are no fan readings
  };
  return `<div class="others perfs${dials ? " dials" : ""}">${PERF_ITEMS.map(([k]) => rows[k]()).join("")}</div>`;
}
// A Gauges pane's figure, as a Performance pane would show it but as a gauge: a half-circle filled to its percentage
// (the Heat figure's °C read against 100), or, for a rate with no percentage (the network, a disk's bytes), to its
// latest reading against the highest in its sparkline's span; the figure in the middle in the arc's colour, a rate's
// unit small under its number so the two fit inside the arc, and its name and detail under it.
function dial(name, detail, pct, series, ceil, unit, colour, gunit, own) {
  const last = series ? series[series.length - 1] : null;
  const frac = pct != null ? pct / 100 : last != null && ceil ? last / ceil : null;
  const fill = frac == null ? 0 : Math.max(0, Math.min(1, frac)) * 100;
  const figure = pct != null ? `${Math.round(pct)}${unit}` : last != null ? graphFmt(last, gunit) : "–", stroke = pct != null ? colour : own;
  return `<svg class="arc" viewBox="0 0 100 56"><path class="track" d="M10 50 A40 40 0 0 1 90 50" pathLength="100"/>` +
    (fill > 0 ? `<path d="M10 50 A40 40 0 0 1 90 50" pathLength="100" stroke="${stroke}" stroke-dasharray="${fill.toFixed(1)} 100"/>` : "") + `</svg>` +
    `<div class="dfig${/ \S+$/.test(figure) ? " rate" : ""}" style="color:${figure === "–" ? "var(--faint)" : stroke}">${esc(figure.replace(/ \S+$/, ""))}` +
    `${/ \S+$/.test(figure) ? `<small>${esc(figure.split(" ").pop())}</small>` : ""}</div>` +
    `<div class="dname"><span class="name">${esc(name)}</span></div><div class="pdet">${esc(detail).replace(/(\d) (?=[A-Za-z°])/g, "$1\u00a0")}</div>`;   // a number kept on the line with its unit
}
// A Performance row's enlarged graph, over the page: its series over 2 minutes, 10, an hour or a day (the last chosen,
// kept in this browser), read again every ten seconds while it is open, with gridlines, times along the bottom, its
// latest, average and highest over the span, and the reading under the pointer. A gap in the readings (the page was not
// running) is a gap in the line.
const GRAPH_SPANS = [[120, "2m"], [600, "10m"], [3600, "1h"], [86400, "24h"]];
let graphOf = null, graphTimer = null;
const graphSpan = () => { const v = +localStorage.getItem("graphspan"); return GRAPH_SPANS.some(([s]) => s === v) ? v : 600; };
// a reading in its unit: a percentage, °C, the network's bits a second or the disks' bytes a second
const graphFmt = (v, unit) => v == null ? "–" : unit === "%" ? `${v < 10 && v % 1 ? v.toFixed(1) : Math.round(v)}%` : unit === "°C" ? `${Math.round(v)} °C`
  : unit === "rpm" ? `${Math.round(v)} rpm`
  : unit === "b" ? perfSize(v * 8, "b") + "/s" : perfSize(v) + "/s";
function openGraph(key, label, colour, unit) {
  graphOf = {key, label, colour: colour || "var(--cyan)", unit, data: null};
  $("#graphname").textContent = label; $("#graphsum").textContent = ""; $("#graphbody").innerHTML = `<div class="blank">Reading…</div>`;
  $("#graphbox").classList.add("on");
  clearInterval(graphTimer); graphTimer = setInterval(loadGraph, 10000);
  loadGraph();
}
// The CPU, Memory, Network, GPU, Heat and Fans bars open the graph their Performance rows do, while the layout is locked.
const BAR_GRAPH = {
  cpubar: () => ["cpu", "CPU", "cpu", "%"],
  membar: () => ["mem", "Memory", "mem", "%"],
  heatbar: () => ["heat", "Heat", "heat", "°C"],
  fanbar: () => { const f = (perfNow?.fans || []).reduce((a, b) => !a || b.rpm > a.rpm ? b : a, null); return f && ["fan:" + f.name, f.name, "fan", "rpm"]; },
  gpubar: () => { const g = (perfNow?.gpus || []).reduce((a, b) => !a || b.pct > a.pct ? b : a, null); return g && ["gpu:" + g.id, "GPU", "gpu", "%"]; },
  netbar: () => { const n = (perfNow?.net || []).reduce((a, b) => !a || b.in + b.out > a.in + a.out ? b : a, null); return n && ["net:" + n.name, n.name, "net", "b"]; },
};
addEventListener("click", async e => {
  const bar = e.target.closest(".bi.plug"), of = bar && !barEditing() && BAR_GRAPH[bar.dataset.item];
  if (!of) return;
  await loadPerf();   // the sampling behind the graph, and which network and GPU are the busiest
  const g = of();
  if (g) openGraph(g[0], g[1], perfColour(g[2]), g[3]);
});
function closeGraph() { $("#graphbox").classList.remove("on"); clearInterval(graphTimer); graphOf = null; }
$("#graphbox").onclick = e => { if (e.target.id === "graphbox" || e.target.id === "graphx") closeGraph(); };
$("#graphspan").onclick = e => { const b = e.target.closest("[data-span]"); if (!b) return; localStorage.setItem("graphspan", b.dataset.span); loadGraph(); };
async function loadGraph() {
  const g = graphOf, span = graphSpan();
  $("#graphspan").innerHTML = GRAPH_SPANS.map(([s, t]) => `<b data-span="${s}" class="${s === span ? "on" : ""}">${t}</b>`).join("");
  if (!g) return;
  try {
    const r = await fetch(`/api/perf/history?key=${encodeURIComponent(g.key)}&span=${span}`, {cache: "no-store"});
    if (g !== graphOf) return;
    g.data = r.ok ? await r.json() : {span, step: 10, points: []};
  } catch (e) { return; }
  drawGraph();
}
function drawGraph() {
  const g = graphOf, body = $("#graphbody");
  if (!g?.data) return;
  const {points, span, step} = g.data, now = Date.now() / 1000, vals = points.map(p => p[1]);
  if (!points.length) { body.innerHTML = `<div class="blank">No readings in this span yet</div>`; $("#graphsum").textContent = ""; return; }
  const avg = vals.reduce((a, b) => a + b, 0) / vals.length, top = Math.max(...vals);
  $("#graphsum").textContent = `now ${graphFmt(vals[vals.length - 1], g.unit)} · average ${graphFmt(avg, g.unit)} · highest ${graphFmt(top, g.unit)}`;
  const W = Math.max(200, body.clientWidth - 32), H = Math.max(120, body.clientHeight - 24), L = 64, B = 22;
  const ceil = g.unit === "%" ? 100 : g.unit === "°C" ? Math.max(100, top * 1.1) : Math.max(1, top * 1.15);
  const x = t => L + (W - L) * (t - (now - span)) / span, y = v => (H - B) * (1 - Math.min(v, ceil) / ceil);
  // the line, broken where readings are more than three steps apart
  let line = "", area = "", run = [];
  const flush = () => { if (!run.length) return; const d = run.map((p, i) => (i ? "L" : "M") + x(p[0]).toFixed(1) + " " + y(p[1]).toFixed(1)).join(" ");
    line += d + " "; area += `${d} L${x(run[run.length - 1][0]).toFixed(1)} ${H - B} L${x(run[0][0]).toFixed(1)} ${H - B} Z `; run = []; };
  points.forEach((p, i) => { if (i && p[0] - points[i - 1][0] > step * 3) flush(); run.push(p); });
  flush();
  const grid = [0, .25, .5, .75, 1].map(f => `<line class="grid" x1="${L}" x2="${W}" y1="${y(ceil * f)}" y2="${y(ceil * f)}"/><text x="${L - 8}" y="${y(ceil * f) + 3.5}" text-anchor="end">${graphFmt(ceil * f, g.unit)}</text>`).join("");
  const clock = (t, secs = span <= 120) => new Date(t * 1000).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit", hourCycle: "h23", ...(secs ? {second: "2-digit"} : {})});
  const times = [0, .25, .5, .75, 1].map(f => `<text x="${L + (W - L) * f}" y="${H - 5}" text-anchor="${f === 0 ? "start" : f === 1 ? "end" : "middle"}">${clock(now - span * (1 - f))}</text>`).join("");
  const id = "gg" + Math.random().toString(36).slice(2);
  body.innerHTML = `<svg viewBox="0 0 ${W} ${H}"><defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${g.colour}" stop-opacity=".35"/><stop offset="1" stop-color="${g.colour}" stop-opacity="0"/></linearGradient></defs>` +
    `${grid}${times}<path d="${area}" fill="url(#${id})"/><path d="${line}" fill="none" stroke="${g.colour}" stroke-width="1.8" vector-effect="non-scaling-stroke"/>` +
    `<line class="cursor" y1="0" y2="${H - B}" style="display:none"/><circle r="3.5" fill="${g.colour}" style="display:none"/></svg><div id="graphtip" style="display:none"></div>`;
  const svg = body.querySelector("svg"), cur = svg.querySelector(".cursor"), dot = svg.querySelector("circle"), tip = $("#graphtip");
  svg.onmousemove = e => {
    const box = svg.getBoundingClientRect(), t = (now - span) + span * ((e.clientX - box.left) * W / box.width - L) / (W - L);
    const p = points.reduce((a, b) => Math.abs(b[0] - t) < Math.abs(a[0] - t) ? b : a);
    cur.setAttribute("x1", x(p[0])); cur.setAttribute("x2", x(p[0])); cur.style.display = "";
    dot.setAttribute("cx", x(p[0])); dot.setAttribute("cy", y(p[1])); dot.style.display = "";
    tip.textContent = `${clock(p[0], true)} · ${graphFmt(p[1], g.unit)}`; tip.style.display = "";
    tip.style.left = Math.min(box.width - tip.offsetWidth, Math.max(0, x(p[0]) * box.width / W - tip.offsetWidth / 2)) + 16 + "px";
  };
  svg.onmouseleave = () => { cur.style.display = dot.style.display = tip.style.display = "none"; };
}
addEventListener("resize", () => { if (graphOf) drawGraph(); });
// Where each part of a pane was scrolled to, put back after a redraw: a part that is replaced, or moved as a kept feed
// is, comes back at its top (owner, 2026-11-01: "sometimes when I click the padlock both panes scroll to the very top").
const scrollKey = e => (e.closest("[data-name]")?.dataset.name || "") + "|" + e.className + "|" + (e.dataset.key || "");
function scrolls(root) {
  const m = new Map();
  root.querySelectorAll("*").forEach(e => { if (e.scrollTop > 0) m.set(scrollKey(e), e.scrollTop); });
  return m;
}
function unscroll(root, m) {
  if (!m.size) return;
  root.querySelectorAll("*").forEach(e => {
    const k = scrollKey(e);
    if (m.has(k) && e.scrollTop !== m.get(k)) e.scrollTop = m.get(k);
    if (m.has(k) && e.matches(".feed")) paneFeeds.add(e);
  });
}
// A pane's conversation stays at its newest turn unless it has been scrolled up.
// It is read as it stood at its last scroll: the keyboard opening shrinks it without scrolling it, and that is not
// scrolling up (owner, 2026-11-01: the box moved up but the content did not).
const atEnd = f => f.dataset.end ? f.dataset.end === "1" : f.scrollHeight - f.scrollTop - f.clientHeight < 40;
const markEnd = f => { f.dataset.end = f.scrollHeight - f.scrollTop - f.clientHeight < 40 ? "1" : "0"; };
addEventListener("scroll", e => { if (e.target.matches?.(FEEDS)) markEnd(e.target); }, true);
const FEEDS = "#main :is(.card.full, .teamlog:not(.summary)) .feed";
function paneEnds() { return new Set([...document.querySelectorAll(FEEDS)].filter(atEnd).map(f => f.parentElement.closest("[data-name]").dataset.name)); }
const paneFeeds = new WeakSet();   // the panes' conversations already placed, so a new one starts at its end
function toPaneEnds(ends) {
  document.querySelectorAll(FEEDS + " .ago[data-ts]").forEach(s => { const t = since(s.dataset.ts); if (s.textContent !== t) s.textContent = t; });
  document.querySelectorAll(FEEDS).forEach(f => { if (ends.has(f.parentElement.closest("[data-name]").dataset.name) || !paneFeeds.has(f)) f.scrollTop = f.scrollHeight; paneFeeds.add(f); markEnd(f); });
}
// Any pane can hold tabs (n.tabs, n.tab the one showing), each tab a pane of its own of any type (owner, 2026-11-11:
// "a panel that is tabs and each tab is a panel"): the showing tab's pane lives on the pane itself, where everything
// that draws it reads it, its name (title) among the rest, and each tab's is kept whole in n.tabs and swapped in when
// it is picked. A tab holds one pane, never tabs of its own, so tabs are never nested. A layout saved before a tab's
// name lived on the pane has the showing tab's only in n.tabs, where keepTab leaves it until the tab is renamed.
const TAB_OWN = ["tabs", "tab"];
function keepTab(n) {
  const t = n.tabs[n.tab || 0], title = n.title ?? t.title;
  for (const k of Object.keys(t)) delete t[k];
  Object.assign(t, Object.fromEntries(Object.entries(n).filter(([k]) => !TAB_OWN.includes(k))), title == null ? {} : {title});
}
function showTab(n, i) {
  for (const k of Object.keys(n)) if (!TAB_OWN.includes(k)) delete n[k];
  Object.assign(n, n.tabs[i]);
  n.tab = i;
}
function toTab(n, i) {
  keepTab(n);
  showTab(n, i);
}
function moveTab(n, from, to) {
  keepTab(n);
  const showing = n.tabs[n.tab || 0], [t] = n.tabs.splice(from, 1);
  n.tabs.splice(to, 0, t); n.tab = n.tabs.indexOf(showing);
}
function closeTab(n, i) {
  keepTab(n);
  const at = n.tab || 0;
  n.tabs.splice(i, 1);
  showTab(n, i < at ? at - 1 : Math.min(at, n.tabs.length - 1));
  if (n.tabs.length < 2) { delete n.tabs; delete n.tab; }
}
// The view picker, from a tab's chevron, a pane's + or an empty pane: the views in their groups, the tab's own ticked;
// picked(type) is called with the one clicked.
function viewPicker(btn, path, picked) {
  const key = "views:" + path + ":" + (btn.closest(".ctab")?.dataset.i ?? btn.className);
  if (menuOn(key)) return menuOff(true);
  menuAt(btn, key, PANE_GROUPS.map(([group, list]) => `<div class="mg">${group}</div>` + list.map(([t, line]) =>
    `<div class="mi pvi" data-t="${t}"><i class="pvico">${PANE_ICON[t]}</i><span class="pvt"><b>${PANE_TYPES[t]}</b><small>${line}</small></span>` +
    (t === btn.dataset.cur ? MENU_ICON.check.replace("<svg", '<svg class="tick"') : "") + `</div>`).join("")).join(""));
  menu.querySelectorAll(".pvi").forEach(mi => mi.onclick = () => { menuOff(true); picked(mi.dataset.t); });
}
// A row of role chips keeps to its width: the roles that do not fit, from the end, are hidden behind a +N chip, lit
// while one of them is picked, whose menu ticks and flips them as the chips do.
// A row is fitted again whenever its width changes, as a Characters pane's does once its tiles are measured.
// Only a change of width refits it: fitting hides chips, which must not set off another fit.
const chipRows = new ResizeObserver(es => es.forEach(e => { const w = Math.round(e.contentRect.width);
  if (e.target.fitW !== w) { e.target.fitW = w; e.target.fit?.(); } }));
function fitChips(row, path, flip) {
  if (!row.fit) { row.fit = () => fitChips(row, path, flip); chipRows.observe(row); }
  const chips = [...row.querySelectorAll('.chip[data-role]:not([data-role=""])')], more = row.querySelector(".chip.more");
  if (!row.isConnected || !more) { chipRows.unobserve(row); return; }   // a row a redraw has replaced
  chips.forEach(c => c.hidden = false); more.hidden = true;
  if (row.scrollWidth <= row.clientWidth) return;
  more.hidden = false;
  const gone = [];
  for (let i = chips.length - 1; i >= 0 && (gone.length === 0 || row.scrollWidth > row.clientWidth); i--) {
    chips[i].hidden = true; gone.unshift(chips[i].dataset.role); more.textContent = "+" + gone.length;
  }
  more.classList.toggle("on", chips.some(c => c.hidden && c.classList.contains("on")));
  filterButton(more, roleItems().filter(([r]) => gone.includes(r)), () => rolesPicked(nodeAt(layout().root, path)),
    r => `Show or leave out the ${roleList().find(x => x.role === r)?.name || r}`, flip, "Roles");
}
function customClicks() {
  const main = $("#main"), change = f => { const l = layout(); f(l); saveLayout(l); draw(); };
  main.querySelectorAll(".pbar [data-act]").forEach(el => {
    const path = el.closest(".pane").dataset.path, act = el.dataset.act;
    if (act === "badge") { el.onchange = () => change(l => { nodeAt(l.root, path)[act] = el.value; }); return; }
    if (act === "move") { el.onpointerdown = e => movePane(e, el, path, change); return; }
    if (act === "ticket") { el.onchange = () => { change(l => { const n = nodeAt(l.root, path), v = el.value.trim(); if (v) n.ticket = v; else delete n.ticket; }); }; return; }
    if (act === "path") {
      const show = () => { fileSeen(el.value.trim()); change(l => { nodeAt(l.root, path).path = el.value.trim(); }); setTimeout(load); };
      el.onchange = show; el.onfocus = el.oninput = () => pickShow(el, show); el.onkeydown = e => pickKey(e, el, show);
      return;
    }
    if (act === "view" || act === "machine") el.onclick = () => { change(l => { nodeAt(l.root, path)[act] = el.dataset.v; }); setTimeout(load); };   // a full card needs its conversation
  });
  // a pane's menu: split it either way, or remove it
  main.querySelectorAll(".pane .pmore").forEach(el => el.onclick = e => {
    e.stopPropagation();
    const path = el.closest(".pane").dataset.path;
    if (menuOn(el.dataset.menu)) return menuOff(true);
    menuAt(el, el.dataset.menu, [["row", "Split side by side", PANE_ICON.splitrow], ["col", "Split top and bottom", PANE_ICON.splitcol], ["del", "Remove this pane", MENU_ICON.close]].map(([a, t, i]) =>
      `<div class="mi${a === "del" ? " warn" : ""}" data-a="${a}">${i}${t}</div>`).join(""));
    menu.querySelectorAll("[data-a]").forEach(mi => mi.onclick = () => { menuOff(true); const act = mi.dataset.a; change(l => {
      const n = nodeAt(l.root, path);
      if (act === "del") path === "r" ? putAt(l, "r", {}) : putAt(l, path.slice(0, -1), nodeAt(l.root, path.slice(0, -1))[path.endsWith("a") ? "b" : "a"]);
      else putAt(l, path, {split: act, at: 0.5, a: n, b: {}});
    }); });
  });

  main.querySelectorAll(".agentpick [data-agent]").forEach(el => el.onclick = e => {
    e.stopPropagation();
    const path = el.closest(".pane").dataset.path;
    change(l => { nodeAt(l.root, path).name = el.dataset.agent; }); setTimeout(load);
  });
  main.querySelectorAll(".pown .kchips [data-kind]").forEach(el => el.onclick = () => {
    const path = el.closest(".pane").dataset.path, k = el.dataset.kind;
    change(l => { const n = nodeAt(l.root, path), on = Array.isArray(n.kinds) ? n.kinds : [], next = !k ? [] : on.includes(k) ? on.filter(x => x !== k) : [...on, k];
      if (next.length) n.kinds = next; else delete n.kinds; });
  });
  main.querySelectorAll(".workq [data-owner]").forEach(el => el.onclick = e => {
    e.stopPropagation();
    const path = el.closest(".pane").dataset.path;
    change(l => { const n = nodeAt(l.root, path); if (n.owner === el.dataset.owner) delete n.owner; else n.owner = el.dataset.owner; });
  });
  main.querySelectorAll(".frecent [data-recent]").forEach(el => el.onclick = () => {
    const path = el.closest(".pane").dataset.path; fileSeen(el.dataset.recent);
    change(l => { nodeAt(l.root, path).path = el.dataset.recent; }); setTimeout(load);
  });
  main.querySelectorAll(".meetpick [data-invite]").forEach(el => el.onclick = () => {
    const path = el.closest(".pane").dataset.path;
    change(l => { const n = nodeAt(l.root, path); meetInvite(n, [el.dataset.invite], !inMeeting(n, meetTeam().find(a => a.name === el.dataset.invite) || {})); });
  });
  // a pane's role chips: All shows every role; a role picked alone from All, then added or taken out, and All again
  // once none is left
  main.querySelectorAll(".pbar .chips").forEach(row => {
    const path = row.closest(".pane").dataset.path;
    if (row.querySelector("[data-invite-role]")) {
      const invite = r => change(l => { const n = nodeAt(l.root, path);
        if (!r) { delete n.who; return; }
        const them = meetTeam().filter(a => a.role === r);   // from Invite all, a role's chip invites that role alone
        if (!Array.isArray(n.who)) n.who = them.map(a => "name:" + a.name); else meetInvite(n, them.map(a => a.name), !them.every(a => inMeeting(n, a)));
      });
      row.querySelectorAll(".chip[data-invite-role]").forEach(c => c.onclick = () => invite(c.dataset.inviteRole));
      fitChips(row, path, invite);
      return;
    }
    const flip = r => { change(l => { const n = nodeAt(l.root, path), on = rolesPicked(n), next = !r ? [] : on.includes(r) ? on.filter(x => x !== r) : [...on, r];
      if (PICK_VIEWS.includes(n.show)) return pickRole(n, r);
      if (next.length) n.roles = next; else delete n.roles; }); setTimeout(load); };
    row.querySelectorAll(".chip[data-role]").forEach(c => c.onclick = () => flip(c.dataset.role));
    fitChips(row, path, flip);
  });


  // the meeting's bar: Start (with the topic typed beside it), Add, Pause or Resume, End, and New meeting once ended
  main.querySelectorAll(".meetbar [data-meet]").forEach(el => el.onclick = async e => {
    const path = el.closest(".pane").dataset.path, n = nodeAt(layout().root, path), m = meetOf(n), what = el.dataset.meet;
    if (what === "add") { e.stopPropagation(); return meetAdd(el, path); }
    if (what === "start") {
      const topic = el.closest(".meetbar").querySelector(".mtopic")?.value.trim() || "";
      const d = await meetPost(null, "start", {who: meetInvited(n).map(a => a.name), topic, view: shownView().name || ""});
      if (d?.id) change(l => { nodeAt(l.root, path).meeting = d.id; });
      else if (d?.error) alert("The meeting did not start. " + d.error);
      setTimeout(load);
    } else if (what === "new") change(l => { delete nodeAt(l.root, path).meeting; });
    else if (m && what === "pause") meetPost(m.id, "pause", {on: !m.paused});
    else if (m && what === "end") meetPost(m.id, "end");
  });
  // a suggestion at the meeting's end: Send sends it as its box now reads; Skip sends nothing
  main.querySelectorAll(".hand [data-hand]").forEach(el => el.onclick = () => {
    const h = el.closest(".hand"), m = meetOf(nodeAt(layout().root, el.closest(".pane").dataset.path));
    if (m) meetPost(m.id, "handover", {name: h.dataset.n, action: el.dataset.hand, text: h.querySelector(".htext")?.value || ""});
  });
  main.querySelectorAll(".teamlog .clanes").forEach(el => {
    const path = el.closest(".pane").dataset.path;
    filterButton(el, CLANES, () => clanesOf(nodeAt(layout().root, path)), l => CLANE_TIP[l], lane => change(l => {
      const n = nodeAt(l.root, path), on = clanesOf(n);
      n.clanes = on.includes(lane) ? on.filter(x => x !== lane) : [...on, lane];
      delete n.lanes;
    }));
  });
  // a pane's tabs: picked, added (a copy of the one showing), renamed or closed
  const tabbed = (el, f) => { const path = el.closest(".pane").dataset.path; change(l => f(nodeAt(l.root, path))); setTimeout(load); };
  const atPane = (path, f) => { change(l => f(nodeAt(l.root, path))); setTimeout(load); };
  // the tab showing is renamed in place: a double-click on it gives a box for its name, Enter or a click away keeps
  // it, Esc leaves it as it was; kept empty, the tab is named from what it shows again
  const rename = el => {
    if (!el || pageLocked() || el.querySelector(".ctname")) return;
    const label = el.querySelector(".ctl"), was = label.textContent, box = Object.assign(document.createElement("input"), {className: "ctname", value: was});
    let done = false;
    const end = keep => { if (done) return; done = true; const v = box.value.trim();
      box.remove(); label.hidden = false;
      if (keep && v !== was) tabbed(el, n => { if (v) n.title = v; else { delete n.title; if (n.tabs) delete n.tabs[n.tab || 0].title; } }); else draw(); };
    box.onkeydown = e => { e.stopPropagation(); if (e.key === "Enter") end(true); else if (e.key === "Escape") end(false); };
    box.onblur = () => end(true);
    el.draggable = false; label.hidden = true; label.after(box); box.focus(); box.select();
  };
  // a tab dragged along the strip is put where it is dropped, before or after the tab under the pointer
  let dragged = null;
  main.querySelectorAll(".pane .ctab[draggable]").forEach(el => {
    const side = e => { const r = el.getBoundingClientRect(); return e.clientX < r.left + r.width / 2 ? "before" : "after"; };
    const clear = () => main.querySelectorAll(".ctab.before, .ctab.after").forEach(t => t.classList.remove("before", "after"));
    el.ondragstart = e => { dragged = el; e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", ""); el.classList.add("dragging"); };
    el.ondragend = () => { mouseDown = false; dragged = null; el.classList.remove("dragging"); clear(); };
    el.ondragover = e => {
      if (!dragged || dragged === el || dragged.parentElement !== el.parentElement) return;
      e.preventDefault(); clear(); el.classList.add(side(e));
    };
    el.ondrop = e => {
      if (!dragged || dragged === el || dragged.parentElement !== el.parentElement) return;
      e.preventDefault(); mouseDown = false;
      const from = +dragged.dataset.i, at = +el.dataset.i + (side(e) === "after" ? 1 : 0);
      tabbed(el, n => moveTab(n, from, at > from ? at - 1 : at));
    };
  });
  main.querySelectorAll(".pane .ctab").forEach(el => {
    el.onclick = e => {
      if (e.target.closest(".ctname")) return;
      const path = el.closest(".pane").dataset.path, i = +el.dataset.i, cv = e.target.closest(".cv");
      if (cv) { e.stopPropagation(); viewPicker(cv, path, t => atPane(path, n => { if (n.tabs && i !== (n.tab || 0)) toTab(n, i); n.show = t; })); }
      else if (e.target.closest(".cx")) tabbed(el, n => closeTab(n, i));
      else if (!el.classList.contains("sel")) tabbed(el, n => toTab(n, i));
    };
    el.ondblclick = e => { if (el.classList.contains("sel") && !e.target.closest(".cv, .cx")) rename(el); };
  });
  // + adds a tab of the view picked for it, showing every role; an empty pane picks its first view
  main.querySelectorAll(".pane .cadd").forEach(el => el.onclick = e => {
    e.stopPropagation();
    const path = el.closest(".pane").dataset.path;
    viewPicker(el, path, t => atPane(path, n => {
      if (!n.tabs?.length) { n.tabs = [{}]; n.tab = 0; }
      keepTab(n); n.tabs.push({show: t}); toTab(n, n.tabs.length - 1);
    }));
  });
  main.querySelectorAll(".pane .pchoose").forEach(el => el.onclick = e => {
    e.stopPropagation();
    const path = el.closest(".pane").dataset.path;
    viewPicker(el, path, t => atPane(path, n => { n.show = t; }));
  });
  main.querySelectorAll(".teamlog .agents.fbtn").forEach(el => {
    const path = el.closest(".pane").dataset.path;
    filterButton(el, teamItems(), () => { const hide = nodeAt(layout().root, path).hide || []; return teamNames().filter(x => !hide.includes(x)); },
      x => `Show or leave out ${x}'s messages`, x => change(l => {
        const n = nodeAt(l.root, path), hide = new Set(n.hide || []);
        hide.has(x) ? hide.delete(x) : hide.add(x); n.hide = [...hide];
      }), "Agents");
  });
  // An agent in the list ("others") or a tile ("characters"), or a turn in a Team pane (the agent on the name clicked, else
  // the turn's own): one with a card in a pane gets the cursor in its message box, any other has its view opened. One in
  // a tabs pane behind another tab is brought to the front first. In a Combined pane (its header or a turn) see pick.
  const goTo = name => {
    const box = () => main.querySelector(`.pane .card[data-name="${CSS.escape(name)}"] .say`);
    const tabs = !box() && leaves(layout().root).find(([, n]) => n.show === "tabs" && paneAgents(n).some(a => a.name === name));
    if (tabs) { localStorage.setItem("tab:pane:" + tabs[0], name); draw(); }
    box() ? aim(box()) : openDetail(name);
  };
  // an agent that is not running has nothing to open: a click on its row or tile opens its menu instead, as a tap
  // does on a touch screen, where nothing rests on it (the menu's Open goes to it)
  const open = m => m.classList.contains("off") || touched ? menuSoon(m, 0) : (menuOff(true), pick(m, m.dataset.name));
  // in a Combined pane, the agent fills the pane; anywhere else, goTo
  const pick = (el, name) => {
    const path = el.closest(".pane")?.dataset.path;
    if (!path || !el.closest(".teamlog.combined") || nodeAt(layout().root, path)?.show !== "combined") return goTo(name);
    localStorage.setItem("focus:pane:" + path, name); draw();
    const box = main.querySelector(`.pane[data-path="${path}"] .card[data-name="${CSS.escape(name)}"] .say`);
    if (box) aim(box);
  };
  main.querySelectorAll(".mini.perf[data-series]").forEach(m => m.onclick = () => openGraph(m.dataset.series, m.dataset.label, m.style.getPropertyValue("--c"), m.dataset.unit));
  main.querySelectorAll(".others .mini:not(.perf)").forEach(m => {
    m.onclick = () => open(m);
    m.onmouseenter = () => menuSoon(m, 350); m.onmouseleave = () => { clearTimeout(menuShow); if (menu.dataset.rested) menuOff(); };
    m.oncontextmenu = e => { e.preventDefault(); menuSoon(m, 0); };
  });
  main.querySelectorAll(".chrs .chr, .chrrow .chr, .iconrow .face, .combined .cnames .name").forEach(m => {
    m.onclick = () => open(m);
    m.onkeydown = e => { if (e.key === "Enter" || e.key === " ") { e.preventDefault(); open(m); } };
    m.onmouseenter = () => menuSoon(m, 350); m.onmouseleave = () => { clearTimeout(menuShow); if (menu.dataset.rested) menuOff(); };
    m.oncontextmenu = e => { e.preventDefault(); menuSoon(m, 0); };
  });
  menuGo = (name, from) => from ? pick(from, name) : goTo(name);   // from an agent in a Combined pane, it fills the pane
  main.querySelectorAll(".teamlog:not(.combined) .thead .name").forEach(el => el.onclick = () => goTo(el.dataset.name));   // a Combined pane's are above
  main.querySelectorAll(".teamlog .feed").forEach(f => f.onclick = e => {
    const row = e.target.closest(".it[data-agent]");
    if (!row || !getSelection().isCollapsed || e.target.closest("a, img, .thumbs, pre, [data-run]")) return;
    const named = e.target.closest(".who")?.textContent, name = S.agents.some(a => a.name === named) ? named : row.dataset.agent;
    if (S.agents.some(a => a.name === name)) pick(f, name);
  });
  // a card over a Combined view starts below its header, so the agents along it show, greyed, above the card
  main.querySelectorAll(".paneover").forEach(o => {
    const h = o.parentElement.querySelector(".teamlog > .thead");
    if (h) o.style.paddingTop = (h.getBoundingClientRect().bottom - o.getBoundingClientRect().top + 8) + "px";
    const name = localStorage.getItem("focus:pane:" + o.closest(".pane").dataset.path);   // its agent's own icon stays clear
    h?.querySelectorAll(".cnames [data-name]").forEach(el => el.classList.toggle("focal", el.dataset.name === name));
    const f = o.querySelector(".feed");   // one at its newest turn stays there, now it is shorter
    if (f?.dataset.end === "1") f.scrollTop = f.scrollHeight;
  });
  // the greyed agent under a point on a card's overlay, which lies over them and takes their clicks
  const greyedAt = (o, e) => document.elementsFromPoint(e.clientX, e.clientY).find(el => el.matches(".cnames [data-name]") && el.closest(".pbody") === o.parentElement);
  main.querySelectorAll(".paneover").forEach(o => o.onmousemove = e => { o.style.cursor = e.target === o && greyedAt(o, e) ? "pointer" : ""; });
  // the back button, or a click on the greyed Combined view round the card, closes it; a click on a greyed agent opens that agent
  main.querySelectorAll(".pane .backbtn, .paneover").forEach(b => b.onclick = e => {
    if (b.matches(".paneover") && e.target !== b) return;
    e.stopPropagation();
    const other = b.matches(".paneover") && greyedAt(b, e);
    if (other) return open(other);
    localStorage.removeItem("focus:pane:" + b.closest(".pane").dataset.path); draw();
  });
  main.querySelectorAll(".pane .termseg b").forEach(b => b.onclick = e => { e.stopPropagation(); localStorage.setItem("term", termOn() ? "off" : "on"); draw(); });
  main.querySelectorAll(".card.full > .termwrap").forEach(w => w.onclick = e => {
    e.stopPropagation();
    if (!w.classList.contains("big")) paneBig = w.closest(".card").dataset.name;
    else if (e.target === w || e.target.matches(".pzoom, .x")) paneBig = null;
    else return;
    draw();
  });
  main.querySelectorAll(".filelog [data-fe]").forEach(b => b.onclick = () => fileAct(b.dataset.fe, nodeAt(layout().root, b.closest(".pane").dataset.path)?.path));
  main.querySelectorAll(".filelog textarea.fedit").forEach(t => {
    const p = nodeAt(layout().root, t.closest(".pane").dataset.path)?.path;
    t.oninput = () => { const ed = fileEdit[p]; if (!ed) return; ed.text = t.value; t.closest(".filelog").querySelector(".fdirty").hidden = ed.text === ed.orig; };
    t.onkeydown = e => {
      if ((e.ctrlKey || e.metaKey) && !e.altKey && e.key.toLowerCase() === "s") { e.preventDefault(); fileAct("save", p); }
      else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); fileAct("close", p); }
    };
  });
  main.querySelectorAll(".pane .maxbtn").forEach(b => b.onclick = e => {
    e.stopPropagation();
    if (!unmax()) { localStorage.setItem("custom:max", b.closest(".pane").dataset.path); localStorage.setItem("custom:maxname", b.closest("[data-name]").dataset.name); load(); }
  });
  main.querySelectorAll(".card.full, .teamlog.combined:not(.summary)").forEach(c => {
    const f = c.querySelector(".feed"), btn = c.querySelector(".newest");
    const show = () => { btn.style.bottom = (c.getBoundingClientRect().bottom - f.getBoundingClientRect().bottom + 12) + "px"; btn.classList.toggle("on", !atEnd(f)); };
    f.onscroll = show; show();
    btn.onclick = e => { e.stopPropagation(); f.scrollTo({top: f.scrollHeight, behavior: "smooth"}); };
  });
  main.querySelectorAll(":is(.card.full, .teamlog) .folded").forEach(f => f.onclick = e => { e.stopPropagation(); const k = f.dataset.run; openRuns.has(k) ? openRuns.delete(k) : openRuns.add(k); draw(); });
  main.querySelectorAll(".divider.drag").forEach(d => d.onpointerdown = e => {
    e.preventDefault(); d.setPointerCapture(e.pointerId); d.classList.add("moving");
    const lay = d.parentElement, row = lay.classList.contains("row"), r = lay.getBoundingClientRect(), [h1, h2] = lay.querySelectorAll(":scope > .half");
    document.body.classList.add(row ? "resizing" : "resizing-row"); resizing = true;
    const side = tileSide(nodeAt(layout().root, d.dataset.path));
    let at = null, tiles = null;
    // Free dividers snap, within SNAP px, to the middle of the page and into line with the other dividers that run the
    // same way (two columns each split top and bottom line up their rows). The lines are read once: a drag moves only
    // what is inside this split.
    const m = $("#main").getBoundingClientRect(), mid = rc => row ? rc.left + rc.width / 2 : rc.top + rc.height / 2;
    const lines = side ? [] : [mid(m), ...[...main.querySelectorAll(`.lay.${row ? "row" : "col"} > .divider`)]
      .filter(x => !lay.contains(x)).map(x => mid(x.getBoundingClientRect()))];
    const guide = $(".snapguide") || document.body.appendChild(Object.assign(document.createElement("div"), {className: "snapguide"}));
    d.onpointermove = mv => {
      if (side && row) {
        const w = side === "a" ? mv.clientX - r.left : r.right - mv.clientX;
        tiles = Math.max(1, Math.min(3, Math.round((w - 18) / 120)));
        (side === "a" ? h1 : h2).style.flexBasis = tilesWidth(tiles) + "px";
        return;
      }
      if (side) {
        const h = side === "a" ? mv.clientY - r.top : r.bottom - mv.clientY, bar = tilesHeight(0, d.dataset.path + side);
        tiles = Math.max(1, Math.min(3, Math.round((h - bar) / 120)));
        (side === "a" ? h1 : h2).style.flexBasis = tilesHeight(tiles, d.dataset.path + side) + "px";
        return;
      }
      const pos = row ? mv.clientX : mv.clientY, near = lines.filter(x => Math.abs(x - pos) <= SNAP).sort((x, y) => Math.abs(x - pos) - Math.abs(y - pos))[0];
      const dw = row ? d.offsetWidth : d.offsetHeight, start = row ? r.left : r.top, span = (row ? r.width : r.height) - dw;
      at = Math.max(0.1, Math.min(0.9, ((near ?? pos) - dw / 2 - start) / span));
      h1.style.flexGrow = at; h2.style.flexGrow = 1 - at;
      guide.classList.toggle("on", near != null);
      if (near != null) Object.assign(guide.style, row ? {left: near + "px", top: m.top + "px", width: 0, height: m.height + "px", borderLeftWidth: "1px", borderTopWidth: 0}
        : {left: m.left + "px", top: near + "px", width: m.width + "px", height: 0, borderTopWidth: "1px", borderLeftWidth: 0});
    };
    d.onpointerup = () => {
      d.onpointermove = null; d.classList.remove("moving"); $(".snapguide")?.classList.remove("on"); document.body.classList.remove("resizing", "resizing-row"); resizing = false;
      if (tiles != null) change(l => { nodeAt(l.root, d.dataset.path).tiles = tiles; });
      else if (at != null) change(l => { nodeAt(l.root, d.dataset.path).at = +at.toFixed(3); });
    };
  });
}

// Every pulse keeps time with the page's clock, so a card redrawn mid-beat carries on where its last copy was.
function beat() {
  for (const a of document.getAnimations()) if (a instanceof CSSAnimation && a.startTime !== 0) a.startTime = 0;
}

// Each agent in its colour: while the theme is Custom, its own there, else its role's there; else its role's (the server's).
function paintAgents() {
  const c = themeNow() === "custom" ? customTheme() : {agents: {}, roles: {}};
  for (const a of [...S.agents, ...S.bench]) a.colour = c.agents[a.name] || c.roles[a.role] || a.roleColour;
  colours = Object.fromEntries([...S.agents, ...S.bench].map(a => [a.name, a.colour]));
  paintKey = Object.values(colours).join();   // in the conversations' keys, so a feed kept as drawn is drawn again in new colours
}
async function load() {
  try {
    S = await (await fetch("/api/state", {cache: "no-store"})).json();
    await loadPaneConvs();
    for (const a of [...S.agents, ...S.bench]) a.roleColour = a.colour;
    paintAgents();
    draw();
    if (menu.classList.contains("on")) menu.refresh?.();
  } catch (e) {
    // a server that cannot be reached and an error while drawing both land here; the pill's title and the console say which
    console.error("agents-web refresh failed", e);
    const why = e instanceof TypeError && /fetch/i.test(e.message) ? "The page server cannot be reached" : `${e.name}: ${e.message}${e.stack ? "\n" + e.stack.split("\n").slice(1, 4).join("\n") : ""}`;
    $("#counts").innerHTML = `<span class="pill" style="color:var(--red)" title="${esc(why)}">offline</span>`;
    $("#counts").dataset.html = "";
  }
}

// What the owner has seen of each agent's conversation, as the time of its newest turn when they last saw it: every
// agent whose card is on the page (in tabs, only the picked one), and the open one while its view is. A message from an agent, or to or from
// it, newer than that is unseen. It is counted only in the lanes the agent's card shows, and once per message: the
// pieces of one reply, between its tool calls, are one message, and a message from the owner ends one.
const seen = JSON.parse(localStorage.getItem("seen") || "{}");
const SEEN_KINDS = ["said", "peer", "sent"];
function markSeen(names) {
  for (const a of S.agents) {
    if (!names.includes(a.name)) continue;
    const newest = a.feed.reduce((m, it) => it.ts && it.ts > m ? it.ts : m, "");
    if (newest > (seen[a.name] || "")) seen[a.name] = newest;
  }
  localStorage.setItem("seen", JSON.stringify(seen));
}
// a message shown in a Combined pane has been seen, as an agent's card counts its own as seen
function seenUpTo(items) {
  for (const it of items) if (SEEN_KINDS.includes(it.kind) && it.ts > (seen[it._agent] || "")) seen[it._agent] = it.ts;
  localStorage.setItem("seen", JSON.stringify(seen));
}
const unseenBadge = n => `<span class="unseen" title="${n} message${n > 1 ? "s" : ""} since you last looked">${n >= 10 ? "10+" : n}</span>`;
function unseen(a) {
  if (!seen[a.name]) return 0;
  const on = laneOf(a.name);
  let n = 0, prev = "";
  for (const it of a.feed) {
    if (it.kind === "owner") { prev = ""; continue; }
    if (!SEEN_KINDS.includes(it.kind) || !on.includes(it.lane)) continue;
    const key = it.kind + ":" + it.who;
    if (key !== prev && it.ts && it.ts > seen[a.name]) n++;
    prev = key;
  }
  return n;
}

// The column of every agent beside an open one, the open one marked: name with its state and unseen count (as a tab),
// ticket, how long, context and burn.
// " waking" while the page is starting the agent (alone or with the team), " switching" while it is stopping it, for its
// card, tab, List row, tile and icon.
const switching = a => !a.live && S.starting.includes(a.name) ? " waking" : a.live && S.halting.includes(a.name) ? " switching" : "";
function minis(cur, agents = S.agents) {
  const ceil = Math.max(1, ...S.agents.flatMap(a => a.series));
  return agents.map(a => {
    const st = stOf(a), n = a.name === cur ? 0 : unseen(a);
    return `<div class="mini ${st}${switching(a)}${a.name === cur ? " cur" : ""}" style="--c:${a.colour}" data-name="${esc(a.name)}">
      <div class="mtop"><span class="name" title="${st === "wanted" ? esc(a.wanted) : STATE[st] || esc(st)}"><span class="dot"></span>${esc(shown(a.name))}${n ? unseenBadge(n) : ""}</span>${a.ticket ? `<span class="ticket" title="${esc(a.ticket)}">${esc(a.ticket)}</span>` : ""}<span class="mstat" title="${esc(mstat(a, st))}">${esc(mstat(a, st))}</span><span class="ago">${ago(a.held)}</span>${a.ctxPct == null ? "" : `<span class="pct" style="color:${gauge(a.ctxPct)}" title="${a.ctxPct}% of context used">ctx ${a.ctxPct}%</span>`}</div>
      ${spark(a.series, ceil, a.colour)}</div>`;
  }).join("");
}
// Characters: each agent's tile. Its portrait is <name>.png/.webp/.jpg in ~/.claude/agents-portraits when there is
// one, else the shadow of its role (shadow). Round
// the portrait: its last activity (green within the minute) and how long ago, its context, its unseen count, its
// ticket and its activity.
// A shadow for an agent with no portrait: a head and shoulders in its colour, faint, with its role's prop in the full
// colour (the lead's cap, a developer's headphones, a tester's clipboard, the head of testing's clipboard and crown,
// production support's on-call beacon, the reviewer's glasses and pen, process improvement's hard hat, the assistant's
// hair and bow tie). A tile showing a shadow carries the agent's name on its chest (tiles, .nm); a portrait is left
// as drawn.
const PROPS = {
  lead: `<path d="M29 33 L25 21 Q50 9 75 21 L71 33 Z" class="p"/><path d="M28 33 H72 V37 H28 Z" class="k"/><path d="M33 37 Q50 47 67 37 Z" class="k"/><circle cx="50" cy="24" r="3.2" class="b"/>`,
  dev: `<path d="M30 45 A20 20 0 0 1 70 45" class="s" stroke-width="5"/><rect x="25" y="40" width="9" height="15" rx="3.5" class="p"/><rect x="66" y="40" width="9" height="15" rx="3.5" class="p"/>`,
  tester: `<rect x="62" y="66" width="22" height="28" rx="3" class="p"/><rect x="65" y="71" width="16" height="20" rx="1" class="b"/><rect x="68" y="63" width="10" height="6" rx="2" class="k"/><path d="M68.5 81 l4 4 l7 -8" class="s" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/>`,
  hot: `<rect x="62" y="66" width="22" height="28" rx="3" class="p"/><rect x="65" y="71" width="16" height="20" rx="1" class="b"/><rect x="68" y="63" width="10" height="6" rx="2" class="k"/><path d="M68.5 81 l4 4 l7 -8" class="s" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"/><path d="M36 31 L38 17 L44 24 L50 14 L56 24 L62 17 L64 31 Z" class="p"/>`,
  review: `<path d="M34 45 h13 a6.5 6.5 0 0 1 -13 0z M53 45 h13 a6.5 6.5 0 0 1 -13 0z" class="p"/><path d="M47 45 h6" class="s" stroke-width="2"/><path d="M80 96 L88 62" class="s" stroke-width="5" stroke-linecap="round"/><path d="M86 61 L89 54 L91 62 Z" class="p"/>`,
  support: `<path d="M50 8 V13 M37 12 L40.5 16 M63 12 L59.5 16 M32 20 L36.5 21.5 M68 20 L63.5 21.5" class="s" stroke-width="2.6" stroke-linecap="round"/><path d="M42.5 25 A7.5 7.5 0 0 1 57.5 25 Z" class="k"/><rect x="39" y="25" width="22" height="5" rx="1.5" class="p"/>`,
  process: `<path d="M31 37 A19 18 0 0 1 69 37 Z" class="p"/><path d="M24 36 H76 V41 H24 Z" class="p"/><path d="M50 20 V36" class="k" stroke-width="3"/>`,
  pa: `<path d="M33 40 Q34 25 50 25 Q66 25 67 40 Q61 31 50 32 Q39 31 33 40 Z" class="p"/><path d="M38 64 L50 70 L38 76 Z M62 64 L50 70 L62 76 Z" class="p"/><circle cx="50" cy="70" r="3" class="p"/>`,
};
PROPS.ops = PROPS.support;   // the head of operations keeps production support's beacon (owner, 2026-11-01)
function shadow(a) {
  const c = a.colour;
  const prop = (PROPS[a.role] || "").replace(/class="p"/g, `fill="${c}"`).replace(/class="k"/g, `fill="${c}" stroke="${c}" fill-opacity=".7"`)
    .replace(/class="b"/g, `fill="var(--chtile)"`).replace(/class="s"/g, `fill="none" stroke="${c}"`);
  return `<svg viewBox="0 0 100 100" aria-hidden="true"><rect width="100" height="100" rx="18" fill="${c}" fill-opacity=".1"/>` +
    `<g fill="${c}" fill-opacity=".38"><circle cx="50" cy="44" r="17"/><path d="M14 100 C14 77 30 66 50 66 C70 66 86 77 86 100 Z"/></g>${prop}</svg>`;
}
// Shadows with a clipboard on the right have the name to its left.
const LEFT_BADGE = new Set(["tester", "hot"]);
// An agent as a small Characters tile: its portrait, else its role's shadow with the agent's initial bottom left, over
// a bar in its colour. A running agent's tile carries its state, so a waiting one flashes like its Characters tile; the
// bench's have none. One the page is starting or stopping pulses.
const face = (a, attrs, cls = "") => `<span class="face${cls}${"live" in a ? " " + stOf(a) : ""}${switching(a)}" style="--c:${a.colour}" ${attrs}>${a.portrait ? `<img src="${esc(a.portrait)}" alt="${esc(shown(a.name))}">` : shadow(a) + `<span class="ini">${esc([...a.name][0] || "")}</span>`}</span>`;
function tiles(them) {
  const ceil = Math.max(1, ...S.agents.flatMap(a => a.series)), nowS = Date.now() / 1000;
  return them.map(a => {
    // a benched agent: its portrait or shadow, greyed, and "on the bench"; its menu has its details (and a standing one's Start)
    if (!a.feed) return `<div class="chr off bench" role="button" tabindex="0" style="--c:${a.colour}" data-name="${esc(a.name)}" aria-label="${esc(shown(a.name))}, on the bench">` +
      `<span class="por">${a.portrait ? `<img src="${esc(a.portrait)}" alt="">` : shadow(a)}</span>` +
      `<span class="nm${LEFT_BADGE.has(a.role) ? " left" : ""}">${esc(shown(a.name))}</span><span class="tk">on the bench</span></div>`;
    const st = stOf(a), n = unseen(a);
    const last = a.feed.reduce((m, it) => it.ts && it.ts > m ? it.ts : m, ""), since = last ? Math.max(0, Math.round(nowS - Date.parse(last) / 1000)) : a.held;
    return `<div class="chr ${st}${switching(a)}" role="button" tabindex="0" style="--c:${a.colour}" data-name="${esc(a.name)}" aria-label="${esc(shown(a.name))}"${st === "wanted" ? ` title="${esc(shown(a.name))} wants you: ${esc(a.wanted)}"` : ""}>` +
      `<span class="por">${a.portrait ? `<img src="${esc(a.portrait)}" alt="">` : shadow(a)}</span>` +
      `<span class="nm${LEFT_BADGE.has(a.role) ? " left" : ""}">${esc(shown(a.name))}</span>` +
      `<span class="tl"><i class="${since != null && since < 60 ? "now" : ""}"></i>${since == null ? "" : ago(since)}</span>` +
      `<span class="tr">${a.ctxPct == null ? "" : `<b class="${a.ctxPct >= 60 ? "hi" : ""}" title="${a.ctxPct}% of context used">${a.ctxPct}%</b>`}${n ? unseenBadge(n) : ""}</span>` +
      (a.ticket ? `<span class="tk" title="${esc(a.ticket)}">${esc(a.ticket)}</span>` : "") +
      `<span class="sp">${spark(a.series, ceil, a.colour)}</span></div>`;
  }).join("");
}
function rail() {
  if (!open || !S) return;
  markSeen(S.agents.filter(a => !seen[a.name] || a.name === open).map(a => a.name));
  patch($("#drail"), minis(open));
  document.querySelectorAll("#drail .mini").forEach(m => {
    if (m.matches(".cur")) m.dataset.menu = "agent:" + m.dataset.name;   // the agent in the view: a click opens or shuts its menu
    m.onclick = () => m.matches(".off, .cur") || touched ? menuSoon(m, 0) : (menuOff(true), openDetail(m.dataset.name));
    m.onmouseenter = () => menuSoon(m, 350); m.onmouseleave = () => { clearTimeout(menuShow); if (menu.dataset.rested) menuOff(); };
    m.oncontextmenu = e => { e.preventDefault(); menuSoon(m, 0); };
  });
  beat();
}

// The open agent's facts beside its name: its state and for how long, model and effort, context used, burn, and
// where it sits and works. Redrawn with the page.
function facts() {
  const a = open && S && S.agents.find(x => x.name === open), el = $("#dfacts");
  if (!a || !el) return;
  const st = stOf(a);
  const ctx = a.ctxUsed == null ? "" : `<span title="Context used of the window">${k(a.ctxUsed)} / ${k(a.ctxWindow)} <b style="color:${gauge(a.ctxPct)}">${a.ctxPct}%</b></span>`;
  patch(el, [`<span class="state ${st}"${st === "wanted" ? ` title="${esc(a.wanted)}"` : ""}><span class="dot"></span>${STATE[st] || esc(st)} ${ago(heldOf(a))}</span>`,
    a.model ? `<span title="Model and effort">${esc(a.model)}${a.effort ? " · " + esc(a.effort) : ""}</span>` : "",
    ctx, a.rate ? `<span title="Tokens a minute, lately">${k(a.rate)} tok/min</span>` : "",
    `<span title="Where it sits · the folder it works in">${esc(a.tab || "")} · ${esc(a.cwd || "")}</span>`].filter(Boolean).join(""));
}

// An open agent's terminal, beside its conversation, is shown or hidden from its header; the choice is remembered.
const termOn = () => localStorage.getItem("term") !== "off";
function showTerm() { $("#detail .box").classList.toggle("noterm", !termOn()); }
// The edge the other agents' column sits on, moved round clockwise from the header and remembered.
const EDGES = {right: "→", bottom: "↓", left: "←", top: "↑"};
const railEdge = () => EDGES[localStorage.getItem("rail")] ? localStorage.getItem("rail") : "right";
function showRail() {
  const box = $("#detail .box"), edge = railEdge();
  for (const e in EDGES) box.classList.toggle("rail-" + e, e === edge && e !== "right");
  const b = $("#dhead .railseg b");
  if (b) b.textContent = "Cards " + EDGES[edge];
}

async function openDetail(name) {
  if ($("#detail").classList.contains("docked")) localStorage.setItem("tab:page", name);
  open = name; pinned = true; $("#dbottom").classList.remove("on"); $("#dconv").innerHTML = ""; $("#dscreen").innerHTML = ""; $("#dterm").classList.remove("big"); $("#dzoom").textContent = "⤢";
  history.replaceState(null, "", "#" + encodeURIComponent(name));
  if (ONLY) document.title = shown(name);
  const a = S.agents.find(x => x.name === name) || {};
  $("#detail .box").style.setProperty("--c", a.colour || "#888");
  $("#dhead").innerHTML = `<span class="name" style="--c:${a.colour}">${esc(shown(name))}</span><span class="role">${esc(a.roleName || "")}</span>${a.ticket ? `<span class="ticket" style="margin-left:6px">${esc(a.ticket)}</span>` : ""}<span class="facts" id="dfacts"></span><span class="seg termseg"><b class="${termOn() ? "on" : ""}" title="Show or hide its terminal">Terminal</b></span><span class="seg railseg"><b title="Move the other agents' cards to the next edge"></b></span>${laneSeg(name)}<b class="fbtn" id="dmore" data-menu="agent:${esc(name)}" title="More">${MENU_ICON.more}</b><span class="x" title="Close (Esc)">✕</span>`;
  $("#dhead .x").onclick = closeDetail; laneClicks($("#dhead"));
  menuButton($("#dmore"), rested => agentMenu($("#dmore"), name, false, rested));
  $("#dhead .termseg b").onclick = e => { localStorage.setItem("term", termOn() ? "off" : "on"); e.target.classList.toggle("on", termOn()); showTerm(); };
  $("#dhead .railseg b").onclick = () => { const k = Object.keys(EDGES); localStorage.setItem("rail", k[(k.indexOf(railEdge()) + 1) % k.length]); showRail(); fitTerm(); };
  showTerm(); showRail();
  facts();
  $("#detail").classList.add("open");
  rail();
  const ds = $("#dsay"); ds.value = draft(name); grow(ds); shutBox(ds, {name, ...a});
  $("#datt").dataset.name = name; showAtt(name);
  $("#dsayrow").style.display = a.live ? "" : "none"; syncStop(); setTimeout(() => aim(ds), 50);
  await refreshDetail(true);
}
// The conversation stays pinned to its newest turn: from opening, until it is scrolled up, and again once it is
// scrolled back to the bottom.
let pinned = true;
// A click in the conversation, as on a card in a custom pane, puts the cursor in the message box; links, images and
// folded runs keep their own clicks, and a click that ends a selection leaves it be.
$("#dconv").addEventListener("click", e => {
  const ds = $("#dsay");
  if (!getSelection().isCollapsed || e.target.closest("a, button, img, .thumbs, [data-run]") || !ds.offsetParent) return;
  if (document.activeElement !== ds) aim(ds);
});
$("#dconv").addEventListener("scroll", () => { const c = $("#dconv"); pinned = c.scrollTop + c.clientHeight >= c.scrollHeight - 30; $("#dbottom").classList.toggle("on", !pinned); });
$("#dbottom").onclick = () => { const c = $("#dconv"); pinned = true; $("#dbottom").classList.remove("on"); c.scrollTo({top: c.scrollHeight, behavior: "smooth"}); };
let convFeed = [];
function renderConv() {
  const conv = $("#dconv");
  if (holding(conv)) return;
  patch(conv, convFeed.length ? feedHtml(convFeed, open, false) : `<div class="empty">no conversation yet</div>`);
  conv.querySelectorAll(".folded").forEach(f => f.onclick = () => { const k = f.dataset.run; openRuns.has(k) ? openRuns.delete(k) : openRuns.add(k); renderConv(); });
}
async function refreshDetail(first) {
  if (!open) return;
  const name = open;
  const d = await (await fetch("/api/agent/" + encodeURIComponent(name), {cache: "no-store"})).json();
  if (name !== open) return;   // another agent was opened meanwhile
  const conv = $("#dconv");
  if (first) pinned = true;
  convFeed = d.feed; renderConv();
  if (pinned && !holding(conv)) { conv.scrollTop = conv.scrollHeight; requestAnimationFrame(() => { conv.scrollTop = conv.scrollHeight; }); }
  if (!holding($("#dscreen"))) $("#dscreen").innerHTML = d.screen || `<span style="color:var(--faint)">not on screen</span>`;
  term = {cols: d.cols || 80, rows: d.rows || 24};
  $("#dtitle").textContent = `${open} — ${term.cols}×${term.rows}`;
  fitTerm(); beat();
}
// A message box wraps its words and grows with them, up to its cap, then scrolls. Enter sends; Ctrl+Enter starts a
// new line.
function grow(t) {
  if (!t.value) { t.style.height = ""; t.style.overflowY = "hidden"; return; }   // empty: one line, whatever the placeholder
  t.style.height = "auto";
  t.style.height = t.scrollHeight + 2 + "px";
  t.style.overflowY = t.scrollHeight > t.clientHeight + 2 ? "auto" : "hidden";
}
// A new line at the caret, kept in view in a box past its cap. The text before the caret, laid out in a hidden copy of
// the box, gives the caret's depth, wrapped lines included.
function newLine(t) {
  t.setRangeText("\n", t.selectionStart, t.selectionEnd, "end");
  grow(t);
  const copy = t.cloneNode();
  copy.value = t.value.slice(0, t.selectionStart);
  copy.style.cssText += `;position:absolute;visibility:hidden;width:${t.offsetWidth}px;height:0;min-height:0`;
  t.after(copy);
  const depth = copy.scrollHeight;
  copy.remove();
  const line = parseFloat(getComputedStyle(t).lineHeight);
  if (depth > t.scrollTop + t.clientHeight) t.scrollTop = depth - t.clientHeight;
  else if (depth - line < t.scrollTop) t.scrollTop = depth - line;
}
// A working agent's turn can be stopped, as Esc stops it in the terminal. From the click until the agent is no
// longer busy (or ten seconds pass) its Stop buttons show it is stopping and its working line reads "Stopping…".
const stopping = {};
const stopButton = name => `<button class="stop${stopping[name] ? " going" : ""}" data-name="${esc(name)}"${stopping[name] ? " disabled" : ""} title="Stop this turn, as Esc does in the terminal"></button>`;
function stopShown(name) { draw(); if (open === name) { syncStop(); renderConv(); } }
async function stopAgent(name, button) {
  button.disabled = true; button.classList.add("going"); stopping[name] = Date.now(); stopShown(name);
  const r = await fetch("/api/agent/" + encodeURIComponent(name) + "/stop", {method: "POST", headers: {"X-Team-Say": "1"}}).catch(() => null);
  if (!r || !r.ok) {
    delete stopping[name]; stopShown(name);
    button.title = r ? await r.text() : "the page could not be reached"; button.disabled = false; button.classList.remove("going"); return;
  }
  for (let i = 0; i < 25 && S.agents.find(a => a.name === name)?.status === "busy"; i++) { await new Promise(t => setTimeout(t, 400)); await load(); }
  delete stopping[name]; stopShown(name);
  if (open === name) refreshDetail(false);
}
$("#dstop").onclick = () => stopAgent(open, $("#dstop"));
function syncStop() {
  if (!open || !S) return;
  const a = S.agents.find(x => x.name === open) || {};
  $("#dstop").style.display = a.status === "busy" ? "" : "none"; $("#dstop").disabled = !!stopping[open]; $("#dstop").classList.toggle("going", !!stopping[open]);
  shutBox($("#dsay"), {name: open, ...a});
}
// Esc twice in quick succession in a box with text in it clears the box (and its draft); there, Esc never closes the view.
let escAt = 0;
function keys(e, box, name) {
  if (slashKey(e, box, name) || histKey(e, box, name)) return;
  if (e.key === "Tab" && !e.shiftKey && !box.value && settings().suggest !== "off") {   // the prompt Claude Code suggests, as Tab takes it there
    const hint = S.agents.find(a => a.name === name)?.suggest;
    if (hint) { e.preventDefault(); box.value = hint; grow(box); keep(box); }
    return;
  }
  if (e.ctrlKey && e.key.toLowerCase() === "u") { e.preventDefault(); pick(name, box); return; }
  if (e.key === "Escape" && box.value) {
    e.stopPropagation();
    if (Date.now() - escAt < 600) { box.value = ""; grow(box); keep(box); escAt = 0; } else escAt = Date.now();
    return;
  }
  if (e.key !== "Enter") return;
  e.preventDefault();
  if (e.ctrlKey) newLine(box);
  else {
    if (openAsk(S.agents.find(a => a.name === name))) { flash(box, "failed"); box.title = ASK_SHUT; } else say(name, box);
  }
}
// What the owner has sent to each agent from the page's message boxes, oldest first, the last hundred per agent, kept in
// this browser. In an agent's box, ↑ with the caret on the top line steps back through what was sent to that agent and
// ↓ on the bottom line forward again, to what was being written before the first ↑. Whether the caret was on that line
// is told by where the key left it: the browser moves it to the very start (or end) only from the top (or bottom) line.
// Once stepping, ↑ and ↓ go on stepping wherever the caret is, through a message of several lines too, until any other
// key, click or touch (hist.chain).
const sentBy = (() => { try { return JSON.parse(localStorage.getItem("sentBy")) || {}; } catch (e) { return {}; } })();
let hist = {box: null, at: 0, draft: "", shown: null, chain: false};
const plainArrow = e => (e.key === "ArrowUp" || e.key === "ArrowDown") && !e.altKey && !e.ctrlKey && !e.metaKey && !e.shiftKey;
document.addEventListener("keydown", e => { if (!plainArrow(e)) hist.chain = false; }, true);
document.addEventListener("pointerdown", () => { hist.chain = false; }, true);
function logSent(name, text) {
  const log = sentBy[name] = sentBy[name] || [];
  if (log[log.length - 1] !== text) log.push(text);
  log.splice(0, log.length - 100);
  localStorage.setItem("sentBy", JSON.stringify(sentBy));
  hist.box = null;
}
function histKey(e, box, name) {
  const sentLog = sentBy[name] || [];
  if (!plainArrow(e)) return false;
  const up = e.key === "ArrowUp", from = box.selectionStart, v = box.value;
  const chained = hist.chain && hist.box === box && hist.name === name && v === hist.shown;
  if (!chained && (box.selectionStart !== box.selectionEnd || (up ? v.slice(0, from).includes("\n") : v.slice(from).includes("\n")))) return false;
  const step = () => {
    if (hist.box !== box || hist.name !== name || box.value !== hist.shown) hist = {box, name, at: sentLog.length, draft: box.value, shown: null};
    const to = hist.at + (up ? -1 : 1);
    if (to < 0 || to > sentLog.length) return;
    hist.at = to;
    box.value = hist.shown = to === sentLog.length ? hist.draft : sentLog[to];
    box.selectionStart = box.selectionEnd = up ? 0 : box.value.length;   // so the next ↑ (or ↓) steps on at once
    hist.chain = true;
    grow(box); keep(box);
  };
  if (chained) { e.preventDefault(); step(); return true; }
  setTimeout(() => { if (box.selectionStart === box.selectionEnd && box.selectionStart === (up ? 0 : box.value.length) && box.value === v) step(); });
  return false;
}
// The list under a message box. Typing / and a name lists the commands that match (Claude Code's own, the user's and
// the team's commands and skills, the plugins'); in a meeting's box, typing @ lists the meeting's attendees. ↑/↓
// choose, Tab completes, Enter completes (and sends a command), Esc closes.
let slashCmds = null, slash = {box: null, at: 0, list: [], at_: null};
const slashEl = Object.assign(document.createElement("div"), {id: "slash"});
document.body.append(slashEl);
// The @name being typed in a meeting's box, up to the caret: {from, q, names}, or null.
function mentionAt(box) {
  if (!box.dataset.name?.startsWith(MEET) || box.selectionStart !== box.selectionEnd) return null;
  const m = /(^|\s)@(\w*)$/.exec(box.value.slice(0, box.selectionStart));
  const meet = m && meetOf(nodeAt(layout().root, box.dataset.name.slice(MEET.length)) || {});
  return meet && {from: box.selectionStart - m[2].length - 1, q: m[2].toLowerCase(), names: meet.who.map(meetAgent).sort(byName)};
}
async function slashShow(box) {
  const at = mentionAt(box);
  if (at) {
    const list = at.names.filter(a => a.name.toLowerCase().startsWith(at.q)).map(a => ({name: a.name, desc: a.roleName || ""}));
    if (!list.length) return slashOff();
    slash = {box, at: slash.box === box ? Math.min(slash.at, list.length - 1) : 0, list, at_: at};
    return slashDraw(box, "@");
  }
  const m = /^\/([\w:.-]*)$/.exec(box.value);
  if (!m) return slashOff();
  slashCmds = slashCmds || await fetch("/api/commands").then(r => r.json()).catch(() => []);
  const q = m[1].toLowerCase(), named = c => c.name.toLowerCase();
  const list = [...slashCmds.filter(c => named(c).startsWith(q)), ...slashCmds.filter(c => !named(c).startsWith(q) && named(c).includes(q))].slice(0, 8);
  if (!list.length || box.value !== "/" + m[1]) return slashOff();
  slash = {box, at: slash.box === box ? Math.min(slash.at, list.length - 1) : 0, list, at_: null};
  slashDraw(box, "/");
}
function slashDraw(box, mark) {
  slashEl.innerHTML = slash.list.map((c, i) => `<div class="sl${i === slash.at ? " at" : ""}" data-i="${i}"><b>${mark}${esc(c.name)}</b><span>${esc(c.desc)}</span></div>`).join("");
  const r = box.getBoundingClientRect();
  slashEl.style.cssText = `display:block;left:${r.left}px;width:${Math.max(r.width, 320)}px;bottom:${innerHeight - r.top + 4}px`;
  slashEl.querySelectorAll(".sl").forEach(el => el.onmousedown = e => { e.preventDefault(); slash.at = +el.dataset.i; slashDone(false); });
}
function slashOff() { slash = {box: null, at: 0, list: [], at_: null}; slashEl.style.display = "none"; }
function slashDone(send, name) {
  const box = slash.box, c = slash.list[slash.at], at = slash.at_;
  slashOff();
  if (at) {
    const head = box.value.slice(0, at.from) + "@" + c.name + " ";
    box.value = head + box.value.slice(box.selectionStart).replace(/^\w*\s?/, "");
    box.setSelectionRange(head.length, head.length); grow(box); keep(box); box.focus();
    return;
  }
  box.value = "/" + c.name + (send ? "" : " "); grow(box); keep(box); box.focus();
  if (send) say(name, box);
}
function slashKey(e, box, name) {
  if (slash.box !== box || !slash.list.length) return false;
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    e.preventDefault(); slash.at = (slash.at + (e.key === "ArrowDown" ? 1 : -1) + slash.list.length) % slash.list.length; slashShow(box);
  } else if (e.key === "Tab" || e.key === "Enter" && !e.ctrlKey) { e.preventDefault(); slashDone(e.key === "Enter", name); }
  else if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); slashOff(); }
  else return false;
  return true;
}
document.addEventListener("input", e => { if (e.target.matches?.("textarea.say")) slashShow(e.target); });
document.addEventListener("focusout", e => { if (e.target === slash.box) setTimeout(() => document.activeElement !== slash.box && slashOff(), 100); });
// Messages sent from the page, drawn in their agent's conversation the moment Enter is pressed, "sending" and then
// "sent", until the transcript has them (or a minute has passed): agent -> [{text, at, state}].
const echoes = {};
function echoItems(items, name) {
  const seen = m => items.some(it => ["owner", "pending"].includes(it.kind) && Date.parse(it.ts) >= m.at - 5000 && (it.text || "").includes(m.text.slice(0, 80)));
  const mine = echoes[name] = (echoes[name] || []).filter(m => Date.now() - m.at < 60000 && !seen(m));
  return mine.map(m => ({kind: "echo", text: m.text, state: m.state, ts: new Date(m.at).toISOString(), lane: "owner", who: "", with: ""}));
}
const echoKey = name => (echoes[name] || []).map(m => m.at + m.state).join() + (stopping[name] ? "|stopping" : "");
function echoed(name) { draw(); if (open === name) { renderConv(); const c = $("#dconv"); c.scrollTop = c.scrollHeight; } }
const saying = new Set();   // agents a message is on its way to: a second Enter meanwhile sends nothing
async function say(name, input) {
  if (name.startsWith(MEET)) return sayAll(name, input);
  const text = input.value.trim(), sent = atts[name] || [];
  if (!text && !sent.length || input.disabled || saying.has(name)) return;
  // The box empties before the echo redraws the page, so neither the redraw nor the kept draft can bring the text
  // back to be sent twice; a card's box may have been redrawn by the time the answer comes, so the answer goes to
  // whichever box is on the page then.
  input.value = ""; grow(input); keep(input); input.disabled = true; saying.add(name);
  const echo = text && {text, at: Date.now(), state: "sending"};
  if (echo) { (echoes[name] = echoes[name] || []).push(echo); echoed(name); }
  const box = () => input.isConnected ? input : document.querySelector(`#main .say[data-name="${CSS.escape(name)}"]`) || input;
  try {
    const r = await fetch("/api/agent/" + encodeURIComponent(name) + "/say", {method: "POST", headers: {"Content-Type": "application/json", "X-Team-Say": "1"}, body: JSON.stringify({text, images: sent.map(i => i.path)})});
    if (!r.ok) throw new Error(await r.text());
    if (echo) { echo.state = "sent"; echoed(name); }
    if (text) logSent(name, text);
    atts[name] = (atts[name] || []).filter(i => !sent.includes(i)); showAtt(name);
    flash(box(), "sent");
    chase(name, text);
  } catch (e) { if (echo) { echoes[name] = echoes[name].filter(m => m !== echo); echoed(name); } const b = box(); b.value = text; grow(b); keep(b); flash(b, "failed"); b.title = String(e.message || e); }
  saying.delete(name); input.disabled = false; aim(box());
}
// A message to the meeting: the server logs it and passes it to everyone in it; the box gets the text back if it fails.
async function sayAll(key, input) {
  const m = meetOf(nodeAt(layout().root, key.slice(MEET.length)) || {}), text = input.value.trim();
  if (!text || input.disabled || saying.has(key)) return;
  if (!m || m.ended || m.ending) { flash(input, "failed"); input.title = "The meeting is not open"; return; }
  input.value = ""; grow(input); keep(input); input.disabled = true; saying.add(key);
  const r = await fetch(`/api/meeting/${m.id}/say`, {method: "POST", headers: {"Content-Type": "application/json", "X-Team-Say": "1"},
    body: JSON.stringify({text})}).catch(() => null);
  const b = input.isConnected ? input : document.querySelector(`#main .say[data-name="${CSS.escape(key)}"]`) || input;
  if (r?.ok) logSent(key, text); else { b.value = text; grow(b); keep(b); }
  flash(b, r?.ok ? "sent" : "failed"); b.title = r?.ok ? "" : "Not said: the meeting did not take it";
  saying.delete(key); input.disabled = false;
  await loadMeetings(); draw(); aim(b);
}
// After a message is sent, that agent alone is asked for its conversation every half second until the message shows
// in it (as the owner's turn, or queued), for up to ten seconds; the page and its view then refresh at once rather
// than at the next poll.
async function chase(name, text) {
  const want = text.slice(0, 80);
  for (let i = 0; i < 20; i++) {
    await new Promise(r => setTimeout(r, 500));
    const d = await fetch("/api/agent/" + encodeURIComponent(name), {cache: "no-store"}).then(r => r.json()).catch(() => null);
    if (d && d.feed.some(it => ["owner", "pending"].includes(it.kind) && (it.text || "").includes(want))) break;
  }
  load(); if (open === name) refreshDetail(false);
}
// An image pasted into a message box is kept by the server as a file and waits above the box, removable, until the
// message goes (kept in this browser across reloads); it is sent as an attachment, as if dragged into the agent's terminal.
const atts = JSON.parse(localStorage.getItem("atts") || "{}");
// What is typed to an agent and not yet sent is kept in this browser, one draft per agent, so a reload or a restart
// of the server never loses it, and every box for that agent (its card in any view, its own view) shows the same text.
const drafts = () => JSON.parse(localStorage.getItem("drafts") || "{}");
const draft = name => drafts()[name] || "";
function keep(box) {
  const d = drafts(), name = box.id === "dsay" ? open : box.dataset.name;
  if (box.value) d[name] = box.value; else delete d[name];
  try { localStorage.setItem("drafts", JSON.stringify(d)); } catch (e) {}   // a paste too big to keep still sends
  for (const b of [...document.querySelectorAll("#main .say"), $("#dsay")]) {
    if (b !== box && (b.id === "dsay" ? open : b.dataset.name) === name && b.value !== box.value) { b.value = box.value; grow(b); }
  }
}
// Drafts kept per box, the card's and the view's, become the agent's one draft: the longer of the two.
{
  const d = drafts(); let moved = false;
  for (const k of Object.keys(d)) {
    const m = k.match(/^(card|view):(.+)$/);
    if (!m) continue;
    if (!d[m[2]] || d[k].length > d[m[2]].length) d[m[2]] = d[k];
    delete d[k]; moved = true;
  }
  if (moved) localStorage.setItem("drafts", JSON.stringify(d));
}
async function pasted(e, name) {
  const files = [...e.clipboardData.items].filter(i => i.kind === "file").map(i => i.getAsFile());
  if (!files.length) return;
  if (!e.clipboardData.getData("text/plain")) e.preventDefault();
  upload(files, name, e.target);
}
async function upload(files, name, box) {
  for (const f of files) {
    const r = await fetch("/api/paste", {method: "POST", headers: {"Content-Type": f.type || "application/octet-stream", "X-File-Name": encodeURIComponent(f.name || ""), "X-Team-Say": "1"}, body: f}).catch(() => null);
    if (!r || !r.ok) { flash(box, "failed"); box.title = r ? await r.text() : "the page could not be reached"; continue; }
    (atts[name] = atts[name] || []).push(await r.json()); showAtt(name);
  }
}
// The + beside a message box, or Ctrl+U in it, picks images or any other files from this computer to go with the message.
function pick(name, box) {
  const input = Object.assign(document.createElement("input"), {type: "file", multiple: true});
  input.onchange = () => { upload([...input.files], name, box); aim(box); };
  input.click();
}
// A file dragged from this computer onto a message row goes with the message, as one picked with its + does. Dropped
// anywhere else on the page it is ignored: the browser would otherwise leave the page to open it.
const hasFiles = e => e.dataTransfer?.types.includes("Files");
const dropBox = e => { const b = e.target.closest?.(".sayrow")?.querySelector("textarea.say"); return b && !b.disabled ? b : null; };
const dropMark = b => { document.querySelectorAll(".say.dropping").forEach(x => x.classList.remove("dropping")); b?.classList.add("dropping"); };
document.addEventListener("dragover", e => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  const b = dropBox(e);
  e.dataTransfer.dropEffect = b ? "copy" : "none";
  dropMark(b);
});
document.addEventListener("dragleave", e => { if (hasFiles(e) && !e.relatedTarget) dropMark(null); });
document.addEventListener("drop", e => {
  if (!hasFiles(e)) return;
  e.preventDefault();
  dropMark(null);
  const b = dropBox(e);
  if (b) { upload([...e.dataTransfer.files], b.dataset.name || open, b); aim(b); }
});
const addButton = name => `<button class="add" data-name="${esc(name)}" title="Add images or files (Ctrl+U)"></button>`;
function showAtt(name) {
  const list = atts[name] || [];
  localStorage.setItem("atts", JSON.stringify(atts));
  document.querySelectorAll(`.att[data-name="${CSS.escape(name || "")}"]`).forEach(el => {
    el.innerHTML = list.map((a, i) => a.image === false ? `<span class="file" title="${esc(a.path)}">${esc(a.name)}<b data-i="${i}" title="Remove">✕</b></span>` : `<span><a href="${a.url}" title="${esc(a.path)}" onclick="return showImg(event, this)"><img src="${a.url}" alt="pasted image"></a><b data-i="${i}" title="Remove">✕</b></span>`).join("");
    el.onclick = e => e.stopPropagation();
    el.querySelectorAll("b").forEach(x => x.onclick = () => { list.splice(+x.dataset.i, 1); showAtt(name); });
  });
}
function flash(el, cls) { el.classList.add(cls); setTimeout(() => el.classList.remove(cls), 1200); }
// Emoji shortcodes, as the desktop app has them: typing the closing colon of ":+1:" turns it into 👍.
const EMOJI = {"+1": "👍", thumbsup: "👍", "-1": "👎", thumbsdown: "👎", ok_hand: "👌", clap: "👏", pray: "🙏", wave: "👋",
  muscle: "💪", raised_hands: "🙌", point_up: "☝️", eyes: "👀", smile: "😄", smiley: "😃", grin: "😁", joy: "😂",
  laughing: "😆", wink: "😉", blush: "😊", slightly_smiling_face: "🙂", upside_down_face: "🙃", thinking: "🤔",
  neutral_face: "😐", confused: "😕", worried: "😟", cry: "😢", sob: "😭", scream: "😱", rage: "😡", sweat_smile: "😅",
  sunglasses: "😎", heart_eyes: "😍", facepalm: "🤦", shrug: "🤷", heart: "❤️", broken_heart: "💔", fire: "🔥",
  tada: "🎉", rocket: "🚀", star: "⭐", sparkles: "✨", "100": "💯", white_check_mark: "✅", heavy_check_mark: "✔️",
  x: "❌", warning: "⚠️", question: "❓", exclamation: "❗", bulb: "💡", bug: "🐛", wrench: "🔧", hammer: "🔨",
  lock: "🔒", key: "🔑", memo: "📝", pushpin: "📌", hourglass: "⌛", stopwatch: "⏱️", coffee: "☕", beer: "🍺",
  champagne: "🍾", pizza: "🍕", poop: "💩", skull: "💀", ghost: "👻", robot: "🤖", see_no_evil: "🙈", zap: "⚡",
  boom: "💥", construction: "🚧", rotating_light: "🚨", checkered_flag: "🏁", trophy: "🏆", gift: "🎁", money_bag: "💰",
  chart_with_upwards_trend: "📈", chart_with_downwards_trend: "📉", calendar: "📅", email: "📧", phone: "📱",
  computer: "💻", sunny: "☀️", rain_cloud: "🌧️", snowflake: "❄️", rainbow: "🌈", arrow_right: "➡️", arrow_left: "⬅️",
  arrow_up: "⬆️", arrow_down: "⬇️", recycle: "♻️", no_entry: "⛔", stop_sign: "🛑", green_circle: "🟢", red_circle: "🔴",
  yellow_circle: "🟡", hugs: "🤗", partying_face: "🥳", mind_blown: "🤯", exploding_head: "🤯", sleeping: "😴",
  zipper_mouth_face: "🤐", nerd_face: "🤓", cool: "🆒", new: "🆕", up: "🆙", sos: "🆘", crossed_fingers: "🤞",
  handshake: "🤝", point_right: "👉", point_left: "👈", heavy_plus_sign: "➕", heavy_minus_sign: "➖"};
function emojify(t) {
  const at = t.selectionStart, m = t.selectionEnd === at && t.value.slice(0, at).match(/:([a-z0-9_+-]+):$/);
  if (!m || !EMOJI[m[1]]) return;
  const e = EMOJI[m[1]], from = at - m[0].length;
  t.value = t.value.slice(0, from) + e + t.value.slice(at);
  t.selectionStart = t.selectionEnd = from + e.length;
}
// Typing ":" and a few letters of a shortcode offers the emoji that match, in a list over the box: ↑ ↓ to move, Enter or
// Tab (or a click) to put one in, Esc to leave the text as typed.
const emo = document.body.appendChild(Object.assign(document.createElement("div"), {id: "emo"}));
let emoFor = null, emoAt = 0;
function suggest(t) {
  const at = t.selectionStart, m = t.selectionEnd === at && t.value.slice(0, at).match(/(?:^|[\s(])(:([a-z0-9_+-]+))$/i);
  const q = m && m[2].toLowerCase(), names = Object.keys(EMOJI);
  const hits = q ? [...names.filter(n => n.startsWith(q)), ...names.filter(n => !n.startsWith(q) && n.includes(q))].slice(0, 8) : [];
  if (!hits.length) return emoHide();
  emoFor = t; emoAt = Math.min(emoAt, hits.length - 1);
  emo.innerHTML = hits.map((n, i) => `<div class="${i === emoAt ? "on" : ""}" data-n="${esc(n)}"><span>${EMOJI[n]}</span>:${esc(n)}:</div>`).join("");
  const r = t.getBoundingClientRect();
  Object.assign(emo.style, {left: r.left + "px", bottom: innerHeight - r.top + 4 + "px", display: "block"});
  emo.querySelectorAll("div").forEach(d => d.onmousedown = e => { e.preventDefault(); emoPut(d.dataset.n); });
}
function emoHide() { emoFor = null; emoAt = 0; emo.style.display = "none"; }
function emoPut(n) {
  const t = emoFor, at = t.selectionStart, from = t.value.slice(0, at).lastIndexOf(":");
  t.value = t.value.slice(0, from) + EMOJI[n] + t.value.slice(at);
  t.selectionStart = t.selectionEnd = from + EMOJI[n].length;
  emoHide(); t.dispatchEvent(new Event("input"));
}
// true when the key was the list's
function emoKey(e, t) {
  if (emoFor !== t || emo.style.display !== "block") return false;
  const rows = emo.querySelectorAll("div");
  if (e.key === "ArrowDown" || e.key === "ArrowUp") emoAt = (emoAt + (e.key === "ArrowDown" ? 1 : rows.length - 1)) % rows.length, suggest(t);
  else if ((e.key === "Enter" && !e.shiftKey) || e.key === "Tab") emoPut(rows[emoAt].dataset.n);
  else if (e.key === "Escape") emoHide();
  else return false;
  e.preventDefault(); e.stopPropagation(); return true;
}
addEventListener("focusout", e => { if (e.target === emoFor) emoHide(); });
$("#dsay").oninput = () => { emojify($("#dsay")); suggest($("#dsay")); grow($("#dsay")); keep($("#dsay")); };
$("#dsay").onkeydown = e => emoKey(e, $("#dsay")) || keys(e, $("#dsay"), open);
$("#dsay").onpaste = e => pasted(e, open);
$("#dadd").onclick = () => pick(open, $("#dsay"));

// The pane in its own terminal window, sized so all its columns and rows fit: within THUMB_W x THUMB_H as a
// thumbnail, or within the view when expanded (at most BIG px text).
const THUMB_W = 340, THUMB_H = 240, BIG = 16, PAD = 22;   // PAD: the screen's padding and the window's border
let term = {cols: 80, rows: 24}, charW = 0;
function fitTerm() {
  measureChar();
  const wrap = $("#dterm"), pre = $("#dscreen"), big = wrap.classList.contains("big");
  const w = big ? wrap.clientWidth - 80 - PAD : THUMB_W - PAD;
  const h = big ? wrap.clientHeight - 80 - PAD - $("#detail .bar").offsetHeight : THUMB_H;
  if (w <= 0 || h <= 0) return;
  const size = Math.max(1, Math.min(big ? BIG : 99, w / (term.cols * charW), h / (term.rows * 1.25)));
  pre.style.fontSize = size.toFixed(2) + "px";
  pre.style.width = (term.cols * charW * size).toFixed(1) + "px";
  pre.style.height = (term.rows * 1.25 * size).toFixed(1) + "px";
}
function measureChar() {
  if (charW) return;
  const p = document.createElement("span"); p.style.cssText = "font:100px var(--mono);position:absolute;visibility:hidden;white-space:pre";
  p.textContent = "M".repeat(50); document.body.append(p); charW = p.getBoundingClientRect().width / 5000; p.remove();
}
function zoom(on) { $("#dterm").classList.toggle("big", on); $("#dterm").title = on ? "" : "Expand"; $("#dzoom").textContent = on ? "⤡" : "⤢"; fitTerm(); }
$("#dterm").onclick = e => { if (!$("#dterm").classList.contains("big")) zoom(true); else if (["dzoom", "dterm", "dtx"].includes(e.target.id)) zoom(false); };
new ResizeObserver(fitTerm).observe($("#detail .box"));

// In the page's Tabs the open agent's view fills the page's body instead of floating over it: the column beside it
// picks the agent, remembered under "tab:page", and there is nothing behind it to close back to.
function dock(a) {
  const d = $("#detail"), was = d.classList.contains("docked");
  if (!a) { if (was) { d.classList.remove("docked"); d.style.inset = ""; closeDetail(); } return; }
  const r = $("#main").getBoundingClientRect();
  d.style.inset = `${r.top}px ${innerWidth - r.right}px ${innerHeight - r.bottom}px ${r.left}px`;
  d.classList.add("docked");
  if (open !== a.name) openDetail(a.name);
}
function closeDetail() { if (ONLY || $("#detail").classList.contains("docked")) return; open = null; $("#detail").classList.remove("open"); history.replaceState(null, "", location.pathname); }
$("#detail").onclick = e => { if (e.target.id === "detail") closeDetail(); };
addEventListener("keydown", e => {
  if (e.key !== "Escape") return;
  if ($("#lightbox").classList.contains("on")) closeImg();
  else if ($("#graphbox").classList.contains("on")) closeGraph();
  else if ($("#docbox").classList.contains("on")) closeDoc();
  else if ($("#dterm").classList.contains("big")) zoom(false);
  else if (paneBig && !open) { paneBig = null; draw(); }
  else if (open || !unmax()) closeDetail();
});
addEventListener("resize", () => { draw(); const c = $("#dconv"); if (open && pinned) c.scrollTop = c.scrollHeight; kbKeep(); });
// The conversations at their newest turn when a message box is tapped are put back there by each resize for the next
// two seconds, whatever scrolled them as the keyboard opened: on a phone the shrink itself can scroll one a little,
// which reads as scrolled up, and a redraw is skipped while the finger is still down (owner, 2026-11-02: "the box
// jumps up and newest appears").
let kbEnds = null;
addEventListener("focusin", e => { if (e.target.matches?.("textarea.say")) kbEnds = {at: Date.now(), panes: paneEnds(), conv: !!open && pinned}; }, true);
function kbKeep() {
  if (!kbEnds || Date.now() - kbEnds.at > 2000) return;
  document.querySelectorAll(FEEDS).forEach(f => { if (kbEnds.panes.has(f.parentElement.closest("[data-name]").dataset.name)) { f.scrollTop = f.scrollHeight; markEnd(f); } });
  if (kbEnds.conv && open) { const c = $("#dconv"); pinned = true; c.scrollTop = c.scrollHeight; $("#dbottom").classList.remove("on"); }
}
// Where the on-screen keyboard shrinks only the visible part of the page (iOS ignores interactive-widget), the page
// is sized and moved to that part, so the footer sits on the keyboard with no gap (owner, 2026-11-01: "halved the
// gap"). A pinch-zoom, which also shrinks it, leaves the page alone.
if (window.visualViewport) {
  const vv = visualViewport, fit = () => {
    const kb = vv.scale < 1.01 && innerHeight - vv.height > 1;
    document.documentElement.style.height = kb ? vv.height + "px" : "";
    document.body.style.transform = kb && vv.offsetTop ? `translateY(${vv.offsetTop}px)` : "";
    // The browser can scroll the page itself to show the box, though the page does not scroll: that lifts the footer.
    const se = document.scrollingElement;
    if (se.scrollTop) se.scrollTop = 0;
    kbKeep();
  };
  vv.addEventListener("resize", fit); vv.addEventListener("scroll", fit);
}

// The bars as this browser keeps them from the first paint, not after /api/state: the plug-ins join them when it answers.
try { placeBar(); } catch (e) { console.error("agents-web first bar placement failed", e); }
document.documentElement.classList.add("barsplaced");
load().then(() => { if (location.hash.length > 1) openDetail(decodeURIComponent(location.hash.slice(1))); });
// Ctrl- or Cmd-click, or a middle click, on an agent - its card, its row in a list, its name or a turn of its in a
// Team or Combined pane - opens its view in a new tab instead, as its menu's "Open in new tab" does. That tab (?only)
// is the agent alone: its view fills the window, with no page behind it, no other agents beside it and no way to close it.
const AGENT_AT = "#main .card[data-name], .mini[data-name], .chr[data-name], .teamlog .thead .name, .teamlog .it[data-agent]";
function agentAt(e) {
  const el = e.target.closest?.(AGENT_AT);
  const name = el && (el.dataset.name || el.dataset.agent || el.textContent);
  return S && S.agents.some(a => a.name === name) && !e.target.closest("a, textarea, button, .seg, .fbtn") ? name : null;
}
const inNewTab = name => window.open("/?only#" + encodeURIComponent(name), "_blank", "noopener");
const inWindow = name => window.open("/?only#" + encodeURIComponent(name), "_blank", "noopener,popup,width=960,height=1000");
// The page's menu, one at a time, kept at its anchor (data-menu names it, so a click on the anchor of the open menu
// closes it): a Characters tile's beside the tile, after a moment's rest or at once on a right-click, going when the
// pointer has left both; a filter button's under the button on a click, going on a click elsewhere. Esc closes either.
const menu = $("#menu");
let menuShow = 0, menuHide = 0, menuGo = () => {};   // menuGo(name, anchor): Open, the layout's way to show an agent (its box, else its view)
// menuAt draws a menu at its anchor; with stay, an open one is drawn again where it is, keeping the item the keyboard
// is on, as the page's refresh does to keep a menu up to date (menu.refresh, which a menu that changes sets).
function menuAt(anchor, key, html, beside, stay) {
  if (stay) {
    // a portrait being looked at full size is not redrawn under the mouse, which would close and reopen it
    if (menu.querySelector(".mpor:hover")) return;
    const at = [...menu.querySelectorAll(".mi")].findIndex(m => m.classList.contains("at"));
    menu.innerHTML = html; menu.querySelectorAll(".mi")[at]?.classList.add("at");
    return;
  }
  clearTimeout(menuHide);   // a menu opening is not closed by the one it replaces, left a moment ago
  menu.innerHTML = html; menu.dataset.key = key; delete menu.dataset.rested; menu.refresh = null; menu.classList.add("on");
  if (!anchor?.offsetParent) anchor = $(".brand");   // a button out of the bars, reached by its shortcut: from the logo
  const r = anchor.getBoundingClientRect(), w = menu.offsetWidth, h = menu.offsetHeight;
  // a menu beside its tile or icon would cover the next one along a row, either side, so there it opens below (or above)
  // instead; an icon in Tabs stands in its own .ftab, whose siblings are the ones along the row
  const inRow = el => { const o = el?.getBoundingClientRect(); return !!o && o.width > 0 && o.top < r.bottom && o.bottom > r.top; };
  const along = anchor.closest(".ftab") || anchor;
  const row = beside && (inRow(along.nextElementSibling) || inRow(along.previousElementSibling));
  if (row) beside = false;
  const left = beside ? (r.right + 6 + w <= innerWidth ? r.right + 6 : r.left - 6 - w) : row ? Math.min(r.left, innerWidth - w - 6) : Math.min(r.right - w, innerWidth - w - 6);
  const top = beside ? r.top : r.bottom + 4 + h <= innerHeight ? r.bottom + 4 : r.top - 4 - h;
  menu.style.left = Math.max(6, left) + "px"; menu.style.top = Math.max(6, Math.min(top, innerHeight - h - 6)) + "px";
}
// A menu that grows once open (a view renamed, a delete asked, an item added) is moved back inside the window: its
// right and bottom edges are kept off the window's, and its left and top on it.
new ResizeObserver(() => {
  if (!menu.classList.contains("on")) return;
  const r = menu.getBoundingClientRect();
  if (r.right > innerWidth - 6) menu.style.left = Math.max(6, innerWidth - 6 - r.width) + "px";
  if (r.bottom > innerHeight - 6) menu.style.top = Math.max(6, innerHeight - 6 - r.height) + "px";
}).observe(menu);
// A menu's portrait shown at full size grows from the corner that keeps it inside the window: up from its bottom
// edge when there is no room below it, rightwards from its left edge when there is none to its left.
menu.addEventListener("mouseover", e => {
  const img = e.target.closest?.(".mpor img");
  if (!img || phoneOn()) return;
  const r = img.parentElement.getBoundingClientRect(), big = r.width * 2.67;
  img.style.transformOrigin = `${r.right - big < 6 ? "left" : "right"} ${r.top + big > innerHeight - 6 ? "bottom" : "top"}`;
});
// On the phone a tap on it shows it large over the sheet, and a tap anywhere puts it away.
menu.addEventListener("click", e => {
  const img = phoneOn() && e.target.closest?.(".mpor img");
  if (!img) return;
  e.stopPropagation();
  const o = document.createElement("div"); o.id = "phpor"; o.innerHTML = `<img src="${esc(img.getAttribute("src"))}" alt="">`;
  o.onclick = ev => { ev.stopPropagation(); o.remove(); };
  $("#phpor")?.remove(); document.body.append(o);
}, true);
const menuOn = key => menu.classList.contains("on") && menu.dataset.key === key;
function menuOff(now) {
  clearTimeout(menuShow); clearTimeout(menuHide);
  menuHide = setTimeout(() => { menu.classList.remove("on"); delete menu.dataset.key; delete menu.dataset.rested; menu.refresh = null; }, now ? 0 : 200);
}
menu.onmouseenter = () => clearTimeout(menuHide);
menu.onmouseleave = () => { if (menu.dataset.rested) menuOff(); };
// Esc with a menu open closes the menu and nothing else.
addEventListener("keydown", e => { if (e.key === "Escape" && menu.classList.contains("on") && !e.target.closest?.("#menu input")) { e.stopPropagation(); menuOff(true); } }, true);
// An open menu's items by keyboard, unless it opened from a moment's rest: arrows move, Enter or Space picks or ticks.
addEventListener("keydown", e => {
  if (!menu.classList.contains("on") || menu.dataset.rested || !["ArrowDown", "ArrowUp", "Enter", " "].includes(e.key) || e.target.closest?.("#menu input")) return;
  const items = [...menu.querySelectorAll(".mi")], at = items.findIndex(m => m.classList.contains("at"));
  if (!items.length) return;
  e.preventDefault(); e.stopPropagation();
  if (e.key === "Enter" || e.key === " ") { items[at]?.click(); return; }
  const down = e.key === "ArrowDown", next = at < 0 ? (down ? 0 : items.length - 1) : (at + (down ? 1 : items.length - 1)) % items.length;
  items.forEach((m, i) => m.classList.toggle("at", i === next));
}, true);

// Keyboard shortcuts, listed by the ? at the top right (or ? and Alt+/). Those with Alt work while typing in a box;
// "this agent" is the one whose box is being typed in, else the one open, else the one under the pointer.
const SHORTCUTS = [
  ["Agents", [["Alt+1 … 9", "That agent's message box, in list order"], ["Alt+↑ / ↓", "The agent before or after this one"],
    ["Alt+W", "The agent waiting longest"], ["Alt+Enter", "Open this agent's view, or close it"]]],
  ["Views", [["Ctrl+Alt+1 … 9", ""]]],
  ["Page", [["Alt+V", "Choose the view"], ["Alt+L", "This agent's filter, else the page's"], ["Alt+M", "Maximise this pane, or restore it"]]],
  ["Message box", [["Enter", "Send"], ["Ctrl+Enter", "New line"], ["Esc Esc", "Clear the box"], ["Ctrl+U", "Add images or files"]]],
  ["Anywhere", [["Esc", "Close what is open"], ["Ctrl+Click", "Open an agent in a new tab"], ["? or Alt+/", "These shortcuts"]]],
  ["Menus", [["↑ / ↓", "Move"], ["Enter / Space", "Pick, or tick"], ["Esc", "Close"]]],
  ["Prompts", [["↑ / ↓", "Move to an option"], ["Enter", "Choose it"], ["1 … 9", "Choose that option"]]],
];
function helpMenu(rested) {
  if (menuOn("help")) { if (!rested) menuOff(true); return; }
  const set = settings(), jump = Object.entries(jumpKeys()).sort().map(([d, n]) => [`${MODS[set.mod]}+${d}`, n]);
  const vlist = views().views, vjump = Object.entries(viewKeys()).sort().map(([d, i]) => [`${viewMod()}+${d}`, vlist[i].name]);
  const rows = SHORTCUTS.map(([h, rows]) => [h, rows.flatMap(([k, what]) => k === "Alt+1 … 9" ? jump : k === "Ctrl+Alt+1 … 9" ? vjump : [[k, what]])]);
  menuAt($("#help"), "help", rows.map(([h, rows]) => `<div class="hd"><div>${h}</div></div>` +
    rows.map(([k, what]) => `<div class="sc"><span>${esc(what)}</span><kbd>${esc(k)}</kbd></div>`).join("")).join(""), false);
  if (rested) menu.dataset.rested = "1";
}
menuButton($("#help"), helpMenu);
// The page's settings, kept in this browser: the size of its text (every size scales together), the size of the
// conversations' text and of the message boxes' on top of that, whether the header shows the five-hour session's use,
// whether an idle agent's box offers the prompt Claude Code suggests, and the jump keys: a modifier with 1 … 9 goes to an agent, the Nth in list order
// until any key is given an agent, then only the keys given one; a jump goes to the agent's message box (its card's,
// its tab's or a Combined pane's chat, else its view) or always to its view. The defaults are the page as it is
// without them.
const SETTINGS = {fs: 100, conv: 100, box: 100, suggest: "on", mod: "alt", keys: {}, jump: "box", viewKeys: {}};
// The modifiers a jump key can be held with: Cmd only on a Mac (elsewhere it is the system's own key), and Shift only
// outside a text box, where Shift with a digit types its symbol. A saved choice this machine lacks falls back to Alt.
const MAC = /mac/i.test(navigator.userAgentData?.platform || navigator.platform || "");
const MODS = MAC ? {alt: "Option", meta: "Cmd", ctrl: "Ctrl", shift: "Shift"} : {alt: "Alt", ctrl: "Ctrl", shift: "Shift"};
function settings() {
  let set;
  try { set = {...SETTINGS, ...JSON.parse(localStorage.getItem("settings") || "{}")}; } catch (e) { set = {...SETTINGS}; }
  if (!MODS[set.mod]) set.mod = "alt";
  return set;
}
function applySettings() {
  const set = settings(), root = document.documentElement.style;
  set.fs === 100 ? root.removeProperty("--fs") : root.setProperty("--fs", set.fs / 100);
  set.conv === 100 ? root.removeProperty("--conv") : root.setProperty("--conv", set.conv / 100);
  set.box === 100 ? root.removeProperty("--boxfs") : root.setProperty("--boxfs", set.box / 100);
}
applySettings();
function settingsMenu(redraw) {
  if (!redraw && menuOn("settings")) { menuOff(true); return; }
  const set = settings(), keyed = jumpKeys(), names = [...S.agents, ...S.bench].map(a => a.name);
  const pick = (attr, now, opts) => `<select ${attr}>${opts.map(([v, l]) => `<option value="${esc(v)}"${String(v) === String(now) ? " selected" : ""}>${esc(l)}</option>`).join("")}</select>`;
  const sizes = [80, 90, 100, 110, 120, 130, 140, 150].map(v => [v, v + "%"]);
  const digits = [["", "none"], ...[1, 2, 3, 4, 5, 6, 7, 8, 9].map(d => [d, `${MODS[set.mod]}+${d}`])];
  const keys = names.map(n => `<label class="set"><span>${esc(n)}</span>` +
    pick(`data-agent="${esc(n)}"`, Object.keys(keyed).find(d => keyed[d] === n) || "", digits) + `</label>`).join("");
  const vkeyed = viewKeys(), vdigits = [["", "none"], ...[1, 2, 3, 4, 5, 6, 7, 8, 9].map(d => [d, `${viewMod()}+${d}`])];
  const vkeys = views().views.map((x, i) => `<label class="set"><span>${esc(x.name)}</span>` +
    pick(`data-view="${esc(x.name)}"`, Object.keys(vkeyed).find(d => vkeyed[d] === i) || "", vdigits) + `</label>`).join("");
  menuAt($("#settings"), "settings", `<div class="hd"><div>Settings, kept in this browser</div></div>` +
    `<label class="set"><span>Text size</span>${pick('data-set="fs"', set.fs, sizes)}</label>` +
    `<label class="set"><span>Conversation text</span>${pick('data-set="conv"', set.conv, sizes)}</label>` +
    `<label class="set"><span>Message box text</span>${pick('data-set="box"', set.box, sizes)}</label>` +
    `<label class="set"><span>Theme</span>${pick("data-theme", themeNow(), [["dark", "Dark"], ["light", "Light"], ["custom", "Custom"]])}</label>` +
    (themeNow() === "custom" ? `<button data-edit-theme>Edit the custom theme…</button>` : "") +
    `<label class="set"><span>Suggested prompts</span>${pick('data-set="suggest"', set.suggest, [["on", "shown"], ["off", "hidden"]])}</label>` +
    `<div class="hd"><div>Jump to an agent</div></div>` +
    `<label class="set"><span>Hold</span>${pick('data-set="mod"', set.mod, Object.entries(MODS))}</label>` +
    `<label class="set"><span>Goes to</span>${pick('data-set="jump"', set.jump, [["box", "its message box"], ["view", "its full view"]])}</label>${keys}` +
    `<div class="hd"><div>Switch view</div></div>${vkeys}` +
    `<button data-reset>Reset to defaults</button>`, false, redraw);
  menu.querySelectorAll("select").forEach(sel => sel.onchange = () => {
    if (sel.hasAttribute("data-theme")) { retheme(sel.value); settingsMenu(true); return; }
    const now = settings();
    if (sel.dataset.agent) {   // the keys as they stand, list order included, with this agent moved to its new key
      const keys = Object.fromEntries(Object.entries(jumpKeys()).filter(([d, n]) => n !== sel.dataset.agent && d !== sel.value));
      if (sel.value) keys[sel.value] = sel.dataset.agent;
      now.keys = keys;
    } else if (sel.dataset.view) {   // the view keys as they stand, menu order included, with this view moved to its new key
      const v = views().views, keys = Object.fromEntries(Object.entries(viewKeys()).map(([d, i]) => [d, v[i].name]).filter(([d, n]) => n !== sel.dataset.view && d !== sel.value));
      if (sel.value) keys[sel.value] = sel.dataset.view;
      now.viewKeys = keys;
    } else now[sel.dataset.set] = ["mod", "jump", "session", "suggest"].includes(sel.dataset.set) ? sel.value : +sel.value;
    localStorage.setItem("settings", JSON.stringify(now)); applySettings(); settingsMenu(true); draw();
  });
  menu.querySelector("[data-reset]").onclick = () => { localStorage.removeItem("settings"); applySettings(); settingsMenu(true); };
  const edit = menu.querySelector("[data-edit-theme]");
  if (edit) edit.onclick = () => themeMenu();
}
// The theme editor, from Settings: where to start from (a preset), the base, then a colour for each of the page's
// colours, each gauge, each role and each agent (an agent's own colour over its role's). Each change is saved and
// shown at once; a gauge's, role's or agent's ✕ gives it back its own colour.
const GAUGE_NAMES = [["cpu", "CPU"], ["mem", "Memory"], ["disk", "Disk"], ["net", "Network"], ["gpu", "GPU"], ["heat", "Heat"]];
function themeMenu(redraw) {
  const c = customTheme(), people = [...S.agents, ...S.bench];
  const roles = [...new Map(people.map(a => [a.role, a])).values()];   // each role once, by its first agent
  const row = (attr, label, value, own) => `<label class="set"><span>${esc(label)}</span><input type="color" ${attr} value="${esc(value)}">` +
    `<b class="unset${own ? "" : " off"}" ${attr} title="Back to its own colour">✕</b></label>`;
  menuAt($("#settings"), "theme", `<div class="hd"><div>Custom theme, kept in this browser</div></div>` +
    `<div class="set"><span>Start from</span><span class="presets">` +
      [["dark", "Dark"], ["light", "Light"], ["warm", "Warm light"]].map(([k, l]) => `<button data-preset="${k}">${l}</button>`).join("") + `</span></div>` +
    `<label class="set"><span>Based on</span><select data-base>` +
      [["light", "Light"], ["dark", "Dark"]].map(([v, l]) => `<option value="${v}"${c.base === v ? " selected" : ""}>${l}</option>`).join("") + `</select></label>` +
    `<div class="hd sub"><div>Page</div></div>` + PAGE_COLOURS.map(([k, l]) => row(`data-page="${k}"`, l, c.page[k], false)).join("") +
    `<div class="hd sub"><div>Gauges</div></div>` + GAUGE_NAMES.map(([k, l]) => row(`data-perf="${k}"`, l, c.perf[k] || PERF_COLOUR[k], !!c.perf[k])).join("") +
    `<div class="hd sub"><div>Roles</div></div>` + roles.map(a => row(`data-role="${esc(a.role)}"`, a.roleName, c.roles[a.role] || a.roleColour, !!c.roles[a.role])).join("") +
    `<div class="hd sub"><div>Agents</div></div>` +
      people.map(a => row(`data-agent="${esc(a.name)}"`, shown(a.name), c.agents[a.name] || c.roles[a.role] || a.roleColour, !!c.agents[a.name])).join("") +
    `<button data-back>Back to Settings</button>`, false, redraw);
  const save = (t, again) => { localStorage.setItem("customTheme", JSON.stringify(t)); retheme("custom"); if (again) themeMenu(true); };
  const put = (t, d, v) => {
    if (d.page) { t.page[d.page] = v; return; }
    const [set, k] = d.perf ? [t.perf, d.perf] : d.role ? [t.roles, d.role] : [t.agents, d.agent];
    v ? set[k] = v : delete set[k];
  };
  menu.querySelectorAll("input[type=color]").forEach(inp => {
    // the page's colours follow the picker as it moves; a gauge or an agent, which needs the page drawn again, once chosen
    inp[inp.dataset.page ? "oninput" : "onchange"] = () => { const t = customTheme(); put(t, inp.dataset, inp.value); save(t, !inp.dataset.page); };
  });
  menu.querySelectorAll(".unset").forEach(x => x.onclick = e => { e.preventDefault(); const t = customTheme(); put(t, x.dataset, ""); save(t, true); });
  menu.querySelectorAll("[data-preset]").forEach(b => b.onclick = () => { const t = customTheme(), p = THEME_PRESETS[b.dataset.preset]; save({...t, base: p.base, page: {...p.page}}, true); });
  menu.querySelector("[data-base]").onchange = e => save({...customTheme(), base: e.target.value}, true);
  menu.querySelector("[data-back]").onclick = () => settingsMenu();
}
$("#settings").onclick = e => { e.stopPropagation(); if (S) settingsMenu(); };
// Key -> agent: the keys given an agent, or while none is, the first nine running agents in list order.
function jumpKeys() {
  const keys = Object.fromEntries(Object.entries(settings().keys).filter(([, n]) => n));
  return Object.keys(keys).length ? keys : Object.fromEntries(S.agents.slice(0, 9).map((a, i) => [i + 1, a.name]));
}
const jumpTo = d => { const n = jumpKeys()[d]; return S.agents.some(a => a.name === n) ? n : null; };
const jumpMod = (e, mod, typing) => {
  const held = {alt: e.altKey, meta: e.metaKey, ctrl: e.ctrlKey, shift: e.shiftKey};
  return held[mod] && Object.entries(held).every(([k, on]) => k === mod || !on) && !(mod === "shift" && typing);
};
const here = () => {
  const a = document.activeElement;
  if (a?.id === "dsay") return open;
  if (a?.matches?.("#main .say")) return a.dataset.name;
  return open || document.querySelector("#main .card[data-name]:hover, .mini[data-name]:hover, .chr[data-name]:hover")?.dataset.name || null;
};
// An agent's message box: its card's, where one shows; else its tab is brought forward; else its view opens.
const shownBox = name => [...document.querySelectorAll(`#main .say[data-name="${CSS.escape(name)}"]`)].find(b => b.offsetParent);
function focusAgent(name) {
  if (!name) return;
  if (settings().jump === "view") return name === open ? aim($("#dsay")) : openDetail(name);
  if (open) return name === open ? aim($("#dsay")) : openDetail(name);
  if (!shownBox(name) && (localStorage.getItem("page") || "grid") === "custom") {   // a Combined pane's chat with it
    const pane = leaves(layout().root).find(([, n]) => n.show === "combined" && paneAgents(n).some(a => a.name === name && a.live));
    if (pane) return chatWith(pane[0], name);
  }
  const box = () => shownBox(name);
  if (!box()) {
    const pane = (localStorage.getItem("page") || "grid") === "custom" && leaves(layout().root).find(([, n]) => n.show === "tabs" && paneAgents(n).some(a => a.name === name));
    if (pane) { localStorage.setItem("tab:pane:" + pane[0], name); draw(); }
    else $(`#main .tabbar button[data-tab="${CSS.escape(name)}"]`)?.click();
  }
  box() ? aim(box()) : openDetail(name);
}
addEventListener("keydown", e => {
  const typing = e.target.closest?.("textarea, input, select");
  if (!e.altKey && !e.ctrlKey && !e.metaKey && e.key === "?" && !typing) { e.preventDefault(); helpMenu(false); return; }
  const digit = /^Digit([1-9])$/.exec(e.code);
  if (digit && e.ctrlKey && e.altKey && !e.metaKey && !e.shiftKey) {   // a view key
    const i = viewKeys()[digit[1]];
    if (i == null) return;
    e.preventDefault(); e.stopPropagation(); menuOff(true);
    if (i !== views().at) changeViews(v => { v.at = i; });
    return;
  }
  if (digit && S && jumpMod(e, settings().mod, typing)) { e.preventDefault(); e.stopPropagation(); focusAgent(jumpTo(digit[1])); return; }
  if (!e.altKey || e.ctrlKey || e.metaKey || !S) return;
  const names = S.agents.map(a => a.name), cur = here(), at = names.indexOf(cur);
  const step = d => names[at < 0 ? (d > 0 ? 0 : names.length - 1) : (at + d + names.length) % names.length];
  const act = e.code === "ArrowDown" || e.code === "ArrowUp" ? () => focusAgent(step(e.code === "ArrowDown" ? 1 : -1))
    : e.code === "KeyW" ? () => focusAgent(needing()[0]?.name)
    : e.code === "Enter" ? () => { if (!open) return openDetail(cur || names[0]); closeDetail(); if (!open) aim(shownBox(cur)); }
    : e.code === "KeyV" ? () => viewMenu([$("#pagemode .viewbtn"), $("#viewbar .vtmenu"), $("#viewbar")].find(b => b?.offsetParent) || $(".brand"), false)
    : e.code === "KeyL" ? () => ((cur && open === cur && $("#dhead .lanes")) || (cur && $(`#main .card[data-name="${CSS.escape(cur)}"] .lanes`)) || $("#pagelanes .fbtn")).click()
    : e.code === "KeyM" ? () => maxToggle()
    : e.code === "Slash" ? () => helpMenu(false) : null;
  if (!act) return;
  e.preventDefault(); e.stopPropagation(); act();
}, true);
addEventListener("mousedown", e => {
  if (typeof phHeld === "number" && Date.now() - phHeld < 800) return;   // a phone's held finger lifting under its new sheet
  if (e.target.closest?.("#phpor")) return;   // the menu's portrait shown large: putting it away leaves the menu open
  if (menu.classList.contains("on") && !menu.contains(e.target) && e.target.closest?.("[data-menu]")?.dataset.menu !== menu.dataset.key) menuOff(true);
}, true);
// An agent's menu (a Characters tile's, a List row's, the view header's ⋯): who it is and what it is doing, then Open
// (as a click on it), Open in a new tab and Open in a new window, and for a standing agent Start, or Stop, which asks
// again first; a stopped one is on the bench, and its menu there has its Start.
// its last compaction, for the menu's header: how long ago, manual or auto, the context before and after, how long it took
function lastCompact(a) {
  const c = a.lastCompact, at = c && Date.parse(c.ts);
  if (!at) return "";
  const took = c.ms == null ? "" : c.ms < 60000 ? ` in ${Math.round(c.ms / 1000)}s` : ` in ${Math.floor(c.ms / 60000)}m ${Math.round(c.ms % 60000 / 1000)}s`;
  const size = c.pre == null ? "" : ` · ${k(c.pre)}${c.post == null ? "" : "&nbsp;→ " + k(c.post)}`;
  return `<div title="${esc(new Date(at).toLocaleString())}">Compacted ${ago(Math.max(0, Math.round(S.now - at / 1000)))} ago${c.trigger === "auto" ? ", auto" : ""}${took}${size}</div>`;
}
const STANDING_ROLES = new Set(["lead", "hot", "ops", "support", "review", "process", "pa"]);
const post = path => fetch(path, {method: "POST", headers: {"X-Team-Say": "1"}}).then(r => { if (!r.ok) r.text().then(t => alert(t.trim())); load(); });
function agentMenu(anchor, name, beside, rested, confirm, stay) {
  if (anchor.closest?.(".meetrow")) return meetMenu(anchor, name, beside, rested);
  const bench = S.bench.find(x => x.name === name), a = S.agents.find(x => x.name === name) || bench, key = "agent:" + name;
  if (!a || !stay && !anchor.isConnected) return;
  if (menuOn(key) && !confirm && !stay) { if (rested) return; if (menu.dataset.rested) delete menu.dataset.rested; else menuOff(true); return; }
  const st = bench ? "bench" : stOf(a), ctx = a.ctxPct == null ? "" : ` · ${a.ctxPct}% context`;
  const pulse = icon => icon.replace("<svg", '<svg class="switching"');   // pulses until it is done
  // its model, effort and burn, over its usage graph drawn to the team's scale, as on its card
  const model = a.model ? `<div>${esc(a.model)}${a.effort ? " · " + esc(a.effort) : ""}${a.rate ? " · " + k(a.rate) + " tok/min" : ""}</div>` : "";
  const usage = bench ? "" : spark(a.series, Math.max(1, ...S.agents.flatMap(x => x.series)), a.colour);
  const compact = S.compacting.includes(name) ? `<div class="mi off">${pulse(MENU_ICON.compact)}Compacting…</div>`
    : `<div class="mi" data-go="compact">${MENU_ICON.compact}Compact now</div>`;
  let power = "";
  if (STANDING_ROLES.has(a.role)) {
    power = S.starting.includes(name) ? `<div class="mi off">${pulse(MENU_ICON.start)}Starting…</div>`
      : S.halting.includes(name) ? `<div class="mi off">${pulse(MENU_ICON.stop)}Stopping…</div>`
      : !a.live ? `<div class="mi" data-go="start">${MENU_ICON.start}Start ${esc(shown(name))}</div>`
      : confirm ? `<div class="ask">Ask ${esc(name)} to finish, update its record and stop? Its pane closes once it is idle.</div>` +
        `<div class="mi warn" data-go="halt">${MENU_ICON.power}Stop ${esc(shown(name))}</div><div class="mi" data-go="cancel">${MENU_ICON.close}Cancel</div>`
      : `<div class="mi" data-go="ask">${MENU_ICON.power}Stop ${esc(shown(name))}…</div>`;
  }
  const chatIn = a.live && anchor.closest?.(".teamlog.combined") && anchor.closest(".pane")?.dataset.path;   // a Combined pane's chat
  // its name and details, with its second portrait, else its portrait, on the right
  menuAt(anchor, key, `<div class="hd"><div class="hrow"><div class="htxt"><span class="name" style="--c:${a.colour}">${esc(a.fullName || a.name)}</span><div>${esc(a.roleName || "")}${a.ticket ? " · " + esc(a.ticket) : ""}</div>` +
    `<div>${STATE[st] || esc(st)}${a.held == null ? "" : " · " + ago(a.held)}${ctx}</div>${model}</div>` +
    `${a.altPortrait || a.portrait ? `<span class="mpor"><img src="${esc(a.altPortrait || a.portrait)}" alt=""></span>` : ""}</div>${usage}${lastCompact(a)}</div>` +
    (bench ? (bench.standing ? power : "") : !a.live ? power :   // a benched developer or tester has only its details, a benched standing agent its Start; one that is not running has nothing to open
      (name === open ? "" : `<div class="mi" data-go="open">${MENU_ICON.open}Open<kbd>Click</kbd></div>`) +   // not the agent already in the view
      `<div class="mi" data-go="tab">${MENU_ICON.tab}Open in new tab<kbd>Ctrl+Click</kbd></div>` +
      `<div class="mi" data-go="window">${MENU_ICON.window}Open in new window</div>` +
      (chatIn ? `<div class="mi" data-go="chat">${MENU_ICON.said}Chat</div>` : "") + `<div class="sep"></div>${compact}${power}`) +
    `<div class="sep"></div><div class="mi" data-go="fav">${MENU_ICON.star}${phFav(name) ? "Remove from favourites" : "Add to favourites"}</div>`, beside, stay);
  if (rested && !stay) menu.dataset.rested = "1";
  menu.refresh = () => agentMenu(anchor, name, beside, false, confirm, true);
  menu.querySelectorAll(".mi[data-go]").forEach(mi => mi.onclick = () => {
    const go = mi.dataset.go;
    if (go === "ask") return agentMenu(anchor, name, beside, false, true);
    menuOff(true);
    if (go === "chat") chatWith(chatIn, name);
    else if (go === "fav") phFavToggle(name);
    else if (go === "start") post(`/api/agent/${encodeURIComponent(name)}/start`);
    else if (go === "halt" || go === "compact") post(`/api/agent/${encodeURIComponent(name)}/${go}`);
    else if (go !== "cancel") ({tab: inNewTab, window: inWindow}[go] || (open || phoneOn() ? openDetail : x => menuGo(x, anchor)))(name);   // with a view open, or on the phone (no panes), Open shows the agent's view
  });
}
// A meeting attendee's menu. The face stands for the agent's meeting session, not the agent, so it has none of the
// agent's own items: everything said in a meeting goes to everyone in it. It shows who it is and whether its session
// is active and, while the meeting is open, Mention puts @<name> in the meeting's box.
function meetMenu(anchor, name, beside, rested) {
  const a = meetAgent(name), key = "meet:" + name, pane = anchor.closest(".pane");
  const box = pane?.querySelector('textarea.say[data-name^="~meeting:"]');
  const m = meetOf(nodeAt(layout().root, pane?.dataset.path || "") || {}), state = anchor.title.split(", ").slice(1).join(", ");
  if (menuOn(key)) { if (rested) return; if (menu.dataset.rested) delete menu.dataset.rested; else menuOff(true); return; }
  menuAt(anchor, key, `<div class="hd"><div class="hrow"><div class="htxt"><span class="name" style="--c:${a.colour}">${esc(a.fullName || name)} · meeting</span>` +
    `<div>${esc(a.roleName || "")}</div>${state ? `<div>${esc(state[0].toUpperCase() + state.slice(1))}</div>` : ""}</div>` +
    `${a.altPortrait || a.portrait ? `<span class="mpor"><img src="${esc(a.altPortrait || a.portrait)}" alt=""></span>` : ""}</div></div>` +
    (m && !m.ended && box ? `<div class="mi" data-go="mention">${MENU_ICON.said}Mention @${esc(name)}</div>` : ""), beside);
  if (rested) menu.dataset.rested = "1";
  menu.querySelectorAll(".mi[data-go=mention]").forEach(mi => mi.onclick = () => {
    menuOff(true);
    const at = box.selectionStart ?? box.value.length, pre = box.value.slice(0, at), gap = !pre || /\s$/.test(pre) ? "" : " ";
    box.value = pre + gap + "@" + name + " " + box.value.slice(at); grow(box); keep(box); aim(box);
    box.setSelectionRange(pre.length + gap.length + name.length + 2, pre.length + gap.length + name.length + 2);
  });
}
// A tile or List row shows its agent's menu beside it after a moment's rest, or at once on a right-click.
// The agents a Combined pane's chat can switch to: the pane's running agents, the one in the chat ticked; picking that
// one again closes the chat.
function chatPick(anchor) {
  const path = anchor.dataset.chat, key = "chatpick:" + path, n = nodeAt(layout().root, path), cur = n?.chat;
  if (menuOn(key)) return menuOff(true);
  const them = n ? paneAgents(n).filter(a => a.live) : [];
  menuAt(anchor, key, `<div class="hd"><div>Chat with</div></div>` + them.map(a => `<div class="mi" data-pick="${esc(a.name)}">${face(a, "")}` +
    `${esc(shown(a.name))}${MENU_ICON.check.replace("<svg", `<svg class="tick${a.name === cur ? "" : " off"}"`)}</div>`).join(""), false);
  menu.querySelectorAll(".mi[data-pick]").forEach(mi => mi.onclick = () => {
    menuOff(true); chatWith(path, mi.dataset.pick === cur ? null : mi.dataset.pick);   // the ticked one closes the chat
  });
}
// A Combined pane's chat (n.chat, kept with the layout and with the pane's tab) opened with an agent, or closed for null.
function chatWith(path, name) {
  const l = layout(), n = nodeAt(l.root, path);
  if (!n) return;
  if (name) n.chat = name; else delete n.chat;
  saveLayout(l); draw();
  if (name) aim($(`#main .pane[data-path="${path}"] .chat .say`));
}
// Whether the last press was a finger. A tap sends mouseenter too, and a rest's menu must not open on it. Nor does one
// open on the phone layout, where a menu is a sheet whose backdrop covers what was rested on: it would close and open
// again for as long as the pointer stayed.
let touched = false;
document.addEventListener("pointerdown", e => { touched = e.pointerType === "touch"; }, true);
function menuSoon(el, wait) {
  if (wait > 0 && (touched || phoneOn())) return;
  clearTimeout(menuShow); clearTimeout(menuHide);
  // A redraw in the wait replaces el; a detached one measures as 0,0 and the menu would open in the corner.
  menuShow = setTimeout(() => el.isConnected && agentMenu(el, el.dataset.name, true, wait > 0), wait);
}
// The team's play, pause and stop buttons, one of them on at a time: stop (red) while nobody runs or the page has wound
// the team down (team/team-paused.sh says so and nobody is working), pause (amber) while the nudger is paused, play (green) while the
// team runs. Play starts a stopped team (those running when the page last stopped it, else everyone with a Session) or
// resumes the nudger; pause pauses the nudger; stop asks the lead to wind the team down (greyed while no lead runs), after a second click to
// confirm. The button clicked fades in and out in its colour until the page sees the change.
let teamAsk = null, nudgerTo = null;   // nudgerTo: the nudger state a click is waiting to see
function teamButton() {
  const lead = S.agents.find(a => a.name === S.lead), starting = S.starting.includes("team");   // the first running of delivery lead, head of testing, head of operations, assistant
  const team = S.agents.filter(a => a.role !== "pa");   // an assistant is not on the team: it neither holds a wind-down nor makes a team running
  const working = team.filter(a => a.live && (a.status === "busy" || a.status === "waiting" || a.compacting)).map(a => a.name);
  const stopping = !starting && S.halting.includes("team");
  const woundDown = !starting && !stopping && !!S.teamUp && S.teamPaused && !working.length;
  const down = !starting && !stopping && (woundDown || !team.some(a => a.live));   // no lead alone is not a stopped team
  if (nudgerTo != null && nudgerTo === S.nudgerPaused) nudgerTo = null;
  if (down || stopping || starting) { clearTimeout(teamAsk); teamAsk = null; }
  const on = starting || stopping || nudgerTo != null ? "" : down ? "stop" : S.nudgerPaused ? "pause" : "play";
  const go = starting || nudgerTo === false ? "play" : stopping ? "stop" : nudgerTo ? "pause" : "";
  const tips = {
    play: starting ? "Starting the team" : nudgerTo === false ? "Resuming the nudger" : on === "play" ? "The team is running"
      : on === "pause" ? "Resume the nudger"
      : `Start ${S.teamUp ? S.teamUp.map(shown).join(", ") + ", who were running when the team stopped" : "the team: everyone with a Session on the roster"}`,
    pause: nudgerTo ? "Pausing the nudger" : on === "pause" ? "The nudger is paused" : on === "play" ? "Pause the nudger" : "",
    stop: stopping ? (working.length ? `Stopping: waiting for ${working.join(", ")}` : `Stopping: waiting for ${lead?.name || "the lead"} to pause the nudger`)
      : teamAsk ? `Click again to ask ${lead.name} to wind the team down: everyone stops at a clean point and the nudger pauses`
      : on === "stop" ? "The team is stopped" : lead?.live ? `Stop the team: ask ${shown(lead.name)} to wind everyone down` : "",
  };
  const key = [on, go, !!teamAsk, ...Object.values(tips)].join("|");
  if ($("#teamctl").dataset.text === key) return;
  const COLOUR = {play: "var(--green)", pause: "var(--amber)", stop: "var(--red)"}, ICON = {play: "start", pause: "pause", stop: "stop"};
  const btn = k => `<b class="fbtn tc-${k}${on === k ? " lit" : ""}${go === k ? " going" : ""}${k === "stop" && teamAsk ? " warn" : ""}${tips[k] ? "" : " idle"}" ` +
    `style="--c:${COLOUR[k]}" title="${esc(tips[k])}">${MENU_ICON[ICON[k]]}${k === "stop" && teamAsk ? "<span>Stop the team?</span>" : ""}</b>`;
  $("#teamctl").innerHTML = btn("play") + btn("pause") + btn("stop");
  $("#teamctl").dataset.text = key;
  const nudge = paused => {
    nudgerTo = paused; teamButton();
    setTimeout(() => { if (nudgerTo != null) { nudgerTo = null; teamButton(); } }, 10000);   // a request that went wrong stops waiting
    post(paused ? "/api/nudger/pause" : "/api/nudger/resume");
  };
  $("#teamctl .tc-play").onclick = () => { if (go) return; if (on === "stop") post("/api/team/start"); else if (on === "pause") nudge(false); };
  $("#teamctl .tc-pause").onclick = () => { if (!go && on === "play") nudge(true); };
  $("#teamctl .tc-stop").onclick = () => {
    if (go || on === "stop" || !lead?.live) return;
    if (!teamAsk) { teamAsk = setTimeout(() => { teamAsk = null; teamButton(); }, 4000); return teamButton(); }
    clearTimeout(teamAsk); teamAsk = null; post("/api/team/stop"); teamButton();
  };
}
// A filter button's: each lane, ticked while it is shown; a click shows or hides it and leaves the menu open. It opens
// after a moment's rest on the button, going again when the pointer has left both, or at once on a click, staying
// until a click elsewhere; a click on the button while it shows keeps a rested-on menu, else closes it.
function filterButton(btn, list, on, tip, flip, head = "Show") {
  menuButton(btn, rested => filterMenu(btn, list, on, tip, flip, rested, head));
}
// A button whose menu opens after a moment's rest on it or at once on a click (open(rested) draws it).
function menuButton(btn, open) {
  btn.onclick = e => { e.stopPropagation(); clearTimeout(menuShow); open(false); };
  btn.onmouseenter = () => {
    clearTimeout(menuHide); if (menuOn(btn.dataset.menu) || touched || phoneOn()) return;   // see menuSoon
    clearTimeout(menuShow); menuShow = setTimeout(() => btn.isConnected && open(true), 350);   // as menuSoon
  };
  btn.onmouseleave = () => { clearTimeout(menuShow); if (menu.dataset.rested) menuOff(); };
}
function filterMenu(btn, list, on, tip, flip, rested, head) {
  const key = btn.dataset.menu;
  if (menuOn(key)) { if (rested) return; if (menu.dataset.rested) delete menu.dataset.rested; else menuOff(true); return; }
  const ticks = () => menu.querySelectorAll(".mi").forEach(mi => mi.querySelector("svg.tick").classList.toggle("off", !on().includes(mi.dataset.lane)));
  menuAt(btn, key, `<div class="hd"><div>${head}</div></div>` + list.map(([l, t, icon]) =>
    `<div class="mi" data-lane="${esc(l)}" title="${esc(tip(l))}">${icon ?? MENU_ICON[l] ?? ""}${esc(t || S.owner)}${MENU_ICON.check.replace("<svg", '<svg class="tick"')}</div>`).join(""), false);
  ticks();
  if (rested) menu.dataset.rested = "1";
  menu.querySelectorAll(".mi").forEach(mi => mi.onclick = () => { flip(mi.dataset.lane); ticks(); });
}
// only a running agent opens in a new tab: one that is not running has nothing to show
const liveAt = e => { const name = agentAt(e); return name && S?.agents.find(a => a.name === name)?.live ? name : null; };
addEventListener("click", e => { const name = (e.ctrlKey || e.metaKey) && liveAt(e); if (name) { e.preventDefault(); e.stopPropagation(); inNewTab(name); } }, true);
addEventListener("auxclick", e => { const name = e.button === 1 && liveAt(e); if (name) { e.preventDefault(); e.stopPropagation(); inNewTab(name); } }, true);
addEventListener("mousedown", e => { if (e.button === 1 && liveAt(e)) e.preventDefault(); }, true);   // no autoscroll on a middle click
// ── The phone ────────────────────────────────────────────────────────────────────────────────────────────────────
// At 700px or narrower (owner, 2026-11-08) the page is drawn as a phone app in #phone: a header with the logo, the
// team's state, the week and the team menu; then the team as a list, waiting agents first, or as portraits, or the
// Team chat or Day log; and tabs along the bottom. An agent opens in the agent view, full screen. A tablet or a wide
// window keeps the desktop page; "Desktop layout" in the team menu keeps it on a phone too, in this browser.
const PHONE_MQ = matchMedia("(max-width:700px)");
const phoneOn = () => PHONE_MQ.matches && !ONLY && localStorage.getItem("phone") !== "off";
// The toolbar: up to PH_MAX of the panels, chosen and put in order in the team menu and kept in this browser; until
// chosen, the first four (owner, 2026-11-10: "let me choose up to 5 for my toolbar", then "can the toolbar items be
// reorderable"). The tab showing is one of them.
const PH_MAX = 5;
function phToolbar() {
  let mine; try { mine = JSON.parse(localStorage.getItem("phonetabs")); } catch (e) {}
  const keys = PH_TABS.map(([k]) => k), on = Array.isArray(mine) ? [...new Set(mine)].filter(k => keys.includes(k)).slice(0, PH_MAX) : [];
  return on.length ? on : keys.slice(0, 4);
}
const phTabName = k => PH_TABS.find(([x]) => x === k)[1];
// The team menu's Toolbar slides in a second panel of the toolbar alone: its panels left to right, each dragged by its
// grip to reorder or taken out, then the others to add while there is room (owner, 2026-11-10: "the toolbar should
// have a > which slides in a second panel with just the toolbar options - they should be draggable to reorder").
let phMenuAt = "team";
const PH_GRIP = `<svg viewBox="0 0 16 16" width="16" height="16" fill="currentColor" aria-hidden="true"><circle cx="5.5" cy="4" r="1.2"/><circle cx="10.5" cy="4" r="1.2"/><circle cx="5.5" cy="8" r="1.2"/><circle cx="10.5" cy="8" r="1.2"/><circle cx="5.5" cy="12" r="1.2"/><circle cx="10.5" cy="12" r="1.2"/></svg>`;
const phToolbarSave = next => { if (next.length && next.length <= PH_MAX) { localStorage.setItem("phonetabs", JSON.stringify(next)); phoneDraw(); } };
function phToolbarMenu(slide) {
  const sh = $("#phsheet"), bar = phToolbar(), spare = PH_TABS.filter(([k]) => !bar.includes(k));
  sh.innerHTML = `<div class="sh tbsheet" role="dialog" aria-label="Toolbar"><span class="grab"></span>` +
    `<div class="tbhead"><button class="tbback" data-go="back" aria-label="Back to the team menu">${PH_ICON.chev}</button><h2>TOOLBAR</h2></div>` +
    `<h3>PREVIEW</h3><div class="tbprev" style="grid-template-columns:repeat(${bar.length},minmax(0,1fr))">${bar.map((k, i) => `<span class="${i ? "" : "on"}">${PH_ICON[k]}<small>${phTabName(k)}</small></span>`).join("")}</div>` +
    `<h3>SLOTS · DRAG TO REORDER</h3>` +
    `<div class="tblist">${bar.map((k, i) => `<div class="tbrow" data-k="${k}"><span class="tbgrip" aria-label="Drag ${phTabName(k)} to reorder">${PH_GRIP}</span><span class="tbnum">${i + 1}</span>${PH_ICON[k]}<span class="tbname">${phTabName(k)}</span>` +
      `<button data-go="out:${k}"${bar.length > 1 ? "" : " disabled"} aria-label="Take ${phTabName(k)} out">${MENU_ICON.close}</button></div>`).join("")}</div>` +
    (spare.length ? `<h3>${bar.length >= PH_MAX ? `NOT IN THE TOOLBAR · TAKE ONE OUT TO ADD` : "ADD"}</h3><div class="tbopts">${spare.map(([k, l]) => `<button data-go="add:${k}"${bar.length >= PH_MAX ? " disabled" : ""}>${PH_ICON[k]}+ ${l}</button>`).join("")}</div>` : "") +
    `<div class="note">Up to ${PH_MAX}, left to right. Changes save as you go.</div></div>`;
  const panel = sh.querySelector(".sh"), list = panel.querySelector(".tblist");
  if (!sh.classList.contains("on")) sh.classList.add("on");
  if (slide) panel.classList.add(slide);
  phSheetDrag(panel);
  panel.querySelectorAll("[data-go]").forEach(b => b.onclick = () => {
    const [go, k] = b.dataset.go.split(":");
    if (go === "back") { phMenuAt = "team"; phoneMenu(false, "slideback"); return; }
    phToolbarSave(go === "out" ? bar.filter(x => x !== k) : [...bar, k]);
    phToolbarMenu();
  });
  // a row follows the finger or mouse on its grip: a row it passes the middle of moves to its other side. The row held
  // is never moved itself, as a browser lets go of a pointer whose element leaves the page, even for a moment.
  list.querySelectorAll(".tbgrip").forEach(g => {
    g.addEventListener("touchstart", e => e.stopPropagation(), {passive: true});
    g.onpointerdown = e => {
      e.preventDefault(); e.stopPropagation();
      const row = g.closest(".tbrow"); g.setPointerCapture(e.pointerId); row.classList.add("moving");
      g.onpointermove = ev => {
        const rows = [...list.children], at = rows.indexOf(row);
        rows.forEach((r, i) => {
          if (r === row) return;
          const b = r.getBoundingClientRect(), mid = b.top + b.height / 2;
          if (i > at && ev.clientY > mid) list.insertBefore(r, row);
          else if (i < at && ev.clientY < mid) list.insertBefore(r, row.nextSibling);
        });
        [...list.children].forEach((r, i) => { r.querySelector(".tbnum").textContent = i + 1; });
      };
      g.onpointerup = g.onpointercancel = g.onlostpointercapture = () => {
        g.onpointermove = g.onpointerup = g.onpointercancel = g.onlostpointercapture = null; row.classList.remove("moving");
        const next = [...list.children].map(r => r.dataset.k);
        if (next.join() !== bar.join()) { phToolbarSave(next); phToolbarMenu(); }
      };
    };
  });
}
const phoneTab = () => { const on = phToolbar(), t = localStorage.getItem("phonetab"); return on.includes(t) ? t : on[0]; };
const PH_ICON = {
  more: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="5" cy="12" r="1.2"/><circle cx="12" cy="12" r="1.2"/><circle cx="19" cy="12" r="1.2"/></svg>`,
  list: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><circle cx="9" cy="8" r="3.5"/><path d="M2.5 20c.8-3.6 3.4-5.5 6.5-5.5s5.7 1.9 6.5 5.5M16 4.6a3.5 3.5 0 0 1 0 6.8M18.5 14.8c1.6.8 2.6 2.5 3 5.2"/></svg>`,
  faces: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="3" width="7.5" height="7.5" rx="2"/><rect x="3" y="13.5" width="7.5" height="7.5" rx="2"/><rect x="13.5" y="13.5" width="7.5" height="7.5" rx="2"/></svg>`,
  team: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><path d="M4 5h16v11H9l-5 4z"/></svg>`,
  mix: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 6h16M4 12h10M4 18h13"/><circle cx="19" cy="12" r="2"/></svg>`,
  day: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><rect x="4" y="5" width="16" height="15" rx="2"/><path d="M4 10h16M9 3v4M15 3v4"/></svg>`,
  chev: `<svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6"/></svg>`,
  queue: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6h11M9 12h11M9 18h11"/><path d="M3.5 6l1.5 1.5L7.5 5M3.5 12l1.5 1.5L7.5 11"/><circle cx="5" cy="18" r="1.2"/></svg>`,
  perf: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 12h4l3-7 4 14 3-7h4"/></svg>`,
  dash: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round" aria-hidden="true"><rect x="3" y="3" width="18" height="7" rx="2"/><rect x="3" y="13" width="8" height="8" rx="2"/><rect x="14" y="13" width="7" height="8" rx="2"/></svg>`
};
// The Dashboard, the phone's own panel: any of the bar's readings (its plug-ins: Week, Session, Team, Disk and the
// rest) as live tiles on two columns, each half or full width, in the order chosen (owner, 2026-11-10: "a panel I can
// add header and footer items to in any arrangement ... a mobile only panel"). Kept in this browser as phonedash,
// [{k: key, w: 1 or 2}]; until arranged, the header's readings in its order, each half width. Edit moves, widens,
// takes out and adds tiles.
let phDashEdit = false;
// Done, while arranging: a cross
const PH_CROSS = `<svg viewBox="0 0 16 16" width="20" height="20" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8"/></svg>`;
// the filter icon's sliders, upright: three lines, each with its knob (owner, 2026-11-10: "the 3 lines filter icon - but vertical")
const PH_TUNE = `<svg viewBox="0 0 16 16" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" aria-hidden="true"><path d="M3.5 1.5v3M3.5 8.5v6M8 1.5v8M8 13.5v1M12.5 1.5v1M12.5 6.5v8"/><circle cx="3.5" cy="6.5" r="2"/><circle cx="8" cy="11.5" r="2"/><circle cx="12.5" cy="4.5" r="2"/></svg>`;
// The bar's own items that show the team, offered beside the readings: the Agents count, the Bench and the Favourites
// (owner, 2026-11-10: "Bench is a header and footer item and I asked for a favourites too"). The bar's buttons
// (Start and stop, Lanes, Views, Lock, Theme, Settings, Help) are the phone's ⋯ menu's.
const PH_DASH_OWN = ["tally", "bench", "favs", "active"];
const phDashItems = () => [...PH_DASH_OWN.map(k => ({key: k, own: true, name: BAR_ITEMS[k]})), ...plugs().filter(x => !x.hidden)];
// an own item's tile body: the count as the header's tally reads it; the bench and the favourites as portraits, a tap
// opening a running one and a hold its menu
function phDashOwn(k) {
  if (k === "tally") {
    const n = st => S.agents.filter(a => a.live && stOf(a) === st).length, waiting = S.agents.filter(a => a.status === "waiting").length;
    return `<div class="dval dtally" title="${n("busy")} working, ${n("idle")} idle${waiting ? `, ${waiting} waiting` : ""}"><i style="background:var(--green)"></i><b>${n("busy")}</b><i></i><b style="color:var(--mute)">${n("idle")}</b>${waiting ? `<span style="color:var(--amber)">${waiting} waiting</span>` : ""}</div>`;
  }
  const who = barWho(k);
  return who.length ? `<div class="dfaces">${who.map(a => `<button class="dface" ${a.live ? `data-open="${esc(a.name)}" ` : ""}data-menu-name="${esc(a.name)}" aria-label="${esc(shown(a.name))}" title="${esc(shown(a.name))}">${phPor(a.live ? a : {...a, live: undefined}, a.live ? "" : " bench")}</button>`).join("")}</div>`
    : `<div class="dval" style="color:var(--mute);font-weight:400;font-size:1em">${BAR_ROW[k][2]}</div>`;
}
function phDash() {
  let mine; try { mine = JSON.parse(localStorage.getItem("phonedash")); } catch (e) {}
  const have = phDashItems().map(x => x.key);
  if (Array.isArray(mine)) return mine.filter(t => t && have.includes(t.k)).map(t => ({k: t.k, w: t.w === 2 ? 2 : 1}));
  return barOf().head.filter(k => have.includes(k)).map(k => ({k, w: 1}));
}
const phDashSave = d => localStorage.setItem("phonedash", JSON.stringify(d));
function phDashHtml() {
  const d = phDash(), by = Object.fromEntries(phDashItems().map(x => [x.key, x]));
  const tile = (t, i) => {
    const x = by[t.k], m = !x.own && x.meter, parts = (x.parts || [{text: x.value, colour: x.colour}]).filter(p => p.text !== "");
    const val = parts.map(p => `<${p.bold ? "b" : "span"} style="color:${plugColour(p.colour || (x.parts ? "" : x.colour))}">${esc(p.text)}</${p.bold ? "b" : "span"}>`).join("");
    return `<div class="dtile${t.w === 2 ? " wide" : ""}" data-k="${esc(t.k)}" title="${esc(x.title || "")}"><div class="dlab">${phDashEdit ? `<span class="dgrip" aria-label="Drag ${esc(phGaugeName(x))} to move it">${PH_GRIP}</span>${esc(phGaugeName(x))}` : phGaugeLabel(x)}</div>${x.own ? phDashOwn(t.k) : `<div class="dval">${val || "–"}</div>`}` +
      (m ? `<div class="dmeter"><i style="width:${m.pct}%;background:${meterFill(m)}"></i>${m.mark == null ? "" : `<u style="left:calc(${m.mark}% - 1px)"></u>`}</div>` : "") +
      (!x.own && x.spark?.length ? `<div class="dspark">${spark(x.spark, Math.max(1, ...x.spark), "currentColor")}</div>` : "") +
      (phDashEdit ? `<div class="dedit">` +
        `<button data-dash="wide:${i}">${t.w === 2 ? "Half" : "Wide"}</button><button class="dx" data-dash="out:${i}" aria-label="Take out" title="Take out">${MENU_ICON.close}</button></div>` : "") + `</div>`;
  };
  const spare = phDashItems().filter(x => !d.some(t => t.k === x.key));
  return `<div class="ph-dash"><div class="dhead"><b>Dashboard</b>${phDashEdit ? `<button class="dbtn dtune dclose" data-dash="edit" aria-label="Done arranging" title="Done">${PH_CROSS}</button>`
    : `<button class="dbtn dtune" data-dash="edit" aria-label="Arrange the dashboard" title="Arrange the dashboard">${PH_TUNE}</button>`}</div>` +
    (d.length ? `<div class="dgrid">${d.map(tile).join("")}</div>` : `<div class="blank">Nothing on the dashboard. Tap Edit to add readings.</div>`) +
    (phDashEdit && spare.length ? `<div class="dadd"><span>Add</span>${spare.map(x => `<button data-dash="add:${esc(x.key)}">+ ${esc(phGaugeName(x))}</button>`).join("")}</div>` : "") + `</div>`;
}
// In Edit, a tile follows the finger or mouse on its grip, taking the place of the tile it is over; the tiles between
// shift along. The tile held is never moved itself (a browser lets go of a pointer whose element leaves the page), and
// the dashboard is not redrawn under the finger until it lifts.
let phDashDrag = false;
function phDashWire(body) {
  const grid = body.querySelector(".dgrid");
  grid?.querySelectorAll(".dgrip").forEach(g => {
    if (g.onpointerdown) return;
    g.addEventListener("touchstart", e => e.stopPropagation(), {passive: true});
    g.onpointerdown = e => {
      e.preventDefault(); e.stopPropagation();
      const tile = g.closest(".dtile"); g.setPointerCapture(e.pointerId); tile.classList.add("moving"); phDashDrag = true;
      g.onpointermove = ev => {
        const tiles = [...grid.children], at = tiles.indexOf(tile);
        const j = tiles.findIndex(t => { const b = t.getBoundingClientRect(); return t !== tile && ev.clientX > b.left && ev.clientX < b.right && ev.clientY > b.top && ev.clientY < b.bottom; });
        if (j < 0) return;
        if (j > at) for (let k = at + 1; k <= j; k++) grid.insertBefore(tiles[k], tile);
        else for (let k = at - 1; k >= j; k--) grid.insertBefore(tiles[k], tile.nextSibling);
      };
      g.onpointerup = g.onpointercancel = g.onlostpointercapture = () => {
        g.onpointermove = g.onpointerup = g.onpointercancel = g.onlostpointercapture = null; tile.classList.remove("moving"); phDashDrag = false;
        const w = Object.fromEntries(phDash().map(t => [t.k, t.w]));
        phDashSave([...grid.children].map(t => ({k: t.dataset.k, w: w[t.dataset.k] || 1})));
        phoneDraw();
      };
    };
  });
}
function phDashAct(go) {
  const [what, arg] = go.split(/:(.*)/s), d = phDash(), i = +arg;
  if (what === "edit") phDashEdit = !phDashEdit;
  else if (what === "wide") d[i].w = d[i].w === 2 ? 1 : 2;
  else if (what === "out") d.splice(i, 1);
  else if (what === "add") d.push({k: arg, w: 1});
  if (what !== "edit") phDashSave(d);
  phoneDraw();
}
const PH_TABS = [["list", "Agents"], ["faces", "Portraits"], ["mix", "Combined"], ["day", "Day log"], ["queue", "Work queue"], ["perf", "Performance"], ["dash", "Dashboard"]];   // no Team chat on the phone (owner, 2026-11-08: "lose the team chat")
// an agent's portrait, else its role's shadow, framed in its colour, with a dot for its state
const phPor = (a, cls = "") => `<span class="ph-por${cls}" style="--c:${a.colour || "#888"}"><span class="fr">${a.portrait ? `<img src="${esc(a.portrait)}" alt="" loading="lazy">` : shadow(a)}</span>${a.live === undefined ? "" : "<i></i>"}</span>`;
// a line of what an agent said last, as plain text
const phPlain = s => String(s || "").replace(/```[\s\S]*?```/g, " ").replace(/[`*_>#|]/g, "").replace(/\s+/g, " ").trim();
function phLast(a) {
  const live = (a.feed || []).find(it => it.kind === "live");
  if (live) return {text: live.text, live: true};
  const said = [...(a.feed || [])].reverse().find(it => it.kind === "said" || it.kind === "peer" && it.who);
  return {text: said ? (said.kind === "peer" ? shown(said.who) + ": " : "") + phPlain(said.text) : ""};
}
// the team's state in a few words, as the team buttons read it
function phTeamState() {
  const team = S.agents.filter(a => a.role !== "pa"), busy = team.some(a => a.live && (a.status === "busy" || a.status === "waiting" || a.compacting));
  const state = S.starting.includes("team") ? ["Starting", "var(--amber)"] : S.halting.includes("team") ? ["Stopping", "var(--amber)"]
    : S.teamUp && S.teamPaused && !busy || !team.some(a => a.live) ? ["Stopped", "var(--faint)"] : ["Running", "var(--green)"];
  return {word: state[0], colour: state[1], up: S.agents.filter(a => a.live).length, off: S.bench.length + S.agents.filter(a => !a.live).length};
}
// How the Agents and Portraits tabs order the team: by status (waiting, working, idle, stopped) or by role.
const phOrder = () => localStorage.getItem("phoneorder") === "state" ? "state" : "role";   // by role unless Status is chosen (owner, 2026-11-09: "portraits should be grouped by role")
// Favourites (owner, 2026-11-09: "favourites ... listed at the top"): agents starred from their menu, kept in this browser
// and listed by name, shown first on the Agents and Portraits tabs in either order and not again below, and in the
// bar's Favourites item.
const phFavs = () => { try { const v = JSON.parse(localStorage.getItem("phonefavs")); return Array.isArray(v) ? v.filter(n => typeof n === "string").sort((x, y) => x.localeCompare(y, undefined, {sensitivity: "base"})) : []; } catch (e) { return []; } };
const phFav = name => phFavs().includes(name);
// The agents in each of the bars' rows of agents, by item: the bench, less the favourites while their bar is on screen
// (owner, 2026-11-11: "favourites should not also show on the bench", "icons should show on the bench when I don't have the
// favourites bar on the screen"); the favourites, running or not; and the active, every
// running agent not among the favourites, each with its state's dot (owner, 2026-11-11: "put the in shell icons in active",
// "active should not show favourites", "I have 7 active agents").
const favsShown = () => phoneOn() ? phDash().some(t => t.k === "favs") : (b => [...b.head, ...b.foot].includes("favs"))(barOf());
const barWho = k => k === "bench" ? (favsShown() ? S.bench.filter(a => !phFav(a.name)) : S.bench)
  : k === "favs" ? phFavs().map(n => S.agents.find(a => a.name === n) || S.bench.find(a => a.name === n)).filter(Boolean)
  : k === "active" ? S.agents.filter(a => a.live && !phFav(a.name)) : [];
const BAR_ROW = {favs: ["Favourites: star an agent from its menu", "none yet", "No favourites yet: star an agent from its menu"],
  active: ["Running, other than the favourites", "none", "No one else running"], bench: ["On the bench", "", "No one on the bench"]};
// A desktop bar's row of agents (favs or active) in its element: its icon, then each agent by name or icon as
// the bench is set to show them; a rest or right-click shows its menu and a click opens a running one.
function agentRow(el, k, style) {
  const html = `<span title="${esc(BAR_ROW[k][0])}">${ADD_ICON[k]}</span><span class="rrow">${barWho(k).map(a => {
    const tip = `data-name="${esc(a.name)}" data-fav="${esc(a.name)}"`;
    return style === "icon" ? face(a, tip, a.live ? "" : " benched") : `<em class="${a.live ? "" : "off"}" style="--c:${a.colour}" ${tip}>${esc(shown(a.name))}</em>`; }).join("") || `<span class="none">${BAR_ROW[k][1]}</span>`}</span>`;
  if (el.dataset.html !== html) { el.innerHTML = html; el.dataset.html = html; }
  el.querySelectorAll(".rrow [data-name]").forEach(m => {
    m.onmouseenter = () => menuSoon(m, 350); m.onmouseleave = () => { clearTimeout(menuShow); if (menu.dataset.rested) menuOff(); };
    m.oncontextmenu = e => { e.preventDefault(); menuSoon(m, 0); };
    m.onclick = () => { if (S.agents.some(a => a.name === m.dataset.fav && a.live)) openDetail(m.dataset.fav); };
  });
}
function phFavToggle(name) {
  const f = phFavs(), next = f.includes(name) ? f.filter(x => x !== name) : [...f, name];
  try { localStorage.setItem("phonefavs", JSON.stringify(next)); } catch (e) {}
  phoneOn() ? phoneDraw() : draw();
  if (open) phRail();   // the agent view's strip, favourites first, too
}
// [role, its agents] in the page's role order; within a role by name, running and stopped together
function phByRole() {
  const all = [...S.agents, ...S.bench];
  return roleList().map(r => [r, all.filter(a => a.role === r.role).sort(byName)]).filter(([, list]) => list.length);
}
function phListHtml() {
  const favs = phFavs().map(n => S.agents.find(a => a.name === n) || S.bench.find(a => a.name === n)).filter(Boolean);
  const notFav = a => !favs.includes(a);
  const live = S.agents.filter(a => a.live && notFav(a)), wait = live.filter(a => a.status === "waiting").sort((x, y) => (y.held || 0) - (x.held || 0));
  const work = live.filter(a => a.status !== "waiting" && (a.status === "busy" || a.compacting || a.status === "shell"));
  const idle = live.filter(a => !wait.includes(a) && !work.includes(a));
  const off = [...S.agents.filter(a => !a.live), ...S.bench].filter(notFav);
  const banner = a => { const ask = (a.feed || []).find(it => it.kind === "ask");
    return `<button class="ph-wait waiting" data-open="${esc(a.name)}" data-menu-name="${esc(a.name)}">${phPor(a)}<span class="ph-mid"><small>Waiting for you · ${ago(a.held)}</small><b>${esc(shown(a.name))}: ${esc(phPlain(ask?.text) || "a prompt is open")}</b></span>${PH_ICON.chev}</button>`; };
  const row = (a, big) => { const st = stOf(a), last = phLast(a), n = unseen(a);
    return `<button class="ph-row ${st}${big ? " big" : ""}${switching(a)}" data-open="${esc(a.name)}" data-menu-name="${esc(a.name)}">${phPor(a, big ? "" : " s")}<span class="ph-mid"><span class="ph-line1"><span class="ph-name">${esc(shown(a.name))}</span>` +
      (a.ticket ? `<span class="ph-tk">${esc(a.ticket)}</span>` : big ? "" : `<span class="ph-role">${esc(a.roleName || "")}</span>`) +
      `<span class="ph-right">${n ? unseenBadge(n) : ""}${big ? (a.ctxPct == null ? "" : `<span style="color:${gauge(a.ctxPct)}">${a.ctxPct}%</span>`) : `${STATE[st] || esc(st)} ${ago(a.held)}`}</span></span>` +
      (big && last.text ? `<span class="ph-sub${last.live ? " live" : ""}">${esc(last.text)}</span>` : "") + `</span></button>`; };
  const sec = (title, list, big) => list.length ? `<section><h2>${title} · ${list.length}</h2><div class="ph-list">${list.map(a => row(a, big)).join("")}</div></section>` : "";
  // by role (owner, 2026-11-08): each role's agents in the roster's order, running or not, a stopped one greyed
  const rrow = a => { if (!a.live) return `<button class="ph-row off" data-menu-name="${esc(a.name)}">${phPor({...a, live: undefined}, " s bench")}<span class="ph-mid"><span class="ph-line1"><span class="ph-name" style="color:var(--mute)">${esc(shown(a.name))}</span><span class="ph-right">stopped</span></span></span></button>`;
      const st = stOf(a), last = phLast(a), n = unseen(a), busy = st === "busy" || st === "compacting" || st === "waiting";
      return `<button class="ph-row ${st}${busy ? " big" : ""}${switching(a)}" data-open="${esc(a.name)}" data-menu-name="${esc(a.name)}">${phPor(a, busy ? "" : " s")}<span class="ph-mid"><span class="ph-line1"><span class="ph-name">${esc(shown(a.name))}</span>` +
        (a.ticket ? `<span class="ph-tk">${esc(a.ticket)}</span>` : "") +
        `<span class="ph-right">${n ? unseenBadge(n) : ""}<span style="color:${st === "waiting" ? "var(--amber)" : busy ? "var(--green)" : "var(--mute)"}">${STATE[st] || esc(st)}</span> ${ago(a.held)}</span></span>` +
        (busy && last.text ? `<span class="ph-sub${last.live ? " live" : ""}">${esc(last.text)}</span>` : "") + `</span></button>`; };
  const fav = favs.length ? `<section class="ph-favs"><h2>${MENU_ICON.star}Favourites · ${favs.length}</h2><div class="ph-list">${favs.map(rrow).join("")}</div></section>` : "";
  if (phOrder() === "role") {
    return fav + wait.map(banner).join("") + phByRole().map(([r, list]) => [r, list.filter(notFav)]).filter(([, list]) => list.length).map(([r, list]) => `<section><h2>${esc(r.name)} · ${list.length}</h2><div class="ph-list">${list.map(rrow).join("")}</div></section>`).join("") +
      (S.agents.length || S.bench.length ? "" : `<div class="ph-empty">No one on the roster</div>`);
  }
  return fav + wait.map(banner).join("") + sec("Working", work, true) + sec("Idle", idle, false) +
    (off.length ? `<section><h2>Stopped · ${off.length}</h2><div class="ph-chips">${off.map(a => `<button class="ph-chip${switching(a)}" data-menu-name="${esc(a.name)}">${phPor({...a, live: undefined}, " bench")}${esc(shown(a.name))}</button>`).join("")}</div></section>` : "") +
    (S.agents.length || S.bench.length ? "" : `<div class="ph-empty">No one on the roster</div>`);
}
function phFacesHtml() {
  const live = S.agents.filter(a => a.live), rank = a => a.status === "waiting" ? 0 : a.status === "busy" || a.compacting ? 1 : 2;
  let up = [...live].sort((x, y) => rank(x) - rank(y)), off = [...S.agents.filter(a => !a.live), ...S.bench];
  const tile = a => { const st = stOf(a), n = unseen(a);
    return `<button class="ph-tile ${st}${switching(a)}" data-open="${esc(a.name)}" data-menu-name="${esc(a.name)}" aria-label="${esc(shown(a.name))}, ${STATE[st] || st}">` +
      `<span class="ph-por" style="--c:${a.colour}"><span class="fr">${a.portrait ? `<img src="${esc(a.portrait)}" alt="" loading="lazy">` : shadow(a)}</span><span class="ph-st">${STATE[st] || esc(st)}</span>${n ? `<span class="ph-un">${unseenBadge(n)}</span>` : ""}</span>` +
      `<span class="ph-name">${esc(shown(a.name))}</span><span class="ph-role">${esc(a.ticket || a.roleName || "")}</span></button>`; };
  const offTile = a => `<button class="ph-tile off${switching(a)}" data-menu-name="${esc(a.name)}" aria-label="${esc(shown(a.name))}, stopped">${phPor({...a, live: undefined}, " bench")}<span class="ph-name" style="color:var(--mute)">${esc(shown(a.name))}</span><span class="ph-role">${esc(a.roleName || "")}</span></button>`;   // the grey says stopped; the line says the role (owner, 2026-11-09)
  // favourites first, as in the Agents tab, and not again under their role
  const favs = phFavs().map(n => S.agents.find(a => a.name === n) || S.bench.find(a => a.name === n)).filter(Boolean);
  const fav = favs.length ? `<section class="ph-favs"><h2>${MENU_ICON.star}Favourites</h2><div class="ph-grid">${favs.map(a => a.live ? tile(a) : offTile(a)).join("")}</div></section>` : "";
  if (phOrder() === "role") return fav + phByRole().map(([r, list]) => [r, list.filter(a => !favs.includes(a))]).filter(([, list]) => list.length).map(([r, list]) => `<section><h2>${esc(r.name)}</h2><div class="ph-grid">${list.map(a => a.live ? tile(a) : offTile(a)).join("")}</div></section>`).join("") +
    `<div class="ph-hint">Tap a portrait to open the agent · press and hold for its details</div>`;
  const notFav = a => !favs.includes(a);
  up = up.filter(notFav); off = off.filter(notFav);
  return fav + (up.length ? `<div class="ph-grid">${up.map(tile).join("")}</div>` : !live.length ? `<div class="ph-empty">No agent is running</div>` : "") +
    (off.length ? `<section><h2>Stopped</h2><div class="ph-grid bench">${off.map(a => `<button class="ph-tile${switching(a)}" data-menu-name="${esc(a.name)}">${phPor({...a, live: undefined}, " bench")}${esc(shown(a.name))}</button>`).join("")}</div></section>` : "") +
    `<div class="ph-hint">Tap a portrait to open the agent · press and hold for its details</div>`;
}
let phDayAt = 0, phMixAt = 0;
// The Combined tab: every running agent's conversation as one, in time order. Its Roles and lanes filters are the
// phone's own, kept in this browser (owner, 2026-11-08); until one is used, the desktop's first Combined pane's here,
// else every role, every lane.
function phMixNode() {
  let mine; try { mine = JSON.parse(localStorage.getItem("phonemix")); } catch (e) {}
  if (mine && Array.isArray(mine.roles) && Array.isArray(mine.clanes)) return {show: "combined", roles: mine.roles, clanes: mine.clanes};
  const desk = views().views.flatMap(v => v.layout ? leaves(v.layout.root).map(([, n]) => n) : []).find(n => n.show === "combined");
  return {show: "combined", roles: Array.isArray(desk?.roles) && desk.roles.length ? desk.roles : roleList().map(r => r.role), clanes: desk ? clanesOf(desk) : CALL};
}
// a filter's choice flips one role or lane, keeps the result as the phone's own, and reads any agent it brings in
function phMixFlip(key, x) {
  const n = phMixNode(), on = key === "roles" ? n.roles : n.clanes, next = on.includes(x) ? on.filter(y => y !== x) : [...on, x];
  localStorage.setItem("phonemix", JSON.stringify({roles: key === "roles" ? next : n.roles, clanes: key === "roles" ? n.clanes : next}));
  phMixAt = 0; phoneDraw();
}
// the Combined tab's filters: one ⋯ in its header, lit while something is left out, opening its Roles and its lanes
function phMixFilters(body) {
  const head = body.querySelector(".teamlog .thead");
  if (!head) return;
  head.querySelectorAll(".fbtn").forEach(b => b.remove()); head.classList.add("phmix");
  const n = phMixNode(), some = n.roles.length < roleList().length || n.clanes.length < CALL.length;
  head.insertAdjacentHTML("beforeend", `<b class="phmixmore fbtn${some ? " some" : ""}" data-menu="phmix" role="button" aria-label="Filter: roles and lanes" title="Roles and lanes">${PH_ICON.more}</b>`);
  head.querySelector(".phmixmore").onclick = e => { e.stopPropagation(); phMixMenu(e.currentTarget); };
}
function phMixMenu(btn) {
  if (menuOn("phmix")) return menuOff(true);
  const tick = MENU_ICON.check.replace("<svg", '<svg class="tick"');
  const row = (k, l, t, icon) => `<div class="mi" data-k="${k}" data-lane="${esc(l)}">${icon || ""}${esc(t)}${tick}</div>`;
  menuAt(btn, "phmix", `<div class="hd"><div>Roles</div></div>` + roleItems().map(([l, t, icon]) => row("roles", l, t, icon)).join("") +
    `<div class="hd sec"><div>Lanes</div></div>` + CLANES.map(([l, t]) => row("clanes", l, t || S.owner, MENU_ICON[l])).join(""), false);
  const ticks = () => { const n = phMixNode(); menu.querySelectorAll(".mi[data-k]").forEach(mi => mi.querySelector("svg.tick").classList.toggle("off", !n[mi.dataset.k].includes(mi.dataset.lane))); };
  ticks();
  menu.querySelectorAll(".mi[data-k]").forEach(mi => mi.onclick = () => { phMixFlip(mi.dataset.k, mi.dataset.lane); ticks(); });
}
// The page under a menu on the phone is dimmed, and a tap there closes the menu and does nothing else; the menu
// follows a finger pulling it down and closes if pulled far enough.
{
  const back = document.createElement("div"); back.id = "phmenuback"; document.body.append(back);
  back.onclick = e => { e.stopPropagation(); if (Date.now() - phHeld > 800) menuOff(true); };   // not the lift of the finger that held for it
  new MutationObserver(() => back.classList.toggle("on", phoneOn() && menu.classList.contains("on"))).observe(menu, {attributes: true, attributeFilter: ["class"]});
  phSheetDrag(menu, () => menuOff(true), back, () => phoneOn());
}
let phQueueAt = 0, phPerfAt = 0;
async function phLoad(tab) {
  // the Team chat and the Day log are read only while their tab is showing, as their panes are
  try {
    if (tab === "mix" && Date.now() - phMixAt > 3500) {
      phMixAt = Date.now();
      await Promise.all(paneAgents(phMixNode()).map(async a => {
        const d = await (await fetch("/api/agent/" + encodeURIComponent(a.name), {cache: "no-store"})).json(), t = JSON.stringify(d.feed);
        if (t !== paneText[a.name]) { paneConv[a.name] = d.feed; paneText[a.name] = t; paneVer[a.name] = (paneVer[a.name] || 0) + 1; }
      }));
      phoneDraw();
    }
    if (tab === "day" && Date.now() - phDayAt > (dayLog?.state === "reading" ? 3000 : 30000)) { phDayAt = Date.now(); dayLog = await (await fetch("/api/daylog", {cache: "no-store"})).json(); phoneDraw(); }
    // the Work queue and Performance are read while their tab shows, as often as their panes are
    if (tab === "queue" && Date.now() - phQueueAt > 3500) { phQueueAt = Date.now(); workQueue = await (await fetch("/api/workqueue", {cache: "no-store"})).json(); phoneDraw(); }
    if (tab === "perf" && Date.now() - phPerfAt > 1500) { phPerfAt = Date.now(); perfNow = await (await fetch("/api/perf", {cache: "no-store"})).json(); phoneDraw(); }
  } catch (e) {}
}
function phoneDraw() {
  const on = phoneOn(), html = document.documentElement;
  html.classList.toggle("phone", on); html.classList.toggle("phoneoff", PHONE_MQ.matches && !ONLY && !on);
  if (!on) return;
  const ph = $("#phone");
  if (!S) { if (!ph.firstChild) ph.innerHTML = `<div class="ph-loading">Loading…</div>`; return; }
  if (ph.querySelector(":scope > .ph-loading")) ph.innerHTML = "";
  const tab = phoneTab();
  if (!ph.firstChild) {
    ph.innerHTML = `<div class="ph-top"><div class="brand ph-logo"></div><div class="ph-title"></div><button class="ph-week"></button><button class="ph-icon" id="phmore" aria-label="Team menu">${PH_ICON.more}</button></div><div class="ph-body"></div>` +
      `<nav class="ph-nav" aria-label="Pages"></nav>`;
    ph.querySelector(".ph-logo").innerHTML = document.querySelector(".brand:not(.ph-logo)")?.innerHTML || "";   // the logo, wherever the bar has put it (header, footer or taken out)
    ph.querySelector(".ph-nav").onclick = e => { const b = e.target.closest("[data-tab]"); if (!b) return; localStorage.setItem("phonetab", b.dataset.tab); ph.querySelector(".ph-body").scrollTop = 0; try { phoneDraw(); } catch (e) { phError(e); } };
    $("#phmore").onclick = () => { try { phoneMenu(); } catch (e) { phError(e); } };
    ph.querySelector(".ph-week").onclick = () => { try { phoneMenu(); } catch (e) { phError(e); } };
    const body = ph.querySelector(".ph-body");
    body.addEventListener("click", e => {
      const dash = e.target.closest("[data-dash]");
      if (dash) { try { phDashAct(dash.dataset.dash); } catch (e) { phError(e); } return; }
      const who = body.dataset.tab === "mix" && e.target.closest(".who, .cnames .name");
      if (who) { const n = who.dataset.name || who.closest("[data-agent]")?.dataset.agent; if (n && S.agents.some(a => a.name === n && a.live)) return openDetail(n); }
      const o = e.target.closest("[data-open]"), m = e.target.closest("[data-menu-name]");
      if (Date.now() - phHeld < 600) return;   // the finger that held for the menu lifts with a click
      if (o) openDetail(o.dataset.open);
      else if (m) agentMenu(m, m.dataset.menuName, false, false);
    });
    // a press held on an agent (a row, a portrait) opens its menu as a sheet, as a right-click does. The hold is timed
    // here from the touch, because a phone's browser may send no contextmenu for it (Safari on an iPhone never does);
    // one that does is the same hold, and opens nothing twice.
    phHoldWire();
  }
  // the logo flashes, and opens the agent waiting longest, as the header's does
  const logo = ph.querySelector(".ph-logo"), waits = S.agents.filter(a => a.status === "waiting").sort((x, y) => (y.held || 0) - (x.held || 0));
  logo.classList.toggle("waiting", !!waits.length); logo.title = waits.length ? `Open ${shown(waits[0].name)}, waiting longest (${waits.length} waiting)` : "Claude agents";
  logo.onclick = waits.length ? () => openDetail(waits[0].name) : null;
  const t = phTeamState();
  patch(ph.querySelector(".ph-title"), `<b>${esc(S.project || document.title || "Team")}</b><span><span style="color:${t.colour}">●</span> ${t.word} · ${t.up} up${t.off ? ` · ${t.off} stopped` : ""}${S.nudgerPaused ? " · nudger paused" : ""}</span>`);
  // an uncoloured meter is green, as on the desktop bar: the plug-in owns its colour (it leaves green blank), so the
  // phone must not re-colour it by its own fill thresholds (owner, 2026-11-09: "amber on the phone but green on the desktop")
  const g = phGauge(), gb = ph.querySelector(".ph-week");
  if (g) {
    const m = g.meter, val = (g.parts || [{text: g.value, colour: g.colour}]).filter(x => x.text !== "").map(x => `<b style="color:${plugColour(x.colour || (g.parts ? "" : g.colour))}">${esc(x.text)}</b>`).join("");
    patch(gb, `<span class="gl">${phGaugeLabel(g)}</span>` + (m ? `<i><u style="width:${m.pct}%;background:${meterFill(m)}"></u>${m.mark == null ? "" : `<s style="left:calc(${m.mark}% - 1px)"></s>`}</i>` : "") + `<span class="gv">${val}</span>`);
    gb.setAttribute("aria-label", `${phGaugeName(g)}: ${g.value}${g.title ? ". " + g.title : ""}`); gb.title = g.title || "";
  } else {
    const wk = S.week;
    patch(gb, wk == null ? "–" : `<span class="gl"><span class="gico" role="img" aria-label="Week">${BAR_ICON.week}</span></span><i><u style="width:${Math.min(100, wk)}%;background:${gauge(wk)}"></u></i><span class="gv">${Math.round(wk)}%</span>`);
    gb.setAttribute("aria-label", wk == null ? "Week not read yet" : `Week used: ${Math.round(wk)}%`);
  }
  const nav = ph.querySelector(".ph-nav"), bar = phToolbar();
  if (nav.dataset.tabs !== bar.join()) {
    nav.dataset.tabs = bar.join(); nav.style.gridTemplateColumns = `repeat(${bar.length},minmax(0,1fr))`;
    nav.innerHTML = bar.map(k => `<button data-tab="${k}">${PH_ICON[k]}<span>${PH_TABS.find(([x]) => x === k)[1]}</span></button>`).join("");
  }
  ph.querySelectorAll(".ph-nav [data-tab]").forEach(b => { b.classList.toggle("on", b.dataset.tab === tab); b.setAttribute("aria-current", b.dataset.tab === tab ? "page" : "false"); });
  const body = ph.querySelector(".ph-body");
  body.dataset.tab = tab;
  if (tab !== "mix") delete body.dataset.html;
  if (tab === "list") patch(body, phListHtml());
  else if (tab === "faces") patch(body, phFacesHtml());
  else if (tab === "mix") {
    // the transcript is drawn again only when it changes, and stays at its newest turn unless scrolled up
    const html = combinedHtml("phone", phMixNode(), true, false);
    if (body.dataset.html !== html) {
      const f = body.querySelector(".feed"), end = !f || f.scrollHeight - f.scrollTop - f.clientHeight < 60, was = f?.scrollTop;
      body.innerHTML = `<div class="ph-pane">${html}</div>`; body.dataset.html = html;
      body.querySelectorAll(".maxbtn, .newest").forEach(b => b.remove());
      phMixFilters(body);
      const g = body.querySelector(".feed"); if (g) g.scrollTop = end ? g.scrollHeight : was;
    }
    phLoad(tab);
  }
  else if (tab === "queue") {
    patch(body, `<div class="ph-pane">${workQueueHtml(false)}</div>`);
    body.querySelectorAll(".maxbtn").forEach(b => b.remove());
    phLoad(tab);
  }
  else if (tab === "perf") { patch(body, `<div class="ph-pane ph-perf">${perfHtml({show: "machine", machine: "rows"})}</div>`); phLoad(tab); }
  else if (tab === "dash") { if (!phDashDrag) { patch(body, phDashHtml()); phDashWire(body); } }
  else { patch(body, `<div class="ph-pane">${dayLogHtml()}</div>`); phLoad(tab); }
  if (tab === "list" || tab === "faces") markSeen([]);
  // while the Dashboard is being arranged the rest of the phone is locked: the header and toolbar dimmed and deaf to taps
  // until the tick (owner, 2026-11-10: "some way to lock the rest of the screen while editing the dashboard")
  if (tab !== "dash") phDashEdit = false;
  ph.classList.toggle("dashedit", phDashEdit);
}
let phHeld = 0;
// A press held on an agent anywhere on the phone, by a finger or a mouse button (a row, a portrait, the agent view's strip of portraits, a name in
// Combined) opens its menu, as a sheet. Wired once, on the document.
const PH_HOLD = "#phone [data-menu-name], #drail .phf[data-name], #phone .teamlog .cnames .name[data-name]";
function phHoldWire() {
  if (phHoldWire.done) return; phHoldWire.done = true;
  const who = t => { const m = phoneOn() && t.closest?.(PH_HOLD), n = m && (m.dataset.menuName || m.dataset.name); return n && [...S.agents, ...S.bench].some(a => a.name === n) ? [m, n] : null; };   // a benched or stopped agent has its menu too
  const held = ([m, n]) => { if (Date.now() - phHeld < 800) return; phHeld = Date.now(); navigator.vibrate?.(10); agentMenu(m, n, false, false); };
  let hold = 0, at = null;
  document.addEventListener("touchstart", e => {
    clearTimeout(hold); const w = e.touches.length === 1 && who(e.target); if (!w) return;
    at = [e.touches[0].clientX, e.touches[0].clientY]; hold = setTimeout(() => held(w), 480);
  }, {passive: true});
  document.addEventListener("touchmove", e => { if (at && Math.hypot(e.touches[0].clientX - at[0], e.touches[0].clientY - at[1]) > 10) clearTimeout(hold); }, {passive: true});
  document.addEventListener("touchend", e => { clearTimeout(hold); if (Date.now() - phHeld < 800 && e.cancelable) e.preventDefault(); });   // the lift after a hold clicks nothing
  document.addEventListener("touchcancel", () => clearTimeout(hold));
  document.addEventListener("pointerdown", e => {
    if (e.pointerType !== "mouse" || e.button) return;
    clearTimeout(hold); const w = who(e.target); if (!w) return;
    at = [e.clientX, e.clientY]; hold = setTimeout(() => held(w), 480);
  });
  document.addEventListener("pointermove", e => { if (e.pointerType === "mouse" && at && Math.hypot(e.clientX - at[0], e.clientY - at[1]) > 10) clearTimeout(hold); });
  document.addEventListener("pointerup", e => { if (e.pointerType === "mouse") clearTimeout(hold); });
  document.addEventListener("contextmenu", e => { const w = who(e.target); if (!w) { if (phoneOn() && e.target.closest?.("#phone img, #drail img")) e.preventDefault(); return; } e.preventDefault(); e.stopPropagation(); clearTimeout(hold); held(w); }, true);
  // the click that ends a held mouse button goes nowhere: caught on the window, before the page's own handlers see it
  addEventListener("click", e => { if (Date.now() - phHeld < 800 && phoneOn() && !e.target.closest("#menu")) { e.preventDefault(); e.stopImmediatePropagation(); } }, true);
}
// The header's gauge: one of the bar's plug-ins (the same reading the desktop bar shows), chosen in the team menu and
// kept in this browser; until one is chosen, the day bar, else the week's (owner, 2026-11-08: "I want the day bar for now").
const phGauges = () => plugs().filter(x => !x.hidden && (x.meter || x.value) && x.value !== "…");
const phGaugeName = x => x.name || x.label || barName(x.key);
// The phone shows an item by its icon, as the desktop bar can, and by name only where it has none (owner, 2026-11-11:
// "we have icons for them they don't need to use up a load of space saying day bar and week bar").
const phGaugeLabel = x => { const i = BAR_ICON[x.icon] || ADD_ICON[x.key]; return i ? `<span class="gico" role="img" aria-label="${esc(phGaugeName(x))}">${i}</span>` : esc(phGaugeName(x)); };
function phGauge() {
  const all = phGauges(), want = localStorage.getItem("phonegauge");
  return all.find(x => x.key === want) || all.find(x => x.key === "daybar") || all.find(x => x.key === "weekbar") || all.find(x => x.key === "week") || null;
}
// The team menu: the team's state and its start and stop, the nudger, the theme, text size, and the desktop layout.
let phStopAsk = null;
function phoneMenu(again, slide) {
  let sh = $("#phsheet");
  if (!sh) { sh = document.createElement("div"); sh.id = "phsheet"; document.body.append(sh); sh.onclick = e => { if (e.target === sh) phoneMenuOff(); }; }
  if (phMenuAt === "toolbar") return phToolbarMenu(slide);
  const t = phTeamState(), lead = S.agents.find(a => a.name === S.lead);   // the first running of delivery lead, head of testing, head of operations, assistant
  const starting = S.starting.includes("team"), stopping = S.halting.includes("team"), down = t.word === "Stopped";
  const nudgeOn = nudgerTo != null ? !nudgerTo : !S.nudgerPaused;
  const light = document.documentElement.classList.contains("light"), fs = settings().fs || 100;
  sh.innerHTML = `<div class="sh" role="dialog" aria-label="Team menu"><span class="grab"></span>` +
    `<h2>TEAM</h2><div class="tstate"><i style="background:${t.colour}"></i><b>${t.word}</b><span style="color:var(--mute)">· ${t.up} up, ${t.off} stopped</span></div>` +
    `<div class="two">` +
      (down || starting ? `<button class="big go" data-go="start"${starting ? " disabled" : ""}>${MENU_ICON.start}${starting ? "Starting…" : "Start team"}</button>`
        : `<button class="big" data-go="open-lead"${lead?.live ? "" : " disabled"}>${MENU_ICON.open}Open lead</button>`) +   // whoever leads now (owner, 2026-11-09: "the button should just say open lead")
      (down || starting ? `<button class="big" disabled>${MENU_ICON.stop}Stopped</button>`
        : stopping ? `<button class="big warn" disabled>${MENU_ICON.stop}Stopping…</button>`
        : `<button class="big ${phStopAsk ? "sure" : "warn"}" data-go="stop"${lead?.live ? "" : " disabled"}>${MENU_ICON.stop}${phStopAsk ? "Tap to confirm" : "Stop team…"}</button>`) +
    `</div><div class="note">${down ? `Starts ${S.teamUp ? esc(S.teamUp.map(shown).join(", ")) : "everyone with a session on the roster"}.` : stopping ? "Waiting for everyone to reach a clean point." : `Stop asks ${esc(shown(lead?.name || "the lead"))} to wind everyone down at a clean point.`}</div>` +
    `<div class="rows">` +
      `<button class="r" data-go="nudge"><span>Nudge waiting agents<small>Reminds idle agents that have work waiting</small></span><i class="sw${nudgeOn ? " on" : ""}" role="switch" aria-checked="${nudgeOn}"></i></button>` +
      (phGauges().length ? `<label class="r" style="cursor:default"><span>Header gauge</span><select class="gsel">${phGauges().map(x => `<option value="${esc(x.key)}"${x.key === phGauge()?.key ? " selected" : ""}>${esc(phGaugeName(x))}</option>`).join("")}</select></label>` : "") +
      `<div class="r" style="cursor:default"><span>Order agents</span><div class="seg2" style="flex:none"><button data-go="by-state" class="${phOrder() === "state" ? "on" : ""}">Status</button><button data-go="by-role" class="${phOrder() === "role" ? "on" : ""}">Role</button></div></div>` +
      `<div class="r" style="cursor:default"><span>Theme</span><div class="seg2" style="flex:none"><button data-go="light" class="${light ? "on" : ""}">Light</button><button data-go="dark" class="${light ? "" : "on"}">Dark</button></div></div>` +
      `<button class="r" data-go="fs"><span>Text size</span><em>${fs}%</em></button>` +
      `<button class="r" data-go="toolbar"><span>Toolbar<small>${esc(phToolbar().map(phTabName).join(", "))}</small></span>${PH_ICON.chev}</button>` +
      `<button class="r" data-go="desk"><span>Desktop layout<small>The full page, as on a computer, in this browser</small></span>${PH_ICON.chev}</button>` +
    `</div></div>`;
  const panel = sh.querySelector(".sh");
  if (!sh.classList.contains("on")) { sh.classList.add("on"); panel.style.transform = "translateY(100%)"; requestAnimationFrame(() => requestAnimationFrame(() => { panel.style.transform = ""; })); }
  if (slide) panel.classList.add(slide);
  phSheetDrag(panel);
  sh.querySelector(".gsel")?.addEventListener("change", e => { localStorage.setItem("phonegauge", e.target.value); phoneDraw(); });
  sh.querySelectorAll("[data-go]").forEach(b => b.onclick = () => {
    const go = b.dataset.go;
    if (go === "start") { post("/api/team/start"); phoneMenuOff(); }
    else if (go === "open-lead") { phoneMenuOff(); openDetail(lead.name); }
    else if (go === "stop") {
      if (!phStopAsk) { phStopAsk = setTimeout(() => { phStopAsk = null; if ($("#phsheet")?.classList.contains("on")) phoneMenu(); }, 4000); return phoneMenu(); }
      clearTimeout(phStopAsk); phStopAsk = null; post("/api/team/stop"); phoneMenuOff();
    }
    else if (go === "nudge") { const pause = nudgeOn; nudgerTo = pause; setTimeout(() => { nudgerTo = null; }, 10000); post(pause ? "/api/nudger/pause" : "/api/nudger/resume"); phoneMenu(); }
    else if (go === "light" || go === "dark") { retheme(go); phoneMenu(); }
    else if (go === "by-state" || go === "by-role") { localStorage.setItem("phoneorder", go.slice(3)); phoneDraw(); phoneMenu(); }
    else if (go === "fs") { const steps = [90, 100, 115, 130], next = steps[(steps.indexOf(fs) + 1) % steps.length] || 100; const s = settings(); s.fs = next; localStorage.setItem("settings", JSON.stringify(s)); applySettings(); phoneMenu(); }
    else if (go === "toolbar") { phMenuAt = "toolbar"; phoneMenu(false, "slidein"); }
    else if (go === "desk") { localStorage.setItem("phone", "off"); phoneMenuOff(); phoneDraw(); draw(); }
  });
}
function phoneMenuOff() {
  clearTimeout(phStopAsk); phStopAsk = null; phMenuAt = "team";
  const sh = $("#phsheet"), panel = sh?.querySelector(".sh");
  if (!sh?.classList.contains("on")) return;
  if (!panel) return sh.classList.remove("on");
  panel.style.transform = "translateY(100%)"; sh.classList.add("closing");
  setTimeout(() => { sh.classList.remove("on", "closing"); panel.style.transform = ""; }, 220);
}
// The sheet follows a finger pulling it down, from its handle or from anywhere once its list is scrolled to the top,
// and closes if pulled far enough or flicked; otherwise it springs back (owner, 2026-11-08).
function phSheetDrag(panel, close = phoneMenuOff, back = null, when = () => true) {
  let y0 = null, t0 = 0, dy = 0, dragged = false;
  const dim = () => back || $("#phsheet");
  const start = (y, target) => { if (!when() || panel.scrollTop > 0 && !target.closest(".grab")) { y0 = null; return false; } y0 = y; t0 = Date.now(); dy = 0; dragged = false; panel.style.transition = "none"; return true; };
  const move = y => {
    if (y0 == null) return false;
    dy = Math.max(0, y - y0);
    if (dy > 0) { dragged = true; panel.style.transform = `translateY(${dy}px)`; dim().style.background = `rgba(0,0,0,${0.45 * Math.max(0, 1 - dy / panel.offsetHeight)})`; }
    return dy > 0;
  };
  const end = () => {
    if (y0 == null) return;
    y0 = null; panel.style.transition = ""; dim().style.background = "";
    const fast = dy > 30 && dy / Math.max(1, Date.now() - t0) > 0.5;
    if (dy > Math.min(140, panel.offsetHeight / 3) || fast) { close(); if (back) setTimeout(() => { panel.style.transform = ""; }, 50); } else panel.style.transform = "";
  };
  panel.ontouchstart = e => { if (e.touches.length !== 1) { y0 = null; return; } start(e.touches[0].clientY, e.target); };
  panel.ontouchmove = e => { if (move(e.touches[0].clientY)) e.preventDefault(); };
  panel.ontouchend = panel.ontouchcancel = end;
  let mouse = null;
  panel.classList.add("sheetdrag");
  panel.onpointerdown = e => { dragged = false; if (e.pointerType === "mouse" && !e.button && start(e.clientY, e.target)) mouse = e.pointerId; };
  panel.onpointermove = e => {
    if (e.pointerId !== mouse) return;
    if (!dragged && e.clientY - y0 < 6) return;
    if (!panel.hasPointerCapture(mouse)) panel.setPointerCapture(mouse);
    if (move(e.clientY)) panel.classList.add("grabbing");
  };
  panel.onpointerup = panel.onpointercancel = e => { if (e.pointerId !== mouse) return; mouse = null; panel.classList.remove("grabbing"); end(); setTimeout(() => { dragged = false; }); };   // after the click it ends with
  panel.addEventListener("click", e => { if (dragged) { dragged = false; e.preventDefault(); e.stopPropagation(); } }, true);
}
// A strip that scrolls sideways under a finger scrolls under a mouse too: dragged with its button held, or with the
// wheel. A drag clicks nothing it ends on.
const PH_STRIPS = "html.phone #drail, html.phone #detail .head .facts";
{
  let strip = null, x0 = 0, s0 = 0, dragged = false;
  document.addEventListener("pointerdown", e => {
    dragged = false;
    const el = e.pointerType === "mouse" && !e.button && e.target.closest?.(PH_STRIPS);
    if (!el || el.scrollWidth <= el.clientWidth) return;
    strip = el; x0 = e.clientX; s0 = el.scrollLeft; dragged = false;
  });
  document.addEventListener("pointermove", e => {
    if (!strip) return;
    const dx = e.clientX - x0;
    if (!dragged && Math.abs(dx) < 6) return;
    if (!dragged) { dragged = true; strip.classList.add("grabbing"); }
    strip.scrollLeft = s0 - dx;
  });
  const done = () => { strip?.classList.remove("grabbing"); strip = null; setTimeout(() => { dragged = false; }); };   // after the click it ends with
  document.addEventListener("pointerup", done);
  document.addEventListener("pointercancel", done);
  document.addEventListener("dragstart", e => { if (e.target.closest?.(PH_STRIPS)) e.preventDefault(); });   // a portrait's image is not dragged out
  document.addEventListener("click", e => { if (dragged) { dragged = false; e.preventDefault(); e.stopPropagation(); } }, true);
  document.addEventListener("wheel", e => {
    const el = e.target.closest?.(PH_STRIPS);
    if (!el || el.scrollWidth <= el.clientWidth || Math.abs(e.deltaX) >= Math.abs(e.deltaY)) return;
    e.preventDefault(); el.scrollLeft += e.deltaY;
  }, {passive: false});
}
// Phone layout, on a phone showing the desktop: a tap goes back; a drag moves it out of the way, and it stays where it
// was put in this browser (the owner, 2026-11-10: "It needs to be draggable, it's in my way and I can't move it").
{
  const pb = $("#phoneback"), KEY = "phoneback:at";
  let drag = null, moved = false;
  const place = (x, y) => {
    const w = pb.offsetWidth || 120, h = pb.offsetHeight || 40;
    x = Math.max(4, Math.min(innerWidth - w - 4, x)); y = Math.max(4, Math.min(innerHeight - h - 4, y));
    Object.assign(pb.style, {left: x + "px", top: y + "px", bottom: "auto"});
    return [x, y];
  };
  const restore = () => {
    let at = null;
    try { at = JSON.parse(localStorage.getItem(KEY) || "null"); } catch (e) {}
    if (Array.isArray(at) && at.length === 2 && pb.offsetWidth) place(at[0], at[1]);
  };
  pb.addEventListener("pointerdown", e => {
    const r = pb.getBoundingClientRect();
    drag = {id: e.pointerId, sx: e.clientX, sy: e.clientY, dx: e.clientX - r.left, dy: e.clientY - r.top}; moved = false;
    pb.setPointerCapture(e.pointerId);
  });
  pb.addEventListener("pointermove", e => {
    if (!drag || e.pointerId !== drag.id) return;
    if (!moved && Math.hypot(e.clientX - drag.sx, e.clientY - drag.sy) < 8) return;
    moved = true; pb.classList.add("moving");
    place(e.clientX - drag.dx, e.clientY - drag.dy);
  });
  const end = e => {
    if (!drag || e.pointerId !== drag.id) return;
    drag = null; pb.classList.remove("moving");
    if (moved) { const r = pb.getBoundingClientRect(); try { localStorage.setItem(KEY, JSON.stringify([Math.round(r.left), Math.round(r.top)])); } catch (e) {} }
  };
  pb.addEventListener("pointerup", end); pb.addEventListener("pointercancel", end);
  pb.onclick = e => {
    if (moved) { moved = false; e.preventDefault(); return; }   // the end of a drag is not a tap
    localStorage.removeItem("phone"); phoneDraw();
  };
  new MutationObserver(restore).observe(document.documentElement, {attributes: true, attributeFilter: ["class"]});
  addEventListener("resize", restore);
  restore();
}
PHONE_MQ.addEventListener("change", () => { phoneDraw(); draw(); });
{
  // On the phone the desktop page is hidden and not drawn: its panes measure nothing there, and a pane that redraws
  // until its size settles would never settle. Should the phone's own drawing fail, the desktop page shows instead
  // of a blank screen, and the console says why.
  const _draw = draw;
  draw = function () {
    if (!phoneOn() || !S) _draw();
    try { phoneDraw(); } catch (e) { phError(e); }
  };
}
// Anything that goes wrong on the phone is shown on it, over the page, with what it was and where: a phone has no
// console to read (owner, 2026-11-08: "white header, with ... that does nothing"). Desktop layout is a way out.
function phError(e) {
  console.error("agents-web phone layout failed", e);
  if (!PHONE_MQ.matches || ONLY) return;
  let box = $("#pherr");
  if (!box) { box = document.createElement("div"); box.id = "pherr"; document.body.append(box); }
  const what = (e && (e.stack || e.message)) || String(e), ua = navigator.userAgent;
  box.innerHTML = `<b>The phone layout hit an error</b><pre>${esc(String(what).split("\n").slice(0, 8).join("\n"))}</pre><pre>${esc(ua)}</pre>` +
    `<div><button data-go="desk">Use desktop layout</button><button data-go="x">Dismiss</button></div>`;
  box.querySelector('[data-go="desk"]').onclick = () => { localStorage.setItem("phone", "off"); box.remove(); location.reload(); };
  box.querySelector('[data-go="x"]').onclick = () => box.remove();
}
addEventListener("error", e => { if (document.documentElement.classList.contains("phone")) phError(e.error || e.message + " at " + e.filename + ":" + e.lineno + ":" + e.colno); });
// A request the network dropped (the phone asleep, or between Wi-Fi and mobile) is not a layout fault, and the next poll
// asks again (owner, 2026-11-09: "Failed to fetch at refreshDetail" over the page): Chrome says "Failed to fetch", Safari
// "Load failed", Firefox "NetworkError…", and an aborted one is an AbortError.
const netDrop = r => r && (r.name === "AbortError" || r.name === "TypeError" && /failed to fetch|load failed|networkerror|network connection was lost/i.test(r.message || ""));
addEventListener("unhandledrejection", e => { if (document.documentElement.classList.contains("phone") && !netDrop(e.reason)) phError(e.reason); });
// The agent view on the phone: a back arrow, the others as portraits, a suggestion to tap. Back on the phone (its
// gesture or button) closes the view rather than leaving the page.
function phRail() {
  const order = a => a.status === "waiting" ? 0 : a.status === "busy" || a.compacting ? 1 : 2;
  const all = phOrder() === "role" ? phByRole().flatMap(([, l]) => l).filter(a => a.live) : [...S.agents.filter(a => a.live)].sort((x, y) => order(x) - order(y));
  // favourites first (owner, 2026-11-09: "can this row put favourites first")
  const favs = phFavs(), list = [...favs.map(n => all.find(a => a.name === n)).filter(Boolean), ...all.filter(a => !favs.includes(a.name))];
  patchByName($("#drail"), list.map(a => { const n = a.name === open ? 0 : unseen(a);
    return `<button class="phf ${stOf(a)}${a.name === open ? " cur" : ""}" style="--c:${a.colour}" data-name="${esc(a.name)}" aria-label="${esc(shown(a.name))}, ${STATE[stOf(a)] || ""}">` +
      // the badge is always there, hidden at none: a badge coming or going would change the button's children, and the
      // redraw would rebuild its image, blank on the phone until it loads again (owner, 2026-11-09: a green frame with no face)
      `<span>${a.portrait ? `<img src="${esc(a.portrait)}" alt="">` : shadow(a)}</span><i></i>${n ? unseenBadge(n) : `<span class="unseen" hidden></span>`}</button>`; }).join(""));
  $("#drail").onclick = e => { const b = e.target.closest(".phf"); if (b && b.dataset.name !== open) openDetail(b.dataset.name); };
  markSeen([open]);
}
function phDetail() {
  if (!phoneOn() || !open || !S) { const g = $("#dsug"); if (g) g.hidden = true; return; }
  const x = $("#dhead .x");
  if (x && !x.querySelector("svg")) { x.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M15 6l-6 6 6 6"/></svg>`; x.title = "Back"; x.setAttribute("role", "button"); x.setAttribute("aria-label", "Back to the team"); x.onclick = phBack; }
  const a = S.agents.find(y => y.name === open) || {}, g = $("#dsug"), box = $("#dsay");
  const sug = a.live && a.status === "idle" && a.suggest && settings().suggest !== "off" && !box.value ? a.suggest : "";
  g.hidden = !sug; if (sug && g.dataset.s !== sug) { g.dataset.s = sug; g.textContent = "Suggested: " + sug; }
}
$("#dsug").onclick = () => { const box = $("#dsay"), s = $("#dsug").dataset.s; if (!s) return; box.value = s; box.dispatchEvent(new Event("input", {bubbles: true})); grow(box); $("#dsug").hidden = true; box.focus(); };
function phBack() { if (history.state?.ph) history.back(); else closeDetail(); }
addEventListener("popstate", () => { if (open && phoneOn() && !history.state?.ph) closeDetail(); });
{
  const _open = openDetail, _rail = rail, _facts = facts, _hint = sayHint;
  openDetail = function (name) {
    if (phoneOn() && !history.state?.ph) history.pushState({ph: 1}, "", "#" + encodeURIComponent(name));
    const r = _open(name);
    if (phoneOn() && history.state?.ph) history.replaceState({ph: 1}, "", "#" + encodeURIComponent(name));
    phDetail(); return r;
  };
  rail = function () { if (phoneOn() && open && S) phRail(); else _rail(); };
  facts = function () { _facts(); phDetail(); };
  // on the phone the box's hint is short, and has no Tab: a suggestion is a button over it instead
  sayHint = a => !phoneOn() ? _hint(a) : openAsk(a) ? "Answer the question above" : a.status === "waiting" ? "This answers the prompt in its pane" : a.name?.startsWith(MEET) ? _hint(a) : `Message ${shown(a.name)}…`;
}
{
  // the phone has no docked view (a Tabs page docks it on the desktop): one open there is closed when the phone takes over
  const _dock = dock, _close = closeDetail;
  dock = function (a) {
    if (!phoneOn()) return _dock(a);
    const d = $("#detail");
    if (d.classList.contains("docked")) { d.classList.remove("docked"); d.style.inset = ""; open = null; d.classList.remove("open"); }
  };
  closeDetail = function () { if (phoneOn() && history.state?.ph) history.back(); else _close(); };
}
// A poll is skipped while the last one is still out, so a slow server is not sent more work than it can answer.
const once = f => { let out = false; return () => { if (out) return; out = true; Promise.resolve(f()).catch(() => {}).finally(() => { out = false; }); }; };
setInterval(once(load), 4000); setInterval(once(() => refreshDetail(false)), 2500);
</script>
</body>
</html>
"""


def self_test():
    """Fixtures in a throwaway directory: a roster, Claude Code records held by live stand-in processes, context rows,
    a claims board, a transcript, a stand-in tmux and budget. Nothing live is read, and nothing is typed anywhere."""
    import sys
    g, fails, kids = globals(), [], []

    def t(what, got, want):
        print(("ok   " if got == want else "FAIL ") + what + ("" if got == want else f"\n     got {got!r}, want {want!r}"))
        if got != want:
            fails.append(what)

    T = tempfile.mkdtemp()
    try:
        for d in ("sessions", "projects/p", "context", "dash", "bin", "socks"):
            os.makedirs(os.path.join(T, d))
        g.update(HOME=T, PROJECT="proj", SESSIONS=T + "/sessions", PROJECTS=T + "/projects", CONTEXT_DIR=T + "/context",
                 CACHE=T + "/dash", BURN=T + "/dash/burn.json", BOARD=T + "/dash/board", LEDGER=T + "/no-ledger",
                 ROSTER=T + "/roster.json", BUDGET=T + "/bin/budget", DAY_BUDGET=T + "/bin/day", PASTED=T + "/pasted", STATE_DIR=T + "/state",
                 TEAM_UP=T + "/state/team-up", STOPPED=T + "/state/stopped", COMPACT_ON_START=T + "/state/compact-on-start", TEAM_START_LOG=T + "/state/team-start.log",
                 TEAM_START_SH=T + "/bin/team-start", TEAM_PAUSED_SH=T + "/bin/team-paused", SHIPPED_BAR=T + "/shipped")
        with open(T + "/roster.json", "w") as f:
            json.dump({"agents": [
                {"name": "Lea", "email": "lea@proj.local", "role": "delivery-lead", "status": "active"},
                {"name": "Ada", "email": "ada@proj.local", "role": "developer", "status": "active"},
                {"name": "Ben", "email": "ben@proj.local", "role": "developer", "status": "active"},
                {"name": "Old", "email": "old@proj.local", "role": "developer", "status": "retired"},
                {"name": "Tess", "email": "tess@proj.local", "role": "tester", "status": "active"}],
                "assistants": [{"name": "Max", "email": "max@proj.local"}]}, f)
        t("roster: active agents in file order, then the assistants",
          [(r["name"], r["role"]) for r in roster()],
          [("Lea", "delivery-lead"), ("Ada", "developer"), ("Ben", "developer"), ("Tess", "tester"), ("Max", "assistant")])
        t("full names: none set, each agent shows its name", [r["fullName"] for r in roster()], ["Lea", "Ada", "Ben", "Tess", "Max"])
        g["FULL_NAMES"] = os.path.join(T, "full-names.json")
        for bad in ('{"Ada": ', '["Ada"]', '{"Ada": "", "Ben": 7, "Lea": "  "}'):
            with open(FULL_NAMES, "w") as f:
                f.write(bad)
            t(f"full names: {bad} leaves the short names", [r["fullName"] for r in roster()], ["Lea", "Ada", "Ben", "Tess", "Max"])
        t("shown names: none set, the state carries none", shown_names(), {})
        g["SHOWN_NAMES"] = os.path.join(T, "shown-names.json")
        for bad in ('{"Ada": ', '["Ada"]', '{"Ada": "", "Ben": 7, "Lea": "  "}'):
            with open(SHOWN_NAMES, "w") as f:
                f.write(bad)
            t(f"shown names: {bad} leaves the roster's spelling", shown_names(), {})
        with open(SHOWN_NAMES, "w", encoding="utf-8") as f:
            json.dump({"Ada": "A’da"}, f, ensure_ascii=False)
        t("shown names: a listed name reads as written", shown_names(), {"Ada": "A’da"})
        for words, want in (("ask Ada's review", "ask A’da's review"),
                            ("Ada, then Ada.", "A’da, then A’da."),
                            ("cd /home/me/Ada and ~/Ada", "cd /home/me/Ada and ~/Ada"),
                            ("see https://x.test/Ada now", "see https://x.test/Ada now"),
                            ("strength-Ada Ada-x --to=Ada Ada@box Adam", "strength-Ada Ada-x --to=Ada Ada@box Adam")):
            t(f"screen: {words!r}", spelled_screen(words, shown_names()), want)
        t("screen: a coloured name is spelled, its colour kept", ansi_html("\x1b[1mAda\x1b[0m said", shown_names()),
          '<span style="font-weight:600">A’da</span> said')
        t("screen: no names, as written", ansi_html("Ada said"), "Ada said")
        with open(FULL_NAMES, "w", encoding="utf-8") as f:
            json.dump({"Ada": "Ada O’Tucker", "Max": "Captain Max", "Nobody": "Not On The Roster"}, f, ensure_ascii=False)
        t("full names: an agent or assistant listed shows it, the rest their name, and a stray name adds nobody",
          [(r["name"], r["fullName"]) for r in roster()],
          [("Lea", "Lea"), ("Ada", "Ada O’Tucker"), ("Ben", "Ben"), ("Tess", "Tess"), ("Max", "Captain Max")])
        t("grouped: by role in the panel's order, file order within a role, an unknown role before the assistant",
          [r["name"] for r in grouped([{"name": n, "role": ro} for n, ro in [
              ("Max", "assistant"), ("Tess", "tester"), ("Rex", "code-reviewer"), ("Zed", "developer"), ("Pip", "ops"),
              ("Vi", "head-of-testing"), ("Ada", "developer"), ("Lea", "delivery-lead"), ("Ann", "tester")]])],
          ["Lea", "Zed", "Ada", "Tess", "Ann", "Rex", "Vi", "Pip", "Max"])

        # A session is its process's GIT_AUTHOR_EMAIL's agent; without one, the record's name.
        env = {k: v for k, v in os.environ.items() if k != "GIT_AUTHOR_EMAIL"}
        for i, (name, email) in enumerate([("someone-else", "ada@proj.local"), ("lea", ""), ("Stranger", ""), ("Ben", "")]):
            kid = subprocess.Popen(["sleep", "600"], env=dict(env, **({"GIT_AUTHOR_EMAIL": email} if email else {})))
            kids.append(kid)
            sock = f"{T}/socks/{i}"
            open(sock, "w").close()
            with open(f"{T}/sessions/{kid.pid}.json", "w") as f:
                # Ben's record is older than the process holding its pid: a crashed session's, its pid reused
                json.dump({"name": name, "sessionId": f"s{i}", "status": ["busy", "idle", "idle", "idle"][i], "cwd": T,
                           "messagingSocketPath": sock, "statusUpdatedAt": int(time.time() * 1000),
                           "startedAt": int((time.time() - (7200 if name == "Ben" else 0)) * 1000)}, f)
        time.sleep(0.2)
        t("live sessions: by the address in the process's environment, else by the record's name; a stranger is no one,"
          " and a record older than the process on its pid is no one's", sorted(live_sessions()), ["Ada", "Lea"])
        # Claude Code started for the session is its own even when its start, counted from boot, reads as after the
        # record's (a clock set after boot); another conversation's Claude on that pid is not.
        with open(T + "/bin/claude", "w") as f:
            f.write("#!/usr/bin/env bash\nsleep 60\n")
        os.chmod(T + "/bin/claude", 0o755)
        for i, (args, want) in enumerate([(["--resume", "s7"], ["Ada", "Lea", "Tess"]), (["--name", "Tess"], ["Ada", "Lea", "Tess"]),
                                          (["--resume", "s8"], ["Ada", "Lea"])]):
            kid = subprocess.Popen(["bash", T + "/bin/claude"] + args, env=dict(env, GIT_AUTHOR_EMAIL="tess@proj.local"),
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            sock = f"{T}/socks/t{i}"
            open(sock, "w").close()
            with open(f"{T}/sessions/{kid.pid}.json", "w") as f:
                json.dump({"name": "Tess", "sessionId": "s7", "status": "idle", "cwd": T, "messagingSocketPath": sock,
                           "statusUpdatedAt": int(time.time() * 1000), "startedAt": int((time.time() - 7200) * 1000)}, f)
            time.sleep(0.2)
            t(f"  claude {' '.join(args)}: " + ("its own session, whatever its start reads" if "Tess" in want else "not the session's"),
              sorted(live_sessions()), want)
            kid.kill()
            kid.wait()
            os.remove(f"{T}/sessions/{kid.pid}.json")
        # an agent's meeting session is live under its meeting name; a stranger's is no one's
        for i, said in enumerate(["Ada · meeting", "Stranger · meeting"]):
            kid = subprocess.Popen(["sleep", "60"], env=env)
            kids.append(kid)
            sock = f"{T}/socks/m{i}"
            open(sock, "w").close()
            with open(f"{T}/sessions/{kid.pid}.json", "w") as f:
                json.dump({"name": said, "sessionId": f"m{i}", "status": "idle", "cwd": T, "messagingSocketPath": sock,
                           "statusUpdatedAt": int(time.time() * 1000), "startedAt": int(time.time() * 1000)}, f)
        time.sleep(0.2)
        t("live sessions: an agent's meeting session by its meeting name, a stranger's not at all",
          sorted(live_sessions()), ["Ada", "Ada · meeting", "Lea"])

        with open(T + "/dash/board", "w") as f:
            f.write("feat_x|backend|Ada\nfeat_y|docs|Ada\nfeat_z|docs|-\nfeat_w|ci|Tess  <= DEPARTED\n")
        t("claims: the first ticket each agent holds, unclaimed rows skipped", claims(), {"ada": "feat_x", "tess": "feat_w"})

        os.environ.update(AGENT_WEEK_PCT_PER_HOUR="2", AGENT_WORK_HOURS="08:00-17:00", AGENT_WORK_DAYS="Mon Tue Wed Thu Fri")
        t("even plan: 2 an hour for 45 hours leaves 10% in hand, so 36% planned shares out as 40%", even_plan(36), 40.0)
        os.environ["AGENT_WEEK_PCT_PER_HOUR"] = "3"
        t("  and a week planned past 100% has no contingency", even_plan(36), None)

        t("colour: the role's own", colour("developer"), xterm(110))
        os.environ["AGENT_COLOUR_DEVELOPER"] = "pink"
        t("  or AGENT_COLOUR_<ROLE>", colour("developer"), xterm(175))
        os.environ["AGENT_COLOUR_DEVELOPER"] = ""
        t("  and blank for none", colour("developer"), "#8b949e")
        del os.environ["AGENT_COLOUR_DEVELOPER"]

        with open(T + "/bin/tmux", "w") as f:
            f.write(f"#!/usr/bin/env bash\n[ \"$1\" = load-buffer ] && {{ cat > {T}/loaded; exit 0; }}\n"
                    "[ \"$1\" = list-panes ] && printf '%s\\n' "
                    "'proj-ada\t%1\t✳ Ada\tnode\t120\t40' 'Work-3\t%2\t✳ Lea\tclaude\t100\t30' 'Work\t%2\t✳ Lea\tclaude\t100\t30' 'other\t%3\t✳ Nobody\tclaude\t80\t24' 'meet-1-Ada\t%4\t✳ Ada · meeting\tclaude\t200\t50'\n")
        with open(T + "/bin/budget", "w") as f:
            f.write("#!/usr/bin/env bash\necho 'budget  over: week 38% used of 36% planned so far'\n")
        os.chmod(T + "/bin/tmux", 0o755)
        os.chmod(T + "/bin/budget", 0o755)
        with open(T + "/bin/day", "w") as f:
            f.write("#!/usr/bin/env bash\necho 'day  none: no day open'; exit 3\n")
        os.chmod(T + "/bin/day", 0o644)   # as the script is: run with bash, not by its mode
        os.environ["PATH"] = T + "/bin:" + os.environ["PATH"]
        t("panes: the agent's own tmux session, or a claude pane titled with its name, and its meeting session's pane",
          {n: p["pane"] for n, p in panes().items()}, {"Ada": "%1", "Lea": "%2", "Ada · meeting": "%4"})

        lines = [{"type": "user", "timestamp": "2026-10-27T10:00:00Z", "message": {"content": "please look at the build"}},
                 {"type": "assistant", "timestamp": "2026-10-27T10:00:05Z", "message": {"content": [
                     {"type": "text", "text": "On it."}, {"type": "tool_use", "name": "Bash", "input": {"command": "ls"}}]}},
                 {"type": "user", "timestamp": "2026-10-27T10:01:00Z", "message": {"content": "<system-reminder>x</system-reminder>"}},
                 {"type": "queue-operation", "operation": "enqueue", "content": "and the tests", "timestamp": "2026-10-27T10:02:00Z"}]
        with open(T + "/projects/p/s0.jsonl", "w") as f:
            f.write("\n".join(json.dumps(x) for x in lines) + "\n")
        t("feed: the owner's words, the agent's, its tools folded, Claude Code's own text left out, then what is queued",
          [(it["kind"], it["lane"]) for it in feed("s0", 50)],
          [("owner", "owner"), ("said", "owner"), ("tools", "auto"), ("pending", "owner")])
        t("  a message from another session is the team's",
          user_items('<cross-session-message from-name="Lea">hello</cross-session-message>')[0]["kind"], "peer")
        os.environ["AGENT_OWNER_NAME"] = "Pat"
        t("  a shell command the owner ran with ! is the owner's",
          user_items("<bash-input>git status</bash-input>"), [{"kind": "owner", "who": "Pat", "text": "`! git status`"}])
        t("  and what it printed follows it, in the owner's lane",
          [(i["kind"], i["text"], LANE[i["kind"]]) for i in user_items("<bash-stdout>clean\n</bash-stdout><bash-stderr>warn\n</bash-stderr>")],
          [("shell", "```\nclean\nwarn\n```", "owner")])
        t("  or says it printed nothing", user_items("<bash-stdout></bash-stdout><bash-stderr></bash-stderr>")[0]["text"], "no output")

        # Lea's conversation (s1) holds messages from Ada, from Old (retired, still on the roster) and from a helper.
        team_lines = [{"type": "user", "timestamp": f"2026-10-27T11:0{i}:00Z", "message": {"content":
                       f'<cross-session-message from-name="{who}">note {i}</cross-session-message>'}}
                      for i, who in enumerate(["Ada", "Explore", "Old"])]
        with open(T + "/projects/p/s1.jsonl", "w") as f:
            f.write("\n".join(json.dumps(x) for x in team_lines) + "\n")
        t("team: every message between agents, from its recipient's conversation, oldest first; a helper's is left out",
          [(m["from"], m["to"], m["text"]) for m in json.loads(team_json())], [("Ada", "Lea", "note 0"), ("Old", "Lea", "note 2")])

        os.environ.update(AGENT_OWNER_NAME="Pat", AGENT_WEEK_PCT_PER_HOUR="2")
        st = state()
        t("state: sections as byobu has them, then by role for an agent in its own spawn session", st["tabs"], ["Work", "Developers"])
        t("  each running agent in its section (its pane's session, not a byobu client's), with its ticket",
          [(a["name"], a["tab"], a["ticket"], a["status"]) for a in st["agents"]],
          [("Lea", "Work", "", "idle"), ("Ada", "Developers", "feat_x", "busy")])
        t("  developers and testers with no session are on the bench, and so is a stopped standing agent",
          [(b["name"], b["standing"]) for b in st["bench"]], [("Ben", False), ("Tess", False), ("Max", True)])
        t("full names: reach the page, on a running agent and on the bench",
          ([a["fullName"] for a in st["agents"] if a["name"] == "Ada"], [b["fullName"] for b in st["bench"]]),
          (["Ada O’Tucker"], ["Ben", "Tess", "Captain Max"]))
        t("  the week's plan and the plan shared out evenly", (st["plan"], st["even"]), (36, 40.0))
        t("  and no day, while none is open", st["day"], None)
        for line, want in (("day  on: 11% of the day's 15% used (week 69%, from 58% at 06:05)", {"used": 11, "quota": 15, "from": 58}),
                           ("day  over: 16% of the day's 15% used (week 74%, from 58% at 06:05): write your durable record and pause",
                            {"used": 16, "quota": 15, "from": 58}),
                           ("day  on: 6% of the day's 5% used (week 80%, from 74% at 09:00): verification day, nothing stops at it",
                            {"used": 6, "quota": 5, "from": 74, "nostop": True}),
                           ("day  none: between days since 20:44: 3% of the plan's 5% used (week 77%, from 74%)", {"used": 3, "quota": 5, "from": 74}),
                           ("day  none: between days since 20:44: 3% used (week 77%, from 74%)", {"used": 3, "quota": None, "from": 74}),
                           ("day  none: no day open", None),
                           ("day  cannot tell: no week reading (team/lib/week-usage.sh)", None)):
            with open(T + "/bin/day", "w") as f:
                f.write(f"#!/usr/bin/env bash\necho {shlex.quote(line)}\n")
            t(f"  the day as {line.split(':')[0][5:]!r} says it", day_budget(), want)
        t("  the owner's name from AGENT_OWNER_NAME", st["owner"], "Pat")

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        g["PORT"] = server.server_address[1]
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{PORT}"

        def code(path, method="GET", headers=None, body=None):
            try:
                with urllib.request.urlopen(urllib.request.Request(base + path, data=body, method=method, headers=headers or {})) as r:
                    return r.status, r.read()
            except urllib.error.HTTPError as e:
                return e.code, b""
        status, page = code("/")
        t("the page is served", (status, page[:15]), (200, b"<!doctype html>"))
        # the day log: the page runs a program and keeps what it prints to the documented shape
        g["DAY_LOG_PROGRAM"] = T + "/bin/no-day-log"
        d = json.loads(code("/api/daylog")[1])
        t("day log: no program says so, and where it looked", (d["state"], d["program"], d["rows"]), ("unset", T + "/bin/no-day-log", []))
        with open(SHOWN_NAMES, encoding="utf-8") as f:
            spell = next(iter(json.load(f).items()))
        prog = T + "/bin/day-log"
        def day_prog(body):
            with open(prog, "w") as f:
                f.write("#!/bin/sh\n" + body)
            os.chmod(prog, 0o755)
            refresh_day_log(prog)
        g["DAY_LOG_PROGRAM"] = prog
        odd = f"{spell[0][0]}’{spell[0][1:].upper()}"    # signed as "O’Brian" for OBrian: other punctuation and case
        out = {"summary": "1 day, 2 entries", "note": "a note", "empty": "nothing", "kinds": {"released": {"name": "Released", "about": "Out.", "x": 1}, "bad": 3},
               "rows": [{"at": 300, "type": "entry", "kind": "released", "by": spell[1], "text": f"by {spell[0]}", "url": "https://x/1", "label": "#1"},
                        {"at": 200, "type": "entry", "kind": "fix<b>", "by": odd, "text": "a bad link", "url": "javascript:alert(1)"},
                        {"at": 100, "type": "day", "kind": "development", "by": "Lea", "text": "x" * 400},
                        {"at": "soon", "type": "entry"}, {"at": True, "type": "day"}, {"at": 1, "type": "other"}, "not a row"]}
        day_prog("cat <<'EOF'\n" + json.dumps(out) + "\nEOF\n")
        d = json.loads(code("/api/daylog")[1])
        t("day log: a program's rows, the bad ones left out", [(r["at"], r["type"]) for r in d["rows"]], [(300, "entry"), (200, "entry"), (100, "day")])
        t("  a name comes back as the roster's, and one in the words is spelled as the page spells it",
          (d["rows"][0]["by"], d["rows"][0]["text"]), (spell[0], f"by {spell[1]}"))
        t(f"  a name signed {odd!r} is the roster's {spell[0]!r} too", d["rows"][1]["by"], spell[0])
        t("  only an http(s) link is kept, a kind is a plain word, and text is cut short",
          (d["rows"][0]["url"], d["rows"][1]["url"], d["rows"][1]["kind"], len(d["rows"][2]["text"])), ("https://x/1", "", "fixb", 300))
        t("  its words and kinds pass through", (d["state"], d["summary"], d["note"], d["empty"], d["kinds"]),
          ("ok", "1 day, 2 entries", "a note", "nothing", {"released": {"name": "Released", "about": "Out."}}))
        day_prog("echo 'GitHub could not be read just now' >&2; exit 1\n")
        d = json.loads(code("/api/daylog")[1])
        t("day log: a failed program says why, and the log it last printed stays", (d["state"], d["error"], len(d["rows"])),
          ("failed", "GitHub could not be read just now", 3))
        day_prog("echo not json\n")
        t("  as does one that prints no JSON", json.loads(code("/api/daylog")[1])["error"], "printed something that is not JSON")
        day_prog("echo '{\"rows\": []}'\n")
        t("  and the next good one clears it", [json.loads(code("/api/daylog")[1])[k] for k in ("state", "error", "rows")], ["ok", "", []])
        with open(prog, "w") as f:
            f.write("#!/bin/sh\nsleep 0.3; echo '{\"rows\": [{\"at\": 5, \"type\": \"day\", \"text\": \"Monday\"}]}'\n")
        _daylog.update(at=0, busy=False, data=None, error="", thread=None)
        d = json.loads(code("/api/daylog")[1])
        t("day log: the first request waits for the first reading, so a quick program is shown at once", (d["state"], len(d["rows"])), ("ok", 1))
        t("  and a day with no kind is drawn as its name alone",
          ': `<div class="row day"><span class="tx">${esc(r.text)}</span></div>`)' in PAGE, True)
        t("  the phone's Day log asks again soon while the first reading is still coming",
          'Date.now() - phDayAt > (dayLog?.state === "reading" ? 3000 : 30000)' in PAGE, True)
        g["DAY_LOG_PROGRAM"] = os.path.join(ROOT, "team", "day-log.py")
        _daylog.update(at=0, busy=False, data=None, error="", thread=None)
        t("  and the pane is offered", ('daylog: "Day log"' in PAGE, "body = dayLogHtml(n)" in PAGE), (True, True))
        # the harness's own program: its two logs and a stand-in gh, with the clock's window taken from now
        stamp = lambda ago: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - ago))
        ep = lambda ago: int(time.time() - ago)
        ds = T + "/daystate"
        os.makedirs(ds)
        os.makedirs(T + "/ghbin")
        with open(T + "/ghbin/gh", "w") as f:
            f.write(f"#!/bin/sh\ncat {T}/gh.json\n")
        os.chmod(T + "/ghbin/gh", 0o755)
        def harness_log(prs, repo="o/r"):
            with open(T + "/gh.json", "w") as f:
                f.write(prs if isinstance(prs, str) else json.dumps(prs))
            env = {**os.environ, "DAY_LOG_STATE_DIR": ds, "PATH": T + "/ghbin:" + os.environ["PATH"], "AGENTS_PR_REPO": repo}
            p = subprocess.run([os.path.join(ROOT, "team", "day-log.py")], input='{"days": 7}', capture_output=True, text=True, env=env, timeout=30)
            return p.returncode, (json.loads(p.stdout) if p.returncode == 0 else p.stderr.strip())
        t("harness day log: nothing started is no rows", harness_log([])[1]["rows"], [])
        with open(ds + "/dev-day.log", "w") as f:
            f.write(f"{stamp(9 * 86400)}\tdevelopment\tgate=0\tOld\n{stamp(8 * 86400)}\tverification\tgate=0\tOld\n{stamp(3600)}\tverification\tgate=0\tAda\n"
                    f"not a line\nbad\tdevelopment\tgate=0\tAda\n{stamp(1800)}\tdevelopment\tgate=0\tAda\n")
        with open(ds + "/agents-day-budget.log", "w") as f:
            f.write(f"{ep(9 * 86400)} start 1 20\n{ep(8 * 86400)} end 5 0\n{ep(1800) + 2} start 23 15\n")
        prs = [{"number": 1, "title": "Too old", "mergedAt": stamp(8.5 * 86400 + 86400), "url": "https://x/1"},
               {"number": 2, "title": "Under verification — Ada", "mergedAt": stamp(2700), "url": "https://x/2"},
               {"number": 3, "title": "fix_a_long_ticket_name: what it did", "mergedAt": stamp(600), "url": "https://x/3"},
               {"number": 4, "title": "no merge time", "url": "https://x/4"}]
        rc, d = harness_log(prs)
        rows = d["rows"]
        t("harness day log: newest first, each PR under the day it merged in, a bad line left out, the window opening at a start",
          [r["label"] if r["type"] == "entry" else r["kind"] for r in rows], ["#3", "development", "#2", "verification", "verification"])
        t("  the development day's share, and none on a verification day that opened no share",
          (rows[1]["text"], rows[3]["text"]), ("Started development day, 15%", "Started verification day"))
        t("  a PR's link, its words without its ticket's name, and its kind", (rows[0]["url"], rows[0]["text"], rows[0]["kind"]), ("https://x/3", "what it did", "fix"))
        t("  a PR's maker off the end of its title, and who started a day", (rows[2]["by"], rows[2]["text"], rows[1]["by"]), ("Ada", "Under verification", "Ada"))
        t("  its header's words", d["summary"], "3 days started, 2 PRs merged")
        with open(ds + "/agents-day-budget.log", "w") as f:
            f.write(f"{ep(3600) - 1} end 20 0\n{ep(3600) - 1} start 20 5\n{ep(1800) + 2} start 23 15\n")
        t("  a verification day that opened a share shows it", harness_log(prs)[1]["rows"][3]["text"], "Started verification day, 5%")
        t("harness day log: GitHub unread fails, saying why", harness_log(""), (1, "GitHub could not be read just now"))
        rc, d = harness_log([{"number": n, "title": "t", "mergedAt": stamp(60), "url": "u"} for n in range(500)])
        t("harness day log: a full read says it may be cut", d["note"], "Showing the newest PRs only: there are more in this window than the page reads.")
        rc, d = harness_log(prs, repo="")
        t("harness day log: no repository set still shows the days, and says so", (d["note"], [r["type"] for r in d["rows"]]),
          ("PRs are not shown: AGENTS_PR_REPO is not set.", ["day"] * 3))
        import importlib.util
        spec = importlib.util.spec_from_file_location("day_log", os.path.join(ROOT, "team", "day-log.py"))
        dl = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dl)
        for whole, shown in [("fix_a_long_ticket_name: what it did (pt3) — James", "what it did (pt3) — James"), ("ci: a colon but no ticket", "ci: a colon but no ticket"),
                             ("fix_only_a_ticket_name", "fix_only_a_ticket_name"), ("fix_a_name: ", "fix_a_name: "), ("Why: fix_a_name: stays", "Why: fix_a_name: stays")]:
            t(f"  a title without its ticket's name: {whole!r}", dl.short_title(whole), shown)
        for whole, parts in [("what it did — James", ("what it did", "James")), ("no name here", ("no name here", "")), ("a — b and more", ("a — b and more", "")), ("two — dashes — Ada", ("two — dashes", "Ada"))]:
            t(f"  a title's name: {whole!r}", dl.title_name(whole), parts)
        t("  a title with no ticket name has no kind", [dl.title_kind(x) for x in ("ci: a colon", "fix_only_a_name", "fix_a_name: ", "feat_a_b: c")], ["", "", "", "feat"])
        # the work queue: team/work-queue.py keeps Now, Next and Later, and /api/workqueue serves them to the Work queue pane
        from concurrent.futures import ThreadPoolExecutor
        wqf = T + "/wq/work-queue.json"
        def wq(*args, who="Lead", env=None):
            return subprocess.run([os.path.join(ROOT, "team", "work-queue.py"), *args], capture_output=True, text=True, timeout=30,
                                  env={**os.environ, "AGENT_WORK_QUEUE": wqf, "AGENT_NAME": who, **(env or {})})
        def wq_keys():
            with open(wqf) as f:
                q = json.load(f)
            return [i["key"] for i in q["now"]], [i["key"] for i in q["next"]], [i["key"] for i in q.get("later", [])]
        t("work queue: add puts an item at the end of Next, or Now with --now",
          [wq("add", "feat_one", "One", "--now", "--who", "Lea").returncode, wq("add", "AB-2", "Two").returncode,
           wq("add", "AB-3", "Three", "--note", "after AB-2", "--url", "https://x/3").returncode, wq_keys()],
          [0, 0, 0, (["feat_one"], ["AB-2", "AB-3"], [])])
        with open(wqf) as f:
            q = json.load(f)
        t("  with its title, who, note and link, and who changed it last", (q["now"][0], q["next"][1]["url"], q["by"]),
          ({"key": "feat_one", "title": "One", "who": "Lea", "note": "", "url": ""}, "https://x/3", "Lead"))
        t("  an item already there is refused", wq("add", "AB-2", "again").returncode, 1)
        t("  an id with a space or a leading dash is refused", (wq("add", "not an id", "x").returncode, wq("add", "-x", "x").returncode), (1, 1))
        # A ledger's ids run past 100 characters (strength's, 2026-11-10: three live ones), so up to 255 is an id; past it, not.
        long_id = "fix_" + "a_long_ledger_slug_" * 10   # 194 characters
        t("  a 194-character ledger id is taken; a 256-character one is refused",
          [wq("add", long_id, "Long").returncode, wq("add", "x" * 256, "Too long").returncode, wq("drop", long_id).returncode], [0, 1, 0])
        wq("up", "AB-3")
        t("  up moves an item one place within its list", wq_keys(), (["feat_one"], ["AB-3", "AB-2"], []))
        wq("up", "AB-3")
        t("  and not past the top", wq_keys(), (["feat_one"], ["AB-3", "AB-2"], []))
        wq("move", "AB-2", "now")
        t("  move takes it to the end of the other list", wq_keys(), (["feat_one", "AB-2"], ["AB-3"], []))
        wq("add", "AB-4", "Four", "--later")
        wq("move", "AB-3", "later")
        t("  --later and move ... later put it in Later, after what is there", wq_keys(), (["feat_one", "AB-2"], [], ["AB-4", "AB-3"]))
        wq("add", "AB-5", "Five", "--parked")
        wq("move", "AB-3", "parked")
        with open(wqf) as f:
            t("  --parked and move ... parked put it in Parked, after what is there", [i["key"] for i in json.load(f)["parked"]], ["AB-5", "AB-3"])
        wq("move", "AB-3", "later")
        wq("drop", "AB-5")
        wq("move", "AB-4", "next")
        wq("edit", "feat_one", "--who", "", "--title", "One again")
        with open(wqf) as f:
            t("  edit changes its words, and an empty value clears who", json.load(f)["now"][0],
              {"key": "feat_one", "title": "One again", "who": "", "note": "", "url": ""})
        os.makedirs(T + "/wqconf/sessions")
        with open(T + "/wqconf/sessions/9.json", "w") as f:
            json.dump({"sessionId": "s-1", "name": "Lead2"}, f)
        wq("edit", "AB-2", "--note", "", who="", env={"CLAUDE_CONFIG_DIR": T + "/wqconf", "CLAUDE_CODE_SESSION_ID": "s-1"})
        with open(wqf) as f:
            t("  with no AGENT_NAME, who changed it is the Claude session's name", json.load(f)["by"], "Lead2")
        t("  drop takes it out", (wq("drop", "AB-3").returncode, wq("drop", "AB-4").returncode, wq_keys()), (0, 0, (["feat_one", "AB-2"], [], [])))
        t("  an id not in the queue says so", wq("drop", "AB-9").stderr.strip(), "work-queue: AB-9 is not in the queue")
        wq("add", "AB-7", "Seven", "--parked")
        wq("done", "AB-7", "--note", "live")
        with open(wqf) as f:
            q = json.load(f)
        t("  done moves an item to Done, with its note and when", ([i["key"] for i in q["parked"]], q["done"][0]["note"], isinstance(q["done"][0].get("done"), int)),
          ([], "live", True))
        wq("move", "AB-7", "later")
        with open(wqf) as f:
            t("  and moving it out of Done takes the stamp off", "done" in json.load(f)["later"][-1], False)
        wq("drop", "AB-7")
        wq("add", "AB-8", "Eight", "--done")
        with open(wqf) as f:
            q = json.load(f)
        t("  --done adds straight to Done, stamped", [(i["key"], "done" in i) for i in q["done"]], [("AB-8", True)])
        q["done"][0]["done"] -= 15 * 86400
        with open(wqf, "w") as f:
            json.dump(q, f)
        wq("add", "AB-9", "Nine", "--done")
        with open(wqf) as f:
            t("  Done keeps fourteen days: an older one goes at the next change", [i["key"] for i in json.load(f)["done"]], ["AB-9"])
        wq("drop", "AB-9")
        with ThreadPoolExecutor(8) as pool:
            list(pool.map(lambda n: wq("add", f"CD-{n}", f"t{n}"), range(16)))
        t("  sixteen agents adding at once all land", sorted(wq_keys()[1]), sorted(f"CD-{n}" for n in range(16)))
        keep_wq, keep_su = g["WORK_QUEUE"], g["STANDUPS"]
        g["WORK_QUEUE"], g["STANDUPS"] = wqf, T + "/wq/standups.md"
        try:
            t("work queue pane: with no stand-up log there are no stand-ups, and Done is one list", g["standup_times"](), [])
            with open(T + "/wq/standups.md", "w") as f:
                f.write("# Stand-ups\n\n# Stand-up, Wednesday 11 November 2026 (DRAFT)\n\n# Stand-up, Tuesday 10 November 2026 (FINAL, 09:10Z)\n"
                        "\n# Stand-up, Monday 9 November 2026 (FINAL)\n\n# Stand-up, Friday 6 November 2026\n")
            t("  the stand-ups are the log's FINAL days, newest first, 09:15Z where no time is given",
              json.loads(code("/api/workqueue")[1])["standups"], [1794301800, 1794215700])
            wq("add", "AB-10", "Ten", "--done")
            d = json.loads(code("/api/workqueue")[1])
            t("  Done is served with when each got there", ([i["key"] for i in d["done"]], d["done"][0]["done"] > 0, d["now"][0]["done"]), (["AB-10"], True, 0))
            wq("drop", "AB-10")
            wq("add", long_id, "Long")
            t("  a 194-character ledger id is served whole", [i["key"] for i in json.loads(code("/api/workqueue")[1])["next"]].count(long_id), 1)
            wq("drop", long_id)
            wq("edit", "AB-2", "--url", "https://x/2")
            d = json.loads(code("/api/workqueue")[1])
            wq("move", "CD-0", "later")
            d = json.loads(code("/api/workqueue")[1])
            t("work queue pane: Now, Next and Later in order, an item linked only where it gives an http(s) link",
              (d["state"], [i["key"] for i in d["now"]], [i["url"] for i in d["now"]], len(d["next"]), [i["key"] for i in d["later"]]),
              ("ok", ["feat_one", "AB-2"], ["", "https://x/2"], 15, ["CD-0"]))
            with open(wqf, "w") as f:
                json.dump({"now": [{"key": "<b>", "title": "x"}, {"key": "AB-5", "title": "t" * 500, "who": 3, "url": "javascript:x"}, "junk"], "next": "no"}, f)
            d = json.loads(code("/api/workqueue")[1])
            t("  a bad item is left out, words are cut short, and a link that is not http(s) is dropped",
              ([i["key"] for i in d["now"]], len(d["now"][0]["title"]), d["now"][0]["who"], d["now"][0]["url"], d["next"], d["later"]), (["AB-5"], 200, "", "", [], []))
            with open(wqf, "w") as f:
                f.write("not json")
            t("  a file that is not a queue says so", json.loads(code("/api/workqueue")[1])["state"], "bad")
            t("  and so does the command, changing nothing", (wq("add", "AB-6", "x").returncode, open(wqf).read()), (1, "not json"))
            os.remove(wqf)
            t("  no file is an empty queue", json.loads(code("/api/workqueue")[1])["state"], "empty")
        finally:
            g["WORK_QUEUE"], g["STANDUPS"] = keep_wq, keep_su
        t("  the pane is offered, Doing (Now, Next, Later and Parked) and Done tabs, one line an item, and a phone panel too",
          ('workqueue: "Work queue"' in PAGE, "body = workQueueHtml(path === maxed, n)" in PAGE and '[["Now", q.now], ["Next", q.next], ["Later", q.later], ["Parked", q.parked]]' in PAGE
           and '[["work", "Doing"], ["done", "Done"]]' in PAGE, ".workq .tx{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}" in PAGE,
           '["queue", "Work queue"]' in PAGE), (True, True, True, True))
        t("  it can be maximised, and draws titles and notes as Markdown",
          ('"file", "workqueue"].includes(maxNode.show)' in PAGE, 'data-name="~workqueue"' in PAGE, "${inline(i.title)}" in PAGE and "${inline(i.note)}" in PAGE), (True, True, True))
        t("the logo flashes while an agent waits, and a click opens the one waiting longest",
          ('brand.classList.toggle("waiting", !!waiting)' in PAGE, "brand.onclick = waiting ? () => openDetail(longest) : null" in PAGE,
           ".brand.waiting{cursor:pointer" in PAGE), (True, True, True))
        t("at 700px or narrower the page is the phone layout, and Desktop layout turns it off in this browser",
          ('const PHONE_MQ = matchMedia("(max-width:700px)")' in PAGE, 'localStorage.getItem("phone") !== "off"' in PAGE,
           'html.phone body > header,html.phone body > main,html.phone body > footer{display:none !important}' in PAGE,
           '<div id="phone"><div class="ph-loading">Loading…</div></div><button id="phoneback">Phone layout</button>' in PAGE), (True, True, True, True))
        t("  its logo flashes and opens the agent waiting longest, as the header's does",
          "logo.onclick = waits.length ? () => openDetail(waits[0].name) : null" in PAGE, True)
        t("  Stop team asks for a second tap, and a phone error is shown on the phone with a way out",
          ('phStopAsk ? "Tap to confirm" : "Stop team…"' in PAGE, 'box.querySelector(\'[data-go="desk"]\').onclick' in PAGE), (True, True))
        t("  its panels are Agents, Portraits, Combined, the Day log, the Work queue, Performance and the Dashboard",
          'const PH_TABS = [["list", "Agents"], ["faces", "Portraits"], ["mix", "Combined"], ["day", "Day log"], ["queue", "Work queue"], ["perf", "Performance"], ["dash", "Dashboard"]]' in PAGE, True)
        t("  its toolbar is up to five of them, chosen and ordered by dragging in the ⋯ menu's Toolbar, kept in this browser",
          ('localStorage.setItem("phonetabs", JSON.stringify(next))' in PAGE, 'data-go="toolbar"' in PAGE, 'class="tbgrip"' in PAGE,
           "nav.innerHTML = bar.map(k =>" in PAGE), (True, True, True, True))
        t("  the Dashboard holds the bar's readings, the Agents count, the Bench, the Favourites and the Active, half or wide, dragged by grip in Edit",
          ('const PH_DASH_OWN = ["tally", "bench", "favs", "active"]' in PAGE, 'localStorage.setItem("phonedash"' in PAGE, 'data-dash="wide:${i}"' in PAGE,
           'class="dgrip"' in PAGE, "#phone.dashedit .ph-top,#phone.dashedit .ph-nav{display:none}" in PAGE, 'class="dbtn dtune dclose"' in PAGE), (True,) * 6)
        t("  a meter is the same colour on the bar, the phone's gauge and the Dashboard",
          ("background:${meterFill(m)}" in PAGE, 'const meterFill = m => m.colour ? plugColour(m.colour) : "linear-gradient(90deg,#2ea043,#3fb950)"' in PAGE), (True, True))
        t("the header can show the Favourites, as the Bench, and the desktop agent menu adds and removes one",
          ('bench: "Bench", favs: "Favourites"' in PAGE, "phFavToggle" in PAGE), (True, True))
        t("  Combined has its own Roles and lanes, behind one ⋯ in its header, kept in this browser",
          ('data-menu="phmix"' in PAGE, 'menuAt(btn, "phmix", `<div class="hd"><div>Roles</div></div>`' in PAGE, 'localStorage.setItem("phonemix"' in PAGE), (True, True, True))
        t("  its agents are by role unless Status is chosen, favourites first on Agents and Portraits, each group by name",
          ('const phOrder = () => localStorage.getItem("phoneorder") === "state" ? "state" : "role";' in PAGE,
           'const fav = favs.length ? `<section class="ph-favs"><h2>${MENU_ICON.star}Favourites</h2><div class="ph-grid">' in PAGE,
           'all.filter(a => a.role === r.role).sort(byName)' in PAGE, '.sort((x, y) => x.localeCompare(y, undefined, {sensitivity: "base"}))' in PAGE),
          (True, True, True, True))
        t("  a mouse drags a sheet down, drags and wheels a strip sideways, and a held button opens an agent's menu",
          ('panel.classList.add("sheetdrag");' in PAGE, 'const PH_STRIPS = "html.phone #drail, html.phone #detail .head .facts";' in PAGE,
           'e.preventDefault(); el.scrollLeft += e.deltaY;' in PAGE, 'if (e.pointerType !== "mouse" || e.button) return;' in PAGE,
           "html.phone .sheetdrag{cursor:grab}" in PAGE), (True, True, True, True, True))
        t("  resting the mouse opens no menu there, and Open in an agent's menu opens its view",
          ("if (wait > 0 && (touched || phoneOn())) return;" in PAGE, "if (menuOn(btn.dataset.menu) || touched || phoneOn()) return;" in PAGE,
           "(open || phoneOn() ? openDetail : x => menuGo(x, anchor))" in PAGE), (True, True, True))
        t("a message's badges open its first line and its later lines run the full width beneath them",
          ('const inline = !!heads && it.kind !== "live";' in PAGE, '${inline ? `<span class="heads">${heads}</span>` : ""}' in PAGE,
           ".it .tx > .heads{float:left;height:1lh;" in PAGE), (True, True, True))
        t("  every menu is a sheet from the bottom over a dimmed page, which a tap closes",
          ("html.phone #menu.on{left:0 !important;right:0;top:auto !important;bottom:0" in PAGE, 'back.onclick = e => { e.stopPropagation(); if (Date.now() - phHeld > 800) menuOff(true); };' in PAGE), (True, True))
        t("  each entry starts with who did it (the releaser a release names, else System), its time and its kind's icon; a day's ends with its icon",
          ('${dayLogWho(dayLogBy(r))}<span class="at">${dayLogTime(r.at)}</span>${dayLogIcon(r.kind, "e" + r.at + ":" + i)}' in PAGE, '${dayLogIcon(r.kind, "d" + r.at)}</div>' in PAGE,
           'r.text?.match(/^Released by ([A-Z][\\w-]*)/)?.[1] || "System"' in PAGE), (True, True, True))
        t("  and the pane heads it with its summary, its tab naming it", '<div class="thead"><span class="tsum">${esc(sum)}</span></div>' in PAGE, True)
        t("the bars stay out of sight until placed, and are placed before the first state",
          ('html:not(.barsplaced) :is(header,footer){display:none}' in PAGE, -1 < PAGE.find('try { placeBar(); }') < PAGE.find('load().then(() => { if (location.hash')), (True, True))
        t("  and its state", sorted(json.loads(code("/api/state")[1])), ["agents", "bench", "compacting", "day", "disk", "even", "halting", "lead", "now", "nudgerPaused", "owner", "plan", "plugins", "project", "session", "shownNames", "starting", "tabs", "teamPaused", "teamUp", "week"])
        t("  and the team's transcript", [m["from"] for m in json.loads(code("/api/team")[1])], ["Ada", "Old"])
        say = {"Content-Type": "application/json"}
        t("a message without the page's header is refused", code("/api/agent/Ada/say", "POST", say, b'{"text":"hi"}')[0], 403)
        t("  and one from another site", code("/api/agent/Ada/say", "POST", dict(say, **{"X-Team-Say": "1", "Origin": "http://evil.example"}), b'{"text":"hi"}')[0], 403)
        t("  and one with nothing in it", code("/api/agent/Ada/say", "POST", dict(say, **{"X-Team-Say": "1"}), b'{"text":"  "}')[0], 400)
        # the public name, behind Access: a key of the test's own stands in for the team's
        def sign(claims, key="key"):
            enc = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()
            head = enc({"alg": "RS256", "kid": "k1"}) + "." + enc(claims)
            sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", f"{T}/{key}.pem"], input=head.encode(), capture_output=True).stdout
            return head + "." + base64.urlsafe_b64encode(sig).rstrip(b"=").decode()
        for k in ("key", "other"):
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", f"{T}/{k}.pem", "-out", f"{T}/{k}.crt",
                            "-days", "1", "-subj", "/CN=t"], capture_output=True, check=True)
        fetched = []
        g.update(access_certs=lambda: fetched.append(1) or {"k1": open(f"{T}/key.crt").read()})
        good = {"aud": ["aud1"], "iss": "https://tm.cloudflareaccess.com", "exp": time.time() + 600}
        pub = lambda tok=None, **h: dict({"Host": "team.example"}, **({"Cf-Access-Jwt-Assertion": tok} if tok else {}), **h)
        t("the public name is refused while it is not set", code("/api/state", headers=pub(sign(good)))[0], 403)
        t("  and so is any other name", (code("/", headers={"Host": "rebound.example"})[0], code("/api/state", headers={"Host": "rebound.example"})[0]), (403, 403))
        g.update(PUBLIC_HOST="team.example", ACCESS_TEAM="tm", ACCESS_AUD="aud1")
        t("the public name without Access's token is refused", code("/api/state", headers=pub())[0], 403)
        t("  and with its token, served", code("/api/state", headers=pub(sign(good)))[0], 200)
        t("  and the token checked once, its certificates fetched once", (code("/", headers=pub(sign(good)))[0], len(fetched)), (200, 1))
        t("  but one signed with another key is refused", code("/api/state", headers=pub(sign(good, "other")))[0], 403)
        t("  and one for another application", code("/api/state", headers=pub(sign(dict(good, aud=["aud2"]))))[0], 403)
        t("  and one from another team", code("/api/state", headers=pub(sign(dict(good, iss="https://x.cloudflareaccess.com"))))[0], 403)
        t("  and one expired", code("/api/state", headers=pub(sign(dict(good, exp=time.time() - 5))))[0], 403)
        t("  and a message from another site, even signed in", code("/api/agent/Ada/say", "POST", dict(say, **pub(sign(good), **{"X-Team-Say": "1", "Origin": "https://evil.example"})), b'{"text":"  "}')[0], 403)
        t("  but one from the page under that name goes on to be read", code("/api/agent/Ada/say", "POST", dict(say, **pub(sign(good), **{"X-Team-Say": "1", "Origin": "https://team.example"})), b'{"text":"  "}')[0], 400)
        g.update(ACCESS_AUD="")
        t("  and with no application named, even a good token is refused", code("/api/state", headers=pub(sign(good)))[0], 403)
        g.update(PUBLIC_HOST="", ACCESS_TEAM="", access_certs=access_certs)
        long_text = "line of a long paste\n" * 20000
        code("/api/agent/Ada/say", "POST", dict(say, **{"X-Team-Say": "1"}), json.dumps({"text": long_text}).encode())
        t("a long paste (400 KB) reaches the pane whole", os.path.getsize(T + "/loaded") if os.path.exists(T + "/loaded") else 0, len(long_text.strip()) + 1)
        t("  and one over the limit is refused as too long", code("/api/agent/Ada/say", "POST", dict(say, **{"X-Team-Say": "1"}), b" " * (SAY_MAX_BYTES + 1))[0], 413)
        t("a stop for an agent that is not working is refused", code("/api/agent/Lea/stop", "POST", {"X-Team-Say": "1"}, b"")[0], 409)
        with open(T + "/bin/team-start", "w") as f:
            f.write(f'echo "$*" >> {T}/started\n')
        os.makedirs(T + "/state", exist_ok=True)
        with open(T + "/state/team-up", "w") as f:
            f.write("Ada\nGone\nMax\n")
        t("the next start brings back those recorded who are still on the roster, and the lead", team_up(), ["Lea", "Ada"])
        t("  and leaves out an assistant, here on the roster and in the record", "Max" in [r["name"] for r in roster()], True)
        os.rename(T + "/state/team-up", T + "/state/team-up.keep")
        with open(STOPPED, "w") as f:
            f.write("Ben\n")
        t("with an agent stopped on its own, the start is the rest of the team and no assistant", "Max" in team_up(), False)
        with open(STOPPED, "w") as f:
            f.write("Max\n")
        t("  and an assistant stopped on its own does not make the start a partial one", team_up(), None)
        os.remove(STOPPED)
        os.rename(T + "/state/team-up.keep", T + "/state/team-up")
        t("with nobody running the delivery lead leads, whom a start brings up", lead_name(set()), "Lea")
        g, keep_roster = globals(), roster
        g["roster"] = lambda: keep_roster() + [{"name": "Vi", "role": "head-of-testing", "status": "active"},
                                               {"name": "Ops", "role": "head-of-operations", "status": "active"}]
        t("  and while running, the delivery lead before everyone", lead_name({"Lea", "Vi", "Ops", "Max"}), "Lea")
        t("  then the head of testing", lead_name({"Vi", "Ops", "Max", "Ada"}), "Vi")
        t("  then the head of operations", lead_name({"Ops", "Max", "Ada"}), "Ops")
        t("  then the assistant", lead_name({"Max", "Ada"}), "Max")
        t("  and a developer never leads", lead_name({"Ada"}), "Lea")
        g["roster"] = keep_roster
        t("a team start without the page's header is refused", code("/api/team/start", "POST", {}, b"")[0], 403)
        t("a team start is taken", code("/api/team/start", "POST", {"X-Team-Say": "1"}, b"")[0], 202)
        wait_for(lambda: os.path.exists(T + "/started"), 15, 0.2)
        t("  and runs team-start.sh for those recorded", open(T + "/started").read().strip() if os.path.exists(T + "/started") else "", "--only Lea --only Ada")
        t("  and uses the record up", wait_for(lambda: not os.path.exists(T + "/state/team-up"), 5, 0.2), True)
        t("  and finishes", wait_for(lambda: "team" not in _starting, 30, 0.2), True)   # its finally would clear what the next check reads
        keep = {k: g[k] for k in ("start_team", "type_into", "live_sessions", "compact_when_up", "team_paused")}
        ran = []
        g.update(start_team=lambda lead, names: None)
        code("/api/team/start", "POST", {"X-Team-Say": "1"}, b"")
        t("a whole-team start shows the team as starting, and no assistant", [n in state()["starting"] for n in ("Ada", "Max")], [True, False])
        _starting.clear()
        g.update(start_team=keep["start_team"], compact_when_up=lambda n: ran.append(n) or True, type_into=lambda *a: True)
        start_team("Lea", None)
        t("  and waits on the team coming up, not on an assistant", ["Ada" in ran, "Max" in ran], [True, False])
        g.update(live_sessions=lambda: {"Lea": {"status": "idle"}, "Max": {"status": "idle"}})
        code("/api/team/stop", "POST", {"X-Team-Say": "1"}, b"")
        t("a team stop records the team's running agents, and no assistant", names_in(TEAM_UP), {"Lea"})
        t("  and marks no assistant to compact", sorted(os.listdir(COMPACT_ON_START)), ["Lea"])
        os.remove(TEAM_UP); os.remove(os.path.join(COMPACT_ON_START, "Lea"))
        g.update(team_paused=lambda: True, live_sessions=lambda: {"Max": {"status": "busy"}})
        state()
        t("a busy assistant does not hold a wound-down team on stopping", "team" in _halting, False)
        _halting.add("team")
        g.update(live_sessions=lambda: {"Ada": {"status": "busy"}})
        state()
        t("  and a busy agent on the team does", "team" in _halting, True)
        _halting.discard("team"); _team_stop["at"] = 0
        g.update(keep)
        t("a developer is not started from the page", code("/api/agent/Ada/start", "POST", {"X-Team-Say": "1"}, b"")[0], 409)
        os.remove(T + "/started")
        t("a stopped standing agent is started from the page", code("/api/agent/Max/start", "POST", {"X-Team-Say": "1"}, b"")[0], 202)
        wait_for(lambda: os.path.exists(T + "/started"), 15, 0.2)
        t("  by team-start.sh --only", open(T + "/started").read().strip() if os.path.exists(T + "/started") else "", "--only Max")
        t("the head of testing is a standing agent", "hot" in STANDING, True)
        t("the head of operations is a standing agent", "ops" in STANDING and role_of("head-of-operations")[0] == "ops", True)
        t("  and so is production support, its role until the roster renames it", "support" in STANDING, True)
        t("the lead is stopped on its own", code("/api/agent/Lea/halt", "POST", {"X-Team-Say": "1"}, b"")[0], 202)
        t("  asked to finish and stop", "stopping you from the team page" in open(T + "/loaded").read(), True)
        t("an image from outside the home directory is not served", code("/img?p=/etc/passwd")[0], 404)
        up = lambda h, body=b"PK\x03\x04": json.loads(code("/api/paste", "POST", dict(h, **{"X-Team-Say": "1"}), body)[1] or b"{}")
        z = up({"Content-Type": "application/zip", "X-File-Name": "my%20logs%20(2).zip"})
        t("a picked zip is kept by its own name, as a file and not an image",
          (os.path.basename(z.get("path", "")).split("_", 3)[-1], z.get("name"), z.get("image"), os.path.dirname(z.get("path", ""))),
          ("my-logs-2-.zip", "my-logs-2-.zip", False, T + "/pasted"))
        t("  a pasted image with no name gets its type's extension",
          (os.path.splitext(up({"Content-Type": "image/png"}).get("path", ""))[1], up({"Content-Type": "image/png", "X-File-Name": "shot"}).get("name")), (".png", "shot.png"))
        t("  a file with neither a name nor an image type is refused",
          code("/api/paste", "POST", {"Content-Type": "application/octet-stream", "X-Team-Say": "1"}, b"x")[0], 400)
        t("  and a name cannot climb out of the folder", os.path.dirname(up({"Content-Type": "", "X-File-Name": "..%2F..%2Fevil.sh"}).get("path", "")), T + "/pasted")
        with open(T + "/edit.md", "wb") as f:
            f.write(b"one\r\ntwo\r\n")
        v0 = hashlib.sha256(b"one\r\ntwo\r\n").hexdigest()
        doc_save = lambda version: code("/api/doc", "POST", {"Content-Type": "application/json", "X-Team-Say": "1"},
                                        json.dumps({"p": T + "/edit.md", "text": "one\nthree\n", "version": version}).encode())[0]
        first, again = doc_save(v0), doc_save(v0)
        with open(T + "/edit.md", "rb") as f:
            saved = f.read()
        t("a File pane's edit is saved over the version it began from, keeping the line endings; a stale version is refused",
          (first, saved, again), (200, b"one\r\nthree\r\n", 409))
        os.makedirs(T + "/browse/sub")
        for f in ("a.md", ".hidden.md", "b.json"):
            open(T + "/browse/" + f, "w").close()
        got = code("/dir?p=" + urllib.parse.quote(T + "/browse"))
        t("a File pane's path box lists a home folder's folders first, then the documents the pane shows; nothing outside home",
          (json.loads(got[1] or b"[]"), code("/dir?p=/etc")[0]),
          ([{"name": "sub", "dir": True}, {"name": ".hidden.md", "dir": False}, {"name": "a.md", "dir": False}], 404))
        server.shutdown()
        # a question with previews, as the pane draws it: the preview of the option under the cursor beside the options
        shot = ("─" * 60 + "\n ☐ Test\n\nWhich footer?\n\n❯ 1. Footer empty        ┌──────────────────┐\n"
                "    (Recommended)        │ header: everything │\n  2. Bench in footer     │ footer: empty      │\n"
                "                         └──────────────────┘\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n")
        was_run, g["run"] = g["run"], lambda *cmd, **kw: shot if cmd[:2] == ("tmux", "capture-pane") else was_run(*cmd, **kw)
        try:
            ask = ask_of("%1")
        finally:
            g["run"] = was_run
        t("a question with previews keeps the preview out of its options' labels, and says it has them",
          ([o["label"] for o in ask["options"]], ask.get("preview")), (["Footer empty", "Bench in footer"], True))
        # a question whose last option sits below a rule of its own, as Claude Code draws "Chat about this"
        shot = (" ☐ Migration\n\n│ Who applies it?\n\n❯ 1. You apply it (Recommended)\n     It stays with you.\n  2. Deacon applies it\n"
                "  3. Type something.\n" + "─" * 60 + "\n  4. Chat about this\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n" + "─" * 60 + "\n")
        g["run"] = lambda *cmd, **kw: shot if cmd[:2] == ("tmux", "capture-pane") else was_run(*cmd, **kw)
        try:
            ask = ask_of("%1")
        finally:
            g["run"] = was_run
        t("a rule above \"Chat about this\" splits the options and does not hide the question: all four are read, and its text",
          (ask and [o["label"] for o in ask["options"]], ask and "Who applies it?" in ask["text"]),
          (["You apply it (Recommended)", "Deacon applies it", "Type something.", "Chat about this"], True))
        # an unnumbered prompt under a numbered list from the conversation: only the prompt's own options are read
        shot = ("  1. Apple\n  2. Pear\n\n" + "─" * 60 + "\n Accessing workspace:\n\n /tmp/probe\n\n"
                " ❯ No, exit\n   Yes, I trust this folder\n\n Enter to confirm · Esc to cancel\n")
        g["run"] = lambda *cmd, **kw: shot if cmd[:2] == ("tmux", "capture-pane") else was_run(*cmd, **kw)
        try:
            ask = ask_of("%1")
        finally:
            g["run"] = was_run
        t("a transcript line that is not text (a crash's NULs, bytes that are not UTF-8) is skipped, not fatal",
          turns([b"\x00\x00\x00", b"\xff\xfe{", "not json"], 5), [])
        t("a Gauges pane draws the Performance figures as half-circle gauges, and idle network interfaces are hidden",
          ('gauges: "Gauges"' in PAGE, "function dial(name, detail, pct" in PAGE, 'd.net?.length ? "no traffic" : "no interface"' in PAGE), (True, True, True))
        t("one scale for type, weight and corner radius: six sizes, two weights and four radii on :root",
          ("--t-xs:10px; --t-s:11px; --t-m:12px; --t-l:13px; --t-xl:17px; --t-xxl:20px;" in PAGE, "--r-xs:2px; --r-s:5px; --r-m:9px; --r-l:14px;" in PAGE),
          (True, True))
        t("  the header's stats one height with meters one thickness, its buttons one height, and bench portraits square",
          (".pspark{width:190px;height:14px;" in PAGE, "#lock{height:var(--ctl);" in PAGE, ".face::after{" in PAGE), (True, True, True))
        t("a Custom theme beside Dark and Light, its editor colouring the page, each gauge, each role and each agent; the pill names the theme showing",
          ('const THEMES = ["dark", "light", "custom"]' in PAGE, "function themeMenu(redraw)" in PAGE, 'c.agents[a.name] || c.roles[a.role] || a.roleColour' in PAGE,
           '$("#theme").textContent = THEME_NAME[t]' in PAGE), (True, True, True, True))
        t("  a File pane has an Edit button, Save (Ctrl+S) and Close (Esc)", ("function fileAct(what, p)" in PAGE, 'data-fe="save"' in PAGE), (True, True))
        t("a Characters pane shows the whole team, benched agents greyed, and a File pane has a header and maximises",
          ('[...S.agents, ...S.bench].filter(a => a.role === r).sort(byName)' in PAGE, '.chr.bench{' in PAGE,
           '["team", "combined", "meeting", "file", "workqueue"].includes(maxNode.show)' in PAGE, 'class="teamlog filelog"' in PAGE), (True, True, True, True))
        t("  a poll is not sent while the last one is out, and one state build runs at a time",
          ("setInterval(once(load), 4000)" in PAGE, isinstance(_state_build, type(threading.Lock()))), (True, True))
        t("  a prompt's options answer the keyboard as in the terminal: arrows move the highlight, Enter or a digit chooses",
          ('if (plainArrow(e)) n = ns[' in PAGE, '.it.ask .opt.at{' in PAGE, '["Prompts", [' in PAGE), (True, True, True))
        t("  an unnumbered prompt's options are its cursor row and the rows lined up with it, not a list above its rule",
          ([o["label"] for o in ask["options"]], ask.get("select"), ask.get("cursor")), (["No, exit", "Yes, I trust this folder"], True, 1))
        # the pane's footer under its input box, for a List row's status: its own words, less auto mode and the hint
        box = "─" * 60 + "\n❯ \n" + "─" * 60 + "\n"
        foot = lambda screen: (g.__setitem__("run", lambda *cmd, **kw: screen if cmd[:2] == ("tmux", "capture-pane") else was_run(*cmd, **kw)), pane_footer("%1"))[1]
        try:
            feet = (foot(box + "  ⏵⏵ auto mode on · 1 shell (shift+tab to cycle)                       ◉ high\n"), foot(box + "  ? for shortcuts\n"),
                    foot("no box here\n"))
        finally:
            g["run"] = was_run
        t("a pane's footer is its own words, less auto mode, the hint and what sits at its right; none without an input box",
          feet, ("1 shell", "? for shortcuts", None))
        t("  the status block under the message box is gone from cards and the open view: the List row keeps the footer",
          (bool(re.search(r"\bpstat", PAGE)), "pstattog" in PAGE, "statusOff" in PAGE, "a.live && a.pfoot" in PAGE), (False, False, False, True))
        # the bar's plug-ins: a script's line, a script's JSON, a failing script, and a file that is not executable
        bd = os.path.join(T, ".config", "agents-web", "bar")
        os.makedirs(bd)
        for f, body, mode in (("load.sh", "echo 0.42", 0o755), ("prs", 'echo \'{"label": "PRs", "value": 3, "colour": "red"}\'', 0o755),
                              ("bad", "echo nope >&2; exit 1", 0o755), ("notes.txt", "echo hidden", 0o644)):
            with open(os.path.join(bd, f), "w") as fh:
                fh.write("#!/bin/sh\n" + body + "\n")
            os.chmod(os.path.join(bd, f), mode)
        t("a plug-in shows … until its first run is in", [(x["key"], x["value"]) for x in plugins()], [("x:bad", "…"), ("x:load", "…"), ("x:prs", "…")])
        wait_for(lambda: not _plugging, 5, 0.1)
        t("  then what it printed: a line under its file name, JSON as given, and a failure as ? with its reason",
          [(x["key"], x["label"], x["value"], x["colour"], x["title"]) for x in plugins()],
          [("x:bad", "bad", "?", "", "bad: nope"), ("x:load", "load", "0.42", "", ""), ("x:prs", "PRs", "3", "red", "")])
        t("  JSON's parts, meter, sparkline, pace and hiding, each bounded",
          plug_item({"value": ["a", {"text": "b", "colour": "red", "bold": 1}], "meter": {"pct": 140, "mark": "x"}, "spark": [1, -2, "z"],
                     "every": 1, "hidden": True}, "n"),
          {"label": "n", "title": "", "colour": "", "parts": [{"text": "a", "colour": "", "bold": False}, {"text": "b", "colour": "red", "bold": True}],
           "value": "ab", "meter": {"pct": 100, "mark": None, "colour": ""}, "spark": [1, 0, 0], "every": 2, "hidden": True})
        t("  and a meter with no pct is none", "meter" in plug_item({"meter": {"mark": 5}}, "n"), False)
        # the harness's own, keyed by their bare names, given the page's numbers on their input
        os.makedirs(T + "/shipped")
        with open(T + "/shipped/echo", "w") as fh:
            fh.write("#!/bin/sh\ncat > " + T + "/facts\necho on\n")
        os.chmod(T + "/shipped/echo", 0o755)
        _plugged.clear()
        plugins({"week": 70, "agents": [{"name": "Ada", "series": [1, 2]}]})
        wait_for(lambda: not _plugging, 5, 0.1)
        t("a harness plug-in is keyed by its bare name and is given the page's numbers",
          ([x["key"] for x in plugins()][0], json.load(open(T + "/facts"))), ("echo", {"week": 70, "agents": [{"name": "Ada", "series": [1, 2]}]}))
        t("  and the facts it is given are the page's numbers, each agent's state and activity, and the machine's performance",
          sorted(bar_facts({"week": 1, "tabs": [], "agents": [{"name": "A", "status": "busy", "rate": 3, "series": [1], "convo": "x"}]})),
          ["agents", "cores", "day", "disk", "even", "now", "perf", "plan", "session", "week"])
        _plugged[T + "/shipped/echo"]["every"], _plugged[T + "/shipped/echo"]["at"] = 30, time.time() - 20
        plugins()
        t("  run again only once its own pace has passed", T + "/shipped/echo" in _plugging, False)
        bar = os.path.join(ROOT, "team", "bar")
        sh = lambda f, facts: json.loads(subprocess.run([os.path.join(bar, f)], input=json.dumps(facts), capture_output=True, text=True).stdout)
        txt = lambda j: "".join(p if isinstance(p, str) else p["text"] for p in j["value"]) if isinstance(j["value"], list) else j["value"]
        day = {"used": 12, "quota": 15, "from": 58}
        t("team/bar/week: with a day open, the week and the day's use, marked at the day's stop",
          (txt(w := sh("week", {"week": 70, "plan": 85, "day": day})), w["meter"]["mark"], w["value"][0]["colour"]), ("70% - Day: 12%", 73, "green"))
        ver = {"used": 6, "quota": 5, "from": 74, "nostop": True}
        t("  a verification day past its share stays green in every bar, and says nothing stops it",
          ([sh(f, {"week": 80, "plan": 85, "day": ver})["value"][0]["colour"] for f in ("week", "weekbar", "daybar")],
           "nothing stops at it" in sh("week", {"week": 80, "plan": 85, "day": ver})["title"],
           "nothing stops at it" in sh("weekbar", {"week": 80, "plan": 85, "day": ver})["title"]),
          (["green", "green", "green"], True, True))
        t("  red once the day has spent past its share", sh("week", {"week": 74, "plan": 85, "day": {**day, "used": 16}})["value"][0]["colour"], "red")
        t("  amber with 1% of the day's share left, green with 2%",
          [sh(f, {"week": 72, "plan": 85, "day": {**day, "used": u}})["value"][0]["colour"] for f in ("week", "weekbar", "daybar") for u in (13, 14, 15)],
          ["green", "amber", "amber"] * 3)
        t("  with none, the week against the plan: green on it",
          (txt(w := sh("week", {"week": 40, "plan": 44, "even": 50})), w["meter"]["mark"], w["value"][0]["colour"]), ("40% of 44% planned", 44, "green"))
        t("  amber spending the contingency, red past an even share",
          [sh("week", {"week": v, "plan": 44, "even": 50})["value"][0]["colour"] for v in (46, 52)], ["amber", "red"])
        t("  and says when there is no reading", txt(sh("week", {"week": None})), "no reading")
        t("team/bar/session: amber from 75, red from 90", [sh("session", {"session": v})["value"][0]["colour"] for v in (74, 75, 90)], ["green", "amber", "red"])
        t("team/bar/team: the running agents' activity added up, and their rate",
          ((j := sh("team", {"agents": [{"rate": 1200, "series": [1, 2]}, {"rate": 300, "series": [3, 4]}]}))["spark"], txt(j)), ([4, 6], "1.5k tok/min"))
        t("  and no rate with none running", txt(sh("team", {"agents": []})), "")
        dk = {"label": "/", "free_gb": 30, "total_gb": 1000, "warn": 40, "alert": 20}
        t("team/bar/disk: what is free, amber under the warning", (sh("disk", {"disk": dk})["label"], txt(sh("disk", {"disk": dk})),
          sh("disk", {"disk": dk})["value"][0]["colour"]), ("/ free", "30 GB of 1000", "amber"))
        t("  and hidden with nothing to watch", sh("disk", {"disk": None})["hidden"], True)
        t("the tall four go in the header only, the slim ones either",
          {f: sh(f, {"week": 1, "disk": dk, "day": day}).get("place") for f in ("week", "session", "team", "disk", "weekbar", "daybar", "tokbar", "diskbar")},
          {"week": "header", "session": "header", "team": "header", "disk": "header", "weekbar": None, "daybar": None, "tokbar": None, "diskbar": None})
        t("team/bar/weekbar: slim, the week alone, marked at the day's stop",
          ((w := sh("weekbar", {"week": 70, "plan": 85, "day": day}))["slim"], w["label"], txt(w), w["meter"]["mark"]), (True, "Week", "70%", 73))
        gap = {"used": 2, "quota": 5, "from": 74}
        t("between days: the verification day is a day with its share of the plan, in the header and both bars",
          (txt(sh("week", {"week": 76, "plan": 85, "day": gap})), sh("week", {"week": 76, "plan": 85, "day": gap})["meter"]["mark"],
           sh("weekbar", {"week": 76, "plan": 85, "day": gap})["meter"]["mark"], (d := sh("daybar", {"plan": 85, "day": gap}))["label"], txt(d),
           d["meter"]["pct"], d["value"][0]["colour"], sh("daybar", {"plan": 85, "day": {**gap, "used": 6}})["value"][0]["colour"]),
          ("76% - Day: 2%", 79, 79, "Day", "2%", 40, "green", "red"))
        t("  and with no share, the week alone and no day bar",
          (txt(sh("week", {"week": 76, "plan": 85, "day": {**gap, "quota": None}})), sh("daybar", {"plan": 85, "day": {**gap, "quota": None}})["hidden"]),
          ("76% of 85% planned", True))
        t("team/bar/daybar: the day's share used, red once past it, hidden with none open",
          ((d := sh("daybar", {"day": day}))["meter"]["pct"], txt(d), sh("daybar", {"day": {**day, "used": 16}})["value"][0]["colour"],
           sh("daybar", {"day": None})["hidden"]), (80, "12%", "red", True))
        t("team/bar/tokbar: the sparkline alone, no text", ((j := sh("tokbar", {"agents": [{"rate": 5, "series": [1, 2]}]}))["label"], j["spark"],
          "value" in j), ("", [1, 2], False))
        t("team/bar/diskbar: the disk named and the space used, amber under the warning",
          ((j := sh("diskbar", {"disk": dk}))["label"], j["value"], round(j["meter"]["pct"]), j["meter"]["colour"]), ("Disk", "/", 97, "amber"))
        t("a plug-in's slim, name and place are kept, and a place other than header or footer is none",
          [plug_item({"label": "", "slim": True, "name": "N", "place": "footer"}, "n"), "place" in plug_item({"place": "top"}, "n")],
          [{"label": "", "title": "", "colour": "", "value": "", "slim": True, "name": "N", "place": "footer"}, False])
        # the machine's performance, for Performance panes and the CPU, Memory, Network, GPU, Heat and Fans bars: each source's
        # text as its command or /proc file prints it, and a reading made from two samples
        def perf_checks():
            # ── Linux ────────────────────────────────────────────────────────────────────
            t("CPU busy leaves out idle and iowait",
                   proc_cpu("cpu  100 5 50 800 20 3 2 0 0 0\ncpu0 1 2 3 4 5 6 7 8 9 10\n"), (160, 980))
            mem = proc_mem("MemTotal:       32768000 kB\nMemFree:  1000 kB\nMemAvailable:   12288000 kB\nCached:  6000000 kB\n"
                             "SwapTotal:       8388608 kB\nSwapFree:        1048576 kB\n")
            t("memory in use is what is not available", mem["used"], (32768000 - 12288000) * 1024)
            t("swap in use is total less free", mem["swap_used"], (8388608 - 1048576) * 1024)
            disks = proc_disks("   8       0 sda 1395 400 176634 753 0 0 0 0 0 1420 753 0 0 0 0 0 0\n"
                                 "   8       1 sda1 100 0 2000 10 5 0 80 1 0 20 11 0 0 0 0\n"
                                 " 259       0 nvme0n1 10 0 8 1 4 0 16 2 0 70 3 0 0 0 0\n"
                                 " 259       1 nvme0n1p1 10 0 8 1 4 0 16 2 0 70 3 0 0 0 0\n   7   0 loop0 1 0 2 0 0 0 0 0 0 4 0\n")
            t("whole disks only, not partitions or loop devices", sorted(disks), ["nvme0n1", "sda"])
            t("a disk's bytes read and written and ms busy", disks["sda"], (176634 * 512, 0, 1420))
            net = proc_net("Inter-|   Receive    |  Transmit\n face |bytes packets errs drop fifo frame compressed multicast|bytes packets\n"
                             "    lo: 500 5 0 0 0 0 0 0 500 5 0 0 0 0 0 0\n  eth0: 1000 10 0 0 0 0 0 0 2000 20 0 0 0 0 0 0\n"
                             "docker0: 7 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0\nvethab12: 7 1 0 0 0 0 0 0 9 1 0 0 0 0 0 0\n")
            t("real interfaces only, bytes in and out", net, {"eth0": (1000, 2000)})
            t("an nvidia-smi line", smi_line("0, NVIDIA GeForce RTX 4060 Laptop GPU, 37, 1024, 8188, 49"),
                   {"id": "0", "name": "NVIDIA GeForce RTX 4060 Laptop GPU", "pct": 37.0, "mem_used": 1024.0 * 2**20,
                    "mem_total": 8188.0 * 2**20, "temp": 49.0})
            t("a figure nvidia-smi cannot give is None", smi_line("0, GPU, [Unknown Error], 0, 8188, [N/A]")["pct"], None)
            t("nvidia-smi's errors are not a GPU", smi_line("NVIDIA-SMI has failed because it couldn't communicate"), None)

            # ── macOS ────────────────────────────────────────────────────────────────────
            top = """Processes: 512 total, 2 running, 510 sleeping, 2345 threads
            2026/11/02 09:00:00
            Load Avg: 2.10, 2.35, 2.40
            CPU usage: 5.26% user, 3.15% sys, 91.58% idle
            SharedLibs: 512M resident, 98M data, 45M linkedit.
            PhysMem: 15G used (2345M wired, 1234M compressor), 789M unused.
            Networks: packets: 1234567/1234M in, 987654/567M out.
            Disks: 2345678/45G read, 1234567/320M written.
            """
            t("top's CPU is what is not idle", mac_top(top)["cpu"], 8.4)
            t("top's disks read and written", mac_top(top)["disk"], (45 * 1024**3, 320 * 1024**2))
            vm_stat = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
            Pages free:                               12345.
            Pages active:                            234567.
            Pages wired down:                         98765.
            Pages purgeable:                           4321.
            "Translation faults":                 123456789.
            File-backed pages:                       150000.
            Anonymous pages:                         300000.
            Pages occupied by compressor:             50000.
            """
            mem = mac_mem("17179869184\n", vm_stat, "total = 2048.00M  used = 1024.50M  free = 1023.50M  (encrypted)\n")
            t("Memory Used is app memory, wired and compressed", mem["used"], (300000 - 4321 + 98765 + 50000) * 16384)
            t("macOS total memory", mem["total"], 17179869184)
            t("macOS swap", (mem["swap_used"], mem["swap_total"]), (1024.5 * 1024**2, 2048 * 1024**2))
            netstat = """Name       Mtu   Network       Address            Ipkts Ierrs     Ibytes    Opkts Oerrs     Obytes  Coll
            lo0        16384 <Link#1>                        123456     0   45678901   123456     0   45678901     0
            lo0        16384 127           localhost         123456     -   45678901   123456     -   45678901     -
            en0        1500  <Link#6>    a4:83:e7:12:34:56  9876543     0 12345678901  5432109     0  987654321     0
            en0        1500  192.168.1     192.168.1.20      9876543     - 12345678901  5432109     - 987654321     -
            en5*       1500  <Link#9>                             0     0          0        0     0          0     0
            utun0      1380  <Link#15>                            12     0       1234       34     0       5678     0
            """
            t("netstat's real interfaces, from their link rows, with or without an address",
                   mac_net(netstat), {"en0": (12345678901, 987654321), "en5": (0, 0)})
            ioreg = """+-o AGXAcceleratorG14X  <class AGXAcceleratorG14X, id 0x100000abc, registered, matched, active, busy 0 (0 ms), retain 50>
                {
                  "model" = "Apple M2"
                  "PerformanceStatistics" = {"In use system memory"=123456789,"Device Utilization %"=12,"Renderer Utilization %"=10}
                }
            """
            t("ioreg's GPU", mac_gpu(ioreg), [{"id": "0", "name": "Apple M2", "pct": 12.0, "mem_used": 123456789.0,
                                                       "mem_total": None, "temp": None}])
            t("no GPU figures, no GPU", mac_gpu(""), [])

            # ── readings ─────────────────────────────────────────────────────────────────
            g["perf_spaces"] = lambda: []
            prev = {"cpu": (100, 1000), "mem": {"total": 4, "used": 1}, "disks": {"sda": (0, 0, 0)}, "net": {"eth0": (0, 0)}, "gpus": []}
            cur = {"cpu": (400, 2000), "mem": {"total": 4, "used": 2}, "disks": {"sda": (4096, 8192, 1000)}, "net": {"eth0": (2000, 4000)}, "gpus": []}
            r = perf_reading(prev, cur, 2)
            t("CPU busy between two samples", r["cpu"], 30.0)
            t("disk rates and active time", r["disk"], {"read": 2048, "write": 4096, "active": 50.0})
            t("network rates", r["net"], [{"name": "eth0", "in": 1000, "out": 2000}])
            r = perf_reading(None, cur, 0)
            t("a first sample has no rates", ("cpu" in r, "disk" in r, "net" in r), (False, False, False))
            mac = {**cur, "cpu_pct": None, "disks": {"disk": (100, 200, None)}}
            r = perf_reading({**prev, "cpu_pct": 5.0, "disks": {"disk": (0, 0, None)}}, mac, 2)
            t("macOS before top's first sample has no CPU", "cpu" in r, False)
            t("macOS disks have rates but no active time", r["disk"], {"read": 50, "write": 100, "active": None})
        spaces = perf_spaces
        try:
            perf_checks()
        finally:
            g["perf_spaces"] = spaces
        t("team/bar/cpubar: green, red from 95%, \"…\" with no reading",
          ((j := sh("cpubar", {"perf": {"cpu": 30}, "cores": 4}))["value"][0]["colour"], j["meter"]["colour"], j["icon"],
           sh("cpubar", {"perf": {"cpu": 96}})["meter"]["colour"], sh("cpubar", {"perf": None})["value"]), ("green", "", "cpu", "red", "…"))
        t("team/bar/netbar: its last two minutes where no link speed can be read",
          ((j := sh("netbar", {"perf": {"net": [{"name": "nosuch0", "in": 1, "out": 2}], "hist": {"net:nosuch0": [1, 2]}}}))["spark"], "meter" in j),
          ([1, 2], False))
        t("team/bar/heatbar: the hottest sensor, amber from 80 °C, red from 90 °C, \"…\" with no reading, hidden with no sensor",
          ((j := sh("heatbar", {"perf": {"temps": [{"name": "TZ04", "c": 84.2}, {"name": "TZ03", "c": 48}]}}))["value"][0]["text"],
           j["meter"]["colour"], j["icon"], sh("heatbar", {"perf": {"temps": [{"name": "CPU", "c": 93}]}})["meter"]["colour"],
           sh("heatbar", {"perf": {"temps": [{"name": "CPU", "c": 40}]}})["value"][0]["colour"],
           sh("heatbar", {"perf": None})["value"], sh("heatbar", {"perf": {"temps": []}}).get("hidden")),
          ("84 °C", "amber", "heat", "red", "green", "…", True))
        fans = [{"name": "nct6799 fan2", "rpm": 0, "duty": 36}, {"name": "nct6799 fan3", "rpm": 1039, "duty": 85}]
        t("team/bar/fanbar: the fastest fan, the most power as its meter, amber from 80%, \"…\" with no reading, hidden with no fan",
          ((j := sh("fanbar", {"perf": {"fans": fans}}))["value"][0]["text"], j["meter"], j["icon"],
           sh("fanbar", {"perf": {"fans": [{**fans[0], "duty": 96}]}})["value"][0]["text"],
           sh("fanbar", {"perf": {"fans": [{**fans[0], "duty": 96}]}})["meter"]["colour"],
           "meter" in sh("fanbar", {"perf": {"fans": [{"name": "GPU", "rpm": 800, "duty": None}]}}),
           sh("fanbar", {"perf": None})["value"], sh("fanbar", {"perf": {"fans": []}}).get("hidden")),
          ("1039 rpm", {"pct": 85, "mark": None, "colour": "amber"}, "fan", "stopped", "red", False, "…", True))
        t("team/bar/heatbar: says the fans are not reported only where they are not",
          [("standing in" in sh("heatbar", {"perf": {"temps": [{"name": "CPU", "c": 40}], "fans": f}})["title"]) for f in (fans, [], None)],
          [False, True, True])
        t("Windows' thermal zones: tenths of a kelvin to °C, a zone reading 0 left out",
          windows_temps("\\_SB.TZ04=3322\r\n\\TPOL=0\r\n"), [("TZ04", 59.1)])
        hw = os.path.join(T, "hwmon")   # a board's fan chip: an empty header, a fan stopped when cool, one turning, a labelled one
        for p, v in (("hwmon7/name", "nct6799"), ("hwmon7/fan1_input", "0"), ("hwmon7/fan2_input", "0"), ("hwmon7/pwm2", "91"),
                     ("hwmon7/fan3_input", "1039"), ("hwmon7/pwm3", "255"), ("hwmon7/fan10_input", "512"),
                     ("hwmon2/name", "amdgpu"), ("hwmon2/fan1_input", "800"), ("hwmon2/fan1_label", "GPU")):
            os.makedirs(os.path.dirname(os.path.join(hw, p)), exist_ok=True)
            with open(os.path.join(hw, p), "w") as f:
                f.write(v + "\n")
        t("fans: a header that has never turned is left out, its PWM as power, labels kept, fan10 after fan3",
          sys_fans(hw, set()), [{"name": "GPU", "rpm": 800, "duty": None}, {"name": "nct6799 fan3", "rpm": 1039, "duty": 100},
                                {"name": "nct6799 fan10", "rpm": 512, "duty": None}])
        t("fans: one that has turned stays in when it stops", [f["name"] for f in sys_fans(hw, {"nct6799 fan2"})],
          ["GPU", "nct6799 fan2", "nct6799 fan3", "nct6799 fan10"])
        t("fans: none where no chip reports them", sys_fans(os.path.join(T, "nohwmon"), set()), [])
        def meeting_checks():
            opened, typed, killed, real = [], [], [], subprocess
            open_session = open_meeting_session
            class Run:   # subprocess with run() noting each command (the tmux sessions closed) and running none
                def __getattr__(self, k):
                    return getattr(real, k)
                @staticmethod
                def run(c, *a, **k):
                    killed.append(c)
            g.update(MEETINGS=T + "/meetings", MEETING_RECORDS=T + "/meeting-records", _meetings={}, subprocess=Run(),
                     open_meeting_session=lambda m, n: (opened.append(n), m["tmux"].__setitem__(n, "meet-" + n)),
                     type_into=lambda n, text, images=(): typed.append((n, text)) or True, setting=lambda n: "",
                     live_sessions=lambda: {"A · meeting": {"status": "idle"}, "B · meeting": {"status": "idle"}, "A": {"status": "idle"}},
                     roster=lambda: [{"name": "A", "role": "developer"}, {"name": "B", "role": "tester"}, {"name": "C", "role": "developer"}])
            me = meeting_owner()
            m = start_meeting(["A", "B"], "Plan", "V")
            t("a meeting opens a meeting session for each agent", opened, ["A", "B"])
            meeting_said(m, "A", "hello")
            t("a session's line is held for the others only", {k: v for k, v in m["held"].items() if v}, {"B": ["A: hello"]})
            m["paused"] = True
            meeting_said(m, "B", "hi A")
            t("the owner speaking ends a Pause", (m["paused"], meeting_said(m, None, "go on") and m["paused"]), (True, False))
            t("the owner's line is held for every session", (m["held"]["A"][-1], m["held"]["B"][-1]), (f"{me}: go on", f"{me}: go on"))
            meeting_join(m, "C", added=True)
            t("an agent brought in hears what was said before it joined", m["held"]["C"][:2], ["(said before you joined)", "A: hello"])
            meeting_end(m)
            t("End asks each running session for a handover; one not running has nothing", {n: h["state"] for n, h in m["handover"].items()},
              {"A": "asked", "B": "asked", "C": "skipped"})
            meeting_said(m, "A", "Do the thing", handover=True)
            meeting_said(m, "B", "nothing", handover=True)
            t("a suggested handover waits for the owner; \"nothing\" is skipped", ({n: h["state"] for n, h in m["handover"].items()}, m["ended"]),
              ({"A": "suggested", "B": "skipped", "C": "skipped"}, None))
            meeting_handover(m, "A", "send", "Do the thing, edited")
            t("an edited handover is queued, the meeting ends and its sessions close",
              (m["handover"]["A"]["state"], m["handover"]["A"]["edited"], bool(m["ended"]), len(killed)), ("queued", True, True, 3))
            with open(os.path.join(MEETING_RECORDS, m["record"])) as f:
                rec = f.read()
            t("the readable record has the lines, who was brought in and what was sent",
              all(x in rec for x in ("**A**", "C was brought in", "Sent: Do the thing, edited", "B**: nothing to send")), True)
            m2 = start_meeting(["A", "B"], "", "V")
            typed.clear()
            meeting_said(m2, None, "first")
            meeting_said(m2, "A", "second")
            g["live_sessions"] = lambda: {"A · meeting": {"status": "idle"}, "B · meeting": {"status": "busy"}, "A": {"status": "busy"}}
            meeting_deliver_once()
            t("an idle session hears its lines; a busy one waits", typed, [("A · meeting", f"[Meeting]\n{me}: first")])
            g["live_sessions"] = lambda: {"A · meeting": {"status": "idle"}, "B · meeting": {"status": "idle"}, "A": {"status": "idle"}}
            typed.clear()
            meeting_deliver_once()
            t("a session idle again hears every held line in one go, and an idle agent gets its queued handover", sorted(typed),
              [("A", "[Meeting: Plan] Do the thing, edited"), ("B · meeting", f"[Meeting]\n{me}: first\nA: second")])
            t("the handover is then marked sent", m["handover"]["A"]["state"], "sent")
            m2["paused"] = True
            meeting_said(m2, "B", "third")
            typed.clear()
            meeting_deliver_once()
            t("nothing is delivered while the meeting is paused", typed, [])
            g["subprocess"] = real   # the trust and stuck readers below run git and tmux for real
            R = os.path.realpath(T)
            for d in ("yes", "no", "other"):
                os.makedirs(f"{R}/{d}", exist_ok=True)
            real.run(["git", "init", "-q", f"{R}/repo"], check=True)
            real.run(["git", "-C", f"{R}/repo", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x"], check=True)
            real.run(["git", "-C", f"{R}/repo", "worktree", "add", "-q", f"{R}/wt"], check=True)
            g["CLAUDE_JSON"] = f"{R}/claude.json"
            t("a folder Claude Code has never seen cannot tell nothing: no .claude.json is None", folder_trusted(f"{R}/yes"), None)
            with open(f"{R}/claude.json", "w") as f:
                json.dump({"projects": {f"{R}/yes": {"hasTrustDialogAccepted": True}, f"{R}/no": {"hasTrustDialogAccepted": False},
                                        f"{R}/repo": {"hasTrustDialogAccepted": True}, R: {"hasTrustDialogAccepted": True}}}, f)
            t("a trusted folder is trusted; one refused or never asked is not, though its parent is",
              (folder_trusted(f"{R}/yes"), folder_trusted(f"{R}/no"), folder_trusted(f"{R}/other")), (True, False, False))
            t("a worktree takes its main checkout's trust", folder_trusted(f"{R}/wt"), True)
            m3 = start_meeting(["A"], "", "V")
            t("an attendee just joined is not stuck", meeting_stuck(m3, "A", {}), None)
            m3["joined"]["A"] -= MEETING_STUCK_AFTER + 1
            g["meeting_screen"] = lambda tmux: None
            t("one whose session has gone is stuck, and says so", meeting_stuck(m3, "A", {}), "its session closed")
            g["meeting_screen"] = lambda tmux: " ❯ No, exit\n   Yes, I trust this folder\n"
            t("one at the trust prompt is stuck there", meeting_stuck(m3, "A", {}), "waiting at Claude Code's folder trust prompt")
            g["meeting_screen"] = lambda tmux: "> "
            t("one running but silent is stuck as that", meeting_stuck(m3, "A", {"A · meeting": {}}), "running but has not said it is here")
            m3["present"]["A"] = time.time()
            t("one that has said it is here is not stuck", meeting_stuck(m3, "A", {}), None)
            g.update(last_sessions=lambda: {}, subprocess=Run())   # notes the byobu command, starts nothing
            killed.clear()
            open_session(m3, "A")
            t("a meeting session starts in the folder the projects sit in, not in the project",
              (killed[-1][-1].startswith(f"cd {shlex.quote(MEETING_DIR)} && "),
               os.environ.get("AGENTS_MEETING_DIR") is not None or MEETING_DIR == os.path.dirname(ROOT)), (True, True))
        keep = {k: g[k] for k in ("MEETINGS", "MEETING_RECORDS", "_meetings", "subprocess", "open_meeting_session", "type_into",
                                  "setting", "live_sessions", "roster", "CLAUDE_JSON", "meeting_screen", "last_sessions")}
        try:
            meeting_checks()
        finally:
            g.update(keep)
        sc, was = tempfile.mkdtemp(), g["SCRATCH"]   # outside the test's home, so only the scratchpad rule can pass it
        os.makedirs(sc + "/s/scratchpad")
        g["SCRATCH"] = sc
        try:
            pad = sc + "/s/scratchpad/a.md"
            os.chmod(sc, 0o700)
            mine = shown_file(pad)
            os.chmod(sc, 0o755)
            shared = shown_file(pad)
            t("a file in a private scratchpad is shown, one in a scratchpad others can enter is not, nor one outside both",
              (shown_file(T + "/x.md"), mine, shared, shown_file("/tmp/other/a.md"), shown_file(sc + "-evil/a.md")),
              (True, True, False, False, False))
        finally:
            g["SCRATCH"] = was
            shutil.rmtree(sc, ignore_errors=True)
        wd, was_w = tempfile.mkdtemp(), g["WANTED"]
        g["WANTED"] = wd
        try:
            with open(wd + "/s1", "w") as f:
                f.write("needs a decision\n")
            t("owner-wanted: a session's flag gives its line, and one with none gives nothing",
              (wanted("s1")[0], wanted("s2")), ("needs a decision", (None, None)))
        finally:
            g["WANTED"] = was_w
            shutil.rmtree(wd, ignore_errors=True)
        t("  a List row's status is amber for an agent that wants the owner, as for one waiting",
          ".mini.waiting .mtop .mstat,.mini.wanted .mtop .mstat{color:var(--amber)}" in PAGE, True)
        t("  an agent not on a prompt that wants the owner pulses amber as one waiting, and counts in the badge and Alt+W",
          ('a.status !== "waiting" && a.wanted ? "wanted"' in PAGE, ".card.waiting,.card.wanted{" in PAGE,
           'focusAgent(needing()[0]?.name)' in PAGE), (True, True, True))
        t("a plug-in's icon is kept, and one that is not a plain name is not",("icon" in plug_item({"icon": "cpu"}, "n"), "icon" in plug_item({"icon": "<svg>"}, "n")),
          (True, False))
        tf = os.path.join(T, "tokens.jsonl")
        line = lambda rid, ts, u, tools=(): json.dumps({"type": "assistant", "requestId": rid, "timestamp": ts,
            "message": {"usage": u, "content": [{"type": "tool_use", "name": n} for n in tools]}}) + "\n"
        with open(tf, "w") as f:
            f.write('{"type":"custom-title","customTitle":"Ann"}\n' + line("r1", "2026-11-09T10:00:00Z", {"input_tokens": 1, "cache_creation_input_tokens": 10, "cache_read_input_tokens": 100, "output_tokens": 2})
                    + line("r1", "2026-11-09T10:00:01Z", {"input_tokens": 1, "output_tokens": 2}, ["SendMessage"]))
        k1 = token_file(tf, os.path.getsize(tf), None)
        with open(tf, "a") as f:
            f.write(line("r2", "2026-11-10T09:00:00Z", {"output_tokens": 5}) + '{"type":"assistant","requestId":"r3"')
        k2 = token_file(tf, os.path.getsize(tf), k1)
        t("token usage: a response counts once by its request id, its messages sent count, and a file is read on from where it stopped",
          (k1["title"], k1["days"]["2026-11-09"], k2["days"].get("2026-11-10"), k2["off"] < os.path.getsize(tf)),
          ("Ann", [1, 10, 100, 2, 1, 1], [0, 0, 0, 5, 1, 0], True))
        t("token usage: the pane draws a box per week and any pane's tabs hold a whole pane",
          ('Week of ${label(mon' in PAGE, "tokens: \"Token usage\"" in PAGE, "function showTab(n, i)" in PAGE), (True, True, True))
        t("views: Gauges and Performance open as Machine, people views share the role chips, same-named tabs are numbered, and the Team pane draws",
          ('t.machine = t.show === "perf" ? "rows" : "gauges"; t.show = "machine";' in PAGE,
           'const CHIP_VIEWS = ["grid", "others", "tabs", "combined", "characters", "meeting", "daylog", "workqueue", "tokens"];' in PAGE,
           "out[path + \":\" + i] = c > 1 ? `${name} ${c}` : name;" in PAGE, "kept.length} message" in PAGE and "const kept = teamLog" in PAGE), (True, True, True, True))
        t("pane tabs: each picks its view from the grouped picker, names itself, and filters by role chips with no roles meaning All",
          ("function viewPicker(btn, path, picked)" in PAGE, "function autoName(p)" in PAGE, "const roleChips = " in PAGE,
           "const rolesOn = n => rolesPicked(n).length ? n.roles : roleList().map(r => r.role);" in PAGE), (True, True, True, True))
    finally:
        for k in kids:
            k.kill()
        shutil.rmtree(T, ignore_errors=True)
    print("all passed" if not fails else f"{len(fails)} failed")
    sys.exit(1 if fails else 0)


def main():
    import sys
    if sys.argv[1:] == ["--self-test"]:
        self_test()
    load_meetings()
    threading.Thread(target=meeting_deliver, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
