#!/usr/bin/env bash
# scripts/lib/gh-checks.sh — "is this SHA's required check running, red, or neither?"
#
# Shared by scripts/pr-refresh.sh and scripts/merge-batch.sh. It lives here because
# both need the SAME answer to the same question, and two copies of this would drift
# — specifically on the `cancelled` case below, which is the one that is easy to get
# wrong and expensive when it is.
#
# Callers must set GH_REPO and CHECK_NAME before sourcing, or pass them in.

# gh_verify_state <head-sha> [repo] [check-name]
#   in_flight     the required check is queued or running
#   failure       it ran, reached a verdict, and the verdict was red
#   indeterminate it died mid-gate — NOTHING was ever judged (see below)
#   ready         green, never ran, or CANCELLED
#
# ⚠ CANCELLED IS `ready`, EMPHATICALLY. Every superseded run ends cancelled — it is
# the signature of the refresh/batch churn these scripts exist to reduce, not of a
# broken PR. Reading it as a failure makes both callers step over precisely the PRs
# they exist to land, and the queue sits idle with work waiting.
#
# A SHA we cannot ask about (empty, or gh unreachable) is `ready`: the worst case is
# one redundant action, whereas guessing `in_flight` stalls everything on a blip.
# ⚠ THE VERDICT COMES FROM THE LATEST *CONCLUSIVE* RUN, NOT THE LATEST RUN.
# (fix_cancelled_run_hides_a_red_verify) This was `sort_by(.started_at) | last`, and
# that one word `last` cost a seven-PR batch:
#
#   1. #4557's own verify FAILS.
#   2. The batcher absorbs it into a batch and CANCELS its own run — correct, the
#      batch covers it.
#   3. The latest run at that SHA is now `cancelled`, which classifies as `ready`.
#   4. #4557 reads as HEALTHY, joins the next batch, and reddens that one too.
#   5. Go to 2. It ran all day on 2026-08-07.
#
# The guard that keeps a known-red PR out of batches was defeated by the batcher's own
# housekeeping.
#
# ⚠ AND THE OBVIOUS FIX IS STILL WRONG — see the note above, which stands. Counting
# `cancelled` as a failure would make both callers step over precisely the PRs they
# exist to land. The distinction: a cancellation is the ABSENCE OF EVIDENCE, not
# evidence of health. It must not ERASE a failure already on the record, and it must
# not CREATE one either. A SHA whose only runs are cancelled is `ready`, as before.
#
# ⚠ AND THERE IS A THIRD STATE, BECAUSE JOB-LEVEL CONCLUSIONS CANNOT EXPRESS IT.
# (fix_batcher_bisects_a_batch_a_power_cut_reddened) The box lost power at 13:02 on
# 2026-08-08, mid-gate, on batch #4765. The artefact — run 31258422816, ATTEMPT 1:
#
#     JOB verify                                        completed  FAILURE
#        step Set up job                                           success
#        step Run actions/checkout@v5                              success
#        step Create dev .env                                      success
#        step The full house gate — bash scripts/verify.sh         CANCELLED
#        step Upload / Dump / Reap / Teardown                      skipped
#
# The gate was killed at 3m49s of a ~12m run, so verify.sh never returned an exit code
# and NOTHING WAS EVER JUDGED. But the JOB rolls that up to `failure`, this function
# read the job, and the batcher was told `failure` — so it closed a batch of four good
# PRs and bisected it. No PR was bad. The queue paid ~36 minutes for a power cut.
#
# ⚠ THE `cancelled` GUARD ABOVE DOES NOT COVER THIS, and the near-miss is what makes it
# invisible. There the RUN is cancelled; here the RUN and the JOB are `failure` and only
# the STEP is cancelled. Job-level conclusions alone CANNOT tell the two apart — the
# distinguishing evidence is one level down, in the steps.
#
# THE RULE: a job that concluded `failure` in which NO STEP EVER CONCLUDED `failure` is
# `indeterminate` — the box died holding the gate, and nothing was decided. Stated that
# way it is independent of step NAMES (which get renamed) and of which step died.
#   * a genuine red has the gate step `completed/failure`      -> judged   -> `failure`
#   * a killed run has it `completed/cancelled`, rest `skipped` -> unjudged -> `indeterminate`
#
# ⚠ ONLY `failure` GETS THIS TREATMENT — NOT `timed_out`. A job that burned its 45 minutes
# WAS given a verdict: it was asked to finish and did not. That is attributable to the tree
# (a hanging test) as readily as to the box, and it stays a hard failure. Every mechanism
# the ticket names — OOM kill, docker engine restart under the job, dropped network, an
# operator cancelling by hand — produces job `failure`, so the narrow rule covers them all.
#
# ⚠ READING THE ARTEFACT BACK LATER: `commits/<sha>/check-runs` and `runs/<id>/jobs` serve
# ONLY THE LATEST ATTEMPT. Run 31258422816 was re-run at 13:20:58, so today both endpoints
# report it `cancelled` and the evidence above looks fabricated. It is not — it is on
# `runs/31258422816/attempts/1/jobs`. Anyone re-deriving this must ask for the attempt
# explicitly or they will conclude the opposite of the truth. (Live callers are unaffected:
# they read the current attempt, which is the one the merge decision is actually about.)
#
# THE CLASSIFIER BELOW IS NOW THE PURE FUNCTION ITSELF, not a jq twin of it. The old header
# said "the jq is what runs, this is what is asserted" — two implementations of one rule,
# which is the drift this file exists to prevent. The API call now only FETCHES; every
# decision is gh_classify_history, so the self-test exercises the code that ships.
gh_verify_state() {
  local sha="$1" repo="${2:-${GH_REPO:-}}" check="${3:-${CHECK_NAME:-verify}}"
  local -a args
  mapfile -t args < <(_gh_history_args "$sha" "$repo" "$check")
  (( ${#args[@]} )) || { printf 'ready\n'; return 0; }
  gh_classify_history "${args[@]}"
}

# gh_verify_attempt <head-sha> [repo] [check-name] -> integer (0 if there is no run)
#   Which ATTEMPT the SHA's current check-run is. This is what BOUNDS the batcher's
#   re-run, and it is deliberately not a state file: GitHub already counts for us.
#
# ⚠ AND IT MUST BE THE ATTEMPT, NOT A COUNT OF CHECK-RUNS AT THE SHA. A re-run REPLACES
# the check-run rather than adding one — measured on 185ecdf28: after attempt 2, the
# attempt-1 job (93105359070) is simply not in `commits/<sha>/check-runs` any more, and
# exactly one row is returned. A counter built on that history can therefore never reach
# two, so the bound would never fire and an unhealthy box would re-run for ever — the
# precise failure the ticket says to assert against.
#
# A new SHA starts at attempt 1, so a refresh or a re-cut resets the budget by
# construction, which is right: that is a different tree and it deserves its own chance.
gh_verify_attempt() {
  local sha="$1" repo="${2:-${GH_REPO:-}}" check="${3:-${CHECK_NAME:-verify}}" id n
  [[ -n "$sha" && -n "$repo" ]] || { printf '0\n'; return 0; }
  id="$(gh api "repos/$repo/commits/$sha/check-runs?check_name=$check" \
          --jq '[.check_runs[]] | sort_by(.started_at) | last | .id // empty' 2>/dev/null)" || id=''
  [[ -n "$id" ]] || { printf '0\n'; return 0; }
  n="$(gh api "repos/$repo/actions/jobs/$id" --jq '.run_attempt // empty' 2>/dev/null)" || n=''
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

# gh_verify_run_id <head-sha> [repo] [check-name] -> the Actions run id, or empty
#   What `gh run rerun` needs. Resolved through the check-run's job rather than through
#   `gh run list --commit`, so it is by construction THE SAME RUN the verdict came from —
#   a second lookup by SHA can pick a different workflow's run and re-run the wrong thing.
gh_verify_run_id() {
  local sha="$1" repo="${2:-${GH_REPO:-}}" check="${3:-${CHECK_NAME:-verify}}" id
  [[ -n "$sha" && -n "$repo" ]] || return 0
  id="$(gh api "repos/$repo/commits/$sha/check-runs?check_name=$check" \
          --jq '[.check_runs[]] | sort_by(.started_at) | last | .id // empty' 2>/dev/null)" || return 0
  [[ -n "$id" ]] || return 0
  gh api "repos/$repo/actions/jobs/$id" --jq '.run_id // empty' 2>/dev/null || true
}

# gh_rerun_verdict <attempt> [max-attempts] -> rerun | give_up   (pure, self-tested)
#   ⚠ THE BOUND IS THE POINT. A batch that dies mid-gate TWICE on the same tree is a box
#   that cannot hold a verify, not a batch worth retrying a third time. Past the budget
#   the caller falls back to its ordinary red path, so one bad box costs a bisect rather
#   than becoming a permanent queue that never converges and never alerts.
#   ⚠ AND AN UNKNOWN ATTEMPT IS `give_up`, NOT `rerun`. gh_verify_attempt returns 0 when
#   the API cannot be read, and 0 < max would re-run on EVERY tick for ever — an
#   unbounded retry built out of the very guard meant to bound it. Failing closed costs
#   at worst one bisect of a batch that would have been re-run, which is today's
#   behaviour; failing open costs the queue.
gh_rerun_verdict() {
  local attempt="${1:-0}" max="${2:-${GH_MAX_VERIFY_ATTEMPTS:-2}}"
  [[ "$attempt" =~ ^[0-9]+$ ]] || attempt=0
  [[ "$max" =~ ^[0-9]+$ ]] || max=2
  (( attempt >= 1 && attempt < max )) && printf 'rerun\n' || printf 'give_up\n'
}

# ── the fetch half: check-runs -> "status:conclusion:judged" args, oldest first ──
# Judged-ness costs one extra API call PER FAILED run, and only for failed runs — a green
# or in-flight history makes no extra call at all, which is every ordinary tick.
_gh_history_args() {
  local sha="$1" repo="$2" check="$3" rows st cn id
  [[ -n "$sha" && -n "$repo" ]] || return 0
  rows="$(gh api "repos/$repo/commits/$sha/check-runs?check_name=$check" \
            --jq '[.check_runs[]] | sort_by(.started_at)[]
                  | "\(.status)\t\(.conclusion // "")\t\(.id)"' 2>/dev/null)" || return 0
  while IFS=$'\t' read -r st cn id; do
    [[ -n "$st" ]] || continue
    printf '%s:%s:%s\n' "$st" "$cn" "$(_gh_job_judged "$repo" "$st" "$cn" "$id")"
  done <<< "$rows"
}

# _gh_job_judged <repo> <status> <conclusion> <check-run-id> -> judged|unjudged
# A check-run's id IS the Actions job id, so its steps are one call away (verified against
# job 93105359070). ⚠ AN UNREADABLE JOB IS `judged`: that is today's behaviour, and the safe
# default. Guessing `unjudged` on an API blip would re-run a genuinely red batch instead of
# bisecting it — turning a transient into wasted verifies on the one runner this repo has.
#
# ⚠ THE RULE ITSELF NOW LIVES IN gh_failure_reason AND THIS ONLY FETCHES FOR IT. There were two
# implementations of "did anything actually fail in there" — this one, and the agent-facing
# classifier below — which is the drift this file's header already warns about for the jq twin.
# One rule, two callers, one self-test.
#
# ⚠ NO ANNOTATION IS FETCHED HERE, ON PURPOSE. The merge decision treats `lost-runner` and
# `unjudged` identically (both are "nothing was decided, re-run it"), so the extra API call per
# red run would buy the batcher nothing on its hot path. The agent-facing caller pays for it
# because IT is the one that has to name the cause out loud.
_gh_job_judged() {
  local repo="$1" status="$2" concl="$3" id="$4"
  local -a steps=()
  [[ "$status" == completed && "$concl" == failure && -n "$id" ]] || { printf 'judged\n'; return 0; }
  mapfile -t steps < <(gh api "repos/$repo/actions/jobs/$id" --jq '.steps[]?.conclusion' 2>/dev/null) \
    || { printf 'judged\n'; return 0; }
  # No steps at all is not evidence of a killed gate — treat it as judged.
  (( ${#steps[@]} )) || { printf 'judged\n'; return 0; }
  case "$(gh_failure_reason failure '' "${steps[@]}")" in
    lost-runner|unjudged) printf 'unjudged\n' ;;
    *)                    printf 'judged\n' ;;
  esac
}

# ── WHY a job failed: the BOX, or your DIFF? ─────────────────────────────────
# (infra_a_lost_runner_reads_as_a_failed_verify)
#
# Everything above answers "may this SHA merge". This answers a different question the same
# artefacts happen to contain, and that every AGENT-FACING surface needs: when the check went red,
# was it the tree or the box? The batcher does not care — an unjudged run is re-run either way —
# but a red that says nothing gets read as "my change broke the build" and buys an investigation.
# On 2026-08-12 four hard power cuts produced six red crosses, not one of which was a code defect,
# and each had to be diagnosed by hand by intersecting job timestamps with `journalctl --list-boots`.
#
# gh_failure_reason <job-conclusion> <annotation-text> [<step-conclusion>…] — PURE
#   red          a step reached a `failure` verdict — something WAS judged, and it lost. READ IT.
#   lost-runner  the runner vanished: GitHub says so in its own words, or no step ever reached
#                a verdict at all
#   unjudged     the job failed with nothing in it having failed — the box died holding the gate
#   cancelled    superseded by a push, cancelled by hand, or absorbed into a batch
#   ok           not a failure
#
# ⚠ IT FAILS TOWARD `red` IN EVERY BRANCH, AND THAT DIRECTION IS THE WHOLE SAFETY ARGUMENT.
# Mislabelling a genuine test failure as "infrastructure" tells an agent to ignore a real bug
# report — strictly worse than the defect being fixed here, because today's cost is a wasted
# investigation and that cost is a shipped defect. So an unreadable annotation, an unrecognised
# conclusion, and a job with no steps at all are all `red`, which is exactly today's behaviour.
# A failure only ever leaves `red` on POSITIVE evidence.
#
# ⚠ THE STEP CHECK OUTRANKS THE ANNOTATION, not the other way round. If a step reached `failure`
# the tree was judged and lost, whatever happened to the runner afterwards — and that ordering is
# what keeps the failure direction safe rather than merely stated.
#
# ⚠ "NO VERDICT" IS SPELLED TWO WAYS ON THE SAME STEPS AND BOTH ARE ACCEPTED. `null` through
# `gh api …/runs/<id>/jobs`, the empty string through `gh run view <id> --json jobs` — measured on
# the fixture, both captured in scripts/testdata/ci-runs/. A classifier that handles one passes its
# tests against that source and mislabels against the other, silently, in the direction that says
# "your diff is broken". An earlier version of this ticket asserted a signature that did not exist
# for precisely this reason: a filter that was correct against REST, pointed at the CLI.
# ── ⚠ THE SIXTH VERDICT: A RED THAT IS NOT ABOUT THIS PR AT ALL ─────────────────────────────────
# (fix_a_queue_block_red_is_reported_as_your_diff_being_broken)
#
# ci.yml's "The full suite must not be red on main" step fails a PR because **main's** hourly full
# suite is red. It runs AFTER the full house gate and BEFORE the merge, so a PR stopped there has
# **passed its own suite** and is being held on a fact about somebody else's commit. Reported as
# `red` — "the required check FAILED, the cause is in a comment on the PR" — it sends its owner to
# read a failure in their own diff that does not exist, which is where they will look first and
# longest. Same argument as `lost-runner` one class along, and the header's rule that check-infra
# must never be folded into check-red applies here word for word.
#
# ⚠ AND IT STILL FAILS TOWARD `red`. `queue-blocked` requires POSITIVE evidence: exactly one failing
# step, and that step named as the queue block. A run that died at the block AND anywhere else is
# `red` — the other failure is a real bug report and hiding it behind "main was red" is the
# expensive direction this whole file is built to avoid.
# ── ⚠ THE STEP -> MEANING TABLE. ONE DEFINITION, REPO-WIDE. ─────────────────────────────────────
# (infra_the_step_to_meaning_table_has_two_copies_both_mine)
#
# Which failing step name means what was encoded TWICE, in this file and in pr-refresh.sh, and both
# copies were written on the same day by the same agent — neither PR was wrong on its own, the PAIR
# was. That is the shape worth remembering: each half was the ONLY copy when it was written, so no
# single diff review could have caught it. The file's own header already said "if you ever add one
# back, SOURCE THIS LIBRARY — do not write a local copy", and the copy was written below that line
# because at the time there was nothing here to source.
#
# ⚠ AND BOTH COPIES FAILED SILENTLY, IN THE REASSURING DIRECTION. Reword the ci.yml step and one of
# them stops matching: pr-refresh stops re-queueing PRs whose block has cleared, and my-stuck-prs
# goes back to telling agents their own diff is broken. Neither reds anything. A third encoding of
# these same names lives in check-verify-routing.sh, and it is DIFFERENT in exactly the way that
# matters — it fails LOUDLY — which is why it is wired to this table rather than left alone.
#
# Matched as SUBSTRINGS of the step name, so a step can be reworded around them without silently
# disabling anything. The ci.yml steps today (job `verify`, in order) are:
#     3  "Let an already-won PR settle before merging main"
#     4  "Merge the PR's base branch into this branch, or stop"   <- base merge
#     7  "The full house gate — bash scripts/verify.sh"
#     8  "The full suite must not be red on main"                 <- queue block
#     9  "Merge — the pipeline lands its own PR"                  <- the LANDING, a different step
#
# ⚠ NOTE THE LAST TWO. "Merge the PR" and "Merge —" name DIFFERENT steps, and only the first is a
# conflict site. The landing step does not contain the substring "Merge the PR", which is what keeps
# the base-merge needle from matching it — checked, not assumed.
GH_STEP_BASE_MERGE="${GH_STEP_BASE_MERGE:-Merge the PR}"
GH_STEP_QUEUE_BLOCK="${GH_STEP_QUEUE_BLOCK:-full suite must not be red}"

# gh_step_site <step name> -> base-merge | queue-block | other                              (pure)
#
# ⚠ THIS ANSWERS "WHERE DID IT DIE", AND NOTHING ELSE. It deliberately does NOT answer "is this
# retryable" or "is this about the diff" — those are two different questions with two different
# safety arguments, asked by two different callers, and folding them into one verdict would give one
# caller the other's argument. pr-refresh's is load-bearing: a retry that can reach a genuine test
# failure is the retries/PW_WORKERS/timeout family wearing a different hat.
#
# So the TABLE is shared and the VERDICTS are not. That is the whole design.
#
# ⚠ AND IT ANSWERS ONLY ABOUT **OUR** STEPS. "Did the run die inside GitHub's own harness — set-up,
# checkout, container init — rather than in anything we wrote?" is a DIFFERENT question with a
# different table, and this function says `other` to every one of those. The two are complementary
# and share no strings, but they are adjacent enough to be reached for interchangeably, so:
#
#   · a queue-block death is `queue-block` here and NOT a harness death there — both correct, and
#     they will disagree about the same run. Neither is wrong; they were asked different things.
#   · if you are adding a row, the question "which of OUR ci.yml steps is this" belongs HERE. The
#     question "was this us at all" does not.
#
# Found by composing this change against a concurrent one that added the other classifier to this
# same file — two branches, both green, and the trap visible only in their union.
gh_step_site() {
  local name="${1-}"
  [[ -n "$name" ]] || { printf 'other\n'; return 0; }
  case "$name" in
    *"$GH_STEP_BASE_MERGE"*)  printf 'base-merge\n' ; return 0 ;;
    *"$GH_STEP_QUEUE_BLOCK"*) printf 'queue-block\n'; return 0 ;;
  esac
  printf 'other\n'
}

gh_failure_reason() {
  local concl="${1-}" annotations="${2-}" s failed=0 noverdict=0 steps=0
  local tok name failed_name='' named=0
  if (( $# > 2 )); then shift 2; else set --; fi
  case "$concl" in
    ''|success|skipped|neutral) printf 'ok\n'; return 0 ;;
    cancelled)                  printf 'cancelled\n'; return 0 ;;
    failure)                    ;;
    # ⚠ timed_out and action_required are VERDICTS in their own right — see the header. A job that
    # burned its 45 minutes was asked to finish and did not, which is attributable to a hanging
    # test as readily as to the box.
    *)                          printf 'red\n'; return 0 ;;
  esac
  for tok in "$@"; do
    # ⚠ A STEP MAY ARRIVE AS `<name>:<conclusion>` OR AS A BARE CONCLUSION, and both must keep
    # working. Every caller written before step names existed passes bare conclusions, and this is
    # ONE implementation on purpose — a second name-aware classifier beside this one is exactly the
    # drift this file's header warns about, and it has already happened here once.
    # Split on the LAST colon: a conclusion never contains one, a step name may.
    if [[ "$tok" == *:* ]]; then name="${tok%:*}"; s="${tok##*:}"; named=1
    else name=''; s="$tok"; fi
    steps=$(( steps + 1 ))
    case "$s" in
      failure)   failed=$(( failed + 1 )); failed_name="$name" ;;
      ''|null)   noverdict=$(( noverdict + 1 )) ;;
    esac
  done
  # ⚠ EXACTLY ONE FAILING STEP, AND IT MUST BE THE BLOCK. Checked before the generic red below,
  # and narrowed to the sole-failure case so a genuine test red can never be relabelled.
  if (( named == 1 && failed == 1 )) && [[ -n "$failed_name" ]] \
     && [[ "$(gh_step_site "$failed_name")" == "queue-block" ]]; then
    printf 'queue-blocked\n'; return 0
  fi
  # ⚠ THE OTHER DEATH SITE THE TABLE ALREADY KNEW ABOUT, AND HAD NO VERDICT FOR.
  # ci.yml's step 4 merges the PR's base branch into the branch and STOPS IN SECONDS when that
  # conflicts. It has judged NOTHING about the diff. Reported as `red` — "the required check
  # FAILED, the cause is in a comment on the PR" — it sends the owner to read a test failure in
  # their own code that does not exist, which is where they will look first and longest.
  # Live specimen: run 32240319460 (PR #5985), diagnosed by hand at the time.
  # (fix_a_branch_needing_a_rebase_classifies_as_a_broken_diff)
  #
  # ⚠ SAME POSITIVE-EVIDENCE RULE AS `queue-blocked`, NOT A WEAKER ONE: exactly one failing step,
  # and that step named as the base merge. A run that died at the merge AND anywhere else is `red`,
  # because the other failure is a genuine bug report and hiding it behind "you need a rebase" is
  # the expensive direction this whole file is built to avoid.
  if (( named == 1 && failed == 1 )) && [[ -n "$failed_name" ]] \
     && [[ "$(gh_step_site "$failed_name")" == "base-merge" ]]; then
    printf 'needs-rebase\n'; return 0
  fi
  (( failed > 0 )) && { printf 'red\n'; return 0; }
  case "$annotations" in
    *"lost communication with the server"*) printf 'lost-runner\n'; return 0 ;;
  esac
  # A job with no steps at all is not evidence of anything — stay where we are.
  (( steps == 0 )) && { printf 'red\n'; return 0; }
  # The shape, for when the annotation could not be read: steps that never reached a verdict mean
  # the runner went away mid-job rather than the job being stopped.
  (( noverdict > 0 )) && { printf 'lost-runner\n'; return 0; }
  printf 'unjudged\n'
}

# gh_job_failure_reason <repo> <job-id> -> the same five verdicts, fetched.
# Two calls, and ONLY ever for a job already known to have failed. ⚠ Fails soft to `red`, in
# keeping with the direction argued above: an agent told "read the failure" about an infrastructure
# death loses a few minutes, an agent told "infrastructure" about a real red ships the bug.
gh_job_failure_reason() {
  local repo="$1" id="$2" job concl ann
  local -a steps=()
  [[ -n "$repo" && -n "$id" ]] || { printf 'red\n'; return 0; }
  job="$(gh api "repos/$repo/actions/jobs/$id" 2>/dev/null)" || { printf 'red\n'; return 0; }
  [[ -n "$job" ]] || { printf 'red\n'; return 0; }
  concl="$(printf '%s' "$job" | jq -r '.conclusion // ""' 2>/dev/null)" || concl=''
  # ⚠ NAME AND CONCLUSION, not the conclusion alone — the classifier needs the name to tell a
  # queue block from a test failure, and this is the only caller that already holds the whole job.
  mapfile -t steps < <(printf '%s' "$job" | jq -r '.steps[]? | "\(.name // ""):\(.conclusion // "")"' 2>/dev/null)
  ann="$(gh api "repos/$repo/check-runs/$id/annotations" --jq '[.[].message] | join(" ")' 2>/dev/null)" || ann=''
  gh_failure_reason "$concl" "$ann" "${steps[@]}"
}

# ── the history rule — PURE, and now the code that actually runs ─────────────
# gh_classify_history <"status:conclusion[:judged|unjudged]" …>  — oldest first, as the
# API returns them sorted by started_at. The third field is OPTIONAL and defaults to
# `judged`, so every caller and every case written before indeterminate existed keeps
# its exact meaning.
# ⚠ AN UNJUDGED RUN IS THE ABSENCE OF EVIDENCE — EXACTLY LIKE A CANCELLATION, and it
# gets the same two-sided treatment the header demands of one. It must not CREATE a
# failure (that was the bug: four good PRs bisected), and it must not ERASE one either.
# So it is tracked SEPARATELY from the standing verdict rather than replacing it: a red
# tree whose re-run dies with the box is still red, because the box dying taught us
# nothing about the tree. Only when no judged failure stands does `indeterminate` win.
gh_classify_history() {
  local newest_status judged_concl='' newest_unjudged=0 arg s c j rest
  (( $# == 0 )) && { printf 'ready\n'; return 0; }
  for arg in "$@"; do
    s="${arg%%:*}"; rest="${arg#*:}"; [[ "$rest" == "$arg" ]] && rest=''
    c="${rest%%:*}"; j="${rest#*:}"
    # No third field (or an empty one) means judged — the pre-indeterminate meaning.
    { [[ "$j" == "$c" ]] || [[ -z "$j" ]]; } && j=judged
    newest_status="$s"
    # Step over the inconclusive ones — they neither prove health nor prove failure.
    [[ "$s" == completed && "$c" != cancelled && "$c" != skipped ]] || continue
    # ⚠ ONLY `failure` CAN BE UNJUDGED — timed_out and action_required are verdicts in
    # their own right (see the header), so they fall through and become the standing one.
    if [[ "$c" == failure && "$j" == unjudged ]]; then
      newest_unjudged=1
    else
      judged_concl="$c"; newest_unjudged=0
    fi
  done
  [[ "$newest_status" != completed ]] && { printf 'in_flight\n'; return 0; }
  case "$judged_concl" in
    failure|timed_out|action_required) printf 'failure\n' ;;
    *) (( newest_unjudged )) && printf 'indeterminate\n' || printf 'ready\n' ;;
  esac
}

# ── the pure half, so both callers can self-test without the network ─────────
# gh_classify_check <status> <conclusion> — the decision alone.
gh_classify_check() {
  local status="${1:-}" concl="${2:-}"
  [[ -z "$status" ]] && { printf 'ready\n'; return 0; }
  [[ "$status" != "completed" ]] && { printf 'in_flight\n'; return 0; }
  case "$concl" in
    failure|timed_out|action_required) printf 'failure\n' ;;
    *) printf 'ready\n' ;;
  esac
}

# ── moved here from scripts/full-suite-gate.sh, unchanged ────────────────────
# Two callers now need this exact discrimination: the queue block (does main's red
# reflect a suite verdict?) and merge-queue-metrics (is this red ours to count?).
# A second copy of a step-name convention is the drift this file exists to prevent.
# (fix_merge_queue_metrics_buckets_a_setup_death_as_a_test_red)
# run_death_site <jobs-json> <job-name> -> setup | suite | unknown                       (pure)
#
# Given the payload of `actions/runs/<id>/jobs`, decide whether the named job failed BEFORE it ran
# any of the workflow's own steps. GitHub prepends its own setup steps ("Set up job", the `uses:`
# action steps) ahead of every `run:` step, and a failure in those means our code never executed.
#
# ⚠ IT MATCHES THE FAILING STEP'S NAME AGAINST GITHUB'S OWN SETUP STEPS, and that IS a second copy of
# somebody else's naming convention — said plainly rather than dressed up, because a copy of a fact
# that lives elsewhere is the thing this repo keeps getting caught by.
#
# What makes it acceptable here is the DIRECTION IT ROTS. If GitHub renames "Set up job", the pattern
# stops matching, this returns `suite`, and the gate BLOCKS — which is exactly today's behaviour, the
# one being fixed. So the failure mode of a stale pattern is "no better than before", never "silently
# stops blocking". A number-based rule (is the failing step before the first `run:`?) would be more
# durable but the API does not expose which steps came from the workflow versus from the runner, so
# it would need its own copy of that boundary — a different guess wearing a more confident costume.
#
# The self-test drives the REAL payload shape from the 14:08 run, so a rename shows up as a red here
# before it shows up as a mystery in production.
run_death_site() {
  local jobs="${1-}" name="${2-}" out
  [[ -n "$jobs" ]] || { printf 'unknown\n'; return 0; }
  out="$(printf '%s' "$jobs" | jq -r --arg n "$name" '
      [ .jobs[]? | select(.name == $n) ] as $j
    | if ($j | length) == 0 then "unknown"
      else
        ($j[0].steps // []) as $steps
      | ([ $steps[] | select(.conclusion == "failure") ] | first) as $bad
      | if $bad == null then "unknown"
        elif ($bad.name | ascii_downcase
              | test("^(set up job|checkout|run actions/|initialize containers|set up runner|post )")) then "setup"
        else "suite" end
      end' 2>/dev/null)"
  case "$out" in
    setup|suite|unknown) printf '%s\n' "$out" ;;
    # jq missing, malformed payload, empty output — all "could not establish", which BLOCKS.
    *)                   printf 'unknown\n' ;;
  esac
}

# run_death_step <jobs-json> <job-name> -> the FIRST failing step's name, or "" (pure)
# run_job_duration <jobs-json> <job-name> -> "33s" / "23m 17s", or "" (pure)
# (infra_the_merge_queue_block_message_throws_away_the_death_site_it_just_computed)
#
# ⚠ run_death_site COMPUTES THE FAILING STEP AND THEN DISCARDS IT. It selects `$bad` — the first
# step with conclusion "failure" — classifies it setup/suite, and returns the CLASS. The name it
# matched against is thrown away one line later, and the block message therefore cannot say where
# the run died even though the answer was in hand. These two return the parts it drops. They do NOT
# reclassify anything: `run_death_site` is unchanged and still returns `suite` for the 17:12 case.
#
# ⚠⚠ AND THE DURATION IS NOT A NICETY — IT IS THE DISCRIMINATOR, WHICH THE STEP NAME IS NOT.
# Measured on the two runs this ticket is about:
#
#     run 32053471791  18:08  failing step "Full house gate on main tip — bash scripts/verify.sh"
#     run 32586684979  17:12  failing step "Full house gate on main tip — bash scripts/verify.sh"
#
# IDENTICAL step names, identical step lists. One ran the suite; the other died 33 seconds in, at a
# ledger check, having executed no specs at all. **A fix that named only the step would satisfy a
# careless reading of the ticket and still leave the two indistinguishable** — the reader separates
# them by 33s versus 23m and by nothing else. Both are printed, together, or neither is worth
# printing.
#
# Both fail soft to "" — a message that omits a detail is strictly better than one that invents it,
# and every caller must already handle the empty case because `unknown` payloads exist.
run_death_step() {
  local jobs="${1-}" name="${2-}" out
  [[ -n "$jobs" ]] || { printf '\n'; return 0; }
  out="$(printf '%s' "$jobs" | jq -r --arg n "$name" '
      [ .jobs[]? | select(.name == $n) ] as $j
    | if ($j | length) == 0 then ""
      else ( ($j[0].steps // []) | map(select(.conclusion == "failure")) | first | .name // "" )
      end' 2>/dev/null)" || out=''
  [[ "$out" == "null" ]] && out=''
  printf '%s\n' "$out"
}

# run_job_duration_s <jobs-json> <job-name> -> "2717" (whole seconds), or "" (pure)
#
# ⚠ THE SECONDS EXIST SEPARATELY BECAUSE A CALLER THAT NEEDS TO COMPARE CANNOT USE THE PRETTY FORM,
# AND I SHIPPED THAT BUG BEFORE WRITING THIS. `full-suite-gate.sh` compares a job's duration against
# its `timeout-minutes` to tell a timed-out run from a human cancel; built on `run_job_duration` it
# was testing `"45m 17s" =~ ^[0-9]+$`, which is false for every value the function can return, so the
# comparison never fired and the fix was inert. Every pure test still passed — they call the verdict
# function directly and never touch the wiring.
# (fix_a_timed_out_full_suite_reads_as_cannot_tell_so_it_can_never_block_the_merge_queue)
run_job_duration_s() {
  local jobs="${1-}" name="${2-}" secs
  [[ -n "$jobs" ]] || { printf '\n'; return 0; }
  secs="$(printf '%s' "$jobs" | jq -r --arg n "$name" '
      [ .jobs[]? | select(.name == $n) ] as $j
    | if ($j | length) == 0 then ""
      else ( $j[0] as $job
           | if ($job.started_at // "") == "" or ($job.completed_at // "") == "" then ""
             else (($job.completed_at | fromdateiso8601) - ($job.started_at | fromdateiso8601))
             end )
      end' 2>/dev/null)" || secs=''
  # ⚠ ANYTHING THAT IS NOT A NON-NEGATIVE INTEGER IS "" — including the negative durations this repo
  # has seen from cancelled and skipped jobs, whose timestamps are nonsense. A duration is offered as
  # evidence, so an impossible one must be withheld rather than printed with a minus sign.
  case "$secs" in
    ''|null|*[!0-9]*) printf '\n'; return 0 ;;
  esac
  printf '%s\n' "$secs"
}

# run_job_dispatched <jobs-json> <job-name> -> yes | no                                     (pure)
#
# ⚠⚠ DID THIS JOB EVER GET A RUNNER? A DURATION CANNOT ANSWER THAT, AND IT LOOKS LIKE IT CAN.
# For a job that never dispatched, GitHub stamps `started_at = created_at` and `completed_at` at
# cancellation — so `run_job_duration_s` returns the QUEUE WAIT, a real number that reads exactly like
# execution time. On a saturated seat that number is routinely LARGER than the suite's own timeout:
# measured 2026-09-05, the hourly created 20:08:03 did not start until 21:34:21 — **86 minutes of
# queue**, against a 45-minute limit.
#
# ⚠ So any claim of the form "this ran long enough to have been killed by timeout-minutes" MUST first
# establish that it ran at all. `runner_name` is the discriminator and duration never is.
# (The same discriminator this repo already reached for when costing cancelled runs: 64 of 66 cancelled
# jobs had never dispatched, and their summed "duration" was 11,082s against a real cost of zero.)
run_job_dispatched() {
  local jobs="${1-}" name="${2-}" runner
  [[ -n "$jobs" ]] || { printf 'no\n'; return 0; }
  runner="$(printf '%s' "$jobs" | jq -r --arg n "$name" '
      [ .jobs[]? | select(.name == $n) ] as $j
    | if ($j | length) == 0 then "" else ($j[0].runner_name // "") end' 2>/dev/null)" || runner=''
  case "$runner" in
    ''|null) printf 'no\n' ;;
    *)       printf 'yes\n' ;;
  esac
}

run_job_duration() {
  local secs; secs="$(run_job_duration_s "${1-}" "${2-}")"
  [[ -n "$secs" ]] || { printf '\n'; return 0; }
  if (( secs < 60 )); then printf '%ds\n' "$secs"
  else printf '%dm %ds\n' "$(( secs / 60 ))" "$(( secs % 60 ))"; fi
}

# gh_job_death_site <repo> <job-id> -> setup | suite | unknown           (fetches)
# The impure half of run_death_site, shaped exactly like gh_job_failure_reason above: ONE call, and
# only ever for a job already known to have failed.
#
# ⚠ THE ARGUMENT IS A CHECK-RUN ID AND THAT IS DELIBERATE. For Actions, a job's check-run id and its
# job id are the same integer — verified on job 95782042558 (run 32156066115), where the id served by
# `commits/<sha>/check-runs` resolved unchanged through `actions/jobs/<id>`. gh_job_failure_reason
# already relies on this (it hits actions/jobs and check-runs with the one id); it is written down
# here because a caller holding a check-run id would otherwise have no reason to believe it.
#
# ⚠ FAILS SOFT TO `unknown`, WHICH IS THE PESSIMISTIC ANSWER, and that is the opposite direction from
# gh_job_failure_reason's soft-fail to `red` only in spelling. Both mean "assume this counts against
# us": not knowing where a run died is not knowing that it never started, so only a POSITIVE
# identification of a setup death may ever downgrade a red.
gh_job_death_site() {
  local repo="${1-}" id="${2-}" job name
  [[ -n "$repo" && -n "$id" ]] || { printf 'unknown\n'; return 0; }
  job="$(gh api "repos/$repo/actions/jobs/$id" 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  [[ -n "$job" ]] || { printf 'unknown\n'; return 0; }
  name="$(printf '%s' "$job" | jq -r '.name // ""' 2>/dev/null)" || name=''
  [[ -n "$name" ]] || { printf 'unknown\n'; return 0; }
  run_death_site "$(printf '%s' "$job" | jq -c '{jobs:[.]}' 2>/dev/null)" "$name"
}

gh_checks_self_test() {
  local fails=0
  _c() { local want="$1" got; got="$(gh_classify_check "$2" "${3:-}")"
         if [[ "$got" == "$want" ]]; then printf '  ok    check %s/%s -> %s\n' "${2:-none}" "${3:--}" "$want"
         else printf '  FAIL  check %s/%s -> %s (wanted %s)\n' "${2:-none}" "${3:--}" "$got" "$want"; fails=1; fi; }
  _c ready     ''
  _c in_flight queued
  _c in_flight in_progress
  _c failure   completed failure
  _c failure   completed timed_out
  _c failure   completed action_required
  _c ready     completed success
  # ⚠ THE ONE THAT MATTERS — see the header. A regression here makes both callers
  # step over the very PRs they exist to land.
  _c ready     completed cancelled
  _c ready     completed skipped

  # ── the HISTORY rule (fix_cancelled_run_hides_a_red_verify) ────────────────
  _h() { local want="$1"; shift; local got; got="$(gh_classify_history "$@")"
         if [[ "$got" == "$want" ]]; then printf '  ok    history [%s] -> %s\n' "$*" "$want"
         else printf '  FAIL  history [%s] -> %s (wanted %s)\n' "$*" "$got" "$want"; fails=1; fi; }

  # ⚠ THE BUG, EXACTLY AS IT RAN ALL DAY ON 2026-08-07: a real failure, then the
  # batcher cancels the re-run because it absorbed the PR. Under `last`, that reads
  # `ready` and the PR joins the next batch and reddens it too.
  _h failure  completed:failure completed:cancelled
  _h failure  completed:failure completed:cancelled completed:cancelled
  # ⚠ AND THE OPPOSITE MISTAKE, which would be worse: cancellation alone is NOT a
  # failure. Every superseded run ends cancelled; reading these as red makes both
  # callers step over the PRs they exist to land.
  _h ready    completed:cancelled
  _h ready    completed:cancelled completed:cancelled
  _h ready    completed:skipped
  # A later success clears an earlier red at the same SHA — a green re-run must count.
  _h ready    completed:failure completed:success
  _h ready    completed:failure completed:success completed:cancelled
  # …and a later failure outranks an earlier success, or a newly-broken PR sails in.
  _h failure  completed:success completed:failure
  # A run in flight right now is in_flight whatever the history says.
  _h in_flight completed:failure queued
  _h in_flight in_progress
  # No runs at all is ready — an unverified PR is not a broken one.
  _h ready

  # ── THE THIRD STATE (fix_batcher_bisects_a_batch_a_power_cut_reddened) ─────
  # ⚠ THE EXACT ARTEFACT, not a paraphrase: run 31258422816 attempt 1, the batch #4765
  # power cut. Job `failure`, gate step `cancelled`, everything after it `skipped`.
  # Before the fix this returned `failure` and the batcher bisected four good PRs.
  _h indeterminate completed:failure:unjudged
  # ⚠ AND THE CASE THAT MUST NOT MOVE — a genuine red still bisects. The whole value of
  # the bisect is surviving one bad PR; a fix that made every red look indeterminate
  # would destroy it, and would do so silently.
  _h failure       completed:failure:judged
  _h failure       completed:failure
  # A judged red LATER than a died-mid-gate run is a real red — the box recovered and
  # then the tree failed on its own account.
  _h failure       completed:failure:unjudged completed:failure:judged
  # …and the reverse: a red tree, then the box dies re-running it. Nothing new was
  # learned, so the standing red is what survives — an infra death must not LAUNDER a
  # failure already on the record, exactly as a cancellation must not.
  _h failure       completed:failure:judged completed:failure:unjudged
  # A green after a died-mid-gate run clears it.
  _h ready         completed:failure:unjudged completed:success
  # A GREEN tree whose re-run dies with the box has still learned nothing new — re-run
  # it rather than calling a healthy PR red.
  _h indeterminate completed:success completed:failure:unjudged
  # Cancellation still steps over an indeterminate, changing nothing.
  _h indeterminate completed:failure:unjudged completed:cancelled
  # timed_out is NOT indeterminate even though its gate step is cancelled too — the job
  # was given 45 minutes and did not finish, which IS a verdict. See the header.
  _h failure       completed:timed_out:unjudged

  # ── the retry bound: GitHub's own attempt counter, not a state file ────────
  _n() { local want="$1"; shift; local got; got="$(gh_rerun_verdict "$@")"
         if [[ "$got" == "$want" ]]; then printf '  ok    rerun attempt=%s max=%s -> %s\n' "$1" "${2:-default}" "$want"
         else printf '  FAIL  rerun attempt=%s max=%s -> %s (wanted %s)\n' "$1" "${2:-default}" "$got" "$want"; fails=1; fi; }
  # The first death buys ONE re-run of the same tree…
  _n rerun   1
  # …and the second does not. ⚠ ASSERT THE BOUND: without it one unhealthy box becomes a
  # permanent queue, re-running for ever and never falling back to a path that alerts.
  _n give_up 2
  _n give_up 3
  # ⚠ AN UNREADABLE ATTEMPT FAILS CLOSED. gh_verify_attempt returns 0 on an API blip, and
  # `0 < max` would re-run every tick for ever — an unbounded retry assembled out of the
  # bound itself. This case is the guard on that, and it must never flip to `rerun`.
  _n give_up 0
  _n give_up ''
  _n give_up nonsense
  # The budget is configurable, and the bound must track it rather than a hard-coded 2.
  _n rerun   2 3
  _n give_up 3 3
  _n give_up 1 1
  # A garbage budget falls back to the default rather than disabling the bound.
  _n rerun   1 nonsense

  # ── WHY it failed: the box or the diff (infra_a_lost_runner_reads_as_a_failed_verify) ──
  # ⚠ ASSERTED AGAINST CAPTURED REAL RESPONSES, NOT HAND-WRITTEN JSON. The signature this
  # classifier keys on is PERISHABLE — re-running a run destroys its predecessor's job list and
  # its annotations — and an earlier attempt at this ticket named a signature that does not exist
  # because it was read off a mislabelling filter rather than off an artefact. Hand-writing the
  # fixture here would reproduce exactly that: a test that agrees with whatever the author believed.
  # See scripts/testdata/ci-runs/README.md.
  local fxdir; fxdir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../testdata/ci-runs" 2>/dev/null && pwd)" || fxdir=''
  if [[ -z "$fxdir" ]]; then
    printf '  FAIL  the CI fixtures are missing (scripts/testdata/ci-runs) — the classifier is unasserted\n'
    fails=1
  else
    # The step conclusions EXACTLY as the file spells them: `jq -r` prints a JSON null as the
    # literal `null` and an empty string as an empty line, so the raw output IS the two spellings
    # the classifier has to survive. Normalising here would delete the thing under test.
    _fx_steps() { jq -r --arg j "$2" '.jobs[] | select(.name == $j) | .steps[].conclusion' "$1" 2>/dev/null; }
    _fx_concl() { jq -r --arg j "$2" '.jobs[] | select(.name == $j) | .conclusion' "$1" 2>/dev/null; }
    _fx_ann()   { jq -r '[.[].message] | join(" ")' "$1" 2>/dev/null; }

    # _f <want> <jobs-file> <job-name> [annotations-file]
    _f() {
      local want="$1" jf="$fxdir/$2" jn="$3" af="${4:-}" ann='' got concl
      local -a st=()
      if [[ ! -f "$jf" ]]; then
        printf '  FAIL  fixture %s is missing — cannot assert %s\n' "$2" "$want"; fails=1; return
      fi
      if [[ -n "$af" ]]; then
        if [[ ! -f "$fxdir/$af" ]]; then
          printf '  FAIL  fixture %s is missing — cannot assert %s\n' "$af" "$want"; fails=1; return
        fi
        ann="$(_fx_ann "$fxdir/$af")"
      fi
      concl="$(_fx_concl "$jf" "$jn")"
      mapfile -t st < <(_fx_steps "$jf" "$jn")
      got="$(gh_failure_reason "$concl" "$ann" ${st[@]+"${st[@]}"})"
      if [[ "$got" == "$want" ]]; then printf '  ok    %s / %s -> %s\n' "$2" "$jn" "$want"
      else printf '  FAIL  %s / %s -> %s (wanted %s)\n' "$2" "$jn" "$got" "$want"; fails=1; fi
    }

    # THE FIXTURE — run 31606017907, the only surviving instance of the signature. Both jobs.
    _f lost-runner lost-runner-31606017907.rest-jobs.json 'verify'              lost-runner-31606017907.annotations-verify.json
    _f lost-runner lost-runner-31606017907.rest-jobs.json 'coverage (advisory)' lost-runner-31606017907.annotations-coverage.json
    # ⚠ THE SAME RUN THROUGH THE OTHER ENDPOINT. Identical steps, `""` instead of `null`. This is
    # the pair that stops the classifier passing against one source and mislabelling against the
    # other — the trap that produced the wrong signature the first time round.
    _f lost-runner lost-runner-31606017907.cli-jobs.json  'verify'              lost-runner-31606017907.annotations-verify.json
    _f lost-runner lost-runner-31606017907.cli-jobs.json  'coverage (advisory)' lost-runner-31606017907.annotations-coverage.json
    # …and the shape alone, with NO annotation, because the annotations endpoint can fail or the
    # attempt can have been replaced. Both spellings again.
    _f lost-runner lost-runner-31606017907.rest-jobs.json 'verify'
    _f lost-runner lost-runner-31606017907.cli-jobs.json  'verify'

    # ⚠ THE LOAD-BEARING NEGATIVE CONTROLS: two REAL reds from the same day. If either of these
    # ever reads as infrastructure, this feature is actively telling agents to ignore bug reports —
    # which is worse than the silence it replaces. They separate on BOTH axes independently:
    # `failed=1, no-verdict=0`, and an annotation reading "Process completed with exit code 1."
    _f red real-red-31604230722.rest-jobs.json 'verify' real-red-31604230722.annotations-verify.json
    _f red real-red-31592652576.rest-jobs.json 'verify' real-red-31592652576.annotations-verify.json
    # …and with no annotation read at all, so the verdict rests on the step shape alone.
    _f red real-red-31604230722.rest-jobs.json 'verify'
    _f red real-red-31592652576.rest-jobs.json 'verify'

    # NEGATIVE CONTROL 2 — cancellations, which must never read as a lost runner.
    # Superseded by a newer push (the concurrency group), and cancelled mid-gate.
    _f cancelled cancelled-by-push-31669787525.rest-jobs.json 'verify'
    _f cancelled cancelled-midgate-31627036211.rest-jobs.json 'verify'
    # A job SKIPPED because the run was cancelled before it started is not a failure either.
    _f ok        cancelled-by-push-31669787525.rest-jobs.json 'API e2e'

    # ⚠ THE OTHER INFRASTRUCTURE SHAPE, AND IT IS NOT A LOST RUNNER. The 2026-08-08 power cut:
    # job `failure`, the gate step `cancelled`, everything after it `skipped` — no step without a
    # verdict anywhere. Its annotation says only "The operation was canceled.", which is exactly
    # what a human pressing cancel produces, so the annotation CANNOT carry this one and the step
    # shape has to. Calling it `lost-runner` would overclaim a cause the signal does not support.
    _f unjudged died-midstep-31258422816-attempt1.rest-jobs.json 'verify' died-midstep-31258422816.annotations-verify.json
    _f unjudged died-midstep-31258422816-attempt1.rest-jobs.json 'verify'

    # ── the fixtures themselves, pinned ──────────────────────────────────────
    # ⚠ A RE-RUN REPLACES A RUN'S JOB LIST. If anyone re-captures these files from a run that has
    # since been re-run, the classifier assertions above would quietly start testing a different
    # artefact — and would most likely still pass, because the replacement is usually a plain red.
    # These counts are the tripwire for that, and they are the numbers in the README table.
    _fxcount() { # <want> <file> <job> <jq-filter-on-steps> <label>
      local want="$1" got
      got="$(jq -r --arg j "$3" "[.jobs[] | select(.name == \$j) | .steps[] | select($4)] | length" "$fxdir/$2" 2>/dev/null)"
      if [[ "$got" == "$want" ]]; then printf '  ok    fixture %s: %s = %s\n' "$2" "$5" "$want"
      else printf '  FAIL  fixture %s: %s = %s (wanted %s) — was this run RE-RUN and re-captured?\n' "$2" "$5" "$got" "$want"; fails=1; fi
    }
    _fxcount 0 lost-runner-31606017907.rest-jobs.json 'verify' '.conclusion == "failure"' 'failed steps'
    _fxcount 8 lost-runner-31606017907.rest-jobs.json 'verify' '.conclusion == null'      'no-verdict steps'
    _fxcount 7 lost-runner-31606017907.rest-jobs.json 'coverage (advisory)' '.conclusion == null' 'no-verdict steps'
    # The CLI capture must be the SAME steps in the OTHER spelling — that equivalence is the claim.
    _fxcount 8 lost-runner-31606017907.cli-jobs.json  'verify' '.conclusion == ""'        'no-verdict steps'
    _fxcount 1 real-red-31604230722.rest-jobs.json 'verify' '.conclusion == "failure"' 'failed steps'
    _fxcount 0 real-red-31604230722.rest-jobs.json 'verify' '.conclusion == null'      'no-verdict steps'
    _fxcount 1 real-red-31592652576.rest-jobs.json 'verify' '.conclusion == "failure"' 'failed steps'
    _fxcount 0 real-red-31592652576.rest-jobs.json 'verify' '.conclusion == null'      'no-verdict steps'
    # And the annotation the whole classification hangs on is actually in the file.
    if [[ -f "$fxdir/lost-runner-31606017907.annotations-verify.json" ]] \
       && _fx_ann "$fxdir/lost-runner-31606017907.annotations-verify.json" \
          | /usr/bin/grep -qF 'lost communication with the server'; then
      printf '  ok    fixture carries the lost-runner annotation verbatim\n'
    else
      printf '  FAIL  the lost-runner annotation is gone from the fixture — the signature is unasserted\n'; fails=1
    fi
  fi

  # ── the STEP -> MEANING table, which both callers now share ──────────────────
  # (infra_the_step_to_meaning_table_has_two_copies_both_mine)
  _ss() { local want="$1" name="$2" got; got="$(gh_step_site "$name")"
          if [[ "$got" == "$want" ]]; then printf '  ok    site [%s] -> %s\n' "$name" "$want"
          else printf '  FAIL  site [%s] -> %s (wanted %s)\n' "$name" "$got" "$want"; fails=1; fi; }
  # The ci.yml step names verbatim, so a rewording that breaks the match is caught HERE rather than
  # by a retry loop quietly going silent.
  _ss base-merge  "Merge the PR's base branch into this branch, or stop"
  _ss queue-block 'The full suite must not be red on main'
  # ⚠ THE LANDING STEP IS NOT THE BASE MERGE, and "Merge" alone would conflate them — a conflict
  # retry aimed at the step that lands the PR would re-run a run that had already succeeded.
  _ss other       'Merge — the pipeline lands its own PR'
  _ss other       'The full house gate — bash scripts/verify.sh'
  _ss other       'Teardown — return the CI seat'
  # Nothing to read is `other`, never a site: the callers turn a site into a verdict, and inventing
  # one from an empty string is how a retry reaches somewhere it was never cleared for.
  _ss other       ''
  # ⚠ THE PROPERTY THIS TICKET BUYS, ASSERTED RATHER THAN IMPLIED: renaming the step in ONE place
  # moves the table, so every caller follows. Before this the needle existed here AND in
  # pr-refresh.sh, and updating one left the other matching the old name — silently, and in the
  # reassuring direction.
  ( GH_STEP_QUEUE_BLOCK='hourly suite must be green'
    if [[ "$(gh_step_site 'The hourly suite must be green on main')" == 'queue-block' \
       && "$(gh_step_site 'The full suite must not be red on main')" == 'other' ]]; then
      printf '  ok    renaming the step in one place moves the table\n'
    else
      printf '  FAIL  the table did not follow a rename — a caller is still matching its own copy\n'
      exit 1
    fi ) || fails=1

  # ── the pure rule, at its edges ──────────────────────────────────────────────
  _r() { local want="$1"; shift; local got; got="$(gh_failure_reason "$@")"
         if [[ "$got" == "$want" ]]; then printf '  ok    reason [%s] -> %s\n' "$*" "$want"
         else printf '  FAIL  reason [%s] -> %s (wanted %s)\n' "$*" "$got" "$want"; fails=1; fi; }
  # A step that FAILED outranks the annotation: the tree was judged and it lost, whatever became
  # of the runner afterwards. ⚠ This is the ordering that keeps the failure direction safe.
  _r red         failure 'The self-hosted runner lost communication with the server.' success failure
  # Both spellings of no-verdict, stated directly rather than only through a fixture.
  _r lost-runner failure '' success null null
  _r lost-runner failure '' success '' ''
  _r lost-runner failure '' null
  _r lost-runner failure '' ''
  # A verdict on every step and none of them failed: the box died mid-step, not a vanished runner.
  _r unjudged    failure '' success cancelled skipped
  _r unjudged    failure 'The operation was canceled.' success cancelled skipped
  # ⚠ NO STEPS AT ALL IS NOT EVIDENCE — it stays red. Guessing infrastructure from an absence is
  # how a classifier starts excusing genuine failures it simply could not read.
  _r red         failure ''
  # …but an ABSENCE OF STEPS IS NOT AN ABSENCE OF EVIDENCE when GitHub has said the runner went
  # away in its own words. The guard above is for the case where there is nothing to read at all;
  # the annotation is a positive statement and it stands on its own. A genuine red cannot reach
  # here — its annotation reads "Process completed with exit code 1."
  _r lost-runner failure 'The self-hosted runner lost communication with the server.'
  # ── ⚠ THE SIXTH VERDICT — a red that is not about this PR at all ─────────────────────────────
  # (fix_a_queue_block_red_is_reported_as_your_diff_being_broken)
  # Steps arrive as `<name>:<conclusion>` from the fetcher; every case above passes bare
  # conclusions and must keep meaning exactly what it meant, which is what makes this ONE
  # implementation rather than a second classifier beside it.
  _r queue-blocked failure '' 'The full house gate — bash scripts/verify.sh:success' \
                              'The full suite must not be red on main:failure'
  # ⚠ THE NEGATIVE THAT KEEPS IT SAFE: the block AND a real failure is `red`. The other failure is a
  # genuine bug report, and hiding it behind "main was red" is the expensive direction.
  _r red         failure '' 'The full house gate — bash scripts/verify.sh:failure' \
                            'The full suite must not be red on main:failure'
  # A named test failure with no block involved is untouched.
  _r red         failure '' 'The full house gate — bash scripts/verify.sh:failure' \
                            'Teardown — return the CI seat:success'
  # ── ⚠ THE SEVENTH VERDICT — a run that judged NOTHING about the diff ────────────────────────
  # (fix_a_branch_needing_a_rebase_classifies_as_a_broken_diff)
  # ci.yml's step 4 merges the PR's base branch in and STOPS IN SECONDS on a conflict. Reported as
  # `red` it sends the owner to read a test failure in their own code that does not exist.
  # LIVE SPECIMEN: run 32240319460 (PR #5985), diagnosed by hand at the time — a classification row
  # with no failing artefact behind it is what gets "tidied" in six months by someone who cannot see
  # what it was for. The step name below is that run's, matched through GH_STEP_BASE_MERGE.
  _r needs-rebase failure '' "Merge the PR's base branch into this branch, or stop:failure"
  # ⚠ THE NEGATIVE THAT KEEPS IT SAFE, AND IT IS THE SAME ONE `queue-blocked` HAS: the base merge
  # AND a real failure is `red`. The other failure is a genuine bug report, and hiding it behind
  # "you need a rebase" is the expensive direction this whole file is built to avoid.
  _r red          failure '' "Merge the PR's base branch into this branch, or stop:failure" \
                             'The full house gate — bash scripts/verify.sh:failure'
  # ⚠ AND A BASE MERGE THAT SUCCEEDED IS NOT THIS VERDICT. Positive evidence means the step FAILED,
  # not merely that it is present — without this case the rule would fire on every run in the repo,
  # since step 4 is on all of them.
  _r red          failure '' "Merge the PR's base branch into this branch, or stop:success" \
                             'The full house gate — bash scripts/verify.sh:failure'
  # ⚠ NAMES CONTAINING A COLON MUST SPLIT ON THE LAST ONE, or a step called "Merge: the PR" would
  # have its conclusion read as "the PR" and land in the noverdict bucket.
  _r red         failure '' 'Some step: with a colon:failure'
  # A named run where the runner vanished still reads as lost-runner — the name-awareness must not
  # shadow the classes that already worked.
  _r lost-runner failure '' 'The full house gate — bash scripts/verify.sh:' 'Teardown:'
  # Not failures.
  _r ok          success '' success
  _r ok          '' ''
  _r ok          skipped ''
  _r cancelled   cancelled '' cancelled skipped
  # Verdicts in their own right — a burnt timeout is attributable to a hanging test.
  _r red         timed_out '' success null
  _r red         action_required ''
  # An unrecognised conclusion falls to red rather than inventing a class for it.
  _r red         some_new_github_conclusion '' null

  # ⚠ THE ONE PLACE _gh_job_judged'S ANSWER DELIBERATELY MOVED, pinned so it cannot revert
  # unnoticed. The old rule joined the step conclusions into a string and treated an EMPTY string
  # as "no steps at all, so judged" — but `[null] | join(" ")` is also the empty string, so a job
  # whose single step never reached a verdict (the lost-runner signature in miniature) read as a
  # genuine red and the batcher bisected a batch over it. Measured both ways before changing it:
  # old `judged`, new `unjudged`. Everything else in that function answers exactly as it did.
  _r lost-runner failure '' null
  _r red         failure ''

  return "$fails"
}
