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
AGENTS.md                # routing file for agents (fill the {{placeholders}})
PROGRESS.md              # mutable "what's happening now"
DECISIONS.md             # append-only architecture log
feature_list.json        # the work queue (WIP=1, status machine)
scripts/
  init.sh                # clock in
  verify.sh              # Definition of Done
  handoff.sh             # clock out gate
  git-hooks/pre-commit   # hard enforcement (installed by init.sh)
.claude/
  settings.json          # Claude Code hook wiring
  hooks/stop-check.sh        # per-turn lenient handoff warning
  hooks/user-prompt-check.sh # nudge to run init.sh
  skills/configure/SKILL.md  # /configure — fills every placeholder for you (Claude Code)
```

## Setup

### The fast path — `/configure` (Claude Code)

1. **Copy the kit into your repo root** (everything except this README):
   ```bash
   cp -r agent-harness/{scripts,.claude,AGENTS.md,PROGRESS.md,DECISIONS.md,feature_list.json,harness.env.example} /path/to/your-repo/
   ```

2. **Open the repo in Claude Code and run `/configure`.** The skill detects your
   stack, then **asks you to confirm or override every value** (it never assumes a
   command, path, or convention) and writes all of it for you: `harness.env`, the
   `AGENTS.md` / `DECISIONS.md` / `feature_list.json` placeholders, and a starter
   project-specific `CLAUDE.md`. This replaces steps 2–3 of the manual path below.

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

3. **Fill the `{{placeholders}}`** in `AGENTS.md` and `DECISIONS.md`, remove the
   `example_replace_me` entry in `feature_list.json`, and write a project-specific
   `CLAUDE.md` with your data model / runbook.

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
bash scripts/init.sh        # start of session
# … add a feature_list.json entry (not_started → in_progress) BEFORE coding …
bash scripts/verify.sh      # exit 0 == done; then mark the feature "passing"
bash scripts/handoff.sh     # end of session — must be green to clock out
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

## Design notes

The lecture references in the script comments (lec 6 / 9 / 10 / 12) trace back to
a harness-engineering framework: initialization is its own phase, agents can't
self-grade, only end-to-end testing proves boundary defects are absent, and every
session must leave a clean state. Adjust freely — the mechanism is the point.
