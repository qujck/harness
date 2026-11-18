#!/usr/bin/env bash
# team/agent-stopped.sh — records that the calling agent has stopped for a team shutdown, at a clean point with its
# durable record up to date. It puts "<Name><TAB><now>" in the stop file, ~/.local/state/<project>/team-up, replacing
# any earlier line for that name. The team page acts on it: it closes the agent's pane once the turn that ran this
# ends (the lead's only once every other team agent has stopped), and the team's next Start brings back exactly the
# agents in the file.
#
#   bash team/agent-stopped.sh                # the name is $AGENT_NAME, else the Claude session this runs under
#   bash team/agent-stopped.sh --self-test
#
# Exits 1, printing why on stderr, with no name or if the file cannot be written; 2 for any argument.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"

selftest() {
  local fails=0 T F
  T=$(mktemp -d); trap 'rm -rf "$T"' RETURN
  F="$T/.local/state/p/team-up"
  check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
  HOME=$T HARNESS_PROJECT=p AGENT_NAME=Ada bash "$_here/agent-stopped.sh" >/dev/null; check "records the agent" "$(cut -f1 "$F")" Ada
  HOME=$T HARNESS_PROJECT=p AGENT_NAME=Lea bash "$_here/agent-stopped.sh" >/dev/null
  HOME=$T HARNESS_PROJECT=p AGENT_NAME=Ada bash "$_here/agent-stopped.sh" >/dev/null
  check "one line a name, the newest last" "$(cut -f1 "$F" | paste -sd,)" "Lea,Ada"
  check "  with the time" "$(awk -F'\t' '$2 ~ /^[0-9]+$/' "$F" | wc -l | tr -d ' ')" 2
  (cd "$T" && HOME=$T HARNESS_PROJECT=p AGENT_NAME= bash "$_here/agent-stopped.sh" >/dev/null 2>&1); check "no name is refused" "$?" 1
  bash "$_here/agent-stopped.sh" --now >/dev/null 2>&1; check "an argument is refused" "$?" 2
  [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; return 1; }
}
if selftest_requested "$@"; then selftest; exit $?; fi
[ $# -eq 0 ] || { echo "agent-stopped: takes no arguments" >&2; exit 2; }

name=${AGENT_NAME:-}
if [ -z "$name" ]; then   # the name of the nearest ancestor that is a named Claude session
  pid=$$
  while [ -z "$name" ] && [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    f="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions/$pid.json"
    [ -r "$f" ] && name=$(jq -r '.name // empty' "$f" 2>/dev/null) && name=${name#/}
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
fi
[ -n "$name" ] || { echo "agent-stopped: this is not a named Claude session" >&2; exit 1; }

project=${HARNESS_PROJECT:-$(basename "$(cd "$_here/.." && pwd)")}
F="$HOME/.local/state/$project/team-up"
mkdir -p "$(dirname "$F")" || { echo "agent-stopped: cannot create $(dirname "$F")" >&2; exit 1; }
exec 9>>"$F.lock" || { echo "agent-stopped: cannot lock $F" >&2; exit 1; }
flock 9
{ [ -r "$F" ] && awk -F'\t' -v n="$name" '$1 != n' "$F"; printf '%s\t%s\n' "$name" "$(date +%s)"; } > "$F.$$.tmp" \
  && mv -f "$F.$$.tmp" "$F" || { echo "agent-stopped: cannot write $F" >&2; exit 1; }
echo "$name: stopped; your pane closes once this turn ends"
