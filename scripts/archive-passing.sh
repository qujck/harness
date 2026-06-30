#!/usr/bin/env bash
# scripts/archive-passing.sh — move passing tickets out of the live queue.
#
# Keeps the Lec 8 feature-list primitive lean and machine-readable: the live
# queue stays just the outstanding work (fast ready-frontier query), while
# completed tickets become append-only history.
#
# For each features/<id>.json with status "passing", append a compact one-line
# entry to feature_list.archive.jsonl (merge=union via .gitattributes, so
# concurrent archive appends auto-merge) and remove the live file. Run it after a
# ticket reaches "passing" to keep the ready-frontier query fast and the live
# queue focused on outstanding work.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/_features.sh"

command -v jq >/dev/null || { echo "archive-passing: jq not found" >&2; exit 1; }

shopt -s nullglob
moved=0
for f in "$FEATURES_DIR"/*.json; do
  status="$(jq -r '.status // empty' "$f" 2>/dev/null || true)"
  [[ "$status" == "passing" ]] || continue
  jq -c '.' "$f" >> "$FEATURES_ARCHIVE"
  rm -f "$f"
  echo "   archived $(basename "$f")"
  moved=$((moved + 1))
done
echo "archive-passing: $moved passing ticket(s) moved to $FEATURES_ARCHIVE"
