#!/usr/bin/env bash
# scripts/check-merge-seat-count.sh — the merge seat is N runners per seat label, and only the runner
# REGISTRY can say so. (feat_harness_ci_routes_a_pr_by_diff_runs_a_test_subset_and_gates_merges_on_the_hourly_full_suite)
#
#   bash scripts/check-merge-seat-count.sh              # reads the registry (gh api); exit 0 ok · 1 seats wrong · 2 CANNOT TELL
#   bash scripts/check-merge-seat-count.sh --self-test
#
# GitHub runs one job per RUNNER. "One verify on the merge seat at a time" therefore holds exactly
# while the number of registered runners carrying MERGE_SEAT_LABEL equals what harness.env DECLARES
# (MERGE_SEAT_RUNNERS, default 1). The seeded project asserted "exactly one" and then ran a second
# seat on purpose — the probe alerted on its own trial for a week. So this asserts the DECLARED count,
# not a constant (the precedent: its row fix_the_seat_probe_alerts_on_a_label_shared_by_two_runners…).
# The route and canary labels are lanes, not seats: carried by any number of runners by design.
# An empty registry read is CANNOT TELL (exit 2), never "zero seats".
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/harness-env.sh"
MERGE_SEAT_LABEL="${MERGE_SEAT_LABEL:-forge-box}"
MERGE_SEAT_RUNNERS="${MERGE_SEAT_RUNNERS:-1}"

# seat_counts_verdict <lines: name<TAB>label,label,…> <label> <expected> -> "ok <label>=<n>" | "seats <label>=<n>(<names>) expected <e>" | "unreadable"
seat_counts_verdict() {
  local lines="${1-}" label="${2:?}" expected="${3:?}" n names
  [[ -n "$(printf '%s' "$lines" | tr -d '[:space:]')" ]] || { printf 'unreadable\n'; return 0; }
  [[ "$expected" =~ ^[0-9]+$ ]] || { printf 'unreadable\n'; return 0; }
  names="$(printf '%s\n' "$lines" | awk -F'\t' -v l="$label" '{ m=split($2, a, ","); for (i=1;i<=m;i++) if (a[i]==l) { printf "%s%s", (o++ ? "," : ""), $1 } }')"
  n="$(printf '%s\n' "$lines" | awk -F'\t' -v l="$label" '{ m=split($2, a, ","); for (i=1;i<=m;i++) if (a[i]==l) c++ } END { print c+0 }')"
  if (( n == expected )); then printf 'ok %s=%s\n' "$label" "$n"; else printf 'seats %s=%s(%s) expected %s\n' "$label" "$n" "${names:-none}" "$expected"; fi
}

if selftest_is_flag "${1:-}"; then
  fails=0
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; fails=1; fi; }
  one=$'forge-box\tself-hosted,forge-box\ncanary\tself-hosted,canary-box'
  two=$'forge-box\tself-hosted,forge-box\nfast-box\tself-hosted,forge-box,fast-box\ncanary\tself-hosted,canary-box'
  _t "one runner with the seat label, one declared: ok"                 "ok forge-box=1" "$(seat_counts_verdict "$one" forge-box 1)"
  _t "two runners sharing the label, ONE declared: seats wrong, both named" "seats forge-box=2(forge-box,fast-box) expected 1" "$(seat_counts_verdict "$two" forge-box 1)"
  _t "two runners sharing the label, TWO declared (a second seat on purpose): ok" "ok forge-box=2" "$(seat_counts_verdict "$two" forge-box 2)"
  _t "no runner with the label: seats wrong, 'none' named"              "seats forge-box-2=0(none) expected 1" "$(seat_counts_verdict "$one" forge-box-2 1)"
  _t "an empty registry read is unreadable, never zero"                  unreadable "$(seat_counts_verdict '' forge-box 1)"
  _t "a non-numeric declared count is unreadable"                        unreadable "$(seat_counts_verdict "$one" forge-box many)"
  _t "the live path reads the declared count from harness.env (MERGE_SEAT_RUNNERS)" 1 "$(awk '/^MERGE_SEAT_RUNNERS="\$\{MERGE_SEAT_RUNNERS:-1\}"$/{n++} END{print n+0}' "${BASH_SOURCE[0]}")"
  (( fails == 0 )) && echo "check-merge-seat-count: self-test ok" || { echo "check-merge-seat-count: self-test FAILED" >&2; exit 1; }
  exit 0
fi

[[ -n "${HARNESS_REPO:-}" ]] || { echo "check-merge-seat-count: CANNOT TELL — HARNESS_REPO is not set in harness.env" >&2; exit 2; }
lines="$(gh api "repos/$HARNESS_REPO/actions/runners?per_page=100" --jq '.runners[] | "\(.name)\t\([.labels[].name]|join(","))"' 2>/dev/null || true)"
v="$(seat_counts_verdict "$lines" "$MERGE_SEAT_LABEL" "$MERGE_SEAT_RUNNERS")"
case "$v" in
  unreadable) echo "check-merge-seat-count: CANNOT TELL — the runner registry of $HARNESS_REPO could not be read (not a zero)" >&2; exit 2 ;;
  ok*)        echo "check-merge-seat-count: $v — $MERGE_SEAT_RUNNERS run(s) on the merge seat at a time, as declared"; exit 0 ;;
  *)          echo "check-merge-seat-count: ⚠ $v — GitHub runs one job per runner, so the seat no longer serialises as harness.env declares (fix the registry or the declaration)" >&2; exit 1 ;;
esac
