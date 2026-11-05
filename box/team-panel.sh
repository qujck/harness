#!/bin/bash
# The team panel (harness team/agents-dash.sh) beside the delivery lead, started by restore-claude.sh.
# The owner's weekly budget comes from ONE file, which strength's spawn wrapper also reads, so the panel
# and the wrapper can never disagree. Without that file, or with any of its four values unset, the panel
# does not start: it says so in its pane and never falls back to old numbers.
B=/home/peter/.local/state/strength/agents-budget.env
missing=""
# Only the file may set these: a value inherited from the environment would hide a missing line.
unset AGENT_WEEK_PCT_PER_HOUR AGENT_WORK_DAYS AGENT_WORK_HOURS AGENT_WEEK_RESET
if [ -r "$B" ]; then
  set -a; . "$B"; set +a
  for k in AGENT_WEEK_PCT_PER_HOUR AGENT_WORK_DAYS AGENT_WORK_HOURS AGENT_WEEK_RESET; do
    [ -n "${!k}" ] || missing="$missing $k"
  done
else
  missing=" the whole file"
fi
if [ -n "$missing" ]; then
  printf '\n \033[1;37;41m NO BUDGET \033[0m\n\n %s\n is missing:%s\n\n The panel is NOT started, so it\n never shows old numbers.\n Fix the file, then:\n byobu respawn-pane -k -t %s\n' \
    "$B" "$missing" "${TMUX_PANE:-<this pane>}"
  exec sleep infinity
fi

# The project names the owner's budget adjustments file (~/.local/state/strength/agents-budget-adjust.tsv),
# the one strength's spawn wrapper reads; without it the panel would read harness's.
export HARNESS_PROJECT=strength
export ROSTER_FILE=/home/peter/dev/strength/agents/roster.json
export CONTEXT_DIR=/home/peter/.local/state/strength/context
export AGENTS_DASH_CACHE=/home/peter/.local/state/strength/dash
# Colours: the harness defaults the roles to /color's (Vera purple); Ed's role has no default.
export AGENT_COLOUR_PRODUCTION_SUPPORT=orange
exec bash /home/peter/dev/harness/team/agents-dash.sh
