#!/usr/bin/env bash
# agent-onboard.sh — stand an agent up: register the name, then PRINT THE LINE THAT STARTS IT.
# (feat_agent_onboarding_and_offboarding)
#
#   bash scripts/agent-onboard.sh <Name> <role>            # register, then print the launch line
#   bash scripts/agent-onboard.sh <Name> <role> --dry-run  # check and print, register nothing
#   bash scripts/agent-onboard.sh --launch-line <Name>     # just the line, for an agent already rostered
#   bash scripts/agent-onboard.sh --self-test
#
# role ∈ delivery-lead | head-of-testing | developer | process-improvement | code-reviewer | tester
#        (they name docs/roles/<role>.md; the last two are optional)
#
# The line is roster.sh's roster_launch_line, and it has two shapes: a developer or tester gets the
# delivery lead's `agent-spawn.sh` command, every other role a `cd` into its own sibling tree
# `<project>-<name>` with the row's address. It refuses (rc 1, no line) a retired name, an empty address
# and a missing tree, and for a missing tree prints the `git worktree add` that makes it.
# (backported from acme, 2026-10-25)
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
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/harness-env.sh"
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
    delivery-lead|head-of-testing|developer|process-improvement|code-reviewer|tester) ;;
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
  _t "delivery-lead is a role"             "$(onboard_verdict Wren delivery-lead 0)"    ok
  _t "head-of-testing is a role"           "$(onboard_verdict Wren head-of-testing 0)"  ok
  _t "process-improvement is a role"       "$(onboard_verdict Wren process-improvement 0)"  ok
  _t "code-reviewer is a role"             "$(onboard_verdict Wren code-reviewer 0)"    ok
  _t "tester is a role"                    "$(onboard_verdict Wren tester 0)"           ok

  # ── the launch line, which is the actual deliverable ─────────────────────────────────────────
  # Driven through `--launch-line` on a FIXTURE roster and a fixture parent directory, never the real
  # ones: the real roster has every address equal to the derived one, so it cannot tell a line that
  # reads the row from one that derives the address, and a missing-tree arm on the real parent would
  # be one bug away from creating a tree beside the real checkout. The fixture project is `acme`.
  _T="$(mktemp -d)" && [[ -d "$_T" ]] || { echo "FATAL: agent-onboard self-test cannot make a scratch dir" >&2; exit 2; }
  trap 'rm -rf "$_T"' EXIT
  _g() { env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE git -c user.name=t -c user.email=t@t -c init.defaultBranch=main "$@"; }
  _g init -q "$_T/acme" && _g -C "$_T/acme" commit -q --allow-empty -m seed \
    && _g -C "$_T/acme" update-ref refs/remotes/origin/main HEAD \
    && _g -C "$_T/acme" worktree add -q --detach "$_T/acme-vera" origin/main \
    && _g -C "$_T/acme" worktree add -q --detach "$_T/acme-lea" origin/main \
    || { echo "FATAL: agent-onboard self-test cannot build its fixture repository" >&2; exit 2; }
  printf 'not a tree\n' > "$_T/acme-pat"
  mkdir "$_T/acme-hal" && _g init -q "$_T/acme-ivy" \
    || { echo "FATAL: agent-onboard self-test cannot build its fixture directories" >&2; exit 2; }
  # Vera and Tommy carry addresses that are NOT the derived form, so a derived address is visible.
  cat > "$_T/roster.json" <<'EOF_ROSTER'
{"agents":[
 {"name":"Cara","email":"cara@example.test","role":"developer","status":"active"},
 {"name":"Tommy","email":"t.qa@example.test","role":"tester","status":"active"},
 {"name":"Vera","email":"vera.qa@example.test","role":"head-of-testing","status":"active"},
 {"name":"Lea","email":"lea@example.test","role":"delivery-lead","status":"active"},
 {"name":"Zed","email":"","role":"delivery-lead","status":"active"},
 {"name":"Quinn","email":"quinn@example.test","role":"code-reviewer","status":"active"},
 {"name":"Pat","email":"pat@example.test","role":"process-improvement","status":"active"},
 {"name":"Hal","email":"hal@example.test","role":"code-reviewer","status":"active"},
 {"name":"Ivy","email":"ivy@example.test","role":"delivery-lead","status":"active"},
 {"name":"Arnold","email":"arnold@example.test","role":"developer","status":"retired"},
 {"name":"Rhea","email":"rhea@example.test","role":"head-of-testing","status":"retired"}]}
EOF_ROSTER
  # ROSTER_DOMAIN is pinned: the fixture rows carry the seeded project's addresses, and a worktree's basename would otherwise name the domain.
  _ll() { ROSTER_FILE="$_T/roster.json" ROSTER_TREES_DIR="$_T" HARNESS_PROJECT=acme ROSTER_DOMAIN=example.test bash "$0" --launch-line "$1" 2>"$_T/err"; }
  _ll1() { local o; o="$(_ll "$1")"; printf '%s' "${o%%$'\n'*}"; }
  _snap() { find "$_T" -maxdepth 1 ! -name err -printf '%f %y\n' | sort; _g -C "$_T/acme" worktree list --porcelain; }
  _t "the fixture reads Vera's row address" "$(ROSTER_FILE="$_T/roster.json" roster_lookup_email Vera)" vera.qa@example.test

  _t "a developer is spawned by the delivery lead" "$(_ll Cara; echo "rc=$?")" \
     $'bash team/agent-spawn.sh developer --name Cara --ticket <ticket-id>\nrc=0'
  _t "a tester is spawned as a tester" "$(_ll Tommy; echo "rc=$?")" \
     $'bash team/agent-spawn.sh tester --name Tommy --ticket <ticket-id>\nrc=0'
  _t "the name is spelt as the row spells it" "$(_ll tommy) $(_ll TOMMY)" \
     'bash team/agent-spawn.sh tester --name Tommy --ticket <ticket-id> bash team/agent-spawn.sh tester --name Tommy --ticket <ticket-id>'
  _t "a head of testing starts in her own tree with the ROW's address" "$(_ll Vera; echo "rc=$?")" \
     "$(printf 'cd %q && \\\n  GIT_AUTHOR_NAME="Vera" GIT_AUTHOR_EMAIL="vera.qa@example.test" \\\n  GIT_COMMITTER_NAME="Vera" GIT_COMMITTER_EMAIL="vera.qa@example.test" \\\n  claude\nrc=0' "$_T/acme-vera")"
  _t "the delivery lead is a sibling-tree role too" "$(_ll1 Lea)" "$(printf 'cd %q && \\' "$_T/acme-lea")"
  _all="$(for _n in Cara Tommy Vera Lea; do _ll "$_n"; done)"
  _t "no line places the session with --worktree" "$(printf '%s' "$_all" | /usr/bin/grep -c -- '--work''tree')" 0
  _t "no line starts it in tmux" "$(printf '%s' "$_all" | /usr/bin/grep -c -- '--tm''ux')" 0
  _t "no line carries a derived address for a row that holds another" "$(printf '%s' "$_all" | /usr/bin/grep -cE 'vera@|tommy@')" 0

  # The refusals: rc 1, NOTHING on stdout, the reason on stderr.
  _t "a retired developer is refused" "$(_ll Arnold; echo "rc=$?")" rc=1
  _t "…as retired" "$(/usr/bin/grep -c 'retired' "$_T/err")" 1
  _t "a retired head of testing is refused" "$(_ll Rhea; echo "rc=$?")" rc=1
  _t "an empty address on the row is refused, never derived" "$(_ll Zed; echo "rc=$?")" rc=1
  _t "…naming the empty field" "$(/usr/bin/grep -c 'empty email' "$_T/err")" 1
  _t "an unrostered name is refused" "$(_ll Nobody; echo "rc=$?")" rc=1
  _t "…as not in agents/roster.json" "$(/usr/bin/grep -c 'not in agents/roster.json' "$_T/err")" 1
  _before="$(_snap)"
  _t "a missing tree is refused" "$(_ll Quinn; echo "rc=$?")" rc=1
  _t "…printing exactly one command, the worktree add of the shared checkout's sibling" \
     "$(/usr/bin/grep -c '^git ' "$_T/err") $(/usr/bin/grep '^git ' "$_T/err")" \
     "1 $(printf 'git -C %q worktree add --detach %q origin/main' "$_T/acme" "$_T/acme-quinn")"
  _t "…and creating nothing" "$(_snap)" "$_before"
  _t "a FILE where the tree should be is a missing tree" "$(_ll Pat; echo "rc=$?")" rc=1
  _t "…and the file is left alone" "$(cat "$_T/acme-pat")" 'not a tree'
  _t "a plain directory where the tree should be is a missing tree" "$(_ll Hal; echo "rc=$?")" rc=1
  _t "…and it is left empty" "$(ls -A "$_T/acme-hal")" ''
  _t "another repository where the tree should be is a missing tree" "$(_ll Ivy; echo "rc=$?")" rc=1
  _t "…and it is not made a worktree of the shared checkout" \
     "$(_g -C "$_T/acme" worktree list --porcelain | /usr/bin/grep -c 'acme-ivy$')" 0
  # The printed command is the remedy: run it (in the fixture), and the line follows.
  _ll Quinn >/dev/null; env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE bash -c "$(/usr/bin/grep '^git ' "$_T/err")" >/dev/null 2>&1
  _t "the printed worktree add makes the tree, and the line then prints" "$(_ll1 Quinn)" "$(printf 'cd %q && \\' "$_T/acme-quinn")"

  # A row onboarding has just written: roster_add writes the derived address, and the line reads it back.
  cp "$_T/roster.json" "$_T/onboard.json"
  ROSTER_FILE="$_T/onboard.json" ROSTER_DOMAIN=example.test roster_add Wren code-reviewer 2026-10-24 test >/dev/null 2>&1
  _g -C "$_T/acme" worktree add -q --detach "$_T/acme-wren" origin/main >/dev/null 2>&1
  _t "a freshly onboarded row prints its line" "$(ROSTER_FILE="$_T/onboard.json" ROSTER_TREES_DIR="$_T" HARNESS_PROJECT=acme ROSTER_DOMAIN=example.test bash "$0" --launch-line Wren 2>&1 | /usr/bin/grep -c 'GIT_AUTHOR_EMAIL="wren@example.test"')" 1
  # --dry-run has no row yet: the line comes from the facts roster_add WILL write, and says so.
  _out="$(ROSTER_FILE="$_T/roster.json" ROSTER_TREES_DIR="$_T" HARNESS_PROJECT=acme ROSTER_DOMAIN=example.test bash "$0" Wren2 developer --dry-run 2>&1)"
  _t "a dry run prints the spawn line for a developer" "$(printf '%s' "$_out" | /usr/bin/grep -cxF 'bash team/agent-spawn.sh developer --name Wren2 --ticket <ticket-id>')" 1
  _t "…and names the address it will write" "$(printf '%s' "$_out" | /usr/bin/grep -c 'wren2@example.test')" 1
  _out="$(ROSTER_FILE="$_T/roster.json" ROSTER_TREES_DIR="$_T" HARNESS_PROJECT=acme ROSTER_DOMAIN=example.test bash "$0" Wren3 code-reviewer --dry-run 2>&1)"
  _t "a dry run for a role with no tree yet prints the worktree add, not a line" \
     "$(printf '%s' "$_out" | /usr/bin/grep -c 'worktree add --detach') $(printf '%s' "$_out" | /usr/bin/grep -c 'GIT_AUTHOR')" '1 0'

  if [[ $fails -eq 0 ]]; then echo "agent-onboard --self-test: PASS"; exit 0; fi
  echo "agent-onboard --self-test: FAIL"; exit 1
fi

# `--launch-line <Name>` — for an agent already in the roster who simply needs the command.
if [[ "${1:-}" == "--launch-line" ]]; then
  NAME="${2:-}"
  [[ -n "$NAME" ]] || { printf 'usage: agent-onboard.sh --launch-line <Name>\n' >&2; exit 2; }
  roster_has_name "$NAME" || { printf '%s is not in agents/roster.json — onboard them first.\n' "$NAME" >&2; exit 1; }
  # The generator's rc is the answer: a retired name, an empty address or a missing tree prints no line.
  roster_launch_line "$NAME"
  exit $?
fi

NAME="${1:-}"; ROLE="${2:-}"; DRY=0
[[ -n "$NAME" && -n "$ROLE" ]] || {
  printf 'usage: agent-onboard.sh <Name> <role> [--dry-run]\n' >&2
  printf '       agent-onboard.sh --launch-line <Name>\n' >&2
  printf '  role: delivery-lead | head-of-testing | developer | process-improvement | code-reviewer | tester\n' >&2
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
    printf '  Use delivery-lead, head-of-testing, developer, process-improvement, code-reviewer or tester — they name\n' >&2
    printf '  docs/roles/<role>.md,\n' >&2
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

# The row exists unless this is a dry run; a dry run prints from the facts roster_add WILL write.
if [[ "$DRY" == 1 ]]; then
  printf 'The row does not exist yet: this line uses the address roster_add will write, %s.\n\n' "$(roster_email_of_name "$NAME")"
  LINE="$(roster_launch_line_for "$NAME" "$ROLE" "$(roster_email_of_name "$NAME")")"
else
  LINE="$(roster_launch_line "$NAME")"
fi || {
  printf '\nNo launch line yet: the refusal above says why. Once it is fixed, print the line with\n'
  printf '  bash scripts/agent-onboard.sh --launch-line %s\n' "$NAME"
  exit 0
}

if roster_role_is_spawned "$ROLE"; then
cat <<EOF
── THE DELIVERY LEAD STARTS A ${ROLE^^} PER TICKET, WITH THIS ─────────────────────

$LINE

agent-spawn.sh starts the session in its own worktree with the identity from the roster
row, on that ticket; agent-bench.sh stops it once the ticket has merged.
EOF
  exit 0
fi

cat <<EOF
── START THE SESSION WITH THIS, and it must be THIS ────────────────────────────

$LINE

⚠ The identity is read at LAUNCH and cannot be added afterwards. A session started
without it resolves by falling back to whichever directory it happens to stand in
— which on 2026-08-14 made five live sessions share one name out of a file written
six days earlier, with nothing reporting anything wrong.

Then, inside that session:
  1. read docs/roles/$ROLE.md — CLAUDE.md step 00 requires it and nothing enforces it
  2. bash scripts/init.sh
EOF
