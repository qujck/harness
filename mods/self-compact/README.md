# self-compact

A Claude Code mod that lets an agent compact its own session at a stopping point of its choosing, and
asks it to find one when the compaction window is nearly full. The owner's design (2026-10-16): each agent
watches its own context; when it gets low it reaches a natural stopping point, saves its durable record, and
then asks to be compacted. Auto-compact at the window stays as the backstop.

It loads in every session on the machine and acts only on the session it runs in. After every main-loop
turn (a subagent's or fork's turns are passed through) it does one of two things:

- **A request is waiting.** `<state>/self-compact/<this session's id>.json` exists and is newer than the last
  one acted on (`<state>` is `$XDG_STATE_HOME`, else `$HOME/.local/state`). Its content is `{}` or
  `{"instructions": "<what the summary must keep>"}`. The mod calls the engine's own compact, the same call
  `/compact` makes, with those instructions, and logs `self-compact: compacted at the agent's request`. A
  file that is not a JSON object compacts nothing and is named once in the log. A hook's veto is reported,
  not retried. The agent may write the file at any time, not only when nudged: an early compaction after
  a milestone is the agent's call.
- **No request, and the count has reached the soft point.** The soft point is `COMPACT_AFTER` for this agent
  when the config file (below) gives one, else where 20% of the room remains. The room runs to the *hard
  point*: where this session actually auto-compacts, read from the engine's context breakdown each turn (its
  settled window less its auto-compact buffer, ~33k; a running session keeps the window it started with or the
  one `/autocompact` gave it, whatever the settings file says now). Without a breakdown the settings window
  less 33k stands in (measured 2026-10-16: auto-compact at 266.7k–269.3k on 300k, 217,132 on 250k). The mod submits one prompt, marked `[self-compact mod, not the owner]`, naming the
  figures and the exact path to write: finish at a natural stopping point, bring the durable record up to
  date, then write the file and end the turn. One nudge per fill: it re-arms only once the count has
  dropped, that is, after a compaction.

**The soft point, `COMPACT_AFTER`.** One file per box, `$XDG_CONFIG_HOME/self-compact/compact-after.json`
(`~/.config/...` when unset), read at every turn end, so a change needs no restart and no typing into any
session:

```json
{ "default": 200000, "agents": { "Vera": 230000 } }
```

`default` is the token count at which every agent is nudged; `agents` overrides it by name, the name being
the launch line's `GIT_AUTHOR_NAME` (more room for an agent that runs big suites). No file, or no entry for
this agent, means the 20% rule. A malformed file changes nothing and is named once in the log. The owner sets
the numbers (2026-10-16: default 200k, `autoCompactWindow` 300k, so auto-compact at ~267k and ~67k of room).

**The guard.** Every turn the status line shows `<used> used, nudge at <soft>, auto-compact at
<hard>, room <hard − soft>`. When the room is under 40,000 (`MIN_FINISH_ROOM`) the line ends in ⚠ and one log
line says so, naming whether the hard point was read from this session or estimated, and the remedy:
`/autocompact <window>` in that session, or a lower `COMPACT_AFTER`. That is the silent miss made loud: settings
raised while a running session kept its old window, or a soft point set too close.

**Writing the request in one command.** `bash mods/self-compact/compact-me.sh "<what the summary must keep>"`
writes `{"instructions": …}` to this session's own request path and tells you to end your turn. The session id
is `CLAUDE_CODE_SESSION_ID`, which Claude Code sets in every Bash an agent runs; without it, or with one that
is not a plain token, or with no state directory, the script refuses (exit 2, one line) rather than guess, since
a guessed id could only name a file no session reads. The write is atomic and the text is JSON-escaped.
`--self-test` runs its pure arms; `scripts/check-mods-tests-pass.sh` runs every mod's `*.sh --self-test` on every PR.

What it cannot do, by construction rather than by rule: it never types into any pane (the engine call is
not a keystroke, so nothing it does can be mistaken for the owner's typing or answer a prompt), and it
cannot reach another session (the only id in the path is its own, and the compact call takes no target).
The compact call runs between turns only and rejects during one, so a request written mid-turn is read at
that turn's end.

Install it, with every other mod in this folder, by naming the folder in the `env` block of
`~/.claude/settings.json` (each subfolder holding `.claude-plugin/plugin.json` loads as a mod; several
folders are separated by `:`):

```json
{ "env": { "CLAUDE_CODE_PLUGIN_DIRS": "/path/to/harness/mods" } }
```

It takes effect in sessions started after that. A running session does not reload `autoCompactWindow` from
settings either; `/autocompact 250000` in that session brings it onto the new window, and `claude --settings`
does not override it.

- `hooks/compact.ts` is the pure part: the request and config paths, the window arithmetic (soft point, hard
  point, guard), the nudge and status text, and the two parsers. `hooks/register.ts` reads and acts after each turn. `hooks/compact.test.ts` holds the
  tests, including the negative control (a garbled request compacts nothing).
- `claude plugin validate mods/self-compact` and `claude plugin test mods/self-compact` check it.
  `scripts/verify.sh` runs the tests on every PR through `scripts/check-mods-tests-pass.sh`.
  `.claude-plugin/types/`, which `tsconfig.json` extends, is written by Claude Code when it loads the mod
  and is not committed.
