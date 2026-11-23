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
#   HARNESS_ENV_FILE   one more settings file read after harness.env (below); unset = none
# ⚠ Why a project NAME is required at all: the ledger is one instance per box, read by every worktree
# of the project, so its identifiers cannot derive from the checkout you happen to be standing in.
_he_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
export HARNESS_ROOT="${HARNESS_ROOT:-$_he_dir}"
if [[ -f "$HARNESS_ROOT/harness.env" ]]; then
  # shellcheck disable=SC1091
  set -a; . "$HARNESS_ROOT/harness.env"; set +a
fi
# HARNESS_ENV_FILE: one more settings file, read after harness.env so its values win (a project that keeps the
# owner's budget and caps outside every checkout, e.g. ~/.local/state/<project>/agents-budget.env). Unset = none.
# Only a file of plain settings is read: every line blank, a comment, or NAME=value. Anything else is not sourced
# and is said on stderr, so a stray command in a file under ~/.local/state never runs; the settings it would have
# carried stay unset, which the budget and the cap read as "no budget" (ask the owner) and "no cap".
if [[ -n "${HARNESS_ENV_FILE:-}" && -f "$HARNESS_ENV_FILE" ]]; then
  if command grep -qvE '^([[:space:]]*|[[:space:]]*#.*|[A-Za-z_][A-Za-z0-9_]*=.*)$' "$HARNESS_ENV_FILE" \
     || command grep -vE '^[[:space:]]*#' "$HARNESS_ENV_FILE" | command grep -qE '\$\(|`'; then
    printf 'harness-env: %s holds a line that is not NAME=value, a comment or blank (or runs a command): not read\n' "$HARNESS_ENV_FILE" >&2
  else
    # shellcheck disable=SC1090
    set -a; . "$HARNESS_ENV_FILE"; set +a
  fi
  export HARNESS_ENV_FILE
fi
export HARNESS_PROJECT="${HARNESS_PROJECT:-$(basename -- "$HARNESS_ROOT")}"
export TICKET_STORE="${TICKET_STORE:-db}"
export LEDGER_CONTAINER="${LEDGER_CONTAINER:-${HARNESS_PROJECT}-ledger-db}"
export LEDGER_NETWORK="${LEDGER_NETWORK:-${HARNESS_PROJECT}-ledger_default}"
export HARNESS_REPO="${HARNESS_REPO:-}"
export LEDGER_PORT="${LEDGER_PORT:-55432}"
export LEDGER_DEPLOY_DIR="${LEDGER_DEPLOY_DIR:-$HOME/.local/state/${HARNESS_PROJECT}/ledger-db}"
unset _he_dir
