#!/usr/bin/env bash
# team/diff-fingerprint.sh <base> [<head>] - a change's fingerprint, 16 hex characters, that a developer's handover and a
# tester's check can compare. Run it inside the repository.
#
#   team/diff-fingerprint.sh <base>          the working tree against <base>, new files included: work not yet committed
#   team/diff-fingerprint.sh <base> <head>   <base> against <head>: the same change once committed gives the same value
#
# The diff carries full object ids (--full-index), so the value does not follow git's abbreviation length, which
# differs between checkouts. New files are added intent-to-add to a copy of the index, never the real one, so the
# command changes nothing in the checkout it reads.
set -euo pipefail
[ $# -ge 1 ] && [ $# -le 2 ] || { echo "usage: diff-fingerprint.sh <base> [<head>]" >&2; exit 2; }
cd "$(git rev-parse --show-toplevel)"
diff() { git diff --full-index --binary --no-ext-diff --no-textconv --no-color "$@"; }
sha() { if command -v sha256sum >/dev/null; then sha256sum; else shasum -a 256; fi | cut -c1-16; }
if [ $# -eq 2 ]; then
  diff "$1" "$2" | sha
  exit
fi
T=$(mktemp)
trap 'rm -f "$T"' EXIT
index=$(git rev-parse --git-path index)
[ -f "$index" ] && cp "$index" "$T" || rm -f "$T"
GIT_INDEX_FILE=$T git add -N .
GIT_INDEX_FILE=$T diff "$1" | sha
