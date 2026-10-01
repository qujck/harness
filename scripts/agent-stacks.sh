#!/usr/bin/env bash
# Who is on this box, and is there room for one more?
#
# Usage:
#   bash scripts/agent-stacks.sh              # list the live agent stacks and who holds them
#   bash scripts/agent-stacks.sh --check      # …and exit 1 if THIS stream would exceed the cap
#   bash scripts/agent-stacks.sh --selftest   # assert the pure decisions below
#
# ═══ WHY A CAP EXISTS (infra_cap_concurrent_agents_at_four_machine_wide) ═══
# Nothing capped how many agents ran at once, and the box has been driven to a **load average of 182
# on 32 cores**, CPU pressure `some avg10=77.69` (something was waiting for a core 78% of the time),
# 205 headless_shell processes. One agent was deliberately running four full Playwright suites; the
# others were doing ordinary work and paying for it. Nothing in the harness noticed or objected.
#
# Owner, 2026-08-02: *"a second human will not run more agents, agents will have to be shared between
# them - 4 max for the box"*. FOUR TOTAL, SHARED — not four each, and not two each. The count is
# deliberately not tied to human identity.
#
# ═══ THE CRUX: THIS MUST COUNT ACROSS USERS, AND THE EXISTING CHECK CANNOT ═══
# init.sh already scans sibling worktrees for .agent/session.active. That scan is PATH-RELATIVE — it
# looks beside the current worktree — so with a second human under a different home it would see four
# agents and report one. A cap built on it would be silently wrong exactly when it started to matter.
#
# **The docker daemon is the one thing on this box that is already machine-wide.** It sees every
# stack regardless of which user created it. So the COUNT comes from `docker compose ls` and depends
# on nobody's home directory. Agent NAMES are then looked up from each stack's own worktree as a
# best-effort LABEL — and when that is unreadable (another user's home, exactly the case this ticket
# is about) the refusal still names the project and its path. **The count is authoritative; the names
# are a courtesy.** Getting those two the wrong way round is how this check would rot.
#
# ═══ WHY THERE IS NO REGISTRY FILE ═══
# A registry of "who holds a slot" has to be written, and anything written can go stale — an agent
# whose stack died would hold a slot forever, turning a capacity limit into a lockout whose recovery
# is "ask the owner". Live docker projects cannot go stale: `docker compose ls` lists only projects
# with RUNNING containers, so a stack that died stops being counted the moment it dies, with no
# reaping, no TTL and no cleanup path to get wrong. **The absence of state here is the feature.**
#
# ═══ WHAT COUNTS AS AN AGENT STACK ═══
# A compose project whose config files include a `docker-compose.override.yml`. That override is what
# MAKES a stack a dev/agent stack — it bind-mounts ./backend, runs `dotnet watch`, and adds the
# front-end containers. Everything else on this box is correctly excluded by the same rule, not by a
# hand-maintained deny-list:
#   * plex / caddy / portainer / download / cloudflared — unrelated projects, different compose files
#   * iron-forge-monitoring, iron-forge-logs           — docker-compose.monitoring.yml / .logs.yml
#   * iron-forge-test-local                            — docker-compose.test-local.yml
#   * ephemeral e2e (scripts/e2e-ephemeral.sh)         — pins base+e2e and says "NO dev override"
# Counting containers instead would refuse the first agent of the day, since the box idles with ~20
# containers that belong to nobody's agent.
#
# EPHEMERAL e2e IS DELIBERATELY NOT COUNTED. It is real load, but it is a throwaway that tears itself
# down in minutes and it is not an agent holding a seat. Counting it would let a passing e2e run
# refuse an agent that then has nothing to wait for.
#
# THE SELF-HOSTED CI STACK ($CI_STACK_PROJECT, infra_stack_cap_ci_slot) IS ENUMERATED BUT NOT AN
# AGENT: it holds a RESERVED seat of its own — 4 agents + 1 CI, the owner's budget for this box —
# because its compose set includes the override (so the override rule alone would miscount it) and
# because refusing it, once its verify check is required, blocks everyone's merges. The reasoning
# lives with the constant in scripts/lib/agent-stacks.sh.
#
# ═══ WHAT THIS IS NOT ═══
#   * NOT a throttle. It caps HOW MANY agents run, not how fast each one works. Lowering PW_WORKERS
#     or slowing the suite is explicitly the wrong lever (CLAUDE.md: a change that makes the suite
#     slower and no more correct has fixed nothing).
#   * NOT advisory. A warning nobody has to obey is what existed before this.
#   * NOT enforced by killing anything. It refuses the fifth START and never takes down a running
#     stack — an agent mid-session is doing real work and its stack is where that work lives.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/agent-stacks.sh"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"

# This script has arguments of its own, so it keeps its own rejection rather than delegating the
# whole contract to selftest_requested. Everything it accepts is listed here; nothing else passes.
case "${1:-}" in
  ''|--check|--self-test|--selftest) ;;
  *) printf 'unknown argument: %s\n' "$1" >&2
     printf 'usage: agent-stacks.sh [--check|--self-test]\n' >&2
     exit 2 ;;
esac

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  # the fixtures below are the seeded project's real `docker compose ls` shapes; their names are DATA,
  # so the self-test pins the config they were recorded under (the live defaults come from harness.env)
  CI_STACK_PROJECT=strength_ci; INFRA_STACK_PROJECTS='iron-forge-test-local'; TEST_STACK_PROJECT=iron-forge-test-local
  fails=0
  eq() { # eq <what> <expected> <got>
    if [[ "$3" != "$2" ]]; then printf 'selftest FAIL [%s]: expected %q, got %q\n' "$1" "$2" "$3" >&2; fails=1; fi
  }

  # A faithful sample of this box: four agent stacks plus everything else that actually runs here.
  SAMPLE='[
    {"Name":"caddy","Status":"running(1)","ConfigFiles":"/home/peter/dev/download/caddy/docker-compose.yml"},
    {"Name":"iron-forge-logs","Status":"running(1)","ConfigFiles":"/home/peter/dev/strength-nadia/monitoring/docker-compose.logs.yml"},
    {"Name":"iron-forge-monitoring","Status":"running(3)","ConfigFiles":"/home/peter/dev/strength/monitoring/docker-compose.monitoring.yml"},
    {"Name":"iron-forge-test-local","Status":"running(5)","ConfigFiles":"/home/peter/dev/strength-autodeploy/docker-compose.test-local.yml,/home/peter/dev/strength-nadia/docker-compose.test-local.yml"},
    {"Name":"plex","Status":"running(1)","ConfigFiles":"/home/peter/dev/download/plex/docker-compose.yml"},
    {"Name":"strength_ci","Status":"running(9)","ConfigFiles":"/var/lib/ironforge/actions-runner/_work/strength/strength/docker-compose.yml,/var/lib/ironforge/actions-runner/_work/strength/strength/docker-compose.override.yml,/var/lib/ironforge/actions-runner/_work/strength/strength/docker-compose.ci.yml"},
    {"Name":"strength_e2e_20260802_021455_31337","Status":"running(4)","ConfigFiles":"/home/peter/dev/strength-hugo/docker-compose.yml,/home/peter/dev/strength-hugo/docker-compose.e2e.yml"},
    {"Name":"strength_strength-hugo","Status":"running(9)","ConfigFiles":"/home/peter/dev/strength-hugo/docker-compose.yml,/home/peter/dev/strength-hugo/docker-compose.override.yml"},
    {"Name":"strength_strength-nadia","Status":"running(9)","ConfigFiles":"/home/peter/dev/strength-nadia/docker-compose.yml,/home/peter/dev/strength-nadia/docker-compose.override.yml"},
    {"Name":"strength_strength-nell","Status":"running(9)","ConfigFiles":"/home/peter/dev/strength-nell/docker-compose.yml,/home/peter/dev/strength-nell/docker-compose.override.yml"},
    {"Name":"strength_strength-wren","Status":"running(9)","ConfigFiles":"/home/peter/dev/strength-wren/docker-compose.yml,/home/peter/dev/strength-wren/docker-compose.override.yml"}
  ]'

  # The CI stack IS enumerated (its compose set includes the override — the listing must be able to
  # show it) but is then classified OUT of agent arithmetic below. Two different questions.
  got="$(printf '%s' "$SAMPLE" | agent_stacks_from_json | cut -f1 | tr '\n' ' ')"
  eq "the four agent stacks + the CI stack, and ONLY those" \
     'strength_ci strength_strength-hugo strength_strength-nadia strength_strength-nell strength_strength-wren ' "$got"

  # Each exclusion asserted on its own, so a future regression names which one broke.
  for excluded in caddy plex iron-forge-monitoring iron-forge-logs iron-forge-test-local; do
    if printf '%s' "$SAMPLE" | agent_stacks_from_json | cut -f1 | grep -qx "$excluded"; then
      echo "selftest FAIL: '$excluded' must not count as an agent stack" >&2; fails=1
    fi
  done
  # The ephemeral e2e stack lives in an agent's worktree and shares its compose file — it is excluded
  # by the OVERRIDE rule, not by its name. This is the case a basename or path check would get wrong.
  if printf '%s' "$SAMPLE" | agent_stacks_from_json | cut -f1 | grep -q 'strength_e2e_'; then
    echo "selftest FAIL: an ephemeral e2e stack must not hold an agent slot" >&2; fails=1
  fi

  eq "worktree dir is derived from the config path" \
     '/home/peter/dev/strength-nell' \
     "$(printf '%s' "$SAMPLE" | agent_stacks_from_json | awk -F'\t' '$1=="strength_strength-nell"{print $2}')"

  # Degenerate daemon output must not explode or invent stacks.
  eq "empty array"  '' "$(printf '[]'   | agent_stacks_from_json)"
  eq "null"         '' "$(printf 'null' | agent_stacks_from_json)"
  eq "empty stdin"  '' "$(printf ''     | agent_stacks_from_json)"

  # ── the CI seat (infra_stack_cap_ci_slot) ──
  # The one non-agent project with a stack of its own. It must never land in `others` (that would
  # let a CI verify eat a human's seat) and never in `mine_up` (its admission is the $CI bypass).
  enum="$(printf '%s' "$SAMPLE" | agent_stacks_from_json)"
  eq "CI up: hugo sees 3 others + himself + CI"  $'3\t1\t1' "$(classify_stacks strength_strength-hugo <<< "$enum")"
  eq "CI up: a newcomer sees 4 others + CI"      $'4\t0\t1' "$(classify_stacks strength_strength-faith <<< "$enum")"
  eq "no CI stack: ci_up is 0" \
     $'4\t0\t0' "$(classify_stacks strength_strength-faith <<< "$(grep -v $'^strength_ci\t' <<< "$enum")")"
  # And the seat does not soften the agent cap: with CI up and four agents live, a fifth AGENT is
  # still refused — CI's presence must change nothing about the humans' arithmetic.
  IFS=$'\t' read -r _o _m _c <<< "$(classify_stacks strength_strength-faith <<< "$enum")"
  eq "fifth agent still refused while CI holds its seat" refuse "$(cap_verdict "$_o" "$_m" 4)"

  # ── the permanent TEST stack (fix_agent_stacks_counts_the_permanent_test_autodeploy_stack_as_one_of_the_four_developer_slots) ──
  # ⚠ THE LIVE SHAPE, NOT THE TIDY ONE. The fixture above gives iron-forge-test-local only its own
  # compose file, so the override rule excludes it and no name check is exercised. On the box it had
  # ALSO picked up another worktree's docker-compose.override.yml, which is what made it an "agent".
  TEST_SHAPE='{"Name":"iron-forge-test-local","Status":"running(10)","ConfigFiles":"/srv/ironforge/strength-autodeploy/docker-compose.test-local.yml,/home/peter/dev/strength-rowan-l/docker-compose.yml,/home/peter/dev/strength-rowan-l/docker-compose.override.yml"}'
  agent_json() { printf '{"Name":"strength_strength-%s","Status":"running(9)","ConfigFiles":"/home/peter/dev/strength-%s/docker-compose.yml,/home/peter/dev/strength-%s/docker-compose.override.yml"}' "$1" "$1" "$1"; }
  three="$(printf '[%s,%s,%s,%s]' "$TEST_SHAPE" "$(agent_json a)" "$(agent_json b)" "$(agent_json c)")"
  four="$(printf '[%s,%s,%s,%s,%s]' "$TEST_SHAPE" "$(agent_json a)" "$(agent_json b)" "$(agent_json c)" "$(agent_json d)")"
  # Positive control on the fixture: the contaminated shape IS enumerated by the override rule, so the
  # arms below are testing the name exclusion and not passing because the stack was never seen.
  eq "the contaminated TEST stack is enumerated (so the exclusion below is what is tested)" \
     1 "$(printf '%s' "$three" | agent_stacks_from_json | cut -f1 | grep -cx iron-forge-test-local)"
  IFS=$'\t' read -r _o _m _c <<< "$(classify_stacks strength_strength-new <<< "$(printf '%s' "$three" | agent_stacks_from_json)")"
  eq "TEST + three agents: TEST is not counted" 3 "$_o"
  eq "TEST + three agents: a fourth DEVELOPER is admitted" allow "$(cap_verdict "$_o" "$_m" 4)"
  IFS=$'\t' read -r _o _m _c <<< "$(classify_stacks strength_strength-new <<< "$(printf '%s' "$four" | agent_stacks_from_json)")"
  eq "NEGATIVE CONTROL: TEST + four agents still refuses a fifth developer" refuse "$(cap_verdict "$_o" "$_m" 4)"
  eq "TEST never lands in ci_up either" 0 "$_c"
  # Keyed on the declared NAME, never on "(unnamed)": an agent stack whose holder cannot be named
  # still takes its seat.
  eq "an unnamed agent stack still counts" $'1\t0\t0' \
     "$(classify_stacks strength_strength-new <<< $'strength_strength-nobody\t/tmp/no-such-worktree\trunning(9)')"
  eq "a near-miss of the TEST name is NOT excluded" 1 "$(is_test_stack iron-forge-test-local-2; echo $?)"
  # ⚠ ONE NAME, TWO FILES. scripts/test-local.sh pins the project; this is the check that they agree.
  _tl_proj="$(sed -n '/^PROJECT=/{s///p;q;}' "$(dirname "${BASH_SOURCE[0]}")/test-local.sh")"
  eq "is_ci_stack: the pinned project"  0 "$(is_ci_stack strength_ci; echo $?)"
  eq "is_ci_stack: an agent is not CI"  1 "$(is_ci_stack strength_strength-hugo; echo $?)"
  # ⚠ EVERY CI LANE MUST BE EXCLUDED, not just the historical literal
  # (fix_ledger_lane_verify_destroys_the_code_lane_ci_stack). CI runs under one project name PER
  # LANE now, and if this classifier stops recognising one, that lane's stack is counted as
  # another agent's — a running CI job then eats one of the four machine-wide seats and init.sh
  # refuses to start an agent, with nothing in the message pointing at CI.
  eq "is_ci_stack: the code lane"       0 "$(is_ci_stack strength_ci_forge-box; echo $?)"
  eq "is_ci_stack: the ledger lane"     0 "$(is_ci_stack strength_ci_canary-box; echo $?)"
  eq "is_ci_stack: the nightly"         0 "$(is_ci_stack strength_ci_nightly; echo $?)"
  eq "is_ci_stack: the dispatch job"    0 "$(is_ci_stack strength_ci_dispatch; echo $?)"
  # …and this one was ALREADY misclassified before the rename — the manual UI job has always had
  # its own project name and the exact match never covered it.
  eq "is_ci_stack: the manual UI job"   0 "$(is_ci_stack strength_ci_ui; echo $?)"
  # ⚠ AND THE PREFIX MUST NOT OVER-REACH. A name that merely STARTS with the letters is not a CI
  # stack; without the separator check this would silently stop counting a real agent.
  eq "is_ci_stack: a near-miss is NOT CI" 1 "$(is_ci_stack strength_cider; echo $?)"
  # The property that actually matters: a lane-named CI stack does not consume an agent seat.
  lane_enum="$(printf '%s\n' $'strength_ci_forge-box\t/w\trunning(9)' $'strength_strength-hugo\t/h\trunning(9)')"
  eq "a lane-named CI stack is not another agent" $'0\t1\t1' \
     "$(classify_stacks strength_strength-hugo <<< "$lane_enum")"
  # classify handles degenerate input like the enumerator does.
  eq "classify of nothing" $'0\t0\t0' "$(classify_stacks strength_strength-faith <<< '')"

  # ── occupancy: is this a stack, or debris that looks like one? ──
  # (fix_agent_cap_counts_a_one_container_remnant_as_a_full_stack)
  # ⚠ BOTH ARMS, AND THE FIRST IS THE ONE THAT MATTERS. Asserting only that a remnant is excluded is
  # satisfied by a predicate that counts NOTHING — which would silently raise the cap and let five
  # real stacks onto a box sized for four.
  eq "a real stack (has api) COUNTS"          up       "$(stack_occupancy 'test api db pwa' 200000)"
  eq "the measured remnant (test only, 38h)"  remnant  "$(stack_occupancy 'test' 136800)"
  # ⚠ THE THIRD CASE. A stack mid-init also has no api yet — api waits on db's healthcheck before it
  # is even created. If it did not count, two agents starting seconds apart would both see a free
  # seat: check-then-act, the shape this repo has already been bitten by.
  eq "mid-init (no api, seconds old) COUNTS"  starting "$(stack_occupancy 'db' 5)"
  eq "just at the grace boundary counts"      starting "$(stack_occupancy 'db' 599 600)"
  eq "one second past it is debris"           remnant  "$(stack_occupancy 'db' 600 600)"
  # Absence of evidence must not free a seat.
  eq "unreadable age counts"                  starting "$(stack_occupancy 'test' '')"
  eq "no services at all, unknown age"        starting "$(stack_occupancy '' '')"
  # A substring must not pass for the service — `api` is not `apidocs`.
  eq "a near-miss service is not api"         remnant  "$(stack_occupancy 'apidocs' 999999)"

  # …and the property that actually matters, through classify_stacks: debris holds no seat, while
  # everything else is unchanged. The 4th field is OPTIONAL, so every assertion above that passes
  # three fields still means exactly what it meant before occupancy existed.
  occ_enum="$(printf '%s\n' \
    $'strength_strength\t/home/peter/dev/strength\trunning(1)\tremnant' \
    $'strength_strength-anthony\t/a\trunning(11)\tup' \
    $'strength_strength-saffron2\t/s\trunning(10)\tup' \
    $'strength_strength-cara\t/c\trunning(11)\tup')"
  eq "the real 5/4: debris drops out, 3 remain" $'2\t1\t0' \
     "$(classify_stacks strength_strength-cara <<< "$occ_enum")"
  eq "and a newcomer is admitted"               allow \
     "$(IFS=$'\t' read -r o m _ <<< "$(classify_stacks strength_strength-new <<< "$occ_enum")"; cap_verdict "$o" "$m" 4)"
  # The negative control on the SAME fixture: without the verdict column nothing is excluded, so the
  # newcomer is refused. This is the pre-fix behaviour, and it proves the fixture can still refuse.
  eq "control: no verdicts -> the old wrong answer" refuse \
     "$(IFS=$'\t' read -r o m _ <<< "$(classify_stacks strength_strength-new <<< "$(cut -f1-3 <<< "$occ_enum")")"; cap_verdict "$o" "$m" 4)"

  # ── the listing's WORDING: it must never assert a direction it cannot know ──
  # (infra_a_dead_stack_reads_as_a_starting_one_and_holds_a_machine_wide_slot)
  # ⚠ THE MEASURED INSTANCE. `uinet` at 18 restarts on `host not found in upstream "pwa"`, api long
  # gone, project age 570s — INSIDE the 600s grace, so `stack_occupancy` says `starting` and is
  # right to: on services and age alone this is indistinguishable from a slow init. The defect was
  # never the count; it was the tool printing "but coming up" over a crash loop.
  eq "a crash loop is not called 'coming up'" \
     '  <- counted: no api, and 18 restart(s) — starting slowly, or crash-looping; `docker ps` says which' \
     "$(occupancy_note starting 18)"
  # ⚠ AND THE OTHER BRANCH MUST NOT CLAIM HEALTH EITHER. Zero restarts is not evidence a stack is
  # coming up — an api removed cleanly leaves none behind. Both branches state what is KNOWN.
  eq "no restarts is not evidence of health" \
     '  <- counted: no api yet; no restarts seen' "$(occupancy_note starting 0)"
  eq "an unreadable restart count is not a crash loop" \
     '  <- counted: no api yet; no restarts seen' "$(occupancy_note starting '')"
  eq "a non-numeric restart count is not a crash loop" \
     '  <- counted: no api yet; no restarts seen' "$(occupancy_note starting 'many')"
  # ⚠ NEGATIVE CONTROL ON THE WHOLE POINT: no branch of this function may contain the old claim.
  eq "no branch asserts a direction" '' \
     "$(for r in '' 0 1 18 many; do occupancy_note starting "$r"; occupancy_note remnant "$r"; occupancy_note up "$r"; done | grep -o 'coming up' | head -1)"
  # The unchanged arms, so this function cannot quietly restyle the rest of the listing.
  eq "remnant wording is unchanged" \
     '  <- NOT counted: no api container, nothing recent — leftover, not a stack' \
     "$(occupancy_note remnant 0)"
  eq "a real stack gets no annotation" '' "$(occupancy_note up 0)"
  eq "an empty occupancy gets no annotation" '' "$(occupancy_note '' 0)"

  # ⚠ THE REGRESSION THIS TICKET NEARLY CAUSED, DRIVEN. Widening the listing to five fields made
  # `classify_stacks`'s `read -r proj dir status occ` fold `remnant<TAB>0` into `occ`, so the debris
  # guard stopped matching and DEBRIS STARTED COUNTING — a wording change silently becoming a
  # seat-arithmetic change. The 4-field form must keep its exact prior meaning too.
  five_field="$(printf '%s\n' \
    $'strength_strength\t/home/peter/dev/strength\trunning(1)\tremnant\t0' \
    $'strength_strength-anthony\t/a\trunning(11)\tup\t0' \
    $'strength_strength-cara\t/c\trunning(11)\tup\t3')"
  eq "a 5-field line still excludes debris" $'1\t1\t0' \
     "$(classify_stacks strength_strength-cara <<< "$five_field")"
  eq "…and the 4-field form is unchanged" $'1\t1\t0' \
     "$(classify_stacks strength_strength-cara <<< "$(cut -f1-4 <<< "$five_field")")"
  # ⚠ NO HAND-ROLLED "CONTROL" HERE, DELIBERATELY. The first draft asserted the pre-fix answer by
  # re-implementing the broken loop inline — arithmetic over a constant, which passes whatever the
  # real code does and could never have failed. The honest control is a MUTATION of the real
  # function, driven rather than described:
  #
  #   remove `_extra` from classify_stacks  -> "a 5-field line still excludes debris"
  #                                            expected $'1\t1\t0', got $'2\t1\t0'  (exit 1)
  #   restore the old wording               -> 5 of the wording assertions fail, including
  #                                            "no branch asserts a direction"
  #
  # Both run and restored 2026-08-30. A control that cannot fail is documentation with a green tick.

  # ── the cap itself ──
  eq "0 others, room"                allow  "$(cap_verdict 0 0 4)"
  eq "3 others, I am the fourth"     allow  "$(cap_verdict 3 0 4)"
  eq "4 others, I would be the FIFTH" refuse "$(cap_verdict 4 0 4)"
  eq "5 others (box already over)"   refuse "$(cap_verdict 5 0 4)"
  # Re-running init.sh with my stack already up must ALWAYS work, at any occupancy. This is the one
  # that turns a capacity limit into a lockout if it regresses.
  eq "re-attach at the cap"          allow  "$(cap_verdict 4 1 4)"
  eq "re-attach over the cap"        allow  "$(cap_verdict 9 1 4)"
  # The limit is a judgement, not a law.
  eq "limit raised to 5"             allow  "$(cap_verdict 4 0 5)"
  eq "limit lowered to 1"            refuse "$(cap_verdict 1 0 1)"

  if [[ $fails -eq 0 ]]; then echo "agent-stacks: selftest ok"; else exit 1; fi
  exit 0
fi

# ── Live ──────────────────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/_stack.sh"
# my own compose project: the template's _stack.sh sets PROJ only in per-stream mode, so derive it here
PROJ="${PROJ:-${COMPOSE_PROJECT_NAME:-$(stack_default_proj)}}"

# ⚠ ANNOTATED WITH OCCUPANCY, because `docker compose ls` cannot tell a stack from its debris:
# "running(1)" and "running(11)" read identically, and one leftover container held a whole seat.
# (fix_agent_cap_counts_a_one_container_remnant_as_a_full_stack)
FACTS="$(stack_container_facts)"
STACKS="$(docker compose ls --format json 2>/dev/null | agent_stacks_from_json \
  | while IFS=$'\t' read -r p d s; do
      [[ -n "$p" ]] || continue
      svc="$(awk -F'\t' -v want="$p" '$1==want{print $2; exit}' <<< "$FACTS")"
      age="$(awk -F'\t' -v want="$p" '$1==want{print $3; exit}' <<< "$FACTS")"
      rst="$(awk -F'\t' -v want="$p" '$1==want{print $4; exit}' <<< "$FACTS")"
      printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$d" "$s" "$(stack_occupancy "$svc" "$age")" "$rst"
    done)"

IFS=$'\t' read -r others mine_up ci_up <<< "$(classify_stacks "$PROJ" <<< "$STACKS")"

if [[ "${1:-}" != "--check" ]]; then
  if [[ -z "$STACKS" ]]; then
    echo "no agent stacks are running on this box (limit ${AGENT_STACK_LIMIT})"
    exit 0
  fi
  printf 'agent stacks live on this box (%d/%d agents%s):\n' \
    "$((others + mine_up))" "$AGENT_STACK_LIMIT" \
    "$([[ "$ci_up" == 1 ]] && printf ' + the reserved CI seat')"
  # ⚠ THE LISTING SAYS WHY. The original defect could only be diagnosed from OUTSIDE the tool: Ed
  # had to count containers per project by hand to see that his own entry was debris, because
  # "running(1)" and "running(11)" were displayed identically. Whatever the predicate is, the
  # listing must show what it decided — or the next person goes outside the tool again.
  while IFS=$'\t' read -r proj dir status occ rst; do
    [[ -n "$proj" ]] || continue
    # ⚠ THE WORDING IS `occupancy_note`'s, NOT THIS LOOP'S. It used to say `no api yet, but coming
    # up` for every `starting` stack — a claim about where the stack is HEADED, made from services
    # and age alone, which cannot carry it. The measured instance was a crash loop and this line
    # called it healthy. (infra_a_dead_stack_reads_as_a_starting_one_and_holds_a_machine_wide_slot)
    note="$(occupancy_note "$occ" "$rst")"
    if is_ci_stack "$proj"; then
      printf '  %-28s %-12s %s%s\n' 'CI (reserved seat)' "$status" "$dir" "$note"
    elif is_test_stack "$proj"; then
      # Named, never "(unnamed)", and said out loud that it holds no developer seat.
      printf '  %-28s %-12s %s  <- NOT counted: declared infrastructure (%s in INFRA_STACK_PROJECTS)\n' \
        'INFRASTRUCTURE' "$status" "$dir" "$proj"
    else
      printf '  %-28s %-12s %s%s%s\n' "$(holder_of "$dir")" "$status" "$dir" \
        "$([[ "$proj" == "$PROJ" ]] && printf '  <- you')" "$note"
    fi
  done <<< "$STACKS"
  exit 0
fi

# ── --check: may THIS stream start? ───────────────────────────────────────────────────────────────
# The CI bypass covers both CI shapes, for different reasons:
#   * HOSTED (ubuntu-latest): a throwaway machine that shares nothing with this box — the cap is
#     simply not about it.
#   * SELF-HOSTED (forge-box, epic_self_hosted_ci_runner): its verify stack runs HERE, but in the
#     RESERVED seat — project-pinned to $CI_STACK_PROJECT, excluded from agent arithmetic by
#     classify_stacks, and incapable of holding two seats (one compose project, one runner job at
#     a time). Admitting it through cap_verdict instead would refuse CI exactly when the box is
#     full of agents — which, once the verify check is REQUIRED, blocks everyone's merges.
if [[ -n "${CI:-}" ]]; then exit 0; fi

if [[ "$(cap_verdict "$others" "$mine_up" "$AGENT_STACK_LIMIT")" == refuse ]]; then
  printf '   \033[1;31mFAIL\033[0m this box already runs %d agent stacks (the cap is %d, machine-wide across everyone).\n' \
    "$others" "$AGENT_STACK_LIMIT" >&2
  # Say "one more", not "a fifth": the limit is configurable, and an ordinal derived from the
  # DEFAULT would be a lie the moment anyone set AGENT_STACK_LIMIT.
  printf '        Starting one more makes every run slower for all of them. What motivated the cap:\n' >&2
  printf '        this box has been driven to load average 182 on 32 cores, with something waiting\n' >&2
  printf '        for a core 78%% of the time. Your suite would not finish sooner for having started.\n\n' >&2
  # ⚠ NAME THE TRAILING FIELDS. `read` folds every remainder into the last variable, so reading
  # three names off a five-field line prints the occupancy and the restart count INSIDE the status
  # column — a refusal message is the worst place to garble.
  while IFS=$'\t' read -r proj dir status _occ _rst; do
    [[ -n "$proj" ]] || continue
    # The permanent TEST stack holds no developer seat, so the refusal must not offer it as one to
    # ask to wrap up — there is nobody to ask, and handoff.sh would tear TEST down.
    is_test_stack "$proj" && continue
    printf '          %-24s %-12s %s\n' "$(holder_of "$dir")" "$status" "$dir" >&2
  done <<< "$STACKS"
  printf '\n        HOW TO PROCEED — nothing here is killed and nothing is queued for you:\n' >&2
  printf '          * wait for one to finish, then re-run scripts/init.sh (it is idempotent);\n' >&2
  printf '          * or ask a holder above to wrap up — scripts/handoff.sh tears their stack down;\n' >&2
  printf '          * or, if this box genuinely has room today, raise the limit for this run:\n' >&2
  printf '              AGENT_STACK_LIMIT=%d bash scripts/init.sh\n' "$((AGENT_STACK_LIMIT + 1))" >&2
  printf '            (a judgement about this box, not a law — but four is the owner'"'"'s number)\n' >&2
  printf '        You can review the live stacks any time: bash scripts/agent-stacks.sh\n' >&2
  exit 1
fi
exit 0
