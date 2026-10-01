#!/usr/bin/env bash
# remedy-none: a red names the surface or the stage that was not reported; the change is to verify.sh,
# ci.yml or full-suite-gate.sh, wherever the report stopped being written or read.
#
# scripts/verify-stages.sh — which of verify's stages RAN, and which never started because an earlier one
# stopped the run. (infra_the_verify_stage_chain_hides_the_whole_browser_suite_behind_any_earlier_red)
#
#   . scripts/verify-stages.sh                       # verify.sh: vs_init / vs_begin / vs_skip / vs_finish
#   bash scripts/verify-stages.sh --lines <report>     # one human line per stage
#   bash scripts/verify-stages.sh --markdown <report>  # the same, for a job summary
#   bash scripts/verify-stages.sh --self-test          # pure arms + a REAL verify with a planted early red
#
# ── WHY ─────────────────────────────────────────────────────────────────────────────────────────
# verify.sh is a chain that STOPS at its first red: static checks, unit tests, API e2e, then Playwright.
# Measured over 768 scheduled runs (2026-08-29 → 09-28): 60 of the 214 red hourly full suites never
# started Playwright, and a single API e2e tracer red hid the WHOLE browser suite for 35 runs over six
# days. "Red" was read as "the browser suite was measured" when none of it had run. The owner ruled
# (2026-09-28, option (b)): keep the stop, but the job summary, the alert and the full-suite gate each
# NAME every stage that never started — "Playwright: NOT RUN — stopped at API e2e".
#
# ⚠ SKIPPED IS NOT NOT-RUN. A stage the run was CONFIGURED to leave out (SKIP_UI=1, the fast lane, a
# docs-only diff) is `skipped`, with its reason; only a stage that was due and never started because
# something before it stopped the run is `not-run`. Conflating them would put a warning on every
# fast-lane PR, which is how a warning stops being read.
#
# ⚠ THE REPORT IS WRITTEN AS THE RUN GOES, NOT ONLY AT EXIT. A run killed at its timeout never reaches
# the EXIT trap; its report then still says which stage was RUNNING, and the renderer says so.

VS_STAGES=(static unit api-e2e playwright)
vs_label() { # <stage> -> the name a reader sees
  case "${1-}" in
    static) printf 'static checks' ;; unit) printf 'unit tests' ;;
    api-e2e) printf 'API e2e' ;; playwright) printf 'Playwright' ;; *) printf '%s' "${1-}" ;;
  esac
}

# ── recording (verify.sh) ──────────────────────────────────────────────────────────────────────────
# State per stage: pending | running | ran | skipped | stopped. The file holds `<stage>\t<state>\t<detail>`.
declare -gA _VS_STATE=() _VS_DETAIL=()
VS_FILE=""
_vs_write() {
  [[ -n "$VS_FILE" ]] || return 0
  local s
  { for s in "${VS_STAGES[@]}"; do printf '%s\t%s\t%s\n' "$s" "${_VS_STATE[$s]:-pending}" "${_VS_DETAIL[$s]:-}"; done; } \
    > "$VS_FILE" 2>/dev/null || true
}
vs_init() { # <report-file>
  VS_FILE="${1-}"; local s
  for s in "${VS_STAGES[@]}"; do _VS_STATE[$s]=pending; _VS_DETAIL[$s]=""; done
  _vs_write
}
# A stage starts. The one before it, if it was running, has finished cleanly.
vs_begin() { # <stage>
  local s; for s in "${VS_STAGES[@]}"; do [[ "${_VS_STATE[$s]}" == running ]] && _VS_STATE[$s]=ran; done
  _VS_STATE[$1]=running; _vs_write
}
vs_skip() { # <stage> <reason>
  local s; for s in "${VS_STAGES[@]}"; do [[ "${_VS_STATE[$s]}" == running ]] && _VS_STATE[$s]=ran; done
  _VS_STATE[$1]=skipped; _VS_DETAIL[$1]="${2-}"; _vs_write
}
# The run is over. rc 0: whatever was running finished. rc != 0: it STOPPED there, and every stage still
# pending was never started because of it.
vs_finish() { # <rc>
  local rc="${1-0}" s stopper=""
  for s in "${VS_STAGES[@]}"; do
    if [[ "${_VS_STATE[$s]}" == running ]]; then
      if [[ "$rc" == 0 ]]; then _VS_STATE[$s]=ran; else _VS_STATE[$s]=stopped; stopper="$s"; fi
    fi
  done
  if [[ "$rc" != 0 ]]; then
    for s in "${VS_STAGES[@]}"; do
      [[ "${_VS_STATE[$s]}" == pending ]] && { _VS_STATE[$s]=not-run; _VS_DETAIL[$s]="$stopper"; }
    done
  fi
  _vs_write
}

# ── rendering (the job summary, the alert, the full-suite gate) ────────────────────────────────────
# vs_lines <report-file> -> one line per stage. The ONE renderer every surface uses, so the words cannot
# drift apart between them.
vs_lines() {
  local f="${1-}" stage state detail stopper=""
  [[ -s "$f" ]] || { printf 'stages: NO STAGE REPORT — verify.sh never started, or this run predates the report.\n'; return 0; }
  while IFS=$'\t' read -r stage state detail; do [[ "$state" == stopped || "$state" == running ]] && stopper="$stage"; done < "$f"
  while IFS=$'\t' read -r stage state detail; do
    [[ -n "$stage" ]] || continue
    case "$state" in
      ran)     printf '%s: ran\n' "$(vs_label "$stage")" ;;
      skipped) printf '%s: skipped — %s\n' "$(vs_label "$stage")" "${detail:-by configuration}" ;;
      stopped) printf '%s: FAILED — the run stopped here\n' "$(vs_label "$stage")" ;;
      running) printf '%s: STILL RUNNING when the run ended (killed or timed out) — nothing after it ran\n' "$(vs_label "$stage")" ;;
      not-run) printf '%s: NOT RUN — stopped at %s\n' "$(vs_label "$stage")" "$(vs_label "${detail:-$stopper}")" ;;
      pending) if [[ -n "$stopper" ]]; then printf '%s: NOT RUN — stopped at %s\n' "$(vs_label "$stage")" "$(vs_label "$stopper")"
               else printf '%s: not reached\n' "$(vs_label "$stage")"; fi ;;
      *)       printf '%s: %s\n' "$(vs_label "$stage")" "$state" ;;
    esac
  done < "$f"
}
# vs_not_run_count <report-file> -> how many stages never started because of a stop (0 on a full run)
vs_not_run_count() {
  vs_lines "${1-}" | grep -cE ': (NOT RUN|STILL RUNNING)' || true
}
vs_markdown() { # <report-file>
  local n; n="$(vs_not_run_count "${1-}")"
  if [[ "${n:-0}" -gt 0 ]]; then printf '### ⚠ %s stage(s) of verify NEVER RAN — a red here did not measure them\n\n' "$n"
  else printf '### verify stages\n\n'; fi
  vs_lines "${1-}" | sed 's/^/- /'
  printf '\n'
}

# ── CLI + self-test ──────────────────────────────────────────────────────────────────────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -uo pipefail
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
  case "${1-}" in
    --lines)    vs_lines "${2-}"; exit 0 ;;
    --markdown) vs_markdown "${2-}"; exit 0 ;;
  esac
  selftest_is_flag "${1-}" || { printf 'usage: verify-stages.sh --lines <report> | --markdown <report> | --self-test\n' >&2; exit 2; }
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fails=0; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  t() { if eval "$2"; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fails=$((fails+1)); fi; }

  printf '== pure: a stop names every stage after it, a finished run names none ==\n'
  ( vs_init "$tmp/stop"; vs_begin static; vs_begin unit; vs_begin api-e2e; vs_finish 1 )
  t 'a red at API e2e: Playwright is NOT RUN, naming where it stopped' \
    '[[ "$(vs_lines "$tmp/stop")" == *"Playwright: NOT RUN — stopped at API e2e"* ]]'
  t '…and API e2e itself reads FAILED, the stages before it ran' \
    '[[ "$(vs_lines "$tmp/stop")" == *"API e2e: FAILED"* && "$(vs_lines "$tmp/stop")" == *"unit tests: ran"* ]]'
  ( vs_init "$tmp/green"; vs_begin static; vs_begin unit; vs_begin api-e2e; vs_begin playwright; vs_finish 0 )
  t 'NEGATIVE CONTROL: a run that reached the end names NO stage as not run' \
    '[[ "$(vs_not_run_count "$tmp/green")" == 0 && "$(vs_lines "$tmp/green")" != *"NOT RUN"* ]]'
  ( vs_init "$tmp/fast"; vs_begin static; vs_skip unit 'fast lane'; vs_skip api-e2e 'fast lane'; vs_begin playwright; vs_finish 0 )
  t 'a stage SKIPPED by configuration reads skipped, with its reason, not NOT RUN' \
    '[[ "$(vs_lines "$tmp/fast")" == *"unit tests: skipped — fast lane"* && "$(vs_not_run_count "$tmp/fast")" == 0 ]]'
  ( vs_init "$tmp/killed"; vs_begin static; vs_begin unit )
  t 'a run KILLED mid-stage (no EXIT trap) still says what was running and that nothing after it ran' \
    '[[ "$(vs_lines "$tmp/killed")" == *"unit tests: STILL RUNNING"* && "$(vs_lines "$tmp/killed")" == *"Playwright: NOT RUN — stopped at unit tests"* ]]'
  t 'no report at all is said, never read as clean' \
    '[[ "$(vs_lines "$tmp/none")" == *"NO STAGE REPORT"* ]]'
  t 'the job-summary markdown leads with the count of stages that never ran' \
    '[[ "$(vs_markdown "$tmp/stop")" == *"1 stage(s) of verify NEVER RAN"* ]]'

  printf '== ⚠ DRIVEN: a REAL verify.sh, with a planted red in its first stage ==\n'
  # Isolated so it leaves nothing behind: its own RUNNER_TEMP, no trace record, no ingest key. An early
  # red produces no fresh results, so verify's dashboard post has nothing to send either.
  ( cd "$REPO_ROOT" && RUNNER_TEMP="$tmp" HARNESS_OBSERVE=0 TEST_INGEST_KEY= VERIFY_PLANT_RED=static \
      timeout 300 bash scripts/verify.sh ) > "$tmp/verify.log" 2>&1
  planted_rc=$?
  report="$tmp/verify-stages.txt"
  t "the planted run FAILED (rc $planted_rc) at the plant, not somewhere else" \
    '[[ "$planted_rc" != 0 ]] && grep -q "planted red" "$tmp/verify.log"'
  t 'surface 1, the REPORT: "Playwright: NOT RUN — stopped at static checks"' \
    '[[ "$(vs_lines "$report")" == *"Playwright: NOT RUN — stopped at static checks"* ]]'
  t 'the EXIT handler recorded HOW it ended: static checks FAILED, not "still running"' \
    '[[ "$(vs_lines "$report")" == *"static checks: FAILED — the run stopped here"* ]]'
  t '…and unit tests and API e2e are named NOT RUN too' \
    '[[ "$(vs_lines "$report")" == *"unit tests: NOT RUN — stopped at static checks"* && "$(vs_lines "$report")" == *"API e2e: NOT RUN — stopped at static checks"* ]]'
  t 'surface 2, the JOB SUMMARY (--markdown, what ci.yml appends): names it' \
    '[[ "$(bash "$REPO_ROOT/scripts/verify-stages.sh" --markdown "$report")" == *"Playwright: NOT RUN — stopped at static checks"* ]]'
  t 'surface 3, the ALERT (--lines, what the hourly alert body carries): names it' \
    '[[ "$(bash "$REPO_ROOT/scripts/verify-stages.sh" --lines "$report")" == *"Playwright: NOT RUN — stopped at static checks"* ]]'
  t 'surface 4, the FULL-SUITE GATE: its block-message renderer names it from the published report' \
    '[[ "$(bash "$REPO_ROOT/scripts/full-suite-gate.sh" --render-stages "$report")" == *"Playwright: NOT RUN — stopped at static checks"* ]]'
  # ⚠ The surfaces must actually CALL the renderer, or the arms above prove a function nobody uses.
  ci="$REPO_ROOT/.github/workflows/ci.yml"
  t 'ci.yml: the hourly failure path appends the stage report to the job summary' \
    'grep -q "verify-stages.sh --markdown" "$ci"'
  t 'ci.yml: the hourly red alert body carries the stage lines' \
    'grep -q "verify-stages.sh --lines" "$ci"'
  t 'ci.yml: the hourly red publishes the report for the gate (the "verify stages" check-run)' \
    'grep -q "name=verify stages" "$ci"'
  t 'full-suite-gate.sh: the block message prints the stages it read' \
    'grep -q "gate_stage_lines" "$REPO_ROOT/scripts/full-suite-gate.sh"'

  printf '\n'
  (( fails == 0 )) && { echo "verify-stages: self-test ok"; exit 0; }
  echo "verify-stages: self-test FAILED ($fails)" >&2; exit 1
fi
