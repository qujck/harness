# Claude Code host config

Host-level config for Claude Code that lives outside any project repo and would otherwise have no
history. Same reason `caddy/`, `cloudflared/` and the Windows `*.ps1` helpers are in here: it is machine
state that is painful to reconstruct and impossible to review after the fact.

## `statusline.sh`

**This file IS the live status line — not a copy of one.** `~/.claude/settings.json` points its
`statusLine.command` straight at this path:

```json
"statusLine": { "command": "/home/peter/dev/download/claude/statusline.sh", "refreshInterval": 5 }
```

Claude Code pipes a JSON blob to it on stdin and renders the line it prints — model, agent name, cwd,
context gauge, weekly-limit gauge, and the running gate for *this* session.

There is deliberately no copy step and nothing to keep in sync: one file, so it cannot drift. Two
consequences worth knowing:

- **Editing it changes your status line immediately**, before you commit. Your working tree is the
  thing that runs.
- **Moving or deleting this directory breaks the status line**, and because a command that fails to run
  renders nothing, that shows up as a blank bar rather than an error. If you ever relocate this repo,
  update `statusLine.command` with it.

It must stay executable (`chmod +x`) — it is invoked directly, not via `bash <file>`.

Two things to know before editing it:

- **It must always exit 0.** A non-zero exit makes Claude Code render *nothing*, which presents as a
  completely blank status bar rather than an error. This has already happened once, from a bare
  `test &&` as the last statement.
- **It shares a wire format with another program it cannot see.** Agent identity is resolved from
  `~/.claude/agent-names/pid-<claude pid>`, written by `scripts/init.sh` in the `strength` repo, one
  line of `<name>TAB<worktree>`. Field 2 is what makes a recycled pid detectable. Change the shape on
  either side and the other must change with it — `bash scripts/init.sh --selftest` in that repo pins
  it.

Added here 2026-07-31, at the version that fixed the identity lookup
(`fix_statusline_cwd_fallback_names_the_wrong_agent`, qujck/strength#3994): the cwd fallback no longer
names whoever else owns the directory, and the recorded worktree is actually read.

It arrived as a copy alongside `~/.claude/statusline.sh` and was promoted to the live file the same day
— a copy would have drifted the first time anyone edited one side.
