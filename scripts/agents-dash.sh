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

# The clock, overridable so the self-test can pin a frame to a known second.
now_s() { printf '%s' "${AGENTS_DASH_NOW:-$(date -u +%s)}"; }

ONCE=0; PLAIN=0
colours() {
  if [ "$PLAIN" = 1 ] || [ ! -t 1 ]; then
    R=""; DIM=""; BOLD=""; GREEN=""; AMBER=""; RED=""; CYAN=""; GREY=""
  else
    R=$'\033[0m'; DIM=$'\033[2m'; BOLD=$'\033[1m'
    GREEN=$'\033[32m'; AMBER=$'\033[33m'; RED=$'\033[31m'; CYAN=$'\033[36m'; GREY=$'\033[90m'
  fi
  RULE=$(printf '─%.0s' $(seq 1 "$W"))
}

SPARK=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

# ── the roster ────────────────────────────────────────────────────────────────
# roster -> "<name>\t<role>\t<kind>" per active agent in file order, then per assistant.
roster() { [ -r "$ROSTER" ] && roster_panel_rows < "$ROSTER"; }

# A short label per role id, so the column fits.
short_role() {
  case "$1" in
    delivery-lead) echo lead ;;
    developer) echo dev ;;
    head-of-testing) echo test ;;
    tester) echo tester ;;
    code-reviewer) echo review ;;
    process-improvement) echo process ;;
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
spark() {
  local csv=$1 ceil=${2:-1} v i out=""
  IFS=',' read -r -a vals <<<"$csv"
  for v in "${vals[@]:-0}"; do
    v=${v:-0}
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    if [ "$v" -le 0 ]; then out+="${GREY}▁${R}"
    else
      i=$(( v * 7 / (ceil > 0 ? ceil : 1) ))
      [ "$i" -gt 7 ] && i=7
      out+="${SPARK[$i]}"
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

  # ── header
  printf '%s%-*s%s%s\n' "$BOLD$CYAN" $(( W - 6 )) " TEAM" "$(TZ=${TZ:-} date -d "@$now" '+%H:%M' 2>/dev/null || date '+%H:%M')" "$R"
  rule
  week_line "${week:--1}"
  disk_line
  rule

  # ── one agent per three lines
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
      line1=$(printf '%s %-11s %-7s %s' "$GREY" "${name:0:9}" "$role" "$ticket")
      printf '%s%s\n' "${line1%"${line1##*[![:space:]]}"}" "$R"
      printf '%s   not started%s\n' "$GREY" "$R"
      rule
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
    printf '%s\n' "${line1%"${line1##*[![:space:]]}"}"
    local line2
    line2=$(printf ' %s %-9s %s' "$dot" "$state $(ago "$held")" "$ctxtxt")
    printf '%s\n' "${line2%"${line2##*[![:space:]]}"}"
    local line3
    if [ -n "$ser" ]; then
      line3=$(printf ' %s %s%s/m%s %s %s' "$(spark "$ser" "$ceil")" "$DIM" "$(compact "${rate:-0}")" "$R" "$modeltxt" "$efftxt")
    else
      # Live, but no row has carried a token total yet: the publisher has not refreshed with one.
      line3=$(printf ' %sno reading yet%s %s %s' "$DIM" "$R" "$modeltxt" "$efftxt")
    fi
    printf '%s\n' "${line3%"${line3##*[![:space:]]}"}"
    rule
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
  t test 'short_role: head-of-testing' "$(short_role head-of-testing)"

  # The roster: file order, retired left out, assistants last.
  printf '%s' '{"agents":[{"name":"Ed","email":"ed@example.test","role":"developer","status":"active"},
    {"name":"Vera","email":"vera@example.test","role":"head-of-testing","status":"active"},
    {"name":"Old","email":"old@example.test","role":"developer","status":"retired"},
    {"name":"Ben","email":"ben@example.test","role":"tester","status":"active"}],
    "assistants":[{"name":"Ada"}]}' > "$T/roster.json"
  ROSTER="$T/roster.json"
  t $'Ed\tdeveloper\tagent\nVera\thead-of-testing\tagent\nBen\ttester\tagent\nAda\tassistant\tassistant' \
    'roster: active agents in file order, then the assistant' "$(roster)"

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
  frame
  exit 0
fi

trap 'tput cnorm 2>/dev/null; exit 0' INT TERM
tput civis 2>/dev/null
while :; do
  out=$(frame)
  tput clear 2>/dev/null || printf '\033[2J\033[H'
  printf '%s\n' "$out"
  sleep "$INTERVAL"
done
