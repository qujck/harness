#!/usr/bin/env bash
# team/agent-containers.sh — an agent's Docker containers: the ones it started for its tickets, found by label.
#
#   bash team/agent-containers.sh <Name>             lists them, one "name<TAB>state" a line
#   bash team/agent-containers.sh <Name> --remove    removes them, with their anonymous volumes, naming each one
#   bash team/agent-containers.sh --leftovers        every rostered agent with no running session that still has
#                                                    containers, one "Name: N (a, b, ...)" a line
#   bash team/agent-containers.sh --self-test
#
# A container is the agent's when it carries the label agents.owner=<Name> (AGENTS.md, "Your Docker containers").
# A container without that label is never touched: the per-agent stacks (agent-stacks.sh) and the infrastructure
# are not labelled, so they are never caught. agent-bench.sh removes an agent's containers as it benches it; the
# lead's start-of-day message names the leftovers.
#
# Exit: 0 done · 2 a usage error.
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
DOCKER="${AGENTS_DOCKER:-docker}"
USAGE="usage: agent-containers.sh <Name> [--remove] | agent-containers.sh --leftovers"

# every labelled container as "name|owner|state"
containers_all() { "$DOCKER" ps -a --filter label=agents.owner --format '{{.Names}}|{{.Label "agents.owner"}}|{{.State}}' 2>/dev/null; }

# PURE: "name|owner|state" lines on stdin -> those whose owner is <Name> (any case), as "name<TAB>state"
containers_of() { # <name>
  awk -F'|' -v n="${1,,}" 'tolower($2) == n && $1 != "" { print $1 "\t" $3 }'
}

containers_self_test() {
  local fails=0 T out rc
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
         else printf '  FAIL %s\n       want %q\n       got  %q\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  T="$(mktemp -d)" || return 2
  trap 'rm -rf "$T"' RETURN

  _t "an agent's containers, by its label in any case" \
     "$(printf 'ada-feat_a-mysql|Ada|running\nrig|ada|exited\nproj-ada-api-1||running\nadam-x|Adam|running\n' | containers_of Ada)" \
     $'ada-feat_a-mysql\trunning\nrig\texited'

  # FIXTURES: a roster, a stand-in docker and tmux, no Claude Code records. Ada is up in tmux; Ben is not running.
  mkdir -p "$T/repo/agents" "$T/bin" "$T/claude/sessions"
  cat > "$T/repo/agents/roster.json" <<'JSON'
{"agents":[
 {"name":"Ada","email":"ada@proj.local","role":"developer","status":"active"},
 {"name":"Ben","email":"ben@proj.local","role":"tester","status":"active"}]}
JSON
  cat > "$T/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps) printf '%s\n' 'ada-feat_a-mysql|Ada|running' 'ben-feat_b-redis|Ben|exited' 'ben-feat_b-uc|Ben|running' ;;
  rm) printf '%s\n' "\$*" >> "$T/rm.log" ;;
esac
EOF
  printf '#!/usr/bin/env bash\n[ "$1" = has-session ] && [ "$3" = "=proj-ada" ]\n' > "$T/bin/tmux"
  chmod +x "$T/bin/docker" "$T/bin/tmux"
  run() { HARNESS_ROOT="$T/repo" HARNESS_PROJECT=proj ROSTER_DOMAIN=proj.local ROSTER_FILE="$T/repo/agents/roster.json" \
            CLAUDE_CONFIG_DIR="$T/claude" PATH="$T/bin:$PATH" AGENTS_DOCKER="$T/bin/docker" bash "$SELF" "$@" 2>&1; }

  _t "lists an agent's containers" "$(run Ben | cut -f1 | paste -sd' ' -)" "ben-feat_b-redis ben-feat_b-uc"
  out="$(run Ben --remove)"
  _t "removal names each" "$(paste -sd' ' - <<<"$out")" "removed ben-feat_b-redis removed ben-feat_b-uc"
  _t "  forcing, with the volumes, and only the agent's" "$(paste -sd' ' - < "$T/rm.log")" "rm -f -v ben-feat_b-redis rm -f -v ben-feat_b-uc"
  _t "leftovers: agents with no running session only" "$(run --leftovers)" "Ben: 2 (ben-feat_b-redis, ben-feat_b-uc)"
  out="$(run)"; rc=$?;            _t "no name is a usage error" "$rc" 2
  out="$(run Ada --frob)"; rc=$?; _t "an unknown argument is a usage error" "$rc" 2
  out="$(run --slef-test)"; rc=$?; _t "a mistyped self-test flag exits 2, never runs" "$rc" 2

  if (( fails == 0 )); then echo "agent-containers --self-test: PASS"; return 0; fi
  echo "agent-containers --self-test: FAIL ($fails)"; return 1
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  [[ $# -eq 1 ]] || { printf 'unknown argument: %s\n' "$2" >&2; exit 2; }
  containers_self_test; exit $?
fi

case "${1:-}" in
  --leftovers)
    [[ $# -eq 1 ]] || { echo "$USAGE" >&2; exit 2; }
    ALL="$(containers_all)"
    while IFS=$'\t' read -r n _; do
      [[ -n "$n" ]] || continue
      agent_session_tmux_up "$n" && continue
      [[ -n "$(agent_session_record "$n")" ]] && continue
      mine="$(containers_of "$n" <<<"$ALL" | cut -f1)"
      [[ -n "$mine" ]] && printf '%s: %s (%s)\n' "$n" "$(grep -c . <<<"$mine")" "$(paste -sd',' - <<<"$mine" | sed 's/,/, /g')"
    done < <(roster_list_known)
    exit 0 ;;
  ""|-*) echo "$USAGE" >&2; exit 2 ;;
esac
NAME=$1
case "${2:-}" in
  "") [[ $# -eq 1 ]] || { echo "$USAGE" >&2; exit 2; }; containers_all | containers_of "$NAME" ;;
  --remove)
    [[ $# -eq 2 ]] || { echo "$USAGE" >&2; exit 2; }
    containers_all | containers_of "$NAME" | while IFS=$'\t' read -r c _; do
      "$DOCKER" rm -f -v "$c" >/dev/null 2>&1 && echo "removed $c" || echo "could not remove $c" >&2
    done ;;
  *) echo "$USAGE" >&2; exit 2 ;;
esac
