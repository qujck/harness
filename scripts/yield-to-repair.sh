#!/usr/bin/env bash
# scripts/yield-to-repair.sh — while a repair-main PR is open and main is red, nothing else should
# hold a CI seat: the hourly yields its run, and queued verifies that can only be refused at the gate
# are cancelled so the repair's verify moves up. Run from ci.yml; read-only by hand.
# (infra_the_hourly_yields_and_the_refresher_stops_requeuing_while_a_repair_pr_is_open)
#
#   bash scripts/yield-to-repair.sh --hourly <run-id>   # in the hourly job: cancel THIS run if a repair PR is open
#   bash scripts/yield-to-repair.sh --doomed            # cancel QUEUED verify runs of non-repair PRs while blocked
#   bash scripts/yield-to-repair.sh --doomed --dry-run  # say what --doomed would cancel, cancel nothing
#   bash scripts/yield-to-repair.sh --self-test
#
# ── WHY ─────────────────────────────────────────────────────────────────────────────────────────
# First live use of the repair lane, 2026-09-06 (#8199): its repair job started 40 minutes late,
# behind the 17:07Z hourly on canary-box — an hourly testing a main everyone already knew was red —
# and its verify was queued on forge-box for over an hour behind re-queued verifies that were every
# one of them going to be refused at the merge-queue gate. Roughly eighty minutes of a four-hour red
# were spent in queues whose work could not change the outcome.
#
# ── THE TWO RULES, AND THEIR PRECONDITIONS ─────────────────────────────────────────────────────
#   --hourly  yields ONLY while an open PR carries the repair-main label. Not "while main is red":
#             a red with nobody repairing it still needs the hourly, because the hourly is what
#             would notice a flake clearing or a second red arriving. A yielded run is CANCELLED
#             (gh run cancel on itself), which full-suite-gate.sh reads as a gap, never a verdict —
#             a green no-op would have read as GREEN MAIN and lifted the block on nothing.
#   --doomed  cancels ONLY queued (never running) verify runs, ONLY of PRs without the label, ONLY
#             while full-suite-gate.sh says BLOCK and at least one repair-main PR is open. Each
#             cancelled PR gets one comment saying why and that pr-refresh re-queues it when the
#             block clears (pr-refresh.sh leaves cancelled runs alone while blocked, by design).
#             ⚠ A cancelled run is invisible to any sweep keyed on conclusion == FAILURE (Carl,
#             2026-09-06, after the first hand-run of this mode), which is why the comment names
#             the run id and the hand remedy — `gh run rerun <id>`. (`--failed` recovers a
#             cancelled run too: reasoned otherwise from its man page, then DRIVEN on three runs
#             the same night — the experiment beat the documentation.)
#
# ⚠ THIS IS THE ONE PLACE IN THE REPO THAT CANCELS OTHER PEOPLE'S RUNS, and the runs it cancels are
# the ones that CANNOT pass — the gate refuses every non-repair PR while main is red. CLAUDE.md's
# rule ("do not kill another agent's run") is about runs that could produce a verdict; these cannot.
#
# ── EXIT CODES ──────────────────────────────────────────────────────────────────────────────────
#   0  did what the mode says (including "nothing to do")
#   2  COULD NOT LOOK — no gh, a failed query. Never treated as "nothing to cancel".
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/harness-env.sh"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
. "$(dirname "${BASH_SOURCE[0]}")/lib/selftest-flag.sh" 2>/dev/null || true
REPO="${GITHUB_REPOSITORY:-${HARNESS_REPO:-owner/repo}}"
LABEL="${REPAIR_LABEL:-repair-main}"

# ── the pure half ───────────────────────────────────────────────────────────────────────────────
# doomed_verdict <run-status> <head-branch> <repair-branches (space-separated)> -> cancel | keep-<why>
doomed_verdict() {
  local status="$1" branch="$2" repair="$3" b
  [[ "$status" == queued ]] || { printf 'keep-not-queued'; return 0; }
  [[ "$branch" == main ]] && { printf 'keep-main'; return 0; }
  [[ -n "$branch" ]] || { printf 'keep-no-branch'; return 0; }
  for b in $repair; do [[ "$branch" == "$b" ]] && { printf 'keep-repair'; return 0; }; done
  printf 'cancel'
}
# hourly_verdict <open-repair-pr-numbers> -> yield | run
hourly_verdict() { [[ -n "${1//[[:space:]]/}" ]] && printf 'yield' || printf 'run'; }

# ── the self-test ───────────────────────────────────────────────────────────────────────────────
if [[ "${1:-}" == "--self-test" ]]; then
  fails=0
  t() { local want="$1" desc="$2"; shift 2; local got; got="$("$@")"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  t cancel          'a queued verify on an ordinary branch is doomed'            doomed_verdict queued feat_x-pt1 'fix_red-pt1'
  t keep-repair     'NEGATIVE CONTROL: the repair PR'"'"'s own queued verify is kept' doomed_verdict queued fix_red-pt1 'fix_red-pt1 other-repair'
  t keep-not-queued 'NEGATIVE CONTROL: a RUNNING verify is never cancelled'      doomed_verdict in_progress feat_x-pt1 'fix_red-pt1'
  t keep-not-queued 'NEGATIVE CONTROL: a completed run is not touched'           doomed_verdict completed feat_x-pt1 'fix_red-pt1'
  t keep-main       'NEGATIVE CONTROL: a run on main (canary) is kept'           doomed_verdict queued main 'fix_red-pt1'
  t keep-no-branch  'NEGATIVE CONTROL: a run with no branch is kept, not guessed' doomed_verdict queued '' 'fix_red-pt1'
  t cancel          'two repair branches: an unrelated queued verify is still doomed' doomed_verdict queued feat_y 'fix_a-pt1 fix_b-pt1'
  t yield           'hourly: one open repair PR means yield'                     hourly_verdict '8199'
  t yield           'hourly: several open repair PRs mean yield'                 hourly_verdict $'8199\n8203'
  t run             'hourly NEGATIVE CONTROL: no open repair PR means run'       hourly_verdict ''
  t run             'hourly NEGATIVE CONTROL: whitespace is not a PR'            hourly_verdict $' \n'
  exit $fails
fi

# ── the impure half ─────────────────────────────────────────────────────────────────────────────
command -v gh >/dev/null 2>&1 || { echo "yield-to-repair: COULD NOT LOOK — no gh" >&2; exit 2; }
open_repair_prs() { # -> "number<TAB>headRefName" per open labelled PR
  gh pr list -R "$REPO" --label "$LABEL" --state open --limit 20 --json number,headRefName \
    --jq '.[] | "\(.number)\t\(.headRefName)"' 2>/dev/null
}
mode="${1:-}"; dry=0; [[ "${2:-}" == "--dry-run" || "${3:-}" == "--dry-run" ]] && dry=1
case "$mode" in
  --hourly)
    run_id="${2:-}"; [[ "$run_id" =~ ^[0-9]+$ ]] || { echo "usage: $0 --hourly <run-id>" >&2; exit 2; }
    prs="$(open_repair_prs)" || { echo "yield-to-repair: COULD NOT LOOK — gh pr list failed; running the hourly rather than guessing" >&2; exit 0; }
    if [[ "$(hourly_verdict "$prs")" == run ]]; then
      echo "yield-to-repair: no open $LABEL PR — the hourly runs"; exit 0
    fi
    printf 'yield-to-repair: yielding this hourly to the open repair PR(s): %s\n' "$(printf '%s\n' "$prs" | cut -f1 | sed 's/^/#/' | tr '\n' ' ')"
    echo "  (a cancelled hourly is a GAP to full-suite-gate.sh, never a verdict; the repair job needs this seat)"
    if gh run cancel "$run_id" -R "$REPO" 2>/dev/null; then
      # The cancellation lands asynchronously; wait for it rather than falling through to the suite.
      for _ in $(seq 1 60); do sleep 5; done
      echo "yield-to-repair: cancellation requested but this job is still running after 5 min — continuing" >&2
    else
      echo "yield-to-repair: could not cancel run $run_id — running the hourly rather than sitting on the seat" >&2
    fi
    exit 0 ;;
  --doomed)
    prs="$(open_repair_prs)" || { echo "yield-to-repair: COULD NOT LOOK — gh pr list failed" >&2; exit 2; }
    [[ -n "${prs//[[:space:]]/}" ]] || { echo "yield-to-repair: no open $LABEL PR — nothing is doomed"; exit 0; }
    if bash scripts/full-suite-gate.sh >/dev/null 2>&1; then rc=0; else rc=$?; fi
    [[ "$rc" == 1 ]] || { echo "yield-to-repair: the merge-queue gate does not say BLOCK (rc=$rc) — cancelling nothing"; exit 0; }
    repair_branches="$(printf '%s\n' "$prs" | cut -f2 | tr '\n' ' ')"
    runs="$(gh api "repos/$REPO/actions/runs?event=pull_request&status=queued&per_page=100" \
      --jq '.workflow_runs[] | "\(.id)\t\(.status)\t\(.head_branch)"' 2>/dev/null)" \
      || { echo "yield-to-repair: COULD NOT LOOK — the runs query failed" >&2; exit 2; }
    n=0
    while IFS=$'\t' read -r rid status branch; do
      [[ -n "${rid:-}" ]] || continue
      v="$(doomed_verdict "$status" "$branch" "$repair_branches")"
      [[ "$v" == cancel ]] || { printf '  keep %s (%s) — %s\n' "$rid" "$branch" "$v"; continue; }
      num="$(gh pr list -R "$REPO" --head "$branch" --state open --limit 1 --json number --jq '.[0].number // empty' 2>/dev/null)"
      if [[ "$dry" == 1 ]]; then printf '  would cancel run %s (%s, PR #%s) — doomed while main is red\n' "$rid" "$branch" "${num:-?}"; continue; fi
      if gh api -X POST "repos/$REPO/actions/runs/$rid/cancel" >/dev/null 2>&1; then
        n=$((n+1)); printf '  cancelled run %s (%s, PR #%s)\n' "$rid" "$branch" "${num:-?}"
        [[ -n "$num" ]] && gh pr comment "$num" -R "$REPO" --body "⚠ **Your queued \`verify\` was cancelled to let a repair through — nothing is wrong with this PR.** Main's full suite is red and the merge-queue gate refuses every PR until the repair (label \`repair-main\`, $(printf '%s\n' "$prs" | cut -f1 | sed 's/^/#/' | tr '\n' ' ')) lands, so this run could only have spent the seat to be refused. \`pr-refresh.sh\` re-queues it as soon as the block clears (a cancelled required check with no successor is exactly what its re-queue arm looks for); if the refresher is stopped, the hand remedy is \`gh run rerun $rid\` (\`--failed\` works on a cancelled run too — driven 2026-09-06). (docs/runbooks/main-is-red.md)" >/dev/null 2>&1 || true
      else
        printf '  could not cancel run %s (%s)\n' "$rid" "$branch" >&2
      fi
    done <<<"$runs"
    printf 'yield-to-repair: %s doomed queued verify run(s) cancelled ahead of the repair\n' "$n"
    exit 0 ;;
  *) echo "usage: $0 --hourly <run-id> | --doomed [--dry-run] | --self-test" >&2; exit 2 ;;
esac
