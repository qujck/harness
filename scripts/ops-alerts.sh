#!/usr/bin/env bash
# scripts/ops-alerts.sh — read the durable queue of operational alerts.
# (infra_nothing_watches_the_stuck_count_so_work_can_stop_for_hours)
#
#   bash scripts/ops-alerts.sh                # alerts you have not acted on yet
#   bash scripts/ops-alerts.sh --all          # everything ever recorded
#   bash scripts/ops-alerts.sh --ack <seq>    # mark everything up to <seq> as ACTED ON
#   bash scripts/ops-alerts.sh --ack-all      # mark everything currently recorded as acted on
#   bash scripts/ops-alerts.sh --self-test
#
# ── ⚠ WHY THERE IS A QUEUE TO READ AT ALL ───────────────────────────────────────────────────────
#
# On 2026-08-18 the merge queue froze at 01:02 and pr-refresh detected it correctly, alerting at
# 01:51:41 with the oldest waiting PR named. Nothing moved until a human acted at 05:15 — three
# hours and twenty-four minutes on a channel that had already worked. The owner's response was to
# switch that class of email off: "if you can't be informed and take action then just leave it."
#
# **He was not rejecting the alert as wrong. He was rejecting it as useless.** The fix is to route
# machine states to something that can act on them, not to detect harder.
#
# ⚠ AND IT IS A PULL BECAUSE NO PUSH ON THIS BOX CAN CONFIRM DELIVERY. `tmux send-keys` returns 0
# when tmux ACCEPTED THE KEYSTROKES — that is fix_the_pager_types_into_a_pane_and_calls_it_delivered,
# still open — and the agent session socket accepts a write and returns no ack and no error. Either
# would let a wrapper record "delivered" having delivered nothing, in the one channel that exists to
# break every other silence. A pull claims nothing, so it cannot lie: its failure mode is "nobody
# has looked yet", which is honest and carries a timestamp.
#
# ⚠ THIS IS THE DURABLE RECORD, NOT THE TIMELINESS, and the distinction is load-bearing. A pull is
# only as timely as the puller. Nothing here shortens an overnight freeze on its own — what makes a
# reader exist at 02:00 is strength-agent-nudge restarting an agent that stopped between turns.
# **Neither half is sufficient alone**, and describing this one as the answer to overnight would be
# the same defect in a third costume.
#
# ⚠ ACK IS NOT DELETE. Reading changes nothing; only --ack does. A queue that cleared on read would
# lose an alert whenever the reader died between reading and acting — the self-sealing shape this
# repo keeps meeting. Nothing in here removes a line, ever.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib/selftest-flag.sh"
. "$REPO_ROOT/scripts/lib/ops-alert.sh"   # the queue lives beside the condition state (one location)

ALERTS_FILE="${OPS_ALERTS_LOG:-$(ops_alert_state_dir 2>/dev/null)/ops-alerts.jsonl}"
ACK_FILE="${OPS_ALERTS_ACK:-${ALERTS_FILE}.acked}"

# ── the pure half ───────────────────────────────────────────────────────────────────────────────

# acked_seq <file-contents> → the highest sequence marked acted-on, 0 when absent or unreadable.
#
# ⚠ AN UNREADABLE MARKER MEANS ZERO, WHICH SHOWS EVERYTHING. The other direction — treating a
# corrupt marker as "all acked" — hides every alert in the queue and looks exactly like an empty
# queue. When the marker cannot be trusted, the safe reading is the noisy one.
acked_seq() {
  local raw="${1:-}"
  raw="${raw//[$'\n\r\t ']/}"
  [[ "$raw" =~ ^[0-9]+$ ]] || { printf '0\n'; return 0; }
  printf '%s\n' "$raw"
}

# unread_lines <acked> — filter JSONL on stdin to alerts after <acked>.
#
# ⚠ A LINE THAT WILL NOT PARSE IS SHOWN, NOT SKIPPED. A corrupt line in an alert queue is itself
# something worth seeing, and silently dropping it is how a queue reports "nothing to do".
unread_lines() {
  local acked="${1:-0}"
  python3 -c '
import json, sys
acked = int(sys.argv[1])
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw.strip():
        continue
    try:
        seq = int(json.loads(raw).get("seq", 0))
    except Exception:
        print(raw)          # unparseable: surface it rather than swallow it
        continue
    if seq > acked:
        print(raw)
' "$acked" 2>/dev/null
}

# render — JSONL on stdin → something a person reads.
render() {
  python3 -c '
import json, sys
n = 0
for raw in sys.stdin:
    raw = raw.rstrip("\n")
    if not raw.strip():
        continue
    n += 1
    try:
        d = json.loads(raw)
    except Exception:
        print("  [%d] UNPARSEABLE: %s" % (n, raw[:200]))
        continue
    print("  [%s] %s  %s" % (d.get("seq", "?"), d.get("ts", "?"), d.get("class", "?")))
    print("      %s" % (d.get("subject", "")))
    for line in (d.get("body") or "").splitlines():
        print("      | %s" % line)
    print()
print("  %d alert(s)." % n)
'
}

# ── self-test ───────────────────────────────────────────────────────────────────────────────────
if selftest_is_flag "${1:-}"; then
  fails=0
  _a() { local want="$1" got; got="$(acked_seq "$2")"
         if [[ "$got" == "$want" ]]; then printf '  ok    acked_seq %-14q -> %s\n' "$2" "$want"
         else printf '  FAIL  acked_seq %q -> %q (wanted %q)\n' "$2" "$got" "$want"; fails=1; fi; }
  _a 7 '7'
  _a 7 $'7\n'
  _a 0 ''
  # ⚠ THE DIRECTION THAT MATTERS: garbage must read as 0 (show everything), never as a high number.
  _a 0 'nonsense'
  _a 0 '-3'
  _a 0 '3.5'

  fx='{"seq":1,"ts":"t","class":"a","subject":"one","body":""}
{"seq":2,"ts":"t","class":"b","subject":"two","body":""}
{"seq":3,"ts":"t","class":"c","subject":"three","body":""}'
  got="$(printf '%s\n' "$fx" | unread_lines 1 | wc -l)"
  [[ "$got" == 2 ]] && printf '  ok    acked=1 leaves 2 unread\n' \
    || { printf '  FAIL  acked=1 -> %q unread (wanted 2)\n' "$got"; fails=1; }
  got="$(printf '%s\n' "$fx" | unread_lines 3 | wc -l)"
  [[ "$got" == 0 ]] && printf '  ok    acked=3 leaves nothing unread\n' \
    || { printf '  FAIL  acked=3 -> %q unread (wanted 0)\n' "$got"; fails=1; }
  got="$(printf '%s\n' "$fx" | unread_lines 0 | wc -l)"
  [[ "$got" == 3 ]] && printf '  ok    acked=0 shows everything\n' \
    || { printf '  FAIL  acked=0 -> %q (wanted 3)\n' "$got"; fails=1; }

  # ⚠ A CORRUPT LINE IS SHOWN. A queue that quietly drops what it cannot parse reports "nothing to
  # do" for the one entry most likely to matter.
  got="$(printf '%s\n' 'not json at all' | unread_lines 99 | wc -l)"
  [[ "$got" == 1 ]] && printf '  ok    an unparseable line survives the filter rather than vanishing\n' \
    || { printf '  FAIL  unparseable line -> %q (wanted 1)\n' "$got"; fails=1; }

  # ⚠ ACK NEVER REMOVES A LINE. Driven against a real file, because that is the property that makes
  # a reader dying mid-act survivable, and it cannot be asserted from the pure half.
  t="$(mktemp -d)"
  printf '%s\n' "$fx" > "$t/alerts.jsonl"
  before="$(wc -l < "$t/alerts.jsonl")"
  OPS_ALERTS_LOG="$t/alerts.jsonl" OPS_ALERTS_ACK="$t/alerts.acked" bash "$REPO_ROOT/scripts/ops-alerts.sh" --ack-all >/dev/null 2>&1
  after="$(wc -l < "$t/alerts.jsonl")"
  if [[ "$before" == "$after" && "$(cat "$t/alerts.acked" 2>/dev/null)" == 3 ]]; then
    printf '  ok    --ack-all marks 3 and removes nothing (%s lines before and after)\n' "$before"
  else
    printf '  FAIL  --ack-all: %s -> %s lines, marker %q\n' "$before" "$after" "$(cat "$t/alerts.acked" 2>/dev/null)"; fails=1
  fi
  rm -rf "$t"

  # ⚠ A CI LOG GETS THE COUNT, NEVER A BODY. The body below quotes a Playwright result line, which is
  # exactly what made a log grep count old reds as new ones.
  t="$(mktemp -d)"
  printf '%s\n' '{"seq":9,"ts":"t","class":"ci","subject":"hourly red","body":"✘ 325 [chromium] › lifecycle-phases-one-to-three.spec.js:22 phases 1-3"}' > "$t/alerts.jsonl"
  ci_out="$(GITHUB_ACTIONS=true OPS_ALERTS_LOG="$t/alerts.jsonl" OPS_ALERTS_ACK="$t/acked" bash "$REPO_ROOT/scripts/ops-alerts.sh" 2>&1)"
  se_out="$(env -u GITHUB_ACTIONS OPS_ALERTS_LOG="$t/alerts.jsonl" OPS_ALERTS_ACK="$t/acked" bash "$REPO_ROOT/scripts/ops-alerts.sh" 2>&1)"
  if [[ "$ci_out" != *lifecycle-phases-one-to-three* && "$ci_out" == *"1 alert(s) not yet acted on"* ]]; then
    printf '  ok    in a CI job log: the count and the pointer, and no alert body (no old result line to grep)\n'
  else printf '  FAIL  in CI the alert body reached the log: %q\n' "${ci_out:0:160}"; fails=1; fi
  if [[ "$se_out" == *lifecycle-phases-one-to-three* ]]; then
    printf '  ok    NEGATIVE CONTROL: at a session start the agent still reads the full body\n'
  else printf '  FAIL  a session no longer shows the alert body: %q\n' "${se_out:0:160}"; fails=1; fi
  rm -rf "$t"

  [[ "$fails" == 0 ]] && printf '  ops-alerts: all cases passed\n'
  exit "$fails"
fi

# ── the impure half ─────────────────────────────────────────────────────────────────────────────
usage() { printf 'usage: %s [--all | --count | --ack <seq> | --ack-all | --self-test]\n' "$(basename -- "$0")" >&2; }

mode=unread; ack_to=""
case "${1:-}" in
  '')        ;;
  --all)     mode=all ;;
  # ⚠ `--count` EXISTS SO A CALLER CAN BE QUIET WHEN THERE IS NOTHING, WITHOUT REIMPLEMENTING THE
  # QUEUE. init.sh prints this queue at session start and must add no noise on the ordinary day —
  # but the obvious way to check first (does the file have more lines than the ack marker?) is a
  # SECOND definition of "unread", in a second file, drifting from `unread_lines` the moment either
  # changes. One reader, one definition; the count comes from the same filter the render uses.
  --count)   mode=count ;;
  --ack-all) mode=ackall ;;
  --ack)     mode=ack; ack_to="${2:-}"
             [[ "$ack_to" =~ ^[0-9]+$ ]] || { printf 'ack needs a sequence number, got: %q\n' "$ack_to" >&2; usage; exit 2; } ;;
  *)         printf 'unknown argument: %s\n' "$1" >&2; usage; exit 2 ;;
esac
if [[ "$mode" != ack && $# -gt 1 ]] || [[ "$mode" == ack && $# -gt 2 ]]; then
  printf 'unexpected extra argument\n' >&2; usage; exit 2
fi

if [[ -z "$ALERTS_FILE" ]]; then
  printf 'no ops-alerts path could be resolved (ops_alert_state_dir)\n' >&2; exit 2
fi
if [[ ! -e "$ALERTS_FILE" ]]; then
  # ⚠ `--count` ANSWERS 0 HERE AND SAYS NOTHING ELSE. Every other mode explains that an absent file
  # means "nothing has been written", NOT "nothing has happened" — that sentence is for a person.
  # A caller asking for a number gets a number, and the distinction it must not lose is already
  # made where it matters: a count of 0 makes init.sh print nothing, which is the same silence as
  # a healthy day and is the honest state either way.
  [[ "$mode" == count ]] && { printf '0\n'; exit 0; }
  printf '  no alerts recorded yet — %s does not exist.\n' "$ALERTS_FILE"
  printf '  That is "nothing has been written", NOT "nothing has happened".\n'
  exit 0
fi

acked="$(acked_seq "$(cat "$ACK_FILE" 2>/dev/null)")"
case "$mode" in
  all)    printf '\n  All recorded alerts (%s), acted-on up to %s:\n\n' "$ALERTS_FILE" "$acked"
          render < "$ALERTS_FILE" ;;
  count)  unread_lines "$acked" < "$ALERTS_FILE" | wc -l | tr -d ' ' ;;
  unread) # ⚠ NOT INTO A CI JOB LOG. init.sh prints this queue, and verify runs init.sh on the CI seat, so every
          # job log carried every unread alert's BODY, and bodies quote old test output. One from ~2026-09-04
          # quoted '✘ 325 [chromium] › lifecycle-phases-one-to-three.spec.js:22', so a log grep for that spec
          # matched EVERY later run, and a tally built that way counted 38 reds that never happened. An alert
          # is for an agent at session start, who can act; a CI log is read by greps, which cannot tell
          # history from this run. So CI gets the count and the pointer.
          # (infra_the_verify_stage_chain_hides_the_whole_browser_suite_behind_any_earlier_red)
          if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
            printf '  %s alert(s) not yet acted on — NOT reprinted into a CI log (their bodies quote old test results,\n' \
              "$(unread_lines "$acked" < "$ALERTS_FILE" | wc -l | tr -d ' ')"
            printf '  which a grep of this log would count as this run'"'"'s). Read them on the box: bash scripts/ops-alerts.sh\n'
          else
            printf '\n  Alerts not yet acted on (%s), marker at %s:\n\n' "$ALERTS_FILE" "$acked"
            unread_lines "$acked" < "$ALERTS_FILE" | render
            printf '  Mark them done with: bash scripts/ops-alerts.sh --ack-all\n'
          fi ;;
  ack|ackall)
          if [[ "$mode" == ackall ]]; then
            ack_to="$(python3 -c '
import json, sys
hi = 0
for raw in sys.stdin:
    try:
        hi = max(hi, int(json.loads(raw).get("seq", 0)))
    except Exception:
        pass
print(hi)' < "$ALERTS_FILE")"
          fi
          printf '%s\n' "$ack_to" > "$ACK_FILE"
          printf '  acted-on marker set to %s. Nothing was deleted — --all still shows everything.\n' "$ack_to" ;;
esac
exit 0
