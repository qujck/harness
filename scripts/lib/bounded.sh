#!/usr/bin/env bash
# scripts/lib/bounded.sh — run a command under a time bound and get a status that does not lie.
# (fix_the_boxs_timeout_is_uutils_and_it_segfaults_whenever_its_child_dies_by_signal)
#
#   source scripts/lib/bounded.sh
#   run_bounded 90 some-command --args
#   rc=$?                       # the CHILD's true status, GNU-style (128+n for a signal)
#   "$BOUNDED_VERDICT"          # completed | bound-fired | wrapper-died
#   "$BOUNDED_STATUS"           # the child's status if it finished, EMPTY if it never did
#
#   bash scripts/lib/bounded.sh --self-test
#
# ── ⚠ WHY THIS EXISTS: `timeout` ON THIS BOX IS uutils 0.8.0 AND ITS STATUS LIES TWICE ───────────
#
# Driven, and re-driven on 2026-09-09 before this file was written (scripts/timeout-behaviour-probe.sh
# is the standing measurement; run it, do not trust this comment):
#
#   timeout 5 bash -c 'kill -TERM $$'   -> 15    GNU: 143   ⚠ 15 IS A PLAUSIBLE ORDINARY EXIT CODE
#   timeout 5 bash -c 'kill -SEGV $$'   -> 139              ⚠ AND `timeout` ITSELF SEGFAULTS + DUMPS CORE
#
# So a signal-killed child is indistinguishable from a child that chose that exit code, and a
# wrapper crash is indistinguishable from a child crash. There is NO GNU `timeout` on this box —
# /usr/bin/timeout and /bin/timeout are the same uutils binary — so "shell out to the real one" is
# not a remedy available to us.
#
# ── HOW IT WORKS, AND WHY THE INNER SHELL IS THE WHOLE TRICK ─────────────────────────────────────
#
# The command is run inside `bash -c`, which records ITS OWN view of the child's status to a file
# before returning. Bash normalises a signal death to 128+n, so the file gets GNU semantics for
# free — the wrapper's broken status is never consulted for a child that finished. And because the
# inner shell is a separate process, it ABSORBS a child's fatal signal instead of letting it reach
# the wrapper, which is what stops the segfault propagating.
#
# THE DISCRIMINATOR, DRIVEN — the three cases collapse to two values without it:
#
#   case                    timeout rc    status file    verdict         run_bounded exits
#   child exits 3               0            "3"         completed              3
#   child killed by TERM        0           "143"        completed            143   (was 15)
#   child killed by SEGV        0           "139"        completed            139
#   bound fires                124          EMPTY        bound-fired          124
#   ⚠ WRAPPER killed          139           EMPTY        wrapper-died         125
#
# ⚠ THE STATUS FILE BEING EMPTY IS THE SIGNAL, NOT AN ERROR. A child that finished always writes;
# one that was killed mid-run never does. That is the only thing separating "the bound fired over a
# no-op" from "the wrapper died", and both used to be 139-or-124 with nothing else to read.
#
# ── ⚠ WHAT THIS DOES *NOT* SOLVE, SAID PLAINLY SO NOBODY THINKS IT DOES ──────────────────────────
#
# A command that COMPLETED ITS WRITE and was then killed by the bound still reports `bound-fired`
# with an empty status, because it never got to return. The status file cannot know what the child
# managed to do before it died. Distinguishing "the bound fired and nothing happened" from "the
# bound fired after the work landed" REQUIRES THE CHILD'S COOPERATION — it must record a durable
# verdict at the moment its work is safe, and the caller must let that verdict beat the exit code.
#
# `park_forward_outcome` in scripts/feature-ticket.sh is the one implementation of that pattern and
# the place to copy: a verdict word wins over the exit code, IN THAT DIRECTION ONLY. This helper
# gives you the bound and an honest status; it cannot give you idempotence, and widening it to try
# is explicitly out of scope.
#
# ⚠ AND DO NOT "SIMPLIFY" THIS BY MAPPING 139 TO "child crashed". 139 is what BOTH a crashed child
# and a crashed wrapper produce. That mapping passes a naive test and preserves the exact ambiguity
# this file exists to remove — see the self-test's wrapper-died case, which is driven by SEGVing the
# wrapper process itself.

BOUNDED_VERDICT=""
BOUNDED_STATUS=""

# run_bounded [-k <grace>] <seconds> <command> [args...]
#
# ⚠ THE EXIT CODE CARRIES THE WHOLE VERDICT, DELIBERATELY, so a caller can use this inside a
# command substitution — `out="$(run_bounded ...)"; rc=$?` — where BOUNDED_VERDICT would be set in
# a subshell and lost. 124 = the bound fired, 125 = the wrapper died, anything else IS the child's
# own status. The variables are for callers who are not capturing stdout.
run_bounded() {
  local _kill=""
  if [[ "${1-}" == "-k" ]]; then _kill="${2-}"; shift 2 || true; fi
  local _secs="${1-}"; shift || true
  local _sf; _sf="$(mktemp)" || return 125
  BOUNDED_VERDICT=""; BOUNDED_STATUS=""

  # ⚠ NO PIPE, AND $? IS READ ON THE VERY NEXT LINE. A pipe here would yield the LAST command's
  # status and this helper would report 0 for every case it exists to tell apart.
  if [[ -n "$_kill" ]]; then
    timeout -k "$_kill" "$_secs" bash -c 'set +e; "$@"; printf "%s" "$?" >"$0"' "$_sf" "$@"
  else
    timeout "$_secs" bash -c 'set +e; "$@"; printf "%s" "$?" >"$0"' "$_sf" "$@"
  fi
  local _wrc=$?
  local _cs; _cs="$(cat "$_sf" 2>/dev/null)"
  rm -f "$_sf"

  if [[ -n "$_cs" ]]; then
    BOUNDED_VERDICT="completed"; BOUNDED_STATUS="$_cs"
    return "$_cs"
  fi
  if [[ "$_wrc" == 124 ]]; then
    BOUNDED_VERDICT="bound-fired"; BOUNDED_STATUS=""
    return 124
  fi
  # No status and not a timeout: the wrapper died under us. 125 is GNU timeout's own code for
  # "timeout itself failed", so it does not collide with 124 or with any child status.
  BOUNDED_VERDICT="wrapper-died"; BOUNDED_STATUS=""
  return 125
}

# ── SELF-TEST ────────────────────────────────────────────────────────────────────────────────────
# Runs only when this file is EXECUTED, never when it is sourced.
_bounded_self_test() {
  local pass=0 fail=0
  _t() { # <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; pass=$((pass+1))
    else printf '  FAIL  %s — expected [%s] got [%s]\n' "$1" "$2" "$3"; fail=$((fail+1)); fi
  }

  run_bounded 5 bash -c 'exit 3'
  _t "a normal exit is passed through"                    "3|completed"   "$?|$BOUNDED_VERDICT"

  # ⚠ NEGATIVE CONTROL (the ticket names this one): a child KILLED by SIGTERM must be
  # distinguishable from a child that CHOSE to exit 15. Bare `timeout` gives 15 for both.
  run_bounded 5 bash -c 'kill -TERM $$'; local killed=$?
  run_bounded 5 bash -c 'exit 15';       local chose=$?
  _t "NC: TERM-killed reports 143, not 15"                "143"           "$killed"
  _t "NC: a child that chose 15 still reports 15"         "15"            "$chose"
  _t "NC: and the two are DIFFERENT"                      "different"     "$([[ "$killed" != "$chose" ]] && echo different || echo COLLIDED)"

  # ⚠ NEGATIVE CONTROL: wrapper death vs child death. Both are 139 under bare `timeout`.
  run_bounded 5 bash -c 'kill -SEGV $$'
  _t "a SEGV child passes 139 through (guard, not a control — 139 either way)"         "139|completed" "$?|$BOUNDED_VERDICT"

  # ⚠ DRIVEN THROUGH run_bounded, NOT AROUND IT. An earlier version of this control SEGV'd a bare
  # `timeout` in the test body and asserted the status file stayed empty — which is true of the
  # BOX, not of this helper, so it passed with the fix removed and guarded nothing. This kills the
  # wrapper that run_bounded actually spawned and asserts the verdict IT returns.
  local wdf; wdf="$(mktemp)"
  ( run_bounded 5 sleep 4; printf '%s|%s' "$?" "$BOUNDED_VERDICT" > "$wdf" ) &
  local sub=$!
  sleep 0.3
  # ⚠ CAPTURE, THEN SLICE — never `pgrep | head -1`. head exits after one line, SIGPIPEs pgrep, and
  # under pipefail that becomes the pipeline's status: a false failure from a reader that already
  # had what it needed. Same shape as the `timeout --version | head -1` this ticket already fixed.
  local _pg; _pg="$(pgrep -P "$sub" -x timeout 2>/dev/null)"
  local tpid="${_pg%%$'\n'*}"
  [[ -n "$tpid" ]] && kill -SEGV "$tpid" 2>/dev/null
  wait "$sub" 2>/dev/null
  local wd; wd="$(cat "$wdf" 2>/dev/null)"; rm -f "$wdf"
  _t "NC: a SEGV'd WRAPPER is wrapper-died, not a 139 child" "125|wrapper-died" "$wd"

  # ⚠ NEGATIVE CONTROL: the bound must still work. Deleting the `timeout` wrapper to dodge the
  # defect is a regression, and this item is what fails if anyone does.
  local t0 t1; t0=$(date +%s)
  run_bounded 0.3 sleep 30; local brc=$?
  t1=$(date +%s)
  _t "NC: the bound still fires"                          "124|bound-fired" "$brc|$BOUNDED_VERDICT"
  _t "NC: …and it actually bounded the runtime"           "bounded"       "$([[ $((t1-t0)) -lt 10 ]] && echo bounded || echo UNBOUNDED)"

  # ⚠ NEGATIVE CONTROL for the 124-means-nothing-happened case. The helper alone CANNOT tell these
  # apart — that is the documented limit — so this asserts the CALLER-COOPERATION pattern works:
  # the child records a durable verdict before the bound can reach it, and that verdict is what
  # separates them. A fix that only maps signal exits to 128+n passes everything above and fails here.
  local mark; mark="$(mktemp)"; rm -f "$mark"
  run_bounded 0.3 bash -c 'printf done >"$1"; sleep 30' _ "$mark"
  local wrote_rc=$? wrote_v="$BOUNDED_VERDICT" wrote_mark="$([[ -s "$mark" ]] && echo present || echo absent)"
  rm -f "$mark"
  local mark2; mark2="$(mktemp)"; rm -f "$mark2"
  run_bounded 0.3 bash -c 'sleep 30' _ "$mark2"
  local noop_v="$BOUNDED_VERDICT" noop_mark="$([[ -s "$mark2" ]] && echo present || echo absent)"
  rm -f "$mark2"
  _t "NC: work-then-bound and no-op-then-bound agree on the STATUS" "124|124" "$wrote_rc|124"
  _t "NC: …and the verdicts alone cannot separate them"    "bound-fired|bound-fired" "$wrote_v|$noop_v"
  _t "NC: …but the child's durable marker CAN"             "present|absent" "$wrote_mark|$noop_mark"

  # -k is what the real call sites pass; assert it still bounds and still classifies.
  run_bounded -k 1 0.3 sleep 30
  _t "-k still bounds and still reports bound-fired"      "124|bound-fired" "$?|$BOUNDED_VERDICT"
  run_bounded -k 1 5 bash -c 'exit 4'
  _t "-k passes a normal status through"                  "4|completed"   "$?|$BOUNDED_VERDICT"

  printf '\n%s: %d passed, %d failed\n' "$([[ $fail == 0 ]] && echo PASS || echo FAIL)" "$pass" "$fail"
  [[ $fail == 0 ]]
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # ⚠ THE SHARED FLAG CONTRACT, NOT A HAND-ROLLED `case`. An unrecognised flag must not fall
  # through and run something else that exits 0 — that is a self-test reported as passing when it
  # never ran, which is the same false-green family this whole file exists to remove.
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/selftest-flag.sh"
  if selftest_requested "$@"; then
    _bounded_self_test; exit $?
  fi
  printf 'usage: bash %s --self-test   (or: source it and call run_bounded)\n' "$0"
  exit 2
fi
