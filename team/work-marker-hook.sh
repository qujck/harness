#!/usr/bin/env bash
# team/work-marker-hook.sh — marks which ticket an agent is on, so every conversation is counted against its ticket.
#
#   (SessionStart, and PostToolUse with matcher Bash: the hook payload on stdin; team/install-claude-code.sh wires both)
#   bash team/work-marker-hook.sh --self-test
#
# WHY. Owner, 2026-11-20: asked whether a hook writes the ticket id against every conversation; none did. The
# project's ticket-cost report splits each agent's usage by work markers (`ledger-db.sh work on|off|switch`), and
# only the agents who remembered to type them were counted: on 11-20 two developers had never marked, the delivery
# lead had not since 11-08, and two marks had been left "on" for a week. A hook does not depend on remembering.
#
# WHAT IT MARKS, from the commands an agent already runs (main session only, a call that succeeded):
#   claim <id>                (feature-ticket.sh or ledger-db.sh)          work on <id>
#   git checkout / git switch to a branch named <id> or <id>-pt<N>         work switch <id>   (off every other ticket)
#   release | sign-off | hand-over <id>   (ledger-db.sh, feature-ticket.sh release)   work off <id>
#   handoff.sh                (the end of a session)                        work off           (every ticket)
# and at SessionStart (a spawn, a resume, after a compaction) a tree whose branch is <id> or <id>-pt<N>: work on <id>;
# on any other branch or a detached head, the ticket agent-spawn.sh named in STRENGTH_TICKET, if it set one.
# A command that already runs `ledger-db.sh work` is left alone: the agent marked it by hand.
#
# It writes through the tree's own scripts/ledger-db.sh, so the ledger checks who is asking (the session identity)
# and refuses a ticket it has no row for; a tree without that script (any other repo) is skipped. A repeat is the
# ledger's no-op. It tells the agent only what it marked. It never fails the call it follows, and never blocks it.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/../scripts/lib/selftest-flag.sh"

WORK_MARKER_TIMEOUT="${WORK_MARKER_TIMEOUT:-8}"
# roles whose sessions work in other people's trees and branches, so a branch says nothing about their ticket
WORK_MARKER_SKIP_ROLES="${WORK_MARKER_SKIP_ROLES:-project-office}"
_ID='[A-Za-z0-9_.-]+'

# intents <command> -> one line per marker it implies: "on <id>", "off <id>", "off", or "branch"   (pure)
intents() {
  local c="$1" re
  [[ "$c" =~ ledger-db\.sh[^|\;\&]*[[:space:]]work[[:space:]] ]] && return 0
  re="(feature-ticket|ledger-db)\.sh[[:space:]]+claim[[:space:]]+($_ID)"
  [[ "$c" =~ $re ]] && echo "on ${BASH_REMATCH[2]}"
  re="(ledger-db\.sh[[:space:]]+(release|sign-off|hand-over)|feature-ticket\.sh[[:space:]]+release)[[:space:]]+($_ID)"
  [[ "$c" =~ $re ]] && echo "off ${BASH_REMATCH[3]}"
  # the end of a session is off everything, whatever it checked out on the way (a tester detaches first)
  [[ "$c" =~ (^|[^A-Za-z0-9_-])handoff\.sh([[:space:]]|$) ]] && { echo "off"; return 0; }
  re="(^|[;&|[:space:]])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(checkout|switch)([[:space:]]|$)"
  [[ "$c" =~ $re ]] && echo "branch"
  return 0
}

# ticket_of_branch <branch> -> the ticket a branch is cut for, or nothing   (pure)
#   a ledger number: <N>, <N>-pt<M>, <N>-hotfix or <N>-raise -> N (strength #6854: numbers replace the text ids)
#   an old text id, until the ids are gone: <id> or <id>-pt<M> -> id
ticket_of_branch() {
  local b="$1"
  case "$b" in ""|main|master|HEAD|*/*) return 0 ;; esac
  [[ "$b" =~ ^([1-9][0-9]{0,8})(-pt[0-9]+|-hotfix|-raise)?$ ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
  [[ "$b" =~ ^(.+)-pt[0-9]+$ ]] && b="${BASH_REMATCH[1]}"
  [[ "$b" =~ ^[A-Za-z0-9_.-]+$ && "$b" == *_* ]] && printf '%s' "$b"
  return 0
}

# role_of <name> <roster> -> the roster role for name (any case), or nothing   (pure)
role_of() {
  jq -r --arg n "${1,,}" '.agents[] | select((.name | ascii_downcase) == $n) | .role // empty' "$2" 2>/dev/null | head -1
}

# mark <tree> <kind> [id] -> the ledger's answer (ok:on:<id>, already:on, no-such-ticket:<id>, ...), or nothing
mark() {
  local top="$1"; shift
  local led="${WORK_MARKER_LEDGER:-$top/scripts/ledger-db.sh}"
  [[ -f "$led" ]] || return 0
  (cd "$top" && timeout "$WORK_MARKER_TIMEOUT" bash "$led" work "$@" 2>/dev/null) | grep -oE '(ok|already):[a-z]+(:[A-Za-z0-9_.-]+)?' | head -1
}

run() {
  local event="$1" in cwd top cmd line kind id b ans said=()
  in="$(cat)"
  [[ -z "$(jq -r '.agent_id // empty' <<<"$in" 2>/dev/null)" ]] || return 0
  cwd="$(jq -r '.cwd // empty' <<<"$in" 2>/dev/null)"; [[ -n "$cwd" ]] || cwd="$PWD"
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || return 0
  [[ -f "${WORK_MARKER_LEDGER:-$top/scripts/ledger-db.sh}" ]] || return 0
  local role; role="$(role_of "${GIT_AUTHOR_NAME:-}" "$top/agents/roster.json")"
  [[ -n "$role" && " $WORK_MARKER_SKIP_ROLES " == *" $role "* ]] && return 0
  if [[ "$event" == SessionStart ]]; then
    # the branch first; else the ticket agent-spawn.sh started this session for (a tester's tree starts detached)
    local how="this tree's branch"
    id="$(ticket_of_branch "$(git -C "$top" branch --show-current 2>/dev/null)")"
    if [[ -z "$id" && "${STRENGTH_TICKET:-}" =~ ^#?[A-Za-z0-9_.-]+$ ]]; then id="${STRENGTH_TICKET#\#}"; how="the ticket this session was spawned for"; fi
    [[ -n "$id" ]] || return 0
    ans="$(mark "$top" on "$id")"
    [[ "$ans" == ok:* ]] && said+=("on $id ($how)")
  else
    jq -e '.tool_name == "Bash" and ((.tool_response.interrupted // false) | not)' >/dev/null 2>&1 <<<"$in" || return 0
    cmd="$(jq -r '.tool_input.command // empty' <<<"$in")"
    while read -r kind id; do
      case "$kind" in
        on)  ans="$(mark "$top" on "$id")";  [[ "$ans" == ok:* ]] && said+=("on $id") ;;
        off) if [[ -n "$id" ]]; then ans="$(mark "$top" off "$id")"; else ans="$(mark "$top" off)"; fi
             [[ "$ans" == ok:* ]] && said+=("off ${id:-every ticket}") ;;
        branch) b="$(git -C "$top" branch --show-current 2>/dev/null)"; id="$(ticket_of_branch "$b")"
             [[ -n "$id" ]] || continue
             ans="$(mark "$top" switch "$id")"; [[ "$ans" == ok:* ]] && said+=("on $id (branch $b)") ;;
      esac
    done < <(intents "$cmd")
  fi
  (( ${#said[@]} )) || return 0
  local IFS=';'; jq -n --arg e "$event" --arg c "Work marker written for you: ${said[*]}. Nothing to do; ledger-db.sh work on|off|switch still corrects it." \
    '{hookSpecificOutput: {hookEventName: $e, additionalContext: $c}}'
}

self_test() {
  local fails=0 d out
  _t() { if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1"; echo "       got  $2"; echo "       want $3"; fails=$((fails + 1)); fi; }
  _t "a claim marks on" "$(intents 'bash scripts/feature-ticket.sh claim fix_a_thing')" "on fix_a_thing"
  _t "a ledger claim too" "$(intents 'cd x && bash scripts/ledger-db.sh claim fix_a_thing')" "on fix_a_thing"
  _t "a release marks off that ticket" "$(intents 'bash scripts/ledger-db.sh release fix_a_thing done')" "off fix_a_thing"
  _t "a sign-off marks off" "$(intents 'bash scripts/ledger-db.sh sign-off fix_a_thing abc123 note')" "off fix_a_thing"
  _t "a hand-over marks off" "$(intents 'bash scripts/ledger-db.sh hand-over fix_a_thing Ada')" "off fix_a_thing"
  _t "handoff.sh marks off every ticket" "$(intents 'git checkout --detach origin/main; bash scripts/handoff.sh')" "off"
  _t "a checkout asks for the branch" "$(intents 'git checkout fix_a_thing-pt1')" "branch"
  _t "git -C <dir> switch too" "$(intents 'git -C ../t switch -c fix_a_thing-pt2')" "branch"
  _t "a checkout of a file is still a checkout (the branch decides)" "$(intents 'git checkout -- a.txt')" "branch"
  _t "a hand-written work marker is left alone" "$(intents 'bash scripts/ledger-db.sh work on x && bash scripts/feature-ticket.sh claim x')" ""
  _t "the words in an echo are not a claim" "$(intents 'echo claim fix_a_thing')" ""
  _t "git log is not a checkout" "$(intents 'git log --oneline -3')" ""
  _t "a pt branch names its ticket" "$(ticket_of_branch fix_a_thing-pt12)" fix_a_thing
  _t "a bare ticket branch too" "$(ticket_of_branch feat_x_y)" feat_x_y
  _t "main names none" "$(ticket_of_branch main)" ""
  _t "a ledger number branch names its number" "$(ticket_of_branch 6854)" 6854
  _t "a numbered pt branch names its number" "$(ticket_of_branch 6854-pt3)" 6854
  _t "a numbered hotfix branch names its number" "$(ticket_of_branch 6854-hotfix)" 6854
  _t "a numbered raise branch names its number" "$(ticket_of_branch 6854-raise)" 6854
  _t "a leading zero is no number" "$(ticket_of_branch 0123)" ""
  _t "a slash branch names none" "$(ticket_of_branch peter/try)" ""
  _t "a word with no underscore names none" "$(ticket_of_branch scratch)" ""
  # the real entry point against a throwaway repo and a stub ledger that records its calls
  d="$(mktemp -d)"
  git -C "$d" init -q -b main && git -C "$d" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 0
  mkdir -p "$d/scripts"
  printf '#!/usr/bin/env bash\necho "$*" >> %q/calls\ncase "$2" in on|switch) echo "ok:on:$3" ;; off) echo "ok:off${3:+:$3}" ;; esac\n' "$d" > "$d/scripts/ledger-db.sh"
  p() { jq -nc --arg c "$1" --arg w "$d" --arg a "${2:-}" '{session_id: "s", cwd: $w, tool_name: "Bash", tool_input: {command: $c}, tool_response: {stdout: ""}} + (if $a != "" then {agent_id: $a} else {} end)'; }
  out="$(p 'bash scripts/feature-ticket.sh claim fix_a_thing' | bash "$HERE/work-marker-hook.sh" PostToolUse)"
  _t "a claim writes work on through the tree's ledger-db.sh" "$(cat "$d/calls")" "work on fix_a_thing"
  _t "and tells the agent" "$(jq -r .hookSpecificOutput.additionalContext <<<"$out" | grep -o 'on fix_a_thing')" "on fix_a_thing"
  : > "$d/calls"; git -C "$d" switch -q -c fix_a_thing-pt1
  p 'git switch -c fix_a_thing-pt1' | bash "$HERE/work-marker-hook.sh" PostToolUse >/dev/null
  _t "a switch to a pt branch writes work switch to its ticket" "$(cat "$d/calls")" "work switch fix_a_thing"
  : > "$d/calls"
  out="$(jq -nc --arg w "$d" '{session_id: "s", cwd: $w, source: "startup"}' | bash "$HERE/work-marker-hook.sh" SessionStart)"
  _t "a session starting on that branch writes work on" "$(cat "$d/calls")" "work on fix_a_thing"
  _t "and says it is SessionStart context" "$(jq -r .hookSpecificOutput.hookEventName <<<"$out")" SessionStart
  : > "$d/calls"
  p 'bash scripts/handoff.sh' | bash "$HERE/work-marker-hook.sh" PostToolUse >/dev/null
  _t "handoff.sh writes work off, every ticket" "$(cat "$d/calls")" "work off"
  : > "$d/calls"
  out="$(p 'bash scripts/feature-ticket.sh claim fix_a_thing' agent-7 | bash "$HERE/work-marker-hook.sh" PostToolUse)"
  _t "a subagent's call writes nothing and says nothing" "$(cat "$d/calls")$out" ""
  out="$(p 'git log' | bash "$HERE/work-marker-hook.sh" PostToolUse)"
  _t "an unrelated command writes nothing and says nothing" "$(cat "$d/calls")$out" ""
  git -C "$d" switch -q main
  out="$(p 'git switch main' | bash "$HERE/work-marker-hook.sh" PostToolUse)"
  _t "a switch to main writes nothing (it marks nobody off)" "$(cat "$d/calls")$out" ""
  printf '{"agents":[{"name":"Boozer","role":"project-office"},{"name":"Ada","role":"developer"}]}' > "$d/agents.json"
  mkdir -p "$d/agents"; mv "$d/agents.json" "$d/agents/roster.json"
  : > "$d/calls"; git -C "$d" switch -q fix_a_thing-pt1
  out="$(jq -nc --arg w "$d" '{session_id: "s", cwd: $w}' | GIT_AUTHOR_NAME=Boozer bash "$HERE/work-marker-hook.sh" SessionStart)"
  _t "a project-office session on a ticket's branch writes nothing (it works in others' trees)" "$(cat "$d/calls")$out" ""
  out="$(jq -nc --arg w "$d" '{session_id: "s", cwd: $w}' | GIT_AUTHOR_NAME=ada bash "$HERE/work-marker-hook.sh" SessionStart)"
  _t "a developer's, any case, does" "$(cat "$d/calls")" "work on fix_a_thing"
  : > "$d/calls"; git -C "$d" switch -q --detach
  out="$(jq -nc --arg w "$d" '{session_id: "s", cwd: $w}' | GIT_AUTHOR_NAME= STRENGTH_TICKET=feat_spawned bash "$HERE/work-marker-hook.sh" SessionStart)"
  _t "a detached tree marks the ticket it was spawned for" "$(cat "$d/calls")" "work on feat_spawned"
  : > "$d/calls"; git -C "$d" switch -q fix_a_thing-pt1
  jq -nc --arg w "$d" '{session_id: "s", cwd: $w}' | GIT_AUTHOR_NAME= STRENGTH_TICKET=feat_spawned bash "$HERE/work-marker-hook.sh" SessionStart >/dev/null
  _t "a ticket's branch wins over the spawn ticket" "$(cat "$d/calls")" "work on fix_a_thing"
  : > "$d/calls"; git -C "$d" switch -q --detach
  out="$(jq -nc --arg w "$d" '{session_id: "s", cwd: $w}' | GIT_AUTHOR_NAME= STRENGTH_TICKET='x; rm -rf /' bash "$HERE/work-marker-hook.sh" SessionStart)"
  _t "a spawn ticket that is not an id is ignored" "$(cat "$d/calls")$out" ""
  rm -f "$d/scripts/ledger-db.sh"
  out="$(p 'bash scripts/feature-ticket.sh claim fix_a_thing' | bash "$HERE/work-marker-hook.sh" PostToolUse)"; rc=$?
  _t "a tree with no ledger-db.sh is skipped, exit 0" "$rc:$out" "0:"
  out="$(printf 'not json' | bash "$HERE/work-marker-hook.sh" PostToolUse)"; rc=$?
  _t "a payload it cannot read: exit 0, nothing said" "$rc:$out" "0:"
  rm -rf "$d"
  if (( fails == 0 )); then echo "work-marker-hook --self-test: ok"; else echo "work-marker-hook --self-test: $fails FAILED"; return 1; fi
}

if selftest_is_flag "${1:-}"; then self_test; exit $?; fi
run "${1:-PostToolUse}" || true
exit 0
