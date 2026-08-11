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
