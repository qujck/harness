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

0. **Work in an isolated checkout when more than one agent may run at once.** Across separate machines/clones you're already isolated. On ONE machine, before any git / build / `init.sh` work, check `git worktree list` and sibling session markers (`ls ../*/.agent/session.active`); if you'd otherwise share a checkout, `git worktree add ../<repo>-<stream> -b <your-branch> <main>` and work from there (set `PER_STREAM_STACKS=1` so each worktree gets its own stack). Two agents in one checkout corrupt each other (HEAD jumps branches → commits on the wrong branch, build outputs clash, ledger collides). Isolation is what makes parallel agents safe.
1. **One ticket per change.** Add a `features/<id>.json` ticket file with `status: "not_started"` *before* writing code; flip to `"in_progress"` when you start. Multiple may be `in_progress` across **isolated checkouts** — WIP is a handoff nudge, not a hard cap; worktree isolation + `depends_on` are the safety. See [features/README.md](features/README.md).
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

Brings the stack up, waits on the health endpoint, installs the pre-commit hook, marks the session active, and prints the next ready feature (highest priority whose `depends_on` are all `passing`). Then read: [PROGRESS.md](PROGRESS.md) → [features/](features/) → relevant docs for the area you're touching.

---

## Session exit — clock out

```bash
bash scripts/handoff.sh
```

Runs `verify.sh`, then checks: clean tree (or commits made), `PROGRESS.md` touched, no debug artifacts, and the ledger WIP (a nudge — see rule 1). Refuses to "pass" otherwise. **If it won't pass, fix the gap rather than working around it.** That's the whole point. With `PER_STREAM_STACKS=1`, a strict pass also tears this worktree's stack down (`KEEP_STACK=1` to keep it).

---

## Adding a feature — checklist

1. Add a `features/<id>.json` ticket file with `status: "not_started"` **before** writing code. Include a real `verification_command` another agent could run, and `depends_on` if it needs another ticket first. (Schema: [features/README.md](features/README.md).)
2. Flip its status to `"in_progress"`. In your own isolated checkout, others' `in_progress` tickets are fine.
3. Implement it. {{project-specific layering notes}}
4. Run `bash scripts/verify.sh`. If exit 0, set `"passing"` and record the commit hash in `last_verified_commit`, then `bash scripts/archive-passing.sh` to move it to the archive. If not, it's not done.
5. Update [PROGRESS.md](PROGRESS.md) and run `bash scripts/handoff.sh`.

---

## Configuration

All stack-specific commands live in `harness.env` (copied from `harness.env.example`).
The scripts themselves are generic — see that file to point the harness at this
project's build, test, e2e, and health-check commands.

First-time setup is automated: in Claude Code, run **`/configure`** — it detects
the stack, confirms every value with you, and fills `harness.env` plus the
placeholders in this file and `DECISIONS.md`, seeds the `features/` queue, and
writes a starter `CLAUDE.md`. (Manual fallback: edit those files by hand — see
`README.md`.)

### Parallel development

The **distributed** parallel-safe workflow is the default and needs no config:
the per-ticket ledger ([features/](features/)), `depends_on` / ready-frontier
scheduling, union-merge on the append-only docs, and rule 0 above. It works
across any number of separate clones / machines out of the box.

**Local** parallel — several git worktrees on ONE machine — is opt-in: set
`PER_STREAM_STACKS=1` in `harness.env` so each worktree gets its own isolated
docker stack (kernel-assigned ports). Needs a machine that can run several
stacks at once. See `README.md` → "Parallel development" for the full picture
and the GitHub/CI patterns that complement it (merge queue, ticket→issue mirroring).
