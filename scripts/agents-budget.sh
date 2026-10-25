#!/usr/bin/env bash
# scripts/agents-budget.sh — is the team inside the owner's weekly budget? The delivery lead's test before it
# starts another agent (docs/roles/delivery-lead.md, "The size of the team").
#
#   bash scripts/agents-budget.sh                          one line, and the exit code
#   bash scripts/agents-budget.sh approve <pct> "<words>"  OWNER: today's plan, at close of day, becomes <pct>
#   bash scripts/agents-budget.sh adjust <+N|-N> "<words>" OWNER: add or take back N points, from now
#   bash scripts/agents-budget.sh adjustments              this week's entries and their sum
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
# THE OWNER'S ADJUSTMENTS (owner, 2026-10-25: "I'd like to approve 60% for today, so burn some contingency and
# run out sooner"). The plan above is a straight line; the week's allowance is not, and the owner moves it. Each
# entry in ~/.local/state/<project>/agents-budget-adjust.tsv (AGENT_BUDGET_ADJUST) adds its delta, in points, to
# the plan from the moment it is written for the REST OF THE WEEK: the plan at the reset rises by the same
# amount, so what was contingency is spent earlier, and a negative delta gives it back. `approve <pct>` records
# the delta that makes today's plan AT CLOSE OF DAY (or now, once the day has shut) equal <pct>; `adjust ±N`
# records N itself. Entries carry the epoch of the reset they were written under and are counted only while
# that reset is the current one: the reset clears them without deleting the history. Every entry needs the
# owner's words (no blank, no `<placeholder>`), and the budget line shows the sum: "of 60% planned so far
# (owner +7.4)". The panel's mark and agent-spawn.sh read that line as before.
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

  # ── the owner's adjustments ──────────────────────────────────────────────────────────────────────────
  # verb <what> <want exit> <want text> <now> <week %> <written at> <args...>
  verb() {
    local what=$1 code=$2 text=$3 now out rc; local pct=$5 wrote=$6
    now=$(TZ=Europe/London date -d "$4" +%s); shift 6
    rm -f "$T/ctx/"*.json
    printf '{"ts":"%s","week":{"used_pct":%s}}\n' "$(date -u -d "$wrote" +%FT%TZ)" "$pct" > "$T/ctx/a.json"
    out=$(env -u AGENT_WEEK_PCT_PER_HOUR -u AGENT_WEEK_RESET -u AGENT_WORK_DAYS -u AGENT_WORK_HOURS GIT_AUTHOR_NAME=Owner \
            TZ=Europe/London HARNESS_ROOT="$T/repo" CONTEXT_DIR="$T/ctx" AGENT_BUDGET_NOW="$now" AGENT_BUDGET_ADJUST="$T/adjust.tsv" \
            bash "$SELF" "$@" 2>&1); rc=$?
    if [[ "$rc" == "$code" ]] && grep -qF -- "$text" <<<"$out"; then printf '  ok   %s\n' "$what"
    else printf '  FAIL %s\n       want exit %s and %q\n       got  exit %s: %s\n' "$what" "$code" "$text" "$rc" "$out"; fails=$((fails+1)); fi
  }
  rows() { [[ -f "$T/adjust.tsv" ]] && wc -l < "$T/adjust.tsv" || echo 0; }
  printf 'AGENT_WEEK_PCT_PER_HOUR=2\nAGENT_WEEK_RESET="Sun 07:00"\n' > "$T/repo/harness.env"
  rm -f "$T/adjust.tsv"
  # Wednesday 12:00: 44% planned so far, 54% at today's close (17:00). 45% used is over.
  verb "the owner approves 60% for today: the delta is 60 - 54 at close, +6" 0 "week 45% used of 50% planned so far (owner +6)" \
       "2026-10-21 12:00" 45 "2026-10-21 11:59" approve 60 "burn some contingency today"
  [[ "$(rows)" == 1 ]] && printf '  ok   one entry recorded\n' || { printf '  FAIL entries: %s\n' "$(rows)"; fails=$((fails+1)); }
  verb "  and at close of day the plan is 60%" 0 "of 60% planned so far (owner +6)" "2026-10-21 17:00" 59 "2026-10-21 16:59"
  verb "  the entry holds for the rest of the week: Saturday plans 90 + 6" 0 "of 96% planned so far (owner +6)" "2026-10-24 10:00" 89 "2026-10-24 09:59"
  verb "  and is not counted after the reset" 2 "planned 0%)" "2026-10-25 08:00" 1 "2026-10-24 09:59"
  verb "adjust -6 takes it back from now" 0 "of 44% planned so far" "2026-10-21 12:00" 41 "2026-10-21 11:59" adjust -6 "too much"
  verb "  with the sum shown as 0" 0 "(owner +0)" "2026-10-21 12:00" 41 "2026-10-21 11:59"
  verb "adjust +2.5 is a decimal" 0 "of 46% planned so far (owner +2.5)" "2026-10-21 12:00" 41 "2026-10-21 11:59" adjust +2.5 "a little more"
  verb "approve below the plan records a negative delta" 0 "(owner -4)" "2026-10-21 12:00" 35 "2026-10-21 11:59" approve 50 "pull it back"
  verb "  so a 41% week is now over" 1 "of 40% planned so far (owner -4): ask" "2026-10-21 12:00" 41 "2026-10-21 11:59"
  verb "adjustments lists the week's entries and the sum" 0 "sum -4" "2026-10-21 12:00" 41 "2026-10-21 11:59" adjustments
  verb "  naming who wrote them" 0 "Owner" "2026-10-21 12:00" 41 "2026-10-21 11:59" adjustments
  local before; before=$(rows)
  verb "blank words are refused" 2 "words" "2026-10-21 12:00" 41 "2026-10-21 11:59" approve 60 ""
  verb "a placeholder is refused" 2 "words" "2026-10-21 12:00" 41 "2026-10-21 11:59" approve 60 "<your words>"
  verb "no words at all is a usage error" 2 "usage" "2026-10-21 12:00" 41 "2026-10-21 11:59" approve 60
  verb "a percentage that is not a number is refused" 2 "not a percentage" "2026-10-21 12:00" 41 "2026-10-21 11:59" approve sixty "words"
  verb "a delta without a sign is refused" 2 "like +5 or -5" "2026-10-21 12:00" 41 "2026-10-21 11:59" adjust 5 "words"
  verb "an unknown verb is a usage error" 2 "usage" "2026-10-21 12:00" 41 "2026-10-21 11:59" frobnicate
  [[ "$(rows)" == "$before" ]] && printf '  ok   refusals record nothing\n' || { printf '  FAIL refusals recorded: %s -> %s\n' "$before" "$(rows)"; fails=$((fails+1)); }
  : > "$T/repo/harness.env"
  verb "with no budget set, approve is refused" 2 "none set" "2026-10-21 12:00" 41 "2026-10-21 11:59" approve 60 "words"
  [[ "$(rows)" == "$before" ]] && printf '  ok   and records nothing\n' || { printf '  FAIL no-budget approve recorded: %s -> %s\n' "$before" "$(rows)"; fails=$((fails+1)); }
  printf 'AGENT_WEEK_PCT_PER_HOUR=2\nAGENT_WEEK_RESET="Sun 07:00"\n' > "$T/repo/harness.env"
  printf 'garbage line\n' >> "$T/adjust.tsv"
  verb "a malformed entry is skipped, said on stderr" 0 "(owner -4)" "2026-10-21 12:00" 35 "2026-10-21 11:59"
  verb "  and named" 0 "skipped" "2026-10-21 12:00" 35 "2026-10-21 11:59"

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

# selftest_is_flag, not selftest_requested: the latter exits on any further argument, and this script takes verbs.
if selftest_is_flag "${1:-}"; then
  [[ $# -eq 1 ]] || { printf 'unknown argument: %s\nusage: agents-budget.sh [--self-test]\n' "$2" >&2; exit 2; }
  budget_self_test; exit $?
fi

RATE="${AGENT_WEEK_PCT_PER_HOUR:-0}"; RESET="${AGENT_WEEK_RESET:-}"
DAYS="${AGENT_WORK_DAYS:-Mon Tue Wed Thu Fri}"; HOURS="${AGENT_WORK_HOURS:-08:00-17:00}"
ADJUST="${AGENT_BUDGET_ADJUST:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/agents-budget-adjust.tsv}"
VERB="${1:-}"
case "$VERB" in
  ''|approve|adjust|adjustments) ;;
  *) printf 'usage: agents-budget.sh [approve <pct> "<words>" | adjust <+N|-N> "<words>" | adjustments | --self-test]\n' >&2; exit 2 ;;
esac
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

# budget_calc -> "plan plan_at_close reset_epoch sum" : the straight-line plan now and at today's close, the epoch
# of the current reset (whole minutes), and the sum of this week's adjustments. Malformed entries are said on
# stderr and skipped; a missing file is no adjustment.
budget_calc() {
  awk -v now="$now" -v nows="$NOW_S" -v rate="$RATE" -v reset="$RESET" -v days="$DAYS" -v hours="$HOURS" -v adjust="$ADJUST" '
    function planned(upto,   mins, day, a, b) {
      mins = 0
      for (day = -7; day < 7; day++) {
        if (!(((day + 7) % 7) in work)) continue
        a = day * 1440 + open; b = day * 1440 + shut
        if (a < from) a = from; if (b > upto) b = upto
        if (b > a) mins += b - a
      }
      return rate * mins / 60
    }
    BEGIN {
      split("Sun Mon Tue Wed Thu Fri Sat", n, " "); for (i = 1; i <= 7; i++) dn[n[i]] = i - 1
      split(reset, r, "[ :]"); rs = dn[r[1]] * 1440 + r[2] * 60 + r[3]
      split(hours, h, "[-:]"); open = h[1] * 60 + h[2]; shut = h[3] * 60 + h[4]
      k = split(days, d, " "); for (i = 1; i <= k; i++) work[dn[d[i]]] = 1
      since = now - rs; if (since < 0) since += 10080           # minutes since the reset
      from = now - since                                        # the reset, possibly last week (negative)
      cl = int(now / 1440) * 1440 + shut   # today's close; after it, no working minutes separate close from now
      reset_epoch = nows - (nows % 60) - since * 60
      sum = 0
      while ((getline line < adjust) > 0) {
        nf = split(line, f, "\t")
        if (nf < 5 || f[1] !~ /^[0-9]+$/ || f[2] !~ /^[0-9]+$/ || f[3] !~ /^[-+]?[0-9]+([.][0-9]+)?$/) {
          printf "budget  skipped a malformed entry in %s: %s\n", adjust, line > "/dev/stderr"; continue }
        if (f[2] + 0 == reset_epoch) { sum += f[3]; cnt++ }
      }
      printf "%.4f %.4f %d %.4f %d\n", planned(now), planned(cl), reset_epoch, sum, cnt + 0
    }'
}
read -r plan plan_close reset_epoch sum cnt <<<"$(budget_calc)"

# The owner's words: not blank, not a <placeholder>, no control characters.
words_ok() { local w; w="$(printf '%s' "${1-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "$w" && ! "$w" =~ ^\<.*\>$ && ! "$w" =~ [[:cntrl:]] ]]; }
record() { # <delta> <words>
  mkdir -p "$(dirname -- "$ADJUST")" || { echo "budget  cannot write $ADJUST" >&2; exit 2; }
  printf '%s\t%s\t%s\t%s\t%s\n' "$NOW_S" "$reset_epoch" "$1" "${GIT_AUTHOR_NAME:-${USER:-?}}" "$2" >> "$ADJUST" \
    || { echo "budget  cannot write $ADJUST" >&2; exit 2; }
  read -r plan plan_close reset_epoch sum cnt <<<"$(budget_calc)"
}
case "$VERB" in
  approve)
    [[ $# -ge 3 ]] || { printf 'usage: agents-budget.sh approve <pct> "<the owner'"'"'s words>"\n' >&2; exit 2; }
    [[ $2 =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v p="$2" 'BEGIN{exit !(p<=100)}' || { printf 'budget  %q is not a percentage (0-100)\n' "$2" >&2; exit 2; }
    words_ok "$3" || { echo "budget  approve needs the owner's words: not blank, not a <placeholder>" >&2; exit 2; }
    delta=$(awk -v p="$2" -v c="$plan_close" -v s="$sum" 'BEGIN{d=p-c-s; printf (d>=0?"+%.4g":"%.4g"), d}')
    record "$delta" "$3"
    printf 'budget  approved: today closes at %s%% planned (owner %s, this entry %s)\n' "$2" "$(awk -v s="$sum" 'BEGIN{printf (s>=0?"+%.4g":"%.4g"), s}')" "$delta" ;;
  adjust)
    [[ $# -ge 3 ]] || { printf 'usage: agents-budget.sh adjust <+N|-N> "<the owner'"'"'s words>"\n' >&2; exit 2; }
    [[ $2 =~ ^[-+][0-9]+([.][0-9]+)?$ ]] || { printf 'budget  %q is not a delta like +5 or -5\n' "$2" >&2; exit 2; }
    words_ok "$3" || { echo "budget  adjust needs the owner's words: not blank, not a <placeholder>" >&2; exit 2; }
    record "$2" "$3"
    printf 'budget  adjusted by %s (owner %s this week)\n' "$2" "$(awk -v s="$sum" 'BEGIN{printf (s>=0?"+%.4g":"%.4g"), s}')" ;;
  adjustments)
    printf 'budget  adjustments this week (since reset %s), from %s:\n' "$(date -d "@$reset_epoch" '+%a %H:%M' 2>/dev/null || date -r "$reset_epoch" '+%a %H:%M')" "$ADJUST"
    if [[ -f "$ADJUST" ]]; then
      awk -F'\t' -v re="$reset_epoch" 'NF >= 5 && $2 == re { printf "  %s\t%s\t%s\t%s\n", strftime("%a %H:%M", $1), $3, $4, $5 }' "$ADJUST"
    fi
    printf '  sum %s\n' "$(awk -v s="$sum" 'BEGIN{printf (s>=0?"+%.4g":"%.4g"), s}')"
    exit 0 ;;
esac

awk -v plan="$plan" -v sum="$sum" -v cnt="$cnt" -v used="${used:--1}" -v at="${at:-0}" -v nows="$NOW_S" -v re="$reset_epoch" '
  BEGIN {
    total = plan + sum
    owner = (cnt > 0) ? sprintf(" (owner %s%.4g)", (sum >= 0 ? "+" : ""), sum) : ""   # said whenever the week has an entry, even at +0
    if (used < 0 || at < re) {
      printf "budget  no reading of the week since it reset: ask the owner (planned %.0f%%%s)\n", total, owner; exit 2 }
    if (used <= total) { printf "budget  on: week %d%% used of %.0f%% planned so far%s\n", used, total, owner; exit 0 }
    printf "budget  over: week %d%% used of %.0f%% planned so far%s: ask the owner\n", used, total, owner; exit 1
  }'
