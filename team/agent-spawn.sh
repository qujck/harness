#!/usr/bin/env bash
# team/agent-spawn.sh — start an onboarded developer or tester for ONE ticket: off the bench.
#
#   HARNESS_PROJECT=<project> bash team/agent-spawn.sh [spawn] developer|tester|delivery-lead|head-of-testing [--name <Name>] [--ticket <id> | --job "<job>"] [--model <model>] [--effort <level>] [--login <label>] --why "<reason>" [--owner-ok "<words>"] [--verification-support] [--dry-run]
#   HARNESS_PROJECT=<project> bash team/agent-spawn.sh bench <Name> [--dry-run] [--by-hand]   (team/agent-bench.sh)
#   bash team/agent-spawn.sh --self-test
#
# The delivery lead's way to grow the team for a ticket (docs/roles/delivery-lead.md, "The size of the
# team"). Its partner is team/agent-bench.sh, which stops the session once the ticket has merged.
#
# THE POOL IS THE ROSTER. A name is free when its row in agents/roster.json is ACTIVE, holds this role, and
# has no running session (team/lib/agent-session.sh: its tmux session, or a live Claude Code record
# carrying its address). Without --name one free name is picked at random, a dry run included, so start
# exactly the name a dry run printed with --name. A --name that is not free is refused, and with no name
# free it refuses and says so: onboard another (agent-onboard.sh) or bench a finished one.
#
# SPAWNING NEVER WRITES agents/roster.json. The name, its identity and its worktree are the onboarded
# agent's own and stay theirs on the bench; only onboarding and retiring change the roster.
#
# What it starts, in a detached tmux session `<project>-<name>` (watch it with `tmux attach -t =<that>`):
#
#   env <roster_launch_env> claude --worktree <project>-<name> --name <Name> [--model M] [--effort E] --remote-control <project>-<name> "<first prompt>"
#
#   identity     roster_launch_env: the same four GIT_* variables as the launch line agent-onboard.sh prints
#   model        --model, else AGENT_MODEL_DEV / AGENT_MODEL_TESTER (harness.env), else the account default
#   effort       --effort low|medium|high|xhigh|max, the reasoning efforts Claude Code takes, else "effort <level>" as
#                a clause of its own in --why ("routine fix, effort low"; a level elsewhere in the words, as in
#                "low effort high-risk change", is not one), else none: the session default. Any other level is a
#                usage error (exit 2). The record keeps it, so box/restore-claude.sh resumes the agent at it.
#   first prompt Claude Code's positional prompt: read the role document and AGENTS.md, run
#                `bash scripts/init.sh`, then a developer CLAIMS THE TICKET ITSELF (feature-ticket.sh claim):
#                a claim is stamped with the session's identity, so nobody can claim on its behalf. A tester
#                claims nothing; it tells the delivery lead it is ready to test the ticket.
#
#   remote       --remote-control <session>: every spawned session can be reached from claude.ai/code and the
#                Claude mobile app under its tmux session's name (owner, 2026-10-25), except one on a named login
#
# A LOGIN FOLLOWS THE NAME. A roster row's "login" is the login that agent always starts on: the owner's token in
# ~/.claude/logins/<label>.token (AGENT_LOGINS names another directory), through team/claude-as.sh in place of
# `claude`, so another subscription pays for that agent every time it is spawned while it stays a local member of the
# team. Such a session has no Remote Control (a login's token cannot carry it), and the record keeps the label so
# box/restore-claude.sh resumes it on the same login. Without --name a spawn with no --login picks only among names
# with no "login", and --login <label> only among the names whose "login" is that label; --name takes its row's login,
# and a --login naming another is refused (exit 1). --login with --name of a row that has none starts it on that login
# this once. A label is lower-case letters, digits and dashes (else a usage error, exit 2), and one with no token file
# is refused before anything starts (exit 1).
#
# THE BUDGET GATES DEVELOPERS ONLY (owner, 2026-10-25). Every run prints team/agents-budget.sh's line, or
# team/agents-day-budget.sh's while a day is open (its `day  on` / `day  over` read as `budget  on` / `over`; a
# verification day never reads over, nothing stops at its share):
#   developer  `budget  on` → start it and tell the owner in one line. `over`, or no budget / no reading →
#              ASK THE OWNER FIRST; a real spawn then needs their answer on the line, --owner-ok "<their words>",
#              and is refused without it. Never a flat refusal: the owner's OK is the way through. The words
#              must BE words: another flag ("--owner-ok --dry-run"), the "<their words>" placeholder pasted
#              unedited, blanks or a second line are a usage error (exit 2) and start nothing.
#   tester     started whatever the line says; the line is information. Testers are not budget-gated.
#   --verification-support  a developer started to fix what verification found starts whatever the budget line
#              says, with no owner's words: the work that makes a spent day's tickets pass is not new spending to
#              ask about (owner, 2026-10-31: "They'll need to spawn to fix verification errors"). It lifts the
#              budget gate AND the cap below (owner, same day: "it bypasses the cap, that's the point - there's
#              no limit during verification day"). The record's verdict reads `over:verification-support` (or
#              `on:…`, `cannot-tell:…`), with `:over-cap` added when it started at or over the cap, so the spawns
#              that went past either line this way stay countable.
# The budget never picks the model.
#
# THE LEADS HAND OVER BY SPAWNING EACH OTHER (owner, 2026-10-31). At the end of a development day the delivery
# lead spawns the head of testing, hands over, and is benched by them (team/agent-bench.sh); at the end of a
# verification day the reverse. A lead (delivery-lead or head-of-testing) is spawned with no ticket (--ticket is a
# usage error), is not budget-gated and is not counted against the cap: the record's verdict reads `lead`. Its first
# prompt names the other lead and says to read their latest session entry, the handover, before anything else. Its
# model is --model, else the account default.
#
# EVERY REAL SPAWN SAYS WHY THIS MODEL (owner, 2026-10-26, for developers and testers: "both please"). --why
# "<reason>" is the lead's reason for the model the agent starts on, whether named with --model or left to the
# role's: "first round of a new feature", "routine retest of a one-line fix". A real spawn without it is a usage
# error (exit 2) and starts nothing; the same words check as --owner-ok applies. A dry run without it says so.
#
# THE TICKET IS CHECKED BEFORE THE START, AND THE CLAIM AFTER (owner, 2026-10-26: "this stuff should be automatic").
# A developer spawned for a ticket is a developer who will hold it, so the spawn reads the row first (ticket-row,
# ticket-owner): no row, a finished or ungroomed status, or another holder refuses the spawn before anything
# starts, with the way out; a row already this name's is fine (a claim from an earlier session). The developer
# still claims it itself — a claim carries the session's identity — so after the start the spawn watches the row
# until the claim appears, up to AGENT_SPAWN_CLAIM_WAIT_S (600; 0 = do not wait), and if it does not, says so
# loudly and exits 1 with the agent running: an unclaimed ticket is work the board cannot see. A tester's
# ticket is not read or watched. AGENT_SPAWN_LEDGER names a stand-in for scripts/ledger-db.sh (the self-test's).
#
# EVERY REAL SPAWN IS RECORDED, one TSV line in ~/.local/state/<project>/agent-spawns.tsv (AGENT_SPAWN_LOG):
# time · name · role · ticket (job:<words> for a --job) · model · budget verdict · the owner's words (or -) · the budget
# line · why that model · who ran it (AGENT_SPAWNER, else the roster name of the session's GIT_AUTHOR_EMAIL, else -) ·
# the effort (or -) · the login (or -). That is where an off-budget start shows who said yes, and every start why it runs on its model; the
# start line prints the same. A real spawn needs HARNESS_PROJECT in the environment, or AGENT_SPAWN_LOG naming the
# file: the name lib/harness-env.sh derives from the repo directory does not count (from the harness checkout it
# says "harness", a log the project's own tools never read), so without either it is a usage error, exit 2, and
# starts nothing. A dry run writes no log and needs neither. (Owner, 2026-10-27; the budget verbs' rule from #53.)
#
# AGENT_SPAWN_BUDGET names a stand-in for agents-budget.sh (the self-test's hook, like agents-dash.sh's).
#
# THE CAP (owner, 2026-10-29: "make it configurable - start with 10"). AGENT_MAX_WORKING in harness.env is how
# many sessions may be WORKING at once; a spawn of EITHER role at or over it is refused unless the owner's words
# are on --owner-ok, exactly as the budget gates a developer. Working = a Claude Code session record
# (~/.claude/sessions/<pid>.json) whose process is alive and whose status is busy or shell, one per session. NOT
# the context rows' activity: that comes from a state file the activity hook leaves at "working" after Stop, so
# on 2026-10-29 the rows said 9–11 working while the session records said 1–3 (Alfred's review of #108); a cap
# counted from the rows would have refused every spawn. Unset = no cap, and the line says so.
# What the count is (Stephanie's review of #108/#110): the whole box, not one project, because every session
# on it draws on the one account; it includes the session running this spawn, so a cap of 10 is the caller and
# nine others; a session at "shell" may be a background command after the model went idle (box load, not
# tokens); and it is SOFT: a session just started is idle until its first prompt lands, so two spawns in one
# turn can both pass. If live records exist but none carries a status (the record's shape changed under a
# Claude Code update), the count is "?" and a spawn under a cap asks the owner, rather than reading 0 and
# never firing.
# Measured 2026-10-29: twelve sessions woke together at 06:03 and read 52 M tokens by 06:40; every one of them
# pays its whole context on every call, so the number working at once is the rate.
#
# THE SESSION IS MARKED. The started command carries HARNESS_SPAWNED=1 and HARNESS_TICKET=<id> (a lead:
# HARNESS_ROLE=<role>) in its environment, and the tmux session holds the same (tmux set-environment), with
# HARNESS_OWNER_OK=<the words> when there were some. team/work-marker-hook.sh reads HARNESS_TICKET at SessionStart;
# team/agent-bench.sh reads the session's markers (AGENT_BENCH_SPAWNED_ONLY, AGENT_BENCH_PRECHECK_CMD).
#
# A LEADING VERB is accepted and changes nothing: `agent-spawn.sh spawn <role> …` is `agent-spawn.sh <role> …`, and
# `agent-spawn.sh bench <Name> …` runs team/agent-bench.sh with the rest of the line, so a project's one spawn-and-bench
# command can be this script.
#
# PROJECT SETTINGS (harness.env, HARNESS_ENV_FILE, or the environment). Every one defaults to the behaviour above, so
# a project that sets none sees no change. Commands are run by bash in HARNESS_ROOT with stdin closed, so a
# relative `bash scripts/x.sh` names the project's own script.
#   AGENT_TREE_MODE=claude-worktree|sibling   where the agent works. claude-worktree (the default): `claude --worktree
#        <project>-<name>` from HARNESS_ROOT, as above. sibling: its own git worktree beside the main checkout,
#        <dir of the main checkout>/<project>-<name>, and `claude` started in it with no --worktree. A missing tree is
#        added detached at a freshly fetched origin/main. An existing one is RE-ENTERED: it must be a worktree of this
#        repository; it is fetched (`fetch --no-tags`, a dry run too), refused while `git status --porcelain` shows
#        anything or while HEAD holds a commit no origin branch has and main holds no copy of (spawn_commits_only_here),
#        and otherwise detached at origin/main. No branch is created, moved or deleted, and nothing is reset. Trust is
#        then asked of the tree or a folder above it below $HOME.
#   AGENT_LAUNCH_ENV="NAME=value …"   more environment for the started agent, after its identity (e.g.
#        MSBUILDDISABLENODEREUSE=1). Each word must be NAME=value with no blanks, or it is a usage error (exit 2).
#   AGENT_SPAWN_STACKS_CMD   a command asked before any start, a dry run too: it failing refuses the spawn, and so
#        does a header "(N/M agents" in what it prints with N >= M (scripts/agent-stacks.sh's: the box is out of
#        stacks, and the agent's init.sh would be refused). Exit 0 with no such header refuses too: cannot tell.
#        Unset = not asked.
#   AGENT_SPAWN_PROMPT_CMD   a command run with <name> <role> <ticket or -> <other lead or -> whose stdout is added to
#        the end of the first prompt (the team's pronouns, an identity check, a tester's brief). It failing refuses
#        the spawn: a prompt that could not be built is not started on. Unset = the prompt above as it is.
#   AGENT_SPAWN_TICKET_RESOLVE_CMD   a command run with the --ticket as given (an id, or a number like 6854) that
#        prints the ticket's id: exit 0 the id (every later step uses it), 1 no such ticket (refused), anything else
#        cannot tell (refused). Unset = the ticket is used as given.
#   AGENT_SPAWN_LEAD_NEEDS_PEER=1   a lead is refused when no lead of the OTHER lead role is active on the roster:
#        there would be no handover to read. Its prompt names that lead. Unset or 0 = any other lead, or none.
#   AGENT_SPAWN_REQUIRE_NAME=1   --name is required (a dry run and the real run then cannot pick different people).
#   AGENT_SPAWN_REQUIRE_TICKET=1   a developer or tester needs --ticket, or --job "<the job>" for work with no ticket.
#        A --job is the delivery lead's alone, whatever this says: the caller (who ran it, above) must be the
#        delivery-lead on the roster, or the spawn is refused (exit 1). The job is in the first prompt and the record.
#
# Exit: 0 started (or a dry run said what it would start) · 1 refused, or started but the claim never appeared ·
# 2 a usage error.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="$_here/$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"
PROJECT_GIVEN="${HARNESS_PROJECT:-}"   # before harness-env.sh derives one from the repo directory's name
ROOT_GIVEN="${HARNESS_ROOT:-}"         # likewise: a start line printed for a project's tree must carry it
# shellcheck source=lib/harness-env.sh
. "$_here/../scripts/lib/harness-env.sh"
export ROSTER_FILE="${ROSTER_FILE:-$HARNESS_ROOT/agents/roster.json}"
# shellcheck source=lib/roster.sh
. "$_here/../scripts/lib/roster.sh"
# shellcheck source=lib/agent-session.sh
. "$_here/lib/agent-session.sh"

USAGE="usage: agent-spawn.sh [spawn] developer|tester|delivery-lead|head-of-testing [--name <Name>] [--ticket <id> | --job \"<job>\"] [--model <model>] [--effort <level>] [--login <label>] --why \"<why that model>\" [--owner-ok \"<the owner's words>\"] [--verification-support] [--dry-run]"
SPAWN_LOG="${AGENT_SPAWN_LOG:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/agent-spawns.tsv}"
BUDGET_SH="${AGENT_SPAWN_BUDGET:-$_here/agents-budget.sh}"
DAY_BUDGET_SH="${AGENT_SPAWN_DAY_BUDGET:-$_here/agents-day-budget.sh}"
LOGINS="${AGENT_LOGINS:-$HOME/.claude/logins}"
CLAUDE_AS="$_here/claude-as.sh"
LEDGER_SH="${AGENT_SPAWN_LEDGER:-bash $_here/../scripts/ledger-db.sh}"
CLAIM_WAIT_S="${AGENT_SPAWN_CLAIM_WAIT_S:-600}"
CLAIM_POLL_S="${AGENT_SPAWN_CLAIM_POLL_S:-5}"
# The size of the agent's tmux session, columns x rows: tmux's own default is 80x24, which the agent's screen (and its
# terminal on the team page) wraps at until someone attaches.
SIZE="${AGENT_SESSION_SIZE:-240x60}"; [[ "$SIZE" =~ ^[0-9]+x[0-9]+$ ]] || SIZE=240x60
# The project settings (header, PROJECT SETTINGS). Unset, each is the harness's own behaviour.
TREE_MODE="${AGENT_TREE_MODE:-claude-worktree}"
LAUNCH_ENV="${AGENT_LAUNCH_ENV:-}"
STACKS_CMD="${AGENT_SPAWN_STACKS_CMD:-}"
PROMPT_CMD="${AGENT_SPAWN_PROMPT_CMD:-}"
RESOLVE_CMD="${AGENT_SPAWN_TICKET_RESOLVE_CMD:-}"
LEAD_NEEDS_PEER="${AGENT_SPAWN_LEAD_NEEDS_PEER:-0}"
REQUIRE_NAME="${AGENT_SPAWN_REQUIRE_NAME:-0}"
REQUIRE_TICKET="${AGENT_SPAWN_REQUIRE_TICKET:-0}"

# A project command (a setting above), run by bash in HARNESS_ROOT with stdin closed. $1 the command · the rest its
# arguments. Its exit and output are the command's.
spawn_project_cmd() {
  local c="$1"; shift
  ( cd -- "$HARNESS_ROOT" && bash -c "$c"' "$@"' agent-spawn "$@" ) </dev/null
}
# PURE: is this AGENT_LAUNCH_ENV? Words of NAME=value, no blanks inside a word, nothing else. $1 -> 0 | 1
spawn_launch_env_ok() {
  local w ws
  [[ "${1-}" != *[[:cntrl:]]* ]] || return 1
  read -ra ws <<<"${1-}"
  for w in ${ws[@]+"${ws[@]}"}; do [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*=[^\'\"\\]*$ ]] || return 1; done
  return 0
}
# PURE: stacks output -> "N M" from its "(N/M agents" header, or nothing when it has none.
spawn_stacks_nm() { [[ "${1-}" =~ \(([0-9]+)/([0-9]+)\ agents ]] && printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"; return 0; }
# PURE: the other lead's role. $1 a lead role -> the other one (nothing for any other role)
spawn_other_lead_role() { case "${1-}" in delivery-lead) printf head-of-testing ;; head-of-testing) printf delivery-lead ;; esac; }
# git with no repository inherited from a hook's environment (a spawn run from a hook would otherwise act on the
# hook's repository, not the tree named with -C).
spawn_git() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR git "$@"; }
# <tree>: the commits its HEAD holds that no origin branch has and main holds no copy of, one per line (sibling mode).
# A rebase merge rewrites a PR's commits and deletes its branch, so the tree it leaves behind holds only pre-rebase
# copies of what is on main. A copy is what `git cherry` marks "-": the same patch id. Each commit must be marked, not
# merely unmarked "+": cherry never lists a merge, and a merge can carry its own edits.
spawn_commits_only_here() {
  local tree="$1" unpushed copies c
  unpushed="$(spawn_git -C "$tree" rev-list HEAD --not --remotes=origin)" || return 1
  [[ -n "$unpushed" ]] || return 0
  copies="$(spawn_git -C "$tree" cherry origin/main HEAD)" || return 1
  copies=$'\n'"$copies"$'\n'
  for c in $unpushed; do
    [[ "$copies" == *$'\n- '"$c"$'\n'* ]] || printf '%s\n' "$c"
  done
}
# Has Claude Code's trust dialog been accepted for <path> exactly (claude-worktree mode), or with $2=up for <path> or
# a folder above it below $HOME (sibling mode: a tree is trusted through the folder the trees sit in)?
spawn_trusted() { # <path> [up]
  local state p home
  state="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"; state="${state:-$HOME/.claude.json}"
  [[ "${2-}" == up ]] || { jq -e --arg r "$1" '.projects[$r].hasTrustDialogAccepted == true' "$state" >/dev/null 2>&1; return; }
  [[ -r "$state" ]] || return 1
  p="$(realpath -m -- "$1")"; home="$(realpath -m -- "$HOME")"
  while [[ -n "$p" && "$p" != / && "$p" != "$home" ]]; do
    jq -e --arg p "$p" '.projects[$p].hasTrustDialogAccepted == true' "$state" >/dev/null 2>&1 && return 0
    p="${p%/*}"
  done
  return 1
}

# PURE: are these the owner's words? Not blank; not another flag (--dry-run after --owner-ok must not become the
# words, and start a real spawn); not the script's own "<their words>" placeholder pasted unedited; one line (a tab or
# newline would split the TSV record). $1 words -> 0 | 1
spawn_owner_ok_text_ok() {
  local t="${1-}" s
  s="${t#"${t%%[![:space:]]*}"}"                 # trimmed of leading blanks
  [[ -n "$s" && "$s" != -* && "$t" != *[[:cntrl:]]* ]] || return 1
  s="${s%"${s##*[![:space:]]}"}"                 # and of trailing blanks
  [[ "$s" == '<'*'>' ]] && return 1
  return 0
}
# PURE: what the budget line means for this role. $1 role · $2 agents-budget.sh's exit -> start | ask | info
spawn_budget_rule() {
  if [[ "$1" == delivery-lead || "$1" == head-of-testing ]]; then printf 'lead'
  elif [[ "$1" == tester ]]; then printf 'info'; elif [[ "$2" == 0 ]]; then printf 'start'; else printf 'ask'; fi
}

# How many sessions are working now: session records (<pid>.json) whose pid is alive and whose status is busy
# (in a model call or a tool) or shell (a command running, possibly after the model went idle), one per session
# id. $1 the sessions dir -> a count (0 with no records, no live process, or no jq), or "?" when live records
# exist but none carries a status (the shape has changed: say so rather than read 0). A record whose pid is
# gone is a session that ended.
spawn_working_count() {
  local f pid n=0 live=0 with_status=0 ids=""
  for f in "$1"/*.json; do
    [[ -e "$f" ]] || continue
    pid="$(basename -- "$f" .json)"; [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -0 "$pid" 2>/dev/null || continue
    jq -e . "$f" >/dev/null 2>&1 || continue
    live=$((live + 1))
    jq -e '.status | strings' "$f" >/dev/null 2>&1 && with_status=$((with_status + 1))
    ids+="$(jq -r 'select(.status == "busy" or .status == "shell") | .sessionId // "?"' "$f" 2>/dev/null)"$'\n'
  done
  if (( live > 0 && with_status == 0 )); then printf '?'; return; fi
  n="$(printf '%s' "$ids" | sort -u | grep -c .)" || true
  printf '%s' "$n"
}
# PURE: what the cap means now. $1 AGENT_MAX_WORKING (may be empty) · $2 working (a count, or "?")
#   -> none | open | full | unknown | bad   (unknown = a cap is set but the count cannot be read: ask)
spawn_cap_rule() {
  [[ -n "${1-}" ]] || { printf 'none'; return; }
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || { printf 'bad'; return; }
  [[ "$2" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
  if (( $2 >= $1 )); then printf 'full'; else printf 'open'; fi
}
# PURE: is this a ticket id? A ledger id (the ledger's own CHECK: ^[a-z][a-z0-9_-]{4,200}$) or a Jira key.
spawn_ticket_ok() { [[ "${1-}" =~ ^([a-z][a-z0-9_-]{4,200}|[A-Z][A-Z0-9]+-[0-9]+|#?[1-9][0-9]{0,8})$ ]]; }   # an id, a Jira key, or a ledger number (#6854)
# PURE: who holds the row, from a ticket-owner line. The database store answers `owner:<name>\tstood-down-by:<x>`;
# the Jira store answers the assignee's name alone. $1 line -> the name, or nothing
spawn_owner_of() { local f="${1%%$'\t'*}"; printf '%s' "${f#owner:}"; }
# PURE: may this developer be started for this row? Mirrors feature-ticket.sh's claim rules, so a spawn that
# would end in a refused claim is refused here, before an agent starts. $1 status · $2 holder · $3 name
#   -> claimable | yours | refused:no-row | refused:finished:<st> | refused:not-selected:<st> | refused:held-by:<who>
spawn_ticket_verdict() {
  local st="$1" who="$2" name="$3"
  [[ -n "$st" ]] || { printf 'refused:no-row'; return; }
  case "$st" in
    archived|passing|wont_do) printf 'refused:finished:%s' "$st"; return ;;
    selected|in_progress) ;;
    *) printf 'refused:not-selected:%s' "$st"; return ;;
  esac
  if [[ -n "$who" && "${who,,}" != "${name,,}" ]]; then printf 'refused:held-by:%s' "$who"
  elif [[ -n "$who" ]]; then printf 'yours'
  else printf 'claimable'; fi
}
# PURE: is this a model name Claude Code could take (an alias, a full id, a [1m]-style suffix)?
spawn_model_ok() { [[ "${1-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(\[[A-Za-z0-9]+\])?$ ]]; }
# PURE: is this a reasoning effort Claude Code takes (--effort)?
spawn_effort_ok() { case "${1-}" in low|medium|high|xhigh|max) return 0 ;; *) return 1 ;; esac; }
# PURE: is this a login's label (team/claude-as.sh's)?
spawn_login_ok() { [[ "${1-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }
# The login a roster name always starts on: its row's "login", else nothing. $1 name
spawn_login_of() { _roster_json | jq -r --arg n "$1" '[.agents[]? | select(.name == $n) | .login // ""] | first // ""' 2>/dev/null; }
# PURE: the effort a --why names as a clause of its own ("routine fix, effort low", "effort max; a migration"), else
# nothing. A level elsewhere in the words ("low effort high-risk change", "no need for effort max") is not one.
spawn_effort_in_why() {
  local re='(^|[,;.][[:space:]]*)effort[[:space:]]+(low|medium|high|xhigh|max)[[:space:]]*([,;.]|$)'
  if [[ "${1,,}" =~ $re ]]; then printf '%s' "${BASH_REMATCH[2]}"; fi
}

# The first prompt. $1 name · $2 role · $3 ticket (may be empty) · $4 the other lead, for a lead · $5 a job with no ticket
spawn_prompt() {
  local n="$1" r="$2" t="${3:-}" o="${4:-}" j="${5:-}" p
  if [[ "$r" == delivery-lead || "$r" == head-of-testing ]]; then
    p="You are $n, the $r, started by team/agent-spawn.sh to take over from ${o:-the other lead}."
    p+=" Read docs/roles/$r.md and AGENTS.md first, then run \`bash scripts/init.sh\`."
    p+=" Then read the handover, ${o:-the other lead}'s latest session entry"
    [[ -n "$o" ]] && p+=" (\`bash scripts/ledger-db.sh session-entries --agent $o --limit 1\`)"
    p+=", before anything else, and tell ${o:-them} you have it."
    printf '%s' "$p"; return
  fi
  p="You are $n, a $r on this project's agent team, started by team/agent-spawn.sh"
  if [[ -n "$t" ]]; then p+=" for ticket $t. That ticket is yours and you hold no other."
  elif [[ -n "$j" ]]; then p+=" for a job with no ticket: $j."
  else p+="."; fi
  p+=" Read docs/roles/$r.md and AGENTS.md first, then run \`bash scripts/init.sh\`."
  if [[ -z "$t" && -n "$j" ]]; then
    p+=" Then tell the delivery lead you are ready for that job."
  elif [[ -z "$t" ]]; then
    p+=" Then tell the delivery lead you are ready and ask which ticket is yours."
  elif [[ "$r" == developer ]]; then
    p+=" Then claim it yourself, \`bash scripts/feature-ticket.sh claim $t\`, and tell the delivery lead you have it."
    # without it a developer ends its first turn at the report and sits idle until someone sends a go (strength, 2026-11-01)
    p+=" Then start on it in the same turn: plan it and build it. Do not wait for a go."
  else
    p+=" A tester claims nothing: tell the delivery lead you are ready to test $t."
  fi
  printf '%s' "$p"
}

# The free names for a role, one per line, in roster order.
spawn_free_names() { # <role>
  local n r
  while IFS=$'\t' read -r n r; do
    [[ -n "$n" && "$r" == "$1" ]] || continue
    agent_session_running "$n" || printf '%s\n' "$n"
  done < <(roster_list_active)
}

spawn_self_test() {
  local fails=0 T out rc child=""
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
         else printf '  FAIL %s\n       want %q\n       got  %q\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  _has() { if grep -qF -- "$3" <<<"$2"; then printf '  ok   %s\n' "$1"
           else printf '  FAIL %s\n       no %q in:\n%s\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  _not() { if ! grep -qF -- "$3" <<<"$2"; then printf '  ok   %s\n' "$1"
           else printf '  FAIL %s\n       found %q in:\n%s\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  T="$(mktemp -d)" || return 2
  trap '[[ -n "$child" ]] && kill "$child" 2>/dev/null; rm -rf "$T"' RETURN

  # PURE arms
  spawn_ticket_ok feat_some_ticket && _t "a ledger id is a ticket" 0 0 || _t "a ledger id is a ticket" 1 0
  spawn_ticket_ok HAR-12 && _t "a Jira key is a ticket" 0 0 || _t "a Jira key is a ticket" 1 0
  spawn_ticket_ok 6854 && _t "a ledger number is a ticket" 0 0 || _t "a ledger number is a ticket" 1 0
  spawn_ticket_ok '#6854' && _t "a #ledger number is a ticket" 0 0 || _t "a #ledger number is a ticket" 1 0
  spawn_ticket_ok 0 && _t "zero is no ticket" 0 1 || _t "zero is no ticket" 1 1
  spawn_ticket_ok Har-12 && _t "a mixed-case key is no ticket" 0 1 || _t "a mixed-case key is no ticket" 1 1
  spawn_ticket_ok 'x;rm' && _t "a shell metacharacter is no ticket" 0 1 || _t "a shell metacharacter is no ticket" 1 1
  spawn_model_ok 'opus;rm' && _t "a model with ; is refused" 0 1 || _t "a model with ; is refused" 1 1
  spawn_model_ok 'opus[1m]' && _t "a [1m] model suffix is accepted" 0 0 || _t "a [1m] model suffix is accepted" 1 0
  spawn_effort_ok xhigh && _t "xhigh is an effort" 0 0 || _t "xhigh is an effort" 1 0
  spawn_effort_ok huge && _t "huge is no effort" 0 1 || _t "huge is no effort" 1 1
  _t "effort: a clause of the reason names it" "$(spawn_effort_in_why 'routine fix, Effort Medium')" medium
  _t "effort: the reason's first clause too" "$(spawn_effort_in_why 'effort max; a hard migration')" max
  _t "effort: the whole reason" "$(spawn_effort_in_why 'effort low')" low
  _t "effort: a level elsewhere in the words is not one" "$(spawn_effort_in_why 'low effort high-risk change')" ""
  _t "effort: nor inside a clause" "$(spawn_effort_in_why 'no need for effort max')" ""
  _t "owner: the database store's line gives the name" "$(spawn_owner_of $'owner:Ada\tstood-down-by:')" Ada
  _t "owner: the database store's line with nobody gives nothing" "$(spawn_owner_of $'owner:\tstood-down-by:Ben')" ""
  _t "owner: the Jira store's bare name gives the name" "$(spawn_owner_of 'Ada Lovelace')" "Ada Lovelace"
  _t "verdict: a selected, unclaimed row is claimable" "$(spawn_ticket_verdict selected '' Ada)" claimable
  _t "verdict: an in_progress row held by this name is yours" "$(spawn_ticket_verdict in_progress ada Ada)" yours
  _t "verdict: a row held by another is refused, naming them" "$(spawn_ticket_verdict in_progress Ben Ada)" refused:held-by:Ben
  _t "verdict: no row is refused" "$(spawn_ticket_verdict '' '' Ada)" refused:no-row
  _t "verdict: a finished row is refused" "$(spawn_ticket_verdict archived '' Ada)" refused:finished:archived
  _t "verdict: an ungroomed row is refused" "$(spawn_ticket_verdict not_started '' Ada)" refused:not-selected:not_started
  _t "rule: a developer on budget starts" "$(spawn_budget_rule developer 0)" start
  _t "rule: a developer over budget asks" "$(spawn_budget_rule developer 1)" ask
  _t "rule: a developer with no budget reading asks" "$(spawn_budget_rule developer 2)" ask
  _t "rule: a tester over budget is information only" "$(spawn_budget_rule tester 1)" info
  _t "rule: a tester with no reading is information only" "$(spawn_budget_rule tester 2)" info
  _t "cap: unset is no cap" "$(spawn_cap_rule '' 12)" none
  _t "cap: below it is open" "$(spawn_cap_rule 10 9)" open
  _t "cap: at it is full" "$(spawn_cap_rule 10 10)" full
  _t "cap: over it is full" "$(spawn_cap_rule 10 12)" full
  _t "cap: a non-number is bad" "$(spawn_cap_rule ten 1)" bad
  _t "cap: a count that cannot be read is unknown under a cap" "$(spawn_cap_rule 10 '?')" unknown
  _t "cap: and none without one" "$(spawn_cap_rule '' '?')" none
  local CD; CD="$(mktemp -d)"
  rec() { printf '{"pid":%s,"sessionId":"%s","status":"%s"}\n' "$1" "$2" "$3" > "$CD/$1.json"; }   # <pid> <session> <status>
  rec $$ s-busy busy; rec $PPID s-shell shell; printf 'not json\n' > "$CD/junk.json"
  _t "working count: a live busy and a live shell record are two" "$(spawn_working_count "$CD")" 2
  rec $$ s-busy idle
  _t "working count: a live idle record is not working" "$(spawn_working_count "$CD")" 1
  true & local DEAD=$!; wait "$DEAD"   # a pid that has certainly exited (pid_max is not a dead pid)
  rec "$DEAD" s-dead busy
  _t "working count: a busy record whose process is gone is a session that ended" "$(spawn_working_count "$CD")" 1
  _t "working count: no records is 0" "$(spawn_working_count "$CD/none")" 0
  rm -f "$CD"/*.json; rec $$ s-busy busy; sed -i 's/"status"/"state"/' "$CD/$$.json"
  _t "working count: live records with no status field cannot be read: ? not 0" "$(spawn_working_count "$CD")" '?'
  rm -rf "$CD"

  # FIXTURES: a project root with a roster, a stand-in tmux and claude on PATH, Claude Code records in a
  # throwaway config dir. Nothing here can start a real session: the only tmux on PATH is the stand-in.
  mkdir -p "$T/repo/agents" "$T/bin" "$T/claude/sessions"
  jq -n --arg r "$T/repo" '{projects: {($r): {hasTrustDialogAccepted: true}}}' > "$T/claude/.claude.json"
  cat > "$T/repo/agents/roster.json" <<'JSON'
{"agents":[
 {"name":"Lea","email":"lea@proj.local","role":"delivery-lead","status":"active"},
 {"name":"Vi","email":"vi@proj.local","role":"head-of-testing","status":"active"},
 {"name":"Ada","email":"ada@proj.local","role":"developer","status":"active"},
 {"name":"Ben","email":"ben@proj.local","role":"developer","status":"active"},
 {"name":"Cy","email":"cy@proj.local","role":"developer","status":"retired"},
 {"name":"Tess","email":"tess@proj.local","role":"tester","status":"active"}]}
JSON
  # new-session is the agent starting: when $T/ledger.claims-on-start exists, a started developer (its prompt
  # says to claim) "claims" the ticket at once, as a real one would after init; without it the row stays as it was.
  cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/tmux.log"
case "\$1" in
  has-session) grep -qxF -- "\${3#=}" "$T/tmux.sessions" 2>/dev/null ;;
  new-session) printf '%s\n' "\$4" >> "$T/tmux.sessions"
               if [ -e "$T/ledger.claims-on-start" ] && grep -q 'feature-ticket.sh claim' <<<"\$*"; then
                 n=\$(sed -n 's/.*--name \([A-Za-z]*\).*/\1/p' <<<"\$*"); printf 'in_progress\t%s\n' "\$n" > "$T/ledger.state"
               fi ;;
esac
EOF
  # a stand-in ledger-db.sh: the row is $T/ledger.state ("status<TAB>holder"); $T/ledger.down makes it unreachable
  cat > "$T/bin/ledger" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/ledger.log"
[ -e "$T/ledger.down" ] && { echo "ledger-db: cannot reach the ledger" >&2; exit 3; }
IFS=\$'\t' read -r st ow < "$T/ledger.state"
case "\$1" in
  ticket-row)   printf '%s\n' "\$st" ;;
  ticket-owner) printf 'owner:%s\tstood-down-by:\n' "\$ow" ;;
esac
EOF
  printf 'selected\t\n' > "$T/ledger.state"; touch "$T/ledger.claims-on-start"
  printf '#!/usr/bin/env bash\necho "stand-in claude: never run by the self-test" >&2; exit 1\n' > "$T/bin/claude"
  # a stand-in agents-budget.sh, steered by $T/budget.mode: on / over / (absent) none set
  cat > "$T/bin/budget" <<EOF
#!/usr/bin/env bash
case "\$(cat "$T/budget.mode" 2>/dev/null)" in
  on)   echo "budget  on: week 30% used of 44% planned so far"; exit 0 ;;
  over) echo "budget  over: week 61% used of 44% planned so far: ask the owner"; exit 1 ;;
  *)    echo "budget  none set (AGENT_WEEK_PCT_PER_HOUR in harness.env): ask the owner"; exit 2 ;;
esac
EOF
  # a stand-in agents-day-budget.sh, steered by $T/day.mode: on / over / (absent) no day open
  cat > "$T/bin/day" <<EOF
#!/usr/bin/env bash
case "\$(cat "$T/day.mode" 2>/dev/null)" in
  on)   echo "day  on: 7% of the day's 15% used (week 52%, from 45% at 08:00)"; exit 0 ;;
  over) echo "day  over: 16% of the day's 15% used (week 61%, from 45% at 08:00): write your durable record and pause"; exit 1 ;;
  *)    echo "day  none: no day open"; exit 3 ;;
esac
EOF
  chmod +x "$T/bin/tmux" "$T/bin/claude" "$T/bin/budget" "$T/bin/day" "$T/bin/ledger"
  : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"   # Ben is already running, in agent-spawn's own tmux session
  local sum0; sum0="$(cksum < "$T/repo/agents/roster.json")"
  run() { env -u AGENT_MODEL_DEV -u AGENT_MODEL_TESTER HARNESS_ROOT="${ROOT:-$T/repo}" HARNESS_PROJECT="${PROJ-proj}" ROSTER_DOMAIN=proj.local \
            ROSTER_FILE="${RF:-$T/repo/agents/roster.json}" CLAUDE_CONFIG_DIR="$T/claude" CONTEXT_DIR="$T/ctx" PATH="$T/bin:$PATH" \
            AGENT_SPAWN_BUDGET="$T/bin/budget" AGENT_SPAWN_DAY_BUDGET="$T/bin/day" AGENT_SPAWN_LOG="${LOGF-$T/spawns.tsv}" \
            AGENT_SPAWN_LEDGER="bash $T/bin/ledger" AGENT_SPAWN_CLAIM_WAIT_S="${CW:-2}" AGENT_SPAWN_CLAIM_POLL_S=1 \
            AGENT_SPAWN_FIXTURE_BIN="${FB:-$T/bin}" AGENT_LOGINS="$T/logins" bash "$SELF" "$@" ${WHYARGS[@]+"${WHYARGS[@]}"} 2>&1; }
  local WHYARGS=(--why "routine test")   # every run in this test says why its model, unless a test empties it

  # the pick: only Ada is free (Ben is running, Cy is retired, Tess is a tester, Lea the lead)
  out=""; for _ in 1 2 3 4 5 6; do out+="$(run developer --ticket HAR-12 --dry-run)"$'\n'; done
  _t "a dry run picks only the free developer" "$(grep -c '^would start ' <<<"$out")" 6
  _t "a running name is never picked" "$(grep -c 'would start Ben' <<<"$out")" 0
  _t "a retired name is never picked" "$(grep -c 'would start Cy' <<<"$out")" 0
  _has "the dry run names the name to start with --name" "$out" "would start Ada (developer) for HAR-12"
  _has "a developer's prompt tells it to start on its ticket without waiting for a go" "$(spawn_prompt Ada developer HAR-12)" "Do not wait for a go."
  _not "  …and a tester's prompt does not" "$(spawn_prompt Tia tester HAR-12)" "Do not wait for a go"
  _has "a dry run prints the budget line, to decide whether to ask the owner" "$out" "budget  none set"
  _has "  with no budget a developer dry run says to ask the owner first" "$out" "ask the owner first, in one line; start it with their words on --owner-ok"
  _has "  and the start line it prints carries the --owner-ok slot" "$out" '--owner-ok "<the owner'"'"'s words>"'
  _has "a dry run says Remote Control will be on" "$out" "with Remote Control on"
  _t "a dry run starts nothing" "$(grep -c '^new-session' "$T/tmux.log" 2>/dev/null || true)" 0
  _t "a dry run writes no roster" "$(cksum < "$T/repo/agents/roster.json")" "$sum0"

  out="$(run developer --name ben --dry-run)"; rc=$?
  _t "--name of a running agent is refused" "$rc" 1
  _has "  and the refusal lists the free names" "$out" "ben is not a free developer (free: Ada)"
  out="$(run developer --name Tess --dry-run)"; rc=$?
  _t "--name of another role's agent is refused" "$rc" 1
  out="$(run developer --name Cy --dry-run)"; rc=$?
  _t "--name of a retired agent is refused" "$rc" 1
  out="$(run developer --name ada --dry-run)"
  _has "--name takes the roster's spelling" "$out" "would start Ada (developer)"

  out="$(run developer --model 'opus;rm' --dry-run)"; rc=$?
  _t "a malformed model is refused as usage" "$rc" 2
  out="$(run developer --ticket 'x y' --dry-run)"; rc=$?
  _t "a malformed ticket is refused as usage" "$rc" 2
  out="$(run code-reviewer --dry-run)"; rc=$?
  _t "a role other than developer, tester or lead is refused" "$rc" 2
  out="$(run developer --frobnicate)"; rc=$?
  _t "an unknown argument is refused" "$rc" 2
  out="$(run --slef-test)"; rc=$?
  _t "a mistyped self-test flag exits 2, never runs" "$rc" 2

  # ── THE BUDGET GATES DEVELOPERS ONLY (owner, 2026-10-25) ──
  printf 'AGENT_MODEL_DEV=sonnet\n' > "$T/repo/harness.env"
  printf 'over\n' > "$T/budget.mode"; : > "$T/tmux.log"; rm -f "$T/spawns.tsv"
  out="$(run developer --ticket HAR-12)"; rc=$?
  _t "a developer spawn off budget without the owner's OK is refused" "$rc" 1
  _has "  and says how to ask and how to pass the answer" "$out" '--owner-ok "<their words>"'
  _has "  and that a tester would not be gated" "$out" "a tester is not budget-gated"
  _t "  starting nothing" "$(grep -c '^new-session' "$T/tmux.log" 2>/dev/null || true)" 0
  _t "  recording nothing" "$([[ -e "$T/spawns.tsv" ]] && echo written || echo nothing)" nothing

  # ── AN OPEN DAY ANSWERS INSTEAD OF THE WEEK'S EVEN PACING (owner, 2026-10-31) ──
  printf 'on\n' > "$T/day.mode"; : > "$T/tmux.log"
  out="$(run developer --ticket HAR-12 --dry-run)"
  _has "a day on budget lets a developer start though the week's line is over" "$out" "day  on: 7% of the day's 15% used"
  _t "  and the week's line is not asked" "$(grep -c "budget  over" <<<"$out")" 0
  printf 'on\n' > "$T/budget.mode"; printf 'over\n' > "$T/day.mode"; rm -f "$T/spawns.tsv"
  out="$(run developer --ticket HAR-12)"; rc=$?
  _t "a day over its share refuses a developer though the week's line is on" "$rc" 1
  _has "  and shows the day's line" "$out" "day  over: 16%"
  _t "  starting nothing" "$(grep -c '^new-session' "$T/tmux.log" 2>/dev/null || true)" 0
  rm -f "$T/day.mode"; printf 'over\n' > "$T/budget.mode"
  out="$(run developer --ticket HAR-12 --dry-run)"
  _has "a developer dry run off budget says to ask the owner first" "$out" "developer, off budget (or no reading): ask the owner first"
  out="$(run tester --ticket HAR-12 --dry-run)"
  _has "a tester dry run off budget says to start it regardless" "$out" "testers are not budget-gated"
  _has "  and still prints the budget line" "$out" "budget  over"
  out="$(run tester --ticket HAR-12)"; rc=$?
  _t "a tester spawn off budget starts without any OK" "$rc" 0
  _t "  and is recorded with no owner words" "$(awk -F'\t' '$2=="Tess"{print $3"|"$6"|"$7}' "$T/spawns.tsv")" 'tester|over|-'
  # ── THE CAP GATES EVERY ROLE (owner, 2026-10-29) ──
  printf 'on\n' > "$T/budget.mode"; mkdir -p "$T/ctx" "$T/claude/sessions"; : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"   # Tess is free again
  # Session records are what count: three live busy/shell ones, one busy whose process is gone, and a context row
  # left at "working" for an agent with no busy record (the activity hook leaves that behind after Stop).
  sleep 300 & local SLP=$!; trap 'kill "$SLP" 2>/dev/null' RETURN
  true & local DEAD=$!; wait "$DEAD"
  mk() { printf '{"pid":%s,"sessionId":"%s","status":"%s"}\n' "$1" "$2" "$3" > "$T/claude/sessions/$1.json"; }
  mk $$ s1 busy; mk $PPID s2 shell; mk "$DEAD" s3 busy
  printf '{"agent":"Zoe","activity":"working","ts":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$T/ctx/Zoe.json"
  out="$(run tester --ticket HAR-12 --dry-run)"
  _has "a fresh working context row with no busy record is not counted, nor a busy record whose process is gone" "$out" "working 2 sessions now"
  mk "$SLP" s4 busy
  out="$(run tester --ticket HAR-12 --dry-run)"
  _has "with no cap set the dry run counts the working sessions and says there is no cap" "$out" "working 3 sessions now (no cap: AGENT_MAX_WORKING in harness.env)"
  printf 'AGENT_MODEL_DEV=sonnet\nAGENT_MAX_WORKING=3\n' > "$T/repo/harness.env"
  : > "$T/tmux.log"; before=$(wc -l < "$T/spawns.tsv")
  out="$(run tester --ticket HAR-12)"; rc=$?
  _t "a tester spawn at the cap without the owner's OK is refused" "$rc" 1
  _has "  naming the cap" "$out" "working 3 of up to 3 sessions: at the cap"
  _t "  starting nothing, recording nothing" "$(grep -c '^new-session' "$T/tmux.log")/$(wc -l < "$T/spawns.tsv")" "0/$before"
  out="$(run developer --ticket HAR-12)"; rc=$?
  _t "a developer spawn ON budget but at the cap is refused too" "$rc" 1
  out="$(run developer --ticket HAR-12 --dry-run)"
  _has "a dry run at the cap says to ask whatever the role" "$out" "at the cap (working 3 of up to 3 sessions): ask the owner first"
  out="$(run tester --ticket HAR-12 --owner-ok 'yes, one more, Peter')"; rc=$?
  _t "a tester spawn at the cap WITH the owner's OK starts" "$rc" 0
  _has "  and prints the cap line" "$out" "working 3 of up to 3 sessions"
  printf 'AGENT_MODEL_DEV=sonnet\nAGENT_MAX_WORKING=4\n' > "$T/repo/harness.env"
  : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"
  out="$(run tester --ticket HAR-12)"; rc=$?
  _t "below the cap a tester starts as before" "$rc" 0
  printf 'AGENT_MODEL_DEV=sonnet\nAGENT_MAX_WORKING=ten\n' > "$T/repo/harness.env"
  : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"
  out="$(run tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "a cap that is not a number is a usage error" "$rc" 2
  printf 'AGENT_MODEL_DEV=sonnet\nAGENT_MAX_WORKING=10\n' > "$T/repo/harness.env"
  sed -i 's/"status"/"state"/' "$T/claude/sessions"/*.json; : > "$T/tmux.log"; before=$(wc -l < "$T/spawns.tsv")
  out="$(run tester --ticket HAR-12 --dry-run)"
  _has "records with no status under a cap: the dry run says it cannot tell and asks" "$out" "cannot tell how many sessions are working (no status in"
  _has "  the spawn line carries --owner-ok" "$out" '--owner-ok "<the owner'"'"'s words>"'
  out="$(run tester --ticket HAR-12)"; rc=$?
  _t "  and a real spawn is refused, not let through on a count of 0" "$rc" 1
  _t "  starting nothing" "$(grep -c '^new-session' "$T/tmux.log")/$(wc -l < "$T/spawns.tsv")" "0/$before"
  out="$(run tester --ticket HAR-12 --owner-ok 'go on, Peter')"; rc=$?
  _t "  the owner's words start it" "$rc" 0
  kill "$SLP" 2>/dev/null; rm -f "$T/ctx"/*.json "$T/claude/sessions"/*.json; printf 'AGENT_MODEL_DEV=sonnet\n' > "$T/repo/harness.env"; printf 'over\n' > "$T/budget.mode"
  : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"
  out="$(run developer --ticket HAR-12 --owner-ok 'yes, start her, Peter')"; rc=$?
  _t "a developer spawn off budget WITH the owner's OK starts" "$rc" 0
  _has "  and the start line quotes the OK" "$out" 'owner OK: "yes, start her, Peter"'
  _t "  and the record holds who was started, on which verdict, on whose words" "$(awk -F'\t' '$2=="Ada"{print $3"|"$4"|"$5"|"$6"|"$7}' "$T/spawns.tsv")" 'developer|HAR-12|sonnet|over|yes, start her, Peter'
  _has "  and the budget line itself" "$(tail -1 "$T/spawns.tsv")" "budget  over: week 61%"

  # ── VERIFICATION SUPPORT LIFTS THE BUDGET GATE, NOT THE CAP (owner, 2026-10-31) ──
  : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"
  out="$(run developer --ticket HAR-12 --verification-support --dry-run)"
  _has "a developer dry run off budget with --verification-support says to start it" "$out" "developer, verification support: start it"
  out="$(run developer --ticket HAR-12 --verification-support)"; rc=$?
  _t "a developer spawn off budget with --verification-support starts without the owner's words" "$rc" 0
  _has "  and the start line says so" "$out" "; verification support"
  _t "  and the record's verdict says how it went past the line" "$(awk -F'\t' '$2=="Ada"{v=$6"|"$7} END{print v}' "$T/spawns.tsv")" 'over:verification-support|-'
  mk $$ s1 busy; printf 'AGENT_MODEL_DEV=sonnet\nAGENT_MAX_WORKING=1\n' > "$T/repo/harness.env"; : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"
  out="$(run developer --ticket HAR-12 --verification-support)"; rc=$?
  _t "  and at the cap it starts too, with no owner's words" "$rc" 0
  _has "  and the cap line says the cap was lifted" "$out" "at the cap, lifted for verification support"
  _t "  and the record's verdict says it went past the cap" "$(awk -F'\t' '{v=$6"|"$7} END{print v}' "$T/spawns.tsv")" 'over:verification-support:over-cap|-'
  : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"
  printf 'on\n' > "$T/budget.mode"; out="$(run developer --ticket HAR-12)"; rc=$?
  _t "  without the flag, a developer ON budget at the cap is refused" "$rc" 1
  _t "  starting nothing" "$(grep -c '^new-session' "$T/tmux.log" 2>/dev/null || true)" 0
  printf 'over\n' > "$T/budget.mode"
  # ── THE LEADS HAND OVER BY SPAWNING EACH OTHER (owner, 2026-10-31): no ticket, no budget gate, no cap ──
  : > "$T/tmux.log"; printf 'Ben\nLea\n' > "$T/tmux.sessions"
  out="$(run head-of-testing --dry-run)"; rc=$?
  _t "a lead dry run with no ticket passes" "$rc" 0
  _has "  its prompt names the lead it takes over from" "$out" "the head-of-testing, started by team/agent-spawn.sh to take over from Lea"
  _has "  and says to read the handover first" "$out" "session-entries --agent Lea --limit 1"
  _has "  and says it is not gated" "$out" "lead: start it to hand over"
  out="$(run head-of-testing --ticket HAR-12 --dry-run)"; rc=$?
  _t "a lead with a ticket is a usage error" "$rc" 2
  out="$(run head-of-testing)"; rc=$?
  _t "a lead spawn off budget AND at the cap starts with no owner's words" "$rc" 0
  _has "  and the cap line says it is not counted" "$out" "a lead is not counted against the cap"
  _t "  and the record's verdict is lead" "$(awk -F'\t' '{v=$3"|"$4"|"$6"|"$7} END{print v}' "$T/spawns.tsv")" 'head-of-testing|-|lead|-'
  rm -f "$T/claude/sessions"/*.json; printf 'AGENT_MODEL_DEV=sonnet\n' > "$T/repo/harness.env"; : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"
  out="$(run developer --owner-ok '' --dry-run)"; rc=$?
  _t "--owner-ok with no words is a usage error" "$rc" 2
  # F1 (from the review of the spawn gate): "--owner-ok --dry-run" must not take "--dry-run" as the owner's words and then
  # start a REAL spawn recorded as approved. F2: the script's own placeholders pasted unedited are not words either.
  : > "$T/tmux.log"; before=$(wc -l < "$T/spawns.tsv")
  out="$(run developer --ticket HAR-12 --owner-ok --dry-run 2>&1)"; rc=$?
  _t "--owner-ok followed by another flag is a usage error, not an approval" "$rc" 2
  _has "  naming what it got" "$out" 'got --dry-run'
  _t "  and starts nothing" "$(grep -c '^new-session' "$T/tmux.log")" 0
  _t "  and records nothing" "$(wc -l < "$T/spawns.tsv")" "$before"
  for ph in '<their words>' "<the owner's words>" '  <anything in angle brackets>  '; do
    out="$(run developer --ticket HAR-12 --owner-ok "$ph" --dry-run 2>&1)"; rc=$?
    _t "the placeholder $ph pasted unedited is a usage error" "$rc" 2
  done
  _t "  and nothing was started by any of them" "$(grep -c '^new-session' "$T/tmux.log")" 0
  _t "  nor recorded" "$(wc -l < "$T/spawns.tsv")" "$before"
  : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"   # Ada's spawn above is over; she is free again
  out="$(run developer --ticket HAR-12 --owner-ok 'yes <go ahead> - Peter' --dry-run 2>&1)"; rc=$?
  _t "words that merely contain brackets or a dash are words" "$rc" 0
  # Follow-ups from the same review: the trailing trim is what refuses a placeholder pasted
  # with a space after it; words that only START or only END with <…> are the owner's words.
  : > "$T/tmux.log"; before=$(wc -l < "$T/spawns.tsv")
  out="$(run developer --ticket HAR-12 --owner-ok '<their words> ' 2>&1)"; rc=$?
  _t "over budget, the placeholder with a trailing space is a usage error" "$rc" 2
  _t "  and starts nothing, records nothing" "$(grep -c '^new-session' "$T/tmux.log")/$(wc -l < "$T/spawns.tsv")" "0/$before"
  out="$(run developer --ticket HAR-12 --owner-ok '<Peter> said yes' --dry-run 2>&1)"; rc=$?
  _t "words that start with <…> are words" "$rc" 0
  out="$(run developer --ticket HAR-12 --owner-ok 'said yes <ok>' --dry-run 2>&1)"; rc=$?
  _t "words that end with <…> are words" "$rc" 0
  spawn_owner_ok_text_ok $'yes\tPeter' && _t "a tab in the words is refused (it would split the record)" 0 1 \
    || _t "a tab in the words is refused (it would split the record)" 1 1
  spawn_owner_ok_text_ok '  -yes' && _t "a leading dash after blanks is still a flag, not words" 0 1 \
    || _t "a leading dash after blanks is still a flag, not words" 1 1

  # a real start, on budget, with the role's model from harness.env; the row is selected and unclaimed again
  printf 'on\n' > "$T/budget.mode"; : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"; printf 'selected\t\n' > "$T/ledger.state"
  out="$(run developer --ticket HAR-12)"; rc=$?
  _t "a spawn exits 0" "$rc" 0
  _has "  and says how to watch it" "$out" "tmux attach -t =Ada"
  _has "  and that Remote Control is on" "$out" "with Remote Control on"
  _t "  on budget, recorded with no owner words" "$(awk -F'\t' '$2=="Ada"{v=$6"|"$7} END{print v}' "$T/spawns.tsv")" 'on|-'
  local line; line="$(grep '^new-session' "$T/tmux.log")"
  _has "  the session starts claude with Remote Control on, named for the tmux session" "$line" "--remote-control proj-ada"
  _has "it starts a detached tmux session named for the agent, at AGENT_SESSION_SIZE, in the project root" "$line" "new-session -d -s Ada -x 240 -y 60 -c $T/repo env"
  _has "  with the roster identity" "$line" "GIT_AUTHOR_NAME=Ada GIT_AUTHOR_EMAIL=ada@proj.local GIT_COMMITTER_NAME=Ada GIT_COMMITTER_EMAIL=ada@proj.local"
  _has "  in the agent's own worktree, named in the session" "$line" "claude --worktree proj-ada --name Ada"
  _has "  on the role's model (AGENT_MODEL_DEV)" "$line" "--model sonnet"
  _has "  told to read its role and init" "$line" "Read docs/roles/developer.md and AGENTS.md first, then run \`bash scripts/init.sh\`"
  _has "  and to claim the ticket itself" "$line" "bash scripts/feature-ticket.sh claim HAR-12"
  _has "  the row was read before the start" "$out" "ticket  HAR-12 is selected, unclaimed: Ada claims it after init"
  _has "  and the claim was seen after it" "$out" "claimed HAR-12 is Ada's"
  _t "a spawn writes no roster" "$(cksum < "$T/repo/agents/roster.json")" "$sum0"

  # ── THE TICKET IS CHECKED BEFORE THE START, AND THE CLAIM AFTER (owner, 2026-10-26) ──
  : > "$T/tmux.log"; : > "$T/ledger.log"; printf 'Ben\n' > "$T/tmux.sessions"
  for row in $'\t' $'archived\t' $'not_started\t' $'in_progress\tBen'; do
    printf '%s\n' "$row" > "$T/ledger.state"
    out="$(run developer --ticket HAR-12 --dry-run)"; rc=$?
    _t "a row that is '$row' refuses the spawn" "$rc" 1
  done
  printf '\n' > "$T/ledger.state"; out="$(run developer --ticket HAR-12)"
  _has "  no row says to raise it" "$out" "no row for HAR-12 on the ledger"
  printf 'archived\t\n' > "$T/ledger.state"; out="$(run developer --ticket HAR-12)"
  _has "  a finished row says so" "$out" "HAR-12 is 'archived': finished, not claimable"
  printf 'not_started\t\n' > "$T/ledger.state"; out="$(run developer --ticket HAR-12)"
  _has "  an ungroomed row says who grooms" "$out" "ask the PO to groom it to selected first"
  printf 'in_progress\tBen\n' > "$T/ledger.state"; out="$(run developer --ticket HAR-12)"
  _has "  another's row names the holder" "$out" "HAR-12 is held by Ben"
  _t "  none of them started anything" "$(grep -c '^new-session' "$T/tmux.log")" 0
  _t "  nor recorded a spawn" "$(awk -F'\t' '$4=="HAR-12"' "$T/spawns.tsv" | wc -l)" "$(awk -F'\t' '$4=="HAR-12"' "$T/spawns.tsv" | wc -l)"
  touch "$T/ledger.down"; out="$(run developer --ticket HAR-12 --dry-run)"; rc=$?
  _t "an unreachable ledger refuses: cannot tell is not free" "$rc" 1
  _has "  and says so" "$out" "could not read the ledger for HAR-12"
  rm -f "$T/ledger.down"
  printf 'in_progress\tAda\n' > "$T/ledger.state"; : > "$T/tmux.log"
  out="$(run developer --ticket HAR-12)"; rc=$?
  _t "a row already this name's starts without waiting" "$rc" 0
  _has "  and says the claim is from before" "$out" "HAR-12 is already Ada's"
  _t "  the agent started" "$(grep -c '^new-session' "$T/tmux.log")" 1
  printf 'selected\t\n' > "$T/ledger.state"; rm -f "$T/ledger.claims-on-start"; : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"
  before=$(wc -l < "$T/spawns.tsv")
  out="$(run developer --ticket HAR-12)"; rc=$?
  _t "a claim that never appears exits 1 with the agent running" "$rc" 1
  _has "  and says so loudly, naming agent, ticket and the way out" "$out" "Ada has NOT claimed HAR-12 after 2s"
  _has "  with how to tell them" "$out" "bash scripts/feature-ticket.sh claim HAR-12"
  _t "  the agent did start" "$(grep -c '^new-session' "$T/tmux.log")" 1
  _t "  and the spawn is recorded" "$(( $(wc -l < "$T/spawns.tsv") - before ))" 1
  printf 'selected\t\n' > "$T/ledger.state"; : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"
  out="$(CW=0 run developer --ticket HAR-12)"; rc=$?
  _t "AGENT_SPAWN_CLAIM_WAIT_S=0 starts without watching" "$rc" 0
  _has "  and says the claim is unwatched" "$out" "not watched (AGENT_SPAWN_CLAIM_WAIT_S=0)"
  touch "$T/ledger.claims-on-start"; printf 'selected\t\n' > "$T/ledger.state"; : > "$T/ledger.log"
  run tester --ticket HAR-12 >/dev/null
  _t "a tester's ticket is neither read nor watched" "$(grep -c . "$T/ledger.log")" 0
  printf 'Ben\nAda\n' > "$T/tmux.sessions"   # as after the real start above: Ben and Ada running

  # a project root Claude Code has not been trusted in: refused before anything starts
  cp "$T/claude/.claude.json" "$T/trusted.json"; printf '{"projects":{}}\n' > "$T/claude/.claude.json"
  : > "$T/tmux.log"
  out="$(run developer --dry-run)"; rc=$?
  _t "an untrusted project root is refused" "$rc" 1
  _has "  and says how to trust it" "$out" "accept the trust prompt"
  _t "  starting nothing" "$(grep -c '^new-session' "$T/tmux.log" 2>/dev/null || true)" 0
  mv "$T/trusted.json" "$T/claude/.claude.json"

  # now every developer is running: refused, with the way out
  out="$(run developer --dry-run)"; rc=$?
  _t "with every developer running it refuses" "$rc" 1
  _has "  and says to onboard another or bench one" "$out" "onboard another"
  printf '{"agents":[{"name":"Old","email":"old@proj.local","role":"developer","status":"retired"}]}\n' > "$T/none.json"
  out="$(RF="$T/none.json" run developer --dry-run)"; rc=$?
  _t "with no active developer onboarded it refuses" "$rc" 1
  _has "  and says nobody is onboarded, not that all are running" "$out" "no active developer is onboarded"

  # a tester: --model overrides the role's model, and a tester claims nothing
  printf 'AGENT_MODEL_TESTER=sonnet\n' > "$T/repo/harness.env"
  : > "$T/tmux.log"
  run tester --ticket feat_some_ticket --model opus >/dev/null; rc=$?
  line="$(grep '^new-session' "$T/tmux.log")"
  _t "a tester spawn exits 0" "$rc" 0
  _has "--model overrides the role's model" "$line" "--model opus"
  _t "  and the role's model is not also passed" "$(grep -c -- '--model sonnet' <<<"$line")" 0
  _has "a tester is told it claims nothing" "$line" "A tester claims nothing: tell the delivery lead you are ready to test feat_some_ticket."
  _t "  and is not told to claim" "$(grep -c 'feature-ticket.sh claim' <<<"$line")" 0

  # no model anywhere: no --model at all, so the account default applies
  : > "$T/repo/harness.env"; printf 'Ben\n' > "$T/tmux.sessions"; : > "$T/tmux.log"
  run developer >/dev/null
  line="$(grep '^new-session' "$T/tmux.log")"
  _t "with no model set, no --model is passed" "$(grep -c -- '--model' <<<"$line")" 0
  _has "with no ticket, it asks the lead for one" "$line" "ask which ticket is yours"

  # ── EVERY REAL SPAWN SAYS WHY THIS MODEL (owner, 2026-10-26) ──
  _t "the record's last column is why that model" "$(awk -F'\t' 'END{print $9}' "$T/spawns.tsv")" "routine test"
  printf 'on\n' > "$T/budget.mode"; printf 'Ben\n' > "$T/tmux.sessions"; : > "$T/tmux.log"
  out="$(WHYARGS=(); run tester --ticket HAR-12 --model opus --why 'first round of a new feature')"
  _has "the start line says the model and why" "$out" "on opus (first round of a new feature)"
  mkdir -p "$T/home"; : > "$T/tmux.log"; before=$(wc -l < "$T/spawns.tsv")
  out="$(PROJ='' LOGF='' HOME="$T/home" run tester --ticket HAR-12 --model opus)"; rc=$?
  _t "a real spawn with neither HARNESS_PROJECT nor AGENT_SPAWN_LOG is a usage error" "$rc" 2
  _has "  saying what it needs" "$out" 'a real spawn needs HARNESS_PROJECT=<project>'
  _t "  and starts nothing" "$(grep -c '^new-session' "$T/tmux.log" || true)" 0
  _t "  and records nothing, not even under a derived project" "$(find "$T/home" -name agent-spawns.tsv | wc -l)$(wc -l < "$T/spawns.tsv")" "0$before"
  cp "$T/tmux.sessions" "$T/tmux.sessions.kept"; : > "$T/tmux.sessions"   # a tester free to pick, whatever the project
  out="$(PROJ='' LOGF='' HOME="$T/home" run tester --ticket HAR-12 --model opus --dry-run)"; rc=$?
  mv "$T/tmux.sessions.kept" "$T/tmux.sessions"
  _t "a dry run needs neither" "$rc" 0
  _has "  and its start line asks for the project" "$out" "start exactly this one with: HARNESS_PROJECT=<project> HARNESS_ROOT=$T/repo bash $SELF tester"
  printf 'Ben\n' > "$T/tmux.sessions"
  out="$(run tester --ticket HAR-12 --model opus --dry-run)"
  _has "a dry run's start line carries the project it was given" "$out" "start exactly this one with: HARNESS_PROJECT=proj HARNESS_ROOT=$T/repo bash $SELF tester"
  printf 'Ben\n' > "$T/tmux.sessions"; : > "$T/tmux.log"; before=$(wc -l < "$T/spawns.tsv")
  WHYARGS=()
  out="$(run tester --ticket HAR-12 --model opus)"; rc=$?
  _t "a real spawn without --why is a usage error" "$rc" 2
  _has "  saying what it needs" "$out" 'a real spawn says why it runs on its model'
  for w in '<why that model>' '  ' '--dry-run' $'two\nlines'; do
    out="$(run tester --ticket HAR-12 --model opus --why "$w")"; rc=$?
    _t "  --why $(printf %q "$w") is not a reason" "$rc" 2
  done
  _t "  and none of them started or recorded anything" "$(grep -c '^new-session' "$T/tmux.log")/$(wc -l < "$T/spawns.tsv")" "0/$before"
  out="$(run tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "a dry run without --why still runs" "$rc" 0
  _has "  and says the real spawn needs it" "$out" "the real spawn needs --why"
  _has "  with the slot in the start line" "$out" '--why "<why that model>"'
  WHYARGS=(--why "routine test")

  # a session started by hand from the launch line (no tmux session of ours) still counts as running
  : > "$T/tmux.sessions"
  GIT_AUTHOR_EMAIL=ada@proj.local sleep 60 & child=$!
  printf '{"pid":%s,"sessionId":"s1","status":"idle","startedAt":%s}\n' "$child" "$(( $(date +%s) * 1000 ))" > "$T/claude/sessions/$child.json"
  out="$(run developer --name Ada --dry-run)"; rc=$?
  _t "a live Claude Code record carrying the agent's address makes it running" "$rc" 1
  printf '{"pid":4194300,"sessionId":"dead","name":"Ben","status":"idle"}\n' > "$T/claude/sessions/4194300.json"
  out="$(run developer --name Ben --dry-run)"; rc=$?
  _t "a record whose pid is dead does not" "$rc" 0

  # ── PROJECT SETTINGS: each one unset is the behaviour above, and each one set is shown to bite ──
  kill "$child" 2>/dev/null; wait "$child" 2>/dev/null; child=""; rm -f "$T/claude/sessions"/*.json
  : > "$T/repo/harness.env"; printf 'on\n' > "$T/budget.mode"
  fresh() { : > "$T/tmux.log"; printf 'Ben\n' > "$T/tmux.sessions"; }
  _starts() { grep -c '^new-session' "$T/tmux.log" 2>/dev/null || true; }

  # unset: the start line as before, with the session's markers added to its environment and to the tmux session
  fresh; out="$(run tester --ticket HAR-12)"; rc=$?; line="$(grep '^new-session' "$T/tmux.log")"
  _t "settings unset: a tester starts" "$rc" 0
  _has "  in claude's worktree, from the project root, as before" "$line" "-c $T/repo env GIT_AUTHOR_NAME=Tess"
  _has "  marked in its environment with the ticket it was spawned for" "$line" "GIT_COMMITTER_EMAIL=tess@proj.local HARNESS_SPAWNED=1 HARNESS_TICKET=HAR-12 claude --worktree proj-tess --name Tess"
  _has "  and on the tmux session, for the bench" "$(cat "$T/tmux.log")" "set-environment -t =Tess HARNESS_SPAWNED 1"
  _has "  the ticket too" "$(cat "$T/tmux.log")" "set-environment -t =Tess HARNESS_TICKET HAR-12"
  _not "  no stacks line (AGENT_SPAWN_STACKS_CMD unset)" "$out" "stacks  "
  _has "  the prompt ends as before (AGENT_SPAWN_PROMPT_CMD unset)" "$line" "tell the delivery lead you are ready to test HAR-12."
  fresh; out="$(run head-of-testing --owner-ok 'fine, Peter')"; rc=$?
  _has "a lead is marked with its role, and the owner's words ride on the session" "$(cat "$T/tmux.log")" "set-environment -t =Vi HARNESS_OWNER_OK fine, Peter"
  _has "  its role" "$(cat "$T/tmux.log")" "set-environment -t =Vi HARNESS_ROLE head-of-testing"
  fresh; out="$(run tester --ticket HAR-12 --dry-run)"
  _has "a start line names this script by its absolute path (it was a relative team/agent-spawn.sh)" "$out" "bash $SELF tester --name Tess"
  [[ "$SELF" == /* ]] && _t "  which is absolute" abs abs || _t "  which is absolute" "$SELF" abs

  # the leading verb: spawn changes nothing; bench is agent-bench.sh
  fresh; out="$(run spawn tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "'spawn <role> …' is '<role> …'" "$rc" 0
  _has "  and says the same" "$out" "would start Tess (tester) for HAR-12"
  out="$(WHYARGS=(); run bench Nobody --dry-run)"; rc=$?
  _t "'bench <Name>' runs agent-bench.sh" "$rc" 1
  _has "  whose refusal it is" "$out" "agent-bench: Nobody is not on the roster"

  # AGENT_SPAWN_REQUIRE_NAME / AGENT_SPAWN_REQUIRE_TICKET
  fresh; out="$(AGENT_SPAWN_REQUIRE_NAME=1 run tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "AGENT_SPAWN_REQUIRE_NAME=1: no --name is a usage error" "$rc" 2
  _has "  saying why" "$out" "AGENT_SPAWN_REQUIRE_NAME=1"
  out="$(AGENT_SPAWN_REQUIRE_NAME=1 run tester --name Tess --ticket HAR-12 --dry-run)"; rc=$?
  _t "  with --name it runs" "$rc" 0
  out="$(AGENT_SPAWN_REQUIRE_TICKET=1 run tester --dry-run)"; rc=$?
  _t "AGENT_SPAWN_REQUIRE_TICKET=1: a tester with no --ticket is a usage error" "$rc" 2
  out="$(run tester --dry-run)"; rc=$?
  _t "  unset, it runs and asks the lead for one" "$rc" 0
  out="$(AGENT_SPAWN_REQUIRE_TICKET=1 run head-of-testing --dry-run)"; rc=$?
  _t "  a lead needs none" "$rc" 0

  # --job: ticketless work, the delivery lead's alone, in the prompt and the record with who ran it
  out="$(AGENT_SPAWN_REQUIRE_TICKET=1 AGENT_SPAWNER=Lea run tester --job "check the docs build" --dry-run)"; rc=$?
  _t "AGENT_SPAWN_REQUIRE_TICKET=1: the delivery lead's --job stands in for a ticket" "$rc" 0
  _has "  and the dry run says what for" "$out" "for a job with no ticket: check the docs build"
  out="$(AGENT_SPAWN_REQUIRE_TICKET=1 AGENT_SPAWNER=Rex run tester --job "check the docs build" --dry-run)"; rc=$?
  _t "  anyone else's --job is refused" "$rc" 1
  _has "  saying it is the delivery lead's" "$out" "--job is the delivery lead's: Rex is not the delivery-lead"
  out="$(AGENT_SPAWNER= GIT_AUTHOR_EMAIL=LEA@proj.local run tester --job "check the docs build" --dry-run)"; rc=$?
  _t "  the caller is found from GIT_AUTHOR_EMAIL when AGENT_SPAWNER is unset" "$rc" 0
  out="$(AGENT_SPAWNER= GIT_AUTHOR_EMAIL= run tester --job "check the docs build" --dry-run)"; rc=$?
  _t "  and with no identity at all it is refused" "$rc" 1
  out="$(AGENT_SPAWNER=Lea run tester --ticket HAR-12 --job "x y" --dry-run)"; rc=$?
  _t "  --ticket and --job together are a usage error" "$rc" 2
  out="$(AGENT_SPAWNER=Lea run head-of-testing --job "x y" --dry-run)"; rc=$?
  _t "  a lead takes no --job" "$rc" 2
  out="$(AGENT_SPAWNER=Lea run tester --job "" --dry-run)"; rc=$?
  _t "  an empty --job is a usage error" "$rc" 2
  _has "the prompt carries the job" "$(spawn_prompt Tia tester "" "" "check the docs build")" "for a job with no ticket: check the docs build."
  fresh; rm -f "$T/spawns.tsv"; out="$(AGENT_SPAWNER=Lea run tester --name Tess --job "check the docs build")"; rc=$?
  _t "a real --job spawn starts" "$rc" 0
  _t "  and is recorded as job:<words>, with who ran it" "$(awk -F'\t' '$2=="Tess"{print $4"|"$10}' "$T/spawns.tsv")" 'job:check the docs build|Lea'
  fresh; rm -f "$T/spawns.tsv"; out="$(AGENT_SPAWNER= GIT_AUTHOR_EMAIL= run tester --name Tess --ticket HAR-12)"; rc=$?
  _t "a spawn with no known caller records - as who ran it" "$(awk -F'\t' '$2=="Tess"{print $4"|"$10}' "$T/spawns.tsv")" 'HAR-12|-'
  _t "  and - as the effort, with none given" "$(awk -F'\t' '$2=="Tess"{print $11}' "$T/spawns.tsv")" -
  _not "  and passes none to claude" "$(grep '^new-session' "$T/tmux.log")" "--effort"

  # --effort, or "effort <level>" as a clause of --why: claude starts at it, and the record keeps it for a restore
  fresh; rm -f "$T/spawns.tsv"; out="$(run tester --name Tess --ticket HAR-12 --model opus --effort LOW)"; rc=$?
  _t "--effort: the spawn starts" "$rc" 0
  _has "  claude at that effort, after the model" "$(grep '^new-session' "$T/tmux.log")" "--model opus --effort low --remote-control"
  _has "  and the start line says it" "$out" "on opus at effort low (routine test)"
  _t "  the record's eleventh column is the effort, and the last the login" "$(awk -F'\t' 'END{print NF"|"$11"|"$12}' "$T/spawns.tsv")" '12|low|-'
  fresh; out="$(WHYARGS=(); run tester --name Tess --ticket HAR-12 --why "deep retest, effort xhigh")"; rc=$?
  _has "\"effort <level>\" in --why sets it" "$(grep '^new-session' "$T/tmux.log")" "--effort xhigh"
  fresh; out="$(WHYARGS=(); run tester --name Tess --ticket HAR-12 --why "low effort high-risk change")"; rc=$?
  _not "  a level elsewhere in the words does not" "$(grep '^new-session' "$T/tmux.log")" "--effort"
  fresh; out="$(WHYARGS=(); run tester --name Tess --ticket HAR-12 --effort high --why "routine, effort low")"; rc=$?
  _has "  --effort wins over the reason's" "$(grep '^new-session' "$T/tmux.log")" "--effort high"
  fresh; out="$(run tester --name Tess --ticket HAR-12 --effort max --dry-run)"
  _has "a dry run says the effort" "$out" "at effort max, with Remote Control on"
  _has "  and its start line carries it" "$out" "--name Tess --ticket HAR-12 --effort max --why"
  fresh; before=$(wc -l < "$T/spawns.tsv"); out="$(run tester --name Tess --ticket HAR-12 --effort huge)"; rc=$?
  _t "an unknown effort is a usage error" "$rc" 2
  _has "  naming the levels" "$out" "huge is not an effort: low, medium, high, xhigh or max"
  _t "  starting and recording nothing" "$(_starts)/$(wc -l < "$T/spawns.tsv")" "0/$before"

  # A LOGIN FOLLOWS THE NAME: a row's "login" is the login it always starts on, through claude-as.sh, without Remote
  # Control, and the record keeps the label. The token is on no command line. The logins are $T/logins, never the box's.
  cat > "$T/login.json" <<'JSON'
{"agents":[
 {"name":"Lea","email":"lea@proj.local","role":"delivery-lead","status":"active"},
 {"name":"Dot","email":"dot@proj.local","role":"developer","status":"active","login":"second"},
 {"name":"Eve","email":"eve@proj.local","role":"developer","status":"active"}]}
JSON
  local lsum; lsum="$(cksum < "$T/login.json")"
  mkdir -p "$T/logins"; echo not-a-real-token > "$T/logins/second.token"; echo not-a-real-token > "$T/logins/third.token"
  lrun() { RF="$T/login.json" run "$@"; }
  fresh; out=""; for _ in 1 2 3 4 5 6; do out+="$(lrun developer --dry-run)"$'\n'; done
  _t "a spawn with no --login never picks a name kept for a login" "$(grep -c 'would start Dot' <<<"$out")" 0
  _has "  and picks one with none, with Remote Control on" "$out" "would start Eve (developer) in tmux session Eve, on the account default model, with Remote Control on"
  fresh; out=""; for _ in 1 2 3 4 5 6; do out+="$(lrun developer --login second --dry-run)"$'\n'; done
  _t "--login picks only among that login's names" "$(grep -c 'would start Eve' <<<"$out")" 0
  _has "  a dry run says the login" "$out" "would start Dot (developer) in tmux session Dot, on the account default model, on the second login, without Remote Control"
  _has "  and its start line carries it" "$out" "--name Dot --login second --why"
  fresh; rm -f "$T/spawns.tsv"; out="$(lrun developer --name Dot)"; rc=$?; line="$(grep '^new-session' "$T/tmux.log")"
  _t "--name starts the name on its row's login" "$rc" 0
  _has "  and the start line says so" "$out" "started Dot (developer) in tmux session Dot, on the account default model (routine test), on the second login, without Remote Control"
  _has "  through claude-as.sh" "$line" "HARNESS_SPAWNED=1 bash $_here/claude-as.sh second --worktree proj-dot --name Dot"
  _not "  with no Remote Control" "$line" "--remote-control"
  _not "  and the token is on no command line" "$(cat "$T/tmux.log")" "not-a-real-token"
  _t "  the record keeps the label" "$(awk -F'\t' 'END{print $12}' "$T/spawns.tsv")" second
  fresh; out="$(lrun developer --name Dot --login third)"; rc=$?
  _t "a --login naming another than the row's is refused" "$rc" 1
  _has "  naming both" "$out" "Dot's roster row has the second login, not third"
  fresh; out="$(lrun developer --name Eve --login third)"; rc=$?
  _t "--login with --name of a row that has none starts it there this once" "$rc" 0
  _has "  on that login" "$out" "on the third login, without Remote Control"
  fresh; out="$(lrun developer)"; line="$(grep '^new-session' "$T/tmux.log")"
  _t "a spawn on the box's own login records -" "$(awk -F'\t' 'END{print $12}' "$T/spawns.tsv")" -
  _has "  and keeps Remote Control" "$line" "claude --worktree proj-eve --name Eve --remote-control proj-eve"
  fresh; out="$(lrun developer --login third --dry-run)"; rc=$?
  _t "--login with no free name kept for it is refused" "$rc" 1
  _has "  naming where the names are" "$out" "no free developer is kept for the third login; on another login: Dot (second) Eve (none)"
  rm "$T/logins/second.token"; fresh; before=$(wc -l < "$T/spawns.tsv")
  out="$(lrun developer --name Dot)"; rc=$?
  _t "a login with no token file is refused" "$rc" 1
  _has "  naming it" "$out" "no login named second in $T/logins"
  _t "  starting and recording nothing" "$(_starts)/$(wc -l < "$T/spawns.tsv")" "0/$before"
  echo not-a-real-token > "$T/logins/second.token"
  fresh; out="$(lrun developer --name Dot --login ../second --dry-run)"; rc=$?
  _t "a label that is not one is a usage error" "$rc" 2
  _t "a spawn on a login writes no roster" "$(cksum < "$T/login.json")" "$lsum"

  # AGENT_LAUNCH_ENV
  fresh; out="$(AGENT_LAUNCH_ENV='MSBUILDDISABLENODEREUSE=1 X_Y=a/b' run tester --ticket HAR-12)"; rc=$?
  _t "AGENT_LAUNCH_ENV: the spawn starts" "$rc" 0
  _has "  with the extra environment after the identity" "$(grep '^new-session' "$T/tmux.log")" "GIT_COMMITTER_EMAIL=tess@proj.local MSBUILDDISABLENODEREUSE=1 X_Y=a/b HARNESS_SPAWNED=1"
  for bad in 'NOEQUALS' '1X=y' "A='b c'" 'A=ok -x'; do
    fresh; out="$(AGENT_LAUNCH_ENV="$bad" run tester --ticket HAR-12)"; rc=$?
    _t "  AGENT_LAUNCH_ENV=$bad is a usage error" "$rc" 2
  done
  _t "  and none of them started anything" "$(_starts)" 0

  # HARNESS_ENV_FILE: read after harness.env; a file that is not plain settings is not read
  printf '# the owner'"'"'s values\nAGENT_LAUNCH_ENV="FROM_ENV_FILE=1"\n\n' > "$T/settings.env"
  fresh; out="$(HARNESS_ENV_FILE="$T/settings.env" run tester --ticket HAR-12)"; rc=$?
  _has "HARNESS_ENV_FILE: its settings are read" "$(grep '^new-session' "$T/tmux.log")" "FROM_ENV_FILE=1 HARNESS_SPAWNED=1"
  printf 'AGENT_LAUNCH_ENV="FROM_ENV_FILE=1"\ntouch %s/ran\n' "$T" > "$T/settings.env"
  fresh; out="$(HARNESS_ENV_FILE="$T/settings.env" run tester --ticket HAR-12)"; rc=$?
  _has "  a file with a line that is not a setting is not read, and says so" "$out" "is not NAME=value, a comment or blank"
  _not "  none of its settings apply" "$(grep '^new-session' "$T/tmux.log")" "FROM_ENV_FILE"
  _t "  and its command never ran" "$([[ -e "$T/ran" ]] && echo ran || echo never)" never
  printf 'AGENT_LAUNCH_ENV="X=$(touch %s/ran)"\n' "$T" > "$T/settings.env"
  fresh; out="$(HARNESS_ENV_FILE="$T/settings.env" run tester --ticket HAR-12 --dry-run)"
  _t "  nor does a setting that runs a command" "$([[ -e "$T/ran" ]] && echo ran || echo never)" never

  # AGENT_SPAWN_STACKS_CMD
  fresh; out="$(AGENT_SPAWN_STACKS_CMD='echo "live agent stacks (3/3 agents)"' run tester --ticket HAR-12)"; rc=$?
  _t "AGENT_SPAWN_STACKS_CMD: a box at its stack cap refuses" "$rc" 1
  _has "  naming the cap" "$out" "the box is at its stack cap (3/3 agents)"
  _t "  starting nothing" "$(_starts)" 0
  fresh; out="$(AGENT_SPAWN_STACKS_CMD='echo nope; exit 4' run tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "  a stack check that fails refuses, a dry run too" "$rc" 1
  _has "  as cannot tell" "$out" "cannot tell whether there is room"
  fresh; out="$(AGENT_SPAWN_STACKS_CMD='echo "live agent stacks (2/3 agents)"' run tester --ticket HAR-12)"; rc=$?
  _t "  with room it starts" "$rc" 0
  _has "  and says the stacks" "$out" "stacks  2/3 agents"
  fresh; out="$(AGENT_SPAWN_STACKS_CMD='[ "$PWD" = "'"$T/repo"'" ] && echo "(0/3 agents)"' run tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "  it runs in the project root" "$rc" 0
  fresh; out="$(AGENT_SPAWN_STACKS_CMD='echo all good' run tester --ticket HAR-12)"; rc=$?
  _t "  a check that passes but prints no N/M count refuses: cannot tell" "$rc" 1
  _has "  saying so" "$out" "cannot tell — the stacks check printed no count"
  _t "  starting nothing" "$(_starts)" 0

  # AGENT_SPAWN_PROMPT_CMD
  printf '#!/usr/bin/env bash\nprintf "Pronouns: Tess she/her. [%%s|%%s|%%s|%%s]" "$@"\n' > "$T/bin/prompt"; chmod +x "$T/bin/prompt"
  fresh; out="$(AGENT_SPAWN_PROMPT_CMD="bash $T/bin/prompt" run tester --ticket HAR-12)"; rc=$?
  _has "AGENT_SPAWN_PROMPT_CMD: its output ends the first prompt, given name, role, ticket, other lead" \
    "$(grep '^new-session' "$T/tmux.log")" "ready to test HAR-12. Pronouns: Tess she/her. [Tess|tester|HAR-12|-]"
  fresh; out="$(AGENT_SPAWN_PROMPT_CMD='exit 3' run tester --ticket HAR-12)"; rc=$?
  _t "  a prompt command that fails refuses" "$rc" 1
  _t "  starting nothing" "$(_starts)" 0

  # AGENT_SPAWN_TICKET_RESOLVE_CMD
  printf '#!/usr/bin/env bash\ncase "$1" in 6854) echo feat_resolved ;; 404) exit 1 ;; 77) echo "x;y" ;; *) exit 3 ;; esac\n' > "$T/bin/resolve"
  chmod +x "$T/bin/resolve"
  fresh; out="$(AGENT_SPAWN_TICKET_RESOLVE_CMD="$T/bin/resolve" run tester --ticket '#6854' --dry-run)"; rc=$?
  _has "AGENT_SPAWN_TICKET_RESOLVE_CMD: a number becomes the ticket's id" "$out" "would start Tess (tester) for feat_resolved"
  out="$(AGENT_SPAWN_TICKET_RESOLVE_CMD="$T/bin/resolve" run tester --ticket 404 --dry-run)"; rc=$?
  _t "  no such ticket refuses" "$rc" 1
  _has "  saying so" "$out" "no ticket 404"
  out="$(AGENT_SPAWN_TICKET_RESOLVE_CMD="$T/bin/resolve" run tester --ticket 999 --dry-run)"; rc=$?
  _t "  a resolver that cannot tell refuses" "$rc" 1
  out="$(AGENT_SPAWN_TICKET_RESOLVE_CMD="$T/bin/resolve" run tester --ticket 77 --dry-run)"; rc=$?
  _t "  an answer that is not an id refuses" "$rc" 1
  out="$(run tester --ticket 6854 --dry-run)"
  _has "  unset, the ticket is used as given" "$out" "would start Tess (tester) for 6854"

  # AGENT_SPAWN_LEAD_NEEDS_PEER: a roster with two heads of testing and no delivery lead
  printf '{"agents":[{"name":"Vi","email":"vi@proj.local","role":"head-of-testing","status":"active"},{"name":"Hal","email":"hal@proj.local","role":"head-of-testing","status":"active"},{"name":"Lea","email":"lea@proj.local","role":"delivery-lead","status":"retired"}]}\n' > "$T/leads.json"
  fresh; out="$(RF="$T/leads.json" run head-of-testing --name Vi --dry-run)"; rc=$?
  _t "unset, a lead starts with no delivery lead active" "$rc" 0
  _has "  taking over from the other active lead" "$out" "to take over from Hal"
  out="$(AGENT_SPAWN_LEAD_NEEDS_PEER=1 RF="$T/leads.json" run head-of-testing --name Vi --dry-run)"; rc=$?
  _t "AGENT_SPAWN_LEAD_NEEDS_PEER=1: with no delivery lead active it refuses" "$rc" 1
  _has "  naming the role it needs" "$out" "no delivery-lead is active on the roster"
  out="$(AGENT_SPAWN_LEAD_NEEDS_PEER=1 run head-of-testing --dry-run)"; rc=$?
  _t "  with one active it starts" "$rc" 0
  _has "  and its prompt names that lead" "$out" "to take over from Lea"

  # the fixture's stand-ins only: a self-test whose PATH reached a real tmux or claude starts nothing
  fresh; out="$(FB="$T/elsewhere" run tester --ticket HAR-12)"; rc=$?
  _t "AGENT_SPAWN_FIXTURE_BIN: a tmux that is not the fixture's refuses" "$rc" 1
  _t "  starting nothing" "$(_starts)" 0

  # AGENT_TREE_MODE=sibling: a project with an origin, the agents' trees beside its main checkout
  fresh; out="$(AGENT_TREE_MODE=elsewhere run tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "AGENT_TREE_MODE that is not a mode is a usage error" "$rc" 2
  local S="$T/sib"; mkdir -p "$S"
  git init -q --bare "$S/origin.git"
  git clone -q "$S/origin.git" "$S/main" 2>/dev/null
  mkdir -p "$S/main/agents"; cp "$T/repo/agents/roster.json" "$S/main/agents/"
  git -C "$S/main" add -A; git -C "$S/main" -c user.name=t -c user.email=t@t commit -q -m init; git -C "$S/main" push -q origin HEAD:main 2>/dev/null
  git -C "$S/main" fetch -q origin
  sib() { AGENT_TREE_MODE=sibling ROOT="$S/main" run "$@"; }
  fresh; out="$(sib tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "sibling: a tree folder Claude Code has not been trusted in refuses" "$rc" 1
  _has "  saying where to trust it" "$out" "has not been trusted in $S/proj-tess or any folder above it"
  jq --arg s "$S" '.projects[$s] = {hasTrustDialogAccepted: true}' "$T/claude/.claude.json" > "$T/cj" && mv "$T/cj" "$T/claude/.claude.json"
  fresh; out="$(sib tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "sibling: trusted through the folder above, a dry run passes" "$rc" 0
  _has "  and says it would add the tree" "$out" "add $S/proj-tess, detached at origin/main"
  _t "  adding nothing" "$([[ -e "$S/proj-tess" ]] && echo added || echo none)" none
  fresh; out="$(sib tester --ticket HAR-12)"; rc=$?; line="$(grep '^new-session' "$T/tmux.log")"
  _t "sibling: a spawn exits 0" "$rc" 0
  _has "  starting in the agent's own tree" "$line" "-c $S/proj-tess env"
  _not "  with no claude --worktree" "$line" "--worktree"
  _t "  the tree is a worktree, detached at origin/main" \
    "$(git -C "$S/proj-tess" rev-parse HEAD)|$(git -C "$S/proj-tess" branch --show-current)" "$(git -C "$S/main" rev-parse origin/main)|"
  touch "$S/proj-tess/wip.txt"
  fresh; out="$(sib tester --ticket HAR-12)"; rc=$?
  _t "sibling: re-entering a tree with uncommitted work refuses" "$rc" 1
  _has "  naming it" "$out" "$S/proj-tess has uncommitted changes"
  _t "  starting nothing" "$(_starts)" 0
  rm -f "$S/proj-tess/wip.txt"
  git -C "$S/proj-tess" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "only here"
  fresh; out="$(sib tester --ticket HAR-12 --dry-run)"; rc=$?
  _t "sibling: a tree holding a commit no origin branch has refuses" "$rc" 1
  _has "  saying so" "$out" "commit(s) no origin branch has"
  git -C "$S/proj-tess" checkout -q --detach origin/main
  fresh; out="$(sib tester --ticket HAR-12)"; rc=$?
  _t "sibling: a clean tree is re-entered" "$rc" 0
  _has "  and says so" "$out" "re-enter $S/proj-tess, detached at origin/main"
  mkdir -p "$S/proj-ada"
  fresh; out="$(sib developer --name Ada --dry-run)"; rc=$?
  _t "sibling: a folder in the tree's place that is not a worktree refuses" "$rc" 1

  if (( fails == 0 )); then echo "agent-spawn --self-test: PASS"; return 0; fi
  echo "agent-spawn --self-test: FAIL ($fails)"; return 1
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  [[ $# -eq 1 ]] || { printf 'unknown argument: %s\n' "$2" >&2; exit 2; }
  spawn_self_test; exit $?
fi
# A leading verb (header): `spawn` changes nothing; `bench` is team/agent-bench.sh with the rest of the line.
case "${1:-}" in
  spawn) shift ;;
  bench) shift; exec bash "$_here/agent-bench.sh" "$@" ;;
esac

ROLE="" WANT="" TICKET="" JOB="" MODEL="" EFFORT="" LOGIN="" WHY="" OWNER_OK="" VSUPPORT=0 DRY=0
while (( $# )); do
  case "$1" in
    developer|tester|delivery-lead|head-of-testing) [[ -z "$ROLE" ]] || { echo "$USAGE" >&2; exit 2; }; ROLE=$1 ;;
    --name)   [[ $# -ge 2 ]] || { echo "$USAGE" >&2; exit 2; }; WANT=$2; shift ;;
    --owner-ok) [[ $# -ge 2 ]] || { echo "agent-spawn: --owner-ok needs the owner's words" >&2; echo "$USAGE" >&2; exit 2; }
                OWNER_OK=$2; shift
                spawn_owner_ok_text_ok "$OWNER_OK" \
                  || { printf "agent-spawn: --owner-ok needs the owner's words on one line, and got %q\n" "$OWNER_OK" >&2; echo "$USAGE" >&2; exit 2; } ;;
    --ticket) [[ $# -ge 2 ]] || { echo "$USAGE" >&2; exit 2; }; TICKET=${2#\#}; shift ;;   # "#6854" is 6854
    --job)    [[ $# -ge 2 ]] || { echo "agent-spawn: --job needs the job in words" >&2; echo "$USAGE" >&2; exit 2; }
              JOB=$2; shift
              spawn_owner_ok_text_ok "$JOB" \
                || { printf 'agent-spawn: --job needs the ticketless job on one line, and got %q\n' "$JOB" >&2; echo "$USAGE" >&2; exit 2; } ;;
    --model)  [[ $# -ge 2 ]] || { echo "$USAGE" >&2; exit 2; }; MODEL=$2; shift ;;
    --effort) [[ $# -ge 2 ]] || { echo "agent-spawn: --effort needs a level" >&2; echo "$USAGE" >&2; exit 2; }; EFFORT=$2; shift ;;
    --login)  [[ $# -ge 2 ]] || { echo "agent-spawn: --login needs a login's label" >&2; echo "$USAGE" >&2; exit 2; }; LOGIN=$2; shift ;;
    --why)    [[ $# -ge 2 ]] || { echo "agent-spawn: --why needs the reason for the model" >&2; echo "$USAGE" >&2; exit 2; }
              WHY=$2; shift
              spawn_owner_ok_text_ok "$WHY" \
                || { printf 'agent-spawn: --why needs the reason for the model on one line, and got %q\n' "$WHY" >&2; echo "$USAGE" >&2; exit 2; } ;;
    --verification-support) VSUPPORT=1 ;;
    --dry-run) DRY=1 ;;
    *) printf 'agent-spawn: unknown argument: %s\n%s\n' "$1" "$USAGE" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$ROLE" ]] || { echo "$USAGE" >&2; exit 2; }
LEAD=0; [[ "$ROLE" == delivery-lead || "$ROLE" == head-of-testing ]] && LEAD=1
(( LEAD )) && [[ -n "$TICKET$JOB" ]] && { printf 'agent-spawn: a lead takes over from the other lead and holds no ticket or job; drop --ticket and --job\n%s\n' "$USAGE" >&2; exit 2; }
[[ -z "$TICKET" || -z "$JOB" ]] || { printf 'agent-spawn: --ticket or --job, not both\n%s\n' "$USAGE" >&2; exit 2; }
# The project settings that are usage: a mode that is not one, an environment that is not NAME=value words, a
# name or ticket the project requires (header, PROJECT SETTINGS).
case "$TREE_MODE" in claude-worktree|sibling) ;;
  *) printf "agent-spawn: AGENT_TREE_MODE='%s' is not claude-worktree or sibling; nothing started.\n" "$TREE_MODE" >&2; exit 2 ;; esac
spawn_launch_env_ok "$LAUNCH_ENV" \
  || { printf "agent-spawn: AGENT_LAUNCH_ENV='%s' is not NAME=value words; nothing started.\n" "$LAUNCH_ENV" >&2; exit 2; }
[[ "$REQUIRE_NAME" != 1 || -n "$WANT" ]] \
  || { printf 'agent-spawn: this project names who starts: --name <Name> (AGENT_SPAWN_REQUIRE_NAME=1), so a dry run and the real run start the same agent\n%s\n' "$USAGE" >&2; exit 2; }
[[ "$REQUIRE_TICKET" != 1 ]] || (( LEAD )) || [[ -n "$TICKET$JOB" ]] \
  || { printf 'agent-spawn: this project starts a %s for a ticket: --ticket <id>, or the delivery lead'"'"'s --job "<the job>" for work with no ticket (AGENT_SPAWN_REQUIRE_TICKET=1)\n%s\n' "$ROLE" "$USAGE" >&2; exit 2; }
(( DRY )) || [[ -n "$WHY" ]] \
  || { printf 'agent-spawn: a real spawn says why it runs on its model: --why "<the reason for that model>"\n%s\n' "$USAGE" >&2; exit 2; }
(( DRY )) || [[ -n "$PROJECT_GIVEN" || -n "${AGENT_SPAWN_LOG:-}" ]] \
  || { printf 'agent-spawn: a real spawn needs HARNESS_PROJECT=<project> (or AGENT_SPAWN_LOG), to record it where the project reads it\n%s\n' "$USAGE" >&2; exit 2; }
# The start lines this prints carry the project (and the project's tree, when one was given) and this script's
# absolute path, so pasting one from the harness checkout or from a project's tree is not refused, nor runs nothing.
RUN_AS="HARNESS_PROJECT=${PROJECT_GIVEN:-<project>}${ROOT_GIVEN:+ HARNESS_ROOT=$(printf '%q' "$ROOT_GIVEN")} bash $SELF"
WHY_ARG=""; [[ -n "$WHY" ]] && WHY_ARG=" --why $(printf '%q' "$WHY")"
[[ -z "$TICKET" ]] || spawn_ticket_ok "$TICKET" \
  || { printf 'agent-spawn: %q is not a ticket id (a ledger id like feat_x_y, or a Jira key like HAR-12)\n' "$TICKET" >&2; exit 2; }
if [[ -z "$MODEL" ]]; then
  case "$ROLE" in developer) MODEL="${AGENT_MODEL_DEV:-}" ;; tester) MODEL="${AGENT_MODEL_TESTER:-}" ;; esac
fi
[[ -z "$MODEL" ]] || spawn_model_ok "$MODEL" || { printf 'agent-spawn: %q is not a model name\n' "$MODEL" >&2; exit 2; }
[[ -n "$EFFORT" ]] || EFFORT="$(spawn_effort_in_why "$WHY")"
EFFORT="${EFFORT,,}"
[[ -z "$EFFORT" ]] || spawn_effort_ok "$EFFORT" \
  || { printf 'agent-spawn: %q is not an effort: low, medium, high, xhigh or max\n%s\n' "$EFFORT" "$USAGE" >&2; exit 2; }
[[ -z "$LOGIN" ]] || spawn_login_ok "$LOGIN" \
  || { printf "agent-spawn: %q is not a login's label: lower-case letters, digits and dashes\n%s\n" "$LOGIN" "$USAGE" >&2; exit 2; }
[[ -r "$ROSTER_FILE" ]] || { echo "agent-spawn: no roster at $ROSTER_FILE" >&2; exit 1; }
# Who ran it: AGENT_SPAWNER, else the roster's name for the session's GIT_AUTHOR_EMAIL. A --job is the delivery lead's.
SPAWNER="${AGENT_SPAWNER:-$(roster_lookup_name "${GIT_AUTHOR_EMAIL:-}" 2>/dev/null)}"
if [[ -n "$JOB" && "$(roster_lookup_role "$SPAWNER" 2>/dev/null)" != delivery-lead ]]; then
  printf 'agent-spawn: --job is the delivery lead'"'"'s: %s is not the delivery-lead on the roster, so no agent is started for work with no ticket (the caller is AGENT_SPAWNER, else the roster name of GIT_AUTHOR_EMAIL)\n' "${SPAWNER:-the caller (no rostered identity)}" >&2; exit 1
fi
# `claude --worktree` exits at once in a folder whose trust dialog was never accepted, so the session would die
# unseen behind tmux. Claude Code records the acceptance in .claude.json, per exact folder. (Sibling mode asks of the
# agent's own tree, once its name is known, below.)
if [[ "$TREE_MODE" == claude-worktree ]]; then
  spawn_trusted "$HARNESS_ROOT" || {
    printf 'agent-spawn: Claude Code has not been trusted in %s, so `claude --worktree` would exit at once.\n' "$HARNESS_ROOT" >&2
    printf '  Run `claude` there once, accept the trust prompt, and spawn again.\n' >&2
    exit 1; }
fi

# The ticket, by the project's own ledger when it says how (AGENT_SPAWN_TICKET_RESOLVE_CMD): a number becomes its id,
# and a ticket that does not exist starts nothing.
if [[ -n "$TICKET" && -n "$RESOLVE_CMD" ]]; then
  _tk="$(spawn_project_cmd "$RESOLVE_CMD" "$TICKET" 2>/dev/null)"; _tkrc=$?
  case "$_tkrc" in
    0) spawn_ticket_ok "$_tk" && [[ "$_tk" != *$'\n'* ]] \
         || { printf 'agent-spawn: the ticket resolver said %q for %s, which is not a ticket id: CANNOT TELL; nothing started.\n' "$_tk" "$TICKET" >&2; exit 1; }
       TICKET="$_tk" ;;
    1) printf 'agent-spawn: no ticket %s (AGENT_SPAWN_TICKET_RESOLVE_CMD found none); nothing started.\n' "$TICKET" >&2; exit 1 ;;
    *) printf 'agent-spawn: could not resolve ticket %s (AGENT_SPAWN_TICKET_RESOLVE_CMD exit %s): CANNOT TELL; nothing started.\n' "$TICKET" "$_tkrc" >&2; exit 1 ;;
  esac
fi

mapfile -t FREE < <(spawn_free_names "$ROLE")
if [[ -n "$WANT" ]]; then
  NAME=""; for n in "${FREE[@]}"; do [[ "${n,,}" == "${WANT,,}" ]] && NAME=$n; done
  [[ -n "$NAME" ]] || { printf 'agent-spawn: %s is not a free %s (free: %s)\n' "$WANT" "$ROLE" "${FREE[*]:-none}" >&2; exit 1; }
else
  # Without --name, only the names kept for the spawn's login are picked from: those with no "login", or --login's.
  KEPT=() ELSEWHERE=()
  for n in ${FREE[@]+"${FREE[@]}"}; do
    l="$(spawn_login_of "$n")"
    if [[ "$l" == "$LOGIN" ]]; then KEPT+=("$n"); else ELSEWHERE+=("$n (${l:-none})"); fi
  done
  if (( ${#FREE[@]} > 0 && ${#KEPT[@]} == 0 )); then
    WHOSE="the box's own login"; [[ -z "$LOGIN" ]] || WHOSE="the $LOGIN login"
    printf 'agent-spawn: no free %s is kept for %s; on another login: %s\n' "$ROLE" "$WHOSE" "${ELSEWHERE[*]}" >&2
    printf '  Spawn one of them with --name <Name>, or give a roster row that "login".\n' >&2
    exit 1
  fi
  FREE=(${KEPT[@]+"${KEPT[@]}"})
  if (( ${#FREE[@]} == 0 )); then
    if roster_list_active | awk -F'\t' -v r="$ROLE" '$2 == r { f = 1 } END { exit !f }'; then
      printf 'agent-spawn: every %s on the roster is running, so none is free.\n' "$ROLE" >&2
    else
      printf 'agent-spawn: no active %s is onboarded, so there is nobody to start.\n' "$ROLE" >&2
    fi
    printf '  Bench one whose ticket has merged (bash %s <Name>), or onboard another\n' "$_here/agent-bench.sh" >&2
    printf '  (bash scripts/agent-onboard.sh <Name> %s) and commit the roster.\n' "$ROLE" >&2
    exit 1
  fi
  NAME=${FREE[RANDOM % ${#FREE[@]}]}
fi

# The name's login: its row's "login", which an explicit --login may repeat and never replace. The label must be one
# the owner has a token file for, or nothing starts.
l="$(spawn_login_of "$NAME")"
[[ -z "$l" || -z "$LOGIN" || "$l" == "$LOGIN" ]] \
  || { printf "agent-spawn: %s's roster row has the %s login, not %s; nothing started.\n" "$NAME" "$l" "$LOGIN" >&2; exit 1; }
LOGIN="${LOGIN:-$l}"
if [[ -n "$LOGIN" ]]; then
  spawn_login_ok "$LOGIN" \
    || { printf "agent-spawn: %s's roster \"login\", %q, is not a login's label: lower-case letters, digits and dashes; nothing started.\n" "$NAME" "$LOGIN" >&2; exit 1; }
  [[ -r "$LOGINS/$LOGIN.token" ]] || { printf 'agent-spawn: no login named %s in %s; nothing started.\n' "$LOGIN" "$LOGINS" >&2; exit 1; }
fi
SESSION="$(agent_session_name "$NAME")"
TSESSION="$(agent_tmux_session "$NAME")"
OTHER_LEAD=""
if (( LEAD )) && [[ "$LEAD_NEEDS_PEER" == 1 ]]; then
  # the handover is the OTHER lead role's latest entry: with none active there is nothing to take over from
  OTHER_ROLE="$(spawn_other_lead_role "$ROLE")"
  OTHER_LEAD="$(roster_list_active | awk -F'\t' -v r="$OTHER_ROLE" '$2 == r { print $1; exit }')"
  [[ -n "$OTHER_LEAD" ]] || { printf 'agent-spawn: no %s is active on the roster, so there is no handover for %s to read (AGENT_SPAWN_LEAD_NEEDS_PEER=1); nothing started.\n' "$OTHER_ROLE" "$NAME" >&2; exit 1; }
elif (( LEAD )); then
  OTHER_LEAD="$(roster_list_active | awk -F'\t' -v me="$NAME" '($2 == "delivery-lead" || $2 == "head-of-testing") && $1 != me { print $1; exit }')"
fi

# Sibling mode (header): the agent's own tree beside the main checkout, trusted, and clean if it is re-entered.
TREE="" REENTER=0 HOW=""
if [[ "$TREE_MODE" == sibling ]]; then
  COMMON="$(spawn_git -C "$HARNESS_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { echo "agent-spawn: $HARNESS_ROOT is not a git tree, so there is no main checkout to put $NAME's tree beside; nothing started." >&2; exit 1; }
  MAIN="${COMMON%/.git}"
  TREE="${MAIN%/*}/$SESSION"
  spawn_trusted "$TREE" up || {
    printf 'agent-spawn: Claude Code has not been trusted in %s or any folder above it below $HOME, so the session would exit at once.\n' "$TREE" >&2
    printf '  Run `claude` in %s once, accept the trust prompt, and spawn again.\n' "${MAIN%/*}" >&2
    exit 1; }
  if [[ -e "$TREE" ]]; then
    REENTER=1
    [[ "$(spawn_git -C "$TREE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" == "$COMMON" \
       && "$(realpath -m -- "$(spawn_git -C "$TREE" rev-parse --show-toplevel 2>/dev/null)")" == "$(realpath -m -- "$TREE")" ]] \
      || { echo "agent-spawn: $TREE exists but is not a worktree of $MAIN: move it aside by hand; nothing started." >&2; exit 1; }
    spawn_git -C "$TREE" fetch -q --no-tags origin </dev/null || { echo "agent-spawn: cannot fetch origin in $TREE; nothing started." >&2; exit 1; }
    [[ -z "$(spawn_git -C "$TREE" status --porcelain)" ]] \
      || { echo "agent-spawn: $TREE has uncommitted changes: $NAME commits and pushes them, or discards them, first; nothing started." >&2; exit 1; }
    UNPUSHED="$(spawn_commits_only_here "$TREE")" || { echo "agent-spawn: cannot list $TREE's unpushed commits; nothing started." >&2; exit 1; }
    [[ -z "$UNPUSHED" ]] \
      || { echo "agent-spawn: $TREE's HEAD holds $(grep -c . <<<"$UNPUSHED") commit(s) no origin branch has and main holds no copy of: $NAME pushes them first; nothing started." >&2; exit 1; }
    HOW="re-enter $TREE, detached at origin/main"
  else
    HOW="add $TREE, detached at origin/main"
  fi
fi

# The box's stacks (AGENT_SPAWN_STACKS_CMD): out of them, the agent's init.sh would be refused.
STACKS_LINE=""
if [[ -n "$STACKS_CMD" ]]; then
  STACKS_OUT="$(spawn_project_cmd "$STACKS_CMD" 2>&1)" \
    || { printf 'agent-spawn: the stack check failed (AGENT_SPAWN_STACKS_CMD), so cannot tell whether there is room; nothing started.\n%s\n' "$STACKS_OUT" >&2; exit 1; }
  read -r _sn _sm <<<"$(spawn_stacks_nm "$STACKS_OUT")"
  if [[ -n "${_sn:-}" ]]; then
    (( _sn < _sm )) || { printf "agent-spawn: the box is at its stack cap (%s/%s agents): %s's init.sh would be refused; nothing started. Who holds it:\n%s\n" "$_sn" "$_sm" "$NAME" "$STACKS_OUT" >&2; exit 1; }
    STACKS_LINE="stacks  $_sn/$_sm agents"
  else
    # a set check that cannot be read fails closed: no count is not room
    printf 'agent-spawn: cannot tell — the stacks check printed no count (no "(N/M agents" from AGENT_SPAWN_STACKS_CMD); nothing started.\n%s\n' "$STACKS_OUT" >&2; exit 1
  fi
fi

PROMPT="$(spawn_prompt "$NAME" "$ROLE" "$TICKET" "$OTHER_LEAD" "$JOB")"
if [[ -n "$PROMPT_CMD" ]]; then
  EXTRA="$(spawn_project_cmd "$PROMPT_CMD" "$NAME" "$ROLE" "${TICKET:--}" "${OTHER_LEAD:--}")" \
    || { echo "agent-spawn: the first prompt's project part failed (AGENT_SPAWN_PROMPT_CMD), so the prompt is not whole; nothing started." >&2; exit 1; }
  [[ -z "$EXTRA" ]] || PROMPT+=" $EXTRA"
fi
# the row's own address, or nothing starts (a session under an address no row holds is no agent)
IDENT_TXT="$(roster_launch_env "$NAME")" || exit 1
mapfile -t IDENT <<<"$IDENT_TXT"
read -ra XENV <<<"$LAUNCH_ENV"
MARKS=(HARNESS_SPAWNED=1)
if (( LEAD )); then MARKS+=("HARNESS_ROLE=$ROLE"); elif [[ -n "$TICKET" ]]; then MARKS+=("HARNESS_TICKET=$TICKET"); fi
# On a login, claude-as.sh starts claude with the login's token, and without Remote Control (header).
if [[ -n "$LOGIN" ]]; then CLAUDE=(bash "$CLAUDE_AS" "$LOGIN"); REACH="on the $LOGIN login, without Remote Control"
else CLAUDE=(claude); REACH="with Remote Control on"; fi
CMD=(env "${IDENT[@]}" ${XENV[@]+"${XENV[@]}"} "${MARKS[@]}" "${CLAUDE[@]}")
[[ "$TREE_MODE" == sibling ]] || CMD+=(--worktree "$SESSION")
CMD+=(--name "$NAME")
[[ -n "$MODEL" ]] && CMD+=(--model "$MODEL")
[[ -n "$EFFORT" ]] && CMD+=(--effort "$EFFORT")
[[ -n "$LOGIN" ]] || CMD+=(--remote-control "$SESSION")
CMD+=("$PROMPT")
START_DIR="$HARNESS_ROOT"; [[ "$TREE_MODE" == sibling ]] && START_DIR="$TREE"
WHAT="$NAME ($ROLE)${TICKET:+ for $TICKET}${JOB:+ for a job with no ticket: $JOB}"

# The ticket, for a developer: the row must be one this developer could claim, or nothing starts.
TICKET_LINE="" CLAIM_STATE=""
if [[ "$ROLE" == developer && -n "$TICKET" ]]; then
  ROW_STATUS="$($LEDGER_SH ticket-row "$TICKET" 2>/dev/null)" \
    || { printf 'agent-spawn: could not read the ledger for %s: CANNOT TELL, not free; nothing started.\n' "$TICKET" >&2; exit 1; }
  ROW_OWNER="$(spawn_owner_of "$($LEDGER_SH ticket-owner "$TICKET" 2>/dev/null)")"
  VERDICT_T="$(spawn_ticket_verdict "$ROW_STATUS" "$ROW_OWNER" "$NAME")"
  case "$VERDICT_T" in
    claimable) TICKET_LINE="ticket  $TICKET is $ROW_STATUS, unclaimed: $NAME claims it after init" ;;
    yours)     TICKET_LINE="ticket  $TICKET is already $NAME's (a claim from an earlier session)"; CLAIM_STATE=yours ;;
    refused:no-row)        echo "agent-spawn: no row for $TICKET on the ledger: raise it first (ledger-db.sh raise <json>); nothing started." >&2; exit 1 ;;
    refused:finished:*)    echo "agent-spawn: $TICKET is '${VERDICT_T##*:}': finished, not claimable; nothing started." >&2; exit 1 ;;
    refused:not-selected:*) echo "agent-spawn: $TICKET is '${VERDICT_T##*:}': ask the PO to groom it to selected first; nothing started." >&2; exit 1 ;;
    refused:held-by:*)     echo "agent-spawn: $TICKET is held by ${VERDICT_T#refused:held-by:}, so $NAME could not claim it; nothing started." >&2; exit 1 ;;
  esac
fi
# The budget line, and what it means for THIS role (header: developers are gated, testers are not). An open day
# (agents-day-budget.sh: a development day's fixed share) answers instead of the week's even pacing; exit 3 is no
# day open, and only then is agents-budget.sh asked.
BUDGET_LINE="$(bash "$DAY_BUDGET_SH" status 2>&1)"; BUDGET_RC=$?
if [[ "$BUDGET_RC" == 3 ]]; then BUDGET_LINE="$(bash "$BUDGET_SH" 2>&1)"; BUDGET_RC=$?; fi
RULE="$(spawn_budget_rule "$ROLE" "$BUDGET_RC")"
case "$BUDGET_RC" in 0) VERDICT=on ;; 1) VERDICT=over ;; *) VERDICT=cannot-tell ;; esac
# verification support lifts the budget gate for a developer, and the cap below (header)
if (( VSUPPORT )); then VERDICT="$VERDICT:verification-support"; [[ "$RULE" == ask ]] && RULE=start; fi
WORKING_N="$(spawn_working_count "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions")"
CAP_RULE="$(spawn_cap_rule "${AGENT_MAX_WORKING:-}" "$WORKING_N")"
case "$CAP_RULE" in
  none) CAP_LINE="working $WORKING_N sessions now (no cap: AGENT_MAX_WORKING in harness.env)" ;;
  bad)  echo "agent-spawn: AGENT_MAX_WORKING='${AGENT_MAX_WORKING}' is not a whole number of sessions; nothing started." >&2; exit 2 ;;
  unknown) CAP_LINE="cannot tell how many sessions are working (no status in ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/<pid>.json; cap $AGENT_MAX_WORKING)" ;;
  *)    CAP_LINE="working $WORKING_N of up to $AGENT_MAX_WORKING sessions" ;;
esac
# at the cap, or unable to read the count under one, either role asks; the owner's words start it. Verification
# support starts it anyway, and says so on the line and in the record.
if [[ "$CAP_RULE" == full || "$CAP_RULE" == unknown ]] && (( VSUPPORT )); then
  CAP_RULE=lifted; CAP_LINE="$CAP_LINE: at the cap, lifted for verification support"; VERDICT="$VERDICT:over-cap"
fi
# a lead is not counted against the cap or the budget (header)
if (( LEAD )); then
  VERDICT=lead; [[ "$CAP_RULE" == full || "$CAP_RULE" == unknown ]] && { CAP_RULE=lifted; CAP_LINE="$CAP_LINE: a lead is not counted against the cap"; }
fi
[[ "$CAP_RULE" == full || "$CAP_RULE" == unknown ]] && RULE=ask

if (( DRY )); then
  printf 'would start %s in tmux session %s, on %s%s, %s%s\n' "$WHAT" "$TSESSION" "${MODEL:-the account default model}" "${EFFORT:+ at effort $EFFORT}" "$REACH" "${HOW:+: $HOW}"
  printf '  start exactly this one with: %s %s --name %s%s%s%s%s\n' \
    "$RUN_AS" "$ROLE" "$NAME" "${TICKET:+ --ticket $TICKET}" "${MODEL:+ --model $MODEL}${EFFORT:+ --effort $EFFORT}${LOGIN:+ --login $LOGIN}" "${WHY_ARG:- --why \"<why that model>\"}" \
    "$([[ "$RULE" == ask ]] && printf ' --owner-ok "<the owner'"'"'s words>"')"
  [[ -n "$WHY" ]] || printf '  the real spawn needs --why: the reason for the model it starts on.\n'
  printf '  first prompt: %s\n' "$PROMPT"
  [[ -z "$TICKET_LINE" ]] || printf '%s\n' "$TICKET_LINE"
  [[ -z "$STACKS_LINE" ]] || printf '%s\n' "$STACKS_LINE"
  printf '%s\n' "$BUDGET_LINE"
  printf '%s\n' "$CAP_LINE"
  if [[ "$CAP_RULE" == full || "$CAP_RULE" == unknown ]]; then
    printf '  at the cap (%s): ask the owner first, in one line, whatever the role; start it with their words on --owner-ok.\n' "$CAP_LINE"
  else case "$RULE" in
    start) if (( VSUPPORT )); then printf '  developer, verification support: start it whatever the budget line says; no owner OK needed.\n'
           else printf '  developer, on budget: start it, then tell the owner in one line with the budget.\n'; fi ;;
    ask)   printf '  developer, off budget (or no reading): ask the owner first, in one line; start it with their words on --owner-ok.\n' ;;
    info)  printf '  tester: start it whatever the budget line says; testers are not budget-gated (owner, 2026-10-25). The line is information.\n' ;;
    lead)  printf '  lead: start it to hand over; a lead is not budget-gated or counted against the cap (owner, 2026-10-31).\n' ;;
  esac; fi
  exit 0
fi

if [[ "$CAP_RULE" == full || "$CAP_RULE" == unknown ]] && [[ -z "$OWNER_OK" ]]; then
  printf 'agent-spawn: %s: at the cap\n' "$CAP_LINE" >&2
  printf '  a spawn at the cap needs the owner'"'"'s OK whatever the role: ask in one line (ticket, name, the line above), then start it with\n' >&2
  printf '  their words on the line: %s %s --name %s%s%s%s --owner-ok "<their words>"\n' "$RUN_AS" "$ROLE" "$NAME" "${TICKET:+ --ticket $TICKET}" "${MODEL:+ --model $MODEL}${EFFORT:+ --effort $EFFORT}${LOGIN:+ --login $LOGIN}" "$WHY_ARG" >&2
  exit 1
fi
if [[ "$RULE" == ask && -z "$OWNER_OK" ]]; then
  printf 'agent-spawn: %s\n' "$BUDGET_LINE" >&2
  printf '  a developer spawn off budget needs the owner'"'"'s OK: ask in one line (ticket, name, budget line), then start it with\n' >&2
  printf '  their words on the line: %s developer --name %s%s%s%s --owner-ok "<their words>"\n' "$RUN_AS" "$NAME" "${TICKET:+ --ticket $TICKET}" "${MODEL:+ --model $MODEL}${EFFORT:+ --effort $EFFORT}${LOGIN:+ --login $LOGIN}" "$WHY_ARG" >&2
  printf '  (a tester is not budget-gated and starts regardless; a developer fixing what verification found starts with --verification-support)\n' >&2
  exit 1
fi

command -v tmux >/dev/null 2>&1 || { echo "agent-spawn: tmux is not on PATH" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "agent-spawn: claude is not on PATH" >&2; exit 1; }
# The self-test names its stand-ins' folder: then only those may run, never a real tmux or claude a reordered PATH
# put first (strength, 2026-10-24: a mutant's PATH started three real sessions under fixture names).
if [[ -n "${AGENT_SPAWN_FIXTURE_BIN:-}" ]]; then
  for _b in tmux claude; do
    [[ "$(command -v "$_b")" == "$AGENT_SPAWN_FIXTURE_BIN/$_b" ]] \
      || { echo "agent-spawn: a self-test reached a $_b that is not the fixture's ($(command -v "$_b")): nothing started." >&2; exit 1; }
  done
fi
# Sibling mode: the tree is put at origin/main now, after every gate (header). Re-entering was checked clean above.
if [[ "$TREE_MODE" == sibling ]]; then
  if (( REENTER )); then
    spawn_git -C "$TREE" checkout -q --detach origin/main </dev/null \
      || { echo "agent-spawn: could not detach $TREE at origin/main; nothing started." >&2; exit 1; }
  else
    spawn_git -C "$HARNESS_ROOT" fetch -q --no-tags origin </dev/null || { echo "agent-spawn: cannot fetch origin; nothing started." >&2; exit 1; }
    spawn_git -C "$HARNESS_ROOT" worktree add -q --detach "$TREE" origin/main </dev/null \
      || { echo "agent-spawn: could not add $TREE; nothing started." >&2; exit 1; }
  fi
fi
tmux new-session -d -s "$TSESSION" -x "${SIZE%x*}" -y "${SIZE#*x}" -c "$START_DIR" "${CMD[@]}" \
  || { echo "agent-spawn: tmux could not start session $TSESSION for $NAME" >&2; exit 1; }
tmux has-session -t "=$TSESSION" 2>/dev/null \
  || { echo "agent-spawn: session $SESSION ended at once; start it by hand to see why: bash scripts/agent-onboard.sh --launch-line $NAME" >&2; exit 1; }
# The session's markers (header): what team/agent-bench.sh reads to know this script started it, and for what.
for _m in "${MARKS[@]}" ${OWNER_OK:+"HARNESS_OWNER_OK=$OWNER_OK"}; do
  tmux set-environment -t "=$TSESSION" "${_m%%=*}" "${_m#*=}" 2>/dev/null \
    || echo "agent-spawn: could not mark session $SESSION with ${_m%%=*} (the agent is running; a bench that asks for it needs --by-hand)" >&2
done
# The record: who was started, against which budget line, on whose word.
mkdir -p "$(dirname -- "$SPAWN_LOG")" 2>/dev/null
LOGGED_TICKET="${TICKET:-${JOB:+job:$JOB}}"
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$ROLE" "${LOGGED_TICKET:--}" "${MODEL:--}" "$VERDICT" "${OWNER_OK:--}" "$BUDGET_LINE" "$WHY" "${SPAWNER:--}" "${EFFORT:--}" "${LOGIN:--}" >> "$SPAWN_LOG" \
  || echo "agent-spawn: could not record the spawn in $SPAWN_LOG (the agent is running)" >&2
printf 'started %s in tmux session %s, on %s%s (%s), %s%s\n' "$WHAT" "$TSESSION" "${MODEL:-the account default model}" "${EFFORT:+ at effort $EFFORT}" "$WHY" "$REACH" "${OWNER_OK:+; owner OK: \"$OWNER_OK\"}$( (( VSUPPORT )) && printf '; verification support')${HOW:+; $HOW}"
[[ -z "$STACKS_LINE" ]] || printf '  %s\n' "$STACKS_LINE"
printf '  %s\n' "$BUDGET_LINE"
printf '  %s\n' "$CAP_LINE"
printf '  watch it: tmux attach -t =%s · recorded in %s\n' "$TSESSION" "$SPAWN_LOG"
[[ -z "$TICKET_LINE" ]] || printf '  %s\n' "$TICKET_LINE"

# The claim: the developer's own, watched here until it is on the row. An unclaimed ticket is work the board
# cannot see, so a claim that never appears is said loudly, and the exit says it too; the agent keeps running.
if [[ "$ROLE" == developer && -n "$TICKET" && "$CLAIM_STATE" != yours ]]; then
  if (( CLAIM_WAIT_S <= 0 )); then
    printf '  claim   %s not watched (AGENT_SPAWN_CLAIM_WAIT_S=0): check the row yourself: bash scripts/ledger-db.sh ticket-owner %s\n' "$TICKET" "$TICKET"
  else
    waited=0 holder=""
    while :; do
      holder="$(spawn_owner_of "$($LEDGER_SH ticket-owner "$TICKET" 2>/dev/null)")"
      [[ "${holder,,}" != "${NAME,,}" ]] || { printf '  claimed %s is %s'"'"'s, after %ss\n' "$TICKET" "$NAME" "$waited"; break; }
      if [[ -n "$holder" ]]; then
        printf 'agent-spawn: %s was claimed by %s, not %s, while %s was starting. Two agents on one ticket: sort it out now.\n' "$TICKET" "$holder" "$NAME" "$NAME" >&2; exit 1
      fi
      (( waited < CLAIM_WAIT_S )) || {
        printf 'agent-spawn: %s has NOT claimed %s after %ss: the row is still unclaimed and the board does not show the work.\n' "$NAME" "$TICKET" "$waited" >&2
        printf '  Read the pane (tmux attach -t =%s). Tell %s, as developer, to claim it: bash scripts/feature-ticket.sh claim %s. Or bench them.\n' "$TSESSION" "$NAME" "$TICKET" >&2
        exit 1; }
      sleep "$CLAIM_POLL_S"; waited=$(( waited + CLAIM_POLL_S ))
    done
  fi
fi
