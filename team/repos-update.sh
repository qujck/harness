#!/usr/bin/env bash
# team/repos-update.sh — bring the standard branches of the local repositories up to date with their remote, as the
# team page's Start and its Repositories button do. The repositories are those directly under AGENT_REPOS_ROOT
# (harness.env), or --root, else this project's own repository alone. Each is fetched, all at once, and each of its
# develop, main and master that exists locally with an upstream is fast-forwarded to that upstream: one not checked out
# moves without touching any working tree; the one checked out moves only when the checkout has no uncommitted changes
# and no process working in it. No branch is switched, merged, rebased or reset, other branches are never moved, and a
# repository AGENT_REPOS_SKIP names, by folder or by the account its origin belongs to (one that is not the team's),
# is left alone, not even fetched. A branch that cannot move is left as it is, with the reason.
#
#   bash team/repos-update.sh [--dry-run] [--root DIR]
#   bash team/repos-update.sh --self-test
#
# Prints each branch's line ("updated api develop: 3 commits from origin/develop", "left web main: checked out with 1
# uncommitted changes, 26 behind"), then one summary line counting branches ("6 branches updated, 40 up to date, 9 left
# as they are; behind but left: web main (26)"). An update's lines also go to ~/.local/state/<project>/repos-update.log.
# --dry-run fetches but moves nothing, and logs nothing. Exits 0 unless the root cannot be read; 2 for a bad argument.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"

selftest() {
  local fails=0 T out
  T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
  g() { git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
  g init -q "$T/origin" && g -C "$T/origin" commit -q --allow-empty -m a && g -C "$T/origin" branch develop
  mkdir "$T/root" && g clone -q "$T/origin" "$T/root/app" 2>/dev/null
  g -C "$T/root/app" branch -q --track develop origin/develop && g -C "$T/root/app" switch -q -c feature/x
  g clone -q "$T/origin" "$T/root/dirty" 2>/dev/null && echo x > "$T/root/dirty/f"
  g clone -q "$T/origin" "$T/root/theirs" 2>/dev/null
  g -C "$T/origin" commit -q --allow-empty -m b && g -C "$T/origin" switch -q develop && g -C "$T/origin" commit -q --allow-empty -m c
  out=$(cd / && HOME=$T HARNESS_PROJECT=p AGENT_REPOS_SKIP=theirs bash "$_here/repos-update.sh" --root "$T/root")
  check "a branch not checked out moves" "$(g -C "$T/root/app" rev-list --count main..origin/main)" 0
  check "  and develop too" "$(g -C "$T/root/app" rev-list --count develop..origin/develop)" 0
  check "the branch checked out stays where it was" "$(g -C "$T/root/app" branch --show-current)" feature/x
  check "a checked-out branch with changes is left, and why" "$(grep -c '^left dirty main: checked out with 1 uncommitted changes, 1 behind' <<<"$out")" 1
  check "  its changes kept" "$(cat "$T/root/dirty/f")" x
  check "a skipped repository is not touched" "$(grep -c theirs <<<"$out")" 0
  check "the summary counts branches" "$(tail -1 <<<"$out")" "2 branches updated, 0 up to date, 1 left as they are; behind but left: dirty main (1)"
  check "an update is logged" "$(grep -c 'branches updated' "$T/.local/state/p/repos-update.log")" 1
  g -C "$T/origin" switch -q main && g -C "$T/origin" commit -q --allow-empty -m d
  out=$(cd / && HOME=$T HARNESS_PROJECT=p AGENT_REPOS_SKIP=theirs bash "$_here/repos-update.sh" --root "$T/root" --dry-run)
  check "a dry run says what it would move" "$(grep -c '^would update app main: 1 behind origin/main' <<<"$out")" 1
  check "  and moves nothing" "$(g -C "$T/root/app" rev-list --count main..origin/main)" 1
  bash "$_here/repos-update.sh" --now >/dev/null 2>&1; check "a bad argument is refused" "$?" 2
  [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; return 1; }
}
ROOT="" DRY=0
while [ $# -gt 0 ]; do
  if selftest_is_flag "$1"; then selftest; exit $?; fi
  case "$1" in
    --dry-run) DRY=1 ;;
    --root) ROOT="${2:-}"; shift ;;
    *) echo "usage: repos-update.sh [--dry-run] [--root DIR]" >&2; exit 2 ;;
  esac
  shift
done
ROOT=${ROOT:-${AGENT_REPOS_ROOT:-}}
[ -z "$ROOT" ] || [ -d "$ROOT" ] || { echo "repos-update: no $ROOT" >&2; exit 1; }
project=${HARNESS_PROJECT:-$(basename "$(cd "$_here/.." && pwd)")}
LOG="$HOME/.local/state/$project/repos-update.log"
mkdir -p "$(dirname "$LOG")"
SKIP=" ${AGENT_REPOS_SKIP:-} "
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

mapfile -t CWDS < <(for p in /proc/[0-9]*/cwd; do readlink "$p" 2>/dev/null; done | sort -u)
in_use() { local c; for c in "${CWDS[@]}"; do [[ "$c" == "$1" || "$c" == "$1"/* ]] && return 0; done; return 1; }

# one repository: fetch, then each standard branch fast-forwarded if it may be; its lines to $T/<name>
one() {
  local repo="$1" name cur br up behind ahead dirty out
  name=$(basename "$repo"); out="$T/$name"
  if ! timeout 60 git -C "$repo" fetch --quiet --prune 2>/dev/null; then echo "left $name: the fetch failed" > "$out"; return; fi
  cur=$(git -C "$repo" branch --show-current)
  : > "$out"
  for br in develop main master; do
    git -C "$repo" show-ref --verify --quiet "refs/heads/$br" || continue
    up=$(git -C "$repo" rev-parse --abbrev-ref "$br@{u}" 2>/dev/null) || { echo "left $name $br: no upstream" >> "$out"; continue; }
    behind=$(git -C "$repo" rev-list --count "$br..$br@{u}") ahead=$(git -C "$repo" rev-list --count "$br@{u}..$br")
    [ "$behind" -gt 0 ] || { echo "current $name $br" >> "$out"; continue; }
    [ "$ahead" -eq 0 ] || { echo "left $name $br: $ahead commits $up does not, $behind behind" >> "$out"; continue; }
    if [ "$br" = "$cur" ]; then
      dirty=$(git --no-optional-locks -C "$repo" status --porcelain | wc -l)
      [ "$dirty" -eq 0 ] || { echo "left $name $br: checked out with $dirty uncommitted changes, $behind behind" >> "$out"; continue; }
      if in_use "$repo"; then echo "left $name $br: checked out and in use, $behind behind" >> "$out"; continue; fi
    elif git -C "$repo" worktree list --porcelain | grep -qx "branch refs/heads/$br"; then
      echo "left $name $br: checked out in a worktree, $behind behind" >> "$out"; continue
    fi
    if [ "$DRY" = 1 ]; then echo "would update $name $br: $behind behind $up" >> "$out"; continue; fi
    if { [ "$br" = "$cur" ] && git -C "$repo" merge --ff-only --quiet "$up" 2>/dev/null; } ||
       { [ "$br" != "$cur" ] && git -C "$repo" update-ref "refs/heads/$br" "$(git -C "$repo" rev-parse "$up")" "$(git -C "$repo" rev-parse "$br")"; }; then
      echo "updated $name $br: $behind commits from $up" >> "$out"
    else echo "left $name $br: the fast-forward failed" >> "$out"; fi
  done
  [ -s "$out" ] || echo "left $name: no develop, main or master" > "$out"
}

if [ -n "$ROOT" ]; then repos=("$ROOT"/*/); else repos=("$(git -C "$_here" rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git$##')/"); fi
for repo in "${repos[@]}"; do
  repo="${repo%/}"
  [ -e "$repo/.git" ] || continue
  owner=$(git -C "$repo" remote get-url origin 2>/dev/null | sed -E 's#/*$##; s#\.git$##; s#.*[:/]([^/:]+)/[^/]+$#\1#')
  [[ "$SKIP" == *" $(basename "$repo") "* || ( -n "$owner" && "$SKIP" == *" $owner "* ) ]] && continue
  one "$repo" &
done
wait

lines=$(cat "$T"/* 2>/dev/null | sort)
count() { printf '%s\n' "$lines" | grep -c "^$1 " ; }
# the branches left behind their remote are worth naming; the rest (no upstream, a failed fetch) only counted
behind=$(printf '%s\n' "$lines" | sed -n 's/^left \([^:]*\):.* \([0-9]*\) behind.*/\1 (\2)/p' | paste -sd, - | sed 's/,/, /g')
summary="$(count "$( [ "$DRY" = 1 ] && echo would || echo updated)") $( [ "$DRY" = 1 ] && echo "branches to update" || echo "branches updated"), $(count current) up to date, $(count left) left as they are${behind:+; behind but left: $behind}"
[ "$DRY" = 1 ] || { printf '%s\n' "$lines" | sed "s/^/$(date '+%F %T') /"; echo "$(date '+%F %T') $summary"; } >> "$LOG"
printf '%s\n' "$lines"
echo "$summary"
