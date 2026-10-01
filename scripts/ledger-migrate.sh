#!/usr/bin/env bash
# scripts/ledger-migrate.sh — apply ledger migrations, and RECORD that you did.
#
# ⚠ WHY THIS EXISTS: THE SANCTIONED APPLY PATH USED TO BE A LINE OF DOCUMENTATION.
# `ledger-db-deploy.sh` prints it at the end of every run:
#
#     docker exec -i strength-ledger-db psql -U ledger_owner -d ledger -v ON_ERROR_STOP=1 -f - < <file>
#
# That applies the DDL and records nothing, so the database could not say which of its own
# migrations it was carrying. Measured 2026-08-29: 17, 18, 19, 20 and 21 were all merged to main and
# NOT ONE was applied — found by diffing schemas and reading five file headers to work out what each
# absence meant. One of them (18) was breaking the owner's work-items screen with
# `permission denied for table request`.
#
# ⚠ THE RECORD AND THE DDL GO IN ONE TRANSACTION, AND THAT IS THE WHOLE DESIGN.
# A migration that half-applied and recorded itself is WORSE than one that recorded nothing: the
# next reader is told it ran. So the stream sent to psql is
#
#     BEGIN;  <the file>  INSERT INTO ledger.schema_migration …;  COMMIT;
#
# with ON_ERROR_STOP=1, so a failure anywhere rolls back BOTH halves and the table is unchanged.
# Driven as a negative control: a file whose LAST statement raises leaves NO row. See --selftest for
# the pure half and docs on the ticket for the live driving.
#
# ⚠ THIS DOES NOT REPLACE `check-ledger-schema-rebuilds.sh` AND MUST NOT BE READ AS DOING SO. This
# records what was APPLIED; that compares what the schema now IS. Something changed by hand outside
# a migration is invisible here and visible there. They are complements, and their DISAGREEMENT —
# a file recorded as applied whose objects are missing — is a real state the gate now reports.
#
# ⚠ `ledger_owner` IS A ROLE, NOT A PERSON. The DDL needs owner privileges, so `applied_by` is
# `session_user` and will read `ledger_owner` for every row this tool writes. That is the truthful
# database-level answer and it is NOT an answer to "who did this". The agent's own name goes in
# `note`, which is why this refuses to run without a session-proven identity: a deploy nobody can be
# asked about is the same defect as a claim nobody can be asked about.
# (infra_nothing_records_which_ledger_migrations_are_applied_to_the_live_instance)
#
# Usage:
#   bash scripts/ledger-migrate.sh status              what is applied, what is pending
#   bash scripts/ledger-migrate.sh apply --all         apply every pending file, in order
#   bash scripts/ledger-migrate.sh apply <file>        apply exactly one (still refuses to skip)
#   bash scripts/ledger-migrate.sh --selftest
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
cd "$(dirname "$0")/.."

SRC="infra/ledger-db"
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/harness-env.sh"
CONTAINER="${LEDGER_CONTAINER:-${HARNESS_PROJECT}-ledger-db}"
# The file that creates the record. Anything ordered BELOW it and absent from the table predates the
# record rather than being pending — see file_verdict.
BOOTSTRAP='001-baseline.sql'   # the template's baseline is the first recorded migration

# ── PURE — SOURCED, NOT COPIED ───────────────────────────────────────────────────────────────────
# ⚠ `scripts/check-ledger-schema-rebuilds.sh` needs the same verdicts to say WHICH SIDE IS STALE.
# A second copy there would let the tool and the gate disagree about whether an instance is
# behind — and the gate's whole problem was that it could not say. Two answers to that question
# would be worse than the none it had. This file's --selftest is what covers them; the gate is
# ci-exempt and runs only when somebody chooses to run it.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/ledger-migration-state.sh"

# ── SELF-TEST ───────────────────────────────────────────────────────────────────────────────────
# ⚠ `selftest_is_flag`, NOT `selftest_requested`. This script has SUBCOMMANDS, and
# `selftest_requested` implements the whole argument contract for a script that takes nothing
# but the flag — it EXITS 2 on any other word. Sourced in, that made `status` and `apply` die
# with `unknown argument: status` before a line of this file ran. Caught by a control whose
# result then read as a PASS: the negative control reported "0 rows, no table", which is what
# success looks like, and it came from the migration never having been attempted.
# ── WHO MAY APPLY A MIGRATION, AND HOW THE RECORD SAYS SO ────────────────────────────────────────
# (infra_the_owner_cannot_satisfy_the_identity_guard_on_the_tool_he_is_told_to_run)
#
# ⚠ THE GUARD WAS RIGHT AND ITS POPULATION WAS WRONG. `_agent_name` proves the name came from the
# SESSION rather than from a directory label — the 2026-08-14 defect, five sessions under one name,
# none able to fix it from the inside. That is worth keeping exactly as it is. But it establishes
# the name by resolving $GIT_AUTHOR_EMAIL through `agents/roster.json`, and the roster holds twelve
# entries, every one an agent on @weaversite.co.uk. **The owner applies the migrations and is not in
# it**, so the one human who runs this tool is the one identity it cannot accept — and the remedy it
# printed, `agent-onboard.sh --launch-line`, is an AGENT onboarding path he cannot use. A guard whose
# remedy is unavailable to the person it stops is the shape CLAUDE.md warns about: it pushes people
# toward the workaround, and here the workaround is borrowing an agent's email, which writes a FALSE
# actor into an append-only record whose entire purpose is attribution.
#
# ⚠ THE QUESTION WAS "IS THE APPLIER FIELD'S DOMAIN ROSTER ENTRIES OR IDENTITIES", AND THE SCHEMA
# ANSWERS NEITHER. `schema_migration.applied_by` is `session_user` — it reads `ledger_owner` for
# every row this tool writes, a Postgres ROLE, never a roster name. The person is recorded in `note`,
# which is free prose. **No column here has "roster entry" as its domain**; the roster appears only
# in the tool's CHECK and never in its RECORD. So adding the owner to `agents/roster.json` would
# make the agent roster mean two things in order to satisfy a check that writes it nowhere — and
# several consumers iterate that file expecting agents.
#
# ⚠ AND `scripts/lib/agent-name.sh` SETTLES THE STRENGTH QUESTION IN ITS OWN WORDS: the roster rung
# "proves the provenance of an ENVIRONMENT VARIABLE, not of an agent: anyone may set this to any
# name in the roster. It is an ANTI-MISTAKE control … NOT a boundary against deliberate
# misattribution." A declared name is therefore EXACTLY as strong as the rung it stands beside. It
# is not a hole being opened; it is the same strength, labelled honestly — which is why the note
# records HOW the name was established and never pretends the two are the same.
#
# ⚠ THE SIBLING GUARD WAS CHECKED AND IS CORRECT — do not "fix" it too. `_require_session_identity`
# in scripts/ledger-db.sh gates `claim`, `park` and `flip-passing`: agent OWNERSHIP decisions, which
# the owner does not make. Its population genuinely is agents. Reads are unaffected there and always
# were.

# declared_name_verdict <name> <is it a roster name: yes|no>  ->  ok | invalid | is-an-agent
# ⚠ A ROSTER NAME IS REFUSED HERE ON PURPOSE. `--as Ed` would record a rostered agent as
# self-declared — downgrading an identity that has a stronger route available, and blurring the two
# populations the note exists to keep apart. If you are an agent, prove it the agent way.
declared_name_verdict() {
  # ⚠ SOURCED HERE, THE SAME WAY `_agent_name` DOES IT. `agent_name_valid` is the one definition of
  # what a name is, and re-implementing the pattern would let this function and the session route
  # disagree about the same string — the exact confusion agent-name.sh was written to end.
  source scripts/lib/agent-name.sh 2>/dev/null || true
  local name="${1-}" in_roster="${2-}"
  agent_name_valid "$name" || { printf 'invalid'; return; }
  [[ "$in_roster" == yes ]] && { printf 'is-an-agent'; return; }
  printf 'ok'
}

# applier_note <name> <session|declared>  ->  the `note` column's text
# ⚠ THE PROVENANCE IS IN THE RECORD, NOT JUST IN THE TOOL. Accepting a weaker identity without
# saying it was weaker is how a record stops meaning anything: a reader two months out cannot ask
# the tool how a name got there, only the row. Both shapes name a person; only one claims the
# roster stood behind it.
applier_note() {
  local who="${1-}" prov="${2-}"
  case "$prov" in
    session)  printf 'applied by %s (roster-verified session identity) via ledger_owner (ledger_owner is a ROLE, not a person)' "$who" ;;
    declared) printf 'applied by %s (SELF-DECLARED with --as, not roster-verified) via ledger_owner (ledger_owner is a ROLE, not a person)' "$who" ;;
    *)        printf 'applied by %s (provenance unrecorded — this is a defect, see applier_note) via ledger_owner' "$who" ;;
  esac
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  _f=0
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"
         else printf '  FAIL  %s\n    got:  %s\n    want: %s\n' "$1" "$2" "$3"; _f=1; fi; }
  printf 'ledger-migrate --selftest\n'
  B="$BOOTSTRAP"

  # ── who may apply, and how the record says so ──
  # (infra_the_owner_cannot_satisfy_the_identity_guard_on_the_tool_he_is_told_to_run)
  # ⚠ THE CASE THE TOOL EXISTS TO ADMIT: a real person who is not an agent. The owner applies these
  # migrations and is not in agents/roster.json — twelve entries, every one an agent.
  _t "a non-agent person may declare a name"  "$(declared_name_verdict Peter no)"    ok
  # ⚠ AND THE CASE IT MUST REFUSE, WHICH IS THE ONE THAT KEEPS THE RECORD MEANINGFUL. An agent has a
  # stronger route; recording one as self-declared downgrades an identity for no reason and blurs
  # the two populations the note exists to keep apart.
  _t "a roster name is refused via --as"      "$(declared_name_verdict Ed yes)"      is-an-agent
  _t "…and that is about the ROSTER, not the spelling" "$(declared_name_verdict Ed no)" ok
  # Shape, borrowed from agent_name_valid so the two cannot disagree about what a name is.
  _t "an empty name is not a name"            "$(declared_name_verdict '' no)"       invalid
  _t "a path is not a name"                   "$(declared_name_verdict 'a/b' no)"    invalid
  _t "whitespace is not a name"               "$(declared_name_verdict '  ' no)"     invalid
  _t "a leading digit is not a name"          "$(declared_name_verdict '9Ed' no)"    invalid
  # ⚠ ORDER MATTERS: an INVALID name that happens to be flagged as a roster hit is still invalid.
  # Validating second would report a malformed string as "that is an agent", which is a confident
  # wrong answer about a different thing.
  _t "invalid beats is-an-agent"              "$(declared_name_verdict 'a/b' yes)"   invalid

  # ⚠ THE PROVENANCE MUST REACH THE ROW, NOT JUST THE TOOL. Accepting a weaker identity without
  # recording that it was weaker is how an append-only record stops meaning anything: a reader two
  # months out can only ask the row.
  _t "a session identity says roster-verified" \
     "$(applier_note Ed session)" \
     'applied by Ed (roster-verified session identity) via ledger_owner (ledger_owner is a ROLE, not a person)'
  _t "a declared identity says SELF-DECLARED" \
     "$(applier_note Peter declared)" \
     'applied by Peter (SELF-DECLARED with --as, not roster-verified) via ledger_owner (ledger_owner is a ROLE, not a person)'
  # ⚠ NEGATIVE CONTROL ON THE WHOLE POINT: the two notes must not be confusable. If a future edit
  # makes them agree, this fires — the assertions above would both still pass on identical strings.
  _t "the two provenances are distinguishable" \
     "$([[ "$(applier_note X session)" == "$(applier_note X declared)" ]] && echo SAME || echo different)" \
     different
  # ⚠ AND AN UNRECORDED PROVENANCE IS NOT SILENTLY TREATED AS THE STRONGER ONE. A missing third
  # argument must never render as "roster-verified"; it says it is a defect, in the row.
  _t "an unknown provenance does not claim verification" \
     "$(applier_note Someone '' | grep -c 'roster-verified')" 0

  _t "a recorded file is applied"            "$(file_verdict '017-a.sql' yes "$B")" applied
  _t "an unrecorded LATER file is pending"   "$(file_verdict '024-x.sql' no "$B")"  pending
  # ── A RENUMBERED FILE IS NOT PENDING ──────────────────────────────────────────────────────────
  # ⚠ THE TEST TRAP HERE IS SPECIFIC: asserting that `status` no longer says BEHIND is satisfied by a
  # tool that says NOTHING AT ALL. The useful half is the SENTENCE — it must name the file the
  # content was applied under — so these assert the verdict that produces it, and the live driving
  # below asserts the name appears in the output.
  _t "content applied under another name is not pending" \
     "$(file_verdict '041-seed.sql' no "$B" '038-seed.sql')" applied-elsewhere
  # ⚠ NEGATIVE CONTROL: a twin that is the file's OWN name is the ordinary applied case, not this
  # one. Without this, any recorded row would reclassify its own file as "applied elsewhere".
  _t "a twin equal to the file itself is not 'elsewhere'" \
     "$(file_verdict '024-x.sql' no "$B" '024-x.sql')" pending
  # ⚠ AND AN EMPTY TWIN CHANGES NOTHING — every existing caller passes three arguments, so a
  # checksum nobody looked up must not silently reclassify a genuinely pending file.
  _t "no twin leaves the old verdict exactly as it was" \
     "$(file_verdict '024-x.sql' no "$B" '')" pending
  _t "a recorded file wins over any twin"    "$(file_verdict '017-a.sql' yes "$B" '038-seed.sql')" applied
  # ⚠ THE THIRD STATE — an unrecorded EARLIER file predates the record, it is not work to do.
  # (these two use a LATER bootstrap name than the template's 001-baseline.sql: in the template nothing
  # can predate the record, so the pure function's "predates" branch is exercised with a fixture name)
  _t "an unrecorded EARLIER file predates"   "$(file_verdict '022-x.sql' no '023-record.sql')"  predates-the-record
  _t "01-schema predates too"                "$(file_verdict '001-schema.sql' no '023-record.sql')" predates-the-record
  # ⚠ THE BOOTSTRAP ITSELF IS NOT 'EARLIER THAN ITSELF'. Off-by-one here would report the file that
  # creates the table as predating the table.
  _t "the bootstrap itself is pending when unrecorded" "$(file_verdict "$B" no "$B")" pending
  _t "the bootstrap itself is applied when recorded"   "$(file_verdict "$B" yes "$B")" applied
  # ⚠ `01a` SORTS AFTER `01-` IN BYTE ORDER (a=0x61 > -=0x2D) — the same sort-order trap the
  # catalogue digest was bitten by. Both still predate the bootstrap, which is what matters here.
  _t "01a sorts sanely and still predates"   "$(file_verdict '001a-seed.sql' no '023-record.sql')" predates-the-record

  _t "in order -> ok"                 "$(order_verdict 17-a.sql 17-a.sql)" ok
  _t "skipping one -> out-of-order"   "$(order_verdict 19-c.sql 17-a.sql)" out-of-order
  _t "nothing pending is its own state" "$(order_verdict 19-c.sql '')"     nothing-pending

  _t "no table -> no-record, NOT nothing-applied" "$(instance_verdict no 0 0)"  no-record
  _t "pending work -> behind"                     "$(instance_verdict yes 20 3)" behind
  _t "all recorded -> current"                    "$(instance_verdict yes 24 0)" current
  _t "table exists but empty -> its own state"    "$(instance_verdict yes 0 0)"  empty-record

  # ── IS THIS CHECKOUT THE WHOLE POPULATION? (clause 1/2 of the ticket) ──────────────────────────
  # ⚠ `stale 0 -> unknown`, NOT `complete`, IS THE ARM THAT MATTERS. If the fetch failed, zero
  # missing may mean "nothing is missing" or "our origin/main is as old as our tree", and those are
  # different facts. Collapsing them is the defect this whole ticket is about, one level up.
  _t "fetched, nothing upstream we lack -> complete"   "$(tree_verdict fresh 0)"  complete
  _t "files exist upstream and not here -> incomplete" "$(tree_verdict fresh 3)"  incomplete
  _t "could not fetch, zero missing -> UNKNOWN"        "$(tree_verdict stale 0)"  unknown
  _t "could not fetch, but files ARE missing -> still incomplete (positive evidence)" \
                                                       "$(tree_verdict stale 2)"  incomplete
  _t "a non-numeric count is unknown, never complete"  "$(tree_verdict fresh x)"  unknown

  # ── drift_verdict — what the GATE says, tested here because this is where the self-test lives ──
  # ⚠⚠ THE ARM THAT MATTERS: a single unapplied migration that both DROPS and ADDS shows as BOTH
  # directions in a schema diff, and the old gate called that "two separate facts, not one drift".
  # It is ONE fact, and `unapplied` counts FILES, so it says so.
  _t "unapplied files -> live-behind, however many directions the diff took" \
    "$(drift_verdict yes 5 0)" live-behind
  _t "live carries files the repo lacks -> repo-behind" "$(drift_verdict yes 0 2)" repo-behind
  _t "genuinely two facts -> both"                      "$(drift_verdict yes 3 2)" both
  # ⚠ THE COMPLEMENT CASE, AND THE ARGUMENT FOR KEEPING THE SCHEMA DIFF: every migration accounted
  # for and the schemas still differ, so something changed OUTSIDE a migration. The record cannot
  # see it by construction; the diff cannot name it; only both together can.
  _t "all migrations accounted for but schemas differ -> unrecorded-change" \
    "$(drift_verdict yes 0 0)" unrecorded-change
  # ⚠ NO RECORD IS NOT A VERDICT ABOUT DRIFT. It is the state the ledger was in before this table.
  _t "no record -> unclassifiable, never a guess"       "$(drift_verdict no 0 0)"  unclassifiable
  _t "no record outranks the counts"                    "$(drift_verdict no 9 9)"  unclassifiable

  [[ $_f -eq 0 ]] && printf 'ledger-migrate: self-test PASSED\n' \
                  || printf 'ledger-migrate: self-test FAILED\n' >&2
  exit "$_f"
fi

# ── LIVE ────────────────────────────────────────────────────────────────────────────────────────

_up() { docker exec "$CONTAINER" true >/dev/null 2>&1; }
_psql() { docker exec -i "$CONTAINER" psql -U ledger_owner -d ledger -v ON_ERROR_STOP=1 -tA "$@"; }

_files() { # every migration on disk, in the order Postgres's initdb mount would run them
  find "$SRC" -maxdepth 1 -name '*.sql' -type f -printf '%f\n' | LC_ALL=C sort
}

_has_table() {
  local r; r="$(_psql -c "select to_regclass('ledger.schema_migration') is not null" 2>/dev/null)"
  [[ "$r" == t ]] && printf 'yes\n' || printf 'no\n'
}

# _recorded_file_with_same_content — the RECORDED filename whose checksum equals this file's, or ''.
#
# ⚠ THIS IS WHAT MAKES A RENUMBERED MIGRATION READABLE. `schema_migration` is append-only by trigger,
# so a renumber leaves the old row permanently — correctly, it records what actually ran. Without
# this lookup the new name is simply unrecorded, and "unrecorded" was reported as PENDING.
#
# ⚠ IT COMPARES CONTENT, NOT NUMBERS. A file that merely SORTS near an applied one is not the same
# migration; only the checksum can say the content already ran. Two files with identical content
# under different names is exactly the renumber case and nothing else.
_recorded_file_with_same_content() { # $1 filename in $SRC
  local f="${1-}" sum
  [[ -n "$f" && -f "$SRC/$f" ]] || return 0
  sum="$(sha256sum "$SRC/$f" | cut -d' ' -f1)"
  [[ -n "$sum" ]] || return 0
  # ⚠ ONE QUERY PER UNRECORDED FILE, and only unrecorded ones reach here. `-tA` so the answer is the
  # bare filename with no padding to trim.
  # ⚠⚠ `</dev/null` IS LOAD-BEARING, NOT TIDINESS. `_psql` is `docker exec -i`, which DRAINS the
  # caller's stdin — and this runs inside `while read … done < <(_files)`. Without it the first
  # unrecorded file eats the rest of the list and the loop simply stops: driven here, it reported
  # **24 of 45 files** and the renamed migration never appeared at all. The signature is a count far
  # below the subject count with nothing marked failed, and a short clean report is what a partial
  # sweep looks like.
  # ⚠ The redirect is correct HERE because this psql's stdin is INCIDENTAL — the SQL travels in `-c`.
  # Applied to a command whose stdin is its DATA the same remedy would delete the input.
  _psql -c "select filename from ledger.schema_migration where checksum = '$(_sql_string "$sum")' \
            and filename <> '$(_sql_string "$f")' order by filename limit 1" </dev/null 2>/dev/null | head -1
}

_recorded() { # the filenames the instance says it carries, one per line
  _psql -c "select filename from ledger.schema_migration order by filename" 2>/dev/null
}

_agent_name() {
  source scripts/lib/agent-name.sh 2>/dev/null || true
  local src n
  src="$(agent_name_source 2>/dev/null || true)"
  n="$(agent_name_resolved 2>/dev/null || true)"
  [[ "$src" == session && -n "$n" ]] || return 1
  printf '%s' "$n"
}

_sql_string() { printf "%s" "$1" | sed "s/'/''/g"; }   # single-quote escaping for a psql literal

cmd="${1-status}"

case "$cmd" in
  status)
    _up || { echo "ledger-migrate: the ledger container '$CONTAINER' is not running — nothing was read." >&2
             echo "  ⚠ exit 2 = CANNOT LOOK. This is deliberately not 0: reporting 'could not look' as" >&2
             echo "     'looked and agreed' is a control that cannot fail wearing a green." >&2
             exit 2; }
    # ── WHICH TREE DID WE JUST ENUMERATE, AND IS IT THE WHOLE POPULATION? ────────────────────
    # ⚠ `SRC` is the WORKING TREE, so everything below is a statement about YOUR CHECKOUT. Saying
    # so is clause (1); refusing to call an incomplete tree `current` is clause (2); and NOT
    # switching the subject to origin/main is clause (5) -- an author's new migration must stay
    # visible to the tool that applies it.
    #
    # ⚠ EXPLICIT REFSPEC. `git fetch origin main` updates refs/remotes/origin/main only
    # opportunistically, so a fetch can report success and leave the ref untouched -- which would
    # restore this very defect wearing a fix. `main:refs/remotes/origin/main` is not optional.
    # (driven by Anthony, 2026-08-30)
    _fetch=stale
    git fetch --quiet origin main:refs/remotes/origin/main >/dev/null 2>&1 && _fetch=fresh
    _upstream_missing=(); _behind='?'
    if git rev-parse --verify -q origin/main >/dev/null 2>&1; then
      _behind="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo '?')"
      while IFS= read -r _uf; do
        [[ -n "$_uf" ]] || continue
        [[ -e "$_uf" ]] || _upstream_missing+=("${_uf##*/}")
      done < <(git ls-tree --name-only origin/main "$SRC/" 2>/dev/null | grep -E '\.sql$')
    fi
    _tv="$(tree_verdict "$_fetch" "${#_upstream_missing[@]}")"

    has="$(_has_table)"
    rec_list=''; [[ "$has" == yes ]] && rec_list="$(_recorded)"
    applied=0 pending=0 predates=0 elsewhere=0
    pending_files=()
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      # ⚠ MATCH ON THE MIGRATION KEY, NOT THE RAW NAME. The record holds the filename each
      # migration had when it ran; the padding rename changed every one of those names. See
      # migration_key in scripts/lib/ledger-migration-state.sh for why the record is not rewritten.
      r=no
      if grep -qxF "$f" <<<"$rec_list"; then r=yes
      elif grep -qxF "$(migration_key "$f")" <<<"$(while IFS= read -r _rl; do [[ -n "$_rl" ]] && migration_key "$_rl"; done <<<"$rec_list")"; then r=yes
      fi
      # ⚠ THE TWIN LOOKUP IS ONLY DONE FOR UNRECORDED FILES, against a map fetched once — not a query
      # per file. A renumbered migration is rare; paying for the answer on every recorded file would
      # make `status` slower for everybody in order to describe nobody.
      _twin=''
      if [[ "$r" == no && -f "$SRC/$f" ]]; then
        _twin="$(_recorded_file_with_same_content "$f")"
      fi
      case "$(file_verdict "$f" "$r" "$BOOTSTRAP" "$_twin")" in
        applied)             applied=$((applied+1)); printf '  applied              %s\n' "$f" ;;
        predates-the-record) predates=$((predates+1)); printf '  predates the record  %s  (ran before this table existed — NOT work to do)\n' "$f" ;;
        # ⚠ THE SENTENCE IS THE USEFUL HALF, NOT THE COUNT. "PENDING" with no explanation is what
        # sent agents to `apply --all`; naming the file the content actually ran under is what lets a
        # reader decide in one line that there is nothing to do.
        applied-elsewhere)   elsewhere=$((elsewhere+1)); printf '  already applied      %s  (its content ran as %s — renumbered; NOT work to do)\n' "$f" "$_twin" ;;
        pending)             pending=$((pending+1)); pending_files+=("$f"); printf '  ⚠ PENDING            %s\n' "$f" ;;
      esac
    done < <(_files)

    # ⚠⚠ THE LOOP MUST HAVE SEEN EVERY FILE, AND IT SILENTLY DID NOT. A command inside a
    # `while read … done < <(…)` that reads stdin DRAINS the list: `_psql` is `docker exec -i`, and
    # when the twin lookup was added without `</dev/null` this loop reported **24 of 45 files** and
    # stopped. Nothing was marked failed — a partial sweep and a clean one look identical, because
    # both say only good news.
    # ⚠ SO THE COUNT IS ASSERTED RATHER THAN ASSUMED. This is the instrument checking itself; every
    # number printed above is a claim about a population, and this is the only line that says the
    # population was fully read.
    _seen=$(( applied + predates + pending + elsewhere ))
    _have=$(_files | grep -c . || true)
    if [[ "$_seen" -ne "$_have" ]]; then
      printf '\n  ⚠ THIS REPORT IS INCOMPLETE — it classified %d file(s) of %d in the tree.\n' "$_seen" "$_have"
      printf '     Every count above is a floor, not a total. Do NOT act on them.\n'
      printf '     The usual cause is a command inside the scan reading stdin and draining the list.\n'
    fi

    printf '\n  tree enumerated      %s/ in THIS CHECKOUT (HEAD %s)\n' "$SRC" "$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
    case "$_tv" in
      complete)
        printf '  vs origin/main       %s commit(s) behind; it carries no migration this tree lacks (fetched just now)\n' "$_behind" ;;
      incomplete)
        printf '  ⚠ vs origin/main     %s commit(s) behind, and %d migration file(s) EXIST THERE AND NOT HERE:\n' "$_behind" "${#_upstream_missing[@]}"
        printf '        %s\n' "${_upstream_missing[@]}"
        printf '     ⚠ THIS REPORT CANNOT SEE THEM. Everything above is about YOUR TREE, so a low\n'
        printf '        pending count here says nothing about the database. Pull, then re-run.\n' ;;
      unknown)
        printf '  ⚠ vs origin/main     COULD NOT LOOK — the fetch failed, so this checkout may be as old\n'
        printf '        as its copy of origin/main. Zero missing is not evidence of nothing missing.\n' ;;
    esac

    v="$(instance_verdict "$has" "$applied" "$pending")"
    printf '\n'
    case "$v" in
      no-record)
        printf 'ledger-migrate: THIS INSTANCE HAS NO MIGRATION RECORD (ledger.schema_migration is absent).\n'
        printf '  ⚠ That is NOT the same as "nothing has been applied" — an instance built before the\n'
        printf '     record existed carries every migration and has no table to say so. Apply\n'
        printf '     %s to create it; its backfill records what preceded it.\n' "$BOOTSTRAP"
        exit 1 ;;
      behind)
        printf 'ledger-migrate: BEHIND — %d file(s) applied, %d predate the record, %d already applied under another name, %d PENDING.\n' "$applied" "$predates" "$elsewhere" "$pending"
        printf '  Apply them in order:  bash scripts/ledger-migrate.sh apply --all\n'
        exit 1 ;;
      current)
        # ⚠ "%d applied" READ AS A MIGRATION NUMBER IS EXACTLY BACKWARDS, and it happened: `28
        # applied, 0 pending` was read as "#28 is applied" when 28 was one of the three that was
        # NOT. The count now says what it counts. (clause 4)
        if [[ "$_tv" == complete ]]; then
          printf 'ledger-migrate: current — %d file(s) applied, %d predate the record, %d already applied under another name, 0 pending IN THIS TREE.\n' "$applied" "$predates" "$elsewhere"
          exit 0
        fi
        # ⚠ clause (2): an incomplete or unverifiable tree must NOT report as current. `0 pending`
        # is the answer the asker was hoping for, and it closed the question for four hours.
        printf 'ledger-migrate: 0 pending IN THIS TREE — but the tree is %s, so this is NOT "the database is current".\n' "$_tv"
        printf '  %d file(s) applied, %d predate the record, %d already applied under another name. Read the tree lines above before acting on this.\n' "$applied" "$predates" "$elsewhere"
        exit 1 ;;
      *)
        printf 'ledger-migrate: the record EXISTS BUT IS EMPTY — no file claims to have been applied.\n'
        printf '  ⚠ Its own bootstrap should have recorded itself, so this is a defect in the record,\n'
        printf '     not a report about the schema. Do not re-apply anything on the strength of it.\n'
        exit 1 ;;
    esac ;;

  apply)
    _up || { echo "ledger-migrate: the ledger container '$CONTAINER' is not running." >&2; exit 2; }
    # ⚠ `--as` IS PARSED OUT FIRST so it may sit either side of the target, and `shift`ing here
    # keeps the target positional exactly as it was for every existing caller.
    declared=''
    args=(); shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        # ⚠ `shift 2` FAILS when --as is the LAST argument, and with `|| true` after it the loop
        # never advances — an infinite spin on a typo. Take the value only if there is one.
        --as) [[ $# -ge 2 ]] || { echo "ledger-migrate: --as needs a name" >&2; exit 1; }
              declared="$2"; shift 2 ;;
        --as=*) declared="${1#--as=}"; shift ;;
        *) args+=("$1"); shift ;;
      esac
    done
    set -- "${args[@]+"${args[@]}"}"

    prov=''
    if who="$(_agent_name)"; then
      prov=session
      # ⚠ A SESSION IDENTITY WINS AND `--as` IS REFUSED BESIDE IT, rather than silently ignored.
      # Ignoring it would let someone believe they had recorded a different applier than the row
      # actually names — a wrong belief about an append-only record, which is the failure this
      # whole file exists to prevent.
      if [[ -n "$declared" ]]; then
        echo "ledger-migrate: REFUSING — you have a roster-verified session identity ($who)," >&2
        echo "  so --as would record a WEAKER provenance than the one you already have." >&2
        echo "  Drop --as and run it as yourself." >&2
        exit 3
      fi
    elif [[ -n "$declared" ]]; then
      # ⚠ MATCH THE NAME FIELD, NOT THE FILE TEXT. A substring grep over roster.json answers a
      # neighbouring question — it hits an email local-part, a role, a comment — and here a false
      # `yes` refuses a legitimate applier while a false `no` records an agent as self-declared.
      in_roster=no
      if command -v jq >/dev/null 2>&1; then
        jq -e --arg n "$declared" '[(.agents // .)[] | .name] | index($n) != null' \
           agents/roster.json >/dev/null 2>&1 && in_roster=yes
      else
        # ⚠ NO jq: FAIL TOWARD `yes`. An unreadable roster must not let a name through as
        # not-an-agent — refusing is recoverable and visible; a mislabelled append-only row is not.
        echo "ledger-migrate: cannot read agents/roster.json (no jq) — refusing --as rather than" >&2
        echo "  guessing whether '$declared' is an agent. Install jq, or use the session route." >&2
        exit 3
      fi
      case "$(declared_name_verdict "$declared" "$in_roster")" in
        ok)          who="$declared"; prov=declared ;;
        is-an-agent) echo "ledger-migrate: REFUSING — '$declared' is a name in agents/roster.json." >&2
                     echo "  An agent has a stronger route: launch the session with its identity" >&2
                     echo "  (bash scripts/agent-onboard.sh --launch-line $declared) and drop --as." >&2
                     echo "  --as exists for a person who is NOT an agent; recording one as" >&2
                     echo "  self-declared would blur the two the note keeps apart." >&2
                     exit 3 ;;
        *)           echo "ledger-migrate: REFUSING — '$declared' is not a usable name." >&2
                     echo "  Letters, digits, _ and -, starting with a letter, 2-32 characters." >&2
                     exit 3 ;;
      esac
    else
      echo "ledger-migrate: REFUSING — your identity came from this DIRECTORY, not your session." >&2
      echo "  A deploy nobody can be asked about is the same defect as a claim nobody can be asked" >&2
      echo "  about. \`ledger_owner\` is a role; the note needs a person." >&2
      echo "" >&2
      # ⚠ BOTH REMEDIES, BECAUSE ONE OF THEM WAS UNAVAILABLE TO THE PERSON THIS MOST OFTEN STOPS.
      # The owner applies these migrations and is not in the agent roster, so the onboarding line
      # below has never been a route he could take. A guard that names only a remedy its subject
      # cannot use is what sends people to the workaround — here, borrowing an agent's email.
      echo "  If you are an AGENT — fix it at the session, which is the stronger route:" >&2
      echo "      bash scripts/agent-onboard.sh --launch-line <YourName>" >&2
      echo "  If you are NOT an agent (the owner, a guest) — declare the name, and the record will" >&2
      echo "  say it was self-declared rather than roster-verified:" >&2
      echo "      bash scripts/ledger-migrate.sh apply --all --as <YourName>" >&2
      exit 3
    fi

    target="${1-}"
    [[ -n "$target" ]] || { echo "ledger-migrate: apply needs --all or a filename" >&2; exit 1; }

    has="$(_has_table)"
    rec_list=''; [[ "$has" == yes ]] && rec_list="$(_recorded)"
    pending_files=()
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      # ⚠ MATCH ON THE MIGRATION KEY, NOT THE RAW NAME. The record holds the filename each
      # migration had when it ran; the padding rename changed every one of those names. See
      # migration_key in scripts/lib/ledger-migration-state.sh for why the record is not rewritten.
      r=no
      if grep -qxF "$f" <<<"$rec_list"; then r=yes
      elif grep -qxF "$(migration_key "$f")" <<<"$(while IFS= read -r _rl; do [[ -n "$_rl" ]] && migration_key "$_rl"; done <<<"$rec_list")"; then r=yes
      fi
      [[ "$(file_verdict "$f" "$r" "$BOOTSTRAP")" == pending ]] && pending_files+=("$f")
    done < <(_files)

    low="${pending_files[0]-}"
    if [[ "$target" != "--all" ]]; then
      target="$(basename "$target")"
      case "$(order_verdict "$target" "$low")" in
        nothing-pending) echo "ledger-migrate: nothing is pending — $target is already recorded or predates the record."; exit 0 ;;
        out-of-order)
          echo "ledger-migrate: REFUSING to apply $target — $low is pending and must go first." >&2
          echo "  ⚠ This is not pedantry. ${BOOTSTRAP}'s backfill asserts that every file below it" >&2
          echo "     has run. Applied out of order that assertion becomes false, and a falsehood in a" >&2
          echo "     record built to be trusted is worse than the absence it replaced." >&2
          exit 1 ;;
      esac
      pending_files=("$target")
    fi

    [[ ${#pending_files[@]} -gt 0 ]] || { echo "ledger-migrate: nothing pending — 0 applied."; exit 0; }

    for f in "${pending_files[@]}"; do
      sum="$(sha256sum "$SRC/$f" | cut -d' ' -f1)"
      note="$(applier_note "$who" "$prov")"
      printf '  applying %s …\n' "$f"
      # ⚠ ONE TRANSACTION, DDL AND RECORD TOGETHER. ON_ERROR_STOP=1 plus the explicit BEGIN/COMMIT
      # means a failure anywhere — including in the INSERT — rolls back the schema change too. A
      # file that half-applied and recorded itself is worse than one that recorded nothing.
      # ⚠ THE BOOTSTRAP RECORDS ITSELF (it must: on the initdb path no tool runs), so this INSERT
      # is ON CONFLICT DO NOTHING rather than a plain one. Every other file is genuinely absent
      # from the table at this point, because that is what `pending` means.
      {
        printf 'BEGIN;\n'
        cat "$SRC/$f"
        printf "\nINSERT INTO ledger.schema_migration (filename, applied_at, applied_by, checksum, note)\n"
        printf " VALUES ('%s', now(), session_user, '%s', '%s') ON CONFLICT (filename) DO NOTHING;\n" \
          "$(_sql_string "$f")" "$sum" "$(_sql_string "$note")"
        printf 'COMMIT;\n'
      } | _psql >/dev/null || { echo "ledger-migrate: FAILED on $f — the transaction rolled back; the record is unchanged." >&2; exit 1; }

      # ⚠ A POSITIVE CHECK THAT THE ROW LANDED, not an assumption that COMMIT implies it. The
      # ON CONFLICT above is a legitimate no-op for the bootstrap and would be a SILENT no-op for
      # anything else that had somehow recorded itself — which is precisely the state this tool
      # exists to make impossible to reach unnoticed.
      got="$(_psql -c "select count(*) from ledger.schema_migration where filename = '$(_sql_string "$f")'")"
      [[ "$got" == 1 ]] || { echo "ledger-migrate: $f applied but the record shows $got rows for it — STOP." >&2; exit 1; }
      printf '  recorded %s\n' "$f"
    done
    printf 'ledger-migrate: %d applied and recorded.\n' "${#pending_files[@]}"
    exit 0 ;;

  *)
    echo "ledger-migrate: unknown command '$cmd' — try status | apply | --selftest" >&2
    exit 1 ;;
esac
