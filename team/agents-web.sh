#!/usr/bin/env bash
# team/agents-web.sh — the team as a web page, on this machine only.
#
#   bash team/agents-web.sh               serve http://127.0.0.1:8787 (AGENT_WEB_PORT) until interrupted
#   bash team/agents-web.sh --self-test   the server's own checks, against fixtures
#
# WHAT IT SHOWS. Every running agent on the roster as a card, in sections by role (Lead, Developers, Testers,
# Reviewer, Others): its state, context, model, ticket, the last few minutes of its burn, and the last turns of its
# conversation (the owner's messages and its words, its messages with other agents, its tool calls folded). A card
# opens the agent's own view: its longer conversation and its terminal as it is on screen. Across the top: the
# week against the budget (green on it, amber while the week's contingency is being spent, red past an even share
# of the whole allowance), the team's combined activity, the disk (AGENT_DISK_WATCH) and the developers and testers
# on the bench, with the standing agents that are stopped. The page can also be laid out as tabs, or as a custom set of panes saved in the browser; one kind of
# pane is the Team transcript, every message between agents on the roster, with a name button to leave each agent out;
# another, Combined, is the conversations of every agent in the roles chosen as one, in time order, with its own lanes.
# A click on a turn in either goes to its agent. The Combined pane's lanes split the owner's: Owner is the owner's messages,
# Said each agent's own words. An agent's menu (a rest on, or a right click on, its row, tile or view header) opens
# it, or opens it alone in a new tab or window, as a Ctrl- or middle click on it does.
# A shell command the owner runs with ! in an agent's prompt shows as the owner's, with what it printed.
#
# WHAT IT DOES. Each card and view has a message box: a message is typed into the agent's tmux pane and Enter
# pressed, as agent-spawn.sh types a first prompt; images pasted into the page go with it as attachments; Esc stops
# a working turn. A full path to a document in an agent's words (~/... or /home/..., ending .md, .markdown, .txt,
# .sql or .log) is a link that opens it over the page, Markdown rendered, from under the home directory only; a
# custom File pane shows one such document, and a pane's grip drags it onto another to swap the two. While a question or permission prompt is open the box is shut and each option is a button that
# chooses it as its number does in the terminal; a Type something option is a box among them, and a multi-select
# question gets a Submit button. Only the page itself can send (its host and port, an X-Team-Say header another site's page cannot
# send, its own Origin), and it listens on 127.0.0.1 only. The header's power button asks the delivery lead to wind
# the team down, recording who was running, and pulses a square until team/team-paused.sh says it is paused and no
# agent is busy; then it shows ▶, which runs team/team-start.sh for those recorded and tells the lead to start the
# day. The leads, reviewer, process improvement and assistant start and stop one by one from their menus; a stopped
# one waits on the bench, and its Start is there. Both
# scripts are placeholders until wired up on the workstation that runs the team.
#
# WHERE THE NUMBERS COME FROM. What team/agents-dash.sh reads (agents/roster.json, Claude Code's session records,
# the context rows of docs/context-publisher.md, the panel's burn cache and claims board, team/agents-budget.sh),
# plus tmux and the tail of each agent's transcript. The claims board is read from the panel's cache; once that
# is a minute old the page reads the ledger again in the background.
#
# Settings, in harness.env: AGENT_WEB_PORT, AGENT_OWNER_NAME (how the owner's messages are labelled),
# AGENT_COLOUR_<ROLE>, and the budget's and the panel's own. Needs python3 (standard library only) and tmux.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"
# shellcheck source=../scripts/lib/harness-env.sh
. "$_here/../scripts/lib/harness-env.sh" 2>/dev/null || true

command -v python3 >/dev/null 2>&1 || { echo "agents-web: needs python3" >&2; exit 2; }
if selftest_requested "$@"; then exec python3 "$_here/lib/agents_web.py" --self-test; fi
exec python3 "$_here/lib/agents_web.py"
