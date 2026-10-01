#!/usr/bin/env bash
# scripts/verify.sh — Definition of Done.
#
# L09: an agent cannot self-grade. L10: only end-to-end testing proves
# component-boundary defects don't exist. This script is the single command
# whose exit code decides whether a feature is "passing".
#
# Three layers, run in order, stop on first failure:
#   1. VERIFY_STATIC   (lint / typecheck / compile)
#   2. VERIFY_UNIT     (unit tests)
#   3. VERIFY_E2E      (end-to-end, against a running stack)
# Plus an opt-in UI layer (VERIFY_UI, gated by RUN_UI=1). Configure all of
# these in harness.env; a BLANK command skips its layer.
#
# Env:
#   SKIP_E2E=1   skip the e2e layer (CI may run it in a separate job)
#   RUN_UI=1     additionally run the VERIFY_UI command

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=/dev/null
[[ -f harness.env ]] && source harness.env
# Per-stream helpers: in PER_STREAM_STACKS=1 mode this re-loads .agent/env so
# HEALTH_URL below is the discovered per-worktree port, not the static default.
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/_stack.sh"

VERIFY_STATIC="${VERIFY_STATIC:-}"
VERIFY_UNIT="${VERIFY_UNIT:-}"
VERIFY_E2E="${VERIFY_E2E:-}"
VERIFY_UI="${VERIFY_UI:-}"
HEALTH_URL="${HEALTH_URL:-}"
SKIP_E2E="${SKIP_E2E:-0}"
# The tiered runner: static → unit → e2e → a GUARDED browser step. Each tier is timed against
# VERIFY_STEP_BUDGET_S (harness.env; 0 = unbudgeted): a tier over its budget FAILS the run, because a
# required check that grows unnoticed is how a five-minute gate becomes a forty-minute one (the seeded
# project measured 60–72% of its check in one tier before it split the suite). UI_ONLY=1 runs only the
# browser step (CI's second step); UI_GREP narrows it to the subset scripts/ui-relevant-specs.sh chose;
# VERIFY_FULL=1 ignores the subset and runs everything (the hourly run, a repair PR, a red main).
VERIFY_STEP_BUDGET_S="${VERIFY_STEP_BUDGET_S:-0}"
UI_ONLY="${UI_ONLY:-0}"; UI_GREP="${UI_GREP:-}"; VERIFY_FULL="${VERIFY_FULL:-}"
_tier_t0=0
tier_start() { _tier_t0=$(date +%s); }
# tier_budget_verdict <elapsed s> <budget s> -> within | over | unbudgeted   (pure)
tier_budget_verdict() { local e="${1:-0}" b="${2:-0}"; [[ "$b" =~ ^[0-9]+$ && "$b" -gt 0 ]] || { echo unbudgeted; return; }; [[ "$e" =~ ^[0-9]+$ ]] || { echo over; return; }; (( e > b )) && echo over || echo within; }
tier_end() { local name="$1" e=$(( $(date +%s) - _tier_t0 )); case "$(tier_budget_verdict "$e" "$VERIFY_STEP_BUDGET_S")" in
  over) fail "$name took ${e}s, over the per-step budget of ${VERIFY_STEP_BUDGET_S}s (VERIFY_STEP_BUDGET_S) — a check that grows unnoticed is the defect, not the slowness" ;;
  within) ok "$name: ${e}s (budget ${VERIFY_STEP_BUDGET_S}s)" ;;
  *) ok "$name: ${e}s" ;; esac; }
. "$REPO_ROOT/scripts/lib/selftest-flag.sh"
selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  f=0; _t() { [[ "$2" == "$3" ]] && printf '  ok    %s\n' "$1" || { printf '  FAIL  %s (want %s got %s)\n' "$1" "$2" "$3"; f=1; }; }
  _t "budget 0 is unbudgeted"            unbudgeted "$(tier_budget_verdict 999 0)"
  _t "under budget is within"            within     "$(tier_budget_verdict 299 300)"
  _t "at budget is within"               within     "$(tier_budget_verdict 300 300)"
  _t "over budget is over"               over       "$(tier_budget_verdict 301 300)"
  _t "garbage elapsed is over, never a pass" over    "$(tier_budget_verdict x 300)"
  (( f == 0 )) && { echo "verify --self-test: ok"; exit 0; } || { echo "verify --self-test: FAILED" >&2; exit 1; }
fi

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
fail() { printf '   \033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

start_ts=$(date +%s)
# ── the stage report: which stages RAN and which never started because an earlier one stopped the run
# (scripts/verify-stages.sh; the full-suite gate renders it: "Playwright: NOT RUN — stopped at static checks").
# VERIFY_PLANT_RED=<stage> plants a red at that stage so verify-stages.sh --self-test can drive a REAL run.
. "$REPO_ROOT/scripts/verify-stages.sh"
vs_init "${VERIFY_STAGES_FILE:-${RUNNER_TEMP:-$REPO_ROOT/.agent}/verify-stages.txt}"
_vs_on_exit() { local rc=$?; declare -F vs_finish >/dev/null 2>&1 && { vs_finish "$rc" || true; }; }
trap _vs_on_exit EXIT

# 1. Static.
# ── [0/3] The harness's own checks — always, whatever harness.env says ──────────────────────
# A check is invoked for REAL, after its own self-test: a step that only runs a gate's arms is not
# a gate (METHOD.md). The tier manifest that enrols every self-test arrives with the self-test
# child of the template epic; until then the harness's checks are listed here by hand.
if [[ -n "${VERIFY_PLANT_RED:-}" ]]; then
  step "[0/3] Harness — skipped: VERIFY_PLANT_RED=$VERIFY_PLANT_RED (a planted run proves the stage report, not the harness checks)"
else
step "[0/3] Harness — scripts/check-docs-markers-match-landed-children.sh"
bash scripts/check-docs-markers-match-landed-children.sh || fail "a doc describes a landed child as still to come"
# the ticket store: the adapter + the verbs (a throwaway Postgres built from the baseline), the
# migration runner, and the lifecycle verbs (a stub remote and a stubbed ledger)
# ── every self-test the manifest assigns to this tier, and NOTHING hand-listed ─────────────────
# scripts/selftest-tiers.txt is the one list; `check-selftests-are-invoked.sh --list` prints its verify
# rows and this step runs EXACTLY those, failing on an empty list (a step that passes having run
# nothing is the defect). A self-test that needs a stack is the `stack` tier (run with VERIFY_STACK=1).
step "[0/3] Harness — the self-test tier (scripts/selftest-tiers.txt via check-selftests-are-invoked.sh --list)"
_st_list="$(bash scripts/check-selftests-are-invoked.sh --list 2>/dev/null)"
_st_n="$(printf '%s\n' "$_st_list" | awk 'NF' | wc -l)"
(( _st_n >= 1 )) || fail "the self-test tier list is EMPTY — this step would pass having run nothing"
_st_ran=0
while IFS= read -r _s; do
  [[ -n "$_s" ]] || continue
  case "$_s" in
    *.py) python3 "$_s" --self-test >/dev/null 2>&1 || fail "self-test failed: $_s (run: python3 $_s --self-test)" ;;
    *)    bash "$_s" --self-test >/dev/null 2>&1 || fail "self-test failed: $_s (run: bash $_s --self-test)" ;;
  esac
  _st_ran=$((_st_ran+1))
done <<<"$_st_list"
ok "$_st_ran of $_st_n self-tests in the verify tier passed (the floor is 1)"
if [[ "${VERIFY_STACK:-0}" == 1 ]]; then
  step "[0/3] Harness — the stack tier (needs docker)"
  while IFS= read -r _s; do [[ -n "$_s" ]] || continue; bash "$_s" --self-test >/dev/null 2>&1 || fail "stack-tier self-test failed: $_s"; done <<<"$(bash scripts/check-selftests-are-invoked.sh --list-stack 2>/dev/null)"
  ok "stack tier passed"
fi
# ── the gates themselves, invoked for REAL (a self-test is not an invocation: check-steps-invoke-their-scripts.sh) ──
step "[0/3] Harness — scripts/check-selftests-are-invoked.sh"
bash scripts/check-selftests-are-invoked.sh || fail "a self-test is invoked by nothing and no reason is recorded"
step "[0/3] Harness — scripts/check-selftest-flag-contract.sh"
bash scripts/check-selftest-flag-contract.sh || fail "a script parses its self-test flag by hand"
step "[0/3] Harness — scripts/check-steps-invoke-their-scripts.sh"
bash scripts/check-steps-invoke-their-scripts.sh || fail "a verify step promises a gate it only self-tests"
step "[0/3] Harness — scripts/check-no-committed-jira-token.sh"
bash scripts/check-no-committed-jira-token.sh || fail "a tracked file carries a Jira token — rotate it NOW, then remove it"
step "[0/3] Harness — scripts/check-no-new-progress-files.sh"
bash scripts/check-no-new-progress-files.sh || fail "a session-entry FILE was added under progress/ or PROGRESS.md — entries are ledger rows: bash scripts/progress.sh new"
step "[0/3] Harness — scripts/check-context-is-never-a-reason-to-do-less.sh"
bash scripts/check-context-is-never-a-reason-to-do-less.sh || fail "a document cites context as a reason to do less"
step "[0/3] Harness — scripts/check-workflow-shape.sh"
bash scripts/check-workflow-shape.sh || fail "the workflow no longer has the shape its header promises"
ok "harness checks green"
fi

if (( UI_ONLY )); then
  step "[1/3]–[3/3] skipped — UI_ONLY=1 (the browser step alone)"
  vs_skip static 'UI_ONLY=1'; vs_skip unit 'UI_ONLY=1'; vs_skip api-e2e 'UI_ONLY=1'
elif [[ -n "$VERIFY_STATIC" || -n "${VERIFY_PLANT_RED:-}" ]]; then
  step "[1/3] Static — ${VERIFY_STATIC:-(nothing configured)}"; tier_start; vs_begin static
  [[ "${VERIFY_PLANT_RED:-}" == static ]] && fail "planted red (VERIFY_PLANT_RED=static) — scripts/verify-stages.sh --self-test drives the stage report through a real run"
  [[ -n "$VERIFY_STATIC" ]] && { eval "$VERIFY_STATIC" || fail "static check failed"; }
  tier_end "static"
else
  vs_skip static 'VERIFY_STATIC unset'
  step "[1/3] Static — skipped (VERIFY_STATIC unset)"
fi

# 2. Unit.
if (( UI_ONLY )); then :
elif [[ -n "$VERIFY_UNIT" ]]; then
  step "[2/3] Unit — $VERIFY_UNIT"; tier_start; vs_begin unit
  [[ "${VERIFY_PLANT_RED:-}" == unit ]] && fail "planted red (VERIFY_PLANT_RED=unit)"
  eval "$VERIFY_UNIT" || fail "unit tests failed"
  tier_end "unit"
else
  vs_skip unit 'VERIFY_UNIT unset'
  step "[2/3] Unit — skipped (VERIFY_UNIT unset)"
fi

# 3. End-to-end.
if (( UI_ONLY )); then :
elif [[ "$SKIP_E2E" == "1" || -z "$VERIFY_E2E" ]]; then
  step "[3/3] E2E — skipped"; vs_skip api-e2e "$([[ "$SKIP_E2E" == 1 ]] && echo 'SKIP_E2E=1' || echo 'VERIFY_E2E unset')"
else
  step "[3/3] E2E — $VERIFY_E2E"; tier_start; vs_begin api-e2e
  [[ "${VERIFY_PLANT_RED:-}" == api-e2e ]] && fail "planted red (VERIFY_PLANT_RED=api-e2e)"
  # Bring the stack up if a health endpoint is configured and unreachable.
  if [[ -n "$HEALTH_URL" ]] && ! curl --silent --fail --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    echo "   stack not reachable — bringing it up via scripts/init.sh"
    bash scripts/init.sh
  fi
  eval "$VERIFY_E2E" || fail "e2e tests failed"
  tier_end "e2e"
fi

# 4. UI acceptance (opt-in).
# ── [4/4] the GUARDED browser step: only with RUN_UI=1; the subset from UI_GREP unless VERIFY_FULL=1 ──
if [[ "${RUN_UI:-0}" == "1" && -n "$VERIFY_UI" ]]; then
  if [[ -n "$VERIFY_FULL" ]]; then step "[4/4] UI — the WHOLE suite (VERIFY_FULL=1) — $VERIFY_UI"; export UI_GREP=""
  elif [[ -n "$UI_GREP" ]]; then step "[4/4] UI — the subset for this diff (UI_GREP='$UI_GREP') — $VERIFY_UI"; export UI_GREP
  else step "[4/4] UI — $VERIFY_UI"; fi
  tier_start; vs_begin playwright
  eval "$VERIFY_UI" || fail "ui acceptance failed"
  tier_end "ui"
else
  vs_skip playwright "$([[ "${RUN_UI:-0}" == 1 ]] && echo 'VERIFY_UI unset' || echo 'RUN_UI not set (the guarded browser step)')"
fi

dur=$(( $(date +%s) - start_ts ))
printf '\n\033[1;32mverify ok\033[0m  (%ss)\n' "$dur"
