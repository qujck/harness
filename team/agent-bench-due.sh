#!/usr/bin/env bash
# team/agent-bench-due.sh — bench a finished ticket's developer and tester once the ledger says it is done.
#
#   bash team/agent-bench-due.sh <id>            record who is due, then wait in the background (log: <state>/<id>.log)
#   bash team/agent-bench-due.sh <id> --check    one pass in the foreground: 0 all benched · 2 still waiting · 1 error
#   bash team/agent-bench-due.sh --self-test
#
# The bench step of a ticket's completion. With AGENT_BENCH_ON_MERGE=1, `feature-ticket.sh release <id>` starts it,
# so the developer that released the lock and the tester that signed the ticket off go to the bench without the
# delivery lead doing it by hand; the lead can also run it. Off (the default), nothing calls it.
#
# WHO IS DUE is fixed at the first call: each active developer or tester on the roster whose running tmux session
# (agent-spawn.sh's) carries HARNESS_TICKET=<id>. The list is kept in <state>/<id> (AGENT_BENCH_DUE_DIR, default
# ~/.local/state/<project>/bench-due), so a later pass benches the same people even after their sessions change.
#
# A PASS does nothing until `ledger-db.sh ticket-row <id>` reads archived, wont_do or passing (what
# feature-ticket.sh release accepts), then runs team/agent-bench.sh on each one still due. agent-bench.sh's own checks
# (no claim held, not mid-turn, a clean worktree, a session entry written) decide when each goes, so a pass that
# benches nobody is tried again: an agent finishing its last turn is benched on a later pass. One pass runs at a time
# (<state>/<id>.lock).
#
# THE WAIT polls every AGENT_BENCH_DUE_POLL_S seconds (300) for up to AGENT_BENCH_DUE_HOURS hours (4), then stops
# and logs who is left and the last status the ledger gave. The waiter's pid is in <state>/<id>.pid; a second call
# while it runs starts no other.
#
# Stand-ins for the self-test: LDB (else AGENT_SPAWN_LEDGER, else scripts/ledger-db.sh) and AGENT_BENCH_DUE_BENCH
# (else team/agent-bench.sh).
#
# Exit: 0 all due benched (or a waiter started) · 1 error · 2 still waiting (--check) or a usage error.
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

USAGE="usage: agent-bench-due.sh <id> [--check]"
LDB="${LDB:-${AGENT_SPAWN_LEDGER:-bash $_here/../scripts/ledger-db.sh}}"
BENCH="${AGENT_BENCH_DUE_BENCH:-bash $_here/agent-bench.sh}"
STATE="${AGENT_BENCH_DUE_DIR:-$HOME/.local/state/${HARNESS_PROJECT}/bench-due}"
POLL="${AGENT_BENCH_DUE_POLL_S:-300}"
HOURS="${AGENT_BENCH_DUE_HOURS:-4}"

# PURE: is this a ticket status the ticket is finished at? $1 -> 0 | 1
due_done_status() { case "${1-}" in archived|wont_do|passing) return 0 ;; *) return 1 ;; esac; }

# The active developers and testers whose running session carries HARNESS_TICKET=<id>, one name per line.
due_holders() { # <id>
  local n r s v
  while IFS=$'\t' read -r n r; do
    [[ "$r" == developer || "$r" == tester ]] || continue
    s="$(agent_tmux_session "$n")"
    tmux has-session -t "=$s" 2>/dev/null || continue
    v="$(tmux show-environment -t "=$s" HARNESS_TICKET 2>/dev/null)" || continue
    [[ "$v" == "HARNESS_TICKET=$1" ]] && printf '%s\n' "$n"
  done < <(_roster_json | roster_active)
  return 0
}

# One pass: bench whoever is still due once the ledger says the ticket is done.
due_pass() { # <id>
  local id="$1" due="$STATE/$1" st left="" n
  [[ -s "$due" ]] || { echo "agent-bench-due: nobody is due for $id"; return 0; }
  st="$($LDB ticket-row "$id" 2>/dev/null)" || { echo "agent-bench-due: could not read $id on the ledger: CANNOT TELL" >&2; return 1; }
  st="$(tr -d '[:space:]' <<<"$st")"
  if ! due_done_status "$st"; then
    echo "agent-bench-due: $id is '${st:-no row}', not finished: waiting ($(paste -sd' ' "$due"))"; return 2
  fi
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if $BENCH "$n" >/dev/null 2>&1; then echo "agent-bench-due: benched $n ($id is $st)"
    else left+="$n"$'\n'; fi
  done < "$due"
  printf '%s' "$left" > "$due"
  [[ -z "$left" ]] && { echo "agent-bench-due: everyone due for $id is benched"; return 0; }
  echo "agent-bench-due: still due for $id: $(paste -sd' ' "$due") (agent-bench refused; tried again on the next pass)"; return 2
}

due_self_test() {
  local fails=0 T out rc
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
         else printf '  FAIL %s\n       want %q\n       got  %q\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  _has() { if grep -qF -- "$3" <<<"$2"; then printf '  ok   %s\n' "$1"
           else printf '  FAIL %s\n       no %q in:\n%s\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  T="$(mktemp -d)" || return 2
  trap 'rm -rf "$T"' RETURN

  _t "archived is finished" "$(due_done_status archived && echo y)" y
  _t "in_progress is not" "$(due_done_status in_progress || echo n)" n

  mkdir -p "$T/repo/agents" "$T/bin" "$T/state"
  cat > "$T/repo/agents/roster.json" <<'JSON'
{"agents":[
 {"name":"Lea","email":"lea@proj.local","role":"delivery-lead","status":"active"},
 {"name":"Ada","email":"ada@proj.local","role":"developer","status":"active"},
 {"name":"Ben","email":"ben@proj.local","role":"developer","status":"active"},
 {"name":"Tess","email":"tess@proj.local","role":"tester","status":"active"},
 {"name":"Cy","email":"cy@proj.local","role":"tester","status":"retired"}]}
JSON
  cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
case "\$1" in
  has-session) grep -qxF -- "\${3#=}" "$T/tmux.sessions" 2>/dev/null ;;
  show-environment) grep -m1 "^\$4=" "$T/tmux.env.\${3#=}" 2>/dev/null || { echo "unknown variable: \$4" >&2; exit 1; } ;;
esac
EOF
  cat > "$T/bin/ledger" <<EOF
#!/usr/bin/env bash
[ -e "$T/ledger.down" ] && exit 3
[ "\$1" = ticket-row ] && cat "$T/status"
EOF
  cat > "$T/bin/bench" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$T/benched"
! grep -qxF -- "\$1" "$T/refuse" 2>/dev/null
EOF
  chmod +x "$T/bin/tmux" "$T/bin/ledger" "$T/bin/bench"
  printf 'Lea\nAda\nBen\nTess\nCy\n' > "$T/tmux.sessions"
  printf 'HARNESS_TICKET=feat_x\n' | tee "$T/tmux.env.Ada" "$T/tmux.env.Tess" "$T/tmux.env.Lea" "$T/tmux.env.Cy" >/dev/null
  printf 'HARNESS_TICKET=feat_y\n' > "$T/tmux.env.Ben"
  run() { env HARNESS_ROOT="$T/repo" HARNESS_PROJECT=proj ROSTER_FILE="$T/repo/agents/roster.json" PATH="$T/bin:$PATH" \
            LDB="$T/bin/ledger" AGENT_BENCH_DUE_BENCH="$T/bin/bench" AGENT_BENCH_DUE_DIR="$T/state" bash "$SELF" "$@" 2>&1; }

  printf 'in_progress\n' > "$T/status"
  out="$(run feat_x --check)"; rc=$?
  _t "unfinished: still waiting" "$rc" 2
  _t "  the due list is the ticket's running developer and tester, no lead, no retired agent, no other ticket's" "$(cat "$T/state/feat_x")" $'Ada\nTess'
  _t "  and nobody is benched yet" "$(cat "$T/benched" 2>/dev/null)" ""
  printf 'archived\n' > "$T/status"; printf 'Tess\n' > "$T/refuse"
  out="$(run feat_x --check)"; rc=$?
  _t "archived, but agent-bench refuses one: still waiting" "$rc" 2
  _has "  the other is benched" "$out" "benched Ada"
  _t "  and only the refused one is still due" "$(cat "$T/state/feat_x")" "Tess"
  : > "$T/refuse"; : > "$T/benched"
  out="$(run feat_x --check)"; rc=$?
  _t "the next pass benches the rest" "$rc" 0
  _t "  and asks only for the one left" "$(cat "$T/benched")" "Tess"
  touch "$T/ledger.down"; printf 'Ada\n' > "$T/state/feat_x"
  out="$(run feat_x --check)"; rc=$?
  _t "a ledger it cannot read is an error, not done" "$rc" 1
  rm -f "$T/ledger.down"
  out="$(run feat_z --check)"; rc=$?
  _t "a ticket nobody holds: nothing to do" "$rc" 0
  out="$(run 'bad id!' --check)"; rc=$?
  _t "a bad id is a usage error" "$rc" 2
  out="$(run feat_x --frob)"; rc=$?
  _t "an unknown argument is a usage error" "$rc" 2
  out="$(run --slef-test)"; rc=$?
  _t "a mistyped self-test flag exits 2" "$rc" 2

  if (( fails == 0 )); then echo "agent-bench-due --self-test: PASS"; return 0; fi
  echo "agent-bench-due --self-test: FAIL ($fails)"; return 1
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  [[ $# -eq 1 ]] || { printf 'unknown argument: %s\n' "$2" >&2; exit 2; }
  due_self_test; exit $?
fi

ID="${1:-}" MODE="${2:-}"
[[ "$ID" =~ ^[A-Za-z0-9][A-Za-z0-9_.#/-]{0,254}$ ]] || { echo "$USAGE" >&2; exit 2; }
case "$MODE" in ''|--check|--wait) ;; *) echo "$USAGE" >&2; exit 2 ;; esac
[[ $# -le 2 ]] || { echo "$USAGE" >&2; exit 2; }
ID="${ID#\#}"
mkdir -p "$STATE" || { echo "agent-bench-due: cannot make $STATE" >&2; exit 1; }
DUE="$STATE/$ID"
[[ -e "$DUE" ]] || due_holders "$ID" > "$DUE"

pass() { ( flock 9; due_pass "$ID" ) 9>"$STATE/$ID.lock"; }

case "$MODE" in
  --check) pass; exit $? ;;
  --wait)
    end=$(( $(date +%s) + HOURS * 3600 ))
    while :; do
      pass; rc=$?
      (( rc == 0 )) && break
      (( $(date +%s) >= end )) && { echo "agent-bench-due: gave up after ${HOURS}h; still due for $ID: $(paste -sd' ' "$DUE")"; break; }
      sleep "$POLL"
    done
    rm -f "$STATE/$ID.pid"; exit 0 ;;
esac

# The default: one waiter per ticket, in the background.
if [[ -s "$STATE/$ID.pid" ]] && kill -0 "$(cat "$STATE/$ID.pid")" 2>/dev/null; then
  echo "agent-bench-due: already waiting for $ID (pid $(cat "$STATE/$ID.pid"))"; exit 0
fi
[[ -s "$DUE" ]] || { echo "agent-bench-due: nobody is due for $ID"; exit 0; }
nohup bash "$SELF" "$ID" --wait >> "$STATE/$ID.log" 2>&1 < /dev/null &
echo $! > "$STATE/$ID.pid"
echo "agent-bench-due: waiting for $ID to finish, then benching $(paste -sd' ' "$DUE") (log: $STATE/$ID.log)"
