#!/bin/bash
# The team as a web page (harness team/agents-web.sh) on http://127.0.0.1:8787, with the same settings as the panel.
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
  printf '\n \033[1;37;41m NO BUDGET \033[0m\n\n %s\n is missing:%s\n\n The panel is NOT started, so it\n never shows old numbers.\n Fix the file, then:\n bash team-web.sh\n' \
    "$B" "$missing"
  exec sleep infinity
fi

# The project names the owner's budget adjustments file (~/.local/state/strength/agents-budget-adjust.tsv),
# the one strength's spawn wrapper reads; without it the panel would read harness's.
export HARNESS_PROJECT=strength
export ROSTER_FILE=/home/peter/dev/strength/agents/roster.json
# The names the owner sees in an agent's menu and tooltips; everything else keeps the roster's one spelling.
export AGENT_FULL_NAMES=/home/peter/dev/harness/box/agent-full-names.json
# How the page spells a name the roster's characters cannot hold.
export AGENT_SHOWN_NAMES=/home/peter/dev/harness/box/agent-shown-names.json
export CONTEXT_DIR=/home/peter/.local/state/strength/context
export AGENTS_DASH_CACHE=/home/peter/.local/state/strength/dash
# The Day log pane's merged PRs.
export AGENTS_PR_REPO=qujck/strength
# Colours: the harness defaults the roles to /color's (Vera purple); Ed's role has no default.
export AGENT_COLOUR_PRODUCTION_SUPPORT=orange
# The header's disk: the root volume, which holds Docker and the worktrees.
export AGENT_DISK_WATCH=/
# The phone: the public hostname and the Cloudflare Access team and audience tag live in a private file
# outside this repo, which is public. Without it the page still runs on 127.0.0.1, with no phone access.
P=/home/peter/.config/harness/team-web.env
if [ -r "$P" ]; then set -a; . "$P"; set +a; else echo "team-web: no $P, so no phone access (127.0.0.1 only)" >&2; fi
exec bash /home/peter/dev/harness/team/agents-web.sh
