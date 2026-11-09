#!/usr/bin/env bash
# team/owner-wanted.sh — flags the Claude Code session this runs under as wanting the owner, so the team page pulses
# its card, tab, tile and icon amber with LINE as the label, as it does for a session blocked on a prompt.
#
#   bash team/owner-wanted.sh "<one line>"    raise it, or replace the line
#   bash team/owner-wanted.sh --clear         drop it
#   bash team/owner-wanted.sh --self-test
#
# The flag is $AGENT_WANTED_DIR/<session id> (default ~/.local/state/<HARNESS_PROJECT>/wanted), holding the line; the
# page reads it (WANTED in team/lib/agents_web.py). team/activity-hook.sh drops it when the owner next types in that
# session. The session is found by walking up from this process to the one Claude Code records under
# ${CLAUDE_CONFIG_DIR:-~/.claude}/sessions/<pid>.json.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"
. "$_here/../scripts/lib/harness-env.sh" 2>/dev/null || true

# flag <dir> <session id> <line | --clear>: writes or removes the session's flag   (the real action)
flag() {
  local dir="$1" sid="$2" line="$3"
  [[ -n "$sid" && "$sid" != */* ]] || return 1
  if [[ "$line" == --clear ]]; then rm -f "$dir/$sid"; return 0; fi
  mkdir -p "$dir" && printf '%s\n' "${line//$'\n'/ }" > "$dir/.$sid.tmp" && mv -f "$dir/.$sid.tmp" "$dir/$sid"
}

# session_id: the id of the Claude Code session this process runs under, or nothing
session_id() {
  local sessions="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions" sid="" pid=$$ f
  while [[ -z "$sid" && -n "$pid" ]] && [ "$pid" -gt 1 ] 2>/dev/null; do
    f="$sessions/$pid.json"
    [[ -r "$f" ]] && sid=$(jq -r '.sessionId // empty' "$f" 2>/dev/null)
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  printf '%s' "$sid"
}

if selftest_is_flag "${1:-}"; then
  fails=0; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
  flag "$T/w" s1 "needs a decision"; check "a flag holds its line" "$(cat "$T/w/s1")" "needs a decision"
  flag "$T/w" s1 $'two\nlines'; check "a later line replaces it, on one line" "$(cat "$T/w/s1")" "two lines"
  flag "$T/w" s1 --clear; check "--clear drops it" "$(ls -A "$T/w" | wc -l | tr -d ' ')" 0
  flag "$T/w" ../x "no"; check "a session id with a slash is refused" "$?" 1
  mkdir -p "$T/c/sessions" && printf '{"sessionId":"sx"}' > "$T/c/sessions/$$.json"
  check "the session is found from this process up" "$(CLAUDE_CONFIG_DIR="$T/c" session_id)" sx
  HOME=$T CLAUDE_CONFIG_DIR="$T/none" bash "$_here/owner-wanted.sh" "a line" 2>/dev/null; check "outside a session it fails" "$?" 1
  bash "$_here/owner-wanted.sh" 2>/dev/null; check "no line is refused" "$?" 2
  bash "$_here/owner-wanted.sh" --now 2>/dev/null; check "an unknown flag is refused" "$?" 2
  [ "$fails" -eq 0 ] && { echo "all passed"; exit 0; } || { echo "$fails failed"; exit 1; }
fi

[[ $# -eq 1 && -n "$1" ]] || { echo 'usage: owner-wanted.sh "<one line>" | --clear' >&2; exit 2; }
[[ "$1" != --* || "$1" == --clear ]] || { echo "owner-wanted: unknown flag $1" >&2; exit 2; }
sid="$(session_id)"
[[ -n "$sid" ]] || { echo "owner-wanted: not running under a Claude session" >&2; exit 1; }
flag "${AGENT_WANTED_DIR:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/wanted}" "$sid" "$1"
