#!/usr/bin/env bash
# scripts/lib/agent-name.sh — who is this session? Sourced, never executed.
#
#   . scripts/lib/agent-name.sh
#   name="$(agent_name_of "$REPO_ROOT")"
#
# ⚠ THIS FILE PARSES NO ARGUMENTS AND CALLS NO exit. A sourced file that reads $1 reads its
# CALLER'S argv — a library with a `--self-test` arm once answered its caller's own `--self-test`
# and exited 0, silently replacing a real gate with one that always passes. Libraries here are pure
# functions; their assertions live in whichever script sources them.
#
# ── WHY AN AGENT NEEDS A NAME ────────────────────────────────────────────────────────────────────
# Every ownership record — who claimed a ticket, who parked it, whose session record this is — is
# worthless if it says "agent". With more than one agent the name is the only thing that makes a
# claim attributable, and attribution is the one field the ledger cannot self-correct: a wrong
# STATUS is fixed by the next verify, a wrong OWNER just persists.
#
# ⚠ RESOLUTION ORDER IS `.agent/name` > $AGENT_NAME, AND THAT ORDER MATTERS.
# `.agent/name` names a DIRECTORY, not a session. If two agents share one checkout, the second one
# reads the first one's name and stamps its work with it — silently, with nothing else looking
# wrong. That is why the harness tells you to work in your own worktree: the name is per-directory,
# so sharing a directory means sharing an identity whether you meant to or not.

# agent_name_of <repo-root> → the name, or empty if none is set.
agent_name_of() {
  local root="${1:-.}" n=""
  [[ -f "$root/.agent/name" ]] && n="$(tr -d '\r\n' < "$root/.agent/name" 2>/dev/null || true)"
  [[ -n "$n" ]] || n="${AGENT_NAME:-}"
  printf '%s' "$n"
}

# agent_name_set <repo-root> <name> → persist it for this directory.
agent_name_set() {
  local root="${1:?}" n="${2:?}"
  mkdir -p "$root/.agent"
  printf '%s\n' "$n" > "$root/.agent/name"
}

# agent_name_slug <name> → filename-safe form (used by progress.sh and claim stamps).
agent_name_slug() {
  printf '%s' "${1:-}" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-'
}
