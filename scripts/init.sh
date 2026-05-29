#!/usr/bin/env bash
# scripts/init.sh — bootstrap contract for a fresh agent session.
#
# Lec 6 of the harness-engineering framework: initialization is its own phase,
# not mixed with implementation. Idempotent. Brings the stack up, waits on the
# health endpoint, installs the git pre-commit hook, marks the session active,
# and prints the next non-passing feature from feature_list.json.
#
# Configure UP_CMD / HEALTH_URL / REQUIRED_TOOLS in harness.env.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=/dev/null
[[ -f harness.env ]] && source harness.env

HEALTH_URL="${HEALTH_URL:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
UP_CMD="${UP_CMD:-}"
REQUIRED_TOOLS="${REQUIRED_TOOLS:-}"

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
fail() { printf '   \033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

# 1. Sanity — required tools (jq is a hard harness dependency).
step "Checking required tools"
if ! command -v jq >/dev/null; then
  echo "   jq not found — installing via apt (will prompt for sudo)"
  if command -v apt-get >/dev/null; then
    sudo apt-get update -qq && sudo apt-get install -y jq
  else
    fail "jq missing and no apt-get available — install jq manually"
  fi
  command -v jq >/dev/null || fail "jq still not on PATH after install"
fi
for tool in $REQUIRED_TOOLS; do
  command -v "$tool" >/dev/null || fail "$tool not found (REQUIRED_TOOLS in harness.env)"
done
ok "jq${REQUIRED_TOOLS:+, $REQUIRED_TOOLS} present"

# 2. .env present (if the project ships a .env.example template).
if [[ -f .env.example ]]; then
  step "Checking .env"
  if [[ ! -f .env ]]; then
    cp .env.example .env
    ok "copied .env.example -> .env (development defaults)"
  else
    ok ".env present"
  fi
fi

# 3. Bring the stack up.
if [[ -n "$UP_CMD" ]]; then
  step "Bringing stack up ($UP_CMD)"
  eval "$UP_CMD"
  ok "stack up"
fi

# 4. Wait for the health endpoint.
if [[ -n "$HEALTH_URL" ]]; then
  step "Waiting for $HEALTH_URL (timeout ${HEALTH_TIMEOUT}s)"
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while true; do
    if curl --silent --fail --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
      ok "healthy at $HEALTH_URL"
      break
    fi
    if (( $(date +%s) > deadline )); then
      fail "not healthy within ${HEALTH_TIMEOUT}s"
    fi
    sleep 2
  done
fi

# 5. Install the git pre-commit hook from the versioned source. Copy (not
#    symlink) so it survives different filesystems / Windows clones.
step "Git pre-commit hook"
HOOK_SRC="$REPO_ROOT/scripts/git-hooks/pre-commit"
HOOK_DST="$REPO_ROOT/.git/hooks/pre-commit"
if [[ -f "$HOOK_SRC" && -d "$REPO_ROOT/.git" ]]; then
  if [[ ! -f "$HOOK_DST" ]] || ! cmp -s "$HOOK_SRC" "$HOOK_DST"; then
    cp "$HOOK_SRC" "$HOOK_DST"
    chmod +x "$HOOK_DST"
    ok "installed .git/hooks/pre-commit"
  else
    ok "pre-commit hook up to date"
  fi
else
  echo "   (skipped: no .git dir or hook source missing)"
fi

# 6. Mark the session active. handoff.sh requires this marker.
step "Session marker"
mkdir -p "$REPO_ROOT/.agent"
date -u +"%Y-%m-%dT%H:%M:%SZ" > "$REPO_ROOT/.agent/session.active"
ok "wrote .agent/session.active"

# 7. Bootstrap-contract summary (lec 6: can start, test, see progress, pick up next).
step "Bootstrap contract"
echo "   can start         : $UP_CMD"
echo "   can verify        : bash scripts/verify.sh"
echo "   can see progress  : cat PROGRESS.md"
echo "   can pick up next  : see below"

# 8. Next non-passing feature. Both "passing" and "wont_do" are terminal.
step "Next feature (highest priority, status not in {passing, wont_do})"
NEXT=$(jq -r '
  [.features[] | select(.status != "passing" and .status != "wont_do")]
  | sort_by(.priority)
  | .[0]
  | if . == null then "ALL_PASSING"
    else "  id      : \(.id)\n  status  : \(.status)\n  priority: \(.priority)\n  title   : \(.title)\n  verify  : \(.verification_command // "(not set)")"
    end
' feature_list.json 2>/dev/null || echo "ALL_PASSING")

if [[ "$NEXT" == "ALL_PASSING" ]]; then
  echo "   No non-passing features. Add one with status=not_started before starting work."
else
  echo "$NEXT"
fi

step "Init complete"
