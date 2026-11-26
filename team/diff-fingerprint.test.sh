#!/usr/bin/env bash
# Tests for team/diff-fingerprint.sh, in a throwaway repository.
#   bash team/diff-fingerprint.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FP="$HERE/diff-fingerprint.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
cd "$T" && git init -q -b main r && cd r
git config user.name t && git config user.email t@t
mkdir src && printf 'one\ntwo\n' > src/a.txt && git add . && git commit -qm base
base=$(git rev-parse HEAD)

# a modified file, a new file, run from a subfolder
printf 'one\nTWO\n' > src/a.txt && printf 'new\n' > src/b.txt
git status >/dev/null   # the index's stat data refreshed first, so only the script could change it after
idx=$(cksum < .git/index)
work=$(cd src && bash "$FP" "$base")
check "the real index is not written" '[ "$(cksum < .git/index)" = "$idx" ]'
check "prints 16 hex characters" '[[ $work =~ ^[0-9a-f]{16}$ ]]'
check "a new file counts" '[ "$work" != "$(git diff --full-index --binary "$base" | sha256sum | cut -c1-16)" ]'
check "nothing is left staged as intent-to-add" '[ "$(git status --porcelain src/b.txt)" = "?? src/b.txt" ]'
for n in 7 9 12; do
  git config core.abbrev $n
  check "the same with core.abbrev $n" '[ "$(bash "$FP" "$base")" = "$work" ]'
done
git config --unset core.abbrev
check "a staged change gives the same value as an unstaged one" '[ "$(git add src/a.txt && bash "$FP" "$base"; git reset -q)" = "$work" ]'

git add . && git commit -qm change
check "once committed, <base> <head> gives the same value" '[ "$(bash "$FP" "$base" HEAD)" = "$work" ]'
check "and the working tree against the base still does" '[ "$(bash "$FP" "$base")" = "$work" ]'
check "a different base gives a different value" '[ "$(bash "$FP" HEAD)" != "$work" ]'
check "a bad argument count is refused" '! bash "$FP" 2>/dev/null && ! bash "$FP" a b c 2>/dev/null'

[ "$fails" = 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
