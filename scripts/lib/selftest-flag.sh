#!/usr/bin/env bash
# The self-test flag contract, in one place.
# (chore_unify_selftest_flag_spelling)
#
# ⚠ WHAT WENT WRONG, because the name of this file makes it sound cosmetic.
#
# A mistyped self-test flag did not error. It fell through the guard and ran the script's REAL
# ACTION, then exited 0. Measured across the tree on 2026-08-09: `acceptance-ui.sh --self-test`
# began real Playwright work, `init.sh --self-test` began a full stack bring-up (stopping only at
# the shared-checkout guard), `agent-stacks.sh --self-test` listed the live stacks, and four
# read-only checkers ran their real check. Every one of them exited 0.
#
# So the failure mode is a FALSE GREEN: a zero exit from a self-test that never ran. `verify.sh`
# invokes a self-test 128 times between the two spellings, and a caller cannot tell the difference
# between "the self-test passed" and "the flag was ignored and something else passed instead".
#
# ⚠ ACCEPTING BOTH SPELLINGS IS ONLY HALF THE FIX, and it is the half that feels like the whole
# one. It closes `--selftest` vs `--self-test`, which are the two we know about. It does nothing
# for `--slef-test`, `--self_test`, or whatever the next convention turns out to be — those still
# fall through and still exit 0. The defect's actual shape is:
#
#         UNKNOWN INPUT IS SILENTLY TREATED AS NO INPUT.
#
# So the contract below is BOTH halves: recognise either spelling, AND fail loudly on anything
# unrecognised. `scripts/check-backup-freshness.sh` had done this by hand for months and is the
# exemplar this was copied from, rather than invented.
#
# ── the contract ────────────────────────────────────────────────────────────────────────────────
#
#   selftest_requested "$@"   for a script whose ONLY argument is the self-test flag.
#                             returns 0  -> run the self-test
#                             returns 1  -> no arguments; run the real action
#                             exits  2   -> anything else, naming the argument
#
#   selftest_is_flag "$1"     for a script that has its own argument loop. Returns 0 if the word
#                             is either spelling. The caller keeps its own `*)` rejection.
#
# ── canonical spelling ──────────────────────────────────────────────────────────────────────────
#
# `--self-test` is canonical: it is what new code should WRITE. `--selftest` is accepted for ever
# and is not deprecated — 41 scripts, several cron units, runbooks and docs examples use it, and
# with unknown-arg rejection in place an alias costs nothing while removing one breaks callers.
# Canonicalise what the repo WRITES, not what it ACCEPTS. `scripts/check-selftest-flag-contract.sh`
# is what keeps that true for scripts written after this one.

# Is this word a self-test flag, in either spelling?
selftest_is_flag() {
  case "${1:-}" in
    --self-test|--selftest) return 0 ;;
    *) return 1 ;;
  esac
}

# The whole argument contract for a script that takes nothing but the flag.
#
# Note it EXITS rather than returning on a bad argument. That is deliberate: a `return 2` would
# be a status the caller has to remember to check, and the entire bug being fixed here is a status
# nobody checked. Sourced into the caller's shell, `exit` ends the script — which is the point.
selftest_requested() {
  case "${1:-}" in
    '')
      return 1
      ;;
    --self-test|--selftest)
      if [ "$#" -gt 1 ]; then
        printf 'unknown argument: %s\n' "$2" >&2
        printf 'usage: %s [--self-test]\n' "$(basename -- "$0")" >&2
        exit 2
      fi
      return 0
      ;;
    *)
      printf 'unknown argument: %s\n' "$1" >&2
      printf 'usage: %s [--self-test]\n' "$(basename -- "$0")" >&2
      exit 2
      ;;
  esac
}

# ── self-test ───────────────────────────────────────────────────────────────────────────────────
# Run directly, not when sourced — when sourced, $1 belongs to the caller.
#
# Every case is driven in a SUBSHELL, because two of the four outcomes are `exit 2` and a function
# that ends the script cannot otherwise be tested from inside it. That is the same property the
# contract relies on in real callers, so testing it any other way would test something else.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    ''|--self-test|--selftest) ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac

  _st_fails=0
  _st() {  # $1 label · $2 expected exit · rest: args to selftest_requested
    local label="$1" want="$2"; shift 2
    local got
    ( selftest_requested "$@" ) >/dev/null 2>&1; got=$?
    if [ "$got" = "$want" ]; then printf '  ok   %s\n' "$label"
    else printf '  FAIL %s — want exit %s, got %s\n' "$label" "$want" "$got"; _st_fails=1; fi
  }

  _st "no arguments -> 1 (run the real action)"        1
  _st "--self-test  -> 0 (run the self-test)"          0 --self-test
  _st "--selftest   -> 0 (the alias, kept for ever)"   0 --selftest
  _st "--slef-test  -> 2 (the typo that used to pass)" 2 --slef-test
  _st "--self_test  -> 2 (a third convention)"         2 --self_test
  _st "a bare word  -> 2"                              2 nonsense
  _st "-h           -> 2"                              2 -h
  # ⚠ THE TRAILING-ARGUMENT CASE. `--self-test extra` must NOT be accepted: a caller that meant to
  # pass a second argument is a caller whose contract this is not, and silently ignoring the tail
  # is the same swallow-the-input shape the whole file exists to remove.
  _st "--self-test with a trailing argument -> 2"      2 --self-test extra

  _sif() {  # $1 label · $2 expected status · $3 word
    local got; selftest_is_flag "$3" && got=0 || got=1
    if [ "$got" = "$2" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s — want %s, got %s\n' "$1" "$2" "$got"; _st_fails=1; fi
  }
  _sif "selftest_is_flag --self-test" 0 --self-test
  _sif "selftest_is_flag --selftest"  0 --selftest
  _sif "selftest_is_flag --slef-test" 1 --slef-test
  _sif "selftest_is_flag ''"          1 ''

  if [ "$_st_fails" -ne 0 ]; then printf '\nselftest-flag: FAIL\n'; exit 1; fi
  printf '\nselftest-flag: selftest ok\n'
fi
