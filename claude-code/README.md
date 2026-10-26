# claude-code/ — mods for Claude Code

Three mods, installed per box rather than per repo: one line in `~/.claude/settings.json`
(`"env": { "CLAUDE_CODE_PLUGIN_DIRS": "/path/to/this-repo/claude-code" }`) loads every subfolder in every session.

- `self-compact/`: an agent compacts itself at a stopping point of its choosing (`compact-me.sh`), nudged when the
  window is nearly full.
- `waiting-agents/`: tells the delivery lead when a team agent sits at a permission prompt or the team has gone idle.
- `read-guard/`: refuses a repeat Read of an image already in the context and an unbounded Read of a large file.

Each has its own README. They import Claude Code's mod types (`claude-code`, `claude-code/testing`); the generated
`.claude-plugin/types/` folders are gitignored. `claude plugin test claude-code/<mod>` runs one mod's tests, and
`scripts/check-mods-tests-pass.sh` runs them all on every PR.

**Needs.** Claude Code. `waiting-agents` reads `agents/roster.json` from the process section and `harness.env`.

**Optional.** A team on another agent leaves this directory out. The hooks and the `/configure` skill are not here:
Claude Code reads them from `.claude/` at the repo root, so that is where they stay.
