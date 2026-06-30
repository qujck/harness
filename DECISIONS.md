# DECISIONS

> Append-only architecture log. One entry per significant choice another agent might re-debate. **Binding until superseded by a later entry.** Newest at the bottom.

---

## {{DATE}} — Adopted the agent harness

Adopted the init/verify/handoff harness (this kit). Rationale: make the correct
workflow the path of least resistance and make self-grading impossible —
`scripts/verify.sh` exit 0 is the only Definition of Done; `scripts/handoff.sh`
gates session exit; the git pre-commit hook is the hard enforcement point.

Parallel-safe by default: the work queue is a per-ticket `features/` directory
(no merge conflicts on the queue), `depends_on`/ready-frontier orders the work,
and the append-only logs union-merge — so independent agents on separate clones
never collide. Running several worktrees on one machine (per-stream container
stacks) is opt-in via `PER_STREAM_STACKS=1`.

Deliberately deferred for now: sprint contracts, distributed tracing, evaluator
rubrics. Revisit if/when the team scales further.
