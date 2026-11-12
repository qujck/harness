#!/usr/bin/env bash
# team/team-start.sh — start the team after a boot, or only the named agents: the team page's ▶ and a standing
# agent's Start run it.
#
#   bash team/team-start.sh                    start the whole team
#   bash team/team-start.sh --only NAME ...    start only these (repeat --only): those running when the page last
#                                              stopped the team, or one standing agent
#   bash team/team-start.sh --self-test
#
# Each named agent (the whole team: every active standing agent) starts from its own launch line, which the
# project prints (scripts/agent-onboard.sh --launch-line <Name>: its tree and its roster identity), in a detached tmux
# session <project>-<name>, resuming its newest conversation there, named and with Remote Control on as agent-spawn.sh
# starts one. An agent already running is left alone. A developer or tester is not started here: the delivery lead
# spawns one per ticket (team/agent-spawn.sh). Exit 0 when each asked for is running, 1 when one could not start.
#
# An assistant (the roster's .assistants, not on the team) starts only when named with --only: in its own folder beside
# the project's checkout (<parent>/<name, lower case>), in a tmux session of its own name. It has no launch line and no
# identity: it sets its address on each commit, so it is known to be running by the folder its process runs in.
#
# A standing agent's model is its role's AGENTS_MODEL_<ROLE> in ~/.claude/agents.env (TEAM_START_MODELS), the role
# upper-cased with - as _ (process-improvement -> AGENTS_MODEL_PROCESS_IMPROVEMENT); with none set there, no --model,
# so Claude Code's own default ("model" in settings.json) applies. A /model in a running session lasts only until
# it is restarted: put it here for the agent to keep it.
#
#   TEAM_START_DRY=1          print each command instead of starting it
#   TEAM_START_PROJECT=<dir>  the project's checkout (default: the one ROSTER_FILE is in)
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"

project="${TEAM_START_PROJECT:-}"
[ -n "$project" ] || { [ -n "${ROSTER_FILE:-}" ] && project="$(cd "$(dirname "$ROSTER_FILE")/.." 2>/dev/null && pwd)"; }
roster="${ROSTER_FILE:-$project/agents/roster.json}"
# --make-tree makes a standing agent's missing tree before printing its line; a project whose onboarding
# predates it gets --launch-line, which refuses a missing tree and prints the command that makes it.
launch_line() {
  local verb=--launch-line
  grep -q -- '"--make-tree"' "$project/scripts/agent-onboard.sh" 2>/dev/null && verb=--make-tree
  (cd "$project" && bash scripts/agent-onboard.sh "$verb" "$1")
}
[ -n "${TEAM_START_LAUNCH_LINE:-}" ] && launch_line() { bash -c "$TEAM_START_LAUNCH_LINE" _ "$1"; }

# running <email>: whether a Claude Code process carries this roster address, wherever it was started
running() {
  local p
  for p in $(pgrep -x claude 2>/dev/null); do
    tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -qx "GIT_AUTHOR_EMAIL=$1" && return 0
  done
  return 1
}
# running_in <dir>: whether a Claude Code process runs in this folder
running_in() {
  local p
  for p in $(pgrep -x claude 2>/dev/null); do
    [ "$(readlink "/proc/$p/cwd" 2>/dev/null)" = "$1" ] && return 0
  done
  return 1
}
[ -n "${TEAM_START_RUNNING:-}" ] && {
  running() { [[ " $TEAM_START_RUNNING " == *" $1 "* ]]; }
  running_in() { [[ " $TEAM_START_RUNNING " == *" $1 "* ]]; }
}

# role_model <role>: " --model <m>" from AGENTS_MODEL_<ROLE> in the models file, or nothing. The file is read, never
# sourced, and a value that is not a plain model name is refused, since it goes into a shell command line.
models="${TEAM_START_MODELS:-$HOME/.claude/agents.env}"
role_model() {
  local key m
  key="AGENTS_MODEL_$(tr 'a-z-' 'A-Z_' <<<"$1")"
  m="$(sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\?$key=//p" "$models" 2>/dev/null | tail -1)"
  m="${m%"${m##*[![:space:]]}"}"; m="${m#[\"\']}"; m="${m%[\"\']}"
  [ -n "$m" ] || return 0
  [[ $m =~ ^[A-Za-z0-9._:-]+(\[[A-Za-z0-9]+\])?$ ]] || { echo "team-start: $key='$m' in $models is not a model name; starting on the default" >&2; return 0; }
  printf ' --model %s' "$m"
}

# resume_flag <tree>: --continue when this folder has a conversation to resume
resume_flag() {
  compgen -G "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/${1//[\/.]/-}/*.jsonl" >/dev/null && printf ' --continue'
  return 0
}

# launch <name> <session> <command> <how to see why>: starts the command in a detached tmux session, or prints it
launch() {
  local name="$1" session="$2" cmd="$3" hint="$4"
  if [ -n "${TEAM_START_DRY:-}" ]; then printf 'would start %s in tmux session %s:\n%s\n' "$name" "$session" "$cmd"; return 0; fi
  tmux has-session -t "=$session" 2>/dev/null && { echo "team-start: tmux session $session exists but $name is not running in it; close it first" >&2; return 1; }
  tmux new-session -d -s "$session" -x 200 -y 50 bash -lc "$cmd" || { echo "team-start: tmux could not start $session" >&2; return 1; }
  sleep 2
  tmux has-session -t "=$session" 2>/dev/null || { echo "team-start: $session ended at once; start it by hand to see why: $hint" >&2; return 1; }
  case "$cmd" in *" --continue "*) hint=", resuming its newest conversation" ;; *) hint="" ;; esac
  echo "team-start: started $name in tmux session $session$hint, with Remote Control on"
}

start_assistant() {
  local name="$1" tree cont
  tree="$(dirname "$project")/${name,,}"
  [ -d "$tree" ] || { echo "team-start: $name is an assistant but its folder $tree is not there" >&2; return 1; }
  if running_in "$tree"; then echo "team-start: $name is already running"; return 0; fi
  cont="$(resume_flag "$tree")"
  launch "$name" "$name" "cd $(printf %q "$tree") && claude --name $name$cont --remote-control ${name,,}" "cd $tree && claude --name $name"
}

start_one() {
  local name="$1" row role email session line tree cont=""
  row="$(jq -r --arg n "${name,,}" '.agents[]? | select((.name|ascii_downcase) == $n and .status == "active") | "\(.name)\t\(.role)\t\(.email)"' "$roster" 2>/dev/null | head -1)"
  if [ -z "$row" ]; then
    row="$(jq -r --arg n "${name,,}" '.assistants[]? | select((.name|ascii_downcase) == $n) | .name' "$roster" 2>/dev/null | head -1)"
    [ -n "$row" ] && { start_assistant "$row"; return; }
    echo "team-start: $name is not an active agent on $roster" >&2; return 1
  fi
  IFS=$'\t' read -r name role email <<<"$row"
  case "$role" in developer|tester) echo "team-start: $name ($role) is started per ticket by the delivery lead (team/agent-spawn.sh), not here"; return 0 ;; esac
  if running "$email"; then echo "team-start: $name is already running"; return 0; fi
  line="$(launch_line "$name" 2>&1)" || { echo "team-start: no launch line for $name: $line" >&2; return 1; }
  tree="$(sed -n '1s/^cd \(.*\) && \\$/\1/p' <<<"$line")"
  [ -n "$tree" ] || { echo "team-start: $name's launch line does not start in its own tree: $line" >&2; return 1; }
  # resume its newest conversation in that tree, when it has one
  cont="$(resume_flag "$tree")"
  session="${HARNESS_PROJECT:-$(basename "$project")}-${name,,}"
  launch "$name" "$session" "$line$(role_model "$role") --name $name$cont --remote-control $session" "$line"
}

selftest() {
  local fails=0 out rc T
  check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; fails=$((fails + 1)); fi; }
  T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  mkdir -p "$T/proj/agents" "$T/cfg/projects/-t-proj-lea" "$T/max" "$T/cfg/projects/${T//[\/.]/-}-max"
  : > "$T/cfg/projects/-t-proj-lea/old.jsonl"; : > "$T/cfg/projects/${T//[\/.]/-}-max/old.jsonl"
  cat > "$T/proj/agents/roster.json" <<'J'
{"agents":[{"name":"Lea","role":"delivery-lead","email":"lea@p.test","status":"active"},
 {"name":"Vi","role":"head-of-testing","email":"vi@p.test","status":"active"},
 {"name":"Ada","role":"developer","email":"ada@p.test","status":"active"},
 {"name":"Old","role":"delivery-lead","email":"old@p.test","status":"retired"}],
 "assistants":[{"name":"Max","role":"house-assistant","email":"max@p.test"},{"name":"Noa","role":"house-assistant"}]}
J
  local env=(TEAM_START_DRY=1 ROSTER_FILE="$T/proj/agents/roster.json" HARNESS_PROJECT=proj CLAUDE_CONFIG_DIR="$T/cfg"
             TEAM_START_LAUNCH_LINE='n="${1,,}"; [ "$n" = nob ] && { echo "no tree" >&2; exit 1; }; printf "cd /t/proj-%s && \\\\\n  GIT_AUTHOR_EMAIL=%s@p.test \\\\\n  claude\n" "$n" "$n"')
  out=$(env "${env[@]}" bash "$_here/team-start.sh" --only Lea 2>&1); rc=$?
  check "a standing agent starts from its launch line" "$rc" 0
  check "  in its own session, named, resuming its newest conversation, with Remote Control" "$(grep -c -- 'claude --name Lea --continue --remote-control proj-lea' <<<"$out")" 1
  out=$(env "${env[@]}" bash "$_here/team-start.sh" --only Vi 2>&1)
  check "  and one with no conversation there yet starts a new one" "$(grep -c -- 'claude --name Vi --remote-control proj-vi' <<<"$out")" 1
  out=$(env "${env[@]}" TEAM_START_RUNNING=lea@p.test bash "$_here/team-start.sh" --only Lea 2>&1); rc=$?
  check "one already running is left alone" "$rc:$(grep -c 'already running' <<<"$out"):$(grep -c 'would start' <<<"$out")" "0:1:0"
  out=$(env "${env[@]}" bash "$_here/team-start.sh" --only Ada 2>&1); rc=$?
  check "a developer is not started here" "$rc:$(grep -c 'per ticket' <<<"$out"):$(grep -c 'would start' <<<"$out")" "0:1:0"
  env "${env[@]}" bash "$_here/team-start.sh" --only Old >/dev/null 2>&1; check "a retired agent is refused" "$?" 1
  out=$(env "${env[@]}" bash "$_here/team-start.sh" --only Max 2>&1); rc=$?
  check "an assistant starts in the folder beside the project, in a session of its name" "$rc:$(grep -c -- 'would start Max in tmux session Max:' <<<"$out"):$(grep -cF -- "cd $T/max && claude --name Max --continue --remote-control max" <<<"$out")" "0:1:1"
  check "  with no identity set for it" "$(grep -c 'GIT_AUTHOR' <<<"$out")" 0
  out=$(env "${env[@]}" bash "$_here/team-start.sh" --only max 2>&1)
  check "  whatever the case of the name" "$(grep -c 'would start Max' <<<"$out")" 1
  out=$(env "${env[@]}" TEAM_START_RUNNING="$T/max" bash "$_here/team-start.sh" --only Max 2>&1); rc=$?
  check "an assistant running in its folder is left alone" "$rc:$(grep -c 'already running' <<<"$out"):$(grep -c 'would start' <<<"$out")" "0:1:0"
  out=$(env "${env[@]}" bash "$_here/team-start.sh" --only Noa 2>&1); rc=$?
  check "an assistant with no folder is refused, and says where it looked" "$rc:$(grep -cF "$T/noa" <<<"$out")" "1:1"
  env "${env[@]}" bash "$_here/team-start.sh" --only Nobody >/dev/null 2>&1; check "a name off the roster is refused" "$?" 1
  out=$(env "${env[@]}" bash "$_here/team-start.sh" 2>&1); rc=$?
  check "the whole team is every active standing agent, and no assistant" "$rc:$(grep -c 'would start' <<<"$out"):$(grep -c 'Ada\|Old\|Max' <<<"$out")" "0:2:0"
  out=$(env "${env[@]}" bash "$_here/team-start.sh" --only Vi 2>&1)
  check "with no models file, no --model, so the default applies" "$(grep -c -- '--model' <<<"$out")" 0
  printf '# models\nAGENTS_MODEL_HEAD_OF_TESTING=claude-fable-5-2\nexport AGENTS_MODEL_DELIVERY_LEAD="opus[1m]"\nAGENTS_MODEL_NOBODY=x;rm\n' > "$T/agents.env"
  out=$(env "${env[@]}" TEAM_START_MODELS="$T/agents.env" bash "$_here/team-start.sh" --only Vi 2>&1)
  check "a role with a model set starts on it" "$(grep -c -- 'claude --model claude-fable-5-2 --name Vi --remote-control proj-vi' <<<"$out")" 1
  out=$(env "${env[@]}" TEAM_START_MODELS="$T/agents.env" bash "$_here/team-start.sh" --only Lea 2>&1)
  check "  quoted and exported values are read too" "$(grep -cF -- 'claude --model opus[1m] --name Lea' <<<"$out")" 1
  printf 'AGENTS_MODEL_DELIVERY_LEAD=opus;touch %s/pwned\n' "$T" > "$T/agents.env"
  out=$(env "${env[@]}" TEAM_START_MODELS="$T/agents.env" bash "$_here/team-start.sh" --only Lea 2>&1); rc=$?
  check "  a value that is not a model name is refused, and the agent starts on the default" "$rc:$(grep -c 'not a model name' <<<"$out"):$(grep -c -- '--model' <<<"$out")" "0:1:0"
  bash "$_here/team-start.sh" --only >/dev/null 2>&1; check "--only needs a name" "$?" 2
  bash "$_here/team-start.sh" --sole Ada >/dev/null 2>&1; check "an unknown argument is refused" "$?" 2
  [ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; return 1; }
}

only=()
while [ $# -gt 0 ]; do
  if selftest_is_flag "$1"; then selftest; exit $?; fi
  selftest_reject_typo "$1"
  case "$1" in
    --only) [ -n "${2:-}" ] || { echo "team-start: --only needs a name" >&2; exit 2; }; only+=("$2"); shift 2 ;;
    *) echo "team-start: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

[ -r "$roster" ] || { echo "team-start: no roster at '$roster' (set ROSTER_FILE or TEAM_START_PROJECT)" >&2; exit 2; }
if [ ${#only[@]} -eq 0 ]; then
  mapfile -t only < <(jq -r '.agents[]? | select(.status == "active" and .role != "developer" and .role != "tester") | .name' "$roster")
fi
rc=0
for n in "${only[@]}"; do start_one "$n" || rc=1; done
exit $rc
