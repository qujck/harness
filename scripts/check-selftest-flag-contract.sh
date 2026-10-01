#!/usr/bin/env bash
# scripts/check-selftest-flag-contract.sh — a script that offers a self-test must go through the
# shared flag contract. (chore_unify_selftest_flag_spelling)
#
#   bash scripts/check-selftest-flag-contract.sh              # assert
#   bash scripts/check-selftest-flag-contract.sh --self-test  # prove the checker itself can fail
#
# ── WHY A RATCHET AND NOT A CONVENTION ──────────────────────────────────────────────────────────
#
# The schism this closes grew without anybody deciding on it: 41 scripts accepted only `--selftest`,
# 25 only `--self-test`, and `verify.sh` invoked both spellings 128 times between them. Nobody chose
# that. The 26th checker was written by copying the 25th, and the 25th had copied the 24th.
#
# The cost was not untidiness. A mistyped flag did not error — it fell through the guard, ran the
# script's REAL ACTION and exited 0. So a self-test that never ran was indistinguishable from one
# that passed, in a gate whose entire job is to be believed.
#
# A rule enforced by attention over ~80 scripts is not a rule. This is the mechanism.
#
# ── WHAT IT ASKS ────────────────────────────────────────────────────────────────────────────────
#
# For every script under scripts/ that PARSES a self-test flag (as opposed to passing one to some
# other command): does it source scripts/lib/selftest-flag.sh?
#
# Sourcing the library is the whole test, because the library is what supplies both halves of the
# contract — either spelling accepted, AND any unrecognised argument refused with exit 2. Asking
# the question that way is deliberate: an earlier version of this audit tried to detect "rejects
# unknown arguments" by pattern, and got the answer wrong three separate times (blind to
# `[ "$1" = "--flag" ]`, blind to single-line `case … esac`, blind to `-*)` catch-alls). A checker
# whose own reading is unreliable produces confident, plausible, false findings — so this one asks
# a question with an exact answer instead.
#
# ── THE LEGACY LIST, AND WHY IT CAN ONLY SHRINK ─────────────────────────────────────────────────
#
# The scripts below handled the flag by hand before the library existed. Each was checked BY
# EXECUTION on 2026-08-09 — both spellings run the self-test, `--slef-test` exits non-zero — so
# they are correct, just not uniform. Rewriting deploy-prod.sh's argument handling to gain nothing
# behavioural is not a trade worth making.
#
# ⚠ THE LIST IS FROZEN. A name may be REMOVED (when that script moves to the library) but never
# ADDED. That is the whole ratchet: adding one is exactly how the 26th checker got written.
#
# ── WHAT THIS DOES NOT CATCH, stated rather than left to be discovered ──────────────────────────
#
# It catches a script that PARSES the flag badly. It cannot catch a script that ADVERTISES a
# self-test it never wrote — because such a script contains no argument handling for this checker
# to read. That was a real instance: `check-e2e-readiness-gate.sh` was invoked by verify.sh as
# `--selftest` while having no `case`, no comparison and no argv handling whatsoever, so every
# spelling AND `--utter-nonsense` produced byte-identical output and exit 0. Confirmed by running
# this ratchet against the real pre-fix file: it names four of the five, and NOT that one.
#
# The remedy for that shape is the same library used the other way round — the gate now calls
# `selftest_requested "$@" || true` purely to refuse an argument it does not understand. If you
# find another script whose call site passes a flag it never reads, that is the fix.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/scripts/lib/selftest-flag.sh"
cd "$ROOT"

SELF_TEST=0
if selftest_requested "$@"; then SELF_TEST=1; fi

# ── the frozen legacy list ──────────────────────────────────────────────────────────────────────
LEGACY="
# (empty in the template: every script here goes through scripts/lib/selftest-flag.sh — the ratchet
# starts at zero and may only shrink)
"

scan() {  # $1 = repo root; scans <root>/scripts. prints one offending path per line.
  python3 - "$1" "$LEGACY" <<'PY'
import io, os, re, sys

repo, legacy = sys.argv[1], set(sys.argv[2].split())
# scripts/ is where the gates live; e2e-ui/tools holds node tools with self-tests of their own, and
# leaving them out would make the ratchet's silence mean less than it appears to.
ROOTS = ['scripts', 'e2e-ui/tools']
SPELL = re.compile(r'--self-?test')
# The flag being handed TO something else is a call site, not a handler.
CALL = re.compile(r'\b(?:bash|sh|node|python3?|exec|source)\b[^\n]*?' + SPELL.pattern)

offenders = []
for r in ROOTS:
  for dp, dn, fn in os.walk(os.path.join(repo, r)):
    dn[:] = [d for d in dn if d not in ('.git', 'node_modules')]
    for f in sorted(fn):
        p = os.path.join(dp, f)
        # ⚠ EXTENSION *OR* SHEBANG, BECAUSE GIT HOOKS HAVE NO EXTENSION AND THAT IS NOT OPTIONAL
        # FOR THEM — git requires the exact names `pre-commit` / `pre-push`. The filter used to be
        # `f.endswith(('.sh','.mjs'))` alone, and this walk ALREADY DESCENDS INTO `scripts/git-hooks/`
        # — so the gate enumerated the directory and then dropped every file in it, reporting `ok`
        # about a population it had never examined.
        #
        # ⚠⚠ AND IT IS THE WORST POPULATION TO MISS, FOR THE REASON IN THIS FILE'S OWN HEADER: a
        # hand-rolled flag test is "how a MISTYPED flag came to fall through a guard, run a script's
        # REAL ACTION and exit 0". IN A GIT HOOK THE REAL ACTION IS THE HOOK. Driven 2026-09-02:
        # `bash scripts/git-hooks/pre-push --self-test` (hyphenated) matched no guard, ran the hook
        # body, and exited 0 — indistinguishable from a pass, and nearly recorded as one.
        if not f.endswith(('.sh', '.mjs')):
            if '.' in f:
                continue                  # some other extension: .py, .txt, .service, .json …
            try:
                with io.open(p, encoding='utf-8', errors='replace') as fh:
                    if not fh.readline().startswith('#!'):
                        continue          # not a script at all
            except OSError:
                continue
        key = os.path.relpath(p, repo)          # comparable to the LEGACY entries
        if key.endswith('lib/selftest-flag.sh'):
            continue
        s = io.open(p, encoding='utf-8', errors='replace').read()
        # ⚠ MATCH THE SOURCE LINE, NOT THE STRING 'lib/selftest-flag.sh'.
        #
        # This was a bare substring test for `lib/selftest-flag.sh`, which is what a script in
        # scripts/ naturally writes — and what a script ALREADY INSIDE scripts/lib/ naturally does
        # NOT. From there the correct line is `. "$(dirname …)/selftest-flag.sh"`: a correct source
        # of the correct file, containing no `lib/`, so a compliant library was reported as
        # hand-rolled. Reproduced before fixing: a probe lib written exactly that way was flagged,
        # exit 1. Reported by Anthony after it bit scripts/lib/ticket-source.sh, and it will bite
        # the one directory most likely to gain the next shared helper.
        #
        # Requiring the line to be a SOURCE (`.` or `source`) is also strictly tighter than the
        # substring it replaces: a file that merely NAMED the contract in prose used to pass.
        if re.search(r'^\s*(?:\.|source)\s+[^\n]*selftest-flag\.sh', s, re.M):
            continue                      # uses the shared contract -- correct by construction
        handles = False
        for ln in s.split('\n'):
            st = ln.strip()
            if st.startswith('#') or st.startswith('//'):
                continue
            if SPELL.search(ln) and not CALL.search(ln):
                handles = True
                break
        if handles and key not in legacy:
            offenders.append(key)
print('\n'.join(offenders))
PY
}

if [ "$SELF_TEST" = 1 ]; then
  # ⚠ PROVED AGAINST REAL SHAPES, NOT A TOY. Each fixture is copied from a real pre-fix script, so
  # a checker that goes blind stops being able to see the thing it was written for.
  fails=0
  t() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
        else printf '  FAIL %s\n       want %q\n       got  %q\n' "$1" "$2" "$3"; fails=$((fails+1)); fi; }

  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  mkdir -p "$tmp/scripts/lib"
  cp scripts/lib/selftest-flag.sh "$tmp/scripts/lib/selftest-flag.sh"

  # 1. a NEW hand-rolled script, in the exact shape of the 29 that were swept -- must be caught
  cat > "$tmp/scripts/check-brand-new.sh" <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--selftest" ]]; then
  echo "self-test"; exit 0
fi
echo "the real check"
FIX
  t "a new hand-rolled checker is caught" "scripts/check-brand-new.sh" "$(scan "$tmp")"

  # 2. the same script, routed through the library -- must be clean
  cat > "$tmp/scripts/check-brand-new.sh" <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
if selftest_requested "$@"; then
  echo "self-test"; exit 0
fi
echo "the real check"
FIX
  t "the same script, routed, is clean" "" "$(scan "$tmp")"

  # 4. ⚠ THE CORPUS CONTROL: AN EXTENSIONLESS SCRIPT MUST BE SEEN. Asserting the gate PASSES cannot
  #    tell a widened corpus from a blind one — both are green — so this asserts the offender is
  #    NAMED. Git hooks have no extension because git requires the exact names `pre-push` /
  #    `pre-commit`, and this walk already descends into `scripts/git-hooks/`; before this, every
  #    file there was dropped by the `.sh`/`.mjs` filter and the gate reported ok about a population
  #    it had never read. (infra_the_selftest_flag_gate_cannot_see_the_git_hooks_because_they_have_no_extension)
  rm -f "$tmp/scripts/check-brand-new.sh"
  mkdir -p "$tmp/scripts/git-hooks"
  cat > "$tmp/scripts/git-hooks/pre-push" <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "--selftest" ]]; then
  echo "self-test"; exit 0
fi
echo "the real hook"
FIX
  t "an extensionless hand-rolled HOOK is caught" "scripts/git-hooks/pre-push" "$(scan "$tmp")"

  # 5. and the same hook routed through the library is clean, so case 4 is catching the HAND-ROLL
  #    rather than merely catching the absence of an extension.
  cat > "$tmp/scripts/git-hooks/pre-push" <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/lib/selftest-flag.sh"
if selftest_is_flag "${1:-}"; then
  echo "self-test"; exit 0
fi
echo "the real hook"
FIX
  t "the same hook, routed, is clean" "" "$(scan "$tmp")"

  # 6. ⚠ AND AN EXTENSIONLESS NON-SCRIPT MUST NOT BE DRAGGED IN. The widened filter admits a file
  #    with no extension only if it opens with a shebang; without that clause the corpus would grow
  #    to include LICENSE, Makefile and every extensionless data file in the tree.
  printf 'not a script, just text\n' > "$tmp/scripts/git-hooks/NOTES"
  t "an extensionless NON-script is ignored" "" "$(scan "$tmp")"
  rm -f "$tmp/scripts/git-hooks/NOTES" "$tmp/scripts/git-hooks/pre-push"

  # 3. ⚠ NEGATIVE CONTROL FOR THE CALL-SITE RULE. A script that merely INVOKES another with the
  #    flag is not a handler, and flagging it would make the ratchet unusable in verify.sh.
  cat > "$tmp/scripts/check-brand-new.sh" <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
bash scripts/check-something-else.sh --self-test || exit 1
FIX
  t "a pure call site is NOT flagged" "" "$(scan "$tmp")"

  # 4. ⚠ AND THE CONTROL FOR THAT CONTROL: a file that both calls AND handles is still a handler,
  #    so rule 3 cannot be used to hide one behind a call on another line.
  cat > "$tmp/scripts/check-brand-new.sh" <<'FIX'
#!/usr/bin/env bash
set -euo pipefail
bash scripts/check-something-else.sh --self-test || exit 1
if [[ "${1:-}" == "--selftest" ]]; then echo hi; exit 0; fi
FIX
  t "a call site that ALSO handles is flagged" "scripts/check-brand-new.sh" "$(scan "$tmp")"

  # 5. a comment mentioning the flag is not a handler
  cat > "$tmp/scripts/check-brand-new.sh" <<'FIX'
#!/usr/bin/env bash
# usage: check-brand-new.sh --self-test
set -euo pipefail
echo "the real check"
FIX
  t "a comment-only mention is not flagged" "" "$(scan "$tmp")"

  # 6. ⚠ THE ONE THAT MATTERS FOR THE REAL TREE: run against the REAL scripts/ directory and
  #    require silence. A checker that has only ever been shown fixtures has not been shown that
  #    its own repo passes -- and the previous audit's 16 false positives were all in the tree.
  t "the real tree is clean" "" "$(scan "$ROOT")"

  if [ "$fails" -gt 0 ]; then printf '\ncheck-selftest-flag-contract: %d failure(s)\n' "$fails"; exit 1; fi
  printf '\ncheck-selftest-flag-contract: selftest ok\n'
  exit 0
fi

offenders="$(scan "$ROOT")"
if [ -n "$offenders" ]; then
  printf 'check-selftest-flag-contract: FAIL\n\n' >&2
  printf 'These scripts parse a self-test flag by hand instead of using the shared contract:\n\n' >&2
  printf '%s\n' "$offenders" | sed 's/^/    /' >&2
  cat >&2 <<'MSG'

Hand-rolling it is how the two spellings diverged, and how a mistyped flag came to run the
script's real action and exit 0 — a self-test that never ran, reported as a pass.

Fix it like this — FROM scripts/ :

    . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"

…or FROM INSIDE scripts/lib/ , where the file is a sibling and there is no lib/ to traverse:

    . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/selftest-flag.sh"

then:

    if selftest_requested "$@"; then
      ...the self-test...
      exit 0
    fi

If the script has arguments of its own, use `selftest_is_flag "${1:-}"` in your existing case
block and keep your own `*)` rejection.

⚠ IF YOU ARE WRITING A LIBRARY IN scripts/lib/: A SOURCED FILE MUST NOT PARSE ARGV UNGUARDED.
A sourced file that reads $1 reads its CALLER'S argv. scripts/lib/janitor.sh briefly answered
feature-ticket.sh's own `--self-test` with its own suite and exited 0 — which would have silently
replaced a real gate in verify.sh with an easier one that always passes.

TWO SHAPES ARE CORRECT, and this check accepts both:

  1. No argument handling at all — pure functions, assertions living in the caller that sources
     it. scripts/lib/claim-decision.sh. This check then has nothing to say to you, because you are
     not parsing a flag.

  2. A CLI guarded to direct execution — everything argv-related behind
        if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then … fi
     so sourcing consumes nothing. scripts/lib/ticket-source.sh.

⚠ This paragraph first said "prefer no argument handling at all", which condemned shape 2 —
correct code — and that is the SAME mistake this check was fixed for one level up: a rule that
recognises one valid form and reports the other as a violation. Whichever you pick, assert that
sourcing with a flag in argv consumes nothing; that assertion is what stops the guard being
dropped later. (fix_the_selftest_ratchet_misreads_a_library_that_is_correct)

⚠ Do NOT add the script to the LEGACY list in this file. That list is frozen and may only shrink;
adding to it is exactly the copy-the-previous-one move that produced the schism.
MSG
  exit 1
fi

# ── PART 2: A FLAG-ONLY CONTRACT IN A SCRIPT THAT HAS ARGUMENTS ─────────────────────────────────
# (fix_the_shared_red_reporter_rejects_the_argument_ci_gives_it)
#
# Part 1 asks "does it source the library?". BOTH scripts that this part was written for DID —
# they sourced it and then used the WRONG HELPER FOR THEIR SHAPE, which Part 1 cannot see. That is
# a third blind spot, alongside the "advertises a self-test it never wrote" one named above.
#
# ⚠ THE EXACT QUESTION, chosen because the header of this file records THREE wrong answers from
# trying to detect "rejects unknown arguments" by pattern: `selftest_requested "$@"` EXITS 2 on any
# non-flag argument. So a TOP-LEVEL read of $1/$2 that appears AFTER that call is dead by
# construction — it can only ever observe an empty value. That is a contradiction inside one file,
# not a judgement about intent, and it is what both real instances were:
#
#   ci-shared-red.sh              line 240 selftest_requested "$@"  ->  line 245 CAUSES="${1:?…}"
#   check-mdns-publishes-lan…sh   line 229 selftest_requested "$@"  ->  line 323 NAME="${1:-…}"
#
# ⚠ COLUMN 0 IS THE PROXY FOR "TOP LEVEL", and it is a deliberate under-reach: function bodies and
# heredocs are indented in this tree, and $2 inside a function body is a FUNCTION PARAMETER, not a
# script argument. A sweep that ignored that distinction flagged ~70 of 110 files and was useless.
# Under-reaching is the right failure direction for a ratchet: a missed instance is the status quo,
# a false one costs somebody an afternoon proving their correct script correct.
argv_after_flag_contract() { # stdin = script text · echoes the offending lines, or nothing
  awk '
    # A COMMENT MENTIONING THE CALL IS NOT THE CALL. The first version had no such guard, and the
    # comments added by THIS TICKET -- explaining why each script cannot use selftest_requested --
    # tripped it, so the gate reported the two FIXED files as broken. An instrument that matches
    # prose ABOUT the defect scores correct code as an instance; check-hooks-are-executable.sh, the
    # exemplar, was flagged for exactly that reason and it is the control that proves this clause.
    /^[[:space:]]*#/ { next }
    /selftest_requested[[:space:]]+"\$@"/ { seen = NR; next }
    # THE BRACE IS LOAD-BEARING. A braced positional read is an argv read; a bare dollar-2 inside
    # a command substitution is an awk or jq FIELD reference. Without requiring the brace this
    # matched a CLAIMED_JSON= assignment in init.sh that pipes through awk, a script with no argv
    # defect at all. NOTE: this awk program is single-quoted in the shell below, so it must contain
    # no apostrophe and no command substitution -- an apostrophe here ends the quoted string and
    # the field references leak into bash, which under set -u aborts the gate. That happened.
    seen && /^[A-Za-z_][A-Za-z0-9_]*=.*\$\{[12][:}-]/ { printf "%d:%s\n", NR, $0 }
  '
}

_p2_offenders=""
while IFS= read -r _f; do
  [ -n "$_f" ] || continue
  _hits="$(argv_after_flag_contract < "$_f")"
  [ -n "$_hits" ] && _p2_offenders="$_p2_offenders$_f
$(printf '%s' "$_hits" | sed 's/^/    /')
"
done <<EOF
$(grep -rl 'selftest_requested "\$@"' scripts --include='*.sh' 2>/dev/null || true)
EOF

if [ -n "$_p2_offenders" ]; then
  printf 'check-selftest-flag-contract: FAIL — a flag-only contract in a script that takes arguments\n\n' >&2
  printf '%s\n' "$_p2_offenders" >&2
  cat >&2 <<'MSG'
`selftest_requested "$@"` is contracted for a script whose ONLY argument is the self-test flag: it
EXITS 2 on anything else. So the argv read above it can never see a value — the script rejects its
own caller. That is not hypothetical: ci-shared-red.sh did exactly this and NEVER EXECUTED ONCE
between 2026-08-13 and 2026-08-24, silently, because its call site in ci.yml wrapped it in
`2>/dev/null || true`.

The fix is the same library used the other way round — `selftest_is_flag "$1"` plus your own `*)`
rejection, so an unrecognised `--flag` still cannot fall through and be read as a filename.
scripts/check-hooks-are-executable.sh is the exemplar and documents why.
MSG
  exit 1
fi

printf 'check-selftest-flag-contract: ok — every self-test flag goes through the shared contract\n'
