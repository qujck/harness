#!/bin/bash
# Recreate the byobu layout and resume every named Claude session after a reboot.
# Safe to re-run: sessions that already exist are left alone, so this can be used
# to bring back one missing session without touching the others.
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

# Identity is set at launch and a resume needs it as much as a fresh start
# (strength scripts/start-agent.sh). Rostered agents get their GIT_AUTHOR_* /
# GIT_COMMITTER_* from agents/roster.json; anyone not on it (Alfred) gets none.
ROSTER=$(git -C "$S" show origin/main:agents/roster.json 2>/dev/null || cat "$S/agents/roster.json" 2>/dev/null || true)
ident() { # ident <name> -> "env GIT_...=... " or nothing
  local e
  e=$(jq -r --arg n "$1" '.agents[]? | select(.name==$n and .status=="active") | .email' <<<"$ROSTER" 2>/dev/null)
  # AGENT_NAME too: the status line and init.sh read it first, so a resumed agent in the
  # shared checkout is named on its bar without re-running init.sh.
  [ -n "$e" ] && printf 'env AGENT_NAME=%s GIT_AUTHOR_NAME=%s GIT_AUTHOR_EMAIL=%s GIT_COMMITTER_NAME=%s GIT_COMMITTER_EMAIL=%s ' "$1" "$1" "$e" "$1" "$e"
}

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

start() { # start <session> <fallback-dir> <claude-name>
  if exists "$1"; then
    echo "skip    $1 (already running)"
  else
    byobu new-session -d -s "$1" -c "$(dir "$3" "$2")" "$(resume "$3")"
    echo "started $1"
  fi
}

# cmd <claude-name> <fallback-dir> -> sets $C and $D for one pane; an agent with no named
# conversation yet gets a plain shell in its slot, so the grid keeps its shape. "-" is a
# deliberately empty slot.
cmd() {
  if [ "$1" = - ]; then C=bash; D=/home/peter; return; fi
  if [ -z "$(transcript "$1")" ]; then echo "note    $1 has no named conversation yet, shell in its slot"; C=bash; D=$2; return; fi
  C=$(resume "$1"); D=$(dir "$1" "$2")
}

# columns <session> <fallback-dir> <top1> <bottom1> <top2> <bottom2> ... : one window,
# one column per pair, each column split top and bottom.
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
    cmd "${args[i * 2 + 1]}" "$fd"
    byobu split-window -v -d -t "${top[i]}" -c "$D" "$C"
  done
  echo "started $s ($*)"
}

# --- Delivery: devs in the left 2x2 block, testers, then the empty slot over Stephanie ---
columns Delivery "$S" Saffron Anthony Cara Ed Vera Tommy - Stephanie

# --- the delivery lead, with the team panel ---
start "Delivery Lead" /home/peter/dev/strength-carl Carl
# The team panel (harness scripts/agents-dash.sh) in a 32-column pane beside the delivery lead,
# added only when the session has just one pane, so a re-run never stacks a second panel.
if [ "$(byobu list-panes -t "Delivery Lead" 2>/dev/null | wc -l)" = 1 ]; then
  p=$(byobu split-window -h -d -P -F '#{pane_id}' -l 32 -t "Delivery Lead" "env ROSTER_FILE=$S/agents/roster.json CONTEXT_DIR=/home/peter/.local/state/strength/context AGENTS_DASH_CACHE=/home/peter/.local/state/strength/dash bash /home/peter/dev/harness/scripts/agents-dash.sh")
  # A detached session is 80 wide, so -l 32 alone scales up to half the screen on attach.
  # Pin it back to 32 columns every time the window changes size.
  byobu set-hook -t "Delivery Lead" window-resized "resize-pane -t $p -x 32"
  echo "started the team panel"
fi

# --- Project: Rowan on the left, Alfred on the right ---
if exists Project; then echo "skip    Project (already running)"
else
  cmd Rowan /home/peter/dev
  byobu new-session -d -s Project -n Project -c "$D" "$C"
  cmd Alfred /home/peter
  byobu split-window -h -d -t Project:Project -c "$D" "$C"
  echo "started Project (Rowan, Alfred)"
fi

echo
echo "Attach with:"
echo "  byobu attach -t Delivery          (Saffron, Cara / Anthony, Ed | Vera / Tommy | empty / Stephanie)"
echo "  byobu attach -t 'Delivery Lead'   (Carl and the team panel)"
echo "  byobu attach -t Project           (Rowan, Alfred)"
