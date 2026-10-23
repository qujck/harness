#!/usr/bin/env bash
# scripts/agents-budget.sh — is the team inside the owner's weekly budget? The delivery lead's test before it
# starts another agent (docs/roles/delivery-lead.md, "The size of the team").
#
#   bash scripts/agents-budget.sh             one line, and the exit code
#   bash scripts/agents-budget.sh --self-test
#
# Exit: 0 on budget · 1 over it · 2 cannot tell (no budget set, a malformed setting, or no reading of the week
# since it reset). The budget decides only whether the lead asks the owner before starting an agent; it never
# decides which model the agent runs on.
#
# THE BUDGET is AGENT_WEEK_PCT_PER_HOUR percent of the account's weekly allowance for every working hour
# (AGENT_WORK_DAYS, AGENT_WORK_HOURS) since the week last reset (AGENT_WEEK_RESET), in local time. E.g. at 2 an
# hour, 08:00-17:00 Monday to Friday, by Wednesday 12:00 the budget is (9 + 9 + 4) x 2 = 44%: a week at 41% is
# on budget, one at 45% is over. Hours outside the working day add nothing, so work in the evening or at the
# weekend spends from the next working day's share. All four live in harness.env; with no rate set (blank or 0)
# there is no budget and the answer is always "ask".
#
# THE WEEK'S USE is scripts/lib/week-usage.sh's reading, the one the panel shows. A reading older than the
# reset is no reading: the week it measured is over.
#
# AGENT_BUDGET_NOW (epoch seconds) pins the clock for the self-test.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="$_here/$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=lib/selftest-flag.sh
. "$_here/lib/selftest-flag.sh"
# shellcheck source=lib/harness-env.sh
. "$_here/lib/harness-env.sh"
# shellcheck source=lib/week-usage.sh
. "$_here/lib/week-usage.sh"

budget_self_test() {
  local fails=0 T
  T="$(mktemp -d)" || return 2
  trap 'rm -rf "$T"' RETURN
  mkdir -p "$T/repo" "$T/ctx"
  # check <what> <want exit> <want text> <now "YYYY-mm-dd HH:MM", London> [<week %> <written at "YYYY-mm-dd HH:MM">]
  check() {
    local what=$1 code=$2 text=$3 now out rc
    now=$(TZ=Europe/London date -d "$4" +%s)
    rm -f "$T/ctx/"*.json
    [[ -n "${5:-}" ]] && printf '{"ts":"%s","week":{"used_pct":%s}}\n' "$(date -u -d "$6" +%FT%TZ)" "$5" > "$T/ctx/a.json"
    out=$(env -u AGENT_WEEK_PCT_PER_HOUR -u AGENT_WEEK_RESET -u AGENT_WORK_DAYS -u AGENT_WORK_HOURS \
            TZ=Europe/London HARNESS_ROOT="$T/repo" CONTEXT_DIR="$T/ctx" AGENT_BUDGET_NOW="$now" bash "$SELF" 2>&1); rc=$?
    if [[ "$rc" == "$code" ]] && grep -qF -- "$text" <<<"$out"; then printf '  ok   %s\n' "$what"
    else printf '  FAIL %s\n       want exit %s and %q\n       got  exit %s: %s\n' "$what" "$code" "$text" "$rc" "$out"; fails=$((fails+1)); fi
  }

  : > "$T/repo/harness.env"
  check "no budget set: ask" 2 "none set" "2026-10-21 12:00" 10 "2026-10-21 11:59"
  printf 'AGENT_WEEK_PCT_PER_HOUR=0\nAGENT_WEEK_RESET="Sun 07:00"\n' > "$T/repo/harness.env"
  check "a rate of 0 is no budget" 2 "none set" "2026-10-21 12:00" 10 "2026-10-21 11:59"

  printf 'AGENT_WEEK_PCT_PER_HOUR=2\nAGENT_WEEK_RESET="Sun 07:00"\n' > "$T/repo/harness.env"
  check "Wednesday 12:00 plans 9+9+4 hours: 41% is on budget" 0 "week 41% used of 44% planned" "2026-10-21 12:00" 41 "2026-10-21 11:59"
  check "  and 45% is over" 1 "week 45% used of 44% planned" "2026-10-21 12:00" 45 "2026-10-21 11:59"
  check "an hour at the weekend plans nothing" 0 "of 0% planned" "2026-10-18 12:00" 0 "2026-10-18 11:59"
  check "Saturday plans the whole working week, 45 hours" 0 "of 90% planned" "2026-10-24 10:00" 89 "2026-10-24 09:59"
  check "before Sunday's reset it is still last week" 1 "of 90% planned" "2026-10-25 06:00" 95 "2026-10-25 05:59"
  check "a reading from before the reset is no reading" 2 "no reading of the week since it reset" "2026-10-26 09:00" 89 "2026-10-24 09:59"
  check "no reading at all is no reading" 2 "no reading of the week since it reset" "2026-10-21 12:00"

  printf 'AGENT_WEEK_PCT_PER_HOUR=2\nAGENT_WEEK_RESET="Sun 07:00"\nAGENT_WORK_DAYS="Mon Tue"\nAGENT_WORK_HOURS="09:00-12:30"\n' > "$T/repo/harness.env"
  check "the working days and hours are the owner's: Wednesday has 2 x 3.5 hours behind it" 0 "of 14% planned" "2026-10-21 12:00" 10 "2026-10-21 11:59"

  printf 'AGENT_WEEK_PCT_PER_HOUR=2\nAGENT_WEEK_RESET="Sunday"\n' > "$T/repo/harness.env"
  check "a malformed reset is refused" 2 "is not like 'Sun 07:00'" "2026-10-21 12:00" 41 "2026-10-21 11:59"
  printf 'AGENT_WEEK_PCT_PER_HOUR=two\nAGENT_WEEK_RESET="Sun 07:00"\n' > "$T/repo/harness.env"
  check "a rate that is not a number is no budget" 2 "none set" "2026-10-21 12:00" 41 "2026-10-21 11:59"
  printf 'AGENT_WEEK_PCT_PER_HOUR=2\nAGENT_WEEK_RESET="Sun 07:00"\nAGENT_WORK_HOURS="8-17"\n' > "$T/repo/harness.env"
  check "malformed working hours are refused" 2 "is not like '08:00-17:00'" "2026-10-21 12:00" 41 "2026-10-21 11:59"

  # the week's reading (scripts/lib/week-usage.sh), which the panel shares
  local r
  rm -f "$T/ctx/"*.json
  r=$(CONTEXT_DIR="$T/ctx" week_used)
  [[ "$r" == "-1 0" ]] && printf '  ok   %s\n' "no rows: no reading" || { printf '  FAIL no rows: got %q\n' "$r"; fails=$((fails+1)); }
  printf '{"ts":"2026-10-21T11:00:00Z","week":{"used_pct":40}}\n' > "$T/ctx/a.json"
  printf '{"ts":"2026-10-21T11:00:30Z","week":{"used_pct":38.6}}\n' > "$T/ctx/b.json"
  printf '{"ts":"2026-10-21T10:00:00Z","week":{"used_pct":90}}\n' > "$T/ctx/c.json"
  printf 'not json\n' > "$T/ctx/d.json"
  r=$(CONTEXT_DIR="$T/ctx" week_used)
  [[ "$r" == "40 $(date -u -d 2026-10-21T11:00:30Z +%s)" ]] \
    && printf '  ok   %s\n' "the highest figure within a minute of the freshest row; an hour-old row and a bad file are ignored" \
    || { printf '  FAIL the week reading: got %q\n' "$r"; fails=$((fails+1)); }

  if (( fails == 0 )); then echo "agents-budget --self-test: PASS"; return 0; fi
  echo "agents-budget --self-test: FAIL ($fails)"; return 1
}

if selftest_requested "$@"; then budget_self_test; exit $?; fi

RATE="${AGENT_WEEK_PCT_PER_HOUR:-0}"; RESET="${AGENT_WEEK_RESET:-}"
DAYS="${AGENT_WORK_DAYS:-Mon Tue Wed Thu Fri}"; HOURS="${AGENT_WORK_HOURS:-08:00-17:00}"
[[ $RATE =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ ! $RATE =~ ^0+([.]0+)?$ ]] \
  || { echo "budget  none set (AGENT_WEEK_PCT_PER_HOUR in harness.env): ask the owner"; exit 2; }
[[ $RESET =~ ^(Sun|Mon|Tue|Wed|Thu|Fri|Sat)\ ([0-9]{2}):([0-9]{2})$ ]] \
  || { echo "budget  AGENT_WEEK_RESET '$RESET' is not like 'Sun 07:00': ask the owner"; exit 2; }
[[ $HOURS =~ ^([0-9]{2}):([0-9]{2})-([0-9]{2}):([0-9]{2})$ ]] \
  || { echo "budget  AGENT_WORK_HOURS '$HOURS' is not like '08:00-17:00': ask the owner"; exit 2; }

# Minutes into the week (Sunday 00:00 = 0), local time. GNU date, else BSD date.
NOW_S="${AGENT_BUDGET_NOW:-$(date +%s)}"
read -r U H M <<<"$(date -d "@$NOW_S" '+%u %H %M' 2>/dev/null || date -r "$NOW_S" '+%u %H %M')"
now=$(( (U % 7) * 1440 + 10#$H * 60 + 10#$M ))
read -r used at <<<"$(week_used)"

awk -v now="$now" -v nows="$NOW_S" -v rate="$RATE" -v reset="$RESET" -v days="$DAYS" -v hours="$HOURS" \
    -v used="${used:--1}" -v at="${at:-0}" '
  BEGIN {
    split("Sun Mon Tue Wed Thu Fri Sat", n, " "); for (i = 1; i <= 7; i++) dn[n[i]] = i - 1
    split(reset, r, "[ :]"); rs = dn[r[1]] * 1440 + r[2] * 60 + r[3]
    split(hours, h, "[-:]"); open = h[1] * 60 + h[2]; shut = h[3] * 60 + h[4]
    k = split(days, d, " "); for (i = 1; i <= k; i++) work[dn[d[i]]] = 1
    since = now - rs; if (since < 0) since += 10080           # minutes since the reset
    from = now - since                                        # the reset, possibly last week (negative)
    mins = 0
    for (day = -7; day < 7; day++) {
      if (!(((day + 7) % 7) in work)) continue
      a = day * 1440 + open; b = day * 1440 + shut
      if (a < from) a = from; if (b > now) b = now
      if (b > a) mins += b - a
    }
    plan = rate * mins / 60
    if (used < 0 || at < nows - since * 60) {
      printf "budget  no reading of the week since it reset: ask the owner (planned %.0f%%)\n", plan; exit 2 }
    if (used <= plan) { printf "budget  on: week %d%% used of %.0f%% planned so far\n", used, plan; exit 0 }
    printf "budget  over: week %d%% used of %.0f%% planned so far: ask the owner\n", used, plan; exit 1
  }'
