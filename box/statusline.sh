#!/usr/bin/env bash
# Claude Code status line — trimmed to the agent's name and activity (owner, 2026-11-12: "I no longer use the
# terminal"; it ran every 5 s in every session, 0.7-2 s and ~0.9 CPU-s a run, mostly walking every process for
# gates). Its real job is the publish at the end: each session's context, activity and limits, which the team
# page reads. The bars, the gate row and the CI-watch row went; git history has them.
#
# Layout:  Opus 5.5 1M  boozer  ● working
# Fed a JSON blob on stdin (see: code.claude.com/docs/en/statusline.md).

in=$(cat)

if command -v jq >/dev/null 2>&1; then
  eval "$(jq -r '@sh "mid=\(.model.id // "") mname=\(.model.display_name // "") dir=\(.workspace.current_dir // .cwd // "") rem=\(.context_window.remaining_percentage // "") cwsize=\(.context_window.context_window_size // "") sid=\(.session_id // "") tpath=\(.transcript_path // "")"' <<<"$in")"
else
  mid=""; mname=""; dir="$PWD"; rem=""; cwsize=""; sid=""; tpath=""
fi

# ── model → "<family> <version>" ──────────────────────────────────────────────
# display_name carries a parenthetical variant we do not want on the bar
# ("Opus 5 (1M context)" -> "Opus 5"); a leading "Claude " is redundant here too.
m=$mname
m=${m#Claude }
m=${m%% (*}
m=${m%"${m##*[![:space:]]}"}          # trim any trailing whitespace

if [ -z "$m" ]; then                  # no display_name — rebuild from the id
  probe=$(printf '%s' "$mid" | tr '[:upper:]' '[:lower:]')
  case "$probe" in
    *opus*)   m="Opus" ;;
    *sonnet*) m="Sonnet" ;;
    *haiku*)  m="Haiku" ;;
    *fable*)  m="Fable" ;;
    *)        m="?" ;;
  esac
  # claude-opus-5[1m] / claude-haiku-4-5-20251001 -> the version between family and date
  ver=$(printf '%s' "$probe" \
        | sed -E 's/\[[^]]*\]//; s/-[0-9]{8}$//; s/^claude-(opus|sonnet|haiku|fable)-?//; s/-/./g')
  [ -n "$ver" ] && [ "$m" != "?" ] && m="$m $ver"
fi

# The auto-compact window caps where compaction fires, but the payload still reports
# the model's full window (1M stays 1M at 500k). A running session does NOT reload
# autoCompactWindow from settings.json: /autocompact shows the file's value, but after
# settings went 300k -> 250k every session kept compacting at ~267k, the 300k point
# (compaction fires ~33k short of the window). So the session's window is:
#   1. the last "Auto-compact window … <n>k|m tokens" line in this transcript, else
#   2. the settings value as this script first saw it for the session (its start), else
#   3. the model's own window.
# Transcripts run to 600 MB, so this is cached per session as
# "<transcript value|-> <bytes scanned> <unused> <settings value at start|->" and only
# the bytes appended since are scanned.
acw=""
if [ -n "$sid" ] && [ -f "$tpath" ]; then
  _cf="$HOME/.local/state/claude-compact/$sid"
  _cv=""; _off=0; _x=0; _sv=""
  { read -r _cv _off _x _sv < "$_cf"; } 2>/dev/null
  if [ -z "$_sv" ]; then
    _sv=$(jq -r '.autoCompactWindow // empty' "$HOME/.claude/settings.json" 2>/dev/null); _sv=${_sv%.*}
  fi
  _sz=$(stat -c %s "$tpath" 2>/dev/null || echo 0)
  [ "${_off:-0}" -gt "$_sz" ] 2>/dev/null && { _cv=""; _off=0; }
  _hit=$(tail -c +$(( ${_off:-0} + 1 )) "$tpath" 2>/dev/null | head -c $(( _sz - ${_off:-0} )) \
         | LC_ALL=C command grep -a -o '"content":"<local-command-stdout>Auto-compact window [^<"]*tokens' | tail -n 1)
  if [ -n "$_hit" ]; then
    _cv=$(printf '%s' "$_hit" | sed -E 's/.* ([0-9.]+)([kKmM]) tokens.*/\1 \2/' \
          | awk '{u=tolower($2)=="m"?1000000:1000; printf "%d", $1*u}')
  fi
  mkdir -p "${_cf%/*}" 2>/dev/null && printf '%s %s 0 %s\n' "${_cv:--}" "$_sz" "${_sv:--}" > "$_cf" 2>/dev/null
  [ "$_cv" = "-" ] && _cv=""; [ "$_sv" = "-" ] && _sv=""
  acw=${_cv:-$_sv}
fi
cw=${cwsize%.*}
if [ -n "$acw" ] && [ -n "$cw" ] && [ "$acw" -lt "$cw" ] 2>/dev/null; then
  if [ -n "$rem" ]; then
    _used=$(( (100 - ${rem%.*}) * cw / 100 ))             # tokens in context now
    rem=$(( 100 - _used * 100 / acw )); [ "$rem" -lt 0 ] && rem=0
  fi
  cw=$acw; capped=1
fi

# Long-context variants ("Opus 5" vs "Opus 5 (1M context)") share a display name once
# the parenthetical is stripped, so tag the model from the MEASURED window instead —
# that stays right whatever a future variant calls itself. Standard is 200k.
if [ -n "$cw" ] && { [ "$cw" -gt 200000 ] || [ -n "${capped:-}" ]; } 2>/dev/null; then
  if [ $(( cw % 1000000 )) -eq 0 ]; then tag="$(( cw / 1000000 ))M"
  else                                   tag="$(( cw / 1000 ))k"; fi
  m="$m $tag"
fi

rawdir=$dir          # keep the real path — .agent/ lookups below need it
r=$'\033[0m'; dim=$'\033[2m'

# ── who this session is ──────────────────────────────────────────────────────
# One script is shared by every session, but each session runs its OWN copy
# against its own stdin — so "mine" is answerable, and four windows showing all
# four agents' gates was just four copies of the same noise.
#
# RESOLVED PER SESSION, NOT PER DIRECTORY, and that distinction is the whole fix. Several agents can
# share one cwd: gwen, simon and otto all reported workspace.current_dir = /home/peter/dev/strength
# while each worked in its own worktree, so a name written there named ALL of them. (Observed live —
# two agents' bars showed a third agent's name. James was unaffected only because his session really
# does run inside his worktree.)
#
# Order, most specific first:
#   1. $AGENT_NAME        — set per terminal before launching claude. Unambiguous, and the same
#                           variable init.sh already honours (.agent/name > $AGENT_NAME > prompt).
#   2. session-id mapping — ~/.claude/agent-names/<session_id>, which an agent can write for itself.
#   3. .agent/name in cwd — correct ONLY when the session's cwd is its own worktree, and now only used
#                           when no LIVE registered session claims that directory. Last because it is
#                           the one that misfires when a cwd is shared, which is the common case.
#
# Steps 2a and 3 both hardened by fix_statusline_cwd_fallback_names_the_wrong_agent: 2a now honours the
# worktree stored beside the name (a recycled pid is detectable), and 3 no longer guesses over the top
# of a directory somebody else has registered. An unresolvable session reads "unnamed" — the honest
# answer, and the one the init.sh half's DoD asked for.
me=${AGENT_NAME:-}

# (2a) THE SESSION'S `claude` PID — written by scripts/init.sh, which already requires every agent to
# be named and runs inside the session, so it can reach the same process from the other direction.
# This is the one that should normally fire: the name is captured where it is already being demanded,
# instead of anywhere else having to know about status lines.
if [ -z "$me" ]; then
  p=$PPID
  for _ in 1 2 3 4 5 6 7 8; do
    [ -r "/proc/$p/comm" ] || break
    if [ "$(cat "/proc/$p/comm" 2>/dev/null)" = "claude" ]; then
      _map="$HOME/.claude/agent-names/pid-$p"
      if [ -r "$_map" ]; then
        _cand=$(cut -f1 "$_map" 2>/dev/null)
        _root=$(cut -f2 "$_map" 2>/dev/null)
        # THE SECOND FIELD IS THE RECYCLED-PID CHECK, and it was being dropped on the floor. init.sh
        # stores the worktree beside the name precisely "so a RECYCLED pid is detectable rather than
        # silently wrong" — Linux reuses pids, and a box running many short agent sessions will
        # eventually hand a new session a pid some dead agent registered. A mapping whose worktree no
        # longer exists cannot be this session's, so it is discarded rather than worn.
        #
        # NOT compared against the cwd, deliberately: a mapping pointing somewhere OTHER than the cwd is
        # the normal case and the entire reason this lookup exists (gwen/simon/otto all report the
        # shared checkout while working in their own worktrees). Only ABSENCE is evidence.
        # An old single-field mapping has no worktree to check, so it is still trusted.
        if [ -n "$_cand" ] && { [ -z "$_root" ] || [ -d "$_root" ]; }; then
          me=$_cand
        fi
      fi
      break
    fi
    p=$(awk '{print $4}' "/proc/$p/stat" 2>/dev/null)
    case "$p" in ""|0|1) break ;; esac
  done
fi

# (2b) A session-id mapping, for a session that never ran init.sh in its own worktree.
if [ -z "$me" ] && [ -n "$sid" ] && [ -r "$HOME/.claude/agent-names/$sid" ]; then
  me=$(cat "$HOME/.claude/agent-names/$sid" 2>/dev/null)
fi

# (3) `.agent/name` in the cwd — KEPT, but only when nothing contradicts it.
#
# THE DECISION, WRITTEN DOWN because leaving this step as it was is what produced the original
# "three bars said Otto": ranked-last is not the same as harmless. A session with no pid mapping — one
# that never ran init.sh, or whose init.sh was correctly REFUSED because the directory was already
# occupied — fell straight through to here and rendered the INCUMBENT'S name. That is worse than no
# name, because it looks authoritative.
#
# Dropping the step outright would have cost the case it genuinely serves: a lone agent working inside
# its own worktree that never registered. So it is CORROBORATED instead. If a LIVE registered session
# already claims this directory as its worktree, then this directory's `.agent/name` is that agent's
# name, and we are demonstrably not them (we would have matched on our own pid above). Say nothing.
#
# Worked example, from the run that raised this: nadia registered /home/peter/dev/strength and is live,
# so a second session sitting in that directory now reads "unnamed" instead of "nadia". Meanwhile
# gwen/simon/otto register their OWN worktrees, so none of them claims the shared checkout and a solo
# agent there still gets named. (fix_statusline_cwd_fallback_names_the_wrong_agent)
if [ -z "$me" ] && [ -n "$rawdir" ]; then
  _here=$(readlink -f "$rawdir" 2>/dev/null)
  _claimed=""
  for _f in "$HOME"/.claude/agent-names/pid-*; do
    [ -r "$_f" ] || continue
    _pid=${_f##*/pid-}
    [ -d "/proc/$_pid" ] || continue          # a dead session claims nothing
    _r=$(cut -f2 "$_f" 2>/dev/null)
    [ -n "$_r" ] || continue
    if [ "$(readlink -f "$_r" 2>/dev/null)" = "$_here" ]; then
      _claimed=1
      break
    fi
  done
  if [ -z "$_claimed" ]; then
    me=$(cat "$rawdir/.agent/name" 2>/dev/null)
  fi
fi

# SELF-DISCOVERY. An agent cannot register itself under (2) without knowing its own session_id, and
# nothing hands it that. So an unnamed session drops the id here, where the agent can read it and
# write its own mapping — no guessing, no asking the human to fish it out of a path.
if [ -z "$me" ] && [ -n "$sid" ]; then
  mkdir -p "$HOME/.claude/agent-names" 2>/dev/null
  printf '%s\n' "$sid" > "$HOME/.claude/agent-names/.unnamed-$sid" 2>/dev/null
fi


# ── is this agent WORKING right now? ─────────────────────────────────────────
# (owner, 2026-09-28: pages typed into the input box pile up while an agent is busy, and clearing
# them with Esc would interrupt a working agent — so the bar must say whether it is working, without
# anyone scrolling up to look.)
#
# The hooks in ~/.claude/settings.json (activity-hook.sh) record the state directly:
#   working  a turn is in progress, however long its current tool call runs
#   waiting  blocked on the owner: a permission prompt or a question is on screen
#   idle     the turn ended, shown with how long ago
# (owner, 2026-10-03: the earlier transcript-mtime rule showed agents as idle while they were
# waiting — a long tool call or a permission prompt writes nothing to the transcript.)
# Esc fires no hook, so a "working" whose transcript ends in the interrupt marker is idle.
# A session that has fired no hook yet (mid-turn when the hooks were installed, or an older
# runtime) has no state file and falls back to reading the transcript.
act=""; act_state="unknown"; act_idle_s=""; _n=$(date +%s)
_sf="$HOME/.local/state/claude-activity/$sid"
if [ -n "$sid" ] && { read -r _st _ts < "$_sf"; } 2>/dev/null && [ -n "$_ts" ]; then
  if [ "$_st" = working ] && [ -n "$tpath" ] && tail -n 3 "$tpath" 2>/dev/null | /usr/bin/grep -q '\[Request interrupted by user'; then
    _st=idle; _ts=$(stat -c %Y "$tpath" 2>/dev/null || echo "$_ts")
  fi
  act_state=$_st
  [ "$_st" = idle ] && act_idle_s=$(( _n - _ts ))
elif [ -n "$tpath" ] && [ -r "$tpath" ]; then
  _m=$(stat -c %Y "$tpath" 2>/dev/null)
  if [ -n "$_m" ]; then
    act_idle_s=$(( _n - _m ))
    # A tool call still running leaves its tool_use as the last conversation entry,
    # with no tool_result after it — so that also counts as working.
    _last=$(tail -n 60 "$tpath" 2>/dev/null | jq -rc 'select(.type=="assistant" or .type=="user")
             | [.type, ([.message.content[]?|.type?] | last // "")] | join(":")' 2>/dev/null | tail -n 1)
    if [ "$act_idle_s" -le 20 ] || [ "$_last" = "assistant:tool_use" ]; then act_state=working; act_idle_s=""
    else act_state=idle; fi
  fi
fi
case "$act_state" in
  working) printf -v act '  \033[32m● working\033[0m' ;;
  waiting) printf -v act '  \033[1;33m◆ waiting on you\033[0m' ;;
  idle)
    if [ "$act_idle_s" -ge 3600 ]; then _ago="$(( act_idle_s / 3600 ))h"
    elif [ "$act_idle_s" -ge 60 ]; then _ago="$(( act_idle_s / 60 ))m"
    else _ago="${act_idle_s}s"; fi
    printf -v act '  %s○ idle %s%s' "$dim" "$_ago" "$r" ;;
esac

# ── publish this session's context for the other agents ──────────────────────
# (owner, 2026-09-28: "each agent should log their current context where the other agents can see
# it.") The payload reaches only this script, never the model, so this is the one place the number
# can be written down. One small JSON file per session under a shared state dir; every agent on the
# box can read every file. `scripts/agent-context.sh` in the strength repo renders them. Best-effort:
# nothing here may ever break the bar, hence the subshell and the `|| true`.
if [ -n "$sid" ] && command -v jq >/dev/null 2>&1; then
  (
    cdir="$HOME/.local/state/strength/context"
    mkdir -p "$cdir"
    # A running output-token total for the team panel's burn sparkline (harness team/agents-dash.sh,
    # docs/context-publisher.md). The payload carries only the LAST response's output, so a refresh
    # whose (used, output) pair differs from the previous one is a new response and is added.
    used=$(jq -r '.context_window.total_input_tokens // empty' <<<"$in")
    last_out=$(jq -r '.context_window.total_output_tokens // empty' <<<"$in")
    tok="$cdir/.$sid.tokens"; prev_used=""; prev_out=""; out_total=0
    [ -r "$tok" ] && read -r prev_used prev_out out_total < "$tok"
    if [ -n "$used" ] && [ -n "$last_out" ] && { [ "$used" != "$prev_used" ] || [ "$last_out" != "$prev_out" ]; }; then
      out_total=$(( ${out_total:-0} + ${last_out%.*} ))
      printf '%s %s %s\n' "$used" "$last_out" "$out_total" > "$tok.tmp" && mv -f "$tok.tmp" "$tok"
    fi
    jq -c --arg agent "${me:-unnamed}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg cwd "$rawdir" --arg act "$act_state" --arg idle "${act_idle_s:-}" --arg cw "${cw:-}" --arg crem "${rem:-}" \
       --argjson total "${out_total:-0}" --arg has_tokens "${last_out:+1}" \
       '{agent:$agent, session_id:.session_id, ts:$ts, cwd:$cwd, worktree:(.workspace.git_worktree // null), activity:$act, idle_s:($idle|tonumber? // null),
         model:(.model.display_name // .model.id // null), effort:((.effort | objects | .level) // null),
         context:{used_pct:(.context_window.used_percentage // null), remaining_pct:(.context_window.remaining_percentage // null),
                  size:(.context_window.context_window_size // null), input_tokens:(.context_window.total_input_tokens // null),
                  output_tokens:(.context_window.total_output_tokens // null),
                  compact_window:($cw|tonumber? // null), to_compact_pct:($crem|tonumber? // null),
                  used:(.context_window.total_input_tokens // null), window:($cw|tonumber? // null)},
         tokens:{output_total:(if $has_tokens == "1" then $total else null end)},
         week:{used_pct:(.rate_limits.seven_day.used_percentage // null), resets_at:(.rate_limits.seven_day.resets_at // null)},
         five_hour:{used_pct:(.rate_limits.five_hour.used_percentage // null), resets_at:(.rate_limits.five_hour.resets_at // null)}}' \
       <<<"$in" > "$cdir/.$sid.tmp" && mv -f "$cdir/.$sid.tmp" "$cdir/$sid.json"
  ) 2>/dev/null || true
fi

# The name always shows, "unnamed" when there is none: an agent can rename itself mid-session.
if [ -n "$me" ]; then printf -v nm '  \033[35m%s\033[0m' "$me"
else                  printf -v nm '  %sunnamed%s' "$dim" "$r"; fi
printf '%s%s%s%s%s' "$dim" "$m" "$r" "$nm" "$act"

# EXIT 0 EXPLICITLY, and never remove this: a non-zero status makes Claude Code render NOTHING, and any
# future last-line conditional would otherwise become the script's status.
exit 0
