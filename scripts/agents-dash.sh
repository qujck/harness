#!/usr/bin/env bash
# scripts/agents-dash.sh — a narrow at-a-glance panel for the team, to sit beside the delivery lead.
#
#   bash scripts/agents-dash.sh            redraw until interrupted
#   bash scripts/agents-dash.sh --once     draw one frame and exit
#   bash scripts/agents-dash.sh --plain    no colour (for a pipe or a log)
#   bash scripts/agents-dash.sh --self-test
#
# It answers one question: is anything going awol. Per agent it shows whether the session is
# working, waiting, in a shell command or idle and for how long, how much of its context window it
# has used, how fast it is generating tokens, and what it costs the machine. The account's week sits at
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
#   cpu, memory     ps
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

# readings -> one line per session, "<sid> <used> <window> <tokens in the last minute> <series>" with
# the fields separated by \x1f (a tab would be swallowed by `read` where a field is empty), the last
# two empty where no row has ever carried a total; and the new $CACHE/burn.json.
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
        | {sid: $r.sid, used: $r.used, window: $r.window, buckets: $b,
           has: ($r.total != null or $p.total != null),
           next: {total: (if $r.total != null and $r.ts >= $p.at then $r.total else $p.total end),
                  at: ([$r.ts, $p.at] | max), buckets: $b}})
    | (map(. as $e | "\($e.sid)\u001f\($e.used // "")\u001f\($e.window)\u001f"
          + (if $e.has then
               # the last 60 s: this minute so far, plus the part of last minute still inside it
               (((($e.buckets[$cur | tostring]) // 0)
                 + ((($e.buckets[($cur - 1) | tostring]) // 0) * (60 - ($now % 60)) / 60)) | floor | tostring)
               + "\u001f" + ([range(0; $mins) | ($cur - $mins + 1 + .) | tostring | ($e.buckets[.] // 0) | tostring] | join(","))
             else "\u001f" end))
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

  # cpu and resident memory for every agent pid in one call
  declare -A CPU RSS
  local pids=""
  for n in "${!L_PID[@]}"; do pids+="${pids:+,}${L_PID[$n]}"; done
  if [ -n "$pids" ]; then
    while read -r p c r; do [ -n "${p:-}" ] && { CPU[$p]=$c; RSS[$p]=$r; }; done \
      < <(ps -o pid=,%cpu=,rss= -p "$pids" 2>/dev/null)
  fi

  # What the publisher wrote for every session, keyed by session id.
  declare -A C_USED C_WIN C_RATE C_SER
  local used win rate ser
  while IFS=$'\x1f' read -r sid used win rate ser; do
    [ -n "$sid" ] || continue
    C_USED[$sid]=$used; C_WIN[$sid]=$win; C_RATE[$sid]=$rate; C_SER[$sid]=$ser
  done < <(readings)

  # Collect each agent's numbers first: the sparkline ceiling has to be shared across agents for the
  # heights to mean anything side by side.
  local names=() roles=() ctxs=() rates=() series=() ceil=1
  while IFS=$'\t' read -r name role kind; do
    [ -n "$name" ] || continue
    # A developer or tester with no running session is on the bench (scripts/agent-bench.sh) until it is
    # spawned for its next ticket: not shown. Every other role reads "not started" when it is down.
    case "$role" in developer|tester) [ -n "${L_PID[$name]:-}" ] || continue ;; esac
    local ctx="" rate="" ser=""
    if [ -n "${L_SID[$name]:-}" ]; then
      sid=${L_SID[$name]}
      ctx=${C_USED[$sid]:-}; rate=${C_RATE[$sid]:-}; ser=${C_SER[$sid]:-}
      local v
      for v in ${ser//,/ }; do [ "${v:-0}" -gt "$ceil" ] 2>/dev/null && ceil=$v; done
    fi
    names+=("$name"); roles+=("$(short_role "$role")")
    ctxs+=("${ctx:-}"); rates+=("${rate:-}"); series+=("${ser:-}")
  done < <(roster)

  # ── header
  printf '%s%-*s%s%s\n' "$BOLD$CYAN" $(( W - 6 )) " TEAM" "$(TZ=${TZ:-} date -d "@$now" '+%H:%M' 2>/dev/null || date '+%H:%M')" "$R"
  rule
  week_line "${week:--1}"
  rule

  # ── one agent per three lines
  local i
  for i in "${!names[@]}"; do
    local name=${names[$i]} role=${roles[$i]}
    local ctx=${ctxs[$i]} rate=${rates[$i]} ser=${series[$i]}
    local pid=${L_PID[$name]:-} status=${L_STATUS[$name]:-} since=${L_SINCE[$name]:-0}
    local flag=" " namecol="$BOLD" dot state

    if [ -z "$pid" ]; then
      # On the roster but not running.
      printf '%s %-9s %s%s\n' "$GREY" "${name:0:9}" "$role" "$R"
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

    # A long wait flags the row; high context shows only in the gauge's colour.
    if [ "$status" = waiting ] && [ "$held" -ge "$WAIT_ALERT" ]; then flag="${AMBER}?${R}"; namecol="$BOLD$AMBER"; fi

    local mem=""
    [ -n "${RSS[$pid]:-}" ] && mem=$(printf '%d.%dG' $(( RSS[$pid] / 1048576 )) $(( RSS[$pid] % 1048576 * 10 / 1048576 )))
    printf '%s%s%-9s%s %s%-7s%s %s%6s %4s%%%s\n' "$flag" "$namecol" "${name:0:9}" "$R" \
      "$DIM" "$role" "$R" "$GREY" "$mem" "${CPU[$pid]:-0}" "$R"
    local line2
    line2=$(printf ' %s %-9s %s' "$dot" "$state $(ago "$held")" "$ctxtxt")
    printf '%s\n' "${line2%"${line2##*[![:space:]]}"}"
    if [ -n "$ser" ]; then
      printf ' %s %s%s/m%s\n' "$(spark "$ser" "$ceil")" "$DIM" "$(compact "${rate:-0}")" "$R"
    else
      # Live, but no row has carried a token total yet: the publisher has not refreshed with one.
      printf ' %sno reading yet%s\n' "$DIM" "$R"
    fi
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
  row() { printf '{"agent":"Ed","session_id":"s1","ts":"%s","context":{"remaining_pct":50,"window":500000,"used":%s},"tokens":{"output_total":%s},"activity":"working","five_hour":{"used_pct":9},"week":{"used_pct":70}}\n' \
            "$(date -u -d "@$1" +%FT%TZ)" "$2" "$3" > "$CONTEXT_DIR/s1.json"; }
  row $((NOW-200)) 200000 1000
  t $'s1\x1f200000\x1f500000\x1f0\x1f0,0,0,0,0' 'readings: the first sample sets the total and draws nothing' "$(readings)"
  row $((NOW-100)) 201000 1600
  t $'s1\x1f201000\x1f500000\x1f0\x1f0,0,600,0,0' 'readings: growth lands in the minute the row was written' "$(readings)"
  row $((NOW-5)) 202000 1900
  t $'s1\x1f202000\x1f500000\x1f300\x1f0,0,600,300,0' 'readings: a second sample adds its own bucket and the last-minute rate' "$(readings)"
  t $'s1\x1f202000\x1f500000\x1f300\x1f0,0,600,300,0' 'readings: an unchanged row adds nothing' "$(readings)"
  printf '{"agent":"Vera","session_id":"s2","ts":"%s","context":{"remaining_pct":50},"activity":"idle"}\n' "$(date -u -d "@$((NOW-5))" +%FT%TZ)" > "$CONTEXT_DIR/s2.json"
  t $'s2\x1f\x1f0\x1f\x1f' 'readings: a row without the figures keeps its empty fields in place' "$(readings | grep '^s2')"
  t 70 'week: the weekly figure from the rows' "$(w=$(week_used); echo "${w%% *}")"
  printf 'not json at all\n' > "$CONTEXT_DIR/junk.json"
  t 70 'week: a file that is not JSON is dropped, not fatal to the frame' "$(w=$(week_used); echo "${w%% *}")"

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
