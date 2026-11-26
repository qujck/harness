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
#     (the branch the command names, in whichever tree it runs; never the session tree's own branch)
#   release | sign-off | hand-over <id>   (ledger-db.sh, feature-ticket.sh release)   work off <id>
#   handoff.sh                (the end of a session)                        work off           (every ticket)
# and at SessionStart (a spawn, a resume, after a compaction) a tree whose branch is <id> or <id>-pt<N>: work on <id>;
# on any other branch or a detached head, the ticket agent-spawn.sh named in HARNESS_TICKET (STRENGTH_TICKET from
# strength's own spawner, before it called this harness's), if it set one.
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
  branch_targets "$c" | sed 's/^/branch /'
  return 0
}

# branch_targets <command> -> the branch each git checkout/switch in it moves to, one per line, as written   (pure)
#   Read from the command, never from a tree: an agent with many worktrees runs `cd <other tree> && git switch X`,
#   and the hook's cwd is the session's own tree, whose branch is another ticket's (owner's team, 2026-11-26: Ada's
#   marker kept going back to her home tree's branch). A checkout of files (`--`, or paths after the branch), a
#   detach, `-` and a branch from a variable move to nothing it can name, so they mark nothing.
branch_targets() {
  local rest="$1" re="(^|[;&|[:space:]\"'(])git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(checkout|switch)([[:space:]].*)?$"
  local w t want stop; local -; set -f          # a * in the command is a word, not a glob
  while [[ "$rest" =~ $re ]]; do
    rest="${BASH_REMATCH[4]}"; t=""; want=""; stop=""
    for w in $rest; do
      [[ "$w" =~ ^[\;\&\|\)\"\'] || "$w" =~ ^[0-9]*[\<\>] ]] && break   # the command's end, or a redirect
      [[ "$w" =~ [\;\&\|\)\"\']+$ ]] && { stop=1; w="${w%%[;&|)\"\']*}"; }
      if [[ -n "$want" ]]; then t="$w"; break                     # -b <new> [<start point>]: the new one
      elif [[ -n "$t" ]]; then t=""; break                      # a second word: paths, so files
      else case "$w" in
        --) break ;;
        --detach|-d|-) break ;;
        -b|-B|-c|-C|--orphan|--create|--force-create) want=1 ;;
        -*) ;;
        *) t="$w" ;;
      esac; fi
      [[ -n "$stop" ]] && break
    done
    [[ -n "$t" && "$t" != \$* ]] && printf '%s\n' "$t"
  done
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
    local spawned="${HARNESS_TICKET:-${STRENGTH_TICKET:-}}"
    if [[ -z "$id" && "$spawned" =~ ^#?[A-Za-z0-9_.-]+$ ]]; then id="${spawned#\#}"; how="the ticket this session was spawned for"; fi
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
        branch) b="$id"; id="$(ticket_of_branch "$b")"
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
  _t "a checkout names the branch it moves to" "$(intents 'git checkout fix_a_thing-pt1')" "branch fix_a_thing-pt1"
  _t "git -C <dir> switch -c too" "$(intents 'git -C ../t switch -c fix_a_thing-pt2')" "branch fix_a_thing-pt2"
  _t "a switch in another tree names its own branch, not the session's (Ada, 2026-11-26)" \
    "$(intents 'taskset -c 30-31 bash -c "cd /home/x/strength-ada-5367 && git switch -q 7112-pt1 && git log -1"')" "branch 7112-pt1"
  _t "  and so does a cd; checkout; with the branch last on its line" "$(intents 'cd $W; git checkout -q 5367-pt1; git status')" "branch 5367-pt1"
  _t "  two moves, each named in order" "$(intents 'git switch a_b-pt1 && git -C ../y checkout -B c_d-pt2')" "branch a_b-pt1
branch c_d-pt2"
  _t "  a new branch from a start point names the new one" "$(intents 'git checkout -q --no-track -b 7013-pt1 origin/main 2>&1')" "branch 7013-pt1"
  _t "  a redirect after the branch is not a path" "$(intents 'git checkout 5141-pt1 2>/dev/null; git switch -q x_y-pt1 >/dev/null')" "branch 5141-pt1
branch x_y-pt1"
  _t "a checkout of files names nothing" "$(intents 'git checkout -- a.txt')" ""
  _t "  nor files from a branch" "$(intents 'git checkout fix_a_thing-pt1 a.txt b.txt')" ""
  _t "  nor a detach, the last branch, or a variable" "$(intents 'git switch --detach x_y; git checkout -; git switch $B')" ""
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
  p 'cd /elsewhere/other-tree && git switch -q 7112-pt1' | bash "$HERE/work-marker-hook.sh" PostToolUse >/dev/null
  _t "  a switch in another tree writes its own ticket, not this tree's branch" "$(cat "$d/calls")" "work switch 7112"
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
  : > "$d/calls"
  out="$(jq -nc --arg w "$d" '{session_id: "s", cwd: $w}' | GIT_AUTHOR_NAME= HARNESS_TICKET=feat_harness bash "$HERE/work-marker-hook.sh" SessionStart)"
  _t "  and so does harness agent-spawn.sh's HARNESS_TICKET" "$(cat "$d/calls")" "work on feat_harness"
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
