# Claude Code host config

Host-level config for Claude Code that lives outside any project repo and would otherwise have no
history. Same reason `caddy/`, `cloudflared/` and `install-startup-task.ps1` are in here: it is machine
state that is painful to reconstruct and impossible to review after the fact.

## `statusline.sh`

Deployed to **`~/.claude/statusline.sh`**. Claude Code pipes a JSON blob to it on stdin and renders the
line it prints — model, agent name, cwd, context gauge, weekly-limit gauge, and the running gate for
*this* session.

```bash
cp claude/statusline.sh ~/.claude/statusline.sh && chmod +x ~/.claude/statusline.sh
```

Two things to know before editing it:

- **It must always exit 0.** A non-zero exit makes Claude Code render *nothing*, which presents as a
  completely blank status bar rather than an error. This has already happened once, from a bare
  `test &&` as the last statement.
- **It shares a wire format with another program it cannot see.** Agent identity is resolved from
  `~/.claude/agent-names/pid-<claude pid>`, written by `scripts/init.sh` in the `strength` repo, one
  line of `<name>TAB<worktree>`. Field 2 is what makes a recycled pid detectable. Change the shape on
  either side and the other must change with it — `bash scripts/init.sh --selftest` in that repo pins
  it.

Copied here 2026-07-31, at the version that fixed the identity lookup
(`fix_statusline_cwd_fallback_names_the_wrong_agent`, qujck/strength#3994): the cwd fallback no longer
names whoever else owns the directory, and the recorded worktree is actually read.

**This is a copy, not the live file.** Nothing syncs it automatically — if you edit `~/.claude/statusline.sh`,
copy it back and commit, or the next change lands on top of a stale snapshot.
