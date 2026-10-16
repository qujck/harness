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
- **No request, and 20% or less of the room remains.** The room is the *effective* window: `autoCompactWindow`
  from the merged settings (the model's window when unset) less the ~33k tokens auto-compact keeps back, since
  it fires that far short of the window (measured 2026-10-16: 266.7k–269.3k on 300k, so ~217k on 250k, where
  the nudge comes at 173.6k used and leaves ~43k to finish and save). The count is the session's own usage, as
  the status line has it. The mod submits one prompt, marked `[self-compact mod, not the owner]`, naming the
  figures and the exact path to write: finish at a natural stopping point, bring the durable record up to
  date, then write the file and end the turn. One nudge per fill: it re-arms only once the count has
  dropped, that is, after a compaction.

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

- `hooks/compact.ts` is the pure part: the request path, the window arithmetic, the nudge text and the
  request parser. `hooks/register.ts` reads and acts after each turn. `hooks/compact.test.ts` holds the
  tests, including the negative control (a garbled request compacts nothing).
- `claude plugin validate mods/self-compact` and `claude plugin test mods/self-compact` check it.
  `scripts/verify.sh` runs the tests on every PR through `scripts/check-mods-tests-pass.sh`.
  `.claude-plugin/types/`, which `tsconfig.json` extends, is written by Claude Code when it loads the mod
  and is not committed.
