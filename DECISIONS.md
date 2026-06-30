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
