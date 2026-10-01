#!/usr/bin/env bash
# scripts/ops-alerts-settle.sh — the settle tick: announce recoveries that have held, and sweep
# unit-failed:<unit> conditions whose unit is active again (a unit that recovered without anyone
# calling `recovered` would otherwise stay FAILING for ever). Run by @@PROJECT@@-alerts-settle.timer.
# (feat_harness_ops_alerts_are_conditions_with_one_email_on_failing_and_one_on_recovery)
#
#   bash scripts/ops-alerts-settle.sh              # one tick
#   bash scripts/ops-alerts-settle.sh --self-test
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/selftest-flag.sh"
. "$HERE/lib/ops-alert.sh"

# unit_healthy_verdict <ActiveState> -> healthy | failed | unknown   (pure)
unit_healthy_verdict() { case "${1-}" in active|activating|inactive) echo healthy ;; failed) echo failed ;; *) echo unknown ;; esac; }

sweep_unit_failed_keys() { # for each open unit-failed:<unit> key, a healthy unit is a recovery reading
  local k unit st
  while IFS= read -r k; do
    [[ "$k" == unit-failed:* ]] || continue
    unit="${k#unit-failed:}"
    st="$(systemctl --user show "$unit" -p ActiveState --value 2>/dev/null || true)"
    [[ -n "$st" ]] || st="$(systemctl show "$unit" -p ActiveState --value 2>/dev/null || true)"
    case "$(unit_healthy_verdict "$st")" in
      healthy) ops_alert_condition "$k" recovered "systemd unit $unit is healthy again" "ActiveState=$st read by the settle tick on $(hostname)" || true ;;
      *) : ;;   # still failed, or could not read: the condition stands (never cleared on an unreadable)
    esac
  done < <(ops_alert_open_keys)
}

if selftest_is_flag "${1:-}"; then
  f=0; _t() { [[ "$2" == "$3" ]] && printf '  ok    %s\n' "$1" || { printf '  FAIL  %s (want %s got %s)\n' "$1" "$2" "$3"; f=1; }; }
  _t "active is healthy"            healthy "$(unit_healthy_verdict active)"
  _t "inactive (a oneshot between runs) is healthy" healthy "$(unit_healthy_verdict inactive)"
  _t "failed is failed"             failed  "$(unit_healthy_verdict failed)"
  _t "an unreadable state is unknown — never cleared" unknown "$(unit_healthy_verdict '')"
  (( f == 0 )) && { echo "ops-alerts-settle: self-test ok"; exit 0; } || { echo "ops-alerts-settle: self-test FAILED" >&2; exit 1; }
fi
ops_alert_settle_due
sweep_unit_failed_keys
