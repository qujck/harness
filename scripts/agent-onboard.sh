#!/usr/bin/env bash
# agent-onboard.sh — stand an agent up: register the name, then PRINT THE LINE THAT STARTS IT.
# (feat_agent_onboarding_and_offboarding)
#
#   bash scripts/agent-onboard.sh <Name> <role>            # register, then print the launch line
#   bash scripts/agent-onboard.sh <Name> <role> --dry-run  # check and print, register nothing
#   bash scripts/agent-onboard.sh --launch-line <Name>     # just the line, for an agent already rostered
#   bash scripts/agent-onboard.sh --self-test
#
# role ∈ product-owner | head-of-testing | developer | process-improvement   (they name docs/roles/<role>.md)
#
# ── ⚠ THE PRINTED LINE IS THE DELIVERABLE, NOT A CONVENIENCE ────────────────────────────────────
#
# A session's identity comes from `$GIT_AUTHOR_*`, which belong to the PROCESS and are read at
# launch. **A running session cannot be given an identity after the fact** — and that is not a
# design opinion, it is what the 2026-08-14 incident demonstrated: five live sessions all resolved
# to a single name out of `<the shared checkout>/.agent/name`, a file written six days earlier,
# because `$GIT_AUTHOR_EMAIL` was unset in every one of them. Not one of the five could repair
# itself from the inside. So this emits a command for a human to run; a script that tried to set
# the variables would be writing them into the wrong process.
#
# That is also why the register alone was not enough. `agents/roster.json`, the resolver and the
# authorship gate had all landed and the fleet was still anonymous, because nothing anywhere told
# an agent how to start. **A register nobody can act on is a list.**
#
# ── ⚠ A NAME IS REFUSED IF IT IS KNOWN, INCLUDING A RETIRED ONE ─────────────────────────────────
#
# Retired names are NOT free. Their old commits still carry the address, so reusing one silently
# reassigns history: `git log --author` would return two different people's work under one name and
# nothing would ever flag it. `roster_add` enforces this and the check is repeated here so the
# refusal arrives before anything else happens — but the enforcement is the library's, not a
# convention this script remembers.
#
# The obvious implementation of "is this name free?" is `select(.status == "active")`, which answers
# FREE for a retired name. roster.sh's readers deliberately ignore status for exactly that reason.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib/selftest-flag.sh"
. "$REPO_ROOT/scripts/lib/roster.sh"

# PURE: (name, role, known:0|1) -> ok | bad-name | bad-role | taken
#
# ⚠ `taken` is tested AFTER shape but BEFORE anything is written, and `known` is passed in rather
# than looked up here so the whole table drives with no roster file.
onboard_verdict() { # $1 name · $2 role · $3 known 0|1
  local name="${1-}" role="${2-}" known="${3-0}"
  # The same shape init.sh:499 validates, so a name that onboards is a name that can start a session.
  [[ "$name" =~ ^[A-Za-z][A-Za-z0-9_-]{1,31}$ ]] || { printf 'bad-name'; return; }
  case "$role" in
    product-owner|head-of-testing|developer|process-improvement) ;;
    *) printf 'bad-role'; return ;;
  esac
  [[ "$known" == "1" ]] && { printf 'taken'; return; }
  printf 'ok'
}

if selftest_is_flag "${1:-}"; then
  [[ $# -eq 1 ]] || { printf 'unknown argument: %s\n' "$2" >&2; exit 2; }
  fails=0
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
         else printf '  FAIL %s\n       want %q\n       got  %q\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }

  _t "a fresh name and a real role"        "$(onboard_verdict Wren developer 0)"        ok
  _t "an ACTIVE name is taken"             "$(onboard_verdict Cara developer 1)"        taken
  # ⚠ THE CASE THAT PROTECTS HISTORY. A retired name is not free — its old commits still carry the
  # address, so reuse silently merges two people's work under one name.
  _t "a RETIRED name is taken too"         "$(onboard_verdict Arnold developer 1)"      taken
  _t "shape is checked before taken"       "$(onboard_verdict '' developer 1)"          bad-name
  _t "a leading digit is refused"          "$(onboard_verdict 9Wren developer 0)"       bad-name
  _t "a space is refused"                  "$(onboard_verdict 'Wren Two' developer 0)"  bad-name
  _t "33 characters is refused"            "$(onboard_verdict "$(printf 'W%.0s' {1..33})" developer 0)" bad-name
  _t "32 characters is accepted"           "$(onboard_verdict "$(printf 'W%.0s' {1..32})" developer 0)" ok
  _t "an unknown role is refused"          "$(onboard_verdict Wren wizard 0)"           bad-role
  _t "product-owner is a role"             "$(onboard_verdict Wren product-owner 0)"    ok
  _t "head-of-testing is a role"           "$(onboard_verdict Wren head-of-testing 0)"  ok
  _t "process-improvement is a role"       "$(onboard_verdict Wren process-improvement 0)"  ok

  # ── the launch line, which is the actual deliverable ─────────────────────────────────────────
  _line="$(roster_launch_line Wren)"
  for _needle in 'GIT_AUTHOR_NAME="Wren"' 'GIT_AUTHOR_EMAIL="wren@' 'GIT_COMMITTER_NAME="Wren"' \
                 'GIT_COMMITTER_EMAIL="wren@' '--worktree ${HARNESS_PROJECT}-wren' '--tmux'; do
    _t "launch line carries ${_needle:0:34}" \
       "$(printf '%s' "$_line" | /usr/bin/grep -cF -- "$_needle")" 1
  done
  # ⚠ THE WORKTREE IS LOWERCASED AND THE NAME IS NOT. `strength-Wren` is a different directory from
  # the convention every other tool assumes, and a capitalised GIT_AUTHOR_NAME is what the gate
  # compares against the roster — so the two cases are deliberately different and both matter.
  _t "worktree is lowercased"  "$(printf '%s' "$_line" | /usr/bin/grep -c "${HARNESS_PROJECT}-Wren" || true)" 0

  if [[ $fails -eq 0 ]]; then echo "agent-onboard --self-test: PASS"; exit 0; fi
  echo "agent-onboard --self-test: FAIL"; exit 1
fi

# `--launch-line <Name>` — for an agent already in the roster who simply needs the command.
if [[ "${1:-}" == "--launch-line" ]]; then
  NAME="${2:-}"
  [[ -n "$NAME" ]] || { printf 'usage: agent-onboard.sh --launch-line <Name>\n' >&2; exit 2; }
  roster_has_name "$NAME" || { printf '%s is not in agents/roster.json — onboard them first.\n' "$NAME" >&2; exit 1; }
  roster_launch_line "$NAME"
  exit 0
fi

NAME="${1:-}"; ROLE="${2:-}"; DRY=0
[[ -n "$NAME" && -n "$ROLE" ]] || {
  printf 'usage: agent-onboard.sh <Name> <role> [--dry-run]\n' >&2
  printf '       agent-onboard.sh --launch-line <Name>\n' >&2
  printf '  role: product-owner | head-of-testing | developer | process-improvement\n' >&2
  exit 2
}
case "${3:-}" in --dry-run) DRY=1 ;; '') ;; *) printf 'unknown argument: %s\n' "$3" >&2; exit 2 ;; esac

KNOWN=0; roster_has_name "$NAME" && KNOWN=1

case "$(onboard_verdict "$NAME" "$ROLE" "$KNOWN")" in
  bad-name)
    printf 'REFUSING: %q is not a usable agent name.\n' "$NAME" >&2
    printf '  It must match ^[A-Za-z][A-Za-z0-9_-]{1,31}$ — the same shape init.sh validates, so a\n' >&2
    printf '  name that onboards is a name that can actually start a session.\n' >&2
    exit 1 ;;
  bad-role)
    printf 'REFUSING: %q is not a role.\n' "$ROLE" >&2
    printf '  Use product-owner, head-of-testing, developer or process-improvement — they name docs/roles/<role>.md,\n' >&2
    printf '  which CLAUDE.md step 00 requires the agent to read.\n' >&2
    exit 1 ;;
  taken)
    printf 'REFUSING: %s is already in the roster (status: %s).\n' "$NAME" "$(roster_lookup_status "$NAME")" >&2
    printf '  A name is NEVER reused, and a RETIRED one is not free: its old commits still carry\n' >&2
    printf '  %s, so reusing it would silently file two agents work under one name.\n' "$(roster_lookup_email "$NAME")" >&2
    printf '  Pick another name.\n' >&2
    exit 1 ;;
esac

if [[ "$DRY" == 1 ]]; then
  printf -- '--dry-run: %s (%s) is clear to onboard. Nothing written.\n\n' "$NAME" "$ROLE"
else
  roster_add "$NAME" "$ROLE" "$(date -u +%Y-%m-%d)" "declared — onboarded by agent-onboard.sh" \
    || { printf 'roster_add failed — nothing was written.\n' >&2; exit 1; }
  printf 'Registered %s (%s) in agents/roster.json.\n' "$NAME" "$ROLE"
  printf '⚠ Commit that change — the roster is only real once it is on main.\n\n'

  # ── the ledger's per-agent LOGIN role ────────────────────────────────────────────────────────────
  # The owner, 2026-08-26: "onboarding should create and offboarding remove". Without this an agent
  # is rostered, can start a session, and CANNOT READ THE BOARD — with nothing at onboarding time to
  # say why.
  #
  # ⚠ BEST EFFORT AND NEVER FATAL. Onboarding must not fail because an optional observability
  # database is down; ledger_role_onboard returns 0 on every path. It is also NEVER SILENT — a skip
  # that says nothing reproduces exactly the state this fixes, and "the end state looks correct" has
  # already fooled us once here. (infra_onboarding_and_offboarding_do_not_touch_the_ledger_login)
  if [[ -f "$REPO_ROOT/scripts/lib/ledger-role.sh" ]]; then
    . "$REPO_ROOT/scripts/lib/ledger-role.sh"
    # email and role come from the roster we have just written — ledger.agent declares both NOT NULL,
    # and synthesising either would put a second spelling of the same fact in a second store.
    ledger_role_onboard "$NAME" "$(roster_lookup_email "$NAME")" "$ROLE" "$(date -u +%Y-%m-%d)"
    printf '\n'
  fi
fi

cat <<EOF
── START THE SESSION WITH THIS, and it must be THIS ────────────────────────────

$(roster_launch_line "$NAME")

⚠ The identity is read at LAUNCH and cannot be added afterwards. A session started
without it resolves by falling back to whichever directory it happens to stand in
— which on 2026-08-14 made five live sessions share one name out of a file written
six days earlier, with nothing reporting anything wrong.

Then, inside that session:
  1. read docs/roles/$ROLE.md — CLAUDE.md step 00 requires it and nothing enforces it
  2. bash scripts/init.sh
EOF
