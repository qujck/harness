#!/usr/bin/env bash
# scripts/handoff.sh — clean-state session-exit gate.
#
# L12: every session must leave a clean state, or the next session faces
# cascading failures. This script refuses to "pass" a session unless ALL of:
#
#   1. .agent/session.active exists (i.e. scripts/init.sh has run)
#   2. scripts/verify.sh exits 0
#   3. PROGRESS.md was modified this session (uncommitted, or a recent commit)
#   4. No debug artifacts in tracked changes (DEBUG_PATTERNS in harness.env)
#   5. ledger WIP nudge (live claims on the ledger — a warning, not a cap)
#   6. Git working tree is clean OR all changes are committed
#
# Usage:
#   bash scripts/handoff.sh                  # strict session-end check
#   bash scripts/handoff.sh --lenient        # warn-don't-block (Stop hook)
#   SKIP_VERIFY=1 bash scripts/handoff.sh    # skip verify (already ran it)
#   ALLOW_DIRTY=1 bash scripts/handoff.sh    # skip the clean-tree gate

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=/dev/null
[[ -f harness.env ]] && source harness.env
# Per-stream stack identity (COMPOSE_PROJECT_NAME, dc) for the strict-mode
# teardown below.
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/_stack.sh"

SKIP_VERIFY="${SKIP_VERIFY:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
PER_STREAM_STACKS="${PER_STREAM_STACKS:-0}"
DEBUG_PATTERNS="${DEBUG_PATTERNS:-console\.log debugger; //[[:space:]]*TODO Console\.WriteLine}"

LENIENT=0
for arg in "$@"; do
  case "$arg" in --lenient) LENIENT=1 ;; esac
done

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
LENIENT_HITS=0
fail() {
  if (( LENIENT == 1 )); then
    printf '   \033[1;33mwarn\033[0m %s\n' "$*" >&2
    LENIENT_HITS=$((LENIENT_HITS + 1))
    return 0
  fi
  printf '   \033[1;31mFAIL\033[0m %s\n' "$*" >&2
  exit 1
}

# 1. Session marker — was init.sh run? Skipped in CI (no bootstrap concept there).
step "[1/6] session marker"
if [[ "${CI:-}" == "true" ]]; then
  ok "skipped (CI)"
elif [[ ! -f .agent/session.active ]]; then
  fail "no .agent/session.active — run \`bash scripts/init.sh\` before handing off"
else
  ok ".agent/session.active present (started $(cat .agent/session.active 2>/dev/null || echo unknown))"
fi

# 2. verify.sh exits 0.
if [[ "$SKIP_VERIFY" == "1" ]]; then
  step "[2/6] verify — skipped (SKIP_VERIFY=1)"
else
  step "[2/6] verify — bash scripts/verify.sh"
  bash scripts/verify.sh || fail "verify failed; nothing else matters until this passes"
  ok "verify passed"
fi

# 3. A session entry exists under progress/ (uncommitted OR committed in the last 6 hours).
#
# ⚠ THIS USED TO REQUIRE PROGRESS.md, WHICH MADE EVERY SESSION TOUCH ONE SHARED FILE. Two agents
# finishing near each other then conflicted by construction, and the harness answered that with
# `merge=union` — which GitHub's PR merge IGNORES. See scripts/progress.sh for the measurement.
# One file per session has nothing to union.
PROGRESS_DIR="${PROGRESS_DIR:-progress}"
step "[3/6] a session entry was written under $PROGRESS_DIR/"
progress_new=""
# Uncommitted (staged or not) — the usual case: written moments ago, about to be committed.
progress_new="$(git status --porcelain -- "$PROGRESS_DIR" 2>/dev/null | head -1 || true)"
# …or committed recently, for a session that already landed its entry.
recent_progress_commit=$(git log --since='6 hours ago' --pretty=format:'%h' -- "$PROGRESS_DIR" 2>/dev/null | head -1 || true)
if [[ -n "$progress_new" ]]; then
  ok "a $PROGRESS_DIR/ entry is pending commit"
elif [[ -n "$recent_progress_commit" ]]; then
  ok "a $PROGRESS_DIR/ entry landed in recent commit $recent_progress_commit"
else
  fail "no session entry this session — run: bash scripts/progress.sh new \"<what happened>\""
fi

# 4. No debug artifacts in added lines (vs HEAD).
step "[4/6] No debug artifacts in changes"
read -ra _patterns <<< "$DEBUG_PATTERNS"
diff_output=$(git diff HEAD 2>/dev/null || true)
debug_hits=()
while IFS= read -r line; do
  [[ "$line" =~ ^\+[^+] ]] || continue   # only added lines
  body="${line:1}"
  for p in "${_patterns[@]}"; do
    [[ "$body" =~ $p ]] && debug_hits+=("$p")
  done
done <<< "$diff_output"
if (( ${#debug_hits[@]} > 0 )); then
  printf '   added lines matching:\n'
  printf '   - %s\n' "${debug_hits[@]}" | sort -u
  fail "remove debug artifacts before handing off"
fi
ok "no debug artifacts added"

# 5. WIP in the ledger — a nudge, not a hard cap. Multiple in_progress is fine
#    PROVIDED each runs in its OWN git worktree/clone; worktree isolation + the
#    depends_on ready-frontier are the safety, not a count.
step "[5/6] ledger WIP (parallel-OK)"
# the ledger's live claims (rows in_progress), not a file count
_claims="$(bash scripts/ledger-db.sh board 2>/dev/null | awk -F'|' '$3!="-" && $3!=""' || true)"
in_progress="$(printf '%s' "$_claims" | grep -c . || true)"
if (( in_progress > 1 )); then
  printf '%s\n' "$_claims" | awk -F'|' '{ printf "   - %s (%s)\n", $1, $3 }'
  warn "$in_progress claims live on the ledger — fine PROVIDED each runs in its OWN git worktree (worktree isolation + depends_on are the safety, not a count)"
else
  ok "$in_progress claim(s) live on the ledger"
fi

# 6. Working tree clean OR commits made.
step "[6/6] Git tree state"
if [[ "$ALLOW_DIRTY" == "1" ]]; then
  warn "ALLOW_DIRTY=1 — skipping clean-tree check"
else
  if ! git diff --quiet || ! git diff --cached --quiet; then
    git status --short
    fail "uncommitted changes — commit them or run with ALLOW_DIRTY=1"
  fi
  ok "tree clean"
fi

# 7. Tear down THIS worktree's per-stream stack — STRICT mode + PER_STREAM_STACKS=1
#    only. The Stop hook runs with --lenient and must NEVER reach this (or the env
#    would die after every turn). CI is excluded (its runner is already ephemeral).
#    KEEP_STACK=1 keeps it alive for a human who wants it to survive a clean
#    handoff. Only reached when every check above passed (a failed check exits
#    earlier, leaving the env up to fix).
if [[ "$PER_STREAM_STACKS" == "1" ]] && (( LENIENT == 0 )) \
    && [[ "${CI:-}" != "true" ]] && [[ "${KEEP_STACK:-0}" != "1" ]]; then
  step "Tear down per-stream stack ($COMPOSE_PROJECT_NAME) — docker compose down -v"
  if command -v docker >/dev/null 2>&1; then
    dc down -v --remove-orphans >/dev/null 2>&1 || warn "teardown reported an issue (already down?)"
    rm -f "$REPO_ROOT/.agent/env" "$REPO_ROOT/.agent/session.active"
    ok "stack '$COMPOSE_PROJECT_NAME' down; .agent/env + session.active cleared"
  else
    warn "docker not available — skipped teardown"
  fi
fi

if (( LENIENT == 1 )); then
  if (( LENIENT_HITS == 0 )); then
    printf '\n\033[1;32mhandoff ok — clean to clock out\033[0m\n'
  else
    printf '\n\033[1;33mhandoff: %d gap(s) — see warnings above (lenient mode, not blocking)\033[0m\n' "$LENIENT_HITS" >&2
  fi
  exit 0
fi
printf '\n\033[1;32mhandoff ok — clean to clock out\033[0m\n'
