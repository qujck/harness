#!/usr/bin/env bash
# team/team-start.sh — start the team after a boot, or only the named agents: the team page's ▶ and a standing
# agent's Start run it.
#
#   bash team/team-start.sh                    start the whole team
#   bash team/team-start.sh --only NAME ...    start only these (repeat --only): those running when the page last
#                                              stopped the team, or one standing agent
#   bash team/team-start.sh --self-test
#
# A PLACEHOLDER, to be wired up on the workstation that runs the team. The page runs it detached, through the
# owner's login shell, and keeps what it prints in ~/.local/state/<project>/team-start.log; once the delivery lead
# is up and idle the page tells it to start the day. Wired up, it starts each agent's tmux session (named as
# team/agent-spawn.sh names them, <project>-<name>), resuming the agent's newest conversation, and leaves alone a
# session that is already running. Until then it says so and exits 3, and nothing starts.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"

selftest() {
  local fails=0 out rc
  check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
  out=$(bash "$_here/team-start.sh" --only Ada --only Lea 2>&1); rc=$?
  check "unwired, it starts nothing and exits 3" "$rc" 3
  check "  naming who was asked for" "$(grep -c -- '--only Ada --only Lea' <<<"$out")" 1
  bash "$_here/team-start.sh" --only >/dev/null 2>&1; check "--only needs a name" "$?" 2
  bash "$_here/team-start.sh" --sole Ada >/dev/null 2>&1; check "an unknown argument is refused" "$?" 2
  [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; return 1; }
}

only=()
while [ $# -gt 0 ]; do
  if selftest_is_flag "$1"; then selftest; exit $?; fi
  selftest_reject_typo "$1"
  case "$1" in
    --only) [ -n "${2:-}" ] || { echo "team-start: --only needs a name" >&2; exit 2; }; only+=("$2"); shift 2 ;;
    *) echo "team-start: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

asked="the whole team"; [ ${#only[@]} -eq 0 ] || asked="${only[*]/#/--only }"
echo "team-start: not wired up on this workstation yet (asked for: $asked); see team/team-start.sh" >&2
exit 3
