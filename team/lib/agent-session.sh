#!/usr/bin/env bash
# team/lib/agent-session.sh — is a rostered agent's session running, and in what state.
# Sourced by team/agent-spawn.sh and team/agent-bench.sh; it parses no arguments, and its arms
# run inside those two scripts' self-tests.
#
# A session is RUNNING when either holds:
#   - the tmux session `<project>-<name, lowercased>` exists (the one agent-spawn.sh starts), or
#   - a Claude Code record ~/.claude/sessions/<pid>.json has a live pid whose process carries the
#     name's roster address in GIT_AUTHOR_EMAIL (read from /proc/<pid>/environ), or, where /proc
#     cannot be read, whose record is named <name>. This finds a session started by hand from the
#     launch line, which has no tmux session of agent-spawn's making.
# The record is what says whether it is mid-turn (`status`) and when it started (`startedAt`, ms).
# A record counts only while its process is the session's own: Claude Code leaves a crashed session's record
# behind, and its pid can be reused, so the process must have started no later than `startedAt` (a minute's
# grace). A process that took the pid over started after the record was written.
#
# Needs: jq, roster.sh sourced first (roster_lookup_email, roster_email_of_name), HARNESS_PROJECT.

# The tmux session and the worktree an agent's session uses: one name for both.
agent_session_name() { printf '%s-%s\n' "${HARNESS_PROJECT:?}" "${1,,}"; }

# agent_session_pid_since <pid> <startedAt-ms> -> 0 when the process started no later than the session did.
agent_session_pid_since() {
  local el
  # ps's etime is [[dd-]hh:]mm:ss on Linux and macOS alike
  el=$(ps -o etime= -p "$1" 2>/dev/null | awk '{ n = split($1, a, /[-:]/); s = a[n] + 60 * a[n-1]
    if (n > 2) s += 3600 * a[n-2]; if (n > 3) s += 86400 * a[n-3]; print s }')
  [[ "$el" =~ ^[0-9]+$ && "$2" =~ ^[0-9]+$ ]] && (( $(date +%s) - el <= $2 / 1000 + 60 ))
}

agent_session_tmux_up() { # <name>
  command -v tmux >/dev/null 2>&1 || return 1
  tmux has-session -t "=$(agent_session_name "$1")" 2>/dev/null
}

# agent_session_record <name> -> "pid<TAB>status<TAB>startedAt-ms" of the newest live record that is
# this agent's, or nothing. `status` is empty where the record carries none.
agent_session_record() { # <name>
  local name="$1" email dir f pid rname status started env_email best="" best_t=-1
  email="$(roster_lookup_email "$name")"; [[ -n "$email" ]] || email="$(roster_email_of_name "$name")"
  dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"
  for f in "$dir"/*.json; do
    [[ -r "$f" ]] || continue
    pid=${f##*/}; pid=${pid%.json}
    [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || continue
    IFS=$'\x1f' read -r rname status started < <(
      jq -r '[(.name // ""), (.status // ""), ((.startedAt // 0) | tostring)] | join("\u001f")' "$f" 2>/dev/null)
    env_email=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^GIT_AUTHOR_EMAIL=//p' | head -1)
    if [[ -n "$env_email" ]]; then [[ "${env_email,,}" == "${email,,}" ]] || continue
    else [[ -n "$rname" && "${rname,,}" == "${name,,}" ]] || continue; fi
    [[ "${started:-0}" =~ ^[0-9]+$ ]] || started=0
    agent_session_pid_since "$pid" "$started" || continue
    (( started > best_t )) && { best_t=$started; best="$pid"$'\t'"$status"$'\t'"$started"; }
  done
  [[ -n "$best" ]] && printf '%s\n' "$best"
  return 0
}

agent_session_running() { # <name>
  agent_session_tmux_up "$1" && return 0
  [[ -n "$(agent_session_record "$1")" ]]
}
