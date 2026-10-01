#!/usr/bin/env bash
# check-verify-cost-budget.sh — did the required check cost more than it is supposed to?
#   (infra_playwright_leaves_the_required_check_and_a_gate_keeps_it_out)
#
#   VERIFY_ELAPSED_SECONDS=540 bash scripts/check-verify-cost-budget.sh
#   bash scripts/check-verify-cost-budget.sh --self-test
#
# ⚠ THE ELAPSED TIME ARRIVES AS AN ENVIRONMENT VARIABLE, NOT AN ARGUMENT, and that is not a style
# choice. lib/selftest-flag.sh is the shared flag contract and it is explicitly "for a script that
# takes nothing but the flag" — it exits 2 on any positional argument. Hand-rolling a flag check to
# get around that is refused by check-selftest-flag-contract.sh, and rightly: a mistyped self-test
# flag that falls through and runs the real action is the false green that contract exists to stop.
#
# ── ⚠ WHY THIS EXISTS: A 29-MINUTE VERIFY AND A 9-MINUTE ONE LOOK IDENTICAL ─────────────────────
#
# From outside, the required check is ONE step called "The full house gate". It is green either
# way. That is why the required check drifted to 60-72% Playwright and stayed there for a month
# with nobody raising it — nothing was wrong, it was just slow, and slow has no colour.
#
# So the cost gets a number and the number gets checked.
#
# ── THE BUDGET, AND WHO CHOSE IT ────────────────────────────────────────────────────────────────
#
# TWO budgets, one per arm, because route decides which population a run belongs to and ci.yml
# passes the matching one: 21 minutes for a run with no browser subset, 40 for one with it.
# Re-derived by Cara on 2026-09-29, shape (a) — "the BUDGET is wrong" — approved by the PO.
# (fix_the_ci_cost_budget_is_below_what_verify_costs_and_the_step_is_advisory_so_it_never_surfaces)
#
# METHOD, so nobody re-measures differently and gets a different number:
#   * 419 `verify` jobs with conclusion == success, created 2026-09-13T11:16Z .. 2026-09-29T04:02Z.
#     Excluded: 287 cancelled, 251 failure, 41 null, 2 skipped — a cancelled job reports a plausible
#     duration for work it never did.
#   * ⚠ THE WINDOW IS 16 DAYS, NOT THE 28 ASKED FOR: the runs listing caps a filtered query at 1000
#     runs, and 1000 reached back only to 09-13. Nothing green landed 09-23..09-26.
#   * Elapsed = the stamp step's completion to this step's start — the SAME interval this check
#     measures, not the job's start/end (which adds checkout, merge and stack setup).
#   * Arm = whether the step "Playwright — the specs that cover the surfaces this PR touched" concluded
#     success (browser) or skipped (no browser).
#
#     no browser  n=340  min  9.2m  p50 15.9m  p90 19.7m  p95 20.7m  max 26.2m
#     browser     n= 79  min  5.9m  p50 31.9m  p90 37.2m  p95 39.4m  max 43.9m
#
# ⚠ THE OLD 14 AND 30 WERE BOTH WRONG, AND BY THE SAME MECHANISM: they were set from a population
# that no longer exists. Ed's 2026-09-04 derivation (26 runs, no-browser median 9.0m, a clean 4.5m gap
# between the populations, 14 at its midpoint) was right for its day. By 09-13 the non-browser
# median was 16.0m and it has sat at 14-17m every day since — flat, not growing, with the house gate
# the whole of it — so 238 of 340 green runs (70%) read OVER, and 43 of 79 browser runs (54%) read  [measured 2026-09-29]
# OVER at 30. A budget exceeded by most green runs is not an alarm, it is a constant.
#
# ⚠ THE POPULATIONS NOW OVERLAP (a browser run can be 5.9m, a non-browser one 26.2m), so there is no
# gap to put a midpoint in. The rule instead is the p95 of green runs, rounded UP to a whole minute:
# an OVER means this run is in the slowest ~5% (2026-09-29 window) of what verify has been costing — worth a look —
# rather than an ordinary day. ⚠ AND THE ORDER MATTERS: this number had to be corrected BEFORE the
# OVER went to the PR thread, or the comment would have landed on 70% of PRs (2026-09-29) and taught everyone to
# scroll past it. Override for a run with CI_VERIFY_BUDGET_MINUTES.
#
# ⚠ WHEN TO RE-DERIVE: when the OVER comment becomes common on ordinary PRs, the cost has moved again
# — re-run the method above and say which shape it is. Do not nudge the number to make comments stop.
#
# ── ⚠ IT WARNS, IT DOES NOT FAIL, AND THAT IS A DECISION ────────────────────────────────────────
#
# A slow run is not a broken run, and failing a green PR because the box was busy would teach people
# to re-run rather than to look — the cost is load-shaped, and blocking on it punishes an author for
# seat contention. But a soft signal nobody receives is worthless: until 2026-09-29 this printed only
# into the job summary, of a job that PASSED, so nobody opened it (the `no map row` diagnosis died
# the same way). An OVER now ALSO writes a PR comment (VERIFY_COST_COMMENT_FILE, posted by ci.yml),
# because the PR thread is where the author already is.
#
# Exit: 0 within budget · 1 over budget (the caller decides what to do about it) · 2 bad argument
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/selftest-flag.sh"

DEFAULT_BUDGET_MINUTES=21

# budget_verdict <elapsed-seconds> <budget-minutes> -> within | OVER | unmeasurable
#
# ⚠ AN UNREADABLE ELAPSED TIME IS `unmeasurable`, NEVER `within`. A missing start stamp is the
# obvious way this check silently stops checking, and "I could not tell" must not render as "fine".
budget_verdict() {
  local elapsed="${1-}" budget="${2-}"
  [[ "$elapsed" =~ ^[0-9]+$ ]] || { printf 'unmeasurable\n'; return; }
  [[ "$budget"  =~ ^[0-9]+$ ]] || { printf 'unmeasurable\n'; return; }
  if (( elapsed > budget * 60 )); then printf 'OVER\n'; else printf 'within\n'; fi
}

# over_comment <mins> <budget> <arm> <run> -> the PR comment an OVER posts
#
# ⚠ THIS IS THE HALF OF THE ROUTING THE TICKET WAS ABOUT. The job summary already carried the OVER
# and nobody opened it: the job PASSED, so nobody had a reason to. The PR thread is where the author
# already is. It names the arm it was judged on, because a first cut that scored every run at 14m
# made browser PRs look far worse than they were, and the reader needs to know which budget spoke.
over_comment() {
  local mins="$1" budget="$2" arm="$3" run="$4"
  printf '### ⚠ verify cost: %sm against a %sm budget (%s)\n\n' "$mins" "$budget" "$arm"
  printf 'This is a **warning, not a failure** — the check is green and nothing here blocks the merge.\n'
  printf 'A slow run is not a broken one, and the box is shared, so one OVER is a draw, not a trend.\n\n'
  printf 'It is here because a green check and an over-budget verify look identical from outside, and\n'
  printf 'for a month this line printed only into a job nobody opened. If your diff added a gate, a\n'
  printf 'suite or a stack restart, this is the number that says so. The budget, and how it was\n'
  printf 'derived, is in `scripts/check-verify-cost-budget.sh`.\n\n'
  printf '<sub>run %s · measured from the start stamp to the cost step, the same interval the budget was derived from</sub>\n' "$run"
}

self_test() {
  local fails=0
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
         else printf '  FAIL %s — expected %s, got %s\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }

  echo "self-test: budget_verdict — the 2026-09-13..29 green populations, per arm"
  _t 'no-browser: the fastest green run is within'    within "$(budget_verdict 552 21)"    # 9.2m
  _t 'no-browser: the median green run is within'     within "$(budget_verdict 954 21)"    # 15.9m
  _t '⚠ no-browser: p95 (20.7m) is within'            within "$(budget_verdict 1242 21)"   # 20.7m
  _t '⚠ REGRESSION: a 16.5m run, OVER at the old 14, is within' within "$(budget_verdict 990 21)"
  _t 'no-browser: the slowest green run is OVER'      OVER   "$(budget_verdict 1572 21)"   # 26.2m
  _t 'browser: the median green run is within'        within "$(budget_verdict 1914 40)"   # 31.9m
  _t '⚠ browser: p95 (39.4m) is within'               within "$(budget_verdict 2364 40)"   # 39.4m
  _t 'browser: the slowest green run is OVER'         OVER   "$(budget_verdict 2634 40)"   # 43.9m
  _t '⚠ ARMS: a 25m run is OVER without a browser subset…' OVER   "$(budget_verdict 1500 21)"
  _t '⚠ …and within with one'                         within "$(budget_verdict 1500 40)"

  echo "self-test: the boundary is exact and exclusive"
  _t 'exactly on budget is within, not over'    within       "$(budget_verdict 840 14)"
  _t 'one second past budget is OVER'           OVER         "$(budget_verdict 841 14)"

  echo "self-test: ⚠ an unreadable input is unmeasurable, never 'within'"
  _t 'a missing elapsed time cannot pass'       unmeasurable "$(budget_verdict '' 14)"
  _t 'a non-numeric elapsed time cannot pass'   unmeasurable "$(budget_verdict 'abc' 14)"
  _t 'a negative-looking value cannot pass'     unmeasurable "$(budget_verdict '-5' 14)"
  _t 'a missing budget cannot pass'             unmeasurable "$(budget_verdict 600 '')"

  echo "self-test: ⚠ the PR comment names the minutes, the budget, the ARM and the run"
  local body; body="$(over_comment 16.5 14 no-browser 123456)"
  _t 'the comment carries the minutes and budget' yes "$([[ "$body" == *'16.5m against a 14m budget'* ]] && echo yes || echo no)"
  _t 'the comment names the arm it was judged on' yes "$([[ "$body" == *'(no-browser)'* ]] && echo yes || echo no)"
  _t 'the comment names its run'                  yes "$([[ "$body" == *'run 123456'* ]] && echo yes || echo no)"
  _t '⚠ the comment says it does not block'       yes "$([[ "$body" == *'not a failure'* ]] && echo yes || echo no)"

  echo "self-test: ⚠ ONLY an OVER writes the comment — driven through the real entry point"
  local cf; cf="$(mktemp)"; trap 'rm -f "$cf"' RETURN
  : > "$cf"
  VERIFY_ELAPSED_SECONDS=600 CI_VERIFY_BUDGET_MINUTES=21 VERIFY_COST_COMMENT_FILE="$cf" \
    GITHUB_STEP_SUMMARY=/dev/null bash "$0" >/dev/null 2>&1
  _t 'a run within budget writes no comment'      empty "$([[ -s "$cf" ]] && echo written || echo empty)"
  VERIFY_ELAPSED_SECONDS=1500 CI_VERIFY_BUDGET_MINUTES=21 VERIFY_COST_COMMENT_FILE="$cf" VERIFY_COST_ARM=no-browser \
    GITHUB_STEP_SUMMARY=/dev/null bash "$0" >/dev/null 2>&1
  _t '⚠ a run OVER budget writes the comment'     written "$([[ -s "$cf" ]] && echo written || echo empty)"
  : > "$cf"
  VERIFY_ELAPSED_SECONDS=1500 CI_VERIFY_BUDGET_MINUTES=40 VERIFY_COST_COMMENT_FILE="$cf" VERIFY_COST_ARM=browser \
    GITHUB_STEP_SUMMARY=/dev/null bash "$0" >/dev/null 2>&1
  _t '⚠ NEGATIVE ARM: the same run judged at the browser budget writes none' empty "$([[ -s "$cf" ]] && echo written || echo empty)"

  echo "self-test: unknown arguments are rejected"
  if bash "$0" --slef-test >/dev/null 2>&1; then
    printf '  FAIL --slef-test was accepted\n'; fails=$((fails+1))
  else printf '  ok   --slef-test is rejected rather than silently ignored\n'; fi

  [[ "$fails" -eq 0 ]] || { printf '\n%d self-test failure(s)\n' "$fails" >&2; return 1; }
  echo "check-verify-cost-budget: selftest ok"
}
selftest_requested "$@" && { self_test; exit $?; }

ELAPSED="${VERIFY_ELAPSED_SECONDS-}"
BUDGET="${CI_VERIFY_BUDGET_MINUTES:-$DEFAULT_BUDGET_MINUTES}"
[[ -n "$ELAPSED" ]] || {
  # ⚠ NOT exit 0. A missing stamp is the obvious way this check silently stops checking, and it must
  # not render as "within budget".
  echo "verify cost: UNMEASURABLE — VERIFY_ELAPSED_SECONDS is unset. Not reporting this as within budget." >&2
  exit 1; }

verdict="$(budget_verdict "$ELAPSED" "$BUDGET")"
mins="$(awk -v s="$ELAPSED" 'BEGIN{ if (s ~ /^[0-9]+$/) printf "%.1f", s/60; else printf "?" }')"

case "$verdict" in
  within)
    printf 'verify cost: %sm, budget %sm — within\n' "$mins" "$BUDGET" ;;
  OVER)
    printf '::warning::the required check took %sm against a %sm budget. That is the slowest ~5%% of green runs for this arm: a gate may have grown teeth, a suite returned, or the seat was contended. See scripts/check-verify-cost-budget.sh for how the budget was derived.\n' "$mins" "$BUDGET"
    printf 'verify cost: %sm, budget %sm — OVER\n' "$mins" "$BUDGET"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      {
        printf '### ⚠ Required check over its cost budget\n\n'
        printf '**%sm** against a **%sm** budget.\n\n' "$mins" "$BUDGET"
        printf 'A 29-minute verify and a 9-minute one look identical from outside — both are one green\n'
        printf 'step. That is how this check drifted to 60-72%% Playwright for a month. This line is the\n'
        printf 'only thing that makes the cost visible without opening a job.\n'
      } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
    fi
    # The caller posts this onto the PR. Written, not posted, so this script stays free of the network
    # and the self-test can drive the real entry point. (fix_the_ci_cost_budget_is_below_what_verify_costs_and_the_step_is_advisory_so_it_never_surfaces)
    if [[ -n "${VERIFY_COST_COMMENT_FILE:-}" ]]; then
      over_comment "$mins" "$BUDGET" "${VERIFY_COST_ARM:-unstated arm}" "${VERIFY_COST_RUN:-?}" \
        > "$VERIFY_COST_COMMENT_FILE" 2>/dev/null || true
    fi
    exit 1 ;;
  *)
    printf 'verify cost: UNMEASURABLE (elapsed=%q budget=%q) — not reporting this as within budget\n' "$ELAPSED" "$BUDGET"
    exit 1 ;;
esac
