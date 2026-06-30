# Observability (L11) — the optional next step

> **Status: documented, not implemented.** This is the next rung of *Learn
> Harness Engineering* (L11 — "why observability belongs inside the harness").
> The kit ships without it on purpose: it's the highest-ceiling lecture and the
> heaviest to build. This file is the adoption path for when you want it.

## Why L11 exists

Without observability, "agents make decisions under uncertainty, evaluations
become subjective judgments, and retries become blind wandering." Four failure
modes it removes:

1. **Runtime vs. apparent correctness** — code can look right and fail at
   execution; only a trace shows what actually happened.
2. **Non-reproducible evaluation** — without a rubric, two graders disagree on the
   same output.
3. **Blind retries** — no diagnostic data → tokens wasted on misdirected fixes.
4. **Handoff penalty** — incomplete, un-traced handoffs burn an observed
   **30–50% of the next session** on re-diagnosis (this is the cost L12's
   clean-state rule already attacks; L11 makes the remaining work visible).

## The two layers

- **Runtime observability** — *what did the system do?* Logs, traces, process
  events, health checks.
- **Process observability** — *why should this change be accepted?* The harness's
  own decision artifacts: plans, acceptance criteria, rubrics.

## How it would plug into this harness

The seams already exist — L11 is mostly about *recording* what flows through them.

| L11 instrument | Where it attaches here | First cheap rung |
|---|---|---|
| **Task trace** (OpenTelemetry spans) | `init.sh` / `verify.sh` / `handoff.sh` already print step logs | Append one structured record per run to `.agent/runs.jsonl` (ticket id, layer, pass/fail, duration, commit). Promote to OTel spans later. |
| **Sprint contract** | a `features/<id>.json` ticket's `acceptance` is the agreed "done" | Require `acceptance[]` to be filled *before* `status: in_progress` — the contract is signed before code. |
| **Evaluator rubric** | the ticket's `verification` + `acceptance` | Add a `rubric[]` of true/false criteria; grade each with an isolated judge, not the implementer. |
| **Generator ≠ Evaluator** | extends L09 (no self-grading) to multi-agent | A second agent runs `verify.sh` + scores the rubric; the implementer never flips its own ticket to `passing`. |

## A minimal first implementation (sketch)

1. Add `OBSERVABILITY=1` to `harness.env` (a stub line is already there, commented).
2. Add `scripts/_observe.sh` defining `trace_event <event> <json>` that appends a
   line to `.agent/runs.jsonl` **only when `OBSERVABILITY=1`** (no-op otherwise).
3. Call `trace_event` at the start/end of each `verify.sh` layer and at
   `handoff.sh` exit. `.agent/` is already git-ignored, so traces stay local.
4. (Later) Add a `rubric[]` to the ticket schema and a separate evaluator step.

Keep it inert until opted in — same discipline as `PER_STREAM_STACKS`.

## When to adopt

Adopt L11 when any of these bite: you can't tell *why* a verify failed from the
output; multiple agents grade inconsistently; or session handoffs keep costing
re-diagnosis time. Until then, L09 (verify is the only DoD) + L12 (clean handoff)
carry most of the value at a fraction of the cost.
