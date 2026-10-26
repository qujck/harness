#!/usr/bin/env bash
# team/agent-spawn.sh — start an onboarded developer or tester for ONE ticket: off the bench.
#
#   bash team/agent-spawn.sh developer|tester [--name <Name>] [--ticket <id>] [--model <model>] --why "<reason>" [--owner-ok "<words>"] [--dry-run]
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
#   env <roster_launch_env> claude --worktree <project>-<name> --name <Name> [--model M] --remote-control <project>-<name> "<first prompt>"
#
#   identity     roster_launch_env: the same four GIT_* variables as the launch line agent-onboard.sh prints
#   model        --model, else AGENT_MODEL_DEV / AGENT_MODEL_TESTER (harness.env), else the account default
#   first prompt Claude Code's positional prompt: read the role document and AGENTS.md, run
#                `bash scripts/init.sh`, then a developer CLAIMS THE TICKET ITSELF (feature-ticket.sh claim):
#                a claim is stamped with the session's identity, so nobody can claim on its behalf. A tester
#                claims nothing; it tells the delivery lead it is ready to test the ticket.
#
#   remote       --remote-control <session>: every spawned session can be reached from claude.ai/code and the
#                Claude mobile app under its tmux session's name (owner, 2026-10-25)
#
# THE BUDGET GATES DEVELOPERS ONLY (owner, 2026-10-25). Every run prints team/agents-budget.sh's line:
#   developer  `budget  on` → start it and tell the owner in one line. `over`, or no budget / no reading →
#              ASK THE OWNER FIRST; a real spawn then needs their answer on the line, --owner-ok "<their words>",
#              and is refused without it. Never a flat refusal: the owner's OK is the way through. The words
#              must BE words: another flag ("--owner-ok --dry-run"), the "<their words>" placeholder pasted
#              unedited, blanks or a second line are a usage error (exit 2) and start nothing.
#   tester     started whatever the line says; the line is information. Testers are not budget-gated.
# The budget never picks the model.
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
# time · name · role · ticket · model · budget verdict · the owner's words (or -) · the budget line · why that
# model. That is where an off-budget start shows who said yes, and every start why it runs on its model; the
# start line prints the same.
#
# AGENT_SPAWN_BUDGET names a stand-in for agents-budget.sh (the self-test's hook, like agents-dash.sh's).
#
# Exit: 0 started (or a dry run said what it would start) · 1 refused, or started but the claim never appeared ·
# 2 a usage error.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="$_here/$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"
# shellcheck source=lib/harness-env.sh
. "$_here/../scripts/lib/harness-env.sh"
export ROSTER_FILE="${ROSTER_FILE:-$HARNESS_ROOT/agents/roster.json}"
# shellcheck source=lib/roster.sh
. "$_here/../scripts/lib/roster.sh"
# shellcheck source=lib/agent-session.sh
. "$_here/lib/agent-session.sh"

USAGE="usage: agent-spawn.sh developer|tester [--name <Name>] [--ticket <id>] [--model <model>] --why \"<why that model>\" [--owner-ok \"<the owner's words>\"] [--dry-run]"
SPAWN_LOG="${AGENT_SPAWN_LOG:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/agent-spawns.tsv}"
BUDGET_SH="${AGENT_SPAWN_BUDGET:-$_here/agents-budget.sh}"
LEDGER_SH="${AGENT_SPAWN_LEDGER:-bash $_here/../scripts/ledger-db.sh}"
CLAIM_WAIT_S="${AGENT_SPAWN_CLAIM_WAIT_S:-600}"
CLAIM_POLL_S="${AGENT_SPAWN_CLAIM_POLL_S:-5}"

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
  if [[ "$1" == tester ]]; then printf 'info'; elif [[ "$2" == 0 ]]; then printf 'start'; else printf 'ask'; fi
}

# PURE: is this a ticket id? A ledger id (the ledger's own CHECK: ^[a-z][a-z0-9_-]{4,200}$) or a Jira key.
spawn_ticket_ok() { [[ "${1-}" =~ ^([a-z][a-z0-9_-]{4,200}|[A-Z][A-Z0-9]+-[0-9]+)$ ]]; }
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

# The first prompt. $1 name · $2 role · $3 ticket (may be empty)
spawn_prompt() {
  local n="$1" r="$2" t="${3:-}" p
  p="You are $n, a $r on this project's agent team, started by team/agent-spawn.sh"
  [[ -n "$t" ]] && p+=" for ticket $t. That ticket is yours and you hold no other." || p+="."
  p+=" Read docs/roles/$r.md and AGENTS.md first, then run \`bash scripts/init.sh\`."
  if [[ -z "$t" ]]; then
    p+=" Then tell the delivery lead you are ready and ask which ticket is yours."
  elif [[ "$r" == developer ]]; then
    p+=" Then claim it yourself, \`bash scripts/feature-ticket.sh claim $t\`, and tell the delivery lead you have it."
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
  T="$(mktemp -d)" || return 2
  trap '[[ -n "$child" ]] && kill "$child" 2>/dev/null; rm -rf "$T"' RETURN

  # PURE arms
  spawn_ticket_ok feat_some_ticket && _t "a ledger id is a ticket" 0 0 || _t "a ledger id is a ticket" 1 0
  spawn_ticket_ok HAR-12 && _t "a Jira key is a ticket" 0 0 || _t "a Jira key is a ticket" 1 0
  spawn_ticket_ok Har-12 && _t "a mixed-case key is no ticket" 0 1 || _t "a mixed-case key is no ticket" 1 1
  spawn_ticket_ok 'x;rm' && _t "a shell metacharacter is no ticket" 0 1 || _t "a shell metacharacter is no ticket" 1 1
  spawn_model_ok 'opus;rm' && _t "a model with ; is refused" 0 1 || _t "a model with ; is refused" 1 1
  spawn_model_ok 'opus[1m]' && _t "a [1m] model suffix is accepted" 0 0 || _t "a [1m] model suffix is accepted" 1 0
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

  # FIXTURES: a project root with a roster, a stand-in tmux and claude on PATH, Claude Code records in a
  # throwaway config dir. Nothing here can start a real session: the only tmux on PATH is the stand-in.
  mkdir -p "$T/repo/agents" "$T/bin" "$T/claude/sessions"
  jq -n --arg r "$T/repo" '{projects: {($r): {hasTrustDialogAccepted: true}}}' > "$T/claude/.claude.json"
  cat > "$T/repo/agents/roster.json" <<'JSON'
{"agents":[
 {"name":"Lea","email":"lea@proj.local","role":"delivery-lead","status":"active"},
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
  chmod +x "$T/bin/tmux" "$T/bin/claude" "$T/bin/budget" "$T/bin/ledger"
  : > "$T/tmux.log"; printf 'proj-ben\n' > "$T/tmux.sessions"   # Ben is already running, in agent-spawn's own tmux session
  local sum0; sum0="$(cksum < "$T/repo/agents/roster.json")"
  run() { env -u AGENT_MODEL_DEV -u AGENT_MODEL_TESTER HARNESS_ROOT="$T/repo" HARNESS_PROJECT=proj ROSTER_DOMAIN=proj.local \
            ROSTER_FILE="${RF:-$T/repo/agents/roster.json}" CLAUDE_CONFIG_DIR="$T/claude" CONTEXT_DIR="$T/ctx" PATH="$T/bin:$PATH" \
            AGENT_SPAWN_BUDGET="$T/bin/budget" AGENT_SPAWN_LOG="$T/spawns.tsv" \
            AGENT_SPAWN_LEDGER="bash $T/bin/ledger" AGENT_SPAWN_CLAIM_WAIT_S="${CW:-2}" AGENT_SPAWN_CLAIM_POLL_S=1 \
            bash "$SELF" "$@" ${WHYARGS[@]+"${WHYARGS[@]}"} 2>&1; }
  local WHYARGS=(--why "routine test")   # every run in this test says why its model, unless a test empties it

  # the pick: only Ada is free (Ben is running, Cy is retired, Tess is a tester, Lea the lead)
  out=""; for _ in 1 2 3 4 5 6; do out+="$(run developer --ticket HAR-12 --dry-run)"$'\n'; done
  _t "a dry run picks only the free developer" "$(grep -c '^would start ' <<<"$out")" 6
  _t "a running name is never picked" "$(grep -c 'would start Ben' <<<"$out")" 0
  _t "a retired name is never picked" "$(grep -c 'would start Cy' <<<"$out")" 0
  _has "the dry run names the name to start with --name" "$out" "would start Ada (developer) for HAR-12"
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
  out="$(run head-of-testing --dry-run)"; rc=$?
  _t "a role other than developer or tester is refused" "$rc" 2
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
  out="$(run developer --ticket HAR-12 --dry-run)"
  _has "a developer dry run off budget says to ask the owner first" "$out" "developer, off budget (or no reading): ask the owner first"
  out="$(run tester --ticket HAR-12 --dry-run)"
  _has "a tester dry run off budget says to start it regardless" "$out" "testers are not budget-gated"
  _has "  and still prints the budget line" "$out" "budget  over"
  out="$(run tester --ticket HAR-12)"; rc=$?
  _t "a tester spawn off budget starts without any OK" "$rc" 0
  _t "  and is recorded with no owner words" "$(awk -F'\t' '$2=="Tess"{print $3"|"$6"|"$7}' "$T/spawns.tsv")" 'tester|over|-'
  : > "$T/tmux.log"; printf 'proj-ben\n' > "$T/tmux.sessions"
  out="$(run developer --ticket HAR-12 --owner-ok 'yes, start her, Peter')"; rc=$?
  _t "a developer spawn off budget WITH the owner's OK starts" "$rc" 0
  _has "  and the start line quotes the OK" "$out" 'owner OK: "yes, start her, Peter"'
  _t "  and the record holds who was started, on which verdict, on whose words" "$(awk -F'\t' '$2=="Ada"{print $3"|"$4"|"$5"|"$6"|"$7}' "$T/spawns.tsv")" 'developer|HAR-12|sonnet|over|yes, start her, Peter'
  _has "  and the budget line itself" "$(tail -1 "$T/spawns.tsv")" "budget  over: week 61%"
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
  : > "$T/tmux.log"; printf 'proj-ben\n' > "$T/tmux.sessions"   # Ada's spawn above is over; she is free again
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
  printf 'on\n' > "$T/budget.mode"; : > "$T/tmux.log"; printf 'proj-ben\n' > "$T/tmux.sessions"; printf 'selected\t\n' > "$T/ledger.state"
  out="$(run developer --ticket HAR-12)"; rc=$?
  _t "a spawn exits 0" "$rc" 0
  _has "  and says how to watch it" "$out" "tmux attach -t =proj-ada"
  _has "  and that Remote Control is on" "$out" "with Remote Control on"
  _t "  on budget, recorded with no owner words" "$(awk -F'\t' '$2=="Ada"{v=$6"|"$7} END{print v}' "$T/spawns.tsv")" 'on|-'
  local line; line="$(grep '^new-session' "$T/tmux.log")"
  _has "  the session starts claude with Remote Control on, named for the tmux session" "$line" "--remote-control proj-ada"
  _has "it starts a detached tmux session named for the agent, in the project root" "$line" "new-session -d -s proj-ada -c $T/repo env"
  _has "  with the roster identity" "$line" "GIT_AUTHOR_NAME=Ada GIT_AUTHOR_EMAIL=ada@proj.local GIT_COMMITTER_NAME=Ada GIT_COMMITTER_EMAIL=ada@proj.local"
  _has "  in the agent's own worktree, named in the session" "$line" "claude --worktree proj-ada --name Ada"
  _has "  on the role's model (AGENT_MODEL_DEV)" "$line" "--model sonnet"
  _has "  told to read its role and init" "$line" "Read docs/roles/developer.md and AGENTS.md first, then run \`bash scripts/init.sh\`"
  _has "  and to claim the ticket itself" "$line" "bash scripts/feature-ticket.sh claim HAR-12"
  _has "  the row was read before the start" "$out" "ticket  HAR-12 is selected, unclaimed: Ada claims it after init"
  _has "  and the claim was seen after it" "$out" "claimed HAR-12 is Ada's"
  _t "a spawn writes no roster" "$(cksum < "$T/repo/agents/roster.json")" "$sum0"

  # ── THE TICKET IS CHECKED BEFORE THE START, AND THE CLAIM AFTER (owner, 2026-10-26) ──
  : > "$T/tmux.log"; : > "$T/ledger.log"; printf 'proj-ben\n' > "$T/tmux.sessions"
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
  printf 'selected\t\n' > "$T/ledger.state"; rm -f "$T/ledger.claims-on-start"; : > "$T/tmux.log"; printf 'proj-ben\n' > "$T/tmux.sessions"
  before=$(wc -l < "$T/spawns.tsv")
  out="$(run developer --ticket HAR-12)"; rc=$?
  _t "a claim that never appears exits 1 with the agent running" "$rc" 1
  _has "  and says so loudly, naming agent, ticket and the way out" "$out" "Ada has NOT claimed HAR-12 after 2s"
  _has "  with how to tell them" "$out" "bash scripts/feature-ticket.sh claim HAR-12"
  _t "  the agent did start" "$(grep -c '^new-session' "$T/tmux.log")" 1
  _t "  and the spawn is recorded" "$(( $(wc -l < "$T/spawns.tsv") - before ))" 1
  printf 'selected\t\n' > "$T/ledger.state"; : > "$T/tmux.log"; printf 'proj-ben\n' > "$T/tmux.sessions"
  out="$(CW=0 run developer --ticket HAR-12)"; rc=$?
  _t "AGENT_SPAWN_CLAIM_WAIT_S=0 starts without watching" "$rc" 0
  _has "  and says the claim is unwatched" "$out" "not watched (AGENT_SPAWN_CLAIM_WAIT_S=0)"
  touch "$T/ledger.claims-on-start"; printf 'selected\t\n' > "$T/ledger.state"; : > "$T/ledger.log"
  run tester --ticket HAR-12 >/dev/null
  _t "a tester's ticket is neither read nor watched" "$(grep -c . "$T/ledger.log")" 0
  printf 'proj-ben\nproj-ada\n' > "$T/tmux.sessions"   # as after the real start above: Ben and Ada running

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
  : > "$T/repo/harness.env"; printf 'proj-ben\n' > "$T/tmux.sessions"; : > "$T/tmux.log"
  run developer >/dev/null
  line="$(grep '^new-session' "$T/tmux.log")"
  _t "with no model set, no --model is passed" "$(grep -c -- '--model' <<<"$line")" 0
  _has "with no ticket, it asks the lead for one" "$line" "ask which ticket is yours"

  # ── EVERY REAL SPAWN SAYS WHY THIS MODEL (owner, 2026-10-26) ──
  _t "the record's last column is why that model" "$(awk -F'\t' 'END{print $9}' "$T/spawns.tsv")" "routine test"
  printf 'on\n' > "$T/budget.mode"; printf 'proj-ben\n' > "$T/tmux.sessions"; : > "$T/tmux.log"
  out="$(WHYARGS=(); run tester --ticket HAR-12 --model opus --why 'first round of a new feature')"
  _has "the start line says the model and why" "$out" "on opus (first round of a new feature)"
  printf 'proj-ben\n' > "$T/tmux.sessions"; : > "$T/tmux.log"; before=$(wc -l < "$T/spawns.tsv")
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

  if (( fails == 0 )); then echo "agent-spawn --self-test: PASS"; return 0; fi
  echo "agent-spawn --self-test: FAIL ($fails)"; return 1
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  [[ $# -eq 1 ]] || { printf 'unknown argument: %s\n' "$2" >&2; exit 2; }
  spawn_self_test; exit $?
fi

ROLE="" WANT="" TICKET="" MODEL="" WHY="" OWNER_OK="" DRY=0
while (( $# )); do
  case "$1" in
    developer|tester) [[ -z "$ROLE" ]] || { echo "$USAGE" >&2; exit 2; }; ROLE=$1 ;;
    --name)   [[ $# -ge 2 ]] || { echo "$USAGE" >&2; exit 2; }; WANT=$2; shift ;;
    --owner-ok) [[ $# -ge 2 ]] || { echo "agent-spawn: --owner-ok needs the owner's words" >&2; echo "$USAGE" >&2; exit 2; }
                OWNER_OK=$2; shift
                spawn_owner_ok_text_ok "$OWNER_OK" \
                  || { printf "agent-spawn: --owner-ok needs the owner's words on one line, and got %q\n" "$OWNER_OK" >&2; echo "$USAGE" >&2; exit 2; } ;;
    --ticket) [[ $# -ge 2 ]] || { echo "$USAGE" >&2; exit 2; }; TICKET=$2; shift ;;
    --model)  [[ $# -ge 2 ]] || { echo "$USAGE" >&2; exit 2; }; MODEL=$2; shift ;;
    --why)    [[ $# -ge 2 ]] || { echo "agent-spawn: --why needs the reason for the model" >&2; echo "$USAGE" >&2; exit 2; }
              WHY=$2; shift
              spawn_owner_ok_text_ok "$WHY" \
                || { printf 'agent-spawn: --why needs the reason for the model on one line, and got %q\n' "$WHY" >&2; echo "$USAGE" >&2; exit 2; } ;;
    --dry-run) DRY=1 ;;
    *) printf 'agent-spawn: unknown argument: %s\n%s\n' "$1" "$USAGE" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$ROLE" ]] || { echo "$USAGE" >&2; exit 2; }
(( DRY )) || [[ -n "$WHY" ]] \
  || { printf 'agent-spawn: a real spawn says why it runs on its model: --why "<the reason for that model>"\n%s\n' "$USAGE" >&2; exit 2; }
WHY_ARG=""; [[ -n "$WHY" ]] && WHY_ARG=" --why $(printf '%q' "$WHY")"
[[ -z "$TICKET" ]] || spawn_ticket_ok "$TICKET" \
  || { printf 'agent-spawn: %q is not a ticket id (a ledger id like feat_x_y, or a Jira key like HAR-12)\n' "$TICKET" >&2; exit 2; }
if [[ -z "$MODEL" ]]; then
  [[ "$ROLE" == developer ]] && MODEL="${AGENT_MODEL_DEV:-}" || MODEL="${AGENT_MODEL_TESTER:-}"
fi
[[ -z "$MODEL" ]] || spawn_model_ok "$MODEL" || { printf 'agent-spawn: %q is not a model name\n' "$MODEL" >&2; exit 2; }
[[ -r "$ROSTER_FILE" ]] || { echo "agent-spawn: no roster at $ROSTER_FILE" >&2; exit 1; }
# `claude --worktree` exits at once in a folder whose trust dialog was never accepted, so the session would die
# unseen behind tmux. Claude Code records the acceptance in .claude.json, per exact folder.
CLAUDE_STATE="${CLAUDE_CONFIG_DIR:+$CLAUDE_CONFIG_DIR/.claude.json}"; CLAUDE_STATE="${CLAUDE_STATE:-$HOME/.claude.json}"
jq -e --arg r "$HARNESS_ROOT" '.projects[$r].hasTrustDialogAccepted == true' "$CLAUDE_STATE" >/dev/null 2>&1 || {
  printf 'agent-spawn: Claude Code has not been trusted in %s, so `claude --worktree` would exit at once.\n' "$HARNESS_ROOT" >&2
  printf '  Run `claude` there once, accept the trust prompt, and spawn again.\n' >&2
  exit 1; }

mapfile -t FREE < <(spawn_free_names "$ROLE")
if [[ -n "$WANT" ]]; then
  NAME=""; for n in "${FREE[@]}"; do [[ "${n,,}" == "${WANT,,}" ]] && NAME=$n; done
  [[ -n "$NAME" ]] || { printf 'agent-spawn: %s is not a free %s (free: %s)\n' "$WANT" "$ROLE" "${FREE[*]:-none}" >&2; exit 1; }
else
  if (( ${#FREE[@]} == 0 )); then
    if roster_list_active | awk -F'\t' -v r="$ROLE" '$2 == r { f = 1 } END { exit !f }'; then
      printf 'agent-spawn: every %s on the roster is running, so none is free.\n' "$ROLE" >&2
    else
      printf 'agent-spawn: no active %s is onboarded, so there is nobody to start.\n' "$ROLE" >&2
    fi
    printf '  Bench one whose ticket has merged (bash team/agent-bench.sh <Name>), or onboard another\n' >&2
    printf '  (bash scripts/agent-onboard.sh <Name> %s) and commit the roster.\n' "$ROLE" >&2
    exit 1
  fi
  NAME=${FREE[RANDOM % ${#FREE[@]}]}
fi

SESSION="$(agent_session_name "$NAME")"
PROMPT="$(spawn_prompt "$NAME" "$ROLE" "$TICKET")"
mapfile -t IDENT < <(roster_launch_env "$NAME")
CMD=(env "${IDENT[@]}" claude --worktree "$SESSION" --name "$NAME")
[[ -n "$MODEL" ]] && CMD+=(--model "$MODEL")
CMD+=(--remote-control "$SESSION" "$PROMPT")
WHAT="$NAME ($ROLE)${TICKET:+ for $TICKET}"

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

# The budget line, and what it means for THIS role (header: developers are gated, testers are not).
BUDGET_LINE="$(bash "$BUDGET_SH" 2>&1)"; BUDGET_RC=$?
RULE="$(spawn_budget_rule "$ROLE" "$BUDGET_RC")"
case "$BUDGET_RC" in 0) VERDICT=on ;; 1) VERDICT=over ;; *) VERDICT=cannot-tell ;; esac

if (( DRY )); then
  printf 'would start %s in tmux session %s, on %s, with Remote Control on\n' "$WHAT" "$SESSION" "${MODEL:-the account default model}"
  printf '  start exactly this one with: bash team/agent-spawn.sh %s --name %s%s%s%s%s\n' \
    "$ROLE" "$NAME" "${TICKET:+ --ticket $TICKET}" "${MODEL:+ --model $MODEL}" "${WHY_ARG:- --why \"<why that model>\"}" \
    "$([[ "$RULE" == ask ]] && printf ' --owner-ok "<the owner'"'"'s words>"')"
  [[ -n "$WHY" ]] || printf '  the real spawn needs --why: the reason for the model it starts on.\n'
  printf '  first prompt: %s\n' "$PROMPT"
  [[ -z "$TICKET_LINE" ]] || printf '%s\n' "$TICKET_LINE"
  printf '%s\n' "$BUDGET_LINE"
  case "$RULE" in
    start) printf '  developer, on budget: start it, then tell the owner in one line with the budget.\n' ;;
    ask)   printf '  developer, off budget (or no reading): ask the owner first, in one line; start it with their words on --owner-ok.\n' ;;
    info)  printf '  tester: start it whatever the budget line says; testers are not budget-gated (owner, 2026-10-25). The line is information.\n' ;;
  esac
  exit 0
fi

if [[ "$RULE" == ask && -z "$OWNER_OK" ]]; then
  printf 'agent-spawn: %s\n' "$BUDGET_LINE" >&2
  printf '  a developer spawn off budget needs the owner'"'"'s OK: ask in one line (ticket, name, budget line), then start it with\n' >&2
  printf '  their words on the line: bash team/agent-spawn.sh developer --name %s%s%s%s --owner-ok "<their words>"\n' "$NAME" "${TICKET:+ --ticket $TICKET}" "${MODEL:+ --model $MODEL}" "$WHY_ARG" >&2
  printf '  (a tester is not budget-gated and starts regardless)\n' >&2
  exit 1
fi

command -v tmux >/dev/null 2>&1 || { echo "agent-spawn: tmux is not on PATH" >&2; exit 1; }
command -v claude >/dev/null 2>&1 || { echo "agent-spawn: claude is not on PATH" >&2; exit 1; }
tmux new-session -d -s "$SESSION" -c "$HARNESS_ROOT" "${CMD[@]}" \
  || { echo "agent-spawn: tmux could not start session $SESSION for $NAME" >&2; exit 1; }
tmux has-session -t "=$SESSION" 2>/dev/null \
  || { echo "agent-spawn: session $SESSION ended at once; start it by hand to see why: bash scripts/agent-onboard.sh --launch-line $NAME" >&2; exit 1; }
# The record: who was started, against which budget line, on whose word.
mkdir -p "$(dirname -- "$SPAWN_LOG")" 2>/dev/null
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$NAME" "$ROLE" "${TICKET:--}" "${MODEL:--}" "$VERDICT" "${OWNER_OK:--}" "$BUDGET_LINE" "$WHY" >> "$SPAWN_LOG" \
  || echo "agent-spawn: could not record the spawn in $SPAWN_LOG (the agent is running)" >&2
printf 'started %s in tmux session %s, on %s (%s), with Remote Control on%s\n' "$WHAT" "$SESSION" "${MODEL:-the account default model}" "$WHY" "${OWNER_OK:+; owner OK: \"$OWNER_OK\"}"
printf '  %s\n' "$BUDGET_LINE"
printf '  watch it: tmux attach -t =%s · recorded in %s\n' "$SESSION" "$SPAWN_LOG"
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
        printf '  Read the pane (tmux attach -t =%s). Tell %s, as developer, to claim it: bash scripts/feature-ticket.sh claim %s. Or bench them.\n' "$SESSION" "$NAME" "$TICKET" >&2
        exit 1; }
      sleep "$CLAIM_POLL_S"; waited=$(( waited + CLAIM_POLL_S ))
    done
  fi
fi
