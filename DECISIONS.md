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
