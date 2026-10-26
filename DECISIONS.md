# DECISIONS

> Append-only architecture log. One entry per significant choice another agent might re-debate. **Binding until superseded by a later entry.** Newest at the bottom.

---

## {{DATE}} — Adopted the agent harness

Adopted the init/verify/handoff harness (this kit) — an implementation of the
**Learn Harness Engineering** framework (WalkingLabs, L01–L12). Rationale: make
the correct workflow the path of least resistance and make self-grading
impossible — `scripts/verify.sh` exit 0 is the only Definition of Done (L09);
`scripts/handoff.sh` gates session exit on a clean state (L12); the git
pre-commit hook is the hard enforcement point (a primitive, not a document, L08).

Parallel-safe by default: the work queue is a per-ticket `features/` directory
(no merge conflicts on the queue), `depends_on`/ready-frontier orders the work,
and the append-only logs union-merge — so independent agents on separate clones
never collide. Running several worktrees on one machine (per-stream container
stacks) is opt-in via `PER_STREAM_STACKS=1`.

Deliberately deferred for now: **L11 — observability inside the harness** (task
traces / OpenTelemetry, sprint contracts, evaluator rubrics, the
Planner→Generator→Evaluator split). Highest-ceiling lecture, heaviest to build;
revisit if/when the agent fleet and eval needs grow. The adoption path is written
up in `OBSERVABILITY.md` (with an opt-in `OBSERVABILITY` stub in `harness.env`).

## 2026-08-11 — union-merge is not a concurrency strategy; one file per writer is

**Decision.** Nothing in this harness relies on a `.gitattributes` merge driver. Every artifact that
two agents can write at the same time gets ONE FILE PER WRITER:

| artifact | was | is |
|---|---|---|
| completed tickets | `feature_list.archive.jsonl`, appended, `merge=union` | `features/archive/<id>.json` |
| session records | `PROGRESS.md`, appended, `merge=union` | `progress/<stamp>-<name>-<slug>.md` |
| live tickets | already one file per ticket | unchanged |

**Why.** ⚠ **GitHub's PR merge IGNORES `.gitattributes` merge drivers.** A local `git merge` honours
them, so the pattern tests clean on one machine and fails on the workflow this harness prescribes
(branch + PR). In the project this harness was extracted from it produced **two full PR re-rolls in
one day (2026-07-14)** before the cause was found: two agents archive different tickets, both append
a line, GitHub reports a conflict, and both have to re-roll.

**⚠ The failure mode is what makes this worth a decision rather than a fix.** The union driver does
not fail loudly or early — it works for the person who tests it, and only breaks once a second agent
exists, which is exactly when the harness is doing its job. Shipping it as advice meant handing
every adopter a defect that appears at the moment they start using the feature it was written for.

**What is deliberately NOT split:** `DECISIONS.md` remains a single append-only file. Entries are
rare and the log reads badly split across files, so the trade is accepted — but it is exposed to the
same conflict, and the answer when it happens is to keep both entries, not to add a merge driver.

**Supersedes** the `.gitattributes` comment that described the jsonl archive as unioning "cleanly".

## 2026-08-11 — the harness gains claims, identity, and a method for measuring

**Decision.** Three additions, each closing a gap that only appears once the harness is doing the
job it is adopted for.

**1. `scripts/feature-ticket.sh` — claims.** The harness advertised parallel agents and had no way
to take a ticket. ⚠ **A ticket status is not a lock**: two agents can both read `not_started`, both
write `in_progress`, and both start. Checking for a branch first is not a lock either — both can
look, both see nothing, both proceed. Exactly one operation here is atomic across machines:
`git push origin <id>`, which the remote **rejects** for the second pusher. The claim is therefore
the push, and everything else is bookkeeping around it. The branch is based on `origin/main`, never
on HEAD, so a claim cannot silently absorb another agent's unmerged commits.

**2. `scripts/lib/agent-name.sh` — identity.** Every ownership record is worthless if it says
"agent". ⚠ `.agent/name` names a **directory**, not a session: two agents sharing one checkout share
an identity, silently, with nothing else looking wrong. That is the concrete reason the harness
tells you to work in your own worktree.

**3. `METHOD.md` — the other half.** The scripts make the WORKFLOW hard to get wrong. METHOD is
about the MEASUREMENT, and it is the higher-value half per byte: **a broken test fails, a broken
measurement passes and you act on it.** Every rule in it is drawn from a real incident, and the two
that catch most of them are *could this instrument have produced the other answer* and *is this
count a window or a period*.

**⚠ Written while breaking two of its own rules, which is the argument for having it.** The refusal
message in `feature-ticket.sh` used backticks inside a double-quoted string — command substitution
— so it executed `release` and mangled itself; found only by driving the refusal path, which is the
path least likely to be exercised and most likely to be read when something has already gone wrong.
And a regex edit to `features/README.md` matched across a sentence boundary and corrupted the
paragraph it was fixing. Both were caught by looking at the output rather than at the diff.

**Not included, deliberately:** no takeover verb, no batch claims, no issue-tracker integration.
Those are conveniences. What is here is the part that makes concurrency SAFE.

## 2026-10-01 — The template catches up with the process it seeded: docs and roles first (child 1 of the template epic)

Owner, 2026-10-01: the template (this repo) is seven weeks and one whole process behind the project
it was seeded into, and he wants it current — "port the mechanisms too", and "for process it should
support jira for tickets". This child lands the DOCS: AGENTS.md rewritten to the current lifecycle
(a database ledger behind one verb set, with a Jira store to follow; identity from the session;
completion as three row writes after the merge, `Part of #N` never `Closes`; a session entry as a
row; every self-test invoked through one contract), the four role documents in generic form
(docs/roles/), the red-main runbook, and four METHOD rules learned since August. **What was
deliberately left:** the mechanisms themselves — each section that depends on one says "(arrives
with `<child-id>`)", and `scripts/check-docs-markers-match-landed-children.sh` fails the build if a
marker outlives its child (`docs/landed-children.txt`). The file ledger under `features/` stands
until the ticket-store child lands; the docs say so. The template's own `verify.sh` runs the marker
check (self-test and real) until the tier manifest arrives.


## 2026-10-01 — The ticket store is the ledger database, behind one verb set (template child 2)

`feat_harness_the_ledger_is_a_database_with_raise_groom_claim_amend_flip_archive_and_release_verbs`.
The file ledger under `features/` is gone (with `_features.sh` and `archive-passing.sh`); the store
is a Postgres per box under `infra/ledger-db/` — the seeded project's schema squashed into ONE
baseline (`001-baseline.sql`, 19 tables, 33 views, 66 functions, grants to `ledger_agent` /
`ledger_console` / `ledger_owner`) with a `000-roles.sql` that creates the group roles, and later
changes as numbered migrations applied by `ledger-migrate.sh`. `ledger-db.sh` is the port of the
seeded project's verbs with the project name parametrised (`HARNESS_PROJECT`, via
`scripts/lib/harness-env.sh`); its FILE-ERA verbs (`sync`, `mirror`, `regenerate`, `freshness`,
`export`) refuse by name — the template never had a file era. `scripts/lib/ticket-store.sh` is the
adapter: `TICKET_STORE=db|jira`, one verb contract, an unsupported verb exits 2 loudly, never a silent
pass. `feature-ticket.sh` keeps what a row cannot be — the pushed lock branch — and records the
claim on the row; a refused record takes the lock down again. A write needs a session identity
mapped by `agents/roster.json` (the onboarding script that fills it is child 4; until then the file
is edited in a PR). `init.sh` reads the frontier and `handoff.sh` the live claims from the ledger.
**Deliberately not ported:** the seeded project's 16,000-line `feature-ticket.sh` (its sync, repair
and board machinery is that project's migration history), its migration files 001–147 (replaced by
the baseline), and its exempt-gate runners (child 7). Self-tests: `ledger-db.sh` 96 arms + the
adapter's 7, `ledger-migrate.sh`, `feature-ticket.sh` 11 — all run by `verify.sh` step [0/3].

## 2026-10-01 — Jira is a ticket store behind the same verbs (template child 3)

`feat_harness_jira_is_a_ticket_store_behind_the_same_verbs`. Owner: "for process it should support
jira for tickets". NEW code, not a port: `scripts/lib/ticket_store_jira.py` (one method per verb,
the database store's verdict strings and exit codes), reached through the child-2 seam
(`scripts/lib/ticket-store.sh`, `TICKET_STORE=jira`). Assumptions stated in
`docs/ticket-store-jira.md` for the owner to correct: Jira Cloud, REST v3, email + API token in
`harness.env` (never in git — `scripts/check-no-committed-jira-token.sh`), one project per harness
project. The issue KEY is the ticket id so the branch-is-the-lock rule holds; the status map is DATA
validated against the project's real workflow before any write; requirement text lives in description
sections rewritten only by `amend`, with a comment naming who and why. Two transports: live (retries
429/503; a final failure is cannot-tell for a read, a refusal for a write) and fixture (an in-process
fake of exactly the endpoints the verbs use; `--live --record` regenerates it from a real project).
**Not yet run against a real Jira project** — the owner has not named one; the `--live` item on the
row stays open until he does. Carl relayed a docs-only reading of the owner's words
("just put a simple jira can be used in place of x, y, z and I will get it extended elsewhere");
asked directly, the owner chose "Keep the adapter", so the doc carries that short section AND the
adapter ships. 38 self-test arms + 5 for the token gate, both run by `verify.sh` step [0/3].

## 2026-10-01 — Identity comes from the session; a session entry is a row (template child 4)

`feat_harness_identity_comes_from_the_session_via_a_roster_and_session_entries_are_ledger_rows`.
Ported from the seeded project: `scripts/agent-onboard.sh` (register a roster row; PRINT the launch
line — the line is the deliverable), `scripts/progress.sh` (entries as rows: new · tail · list),
`scripts/check-no-new-progress-files.sh` (progress/ and PROGRESS.md are frozen history), the roster's
three populations (agents · machines · assistants, with their notes). NEW, not ported: `init.sh`'s
identity step (`scripts/lib/identity-gate.sh`, two pure decisions with arms): a session whose name
came from `.agent/name` or `$AGENT_NAME` is REFUSED with the launch line to use — the seeded
project's "kept from .agent/name" prompt is gone, because a directory's label is not evidence of who
is typing; a checkout with another agent's live marker is refused unless `ALLOW_SHARED_CHECKOUT=1`.
`handoff.sh` reads the store for this session's entry (`session-entries --mine --since <marker>`),
and says CANNOT TELL, not pass, when the store is unreachable. `verify.sh` runs the freeze gate for
REAL against the diff, not only its arms (the seeded project's lesson: a step that ran the arms and
never the gate let four files through). With `TICKET_STORE=jira`, an entry is a comment on the issue
`JIRA_SESSION_LOG_ISSUE` names (head line `[session-entry] <who>: <title>`), refused by name when unset.

## 2026-10-01 — CI routes a PR by diff, runs a subset, and gates merges on the hourly full suite (template child 5)

`feat_harness_ci_routes_a_pr_by_diff_runs_a_test_subset_and_gates_merges_on_the_hourly_full_suite`.
The SHAPE of the seeded project's 3,483-line pipeline, generic: `.github/workflows/ci.yml` (route →
verify → land, + a `repair-main` job; one concurrency group per event+ref with cancel-in-progress
only for pull_request; runner labels as repository VARIABLES mirroring harness.env) and
`hourly-full-suite.yml` (its own group, never cancelling). Ported as-is with the repo parametrised:
`full-suite-gate.sh` (270 arms green here; reads `FULL_SUITE_WORKFLOW=hourly-full-suite.yml`),
`ci-stack-project.sh` (project keyed on the RUNNER NAME), `ci-merge-pr-base.sh`, `ci-land-pr.sh`,
`yield-to-repair.sh`, `check-verify-cost-budget.sh`, `lib/bounded.sh`, `lib/gh-checks.sh`,
`verify-stages.sh`. NEW: `ui-relevant-specs.sh` (a small path-row selector with the seeded
project's two properties — an unmapped surface path runs everything; always-specs always run — and
the same map FORMAT; the by-content resolver and generated map are NOT ported), `ui-map.txt` as an
example with the deliberately-unmapped class documented, `check-merge-seat-count.sh` (asserts the
DECLARED count, the seeded project's lesson from its second-seat trial), `check-workflow-shape.sh`
(mutation arms), and `verify.sh` as the tiered runner with a per-tier budget (`VERIFY_STEP_BUDGET_S`),
`UI_ONLY`/`UI_GREP`/`VERIFY_FULL`. The gate's 0/1/2 contract and the proceed-on-2 policy are written
beside both calls in the workflow and asserted by the shape check. Dropped: `check-required-check-name.sh`
(it reads a classifier the template does not ship). **Not driven end to end on a real project**: the
template has no runners or ruleset; the row's end-to-end items stay open until a project wires it
(the runbook says how). This child gives the template a required check (`route`, `verify`), so the
earlier children's PRs may be armed once a project's ruleset names them.

## 2026-10-01 — Ops alerts are conditions: one email on failing, one on recovery (template child 6)

`feat_harness_ops_alerts_are_conditions_with_one_email_on_failing_and_one_on_recovery`. Ported:
`scripts/lib/ops-alert.sh` + `scripts/lib/ops_alert_machine.py` (the condition contract of the
seeded project's 2026-09-28 decision: [FAILING] once, [RECOVERED] once it has held the settle
window, [FLAPPING] at the fifth transition in an hour and then silence; a send that fails does not
advance state) with the shared vectors in `scripts/testdata/ops-alert-conditions.json` (12 scenarios
— the twelfth is the two-senders flap), `scripts/ops-alerts.sh` (the durable queue), and the
OnFailure hook `scripts/ops-alert-unit-failure.sh`. Changed on purpose: the transport is CONFIG
(`ALERT_TRANSPORT=none|resend|post`, addresses from `harness.env`, the key from the monitoring
dir's `.env`), nothing project-named in the library; and the two-senders defect is closed by design
— `ops_alert_state_dir` resolves ONE location (explicit, `ALERT_STATE_DIR`, `$PLATFORM_VAR`,
`~/.local/state/<project>/alerts`) with no second fallback and REFUSES to run (exit 2) when it
cannot create it; the queue lives beside it. NEW: `scripts/systemd/*.in` templates
(`unit-failure@.service`, `alerts-settle.{service,timer}`) rendered and installed by
`scripts/install-units.sh` (user scope; its self-test proves no placeholder survives and every service
names the hook), and `scripts/ops-alerts-settle.sh` (the settle tick + the sweeper that turns a
healthy unit into a recovery reading). The seeded project's platform-paths/installer (388 lines,
44 couplings) are not ported. The throwaway-box drive of the installed units is recorded below once
run.

### The drive (2026-10-01, this box, user scope, scratch project `hdemo`, `ALERT_TRANSPORT=none`)

`install-units.sh` rendered and installed `hdemo-unit-failure@.service` and `hdemo-alerts-settle.{service,timer}`.
A probe unit (`ExecStart=/bin/sh -c 'test -f …/healthy'`, `OnFailure=hdemo-unit-failure@%n.service`) was started
with the file absent, then with it present. The journal, filtered on the contract words, shows exactly two lines:

    12:17:03  [FAILING]   unit-failed:hdemo-probe.service   (the hook, on the failed run)
    12:32:04  [RECOVERED] unit-failed:hdemo-probe.service   (the settle tick: the 12:22 tick's sweep read the unit
                                                              `inactive` = healthy and recorded the recovery; it was
                                                              announced once it had held the 10-minute settle)

Three settle ticks between them (12:22, 12:27, 12:32) announced nothing. The scratch units were then disabled and
removed. **A finding on the way:** my drive of a mistyped flag (`--slef-test`) against `install-units.sh` fell
through to the real action and installed `harness-*` units on the box (removed) — the fall-through child 7's
refusal now closes.
## 2026-10-01 — Self-tests follow one flag contract and a tier manifest that verify runs (template child 7)

`feat_harness_self_tests_follow_one_flag_contract_and_a_tier_manifest_that_verify_runs`. Ported:
`scripts/lib/selftest-flag.sh` (already here since child 2) gains `selftest_reject_typo`;
`scripts/check-selftests-are-invoked.sh` (an actual invocation is evidence, a prose mention never
counts; `--list` / `--list-stack` feed `verify.sh`); `scripts/check-selftest-flag-contract.sh` with its
legacy list EMPTIED (the ratchet starts at zero here); `scripts/selftest-tiers.txt` in the seeded
project's FORMAT with the template's 38 rows (`verify` | `stack` for the ledger's throwaway-Postgres
arms | `nowhere` with a reason for sourced libraries whose arms run inside a parent's). NEW:
`scripts/check-steps-invoke-their-scripts.sh` — the generic form of the seeded project's lesson
(fix_the_progress_freeze_gate_let_four_progress_files_onto_main_after_the_cutover): a `step "… —
scripts/x.sh"` beneath which only `x.sh --self-test` runs is a broken promise, named; positive and
negative controls. `verify.sh` now runs EXACTLY the manifest's verify tier (fails on an empty list)
and then every gate for real as its own step. **Measured on the way, and it is why
`selftest_reject_typo` exists:** before it, `--slef-test` fell through on 19 of the 35 enrolled
scripts, 14 of them exiting 0; one of those fall-throughs (`install-units.sh`) INSTALLED units on the
developer's box during the drive. After: every enrolled script exits 2 on the typo (37 of 37). Three
template scripts (the marker gate, `verify.sh`, `agent-name.sh`) parsed the flag by hand and now go
through the contract. Not ported: `check-verify-steps-reach-the-failure-reporter.sh` (it reads a
CI step the template's workflow does not have). **Wired on the way:** the ported `verify-stages.sh`
(the stage report the full-suite gate renders — "Playwright: NOT RUN — stopped at static checks") is
now sourced by `verify.sh`: `vs_init` at the start, `vs_begin`/`vs_skip` per tier, `vs_finish` on
exit, and `VERIFY_PLANT_RED=<stage>` plants a red so the library's self-test drives a REAL run (the
harness step is skipped in a planted run, so it cannot recurse into itself); the verify, repair and
hourly jobs publish the report on failure (job summary, the "verify stages" check-run the gate reads).

## 2026-10-01 — A machine-wide agent stack cap, and each agent's context published for the others (template child 8)

`feat_harness_a_machine_wide_agent_stack_cap_and_each_agents_context_published_for_the_others`.
Ported: `scripts/lib/agent-stacks.sh` + `scripts/agent-stacks.sh` (the cap counts live compose
projects with an override file and a running `STACK_HEALTH_SERVICE`; the listing says why each entry
is or is not counted; the CI seat `<project>_ci*` is exempt by name; a declared `INFRA_STACK_PROJECTS`
list is exempt and named — the seeded project's fix for counting its permanent test stack as a
developer; the self-test keeps the seeded project's real `docker compose ls` shapes as fixtures with
their config pinned inside the self-test), `init.sh` refuses a stack past the cap and never stops one,
`scripts/agent-context.sh` (`--me` from the session identity). NEW: `docs/context-publisher.md` (the
contract), `scripts/examples/statusline-publish.sh` (an example the owner adapts — the real status
line is his, outside the repo), AGENTS.md rule 0a with the owner's sentence verbatim and dated, and
`scripts/check-context-is-never-a-reason-to-do-less.sh` (grep for the forbidden shapes, with positive
and negative controls; the rule's own quotation is exempt by marker).

**Driven on this box (2026-10-01):** two stub agent stacks (`harness_stub-a/b`, an `api` service and
an override file), a declared infrastructure stack (`my-infra-stack`) and a CI-named stack
(`harness_ci_forge-box`). The listing showed the CI stack as the reserved seat, the infrastructure
stack as "NOT counted: declared infrastructure (my-infra-stack in INFRA_STACK_PROJECTS)", and the stubs
as agents; `agent-stacks.sh --check` from a newcomer's directory with `AGENT_STACK_LIMIT=2` exited 1,
named every holder (the box's real agents and the stubs), printed "nothing here is killed", and all
four stub containers were still running afterwards; they were then torn down by hand. The example
publisher, fed a status-line payload, wrote the contract's JSON and `agent-context.sh` rendered it.

## 2026-10-19 — The developer proves their change; the tester attacks it instead of re-running the developer's evidence (ported from the seeded project)

The seeded project's owner asked (2026-10-18) *"is there a clear separation between what a dev tests and
what a tester tests?"*: nothing separated them, so at the end of a ticket the tester re-ran the developer's
specs, budgets and gates. The defects on the incident ticket came from different eyes (the tester's own
mutants and a rendered sweep of every page; the reviewer's code read), not from the repeat. Ported into
`docs/roles/tester.md`, `docs/roles/developer.md` and `docs/roles/head-of-testing.md`: (1) the developer
proves their own change, with each handover reading as full sha, command, exit code and counts, a control
red on the old code, and what the tests do not cover; (2) the tester checks the handover, re-runs once only
the items that need their hands or that the handover lacks, and spends the rest attacking the change
(own mutants, other surfaces and states, a rendered sweep, the named limits); (3) the tester's report lists
the items re-run, the items taken from the handover and what the attack covered; (4) the head of testing
decides the split where it is not obvious. The seeded project gates a PR on a ledger sign-off verb; this
template has no such verb, so the rule is stated for the tester's report, not a verdict row.

## 2026-10-23 — The team grows and shrinks per ticket: spawn and bench, and a tester per ticket (ported from the seeded project)

**Decision.** Developers and testers live by four steps, and only the first and last write the roster:
**onboard** (`agent-onboard.sh`, unchanged: the row and identity, committed on `main`), **spawn**
(`scripts/agent-spawn.sh`: an onboarded, active developer or tester with no running session starts for one
ticket), **bench** (`scripts/agent-bench.sh`: once that ticket's PR merges, its session stops; name, identity
and worktree stay), **retire** (permanent, unchanged; a retired name is still never reused). The onboarded
developers and testers ARE the pool: there is no name-pool setting, and a benched agent coming back is the
same identity, not a reuse, so the never-reuse rule stands. One agent per ticket, one ticket per agent; bench
at the merge, not at a release; the work picks the model, never the cost (`docs/roles/delivery-lead.md`,
"The size of the team").

**Testers.** A tester is no longer under the head of testing: the delivery lead starts one per ticket and
routes it, it owns what is true about that ticket and decides the split between the developer's proof and its
attack. The head of testing stays a required role owning what is true about the system (the capacity and
performance record, pre-prod, new testing requirements, reading measurements that drive decisions), and runs
no tests and directs no testers.

**Ported** (behaviour and test cases, not code) from the seeded project's `agent-spawn` / `agent-bench`: the
random pick with `--name` to start exactly the dry run's name, `--ticket` and `--model` validation (a ticket id
is a ledger id or a Jira key), `--dry-run`, and bench's refusals mapped onto harness facts: a claim on the
board instead of a ticket file, the agent's own `<project>-<name>` worktree (exact name, not a substring), and
a session entry since the session started (`ledger-db.sh session-entries`) instead of a closing line in a
record. A board or entry list that cannot be read refuses. `harness.env.example` gains `AGENT_MODEL_DEV` /
`AGENT_MODEL_TESTER`; the panel hides a developer or tester with no running session. Self-tests in-script
with stand-in `tmux`, `claude` and ledger on PATH and a fixture roster (`selftest-tiers.txt`: both scripts
`verify`; `scripts/lib/agent-session.sh`, the shared "is it running" helper, `nowhere` with its reason).

**How a session is started, and why not `--tmux`.** Spawn runs `tmux new-session -d -s <project>-<name>`
with `env <roster_launch_env> claude --worktree <project>-<name> --name <Name> [--model M] "<first prompt>"`:
the same identity as the printed launch line, but spawn owns the tmux session instead of passing `--tmux`,
because `--tmux` expects a terminal to attach and spawn runs from the lead's session, which has none. The
first prompt is Claude Code's positional prompt rather than text typed once the session is idle.

**Driven on a real box (Claude Code 2.1, 23 Oct 2026), and what is still unproven.** A positional first
prompt in a detached tmux session is submitted and answered, and the session stays open for the next prompt.
`claude --worktree` refuses to start ("Workspace trust not yet accepted") in a folder whose trust dialog was
never accepted there - trust in a parent folder does not count - so spawn checks `.claude.json` for the
project root first and says how to fix it, rather than report a session that dies at once. Still unproven
until the first real spawn and bench: `--worktree` re-entering a benched agent's existing worktree, and a
real session's environment and record being read as these scripts read them (the record's `startedAt`, in
milliseconds, is there in Claude Code 2.1's records).

**Deliberately not ported:** the weekly budget and its panel bar, the seeded project's restore script and
pane grid, PR-comment and merge-gate tooling, that owner's own process settings and per-box settings file,
the Test Lead merge (the head of testing stays), a context-trimming settings example, the other panel extras
(ticket, effort, role colours, disk), and verbatim owner quotes: the rules are stated plainly.

## 2026-10-23 — A weekly budget decides whether the lead asks before starting an agent (ported from the seeded project)

**Decision.** `scripts/agents-budget.sh` answers one question for the delivery lead: is the account's week inside
the owner's budget so far? The budget is `AGENT_WEEK_PCT_PER_HOUR` percent of the weekly allowance for every
working hour (`AGENT_WORK_DAYS`, `AGENT_WORK_HOURS`) since the week reset (`AGENT_WEEK_RESET`), in local time: at 2
an hour over 08:00-17:00 Monday to Friday, by Wednesday 12:00 that is 44%, and a full working week spends 90%,
leaving 10% in hand. Exit 0 on budget, 1 over, 2 cannot tell (no budget, a malformed setting, no reading since the
reset). On budget the lead starts the agent and tells the owner in one line; over it, or when it cannot tell, the
lead asks first. A spawn's dry run prints the line. The budget never picks the model: the work does
(`docs/roles/delivery-lead.md`). With no rate set nothing changes: the lead asks every time.

**The week's reading** is in one place, `scripts/lib/week-usage.sh`, for the budget and the panel alike: the
highest `week.used_pct` among the context rows written within a minute of the freshest, because each session's
figure is as of its own last request. A reading from before the reset is no reading.

**The panel's top line** becomes one week bar: filled to the use, a `│` at the budget's allowance for now, both
figures (`week ████│███░░░ 70% of 44%`), green inside the allowance and red past it; with no budget, the plain
bar. The five-hour bar goes, so the top line shows the one figure the budget is about.
`five_hour.used_pct` stays in the publisher contract.

## 2026-10-23 — The panel shows each agent's ticket, model and effort, in its role's colour (ported from the seeded project)

**Decision.** Each row of `scripts/agents-dash.sh` now carries what the delivery lead routes by, in place of the
process's CPU and memory:

- **The ticket** the agent holds, from the claims board (`ledger-db.sh board`). A board read is a database call,
  so the frame never waits for one: the panel keeps the last answer in its cache and, once it is a minute old
  (`AGENTS_DASH_BOARD_EVERY`), starts one read in the background for the next frame. A failed read keeps the
  last answer.
- **The model and reasoning effort**, e.g. `O5.5 x`: the model from the publisher's row, and `effort`, a new
  publisher field from the payload's `effort.level` (`docs/context-publisher.md`; the example publisher writes it).
  `xhigh` and `max` show in amber, as the two levels that spend the most tokens.
- **The name in its role's colour**, black on the colour as Claude Code draws a name after `/color`:
  `AGENT_COLOUR_<ROLE>` in `harness.env`, defaulting to lead red, developer blue, tester yellow, head of testing
  purple, code reviewer cyan, process improvement pink, assistant green. A long wait turns the box amber.
- **Free disk space** under the week bar, only for a path set in `AGENT_DISK_WATCH`: amber under 40G, red under
  20G, for a box where a full disk stops every session.

**Not ported:** the seeded project's `/color` at spawn (the spawn's one positional prompt is the agent's
first prompt) and its waiting pulse.

## 2026-10-26 — The repo is laid out in sections: one home per kind of thing

**Decision.** The harness held four kinds of thing in one `scripts/` tree, and an adopter could not tell which were
the process and which were one way of running it. They now sit apart, and dependencies point one way:

- `scripts/` is **the process**: init, verify, handoff, the ledger and its verbs, identity and the roster, the
  gates, the CI helpers, `lib/`. It depends on no other section. `agents/roster.json`, `infra/ledger-db/` and
  `docs/` stay where they were: identity and the ticket store are process.
- `team/` is **several agents on one box**: spawn, bench, budget, the panel, the context screen, the status-line
  publisher and their two libraries. Optional; needs tmux and a usage reading.
- `ops/` is **alerts and timers**: the condition library in both languages, the queue, the settle tick, the unit
  failure hook, the unit templates and their installer. Optional.
- `claude-code/` is **the Claude Code mods**. Optional; Claude Code only. The hooks and the `/configure` skill stay
  under `.claude/`, because Claude Code reads them from that path.

Each section has a README saying what it is, what it needs and that it can be left out. Moved scripts source the
shared libraries from `scripts/lib/`; their own libraries sit beside them. `check-selftest-flag-contract.sh` scans
`team/` and `ops/` as well as `scripts/`; `check-mods-tests-pass.sh` reads `claude-code/`.

**What did not move, and why.** `scripts/` keeps its name: `scripts/` is written in over a hundred files, this log
among them, and the name says nothing wrong. `agent-stacks.sh` stays in the process: `init.sh` refuses to start a
stack past the cap, so the cap is part of clocking in. This entry records the moves only; content is unchanged, so
the diff reads as renames.

## 2026-10-26 — The Claude Code mods catch up with the seeded project's copies

**Decision.** Three behaviours that the project this harness was extracted from added to its own copies of
the mods are brought back, so the two copies carry the same mechanisms:

- **self-compact.** A compaction the agent asked for is followed by one prompt of the mod's own, marked as the
  mod's: read your durable record first, then carry on with its next action; if that action is waiting on
  someone, say so and stop. A compaction is not a turn, so without it the session sat at an empty prompt and
  the standing rule to read the record first never fired. The nudge now names the one command to run,
  `compact-me.sh "<what the summary must keep>"`, and says what the instructions must name (where the record
  is and the very next action), instead of a JSON file path to write by hand. A veto or a refused request is
  followed by nothing.
- **waiting-agents, liveness without `/proc`.** On macOS there is no `/proc`, so the mod saw no live session
  at all and the delivery lead's status line stayed empty. There a session now counts as live while the
  messaging socket its own record names still exists; Claude Code writes both and removes both. Where `/proc`
  exists nothing changes: start time and `GIT_AUTHOR_EMAIL` are still read from it.
- **waiting-agents, a pause file and the nudged roles.** `waiting-agents.paused` beside the nudger's log
  silences every alert and nudge while it exists, with `paused` in the status bar, for evenings and weekends.
  Nudges go only to developers, testers, the code reviewer and process improvement (`NUDGE_ROLES`): the head
  of testing defines what is true rather than working a ticket, and assistants are not on the team.

**Not ported, and why.** The seeded project keys each agent's `COMPACT_AFTER` entry by the session's own name
read from `~/.claude/sessions`; the harness keeps `GIT_AUTHOR_NAME` from the launch line, which is its identity
rule. Its nudges carry each agent's ticket from a per-agent ticket file; here the ticket is a ledger claim and
the nudge text stays as it was. Its `compact-me.sh` parses the self-test flag by hand; the harness copy keeps the
shared `selftest-flag.sh` contract.

## 2026-10-26 — Activity comes from hooks, and Claude Code is wired in one command (ported from the seeded project)

**Decision.** The context row's `activity` was whatever the publisher guessed, which was `working` for every
session, so the nudger never saw an idle agent and the panel could not tell a blocked session from a busy one.
Now `team/activity-hook.sh`, called from Claude Code's hooks, records each session as working (a prompt or a
tool call), waiting (a permission prompt, or a question to the person) or idle (a stop), with the time, in one
file per session under `~/.local/state/<project>/activity`; a session's end removes it. The publisher reads that
file into `activity` and `idle_s`. A transcript cannot give this: a long tool call or a permission prompt writes
nothing to it, so a busy or blocked agent read as idle.

`team/install-claude-code.sh` wires Claude Code on a box once: the status line, the `claude-code` mods folder in
`CLAUDE_CODE_PLUGIN_DIRS`, and the activity hooks on the eight events, added to the user's `settings.json`
alongside what is there. It never replaces a value the person set, shows what it would add, asks, and keeps the
old file as `.bak`; `--dry-run` only looks, `--yes` is for a script. Both scripts carry `--self-test` and have
`verify` rows; the merge is a pure function tested on its own, and the installer is tested against a throwaway
`CLAUDE_CONFIG_DIR`.

**Not ported.** The seeded project's installer also writes a roster, installs byobu bindings, copies scripts
into `~/.claude/bin` and installs systemd or launchd timers for its record archiver; those belong to its own
roster and layout, which the harness does not share. Its status line draws a full bar (activity, ticket, a
running-gates row); the harness publisher remains the example it was, now carrying the activity.

## 2026-10-26 — The rules of conduct between agents, and with the owner (ported from the seeded project)

**Decision.** The harness said what each role owns and what it must not touch, but little about how agents
deal with one another and with the owner, and the seeded project had learnt those rules the hard way. They
are now in AGENTS.md, stated as rules without the quotes that produced them:

- **0b, a wait never holds your turn.** A foreground sleep or `until` loop keeps the session in a turn; the
  lead, the mod and the panel all see it as busy, and messages queue behind it. Monitor for up to thirty
  minutes, otherwise record the pending check, tell the lead and end the turn.
- **0a gains three sentences.** After a compaction, read the record first (session entry, claimed row,
  `agent-context.sh --me`), check the identity still resolves, trust the record's ids over the summary's;
  "skipping verification" joins the list of what low context is never for; the weekly usage is the owner's
  to spend. And routing is never by context left: role and who is free decide, because each agent manages
  its own compaction. The old "prefer the agent with room" in 0a and in docs/context-publisher.md said the
  opposite and is gone.
- **Rule 6**: every id in a session entry comes from the command that printed it, never from memory.
- **Session exit**: every container started outside the project's stack is named in the session entry and
  removed by name, never by a prune; an unrecorded container is orphaned and will be removed.
- **A new section, "Working beside other agents, and with the owner"**: name the role with the name; only
  the delivery lead talks to the code reviewer, and findings go on the PR first; developers and testers reach
  the owner through the lead, and tell the lead before putting anything to the owner in their own pane;
  guidance the lead relays is acted on without re-confirming, with the short list of what stays the owner's
  own; shared things are touched by check, tell, then touch.
- **Role docs**: the developer runs what the pipeline runs before opening the PR and lists it in the
  handover (CI's run stays the definition of done); the code reviewer compacts only at a finished PR and
  sets its soft point low; the delivery lead keeps the reviewer's queue, confirms only invasive relays with
  the owner, and tells the owner in one line when an agent is stuck on a prompt that is the owner's; every PR
  comment starts with the agent's name and role; the tester touches shared things by the rule.

**Not ported.** The seeded project's never-merge-until-the-owner-says rule, its signed-comment and
three-approval gate, its review-in-the-main-checkout and sign-off-before-PR settings, and its single-file
durable record are its own merge model and record format; the harness lands by CI and records in the ledger.

## 2026-10-26 — The panel pulses for a waiting agent; old context rows are hidden; the tester's browser wait (ported from the seeded project)

**Decision.** Three small things the seeded project's team found it wanted:

- **`team/agents-dash.sh`**: a waiting agent's whole block pulses through 256-colour background shades
  (`AGENTS_DASH_PULSE`, one step every `AGENTS_DASH_PULSE_STEP` seconds), so a stuck agent catches the eye
  without the panel having to be read. The frame marks a waiting agent's lines; `render()` paints marked
  lines and strips the mark, re-applying the background after every reset inside the line. The loop redraws
  the same frame in the next shade until the interval is up, and no longer clears the screen per frame: home,
  overwrite with each line cleared to its end, clear below. Plain output (`--plain`, or not a terminal) is
  unchanged, so every existing assertion still holds.
- **`team/agent-context.sh`**: a row older than a day is a session long gone and is hidden; `--all` shows it.
  Stale (over two minutes) still marks rather than hides.
- **`AGENT_BROWSER_WAIT`** in `harness.env` and the tester's role doc: with `yes` the tester batches the checks
  that need no browser, then tells the delivery lead the ticket, the URL and roughly how long before the first
  browser step and waits for "go" or "go without me", so the owner can watch.

**Not ported.** The seeded project's panel reads a second usage source, a cache its own status line writes;
the harness has one source, the publisher's rows, and keeps it. Its "dormant" label for a role switched off by
hand reads a roster column the harness roster does not have; a role with no session still reads "not started".
Its ticket column in the context screen reads a per-agent ticket file; here the ticket is a ledger claim and
the panel already shows it from the board.

## 2026-10-26 — The seeded project's names, machine and session records leave the template

**Decision.** The harness is a template: what it carries from the project it was extracted from should be the
process, not that project's furniture. Scrubbed in one pass, behaviour unchanged, every self-test and gate green:

- **Fixtures.** `scripts/agent-stacks.sh` sampled one machine's `docker compose ls` by its real paths and project
  names; the same shapes now carry neutral names (`/home/owner`, `acme`, `acme-forge`), so every arm still
  exercises the rule it was written for. `scripts/lib/roster.sh` and the waiting-agents mod's tests used the
  seeded project's mail domain and worktree names, as did `scripts/lib/agent-name.sh`, `scripts/agent-onboard.sh` and two
  comments in the ledger scripts; they now use `example.test` and `acme`.
- **Credits.** Comments that named the agent or person who found something ("X's review", "after X found the
  trap") now say what was found and when. The finding is the record; the name was not.
- **Session records.** `progress/` held two records from the seeded project's own sessions. They are gone; the
  directory is still frozen (`scripts/check-no-new-progress-files.sh`), so nothing new appears there either.
- **Permission.** `.claude/settings.json` allowed one web domain by name; nothing in the kit fetches it. Removed.

**Kept.** Dated decisions and their counts (a unit that failed 391 times in four days), the ticket slugs that
name the fix a rule came from, and the project names inside DECISIONS.md entries: those are the history that
explains a rule, and a template with no history explains nothing.

## 2026-10-26 — A developer's ticket is checked before the spawn and its claim watched after

**Decision.** The owner, on finding tickets left unassigned after their developers were started: "this stuff
should be automatic - how do we make it something natural rather than something you have to remember".
`team/agent-spawn.sh` now reads a developer's ticket row before starting anything and refuses a spawn the
claim would refuse (no row, finished, ungroomed, held by another), and after the start watches the row until
the developer's claim appears, for `AGENT_SPAWN_CLAIM_WAIT_S`, saying loudly and exiting 1 when it does not.
A tester's ticket is left alone.

**Why not claim for the developer.** The seeded project runs on one Jira account, so its spawn assigns the
ticket to the owner and moves it to In Progress itself. Here every agent has its own identity and a claim is
stamped with it (`scripts/lib/agent-name.sh`: a claim under another name is a record that matches nothing
else), and the lock is a branch the developer pushes. So the spawn checks and watches; it never claims.

## 2026-10-26 — Every spawn says why its model (ported from the seeded project)

**Decision.** The owner, on the delivery lead's model choices going unrecorded: "we aren't capturing the
decision and the reason each time - can we?", and for developers as well as testers, "both please".
`team/agent-spawn.sh` takes `--why "<reason>"`, the reason for the model the agent starts on, and a real spawn
without it is a usage error that starts nothing; the words check `--owner-ok` uses applies, so a flag, blanks,
a second line or the `<placeholder>` pasted unedited are refused. The reason is the spawn record's ninth
column and is printed on the start line. A dry run without it still runs and says the real spawn needs it.

**What differs from the seeded project.** There a real spawn must also name `--model`. Here the role's
`AGENT_MODEL_*` from `harness.env` still applies without one: the reason is recorded either way, and the
settings keep their meaning.

**Not ported, and why.** Two of the seeded project's changes the same day are about its shared byobu grid: a
benched agent's pane is left as a spare placeholder rather than closed, and re-laying out a window closes
the spares it no longer needs, so a bench shrinks the grid by whole columns. The harness gives each agent
its own tmux session (`team/agent-bench.sh` stops it), so there is no shared grid to lay out. Its spawn
assigning the ticket in Jira is covered here by the ledger check and claim watch above.

The change sits in `team/`, where the sectioned layout of the same day put the spawn.

