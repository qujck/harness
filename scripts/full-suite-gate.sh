#!/usr/bin/env bash
# scripts/full-suite-gate.sh — may a PR merge, given main's last completed FULL-SUITE run?
# (infra_split_the_required_check_into_a_five_minute_subset_and_a_timed_full_suite)
#
#   bash scripts/full-suite-gate.sh            # query the real state, print a verdict, exit 0/1
#   bash scripts/full-suite-gate.sh --self-test
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────────────────────
# A per-PR Playwright subset buys the merge seat back and pays for it in coverage: specs the subset
# defers are no longer proven before a merge. The owner's decision is that the full suite runs
# HOURLY against main, off the critical path, and that **a red full suite BLOCKS THE MERGE QUEUE**.
#
# ⚠ BLOCKING WAS CHOSEN OVER ALERTING BECAUSE BOTH OUR NOTIFICATION PATHS FAIL SOFT, and that is
# measured rather than assumed:
#   · the nightly's alert is `continue-on-error: true` wrapped around `curl … || echo "(non-fatal)"`;
#   · the pager types into a tmux input box and records the page as SENT
#     (fix_the_pager_types_into_a_pane_and_calls_it_delivered), then de-duplicates the retry away.
# A block needs no channel at all: the factory visibly stops within one PR, and whoever is next to
# merge finds out immediately, on their own PR, in the place they are already looking.
#
# ── ⚠ THE RULE THIS FILE EXISTS TO ENFORCE: "RED" AND "COULD NOT LOOK" ARE NOT THE SAME STATE ────
# Same family as fix_claim_janitor_cannot_tell_no_open_issues_from_could_not_look, and the same
# family as the three collapses fixed on 2026-08-15 alone (an alert stating an unestablished
# hypothesis; a guard reading "could not read" as "read zero"; a reporter reading "nothing produced
# a result" as "my extractor is broken").
#
#   RED           -> BLOCK. The suite ran and said no.
#   GREEN         -> PROCEED.
#   ANYTHING ELSE -> PROCEED, LOUDLY. A broken query, a cancelled run, or no run yet must NEVER halt
#                    the factory. A gate that stops everything when it cannot see is a self-inflicted
#                    outage, and it would fire on exactly the days the API is having a bad morning.
#
# ⚠ A CANCELLED RUN IS NOT A PASS AND NOT A FAILURE. ci.yml already says so about the nightly — "a
# cancelled drift-detector is a gap, not a verdict" — so it lands in cannot-tell, which proceeds.
# Reading cancelled as green would hide a real red; reading it as red would stop the queue every
# time somebody force-pushes.
#
# ⚠ AND A PERSISTENT cannot-tell IS ITS OWN ALARM. Proceeding is right for one tick and wrong for a
# day: it means the safety net has been absent that whole time while every PR merged normally. The
# caller reports it; see FULL_SUITE_STALE_HOURS.
set -uo pipefail
# ⚠ 2, NOT 0 — SAME REASONING AS THE cannot-tell ARM 1,235 LINES BELOW, WHICH THIS LINE MISSED.
# (fix_the_full_suite_gate_exits_green_when_it_cannot_reach_its_own_repo)
# A failed cd means this gate could not reach the repository it is meant to judge. Exit 0 does not
# say that: at ci.yml's blocking step, 0 means MAIN'S LAST FULL SUITE WAS GREEN. So the one arm
# that knows least would have told the merge queue the safety net ran and passed.
# The `exit 2` arm at the bottom of this file was written to fix exactly this conflation — "that
# made ONE exit code carry TWO consequences, and only one of them was ever decided" — and was
# applied only where the bug was found. This is the same defect, in the same file, above it.
# ⚠ AND 1 IS STILL THE WRONG ANSWER, for the reason that arm gives: a gate that halts the factory
# whenever it cannot see is a self-inflicted outage. Both consumers already have an explicit rc=2
# arm (ci.yml warns and proceeds), so nothing downstream needs to change.
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
# Absolute path to THIS file, resolved AFTER the cd above — the self-test re-invokes the whole
# script end to end, and a relative BASH_SOURCE would not survive the change of directory.
_SELF="$PWD/scripts/$(basename "${BASH_SOURCE[0]}")"
. "$(dirname "${BASH_SOURCE[0]}")/lib/selftest-flag.sh" 2>/dev/null || true
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness-env.sh" 2>/dev/null || true
# The stage report's ONE renderer, shared with the job summary and the hourly alert so the three cannot word
# it differently. (infra_the_verify_stage_chain_hides_the_whole_browser_suite_behind_any_earlier_red)
. "$(dirname "${BASH_SOURCE[0]}")/verify-stages.sh"
# run_death_site now lives in the shared lib — full-suite-gate.sh and merge-queue-metrics.sh
# both need the same answer to "where did this run die", and two copies of it would drift.
# (fix_merge_queue_metrics_buckets_a_setup_death_as_a_test_red)
# shellcheck source=scripts/lib/gh-checks.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/gh-checks.sh"

# ⚠ THE OFF-SWITCH, AND IT IS A REQUIREMENT RATHER THAN A CONVENIENCE. The owner called this an
# experiment; an experiment you cannot stop is a migration. Setting the repo variable
# FULL_SUITE_ON_EVERY_PR=1 reverts to full-suite-on-every-PR and makes this gate inert — no PR, no
# merge, no queue wait, which is the point: the revert must not need the pipeline it is reverting.
OFF_SWITCH="${FULL_SUITE_ON_EVERY_PR:-0}"
STALE_HOURS="${FULL_SUITE_STALE_HOURS:-6}"
# ⚠ THE CEILING A HEALTHY CYCLE CANNOT EXCEED, USED FOR THE NOTICE ONLY — NOT FOR BLOCKING.
# Derived from measurement rather than chosen as a round number: the hourly's period is 60 minutes
# and five consecutive samples on 2026-09-06 ran 1740-1800s, so the newest verdict is at most
# ~90 minutes old when the schedule is keeping up. `STALE_HOURS` is deliberately NOT changed here —
# making the gate SPEAK is the fix; re-picking the blocking threshold is a separate decision that
# should be made against what the speaking then shows.
FULL_SUITE_EXPECTED_CYCLE_S="${FULL_SUITE_EXPECTED_CYCLE_S:-5400}"
# What THIS run proved about the tree that will actually land. ci.yml sets it to 'green-full' ONLY
# when the route it chose was the full suite — reaching this step is what proves the suite passed.
# Never set from anything a PR author writes; see the header on queue_block_verdict.
OWN_RESULT="${FULL_SUITE_OWN_RESULT:-}"
# ⚠ WORDING ONLY — never consulted by queue_block_verdict. See blocked_lane_advice.
# (docs_the_full_suite_gate_blocks_a_lane_that_can_never_clear_itself)
LANE="${FULL_SUITE_LANE:-}"
# ── THE REPAIR LANE: evidence READ from a sibling job, never declared ───────────────────────────
# (infra_a_repair_pr_proves_the_full_suite_itself_and_the_gate_accepts_it, 2026-09-06)
# A PR labelled `repair-main` gets ci.yml's `repair` job: the FULL suite on the merged tree, ending
# in a step that reads Playwright's own results files and fails unless specs ran and passed. When
# this gate would otherwise BLOCK, and the PR carries the label, it waits for that job and reads its
# conclusion from the API. Success + that step passed = the `green-full` own-result the escape has
# always required. Nothing here is set from anything a PR author writes: the run id is this run,
# the job and step are named by ci.yml, and the verdict is GitHub's record of what executed.
# ⚠ Only consulted when the verdict WOULD BE block. A green main asks nothing of the repair job.
# ── A DISPATCHED FULL SUITE COUNTS AS A VERDICT, BY ITS RUN NAME ────────────────────────────────
# (infra_a_merged_repair_triggers_the_full_suite_on_main_at_once, 2026-09-06)
# When a repair-main PR merges, verify's merge step dispatches the hourly job on main at once instead
# of leaving the block up until the next :07. ci.yml names such a run `full suite on main
# (dispatched)` via `run-name:`, and this gate reads workflow_dispatch runs on main whose title is
# exactly that, merged with the scheduled runs by time. Other dispatches (run_ui, run_e2e — hosted
# jobs, no full suite) keep the workflow's default name and are never read. Keyed on the NAME the
# workflow gives its own run, not on anything a person types.
DISPATCH_TITLE="${FULL_SUITE_DISPATCH_TITLE:-full suite on main (dispatched)}"
REPAIR_RUN_ID="${FULL_SUITE_REPAIR_RUN_ID:-}"
REPAIR_JOB="${FULL_SUITE_REPAIR_JOB:-repair full suite (main is red)}"
REPAIR_PROOF_STEP="${FULL_SUITE_REPAIR_PROOF_STEP:-Prove the browser suite ran}"
REPAIR_LABELLED="${FULL_SUITE_REPAIR_LABELLED:-0}"
REPAIR_WAIT_S="${FULL_SUITE_REPAIR_WAIT_S:-2700}"   # 45 min: the suite is ~30, the seat may be busy
REPAIR_POLL_S="${FULL_SUITE_REPAIR_POLL_S:-60}"
# WHICH JOB IS ASKING — `verify` or `route`. WORDING ONLY, never consulted by
# queue_block_verdict: the two callers know different things about the branch, and an unset
# value gets the neutral form rather than the stronger claim. See blocked_branch_note.
CALLER="${FULL_SUITE_CALLER:-}"

# ── the pure half ───────────────────────────────────────────────────────────
# repair_job_verdict <jobs-json> <job-name> <proof-step-name> -> green-full | red | running | absent
#   The GitHub jobs listing for ONE run, and the names ci.yml gives the repair job and its proof
#   step. `green-full` only when the job CONCLUDED success AND the proof step itself concluded
#   success — a job that skipped the step, or a step that was cancelled, is `red`, never green.
#   `absent` means no such job in this run (the event carried no label); `running` means wait.
repair_job_verdict() { # <jobs_json> <job> <step>
  local json="$1" job="$2" step="$3"
  [[ -n "$json" ]] || { printf 'absent'; return 0; }
  jq -r --arg j "$job" --arg s "$step" '
    [ .jobs[]? | select(.name == $j) ] as $J
    | if ($J | length) == 0 then "absent"
      else ($J | last) as $job
      | if $job.status != "completed" then "running"
        elif $job.conclusion == "success"
             and ([ $job.steps[]? | select(.name == $s and .conclusion == "success") ] | length) > 0
        then "green-full"
        else "red" end
      end' <<<"$json" 2>/dev/null || printf 'absent'
}
# repair_proof_verdict <labelled 0|1> <repair-verdict> -> not-required | proven | refused      (pure)
# (infra_a_repair_main_pr_whose_own_full_suite_is_red_is_landed_anyway_because_only_verify_is_required)
#   The `repair-main` label is a CLAIM: "this PR proves the full suite on the tree that will land".
#   A claim the run disproved must not land, IN EVERY STATE OF MAIN. Before this, the repair job's
#   verdict was read ONLY as the escape when main was red; when main happened to be green the gate had
#   nothing to escape, never looked, and #9352 landed at 23:30Z with its own repair job RED (22:35 ->
#   23:11) on a green subset — and turned main red. Anything but `green-full` refuses: red, absent (a
#   skipped or cancelled job is absent proof), still running at the wait limit, or unreadable.
repair_proof_verdict() { # <labelled> <repair_verdict>
  [[ "${1:-0}" == 1 ]] || { printf 'not-required'; return 0; }
  [[ "${2:-}" == green-full ]] && printf 'proven' || printf 'refused'
}
# ────────────────────   <- ⚠ THIS LINE HAD NO LEADING '#' AND BASH TRIED TO RUN IT. Every invocation of this gate printed
#   "line 117: ────────────────────: command not found" to stderr — on main, on every PR, for as long
#   as it has been there. Non-fatal, so nothing failed and nobody looked. ⚠ It is fixed here rather
#   than filed because THIS gate's whole job in this ticket is to make a degradation legible, and a
#   spurious error on every run is exactly the noise that teaches a reader to skim its output.

# queue_block_verdict <conclusion> <off-switch> -> block | proceed | cannot-tell        (pure)
#
# <conclusion> is the GitHub conclusion of main's last COMPLETED full-suite run, or one of the
# sentinels the caller substitutes: '' (no run found), 'QUERY_FAILED' (the API call failed).
# <where> is WHERE THE RUN DIED, supplied by the impure half: 'setup' (it never reached the suite),
# 'suite' (it ran and failed), or '' / 'unknown' (could not establish).
#
# ⚠ THIS THIRD ARGUMENT EXISTS BECAUSE A CONCLUSION IS NOT A CAUSE, AND THE GAP IT CLOSES IS THE ONE
# THIS FILE'S HEADER WARNS ABOUT BY NAME. The contract above says RED means "the suite ran and said
# no" — but a run whose job dies at `Set up job`, because codeload 429s the `actions/checkout`
# download, also concludes `failure`. Byte-identical, opposite meanings.
#
# MEASURED 2026-08-17: main's 14:08 hourly (sha 75df3ad4) died exactly that way —
#   ##[error]Response status code does not indicate success: 429 (Too Many Requests).
#   ##[error]Failed to download archive 'https://codeload.github.com/actions/checkout/…'
# NOT ONE SPEC RAN, and the queue was blocked with no code defect anywhere in the repo. The header
# predicted this in as many words: "it would fire on exactly the days the API is having a bad
# morning." It was a bad morning.
#
# ⚠ `unknown` BLOCKS, and that asymmetry is deliberate. Not knowing where it died is not the same as
# knowing it never started: a `failure` we cannot explain is still most likely a real red, and this
# gate's whole purpose is to stop the queue on one. Only a POSITIVE identification of a setup death
# downgrades it — the same rule the readiness probes landed on today, where "no marker" must never
# be read as "ours but wrong". The caller says so out loud when it cannot establish the step.
# (fix_the_merge_queue_gate_reads_a_setup_failure_as_a_test_red)
# ⚠ THE FOURTH ARGUMENT IS THE ESCAPE FROM THE CYCLE, AND IT IS KEYED ON EVIDENCE, NEVER ON INTENT.
# <own> is what THIS run proved about the tree that will actually land: 'green-full' means this run
# executed the FULL suite on the merged tree (ci.yml merges current origin/main into the branch
# before testing) and reached this gate, which it can only do if every earlier step passed. Anything
# else — a subset run, no information — is ''.
#
# WHY IT MUST EXIST. The gate reasons from a STALE reading: main's last COMPLETED full suite. But a
# PR that has just run a green full suite on the merged tree holds a NEWER and truer reading of what
# main is about to become. Rejecting it on the older one is backwards, and it is the whole deadlock:
# on 2026-08-19 main was red for ten hours, 16 PRs were blocked, and the only way out was a human
# turning the net off — including for the PR that repaired main. Second occurrence; 2026-08-17 was an
# unpinned type manifest. Two unrelated causes, one identical cycle.
#
# ⚠ IT IS NOT FORGEABLE AND THAT IS THE POINT. A label, a title prefix, a `fixes-main` marker are all
# DECLARED, and the person most likely to reach for one is somebody certain they are right during
# exactly this kind of outage. This is not declared: ci.yml sets it only when the route it chose was
# the full suite, and reaching this step at all is what proves the suite was green.
#
# ⚠⚠ AND HERE IS THE PROPERTY THAT IS EASY TO STATE WRONGLY — I STATED IT WRONGLY FIRST, AND DON
# CAUGHT IT. It is tempting to write "the net holds by construction, because the merged tree CONTAINS
# main's breakage, so a PR that does not repair main fails its own full suite and is still refused."
# THAT IS ONLY TRUE FOR ONE OF THE TWO FAILURE CLASSES:
#
#   (a) breakage that REPRODUCES on merged trees (2026-08-17's unpinned type manifest). The net holds
#       exactly as described — only a PR that genuinely repairs main can go green here.
#   (b) breakage that is MAIN-ONLY (2026-08-19's selftest, which fails only where
#       `origin/main..HEAD` is empty — measured: main shape exit 1, a branch 5 commits ahead exit 0).
#       It appears on NO merged tree, every PR runs a green full suite, and every PR takes this
#       escape. The gate is then effectively INERT until main is repaired.
#
# Class (b) is arguably the right outcome — a failure that cannot manifest on any merged tree does
# not endanger stacking — but it must be a STATED property, not an accident nobody can see. **This
# function cannot tell the two apart**: distinguishing them needs main's tip tested alone, which is
# the hourly run, not this one. So the caller says both classes out loud whenever the escape is
# taken, and emits a countable marker — because "every PR merged under the escape" and "the PR that

# blocked_lane_advice <lane> -> what this PR can and cannot do about the block   (pure)
# (docs_the_full_suite_gate_blocks_a_lane_that_can_never_clear_itself)
#
# ⚠⚠ THE TEXT THIS REPLACES TOLD SIX OF SEVEN BLOCKED PRs TO DO SOMETHING THAT CANNOT WORK.
# It said, unconditionally: "RE-RUN THIS PR — route will see the red main, promote it to the full
# suite, and it can then admit itself." That is TRUE for the code lane and FALSE BY CONSTRUCTION for
# the ledger lane, which never runs the suite at all. Measured on 2026-08-22, the seven PRs blocked
# 17:16–18:46: SIX were ledger-lane (features/*.json only), ONE was code. So the advice was wrong
# for six of seven readers, and wrong in the direction that costs them a seat.
#
# ⚠ AND IT IS WORSE THAN USELESS FOR THEM, NOT MERELY UNHELPFUL. A re-run consumes the same
# serialised runner the CURING hourly is queued behind, so following the instruction lengthens the
# very wait it claims to shorten — while looking exactly like progress. Same for an empty commit.
#
# ⚠ STATED AS AN IMPOSSIBILITY, NEVER A DELAY. Wording that reads as "this may take a while" invites
# retrying, re-running and pushing empty commits — all of which do nothing, all of which look like
# action. `route` already emits this fact at promotion time
# (fix_a_ledger_lane_pr_takes_the_full_suite_escape_without_running_the_suite), in the route job's
# log, which is not where somebody staring at a blocked PR is looking. This is the same fact, said
# where it is read.
#
# ⚠ NOTHING HERE CHANGES WHAT BLOCKS. The lane is used for WORDING ONLY — it is never consulted by
# queue_block_verdict, and a lane must never become a way to self-certify. An unknown or empty lane
# gets the union of both messages rather than a guess.
# blocked_branch_note <caller: verify|route|''> -> the clause saying WHAT THIS BLOCK SAYS ABOUT THE
#                                                  BRANCH, for the first annotation line     (pure)
# (infra_a_blocked_merge_queue_reports_every_waiting_pr_as_failed, shape (c'))
#
# ⚠ THE TICKET IS NAMED FOR THIS SENTENCE. A red main made every waiting PR's required check go
# FAILURE, so **"cannot merge yet" and "this PR is bad" were reported as the same thing** — and the
# blocking arm in ci.yml was a bare `exit "$rc"`, saying nothing at all about whose fault it was not.
#
# ⚠ THE CALLER MATTERS AND IS NOT COSMETIC, BECAUSE THE TWO CALLERS KNOW DIFFERENT THINGS.
# `verify` reaches its gate step LAST — steps run in order and stop at the first failure — so
# **arriving here PROVES the branch's own tests passed.** `route` runs FIRST and knows nothing about
# the branch yet. Emitting verify's sentence from route would assert a pass that has not happened;
# emitting route's from verify would discard a fact a ~25-minute run had just established.
#
# ⚠ AN UNKNOWN CALLER GETS THE NEUTRAL FORM AND MUST NEVER CLAIM A PASS. Same reasoning as
# `applier_note`'s unknown-provenance arm in ledger-migrate.sh: a missing value silently rendering as
# the stronger claim is how a caveat stops existing. Asserted below as its own case.
blocked_branch_note() { # <caller>
  case "${1-}" in
    verify) printf 'THIS BRANCH WAS NOT JUDGED BAD — its own tests PASSED, and reaching this gate is what proves it.' ;;
    route)  printf 'This PR has not been judged yet — verify will still run and report on the branch itself.' ;;
    *)      printf 'This block is about MAIN, not about this branch.' ;;
  esac
}

blocked_lane_advice() { # <lane>
  local lane="${1-}"
  printf '\n'
  case "$lane" in
    ledger)
      printf '⚠⚠ THIS PR IS ON THE LEDGER LANE, SO IT CAN NEVER OPEN THAT ESCAPE — not slowly, not\n'
      printf 'expensively, NOT AT ALL. A ledger-lane run does not execute the full suite by construction,\n'
      printf 'so it can never hold the green full suite the escape requires. THERE IS NOTHING YOU CAN DO\n'
      printf 'TO THIS PR THAT WILL ADMIT IT. It clears when main goes green and not before.\n'
      printf '\n'
      printf '⚠ SO DO NOT: re-run it, push an empty commit, rebase it, or close and reopen it. None of\n'
      printf 'those runs the suite, and a re-run is ACTIVELY COUNTERPRODUCTIVE — it consumes the same\n'
      printf 'serialised runner the curing hourly is queued behind, so it makes the wait LONGER.\n' ;;
    full)
      printf '⚠ MOST LIKELY CAUSE, AND IT HAS A CHEAP FIX: the promotion to the full suite is decided by\n'
      printf 'the `route` job BEFORE the suite runs. If route ran while main was still green and main went\n'
      printf 'red afterwards, this run was already committed to the subset. RE-RUN THIS PR — route will\n'
      printf 'see the red main, promote it to the full suite, and it can then admit itself.\n'
      printf '⚠ This applies because your lane is `full`. It would NOT work on the ledger lane.\n'
      printf '\n'
      printf '⚠ RE-RUN THE WHOLE RUN, NOT `--failed`. The reflex spelling is\n'
      printf '      gh run rerun <id> --failed        ← CANNOT WORK HERE\n'
      printf 'and it is the natural thing to type when you are trying not to repeat a 25-minute suite.\n'
      printf 'It re-runs only the jobs that FAILED, and `route` — the job that decides the promotion —\n'
      printf 'SUCCEEDED. So the decision that has to change is the one thing `--failed` will not re-take.\n'
      printf 'Use:  gh run rerun %s\n' "${GITHUB_RUN_ID:-<run-id>}"
      printf '\n'
      printf '⚠ AND CHECK THE ATTEMPT ACTUALLY INCREMENTED — do NOT trust the exit status. A re-run\n'
      printf 'issued while a CANCEL is still in flight returns SUCCESS and does nothing (measured on\n'
      printf '#7258: the command reported ok and the run was still at attempt=1):\n'
      printf '      gh run view %s --json attempt --jq .attempt\n' "${GITHUB_RUN_ID:-<run-id>}"
      ;;
    *)
      printf '⚠ WHICH OF THESE APPLIES DEPENDS ON YOUR LANE, AND THIS RUN COULD NOT ESTABLISH IT (lane=%q),\n' "$lane"
      printf 'so both are given rather than guessing. Your lane is in the `route` job summary.\n'
      printf '\n'
      printf 'IF YOUR LANE IS `full`: the promotion is decided by `route` BEFORE the suite runs, so a run\n'
      printf 'committed to the subset while main was still green was already committed to it. RE-RUN THIS PR\n'
      printf '— route will see the red main, promote it, and it can then admit itself.\n'
      printf '\n'
      printf '⚠ RE-RUN THE WHOLE RUN, NOT `--failed`. The reflex spelling is\n'
      printf '      gh run rerun <id> --failed        ← CANNOT WORK HERE\n'
      printf 'and it is the natural thing to type when you are trying not to repeat a 25-minute suite.\n'
      printf 'It re-runs only the jobs that FAILED, and `route` — the job that decides the promotion —\n'
      printf 'SUCCEEDED. So the decision that has to change is the one thing `--failed` will not re-take.\n'
      printf 'Use:  gh run rerun %s\n' "${GITHUB_RUN_ID:-<run-id>}"
      printf '\n'
      printf '⚠ AND CHECK THE ATTEMPT ACTUALLY INCREMENTED — do NOT trust the exit status. A re-run\n'
      printf 'issued while a CANCEL is still in flight returns SUCCESS and does nothing (measured on\n'
      printf '#7258: the command reported ok and the run was still at attempt=1):\n'
      printf '      gh run view %s --json attempt --jq .attempt\n' "${GITHUB_RUN_ID:-<run-id>}"
      printf '\n'
      printf '⚠ IF YOUR LANE IS `ledger`: it can NEVER open the escape, at any cost, on any day — a\n'
      printf 'ledger-lane run does not execute the suite. Re-running is actively counterproductive: it\n'
      printf 'consumes the seat the curing hourly is queued behind. Wait for main to go green.\n' ;;
  esac
  printf '\n'
  printf 'AND WHAT ACTUALLY CLEARS IT, FOR EVERY LANE:\n'
  printf 'the next conclusive SCHEDULED full-suite run on main.\n'
  # ⚠ NO CLOCK IN THIS SENTENCE, DELIBERATELY, AND DO NOT "IMPROVE" IT BACK. It used to read
  # "a fix merging at :16 does NOT clear this — the next hourly does", and both halves invite the
  # same arithmetic: a minutes-past-the-hour, and an interval a reader adds to the last run he saw.
  # ⚠ THIS FILE ALREADY KNEW BETTER AND SAID SO IN A COMMENT NOBODY BLOCKED BY THE GATE READS: the
  # `creation_cadence` header records "12 runs in 24h against ~24 for an hourly cron, gaps median
  # 1.23h and NONE ON THE HOUR". Measured again 2026-08-30 — nine consecutive gaps of 57-63m, then
  # 80m, 54m, 27m. Two agents independently added a nominal hour to the last run, both told each
  # other the block would clear at "~02:20Z", and the clearing run started at 01:47:15Z.
  # ⚠ THE FIX IS SUBTRACTIVE. A computed ETA would be the same defect with a more convincing number
  # on it -- this gate cannot know when GitHub will schedule the next run, so it must not imply it.
  # (docs_the_merge_queue_gate_tells_you_a_clock_time_it_cannot_know)
  printf 'Merging a fix does NOT clear this — only that next scheduled run does, whenever GitHub\n'
  printf 'starts it. Your own run cannot supersede it either: a PR run skips the full-suite job,\n'
  printf 'and a skipped run votes for nothing.\n'
}

# death_site_line <failing-step-name> <job-duration> -> the human line(s), or nothing   (pure)
# (infra_the_merge_queue_block_message_throws_away_the_death_site_it_just_computed)
#
# ⚠ PURE AND SEPARATE SO IT CAN BE DRIVEN. The block message is printf'd inline, which is why the
# `unknown` arm's reasoning could sit in this file for weeks applying to one arm only: nothing
# executed the other arm's text, so nothing could notice it was missing.
#
# ⚠⚠ IT PRINTS THE DURATION BESIDE THE STEP BECAUSE THE STEP ALONE DOES NOT SEPARATE THE CASES.
# Runs 32053471791 and 32586684979 have the SAME failing step name — "Full house gate on main tip
# — bash scripts/verify.sh" — and the same step list. One ran the suite for 23 minutes; the other
# died after 33 seconds in a ledger check, having executed no specs. A fix that named only the step
# would satisfy a careless reading of the ticket and leave the two indistinguishable.
#
# Emits nothing when it knows nothing: a message that omits a detail beats one that invents it.
death_site_line() { # <step> <duration>
  local step="${1-}" dur="${2-}"
  [[ -n "$step" || -n "$dur" ]] || return 0
  printf 'It died'
  # ⚠ %s IN QUOTES, NOT %q. %q backslash-escapes every space, so a real step name renders as
  # `Full\ house\ gate\ on\ main\ tip\ —\ bash\ scripts/verify.sh` — correct shell quoting and
  # markedly harder to read than the thing it names. This line exists to be READ.
  [[ -n "$step" ]] && printf ' at step "%s"' "$step"
  [[ -n "$dur"  ]] && printf ' after %s' "$dur"
  printf '.\n'
  # ⚠ A SHORT RUN IS A CLAIM ABOUT WHAT WAS EXECUTED. Say what it implies rather than leaving the
  # reader to do the arithmetic — the whole failure this fixes is a reader who could not tell "a
  # spec is broken" from "verify.sh fell over before the specs", which need different work.
  # A duration containing "m " is minutes, i.e. plausibly a real suite; anything else is seconds.
  case "$dur" in
    ''|*m\ *) : ;;
    *) printf 'A full suite takes ~22 minutes, so this one did NOT reach the specs — read that step, not a test result.\n' ;;
  esac
}

# fixed main merged under the escape" look identical from inside a single run.
queue_block_verdict() {
  local concl="${1-}" off="${2-0}" where="${3-}" own="${4-}"
  # The off-switch outranks everything, including a red — because its whole job is to be the way
  # out when this experiment is the problem. It cannot require the thing it is disabling.
  [[ "$off" == 1 ]] && { printf 'proceed\n'; return 0; }
  # ⚠ SECOND ONLY TO THE OFF-SWITCH, AND ONLY AGAINST A RED. Against cannot-tell it changes nothing
  # (that already proceeds), and against a green it changes nothing (likewise) — so it can only ever
  # convert a BLOCK into a proceed, which bounds the blast radius of getting it wrong.
  if [[ "$own" == green-full ]]; then
    case "$concl" in
      failure|timed_out|startup_failure|action_required)
        [[ "$where" == setup ]] || { printf 'proceed-on-own-evidence\n'; return 0; } ;;
      # ⚠ THE NEW BLOCK BELOW MUST HAVE THE SAME ESCAPE, OR IT RE-CREATES THE DEADLOCK. Adding a
      # blocking condition without adding it here is how a net becomes a trap: main times out, every
      # PR is refused, and the PR that would repair main is refused with them — the exact ten-hour
      # cycle of 2026-08-19 that `own=green-full` was written to end. A PR that has just run the FULL
      # suite green on the merged tree holds a newer and truer reading than main's stale timeout.
      TIMED_OUT_CANCEL) [[ "$where" == setup ]] || { printf 'proceed-on-own-evidence\n'; return 0; } ;;
    esac
  fi
  case "$concl" in
    failure|timed_out|startup_failure|action_required)
      [[ "$where" == setup ]] && { printf 'cannot-tell\n'; return 0; }
      printf 'block\n' ;;
    success)                                           printf 'proceed\n' ;;
    # ⚠ `cancelled` IS NOT ONE THING, AND THE BRANCH ABOVE PROTECTS A CONCLUSION THIS WORKFLOW HAS
    # NEVER PRODUCED. `timed_out` sits in the blocking list and reads as though timeouts were
    # covered. They are not: **a job that exceeds `timeout-minutes` concludes `cancelled`**, which
    # fell to the catch-all below and proceeded. Measured across 60 scheduled ci.yml runs
    # (2026-09-03 11:08Z – 2026-09-05 20:08Z, 58 hourly jobs terminal): success 35, failure 18,
    # cancelled 4, skipped 2, and `timed_out` **zero times**. The four cancelled ran 45m17s, 45m18s,
    # 45m17s, 45m17s against `timeout-minutes: 45` — identical to the second, and the fourth was
    # predicted forward before it concluded. So the one failure mode that means THE SUITE IS
    # UNHEALTHY was the one that could never block. (`timed_out` stays above: 60 runs of this
    # workflow is not proof GitHub never emits it, and removing it would be trading a live branch
    # for a tidier list.)
    #
    # ⚠ ONLY A POSITIVE IDENTIFICATION UPGRADES IT — the mirror of the `unknown`-blocks rule above,
    # and deliberately the safer direction. A human cancel, a concurrency cancel, an abandoned run
    # and a payload we could not read all still proceed, because none of them carries the evidence.
    # A fix that made every `cancelled` block would re-create the self-inflicted outage the whole
    # rc=2 arm exists to prevent, and it would look like the simpler rule.
    TIMED_OUT_CANCEL)                                  printf 'block\n' ;;
    # skipped / neutral / stale / '' / QUERY_FAILED / anything unrecognised.
    *)                                                 printf 'cannot-tell\n' ;;
  esac
}

# staleness_note <age-hours> <stale-threshold> -> fresh | stale | unknown               (pure)
#
# ⚠ A GREEN THAT IS TWO DAYS OLD IS NOT THE SAME ASSURANCE AS A GREEN FROM TWENTY MINUTES AGO, and
# the verdict alone cannot say which you have. This does not change whether the merge proceeds —
# blocking on staleness would be the self-inflicted outage above — it changes what the PR is TOLD.
# ⚠ IT TAKES SECONDS, NOT HOURS, AND THAT IS A BUG FIX RATHER THAN A REFACTOR.
#
# It took an age already truncated to whole hours by `(( (now_s - then_s) / 3600 ))`, and bash
# integer division floors. So a suite 6.99 hours old arrived as `6`, `(( 6 > 6 ))` was false, and it
# read FRESH — while the warning beside it says "threshold 6h". Driven at the boundary:
#
#     21600s (6.00h) -> AGE_H 6 -> fresh
#     23400s (6.50h) -> AGE_H 6 -> fresh
#     25199s (6.99h) -> AGE_H 6 -> fresh          <- the gap
#     25200s (7.00h) -> AGE_H 7 -> stale
#
# **The effective threshold was 7.00h while the message claimed 6** — up to 59 minutes more
# permissive than it says, which is the stale-fact-in-a-second-place shape: the printed number and
# the behaviour disagreed and only one of them was true.
#
# ⚠ AND IT POINTS THE OPPOSITE WAY TO THE OTHER DEFECT IN THIS FUNCTION. The confirm path below
# prevents a false STALE; this was a false FRESH. Two directions in one function, and the confirm
# path could never have caught it — it runs only when the note is ALREADY stale, so it never
# executes on the happy arm. Found by Vera, 2026-08-27, while #6857 was in flight.
# (infra_the_full_suite_gate_intermittently_reports_a_fresh_suite_as_stale)
staleness_note() {
  local age_s="${1-}" limit_h="${2-6}"
  [[ "$age_s"   =~ ^[0-9]+$ ]] || { printf 'unknown\n'; return 0; }
  [[ "$limit_h" =~ ^[0-9]+$ ]] || limit_h=6
  (( age_s > limit_h * 3600 )) && printf 'stale\n' || printf 'fresh\n'
}

# staleness_verdict <note> <newer-scheduled-run-exists: yes|no|unknown> -> fresh | stale | unknown
#
# ⚠ A `stale` READING FROM A PAGE WE CANNOT PROVE WAS CURRENT IS NOT A FINDING, AND THIS IS THE WHOLE
# OF infra_the_full_suite_gate_intermittently_reports_a_fresh_suite_as_stale.
#
# 2026-08-25 15:03Z the gate warned "the last full suite is 26h old"; measured directly against the
# API seconds later, the last full suite had completed GREEN 40 minutes earlier. Two immediate
# re-runs said `0 hours ago, fresh`. The verdict (the exit code) was correct throughout — nothing
# was blocked — but the staleness WARNING is the only mechanism that would ever tell anybody the
# hourly had stopped, and a warning that cries wolf is one that gets skimmed on the day it is right.
#
# ⚠ WHY THE EXISTING `unknown` STATE DID NOT COVER IT. A FAILED fetch already lands on `unknown`:
# `gh api` non-zero sets QUERY_FAILED, an empty or all-inconclusive page sets NO_CONCLUSIVE_RUN, and
# both leave AGE_H empty, which staleness_note reads as `unknown`. The hole is the fetch that
# SUCCEEDS while LAGGING — a page that returns 200 and simply does not contain the newest completed
# run yet. That yields a real timestamp from a real, older run, and a real timestamp is
# indistinguishable from genuine staleness. It is "could not look" wearing the costume of "looked".
#
# So a `stale` note is CONFIRMED before it is believed: ask whether any scheduled run NEWER than the
# one measured exists in ANY status. If one does, either the page was lagging or the hourly is
# running right now — both mean the schedule is alive and the warning would be false.
#
# ⚠ THE NEGATIVE CONTROL IS PRESERVED, AND IT IS THE POINT: a genuinely absent hourly has nothing
# newer, so `newer=no`, and the warning still fires. A fix that made the false positive go away by
# never warning would have removed the safety net rather than repaired it.
#
# ⚠ AND AN UNCONFIRMABLE STALE IS `unknown`, NOT `stale`. Failing toward silence on a warning is the
# right direction — the ticket's own argument — and it is not actually silent: the caller prints the
# unknown state and why, so "could not confirm" is still said out loud.
#
# ⚠⚠ WHAT THIS WARNING COVERS, AND WHAT IT DOES NOT — MEASURED, AND NARROWER THAN IT READS.
# Driven live at threshold=1h: the newest COMPLETED scheduled run was 5h old and `newer=yes`, because
# scheduled runs newer than it existed without appearing as completed. So `newer=yes` is the ORDINARY
# state whenever the newest completed run is more than about an hour old — which means:
#
#     the hourly STOPS BEING SCHEDULED   -> no new runs are created -> newer=no -> WARNS.  ✓
#     the hourly is scheduled but its
#     runs never COMPLETE                -> newer=yes -> reported unknown, NOT warned.     ✗
#
# The second is a real gap and it is named rather than papered over: this check watches the
# SCHEDULER, not completion. Closing it needs a different question (is any scheduled run completing
# at all?), which is a different measurement and not this ticket's. Do not read a quiet gate as proof
# the suite is completing — only as proof runs are still being created.
# ⚠⚠ `newer` HAS FOUR VALUES AND NOT TWO, AND THE FIRST VERSION OF THIS FIX WAS WRONG BECAUSE IT HAD
# TWO. It asked only "does a newer scheduled run exist?" and treated any `yes` as evidence the page
# had lagged. That conflates two OPPOSITE situations:
#
#     a newer run exists and it COMPLETED    -> our page was behind. The true age is younger than we
#                                               measured, so `stale` is a false alarm.  -> not stale
#     newer runs exist and NONE completed    -> the scheduler is alive and the suite is NOT
#                                               COMPLETING. That is not freshness; it is the outage
#                                               in a different costume.                 -> STILL warn
#
# ⚠ AND THE SECOND IS CLOSE TO THE LIVE STATE, WHICH IS HOW THIS WAS CAUGHT. Measured 2026-08-27:
# the newest scheduled run was `queued` and the newest COMPLETED one was ~5h old; Vera measured the
# hourly running 14 times in 44 hours (~3.1h apart) with four runs taking 78–124 minutes against a
# 60-minute period. So a run is almost always in flight, `newer` is almost always non-empty, and a
# two-valued check would have suppressed the staleness warning permanently — REMOVING coverage the
# unfixed gate had, while fixing a rarer false positive. The safety net has to survive the fix.
# blocking_currency <verdict> <newer-scheduled-run: no|pending|completed|unknown> -> verdict
#
# ⚠ A BLOCK BUILT ON A PAGE WE CAN PROVE WAS BEHIND IS NOT A VERDICT, IT IS AN ARTEFACT.
# (infra_the_full_suite_gate_returns_a_wrong_exit_code_when_the_runs_page_is_behind)
#
# 2026-09-04: this gate returned BLOCKED and, sixteen seconds later with main unchanged and no run
# concluding between them, OPEN. The Actions runs page had served a page missing the ten most recent
# runs; read literally, its newest COMPLETED scheduled run was an eleven-hour-old failure, so the
# gate concluded main was red — correctly, from a page that was wrong. Nothing in the response says
# it is behind.
#
# ⚠ THE SIBLING TICKET FIXED THE MESSAGE AND LEFT THE VERDICT.
# `infra_the_full_suite_gate_intermittently_reports_a_fresh_suite_as_stale` is archived passing and
# its own words are "its verdict (exit code) was correct throughout, so nothing was blocked". Same
# root cause, opposite blast radius: a wrong WARNING is noise; a wrong EXIT CODE stops every merge in
# the repo. `staleness_verdict` above already downgrades a stale READING on this evidence — the
# `proceed` arm consumes it — and the `block` arm never looked at it.
#
# ⚠ THE ASYMMETRY BELOW IS DELIBERATE, AND IT IS THE WHOLE SAFETY ARGUMENT.
# Only `completed` — POSITIVE PROOF that a newer scheduled run has finished, which a current page
# sorted newest-first could not have omitted — abandons a block. `no` and `pending` are proof of
# currency (nothing newer has completed, so our run IS the newest completed one) and still block.
# `unknown` — the confirmation query itself failed — ALSO still blocks, because an unconfirmed red is
# most likely a real red, and because a gate that opened whenever a second API call was unwell would
# be the same self-inflicted outage the `exit 2` arm at the foot of this file exists to prevent.
# **We abandon a block only on proof that the reading was superseded, never on mere doubt.**
#
# ⚠ AND THE FIX IS NOT A BIGGER `per_page`. The observed page was 15 and a page of 30 happened to be
# right sixteen seconds later; a larger page lowers the rate and hides the class, and the next
# observer raises this ticket again. The detector is a SECOND, INDEPENDENTLY-FILTERED query whose
# newest completed run cannot be in our page if our page was current — a proof, not a probability.
# newer_is_superseding <status> <conclusion> -> yes | no                                    (pure)
#
# ⚠ `status: completed` IS NOT A VERDICT, AND THAT IS THE WHOLE OF THIS FUNCTION.
# The currency proof above abandons a block only on a newer run that FINISHED — but it read
# `.status` alone, and a job killed by `timeout-minutes` finishes: GitHub concludes it `cancelled`
# with `status: completed`. So a suite dying at the wall, over and over, was positive proof that our
# reading had been "superseded" — by runs that produced no reading at all.
#
# ⚠ THE CURRENCY ARGUMENT STAYS TRUE AND THE INFERENCE FROM IT DOES NOT. A newer completed run
# really does prove the page was behind; it does NOT prove main's last word has changed, because a
# cancelled run has no last word. Those were one step in the original and they are two here.
#
# Observed 2026-09-05: four consecutive hourlies killed at 45m17s, every one `completed/cancelled`,
# while main had had no fresh verdict for six hours and every gate in the chain returned 0.
#
# ⚠ THE ACCEPT LIST IS `newest_conclusive`'s, DELIBERATELY. Both answer "did this run reach a
# verdict?"; two spellings of that question is how one of them drifts.
# (fix_a_timed_out_full_suite_reads_as_cannot_tell_so_it_can_never_block_the_merge_queue)
newer_is_superseding() {
  local status="${1-}" concl="${2-}"
  [[ "$status" == completed ]] || { printf 'no\n'; return 0; }
  case "$concl" in
    success|failure|timed_out|startup_failure|action_required) printf 'yes\n' ;;
    # ⚠ cancelled / skipped / neutral / '' — no verdict, so no proof. An absent conclusion is
    # counted as no proof rather than assumed benign: this is the arm that ABANDONS a block, so
    # doubt must leave it standing, exactly as `unknown` does below.
    *)                                                        printf 'no\n' ;;
  esac
}

blocking_currency() {
  local verdict="${1-}" newer="${2-unknown}"
  # ⚠ BOTH verdicts the page can give are void when the page is proven behind — GREEN AS MUCH AS
  # RED. This used to convert only a block: a proceed from a behind page passed straight through,
  # and #9672 was ADMITTED at 15:27:45Z on a 610-hour-old green with "the page was behind" printed
  # on the very same line, while main's newest concluded full suite (the 13:08Z hourly) was red.
  # A page known to be behind cannot say what main's newest verdict is; the honest answer for either
  # colour is CANNOT TELL, exit 2. (fix_the_full_suite_gate_admits_a_merge_on_a_weeks_old_green_when_its_runs_page_is_behind)
  case "$verdict" in block|proceed) ;; *) printf '%s\n' "$verdict"; return 0 ;; esac
  case "$newer" in
    completed) printf 'cannot-tell-behind\n' ;;
    *)         printf '%s\n' "$verdict" ;;
  esac
}

staleness_verdict() {
  local note="${1-}" newer="${2-unknown}"
  case "$note" in
    stale) ;;                                   # only a stale reading needs confirming
    fresh|unknown) printf '%s\n' "$note"; return 0 ;;
    *) printf 'unknown\n'; return 0 ;;
  esac
  case "$newer" in
    no)        printf 'stale\n' ;;              # nothing newer at all — the schedule really has stopped
    pending)   printf 'stale\n' ;;              # runs are being CREATED but none has COMPLETED — still an outage
    completed) printf 'unknown\n' ;;            # a newer run DID complete: our page was behind, not the suite
    *)         printf 'unknown\n' ;;            # could not establish — never cry wolf on an unconfirmed reading
  esac
}

# creation_cadence <now-epoch> <created-epoch>...  -> "<n> in <span>h, median gap <g>h"  (pure)
#
# ⚠ IT EXISTS SO THE WARNING CANNOT BE READ AS "CREATION IS HEALTHY". The `pending` arm says
# "scheduled runs ARE being created but none has completed since" — true, and on 2026-08-27 it sat
# beside a SEPARATE fact it did not mention: creation was running at roughly half rate, 12 runs in
# 24h against ~24 for an hourly cron, with gaps median 1.23h and none on the hour. A reader could
# take the first sentence as evidence the scheduler is fine. **The qualifier has to travel in the
# same sentence as the claim**, so the cadence is computed here and printed there.
#
# ⚠ AND IT COSTS NO EXTRA API CALL. The confirm query already fetches `created_at` for the newest
# scheduled runs; this reads what is already in hand. A second query for this would have been a
# second way for the gate to fail in front of every PR, which this file argues against elsewhere.
#
# ⚠ IT REPORTS WHAT IT SAW, NEVER AN EXTRAPOLATION. "12 in 20.4h" is a window, not a rate per day —
# scaling a partial window to a day is how a six-hour sample became a daily figure in this repo
# before. If fewer than two timestamps are usable it says so rather than inventing a cadence.
creation_cadence() {
  local now="${1-}"; shift
  local -a t=()
  local x
  for x in "$@"; do [[ "$x" =~ ^[0-9]+$ ]] && t+=("$x"); done
  if (( ${#t[@]} < 2 )); then printf 'cadence unknown (%d timestamp(s))\n' "${#t[@]}"; return 0; fi
  # sort numerically, newest last
  local -a srt=()
  while IFS= read -r x; do srt+=("$x"); done < <(printf '%s\n' "${t[@]}" | sort -n)
  local n="${#srt[@]}" span=$(( srt[${#srt[@]}-1] - srt[0] ))
  local -a gaps=()
  local i
  for (( i = 1; i < n; i++ )); do gaps+=( $(( srt[i] - srt[i-1] )) ); done
  local -a gs=()
  while IFS= read -r x; do gs+=("$x"); done < <(printf '%s\n' "${gaps[@]}" | sort -n)
  local med="${gs[$(( ${#gs[@]} / 2 ))]}"
  printf '%d created in %sh, median gap %sh\n' "$n" \
    "$(awk -v v="$span" 'BEGIN{printf "%.1f", v/3600}')" \
    "$(awk -v v="$med" 'BEGIN{printf "%.2f", v/3600}')"
}

# newest_conclusive  — stdin: "<conclusion>\t<updated_at>[\t<head_sha>]\t<id>" per line, NEWEST FIRST
#                      (order_by_commit's order when the rows carry a sha; the id is always LAST).
#                      stdout: the first CONCLUSIVE line, or nothing at all.               (pure)
#
# ⚠ THE GATE USED TO READ `[0]` AND NOTHING ELSE, so one cancelled run discarded every conclusive
# run beneath it. (fix_the_full_suite_gate_reads_one_run_so_a_cancellation_hides_a_red)
#
# ⚠ AND THE FAILURE IS ASYMMETRIC IN THE DIRECTION THAT COSTS. If run N is cancelled and run N-1 was
# a genuine FAILURE, the old logic answered cannot-tell and the queue PROCEEDED — the precise event
# this gate exists to catch, made invisible by the same step that hides the good news. MEASURED
# 2026-08-19 over the last 100 completed scheduled runs (a WINDOW, not a total — the count equalled
# the API's per_page cap): 68 success, 21 failure, 11 cancelled. So roughly one time in nine the
# gate's single data point was destroyed evidence.
#
# ⚠ SKIPPING CANCELLED IS NOT "TREATING A CANCELLATION AS A RED", which the header above rightly
# forbids: `gh pr checks` renders a cancelled check as `fail`, and counting that as a red
# manufactures reds out of destroyed evidence. A cancellation still votes for nothing. It simply
# stops SPEAKING FOR the run below it.
#
# ⚠ AN EXHAUSTED WINDOW IS ITS OWN ANSWER. If every line is inconclusive this prints nothing, and the
# caller says so — it must never walk off the end and report the oldest thing it can see as though it
# were current.
# merge_by_updated <tsv…>  ->  the same rows, newest updated_at first (field 2 is an ISO-8601 stamp,
#   so a plain reverse sort on it orders them). Feeds newest_conclusive() the scheduled and the
#   dispatched runs as ONE list, so whichever full suite finished last decides.
merge_by_updated() {
  printf '%s\n' "$@" | grep -v '^[[:space:]]*$' | sort -t$'\t' -k2,2r
}
# ── hourly_job_verdict: did THIS run execute the hourly job at all? ─────────────────────────
# (fix_the_full_suite_gate_reads_the_run_level_conclusion_so_a_nightly_with_the_hourly_skipped_can_pass_for_main)
# The scheduled-runs list carries the RUN-level conclusion, and the nightly (`nightly full verify`)
# shares event=schedule with the hourly: in its run the `hourly full suite` job is SKIPPED (runner
# null, completed_at before started_at) and the run-level conclusion is the NIGHTLY's. Measured over
# 7 days to 2026-09-07: 174 scheduled runs, 7 nightlies where run-level ≠ hourly-job, and once
# (2026-09-04 01:47Z, run 33827079599) a nightly was the newest conclusive run above a RED hourly —
# the gate read the nightly's verdict as main's and was right by luck (the nightly was red too).
# A green nightly there would have UNBLOCKED a red main. The human drain-check says "read the
# hourly JOB conclusion, never the run-level status"; this makes the gate obey the same rule, as
# repair_job_verdict above already does for the repair lane.
#
# hourly_job_verdict <jobs_json> <job name> -> executed | gap | unreadable
#   executed   the named job exists and CONCLUDED (success/failure/timed_out) — a conclusion proves
#              it ran, whether or not the listing carries runner_name (recorded fixtures do not)
#   gap        ⚠ NOT A VERDICT: no such job, or it was skipped, or it was cancelled without ever
#              getting a runner (a queue cancellation, not an execution). A run without
#              the hourly is not a red and not a green — it is not the hourly. Treating it as a red
#              would manufacture reds out of every nightly, the same error the cancellation note in
#              newest_conclusive warns about. The caller drops the run and looks at the next one.
#   unreadable the listing could not be parsed; the caller keeps the run-level read and SAYS SO
#              (a failed query never blocks — and must not silently un-block either).
hourly_job_verdict() {
  local jobs="${1-}" name="${2-}" v
  [[ -n "$jobs" ]] || { printf 'unreadable\n'; return 0; }
  v="$(printf '%s' "$jobs" | jq -r --arg n "$name" '
      [ .jobs[]? | select(.name == $n) ] as $j
    | if ($j | length) == 0 then "gap"
      elif (($j[0].conclusion // "") == "skipped") then "gap"
      elif (($j[0].conclusion // "") | IN("success", "failure", "timed_out")) then "executed"
      elif (($j[0].runner_name // "") == "") then "gap"
      else "executed" end' 2>/dev/null)" || v=''
  case "$v" in executed|gap) printf '%s\n' "$v" ;; *) printf 'unreadable\n' ;; esac
}

# drop_run <lines> <run id> -> the same lines without the one whose id column is <run id>
drop_run() {
  local lines="${1-}" id="${2-}" line
  [[ -n "$id" ]] || { printf '%s' "$lines"; return 0; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "${line##*$'\t'}" == "$id" ]] && continue
    printf '%s\n' "$line"
  done <<<"$lines"
}

newest_conclusive() {
  local line concl
  # ⚠ `|| [[ -n "$line" ]]` IS LOAD-BEARING, NOT A FLOURISH. `read` returns non-zero on a final line
  # with no trailing newline, so the plain form SILENTLY DROPS IT — and the last line is exactly
  # where the oldest, most-likely-conclusive run sits. Caught by this file's own self-test: the
  # fixture whose last line was `failure` returned nothing while an identical fixture with `success`
  # in the MIDDLE passed. A one-line window would have been dropped entirely.
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *[![:space:]]* ]] || continue
    concl="${line%%$'\t'*}"
    case "$concl" in
      # ⚠ TIMED_OUT_CANCEL IS A SENTINEL THE IMPURE HALF SUBSTITUTES, AND IT IS HERE BECAUSE THIS
      # WALK IS WHERE THE DEFECT LIVED. GitHub concludes a job killed by `timeout-minutes` as
      # `cancelled`; `cancelled` is not conclusive, so the walk skipped it and reported an OLDER run.
      # Measured in production 2026-09-05T20:18:10Z, mid-timeout: "main's last full suite was green
      # (4.7 hours ago, fresh)" — sourced from 15:36, before the regression began at 16:08. The gate
      # did not fail silent, it failed REASSURING.
      # ⚠ THE LIST IS is_conclusive's (below) — one list, which order_by_commit reads too.
      # ⚠ Plain `cancelled` is still absent from this list ON PURPOSE. A human or concurrency cancel
      # tells you nothing and looking beneath it is correct; the self-tests below pin that.
      *) if is_conclusive "$concl"; then printf '%s\n' "$line"; return 0; fi ;;
    esac
  done
  return 0
}

# is_conclusive <conclusion> — the ONE list of conclusions that are a verdict. newest_conclusive walks
# past everything else, and order_by_commit only insists on resolving the sha of a row that can win.
is_conclusive() {
  case "${1-}" in
    success|failure|timed_out|startup_failure|action_required|TIMED_OUT_CANCEL) return 0 ;;
    *) return 1 ;;
  esac
}

# commit_generation <sha> -> how many commits <sha> carries (itself and every ancestor), or nothing.
#
# ⚠ THIS IS THE ORDER THE GATE RANKS BY, AND IT IS STRICT ALONG ANCESTRY: if A is an ancestor of B and
# A ≠ B, A's history is a proper subset of B's, so A's count is smaller — on a linear main and across a
# merge alike. Two commits that are NOT related would get an arbitrary (deterministic) order, and that
# cannot arise here: every verdict is a run on main, and main is one line of history.
# A missing object is fetched once, bounded; a sha that still does not resolve prints nothing and the
# caller says cannot-tell rather than guessing an order. Self-tests replace this function with a map.
commit_generation() {
  local sha="${1-}" n
  [[ "$sha" =~ ^[0-9a-f]{7,40}$ ]] || return 0
  # FULL_SUITE_GATE_FETCH=0 skips the fetch (the self-test, which must not reach the network).
  if ! git cat-file -e "$sha^{commit}" 2>/dev/null && [[ "${FULL_SUITE_GATE_FETCH:-1}" == 1 ]]; then
    timeout 30 git fetch -q origin "$sha" >/dev/null 2>&1 || true
  fi
  n="$(git rev-list --count "$sha" 2>/dev/null)" || n=''
  [[ "$n" =~ ^[0-9]+$ ]] && printf '%s\n' "$n"
  return 0
}

# order_by_commit — stdin: "<conclusion>\t<updated_at>\t<head_sha>\t<id>" per line, newest updated_at
#                   first (merge_by_updated's output). stdout: the same rows, a verdict on a DESCENDANT
#                   commit ahead of one on its ancestor whichever finished last; rows on the SAME commit
#                   keep the incoming (completion) order.                                   exit 0 | 2
#
# ⚠ COMPLETION TIME IS NOT THE ORDER THE GATE IS ASKING ABOUT. The question is "what is main's newest
# TESTED tip", and a run's updated_at says when it FINISHED, not what it tested. A scheduled hourly on
# an old sha can queue for an hour and finish after a green on a descendant — and ranked by the clock
# its red re-blocks the queue on a commit that is no longer main. 2026-09-28 10:10–10:37Z came within
# one cancellation of it. (fix_the_full_suite_gate_ranks_verdicts_by_completion_time_so_a_stale_run_on_an_old_sha_can_outrank_a_newer_green)
#
# ⚠ exit 2 = CANNOT TELL, and stdout is then the REASON, not rows: a CONCLUSIVE row whose sha is empty
# or does not resolve. Its rank is the
# whole question, so no order is guessed. An inconclusive row cannot win the walk, so its sha is not
# required; without one it is ranked first, where the walk steps over it exactly as it does today.
# Rows in the OLD three-column shape carry no sha at all (recorded fixtures and stubs). When NO row
# has a sha column the input passes through unchanged: there is nothing to rank by, and that shape
# is not a live API answer.
order_by_commit() {
  local rows=() line concl sha gen idx=0 any4=0 unresolved='' out
  local -A gens=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *[![:space:]]* ]] || continue
    rows+=("$line")
    [[ "$line" == *$'\t'*$'\t'*$'\t'* ]] && any4=1
  done
  (( ${#rows[@]} )) || return 0
  if (( ! any4 )); then printf '%s\n' "${rows[@]}"; return 0; fi
  out=''
  for line in "${rows[@]}"; do
    concl="${line%%$'\t'*}"
    sha=''
    if [[ "$line" == *$'\t'*$'\t'*$'\t'* ]]; then sha="${line#*$'\t'*$'\t'}"; sha="${sha%%$'\t'*}"; fi
    gen=''
    if [[ -n "$sha" ]]; then
      if [[ -z "${gens[$sha]+x}" ]]; then gens[$sha]="$(commit_generation "$sha")"; fi
      gen="${gens[$sha]}"
    fi
    if [[ -z "$gen" ]]; then
      if is_conclusive "$concl"; then unresolved+="${unresolved:+ }${line##*$'\t'}${sha:+@$sha}"; fi
      # an inconclusive row cannot win, so where it sits changes nothing; first is as good as anywhere
      gen=999999999
    fi
    out+="$gen"$'\t'"$idx"$'\t'"$line"$'\n'
    idx=$(( idx + 1 ))
  done
  if [[ -n "$unresolved" ]]; then
    printf 'order_by_commit: cannot rank run(s) %s — the commit does not resolve here\n' "$unresolved"
    return 2
  fi
  sort -t$'\t' -k1,1nr -k2,2n <<<"${out%$'\n'}" | cut -f3-
}

# ── self-test ───────────────────────────────────────────────────────────────────────────────────
# gate_stage_lines <report-file> -> which stages of the blocking run ran, and which NEVER STARTED   (pure)
# ⚠ THE BLOCK SAYS "main's full suite was failure" — AND THAT USED TO BE READ AS "THE BROWSER SUITE WAS
# MEASURED AND SOMETHING IN IT IS RED". Over 768 scheduled runs, 60 of 214 reds never started Playwright
# at all; one API e2e red hid the whole browser suite for six days while this gate blocked on it. The owner
# ruled (2026-09-28, option b): keep the stop, NAME what never ran. The duration line above only guessed
# at it ("did NOT reach the specs"); this reads the stages the run itself published.
# (infra_the_verify_stage_chain_hides_the_whole_browser_suite_behind_any_earlier_red)
gate_stage_lines() {
  local f="${1-}"
  if [[ ! -s "$f" ]]; then
    printf 'Which stages of that run ran is UNKNOWN: it published no stage report (it predates the report, or died before publishing it).\n'
    return 0
  fi
  printf 'Stages of that run:\n'
  vs_lines "$f" | sed 's/^/  /'
}
if [[ "${1:-}" == --render-stages ]]; then gate_stage_lines "${2-}"; exit 0; fi

if declare -F selftest_is_flag >/dev/null && selftest_is_flag "${1:-}"; then
  fails=0
  v() { local want="$1" desc="$2"; shift 2; local got; got="$(queue_block_verdict "$@")"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }

  # ⚠ THE POSITIVE CONTROL FIRST — this is the entire feature. A gate that never blocks is the
  # coverage loss with none of the protection that was traded for it.
  v block       'a red full suite stops the queue'                       failure 0
  v block       'a timed-out full suite is a red, not a shrug'           timed_out 0
  v block       'a startup failure is not a pass'                   startup_failure 0

  v proceed     'a green full suite lets the queue run'                  success 0

  # ⚠ EVERY WAY OF NOT KNOWING PROCEEDS. A broken query must never halt the factory — it would fire
  # on exactly the mornings the API is unwell, and it would look identical to a real red.
  v cannot-tell 'a failed query does not block'                     QUERY_FAILED 0
  v cannot-tell 'no run yet does not block'                                    '' 0
  v cannot-tell 'a CANCELLED run is a gap, not a verdict'                cancelled 0
  v cannot-tell 'a skipped run is not a pass'                              skipped 0

  # ── A CANCELLED RUN THAT HIT ITS TIMEOUT ───────────────────────────────────────────────────────
  # ⚠ POSITIVE CONTROL FIRST — without this the whole change is a comment. A job that exceeds
  # `timeout-minutes` concludes `cancelled`, and before this it proceeded: the suite failing in the
  # loudest possible way was the one state that could not block.
  v block       'a run killed by its own TIMEOUT is a red'        TIMED_OUT_CANCEL 0
  # ⚠ AND THE NEGATIVE CONTROLS THAT KEEP IT NARROW. The line above must not become "every cancelled
  # blocks" — a human cancel, a concurrency cancel and a payload we could not measure are still gaps,
  # and blocking on them re-creates the outage the cannot-tell arm exists to prevent. The sentinel is
  # substituted by the impure half ONLY on measured evidence, so plain `cancelled` is untouched.
  v cannot-tell 'a plain cancelled run is still a gap'                    cancelled 0
  v cannot-tell 'a cancelled run we could not measure is still a gap'     cancelled 0 unknown
  # ⚠ The off-switch still outranks it — it cannot require the thing it is disabling.
  v proceed     'the off-switch outranks a timed-out run'          TIMED_OUT_CANCEL 1
  # ⚠ AND THE ESCAPE APPLIES, OR THE NET IS A TRAP. A PR whose own full suite went green on the
  # merged tree is not refused by main's timeout — same rule as for a red, same reason.
  v proceed-on-own-evidence 'own green-full escapes a timed-out run' TIMED_OUT_CANCEL 0 '' green-full
  v block       'a timeout blocks even when the death site is unclear' TIMED_OUT_CANCEL 0 setup ''
  v cannot-tell 'an unrecognised conclusion does not block'      something_new_v5 0

  # ── WHERE IT DIED ──────────────────────────────────────────────────────────────────────────────
  # ⚠ (a) FIRST, THE PROPERTY A CARELESS FIX DESTROYS. A run that actually executed the suite and
  # failed must STILL block; a change that merely stopped this gate blocking would pass a test that
  # only checked the setup case.
  v block       'a suite that RAN and failed still blocks'          failure 0 suite
  v block       'so does a timed-out suite that ran'              timed_out 0 suite
  # (b) the defect: it never reached a spec, so it is not a verdict.
  v cannot-tell 'a run that died at SETUP never ran a spec'         failure 0 setup
  v cannot-tell 'and a startup_failure at setup likewise'   startup_failure 0 setup
  # ⚠ (c) UNKNOWN BLOCKS. Not knowing where it died is NOT knowing it never started — an unexplained
  # failure is most likely a real red, and only a POSITIVE identification of a setup death may
  # downgrade one. Same rule as the readiness probes: absence of a marker is not identification.
  v block       'an unestablished death site is treated as a real red' failure 0 unknown
  v block       'and an empty one likewise'                            failure 0 ''
  # (d) success is unaffected by any of it.
  v proceed     'a green suite is green wherever it is asked about'     success 0 setup

  # ⚠ THE OFF-SWITCH MUST BEAT A RED. It is the way out when this experiment is itself the problem,
  # so it cannot be conditional on the experiment being healthy.
  v proceed     'the off-switch beats a red'                             failure 1
  v proceed     'the off-switch beats a failed query'               QUERY_FAILED 1
  # …and it must be exact. A stray value must not silently disable the gate.
  v block       'only the exact value 1 disables the gate'               failure yes
  v block       'an empty off-switch does not disable the gate'          failure ''

  # ── THE ESCAPE FROM THE CYCLE — BOTH DIRECTIONS, OR IT IS A HOLE RATHER THAN A FIX ─────────────
  # ⚠ THE POSITIVE CASE IS THE FEATURE: a PR holding a GREEN FULL SUITE on the merged tree is a
  # newer, truer reading of what main is about to become than main's last completed run, so it
  # merges — with no repo variable and no human. This is the deadlock, and it is the whole ticket.
  v proceed-on-own-evidence 'a green full suite on the merged tree beats a stale red' failure 0 suite green-full
  v proceed-on-own-evidence 'and beats a timed-out one'                             timed_out 0 suite green-full
  v proceed-on-own-evidence 'and an unestablished death site'                       failure 0 unknown green-full
  # ⚠ AND NOW THE HALF THAT MATTERS MORE — THE NET MUST STILL BE THERE. Every one of these would
  # pass a test that merely checked the escape works, which is exactly how an escape becomes a hole.
  # (a) A SUBSET run proves nothing about the deferred specs, so it must not open the escape. This is
  #     the ordinary case for every PR on a healthy day — if this line ever flips, the gate is gone.
  v block       'a SUBSET run does not open the escape'                    failure 0 suite ''
  v block       'nor does an absent result'                                failure 0 suite none
  # (b) ⚠ NOR MAY A NEAR-MISS SPELLING. The value is set by ci.yml, and a typo there must fail
  #     CLOSED — a gate that opens on any non-empty string is one refactor from opening always.
  v block       'only the exact token green-full opens it'                 failure 0 suite green
  v block       'and it is not a boolean'                                  failure 0 suite 1
  v block       'and not case-insensitive'                                 failure 0 suite GREEN-FULL
  # (c) ⚠ IT MUST NOT UPGRADE A could-not-look INTO A VERDICT. A setup death never ran a spec, so
  #     this run's green says nothing about main's; collapsing it to proceed would publish an
  #     unestablished state as an established one — the exact family this file exists to police.
  v cannot-tell 'a SETUP death stays could-not-look even with own evidence' failure 0 setup green-full
  v cannot-tell 'a broken query is still a broken query'              QUERY_FAILED 0 '' green-full
  v cannot-tell 'a cancelled run is still a gap'                         cancelled 0 '' green-full
  # (d) and it must not manufacture a distinct verdict where none is needed.
  v proceed     'a green main needs no escape and does not claim one'      success 0 suite green-full

  # ── END TO END, AGAINST A RECORDED REAL RED — NOT JUST THE PURE HALF ───────────────────────────
  # ⚠ THE PURE CASES ABOVE CANNOT CATCH A WIRING FAULT, and the wiring is where this feature lives:
  # OWN_RESULT has to be read from the environment, threaded into the verdict, and turned into the
  # right exit code and the right words. A queue_block_verdict that is perfect while the caller
  # hands it nothing would pass every single test above.
  #
  # So run THE WHOLE SCRIPT with `gh` stubbed to replay run 32218424076 — 2026-08-19's genuine red
  # hourly, job "hourly full suite" -> failure, dying at "Full house gate on main tip". Real payload
  # shape, real jq paths, real death-site classification; the fixture is the API's own response
  # trimmed to the fields this script reads.
  _dd="$(mktemp -d)"; _red="$PWD/scripts/testdata/full-suite-gate/red-hourly-jobs.json"
  if [[ -r "$_red" ]]; then
    cat > "$_dd/gh" <<'STUB'
#!/usr/bin/env bash
# ⚠ TWO DIFFERENT /runs QUERIES, AND THE WHOLE BEHIND-PAGE CASE IS THE DIFFERENCE BETWEEN THEM.
#   status=completed  -> the PRIMARY page the verdict is read from (which can be behind)
#   no status filter  -> the CONFIRMATION page, asked only when the answer could change
# A stub that answered both with one string could not express "the primary page was missing runs
# the confirmation page can see", which is the entire defect under test.
case "$*" in
  # ⚠ STUB_JOBS_MAP / STUB_RUNS exist so the TIMEOUT WALK can be driven: it needs a page with more
  # than one cancelled run AND a different jobs payload per run id. Both are opt-in, so every test
  # written before them behaves exactly as it did.
  *"/jobs"*)
    if [[ -n "${STUB_JOBS_MAP:-}" ]]; then
      for _pair in $STUB_JOBS_MAP; do
        case "$*" in *"/runs/${_pair%%:*}/jobs"*) cat "${_pair#*:}"; exit 0 ;; esac
      done
      exit 0    # an id the map does not name answers with nothing, as an unreadable payload would
    fi
    cat "$STUB_JOBS" ;;
  *"status=completed"*)
    if [[ -n "${STUB_RUNS:-}" ]]; then printf '%s\n' "$STUB_RUNS"
    else printf '%s\t%s\t%s\n' "$STUB_CONCL" "$STUB_UPDATED" "32218424076"; fi ;;
  *"/runs?"*)            printf '%s' "${STUB_NEWER_RUNS:-}" ;;
  *)                     printf '%s\n' "${HARNESS_REPO:-owner/repo}" ;;
esac
STUB
    chmod +x "$_dd/gh"
    e2e() { # e2e <want-exit> <want-substring> <conclusion> <own> <desc>
      local wexit="$1" wsub="$2" concl="$3" own="$4" desc="$5" out rc
      out="$( PATH="$_dd:$PATH" STUB_CONCL="$concl" STUB_JOBS="$_red" \
              STUB_UPDATED="$(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
              FULL_SUITE_OWN_RESULT="$own" FULL_SUITE_ON_EVERY_PR=0 \
              bash "$_SELF" 2>&1 )"; rc=$?
      if [[ "$rc" == "$wexit" && "$out" == *"$wsub"* ]]; then printf '  ok   %s\n' "$desc"
      else printf '  FAIL %s\n       want exit %s + %q, got exit %s\n' "$desc" "$wexit" "$wsub" "$rc"; fails=1; fi
    }
    # e2ec — the same drive, but threading FULL_SUITE_CALLER.
    # ⚠ THE PURE CASES CANNOT CATCH THIS AND THE COMMENT ABOVE SAYS SO IN ITS OWN WORDS: the wiring
    # is where the feature lives. `blocked_branch_note` can be perfect while the env never reaches
    # it, and every pure assertion would still pass. This runs the WHOLE script and reads the
    # annotation it actually emits.
    # (infra_a_blocked_merge_queue_reports_every_waiting_pr_as_failed)
    e2ec() { # e2ec <want-exit> <want-substring> <conclusion> <own> <caller> <desc>
      local wexit="$1" wsub="$2" concl="$3" own="$4" caller="$5" desc="$6" out rc
      out="$( PATH="$_dd:$PATH" STUB_CONCL="$concl" STUB_JOBS="$_red" \
              STUB_UPDATED="$(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
              FULL_SUITE_OWN_RESULT="$own" FULL_SUITE_ON_EVERY_PR=0 FULL_SUITE_CALLER="$caller" \
              bash "$_SELF" 2>&1 )"; rc=$?
      if [[ "$rc" == "$wexit" && "$out" == *"$wsub"* ]]; then printf '  ok   %s\n' "$desc"
      else printf '  FAIL %s\n       want exit %s + %q, got exit %s\n' "$desc" "$wexit" "$wsub" "$rc"; fails=1; fi
    }
    e2ecn() { # same, but the substring must be ABSENT
      local wexit="$1" wsub="$2" concl="$3" own="$4" caller="$5" desc="$6" out rc
      out="$( PATH="$_dd:$PATH" STUB_CONCL="$concl" STUB_JOBS="$_red" \
              STUB_UPDATED="$(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
              FULL_SUITE_OWN_RESULT="$own" FULL_SUITE_ON_EVERY_PR=0 FULL_SUITE_CALLER="$caller" \
              bash "$_SELF" 2>&1 )"; rc=$?
      if [[ "$rc" == "$wexit" && "$out" != *"$wsub"* ]]; then printf '  ok   %s\n' "$desc"
      else printf '  FAIL %s\n       %q must be ABSENT (exit %s)\n' "$desc" "$wsub" "$rc"; fails=1; fi
    }
    # ── the repair-main proof, END TO END, with main GREEN — the state the old gate never looked in ──
    # (infra_a_repair_main_pr_whose_own_full_suite_is_red_is_landed_anyway_because_only_verify_is_required)
    # The whole script, main's last full suite GREEN, a `repair-main` run id whose jobs payload is fed
    # per id through STUB_JOBS_MAP. #9352 is the RED arm: subset green, repair job red, landed.
    printf '%s' '{"jobs":[{"name":"repair full suite (main is red)","status":"completed","conclusion":"failure","steps":[{"name":"Prove the browser suite ran","conclusion":"skipped"}]}]}' > "$_dd/rep-red.json"
    printf '%s' '{"jobs":[{"name":"repair full suite (main is red)","status":"completed","conclusion":"success","steps":[{"name":"Prove the browser suite ran","conclusion":"success"}]}]}' > "$_dd/rep-green.json"
    printf '%s' '{"jobs":[{"name":"verify","status":"in_progress","conclusion":null,"steps":[]}]}' > "$_dd/rep-none.json"
    e2er() { # e2er <want-exit> <want-substring|!absent-substring> <labelled> <jobs-file> <desc>
      local wexit="$1" wsub="$2" lab="$3" jf="$4" desc="$5" out rc ok=0
      out="$( PATH="$_dd:$PATH" STUB_CONCL=success STUB_JOBS="$_red" STUB_JOBS_MAP="777:$jf" \
              STUB_UPDATED="$(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
              FULL_SUITE_OWN_RESULT='' FULL_SUITE_ON_EVERY_PR=0 FULL_SUITE_CALLER=verify \
              FULL_SUITE_REPAIR_LABELLED="$lab" FULL_SUITE_REPAIR_RUN_ID=777 \
              FULL_SUITE_REPAIR_WAIT_S=0 FULL_SUITE_REPAIR_POLL_S=0 \
              bash "$_SELF" 2>&1 )"; rc=$?
      if [[ "$wsub" == '!'* ]]; then [[ "$rc" == "$wexit" && "$out" != *"${wsub#!}"* ]] && ok=1
      else [[ "$rc" == "$wexit" && "$out" == *"$wsub"* ]] && ok=1; fi
      if (( ok )); then printf '  ok   %s\n' "$desc"
      else printf '  FAIL %s\n       want exit %s + %q, got exit %s\n' "$desc" "$wexit" "$wsub" "$rc"
           _h="$(grep -E 'repair lane|REPAIR-MAIN|::error' <<<"$out")"; sed -n '1,3s/^/         /p' <<<"$_h"; fails=1; fi
    }
    e2er 1 '::error::REPAIR-MAIN PROOF MISSING' 1 "$_dd/rep-red.json" \
         'e2e: main GREEN + repair-main + a RED repair job is REFUSED, on the ::error:: line (the #9352 case)'
    e2er 1 'repair full suite (main is red)' 1 "$_dd/rep-red.json" \
         'e2e: …and the refusal names the repair job'
    e2er 1 'REPAIR-MAIN PROOF MISSING' 1 "$_dd/rep-none.json" \
         'e2e: main GREEN + repair-main + NO repair job in the run (absent proof) is refused'
    e2er 0 '!REPAIR-MAIN PROOF MISSING' 1 "$_dd/rep-green.json" \
         'e2e NEGATIVE CONTROL: main GREEN + repair-main + a GREEN repair job lands exactly as before'
    e2er 0 '!repair lane' 0 "$_dd/rep-red.json" \
         'e2e NEGATIVE CONTROL: NO label — the repair job is never consulted, even when it is red'

    # ⚠ THE TICKET IS NAMED FOR THIS LINE. A blocked PR must be told the block is not about its code.
    e2ec  1 'THIS BRANCH WAS NOT JUDGED BAD' failure '' verify \
          'e2e: a blocked verify says the branch itself passed'
    # ⚠ AND IT MUST RIDE ON THE ::error:: ANNOTATION, not merely appear somewhere in stdout -- the
    # annotation is what the checks tab renders; stdout is thousands of lines down inside the log.
    e2ec  1 '::error::THE MERGE QUEUE IS BLOCKED' failure '' verify \
          'e2e: and it rides on the error annotation, not buried in stdout'
    # ⚠ NEGATIVE CONTROL ON THE WIRING: with no caller the neutral form is used and the pass claim
    # must be ABSENT. If the env were ignored and `verify` hard-coded, this fires and nothing else does.
    e2ecn 1 'tests PASSED' failure '' '' \
          'e2e NEGATIVE CONTROL: an unset caller does not claim the tests passed'

    # THE DEADLOCK ITSELF: main red, this PR ran only the subset, so it has proved nothing about the
    # deferred specs and is still refused. That is the pre-fix behaviour and it must survive.
    e2e 1 'MERGE QUEUE IS BLOCKED'    failure ''           'e2e: a subset run is still refused while main is red'
    # THE ESCAPE: a green FULL suite on the merged tree is newer, truer evidence, so it merges — no
    # repo variable, no human. This is the whole ticket.
    e2e 0 'ESCAPE TAKEN'              failure green-full   'e2e: a green full suite on the merged tree merges'
    e2e 0 'NOT ESTABLISHED'           failure green-full   'e2e: and names the class it CANNOT establish'
    e2e 0 'FULL_SUITE_ESCAPE_TAKEN'   failure green-full   'e2e: and emits a countable marker'
    # ⚠ AND THE HALF THAT KEEPS IT FROM BEING A HOLE RATHER THAN A FIX.
    e2e 1 'MERGE QUEUE IS BLOCKED'    failure green        'e2e: a near-miss token does not open it'
    # ⚠ AND WHEN IT BLOCKS, THE READER MUST BE ABLE TO ACT. The unbounded risk of this feature is
    # false confidence — someone assuming recovery is automatic and never reaching for the lever, so
    # main sits red the way it did overnight on 2026-08-18. These assert the block message SAYS why
    # the automatic escape did not apply and names the manual switch, for a person who has never
    # heard of this ticket.
    e2e 1 'WHY THE AUTOMATIC ESCAPE DID NOT APPLY' failure '' 'e2e: a block explains why the escape did not open'
    e2e 1 'RE-RUN THIS PR'              failure ''           'e2e: and names the cheap fix when route pre-dated the red'
    e2e 1 'FULL_SUITE_ON_EVERY_PR=1'    failure ''           'e2e: and still names the manual lever'
    e2e 1 'it is not automatic'         failure ''           'e2e: and says plainly that the lever is not automatic'
    e2e 1 'MISCONFIGURATION'            failure green        'e2e: a near-miss token is named as misconfiguration, not a test result'
    e2e 0 'last full suite was green' success green-full   'e2e: a green main claims no escape'

    # ── ⚠ CANNOT TELL IS ITS OWN EXIT CODE (fix_the_full_suite_gate_cannot_say_cannot_tell) ──────
    # The `v cannot-tell …` rows above assert the VERDICT FUNCTION. They cannot see the exit code,
    # and the exit code is the entire defect: cannot-tell used to `exit 0`, the same as "main is
    # green", so ci.yml:361 read it as force_full=0 and SILENTLY withheld the deadlock escape.
    # These assert the PROCESS, which is the only thing the callers actually see.
    e2e 2 'CANNOT TELL'  QUERY_FAILED     '' 'e2e: a failed query exits 2, distinguishable from green'
    e2e 2 'CANNOT TELL'  cancelled        '' 'e2e: a cancelled run exits 2 — a gap, not a verdict'

    # ⚠⚠ THE WIRING TEST, AND IT IS NOT OPTIONAL — IT CAUGHT THIS FIX BEING INERT. Every pure case
    # above passed while `HIT_LIMIT` could never be set: the wiring compared `run_job_duration`'s
    # PRETTY string ("45m 17s") with `=~ ^[0-9]+$`, which is false for every value it can return.
    # The verdict function was correct, tested, and never reached. `run_job_duration_s` exists
    # because of that, and these two cases are what would have failed.
    _to="$PWD/scripts/testdata/full-suite-gate/timed-out-hourly-jobs.json"
    e2etimeout() { # e2etimeout <want-exit> <want-substring> <limit-min> <desc>
      local wexit="$1" wsub="$2" lim="$3" desc="$4" out rc
      out="$( PATH="$_dd:$PATH" STUB_CONCL=cancelled STUB_JOBS="$_to" \
              STUB_UPDATED="$(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
              FULL_SUITE_TIMEOUT_MIN="$lim" FULL_SUITE_ON_EVERY_PR=0 \
              bash "$_SELF" 2>&1 )"; rc=$?
      if [[ "$rc" == "$wexit" && "$out" == *"$wsub"* ]]; then printf '  ok   %s\n' "$desc"
      else printf '  FAIL %s\n       want exit %s + %q, got exit %s\n' "$desc" "$wexit" "$wsub" "$rc"; fails=1; fi
    }
    e2etimeout 1 'BLOCK' 45 'e2e: a 45m17s cancelled run against a 45m limit BLOCKS — the wiring reaches the verdict'
    # ⚠ AND THE SAME PAYLOAD WITH NO LIMIT TO COMPARE AGAINST MUST STILL PROCEED. Without this the
    # test above would pass just as well on a version that blocked every cancelled run.
    e2etimeout 2 'CANNOT TELL' '' 'e2e: the same run with no limit configured is still a gap'
    # A limit the run did not reach is not evidence either — 45m17s is well under 90 minutes.
    e2etimeout 2 'CANNOT TELL' 90 'e2e: a cancelled run comfortably inside its limit is still a gap'

    # ── ⚠⚠ A LONG DURATION ON A JOB THAT NEVER RAN MUST NOT BLOCK ────────────────────────────────
    # The duration test above is necessary and NOT sufficient. A job that never got a runner is
    # stamped `started_at = created_at` and `completed_at` at cancellation, so its arithmetic yields
    # the QUEUE WAIT — a real number, larger than the limit on a saturated seat (measured 86 minutes
    # against 45 on 2026-09-05). Blocking on it would halt every merge over a suite that never ran.
    # ⚠ This is THIS TICKET'S OWN DEFECT ONE LAYER DOWN: `cancelled` conflates human-cancel with
    # timeout-kill; `>= 45 min` conflates killed-at-the-wall with merely-queued-a-long-time.
    _nd="$PWD/scripts/testdata/full-suite-gate/never-dispatched-hourly-jobs.json"
    e2ejobs() { # e2ejobs <want-exit> <want-substring> <jobs-file> <limit-min> <desc>
      local wexit="$1" wsub="$2" jf="$3" lim="$4" desc="$5" out rc
      out="$( PATH="$_dd:$PATH" STUB_CONCL=cancelled STUB_JOBS="$jf" \
              STUB_UPDATED="$(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
              FULL_SUITE_TIMEOUT_MIN="$lim" FULL_SUITE_ON_EVERY_PR=0 \
              bash "$_SELF" 2>&1 )"; rc=$?
      if [[ "$rc" == "$wexit" && "$out" == *"$wsub"* ]]; then printf '  ok   %s\n' "$desc"
      else printf '  FAIL %s\n       want exit %s + %q, got exit %s\n' "$desc" "$wexit" "$wsub" "$rc"; fails=1; fi
    }
    e2ejobs 2 'CANNOT TELL' "$_nd" 45 \
      'e2e: an 86-minute QUEUE WAIT on a never-dispatched job does NOT block — it never ran'
    # ⚠ POSITIVE CONTROL FOR THE ROW ABOVE, and it is the one that matters: the two fixtures differ
    # ONLY in `runner_name` and the timestamps. If the guard were implemented as "never block on a
    # cancelled run" both rows would pass and the ticket's whole fix would be gone.
    e2ejobs 1 'BLOCK' "$_to" 45 \
      'e2e POSITIVE CONTROL: the DISPATCHED 45m17s run still blocks — the guard is dispatch, not cancellation'

    # ── ⚠⚠ A SUPERSEDE ON TOP OF A TIMEOUT MUST NOT HIDE IT ──────────────────────────────────────
    # THE REGRESSION THAT SHIPPED AND WAS CAUGHT LIVE. The first version substituted the sentinel for
    # the NEWEST line only. At 23:15Z the gate exited 0 and announced a 7.6-hour-old green with five
    # dispatched timeouts in the page, because a sixth run — superseded while PENDING, so `cancelled`
    # with no hourly job at all — had landed on top of them.
    # ⚠ `cancel-in-progress` is false for `schedule`: it protects a RUNNING run, never a PENDING one,
    # so this arrangement appears whenever the queue is deep. It is the ordinary case, not a corner.
    _ago2() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ''; }
    e2ewalk() { # e2ewalk <want-exit> <want-substring> <runs-tsv> <jobs-map> <desc>
      local wexit="$1" wsub="$2" rows="$3" map="$4" desc="$5" out rc
      out="$( PATH="$_dd:$PATH" STUB_RUNS="$rows" STUB_JOBS_MAP="$map" STUB_JOBS="$_red" \
              STUB_UPDATED="$(_ago2 '30 min ago')" \
              FULL_SUITE_TIMEOUT_MIN=45 FULL_SUITE_ON_EVERY_PR=0 \
              bash "$_SELF" 2>&1 )"; rc=$?
      if [[ "$rc" == "$wexit" && "$out" == *"$wsub"* ]]; then printf '  ok   %s\n' "$desc"
      else printf '  FAIL %s\n       want exit %s + %q, got exit %s\n' "$desc" "$wexit" "$wsub" "$rc"; fails=1; fi
    }
    _u30="$(_ago2 '30 min ago')"
    e2ewalk 1 'BLOCK' \
      "cancelled	$_u30	900
cancelled	$_u30	901" "900:$_nd 901:$_to" \
      'e2e: a never-dispatched supersede does NOT hide the dispatched timeout beneath it'
    # ⚠ NEGATIVE CONTROL — the walk must not invent a timeout when there is none beneath. Two
    # never-dispatched runs are still a gap, however many of them there are.
    e2ewalk 2 'CANNOT TELL' \
      "cancelled	$_u30	900
cancelled	$_u30	902" "900:$_nd 902:$_nd" \
      'e2e NEGATIVE CONTROL: two never-dispatched runs are a gap, not a block'
    # ⚠ AND IT MUST NOT REACH PAST A REAL VERDICT. A failure beneath a supersede is that failure —
    # the walk stops at the first non-cancelled entry, which is also what keeps the happy path free
    # of API calls.
    e2ewalk 1 'BLOCK' \
      "cancelled	$_u30	900
failure	$_u30	903" "900:$_nd 903:$_red" \
      'e2e: the walk stops at the first real verdict beneath a supersede'
    # ⚠ THE JOBLESS RUN — the shape that actually sat on top of the queue tonight. A run cancelled
    # while PENDING is never expanded into jobs at all, so the walk must pass over a payload with no
    # job object rather than one with an undispatched job. Same answer, third route.
    _jl="$PWD/scripts/testdata/full-suite-gate/jobless-run-jobs.json"
    e2ewalk 1 'BLOCK' \
      "cancelled	$_u30	904
cancelled	$_u30	901" "904:$_jl 901:$_to" \
      'e2e: a JOBLESS superseded run does not hide the dispatched timeout beneath it'
    e2ewalk 2 'CANNOT TELL' \
      "cancelled	$_u30	904
cancelled	$_u30	900" "904:$_jl 900:$_nd" \
      'e2e NEGATIVE CONTROL: jobless above never-dispatched is still a gap, not a block'
    # ── the WIRING of the commit ranking, end to end ──────────────────────────────────────────────
    # The pure arms prove order_by_commit; these prove the jq asks for head_sha, the ranking runs
    # between merge_by_updated and the walk, and its notice reaches the log. Real commits: HEAD~1 is
    # an ancestor of HEAD, so a red on HEAD~1 that FINISHED later is the 2026-09-28 10:10Z shape.
    # (fix_the_full_suite_gate_ranks_verdicts_by_completion_time_so_a_stale_run_on_an_old_sha_can_outrank_a_newer_green)
    # The unresolvable arm must not reach the network: a self-test answers from this box alone.
    export FULL_SUITE_GATE_FETCH=0
    _wh="$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || _wh=''
    _wp="$(git rev-parse -q --verify 'HEAD~1^{commit}' 2>/dev/null)" || _wp=''
    if [[ -n "$_wh" && -n "$_wp" ]]; then
      _u20="$(_ago2 '20 min ago')"
      e2ewalk 0 'SUPERSEDED by run 812' \
        "failure	$_u20	$_wp	811
success	$_u30	$_wh	812" "" \
        'e2e: a red on an ANCESTOR that finished after the green on its descendant does not block — and the log names both'
      e2ewalk 1 'BLOCK' \
        "failure	$_u20	$_wh	821
success	$_u30	$_wp	822" "" \
        'e2e: a red on the DESCENDANT still blocks, however late an ancestor'"'"'s green finished'
      # NEGATIVE CONTROL: the same page with the commits taken away is ranked by the clock, exactly as
      # before this ticket — proving the PROCEED above came from the commits and nothing else.
      e2ewalk 1 'BLOCK' \
        "failure	$_u20	811
success	$_u30	812" "" \
        'e2e NEGATIVE CONTROL: without head_sha the later-finishing red still decides (the old ranking)'
      e2ewalk 2 'CANNOT TELL' \
        "failure	$_u20	0000000000000000000000000000000000000000	831
success	$_u30	$_wh	832" "" \
        'e2e: a conclusive run on a commit that does not resolve is CANNOT TELL, not a guess'
    else
      printf '  --   e2e commit ranking: NOT RUN — no HEAD~1 here (not a pass)\n'
    fi
    e2e 2 'CANNOT TELL'  skipped          '' 'e2e: a skipped run exits 2'
    e2e 2 'CANNOT TELL'  something_new_v5 '' 'e2e: an unrecognised conclusion exits 2'
    # ⚠ THE NEGATIVE CONTROL, AND IT GUARDS THE MOST LIKELY WRONG FIX. "Make it exit non-zero on
    # QUERY_FAILED" restores the escape AND halts the factory whenever the API is unwell — the
    # self-inflicted outage the `*)` arm exists to prevent. 2 is not 1, and that must stay true.
    if PATH="$_dd:$PATH" STUB_CONCL=QUERY_FAILED STUB_JOBS="$_red" \
       STUB_UPDATED="$(date -u -d '30 min ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')" \
       FULL_SUITE_OWN_RESULT='' FULL_SUITE_ON_EVERY_PR=0 bash "$_SELF" >/dev/null 2>&1
    then _cc_rc=0; else _cc_rc=$?; fi
    if [[ "$_cc_rc" != 1 ]]; then printf '  ok   e2e: cannot-tell does NOT block (exit is %s, not 1)\n' "$_cc_rc"
    else printf '  FAIL e2e: cannot-tell exited 1 — that halts the factory whenever the API is unwell\n'; fails=1; fi
    # ── ⚠ A BEHIND RUNS PAGE MUST NOT BLOCK THE REPO ────────────────────────────────────────────
    # (infra_the_full_suite_gate_returns_a_wrong_exit_code_when_the_runs_page_is_behind)
    #
    # ⚠ THE PURE `bc` ROWS ABOVE CANNOT CATCH THIS, AND THE TICKET SAYS SO IN ITS OWN FIRST ITEM:
    # "REPRODUCE THE VERDICT FLIP, not the message". blocking_currency can be perfect while the
    # confirmation never runs on the block path, or while NEWER never reaches it — and every pure
    # row would still pass. These drive THE WHOLE SCRIPT against a primary page that is missing the
    # newest runs, and read the exit code the callers actually see.
    _ago() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo ''; }
    e2eb() { # e2eb <want-exit> <want-substring> <concl> <updated> <newer-runs-tsv> <desc>
      local wexit="$1" wsub="$2" concl="$3" upd="$4" newer="$5" desc="$6" out rc
      out="$( PATH="$_dd:$PATH" STUB_CONCL="$concl" STUB_JOBS="$_red" \
              STUB_UPDATED="$upd" STUB_NEWER_RUNS="$newer" \
              FULL_SUITE_OWN_RESULT='' FULL_SUITE_ON_EVERY_PR=0 \
              bash "$_SELF" 2>&1 )"; rc=$?
      if [[ "$rc" == "$wexit" && "$out" == *"$wsub"* ]]; then printf '  ok   %s\n' "$desc"
      else printf '  FAIL %s\n       want exit %s + %q, got exit %s\n' "$desc" "$wexit" "$wsub" "$rc"; fails=1; fi
    }

    # THE OBSERVED INCIDENT, IN THE SHAPE IT ARRIVED. The primary page's newest COMPLETED run is an
    # eleven-hour-old failure; the confirmation page shows a scheduled run that COMPLETED an hour
    # ago. A current page could not have omitted it, so the failure we read is not main's last word.
    e2eb 0 'judging on that run' failure "$(_ago '11 hours ago')" "$(_ago '1 hour ago')$(printf '\t')completed$(printf '\t')success" \
         'e2e: a PROVEN behind page is not judged — the newer GREEN run is, and it admits (not blocked on a paging artefact)'
    e2eb 0 'was BEHIND'  failure "$(_ago '11 hours ago')" "$(_ago '1 hour ago')$(printf '\t')completed$(printf '\t')success" \
         'e2e: …and says the page was behind, so the reader is not hunting a test failure'
    e2eb 0 'admitted on run' failure "$(_ago '11 hours ago')" "$(_ago '1 hour ago')$(printf '\t')completed$(printf '\t')success" \
         'e2e: …and the admit line names the run it admitted on'

    # ⚠ THE CASE THE OLD TRIGGER COULD NOT HAVE SEEN, AND THE REASON THE TRIGGER MOVED. The
    # confirmation used to run only when the age read `stale`. A behind page is behind by whatever
    # the API is behind by — here half an hour — so it looks FRESH, the confirmation never ran, and
    # the block went out on page order alone. This drives that exact shape.
    e2eb 0 'judging on that run' failure "$(_ago '30 min ago')" "$(_ago '10 min ago')$(printf '\t')completed$(printf '\t')success" \
         'e2e: a behind page that looks FRESH is caught too — the trigger is the confirmation, not the age'

    # ⚠⚠ THE NEGATIVE CONTROLS. THIS IS THE ARCHIVED SIBLING TICKET'S THIRD ITEM, UNCHANGED: "a fix
    # that stops false blocks by never blocking has removed the control". Each of these is a page we
    # can prove was CURRENT, and every one of them must still block.
    e2eb 1 'MERGE QUEUE IS BLOCKED' failure "$(_ago '30 min ago')" "$(_ago '12 hours ago')$(printf '\t')completed$(printf '\t')success" \
         'e2e NEGATIVE CONTROL: nothing newer than our run — a genuine red still blocks'
    e2eb 1 'MERGE QUEUE IS BLOCKED' failure "$(_ago '30 min ago')" "$(_ago '10 min ago')$(printf '\t')in_progress" \
         'e2e NEGATIVE CONTROL: a newer run that has NOT completed — ours is still the newest, blocks'
    e2eb 1 'MERGE QUEUE IS BLOCKED' failure "$(_ago '30 min ago')" '' \
         'e2e NEGATIVE CONTROL: the confirmation query answered nothing — doubt does not open the gate'
    # ⚠ AND A GREEN MAIN IS UNTOUCHED. blocking_currency runs on every invocation; if it rewrote any
    # verdict but `block`, this fires.
    # ⚠ THIS ARM USED TO EXPECT EXIT 0 ("a green main is unaffected by the currency check") — and that
    # expectation was the defect: it pinned a behind page's green as an admit. Flipped, deliberately.
    e2eb 0 'judging on that run' success "$(_ago '30 min ago')" "$(_ago '10 min ago')$(printf '\t')completed$(printf '\t')success" \
         'e2e: a GREEN read from a proven-behind page is not the evidence — the newer green run is, and the line says so'
    e2eb 1 'MERGE QUEUE IS BLOCKED' success "$(_ago '50 min ago')" "$(_ago '10 min ago')$(printf '\t')completed$(printf '\t')failure" \
         'e2e: a FRESH green with a newer completed RED behind the page — the #9622/#9498/#9548 shape — BLOCKS on the newer red'
    e2eb 1 'MERGE QUEUE IS BLOCKED' success "$(_ago '610 hours ago')" "$(_ago '2 hours ago')$(printf '\t')completed$(printf '\t')failure" \
         'e2e: #9672'"'"'s exact shape — a 610-hour-old green on the page, a newer red completed — BLOCKS'
    e2eb 0 'last full suite was green' success "$(_ago '30 min ago')" "$(_ago '10 min ago')$(printf '\t')in_progress" \
         'e2e NEGATIVE CONTROL: a current page whose green is the newest CONCLUDED run still admits (a newer run in progress is not a verdict)'
    e2eb 0 'last full suite was green' success "$(_ago '30 min ago')" '' \
         'e2e NEGATIVE CONTROL: a current green with nothing newer still admits'
    e2eb 0 'admitted on run 32218424076' success "$(_ago '30 min ago')" '' \
         'e2e: the admit line names the run it admitted on (no trailing unknown)'
    e2eb 1 'MERGE QUEUE IS BLOCKED' failure "$(_ago '30 min ago')" '' \
         'e2e NEGATIVE CONTROL: a current page whose newest concluded full suite is RED still blocks'

    # ── ⚠ A NEWER RUN THAT WAS KILLED AT THE WALL IS NOT PROOF OF ANYTHING ──────────────────────
    # THE SECOND SURFACE OF THIS TICKET, and the one the fix above does NOT reach. `newest_conclusive`
    # decides what main's last word was; THIS decides whether to abandon a block built on it. Both
    # were fooled by the same fact, in different functions, for different reasons — so a fix to one
    # says nothing about the other. (The sentinel only rewrites the NEWEST line; when that line is an
    # ordinary human cancel the walk goes deeper, `$updated` is older, and a timed-out run newer than
    # it lands squarely in this query.)
    #
    # Live shape, 2026-09-05: main's last verdict was a real red, and four hourlies then died at
    # 45m17s. Every one is `completed`, so the old code read four proofs that the red was superseded.
    e2eb 1 'MERGE QUEUE IS BLOCKED' failure "$(_ago '30 min ago')" "$(_ago '10 min ago')$(printf '\t')completed$(printf '\t')cancelled" \
         'e2e: a newer run killed at the wall does NOT abandon the block — it carries no verdict'
    e2eb 1 'MERGE QUEUE IS BLOCKED' failure "$(_ago '6 hours ago')" \
         "$(_ago '10 min ago')$(printf '\t')completed$(printf '\t')cancelled
$(_ago '1 hour ago')$(printf '\t')completed$(printf '\t')cancelled
$(_ago '2 hours ago')$(printf '\t')completed$(printf '\t')cancelled
$(_ago '3 hours ago')$(printf '\t')completed$(printf '\t')cancelled" \
         'e2e: FOUR of them in a row still do not — tonight, exactly as it happened'
    # ⚠ POSITIVE CONTROL FOR THE PAIR ABOVE. Same page, same ages, one real verdict among the
    # cancels — and the block IS abandoned. Without this the two rows above would also pass if the
    # currency check had simply stopped working, which is the way this fix could go wrong silently.
    e2eb 0 'judging on that run' failure "$(_ago '6 hours ago')" \
         "$(_ago '10 min ago')$(printf '\t')completed$(printf '\t')cancelled
$(_ago '1 hour ago')$(printf '\t')completed$(printf '\t')success" \
         'e2e POSITIVE CONTROL: one real verdict among the cancels still proves the page was behind, and the gate judges on it'
    # ⚠ A SHORT LINE MUST NOT BE READ AS A VERDICT. The old two-column shape is what every caller
    # sent before this change; if it ever reappears it means no conclusion, not a benign one.
    e2eb 1 'MERGE QUEUE IS BLOCKED' failure "$(_ago '30 min ago')" "$(_ago '10 min ago')$(printf '\t')completed" \
         'e2e: a row with no conclusion column is doubt, and doubt leaves the block standing'

    # ⚠ ITEM 4: SHOW THE DETECTION IS NOT JUST A BIGGER PAGE. The ticket is explicit that raising
    # per_page is not a fix — it lowers the rate and hides the class. The primary query's page size
    # is asserted UNCHANGED, so this ticket cannot be "closed" by widening it and the next reader can
    # see at a glance that the detector is the second query, not the first one's size.
    if grep -q 'status=completed&per_page=20' "$_SELF"; then
      printf '  ok   the primary page size is UNCHANGED — the detector is a second query, not a bigger page\n'
    else
      printf '  FAIL the primary query per_page changed — a bigger page hides this class, it does not fix it\n'; fails=1
    fi

    # ⚠ THE CONSUMER-SIDE ASSERTION LIVES IN pr-refresh.sh's OWN SELF-TEST, NOT HERE — and the first
    # spelling of it here was a probe that could never fire. It tried to source pr-refresh.sh with a
    # `--source-only` flag that does not exist, so it took its own "could not drive it" fallback on
    # every run and reported that as acceptable, while claiming the assertion existed elsewhere.
    # It did not: pr-refresh's self-test stubbed exit 0 and exit 1 only. Both halves of that
    # sentence were wrong, in the reassuring direction, in a file about a defect of exactly that
    # shape. The real assertion is now DIRECTION 3 there — a gate-unknown.sh stub exiting 2, and an
    # assertion that queue_block_cleared answers `unknown` rather than `cleared`.
    # (fix_the_full_suite_gate_cannot_say_cannot_tell)

    # ── ⚠ THE cd GUARD MUST ALSO SAY cannot-tell, NOT green ───────────────────────────────────
    # (fix_the_full_suite_gate_exits_green_when_it_cannot_reach_its_own_repo)
    #
    # ⚠ THIS IS A SOURCE ASSERTION AND NOT A DRIVE, SAID PLAINLY BECAUSE THIS FILE HAS ALREADY BEEN
    # BITTEN BY THE ALTERNATIVE. A few lines above, a probe that "could not drive it" took its own
    # fallback on every run and reported that as acceptable while claiming the real assertion lived
    # elsewhere; it did not. So rather than a stub that cannot fire, this reads the line.
    #
    # THE cd CANNOT BE MADE TO FAIL WITHOUT MAKING THE SCRIPT UNREADABLE, which stops the test
    # running at all: the target is `dirname "$BASH_SOURCE"/..`, so it exists whenever bash was able
    # to open this file, and removing search permission on the parent defeats the open, not the cd.
    # An assertion that pins the code is worth more than a drive that cannot reach the arm.
    _cd_line="$(grep -n '^cd "$(dirname' "$_SELF" | head -1)"
    if [[ "$_cd_line" == *'|| exit 2'* ]]; then
      printf '  ok   the cd guard exits 2 (cannot-tell), not 0 (main was green)\n'
    else
      printf '  FAIL the cd guard must exit 2 — 0 tells the merge queue the full suite PASSED\n       got: %s\n' "$_cd_line"; fails=1
    fi
    # ⚠ POSITIVE CONTROL: the grep must actually find the line. Without this, deleting or renaming
    # the cd would leave an empty string, the `exit 2` test would fail — but so would a genuine
    # regression, and the two would be indistinguishable. An empty match is a broken assertion.
    if [[ -n "$_cd_line" ]]; then printf '  ok   control: the cd guard line was located in the source\n'
    else printf '  FAIL control: could not find the cd guard at all — this assertion is about nothing\n'; fails=1; fi
    # ⚠ AND 1 IS ASSERTED AGAINST, not merely absent: the obvious "fix" for a gate that cannot see
    # is to make it block, which is the self-inflicted outage the cannot-tell arm exists to prevent.
    if [[ "$_cd_line" != *'|| exit 1'* ]]; then printf '  ok   ...and does NOT exit 1, which would halt the factory on an unreadable checkout\n'
    else printf '  FAIL the cd guard exits 1 — that halts the queue whenever the checkout is unwell\n'; fails=1; fi

    rm -rf "$_dd"
  else
    printf '  FAIL e2e fixture missing: %s\n' "$_red"; fails=1
  fi

  s() { local want="$1" desc="$2"; shift 2; local got; got="$(staleness_note "$@")"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  # ── run_death_site, against the REAL payloads of the two runs that motivated this ───────────────
  # ⚠ THESE ARE VERBATIM FROM THE API, not hand-written. A fixture somebody invents proves the parser
  # can match a string that author imagined; only the real payload proves it tells apart the two runs
  # that were actually confused — and only the real one starts failing the day GitHub renames a step,
  # which is the rot this parser is exposed to and the reason it is pinned here.
  d() { local want="$1" desc="$2" json="$3"; local got; got="$(run_death_site "$json" 'hourly full suite')"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }

  # Run 32038005812 (14:08, sha 75df3ad4) — codeload 429 on actions/checkout. ONE step, and it is
  # GitHub's own. This is the run that blocked the queue with no code defect in the repo.
  _REAL_SETUP='{"jobs":[{"conclusion":"failure","name":"hourly full suite","steps":[
      {"conclusion":"failure","name":"Set up job","number":1}]}]}'
  d setup 'the REAL 14:08 codeload-429 run died at setup' "$_REAL_SETUP"

  # Run 32053471791 (18:08) — the genuine red: five steps green, then verify.sh.
  _REAL_SUITE='{"jobs":[{"conclusion":"failure","name":"hourly full suite","steps":[
      {"conclusion":"success","name":"Set up job","number":1},
      {"conclusion":"success","name":"Run actions/checkout@v5","number":2},
      {"conclusion":"success","name":"Create dev .env","number":3},
      {"conclusion":"success","name":"Reclaim the CI seat — clear a stack no job will come back for","number":4},
      {"conclusion":"success","name":"Generate the coverage artifact this gate inspects","number":5},
      {"conclusion":"failure","name":"Full house gate on main tip — bash scripts/verify.sh","number":6},
      {"conclusion":"success","name":"Upload Playwright report + traces","number":7}]}]}'
  d suite 'the REAL 18:08 run ran the suite and failed in it' "$_REAL_SUITE"

  # ⚠ EVERY WAY OF NOT ESTABLISHING IT LANDS ON `unknown`, WHICH BLOCKS. None of these may quietly
  # become `setup`, or an unreadable payload would silently unblock the queue.
  d unknown 'no payload at all'                    ''
  d unknown 'a job by another name'                '{"jobs":[{"name":"something else","steps":[{"conclusion":"failure","name":"Set up job"}]}]}'
  d unknown 'a job with no failing step'           '{"jobs":[{"name":"hourly full suite","steps":[{"conclusion":"success","name":"Set up job"}]}]}'
  d unknown 'a job with no steps array'            '{"jobs":[{"name":"hourly full suite"}]}'
  d unknown 'malformed json'                       '{not json'
  # And the earliest failure wins, so a cleanup failure after a real red cannot mask it.
  d suite   'the FIRST failing step decides, not the last' \
    '{"jobs":[{"name":"hourly full suite","steps":[
       {"conclusion":"failure","name":"Full house gate on main tip — bash scripts/verify.sh","number":6},
       {"conclusion":"failure","name":"Post Run actions/checkout@v5","number":14}]}]}'

  # ── the DEATH SITE the message used to discard ───────────────────────────────────────────────
  # (infra_the_merge_queue_block_message_throws_away_the_death_site_it_just_computed)
  #
  # ⚠ THE REAL PAYLOAD OF RUN 32586684979 — the 17:12 run that actually blocked the queue on
  # 2026-08-22 — verbatim from the API, same convention as the two above. Its whole point is what it
  # shares with _REAL_SUITE: an IDENTICAL failing step name and step list. It is here to prove that
  # naming the step is NOT sufficient.
  _REAL_17_12='{"jobs":[{"conclusion":"failure","name":"hourly full suite",
      "started_at":"2026-08-22T17:12:52Z","completed_at":"2026-08-22T17:13:25Z","steps":[
      {"conclusion":"success","name":"Set up job","number":1},
      {"conclusion":"success","name":"Run actions/checkout@v5","number":2},
      {"conclusion":"success","name":"Create dev .env","number":3},
      {"conclusion":"success","name":"Reclaim the CI seat — clear a stack no job will come back for","number":4},
      {"conclusion":"success","name":"Generate the coverage artifact this gate inspects","number":5},
      {"conclusion":"failure","name":"Full house gate on main tip — bash scripts/verify.sh","number":6},
      {"conclusion":"success","name":"Upload Playwright report + traces","number":7}]}]}'

  # ⚠⚠ THE CLASSIFICATION IS UNCHANGED AND THIS ASSERTS IT. This ticket changes REPORTING only. If
  # `suite` ever became `setup` here the gate would stop blocking on a real red, which is the one
  # outcome that must not fall out of a message change.
  d suite 'the REAL 17:12 blocker is STILL classified `suite` — run_death_site is untouched' "$_REAL_17_12"

  _ds() { local want="$1" desc="$2" json="$3" got
          got="$(run_death_step "$json" 'hourly full suite')"
          if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
          else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  _dur() { local want="$1" desc="$2" json="$3" got
           got="$(run_job_duration "$json" 'hourly full suite')"
           if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
           else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }

  _ds  'Full house gate on main tip — bash scripts/verify.sh' \
       'the failing STEP is recovered from the real 17:12 payload' "$_REAL_17_12"
  _dur '33s' 'and its DURATION — 33 seconds, not a suite run'      "$_REAL_17_12"

  # ⚠ THE STEP NAME ALONE CANNOT SEPARATE THEM, WHICH IS WHY THE DURATION IS PRINTED. Asserted as an
  # EQUALITY between the two runs rather than left implicit: if a future edit drops the duration,
  # this line still passes and the one below fails, naming exactly what was lost.
  _ds  'Full house gate on main tip — bash scripts/verify.sh' \
       'the 18:08 REAL suite red has the SAME failing step name' "$_REAL_SUITE"
  _dur '' 'and no duration at all, so it cannot be told apart on the step' "$_REAL_SUITE"

  # ⚠ EVERY UNREADABLE INPUT IS SILENT, NEVER A GUESS. A message that omits a detail beats one that
  # invents it, and these must not start emitting "at step null".
  _ds  '' 'no payload -> no step'                    ''
  _ds  '' 'a job by another name -> no step'         '{"jobs":[{"name":"other","steps":[{"conclusion":"failure","name":"x"}]}]}'
  _ds  '' 'malformed json -> no step'                '{not json'
  _dur '' 'no timestamps -> no duration'             '{"jobs":[{"name":"hourly full suite"}]}'
  _dur '' 'malformed json -> no duration'            '{not json'
  # ⚠ A NEGATIVE DURATION IS WITHHELD, NOT PRINTED. Cancelled and skipped jobs in this repo have
  # produced timestamps that run backwards; a duration is offered as evidence and an impossible one
  # must not be.
  _dur '' 'a run that ends before it starts is not reported' \
       '{"jobs":[{"name":"hourly full suite","started_at":"2026-08-22T17:13:25Z","completed_at":"2026-08-22T17:12:52Z"}]}'
  _dur '23m 17s' 'a real suite length is rendered in minutes' \
       '{"jobs":[{"name":"hourly full suite","started_at":"2026-08-22T16:03:18Z","completed_at":"2026-08-22T16:26:35Z"}]}'

  # ── blocked_branch_note — "cannot merge yet" must not be spelled like "this PR is bad" ─────────
  # (infra_a_blocked_merge_queue_reports_every_waiting_pr_as_failed, shape (c'))
  _bn() { local want="$1" desc="$2" caller="$3"; local got; got="$(blocked_branch_note "$caller")"
          if [[ "$got" == *"$want"* ]]; then printf '  ok   %s\n' "$desc"
          else printf '  FAIL %s\n       wanted to contain %q, got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  # ⚠ THE DISCRIMINATING PAIR THE TICKET ASKS FOR. From `verify`, reaching the gate PROVES the
  # branch's own tests passed -- steps stop at the first failure and this one is last -- so the block
  # must say so. A PR whose tests FAIL never reaches this message at all; that is the discrimination,
  # and it is STRUCTURAL rather than a matter of wording.
  _bn 'tests PASSED'        'verify says the branch itself passed'   verify
  _bn 'not been judged yet' 'route makes no claim about the branch'  route
  #/ AN UNKNOWN CALLER MUST NOT CLAIM A PASS. A missing value silently rendering as the stronger
  # claim is how a caveat stops existing -- the same arm as applier_note's unknown provenance.
  if [[ "$(blocked_branch_note '')" != *'PASSED'* ]]; then
    printf '  ok   an unknown caller does NOT claim the tests passed\n'
  else
    printf '  FAIL an unknown caller claims a pass it cannot know about\n'; fails=1
  fi
  # ⚠ NEGATIVE CONTROL, AND IT IS THE ONE THAT MATTERS: if the arms ever render the same string,
  # every assertion above still passes on substring matches. The point is that the three callers say
  # DIFFERENT things, because they know different things.
  if [[ "$(blocked_branch_note verify)" != "$(blocked_branch_note route)" \
     && "$(blocked_branch_note route)" != "$(blocked_branch_note '')" ]]; then
    printf '  ok   NEGATIVE CONTROL: the three callers stay distinguishable\n'
  else
    printf '  FAIL NEGATIVE CONTROL: two callers render identically -- the caller no longer matters\n'; fails=1
  fi

  # ── blocked_lane_advice — the four facts, per lane ─────────────────────────────────────────────
  # (docs_the_full_suite_gate_blocks_a_lane_that_can_never_clear_itself)
  _a()  { local want="$1" desc="$2" lane="$3"; local got; got="$(blocked_lane_advice "$lane")"
          if [[ "$got" == *"$want"* ]]; then printf '  ok   %s\n' "$desc"
          else printf '  FAIL %s\n       wanted to contain %q\n' "$desc" "$want"; fails=1; fi; }
  _an() { local unwant="$1" desc="$2" lane="$3"; local got; got="$(blocked_lane_advice "$lane")"
          if [[ "$got" != *"$unwant"* ]]; then printf '  ok   %s\n' "$desc"
          else printf '  FAIL %s\n       must NOT contain %q\n' "$desc" "$unwant"; fails=1; fi; }

  # ⚠⚠ THE ONE THAT MATTERS: the ledger lane must NEVER be told to re-run. That instruction was
  # given unconditionally before this ticket, and on 2026-08-22 six of the seven blocked PRs were
  # ledger-lane — so it was wrong for six of seven readers, in the direction that costs a seat.
  _an 'RE-RUN THIS PR' 'the LEDGER lane is never told to re-run'                 ledger
  _a  'NOT AT ALL'     '…it is stated as an impossibility, not a delay'          ledger
  _a  'makes the wait LONGER' '…and re-running is named as counterproductive'    ledger
  _a  'empty commit'   '…as is the empty commit, the other thing people try'     ledger

  # ⚠ AND THE ADVICE MUST SURVIVE FOR THE LANE IT IS TRUE OF. Deleting it outright would satisfy the
  # assertion above and remove correct guidance from the code lane — the careless fix, again.
  _a  'RE-RUN THIS PR' 'the FULL lane still gets the re-run advice, which works there' full
  # ── docs_the_blocked_pr_advice_says_rerun_and_the_reflex_spelling_cannot_work ──────────────────
  # ⚠ THE REFLEX SPELLING CANNOT WORK, AND IT IS THE ONE PEOPLE TYPE. `--failed` re-runs only the
  # jobs that FAILED; `route` — the job that decides the promotion — SUCCEEDED. So the decision that
  # has to change is the single thing `--failed` will not re-take. The ticket's raiser made the
  # mistake himself while trying not to repeat a 25-minute suite, which is the evidence the reflex
  # is real rather than hypothetical.
  _a  'NOT `--failed`'  'the full lane is warned off the reflex spelling'             full
  # ⚠ MATCH THE EMITTED FORM, NOT THE ONE IN MY HEAD. My first spelling of this assertion was
  # lowercase and the text prints uppercase — the same authored-vs-emitted distinction that makes a
  # grep for ::warning:: find the echo instead of the output.
  _a  'ATTEMPT ACTUALLY INCREMENTED' 'and told to verify the attempt, not the exit status' full
  # ⚠⚠ AND THE LEDGER LANE MUST NOT RECEIVE ANY OF IT. Giving the ledger arm a re-run instruction
  # while fixing the full arm is the exact defect docs_the_full_suite_gate_blocks_a_lane_that_can
  # _never_clear_itself fixed, where six of seven blocked PRs were told to do something that cannot
  # work — and a re-run there is worse than useless, because it consumes the seat the curing hourly
  # is queued behind.
  _an 'NOT `--failed`'  'the LEDGER lane is not given a spelling for a command it must not run' ledger
  _an 'gh run rerun'    'the LEDGER lane is given no re-run command at all'           ledger
  _a  'NOT work on the ledger lane' '…and is told where it does not apply'             full

  # ⚠ AN UNKNOWN LANE GETS BOTH, NEVER A GUESS. The env var can be absent — an older workflow, a
  # hand-run, a `route` that failed — and picking one at random would be confidently wrong half the
  # time about a fact the reader cannot check.
  _a  'COULD NOT ESTABLISH IT' 'an empty lane says so'                            ''
  _a  'RE-RUN THIS PR'         '…and offers the full-lane branch'                 ''
  _a  'NEVER open the escape'  '…and the ledger-lane branch too'                  ''
  _a  'COULD NOT ESTABLISH IT' 'an unrecognised lane likewise'                    banana

  # ⚠ THE FACTS THAT HOLD FOR EVERY LANE MUST APPEAR ON EVERY LANE. Asserted per lane rather than
  # once, because "it is in the shared tail" is exactly the kind of thing a later edit breaks for
  # one branch only — which is the defect this whole ticket is about.
  for _ln in ledger full '' banana; do
    _a 'SCHEDULED full-suite run on main' "the curing event is named (lane=${_ln:-<empty>})"   "$_ln"
    _a 'does NOT clear this'              "…and that merging a fix is not it (lane=${_ln:-<empty>})" "$_ln"
    _a 'votes for nothing'                "…and that its own run cannot supersede it (lane=${_ln:-<empty>})" "$_ln"
  done

  # ⚠⚠ NEGATIVE CONTROL ON THE VERDICT, NON-NEGOTIABLE: this ticket changes WORDING ONLY. The lane
  # must not reach the decision. Driven rather than asserted in a comment — every verdict input is
  # re-run with FULL_SUITE_LANE set to each lane, and the answer must not move.
  for _ln in ledger full '' banana; do
    _v1="$(FULL_SUITE_LANE="$_ln" queue_block_verdict failure 0 suite '')"
    _v2="$(FULL_SUITE_LANE="$_ln" queue_block_verdict success 0 suite '')"
    _v3="$(FULL_SUITE_LANE="$_ln" queue_block_verdict failure 0 suite green-full)"
    if [[ "$_v1" == block && "$_v2" == proceed && "$_v3" == proceed-on-own-evidence ]]; then
      printf '  ok   the verdict is unmoved by lane=%s\n' "${_ln:-<empty>}"
    else
      printf '  FAIL the verdict MOVED with lane=%s: %q %q %q\n' "${_ln:-<empty>}" "$_v1" "$_v2" "$_v3"; fails=1
    fi
  done

  # ── death_site_line: the sentence itself, both arms ─────────────────────────────────────────────
  _l() { local want="$1" desc="$2"; shift 2; local got; got="$(death_site_line "$@")"
         if [[ "$got" == *"$want"* ]]; then printf '  ok   %s\n' "$desc"
         else printf '  FAIL %s\n       wanted to contain %q, got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  _n() { local unwant="$1" desc="$2"; shift 2; local got; got="$(death_site_line "$@")"
         if [[ "$got" != *"$unwant"* ]]; then printf '  ok   %s\n' "$desc"
         else printf '  FAIL %s\n       must NOT contain %q, got %q\n' "$desc" "$unwant" "$got"; fails=1; fi; }

  _l 'verify.sh' 'the line names the failing step'        'Full house gate on main tip — bash scripts/verify.sh' '33s'
  _l '33s'       '…and how long the run lasted'           'Full house gate on main tip — bash scripts/verify.sh' '33s'
  _l 'did NOT reach the specs' 'a seconds-long run says the specs never ran' 'x' '33s'
  _n 'did NOT reach the specs' 'a 23-minute run does NOT claim that'         'x' '23m 17s'
  _n 'did NOT reach the specs' 'and neither does an unknown duration'        'x' ''

  # ⚠ THE BEFORE CASE. This is what the message did until this ticket: knowing nothing, it said
  # nothing — which is correct for an empty payload and was ALSO what it did when it knew everything.
  # Kept as an assertion so "emits nothing" stays deliberate rather than becoming the default again.
  _n 'It died' 'knowing nothing, it says nothing'         '' ''

  # ⚠ SECONDS NOW. The same three facts as before, exact rather than truncated.
  s fresh   'an hour-old green is fresh'                 $((1*3600)) 6
  s fresh   'exactly at the threshold is still fresh'    $((6*3600)) 6
  s stale   'seven hours with an hourly job means five were missed' $((7*3600)) 6
  s unknown 'an unreadable age is unknown, never fresh'  '' 6
  s unknown 'and a non-numeric age likewise'         nonsense 6

  # ⚠⚠ THE TRUNCATION BOUNDARY, WHICH IS THE WHOLE OF THE SECOND FIX. Before this, the age was
  # floored to whole hours before the comparison, so everything from 6.00h to 6.99h read FRESH while
  # the warning claimed a 6h threshold — a message and a behaviour disagreeing, with only one true.
  # These three cases are what a re-truncation would fail.
  # ⚠ MY FIRST VERSION OF THIS CASE ASSERTED `fresh` HERE and it was the assertion that was wrong,
  # not the code — I had written the OLD lenient behaviour into a case meant to pin the new exact
  # one. With a seconds comparison, one second past the threshold IS past it.
  s stale   'six hours and one SECOND is stale — the comparison is exact now' $((6*3600+1)) 6
  s stale   '…as is six hours and a minute'                       $((6*3600+60)) 6
  s stale   'and 6.99h — the case the old truncation called fresh' 25199 6
  # A larger threshold moves with it rather than being hardcoded anywhere.
  s fresh   'the limit is honoured, not assumed: 7h against a 12h threshold' $((7*3600)) 12
  s stale   '…and 13h against the same threshold'                  $((13*3600)) 12

  # ── blocking_currency: a BLOCK must be read off a page we can prove was not behind ─────────────
  # (infra_the_full_suite_gate_returns_a_wrong_exit_code_when_the_runs_page_is_behind)
  bc() { local want="$1" desc="$2"; shift 2; local got; got="$(blocking_currency "$@")"
         if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
         else printf '  FAIL %s\n       blocking_currency %s -> %q, want %q\n' "$desc" "$*" "$got" "$want"; fails=1; fi; }

  # THE DEFECT. A newer scheduled run has COMPLETED, so a current page sorted newest-first could not
  # have omitted it — our page was behind and the failure we read is not main's latest word.
  bc cannot-tell-behind 'a PROVEN behind page does not block the repo'          block completed
  bc cannot-tell-behind 'a PROVEN behind page does not ADMIT either — its green is void too (#9672)' proceed completed
  bc proceed            'a current page (nothing newer completed) still admits a green'            proceed pending
  bc proceed            'no newer run at all — the green is main'"'"'s latest word, admits'        proceed no
  bc proceed            'confirmation unknown on a green — admits on the page (a failed query is not a red)' proceed unknown
  # ⚠ THE THREE NEGATIVE CONTROLS, AND THEY ARE THE HALF THAT KEEPS THIS FROM BEING A HOLE.
  # Without them "return cannot-tell" is satisfied by a function that never blocks at all, which
  # removes the safety net instead of repairing it — the archived sibling ticket's own third item.
  bc block  'nothing newer at all is PROOF OF CURRENCY — a genuine red still blocks'  block no
  bc block  'runs created but none completed: ours IS the newest completed — blocks'  block pending
  bc block  'an UNCONFIRMED reading still blocks — we abandon a block only on proof'  block unknown
  bc block  '…and an unrecognised confirmation value never opens the gate'           block banana
  bc block  '…nor does a missing confirmation argument'                              block
  # ⚠ AND IT MUST NOT TOUCH ANY OTHER VERDICT. This runs on every invocation; a function that
  # rewrote `proceed` or `cannot-tell` would change the gate everywhere for a defect on one path.
  # ⚠ FLIPPED: this arm used to pin a proceed from a proven-behind page as 'passed through untouched' —
  # the defect. A behind page voids its green exactly as it voids its red.
  bc cannot-tell-behind 'a proceed from a proven-behind page is NOT passed through — it is void' proceed completed
  bc proceed-on-own-evidence  'so is the deadlock escape'   proceed-on-own-evidence completed
  bc cannot-tell              'so is cannot-tell'                           cannot-tell completed
  bc ''                       'and an empty verdict stays empty'                     '' completed

  # ── staleness_verdict: a `stale` reading is confirmed before it is believed ────────────────────
  # (infra_the_full_suite_gate_intermittently_reports_a_fresh_suite_as_stale)
  sv() { local want="$1" desc="$2"; shift 2; local got; got="$(staleness_verdict "$@")"
         if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
         else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }

  # ⚠ THE NEGATIVE CONTROL FIRST, BECAUSE IT IS THE ONE THAT MATTERS. A genuinely absent hourly has
  # nothing newer than the run we measured, so the warning MUST still fire. A fix that made the false
  # positive go away by never warning would have removed the safety net rather than repaired it.
  sv stale   'a stale age with nothing newer STILL warns — the safety net'   stale   no
  # ⚠⚠ THE CASE THAT CAUGHT THE FIRST VERSION OF THIS FIX. Runs are being CREATED but none has
  # COMPLETED: the scheduler is alive and the suite is not finishing. A two-valued check read that
  # as "something newer exists, so we must have been looking at a stale page" and went quiet —
  # REMOVING coverage the unfixed gate had. Measured 2026-08-27: newest scheduled run `queued`,
  # newest COMPLETED ~5h old, so this is close to the live state rather than a corner.
  sv stale   'runs created but NONE completed is an outage, not freshness'   stale   pending
  # The observed false positive: a newer run really did COMPLETE, so our page was behind and the
  # true age is younger than we measured.
  sv unknown 'a newer COMPLETED run means the page lagged, not that it is stale' stale completed
  sv unknown 'an unrecognised confirmation value is unknown, never stale'    stale   yes
  # ⚠ AND AN UNCONFIRMABLE STALE IS NOT A STALE. This is the shape the gate was bitten by: a reading
  # that could not be established, believed because it looked like a real number.
  sv unknown 'a stale age that could NOT be confirmed is unknown'            stale   unknown
  sv unknown '…and an absent confirmation argument likewise'                 stale
  # Fresh and unknown pass straight through — a newer run can only make a fresh reading fresher, and
  # confirming an already-unknown reading cannot rescue it.
  sv fresh   'a fresh reading is unaffected by anything newer'               fresh   completed
  sv fresh   '…and by nothing newer'                                        fresh   no
  sv unknown 'an unknown reading stays unknown however it is confirmed'      unknown no
  sv unknown 'a nonsense note is unknown, never stale'                       banana  no

  # ── newer_is_superseding: `completed` is a lifecycle state, not a verdict ────────────────────
  nis() { local want="$1" desc="$2"; shift 2; local got; got="$(newer_is_superseding "$@")"
          if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
          else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }

  # ⚠ THE ROW THIS FUNCTION EXISTS FOR. Four of these on 2026-09-05, each a suite killed at 45m17s.
  nis no  'a completed run that was CANCELLED supersedes nothing'        completed cancelled
  nis no  '…nor a skipped one'                                          completed skipped
  nis no  '…nor one whose conclusion we did not get'                    completed ''
  # ⚠ THE POSITIVE HALF, WHICH IS WHAT KEEPS THIS FROM BEING A GATE THAT NEVER OPENS. The archived
  # sibling ticket's whole point was that a genuinely behind page must NOT block the repo, and every
  # one of these must still say yes or that protection is gone.
  nis yes 'a completed SUCCESS is proof the page was behind'             completed success
  nis yes '…and so is a completed FAILURE — a verdict either way'        completed failure
  nis yes '…and a genuine timed_out, on the rare day GitHub says it'     completed timed_out
  nis yes '…and startup_failure'                                        completed startup_failure
  nis yes '…and action_required'                                        completed action_required
  # A run that has not finished proves nothing regardless of what the conclusion field holds.
  nis no  'an in_progress run is not proof, whatever its conclusion says' in_progress success
  nis no  'nor a queued one'                                            queued    ''
  nis no  'and a missing status is not a completion'                     ''        success

  # ── run_job_dispatched: did it ever get a runner? duration cannot answer that ────────────────
  njd() { local want="$1" desc="$2" json="$3"; local got; got="$(run_job_dispatched "$json" 'hourly full suite')"
          if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
          else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }

  # ⚠ THE ROW THIS EXISTS FOR: a null runner beside an 86-minute stamped span. The duration is real
  # arithmetic and means nothing, because nothing ran.
  njd no  'a null runner_name is NOT dispatched, however long the span' \
      '{"jobs":[{"name":"hourly full suite","runner_name":null,"started_at":"2026-09-05T20:08:03Z","completed_at":"2026-09-05T21:34:21Z"}]}'
  njd no  '…and an EMPTY runner_name likewise' \
      '{"jobs":[{"name":"hourly full suite","runner_name":"","started_at":"2026-09-05T20:08:03Z","completed_at":"2026-09-05T21:34:21Z"}]}'
  njd no  '…and an absent runner_name key' \
      '{"jobs":[{"name":"hourly full suite","started_at":"2026-09-05T20:08:03Z","completed_at":"2026-09-05T21:34:21Z"}]}'
  # ⚠ THE POSITIVE HALF — without these the guard could be "always no" and every timeout would stop
  # blocking, silently restoring the defect this whole ticket exists to fix.
  njd yes 'a named runner IS dispatched'  '{"jobs":[{"name":"hourly full suite","runner_name":"canary-box"}]}'
  # The job we care about is absent / the payload is unusable -> no claim, which leaves old behaviour.
  njd no  'a payload with no such job makes no claim'  '{"jobs":[{"name":"something else","runner_name":"canary-box"}]}'
  njd no  'an empty payload makes no claim'            ''
  njd no  'unparseable JSON makes no claim'            'not json at all'
  # ⚠ A THIRD ROUTE, NOT A REPEAT: a run cancelled while PENDING is never expanded into jobs, so
  # there is NO JOB OBJECT and therefore no `runner_name` to interrogate — the discriminator every
  # other case turns on is simply absent. Same verdict, different path. (Real: run 33992051892
  # returns {"total_count":0,"jobs":[]}.) Verified working before this was written; pinned because
  # nothing pinned it, which is the whole argument for a positive control.
  njd no  'a run with an EMPTY jobs array has no runner_name to read' '{"jobs":[]}'
  njd no  '…and one with no jobs key at all'                          '{}'

  # ── creation_cadence: the qualifier that travels with the claim ────────────────────────────────
  cc() { local want="$1" desc="$2"; shift 2; local got; got="$(creation_cadence "$@")"
         if [[ "$got" == *"$want"* ]]; then printf '  ok   %s\n' "$desc"
         else printf '  FAIL %s\n       want *%q* got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  # An exactly-hourly scheduler: three runs an hour apart.
  cc "median gap 1.00h" 'an hourly cadence reads as a 1.00h median gap' \
     1000000000 999996400 1000000000 999992800
  # ⚠ THE CASE THIS EXISTS FOR: half rate. Same three runs, two hours apart.
  cc "median gap 2.00h" 'a half-rate cadence is visible in the same string' \
     1000000000 999992800 1000000000 999985600
  cc "3 created in" '…and it says HOW MANY it saw, not a rate per day' \
     1000000000 999992800 1000000000 999985600
  # ⚠ FEWER THAN TWO TIMESTAMPS CANNOT SHOW A CADENCE — say so rather than invent one.
  cc "cadence unknown (1" 'one timestamp cannot show a cadence' 1000000000 999996400
  cc "cadence unknown (0" 'no timestamps likewise'              1000000000
  cc "cadence unknown (0" 'and non-numeric input is discarded, not parsed' 1000000000 banana ''

  # ── newest_conclusive (fix_the_full_suite_gate_reads_one_run_so_a_cancellation_hides_a_red) ─────
  n() { local want="$1" desc="$2" input="$3" got
        got="$(printf '%s' "$input" | newest_conclusive)"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }

  # ⚠ THE CASE THIS EXISTS FOR, AND IT IS A POSITIVE CONTROL: the newest run is CANCELLED and the one
  # beneath it is a genuine RED. The old `[0]` logic answered cannot-tell and the queue PROCEEDED.
  _CANCELLED_OVER_RED=$'cancelled\t2026-08-19T11:07:28Z\t32241130302\nfailure\t2026-08-19T07:18:50Z\t32227085229'
  n $'failure\t2026-08-19T07:18:50Z\t32227085229' \
    'a cancelled newest run does not hide the RED beneath it' "$_CANCELLED_OVER_RED"

  # ⚠ THE NEGATIVE CONTROL FOR THAT ASSERTION. Without it the test above could pass against a gate
  # that was never broken; this pins that today's one-run reading really does answer `cancelled` on
  # the same fixture, so the fix has a demonstrated subject.
  _first="$(printf '%s' "$_CANCELLED_OVER_RED" | head -1)"
  if [[ "$(queue_block_verdict "${_first%%$'\t'*}" 0)" == cannot-tell \
     && "$(queue_block_verdict failure 0)" == block ]]; then
    printf '  ok   …and the OLD [0] reading answered cannot-tell on that same fixture\n'
  else
    printf '  FAIL the pre-fix reading no longer demonstrates the defect\n'; fails=1
  fi

  # Real data shape from 2026-08-19: the newest was cancelled and the two below were green.
  n $'success\t2026-08-19T09:44:18Z\t32236374617' \
    'a cancelled newest run does not hide the GREEN beneath it either' \
    $'cancelled\t2026-08-19T11:07:28Z\t32241130302\nsuccess\t2026-08-19T09:44:18Z\t32236374617\nsuccess\t2026-08-19T08:36:18Z\t32231354206'

  n $'failure\t3\t3' 'several inconclusive runs are skipped in order' \
    $'cancelled\t1\t1\nskipped\t2\t2\nfailure\t3\t3'

  # ⚠ AN EXHAUSTED WINDOW PRINTS NOTHING — it must never walk off the end and report the oldest
  # thing it can see as though it were current. The caller turns this into NO_CONCLUSIVE_RUN.
  n '' 'a window with nothing conclusive answers nothing' $'cancelled\t1\t1\nskipped\t2\t2'
  n '' 'an empty window answers nothing'                  ''
  n '' 'blank lines are not a conclusion'                 $'\n \n'

  # …and NO_CONCLUSIVE_RUN must reach cannot-tell, never green.
  v cannot-tell 'an exhausted window is cannot-tell, never a pass' NO_CONCLUSIVE_RUN 0
  # …and a window whose newest verdict could not be PLACED (a commit that does not resolve) likewise.
  v cannot-tell 'an unrankable window is cannot-tell, never the clock order guessed back in' ORDER_UNRESOLVED 0

  n $'success\t9\t9' 'a conclusive newest run is returned unchanged' $'success\t9\t9\nfailure\t8\t8'
  # ── a dispatched full suite is merged by time with the scheduled ones ──
  m() { local want="$1" desc="$2"; shift 2; local got; got="$(merge_by_updated "$@" | newest_conclusive)"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  m $'success\t2026-09-06T10:30:00Z\t2' 'dispatch: a NEWER green dispatched run beats an older red scheduled one' \
    $'failure\t2026-09-06T10:08:00Z\t1' $'success\t2026-09-06T10:30:00Z\t2'
  m $'failure\t2026-09-06T11:08:00Z\t3' 'dispatch: a newer red scheduled run beats an older green dispatched one — the last verdict decides' \
    $'failure\t2026-09-06T11:08:00Z\t3' $'success\t2026-09-06T10:30:00Z\t2'
  m $'failure\t2026-09-06T10:08:00Z\t1' 'dispatch NEGATIVE CONTROL: an empty dispatched list changes nothing' \
    $'failure\t2026-09-06T10:08:00Z\t1' ''
  m $'success\t2026-09-06T10:30:00Z\t2' 'dispatch: a cancelled scheduled run on top does not hide the dispatched green beneath it' \
    $'cancelled\t2026-09-06T11:08:00Z\t4\nfailure\t2026-09-06T10:08:00Z\t1' $'success\t2026-09-06T10:30:00Z\t2'

  # ── ranked by COMMIT, not completion time ──────────────────────────────────────────────────────
  # (fix_the_full_suite_gate_ranks_verdicts_by_completion_time_so_a_stale_run_on_an_old_sha_can_outrank_a_newer_green)
  # A subshell, so the stubbed commit_generation (a map, no git) cannot leak into a later arm.
  # aaaaaaa is an ancestor of bbbbbbb (fewer commits); ddddddd resolves nowhere.
  ( declare -A _GEN=([aaaaaaa]=100 [bbbbbbb]=101)
    commit_generation() { [[ -n "${_GEN[${1-}]:-}" ]] && printf '%s\n' "${_GEN[$1]}"; return 0; }
    fails=0
    o() { local want="$1" desc="$2" in="$3" got rc
          got="$(order_by_commit <<<"$in")"; rc=$?
          [[ $rc -eq 0 ]] && got="$(newest_conclusive <<<"$got")"
          if [[ "$got|$rc" == "$want" ]]; then printf '  ok   %s\n' "$desc"
          else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got|$rc"; fails=1; fi; }
    # ⚠ POSITIVE CONTROL FIRST: the 2026-09-28 10:10Z shape. A red on the ANCESTOR that finishes LATER
    # must not outrank the green on its descendant — ranked by the clock it would, and re-block main
    # on a commit that is no longer main.
    o $'success\t2026-09-28T11:10:00Z\tbbbbbbb\t36410849862|0' \
      'a red on an ancestor that finished AFTER a green on its descendant is superseded — PROCEED' \
      $'failure\t2026-09-28T11:20:00Z\taaaaaaa\t36408080060\nsuccess\t2026-09-28T11:10:00Z\tbbbbbbb\t36410849862'
    # …and the same rule does not become "green wins": a NEWER commit's red is not excused by an
    # older commit's green that happened to finish later.
    o $'failure\t2026-09-28T11:10:00Z\tbbbbbbb\t2|0' \
      'a green on an ancestor finishing after a red on its descendant does NOT lift the red — BLOCK' \
      $'success\t2026-09-28T11:20:00Z\taaaaaaa\t1\nfailure\t2026-09-28T11:10:00Z\tbbbbbbb\t2'
    o $'failure\t2026-09-28T11:20:00Z\taaaaaaa\t1|0' \
      'two verdicts on the SAME commit: the later completion wins, as before' \
      $'failure\t2026-09-28T11:20:00Z\taaaaaaa\t1\nsuccess\t2026-09-28T11:10:00Z\taaaaaaa\t2'
    o $'order_by_commit: cannot rank run(s) 1@ddddddd — the commit does not resolve here|2' \
      'a conclusive run whose commit cannot be resolved is CANNOT TELL (rc 2), never a guessed order' \
      $'failure\t2026-09-28T11:20:00Z\tddddddd\t1\nsuccess\t2026-09-28T11:10:00Z\tbbbbbbb\t2'
    o $'order_by_commit: cannot rank run(s) 1 — the commit does not resolve here|2' \
      'a conclusive run with NO sha in a sha-bearing list is cannot-tell too' \
      $'failure\t2026-09-28T11:20:00Z\t\t1\nsuccess\t2026-09-28T11:10:00Z\tbbbbbbb\t2'
    o $'success\t2026-09-28T11:10:00Z\tbbbbbbb\t2|0' \
      'an INCONCLUSIVE run whose commit cannot be resolved does not stop the ranking — it cannot win' \
      $'cancelled\t2026-09-28T11:30:00Z\tddddddd\t9\nfailure\t2026-09-28T11:20:00Z\taaaaaaa\t1\nsuccess\t2026-09-28T11:10:00Z\tbbbbbbb\t2'
    # NEGATIVE CONTROL: the three-column shape (recorded fixtures, stubs) has nothing to rank by and
    # passes through byte-identical, so every arm above this block keeps meaning what it meant.
    _legacy=$'failure\t2026-09-06T11:08:00Z\t3\nsuccess\t2026-09-06T10:30:00Z\t2'
    if [[ "$(order_by_commit <<<"$_legacy")" == "$_legacy" ]]; then printf '  ok   NEGATIVE CONTROL: three-column rows pass through unchanged\n'
    else printf '  FAIL NEGATIVE CONTROL: three-column rows were reordered\n'; fails=1; fi
    exit "$fails" ) || fails=1
  # ⚠ AND THE REAL commit_generation, against this repo's own history — the order is STRICT along
  # ancestry, which is the whole claim the ranking rests on. HEAD~1 is always an ancestor of HEAD.
  # Outside a repo with that history (a bare tarball) this says so rather than passing.
  _gh="$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)" || _gh=''
  _gp="$(git rev-parse -q --verify 'HEAD~1^{commit}' 2>/dev/null)" || _gp=''
  if [[ -n "$_gh" && -n "$_gp" ]]; then
    _nh="$(commit_generation "$_gh")"; _np="$(commit_generation "$_gp")"
    if [[ "$_nh" =~ ^[0-9]+$ && "$_np" =~ ^[0-9]+$ ]] && (( _np < _nh )); then
      printf '  ok   commit_generation is strict along ancestry on real history (HEAD~1 %s < HEAD %s)\n' "$_np" "$_nh"
    else printf '  FAIL commit_generation: HEAD~1=%q HEAD=%q — not strictly increasing\n' "$_np" "$_nh"; fails=1; fi
    if [[ -z "$(FULL_SUITE_GATE_FETCH=0 commit_generation 0000000000000000000000000000000000000000)" ]]; then
      printf '  ok   commit_generation answers NOTHING for a commit that does not exist (never a guessed rank)\n'
    else printf '  FAIL commit_generation invented a rank for a missing commit\n'; fails=1; fi
  else
    printf '  --   commit_generation on real history: NOT RUN — no HEAD~1 here (not a pass)\n'
  fi

  # ── the repair lane's reading of a jobs listing ──
  r() { local want="$1" desc="$2" json="$3" got
        got="$(repair_job_verdict "$json" 'repair full suite (main is red)' 'Prove the browser suite ran')"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  _R_GREEN='{"jobs":[{"name":"verify","status":"in_progress","conclusion":null},{"name":"repair full suite (main is red)","status":"completed","conclusion":"success","steps":[{"name":"Full house gate on the merged tree — bash scripts/verify.sh","conclusion":"success"},{"name":"Prove the browser suite ran","conclusion":"success"}]}]}'
  r green-full 'repair: a completed, successful job whose proof step passed is green-full' "$_R_GREEN"
  r red        'repair NEGATIVE CONTROL: job success but the proof step is MISSING is red, not green' \
    '{"jobs":[{"name":"repair full suite (main is red)","status":"completed","conclusion":"success","steps":[{"name":"Full house gate on the merged tree — bash scripts/verify.sh","conclusion":"success"}]}]}'
  r red        'repair NEGATIVE CONTROL: proof step skipped (job green by reaching it) is red' \
    '{"jobs":[{"name":"repair full suite (main is red)","status":"completed","conclusion":"success","steps":[{"name":"Prove the browser suite ran","conclusion":"skipped"}]}]}'
  r red        'repair: a failed job is red' \
    '{"jobs":[{"name":"repair full suite (main is red)","status":"completed","conclusion":"failure","steps":[{"name":"Prove the browser suite ran","conclusion":"skipped"}]}]}'
  r running    'repair: a job still in progress is running, not a verdict' \
    '{"jobs":[{"name":"repair full suite (main is red)","status":"in_progress","conclusion":null,"steps":[]}]}'
  # ── the repair-main proof, required in EVERY state of main ──
  # (infra_a_repair_main_pr_whose_own_full_suite_is_red_is_landed_anyway_because_only_verify_is_required)
  pv() { local want="$1" desc="$2" got; got="$(repair_proof_verdict "$3" "$4")"
         if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
         else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  pv proven       'proof: label + a green-full repair job is allowed'                 1 green-full
  pv refused      'proof: label + a RED repair job is refused (the #9352 case)'        1 red
  pv refused      'proof: label + NO repair job in the run (skipped/cancelled) is refused' 1 absent
  pv refused      'proof: label + still running at the wait limit is refused'          1 running
  pv refused      'proof: label + an unreadable jobs listing is refused'               1 unreadable
  pv refused      'proof: label + no verdict at all is refused'                         1 ''
  pv not-required 'proof NEGATIVE CONTROL: NO label + a red repair job is ignored'       0 red
  pv not-required 'proof NEGATIVE CONTROL: NO label + green is not required either'      0 green-full
  r absent     'repair: no such job in the run (no label on the event) is absent' \
    '{"jobs":[{"name":"verify","status":"in_progress","conclusion":null}]}'
  r absent     'repair NEGATIVE CONTROL: an unreadable listing is absent, never green' 'not json'
  r absent     'repair NEGATIVE CONTROL: an EMPTY listing is absent, never green' ''
  # ── the dispatch arm must be able to READ its source: `gh api` takes no `--arg` ─────────────
  if grep -qE -- '--jq +--arg t "\$DISPATCH' "${BASH_SOURCE[0]}"; then   # the call shape, not prose about it
    printf '  FAIL a `gh api … --jq --arg` call is back — gh refuses it and the dispatch arm goes silent\n'; fails=1
  else printf '  ok   no `gh api --jq --arg` shape in this file — the dispatch arm can read its source\n'; fi
  # ── hourly_job_verdict: the RUN-level conclusion is not the hourly's ────────────────────────
  hj() { local want="$1" desc="$2" json="$3"; local got; got="$(hourly_job_verdict "$json" 'hourly full suite')"
         if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
         else printf '  FAIL %s\n       want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  # ⚠ THE ROW THIS EXISTS FOR, verbatim shape of run 33827079599 (2026-09-04 01:47Z): the nightly's
  # run, hourly job skipped, runner null, completed before it started; run-level said `failure`.
  _NIGHTLY='{"jobs":[{"name":"hourly full suite","status":"completed","conclusion":"skipped","runner_name":null,"started_at":"2026-09-04T01:47:30Z","completed_at":"2026-09-04T01:47:29Z"},{"name":"nightly full verify (drift detector)","status":"completed","conclusion":"failure","runner_name":"forge-box"}]}'
  hj gap        'a nightly run: hourly job SKIPPED with no runner is a GAP, not a verdict' "$_NIGHTLY"
  hj executed   'an hourly that ran on a runner and concluded is executed' \
      '{"jobs":[{"name":"hourly full suite","status":"completed","conclusion":"failure","runner_name":"canary-box"}]}'
  hj gap        'no hourly job in the run at all is a gap' '{"jobs":[{"name":"verify","status":"completed","conclusion":"success","runner_name":"forge-box"}]}'
  hj gap        'an hourly job that never got a runner (cancelled in the queue) is a gap' \
      '{"jobs":[{"name":"hourly full suite","status":"completed","conclusion":"cancelled","runner_name":""}]}'
  hj executed   'a cancelled hourly that HAD a runner is executed (the timeout scan judges it, not this)' \
      '{"jobs":[{"name":"hourly full suite","status":"completed","conclusion":"cancelled","runner_name":"canary-box"}]}'
  hj executed   'a concluded failure with NO runner_name field is still executed — the conclusion proves it ran' \
      '{"jobs":[{"name":"hourly full suite","status":"completed","conclusion":"failure"}]}'
  hj unreadable 'an unreadable listing is unreadable — never executed, never gap' 'not json'
  hj unreadable 'an EMPTY listing is unreadable' ''
  # the walk: a green nightly newest, above a red hourly — the verdict must be the red hourly's
  _GREEN_NIGHTLY_OVER_RED=$'success\t2026-09-04T03:53:59Z\t33827079599\nfailure\t2026-09-04T01:40:00Z\t33826000000'
  got="$(drop_run "$_GREEN_NIGHTLY_OVER_RED" 33827079599 | newest_conclusive)"
  if [[ "$got" == $'failure\t2026-09-04T01:40:00Z\t33826000000' ]]; then printf '  ok   dropping the gap run leaves the RED hourly beneath it as the verdict\n'
  else printf '  FAIL drop_run + newest_conclusive: %q\n' "$got"; fails=1; fi
  got="$(drop_run "$_GREEN_NIGHTLY_OVER_RED" '' | newest_conclusive)"
  if [[ "$got" == $'success\t2026-09-04T03:53:59Z\t33827079599' ]]; then printf '  ok   NEGATIVE CONTROL: without the drop the nightly'"'"'s run-level green would stand in for main\n'
  else printf '  FAIL negative control: %q\n' "$got"; fails=1; fi

  v proceed-on-own-evidence 'and green-full from the repair job opens the SAME escape a green own-result does' failure 0 suite green-full
  v block   'while red from the repair job leaves the block exactly as it was'              failure 0 suite ''
  (( fails == 0 )) && { printf 'full-suite-gate: selftest ok\n'; exit 0; }
  printf 'full-suite-gate: selftest FAILED\n' >&2; exit 1
fi

# ── the impure half ─────────────────────────────────────────────────────────────────────────────
REPO="${GITHUB_REPOSITORY:-${HARNESS_REPO:-owner/repo}}"
WORKFLOW="${FULL_SUITE_WORKFLOW:-ci.yml}"
JOB_NAME="${FULL_SUITE_JOB_NAME:-hourly full suite}"

# ⚠ READ THE RUN'S CONCLUSION, NEVER A CHECK SUMMARY. `gh pr checks` renders a CANCELLED check as
# `fail`, so a corpus built from check summaries counts destroyed evidence as reds — recorded in
# infra_attribute_a_red_batch_before_bisecting and it applies exactly here, where a cancelled run
# must land in cannot-tell rather than in block.
CONCL=""
AGE_H=""     # display only, one decimal — never compared against anything
AGE_S=""     # the integer seconds every comparison uses
RUN_ID=""
RUN_SHA=""
sha9() { local s="${RUN_SHA:0:9}"; printf '%s' "${s:-?}"; }   # the admitted run's sha, or ? when the row carried none
WHERE=""
DEAD_STEP=""   # the failing step's NAME (infra_the_merge_queue_block_message_throws_away_the_death_site_it_just_computed)
JOB_DUR=""     # how long that job ran — the discriminator the step name is not
STAGE_REPORT="" # the stage report the run published (infra_the_verify_stage_chain_hides_the_whole_browser_suite_behind_any_earlier_red)
if runs="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?event=schedule&branch=main&status=completed&per_page=20" \
            --jq '.workflow_runs[] | "\(.conclusion // "")\t\(.updated_at // "")\t\(.head_sha // "")\t\(.id // "")"' 2>/dev/null)"; then
  # ⚠ THE WHOLE PAGE, THEN THE NEWEST CONCLUSIVE ONE — not `[0]`. A cancelled newest run must not
  # speak for the run beneath it, in either direction.
  # (fix_the_full_suite_gate_reads_one_run_so_a_cancellation_hides_a_red)
  # ── WAS THE NEWEST RUN KILLED BY ITS OWN TIMEOUT? ────────────────────────────────────────────
  # ⚠ THIS MUST HAPPEN BEFORE THE WALK, WHICH IS THE WHOLE POINT. `newest_conclusive` skips a
  # `cancelled` run and reports an older one — so by the time the verdict is computed the timeout is
  # gone and the gate announces a green that predates the fault. Substituting the sentinel here is
  # what puts the timeout back in front of the walk.
  #
  # ⚠ EVIDENCE, NOT INFERENCE, AND EVERY MISSING PIECE LEAVES THE OLD BEHAVIOUR. No limit configured,
  # no duration, an unreadable payload, a non-cancelled newest run — each leaves `$runs` untouched and
  # the walk behaves exactly as before. This adds a way to BLOCK, and a blocking path built on a guess
  # is worse than the gap it closes.
  #
  # ⚠⚠ IT WALKS THE LEADING RUN OF CANCELLED ENTRIES, NOT JUST THE NEWEST ONE, AND THAT MATTERS.
  # The first version examined `[0]` only. Driven live 2026-09-05 at 23:15Z it exited 0 and announced
  # a 7.6-hour-old green while FIVE dispatched timeouts sat in the page — because a SIXTH run, created
  # 21:06, had been superseded while pending (`cancelled`, no hourly job at all) and landed on top.
  # ⚠ ONE supersede above N timeouts defeated the whole fix, and supersedes are routine whenever the
  # queue is deep — `cancel-in-progress` is false for `schedule`, which protects a RUNNING run but not
  # a PENDING one. So the sentinel has to be able to reach past a run that carries no information.
  #
  # ⚠ COST IS STILL BOUNDED AND STILL ZERO ON THE HAPPY PATH: the loop stops at the first entry that
  # is not `cancelled`, so a success or failure at the head costs no calls at all. FULL_SUITE_TIMEOUT_SCAN
  # caps it (default 6) so a page of nothing but cancellations cannot turn one gate run into twenty
  # API calls.
  if [[ "${FULL_SUITE_TIMEOUT_MIN:-}" =~ ^[0-9]+$ ]]; then
    _scan_prefix=""; _scan_rest="$runs"; _scanned=0
    while [[ -n "$_scan_rest" ]]; do
      _scan_line="${_scan_rest%%$'\n'*}"
      # Stop at the first entry that is not a cancellation: it carries a real verdict and the walk
      # below will find it. This is what keeps the happy path free of API calls.
      [[ "${_scan_line%%$'\t'*}" == cancelled ]] || break
      (( _scanned < ${FULL_SUITE_TIMEOUT_SCAN:-6} )) || break
      _scanned=$(( _scanned + 1 ))
      # everything after this line, or empty when this is the last one (guards an infinite loop)
      if [[ "$_scan_rest" == *$'\n'* ]]; then _scan_tail="${_scan_rest#*$'\n'}"; else _scan_tail=""; fi
      _cid="${_scan_line##*$'\t'}"
      if [[ -n "$_cid" ]] && _cjobs="$(gh api "repos/$REPO/actions/runs/$_cid/jobs?per_page=100" 2>/dev/null)"; then
      _cdur="$(run_job_duration_s "$_cjobs" "$JOB_NAME")"
      # ⚠⚠ DISPATCH FIRST, DURATION SECOND — AND THIS ORDER IS THE WHOLE GUARD.
      # A job that never got a runner is stamped `started_at = created_at` and `completed_at` at
      # cancellation, so its "duration" is the QUEUE WAIT — a real number that reads exactly like
      # execution time. On a saturated seat it routinely EXCEEDS the limit: measured 2026-09-05, the
      # hourly created 20:08:03 did not start until 21:34:21, **86 minutes of queue against a
      # 45-minute timeout**. Without this check that run supersedes into a TIMED_OUT_CANCEL and
      # BLOCKS THE MERGE QUEUE on a suite that never executed — a false block, the expensive
      # direction, and indistinguishable from a real one downstream.
      # ⚠ The defect this ticket exists to fix is TWO MECHANISMS SHARING ONE CONCLUSION STRING
      # (`cancelled` = human cancel or timeout kill). Duration alone reproduces that same conflation
      # one layer down: `>= 45 min` = killed at the wall OR merely queued a long time. `runner_name`
      # is the discriminator; duration never is.
      if [[ "$(run_job_dispatched "$_cjobs" "$JOB_NAME")" == yes ]] \
         && [[ "$_cdur" =~ ^[0-9]+$ ]] && (( _cdur >= FULL_SUITE_TIMEOUT_MIN * 60 )); then
        runs="${_scan_prefix}TIMED_OUT_CANCEL${_scan_line#cancelled}"
        [[ -n "$_scan_tail" ]] && runs+=$'\n'"$_scan_tail"
        break
      fi
      fi
      # not a provable timeout — keep it in place and look beneath it
      _scan_prefix+="$_scan_line"$'\n'
      _scan_rest="$_scan_tail"
    done
  fi

  # A dispatched full suite (DISPATCH_TITLE) is a verdict too. Its query failing is NOT a cannot-tell
  # for the whole gate — the scheduled list still answers — so it degrades to an empty list.
  # ⚠ `gh api` HAS NO `--arg`. The first cut passed the title with `--jq --arg t …`; gh refused it
  # ("accepts 1 arg(s), received 4"), `2>/dev/null` ate the message and `|| dispatched=""` turned the
  # refusal into an empty list — so the dispatch arm NEVER contributed a verdict. 2026-09-07: a repair
  # merged at 13:39Z, the full suite was dispatched and went green, and the block did not lift on it.
  # Found by Carl driving the call by hand. The filter now runs in jq AFTER the call (a full reader,
  # safe under pipefail), and the self-test refuses the `--jq --arg` shape in this file.
  dispatched="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?event=workflow_dispatch&branch=main&status=completed&per_page=20" 2>/dev/null \
            | jq -r --arg t "$DISPATCH_TITLE" '.workflow_runs[] | select(.display_title == $t) | "\(.conclusion // "")\t\(.updated_at // "")\t\(.head_sha // "")\t\(.id // "")"' 2>/dev/null)" || dispatched=""
  _merged="$(merge_by_updated "$runs" "$dispatched")"
  # ⚠ RANK BY THE COMMIT, NOT THE CLOCK. merge_by_updated orders by when each run FINISHED; the
  # question is what main's newest TESTED commit says, and a stale run on an ancestor can finish last.
  # (fix_the_full_suite_gate_ranks_verdicts_by_completion_time_so_a_stale_run_on_an_old_sha_can_outrank_a_newer_green)
  _order_unresolved=0
  _by_clock="$(newest_conclusive <<<"$_merged")"
  if _ordered="$(order_by_commit <<<"$_merged")"; then
    _merged="$_ordered"
    _by_commit="$(newest_conclusive <<<"$_merged")"
    if [[ -n "$_by_clock" && "${_by_clock##*$'\t'}" != "${_by_commit##*$'\t'}" ]]; then
      # Name both, so the log says which run decided and which was set aside, and why.
      printf '::notice::run %s (%s, finished later) is SUPERSEDED by run %s on a descendant commit — ranked by commit, not completion time.\n' \
        "${_by_clock##*$'\t'}" "${_by_clock%%$'\t'*}" "${_by_commit##*$'\t'}"
    fi
  else
    _order_unresolved=1
    printf '::warning::%s\n' "$_ordered"
  fi
  # ⚠ READ THE HOURLY JOB, NOT THE RUN. newest_conclusive picks by run-level conclusion; a nightly
  # run whose hourly job was skipped carries the NIGHTLY's verdict. Drop such gaps and pick again,
  # bounded — one nightly a day is the normal cost. See hourly_job_verdict.
  out=""; _hops=0
  while (( ! _order_unresolved )); do
    out="$(newest_conclusive <<<"$_merged")"   # herestring: newest_conclusive returns early, and a pipe would SIGPIPE the producer
    [[ "$out" == *[![:space:]]* ]] || break
    _oid="${out##*$'\t'}"
    if [[ "${out%%$'\t'*}" == TIMED_OUT_CANCEL ]]; then break; fi   # already proven dispatched by the scan above
    if _ojobs="$(gh api "repos/$REPO/actions/runs/$_oid/jobs?per_page=100" 2>/dev/null)"; then
      case "$(hourly_job_verdict "$_ojobs" "$JOB_NAME")" in
        executed) break ;;
        gap)
          printf '::notice::run %s did not execute the %q job (a nightly, or never dispatched) — a GAP, not a verdict; reading the next scheduled run.\n' "$_oid" "$JOB_NAME"
          _merged="$(drop_run "$_merged" "$_oid")"; _hops=$(( _hops + 1 ))
          (( _hops < 5 )) || { printf '::warning::five scheduled runs in a row without the %q job — keeping the run-level read of %s.\n' "$JOB_NAME" "$_oid"; break; } ;;
        *) printf '::warning::could not read run %s'"'"'s jobs — keeping its run-level conclusion.\n' "$_oid"; break ;;
      esac
    else
      printf '::warning::could not list run %s'"'"'s jobs — keeping its run-level conclusion.\n' "$_oid"; break
    fi
  done
  if (( _order_unresolved )); then
    # A conclusive run's commit could not be placed, so which verdict is NEWEST is unknown. Guessing
    # the clock order back in would reintroduce the defect on exactly the reading we could not check.
    CONCL="ORDER_UNRESOLVED"
  elif [[ "$out" != *[![:space:]]* ]]; then
    # Every run in the window was cancelled/skipped/neutral. That is genuinely cannot-tell, and
    # saying WHICH kind matters: "we looked at 20 runs and none concluded" is a different fact from
    # "the API would not answer", and a different one again from "the last one was cancelled".
    CONCL="NO_CONCLUSIVE_RUN"
  else
    CONCL="${out%%$'\t'*}"
    RUN_ID="${out##*$'\t'}"
    RUN_SHA="$(awk -F'\t' 'NF>=4{print $3} NF<4{print ""}' <<<"$out")"   # the row is concl\tupdated\tsha\tid
    updated="${out#*$'\t'}"; updated="${updated%%$'\t'*}"
    # ⚠ THE AGE COMES FROM THE RUN ACTUALLY USED. Taking `[0]`'s timestamp beside run N-1's
    # conclusion would print a fresher number describing a different run — the denominator swap, on
    # the time axis.
    if [[ -n "$updated" ]]; then
      then_s="$(date -d "$updated" +%s 2>/dev/null || echo '')"
      now_s="$(date +%s 2>/dev/null || echo '')"
      # ⚠ SECONDS FOR THE COMPARISON, a rounded string only for the message. Truncating to whole
      # hours here is what made the effective threshold 7h while the text said 6h.
      if [[ "$then_s" =~ ^[0-9]+$ && "$now_s" =~ ^[0-9]+$ ]]; then
        AGE_S="$(( now_s - then_s ))"
        AGE_H="$(awk -v s="$AGE_S" 'BEGIN{printf "%.1f", s/3600}')"
        # ⚠ MINUTES TOO, AND THAT IS NOT COSMETIC. This job runs on a SIXTY MINUTE cadence, so an
        # age expressed in hours to one decimal has no resolution where it matters: 82 minutes
        # prints as "1.4 hours ago" beside a threshold of 6 and reads as healthy. Measured
        # 2026-09-06 — the hourly waited 51.7 minutes for its seat and then ran 30, so the cycle
        # was 81.7 minutes against a 60 minute period, and the gate said "1.4 hours ago, fresh".
        AGE_M="$(awk -v s="$AGE_S" 'BEGIN{printf "%d", s/60}')"
      fi
    fi
  fi
else
  # ⚠ THE QUERY FAILING IS A FIRST-CLASS OUTCOME AND IS NOT A RED. Distinguishing it is the whole
  # point of this script.
  CONCL="QUERY_FAILED"
fi

# ⚠ ONLY ASK WHERE IT DIED WHEN THAT CAN CHANGE THE ANSWER. A second API call on every green would be
# latency on the happy path for information nobody uses — and it would put another way for this gate
# to fail in front of every PR, on a script whose entire purpose is not falling over when the API is
# unwell. The off-switch short-circuits first for the same reason.
if [[ "$OFF_SWITCH" != 1 && -n "$RUN_ID" ]]; then
  case "$CONCL" in
    # ⚠ `cancelled` JOINS THIS LIST SO THE DURATION CAN BE MEASURED. Without it no jobs call is made,
    # `JOB_DUR` stays empty, and a timeout is indistinguishable from a human cancel — which is how
    # four consecutive 45m17s timeouts proceeded as gaps on 2026-09-05. It costs one API call on a
    # conclusion that is rare, never on the happy path.
    failure|timed_out|startup_failure|action_required|cancelled)
      if jobs_json="$(gh api "repos/$REPO/actions/runs/$RUN_ID/jobs?per_page=100" 2>/dev/null)"; then
        WHERE="$(run_death_site "$jobs_json" "$JOB_NAME")"
        # ⚠ SAME PAYLOAD, NO SECOND CALL. These are the parts run_death_site computes and drops;
        # taking them here costs nothing and is the whole of
        # infra_the_merge_queue_block_message_throws_away_the_death_site_it_just_computed.
        DEAD_STEP="$(run_death_step "$jobs_json" "$JOB_NAME")"
        JOB_DUR="$(run_job_duration "$jobs_json" "$JOB_NAME")"
        # ⚠ SECONDS, NOT THE PRETTY STRING — see run_job_duration_s. The comparison below is
        # arithmetic and "45m 17s" is not a number; built on JOB_DUR it silently never fired.
        JOB_DUR_S="$(run_job_duration_s "$jobs_json" "$JOB_NAME")"
        # The stage report this run published as its "verify stages" check-run, matched by run id. One call,
        # only on a red. (infra_the_verify_stage_chain_hides_the_whole_browser_suite_behind_any_earlier_red)
        _rsha="$(jq -r '.jobs[0].head_sha // empty' <<<"$jobs_json" 2>/dev/null)"
        if [[ -n "$_rsha" ]]; then
          STAGE_REPORT="$(mktemp)"
          gh api "repos/$REPO/commits/$_rsha/check-runs?check_name=verify%20stages&per_page=20" \
            --jq ".check_runs[] | select(.external_id == \"$RUN_ID\") | .output.text" 2>/dev/null | head -8 > "$STAGE_REPORT" || true
        fi
      else
        WHERE="unknown"
      fi ;;
  esac
fi

# ── the repair lane: wait for the sibling job ───────────────────────────────────────────────────
# Sets REPAIR_RV (green-full | red | absent | running | unreadable) and REPAIR_NOTE. Called on the
# red-main escape path as before, AND — since the proof is required in every state of main — for any
# `repair-main` PR the escape path did not already read.
# ⚠ A FAILED QUERY RETRIES INSIDE THE WINDOW; it no longer reads as `absent` on the first miss, because
# `absent` is now a refusal and a flaky API call is not evidence the job never ran.
REPAIR_NOTE=""; REPAIR_RV=""
await_repair_verdict() {
  local _waited=0 _jobs
  REPAIR_RV="unreadable"
  while :; do
    if _jobs="$(gh api "repos/$REPO/actions/runs/$REPAIR_RUN_ID/jobs?per_page=100" 2>/dev/null)"; then
      REPAIR_RV="$(repair_job_verdict "$_jobs" "$REPAIR_JOB" "$REPAIR_PROOF_STEP")"
    else
      REPAIR_RV="unreadable"; printf 'repair lane: could not read the run'"'"'s jobs (query failed) — trying again\n'
    fi
    case "$REPAIR_RV" in
      green-full) REPAIR_NOTE="the repair job ran the FULL suite on the merged tree and its proof step passed"
                  printf 'repair lane: %s — that is the evidence.\n' "$REPAIR_NOTE"; return ;;
      red)        REPAIR_NOTE="the repair job is RED (or its proof step did not pass) — a red repair merges nothing"
                  printf 'repair lane: %s.\n' "$REPAIR_NOTE"; return ;;
      absent)     REPAIR_NOTE="no repair job in this run — the label was not on the PR when this run was created (add it, then push one commit so a synchronize event carries it)"
                  printf 'repair lane: %s.\n' "$REPAIR_NOTE"; return ;;
    esac
    # running, or the query failed: wait, within the window
    if (( _waited >= REPAIR_WAIT_S )); then
      if [[ "$REPAIR_RV" == unreadable ]]; then
        REPAIR_NOTE="the run's jobs could not be read for ${REPAIR_WAIT_S}s — the proof is unverified"
      else
        REPAIR_NOTE="the repair job had not concluded after ${REPAIR_WAIT_S}s — re-run this check once it has"
      fi
      printf 'repair lane: %s.\n' "$REPAIR_NOTE"; return
    fi
    sleep "$REPAIR_POLL_S"; _waited=$(( _waited + REPAIR_POLL_S ))
  done
}
if [[ "$OFF_SWITCH" != 1 && -z "$OWN_RESULT" && "$REPAIR_LABELLED" == 1 && -n "$REPAIR_RUN_ID" \
      && "$(queue_block_verdict "$CONCL" "$OFF_SWITCH" "$WHERE" "")" == block ]]; then
  printf 'repair lane: this PR carries `repair-main` and main is red — waiting for job %q in run %s (up to %ss)\n' \
    "$REPAIR_JOB" "$REPAIR_RUN_ID" "$REPAIR_WAIT_S"
  await_repair_verdict
  [[ "$REPAIR_RV" == green-full ]] && OWN_RESULT="green-full"
fi
# ⚠ AND IN EVERY OTHER STATE OF MAIN. The block above reads the repair job only as an escape; a green
# main has nothing to escape, so it used to never look. The label is a claim either way.
if [[ "$REPAIR_LABELLED" == 1 && -n "$REPAIR_RUN_ID" && -z "$REPAIR_RV" ]]; then
  printf 'repair lane: this PR carries `repair-main` — its own full suite must be green whatever state main is in; waiting for job %q in run %s (up to %ss)\n' \
    "$REPAIR_JOB" "$REPAIR_RUN_ID" "$REPAIR_WAIT_S"
  await_repair_verdict
fi

# ── DID THE JOB HIT ITS TIMEOUT? ────────────────────────────────────────────────────────────────
# ⚠ THE ANSWER IS CARRIED BY THE `TIMED_OUT_CANCEL` SENTINEL IN `$CONCL`, NOT BY A FIFTH ARGUMENT.
# There used to be a `HIT_LIMIT` variable here — computed from JOB_DUR_S and FULL_SUITE_TIMEOUT_MIN,
# passed as `$5`, and **consumed by nothing**: `queue_block_verdict` takes four parameters and never
# read a fifth. It was left over from the earlier design, superseded by the sentinel substitution
# above (the bounded walk over the leading run of cancelled entries), and the two computed the same
# fact twice with only one copy wired up.
#
# ⚠ IT WAS HARMLESS AND WORTH DELETING ANYWAY, WHICH IS THE WHOLE POINT. Functionally inert — bash
# ignores a surplus argument — but it read as the mechanism: a carefully commented "EVIDENCE, NOT
# INFERENCE" block feeding the verdict call. **A reader tracing how a timeout blocks the queue would
# have followed it and found nothing**, in the one script whose job is to be legible when everything
# else is unwell. Duplicate logic where one copy is dead is worse than no comment at all.
#
# The limit itself is still an INPUT, not a parse: ci.yml passes `FULL_SUITE_TIMEOUT_MIN` and
# `scripts/check-full-suite-timeout-agrees.sh` stops the two drifting. The `>=` comparison and the
# dispatched-job guard live with the sentinel walk, where they are actually read.
VERDICT="$(queue_block_verdict "$CONCL" "$OFF_SWITCH" "$WHERE" "$OWN_RESULT")"

# ── A repair-main PR THE RUN DISPROVED DOES NOT LAND ──────────────────────────────────────────────
# (infra_a_repair_main_pr_whose_own_full_suite_is_red_is_landed_anyway_because_only_verify_is_required)
# `block` already refuses (and already says why, with REPAIR_NOTE). Every other verdict — a green main,
# a gate that cannot tell, the owner's off-switch — used to let a labelled PR through on its subset.
# A labelled PR with no run id to read is refused too: the claim then cannot be checked at all.
if [[ "$REPAIR_LABELLED" == 1 && "$VERDICT" != block ]]; then
  [[ -n "$REPAIR_RUN_ID" ]] || { REPAIR_RV=""; REPAIR_NOTE="no run id was passed, so the repair job cannot be read"; }
  if [[ "$(repair_proof_verdict 1 "$REPAIR_RV")" == refused ]]; then
    printf '::error::REPAIR-MAIN PROOF MISSING — this PR carries `repair-main`, and its own job "%s" is not green (%s). The label claims this PR proves the full suite on the tree that will land; a claim the run did not bear out does not merge, whatever state main is in.\n' \
      "$REPAIR_JOB" "${REPAIR_NOTE:-verdict ${REPAIR_RV:-none}}"
    printf 'repair lane: REFUSED (%s). Fix the red spec on this branch, or remove the label if this is not a repair.\n' "${REPAIR_RV:-no verdict}"
    exit 1
  fi
fi

FRESH="$(staleness_note "$AGE_S" "$STALE_HOURS")"

# ⚠ CONFIRM A `stale` READING BEFORE BELIEVING IT — AND ONLY THEN, so the happy path pays nothing.
# A second API call on every green would be latency for information nobody uses, and another way for
# this gate to fail in front of every PR; the file already makes that argument for the death-site
# lookup and it applies unchanged here. We pay one call precisely when we are about to cry wolf.
#
# The question is narrow: is there any scheduled run NEWER than the one we measured, in ANY status?
# `yes` means the page we derived the age from was not current, or the hourly is running right now.
# Either way the schedule is alive. `unknown` means the confirmation itself could not be made.
NEWER="unknown"
NEWER_CONCL=""; NEWER_ID=""; NEWER_SHA=""; NEWER_CREATED=""
CADENCE=""
# ⚠ AND WHENEVER WE ARE ABOUT TO BLOCK, WHATEVER THE AGE SAYS. Blocking is the expensive verdict —
# it stops every merge in the repo — so it is exactly where this file's own rule ("only ask when it
# can change the answer", "we pay one call precisely when we are about to cry wolf") applies hardest.
# A behind page can also look FRESH: it is behind by whatever the API is behind by, and nothing says
# the omitted runs span more than the staleness threshold. Gating the confirmation on `stale` alone
# would leave the block path trusting page order on precisely the reading that costs the most.
# ⚠⚠ AND ON EVERY PROCEED TOO — the fresh-looking green is the case that let three merges through.
# This condition used to read `( FRESH == stale || VERDICT == block )`: "only ask when it can change
# the answer". A behind page whose green looked FRESH (< 6 h) was never asked, and it CAN change the
# answer: #9622 (16:19:58Z, "green 48 minutes ago, fresh"), #9498 (16:24:49Z, 53 min) and #9548
# (16:29:04Z, 57 min) all admitted after the 15:09Z hourly had concluded RED at ~16:09Z, with no
# repair PR open. One API call per gate run is the price of asking every time; a PR that merges onto
# a red main is the price of not asking. (fix_the_full_suite_gate_admits_a_merge_on_a_weeks_old_green_when_its_runs_page_is_behind)
if [[ "$VERDICT" =~ ^(proceed|block)$ && "$OFF_SWITCH" != 1 && -n "$updated" ]]; then
  # ⚠ CLASSIFY, DO NOT MERELY DETECT. Ask for status as well as time: a newer run that COMPLETED
  # means our page was behind; newer runs that are all queued/in_progress mean the suite is not
  # completing, which is an outage rather than freshness.
  # ⚠ AND ASK FOR THE CONCLUSION TOO — `status` alone cannot tell a run that finished with a verdict
  # from one killed at the wall, and both read `completed`. See newer_is_superseding.
  if newer_runs="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?event=schedule&branch=main&per_page=10" \
                    --jq '.workflow_runs[] | "\(.created_at // "")\t\(.status // "")\t\(.conclusion // "")\t\(.id // "")\t\(.head_sha // "")"' 2>/dev/null)"; then
    _b="$(date -d "$updated" +%s 2>/dev/null || echo '')"
    if [[ ! "$_b" =~ ^[0-9]+$ || "$newer_runs" != *[![:space:]]* ]]; then
      NEWER="unknown"          # nothing to compare against, or the query answered with nothing
    else
      _saw_newer=0; _saw_superseding=0; _epochs=(); _best_a=0
      while IFS=$'\t' read -r _created _status _concl _nid _nsha; do
        [[ -n "$_created" ]] || continue
        _a="$(date -d "$_created" +%s 2>/dev/null || echo '')"
        [[ "$_a" =~ ^[0-9]+$ ]] || continue
        _epochs+=("$_a")          # every creation seen, for the cadence — not only the newer ones
        (( _a > _b )) || continue
        _saw_newer=1
        if [[ "$(newer_is_superseding "$_status" "$_concl")" == yes ]]; then
          _saw_superseding=1
          # keep the NEWEST superseding run: it is main's latest word, and we judge on it below
          if (( _a > _best_a )); then _best_a=$_a; NEWER_CONCL="$_concl"; NEWER_ID="${_nid:-}"; NEWER_SHA="${_nsha:-}"; NEWER_CREATED="$_created"; fi
        fi
      done <<< "$newer_runs"
      CADENCE="$(creation_cadence "$(date +%s)" ${_epochs+"${_epochs[@]}"})"
      if   (( _saw_superseding )); then NEWER="completed"
      elif (( _saw_newer ));     then NEWER="pending"
      else                            NEWER="no"
      fi
    fi
  fi
fi
FRESH="$(staleness_verdict "$FRESH" "$NEWER")"

# ⚠ THE VERDICT, NOT ONLY THE MESSAGE. `staleness_verdict` above adjusts what we SAY about the age;
# this adjusts what we DO. They read the same evidence and only the first one used to exist, which
# is how a gate came to announce "the page was behind" on one path while blocking the whole repo on
# that same page on another.
# ⚠⚠ JUDGE ON THE NEWER RUN, NOT ON CANNOT-TELL. The verify job treats exit 2 as "proceed — a broken
# query must never halt the factory" (ci.yml, the step 'The full suite must not be red on main'), so
# a page proven behind that only said CANNOT TELL would still ADMIT the merge — which is exactly
# what #9672 and the three 16:2xZ merges did. But when the page is proven behind, the confirmation
# query above has already read the newer run's conclusion: that run IS main's latest word, and the
# gate judges on it — red blocks (exit 1), green admits naming it. CANNOT TELL is kept for the one
# case where the newer run's conclusion is unreadable.
# (fix_the_full_suite_gate_admits_a_merge_on_a_weeks_old_green_when_its_runs_page_is_behind)
if [[ "$NEWER" == completed && "$VERDICT" =~ ^(proceed|block)$ && -n "$NEWER_CONCL" ]]; then
  printf '::notice::full-suite gate: the runs page was BEHIND — its newest verdict (%s, run %s) is superseded by run %s @ %s (created %s), which concluded %s; judging on that run.\n' \
    "$CONCL" "${RUN_ID:-?}" "${NEWER_ID:-?}" "${NEWER_SHA:0:9}" "$NEWER_CREATED" "$NEWER_CONCL"
  CONCL="$NEWER_CONCL"; RUN_ID="$NEWER_ID"; RUN_SHA="$NEWER_SHA"
  if _n_s="$(date -d "$NEWER_CREATED" +%s 2>/dev/null)" && [[ "$_n_s" =~ ^[0-9]+$ ]]; then
    AGE_S="$(( $(date +%s) - _n_s ))"; AGE_H="$(awk -v s="$AGE_S" 'BEGIN{printf "%.1f", s/3600}')"; AGE_M="$(awk -v s="$AGE_S" 'BEGIN{printf "%d", s/60}')"
  fi
  # WHERE (the death site) of the newer red is unestablished here; `unknown` BLOCKS by this file's own
  # rule, which is the safe direction for a red we have not dissected.
  VERDICT="$(queue_block_verdict "$CONCL" "$OFF_SWITCH" "$([[ "$CONCL" == success ]] && printf 'n/a' || printf 'unknown')" "$OWN_RESULT")"
else
  VERDICT="$(blocking_currency "$VERDICT" "$NEWER")"
fi

case "$VERDICT" in
  block)
    # ⚠ THE BRANCH CLAUSE RIDES ON THIS FIRST LINE, NOT ON A SECOND ANNOTATION. This is the string
    # GitHub renders on the checks tab and in the PR summary; a second `::error::` would be a second
    # annotation the reader may never scroll to, and stdout is thousands of lines down inside the
    # log. **The order of the words is the feature**: the queue is blocked, and this branch is not
    # the reason. (infra_a_blocked_merge_queue_reports_every_waiting_pr_as_failed)
    printf '::error::THE MERGE QUEUE IS BLOCKED — main'"'"'s last full suite was %s. %s\n' "$CONCL" "$(blocked_branch_note "$CALLER")"
    # The exit, named where the reader is: a repair PR proves the suite itself and is admitted on
    # that evidence. Everything else waits for it. (docs/runbooks/main-is-red.md)
    if [[ -n "$REPAIR_NOTE" ]]; then
      printf '::notice::repair lane: %s.\n' "$REPAIR_NOTE"
    else
      printf 'THE WAY OUT IS A REPAIR, NOT A WAIT: whoever reads this first owns the red — docs/runbooks/main-is-red.md.\n'
      printf 'bash scripts/red-main-report.sh names the failing specs, the blame window and where to look first; the repair\n'
      printf 'PR is opened with `--label repair-main`, runs the FULL suite itself, and is admitted on that green.\n'
    fi
    # ⚠ NAME WHERE IT DIED ON EVERY ARM, NOT JUST `unknown`. The `unknown` arm below already argues
    # this in its own words — "the reader must be able to tell this verdict from one where the suite
    # demonstrably ran and failed, because only the second names a defect to fix" — and then only one
    # arm acted on it. `run_death_site` had the failing step in hand and discarded it.
    #
    # ⚠⚠ THE DURATION IS PRINTED BESIDE THE STEP BECAUSE THE STEP ALONE DOES NOT SEPARATE THE CASES.
    # Runs 32053471791 and 32586684979 have the SAME failing step name; one ran the suite for 23
    # minutes, the other died at 33 seconds in a ledger check having executed no specs. Without the
    # duration the reader still cannot tell "a spec is broken" from "verify.sh fell over before the
    # specs", and those need completely different work.
    death_site_line "$DEAD_STEP" "$JOB_DUR"
    gate_stage_lines "${STAGE_REPORT:-}"
    if [[ "$WHERE" == unknown ]]; then
      # ⚠ SAY THAT WE COULD NOT ESTABLISH IT. Blocking on `unknown` is deliberate — an unexplained
      # failure is most likely a real red — but the reader must be able to tell this verdict from one
      # where the suite demonstrably ran and failed, because only the second names a defect to fix.
      printf '::warning::could not establish WHERE that run died (job %q steps unavailable), so it is treated as a real red.\n' "$JOB_NAME"
      printf 'If it actually died at "Set up job", this block is spurious — check the run before hunting for a test failure.\n'
    fi
    # ⚠ "runs hourly" is fine HERE -- it names the schedule's intent, not a time you can act on.
    # "clears on its next hourly run" was NOT: that is a prediction, and the sibling of the line at
    # :188. Found by this ticket's own verification grep rather than by reading, which is the whole
    # argument for writing the check as a grep over the OUTPUT instead of "I fixed the line".
    # (docs_the_merge_queue_gate_tells_you_a_clock_time_it_cannot_know)
    printf 'The per-PR gate is a SUBSET; the full suite runs on a schedule against main and it is red.\n'
    printf 'Merging now would stack changes on top of a known-broken main.\n'
    printf 'Fix the full suite (or revert what broke it) and this clears on the next scheduled run.\n'
    printf '\n'
    # ⚠ SAY WHY THE AUTOMATIC ESCAPE DID NOT APPLY, AND NAME THE MANUAL LEVER IN THE SAME BREATH.
    # The bounded risk is the escape not firing — somebody flips the switch and we are back to the
    # old behaviour. The UNBOUNDED risk is false confidence: everyone believing recovery is
    # automatic, so nobody reaches for the lever, and main sits red for hours the way it did on
    # 2026-08-18. NOBODY GOES LOOKING FOR A LEVER THEY THINK IS AUTOMATIC. Written for someone
    # landing on a red PR who has never heard of this ticket. (Don's mitigation, 2026-08-19.)
    case "$OWN_RESULT" in
      green-full) : ;;   # unreachable: that verdict is proceed-on-own-evidence, not block
      '')
        printf 'WHY THE AUTOMATIC ESCAPE DID NOT APPLY HERE: it admits a PR that has proved a GREEN FULL\n'
        printf 'suite on the merged tree, and this run executed only the SUBSET — so it has proved nothing\n'
        printf 'about the specs the subset defers, and cannot be admitted on that evidence.\n'
        printf '\n'
        blocked_lane_advice "$LANE" ;;
      *)
        printf '⚠ MISCONFIGURATION, NOT A TEST RESULT: FULL_SUITE_OWN_RESULT is set to %q, which is not the\n' "$OWN_RESULT"
        printf 'token `green-full`. Only that exact value opens the escape (deliberately — a gate that opened\n'
        printf 'on any non-empty string is one refactor from opening always). Check the env block of the\n'
        printf 'gate step in .github/workflows/ci.yml; nothing a PR author writes should be reaching this.\n' ;;
    esac
    printf '\n'
    printf 'AND IF NEITHER APPLIES, THE MANUAL LEVER STILL EXISTS — it is not automatic, somebody has to\n'
    printf 'pull it. Emergency revert of the whole experiment, no PR needed: set the repo variable\n'
    printf '  FULL_SUITE_ON_EVERY_PR=1\n'
    printf '(then set it back to 0 once main is green, or every PR pays a full suite on one serialised seat.)\n'
    exit 1 ;;
  proceed-on-own-evidence)
    # ⚠ SAY WHAT IS ESTABLISHED AND WHAT IS NOT, AT THE MOMENT THE ESCAPE IS TAKEN. A PR merging
    # under this rule while main is red is fine; a PR merging under it with nobody able to tell
    # whether the net HELD or EVAPORATED is the silent-failure shape this repo has paid for
    # repeatedly. Both classes are named because this run cannot tell them apart — see the header.
    printf '::warning::full-suite gate: ESCAPE TAKEN — main'"'"'s last full suite was %s, but THIS run'"'"'s FULL suite on the merged tree was green.\n' "$CONCL"
    printf 'ESTABLISHED: the tree that will land passes the full suite. That is a newer and truer reading of\n'
    printf 'what main is about to become than main%s last completed run, which is why this merges.\n' "'s"
    printf '\n'
    printf '⚠ NOT ESTABLISHED: that this PR repairs main. Two failure classes reach this point and this run\n'
    printf 'cannot distinguish them — telling them apart needs main%s tip tested ALONE, which is the hourly:\n' "'s"
    printf '  (a) the breakage reproduces on merged trees  -> only a PR that genuinely fixes it can be green\n'
    printf '      here, so the net held and this PR is the repair.\n'
    printf '  (b) the breakage is MAIN-ONLY (e.g. one keyed on an empty origin/main..HEAD) -> it appears on\n'
    printf '      NO merged tree, EVERY PR goes green, every PR takes this escape, and the net is INERT\n'
    printf '      until main is repaired. That may well be the right outcome; it must not be an invisible one.\n'
    printf '\n'
    printf 'Countable marker for whoever is watching: FULL_SUITE_ESCAPE_TAKEN pr=%s main_concl=%s\n' "${GITHUB_REF_NAME:-?}" "$CONCL"
    printf 'If this marker appears on PR after PR, you are in case (b) and the safety net is absent, not working.\n'
    exit 0 ;;
  proceed)
    if [[ "$OFF_SWITCH" == 1 ]]; then
      printf 'full-suite gate: INERT (FULL_SUITE_ON_EVERY_PR=1) — every PR runs the full suite.\n'
    else
      # ⚠ NAME THE RUN AND THE SHA. The old line ended in the staleness word, and on #9672 that word
      # was "unknown" — a reader had no way to tell which run's green had just admitted a merge.
      printf 'full-suite gate: main'"'"'s last full suite was green (%s hours / %s minutes ago, %s) — admitted on run %s @ %s.\n' \
        "${AGE_H:-?}" "${AGE_M:-?}" "$FRESH" "${RUN_ID:-?}" "$(sha9)"
      # ⚠⚠ AN AGE WITHOUT A YARDSTICK IS NOT A REPORT. The gate already printed the age and that was
      # not enough: nothing said what the age SHOULD be, so a reader had no way to tell 1.4 hours
      # from healthy. The hourly's period is 60 minutes and it runs ~30, so in health the newest
      # verdict is at most ~90 minutes old. Past that the cadence has slipped and the queue is
      # admitting on evidence older than the schedule intends.
      #
      # ⚠ A NOTICE, NOT A BLOCK, AND DELIBERATELY SO. Blocking on a slipped cadence would stop the
      # queue for a CI capacity problem that the suite itself is not failing — the verdict is still
      # green, just older than intended. What was missing was VISIBILITY, and a gate that fails
      # toward fine while silent is the shape this file exists to prevent.
      # (infra_the_hourly_still_starves_on_canary_with_the_advisory_work_already_moved)
      if [[ "$AGE_S" =~ ^[0-9]+$ ]] && (( AGE_S > FULL_SUITE_EXPECTED_CYCLE_S )); then
        printf '::notice::the newest full-suite verdict is %s minutes old; the hourly cycle is ~%s minutes when healthy (60 period + ~30 run). The schedule has slipped — the queue is admitting on older evidence than intended.\n' \
          "$AGE_M" "$(( FULL_SUITE_EXPECTED_CYCLE_S / 60 ))"
      fi
      # ⚠ TWO REASONS TO WARN, AND THEY SEND THE READER SOMEWHERE DIFFERENT. "Nothing has been
      # scheduled" is a dead timer; "runs are being created but none completes" is a suite that no
      # longer finishes — the second is the state Vera measured and it would be misdiagnosed as the
      # first by a single message.
      if [[ "$FRESH" == stale && "$NEWER" == pending ]]; then
        # ⚠ "PRODUCED A VERDICT", NOT "COMPLETED" — Saffron's, and it is the word this whole ticket
        # is about. A run killed at its own wall IS `completed`; so is one superseded while pending.
        # A message saying "none has completed" is therefore false on its face during exactly the
        # outage it is reporting, and it teaches the next reader the conflation that caused the bug.
        printf '::warning::the last full suite to produce a VERDICT is %sh old (threshold %sh) — scheduled runs ARE being created but none has produced a verdict since (%s; an hourly cron would give a median gap of 1.00h). ⚠ Runs HAVE concluded in that window: a run killed at its own timeout, or superseded before it ran, concludes `cancelled` and is `status: completed` while judging nothing. The suite is not finishing, which is NOT the same as the timer being dead, and this line is NOT a claim that creation is healthy.\n' \
          "$AGE_H" "$STALE_HOURS" "${CADENCE:-cadence unknown}"
      elif [[ "$FRESH" == stale ]]; then
        printf '::warning::the last full suite is %sh old (threshold %sh) — the hourly job may not be running.\n' "$AGE_H" "$STALE_HOURS"
      fi
      # ⚠ NOT SILENCE. An age past the threshold that could NOT be confirmed says so, because the
      # alternative to crying wolf is not saying nothing — it is saying which of the two you have.
      [[ "$FRESH" == unknown && "$AGE_S" =~ ^[0-9]+$ && "$AGE_S" -gt "$(( STALE_HOURS * 3600 ))" ]] && \
        printf 'full-suite gate: the newest COMPLETED scheduled run in our page is %sh old (threshold %sh), but a NEWER run has completed since or the check could not be made (newer=%s) — the page was behind, so this is NOT reported as stale. See infra_the_full_suite_gate_intermittently_reports_a_fresh_suite_as_stale.\n' \
          "$AGE_H" "$STALE_HOURS" "$NEWER"
    fi
    exit 0 ;;
  cannot-tell-behind)
    # ⚠ UNKNOWN, AND SAID OUT LOUD. This is not "main is green" and it must never read as one.
    printf '::warning::full-suite gate CANNOT TELL — the runs page we read was BEHIND, so its verdict is void.\n'
    printf 'The newest COMPLETED scheduled run in our page concluded %q (%sh ago, run %s @ %s), but a NEWER scheduled run\n' "$CONCL" "${AGE_H:-?}" "${RUN_ID:-?}" "$(sha9)"
    printf 'has COMPLETED since — and a current page, sorted newest-first, could not have omitted it. So the\n'
    printf 'run we judged is not main'"'"'s latest word, and blocking on it would stop every merge in the repo on\n'
    printf 'an artefact of API paging rather than on a test result.\n'
    printf '\n'
    printf '⚠ THIS IS NOT A CLAIM THAT MAIN IS GREEN. The safety net is ABSENT for this tick, which is a gap,\n'
    printf 'not a verdict — the same status as a failed query. If main really is red, the next tick reads a\n'
    printf 'current page and blocks properly; if this repeats, the paging problem is the thing to fix.\n'
    printf 'See infra_the_full_suite_gate_returns_a_wrong_exit_code_when_the_runs_page_is_behind.\n'
    # 2 = "could not look", the same code as a failed query, and for the same reason: the callers can
    # tell it from both 0 and 1 (ci.yml falls through to force_full=0; pr-refresh.sh answers
    # `unknown`, not `cleared`). Exit 1 here would be the bug this arm exists to remove; exit 0 would
    # publish an unestablished state as an established one.
    exit 2 ;;
  *)
    # ⚠ LOUD, AND STILL PROCEEDING. Silence here would make an absent safety net indistinguishable
    # from a working one — which is the defect this whole ticket family is about.
    if [[ "$WHERE" == setup ]]; then
      printf '::warning::full-suite gate CANNOT TELL — main'"'"'s last full suite concluded %q but died at SETUP, so it never ran a spec.\n' "$CONCL"
      printf 'That is infrastructure (a runner that did not come up, codeload refusing actions/checkout), not a test result.\n'
      printf 'Proceeding: the safety net is ABSENT for this tick, which is a gap, not a verdict.\n'
    else
    printf '::warning::full-suite gate CANNOT TELL (conclusion=%q) — proceeding, because a broken query must never halt the factory.\n' "$CONCL"
    fi
    printf 'If this persists, the safety net is absent while every PR merges normally. That is its own alarm.\n'
    # ⚠ 2, NOT 0, AND THE DIFFERENCE IS THE WHOLE TICKET.
    # (fix_the_full_suite_gate_cannot_say_cannot_tell)
    #
    # This arm used to `exit 0` — the same code as "main's last full suite was GREEN". That made ONE
    # exit code carry TWO consequences, and only one of them was ever decided:
    #   · DESIGNED, and still true below: the factory does not halt because an API call failed.
    #   · ACCIDENTAL: ci.yml:361 reads exit 0 as `force_full=0`, so a failed query also SILENTLY
    #     withheld the full-suite promotion — the escape a PR is entitled to when main is red, whose
    #     green result is what admits it. Nobody chose that; it fell out of sharing a code.
    #
    # ⚠ EXIT 1 WOULD BE THE WRONG FIX AND IS THE OBVIOUS ONE. It restores the escape and halts the
    # factory whenever the API is unwell — the self-inflicted outage this arm exists to prevent.
    # The answer is a code the callers can TELL APART, so each decides for itself.
    #
    # 2 is not invented here: `exit 2` already means "could not look" across this repo's check
    # scripts (check-checkout-lag.sh, check-git-hooks.sh, check-prod-csp-vhosts.sh and others).
    #
    # ⚠ AND THE CONSUMER SIDE WAS ALREADY BUILT FOR THIS. pr-refresh.sh:756 has read the gate three
    # ways — cleared / blocked / unknown — since it was written, but the gate only ever emitted 0 or
    # 1, so `unknown` was unreachable from the verdict and had never executed. This line is what
    # makes that branch live. Its behaviour there is `unknown`, which is what it should always have
    # been.
    exit 2 ;;
esac
