#!/usr/bin/env bash
# A self-test that nothing runs is not a test.
#
#   bash scripts/check-selftests-are-invoked.sh              # the sweep
#   bash scripts/check-selftests-are-invoked.sh --list       # the verify-tier entries, for verify.sh
#   bash scripts/check-selftests-are-invoked.sh --selftest   # the pure verdict
#
# ── WHY ─────────────────────────────────────────────────────────────────────────────────────────
#
# 2026-08-19: two agents independently found one each within an hour — `merge-queue-metrics.sh`
# (14 cases with named negative controls) and `page-owner.sh` (the assertions that keep a dead
# runner from being reported as a broken diff). ⚠ TWO INDEPENDENT FINDS IN AN HOUR IS A SAMPLE,
# NOT TWO INSTANCES, so the population was measured instead of the two being fixed and forgotten.
#
# ⚠ AND WIRING THEM ALL IN IS THE WRONG FIX ON ITS OWN: it leaves the next one to be found by
# whoever happens to look. This is the part that does not need anyone to look.
#
# ── ⚠ THE HEADLINE INSTANCE IS THE ONE THAT CURATES THE GATES ───────────────────────────────────
#
# `scripts/preflight.sh` — 127 curated checks, membership established empirically, an anti-vacuity
# floor so it cannot pass having run nothing — HAS NO PRODUCTION CALLER. Every reference to it is a
# comment, a doc, or `merge-batch.sh:1178`, which sits inside `_self_test()` and only asserts that
# preflight REFUSES to run below its floor. docs/design/verify-duration-and-preflight.md shows the
# `- run: bash scripts/preflight.sh` that was planned and never built.
#
# ⚠ SO AN ENTRY IN preflight.sh IS REGISTRATION IN A STAGED LIST, NOT WIRING — and this file counts
# it as such. I had described adding entries there as "wiring" in four of my own PRs before
# measuring it, and corrected all four. A list that looks like a gate is worse than no list.
#
# ── THREE STATES, AND THE THIRD IS THE ONE THAT KEEPS THIS USABLE ───────────────────────────────
#
#   gated    something invokes it with a self-test flag
#   exempt   listed in scripts/selftest-tiers.txt as `nowhere`, WITH A REASON
#   ungated  neither — and that is the failure
#
# ⚠ `exempt` MUST STAY EXPRESSIBLE. A manual disaster-recovery script's self-test may genuinely not
# belong on the critical path, and forcing one in is how a gate becomes latency nobody defends —
# which is how the last few ledger gates lost their authority. The reason is mandatory precisely so
# the exemption cannot be used as a silent mute.
#
# ── ⚠ COMMENTS ARE STRIPPED BEFORE SEARCHING, AND THAT CLOSES A REAL HOLE ───────────────────────
#
# A comment elsewhere reading like an invocation (`# usage: bash scripts/foo.sh --self-test`) would
# otherwise CREDIT foo.sh as gated — an under-count of the problem, in the flattering direction. A
# script's own file is excluded too, because a script printing `echo "foo --self-test: PASS"` would
# otherwise credit itself. Both modes were named by Cara as the limits of the first sweep; this
# closes the first and the self-exclusion closes the second.
# (infra_twenty_six_self_tests_are_invoked_by_nothing)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh" 2>/dev/null || true

TIERS_FILE="${SELFTEST_TIERS_FILE:-scripts/selftest-tiers.txt}"

# ── pure ────────────────────────────────────────────────────────────────────────────────────────
# invocation_verdict <invoked: yes|no> <tier: verify|nowhere|""> -> gated | exempt | ungated
#
# ⚠ AN INVOKED SCRIPT IS `gated` WHATEVER THE MANIFEST SAYS. The manifest records intent; an actual
# invocation is evidence. If they disagree the evidence wins, so a stale `nowhere` row can never
# suppress a real gate — the failure mode would be silent and permanent.
invocation_verdict() {
  local invoked="${1-}" tier="${2-}"
  [[ "$invoked" == "yes" ]] && { printf 'gated\n'; return 0; }
  case "$tier" in
    verify)  printf 'gated\n' ;;
    # `stack` is GATED, not exempt: it runs on every stacked verify. It is a narrower promise about
    # WHERE, not a decision not to run — so it must never be counted as an exemption.
    stack)   printf 'gated\n' ;;
    nowhere) printf 'exempt\n' ;;
    *)       printf 'ungated\n' ;;
  esac
}

# ── pure: a manifest row is only an exemption if it carries a reason ────────────────────────────
# tier_row_verdict <tier> <reason> -> ok | no-reason
tier_row_verdict() {
  local tier="${1-}" reason="${2-}"
  [[ "$tier" == "nowhere" ]] || { printf 'ok\n'; return 0; }
  [[ -n "${reason//[[:space:]]/}" ]] && printf 'ok\n' || printf 'no-reason\n'
}

_self_test() {
  local fails=0 got
  v() { local want="$1" desc="$2"; shift 2; got="$(invocation_verdict "$@")"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s: want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  v gated   'something invokes it — that is the ordinary case'          yes ''
  v gated   'evidence beats the manifest: an invoked script is gated'   yes nowhere
  v gated   'the verify tier counts as gated'                           no  verify
  v exempt  'explicitly nowhere, with a reason, is a legitimate answer' no  nowhere
  # ⚠ THE WHOLE FEATURE. Nothing invokes it and nothing records why — that is the defect, and a
  # check that could not report it would be the thing it is checking for.
  v ungated 'neither invoked nor recorded — the defect'                 no  ''
  v gated   'the stack tier is GATED — a narrower where, not an exemption'  no  stack
  v ungated 'an unrecognised tier is not an exemption'                  no  someday

  # ── ⚠ THE DUPLICATE GUARD, which is what makes `merge=union` on the manifest safe ─────────────
  # (infra_the_selftest_tiers_manifest_conflicts_on_every_append_and_union_alone_would_hide_it)
  # Union keeps both sides of a conflict. For two independent APPENDS that is right; for a MODIFIED
  # row it yields two rows for one script, and the scan parses into a dict keyed by path, so the
  # second silently overwrites the first. Before this guard, a manifest carrying `scripts/r.sh
  # verify` AND `scripts/r.sh nowhere` made this gate exit 0 and print "ok".
  # ⚠⚠ THE SUBJECT MUST EXIST BEFORE ANY OF THIS ASSERTS ANYTHING. `dupe_rows` was defined BELOW
  # this block on the first attempt, so it was not in scope — and the three cases asserting EMPTY
  # output all printed `ok` while bash was reporting "dupe_rows: command not found" on the line
  # above each one. A negative control passes trivially when its subject cannot run, which is the
  # failure mode this whole file exists to prevent, appearing inside this file's own self-test.
  if declare -F dupe_rows >/dev/null 2>&1; then
    printf '  ok   dupe_rows is in scope, so the cases below are about something\n'
  else
    printf '  FAIL dupe_rows is not defined here — every case below asserts nothing\n'; fails=1
  fi
  d() { local want="$1" desc="$2" body="$3" got _f
        _f="$(mktemp)"; printf '%b' "$body" > "$_f"
        got="$(TIERS_FILE="$_f" dupe_rows | tr '\n' ';')"; rm -f "$_f"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s: want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  # ⚠⚠ THE CASE THE TICKET EXISTS FOR: one path, two tiers, and they disagree.
  d $'scripts/r.sh\tverify,nowhere;' 'CONTRADICTORY tiers for one path are caught, and both are named' \
    'scripts/a.sh\tverify\nscripts/r.sh\tverify\nscripts/r.sh\tnowhere\treason\n'
  # An identical duplicate is still one path with two rows — union produces this from two identical
  # appends, and "harmless" is not a state this manifest should be able to be in.
  d $'scripts/r.sh\tverify,verify;' 'an IDENTICAL duplicate is a duplicate too' \
    'scripts/r.sh\tverify\nscripts/r.sh\tverify\n'
  # ⚠ NEGATIVE CONTROLS. Without these the guard would pass by refusing everything, and a commented
  # example row failing the build is exactly how a gate loses its authority.
  d '' 'NEGATIVE CONTROL: a clean manifest yields nothing' \
    'scripts/a.sh\tverify\nscripts/b.sh\tnowhere\twhy\n'
  d '' 'NEGATIVE CONTROL: a COMMENTED example row is not a registration' \
    'scripts/a.sh\tverify\n# scripts/a.sh\tnowhere\tan example\n'

  # ── A REGISTRATION WITH NO SCRIPT ──────────────────────────────────────────────────────────
  # (fix_a_selftest_tiers_row_can_outlive_its_script_and_the_invocation_gate_does_not_notice)
  # Same discipline as the duplicate guard: prove the subject is in scope before any case asserts
  # an EMPTY answer, because an undefined function yields exactly the empty string these controls
  # expect.
  if declare -F orphan_rows >/dev/null 2>&1; then
    printf '  ok   orphan_rows is in scope, so the cases below are about something\n'
  else
    printf '  FAIL orphan_rows is not defined here — every case below asserts nothing\n'; fails=1
  fi
  local _otree; _otree="$(mktemp -d)"; mkdir -p "$_otree/scripts"; : > "$_otree/scripts/present.sh"
  o() { local want="$1" desc="$2" body="$3" got _f
        _f="$(mktemp)"; printf '%b' "$body" > "$_f"
        got="$(TIERS_FILE="$_f" ORPHAN_ROOT="$_otree" orphan_rows | tr '\n' ';')"; rm -f "$_f"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s: want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  # ⚠⚠ THE CASE THE TICKET EXISTS FOR: a verify row whose script is gone.
  o $'scripts/gone.sh\tverify;' 'a row whose script does NOT EXIST is caught, with its tier' \
    'scripts/present.sh\tverify\nscripts/gone.sh\tverify\n'
  # ⚠ NEGATIVE CONTROLS — the ticket names both: without them the guard could pass by refusing
  # every row, and a gate that fails the manifest wholesale loses its authority on the first run.
  o '' 'NEGATIVE CONTROL: a verify row for a script that exists is accepted' \
    'scripts/present.sh\tverify\n'
  o '' 'NEGATIVE CONTROL: a nowhere row WITH a reason, for a script that exists, is accepted' \
    'scripts/present.sh\tnowhere\tbecause it needs the owner\n'
  o '' 'NEGATIVE CONTROL: a COMMENTED row for a missing script is not a registration' \
    'scripts/present.sh\tverify\n# scripts/gone.sh\tverify\n'
  rm -rf "$_otree"
  d '' 'NEGATIVE CONTROL: blank lines are not paths' \
    'scripts/a.sh\tverify\n\n\n'
  # Leading/trailing whitespace must not manufacture two distinct paths out of one.
  d $'scripts/a.sh\tverify,nowhere;' 'a padded path is the SAME path, not a second one' \
    'scripts/a.sh\tverify\n  scripts/a.sh  \tnowhere\twhy\n'

  r() { local want="$1" desc="$2"; shift 2; got="$(tier_row_verdict "$@")"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s: want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  # ⚠ A REASONLESS EXEMPTION IS A SILENT MUTE, which is what this whole file exists to prevent.
  r no-reason 'nowhere with no reason is refused'      nowhere ''
  r no-reason 'nor with whitespace pretending to be one' nowhere '   '
  r ok        'nowhere WITH a reason is accepted'      nowhere 'manual DR script, never on the critical path'
  r ok        'the verify tier needs no reason'        verify  ''

  # ── ⚠ THE SCANNER MUST SEE BOTH HELPERS THE SHARED CONTRACT EXPOSES ───────────────────────────
  # (fix_the_selftest_invocation_gate_cannot_see_scripts_using_the_contract_it_mandates)
  # ACCEPTS recognised `selftest_is_flag` and not `selftest_requested`, so 54 scripts never entered
  # the scan and were reported neither gated nor ungated. The population was 128; it is 186 with
  # both. ⚠ ASSERTED ON FIXTURES, NOT ON THE TREE: the real tree agrees with a broken rule the
  # moment it is fixed, so a tree-based assertion could not have failed before the fix either.
  _acc() { python3 - "$1" <<'PYEOF'
import re,sys
ACCEPTS = re.compile(r"(--self-?test\)|selftest_is_flag|selftest_requested|\"--selftest\"|\"--self-test\"|'--selftest'|'--self-test')")
print("seen" if ACCEPTS.search(sys.argv[1]) else "invisible")
PYEOF
  }
  a() { local want="$1" desc="$2" body="$3"; got="$(_acc "$body")"
        if [[ "$got" == "$want" ]]; then printf '  ok   %s\n' "$desc"
        else printf '  FAIL %s: want %q got %q\n' "$desc" "$want" "$got"; fails=1; fi; }
  a seen 'a script using selftest_requested is SEEN'  'if selftest_requested "$@"; then'
  # ⚠ POSITIVE CONTROL ON THE OTHER HELPER. A regex rewrite that swapped one for the other would
  # trade 54 invisible scripts for a different set, and every count assertion would still pass.
  a seen 'a script using selftest_is_flag is still seen' 'if selftest_is_flag "${1:-}"; then'
  a seen 'a hand-rolled --self-test) case is still seen' 'case "$1" in --self-test) _self_test ;; esac'
  # ⚠ AND THE INSTRUMENT MUST STILL BE ABLE TO SAY `invisible`, or every assertion above is
  # satisfied by a regex matching everything — which would report the whole tree as self-testable.
  a invisible 'NEGATIVE CONTROL: a script with no flag at all is invisible' 'echo hello'
  a invisible '…and prose ABOUT a self-test is not a dispatch' '# run the --selftest by hand'

  # ── ⚠ A PROSE MENTION IS NOT AN INVOCATION, DRIVEN OVER A REAL FIXTURE TREE ──────────────────
  # (fix_the_selftest_invocation_gate_credits_a_prose_mention_as_an_invocation)
  # The `#`-comment strip above is correct and was never the whole story: a Python DOCSTRING line
  # does not start with `#`, so it survived. Measured 2026-08-29 — `page-owner.sh --self-test` was
  # reported `gated` on the strength of exactly ONE line, prose in check-verification-commands.py
  # whose own words were that the script needed a decision rather than a wiring. The gate read the
  # sentence DENYING the wiring as evidence of it, and that self-test ran nowhere.
  #
  # ⚠ THESE ARMS RUN THE REAL `_scan` OVER A FIXTURE TREE, via SCAN_ROOT. A stripping rule
  # re-implemented inside a test arm asserts whatever the arm believes; only driving the actual code
  # can fail when the actual code is wrong.
  # this file's arms use specialised helpers (d/v/r/a); these need a plain boolean one.
  _tt() { if eval "$2"; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fails=1; fi; }
  _fx="$(mktemp -d)"; trap 'rm -rf "$_fx"' RETURN
  printf 'case "$1" in --self-test) _t ;; esac\n' > "$_fx/target.sh"
  printf '"""\ndocs: `target.sh --self-test` is 37.7 SECONDS and needs a decision, not a wiring.\n"""\n' > "$_fx/prose.py"
  _verdict() { SCAN_ROOT="$_fx" TIERS_FILE=/dev/null _scan | awk -F'\t' -v p="$_fx/target.sh" '$1==p{print $2}'; }
  _tt "a backticked mention in a .py DOCSTRING does not credit an invocation" '[[ "$(_verdict)" == "no" ]]'

  # ⚠ NEGATIVE CONTROL — a REAL invocation must still count, or the fix has simply blinded the gate
  # and 258 gated becomes 258 ungated. Same tree, one line added.
  printf 'bash target.sh --self-test\n' > "$_fx/runner.sh"
  _tt "NEGATIVE CONTROL: a real invocation in a .sh body still counts" '[[ "$(_verdict)" == "yes" ]]'

  # ⚠ AND THE STRIP IS .py-ONLY ON PURPOSE: in shell a backtick is COMMAND SUBSTITUTION, so
  # stripping it there would erase real invocations. Asserted, not asserted-about.
  rm -f "$_fx/runner.sh"
  printf 'x=`bash target.sh --self-test`\n' > "$_fx/sub.sh"
  _tt "…and a backticked command substitution in .sh is STILL an invocation" '[[ "$(_verdict)" == "yes" ]]'
  rm -f "$_fx/sub.sh"

  # ⚠ POSITIVE CONTROL ON THE FIXTURE ITSELF. Every arm above reads one field of one row; if the
  # fixture never entered the population the reads are all empty string and the `no` arm passes for
  # the wrong reason. Assert the row EXISTS before trusting what it says.
  _tt "the fixture tree yields exactly one population row" \
      '[[ "$(SCAN_ROOT="$_fx" TIERS_FILE=/dev/null _scan | grep -c .)" == "1" ]]'

  # ── the diff selector (infra_a_self_test_runs_on_a_pr_only_when_its_script_or_its_inputs_changed) ──
  # Three verify rows: a.sh (plain), b.sh (its body NAMES helper.sh), c.sh (DECLARES an input glob in
  # the third column). Each arm names the diff and which of the three must RUN.
  _sx="$(mktemp -d)"; mkdir -p "$_sx/scripts"
  printf '#!/bin/bash\necho a\n' > "$_sx/scripts/a.sh"
  printf '#!/bin/bash\n. "$(dirname "$0")/helper.sh"\n' > "$_sx/scripts/b.sh"
  printf '#!/bin/bash\necho c\n' > "$_sx/scripts/c.sh"
  printf 'scripts/a.sh\tverify\nscripts/b.sh\tverify\nscripts/c.sh\tverify\tinputs:.github/workflows/*.yml,docs/x.md\nscripts/n.sh\tnowhere\ta reason\n' > "$_sx/tiers.txt"
  _ran() { printf '%s' "$1" > "$_sx/chg.txt"
           SCAN_ROOT="$_sx" TIERS_FILE="$_sx/tiers.txt" _select "$_sx/chg.txt" | awk -F'\t' '$1=="RUN"{print $2}' | sed 's#scripts/##' | tr '\n' ' '; }
  _tt "a diff touching only frontend/ runs NONE of them" '[[ "$(_ran "frontend/pwa/js/app.js")" == "" ]]'
  _tt "editing a script runs ITS self-test, and only its" '[[ "$(_ran "scripts/a.sh")" == "a.sh " ]]'
  _tt "editing a file a script NAMES runs that script (the widening beyond the ticket)" '[[ "$(_ran "scripts/helper.sh")" == "b.sh " ]]'
  _tt "a DECLARED input glob runs its script" '[[ "$(_ran ".github/workflows/ci.yml")" == "c.sh " ]]'
  _tt "…and a second declared input too" '[[ "$(_ran "docs/x.md")" == "c.sh " ]]'
  _tt "anything under scripts/lib/ runs EVERY self-test" '[[ "$(_ran "scripts/lib/agent-name.sh")" == "a.sh b.sh c.sh " ]]'
  _tt "the tiers manifest itself runs every self-test" '[[ "$(_ran "scripts/selftest-tiers.txt")" == "a.sh b.sh c.sh " ]]'
  _tt "an EMPTY diff runs every self-test — unreadable is not unchanged" '[[ "$(_ran "")" == "a.sh b.sh c.sh " ]]'
  _tt "a nowhere row is never selected" '[[ "$(printf "x" > "$_sx/chg.txt"; SCAN_ROOT="$_sx" TIERS_FILE="$_sx/tiers.txt" _select "$_sx/chg.txt" | grep -c n.sh)" == "0" ]]'
  _tt "a MISSING diff file runs every self-test" '[[ "$(SCAN_ROOT="$_sx" TIERS_FILE="$_sx/tiers.txt" _select "$_sx/no-such" | grep -c ^RUN)" == "3" ]]'
  _tt "a verify row with an inputs: third column still needs no reason" '[[ "$(tier_row_verdict verify "inputs:docs/x.md")" != "no-reason" ]]'
  rm -rf "$_sx"

  if (( fails )); then echo "check-selftests-are-invoked: selftest FAILED"; return 1; fi
  echo "check-selftests-are-invoked: selftest ok — evidence beats the manifest, and a reasonless exemption is refused"
  return 0
}

# ── ⚠⚠ THE DUPLICATE-PATH GUARD, AND IT IS THE LOAD-BEARING HALF OF THE `merge=union` CHANGE ────
# (infra_the_selftest_tiers_manifest_conflicts_on_every_append_and_union_alone_would_hide_it)
#
# `scripts/selftest-tiers.txt` is append-only, so any two branches that each register a self-test
# append to the same last line and CONFLICT. Six times in one evening, 2026-08-27/28 — and two of
# those inside the hour after the ticket was raised, by an author writing no new self-tests at all,
# merely keeping open PRs current. The recurrence interval is minutes, and it scales with HOW MANY
# PRs ARE OPEN rather than with how much anyone writes, which is why it reads as background noise.
#
# `.gitattributes` now declares `merge=union` for the file. Union keeps BOTH sides, which is exactly
# right for two independent APPENDS — the only shape this file has ever conflicted in. But for a
# MODIFIED row it produces two rows for one script, and if the tiers disagree the manifest asserts
# that a script both runs in `verify` and runs `nowhere`.
#
# ⚠ DRIVEN, NOT REASONED: before this guard, a manifest carrying `scripts/r.sh verify` AND
# `scripts/r.sh nowhere` made this gate exit 0 and print "ok every self-test is run by something".
# The scan parses the manifest into a DICT keyed by path — last write wins — so the contradiction is
# destroyed at parse time and nothing downstream can see it. **Union without this guard trades a
# loud conflict for a silent contradiction, which is a downgrade.** Neither half ships alone.
#
# ⚠ IT READS THE RAW FILE, NOT THE PARSED SCAN, for exactly that reason: the collapse has already
# happened by the time the scan emits anything. Comments and blank lines are excluded so a commented
# example row cannot fail the build.
dupe_rows() { # -> "<path>\t<tier>,<tier>" per duplicated path
  [[ -r "$TIERS_FILE" ]] || return 0
  awk -F'\t' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { p=$1; gsub(/^[ \t]+|[ \t]+$/, "", p); if (p=="") next
      n[p]++; t[p] = (p in t ? t[p] "," $2 : $2) }
    END { for (p in n) if (n[p] > 1) printf "%s\t%s\n", p, t[p] }
  ' "$TIERS_FILE" | sort
}

# ── A REGISTRATION WITH NO SCRIPT ───────────────────────────────────────────────────────────────
# (fix_a_selftest_tiers_row_can_outlive_its_script_and_the_invocation_gate_does_not_notice)
# The scan builds its POPULATION from files that dispatch a self-test flag and then looks each one
# up here — so a row whose script has been DELETED is never in the population and never examined.
# Measured 2026-09-28: `scripts/owner-rulings.sh verify` outlived its script by eleven days (added
# and deleted in the same minute by one ticket, 62742b5d4 / bb816b8d7), and this gate stayed green.
# Deleting a script has no step that removes its registration, so the manifest drifted into
# asserting a self-test that does not exist — and a second reader of the manifest (the PR selector,
# #9489) read it directly and disagreed with the first.
#
# ⚠ IT READS THE RAW FILE, like dupe_rows and for the same reason: the question is about the
# MANIFEST's rows, which the scan never iterates. Comments and blank lines are not registrations.
# `ORPHAN_ROOT` exists so the self-test can drive this over a temp tree; the gate runs from the repo.
orphan_rows() { # -> "<path>\t<tier>" per registered path whose file does not exist
  [[ -r "$TIERS_FILE" ]] || return 0
  local root="${ORPHAN_ROOT:-.}" p tier
  while IFS=$'\t' read -r p tier <&3; do
    [[ -e "$root/$p" ]] || printf '%s\t%s\n' "$p" "$tier"
  done 3< <(awk -F'\t' '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    { p=$1; gsub(/^[ \t]+|[ \t]+$/, "", p); if (p!="") printf "%s\t%s\n", p, $2 }
  ' "$TIERS_FILE")
}

# ⚠ DEFINED BEFORE THE SELF-TEST DISPATCH BELOW, DELIBERATELY. The fixture arms in _self_test
# drive this exact function over a temp tree (SCAN_ROOT); with the definition after the
# dispatch they resolved to nothing and the harness printed `_scan: command not found` FOUR
# times while still reporting `selftest ok`. Moving it up is what makes those arms real.
# (fix_the_selftest_invocation_gate_credits_a_prose_mention_as_an_invocation)
_scan() { TIERS_FILE="$TIERS_FILE" python3 - <<'PYEOF'
import os, re, sys

FLAG = re.compile(r'--self-?test')
# ACCEPTS a self-test flag = dispatches on one. A script that merely mentions the string in prose
# is not self-testable, and counting it would inflate the denominator with things that cannot be
# wired at all.
# ⚠ BOTH HELPERS THE SHARED CONTRACT EXPOSES, NOT JUST ONE.
# (fix_the_selftest_invocation_gate_cannot_see_scripts_using_the_contract_it_mandates)
# This listed `selftest_is_flag` and not `selftest_requested`. The two are not alternatives with a
# house favourite: lib/selftest-flag.sh recommends `selftest_requested` for a script whose ONLY
# argument is the flag, and `selftest_is_flag` for one with its own argument loop. So the canonical
# form for the commonest case was the invisible one.
#
# ⚠ AND check-selftest-flag-contract.sh PUSHES AUTHORS INTO IT. It rejects a hand-rolled flag parse
# and directs you to the contract; adopting the contract is exactly what removed a script from this
# gate's population. The repo's conventions were migrating scripts OUT of the denominator one at a
# time, and this gate reported a cleaner result each time it happened.
#
# ⚠ THE FAILURE WAS A VACUOUS PASS, NOT A WRONG COUNT. 54 scripts were reported neither gated nor
# ungated because they never entered the scan; "0 ungated" was true about a population that excluded
# them. Found only because a correct tiers row had no effect and nothing said why — a gate that
# ignores a valid registration silently is indistinguishable from one that accepted it.
ACCEPTS = re.compile(r"(--self-?test\)|selftest_is_flag|selftest_requested|\"--selftest\"|\"--self-test\"|'--selftest'|'--self-test')")

def walk(base, exts):
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if d not in ('node_modules', 'testdata')]
        for f in sorted(files):
            if f.endswith(exts) or root.endswith('git-hooks'):
                yield os.path.join(root, f)

_root = os.environ.get('SCAN_ROOT', '')
_roots = [(_root, ('.sh', '.yml', '.yaml', '.py', '.mjs'))] if _root else [
    ('scripts', ('.sh', '.yml', '.yaml', '.py', '.mjs')), ('.github', ('.yml', '.yaml'))]

pop = []
# ⚠⚠ THE POPULATION ROOT IS WIDENED SEPARATELY FROM THE INVOCATION-SCAN ROOT ABOVE, AND THAT
# SEPARATION IS THE WHOLE CARE REQUIRED HERE.
# (fix_the_capacity_selftest_swept_prefix_arm_fails_for_any_worktree_under_tmp)
# `ungated 0` was true of a population that had never contained infra/: two Python self-tests live
# in infra/preprod (capacity_driver.py, capacity_runner.py) and this gate could not see them, so a
# self-test defect there was invisible to the sweep whose stated purpose covers it exactly.
# ⚠ SCAN_ROOT replaces BOTH roots at once — it is the fixture handle this file's own self-test uses
# — so the widening goes in the DEFAULT arm only. Widening both together would move the invocation
# scan off scripts/, which is where these two are actually invoked (verify.sh:1372 and :1389), and
# they would come back as false `ungated` rows.
# Measured across the change: population 316 -> 318, ungated 0 -> 0.
for _pr, _pe in ([(_root, ('.sh', '.py'))] if _root else [('scripts', ('.sh', '.py')), ('infra', ('.sh', '.py'))]):
    for p in walk(_pr, _pe):
        try: s = open(p, encoding='utf-8', errors='replace').read()
        except OSError: continue
        if ACCEPTS.search(s):
            pop.append(p)

# ⚠ COMMENT LINES STRIPPED. A comment reading like an invocation would credit a script as gated,
# which is an under-count of the problem in the flattering direction.
bodies = {}
for p in [q for _br, _be in _roots for q in walk(_br, _be)]:
    try: raw = open(p, encoding='utf-8', errors='replace').read()
    except OSError: continue
    _lines = [l for l in raw.split('\n') if not l.lstrip().startswith('#')]
    if p.endswith('.py'):
        _lines = [re.sub(r'`[^`]*`', '', l) for l in _lines]
    bodies[p] = '\n'.join(_lines)

tiers = {}
tf = os.environ.get('TIERS_FILE', '')
if tf and os.path.exists(tf):
    for ln in open(tf, encoding='utf-8'):
        ln = ln.rstrip('\n')
        if not ln.strip() or ln.lstrip().startswith('#'): continue
        parts = ln.split('\t')
        path = parts[0].strip()
        tier = parts[1].strip() if len(parts) > 1 else ''
        reason = parts[2].strip() if len(parts) > 2 else ''
        tiers[path] = (tier, reason)

for p in pop:
    base = os.path.basename(p)
    invoked = 'no'
    for q, body in bodies.items():
        if q == p:            # a script's own output line must not credit it
            continue
        for ln in body.split('\n'):
            if base in ln and FLAG.search(ln):
                invoked = 'yes'; break
        if invoked == 'yes': break
    tier, reason = tiers.get(p, ('', ''))
    sys.stdout.write('\t'.join([p, invoked, tier, reason]) + '\n')
PYEOF
}

# ── WHICH verify-TIER SELF-TESTS A PR'S DIFF CAN REACH (infra_a_self_test_runs_on_a_pr_only_when_its_script_or_its_inputs_changed) ──────
#
#   --list-for-diff <file-of-changed-paths>  ->  "RUN\t<path>" or "SKIP\t<path>" per verify entry
#
# A self-test proves its SCRIPT, not the PR: on a PR whose diff touches none of a script's inputs,
# its self-test cannot fail for a reason in the diff. Measured 2026-09-28 (run 36394788782): the 123
# verify-tier self-tests take 3.5 min of a 16.6 min verify on every PR, nearly all of them unreachable.
# A self-test RUNS when the diff touches any of:
#   (a) the script itself;
#   (b) anything under scripts/lib/ (shared code — every self-test runs);
#   (c) scripts/selftest-tiers.txt, this file, or scripts/verify.sh (how self-tests are chosen/run);
#   (d) an input the row DECLARES: an `inputs:<glob>[,<glob>…]` third column on a verify row;
#   (e) ⚠ WIDER THAN THE TICKET, DELIBERATELY: a changed file the script's body NAMES — any changed
#       path written out in full (a self-test reading .github/workflows/ci.yml or a page), or a
#       scripts/ file by its name (the file it sources or calls). That only ever runs MORE, never fewer.
# ⚠ AN UNREADABLE OR EMPTY DIFF RUNS EVERYTHING. "I could not read the diff" is not "nothing changed".
# ⚠ Decided from the DIFF, never from a cache or a previous verdict: the hourly full suite on main
# still runs every one of them every hour, so an unchanged script is still proved on main.
_select() { TIERS_FILE="$TIERS_FILE" CHANGED_FILE="$1" python3 - <<'PYEOF2'
import os, fnmatch, sys
changed = []
cf = os.environ.get('CHANGED_FILE', '')
if cf and os.path.exists(cf):
    changed = [l.strip() for l in open(cf, encoding='utf-8') if l.strip()]
root = os.environ.get('SCAN_ROOT', '')
rows = []
tf = os.environ.get('TIERS_FILE', '')
if tf and os.path.exists(tf):
    for ln in open(tf, encoding='utf-8'):
        ln = ln.rstrip('\n')
        if not ln.strip() or ln.lstrip().startswith('#'): continue
        parts = ln.split('\t')
        if len(parts) < 2 or parts[1].strip() != 'verify': continue
        extra = parts[2].strip() if len(parts) > 2 else ''
        globs = [g.strip() for g in extra[len('inputs:'):].split(',') if g.strip()] if extra.startswith('inputs:') else []
        rows.append((parts[0].strip(), globs))
ALWAYS = ('scripts/selftest-tiers.txt', 'scripts/check-selftests-are-invoked.sh', 'scripts/verify.sh')
run_all = (not changed) or any(c.startswith('scripts/lib/') or c in ALWAYS for c in changed)
for path, globs in rows:
    why = ''
    if run_all:
        why = 'all'
    elif path in changed:
        why = 'self'
    elif any(fnmatch.fnmatch(c, g) for c in changed for g in globs):
        why = 'declared-input'
    else:
        try: body = open(os.path.join(root, path) if root else path, encoding='utf-8', errors='replace').read()
        except OSError: body = None
        if body is None:
            why = 'unreadable'   # cannot tell what it reads, so it runs
        elif any(c in body or (c.startswith('scripts/') and os.path.basename(c) in body) for c in changed):
            why = 'referenced'   # the script names the changed file: its full path, or a script's name
    sys.stdout.write(('RUN' if why else 'SKIP') + '\t' + path + '\n')
PYEOF2
}

if [[ "${1:-}" == "--list-for-diff" ]]; then
  # ⚠ INTERSECTED WITH --list, so the two readers can never disagree about the population: a tiers
  # row whose script no longer exists (scripts/owner-rulings.sh, measured 2026-09-28) is not in
  # --list, and without this it came back as an extra RUN that verify.sh's count check then rejected.
  _select "${2:-}" | awk -F'\t' 'NR==FNR { keep[$1] = 1; next } ($2 in keep)' \
    <(_scan | awk -F'\t' '$3=="verify"{print $1}') -
  exit 0
fi

declare -F selftest_reject_typo >/dev/null && selftest_reject_typo "${1:-}"
if declare -F selftest_is_flag >/dev/null && selftest_is_flag "${1:-}"; then _self_test; exit $?; fi

# ── the impure half ─────────────────────────────────────────────────────────────────────────────

if [[ "${1:-}" == "--list" ]]; then
  # ⚠ THE MANIFEST IS THE SINGLE SOURCE. verify.sh runs exactly what this prints, so the list it
  # gates and the list this file judges can never be two lists that drift.
  _scan | awk -F'\t' '$3=="verify"{print $1}'
  exit 0
fi

# The stack-only half, printed separately so verify.sh can run it under its own condition and SAY
# what it skipped. Same single source; only the filter differs.
if [[ "${1:-}" == "--list-stack" ]]; then
  _scan | awk -F'\t' '$3=="stack"{print $1}'
  exit 0
fi

c_ok=$'\033[1;32m'; c_bad=$'\033[1;31m'; c_warn=$'\033[1;33m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_ok=; c_bad=; c_warn=; c_off=; }


dupe=0
declare -a DUPES=()
while IFS= read -r _d; do [[ -n "$_d" ]] && { DUPES+=("$_d"); dupe=$((dupe+1)); }; done < <(dupe_rows)

orphan=0
declare -a ORPHANS=()
while IFS= read -r _o; do [[ -n "$_o" ]] && { ORPHANS+=("$_o"); orphan=$((orphan+1)); }; done < <(orphan_rows)

# ⚠ THE SCAN'S EXIT STATUS WAS BEING THROWN AWAY, AND A CRASH READ AS A CLEAN SWEEP.
# (fix_the_selftest_invocation_gate_credits_a_prose_mention_as_an_invocation)
# This loop used to be fed by a PROCESS SUBSTITUTION, whose exit status is unobservable. A traceback
# out of the embedded python therefore produced population 0, ungated 0, the cheerful ok line, and
# EXIT 0. Driven, not reasoned: a RuntimeError injected into the scan printed the traceback AND the
# pass, together, on 2026-08-29.
#
# ⚠ "COULD NOT LOOK" IS NOT "NOTHING TO REPORT", and the difference has to be in the EXIT CODE,
# because that is the only part a caller reads. Exit 2 says the question was not answered; exit 1
# stays reserved for a real ungated script. A gate that fails toward "everything is fine" is the
# self-sealing shape this repo keeps paying for.
#
# ⚠ AND A ZERO POPULATION IS REFUSED EVEN WHEN THE SCAN EXITS 0. This file's own header records
# the time 54 scripts silently never entered the scan and "0 ungated" was true about a population
# that excluded them. An empty denominator is never good news here.
_scan_out="$(mktemp)"; trap 'rm -f "$_scan_out"' EXIT
if ! _scan > "$_scan_out"; then
  printf '\n  %sCOULD NOT LOOK%s  the invocation scan FAILED - this is not a pass.\n' "$c_bad" "$c_off"
  printf '    Nothing was judged, so nothing can be said about whether a self-test is wired.\n'
  exit 2
fi

pop=0; gated=0; exempt=0; ungated=0; badrow=0
declare -a UNGATED=() BADROW=()
while IFS=$'\t' read -r path invoked tier reason; do
  [[ -n "$path" ]] || continue
  pop=$((pop+1))
  if [[ "$(tier_row_verdict "$tier" "$reason")" == "no-reason" ]]; then
    badrow=$((badrow+1)); BADROW+=("$path")
  fi
  case "$(invocation_verdict "$invoked" "$tier")" in
    gated)   gated=$((gated+1)) ;;
    exempt)  exempt=$((exempt+1)) ;;
    ungated) ungated=$((ungated+1)); UNGATED+=("$path") ;;
  esac
done < "$_scan_out"

if (( pop == 0 )); then
  printf '\n  %sCOULD NOT LOOK%s  the scan returned an EMPTY population - this is not a pass.\n' "$c_bad" "$c_off"
  printf '    0 ungated out of 0 examined says nothing. See the note above this loop.\n'
  exit 2
fi

printf '  population   %s   files under scripts/ and infra/ that DISPATCH on a self-test flag\n' "$pop"
printf '  gated        %s   invoked by something, or listed for the verify tier\n' "$gated"
printf '  exempt       %s   explicitly nowhere, WITH a stated reason\n' "$exempt"
printf '  ungated      %s   invoked by nothing and unrecorded\n' "$ungated"
printf '  duplicated   %s   the same path registered more than once\n' "$dupe"
printf '  orphaned     %s   registered, but the script does not exist\n' "$orphan"

if (( badrow )); then
  printf '\n  %sFAIL%s an exemption with no reason is a silent mute:\n' "$c_bad" "$c_off"
  printf '        %s\n' "${BADROW[@]}"
  printf '        Add a reason as the third tab-separated field of %s\n' "$TIERS_FILE"
fi

if (( dupe )); then
  printf '\n  %sFAIL%s the manifest registers the same script TWICE:\n' "$c_bad" "$c_off"
  printf '        %s\n' "${DUPES[@]}"
  printf '        One path, one tier. Two rows for one script is what `merge=union` produces from a\n'
  printf '        MODIFIED row, and when the tiers disagree the manifest says a script both runs in\n'
  printf '        `verify` and runs `nowhere` — which the scan cannot see, because it parses into a\n'
  printf '        dict and the second row silently overwrites the first.\n'
  printf '        Keep the row that is true and delete the other in %s\n' "$TIERS_FILE"
fi

if (( orphan )); then
  printf '\n  %sFAIL%s the manifest registers a self-test whose script DOES NOT EXIST:\n' "$c_bad" "$c_off"
  printf '        %s\n' "${ORPHANS[@]}"
  printf '        The scan never examines these — it only iterates scripts that exist — so a deleted\n'
  printf '        script leaves its registration asserting a self-test nobody can run.\n'
  printf '        Delete the row from %s (or restore the script, if it was deleted by mistake).\n' "$TIERS_FILE"
fi

if (( ungated == 0 && badrow == 0 && dupe == 0 && orphan == 0 )); then
  printf '\n  %sok%s  every self-test is run by something, or recorded as deliberately not run\n' "$c_ok" "$c_off"
  exit 0
fi

if (( ungated )); then
  printf '\n  %sFAIL%s these self-tests are invoked by nothing and no reason is recorded:\n\n' "$c_bad" "$c_off"
  printf '        %s\n' "${UNGATED[@]}"
  printf '\n        A self-test that nothing runs is not a test — it is green because it never ran.\n'
  printf '        Pick a tier in %s (TAB separated):\n' "$TIERS_FILE"
  printf '            scripts/foo.sh\tverify\n'
  printf '            scripts/bar.sh\tnowhere\twhy it does not belong on the critical path\n'
  printf '        ⚠ `nowhere` needs a REASON. That is the whole difference between an exemption and a mute.\n\n'
fi
exit 1
