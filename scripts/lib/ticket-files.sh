#!/usr/bin/env bash
# ── ARE THE TICKET FILES PRESENT, RETIRED, OR MISSING? ───────────────────────────────────────────
# (infra_the_file_reading_gates_are_green_with_and_without_the_ticket_files_so_main_stays_mergeable_the_morning_after)
#
#   . scripts/lib/ticket-files.sh
#   ticket_files_state [<root>]              -> present | retired | missing   (judges the WORKING TREE at <root>)
#   ticket_files_state --ref <commit>        -> present | retired | missing   (judges THAT COMMIT's tree, never the checkout)
#   ticket_files_gate_arm <gate> <HELD|UNHELD|HAND-OFF|MOOT> <sentence> [--ref <commit> | --root <dir>]
#                                            -> files present: returns 0, says nothing, the gate carries on
#                                               RETIRED: prints the NOT JUDGED HERE line TO STDERR and EXITS 0
#                                                        (stdout is left clean: --ids-only / --json callers parse it)
#                                               MISSING: prints the refusal and EXITS 2
#                                               (a class that is not one of the four: EXITS 2 — misuse)
#   bash scripts/lib/ticket-files.sh --self-test
#
# ⚠ THREE STATES, AND THE MIDDLE ONE IS THE WHOLE REASON THIS FILE EXISTS. Nine verify gates refuse
# with "features/ does not exist — refusing to report clean" (exit 2), and every one of those arms
# was written for a BROKEN CHECKOUT: a tree with no ticket directory, which no PR can legitimately
# produce, so a green there would be coverage for ever from a population of nothing. Each arm says
# so in its own words — "if the ticket files have moved to the ledger database, this gate needs
# RELOCATING, not silencing." Measured 2026-09-16 on origin/main 1c9c7b842 with `git rm -r features/`,
# invoked exactly as verify.sh invokes them, under a pull_request event: 11 of the 27 file-reading
# gates in the REQUIRED check are red (9 exit 2, 2 exit 1), 0 of 18 invocations red with the files
# present on the same sha. `verify` is required with strict up-to-date, so the morning after the
# deletion merges NOTHING can merge until those arms know the difference between "gone by accident"
# and "gone on purpose".
#
# ⚠ ABSENCE ALONE MUST NOT MEAN RETIRED. That would silence exactly the arm those authors built. The
# deliberate act is a MARKER, added by the deletion commit in the same commit that removes the files:
#
#     infra/ledger-db/TICKET-FILES-RETIRED.md
#
# carrying the parent sha, the date, the PR number and the rollback sentence (R5 in
# docs/cutover-signoff-criteria.md: `git revert <deletion commit>` restores the files as of the
# parent; every row write after the merge is drift the revert cannot see). So:
#
#     features/ exists                       -> present   (the gate reads the files, as today)
#     features/ absent, marker in the tree   -> retired   (the gate says NOT JUDGED HERE, exit 0)
#     features/ absent, no marker            -> missing   (the gate refuses, exit 2, as today)
#
# and a `git revert` of the deletion restores the files AND removes the marker in one step. The
# NEGATIVE CONTROL is in the self-test below: marker present WITH features/ reads `present`, because
# a rollback that restores the files must never leave the gates in the retired state.
#
# ⚠ THE RETIRED LINE IS NOT "ok". A gate that has no subject prints exactly one line, `NOT JUDGED
# HERE — the ticket files are RETIRED`, naming what holds the property now — and "holds" is a
# claim about a store the gate does not check, so every successor was DRIVEN ONCE (Carl's
# condition, 2026-09-16: a row that would have failed the retired gate must fail its successor).
# Driven as ledger_owner in rolled-back transactions against the live ledger, control update accepted:
#
#     HELD    area                 ticket_area_fkey                          uncontrolled area REFUSED
#     HELD    verification         text[]                                    a string REFUSED at parse
#     HELD    claimed_by (roster)  ticket_claimed_by_fkey                    unrostered name REFUSED
#     HELD    park residue         park_columns_are_clear_when_not_parked    reason on a non-parked row REFUSED
#     UNHELD  verified_by_pr       (column only)                             passing + NULL pointer ACCEPTED
#     UNHELD  passing left live    (no constraint; archive verb is a process) passing, no outcome ACCEPTED
#     UNHELD  claim by a retiree   (fkey still matches)                      — accepted loss, mitigated by 147 (release_retired_claim)
#     MOOT    3 rules whose SUBJECT is gone: escapes in ticket files, the mirror payload, the file corpus
#
# ⚠ THE CLASS IS AN ARGUMENT, NOT PROSE (Carl, 2026-09-16, when a second author adopted this lib):
# every retired line carries exactly one of four tokens in one spelling — `HELD:`, `UNHELD:`,
# `HAND-OFF:`, `MOOT:` — so "which properties are unheld right now" is `grep UNHELD:` across a CI
# log, not a reading exercise. A successor the author cannot demonstrate IS `UNHELD`, said out loud; the drive
# is what upgrades it. A HELD successor makes its gate a RETIREMENT CANDIDATE for the deletion PR;
# an UNHELD one is a property the repo currently does not hold anywhere, which is honest and
# greppable, where a false "held" is the vacuous pass wearing a different word. HAND-OFF is neither:
# the property moves to a named owner's design and the line says whose. MOOT is the narrow fourth,
# and it has a DEFINITIONAL TEST (Carl, 2026-09-16) so it cannot become the escape hatch for an
# inconvenient UNHELD:
#
#     MOOT = the SUBJECT of the rule exists in NO store. Not "nobody checks it", not "it does not
#     matter now" — the thing the rule was ABOUT is gone, and the line must NAME the vanished
#     subject. If the subject exists anywhere — a column, a file, a ref, an API — it is UNHELD, and
#     the absent reader is the gap.
#
# Falsifiable: escapes in ticket files, the file→row mirror payload, and a schema compared against
# the file corpus pass it; "the row does not enforce X" does not — X's subject is a column, so that
# is UNHELD. Calling a MOOT rule HELD would be false; calling it UNHELD would bury the real three
# under noise, and `grep UNHELD:` is the sweep. Two of the twelve:
# check-closing-keyword-archives (no row-side twin in CI — with `Closes #<live>` it is red with the
# files and was SILENTLY GREEN without them, driven 2026-09-16) and check-head-ref-is-not-a-live-lock
# (the lock leaves the file under Saffron's ticket; if the branch stays the lock, the arm is the
# wrong shape and the gate says so). A reader grepping a green CI log for `ok` finds none of these;
# grepping for `NOT JUDGED HERE` finds all of them, which is the intended asymmetry.
#
# ⚠⚠ THE INVARIANT BELOW IS TRUE-AS-WRITTEN AND FALSE-AS-READ, AND THAT IS WORSE THAN AN UNDOCUMENTED
# ONE — it is exactly the sentence a careful reader trusts instead of checking. Corrected 2026-09-18
# (fix_a_single_ticket_file_silently_un_retires_the_whole_store). What it describes is CONTENT READS
# racing the arm. What it does not say is that most callers only REACH the arm when their population
# comes back EMPTY: the arm is their answer to "I found no tickets — is that because there are none,
# or because the store is gone?" So the store is consulted on the empty path and skipped on the
# non-empty one. Before the cutover those were the same question, because a non-empty population
# PROVED the files were there. With the retirement marker in the tree, one stray file makes the
# population non-empty while the store is retired — and the arm is never called at all. DRIVEN over
# all 16 arm-using gates: 12 refuse, 1 judged the stray and passed, 1 needs a PR context and was not
# measured, 2 do not judge ticket files. The general form, which outlives this lib: A PREDICATE
# CANNOT HELP A CALLER THAT DOES NOT CALL IT — so check where a shared guard is INVOKED, not only
# what it returns. The population-independent question is now asked once, early, by
# scripts/check-ticket-file-store-is-coherent.sh, which refuses before any ticket gate runs.
# ⚠ AND THE REASON IT COULD NOT HAVE BEEN CAUGHT WHEN IT WAS WRITTEN IS THE USEFUL PART: population
# non-empty AND store retired was an IMPOSSIBLE combination while the files WERE the store. The
# two-state invariant was true when written. Every assumption the cutover invalidated has this shape,
# which is what makes them findable — look for sentences that were true of a world with one store.
#
# ⚠⚠ THE INVARIANT EVERY CALLER MUST PRESERVE (Carl, 2026-09-16): THE ARM DECIDES ON ITS STORE BEFORE
# ANY CONTENT READ OF THE TICKET FILES ON THE REQUIRED-CHECK PATH. It is an argument from control
# flow, not from a survey: on the shipped state — worktree retired, every historical ref still
# carrying the files — a gate that reads `origin/main:features/<id>.json` or walks branch refs
# (check-closing-keyword-archives' merge_raised_unmerged reads EVERY branch's features/, on purpose)
# would find files and produce a confident, plausible, wrong table. It does not, only because the
# arm fires first. A refactor that moves such a read above the arm re-opens the silent green with
# no red anywhere. Enumerated 2026-09-16 across the twelve callers: the only origin/main CONTENT read
# that is reached on a retired tree is inside check-ticket-verification-is-a-list's SELF-TEST, which
# verify.sh does not run. Path-only diffs against the merge-base (parked-row, ticket-area,
# last-verified-commit) are executed before the arm and cannot fail on absence.
#
# ⚠ ONE PREDICATE, NOT ELEVEN. Every gate goes through `ticket_files_state`; none re-implements
# `[[ -d features ]]` for the cutover decision. The marker's name lives here and nowhere else, so
# the deletion PR has one file to add and one place to read what it must contain.
#
# ⚠ THE STORE IS AN ARGUMENT, BECAUSE THE FIRST VERSION JUDGED THE CHECKOUT FOR EVERY CALLER. Found
# by Anthony adopting it for check-epic-closure.sh, which also takes `--ref <commit>`: on that path
# the working tree can still hold features/ while the ref does not, so the arm said `present`, the
# gate read the ref, found nothing, and went SILENTLY GREEN — the exact bug the marker exists to
# prevent, reintroduced through the fix. A guard that judges a different store from the one its
# subject comes from is the class of feature-ticket.sh:2111 and the `_rel_archived`/`archive_hits`
# pair: same words, different store, opposite behaviour. So a caller that reads a ref passes
# `--ref <commit>` and the predicate judges THAT tree with `git cat-file -e`, never the checkout; the
# self-test's cell for it is "worktree present, ref absent → the ref answer is NOT present".

TICKET_FILES_RETIRED_MARKER="${TICKET_FILES_RETIRED_MARKER:-infra/ledger-db/TICKET-FILES-RETIRED.md}"

# present | retired | missing — judged on the WORKING TREE at $1 (default: the current directory),
# which is the tree the calling gate is standing on; or, with `--ref <commit>`, on that commit's
# tree via git, so a gate that reads a ref asks about the store it reads. Gates run from the repo
# root; this does not `cd`. A ref git cannot resolve is `missing` — not present, never a pass.
ticket_files_state() { # [root] | --ref <commit>
  local _f=0 _m=0
  if [[ "${1:-}" == --ref ]]; then
    local ref="${2:?ticket_files_state --ref needs a commit}"
    if git cat-file -e "$ref:features" 2>/dev/null; then _f=1; fi
    if git cat-file -e "$ref:$TICKET_FILES_RETIRED_MARKER" 2>/dev/null; then _m=1; fi
  else
    local root="${1:-.}"
    if [[ -d "$root/features" ]]; then _f=1; fi
    if [[ -f "$root/$TICKET_FILES_RETIRED_MARKER" ]]; then _m=1; fi
  fi
  # ⚠ BOTH ARE READ BEFORE EITHER IS ANSWERED ON, which is the whole change. The old shape tested
  # the directory FIRST and returned, so the marker was never consulted once a single file existed
  # and one stray ticket outranked the deliberate act of retirement — silently, in the reassuring
  # direction. Presence-first is still correct when there is no marker (the pre-cutover world, and a
  # true `git revert` of the deletion, which removes the marker in the same commit); it is only the
  # BOTH case that changes, and before the cutover that case could not occur.
  if (( _f && _m )); then printf 'anomaly\n'; return 0; fi
  if (( _f )); then printf 'present\n'; return 0; fi
  if (( _m )); then printf 'retired\n'; return 0; fi
  printf 'missing\n'
}

# How many ticket files the store actually holds — used only to make the anomaly message actionable
# ("a directory of 1 against 2,934 rows" is a different situation from a restored corpus). Never a
# verdict on its own: no threshold here decides anything, because any threshold would be invented.
ticket_files_count() { # [root] | --ref <commit>
  if [[ "${1:-}" == --ref ]]; then
    git ls-tree -r --name-only "${2:?}" -- features/ 2>/dev/null | grep -c . || true
  else
    find "${1:-.}/features" -name '*.json' 2>/dev/null | grep -c . || true
  fi
}

# The standard arm. Call it exactly where the gate used to test `[[ ! -d features ]]`:
#
#     ticket_files_gate_arm check-foo HELD   "ticket_area_fkey REFERENCES ledger.area(name) — driven <date>, REFUSED"
#     ticket_files_gate_arm check-bar UNHELD "no constraint requires verified_by_pr; a row reader is the follow-up"
#     ticket_files_gate_arm check-baz HAND-OFF "the lock leaves the file under <ticket> (Saffron)"
#     ticket_files_gate_arm check-qux MOOT   "the rule's subject was the file→row mirror payload; there is no payload"
#
# ⚠ IT EXITS THE CALLER on the retired (0) and missing (2) states, and returns 0 on present. A
# return code the caller had to test was the first shape, and it was wrong under `set -e`: a bare
# `return 1` for "files present, carry on" is a failing simple command, and the gate died on the
# ordinary path in a tree with the files there. Exiting from inside the arm is the shape every
# `die` in this repo already has; the self-test drives it in subshells for that reason.
#
# The sentence is the gate author's honest answer to "what holds this property now?" — a constraint
# name with the date it was DRIVEN, a follow-up for UNHELD, an owner for HAND-OFF. Printed verbatim
# after the class token. An unknown class is a misuse and exits 2 rather than printing something a
# grep would misread.
ticket_files_gate_arm() { # <gate-name> <HELD|UNHELD|HAND-OFF|MOOT> <sentence> [--ref <commit> | --root <dir>]
  local gate=$1 class=$2 sentence=$3 state
  case "$class" in
    HELD|UNHELD|HAND-OFF|MOOT) ;;
    *) printf '%s: ticket_files_gate_arm called with class %q — must be HELD, UNHELD, HAND-OFF or MOOT (scripts/lib/ticket-files.sh)\n' "$gate" "$class" >&2; exit 2 ;;
  esac
  local where="the tree"
  # ⚠ THE COUNT MUST ASK THE SAME STORE THE STATE CAME FROM. This library's own scar: a guard that
  # judges a different store from the one its subject comes from is the class it was rewritten to
  # avoid (see the --ref note in the header). So the args are captured here, beside the state, and
  # never re-derived at the point of printing.
  local -a _tf_count_args=()
  if [[ "${4:-}" == --ref ]]; then
    state="$(ticket_files_state --ref "${5:?ticket_files_gate_arm --ref needs a commit}")"; where="$5"
    _tf_count_args=(--ref "$5")
  elif [[ "${4:-}" == --root ]]; then
    # A gate that reads a directory other than its cwd (an overridable root, a fixture) judges THAT
    # directory — same rule as --ref: the store the subject comes from, never a different one.
    state="$(ticket_files_state "${5:?ticket_files_gate_arm --root needs a directory}")"; where="$5"
    _tf_count_args=("$5")
  elif [[ $# -gt 3 ]]; then
    printf '%s: ticket_files_gate_arm: unexpected argument %q — the options are --ref <commit> and --root <dir>\n' "$gate" "$4" >&2; exit 2
  else
    state="$(ticket_files_state)"
  fi
  case "$state" in
    present) return 0 ;;
    anomaly)
      # ⚠ THE TWO STORES DISAGREE AND THIS PREDICATE CANNOT KNOW WHICH IS TRUE, so it answers as
      # neither. The marker says the files were retired deliberately; the directory says they are
      # here. Answering `present` is what this gate used to do, and it pointed sixteen stood-down
      # gates at whatever the directory happened to hold — a confident clean from a population of
      # one, which is the exact failure the marker was introduced to prevent, arriving by the other
      # door. Answering `retired` would be as bad in the opposite direction: a real rollback
      # restores the corpus, and telling the gates to stop looking would silence them over a live
      # store. "Could not tell" is its own state and it exits 2, the same as `missing`.
      #
      # ⚠ IT IS LOUD AND IT BLOCKS, AND BOTH REMEDIES ARE ORDINARY. Finish the rollback (remove the
      # marker — `git revert` of the deletion commit does it in one step) or remove the stray file.
      # Nothing here deletes anything: a predicate that repaired the tree it was asked to describe
      # would be choosing between two legitimate intentions on the author's behalf.
      printf '%s: THE TICKET-FILE STORE IS IN AN ANOMALOUS STATE — refusing to judge.\n' "$gate" >&2
      printf '  %s is in %s, AND features/ is there too (%s ticket file(s)).\n' \
        "$TICKET_FILES_RETIRED_MARKER" "$where" "$(ticket_files_count ${_tf_count_args[@]+"${_tf_count_args[@]}"})" >&2
      printf '  Those two stores disagree, so this gate cannot say whether the files are a RESTORED\n' >&2
      printf '  corpus to judge or a STRAY that outranked the retirement. It will not guess: judging a\n' >&2
      printf '  stray produces a true statement about a store that should not exist, and standing down\n' >&2
      printf '  over a restored one silences a live gate. Pick the one you meant:\n' >&2
      printf '    rolling back  -> remove %s (git revert of the deletion commit does both at once)\n' "$TICKET_FILES_RETIRED_MARKER" >&2
      printf '    a stray file  -> remove features/ ; the requirement lives in ledger.ticket\n' >&2
      printf '  %s: %s\n' "$class" "$sentence" >&2
      exit 2 ;;
    retired)
      # ⚠ STDERR, NOT STDOUT. Found by Anthony routing check-epic-closure.sh --ids-only through this:
      # its stdout is a bare id list that init.sh reads, and the first version put this sentence INTO
      # that list — reported to every agent at session start as a finished epic to close. A gate's
      # stdout is not always prose (--ids-only, --json, --list); its stderr always is. The exit code
      # is the verdict CI reads and stays 0 here; the sentence goes where a human will see it and a
      # parser will not. A caller that WANTS it on stdout redirects 2>&1 itself.
      printf '%s: NOT JUDGED HERE — the ticket files are RETIRED (%s is in %s, features/ is not). %s: %s\n' \
        "$gate" "$TICKET_FILES_RETIRED_MARKER" "$where" "$class" "$sentence" >&2
      exit 0 ;;
    *)
      printf '%s: features/ does not exist — refusing to report clean.\n' "$gate" >&2
      printf '  This gate reads ticket FILES. With no ticket directory it can only ever pass, having\n' >&2
      printf '  judged nothing, and a rule that cannot fail reads as coverage for ever.\n' >&2
      printf '  THE CAUSE IS OUTSIDE YOUR DIFF unless you deleted features/ yourself. If this tree IS the\n' >&2
      printf '  cutover, the deletion commit must add %s\n' "$TICKET_FILES_RETIRED_MARKER" >&2
      printf '  (scripts/lib/ticket-files.sh says what it carries); then this gate reports NOT JUDGED HERE.\n' >&2
      exit 2 ;;
  esac
}

# ── self-test ────────────────────────────────────────────────────────────────────────────────────
_tf_self_test() {
  local tmp fails=0
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/ticket-files-selftest.XXXXXX")"
  trap 'rm -rf "$tmp"' RETURN
  _tf_expect() { # <label> <want> <got>
    if [[ "$2" == "$3" ]]; then printf '  ok    %s -> %s\n' "$1" "$3"
    else printf '  FAIL  %s -> %s (wanted %s)\n' "$1" "$3" "$2"; fails=$((fails+1)); fi
  }
  mkdir -p "$tmp/present/features" "$tmp/retired/infra/ledger-db" "$tmp/missing" "$tmp/both/features" "$tmp/both/infra/ledger-db"
  : > "$tmp/retired/infra/ledger-db/TICKET-FILES-RETIRED.md"
  : > "$tmp/both/infra/ledger-db/TICKET-FILES-RETIRED.md"
  echo '{}' > "$tmp/both/features/stray.json"
  _tf_expect "features/ exists"                    present "$(ticket_files_state "$tmp/present")"
  _tf_expect "no features/, marker in the tree"    retired "$(ticket_files_state "$tmp/retired")"
  _tf_expect "no features/, no marker"             missing "$(ticket_files_state "$tmp/missing")"
  # ⚠ THE BOTH CELL, AND IT USED TO ASSERT `present`. The reasoning then was that a partial rollback
  # must not leave the gates stood down over a restored corpus — which is right, and is exactly half
  # the story. The other half is that ONE STRAY FILE reaches the identical state, and answering
  # `present` there points every stood-down gate at whatever the directory holds. The two cases are
  # INDISTINGUISHABLE to this predicate, so it now says so instead of picking the reassuring one.
  # (fix_a_single_ticket_file_silently_un_retires_the_whole_store)
  _tf_expect "marker AND features/ — the two stores disagree, so neither answer is asserted" anomaly "$(ticket_files_state "$tmp/both")"
  # ⚠ POSITIVE CONTROLS, NAMED AS SUCH: the fix must not turn retirement into an anomaly, and must
  # not regress the pre-cutover world. Both were green before this change and must stay green.
  _tf_expect "POSITIVE CONTROL: marker, no features/ — still plain retired"  retired "$(ticket_files_state "$tmp/retired")"
  _tf_expect "POSITIVE CONTROL: features/, no marker — the pre-cutover world is still present" present "$(ticket_files_state "$tmp/present")"
  _tf_expect "the anomaly count names how many files are there" 1 "$(ticket_files_count "$tmp/both")"
  # The arm on an anomaly: exits 2, says ANOMALOUS, names BOTH remedies, and never says ok.
  local aout arc
  aout="$(cd "$tmp/both" && ticket_files_gate_arm check-probe HELD "the row holds it" 2>&1 >/dev/null; echo "NOT-REACHED")"; arc=$?
  _tf_expect "arm on anomaly: exit 2 (could-not-tell is not a pass)" 2 "$arc"
  _tf_expect "arm on anomaly: exits the caller"                      0 "$(grep -c 'NOT-REACHED' <<<"$aout" || true)"
  _tf_expect "arm on anomaly: names the state loudly"                1 "$(grep -c 'ANOMALOUS STATE' <<<"$aout")"
  _tf_expect "arm on anomaly: offers the rollback remedy"            1 "$(grep -c 'rolling back' <<<"$aout")"
  _tf_expect "arm on anomaly: offers the stray-file remedy"          1 "$(grep -c 'a stray file' <<<"$aout")"
  _tf_expect "arm on anomaly: never says ok"                         0 "$(grep -ciE '\bok\b' <<<"$aout" || true)"
  _tf_expect "arm on anomaly: never claims NOT JUDGED HERE (that is the retired line, and it exits 0)" \
             0 "$(grep -c 'NOT JUDGED HERE' <<<"$aout" || true)"
  _tf_expect "arm on anomaly: stdout stays clean for --ids-only callers" "" "$(cd "$tmp/both" && ticket_files_gate_arm check-probe HELD "x" 2>/dev/null || true)"
  # ⚠ THE ANOMALY MUST NOT DELETE ANYTHING. A predicate that repaired the tree it was asked to
  # describe would be choosing between two legitimate intentions for the author.
  _tf_expect "arm on anomaly: the tree is untouched — the file is still there" 1 "$(ticket_files_count "$tmp/both")"
  _tf_expect "arm on anomaly: the tree is untouched — the marker is still there" 1 "$(ls "$tmp/both/infra/ledger-db/TICKET-FILES-RETIRED.md" 2>/dev/null | grep -c . || true)"
  # The arm's three return codes, and that the retired line never says "ok".
  local out rc
  out="$(cd "$tmp/present" && ticket_files_gate_arm check-probe HELD "successor" 2>&1; echo "carried-on")"; rc=$?
  _tf_expect "arm on present: return 0, silent, the gate carries on" "0:carried-on" "$rc:$out"
  out="$(cd "$tmp/present" && set -e && ticket_files_gate_arm check-probe HELD "successor" 2>&1; echo "carried-on")"; rc=$?
  _tf_expect "arm on present under set -e: still carries on" "0:carried-on" "$rc:$out"
  # stdout must stay EMPTY on the retired path — a parsed stdout (--ids-only) must not gain a sentence.
  out="$(cd "$tmp/retired" && ticket_files_gate_arm check-probe HELD "the row holds it" 2>/dev/null)"; rc=$?
  _tf_expect "arm on retired: stdout is empty (the line is on stderr)" "0:" "$rc:$out"
  out="$(cd "$tmp/retired" && ticket_files_gate_arm check-probe HELD "the row holds it" 2>&1; echo "NOT-REACHED")"; rc=$?
  _tf_expect "arm on retired: exit 0, nothing after it runs" 0 "$rc"
  _tf_expect "arm on retired: exits the caller"   0 "$(grep -c 'NOT-REACHED' <<<"$out" || true)"
  _tf_expect "arm on retired: names NOT JUDGED HERE" 1 "$(grep -c 'NOT JUDGED HERE' <<<"$out")"
  _tf_expect "arm on retired: carries the successor" 1 "$(grep -c 'the row holds it' <<<"$out")"
  _tf_expect "arm on retired: never says ok"       0 "$(grep -ciE '\bok\b' <<<"$out" || true)"
  _tf_expect "arm on retired: the class token is greppable" 1 "$(grep -c 'RETIRED (.*). HELD: the row holds it' <<<"$out")"
  # ⚠ UNHELD IS A FIRST-CLASS STATE, one spelling, so a sweep for unheld properties is a grep.
  out="$(cd "$tmp/retired" && ticket_files_gate_arm check-probe UNHELD "no constraint yet" 2>&1)"; rc=$?
  _tf_expect "arm on retired, UNHELD: exit 0, token printed" "0:1" "$rc:$(grep -c '\. UNHELD: no constraint yet' <<<"$out")"
  out="$(cd "$tmp/retired" && ticket_files_gate_arm check-probe HAND-OFF "somebody's design" 2>&1)"; rc=$?
  _tf_expect "arm on retired, HAND-OFF: exit 0, token printed" "0:1" "$rc:$(grep -c '\. HAND-OFF: somebody' <<<"$out")"
  out="$(cd "$tmp/retired" && ticket_files_gate_arm check-probe MOOT "no subject remains" 2>&1)"; rc=$?
  _tf_expect "arm on retired, MOOT: exit 0, token printed" "0:1" "$rc:$(grep -c '\. MOOT: no subject remains' <<<"$out")"
  # …and a made-up class is a MISUSE, refused even on a present tree, never printed as if it were one.
  out="$(cd "$tmp/present" && ticket_files_gate_arm check-probe held "lower-case is not the token" 2>&1)"; rc=$?
  _tf_expect "arm with an unknown class: exit 2 on any tree" 2 "$rc"
  out="$(cd "$tmp/retired" && ticket_files_gate_arm check-probe "the row holds it" 2>&1)"; rc=$?
  _tf_expect "arm with the old two-argument shape: exit 2, not a silent HELD" 2 "$rc"
  out="$(cd "$tmp/missing" && ticket_files_gate_arm check-probe HELD "successor" 2>&1 >/dev/null; echo "NOT-REACHED")"; rc=$?
  _tf_expect "arm on missing: exit 2"              2           "$rc"
  _tf_expect "arm on missing: exits the caller"    0 "$(grep -c 'NOT-REACHED' <<<"$out" || true)"
  _tf_expect "arm on missing: refuses to report clean" 1 "$(grep -c 'refusing to report clean' <<<"$out")"
  _tf_expect "arm on missing: names the marker to add" 1 "$(grep -c 'TICKET-FILES-RETIRED.md' <<<"$out")"
  # ── the STORE cell: a caller that reads a REF must be answered about the ref, never the checkout ──
  # Built as a real repo: commit 1 has features/, commit 2 deletes it and adds the marker; then the
  # checkout at commit 2 gets an UNTRACKED features/ back. Worktree says present; the ref must not.
  local repo="$tmp/repo"
  ( set -e; mkdir -p "$repo" && cd "$repo" && git init -q && git config user.email t@t && git config user.name t
    mkdir features && echo '{}' > features/x.json && git add -A && git commit -qm one
    git rm -rq features && mkdir -p infra/ledger-db && : > infra/ledger-db/TICKET-FILES-RETIRED.md && git add -A && git commit -qm two
    mkdir features ) 2>/dev/null
  # ⚠ THIS CELL USED TO ASSERT `present` AND NOW ASSERTS `anomaly`, and the change is the whole
  # ticket rather than a regression: the checkout carries the retirement marker AND an untracked
  # features/, which is exactly "one stray file outranked the marker". The cell's actual purpose —
  # that the worktree and the ref answer DIFFERENTLY, so a gate must ask about the store it reads —
  # is untouched and is asserted on the next line, which still reads retired from the ref.
  _tf_expect "store cell: worktree with the marker AND an untracked features/ is the anomaly" anomaly "$(cd "$repo" && ticket_files_state)"
  _tf_expect "store cell: --ref HEAD (files deleted, marker added) reads RETIRED, not present" retired "$(cd "$repo" && ticket_files_state --ref HEAD)"
  _tf_expect "store cell: --ref HEAD~1 reads present"  present "$(cd "$repo" && ticket_files_state --ref HEAD~1)"
  _tf_expect "store cell: an unresolvable ref is missing, never present" missing "$(cd "$repo" && ticket_files_state --ref no-such-ref)"
  # ⚠ THE --ref PATH HAS THE SAME ORDERING AND IS DRIVEN SEPARATELY, because a fix to the working-tree
  # arm alone leaves it loaded for every gate that judges a commit (check-epic-closure, the sync
  # janitor, the pinned-signoff check). Its own repo, so the three commits above keep their offsets:
  # here a THIRD commit puts one ticket file back while the marker stays — a raise PR merging after
  # the deletion, an old branch landing, a restore. This is the shape that reached main.
  local repo_anom="$tmp/repo-anom"
  ( set -e; mkdir -p "$repo_anom" && cd "$repo_anom" && git init -q && git config user.email t@t && git config user.name t
    mkdir features && echo '{}' > features/x.json && git add -A && git commit -qm one
    git rm -rq features && mkdir -p infra/ledger-db && : > infra/ledger-db/TICKET-FILES-RETIRED.md && git add -A && git commit -qm two
    mkdir features && echo '{}' > features/stray.json && git add -A && git commit -qm three ) 2>/dev/null
  _tf_expect "store cell: --ref where ONE file came back with the marker still in — anomaly, not present" \
             anomaly "$(cd "$repo_anom" && ticket_files_state --ref HEAD)"
  _tf_expect "store cell: --ref counts the files it found in THAT commit" 1 "$(cd "$repo_anom" && ticket_files_count --ref HEAD)"
  _tf_expect "store cell: POSITIVE CONTROL — the commit BEFORE it still reads plain retired" \
             retired "$(cd "$repo_anom" && ticket_files_state --ref HEAD~1)"
  local roa rorc
  roa="$(cd "$repo_anom" && ticket_files_gate_arm check-probe HELD "successor" --ref HEAD 2>&1 >/dev/null; echo "NOT-REACHED")"; rorc=$?
  _tf_expect "store cell: the arm on an anomalous REF exits 2 and does not run on" \
             "2:1:0" "$rorc:$(grep -c 'ANOMALOUS STATE' <<<"$roa"):$(grep -c 'NOT-REACHED' <<<"$roa" || true)"
  out="$(cd "$repo" && ticket_files_gate_arm check-probe HELD "successor" --ref HEAD 2>&1; echo "NOT-REACHED")"; rc=$?
  _tf_expect "store cell: the arm with --ref exits 0 on the retired ref while the checkout has files" "0:0" "$rc:$(grep -c NOT-REACHED <<<"$out" || true)"
  _tf_expect "store cell: the arm names the ref it judged" 1 "$(grep -c 'is in HEAD, features/ is not' <<<"$out")"
  out="$(cd "$tmp/present" && ticket_files_gate_arm check-probe HELD "successor" --root "$tmp/retired" 2>&1; echo "NOT-REACHED")"; rc=$?
  _tf_expect "store cell: --root judges that directory, not the cwd (cwd present, root retired → exit 0, arm fired)" "0:0" "$rc:$(grep -c NOT-REACHED <<<"$out" || true)"
  out="$(cd "$repo" && ticket_files_gate_arm check-probe HELD "successor" --tree x 2>&1)"; rc=$?
  _tf_expect "store cell: an unknown option is a misuse, exit 2" 2 "$rc"
  if (( fails )); then printf 'ticket-files.sh: self-test FAILED (%d)\n' "$fails"; return 1; fi
  printf 'ticket-files.sh: self-test ok — FOUR states told apart in both stores, marker-AND-files is an anomaly that refuses rather than a silent present, a ref is judged as a ref, the retired line never says ok\n'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  . "$(dirname "${BASH_SOURCE[0]}")/selftest-flag.sh"
  if selftest_requested "$@"; then _tf_self_test; exit $?; fi
  printf 'scripts/lib/ticket-files.sh is a library — source it, or run --self-test\n' >&2
  exit 2
fi
