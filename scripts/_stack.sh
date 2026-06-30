# scripts/_stack.sh — OPTIONAL per-stream docker-stack helpers (LOCAL parallel).
# SOURCE this file (do not execute it).
#
# L02, the Environment subsystem: a reproducible, ISOLATED stack. Per worktree
# it's also the operational substrate that lets several agents run in parallel on
# one machine without corrupting each other (the multi-agent operation L11
# assumes). Across separate clones you're already isolated and don't need this.
#
# It always loads the feature-ledger helpers (scripts/_features.sh), so every
# harness script that sources it gets features_live_json regardless of mode.
#
# The per-stream stack machinery only activates when PER_STREAM_STACKS=1 in
# harness.env. In that mode every git worktree gets its OWN docker-compose
# project (name derived from the worktree dir) with kernel-assigned host ports,
# so two worktrees can never collide on a port or a container. init.sh discovers
# the ports and writes .agent/env; sourcing this file re-loads that file so
# verify.sh / handoff.sh reach the SAME stack — HEALTH_URL becomes the discovered
# one, overriding the static harness.env value.
#
# Requires a docker-compose stack. For non-compose projects leave
# PER_STREAM_STACKS=0 and the harness uses UP_CMD / HEALTH_URL as usual.
#
# Provides (PER_STREAM_STACKS=1 only): $COMPOSE_PROJECT_NAME, dc, stack_port, refresh_stack_env.
# Provides (always):                    $REPO_ROOT, stack_default_proj, features_live_json.

if [[ -z "${REPO_ROOT:-}" ]]; then
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi

# Feature-ledger helpers — always available, both modes.
if [[ -f "$REPO_ROOT/scripts/_features.sh" ]]; then
  # shellcheck source=/dev/null
  . "$REPO_ROOT/scripts/_features.sh"
fi

PER_STREAM_STACKS="${PER_STREAM_STACKS:-0}"

# Deterministic compose project name from the worktree dir basename. The SAME
# worktree always reattaches to the SAME stack (idempotent init); two worktrees
# never collide. Compose project names allow only [a-z0-9_-]; lowercase and
# replace anything else (e.g. MyApp-featureX -> myapp-featurex).
stack_default_proj() {
  basename "$REPO_ROOT" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_' | sed 's/_*$//'
}

if [[ "$PER_STREAM_STACKS" == "1" ]]; then
  # Re-load discovered coordinates (project name + HEALTH_URL) if init wrote them.
  # `set -a` exports everything the file defines. Ephemeral/CI runs that pin their
  # OWN coordinates set STACK_NO_ENV_FILE=1 to skip this.
  if [[ "${STACK_NO_ENV_FILE:-0}" != "1" && -f "$REPO_ROOT/.agent/env" ]]; then
    set -a
    # shellcheck source=/dev/null
    . "$REPO_ROOT/.agent/env"
    set +a
  fi

  # An explicit COMPOSE_PROJECT_NAME (manual / CI) always wins; else derive it.
  PROJ="${COMPOSE_PROJECT_NAME:-$(stack_default_proj)}"
  export COMPOSE_PROJECT_NAME="$PROJ"

  # docker compose scoped to this project. A restart/start can hand the container
  # a NEW kernel-assigned host port, which would leave HEALTH_URL pointing at the
  # dead one — so re-discover + rewrite .agent/env after those subcommands.
  dc() {
    docker compose -p "$PROJ" "$@"
    local rc=$?
    if [[ $rc -eq 0 ]]; then
      case "${1:-}" in restart|start) refresh_stack_env || true ;; esac
    fi
    return $rc
  }

  # Host port that container-port $2 of service $1 publishes (empty if down).
  # Tolerant of set -e/pipefail: never aborts the caller if the service is absent.
  stack_port() {
    { dc port "$1" "$2" 2>/dev/null || true; } | sed -n 's/.*:\([0-9][0-9]*\)$/\1/p' | head -1
  }

  # Re-discover the health host port and rewrite + re-export .agent/env. Guarded:
  # if the port isn't published yet (briefly, right after a start) it leaves the
  # existing file untouched rather than clobbering it with blanks.
  refresh_stack_env() {
    [[ "${STACK_NO_ENV_FILE:-0}" == "1" ]] && return 0
    local svc="${STACK_HEALTH_SERVICE:-}" cport="${STACK_HEALTH_CONTAINER_PORT:-}" hpath="${STACK_HEALTH_PATH:-/}"
    [[ -n "$svc" && -n "$cport" ]] || return 0
    local p _
    for _ in 1 2 3 4 5 6; do p="$(stack_port "$svc" "$cport")"; [[ -n "$p" ]] && break; sleep 0.5; done
    [[ -n "$p" ]] || return 0
    export STACK_URL="http://localhost:$p"
    export HEALTH_URL="http://localhost:$p$hpath"
    mkdir -p "$REPO_ROOT/.agent"
    cat > "$REPO_ROOT/.agent/env" <<ENV
# Written by scripts/_stack.sh (refresh after dc restart/start) — per-stream coords.
COMPOSE_PROJECT_NAME=$PROJ
STACK_URL=$STACK_URL
HEALTH_URL=$HEALTH_URL
ENV
  }
fi
