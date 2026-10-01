#!/usr/bin/env bash
# feature-ticket.sh — the LIFECYCLE verbs over the ledger: claim · claims · park · release · exists.
#
# The ticket store is the ledger (scripts/ledger-db.sh, behind the adapter in scripts/lib/ticket-store.sh);
# this script adds the one thing a row cannot be: the ATOMIC LOCK. A claim is a branch named after the
# ticket pushed to the remote — two agents claiming the same id race on the push and exactly one wins —
# and the row records WHO holds it (`ledger.claim`). The branch is the lock; the row is the record.
#
#   claim <id>…        push the lock branch, then record the claim on the row (refused if either exists)
#   claims             every lock branch on the remote with the row's holder and status
#   park <id> "<why>"  the row's park (status stays, the lock STAYS UP) — the ask goes on the row
#   release <id>       delete the lock branch(es) — only for a row already archived / wont_do
#   exists <id>        row on the ledger? lock branch on the remote? exit 0 yes · 1 no · 2 CANNOT TELL
#
# Raise, groom, amend, flip-passing, archive, wont-do are ledger-db.sh verbs: this file never writes a
# ticket's CONTENT. (feat_harness_the_ledger_is_a_database_with_raise_groom_claim_amend_flip_archive_and_release_verbs)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/selftest-flag.sh"
. "$HERE/lib/harness-env.sh"
REMOTE="${FEATURE_TICKET_REMOTE:-origin}"
LDB="${LDB:-bash $HERE/ledger-db.sh}"   # overridable so the self-test can stub the ledger

ok()   { printf '  \033[1;32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[1;33mwarn\033[0m  %s\n' "$*"; }
die()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }

# _lock_branches <id> — the branches on the remote that hold this id (the id itself or <id>-…)
_lock_branches() {
  git ls-remote --heads "$REMOTE" 2>/dev/null | sed -E 's#.*refs/heads/##' \
    | awk -v id="$1" '$0 == id || index($0, id "-") == 1'
}
# _row_status <id> — the row's status, or empty when there is no row. Exit 2 = could not read.
_row_status() { $LDB ticket-row "$1" 2>/dev/null || return 2; }

cmd_claim() {
  [[ $# -ge 1 ]] || die "usage: feature-ticket.sh claim <id> [<id>…]"
  local me; me="$($LDB whoami 2>/dev/null || true)"
  [[ -n "$me" ]] || die "no session identity — GIT_AUTHOR_EMAIL must map to a row in agents/roster.json"
  git fetch -q "$REMOTE" 2>/dev/null || warn "could not fetch $REMOTE — the lock check may be stale"
  local id st held
  for id in "$@"; do
    st="$(_row_status "$id")" || die "could not read the ledger for $id — CANNOT TELL, not 'free'"
    [[ -n "$st" ]] || die "no row for $id on the ledger — raise it first (ledger-db.sh raise <json>)"
    case "$st" in
      archived|passing|wont_do) die "$id is '$st' — finished, not claimable" ;;
      selected|in_progress) ;;
      *) die "$id is '$st' — ask the PO to groom it to selected first" ;;
    esac
    held="$(_lock_branches "$id")"
    [[ -z "$held" ]] || die "$id is already claimed — branch(es) on $REMOTE: $(tr '\n' ' ' <<<"$held")
Pick another ticket. (The branch is the lock; the row's status is not.)"
    git branch -q -f "$id" "$REMOTE/main" 2>/dev/null || die "could not create branch $id from $REMOTE/main"
    if ! git push -q "$REMOTE" "$id" 2>/dev/null; then
      git branch -q -D "$id" 2>/dev/null || true
      die "push rejected for $id — another agent claimed it first. Pick another ticket.
⚠ This is the race the branch push exists to lose safely."
    fi
    # the lock is up; now the record. A refused record (identity, state) must not leave a silent lock.
    if ! $LDB claim "$id"; then
      git push -q "$REMOTE" --delete "$id" 2>/dev/null && warn "lock branch $id removed again — the row refused the claim"
      die "the ledger refused the claim for $id (see above); nothing is held"
    fi
    ok "claimed $id for $me — lock branch pushed, row records the holder. Work on $id-pt1 cut from $REMOTE/main."
  done
}

cmd_claims() {
  git fetch -q "$REMOTE" 2>/dev/null || true
  local b id st who found=0
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    [[ "$b" == main || "$b" == HEAD ]] && continue
    id="${b%%-pt*}"; id="${id%-park}"
    st="$(_row_status "$id" 2>/dev/null || true)"; [[ -n "$st" ]] || continue
    found=1
    who="$($LDB ticket-owner "$id" 2>/dev/null || echo '?')"
    printf '  %-56s %-12s %s\n' "$b" "$st" "${who:-?}"
  done < <(git ls-remote --heads "$REMOTE" 2>/dev/null | sed -E 's#.*refs/heads/##')
  (( found )) || echo "  (no live claims)"
}

cmd_park() {
  local id="${1:?usage: feature-ticket.sh park <id> \"<why>\" [--kind … --condition …]}"; shift
  local why="${1:-}"; [[ $# -ge 1 ]] && shift
  [[ -n "$why" ]] || die "park needs a reason — the next reader must know WHY without spelunking"
  $LDB park "$@" "$id" "$why" || die "the ledger refused the park"
  ok "parked $id — the row carries the ask; the lock STAYS UP"
  if [[ -z "$(_lock_branches "$id")" ]]; then
    git branch -q -f "$id-park" "$REMOTE/main" 2>/dev/null && git push -q "$REMOTE" "$id-park" 2>/dev/null \
      && ok "re-created the lock as $id-park (the merge had taken it)" \
      || warn "could not re-create the lock — the id may read as FREE to other agents"
  fi
}

cmd_release() {
  local id="${1:?usage: feature-ticket.sh release <id>}"
  local st; st="$(_row_status "$id")" || die "could not read the ledger for $id — CANNOT TELL"
  case "$st" in
    archived|wont_do|passing) ;;
    *) die "refusing: $id is '${st:-no row}' and not finished.
release is for work already in main (flip-passing → archive first). Handing it back is \`ledger-db.sh stand-down <id> <why>\`." ;;
  esac
  local b n=0
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    if git push -q "$REMOTE" --delete "$b" 2>/dev/null; then ok "deleted $b (id unlocked)"; n=$((n+1))
    else warn "could not delete $b"; fi
  done < <(_lock_branches "$id")
  (( n )) || warn "no lock branch for $id — already released, or the merge deleted it"
  $LDB release "$id" "lock released by feature-ticket.sh after $st" >/dev/null 2>&1 || true
}

cmd_exists() {
  local id="${1:?usage: feature-ticket.sh exists <id>}" hit=0 st held
  st="$(_row_status "$id")" || { echo "  CANNOT TELL — the ledger could not be read; never raise on this"; exit 2; }
  [[ -n "$st" ]] && { ok "EXISTS on the ledger: $id ($st)"; hit=1; }
  git fetch -q "$REMOTE" 2>/dev/null || { echo "  CANNOT TELL — $REMOTE could not be fetched"; exit 2; }
  held="$(_lock_branches "$id")"
  [[ -n "$held" ]] && { ok "EXISTS as a lock branch on $REMOTE: $(tr '\n' ' ' <<<"$held")"; hit=1; }
  (( hit )) && exit 0
  echo "  not on the ledger, no lock branch — safe to raise"; exit 1
}

_ft_self_test() {
  local fails=0 tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/ft-selftest.XXXXXX")"; trap 'rm -rf "$tmp"' RETURN
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; fails=1; fi; }
  # a stub remote with two lock branches; _lock_branches reads it through ls-remote
  git init -q --bare "$tmp/remote.git"; git init -q "$tmp/w"; ( cd "$tmp/w" && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m x \
    && git branch -q -M main && git remote add origin "$tmp/remote.git" && git push -q origin main && git push -q origin main:refs/heads/abc_x && git push -q origin main:refs/heads/abc_x-pt1 && git push -q origin main:refs/heads/abcd )
  _t "the id and its -pt branches are the lock, a longer id is not" $'abc_x\nabc_x-pt1' "$(cd "$tmp/w" && _lock_branches abc_x)"
  _t "an unlocked id has no lock branches" "" "$(cd "$tmp/w" && _lock_branches zzz)"
  # exists: a stubbed ledger (LDB) returning a status / nothing / failing
  _t "exists: row on the ledger → 0"    0 "$( (cd "$tmp/w"; LDB='printf selected #' bash -c '. '"$HERE"'/feature-ticket.sh --self-test-lib; cmd_exists zzz >/dev/null 2>&1'; echo $?) )"
  _t "exists: no row, no branch → 1"    1 "$( (cd "$tmp/w"; LDB='true #' bash -c '. '"$HERE"'/feature-ticket.sh --self-test-lib; cmd_exists zzz >/dev/null 2>&1'; echo $?) )"
  _t "exists: ledger unreadable → 2, never 'safe'" 2 "$( (cd "$tmp/w"; LDB='false #' bash -c '. '"$HERE"'/feature-ticket.sh --self-test-lib; cmd_exists zzz >/dev/null 2>&1'; echo $?) )"
  _t "release refuses a row that is not finished" 1 "$( (cd "$tmp/w"; LDB='printf in_progress #' bash -c '. '"$HERE"'/feature-ticket.sh --self-test-lib; cmd_release abc_x >/dev/null 2>&1'; echo $?) )"
  _t "claim refuses a finished row"        1 "$( (cd "$tmp/w"; LDB='printf archived #' bash -c '. '"$HERE"'/feature-ticket.sh --self-test-lib; cmd_claim abcd >/dev/null 2>&1'; echo $?) )"
  _t "claim refuses a held lock"           1 "$( (cd "$tmp/w"; LDB='printf selected #' bash -c '. '"$HERE"'/feature-ticket.sh --self-test-lib; cmd_claim abc_x >/dev/null 2>&1'; echo $?) )"
  _t "claim: wins the push, records the row" 0 "$( (cd "$tmp/w"; LDB='printf selected #' bash -c '. '"$HERE"'/feature-ticket.sh --self-test-lib; cmd_claim zzz >/dev/null 2>&1'; echo $?) )"
  _t "…and the lock branch is on the remote" zzz "$(cd "$tmp/w" && _lock_branches zzz)"
  _t "claim: row refuses → the lock comes down again" "" "$( (cd "$tmp/w"; LDB='bash -c "case \$1 in whoami) echo me;; ticket-row) echo selected;; claim) exit 1;; esac" -- #' bash -c '. '"$HERE"'/feature-ticket.sh --self-test-lib; cmd_claim yyy >/dev/null 2>&1; _lock_branches yyy') )"
  (( fails == 0 )) && echo "feature-ticket --self-test: ok" || echo "feature-ticket --self-test: FAILED" >&2
  return $fails
}
# --self-test-lib: load the functions and return (used by the self-test's subshells to drive one verb with a stubbed ledger)
[[ "${1:-}" == --self-test-lib ]] && return 0 2>/dev/null
selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then _ft_self_test; exit $?; fi

case "${1:-}" in
  claim)   shift; cmd_claim "$@" ;;
  claims)  cmd_claims ;;
  park)    shift; cmd_park "$@" ;;
  release) shift; cmd_release "$@" ;;
  exists)  shift; cmd_exists "$@" ;;
  *) sed -n '2,16p' "${BASH_SOURCE[0]}"; exit 64 ;;
esac
