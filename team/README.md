# team/ — several agents on one box

The scripts that run a team of agent sessions side by side on one machine: start a developer or tester for one
ticket (`agent-spawn.sh`), stop it when the ticket has merged (`agent-bench.sh`, which also removes its Docker containers, `agent-containers.sh`), decide whether the week's usage
allows another start (`agents-budget.sh`), and watch the team (`agents-dash.sh`, `agent-context.sh`, or in a browser `agents-web.sh`, all fed by the
status-line row `statusline-publish.sh` publishes; the row's contract is `docs/context-publisher.md`). The row's
`activity` comes from `activity-hook.sh`, which the hooks call on every prompt, tool call, permission request and
stop, so a session blocked on a prompt or busy in a long tool call is not taken for idle; a compaction marks the
session compacting, which the page shows, until the session starts again. An agent that needs the owner but is
not blocked on a prompt runs `owner-wanted.sh "<one line>"`, and the page pulses it amber with that line until the
owner next types in its session. The delivery lead keeps the work the team means to start, as Now, Next and
Later, what is Parked, and what is Done, with `work-queue.py`, and the page's Work queue pane draws it on two tabs,
Doing and Done; Done splits at the stand-ups a stand-up log (`$AGENT_STANDUPS`) marks FINAL. An agent the owner has attached to
a Terminal pane's tab reads what the terminal prints, and shows a command only the owner's Send puts there, with
`agent-terminal` (`terminal.test.sh` tests it). Requests for the code reviewer and the test reviewer wait in
`review-queue.py` (`$AGENT_REVIEW_QUEUE`, else `review-queue.json` in the state directory; `review-queue.test.sh` tests it): a developer or
tester adds one in a fixed short form, the reviewer takes the next and closes it with its verdict, a clean one goes
straight to whoever is next and one with findings to the delivery lead, and the waiting-agents mod delivers each
notice once in the session it names. The Work pane
brings the pipeline, the work queue, the review queue (its Reviews tab) and the Day log together, by what each ticket needs. `install-claude-code.sh`
wires all three into `~/.claude/settings.json` once per box, asking first. The page's team button starts the team
through `team-start.sh`, a placeholder to wire up on the workstation that runs the team. Its wind-down ends with
each agent running `agent-stopped.sh`, which puts it in the stop file: the page closes its pane once that turn ends,
the lead's last, and the next start brings back those in the file. Before the team starts, and on the page's
Repositories button, `repos-update.sh` fast-forwards develop, main and master of the local repositories (`AGENT_REPOS_ROOT`,
else this one) where that is safe; the button shows how many are behind, checked every 15 minutes.

**Needs.** The process section (`scripts/`: the roster, `harness.env`, the ledger's claims board), tmux, and a
Claude subscription whose usage the status line can read. Nothing in `scripts/` depends on this section.

**Optional.** A project whose agents each run on their own machine, or that watches its team another way, leaves
this directory out. `agent-onboard.sh` still prints the launch line; only the spawn, bench, budget and panel go.

**A project's own way.** A project whose agents work in their own sibling worktrees, read the budget from a file
outside the checkout, need more environment, a stack check, more first-prompt text, a ticket lookup or its own
"is the work done" check before a bench sets the `AGENT_TREE_MODE`, `HARNESS_ENV_FILE`, `AGENT_LAUNCH_ENV`,
`AGENT_SPAWN_*` and `AGENT_BENCH_*` settings (`harness.env.example`, and the headers of `agent-spawn.sh` and
`agent-bench.sh`) instead of wrapping the two scripts. Unset, each is the harness's own behaviour. `agent-spawn.sh
spawn …` and `agent-spawn.sh bench …` (or `agent-bench.sh bench …`) are accepted, so one command can spawn and bench.

Each script carries `--self-test` through `scripts/lib/selftest-flag.sh` and has a row in
`scripts/selftest-tiers.txt`.
