#!/usr/bin/env bash
# scripts/check-workflow-shape.sh — the CI workflow keeps the SHAPE its header promises.
# (feat_harness_ci_routes_a_pr_by_diff_runs_a_test_subset_and_gates_merges_on_the_hourly_full_suite)
#
#   bash scripts/check-workflow-shape.sh              # the real .github/workflows/*.yml
#   bash scripts/check-workflow-shape.sh --self-test
#
# The invariants (each learned the expensive way in the seeded project), asserted on the TEXT of the
# workflow so a refactor cannot drop one silently:
#   1. jobs route, verify, land, repair exist, and route+verify are the required contexts (REQUIRED_CHECKS)
#   2. one concurrency group per (event_name, ref), cancel-in-progress ONLY for pull_request — a push to
#      main must never cancel another push to main (a late merge silently cancelled the run that would
#      have proven it)
#   3. verify runs on the runner ROUTE chose (needs.route.outputs.runner), and keys its compose project on
#      the RUNNER NAME through scripts/ci-stack-project.sh — never on the label two runners can share
#   4. verify merges the PR's base in first (scripts/ci-merge-pr-base.sh), then calls the full-suite gate
#      and writes the 0/1/2 policy BESIDE the call (the words "proceeding" and "CANNOT TELL" near rc=2)
#   5. land merges by REBASE (gh pr merge --rebase); the hourly workflow has a schedule, its own
#      concurrency group with cancel-in-progress false, and yields to a repair PR
#   6. the header carries the replace-never-rerun rule (a re-run executes the OLD definition)
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/harness-env.sh"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRED_CHECKS="${REQUIRED_CHECKS:-route verify}"

# shape_findings <ci.yml> <hourly.yml> -> one finding per line (empty = the shape holds). Pure over the files' text.
shape_findings() {
  local ci="$1" hourly="$2" j
  [[ -r "$ci" ]] || { echo "ci workflow missing: $ci"; return 0; }
  for j in route verify land repair; do awk -v j="  $j:" 'index($0,j)==1{f=1} END{exit !f}' "$ci" || echo "job '$j' missing"; done
  for j in $REQUIRED_CHECKS; do awk -v j="    name: $j" 'index($0,j)==1{f=1} END{exit !f}' "$ci" || echo "required context '$j' is not a job name"; done
  awk '/^concurrency:/{c=1} c && /group:.*github\.event_name.*github\.ref/{g=1} END{exit !g}' "$ci" || echo "concurrency group is not keyed on event_name AND ref"
  awk '/cancel-in-progress: \$\{\{ github\.event_name == .pull_request. \}\}/{f=1} END{exit !f}' "$ci" || echo "cancel-in-progress is not limited to pull_request"
  awk '/runs-on:.*needs\.route\.outputs\.runner/{f=1} END{exit !f}' "$ci" || echo "verify does not run on the runner route chose"
  awk '/ci-stack-project\.sh "\$\{RUNNER_NAME/{f=1} END{exit !f}' "$ci" || echo "verify does not key its stack on RUNNER_NAME via ci-stack-project.sh"
  awk '/run: bash scripts\/ci-merge-pr-base\.sh/{f=1} END{exit !f}' "$ci" || echo "verify does not merge the PR's base first (ci-merge-pr-base.sh)"
  awk '/FULL_SUITE_CALLER: verify/{g=1} g && /full-suite-gate\.sh/{c=1} g && c && /2\) .*(proceeding|CANNOT TELL)/{p=1} END{exit !(g&&c&&p)}' "$ci" || echo "the full-suite gate is not called with the proceed-on-2 policy written beside it"
  awk '/if gh pr merge .* --rebase --delete-branch/{f=1} END{exit !f}' "$ci" || echo "land does not merge by rebase"
  awk '/REPLACE, NEVER RE-RUN/{f=1} END{exit !f}' "$ci" || echo "the header no longer states replace-never-rerun"
  [[ -r "$hourly" ]] || { echo "hourly workflow missing: $hourly"; return 0; }
  awk '/^\s*schedule:/{f=1} END{exit !f}' "$hourly" || echo "the hourly workflow has no schedule"
  awk '/cancel-in-progress: false/{f=1} END{exit !f}' "$hourly" || echo "the hourly workflow cancels in progress (a scheduled run must never cancel another)"
  awk '/yield-to-repair\.sh --hourly/{f=1} END{exit !f}' "$hourly" || echo "the hourly workflow does not yield to a repair PR"
  awk '/VERIFY_FULL=1 RUN_UI=1/{f=1} END{exit !f}' "$hourly" || echo "the hourly workflow does not run the FULL suite"
}

if selftest_is_flag "${1:-}"; then
  fails=0; d="$(mktemp -d)"
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; fails=1; fi; }
  _t "the shipped workflows hold every invariant" "" "$(shape_findings "$ROOT/.github/workflows/ci.yml" "$ROOT/.github/workflows/hourly-full-suite.yml")"
  sed 's/cancel-in-progress: \${{ github.event_name == .pull_request. }}/cancel-in-progress: true/' "$ROOT/.github/workflows/ci.yml" > "$d/ci.yml"
  _t "cancel-in-progress widened to every event is a finding" "cancel-in-progress is not limited to pull_request" "$(shape_findings "$d/ci.yml" "$ROOT/.github/workflows/hourly-full-suite.yml")"
  sed 's/ci-stack-project\.sh "\${RUNNER_NAME:-}"/ci-stack-project.sh "forge-box"/' "$ROOT/.github/workflows/ci.yml" > "$d/ci2.yml"
  _t "a stack keyed on a label instead of RUNNER_NAME is a finding" "verify does not key its stack on RUNNER_NAME via ci-stack-project.sh" "$(shape_findings "$d/ci2.yml" "$ROOT/.github/workflows/hourly-full-suite.yml")"
  awk '!/2\) echo "::warning::the full-suite gate CANNOT TELL/' "$ROOT/.github/workflows/ci.yml" > "$d/ci3.yml"
  _t "a gate call without the proceed-on-2 policy beside it is a finding" "the full-suite gate is not called with the proceed-on-2 policy written beside it" "$(shape_findings "$d/ci3.yml" "$ROOT/.github/workflows/hourly-full-suite.yml")"
  sed 's/--rebase --delete-branch/--squash --delete-branch/' "$ROOT/.github/workflows/ci.yml" > "$d/ci4.yml"
  _t "a squash merge is a finding (rebase is the rule)" "land does not merge by rebase" "$(shape_findings "$d/ci4.yml" "$ROOT/.github/workflows/hourly-full-suite.yml")"
  sed 's/cancel-in-progress: false/cancel-in-progress: true/' "$ROOT/.github/workflows/hourly-full-suite.yml" > "$d/h.yml"
  _t "an hourly that cancels in progress is a finding" "the hourly workflow cancels in progress (a scheduled run must never cancel another)" "$(shape_findings "$ROOT/.github/workflows/ci.yml" "$d/h.yml")"
  _t "a missing workflow is a finding, not a pass" "ci workflow missing: $d/none.yml" "$(shape_findings "$d/none.yml" "$d/h.yml")"
  rm -rf "$d"
  (( fails == 0 )) && echo "check-workflow-shape: self-test ok" || { echo "check-workflow-shape: self-test FAILED" >&2; exit 1; }
  exit 0
fi
out="$(shape_findings "$ROOT/.github/workflows/ci.yml" "$ROOT/.github/workflows/hourly-full-suite.yml")"
if [[ -n "$out" ]]; then printf 'check-workflow-shape: FAIL\n%s\n' "$out" | sed '2,$s/^/  /' >&2; exit 1; fi
echo "check-workflow-shape: ok — route → verify → land (+ repair), the gate's 0/1/2 policy beside the call, the hourly with its own group"
