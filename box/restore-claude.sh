#!/bin/bash
# Recreate the byobu layout and resume every named Claude session after a reboot.
# Safe to re-run: sessions that already exist are left alone, and an agent already
# running anywhere gets an empty slot, so its conversation is never resumed twice. So
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
transcript() { # transcript <claude-name> -> newest .jsonl named <name>, or nothing
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
ident() { # ident <name> -> "env GIT_...=... " or nothing
  local e
  e=$(jq -r --arg n "$1" '.agents[]? | select(.name==$n and .status=="active") | .email' <<<"$ROSTER" 2>/dev/null)
  # AGENT_NAME too: the status line and init.sh read it first, so a resumed agent in the
  # shared checkout is named on its bar without re-running init.sh.
  [ -n "$e" ] && printf 'env AGENT_NAME=%s GIT_AUTHOR_NAME=%s GIT_AUTHOR_EMAIL=%s GIT_COMMITTER_NAME=%s GIT_COMMITTER_EMAIL=%s ' "$1" "$1" "$e" "$1" "$e"
}

# by_role <role>... -> the first active agent holding one of these roles, in roster order, or nothing.
# The fixed tabs below are filled by role, so a rotation changes the roster and nothing here.
by_role() {
  jq -r '[.agents[]? | select(.status == "active" and (.role | IN($ARGS.positional[]))) | .name] | first // empty' \
    --args "$@" <<<"$ROSTER" 2>/dev/null
}
# The house assistant: the first one the roster records (it holds no role, so it is not in .agents).
assistant() { jq -r '.assistants[0].name // empty' <<<"$ROSTER" 2>/dev/null; }
# slot <name> -> the name, or "-" (an empty slot) when the role is vacant
slot() { printf '%s\n' "${1:--}"; }

resume() { # resume <claude-name> -> the command that resumes it as itself
  local f; f=$(transcript "$1")
  if [ -n "$f" ]; then echo "$(ident "$1")claude --resume $(basename "$f" .jsonl)"
  else echo "$(ident "$1")claude --resume $1"; fi
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

# cmd <claude-name> <fallback-dir> -> sets $C and $D for one pane; an agent with no named
# conversation yet gets an empty slot, so the grid keeps its shape. "-" is a deliberately
# empty slot. An empty slot says so in the pane (box/empty-slot.py); Enter gives a shell.
EMPTY="python3 /home/peter/dev/harness/box/empty-slot.py"
cmd() {
  if [ "$1" = - ]; then C=$EMPTY; D=/home/peter; return; fi
  if running "$1"; then echo "skip    $1 (already running), empty slot"; C=$EMPTY; D=$2; return; fi
  if [ -z "$(transcript "$1")" ]; then echo "note    $1 has no named conversation yet, empty slot"; C=$EMPTY; D=$2; return; fi
  C=$(resume "$1"); D=$(dir "$1" "$2")
}

# columns <session> <fallback-dir> <top1> <bottom1> <top2> <bottom2> ... : one window,
# one column per pair, each column split top and bottom. A bottom of "=" leaves that
# column as one full-height pane.
columns() {
  local s=$1 fd=$2 i n; shift 2
  if exists "$s"; then echo "skip    $s (already running)"; return; fi
  local args=("$@") top=() p
  for ((i = 0; i < ${#args[@]}; i += 2)); do
    cmd "${args[i]}" "$fd"
    if [ $i = 0 ]; then p=$(byobu new-session -d -P -F '#{pane_id}' -x 168 -y 51 -s "$s" -c "$D" "$C")
    else p=$(byobu split-window -h -d -P -F '#{pane_id}' -t "${top[-1]}" -c "$D" "$C"); fi
    top+=("$p")
  done
  byobu select-layout -t "$s" even-horizontal >/dev/null
  for ((i = 0; i < ${#top[@]}; i++)); do
    [ "${args[i * 2 + 1]}" = = ] && continue
    cmd "${args[i * 2 + 1]}" "$fd"
    byobu split-window -v -d -t "${top[i]}" -c "$D" "$C"
  done
  echo "started $s ($*)"
}

# --- Delivery: worked out from the roster ---
# delivery_slots -> the Delivery panes in column order (top, bottom, top, bottom, ...): the developers,
# then the testers, then every other active agent not placed in Delivery Lead or Project, in roster
# order, with the code reviewer always last: the bottom-right pane. Each group starts its own columns
# and a group with an odd count ends on an empty slot "-", so developers and testers never share a
# column. Empty columns, added before the last one, pad it to at least 8 panes; more agents means more
# columns.
delivery_slots() {
  local g names out=() rev
  for g in developer tester other; do
    mapfile -t names < <(jq -r --arg g "$g" '.agents[]? | select(.status == "active")
      | select(if $g == "other" then (.role | IN("developer", "tester", "delivery-lead", "head-of-testing", "process-improvement", "production-support", "head-of-operations", "code-reviewer") | not)
               else .role == $g end) | .name' <<<"$ROSTER")
    if [ $g != other ] && [ $(( ${#names[@]} % 2 )) = 1 ]; then names+=(-); fi
    out+=("${names[@]}")
  done
  mapfile -t rev < <(jq -r '.agents[]? | select(.status == "active" and .role == "code-reviewer") | .name' <<<"$ROSTER")
  # The reviewer(s) end the grid, the last one bottom right; a gap goes before them if needed.
  if [ $(( (${#out[@]} + ${#rev[@]}) % 2 )) = 1 ]; then out+=(-); fi
  out+=("${rev[@]}")
  while [ ${#out[@]} -lt 8 ]; do
    if [ ${#out[@]} -ge 2 ]; then out=("${out[@]:0:${#out[@]}-2}" - - "${out[@]: -2}"); else out=(- - "${out[@]}"); fi
  done
  printf '%s\n' "${out[@]}"
}
# Agents use the shared login (~/.claude/.credentials.json), NOT the long-lived token in
# ~/.config/claude-agent-token.env: a setup-token token is inference-only, and Remote Control refuses it
# (tried 2026-10-26, reverted on Peter's word). Make sure none is inherited.
unset CLAUDE_CODE_OAUTH_TOKEN
byobu set-environment -gu CLAUDE_CODE_OAUTH_TOKEN 2>/dev/null || true

mapfile -t SLOTS < <(delivery_slots)
columns Delivery "$S" "${SLOTS[@]}"
# Spawned agents (harness agent-spawn.sh starts each in its own strength-<name> session) are moved
# into Delivery, and a benched agent's pane turned back into an empty slot, by delivery-sync.py, which
# tmux runs whenever a session is created or a pane dies. It also keeps the layout rules above.
byobu set-hook -g session-created 'run-shell -b "python3 /home/peter/dev/harness/box/delivery-sync.py"'
byobu set-hook -g pane-died 'run-shell -b "python3 /home/peter/dev/harness/box/delivery-sync.py"'
python3 /home/peter/dev/harness/box/delivery-sync.py || echo "WARNING delivery-sync.py failed: see byobu show-messages"
# A pane whose agent exits stays in place, marked dead, so the grid never shrinks on its own.
# Bring one agent back in its own pane with:  byobu respawn-pane -t <pane>  (it reruns the resume)
byobu set-option -w -t Delivery remain-on-exit on

# --- the delivery lead, with the team panel ---
# The panel's settings live in box/team-panel.sh, beside this script, and the owner's weekly budget in
# ~/.local/state/strength/agents-budget.env, the one file strength's spawn wrapper also reads. Without it the
# panel refuses to start and says so in its pane.
BUDGET=/home/peter/.local/state/strength/agents-budget.env
[ -r "$BUDGET" ] || echo "WARNING $BUDGET is missing: the team panel will not start until it exists"
LEAD=$(slot "$(by_role delivery-lead)")
PI=$(slot "$(by_role process-improvement)")
PA=$(slot "$(assistant)")
HOT=$(slot "$(by_role head-of-testing)")
OPS=$(slot "$(by_role head-of-operations production-support)")
tree() { [ "$1" = - ] && echo /home/peter || echo "/home/peter/dev/strength-${1,,}"; }

# The delivery lead, with the team panel (harness team/agents-dash.sh) on the right.
if exists "Delivery Lead"; then echo "skip    Delivery Lead (already running)"
else
  cmd "$LEAD" "$(tree "$LEAD")"
  c=$(byobu new-session -d -P -F '#{pane_id}' -x 168 -y 51 -s "Delivery Lead" -c "$D" "$C")
  p=$(byobu split-window -h -d -P -F '#{pane_id}' -l 32 -t "$c" "bash /home/peter/dev/harness/box/team-panel.sh")
  # Pane sizes scale in proportion when the window resizes, so pin the panel back to 32 columns
  # every time it does.
  byobu set-hook -t "Delivery Lead" window-resized "resize-pane -t $p -x 32"
  echo "started Delivery Lead ($LEAD, the team panel)"
fi

# --- Project: process improvement on the left, the house assistant on the right ---
if exists Project; then echo "skip    Project (already running)"
else
  cmd "$PI" /home/peter/dev
  r=$(byobu new-session -d -P -F '#{pane_id}' -x 168 -y 51 -s Project -n Project -c "$D" "$C")
  # The assistant runs from its own folder, ~/dev/<name>: Claude Code never saves trust for the home folder.
  cmd "$PA" "/home/peter/dev/${PA,,}"
  byobu split-window -h -d -t "$r" -c "$D" "$C"
  echo "started Project ($PI, $PA)"
fi

# --- Ops: the head of testing on the left, the head of operations (streak upkeep) on the right ---
if exists Ops; then echo "skip    Ops (already running)"
else
  cmd "$HOT" "$(tree "$HOT")"
  v=$(byobu new-session -d -P -F '#{pane_id}' -x 168 -y 51 -s Ops -n Ops -c "$D" "$C")
  cmd "$OPS" "$S"
  byobu split-window -h -d -t "$v" -c "$D" "$C"
  echo "started Ops ($HOT, $OPS)"
fi

# --- Web: the team as a web page (harness team/agents-web.sh) on http://127.0.0.1:8787, the panel's settings ---
if exists Web; then echo "skip    Web (already running)"
else
  byobu new-session -d -s Web -n Web -c /home/peter "bash /home/peter/dev/harness/box/team-web.sh"
  echo "started Web (the team page, http://127.0.0.1:8787)"
fi

echo
echo "Attach with:"
echo "  byobu attach -t Delivery          (columns: developers, testers, then the rest; at least 8 panes)"
echo "  byobu attach -t 'Delivery Lead'   ($LEAD, the team panel)"
echo "  byobu attach -t Project           ($PI, $PA)"
echo "  byobu attach -t Ops               ($HOT, $OPS)"
