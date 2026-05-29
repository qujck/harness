#!/usr/bin/env bash
# .claude/hooks/stop-check.sh — fired by Claude Code on Stop (every assistant turn).
#
# Stop hooks fire on every turn, not session-end, so we MUST be lenient. We run
# handoff.sh in --lenient mode (warns, does not block). Strict enforcement is
# done by the git pre-commit hook on actual commits.
#
# We short-circuit when there's nothing worth checking — clean tree — so quiet
# conversations don't get noisy.

set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Quick skip: clean working tree → nothing to hand off.
if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
  exit 0
fi

# Lenient mode, skip verify (too slow for every turn — the git pre-commit hook
# runs verify on actual commits).
SKIP_VERIFY=1 ALLOW_DIRTY=1 bash scripts/handoff.sh --lenient >&2 || true
exit 0
