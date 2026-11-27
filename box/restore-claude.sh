#!/bin/bash
# Resume every agent that was running, each in its own byobu session, after a reboot.
# Safe to re-run: sessions that already exist are left alone, and an agent already
# running anywhere is skipped, so its conversation is never resumed twice. So
# this can be used to bring back one missing session without touching the others.
# Attach to any session with:  byobu attach -t <name>
set -e
S=/home/peter/dev/strength

# True if a session with exactly this name exists. Grouped client sessions
# (Engineers-6, Carl-7, ...) are deliberately not matched.
exists() {
  byobu list-sessions -F '#{session_name}' 2>/dev/null | grep -Fxq "$1"
}

# Resume by conversation ID, not name: when two conversations share a name,
# "claude --resume <name>" stops at a picker and the agent never starts.
# The ID is the newest conversation whose latest /rename is exactly <name>.
TITLES=$(command grep -oH '"customTitle":"[^"]*"' /home/peter/.claude/projects/*/*.jsonl 2>/dev/null |
  awk -F'"customTitle":"' '{sub(/"$/,"",$2); last[$1]=$2} END {for (f in last) print f "\t" last[f]}')
# WHO WAS UP. The team page (harness team/lib/agents_web.py, note_up) keeps a record of every agent running and its
# session, and takes one off only after watching it stop (a bench); a reboot or a crash leaves it as it was. With that
# record, exactly the agents in it come back, each resuming the conversation it had, and nobody else. Without
# it (no page ran) the old way: every active agent, by its newest /rename title. (2026-11-14: by title alone, the
# seven agents spawned that day, in unnamed conversations, stayed down and seven benched agents came back instead.)
LIVE=${LIVE_AGENTS_FILE:-/home/peter/.local/state/strength/live-agents.json}
UP=$(jq -c '.agents // empty' "$LIVE" 2>/dev/null || true)
was_up() { [ -z "$UP" ] || jq -e --arg n "$1" 'has($n)' <<<"$UP" >/dev/null 2>&1; }
transcript() { # transcript <claude-name> -> the recorded session's .jsonl, else the newest .jsonl named <name>, or nothing
  local sid
  sid=$([ -n "$UP" ] && jq -r --arg n "$1" '.[$n].sessionId // empty' <<<"$UP" 2>/dev/null)
  if [ -n "$sid" ]; then ls -t /home/peter/.claude/projects/*/"$sid".jsonl 2>/dev/null | head -1; return; fi
  printf '%s\n' "$TITLES" | awk -F'\t' -v n="$1" '$2==n {print $1}' | sed 's/:$//' | xargs -r ls -t | head -1
}

# True if a live Claude Code process is this agent, in any session. Its identity in its environment says
# whose it is, so another name on the record, or a crashed session's old record whose pid a new claude reuses,
# doesn't mislead; without an identity (the house assistant) the record's name says. An agent's meeting
# session is its own conversation, so it doesn't count, whatever identity its process carries.
running() { # running <claude-name>
  local f p said who
  for f in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/*.json; do
    [ -e "$f" ] || continue
    p=${f##*/}; p=${p%.json}
    [ "$(cat "/proc/$p/comm" 2>/dev/null)" = claude ] || continue
    said=$(jq -r '.name // ""' "$f" 2>/dev/null)
    [[ $said == *" · meeting" ]] && continue
    who=$(tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | sed -n 's/^GIT_AUTHOR_NAME=//p' | head -1)
    who=${who:-$said}
    [ "${who,,}" = "${1,,}" ] && return 0
  done
  return 1
}

# Identity is set at launch and a resume needs it as much as a fresh start
# (strength scripts/start-agent.sh). Rostered agents get their GIT_AUTHOR_* /
# GIT_COMMITTER_* from agents/roster.json; anyone not on it (the house assistant) gets none.
ROSTER=$(git -C "$S" show origin/main:agents/roster.json 2>/dev/null || cat "$S/agents/roster.json" 2>/dev/null || true)
# The people may live outside git (strength #7164): the roster names their file in `_people_file`.
_people=$(jq -r '._people_file // empty' <<<"$ROSTER" 2>/dev/null)
[ -n "$_people" ] && ROSTER=$(cat "$_people" 2>/dev/null || true)
ident() { # ident <name> -> "env GIT_...=... " or nothing
  local e
  e=$(jq -r --arg n "$1" '.agents[]? | select(.name==$n and .status=="active") | .email' <<<"$ROSTER" 2>/dev/null)
  # AGENT_NAME too: the status line and init.sh read it first, so a resumed agent in the
  # shared checkout is named on its bar without re-running init.sh.
  [ -n "$e" ] && printf 'env AGENT_NAME=%s GIT_AUTHOR_NAME=%s GIT_AUTHOR_EMAIL=%s GIT_COMMITTER_NAME=%s GIT_COMMITTER_EMAIL=%s ' "$1" "$1" "$e" "$1" "$e"
}

# The reasoning effort an agent was last spawned at: column 11 of team/agent-spawn.sh's record of every spawn, "-"
# for none. An agent with no effort recorded resumes at the session default.
SPAWN_LOG=${AGENT_SPAWN_LOG:-/home/peter/.local/state/strength/agent-spawns.tsv}
effort_of() { # effort_of <claude-name> -> " --effort <level>", or nothing
  local e
  e=$(awk -F'\t' -v n="$1" '$2 == n { e = $11 } END { print e }' "$SPAWN_LOG" 2>/dev/null)
  case "$e" in low|medium|high|xhigh|max) printf ' --effort %s' "$e" ;; esac
}

resume() { # resume <claude-name> -> the command that resumes it as itself, at the effort it was spawned at
  local f; f=$(transcript "$1")
  if [ -n "$f" ]; then echo "$(ident "$1")claude$(effort_of "$1") --resume $(basename "$f" .jsonl)"
  else echo "$(ident "$1")claude$(effort_of "$1") --resume $1"; fi
}

# Resume in the conversation's PROJECT directory, the one its transcript is filed
# under, or --resume may not find it (a worktree for agents launched with --worktree).
# Not the last "cwd" (wherever the agent last cd'd) nor the first (a directory may
# have been renamed since): the cwd whose encoded form is the project folder's name.
dir() { # dir <claude-name> <fallback>
  local f p d c; f=$(transcript "$1")
  if [ -n "$f" ]; then
    p=$(basename "$(dirname "$f")")
    while IFS= read -r c; do
      [ "$(printf '%s' "$c" | sed 's/[^A-Za-z0-9]/-/g')" = "$p" ] && [ -d "$c" ] && { d=$c; break; }
    done < <(LC_ALL=C command grep -a -o '"cwd":"[^"]*"' "$f" | sort -u | sed 's/"cwd":"//; s/"$//')
    # A conversation moved to a new folder (Vera, to ~/vera) has no cwd there until its
    # first turn; read the folder back from the project name when it has no dashes or dots.
    [ -z "$d" ] && [ -d "$(printf '%s' "$p" | tr '-' '/')" ] && d=$(printf '%s' "$p" | tr '-' '/')
  fi
  echo "${d:-$2}"
}

# Every agent in its own session (owner, 2026-11-23: "give each agent their own byobu session"), named as
# harness team/agent-spawn.sh names a spawned one, by the agent's name (Ada), so the spawn and the bench find a
# restored agent the same way (team/lib/agent-session.sh) and byobu's menu lists it (it hides any name with a "-").
session() { printf '%s\n' "${1^}"; }

# home <name> <role> -> the folder to fall back on when the conversation's own can't be read
home() {
  case $2 in
    project-office) echo "/home/peter/dev/${1,,}" ;;   # Claude Code never saves trust for the home folder
    process-improvement) echo /home/peter/dev ;;
    *) [ -d "/home/peter/dev/strength-${1,,}" ] && echo "/home/peter/dev/strength-${1,,}" || echo "$S" ;;
  esac
}

# one <name> <role>: resume this agent in its own session, unless it is up already
one() {
  local s; s=$(session "$1")
  if exists "$s"; then echo "skip    $s (already running)"; return; fi
  if running "$1"; then echo "skip    $1 (already running in another session)"; return; fi
  if [ -z "$(transcript "$1")" ]; then echo "note    $1 has no named conversation yet, not started"; return; fi
  byobu new-session -d -x 168 -y 51 -s "$s" -c "$(dir "$1" "$(home "$1" "$2")")" "$(resume "$1")"
  echo "started $s"
}

# Agents use the shared login (~/.claude/.credentials.json), NOT the long-lived token in
# ~/.config/claude-agent-token.env: a setup-token token is inference-only, and Remote Control refuses it
# (tried 2026-10-26, reverted on Peter's word). Make sure none is inherited.
unset CLAUDE_CODE_OAUTH_TOKEN
byobu set-environment -gu CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true

# Each spawned developer and tester gets its role's colour from delivery-sync.py, which tmux runs whenever a
# session is created. It moves nothing: every agent stays in its own session.
byobu set-hook -g session-created 'run-shell -b "python3 /home/peter/dev/harness/box/delivery-sync.py"'
byobu set-hook -gu pane-died 2>/dev/null || true

# The agents that were up (every active one when there is no record of who was), in roster order.
while IFS=$'\t' read -r name role; do
  was_up "$name" && one "$name" "$role"
done < <(jq -r '.agents[]? | select(.status == "active") | [.name, .role] | @tsv' <<<"$ROSTER")
python3 /home/peter/dev/harness/box/delivery-sync.py || echo "WARNING delivery-sync.py failed: see byobu show-messages"

# --- the team panel, in its own session ---
# The panel's settings live in box/team-panel.sh, beside this script, and the owner's weekly budget in
# ~/.local/state/strength/agents-budget.env, the one file strength's spawn wrapper also reads. Without it the
# panel refuses to start and says so in its pane.
BUDGET=/home/peter/.local/state/strength/agents-budget.env
[ -r "$BUDGET" ] || echo "WARNING $BUDGET is missing: the team panel will not start until it exists"
if exists Panel; then echo "skip    Panel (already running)"
else
  byobu new-session -d -s Panel -n Panel -c /home/peter "bash /home/peter/dev/harness/box/team-panel.sh"
  echo "started Panel (the team panel)"
fi

# --- Web: the team as a web page (harness team/agents-web.sh) on http://127.0.0.1:8787, the panel's settings ---
if exists Web; then echo "skip    Web (already running)"
else
  byobu new-session -d -s Web -n Web -c /home/peter "bash /home/peter/dev/harness/box/team-web.sh"
  echo "started Web (the team page, http://127.0.0.1:8787)"
fi

echo
echo "Attach with:  byobu   (it lists one session per agent, by name: pick one)"
