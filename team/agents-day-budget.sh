#!/usr/bin/env bash
# team/agents-day-budget.sh — a day's fixed share of the account's week, counted from the week's reading when the
# day starts. The owner, 2026-10-31: "I think we need a dedicated agent budget script that dev day calls with the
# starting quota."
#
#   bash team/agents-day-budget.sh start <quota>   # opens today's day: the week reading now, plus <quota> points
#   bash team/agents-day-budget.sh [status]        # the day's line; the exit says what it means (below)
#   bash team/agents-day-budget.sh end             # closes the day: agents-budget.sh's even pacing applies again
#   bash team/agents-day-budget.sh --self-test
#
# WHY NOT agents-budget.sh. That paces the week evenly across its working hours ("45% used of 60% planned so far").
# A project that works in development days and verification days spends a fixed share on a development day, from
# wherever the week stands when the day starts, and stops when that share is spent. Under day-based spending the
# even line gives the wrong answer, so this one replaces it for the day: agent-spawn.sh reads this status first and
# falls back to agents-budget.sh only when no day is open (exit 3).
#
# THE DAY is one line in ~/.local/state/<project>/agents-day-budget (beside agents-budget.env; AGENT_DAY_BUDGET
# names it outright): the epoch it started, the week reading then, and the quota. `start` with no reading writes
# nothing (exit 2): a day counted from a guess is no day. `start` again on the same day KEEPS the first reading and
# sets the new quota, so a rerun never hands out a fresh allowance, and the owner raising the day's share is one
# command. THE DATE DOES NOT CLOSE A DAY: only `end` or the week's reset does. A development day that runs past
# midnight is still the same day ("15% of the week, pause at +16"), and a date that closed it would let `start` hand
# out a second 15 from the new reading (Cara, via Carl, 2026-10-31). A day left open by a missed `end` makes the
# next `start` count from the old reading, so it fails towards pausing early, and the line names the day it began.
#
# THE READING is team/lib/week-usage.sh's, the one the panel and agents-budget.sh show. The day has spent the
# reading less the reading at the start. It is OVER once it has spent MORE than the quota: with a quota of 15, at
# 15 points spent it is still on, and the reading that shows 16 stops it. A reading lower than the start by more
# than a few points means the week has reset since the day started, and the day is closed.
#
# EXITS (status): 0 on · 1 over (write your durable record and pause) · 2 cannot tell (no week reading) · 3 no day
# open (none started, ended, or the week has reset). start: 0 started, 2 refused, nothing
# written. end: 0.
#
# A verb that writes needs HARNESS_PROJECT in the environment (or AGENT_DAY_BUDGET), as agents-budget.sh's do: run
# from the harness checkout the project would default to "harness", and a day opened there is read by nobody.
# AGENT_BUDGET_NOW (epoch seconds) pins the clock and AGENT_DAY_BUDGET_READING ("<used %>") the reading, for the
# self-test.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"
# shellcheck source=lib/week-usage.sh
. "$_here/lib/week-usage.sh"

# How far below the day's start a reading may fall before it means the week has reset, not that one session's
# figure lags another's.
RESET_DROP=5

day_selftest() {
  local fails=0 T out rc D0 run
  T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
  has() { case "$2" in *"$3"*) echo "ok   $1" ;; *) echo "FAIL $1: '$2' lacks '$3'"; fails=$((fails + 1)) ;; esac; }
  D0=$(date -d '2026-10-30 08:00' +%s)
  # run <now offset s> <reading or -> <args…>: the script with the clock and the reading pinned
  run() { local at=$1 rd=$2; shift 2
    if [ "$rd" = - ]; then rd=; fi
    env -u CONTEXT_DIR HOME="$T" HARNESS_PROJECT=p AGENT_BUDGET_NOW=$((D0 + at)) AGENT_DAY_BUDGET_READING="$rd" \
      bash "$_here/agents-day-budget.sh" "$@" 2>&1; }

  out=$(run 0 45); rc=$?; check "no day open is exit 3" "$rc" 3; has "  and says so" "$out" "no day open"
  out=$(run 0 - start 15); rc=$?; check "start with no reading is refused" "$rc" 2
  check "  and writes nothing" "$(ls "$T/.local/state/p" 2>/dev/null)" ""
  out=$(run 0 45 start 15); rc=$?; check "start records the reading" "$rc" 0; has "  and says where it stops" "$out" "stops past 60%"
  out=$(run 600 52); rc=$?; check "7 of 15 spent is on" "$rc" 0; has "  and says how much" "$out" "7% of the day's 15% used"
  out=$(run 900 60); rc=$?; check "exactly the quota spent is still on" "$rc" 0
  out=$(run 1200 61); rc=$?; check "past the quota is over" "$rc" 1; has "  and says to pause" "$out" "write your durable record and pause"
  out=$(run 1200 -); rc=$?; check "no reading is cannot tell" "$rc" 2
  out=$(run 1300 70 start 15); check "start again the same day keeps the first reading" "$(run 1300 70 >/dev/null; echo $?)" 1
  out=$(run 1300 70 start 30); has "start again with a new quota raises the share" "$out" "stops past 75%"
  check "  and the day is on again" "$(run 1300 70 >/dev/null; echo $?)" 0
  out=$(run 1400 42); rc=$?; check "a small dip below the start is a lagging figure, still on" "$rc" 0
  out=$(run 1400 3); rc=$?; check "a reading far below the start means the week reset: no day" "$rc" 3; has "  and says so" "$out" "reset"
  out=$(run 86400 50); rc=$?; check "a day past midnight is still open" "$rc" 0
  has "  and names the day it began" "$out" "from 45% at Fri 08:00"
  out=$(run 86400 50 start 15); has "start the next morning on an open day keeps its first reading" "$out" "stops past 60%"
  out=$(run 90000 2 start 15); has "start after the week reset opens a fresh day from the new reading" "$out" "stops past 17%"
  out=$(run 1500 50 end); rc=$?; check "end exits 0" "$rc" 0
  out=$(run 1500 50); rc=$?; check "  and leaves no day open" "$rc" 3
  out=$(run 0 45 start 0); rc=$?; check "a zero quota is refused" "$rc" 2
  out=$(run 0 45 start ten); rc=$?; check "a quota that is not a number is refused" "$rc" 2
  out=$(env -u HARNESS_PROJECT -u AGENT_DAY_BUDGET HOME="$T" AGENT_DAY_BUDGET_READING=40 bash "$_here/agents-day-budget.sh" start 15 2>&1); rc=$?
  check "start with no project is refused" "$rc" 2
  out=$(run 0 45 stat 2>&1); rc=$?; check "an unknown verb is a usage error" "$rc" 2
  [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; return 1; }
}
# selftest_is_flag, not selftest_requested: the latter exits on any further argument, and this script takes verbs.
if selftest_is_flag "${1:-}"; then day_selftest; exit $?; fi
selftest_reject_typo "$@"

FILE="${AGENT_DAY_BUDGET:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/agents-day-budget}"
NOW="${AGENT_BUDGET_NOW:-$(date +%s)}"
TODAY=$(date -d "@$NOW" +%F)

# The week's reading now, as a whole number of percent, or nothing.
reading() {
  if [ -n "${AGENT_DAY_BUDGET_READING+set}" ]; then printf '%s' "$AGENT_DAY_BUDGET_READING"; return; fi
  local used _at; read -r used _at <<<"$(week_used)"
  [ "${used:--1}" -ge 0 ] 2>/dev/null && printf '%s' "$used"
}

# The open day as "<start epoch> <start reading> <quota>", or nothing when none is open.
open_day() {
  local at start quota
  [ -r "$FILE" ] || return 1
  read -r at start quota < "$FILE" || return 1
  [[ "$at" =~ ^[0-9]+$ && "$start" =~ ^[0-9]+$ && "$quota" =~ ^[0-9]+$ ]] || return 1
  printf '%s %s %s' "$at" "$start" "$quota"
}

# When the day began: the time, with the weekday once it is not today.
began() { if [ "$(date -d "@$1" +%F)" = "$TODAY" ]; then date -d "@$1" +%H:%M; else date -d "@$1" '+%a %H:%M'; fi; }

need_project() {
  [ -n "${HARNESS_PROJECT:-}${AGENT_DAY_BUDGET:-}" ] && return 0
  echo "day  refused: set HARNESS_PROJECT so the day lands where the project's spawn and pause read it" >&2; exit 2
}

case "${1:-status}" in
  start)
    need_project
    [[ "${2:-}" =~ ^[0-9]+$ && "${2:-0}" -gt 0 && "${2:-0}" -le 100 ]] \
      || { echo "day  refused: the quota is whole points of the week, 1 to 100 (start 15)" >&2; exit 2; }
    now_used=$(reading)
    [ -n "$now_used" ] || { echo "day  refused: no week reading to count from (team/lib/week-usage.sh); nothing written" >&2; exit 2; }
    # an open day keeps its first reading, unless the week has reset since: that day is over
    if day=$(open_day) && read -r at start _old <<<"$day" && [ "$now_used" -ge $((start - RESET_DROP)) ]; then :
    else at=$NOW; start=$now_used; fi
    mkdir -p "$(dirname "$FILE")" && printf '%s %s %s\n' "$at" "$start" "$2" > "$FILE"
    printf 'day  started %s: %s%% of the week from %s%% (stops past %s%%)\n' \
      "$(began "$at")" "$2" "$start" "$((start + $2))"
    ;;
  status)
    day=$(open_day) || { echo "day  none: no day open"; exit 3; }
    read -r at start quota <<<"$day"
    now_used=$(reading)
    [ -n "$now_used" ] || { echo "day  cannot tell: no week reading (team/lib/week-usage.sh)"; exit 2; }
    if [ "$now_used" -lt $((start - RESET_DROP)) ]; then
      echo "day  none: the week has reset since the day started at $(began "$at") (week ${now_used}%)"; exit 3
    fi
    spent=$((now_used > start ? now_used - start : 0))
    if [ "$spent" -gt "$quota" ]; then
      printf 'day  over: %s%% of the day'"'"'s %s%% used (week %s%%, from %s%% at %s): write your durable record and pause\n' \
        "$spent" "$quota" "$now_used" "$start" "$(began "$at")"; exit 1
    fi
    printf 'day  on: %s%% of the day'"'"'s %s%% used (week %s%%, from %s%% at %s)\n' \
      "$spent" "$quota" "$now_used" "$start" "$(began "$at")"
    ;;
  end) need_project; rm -f "$FILE"; echo "day  ended: agents-budget.sh's even pacing applies" ;;
  *) echo "usage: agents-day-budget.sh [start <quota> | status | end | --self-test]" >&2; exit 2 ;;
esac
