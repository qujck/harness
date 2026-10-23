#!/usr/bin/env bash
# scripts/agent-bench.sh — stop a developer's or tester's session once its ticket has merged: onto the bench.
#
#   bash scripts/agent-bench.sh <Name> [--dry-run]
#   bash scripts/agent-bench.sh --self-test
#
# The delivery lead's way to shrink the team (docs/roles/delivery-lead.md, "The size of the team"); the
# partner of scripts/agent-spawn.sh. Benching stops the SESSION and nothing else: the roster row, the name,
# its identity and its worktree all stay, and agent-spawn.sh can start the same agent for its next ticket.
# It never writes agents/roster.json (retiring a name for good is a different, permanent act).
#
# It refuses, and says what is still open, while the agent:
#   - is not an active developer or tester on the roster;
#   - holds a claim (`ledger-db.sh board` shows a ticket claimed_by it): the ticket's row writes come first,
#     ending with `feature-ticket.sh release <id>`, or the bench would leave an orphaned claim;
#   - is mid-turn (its Claude Code record says busy, waiting or shell);
#   - has uncommitted changes in its worktree `<project>-<name>` (exactly that name, not a substring);
#   - has written no session entry since its session started (`ledger-db.sh session-entries`), which is
#     what handoff.sh asks of any session before it ends.
# A board or entry list it cannot read is a refusal too: "cannot tell" never reads as "nothing open".
#
# Then it stops the session: its tmux session `<project>-<name>` (the one agent-spawn.sh starts), or, for a
# session started by hand from the launch line, its process. An agent with no running session is already on
# the bench, and that is said and exits 0. --dry-run runs every check and stops nothing.
#
# Exit: 0 benched (or already benched, or a dry run passed) · 1 refused · 2 a usage error.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="$_here/$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=lib/selftest-flag.sh
. "$_here/lib/selftest-flag.sh"
# shellcheck source=lib/harness-env.sh
. "$_here/lib/harness-env.sh"
export ROSTER_FILE="${ROSTER_FILE:-$HARNESS_ROOT/agents/roster.json}"
# shellcheck source=lib/roster.sh
. "$_here/lib/roster.sh"
# shellcheck source=lib/agent-session.sh
. "$_here/lib/agent-session.sh"
LDB="${LDB:-bash $_here/ledger-db.sh}"   # overridable so the self-test can stand in for the ledger

USAGE="usage: agent-bench.sh <Name> [--dry-run]"

# PURE: board lines (id|area|claimed_by[  <= note]) on stdin -> the ids claimed by <name>, one per line.
bench_claims_of() { # <name>
  awk -F'|' -v n="${1,,}" '{ split($3, a, " "); if (tolower(a[1]) == n) print $1 }'
}

# The worktrees of this repository whose directory is exactly <session name>, one path per line.
bench_worktrees_of() { # <name>
  local want; want="$(agent_session_name "$1")"
  git -C "$HARNESS_ROOT" worktree list --porcelain | sed -n 's/^worktree //p' |
    while IFS= read -r p; do [[ "${p##*/}" == "$want" ]] && printf '%s\n' "$p"; done
  return "${PIPESTATUS[0]}"
}

bench_self_test() {
  local fails=0 T out rc child="" since
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
         else printf '  FAIL %s\n       want %q\n       got  %q\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  _has() { if grep -qF -- "$3" <<<"$2"; then printf '  ok   %s\n' "$1"
           else printf '  FAIL %s\n       no %q in:\n%s\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  T="$(mktemp -d)" || return 2
  trap '[[ -n "$child" ]] && kill "$child" 2>/dev/null; rm -rf "$T"' RETURN

  _t "board: the claimant's ids" "$(printf 'feat_a|ci|Ada\nfeat_b|ci|Adam\nfeat_c|ci|ada  <= DEPARTED, NOBODY IS COMING BACK\n' | bench_claims_of Ada)" \
     $'feat_a\nfeat_c'

  # FIXTURES: a git repository with Ada's worktree and a near-namesake's, a roster, Claude Code records in a
  # throwaway config dir, and stand-ins for tmux and the ledger. The only tmux on PATH is the stand-in.
  mkdir -p "$T/repo/agents" "$T/bin" "$T/claude/sessions" "$T/wt"
  git init -q "$T/repo" && git -C "$T/repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$T/repo" worktree add -q "$T/wt/proj-ada" 2>/dev/null
  git -C "$T/repo" worktree add -q "$T/wt/proj-adam" 2>/dev/null
  cat > "$T/repo/agents/roster.json" <<'JSON'
{"agents":[
 {"name":"Lea","email":"lea@proj.local","role":"delivery-lead","status":"active"},
 {"name":"Ada","email":"ada@proj.local","role":"developer","status":"active"},
 {"name":"Ben","email":"ben@proj.local","role":"developer","status":"active"},
 {"name":"Cy","email":"cy@proj.local","role":"tester","status":"retired"}]}
JSON
  cat > "$T/bin/tmux" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/tmux.log"
case "\$1" in
  has-session)  grep -qxF -- "\${3#=}" "$T/tmux.sessions" 2>/dev/null ;;
  kill-session) grep -vxF -- "\${3#=}" "$T/tmux.sessions" > "$T/tmux.tmp"; mv "$T/tmux.tmp" "$T/tmux.sessions" ;;
  display-message) echo 1792156000 ;;
esac
EOF
  cat > "$T/bin/ledger-db.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/ledger.log"
[ -e "$T/ledger.down" ] && { echo "ledger-db: cannot connect" >&2; exit 3; }
case "\$1" in board) cat "$T/board" ;; session-entries) cat "$T/entries" ;; esac
EOF
  chmod +x "$T/bin/tmux" "$T/bin/ledger-db.sh"
  local sum0; sum0="$(cksum < "$T/repo/agents/roster.json")"
  run() { HARNESS_ROOT="$T/repo" HARNESS_PROJECT=proj ROSTER_DOMAIN=proj.local ROSTER_FILE="$T/repo/agents/roster.json" \
            CLAUDE_CONFIG_DIR="$T/claude" PATH="$T/bin:$PATH" LDB=ledger-db.sh bash "$SELF" "$@" 2>&1; }
  # Ada: running in agent-spawn's tmux session AND a live record (idle, started at a known ms), finished.
  reset() {
    printf 'proj-ada\n' > "$T/tmux.sessions"; : > "$T/tmux.log"; : > "$T/ledger.log"; rm -f "$T/ledger.down"
    printf 'feat_other|ci|Ben\n' > "$T/board"; printf '[{"agent":"Ada","title":"done"}]\n' > "$T/entries"
    [[ -n "$child" ]] && kill -0 "$child" 2>/dev/null || { GIT_AUTHOR_EMAIL=ada@proj.local sleep 60 & child=$!; }
    printf '{"pid":%s,"sessionId":"s1","status":"idle","startedAt":1792156800000}\n' "$child" > "$T/claude/sessions/$child.json"
  }
  since="$(jq -nr '1792156800 | todate')"

  reset
  out="$(run Nobody)"; rc=$?;   _t "a name not on the roster is refused" "$rc" 1
  out="$(run Lea)"; rc=$?;      _t "the delivery lead is never benched" "$rc" 1
  _has "  and says only developers and testers are" "$out" "only a developer or a tester is benched"
  out="$(run Cy)"; rc=$?;       _t "a retired agent is refused" "$rc" 1
  out="$(run Ben)"; rc=$?;      _t "an agent with no running session is already on the bench" "$rc" 0
  _has "  and says so" "$out" "Ben has no running session: already on the bench"

  printf 'feat_mine|backend|Ada\n' >> "$T/board"
  out="$(run Ada)"; rc=$?;      _t "an agent holding a claim is refused" "$rc" 1
  _has "  naming the claim and the release" "$out" "Ada still holds feat_mine"
  reset; touch "$T/ledger.down"
  out="$(run Ada)"; rc=$?;      _t "a board that cannot be read is a refusal" "$rc" 1
  _has "  said as cannot tell" "$out" "cannot read the board"
  reset; sed -i 's/"idle"/"busy"/' "$T/claude/sessions/$child.json"
  out="$(run Ada)"; rc=$?;      _t "an agent mid-turn is refused" "$rc" 1
  _has "  and says so" "$out" "Ada is mid-turn (busy)"
  reset; sed -i 's/"idle"/"waiting"/' "$T/claude/sessions/$child.json"
  out="$(run Ada)"; rc=$?;      _t "an agent at a prompt is mid-turn too" "$rc" 1
  reset; touch "$T/wt/proj-ada/wip.txt"
  out="$(run Ada)"; rc=$?;      _t "a dirty worktree is refused" "$rc" 1
  _has "  naming it" "$out" "uncommitted changes in $T/wt/proj-ada"
  rm -f "$T/wt/proj-ada/wip.txt"; touch "$T/wt/proj-adam/wip.txt"
  reset; out="$(run Ada --dry-run)"; rc=$?
  _t "a near-namesake's dirty worktree is not Ada's" "$rc" 0
  rm -f "$T/wt/proj-adam/wip.txt"
  reset; printf '[]\n' > "$T/entries"
  out="$(run Ada)"; rc=$?;      _t "no session entry since the session started is refused" "$rc" 1
  _has "  and asks for one" "$out" "no session entry since its session started"
  _has "  asking the ledger from the record's start time" "$(cat "$T/ledger.log")" "session-entries --agent Ada --since $since --limit 1"

  reset; out="$(run Ada --dry-run)"; rc=$?
  _t "a dry run of a finished agent passes" "$rc" 0
  _has "  and says what it would stop" "$out" "would bench Ada (developer): stop tmux session proj-ada"
  _t "  and stops nothing" "$(grep -c '^kill-session' "$T/tmux.log")" 0

  reset; out="$(run Ada)"; rc=$?
  _t "a bench exits 0" "$rc" 0
  _has "  and stops the agent's tmux session, exactly" "$(cat "$T/tmux.log")" "kill-session -t =proj-ada"
  _has "  and says what stays" "$out" "benched Ada"
  _t "  and writes no roster" "$(cksum < "$T/repo/agents/roster.json")" "$sum0"
  _t "  and keeps the worktree" "$(git -C "$T/repo" worktree list | grep -c '/proj-ada ')" 1

  # a session started by hand from the launch line: no tmux session of ours, so the process is stopped
  reset; : > "$T/tmux.sessions"
  out="$(run Ada)"; rc=$?
  _t "a hand-started session is benched by its process" "$rc" 0
  _has "  and says which" "$out" "pid $child"
  wait "$child" 2>/dev/null
  kill -0 "$child" 2>/dev/null && _t "  and the process is gone" alive gone || _t "  and the process is gone" gone gone
  child=""

  out="$(run --slef-test)"; rc=$?; _t "a mistyped self-test flag exits 2, never runs" "$rc" 2
  out="$(run Ada --frobnicate)"; rc=$?; _t "an unknown argument is refused" "$rc" 2

  if (( fails == 0 )); then echo "agent-bench --self-test: PASS"; return 0; fi
  echo "agent-bench --self-test: FAIL ($fails)"; return 1
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  [[ $# -eq 1 ]] || { printf 'unknown argument: %s\n' "$2" >&2; exit 2; }
  bench_self_test; exit $?
fi

NAME="" DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -*|'') printf 'agent-bench: unknown argument: %s\n%s\n' "$a" "$USAGE" >&2; exit 2 ;;
    *) [[ -z "$NAME" ]] || { echo "$USAGE" >&2; exit 2; }; NAME=$a ;;
  esac
done
[[ -n "$NAME" ]] || { echo "$USAGE" >&2; exit 2; }
refuse() { printf 'agent-bench: %s\n' "$*" >&2; exit 1; }

# ── who it is ─────────────────────────────────────────────────────────────────────────────────────────
[[ -r "$ROSTER_FILE" ]] || refuse "no roster at $ROSTER_FILE"
ROLE="$(roster_lookup_role "$NAME")"
[[ -n "$ROLE" ]] || refuse "$NAME is not on the roster"
[[ "$(roster_lookup_status "$NAME")" == active ]] || refuse "$NAME is retired; a retired name is never started, so there is nothing to bench"
case "$ROLE" in developer|tester) ;; *) refuse "$NAME is the $ROLE; only a developer or a tester is benched" ;; esac

SESSION="$(agent_session_name "$NAME")"
TMUX_UP=0; agent_session_tmux_up "$NAME" && TMUX_UP=1
REC="$(agent_session_record "$NAME")"
PID="" STATUS="" STARTED=""
[[ -n "$REC" ]] && IFS=$'\t' read -r PID STATUS STARTED <<<"$REC"
if (( ! TMUX_UP )) && [[ -z "$PID" ]]; then
  printf '%s has no running session: already on the bench. Nothing was stopped.\n' "$NAME"
  exit 0
fi

# ── what is still open ────────────────────────────────────────────────────────────────────────────────
BOARD="$($LDB board 2>&1)" || refuse "cannot read the board (ledger-db.sh board), so cannot tell whether $NAME holds a claim: $BOARD"
CLAIMS="$(bench_claims_of "$NAME" <<<"$BOARD" | paste -sd' ' -)"
[[ -z "$CLAIMS" ]] || refuse "$NAME still holds $CLAIMS: once the PR has merged, its row writes end with \`bash scripts/feature-ticket.sh release <id>\` (developer.md), then bench it"

case "$STATUS" in
  busy|waiting|shell) refuse "$NAME is mid-turn ($STATUS); bench it once it is idle" ;;
esac

WTS="$(bench_worktrees_of "$NAME")" || refuse "cannot list the worktrees of $HARNESS_ROOT"
DIRTY=()
while IFS= read -r w; do
  [[ -n "$w" ]] || continue
  [[ -z "$(git -C "$w" status --porcelain 2>/dev/null)" ]] || DIRTY+=("$w")
done <<<"$WTS"
(( ${#DIRTY[@]} == 0 )) || refuse "uncommitted changes in ${DIRTY[*]}: $NAME commits, pushes or discards them first"

# When the session started: the record's own start (ms), else the tmux session's creation (s).
START_S=""
[[ "${STARTED:-0}" =~ ^[0-9]+$ ]] && (( STARTED > 0 )) && START_S=$(( STARTED / 1000 ))
if [[ -z "$START_S" ]] && (( TMUX_UP )); then
  START_S="$(tmux display-message -p -t "=$SESSION" '#{session_created}' 2>/dev/null)"
fi
[[ "$START_S" =~ ^[0-9]+$ ]] || refuse "cannot tell when $NAME's session started, so cannot check for its session entry"
SINCE="$(jq -nr --argjson s "$START_S" '$s | todate')"
ENTRIES="$($LDB session-entries --agent "$NAME" --since "$SINCE" --limit 1 2>&1)" \
  || refuse "cannot read $NAME's session entries (ledger-db.sh session-entries): $ENTRIES"
N="$(jq -r 'length' <<<"$ENTRIES" 2>/dev/null)"
[[ "$N" =~ ^[0-9]+$ ]] || refuse "cannot read $NAME's session entries: not a JSON list"
(( N > 0 )) || refuse "$NAME has written no session entry since its session started ($SINCE): it writes one (bash scripts/progress.sh new) before it is benched"

# ── the bench ────────────────────────────────────────────────────────────────────────────────────────
if (( TMUX_UP )); then WHAT="stop tmux session $SESSION"; else WHAT="stop its session, pid $PID"; fi
if (( DRY )); then
  printf 'would bench %s (%s): %s. Roster row, name, identity and worktree stay.\n' "$NAME" "$ROLE" "$WHAT"
  exit 0
fi
if (( TMUX_UP )); then
  tmux kill-session -t "=$SESSION" || refuse "tmux could not stop session $SESSION"
else
  kill -TERM "$PID" 2>/dev/null || refuse "could not stop pid $PID"
fi
printf 'benched %s (%s): %s. Roster row, name, identity and worktree%s stay; agent-spawn.sh starts it again for its next ticket.\n' \
  "$NAME" "$ROLE" "$WHAT" "${WTS:+ ($(paste -sd' ' - <<<"$WTS"))}"
