# team/ — several agents on one box

The scripts that run a team of agent sessions side by side on one machine: start a developer or tester for one
ticket (`agent-spawn.sh`), stop it when the ticket has merged (`agent-bench.sh`), decide whether the week's usage
allows another start (`agents-budget.sh`), and watch the team (`agents-dash.sh`, `agent-context.sh`, or in a browser `agents-web.sh`, all fed by the
status-line row `statusline-publish.sh` publishes; the row's contract is `docs/context-publisher.md`). The row's
`activity` comes from `activity-hook.sh`, which the hooks call on every prompt, tool call, permission request and
stop, so a session blocked on a prompt or busy in a long tool call is not taken for idle. `install-claude-code.sh`
wires all three into `~/.claude/settings.json` once per box, asking first. The page's team button starts the team
through `team-start.sh` and, after a wind-down, waits on `team-paused.sh`: both are placeholders to wire up on the
workstation that runs the team.

**Needs.** The process section (`scripts/`: the roster, `harness.env`, the ledger's claims board), tmux, and a
Claude subscription whose usage the status line can read. Nothing in `scripts/` depends on this section.

**Optional.** A project whose agents each run on their own machine, or that watches its team another way, leaves
this directory out. `agent-onboard.sh` still prints the launch line; only the spawn, bench, budget and panel go.

Each script carries `--self-test` through `scripts/lib/selftest-flag.sh` and has a row in
`scripts/selftest-tiers.txt`.
