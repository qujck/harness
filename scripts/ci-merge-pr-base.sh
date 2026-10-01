#!/usr/bin/env bash
# scripts/ci-merge-pr-base.sh — merge the PR's BASE branch into this tree before testing it.
# (fix_ci_merges_hardcoded_main_so_a_release_line_pr_tests_the_wrong_tree)
#
#   BASE_REF=<branch> bash scripts/ci-merge-pr-base.sh     # what ci.yml runs
#   bash scripts/ci-merge-pr-base.sh --self-test           # drives real throwaway repos, no network
#
# ── WHY THIS EXISTS ─────────────────────────────────────────────────────────────────────────────
# This was inline in ci.yml and merged a HARDCODED `origin/main`, with no reference to the PR's base
# anywhere in it. For a PR based on `main` that is right. For a PR based on anything else it tests
# **the branch + its base + all of main's unreleased work** — a tree that will never exist, and
# specifically one containing exactly the code a release line was cut to EXCLUDE.
#
# 14 `release/*` branches exist and hotfixes target them. Green on such a PR meant "this hotfix works
# when combined with unreleased main", which is not the question anyone asked.
#
# ⚠ THE FIX IS "USE THE PR'S BASE REF", NOT "SKIP THE MERGE WHEN THE BASE IS NOT MAIN". Skipping
# would restore an older and quieter failure — a release-line PR testing only itself while its base
# drifted underneath it, which is the thing the merge step was added to stop. **A quiet wrong answer
# is not an improvement on a loud one.**
#
# ⚠ AND IT WAS EXTRACTED FROM THE WORKFLOW RATHER THAN EDITED IN PLACE, because shell inside a
# `run:` block cannot be driven by anything. The ticket asked for a test that asserts WHICH SHA got
# merged — not one that reads the job's conclusion, since a green conclusion is exactly what the
# broken version produced. That test needs a callable unit, so here it is.
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/harness-env.sh"
# The shared flag contract — both spellings accepted, anything unrecognised refused. Guarded because
# this file is also sourced by its own mutation tests and by ci.yml's runner, where a missing lib
# must not be fatal.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh" 2>/dev/null || true

# base_ref_for <github.base_ref> -> the branch to merge                                    (pure)
#
# ⚠ THE FALLBACK IS `main` AND IT MUST STAY. On a non-`pull_request` event `github.base_ref` is
# empty, and this step has always merged main there. Falling back preserves that exactly; failing
# instead would convert a working push/schedule run into a hard stop.
base_ref_for() {
  local b="${1-}"
  [[ -n "${b//[[:space:]]/}" ]] && printf '%s\n' "$b" || printf 'main\n'
}

# ── the impure half ─────────────────────────────────────────────────────────────────────────────
# Kept behaviour-identical to the inline version it replaces, including every fail-open branch. The
# ONLY change is which ref it names. On the overwhelmingly common case — base is `main` — this
# resolves to `main` and does precisely what it did before.
# ── PROVENANCE: record WHAT BASE this run tested against, AT MERGE TIME ─────────────────────────
# (fix_a_red_is_reported_without_the_base_it_was_measured_against)
#
# A red is a measurement of ONE TREE AT ONE MOMENT, but it is reported as a timeless property of the
# PR. The reader cannot tell a PR reddened by a defect main fixed two hours ago from one that is
# genuinely broken — #6241 sat red for 2h05m and nobody could say which it was.
#
# ⚠ EMITTED HERE, NOT RECOVERED FROM THE LOG LATER. The base sha is known exactly once, at the
# moment this script merges it. Reading it back out of a step log would build the provenance on the
# fragile thing and it would be missing precisely when a run is messy — i.e. on the runs that need
# it. $GITHUB_ENV carries it to the reporting step with no parsing and no second API call.
#
# ⚠ THREE STATES, NOT TWO. This step FAILS OPEN on a fetch hiccup, so there are real paths where no
# base was established. Those must record `unknown`, never a plausible-looking sha and never silence
# — "we could not tell what we tested against" is a different fact from "we tested against X", and
# the reporting step must be able to say which.
_record_base_provenance() { # <sha-or-empty> <ref>
    # ⚠ THIS GUARD IS "GITHUB_ENV IS UNSET", AND NOTHING MORE. It used to claim "no-op outside
    # Actions, incl. the self-test" — true on a developer's box and FALSE in CI, where GITHUB_ENV is
    # always set and the self-test therefore wrote CI_BASE_* into the JOB's file. The claim is not
    # corrected here, it is made unnecessary: the self-test now points GITHUB_ENV at its own fixture
    # for its whole duration, so this function's behaviour no longer depends on who is calling it.
    # ⚠ The three call sites on the real merge path MUST keep writing to the job's file — that is
    # the feature. (infra_audit_the_enrolled_self_tests_for_real_side_effects)
    [[ -n "${GITHUB_ENV:-}" ]] || return 0
    printf 'CI_BASE_SHA=%s\n' "${1:-unknown}" >> "$GITHUB_ENV"
    printf 'CI_BASE_REF=%s\n' "${2:-unknown}" >> "$GITHUB_ENV"
    # ⚠ THE MOMENT OF MEASUREMENT, TAKEN HERE. Stamping it in the reporting step would record when
    # the COMMENT was written, which on a 20-minute suite is a different fact and the wrong one.
    printf 'CI_BASE_MEASURED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$GITHUB_ENV"
}

ci_merge_pr_base() {
  local base sha
  base="$(base_ref_for "${BASE_REF:-}")"

  git config user.email "ci@${HARNESS_PROJECT:-harness}.local"
  git config user.name  "CI"


  # ⚠ FAIL OPEN ON THE BASE EXACTLY AS IT DID ON MAIN. A fetch hiccup must not stop a healthy PR —
  # and if this branch failed CLOSED for a base it could not see, the change would convert a
  # transient network fault into a hard stop for every release-line PR.
  if ! git fetch --quiet origin "$base" 2>/dev/null; then
    _record_base_provenance "" "$base"
    echo "could not fetch origin/$base — proceeding with the tree as checked out"
    echo "(this step fails OPEN: a fetch hiccup must not stop a healthy PR)"
    return 0
  fi
  sha="$(git rev-parse --verify --quiet "origin/$base" || true)"
  if [[ -z "$sha" ]]; then
    _record_base_provenance "" "$base"
    echo "could not read origin/$base — proceeding (this step fails OPEN)"
    return 0
  fi
  _record_base_provenance "$sha" "$base"
  if git merge-base --is-ancestor "$sha" HEAD; then
    echo "already contains origin/$base ($sha) — nothing to merge"
    return 0
  fi
  echo "merging origin/$base ($sha) into this tree before testing it"
  if git merge --no-edit --no-ff "$sha"; then
    echo "merged cleanly — everything below tests this branch COMBINED WITH CURRENT origin/$base"
    return 0
  fi

  echo "::error::MERGE_CONFLICT — this branch conflicts with current origin/$base."
  echo "Nothing downstream will run. Only the author can resolve this."
  echo ""
  echo "Conflicting paths:"
  git diff --name-only --diff-filter=U | sed 's/^/    /'
  echo ""
  # ⚠ THE REMEDY IS A REBASE, NEVER A MERGE, AND THIS LINE USED TO SAY `git merge origin/main`.
  # (chore_merge_by_rebase_so_authorship_survives) GitHub REFUSES to rebase-merge a branch containing
  # merge commits, so every author who followed the old remedy made their own PR unmergeable under
  # the merge method this repo moved to. Measured 2026-08-13: the affected set was not draining but
  # GROWING — two new merge commits within the hour it was measured, both from authors correctly
  # following that very message.
  #
  # ⚠ CI's OWN merge above is NOT affected and must not change: it is never pushed, so it creates no
  # merge commit on the branch. There is no `git push` anywhere in the workflow — verified.
  echo "Resolve by rebasing, not by merging the base in:"
  echo "  git fetch origin && git rebase origin/$base"
  echo ""
  echo "A rebase rewrites your branch, so the follow-up push is non-fast-forward:"
  echo "  git push --force-with-lease"
  echo ""
  echo "--force-with-lease, never --force: it refuses if anyone else pushed to the branch meanwhile."
  # ⚠ LEAVE THE REASON WHERE THE REPORTER CAN FIND IT.
  # (infra_the_cause_reporter_blames_itself_when_the_gate_never_ran) Everything printed above is a
  # correct, complete diagnosis — and until this existed it was thrown away one step later: the gate
  # never ran, so no verify-output.log was written, so the reporting step told the reader the
  # REPORTER was broken. A step that stops the chain must hand its reason forward.
  # ⚠ $RUNNER_TEMP, never a fixed /tmp name — two runner users share the box and whoever creates the
  # path owns it (fix_ci_reporters_share_fixed_tmp_paths_across_runner_users).
  if [[ -n "${RUNNER_TEMP:-}" ]]; then
    {
      echo "MERGE_CONFLICT — this branch conflicts with current origin/$base, so the gate never ran."
      echo ""
      echo "Conflicting paths:"
      git diff --name-only --diff-filter=U | sed 's/^/    /'
      echo ""
      echo "Resolve by rebasing, not by merging the base in:"
      echo "  git fetch origin && git rebase origin/$base"
      echo "  git push --force-with-lease"
    } > "$RUNNER_TEMP/stop-reason.txt" 2>/dev/null || true
  fi
  return 1
}

# ── self-test ───────────────────────────────────────────────────────────────────────────────────
# ⚠ IT DRIVES REAL GIT REPOSITORIES, and it asserts on WHICH SHA WAS MERGED — never on an exit code
# alone. The broken version this replaces exited 0 and printed a cheerful success line while merging
# the wrong tree; a test reading only the status would have passed against it.
declare -F selftest_reject_typo >/dev/null && selftest_reject_typo "${1:-}"
if declare -F selftest_is_flag >/dev/null && selftest_is_flag "${1:-}"; then
  fails=0
  t() { if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s\n       want %q\n       got  %q\n' "$1" "$2" "$3"; fails=1; fi; }

  # pure half first — cheap, and it pins the fallback that keeps push/schedule runs working.
  t "an explicit base is used as-is"        "release/v0.175" "$(base_ref_for release/v0.175)"
  t "a main base is main"                   "main"           "$(base_ref_for main)"
  t "an EMPTY base falls back to main"      "main"           "$(base_ref_for '')"
  t "…and whitespace counts as empty"       "main"           "$(base_ref_for '   ')"

  _root="$(mktemp -d)"; trap 'rm -rf "$_root"' EXIT

  # ⚠ ISOLATE $RUNNER_TEMP, NOT JUST THE GIT REPOS — AND THIS IS THE BUG THAT TAUGHT IT.
  # Case (5) below drives the REAL conflict path, which writes $RUNNER_TEMP/stop-reason.txt so the
  # reporting step can carry the reason forward. The self-test isolated the state it THOUGHT it was
  # about — throwaway git repos under $_root — and not the state the code under test actually
  # WRITES. So on a runner it left a genuine stop-reason.txt behind, mid-job, naming its own fixture
  # path `unreleased.txt`.
  #
  # The consequence was not a failing self-test: it was PR comments on unrelated runs reading "the
  # pipeline stopped BEFORE THE TEST GATE RAN — MERGE_CONFLICT, conflicting paths: unreleased.txt",
  # on runs whose gate had plainly executed and whose real cause was extracted and then discarded.
  # ⚠ `unreleased.txt` is not a tracked file anywhere in this repo (`git ls-files` → 0); it exists
  # only as the fixture three lines below, which is what proved the source.
  #
  # This was latent for as long as the self-test was never executed, and became live the moment
  # infra_twenty_six_self_tests_are_invoked_by_nothing enrolled it into verify.sh — which is an
  # argument FOR that ticket, not against it: the defect was already here, unrun.
  # (fix_a_self_test_writes_a_real_stop_reason_into_runner_temp)
  mkdir -p "$_root/runner-temp"
  RUNNER_TEMP="$_root/runner-temp"
  # ⚠ $GITHUB_ENV IS THE SECOND CHANNEL, AND THE FIX ABOVE DID NOT COVER IT.
  # `_record_base_provenance` appends CI_BASE_SHA/CI_BASE_REF/CI_BASE_MEASURED_AT to $GITHUB_ENV and
  # is called from THREE sites on the real merge path with no override, as well as from three
  # deliberately-wrapped assertions further down. Its only guard is
  # `[[ -n "${GITHUB_ENV:-}" ]] || return 0`, whose comment reads "no-op outside Actions, incl. the
  # self-test" — TRUE on a developer's box where GITHUB_ENV is unset, and FALSE in CI, which is the
  # only environment that can be harmed by it.
  #
  # Measured by scripts/audit-selftest-side-effects.sh: 544 bytes into a real $GITHUB_ENV,
  # carrying `CI_BASE_SHA=6b8be3260…` — a sha belonging to the THROWAWAY fixture repos built a few
  # lines below, which `git cat-file -t` cannot resolve because it exists nowhere. In CI the hosting
  # job exports that as what the pipeline tested against and the reporting step publishes it:
  # identical in shape to the `unreleased.txt` stop-reason, a plausible value naming something that
  # does not exist, attached to a real run.
  #
  # ⚠ The fix above isolated the state it had just been burned by and did not look for the same
  # class in the same function. That is the sibling rule, missed at the site that taught it.
  # (infra_audit_the_enrolled_self_tests_for_real_side_effects)
  GITHUB_ENV="$_root/github-env"
  : >"$GITHUB_ENV"
  # Build an "origin" with main and a release line that DIVERGE, then a feature branch off each.
  _mk() {
    rm -rf "$_root/o" "$_root/w"; mkdir -p "$_root/o"
    git init --quiet --bare "$_root/o"
    git clone --quiet "$_root/o" "$_root/w" 2>/dev/null
    (
      cd "$_root/w" || { echo "FATAL: the cd above failed — a failed cd does not stop a script, it RELOCATES it, and every relative path below would resolve against the caller's tree" >&2; exit 1; }
      git config user.email a@b.c; git config user.name A
      echo base > f.txt; git add f.txt; git commit --quiet -m base
      git branch -M main; git push --quiet origin main
      # the release line is cut HERE, then main moves on
      git checkout --quiet -b release/v1
      echo rel > rel.txt; git add rel.txt; git commit --quiet -m "release-only"
      git push --quiet origin release/v1
      git checkout --quiet main
      echo unreleased > unreleased.txt; git add unreleased.txt; git commit --quiet -m "MAIN-UNRELEASED"
      git push --quiet origin main
    ) >/dev/null 2>&1
  }

  # (1) THE COMMON CASE MUST BE UNCHANGED: a main-based PR merges main's tip.
  _mk
  ( cd "$_root/w" && git checkout --quiet -b feat main~1 && echo x > x.txt && git add x.txt && git commit --quiet -m feat ) >/dev/null 2>&1
  _main_sha="$(cd "$_root/w" && git rev-parse origin/main)"
  _out="$(cd "$_root/w" && BASE_REF=main ci_merge_pr_base 2>&1)"; _rc=$?
  t "a main-based PR exits 0" "0" "$_rc"
  case "$_out" in *"merging origin/main ($_main_sha)"*) _g=yes ;; *) _g="no: $_out" ;; esac
  t "…and merges MAIN's tip, named by sha" "yes" "$_g"
  t "…so main's unreleased work IS present" "yes" \
    "$( [[ -f "$_root/w/unreleased.txt" ]] && echo yes || echo no )"

  # ⚠ (2) THE NEGATIVE THE WHOLE TICKET IS ABOUT. A release-line PR must merge the RELEASE LINE and
  # must NOT drag in main's unreleased work — which is precisely what the old hardcoded version did,
  # while exiting 0 and printing a success line.
  _mk
  ( cd "$_root/w" && git checkout --quiet -b hotfix origin/release/v1 && git reset --quiet --hard origin/release/v1~1 && echo h > h.txt && git add h.txt && git commit --quiet -m hotfix ) >/dev/null 2>&1
  _rel_sha="$(cd "$_root/w" && git rev-parse origin/release/v1)"
  _out="$(cd "$_root/w" && BASE_REF=release/v1 ci_merge_pr_base 2>&1)"; _rc=$?
  t "a release-line PR exits 0" "0" "$_rc"
  case "$_out" in *"merging origin/release/v1 ($_rel_sha)"*) _g=yes ;; *) _g="no: $_out" ;; esac
  t "…and merges the RELEASE LINE's tip, named by sha" "yes" "$_g"
  t "…the release-only work IS present" "yes" \
    "$( [[ -f "$_root/w/rel.txt" ]] && echo yes || echo no )"
  # THE ONE THAT FAILS AGAINST THE OLD CODE:
  t "⚠ …and main's UNRELEASED work is ABSENT" "yes" \
    "$( [[ -f "$_root/w/unreleased.txt" ]] && echo no || echo yes )"

  # (3) the ancestry short-circuit still works, per base.
  _mk
  ( cd "$_root/w" && git checkout --quiet -b uptodate origin/release/v1 ) >/dev/null 2>&1
  _out="$(cd "$_root/w" && BASE_REF=release/v1 ci_merge_pr_base 2>&1)"
  case "$_out" in *"already contains origin/release/v1"*) _g=yes ;; *) _g="no: $_out" ;; esac
  t "a branch already containing its base merges nothing" "yes" "$_g"

  # (4) FAIL OPEN on a base that cannot be fetched — the same direction it always failed for main.
  _mk
  ( cd "$_root/w" && git checkout --quiet -b feat2 main ) >/dev/null 2>&1
  _out="$(cd "$_root/w" && BASE_REF=no/such/branch ci_merge_pr_base 2>&1)"; _rc=$?
  t "an unfetchable base fails OPEN, not closed" "0" "$_rc"
  case "$_out" in *"fails OPEN"*) _g=yes ;; *) _g="no: $_out" ;; esac
  t "…and says so" "yes" "$_g"

  # (5) a real conflict still stops the chain, and still names the BASE in the remedy.
  _mk
  ( cd "$_root/w" && git checkout --quiet -b clash main~1 && echo mine > unreleased.txt && git add unreleased.txt && git commit --quiet -m clash ) >/dev/null 2>&1
  _out="$(cd "$_root/w" && BASE_REF=main ci_merge_pr_base 2>&1)"; _rc=$?
  t "a conflicting branch exits 1" "1" "$_rc"
  case "$_out" in *"MERGE_CONFLICT"*) _g=yes ;; *) _g=no ;; esac
  t "…and says MERGE_CONFLICT" "yes" "$_g"
  case "$_out" in *"git rebase origin/main"*) _g=yes ;; *) _g=no ;; esac
  t "…and the remedy is a REBASE onto the base, never a merge" "yes" "$_g"

  # ⚠ THE ISOLATION IS ASSERTED, NOT ASSUMED. Case (5) must have written a stop reason — that proves
  # the path really ran — and it must have landed INSIDE $_root. Checking only "the real path is
  # untouched" would pass just as well if the write stopped happening at all, which is the shape of
  # a control that cannot go positive.
  _g=no; [[ -s "$_root/runner-temp/stop-reason.txt" ]] && _g=yes
  t "the conflict path really wrote a stop reason" "yes" "$_g"
  case "$(cat "$_root/runner-temp/stop-reason.txt" 2>/dev/null)" in
    *"unreleased.txt"*) _g=yes ;; *) _g=no ;;
  esac
  t "…naming this self-test's own fixture, so the write is THIS run's" "yes" "$_g"

  # ⚠ THE SAME ASSERTION FOR THE SECOND CHANNEL, AND FOR THE SAME REASON.
  # The merge path also appends CI_BASE_* to $GITHUB_ENV. Isolating it silently would be worth
  # nothing: an isolation that stops working looks identical to one that was never needed. So prove
  # BOTH halves — the provenance really was emitted (the path ran) and it landed inside $_root.
  _g=no; [[ -s "$_root/github-env" ]] && _g=yes
  t "the merge path really recorded base provenance" "yes" "$_g"
  case "$(cat "$_root/github-env" 2>/dev/null)" in
    *"CI_BASE_SHA="*) _g=yes ;; *) _g=no ;;
  esac
  t "…as CI_BASE_SHA, into THIS self-test's \$GITHUB_ENV and not the job's" "yes" "$_g"

  # ── PROVENANCE (fix_a_red_is_reported_without_the_base_it_was_measured_against) ───────────────
  # ⚠ DRIVEN, because an emitter that writes nothing looks exactly like one that was never reached.
  # These call the helper directly: what is under test is the CONTRACT — a sha when one is known,
  # the literal `unknown` when none is, and silence outside Actions — not git's behaviour.
  _pv="$(mktemp)"
  ( GITHUB_ENV="$_pv" _record_base_provenance "abc1234" "main" )
  t "a known base is emitted as CI_BASE_SHA"  "CI_BASE_SHA=abc1234" "$(grep '^CI_BASE_SHA=' "$_pv")"
  t "…with the ref beside it"                 "CI_BASE_REF=main"    "$(grep '^CI_BASE_REF=' "$_pv")"
  # ⚠ The TIMESTAMP is taken at merge time, not at comment time — on a 20-minute suite those differ,
  # and the one that matters is when the tree was measured.
  _pvt="$(grep -c '^CI_BASE_MEASURED_AT=20[0-9][0-9]-' "$_pv")"
  t "…and the moment it was measured"         "1" "$_pvt"

  # ⚠ THE FAIL-OPEN PATHS MUST SAY `unknown`, NOT NOTHING AND NOT A PLAUSIBLE SHA. This step fails
  # open on a fetch hiccup, so "we could not establish what we tested against" is a REAL outcome and
  # is a different fact from "we tested against X". A reporting step that cannot tell them apart
  # will state a base it never had.
  : > "$_pv"
  ( GITHUB_ENV="$_pv" _record_base_provenance "" "release/v0.175" )
  t "an UNESTABLISHED base is emitted as unknown" "CI_BASE_SHA=unknown" "$(grep '^CI_BASE_SHA=' "$_pv")"
  t "…and still names the ref it could not read"  "CI_BASE_REF=release/v0.175" "$(grep '^CI_BASE_REF=' "$_pv")"

  # ⚠ NEGATIVE CONTROL: outside Actions it must write nothing at all and must not fail. The script
  # runs in this very self-test and on developers' machines; a helper that appended to a stray path
  # or returned non-zero there would break the thing it is instrumenting.
  : > "$_pv"
  ( unset GITHUB_ENV; _record_base_provenance "abc1234" "main" ); _pvrc=$?
  t "outside Actions it writes nothing"       "" "$(cat "$_pv")"
  t "…and does not fail"                      "0" "$_pvrc"
  rm -f "$_pv"

  rm -rf "$_root"; trap - EXIT
  (( fails == 0 )) && { printf 'ci-merge-pr-base: selftest ok\n'; exit 0; }
  printf 'ci-merge-pr-base: selftest FAILED\n' >&2; exit 1
fi

# ⚠ RUN ONLY WHEN EXECUTED, NEVER WHEN SOURCED — and this guard is here because its absence bit
# within minutes of the file being written. Mutation-testing the pure function meant sourcing this
# file to call `base_ref_for`, and sourcing it ran the merge: it fetched origin/main and committed a
# real merge into the author's working branch. Harmless there (unpushed, and dropped immediately),
# but the same shape reaches further — anything that sources this to reuse `base_ref_for`, a future
# self-test, a debugging one-liner, all silently mutate the repository they are inspecting.
#
# ⚠ AND IT IS THE DAY'S OWN THEME POINTING BACK AT ME: a file that performs work merely by being READ
# gives no way to ask it a question without also changing the answer.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  ci_merge_pr_base
fi
