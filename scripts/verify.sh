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
if [[ "${1:-}" == --self-test ]]; then
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

# 1. Static.
# ── [0/3] The harness's own checks — always, whatever harness.env says ──────────────────────
# A check is invoked for REAL, after its own self-test: a step that only runs a gate's arms is not
# a gate (METHOD.md). The tier manifest that enrols every self-test arrives with the self-test
# child of the template epic; until then the harness's checks are listed here by hand.
step "[0/3] Harness — scripts/check-docs-markers-match-landed-children.sh"
bash scripts/check-docs-markers-match-landed-children.sh --self-test || fail "the marker gate's own self-test failed"
bash scripts/check-docs-markers-match-landed-children.sh || fail "a doc describes a landed child as still to come"
# the ticket store: the adapter + the verbs (a throwaway Postgres built from the baseline), the
# migration runner, and the lifecycle verbs (a stub remote and a stubbed ledger)
step "[0/3] Harness — the ledger's self-tests (ledger-db.sh, ledger-migrate.sh, feature-ticket.sh)"
bash scripts/ledger-db.sh --self-test       || fail "ledger-db.sh self-test failed (the verbs or the store adapter)"
bash scripts/ledger-migrate.sh --self-test  || fail "ledger-migrate.sh self-test failed"
bash scripts/feature-ticket.sh --self-test  || fail "feature-ticket.sh self-test failed (claim/release/exists)"
# the Jira store: the whole lifecycle against the fixture transport; and no Jira token in any tracked file
bash scripts/lib/ticket-store-jira.sh --self-test || fail "ticket-store-jira self-test failed (the Jira store behind the same verbs)"
bash scripts/check-no-committed-jira-token.sh --self-test || fail "the committed-token gate's own self-test failed"
bash scripts/check-no-committed-jira-token.sh || fail "a tracked file carries a Jira token — rotate it NOW, then remove it"
# identity and session entries: the gate's arms, onboarding, progress.sh; and the progress FREEZE
# invoked for REAL against this diff (not only its self-test — the seeded project once let four files
# onto main because the step ran the arms and never the gate)
bash scripts/lib/identity-gate.sh --self-test       || fail "identity-gate self-test failed"
bash scripts/agent-onboard.sh --self-test           || fail "agent-onboard self-test failed"
bash scripts/progress.sh --self-test                || fail "progress.sh self-test failed"
bash scripts/check-no-new-progress-files.sh --self-test || fail "the progress-freeze gate's own self-test failed"
bash scripts/check-no-new-progress-files.sh         || fail "a session-entry FILE was added under progress/ or PROGRESS.md — entries are ledger rows: bash scripts/progress.sh new"
# CI: the lanes, the seat, the subset, the gate — their arms; and the workflow's SHAPE for real
bash scripts/verify.sh --self-test                  || fail "verify.sh's own budget arms failed"
bash scripts/ci-stack-project.sh --self-test        || fail "ci-stack-project self-test failed"
bash scripts/ui-relevant-specs.sh --self-test       || fail "ui-relevant-specs self-test failed"
bash scripts/ci-merge-pr-base.sh --self-test        || fail "ci-merge-pr-base self-test failed"
bash scripts/ci-land-pr.sh --self-test              || fail "ci-land-pr self-test failed"
bash scripts/yield-to-repair.sh --self-test         || fail "yield-to-repair self-test failed"
bash scripts/check-verify-cost-budget.sh --self-test || fail "check-verify-cost-budget self-test failed"
bash scripts/check-merge-seat-count.sh --self-test  || fail "check-merge-seat-count self-test failed"
bash scripts/full-suite-gate.sh --self-test         || fail "full-suite-gate self-test failed (270 arms)"
bash scripts/check-workflow-shape.sh --self-test    || fail "the workflow-shape gate's own self-test failed"
bash scripts/check-workflow-shape.sh                || fail "the workflow no longer has the shape its header promises"
ok "harness checks green"

if (( UI_ONLY )); then
  step "[1/3]–[3/3] skipped — UI_ONLY=1 (the browser step alone)"
elif [[ -n "$VERIFY_STATIC" ]]; then
  step "[1/3] Static — $VERIFY_STATIC"; tier_start
  eval "$VERIFY_STATIC" || fail "static check failed"
  tier_end "static"
else
  step "[1/3] Static — skipped (VERIFY_STATIC unset)"
fi

# 2. Unit.
if (( UI_ONLY )); then :
elif [[ -n "$VERIFY_UNIT" ]]; then
  step "[2/3] Unit — $VERIFY_UNIT"; tier_start
  eval "$VERIFY_UNIT" || fail "unit tests failed"
  tier_end "unit"
else
  step "[2/3] Unit — skipped (VERIFY_UNIT unset)"
fi

# 3. End-to-end.
if (( UI_ONLY )); then :
elif [[ "$SKIP_E2E" == "1" || -z "$VERIFY_E2E" ]]; then
  step "[3/3] E2E — skipped"
else
  step "[3/3] E2E — $VERIFY_E2E"; tier_start
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
  tier_start
  eval "$VERIFY_UI" || fail "ui acceptance failed"
  tier_end "ui"
fi

dur=$(( $(date +%s) - start_ts ))
printf '\n\033[1;32mverify ok\033[0m  (%ss)\n' "$dur"
