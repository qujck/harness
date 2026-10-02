#!/usr/bin/env bash
# ci-exempt: pure string function — no docker, no network. Its self-test runs in verify.sh.
#
# The compose project a CI VERIFY job's stack runs under, keyed on the RUNNER THAT TOOK THE JOB.
# (infra_the_ci_compose_project_is_keyed_on_the_runner_label_so_two_runners_sharing_a_label_would_share_a_stack)
#
#   bash scripts/ci-stack-project.sh <runner-name>     # prints <project>_ci_<name>, sanitised (HARNESS_PROJECT from harness.env)
#   bash scripts/ci-stack-project.sh --self-test
#
# ⚠ WHY THE RUNNER NAME AND NOT THE ROUTE LABEL. The verify job used `strength_ci_<route label>`.
# A label is a POOL, not a machine: the moment two runners share one (the approved second-seat trial
# gives fast-box the `forge-box` label), two concurrent verifies get the SAME project name — and all
# four runners share ONE docker daemon, so they do not merely reclaim each other's stack
# (reclaim-ci-seat.sh `down -v`s its project), they ATTACH to each other's containers mid-suite.
# GitHub gives every registered runner its own name, so the name is the discriminator.
#
# ⚠ WHY A SCRIPT AND NOT AN EXPRESSION. `${{ runner.name }}` is NOT available in a job-level `env:`
# block (GitHub's context table allows github/needs/strategy/matrix/vars/secrets/inputs there), so
# the name has to be set by a STEP; and a step's inline shell would be a second copy of the formula
# beside this self-test. One formula, here.
#
# ⚠ THE PREFIX IS LOAD-BEARING: agent-stacks.sh's is_ci_stack() exempts `strength_ci*` from the
# four-agent machine cap, and reap-miskeyed-ci-compose-stacks.sh treats it as live. Registered names
# today equal their labels (forge-box, canary-box, fast-box, route-box), so a single runner's project
# name is unchanged by this: `strength_ci_forge-box` before and after.
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"

# ci_stack_project <runner-name> -> strength_ci_<lowercased, [a-z0-9_-] only>; rc 2 on an empty name.
# Compose project names are lowercase alphanumerics, '-' and '_'; anything else becomes '_'.
ci_stack_project() {
  local n="${1:-}"
  [[ -n "$n" ]] || { echo "ci-stack-project: no runner name — refusing to name a stack (an empty -p derives one from the directory)" >&2; return 2; }
  n="$(printf '%s' "$n" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '_')"
  printf '%s_ci_%s\n' "${HARNESS_PROJECT:-harness}" "$n"
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  f=0
  t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s: want %q got %q\n' "$1" "$3" "$2"; f=1; fi; }
  t 'a single runner keeps today'"'"'s name (registered name == label)' "$(ci_stack_project forge-box)" "${HARNESS_PROJECT:-harness}_ci_forge-box"
  # ⚠ THE CASE THIS EXISTS FOR: two runners holding ONE label get TWO projects.
  a="$(ci_stack_project forge-box)"; b="$(ci_stack_project fast-box)"
  t 'two runners sharing the forge-box label get DIFFERENT projects' "$([[ "$a" != "$b" ]] && echo distinct || echo same)" 'distinct'
  t 'uppercase is lowered (compose refuses it)' "$(ci_stack_project Forge-Box)" "${HARNESS_PROJECT:-harness}_ci_forge-box"
  t 'a space or dot becomes _' "$(ci_stack_project 'my runner.2')" "${HARNESS_PROJECT:-harness}_ci_my_runner_2"
  _p="${HARNESS_PROJECT:-harness}"; t 'the <project>_ci prefix survives, so the machine cap still exempts it' "$(ci_stack_project x | cut -c1-$(( ${#_p} + 4 )))" "${_p}_ci_"
  ci_stack_project '' >/dev/null 2>&1; t 'an EMPTY name is refused (rc 2), never named' "$?" '2'
  [[ $f == 0 ]] && echo 'ci-stack-project: self-test ok'
  exit "$f"
fi

ci_stack_project "${1:-${RUNNER_NAME:-}}"
