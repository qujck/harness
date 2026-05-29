# AGENTS.md

Single entry point for any agent (or human) starting a session in this repo.
Routing file — short on purpose.

> Replace the `{{PLACEHOLDERS}}` below, then delete this line.

---

## What is this project

{{ONE_PARAGRAPH: what it is, the stack, where it runs in production}}

Full project map and commands: [CLAUDE.md](CLAUDE.md) *(create this per-project; the harness doesn't ship one).*

---

## Hard rules — non-negotiable

1. **WIP=1.** Only one feature in [feature_list.json](feature_list.json) may be `status: "in_progress"` at a time. Add a new entry with `status: "not_started"` *before* writing code.
2. **Don't self-grade.** A feature is `passing` only after `bash scripts/verify.sh` exits 0. Do not edit `status` to `passing` by judgement.
3. **Definition of Done = `scripts/verify.sh` exits 0.** No other definition.
4. **Update `PROGRESS.md` at session end.** `scripts/handoff.sh` refuses to pass otherwise.
5. **Append to `DECISIONS.md`** for any architectural choice another agent might re-debate. Past decisions are binding until superseded.
6. {{PROJECT-SPECIFIC RULE — e.g. module isolation, naming, layering. Delete if none.}}

---

## Session entry — clock in

```bash
bash scripts/init.sh
```

Brings the stack up, waits on the health endpoint, installs the pre-commit hook, marks the session active, and prints the next non-`passing` feature. Then read: [PROGRESS.md](PROGRESS.md) → [feature_list.json](feature_list.json) → relevant docs for the area you're touching.

---

## Session exit — clock out

```bash
bash scripts/handoff.sh
```

Runs `verify.sh`, then checks: clean tree (or commits made), `PROGRESS.md` touched, no debug artifacts, `feature_list.json` WIP ≤ 1. Refuses to "pass" otherwise. **If it won't pass, fix the gap rather than working around it.** That's the whole point.

---

## Adding a feature — checklist

1. Append an entry to [feature_list.json](feature_list.json) with `status: "not_started"` **before** writing code. Include a real `verification_command` another agent could run.
2. Flip its status to `"in_progress"` (move any other `in_progress` to `blocked`/`not_started` first).
3. Implement it. {{project-specific layering notes}}
4. Run `bash scripts/verify.sh`. If exit 0, set `"passing"` and record the commit hash in `last_verified_commit`. If not, it's not done.
5. Update [PROGRESS.md](PROGRESS.md) and run `bash scripts/handoff.sh`.

---

## Configuration

All stack-specific commands live in `harness.env` (copied from `harness.env.example`).
The scripts themselves are generic — see that file to point the harness at this
project's build, test, e2e, and health-check commands.

First-time setup is automated: in Claude Code, run **`/configure`** — it detects
the stack, confirms every value with you, and fills `harness.env` plus the
placeholders in this file, `DECISIONS.md`, and `feature_list.json`, and writes a
starter `CLAUDE.md`. (Manual fallback: edit those files by hand — see `README.md`.)
