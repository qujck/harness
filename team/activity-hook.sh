#!/usr/bin/env bash
# team/activity-hook.sh — records what a Claude Code session is doing, for the status line to publish.
#
#   called from the hooks in ~/.claude/settings.json (team/install-claude-code.sh wires them):
#   bash team/activity-hook.sh <Event>      # the hook's JSON on stdin
#   bash team/activity-hook.sh --self-test
#
# Writes "<state> <epoch>" to $ACTIVITY_DIR/<session id> (default ~/.local/state/<HARNESS_PROJECT>/activity),
# where <state> is working, waiting or idle: a tool call or a prompt is working, a permission prompt or a
# question to the person is waiting, a stop is idle, and a session's end removes its file. The publisher
# (team/statusline-publish.sh) reads it into the row's `activity` and `idle_s` (docs/context-publisher.md),
# because a long tool call or a permission prompt writes nothing to the transcript, so the transcript
# alone makes a busy or blocked agent look idle. Best effort: it never fails the hook it runs from.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$_here/../scripts/lib/selftest-flag.sh"
. "$_here/../scripts/lib/harness-env.sh" 2>/dev/null || true

# state_of <event> <tool name> -> working | waiting | idle | gone | "" (an event this hook ignores)   (pure)
state_of() {
  case "$1" in
    PreToolUse) [[ "$2" == AskUserQuestion ]] && printf 'waiting' || printf 'working' ;;
    PermissionRequest) printf 'waiting' ;;
    UserPromptSubmit|PostToolUse|PostToolUseFailure) printf 'working' ;;
    Stop|SessionStart) printf 'idle' ;;
    SessionEnd) printf 'gone' ;;
    *) printf '' ;;
  esac
}

# record <dir> <event> <hook json> <epoch>: writes or removes the session's file   (the real action)
record() {
  local dir="$1" ev="$2" in="$3" now="$4" sid tool st
  sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)"
  [[ -n "$sid" && "$sid" != */* ]] || return 0
  # A subagent's hooks carry its parent's session_id plus an agent_id. Background side agents (a feedback
  # draft, a peer send) run after the parent's Stop, so letting them write left idle sessions "working"
  # (2026-10-29: 7 of 16 live sessions, and #108's cap read 9-11 against 1-3 busy).
  [[ -z "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ]] || return 0
  tool="$(jq -r '.tool_name // empty' <<<"$in" 2>/dev/null)"
  st="$(state_of "$ev" "$tool")"
  case "$st" in
    '') return 0 ;;
    gone) rm -f "$dir/$sid"; return 0 ;;
  esac
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s %s\n' "$st" "$now" > "$dir/.$sid.tmp" && mv -f "$dir/.$sid.tmp" "$dir/$sid"
  return 0
}

case "${1:-}" in
  --*) selftest_is_flag "$1" || { echo "activity-hook: unknown flag $1 (an event name, or --self-test)" >&2; exit 2; } ;;
esac
if selftest_is_flag "${1:-}"; then
  f=0; d="$(mktemp -d)"; _t() { [[ "$2" == "$3" ]] && printf '  ok    %s\n' "$1" || { printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; f=1; }; }
  _t "a tool call is working" working "$(state_of PreToolUse Bash)"
  _t "a question to the person is waiting" waiting "$(state_of PreToolUse AskUserQuestion)"
  _t "a permission prompt is waiting" waiting "$(state_of PermissionRequest '')"
  _t "a stop is idle" idle "$(state_of Stop '')"
  _t "an unknown event is nothing" "" "$(state_of Notification '')"
  record "$d" PreToolUse '{"session_id":"s1","tool_name":"Bash"}' 100
  _t "the file carries the state and the time" "working 100" "$(cat "$d/s1")"
  record "$d" Stop '{"session_id":"s1"}' 160
  _t "a later event replaces it" "idle 160" "$(cat "$d/s1")"
  record "$d" PreToolUse '{"session_id":"s1","agent_id":"a1","tool_name":"SendMessage"}' 180
  _t "a subagent's tool call after the stop leaves it idle" "idle 160" "$(cat "$d/s1")"
  record "$d" Notification '{"session_id":"s1"}' 200
  _t "an ignored event leaves it" "idle 160" "$(cat "$d/s1")"
  record "$d" SessionEnd '{"session_id":"s1"}' 300
  _t "the session's end removes it" 0 "$(ls "$d" | wc -l | tr -d ' ')"
  record "$d" Stop 'not json' 400; record "$d" Stop '{"session_id":"../x"}' 400
  _t "no session id, or one with a slash, writes nothing" 0 "$(ls -A "$d" | wc -l | tr -d ' ')"
  rm -rf "$d"
  (( f == 0 )) && { echo "activity-hook: self-test ok"; exit 0; } || { echo "activity-hook: self-test FAILED" >&2; exit 1; }
fi

record "${ACTIVITY_DIR:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/activity}" "${1:-}" "$(cat)" "$(date +%s)"
exit 0
