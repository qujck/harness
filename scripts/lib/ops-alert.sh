# shellcheck shell=bash
# ── ops_alert — one ops-email path for every local watcher ───────────────────────────────────
#
# Lifted verbatim out of check-backup-freshness.sh (infra_batcher_stall_alerts) when a SECOND
# caller appeared. Two copies of a Resend call is how one of them quietly stops working: the
# copy nobody is looking at keeps the old From domain, the old key name, or the old circular
# route, and nothing tells you until the alert you needed does not arrive.
#
# ⚠ THE ALERT MUST NOT TRAVEL THROUGH THE THING IT IS REPORTING ON.
# This path used to POST to api.iron-forge.app/ops/alert — served BY the production droplet —
# so the one outage that mattered most was the one outage that could not be reported. It calls
# Resend directly for that reason, and nothing here may reintroduce a hop through our own
# infrastructure. (infra_alerting_that_works_when_our_infrastructure_does_not)
#
# ⚠ RESEND_ALERT_KEY IS A SEPARATE, SEND-ONLY KEY — NOT the product's Resend:ApiKey.
# Owner decision 2026-08-01: it may live on both machines on condition that revoking it can
# never cost a member their password-reset email. Reusing the product key is the thing that
# decision explicitly rules out.
#
# MONITORING_STATE is the machine-global state dir holding monitoring/.env (NOT a person's checkout —
# the service account cannot read a 0750 home). ⚠ THE LIBRARY RESOLVES IT ITSELF WHEN THE CALLER DID
# NOT. This header used to say "callers must have sourced platform-paths.sh", and four did not
# (pr-refresh, capacity-import-tick, ci-runner-supervisor, release-executor): from #9514 at
# 2026-09-28T22:02:40Z every alert pr-refresh raised printed "no RESEND_ALERT_KEY (looked in
# <unset>/.env)" and SENT NOTHING — 272 times by the next morning — while the owner's rule is one
# email on failure and one on recovery. A precondition every caller must remember is a precondition
# the fourth caller forgets; the library that needs the path now finds it.
# (fix_every_condition_alert_from_pr_refresh_is_unsent_because_the_library_reads_the_key_from_an_unset_monitoring_state)
# Config comes from harness.env (scripts/lib/harness-env.sh): ALERT_TRANSPORT=resend|post|none,
# ALERT_TO, ALERT_FROM, ALERT_POST_URL; the Resend key is a SECRET read from the monitoring
# directory's .env (never from the repo): MONITORING_STATE, or ${PLATFORM_VAR}/monitoring, or
# ~/.local/state/<project>/monitoring. ⚠ No project name or address is hard-coded here: the
# template's own keys are the examples in harness.env.example.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/harness-env.sh" 2>/dev/null || true
_ops_alert_monitoring_dir() {
  if [[ -n "${MONITORING_STATE:-}" ]]; then printf '%s' "$MONITORING_STATE"; return 0; fi
  if [[ -n "${PLATFORM_VAR:-}" ]]; then printf '%s/monitoring' "$PLATFORM_VAR"; return 0; fi
  printf '%s/.local/state/%s/monitoring' "$HOME" "${HARNESS_PROJECT:-harness}"
}

# Read ONE key out of monitoring/.env rather than sourcing the file.
#
# ⚠ NEVER `. monitoring/.env`. It is a docker --env-file, and that format is not shell:
# BESZEL_AGENT_KEY holds an unquoted ssh public key, so sourcing parses `ssh-ed25519 AAAA…`
# as a command and the caller dies with exit 127 before it checks anything at all. Docker
# tolerates the format; bash does not. (Measured.)
ops_alert_env_val() { # <key>
  local v
  v="$(sed -nE "s/^$1=//p" "$(_ops_alert_monitoring_dir)/.env" 2>/dev/null)"; v="${v%%$'\n'*}"   # first match, no early-exit pipe
  v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
  printf '%s' "$v"
}

# ── ⚠ AND THERE IS NO WAY TO EXERCISE AN ALERT PATH WITHOUT EMAILING THE OWNER ──────────────────
#
# Added 2026-08-14, from a mistake made while fixing the alert text itself
# (infra_an_alert_asks_a_human_for_facts_it_already_has). Driving ops-alert-unit-failure.sh end to
# end on this box sent the owner TWO real "strength-pr-refresh.service FAILED" emails about a unit
# that had not failed. The test was written expecting the send to be refused for want of a key —
# the box has one.
#
# **An alerting path that cannot be tested without paging a human will be tested anyway**, and the
# cost lands on the person the channel exists to protect. So there is a dry run.
#
# ⚠ A DRY-RUN SWITCH ON AN ALERT PATH IS ITSELF A SILENCE MECHANISM, and it is bounded accordingly:
# it is honoured ONLY for the exact value `1`, it announces itself loudly on stderr with the full
# body, it returns 0 (a caller must not treat a dry run as a failed send and climb its ladder), and
# check-alert-wiring.sh asserts no unit, timer or env file on the box sets it. If it is ever found
# set outside a person's shell, that is an outage.
# ── ⚠ THE DURABLE QUEUE — WRITE IT DOWN, LET THE READER COME TO IT ──────────────────────────────
# (infra_nothing_watches_the_stuck_count_so_work_can_stop_for_hours)
#
# ⚠ WHY THIS IS A PULL AND NOT A PUSH, WHICH IS THE WHOLE DESIGN. There is no transport on this box
# that can confirm an alert reached a running agent. `tmux send-keys` returns 0 when TMUX ACCEPTED
# THE KEYSTROKES — that is fix_the_pager_types_into_a_pane_and_calls_it_delivered, still open — and
# the session socket at ~/.claude/sessions/<pid>.json's messagingSocketPath accepts a write and
# returns no ack and no error. Either would let a wrapper record "delivered" having delivered
# nothing, in the one channel that exists to break every other silence.
#
# **A pull claims nothing, so it cannot lie.** Its failure mode is "nobody has looked yet", which is
# honest, visible, and carries a timestamp.
#
# ⚠ AND THE REASON A FUTURE READER WILL "FIX" THIS IN AN AFTERNOON: cross-session messages between
# agents plainly DO arrive, all day, every day. So the socket reads as a solved problem from inside
# a conversation that is working. It is solved for the harness's own client, which frames and acks;
# it is not solved for a shell script — and the difference is invisible from where the reader sits,
# because every message they have ever sent arrived. **That is corroboration by an adjacent true
# fact**, the same mechanism that made three half-true reports credible on 2026-08-17. Before
# replacing this with a push, drive a send from a SHELL and prove the receiving agent acted on it.
#
# ⚠ THIS IS THE DURABLE RECORD, NOT THE TIMELINESS. A pull is only as timely as the puller, and a
# reader who runs when a human talks to them does not shorten an overnight freeze. What makes a
# reader exist at 02:00 is strength-agent-nudge. Neither half is sufficient alone, and describing
# this one as a solution to overnight would be the third costume of the same defect.

# ops_spool <class> <subject> <body> — append one alert to the durable queue. Never fails a caller:
# an alert path that dies because it could not journal is worse than one that only journals.
#
# ⚠ APPEND-ONLY, AND `seq` IS THE LINE'S POSITION. That is what lets the reader mark what it has
# ACTED on without deleting anything — a delete-on-read loses the alert if the reader dies between
# reading and acting, which is this repo's defect wearing yet another costume. Anything that rotates
# this file must not renumber it.
ops_spool() { # <class> <subject> <body>
  local file dir seq
  # the queue lives BESIDE the condition state (one location, resolved by the library): OPS_ALERTS_LOG overrides
  file="${OPS_ALERTS_LOG:-$(ops_alert_state_dir)/ops-alerts.jsonl}"
  [[ -n "$file" ]] || return 0
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || return 0
  # ⚠ THE EXISTENCE TEST IS NOT REDUNDANT. `wc -l < missing 2>/dev/null` suppresses WC's stderr,
  # not the SHELL's — the redirection fails first, so the very first alert ever written printed a
  # "No such file or directory" beside itself. Driven, then fixed.
  if [[ -e "$file" ]]; then seq=$(( $(wc -l < "$file") + 1 )); else seq=1; fi
  python3 -c '
import json, sys
seq, cls, subject, body, host, ts = sys.argv[1:7]
print(json.dumps({"seq": int(seq), "ts": ts, "class": cls, "subject": subject,
                  "body": body, "host": host}, ensure_ascii=False))
' "$seq" "${1:-unclassified}" "${2:-}" "${3:-}" "${WITNESS_HOST:-$(hostname)}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$file" 2>/dev/null || return 0
  return 0
}

# ⚠ THE CONDITION VERBS BELOW CALL THIS BY ITS OWN NAME, NOT `ops_alert`, because a caller may shadow
# `ops_alert` with a different transport (pr-refresh.sh does, and posts to our own API). A settle step
# running inside such a caller must still announce every other watcher's recovery the way that
# watcher's failure was announced. `ops_alert` stays as the name existing callers use.
ops_alert_resend() { # <subject> <body>
  local key to host
  if [[ "${OPS_ALERT_DRY_RUN:-}" == 1 ]]; then
    printf 'ops-alert DRY RUN — nothing sent. Subject: %s\n--- body ---\n%s\n--- end body ---\n' \
      "$1" "$2" >&2
    return 0
  fi
  host="${WITNESS_HOST:-$(hostname)}"
  local transport="${ALERT_TRANSPORT:-resend}"
  case "$transport" in
    none) echo "ops-alert: ALERT_TRANSPORT=none — recorded, not sent: $1" >&2; return 0 ;;
    post)
      [[ -n "${ALERT_POST_URL:-}" ]] || { echo "WARNING: ALERT_TRANSPORT=post but ALERT_POST_URL is unset — cannot send: $1" >&2; return 1; }
      local pp; pp="$(python3 -c 'import json,sys; print(json.dumps({"subject": sys.argv[1], "body": sys.argv[2], "host": sys.argv[3]}))' "$1" "$2" "$host")"
      if curl -fsS -X POST "$ALERT_POST_URL" -H 'Content-Type: application/json' ${ALERT_POST_TOKEN:+-H "Authorization: Bearer $ALERT_POST_TOKEN"} -d "$pp" >/dev/null 2>&1; then
        echo "ops-alert sent (post): $1" >&2; return 0
      fi
      echo "WARNING: ops-alert POST to $ALERT_POST_URL failed — not sent: $1" >&2; return 1 ;;
    resend) ;;
    *) echo "WARNING: ALERT_TRANSPORT='$transport' is not resend|post|none — cannot send: $1" >&2; return 1 ;;
  esac
  key="${RESEND_ALERT_KEY:-$(ops_alert_env_val RESEND_ALERT_KEY)}"
  to="${ALERT_TO:-$(ops_alert_env_val ALERT_TO)}"
  local from="${ALERT_FROM:-${HARNESS_PROJECT:-harness} alerts <alerts@${HARNESS_PROJECT:-harness}.local>}"
  if [[ -z "$key" ]]; then
    echo "WARNING: no RESEND_ALERT_KEY (looked in $(_ops_alert_monitoring_dir || true)/.env) — cannot send: $1" >&2
    return 1
  fi
  if [[ -z "$to" ]]; then
    echo "WARNING: no ALERT_TO (harness.env or $(_ops_alert_monitoring_dir || true)/.env) — cannot send: $1" >&2
    return 1
  fi
  local payload
  payload="$(python3 -c '
import json, sys
subject, body, to, host, frm = sys.argv[1:6]
print(json.dumps({
    "from": frm,
    "to": [to],
    "subject": subject,
    "text": body + "\n\nsent by " + host + " direct to the alert transport",
}))' "$1" "$2" "$to" "$host" "$from")"
  if curl -fsS -X POST "https://api.resend.com/emails" \
       -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
       --data "$payload" >/dev/null 2>&1; then
    echo "ops-alert sent: $1"
  else
    echo "WARNING: ops-alert POST failed: $1" >&2
    return 1
  fi
}

ops_alert() { ops_alert_resend "$@"; } # <subject> <body>

# ── ⚠⚠ AN ALERT IS A CONDITION, NOT AN EVENT: ONE EMAIL WHEN IT STARTS FAILING, ONE WHEN IT IS FIXED ──
# (infra_an_ops_alert_is_a_condition_that_emails_once_when_it_starts_failing_and_once_when_it_recovers)
#
# Owner, 2026-09-28: "one when it fails, and one, however much later, when it's fixed — not every
# fail." The skipped-verify alarm had sent 79 identical emails in four hours, because every sender
# was level-triggered: it re-sent on every tick for as long as the thing stayed broken.
#
#   ops_alert_condition <key> failing|recovered <subject> <body>
#   ops_alert_settle_due          # a scheduled step: announces recoveries that have settled
#   ops_alert_event <subject> <body>   # a genuine one-shot (a release went live): one email per call
#
# THE KEY IS THE CONDITION (`main-red`, `unit-failed:<unit>`), NEVER THE INSTANCE, so a second PR
# entering the same condition is the same key and sends nothing.
#
# ⚠ PO RULING (Carl, 2026-09-28): SETTLED RECOVERY. [FAILING] at once; [RECOVERED] only once the key
# has stayed recovered for 10 minutes; a re-fail inside that window cancels it silently; more than 4
# changes in 60 minutes sends one [FLAPPING] and then nothing until it has been stable for an HOUR (the flap window, not the 10-minute settle). The machine itself is
# scripts/lib/ops_alert_machine.py, and the SAME machine is the /api/ops/alert backstop — both run
# scripts/testdata/ops-alert-conditions.json.
#
# ⚠ THE SETTLE DOES NOT WAIT FOR THE SAME CALLER TO COME BACK. `ops_alert_settle_due` runs as a step on
# pr-refresh's 3-minute tick (Rowan's rule: "do X after N minutes" is a step on an existing tick, never
# a transient timer), so the effective settle is 10–13 minutes. It is file-backed, so it survives a
# reboot, and it runs from the platform checkout like every other user-scope unit.
#
# ⚠ The transport is unchanged: `ops_alert` above, direct to Resend, never through our own API.

OPS_ALERT_MACHINE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ops_alert_machine.py"

# ⚠⚠ ONE STATE DIRECTORY FOR EVERY SCOPE, OR A RECOVERY WAITS A DAY. Seven of the watchers run in SYSTEM
# scope as `ironforge` (backup-freshness, auto-deploy-test, release-claims, …) and the rest as the user.
# A per-$HOME store would split them: a system unit's pending recovery would sit in ironforge's home,
# where pr-refresh's settle step — the user's — never looks, so a daily backup check's [RECOVERED]
# would wait for the NEXT daily run. So the store is machine-global: $PLATFORM_VAR/ops-alert-conditions,
# setgid and group-writable (the user is in the ironforge group), created by whichever process can
# first — ironforge owns $PLATFORM_VAR, so the first system-scope run does. Until it exists, the user's
# own home is used; that is the only transitional split, and it closes on the first system-scope run.
# (infra_every_ops_alert_sender_moves_to_the_condition_contract_with_a_recovery_for_each)
# ⚠ ONE STATE LOCATION, AND THE LIBRARY RESOLVES IT. The seeded project had two senders writing one
# key from two state dirs (a system-scope unit under $PLATFORM_VAR, a user-scope one under $HOME):
# each saw a fresh condition, so the flap guard never tripped and the owner got a steady stream of
# FAILING/RECOVERED mail. Here the location is OPS_ALERT_STATE_DIR (explicit), else
# ${ALERT_STATE_DIR} from harness.env, else ${PLATFORM_VAR}/ops-alert-conditions, else
# ~/.local/state/<project>/alerts — resolved ONCE, in this order, with NO second fallback: a dir that
# cannot be created is a refusal (exit 2, loud), never a silent switch to another location.
ops_alert_state_dir() {
  local m
  if [[ -n "${OPS_ALERT_STATE_DIR:-}" ]]; then m="$OPS_ALERT_STATE_DIR"
  elif [[ -n "${ALERT_STATE_DIR:-}" ]]; then m="$ALERT_STATE_DIR"
  elif [[ -n "${PLATFORM_VAR:-}" ]]; then m="$PLATFORM_VAR/ops-alert-conditions"
  else m="$HOME/.local/state/${HARNESS_PROJECT:-harness}/alerts"; fi
  if { [[ -d "$m" && -w "$m" ]] || mkdir -p -m 2775 "$m" 2>/dev/null; }; then printf '%s' "$m"; return 0; fi
  echo "ops-alert: REFUSING TO RUN — the condition state dir '$m' cannot be created or written; a sender with no state cannot keep the flap guard" >&2
  exit 2
}

# ⚠ OPS_ALERT_NOW exists for the self-test's clock. Like the dry run it is honoured only when it is a
# plain integer, and check-alert-wiring.sh's rule for the dry run applies to it too: no unit sets it.
ops_alert_now() { [[ "${OPS_ALERT_NOW:-}" =~ ^[0-9]+$ ]] && printf '%s' "$OPS_ALERT_NOW" || date +%s; }

# Send each email the machine printed ({"key","kind","subject","body"}, one per line), then COMMIT that
# key's new state — or DISCARD it if any send for the key failed, so the next reading or tick retries.
# ⚠ RETURNS 0 ALWAYS, AND SAYS WHETHER ANYTHING WENT UNSENT IN OPS_ALERT_LAST_UNSENT (1 = an email this call
# owed was NOT delivered). A non-zero return would kill any caller running under `set -e` — pr-refresh
# does — on the day the alert key goes missing, which is the day the alert matters. A caller that must
# escalate an undeliverable alert (auto-deploy-test fails its unit so OnFailure reports it) reads the
# variable instead. (infra_every_ops_alert_sender_moves_to_the_condition_contract_with_a_recovery_for_each)
_ops_alert_send_lines() {
  local line key subject body failed=" " k
  local -a keys=()
  OPS_ALERT_LAST_UNSENT=0
  while IFS= read -r -u 3 line; do
    [[ -n "$line" ]] || continue
    key="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["key"])' "$line")"
    subject="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["subject"])' "$line")"
    body="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["body"])' "$line")"
    [[ " ${keys[*]} " == *" $key "* ]] || keys+=("$key")
    ops_alert_resend "$subject" "$body" || failed="$failed$key "
  done 3<<<"$1"
  for k in "${keys[@]}"; do
    if [[ "$failed" == *" $k "* ]]; then
      OPS_ALERT_LAST_UNSENT=1
      echo "WARNING: ops-alert: the email for '$k' was not sent — its state is NOT advanced, so the next reading retries" >&2
      python3 "$OPS_ALERT_MACHINE" discard "$(ops_alert_state_dir)" "$k" || true
    else
      python3 "$OPS_ALERT_MACHINE" commit "$(ops_alert_state_dir)" "$k" || true
    fi
  done
}

ops_alert_condition() { # <key> failing|recovered <subject> <body>
  local key="${1:-}" op="${2:-}" out
  OPS_ALERT_LAST_UNSENT=0
  if [[ ! "$key" =~ ^[a-z0-9][a-z0-9:._@/-]{0,119}$ ]]; then
    echo "WARNING: ops_alert_condition: bad key '${key}' — a condition key is lowercase [a-z0-9:._@/-], at most 120 chars; sending as an EVENT instead so nothing is lost" >&2
    ops_alert_resend "${3:-}" "${4:-}"; return
  fi
  case "$op" in failing|recovered) ;; *)
    echo "WARNING: ops_alert_condition: state must be failing|recovered, got '$op'" >&2; return 1 ;;
  esac
  out="$(python3 "$OPS_ALERT_MACHINE" step "$(ops_alert_state_dir)" "$key" "$op" "$(ops_alert_now)" "${3:-}" "${4:-}")" \
    || { echo "WARNING: ops_alert_condition: the state machine failed for '$key' — sending as an EVENT so the alert is not lost" >&2
         [[ "$op" == failing ]] && ops_alert_resend "[FAILING] $key — ${3:-}" "${4:-}"; return 0; }
  _ops_alert_send_lines "$out"
}

ops_alert_settle_due() {
  local out
  out="$(python3 "$OPS_ALERT_MACHINE" settle-due "$(ops_alert_state_dir)" "$(ops_alert_now)")" || return 0
  _ops_alert_send_lines "$out"
}

ops_alert_event() { ops_alert_resend "${1:-}" "${2:-}"; } # <subject> <body>

# ops_alert_open_keys <prefix> — the condition keys starting with <prefix> whose latest reading is failing.
# For a sweeper that must decide which open conditions have recovered (systemd has no OnSuccess).
ops_alert_open_keys() { python3 "$OPS_ALERT_MACHINE" open "$(ops_alert_state_dir)" "${1:-}" 2>/dev/null || true; }

# ── --self-test: run as a script, never when sourced ────────────────────────────────────────────
# ⚠ THE SHARED FLAG CONTRACT, AND GUARDED ON BEING EXECUTED: every watcher sources this file with its OWN
# argv, so `$1` here may be the caller's argument. (chore_unify_selftest_flag_spelling)
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/selftest-flag.sh"
if [[ "${BASH_SOURCE[0]}" == "$0" ]] && selftest_is_flag "${1-}"; then
  _root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  _fails=0
  printf '==> the machine against the shared vectors\n'
  python3 "$OPS_ALERT_MACHINE" --self-test "$_root/scripts/testdata/ops-alert-conditions.json" || _fails=1

  # ⚠ EACH CALL IS A SEPARATE PROCESS, because the watchers are: a state that lived only in memory
  # would pass every arm below run in one shell and fail on the box. The dry run is the transport, so
  # nothing reaches the owner, and each "sent" is counted from its announcement on stderr.
  _t="$(mktemp -d)"; trap 'rm -rf "$_t"' EXIT
  _call() { # <now> <fn> <args...> -> the number of emails that call sent
    local now="$1"; shift
    OPS_ALERT_DRY_RUN=1 OPS_ALERT_STATE_DIR="$_t/state" OPS_ALERT_NOW="$now" \
      bash -c '. "$1"; shift; "$@"' _ "${BASH_SOURCE[0]}" "$@" 2>&1 >/dev/null | grep -c '^ops-alert DRY RUN' || true
  }
  _check() { # <want> <got> <desc>
    if [[ "$1" == "$2" ]]; then printf '  ok   %s\n' "$3"; else printf '  FAIL %s — want %s, got %s\n' "$3" "$1" "$2"; _fails=1; fi
  }
  printf '==> through the library, one process per call, file-backed\n'
  _n=0; for i in $(seq 1 100); do _n=$(( _n + $(_call $(( 1000 + i )) ops_alert_condition main-red failing 'main is red' "tick $i") )); done
  _check 1 "$_n" '100 failing calls on one key, in 100 processes, send exactly one email'
  _check 0 "$(_call 2000 ops_alert_condition main-red recovered 'main is red' ok)" 'a recovered reading sends nothing at once (it has not settled)'
  _check 0 "$(_call 2540 ops_alert_settle_due)" '…nor 9 minutes later'
  _check 1 "$(_call 2600 ops_alert_settle_due)" '…and exactly one once it has held 10 minutes, from the settle step alone'
  _body="$(OPS_ALERT_DRY_RUN=1 OPS_ALERT_STATE_DIR="$_t/state2" OPS_ALERT_NOW=100 bash -c '. "$1"; ops_alert_condition k failing s b' _ "${BASH_SOURCE[0]}" 2>&1 >/dev/null
           OPS_ALERT_DRY_RUN=1 OPS_ALERT_STATE_DIR="$_t/state2" OPS_ALERT_NOW=700 bash -c '. "$1"; ops_alert_condition k recovered s b' _ "${BASH_SOURCE[0]}" 2>&1 >/dev/null
           OPS_ALERT_DRY_RUN=1 OPS_ALERT_STATE_DIR="$_t/state2" OPS_ALERT_NOW=1300 bash -c '. "$1"; ops_alert_settle_due' _ "${BASH_SOURCE[0]}" 2>&1 >/dev/null)"
  if grep -q 'Subject: \[RECOVERED\] k' <<<"$_body" && grep -q 'held 10 min, after failing for 10m' <<<"$_body"; then
    printf '  ok   the [RECOVERED] email states when it recovered, the 10-minute hold and how long it was failing\n'
  else printf '  FAIL the [RECOVERED] email does not state the hold and the failing duration:\n%s\n' "$_body"; _fails=1; fi
  _sh="$(OPS_ALERT_DRY_RUN=1 OPS_ALERT_STATE_DIR="$_t/state3" OPS_ALERT_NOW=100 \
          bash -c '. "$1"; ops_alert() { echo "SHADOWED-TRANSPORT" >&2; }; ops_alert_condition shadow-key failing s b' _ "${BASH_SOURCE[0]}" 2>&1 >/dev/null)"
  if grep -q '^ops-alert DRY RUN' <<<"$_sh" && ! grep -q SHADOWED-TRANSPORT <<<"$_sh"; then
    printf '  ok   a caller that shadows ops_alert (as pr-refresh does) cannot reroute a condition email\n'
  else printf '  FAIL a shadowed ops_alert rerouted the condition email: %s\n' "$_sh"; _fails=1; fi
  _f1="$(OPS_ALERT_STATE_DIR="$_t/state4" OPS_ALERT_NOW=100 RESEND_ALERT_KEY= MONITORING_STATE="$_t/nomon" \
          bash -c '. "$1"; ops_alert_condition send-fails failing s b' _ "${BASH_SOURCE[0]}" 2>&1)"
  _f2="$(OPS_ALERT_DRY_RUN=1 OPS_ALERT_STATE_DIR="$_t/state4" OPS_ALERT_NOW=200 \
          bash -c '. "$1"; ops_alert_condition send-fails failing s b' _ "${BASH_SOURCE[0]}" 2>&1 >/dev/null | grep -c '^ops-alert DRY RUN' || true)"
  if grep -q 'NOT advanced' <<<"$_f1" && [[ "$_f2" == 1 ]]; then
    printf '  ok   a send that fails does not advance the state: the next reading sends the [FAILING] it never delivered\n'
  else printf '  FAIL a failed send advanced the state (retry sent %s; first call said: %s)\n' "$_f2" "$(tail -2 <<<"$_f1")"; _fails=1; fi
  _u="$(OPS_ALERT_STATE_DIR="$_t/state5" OPS_ALERT_NOW=100 RESEND_ALERT_KEY= MONITORING_STATE="$_t/nomon" \
        bash -c 'set -e; . "$1"; ops_alert_condition unsent-key failing s b 2>/dev/null; echo "rc=$? unsent=$OPS_ALERT_LAST_UNSENT"' _ "${BASH_SOURCE[0]}")"
  _d="$(OPS_ALERT_DRY_RUN=1 OPS_ALERT_STATE_DIR="$_t/state6" OPS_ALERT_NOW=100 \
        bash -c 'set -e; . "$1"; ops_alert_condition sent-key failing s b 2>/dev/null; echo "rc=$? unsent=$OPS_ALERT_LAST_UNSENT"' _ "${BASH_SOURCE[0]}")"
  if [[ "$_u" == 'rc=0 unsent=1' && "$_d" == 'rc=0 unsent=0' ]]; then
    printf '  ok   an undeliverable email returns 0 under set -e (a watcher survives) and says so in OPS_ALERT_LAST_UNSENT; a delivered one reads 0\n'
  else printf '  FAIL undeliverable: %q, delivered: %q (want rc=0 unsent=1 / rc=0 unsent=0)\n' "$_u" "$_d"; _fails=1; fi
  _perm="$(stat -c '%a' "$_t/state/main-red" 2>/dev/null)"
  if [[ "$_perm" == 664 ]]; then printf '  ok   a state file is group-readable and -writable (the store is shared with the ironforge service account)\n'
  else printf '  FAIL a state file is mode %s, want 664 — the other account would read it as "no state"\n' "${_perm:-missing}"; _fails=1; fi
  _check 0 "$(_call 3000 ops_alert_condition never-failed recovered s b)" 'a recovered reading with no prior failure sends nothing'
  _check 1 "$(_call 3000 ops_alert_condition other-key failing s b)" 'a different key is independent: its first failure emails'
  _check 1 "$(_call 3100 ops_alert_event 'release v1 is live' b)" 'NEGATIVE CONTROL: the event verb sends one email per call…'
  _check 1 "$(_call 3100 ops_alert_event 'release v1 is live' b)" '…every call, with no state and no coalescing'
  _check 1 "$(_call 3200 ops_alert_condition 'NOT A KEY' failing s b)" 'a malformed key is sent as an event, never dropped'
  # ⚠ THE KEY IS FOUND WITH MONITORING_STATE UNSET — the shape of pr-refresh's unit, which sent nothing
  # for a night because this library required the caller to set it. A fixture machine dir, never the box.
  # (fix_every_condition_alert_from_pr_refresh_is_unsent_because_the_library_reads_the_key_from_an_unset_monitoring_state)
  mkdir -p "$_t/pvar/monitoring"; printf 'RESEND_ALERT_KEY=fixture-key\n' > "$_t/pvar/monitoring/.env"
  _k="$(env -u MONITORING_STATE PLATFORM_VAR="$_t/pvar" bash -c '. "$1"; ops_alert_env_val RESEND_ALERT_KEY' _ "${BASH_SOURCE[0]}")"
  _check fixture-key "$_k" 'with MONITORING_STATE UNSET the library resolves the machine dir itself and reads the key'
  _k="$(env -u MONITORING_STATE bash -c 'sed -nE "s/^RESEND_ALERT_KEY=//p" "${MONITORING_STATE:-}/.env" 2>/dev/null')"
  _check "" "$_k" 'NEGATIVE CONTROL: the expression this replaced reads "/.env" and finds nothing'
  _k="$(MONITORING_STATE="$_t/nope" PLATFORM_VAR="$_t/pvar" bash -c '. "$1"; ops_alert_env_val RESEND_ALERT_KEY' _ "${BASH_SOURCE[0]}")"
  _check "" "$_k" 'an explicit MONITORING_STATE still wins over the resolved one (it names where to look)'
  # ── the template's two guarantees (child 6) ──
  _rc="$(OPS_ALERT_STATE_DIR=/proc/none/cannot-exist bash -c '. "$1"; ops_alert_state_dir' _ "${BASH_SOURCE[0]}" >/dev/null 2>&1; echo $?)"
  _check 2 "$_rc" 'a sender whose state location cannot be created REFUSES (exit 2) — it never falls back to a second location'
  _d2="$_t/two-senders"; mkdir -p "$_d2"
  OPS_ALERT_STATE_DIR="$_d2" OPS_ALERT_NOW=100 OPS_ALERT_DRY_RUN=1 ops_alert_condition two-senders failing s b >/dev/null 2>&1
  _o2="$(OPS_ALERT_STATE_DIR="$_d2" OPS_ALERT_NOW=160 OPS_ALERT_DRY_RUN=1 bash -c '. "$1"; ops_alert_condition two-senders failing s b' _ "${BASH_SOURCE[0]}" 2>&1 | grep -c 'FAILING' || true)"
  _check 0 "$_o2" 'a SECOND sender process on the same state dir sees the open condition and sends nothing (one [FAILING], not two)'

  (( _fails == 0 )) && { echo "ops-alert: self-test ok"; exit 0; }
  echo "ops-alert: self-test FAILED" >&2; exit 1
fi
