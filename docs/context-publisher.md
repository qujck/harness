# The context publisher — every agent's context, readable by the others

*(feat_harness_a_machine_wide_agent_stack_cap_and_each_agents_context_published_for_the_others)*

**The rule first (owner, 2026-09-28, verbatim in AGENTS.md):** *context is a fact you can read, never a
reason to do less* — "at no point should it be used as a reason to not do more work — this would be a
disaster". `scripts/check-context-is-never-a-reason-to-do-less.sh` fails the build on a document that
cites context as a reason to stop, defer or narrow.

## The contract

A status-line command (yours — `scripts/examples/statusline-publish.sh` is an example to adapt, not the
file to install) writes **one JSON file per session** to `CONTEXT_DIR`
(default `~/.local/state/<project>/context/`), replaced atomically every few seconds:

```json
{"agent":"Wren","session_id":"abc","ts":"2026-10-01T12:00:00Z","cwd":"/home/me/proj-wren",
 "worktree":"proj-wren","model":"Opus","context":{"remaining_pct":42.0},"week":{"used_pct":18.0},
 "activity":"working","idle_s":null}
```

| field | meaning |
|---|---|
| `agent` | the session's name, from the roster (never from a directory label); `unnamed` means fix your launch line |
| `ts` | when written, UTC; a row older than **120 s** renders as `(stale)` |
| `context.remaining_pct` | what the model has left in its window |
| `week.used_pct` | the account's weekly usage — the owner's to spend |
| `activity` / `idle_s` | `working` or `idle` (+ seconds idle), from the publisher |

`bash scripts/agent-context.sh` renders every row, freshest first (`--me` for yours, `--json` raw).

## What it is for — and only for

1. write the durable record (session entry, decision, row amendment) **before** a compaction;
2. hand a wide read or a long log to a subagent when your own context is low;
3. when routing or handing off, prefer the agent with room, and say so;
4. answer "how much have you got left" with the number.

Never: stopping, deferring, narrowing scope, or "leaving this for someone with more context" (forbidden phrase, quoted here to forbid it).
A compaction is a summary, not an ending.

## The machine-wide stack cap, beside it

`scripts/agent-stacks.sh` lists every live agent stack on the box (a compose project with an override
file and a running `STACK_HEALTH_SERVICE` container) and says why each is or is not counted: the CI
seat (`<project>_ci*`) and the projects named in `INFRA_STACK_PROJECTS` are **not counted** and say
so. `init.sh` runs `agent-stacks.sh --check` before bringing a stack up: at `AGENT_STACK_LIMIT`
(default 4) it **refuses to start one more and names the holders** — it never stops anything, and
nothing is queued for you; wait, or ask a holder to `handoff.sh`.
