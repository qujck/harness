#!/usr/bin/env bash
# ── systemd OnFailure handler — turn a failed unit into an email ─────────────────────────────
#
#   bash scripts/ops-alert-unit-failure.sh <unit-name>
#
# Wired in as `OnFailure=strength-unit-failure@%n.service`, so the failing unit's own name is
# passed through and one handler serves every timer we schedule.
#
# WHY THIS EXISTS (infra_batcher_stall_alerts). On 2026-08-07 the merge batcher stopped making
# progress for ~45 minutes across ~14 ticks and the merge queue froze behind it. systemd had
# already written the evidence at 11:31:
#
#     strength-merge-batch.service: Failed with result 'exit-code'.
#
# Nobody was listening, so it may as well not have been recorded. The owner found out by asking
# why nothing was merging. An unwatched failure signal is not monitoring, it is an audit trail
# for the post-mortem.
#
# ⚠ THIS ALONE IS NOT ENOUGH, AND THE UNIT IT WATCHES KNOWS IT. Half of that incident exited 0
# on every tick while achieving nothing — a green `ok` on a batcher that could never form
# another batch. A handler that fires on non-zero exits would have caught the second stall and
# missed the first entirely. The unit itself must therefore judge whether its tick ACHIEVED
# anything; see merge-batch.sh's stall counter, which turns "productive nothing" into an exit 1
# that lands here.
#
# ⚠ NEVER let this exit non-zero on a send failure. OnFailure handlers that fail can be started
# by their own failure, and a mail outage would become a spin. Every path returns 0.
#
# ── ⚠ ONE EMAIL PER INCIDENT, AND ONE WHEN IT IS FIXED ───────────────────────────────────────────
#
# Until 2026-08-14 two units pointed here and every failure emailed; then eleven more were wired, and
# strength-release-claims failed 391 consecutive times over four days. A repeat ladder (1h → 6h → daily)
# held that to ~7 emails. The owner then asked for something the ladder could not give — "one when it
# fails, and one, however much later, when it's fixed" — so each unit is now a CONDITION,
# `unit-failed:<unit>`, in the shared library: one email when it starts failing, none for any repeat,
# and one [RECOVERED] once pr-refresh's sweeper (systemd has no OnSuccess) has seen it clean for 10
# minutes. An email that could not be sent leaves the condition unopened, so the next failure retries —
# the silence-proof property the ladder's "if the state cannot be written, SEND" rule protected.
# (infra_every_ops_alert_sender_moves_to_the_condition_contract_with_a_recovery_for_each)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness-env.sh" 2>/dev/null || true

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 0

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib/selftest-flag.sh" 2>/dev/null || true

# ── the pure half ───────────────────────────────────────────────────────────────────────────────

# ⚠ THE REPEAT LADDER (1h → 6h → daily, per incident) THAT LIVED HERE IS GONE, AND THE CONDITION REPLACES IT.
# It existed because strength-release-claims failed 391 times in four days and every failure emailed. The
# shared library now gives each failing unit ONE email when it starts failing — keyed `unit-failed:<unit>`,
# so the 391st failure is the same condition as the 1st — and ONE when it has run clean for 10 minutes,
# which the ladder could never send: systemd has no OnSuccess, so the recovery is observed by a sweeper
# on pr-refresh's tick (sweep_recovered_units). The owner asked for exactly that pair.
# (infra_every_ops_alert_sender_moves_to_the_condition_contract_with_a_recovery_for_each)

# ── ⚠ AND IT CARRIES FACTS, NOT A HYPOTHESIS ────────────────────────────────────────────────────
#
# infra_an_alert_asks_a_human_for_facts_it_already_has. The chain's first real delivery escalated
# correctly and then told the owner to "investigate the holder" of a lock. The holder was healthy.
# The four facts that would have settled it were each one `systemctl show` away at send time, and
# the reader had to gather them by hand — which is how an alert channel earns its way to being muted.
#
# So the mail now carries what the handler can cheaply establish. Three properties are non-negotiable
# and each has a test below:
#
#   1. ENRICHMENT MAY NEVER SUPPRESS AN ALERT. If gathering context fails, throws, hangs or returns
#      nothing, the alert goes out anyway and says it is bare. An alert that dies assembling its own
#      explanation is strictly worse than the bare one it replaced, and it is the self-sealing shape
#      this repo has hit repeatedly: a step that fails toward "and therefore do nothing".
#   2. AN UNFAMILIAR UNIT STILL ALERTS, and says plainly it has no context. A handler that only fires
#      when it can enrich goes silent on the unfamiliar failure — which is every new failure.
#   3. NOTHING EXPENSIVE, AND NO LOCK. The handler must not take the lock it is reporting on, run a
#      build, or touch the network. `systemctl show` and nothing more.

# context_or_none <gathered> -> the block to embed   (pure)
context_or_none() {
  local got="${1-}"
  if [[ -z "${got//[[:space:]]/}" ]]; then
    printf 'No further context could be gathered for this unit — the journal below is everything known.\n'
  else
    printf '%s\n' "$got"
  fi
}

# recovery_note <active-state> -> a plain reading of whether it still matters   (pure)
# ⚠ THE SINGLE MOST USEFUL FACT IN A FAILURE EMAIL IS WHETHER IT IS STILL FAILING, and the alert had
# never said. A unit that failed once and has since run cleanly is a different message from one that
# is still down, and the reader currently has to ssh in to tell them apart.
recovery_note() {
  case "${1-}" in
    active|activating) printf 'It is RUNNING again now — this may already be resolved.\n' ;;
    inactive)          printf 'It is idle now (a oneshot that exits is normally inactive between runs).\n' ;;
    failed)            printf 'It is STILL IN A FAILED STATE right now.\n' ;;
    '')                printf 'Its current state could not be read.\n' ;;
    *)                 printf 'Its current state is %s.\n' "$1" ;;
  esac
}

# ── self-test ───────────────────────────────────────────────────────────────────────────────────
declare -F selftest_reject_typo >/dev/null && selftest_reject_typo "${1:-}"
if declare -F selftest_is_flag >/dev/null && selftest_is_flag "${1:-}"; then
  fails=0

  # ── THE ENRICHMENT, AND THE TWO WAYS IT MUST NOT BACKFIRE ──────────────────────────────────
  c() { local want="$1" desc="$2" got; got="$(context_or_none "$3")"
        if [[ "$got" == "$want" ]]; then printf '  ok    %s\n' "$desc"
        else printf '  FAIL  %s\n        want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  c 'No further context could be gathered for this unit — the journal below is everything known.' \
    'an unfamiliar unit is alerted about, and told plainly that nothing is known' ''
  c 'No further context could be gathered for this unit — the journal below is everything known.' \
    'whitespace is not context either' '   '
  c 'ActiveState=failed' 'gathered context is passed through unchanged' 'ActiveState=failed'

  # ⚠ THE CONTROL THAT MATTERS MOST, AND IT DRIVES THE COMPOSITION RATHER THAN THE FUNCTION. The
  # risk is not that context_or_none mishandles an empty string — it is that the GATHERING step dies
  # and takes the alert with it. So this defines a gatherer that fails the way a real one would, and
  # asserts the expression used in the impure half still yields a sendable block.
  broken_gather() { printf 'partial' ; exit 7; }
  got="$(context_or_none "$( { broken_gather; } 2>/dev/null || true )")"
  if [[ -n "$got" ]]; then printf '  ok    a gatherer that dies still leaves a sendable block\n'
  else printf '  FAIL  a failing gatherer emptied the alert — enrichment must never suppress\n'; fails=1; fi
  missing_gather() { command-that-does-not-exist-anywhere; }
  got="$(context_or_none "$( { missing_gather; } 2>/dev/null || true )")"
  if [[ "$got" == No\ further* ]]; then printf '  ok    a gatherer that cannot run degrades to "no context", not to silence\n'
  else printf '  FAIL  a missing command produced %q instead of the bare-alert block\n' "$got"; fails=1; fi

  r() { local want="$1" desc="$2" got; got="$(recovery_note "$3")"
        if [[ "$got" == "$want"* ]]; then printf '  ok    %s\n' "$desc"
        else printf '  FAIL  %s\n        want %q… got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  # ⚠ DRIVEN IN EVERY DIRECTION, because a note that says the same thing whatever the state is not a
  # fact — it is decoration that the reader will learn to skip.
  r 'It is RUNNING again now'          'a recovered unit says so — the reader may not need to act' active
  r 'It is STILL IN A FAILED STATE'    'a still-failed unit says so'                               failed
  r 'It is idle now'                   'an idle oneshot is not reported as broken'                 inactive
  r 'Its current state could not be read' 'an unreadable state is reported as unreadable, not as fine' ''

  # ⚠ AND THE HANDLER MUST NOT DO ANYTHING EXPENSIVE OR TAKE A LOCK. Stated as a gate rather than as
  # a comment, because the next person to add "just one more fact" is who this is for.
  # ⚠ COMMENTS ARE STRIPPED FIRST, and that is not tidiness. The identical control in
  # install-canary-runner.sh fired against a correct file because the PROSE said the word — an
  # absence-check that reads its own explanation is a check that can only fail.
  #
  # ⚠ AND IT SCANS THE IMPURE HALF ONLY, which is both correct and necessary. Correct, because the
  # self-test never runs on an alert path — it is not the subject. Necessary, because the banned
  # list below is itself code: scanning the whole file made this report all six as present, on a
  # file that calls none of them. That is the same defect twice in one control, so the boundary is
  # the fix rather than more quoting tricks.
  _code="$(sed -n '/^# ── the impure half/,$p' "${BASH_SOURCE[0]}" | /usr/bin/grep -vE '^[[:space:]]*#')"
  [[ -n "${_code//[[:space:]]/}" ]] || { printf '  FAIL  the cheapness scan found no impure half to scan\n'; fails=1; }
  _expensive() { # <haystack> -> prints each banned command it finds
    local hay="${1-}" b
    for b in flock 'git ' 'curl ' 'docker ' 'dotnet ' 'wget '; do
      /usr/bin/grep -qF -- "$b" <<<"$hay" && printf '%s\n' "$b"
    done
    return 0
  }
  _found="$(_expensive "$_code")"
  if [[ -z "${_found//[[:space:]]/}" ]]; then
    printf '  ok    the handler runs nothing expensive and takes no lock\n'
  else
    printf '  FAIL  the handler runs: %s — an OnFailure path must stay cheap and lock-free\n' \
      "$(printf '%s' "$_found" | tr '\n' ' ')"; fails=1
  fi
  # ⚠ AND THE CONTROL, because "found nothing" and "cannot find anything" print the same way.
  if [[ -n "$(_expensive 'x=$(flock -n 9); git fetch')" ]]; then
    printf '  ok    …and that scan can actually detect an expensive call\n'
  else printf '  FAIL  the cheapness scan cannot detect flock or git — it proves nothing\n'; fails=1; fi

  (( fails == 0 )) && { printf 'unit-failure alert: all cases passed\n'; exit 0; }
  printf 'unit-failure alert: FAILURES\n'; exit 1
fi

# ── the impure half ─────────────────────────────────────────────────────────────────────────────
UNIT="${1:-unknown.service}"

# the library resolves the monitoring dir and the ONE state location itself (scripts/lib/ops-alert.sh)
. "$(dirname "${BASH_SOURCE[0]}")/lib/ops-alert.sh" 2>/dev/null || exit 0

# ⚠ `cmd --user || cmd` DOES NOT FALL BACK, AND MEASURING IT WAS THE ONLY WAY TO SEE THAT.
# This read `systemctl --user show … || systemctl show …`, which looks like "try user, else system".
# It is not: `systemctl --user show` EXITS 0 for a unit the user manager has never heard of, and
# prints that manager's own idea of the value. Measured 2026-08-12 against a real system-scope unit:
#
#     systemctl --user show strength-release-claims.service -p Result --value  -> exit 0, "exit-code"
#     systemctl        show strength-release-claims.service -p Result --value  -> "success"
#
# So the `||` never fired and the alert reported exit-code for a unit that had succeeded. Same for
# the journal: `journalctl --user -u <system unit>` also exits 0, with nothing in it, so the alert
# carried an empty log and a wrong verdict — about a FAILURE, which is when it is read most closely.
#
# Sibling of fix_janitor_probe_asks_only_the_user_systemd_manager, found by sweeping for the
# pattern rather than the symptom. Seven units migrated to system scope on 2026-08-03.
#
# LoadState is the discriminator: it is `not-found` in the manager that does not own the unit, and
# it is what "does this manager know this unit?" actually asks.
unit_scope() { # → the scope flag of whichever manager owns $UNIT ('--system' if neither does)
  local s
  for s in --system --user; do
    [[ "$(systemctl "$s" show "$UNIT" -p LoadState --value 2>/dev/null)" != "not-found" ]] \
      && { printf '%s\n' "$s"; return 0; }
  done
  printf -- '--system\n'
}
SCOPE="$(unit_scope)"

# The last few lines of the unit's own log are the whole point — an alert saying only "a unit
# failed" sends the reader to the box to find out what this could have told them.
# journalctl takes --user/--system with the same spelling, so one resolution serves both.
LOG="$(journalctl "$SCOPE" -u "$UNIT" -n 25 --no-pager 2>/dev/null)"
[[ -n "$LOG" ]] || LOG='(no journal available)'
RESULT="$(systemctl "$SCOPE" show "$UNIT" -p Result --value 2>/dev/null)"
[[ -n "$RESULT" ]] || RESULT=unknown

# ── the facts, gathered so they CANNOT take the alert down with them ────────────────────────────
# ⚠ THE WHOLE SUBSHELL IS GUARDED, not each command inside it. A gatherer that dies mid-way, or a
# systemctl that is not on this box at all, must yield an empty string and nothing else — never a
# non-zero exit that skips the send below.
unit_facts() {
  local state sub trigger next
  state="$(systemctl "$SCOPE" show "$UNIT" -p ActiveState --value 2>/dev/null)"
  sub="$(systemctl   "$SCOPE" show "$UNIT" -p SubState    --value 2>/dev/null)"
  # ⚠ THE TRAILING NEWLINE IS EXPLICIT — `$(…)` strips the one recovery_note prints, and the first
  # dry run showed the next fact glued onto the end of this sentence.
  [[ -n "$state" ]] && printf 'Right now: ActiveState=%s SubState=%s. %s\n' "$state" "$sub" "$(recovery_note "$state")"
  trigger="$(systemctl "$SCOPE" show "${UNIT%.service}.timer" -p LastTriggerUSec --value 2>/dev/null)"
  # ⚠ BOTH FIELDS. A monotonic timer (OnBootSec / OnUnitActiveSec) leaves NextElapseUSecRealtime
  # EMPTY and fills the monotonic one; a calendar timer does the reverse. Reading realtime alone
  # silently dropped the "next" clause for every monotonic timer — and three of this repo's timers
  # are monotonic-only, so the alert omitted the fact the reader most wants precisely when it was
  # about the units most likely to be quietly dead.
  # (fix_the_timer_install_check_races_its_own_trigger_and_reports_a_healthy_timer_dead)
  next="$(systemctl    "$SCOPE" show "${UNIT%.service}.timer" -p NextElapseUSecRealtime --value 2>/dev/null)"
  case "$next" in
    ''|infinity|0)
      next="$(systemctl "$SCOPE" show "${UNIT%.service}.timer" -p NextElapseUSecMonotonic --value 2>/dev/null)"
      case "$next" in ''|infinity|0) next="" ;; esac
      ;;
  esac
  [[ -n "$trigger" ]] && printf 'Timer: last fired %s' "$trigger" && { [[ -n "$next" ]] && printf ', next %s' "$next"; printf '\n'; }
}
FACTS="$( { unit_facts; } 2>/dev/null || true )"
FACTS_BLOCK="$(context_or_none "$FACTS")"

# ⚠ A CONDITION KEYED ON THE UNIT: the first failure of an incident emails, every later failure of the same
# unit is coalesced until the sweeper has seen it run clean for 10 minutes. The library returns 0 whatever
# happens, and an undeliverable email leaves the condition unopened, so the next failure tries again.
ops_alert_condition "unit-failed:$UNIT" failing "[${HARNESS_PROJECT:-harness}] systemd unit $UNIT" "$UNIT failed with result: $RESULT

$FACTS_BLOCK

Last 25 journal lines:

$LOG"
[[ "${OPS_ALERT_LAST_UNSENT:-0}" == 1 ]] && printf 'alert for %s could NOT be sent — the condition stays unopened, so the next failure retries\n' "$UNIT" >&2

exit 0
