#!/usr/bin/env bash
# scripts/progress.sh — ONE FILE PER SESSION, instead of everyone editing PROGRESS.md.
#
#   bash scripts/progress.sh new "what happened"   # create this session's entry
#   bash scripts/progress.sh tail [n]              # the n newest entries (default 3)
#   bash scripts/progress.sh list [n]              # just their paths
#
# ── ⚠ WHY NOT PROGRESS.md ────────────────────────────────────────────────────────────────────────
# A single shared file that EVERY session is required to touch is a guaranteed conflict between any
# two agents finishing near each other. The harness used to answer that with `merge=union` in
# .gitattributes. That answer is wrong, and it was measured rather than argued:
#
#   GITHUB'S PR MERGE IGNORES .gitattributes MERGE DRIVERS.
#
# Your local `git merge` honours the union driver, so the pattern tests clean on one machine and
# then fails on the workflow this harness prescribes (branch + PR). The project this was extracted
# from hit two full PR re-rolls in one day before anyone worked out why.
#
# One file per session has nothing to union: two agents writing their own entries touch different
# paths and cannot conflict. The stamp+name in the filename is what makes that true even when two
# sessions finish in the same minute.
#
# PROGRESS.md (if your project has one) becomes FROZEN HISTORY: read it, never append to it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
PROGRESS_DIR="${PROGRESS_DIR:-progress}"

# The agent's name, so two sessions finishing in the same MINUTE still get different filenames.
# Falls back to the git user and then to the shell user — never to a constant, which would
# re-introduce the collision this file exists to remove.
_agent_name() {
  local n="${AGENT_NAME:-}"
  [[ -n "$n" ]] || n="$(cat .agent/name 2>/dev/null || true)"
  [[ -n "$n" ]] || n="$(git config user.name 2>/dev/null || true)"
  [[ -n "$n" ]] || n="${USER:-agent}"
  printf '%s' "$n" | tr '[:upper:] ' '[:lower:]-' | tr -cd '[:alnum:]-'
}

_slug() {
  printf '%s' "${1:-session}" | tr '[:upper:] ' '[:lower:]-' \
    | tr -cd '[:alnum:]-' | cut -c1-48 | sed 's/-*$//'
}

cmd_new() {
  local what="${1:-}"
  [[ -n "$what" ]] || { echo "usage: progress.sh new \"what happened\"" >&2; exit 2; }
  mkdir -p "$PROGRESS_DIR"
  local stamp name slug path
  stamp="$(date -u +%Y-%m-%d-%H%M)"
  name="$(_agent_name)"
  slug="$(_slug "$what")"
  path="$PROGRESS_DIR/$stamp-$name-$slug.md"
  # ⚠ Never clobber: if the same agent files twice in one minute, disambiguate rather than
  # overwrite. Losing a session record to a filename collision is the failure this file prevents.
  local n=2
  while [[ -e "$path" ]]; do path="$PROGRESS_DIR/$stamp-$name-$slug-$n.md"; n=$((n + 1)); done
  cat > "$path" <<EOF
# $what

**Agent:** $name · **UTC:** $(date -u '+%Y-%m-%d %H:%M')

## What happened

-

## What is left / next

-

## Anything the next session must not re-derive

-
EOF
  echo "$path"
}

cmd_list() {
  local n="${1:-3}"
  ls -1t "$PROGRESS_DIR"/*.md 2>/dev/null | head -n "$n" || true
}

cmd_tail() {
  local n="${1:-3}" f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    printf '\n===== %s =====\n' "$f"
    cat "$f"
  done < <(cmd_list "$n")
}

case "${1:-}" in
  new)  shift; cmd_new "${1:-}" ;;
  tail) shift; cmd_tail "${1:-3}" ;;
  list) shift; cmd_list "${1:-3}" ;;
  *)    sed -n '2,6p' "$0"; exit 2 ;;
esac
