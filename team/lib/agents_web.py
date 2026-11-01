#!/usr/bin/env python3
"""The team as a web page, on this machine only. Run through team/agents-web.sh, which loads harness.env.

  /                 the page: the week, the disk and every running agent on the roster, in sections by role, each
                    with its state, context, burn, ticket and the last turns of its conversation
  /api/state        everything the page draws, as JSON
                    (and the header's and footer's plug-ins: team/bar's and each executable in AGENT_BAR_PLUGINS,
                    else ~/.config/agents-web/bar, given the page's numbers, print a line or JSON; see plugins())
  /api/team         every message between the running agents, as one transcript
  /api/agent/NAME   one agent's longer conversation and its terminal as it is on screen now (HTML)
  /doc?p=PATH       a document an agent names by its full path, as text for the page to show over itself
  POST /api/agent/NAME/say   {"text": "...", "images": [pasted paths]} typed into the agent's tmux pane, then Enter
  POST /api/agent/NAME/answer  {"n": 3, "label": "Type something.", "text": "..."} the prompt open in its pane
                             answered with option n: its digit, or for a typed option the text, then Enter
  POST /api/agent/NAME/stop  Esc in the agent's pane, while it is working
  POST /api/paste    an image pasted into the page, or any file picked, kept under ~/.local/state/<project>/pasted for a message to attach
  POST /api/team/start       team/team-start.sh, then each agent the page stopped is compacted once it is up, and the
                             delivery lead is told the team is back up to start the day
  POST /api/team/stop        the delivery lead is asked to wind the team down, as the owner asks before a shutdown
  POST /api/nudger/pause     the waiting-agents nudger stops nudging until resumed; /api/nudger/resume starts it again
  POST /api/agent/NAME/start team/team-start.sh --only NAME, for an agent outside the developers and testers,
                             compacted once it is up if the page stopped it
  POST /api/agent/NAME/halt  the agent is asked to finish and stop; its pane closes once it has (not the lead's)
  POST /api/agent/NAME/compact  /compact typed into the agent's pane once it is not working

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
import glob
import hashlib
import html
import json
import os
import re
import shlex
import shutil
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
ROOT = os.environ.get("HARNESS_ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJECT = os.environ.get("HARNESS_PROJECT") or os.path.basename(ROOT)
STATE_DIR = os.path.join(HOME, ".local/state", PROJECT)
PORT = int(os.environ.get("AGENT_WEB_PORT") or "8787")
PUBLIC_HOST = os.environ.get("AGENT_WEB_PUBLIC_HOST") or ""
ACCESS_TEAM = (os.environ.get("AGENT_WEB_ACCESS_TEAM") or "").removeprefix("https://").split(".")[0]
ACCESS_AUD = os.environ.get("AGENT_WEB_ACCESS_AUD") or ""
ROSTER = os.environ.get("ROSTER_FILE") or os.path.join(ROOT, "agents/roster.json")
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


def ansi_html(text):
    """Terminal text with SGR colours as escaped HTML spans; any other escape sequence is dropped."""
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
        t = html.escape("".join(buf))
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
    return rows


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


def live_sessions():
    """Roster name -> Claude Code's own record of the session, for every session whose process and socket are live.
    A session is the agent whose roster address its process carries in GIT_AUTHOR_EMAIL, else the one its record is
    named, and only while its process is the session's own: Claude Code started for it, or else started no later than
    the session did (team/lib/agent-session.sh)."""
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
    except (OSError, json.JSONDecodeError):
        return {}


def series(entry, now):
    cur = int(now // 60)
    b = (entry or {}).get("buckets") or {}
    return [int(b.get(str(m), 0)) for m in range(cur - SPARK_MINS + 1, cur + 1)]


def last_minute(ser, now):
    """Tokens in the last 60 s: this minute so far plus the part of last minute still inside it."""
    return int(ser[-1] + ser[-2] * (60 - now % 60) / 60) if len(ser) > 1 else 0


_board = {"at": 0, "busy": False}


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
    """The development day open now (team/agents-day-budget.sh), as {"used", "quota", "from"}: the points the day has
    spent, its share and the week's reading when it started. Between days (in strength, the verification day) the
    quota is None and the rest counts from the last day's end. None otherwise: the week's even pacing applies."""
    out = run("bash", DAY_BUDGET)
    if m := re.search(r"^day  (?:on|over): (\d+)% of the day's (\d+)% used \(week \d+%, from (\d+)%", out, re.M):
        return dict(zip(("used", "quota", "from"), map(int, m.groups())))
    if m := re.search(r"^day  none: between days since .+?: (\d+)% used \(week \d+%, from (\d+)%", out, re.M):
        return {"used": int(m[1]), "quota": None, "from": int(m[2])}
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


# Plug-ins for the page's header and footer (owner, 2026-11-01: "header should default to what we have, with other
# options addable as plug in style scripts"): each executable file in AGENT_BAR_PLUGINS, else ~/.config/agents-web/bar,
# is an item the page can add, named by its file name, and keyed "x:<name>". The harness's own are in team/bar - Week,
# Session, Team and Disk - keyed by their bare names, and in the bar until taken out. Each is run in the background
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
    """The page's numbers a plug-in is given: the account's week and session, the budget's plan and day, the disk,
    and each running agent's state and activity."""
    return {**{k: st.get(k) for k in ("now", "week", "session", "plan", "even", "day", "disk")},
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
    <project>-<name>, else of a pane titled with its name (a session started by hand)."""
    names = {r["name"].lower(): r["name"] for r in roster()}
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


def type_into(name, text, images=()):
    """Types a message into the agent's pane, then Enter; None when it is in no pane, else whether tmux took it.
    The text goes in as one bracketed paste, as a terminal pastes, so its line breaks stay line breaks in the agent's
    message box instead of sending it early. Each image follows as a paste of its path alone, which Claude Code
    attaches as an image, as when a file is dragged in; any other file stays as its path, for the agent to open,
    with a space after it so the next one does not run on."""
    where = panes().get(name)
    if not where:
        return None
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
        subprocess.run(["bash", "-lic", 'exec bash "$0" "$@"', TEAM_START_SH, *args], stdin=subprocess.DEVNULL,
                       stdout=log, stderr=subprocess.STDOUT, timeout=300)


def team_paused():
    """Whether team/team-paused.sh says the team is wound down."""
    try:
        return subprocess.run(["bash", TEAM_PAUSED_SH], stdin=subprocess.DEVNULL, capture_output=True, timeout=5).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def team_up():
    """Who the next start brings back: those running when the page last stopped the team who are still on the roster,
    the lead always among them; None with no record, when the whole team starts."""
    try:
        with open(TEAM_UP) as f:
            names = {n.strip() for n in f if n.strip()}
    except OSError:
        return None
    return [r["name"] for r in roster() if r["name"] in names or role_of(r["role"])[0] == "lead"]


def start_team(lead, names):
    """team/team-start.sh for the named agents (the whole team for None), then, once the lead is up and ready
    for a message, the lead is told to start the day. The record of who was running is used up."""
    started = names or [r["name"] for r in roster()]
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
        restore("--only", name)
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
                except json.JSONDecodeError:
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
        except json.JSONDecodeError:
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
    options; it is cut from their labels, which would otherwise change as the cursor moves. None when no numbered
    options are on screen."""
    lines = [l.rstrip() for l in run("tmux", "capture-pane", "-p", "-t", pane).splitlines()]
    opts = [i for i, l in enumerate(lines) if re.match(r"^\s*(❯\s*)?1\.\s", l)]
    if not opts:
        return None
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


def with_ask(items, status, pane):
    """The conversation, ending with the pane's open prompt while the agent is waiting on one, or with what its
    pane shows it doing while it works, then the owner's messages queued behind it."""
    pending = [it for it in items if it["kind"] == "pending"]
    items = [it for it in items if it["kind"] != "pending"]
    if not pane or status not in ("waiting", "busy"):
        return items   # a queue lasts only as long as the turn it waits behind
    if status == "waiting":
        ask = ask_of(pane["pane"])
        return items + ([{"kind": "ask", "who": "waiting for you", "text": ask["text"], "options": ask["options"], "ts": None,
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
        m = re.fullmatch(r"(?:\x1b\[[0-9;:]*m)*❯[\s\xa0]+\x1b\[2m([^\x1b]+)\x1b\[0m\s*", line.rstrip())
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
        except (OSError, json.JSONDecodeError):
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
            # none is there too, stopped, and its menu starts it (owner, 2026-10-31)
            if role in ("dev", "tester") or role in STANDING:
                # its model, effort and last compaction are its last session's, the model read from its transcript
                # once the session's context row has gone
                was = last.get(name)
                row = rows.get(was, {}) if was else {}
                bench.append({"name": name, "role": role, "roleName": role_name, "colour": colour(r["role"]), **portraits(name),
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
        agents.append({
            "name": name, "role": role, "roleName": role_name, "colour": colour(r["role"]),
            "tab": tab, "live": bool(rec), "status": (rec or {}).get("status") or ("off" if not rec else "?"),
            "held": int(now - since) if since else None,
            "ctxUsed": used, "ctxWindow": window,
            "ctxPct": round(used * 100 / window) if used and window else None,
            "model": row.get("model", ""), "effort": row.get("effort", ""),
            "ticket": held.get(name.lower(), ""),
            "cwd": row.get("worktree") or os.path.basename((rec or row).get("cwd") or ""),
            "series": ser, "rate": last_minute(ser, now), **portraits(name),
            "compacting": bool(sid) and hook_compacting(sid, now), "lastCompact": last_compact(was),
            "feed": with_ask(by_lane(feed(sid, 300), 10) if sid else [], (rec or {}).get("status"), where.get(name)),
            "suggest": suggestion(where[name]["pane"]) if rec and rec.get("status") == "idle" and name in where else "",
        })
    # the team has stopped once team/team-paused.sh says so and no running agent is busy or waiting; a lead that has
    # not marked it paused ten minutes after being asked is taken not to be stopping it
    paused = team_paused()
    if paused and not any(a["live"] and (a["status"] in ("busy", "waiting") or a["compacting"]) for a in agents) or not paused and now - _team_stop["at"] > 600:
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
        "agents": agents, "bench": bench, "owner": setting("AGENT_OWNER_NAME") or "Owner",
        "teamPaused": paused, "nudgerPaused": os.path.exists(NUDGER_PAUSED), "starting": sorted(_starting), "halting": sorted(_halting),
        "compacting": sorted(_compacting | {a["name"] for a in agents if a["compacting"]}), "teamUp": team_up(),
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


def state_json():
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
        screen = ansi_html(run("tmux", "capture-pane", "-p", "-e", "-t", where["pane"]).rstrip("\n"))
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

    def send(self, code, body, ctype, cache="no-store"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", cache)
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
        elif path == "/api/commands":
            self.send(200, json.dumps(commands()).encode(), "application/json")
        elif path.startswith("/api/agent/") and re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", path[11:]):
            self.send(200, agent_json(path[11:]), "application/json")
        elif path == "/img":
            self.image()
        elif path == "/doc":
            self.doc()
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
        or key file), and only from under the home directory."""
        if not self.here():
            return self.send(403, b"only the team page\n", "text/plain")
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        real = os.path.realpath(os.path.expanduser(query.get("p", [""])[0]))
        if (os.path.splitext(real)[1].lower() not in DOC_TYPES or not real.startswith(HOME + os.sep)
                or not os.path.isfile(real) or os.path.getsize(real) > 2_000_000):
            return self.send(404, b"no such document\n", "text/plain")
        with open(real, "rb") as f:
            self.send(200, f.read(), "text/plain; charset=utf-8")

    def image(self):
        """An image an agent names by its path, full or from its own folder, for the page to show: only from the page
        itself (the Host check keeps other sites out), only an image file, and only from under the home directory."""
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
        if not kind or not real.startswith(HOME + os.sep) or not os.path.isfile(real) or os.path.getsize(real) > 25_000_000:
            return self.send(404, b"no such image\n", "text/plain")
        with open(real, "rb") as f:
            self.send(200, f.read(), kind, "private, max-age=300")

    def do_POST(self):
        m = re.fullmatch(r"/api/agent/([A-Za-z][A-Za-z0-9_-]*)/(say|answer|stop|start|halt|compact)", self.path)
        team = re.fullmatch(r"/api/team/(start|stop)", self.path)
        nudger = re.fullmatch(r"/api/nudger/(pause|resume)", self.path)
        if not m and not team and not nudger and self.path != "/api/paste":
            return self.send(404, b"not found\n", "text/plain")
        origins = {f"http://127.0.0.1:{PORT}", f"http://localhost:{PORT}"} | ({f"https://{PUBLIC_HOST}"} if PUBLIC_HOST else set())
        origin = self.headers.get("Origin")
        if not self.here() or self.headers.get("X-Team-Say") != "1" or (origin and origin not in origins):
            return self.send(403, b"only the team page can send\n", "text/plain")
        if team:
            return self.team(team.group(1))
        if nudger:
            return self.nudger(nudger.group(1) == "pause")
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
        lead = next((r["name"] for r in roster() if role_of(r["role"])[0] == "lead"), None)
        if not lead:
            return self.send(409, b"no delivery lead on the roster\n", "text/plain")
        if what == "stop":
            running = [r["name"] for r in roster() if r["name"] in live_sessions()]
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
        _starting.update(["team", *(names or [r["name"] for r in roster()])])
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
            _starting.add(name)
            threading.Thread(target=start_one, args=(name,), daemon=True).start()
            return self.send(202, json.dumps({"starting": name}).encode(), "application/json")
        if name in _halting:
            return self.send(409, b"already stopping\n", "text/plain")
        ok = type_into(name, AGENT_STOP)
        if ok is None:
            return self.send(409, b"that agent is not running\n", "text/plain")
        _halting.add(name)
        compact_later([name])
        threading.Thread(target=halt_when_idle, args=(name,), daemon=True).start()
        self.send(202, json.dumps({"stopping": name}).encode(), "application/json")

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
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Team</title>
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
body{font:calc(13px*var(--fs,1))/1.45 var(--sans);color:var(--text);background:var(--bg);display:flex;flex-direction:column;
  background-image:radial-gradient(1200px 600px at 10% -10%,var(--glow1),transparent 60%),radial-gradient(900px 500px at 110% 110%,var(--glow2),transparent 60%)}
header,footer{display:flex;align-items:center;gap:22px;padding:12px 18px;flex:none}
header{border-bottom:1px solid var(--line)}footer{border-top:1px solid var(--line)}
footer{padding:3px 14px;gap:18px;min-height:0}   /* the footer is a status bar: as low as its tallest item */
/* the bar's items, in the header or the footer; while the layout is unlocked each is outlined, dragged and taken out with its ✕ */
.bi{position:relative;display:flex;align-items:center;flex:none;min-width:0}
.bi[data-item=bench]{flex:1}
/* a spacer takes the room left, so what comes after it keeps to the right; it shows only while the layout is unlocked */
.bi.gap{flex:1;min-width:0}
.editing > .bi.gap{min-width:60px;height:18px;justify-content:center;color:var(--faint);font-size:calc(11px*var(--fs,1))}
.editing > .bi.gap::before{content:"Spacer"}
.bi.tight + .bi.tight{margin-left:-14px}
.bi:not(.tight) + .bi.tight{margin-left:auto}   /* the buttons keep to the right, as the bench's room pushed them */
.bi > .bx{display:none}
.bi:has(> :first-child:is([style*="display: none"],[style*="display:none"])){display:none}   /* Session or Disk while it is not shown */
.editing > .bi{outline:1px dashed var(--line2);outline-offset:3px;border-radius:4px;cursor:grab;touch-action:none}
.editing > .bi.tight + .bi.tight{margin-left:0}
.editing > .bi.dragging{opacity:.4}
.editing > .bi > .bx{display:flex;position:absolute;z-index:5;top:-10px;right:-10px;width:16px;height:16px;align-items:center;justify-content:center;border-radius:50%;
  background:var(--box);border:1px solid var(--line2);color:var(--mute);font:normal 10px/1 var(--sans);cursor:pointer}
.editing > .bi > .bx:hover{color:var(--red);border-color:var(--red)}
header.bare:not(.editing),footer.bare:not(.editing){display:none}   /* a bar with nothing showing takes no room */
header.editing:not(:has(.bi))::before{content:"Header · drag items here";color:var(--faint);font-size:calc(12px*var(--fs,1))}
footer.editing:not(:has(.bi))::before{content:"Footer · drag items here";color:var(--faint);font-size:calc(12px*var(--fs,1))}
.barplus{margin-left:auto;flex:none;width:28px;height:24px;padding:0;border:1px solid var(--line2);border-radius:6px;background:var(--soft);color:var(--mute);font:inherit;
  font-size:calc(16px*var(--fs,1));line-height:1;text-align:center;text-align-last:center;appearance:none;-webkit-appearance:none;cursor:pointer}
.brand{display:flex;align-items:center;flex:none}
.brand .lt,html.light .brand .dk{display:none}html.light .brand .lt{display:block}   /* the logo drawn for the theme */
.stat{display:flex;flex-direction:column;gap:4px;min-width:150px}
.stat .k{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:calc(10.5px*var(--fs,1));letter-spacing:.12em;text-transform:uppercase;color:var(--mute)}
.stat .v{font:600 calc(13px*var(--fs,1)) var(--mono)}
.pspark{width:190px;height:22px;color:var(--ownerbg)}.pspark svg.spark{height:22px}
/* a slim plug-in is one low line: its label and value beside a shorter meter or sparkline */
.stat.slim{flex-direction:row;align-items:center;gap:7px;min-width:0}
.stat.slim .meter{width:110px;height:6px}.stat.slim .meter u{top:-3px;bottom:-3px}
.stat.slim .pspark,.stat.slim .pspark svg.spark{width:110px;height:14px}
.meter{position:relative;height:8px;border-radius:5px;background:var(--track);overflow:visible;width:190px}
.meter i{position:absolute;inset:0 auto 0 0;border-radius:5px;transition:width .6s}
.meter u{position:absolute;top:-4px;bottom:-4px;width:2px;background:var(--text);border-radius:2px;box-shadow:0 0 6px #fff8}
.counts{flex:none;display:flex;gap:8px}
.pill{display:flex;align-items:center;gap:6px;padding:5px 10px;border:1px solid var(--line2);border-radius:999px;font:600 calc(12px*var(--fs,1)) var(--mono);background:var(--soft);color:var(--text)}
.pill.btn{cursor:pointer;color:var(--mute);font-family:var(--sans)}
.pill.btn:hover{color:var(--text);border-color:var(--hover)}
.pill.tally{position:relative;gap:5px}
.pill.tally b:first-of-type{margin-right:5px}
.pill.tally .dot.on{--reach:7px;animation:ping 1.4s infinite}
.pill.tally .wait{cursor:pointer;position:absolute;inset:-1px;display:flex;align-items:center;justify-content:center;border-radius:999px;border:2px solid #ffb020;color:#000;font:700 calc(12.5px*var(--fs,1)) var(--sans);white-space:nowrap;animation:pillflash 1s ease-in-out infinite}
.bench{flex:1;min-width:0;display:grid;grid-template-columns:auto minmax(0,1fr);gap:4px 6px;align-items:center;color:var(--faint);font-size:calc(11px*var(--fs,1))}
.bench .rrow{display:flex;gap:5px;min-width:0;overflow:hidden;padding:1px}   /* one row, overlapped to fit: fitBench; room for a stacked card's rim */
.bench .rrow > *{position:relative}
.bench .rrow.stack > [data-name]{box-shadow:0 0 0 1px var(--bg)}   /* a fine rim in the page's background colour parts each card of the stack */
.bench em.more{cursor:pointer}
/* every row open, over the page rather than pushing it down, from where the folded rows sat */
.bench{position:relative}
.bench .rrow.all{position:absolute;z-index:30;flex-wrap:wrap;padding:6px;margin:-7px 0 0 -7px;border:1px solid var(--line2);border-radius:9px;background:var(--box);box-shadow:0 10px 28px #0008}
.bench em.more:hover{color:var(--text)}
.bench em{flex:none;font-style:normal;padding:1px 7px;border-radius:5px;border:2px solid var(--c);color:var(--mute)}
.face{position:relative;flex:none;width:34px;height:34px;overflow:hidden;border-radius:7px;border-bottom:3px solid var(--c);background:var(--chtile)}   /* a Characters tile, smaller */
.face img,.face svg{display:block;width:100%;height:100%;object-fit:cover}
.face .ini{position:absolute;left:2px;bottom:2px;min-width:9px;padding:0 2px;border-radius:3px;border:1px solid var(--c);
  font:700 9px/10px var(--sans);text-align:center;color:var(--text);background:color-mix(in srgb,var(--c) 30%,var(--chtile))}   /* a shadow's initial, bottom left on every role */
.face.waiting{animation:alarm 1s ease-in-out infinite}   /* as a Characters tile */
.bench > span:first-child{display:flex;align-items:center;gap:2px}
main{position:relative;flex:1;min-height:0;display:grid;grid-template-rows:minmax(0,1fr);gap:14px;padding:14px}
.colgrip{position:absolute;top:14px;bottom:14px;width:14px;cursor:col-resize;z-index:3}
.colgrip::after{content:"";position:absolute;inset:0 5px;border-radius:2px;background:transparent;transition:background .15s}
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
.divider.drag::after{content:"";position:absolute;inset:0 5px;border-radius:2px;transition:background .15s}
.lay.col > .divider.drag::after{inset:5px 0}
.divider.drag:hover::after,.divider.moving::after{background:var(--line2)}
body.resizing-row{cursor:row-resize;user-select:none}
.pane{min-width:0;min-height:0;display:flex;flex-direction:column;border:1px solid var(--line);border-radius:14px;background:var(--section);backdrop-filter:blur(8px)}
.pbar{flex:none;display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;padding:7px 10px;border-bottom:1px solid var(--line);font-size:calc(11px*var(--fs,1));color:var(--mute)}
.pbar select{font:calc(12px*var(--fs,1)) var(--sans);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:6px;padding:1px 4px}
/* the browser draws a select's open list and an input's own parts in the page's theme, not its default light one */
.pbar :is(select, input){color-scheme:dark}
html.light .pbar :is(select, input){color-scheme:light}
.pbar option{background:var(--box);color:var(--text)}
.pbar input{flex:1 1 240px;min-width:0;font:calc(12px*var(--fs,1)) var(--mono);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:6px;padding:2px 6px}
.pbar input::placeholder{color:var(--faint)}
/* a File pane: one document, as the document viewer shows it */
.fdoc{flex:1;min-height:0;overflow:auto;padding:12px 16px;color:var(--text);font-size:calc(13px*var(--fs,1));line-height:1.5;white-space:pre-wrap;word-break:break-word}
.pbar .pacts{display:flex;gap:2px;margin-left:auto}
.pbar .pacts b{padding:1px 6px;border-radius:5px;font-size:calc(13px*var(--fs,1));font-weight:400;cursor:pointer}
.pbar .pacts b:hover{background:var(--on);color:var(--text)}
/* a pane's grip drags it onto another pane, and the two swap places */
.pbar b.pmove{margin-left:-4px;padding:1px 4px;border-radius:5px;font-size:calc(13px*var(--fs,1));font-weight:400;cursor:grab;touch-action:none}
.pbar b.pmove:hover{background:var(--on);color:var(--text)}
body.moving-pane,body.moving-pane *{cursor:grabbing !important;user-select:none}
.pane.lifted{opacity:.55}
.pane.drop{outline:2px dashed var(--cyan);outline-offset:-2px}
.pbody{flex:1;min-height:0;display:flex;flex-direction:column}
.pbody .blank{margin:auto;color:var(--faint);font-size:calc(12px*var(--fs,1))}
.others{flex:1;min-height:0;overflow:auto;padding:10px;display:flex;flex-direction:column;gap:8px}
section.tab{min-height:0;display:flex;flex-direction:column;border:1px solid var(--line);border-radius:14px;background:var(--section);backdrop-filter:blur(8px)}
section.tab h2{min-height:41px;display:flex;justify-content:space-between;align-items:center;padding:9px 14px;font-size:calc(11px*var(--fs,1));letter-spacing:.16em;text-transform:uppercase;color:var(--mute);font-weight:600;border-bottom:1px solid var(--line)}
.seg{display:flex;border:1px solid var(--line2);border-radius:7px;overflow:hidden;letter-spacing:0;text-transform:none}
.seg b{padding:2px 9px;font-weight:500;font-size:calc(11px*var(--fs,1));cursor:pointer;color:var(--mute)}
.seg b.on{background:var(--on);color:var(--text)}
#pagemode,#pagelanes{display:flex}
#help,#settings{width:30px;padding:0;font:700 calc(13px*var(--fs,1)) var(--sans)}
#settings{display:inline-flex;align-items:center;justify-content:center}
#settings svg{flex:none;width:calc(17px*var(--fs,1));height:calc(17px*var(--fs,1))}
#teamctl{display:flex}
#teamctl{gap:6px}
#teamctl .fbtn{gap:6px}
#teamctl .fbtn svg{flex:none;width:16px;height:16px;stroke-width:1.7}
/* the team's play, pause and stop: off an outline in the text colour, on filled in its colour, fading in and out
   while the page waits for the change it was asked for */
#pagelanes .fbtn,#pagemode .fbtn,#help,#settings{height:auto;padding:0 12px;border:1px solid var(--line2);border-radius:999px;background:var(--soft);font-size:calc(12px*var(--fs,1))}
#teamctl .fbtn{height:auto;padding:0 9px;white-space:nowrap;border:1.5px solid var(--text);border-radius:999px;background:none;color:var(--text);font-size:calc(12px*var(--fs,1))}
#teamctl .fbtn:hover{background:var(--on)}
#teamctl .fbtn:is(.lit,.going){background:var(--c);border-color:var(--c);color:var(--bg)}
#teamctl .fbtn.going{animation:switching 1.4s ease-in-out infinite}
#teamctl .fbtn.warn{color:var(--red);border-color:var(--red);padding:0 12px}
#teamctl .fbtn.idle{cursor:default}
#pagemode .fbtn{color:var(--text)}
#lock{color:var(--text)}
.tabbar{display:flex;flex-wrap:wrap;gap:6px;padding:10px 10px 0}
.tabbar button{--c:#888;display:flex;align-items:center;gap:6px;padding:4px 11px;border-radius:7px;border:1px solid var(--c);background:var(--c);min-height:28px;   /* min-height: as tall with an unseen count as without */
  color:#000;font:600 calc(12.5px*var(--fs,1)) var(--sans);cursor:pointer}
.tabbar button:hover{filter:brightness(1.15)}
.tabbar button.waiting{border:2px solid #ffb020;animation:alarm 1s ease-in-out infinite}
.cards{flex:1;min-height:0;display:grid;gap:10px;padding:10px;grid-auto-rows:minmax(0,1fr)}
.card{--c:#888;position:relative;min-height:0;display:flex;flex-direction:column;border-radius:11px;border:1px solid var(--line2);
  background:linear-gradient(180deg,var(--card1),var(--card2));overflow:hidden;cursor:pointer;transition:transform .15s,border-color .2s,box-shadow .2s}
.card:hover{transform:translateY(-1px);border-color:var(--hover)}
.card::before{content:"";position:absolute;inset:0 0 auto 0;height:3px;background:var(--c);opacity:.9}
.card.busy{box-shadow:0 0 0 1px #3fb95033,0 0 24px -8px #3fb95066}
/* a waiting agent is loud: the card's border and glow pulse amber, and its open question flashes inside its own border */
.card.waiting{border:2px solid #ffb020;animation:alarm 1s ease-in-out infinite}
.card.idle:not(.full) .feed{opacity:.8}
.card.off{opacity:.45}
/* an agent the page is starting or stopping fades in and out until it is up or its pane closes */
@keyframes switching{0%,100%{opacity:1}50%{opacity:.4}}
.switching{animation:switching 2.4s ease-in-out infinite}
.switching.waiting,.tabbar button.switching.waiting{animation:alarm 1s ease-in-out infinite,switching 2.4s ease-in-out infinite}
@keyframes alarm{0%,100%{border-color:#b87400;box-shadow:0 0 0 0 #ffb02000,0 0 10px 0 #ffb02044}50%{border-color:#ffc94d;box-shadow:0 0 0 4px #ffb02088,0 0 46px 6px #ffb020cc}}
@keyframes wash{0%,100%{opacity:.06}50%{opacity:.3}}
@keyframes pillflash{0%,100%{background:#8a5a00}50%{background:#ffc94d}}
@keyframes ask{0%,100%{border-color:#c2410c;box-shadow:0 0 0 0 #ff7a1a00}50%{border-color:#ff9a3c;box-shadow:0 0 0 4px #ff7a1a99,0 0 22px 2px #ff7a1aaa}}
.top{display:flex;align-items:center;gap:8px;padding:10px 12px 6px}
/* a badge's text sits a pixel high of centre, as the font's descender space otherwise shows it low */
.name{white-space:nowrap;background:var(--c);color:#000;font-weight:650;padding:0 8px 2px;border-radius:5px;font-size:calc(13.5px*var(--fs,1))}
/* Text on an agent's colour is the owner badge's: black in the dark theme, white in the light. */
.name,.tabbar button,#dbottom,.card .newest{color:var(--ownerfg)}
.role{color:var(--mute);font-size:calc(11.5px*var(--fs,1));white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.ticket{white-space:nowrap;flex:none;margin-left:auto;font:600 calc(11.5px*var(--fs,1)) var(--mono);color:var(--cyan);background:#39c5cf14;border:1px solid #39c5cf33;padding:1px 7px;border-radius:5px}
.row2{display:flex;align-items:center;gap:10px;white-space:nowrap;min-width:0;padding:0 12px 8px;font:calc(12px*var(--fs,1)) var(--mono);color:var(--mute)}
.state{display:flex;align-items:center;gap:6px;color:var(--text);font-family:var(--sans);font-weight:600}
.dot{width:8px;height:8px;border-radius:50%;background:var(--faint)}
.busy .dot{background:var(--green);animation:ping 1.4s infinite}
.waiting .dot{background:var(--amber)}
.waiting .state{color:var(--amber)}
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
.tabbar button.off .dot,.mini.off .name .dot{border-radius:1px;background:var(--ownerfg)}
@keyframes pingfg{0%{box-shadow:0 0 0 0 var(--ownerfg)}80%{box-shadow:0 0 0 5px var(--c)}100%{box-shadow:0 0 0 6px color-mix(in srgb,var(--c) 0%,transparent)}}
.ctx{display:flex;align-items:center;gap:6px;margin-left:auto}
.ctx .meter{width:64px;height:6px}
.model{color:var(--faint);overflow:hidden;text-overflow:ellipsis;min-width:0}
svg.spark{display:block;width:100%;height:26px;flex:none}
.feed{flex:1;min-height:0;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-end;gap:5px;padding:8px 12px 10px;border-top:1px solid var(--line);
  mask-image:linear-gradient(180deg,transparent,#000 28px)}
.it{display:flex;gap:7px;font-size:calc(12px*var(--fs,1));line-height:1.4;min-width:0}
.it .who{flex:none;font-weight:650;font-size:calc(10.5px*var(--fs,1));padding:1px 6px;border-radius:4px;height:fit-content;margin-top:1px;letter-spacing:.02em}
.it .tx{min-width:0;overflow:hidden;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:4;white-space:pre-line;color:var(--text2)}
.it.said .tx{color:var(--text)}
.it.owner .who{background:var(--ownerbg);color:var(--ownerfg)}
.it.l-auto,.it.l-team{border-left:2px solid var(--lanec);padding-left:7px}
.it.l-owner{padding-left:9px}
.it.l-auto{--lanec:var(--ownerbg)}
.it.l-team{--lanec:var(--pc,var(--line2))}
.it.l-auto{opacity:.55}
.it.l-owner.owner .tx{color:var(--text);font-weight:550}
.it.folded .tx{font-style:italic;color:var(--mute);-webkit-line-clamp:1}
.it.folded .tx .n{font-style:normal;color:var(--faint)}
#detail .conv .it.folded{cursor:pointer}
.lanes{margin-left:auto;flex:none}
/* the maximise button docked in the head's top-right corner, so it stays there when a narrow head wraps */
.card > .top:has(> .maxbtn){padding-right:34px}   /* the maximise button, 10px in, and 2px before it */
.card > .top > .maxbtn{position:absolute;top:10px;right:10px}
.card > .top > .lanes{align-self:flex-start}
.card > .top > .foldbtn{flex:none;align-self:flex-start;display:grid;place-items:center;width:22px;height:20px;margin-left:auto;border-radius:5px;color:var(--mute);cursor:pointer}
.card > .top > .foldbtn:hover{background:var(--on);color:var(--text)}
.card > .top > .foldbtn + .lanes{margin-left:0}
.card.folded > .row2,.card.folded > svg.spark{display:none}   /* folded: the name line alone, on every screen */
.card .top{flex-wrap:wrap;row-gap:4px}
.termseg b,.railseg b{padding:1px 5px;font-size:calc(10px*var(--fs,1))}
/* a filter button, flat like the maximise button; its sliders are in the text colour while something is left out */
.fbtn{flex:none;display:inline-flex;align-items:center;justify-content:center;gap:5px;min-width:22px;height:20px;border-radius:5px;color:var(--mute);cursor:pointer;font-weight:500}
.fbtn svg{width:13px;height:13px;stroke-width:1.5}
.fbtn:has(span){padding:0 6px}
.fbtn:hover{background:var(--on);color:var(--text)}
.fbtn.some{color:var(--text)}
.it.peer .who,.it.sent .who,.it.said .who{background:var(--pc,#444);color:var(--ownerfg)}
.it.sent .who::before{content:"→ "}
.it.event .tx{color:var(--mute);font-style:italic}
.it.event .who,.it.shell .who{color:var(--mute);border:1px solid var(--line2)}
.it.shell .tx{color:var(--mute)}
.it.ask{position:relative;z-index:1;flex-direction:column;gap:4px;padding:8px 10px;border:2px solid #ff7a1a;border-radius:8px;background:#ff7a1a1f;animation:ask 1s ease-in-out infinite}
.it.ask::after{content:"";position:absolute;inset:0;border-radius:6px;background:#ff7a1a;pointer-events:none;animation:wash 1s ease-in-out infinite}
.it.ask .who{align-self:flex-start;background:#ff7a1a;color:#000;text-transform:uppercase;letter-spacing:.06em}
.it.ask .tx{font:calc(12px*var(--fs,1))/1.35 var(--mono);white-space:pre-wrap;-webkit-line-clamp:unset;color:var(--text)}
.it.ask .ago{display:none}
.it.ask .opts{position:relative;z-index:1;display:flex;flex-wrap:wrap;gap:6px}
.it.ask .opt{padding:3px 10px;border-radius:6px;border:1px solid #ff7a1a;background:var(--box);color:var(--text);font:600 calc(12px*var(--fs,1)) var(--sans);cursor:pointer}
.it.ask .opt:hover{background:#ff7a1a40}
.it.ask .opt:disabled{opacity:.5;cursor:progress}
.it.ask .typed{display:flex;flex:1 1 220px;min-width:0}
.it.ask .askin{flex:1;min-width:0;padding:3px 8px;border:1px dashed #ff7a1a;border-right:0;border-radius:6px 0 0 6px;background:var(--box);color:var(--text);font:calc(12px*var(--fs,1)) var(--sans);outline:none}
.it.ask .askin:focus{border-style:solid;box-shadow:0 0 0 2px #ff7a1a40}
.it.ask .askin.failed{border-color:var(--red)}
.it.ask .opt.go{border-radius:0 6px 6px 0;padding:3px 9px}
.it.ask .reply{align-self:center;font:calc(11.5px*var(--fs,1)) var(--mono);color:var(--text2)}
.it.pending{align-items:flex-start;opacity:.8}
.it.pending .tx{flex:1}
.it.pending .badge{flex:none;font:600 calc(10px*var(--fs,1)) var(--mono);color:var(--amber);border:1px dashed var(--amber);border-radius:4px;padding:0 5px;margin-top:2px}
.it.live{align-items:center}
.it.live .who{color:var(--c,var(--green));border:1px solid var(--c,var(--green));animation:livepulse 1.4s ease-in-out infinite}
.it.live .tx{font:calc(11.5px*var(--fs,1)) var(--mono);color:var(--c,var(--green));-webkit-line-clamp:1}
.it.live .ago{display:none}
@keyframes livepulse{0%,100%{opacity:.45;box-shadow:none}50%{opacity:1;box-shadow:0 0 10px 1px var(--c,var(--green))}}
.it.tools .tx{font:calc(11px*var(--fs,1)) var(--mono);color:var(--faint);-webkit-line-clamp:1}
.it.tools .tx b{color:var(--mute);font-weight:600}
.it.tools .call{display:block}
.it.tools .call + .call{padding-left:1.35em}
.it.tools .call + .call{margin-top:2px}
.it .ago{flex:none;margin-left:auto;color:var(--faint);font:calc(10.5px*var(--fs,1)) var(--mono);padding-left:4px}
code{font:calc(11.5px*var(--fs,1)) var(--mono);background:var(--codebg);padding:0 4px;border-radius:4px;color:var(--text)}
code.flat{padding:0;background:none;color:var(--mute)}
.it.pics{flex-wrap:wrap}
.it .thumbs{flex-basis:100%;display:flex;flex-wrap:wrap;gap:6px;padding:2px 0 2px 2px}
.it .thumbs img{display:block;height:56px;max-width:120px;object-fit:cover;border-radius:5px;border:1px solid var(--line2)}
.it .thumbs a:hover img{border-color:var(--c,var(--hover))}
#detail .conv .it .thumbs img{height:auto;max-height:220px;max-width:360px;object-fit:contain}
#pop{position:fixed;z-index:20;display:none;max-width:560px;max-height:60vh;overflow:auto;padding:10px 13px;border-radius:9px;
  border:1px solid var(--line2);background:var(--box);color:var(--text);font-size:calc(12.5px*var(--fs,1));line-height:1.45;white-space:pre-line;box-shadow:0 14px 40px #0009}
#pop.on{display:block;cursor:pointer}
#lightbox{position:fixed;inset:0;z-index:40;display:none;align-items:center;justify-content:center;padding:40px;background:#000c;backdrop-filter:blur(3px)}
#lightbox.on{display:flex}
#lightbox figure{margin:0;display:flex;flex-direction:column;align-items:center;gap:8px;max-width:100%;max-height:100%}
#lbwrap{max-width:calc(100vw - 80px);max-height:calc(100vh - 130px);overflow:hidden;border-radius:8px;box-shadow:0 20px 60px #000a}
#lbwrap.zoomed{overflow:auto;cursor:grab}
#lbwrap.grab{cursor:grabbing}
#lightbox img{display:block;max-width:calc(100vw - 80px);max-height:calc(100vh - 130px);object-fit:contain;background:#fff;user-select:none}
#lbwrap.zoomed img{max-width:none;max-height:none}
#lightbox .zoom{display:flex;align-items:center;gap:4px}
#lightbox .zoom b{min-width:26px;padding:2px 8px;text-align:center;border:1px solid #fff4;border-radius:6px;color:#eee;cursor:pointer;font-weight:600}
#lightbox .zoom b:hover{background:#fff2}
#lbpct{min-width:44px;text-align:right;color:#aaa}
#lightbox figcaption{display:flex;gap:16px;font:calc(12px*var(--fs,1)) var(--mono);color:#ccc}
#lightbox figcaption a{color:#9cf}
#lightbox .x{position:fixed;top:16px;right:22px;color:#ccc;cursor:pointer;font-size:calc(20px*var(--fs,1));line-height:1}
#lightbox .x:hover{color:#fff}
#docbox{position:fixed;inset:0;z-index:40;display:none;align-items:center;justify-content:center;padding:40px;background:#000c;backdrop-filter:blur(3px)}
#docbox.on{display:flex}
#docbox .doc{display:flex;flex-direction:column;width:min(920px,100%);max-height:100%;border:1px solid var(--line2);border-radius:10px;background:var(--box);box-shadow:0 14px 40px #0009}
#docbox .dochead{display:flex;align-items:center;gap:14px;padding:10px 14px;border-bottom:1px solid var(--line);font:calc(12px*var(--fs,1)) var(--mono);color:var(--mute)}
#docname{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:var(--text)}
#docbox .dochead b{cursor:pointer;font-weight:600}
#docbox .dochead b:hover,#docbox .x:hover{color:var(--text)}
#docbox .dochead b.done{color:var(--green)}
#docall[hidden]{display:none}
#doctab{color:var(--cyan)}
#docbox .x{cursor:pointer;font-size:calc(18px*var(--fs,1));line-height:1}
#docbody{overflow:auto;padding:14px 18px;color:var(--text);font-size:calc(13.5px*var(--fs,1));line-height:1.55;white-space:pre-wrap;word-break:break-word}
:is(#docbody, .fdoc) b.h{margin:18px 0 8px;font-weight:600;line-height:1.25}
:is(#docbody, .fdoc) b.h:first-child{margin-top:0}
:is(#docbody, .fdoc) b.h1{padding-bottom:.3em;border-bottom:1px solid var(--line2);font-size:2em}
:is(#docbody, .fdoc) b.h2{padding-bottom:.3em;border-bottom:1px solid var(--line2);font-size:1.5em}
:is(#docbody, .fdoc) b.h3{font-size:1.25em}
:is(#docbody, .fdoc) b.h4{font-size:1.05em}
@media (max-width:600px){#docbox{padding:12px}}
pre.code{display:block;margin:5px 0;padding:7px 10px;font:calc(11.5px*var(--fs,1))/1.4 var(--mono);white-space:pre-wrap;word-break:break-word;background:var(--codebg);border:1px solid var(--line);border-radius:7px;color:var(--text)}
#detail pre.code{font-size:calc(12.5px*var(--fs,1));margin:6px 0}
pre.code{position:relative}
pre.code .copy{position:absolute;top:5px;right:5px;display:none;place-items:center;width:26px;height:24px;padding:0;border-radius:5px;border:1px solid var(--line2);background:var(--box);color:var(--mute);cursor:pointer}
pre.code:hover .copy{display:grid}
pre.code .copy:hover{color:var(--text);border-color:var(--hover)}
pre.code .copy.done{color:var(--green);border-color:var(--green)}
#copied{position:fixed;z-index:50;pointer-events:none;padding:3px 8px;border-radius:6px;background:var(--green);color:#000;font:600 calc(11px*var(--fs,1)) var(--sans);opacity:0;transition:opacity .25s}
#copied.on{opacity:1}
a.link{color:var(--cyan);text-decoration:underline;text-underline-offset:2px;word-break:break-all}
.mdtable{max-width:100%;overflow-x:auto;margin:4px 0}   /* a table wider than its turn scrolls sideways */
table.md{border-collapse:collapse;white-space:normal}
table.md th,table.md td{border:1px solid var(--line2);padding:2px 8px;text-align:left;vertical-align:top;min-width:8em}
table.md th{background:var(--line);font-weight:600}
.feed .it .tx{max-height:9em}
/* an agent pane's card: its longer conversation, every turn in full, scrolled */
.card.full .feed{overflow:auto;justify-content:flex-start;mask-image:none}
.card.full .feed > :first-child{margin-top:auto}
.card.full .it .tx{-webkit-line-clamp:unset;white-space:pre-wrap;max-height:none}
/* The Team pane: one transcript of the messages between agents, sender then recipient on each line. */
.teamlog{position:relative;flex:1;min-height:0;display:flex;flex-direction:column;border:1px solid var(--line2);border-radius:12px;background:var(--box);overflow:hidden}
.teamlog .thead{flex:none;display:flex;flex-wrap:wrap;align-items:center;gap:4px 8px;padding:10px 12px 6px;font-size:calc(13.5px*var(--fs,1));font-weight:650}
.teamlog .thead{position:relative;padding-right:34px}
.teamlog .thead .maxbtn{position:absolute;top:10px;right:10px}
.teamlog .thead > span:nth-child(2){flex:0 1 auto;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font:calc(11px*var(--fs,1)) var(--mono);font-weight:400;color:var(--mute)}
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
.teamlog .thead > .cnames{flex:1 1 0;display:flex;flex-wrap:wrap;gap:4px;overflow:visible;margin-top:2px;font:600 calc(12px*var(--fs,1)) var(--sans)}
.teamlog .thead .name{font-size:calc(12px*var(--fs,1));line-height:13px;padding:0 6px 2px;cursor:pointer}
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
.tabbar .away{opacity:.45;filter:grayscale(1)}   /* a meeting member who is not running */
.tabbar button.away{cursor:default}   /* an icon with its unseen count on its corner, clear of its clipping */
.icontabs .ftab .unseen{position:absolute;z-index:1;top:-6px;right:-7px;min-width:15px;height:15px;padding:0 4px;font-size:10px;line-height:15px;pointer-events:none;background:var(--ownerfg);color:var(--c);box-shadow:0 0 0 1px var(--c)}
.teamlog .thead > .cnames.iconrow{gap:10px}   /* clear of each other's outlines, which stand 4px out */
.teamlog .thead > .cnames.chrrow{gap:8px;margin:0 0 4px}
.teamlog .it[data-agent]{cursor:pointer}
.teamlog.combined .it.said{border-left:2px solid var(--pc,var(--line2));padding-left:7px}
/* in a wide pane the card's name, state and model lines sit on one row, and in a middling one on two, with a slimmer
   burn line under them */
.pbody{container-type:inline-size}
/* A full card in a grid pane is measured on its own, not by the pane */
.cards > .cell{container-type:inline-size;min-height:0;display:flex;flex-direction:column}
.cards > .cell > .card{flex:1}
.maxbtn{flex:none;display:grid;place-items:center;width:22px;height:20px;border-radius:5px;color:var(--mute);cursor:pointer}
.maxbtn:hover{background:var(--on);color:var(--text)}
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
  .card.full > .top > .name{grid-column:1;margin:10px 0 8px 12px}
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
b.h{display:block;margin-top:2px;font-weight:700}
.empty{color:var(--faint);font-style:italic;font-size:calc(12px*var(--fs,1))}
/* detail */
#detail{position:fixed;inset:0;display:none;background:#000a;backdrop-filter:blur(6px);z-index:9;padding:6vh 8vw}
#detail.open{display:flex}
#detail.docked{background:none;backdrop-filter:none;padding:14px;z-index:2}
#detail.docked .box{box-shadow:none;border-radius:14px}
#detail.docked .head .x{display:none}
html.only header,html.only footer,html.only #main,html.only #detail #drail,html.only #dhead :is(.railseg, .x){display:none}
html.only #detail{background:none;backdrop-filter:none;padding:0}
html.only #detail .box{grid-template-columns:minmax(0,1fr);grid-template-rows:auto minmax(0,1fr);border:0;border-radius:0;box-shadow:none}
html.only #detail .box .left{grid-column:1;grid-row:2}
#detail .mini:not(.cur)::before,.others .mini::before{display:none}
#detail .box{--c:#888;--thumb:340px;--rail:220px;position:relative;flex:1;display:grid;grid-template-columns:minmax(0,1fr) var(--rail);grid-template-rows:auto minmax(0,1fr);border:1px solid var(--line2);border-radius:16px;background:var(--box);overflow:hidden;box-shadow:0 30px 80px #000c}
#detail .head{grid-column:1/-1;display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid var(--line);border-top:3px solid var(--c)}
#detail .head .lanes + .x{margin-left:14px}
#emo{position:fixed;display:none;z-index:60;min-width:220px;max-width:340px;padding:4px;border:1px solid var(--line2);border-radius:9px;background:var(--box);box-shadow:0 12px 30px #0008;font:calc(12px*var(--fs,1)) var(--mono);color:var(--text2)}
#emo div{display:flex;align-items:center;gap:8px;padding:3px 8px;border-radius:6px;cursor:pointer;white-space:nowrap}
#emo div span{font-size:calc(16px*var(--fs,1));width:20px;text-align:center}
#emo div.on,#emo div:hover{background:var(--on);color:var(--text)}
#detail .head #dmore + .x{margin-left:10px}
#detail .head .termseg{margin-left:auto;flex:none}
#detail .head .termseg + .railseg,#detail .head .railseg + .lanes{margin-left:8px}
#detail .box.noterm .termwrap{display:none}
#detail .box.noterm .conv{padding-right:16px}
/* the header keeps its name, role and switches whole; the facts take the room left and drop whole, from the end,
   when there is not room for them all */
#detail .head > *{flex:none;white-space:nowrap}
#detail .head .facts{flex:1 1 0;display:flex;flex-wrap:wrap;align-items:center;gap:40px 14px;height:18px;margin-left:10px;min-width:0;overflow:hidden;white-space:nowrap;font:calc(12px*var(--fs,1))/18px var(--mono);color:var(--mute)}
#detail .head .facts > *{flex:none}
#detail .head .facts .state{display:flex;align-items:center;gap:6px;color:var(--text)}
#detail .head .x{margin-left:auto;color:var(--mute);cursor:pointer;font-size:calc(20px*var(--fs,1));line-height:1}
/* every other agent in a column on the right, compressed to its status; a click moves to it. The header's edge
   button moves the column to the bottom, the left or the top, where the cards wrap in rows across the view. */
#detail .rail{grid-column:2;grid-row:2;min-height:0;overflow:auto;padding:10px;display:flex;flex-direction:column;gap:8px;border-left:1px solid var(--line)}
#detail .left{grid-column:1;grid-row:2}
#detail .box.rail-left{grid-template-columns:var(--rail) minmax(0,1fr)}
/* Characters: every agent as a portrait tile, in a custom pane */
/* the tiles' panel follows the pane's rounded corners: the bottom two under the pane bar, all four when locked */
.chrs{border-radius:0 0 13px 13px;flex:1;min-height:0;overflow:auto;scrollbar-gutter:stable;display:grid;grid-template-columns:repeat(auto-fill,112px);grid-auto-rows:112px;gap:8px;padding:12px 3px 12px 12px;align-content:start;background:var(--chpanel)}
.pane > .pbody:first-child > .chrs{border-radius:13px}
.chr{--c:#888;position:relative;width:112px;height:112px;padding:0;border-radius:10px;border:1px solid var(--line2);border-bottom:3px solid var(--c);
  background:var(--chtile);color:var(--chmute);font:calc(10px*var(--fs,1))/1 var(--mono);cursor:pointer;overflow:hidden}
.chr:hover{filter:brightness(1.08)}
.chr.off{opacity:.5}
.chr.waiting{animation:alarm 1s ease-in-out infinite}
.chr .por{position:absolute;left:18px;top:12px;width:76px;height:76px}
.chr .por img{width:100%;height:100%;object-fit:cover;border-radius:14px;display:block}
.chr .por svg{width:100%;height:100%;display:block;overflow:visible}
/* the agent's name, on the chest of its portrait or shadow */
.chr .nm{position:absolute;left:50%;top:68px;transform:translateX(-50%);max-width:86px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;
  padding:1px 5px;border-radius:5px;border:1px solid var(--c);font:700 calc(10px*var(--fs,1))/1.3 var(--sans);color:var(--text);background:color-mix(in srgb,var(--c) 30%,var(--chtile))}
/* clear of a clipboard on the right */
.chr .nm.left{left:41px;max-width:50px}
.chr .tl{position:absolute;top:6px;left:7px;display:flex;align-items:center;gap:4px}
.chr .tl i{--reach:7px;width:6px;height:6px;border-radius:50%;background:var(--faint)}
.chr .tl i.now{background:var(--green)}
.chr.busy .tl i{background:var(--green);animation:ping 1.4s infinite}
.chr.waiting .tl i{--pulse:var(--amber);background:var(--amber);animation:ping 1.4s infinite}
.chr.compacting .tl i{--pulse:var(--cyan);background:var(--cyan);animation:ping 1.4s infinite}
.chr .tr{position:absolute;top:5px;right:6px;display:flex;flex-direction:column;align-items:flex-end;gap:3px}
.chr .tr b{font:700 calc(11px*var(--fs,1))/1 var(--mono);color:var(--text)}
.chr .tr b.hi{color:var(--chhigh)}
.chr .tr .unseen{min-width:16px;height:16px;padding:0 4px;font:700 calc(9.5px*var(--fs,1))/16px var(--sans);background:var(--c);color:var(--ownerfg)}
/* the activity line runs the width of the tile; the ticket, whole, sits over its left end */
.chr .tk{position:absolute;z-index:1;left:5px;bottom:6px;max-width:calc(100% - 10px);white-space:nowrap;padding:2px 3px;border-radius:4px;
  font-size:calc(9px*var(--fs,1));color:var(--chmute);background:color-mix(in srgb,var(--chtile) 65%,transparent)}
.chr .sp{position:absolute;left:5px;right:5px;bottom:5px;height:16px}
.chr .sp svg.spark{height:16px}
/* the page's menu: a Characters tile's (the agent, then ways to open it) or a filter button's (the lanes, ticked when shown) */
#menu{position:fixed;z-index:60;min-width:150px;padding:5px;border:1px solid var(--line2);border-radius:10px;background:var(--box);
  box-shadow:0 12px 32px #0007;font:calc(12.5px*var(--fs,1)) var(--sans);color:var(--text);display:none}
#menu.on{display:block}
#menu[data-key^="agent:"]{width:236px}
#menu .sep{margin:4px 0;border-top:1px solid var(--line)}
#menu .mi.off{cursor:default;color:var(--mute)}
#menu .mi.off:hover{background:none}
#menu .mi.warn{color:var(--red)}
#menu .mi.warn svg{color:var(--red)}
#menu .ask{padding:6px 8px 4px;font-size:calc(11.5px*var(--fs,1));line-height:1.45;color:var(--mute);white-space:normal}
#menu .hd{padding:5px 8px 8px;margin-bottom:4px;border-bottom:1px solid var(--line)}
#menu .hd .name{display:inline-block;margin-bottom:4px}
#menu .hd div{font-size:calc(11.5px*var(--fs,1));color:var(--mute);line-height:1.45}
#menu .mi{display:flex;align-items:center;gap:9px;padding:6px 8px;border-radius:6px;cursor:pointer;white-space:nowrap}
#menu .mi:hover,#menu .mi.at{background:var(--on)}
#menu[data-key="help"]{width:340px}
.it .tx{zoom:var(--conv,1)}
#menu .set{display:flex;align-items:center;gap:12px;padding:3px 8px;font-size:calc(12px*var(--fs,1));color:var(--mute)}
#menu .set select{margin-left:auto;font:calc(12px*var(--fs,1)) var(--sans);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:6px;padding:1px 4px}
#menu button[data-reset]{margin:6px 8px 2px;font:calc(12px*var(--fs,1)) var(--sans);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:6px;padding:2px 10px;cursor:pointer}
#slash{display:none;position:fixed;z-index:70;max-height:50vh;overflow:auto;padding:4px;border:1px solid var(--line2);border-radius:10px;background:var(--box);box-shadow:0 8px 28px #0006}
#slash .sl{display:flex;gap:10px;align-items:baseline;padding:4px 8px;border-radius:6px;cursor:pointer;font-size:calc(12px*var(--fs,1)*var(--boxfs,1));min-width:0}
#slash .sl b{flex:none;font:600 calc(12px*var(--fs,1)*var(--boxfs,1)) var(--mono);color:var(--text)}
#slash .sl span{color:var(--mute);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
#slash .sl.at{background:var(--soft)}
#menu .sc{display:flex;align-items:baseline;gap:12px;padding:3px 8px;font-size:calc(12px*var(--fs,1));color:var(--mute)}
#menu .sc kbd{flex:none;margin-left:auto;padding:1px 6px;border:1px solid var(--line2);border-radius:5px;font:calc(11px*var(--fs,1)) var(--mono);color:var(--text);white-space:nowrap}
#menu .hd:has(.spark){min-width:200px}
#menu .hd .spark{width:100%;margin:5px 0 2px}
#menu .hd .hrow{display:flex;align-items:flex-start;gap:10px;color:inherit}
#menu .hd .htxt{flex:1;min-width:0;font-size:inherit;color:inherit}
#menu .mpor{flex:none;width:96px;height:96px}
#menu .mpor img{display:block;width:100%;height:100%;object-fit:cover;border-radius:8px;position:relative;transform-origin:top right;transition:transform .15s ease}
#menu .mpor:hover img{z-index:2;transform:scale(2.67);box-shadow:0 12px 32px #0009}   /* the mouse over it shows it at full size, in place */
#menu .hd:last-child{margin-bottom:0;border-bottom:0}
#menu .hd ~ .hd{margin-top:6px;border-top:1px solid var(--line);padding-top:8px}
#menu .mi svg{flex:none;width:14px;height:14px;color:var(--mute)}
#menu .mi svg.off{visibility:hidden}
#menu .mi svg.tick{margin-left:auto}
#menu .mi .dot{flex:none;width:10px;height:10px;margin:0 2px;border-radius:50%;background:var(--c)}
#menu .mi kbd{margin-left:auto;font:calc(10.5px*var(--fs,1)) var(--mono);color:var(--mute)}
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
.mini{--c:#888;position:relative;flex:none;padding:8px 10px 4px;border-radius:9px;border:1px solid var(--line2);background:linear-gradient(180deg,var(--card1),var(--card2));
  cursor:pointer;overflow:hidden;transition:border-color .15s}
.mini::before{content:"";position:absolute;inset:0 0 auto 0;height:2px;background:var(--c)}
.mini:hover{border-color:var(--c)}
.mini.waiting{border:2px solid #ffb020;animation:alarm 1s ease-in-out infinite}
.mini.off,.tabbar button.off{opacity:.45}
.mini.cur:not(.waiting){border-color:var(--c)}
.mini.cur{box-shadow:inset 3px 0 0 var(--c);cursor:default}
.mini .mtop{display:flex;align-items:center;gap:6px;font:calc(11px*var(--fs,1)) var(--mono);color:var(--mute);white-space:nowrap;min-width:0}
.unseen{flex:none;min-width:18px;height:18px;padding:0 5px;border-radius:9px;background:var(--c);color:var(--ownerfg);font:700 calc(10.5px*var(--fs,1))/18px var(--sans);text-align:center}
.tabbar .unseen{margin-left:6px;background:var(--ownerfg);color:var(--c)}   /* the tab text's colour, so it follows the theme */
/* One line: name (with its state dot and unseen count, as a tab), ticket, how long, context; the ticket gives way. */
.mini .name{flex:none;display:flex;align-items:center;gap:5px;font-family:var(--sans);font-size:calc(12px*var(--fs,1));line-height:13px;padding:2px 6px 2px;min-height:19px}   /* as tall with an unseen count as without, as a tab is */
.mini .name .dot{flex:none}
.mini .name .unseen{min-width:15px;height:15px;padding:0 4px;font-size:calc(10px*var(--fs,1));line-height:15px;background:var(--ownerfg);color:var(--c)}
.mini .ticket{flex:0 1 auto;min-width:0;margin-left:0;overflow:hidden;text-overflow:ellipsis;font-size:calc(10.5px*var(--fs,1));padding:0 5px}
.mini .mtop .ago,.mini .mtop .pct{flex:none}
.mini .mtop .pct{margin-left:auto}
.mini svg.spark{height:16px;margin-top:3px}
.mini:not(:has(svg.spark)){padding-bottom:8px}   /* with no sparkline, as much space below the name as above */
/* The List pane's cards, and the pop-up's side rail, share their height: when there are more agents than room,
   each card's line shrinks first, down to its name row, and only then does the list scroll. */
.others .mini,#detail .box:not(.rail-top):not(.rail-bottom) .rail .mini{flex:0 1 auto;min-height:32px;display:flex;flex-direction:column}
.others .mini svg.spark,#detail .box:not(.rail-top):not(.rail-bottom) .rail .mini svg.spark{flex:0 1 16px;min-height:0;height:auto}
#detail .left{position:relative;display:flex;flex-direction:column;min-height:0;min-width:0}
#dbottom,.card .newest,.teamlog .newest{position:absolute;left:50%;bottom:64px;transform:translateX(-50%);z-index:3;display:none;padding:5px 14px;border-radius:16px;
  border:1px solid var(--c,var(--line2));background:var(--c,var(--line2));color:#000;font:600 calc(12px*var(--fs,1)) var(--sans);cursor:pointer;box-shadow:0 6px 18px #0007}
#dbottom.on,.card .newest.on,.teamlog .newest.on{display:block}
#dbottom:hover,.card .newest:hover,.teamlog .newest:hover{filter:brightness(1.15)}
.teamlog .chat{flex:none;border-top:1px solid var(--line);padding-top:8px}
.teamlog .chead{display:flex;align-items:center;gap:6px;margin:0 10px 6px}
.teamlog .chead .face{width:26px;height:26px;border-radius:6px;border-bottom-width:2px}
.teamlog .chead .name{font-size:calc(12px*var(--fs,1));line-height:13px;padding:0 6px 2px}
.teamlog .chead .pick{cursor:pointer}
.combined .cnames [data-name]{user-select:none}   /* a double-click opens a chat, not a selection */
.pbody > .ctabs{flex:none;display:flex;flex-wrap:wrap;align-items:flex-end;gap:2px;margin:6px 12px 6px;border-bottom:1px solid var(--line)}
.ctabs .ctab{display:flex;align-items:center;gap:6px;padding:4px 10px 5px;margin-bottom:-1px;border:1px solid transparent;border-bottom:none;
  border-radius:7px 7px 0 0;font:600 calc(12px*var(--fs,1)) var(--sans);color:var(--mute);cursor:pointer;user-select:none}
.ctabs .ctab:hover{color:var(--text)}
/* the custom views beside the View button: a row of small tabs with + at its end */
#menu .vmi .vname{flex:1}
.meetbar{display:flex;align-items:center;gap:8px;padding:6px 13px;font-size:calc(12px*var(--fs,1));color:var(--mute)}
.meetbar span{margin-right:auto}
.meetbar.ask span,.meetbar.on b{color:var(--text)}
.meetbar.on{border-bottom:1px solid var(--line)}
.meetbar + .icontabs{padding:6px 13px 10px}   /* the faces under the bar, in line with its text and clear of the conversation below */
#menu .mi .mute{color:var(--mute)}
.meetbar .mbtn{display:inline-flex;align-items:center;gap:5px;padding:2px 10px;border:1px solid var(--line2);border-radius:999px;color:var(--text);cursor:pointer}
.meetbar .mbtn:hover{background:var(--on)}
.meetbar .mbtn.warn{color:var(--red);border-color:var(--red)}
.meetbar .mbtn svg{width:12px;height:12px}
#menu .mi .dot.hollow{background:none;border:2px solid var(--c);width:8px;height:8px}
#menu .vmi .vico{display:inline-flex;align-items:center;border-radius:4px}
#menu .vmi .vico.pick{padding:2px;margin:-3px;border:1px solid var(--line2);cursor:pointer}
#menu .vmi .vico.pick::after{content:"";margin-left:2px;border:3px solid transparent;border-top-color:var(--mute);transform:translateY(2px)}
#menu .vicons{display:grid;grid-template-columns:repeat(7,22px);gap:2px;padding:4px 8px 6px 28px}
#menu .vicons i{display:flex;align-items:center;justify-content:center;height:22px;border-radius:5px;cursor:pointer}
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
.ctabs .ctname{width:9em;padding:0 4px;font:inherit;color:var(--text);background:var(--bg);border:1px solid var(--line2);border-radius:4px;outline:none}
#menu .mi .face{width:20px;height:20px;border-radius:4px;border-bottom-width:2px}
.teamlog.combined{container:sayroom/size}
.teamlog .chead .x{margin-left:auto;display:flex;padding:3px;border-radius:5px;color:var(--mute);cursor:pointer}
.teamlog .chead .x:hover{color:var(--text);background:var(--line2)}
.teamlog .chead .x svg{width:14px;height:14px}
.teamlog .newest{--c:var(--ownerbg);color:var(--ownerfg)}
#detail .conv{flex:1;min-height:0;overflow:auto;padding:14px calc(var(--thumb) + 40px) 14px 16px;display:flex;flex-direction:column;gap:9px}
.sayrow{flex:none;display:flex;align-items:flex-start;gap:6px;margin:0 10px 10px}
.say{flex:1;min-width:0;display:block;margin:0;padding:6px 10px;border-radius:8px;border:1px solid var(--line2);background:var(--soft);
  color:var(--text);font:calc(12.5px*var(--fs,1)*var(--boxfs,1))/1.4 var(--sans);outline:none;transition:border-color .15s,box-shadow .15s;resize:none;overflow-y:hidden;max-height:120px}
.say::placeholder{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--faint)}
.say:focus{border-color:var(--c);box-shadow:0 0 0 3px color-mix(in srgb,var(--c) 25%,transparent)}
.say.sent{border-color:var(--green)}
.say.failed{border-color:var(--red)}
.say{padding-right:34px}
.send{flex:none;align-self:flex-end;position:relative;z-index:1;width:25px;height:25px;margin:0 3px 3px calc(-6px - 28px);padding:0;border:0;border-radius:6px;
  background:var(--ownerbg);color:var(--ownerfg);cursor:pointer;opacity:.85}   /* inside the box: the row's gap and its own width pulled back over the box's end */
.send::before{content:"";position:absolute;inset:0;margin:auto;width:9px;height:9px;transform:translateY(2px) rotate(45deg);border:solid currentColor;border-width:2px 0 0 2px}
.send:hover{opacity:1}
#detail .say{padding-right:42px}
#detail .send{width:31px;height:31px;margin:0 4px 4px calc(-6px - 35px)}
#detail .sayrow{margin:0 14px 14px}
#detail .box:not(.noterm) .sayrow{margin-right:calc(var(--thumb) + 40px)}
.add{flex:none;position:relative;width:31px;height:31px;padding:0;border-radius:8px;border:1px solid var(--line2);background:var(--soft);color:var(--mute);cursor:pointer}
.add::before,.add::after{content:"";position:absolute;inset:0;margin:auto;width:12px;height:1.5px;border-radius:1px;background:currentColor}
.add::after{width:1.5px;height:12px}
.add:hover{color:var(--text);border-color:var(--hover)}
.att{display:flex;flex-wrap:wrap;gap:8px;margin:0 10px 6px}
.att:empty{display:none}
#detail .att{margin:0 14px 8px}
.att span{position:relative;flex:none}
.att img{display:block;height:48px;max-width:120px;object-fit:cover;border-radius:6px;border:1px solid var(--line2)}
.att b{position:absolute;top:3px;right:3px;width:18px;height:18px;display:grid;place-items:center;border-radius:4px;background:#000a;color:#fff;font-size:calc(11px*var(--fs,1));font-weight:400;cursor:pointer}
.att b:hover{background:#000d}
.att .file{height:48px;display:inline-block;max-width:220px;padding:0 30px 0 10px;border-radius:6px;border:1px solid var(--line2);
  font:calc(12px*var(--fs,1))/46px var(--mono);color:var(--mute);overflow:hidden;white-space:nowrap;text-overflow:ellipsis}   /* a file that is not an image: its name */
.att .file b{line-height:normal}
#detail .say{padding:9px 12px;font-size:calc(13.5px*var(--fs,1)*var(--boxfs,1));max-height:35vh}
/* where a card or the agent's own view is tall enough, its box starts three lines tall */
.card,#detail .left{container:sayroom/size}
@container sayroom (min-height:360px){.say{min-height:calc(4.2em + 14px)} #dsay{min-height:calc(4.2em + 20px)}}
.stop.going{cursor:default;animation:stopping .9s ease-in-out infinite}
@keyframes stopping{50%{opacity:.3}}
.stop{flex:none;position:relative;width:31px;height:31px;border-radius:8px;border:1px solid var(--line2);background:var(--soft);cursor:pointer}
.stop::before{content:"";position:absolute;inset:0;margin:auto;width:10px;height:10px;border-radius:2px;background:var(--text)}
.stop:hover{border-color:var(--red)}
.stop:hover::before{background:var(--red)}
#detail .stop,#detail .add{width:39px;height:39px}
#detail .stop::before{width:12px;height:12px}
#detail .conv .it{font-size:calc(13px*var(--fs,1))}
#detail .conv .it .tx{-webkit-line-clamp:unset;white-space:pre-wrap}
#detail .conv .it.tools .tx{white-space:normal}
/* the pane as a live thumbnail at the top right, in a terminal window of its own shape; a click expands it over
   the whole window over a dimmed page, as large as fits, as an image does */
:is(#detail,.card.full) .termwrap{position:absolute;top:14px;right:16px;z-index:2;cursor:zoom-in}
:is(#detail,.card.full) .termwrap:hover .term{border-color:var(--c)}
:is(#detail,.card.full) .termwrap.big{position:fixed;inset:0;z-index:40;display:flex;justify-content:center;align-items:center;padding:40px;cursor:default;
  background:#000c;backdrop-filter:blur(3px)}
:is(#detail,.card.full) .termwrap .x{display:none;position:fixed;top:16px;right:22px;color:#ccc;cursor:pointer;font-size:calc(20px*var(--fs,1));line-height:1}
:is(#detail,.card.full) .termwrap.big .x{display:block}
:is(#detail,.card.full) .termwrap .x:hover{color:#fff}
:is(#detail,.card.full) .term{display:flex;flex-direction:column;border-radius:10px;overflow:hidden;background:#06080b;border:1px solid #ffffff1f;box-shadow:0 18px 50px #0008;transition:border-color .15s}
:is(#detail,.card.full) .bar{flex:none;display:flex;align-items:center;gap:7px;padding:8px 12px;background:#161b22;border-bottom:1px solid #ffffff14;font:calc(12px*var(--fs,1)) var(--sans);color:#8b949e}
:is(#detail,.card.full) .bar i{width:11px;height:11px;border-radius:50%;background:#ff5f57}
:is(#detail,.card.full) .bar i:nth-child(2){background:#febc2e}:is(#detail,.card.full) .bar i:nth-child(3){background:#28c840;margin-right:8px}
:is(#detail,.card.full) .bar span{flex:1;text-align:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
:is(#detail,.card.full) .bar b{cursor:pointer;font-weight:400;font-size:calc(14px*var(--fs,1));padding:0 2px;color:#8b949e}
:is(#detail,.card.full) .bar b:hover{color:#e6edf3}
:is(#detail,.card.full) .screen{overflow:hidden;padding:10px}
#dscreen,.card.full .termwrap pre{margin:0;font-family:var(--mono);line-height:1.25;color:#d1d7e0;white-space:pre;overflow:hidden}
::-webkit-scrollbar{width:9px;height:9px}::-webkit-scrollbar-thumb{background:var(--thumb);border-radius:9px}
/* On a phone (owner, 2026-11-01: "move to the mobile experience"): the bars wrap; Grid's sections stand one under
   another, two cards across, and the page scrolls; an agent's view fills the screen, the others one row along its
   top to swipe, and no terminal; a custom view's panes stand one under another. A box's text is 16px, under which
   a phone zooms the page when it is tapped. */
@media (max-width:700px){
  header,footer{flex-wrap:wrap;gap:10px 14px;padding:8px 12px}
  .bi.tight + .bi.tight,.bi:not(.tight) + .bi.tight{margin-left:0}
  .bi[data-item=bench]{flex:1 1 100%}
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
</style>
</head>
<body>
<header>
  <div class="bi" data-item="brand"><div class="brand" title="Claude agents"><svg class="dk" width="40" height="40" aria-label="Agent hub" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><rect width="200" height="200" rx="45" fill="#12161C"/><g stroke="#5EEAD4" stroke-width="6" stroke-linecap="round" opacity="0.5"><line x1="100" y1="100" x2="50" y2="50"/><line x1="100" y1="100" x2="150" y2="50"/><line x1="100" y1="100" x2="50" y2="150"/><line x1="100" y1="100" x2="150" y2="150"/></g><circle cx="50" cy="50" r="15" fill="#5EEAD4"/><circle cx="150" cy="50" r="12" fill="#12161C" stroke="#5EEAD4" stroke-width="6"/><circle cx="50" cy="150" r="15" fill="#5EEAD4"/><circle cx="150" cy="150" r="15" fill="#5EEAD4"/><circle cx="100" cy="100" r="36" fill="#F4F4F0"/><path d="M85 87 L98 100 L85 113" fill="none" stroke="#12161C" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/><line x1="103" y1="114" x2="117" y2="114" stroke="#12161C" stroke-width="8" stroke-linecap="round"/></svg><svg class="lt" width="40" height="40" aria-label="Agent hub" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><rect x="1.5" y="1.5" width="197" height="197" rx="44" fill="#F4F4F0" stroke="#D6D6CF" stroke-width="3"/><g stroke="#0D9488" stroke-width="6" stroke-linecap="round" opacity="0.5"><line x1="100" y1="100" x2="50" y2="50"/><line x1="100" y1="100" x2="150" y2="50"/><line x1="100" y1="100" x2="50" y2="150"/><line x1="100" y1="100" x2="150" y2="150"/></g><circle cx="50" cy="50" r="15" fill="#0D9488"/><circle cx="150" cy="50" r="12" fill="#F4F4F0" stroke="#0D9488" stroke-width="6"/><circle cx="50" cy="150" r="15" fill="#0D9488"/><circle cx="150" cy="150" r="15" fill="#0D9488"/><circle cx="100" cy="100" r="36" fill="#12161C"/><path d="M85 87 L98 100 L85 113" fill="none" stroke="#F4F4F0" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/><line x1="103" y1="114" x2="117" y2="114" stroke="#F4F4F0" stroke-width="8" stroke-linecap="round"/></svg></div></div>
  <div class="bi" data-item="tally"><div class="counts" id="counts"></div><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi" data-item="bench"><div class="bench" id="bench"></div><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="controls"><span id="teamctl"></span><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="lanes"><span id="pagelanes"></span><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="view"><span id="pagemode"></span></div>
  <div class="bi tight" data-item="lock"><b class="fbtn" id="lock"></b></div>
  <div class="bi tight" data-item="theme"><span class="pill btn" id="theme" title="Light or dark"></span><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="settings"><b class="fbtn" id="settings" data-menu="settings" title="Settings"><svg viewBox="0 0 16 16" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round"><path d="M13.16 6.40 L14.90 6.82 L14.90 9.18 L13.16 9.60 L12.78 10.52 L13.72 12.04 L12.04 13.72 L10.52 12.78 L9.60 13.16 L9.18 14.90 L6.82 14.90 L6.40 13.16 L5.48 12.78 L3.96 13.72 L2.28 12.04 L3.22 10.52 L2.84 9.60 L1.10 9.18 L1.10 6.82 L2.84 6.40 L3.22 5.48 L2.28 3.96 L3.96 2.28 L5.48 3.22 L6.40 2.84 L6.82 1.10 L9.18 1.10 L9.60 2.84 L10.52 3.22 L12.04 2.28 L13.72 3.96 L12.78 5.48 Z"/><circle cx="8" cy="8" r="2.2"/></svg></b><i class="bx" title="Take this out of the bar">✕</i></div>
  <div class="bi tight" data-item="help"><b class="fbtn" id="help" data-menu="help" title="Keyboard shortcuts (?)">?</b><i class="bx" title="Take this out of the bar">✕</i></div>
</header>
<main id="main"></main>
<footer></footer>
<div id="barbin" hidden><div class="bi gap" data-item="gap1"><i class="bx" title="Take this out of the bar">✕</i></div><div class="bi gap" data-item="gap2"><i class="bx" title="Take this out of the bar">✕</i></div><div class="bi gap" data-item="gap3"><i class="bx" title="Take this out of the bar">✕</i></div></div>
<div id="pop"></div><div id="menu"></div><div id="copied">Copied</div>
<div id="lightbox"><figure><div id="lbwrap"><img id="lbimg" alt="" draggable="false"></div><figcaption><span id="lbname"></span><span class="zoom"><b id="lbout" title="Zoom out (−)">−</b><b id="lbfit" title="Fit to the window (0)">Fit</b><b id="lbin" title="Zoom in (+)">+</b><span id="lbpct"></span></span><a id="lbtab" target="_blank" rel="noopener">Open in a new tab</a></figcaption></figure><span class="x" id="lbx" title="Close (Esc)">✕</span></div>
<div id="docbox"><div class="doc"><div class="dochead"><span id="docname"></span><b id="doccopy" title="Copy the path">Copy path</b><b id="docall" title="Copy the whole document" hidden>Copy all</b><a id="doctab" target="_blank" rel="noopener">Open as text</a><span class="x" id="docx" title="Close (Esc)">✕</span></div><div id="docbody"></div></div></div>
<div id="detail"><div class="box"><div class="head" id="dhead"></div><div class="left"><div class="conv" id="dconv"></div><button id="dbottom" title="Back to the newest turn">↓ Newest</button><div class="att" id="datt"></div><div class="sayrow" id="dsayrow"><button class="add" id="dadd" title="Add images or files (Ctrl+U)"></button><textarea class="say" id="dsay" rows="1" autocomplete="off"></textarea><button class="send" title="Send (Enter)"></button><button class="stop" id="dstop" title="Stop this turn, as Esc does in the terminal"></button></div><div class="termwrap" id="dterm" title="Expand"><div class="term"><div class="bar"><i></i><i></i><i></i><span id="dtitle"></span><b id="dzoom">⤢</b></div><div class="screen" id="dscr"><pre id="dscreen"></pre></div></div><span class="x" id="dtx" title="Close (Esc)">✕</span></div></div><div class="rail" id="drail"></div></div></div>
<script>
const $ = s => document.querySelector(s);
const ONLY = new URLSearchParams(location.search).has("only");
if (ONLY) document.documentElement.classList.add("only");
// Light or dark, remembered in this browser; dark unless chosen.
// The favicon follows the page's theme too: the dark icon is in the page head, the light one here.
const FAVICON = {dark: document.querySelector("link[rel=icon]").href, light: "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 200 200'%3E%3Crect x='1.5' y='1.5' width='197' height='197' rx='39' fill='%23F4F4F0' stroke='%23D6D6CF' stroke-width='3'/%3E%3Ccircle cx='52' cy='52' r='28' fill='%230D9488'/%3E%3Ccircle cx='148' cy='52' r='28' fill='%230D9488'/%3E%3Ccircle cx='52' cy='148' r='28' fill='%230D9488'/%3E%3Ccircle cx='148' cy='148' r='28' fill='%230D9488'/%3E%3Ccircle cx='100' cy='100' r='40' fill='%2312161C'/%3E%3C/svg%3E"};
function theme(t) { document.documentElement.classList.toggle("light", t === "light"); document.querySelector("link[rel=icon]").href = FAVICON[t] || FAVICON.dark; localStorage.setItem("theme", t); $("#theme").textContent = t === "light" ? "☾ Dark" : "☀ Light"; }
theme(new URLSearchParams(location.search).get("theme") || localStorage.getItem("theme") || "dark");
$("#theme").onclick = () => theme(document.documentElement.classList.contains("light") ? "dark" : "light");
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
// The little Markdown agents write: ``` fenced blocks, tables, # headings, - bullets, `code` and **bold**; web
// addresses become links, and so do full paths to documents the page can show (DOC_TYPES on the server).
const DOC = /(^|[\s(>])((?:~|\/home)\/[^\s<>"'`()]+\.(?:md|markdown|txt|sql|log))(?=$|[\s<).,;:!?])/gim;
const inline = s => esc(s)
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
const md = (s, flat) => String(s ?? "").split(/```[^\n]*\n?/)
  .map((part, i) => !(i % 2) ? prose(part) : flat ? `<code class="flat">${esc(part.replace(/\n$/, ""))}</code>\n`
    : `<pre class="code">${esc(part.replace(/\n$/, ""))}${COPY}</pre>`).join("");
const ago = s => s == null ? "" : s < 60 ? s + "s" : s < 3600 ? Math.floor(s / 60) + "m" : s < 86400 ? Math.floor(s / 3600) + "h" : Math.floor(s / 86400) + "d";
const k = n => n == null ? "–" : n < 1000 ? "" + n : n < 1e6 ? (n / 1000).toFixed(n < 1e5 ? 1 : 0) + "k" : (n / 1e6).toFixed(1) + "M";
const gauge = p => p == null ? "var(--faint)" : p >= 85 ? "var(--red)" : p >= 60 ? "var(--amber)" : "var(--green)";
const STATE = {busy: "working", waiting: "waiting", idle: "idle", shell: "in shell", off: "not running", compacting: "compacting", bench: "on the bench"};
// what an agent is doing, for its classes and words: not running, compacting, or its session's own status
const stOf = a => !a.live ? "off" : a.compacting ? "compacting" : a.status;
let S = null, colours = {}, open = null;

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
  const was = b.textContent;
  b.textContent = "Copied"; b.classList.add("done");
  setTimeout(() => { b.textContent = was; b.classList.remove("done"); }, 1200);
}
$("#doccopy").onclick = e => docCopy(e.target, $("#docname").textContent);
$("#docall").onclick = e => docCopy(e.target, docText);
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
  const ag = to => tag ? (it._agents || [agent]).map(x => `<span class="who ag${to ? " to" : ""}" style="--pc:${colours[x] || "#888"}">${esc(x)}</span>`).join("") : "";
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
  const pics = thumbs(it.text, it.images, agent), own = who ? `<span class="who">${esc(who)}</span>` : "";
  const heads = it.kind === "said" ? own : ["owner", "shell", "peer"].includes(it.kind) ? own + ag(true) : ag(false) + own;
  return `<div class="it ${it.kind}${it.kind === "ask" || it.kind === "live" ? "" : " l-" + it.lane}${pics ? " pics" : ""}"${pc}${tag ? ` data-agent="${esc(agent)}"` : ""}>${heads}<span class="tx">${compact === true ? md(it.text.replace(/\n\s*\n+/g, "\n"), true) : md(it.text)}</span>${it.kind === "ask" ? askButtons(it, agent) : ""}<span class="ago" data-ts="${esc(it.ts || "")}">${since(it.ts)}</span>${pics}</div>`;
}
// An open prompt's options in the order shown, each naming its option by number and label so that it answers only the
// prompt it was drawn for: a button for each, chosen as its digit chooses it in the terminal, and for a Type something
// option a box to write the answer in, sent with Enter or its ↵. The server's reply to the last answer shows beside them
// for a while.
let askReply = {name: "", text: "", at: 0};
// What is written in each Type something box, by agent and option, so that a redraw, which may replace the box, draws
// it again with its text; askFocus is the box being written in, with its caret, for a replaced box to take the focus back.
const askTyped = {};
let askFocus = null;
const askKey = (agent, n) => agent + "\n" + n;
const askButtons = (it, agent) => {
  const opts = it.options || [], reply = askReply.name === agent && Date.now() - askReply.at < 15000 ? askReply.text : "";
  const attrs = o => `data-name="${esc(agent)}" data-n="${o.n}" data-label="${esc(o.label)}"`;
  return opts.length ? `<span class="opts">${opts.map(o => o.typed
    ? `<span class="typed"><input class="askin" ${attrs(o)} placeholder="${o.n}. Type something" value="${esc(askTyped[askKey(agent, o.n)] || "")}" autocomplete="off" spellcheck="false">` +
      `<button class="opt go" ${attrs(o)} data-typed="1" title="Answer with what is written here (Enter)">↵</button></span>`
    : `<button class="opt" ${attrs(o)} title="Choose this, as its number does in the terminal">${o.n ? o.n + ". " : ""}${esc(o.label)}</button>`).join("")}` +
    `${reply ? `<span class="reply">${esc(reply)}</span>` : ""}</span>` : "";
};
// An agent's open prompt: while it is open its message box is shut, as a prompt ignores a paste and the Enter after it
// would only choose the highlighted option; the prompt is answered with its own buttons.
const openAsk = a => a?.status === "waiting" && (a.feed || []).find(it => it.kind === "ask" && (it.options || []).length);
const ASK_SHUT = "A prompt is open in its pane: answer it with its buttons";
const sayHint = a => a.name?.startsWith(MEET) ? "Message the meeting…" : openAsk(a) ? ASK_SHUT : a.status === "waiting" ? "A prompt is open in its pane: this answers it"
  : a.suggest && settings().suggest !== "off" ? `${a.suggest}   ⇥ Tab` : `Message ${a.name}…`;
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
const laneSeg = name => filterBtn("lanes", "lanes:" + name, laneOf(name), ALL, LANES, name ? "" : "Filter").replace("<b ", `<b data-name="${esc(name)}" `);
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
const foldButton = (name, on) => `<b class="foldbtn" data-name="${esc(name)}" title="${on ? "Show its state, model and activity" : "Hide its state, model and activity"}">` +
  `<svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.6"><path d="${on ? "M2.5 4.5 6 8l3.5-3.5" : "M2.5 7.5 6 4l3.5 3.5"}"/></svg></b>`;
document.addEventListener("click", e => {
  const b = e.target.closest?.(".foldbtn");
  if (!b) return;
  e.stopPropagation();
  const name = b.dataset.name, f = folded();
  try { localStorage.setItem("folded", JSON.stringify(f.includes(name) ? f.filter(x => x !== name) : [...f, name])); } catch (e) {}
  draw();
}, true);
function card(a, ceil, conv, extra = "", after = "", {key = "", keep = false} = {}) {
  const cls = stOf(a);
  const model = a.model ? a.model.split(" ").slice(0, 2).map((p, i) => i ? p : p[0]).join("") : "";
  const ctx = a.ctxPct == null ? "" : `<span class="ctx"><span class="meter"><i style="width:${Math.min(100, a.ctxPct)}%;background:${gauge(a.ctxPct)}"></i></span><span style="color:${gauge(a.ctxPct)}">${a.ctxPct}%</span></span>`;
  const turns = conv || a.feed;
  const feed = keep ? "" : turns.length ? feedHtml(turns, a.name, !conv) : `<div class="empty">${a.live ? "no conversation yet" : "not running"}</div>`;
  const fold = folded().includes(a.name);
  return `<div class="card ${cls}${switching(a)}${conv ? " full" : ""}${after ? " term" : ""}${fold ? " folded" : ""}" style="--c:${a.colour}" data-name="${esc(a.name)}">
    <div class="top"><span class="name">${esc(a.name)}</span><span class="role">${esc(a.roleName)}</span>${a.ticket ? `<span class="ticket">${esc(a.ticket)}</span>` : ""}${foldButton(a.name, fold)}${a.feed.length ? laneSeg(a.name) : ""}${extra}</div>
    <div class="row2"><span class="state"><span class="dot"></span>${STATE[cls] || esc(cls)}</span><span>${ago(a.held)}</span>${ctx}</div>
    <div class="row2"><span class="model">${esc(model)} ${esc(a.effort)}</span><span class="model">${a.rate ? k(a.rate) + " tok/min" : ""}</span><span class="model" style="margin-left:auto">${esc(a.cwd)}</span></div>
    ${spark(a.series, ceil, a.colour)}
    <div class="feed"${key ? ` data-key="${esc(key)}"${keep ? " data-kept" : ""}` : ""}>${feed}</div>${conv ? `<button class="newest" title="Back to the newest turn">↓ Newest</button>` : ""}${after}
    ${a.live ? sayRow(a) : ""}</div>`;
}

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
  if (an.length !== bn.length) { keepFeeds(a, b); a.replaceChildren(...b.childNodes); return; }
  an.forEach((x, i) => patchNode(x, bn[i]));
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
  if (!box) patchKids(a, b);
}

function draw() {
  if (!S || resizing || holding($("#main")) || document.activeElement?.classList.contains("ctname")) return;   // nor while a tab is being named
  if (!barDrag) placeBar();
  const n = st => S.agents.filter(a => a.status === st).length;
  // Working and idle as a dot and a number each, with a flashing badge on top when any agent is waiting.
  const waiting = n("waiting");
  // the badge opens the agent that has been waiting longest
  const longest = S.agents.filter(a => a.status === "waiting").sort((x, y) => (y.held || 0) - (x.held || 0))[0]?.name || "";
  // the working dot pulses while any agent works; the counts are rewritten only when they change, so the pulse runs on
  const tally = `<span class="pill tally" title="${n("busy")} working, ${n("idle")} idle${waiting ? `, ${waiting} waiting` : ""}">` +
    `<span class="dot${n("busy") ? " on" : ""}" style="background:var(--green)"></span><b>${n("busy")}</b><span class="dot"></span><b style="color:var(--mute)">${n("idle")}</b>` +
    (waiting ? `<span class="wait" data-name="${esc(longest)}" title="Open ${esc(longest)}, waiting longest">${waiting} waiting</span>` : "") + `</span>`;
  if ($("#counts").dataset.html !== tally) { $("#counts").innerHTML = tally; $("#counts").dataset.html = tally; }
  $("#counts").onclick = e => { const w = e.target.closest(".wait"); if (w) openDetail(w.dataset.name); };
  // The benched developers and testers, and the stopped standing agents, on one line in the header's free space, so the header never changes height;
  // those that do not fit are counted in a "+N" that names them. Its filter button, there only while a custom layout is
  // unlocked, shows them by name or as icons (their portrait, else their role's shadow, as a pane's Icon badge); until
  // one is picked, icons while a Characters pane is on the page.
  const style = benchStyle(), benchSel = localStorage.getItem("page") === "custom" && !pageLocked();
  $("#bench").innerHTML = S.bench.length ? `<span>bench${benchSel ? filterBtn("benchsel", "bench", [style], ["name", "icon"], BENCH_STYLES, "") : ""}</span><span class="rrow">${S.bench.map(b => {
    const tip = `data-name="${esc(b.name)}"`;
    return style === "icon" ? face(b, tip)
      : `<em style="--c:${b.colour}" ${tip}>${esc(b.name)}</em>`; }).join("")}</span>` : "";
  // each one's menu, its details only, on a rest or a right-click, as an agent's tile
  document.querySelectorAll("#bench .rrow [data-name]").forEach(m => {
    m.onmouseenter = () => menuSoon(m, 350); m.onmouseleave = () => { clearTimeout(menuShow); if (menu.dataset.rested) menuOff(); };
    m.oncontextmenu = e => { e.preventDefault(); menuSoon(m, 0); };
  });
  if (S.bench.length && benchSel) filterButton($("#bench .benchsel"), BENCH_STYLES, () => [benchStyle()], v => `The bench by ${v === "icon" ? "icon" : "name"}`,
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
  menuButton($("#pagemode .viewbtn"), rested => viewMenu($("#pagemode .viewbtn"), rested));
  $("#lock").innerHTML = padlock(pageLocked()); $("#lock").title = pageLocked() ? "Locked: click to change the page" : "Click to lock the page";
  $("#pagelanes").innerHTML = laneSeg(""); laneClicks($("#pagelanes"));
  teamButton();
  const typed = {}, act = document.activeElement, focus = act && act.matches("#main .say") ? [act.dataset.name, act.selectionStart] : null;
  document.querySelectorAll("#main .say").forEach(i => { if (i.value) typed[i.dataset.name] = i.value; });
  // A row of tabs, one per agent; the picked one is remembered under "tab:" + key.
  const tabRow = (key, agents, badge, none) => {   // none: nobody is picked until one is (a Meeting's row)
    const sel = agents.find(a => a.name === localStorage.getItem("tab:" + key)) || (none ? null : agents[0]);
    if (badge === "icon")
      return [sel, `<div class="tabbar icontabs" data-sec="${esc(key)}">${agents.map(a => { const n = a === sel ? 0 : unseen(a);
        return `<span class="ftab" style="--c:${a.colour}">${face(a, `data-tab="${esc(a.name)}" data-name="${esc(a.name)}" title="${esc(a.name)}"`, a === sel ? " sel" : "")}${n ? unseenBadge(n) : ""}</span>`; }).join("")}</div>`];
    if (badge === "card")
      return [sel, `<div class="tabbar chrtabs" data-sec="${esc(key)}">${agents.map(a => tiles([a]).replace(/ title="[^"]*"/g, "")   // no tooltips: a rest shows the agent's menu
      .replace('<div class="chr ', `<div data-tab="${esc(a.name)}" class="chr${a === sel ? " sel" : ""} `)).join("")}</div>`];
    const tab = a => { const n = a === sel ? 0 : unseen(a);
      return `<button class="${stOf(a)}${switching(a)}" style="--c:${a.colour}" data-tab="${esc(a.name)}"><span class="dot"></span>${esc(a.name)}${n ? unseenBadge(n) : ""}</button>`; };
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
  document.querySelectorAll(".chrtabs .chr, .icontabs .face, .meetrow button, .tabbar button.away").forEach(m => {
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
    if (focus && focus[0] === i.dataset.name) { i.focus(); i.setSelectionRange(focus[1], focus[1]); }
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
const PANE_TYPES = {agent: "Agent", others: "List", grid: "Grid", tabs: "Tabs", team: "Team", combined: "Combined", characters: "Characters", file: "File", meeting: "Meeting"};
const ROLE_ORDER = ["lead", "dev", "tester", "hot", "ops", "support", "review", "process", "pa"];
// The views, kept in this browser: each a name, a kind (grid, tabs or custom) and, for a custom one, a layout, one of
// them showing ("at"). Grid and Tabs are the first two, and can be renamed or deleted like any other. A browser from
// before there were views starts with Grid, Tabs and its one layout (kept under "custom") as the view "Custom", on the
// one it showed ("page"). "page" stays the showing view's kind, which is what the rest of the page reads.
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
// or between the two, taken out with its ✕ and put back with the Add at the end of either. The logo, Views and the
// padlock have no ✕ (owner, 2026-11-01: "Icon is not optional"), so the page can always be locked and unlocked again.
// Week, Session, Team and Disk are the harness's own plug-ins (team/bar), drawn as any plug-in is, and in the bar by default.
const BAR_ITEMS = {brand: "Logo", week: "Week", session: "Session", team: "Team", disk: "Disk", tally: "Agents", bench: "Bench",
  controls: "Start and stop", lanes: "Lanes", view: "Views", lock: "Lock", theme: "Theme", settings: "Settings", help: "Help",
  gap1: "Spacer", gap2: "Spacer 2", gap3: "Spacer 3"};
// Spacers (owner, 2026-11-01, to right-align the footer's items) take the room left, so the items after one sit to
// the right; three, to centre a group or split the bar three ways. Out of the bar until added.
const BAR_GAPS = ["gap1", "gap2", "gap3"];
// Any other plug-in (S.plugins, the server's AGENT_BAR_PLUGINS scripts) is one more item, out of the bar until added.
const plugs = () => S?.plugins || [];
const BAR_FIXED = ["brand", "view", "lock"];
const barName = k => { const x = plugs().find(x => x.key === k); return BAR_ITEMS[k] || x?.name || x?.label || k; };
// A plug-in that says where it goes (its place, header or footer) can be put only there (owner, 2026-11-01: "each
// plug-in can say header, footer or both").
const fits = (k, foot) => { const p = plugs().find(x => x.key === k)?.place; return !p || p === (foot ? "footer" : "header"); };
// One header and footer for the whole page, the same in every view (owner, 2026-11-01), kept in this browser as "bar".
// Until it is first changed, the bar the shown view kept when each view had its own.
function pageBar() { try { const b = JSON.parse(localStorage.getItem("bar")); if (b) return b; } catch (e) {} return shownView().bar || {}; }
function barOf() {
  const b = pageBar(), mine = Object.keys(BAR_ITEMS), all = [...new Set([...mine, ...plugs().map(x => x.key)])];
  const foot = (b.foot || []).filter(k => all.includes(k) && fits(k, true)), off = (b.off || []).filter(k => all.includes(k) && !BAR_FIXED.includes(k) && !foot.includes(k));
  const head = (b.head || []).filter(k => all.includes(k) && fits(k, false) && !foot.includes(k) && !off.includes(k)), placed = k => head.includes(k) || foot.includes(k) || off.includes(k);
  // a built-in the view has not placed yet (one new to the page) goes in after the one before it in the default order,
  // or at the footer's end if it can only go there
  for (const [i, k] of mine.entries()) if (BAR_GAPS.includes(k) && !placed(k)) off.push(k); else if (!placed(k)) fits(k, false) ? head.splice(head.indexOf(mine[i - 1]) + 1, 0, k) : foot.push(k);
  return {head, foot, off: [...off, ...all.filter(k => !mine.includes(k) && !placed(k))]};
}
// Each plug-in drawn as a stat: its label over its value, or with a meter or a sparkline, "Label: value" over it; its
// title on a rest. A colour is a CSS colour or one of the page's own by name.
const PLUG_COLOUR = {green: "var(--green)", amber: "var(--amber)", red: "var(--red)", text: "var(--text)", faint: "var(--faint)"};
const plugColour = c => PLUG_COLOUR[c] || c || "";
function drawPlugs() {
  const keys = plugs().map(x => x.key);
  document.querySelectorAll(".bi.plug").forEach(e => keys.includes(e.dataset.item) || e.remove());
  for (const x of plugs()) {
    if (!$(`.bi[data-item="${x.key}"]`)) $("#barbin").insertAdjacentHTML("beforeend", `<div class="bi plug" data-item="${esc(x.key)}"><div class="stat">` +
      `<div class="k"><span class="lab"></span><span class="kv"></span></div><div class="v"></div><div class="meter"><i></i><u></u></div><div class="pspark"></div></div>` +
      (BAR_FIXED.includes(x.key) ? "" : `<i class="bx" title="Take this out of the bar">✕</i>`) + `</div>`);
    const e = $(`.bi[data-item="${x.key}"]`), st = e.querySelector(".stat"), m = x.meter, inline = !!(m || x.spark);
    // Session shows only when Settings shows the session limit
    st.style.display = x.hidden || x.key === "session" && settings().session !== "on" ? "none" : "";
    st.title = x.title;
    st.classList.toggle("slim", !!x.slim);
    const parts = (x.parts || [{text: x.value, colour: x.colour}]).filter(p => p.text !== "");
    const els = parts.map(p => { const b = document.createElement(p.bold ? "b" : "span"); b.textContent = p.text; b.style.color = plugColour(p.colour || (x.parts ? "" : x.colour)); return b; });
    e.querySelector(".lab").textContent = x.label;
    e.querySelector(".kv").replaceChildren(...(inline && els.length ? [...(x.label ? [": "] : []), ...els] : []));
    e.querySelector(".k").style.display = x.label || inline && els.length ? "" : "none";
    e.querySelector(".v").replaceChildren(...(inline ? [] : els));
    e.querySelector(".v").style.display = inline ? "none" : "";
    const mt = e.querySelector(".meter");
    mt.style.display = m ? "" : "none";
    if (m) {
      mt.querySelector("i").style.cssText = `width:${m.pct}%;background:${m.colour ? plugColour(m.colour) : "linear-gradient(90deg,#2ea043,#3fb950)"}`;
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
  const b = barOf(), edit = barEditing();
  for (const [box, keys] of [[$("header"), b.head], [$("footer"), b.foot], [$("#barbin"), b.off]]) {
    if ([...box.querySelectorAll(":scope > .bi")].map(e => e.dataset.item).join() !== keys.join())
      for (const k of keys) if ($(`.bi[data-item="${k}"]`)) box.insertBefore($(`.bi[data-item="${k}"]`), box.querySelector(":scope > .barplus"));
    if (box.id !== "barbin") box.classList.toggle("editing", edit);
    // bare: nothing in it shows, only spacers or items hidden for now (Session while Settings hides it, Disk with nothing to watch)
    if (box.id !== "barbin") box.classList.toggle("bare", ![...box.querySelectorAll(":scope > .bi:not(.gap)")].some(e => e.firstElementChild?.style.display !== "none"));
    box.querySelectorAll(":scope > .bi").forEach(e => e.draggable = edit && box.id !== "barbin");
    const can = b.off.filter(k => fits(k, box.tagName === "FOOTER"))   // A to Z (owner, 2026-11-01)
      .sort((x, y) => barName(x).localeCompare(barName(y), undefined, {numeric: true, sensitivity: "base"}));
    const plus = box.querySelector(":scope > .barplus"), want = edit && box.id !== "barbin" && can.length ? can.join() : "";
    if (plus && plus.dataset.k !== want) plus.remove();
    if (want && plus?.dataset.k !== want) box.insertAdjacentHTML("beforeend", `<select class="barplus" data-k="${want}" title="Put an item back">` +
      `<option value="">+</option>${can.map(k => `<option value="${esc(k)}">${esc(barName(k))}</option>`).join("")}</select>`);
  }
}
document.addEventListener("click", e => {
  const x = e.target.closest(".editing > .bi > .bx");
  if (!x) return;
  e.stopPropagation(); e.preventDefault();
  const b = barOf(), k = x.parentElement.dataset.item;
  saveBar({head: b.head.filter(i => i !== k), foot: b.foot.filter(i => i !== k), off: [...b.off, k]}); draw();
}, true);
document.addEventListener("change", e => {
  const s = e.target.closest?.(".barplus");
  if (!s?.value) return;
  const b = barOf(), k = s.value, foot = !!s.closest("footer");
  saveBar({head: foot ? b.head : [...b.head, k], foot: foot ? [...b.foot, k] : b.foot, off: b.off.filter(i => i !== k)}); draw();
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
  if (!box || !fits(barDrag.dataset.item, box.tagName === "FOOTER")) return false;
  // a bar wraps on a narrow screen: an item on a later row is not short of the pointer, whatever its left
  const at = [...box.querySelectorAll(":scope > .bi:not(.dragging)")].find(b => { const r = b.getBoundingClientRect();
    return y < r.top || y < r.bottom && x < r.left + r.width / 2; });
  const to = at || box.querySelector(":scope > .barplus");
  if (barDrag.parentElement !== box || barDrag.nextElementSibling !== to) box.insertBefore(barDrag, to);
  return true;
}
function barDropped() {
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
// A grid or tabs pane's agents, role by role in the order the roles were picked (n.roles keeps it), roster order
// within a role.
const paneAgents = n => n.show === "meeting" ? meetAgents(n) : (n.roles || []).flatMap(r => S.agents.filter(a => a.role === r));
// A Meeting pane: those in the meeting along its top, role by role, over their conversations as one and the meeting's
// message box. Nobody along the top is picked to be talked to alone (owner, 2026-11-01: "I don't want to message a
// single agent in a meeting - that's not how meetings work"); a rest on one still shows its menu. Who is in it (n.who,
// "role:<role>" and "name:<agent>" keys, chosen with its Who button while the layout is unlocked) is the whole team
// until chosen.
const byRole = list => list.map((a, i) => [a, i]).sort(([x, i], [y, j]) =>
  ((ROLE_ORDER.indexOf(x.role) + 1 || 99) - (ROLE_ORDER.indexOf(y.role) + 1 || 99)) || i - j).map(([a]) => a);
const inMeeting = (n, a) => !Array.isArray(n.who) || n.who.includes("role:" + a.role) || n.who.includes("name:" + a.name) || (n.extra || []).includes(a.name);
const meetAgents = n => byRole(S.agents.filter(a => inMeeting(n, a)));
// The meeting's box goes to everyone (owner, 2026-11-01): a message typed there goes to every member who is running,
// each as if typed into their own box, headed with the meeting's tag, "[<view> <month>-<day> <started>]" (or the
// view's name alone before Start), so the pane can show just the meeting's conversation (owner, 2026-11-01: "if we
// prefix messages with the meeting name, the view can actually filter to just that conversation").
const MEET = "~meeting:";
const meetTag = n => { const d = n.active && new Date(n.active), p = x => String(x).padStart(2, "0");
  return `[${shownView().name || "Meeting"}${d ? ` ${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}` : ""}]`; };
// An agent's part of the meeting: each tagged message and what followed it, up to the next message the owner (or a
// peer) sent that agent; the tag itself is not shown.
function meetThread(list, tag, all) {
  let on = false;
  return list.flatMap(it => {
    const own = OWN.includes(it.kind), mine = own && (it.text || "").startsWith(tag);
    if (own || ["peer", "shell"].includes(it.kind)) on = mine;
    return mine ? [{...it, text: it.text.slice(tag.length).trimStart()}] : all || on ? [it] : [];
  });
}
const meetAll = path => localStorage.getItem("mode:meet:" + path) === "all";
const meetRow = path => `<div class="att" data-name="${esc(MEET + path)}"></div><div class="sayrow">${addButton(MEET + path)}<textarea class="say" rows="1" data-name="${esc(MEET + path)}" autocomplete="off"></textarea>${SEND}</div>`;
const whoOn = n => Array.isArray(n.who) ? n.who : roleList().map(r => "role:" + r.role);
const whoItems = () => [...roleList().map(r => ["role:" + r.role, r.name, `<span class="dot" style="--c:${r.colour}"></span>`]),
  ...byRole([...S.agents, ...S.bench]).map(a => ["name:" + a.name, a.name, `<span class="dot hollow" style="--c:${a.colour}"></span>`])];
const whoBtn = (path, n) => filterBtn("who", "who:" + path, whoOn(n), Array.isArray(n.who) ? whoItems().map(([k]) => k) : whoOn(n), whoItems(), "Who");
// The meeting's Start, Add and End (owner, 2026-11-01: "start can start anyone not active, and stop can stop anyone
// it started"; "an add, to bring in other member, just to the current active meeting"). Start starts every standing
// agent in the meeting that is not running and opens the meeting (n.active); the pane keeps who it started
// (n.started). Add brings anyone else into the open meeting alone (n.extra), starting a standing agent that is not
// running. End asks those it started that still run to finish and stop, as an agent's own Stop does, and closes the
// meeting, its added members with it. Start and End ask first, in the bar, as Stop does in an agent's menu.
let meetAsk = null;   // {path, what: "start" or "end"} while the bar asks
const meetAway = n => S.bench.filter(a => a.standing && inMeeting(n, a) && !S.starting.includes(a.name)).map(a => a.name);
const meetMine = n => (n.started || []).filter(x => S.agents.some(a => a.name === x && a.live) && !S.halting.includes(x));
const meetOthers = n => byRole([...S.agents.filter(a => a.live), ...S.bench.filter(a => a.standing)]).filter(a => !inMeeting(n, a));
const andList = list => list.length < 2 ? list.join("") : list.slice(0, -1).join(", ") + " and " + list.at(-1);
function meetBar(path, n) {
  const away = meetAway(n), mine = meetMine(n), them = meetAgents(n);
  const busy = [...S.starting, ...S.halting].filter(x => (n.started || []).includes(x));
  if (meetAsk?.path === path) {
    const start = meetAsk.what === "start", who = start ? away : mine;
    if (who.length) return `<div class="meetbar ask"><span>${start ? `Start ${esc(andList(who))}?` : `End the meeting, and ask ${esc(andList(who))} to finish, update ${who.length > 1 ? "their records" : "their record"} and stop?`}</span>` +
      `<b class="mbtn${start ? "" : " warn"}" data-meet="${meetAsk.what}!">${MENU_ICON[start ? "start" : "power"]}${start ? "Start" : "End"}</b><b class="mbtn" data-meet="cancel">${MENU_ICON.close}Cancel</b></div>`;
    meetAsk = null;
  }
  const here = `${them.filter(a => a.live).length} here${away.length ? `, ${away.length} not running` : ""}${busy.length ? ` · ${S.starting.some(x => busy.includes(x)) ? "starting" : "stopping"} ${esc(andList(busy))}…` : ""}`;
  return n.active
    ? `<div class="meetbar on"><span><b>Meeting</b> since ${new Date(n.active).toLocaleTimeString([], {hour: "2-digit", minute: "2-digit"})} · ${here}</span>` +
      `<b class="mbtn" data-meet="add" data-menu="meetadd:${esc(path)}" title="Bring someone else into this meeting">${MENU_ICON.plus}Add</b>` +
      `<b class="mbtn" data-meet="end" title="${mine.length ? `End the meeting and stop ${esc(andList(mine))}, whom it started` : "End the meeting"}">${MENU_ICON.stop}End</b></div>`
    : `<div class="meetbar"><span>${here}</span><b class="mbtn" data-meet="start" title="${away.length ? `Start the meeting and ${esc(andList(away))}` : "Start the meeting"}">${MENU_ICON.start}Start</b></div>`;
}
// The open meeting's Add menu: everyone running or standing who is not in it; a pick brings them in, starting one
// that is not running.
function meetAdd(btn, path) {
  const key = "meetadd:" + path, n = nodeAt(layout().root, path);
  if (menuOn(key)) return menuOff(true);
  const them = meetOthers(n);
  menuAt(btn, key, `<div class="hd"><div>Add to this meeting</div></div>` + (them.length ? them.map(a => `<div class="mi" data-add="${esc(a.name)}">` +
    `<span class="dot" style="--c:${a.colour}"></span>${esc(a.name)}${a.live ? "" : `<span class="mute">&nbsp;· starts them</span>`}</div>`).join("")
    : `<div class="mi off">Everyone is here</div>`), false);
  menu.querySelectorAll(".mi[data-add]").forEach(mi => mi.onclick = () => {
    const name = mi.dataset.add, away = !S.agents.some(a => a.name === name && a.live);
    menuOff(true);
    const l = layout(), m = nodeAt(l.root, path);
    m.extra = [...new Set([...(m.extra || []), name])];
    if (away) m.started = [...new Set([...(m.started || []), name])];
    saveLayout(l); draw(); setTimeout(load);
    if (away) post(`/api/agent/${encodeURIComponent(name)}/start`);
  });
}
// A Characters pane's agents: those in its roles, the same way, or every agent until roles are chosen for it.
const chrAgents = n => Array.isArray(n.roles) ? paneAgents(n) : S.agents;
// How a Tabs or Combined pane shows its agents (n.badge): by name ("name", the default), as the bench's small tiles
// ("icon"), or as their Characters tiles ("card").
const BADGES = [["name", "Name"], ["icon", "Icon"], ["card", "Card"]];
// A pane's Roles button and its menu: each role with a dot in its colour, ticked while the pane shows it.
const rolesOn = n => n.show === "characters" && !Array.isArray(n.roles) ? roleList().map(r => r.role) : n.roles || [];
const roleItems = () => roleList().map(r => [r.role, r.name, `<span class="dot" style="--c:${r.colour}"></span>`]);
const rolesBtn = (path, n) => filterBtn("roles", "roles:" + path, rolesOn(n), roleList().map(r => r.role), roleItems(), "");
// A pane's tabs over its body while it has two or more, each a configuration of its own (see TAB_KEYS): the showing
// one renamed by a click on it, any dragged along the strip or closed while the layout is unlocked.
function paneTabs(n, locked) {
  const tabs = n.tabs || [];
  return tabs.length < 2 ? "" : `<div class="ctabs">${tabs.map((t, i) => { const sel = i === (n.tab || 0);
    return `<span class="ctab${sel ? " sel" : ""}" data-i="${i}"${locked ? "" : ' draggable="true"'} title="${sel && !locked ? "Click to rename" : ""}"><span class="ctl">${esc(t.title || "Tab " + (i + 1))}</span>` +
      `${locked ? "" : `<i class="cx" title="Close this tab">${MENU_ICON.close}</i>`}</span>`; }).join("")}</div>`;
}
// The View menu: every view, Grid and Tabs among them, its kind's icon and its name, the showing one ticked. A click on
// one shows it; its pencil renames it in place (Enter or leaving the box keeps the name, Esc drops it) and its × deletes
// it (never the last) once asked in the menu, as an agent's Stop asks. Add a view, at the bottom, adds an empty custom one and names it straight away.
function viewMenu(btn, rested, again, ask) {
  if (!again && menuOn("view")) { if (rested) return; if (menu.dataset.rested) delete menu.dataset.rested; else menuOff(true); return; }
  const v = views();
  menuAt(btn, "view", `<div class="hd"><div>View</div></div>` + v.views.map((x, i) =>
    `<div class="mi vmi" data-v="${i}" title="${esc(VIEW_TIP[x.kind])}"><i class="vico">${MENU_ICON[x.icon] || MENU_ICON[x.kind]}</i><span class="vname">${esc(x.name)}</span>` +
    MENU_ICON.check.replace("<svg", `<svg class="tick${i === v.at ? "" : " off"}"`) +
    `<i class="vbtn ved" title="Rename this view">${MENU_ICON.pencil}</i>` +
    `${v.views.length > 1 ? `<i class="vbtn vdel" title="Delete this view">${MENU_ICON.close}</i>` : '<i class="vbtn"></i>'}</div>` +
    (ask === i ? `<div class="ask">Delete the view "${esc(x.name)}"?</div><div class="mi warn vyes" data-v="${i}">${MENU_ICON.close}Delete ${esc(x.name)}</div>` +
      `<div class="mi vno">${MENU_ICON.close}Cancel</div><div class="sep"></div>` : "")).join("") +
    `<div class="mi vadd" title="Add an empty custom view">${MENU_ICON.plus}Add a view</div>`, false, again);
  if (rested && !again) menu.dataset.rested = "1";
  const go = f => { const v = views(); f(v); saveViews(v); localStorage.removeItem("custom:max"); localStorage.removeItem("custom:maxname"); paneBig = null; draw(); setTimeout(load); };
  const redraw = ask => viewMenu($("#pagemode .viewbtn"), false, true, ask);
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
  menu.querySelector(".vadd").onclick = () => {
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
    if (keep && (val && val !== was || icon !== wasIcon)) { const v = views(); v.views[i].name = val || was; v.views[i].icon = icon; saveViews(v); draw(); } after(); };
  // its keys are its own: the menu's arrows, Enter and Space, and Esc closing the menu, wait until it is done
  box.onkeydown = e => { e.stopPropagation(); if (e.key === "Enter") end(true); else if (e.key === "Escape") end(false); };
  box.onclick = e => e.stopPropagation();
  box.onblur = () => end(true);
  label.textContent = ""; label.append(box); box.focus(); box.select();
}
function customHtml(ceil, tabRow) {
  const l = layout();
  // A maximised pane is one agent's card filling the layout (an agent pane's own, or one card of a grid or tabs pane),
  // or a Team or Combined pane.
  let maxed = localStorage.getItem("custom:max");
  const maxNode = maxed && leaves(l.root).find(([p]) => p === maxed)?.[1];
  const maxName = maxNode && (["team", "combined", "meeting"].includes(maxNode.show) ? "~" + maxNode.show : maxNode.show === "agent" ? maxNode.name
    : paneAgents(maxNode).some(a => a.name === localStorage.getItem("custom:maxname")) && localStorage.getItem("custom:maxname"));
  if (maxed && !maxName) { localStorage.removeItem("custom:max"); localStorage.removeItem("custom:maxname"); maxed = null; }
  // A card shows the whole conversation unless its pane is set to the summary (the pane bar's Full/Summary, while the
  // layout is being changed); a maximised one always does. Every card has the maximise button docked at the end of its head.
  const paneCard = (n, a, path) => {
    const big = path === maxed;
    if (!fullView(n) && !big) return card(a, ceil, null, maxButton(false));
    const t = big && termOn() && paneTerm[a.name];
    const key = paneConv[a.name] && [a.name, a.live, paneVer[a.name], laneOf(a.name), [...openRuns], noImage.size, echoKey(a.name)].join("|");
    const keep = !!key && $(`#main .pane[data-path="${path}"] .card.full[data-name="${CSS.escape(a.name)}"] .feed`)?.dataset.key === key;
    return card(a, ceil, paneConv[a.name] || a.feed,
      (big ? `<span class="seg termseg"><b class="${termOn() ? "on" : ""}" title="Show or hide its terminal">Terminal</b></span>` : "") + maxButton(big),
      t ? paneTermHtml(a.name, t) : "", {key, keep});
  };
  const pane = (n, path) => {
    const of = paneAgents(n);
    let body = `<div class="blank">${pageLocked() ? "" : "Choose what this pane shows"}</div>`;
    if (n.show === "agent") {
      const a = S.agents.find(x => x.name === n.name);
      body = a ? `<div class="cards" style="grid-template-columns:minmax(0,1fr)">${paneCard(n, a, path)}</div>`
        : `<div class="blank">${n.name ? esc(n.name) + " is not running" : "Choose an agent"}</div>`;
    } else if (n.show === "others") {
      body = `<div class="others">${minis("")}</div>`;
    } else if (n.show === "characters") {
      const them = chrAgents(n);
      body = them.length ? `<div class="chrs">${tiles(them)}</div>` : `<div class="blank">${n.roles.length ? "No agent in these roles is running" : "Choose one or more roles"}</div>`;
    } else if (n.show === "file") {
      const d = n.path && fileDocs[n.path];
      body = !n.path ? `<div class="blank">${pageLocked() ? "" : "Type a document's full path above"}</div>`
        : !d ? `<div class="blank">Loading…</div>`
        : d.text == null ? `<div class="blank">${d.status === 404 ? "No such document, or not one this page shows" : "Could not load it"}</div>`
        : `<div class="fdoc">${/\.(md|markdown)$/i.test(n.path) ? docMd(d.text) : `<pre class="code">${esc(d.text)}</pre>`}</div>`;
    } else if (n.show === "combined") {
      body = combinedHtml(path, n, fullView(n) || path === maxed, path === maxed);
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
      // everyone in it along the top, over their conversations as one; the faces are not tabs: there is nobody to pick
      // members who are not running follow, greyed, their menu (and its Start) on a rest
      const them = meetAgents(n), away = byRole(S.bench.filter(a => inMeeting(n, a))), badge = n.badge || "icon";
      const off = away.map(a => badge === "icon"
        ? `<span class="ftab away">${face(a, `data-name="${esc(a.name)}" title="${esc(a.name)}, not running"`)}</span>`
        : `<button class="away" style="--c:${a.colour}" data-name="${esc(a.name)}" title="${esc(a.name)}, not running"><span class="dot"></span>${esc(a.name)}</button>`).join("");
      const row = them.length ? tabRow("meet:" + path, them, badge, true)[1].replace(/ data-tab="[^"]*"/g, "").replace('class="tabbar', 'class="tabbar meetrow').replace(/<\/div>$/, off + "</div>")
        : off ? `<div class="tabbar${badge === "icon" ? " icontabs" : ""}">${off}</div>` : "";
      body = `${meetBar(path, n)}${row}${combinedHtml(path, n, fullView(n) || path === maxed, path === maxed)}`;
    } else if (n.show === "grid" || n.show === "tabs") {
      body = `<div class="blank">${(n.roles || []).length ? "No agent in these roles is running" : "Choose one or more roles"}</div>`;
    }
    const tabbed = TABBED.includes(n.show);
    const bar = pageLocked() ? "" : `<div class="pbar">
      <b data-act="move" class="pmove" title="Drag onto another pane to swap the two">⠿</b>
      <select data-act="show">${n.show ? "" : `<option value="" selected>Show…</option>`}${Object.entries(PANE_TYPES).map(([t, label]) => `<option value="${t}"${t === n.show ? " selected" : ""}>${label}</option>`).join("")}</select>
      ${n.show && !["others", "characters", "file"].includes(n.show) ? `<span class="seg">${[["full", "Full", "The whole conversation"], ["summary", "Summary", "The newest turns"]].map(([v, label, title]) =>
        `<b data-act="view" data-v="${v}" class="${(v === "full") === fullView(n) ? "on" : ""}" title="${title}">${label}</b>`).join("")}</span>` : ""}
      ${n.show === "file" ? `<input data-act="path" value="${esc(n.path || "")}" placeholder="~/claude-work/owner-actions.md" spellcheck="false" title="A document's full path: Enter to show it">` : ""}
      ${["tabs", "combined", "meeting"].includes(n.show) ? `<select data-act="badge" title="How agents are shown">${BADGES.map(([v, label]) => `<option value="${v}"${v === (n.badge || (n.show === "meeting" ? "icon" : "name")) ? " selected" : ""}>${label}</option>`).join("")}</select>` : ""}
      ${n.show === "agent" ? `<select data-act="name"><option value="">Agent…</option>${S.agents.map(a => `<option${a.name === n.name ? " selected" : ""}>${esc(a.name)}</option>`).join("")}</select>` : ""}
      ${["grid", "tabs", "characters", "combined"].includes(n.show) ? rolesBtn(path, n) : n.show === "meeting" ? whoBtn(path, n) : ""}
      ${tabbed ? `<b class="fbtn cadd" title="Add a tab with this configuration">${MENU_ICON.plus}</b>` : ""}
      <span class="pacts"><b data-act="row" title="Split side by side">⇆</b><b data-act="col" title="Split top and bottom">⇅</b><b data-act="del" title="Remove this pane">✕</b></span></div>`;
    return `<div class="pane" data-path="${path}">${bar}<div class="pbody">${tabbed ? paneTabs(n, pageLocked()) : ""}${body}</div></div>`;
  };
  const node = (n, path) => {
    if (!n.split) return pane(n, path);
    const side = tileSide(n), count = side && chrAgents(n[side]).length;
    const size = side && (n.split === "row" ? tilesWidth(tileCols(n, path + side, count)) : tilesHeight(tileRows(n, path + side, count), path + side));
    const grow = s => side ? (s === side ? `flex:0 0 ${size}px` : "flex-grow:1") : `flex-grow:${s === "a" ? n.at : 1 - n.at}`;
    return `<div class="lay ${n.split}" data-path="${path}"><div class="half" style="${grow("a")}">${node(n.a, path + "a")}</div><div class="divider drag" data-path="${path}"></div><div class="half" style="${grow("b")}">${node(n.b, path + "b")}</div></div>`;
  };
  return !maxed ? node(l.root, "r") : ["team", "combined", "meeting"].includes(maxNode.show) ? pane(maxNode, maxed) : pane({...maxNode, show: "agent", name: maxName}, maxed);
}
const fullView = n => n.view !== "summary";
// A Characters pane beside another is a whole number of tiles wide: one, two or three (two unless set) as its divider
// snaps between them, and more while its tiles would otherwise need scrolling. One above or below another is a whole
// number of rows high in the same way (one unless set).
const tileSide = n => !!n.split && (n.a.show === "characters" ? "a" : n.b.show === "characters" ? "b" : null);
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
// An agent's card or a Team pane can fill the whole layout for a while, from the button at the end of its header or Shift+F11
// (the pane being typed in, else the one under the pointer); Esc, the button or Shift+F11 again puts it back.
const maxButton = on => `<b class="maxbtn" title="${on ? "Restore (Esc)" : "Maximise"}"><svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5">${on
  ? '<path d="M4.5 1v3.5H1M7.5 1v3.5H11M4.5 11V7.5H1M7.5 11V7.5H11"/>' : '<path d="M1 4.5V1h3.5M11 4.5V1H7.5M1 7.5V11h3.5M11 7.5V11H7.5"/>'}</svg></b>`;
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
  return `<div class="termwrap${big ? " big" : ""}" title="${big ? "" : "Expand"}"><div class="term"><div class="bar"><i></i><i></i><i></i><span>${esc(name)} — ${t.cols}×${t.rows}</span><b class="pzoom">${big ? "⤡" : "⤢"}</b></div>` +
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
  const shown = teamLog.filter(m => !hide.has(m.from) && !hide.has(m.to)), log = full ? shown : shown.slice(-30);
  const key = ["team", teamVer, noImage.size, full, [...hide].sort()].join("|");
  const keep = $(`#main .pane[data-path="${path}"] .teamlog .feed`)?.dataset.key === key;
  const row = m => `<div class="it peer l-team" style="--pc:${colours[m.from] || "#888"}" data-agent="${esc(m.from)}"><span class="who">${esc(m.from)}</span>` +
    `<span class="who to" style="--pc:${colours[m.to] || "#888"}">${esc(m.to)}</span><span class="tx">${md(m.text)}</span>` +
    `<span class="ago" data-ts="${esc(m.ts || "")}">${since(m.ts)}</span></div>`;
  return `<div class="teamlog${full ? "" : " summary"}" data-name="~team"><div class="thead"><span>Team</span><span>${shown.length} message${shown.length === 1 ? "" : "s"} between agents</span>${filterBtn("agents", "agents:" + path, names.filter(x => !hide.has(x)), names, teamItems(), "Agents")}${maxButton(big)}</div>` +
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
  const meet = n.show === "meeting", chosen = paneAgents(n).filter(a => !meet || a.live).map(a => a.name), on = clanesOf(n);
  const shown = it => ["ask", "live", "pending", "echo"].includes(it.kind) || on.includes(it.kind === "said" ? "said" : it.lane);
  // a message sent from the pane shows at once, as in an agent's own view, until the agent's conversation has it
  const tag = meet && meetTag(n), all = meet && meetAll(path), part = list => meet ? meetThread(list, tag, all) : list;
  const items = chosen.flatMap(a => part((paneConv[a] || []).concat(echoItems(paneConv[a] || [], a))).filter(it => (it.ts || it.kind === "ask") && shown(it) && !(it.kind === "sent" && chosen.includes(it.with || it.who)))
    .map(it => ({...it, _agent: a}))).sort((x, y) => !x.ts ? 1 : !y.ts ? -1 : x.ts < y.ts ? -1 : x.ts > y.ts ? 1 : 0)
    .reduce(foldSent, []);
  const log = full ? items : items.slice(-30);
  seenUpTo(log);
  const key = ["combined", chosen.map(a => a + ":" + paneVer[a] + echoKey(a)), on, full, tag, all, [...openRuns], noImage.size].join("|");
  const keep = $(`#main .pane[data-path="${path}"] .teamlog .feed`)?.dataset.key === key;
  const seg = filterBtn("clanes", "clanes:" + path, on, CALL, CLANES);
  // the chat opened from an agent's menu in this pane: its badge and its message box, under the conversation
  // a Meeting pane's is the meeting's own, always open
  const talk = !meet && S.agents.find(a => a.live && a.name === n.chat && chosen.includes(a.name));
  const pick = `data-menu="chatpick:${esc(path)}" data-chat="${esc(path)}" title="Chat with another agent"`;
  const chat = meet ? `<div class="chat">${meetRow(path)}</div>` : talk ? `<div class="chat"><div class="chead">${n.badge === "icon" || n.badge === "card" ? face(talk, pick, " pick")
    : `<span class="name pick" style="--c:${talk.colour}" ${pick}>${esc(talk.name)}</span>`}<span class="x" data-chat="${esc(path)}" title="Close the chat">${MENU_ICON.close}</span></div>${sayRow(talk)}</div>` : "";
  return `<div class="teamlog combined${full ? "" : " summary"}" data-name="~combined:${path}"><div class="thead">${meet ? `<span class="cnames">${chosen.length} in the meeting</span><span class="seg mode" data-sec="meet:${esc(path)}">${[["this", "This meeting", "Only this meeting's messages and the answers to them"], ["all", "Everything", "Everything its members said"]].map(([m, label, tip]) => `<b data-mode="${m}" class="${(m === "all") === all ? "on" : ""}" title="${tip}">${label}</b>`).join("")}</span>` : n.badge === "card" && chosen.length ? `<span class="cnames chrrow">${tiles(paneAgents(n))}</span>`
    : n.badge === "icon" && chosen.length ? `<span class="cnames iconrow">${paneAgents(n).map(a => face(a, `data-name="${esc(a.name)}" title="${esc(a.name)}"`)).join("")}</span>` : `<span class="cnames" title="${chosen.map(esc).join(", ")}">${chosen.length ? chosen.map(x => `<span class="name" style="--c:${colours[x] || "#888"}" data-name="${esc(x)}">${esc(x)}</span>`).join("") : "no agents"}</span>`}${seg}${maxButton(big)}</div>` +
    `<div class="feed" data-key="${esc(key)}"${keep ? " data-kept" : ""}>${keep ? "" : !chosen.length ? `<div class="empty">${meet ? "nobody in this meeting is running" : (n.roles || []).length ? "no agent in these roles is running" : "choose one or more roles"}</div>` : feedHtml(log, "", !full, ALL)}</div>${full ? `<button class="newest" title="Back to the newest turn">↓ Newest</button>` : ""}${chat}</div>`;
}
async function loadPaneConvs() {
  if ((localStorage.getItem("page") || "grid") !== "custom") return;
  await Promise.all([loadTeam(), loadFiles()]);
  const max = localStorage.getItem("custom:max"), names = [...new Set(leaves(layout().root).flatMap(([p, n]) =>
    n.show === "combined" || n.show === "meeting" ? paneAgents(n).map(a => a.name) : !fullView(n) && p !== max ? [] : n.show === "agent" ? (n.name ? [n.name] : []) : paneAgents(n).map(a => a.name)))];
  await Promise.all(names.map(async name => {
    try {
      const d = await (await fetch("/api/agent/" + encodeURIComponent(name), {cache: "no-store"})).json();
      const text = JSON.stringify(d.feed);
      if (text !== paneText[name]) { paneConv[name] = d.feed; paneText[name] = text; paneVer[name] = (paneVer[name] || 0) + 1; }
      paneTerm[name] = {screen: d.screen, cols: d.cols || 80, rows: d.rows || 24};
    } catch (e) {}
  }));
}
// A pane dragged by its grip onto another swaps places with it, the pick of tab in a Tabs pane going with it.
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
    const ta = localStorage.getItem("tab:pane:" + from), tb = localStorage.getItem("tab:pane:" + to);
    tb == null ? localStorage.removeItem("tab:pane:" + from) : localStorage.setItem("tab:pane:" + from, tb);
    ta == null ? localStorage.removeItem("tab:pane:" + to) : localStorage.setItem("tab:pane:" + to, ta);
    change(l => { const a = nodeAt(l.root, from), b = nodeAt(l.root, to); putAt(l, from, b); putAt(l, to, a); });
  };
}
// The documents File panes show, by path, read again with every load so a change on disk shows within one refresh.
const fileDocs = {};
async function loadFiles() {
  const paths = [...new Set(leaves(layout().root).filter(([, n]) => n.show === "file" && n.path).map(([, n]) => n.path))];
  await Promise.all(paths.map(async p => {
    try {
      const r = await fetch("/doc?p=" + encodeURIComponent(p), {cache: "no-store"});
      fileDocs[p] = r.ok ? {text: await r.text()} : {status: r.status};
    } catch (e) {}
  }));
}
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
const atEnd = f => f.scrollHeight - f.scrollTop - f.clientHeight < 40;
const FEEDS = "#main :is(.card.full, .teamlog:not(.summary)) .feed";
function paneEnds() { return new Set([...document.querySelectorAll(FEEDS)].filter(atEnd).map(f => f.parentElement.closest("[data-name]").dataset.name)); }
const paneFeeds = new WeakSet();   // the panes' conversations already placed, so a new one starts at its end
function toPaneEnds(ends) {
  document.querySelectorAll(FEEDS + " .ago[data-ts]").forEach(s => { const t = since(s.dataset.ts); if (s.textContent !== t) s.textContent = t; });
  document.querySelectorAll(FEEDS).forEach(f => { if (ends.has(f.parentElement.closest("[data-name]").dataset.name) || !paneFeeds.has(f)) f.scrollTop = f.scrollHeight; paneFeeds.add(f); });
}
// The panes that can hold tabs (n.tabs, n.tab the one showing): the showing tab's configuration lives on the pane
// itself, where everything that draws the pane reads it; each tab's own is kept in n.tabs and swapped in when it is
// picked. A Combined pane's tab keeps its roles, lanes, badge, view and chat, a Team pane's who it leaves out and its
// view, a Grid's its roles and view.
const TABBED = ["combined", "team", "grid"];
const TAB_KEYS = ["roles", "clanes", "lanes", "badge", "view", "chat", "hide"];
function keepTab(n) {
  const t = n.tabs[n.tab || 0];
  for (const k of TAB_KEYS) if (k in n) t[k] = n[k]; else delete t[k];
}
function toTab(n, i) {
  keepTab(n);
  for (const k of TAB_KEYS) if (k in n.tabs[i]) n[k] = n.tabs[i][k]; else delete n[k];
  n.tab = i;
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
  const next = i < at ? at - 1 : Math.min(at, n.tabs.length - 1);
  for (const k of TAB_KEYS) if (k in n.tabs[next]) n[k] = n.tabs[next][k]; else delete n[k];
  n.tab = next;
  if (n.tabs.length < 2) { delete n.tabs; delete n.tab; }
}
function customClicks() {
  const main = $("#main"), change = f => { const l = layout(); f(l); saveLayout(l); draw(); };
  main.querySelectorAll(".pbar [data-act]").forEach(el => {
    const path = el.closest(".pane").dataset.path, act = el.dataset.act;
    if (act === "name" || act === "show" || act === "badge") { el.onchange = () => change(l => { nodeAt(l.root, path)[act] = el.value; }); return; }
    if (act === "move") { el.onpointerdown = e => movePane(e, el, path, change); return; }
    if (act === "path") { el.onchange = () => { change(l => { nodeAt(l.root, path).path = el.value.trim(); }); setTimeout(load); }; return; }
    el.onclick = () => change(l => {
      const n = nodeAt(l.root, path);
      if (act === "view") { n.view = el.dataset.v; setTimeout(load); }   // a full card needs its conversation
      else if (act === "row" || act === "col") putAt(l, path, {split: act, at: 0.5, a: n, b: {}});
      else if (act === "del") path === "r" ? putAt(l, "r", {}) : putAt(l, path.slice(0, -1), nodeAt(l.root, path.slice(0, -1))[path.endsWith("a") ? "b" : "a"]);
    });
  });
  main.querySelectorAll(".pane .roles.fbtn").forEach(el => {
    const path = el.closest(".pane").dataset.path;
    filterButton(el, roleItems(), () => rolesOn(nodeAt(layout().root, path)), r => `Show or leave out the ${roleList().find(x => x.role === r)?.name || r}`,
      r => { change(l => { const n = nodeAt(l.root, path), on = rolesOn(n); n.roles = on.includes(r) ? on.filter(x => x !== r) : [...on, r]; }); setTimeout(load); }, "Roles");
  });
  main.querySelectorAll(".pane .who.fbtn").forEach(el => {
    const path = el.closest(".pane").dataset.path;
    filterButton(el, whoItems(), () => whoOn(nodeAt(layout().root, path)), k => `${k.startsWith("role:") ? "Every" : "Only"} ${whoItems().find(([x]) => x === k)?.[1] || k} in the meeting, or not`,
      k => { change(l => { const n = nodeAt(l.root, path), on = whoOn(n); n.who = on.includes(k) ? on.filter(x => x !== k) : [...on, k]; }); setTimeout(load); }, "Who");
  });
  main.querySelectorAll(".meetbar [data-meet]").forEach(el => el.onclick = e => {
    const path = el.closest(".pane").dataset.path, n = nodeAt(layout().root, path), what = el.dataset.meet;
    if (what === "add") { e.stopPropagation(); return meetAdd(el, path); }
    const open = (m, away) => { m.active = Date.now(); m.started = [...new Set([...(m.started || []), ...away])]; };
    const close = m => { delete m.active; delete m.started; delete m.extra; };
    meetAsk = null;
    if (what === "start") { if (meetAway(n).length) meetAsk = {path, what}; else change(l => open(nodeAt(l.root, path), [])); }
    else if (what === "end") { if (meetMine(n).length) meetAsk = {path, what}; else change(l => close(nodeAt(l.root, path))); }
    else if (what === "start!") {
      const away = meetAway(n);
      change(l => open(nodeAt(l.root, path), away));
      away.forEach(x => post(`/api/agent/${encodeURIComponent(x)}/start`));
    } else if (what === "end!") {
      const mine = meetMine(n);
      change(l => close(nodeAt(l.root, path)));
      mine.forEach(x => post(`/api/agent/${encodeURIComponent(x)}/halt`));
    }
    draw(); setTimeout(load);
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
  // the tab showing is renamed in place: a click on it gives a box for its name, Enter or a click away keeps it, Esc
  // leaves it as it was
  const rename = el => {
    if (!el || pageLocked() || el.querySelector(".ctname")) return;
    const label = el.querySelector(".ctl"), was = label.textContent, box = Object.assign(document.createElement("input"), {className: "ctname", value: was});
    let done = false;
    const end = keep => { if (done) return; done = true; const v = box.value.trim();
      box.remove(); label.hidden = false;
      if (keep && v && v !== was) tabbed(el, n => { n.tabs[+el.dataset.i].title = v; }); else draw(); };
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
  main.querySelectorAll(".pane .ctab").forEach(el => el.onclick = e => {
    if (e.target.closest(".ctname")) return;
    if (e.target.closest(".cx")) tabbed(el, n => closeTab(n, +el.dataset.i));
    else if (el.classList.contains("sel")) rename(el);
    else tabbed(el, n => toTab(n, +el.dataset.i));
  });
  main.querySelectorAll(".pane .cadd").forEach(el => el.onclick = () => {
    const path = el.closest(".pane").dataset.path;
    tabbed(el, n => {
      if (!n.tabs?.length) { n.tabs = [{title: "Tab 1"}]; n.tab = 0; }
      keepTab(n);
      const copy = {...n.tabs[n.tab || 0], title: "Tab " + (n.tabs.length + 1)}; delete copy.chat;
      n.tabs.push(copy); toTab(n, n.tabs.length - 1);
    });
    rename($(`#main .pane[data-path="${path}"] .ctab.sel`));   // a new tab is named straight away
  });
  main.querySelectorAll(".teamlog .agents.fbtn").forEach(el => {
    const path = el.closest(".pane").dataset.path;
    filterButton(el, teamItems(), () => { const hide = nodeAt(layout().root, path).hide || []; return teamNames().filter(x => !hide.includes(x)); },
      x => `Show or leave out ${x}'s messages`, x => change(l => {
        const n = nodeAt(l.root, path), hide = new Set(n.hide || []);
        hide.has(x) ? hide.delete(x) : hide.add(x); n.hide = [...hide];
      }), "Agents");
  });
  // An agent in the list ("others") or a tile ("characters"), a name in a Combined pane's header, or a turn in a Team or Combined pane (the
  // agent on the name clicked, else the turn's own): one with a card in a pane gets the cursor in its message box, any other has its view opened. One in
  // a tabs pane behind another tab is brought to the front first.
  const goTo = name => {
    const box = () => main.querySelector(`.pane .card[data-name="${CSS.escape(name)}"] .say`);
    const tabs = !box() && leaves(layout().root).find(([, n]) => n.show === "tabs" && paneAgents(n).some(a => a.name === name));
    if (tabs) { localStorage.setItem("tab:pane:" + tabs[0], name); draw(); }
    box() ? aim(box()) : openDetail(name);
  };
  // an agent that is not running has nothing to open: a click on its row or tile opens its menu instead, as a tap
  // does on a touch screen, where nothing rests on it (the menu's Open goes to it)
  const open = m => m.classList.contains("off") || touched ? menuSoon(m, 0) : (menuOff(true), goTo(m.dataset.name));
  main.querySelectorAll(".others .mini").forEach(m => {
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
  menuGo = goTo;
  main.querySelectorAll(".teamlog:not(.combined) .thead .name").forEach(el => el.onclick = () => goTo(el.dataset.name));   // a Combined pane's are above
  // in a Combined pane's header a double-click on an agent opens the chat with it; a single click, once it is plainly
  // not the first of two, does what it does anywhere else
  main.querySelectorAll(".combined .cnames [data-name]").forEach(el => {
    const one = el.onclick, path = el.closest(".pane").dataset.path;
    let wait = 0;
    el.onclick = e => { clearTimeout(wait); if (e.detail < 2) wait = setTimeout(() => one(e), 250); };
    el.ondblclick = () => { clearTimeout(wait); menuOff(true); getSelection().removeAllRanges(); if (S.agents.find(a => a.name === el.dataset.name)?.live) chatWith(path, el.dataset.name); };
  });
  main.querySelectorAll(".teamlog .feed").forEach(f => f.onclick = e => {
    const row = e.target.closest(".it[data-agent]");
    if (!row || !getSelection().isCollapsed || e.target.closest("a, img, .thumbs, pre, [data-run]")) return;
    const named = e.target.closest(".who")?.textContent, name = S.agents.some(a => a.name === named) ? named : row.dataset.agent;
    if (S.agents.some(a => a.name === name)) goTo(name);
  });
  main.querySelectorAll(".pane .termseg b").forEach(b => b.onclick = e => { e.stopPropagation(); localStorage.setItem("term", termOn() ? "off" : "on"); draw(); });
  main.querySelectorAll(".card.full > .termwrap").forEach(w => w.onclick = e => {
    e.stopPropagation();
    if (!w.classList.contains("big")) paneBig = w.closest(".card").dataset.name;
    else if (e.target === w || e.target.matches(".pzoom, .x")) paneBig = null;
    else return;
    draw();
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
      at = Math.max(0.1, Math.min(0.9, row ? (mv.clientX - r.left) / r.width : (mv.clientY - r.top) / r.height));
      h1.style.flexGrow = at; h2.style.flexGrow = 1 - at;
    };
    d.onpointerup = () => {
      d.onpointermove = null; d.classList.remove("moving"); document.body.classList.remove("resizing", "resizing-row"); resizing = false;
      if (tiles != null) change(l => { nodeAt(l.root, d.dataset.path).tiles = tiles; });
      else if (at != null) change(l => { nodeAt(l.root, d.dataset.path).at = +at.toFixed(3); });
    };
  });
}

// Every pulse keeps time with the page's clock, so a card redrawn mid-beat carries on where its last copy was.
function beat() {
  for (const a of document.getAnimations()) if (a instanceof CSSAnimation && a.startTime !== 0) a.startTime = 0;
}

async function load() {
  try {
    S = await (await fetch("/api/state", {cache: "no-store"})).json();
    await loadPaneConvs();
    colours = Object.fromEntries([...S.agents, ...S.bench].map(a => [a.name, a.colour]));
    draw();
    if (menu.classList.contains("on")) menu.refresh?.();
  } catch (e) { $("#counts").innerHTML = `<span class="pill" style="color:var(--red)">offline</span>`; }
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
// " switching" while the page is starting the agent (alone or with the team) or stopping it, for its card, tab, List row and tile.
const switching = a => (a.live ? S.halting : S.starting).includes(a.name) ? " switching" : "";
function minis(cur, agents = S.agents) {
  const ceil = Math.max(1, ...S.agents.flatMap(a => a.series));
  return agents.map(a => {
    const st = stOf(a), n = a.name === cur ? 0 : unseen(a);
    return `<div class="mini ${st}${switching(a)}${a.name === cur ? " cur" : ""}" style="--c:${a.colour}" data-name="${esc(a.name)}">
      <div class="mtop"><span class="name" title="${STATE[st] || esc(st)}"><span class="dot"></span>${esc(a.name)}${n ? unseenBadge(n) : ""}</span>${a.ticket ? `<span class="ticket" title="${esc(a.ticket)}">${esc(a.ticket)}</span>` : ""}<span class="ago">${ago(a.held)}</span>${a.ctxPct == null ? "" : `<span class="pct" style="color:${gauge(a.ctxPct)}">${a.ctxPct}%</span>`}</div>
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
// bench's have none.
const face = (a, attrs, cls = "") => `<span class="face${cls}${"live" in a ? " " + stOf(a) : ""}" style="--c:${a.colour}" ${attrs}>${a.portrait ? `<img src="${esc(a.portrait)}" alt="${esc(a.name)}">` : shadow(a) + `<span class="ini">${esc([...a.name][0] || "")}</span>`}</span>`;
function tiles(them) {
  const ceil = Math.max(1, ...S.agents.flatMap(a => a.series)), nowS = Date.now() / 1000;
  return them.map(a => {
    const st = stOf(a), n = unseen(a);
    const last = a.feed.reduce((m, it) => it.ts && it.ts > m ? it.ts : m, ""), since = last ? Math.max(0, Math.round(nowS - Date.parse(last) / 1000)) : a.held;
    return `<div class="chr ${st}${switching(a)}" role="button" tabindex="0" style="--c:${a.colour}" data-name="${esc(a.name)}" aria-label="${esc(a.name)}">` +
      `<span class="por">${a.portrait ? `<img src="${esc(a.portrait)}" alt="">` : shadow(a)}</span>` +
      (a.portrait ? "" : `<span class="nm${LEFT_BADGE.has(a.role) ? " left" : ""}">${esc(a.name)}</span>`) +
      `<span class="tl"><i class="${since != null && since < 60 ? "now" : ""}"></i>${since == null ? "" : ago(since)}</span>` +
      `<span class="tr">${a.ctxPct == null ? "" : `<b class="${a.ctxPct >= 60 ? "hi" : ""}">${a.ctxPct}%</b>`}${n ? unseenBadge(n) : ""}</span>` +
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
  patch(el, [`<span class="state ${st}"><span class="dot"></span>${STATE[st] || esc(st)} ${ago(a.held)}</span>`,
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
  if (ONLY) document.title = name;
  const a = S.agents.find(x => x.name === name) || {};
  $("#detail .box").style.setProperty("--c", a.colour || "#888");
  $("#dhead").innerHTML = `<span class="name" style="--c:${a.colour}">${esc(name)}</span><span class="role">${esc(a.roleName || "")}</span>${a.ticket ? `<span class="ticket" style="margin-left:6px">${esc(a.ticket)}</span>` : ""}<span class="facts" id="dfacts"></span><span class="seg termseg"><b class="${termOn() ? "on" : ""}" title="Show or hide its terminal">Terminal</b></span><span class="seg railseg"><b title="Move the other agents' cards to the next edge"></b></span>${laneSeg(name)}<b class="fbtn" id="dmore" data-menu="agent:${esc(name)}" title="More">${MENU_ICON.more}</b><span class="x" title="Close (Esc)">✕</span>`;
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
  if (e.ctrlKey) { box.setRangeText("\n", box.selectionStart, box.selectionEnd, "end"); grow(box); }
  else {
    if (openAsk(S.agents.find(a => a.name === name))) { flash(box, "failed"); box.title = ASK_SHUT; } else say(name, box);
  }
}
// What the owner has sent to each agent from the page's message boxes, oldest first, the last hundred per agent, kept in
// this browser. In an agent's box, ↑ with the caret on the top line steps back through what was sent to that agent and
// ↓ on the bottom line forward again, to what was being written before the first ↑. Whether the caret was on that line
// is told by where the key left it: the browser moves it to the very start (or end) only from the top (or bottom) line.
const sentBy = (() => { try { return JSON.parse(localStorage.getItem("sentBy")) || {}; } catch (e) { return {}; } })();
let hist = {box: null, at: 0, draft: "", shown: null};
function logSent(name, text) {
  const log = sentBy[name] = sentBy[name] || [];
  if (log[log.length - 1] !== text) log.push(text);
  log.splice(0, log.length - 100);
  localStorage.setItem("sentBy", JSON.stringify(sentBy));
  hist.box = null;
}
function histKey(e, box, name) {
  const sentLog = sentBy[name] || [];
  if (!["ArrowUp", "ArrowDown"].includes(e.key) || e.altKey || e.ctrlKey || e.metaKey || e.shiftKey || box.selectionStart !== box.selectionEnd) return false;
  const up = e.key === "ArrowUp", from = box.selectionStart, v = box.value;
  if (up ? v.slice(0, from).includes("\n") : v.slice(from).includes("\n")) return false;
  const step = () => {
    if (hist.box !== box || hist.name !== name || box.value !== hist.shown) hist = {box, name, at: sentLog.length, draft: box.value, shown: null};
    const to = hist.at + (up ? -1 : 1);
    if (to < 0 || to > sentLog.length) return;
    hist.at = to;
    box.value = hist.shown = to === sentLog.length ? hist.draft : sentLog[to];
    box.selectionStart = box.selectionEnd = up ? 0 : box.value.length;   // so the next ↑ (or ↓) steps on at once
    grow(box); keep(box);
  };
  if (hist.box === box && hist.name === name && box.value === hist.shown) { e.preventDefault(); step(); return true; }
  setTimeout(() => { if (box.selectionStart === box.selectionEnd && box.selectionStart === (up ? 0 : box.value.length) && box.value === v) step(); });
  return false;
}
// The / list under a message box: typing / and a name lists the commands that match (Claude Code's own, the user's
// and the team's commands and skills, the plugins'), ↑/↓ choose, Tab completes, Enter completes and sends, Esc closes.
let slashCmds = null, slash = {box: null, at: 0, list: []};
const slashEl = Object.assign(document.createElement("div"), {id: "slash"});
document.body.append(slashEl);
async function slashShow(box) {
  const m = /^\/([\w:.-]*)$/.exec(box.value);
  if (!m) return slashOff();
  slashCmds = slashCmds || await fetch("/api/commands").then(r => r.json()).catch(() => []);
  const q = m[1].toLowerCase(), named = c => c.name.toLowerCase();
  const list = [...slashCmds.filter(c => named(c).startsWith(q)), ...slashCmds.filter(c => !named(c).startsWith(q) && named(c).includes(q))].slice(0, 8);
  if (!list.length || box.value !== "/" + m[1]) return slashOff();
  slash = {box, at: slash.box === box ? Math.min(slash.at, list.length - 1) : 0, list};
  slashEl.innerHTML = list.map((c, i) => `<div class="sl${i === slash.at ? " at" : ""}" data-i="${i}"><b>/${esc(c.name)}</b><span>${esc(c.desc)}</span></div>`).join("");
  const r = box.getBoundingClientRect();
  slashEl.style.cssText = `display:block;left:${r.left}px;width:${Math.max(r.width, 320)}px;bottom:${innerHeight - r.top + 4}px`;
  slashEl.querySelectorAll(".sl").forEach(el => el.onmousedown = e => { e.preventDefault(); slash.at = +el.dataset.i; slashDone(false); });
}
function slashOff() { slash = {box: null, at: 0, list: []}; slashEl.style.display = "none"; }
function slashDone(send, name) {
  const box = slash.box, c = slash.list[slash.at];
  slashOff();
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
// A message to the whole meeting: sent to each member who is running at once, each with its own echo; the box gets the
// text back only if it reached nobody, and says who it missed.
async function sayAll(key, input) {
  const path = key.slice(MEET.length), n = nodeAt(layout().root, path), text = input.value.trim(), sent = atts[key] || [];
  if (!text && !sent.length || input.disabled || saying.has(key)) return;
  const to = n ? meetAgents(n).filter(a => a.live && !openAsk(a)).map(a => a.name) : [];
  if (!to.length) { flash(input, "failed"); input.title = "Nobody in this meeting can take a message now"; return; }
  input.value = ""; grow(input); keep(input); input.disabled = true; saying.add(key);
  const said = text ? meetTag(n) + " " + text : meetTag(n), mine = to.map(name => [name, {text: said, at: Date.now(), state: "sending"}]);
  for (const [name, echo] of mine) if (echo) (echoes[name] = echoes[name] || []).push(echo);
  draw();
  const box = () => input.isConnected ? input : document.querySelector(`#main .say[data-name="${CSS.escape(key)}"]`) || input;
  const ok = await Promise.all(mine.map(([name, echo]) => fetch("/api/agent/" + encodeURIComponent(name) + "/say", {method: "POST",
      headers: {"Content-Type": "application/json", "X-Team-Say": "1"}, body: JSON.stringify({text: said, images: sent.map(i => i.path)})})
    .then(r => r.ok).catch(() => false).then(good => {
      if (good) echo.state = "sent"; else echoes[name] = echoes[name].filter(m => m !== echo);
      if (good) { if (text) logSent(name, text); chase(name, said); }
      return good;
    })));
  const missed = to.filter((x, i) => !ok[i]);
  if (missed.length < to.length) { if (text) logSent(key, text); atts[key] = (atts[key] || []).filter(i => !sent.includes(i)); showAtt(key); }
  draw();
  const b = box();
  if (missed.length === to.length) { b.value = text; grow(b); keep(b); }
  flash(b, missed.length ? "failed" : "sent"); b.title = missed.length ? `Not sent to ${andList(missed)}` : "";
  saying.delete(key); input.disabled = false; aim(box());
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
  else if ($("#docbox").classList.contains("on")) closeDoc();
  else if ($("#dterm").classList.contains("big")) zoom(false);
  else if (paneBig && !open) { paneBig = null; draw(); }
  else if (open || !unmax()) closeDetail();
});
addEventListener("resize", draw);

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
let menuShow = 0, menuHide = 0, menuGo = () => {};   // menuGo: Open, the layout's way to show an agent (its box, else its view)
// menuAt draws a menu at its anchor; with stay, an open one is drawn again where it is, keeping the item the keyboard
// is on, as the page's refresh does to keep a menu up to date (menu.refresh, which a menu that changes sets).
function menuAt(anchor, key, html, beside, stay) {
  if (stay) {
    const at = [...menu.querySelectorAll(".mi")].findIndex(m => m.classList.contains("at"));
    menu.innerHTML = html; menu.querySelectorAll(".mi")[at]?.classList.add("at");
    return;
  }
  menu.innerHTML = html; menu.dataset.key = key; delete menu.dataset.rested; menu.refresh = null; menu.classList.add("on");
  const r = anchor.getBoundingClientRect(), w = menu.offsetWidth, h = menu.offsetHeight;
  // a menu beside its tile would cover a tile next to it along a row, either side, so there it opens below (or above)
  // the tile instead
  const inRow = el => { const o = el?.getBoundingClientRect(); return !!o && o.width > 0 && o.top < r.bottom && o.bottom > r.top; };
  const row = beside && (inRow(anchor.nextElementSibling) || inRow(anchor.previousElementSibling));
  if (row) beside = false;
  const left = beside ? (r.right + 6 + w <= innerWidth ? r.right + 6 : r.left - 6 - w) : row ? Math.min(r.left, innerWidth - w - 6) : Math.min(r.right - w, innerWidth - w - 6);
  const top = beside ? r.top : r.bottom + 4 + h <= innerHeight ? r.bottom + 4 : r.top - 4 - h;
  menu.style.left = Math.max(6, left) + "px"; menu.style.top = Math.max(6, Math.min(top, innerHeight - h - 6)) + "px";
}
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
  ["Page", [["Alt+V", "Choose the view"], ["Alt+L", "This agent's filter, else the page's"], ["Alt+M", "Maximise this pane, or restore it"]]],
  ["Message box", [["Enter", "Send"], ["Ctrl+Enter", "New line"], ["Esc Esc", "Clear the box"], ["Ctrl+U", "Add images or files"]]],
  ["Anywhere", [["Esc", "Close what is open"], ["Ctrl+Click", "Open an agent in a new tab"], ["? or Alt+/", "These shortcuts"]]],
  ["Menus", [["↑ / ↓", "Move"], ["Enter / Space", "Pick, or tick"], ["Esc", "Close"]]],
];
function helpMenu(rested) {
  if (menuOn("help")) { if (!rested) menuOff(true); return; }
  const set = settings(), jump = Object.entries(jumpKeys()).sort().map(([d, n]) => [`${MODS[set.mod]}+${d}`, n]);
  const rows = SHORTCUTS.map(([h, rows]) => [h, rows.flatMap(([k, what]) => k !== "Alt+1 … 9" ? [[k, what]] : jump)]);
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
const SETTINGS = {fs: 100, conv: 100, box: 100, session: "off", suggest: "on", mod: "alt", keys: {}, jump: "box"};
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
  menuAt($("#settings"), "settings", `<div class="hd"><div>Settings, kept in this browser</div></div>` +
    `<label class="set"><span>Text size</span>${pick('data-set="fs"', set.fs, sizes)}</label>` +
    `<label class="set"><span>Conversation text</span>${pick('data-set="conv"', set.conv, sizes)}</label>` +
    `<label class="set"><span>Message box text</span>${pick('data-set="box"', set.box, sizes)}</label>` +
    `<label class="set"><span>Session limit</span>${pick('data-set="session"', set.session, [["off", "hidden"], ["on", "shown"]])}</label>` +
    `<label class="set"><span>Suggested prompts</span>${pick('data-set="suggest"', set.suggest, [["on", "shown"], ["off", "hidden"]])}</label>` +
    `<div class="hd"><div>Jump to an agent</div></div>` +
    `<label class="set"><span>Hold</span>${pick('data-set="mod"', set.mod, Object.entries(MODS))}</label>` +
    `<label class="set"><span>Goes to</span>${pick('data-set="jump"', set.jump, [["box", "its message box"], ["view", "its full view"]])}</label>${keys}` +
    `<button data-reset>Reset to defaults</button>`, false, redraw);
  menu.querySelectorAll("select").forEach(sel => sel.onchange = () => {
    const now = settings();
    if (sel.dataset.agent) {   // the keys as they stand, list order included, with this agent moved to its new key
      const keys = Object.fromEntries(Object.entries(jumpKeys()).filter(([d, n]) => n !== sel.dataset.agent && d !== sel.value));
      if (sel.value) keys[sel.value] = sel.dataset.agent;
      now.keys = keys;
    } else now[sel.dataset.set] = ["mod", "jump", "session", "suggest"].includes(sel.dataset.set) ? sel.value : +sel.value;
    localStorage.setItem("settings", JSON.stringify(now)); applySettings(); settingsMenu(true); draw();
  });
  menu.querySelector("[data-reset]").onclick = () => { localStorage.removeItem("settings"); applySettings(); settingsMenu(true); };
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
    const pane = (localStorage.getItem("page") || "grid") === "custom" && leaves(layout().root).find(([, n]) => ["tabs", "meeting"].includes(n.show) && paneAgents(n).some(a => a.name === name));
    if (pane) { localStorage.setItem("tab:pane:" + pane[0], name); draw(); }
    else $(`#main .tabbar button[data-tab="${CSS.escape(name)}"]`)?.click();
  }
  box() ? aim(box()) : openDetail(name);
}
addEventListener("keydown", e => {
  const typing = e.target.closest?.("textarea, input, select");
  if (!e.altKey && !e.ctrlKey && !e.metaKey && e.key === "?" && !typing) { e.preventDefault(); helpMenu(false); return; }
  const digit = /^Digit([1-9])$/.exec(e.code);
  if (digit && S && jumpMod(e, settings().mod, typing)) { e.preventDefault(); e.stopPropagation(); focusAgent(jumpTo(digit[1])); return; }
  if (!e.altKey || e.ctrlKey || e.metaKey || !S) return;
  const names = S.agents.map(a => a.name), cur = here(), at = names.indexOf(cur);
  const step = d => names[at < 0 ? (d > 0 ? 0 : names.length - 1) : (at + d + names.length) % names.length];
  const act = e.code === "ArrowDown" || e.code === "ArrowUp" ? () => focusAgent(step(e.code === "ArrowDown" ? 1 : -1))
    : e.code === "KeyW" ? () => focusAgent(S.agents.filter(a => a.status === "waiting").sort((x, y) => (y.held || 0) - (x.held || 0))[0]?.name)
    : e.code === "Enter" ? () => { if (!open) return openDetail(cur || names[0]); closeDetail(); if (!open) aim(shownBox(cur)); }
    : e.code === "KeyV" ? () => $("#pagemode .viewbtn")?.click()
    : e.code === "KeyL" ? () => ((cur && open === cur && $("#dhead .lanes")) || (cur && $(`#main .card[data-name="${CSS.escape(cur)}"] .lanes`)) || $("#pagelanes .fbtn")).click()
    : e.code === "KeyM" ? () => maxToggle()
    : e.code === "Slash" ? () => helpMenu(false) : null;
  if (!act) return;
  e.preventDefault(); e.stopPropagation(); act();
}, true);
addEventListener("mousedown", e => {
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
      : !a.live ? `<div class="mi" data-go="start">${MENU_ICON.start}Start ${esc(name)}</div>`
      : confirm ? `<div class="ask">Ask ${esc(name)} to finish, update its record and stop? Its pane closes once it is idle.</div>` +
        `<div class="mi warn" data-go="halt">${MENU_ICON.power}Stop ${esc(name)}</div><div class="mi" data-go="cancel">${MENU_ICON.close}Cancel</div>`
      : `<div class="mi" data-go="ask">${MENU_ICON.power}Stop ${esc(name)}…</div>`;
  }
  const chatIn = a.live && anchor.closest?.(".teamlog.combined") && anchor.closest(".pane")?.dataset.path;   // a Combined pane's chat
  // its name and details, with its second portrait, else its portrait, on the right
  menuAt(anchor, key, `<div class="hd"><div class="hrow"><div class="htxt"><span class="name" style="--c:${a.colour}">${esc(a.name)}</span><div>${esc(a.roleName || "")}${a.ticket ? " · " + esc(a.ticket) : ""}</div>` +
    `<div>${STATE[st] || esc(st)}${a.held == null ? "" : " · " + ago(a.held)}${ctx}</div>${model}</div>` +
    `${a.altPortrait || a.portrait ? `<span class="mpor"><img src="${esc(a.altPortrait || a.portrait)}" alt=""></span>` : ""}</div>${usage}${lastCompact(a)}</div>` +
    (bench ? (bench.standing ? power : "") : !a.live ? power :   // a benched developer or tester has only its details, a benched standing agent its Start; one that is not running has nothing to open
      (name === open ? "" : `<div class="mi" data-go="open">${MENU_ICON.open}Open<kbd>Click</kbd></div>`) +   // not the agent already in the view
      `<div class="mi" data-go="tab">${MENU_ICON.tab}Open in new tab<kbd>Ctrl+Click</kbd></div>` +
      `<div class="mi" data-go="window">${MENU_ICON.window}Open in new window</div>` +
      (chatIn ? `<div class="mi" data-go="chat">${MENU_ICON.said}Chat<kbd>Double-click</kbd></div>` : "") + `<div class="sep"></div>${compact}${power}`), beside, stay);
  if (rested && !stay) menu.dataset.rested = "1";
  menu.refresh = () => agentMenu(anchor, name, beside, false, confirm, true);
  menu.querySelectorAll(".mi[data-go]").forEach(mi => mi.onclick = () => {
    const go = mi.dataset.go;
    if (go === "ask") return agentMenu(anchor, name, beside, false, true);
    menuOff(true);
    if (go === "chat") chatWith(chatIn, name);
    else if (go === "start") post(`/api/agent/${encodeURIComponent(name)}/start`);
    else if (go === "halt" || go === "compact") post(`/api/agent/${encodeURIComponent(name)}/${go}`);
    else if (go !== "cancel") ({tab: inNewTab, window: inWindow}[go] || (open ? openDetail : menuGo))(name);   // with a view open, Open shows the agent there
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
    `${esc(a.name)}${MENU_ICON.check.replace("<svg", `<svg class="tick${a.name === cur ? "" : " off"}"`)}</div>`).join(""), false);
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
// Whether the last press was a finger. A tap sends mouseenter too, and a rest's menu must not open on it.
let touched = false;
document.addEventListener("pointerdown", e => { touched = e.pointerType === "touch"; }, true);
function menuSoon(el, wait) {
  if (wait > 0 && touched) return;
  clearTimeout(menuShow); clearTimeout(menuHide);
  // A redraw in the wait replaces el; a detached one measures as 0,0 and the menu would open in the corner.
  menuShow = setTimeout(() => el.isConnected && agentMenu(el, el.dataset.name, true, wait > 0), wait);
}
// The team's play, pause and stop buttons, one of them on at a time: stop (red) while nobody runs or the page has wound
// the team down (team/team-paused.sh says so and nobody is working), pause (amber) while the nudger is paused, play (green) while the
// team runs. Play starts a stopped team (those running when the page last stopped it, else everyone with a Session) or
// resumes the nudger; pause pauses the nudger; stop asks the lead to wind the team down, after a second click to
// confirm. The button clicked fades in and out in its colour until the page sees the change.
let teamAsk = null, nudgerTo = null;   // nudgerTo: the nudger state a click is waiting to see
function teamButton() {
  const lead = S.agents.find(a => a.role === "lead"), starting = S.starting.includes("team");
  const working = S.agents.filter(a => a.live && (a.status === "busy" || a.status === "waiting" || a.compacting)).map(a => a.name);
  const stopping = !starting && S.halting.includes("team");
  const woundDown = !starting && !stopping && !!S.teamUp && S.teamPaused && !working.length;
  const down = !starting && !stopping && (woundDown || !lead?.live);
  if (nudgerTo != null && nudgerTo === S.nudgerPaused) nudgerTo = null;
  if (down || stopping || starting) { clearTimeout(teamAsk); teamAsk = null; }
  const on = starting || stopping || nudgerTo != null ? "" : down ? "stop" : S.nudgerPaused ? "pause" : "play";
  const go = starting || nudgerTo === false ? "play" : stopping ? "stop" : nudgerTo ? "pause" : "";
  const tips = {
    play: starting ? "Starting the team" : nudgerTo === false ? "Resuming the nudger" : on === "play" ? "The team is running"
      : on === "pause" ? "Resume the nudger"
      : `Start ${S.teamUp ? S.teamUp.join(", ") + ", who were running when the team stopped" : "the team: everyone with a Session on the roster"}`,
    pause: nudgerTo ? "Pausing the nudger" : on === "pause" ? "The nudger is paused" : on === "play" ? "Pause the nudger" : "",
    stop: stopping ? (working.length ? `Stopping: waiting for ${working.join(", ")}` : `Stopping: waiting for ${lead?.name || "the lead"} to pause the nudger`)
      : teamAsk ? `Click again to ask ${lead.name} to wind the team down: everyone stops at a clean point and the nudger pauses`
      : on === "stop" ? "The team is stopped" : lead ? `Stop the team: ask ${lead.name} to wind everyone down` : "",
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
    if (go || on === "stop" || !lead) return;
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
    clearTimeout(menuHide); if (menuOn(btn.dataset.menu)) return;
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
setInterval(load, 4000); setInterval(() => refreshDetail(false), 2500);
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
                 TEAM_UP=T + "/state/team-up", TEAM_START_LOG=T + "/state/team-start.log",
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
        t("grouped: by role in the panel's order, file order within a role, an unknown role before the assistant",
          [r["name"] for r in grouped([{"name": n, "role": ro} for n, ro in [
              ("Max", "assistant"), ("Tess", "tester"), ("Rex", "code-reviewer"), ("Zed", "developer"), ("Pip", "ops"),
              ("Vi", "head-of-testing"), ("Ada", "developer"), ("Lea", "delivery-lead"), ("Ann", "tester")]])],
          ["Lea", "Zed", "Ada", "Tess", "Ann", "Rex", "Vi", "Pip", "Max"])

        # A session is its process's GIT_AUTHOR_EMAIL's agent; without one, the record's name.
        env = {k: v for k, v in os.environ.items() if k != "GIT_AUTHOR_EMAIL"}
        for i, (name, email) in enumerate([("someone-else", "ada@proj.local"), ("lea", ""), ("Stranger", ""), ("Ben", "")]):
            kid = subprocess.Popen(["sleep", "60"], env=dict(env, **({"GIT_AUTHOR_EMAIL": email} if email else {})))
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
                    "'proj-ada\t%1\t✳ Ada\tnode\t120\t40' 'Work-3\t%2\t✳ Lea\tclaude\t100\t30' 'Work\t%2\t✳ Lea\tclaude\t100\t30' 'other\t%3\t✳ Nobody\tclaude\t80\t24'\n")
        with open(T + "/bin/budget", "w") as f:
            f.write("#!/usr/bin/env bash\necho 'budget  over: week 38% used of 36% planned so far'\n")
        os.chmod(T + "/bin/tmux", 0o755)
        os.chmod(T + "/bin/budget", 0o755)
        with open(T + "/bin/day", "w") as f:
            f.write("#!/usr/bin/env bash\necho 'day  none: no day open'; exit 3\n")
        os.chmod(T + "/bin/day", 0o644)   # as the script is: run with bash, not by its mode
        os.environ["PATH"] = T + "/bin:" + os.environ["PATH"]
        t("panes: the agent's own tmux session, or a claude pane titled with its name",
          {n: p["pane"] for n, p in panes().items()}, {"Ada": "%1", "Lea": "%2"})

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
        t("  the week's plan and the plan shared out evenly", (st["plan"], st["even"]), (36, 40.0))
        t("  and no day, while none is open", st["day"], None)
        for line, want in (("day  on: 11% of the day's 15% used (week 69%, from 58% at 06:05)", {"used": 11, "quota": 15, "from": 58}),
                           ("day  over: 16% of the day's 15% used (week 74%, from 58% at 06:05): write your durable record and pause",
                            {"used": 16, "quota": 15, "from": 58}),
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
        t("  and its state", sorted(json.loads(code("/api/state")[1])), ["agents", "bench", "compacting", "day", "disk", "even", "halting", "now", "nudgerPaused", "owner", "plan", "plugins", "session", "starting", "tabs", "teamPaused", "teamUp", "week"])
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
            f.write("Ada\nGone\n")
        t("the next start brings back those recorded who are still on the roster, and the lead", team_up(), ["Lea", "Ada"])
        t("a team start without the page's header is refused", code("/api/team/start", "POST", {}, b"")[0], 403)
        t("a team start is taken", code("/api/team/start", "POST", {"X-Team-Say": "1"}, b"")[0], 202)
        wait_for(lambda: os.path.exists(T + "/started"), 15, 0.2)
        t("  and runs team-start.sh for those recorded", open(T + "/started").read().strip() if os.path.exists(T + "/started") else "", "--only Lea --only Ada")
        t("  and uses the record up", wait_for(lambda: not os.path.exists(T + "/state/team-up"), 5, 0.2), True)
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
        t("  and the facts it is given are the page's numbers, and each agent's state and activity only",
          sorted(bar_facts({"week": 1, "tabs": [], "agents": [{"name": "A", "status": "busy", "rate": 3, "series": [1], "convo": "x"}]})),
          ["agents", "day", "disk", "even", "now", "plan", "session", "week"])
        _plugged[T + "/shipped/echo"]["every"], _plugged[T + "/shipped/echo"]["at"] = 30, time.time() - 20
        plugins()
        t("  run again only once its own pace has passed", T + "/shipped/echo" in _plugging, False)
        bar = os.path.join(ROOT, "team", "bar")
        sh = lambda f, facts: json.loads(subprocess.run([os.path.join(bar, f)], input=json.dumps(facts), capture_output=True, text=True).stdout)
        txt = lambda j: "".join(p if isinstance(p, str) else p["text"] for p in j["value"]) if isinstance(j["value"], list) else j["value"]
        day = {"used": 12, "quota": 15, "from": 58}
        t("team/bar/week: with a day open, the week and the day's use, marked at the day's stop",
          (txt(w := sh("week", {"week": 70, "plan": 85, "day": day})), w["meter"]["mark"], w["value"][0]["colour"]), ("70% - Day: 12%", 73, "green"))
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
        gap = {"used": 2, "quota": None, "from": 74}
        t("between days: the verification day is a day whose share runs to the week's plan, in the header and both bars",
          (txt(sh("week", {"week": 76, "plan": 85, "day": gap})), sh("week", {"week": 76, "plan": 85, "day": gap})["meter"]["mark"],
           sh("weekbar", {"week": 76, "plan": 85, "day": gap})["meter"]["mark"], (d := sh("daybar", {"plan": 85, "day": gap}))["label"], txt(d),
           round(d["meter"]["pct"]), d["value"][0]["colour"], sh("daybar", {"plan": 85, "day": {**gap, "used": 12}})["value"][0]["colour"]),
          ("76% - Day: 2%", 85, 85, "Day", "2%", 18, "green", "red"))
        t("  and with no plan, hidden like no day at all", sh("daybar", {"day": gap})["hidden"], True)
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
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
