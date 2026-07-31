#!/usr/bin/env bash
# Claude Code status line — model letter · cwd · context gauge · weekly-limit gauge.
#
# Layout:  O  ~/dev/strength ⑂wt   ctx ██░░░░░░░░ 93%   wk █████████░ 9%
#
# Both bars read the SAME way: filled segments = consumed, the number = REMAINING,
# and the colour goes green → amber → red as that remaining figure shrinks. So a
# short green bar is healthy and a long red one means you are nearly out.
#   ctx = this session's context window (compact when it reddens)
#   wk  = the 7-day all-models rate limit (nothing to do but wait when it reddens)
# Fed a JSON blob on stdin (see: code.claude.com/docs/en/statusline.md).

in=$(cat)

if command -v jq >/dev/null 2>&1; then
  mid=$(jq -r '.model.id // ""' <<<"$in")
  mname=$(jq -r '.model.display_name // ""' <<<"$in")
  dir=$(jq -r '.workspace.current_dir // .cwd // ""' <<<"$in")
  rem=$(jq -r '.context_window.remaining_percentage // empty' <<<"$in")
  branch=$(jq -r '.workspace.git_worktree // empty' <<<"$in")
  wkused=$(jq -r '.rate_limits.seven_day.used_percentage // empty' <<<"$in")
  cwsize=$(jq -r '.context_window.context_window_size // empty' <<<"$in")
  sid=$(jq -r '.session_id // empty' <<<"$in")
else
  mid=""; mname=""; dir="$PWD"; rem=""; branch=""; wkused=""; cwsize=""; sid=""
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

# Long-context variants ("Opus 5" vs "Opus 5 (1M context)") share a display name once
# the parenthetical is stripped, so tag the model from the MEASURED window instead —
# that stays right whatever a future variant calls itself. Standard is 200k.
cw=${cwsize%.*}
if [ -n "$cw" ] && [ "$cw" -gt 200000 ] 2>/dev/null; then
  if [ $(( cw % 1000000 )) -eq 0 ]; then tag="$(( cw / 1000000 ))M"
  else                                   tag="$(( cw / 1000 ))k"; fi
  m="$m $tag"
fi

rawdir=$dir          # keep the real path — .agent/ lookups below need it
dir=${dir/#$HOME/\~}

r=$'\033[0m'; dim=$'\033[2m'; cyan=$'\033[36m'

# gauge <remaining-%> -> "<bar> <n>%" coloured by how much is left.
gauge() {
  local left=$1 used fill i bar c
  left=${left%.*}; left=${left:-100}
  [ "$left" -gt 100 ] 2>/dev/null && left=100
  [ "$left" -lt 0 ]   2>/dev/null && left=0
  used=$(( 100 - left ))

  fill=$(( (used + 5) / 10 )); [ "$fill" -gt 10 ] && fill=10; [ "$fill" -lt 0 ] && fill=0
  bar=""; for ((i = 0; i < 10; i++)); do [ "$i" -lt "$fill" ] && bar+="█" || bar+="░"; done

  if   [ "$left" -le 15 ]; then c=$'\033[31m'   # red   — nearly out
  elif [ "$left" -le 30 ]; then c=$'\033[33m'   # amber — getting tight
  else                         c=$'\033[32m'; fi # green — healthy

  printf '%s%s %s%%%s' "$c" "$bar" "$left" "$r"
}

ctx=$(gauge "${rem:-100}")

wt=""; [ -n "$branch" ] && wt=" ${dim}⑂${branch}${r}"

# The weekly gauge only appears when the payload carries the rate-limit block.
wk=""
if [ -n "$wkused" ]; then
  wk=$(printf '  %swk%s %s' "$dim" "$r" "$(gauge $(( 100 - ${wkused%.*} )) )")
fi

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

# A SESSION WITH NO NAME DEGRADES HONESTLY: it lists every gate, each tagged
# with its worktree, exactly as before this scoping existed. It does NOT guess.
#
# Process ancestry was tried here and removed. It is the obvious idea — a gate
# you launched is a descendant of your `claude` — and it is unreliable in both
# directions: one of three live gates had already been reparented to init and
# had no chain to walk, and a backgrounded gate's own bash proved awkward to
# match at all. An indicator whose whole job is answering "is MY run alive?"
# cannot be built on a check that quietly says no. Naming the worktree costs one
# file and is exact; guessing badly is worse than not guessing.

# ── background gates ─────────────────────────────────────────────────────────
# A long-running gate, while it is alive, so a silent session is visibly
# distinguishable from a stopped one — the thing you cannot otherwise tell.
# ABSENT means nothing is running: that is the signal, not a rendering gap.
#
# Free, and that is the whole point: the status line renders locally and never
# enters the model's context, so watching a gate this way costs no tokens.
#
# ONLY THIS SESSION'S GATE IS NAMED. An earlier cut listed all of them, which in
# four windows meant four identical lists and left the one question — is MINE
# still going? — no easier to answer than before. Other agents' runs collapse to
# a dim count, kept ONLY because contention changes how a red result reads:
# verify.sh warns when it was contended, and this is where you see that coming.
#
# ONE GATE, not one per process. A single verify matches several times over (its
# wrapper shell, the script, and the e2e/UI gates it invokes in turn), so the
# longest-lived match wins — which picks the OUTERMOST gate for free, since the
# wrapping verify has by definition been alive longer than anything it spawned.
job=""; mine=""; unnamed=""
for pat in verify.sh e2e.sh acceptance-ui.sh; do
  for pid in $(pgrep -f "scripts/$pat" 2>/dev/null); do
    # THE SCRIPT MUST BE AN ARGUMENT, NOT A MENTION. `pgrep -f` matches the whole
    # command line, so a `bash -c '... scripts/e2e.sh ...'` wrapper — which is how
    # every agent-issued command is shaped — counted as a live gate. Caught in
    # testing: the bar showed `⏳ e2e 0m00s` for a run that had not started yet.
    # A phantom "still working" is the exact lie this indicator exists to prevent,
    # so require the script to appear as its own argv entry and reject any `-c`.
    # `cat |` rather than `< file`, because a gate can EXIT between pgrep and this
    # read: a failed `<` redirect is the SHELL's error and escapes tr's 2>/dev/null,
    # leaking "No such file or directory" into the bar. Observed, not theorised.
    argv=$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' '\n')
    printf '%s\n' "$argv" | /usr/bin/grep -qx -- '-c' && continue
    printf '%s\n' "$argv" | /usr/bin/grep -qE "(^|/)scripts/$pat$" || continue
    gdir=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    [ -n "$gdir" ] || continue
    gname=$(cat "$gdir/.agent/name" 2>/dev/null)
    secs=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$secs" ] || continue

    if [ -z "$me" ]; then
      # No name for this session — list everything, tagged, and claim nothing.
      unnamed="$unnamed${pat%.sh} $(basename "$gdir") $secs"$'\n'
    elif [ -n "$gname" ] && [ "${gname,,}" = "${me,,}" ]; then
      mine="$mine${pat%.sh} $secs"$'\n'
    fi
    # Anything else belongs to another agent and is not shown. An earlier cut
    # added a dim "N others on the box" for reading a contended result; the owner
    # does not want it (2026-07-31). Neighbours' load stays out of this bar.
  done
done

# EVERY gate of MINE, one entry per script, longest-lived first. Not collapsed to
# a single line, because a verify SPAWNS the others — so "verify 5m12s ·
# acceptance-ui 0m48s" says both that it is alive and which stage it reached.
# Deduped by script name, since one run matches as several processes.
if [ -n "$mine" ]; then
  while read -r jpat jsecs; do
    [ -n "$jpat" ] || continue
    printf -v seg '\033[33m⏳ %s %dm%02ds\033[0m  ' "$jpat" $(( jsecs / 60 )) $(( jsecs % 60 ))
    job+="$seg"
  done < <(printf '%s' "$mine" | awk 'NF { if ($2+0 > m[$1]) m[$1]=$2+0 }
                                       END { for (k in m) print k, m[k] }' | sort -k2 -nr)
fi

# Unnamed session: one row per worktree, longest-lived match wins.
if [ -z "$me" ] && [ -n "$unnamed" ]; then
  n=0
  while read -r jpat jdir jsecs; do
    [ -n "$jpat" ] || continue
    n=$(( n + 1 )); [ "$n" -le 3 ] || continue
    printf -v seg '\033[33m⏳ %s %s %dm%02ds\033[0m  ' \
      "$jpat" "$jdir" $(( jsecs / 60 )) $(( jsecs % 60 ))
    job+="$seg"
  done < <(printf '%s' "$unnamed" | awk 'NF { if ($3+0 > m[$2]) { m[$2]=$3+0; p[$2]=$1 } }
                                          END { for (k in m) print p[k], k, m[k] }' | sort -k2)
fi

# THE NAME IS ALWAYS SHOWN, including when there isn't one. An agent can rename
# itself mid-session, and the bar reading it live from .agent/name is the point:
# it reflects what the agent currently calls itself, not what it was called at
# startup. A session with no name says so rather than showing a blank, because
# "unnamed" is itself worth seeing — init.sh requires a name, and gate scoping
# below falls back to listing everyone's when there is none to match on.
if [ -n "$me" ]; then printf -v nm '  \033[35m%s\033[0m' "$me"
else                  printf -v nm '  %sunnamed%s' "$dim" "$r"; fi

printf '%s%s%s%s  %s%s%s%s  %sctx%s %s%s' \
  "$dim" "$m" "$r" "$nm" "$cyan" "$dir" "$r" "$wt" "$dim" "$r" "$ctx" "$wk"

# Gates get their OWN ROW, and only when one is running — so the bar stays a
# single line at rest and grows a second only when there is something to report.
# The extra row appearing is itself the signal. Docs note multi-line output with
# escape codes is likelier to garble than single-line, which is the other reason
# not to make this row permanent. No trailing newline: that would render a blank
# row. (Requires statusLine.refreshInterval in settings.json — event-driven
# updates go quiet exactly when the session is idle waiting on a gate, which is
# the moment this is for.)
[ -n "$job" ] && printf '\n%s' "${job%  }"

# EXIT 0 EXPLICITLY, and never remove this. The line above is a bare `test &&`,
# so with no gate running it evaluates false and becomes the script's exit
# status — a non-zero status makes Claude Code render NOTHING, so the bar worked
# only while a gate was alive and went blank the rest of the time. Any future
# last-line conditional has the same trap; this makes it harmless.
exit 0
