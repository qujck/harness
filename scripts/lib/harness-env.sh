#!/usr/bin/env bash
# scripts/lib/harness-env.sh — one place that reads harness.env and sets the defaults every harness
# script shares. Sourced; parses no arguments (METHOD.md: do not put a CLI on a sourced library).
#
#   . "$(dirname "${BASH_SOURCE[0]}")/lib/harness-env.sh"
#
# Exports (each overridable in harness.env or the environment):
#   HARNESS_ROOT       the repo root
#   HARNESS_PROJECT    a short name for this project; the default is the repo directory's basename.
#                      Names the ledger compose project ("<project>-ledger"), its container, its
#                      docker network, and the worktree prefix the roster's launch line prints.
#   TICKET_STORE       db | jira — which ticket store the one verb set talks to (default db)
#   LEDGER_CONTAINER   the ledger's container name (default "<project>-ledger-db")
#   LEDGER_NETWORK     the ledger compose project's default network (default "<project>-ledger_default")
#   LEDGER_PORT        the loopback port the ledger listens on (default 55432)
#   LEDGER_DEPLOY_DIR  where the compose file and the password live, OUTSIDE every checkout
#                      (default ~/.local/state/<project>/ledger-db) — one ledger per box, not per worktree
# ⚠ Why a project NAME is required at all: the ledger is one instance per box, read by every worktree
# of the project, so its identifiers cannot derive from the checkout you happen to be standing in.
_he_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export HARNESS_ROOT="${HARNESS_ROOT:-$_he_dir}"
if [[ -f "$HARNESS_ROOT/harness.env" ]]; then
  # shellcheck disable=SC1091
  set -a; . "$HARNESS_ROOT/harness.env"; set +a
fi
export HARNESS_PROJECT="${HARNESS_PROJECT:-$(basename -- "$HARNESS_ROOT")}"
export TICKET_STORE="${TICKET_STORE:-db}"
export LEDGER_CONTAINER="${LEDGER_CONTAINER:-${HARNESS_PROJECT}-ledger-db}"
export LEDGER_NETWORK="${LEDGER_NETWORK:-${HARNESS_PROJECT}-ledger_default}"
export HARNESS_REPO="${HARNESS_REPO:-}"
export LEDGER_PORT="${LEDGER_PORT:-55432}"
export LEDGER_DEPLOY_DIR="${LEDGER_DEPLOY_DIR:-$HOME/.local/state/${HARNESS_PROJECT}/ledger-db}"
unset _he_dir
