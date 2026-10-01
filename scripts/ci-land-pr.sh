#!/usr/bin/env bash
# ci-land-pr.sh — after the pipeline has merged (or auto-merge has), carry the verify VERDICT onto the
# merge commit by CONTENT, and dispatch what a landing owes.
# (infra_the_pipeline_lands_its_own_pr_again_and_the_verify_verdict_follows_the_content_onto_main)
#
# ⚠ WHY A COMMIT ON MAIN CARRIED NO VERDICT. The pipeline's merge step used to run INSIDE the verify
# job, so the ruleset refused it every time ("the base branch policy prohibits the merge" — verify was
# still in_progress) and GitHub auto-merge landed the PR instead. Rebase-merge rewrites every commit, so
# the PR head's green check never reaches main, and a merge triggered by a GITHUB_TOKEN check creates
# no push run either. Measured 2026-09-08: 0 of 8 landings kept a sha with a check; the newest main
# commit with a green verify was 91 commits behind the tip; the v0.181.0 cut was refused for it.
#
# WHAT THIS DOES, in the `land` job (which `needs: verify`, so the merge is allowed by then):
#   1. reads the PR: merged? by which commit? — waiting a bounded time if the merge is still landing
#   2. compares the merge commit's TREE with the tree verify tested (TESTED_TREE, from the verify job)
#   3. equal → publishes a `verify` check-run with conclusion success on the merge commit, pointing at
#      the verify run: the same content, judged by the same run. Different → publishes NOTHING and
#      says so; the hourly full suite judges main. A verdict never follows a tree it did not judge.
#   4. dispatches coverage on merge (a GITHUB_TOKEN merge makes no push run) and, for a repair-main
#      PR, the full suite on main.
# Fails soft on everything: a landing that cannot be decorated is still a landing.
#
#   env: GH_TOKEN PR TESTED_TREE VERIFY_RUN_URL VERIFY_RUN_ID [REPAIR=0|1] [LAND_WAIT_S=90] [GH_REPO]
#   bash scripts/ci-land-pr.sh --self-test   # the verdict's own arms
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/harness-env.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
GH_REPO="${GH_REPO:-${HARNESS_REPO:-owner/repo}}"

# land_verdict <state: MERGED|OPEN|CLOSED|…> <tested-tree> <merge-tree> -> publish|differs|deferred|closed|unreadable
land_verdict() {
  local st="${1-}" t="${2-}" m="${3-}"
  case "$st" in
    MERGED)
      [[ "$t" =~ ^[0-9a-f]{40}$ && "$m" =~ ^[0-9a-f]{40}$ ]] || { printf 'unreadable\n'; return 0; }
      if [[ "$t" == "$m" ]]; then printf 'publish\n'; else printf 'differs\n'; fi ;;
    OPEN)   printf 'deferred\n' ;;
    CLOSED) printf 'closed\n' ;;
    *)      printf 'unreadable\n' ;;
  esac
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  f=0; _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s: want %q got %q\n' "$1" "$2" "$3"; f=1; fi; }
  a="$(printf 'a%.0s' {1..40})"; b="$(printf 'b%.0s' {1..40})"
  _t "merged, same tree -> publish (the same content, judged by the same run)" publish "$(land_verdict MERGED "$a" "$a")"
  _t "⚠ NEGATIVE CONTROL: merged, different tree -> differs, nothing published" differs "$(land_verdict MERGED "$a" "$b")"
  _t "still open after the wait -> deferred" deferred "$(land_verdict OPEN "$a" "$a")"
  _t "closed without merging -> closed" closed "$(land_verdict CLOSED "$a" "$a")"
  _t "a tree that is not a sha is unreadable, never publish" unreadable "$(land_verdict MERGED "$a" '')"
  _t "an unknown state is unreadable" unreadable "$(land_verdict '' "$a" "$a")"
  (( f == 0 )) && echo "ci-land-pr: self-test ok"
  exit $f
fi

PR="${PR:?PR number}"
TESTED_TREE="${TESTED_TREE:-}"
VERIFY_RUN_URL="${VERIFY_RUN_URL:-}"
VERIFY_RUN_ID="${VERIFY_RUN_ID:-}"
REPAIR="${REPAIR:-0}"
LAND_WAIT_S="${LAND_WAIT_S:-90}"

state=""; sha=""
deadline=$(( $(date +%s) + LAND_WAIT_S ))
while :; do
  read -r state sha < <(gh pr view "$PR" -R "$GH_REPO" --json state,mergeCommit --jq '"\(.state) \(.mergeCommit.oid // "")"' 2>/dev/null || echo "")
  [[ "$state" == MERGED && -n "$sha" ]] && break
  [[ "$state" == CLOSED ]] && break
  (( $(date +%s) >= deadline )) && break
  sleep 5
done

mtree=""
[[ -n "$sha" ]] && mtree="$(gh api "repos/$GH_REPO/git/commits/$sha" --jq '.tree.sha' 2>/dev/null || true)"
verdict="$(land_verdict "${state:-}" "$TESTED_TREE" "$mtree")"
echo "land: PR #$PR state=${state:-?} merge=${sha:-none} tested_tree=${TESTED_TREE:-?} merge_tree=${mtree:-?} -> $verdict"

case "$verdict" in
  publish)
    summary="This commit is the rebase of PR #$PR onto main and its tree ($mtree) is exactly the tree the PR's verify run tested (the PR branch with main merged in). Same content, same run, same verdict. Run: $VERIFY_RUN_URL"
    if gh api -X POST "repos/$GH_REPO/check-runs" \
         -f name=verify -f head_sha="$sha" -f status=completed -f conclusion=success \
         -f details_url="$VERIFY_RUN_URL" -f external_id="${VERIFY_RUN_ID:-0}" \
         -f 'output[title]=verify — the same tree the PR run verified' -f "output[summary]=$summary" >/dev/null 2>&1; then
      echo "published a verify success check-run on $sha (tree $mtree = tested tree)"
    else
      echo "::warning::could not publish the verify check-run on $sha — main's tip carries no verdict; the hourly judges it"
    fi ;;
  differs)
    echo "::notice::main moved between verify and landing: merge tree $mtree != tested tree $TESTED_TREE. NO verdict published — a verdict never follows a tree it did not judge; the hourly full suite judges main." ;;
  deferred)
    echo "::notice::PR #$PR was not merged within ${LAND_WAIT_S}s — the armed auto-merge or the next attempt lands it; nothing to decorate yet" ;;
  closed)
    echo "::notice::PR #$PR is closed, not merged — nothing landed" ;;
  *)
    echo "::warning::could not read the landing (state=${state:-?} merge=${sha:-?} trees ${TESTED_TREE:-?}/${mtree:-?}) — nothing published, nothing dispatched on a guess" ;;
esac

if [[ "$state" == MERGED ]]; then
  # ⚠ A MERGE MADE WITH GITHUB_TOKEN, OR BY AUTO-MERGE AFTER ONE, CREATES NO PUSH RUN. Ask by name.
  if gh workflow run ci.yml -R "$GH_REPO" --ref main -f coverage_on_merge=true >/dev/null 2>&1; then
    echo "dispatched coverage on merge for main"
  else
    echo "::warning::the coverage dispatch failed — pr-refresh.sh dispatches it for any tip that has none"
  fi
  if [[ "$REPAIR" == 1 ]]; then
    if gh workflow run ci.yml -R "$GH_REPO" --ref main -f full_suite_on_main=true >/dev/null 2>&1; then
      echo "repair merged — dispatched the full suite on main; the block lifts on its green"
    else
      echo "::warning::repair merged but the full-suite dispatch failed — the next :07 hourly is the verdict"
    fi
  fi
fi
exit 0
