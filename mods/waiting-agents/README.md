# waiting-agents

A Claude Code mod that tells the delivery lead when a team agent is stuck waiting for input, such as a
permission prompt, so nobody has to watch every pane.

It loads in every session on the machine and acts only in the one whose identity the roster gives the
`delivery-lead` role. Every ten seconds it reads each live session's `~/.claude/sessions/<pid>.json` (a file
whose process has gone, or whose pid now belongs to another process, is skipped). Each session is named by
the `GIT_AUTHOR_EMAIL` its launch line set, looked up in `agents/roster.json`, or failing that by its session
name. An active agent of any other role that has been waiting for 25 seconds is reported once, e.g.
`Wren waiting: permission prompt (proj:@1.%2)`, in a message marked as coming from the mod and not the owner;
it is reported again only after it has moved on and starts waiting afresh. Nothing is sent while the
delivery lead is mid-turn, so a wait that ends meanwhile is never reported. The delivery lead's status bar
shows `waiting-agents: watching N, M waiting`.

Install it for every session on the machine by naming the `mods` folder in the `env` block of
`~/.claude/settings.json` (each subfolder holding `.claude-plugin/plugin.json` loads as a mod, so every
mod in this repo installs with the one line; naming this mod's own folder still works):

```json
{ "env": { "CLAUDE_CODE_PLUGIN_DIRS": "/path/to/harness/mods" } }
```

It takes effect in sessions started after that. The session files are read from Claude Code's config
directory, `$CLAUDE_CONFIG_DIR` when set and `~/.claude` otherwise, so the mod's folder can live anywhere;
a poll that cannot find them logs `waiting-agents: …` once per poll in the delivery lead's session and sends
nothing.

- `hooks/watch.ts` reads the roster and the session files and decides who is due a report;
  `hooks/register.ts` polls and sends; `hooks/waiting.test.ts` holds the tests.
- `claude plugin validate mods/waiting-agents` and `claude plugin test mods/waiting-agents` check it.
  `scripts/verify.sh` runs the tests on every PR through `scripts/check-mods-tests-pass.sh`.
  `.claude-plugin/types/`, which `tsconfig.json` extends, is written by Claude Code when it loads the mod
  and is not committed.
