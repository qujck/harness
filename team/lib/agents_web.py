#!/usr/bin/env python3
"""The team as a web page, on this machine only. Run through team/agents-web.sh, which loads harness.env.

  /                 the page: the week, the disk and every running agent on the roster, in sections by role, each
                    with its state, context, burn, ticket and the last turns of its conversation
  /api/state        everything the page draws, as JSON
  /api/agent/NAME   one agent's longer conversation and its terminal as it is on screen now (HTML)
  POST /api/agent/NAME/say   {"text": "...", "images": [pasted paths]} typed into the agent's tmux pane, then Enter
  POST /api/agent/NAME/stop  Esc in the agent's pane, while it is working
  POST /api/paste    an image pasted into the page, kept under ~/.local/state/<project>/pasted for a message to attach

It reads what team/agents-dash.sh reads - agents/roster.json, Claude Code's session records, the context rows
(docs/context-publisher.md), the panel's burn cache and claims board, team/agents-budget.sh - plus tmux for each
agent's pane (the session agent-spawn.sh starts, <project>-<name>) and the tail of each agent's transcript for its
conversation. What it does is type into an agent's pane, as agent-spawn.sh types a first prompt. Only this page can
send: the request must be addressed to this host and port, carry the X-Team-Say header (which another site's page
cannot send without a CORS preflight this server never answers), and, where the browser names an Origin, come from
here. It listens on 127.0.0.1 only: nothing off this machine can reach it.
"""
import base64
import glob
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser("~")
ROOT = os.environ.get("HARNESS_ROOT") or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROJECT = os.environ.get("HARNESS_PROJECT") or os.path.basename(ROOT)
STATE_DIR = os.path.join(HOME, ".local/state", PROJECT)
PORT = int(os.environ.get("AGENT_WEB_PORT") or "8787")
ROSTER = os.environ.get("ROSTER_FILE") or os.path.join(ROOT, "agents/roster.json")
BUDGET = os.environ.get("AGENTS_BUDGET") or os.path.join(ROOT, "team/agents-budget.sh")
LEDGER = os.environ.get("AGENTS_DASH_LEDGER") or os.path.join(ROOT, "scripts/ledger-db.sh")
CLAUDE = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.join(HOME, ".claude")
SESSIONS = os.path.join(CLAUDE, "sessions")
PROJECTS = os.path.join(CLAUDE, "projects")
CONTEXT_DIR = os.environ.get("CONTEXT_DIR") or os.path.join(STATE_DIR, "context")
CACHE = os.environ.get("AGENTS_DASH_CACHE") or os.path.join(STATE_DIR, "dash")
BURN = os.path.join(CACHE, "burn.json")
BOARD = os.path.join(CACHE, "board")   # the claims board as the panel caches it: id|area|claimed_by
BOARD_EVERY = 60
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
         "process-improvement": ("process", "Process Improvement", "Others", "pink"),
         "assistant": ("pa", "Assistant", "Others", "green")}
TAB_ORDER = ["Lead", "Developers", "Testers", "Reviewer", "Others"]
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
    el = run("ps", "-o", "etime=", "-p", str(pid)).strip()
    parts = [int(x) for x in re.split(r"[-:]", el) if x.isdigit()] if el else []
    if not parts or not started_ms:
        return False
    secs = sum(v * m for v, m in zip(reversed(parts), (1, 60, 3600, 86400)))
    return time.time() - secs <= started_ms / 1000 + 60


def live_sessions():
    """Roster name -> Claude Code's own record of the session, for every session whose process and socket are live.
    A session is the agent whose roster address its process carries in GIT_AUTHOR_EMAIL, else the one its record is
    named, and only while its process is the session's own (team/lib/agent-session.sh)."""
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
        if not name or not sock or not os.path.exists(sock) or not pid_since(pid, rec.get("startedAt")):
            continue
        at = rec.get("statusUpdatedAt") or rec.get("updatedAt") or 0
        _socket_names[sock] = name
        if name not in best or at > best[name][0]:
            best[name] = (at, rec)
    return {n: r for n, (_, r) in best.items()}


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


def panes():
    """Roster name -> its tmux pane: the pane id and size of the session agent-spawn.sh starts for it,
    <project>-<name>, else of a pane titled with its name (a session started by hand)."""
    names = {r["name"].lower(): r["name"] for r in roster()}
    out = run("tmux", "list-panes", "-a", "-F",
              "#{session_name}\t#{pane_id}\t#{pane_title}\t#{pane_current_command}\t#{pane_width}\t#{pane_height}")
    by_name = {}
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 6:
            continue
        sess, pid, title, cmd, cols, rows = parts
        own = sess.startswith(PROJECT + "-") and names.get(sess[len(PROJECT) + 1:])
        name = own or names.get(re.sub(r"^[^A-Za-z]+", "", title).strip().lower())
        if name and (own or cmd == "claude") and (own or name not in by_name):
            by_name[name] = {"session": sess, "pane": pid, "cols": int(cols), "rows": int(rows)}
    return by_name


# ── the conversation ──────────────────────────────────────────────────────────
_paths, _feeds = {}, {}
_lock = threading.Lock()


def transcript(sid):
    if sid not in _paths or not os.path.exists(_paths[sid] or ""):
        hits = glob.glob(os.path.join(PROJECTS, "*", sid + ".jsonl"))
        _paths[sid] = hits[0] if hits else None
    return _paths[sid]


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


LANE = {"owner": "owner", "said": "owner", "peer": "team", "sent": "team", "event": "auto", "tool": "auto"}


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


def ask_of(pane):
    """The question an agent's pane is waiting on - a permission prompt or a choice - with its options, read
    from the screen: Claude Code writes a prompt to the transcript only once it is answered. It runs from just
    after the solid rule that opens the prompt to the end of the options, so a permission prompt keeps its
    heading and command; the dashed rules inside it become gaps. None when no numbered options are on screen."""
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
    return "\n".join(boxed.sub("", l) if boxed.match(l) else l[pad:] for l in block) or None


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
        return items + ([{"kind": "ask", "who": "waiting for you", "text": ask, "ts": None, "lane": "owner"}] if ask else []) + pending
    now = working_of(pane["pane"])
    return items + ([{"kind": "live", "who": "working", "text": now, "ts": None, "lane": "owner"}] if now else []) + pending


# ── the state the page draws ──────────────────────────────────────────────────
def colour(role):
    """The role's colour: AGENT_COLOUR_<ROLE> in harness.env, one of Claude Code's /color names, else the role's own."""
    key = "AGENT_COLOUR_" + role.upper().replace("-", "_")
    c = CC_COLOUR.get(os.environ[key].strip() if key in os.environ else role_of(role)[3])
    return xterm(c) if c else "#8b949e"


def state():
    now = time.time()
    live, rows, burns = live_sessions(), context_rows(), burn()
    where, held = panes(), claims()
    agents, bench = [], []
    for r in roster():
        name = r["name"]
        role, role_name, tab, _ = role_of(r["role"])
        rec = live.get(name)
        if not rec and not where.get(name):
            # a developer or tester with no session is on the bench, waiting for agent-spawn.sh
            if role in ("dev", "tester"):
                bench.append({"name": name, "role": role, "roleName": role_name, "colour": colour(r["role"])})
            continue
        sid = (rec or {}).get("sessionId")
        row = rows.get(sid, {}) if sid else {}
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
            "cwd": row.get("worktree") or os.path.basename((rec or {}).get("cwd", "")),
            "series": ser, "rate": last_minute(ser, now),
            "feed": with_ask(by_lane(feed(sid, 300), 10) if sid else [], (rec or {}).get("status"), where.get(name)),
        })
    tabs = [t for t in TAB_ORDER if any(a["tab"] == t for a in agents)]
    tabs += sorted({a["tab"] for a in agents} - set(tabs))
    return {
        "now": now, "week": account_pct(rows, "week"), "plan": (plan := budget_plan()), "even": even_plan(plan),
        "disk": disk(),
        "tabs": tabs,
        "agents": agents, "bench": bench, "owner": setting("AGENT_OWNER_NAME") or "Owner",
    }


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


IMAGE_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif", ".webp": "image/webp"}
PASTED = os.path.join(STATE_DIR, "pasted")   # images pasted into the page, kept for the agents to read


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype, cache="no-store"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", cache)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/":
            self.send(200, PAGE.encode(), "text/html; charset=utf-8")
        elif path == "/api/state":
            self.send(200, state_json(), "application/json")
        elif path.startswith("/api/agent/") and re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]*", path[11:]):
            self.send(200, agent_json(path[11:]), "application/json")
        elif path == "/img":
            self.image()
        else:
            self.send(404, b"not found\n", "text/plain")

    def image(self):
        """An image an agent names by its path, full or from its own folder, for the page to show: only from the page
        itself (the Host check keeps other sites out), only an image file, and only from under the home directory."""
        if self.headers.get("Host") not in {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}:
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
        m = re.fullmatch(r"/api/agent/([A-Za-z][A-Za-z0-9_-]*)/(say|stop)", self.path)
        if not m and self.path != "/api/paste":
            return self.send(404, b"not found\n", "text/plain")
        here = {f"127.0.0.1:{PORT}", f"localhost:{PORT}"}
        origin = self.headers.get("Origin")
        if self.headers.get("Host") not in here or self.headers.get("X-Team-Say") != "1" or \
                (origin and origin.removeprefix("http://") not in here):
            return self.send(403, b"only the team page can send\n", "text/plain")
        if not m:
            return self.paste()
        if m.group(2) == "stop":
            return self.stop(m.group(1))
        try:
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(min(n, 20000)) or b"{}")
            text, images = str(body.get("text", "")), [str(i) for i in body.get("images") or []][:8]
        except (ValueError, json.JSONDecodeError, AttributeError, TypeError):
            return self.send(400, b"bad request\n", "text/plain")
        text = re.sub(r"[\x00-\x09\x0b-\x1f\x7f]+", " ", text.replace("\r\n", "\n")).strip()[:4000]
        if any(os.path.dirname(os.path.realpath(i)) != PASTED or not os.path.isfile(i) for i in images):
            return self.send(400, b"an image is not one pasted here\n", "text/plain")
        if not text and not images:
            return self.send(400, b"nothing to send\n", "text/plain")
        where = panes().get(m.group(1))
        if not where:
            return self.send(404, b"that agent is not in a pane\n", "text/plain")
        # The text goes in as one bracketed paste, as a terminal pastes, so its line breaks stay line breaks in the
        # agent's message box instead of sending it early. Each image follows as a paste of its path alone, which
        # Claude Code attaches as an image, as when a file is dragged in.
        ok = True
        for i, part in enumerate(([text + " "] if text else []) + images):
            if i:
                time.sleep(0.3)
            buf = "agents-web-" + uuid.uuid4().hex[:12]
            ok = ok and subprocess.run(["tmux", "load-buffer", "-b", buf, "-"], input=part.encode()).returncode == 0
            ok = ok and subprocess.run(["tmux", "paste-buffer", "-p", "-d", "-b", buf, "-t", where["pane"]]).returncode == 0
        time.sleep(0.2)   # an Enter in the same burst as the paste can be swallowed
        ok = ok and subprocess.run(["tmux", "send-keys", "-t", where["pane"], "Enter"]).returncode == 0
        with _lock:
            _state["at"] = 0
        self.send(200 if ok else 500, json.dumps({"sent": ok}).encode(), "application/json")

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

    def paste(self):
        """Keeps an image pasted into the page as a file in PASTED, for a message to attach; returns its path."""
        ext = {v: k for k, v in IMAGE_TYPES.items()}.get((self.headers.get("Content-Type") or "").split(";")[0].strip())
        n = int(self.headers.get("Content-Length") or 0)
        if not ext or not 0 < n <= 25_000_000:
            return self.send(400, b"only an image of up to 25 MB\n", "text/plain")
        os.makedirs(PASTED, exist_ok=True)
        path = os.path.join(PASTED, time.strftime("%Y-%m-%d_%H-%M-%S_") + uuid.uuid4().hex[:6] + ext)
        with open(path, "wb") as f:
            f.write(self.rfile.read(n))
        self.send(200, json.dumps({"path": path, "url": "/img?p=" + urllib.parse.quote(path)}).encode(), "application/json")

    def log_message(self, *args):
        pass


PAGE = r"""<!doctype html>
<html lang="en-GB">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Team</title>
<style>
:root{
  --track:#ffffff10; --soft:#ffffff06; --section:#0b0f15aa; --card1:#161b22f0; --card2:#0d1117f0; --hover:#ffffff40; --text2:#c9d1d9;
  --codebg:#ffffff12; --box:#0d1117; --glow1:#1f6feb22; --glow2:#a371f71c; --thumb:#ffffff1c; --ownerbg:#f0f6fc; --ownerfg:#000;
  --bg:#07090d; --panel:#0d1117cc; --line:#ffffff14; --line2:#ffffff22; --on:#ffffff38; --text:#e6edf3; --mute:#8b949e; --faint:#545d68;
  --green:#3fb950; --amber:#e3b341; --red:#f85149; --cyan:#39c5cf;
  --sans:"Segoe UI Variable Text","Segoe UI",Inter,system-ui,sans-serif; --mono:"Cascadia Code","JetBrains Mono",Consolas,ui-monospace,monospace;
}
:root.light{
  --bg:#f3f5f8; --panel:#ffffffcc; --line:#0000000f; --line2:#0000001c; --on:#0000001c; --text:#1f2328; --mute:#59636e; --faint:#8c959f;
  --green:#1a7f37; --amber:#d29a00; --red:#cf222e; --cyan:#0969da;
  --track:#0000000f; --soft:#ffffff; --section:#ffffffb0; --card1:#ffffff; --card2:#fbfcfd; --hover:#00000033; --text2:#31373e;
  --codebg:#0000000c; --box:#ffffff; --glow1:#54aeff26; --glow2:#c297ff1f; --thumb:#00000024; --ownerbg:#1f2328; --ownerfg:#fff;
}
:root.light .card{box-shadow:0 1px 2px #0000000d,0 4px 14px -6px #0000001a}
:root.light .card.busy{box-shadow:0 0 0 1px #1a7f3733,0 6px 20px -8px #1a7f3755}
:root.light .meter u{box-shadow:none}
*{box-sizing:border-box;margin:0}
html,body{height:100%;overflow:hidden}
body{font:13px/1.45 var(--sans);color:var(--text);background:var(--bg);display:flex;flex-direction:column;
  background-image:radial-gradient(1200px 600px at 10% -10%,var(--glow1),transparent 60%),radial-gradient(900px 500px at 110% 110%,var(--glow2),transparent 60%)}
header{display:flex;align-items:center;gap:22px;padding:12px 18px;border-bottom:1px solid var(--line);flex:none}
.brand{display:flex;align-items:center;flex:none}
.stat{display:flex;flex-direction:column;gap:4px;min-width:150px}
.stat .k{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-size:10.5px;letter-spacing:.12em;text-transform:uppercase;color:var(--mute)}
.stat .v{font:600 13px var(--mono)}
#teamspark{width:190px;height:22px;color:var(--ownerbg)}#teamspark svg.spark{height:22px}
.meter{position:relative;height:8px;border-radius:5px;background:var(--track);overflow:visible;width:190px}
.meter i{position:absolute;inset:0 auto 0 0;border-radius:5px;transition:width .6s}
.meter u{position:absolute;top:-4px;bottom:-4px;width:2px;background:var(--text);border-radius:2px;box-shadow:0 0 6px #fff8}
.counts{flex:none;display:flex;gap:8px}
.pill{display:flex;align-items:center;gap:6px;padding:5px 10px;border:1px solid var(--line2);border-radius:999px;font:600 12px var(--mono);background:var(--soft);color:var(--text)}
.pill.btn{cursor:pointer;color:var(--mute);font-family:var(--sans)}
.pill.btn:hover{color:var(--text);border-color:var(--hover)}
.pill.tally{position:relative;gap:5px}
.pill.tally b:first-of-type{margin-right:5px}
.pill.tally .wait{position:absolute;inset:-1px;display:flex;align-items:center;justify-content:center;border-radius:999px;border:2px solid #ffb020;color:#000;font:700 12.5px var(--sans);white-space:nowrap;animation:pillflash 1s ease-in-out infinite}
.bench{flex:1;min-width:0;display:grid;grid-template-columns:auto minmax(0,1fr);gap:4px 6px;align-items:center;color:var(--faint);font-size:11px}
.bench .rrow{display:flex;gap:5px;min-width:0;overflow:hidden}
.bench em{flex:none;font-style:normal;padding:1px 7px;border-radius:5px;border:2px solid var(--c);color:var(--mute)}
main{position:relative;flex:1;min-height:0;display:grid;grid-template-rows:minmax(0,1fr);gap:14px;padding:14px}
.colgrip{position:absolute;top:14px;bottom:14px;width:14px;cursor:col-resize;z-index:3}
.colgrip::after{content:"";position:absolute;inset:0 5px;border-radius:2px;background:transparent;transition:background .15s}
.colgrip:hover::after,.colgrip.drag::after{background:var(--line2)}
body.resizing{cursor:col-resize;user-select:none}
/* Custom: the page split into panes, each an agent's card, the agents not on screen, or a grid or tabs of roles */
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
.pbar{flex:none;display:flex;flex-wrap:wrap;align-items:center;gap:6px 8px;padding:7px 10px;border-bottom:1px solid var(--line);font-size:11px;color:var(--mute)}
.pbar select{font:12px var(--sans);color:var(--text);background:var(--soft);border:1px solid var(--line2);border-radius:6px;padding:1px 4px}
.pbar em{font-style:normal;padding:0 7px;border-radius:5px;border:2px solid var(--c);color:var(--mute);cursor:pointer}
.pbar em.on{background:var(--c);color:#000}
.pbar .pacts{display:flex;gap:2px;margin-left:auto}
.pbar .pacts b{padding:1px 6px;border-radius:5px;font-size:13px;font-weight:400;cursor:pointer}
.pbar .pacts b:hover{background:var(--on);color:var(--text)}
.pbody{flex:1;min-height:0;display:flex;flex-direction:column}
.pbody .blank{margin:auto;color:var(--faint);font-size:12px}
.others{flex:1;min-height:0;overflow:auto;padding:10px;display:flex;flex-direction:column;gap:8px}
section.tab{min-height:0;display:flex;flex-direction:column;border:1px solid var(--line);border-radius:14px;background:var(--section);backdrop-filter:blur(8px)}
section.tab h2{min-height:41px;display:flex;justify-content:space-between;align-items:center;padding:9px 14px;font-size:11px;letter-spacing:.16em;text-transform:uppercase;color:var(--mute);font-weight:600;border-bottom:1px solid var(--line)}
.seg{display:flex;border:1px solid var(--line2);border-radius:7px;overflow:hidden;letter-spacing:0;text-transform:none}
.seg b{padding:2px 9px;font-weight:500;font-size:11px;cursor:pointer;color:var(--mute)}
.seg b.on{background:var(--on);color:var(--text)}
#pagemode,#pagelanes{display:flex}
#pagemode .seg,#pagelanes .seg{border-radius:999px;background:var(--soft)}
#pagemode .seg b,#pagelanes .seg b{display:flex;align-items:center;padding:0 12px;font-size:12px}
#lock{display:flex;margin-left:7px;padding:2px;border-radius:4px;opacity:.75}
#lock:hover{opacity:1;background:var(--line2)}
.tabbar{display:flex;flex-wrap:wrap;gap:6px;padding:10px 10px 0}
.tabbar button{--c:#888;display:flex;align-items:center;gap:6px;padding:4px 11px;border-radius:7px;border:1px solid var(--c);background:var(--c);
  color:#000;font:600 12.5px var(--sans);cursor:pointer}
.tabbar button:hover{filter:brightness(1.15)}
.tabbar button .dot{box-shadow:0 0 0 1.5px #000a}
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
@keyframes alarm{0%,100%{border-color:#b87400;box-shadow:0 0 0 0 #ffb02000,0 0 10px 0 #ffb02044}50%{border-color:#ffc94d;box-shadow:0 0 0 4px #ffb02088,0 0 46px 6px #ffb020cc}}
@keyframes wash{0%,100%{opacity:.06}50%{opacity:.3}}
@keyframes pillflash{0%,100%{background:#8a5a00}50%{background:#ffc94d}}
@keyframes ask{0%,100%{border-color:#c2410c;box-shadow:0 0 0 0 #ff7a1a00}50%{border-color:#ff9a3c;box-shadow:0 0 0 4px #ff7a1a99,0 0 22px 2px #ff7a1aaa}}
.top{display:flex;align-items:center;gap:8px;padding:10px 12px 6px}
.name{white-space:nowrap;background:var(--c);color:#000;font-weight:650;padding:1px 8px;border-radius:5px;font-size:13.5px}
.role{color:var(--mute);font-size:11.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.ticket{white-space:nowrap;flex:none;margin-left:auto;font:600 11.5px var(--mono);color:var(--cyan);background:#39c5cf14;border:1px solid #39c5cf33;padding:1px 7px;border-radius:5px}
.row2{display:flex;align-items:center;gap:10px;white-space:nowrap;min-width:0;padding:0 12px 8px;font:12px var(--mono);color:var(--mute)}
.state{display:flex;align-items:center;gap:6px;color:var(--text);font-family:var(--sans);font-weight:600}
.dot{width:8px;height:8px;border-radius:50%;background:var(--faint)}
.busy .dot{background:var(--green);box-shadow:0 0 0 0 #3fb95099;animation:ping 1.4s infinite}
.waiting .dot{background:var(--amber)}
.waiting .state{color:var(--amber)}
@keyframes ping{70%{box-shadow:0 0 0 7px #3fb95000}100%{box-shadow:0 0 0 0 #3fb95000}}
.ctx{display:flex;align-items:center;gap:6px;margin-left:auto}
.ctx .meter{width:64px;height:6px}
.model{color:var(--faint);overflow:hidden;text-overflow:ellipsis;min-width:0}
svg.spark{display:block;width:100%;height:26px;flex:none}
.feed{flex:1;min-height:0;overflow:hidden;display:flex;flex-direction:column;justify-content:flex-end;gap:5px;padding:8px 12px 10px;border-top:1px solid var(--line);
  mask-image:linear-gradient(180deg,transparent,#000 28px)}
.it{display:flex;gap:7px;font-size:12px;line-height:1.4;min-width:0}
.it .who{flex:none;font-weight:650;font-size:10.5px;padding:1px 6px;border-radius:4px;height:fit-content;margin-top:1px;letter-spacing:.02em}
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
.card .top{flex-wrap:wrap;row-gap:4px}
.lanes b,.termseg b,.railseg b{padding:1px 5px;font-size:10px}
.it.peer .who,.it.sent .who,.it.said .who{background:var(--pc,#444);color:#000}
.it.sent .who::before{content:"→ "}
.it.event .tx{color:var(--mute);font-style:italic}
.it.event .who{color:var(--mute);border:1px solid var(--line2)}
.it.ask{position:relative;z-index:1;flex-direction:column;gap:4px;padding:8px 10px;border:2px solid #ff7a1a;border-radius:8px;background:#ff7a1a1f;animation:ask 1s ease-in-out infinite}
.it.ask::after{content:"";position:absolute;inset:0;border-radius:6px;background:#ff7a1a;pointer-events:none;animation:wash 1s ease-in-out infinite}
.it.ask .who{align-self:flex-start;background:#ff7a1a;color:#000;text-transform:uppercase;letter-spacing:.06em}
.it.ask .tx{font:12px/1.35 var(--mono);white-space:pre-wrap;-webkit-line-clamp:unset;color:var(--text)}
.it.ask .ago{display:none}
.it.pending{align-items:flex-start;opacity:.8}
.it.pending .tx{flex:1}
.it.pending .badge{flex:none;font:600 10px var(--mono);color:var(--amber);border:1px dashed var(--amber);border-radius:4px;padding:0 5px;margin-top:2px}
.it.live{align-items:center}
.it.live .who{color:var(--c,var(--green));border:1px solid var(--c,var(--green));animation:livepulse 1.4s ease-in-out infinite}
.it.live .tx{font:11.5px var(--mono);color:var(--c,var(--green));-webkit-line-clamp:1}
.it.live .ago{display:none}
@keyframes livepulse{0%,100%{opacity:.45;box-shadow:none}50%{opacity:1;box-shadow:0 0 10px 1px var(--c,var(--green))}}
.it.tools .tx{font:11px var(--mono);color:var(--faint);-webkit-line-clamp:1}
.it.tools .tx b{color:var(--mute);font-weight:600}
.it .ago{flex:none;margin-left:auto;color:var(--faint);font:10.5px var(--mono);padding-left:4px}
code{font:11.5px var(--mono);background:var(--codebg);padding:0 4px;border-radius:4px;color:var(--text)}
code.flat{padding:0;background:none;color:var(--mute)}
.it.pics{flex-wrap:wrap}
.it .thumbs{flex-basis:100%;display:flex;flex-wrap:wrap;gap:6px;padding:2px 0 2px 2px}
.it .thumbs img{display:block;height:56px;max-width:120px;object-fit:cover;border-radius:5px;border:1px solid var(--line2)}
.it .thumbs a:hover img{border-color:var(--c,var(--hover))}
#detail .conv .it .thumbs img{height:auto;max-height:220px;max-width:360px;object-fit:contain}
#pop{position:fixed;z-index:20;display:none;max-width:560px;max-height:60vh;overflow:auto;padding:10px 13px;border-radius:9px;
  border:1px solid var(--line2);background:var(--box);color:var(--text);font-size:12.5px;line-height:1.45;white-space:pre-line;box-shadow:0 14px 40px #0009}
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
#lightbox figcaption{display:flex;gap:16px;font:12px var(--mono);color:#ccc}
#lightbox figcaption a{color:#9cf}
#lightbox .x{position:fixed;top:16px;right:22px;color:#ccc;cursor:pointer;font-size:20px;line-height:1}
#lightbox .x:hover{color:#fff}
pre.code{display:block;margin:5px 0;padding:7px 10px;font:11.5px/1.4 var(--mono);white-space:pre-wrap;word-break:break-word;background:var(--codebg);border:1px solid var(--line);border-radius:7px;color:var(--text)}
#detail pre.code{font-size:12.5px;margin:6px 0}
pre.code{position:relative}
pre.code .copy{position:absolute;top:5px;right:5px;display:none;place-items:center;width:26px;height:24px;padding:0;border-radius:5px;border:1px solid var(--line2);background:var(--box);color:var(--mute);cursor:pointer}
pre.code:hover .copy{display:grid}
pre.code .copy:hover{color:var(--text);border-color:var(--hover)}
pre.code .copy.done{color:var(--green);border-color:var(--green)}
#copied{position:fixed;z-index:50;pointer-events:none;padding:3px 8px;border-radius:6px;background:var(--green);color:#000;font:600 11px var(--sans);opacity:0;transition:opacity .25s}
#copied.on{opacity:1}
a.link{color:var(--cyan);text-decoration:underline;text-underline-offset:2px;word-break:break-all}
table.md{border-collapse:collapse;margin:4px 0;white-space:normal;width:max-content;max-width:100%}
table.md th,table.md td{border:1px solid var(--line2);padding:2px 8px;text-align:left;vertical-align:top}
table.md th{background:var(--line);font-weight:600}
.feed .it .tx{max-height:9em}
/* an agent pane's card: its longer conversation, every turn in full, scrolled */
.card.full .feed{overflow:auto;justify-content:flex-start;mask-image:none}
.card.full .feed > :first-child{margin-top:auto}
.card.full .it .tx{-webkit-line-clamp:unset;white-space:pre-wrap;max-height:none}
/* in a wide pane the card's name, state and model lines sit on one row, and in a middling one on two, with a slimmer
   burn line under them */
.pbody{container-type:inline-size}
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
  .card.full{display:grid;grid-template-columns:auto auto auto auto minmax(0,1fr) auto auto auto;grid-template-rows:auto auto minmax(0,1fr) auto auto;column-gap:10px}
  .card.full > *{grid-column:1/-1}
  .card.full > .top{display:contents}
  .card.full > .top > *,.card.full > .row2{grid-row:1;align-self:center}
  .card.full > .top > .name{grid-column:1;margin:10px 0 8px 12px}
  .card.full > .top > .role{grid-column:2}
  .card.full > .top > .ticket{grid-column:3;margin:0}
  .card.full > .top + .row2{grid-column:4;padding:0}
  .card.full > .row2 + .row2{grid-column:5;padding:0}
  .card.full > .top > .termseg{grid-column:6}
  .card.full > .top > .lanes{grid-column:7;margin:0 0 0 4px}
  .card.full > .top > .maxbtn{grid-column:8;margin-right:10px}
  .card.full > .termwrap{display:block;grid-row:3;grid-column:1/-1}
  .card.full.term .feed{padding-right:calc(340px + 40px)}
  .card.full > svg.spark{height:16px}
}
b.h{display:block;margin-top:2px;font-weight:700}
.empty{color:var(--faint);font-style:italic;font-size:12px}
/* detail */
#detail{position:fixed;inset:0;display:none;background:#000a;backdrop-filter:blur(6px);z-index:9;padding:3vh 3vw}
#detail.open{display:flex}
#detail.docked{background:none;backdrop-filter:none;padding:14px;z-index:2}
#detail.docked .box{box-shadow:none;border-radius:14px}
#detail.docked .head .x{display:none}
#detail .mini:not(.cur)::before,.others .mini::before{display:none}
#detail .box{--c:#888;--thumb:340px;--rail:220px;position:relative;flex:1;display:grid;grid-template-columns:minmax(0,1fr) var(--rail);grid-template-rows:auto minmax(0,1fr);border:1px solid var(--line2);border-radius:16px;background:var(--box);overflow:hidden;box-shadow:0 30px 80px #000c}
#detail .head{grid-column:1/-1;display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid var(--line);border-top:3px solid var(--c)}
#detail .head .lanes + .x{margin-left:14px}
#detail .head .termseg{margin-left:auto;flex:none}
#detail .head .termseg + .railseg,#detail .head .railseg + .lanes{margin-left:8px}
#detail .box.noterm .termwrap{display:none}
#detail .box.noterm .conv{padding-right:16px}
/* the header keeps its name, role and switches whole; the facts take the room left and drop whole, from the end,
   when there is not room for them all */
#detail .head > *{flex:none;white-space:nowrap}
#detail .head .facts{flex:1 1 0;display:flex;flex-wrap:wrap;align-items:center;gap:40px 14px;height:18px;margin-left:10px;min-width:0;overflow:hidden;white-space:nowrap;font:12px/18px var(--mono);color:var(--mute)}
#detail .head .facts > *{flex:none}
#detail .head .facts .state{display:flex;align-items:center;gap:6px;color:var(--text)}
#detail .head .x{margin-left:auto;color:var(--mute);cursor:pointer;font-size:20px;line-height:1}
/* every other agent in a column on the right, compressed to its status; a click moves to it. The header's edge
   button moves the column to the bottom, the left or the top, where the cards wrap in rows across the view. */
#detail .rail{grid-column:2;grid-row:2;min-height:0;overflow:auto;padding:10px;display:flex;flex-direction:column;gap:8px;border-left:1px solid var(--line)}
#detail .left{grid-column:1;grid-row:2}
#detail .box.rail-left{grid-template-columns:var(--rail) minmax(0,1fr)}
#detail .box.rail-left .rail{grid-column:1;border-left:0;border-right:1px solid var(--line)}
#detail .box.rail-left .left{grid-column:2}
#detail .box.rail-top,#detail .box.rail-bottom{grid-template-columns:minmax(0,1fr)}
#detail .box.rail-top{grid-template-rows:auto auto minmax(0,1fr)}
#detail .box.rail-bottom{grid-template-rows:auto minmax(0,1fr) auto}
#detail .box.rail-top .rail,#detail .box.rail-bottom .rail{grid-column:1;display:grid;grid-template-columns:repeat(auto-fill,minmax(calc(var(--rail) - 20px),1fr));max-height:35vh;border-left:0}
#detail .box.rail-top .rail{grid-row:2;border-bottom:1px solid var(--line)}
#detail .box.rail-top .left{grid-row:3}
#detail .box.rail-bottom .rail{grid-row:3;border-top:1px solid var(--line)}
.mini{--c:#888;position:relative;flex:none;padding:8px 10px 4px;border-radius:9px;border:1px solid var(--line2);background:linear-gradient(180deg,var(--card1),var(--card2));
  cursor:pointer;overflow:hidden;transition:border-color .15s}
.mini::before{content:"";position:absolute;inset:0 0 auto 0;height:2px;background:var(--c)}
.mini:hover{border-color:var(--c)}
.mini.waiting{border:2px solid #ffb020;animation:alarm 1s ease-in-out infinite}
.mini.off{opacity:.45}
.mini.cur:not(.waiting){border-color:var(--c)}
.mini.cur{box-shadow:inset 3px 0 0 var(--c);cursor:default}
.mini .mtop{display:flex;align-items:center;gap:6px;font:11px var(--mono);color:var(--mute);white-space:nowrap;min-width:0}
.unseen{flex:none;min-width:18px;height:18px;padding:0 5px;border-radius:9px;background:var(--c);color:#000;font:700 10.5px/18px var(--sans);text-align:center}
.tabbar .unseen{margin-left:6px;background:#000c;color:#fff}
/* One line: name, ticket, state, how long, context; the ticket gives way first, then the state's word. */
.mini .name{flex:none;font-family:var(--sans);font-size:12px;padding:0 6px}
.mini .ticket{flex:0 1 auto;min-width:0;margin-left:0;overflow:hidden;text-overflow:ellipsis;font-size:10.5px;padding:0 5px}
.mini .mtop .state{flex:0 1 auto;min-width:0;overflow:hidden;font:600 11.5px var(--sans)}
.mini .mtop .dot{flex:none}
.mini .mtop .ago,.mini .mtop .pct{flex:none}
.mini .mtop .pct{margin-left:auto}
.mini svg.spark{height:16px;margin-top:3px}
#detail .left{position:relative;display:flex;flex-direction:column;min-height:0;min-width:0}
#dbottom,.card .newest{position:absolute;left:50%;bottom:64px;transform:translateX(-50%);z-index:3;display:none;padding:5px 14px;border-radius:16px;
  border:1px solid var(--c,var(--line2));background:var(--c,var(--line2));color:#000;font:600 12px var(--sans);cursor:pointer;box-shadow:0 6px 18px #0007}
#dbottom.on,.card .newest.on{display:block}
#dbottom:hover,.card .newest:hover{filter:brightness(1.15)}
#detail .conv{flex:1;min-height:0;overflow:auto;padding:14px calc(var(--thumb) + 40px) 14px 16px;display:flex;flex-direction:column;gap:9px}
.sayrow{flex:none;display:flex;align-items:flex-end;gap:6px;margin:0 10px 10px}
.say{flex:1;min-width:0;display:block;margin:0;padding:6px 10px;border-radius:8px;border:1px solid var(--line2);background:var(--soft);
  color:var(--text);font:12.5px/1.4 var(--sans);outline:none;transition:border-color .15s,box-shadow .15s;resize:none;overflow-y:hidden;max-height:120px}
.say::placeholder{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:var(--faint)}
.say:focus{border-color:var(--c);box-shadow:0 0 0 3px color-mix(in srgb,var(--c) 25%,transparent)}
.say.sent{border-color:var(--green)}
.say.failed{border-color:var(--red)}
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
.att b{position:absolute;top:3px;right:3px;width:18px;height:18px;display:grid;place-items:center;border-radius:4px;background:#000a;color:#fff;font-size:11px;font-weight:400;cursor:pointer}
.att b:hover{background:#000d}
#detail .say{padding:9px 12px;font-size:13.5px;max-height:35vh}
.stop{flex:none;position:relative;width:31px;height:31px;border-radius:8px;border:1px solid var(--line2);background:var(--soft);cursor:pointer}
.stop::before{content:"";position:absolute;inset:0;margin:auto;width:10px;height:10px;border-radius:2px;background:var(--text)}
.stop:hover{border-color:var(--red)}
.stop:hover::before{background:var(--red)}
#detail .stop,#detail .add{width:39px;height:39px}
#detail .stop::before{width:12px;height:12px}
#detail .conv .it{font-size:13px}
#detail .conv .it .tx{-webkit-line-clamp:unset;white-space:pre-wrap}
#detail .conv .it.tools .tx{white-space:normal}
/* the pane as a live thumbnail at the top right, in a terminal window of its own shape; a click expands it over
   the whole window over a dimmed page, as large as fits, as an image does */
:is(#detail,.card.full) .termwrap{position:absolute;top:14px;right:16px;z-index:2;cursor:zoom-in}
:is(#detail,.card.full) .termwrap:hover .term{border-color:var(--c)}
:is(#detail,.card.full) .termwrap.big{position:fixed;inset:0;z-index:40;display:flex;justify-content:center;align-items:center;padding:40px;cursor:default;
  background:#000c;backdrop-filter:blur(3px)}
:is(#detail,.card.full) .termwrap .x{display:none;position:fixed;top:16px;right:22px;color:#ccc;cursor:pointer;font-size:20px;line-height:1}
:is(#detail,.card.full) .termwrap.big .x{display:block}
:is(#detail,.card.full) .termwrap .x:hover{color:#fff}
:is(#detail,.card.full) .term{display:flex;flex-direction:column;border-radius:10px;overflow:hidden;background:#06080b;border:1px solid #ffffff1f;box-shadow:0 18px 50px #0008;transition:border-color .15s}
:is(#detail,.card.full) .bar{flex:none;display:flex;align-items:center;gap:7px;padding:8px 12px;background:#161b22;border-bottom:1px solid #ffffff14;font:12px var(--sans);color:#8b949e}
:is(#detail,.card.full) .bar i{width:11px;height:11px;border-radius:50%;background:#ff5f57}
:is(#detail,.card.full) .bar i:nth-child(2){background:#febc2e}:is(#detail,.card.full) .bar i:nth-child(3){background:#28c840;margin-right:8px}
:is(#detail,.card.full) .bar span{flex:1;text-align:center;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
:is(#detail,.card.full) .bar b{cursor:pointer;font-weight:400;font-size:14px;padding:0 2px;color:#8b949e}
:is(#detail,.card.full) .bar b:hover{color:#e6edf3}
:is(#detail,.card.full) .screen{overflow:hidden;padding:10px}
#dscreen,.card.full .termwrap pre{margin:0;font-family:var(--mono);line-height:1.25;color:#d1d7e0;white-space:pre;overflow:hidden}
::-webkit-scrollbar{width:9px;height:9px}::-webkit-scrollbar-thumb{background:var(--thumb);border-radius:9px}
</style>
</head>
<body>
<header>
  <div class="brand" title="Claude agents"><svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="#d97757" stroke-width="2.6" stroke-linecap="round" aria-label="Claude"><path d="M12 12L21.9 13.4M12 12L18.5 17.0M12 12L15.5 20.7M12 12L10.9 19.5M12 12L5.8 19.9M12 12L4.0 15.2M12 12L2.9 10.7M12 12L5.9 7.2M12 12L8.3 2.9M12 12L13.2 3.7M12 12L17.9 4.4M12 12L19.4 9.0"/></svg></div>
  <div class="stat"><div class="k">Week <span id="weektxt"></span></div><div class="meter" id="week"><i></i><u></u></div></div>
  <div class="stat"><div class="k">Team <span id="teamtxt"></span></div><div id="teamspark"></div></div>
  <div class="stat"><div class="k" id="disklab">Disk</div><div class="v" id="disk"></div></div>
  <div class="counts" id="counts"></div>
  <div class="bench" id="bench"></div>
  <div class="counts"><span id="pagelanes"></span><span id="pagemode"></span><span class="pill btn" id="theme" title="Light or dark"></span></div>
</header>
<main id="main"></main>
<div id="pop"></div><div id="copied">Copied</div>
<div id="lightbox"><figure><div id="lbwrap"><img id="lbimg" alt="" draggable="false"></div><figcaption><span id="lbname"></span><span class="zoom"><b id="lbout" title="Zoom out (−)">−</b><b id="lbfit" title="Fit to the window (0)">Fit</b><b id="lbin" title="Zoom in (+)">+</b><span id="lbpct"></span></span><a id="lbtab" target="_blank" rel="noopener">Open in a new tab</a></figcaption></figure><span class="x" id="lbx" title="Close (Esc)">✕</span></div>
<div id="detail"><div class="box"><div class="head" id="dhead"></div><div class="left"><div class="conv" id="dconv"></div><button id="dbottom" title="Back to the newest turn">↓ Newest</button><div class="att" id="datt"></div><div class="sayrow" id="dsayrow"><button class="add" id="dadd" title="Add images (Ctrl+U)"></button><textarea class="say" id="dsay" rows="1" autocomplete="off"></textarea><button class="stop" id="dstop" title="Stop this turn, as Esc does in the terminal"></button></div><div class="termwrap" id="dterm" title="Expand"><div class="term"><div class="bar"><i></i><i></i><i></i><span id="dtitle"></span><b id="dzoom">⤢</b></div><div class="screen" id="dscr"><pre id="dscreen"></pre></div></div><span class="x" id="dtx" title="Close (Esc)">✕</span></div></div><div class="rail" id="drail"></div></div></div>
<script>
const $ = s => document.querySelector(s);
// Light or dark, remembered in this browser; dark unless chosen.
function theme(t) { document.documentElement.classList.toggle("light", t === "light"); localStorage.setItem("theme", t); $("#theme").textContent = t === "light" ? "☾ Dark" : "☀ Light"; }
theme(new URLSearchParams(location.search).get("theme") || localStorage.getItem("theme") || "dark");
$("#theme").onclick = () => theme(document.documentElement.classList.contains("light") ? "dark" : "light");
const esc = s => String(s ?? "").replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));
// The little Markdown agents write: ``` fenced blocks, tables, # headings, - bullets, `code` and **bold**; web
// addresses become links.
const inline = s => esc(s)
  .replace(/^#{1,6} +(.+)$/gm, '<b class="h">$1</b>')
  .replace(/^(\s*)[-*] +/gm, "$1• ")
  .replace(/`([^`\n]+)`/g, "<code>$1</code>")
  .replace(/\*\*([^*\n]+)\*\*/g, "<b>$1</b>")
  .replace(/\bhttps?:\/\/[^\s<>"'`]*[^\s<>"'`.,;:!?)\]]/g, u => `<a class="link" href="${u}" target="_blank" rel="noopener">${u}</a>`);
// A table is a header row, a row of dashes and its rows, each line between pipes.
const TABLE = /(^\|.*\|[ \t]*\n\|[ \t:|-]+\|[ \t]*(?:\n\|.*\|[ \t]*)*)\n?/gm;
const cells = (row, tag) => row.trim().slice(1, -1).split("|").map(c => `<${tag}>${inline(c.trim())}</${tag}>`).join("");
const table = t => { const [head, , ...rows] = t.trim().split("\n"); return `<table class="md"><tr>${cells(head, "th")}</tr>${rows.map(r => `<tr>${cells(r, "td")}</tr>`).join("")}</table>`; };
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
const STATE = {busy: "working", waiting: "waiting", idle: "idle", shell: "in shell", off: "not running"};
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

function item(it, compact, agent) {
  if (it.kind === "tools") {
    const t = it.calls.map(c => `<b>${esc(c.who)}</b> ${esc(c.text)}`).join(" · ");
    const c = colours[it.with], pc = c ? ` style="--pc:${c}"` : "";
    return `<div class="it tools l-${it.lane}"${pc}><span class="tx">⚙ ${t}</span><span class="ago" data-ts="${esc(it.ts || "")}">${since(it.ts)}</span></div>`;
  }
  // a message of the owner's still queued behind the agent's turn, which can be taken back out to edit
  if (it.kind === "pending") {
    return `<div class="it owner pending"><span class="who">${esc(S.owner || "Owner")}</span><span class="tx">${md(it.text, compact === true)}</span><span class="badge" title="Queued: the agent reads it when its turn allows">pending</span></div>`;
  }
  // the agent's own words carry its name, as the owner's carry theirs
  const who = it.kind === "said" ? agent || "" : it.who;
  const c = colours[it.kind === "said" ? agent : it.with || it.who], pc = c ? ` style="--pc:${c}"` : "";
  const pics = thumbs(it.text, it.images, agent);
  return `<div class="it ${it.kind}${it.kind === "ask" || it.kind === "live" ? "" : " l-" + it.lane}${pics ? " pics" : ""}"${pc}>${who ? `<span class="who">${esc(who)}</span>` : ""}<span class="tx">${compact === true ? md(it.text.replace(/\n\s*\n+/g, "\n"), true) : md(it.text)}</span><span class="ago" data-ts="${esc(it.ts || "")}">${since(it.ts)}</span>${pics}</div>`;
}

// Which lanes of an agent's conversation are shown - the owner's, the team's, automation's - each on or off, chosen
// per agent on its card or in its view, and remembered. The page's own set ("" here) sets every agent's when changed.
const LANES = [["owner", ""], ["team", "Team"], ["auto", "Auto"]], ALL = LANES.map(l => l[0]);
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
function laneSeg(name) {
  const on = laneOf(name);
  const tip = l => `Show or hide${name ? "" : " on every agent"}: ${LANE_TIP[l].replace(/^\w/, c => c.toLowerCase())}`;
  return `<span class="seg lanes" data-name="${esc(name)}">${LANES.map(([l, t]) => `<b data-lane="${l}" class="${on.includes(l) ? "on" : ""}" title="${esc(tip(l))}">${esc(t || S.owner)}</b>`).join("")}</span>`;
}
// A conversation as shown: the chosen lanes only (an open prompt and the working line always), with each run of automated events folded
// into one line; in the agent view a folded run opens on a click.
const openRuns = new Set();
function feedHtml(items, name, compact) {
  const on = laneOf(name), shown = items.filter(it => on.includes(it.lane) || ["ask", "live", "pending"].includes(it.kind)), out = [];
  for (let i = 0; i < shown.length; i++) {
    let j = i;
    while (shown[i].kind === "event" && j + 1 < shown.length && shown[j + 1].kind === "event") j++;
    if (j === i) { out.push(item(shown[i], compact, name)); continue; }
    const run = shown.slice(i, j + 1), key = run[0].ts + run[0].who, n = {};
    run.forEach(it => n[it.who] = (n[it.who] || 0) + 1);
    const what = Object.entries(n).map(([w, c]) => `${esc(w)}${c > 1 ? ` <span class="n">×${c}</span>` : ""}`).join(" · ");
    out.push(`<div class="it event folded l-auto" data-run="${esc(key)}"><span class="who">${run.length} automated</span><span class="tx">${what}</span><span class="ago" data-ts="${esc(run[run.length - 1].ts || "")}">${since(run[run.length - 1].ts)}</span></div>`);
    if (!compact && openRuns.has(key)) out.push(...run.map(it => item(it, compact, name)));
    i = j;
  }
  return out.length ? out.join("") : `<div class="empty">${on.length ? "nothing here lately" : "nothing shown"}</div>`;
}
function laneClicks(root) {
  root.querySelectorAll(".lanes b").forEach(b => b.onclick = e => {
    e.stopPropagation();
    toggleLane(b.parentElement.dataset.name, b.dataset.lane);
    draw(); if (open) { renderConv(); $("#dhead .lanes").outerHTML = laneSeg(open); laneClicks($("#dhead")); }
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

// A card given its conversation's key (an agent pane's) marks its feed with it; with keep, the feed is left empty,
// for the redraw to keep the one on screen.
function card(a, ceil, conv, extra = "", after = "", {key = "", keep = false} = {}) {
  const cls = a.live ? a.status : "off";
  const model = a.model ? a.model.split(" ").slice(0, 2).map((p, i) => i ? p : p[0]).join("") : "";
  const ctx = a.ctxPct == null ? "" : `<span class="ctx"><span class="meter"><i style="width:${Math.min(100, a.ctxPct)}%;background:${gauge(a.ctxPct)}"></i></span><span style="color:${gauge(a.ctxPct)}">${a.ctxPct}%</span></span>`;
  const turns = conv || a.feed;
  const feed = keep ? "" : turns.length ? feedHtml(turns, a.name, !conv) : `<div class="empty">${a.live ? "no conversation yet" : "not running"}</div>`;
  return `<div class="card ${cls}${conv ? " full" : ""}${after ? " term" : ""}" style="--c:${a.colour}" data-name="${esc(a.name)}">
    <div class="top"><span class="name">${esc(a.name)}</span><span class="role">${esc(a.roleName)}</span>${a.ticket ? `<span class="ticket">${esc(a.ticket)}</span>` : ""}${a.feed.length ? laneSeg(a.name) : ""}${extra}</div>
    <div class="row2"><span class="state"><span class="dot"></span>${STATE[cls] || esc(cls)}</span><span>${ago(a.held)}</span>${ctx}</div>
    <div class="row2"><span class="model">${esc(model)} ${esc(a.effort)}</span><span class="model">${a.rate ? k(a.rate) + " tok/min" : ""}</span><span class="model" style="margin-left:auto">${esc(a.cwd)}</span></div>
    ${spark(a.series, ceil, a.colour)}
    <div class="feed"${key ? ` data-key="${esc(key)}"${keep ? " data-kept" : ""}` : ""}>${feed}</div>${conv ? `<button class="newest" title="Back to the newest turn">↓ Newest</button>` : ""}${after}
    ${a.live ? `<div class="att" data-name="${esc(a.name)}"></div><div class="sayrow">${addButton(a.name)}<textarea class="say" rows="1" data-name="${esc(a.name)}" placeholder="${a.status === "waiting" ? "A prompt is open in its pane: this answers it" : "Message " + esc(a.name) + "…"}" autocomplete="off"></textarea>${a.status === "busy" ? stopButton(a.name) : ""}</div>` : ""}</div>`;
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

// A Grid / Tabs switch, for the page (no section) or for one section.
function seg(mode, sec) {
  const tip = {grid: sec ? `Every agent in ${sec} as a card` : "Every section side by side",
    tabs: sec ? `${sec} as tabs, one agent at a time` : "Every agent as one row of tabs, one at a time",
    custom: "Your own layout of panes"};
  return `<span class="seg mode"${sec ? ` data-sec="${esc(sec)}"` : ""}>${(sec ? ["grid", "tabs"] : ["grid", "tabs", "custom"]).map(m => `<b data-mode="${m}" class="${m === mode ? "on" : ""}" title="${esc(tip[m])}">${m[0].toUpperCase() + m.slice(1)}${m === "custom" && mode === "custom" ? `<i id="lock" title="${layout().locked ? "Locked: click to change the layout" : "Click to lock the layout"}">${padlock(layout().locked)}</i>` : ""}</b>`).join("")}</span>`;
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
  if (!S || resizing || holding($("#main"))) return;
  const w = S.week, p = S.plan, over = w != null && p != null && w > p;
  // Over the plan but within the whole allowance shared out evenly is spending the week's contingency: amber.
  const spare = over && S.even != null && w <= S.even, wc = spare ? "var(--amber)" : over ? "var(--red)" : "var(--green)";
  $("#weektxt").innerHTML = w == null ? "· no reading" : `· <b style="color:${wc}">${w}%</b>${p != null ? ` of ${p}% planned` : ""}`;
  $("#week i").style.cssText = `width:${w || 0}%;background:${over ? wc : "linear-gradient(90deg,#2ea043,#3fb950)"}`;
  $("#week u").style.cssText = p == null ? "display:none" : `left:calc(${p}% - 1px)`;
  // Every agent's activity added together, minute by minute, as each card shows its own.
  const team = S.agents.reduce((t, a) => a.series.map((v, i) => v + (t[i] || 0)), []), rate = S.agents.reduce((t, a) => t + (a.rate || 0), 0);
  $("#teamtxt").innerHTML = rate ? `· <b style="color:var(--text)">${k(rate)}</b> tok/min` : "";
  $("#teamspark").innerHTML = spark(team, Math.max(1, ...team), "currentColor");
  const d = S.disk;
  $("#disk").parentElement.style.display = d ? "" : "none";   // no AGENT_DISK_WATCH, no disk
  if (d) { $("#disklab").textContent = d.label + " free"; $("#disk").innerHTML = `<span style="color:${d.free_gb < d.alert ? "var(--red)" : d.free_gb < d.warn ? "var(--amber)" : "var(--text)"}">${d.free_gb} GB</span> <span style="color:var(--faint)">of ${d.total_gb}</span>`; }
  const n = st => S.agents.filter(a => a.status === st).length;
  // Working and idle as a dot and a number each, with a flashing badge on top when any agent is waiting.
  const waiting = n("waiting");
  $("#counts").innerHTML = `<span class="pill tally" title="${n("busy")} working, ${n("idle")} idle${waiting ? `, ${waiting} waiting` : ""}">` +
    `<span class="dot" style="background:var(--green)"></span><b>${n("busy")}</b><span class="dot"></span><b style="color:var(--mute)">${n("idle")}</b>` +
    (waiting ? `<span class="wait">${waiting} waiting</span>` : "") + `</span>`;
  // The benched developers and testers on one line in the header's free space, so the header never changes height;
  // those that do not fit are counted in a "+N" that names them.
  $("#bench").innerHTML = S.bench.length ? `<span>bench</span><span class="rrow">${S.bench.map(b => `<em style="--c:${b.colour}" title="${esc(b.name)}, ${esc(b.roleName || b.role)}, on the bench">${esc(b.name)}</em>`).join("")}</span>` : "";


  const ceil = Math.max(1, ...S.agents.flatMap(a => a.series));
  const main = $("#main"), W = main.clientWidth, H = main.clientHeight;
  const tabs = S.tabs.map(name => ({name, agents: S.agents.filter(a => a.tab === name)}));
  const total = tabs.reduce((s, t) => s + t.agents.length, 0) || 1;
  // The page shows every section side by side (Grid), or one agent's view at a time, picked from the column of them
  // all beside it (Tabs).
  const pageMode = localStorage.getItem("page") || "grid";
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
  $("#pagemode").innerHTML = seg(pageMode);
  if (pageMode === "custom") $("#lock").onclick = e => { e.stopPropagation(); const l = layout(); l.locked = !l.locked; saveLayout(l); draw(); };
  $("#pagelanes").innerHTML = laneSeg(""); laneClicks($("#pagelanes"));
  const typed = {}, act = document.activeElement, focus = act && act.matches("#main .say") ? [act.dataset.name, act.selectionStart] : null;
  document.querySelectorAll("#main .say").forEach(i => { if (i.value) typed[i.dataset.name] = i.value; });
  // A row of tabs, one per agent; the picked one is remembered under "tab:" + key.
  const tabRow = (key, agents) => {
    const sel = agents.find(a => a.name === localStorage.getItem("tab:" + key)) || agents[0];
    const tab = a => { const n = a === sel ? 0 : unseen(a);
      return `<button class="${a.live ? a.status : "off"}" style="--c:${a.colour}" data-tab="${esc(a.name)}"><span class="dot"></span>${esc(a.name)}${n ? unseenBadge(n) : ""}</button>`; };
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
  const ends = paneEnds();
  patch(main, html);
  toPaneEnds(ends);
  dock(pageMode === "tabs" && (tabs.flatMap(t => t.agents).find(a => a.name === localStorage.getItem("tab:page")) || S.agents[0]));
  document.querySelectorAll(".seg.mode b").forEach(b => b.onclick = () => {
    const sec = b.parentElement.dataset.sec;
    localStorage.setItem(sec ? "mode:" + sec : "page", b.dataset.mode); draw();
  });
  document.querySelectorAll(".tabbar button").forEach(b => b.onclick = () => { localStorage.setItem("tab:" + b.parentElement.dataset.sec, b.dataset.tab); draw(); });
  if (pageMode === "grid") grips(tabs.map(t => t.name));
  if (pageMode === "custom") customClicks();
  if (!open) markSeen([...[...main.querySelectorAll(".card")].map(c => c.dataset.name), ...S.agents.filter(a => !seen[a.name]).map(a => a.name)]);
  rail(); facts(); syncStop();
  document.querySelectorAll("#main .stop").forEach(b => b.onclick = e => { e.stopPropagation(); stopAgent(b.dataset.name, b); });
  main.querySelectorAll(".add").forEach(b => b.onclick = e => { e.stopPropagation(); pick(b.dataset.name, b.nextElementSibling); });
  // In a custom layout a click on a card puts the cursor in its message box, and a double-click opens it.
  document.querySelectorAll(".card").forEach(c => c.onclick = e => {
    if (!getSelection().isCollapsed || e.target.closest("a")) return;
    const box = c.closest(".pane") && c.querySelector(".say");
    if (box) { if (e.detail < 2 && document.activeElement !== box) box.focus(); } else openDetail(c.dataset.name);
  });
  document.querySelectorAll(".pane .card").forEach(c => c.ondblclick = e => { if (!e.target.closest(".say,a")) openDetail(c.dataset.name); });
  laneClicks(main);
  document.querySelectorAll("#main .say").forEach(i => {
    i.value = typed[i.dataset.name] || draft(i.dataset.name); grow(i);
    i.onclick = e => e.stopPropagation();
    i.oninput = () => { emojify(i); grow(i); keep(i); };
    i.onkeydown = e => keys(e, i, i.dataset.name);
    i.onpaste = e => pasted(e, i.dataset.name);
    if (focus && focus[0] === i.dataset.name) { i.focus(); i.setSelectionRange(focus[1], focus[1]); }
    if (!i.parentElement.previousElementSibling.children.length) showAtt(i.dataset.name);
  });
  fitBench(); beat();
}
function fitBench() {
  const row = $("#bench .rrow"), chips = row ? [...row.children] : [];
  if (!row || row.scrollWidth <= row.clientWidth) return;
  const more = Object.assign(document.createElement("em"), {style: "--c:var(--line2)"});
  row.append(more);
  const off = [];
  while (chips.length && row.scrollWidth > row.clientWidth) { const c = chips.pop(); c.remove(); off.unshift(c.textContent); more.textContent = "+" + off.length; }
  more.title = "Also on the bench: " + off.join(", ");
}

// The custom layout, kept in this browser: a tree whose inner nodes split their space in two, side by side ("row") or
// one above the other ("col"), at a fraction "at", and whose leaves are panes showing an agent's card ("agent"),
// every agent with no card on screen ("others"), a grid or tabs of the agents in some roles, or nothing yet. A pane is
// named by its path from the root ("r", then "a" or "b" for each split), which also keys its tabs. Locked, the panes
// lose their bars and the dividers stay put.
// A flat padlock in the text colour: the shackle closed when locked, swung open when not.
const padlock = locked => `<svg width="13" height="15" viewBox="0 0 13 15" fill="none" stroke="currentColor" stroke-width="1.6" style="display:block"><rect x="1.5" y="6.5" width="10" height="7.5" rx="1.5"/><path d="${locked ? "M3.75 6.5V4.25a2.75 2.75 0 0 1 5.5 0V6.5" : "M3.75 6.5V4.25a2.75 2.75 0 0 1 5.5 0V3.5"}"/></svg>`;
const PANE_TYPES = {agent: "Agent", others: "Others", grid: "Grid", tabs: "Tabs"};
const ROLE_ORDER = ["lead", "dev", "tester", "hot", "review", "process", "pa"];
const layout = () => { try { return JSON.parse(localStorage.getItem("custom")) || {root: {}}; } catch (e) { return {root: {}}; } };
const saveLayout = l => localStorage.setItem("custom", JSON.stringify(l));
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
const paneAgents = n => (n.roles || []).flatMap(r => S.agents.filter(a => a.role === r));
// The agents a pane shows a card of: an agent pane its one, a grid all of its roles, tabs the picked one.
function onScreen(l) {
  const names = new Set();
  for (const [path, n] of leaves(l.root)) {
    const of = paneAgents(n);
    if (n.show === "agent" && n.name) names.add(n.name);
    if (n.show === "grid") of.forEach(a => names.add(a.name));
    if (n.show === "tabs" && of.length) names.add((of.find(a => a.name === localStorage.getItem("tab:pane:" + path)) || of[0]).name);
  }
  return names;
}
function customHtml(ceil, tabRow) {
  const l = layout(), shown = onScreen(l);
  let maxed = localStorage.getItem("custom:max");
  if (maxed && !leaves(l.root).some(([p, n]) => p === maxed && n.show === "agent")) { localStorage.removeItem("custom:max"); maxed = null; }
  const pane = (n, path) => {
    const of = paneAgents(n);
    let body = `<div class="blank">${l.locked ? "" : "Choose what this pane shows"}</div>`;
    if (n.show === "agent") {
      const a = S.agents.find(x => x.name === n.name);
      const big = path === maxed, t = big && termOn() && paneTerm[a.name];
      const key = a && paneConv[a.name] && [a.name, a.live, paneVer[a.name], laneOf(a.name), [...openRuns], noImage.size].join("|");
      const keep = !!key && $(`#main .pane[data-path="${path}"] .card.full .feed`)?.dataset.key === key;
      body = a ? `<div class="cards" style="grid-template-columns:minmax(0,1fr)">${card(a, ceil, paneConv[a.name] || a.feed,
        (big ? `<span class="seg termseg"><b class="${termOn() ? "on" : ""}" title="Show or hide its terminal">Terminal</b></span>` : "") + maxButton(big),
        t ? paneTermHtml(a.name, t) : "", {key, keep})}</div>`
        : `<div class="blank">${n.name ? esc(n.name) + " is not running" : "Choose an agent"}</div>`;
    } else if (n.show === "others") {
      body = `<div class="others">${minis("", S.agents.filter(a => !shown.has(a.name)))}</div>`;
    } else if (n.show === "grid" && of.length) {
      const el = $(`#main .pane[data-path="${path}"] .pbody`), c = el ? cols(of.length, el.clientWidth, el.clientHeight) : Math.ceil(Math.sqrt(of.length));
      body = `<div class="cards" style="grid-template-columns:repeat(${c},minmax(0,1fr))">${of.map(a => card(a, ceil)).join("")}</div>`;
    } else if (n.show === "tabs" && of.length) {
      const [sel, row] = tabRow("pane:" + path, of);
      body = `${row}<div class="cards" style="grid-template-columns:minmax(0,1fr)">${card(sel, ceil)}</div>`;
    } else if (n.show === "grid" || n.show === "tabs") {
      body = `<div class="blank">${(n.roles || []).length ? "No agent in these roles is running" : "Choose one or more roles"}</div>`;
    }
    const bar = l.locked ? "" : `<div class="pbar">
      <span class="seg">${Object.entries(PANE_TYPES).map(([t, label]) => `<b data-act="show" data-v="${t}" class="${t === n.show ? "on" : ""}">${label}</b>`).join("")}</span>
      ${n.show === "agent" ? `<select data-act="name"><option value="">Agent…</option>${S.agents.map(a => `<option${a.name === n.name ? " selected" : ""}>${esc(a.name)}</option>`).join("")}</select>` : ""}
      ${n.show === "grid" || n.show === "tabs" ? roleList().map(r => `<em style="--c:${r.colour}" class="${(n.roles || []).includes(r.role) ? "on" : ""}" data-act="role" data-v="${esc(r.role)}">${esc(r.name)}</em>`).join("") : ""}
      <span class="pacts"><b data-act="row" title="Split side by side">⇆</b><b data-act="col" title="Split top and bottom">⇅</b><b data-act="del" title="Remove this pane">✕</b></span></div>`;
    return `<div class="pane" data-path="${path}">${bar}<div class="pbody">${body}</div></div>`;
  };
  const node = (n, path) => !n.split ? pane(n, path)
    : `<div class="lay ${n.split}" data-path="${path}"><div class="half" style="flex-grow:${n.at}">${node(n.a, path + "a")}</div><div class="divider${l.locked ? "" : " drag"}" data-path="${path}"></div><div class="half" style="flex-grow:${1 - n.at}">${node(n.b, path + "b")}</div></div>`;
  return maxed ? pane(nodeAt(l.root, maxed), maxed) : node(l.root, "r");
}
// An agent pane can fill the whole layout for a while, from the button at the end of its card's header or Shift+F11
// (the pane being typed in, else the one under the pointer); Esc, the button or Shift+F11 again puts it back.
const maxButton = on => `<b class="maxbtn" title="${on ? "Restore (Esc)" : "Maximise"}"><svg width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" stroke-width="1.5">${on
  ? '<path d="M4.5 1v3.5H1M7.5 1v3.5H11M4.5 11V7.5H1M7.5 11V7.5H11"/>' : '<path d="M1 4.5V1h3.5M11 4.5V1H7.5M1 7.5V11h3.5M11 7.5V11H7.5"/>'}</svg></b>`;
let paneUnder = null;
document.addEventListener("mouseover", e => { paneUnder = e.target.closest?.("#main .pane") || paneUnder; });
addEventListener("keydown", e => {
  if (e.key !== "F11" || !e.shiftKey || (localStorage.getItem("page") || "grid") !== "custom" || open) return;
  e.preventDefault();
  if (unmax()) return;
  const pane = document.activeElement?.closest?.("#main .pane") || (paneUnder?.isConnected ? paneUnder : null);
  pane?.querySelector(".maxbtn")?.click();
});
function unmax() { if (!localStorage.getItem("custom:max")) return false; localStorage.removeItem("custom:max"); paneBig = null; draw(); return true; }
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
async function loadPaneConvs() {
  if ((localStorage.getItem("page") || "grid") !== "custom") return;
  const names = [...new Set(leaves(layout().root).filter(([, n]) => n.show === "agent" && n.name).map(([, n]) => n.name))];
  await Promise.all(names.map(async name => {
    try {
      const d = await (await fetch("/api/agent/" + encodeURIComponent(name), {cache: "no-store"})).json();
      const text = JSON.stringify(d.feed);
      if (text !== paneText[name]) { paneConv[name] = d.feed; paneText[name] = text; paneVer[name] = (paneVer[name] || 0) + 1; }
      paneTerm[name] = {screen: d.screen, cols: d.cols || 80, rows: d.rows || 24};
    } catch (e) {}
  }));
}
// A pane's conversation stays at its newest turn unless it has been scrolled up.
const atEnd = f => f.scrollHeight - f.scrollTop - f.clientHeight < 40;
function paneEnds() { return new Set([...document.querySelectorAll("#main .card.full .feed")].filter(atEnd).map(f => f.closest(".card").dataset.name)); }
const paneFeeds = new WeakSet();   // the panes' conversations already placed, so a new one starts at its end
function toPaneEnds(ends) {
  document.querySelectorAll("#main .card.full .feed .ago[data-ts]").forEach(s => { const t = since(s.dataset.ts); if (s.textContent !== t) s.textContent = t; });
  document.querySelectorAll("#main .card.full .feed").forEach(f => { if (ends.has(f.closest(".card").dataset.name) || !paneFeeds.has(f)) f.scrollTop = f.scrollHeight; paneFeeds.add(f); });
}
function customClicks() {
  const main = $("#main"), change = f => { const l = layout(); f(l); saveLayout(l); draw(); };
  main.querySelectorAll(".pbar [data-act]").forEach(el => {
    const path = el.closest(".pane").dataset.path, act = el.dataset.act;
    if (act === "name") { el.onchange = () => change(l => { nodeAt(l.root, path).name = el.value; }); return; }
    el.onclick = () => change(l => {
      const n = nodeAt(l.root, path);
      if (act === "show") { n.show = el.dataset.v; }
      else if (act === "role") { const rs = new Set(n.roles || []); rs.has(el.dataset.v) ? rs.delete(el.dataset.v) : rs.add(el.dataset.v); n.roles = [...rs]; }
      else if (act === "row" || act === "col") putAt(l, path, {split: act, at: 0.5, a: n, b: {}});
      else if (act === "del") path === "r" ? putAt(l, "r", {}) : putAt(l, path.slice(0, -1), nodeAt(l.root, path.slice(0, -1))[path.endsWith("a") ? "b" : "a"]);
    });
  });
  main.querySelectorAll(".others .mini").forEach(m => m.onclick = () => openDetail(m.dataset.name));
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
    if (!unmax()) { localStorage.setItem("custom:max", b.closest(".pane").dataset.path); draw(); }
  });
  main.querySelectorAll(".card.full").forEach(c => {
    const f = c.querySelector(".feed"), btn = c.querySelector(".newest");
    const show = () => { btn.style.bottom = (c.getBoundingClientRect().bottom - f.getBoundingClientRect().bottom + 12) + "px"; btn.classList.toggle("on", !atEnd(f)); };
    f.onscroll = show; show();
    btn.onclick = e => { e.stopPropagation(); f.scrollTo({top: f.scrollHeight, behavior: "smooth"}); };
  });
  main.querySelectorAll(".card.full .folded").forEach(f => f.onclick = e => { e.stopPropagation(); const k = f.dataset.run; openRuns.has(k) ? openRuns.delete(k) : openRuns.add(k); draw(); });
  main.querySelectorAll(".divider.drag").forEach(d => d.onpointerdown = e => {
    e.preventDefault(); d.setPointerCapture(e.pointerId); d.classList.add("moving");
    const lay = d.parentElement, row = lay.classList.contains("row"), r = lay.getBoundingClientRect(), [h1, h2] = lay.querySelectorAll(":scope > .half");
    document.body.classList.add(row ? "resizing" : "resizing-row"); resizing = true;
    let at = null;
    d.onpointermove = mv => {
      at = Math.max(0.1, Math.min(0.9, row ? (mv.clientX - r.left) / r.width : (mv.clientY - r.top) / r.height));
      h1.style.flexGrow = at; h2.style.flexGrow = 1 - at;
    };
    d.onpointerup = () => {
      d.onpointermove = null; d.classList.remove("moving"); document.body.classList.remove("resizing", "resizing-row"); resizing = false;
      if (at != null) change(l => { nodeAt(l.root, d.dataset.path).at = +at.toFixed(3); });
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

// The column of every agent beside an open one, the open one marked: name, ticket, state and how long, context and burn.
// The column of every agent beside an open one, the open one marked: name, unseen count, ticket, state and how long,
// context and burn.
function minis(cur, agents = S.agents) {
  const ceil = Math.max(1, ...S.agents.flatMap(a => a.series));
  return agents.map(a => {
    const st = a.live ? a.status : "off", n = a.name === cur ? 0 : unseen(a);
    return `<div class="mini ${st}${a.name === cur ? " cur" : ""}" style="--c:${a.colour}" data-name="${esc(a.name)}" title="Open ${esc(a.name)}">
      <div class="mtop"><span class="name">${esc(a.name)}</span>${n ? unseenBadge(n) : ""}${a.ticket ? `<span class="ticket" title="${esc(a.ticket)}">${esc(a.ticket)}</span>` : ""}<span class="state"><span class="dot"></span>${STATE[st] || esc(st)}</span><span class="ago">${ago(a.held)}</span>${a.ctxPct == null ? "" : `<span class="pct" style="color:${gauge(a.ctxPct)}">${a.ctxPct}%</span>`}</div>
      ${spark(a.series, ceil, a.colour)}</div>`;
  }).join("");
}
function rail() {
  if (!open || !S) return;
  markSeen(S.agents.filter(a => !seen[a.name] || a.name === open).map(a => a.name));
  patch($("#drail"), minis(open));
  document.querySelectorAll("#drail .mini").forEach(m => m.onclick = m.matches(".cur") ? null : () => openDetail(m.dataset.name));
  beat();
}

// The open agent's facts beside its name: its state and for how long, model and effort, context used, burn, and
// where it sits and works. Redrawn with the page.
function facts() {
  const a = open && S && S.agents.find(x => x.name === open), el = $("#dfacts");
  if (!a || !el) return;
  const st = a.live ? a.status : "off";
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
  const a = S.agents.find(x => x.name === name) || {};
  $("#detail .box").style.setProperty("--c", a.colour || "#888");
  $("#dhead").innerHTML = `<span class="name" style="--c:${a.colour}">${esc(name)}</span><span class="role">${esc(a.roleName || "")}</span>${a.ticket ? `<span class="ticket" style="margin-left:6px">${esc(a.ticket)}</span>` : ""}<span class="facts" id="dfacts"></span><span class="seg termseg"><b class="${termOn() ? "on" : ""}" title="Show or hide its terminal">Terminal</b></span><span class="seg railseg"><b title="Move the other agents' cards to the next edge"></b></span>${laneSeg(name)}<span class="x" title="Close (Esc)">✕</span>`;
  $("#dhead .x").onclick = closeDetail; laneClicks($("#dhead"));
  $("#dhead .termseg b").onclick = e => { localStorage.setItem("term", termOn() ? "off" : "on"); e.target.classList.toggle("on", termOn()); showTerm(); };
  $("#dhead .railseg b").onclick = () => { const k = Object.keys(EDGES); localStorage.setItem("rail", k[(k.indexOf(railEdge()) + 1) % k.length]); showRail(); fitTerm(); };
  showTerm(); showRail();
  facts();
  $("#detail").classList.add("open");
  rail();
  const ds = $("#dsay"); ds.value = draft(name); grow(ds); ds.placeholder = a.status === "waiting" ? "A prompt is open in its pane: this answers it" : `Message ${name}…`;
  $("#datt").dataset.name = name; showAtt(name);
  $("#dsayrow").style.display = a.live ? "" : "none"; syncStop(); setTimeout(() => ds.focus(), 50);
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
  if (document.activeElement !== ds) ds.focus();
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
// A working agent's turn can be stopped, as Esc stops it in the terminal.
const stopButton = name => `<button class="stop" data-name="${esc(name)}" title="Stop this turn, as Esc does in the terminal"></button>`;
async function stopAgent(name, button) {
  button.disabled = true;
  const r = await fetch("/api/agent/" + encodeURIComponent(name) + "/stop", {method: "POST", headers: {"X-Team-Say": "1"}}).catch(() => null);
  if (!r || !r.ok) { button.title = r ? await r.text() : "the page could not be reached"; button.disabled = false; return; }
  setTimeout(load, 800); if (open === name) setTimeout(() => refreshDetail(false), 800);
}
$("#dstop").onclick = () => stopAgent(open, $("#dstop"));
function syncStop() {
  if (!open || !S) return;
  const a = S.agents.find(x => x.name === open) || {};
  $("#dstop").style.display = a.status === "busy" ? "" : "none"; $("#dstop").disabled = false;
}
function keys(e, box, name) {
  if (e.ctrlKey && e.key.toLowerCase() === "u") { e.preventDefault(); pick(name, box); return; }
  if (e.key !== "Enter") return;
  e.preventDefault();
  if (e.ctrlKey) { box.setRangeText("\n", box.selectionStart, box.selectionEnd, "end"); grow(box); }
  else say(name, box);
}
async function say(name, input) {
  const text = input.value.trim(), sent = atts[name] || [];
  if (!text && !sent.length || input.disabled) return;
  // The box empties at once, so a redraw while the message is on its way cannot bring the text back; a card's box
  // may have been redrawn by the time the answer comes, so the answer goes to whichever box is on the page then.
  input.value = ""; grow(input); keep(input); input.disabled = true;
  const box = () => input.isConnected ? input : document.querySelector(`#main .say[data-name="${CSS.escape(name)}"]`) || input;
  try {
    const r = await fetch("/api/agent/" + encodeURIComponent(name) + "/say", {method: "POST", headers: {"Content-Type": "application/json", "X-Team-Say": "1"}, body: JSON.stringify({text, images: sent.map(i => i.path)})});
    if (!r.ok) throw new Error(await r.text());
    atts[name] = (atts[name] || []).filter(i => !sent.includes(i)); showAtt(name);
    flash(box(), "sent");
    setTimeout(load, 1500); if (open === name) setTimeout(() => refreshDetail(false), 1500);
  } catch (e) { const b = box(); b.value = text; grow(b); keep(b); flash(b, "failed"); b.title = String(e.message || e); }
  input.disabled = false; box().focus();
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
  localStorage.setItem("drafts", JSON.stringify(d));
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
  const files = [...e.clipboardData.items].filter(i => i.kind === "file" && i.type.startsWith("image/")).map(i => i.getAsFile());
  if (!files.length) return;
  if (!e.clipboardData.getData("text/plain")) e.preventDefault();
  upload(files, name, e.target);
}
async function upload(files, name, box) {
  for (const f of files) {
    const r = await fetch("/api/paste", {method: "POST", headers: {"Content-Type": f.type, "X-Team-Say": "1"}, body: f}).catch(() => null);
    if (!r || !r.ok) { flash(box, "failed"); box.title = r ? await r.text() : "the page could not be reached"; continue; }
    (atts[name] = atts[name] || []).push(await r.json()); showAtt(name);
  }
}
// The + beside a message box, or Ctrl+U in it, picks images from this computer to go with the message.
function pick(name, box) {
  const input = Object.assign(document.createElement("input"), {type: "file", accept: "image/png,image/jpeg,image/gif,image/webp", multiple: true});
  input.onchange = () => { upload([...input.files], name, box); box.focus(); };
  input.click();
}
const addButton = name => `<button class="add" data-name="${esc(name)}" title="Add images (Ctrl+U)"></button>`;
function showAtt(name) {
  const list = atts[name] || [];
  localStorage.setItem("atts", JSON.stringify(atts));
  document.querySelectorAll(`.att[data-name="${CSS.escape(name || "")}"]`).forEach(el => {
    el.innerHTML = list.map((a, i) => `<span><a href="${a.url}" title="${esc(a.path)}" onclick="return showImg(event, this)"><img src="${a.url}" alt="pasted image"></a><b data-i="${i}" title="Remove">✕</b></span>`).join("");
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
$("#dsay").oninput = () => { emojify($("#dsay")); grow($("#dsay")); keep($("#dsay")); };
$("#dsay").onkeydown = e => keys(e, $("#dsay"), open);
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
function closeDetail() { if ($("#detail").classList.contains("docked")) return; open = null; $("#detail").classList.remove("open"); history.replaceState(null, "", location.pathname); }
$("#detail").onclick = e => { if (e.target.id === "detail") closeDetail(); };
addEventListener("keydown", e => {
  if (e.key !== "Escape") return;
  if ($("#lightbox").classList.contains("on")) closeImg();
  else if ($("#dterm").classList.contains("big")) zoom(false);
  else if (paneBig && !open) { paneBig = null; draw(); }
  else if (open || !unmax()) closeDetail();
});
addEventListener("resize", draw);

load().then(() => { if (location.hash.length > 1) openDetail(decodeURIComponent(location.hash.slice(1))); });
setInterval(load, 4000); setInterval(() => refreshDetail(false), 2500);
</script>
</body>
</html>
"""


def self_test():
    """Fixtures in a throwaway directory: a roster, Claude Code records held by live stand-in processes, context rows,
    a claims board, a transcript, a stand-in tmux and budget. Nothing live is read, and nothing is typed anywhere."""
    import sys
    import tempfile
    import urllib.request
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
                 ROSTER=T + "/roster.json", BUDGET=T + "/bin/budget", PASTED=T + "/pasted")
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
            f.write("#!/usr/bin/env bash\n[ \"$1\" = list-panes ] && printf '%s\\n' "
                    "'proj-ada\t%1\t✳ Ada\tnode\t120\t40' 'work\t%2\t✳ Lea\tclaude\t100\t30' 'other\t%3\t✳ Nobody\tclaude\t80\t24'\n")
        with open(T + "/bin/budget", "w") as f:
            f.write("#!/usr/bin/env bash\necho 'budget  over: week 38% used of 36% planned so far'\n")
        os.chmod(T + "/bin/tmux", 0o755)
        os.chmod(T + "/bin/budget", 0o755)
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

        os.environ.update(AGENT_OWNER_NAME="Pat", AGENT_WEEK_PCT_PER_HOUR="2")
        st = state()
        t("state: sections by role, in order", st["tabs"], ["Lead", "Developers"])
        t("  each running agent in its section, with its ticket",
          [(a["name"], a["tab"], a["ticket"], a["status"]) for a in st["agents"]],
          [("Lea", "Lead", "", "idle"), ("Ada", "Developers", "feat_x", "busy")])
        t("  developers and testers with no session are on the bench, an assistant is not",
          [b["name"] for b in st["bench"]], ["Ben", "Tess"])
        t("  the week's plan and the plan shared out evenly", (st["plan"], st["even"]), (36, 40.0))
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
        t("  and its state", sorted(json.loads(code("/api/state")[1])), ["agents", "bench", "disk", "even", "now", "owner", "plan", "tabs", "week"])
        say = {"Content-Type": "application/json"}
        t("a message without the page's header is refused", code("/api/agent/Ada/say", "POST", say, b'{"text":"hi"}')[0], 403)
        t("  and one from another site", code("/api/agent/Ada/say", "POST", dict(say, **{"X-Team-Say": "1", "Origin": "http://evil.example"}), b'{"text":"hi"}')[0], 403)
        t("  and one with nothing in it", code("/api/agent/Ada/say", "POST", dict(say, **{"X-Team-Say": "1"}), b'{"text":"  "}')[0], 400)
        t("a stop for an agent that is not working is refused", code("/api/agent/Lea/stop", "POST", {"X-Team-Say": "1"}, b"")[0], 409)
        t("an image from outside the home directory is not served", code("/img?p=/etc/passwd")[0], 404)
        server.shutdown()
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
