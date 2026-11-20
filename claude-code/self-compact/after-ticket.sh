#!/usr/bin/env bash
# claude-code/self-compact/after-ticket.sh — a reviewer's session compacts after every ticket it finishes.
#
#   (PostToolUse hook, matcher Bash: the hook payload on stdin)
#   bash claude-code/self-compact/after-ticket.sh --self-test
#
# WHY. Owner, 2026-11-20: "both roles should say compact after every ticket - ideally using a hook". The test reviewer
# had burned 13.4M tokens by 08:30Z: 721 calls at about 120k of context each, compacting only when the mod nudged at
# 150k, because a delivery lead's relay every five minutes left no finished review to stop at. A review carries
# nothing to the next one (its session entry in the ledger holds what it found), so the end of one is the cheapest
# point to compact, and a hook does not depend on the reviewer remembering to.
#
# WHAT ENDS A TICKET. `ledger-db.sh work off`, which a reviewer runs when its approval or findings are in (the role
# docs say so; scripts/ticket-cost.sh reads the same marker). PostToolUse fires only for a call that succeeded.
#
# WHAT IT DOES. For an agent whose role in the roster is one of AFTER_TICKET_ROLES, it writes this session's compact
# request through compact-me.sh, and tells the agent so (additionalContext): the self-compact mod compacts at the end
# of the turn. Anyone else, any other command, a subagent's call, or a roster it cannot read: nothing, exit 0. It never
# fails the tool call it follows.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../../scripts/lib/selftest-flag.sh"

AFTER_TICKET_ROLES="${AFTER_TICKET_ROLES:-code-reviewer test-reviewer}"
AFTER_TICKET_ROSTER="${AFTER_TICKET_ROSTER:-$HOME/dev/strength/agents/roster.json}"
KEEP="You finished a review (ledger-db.sh work off), so this session compacts at the end of this turn. Keep: your name and role, each PR still with you and the sha you read, and that your ledger session entries hold the detail. Next action: read your latest session entry, then wait for the delivery lead's next message."

# ends_ticket <hook payload> -> exit 0 when it is a main-session Bash call that ran `ledger-db.sh ... work off`   (pure)
ends_ticket() {
  jq -e 'select((.agent_id // "") == "" and .tool_name == "Bash" and ((.tool_response.interrupted // false) | not))
         | .tool_input.command // "" | test("ledger-db\\.sh[^|;&\n]*\\bwork[[:space:]]+off\\b")' >/dev/null 2>&1 <<<"$1"
}

# role_of <name> <roster> -> the roster role for name (any case), or nothing   (pure)
role_of() {
  jq -r --arg n "${1,,}" '.agents[] | select((.name | ascii_downcase) == $n) | .role // empty' "$2" 2>/dev/null | head -1
}

run() {
  local in sid role
  in="$(cat)"
  ends_ticket "$in" || return 0
  role="$(role_of "${GIT_AUTHOR_NAME:-}" "$AFTER_TICKET_ROSTER")"
  [[ -n "$role" && " $AFTER_TICKET_ROLES " == *" $role "* ]] || return 0
  sid="$(jq -r '.session_id // empty' <<<"$in")"
  CLAUDE_CODE_SESSION_ID="$sid" bash "$HERE/compact-me.sh" "$KEEP" >/dev/null 2>&1 || return 0
  jq -n --arg c "Ticket finished, so a compaction is queued for the end of this turn. Make sure your session entry is written, then END YOUR TURN; do not start the next review first." \
    '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}'
}

self_test() {
  local fails=0 d r out
  _t() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1"; echo "       got  $2"; echo "       want $3"; fails=$((fails + 1)); fi; }
  p() { jq -nc --arg c "$1" --arg a "${2:-}" --arg t "${3:-Bash}" '{session_id: "sid-1", tool_name: $t, tool_input: {command: $c}, tool_response: {stdout: "ok"}} + (if $a != "" then {agent_id: $a} else {} end)'; }
  y() { ends_ticket "$(p "$@")" && echo yes || echo no; }
  _t "work off ends a ticket" "$(y 'bash scripts/ledger-db.sh work off')" yes
  _t "with an id, inside a longer command" "$(y 'cd x && bash scripts/ledger-db.sh work off 12400 && bash scripts/handoff.sh')" yes
  _t "work on does not" "$(y 'bash scripts/ledger-db.sh work on 12400')" no
  _t "work switch does not" "$(y 'bash scripts/ledger-db.sh work switch 12401')" no
  _t "the words elsewhere in a command do not" "$(y 'echo work off; bash scripts/ledger-db.sh verdicts 1')" no
  _t "a subagent's call does not" "$(y 'bash scripts/ledger-db.sh work off' agent-7)" no
  _t "another tool does not" "$(y 'bash scripts/ledger-db.sh work off' '' Write)" no
  d="$(mktemp -d)"
  printf '{"agents":[{"name":"OBrian","role":"test-reviewer"},{"name":"Addy","role":"code-reviewer"},{"name":"Ada","role":"developer"}]}' > "$d/roster.json"
  _t "the roster's role, any case" "$(role_of obrian "$d/roster.json")" test-reviewer
  _t "an unreadable roster: no role" "$(role_of Addy "$d/none.json")" ""
  # the real entry point: a reviewer's work off writes this session's request and says so; a developer's writes nothing
  out="$(p 'bash scripts/ledger-db.sh work off' | GIT_AUTHOR_NAME=Addy AFTER_TICKET_ROSTER="$d/roster.json" XDG_STATE_HOME="$d/s" bash "$HERE/after-ticket.sh")"
  r="$(jq -r .instructions "$d/s/self-compact/sid-1.json" 2>/dev/null)"
  _t "a code reviewer's work off queues its compaction, with what to keep" "${r:0:41}" "You finished a review (ledger-db.sh work "
  _t "and tells the agent to end its turn" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out" | grep -c 'END YOUR TURN')" 1
  rm -rf "$d/s"
  out="$(p 'bash scripts/ledger-db.sh work off' | GIT_AUTHOR_NAME=Ada AFTER_TICKET_ROSTER="$d/roster.json" XDG_STATE_HOME="$d/s" bash "$HERE/after-ticket.sh")"
  _t "a developer's work off queues nothing and says nothing" "$([[ -e "$d/s/self-compact/sid-1.json" ]] && echo file)$out" ""
  out="$(p 'bash scripts/ledger-db.sh work on 1' | GIT_AUTHOR_NAME=OBrian AFTER_TICKET_ROSTER="$d/roster.json" XDG_STATE_HOME="$d/s" bash "$HERE/after-ticket.sh")"
  _t "a reviewer's work on queues nothing" "$([[ -e "$d/s/self-compact/sid-1.json" ]] && echo file)$out" ""
  rm -rf "$d"
  if (( fails == 0 )); then echo "after-ticket --self-test: ok"; else echo "after-ticket --self-test: $fails FAILED"; return 1; fi
}

if selftest_is_flag "${1:-}"; then self_test; exit $?; fi
run
exit 0
