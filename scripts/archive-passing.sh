#!/usr/bin/env bash
# scripts/archive-passing.sh — move passing tickets out of the live queue.
#
# Keeps the L08 feature-list primitive lean and machine-readable: the live
# queue stays just the outstanding work (fast ready-frontier query), while
# completed tickets become append-only history.
#
# For each features/<id>.json with status "passing", move it to
# features/archive/<id>.json — ONE FILE PER ARCHIVED TICKET — and remove the live file.
#
# ⚠ THIS USED TO APPEND TO feature_list.archive.jsonl AND RELY ON `merge=union`.
# That does not work, and it was measured rather than reasoned about:
#
#   GITHUB'S PR MERGE IGNORES .gitattributes MERGE DRIVERS.
#
# `merge=union` is honoured by your LOCAL `git merge`, so the pattern tests clean on one
# machine and fails on the workflow this harness actually prescribes (branch + PR). In the
# project this harness was extracted from it produced two full PR re-rolls in a single day
# (2026-07-14) before anyone worked out why: two agents archive different tickets, both
# append a line, GitHub reports a conflict, and each has to re-roll.
#
# One file per archived ticket has nothing to union. Two PRs archiving different tickets
# touch different paths and cannot conflict — which is the property the union driver was
# being asked for and could not deliver.
#
# The legacy feature_list.archive.jsonl (if your project has one) stays as READ-ONLY
# history: grep it, never append to it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/_features.sh"

command -v jq >/dev/null || { echo "archive-passing: jq not found" >&2; exit 1; }

ARCHIVE_DIR="${FEATURES_ARCHIVE_DIR:-$FEATURES_DIR/archive}"
mkdir -p "$ARCHIVE_DIR"

shopt -s nullglob
moved=0
for f in "$FEATURES_DIR"/*.json; do
  status="$(jq -r '.status // empty' "$f" 2>/dev/null || true)"
  [[ "$status" == "passing" ]] || continue
  id="$(jq -r '.id // empty' "$f" 2>/dev/null || true)"
  # Fall back to the filename so a ticket with no `id` is still archived rather than skipped.
  [[ -n "$id" ]] || id="$(basename "$f" .json)"
  # Pretty-printed, same shape as a live ticket file, so every existing grep/jq habit keeps
  # working against the archive. Overwrite-on-re-archive is the de-dup for a re-opened ticket.
  jq '.' "$f" > "$ARCHIVE_DIR/$id.json"
  rm -f "$f"
  echo "   archived $id -> $ARCHIVE_DIR/$id.json"
  moved=$((moved + 1))
done
echo "archive-passing: $moved passing ticket(s) moved to $ARCHIVE_DIR/"
if (( moved > 0 )); then
  echo "⚠ commit the archive file WITH the work, in the same PR — a trailing 'chore: archive <id>'"
  echo "  PR doubles the PR count and leaves a window where main says a finished ticket is open."
fi
