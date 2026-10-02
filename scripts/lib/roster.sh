#!/usr/bin/env bash
# scripts/lib/roster.sh — the ONE reader and the ONE writer for agents/roster.json.
# (feat_agent_identity_is_session_scoped · infra_routing_cannot_see_what_role_a_name_holds)
#
# ⚠ WHY A LIBRARY AND NOT "JUST JQ AT EACH CALL SITE". Onboarding and offboarding are the only two
# things that ever mutate this file, and everything else only reads it. A second writer with its own
# idea of the schema is precisely how a register drifts from the thing that consumes it — which is
# the failure this whole ticket exists to remove, not one to reintroduce one layer down.
#
# ⚠ AND THE READER CARRIES A CONSTRAINT THE WRITER CANNOT ENFORCE ALONE: a RETIRED name is still
# TAKEN. Old commits carry the address for ever, so re-onboarding a retired name would hand one
# person's history to another. Anything asking "is this free?" must count retired rows, and the
# obvious implementation — filter to active, then look — gets that exactly backwards. `roster_known`
# therefore ignores status entirely, and only `roster_active` filters.

# ⚠ THE SHARED FLAG CONTRACT, sourced even though this file is normally SOURCED rather than run.
# A mistyped self-test flag falling through the guard is a self-test that never ran, reporting
# exit 0 — indistinguishable from one that passed. The ratchet
# (scripts/check-selftest-flag-contract.sh) exists because that grew across ~80 scripts, and it
# asks exactly one question: does the script source this library. Sourcing is side-effect free;
# the library only defines functions. (chore_unify_selftest_flag_spelling)
# shellcheck disable=SC1091
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/selftest-flag.sh"

# The file. Overridable so the self-tests can drive fixtures rather than the live register.
# ⚠ TWO VARIABLES REACH THIS, AND THEY DO NOT RELOCATE THE SAME THINGS. `ROSTER_FILE` moves ONLY the
# roster. `REPO_ROOT` moves the roster AND everything else keyed off the checkout — in particular
# `.agent/name`, which agent-name.sh reads as rung 1 and which OUTRANKS the environment. So a caller
# that sets REPO_ROOT to make the roster readable also silently repoints identity resolution at that
# checkout's marker.
#
# Cost me a live one: a self-test case driving "an unrostered AGENT_NAME must not resolve" set
# REPO_ROOT at the real repo so the roster could be read, and the case then resolved the REAL
# .agent/name and reported a name that had never come from the environment at all. The assertion was
# about rung 2 and the answer came from rung 1.
#
# ⚠ IF YOU ONLY NEED THE ROSTER, SET ROSTER_FILE. Reach for REPO_ROOT when you mean "pretend the
# whole checkout is elsewhere", which is a much larger claim than it looks.
# (infra_the_identity_refusal_offers_the_one_rung_that_validates_nothing)
roster_file() { printf '%s\n' "${ROSTER_FILE:-${REPO_ROOT:-.}/agents/roster.json}"; }

# ── pure-ish readers ────────────────────────────────────────────────────────────────────────────
# Each takes the roster JSON on stdin, so every one of them is drivable from a fixture with no
# filesystem and no live roster. The thin wrappers below read the real file.

# roster_name_for_email <email>  ← json on stdin → the name, or empty.
# Case-insensitive: git addresses get typed by humans and `Ed@…` is the same identity as `ed@…`.
# ⚠ AGENTS **AND MACHINES**, AND THE ORDER IS DELIBERATE. An unattended unit (systemd, CI) has no
# session, so `_require_session_identity` refuses its every write — the 2026-09-04 defect where
# strength-release-claims failed 119 runs and refused 600 releases while looking merely idle. The
# remedy is to GIVE it a session identity, not to relax the guard: rung 0 of agent-name.sh resolves
# an address to a name through here, so a machine with a rostered address resolves with
# source=`session` exactly as a person does, and one WITHOUT still resolves to nothing and is still
# refused. Strip the unit's GIT_AUTHOR_EMAIL and the refusal comes straight back — that is the
# negative control, and it is the point.
# ⚠ `.agents` FIRST so a machine can never shadow a person if an address is ever duplicated, and
# ⚠ ONLY THIS FUNCTION LOOKS AT `.machines`. Every rota reader — routing, paging, the stand-up,
# roster_list_active, roster_list_known — enumerates `.agents[]` and is untouched, so nothing here
# can be handed a ticket or woken at 3am. Answering "whose address is this?" is the one question a
# machine has a real answer to. (infra_the_claim_release_timer_has_no_session_identity...)
roster_name_for_email() {
  local email="${1:-}"
  [[ -n "$email" ]] || return 0
  jq -r --arg e "${email,,}" '
    (((.agents // []) + (.machines // []))
      | map(select((.email // "" | ascii_downcase) == $e)) | .[0].name // "")
  ' 2>/dev/null
}

# roster_role_for_name <name>  ← json on stdin → the role, or empty.
roster_role_for_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 0
  jq -r --arg n "${name,,}" '
    (.agents // []) | map(select((.name // "" | ascii_downcase) == $n)) | .[0].role // ""
  ' 2>/dev/null
}

# roster_remit_for_name <name>  ← json on stdin → the remit, or empty.
# A REMIT is a standing responsibility carried ON TOP of a role, named the way a role is: it names
# docs/roles/<remit>.md. It is what routing reads when "developer" is true and not the whole truth.
# ⚠ 2026-09-10: the only machine-readable fact about the process-improvement holder said `developer`
# — the remit lived in a document nobody's tooling read — and the PO routed her developer work twice
# in one day, from the roster, correctly by its lights. A remit is NOT an ownership field (what you are
# for, never what you hold); the self-test below still forbids those.
# (chore_the_roster_records_a_remit_so_routing_stops_reading_rowan_as_a_plain_developer)
roster_remit_for_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 0
  jq -r --arg n "${name,,}" '
    (.agents // []) | map(select((.name // "" | ascii_downcase) == $n)) | .[0].remit // ""
  ' 2>/dev/null
}

# roster_status_for_name <name>  ← json on stdin → active | retired | "" (unknown).
roster_status_for_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 0
  jq -r --arg n "${name,,}" '
    (.agents // []) | map(select((.name // "" | ascii_downcase) == $n)) | .[0].status // ""
  ' 2>/dev/null
}

# roster_known <name>  ← json on stdin → 0 if the name appears AT ALL, whatever its status.
#
# ⚠ THIS IS THE "IS THE NAME TAKEN?" QUESTION AND IT DELIBERATELY IGNORES STATUS. A retired name is
# taken for ever. Writing this as "select(.status == \"active\")" is the natural thing to type and
# would let a retired name be re-onboarded, handing one agent's commit history to another.
roster_known() {
  local name="${1:-}" n
  [[ -n "$name" ]] || return 1
  n="$(jq -r --arg n "${name,,}" '
        (.agents // []) | map(select((.name // "" | ascii_downcase) == $n)) | length
      ' 2>/dev/null)"
  [[ "${n:-0}" -gt 0 ]]
}

# roster_email_known <email>  ← json on stdin → 0 if the address appears at all, any status.
# Same rule as roster_known, for the other half of the identity.
roster_email_known() {
  local email="${1:-}" n
  [[ -n "$email" ]] || return 1
  n="$(jq -r --arg e "${email,,}" '
        (.agents // []) | map(select((.email // "" | ascii_downcase) == $e)) | length
      ' 2>/dev/null)"
  [[ "${n:-0}" -gt 0 ]]
}

# roster_email_allowed <email>  ← json on stdin → 0 if the address may author a commit.
#
# ⚠ AGENTS **AND** HUMANS, and the two are not interchangeable. `roster_email_known` answers "is this
# name taken" over agents alone, because that is the onboarding question. This answers "may this
# address appear as a commit author", which the owner's does and no role prompt is involved. Reusing
# the agent reader here would red the owner's own commits; adding humans to the agent list would put
# a non-agent into routing. Different questions, different readers, one file.
roster_email_allowed() {
  local email="${1:-}" n
  [[ -n "$email" ]] || return 1
  n="$(jq -r --arg e "${email,,}" '
        [ ((.agents // [])[] | .email // ""), ((.humans // [])[] | .email // "") ]
        | map(ascii_downcase) | map(select(. == $e)) | length
      ' 2>/dev/null)"
  [[ "${n:-0}" -gt 0 ]]
}

# roster_name_for_any_email <email> ← json on stdin → the name from EITHER population, or empty.
roster_name_for_any_email() {
  local email="${1:-}"
  [[ -n "$email" ]] || return 0
  jq -r --arg e "${email,,}" '
    [ ((.agents // [])[]), ((.humans // [])[]) ]
    | map(select((.email // "" | ascii_downcase) == $e)) | .[0].name // ""
  ' 2>/dev/null
}

# roster_active  ← json on stdin → one "name<TAB>role" line per ACTIVE agent, sorted.
# The ONLY reader that filters on status, and it is for routing — you do not route to a leaver.
roster_active() {
  jq -r '(.agents // []) | map(select(.status == "active"))
         | sort_by(.name) | .[] | "\(.name)\t\(.role)"' 2>/dev/null
}

# roster_email_for_name <name>  ← json on stdin → the address, or empty.
roster_email_for_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || return 0
  jq -r --arg n "${name,,}" '
    (.agents // []) | map(select((.name // "" | ascii_downcase) == $n)) | .[0].email // ""
  ' 2>/dev/null
}

# The derived form, and the ONLY one. Lowercase the name; one domain.
# ⚠ Do NOT add a second spelling here. The whole naming rule is that there is one.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/harness-env.sh" 2>/dev/null || true
# the naming rule: <name, lowercased>@ROSTER_DOMAIN (harness.env; default <project>.local)
ROSTER_DOMAIN="${ROSTER_DOMAIN:-${HARNESS_PROJECT:-harness}.local}"
roster_email_of_name() { printf '%s@%s\n' "${1,,}" "$ROSTER_DOMAIN"; }

# ── file-backed wrappers ────────────────────────────────────────────────────────────────────────
_roster_json() { local f; f="$(roster_file)"; [[ -r "$f" ]] && cat "$f" || printf '{"agents":[]}'; }

roster_lookup_name()   { _roster_json | roster_name_for_email  "${1:-}"; }
roster_lookup_role()   { _roster_json | roster_role_for_name   "${1:-}"; }
roster_lookup_remit()  { _roster_json | roster_remit_for_name  "${1:-}"; }
roster_lookup_status() { _roster_json | roster_status_for_name "${1:-}"; }
roster_lookup_email()  { _roster_json | roster_email_for_name  "${1:-}"; }
roster_has_name()      { _roster_json | roster_known           "${1:-}"; }
roster_has_email()     { _roster_json | roster_email_known     "${1:-}"; }
roster_list_active()   { _roster_json | roster_active; }
# ⚠ THE REGISTER, NOT THE ROTA — and the two are different questions this file already separates.
# `roster_list_active` answers "who can take work"; this answers "is this name known at all",
# which is what an is-it-registered check must ask. Without it the only list available was the
# ACTIVE one, and agent-roster.sh duly asked the registration question of the rota and reported six
# retired agents as "not in agents/roster.json" — the exact inversion the header of this file warns
# against, committed by the caller because the right list did not exist to reach for.
# (fix_the_roster_report_calls_a_retired_agent_unrostered_and_available)
roster_list_known()    { _roster_json | jq -r '.agents[]? | "\(.name)\t\(.status // "unknown")\t\(.offboarded // "")"' | sort; }
roster_may_author()    { _roster_json | roster_email_allowed   "${1:-}"; }
roster_any_name()      { _roster_json | roster_name_for_any_email "${1:-}"; }

# ── the writer ──────────────────────────────────────────────────────────────────────────────────
# Two verbs, because there are exactly two lifecycle events. Both are idempotent-ish and both
# REFUSE rather than guess — a register that silently accepts a contradictory write is worse than
# one that stops.

# roster_add <name> <role> <date> [evidence]
# ⚠ REFUSES A NAME THAT IS ALREADY KNOWN, INCLUDING A RETIRED ONE. That refusal is the point: a
# retired name must never be re-onboarded while its old commits still carry the address.
roster_add() {
  local name="${1:?roster_add <name> <role> <date> [evidence]}" role="${2:?role}" date="${3:?date}"
  local ev="${4:-declared}" f tmp
  f="$(roster_file)"
  [[ -r "$f" ]] || { printf 'roster_add: no roster at %s\n' "$f" >&2; return 1; }
  case "$role" in
    delivery-lead|head-of-testing|developer|process-improvement) ;;
    *) printf 'roster_add: unknown role %q — must be one of delivery-lead, head-of-testing, developer, process-improvement (they name docs/roles/<role>.md)\n' "$role" >&2; return 1 ;;
  esac
  if roster_has_name "$name"; then
    printf 'roster_add: %q is already in the roster (status: %s). A name is NEVER reused — a retired one still owns its commits.\n' \
      "$name" "$(roster_lookup_status "$name")" >&2
    return 1
  fi
  tmp="$(mktemp)"
  # ⚠ `jq … > "$tmp" && mv` leaks the temp when jq fails: the mv never runs and nothing else touches
  # it. (fix_scripts_leak_a_mktemp_file_per_call_and_nothing_gates_it)
  if jq --arg n "$name" --arg r "$role" --arg d "$date" \
        --arg e "$(roster_email_of_name "$name")" --arg ev "$ev" '
       .agents += [{name:$n, email:$e, role:$r, status:"active", onboarded:$d, offboarded:null, evidence:$ev}]
     ' "$f" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# roster_retire <name> <date> [note]
# Marks retired and stamps the date. The row STAYS — see the reader's constraint above.
roster_retire() {
  local name="${1:?roster_retire <name> <date> [note]}" date="${2:?date}" note="${3:-}" f tmp
  f="$(roster_file)"
  [[ -r "$f" ]] || { printf 'roster_retire: no roster at %s\n' "$f" >&2; return 1; }
  roster_has_name "$name" || { printf 'roster_retire: %q is not in the roster\n' "$name" >&2; return 1; }
  tmp="$(mktemp)"
  # ⚠⚠ THE DATE IS A HISTORICAL FACT, NOT A STATUS, AND IT IS WRITTEN ONCE. `status` is idempotent —
  # retired twice is retired — but `offboarded` answers WHEN, and once overwritten there is nothing
  # left to recompute it from. This used to assign `.offboarded = $d` unconditionally, so re-running
  # the verb against an already-offboarded agent replaced the real date with the date of the re-run
  # and appended the evidence clause a second time.
  #
  # ⚠ IT HAS ALREADY HAPPENED AND IT LANDED. Don's row, commit 82ed3b588 (2026-09-06): the true
  # offboard date 2026-09-02 was replaced by 2026-09-06 and ` · offboarded — held nothing
  # outstanding` appended. Nobody noticed for six days, because the tool reported full success.
  # (fix_agent_offboard_is_not_idempotent_so_re_running_it_overwrites_the_real_offboard_date_and_duplicates_the_evidence)
  #
  # FIRST WRITE WINS for the date; the clause is appended only when not already present. Both are
  # `//` guards rather than a caller-side check, so every caller inherits them — a guard the caller
  # must remember is the one that went missing here.
  if jq --arg n "${name,,}" --arg d "$date" --arg note "$note" '
       .agents |= map(
         if (.name // "" | ascii_downcase) == $n
         then .status = "retired"
              | .offboarded = (if (.offboarded // "") == "" then $d else .offboarded end)
              | .evidence = (
                  if $note == "" then .evidence
                  elif ((.evidence // "") | contains($note)) then .evidence
                  else ((.evidence // "") + " · " + $note) end)
         else . end)
     ' "$f" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# Was this name already offboarded, and when? Prints the date, or nothing.
# ⚠ THIS ANSWERS THE ROSTER'S QUESTION ONLY, AND THAT IS DELIBERATE. "Already offboarded" per the
# roster and "the ledger role can no longer log in" are DIFFERENT facts that can disagree — an
# offboard interrupted halfway leaves the row retired while the role still logs in. So this must
# never be used to skip the whole offboard, only to stop the date being rewritten and to tell the
# operator what they are looking at. The rest of agent-offboard.sh still runs, which is what lets
# an incomplete offboard be completed.
roster_offboarded_on() {
  local name="${1:?roster_offboarded_on <name>}" f
  f="$(roster_file)"; [[ -r "$f" ]] || return 1
  jq -r --arg n "${name,,}" '
    (.agents[] | select((.name // "" | ascii_downcase) == $n) | .offboarded // "") // ""' "$f" 2>/dev/null
}

# roster_role <name> <role> <date> [evidence]
# The owner reassigns a role. 2026-09-11, on the Team page reading "developer · process-improvement":
# "you're not a developer" — so process-improvement became the FOURTH role rather than a remit on
# top of developer, and this is the verb that records such a change. Refuses an unknown or retired
# name and an unknown role; appends evidence; and if the row's remit equals the new role, the remit
# is dropped — a role is not a remit on top of itself. A remit that differs survives.
# (chore_process_improvement_is_a_roster_role_not_a_remit_on_top_of_developer_the_owner_said_so)
roster_role() {
  local name="${1:?roster_role <name> <role> <date> [evidence]}" role="${2:?role}" date="${3:?date}"
  local ev="${4:-declared}" f tmp
  f="$(roster_file)"
  [[ -r "$f" ]] || { printf 'roster_role: no roster at %s\n' "$f" >&2; return 1; }
  case "$role" in
    delivery-lead|head-of-testing|developer|process-improvement) ;;
    *) printf 'roster_role: unknown role %q — must be one of delivery-lead, head-of-testing, developer, process-improvement (they name docs/roles/<role>.md)\n' "$role" >&2; return 1 ;;
  esac
  roster_has_name "$name" || { printf 'roster_role: %q is not in the roster\n' "$name" >&2; return 1; }
  [[ "$(roster_lookup_status "$name")" == active ]] \
    || { printf 'roster_role: %q is retired — a leaver holds no role to change\n' "$name" >&2; return 1; }
  tmp="$(mktemp)"
  if jq --arg n "${name,,}" --arg r "$role" --arg d "$date" --arg ev "$ev" '
       .agents |= map(
         if (.name // "" | ascii_downcase) == $n
         then .role = $r
              | (if .remit == $r then del(.remit) else . end)
              | .evidence = ((.evidence // "") + " · role " + $r + " from " + $d + ": " + $ev)
         else . end)
     ' "$f" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# roster_remit <name> <remit> <date> [evidence]
# The THIRD verb, for the third thing the owner assigns: a standing remit on top of a role. Refuses an
# unknown or retired name, an empty remit, and a remit that names no docs/roles/<remit>.md — a remit
# nobody has written terms of reference for is a label, and routing would read it as a fact. The
# evidence is APPENDED to the row's evidence, so how the role was known and how the remit was known
# both survive; say whether it is declared (the owner said so) or inferred.
roster_remit() {
  local name="${1:?roster_remit <name> <remit> <date> [evidence]}" remit="${2:?remit}" date="${3:?date}"
  local ev="${4:-declared}" f tmp tor
  f="$(roster_file)"
  [[ -r "$f" ]] || { printf 'roster_remit: no roster at %s\n' "$f" >&2; return 1; }
  roster_has_name "$name" || { printf 'roster_remit: %q is not in the roster\n' "$name" >&2; return 1; }
  [[ "$(roster_lookup_status "$name")" == active ]] \
    || { printf 'roster_remit: %q is retired — a leaver carries no remit\n' "$name" >&2; return 1; }
  [[ "$remit" =~ ^[a-z][a-z0-9-]*$ ]] \
    || { printf 'roster_remit: remit %q must be a kebab-case name — it names docs/roles/<remit>.md\n' "$remit" >&2; return 1; }
  tor="${ROSTER_ROLES_DIR:-${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/docs/roles}/$remit.md"
  [[ -r "$tor" ]] \
    || { printf 'roster_remit: no terms of reference at %s — write the ToR first, then record the remit\n' "$tor" >&2; return 1; }
  tmp="$(mktemp)"
  if jq --arg n "${name,,}" --arg r "$remit" --arg d "$date" --arg ev "$ev" '
       .agents |= map(
         if (.name // "" | ascii_downcase) == $n
         then .remit = $r
              | .evidence = ((.evidence // "") + " · remit " + $r + " from " + $d + ": " + $ev)
         else . end)
     ' "$f" > "$tmp"; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# roster_launch_line <name>  ->  the ONE command that starts a session with an identity.
#
# ⚠ THIS IS THE SWITCH THAT TURNS THE WHOLE IDENTITY CHAIN ON, AND IT LIVES IN EXACTLY ONE PLACE.
#
# The register, the resolver and the authorship gate all landed before anything told an agent how to
# START a session with an identity — so on 2026-08-14 five live sessions all resolved to one name
# out of a directory file written six days earlier, because `$GIT_AUTHOR_EMAIL` was unset in every
# one of them and the fallback was therefore the entire mechanism.
#
# ⚠ AND A RUNNING SESSION CANNOT BE RETROFITTED. That is not a design preference, it is what the
# incident proved: not one of the five could repair its own identity from inside itself, because
# these variables belong to the process and are read at launch. Which is exactly why the deliverable
# is A LINE A HUMAN RUNS, and not a script that tries to set them.
#
# It was already written twice and the two copies disagreed — check-commit-authorship.sh set
# GIT_COMMITTER_* and feature-ticket.sh did not. Both now derive from here, because a launch line
# that differs depending on which file you happen to read is how half a fleet ends up half
# configured.
#
# COMMITTER IS SET TOO, EVEN THOUGH THE GATE DOES NOT CHECK IT. That gate reads %ae/%an only, so
# author alone would pass — but leaving the committer as the shared box identity produces a commit
# whose two halves name different people, which is the precise shape that gate's own header objects
# to. One identity, one spelling, in every field that carries it.
# (feat_agent_onboarding_and_offboarding)
roster_launch_line() { # $1 name
  local n="${1:?roster_launch_line <name>}" e
  e="$(roster_email_of_name "$n")"
  printf 'GIT_AUTHOR_NAME="%s" GIT_AUTHOR_EMAIL="%s" \\\n  GIT_COMMITTER_NAME="%s" GIT_COMMITTER_EMAIL="%s" \\\n  claude --worktree ${HARNESS_PROJECT}-%s --tmux\n' \
    "$n" "$e" "$n" "$e" "${n,,}"
}

# ── self-test ───────────────────────────────────────────────────────────────────────────────────
# ⚠ AND THE OTHER HALF OF THE CONTRACT: REFUSE AN UNRECOGNISED ARGUMENT. Sourcing the library
# satisfies the ratchet — it asks only whether the library is sourced — but `selftest_is_flag`
# merely RECOGNISES a flag; it does not reject anything, and the contract says the caller keeps its
# own `*)`. Without this, `roster.sh --slef-test` falls past the guard and exits 0, which is the
# false green the whole ratchet exists to prevent. **Passing the gate is not the same as fixing the
# defect**, and stopping at the green here would have shipped it knowingly.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    '') ;;
    *) selftest_is_flag "$1" || {
         printf 'unknown argument: %s\n' "$1" >&2
         printf 'usage: roster.sh [--self-test]   (this file is normally SOURCED, not run)\n' >&2
         exit 2; } ;;
  esac
fi

# ⚠ THE `BASH_SOURCE == $0` GUARD IS LOAD-BEARING AND STAYS. This file is sourced by
# feature-ticket.sh and agent-name.sh, where `$1` is the CALLER's argument — `feature-ticket.sh
# claim <id>` would otherwise be read as a flag for this library.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && selftest_is_flag "${1:-}"; then
  _real_domain="$ROSTER_DOMAIN"    # the shipped roster is judged against the CONFIGURED domain (below)
  ROSTER_DOMAIN=weaversite.co.uk   # the fixtures below carry the seeded project's addresses; pin the rule to them
  set -uo pipefail
  fails=0
  t() { local want="$1" desc="$2" got="$3"
        if [[ "$got" == "$want" ]]; then printf '  ok    %s\n' "$desc"
        else printf '  FAIL  %s\n        want %q\n        got  %q\n' "$desc" "$want" "$got"; fails=1; fi; }

  FX='{"agents":[
    {"name":"Ed","email":"ed@weaversite.co.uk","role":"developer","status":"active"},
    {"name":"Vera","email":"vera@weaversite.co.uk","role":"head-of-testing","status":"active"},
    {"name":"Arnold","email":"arnold@weaversite.co.uk","role":"developer","status":"retired"}
  ]}'

  t Ed   'an address resolves to its name'        "$(printf '%s' "$FX" | roster_name_for_email ed@weaversite.co.uk)"
  t Ed   'address matching is case-insensitive'   "$(printf '%s' "$FX" | roster_name_for_email Ed@Weaversite.CO.UK)"
  t ''   'an unrostered address resolves to nothing, never to a guess' \
                                                  "$(printf '%s' "$FX" | roster_name_for_email nobody@weaversite.co.uk)"
  t ''   'an empty address resolves to nothing'   "$(printf '%s' "$FX" | roster_name_for_email '')"
  t head-of-testing 'the role comes from the register, not from behaviour' \
                                                  "$(printf '%s' "$FX" | roster_role_for_name Vera)"
  t ''   'an unknown name has no role — silence, not "developer"' \
                                                  "$(printf '%s' "$FX" | roster_role_for_name Nobody)"

  # ⚠ THE CONSTRAINT THAT IS EASIEST TO GET BACKWARDS. A retired name is TAKEN. The natural
  # implementation — filter to active, then look — would answer "free" here and let a second person
  # inherit a first person's commit history.
  printf '%s' "$FX" | roster_known Arnold \
    && printf '  ok    a RETIRED name is still known — the name stays taken for ever\n' \
    || { printf '  FAIL  a retired name read as free\n'; fails=1; }
  printf '%s' "$FX" | roster_email_known arnold@weaversite.co.uk \
    && printf '  ok    …and so is a retired ADDRESS\n' \
    || { printf '  FAIL  a retired address read as free\n'; fails=1; }
  t retired 'and its status is reported honestly'  "$(printf '%s' "$FX" | roster_status_for_name Arnold)"

  # ⚠ THE NEGATIVE CONTROL. Without it `roster_known` could return 0 for everything and every
  # assertion above would still pass — a "is this taken?" that always says yes is as useless as one
  # that always says no, and it would block every genuine onboarding.
  printf '%s' "$FX" | roster_known Nobody \
    && { printf '  FAIL  an unknown name read as known — roster_known says yes to everything\n'; fails=1; } \
    || printf '  ok    NEGATIVE CONTROL: an unknown name is NOT known\n'
  printf '%s' "$FX" | roster_email_known nobody@weaversite.co.uk \
    && { printf '  FAIL  an unknown address read as known\n'; fails=1; } \
    || printf '  ok    NEGATIVE CONTROL: an unknown address is NOT known\n'

  # roster_active is the ONE reader that filters — routing must not route to a leaver.
  t $'Ed\tdeveloper\nVera\thead-of-testing' 'active listing excludes the retired, and is sorted' \
    "$(printf '%s' "$FX" | roster_active)"

  # ── who may AUTHOR a commit: agents AND humans ────────────────────────────
  FXH='{"agents":[{"name":"Ed","email":"ed@weaversite.co.uk","role":"developer","status":"active"},
                  {"name":"Arnold","email":"arnold@weaversite.co.uk","role":"developer","status":"retired"}],
        "humans":[{"name":"Peter Parker","email":"qujck@outlook.com"}]}'
  printf '%s' "$FXH" | roster_email_allowed ed@weaversite.co.uk \
    && printf '  ok    an active agent may author\n' || { printf '  FAIL  agent refused\n'; fails=1; }
  # ⚠ THE OWNER'S OWN ADDRESS. Reusing the AGENT reader here would red every commit he makes.
  printf '%s' "$FXH" | roster_email_allowed qujck@outlook.com \
    && printf '  ok    the owner may author, though he is in no role and takes no claims\n' \
    || { printf '  FAIL  the owner cannot author — the gate would red his own commits\n'; fails=1; }
  # ⚠ A RETIRED AGENT MAY STILL AUTHOR. Their old commits exist and must stay valid; the name being
  # reserved is about onboarding, not about invalidating history.
  printf '%s' "$FXH" | roster_email_allowed arnold@weaversite.co.uk \
    && printf '  ok    a retired agent may still author — their history stays valid\n' \
    || { printf '  FAIL  retiring an agent invalidated their existing commits\n'; fails=1; }
  # NEGATIVE CONTROL, or the allower allows everything.
  printf '%s' "$FXH" | roster_email_allowed nobody@example.com \
    && { printf '  FAIL  an unrostered address may author — the gate proves nothing\n'; fails=1; } \
    || printf '  ok    NEGATIVE CONTROL: an unrostered address may NOT author\n'
  # ⚠ AND THE TWO READERS MUST DISAGREE ON THE OWNER, or one of them is answering the wrong question.
  printf '%s' "$FXH" | roster_email_known qujck@outlook.com \
    && { printf '  FAIL  the owner counts as an AGENT — a non-agent is now routable\n'; fails=1; } \
    || printf '  ok    …and the owner is NOT an agent: the two readers answer different questions\n'
  t 'Peter Parker' 'a human address resolves to a name for messages' \
    "$(printf '%s' "$FXH" | roster_name_for_any_email qujck@outlook.com)"

  t ed@weaversite.co.uk    'the derived address lowercases the name'  "$(roster_email_of_name Ed)"
  t saffron@weaversite.co.uk 'and does so for every name'             "$(roster_email_of_name Saffron)"

  # ── the writer, against a throwaway copy ────────────────────────────────
  _tmp="$(mktemp -d)"; trap 'rm -rf "$_tmp"' EXIT
  printf '%s' "$FX" > "$_tmp/roster.json"
  ROSTER_FILE="$_tmp/roster.json"

  roster_add Wren developer 2026-08-13 'declared — test' >/dev/null 2>&1 \
    && printf '  ok    a new agent can be onboarded\n' \
    || { printf '  FAIL  roster_add refused a genuinely new name\n'; fails=1; }
  t developer 'and is readable immediately'   "$(roster_lookup_role Wren)"
  t wren@weaversite.co.uk 'with the derived address' "$(roster_lookup_email Wren)"

  # ⚠ THE TWO REFUSALS. The second is the load-bearing one.
  roster_add Ed developer 2026-08-13 >/dev/null 2>&1 \
    && { printf '  FAIL  an ACTIVE name was onboarded twice\n'; fails=1; } \
    || printf '  ok    an active name cannot be onboarded twice\n'
  roster_add Arnold developer 2026-08-13 >/dev/null 2>&1 \
    && { printf '  FAIL  a RETIRED name was re-onboarded — its old commits now belong to someone else\n'; fails=1; } \
    || printf '  ok    a RETIRED name cannot be re-onboarded\n'
  roster_add Wren2 wizard 2026-08-13 >/dev/null 2>&1 \
    && { printf '  FAIL  an unknown role was accepted\n'; fails=1; } \
    || printf '  ok    an unknown role is refused — roles name docs/roles/<role>.md\n'

  roster_retire Wren 2026-08-13 'test departure' >/dev/null 2>&1 \
    && printf '  ok    an agent can be retired\n' \
    || { printf '  FAIL  roster_retire failed\n'; fails=1; }
  t retired 'retiring sets the status'  "$(roster_lookup_status Wren)"
  # ⚠ AND THE ROW SURVIVES. Retiring must never delete — that is the whole reservation.
  roster_has_name Wren \
    && printf '  ok    a retired row is KEPT, not deleted\n' \
    || { printf '  FAIL  retiring removed the row — the name is now reusable\n'; fails=1; }
  roster_retire Nobody 2026-08-13 >/dev/null 2>&1 \
    && { printf '  FAIL  retired a name that was never in the roster\n'; fails=1; } \
    || printf '  ok    retiring an unknown name is refused\n'

  # ── the remit: a responsibility on top of a role, readable by routing ────
  _tor="$_tmp/roles"; mkdir -p "$_tor"; printf '# ToR\n' > "$_tor/process-improvement.md"
  ROSTER_ROLES_DIR="$_tor" roster_remit Ed process-improvement 2026-09-10 'declared — test' >/dev/null 2>&1 \
    && printf '  ok    an active agent can be given a remit\n' \
    || { printf '  FAIL  roster_remit refused an active name with a written ToR\n'; fails=1; }
  t process-improvement 'and routing reads it back'          "$(roster_lookup_remit Ed)"
  t developer           'while the role is unchanged'        "$(roster_lookup_role Ed)"
  t ''                  'a row without a remit reads as none, never as a guess' "$(roster_lookup_remit Vera)"
  case "$(_roster_json | jq -r '.agents[] | select(.name=="Ed") | .evidence')" in
    *"remit process-improvement from 2026-09-10: declared — test"*) printf '  ok    the evidence says how the remit was known\n' ;;
    *) printf '  FAIL  the remit left no evidence\n'; fails=1 ;;
  esac
  ROSTER_ROLES_DIR="$_tor" roster_remit Arnold process-improvement 2026-09-10 >/dev/null 2>&1 \
    && { printf '  FAIL  a RETIRED name was given a remit\n'; fails=1; } \
    || printf '  ok    a retired name cannot carry a remit\n'
  ROSTER_ROLES_DIR="$_tor" roster_remit Nobody process-improvement 2026-09-10 >/dev/null 2>&1 \
    && { printf '  FAIL  an unknown name was given a remit\n'; fails=1; } \
    || printf '  ok    an unknown name is refused\n'
  ROSTER_ROLES_DIR="$_tor" roster_remit Ed wizardry 2026-09-10 >/dev/null 2>&1 \
    && { printf '  FAIL  a remit with no terms of reference was accepted\n'; fails=1; } \
    || printf '  ok    ⚠ NEGATIVE CONTROL: a remit with no docs/roles/<remit>.md is refused — a label is not a remit\n'

  # ── the role can change, and a remit equal to the new role is dropped ────
  roster_add Wren2 developer 2026-09-11 'declared — test' >/dev/null 2>&1
  roster_role Wren2 process-improvement 2026-09-11 'declared — test' >/dev/null 2>&1 \
    && printf '  ok    a role can be reassigned to the fourth role\n' \
    || { printf '  FAIL  roster_role refused process-improvement\n'; fails=1; }
  t process-improvement 'and the register reads the new role' "$(roster_lookup_role Wren2)"
  t ''                  'a remit equal to the new role is dropped — Ed carried process-improvement as a remit' "$(roster_role Ed process-improvement 2026-09-11 >/dev/null 2>&1; roster_lookup_remit Ed)"
  t process-improvement '…and Ed now holds it as the role' "$(roster_lookup_role Ed)"
  ROSTER_ROLES_DIR="$_tor" roster_remit Wren2 process-improvement 2026-09-11 >/dev/null 2>&1
  roster_role Wren2 developer 2026-09-11 >/dev/null 2>&1
  t process-improvement '⚠ NEGATIVE CONTROL: a remit DIFFERENT from the new role survives the change' "$(roster_lookup_remit Wren2)"
  roster_role Nobody developer 2026-09-11 >/dev/null 2>&1 \
    && { printf '  FAIL  an unknown name was given a role\n'; fails=1; } \
    || printf '  ok    an unknown name is refused a role\n'
  roster_role Arnold developer 2026-09-11 >/dev/null 2>&1 \
    && { printf '  FAIL  a RETIRED name had its role changed\n'; fails=1; } \
    || printf '  ok    a retired name cannot have its role changed\n'
  roster_role Wren2 wizard 2026-09-11 >/dev/null 2>&1 \
    && { printf '  FAIL  an unknown role was accepted by roster_role\n'; fails=1; } \
    || printf '  ok    an unknown role is refused by roster_role\n'

  # The real register must satisfy its own schema — a fixture proving nothing about the shipped file
  # is the gap this catches.
  ROSTER_FILE="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/agents/roster.json"
  if [[ -r "$ROSTER_FILE" ]]; then
    _bad="$(jq -r '(.agents // [])[] | select(
              (.name // "") == "" or (.email // "") == "" or
              ((.role // "") | IN("delivery-lead","head-of-testing","developer","process-improvement") | not) or
              ((.status // "") | IN("active","retired") | not)
            ) | .name // "<nameless>"' "$ROSTER_FILE" 2>/dev/null)"
    [[ -z "$_bad" ]] && printf '  ok    the shipped roster satisfies its own schema\n' \
      || { printf '  FAIL  shipped roster rows are malformed: %s\n' "$_bad"; fails=1; }
    # Every address must be the derived form. A hand-typed address is a second spelling.
    _mm="$(jq -r --arg d "$_real_domain" '(.agents // [])[] | select((.email // "") != ((.name // "" | ascii_downcase) + "@" + $d)) | .name' "$ROSTER_FILE" 2>/dev/null)"
    [[ -z "$_mm" ]] && printf '  ok    every address is the derived form of its name\n' \
      || { printf '  FAIL  addresses do not match the naming rule: %s\n' "$_mm"; fails=1; }
    # ⚠ AND NO DUPLICATES, IN EITHER FIELD. Two rows for one identity is the drift this file exists
    # to prevent, arriving inside the file itself.
    _dupn="$(jq -r '[(.agents // [])[].name | ascii_downcase] | group_by(.) | map(select(length>1)) | flatten | unique | join(",")' "$ROSTER_FILE" 2>/dev/null)"
    _dupe="$(jq -r '[(.agents // [])[].email | ascii_downcase] | group_by(.) | map(select(length>1)) | flatten | unique | join(",")' "$ROSTER_FILE" 2>/dev/null)"
    [[ -z "$_dupn" && -z "$_dupe" ]] && printf '  ok    no duplicate names or addresses\n' \
      || { printf '  FAIL  duplicates — names:%s addresses:%s\n' "$_dupn" "$_dupe"; fails=1; }
    # Every REMIT on the shipped register names a terms-of-reference file, as every role does.
    _nr=""
    while IFS=$'\t' read -r _rn _rr; do
      [[ -n "$_rr" && ! -r "$(dirname "$ROSTER_FILE")/../docs/roles/$_rr.md" ]] && _nr="$_nr $_rn:$_rr"
    done < <(jq -r '(.agents // [])[] | select(.remit != null) | "\(.name)\t\(.remit)"' "$ROSTER_FILE" 2>/dev/null)
    [[ -z "$_nr" ]] && printf '  ok    every shipped remit names docs/roles/<remit>.md\n' \
      || { printf '  FAIL  remits with no terms of reference:%s\n' "$_nr"; fails=1; }
    # ⚠ NO OWNERSHIP FIELD. The rules block forbids one; this is the assertion that makes the
    # prohibition enforceable rather than advisory.
    _own="$(jq -r '[(.agents // [])[] | keys[]] | unique | map(select(. == "holds" or . == "claimed" or . == "owns" or . == "tickets" or . == "assigned")) | join(",")' "$ROSTER_FILE" 2>/dev/null)"
    [[ -z "$_own" ]] && printf '  ok    the roster carries NO ownership field\n' \
      || { printf '  FAIL  the roster grew an ownership field (%s) — identity is not ownership\n' "$_own"; fails=1; }
  fi

  (( fails == 0 )) && { printf 'roster selftest ok\n'; exit 0; }
  printf 'roster selftest FAILURES\n'; exit 1
fi

# ── SELF-TEST for the write-once guarantee ──────────────────────────────────────────────────────
# ⚠ DRIVEN ON A TEMP ROSTER, NEVER THE REAL ONE. Both arms plus the negative control, because a
# guard that refuses the genuine case would replace one defect with a worse one.
roster_retire_selftest() {
  local f rc=0 b a
  f="$(mktemp)"; printf '%s' '{"agents":[{"name":"Gone","status":"retired","offboarded":"2026-09-02","evidence":"x · offboarded — held nothing outstanding"},{"name":"Here","status":"active","offboarded":null,"evidence":"y"}]}' > "$f"
  ROSTER_FILE="$f" roster_retire Gone "2026-12-25" "offboarded — held nothing outstanding" >/dev/null 2>&1
  b="$(jq -r '.agents[]|select(.name=="Gone")|.offboarded' "$f")"
  a="$(jq -r '.agents[]|select(.name=="Gone")|(.evidence|split(" · ")|length)' "$f")"
  [[ "$b" == "2026-09-02" ]] && printf '  ok   an existing offboard date is KEPT, not overwritten\n' \
                             || { printf '  FAIL date was rewritten to %q\n' "$b"; rc=1; }
  [[ "$a" == "2" ]] && printf '  ok   the clause is not duplicated on a re-run\n' \
                    || { printf '  FAIL evidence now has %s clauses\n' "$a"; rc=1; }
  # ⚠ NEGATIVE CONTROL — the genuine case must still work, or the guard is the new defect.
  ROSTER_FILE="$f" roster_retire Here "2026-12-25" "offboarded — held nothing outstanding" >/dev/null 2>&1
  b="$(jq -r '.agents[]|select(.name=="Here")|.offboarded' "$f")"
  [[ "$b" == "2026-12-25" ]] && printf '  ok   a never-offboarded agent IS dated normally\n' \
                             || { printf '  FAIL genuine offboard did not take (%q)\n' "$b"; rc=1; }
  [[ "$(ROSTER_FILE="$f" roster_offboarded_on Gone)" == "2026-09-02" ]] \
    && printf '  ok   roster_offboarded_on reports the kept date\n' \
    || { printf '  FAIL roster_offboarded_on\n'; rc=1; }
  rm -f "$f"; return "$rc"
}
