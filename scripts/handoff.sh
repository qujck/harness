#!/usr/bin/env bash
# scripts/handoff.sh — clean-state session-exit gate.
#
# Lec 12: every session must leave a clean state, or the next session faces
# cascading failures. This script refuses to "pass" a session unless ALL of:
#
#   1. .agent/session.active exists (i.e. scripts/init.sh has run)
#   2. scripts/verify.sh exits 0
#   3. PROGRESS.md was modified this session (uncommitted, or a recent commit)
#   4. No debug artifacts in tracked changes (DEBUG_PATTERNS in harness.env)
#   5. feature_list.json has at most one feature with status="in_progress"
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

SKIP_VERIFY="${SKIP_VERIFY:-0}"
ALLOW_DIRTY="${ALLOW_DIRTY:-0}"
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

# 3. PROGRESS.md touched (uncommitted edits OR a commit in the last 6 hours).
step "[3/6] PROGRESS.md touched this session"
progress_dirty=0
git diff --quiet -- PROGRESS.md 2>/dev/null || progress_dirty=1
git diff --cached --quiet -- PROGRESS.md 2>/dev/null || progress_dirty=1
recent_progress_commit=$(git log --since='6 hours ago' --pretty=format:'%h' -- PROGRESS.md 2>/dev/null | head -1 || true)
if (( progress_dirty == 1 )); then
  ok "PROGRESS.md has uncommitted edits"
elif [[ -n "$recent_progress_commit" ]]; then
  ok "PROGRESS.md updated in recent commit $recent_progress_commit"
else
  fail "PROGRESS.md was not touched this session — update it before handing off"
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

# 5. WIP=1 in feature_list.json.
step "[5/6] feature_list.json WIP=1"
in_progress=$(jq '[.features[] | select(.status == "in_progress")] | length' feature_list.json 2>/dev/null || echo 0)
if (( in_progress > 1 )); then
  jq -r '.features[] | select(.status == "in_progress") | "   - \(.id)"' feature_list.json
  fail "$in_progress features marked in_progress; only one is allowed"
fi
ok "$in_progress feature(s) in_progress"

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

if (( LENIENT == 1 )); then
  if (( LENIENT_HITS == 0 )); then
    printf '\n\033[1;32mhandoff ok — clean to clock out\033[0m\n'
  else
    printf '\n\033[1;33mhandoff: %d gap(s) — see warnings above (lenient mode, not blocking)\033[0m\n' "$LENIENT_HITS" >&2
  fi
  exit 0
fi
printf '\n\033[1;32mhandoff ok — clean to clock out\033[0m\n'
