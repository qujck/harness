#!/usr/bin/env bash
# team/team-paused.sh — exit 0 once the team is wound down, 1 while it is not. After the team page asks the delivery
# lead to wind the team down, its ⏻ pulses a square until this says so and no agent is busy, then shows ▶.
#
#   bash team/team-paused.sh
#   bash team/team-paused.sh --self-test
#
# A PLACEHOLDER, to be wired up on the workstation that runs the team: it reports whether the file
# ~/.local/state/<project>/team.paused exists, which the lead's wind-down is to create and its start of the day to
# remove. Wire it to whatever pauses the team's nudging there.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"

selftest() {
  local fails=0 T
  T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
  HOME=$T HARNESS_PROJECT=p bash "$_here/team-paused.sh"; check "not paused without the file" "$?" 1
  mkdir -p "$T/.local/state/p" && touch "$T/.local/state/p/team.paused"
  HOME=$T HARNESS_PROJECT=p bash "$_here/team-paused.sh"; check "paused with it" "$?" 0
  bash "$_here/team-paused.sh" --now >/dev/null 2>&1; check "an unknown argument is refused" "$?" 2
  [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; return 1; }
}
if selftest_requested "$@"; then selftest; exit $?; fi

project=${HARNESS_PROJECT:-$(basename "$(cd "$_here/.." && pwd)")}
[ -f "$HOME/.local/state/$project/team.paused" ]
