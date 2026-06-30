---
name: configure
description: Configure the agent-harness for THIS repository. Use right after dropping the harness kit into a new project's root — it fills harness.env, the AGENTS.md / DECISIONS.md placeholders, seeds the features/ queue, and generates a starter CLAUDE.md. Detects the stack, then asks you to confirm or override every value rather than assuming. Trigger on "configure the harness", "set up the harness", "/configure".
---

# Configure the agent-harness

You are configuring the agent-harness for the repository it currently lives in.
The kit ships with placeholders spread across several files that are normally
filled by hand at different times; your job is to fill **all** of them in one
guided pass.

## Governing rule: ask, do not assume

This is the whole point of the skill. For **every** value below:

- If you can detect it from the repo, **propose** the detected value and ask the
  user to confirm or override it. Never silently adopt a detected value.
- If you cannot detect it unambiguously, **ask** — do not guess a command, path,
  port, or convention.
- Leave a `harness.env` command blank **only** when the user confirms that layer
  doesn't exist for this project (e.g. no e2e suite). Blank = "skip that step",
  not "I couldn't figure it out".
- **Some values are defined at different times.** A project often doesn't have an
  e2e command, a health URL, or a project-specific rule on day one. When the user
  says "not yet / decide later", do **not** guess — write the line as a commented
  `# TODO(configure): <what's missing>` above a blank value, and tell them to
  re-run `/configure` once it exists. The skill is re-runnable and only touches
  what's still unfilled unless asked to redo everything.

Use the `AskUserQuestion` tool for the structured choices and propose detected
defaults as the first option. Batch related questions so the user isn't
drip-fed. A wrong assumption here propagates into every generated file, so err
toward one more question.

## Step 0 — Preconditions

1. Confirm you are at the repo root: `harness.env.example`, `scripts/init.sh`,
   and `AGENTS.md` should all be present. If not, stop and tell the user to run
   this from the directory where they copied the kit.
2. If `harness.env` already exists, ask whether to reconfigure (and whether to
   overwrite the already-filled docs) before touching anything.
3. Get today's date for the DECISIONS.md stamp: run `date +%F`.

## Step 1 — Detect the stack (read-only)

Sweep the repo to form proposals. Do not write anything yet. Look for:

- **Language / build:** `package.json` (npm/pnpm/yarn — check `packageManager`
  and lockfiles), `*.csproj` / `*.sln` (dotnet), `go.mod` (go), `Cargo.toml`
  (cargo), `pyproject.toml` / `setup.py` (python), `pom.xml` / `build.gradle`
  (jvm), `Makefile`.
- **Scripts:** `package.json` `scripts` (build/lint/test/test:e2e), `Makefile`
  targets, a `scripts/` directory with `test`/`e2e`/`verify` files.
- **Stack / health:** `docker-compose*.yml` / `compose*.yml`, `Dockerfile`,
  `Procfile`. Note exposed ports and any `/health`-style endpoint.
- **e2e:** Playwright / Cypress configs, a `scripts/e2e.sh`, an `e2e*/` dir.
- **Repo layout:** top-level source dirs (`src/`, `backend/`, `frontend/`,
  `app/`, `lib/`, …), entry points, an existing README.

Summarise what you found before asking — the user corrects faster than they
recall.

## Step 2 — Interview (propose → confirm)

Walk these in order. Each maps to a `harness.env` variable (see
`harness.env.example` for the authoritative descriptions).

| Ask about | Variable | Notes |
|---|---|---|
| How to start the stack (idempotent), or "nothing to start" | `UP_CMD` | e.g. `docker compose up -d --build`; blank if no stack |
| Health endpoint + timeout | `HEALTH_URL`, `HEALTH_TIMEOUT` | only if there's a running service to probe |
| Tools that must be on PATH | `REQUIRED_TOOLS` | from the detected stack (e.g. `docker curl`, `dotnet`, `node`) |
| Static check (lint/typecheck/compile) | `VERIFY_STATIC` | blank skips the layer |
| Unit tests | `VERIFY_UNIT` | blank skips the layer |
| e2e suite | `VERIFY_E2E` | blank skips; needs the stack up |
| Browser/UI suite (opt-in, `RUN_UI=1`) | `VERIFY_UI` | blank if none |
| Which staged paths trigger a pre-commit verify | `VERIFY_PATH_FILTER` | regex; blank = always run |
| Debug-artifact patterns to block at handoff | `DEBUG_PATTERNS` | confirm the language-appropriate defaults |

### Parallel development

The **distributed** parallel-safe workflow (per-ticket `features/` ledger,
`depends_on`/ready-frontier, union-merge `.gitattributes`, worktree-isolation
rule) is the **default** — nothing to ask or switch on; it ships that way.

Only one thing to ask, and only when relevant — **local** parallel:

- **Only if the stack is docker-compose based:** "Will you run several git
  worktrees on this ONE machine, and can it run several container stacks at
  once?" If yes, set `PER_STREAM_STACKS=1` and collect `STACK_HEALTH_SERVICE`
  (the compose service that serves health), `STACK_HEALTH_CONTAINER_PORT` (its
  in-container port), and `STACK_HEALTH_PATH` (e.g. `/health`) — propose these
  from the detected compose file. If not, leave `PER_STREAM_STACKS=0` (they still
  get the distributed workflow across separate clones). Never enable it for a
  non-compose `UP_CMD`.

Then collect the **prose** the docs need:

- **One-paragraph project description** — what it is, the stack, where it runs in
  production. (Fills `AGENTS.md`.)
- **Project-specific hard rule**, if any — module isolation, naming, layering.
  Ask explicitly; if none, say so and the placeholder is deleted, not left.
- **Project-specific layering notes** for the "adding a feature" checklist, if
  any.
- **Whether to seed the first `features/<id>.json` ticket** now, or leave an empty
  queue. Either way the `features/example_replace_me.json` placeholder is removed.

## Step 3 — Write the files

Only after the interview, and only with confirmed values:

1. **`harness.env`** — copy from `harness.env.example` and substitute the
   confirmed values. Keep the explanatory comments.
2. **`AGENTS.md`** — replace every `{{…}}` placeholder with the confirmed prose;
   delete the "Replace the {{PLACEHOLDERS}}…" instruction line; delete any
   placeholder the user said doesn't apply (don't leave an empty `{{…}}`). Leave
   rule 0 (worktree isolation) and the "Parallel development" subsection in place —
   the distributed workflow is the default for every project.
3. **`DECISIONS.md`** — replace `{{DATE}}` with today's date from Step 0.
4. **The ledger (`features/`):** the queue is one file per ticket. Remove the
   `features/example_replace_me.json` placeholder; if seeding, write the first real
   ticket at `features/<id>.json` (the entry object alone — schema in
   `features/README.md`, with optional `depends_on` / `solo`). Otherwise leave the
   directory holding just `README.md`. Confirm `features/`, `.gitattributes`, and
   `feature_list.archive.jsonl` are committed (not gitignored).
5. **`CLAUDE.md`** — generate a starter (see below). Create it if absent;
   if one already exists, ask before overwriting and prefer merging. If
   `PER_STREAM_STACKS=1`, document that each worktree runs its own `init.sh` and
   that strict `handoff.sh` tears the stack down.

### Generating the starter CLAUDE.md

Write a real, project-specific `CLAUDE.md` from what you detected plus the
interview — not a generic template. Aim for these sections, dropping any that
don't apply:

- **Title + one-line description** (from the project description).
- **A pointer to the harness rules** — link `AGENTS.md` and state that
  `scripts/verify.sh` exit 0 is the only Definition of Done.
- **Project structure** — a short annotated tree of the real top-level dirs.
- **Stack** — languages, frameworks, datastores, package manager (detected).
- **Running locally** — the real `UP_CMD` / health URL / ports.
- **Verifying** — the confirmed verify commands.
- **Anything project-specific** the user gave you (rules, layering, data model).

Keep it accurate over comprehensive: every command must be one you confirmed,
every path one that exists. If you're unsure about a section, ask rather than
invent it.

## Step 4 — Verify your own output

1. Run `bash -n scripts/*.sh` and validate every ticket
   (`for f in features/*.json; do jq empty "$f" || echo "bad: $f"; done`) to
   confirm nothing is syntactically broken.
2. Confirm no `{{` placeholders remain: `grep -rn '{{' AGENTS.md DECISIONS.md`.
3. Show the user a concise summary of every file written and the key
   `harness.env` values.

## Step 5 — Hand off

Tell the user the remaining manual steps (do not do these silently):

1. **Gitignore the runtime bits** if not already: `.agent/` and
   `.claude/settings.local.json` (the kit's `.gitignore` already lists them —
   confirm they're present in this repo's `.gitignore`).
2. **Clock in:** `bash scripts/init.sh` (also installs the pre-commit hook).
   Offer to run it.
3. **Restart Claude Code** so it picks up `.claude/settings.json` (the Stop /
   UserPromptSubmit hooks). Hooks loaded at startup won't activate mid-session.

Do not mark anything "done" by judgement — the harness's own rule is that
`scripts/verify.sh` is the only Definition of Done.
