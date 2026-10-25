#!/usr/bin/env bash
# scripts/agents-dash.sh — a narrow at-a-glance panel for the team, to sit beside the delivery lead.
#
#   bash scripts/agents-dash.sh            redraw until interrupted
#   bash scripts/agents-dash.sh --once     draw one frame and exit
#   bash scripts/agents-dash.sh --plain    no colour (for a pipe or a log)
#   bash scripts/agents-dash.sh --self-test
#
# It answers one question: is anything going awol. Per agent it shows its name in its role's colour,
# the ticket it holds, whether the session is working, waiting, in a shell command or idle and for how
# long, how much of its context window it has used, how fast it is generating tokens, and its model and
# reasoning effort. The account's week sits at
# the top - what it has used against the owner's budget so far (scripts/agents-budget.sh) - because the
# limit is account-wide and cannot be attributed to one agent. Put it in a pane beside the delivery
# lead's session, e.g.
# `tmux split-window -h -l 32 -t <session> "bash /path/to/harness/scripts/agents-dash.sh"`.
#
# The frame fits the pane's height. The full layout is three lines and a rule per agent; when that would
# run past the bottom the frame steps down (fit_level): no rule, then the sparkline folded onto the state
# line, then one line per agent. The height is the terminal's own (tput lines), or AGENTS_DASH_LINES.
#
# Where each number comes from:
#   roster          agents/roster.json through scripts/lib/roster.sh (roster_panel_rows): the active
#                   agents in the file's order, which is the owner's order, then the assistants. A
#                   developer or tester with no running session is on the bench and is left out
#   working/idle    ~/.claude/sessions/<pid>.json, Claude Code's own record (status, statusUpdatedAt).
#                   A session is known by the GIT_AUTHOR_EMAIL its launch line set, read from
#                   /proc/<pid>/environ where /proc exists and looked up in the roster, or failing that
#                   by its own session name
#   context, burn,  the rows the context publisher writes to CONTEXT_DIR (docs/context-publisher.md):
#   window, week    context.used, context.window, tokens.output_total; week through scripts/lib/week-usage.sh
#   model, effort   the same rows: model, effort
#   ticket          the claims board, `ledger-db.sh board`, read in the background at most once a minute
#   disk            df, for AGENT_DISK_WATCH only
#
# Nothing here reads a transcript: they run to hundreds of MB, and the status line already receives
# every figure the panel shows. A frame is one jq pass over the context rows, one over the live
# session records, one roster lookup per live session, and one ps.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/selftest-flag.sh
. "$_here/lib/selftest-flag.sh"
# shellcheck source=lib/harness-env.sh
. "$_here/lib/harness-env.sh" 2>/dev/null || true
# shellcheck source=lib/roster.sh
. "$_here/lib/roster.sh"
# shellcheck source=lib/week-usage.sh
. "$_here/lib/week-usage.sh"

ROSTER="${ROSTER_FILE:-${HARNESS_ROOT:-$_here/..}/agents/roster.json}"
SESSIONS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
CONTEXT_DIR="${CONTEXT_DIR:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/context}"
CACHE="${AGENTS_DASH_CACHE:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/dash}"   # holds burn.json, the per-session token totals and minute buckets
INTERVAL="${AGENTS_DASH_INTERVAL:-8}"
W="${AGENTS_DASH_WIDTH:-32}"
SPARK_MINS="${AGENTS_DASH_SPARK_MINS:-15}"
CTX_ALERT="${AGENTS_DASH_CTX_ALERT:-85}"   # context used (%) at which the gauge turns red
WAIT_ALERT="${AGENTS_DASH_WAIT_ALERT:-60}" # seconds waiting before a row is flagged
PANE_LINES="${AGENTS_DASH_LINES:-0}"       # the pane's height; 0 = unknown, and the full layout is drawn

# The clock, overridable so the self-test can pin a frame to a known second.
now_s() { printf '%s' "${AGENTS_DASH_NOW:-$(date -u +%s)}"; }

# The pane's height: AGENTS_DASH_LINES when set, else what the terminal reports. Read in the main
# process, where stdout is the terminal: inside `$(frame)` it is a pipe and tput cannot see the pane.
pane_lines() {
  if [ -n "${AGENTS_DASH_LINES:-}" ]; then printf '%s' "$AGENTS_DASH_LINES"; return; fi
  local l; l=$(tput lines 2>/dev/null) && [ "${l:-0}" -gt 0 ] 2>/dev/null && { printf '%s' "$l"; return; }
  printf '%s' "${LINES:-0}"
}

ONCE=0; PLAIN=0
colours() {
  if [ "$PLAIN" = 1 ] || [ ! -t 1 ]; then
    R=""; DIM=""; BOLD=""; GREEN=""; AMBER=""; RED=""; CYAN=""; GREY=""; INV=""; NOINV=""
  else
    R=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; INV=$'\033[7m'; NOINV=$'\033[27m'
    GREEN=$'\033[32m'; AMBER=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; GREY=$'\033[90m'
  fi
  RULE=$(printf '─%.0s' $(seq 1 "$W"))
}

SPARK=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

# ── the roster ────────────────────────────────────────────────────────────────
# roster -> "<name>\t<role>\t<kind>" per active agent GROUPED BY ROLE in a fixed order (owner, 2026-10-25:
# lead, developers, testers, head of testing, reviewer, process, support, then any other role), file order
# kept within a role, assistants last. A roster appends each new agent at the end, so in file order a new
# tester drew after the reviewer and the process lead: "in the wrong place on the dashboard". The Delivery
# tab groups the same way. roster_panel_rows itself stays in file order for its other readers.
roster() { [ -r "$ROSTER" ] && roster_panel_rows < "$ROSTER" | roster_grouped; }
role_rank() {
  case "$1" in
    delivery-lead) echo 0 ;; developer) echo 1 ;; tester) echo 2 ;; head-of-testing) echo 3 ;;
    code-reviewer) echo 4 ;; process-improvement) echo 5 ;; production-support) echo 6 ;;
    assistant) echo 9 ;; *) echo 8 ;;
  esac
}
# stdin: panel rows -> the same rows, stable-sorted by role_rank (sort -s keeps file order within a rank).
roster_grouped() {
  local name role kind
  while IFS=$'\t' read -r name role kind; do
    printf '%s\t%s\t%s\t%s\n' "$(role_rank "$role")" "$name" "$role" "$kind"
  done | sort -s -t $'\t' -k1,1n | cut -f2-
}

# A short label per role id, so the column fits.
short_role() {
  case "$1" in
    delivery-lead) echo lead ;;
    developer) echo dev ;;
    head-of-testing) echo test ;;
    tester) echo tester ;;
    code-reviewer) echo review ;;
    process-improvement) echo process ;;
    production-support) echo support ;;
    assistant) echo pa ;;
    *) echo "${1:0:7}" ;;
  esac
}

# ── live sessions ─────────────────────────────────────────────────────────────
# One line per live session: name, pid, session id, status, when the status last changed.
# Live means the pid is running AND the socket named in its own record is still there; Claude Code
# writes both when a session starts and removes both when it exits. `updatedAt` is NOT a heartbeat -
# a live session can leave it untouched for days - so it is never used to decide liveness.
# The name is the roster's for the GIT_AUTHOR_EMAIL in the process's environment, else the record's.
live() {
  local f pid files=() sock name rest email
  for f in "$SESSIONS"/*.json; do
    [ -r "$f" ] || continue
    pid=${f##*/}; pid=${pid%.json}
    kill -0 "$pid" 2>/dev/null && files+=("$f")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  jq -r '[(.messagingSocketPath // ""), (.pid|tostring), (.name // ""), (.sessionId // ""), (.status // "?"),
          ((.statusUpdatedAt // .updatedAt // 0)|tostring)] | join("\u001f")' "${files[@]}" 2>/dev/null |
  while IFS=$'\x1f' read -r sock pid name rest; do   # \x1f, not a tab: a tab is swallowed where the name is empty
    [ -n "$sock" ] && [ -S "$sock" ] || continue
    email=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^GIT_AUTHOR_EMAIL=//p' | head -1)
    if [ -n "$email" ]; then
      rostered=$(roster_name_for_email "$email" < "$ROSTER" 2>/dev/null)
      [ -n "$rostered" ] && name=$rostered
    fi
    printf '%s\t%s\t%s\n' "$name" "$pid" "${rest//$'\x1f'/$'\t'}"
  done | awk -F'\t' '$1 != "" { if (!($1 in best) || $5+0 > seen[$1]) { best[$1]=$0; seen[$1]=$5+0 } }
                     END { for (n in best) print best[n] }'
}

# ── formatting ────────────────────────────────────────────────────────────────
compact() { # 512 -> 512, 8500 -> 8.5k, 410739 -> 410k (truncated, not rounded)
  local n=${1:-0}
  [ "$n" -ge 0 ] 2>/dev/null || { printf '-'; return; }
  if [ "$n" -lt 1000 ]; then printf '%s' "$n"
  elif [ "$n" -lt 100000 ]; then printf '%s.%sk' $(( n / 1000 )) $(( n % 1000 / 100 ))
  elif [ "$n" -lt 1000000 ]; then printf '%sk' $(( n / 1000 ))
  else printf '%s.%sM' $(( n / 1000000 )) $(( n % 1000000 / 100000 )); fi
}

ago() { # seconds -> 4s, 12m, 3h
  local s=${1:-0}
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' $(( s / 60 ))
  else printf '%sh' $(( s / 3600 )); fi
}

bar() { # bar <pct> <cells> -> filled/empty blocks
  local pct=${1:-0} cells=${2:-10} f
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  [ "$pct" -ge 0 ] 2>/dev/null || pct=0
  f=$(( pct * cells / 100 ))
  # printf repeats its format once even with no arguments, so an empty run must be skipped, not
  # given to printf: 9% would otherwise draw one filled cell and 100% one empty one.
  [ "$f" -gt 0 ] && printf '█%.0s' $(seq 1 "$f")
  [ "$f" -lt "$cells" ] && printf '░%.0s' $(seq 1 $(( cells - f )))
  return 0
}

# spark <csv series> <ceiling> -> one block per minute, scaled to a ceiling shared by every agent so
# the heights are comparable between rows.
# A third argument keeps only the last that many minutes, for a layout with less room.
# The bars hang from the top of the line (owner, 2026-10-24): a bar rising from the bottom runs into the
# name box on the line below. Unicode has no set of top-anchored blocks, so a bar k/8 tall is the lower
# block (8-k)/8 in reverse video, which fills the top k/8 of the cell; a full bar is █ and a zero minute a
# grey ▔. Plain output has no reverse video and keeps the rising blocks, where the order still reads.
spark() {
  local csv=$1 ceil=${2:-1} cells=${3:-0} v i out=""
  IFS=',' read -r -a vals <<<"$csv"
  if [ "$cells" -gt 0 ] 2>/dev/null && [ "${#vals[@]}" -gt "$cells" ]; then vals=("${vals[@]: -$cells}"); fi
  for v in "${vals[@]:-0}"; do
    v=${v:-0}
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    if [ "$v" -le 0 ]; then if [ -n "$INV" ]; then out+="${GREY}▔${R}"; else out+="${GREY}▁${R}"; fi
    else
      i=$(( v * 7 / (ceil > 0 ? ceil : 1) ))
      [ "$i" -gt 7 ] && i=7
      if [ -z "$INV" ] || [ "$i" -eq 7 ]; then out+="${SPARK[$i]}"
      else out+="${INV}${SPARK[$(( 6 - i ))]}${NOINV}"; fi
    fi
  done
  printf '%s' "$out"
}

colour_for() { # colour_for <pct>
  local p=${1:-0}
  if [ "$p" -ge "$CTX_ALERT" ] 2>/dev/null; then printf '%s' "$RED"
  elif [ "$p" -ge 60 ] 2>/dev/null; then printf '%s' "$AMBER"
  else printf '%s' "$GREEN"; fi
}

rule() { printf '%s%s%s\n' "$DIM" "$RULE" "$R"; }
plain() { printf '%s' "$1" | sed $'s/\e\\[[0-9;]*m//g'; } # the text without its colour codes, to measure it

# fit_level <running> <not started> <fixed lines> <pane lines> -> 4 3 2 1: how many lines each running
# agent may take so the whole frame fits the pane. 4 is the full layout (three lines and a rule), 3 drops
# the rule, 2 folds the sparkline onto the state line, 1 is one line per agent. The first that fits wins,
# so the layout only shrinks when it has to and grows back when the team does. A row not started takes a
# line fewer than a running one at 4 and 3, and one line at 2 and 1. The frame must stay one line short of
# the pane, or printing the last line scrolls the header off the top. An unknown height (0) draws the
# full layout: a pane that cannot be measured is not made smaller on a guess.
fit_level() {
  local run=$1 down=$2 fixed=$3 pane=$4 lvl per_down
  [ "${pane:-0}" -gt 0 ] 2>/dev/null || { printf 4; return; }
  for lvl in 4 3 2; do
    per_down=$(( lvl >= 3 ? lvl - 1 : 1 ))
    [ $(( fixed + run * lvl + down * per_down )) -le $(( pane - 1 )) ] && { printf '%s' "$lvl"; return; }
  done
  printf 1
}

# role_colour <role id> -> black on the role's colour, as Claude Code draws a session's name after /color, or
# nothing without colour. The colour is AGENT_COLOUR_<ROLE> in harness.env (AGENT_COLOUR_DELIVERY_LEAD=red,
# ...), one of Claude Code's /color names; blank leaves the name plain bold. Purple and orange are the nearest
# 256-colour shades; the others match Claude Code's own.
role_colour() {
  [ -n "$R" ] || return 0
  local key def bg
  key=AGENT_COLOUR_${1^^}; key=${key//-/_}
  case "$1" in
    delivery-lead) def=red ;; developer) def=blue ;; tester) def=yellow ;; head-of-testing) def=purple ;;
    code-reviewer) def=cyan ;; process-improvement) def=pink ;; assistant) def=green ;; *) def="" ;;
  esac
  case "${!key-$def}" in
    red) bg=167 ;; green) bg=35 ;; yellow) bg=178 ;; blue) bg=110 ;; cyan) bg=37 ;; pink) bg=175 ;;
    purple) bg=141 ;; orange) bg=209 ;; *) return 0 ;;
  esac
  printf '\033[38;5;16;48;5;%sm' "$bg"
}

# claims -> "<lower-case name>\t<ticket id>" for the first ticket each agent holds on the claims board
# (`ledger-db.sh board`: id|area|claimed_by). The board is a database read, so the frame never waits for
# it: the panel keeps the last answer in $CACHE/board and, once that is BOARD_EVERY seconds old, starts one
# read in the background for the next frame. A read that fails leaves the last answer in place.
BOARD_EVERY="${AGENTS_DASH_BOARD_EVERY:-60}"
LEDGER="${AGENTS_DASH_LEDGER:-$_here/ledger-db.sh}"
claims() {
  local f="$CACHE/board" at
  mkdir -p "$CACHE" 2>/dev/null
  at=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
  if [ $(( $(date +%s) - at )) -ge "$BOARD_EVERY" ]; then
    touch "$f" 2>/dev/null   # one read at a time
    ( out=$(bash "$LEDGER" board 2>/dev/null) && printf '%s\n' "$out" > "$f.tmp" && mv -f "$f.tmp" "$f" ) \
      </dev/null >/dev/null 2>&1 &
  fi
  awk -F'|' '{ split($3, a, " "); n = tolower(a[1])
               if (n != "" && n != "-" && !(n in seen)) { seen[n] = 1; print n "\t" $1 } }' "$f" 2>/dev/null
}

# disk_line -> the free space on AGENT_DISK_WATCH (a path; blank watches nothing), dim, amber under
# AGENTS_DASH_DISK_WARN GB, red under AGENTS_DASH_DISK_ALERT GB. For a box where a full disk stops everything.
DISK="${AGENT_DISK_WATCH:-}"
DISK_WARN="${AGENTS_DASH_DISK_WARN:-40}"
DISK_ALERT="${AGENTS_DASH_DISK_ALERT:-20}"
disk_line() {
  [ -n "$DISK" ] || return 0
  local free col
  # POSIX df (-P, 1K blocks), so GNU and BSD df agree; column 4 is the space available.
  free=$(df -Pk "$DISK" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1048576 }')
  if [ -z "$free" ]; then printf ' %sdisk %s unreadable%s\n' "$AMBER" "$DISK" "$R"; return 0; fi
  col=$DIM; [ "$free" -lt "$DISK_WARN" ] && col=$AMBER; [ "$free" -lt "$DISK_ALERT" ] && col="$BOLD$RED"
  printf ' %sdisk%s %s%sG free%s %s%s%s\n' "$DIM" "$R" "$col" "$free" "$R" "$DIM" "$DISK" "$R"
}

# week_line <used %> -> the week's use as a bar, with a │ at the allowance scripts/agents-budget.sh gives for
# this point in the week, and both figures: green while the use is inside the allowance, red once past it.
# With no budget set, the plain bar, coloured by the use.
BUDGET="${AGENTS_DASH_BUDGET:-$_here/agents-budget.sh}"
week_line() {
  local used=$1 plan="" out i bar="" col fill mark
  if ! [ "$used" -ge 0 ] 2>/dev/null; then printf ' %sweek no reading yet%s\n' "$DIM" "$R"; return 0; fi
  out=$(bash "$BUDGET" 2>/dev/null)
  [ $? -le 1 ] && plan=$(sed -n 's/.* of \([0-9]*\)% planned.*/\1/p' <<<"$out")
  if [ -z "$plan" ]; then
    printf ' %sweek%s %s%s%s %s%s%%%s\n' "$DIM" "$R" "$(colour_for "$used")" "$(bar "$used" 10)" "$R" "$BOLD" "$used" "$R"
    return 0
  fi
  col=$GREEN; [ "$used" -gt "$plan" ] && col="$BOLD$RED"
  fill=$(( (used + 5) / 10 )); mark=$(( (plan + 5) / 10 ))
  [ "$fill" -gt 10 ] && fill=10; [ "$mark" -gt 10 ] && mark=10
  for (( i = 0; i <= 10; i++ )); do
    [ "$i" -eq "$mark" ] && bar+="$R$DIM│$R"
    [ "$i" -lt 10 ] || break
    if [ "$i" -lt "$fill" ]; then bar+="$col█$R"; else bar+="$DIM░$R"; fi
  done
  printf ' %sweek%s %s %s%s%%%s %sof%s %s%%\n' "$DIM" "$R" "$bar" "$col" "$used" "$R" "$DIM" "$R" "$plan"
}

# ── what the status line publishes ────────────────────────────────────────────
# The publisher writes one JSON row per session to CONTEXT_DIR on every refresh. Besides the
# percentages agent-context.sh shows, a row may carry what the panel needs: `context.used`, the
# tokens in the window now; `context.window`, the window the publisher's own gauge is measured
# against; and `tokens.output_total`, a running total of output tokens the publisher adds up across
# responses. The panel samples that total every frame and books its growth to the minute of the
# row's own timestamp, so a row that has not changed adds nothing and an idle minute is a zero.
# Without a figure the panel says so rather than guess: tokens without a percentage, or `no reading
# yet`.

# rows -> every readable row as one JSON value per line; a file that is not JSON is dropped, not fatal.
rows() { cat "$CONTEXT_DIR"/*.json 2>/dev/null | jq -cR 'fromjson? // empty' 2>/dev/null; }

# readings -> one line per session, "<sid> <used> <window> <tokens in the last minute> <series> <model>
# <effort>" with the fields separated by \x1f (a tab would be swallowed by `read` where a field is empty),
# the rate and series empty where no row has ever carried a total; and the new $CACHE/burn.json.
readings() {
  local state="$CACHE/burn.json" out
  mkdir -p "$CACHE" 2>/dev/null
  [ -s "$state" ] || printf '{}\n' > "$state" 2>/dev/null
  out=$(rows | jq -rs --argjson now "$(now_s)" --argjson mins "$SPARK_MINS" --slurpfile st "$state" '
    (($st[0] // {}) | if type == "object" then . else {} end) as $prev
    | ($now / 60 | floor) as $cur
    | map(select(.session_id != null) | {
        sid: .session_id,
        ts: ((.ts | fromdateiso8601?) // 0),
        used: (.context.used // null),
        window: (.context.window // 0),
        model: (.model // ""), effort: (.effort // ""),
        total: (.tokens.output_total // null) })
    | map(. as $r | ($prev[$r.sid] // {total: null, at: 0, buckets: {}}) as $p
        # Growth since the last sample goes into the minute the row was written, not the minute it
        # was read; a row no newer than the last sample adds nothing. Buckets older than the series
        # are dropped.
        | (if $r.total != null and $r.ts > $p.at and $p.total != null and $r.total > $p.total
           then ($r.ts / 60 | floor | tostring) as $m
             | $p.buckets + {($m): (($p.buckets[$m] // 0) + $r.total - $p.total)}
           else $p.buckets end
           | with_entries(select((.key | tonumber) > $cur - $mins - 1))) as $b
        | {sid: $r.sid, used: $r.used, window: $r.window, model: $r.model, effort: $r.effort, buckets: $b,
           has: ($r.total != null or $p.total != null),
           next: {total: (if $r.total != null and $r.ts >= $p.at then $r.total else $p.total end),
                  at: ([$r.ts, $p.at] | max), buckets: $b}})
    | (map(. as $e | "\($e.sid)\u001f\($e.used // "")\u001f\($e.window)\u001f"
          + (if $e.has then
               # the last 60 s: this minute so far, plus the part of last minute still inside it
               (((($e.buckets[$cur | tostring]) // 0)
                 + ((($e.buckets[($cur - 1) | tostring]) // 0) * (60 - ($now % 60)) / 60)) | floor | tostring)
               + "\u001f" + ([range(0; $mins) | ($cur - $mins + 1 + .) | tostring | ($e.buckets[.] // 0) | tostring] | join(","))
             else "\u001f" end)
          + "\u001f\($e.model)\u001f\($e.effort)")
       | .[]),
      (map({key: .sid, value: .next}) | from_entries | tojson)
  ' 2>/dev/null)
  [ -n "$out" ] || return 0
  printf '%s\n' "$out" | sed '$d'
  printf '%s\n' "$out" | tail -n 1 > "$state.tmp" 2>/dev/null && mv -f "$state.tmp" "$state" 2>/dev/null
}

# ── one frame ─────────────────────────────────────────────────────────────────
frame() {
  local now week
  now=$(now_s)
  week=$(week_used); week=${week%% *}

  # Everything about the live sessions, keyed by agent name.
  declare -A L_PID L_SID L_STATUS L_SINCE
  local n pid sid status since
  while IFS=$'\t' read -r n pid sid status since; do
    [ -n "$n" ] || continue
    L_PID[$n]=$pid; L_SID[$n]=$sid; L_STATUS[$n]=$status
    L_SINCE[$n]=$(( since / 1000 ))
  done < <(live)

  # The ticket each agent holds, from the claims board.
  declare -A TICKET
  local tid tname
  while IFS=$'\t' read -r tname tid; do [ -n "$tname" ] && TICKET[$tname]=$tid; done < <(claims)

  # What the publisher wrote for every session, keyed by session id.
  declare -A C_USED C_WIN C_RATE C_SER C_MODEL C_EFF
  local used win rate ser model eff
  while IFS=$'\x1f' read -r sid used win rate ser model eff; do
    [ -n "$sid" ] || continue
    C_USED[$sid]=$used; C_WIN[$sid]=$win; C_RATE[$sid]=$rate; C_SER[$sid]=$ser
    C_MODEL[$sid]=$model; C_EFF[$sid]=$eff
  done < <(readings)

  # Collect each agent's numbers first: the sparkline ceiling has to be shared across agents for the
  # heights to mean anything side by side.
  local names=() roles=() ctxs=() rates=() series=() models=() effs=() ceil=1
  while IFS=$'\t' read -r name role kind; do
    [ -n "$name" ] || continue
    # A developer or tester with no running session is on the bench (scripts/agent-bench.sh) until it is
    # spawned for its next ticket: not shown. Every other role reads "not started" when it is down.
    case "$role" in developer|tester) [ -n "${L_PID[$name]:-}" ] || continue ;; esac
    local ctx="" rate="" ser="" model="" eff=""
    if [ -n "${L_SID[$name]:-}" ]; then
      sid=${L_SID[$name]}
      ctx=${C_USED[$sid]:-}; rate=${C_RATE[$sid]:-}; ser=${C_SER[$sid]:-}
      model=${C_MODEL[$sid]:-}; eff=${C_EFF[$sid]:-}
      local v
      for v in ${ser//,/ }; do [ "${v:-0}" -gt "$ceil" ] 2>/dev/null && ceil=$v; done
    fi
    names+=("$name"); roles+=("$role")
    ctxs+=("${ctx:-}"); rates+=("${rate:-}"); series+=("${ser:-}"); models+=("$model"); effs+=("$eff")
  done < <(roster)

  # ── header, drawn into a variable first so its height is known before the layout is chosen
  local header
  header=$(
    printf '%s%-*s%s%s\n' "$BOLD$CYAN" $(( W - 6 )) " TEAM" "$(TZ=${TZ:-} date -d "@$now" '+%H:%M' 2>/dev/null || date '+%H:%M')" "$R"
    rule
    week_line "${week:--1}"
    disk_line
    rule
  )
  printf '%s\n' "$header"

  # ── the layout that fits: lines per running agent, 4 down to 1
  local run=0 down=0 footer=0 lvl
  for name in "${names[@]}"; do if [ -n "${L_PID[$name]:-}" ]; then run=$(( run + 1 )); else down=$(( down + 1 )); fi; done
  [ "$ceil" -gt 1 ] && footer=1
  lvl=$(fit_level "$run" "$down" "$(( $(printf '%s\n' "$header" | wc -l) + footer ))" "${PANE_LINES:-0}")

  # ── one agent per three lines, or fewer when the pane is short
  local i
  for i in "${!names[@]}"; do
    local name=${names[$i]} role id=${roles[$i]} ticket=${TICKET[${names[$i],,}]:-}
    role=$(short_role "$id")
    local ctx=${ctxs[$i]} rate=${rates[$i]} ser=${series[$i]} model=${models[$i]} eff=${effs[$i]}
    local pid=${L_PID[$name]:-} status=${L_STATUS[$name]:-} since=${L_SINCE[$name]:-0}
    local flag=" " namecol dot state nm line1
    namecol=$(role_colour "$id"); [ -n "$namecol" ] || namecol=$BOLD

    if [ -z "$pid" ]; then
      # On the roster but not running.
      if [ "$lvl" -ge 3 ]; then
        line1=$(printf '%s %-11s %-7s %s' "$GREY" "${name:0:9}" "$role" "$ticket")
        printf '%s%s\n' "${line1%"${line1##*[![:space:]]}"}" "$R"
        printf '%s   not started%s\n' "$GREY" "$R"
        [ "$lvl" -eq 4 ] && rule
      else
        line1=$(printf '%s %-11s %-7s not started' "$GREY" "${name:0:9}" "$role")
        printf '%s%s\n' "${line1%"${line1##*[![:space:]]}"}" "$R"
      fi
      continue
    fi

    local held=$(( now - since )); [ "$held" -lt 0 ] && held=0
    case "$status" in
      busy)    dot="${GREEN}●${R}"; state="working" ;;
      waiting) dot="${AMBER}⏸${R}"; state="waiting" ;;
      shell)   dot="${CYAN}⌨${R}";  state="in shell" ;;   # a shell command of its own is running
      idle)    dot="${DIM}○${R}";   state="idle" ;;
      *)       dot="${DIM}·${R}";   state="$status" ;;
    esac

    # Context against this session's own window.
    local pct="" ctxtxt=""
    if [ -n "$ctx" ]; then
      local win=${C_WIN[${L_SID[$name]}]:-0}
      if [ "${win:-0}" -gt 0 ] 2>/dev/null; then
        pct=$(( ctx * 100 / win ))
        ctxtxt="$(colour_for "$pct")${pct}%${R} ${DIM}$(compact "$ctx")${R}"
      else
        ctxtxt="${DIM}$(compact "$ctx") tok${R}"
      fi
    fi

    # The model as its family's initial and version ("Opus 5.5" -> O5.5), and the session's reasoning
    # effort as one letter (l m h x X), the two levels that spend the most tokens in amber. A model the
    # status line gives no effort level for shows none.
    local fam ver modeltxt="" efftxt=""
    read -r fam ver _ <<<"$model"
    [ -n "$fam" ] && [ "$fam" != "?" ] && modeltxt="${DIM}${fam:0:1}${ver}${R}"
    case "$eff" in
      low) efftxt="${DIM}l${R}" ;; medium) efftxt="${DIM}m${R}" ;; high) efftxt="${DIM}h${R}" ;;
      xhigh) efftxt="${AMBER}x${R}" ;; max) efftxt="${AMBER}X${R}" ;;
      ?*) efftxt="${DIM}${eff:0:1}${R}" ;;
    esac

    # A long wait flags the row and turns the name's box amber; high context shows only in the gauge's colour.
    if [ "$status" = waiting ] && [ "$held" -ge "$WAIT_ALERT" ]; then
      flag="${AMBER}?${R}"; [ -n "$R" ] && namecol=$'\033[38;5;16;48;5;214m' || namecol=""
    fi

    # A coloured name is a box, its width plus a space each side as Claude Code draws it; padding follows it.
    nm=${name:0:9}; [ -n "$R" ] && [ "$namecol" != "$BOLD" ] && nm=" $nm "
    line1=$(printf '%s%s%s%s%*s %s%-7s%s %s%s%s' "$flag" "$namecol" "$nm" "$R" $(( 11 - ${#nm} )) "" \
      "$DIM" "$role" "$R" "$CYAN" "$ticket" "$R")
    local line2 line3
    case "$lvl" in
      4|3)
        printf '%s\n' "${line1%"${line1##*[![:space:]]}"}"
        line2=$(printf ' %s %-9s %s' "$dot" "$state $(ago "$held")" "$ctxtxt")
        printf '%s\n' "${line2%"${line2##*[![:space:]]}"}"
        if [ -n "$ser" ]; then
          line3=$(printf ' %s %s%s/m%s %s %s' "$(spark "$ser" "$ceil")" "$DIM" "$(compact "${rate:-0}")" "$R" "$modeltxt" "$efftxt")
        else
          # Live, but no row has carried a token total yet: the publisher has not refreshed with one.
          line3=$(printf ' %sno reading yet%s %s %s' "$DIM" "$R" "$modeltxt" "$efftxt")
        fi
        printf '%s\n' "${line3%"${line3##*[![:space:]]}"}"
        [ "$lvl" -eq 4 ] && rule
        ;;
      *)
        # Short layouts: the context as a percentage alone, and the sparkline's last minutes in whatever
        # width is left, padded columns so the bars line up down the panel. The token rate goes: the
        # sparkline carries it.
        local pctpad head tail hp tp cells sp=""
        if [ -n "$pct" ]; then pctpad="$(colour_for "$pct")$(printf '%4s' "${pct}%")${R}"
        elif [ -n "$ctx" ]; then pctpad="${DIM}$(printf '%4s' "$(compact "$ctx")")${R}"
        else pctpad=$(printf '%4s' ""); fi
        tail=$(printf ' %s%s' "${modeltxt:+$modeltxt }" "${efftxt:-$(printf ' ')}")
        if [ "$lvl" -eq 2 ]; then
          printf '%s\n' "${line1%"${line1##*[![:space:]]}"}"
          head=$(printf ' %s %-7s %3s %s ' "$dot" "${state/in shell/shell}" "$(ago "$held")" "$pctpad")
        else
          # One line: the name, then the state. The ticket and role have no room at this height.
          nm=${name:0:7}; [ -n "$R" ] && [ "$namecol" != "$BOLD" ] && nm=" $nm "
          head=$(printf '%s%s%s%s%*s%s %3s %s ' "$flag" "$namecol" "$nm" "$R" $(( 9 - ${#nm} )) "" "$dot" "$(ago "$held")" "$pctpad")
          tail=""
        fi
        hp=$(plain "$head"); tp=$(plain "$tail")
        cells=$(( W - ${#hp} - ${#tp} )); [ "$cells" -lt 3 ] && cells=3
        [ -n "$ser" ] && sp=$(spark "$ser" "$ceil" "$cells")
        line2="${head}${sp}${tail}"
        printf '%s\n' "${line2%"${line2##*[![:space:]]}"}"
        ;;
    esac
  done

  [ "$ceil" -gt 1 ] && printf '%s full bar = %s tok/min%s\n' "$DIM" "$(compact "$ceil")" "$R"
}

# ── self-test ─────────────────────────────────────────────────────────────────
# Fixtures for everything a frame reads: a roster, context rows, Claude Code session records with a
# live process behind one of them (a child of this shell, launched with a GIT_AUTHOR_EMAIL) and a
# dead pid behind another, and a pinned clock.
selftest() {
  local t fails=0
  t() { local want="$1" desc="$2" got="$3"
        if [[ "$got" == "$want" ]]; then printf '  ok    %s\n' "$desc"
        else printf '  FAIL  %s\n        want %q\n        got  %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  local T; T=$(mktemp -d) || return 2
  local child=""
  cleanup() { [ -n "$child" ] && kill "$child" 2>/dev/null; rm -rf "$T"; }
  trap cleanup RETURN
  PLAIN=1; colours

  t 512 'compact: under a thousand is itself' "$(compact 512)"
  t 8.5k 'compact: thousands with a decimal' "$(compact 8500)"
  t 410k 'compact: hundreds of thousands truncated to the thousand' "$(compact 410739)"
  t 1.5M 'compact: millions with a decimal' "$(compact 1500000)"
  t 12m 'ago: minutes' "$(ago 720)"
  t 2h 'ago: hours' "$(ago 7200)"
  t '░░░░░░░░░░' 'bar: under one cell draws no filled cell' "$(bar 9 10)"
  t '██████████' 'bar: full draws no empty cell' "$(bar 100 10)"
  t '███████░░░' 'bar: 73% is seven of ten' "$(bar 73 10)"
  t lead 'short_role: the role ids shorten to the column' "$(short_role delivery-lead)"
  t 4 'fit_level: an unknown height draws the full layout' "$(fit_level 13 0 5 0)"
  t 4 'fit_level: the full layout when it ends one line short of the pane' "$(fit_level 2 1 5 17)"
  t 3 'fit_level: thirteen running agents in 51 lines lose the rule' "$(fit_level 13 0 5 51)"
  t 2 'fit_level: twenty running agents in 51 lines fold the sparkline in' "$(fit_level 20 0 5 51)"
  t 1 'fit_level: thirty running agents in 51 lines take one line each' "$(fit_level 30 0 5 51)"
  t 4 'fit_level: agents down count one line fewer at the full layout' "$(fit_level 0 10 5 36)"
  t 57 'spark: a cell count keeps the last minutes' "$(SPARK=(0 1 2 3 4 5 6 7); spark 1,2,5,7 7 2)"
  t $'\033[90m▔\033[0m\033[7m▆\033[27m\033[7m▃\033[27m█' 'spark: in colour the bars hang from the top: a zero is a grey top line, a part bar (2/8, 5/8) the complementary lower block (6/8, 3/8) in reverse video, a full bar █' \
    "$(R=$'\033[0m' GREY=$'\033[90m' INV=$'\033[7m' NOINV=$'\033[27m'; spark 0,1,4,7 7)"
  t test 'short_role: head-of-testing' "$(short_role head-of-testing)"

  # The roster: grouped by role in the fixed order, file order within a role, retired left out, assistants
  # last. The fixture is strength's shape: a tester appended after the reviewer and the process lead.
  printf '%s' '{"agents":[{"name":"Carl","role":"delivery-lead","status":"active"},
    {"name":"Ed","role":"developer","status":"active"},{"name":"Tom","role":"tester","status":"active"},
    {"name":"Vera","role":"head-of-testing","status":"active"},{"name":"Old","role":"developer","status":"retired"},
    {"name":"Stef","role":"code-reviewer","status":"active"},{"name":"Ro","role":"process-improvement","status":"active"},
    {"name":"Ben","role":"tester","status":"active"},{"name":"Zed","role":"some-new-role","status":"active"},
    {"name":"Sup","role":"production-support","status":"active"},{"name":"Ivy","role":"developer","status":"active"}],
    "assistants":[{"name":"Ada"}]}' > "$T/roster-grouped.json"
  t $'Carl\tdelivery-lead\tagent\nEd\tdeveloper\tagent\nIvy\tdeveloper\tagent\nTom\ttester\tagent\nBen\ttester\tagent\nVera\thead-of-testing\tagent\nStef\tcode-reviewer\tagent\nRo\tprocess-improvement\tagent\nSup\tproduction-support\tagent\nZed\tsome-new-role\tagent\nAda\tassistant\tassistant' \
    'roster: grouped lead, developers, testers, head of testing, reviewer, process, support, other; file order within a role; the assistant last' "$(ROSTER="$T/roster-grouped.json" roster)"
  t support 'short_role: production-support' "$(short_role production-support)"
  t '' 'roster_grouped: no rows in, none out' "$(printf '' | roster_grouped)"
  # The frames below read this small roster: Ed, Vera, Ben in file order IS the grouped order (dev, test, tester
  # is not: Ben the tester groups before Vera), so the frame arms also pin the grouping.
  printf '%s' '{"agents":[{"name":"Ed","email":"ed@example.test","role":"developer","status":"active"},
    {"name":"Vera","email":"vera@example.test","role":"head-of-testing","status":"active"},
    {"name":"Old","email":"old@example.test","role":"developer","status":"retired"},
    {"name":"Ben","email":"ben@example.test","role":"tester","status":"active"}],
    "assistants":[{"name":"Ada"}]}' > "$T/roster.json"
  ROSTER="$T/roster.json"
  t $'Ed\tdeveloper\tagent\nBen\ttester\tagent\nVera\thead-of-testing\tagent\nAda\tassistant\tassistant' \
    'roster: the frame fixture groups Ben the tester before Vera, then the assistant' "$(roster)"

  # Readings: a pinned clock on a minute boundary, so the buckets are predictable.
  local NOW=1792156800; AGENTS_DASH_NOW=$NOW; export AGENTS_DASH_NOW
  CONTEXT_DIR="$T/ctx"; CACHE="$T/cache"; SPARK_MINS=5; mkdir -p "$CONTEXT_DIR"
  row() { printf '{"agent":"Ed","session_id":"s1","ts":"%s","context":{"remaining_pct":50,"window":500000,"used":%s},"tokens":{"output_total":%s},"activity":"working","model":"Opus 5.5","effort":"xhigh","five_hour":{"used_pct":9},"week":{"used_pct":70}}\n' \
            "$(date -u -d "@$1" +%FT%TZ)" "$2" "$3" > "$CONTEXT_DIR/s1.json"; }
  row $((NOW-200)) 200000 1000
  t $'s1\x1f200000\x1f500000\x1f0\x1f0,0,0,0,0\x1fOpus 5.5\x1fxhigh' 'readings: the first sample sets the total and draws nothing' "$(readings)"
  row $((NOW-100)) 201000 1600
  t $'s1\x1f201000\x1f500000\x1f0\x1f0,0,600,0,0\x1fOpus 5.5\x1fxhigh' 'readings: growth lands in the minute the row was written' "$(readings)"
  row $((NOW-5)) 202000 1900
  t $'s1\x1f202000\x1f500000\x1f300\x1f0,0,600,300,0\x1fOpus 5.5\x1fxhigh' 'readings: a second sample adds its own bucket and the last-minute rate' "$(readings)"
  t $'s1\x1f202000\x1f500000\x1f300\x1f0,0,600,300,0\x1fOpus 5.5\x1fxhigh' 'readings: an unchanged row adds nothing' "$(readings)"
  printf '{"agent":"Vera","session_id":"s2","ts":"%s","context":{"remaining_pct":50},"activity":"idle"}\n' "$(date -u -d "@$((NOW-5))" +%FT%TZ)" > "$CONTEXT_DIR/s2.json"
  t $'s2\x1f\x1f0\x1f\x1f\x1f\x1f' 'readings: a row without the figures keeps its empty fields in place' "$(readings | grep '^s2')"
  t 70 'week: the weekly figure from the rows' "$(w=$(week_used); echo "${w%% *}")"
  printf 'not json at all\n' > "$CONTEXT_DIR/junk.json"
  t 70 'week: a file that is not JSON is dropped, not fatal to the frame' "$(w=$(week_used); echo "${w%% *}")"

  # The claims board: read from the panel's cache, refreshed in the background once it is old.
  printf 'feat_old|backend|Ed\n' > "$CACHE/board"
  printf '#!/usr/bin/env bash\n[ "$1" = board ] && printf "feat_x|backend|Ed\\nfeat_y|docs|Ed\\nfeat_z|docs|-\\nfeat_w|ci|Ben  <= DEPARTED, NOBODY IS COMING BACK\\n"\n' > "$T/ledger"
  LEDGER="$T/ledger"
  t $'ed\tfeat_old' 'claims: a fresh cache is read as it is, without a database read' "$(claims)"
  touch -d '2 hours ago' "$CACHE/board"
  claims > /dev/null; sleep 1
  t $'ed\tfeat_x\nben\tfeat_w' 'claims: an old cache is read again in the background; first claim per agent, unclaimed rows skipped' "$(claims)"
  printf '#!/usr/bin/env bash\nexit 3\n' > "$T/ledger"; touch -d '2 hours ago' "$CACHE/board"
  claims > /dev/null; sleep 1
  t $'ed\tfeat_x\nben\tfeat_w' 'claims: a failed read keeps the last answer' "$(claims)"
  touch "$CACHE/board"

  # Role colours, as Claude Code draws a name after /color; none without colour.
  t '' 'role colour: none without colour' "$(role_colour developer)"
  t $'\033[38;5;16;48;5;110m' 'role colour: a developer is black on blue by default' "$(R=x role_colour developer)"
  t $'\033[38;5;16;48;5;35m' 'role colour: AGENT_COLOUR_<ROLE> overrides it' "$(R=x AGENT_COLOUR_DEVELOPER=green role_colour developer)"
  t '' 'role colour: a blank setting leaves the name plain' "$(R=x AGENT_COLOUR_DEVELOPER= role_colour developer)"

  # The disk line.
  t '' 'disk: nothing is watched by default' "$(DISK='' disk_line)"
  t 1 'disk: a watched path shows its free space' "$(DISK=/ disk_line | grep -c '^ disk [0-9]*G free /$')"
  t ' disk /no/such/disk unreadable' 'disk: a path df cannot read says so' "$(DISK=/no/such/disk disk_line)"

  # The week line, against a stand-in budget script.
  printf '#!/usr/bin/env bash\necho "budget  none set"; exit 2\n' > "$T/budget"; BUDGET="$T/budget"
  t ' week ███████░░░ 70%' 'week line: with no budget, the plain bar' "$(week_line 70)"
  printf '#!/usr/bin/env bash\necho "budget  on: week 40%% used of 44%% planned so far"; exit 0\n' > "$T/budget"
  t ' week ████│░░░░░░ 40% of 44%' 'week line: on budget, the bar to the use and the mark at the allowance' "$(week_line 40)"
  printf '#!/usr/bin/env bash\necho "budget  over: week 70%% used of 44%% planned so far: ask the owner"; exit 1\n' > "$T/budget"
  t ' week ████│███░░░ 70% of 44%' 'week line: over budget, the bar runs past the mark' "$(week_line 70)"
  t ' week no reading yet' 'week line: no reading says so' "$(week_line -1)"
  t 1 'readings: the good rows survive a bad file beside them' "$(readings | grep -c '^s1')"

  # Live sessions: a child of this shell launched with a GIT_AUTHOR_EMAIL stands for Ed's session;
  # a dead pid and a record without a socket are both left out.
  SESSIONS="$T/sessions"; mkdir -p "$SESSIONS"
  GIT_AUTHOR_EMAIL=ed@example.test bash -c 'sleep 60' & child=$!
  sleep 0.2
  if python3 -c "import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1])" "$T/ed.sock" 2>/dev/null; then
    printf '{"pid":%s,"sessionId":"s1","name":null,"status":"idle","statusUpdatedAt":%s,"messagingSocketPath":"%s"}\n' \
      "$child" "$(( (NOW - 300) * 1000 ))" "$T/ed.sock" > "$SESSIONS/$child.json"
    printf '{"pid":4194300,"sessionId":"dead","name":"Vera","status":"busy","updatedAt":1,"messagingSocketPath":"%s"}\n' "$T/ed.sock" > "$SESSIONS/4194300.json"
    printf '{"pid":%s,"sessionId":"nosock","name":"Vera","status":"busy","updatedAt":1}\n' "$$" > "$SESSIONS/$$.json"
    t "Ed	$child	s1	idle	$(( (NOW - 300) * 1000 ))" 'live: a session is named by its launch email; the dead pid and the socketless record are left out' "$(live)"

    # A whole frame against the fixtures: Ed's row from the live child, Vera not started, Ada not started.
    local out; out=$(frame)
    t 1 'frame: Ed is idle for five minutes at 40% of a 500k window' "$(printf '%s\n' "$out" | grep -c ' ○ idle 5m   40% 202k')"
    t 1 'frame: the week line reads 70% against the budget' "$(printf '%s\n' "$out" | grep -c '^ week ████│███░░░ 70% of 44%$')"
    t 0 'frame: no five-hour line' "$(printf '%s\n' "$out" | grep -c ' 5h ')"
    t 1 'frame: the first line is the name, role and ticket' "$(printf '%s\n' "$out" | grep -c '^ Ed          dev     feat_x$')"
    t 1 'frame: the model and effort follow the token rate' "$(printf '%s\n' "$out" | grep -c '/m O5.5 x$')"
    t 0 'frame: no cpu or memory' "$(printf '%s\n' "$out" | grep -cE '[0-9]G +[0-9.]+%$')"
    t 1 'frame: a row not started lines its role up with a running one' "$(printf '%s\n' "$out" | grep -c '^ Vera        test$')"
    t 2 'frame: the agents without a session read not started' "$(printf '%s\n' "$out" | grep -c 'not started')"
    t 0 'frame: a tester with no session is on the bench and not shown' "$(printf '%s\n' "$out" | grep -c 'Ben')"
    t 1 'frame: a developer with a session is shown' "$(printf '%s\n' "$out" | grep -c '^ Ed ')"
    t 1 'frame: the shared scale is printed' "$(printf '%s\n' "$out" | grep -c 'full bar = 600 tok/min')"
    t 15 'frame: the full layout is three lines and a rule per running agent, two and a rule per agent down' "$(printf '%s\n' "$out" | wc -l)"

    # The frame fits a short pane: the same fixtures, four header lines and the scale line fixed, so
    # 15 lines in full. A 12-line pane gets the two-line layout; an 8-line pane one line per agent,
    # which is the floor even though 8 lines still do not fit.
    out=$(PANE_LINES=12 frame)
    t 9 'fit: a 12-line pane gets two lines per running agent and one per agent down' "$(printf '%s\n' "$out" | wc -l)"
    t 1 'fit: two-line layout keeps the name, role and ticket line' "$(printf '%s\n' "$out" | grep -c '^ Ed          dev     feat_x$')"
    t 1 'fit: two-line layout folds the state, wait, context and sparkline onto one line' "$(printf '%s\n' "$out" | grep -c '^ ○ idle     5m  40% ▁▁█▄▁ O5.5 x$')"
    t 1 'fit: a row down takes one line with its role' "$(printf '%s\n' "$out" | grep -c '^ Vera        test    not started$')"
    out=$(PANE_LINES=8 frame)
    t 8 'fit: an 8-line pane gets one line per agent, the floor' "$(printf '%s\n' "$out" | wc -l)"
    t 1 'fit: one-line layout is the name, state, wait, context and sparkline' "$(printf '%s\n' "$out" | grep -c '^ Ed       ○  5m  40% ▁▁█▄▁$')"
    out=$(PANE_LINES=13 frame)
    t 12 'fit: a 13-line pane drops the rules and keeps three lines per running agent' "$(printf '%s\n' "$out" | wc -l)"
    t 0 'fit: no rule between agents at three lines' "$(printf '%s\n' "$out" | sed '1,5d' | grep -c '^─')"
    out=$(PANE_LINES=16 frame)
    t 15 'fit: a pane one line taller than the frame keeps the full layout' "$(printf '%s\n' "$out" | wc -l)"
  else
    echo "  skipped  the live-session arms need python3 to make a socket — said, not silently passed"
  fi

  (( fails == 0 )) && { echo "agents-dash: self-test ok"; return 0; }
  echo "agents-dash: self-test FAILURES"; return 1
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then selftest; exit $?; fi
for a in "$@"; do
  case "$a" in
    --once) ONCE=1 ;;
    --plain) PLAIN=1 ;;
    -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "agents-dash: unknown argument '$a' (usage: agents-dash.sh [--once] [--plain] [--self-test])" >&2; exit 2 ;;
  esac
done
colours

if [ "$ONCE" = 1 ]; then
  PANE_LINES=$(pane_lines)
  frame
  exit 0
fi

trap 'tput cnorm 2>/dev/null; exit 0' INT TERM
tput civis 2>/dev/null
while :; do
  PANE_LINES=$(pane_lines)   # every frame: the pane may have been resized
  out=$(frame)
  tput clear 2>/dev/null || printf '\033[2J\033[H'
  printf '%s\n' "$out"
  sleep "$INTERVAL"
done
