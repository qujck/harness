#!/usr/bin/env bash
# Tests where team/work-queue.py keeps the queue: the environment, else the settings files the page reads.
#   bash team/work-queue.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fails=0
ok() { printf 'ok    %s\n' "$1"; }
no() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

mkdir -p "$T/p/team" "$T/home"
cp "$HERE/work-queue.py" "$T/p/team/"
n=0
wq() { n=$((n + 1)); env -u AGENT_WORK_QUEUE -u HARNESS_ENV_FILE -u HARNESS_PROJECT -u HARNESS_ROOT HOME="$T/home" AGENT_NAME=t "$@" python3 "$T/p/team/work-queue.py" add "X-$n" "a title" >/dev/null 2>&1 || no "work-queue.py ran"; }

wq; check "with no setting anywhere, the default in the project's state directory" '[ -f "$T/home/.local/state/p/work-queue.json" ]'
printf 'AGENT_WORK_QUEUE=%s\n' "$T/from-env-file.json" > "$T/p/harness.env"
wq; check "set only in harness.env, it lands there, as the page reads it" '[ -f "$T/from-env-file.json" ]'
printf 'AGENT_WORK_QUEUE=%s\n' "$T/from-extra.json" > "$T/extra.env"
wq HARNESS_ENV_FILE="$T/extra.env"; check "HARNESS_ENV_FILE wins over harness.env" '[ -f "$T/from-extra.json" ]'
wq AGENT_WORK_QUEUE="$T/from-shell.json"; check "the environment wins over both" '[ -f "$T/from-shell.json" ]'
printf 'HARNESS_PROJECT=named\n' > "$T/p/harness.env"
wq; check "the project's name in harness.env names the state directory" '[ -f "$T/home/.local/state/named/work-queue.json" ]'

[ "$fails" -eq 0 ] && echo "all passed" || { echo "$fails failed"; exit 1; }
