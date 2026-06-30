# agent-harness

A drop-in workflow harness for AI coding agents. It makes the correct workflow
the path of least resistance and makes self-grading impossible:

- **`init.sh`** clocks in — boots the stack, installs the git hook, marks the session.
- **`verify.sh`** is the *only* Definition of Done — static → unit → e2e, exit 0 or it isn't done.
- **`handoff.sh`** clocks out — refuses a dirty/undocumented/self-graded session.
- **Three enforcement tiers** so nothing slips: a soft nudge, a per-turn warning, and a hard pre-commit block.

Stack-agnostic — you point it at your project's commands in one config file.

## What's in the box

```
harness.env.example      # ← the only thing you edit per project
AGENTS.md                # routing file: the rules + the loop, for any agent
PROGRESS.md              # mutable "what's happening right now"
DECISIONS.md             # append-only architecture log
features/                # the work queue: one <id>.json ticket per file
feature_list.archive.jsonl  # completed tickets (append-only, one per line)
.gitattributes           # union-merge the append-only logs
scripts/
  init.sh                # clock in
  verify.sh              # Definition of Done
  handoff.sh             # clock out gate
  archive-passing.sh     # move passing tickets to the archive
  _features.sh           # ledger helper: aggregates features/*.json (sourced)
  _stack.sh              # optional per-stream docker helpers (sourced)
  git-hooks/pre-commit   # hard enforcement (installed by init.sh)
.claude/
  settings.json          # Claude Code hook wiring
  hooks/stop-check.sh        # per-turn lenient handoff warning
  hooks/user-prompt-check.sh # nudge to run init.sh
  skills/configure/SKILL.md  # /configure — fills every placeholder for you (Claude Code)
```

**The three scripts are the harness.** They map onto a session's lifecycle:

- **`scripts/init.sh` — clock in.** Idempotent bootstrap: checks required tools,
  copies `.env` from `.env.example`, brings your stack up (`UP_CMD`), waits on the
  health endpoint, installs the git pre-commit hook, writes the
  `.agent/session.active` marker, and prints the next ready feature (highest
  priority whose dependencies are met). Initialization is its own phase, kept
  separate from implementation.
- **`scripts/verify.sh` — the Definition of Done.** The *only* thing that decides
  whether a feature is "passing": static → unit → e2e, run in order, stop on first
  failure (each layer skipped if its `harness.env` command is blank). Exit 0 or it
  isn't done — an agent can't self-grade.
- **`scripts/handoff.sh` — clock out.** Refuses to end a session that isn't clean:
  re-runs verify, then checks the tree is clean (or committed), `PROGRESS.md` was
  touched, no debug artifacts were added, and nudges on ledger WIP. Fix the gap
  rather than work around it — that's the whole point. (With `PER_STREAM_STACKS=1`
  a strict pass also tears this worktree's stack down.)

**Three enforcement tiers** make sure none of that is skippable:

1. **`.claude/hooks/user-prompt-check.sh`** — a soft nudge to run `init.sh` when the
   session marker is missing (fires on each prompt).
2. **`.claude/hooks/stop-check.sh`** — a per-turn *lenient* handoff check that warns
   about gaps without blocking (fires only when the tree is dirty).
3. **`scripts/git-hooks/pre-commit`** — the hard stop: runs verify's static+unit
   layers on commit and won't let you commit past a failure (`--no-verify` overrides
   in emergencies).

**The documents & the ledger** carry state between sessions:

- **`AGENTS.md`** — the single entry point any agent reads first: the hard rules and
  the session loop. Short by design; points to a per-project `CLAUDE.md` for detail.
- **`PROGRESS.md`** — mutable "what's happening right now"; `handoff.sh` won't pass
  unless it was touched this session.
- **`DECISIONS.md`** — append-only log of architectural choices, binding until
  superseded, so the next agent doesn't re-litigate them.
- **`features/`** — the work queue: **one `features/<id>.json` per ticket** (the
  entry object alone), each with a status machine (`not_started → in_progress →
  passing` / `blocked` / `wont_do`), a real `verification_command`, and optional
  `depends_on` / `solo`. One file per ticket means concurrent branches never
  conflict on the queue. Schema: [features/README.md](features/README.md).
- **`feature_list.archive.jsonl`** — completed tickets, one compact entry per line;
  `scripts/archive-passing.sh` moves `passing` tickets here to keep the queue lean.
- **`.gitattributes`** — `merge=union` on `PROGRESS.md` / `DECISIONS.md` / the
  archive so concurrent branches that each append don't conflict.

**Configuration & setup:**

- **`harness.env.example`** — the only per-project file you edit; copy to
  `harness.env` and point the generic scripts at your build / test / e2e / health
  commands (leave any line blank to skip that step).
- **`scripts/_features.sh`** — sourced helper that aggregates `features/*.json`
  into the shape `init.sh` / `handoff.sh` read.
- **`scripts/_stack.sh`** — sourced helper for **local** parallel (several
  worktrees on one machine): a per-worktree compose project, port discovery, and
  `.agent/env`. Inert unless `PER_STREAM_STACKS=1`.
- **`.claude/settings.json`** — wires the two hooks into Claude Code.
- **`.claude/skills/configure/SKILL.md`** — the `/configure` skill: detects your
  stack and fills every placeholder for you (Claude Code only).

## Setup

### The fast path — `/configure` (Claude Code)

1. **Copy the kit into your repo root** (everything except this README):
   ```bash
   cp -r agent-harness/{scripts,.claude,features,AGENTS.md,PROGRESS.md,DECISIONS.md,feature_list.archive.jsonl,.gitattributes,harness.env.example} /path/to/your-repo/
   ```

2. **Open the repo in Claude Code and run `/configure`.** The skill detects your
   stack, then **asks you to confirm or override every value** (it never assumes a
   command, path, or convention) and writes all of it for you: `harness.env`, the
   `AGENTS.md` / `DECISIONS.md` placeholders, the first `features/` ticket, and a
   starter project-specific `CLAUDE.md`. This replaces steps 2–3 of the manual
   path below.

3. **Clock in** when it's done (`/configure` will offer to run this):
   ```bash
   bash scripts/init.sh   # also installs the git pre-commit hook
   ```

4. **Restart Claude Code** so it picks up `.claude/settings.json` (the hooks load
   at startup, not mid-session).

### The manual path (other agents, or no Claude Code)

After step 1 above:

2. **Create your config** and fill in your project's commands:
   ```bash
   cd /path/to/your-repo
   cp harness.env.example harness.env
   ```
   Set `VERIFY_STATIC` / `VERIFY_UNIT` / `VERIFY_E2E` to your build/test/e2e
   commands, `UP_CMD` + `HEALTH_URL` to start & probe your stack, and
   `VERIFY_PATH_FILTER` to the paths that should trigger a pre-commit verify.
   **Leave any line blank to skip that step.**

3. **Fill the `{{placeholders}}`** in `AGENTS.md` and `DECISIONS.md`, replace
   `features/example_replace_me.json` with your first real ticket (see
   `features/README.md` for the schema), and write a project-specific `CLAUDE.md`
   with your data model / runbook.

4. **Clock in** (installs the pre-commit hook): `bash scripts/init.sh`.

5. **Restart your agent** so it picks up `.claude/settings.json`.

### Either way — gitignore the runtime bits

The kit's `.gitignore` already lists these; confirm they're in your repo's:
```
.agent/
harness.env
.claude/settings.local.json
```

## The loop, once configured

```
bash scripts/init.sh            # start of session
# … add a features/<id>.json ticket (not_started → in_progress) BEFORE coding …
bash scripts/verify.sh          # exit 0 == done; then mark the ticket "passing"
bash scripts/archive-passing.sh # move passing tickets to the archive
bash scripts/handoff.sh         # end of session — must be green to clock out
```

## Config reference

| Variable | Used by | Meaning |
|---|---|---|
| `UP_CMD` | init | Idempotent command to start the stack. Blank = none. |
| `HEALTH_URL` / `HEALTH_TIMEOUT` | init, verify | Endpoint polled until 2xx. Blank = skip. |
| `REQUIRED_TOOLS` | init | Space-separated tools that must be on PATH. |
| `VERIFY_STATIC` | verify | Lint / typecheck / compile. Blank = skip layer. |
| `VERIFY_UNIT` | verify | Unit tests. Blank = skip layer. |
| `VERIFY_E2E` | verify | End-to-end suite. Blank or `SKIP_E2E=1` = skip. |
| `VERIFY_UI` | verify | Opt-in browser suite, gated by `RUN_UI=1`. |
| `VERIFY_PATH_FILTER` | pre-commit | Regex of staged paths that trigger verify. Blank = always. |
| `DEBUG_PATTERNS` | handoff | Space-separated regexes; an added line matching any blocks handoff. |
| `PER_STREAM_STACKS` | init, verify, handoff | `1` = **local** parallel: per-worktree docker stack with discovered ports. Default `0`. |
| `STACK_HEALTH_SERVICE` / `STACK_HEALTH_CONTAINER_PORT` / `STACK_HEALTH_PATH` | init | Per-stream health probe (`PER_STREAM_STACKS=1`): which compose service/container-port/path to poll (host port discovered). |

The **distributed** parallel-safe workflow (per-ticket ledger, ready-frontier,
union-merge, WIP nudge) is the default and has no config switch — see below.

## Parallel development

When more than one agent (or person) works the repo at once, two things break:
they fight over the same containers, and every PR conflicts on the same hot-spot
in the shared logs/ledger. The harness splits the fix into two halves.

### Distributed — the default (no config)

For agents on **separate clones or machines**. On by default; nothing to switch
on. It removes every git-level conflict source:

- **Per-ticket ledger.** The work queue is the `features/` directory, **one
  `features/<id>.json` per ticket**, so two agents adding/flipping different
  tickets never touch the same file. (A single shared JSON array was the conflict
  source — arrays can't union-merge.) `passing` tickets move to
  **`feature_list.archive.jsonl`** (one line each) via `scripts/archive-passing.sh`.
- **`depends_on` + ready frontier.** A ticket may list `depends_on: [ids]`;
  `init.sh` offers the next ticket from the **ready frontier** (deps all
  `passing`). Add `solo: true` to a ticket that must run alone. Pick work from the
  frontier, preferring a different `area` from the other agent.
- **WIP is a nudge.** `handoff.sh` warns — never fails — on multiple `in_progress`.
  Isolation, not a count, is the safety.
- **Union-merge logs.** `.gitattributes` sets `merge=union` on `PROGRESS.md`,
  `DECISIONS.md`, and the JSONL archive, so concurrent appends auto-merge.
- **Isolation rule.** `AGENTS.md` rule 0: never share a checkout.

### Local — optional (`PER_STREAM_STACKS=1`)

For several git worktrees on **one machine** — only where it can run **several
stacks at once** (and `UP_CMD` is docker-compose based). Each worktree gets its
**own compose project** (named from the worktree dir) with **kernel-assigned host
ports**. `init.sh` discovers the ports into `.agent/env`; the other scripts read
it, so each stream reaches its own stack. Strict `handoff.sh` tears the stack
down (`down -v`); the per-turn Stop-hook never does (`KEEP_STACK=1` keeps it after
a clean handoff). Set `STACK_HEALTH_SERVICE` / `STACK_HEALTH_CONTAINER_PORT` /
`STACK_HEALTH_PATH` so init can find and probe the health endpoint. *If your
machine can't run multiple stacks, leave this `0` — you still get the distributed
workflow across separate clones.*

### Complementary patterns (adopt as they fit — not shipped as code)

These are GitHub/CI/project-specific, so the kit documents rather than ships them:

- **Merge queue.** Enable GitHub's merge queue and add a `merge_group:` trigger to
  your CI workflow so PRs build+test the *combined* result and land **serially** —
  this is what actually kills the rebase treadmill when concurrent PRs race `main`.
- **Ticket → issue mirror.** A small `gh`-based script can open a tracking issue
  when a ticket goes `in_progress` and print a `Closes #N` line for the PR body
  (the `features/<id>.json` file stays the source of truth; the issue auto-closes
  on merge).
- **Verify fast-lane.** Short-circuit `verify.sh` to the cheap relevant checks when
  a diff touches only frontend/docs/ledger paths that can't affect the backend
  layers — minutes saved per parallel PR.

## Design notes — the framework it implements

This kit is a concrete implementation of **[Learn Harness Engineering](https://walkinglabs.github.io/learn-harness-engineering/)**
(WalkingLabs), a 12-lecture framework. A *harness* is everything outside the model
weights — its five subsystems are **instructions, tools, environment, state, and
feedback** (L02) — and the guiding rule is to **make the correct path the path of
least resistance**: constrain the agent with executable rules rather than
enumerating instructions it can ignore. The `Lec N` references in the script
headers point back to these lectures.

Each part maps to a lecture's driver:

| Part | Lecture | Driver it embodies |
|---|---|---|
| `AGENTS.md` — a short router to `CLAUDE.md` / docs | **L04** | One giant instruction file fails — keep the entry file small; link, don't inline. |
| `PROGRESS.md`, `.agent/session.active` | **L05** | Long-running tasks lose continuity — carry state across sessions in files, not chat. |
| `DECISIONS.md`; "the repo *is* the spec" | **L03** | The repo is the single source of record. |
| `scripts/init.sh` — the bootstrap contract | **L06** | Initialization is its own phase: can start, verify, see progress, pick up next — *before* coding. |
| `features/` + `_features.sh` + `archive-passing.sh` | **L08** | Feature lists are harness *primitives* — "documents can be ignored; primitives can't be bypassed." Each ticket carries the triple (behaviour, verification command, state). |
| WIP nudge + `depends_on` ready-frontier | **L07** | Agents overreach and under-finish — bound work so finite attention isn't split `C/k` across tasks. |
| `scripts/verify.sh` exit 0 = Definition of Done | **L09** | Agents declare victory too early — only the verifier (not judgement) advances a ticket to `passing`. |
| `verify.sh` static → unit → **e2e** | **L10** | End-to-end testing changes results — component-boundary defects only surface end-to-end. |
| per-stream stacks / `_stack.sh` (the Environment subsystem) | **L02** | Reproducible, isolated environments — and the substrate that lets multiple agents run at once. |
| `handoff.sh` + per-stream teardown | **L12** | Every session must leave a clean state, or the next pays a 30–50% handoff penalty re-diagnosing. |
| Enforcement: pre-commit + Stop / UserPromptSubmit hooks | **L02 / L08** | A primitive, not a document — the correct path is *enforced*, not merely advised. |

**Where we extend the framework for parallel work.** L07's WIP=1 is the safest
*default*, but it assumes a single attention context. Once each agent runs in an
isolated checkout (own worktree or clone), WIP=1 relaxes to a per-checkout
*nudge* — finite attention is still one task per agent while the fleet runs many.
The per-ticket `features/` layout, union-merge logs, and the `depends_on` frontier
are what make that safe: they remove the shared-file conflicts a single JSON
array created.

**What we deliberately defer.** **L11** — observability inside the harness (task
traces / OpenTelemetry, sprint contracts, evaluator rubrics, the
Planner→Generator→Evaluator split) — is not implemented. It's the highest-ceiling
lecture but the heaviest; revisit it as the agent fleet and eval needs grow (see
`DECISIONS.md`).

The mechanism is the point — adjust freely.
