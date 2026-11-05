#!/usr/bin/env bash
# Records what a Claude session is doing, for the status line to read.
#
# Called from the hooks in ~/.claude/settings.json with the event as $1; the hook
# payload (JSON) arrives on stdin. Writes "<state> <epoch>" to
#   ~/.local/state/claude-activity/<session_id>
#
#   working  a turn is in progress: a prompt was submitted or a tool is running,
#            however long that tool takes (a gh run watch, a sleep loop, a build)
#   waiting  the session is blocked on the owner: a permission prompt or a
#            question (AskUserQuestion) is on screen
#   idle     the turn finished (Stop)
#
# Why: the bar used to infer activity from the transcript's mtime, which goes
# quiet during any long tool call or permission prompt, so a busy or blocked
# agent showed as idle. Hooks are told directly. Best-effort: never fails a hook.
ev=$1
in=$(cat)
sid=$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null)
[ -n "$sid" ] || exit 0
# A subagent's hooks carry its parent's session_id plus an agent_id. Background side agents
# run after the parent's Stop, so letting them write would leave an idle session "working".
[ -z "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ] || exit 0
d="$HOME/.local/state/claude-activity"
mkdir -p "$d" 2>/dev/null || exit 0

case "$ev" in
  PreToolUse)
    if [ "$(jq -r '.tool_name // empty' <<<"$in")" = AskUserQuestion ]; then st=waiting; else st=working; fi ;;
  PermissionRequest) st=waiting ;;
  UserPromptSubmit|PostToolUse|PostToolUseFailure) st=working ;;
  Stop|SessionStart) st=idle ;;
  SessionEnd) rm -f "$d/$sid"; exit 0 ;;
  *) exit 0 ;;
esac
printf '%s %s\n' "$st" "$(date +%s)" > "$d/.$sid.tmp" && mv -f "$d/.$sid.tmp" "$d/$sid"
exit 0
