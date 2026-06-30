#!/usr/bin/env bash
# scripts/verify.sh — Definition of Done.
#
# Lec 9: an agent cannot self-grade. Lec 10: only end-to-end testing proves
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

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
fail() { printf '   \033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

start_ts=$(date +%s)

# 1. Static.
if [[ -n "$VERIFY_STATIC" ]]; then
  step "[1/3] Static — $VERIFY_STATIC"
  eval "$VERIFY_STATIC" || fail "static check failed"
  ok "static clean"
else
  step "[1/3] Static — skipped (VERIFY_STATIC unset)"
fi

# 2. Unit.
if [[ -n "$VERIFY_UNIT" ]]; then
  step "[2/3] Unit — $VERIFY_UNIT"
  eval "$VERIFY_UNIT" || fail "unit tests failed"
  ok "unit tests passed"
else
  step "[2/3] Unit — skipped (VERIFY_UNIT unset)"
fi

# 3. End-to-end.
if [[ "$SKIP_E2E" == "1" || -z "$VERIFY_E2E" ]]; then
  step "[3/3] E2E — skipped"
else
  step "[3/3] E2E — $VERIFY_E2E"
  # Bring the stack up if a health endpoint is configured and unreachable.
  if [[ -n "$HEALTH_URL" ]] && ! curl --silent --fail --max-time 3 "$HEALTH_URL" >/dev/null 2>&1; then
    echo "   stack not reachable — bringing it up via scripts/init.sh"
    bash scripts/init.sh
  fi
  eval "$VERIFY_E2E" || fail "e2e tests failed"
  ok "e2e passed"
fi

# 4. UI acceptance (opt-in).
if [[ "${RUN_UI:-0}" == "1" && -n "$VERIFY_UI" ]]; then
  step "[4/4] UI acceptance — $VERIFY_UI"
  eval "$VERIFY_UI" || fail "ui acceptance failed"
  ok "ui acceptance passed"
fi

dur=$(( $(date +%s) - start_ts ))
printf '\n\033[1;32mverify ok\033[0m  (%ss)\n' "$dur"
