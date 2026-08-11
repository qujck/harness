#!/usr/bin/env bash
# scripts/feature-ticket.sh — claim a ticket so no other agent takes it, and let it go when done.
#
#   bash scripts/feature-ticket.sh claim <id> [<id>…]   # take it: flip + commit + PUSH the lock
#   bash scripts/feature-ticket.sh claims               # who holds what, right now
#   bash scripts/feature-ticket.sh park <id> "<why>"    # stop, KEEP the lock, say why
#   bash scripts/feature-ticket.sh release <id>         # finished: drop the lock
#   bash scripts/feature-ticket.sh exists <id>          # is this id already taken/used anywhere?
#
# ── ⚠ THE PUSHED BRANCH *IS* THE LOCK, AND NOTHING ELSE IS ─────────────────────────────────────
# A ticket file saying `in_progress` is not a lock: two agents can both read `not_started`, both
# write `in_progress`, and both start. Checking for an existing branch first is not a lock either —
# two agents can both look, both see nothing, and both proceed. There is exactly one operation here
# that is ATOMIC across machines:
#
#     git push origin <id>          — the remote REJECTS the second pusher.
#
# So the claim is the push. First push wins; the loser is told to pick another ticket. Everything
# else in this file is bookkeeping around that one atomic fact.
#
# ⚠ AND THE BRANCH IS BASED ON origin/main, NEVER ON YOUR CURRENT HEAD. Basing a claim on whatever
# HEAD happens to be is how a claim branch silently absorbs another agent's unmerged commits.
#
# ── ⚠ WHY THE LOCK OUTLIVES THE WORK, AND WHAT THAT COSTS ──────────────────────────────────────
# `delete_branch_on_merge` removes a PR's head branch when it merges — right for a FINISHED ticket
# and silently wrong for a PARKED one, because the moment the PR merges the id reads as free to
# everyone while the work is still yours. That is what `park` re-creates and `release` deliberately
# does not do until the work is actually finished.
#
# THIS IS A SUBSET of the tool it was extracted from — no takeover, no batch claims, no issue
# integration. What is here is the part that makes parallel agents SAFE rather than convenient.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=scripts/lib/agent-name.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-name.sh"
FEATURES_DIR="${FEATURES_DIR:-features}"
ARCHIVE_DIR="${FEATURES_ARCHIVE_DIR:-$FEATURES_DIR/archive}"
REMOTE="${FEATURE_TICKET_REMOTE:-origin}"

ok()   { printf '  \033[1;32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[1;33mwarn\033[0m  %s\n' "$*"; }
die()  { printf '  \033[1;31mFAIL\033[0m  %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null || die "jq not found"

_ticket()  { printf '%s/%s.json' "$FEATURES_DIR" "$1"; }
_archived(){ [[ -f "$ARCHIVE_DIR/$1.json" ]]; }
_status()  { jq -r '.status // empty' "$(_ticket "$1")" 2>/dev/null || true; }

# Every remote branch whose name is a ticket id (or a sanctioned variant of one).
# ⚠ MATCH A PREFIX, NOT AN EXACT NAME: `<id>-pt2` for a multi-PR ticket and `<id>-park` are
# sanctioned variants, and an exact-match lookup reports a held id as free.
_lock_branches() { # <id>
  git ls-remote --heads "$REMOTE" 2>/dev/null \
    | sed -E 's#.*refs/heads/##' \
    | awk -v id="$1" '$0 == id || index($0, id "-") == 1'
}

_require_name() {
  local n; n="$(agent_name_of "$REPO_ROOT")"
  [[ -n "$n" ]] || die "no agent name — set it: echo '<you>' > .agent/name  (or export AGENT_NAME)
⚠ Every claim is stamped with this. Without it the ledger records that SOMEBODY holds the ticket
and cannot say who, which is the one field nothing downstream can reconstruct."
  printf '%s' "$n"
}

cmd_claim() {
  [[ $# -ge 1 ]] || die "usage: feature-ticket.sh claim <id> [<id>…]"
  local me; me="$(_require_name)"
  git fetch -q "$REMOTE" 2>/dev/null || warn "could not fetch $REMOTE — the lock check may be stale"
  local id f held
  for id in "$@"; do
    f="$(_ticket "$id")"
    [[ -f "$f" ]] || die "no such ticket: $f"
    _archived "$id" && die "$id is already archived — it is finished, not claimable"
    held="$(_lock_branches "$id")"
    [[ -z "$held" ]] || die "$id is already claimed — branch(es) on $REMOTE: $(tr '\n' ' ' <<<"$held")
Pick another ticket. (This is the lock; the ticket file's status is not.)"

    # ⚠ BASED ON origin/main, NOT ON HEAD — see the header.
    git branch -q -f "$id" "$REMOTE/main" 2>/dev/null \
      || die "could not create branch $id from $REMOTE/main"
    git checkout -q "$id" || die "could not switch to $id"

    jq --arg s in_progress --arg by "$me" \
       '.status = $s | .claimed_by = $by' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    git add "$f"
    git commit -q --no-verify -m "$id: claim (-> in_progress, $me)" \
      || die "nothing to commit for $id"

    # THE ATOMIC BIT. A rejected push means somebody claimed it between the check and here.
    if git push -q "$REMOTE" "$id" 2>/dev/null; then
      ok "claimed $id for $me — branch pushed (the lock)"
    else
      die "push rejected for $id — another agent claimed it first. Pick another ticket.
⚠ This is the race the branch push exists to lose safely: your local commit stands, but the id is
theirs. Reset with: git checkout main && git branch -D $id"
    fi
  done
}

cmd_claims() {
  git fetch -q "$REMOTE" 2>/dev/null || true
  local b id st found=0
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    [[ "$b" == "main" || "$b" == "HEAD" ]] && continue
    id="${b%%-pt*}"; id="${id%-park}"
    [[ -f "$(_ticket "$id")" ]] || _archived "$id" || continue
    found=1
    st="$(_status "$id")"; [[ -n "$st" ]] || st="archived"
    printf '  %-44s %-12s %s\n' "$b" "$st" \
      "$(jq -r '.claimed_by // "?"' "$(_ticket "$id")" 2>/dev/null || echo '?')"
  done < <(git ls-remote --heads "$REMOTE" 2>/dev/null | sed -E 's#.*refs/heads/##')
  (( found )) || echo "  (no live claims)"
}

cmd_park() {
  local id="${1:?usage: feature-ticket.sh park <id> \"<why>\"}" why="${2:-}"
  [[ -n "$why" ]] || die "park needs a reason — the next reader must know WHY without spelunking"
  local f; f="$(_ticket "$id")"; [[ -f "$f" ]] || die "no such ticket: $f"
  jq --arg p "$why" '.parked = $p' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  ok "parked $id — status stays in_progress and the lock STAYS UP"
  # ⚠ Re-create the lock if a merge already took it. delete_branch_on_merge removes a PR's head
  # branch, which is right for a finished ticket and wrong for a parked one.
  if [[ -z "$(_lock_branches "$id")" ]]; then
    git branch -q -f "$id-park" HEAD 2>/dev/null && git push -q "$REMOTE" "$id-park" 2>/dev/null \
      && ok "re-created the lock as $id-park (the merge had taken it)" \
      || warn "could not re-create the lock — the id may read as FREE to other agents"
  fi
  echo "  ⚠ commit this ticket change, or the marker exists only in your working tree and the"
  echo "    ticket reads ABANDONED to everyone else."
}

cmd_release() {
  local id="${1:?usage: feature-ticket.sh release <id>}"
  local st; st="$(_status "$id")"
  # ⚠ ONLY FOR FINISHED WORK. Releasing a live claim deletes the lock every other agent depends on.
  if ! _archived "$id" && [[ "$st" != "wont_do" ]]; then
    # ⚠ NO BACKTICKS IN THIS MESSAGE. Inside a double-quoted string they are COMMAND SUBSTITUTION,
    # so a tidy `release` in prose executes `release` and mangles the very error the reader needs.
    # Found by driving the refusal path — the path least likely to be exercised and most likely to
    # be read only when something has already gone wrong.
    die "refusing: $id is '${st:-unknown}' and not archived.
release is for work already in main. If you are handing it back, flip the status first and say so
in the ticket — an id that reads as taken by you, forever, is worse than one nobody claimed."
  fi
  local b n=0
  while IFS= read -r b; do
    [[ -n "$b" ]] || continue
    if git push -q "$REMOTE" --delete "$b" 2>/dev/null; then ok "deleted $b (id unlocked)"; n=$((n+1))
    else warn "could not delete $b"; fi
  done < <(_lock_branches "$id")
  (( n )) || warn "no lock branch for $id — already released, or the merge deleted it"
}

# ⚠ THE ONE LOOKUP THAT IS NOT KEYED ON A NAME YOU ALREADY KNOW.
# Grep, `git ls-remote <id>` and an issue search are all keyed on the id, so a ticket raised INSIDE
# somebody else's branch is invisible to every one of them — and several searches sharing one blind
# spot agree with each other, which reads as confirmation. This asks every ref for the FILE.
cmd_exists() {
  local id="${1:?usage: feature-ticket.sh exists <id>}" hit=0 r
  [[ -f "$(_ticket "$id")" ]] && { ok "EXISTS live: $(_ticket "$id")"; hit=1; }
  _archived "$id" && { ok "EXISTS archived: $ARCHIVE_DIR/$id.json"; hit=1; }
  git fetch -q "$REMOTE" 2>/dev/null || true
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    if git cat-file -e "$r:$FEATURES_DIR/$id.json" 2>/dev/null \
    || git cat-file -e "$r:$ARCHIVE_DIR/$id.json" 2>/dev/null; then
      # Distinguish "it is on main" from "it is hidden inside somebody's branch". Reporting main as
      # invisible-to-a-grep is false and would train the reader to discount the message that matters.
      case "$r" in
        */main|*/HEAD) ok "EXISTS on $r" ;;
        *)             ok "EXISTS on $r — raised INSIDE that branch, so a grep of your checkout cannot see it"; ;;
      esac
      hit=1
    fi
  done < <(git for-each-ref --format='%(refname)' "refs/remotes/$REMOTE" 2>/dev/null)
  (( hit )) && exit 0
  echo "  not found on any ref — safe to raise"; exit 1
}

case "${1:-}" in
  claim)   shift; cmd_claim "$@" ;;
  claims)  cmd_claims ;;
  park)    shift; cmd_park "$@" ;;
  release) shift; cmd_release "$@" ;;
  exists)  shift; cmd_exists "$@" ;;
  *)       sed -n '3,8p' "$0"; exit 2 ;;
esac
