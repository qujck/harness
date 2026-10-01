# agent-harness

A drop-in workflow harness for AI coding agents. It makes the correct workflow
the path of least resistance and makes self-grading impossible:

- **`init.sh`** clocks in — boots the stack, installs the git hook, marks the session.
- **`verify.sh`** is the *only* Definition of Done — static → unit → e2e, exit 0 or it isn't done.
- **`handoff.sh`** clocks out — refuses a dirty/undocumented/self-graded session.
- **`feature-ticket.sh`** claims work so two agents cannot take the same ticket — the pushed
  branch is the lock, because it is the only operation that is atomic across machines.
- **`METHOD.md`** is the other half of the harness: the workflow rules stop you skipping a
  step, and METHOD stops you believing a broken measurement. A broken test fails; a broken
  measurement passes, and you act on it.
- **Three enforcement tiers** so nothing slips: a soft nudge, a per-turn warning, and a hard pre-commit block.

**Stack-agnostic** — you point it at your project's commands in one config file.
**Largely agent-agnostic too:** the scripts, the ledger, and the git pre-commit
gate work with *any* agent (or a human); the `.claude/` hooks and `/configure`
skill are the first-class **Claude Code** integration. Other agents use the
manual path and still get hard enforcement via the git hook.

## What's in the box

```
harness.env.example      # ← the only thing you edit per project
AGENTS.md                # routing file: the rules + the loop, for any agent — names the four roles
docs/roles/              # the four role prompts + the roster doc: PO · developer · head of testing · process improvement
docs/runbooks/           # main-is-red: one owner, repair over revert, the repair lane
docs/landed-children.txt # which template-epic children have landed (governs the "arrives with" markers)
METHOD.md                # how to know your MEASUREMENT is sound — read before trusting a result
PROGRESS.md              # FROZEN history — read it, never append (see progress/)
DECISIONS.md             # append-only architecture log
OBSERVABILITY.md         # L11 — optional observability next step (not yet wired)
infra/ledger-db/         # the ticket store: ONE Postgres per box (compose, baseline schema, migrations)
agents/roster.json       # who may write to the ledger: GIT_AUTHOR_EMAIL -> name -> role
progress/                # session records: one file per session
.gitattributes           # ⚠ sets NO merge driver, deliberately — see the file
scripts/
  init.sh                # clock in
  verify.sh              # Definition of Done
  handoff.sh             # clock out gate
  ledger-db.sh           # the ticket verbs: raise · groom · claim · park · amend · flip-passing · archive · release · frontier …
  ledger-migrate.sh      # apply infra/ledger-db/*.sql to the running ledger, recorded in ledger.schema_migration
  ledger-db-deploy.sh    # sync infra/ledger-db/ to the deploy dir outside every checkout, write pgpass once
  progress.sh            # write this session's own entry under progress/
  feature-ticket.sh      # claim/park/release — the PUSHED BRANCH is the lock
  lib/agent-name.sh      # who this session is (sourced; parses no arguments)
  lib/ticket-store.sh    # the store adapter: TICKET_STORE=db|jira behind the one verb set (sourced)
  lib/harness-env.sh     # reads harness.env; HARNESS_PROJECT names the ledger container/network (sourced)
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

**Three enforcement tiers** make sure none of that is skippable. Tiers 1–2 are
the Claude Code integration; tier 3 is agent-agnostic (plain git):

1. **`.claude/hooks/user-prompt-check.sh`** *(Claude Code)* — a soft nudge to run
   `init.sh` when the session marker is missing (fires on each prompt).
2. **`.claude/hooks/stop-check.sh`** *(Claude Code)* — a per-turn *lenient* handoff
   check that warns about gaps without blocking (fires only when the tree is dirty).
3. **`scripts/git-hooks/pre-commit`** *(any agent)* — the hard stop: runs verify's
   static+unit layers on commit and won't let you commit past a failure
   (`--no-verify` overrides in emergencies).

**The documents & the ledger** carry state between sessions:

- **`AGENTS.md`** — the single entry point any agent reads first: the hard rules and
  the session loop. Short by design; points to a per-project `CLAUDE.md` for detail.
- **`docs/roles/`** — four roles exist in every project using this harness, however small
  the team: product owner (the ledger and the routing), developer (the code, to a terminal
  state), head of testing (what is true; fixes nothing it finds), process improvement (the
  path to `main`, the gates, the scheduled jobs). Each prompt says what the role owns and what it
  must not touch; the roster says who holds which, from the session's identity, never a directory.
- **Mechanisms that arrive with later children of the template epic are marked "(arrives with
  `<child-id>`)"** in the docs, and `scripts/check-docs-markers-match-landed-children.sh` fails the
  build if a marker outlives its child (`docs/landed-children.txt`).
- **`PROGRESS.md`** — mutable "what's happening right now"; `handoff.sh` won't pass
  unless it was touched this session.
- **`DECISIONS.md`** — append-only log of architectural choices, binding until
  superseded, so the next agent doesn't re-litigate them.
- **The ledger** (`infra/ledger-db/`, `scripts/ledger-db.sh`) — the work queue is a **database**,
  one Postgres per box that every worktree reads: a row per ticket, five statuses (`not_started` →
  `selected` → `in_progress` → `passing` → `archived`, plus `wont_do`), every requirement change
  attributed (`amend`), every claim a row AND a pushed lock branch (`feature-ticket.sh claim`).
  Definition: [docs/ledger-spec.md](docs/ledger-spec.md). Bring it up once per box:
  `bash scripts/ledger-db-deploy.sh && docker compose -f ~/.local/state/<project>/ledger-db/docker-compose.yml up -d`.
  Store choice: `TICKET_STORE=db|jira` in `harness.env` (Jira arrives with
  `feat_harness_jira_is_a_ticket_store_behind_the_same_verbs`).
- **`feature_list.archive.jsonl`** — completed tickets, one compact entry per line;
  `scripts/archive-passing.sh` moves `passing` tickets here to keep the queue lean.
- **`.gitattributes`** — `merge=union` on `PROGRESS.md` / `DECISIONS.md` / the
  archive so concurrent branches that each append don't conflict.

**Configuration & setup:**

- **`harness.env.example`** — the only per-project file you edit; copy to
  `harness.env` and point the generic scripts at your build / test / e2e / health
  commands (leave any line blank to skip that step).
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
   cp -r agent-harness/{scripts,.claude,infra,agents,docs,AGENTS.md,PROGRESS.md,DECISIONS.md,OBSERVABILITY.md,feature_list.archive.jsonl,.gitattributes,harness.env.example} /path/to/your-repo/
   ```

2. **Open the repo in Claude Code and run `/configure`.** The skill detects your
   stack, then **asks you to confirm or override every value** (it never assumes a
   command, path, or convention) and writes all of it for you: `harness.env`, the
   `AGENTS.md` / `DECISIONS.md` placeholders, `harness.env` (incl. `HARNESS_PROJECT` / `TICKET_STORE`), and a
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
   the roster's example row with your first real agent (`agents/roster.json`), raise your first
   ticket (`bash scripts/ledger-db.sh raise <json>`), and write a project-specific `CLAUDE.md`
   with your data model / runbook.

4. **Clock in** (installs the pre-commit hook): `bash scripts/init.sh`.

5. **Restart your agent** so it picks up `.claude/settings.json`.

### Integrate into an existing project

The paths above assume a fresh adoption. For a repo that already has code, CI,
docs, and maybe its own agent instructions, adopt **incrementally and
non-destructively** — merge into what's there, don't overwrite it.

1. **Copy only the non-colliding files first.** `scripts/`, `infra/ledger-db/`, `agents/`, `docs/`,
   `feature_list.archive.jsonl`, `OBSERVABILITY.md`, and `harness.env.example` are
   almost always new. Copy them in. Hold back the four that commonly collide —
   `AGENTS.md`, `CLAUDE.md`, `.gitattributes`, `.gitignore` — and merge them by
   hand (below).

2. **Point `harness.env` at commands you already have.** You're not inventing a
   build/test pipeline — you're naming it. Set `VERIFY_STATIC` / `VERIFY_UNIT` /
   `VERIFY_E2E` to your existing lint/test/e2e commands, `UP_CMD` + `HEALTH_URL`
   to however you already start the app, and `VERIFY_PATH_FILTER` to your source
   paths. Leave any layer blank if you don't have it yet.

3. **Merge, don't replace, the colliding files:**
   - **`AGENTS.md`** — if one exists, keep your project content and fold in the
     harness's hard rules + the clock-in/clock-out loop. If not, use the kit's.
   - **`CLAUDE.md`** — keep yours; add a pointer to `AGENTS.md` and that
     `verify.sh` exit 0 is the Definition of Done. (`/configure` will offer to
     merge rather than overwrite.)
   - **`.gitattributes`** — *append* the three `merge=union` lines; don't clobber
     your existing attributes.
   - **`.gitignore`** — add `.agent/`, `harness.env`, `.claude/settings.local.json`.

4. **Handle an existing pre-commit hook.** `init.sh` will **not** overwrite a
   foreign `.git/hooks/pre-commit` — it warns and leaves yours in place. To get
   the harness's verify-on-commit gate, chain them: rename yours (e.g. to
   `pre-commit.local`), install the harness hook, and add a line to it that calls
   your saved hook. (It only manages a hook it recognises as its own.)

5. **Seed the ledger from work already in flight — or start clean.** You do *not*
   need to backfill history. Bring the ledger up (one per box), then either `raise` a row for each
   open piece of work, or leave it empty and raise going forward. The example roster row is retired
   and cannot claim: add your real agents.

6. **Existing tests already red?** That's fine — `verify.sh` will report it. Adopt
   the rule *"a ticket is `passing` only when verify is green"* from the next
   ticket onward; you don't have to make the whole suite pass on day one.

7. **Clock in and restart your agent** — steps 4–5 of the paths above. In Claude
   Code, `/configure` automates most of this: it detects your stack, asks before
   reconfiguring an existing `harness.env`, and prefers merging `CLAUDE.md`.

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
# … raise a row and claim it (ledger-db.sh raise <json>; feature-ticket.sh claim <id>) BEFORE coding …
bash scripts/verify.sh          # exit 0 == done; then mark the ticket "passing"
bash scripts/ledger-db.sh flip-passing <id> <pr> && bash scripts/ledger-db.sh archive <id> "<why>" && bash scripts/feature-ticket.sh release <id>   # after the merge
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

- **Per-ticket ledger.** The work queue is a database row per ticket, so two agents raising/flipping different
  tickets never touch the same file. (A single shared JSON array was the conflict
  source — arrays can't union-merge.) `passing` tickets move to
  the row's status (`archive` is a verb, not a file move).
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
  (the ledger row stays the source of truth; the PR says `Part of #N`, never `Closes`, so the issue never closes over a live row
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
enumerating instructions it can ignore. The `L0N` references in the script
headers point back to these lectures.

Each part maps to a lecture's driver:

| Part | Lecture | Driver it embodies |
|---|---|---|
| `AGENTS.md` — a short router to `CLAUDE.md` / docs | **L04** | One giant instruction file fails — keep the entry file small; link, don't inline. |
| `PROGRESS.md`, `.agent/session.active` | **L05** | Long-running tasks lose continuity — carry state across sessions in files, not chat. |
| `DECISIONS.md`; "the repo *is* the spec" | **L03** | The repo is the single source of record. |
| `scripts/init.sh` — the bootstrap contract | **L06** | Initialization is its own phase: can start, verify, see progress, pick up next — *before* coding. |
| the ledger (`infra/ledger-db/` + `ledger-db.sh` + `feature-ticket.sh`) | **L08** | Feature lists are harness *primitives* — "documents can be ignored; primitives can't be bypassed." Each ticket carries the triple (behaviour, verification command, state). |
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
The per-ticket ledger rows, union-merge logs, and the `depends_on` frontier
are what make that safe: they remove the shared-file conflicts a single JSON
array created.

**What we deliberately defer.** **L11** — observability inside the harness (task
traces / OpenTelemetry, sprint contracts, evaluator rubrics, the
Planner→Generator→Evaluator split) — is not implemented. It's the highest-ceiling
lecture but the heaviest; revisit it as the agent fleet and eval needs grow.
[OBSERVABILITY.md](OBSERVABILITY.md) is the concrete adoption path (and there's a
commented `OBSERVABILITY` stub in `harness.env.example`).

The mechanism is the point — adjust freely.
