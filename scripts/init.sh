#!/usr/bin/env bash
# scripts/init.sh — bootstrap contract for a fresh agent session.
#
# L06 of the harness-engineering framework: initialization is its own phase,
# not mixed with implementation. Idempotent. Brings the stack up, waits on the
# health endpoint, installs the git pre-commit hook, marks the session active,
# and prints the next ready feature from the ledger.
#
# Two stack modes (set in harness.env):
#   PER_STREAM_STACKS=0  (default)  one stack via UP_CMD + HEALTH_URL.
#   PER_STREAM_STACKS=1             a per-worktree docker-compose stack with
#                                   kernel-assigned ports, discovered into
#                                   .agent/env (LOCAL parallel — several worktrees
#                                   on one machine). The distributed parallel-safe
#                                   workflow (per-ticket ledger, ready-frontier,
#                                   union-merge) is on by default in both modes.
#
# Configure UP_CMD / HEALTH_URL / REQUIRED_TOOLS (solo) or PER_STREAM_STACKS /
# STACK_HEALTH_* (per-stream) in harness.env.
#
# Usage:
#   bash scripts/init.sh           # clock in
#   bash scripts/init.sh --reset   # per-stream only: docker compose down -v first

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=/dev/null
[[ -f harness.env ]] && source harness.env
# Per-stream stack + feature-ledger helpers (dc, stack_port, features_live_json).
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/_stack.sh"

HEALTH_URL="${HEALTH_URL:-}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
UP_CMD="${UP_CMD:-}"
REQUIRED_TOOLS="${REQUIRED_TOOLS:-}"
PER_STREAM_STACKS="${PER_STREAM_STACKS:-0}"

RESET=0
for arg in "$@"; do case "$arg" in --reset) RESET=1 ;; esac; done

step() { printf '\n\033[1;36m==>\033[0m %s\n' "$*"; }
ok()   { printf '   \033[1;32mok\033[0m %s\n' "$*"; }
warn() { printf '   \033[1;33m!\033[0m %s\n' "$*"; }
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
if [[ "$PER_STREAM_STACKS" == "1" ]]; then
  # ── Local parallel: a per-worktree docker-compose stack with discovered ports ──
  command -v docker >/dev/null || fail "docker required for PER_STREAM_STACKS=1"
  docker compose version >/dev/null 2>&1 || fail "docker compose v2 plugin required for PER_STREAM_STACKS=1"

  if (( RESET == 1 )); then
    step "Reset — docker compose down -v (project: $COMPOSE_PROJECT_NAME)"
    dc down -v --remove-orphans || true
    rm -f "$REPO_ROOT/.agent/env"
    ok "stack '$COMPOSE_PROJECT_NAME' wiped"
  fi

  step "Bringing per-stream stack up (docker compose -p $COMPOSE_PROJECT_NAME up -d --build)"
  export HOST_UID="${HOST_UID:-$(id -u)}"
  export HOST_GID="${HOST_GID:-$(id -g)}"
  dc up -d --build
  ok "compose up -d completed"

  # Discover the kernel-assigned host port for the health service.
  svc="${STACK_HEALTH_SERVICE:-}"; cport="${STACK_HEALTH_CONTAINER_PORT:-}"; hpath="${STACK_HEALTH_PATH:-/}"
  [[ -n "$svc" && -n "$cport" ]] || fail "set STACK_HEALTH_SERVICE + STACK_HEALTH_CONTAINER_PORT in harness.env for PER_STREAM_STACKS=1"
  step "Discovering published host port for $svc:$cport"
  hport=""
  for _ in $(seq 1 20); do hport="$(stack_port "$svc" "$cport")"; [[ -n "$hport" ]] && break; sleep 0.5; done
  [[ -n "$hport" ]] || fail "could not discover the $svc host port (is it up? try: docker compose -p $COMPOSE_PROJECT_NAME ps)"
  STACK_URL="http://localhost:$hport"
  HEALTH_URL="$STACK_URL$hpath"

  # Persist .agent/env NOW (before the health wait) so a slow/failed boot still
  # leaves the discovered coordinates for debugging + for the other scripts.
  mkdir -p "$REPO_ROOT/.agent"
  cat > "$REPO_ROOT/.agent/env" <<ENV
# Written by scripts/init.sh — per-stream stack coordinates. Sourced by _stack.sh.
COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME
STACK_URL=$STACK_URL
HEALTH_URL=$HEALTH_URL
ENV
  ok "wrote .agent/env (stack=$STACK_URL)"
else
  # ── Single shared stack via UP_CMD (default; local parallel off) ──
  if [[ -n "$UP_CMD" ]]; then
    step "Bringing stack up ($UP_CMD)"
    eval "$UP_CMD"
    ok "stack up"
  fi
fi

# 4. Wait for the health endpoint (HEALTH_URL is the discovered one in per-stream).
if [[ -n "$HEALTH_URL" ]]; then
  step "Waiting for $HEALTH_URL (timeout ${HEALTH_TIMEOUT}s)"
  deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
  while true; do
    if curl --silent --fail --max-time 2 "$HEALTH_URL" >/dev/null 2>&1; then
      ok "healthy at $HEALTH_URL"
      break
    fi
    if (( $(date +%s) > deadline )); then
      [[ "$PER_STREAM_STACKS" == "1" ]] && dc logs --tail=80 "${STACK_HEALTH_SERVICE:-}" 2>/dev/null || true
      fail "not healthy within ${HEALTH_TIMEOUT}s"
    fi
    sleep 2
  done
fi

# 5. Install the git pre-commit hook from the versioned source. Copy (not
#    symlink) so it survives different filesystems / Windows clones. Uses
#    git rev-parse so the hooks dir resolves correctly inside a worktree too.
step "Git pre-commit hook"
HOOK_SRC="$REPO_ROOT/scripts/git-hooks/pre-commit"
if [[ -f "$HOOK_SRC" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
  HOOK_DST="$(git rev-parse --git-path hooks/pre-commit)"
  if [[ ! -f "$HOOK_DST" ]] || ! cmp -s "$HOOK_SRC" "$HOOK_DST"; then
    mkdir -p "$(dirname "$HOOK_DST")"
    cp "$HOOK_SRC" "$HOOK_DST"
    chmod +x "$HOOK_DST"
    ok "installed pre-commit hook -> $HOOK_DST"
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

# 7. Bootstrap-contract summary (L06: can start, test, see progress, pick up next).
step "Bootstrap contract"
[[ "$PER_STREAM_STACKS" == "1" ]] && echo "   stream            : $COMPOSE_PROJECT_NAME"
echo "   can verify        : bash scripts/verify.sh"
echo "   can see progress  : cat PROGRESS.md"
[[ -n "$HEALTH_URL" ]] && echo "   health            : $HEALTH_URL"
echo "   can pick up next  : see below"

# 8. Next feature on the READY FRONTIER: highest priority among entries that are
#    not terminal (passing/wont_do) AND whose depends_on are all "passing". An
#    entry with no depends_on (the solo case) is always ready, so this degrades
#    to plain priority order when dependencies aren't used.
step "Next feature (highest priority on the ready frontier)"
NEXT=$(features_live_json | jq -r '
  (.features // []) as $all
  | ($all | map({(.id): .status}) | add // {}) as $st
  | [ $all[]
      | select(.status != "passing" and .status != "wont_do")
      | select((.depends_on // []) | all(. as $d | $st[$d] == "passing")) ]
  | sort_by(.priority)
  | .[0]
  | if . == null then "NONE_READY"
    else "  id      : \(.id)\n  status  : \(.status)\n  priority: \(.priority)\n  title   : \(.title)\n  verify  : \(.verification_command // "(not set)")"
    end
' 2>/dev/null || echo "NONE_READY")

if [[ "$NEXT" == "NONE_READY" ]]; then
  echo "   No ready feature — all entries are passing/wont_do, or the rest is dependency-blocked."
  echo "   Add one with status=not_started, or unblock a dependency."
else
  echo "$NEXT"
fi

step "Init complete"
