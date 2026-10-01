# scripts/lib/agent-stacks.sh — who is live on this box, as pure functions.
# (infra_platform_state_and_secrets_leave_the_home_directory)
#
# Extracted from scripts/agent-stacks.sh so init.sh's NAME-UNIQUENESS check can use the same
# machine-wide enumeration as the agent CAP. That script is a runnable command that exits, so it
# cannot be sourced; copying the two functions into init.sh would have created exactly the
# hand-synced duplicate this repo keeps paying to remove. One definition, two callers.
#
# The reasoning for every decision below lives in scripts/agent-stacks.sh's header — read it there.

# ── THE LIMIT — the one place it is defined ───────────────────────────────────────────────────────
# A judgement about THIS box (32 cores), not a law. Override for a one-off:
#   AGENT_STACK_LIMIT=5 bash scripts/init.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/harness-env.sh" 2>/dev/null || true
AGENT_STACK_LIMIT="${AGENT_STACK_LIMIT:-4}"

# ── Pure decision 1, asserted by --selftest ───────────────────────────────────────────────────────
# stdin: the output of `docker compose ls --format json`.
# stdout: one TAB-separated line per AGENT stack — <project>\t<worktree-dir>\t<status>
agent_stacks_from_json() {
  jq -r '
    (if . == null then [] else . end)
    | .[]
    | . as $p
    | (($p.ConfigFiles // "") | split(",") | map(select(length > 0))) as $cfs
    | select($cfs | any(split("/") | last == "docker-compose.override.yml"))
    # The worktree is the directory holding the compose files. Any of them will do — they are all in
    # the same worktree — so take the first and drop the filename.
    | ($cfs[0] | split("/") | .[0:-1] | join("/")) as $dir
    | [$p.Name, $dir, ($p.Status // "")] | @tsv
  ' 2>/dev/null
}

# ── Pure decision 2, asserted by --selftest ───────────────────────────────────────────────────────
# ── ⚠ HAS THIS PROJECT COME UP, OR IS IT DEBRIS THAT LOOKS LIKE A STACK? ─────────────────────────
# (fix_agent_cap_counts_a_one_container_remnant_as_a_full_stack)
#
# `docker compose ls` reports "running(1)" and "running(11)" identically, so one leftover container
# held a whole agent seat. Measured 2026-08-09: the board sat at 5/4 for hours with THREE real stacks
# running, and every routing decision that session was made against a number wrong by two.
#
# ⚠ THE REMNANT IS THE `test` SIDECAR, AND THE TICKET'S GUESS AT ITS ORIGIN WAS WRONG — it is not
# "a partial init.sh". Measured on the live box 2026-08-10:
#
#     strength_strength           1 container    service=test    up 38 hours   <- debris
#     strength_strength-anthony  11 containers   incl. api       up 2 days     <- real
#
# `test` is the dedicated runner the PRE-COMMIT HOOK uses, so a remnant is what any checkout gets
# after someone commits in it without ever running init.sh. That is why the shared main checkout grew
# one and why these will keep appearing — which is exactly why the predicate must key on what a REAL
# stack HAS, not on what the debris happens to be called.
#
# THE PREDICATE: a project occupies a seat once it has an `api` container — the service a stack
# exists to run, and the one no remnant has.
#
# ⚠ AND A THIRD CASE NEITHER ARM OF THE OBVIOUS TEST COVERS. A stack genuinely mid-`init.sh` also has
# few containers and no api yet: `api` waits on db's healthcheck before it is even created. If that
# did not count, two agents starting seconds apart would BOTH see a free seat and both proceed — the
# check-then-act shape this repo has already been bitten by (GenerateUniqueUsernameAsync, concurrent
# registration, a raw 500). So youth counts as occupancy.
#
# THE ASYMMETRY IS DELIBERATE. Over-counting costs a false refusal: visible, annoying, and it tells
# you what to do. Under-counting silently oversubscribes a box already driven to load 182 on 32
# cores. So an unreadable age fails TOWARD counting.
AGENT_STACK_UP_SERVICE="${AGENT_STACK_UP_SERVICE:-${STACK_HEALTH_SERVICE:-api}}"   # the service whose container means "this stack is up" (harness.env)
# Generous on purpose — `api` can take tens of seconds to appear behind db's healthcheck, and the
# cost of generosity is a transient false refusal that clears itself.
AGENT_STACK_STARTING_GRACE="${AGENT_STACK_STARTING_GRACE:-600}"

# stack_occupancy <space-separated services> <youngest container age, seconds> [grace]
#   up       — has the service a real stack runs; it holds a seat
#   starting — no such service yet, but something here is younger than the grace
#   remnant  — no such service and nothing recent: debris
stack_occupancy() {
  local services=" ${1:-} " age="${2:-}" grace="${3:-$AGENT_STACK_STARTING_GRACE}"
  [[ "$services" == *" $AGENT_STACK_UP_SERVICE "* ]] && { printf 'up\n'; return 0; }
  [[ "$age" =~ ^[0-9]+$ ]] || { printf 'starting\n'; return 0; }
  (( age < grace )) && { printf 'starting\n'; return 0; }
  printf 'remnant\n'
}

# occupancy_note <occupancy> <max restart count across the project, may be empty>
#   -> the trailing annotation for the listing, or empty
#
# ⚠ THIS EXISTS SO THE LISTING CAN STOP ASSERTING A DIRECTION IT CANNOT KNOW.
# It used to print `no api yet, but coming up` for every `starting` stack. That is a claim about
# where the stack is HEADED, and `stack_occupancy` is given only services and age — on those two
# inputs a stack mid-init and a stack whose api has just died are genuinely indistinguishable.
# The measured instance was a crash loop: `uinet` at 18 restarts on `host not found in upstream
# "pwa"`, api long gone, and the tool said it was coming up.
#
# ⚠ IT IS SEPARATE FROM `stack_occupancy` ON PURPOSE. The seat arithmetic is NOT changed by this
# ticket and must not drift into it: a dying stack holds a seat for at most the grace and that
# bounded over-count is the deliberate asymmetry documented above. Wording lives here; counting
# lives there; nothing reads back the other way.
#
# ⚠ NEITHER BRANCH MAY CLAIM A DIRECTION. Zero restarts is not evidence of health either — an api
# removed cleanly leaves no restarts behind. So both branches report WHAT IS KNOWN and leave the
# reader to look, which is the standard agent-stacks.sh already sets for itself: the listing must
# show what it decided, or the next person goes outside the tool again.
occupancy_note() {
  local occ="${1:-}" restarts="${2:-}"
  case "$occ" in
    remnant)  printf '  <- NOT counted: no api container, nothing recent — leftover, not a stack'; return ;;
    starting) ;;
    *)        return ;;
  esac
  if [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts > 0 )); then
    printf '  <- counted: no api, and %s restart(s) — starting slowly, or crash-looping; `docker ps` says which' "$restarts"
  else
    printf '  <- counted: no api yet; no restarts seen'
  fi
}

# $1 = how many OTHER agent stacks are live   $2 = 1 if THIS stream's stack is already among them
# $3 = the limit.  Echoes: allow | refuse
#
# THE SELF-EXCLUSION IS LOAD-BEARING. init.sh is idempotent and gets re-run all session long. An
# agent whose stack is already up is RE-ATTACHING, not entering — it adds nothing to the box, and
# refusing it would lock the fourth agent out of their own running stack the moment the box filled.
cap_verdict() {
  local others="$1" mine_up="$2" limit="$3"
  [[ "$mine_up" == 1 ]] && { echo allow; return; }
  if [[ "$others" -ge "$limit" ]]; then echo refuse; else echo allow; fi
}

# ── THE CI SLOT (infra_stack_cap_ci_slot · epic_self_hosted_ci_runner) ────────────────────────────
# The self-hosted runner's verify stack. It includes docker-compose.override.yml — that is what
# makes scripts/verify.sh work inside it — so the override rule alone would count it as an agent,
# and the moment phase 3 turns `pull_request` back on, a CI verify would silently eat a human's
# seat (or be refused one, which blocks everyone's merges once its check is required).
#
# The reserved seat is NAME-scoped BY DESIGN, and that is not the deny-list smell the header of
# agent-stacks.sh warns about: the policy itself is "the fifth seat belongs to this exact project
# and nothing else". A blanket AGENT_STACK_LIMIT bump would hand the seat to ANY fifth stack.
# CI can never hold more than one seat because it is one compose project — a second CI verify
# reuses the same project name, and the single runner runs one job at a time anyway.
# (docs/design/self-hosted-runner-migration.md §6; owner-action-items §33.2.)
CI_STACK_PROJECT="${CI_STACK_PROJECT:-${HARNESS_PROJECT:-harness}_ci}"   # scripts/ci-stack-project.sh names CI stacks <project>_ci_<runner>

# ⚠ A PREFIX, NOT AN EXACT MATCH — load-bearing for the agent cap, not cosmetic.
#
# CI no longer runs under one project name. Each lane has its own
# (fix_ledger_lane_verify_destroys_the_code_lane_ci_stack): strength_ci_forge-box,
# strength_ci_canary-box, strength_ci_nightly, strength_ci_dispatch, strength_ci_ui. An exact
# match would classify every one of those as ANOTHER AGENT'S stack, so a running CI job would
# consume one of the four machine-wide agent seats and init.sh would start refusing agents — a
# failure that presents as "an agent cannot start" with nothing pointing at CI.
#
# ⚠ AND strength_ci_ui WAS ALREADY MISCLASSIFIED, before any rename: the manual UI job has had
# its own name since it was written and the exact match never covered it. This closes that too.
#
# Agent projects are `strength_strength-<name>` (derived from the worktree directory), so the
# `strength_ci` prefix cannot collide with one; requiring the `_` separator keeps a hypothetical
# `strength_cider` out.
is_ci_stack() { [[ "$1" == "$CI_STACK_PROJECT" || "$1" == "${CI_STACK_PROJECT}_"* ]]; }

# ── THE PERMANENT TEST STACK — INFRASTRUCTURE, NOT A DEVELOPER ──────────────────────────────────────
# The owner's rule is four DEVELOPERS ("if I can't have 4 developers I don't want another runner",
# 2026-09-27), so an infrastructure stack must never take one of the four.
#
# ⚠⚠ THE OVERRIDE RULE USED TO EXCLUDE THIS FOR FREE, AND IT STOPPED: docker-compose.test-local.yml
# has no dev override, so `iron-forge-test-local` was not an agent by construction. But `docker
# compose ls` reports the UNION of every compose file ever used under a project name, and on
# 2026-09-28 another worktree had started two containers (uinet, playwright) under this same pinned
# name WITH its docker-compose.override.yml. From that moment the TEST stack matched the agent rule,
# its directory was read from its first config file (/srv/ironforge/strength-autodeploy), and it was
# listed as "(unnamed)" holding one of the four seats — which refused a developer an init.sh.
#
# So the exclusion is keyed on a DECLARED IDENTITY — the project name scripts/test-local.sh pins —
# never on the "(unnamed)" fallback, which a genuinely unnamed agent stack also produces and which
# must still count. Exact match: nothing else on this box legitimately carries this name.
# ⚠ ONE NAME, TWO FILES: scripts/test-local.sh's `PROJECT=` is the source; the self-test asserts the
# two agree, so a rename there cannot silently turn TEST back into a developer seat.
# (fix_agent_stacks_counts_the_permanent_test_autodeploy_stack_as_one_of_the_four_developer_slots)
# ⚠ INFRASTRUCTURE IS DECLARED, NOT GUESSED. The seeded project counted its permanent test/auto-deploy
# stack as one of the four developer slots for weeks (fix_agent_stacks_counts_the_permanent_test_autodeploy_stack…):
# a stack that is not an agent's must be NAMED in harness.env (INFRA_STACK_PROJECTS, space-separated
# compose project names), and the listing says so beside each one. Unlisted = counted.
INFRA_STACK_PROJECTS="${INFRA_STACK_PROJECTS:-${TEST_STACK_PROJECT:-}}"
is_test_stack() { local p; for p in $INFRA_STACK_PROJECTS; do [[ "$1" == "$p" ]] && return 0; done; return 1; }
is_infra_stack() { is_test_stack "$1"; }

# ── Pure decision 3, asserted by --selftest ───────────────────────────────────────────────────────
# stdin: agent_stacks_from_json output.  $1 = THIS stream's compose project.
# stdout: "<others>\t<mine_up>\t<ci_up>" — the CI stack is classified FIRST, so it never lands in
# `others` (it does not consume agent arithmetic) and never in `mine_up` (its own admission is the
# $CI bypass in agent-stacks.sh --check, not a seat at this table).
# ⚠ THE OPTIONAL FOURTH FIELD IS THE OCCUPANCY VERDICT (stack_occupancy). A `remnant` holds no seat.
# It is OPTIONAL so that every caller and every self-test written before occupancy existed keeps its
# exact meaning — and an ABSENT verdict counts, which is the same fail-toward-counting asymmetry
# stack_occupancy uses. A caller that cannot read docker must not thereby free four seats.
classify_stacks() {
  local my_proj="$1" proj dir status occ _extra others=0 mine_up=0 ci_up=0
  # ⚠ THE TRAILING `_extra` IS LOAD-BEARING, NOT TIDINESS. `read` puts every remaining field into the
  # LAST name, so without it a 5-field line makes `occ` the string `remnant<TAB>0` — and the
  # `[[ "$occ" == remnant ]]` guard below stops matching, which silently starts COUNTING debris.
  # The listing gained a 5th field (max restart count) for wording only; this is the reader that
  # would have turned a wording change into a seat-arithmetic change. Driven: see the self-test's
  # "a 5-field line still excludes debris".
  while IFS=$'\t' read -r proj dir status occ _extra; do
    [[ -n "$proj" ]] || continue
    # Debris is not an agent. Note this is checked BEFORE the CI arm: a CI remnant is debris too,
    # and reporting a reserved seat that nothing occupies is its own small lie.
    [[ "$occ" == remnant ]] && continue
    # The permanent TEST stack is infrastructure: never a developer seat, never "mine".
    is_test_stack "$proj" && continue
    if is_ci_stack "$proj"; then ci_up=1
    elif [[ "$proj" == "$my_proj" ]]; then mine_up=1
    else others=$((others + 1)); fi
  done
  printf '%s\t%s\t%s\n' "$others" "$mine_up" "$ci_up"
}

# ── Live: what each compose project actually has running ─────────────────────────────────────────
# stdout: <project>\t<space-separated services>\t<youngest container age in seconds>\t<max restart count>
# ⚠ THE 4th FIELD IS EVIDENCE FOR THE LISTING, NEVER FOR THE COUNT. `docker ps -q` does list a
# container in the `restarting` state — driven with a `--restart=always` container that exits 1,
# which appears in `docker ps` as `Restarting (1)` and inspects with a rising `.RestartCount` —
# so a crash loop IS visible here. Confirming that first mattered: if the enumerator could not
# see the subject, every assertion built on it would have passed while reading nothing.
# ONE inspect for every container on the box, rather than a docker call per project — this runs on
# the init.sh path and the box is often the thing under load.
stack_container_facts() {
  local now; now="$(date +%s)"
  docker ps -q 2>/dev/null \
    | xargs -r docker inspect --format \
        '{{index .Config.Labels "com.docker.compose.project"}}	{{index .Config.Labels "com.docker.compose.service"}}	{{.Created}}	{{.RestartCount}}' 2>/dev/null \
    | awk -F'\t' -v now="$now" '
        $1 == "" { next }
        {
          # .Created is RFC3339; strip to seconds and let date do the parsing once per line.
          ts = $3; sub(/\..*/, "", ts); sub(/Z$/, "", ts); gsub(/T/, " ", ts)
          cmd = "date -u -d \"" ts "\" +%s 2>/dev/null"
          cmd | getline epoch; close(cmd)
          age = (epoch == "" ? -1 : now - epoch)
          svc[$1] = svc[$1] " " $2
          if (!(($1) in youngest) || age < youngest[$1]) youngest[$1] = age
          r = ($4 ~ /^[0-9]+$/ ? $4 + 0 : 0)
          if (!(($1) in restarts) || r > restarts[$1]) restarts[$1] = r
        }
        END { for (p in svc) { sub(/^ /, "", svc[p]); print p "\t" svc[p] "\t" youngest[p] "\t" restarts[p] } }
      '
}

# Best-effort label for a stack: the agent name from its worktree, or an honest admission.
# NEVER used for the count — see the header. A worktree under another user's home is unreadable by
# design, and that must degrade to a worse MESSAGE, never to a wrong ANSWER.
. "$(dirname "${BASH_SOURCE[0]}")/agent-name.sh"

holder_of() {
  local dir="$1" n
  # ⚠ agent_name_of, NOT agent_name_resolved. This is asking who holds ANOTHER worktree, and the
  # environment belongs to whoever ran this command, not to the directory being read — falling back to
  # $AGENT_NAME here would label a peer's stack with MY name, a confident wrong answer to the one
  # question this tool exists to answer.
  # (fix_agent_name_requires_init_sh_so_non_stack_agents_cannot_claim)
  n="$(agent_name_of "$dir")"
  if [[ -n "$n" ]]; then
    printf '%s' "$n"
  elif [[ -d "$dir" ]]; then
    printf '(unnamed)'
  else
    printf '(another user — worktree not readable from here)'
  fi
}

