# waiting-agents

A Claude Code mod that tells the delivery lead when a team agent is stuck waiting for input, such as a
permission prompt, so nobody has to watch every pane, and nudges the delivery lead when team agents have been
idle for fifteen minutes, so the team stays active.

It loads in every session on the machine and acts only in the one whose identity the roster gives the
`delivery-lead` role. A session whose root holds no `agents/roster.json` (the house assistant's, or one started
outside a checkout), or whose identity is not the delivery lead's, has nothing to watch: it shows no status
line at all and logs nothing. The line exists only in the session that watches. Every ten seconds it reads each live session's `~/.claude/sessions/<pid>.json` (a file
whose process has gone, or whose pid now belongs to another process, is skipped). Each session is named by
the `GIT_AUTHOR_EMAIL` its launch line set, looked up in `agents/roster.json`, or failing that by its session
name. An active agent of any other role that has been waiting for 25 seconds is reported once, e.g.
`Wren waiting: permission prompt (proj:@1.%2)`, in a message marked as coming from the mod and not the owner;
it is reported again only after it has moved on and starts waiting afresh. Nothing is sent while the
delivery lead is mid-turn, so a wait that ends meanwhile is never reported. The delivery lead's status bar
shows `watching N, M waiting` (the engine prefixes every mod's line with the mod's name).

It is also the nudger. Every five minutes, in the delivery lead's session, it reads the rows the context
publisher writes (docs/context-publisher.md: `CONTEXT_DIR`, else `~/.local/state/<HARNESS_PROJECT>/context`,
resolved from the environment and `harness.env` as `scripts/lib/harness-env.sh` does, ignoring any row older
than two minutes). When active agents of any other role have been idle for fifteen minutes or more
(`LEAD_NUDGE_THRESHOLD_S` in `harness.env` or the environment), it queues one prompt into the delivery lead's
session, e.g. `[Automated nudge 1 of 2 from the waiting-agents mod, not from the owner; it assigns nothing.]
Team agents idle for 15 minutes or more: Wren, developer idle 19m. As delivery lead, check each one and keep
the team active.` A queued prompt runs as a turn of its own once the session is idle and never touches the
prompt box, so nothing the owner is typing there is disturbed. The same set of idle agents is nudged at most
twice, a full threshold apart, and the count survives a restart through the mod's store; a different set is a
new state. It never prods the idle agents and assigns nothing. Every verdict, holds included, is appended to
`lead-nudge.log` beside the context directory.

Install it for every session on the machine by naming the `mods` folder in the `env` block of
`~/.claude/settings.json` (each subfolder holding `.claude-plugin/plugin.json` loads as a mod, so every
mod in this repo installs with the one line; naming this mod's own folder still works):

```json
{ "env": { "CLAUDE_CODE_PLUGIN_DIRS": "/path/to/harness/mods" } }
```

It takes effect in sessions started after that. The session files are read from Claude Code's config
directory, `$CLAUDE_CONFIG_DIR` when set and `~/.claude` otherwise, so the mod's folder can live anywhere;
a poll that cannot find them logs the error once per poll in the delivery lead's session and sends
nothing.

- `hooks/watch.ts` reads the roster and the session files and decides who is due a report; `hooks/nudge.ts`
  decides who is idle and whether a nudge may go; `hooks/register.ts` polls and sends; `hooks/waiting.test.ts`
  and `hooks/nudge.test.ts` hold the tests.
- `claude plugin validate mods/waiting-agents` and `claude plugin test mods/waiting-agents` check it.
  `scripts/verify.sh` runs the tests on every PR through `scripts/check-mods-tests-pass.sh`.
  `.claude-plugin/types/`, which `tsconfig.json` extends, is written by Claude Code when it loads the mod
  and is not committed.
