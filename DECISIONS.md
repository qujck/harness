# DECISIONS

> Append-only architecture log. One entry per significant choice another agent might re-debate. **Binding until superseded by a later entry.** Newest at the bottom.

---

## {{DATE}} — Adopted the agent harness

Adopted the init/verify/handoff harness (this kit). Rationale: make the correct
workflow the path of least resistance and make self-grading impossible —
`scripts/verify.sh` exit 0 is the only Definition of Done; `scripts/handoff.sh`
gates session exit; the git pre-commit hook is the hard enforcement point.

Deliberately deferred (revisit when multiple agents run in parallel): sprint
contracts, distributed tracing, evaluator rubrics. Overhead for a solo agent today.
