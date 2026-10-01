# CI lanes — how a PR reaches `main`

*(feat_harness_ci_routes_a_pr_by_diff_runs_a_test_subset_and_gates_merges_on_the_hourly_full_suite)*

**Workflows:** `.github/workflows/ci.yml` (route → verify → land, + repair) and
`.github/workflows/hourly-full-suite.yml`. **Config:** the CI block of `harness.env`; the runner labels
are ALSO GitHub repository variables of the same names (a workflow cannot read `harness.env`).
**Required contexts on the ruleset:** `route` and `verify` (`REQUIRED_CHECKS`), set in GitHub by hand once.

## The lanes

| job | runner label | what it does |
|---|---|---|
| `route` | `ROUTE_LABEL` | reads the diff: entirely inside `LEDGER_LANE_PATHS_RE` → the **ledger lane** (`LEDGER_LANE_LABEL`, never the seat); otherwise the **merge seat** (`MERGE_SEAT_LABEL`). Asks `full-suite-gate.sh` whether `main` is red (rc 1 → this PR runs the FULL suite). Turns the changed paths into the browser subset (`ui-relevant-specs.sh`): no surface path → no browser run; an unmapped surface path → everything. |
| `verify` | the runner route chose | merges the base branch in (`ci-merge-pr-base.sh`) or stops; keys its compose project on **the runner name** (`ci-stack-project.sh` — two runners can share a label, and the seeded project found that out with two verifies on one project); runs `scripts/verify.sh` (tiers under `VERIFY_STEP_BUDGET_S`), then the browser subset (`UI_GREP`), the cost budget, then the gate. |
| `land` | `ROUTE_LABEL` | `gh pr merge --rebase --delete-branch`, then `ci-land-pr.sh` carries the verdict onto `main`. |
| `repair` | `CANARY_LABEL` | only on a PR labelled `repair-main`: cancels the doomed verifies queued ahead (`yield-to-repair.sh --doomed`), proves the **full** suite on the PR itself. |
| `hourly full suite` | `CANARY_LABEL` | every hour on `main`: `VERIFY_FULL=1 RUN_UI=1 scripts/verify.sh`. Yields to an open repair PR. Its own concurrency group, `cancel-in-progress: false`. |

## The merge seat

GitHub runs one job per runner, so "one verify at a time" holds exactly while the registry carries
`MERGE_SEAT_RUNNERS` runners with `MERGE_SEAT_LABEL`. `scripts/check-merge-seat-count.sh` asserts the
DECLARED count (the seeded project asserted "one" and then ran a second seat on purpose for a week:
the probe alerted on its own trial). An unreadable registry is CANNOT TELL (exit 2), never zero.

## The gate — `scripts/full-suite-gate.sh`, exit 0 / 1 / 2

Reads the scheduled runs of `FULL_SUITE_WORKFLOW` on `main`, judges on the **newest concluded** run
(a newer run supersedes an older red; a stale newest — older than `FULL_SUITE_TIMEOUT_MIN` — is cannot
tell), and names the run id and sha. **0** = main is green, proceed. **1** = main is RED: the merge
queue is blocked; `route` promotes the PR to the full suite so it can carry the evidence. **2** =
CANNOT TELL (the API, a stale run, no run): the workflow PROCEEDS with a warning, because a broken
query must never halt the factory — and the safety net is absent for that run. The policy is written
beside both calls in `ci.yml`, and `scripts/check-workflow-shape.sh` fails the build if it is removed.
The gate must run from a real checkout: it orders runs by commit ancestry.

## When `main` is red

[main-is-red.md](main-is-red.md): raise the ticket, fix on a branch, open the PR with
`--label repair-main`. The repair job proves the full suite on that PR; the gate accepts a repair
PR's own result; when it lands, the next hourly (or a dispatch: `gh workflow run hourly-full-suite.yml`)
turns the gate green and the queue moves.

## Replace, never re-run

A re-run executes the workflow definition the run was CREATED with. After any change to a workflow
file, push a new commit (or close/reopen the PR); never re-run an old run and read its verdict as the
new pipeline's. The header of `ci.yml` says so and the shape check asserts the sentence.

## The subset is safe only with the hourly

`scripts/ui-map.txt` maps changed paths to spec-name fragments; `scripts/ui-relevant-specs.sh` emits
the `--grep` ERE or `__ALL__`. Two properties: an unmapped surface path runs everything (the failure
mode of a missing row is SLOW, never UNTESTED); `UI_ALWAYS_SPECS` always run. Shared files every page
depends on (a global stylesheet, a string table, the harness config) stay unmapped by decision and are
listed in the map's header. All of that is true per PR and false system-wide: remove the hourly and
the map is a hole.

## Wiring a project (once)

1. Register runners with the labels in `harness.env`; set the same names as repository variables.
2. Ruleset on `main`: required status checks `route` and `verify`; linear history; auto-merge on.
3. `gh workflow run hourly-full-suite.yml` once, so the gate has a run to judge.
4. Open a docs-only PR (ledger lane) and a page PR (subset) and read the route log — the row's
   end-to-end items are driven on that project, not on the template.
