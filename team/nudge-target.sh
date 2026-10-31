#!/usr/bin/env bash
# team/nudge-target.sh — who the waiting-agents nudger wakes about an idle team: the delivery lead, the head of
# testing, or nobody. The owner, 2026-10-31: "I'd like the nudger changed to either be nudging you or Vera or be off.
# No one else."
#
#   bash team/nudge-target.sh                      # prints lead, testing or off
#   bash team/nudge-target.sh lead|testing|off     # sets it; the mod reads it on its next poll, no restart
#   bash team/nudge-target.sh --self-test
#
# The switch is one word in the file `nudge-target` beside the nudger's log and pause file: one level above
# CONTEXT_DIR, else ~/.local/state/<HARNESS_PROJECT>/ (claude-code/waiting-agents/README.md). No file is `lead`.
# Setting it needs HARNESS_PROJECT or CONTEXT_DIR in the environment, as agents-budget.sh's writes do: run from
# the harness checkout the project would default to "harness", and a word written there is read by no nudger.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"

selftest() {
  local fails=0 T out
  T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  unset CONTEXT_DIR   # the caller's would point every case at its own state directory
  check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
  out=$(HOME=$T HARNESS_PROJECT=p bash "$_here/nudge-target.sh"); check "no file reads lead" "$out" lead
  HOME=$T HARNESS_PROJECT=p bash "$_here/nudge-target.sh" testing >/dev/null; check "set exits 0" "$?" 0
  check "the word is in the file the mod reads" "$(cat "$T/.local/state/p/nudge-target" 2>/dev/null)" testing
  out=$(HOME=$T HARNESS_PROJECT=p bash "$_here/nudge-target.sh"); check "and reads back" "$out" testing
  mkdir -p "$T/ctx/context"
  HOME=$T CONTEXT_DIR=$T/ctx/context bash "$_here/nudge-target.sh" off >/dev/null
  check "CONTEXT_DIR puts it beside the context directory" "$(cat "$T/ctx/nudge-target" 2>/dev/null)" off
  HOME=$T HARNESS_PROJECT=p bash "$_here/nudge-target.sh" vera >/dev/null 2>&1; check "an unknown word is refused" "$?" 2
  check "and nothing is written" "$(cat "$T/.local/state/p/nudge-target")" testing
  (unset HARNESS_PROJECT CONTEXT_DIR; HOME=$T bash "$_here/nudge-target.sh" off >/dev/null 2>&1); check "a set with no project is refused" "$?" 2
  [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; return 1; }
}
# selftest_is_flag, not selftest_requested: the latter exits on any further argument, and this script takes a word.
if selftest_is_flag "${1:-}"; then selftest; exit $?; fi
selftest_reject_typo "$@"

if [ -n "${CONTEXT_DIR:-}" ]; then dir=$(dirname "$CONTEXT_DIR")
else dir="$HOME/.local/state/${HARNESS_PROJECT:-$(basename "$(cd "$_here/.." && pwd)")}"; fi
file="$dir/nudge-target"

case "${1:-}" in
  '') word=$({ tr -d '[:space:]' < "$file"; } 2>/dev/null); echo "${word:-lead}" ;;
  lead|testing|off)
    [ -n "${HARNESS_PROJECT:-}${CONTEXT_DIR:-}" ] \
      || { echo "nudge-target: set HARNESS_PROJECT (or CONTEXT_DIR) so the word lands where the nudger reads it" >&2; exit 2; }
    mkdir -p "$dir" && printf '%s\n' "$1" > "$file" && echo "nudges: $1 ($file)" ;;
  *) echo "usage: nudge-target.sh [lead|testing|off | --self-test]" >&2; exit 2 ;;
esac
