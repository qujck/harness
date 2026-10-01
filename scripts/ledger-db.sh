#!/usr/bin/env bash
# scripts/ledger-db.sh — the agent's way into the LEDGER DATABASE.
#
# ⚠ THE POINT OF THIS FILE IS THAT IDENTITY IS THE CONNECTION. You reach the database as YOURSELF —
# `psql -U <YourName>` — and every procedure takes `session_user` as the actor. No command here
# accepts a "who" argument and none ever may.
#
# That exists because of 2026-08-14: five live sessions all resolved to ONE agent's name, read out
# of `.agent/name` in a shared checkout, and **not one of them could correct it from the inside**.
# A wrong status is fixed by the next verify; a wrong OWNER just persists, because nothing
# downstream can tell it is wrong. Passing your name as a string reproduces exactly that bug.
#
# ⚠ WHAT THIS DOES NOT DEFEND, SAID PLAINLY. Every agent is the same OS user on this box, so nothing
# stops you typing `-U SomeoneElse`. This closes the ACCIDENTAL path — the one that actually
# produced five wrong owners — not a determined one. Do not read it as stronger than it is.
#
# During the migration git remains authoritative and this MIRRORS each write, so the board is true
# in seconds instead of at merge. (epic_the_ledger_moves_to_a_shared_database, phase 3)
set -uo pipefail

# ── WHICH REVISION OF THIS TOOL IS RUNNING? — shared with feature-ticket.sh via scripts/lib/stale-tool.sh ──
# ⚠ THIS SCRIPT HAD NO STALE-COPY DETECTION AT ALL. On 2026-09-20 a 308-commit-old copy of it answered a
# verb main had (`amend`) with its usage line, and the agent believed the verb did not exist, minutes after
# watching it work. When THIS copy is BEHIND main: the preamble, a trailer after the result, and an
# unknown verb says it may exist on main. A MESSAGE, never a block: no verb here grants on exit 1 (the read
# verbs PRINT live database facts and exit 0; usage is 64), and the write verbs are never touched.
# (infra_the_stale_script_warning_arrives_above_the_output_you_asked_for_and_nobody_reads_it)
STALE_TOOL_NAME=ledger-db
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/stale-tool.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness-env.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/ticket-store.sh"
warn_if_stale_tool "${BASH_SOURCE[0]}"

# ⚠ ONE PAYLOAD FILTER, USED BY BOTH MIRROR PATHS. There were two, and they had already drifted
# apart by six fields: the file loop carried `parent`, `raised_by`, `notes`, `user_visible_behavior`,
# `verification` and `verification_command`; `_emit` carried none of them. That was not a data-loss
# bug only because mirror_ticket guards prose on KEY PRESENCE, so the thinner payload left those
# columns alone — it silently meant the incremental path never UPDATED prose. A third divergence was
# a matter of time. This is the repo's own "a fact in more than one place" rule applied to the one
# script the whole ledger move depends on.
#
# ⚠ `lock_intent` IS DELIBERATELY IN NEITHER LIST SINCE MIGRATION 45, AND THAT IS HOW IT SURVIVES.
# It was BOTH a modelled key AND deleted from `extra`. Removing it from the object alone would have
# stripped the value entirely -- the del() list would still have removed it from the tail -- and
# `check-ledger-reproduces-the-ticket-files.sh` could then not rebuild any of the 58 ticket files on
# main that carry one. Absent from both, it flows into `extra` and round-trips.
# ⚠ SO DO NOT "TIDY" IT BACK INTO THE del() LIST to match the columns above: it is not a column any
# more, and adding it there deletes a live field.
# (infra_lock_intent_cannot_retire_until_the_mirror_stops_naming_it)
# ⚠ `extra` IS THE FILE'S TAIL: every key the schema does not model. Without it, mirror_ticket has
# nothing to merge and `ledger.ticket.extra` stays frozen at whatever the import migration wrote.
# The `del(...)` list must stay in step with the modelled columns above it — if you add a column,
# delete the key here too, or it will be written twice: once as a column and once inside extra.
# (infra_the_mirror_freezes_unmodelled_ticket_prose_at_import_time)
# ⚠ `claimed_by` IS MERGED IN CONDITIONALLY, AND IT IS THE ONLY KEY THAT MAY NOT BE COLLAPSED.
# (fix_the_mirror_wipes_a_claim_the_database_holds)
# It used to sit in the object above as `claimed_by: (.claimed_by // null)`. Object construction
# ALWAYS emits the key, and `//` fires on absent AND on null — so a file with NO claimed_by and a
# file with an explicit null produced BYTE-IDENTICAL payloads. Driven on the real filter:
#
#     file {"claimed_by":"Cara"}  -> payload has_key=true  val="Cara"
#     file {"claimed_by":null}    -> payload has_key=true  val=null
#     file  (no key at all)       -> payload has_key=true  val=null      <-- collapsed
#
# ⚠ THAT COLLAPSE MAKES `p ? 'claimed_by'` IN mirror_ticket ALWAYS TRUE, so the guard's preserve
# branch is unreachable from either real caller and the fix would have changed nothing. The
# distinction has to survive the PAYLOAD, not merely exist in the file. (Found by Cara, driven here.)
#
# ⚠⚠ TWO FIELDS ARE CONDITIONAL NOW, NOT ONE — `claimed_by` AND `parked_reason`. A future tidy-up
# back to `// null` would take BOTH silently, and it would look like restoring consistency while
# doing it. (fix_ledger_park_writes_a_park_the_next_sync_deletes)
#
# ⚠⚠ AND `parked_by` IS A THIRD OWNERSHIP FIELD THAT DELIBERATELY STAYS COLLAPSED — I MADE IT
# CONDITIONAL, DROVE IT, AND PUT IT BACK. Recorded because the change looked exactly like the other
# two, read as the obvious next instance of Cara's finding, and was INERT. `parked_by`'s VALUE is
# DERIVED from the reason inside mirror_ticket:
#     CASE WHEN nullif(p->>'parked_reason','') IS NOT NULL THEN coalesce(v_parked_by, v_owner) END
# so `EXCLUDED.parked_by` is NULL whenever the payload carries no park, no matter what this filter
# emits. Its guard therefore has to key on `p ? 'parked_reason'` — see migration 32 — and a
# presence test on its own key here reaches nothing.
# (infra_retire_the_refs_scan_park_overlay_now_that_parks_are_written_not_recovered)
#
# ⚠ `parked_reason` READS TWO SOURCE KEYS, which `claimed_by` does not: a ticket FILE uses `parked`,
# the column is `parked_reason`, and the old line was `(.parked // .parked_reason // null)`. So the
# presence test must be `has("parked") or has("parked_reason")` — asking about one key alone gets it
# wrong for every real ticket file. Driven: with the collapsed line, all three shapes (text / explicit
# null / no key at all) produced `has_key=true`, so `p ? 'parked_reason'` was always true and a
# key-presence guard in mirror_ticket would have been a second no-op that looked correct.
#
# ⚠ AND `parked_at` IS DERIVED FROM `parked_reason` in the ON CONFLICT clause
# (`CASE WHEN EXCLUDED.parked_reason IS NULL THEN NULL …`), so it wipes in sympathy. That is ONE
# failure presenting as two, not independent corroboration that a park died.
#
# ⚠ EVERY OTHER KEY IS DELIBERATELY LEFT COLLAPSED. They are guarded on key presence too, but their
# callers always send them, and `// null` is what keeps the shape stable for `extra`'s del() list.
# Only ownership has a caller — a sync from main — that legitimately means "I do not know".
#
# ⚠⚠ THAT LAST SENTENCE IS ALMOST RIGHT, AND ITS ONE MISSING CLAUSE IS WHY THE PARAGRAPH ABOVE
# EXISTS. "Only ownership has a caller that legitimately means I do not know" is the correct
# criterion, and `parked_by` meets it word for word while sitting collapsed a few lines up — which
# is exactly what sent me to change it. The missing clause: a field must ALSO be stored
# INDEPENDENTLY for a presence test here to reach it. **The criterion picks the right fields and
# says nothing about where the guard belongs.** So apply it to the next field added here, and then
# ask whether that field's value is derived from another one before assuming this is where its fix
# goes.
# ⚠ `extra_complete: true` IS APPENDED AT THE BOTTOM OF THIS PAYLOAD AND IT IS LOAD-BEARING.
# This builder computes `extra` by del()-ing every modelled key from a COMPLETE ticket file, so the
# result is the whole set of unmodelled keys — not a subset. Migration 125 reads the flag and
# REPLACES `extra` rather than merging it, which is what lets a key the file has DROPPED actually
# leave the row. Without the flag the merge can add and change but never remove, so a withdrawn key
# outlives every later read and the reconstruction re-emits it for ever.
#
# ⚠ ANY FUTURE WRITER THAT BUILDS A PARTIAL PAYLOAD MUST NOT SET IT. Omitting it is the safe
# default: migration 128 falls back to the old merge, so a partial writer can never blank a
# ticket's tail. Setting it while carrying a subset of the file's keys WOULD.
# (fix_the_ledger_reconstruction_invents_values_and_an_invented_key_is_indistinguishable_from_a_fact)
LEDGER_TICKET_PAYLOAD_JQ='{
      id, title, area, status,
      parked_by: (.parked_by // null),
      verified_by_pr: (.verified_by_pr // null),
      issue: (.issue // null),
      priority: (.priority // null),
      depends_on: (.depends_on // null), solo: (.solo // null), parent: (.parent // null),
      raised_by: (.raised_by // null), notes: (.notes // null),
      user_visible_behavior: (.user_visible_behavior // null),
      verification: (.verification // null), verification_command: (.verification_command // null),
      evidence: (.evidence // null),
      acceptance: (.acceptance // null),
      last_verified_commit: (.last_verified_commit // null),
      extra: (del(.id, .title, .area, .status, .claimed_by, .parked, .parked_by, .parked_reason,
                  .park_summary,
                  # ROW-OWNED (ledger_reconstruct.ROW_OWNED): a regenerated file carries it from the
                  # column; re-importing must not park a copy in extra, where it would go stale.
                  .park_condition, .park_kind,
                  .verified_by_pr, .issue, .priority, .depends_on, .solo, .parent,
                  .raised_by, .notes, .user_visible_behavior, .verification, .verification_command,
                  .evidence, .acceptance, .last_verified_commit))
    }
    + (if has("claimed_by") then {claimed_by: .claimed_by} else {} end)
    + (if (has("parked") or has("parked_reason"))
       then {parked_reason: (.parked // .parked_reason)} else {} end)
    + (if has("park_summary") then {park_summary: .park_summary} else {} end)
    + {extra_complete: true}'


# ── does git still hold a LOCK for this ticket? ──────────────────────────────────────────────────
#
# ⚠ THIS EXISTS BECAUSE THE PAYLOAD COULD NOT SAY WHAT ONLY GIT KNOWS, AND THE MIRROR GUESSED.
# `"claimed_by": null` on a ticket file means two different things and the file cannot tell you
# which: main is IGNORANT of a live claim (its flip lives on the lock branch, always), or git is
# ASSERTING a hand-back. Migration 028 read it as the second; since #7782 made the key universal,
# every live claim on main wears the first. The separating fact is whether `origin/<id>` exists —
# the LOCK, which CLAUDE.md already treats as the answer to "is this taken". (migration 104)
#
# ⚠ ONE `ls-remote`, NOT ONE PER TICKET. A full sync is ~2,250 tickets; asking per ticket would add
# a network round trip each. The set is read once and cached for the run.
#
# ⚠ AND A FAILURE HERE MUST NOT LOOK LIKE "NO LOCKS". If ls-remote fails — offline, auth, timeout —
# the set is UNKNOWN, and `_with_lock_held` then emits NO `lock_held` key at all, which migration
# 104 reads as CANNOT TELL: it keeps the owner and records a drift row. An empty set would read as
# "every lock is gone" and wipe all 94 live claims in one run, which is precisely the reassuring
# direction this whole ticket is about.
LEDGER_LOCK_SET=""      # path to the cached ref list, or "" when unknown
LEDGER_LOCK_SET_TRIED=0
# ⚠ THE LOCK SET LIVES FOR THE PROCESS AND MUST DIE WITH IT. Until 2026-09-08 nothing removed it: one
# `tmp.XXXXXXXXXX` per invocation, and the sweeps invoke this script per ticket — 2,464 tickets, so
# every sweep left thousands of files on a RAM-backed /tmp with a 1M-inode cap (378k of them on
# 09-07, 66k in one evening). (fix_scripts_leak_a_mktemp_file_per_call_and_nothing_gates_it)
_lock_set_release() { [[ -n "${LEDGER_LOCK_SET:-}" && -f "$LEDGER_LOCK_SET" ]] && rm -f "$LEDGER_LOCK_SET"; return 0; }
# _stale_tool_trailer is a no-op unless this copy is behind main (scripts/lib/stale-tool.sh).
trap '_lock_set_release; _stale_tool_trailer' EXIT
_lock_set_load() {
  [[ "$LEDGER_LOCK_SET_TRIED" == 1 ]] && return 0
  LEDGER_LOCK_SET_TRIED=1
  local f; f="$(mktemp)"
  if timeout 30 git ls-remote --heads origin 2>/dev/null | sed 's|.*refs/heads/||' | LC_ALL=C sort -u > "$f" && [[ -s "$f" ]]; then
    LEDGER_LOCK_SET="$f"
  else
    rm -f "$f"; LEDGER_LOCK_SET=""
    printf '\033[1;33m⚠ ledger-db: could not read the lock branches from origin — ownership is CANNOT-TELL for this run.\033[0m\n' >&2
    printf '  Claims the database holds are KEPT and each is recorded in ledger.import_drift.\n' >&2
    printf '  Nothing is cleared: an unreadable ref list is not evidence that a lock is gone.\n' >&2
  fi
  return 0
}
# _with_lock_held <payload-json> -> the payload, plus lock_held when git could be asked
_with_lock_held() {
  local payload="$1" id
  _lock_set_load
  [[ -z "$LEDGER_LOCK_SET" ]] && { printf '%s' "$payload"; return 0; }
  id="$(jq -r '.id // empty' <<<"$payload" 2>/dev/null)"
  [[ -z "$id" ]] && { printf '%s' "$payload"; return 0; }
  if grep -qxF "$id" "$LEDGER_LOCK_SET" 2>/dev/null; then
    jq -c '. + {lock_held:"true"}' <<<"$payload" 2>/dev/null || printf '%s' "$payload"
  else
    jq -c '. + {lock_held:"false"}' <<<"$payload" 2>/dev/null || printf '%s' "$payload"
  fi
}

# _sql_lit <text> -> a single-quoted SQL literal, quotes doubled                            (pure)
#
# ⚠ THIS EXISTS TO REMOVE AN ASSUMPTION, NOT TO TIDY ONE UP. `_emit` used to dollar-quote its
# payload with a fixed tag and a comment claiming that tag "cannot appear in ticket prose". Nothing
# enforced that; a ticket carrying the delimiter broke the whole sync at the SQL layer.
#
# ⚠ COMPLETE, GIVEN standard_conforming_strings = on (PG 16, verified on the live instance): inside
# a single-quoted string a backslash is literal, so doubling the apostrophe is the entire escape.
# If that setting were ever `off`, backslashes would become escapes again and this would need E''
# handling — which is why the precondition is written down here rather than assumed.
_sql_lit() { printf "'%s'" "$(printf '%s' "${1-}" | sed "s/'/''/g")"; }
# _unaccounted <emitted> <mirrored> <refused> -> "" | "<n> statement(s) never ran"          (pure)
#
# ⚠⚠ A SYNC CAN LOSE ROWS WITHOUT REFUSING THEM, AND UNTIL NOW NOTHING SAID SO.
# `_emit` appends one statement per ticket to ONE sql file which is executed as a whole. Anything
# that makes psql stop — a syntax error from a ticket's own prose, a connection dropped mid-file —
# abandons every statement after it. Those rows are not mirrored AND not refused: they are in
# NEITHER count, and the summary line goes on printing a plausible number.
#
# ⚠ MEASURED, and this is the reason this helper exists rather than a comment:
#   old code, one ticket carrying the payload delimiter -> "152 of 2397 mirrored, 70 refused".
#   152 + 70 = 222. **2175 tickets in neither number**, and `grep -c "syntax error"` over the whole
#   run returned ZERO — the error never reached the output at all.
#
# ⚠ THE DEFECT PROTECTED ITSELF: the tool printed a plausible count with no error beside it, so the
# smaller, wrong diagnosis ("one ticket failed to mirror") was the one its own output supported. It
# was corrected only by running both code paths and doing the arithmetic by hand.
# (infra_the_sync_summary_does_not_add_up_to_its_own_denominator)
#
# The check is arithmetic the summary can perform on itself, and it covers the whole CLASS: fixing
# one route to an aborted file — as the escaping fix did — closes one route, not the class.
# ⚠ FOURTH ARGUMENT, OPTIONAL, ADDED WITH `errored` (2026-09-16). It defaults to 0 so every existing
# caller and every existing assertion keeps its exact meaning — the arithmetic is unchanged when
# nothing errored, which is the case all the old self-tests describe.
_unaccounted() { # $1 emitted · $2 mirrored · $3 refused · [$4 errored]
  # ⚠ VALIDATE THE RAW ARGUMENTS, BEFORE ANY DEFAULTING. My first version wrote
  #     local emitted="${1:-0}" mirrored="${2:-0}" refused="${3:-0}"
  # and then tested those — so `${2:-0}` had already turned a MISSING count into a believable `0`,
  # the numeric test passed, and the helper reported a confident 2328-row loss that never happened.
  # **The defaulting defeated the validation**, and it failed toward alarm rather than silence,
  # which is the only reason the self-test caught it.
  local a b c gap
  for a in "${1-}" "${2-}" "${3-}"; do
    [[ "$a" =~ ^[0-9]+$ ]] || { printf 'the counts are not all numeric, so this run is UNVERIFIED'; return; }
  done
  # ⚠ VALIDATED ONLY WHEN SUPPLIED — `${4-}` is empty for every pre-existing caller and an empty
  # string is not numeric, so validating it unconditionally would make every old call UNVERIFIED.
  [[ -z "${4-}" || "${4-}" =~ ^[0-9]+$ ]] \
    || { printf 'the counts are not all numeric, so this run is UNVERIFIED'; return; }
  local emitted="$1" mirrored="$2" refused="$3" errored="${4:-0}"
  gap=$(( emitted - mirrored - refused - errored ))
  (( gap > 0 )) && printf '%d statement(s) never ran' "$gap"
  # ⚠ A NEGATIVE GAP IS ALSO WRONG and must not be silently swallowed by `> 0`: more rows accounted
  # for than were emitted means the counter and the output disagree about what was attempted.
  (( gap < 0 )) && printf 'the counts EXCEED what was emitted by %d — the accounting itself is wrong' "$(( -gap ))"
  return 0
}

# _count_ok_bad <file> -> "<mirrored> <refused>"                                          (pure)
#
# ⚠ `grep -c` EXITS 1 WHEN THE COUNT IS ZERO. That is grep reporting "no lines matched", not an
# error — so the old `$(grep -c … || echo 0)` printed the count AND THEN APPENDED ANOTHER ZERO,
# giving the two-line string $'0\n0'. `printf '%d'` then errored and `[[ "$bad" -eq 0 ]]` — the
# value sync_all RETURNS — threw an arithmetic syntax error, so a PERFECT sync exited non-zero.
#
# ⚠⚠ THE FAILURE MODE IS INVERTED, WHICH IS WHY IT SURVIVED FOR MONTHS: it misreports ONLY when
# nothing is wrong. One refusal gives a single clean `1` and everything works. Every sync before
# 2026-08-29 had six refusals (migration 17 was unapplied), so it could not fire until the day that
# defect was fixed — and it fired on the first complete sync this instance ever managed: 2348 of
# 2348, exit 1. The epic's phase-1 acceptance criterion is literally "sync exits 0".
#
# BOTH counters carry it. `ok`'s is latent until a sync where NOTHING mirrors, and fixing only the
# one that bit is the "I fixed the one I was looking at" defect this repo has been bitten by three
# times. (fix_ledger_sync_exits_one_on_complete_success)
# ⚠⚠ AND THE THIRD CATEGORY, ADDED 2026-09-16 AFTER VERA DROVE Ca4: AN ERROR IS NOT A REFUSAL.
# `_bad` was `grep -vc '|ok$'` — EVERY line that is not `<id>|ok`. A psql error emits FIVE lines
# (ERROR / LINE 1 / the caret / …), so ONE failed statement counted as FIVE refusals. `_unaccounted`
# then went negative and printed "⚠ THIS SYNC DID NOT FINISH … the accounting itself is wrong" on a
# rebuild where every one of 2,905 files and 1,479 of 1,482 legacy records had landed. A rebuilder
# reading that verdict starts a 63-minute run again.
#
# ⚠ THE FIX IS A CATEGORY, NOT A BETTER REGEX, BECAUSE THESE ARE DIFFERENT FACTS WITH DIFFERENT
# REMEDIES. A REFUSAL is `mirror_ticket` declining a row and returning a verdict — the row was seen,
# judged and rejected, and the remedy is in the ticket. An ERROR is the statement never reaching
# `mirror_ticket` at all — the remedy is in the payload or the SQL. Collapsing them told a reader to
# go and look at 8 tickets when 5 of the 8 were one broken statement.
#
# ⚠ COUNTED AS DISJOINT SETS AND SUBTRACTED, rather than by a positive pattern for refusals. A
# refusal verdict is free text (`refused:<sqlstate>:<message>`), so no pattern can safely enumerate
# it; a psql DIAGNOSTIC line, by contrast, always carries one of a known set of prefixes. So: count
# what is recognisable, and let refusals be the remainder. Anything new that psql starts printing
# lands in `errored`, which is the safe direction — it is reported rather than blamed on a ticket.
_count_verdicts() {   # <file> -> "<mirrored> <refused> <errored>"
  local f="${1:-}" _ok _diag _err _lines _refused
  _ok=$(grep -c    '|ok$' "$f" 2>/dev/null)   || _ok=0
  # one ERROR line per failed STATEMENT — this is the count of statements, not of noisy lines
  _err=$(grep -c   '^ERROR:' "$f" 2>/dev/null) || _err=0
  # every line psql emits ABOUT an error rather than as a result row
  _diag=$(grep -cE '^(ERROR|FATAL|PANIC|WARNING|NOTICE|DETAIL|HINT|CONTEXT|STATEMENT|LINE [0-9]+|psql):|^ *\^ *$' "$f" 2>/dev/null) || _diag=0
  _lines=$(grep -c . "$f" 2>/dev/null)         || _lines=0
  _refused=$(( _lines - _ok - _diag ))
  (( _refused < 0 )) && _refused=0
  printf '%s %s %s\n' "$_ok" "$_refused" "$_err"
}

# ⚠ KEPT AS A SHIM, NOT DELETED, because `_count_ok_bad` is what every existing caller and self-test
# names. Deleting it would have made this change look bigger than it is and would have taken the
# old assertions with it. It now reports the SAME two numbers it always did, with refusals no longer
# inflated by diagnostic lines.
_count_ok_bad() {
  local _v; _v="$(_count_verdicts "${1:-}")"
  printf '%s %s\n' "${_v%% *}" "$(cut -d' ' -f2 <<<"$_v")"
}
cd "$(dirname "$0")/.."

CONTAINER="${LEDGER_CONTAINER:-${HARNESS_PROJECT}-ledger-db}"   # harness.env, via lib/harness-env.sh

# ⚠ THIS HEADER HAS BEEN WRONG TWICE TONIGHT AND THIS IS THE MEASURED VERSION.
# scripts/lib/agent-name.sh resolves in THREE rungs, and the SESSION WINS:
#
#   0. $GIT_AUTHOR_EMAIL -> agents/roster.json -> name    source: session   <- WINS
#   1. .agent/name                                        source: file      (a DIRECTORY's label)
#   2. $AGENT_NAME                                        source: env       (last resort)
#
# Driven in THIS worktree, whose .agent/name says "Don":
#   GIT_AUTHOR_EMAIL=cara@weaversite.co.uk  ->  Cara / session   <- the session beats the directory
#   GIT_AUTHOR_EMAIL unset                  ->  Don  / file
#
# ⚠ MY FIRST VERSION SAID "prefers GIT_AUTHOR_NAME" — a variable read NOWHERE. My second said "the
# directory beats the session", which is the REVERSE of the truth. Caught by Cara.
#
# ⚠ AND THE SHARPER REASON MY EXPERIMENT AGREED WITH THE WRONG ANSWER (Saffron's):
# I exported GIT_AUTHOR_NAME=Cara — never read — while GIT_AUTHOR_EMAIL still held MY OWN address.
# So the SESSION rung answered "Don"... and this directory's .agent/name also says "Don".
# **BOTH CANDIDATE SOURCES PRODUCED THE SAME OUTPUT, so the test could not discriminate between
# them.** I read "the directory won" off a test incapable of telling me which one did.
# The discriminating case is to change the EMAIL, not the name: with cara@... set here, it returns
# Cara / session — the session beating a directory that says Don.
#
# ⚠ THE HAZARD IS NOT "STANDING IN THE WRONG DIRECTORY" (also Saffron's). It is a MISSING or WRONG
# GIT_AUTHOR_EMAIL silently renaming you WHEREVER YOU STAND. With the email set you are correctly
# yourself in anyone's worktree; with it unset you inherit whatever directory you are in — and that
# is the 2026-08-14 mechanism exactly.
#
# ⚠ AND THE REASON I MISSED RUNG 0 IS THE OTHER HALF OF THE FINDING: I grepped for
#     GIT_AUTHOR_NAME|AGENT_NAME|\.agent/name|...
# a pattern NAMING THE VARIABLE I HAD ALREADY ASSUMED. There are 25 references to GIT_AUTHOR_EMAIL
# in that file and my search could not match one of them. **An instrument keyed on your hypothesis
# can only return your hypothesis.** I then set GIT_AUTHOR_NAME, watched it fall through to the
# file, and read that as proof — a real observation with a fabricated mechanism behind it.
#
# ⚠ CLAUDE.md IS VINDICATED, NOT FICTION. It says set GIT_AUTHOR_EMAIL, and records 2026-08-14 as
# "GIT_AUTHOR_EMAIL was unset in every one of them" — which is exactly the condition under which
# rung 1 takes over and five sessions collapse onto one directory's label.
#
# ⚠ THE UNSAFE STATE IS *source != session*, NOT "the two disagree" (Cara's correction).
# With the email set you are correctly yourself EVEN IN SOMEBODY ELSE'S WORKTREE. My first guard
# refused exactly that — the case that is already right — and stayed silent for the agent with no
# email at all, who has no session name to disagree with. So the write path refuses on the SOURCE.

# _archived_payload <payload-json> -> the same payload as archived, with the park columns CLEARED
#
# ⚠ AN ARCHIVED TICKET IS NOT PARKED, AND A ROW ASSERTING BOTH IS REFUSED BY THE DATABASE.
# `park_columns_are_clear_when_not_parked` permits park columns only at status `parked`. Forcing
# `archived` from the DIRECTORY while leaving `parked_by`/`parked_at`/`parked_reason`/`park_kind` as
# the file wrote them produces exactly that row, and the batch does not stop, so the shortfall
# surfaces only as arithmetic.
#
# DRIVEN against the live database, rolled back, with a control:
#     archived + no parked_by  -> ACCEPTED
#     archived + parked_by     -> ERROR: park_columns_are_clear_when_not_parked
#
# ⚠ THIS IS PREVENTIVE AND THERE IS NO BAD DATA TO MIGRATE. The violating population was 14 -> 18 ->
# 21 and is **0 today**, emptied by 7ec0dc040 earlier the same day. The trap RE-ARMS on the next
# archive: 63 live tickets carry a real `parked_by`, every one legal at `status: "parked"`, each a
# violation the moment it moves under features/archive/. So do not go looking for a live violator —
# there is none, and the defect is still real.
#
# ⚠⚠ THE FALSE ZERO WAITING FOR THE NEXT READER. **No ticket file anywhere carries `status:
# "archived"`** — the status comes from the DIRECTORY, here. So a check written as `select where
# status == "archived"` returns 0 today, and would ALSO have returned 0 yesterday at 21.
# MATCH ON THE PATH, NEVER ON THE FIELD.
#
# ⚠ `del` RATHER THAN `= null`, deliberately. The payload builder uses `(.parked_by // null)`, and
# jq's `//` falls through only on `null`/`false` — **an empty string survives to the column and
# violates**. Deleting the keys cannot express a falsy-but-present value at all. (Vera's finding; no
# file holds one today, and a "cleared" marker written as "" would reintroduce the bug looking fixed.)
# (fix_the_sync_forces_archived_without_clearing_the_park_columns)
_archived_payload() {
  # ⚠⚠ THE REAL TERMINAL STATUS TRAVELS ALONGSIDE THE COERCION — IT NO LONGER REPLACES IT.
  # This used to be `.status="archived"` alone, which DESTROYED the file's passing/wont_do before
  # `mirror_ticket` ever saw it. Measured 2026-09-02: 2241 of 2241 archived tickets had a terminal
  # status the database could not reproduce (2194 passing, 46 wont_do), and those files are what
  # CUTOVER step 7 deletes — so the delivered-vs-abandoned distinction was one deletion from being
  # gone permanently and silently.
  # ⚠ THE COERCION ITSELF IS CORRECT AND STAYS. `status = 'archived'` is load-bearing in SEVEN
  # places — export's corpus filter, the readiness count, `finished:archived`, dependency
  # satisfaction, v_frontier's depends_on check, live_tickets per area, and the release guard — so
  # "preserve the terminal status" must NOT be read as "stop coercing".
  # ⚠ THE DEFECT WAS THE LAYER, NOT THE COERCION. Coercing at the CALL SITE meant the function never
  # saw the real value and so could not log drift for it — which is why no drift row has ever
  # existed for status.
  # ⚠ AND SENDING BOTH KEYS IS WHAT MAKES THIS SAFE TO DEPLOY AHEAD OF ITS MIGRATION. A mirror_ticket
  # that predates the migration ignores unmodelled top-level keys (`extra` is populated only from
  # `p->'extra'`), so it stores status='archived' exactly as today.
  # ⚠ IT LIVES HERE, IN THE ONE HELPER, RATHER THAN AT THE TWO CALL SITES. Both sites coerce; an
  # earlier version of this change edited both inline and would have had to keep them in step for
  # ever. The helper is the sibling-pair fix and this rides on it.
  # (fix_the_mirror_records_no_drift_row_when_it_coerces_an_archived_tickets_status)
  jq -c '. + {archived_from_status: .status, status: "archived"}
         | del(.parked_reason, .parked_at, .parked_by, .park_kind, .park_summary, .parked)' <<<"${1-}"
}

_me() {
  # shellcheck disable=SC1091
  source scripts/lib/agent-name.sh 2>/dev/null || true
  local n src
  n="$(agent_name_resolved 2>/dev/null || true)"
  src="$(agent_name_source 2>/dev/null || true)"

  # ⚠ A READ may proceed on any rung — it connects with the same privileges either way — but it
  # SAYS which rung, because a name from a directory label is a different claim from a name the
  # session proved.
  if [[ "$src" != session ]]; then
    printf 'ledger-db: ⚠ your name came from %s, not from your session (GIT_AUTHOR_EMAIL -> roster).\n' "${src:-nothing}" >&2
    printf '  Reading is fine. WRITING as this name is refused — see _require_session_identity.\n' >&2
  fi
  printf '%s' "$n"
}

_up() { docker exec "$CONTAINER" true >/dev/null 2>&1; }

# ⚠ WRITES REQUIRE A SESSION-PROVEN IDENTITY. Every write lands in an append-only log as its actor,
# and nothing downstream can correct a wrong one. Acting under a DIRECTORY's label is the 2026-08-14
# defect: five sessions, one name, none able to fix it from the inside.
# The remedy is at the session, not in here — which is why this refuses rather than guessing.
_require_session_identity() {
  source scripts/lib/agent-name.sh 2>/dev/null || true
  local src; src="$(agent_name_source 2>/dev/null || true)"
  [[ "$src" == session ]] && return 0
  echo "ledger-db: REFUSING TO WRITE — your identity came from ${src:-nothing}, not your session." >&2
  echo "  GIT_AUTHOR_EMAIL is unset (or not in agents/roster.json), so the name resolved from" >&2
  echo "  \`.agent/name\` — a label belonging to this DIRECTORY, not to you." >&2
  echo "  Fix it at the session: bash scripts/agent-onboard.sh --launch-line <YourName>" >&2
  return 3
}

# Run SQL AS THE CALLING AGENT. Returns psql's own exit code.
# ⚠ THE GUARD BELONGS HERE, ON THE DECISION PATH, NOT ON THE MIRROR — and putting it on the mirror
# first was an inconsistency worse than either choice: `mirror` refused while `sync` did the SAME
# writes in bulk and did not. Found by measuring what my own guard actually broke.
#
# The distinction that resolves it: a MIRROR copies a fact git has already decided, and its event is
# recorded as verb='mirrored' precisely so it is never counted as delivered work. Its actor answers
# "who ran the sync". A CLAIM or a PARK is an ownership DECISION, and its actor answers "whose work
# is this" — which is the question a wrong name makes permanently unanswerable.
#
# So the board stays fresh for everyone regardless of who runs the sync, and only the writes that
# assert ownership require a session-proven identity.
# ⚠ AN UNATTENDED RUN CONNECTS AS `ledger_sync`, NOT AS A PERSON, and this is the only place that
# can decide it — every write goes through here and the actor is `session_user`, so the CONNECTION is
# the attribution. Set only by `sync --unattended` (migration 38).
#
# ⚠ WHY IT MATTERS AT THIS SCALE. Measured on the live instance 2026-08-31: `ticket_event` is 99.9%
# mirror noise wearing a person's name — Don 194,638 mirrored against 17 real events, Anthony 14,480
# against 13. The log exists to answer *who did what* and currently answers "Don did 194,655 things".
# A timer that inherited whichever `.agent/name` its working directory happened to hold would not
# just continue that, it would make it unattributable to anything at all.
#
# ⚠ IT IS AN OVERRIDE OF THE CONNECTION, NOT OF THE GUARD. `_require_session_identity` is untouched
# and still refuses every ownership decision from a name that was not session-proven. This changes
# who the MIRROR connects as; it grants nothing.
LEDGER_ACTOR_ROLE="${LEDGER_ACTOR_ROLE:-}"

# _conn_role_pick <role-override> <resolved-name> -> the role to connect as, or "" = refuse   (pure)
#
# ⚠ THIS EXISTS BECAUSE THE RULE HAD TWO SPELLINGS AND ONLY ONE OF THEM WAS RIGHT.
# `_as_me` honoured LEDGER_ACTOR_ROLE at :296; the BULK sync 240 lines below did `me="$(_me)"` and
# never consulted it. The systemd timer runs the BULK path, so `--unattended` — the flag built for
# that timer, recorded as delivered by PR #7382 — had no effect on the only caller it was for.
#
# The unit's WorkingDirectory is the shared checkout, whose `.agent/name` reads
# `SHARED-CHECKOUT-NOT-AN-AGENT`. That is not a Postgres role. DRIVEN, with a control:
#
#     psql -U 'SHARED-CHECKOUT-NOT-AN-AGENT'  ->  FATAL: role does not exist   (exactly ONE line)
#     psql -U ledger_sync                     ->  connects
#
# ⚠ AND THAT ONE LINE IS WHY THE FAILURE LOG READ AS IT DID. `_count_ok_bad` counts output lines
# matching `|ok$`, so a single FATAL gives `mirrored=0, refused=1` — and `_unaccounted` then
# COMPUTES "26 never ran" as 27-0-1. **26 is arithmetic printed beside two observed values and is
# indistinguishable from a third observation.** An afternoon went into explaining that zero with a
# CHECK-constraint story; the zero was never a fact about mirroring.
#
# ⚠ NO FALLBACK WHEN THE ROLE IS SET — the reasoning is `_as_me`'s and it was already correct:
# falling back to a person's name would quietly restore the misattribution the flag exists to
# remove, and the timer would look healthy while doing the wrong thing. That comment sat 240 lines
# above the code that violated it, which is the whole lesson: a rule stated in one place and
# implemented in two is a rule with one enforced copy.
# (infra_the_unattended_flag_never_reaches_the_bulk_sync_path)
_conn_role_pick() { # $1 role-override · $2 resolved-name
  local override="${1-}" resolved="${2-}"
  [[ -n "${override//[[:space:]]/}" ]] && { printf '%s' "$override"; return 0; }
  [[ -n "${resolved//[[:space:]]/}" ]] && { printf '%s' "$resolved"; return 0; }
  return 3
}

# The one impure wrapper. Both the single-statement path and the bulk sync go through this, so the
# rule cannot drift apart again.
_conn_role() {
  local resolved=""
  [[ -z "${LEDGER_ACTOR_ROLE//[[:space:]]/}" ]] && resolved="$(_me)"
  _conn_role_pick "$LEDGER_ACTOR_ROLE" "$resolved"
}

_as_me() { # <sql>
  local me
  if ! me="$(_conn_role)"; then
    echo "ledger-db: cannot tell who you are — GIT_AUTHOR_NAME is unset and no .agent/name here." >&2
    echo "  Fix it at the SESSION, not from inside: bash scripts/agent-onboard.sh --launch-line <Name>" >&2
    return 3
  fi
  docker exec -i "$CONTAINER" psql -U "$me" -d ledger -v ON_ERROR_STOP=1 -tA -c "$1"
}

# ── ⚠ A VERDICT IS NOT AN EXIT CODE, AND UNTIL NOW THIS SCRIPT CONFLATED THEM ───────────────────
#
#   _as_me_verdict <sql>   — run it as me, print the verdict, and EXIT NON-ZERO if it is not `ok`
#
# ⚠ THE SYMPTOM THAT PAID FOR THIS: `ledger-db.sh park` rejected an over-long summary with
# `summary-too-long` and EXITED 0. The author saw a refusal, the shell saw success, and anything
# chaining on `&&` carried on as though the ticket had been parked. Same family as reading a
# pipeline's status and getting `tail`'s — the failure is visible to a human and invisible to a
# script, which is the worst of both.
#
# ⚠ WHY THE TEST IS A PREFIX AND NOT EQUALITY. The verbs do not share one success token: `park`
# returns `ok`, `adjudicate_retired_park` returns `ok:reassigned`, `claim` returns `ok:<id>`. So the
# contract is that a verdict STARTS with `ok` — which is already how every caller in this repo reads
# them by eye — and everything else is a refusal.
#
# ⚠⚠ THE CALLERS HAVE NOW BEEN READ, AND THE CAUTION THIS COMMENT USED TO CARRY WAS WRONG IN ITS
# MECHANISM. (infra_every_ledger_db_verb_reports_a_refusal_as_success_because_as_me_returns_psqls_status)
# It said converting the rest would make `sync` abort on the first refusal instead of recording it as
# drift. **`sync` does not go through this helper at all.** It builds one SQL file of
# `select 'id', ledger.mirror_ticket(...)` statements and runs it at the `-f -` call below WITHOUT
# `ON_ERROR_STOP=1` — deliberately, so a refused row never stops the file and the refusals can be
# counted. Nothing about converting a dispatch verb reaches it. The instinct not to widen blind was
# right; the reason given for it was not, and it had been written into a ticket as fact.
#
# WHAT READING THE CALLERS ESTABLISHED, verb by verb:
#   claim · flip-passing · release · unpark   ZERO external callers anywhere in scripts/ or .github/
#                                             — they are typed at a shell by a person. CONVERTED.
#   park                                      converted first, by the ticket that found this.
#   answer         NOT CONVERTED: it runs TWO statements and prints two verdicts, so a
#                  single-verdict contract does not fit it. It needs its own shape, not this one.
#   mirror         NOT CONVERTED: it is a shell FUNCTION with its own reporting, and it has ten
#                  references outside this file. Both live call sites in feature-ticket.sh already
#                  end `|| true`, so converting it would change nothing for them — which is an
#                  argument that it is safe, not that it is in scope here.
# ⚠ `reclassify-park` WAS NAMED IN THE OLD LIST AND IS NOT A VERB IN THIS FILE AT ALL. A list of
# affected things, written from memory of a surface rather than from a grep of it, had a member that
# does not exist — and it travelled into a ticket beside the numbers that did.
# ⚠ THE QUERIES ARE NOT VERBS AND MUST STAY ON `_as_me`: board, frontier, waiting, po-queue,
# po-owner, orphans, comments, summary, freshness. A query returning no rows is not a refusal, and
# giving them a verdict contract would turn "nothing to show" into a failing exit code.
# ⚠ THE DECISION IS PURE AND SEPARATE SO THE SELF-TEST CAN DRIVE IT. Asserting this through a live
# `park` would need a real ticket and would write real events into a shared database to prove an
# exit code; the refusal half can be driven against the box harmlessly (a nonexistent id writes
# nothing), but the SUCCESS half cannot, and a test with only the refusal half passes on a helper
# that returns 1 for everything.
# verdict_is_success <verb> <verdict> -> 0 success | 1 refusal   (PURE)
#
# ⚠⚠ THE SUCCESS VOCABULARY IS PER VERB. It was global, and that is the defect this replaces:
# `_verdict_rc` accepted `ok`/`ok:*` and refused everything else, which is exactly right for `park`
# — park has no non-ok success, every other arm dies — and wrong for the three verbs it was later
# applied to. Four verdicts are SUCCESSES that were being reported as failures:
#
#     claim    already-yours        idempotent no-op (003-protect.sql:26)
#     unpark   not-parked           "continuing, the git marker is the subject"
#     release  already-unassigned   the claim was already clear
#     release  archived:*           the owner is KEPT deliberately — an archived ticket's
#                                   claimed_by is the only record of who delivered it
#
# All four have live case arms, so those arms had become UNREACHABLE CODE and `release` died on
# every archived ticket — the normal flow after every merge. Coordinates carry their REF, because a
# bare file:line is silent about whose tree it came from: a colleague's numbers for these same arms
# were 75 out, correct in her branch, and I had copied them into this comment before she caught it.
#     origin/main:scripts/feature-ticket.sh:8813   ok|already-yours)
#     origin/main:scripts/feature-ticket.sh:10242  not-parked)
#     origin/main:scripts/feature-ticket.sh:11345  already-unassigned)   :11346  archived:*)
#     origin/main:scripts/feature-ticket.sh:11445  already-unassigned)   :11446  archived:*) Onset is clean: the release-claims janitor ran ok=22/failed=2 before the
# converting commit and ok=0/failed=10 after, last success 23:12:59, first of the unbroken run
# 23:23:44. (fix_verdict_rc_rejects_every_non_ok_success_so_release_dies_on_archived_tickets)
#
# ⚠ IT FAILS CLOSED, AND THAT IS THE HALF THAT MUST NOT BE "SIMPLIFIED". A verdict no rule names is
# a REFUSAL. Widening this to accept anything unrecognised would reinstate the defect the verdict
# contract was added to remove — a refusal reported as success — from the other direction. A new
# verdict added to a DB function must be added here deliberately, not inherited silently.
#
# ⚠ AND DO NOT COLLAPSE THIS BACK TO A GLOBAL LIST. `archived` is a genuine REFUSAL for `park`
# (feature-ticket.sh dies on it), so accepting `archived:*` for every verb makes a real refusal read
# as success one verb over. The verb is not decoration; it is what makes the answer right.
verdict_is_success() { # <verb> <verdict>
  case "${2-}" in ok|ok:*) return 0 ;; esac
  case "${1-}:${2-}" in
    claim:already-yours)        return 0 ;;
    intent:unchanged)           return 0 ;;
    unpark:not-parked)          return 0 ;;
    release:already-unassigned) return 0 ;;
    release:archived:*)         return 0 ;;
  esac
  return 1
}
_as_me_verdict() { # <verb> <sql>
  # ⚠ THE VERB IS NOW AN ARGUMENT because the success vocabulary is per verb — see
  # verdict_is_success. It was `_as_me_verdict <sql>` and the rule it applied was global.
  local _verb="$1" _v _rc
  _v="$(_as_me "$2")"; _rc=$?
  [[ -n "$_v" ]] && printf '%s\n' "$_v"
  # A connection or SQL failure is already non-zero and keeps its own code — this only adds the
  # refusal case, so `exit 3` from _as_me's identity check still means what it means.
  (( _rc != 0 )) && return "$_rc"
  verdict_is_success "$_verb" "$_v"
}

# ── mirror one ticket from its FILE into the database ────────────────────────────────────────────
# ⚠ THE FILE IS THE SOURCE WHILE GIT IS AUTHORITATIVE. This reads whatever the working tree says and
# makes the row match, so it is idempotent and safe to call after any write — including twice.
# It is NOT a claim: it copies a fact that has already been decided, which is why it may run as the
# owner-side upsert rather than through `claim`.
mirror() { # <id> [<file>] [<logical path>] [<source: main|ref|tree>]
  local id="$1" f logical src
  # ⚠ AN EXPLICIT FILE, BECAUSE THE CALLER OFTEN HAS THE TICKET AND THE WORKING TREE DOES NOT. A
  # freshly raised ticket lives only on its `<id>-raise` branch, and `feature-ticket.sh claim` cuts
  # its branch from origin/main — so at the moment claim needs the database to know the ticket, the
  # working tree has no such file and this function returned "no ticket file". feature-ticket.sh has
  # already resolved the content into `$FF` (a real path or a temp copy from whichever ref carries
  # it); letting it hand that over is the difference between the database being able to decide and
  # being asked about a row that does not exist.
  # (infra_turn_on_the_db_first_write_path_and_start_the_comparison_week)
  if [[ -n "${2:-}" ]]; then
    f="$2"
    [[ -f "$f" ]] || { echo "ledger-db: no such file: $f" >&2; return 1; }
  else
    f="features/$id.json"; [[ -f "$f" ]] || f="features/archive/$id.json"
    [[ -f "$f" ]] || { echo "ledger-db: no ticket file for $id" >&2; return 1; }
  fi
  _up || { echo "ledger-db: the ledger is not running — skipping the mirror (git is still authoritative)" >&2; return 0; }

  # ⚠ `parked_by` MUST TRAVEL. It was absent from this payload, so `mirror_ticket` — which now reads
  # it — received JSON that never contained it, and every parked-but-unclaimed ticket was still
  # refused `in-progress-without-an-owner`. THE RULE LIVED IN FOUR PLACES: the table CHECK, the
  # function's owner test, the function's parked_by derivation, and HERE. The first three JUDGE the
  # data; only this one CARRIES it, so fixing them in order moved the refusal count by exactly zero
  # three times running.
  local payload; payload="$(jq -c "$LEDGER_TICKET_PAYLOAD_JQ" "$f")" || return 1
  # Archived tickets live under features/archive/, and the file does not say so.
  # ⚠ BOTH archive-forcing sites go through the SAME helper. This one and _emit's below are a
  # sibling pair: fixing only the one the bug was found at leaves the identical defect in the other.
  # ⚠ ARCHIVED IS INFERRED FROM THE PATH, SO A TEMP COPY NEEDS ITS LOGICAL PATH HANDED OVER. When
  # feature-ticket.sh materialises features/archive/<id>.json from origin/main (a checkout that is
  # BEHIND main still holds the pre-merge live copy), the file it hands us is /tmp/xxx — and judging
  # that path as "not under features/archive/" mirrored a finished ticket as live. The third
  # argument is the path the content CAME FROM; absent, the file's own path decides as before.
  # (infra_the_release_janitor_mirrors_the_stale_working_tree_copy_so_a_just_merged_ticket_is_refused_as_not_yours)
  logical="${3:-$f}"
  # ── WHERE THIS CONTENT CAME FROM, DECLARED BY THE CALLER ──────────────────────────────────────
  #
  # ⚠ `main` IS A CLAIM ABOUT PROVENANCE AND MIGRATION 159 ENFORCES IT: a payload that says it did
  # not come from origin/main may CREATE a row and may not OVERWRITE one. Driven 2026-09-17 — ten of
  # the eighteen git-owned fields took a stale branch tip's values through this exact call.
  #
  # ⚠ THE DEFAULT IS `tree`, WHICH MEANS INSERT-ONLY, AND THAT IS THE DELIBERATE DIRECTION. A caller
  # that has not thought about provenance has not earned the right to overwrite the authoritative
  # store, and the refusal is LOUD — it returns `not-main:` and marks the row — so a path that has
  # gone inert cannot be mistaken for a path with nothing to do.
  # ⚠ Note this is the OPPOSITE default from the function's: absent means "keep today's behaviour"
  # in SQL, because migrations 080 and 141 call it with legitimate non-main updates. Out here every
  # caller is a git copy, so out here absent means "unverified". Same word, two scopes, and the
  # difference is which population is on the other side of it.
  src="${4:-tree}"
  payload="$(jq -c --arg s "$src" '. + {source:$s}' <<<"$payload")" || return 1
  [[ "$logical" == features/archive/* ]] && payload="$(_archived_payload "$payload")"
  # ⚠ THE SIBLING. `_emit` does the same two lines; a fix applied to only one of them leaves the
  # identical defect in the other, which is what this file's own comment two lines up warns about.
  payload="$(_with_lock_held "$payload")"

  # ⚠ AS THE AGENT, NOT AS THE OWNER. This ran as `ledger_owner` for its first ten minutes and every
  # event landed with actor='ledger_owner' — which is the identity design defeated by its own client.
  # mirror_ticket is SECURITY DEFINER and granted to ledger_agent precisely so the CALLER can be the
  # person: session_user is what the event records, and it is the only unforgeable part.
  # ⚠ `_sql_lit`, NOT A DOLLAR-QUOTE. This line carried a BARE $$...$$ for the whole life of
  # infra_the_mirror_payload_tag_can_appear_in_ticket_prose, which fixed the SAME defect in
  # `_emit` one function away and never migrated here. A bare $$ is far likelier to collide than
  # the tag that ticket worried about: `$$` is the shell PID idiom, so any ticket quoting a
  # `NAME="thing-$$"` line ends the literal early and the rest of its own prose is parsed as SQL.
  # That made the ticket unmirrorable, and because `release` mirrors first and the database is
  # authoritative, its claim could never be released by any guarded path.
  # (fix_mirror_builds_a_bare_dollar_quote_so_a_ticket_containing_one_can_never_be_released)
  _as_me "select ledger.mirror_ticket($(_sql_lit "$payload")::jsonb)"
}

# ── reconcile EVERY ticket from the working tree ─────────────────────────────────────────────────
# ⚠ ONE ROUND TRIP, NOT 2,231. The first version called `mirror` per ticket — a `docker exec` each —
# and did not finish inside two minutes. Sync builds one statement per ticket into a single file and
# runs it once. The lesson is not "batching is faster"; it is that a per-item shell-out is a design
# choice that only reveals itself at the real corpus size, and the real corpus was always available.
#
# ⚠ THE DRIFT IS THE MEASUREMENT, so it prints what it refused rather than a bare "done". A sync that
# reports only a total is indistinguishable from a sync that judged nothing.
# _sync_store_verdict <present|retired|missing> -> mirror | retired | broken            (pure, self-tested)
# The one place the three store states become the sync's three answers. `present` mirrors as
# today; `retired` is a decision (write nothing, exit 0, say why); `missing` is the broken read the
# ZERO-tickets guard has always refused, decided up front instead of after the tree walk.
_sync_store_verdict() {
  case "${1:-}" in
    present) printf 'mirror' ;;
    retired) printf 'retired' ;;
    # ⚠ ANOMALY IS NAMED RATHER THAN SWEPT INTO `broken`. It reaches the same refusal, so the mirror
    # behaves identically — but `broken` prints "features/ is absent and the marker is not in the
    # tree", and on an anomalous tree BOTH halves of that sentence are false. A refusal that names
    # the wrong cause sends the reader to fix something that is not wrong, which is worse than a
    # blank. (fix_a_single_ticket_file_silently_un_retires_the_whole_store)
    anomaly) printf 'anomaly' ;;
    *)       printf 'broken' ;;
  esac
}

sync_all() { # [--worktree]
  _up || { echo "ledger-db: the ledger is not running" >&2; return 1; }
  # ⚠ READS origin/main BY DEFAULT, NOT THE WORKING TREE, AND THAT IS THE WHOLE CORRECTION.
  # The first version read features/*.json from wherever you happened to be standing. Run from a
  # feature branch it mirrored THAT BRANCH's view of the board: five tickets raised on main were
  # invisible to it and simply never reached the database, while it reported "2214 of 2231 mirrored"
  # — a full-looking sync of the wrong corpus.
  #
  # ⚠ THIS IS THE THIRD TIME IN ONE EVENING I DESCRIBED THE WRONG COPY ACCURATELY: the schema
  # written from CLAUDE.md instead of from the tickets; the team briefed from my worktree instead of
  # from main; and this. **Git is authoritative during the migration, and `origin/main` IS git** —
  # a working tree is one agent's proposal, not the board.
  local from="origin/main" mode="main" incremental=0 legacy_only=0
  # ⚠ --since-last MIRRORS ONLY WHAT CHANGED, and exists so this can run at every session start.
  # A full sync is ~27s: ~12s reading 2251 blobs out of git, ~14s applying them. Both halves are
  # avoidable, because on a typical session start a handful of ticket files have moved and the other
  # 2245 rows are re-upserted to their existing values. The marker is a FILE, not a table: applying a
  # new migration to the live database currently needs a permission this session does not have, so a
  # schema-backed marker would be correct and inert. Per-worktree means each worktree pays one full
  # sync and is incremental thereafter.
  # ⚠ --unattended CHANGES WHO THE RUN CONNECTS AS, AND NOTHING ELSE. It is what the systemd timer
  # passes. Without it every mirror lands with `actor = <whichever agent name this directory holds>`,
  # which for a timer is not merely wrong but arbitrary — the same run attributes to a different
  # person depending on which worktree it was installed from.
  # ⚠ IT IS A FLAG RATHER THAN AUTO-DETECTION (`[[ -t 1 ]]`, `$INVOCATION_ID`, an absent TTY…)
  # BECAUSE AUTO-DETECTION IS A GUESS THAT FAILS SILENTLY IN BOTH DIRECTIONS: a piped interactive run
  # would attribute a person's work to the machine, and a timer started differently would attribute
  # the machine's work to a person. The caller knows; make the caller say.
  # (infra_nothing_schedules_the_ledger_sync_so_the_board_is_as_fresh_as_the_last_hand_run)
  if [[ "${1:-}" == "--unattended" ]]; then
    LEDGER_ACTOR_ROLE="ledger_sync"; shift
  fi
  if [[ "${1:-}" == "--since-last" ]]; then incremental=1; shift; fi
  # ⚠ --legacy-only IMPORTS THE THIRD STORE AND NOTHING ELSE, and it exists because the two costs are
  # not comparable. The ticket-file pass is ~2,900 `git show`+jq+sed round trips and is the slowest
  # phase in this script; the legacy pass is ONE jq (0.076s measured). Without this flag the only way
  # to land or re-land 1,480 legacy rows is to pay for a full sync of everything else — which on a
  # loaded box is what it sounds like, and is how this import first timed out at 25 minutes.
  # It reuses the same payload build, the same apply and the same summary: one write path, not two.
  if [[ "${1:-}" == "--legacy-only" ]]; then legacy_only=1; shift; fi
  # Accept the flags in either order — a timer unit is edited by hand and argument order is exactly
  # the kind of thing that silently degrades to "ran as a person" if it only works one way round.
  if [[ "${1:-}" == "--unattended" ]]; then
    LEDGER_ACTOR_ROLE="ledger_sync"; shift
  fi
  if [[ "${1:-}" == "--worktree" ]]; then
    from=""; mode="worktree"
    # ⚠ WARN, DO NOT REFUSE. Ed's: naming the ref makes the failure VISIBLE, but the two output
    # lines are only distinguishable to a reader who already knows `origin/main` is the right
    # answer. A warning removes that dependency — the tell no longer requires knowing the
    # convention. Refusing would be wrong: mirroring a working tree while developing is honest, and
    # a capability removed to prevent a misreading is a worse trade than a capability labelled.
    printf '\033[1;33m⚠ ledger-db sync --worktree: mirroring YOUR WORKING TREE, not the board.\033[0m\n' >&2
    printf '  A working tree is one agent'"'"'s proposal. Git is authoritative during the migration and\n' >&2
    printf '  `origin/main` IS git — tickets raised by others will be MISSING and nothing else says so.\n' >&2
    printf '  Use this for a local preview only; plain `sync` reads origin/main.\n' >&2
  else
    git fetch -q origin 2>/dev/null
  fi

  # ⚠ THE STORE IS JUDGED BEFORE A SINGLE BLOB IS READ, AND THE RETIRED STATE IS NOT AN ERROR.
  # Once the deletion merges (infra/ledger-db/CUTOVER.md step 7) the ROW is the source and there is
  # nothing on main to mirror — so a sync that runs anyway must say so and write NOTHING, because
  # the only files that could ever reappear under features/ after that point are a resurrection
  # (a janitor re-writing deleted files, a partial revert) and mirroring them would overwrite the
  # row from a stale copy. Measured on the code path before this arm existed: with a marker present
  # the incremental branch below saw ~2,900 deletions, kept none, printed "already up to date" and
  # exited 0 for ever; with NO marker (a rebuilt box, a fresh worktree's first init.sh) the full
  # branch read ZERO tickets and exited 1 — an OnFailure email every ten minutes for as long as the
  # timer stayed on. Neither was a decision. This is one, and it is the same predicate the gates use.
  # `missing` (no files, no marker) is the broken-read case and keeps the broken-read exit.
  # The unit itself belongs in scripts/systemd/deliberately-off from the deletion commit on; a
  # `git revert` of the deletion restores the files and this arm returns to mirroring by itself.
  # (infra_the_ledger_sync_janitor_decides_on_its_store_before_it_reads)
  . "$(dirname -- "${BASH_SOURCE[0]}")/lib/ticket-files.sh"
  local _store
  if [[ "$mode" == main ]]; then _store="$(ticket_files_state --ref "$from")"; else _store="$(ticket_files_state)"; fi
  case "$(_sync_store_verdict "$_store")" in
    retired)
      echo "ledger-db sync: NOT MIRRORED — the ticket files are RETIRED at ${from:-the working tree} ($TICKET_FILES_RETIRED_MARKER is in the tree, features/ is not). The row is the source; there is nothing to mirror and nothing was written. strength-ledger-sync.timer belongs OFF (scripts/systemd/deliberately-off); rollback = git revert the deletion commit, then re-enable it." >&2
      return 0 ;;
    anomaly)
      echo "ledger-db sync: NOT MIRRORED — ${from:-the working tree} carries BOTH $TICKET_FILES_RETIRED_MARKER and features/. The two stores disagree, so the corpus to mirror is undefined: mirroring a stray file would overwrite rows from a directory that should not exist, and skipping a restored corpus would silently stop the sync. Resolve it first — finish the rollback (remove the marker; git revert of the deletion commit does both) or remove the stray files. Nothing was written." >&2
      return 1 ;;
    broken)
      echo "ledger-db sync: read ZERO tickets from $mode — features/ is absent and $TICKET_FILES_RETIRED_MARKER is not in the tree: that is a broken read, not an empty ledger" >&2
      return 1 ;;
  esac

  local sql; sql="$(mktemp)"; local n=0
  # ⚠⚠ THE OLD TRAP WAS `rm -f '$sql'` UNCONDITIONALLY, AND IT DELETED THE EVIDENCE FOR ITS OWN
  # FAILURES. Vera's 63-minute Ca4 rebuild ended with one genuinely broken statement and NOBODY
  # COULD SAY WHICH FILE PRODUCED IT — the temp file naming it had been removed on the way out.
  # ⚠ THIS IS THE WORSE HALF OF THAT DEFECT: a wrong COUNT is corrected by the next run; a deleted
  # ARTEFACT is gone. Keep it whenever anything errored or was skipped, and print where it is.
  # shellcheck disable=SC2064
  trap "_sync_cleanup '$sql'" RETURN
  _sync_cleanup() {
    if (( ${_sync_errored:-0} > 0 || ${_emit_skipped:-0} > 0 )); then
      printf '  ⚠ kept the generated SQL for diagnosis (%d errored, %d skipped):\n      %s\n' \
        "${_sync_errored:-0}" "${_emit_skipped:-0}" "$1" >&2
      return 0
    fi
    rm -f "$1"
  }
  _emit() { # <json-text> <is_archived> [<source-label>]
    local payload
    # ⚠ parked_by must travel here too — see the note on the `mirror` payload above.
    payload="$(jq -c "$LEDGER_TICKET_PAYLOAD_JQ" <<<"$1" 2>/dev/null)" || return 0
    # ⚠⚠ `|| return 0` CATCHES jq FAILING. IT DOES NOT CATCH jq SUCCEEDING WITH EMPTY OUTPUT, and
    # that is the case that bit. Vera's Ca4 rebuild emitted
    #     select 'unknown', ledger.mirror_ticket(''::jsonb);
    # — an empty payload, five psql error lines, and a row that cannot name its own ticket. A guard
    # keyed on an EXIT STATUS cannot see a result that is merely empty.
    #
    # ⚠ AND `${_emit_id:-unknown}` MADE IT UNTRACEABLE. That fallback existed for a missing LABEL and
    # silently became the IDENTITY of the row — the "fallback of one component becoming the authority
    # of another" shape this repo has hit repeatedly. It is gone: if the id cannot be determined the
    # statement is NOT EMITTED AT ALL, and the source is named on stderr so the next reader has
    # something to open. A skipped-and-named file is recoverable; an emitted `unknown` is not.
    if [[ -z "$payload" || "$payload" == null ]]; then
      printf '  ⚠ SKIPPED (the payload builder produced nothing): %s\n' "${3:-<unnamed source>}" >&2
      _emit_skipped=$(( ${_emit_skipped:-0} + 1 ))
      return 0
    fi
    [[ "$2" == 1 ]] && payload="$(_archived_payload "$payload")"
    # ⚠ SIBLING OF THE `mirror` PATH ABOVE — both build a payload and BOTH must carry the lock, or
    # the one that does not silently reproduces the wipe. (migration 104)
    payload="$(_with_lock_held "$payload")"
    # ⚠ AND THE SIBLING AGAIN, FOR PROVENANCE. Migration 159 lets a payload that came from
    # origin/main update an existing row and confines every other source to inserting. `sync` reads
    # origin/main by default and a working tree under `--worktree`, and `$mode` is already the name
    # of that distinction — so the label is the mode rather than a second decision that can disagree
    # with it. ⚠ `--worktree` therefore becomes PREVIEW-ONLY for rows that already exist: it can
    # still add what the board is missing and can no longer overwrite the board with one agent's
    # proposal, which is what the warning fifty lines up has been asking people to remember.
    payload="$(jq -c --arg s "$mode" '. + {source: (if $s == "main" then "main" else "tree" end)}' <<<"$payload")" || return 0
    # ⚠⚠ NO LONGER DOLLAR-QUOTED, AND THE OLD COMMENT HERE WAS THE DEFECT.
    # It read: "Dollar-quoted with a tag that cannot appear in ticket prose."
    # CANNOT was doing work the code did not do. Nothing prevented a ticket's notes from containing
    # the delimiter; the sentence was a prediction about what people would write, checked by nothing.
    # DRIVEN: a description carrying it produced `ERROR: syntax error` at the SQL layer, BEFORE
    # mirror_ticket is entered — and because every ticket is appended to ONE sql file, a single
    # hostile description was not confined to its own row.
    # (infra_the_mirror_payload_tag_can_appear_in_ticket_prose)
    #
    # ⚠ THE REPLACEMENT IS DETERMINISTIC, NOT MERELY LESS LIKELY. A random per-run tag would have
    # shrunk the odds and kept the assumption; `_sql_lit` removes it. `standard_conforming_strings`
    # is `on` (verified on the live instance, PG 16), so a backslash inside a single-quoted string is
    # literal and doubling the quote is the COMPLETE escape — which is why the original worry about
    # apostrophes and backslashes does not apply. It is also the technique this very line already
    # used for the ticket id, one argument along.
    # ⚠ THE LABEL IS THE TICKET ID, NOT A COUNTER. A refusal used to read `1456|refused:...`, naming
    # a statement's position in a temp file deleted moments later — usable for counting and nothing
    # else. With the id it names the TICKET, which is what lets the next incremental run re-include
    # exactly the rows that did not land.
    _emit_id="$(jq -r '.id // ""' <<<"$payload" 2>/dev/null)"
    # ⚠ NO `:-unknown` FALLBACK — see above. A payload that parses but carries no id is the same
    # class of unidentifiable row, so it is skipped and named too.
    if [[ -z "$_emit_id" ]]; then
      printf '  ⚠ SKIPPED (payload carries no id): %s\n' "${3:-<unnamed source>}" >&2
      _emit_skipped=$(( ${_emit_skipped:-0} + 1 ))
      return 0
    fi
    ((++n))
    printf 'select %s, ledger.mirror_ticket(%s::jsonb);\n' \
      "$(_sql_lit "$_emit_id")" "$(_sql_lit "$payload")" >> "$sql"
  }

  # ⚠ THE THIRD STORE. `feature_list.archive.jsonl` holds every ticket closed before the per-ticket
  # migration -- 1,482 distinct ids, of which 1,480 had no row at all until this pass existed.
  # "Read the database, not the features directory" never meant "read only that directory's
  # successor": the jsonl is not IN `features/`, so no enumeration of that tree has ever seen it.
  # (infra_the_legacy_archive_jsonl_has_no_row_in_the_ledger)
  #
  # ⚠ IT GOES THROUGH `import_legacy_ticket`, NOT `mirror_ticket`, FOR TWO REASONS AND BOTH MATTER.
  # It stamps `legacy_source`, so a legacy row can never be mistaken for one that went through the
  # current lifecycle; and it REFUSES an id that already exists as a native row, which is not
  # hypothetical -- `feat_admin_pro_accent_system` and `fix_rest_timer_shows_lift_before_first_set`
  # are in BOTH stores, and an unguarded import would overwrite two live rows with legacy snapshots
  # that an existence check would then certify.
  #
  # ⚠⚠ ONE jq FOR THE WHOLE FILE, NOT TWO PER RECORD, AND THE DIFFERENCE IS NOT A MICRO-OPTIMISATION.
  # The first version called `_emit`-style helpers per record: 1,480 records x 2 jq x 2 sed (inside
  # `_sql_lit`) = ~5,900 subprocesses bolted onto a full sync that is already the slowest phase in
  # this script and has ALREADY blown the hourly suite's wall once (see the preflight note above).
  # MEASURED: the whole-file jq below produces all 1,482 payloads in **0.076s**. The loop that
  # follows spawns nothing -- `${v//\'/\'\'}` is a parameter expansion, where `_sql_lit` is a `sed`.
  #
  # ⚠ THE SEPARATOR IS A SPACE AND THAT IS SAFE HERE, NOT LUCKY. A ticket id is a slug and cannot
  # contain one; `@tsv` was the obvious choice and is WRONG, because it escapes tabs inside the JSON
  # payload and corrupts it.
  #
  # ⚠ READ FROM THE REF, NOT THE WORKING TREE, so a sync stays a pure function of `$from` exactly as
  # the ticket-file pass is. A worktree read would make the board depend on which checkout ran it.
  _legacy_pass() { # <ref> -> appends to $sql, echoes the record count
    local from="$1" line id payload count=0
    LEDGER_LEGACY_N=0
    if ! git cat-file -e "$from:feature_list.archive.jsonl" 2>/dev/null; then
      # ⚠ SAY IT. A silent skip is indistinguishable from "there were none", and a store nobody
      # noticed was unread is the entire defect this pass exists to fix.
      echo "  ledger-db: feature_list.archive.jsonl not present at $from — 0 legacy records" >&2
      return 0
    fi
    while read -u 3 -r line; do
      [[ -n "$line" ]] || continue
      id="${line%% *}"; payload="${line#* }"
      printf "select '%s', ledger.import_legacy_ticket('%s'::jsonb);\n" \
        "${id//\'/\'\'}" "${payload//\'/\'\'}" >> "$sql"
      count=$((count+1))
    done 3< <(git show "$from:feature_list.archive.jsonl" 2>/dev/null \
              | jq -rc "($LEDGER_TICKET_PAYLOAD_JQ) \
                        | . + {archived_from_status: .status, status: \"archived\"} \
                        | del(.parked_reason, .parked_at, .parked_by, .park_kind, .park_summary, .parked) \
                        | (if (.id | test(\"[A-Z]\")) then . + {legacy_original_id: .id, id: (.id | ascii_downcase)} else . end) \
                        | \"\\(.id) \\(tostring)\"" 2>/dev/null)
    # ⚠⚠ A GLOBAL, NOT AN ECHO, AND THIS WAS A REAL BUG IN THE FIRST VERSION. The call site read
    # `_legacy="$(_legacy_pass "$from")"` -- a COMMAND SUBSTITUTION, which is a subshell, so the
    # `>> "$sql"` appends survived (they are file writes) while `n` did not. The emitted counter
    # would have been 1,480 short and `_unaccounted` computes "statement(s) never ran" from it, so
    # the summary would have under-reported a number whose whole job is catching lost rows.
    n=$((n+count)); LEDGER_LEGACY_N="$count"
  }

  # ⚠⚠ PREFLIGHT THE CONNECTION BEFORE READING 2,628 TICKETS, BECAUSE THE READ IS THE EXPENSIVE HALF
  # AND IT IS WASTED WHEN THE WRITE CANNOT LAND.
  # (infra_the_hourly_full_suite_now_exceeds_its_timeout_so_main_gets_no_verdict)
  #
  # A full sync runs ONE `git show` per ticket file and only then opens psql. When the role cannot
  # connect, every one of those subprocesses is thrown away — the run reports `0 of N mirrored,
  # 1 refused, N-1 statement(s) never ran`, having spent the whole cost to learn something a single
  # `select 1` could have told it first.
  #
  # ⚠ MEASURED, not supposed. The hourly full suite on canary-box was killed at its 45-minute wall
  # three times (16:08, 17:06, 19:02 on 2026-09-05, all at 45.3 min). Phase timings against the last
  # green run show every phase within 7s EXCEPT this one: 39s -> 1154s. Inside it, 1141s elapsed
  # between two adjacent log lines, and the sync that followed mirrored 0 of 2628 rows. The suite did
  # not grow; a step that could not succeed took nineteen minutes to say so.
  #
  # ⚠ IT SKIPS, IT DOES NOT FAIL. The ledger is an observability surface and this caller is
  # best-effort by design (init.sh: "a stack that refuses to come up because a mirror was slow would
  # be a far worse defect than a stale board"). Returning non-zero here would convert a stale board
  # into a broken stack. The board's freshness does not depend on this path anyway — the
  # strength-ledger-sync timer mirrors main independently, which is exactly why a step mirroring
  # 0 of 2628 went unnoticed.
  #
  # ⚠ THE PROBE IS THE SAME COMMAND, ROLE AND CONTAINER AS THE REAL WRITE, so it cannot pass where
  # the write would fail. A cheaper probe that asked a different question would be a new guess.
  local _pf_role
  if _pf_role="$(_conn_role)" && [[ -n "${_pf_role//[[:space:]]/}" ]]; then
    if ! docker exec -i "$CONTAINER" psql -U "$_pf_role" -d ledger -tAc 'select 1' >/dev/null 2>&1; then
      echo "  ledger-db sync: SKIPPED — cannot connect as '$_pf_role', so nothing could be mirrored." >&2
      echo "    Not reading the board: a full sync is one git show per ticket file, and every one of" >&2
      echo "    them would be discarded by the same refusal this probe just hit." >&2
      echo "    The board is kept fresh by the strength-ledger-sync timer, not by this call." >&2
      return 0
    fi
  fi

  # ⚠ This script `cd`s to the repo root at line 20 and defines no REPO_ROOT — my first version used
  # one and died with `unbound variable` under `set -u`. A relative path is correct HERE precisely
  # because of that cd, which is the sort of thing that is only true in this file.
  local marker=".agent/ledger-sync.commit" since="" head_sha=""
  if (( legacy_only )); then
    _legacy_pass "$from"
    echo "  ledger-db: $LEDGER_LEGACY_N legacy record(s) from feature_list.archive.jsonl (--legacy-only: no ticket files read)"
  elif [[ "$mode" == main ]]; then
    head_sha="$(git rev-parse "$from" 2>/dev/null)"
    if (( incremental )); then
      since="$(cat "$marker" 2>/dev/null | tr -d '[:space:]')"
      # ⚠ EVERY WAY THE MARKER CAN BE WRONG FALLS BACK TO A FULL SYNC, LOUDLY. A recorded sha is not
      # evidence the commit still exists: this repo merges by REBASE, which rewrites commits, so a
      # marker written last week may name something no longer on main — the same reason
      # last_verified_commit is invalid on main by construction. It can also have been written on a
      # different box. Unreadable, unresolvable or not-an-ancestor all mean "I cannot compute a
      # delta", and the only safe answer to that is to read everything.
      if [[ -z "$since" ]]; then
        echo "  ledger-db sync: no marker yet — full sync (this worktree's first)"
        since=""
      elif ! git cat-file -e "${since}^{commit}" 2>/dev/null; then
        echo "  ledger-db sync: marker $since is not a commit here — full sync"
        since=""
      elif ! git merge-base --is-ancestor "$since" "$from" 2>/dev/null; then
        echo "  ledger-db sync: marker $since is not an ancestor of $from (rebased or rewritten) — full sync"
        since=""
      fi
    fi

    if [[ -n "$since" ]]; then
      # ⚠ A PATH IN THE DIFF MAY NOT EXIST AT `from` — an archive moves features/X.json to
      # features/archive/X.json, so the diff names BOTH and only the second still resolves. Emitting
      # the vanished one would send an empty payload and mirror a ticket as nothing.
      local _changed=0
      while read -u 3 -r path; do
        git cat-file -e "$from:$path" 2>/dev/null || continue
        local arch=0; [[ "$path" == features/archive/* ]] && arch=1
        _emit "$(git show "$from:$path" 2>/dev/null)" "$arch" "$from:$path"
        _changed=$((_changed+1))
      done 3< <( { git diff --name-only "$since" "$from" -- features/ | grep '\.json$'
                   # ⚠ ALWAYS RE-INCLUDE WHAT WAS REFUSED LAST TIME — this is what makes advancing
                   # the marker safe, and without it the fast path could never be reached at all.
                   if [[ -s "$marker.refused" ]]; then
                     while read -u 4 -r _rid; do
                       [[ -n "$_rid" ]] || continue
                       for _cand in "features/$_rid.json" "features/archive/$_rid.json"; do
                         git cat-file -e "$from:$_cand" 2>/dev/null && printf '%s\n' "$_cand"
                       done
                     done 4< "$marker.refused"
                   fi
                 } | LC_ALL=C sort -u )

      # ⚠ ZERO CHANGED FILES IS A LEGITIMATE ANSWER HERE, and must NOT reach the "read ZERO tickets"
      # guard below — that guard exists to catch a broken read of the WHOLE board, where zero is
      # impossible. In this mode zero means "nothing moved since $since", which is the common case
      # and the reason this mode is worth having. Reporting it as a broken read would train everyone
      # to ignore the one message that catches a genuinely dead instrument.
      if [[ "$_changed" -eq 0 ]]; then
        rm -f "$sql"
        echo "ledger-db sync: already up to date — no ticket changed between ${since:0:12} and $from"
        # ⚠ THIS EARLY RETURN IS NOW UNCONDITIONALLY CORRECT, AND IT WAS NOT BEFORE.
        # `sync` used to do two jobs — mirror ticket FILES from main, and overlay OWNERSHIP from
        # claim branches — and only the first is what `_changed` measures, so returning here once
        # meant parks reached the board almost never while printing "already up to date". The
        # overlay is retired, mirroring files is the whole job, and `_changed == 0` now genuinely
        # means there is nothing to do.
        # ⚠ DO NOT ADD A BRANCH SCAN BACK HERE. It is not an optimisation that was missing; it was
        # the leading source of store divergence, overwriting main's newer park with a branch's
        # older copy on every run.
        # (infra_retire_the_refs_scan_park_overlay_now_that_parks_are_written_not_recovered)
        return 0
      fi
      echo "  ledger-db sync: $_changed ticket file(s) changed since ${since:0:12}"
    else
      while read -u 3 -r path; do
        local arch=0; [[ "$path" == features/archive/* ]] && arch=1
        _emit "$(git show "$from:$path" 2>/dev/null)" "$arch" "$from:$path"
      done 3< <(git ls-tree -r --name-only "$from" features/ | grep '\.json$')

      # ⚠ FULL SYNC ONLY, AND THAT IS THE POINT RATHER THAN AN OPTIMISATION. The incremental path
      # is a `git diff` over `features/`, which can never name this file, and these records are
      # immutable legacy history so there is nothing incremental to pick up. What must be true is
      # that a REBUILT database gets them -- and a fresh database has no marker, so its first sync is
      # always a full one. That is the path this rides on. `import-legacy` exists for the rest.
      _legacy_pass "$from"
      echo "  ledger-db sync: $LEDGER_LEGACY_N legacy record(s) from feature_list.archive.jsonl"
    fi
  else
    for f in features/*.json features/archive/*.json; do
      [[ -e "$f" ]] || continue
      local arch=0; [[ "$f" == features/archive/* ]] && arch=1
      _emit "$(cat "$f")" "$arch" "$f"
    done
  fi

  # ⚠ A SYNC THAT READ NOTHING IS A DEAD INSTRUMENT, NEVER A CLEAN BOARD.
  if [[ "$n" -eq 0 ]]; then
    rm -f "$sql"; echo "ledger-db sync: read ZERO tickets from $mode — that is a broken read, not an empty ledger" >&2; return 1
  fi

  # ⚠ `_conn_role`, NOT `_me`. This line read `me="$(_me)"` and that is the whole defect: the
  # systemd timer passes `--unattended`, which sets LEDGER_ACTOR_ROLE, and this path ignored it and
  # connected as whatever name the WORKING DIRECTORY happened to hold.
  local me
  if ! me="$(_conn_role)"; then
    echo "ledger-db sync: cannot tell who to connect as — no LEDGER_ACTOR_ROLE and no resolvable name." >&2
    rm -f "$sql"; return 3
  fi
  docker exec -i "$CONTAINER" psql -U "$me" -d ledger -tA -f - < "$sql" > "$sql.out" 2>&1
  rm -f "$sql"
  local ok bad
  # ⚠ `grep -c` EXITS 1 WHEN THE COUNT IS ZERO — that is grep reporting "no lines matched", not an
  # error — so `$(grep -c … || echo 0)` prints the count AND THEN APPENDS ANOTHER ZERO, giving the
  # two-line string $'0\n0'. `printf '%d'` then errors and `[[ "$bad" -eq 0 ]]` throws an arithmetic
  # syntax error, so this function returned NON-ZERO on a PERFECT sync.
  #
  # ⚠⚠ THE FAILURE MODE IS INVERTED, WHICH IS WHY IT SURVIVED: it misreports ONLY when nothing is
  # wrong. One refusal gives `bad=1`, a single clean number, and everything works. Every sync before
  # 2026-08-29 had six refusals (migration 17 was unapplied), so the bug could not fire until the day
  # that defect was fixed — and it fired on the first complete sync this instance ever managed,
  # 2348 of 2348, exit 1. The epic's phase-1 criterion is literally "sync exits 0".
  #
  # `|| ok=0` assigns on grep's failure instead of appending to its output. Both lines carry the
  # bug; `ok`'s is latent until a sync where NOTHING mirrors, and fixing only the one that bit is
  # the "I fixed the one I was looking at" defect this repo has been bitten by three times.
  # (fix_ledger_sync_exits_one_on_complete_success)
  # ⚠ THREE CATEGORIES SINCE 2026-09-16 — see `_count_verdicts`. `bad` is REFUSALS only; a psql
  # error is its own count, because a refusal and an error are different facts with different
  # remedies and collapsing them reported one broken statement as five rejected tickets.
  read -r ok bad _sync_errored < <(_count_verdicts "$sql.out")
  # ⚠ THE CAP IS ANNOUNCED, NOT SILENT. This printed `head -8` while the summary below said "16
  # refused" — so a reader saw eight and had no way to know eight more existed. Silent truncation
  # reads as "that was all of them", which is the failure CLAUDE.md names for any bounded sweep:
  # say what was dropped. Found by comparing my own two numbers, four lines apart, in one output.
  # Same shape as a `docker ps | head -6` that truncated the container being looked for.
  # ⚠ AND THE ESCAPE MUST BE REAL. My first version of this message said "full list:
  # ledger-db.sh sync 2>&1 | grep refused" — which hits the SAME CAP, so it pointed at a remedy that
  # cannot work. A truncation notice whose workaround is also truncated is worse than no notice: it
  # tells the reader the rest is reachable when it is not. LEDGER_SYNC_SHOW_ALL=1 lifts it.
  # ⚠ `; _refused_list` USED TO SIT AT THE END OF THIS LINE and bash EXECUTED it as a command —
  # `_refused_list: command not found` on every single sync, and the variable was never declared
  # local, so it leaked to the global scope. It reads as a declaration and is not one; a stray `;`
  # is the whole difference. Two defects from one character, and the visible half was noise printed
  # in the middle of a summary nobody reads twice.
  local _shown="${LEDGER_SYNC_SHOW_ALL:+0}"; _shown="${_shown:-8}"
  local _refused_list
  _refused_list="$(grep -v '|ok$' "$sql.out" 2>/dev/null | grep -v '^$')"
  local _nref; _nref=$(printf '%s' "$_refused_list" | grep -c . || true)
  # ⚠ `printf '%s'` emits NO trailing newline, so the last refusal ran straight into the summary
  # line below it — "…parked_only_while_owned" + "ledger-db sync: 2245 of 2250…" on one line, which
  # reads as a single garbled message and hides both. Mine, from the cap fix. `printf '%s\n'` on a
  # non-empty list fixes it; the guard keeps an EMPTY list from printing a blank "refused:" row.
  if [[ -z "$_refused_list" ]]; then
    :
  elif (( _shown == 0 )); then
    printf '%s\n' "$_refused_list" | sed 's/^/  refused: /'
  else
    printf '%s\n' "$_refused_list" | head -n "$_shown" | sed 's/^/  refused: /'
    if (( _nref > _shown )); then
      printf '  refused: … and %d more not shown (%d refused in total) — re-run with LEDGER_SYNC_SHOW_ALL=1\n' \
        "$(( _nref - _shown ))" "$_nref"
    fi
  fi
  # ⚠ NAME THE REF, NOT THE MODE. Ed's, and it is the level above the subject count: a denominator
  # makes a VACUOUS pass visible, but it cannot make a WRONG-CORPUS pass visible, because the count
  # is honest. "2214 of 2231" looked no less correct than "2220 of 2237" — the number was real and
  # the corpus was one agent's branch. Printing the ref makes that failure visible on sight instead
  # of only by re-running from a different directory.
  # ⚠ AND NAME THE CODE, NOT ONLY THE REF. The line above was added after this function silently read
  # a working tree instead of origin/main — "name the ref you measured". That fixed half of it.
  # THE OTHER HALF: `sync` runs whatever copy of THIS SCRIPT the current branch happens to hold,
  # against the one shared production board. Driven 2026-08-27: run from a branch cut off main while
  # the `parked_by` payload fix sat unmerged, refusals went **5 -> 15** — the same output line, two
  # different programs, and a number that moved for no reason to do with the data.
  # So say which copy this is. `_ldb_variant` is empty when the script matches origin/main, which is
  # the common case and stays quiet.
  local _ldb_variant=''
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local _ldb_here _ldb_main
    _ldb_here="$(git hash-object "$0" 2>/dev/null)"
    _ldb_main="$(git rev-parse "origin/main:scripts/ledger-db.sh" 2>/dev/null || true)"
    if [[ -n "$_ldb_here" && -n "$_ldb_main" && "$_ldb_here" != "$_ldb_main" ]]; then
      _ldb_variant=" [⚠ running $(git branch --show-current 2>/dev/null || echo 'a detached HEAD')'s ledger-db.sh, which DIFFERS from origin/main]"
    fi
  fi
  printf 'ledger-db sync: %d of %d mirrored from %s, %d refused%s\n' \
    "$ok" "$n" "${from:-the working tree at $PWD}" "$bad" "$_ldb_variant"
  # ⚠ THE SUMMARY CHECKS ITS OWN ARITHMETIC. Every emitted statement must end up in exactly one of
  # the two counts; a shortfall means psql stopped part-way and the rows after it were never
  # attempted. Printed loudly and separately, because the line above is the one people read and it
  # looks entirely normal in exactly this case.
  local _unacc; _unacc="$(_unaccounted "$n" "$ok" "$bad" "${_sync_errored:-0}")"
  # ⚠ REPORTED SEPARATELY AND NAMED, because "8 refused" sent a reader to eight tickets when five of
  # the eight were one broken statement. An error is a defect in the PAYLOAD or the SQL; a refusal
  # is a defect in the TICKET.
  if (( ${_sync_errored:-0} > 0 )); then
    printf '  ⚠ %d statement(s) ERRORED before reaching mirror_ticket — not refusals, and not the\n' "${_sync_errored:-0}" >&2
    printf '     tickets fault. The generated SQL is kept above; grep it for the failing statement.\n' >&2
  fi
  if (( ${_emit_skipped:-0} > 0 )); then
    printf '  ⚠ %d file(s) were SKIPPED because the payload builder produced nothing — each is named\n' "${_emit_skipped:-0}" >&2
    printf '     above. They were NOT emitted, so they are not in any count below.\n' >&2
  fi
  if [[ -n "$_unacc" ]]; then
    printf '  \033[1;31m⚠ THIS SYNC DID NOT FINISH: %s.\033[0m\n' "$_unacc" >&2
    printf '     %d emitted, %d mirrored, %d refused — these do not add up, so the board is INCOMPLETE\n' \
      "$n" "$ok" "$bad" >&2
    printf '     and the rows after the failure were never attempted. They are in NEITHER count.\n' >&2
    printf '     Most likely one statement could not be parsed or the connection dropped mid-file.\n' >&2
    printf '     The failing statement names its ticket id; look in %s\n' "$sql.out" >&2
  fi
  rm -f "$sql.out"

  # ⚠ THE MARKER RECORDS WHAT WAS ACTUALLY MIRRORED, AND ONLY FROM A FULL-BOARD READ OF main.
  # Three conditions, each of which would otherwise make the next delta silently incomplete:
  #   · mode must be `main` — a --worktree sync mirrors one agent's proposal, so recording it would
  #     make the next incremental run skip everything main changed in the meantime.
  #   · `ok` must equal `n` — if any row was REFUSED it is not in the database, and advancing the
  #     marker past it means no future delta will ever include it again. A refused row would become
  #     permanently invisible, which is worse than the refusal.
  #   · the sha must be non-empty.
  # A marker that is merely ABSENT costs one full sync. A marker that is WRONG costs correctness
  # silently, for ever — so every uncertain case declines to write one.
  # ⚠ REFUSING TO ADVANCE ON ANY REFUSAL WAS RIGHT IN PRINCIPLE AND INERT IN PRACTICE. The guard
  # stopped a refused row being skipped by the next delta and lost. But five rows on this board are
  # refused by a constraint whose migration is not applied, so the marker NEVER advanced and
  # `--since-last` did a full 27s sync every single time — the optimisation was dead without ever
  # failing. Two of my own decisions, each defensible, colliding only when run for real.
  #
  # Both properties are available together: advance the marker AND record which ids were refused,
  # then always re-include those in the next delta. A refused row is retried every run until it
  # lands; an unchanged row is skipped. Nothing is lost and the fast path works.
  if [[ "$mode" == main && -n "$head_sha" ]]; then
    mkdir -p "$(dirname "$marker")" 2>/dev/null
    # ⚠ FROM THE VARIABLE, NOT THE FILE. `$sql.out` is removed a few lines above this point, so
    # re-reading it here silently produced an EMPTY refused list — and an empty list looks exactly
    # like "nothing was refused", which would have advanced the marker past five rows and dropped
    # them from every future delta. The failure would have been invisible and permanent.
    # `_refused_list` was already captured while the file existed; use that.
    printf '%s\n' "$_refused_list" | sed -n "s/^\\(.*\\)|refused:.*/\\1/p" | LC_ALL=C sort -u > "$marker.refused" 2>/dev/null || true
    printf '%s\n' "$head_sha" > "$marker" 2>/dev/null || true
    if [[ -s "$marker.refused" ]]; then
      echo "  ledger-db sync: $(wc -l < "$marker.refused") ticket(s) refused — RETRIED on every sync until they land, never skipped"
    fi
  fi

  # ⚠ MAIN IS THE WHOLE BOARD NOW, AND THAT IS THE CHANGE. This used to be followed by `refs-scan`,
  # which read every claim branch and overlaid its park text on top of the mirror's. It was built to
  # RECOVER parks main did not carry and it did that — 79 on its first run — but once parks were
  # written DB-first it became the leading source of divergence: measured A/B/A on the live
  # instance it caused 8 of 11 store conflicts, recovering 2 parks while overwriting 11, and in 7 of
  # those the branch's SHORTER, older text won over the corrected one. Hourly.
  # ⚠ ITS ORDERING COMMENT WAS RIGHT AND ITS PREMISE EXPIRED: "main first, branches second… running
  # it the other way round would let main's older copy overwrite it" assumed the branch is always
  # fresher. True while work is in flight, false the moment the PR merges — and squash-merged
  # branches survive carrying their pre-merge copy, so they never become ancestors of main and no
  # `--merged` sweep collects them.
  # ⚠ SO THE FIX WAS NOT TO INVERT THE ORDER. The overlay was not mis-ordered, it was obsolete.
  # (infra_retire_the_refs_scan_park_overlay_now_that_parks_are_written_not_recovered)
  #
  # ⚠ CARRIED FORWARD FROM infra_a_claim_is_two_facts_and_the_sync_restores_only_one, WHICH ASKED
  # FOR EXACTLY THIS RATHER THAN TO BE CLOSED AS OBSOLETE. That ticket's finding named a LINE that
  # this retirement deleted, but the DEPENDENCY it recorded outlives the line and is the thing to
  # keep: **nothing writes a live claim's `in_progress` into the database except the overlay, and
  # only for parks.** With the overlay gone, nothing does — which is CORRECT rather than a
  # regression, because migration 30 settles that git owns `status` unconditionally and main reads
  # `selected` for every live claim by construction (the claim flip lives on the claim branch). So
  # database and main agree, and `v_frontier` excludes on `claimed_by`, which `ledger.claim` writes.
  # ⚠ THE TRAP TO NOT RE-DERIVE: do NOT "fix" a live claim's status by guarding it here. Migration
  # 30 refused that deliberately, and the sanctioned path for a DB value to out-rank git is
  # `ledger.owner_set_field` -> `ledger.owner_override`, which is owner-only.

  # ── tell the BOARD that it was synced ──────────────────────────────────────────────────────────
  # (infra_nothing_schedules_the_ledger_sync_so_the_board_is_as_fresh_as_the_last_hand_run, part 1)
  #
  # ⚠ THE MARKER TWENTY LINES UP IS A LOCAL FILE AND CANNOT ANSWER THIS. `.agent/ledger-sync.commit`
  # is per-worktree, on one agent's disk — five worktrees hold five answers about one shared board,
  # and neither the owner, the console, nor any other agent can read any of them. **Freshness is a
  # property of the board, so it is recorded IN the board** (migration 31, `ledger.sync_run`).
  #
  # ⚠ LAST, DELIBERATELY: after the mirror, so the row means "a sync completed",
  # not "a sync began". A row written at the top would make a crashed sync look like a fresh board —
  # the reassuring direction again.
  #
  # ⚠ BEST EFFORT. Failing a real, successful sync because its
  # bookkeeping row would not insert is a worse trade than an unrecorded run: the sync's WORK is the
  # point, and an unrecorded run reports as staler than it is — which errs toward being looked at.
  # ⚠ AND IT IS NOT SILENT. A run that mirrored 2368 rows and then could not say so leaves the board
  # reporting an age it has not got, so the failure is announced rather than swallowed.
  # ⚠⚠ "SUCCEEDED" IS NOW CONDITIONAL ON SOMETHING HAVING BEEN MIRRORED, BECAUSE IT WAS NOT.
  # (infra_the_ci_ledger_sync_is_refused_on_its_first_statement_and_mirrors_nothing)
  # This branch fires when the bookkeeping row fails to record, and it used to announce "the sync
  # SUCCEEDED" unconditionally — including on a run that mirrored ZERO rows. Measured in CI: every
  # hourly full suite printed `0 of N mirrored, 1 refused` and then, on the very next line, that the
  # sync had SUCCEEDED. A total failure describing itself as a success is the most effective way
  # there is to train a reader past it, and it is a large part of why a step that has mirrored
  # nothing since at least 2026-09-02 went unnoticed for days.
  # ⚠ THE ORIGINAL SENTENCE IS KEPT VERBATIM FOR THE CASE IT WAS WRITTEN FOR — a real sync whose
  # freshness row would not insert. That case errs toward "looked at" deliberately and must not be
  # softened; the `$ok -gt 0` test is the whole of the change.
  _record_sync_run "$mode" "$head_sha" "$n" "$ok" "$bad" \
    || { if [[ "${ok:-0}" -gt 0 ]]; then
           echo "ledger-db sync: ⚠ the sync SUCCEEDED but its freshness row did not record — the board will read staler than it is" >&2
         else
           echo "ledger-db sync: ⚠ NOTHING WAS MIRRORED (0 of $n; $bad non-ok line(s)), and the freshness row did not record either." >&2
           echo "ledger-db sync:   That is not a stale board — it is a sync that did no work. The refusal above says why." >&2
         fi; }

  [[ "$bad" -eq 0 ]]
}

# _record_sync_run <mode> <head_sha> <n_seen> <n_mirrored> <n_refused>
# ⚠ THE ACTOR IS NEVER PASSED. `ledger.sync_run.actor` defaults to `session_user`, so the row names
# the ROLE this connection actually authenticated as — a value the caller cannot choose and
# therefore cannot get wrong. Passing a name would let a caller write a false actor into an
# append-only record whose whole purpose is attribution. (Same reasoning as
# `schema_migration.applied_by`, settled by #7192.)
# ⚠ AND IT GOES THROUGH `_as_me`, NOT A BARE docker exec, so it obeys the same connection and the
# same role as every other write in this file.
_record_sync_run() {
  local mode="${1-}" sha="${2-}" seen="${3-0}" mirrored="${4-0}" refused="${5-0}"
  # ⚠ A --worktree SYNC IS RECORDED TOO, and `v_board_freshness` is what excludes it. Dropping it
  # here instead would make the table quietly disagree with the count of syncs that actually ran,
  # and a record that hides half its writes is how a store starts lying.
  local sha_sql='NULL'
  # ⚠ SHAPE-CHECK THE SHA RATHER THAN QUOTE-ESCAPING IT. It comes from `git rev-parse`, but this is
  # string-interpolated into SQL, and "it can only ever be a sha" is precisely the assumption that
  # stops being true when someone reuses the function. A 40-hex check is cheaper than being wrong.
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && sha_sql="'$sha'"
  [[ "$seen"     =~ ^[0-9]+$ ]] || seen=0
  [[ "$mirrored" =~ ^[0-9]+$ ]] || mirrored=0
  [[ "$refused"  =~ ^[0-9]+$ ]] || refused=0
  [[ "$mode" == main || "$mode" == worktree ]] || return 1
  _as_me "insert into ledger.sync_run(mode, head_sha, n_seen, n_mirrored, n_refused)
          values ('$mode', $sha_sql, $seen, $mirrored, $refused)" >/dev/null 2>&1
}

# ── write git ticket files FROM the database ─────────────────────────────────────────────────────
# ⚠ THE DIRECTION THAT MAKES PHASE 4 POSSIBLE, and it was promised in phase 1 and never built.
# Today the database MIRRORS git. At cutover the arrow reverses and git becomes the mirror — which
# is impossible unless something can regenerate a ticket file from a row. This is that thing.
#
# ⚠ DRY RUN BY DEFAULT, AND NOT OUT OF TIMIDITY. Git is authoritative until phase 4, so writing
# files from the database TODAY would overwrite the authoritative copy with the derived one — the
# precise inversion this whole migration exists to perform carefully. `--write` is the opt-in, and
# it should stay unused until the cutover is a decision somebody has made out loud.
#
# ⚠ IT ALSO DOUBLES AS THE CUTOVER READINESS TEST. If the export differs from what git already
# holds, the two stores disagree — and every one of those differences must be understood BEFORE the
# arrow reverses, not explained away after. A clean dry run is the evidence that flipping is safe.
# A dry run that reports nothing is not the same as one that compared nothing: it says which.
# ⚠ AREA IS OMITTED FROM --write WHEN THE DATABASE'S VALUE IS A COERCION, NOT KNOWLEDGE.
# mirror_ticket stores "infra" for any area it cannot resolve, and records why in import_drift.
# Writing that back would replace a ticket's real area -- data, api, ui -- with the value that means
# "we did not know", and it would look like a tidy-up. Caught by driving --write on a COPY of the
# tree: the single diff it produced was "area": "data" becoming "area": "infra".
#
# ⚠ Same shape as the area ratchet rejecting infra while the mirror coerces TO it: THE FALLBACK OF
# ONE COMPONENT BECOMING THE AUTHORITY OF ANOTHER. Third instance tonight.
#
# ⚠ AND THE COMMENT EXPLAINING THIS ORIGINALLY LIVED INSIDE THE SQL STRING, WHERE ITS BACKTICKS WERE
# EXECUTED BY THE SHELL -- the query became unparseable and the export read ZERO tickets. Two
# verification lines then reported success from a run that had done nothing; only the
# "zero tickets is a broken read, not an empty ledger" guard caught it. Prose with backticks does
# not go inside a double-quoted shell string.
export_tickets() { # [--write] [<id> ...]
  # ⚠ AN ID FILTER, BECAUSE STEP 5 OF THE CUTOVER NEEDS TO REGENERATE *ONE* TICKET. Without it the
  # only way to write a file from the database was to rewrite all 211, which no lifecycle command
  # can do as a side effect of claiming or parking a single ticket. The filter is what lets
  # feature-ticket.sh write the file FROM THE RESULT rather than hand-editing it with jq.
  # ⚠ NO IDS MEANS EVERY TICKET, exactly as before — this is additive, and every existing caller
  # passes nothing. (epic_phase_4_the_ledger_database_becomes_authoritative)
  _up || { echo "ledger-db: the ledger is not running" >&2; return 1; }
  local write=0 base="origin/main"
  [[ "${1:-}" == "--write" ]] && { write=1; base=""; shift; }   # a write must target the working tree
  # ⚠ QUOTE-DOUBLED AND BUILT FROM THE ARGUMENTS, NEVER INTERPOLATED RAW. A ticket id is
  # `^[a-z][a-z0-9_-]{4,200}$` by CHECK constraint, so it cannot carry a quote today — but this
  # string is concatenated into SQL, and "the data cannot be hostile" is a property of a constraint
  # somebody may relax, not of this function. The doubling costs nothing and does not depend on that.
  local _id_filter="" _i
  if [[ $# -gt 0 ]]; then
    for _i in "$@"; do _id_filter="$_id_filter,'${_i//\'/\'\'}'"; done
    _id_filter=" and t.id in (${_id_filter#,})"
  fi
  # ⚠ COMPARES AGAINST origin/main, NOT THE WORKING TREE — AND I WROTE THIS FUNCTION WITH THE BUG I
  # HAD FIXED IN `sync` AN HOUR EARLIER. Comparing to whatever branch you are standing on reports
  # differences that are just your own unmerged edits, and misses tickets others have raised. Git is
  # authoritative during the migration and `origin/main` IS git.
  # ⚠ Fourth instance today of describing the wrong copy accurately: the enum from CLAUDE.md, the
  # team briefed from my worktree, `sync` reading the branch, and now this. Knowing the shape did
  # not stop me reproducing it in the next function I wrote.
  [[ -n "$base" ]] && git fetch -q origin 2>/dev/null
  local out; out="$(mktemp -d "${TMPDIR:-$HOME/.cache}/ledger-export.XXXXXX")"
  # ⚠ A QUOTED HEREDOC, NOT A DOUBLE-QUOTED STRING — AND THAT IS THE WHOLE FIX. This SQL carries
  # explanatory comments, and comments name identifiers in backticks. INSIDE DOUBLE QUOTES A
  # BACKTICK IS COMMAND SUBSTITUTION: bash ran `absent`, ran `[[ differ -eq 0 && absent -eq 0 ]]`,
  # spliced the resulting errors into psql's argument list, and the SQL that arrived had lost its
  # table alias — "missing FROM-clause entry for table t". Four backticks, ALL IN COMMENTS, none in
  # SQL that mattered. Broken from 980e55a12 (2026-08-31) until 2026-09-02.
  #
  # ⚠⚠ AND WITHOUT ONE GUARD IT WOULD HAVE REPORTED A PERFECT DRY RUN. A read that returns nothing
  # yields ZERO DIFFERENCES, and zero differences is exactly what the cutover procedure waits for.
  # The only thing between that and a green light is the "read ZERO tickets — a broken read, not an
  # empty ledger" check below. Keep it.
  #
  # ⚠ THE QUOTED DELIMITER IS LOAD-BEARING: <<'SQL' does no expansion at all, so a backtick added to
  # a comment tomorrow is inert. An UNQUOTED heredoc would interpolate variables AND still run
  # backticks — it fixes nothing. The one interpolation this query needs is appended afterwards,
  # deliberately, so the heredoc itself never has to expand anything.
  # (scripts/check-no-backtick-in-a-shell-quoted-sql-string.sh gates the class.)
  local _sql
  _sql="$(cat <<'LEDGER_EXPORT_SQL'
    select t.id || E'\t' || jsonb_build_object(
      'id', t.id, 'title', t.title,
      -- ⚠ AN ARCHIVED ROW'S OWN `status` IS THE LITERAL 'archived', WHICH IS NOT THE TICKET'S
      -- TERMINAL STATUS. `--write` patches with `. + ($d|with_entries(select(.value != null)))`, so
      -- emitting t.status here would write "archived" over "passing" in ~2480 real files, and those
      -- files are the ONLY copy of that distinction.
      --
      -- ⚠ IT IS A COLUMN SINCE MIGRATION 148. These lines used to say "`ledger.ticket` has NO
      -- archived_from_status column" and read the value back with a correlated subquery into
      -- `ledger.import_drift` — a DIAGNOSTIC LOG that happened to hold the only copy of this one
      -- fact, told apart from the coercion rows in the same `field='status'` by the value filter
      -- `d.found IN ('passing','wont_do')`. `mirror_ticket` now writes `t.archived_from_status`
      -- from the payload key ledger-db.sh:330 has been sending since migration 83.
      --
      -- ⚠ THE SUBQUERY THIS REPLACES TIE-BROKE WITH `ORDER BY d.found LIMIT 1`, AND THE DETECTOR
      -- THAT CHECKS IT TIE-BROKE WITH `max(d.found)` — OPPOSITE DIRECTIONS. Driven on a throwaway
      -- with one planted pair (passing + wont_do): the export read `passing`, the gate read
      -- `wont_do`, both silently, both green. Two readers of one fact disagreeing is not a
      -- theoretical risk of a value-filtered log lookup, it is what one costs. The corpus holds one
      -- real instance of a doubled status row today (`epic_release_approval_in_the_admin_console`:
      -- blocked + passing) and it is harmless only because `blocked` falls outside the filter.
      --
      -- ⚠ NULL WHEN UNRECOVERABLE, NEVER `coalesce(..., t.status)`. `--write` drops null values, so
      -- an unrecoverable ticket is LEFT ALONE and shows as a visible difference. Coalescing would
      -- reintroduce the clobber this restoration exists to prevent, silently and at scale. The
      -- column is NULL for exactly that case; it is not defaulted.
      --
      -- ⚠ 'archived' ECHOED BACK RECOVERS NOTHING, and the column cannot hold it:
      -- `ticket_archived_from_status_check` permits only NULL, 'passing' or 'wont_do', and
      -- `mirror_ticket` lands anything else as NULL rather than raising.
      'status', CASE WHEN t.status = 'archived'
                     THEN t.archived_from_status
                     -- ⚠ ::text IS REQUIRED, NOT TIDINESS. t.status is the enum
                     -- ledger.ticket_status and d.found is text; without the cast postgres refuses
                     -- the CASE outright ("types ledger.ticket_status and text cannot be matched")
                     -- and export reads ZERO rows. Caught by the "read ZERO tickets" guard, which
                     -- is the one thing standing between a broken read and a perfect-looking dry run.
                     ELSE t.status::text END,
      -- (see the note above export_tickets: area is omitted when the DB value is a coercion)
      'area', CASE WHEN EXISTS (SELECT 1 FROM ledger.import_drift d
                                WHERE d.id = t.id AND d.field = 'area')
                   THEN NULL ELSE t.area END,
      'claimed_by', t.claimed_by,
      'parked', t.parked_reason, 'verified_by_pr', t.verified_by_pr, 'issue', t.issue
    )::text
    -- ⚠ draft AND reviewed ARE EXCLUDED, AND IT IS THE EXIT CODE THAT FORCES IT, NOT THE WRITE.
    -- The write was already safe: a row with no ticket file falls to the `absent` arm below, which
    -- refuses to author one even under --write ("the database owns the LIFECYCLE, git owns the
    -- PROSE"). A draft is database-only and has no file, so it lands there correctly.
    --
    -- ⚠ BUT THIS FUNCTION RETURNS `[[ differ -eq 0 && absent -eq 0 ]]`. Every draft increments
    -- `absent`, so without this filter export exits NON-ZERO for as long as any draft exists --
    -- and CUTOVER.md designates export as the readiness test for step 6, whose comparison week
    -- needs seven CLEAN days and currently cannot get past one. That is step-6 divergence arriving
    -- through the exit status rather than through a bad write, and it would be permanent.
    --
    -- ⚠ THE EXCLUSION IS ANNOUNCED BELOW, BESIDE THE ARCHIVED COUNT. This file has already learned
    -- twice that a silent cap reads as a clean result -- once on the refusal list, once on the
    -- difference list -- and its own archived-exclusion block says silence would "restore exactly
    -- the false clearance this block exists to remove". A silent draft exclusion is that defect a
    -- third time, in the function whose entire job is saying what it compared.
    -- (feat_the_ledger_ticket_has_a_draft_and_reviewed_status, migration 34)
    -- ⚠ 'archived' IS NO LONGER EXCLUDED. It was, and the exclusion was correct while the
    -- terminal status could not be restored: widening first would have written 'archived' over
    -- ~2480 files' real status. That precondition is now met (the CASE above), so the corpus can
    -- widen -- and it must, because CUTOVER.md designates this function as the readiness test for
    -- step 6 and step 7 DELETES every ticket file. A tool that could answer for 9% of the corpus
    -- was not a readiness check for deleting it.
    -- (infra_the_export_corpus_still_excludes_every_archived_ticket_and_widening_it_needs_the_archive_path_too)
    from ledger.ticket t where t.status not in ('draft','reviewed')
LEDGER_EXPORT_SQL
  )"
  _sql="$_sql$_id_filter"
  docker exec "$CONTAINER" psql -U ledger_owner -d ledger -tAc "$_sql" 2>/dev/null > "$out/rows.tsv"

  local n; n=$(wc -l < "$out/rows.tsv")
  if [[ "$n" -eq 0 ]]; then
    rm -rf "$out"; echo "ledger-db export: read ZERO tickets — a broken read, not an empty ledger" >&2; return 1
  fi

  local same=0 differ=0 absent=0 _declined=0 _differ_list="" _d_fields=""
  while IFS=$'\t' read -u 3 -r id json; do
    # ⚠ AN ARCHIVED TICKET DOES NOT LIVE AT features/<id>.json. Widening the corpus without this
    # sends every archived row to the `absent` arm, and this function returns
    # `[[ differ -eq 0 && absent -eq 0 ]]` -- so export would exit NON-ZERO permanently. That is the
    # identical failure the draft/reviewed exclusion was added to prevent, arriving a second time
    # from a different direction.
    #
    # ⚠ AND `$f` IS WHAT `--write` WRITES TO, twenty lines below. Resolving the path is therefore
    # not presentation: without it a widened `--write` would target features/<id>.json for an
    # archived ticket and CREATE a live copy beside the archived one -- the live-and-archived
    # collision that resolve-ledger-ghosts.sh exists to clean up, manufactured at scale by the tool
    # whose job is to prove the two stores agree.
    #
    # LIVE PATH FIRST, ALWAYS. A ticket present in both places is a ghost, and preferring the live
    # copy keeps this tool reporting the same difference every other ledger gate reports rather
    # than silently reading the archived one and calling it agreement.
    local f="features/$id.json" _fa="features/archive/$id.json" cur
    if [[ -n "$base" ]]; then
      cur="$(git show "$base:$f" 2>/dev/null)" || cur=""
      if [[ -z "$cur" ]]; then
        cur="$(git show "$base:$_fa" 2>/dev/null)" || cur=""
        [[ -n "$cur" ]] && f="$_fa"
      fi
    else
      cur="$(cat "$f" 2>/dev/null)" || cur=""
      if [[ -z "$cur" ]]; then
        cur="$(cat "$_fa" 2>/dev/null)" || cur=""
        [[ -n "$cur" ]] && f="$_fa"
      fi
    fi
    if [[ -z "$cur" ]]; then
      absent=$((absent+1))
      # ⚠ NEVER CREATE A TICKET FILE FROM THE DATABASE, EVEN WITH --write. The database models NINE
      # lifecycle fields; a ticket file also carries `notes`, `user_visible_behavior`,
      # `verification`, `verification_command`, `priority` and `depends_on` — the prose the ledger
      # EXISTS FOR. Writing one from a row produces a stub with all of that gone.
      #
      # Proved on a copy before this guard existed: a generated file had
      #   area, claimed_by, id, issue, lock_intent, parked, status, title, verified_by_pr
      # against a real ticket's
      #   area, depends_on, id, notes, priority, status, title, user_visible_behavior
      # ⚠ That is data loss at cutover, in the direction nobody would notice — the file exists, it
      # parses, and every field the database checks is present.
      #
      # THE DIVISION OF OWNERSHIP IS THE POINT: the database owns the LIFECYCLE, git owns the PROSE.
      # An export may UPDATE what the database owns. It may never AUTHOR a ticket.
      [[ "$write" == 1 ]] && printf '  ⚠ %s is in the database with no ticket file — NOT created; the database cannot author prose.\n' "$id"
      continue
    fi
    # ⚠ COMPARE ONLY THE FIELDS THE DATABASE OWNS. A ticket file carries prose the database does not
    # model — notes, verification, user_visible_behavior — and calling those a "difference" would
    # report every ticket as divergent and drown the ones that matter.
    # ⚠ A NULL IN THE DATABASE PAYLOAD IS "DECLINES TO OWN", NOT "DISAGREES", AND THE WRITE PATH
    # HAS ALWAYS SAID SO. `--write` patches with `with_entries(select(.value != null))` — it drops
    # every null — so a null field is precisely one `--write` will never touch. Counting it as a
    # difference reports a disagreement the tool would not act on even if asked.
    #
    # MEASURED 2026-09-08, and this is why it stopped being cosmetic: the `area` CASE above emits
    # NULL whenever an import_drift row exists for area, and 434 of the 2480 archived tickets have
    # one. Before the corpus widened, 4 live tickets hit this and it read as noise. After widening
    # it was 434 of 486 differences — enough to bury the 10 that were real, and CUTOVER.md's bar is
    # "zero UNEXPLAINED differences", so it would have blocked the cutover permanently on fields
    # nothing was ever going to write. ⚠ THE DEFECT IS OLDER THAN THIS CHANGE; widening only made
    # it visible at scale.
    #
    # ⚠ COUNTED AND ANNOUNCED, NEVER SILENTLY DROPPED. This function has already learned twice that
    # a silent cap reads as a clean result — once on the refusal list, once on the difference list —
    # and a field quietly excluded from the comparison is that same defect a third time. What is not
    # compared is stated in the headline beside what is.
    #
    # ⚠ "DECLINED" MEANS THE DATABASE HAS NO OPINION AND THE FILE DOES — not merely that the field
    # is null. Both sides null (an unparked ticket's `parked`, an unclaimed ticket's `claimed_by`)
    # is AGREEMENT and always was. Counting every null as declined reported 2725 of 2740 tickets,
    # which is not a finding, it is the announcement drowning the thing it announces.
    local a b _af _bf _decl
    _af="$(jq -S '{id,title,area,status,claimed_by:(.claimed_by//null),parked:(.parked//null),verified_by_pr:(.verified_by_pr//null),issue:(.issue//null)}' <<<"$cur" 2>/dev/null)"
    _bf="$(jq -S '{id,title,area,status,claimed_by,parked,verified_by_pr,issue}' <<<"$json" 2>/dev/null)"
    # Compare only what the database actually asserts — exactly the fields `--write` would patch.
    b="$(jq -S 'with_entries(select(.value!=null))' <<<"${_bf:-{\}}" 2>/dev/null)"
    a="$(jq -S --argjson b "${b:-{\}}" 'with_entries(select(.key|IN($b|keys[])))' <<<"${_af:-{\}}" 2>/dev/null)"
    _decl="$(jq -rn --argjson a "${_af:-{\}}" --argjson b "${_bf:-{\}}" \
      '[$b|keys[]|select(($b[.]==null) and ($a[.]!=null))]|length' 2>/dev/null)"
    [[ "${_decl:-0}" -gt 0 ]] && _declined=$((_declined+1))
    if [[ "$a" == "$b" ]]; then same=$((same+1)); else
      differ=$((differ+1))
      # ⚠ NAME THE FIELDS, NOT JUST THE TICKET. The comparison spans nine fields and this line
      # reported none of them, so CUTOVER.md's instruction — "read every difference, stop if one is
      # unexplained" — meant re-deriving each diff by hand. The fields ARE the explanation.
      _d_fields="$(jq -rn --argjson a "$a" --argjson b "$b" \
        '[$a|keys_unsorted[] | select(($a[.]|tostring) != ($b[.]|tostring))] | join(",")' 2>/dev/null)"
      # ⚠ COLLECTED, NOT PRINTED HERE. The old line printed the first 8 and stopped, silently — see
      # the announcement below. (fix_the_cutover_readiness_export_shows_eight_of_fifty_three_differences)
      _differ_list+="${_differ_list:+$'\n'}  differs: $(printf '%-58s' "$id") ${_d_fields:-<field unknown>}"
      # ⚠ NO `-S`. Sorting the keys rewrites the whole file's order for a one-field change, so a
      # lifecycle update arrives as a diff touching every line and nobody can see what actually
      # changed. Preserve the author's key order; only the values the database owns are replaced.
      [[ "$write" == 1 ]] && jq --argjson d "$json" '. + ($d|with_entries(select(.value != null)))' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    fi
  done 3< "$out/rows.tsv"
  rm -rf "$out"

  # ── the difference list ───────────────────────────────────────────────────────────────────────
  # ⚠ THE CAP IS ANNOUNCED, NOT SILENT — and this file already knew that. `:324` records the same
  # defect on the REFUSAL list ("a reader saw eight and had no way to know eight more existed") and
  # fixes it at `:351`. This list, twelve lines further down, kept a bare `[[ "$differ" -le 8 ]]`
  # and printed 8 of 53 with nothing to say so. **A rationale written into a file is not a property
  # of the file** — the lesson has to be carried to each site by hand.
  #
  # ⚠ AND IT MATTERS MORE HERE THAN THERE, because `export` IS the cutover readiness test (see the
  # note above this function), and CUTOVER.md's bar is "zero UNEXPLAINED differences". Eight of
  # fifty-three is not a shorter answer to that question — it is a different one.
  #
  # LEDGER_EXPORT_SHOW caps the printed list for a terminal; it defaults to ALL, and whatever it
  # withholds is stated in the same breath.
  # (fix_the_cutover_readiness_export_shows_eight_of_fifty_three_differences)
  if [[ "$differ" -gt 0 ]]; then
    local _cap="${LEDGER_EXPORT_SHOW:-0}" _shown="$differ"
    [[ "$_cap" -gt 0 && "$_cap" -lt "$differ" ]] && _shown="$_cap"
    printf '%s\n' "$_differ_list" | head -n "$_shown"
    [[ "$_shown" -lt "$differ" ]] && printf '  … and %d more not shown (LEDGER_EXPORT_SHOW=%s; set 0 for all)\n' \
      "$((differ - _shown))" "$_cap"
  fi

  # ⚠ NAME THE REF COMPARED AGAINST. A count is honest about the wrong corpus; the ref is what makes
  # a wrong-corpus run visible on sight. (Ed's, and this is the second tool it applies to.)
  # ⚠ "have no file" is a REFUSAL under --write, not a silent skip. Named so the count cannot be
  # read as "and they were created".
  # ⚠ THE EXCLUSIONS ARE COUNTED **BEFORE** THE HEADLINE, BECAUSE THE HEADLINE HAS TO CARRY THEM.
  # They used to be counted after it and printed underneath as caveats. Nothing there was wrong or
  # hidden — the tool states its own exclusion, unprompted, and names the script that measures it.
  # The defect was ORDER and SHAPE: "215 agree, 18 differ" is a verdict sentence and it came first,
  # so a reader carried away a whole-corpus clearance from a NINTH of the corpus. This is the tool
  # CUTOVER.md consults before step 7 DELETES ~2,466 ticket files.
  # (infra_the_readiness_export_compares_a_ninth_of_the_corpus_and_its_headline_reads_as_a_verdict)
  local _excluded _held
  # ⚠ ARCHIVED ROWS ARE IN THE CORPUS NOW, SO NOTHING IS EXCLUDED ON THAT GROUND AND THIS IS 0.
  # Leaving the old `count(*) where status='archived'` here would double-count them -- once inside
  # `n`, once in `_tot` -- and understate coverage by exactly the population this change added. The
  # variable is kept rather than deleted because the announcement machinery below is the part that
  # makes an exclusion visible, and a future exclusion should reuse it rather than reinvent it.
  _excluded=0
  _held="$(docker exec "$CONTAINER" psql -U ledger_owner -d ledger -tAc \
    "select count(*) from ledger.ticket t where t.status in ('draft','reviewed')$_id_filter" 2>/dev/null | tr -d '[:space:]')"

  # ⚠ THE DENOMINATOR IS IN THE SENTENCE, NOT UNDER IT — the shape #7894 shipped for the PO brief.
  # ⚠ AND "COULD NOT COUNT" GETS ITS OWN SENTENCE RATHER THAN A GUESSED TOTAL. A tri-state, because
  # an unreadable count is UNKNOWN coverage, never complete coverage — and a headline that invented
  # a denominator from a failed query would be the false clearance again, one layer down.
  local _coverage _unanswerable=""
  if [[ "${_excluded:-}" =~ ^[0-9]+$ && "${_held:-}" =~ ^[0-9]+$ ]]; then
    local _tot=$(( n + _excluded + _held ))
    _coverage="$(printf 'compared %d of %d rows (%d%%)' "$n" "$_tot" "$(( n * 100 / (_tot == 0 ? 1 : _tot) ))")"
    # ⚠ NEGATIVE CONTROL, AND IT IS A REQUIREMENT NOT A NICETY: when nothing is excluded this must
    # NOT manufacture a caveat. A tool that says "this may be incomplete" on every run has replaced
    # a false verdict with noise, and the reader stops reading the clause that matters.
    # ⚠ ONLY THE NON-ZERO COMPONENTS ARE NAMED. "2366 archived, 0 draft/reviewed" puts a zero in a
    # sentence about what could not be answered, and a zero there reads as noise the eye learns to
    # skip — which is the habit this whole change exists to break.
    if (( _excluded > 0 || _held > 0 )); then
      local _parts=""
      (( _excluded > 0 )) && _parts="$_excluded archived"
      (( _held > 0 )) && _parts="${_parts:+$_parts, }$_held draft/reviewed"
      _unanswerable="$(printf '; the other %d row(s) (%s) CANNOT BE ANSWERED by this tool' \
        "$(( _excluded + _held ))" "$_parts")"
    fi
  else
    _coverage="$(printf 'compared %d rows of an UNKNOWN total' "$n")"
    _unanswerable="; ⚠ the excluded population COULD NOT BE COUNTED — this run's coverage is UNKNOWN, not complete"
  fi

  # ⚠ THE DECLINED-FIELD COUNT RIDES IN THE HEADLINE, for the same reason the exclusions do: a
  # ticket counted as "agree" on seven fields while the eighth was never compared is not the same
  # claim as agreement, and a reader carrying away "2679 agree" needs to know which of those had a
  # field the database declined to own. Silence here would restore exactly the false clearance the
  # exclusion block above exists to remove.
  local _declined_note=""
  (( _declined > 0 )) && _declined_note="$(printf '; %d had a field the database declines to own (not compared — `--write` drops nulls, so it would not touch them)' "$_declined")"
  printf 'ledger-db export: %s vs %s — %d agree, %d differ, %d have no file (never created)%s%s%s\n' \
    "$_coverage" "${base:-the working tree}" "$same" "$differ" "$absent" "$_declined_note" "$_unanswerable" \
    "$([[ "$write" == 1 ]] && echo ' (WRITTEN)' || echo ' (dry run)')"

  # ⚠ SAY WHAT THE CORPUS EXCLUDED, IN THE SAME BREATH AS THE RESULT. This function's query ends
  # `where t.status <> 'archived'`, and CUTOVER.md designates this function as the readiness check
  # for deleting EVERY ticket file. Measured 2026-08-30: 224 examined against 2,368 files on
  # origin/main — **it has never compared 90.5% of the corpus it is read as clearing.** A clean run
  # said "0 differ" and was taken as evidence about 2,368 files. That is not a shorter answer to
  # step 6's question; it is a different question, and the count alone cannot show it.
  #
  # ⚠ AND DO NOT "FIX" THIS BY DROPPING THE FILTER — the remedy is destructive in that order. The
  # patch above merges `$json` into the file, and `$json` carries `'status', t.status`, which for an
  # archived ticket is the literal "archived" (ledger-db.sh:208/:266 overwrite the real terminal
  # status before storage). Widening the corpus while that is true writes "status": "archived" over
  # "status": "passing" in 2,149 real files. **This filter is currently the only thing protecting
  # them.** Preserve the terminal status first; then the corpus can widen.
  # (infra_archiving_a_ticket_destroys_its_terminal_status_and_nothing_detects_it)
  # (counted above, with the headline that now carries it)

  # ⚠ THE DRAFT/REVIEWED EXCLUSION IS STATED IN THE SAME BREATH AS THE RESULT, FOR THE SAME REASON
  # THE ARCHIVED ONE IS. These two are excluded by the query above deliberately -- a draft is the
  # owner's, database-only, and must never acquire a git file -- but "excluded on purpose" and
  # "compared and agreed" are different answers, and a bare `0 differ` cannot tell them apart.
  # ⚠ AND IT IS PRINTED EVEN WHEN THE COUNT IS ZERO IS *NOT* THE RULE HERE: a zero is genuinely
  # nothing withheld, and a line saying so on every run would train the reader to skip the block
  # that matters. It prints when it has something to declare, exactly like the archived arm.
  # (feat_the_ledger_ticket_has_a_draft_and_reviewed_status)
  if [[ "${_held:-0}" =~ ^[0-9]+$ ]] && (( _held > 0 )); then
    printf '  ⚠ EXCLUDED %d draft/reviewed ticket(s) — the owner'"'"'s, database-only, and never exported.\n' "$_held"
    printf '     They have no git file BY DESIGN, so exporting them would make every one an `absent`\n'
    printf '     refusal and CUTOVER step 6 would count each as divergence. This is a deliberate\n'
    printf '     narrowing of the corpus, not a clean comparison of it. (migration 34)\n'
  elif [[ ! "${_held:-}" =~ ^[0-9]+$ ]]; then
    # ⚠ SAME TRI-STATE AS THE ARCHIVED ARM: "could not count" is not "nothing excluded".
    printf '  ⚠ could not count the draft/reviewed rows this query excluded — this run'"'"'s coverage is UNKNOWN, not complete.\n'
  fi
  if [[ "${_excluded:-0}" =~ ^[0-9]+$ ]] && (( _excluded > 0 )); then
    # ⚠ THE FRACTION MOVED TO THE HEADLINE. Restating it here would put the same number in two
    # places, and the copy a reader trusts is the one they reach first. This block keeps the half
    # the headline cannot carry: WHY these rows are unanswerable and what to run to see them.
    printf '  ⚠ EXCLUDED %d archived ticket(s) — counted in the headline above.\n' "$_excluded"
    printf '     This is NOT a verdict on the archived tickets, and CUTOVER step 7 deletes their files.\n'
    printf '     Their terminal status is not reproducible from the database at all:\n'
    printf '       bash scripts/check-ledger-preserves-archived-terminal-status.sh\n'
  elif [[ ! "${_excluded:-}" =~ ^[0-9]+$ ]]; then
    # ⚠ "COULD NOT COUNT" IS NOT "NOTHING EXCLUDED". Silence here would restore exactly the false
    # clearance this block exists to remove.
    printf '  ⚠ could not count the archived rows this query excluded — the coverage of this run is UNKNOWN, not complete.\n'
  fi
  [[ "$write" == 1 ]] || echo "  Git is authoritative until phase 4 — nothing was written. Use --write only at cutover."
  [[ "$differ" -eq 0 && "$absent" -eq 0 ]]
}

# ── attach THIS stack's api to the ledger's network, best-effort ─────────────────────────────────
# ⚠ THIS EXISTS BECAUSE DECLARING THE NETWORK IN docker-compose.yml MADE THE LEDGER A HARD
# DEPENDENCY OF EVERY DEV STACK. Driven: with the network absent, `docker compose up` fails with
# "network declared as external, but could not be found" — so a shared service being down would
# have stopped every agent starting a private one. That is the coupling the shared data tier was
# retired for in June, reintroduced by me, and caught by testing the absent case rather than the
# present one.
#
# ⚠ BEST-EFFORT ON PURPOSE. If the ledger is not running this prints why and returns 0: the stack
# is already up and working, and the screens report "not configured", which is the honest degraded
# state. A convenience that can fail your whole environment is not a convenience.
attach() {
  # ⚠ SCOPE TO **THIS WORKTREE'S** COMPOSE PROJECT. The first version matched `api` across the whole
  # box and took the first hit — which on this machine was **the CI runner's** api container, out of
  # NINE running. On a box with four agent stacks plus two CI seats, "the api container" is
  # ambiguous, and picking arbitrarily means acting on somebody else's stack.
  # COMPOSE_PROJECT_NAME is written to .agent/env by init.sh and is the only unambiguous handle.
  local proj api
  proj="$(grep -oP '^COMPOSE_PROJECT_NAME=\K.*' .agent/env 2>/dev/null || true)"
  if [[ -z "$proj" ]]; then
    echo "ledger-db attach: no COMPOSE_PROJECT_NAME in .agent/env — run scripts/init.sh first." >&2
    echo "  Refusing to guess which of $(docker ps --format '{{.Names}}' | grep -c api) api containers is yours." >&2
    return 0
  fi
  api="$(docker ps --filter "label=com.docker.compose.project=$proj" --filter "label=com.docker.compose.service=api" --format '{{.Names}}' | head -1)"
  if [[ -z "$api" ]]; then
    echo "ledger-db attach: no api container running — bring your stack up first (scripts/init.sh)." >&2
    return 0
  fi
  if ! docker network inspect ${LEDGER_NETWORK} >/dev/null 2>&1; then
    echo "ledger-db attach: the ledger network does not exist — is the ledger running?" >&2
    echo "  docker compose -f $LEDGER_DEPLOY_DIR/docker-compose.yml up -d" >&2
    echo "  (your stack is unaffected; the Ledger screens will report 'not configured')" >&2
    return 0
  fi
  # ⚠ CAPTURE FIRST, NEVER `| grep -q`. Under `set -o pipefail` grep exits on the first match and the
  # producer takes SIGPIPE, so the pipeline reports FAILURE — an already-attached container would
  # read as NOT attached and this would try to connect it again. Caught by
  # check-pipefail-grep-q.sh on the rebased branch, hours after I fixed four of these in the corpus
  # check. Knowing the rule did not stop me writing a fifth.
  local _nets; _nets="$(docker inspect "$api" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null)"
  if grep -q ${LEDGER_NETWORK} <<<"$_nets"; then
    echo "ledger-db attach: $api is already on the ledger network"
    return 0
  fi
  # ⚠⚠ CONNECTING REPUBLISHES THIS CONTAINER'S HOST PORTS. NO RESTART, NO SIGNAL, NO WARNING.
  # Measured 2026-08-27 on two stacks in both directions: only the container the operation TOUCHES
  # moves, and it moves on connect AND on disconnect. One stack went 36103 (init.sh) -> 36774
  # (attach) -> 36790 (disconnect), RestartCount 0 throughout, StartedAt unchanged.
  #
  # ⚠ THIS IS WHY THE init.sh WIRING WAS REVERTED: attaching after the readiness probe moved the api
  # port out from under `.agent/env`, and every HOST-PORT consumer downstream (Playwright, e2e,
  # probes) then talked to a dead port — 133 auth-shaped failures, pages sitting at /login.
  #
  # ⚠ CONTAINER-TO-CONTAINER TRAFFIC IS UNAFFECTED, and that is the trap: the admin console reaches
  # the api by SERVICE NAME over the shared network, so `/api/health` through the proxy still returns
  # 200 while every host-port client is broken. A probe through the proxy is STRUCTURALLY INCAPABLE
  # of detecting this — it is not a weak check, it is one that cannot fail.
  #
  # So: capture the port either side, and REPAIR `.agent/env` rather than leaving a stale coordinate.
  # The repo's standing note says "ANY RESTART reassigns ports"; that is too narrow — any change to a
  # running container's network membership does it, with no restart at all.
  local _before _after
  _before="$(docker port "$api" 8080 2>/dev/null | head -1 | sed 's/.*://')"
  docker network connect ${LEDGER_NETWORK} "$api" 2>&1 || return 0
  echo "ledger-db attach: $api -> ${LEDGER_NETWORK}"
  _after="$(docker port "$api" 8080 2>/dev/null | head -1 | sed 's/.*://')"
  if [[ -n "$_before" && -n "$_after" && "$_before" != "$_after" ]]; then
    echo "ledger-db attach: ⚠ the api HOST PORT moved ${_before} -> ${_after} (no restart — this is what connecting does)"
    if [[ -f .agent/env ]] && grep -q '^API_URL=' .agent/env 2>/dev/null; then
      sed -i "s#^API_URL=.*#API_URL=http://localhost:${_after}#" .agent/env
      echo "ledger-db attach: repaired .agent/env API_URL -> http://localhost:${_after}"
    else
      echo "ledger-db attach: ⚠ no .agent/env API_URL to repair — anything holding ${_before} is now pointing at nothing" >&2
    fi
  elif [[ -n "$_before" && "$_before" == "$_after" ]]; then
    echo "ledger-db attach: host port unchanged (${_after})"
  fi
}

# ── HOW STALE IS THE BOARD ───────────────────────────────────────────────────────────────────────
# (infra_nothing_schedules_the_ledger_sync_so_the_board_is_as_fresh_as_the_last_hand_run, part 1)
#
# ⚠ THE MEASUREMENT IS IN THE DATABASE (migration 31, `ledger.v_board_freshness`); THE POLICY IS
# HERE. A threshold differs between a five-minute poll and an eight-hour shift, and burying one in a
# view means every caller inherits it invisibly and none of them can see it.
#
# ⚠ TWO INDEPENDENT MEASURES, AND EITHER CAN BE UNAVAILABLE WITHOUT THE OTHER. A board synced thirty
# seconds ago against a sha that no longer resolves is FRESH in time and UNKNOWN in commits. Folding
# them into one word would have to pick which unavailability to hide.

# freshness_verdict <never_synced: 0|1> <age_seconds> <threshold_seconds>  ->  never | fresh | stale
# ⚠ `never` IS ITS OWN ANSWER AND IS NOT `stale`. A board that has never been synced and a board
# synced eight hours ago need different actions — one is "run a sync", the other is "why did the
# thing that runs syncs stop" — and collapsing them loses exactly that.
freshness_verdict() {
  local never="${1-}" age="${2-}" threshold="${3-}"
  [[ "$never" == 1 ]] && { printf 'never'; return 0; }
  # ⚠ A NON-NUMERIC AGE IS NOT ZERO. Empty, or a psql error string, must not arithmetic-compare its
  # way to `fresh` — which is exactly what `(( age < threshold ))` does with an unset variable.
  [[ "$age" =~ ^-?[0-9]+$ && "$threshold" =~ ^[0-9]+$ ]] || { printf 'never'; return 0; }
  (( age < threshold )) && { printf 'fresh'; return 0; }
  printf 'stale'
}

# view_note <view: fetched|stale|unknown>  ->  the clause describing HOW FRESH the git view was
# ⚠⚠ THE SIBLING OF THE TRAP BELOW, AND I SHIPPED IT — the controls I wrote covered the verdict
# functions and not the CALLER THAT FEEDS THEM. `freshness_report` compared against `origin/main`
# with no fetch, so `git rev-list --count <sha>..origin/main` was computed against whatever the local
# tracking ref happened to hold. **A stale checkout UNDER-reports how far behind the board is** —
# the reassuring direction, which is the exact class this file's other two controls exist for.
#
# ⚠ THE FETCH IS NECESSARY AND NOT SUFFICIENT, which is why this function exists rather than a bare
# `git fetch` on the line above. A fetch can fail — offline, a dead remote, a credential problem —
# and the gate must not go red for that: it fails OPEN, reporting fewer commits behind than reality,
# never more. **So the three states must be DISTINGUISHABLE IN THE OUTPUT.** A reading that failed
# open silently and one that succeeded look identical otherwise, and only the second deserves to be
# believed. (The pattern is Saffron's, from the migration-uniqueness gate; the defect it found was
# mine.)
view_note() {
  case "${1-}" in
    fetched) printf 'fetched just now' ;;
    stale)   printf '⚠ STALE local view — fetch FAILED or timed out; this can UNDER-report how far behind, never over-report' ;;
    # ⚠ AN UNRECOGNISED STATE MUST NOT RENDER AS THE FRESH ONE. A missing third state silently
    # claiming `fetched just now` is how a caveat stops being a caveat. Same reasoning as
    # `applier_note`'s unknown-provenance arm in ledger-migrate.sh (#7192).
    *)       printf '⚠ view freshness UNRECORDED — this is a defect, see view_note' ;;
  esac
}

# behind_verdict <sha_resolves: yes|no> <commits_behind>  ->  unresolvable | current | behind
# ⚠⚠ THIS FUNCTION EXISTS FOR ONE CASE, AND IT IS THE PLAUSIBLE-WRONG-ANSWER TRAP. This repo merges
# by REBASE, which rewrites commits, so a sha recorded by a sync an hour ago may name nothing on
# main today — the same reason `last_verified_commit` is invalid on main by construction, and the
# same reason the `--since-last` marker falls back to a full sync when its sha will not resolve.
# `git rev-list --count <gone>..origin/main` does not return a large number; it FAILS, and a caller
# that reads its empty output as a count reports **0 commits behind**, which is indistinguishable
# from a board that is perfectly current. **The reassuring direction, from an instrument that could
# not see.** So resolvability is an INPUT here, never inferred from the count.
behind_verdict() {
  local resolves="${1-}" n="${2-}"
  [[ "$resolves" == yes ]] || { printf 'unresolvable'; return 0; }
  [[ "$n" =~ ^[0-9]+$ ]] || { printf 'unresolvable'; return 0; }
  (( n == 0 )) && { printf 'current'; return 0; }
  printf 'behind'
}

# freshness_report [--quiet]
# ⚠ ONE LINE, AND IT NAMES THE MEASUREMENT RATHER THAN ONLY THE VERDICT. "the board is stale" sends
# a reader to look for a broken sync; "stale — last synced 47m ago by ledger_owner, 12 commits
# behind main" tells them which of those it is before they start.
# `--quiet` prints nothing when the verdict is `fresh`, for callers that want to warn and not chat.
freshness_report() {
  local quiet=0; [[ "${1:-}" == --quiet ]] && quiet=1
  local threshold="${LEDGER_STALE_AFTER_SECONDS:-900}"
  _up || { echo "ledger-db freshness: the ledger is not running" >&2; return 1; }

  # ⚠ ONE QUERY, TAB-SEPARATED, READ WITH `read -r`. Five separate psql calls would each pay the
  # docker exec round trip AND could straddle a sync, reporting an age from before one and a sha
  # from after it.
  local row never age actor sha nseen nmirr nref
  row="$(_as_me "select never_synced::int, coalesce(age_seconds::text,''), coalesce(last_main_sync_by,''),
                        coalesce(last_main_sync_sha,''), coalesce(n_seen::text,''),
                        coalesce(n_mirrored::text,''), coalesce(n_refused::text,'')
                 from ledger.v_board_freshness" 2>/dev/null)" || row=""
  IFS='|' read -r never age actor sha nseen nmirr nref <<<"$row"

  # ⚠ A FAILED READ IS NOT A FRESH BOARD. An empty row leaves `never` empty, which is not `1`, and
  # the verdict function's numeric guard then returns `never` rather than arithmetic-comparing an
  # empty age to the threshold and answering `fresh`. Said out loud because the failure that would
  # matter here is silence that reads as health.
  if [[ -z "$row" ]]; then
    echo "ledger: ⚠ CANNOT READ the board's freshness — this is not evidence the board is fresh" >&2
    return 1
  fi

  local verdict; verdict="$(freshness_verdict "${never:-1}" "${age:-}" "$threshold")"

  # ── how far behind main, which is a SEPARATE measure and separately unavailable ────────────────
  # ⚠ RESOLVABILITY IS ESTABLISHED HERE AND PASSED IN. `git rev-list --count <gone>..origin/main`
  # FAILS on a rewritten sha — it does not return a big number — and reading its empty output as a
  # count would report "0 commits behind", i.e. perfectly current. We merge by rebase, so a sha from
  # an hour ago genuinely may not resolve. See behind_verdict's header.
  # ⚠ FETCH FIRST, AND RECORD WHETHER IT WORKED. Without this the comparison ran against whatever
  # the local tracking ref happened to hold — see view_note's header. Bounded, because a hung remote
  # must not hang a status command: this is an observability surface and a slow answer is worse than
  # a caveated one.
  # ⚠ AN EXPLICIT REFSPEC, NOT `git fetch origin main`. The bare form updates `refs/remotes/origin/main`
  # only *opportunistically*, and this line exists precisely to guarantee that ref moved — a fetch
  # that reports success while leaving the ref untouched would restore the defect wearing a fix.
  local view=stale
  if timeout 20 git fetch -q origin '+refs/heads/main:refs/remotes/origin/main' 2>/dev/null; then view=fetched; fi

  local resolves=no behind='' bverdict
  if [[ -n "$sha" ]] && git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    behind="$(git rev-list --count "${sha}..origin/main" 2>/dev/null || true)"
    [[ "$behind" =~ ^[0-9]+$ ]] && resolves=yes
  fi
  bverdict="$(behind_verdict "$resolves" "$behind")"

  (( quiet )) && [[ "$verdict" == fresh ]] && return 0

  local age_h='—'
  [[ "$age" =~ ^[0-9]+$ ]] && age_h="$(( age / 60 ))m$(( age % 60 ))s"
  local behind_h
  case "$bverdict" in
    current)      behind_h='level with main' ;;
    behind)       behind_h="${behind} commit(s) behind main" ;;
    # ⚠ SAY UNMEASURABLE, NEVER "0". A sha that no longer resolves is a population this instrument
    # structurally cannot read, and "0" would close a question that is in fact open.
    unresolvable) behind_h='commits behind: UNMEASURABLE (the recorded sha no longer resolves — rebase rewrites it)' ;;
  esac
  # ⚠ THE COMMITS-BEHIND FIGURE CARRIES ITS OWN PROVENANCE, AND ONLY THAT FIGURE. The AGE comes from
  # the database and is unaffected by the git view, so tacking the caveat onto the whole line would
  # cast doubt on a number that is not in doubt. It is appended to `behind_h` for that reason.
  # ⚠ NOT APPENDED WHEN THE COUNT IS ALREADY UNMEASURABLE: "UNMEASURABLE (…) (fetched just now)"
  # reads as though the freshness rescued something. It did not — an unresolvable sha stays
  # unresolvable however current the view is.
  [[ "$bverdict" != unresolvable ]] && behind_h="${behind_h} [$(view_note "$view")]"

  case "$verdict" in
    never) printf 'ledger: ⚠ this board has NEVER been synced from origin/main — nothing here reflects git\n' ;;
    fresh) printf 'ledger: board fresh — synced %s ago by %s, %s (%s mirrored, %s refused)\n' \
             "$age_h" "${actor:-?}" "$behind_h" "${nmirr:-?}" "${nref:-?}" ;;
    stale) printf 'ledger: ⚠ board STALE — last synced %s ago by %s (threshold %ss), %s\n' \
             "$age_h" "${actor:-?}" "$threshold" "$behind_h" ;;
  esac
  # ⚠ `never` EXITS NON-ZERO TOO, AND THE FIRST DRAFT GOT THIS WRONG — caught by running it rather
  # than by reading it. A never-synced board is the WORST state, not a neutral one, and returning 0
  # for it meant any caller gating on the exit code read "nothing here reflects git" as healthy.
  # The word was right and the exit code contradicted it; the exit code is what a script reads.
  [[ "$verdict" == fresh ]] || return 2
  return 0
}

# ── self-test ───────────────────────────────────────────────────────────────────────────────────
# ⚠ EVERY CASE HERE IS ONE I DROVE AGAINST THE OLD CODE FIRST, so each is a control rather than a
# restatement. Old behaviour, for the record: all-ok gave $'0\n0' for `bad`; none-ok gave $'0\n0'
# for `ok`; one-refusal was fine — which is exactly why nobody saw it.
_ldb_self_test() {
  # ⚠ THE FILE UNDER TEST, RESOLVED FROM ITS OWN PATH — the assertions below read the dispatch
  # arms, so they must read THIS file rather than whatever is in the working directory.
  local SELF="${BASH_SOURCE[0]}"
  local fails=0 d; d="$(mktemp -d)"; trap 'rm -rf "$d"' RETURN
  _eq() { # <label> <expected> <got>
    if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fails=1; fi
  }
  printf 'a|ok\nb|ok\n'            > "$d/all_ok"
  printf 'a|ok\nb|refused:23514\n' > "$d/one_bad"
  printf 'a|refused\nb|refused\n'  > "$d/none_ok"
  : > "$d/empty"

  # THE CASE THAT BROKE IT: every row mirrored. `bad` must be a single 0, not two lines.
  _eq 'every row mirrored counts 2 ok / 0 refused' '2 0' "$(_count_ok_bad "$d/all_ok")"
  # ── the sync decides on its store before it reads (infra_the_ledger_sync_janitor_decides_on_its_store_before_it_reads) ──
  _eq 'files present -> the sync mirrors'                       'mirror'  "$(_sync_store_verdict present)"
  _eq 'files RETIRED (marker in the tree) -> a decision, not an error' 'retired' "$(_sync_store_verdict retired)"
  _eq 'files MISSING (no marker) -> the broken read, refused'     'broken'  "$(_sync_store_verdict missing)"
  _eq 'an unknown state is never mirrored'                        'broken'  "$(_sync_store_verdict '')"
  # ⚠ THE ANOMALY IS ITS OWN VERDICT, NOT `broken`. Both refuse, so the mirror's BEHAVIOUR is the
  # same — the cell exists because the two print different causes, and `broken`'s sentence ("features/
  # is absent and the marker is not in the tree") is false in both halves on an anomalous tree.
  _eq 'marker AND files -> its own verdict, so the refusal can name the real cause' 'anomaly' "$(_sync_store_verdict anomaly)"
  # the arm on a real tree, both states, through the shared predicate on a throwaway repo
  ( set -e; cd "$d" && git init -q st && cd st && git config user.email t@t && git config user.name t
    mkdir -p features infra/ledger-db && printf '{"id":"t1"}\n' > features/t1.json && git add -A && git commit -qm P
    git rm -rq features && printf 'parent: P\n' > infra/ledger-db/TICKET-FILES-RETIRED.md && git add -A && git commit -qm D ) >/dev/null 2>&1
  local _tf; _tf="$(cd -- "$(dirname -- "$SELF")" && pwd)/lib/ticket-files.sh"   # absolute: the cells cd away
  _eq 'the predicate reads the PARENT as present (the ref, not the checkout)' 'mirror' \
      "$(cd "$d/st" && . "$_tf" && _sync_store_verdict "$(ticket_files_state --ref HEAD~1)")"
  _eq 'the predicate reads the DELETION as retired'                          'retired' \
      "$(cd "$d/st" && . "$_tf" && _sync_store_verdict "$(ticket_files_state --ref HEAD)")"
  # …and a THIRD commit putting one ticket file back while the marker stays — the shape that reached
  # main during the cutover — must reach the anomaly refusal rather than mirroring a stray directory.
  ( set -e; cd "$d/st" && mkdir -p features && printf '{"id":"stray"}\n' > features/stray.json \
    && git add -A && git commit -qm S ) >/dev/null 2>&1
  _eq 'one file back WITH the marker still in -> anomaly, never mirror' 'anomaly' \
      "$(cd "$d/st" && . "$_tf" && _sync_store_verdict "$(ticket_files_state --ref HEAD)")"
  _eq 'POSITIVE CONTROL: the commit before it still reads retired' 'retired' \
      "$(cd "$d/st" && . "$_tf" && _sync_store_verdict "$(ticket_files_state --ref HEAD~1)")"
  # ── archiving clears the park columns (fix_the_sync_forces_archived_without_clearing_the_park_columns) ──
  # ⚠ THE ARM THIS EXISTS FOR: an archived row carrying a park column is REFUSED by the database
  # (park_columns_are_clear_when_not_parked). Driven live, rolled back: archived+parked_by errors,
  # archived without it is accepted.
  _eq 'archiving sets the status'  'archived' \
      "$(_archived_payload '{"id":"t","status":"passing"}' | jq -r .status)"
  _eq 'archiving drops parked_by'  'null' \
      "$(_archived_payload '{"id":"t","status":"passing","parked_by":"Saffron"}' | jq -r '.parked_by // "null"')"
  _eq 'archiving drops every park column' '0' \
      "$(_archived_payload '{"id":"t","parked_by":"S","parked_at":"x","parked_reason":"r","park_kind":"banked","park_summary":"a"}' \
         | jq '[.parked_by,.parked_at,.parked_reason,.park_kind,.park_summary] | map(select(. != null)) | length')"
  # ⚠⚠ THE EMPTY STRING, WHICH IS THE ONE A `= null` FIX WOULD MISS. The payload builder uses
  # `(.parked_by // null)` and jq's `//` falls through only on null/false, so "" survives to the
  # column and violates the CHECK. `del` cannot express a falsy-but-present value at all.
  _eq 'an EMPTY-STRING park column is removed, not passed through' 'true' \
      "$(_archived_payload '{"id":"t","parked_by":""}' | jq 'has("parked_by") | not')"
  # ⚠ AND IT MUST NOT INVENT KEYS. A payload with no park columns comes back with none.
  _eq 'no park columns in, none out' 'true' \
      "$(_archived_payload '{"id":"t","status":"passing"}' | jq '[has("parked_by"),has("park_kind")] | any | not')"
  _eq 'unrelated fields survive' 'keepme' \
      "$(_archived_payload '{"id":"t","title":"keepme","parked_by":"S"}' | jq -r .title)"
  # ── which role do we connect as? (infra_the_unattended_flag_never_reaches_the_bulk_sync_path) ──
  # ⚠ THE ARM THIS EXISTS FOR. The bulk sync used to ignore the override entirely, so the systemd
  # timer connected as the working DIRECTORY's label — a name that is not a Postgres role.
  _eq 'the override wins over any resolved name'  'ledger_sync' "$(_conn_role_pick ledger_sync Saffron)"
  _eq 'no override falls back to the resolved name' 'Saffron'    "$(_conn_role_pick '' Saffron)"
  # ⚠ IT MUST REFUSE, NOT GUESS. An empty pick would become `psql -U ''`, which connects as the OS
  # user and mirrors under an identity nobody chose — the misattribution the flag exists to remove.
  _eq 'neither available refuses (rc 3, empty)'    ''            "$(_conn_role_pick '' '' || true)"
  ( _conn_role_pick '' '' >/dev/null 2>&1 ); _eq 'refusal is rc 3' '3' "$?"
  # ⚠ WHITESPACE IS NOT A NAME. `LEDGER_ACTOR_ROLE=" "` from a mis-edited unit file must refuse
  # rather than become `psql -U ' '`. Same shape as the empty-string hole in the park payload.
  _eq 'a whitespace override is not a role'        'Saffron'     "$(_conn_role_pick '   ' Saffron)"
  ( _conn_role_pick '  ' '' >/dev/null 2>&1 ); _eq 'whitespace both sides refuses' '3' "$?"
  # ⚠ THE NEGATIVE CONTROL, AND THE ONE THAT MATTERS: the refusal signal must SURVIVE the fix. A
  # change that made this report 0 refused would have removed the signal rather than the bug.
  _eq 'one refusal is still reported'             '1 1' "$(_count_ok_bad "$d/one_bad")"
  # THE LATENT SIBLING on the success counter — fires only when nothing mirrors.
  _eq 'nothing mirrored counts 0 ok / 2 refused'  '0 2' "$(_count_ok_bad "$d/none_ok")"
  _eq 'empty output counts 0 / 0'                 '0 0' "$(_count_ok_bad "$d/empty")"

  # ⚠⚠ THESE TWO WERE VACUOUS IN MY FIRST DRAFT AND THE CONTROL CAUGHT IT — worth keeping the
  # reason. I asserted on values taken through `read -r o b < <(_count_ok_bad …)`, and `read` stops
  # at the FIRST NEWLINE: fed the broken $'2 0\n0' it yields a clean o=2 b=0, so both assertions
  # passed against the very bug they existed to catch. **A test that launders its input through a
  # line-oriented reader cannot see a multi-line defect.** Assert on the RAW output instead.
  local raw lines
  raw="$(_count_ok_bad "$d/all_ok")"
  lines="$(printf '%s' "$raw" | wc -l)"
  _eq 'output is ONE line, not two' '0' "$lines"
  # ⚠ THIS ONE IS DELIBERATELY LABELLED FOR WHAT IT CAN ACTUALLY DO. Unquoted `$raw` word-splits on
  # the newline too, so `printf '%d %d'` consumes 2 0 0 without complaint — it does NOT catch the
  # two-line defect, and calling it "printf-safe" would have overstated it. That is the line-count
  # assertion's job. This one catches a NON-NUMERIC counter, which is a different regression.
  if printf '%d %d' $raw >/dev/null 2>&1; then printf '  ok   counters are numeric (NOT a two-line check)\n'
  else printf '  FAIL a counter is not numeric\n'; fails=1; fi

  # ⚠ THE PARK COLUMNS OF THE BRANCH IMPORT MUST NEVER READ AN EMPTY BRANCH REASON AS A DELETE.
  # This is a SHAPE assertion, deliberately, and the reason is worth stating: the behavioural
  # controls for that fix need a live Postgres, and this self-test runs in the `verify` tier where
  # there is none. A control that cannot run where it is cheap is not a control -- so the durable
  # one asserts the guard is textually present, which is exactly what a re-introduction would
  # remove. It cannot prove the semantics; it can prove the guard did not silently vanish, which is
  # how this defect arrived.
  # (fix_refs_scan_writes_an_empty_branch_reason_over_the_real_park_on_main)
  #
  # ⚠ THIS FILE IS NO LONGER ONE OF THE SUBJECTS, AND THE REMOVAL IS DELIBERATE RATHER THAN A TIDY-UP.
  # The loop used to read BOTH `scripts/ledger-db.sh` and the historical migration, because
  # `refs_scan` in this file carried a second copy of the same UPDATE. The overlay is retired and
  # that copy is gone, so asserting park guards here would be an assertion about an absent referent
  # -- the needle's positive control below would fail loudly and correctly, for a guard that is
  # legitimately no longer present. A check that can only ever fail is not coverage.
  # `004-import-branch-parks.sql` remains a real subject: it is a HISTORICAL migration that still
  # writes all four columns and runs before the retirement, so a schema rebuild replays it verbatim
  # and it must keep its guards.
  # (infra_retire_the_refs_scan_park_overlay_now_that_parks_are_written_not_recovered)
  local root; root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  local f col body
  # TEMPLATE: the historical migration is NOT in this repo — the schema arrives as one squashed
  # baseline (infra/ledger-db/001-baseline.sql), and the park columns' guards live in ledger.park()
  # there. So this arm has no file subject here; it says so instead of failing, and the baseline's
  # function is checked for the four columns below in its place.
  for f in "$root/infra/ledger-db/004-import-branch-parks.sql"; do
    if [[ ! -r "$f" ]]; then
      if grep -qE 'parked_reason.*parked_at.*parked_by.*blocked_on_owner|FUNCTION ledger\.park\(' "$root/infra/ledger-db/001-baseline.sql" 2>/dev/null; then
        printf '  ok   the historical park migration is not a template file; ledger.park() in 001-baseline.sql writes the four park columns\n'
      else printf '  FAIL neither %s nor a ledger.park() in 001-baseline.sql -- the park guards have no subject\n' "${f##*/}"; fails=1; fi
      continue
    fi
    local cols_for_file expected
    cols_for_file="parked_reason parked_at parked_by blocked_on_owner"; expected=4
    body="$(grep -E "^[[:space:]]*($(printf '%s' "$cols_for_file" | tr ' ' '|'))[[:space:]]*=" "$f")"
    # ⚠ POSITIVE CONTROL ON THE NEEDLE ITSELF: if the grep finds nothing the loop below vacuously
    # passes, and a renamed column or a reformatted statement would read as four green assertions.
    if [[ "$(printf '%s\n' "$body" | grep -c .)" -lt "$expected" ]]; then
      printf '  FAIL %s: found fewer than %d park assignments -- the needle moved, so the guard check below judged nothing\n' "${f##*/}" "$expected"; fails=1; continue
    fi
    for col in $cols_for_file; do
      # ⚠⚠ THE WINDOW WAS THE PROBLEM, AND DRIVING IT HARDER WOULD NOT HAVE FIXED IT. Three goes,
      # each wrong differently; the third is only defensible against the first two, so both stay:
      #   1. The assignment LINE alone -> false RED on `blocked_on_owner`, whose CASE wraps.
      #   2. `grep -A2` -> the window ran into the NEXT column's assignment, and `parked_at`'s own
      #      `ELSE t.parked_at` satisfied `parked_reason`'s pattern. **EVERY COLUMN WAS CERTIFIED BY
      #      ITS NEIGHBOUR'S GUARD** -- four checks agreeing, one blind spot counted four times.
      #      Driven with the guard removed, it still said ok: a false GREEN, which would have
      #      shipped as coverage.
      #   3. This: extract the column's OWN assignment expression -- from `col =` to the comma that
      #      terminates it at paren depth 0 -- and assert the guard inside THAT.
      # ⚠ (3) IS STRUCTURAL WHERE (2) WAS PROXIMITY, AND THAT IS THE WHOLE POINT. `-A2` and `-A3`
      # give different verdicts on the same file and neither number is a fact about the SQL. A
      # neighbour's guard can no longer satisfy this one BY CONSTRUCTION rather than by luck of line
      # count. (Saffron's catch, and it is the five-store lesson one level down: agreement between
      # things that share a blind spot is not corroboration.)
      # ⚠ AND FAILABILITY IS NOT ATTRIBUTION. Proving this check CAN go red says nothing about
      # whether it goes red FOR THIS COLUMN -- go (1) failed loudly on the needle while every guard
      # was present. Each of the four is therefore driven separately, asserting the red NAMES it.
      local expr
      expr="$(awk -v col="$col" '
        BEGIN{ d=0; on=0; buf="" }
        !on && $0 ~ ("^[[:space:]]*" col "[[:space:]]*=") { on=1; sub(/^[^=]*=/,"") }
        on {
          n=split($0,c,"")
          for(i=1;i<=n;i++){
            ch=c[i]
            if(ch=="(") d++
            else if(ch==")") d--
            else if(ch=="," && d==0){ print buf; exit }
            buf=buf ch
          }
          buf=buf " "
        }' "$f")"
      if [[ -z "${expr// }" ]]; then
        printf '  FAIL %s: could not extract the %s assignment -- the statement moved, so nothing was judged\n' "${f##*/}" "$col"; fails=1; continue
      fi
      # ⚠ HERESTRING, NOT A PIPE — and this file's OWN comment 140 lines up says so. Under
      # `set -o pipefail`, `grep -q` exits at the first match while the producer is still writing,
      # so the pipeline can false-fail at any size. I wrote the rule's violation in the same file
      # that carries the rule. (fix_e2e_grep_q_pipeline_false_failures)
      if grep -qE 'COALESCE\(NULLIF\(b\.reason|ELSE[[:space:]]+t\.' <<< "$expr"; then
        printf '  ok   %s: %s keeps main'"'"'s value when the branch reason is empty\n' "${f##*/}" "$col"
      else
        printf '  FAIL %s: %s is UNGUARDED -- an empty branch reason will erase the park on main\n' "${f##*/}" "$col"; fails=1
      fi
    done
  done

  # ── how stale is the board (part 1 of the sync-scheduling ticket) ─────────────────────────────
  # ⚠ THE THRESHOLD IS PASSED IN, NOT READ FROM THE ENVIRONMENT, so these assertions state the
  # policy they are testing instead of inheriting whatever the caller happens to have set.
  _eq 'a board that has never synced says so'   'never' "$(freshness_verdict 1 '' 900)"
  # ⚠ AND `never` IS NOT `stale`: different actions. "run a sync" vs "why did syncing stop".
  _eq 'never is distinct from stale'            'different' \
      "$([[ "$(freshness_verdict 1 '' 900)" == "$(freshness_verdict 0 99999 900)" ]] && echo SAME || echo different)"
  _eq 'a sync inside the window is fresh'       'fresh' "$(freshness_verdict 0 60 900)"
  _eq 'a sync outside the window is stale'      'stale' "$(freshness_verdict 0 901 900)"
  # ⚠ BOUNDARY, BOTH SIDES — an off-by-one here silently widens or narrows the policy for every caller.
  _eq 'the boundary itself is stale'            'stale' "$(freshness_verdict 0 900 900)"
  _eq 'one second inside is fresh'              'fresh' "$(freshness_verdict 0 899 900)"
  # ⚠⚠ THE ONE THAT MATTERS MOST: a psql error, or an empty result, must NOT arithmetic-compare its
  # way to `fresh`. `(( age < threshold ))` with an unset or non-numeric age evaluates to TRUE in
  # bash — so the failure mode of "could not read the freshness" would have been "the board is
  # fresh", which is the reassuring direction from an instrument that could not see.
  _eq 'an empty age is not fresh'               'never' "$(freshness_verdict 0 '' 900)"
  _eq 'a psql error string is not fresh'        'never' "$(freshness_verdict 0 'ERROR:  permission denied' 900)"

  # ⚠⚠ AND THE SIBLING TRAP ON THE COMMIT SIDE, WHICH IS WHY `behind_verdict` TAKES RESOLVABILITY AS
  # AN INPUT RATHER THAN INFERRING IT. We merge by REBASE: a sha recorded an hour ago may name
  # nothing on main today. `git rev-list --count <gone>..origin/main` FAILS rather than returning a
  # large number, and a caller reading its empty output as a count reports **0 commits behind** —
  # indistinguishable from a board that is perfectly current.
  _eq 'an unresolvable sha is not "current"'    'unresolvable' "$(behind_verdict no '')"
  _eq 'an unresolvable sha with a stale 0 is still unresolvable' 'unresolvable' "$(behind_verdict no 0)"
  _eq 'a non-numeric count is unresolvable'     'unresolvable' "$(behind_verdict yes 'fatal: bad revision')"
  _eq 'zero commits behind is current'          'current' "$(behind_verdict yes 0)"
  _eq 'a positive count is behind'              'behind'  "$(behind_verdict yes 12)"
  # ⚠ NEGATIVE CONTROL ON THE WHOLE POINT: `unresolvable` and `current` must never be the same
  # string. If a future edit makes them agree, every assertion above still passes.
  _eq 'unresolvable and current are distinguishable' 'different' \
      "$([[ "$(behind_verdict no 0)" == "$(behind_verdict yes 0)" ]] && echo SAME || echo different)"

  # ── the git VIEW the commits-behind count was computed against (the sibling defect) ────────────
  # ⚠⚠ THE CONTROLS ABOVE COVERED THE VERDICT FUNCTIONS AND NOT THE CALLER THAT FEEDS THEM.
  # `freshness_report` compared against `origin/main` with NO FETCH, so the count was only as fresh
  # as the last fetch by something else — a stale checkout UNDER-reports, the reassuring direction.
  # Shipped by me in the same PR that added two mutation controls for exactly that direction.
  _eq 'a fetched view says so'          'fetched just now' "$(view_note fetched)"
  # ⚠ THE ONE THAT MATTERS: a failed fetch must be VISIBLE, because it fails OPEN. A reading that
  # silently under-reports and one that is trustworthy are otherwise identical on the page.
  # ⚠ CAPTURE FIRST, THEN A HERESTRING — NEVER `| grep -q`. Under `set -o pipefail` grep exits at the
  # first match while the producer is still writing, so the pipeline can false-fail at any size.
  # ⚠ AND I WROTE THE VIOLATION 50 LINES BELOW THE COMMENT THAT STATES THE RULE, in the same file,
  # having quoted that rule at a peer earlier the same day. The ratchet caught it, which is the
  # argument for the gate over the habit: knowing a rule and being protected by it are different
  # things. (fix_e2e_grep_q_pipeline_false_failures)
  _vn_stale="$(view_note stale)"
  _eq 'a stale view warns it can UNDER-report' 'yes' \
      "$(grep -q 'UNDER-report' <<<"$_vn_stale" && echo yes || echo no)"
  # ⚠ AND AN UNRECOGNISED STATE MUST NOT CLAIM FRESHNESS. A missing third state rendering as
  # "fetched just now" is how a caveat quietly stops existing. (applier_note's arm, #7192.)
  _eq 'an unknown view does not claim freshness' '0' "$(view_note '' | grep -c 'fetched just now')"
  # ⚠ NEGATIVE CONTROL ON THE WHOLE POINT: if a future edit makes the two states render the same
  # string, every assertion above still passes. This is the only one that fires.
  _eq 'fetched and stale are distinguishable' 'different' \
      "$([[ "$(view_note fetched)" == "$(view_note stale)" ]] && echo SAME || echo different)"

  # ── the payload literal: prose may contain ANYTHING, including the old delimiter ───────────────
  # (infra_the_mirror_payload_tag_can_appear_in_ticket_prose)
  #
  # ⚠ THE OLD CODE DOLLAR-QUOTED WITH A FIXED TAG AND A COMMENT SAYING IT "CANNOT APPEAR IN TICKET
  # PROSE". Nothing enforced that. These cases are the enforcement.
  #
  # ⚠ THIS FILE MAY CARRY THE DELIMITER SAFELY AND A TICKET FILE MAY NOT — `_emit` reads
  # features/*.json, never scripts/. That asymmetry is why the fix is testable here at all, and why
  # the ticket describing the defect had to spell the delimiter out rather than quote it.
  local _tag='$mrr$'
  _eq 'an apostrophe is doubled, not escaped' "'it''s'" "$(_sql_lit "it's")"
  # ⚠ A BACKSLASH PASSES THROUGH UNTOUCHED, and that is only correct because
  # standard_conforming_strings is on. Asserted so a future change to that setting breaks a test
  # rather than silently corrupting prose.
  _eq 'a backslash is left alone' "'a\b'" "$(_sql_lit 'a\b')"
  _eq 'the old delimiter is just text to the new form' "'x${_tag}y'" "$(_sql_lit "x${_tag}y")"
  # ⚠ THE POSITIVE CONTROL, AND IT IS THE ONLY ASSERTION THAT PROVES THE FIX WAS NEEDED. Without it
  # the three cases above would all pass against code that never had the defect. It builds the
  # statement BOTH ways over the same hostile prose: the old form ends the literal early and leaves
  # the rest of the payload as bare SQL; the new form does not.
  local _hostile="{\"n\":\"has ${_tag} inside\"}"
  local _old; _old="$(printf 'select ledger.mirror_ticket(%s%s%s::jsonb);' "$_tag" "$_hostile" "$_tag")"
  # ⚠ `grep -oF`, NOT `grep -o`. The tag ENDS in a dollar, which BRE reads as an end-of-line anchor,
  # so the pattern matched something other than the tag and the control reported `intact` — a
  # positive control that could not detect the very breakage it exists to prove.
  _eq 'the OLD form is broken by prose carrying the tag' 'broken' \
      "$([[ "$(grep -oF "$_tag" <<<"$_old" | wc -l)" -gt 2 ]] && echo broken || echo intact)"
  _eq 'the NEW form survives the same prose' 'intact' \
      "$([[ "$(_sql_lit "$_hostile")" == "'$_hostile'" ]] && echo intact || echo broken)"

  # ── the SINGLE-TICKET verb, driven — not the escaper it calls ─────────────────────────────────
  # (fix_mirror_builds_a_bare_dollar_quote_so_a_ticket_containing_one_can_never_be_released)
  #
  # ⚠⚠ EVERY ASSERTION ABOVE PASSED THROUGHOUT THE LIFE OF THE DEFECT THIS ONE CATCHES. They drive
  # `_sql_lit`; `mirror()` did not call it, and built a bare $$...$$ quote one function away. A test
  # of the helper is not a test of the caller — so this drives `mirror()` and asserts on the SQL it
  # would actually send, with `_as_me` and `_up` stubbed so no database is required.
  local _dq='$$'          # the shell PID idiom. Safe in scripts/: `_emit` reads features/*.json only.
  local _fx; _fx="$(mktemp)"
  cat > "$_fx" <<'JSON'
{"id":"zz_ldb_selftest_dollar","title":"self-test fixture","status":"selected","area":"ledger","notes":"NAME=\"strength-ledger-schemacheck-$$\""}
JSON
  # ⚠ POSITIVE CONTROL ON THE FIXTURE. If the heredoc ever loses the idiom the two assertions below
  # go green over prose that carries no hazard — the exact way a control stops controlling.
  _eq 'POSITIVE CONTROL: the fixture really carries the shell PID idiom' 'yes' \
      "$(grep -qF "$_dq" "$_fx" && echo yes || echo no)"
  local _sent=""
  _up() { return 0; }
  _as_me() { _sent="$1"; }
  # ⚠ THE LOCK LOOKUP IS STUBBED FOR THE SAME REASON THE DATABASE IS: it is a NETWORK call.
  # `_with_lock_held` runs `git ls-remote --heads origin` (migration 104), so leaving it live would
  # make this hermetic escaping test depend on the remote, on whether a branch named after the
  # fixture happens to exist, and on however long origin takes to answer. This assertion's subject
  # is SQL-LITERAL ESCAPING; it is not the place to exercise the lock lookup.
  # ⚠ AND IT IS STUBBED PASS-THROUGH RATHER THAN HAVING THE KEY PASTED INTO `expected`, because
  # building the expected value with the same helper the code under test uses would assert the
  # function against itself and pass whatever it did. That mirror() carries the lock at all is
  # asserted where it belongs — check-mirror-preserves-a-db-held-claim.sh counts BOTH payload
  # builders, so this test losing sight of it costs no coverage.
  _with_lock_held() { printf '%s' "$1"; }
  mirror zz_ldb_selftest_dollar "$_fx" >/dev/null 2>&1
  local _pl; _pl="$(jq -c "$LEDGER_TICKET_PAYLOAD_JQ" "$_fx")"
  # ⚠ THE PROVENANCE KEY IS SPELLED OUT HERE, NOT TAKEN FROM THE CODE. `mirror()` appends
  # `source` (migration 159) and its default is `tree`, which means INSERT-ONLY: a payload that did
  # not come from origin/main may create a row and may not overwrite one. Writing the literal
  # `"tree"` into the expected value makes this assertion say WHICH default is correct — lifting it
  # out of the code under test would have made the test agree with whatever the code chose, which
  # is exactly what the lock-stub comment above refuses to do for the same reason.
  local _pl_sent; _pl_sent="$(jq -c '. + {source:"tree"}' <<<"$_pl")"
  _eq 'mirror() sends the payload as a SQL literal' \
      "select ledger.mirror_ticket($(_sql_lit "$_pl_sent")::jsonb)" "$_sent"
  # ⚠ AND THE DEFAULT ITSELF IS ASSERTED, SEPARATELY FROM THE ESCAPING. A caller that omits the
  # argument must get a provenance that CANNOT update an existing row. If this ever silently became
  # `main`, every stale working tree would be a write path into the authoritative store again and
  # the escaping assertion above would still pass.
  # ⚠ A SUBSTRING TEST, NOT A JSON PARSE. The sent value is SQL with the payload embedded as a
  # single-quoted literal (quotes doubled), so un-escaping it here would re-implement `_sql_lit`
  # inside its own test. The one fact this arm needs is whether the default key is present and what
  # it says, and `grep -F` answers that without a second escaper to get wrong.
  _eq 'and its default provenance is tree — insert-only, never main' 'yes' \
      "$(grep -qF '"source":"tree"' <<<"$_sent" && echo yes || echo no)"
  # ⚠ NEGATIVE CONTROL on that arm: `main` must NOT be what a defaulted caller sends. Without this
  # the test above would pass on a payload carrying both keys, or on one where the grep matched
  # some other part of the string.
  _eq 'NEGATIVE CONTROL: a defaulted caller never claims main' 'no' \
      "$(grep -qF '"source":"main"' <<<"$_sent" && echo yes || echo no)"
  # ⚠ NEGATIVE CONTROL, and it is the assertion that proves the fix was needed rather than merely
  # present: the OLD construction over THIS SAME payload must be broken. Without it both assertions
  # would pass against code that never had the defect. `grep -oF` because the idiom is all dollars.
  local _old_form="select ledger.mirror_ticket(\$\$${_pl}\$\$::jsonb)"
  _eq 'the OLD bare form is broken by this very payload' 'broken' \
      "$([[ "$(grep -oF "$_dq" <<<"$_old_form" | wc -l)" -gt 2 ]] && echo broken || echo intact)"
  rm -f "$_fx"
  # ── the summary's own arithmetic ──────────────────────────────────────────────────────────────
  # (infra_the_sync_summary_does_not_add_up_to_its_own_denominator)
  #
  # ⚠ THE REAL NUMBERS FROM THE DEFECT THAT MOTIVATED THIS, used as the positive control rather than
  # invented ones: with one ticket carrying the old payload delimiter, sync reported
  # "152 of 2397 mirrored, 70 refused" and printed no error at all. 152 + 70 = 222.
  _eq 'a complete run says nothing'                    ''  "$(_unaccounted 2397 2328 69)"
  _eq 'the real 2175-row loss is caught'               '2175 statement(s) never ran' "$(_unaccounted 2397 152 70)"
  _eq 'a single lost statement is caught'              '1 statement(s) never ran'    "$(_unaccounted 10 8 1)"
  # ⚠ AN ALL-REFUSED RUN IS COMPLETE, NOT LOST. Every statement ran and every one was refused —
  # a different failure, already reported, and reporting it here too would train the reader to
  # ignore this line on the runs where it matters.
  _eq 'an all-refused run is still complete'           ''  "$(_unaccounted 5 0 5)"
  _eq 'an empty run is complete'                       ''  "$(_unaccounted 0 0 0)"
  # ⚠ NEGATIVE GAPS MUST NOT BE SWALLOWED BY `> 0`. More accounted for than emitted means the
  # counter and the output disagree about what was even attempted — impossible, therefore worth
  # saying rather than rounding to "fine".
  _eq 'more accounted for than emitted is also wrong'  'the counts EXCEED what was emitted by 3 — the accounting itself is wrong' "$(_unaccounted 5 6 2)"
  # ⚠ "COULD NOT CHECK" IS NOT "CHECKED AND AGREED" — the same rule the archived-exclusion arm of
  # `export` states. An unset count must not read as a clean run.
  _eq 'a non-numeric count is UNVERIFIED, not clean'   'the counts are not all numeric, so this run is UNVERIFIED' "$(_unaccounted 2397 '' 69)"

  # ── `lock_intent` MUST BE IN NEITHER THE MODELLED OBJECT NOR THE del() LIST ────────────────────
  # ⚠ SHAPE ASSERTION, AND THE ONLY CHEAP GUARD FOR A ONE-LINE MISTAKE THAT DELETES A LIVE FIELD.
  # Migration 45 retired the COLUMN, not the ticket-file field: `feature-ticket.sh` still writes
  # `.lock_intent` on claim and 544 files on origin/main carry one — 57 LIVE and 487 ARCHIVED.
  # ⚠ THIS SAID "58 files on origin/main" WITHOUT SAYING IT COUNTED ONLY THE LIVE QUEUE. That reads
  # as a corpus figure and is a tenfold understatement of one; I nearly quoted it as the population
  # while measuring this very key. State the scope beside a count, or the next reader inherits the
  # smaller number. The value survives ONLY because
  # the key is absent from BOTH lists, so it falls into `extra` and round-trips.
  # ⚠ PUTTING IT BACK IN del() TO "MATCH THE COLUMNS" STRIPS IT ENTIRELY -- silently, with no error
  # and no failing sync, and `check-ledger-reproduces-the-ticket-files.sh` (which would catch it) is
  # ci-exempt and needs the live ledger. This runs in the `verify` tier and costs microseconds.
  # (infra_lock_intent_cannot_retire_until_the_mirror_stops_naming_it)
  _lij="$(printf '%s' "$LEDGER_TICKET_PAYLOAD_JQ")"
  _eq 'lock_intent is NOT a modelled payload key'      '0' "$(printf '%s' "$_lij" | grep -c 'lock_intent:')"
  _eq 'lock_intent is NOT deleted from extra'          '0' "$(printf '%s' "$_lij" | grep -c '\.lock_intent')"
  # ⚠ POSITIVE CONTROL ON THE NEEDLE: both greps above return 0 against an EMPTY string too, so
  # without this a renamed variable would read as two passes. Assert the filter was actually read.
  _eq 'positive control: the payload filter was actually read' 'yes' \
      "$([[ "$(printf '%s' "$_lij" | grep -c 'verified_by_pr')" -gt 0 ]] && echo yes || echo no)"

  # ── ⚠ A VERDICT IS NOT AN EXIT CODE ─────────────────────────────────────────────────────────
  # (infra_a_re_park_carries_the_previous_summary_so_the_owner_sees_a_superseded_reason, item 4)
  # `park` rejected an over-long summary with `summary-too-long` and exited 0 through this wrapper.
  # Visible to a human, invisible to a script — so anything chaining on `&&` carried on as though
  # the ticket had been parked.
  # ⚠ THE VERB IS NOW AN ARGUMENT. These arms all pass `park` because park is the verb the original
  # rule was written for and the one with NO non-ok success — so every assertion below still means
  # exactly what it meant, and any of them changing answer would be a regression rather than a
  # rename. The per-verb arms are asserted separately, below.
  _vrc() { verdict_is_success park "$1" && echo 0 || echo 1; }
  _vrcv() { verdict_is_success "$1" "$2" && echo 0 || echo 1; }
  # ⚠ THE SUCCESS ARMS FIRST, AND THEY ARE THE ONES THAT MATTER. A helper returning 1 for
  # everything satisfies every refusal arm below and would have shipped.
  _eq 'POSITIVE CONTROL: a bare ok is a success'        '0' "$(_vrc 'ok')"
  # The verbs do not share one success token: adjudicate_retired_park returns ok:reassigned and
  # claim returns ok:<id>, so the contract is a PREFIX, not equality.
  _eq 'POSITIVE CONTROL: ok:<detail> is a success too'  '0' "$(_vrc 'ok:reassigned')"
  _eq 'the summary refusal that paid for this is a failure' '1' "$(_vrc 'summary-too-long')"
  _eq 'and the new superseded verdict is too'           '1' "$(_vrc 'summary-superseded')"
  _eq 'so is a refusal that names a person'             '1' "$(_vrc 'not-yours:Saffron')"
  # ⚠ EMPTY IS A FAILURE, NOT A PASS. A verb that printed nothing at all — a silenced error, a
  # connection that died mid-statement — must not read as success; that is the exact shape of the
  # false green this whole helper exists to remove.
  _eq 'an EMPTY verdict is a failure, never a pass'     '1' "$(_vrc '')"
  # ⚠ AND `okay`/`okey` MUST NOT PASS: the prefix is `ok` or `ok:`, not "starts with the letters".
  _eq 'a word merely BEGINNING with ok is not a verdict' '1' "$(_vrc 'okay-but-not-really')"

  # ── ⚠ THE SUCCESS VOCABULARY IS PER VERB, AND A GLOBAL RULE BROKE `release` FOR AN HOUR ────────
  # (fix_verdict_rc_rejects_every_non_ok_success_so_release_dies_on_archived_tickets)
  # Four verdicts are SUCCESSES for their own verb. The global rule refused all four, which made
  # four live case arms in feature-ticket.sh unreachable and killed `release` on every archived
  # ticket — the normal flow after every merge. The scheduled janitor went ok=22/failed=2 before the
  # converting commit to ok=0/failed=10 after it, and died on the FIRST of three candidates each
  # run, so the backlog was invisible.
  _eq 'claim: already-yours is a SUCCESS'          '0' "$(_vrcv claim   'already-yours')"
  _eq 'unpark: not-parked is a SUCCESS'            '0' "$(_vrcv unpark  'not-parked')"
  _eq 'release: already-unassigned is a SUCCESS'   '0' "$(_vrcv release 'already-unassigned')"
  _eq 'release: archived:<why> is a SUCCESS'       '0' "$(_vrcv release 'archived:claimed_by is the only record')"
  # ⚠⚠ THE NEGATIVE CONTROL THAT DECIDES WHETHER THIS IS A FIX OR A HOLE: `archived` must stay a
  # REFUSAL for `park`. feature-ticket.sh dies on it deliberately — parking an archived ticket is
  # finished work, not a park — so widening the rule GLOBALLY to accept `archived:*` would make a
  # real refusal read as success one verb over. That is the defect the verdict contract exists to
  # remove, reintroduced from the other side, and it is the tempting one-line "simplification".
  _eq 'NEGATIVE CONTROL: park still REFUSES archived'      '1' "$(_vrcv park    'archived')"
  _eq 'NEGATIVE CONTROL: park has no non-ok success at all' '1' "$(_vrcv park   'already-unassigned')"
  # ⚠ AND THE VOCABULARY MUST NOT LEAK BETWEEN VERBS, or the verb argument is decoration and the
  # rule is global again wearing a parameter.
  _eq 'NEGATIVE CONTROL: already-yours is NOT a release success' '1' "$(_vrcv release 'already-yours')"
  _eq 'NEGATIVE CONTROL: not-parked is NOT a claim success'      '1' "$(_vrcv claim   'not-parked')"
  # ⚠ FAILS CLOSED: an unrecognised verdict is a REFUSAL, and an unrecognised VERB gets only the
  # universal `ok` prefix. A new verdict added to a DB function must be named here deliberately
  # rather than inherited silently — the opposite failure to the one this ticket fixes.
  _eq 'an unknown verdict is a refusal'            '1' "$(_vrcv release 'brand-new-verdict')"
  _eq 'an unknown VERB still accepts a bare ok'    '0' "$(_vrcv frobnicate 'ok')"
  _eq 'an unknown VERB refuses a per-verb success' '1' "$(_vrcv frobnicate 'already-unassigned')"

  # ── ⚠ WHICH DISPATCH ARMS CARRY THE VERDICT CONTRACT, ASSERTED ON THE FILE ──────────────────
  # (infra_every_ledger_db_verb_reports_a_refusal_as_success_because_as_me_returns_psqls_status)
  # The population was established by READING THE CALLERS, not by counting call sites: `claim`,
  # `flip-passing`, `release` and `unpark` have ZERO external callers in scripts/ or .github/, so
  # converting them cannot break a script — they are typed at a shell by a person.
  # ⚠ ASSERTED HERE RATHER THAN LEFT TO REVIEW because the failure is silent: an arm quietly moved
  # back to `_as_me` during a merge would restore the exact defect this ticket closes, and nothing
  # else in the repo would notice.
  # ⚠⚠ READ THE FILE WITHOUT THIS FUNCTION IN IT. My first version grepped the whole file and every
  # arm returned 2 instead of 1 — because the assertion's own pattern is a line of the file it is
  # searching. `answer`, asserted to be absent, came back 1 for the same reason: the line saying so
  # contained the string. An assertion that reads the file it lives in counts ITSELF, and the count
  # was exactly double, which is what made it obvious rather than plausible.
  _dispatch() { sed '/^_ldb_self_test()/,/^}$/d' "$SELF"; }
  # ── ⚠ THE OWNER'S COMMENT IS RETURNED WHOLE ────────────────────────────────────────────────────
  # (fix_the_owners_comment_is_truncated_to_eighty_characters_so_the_po_cannot_read_it)
  #
  # ⚠⚠ COMMENT LINES ARE STRIPPED BEFORE COUNTING, AND THAT IS NOT TIDINESS. The fix's own header
  # QUOTES the code it replaced, so a plain grep counts the explanation and reports the defect as
  # still present. Same shape as `_dispatch` stripping this function: an assertion that reads the
  # file it lives in counts ITSELF.
  _nocomment() { _dispatch | grep -vE "^[[:space:]]*#"; }
  _eq 'no LIVE code truncates a comment body'      '0' "$(_nocomment | grep -c 'left(replace(c.body')"
  _eq 'both comment reads return the whole body'   '2' "$(_nocomment | grep -c 'replace(c.body')"
  # ⚠ NEGATIVE CONTROL FOR THE ARM ABOVE. `0` is only a finding if the string is greppable at all —
  # otherwise a typo in the pattern passes. The fix's header quoting the old form is what proves it.
  _eq 'the old form IS greppable, so 0 above is a finding' '1' "$(_dispatch | grep -c 'left(replace(c.body')"
  _eq 'claim carries the verdict contract'        '1' "$(_dispatch | grep -c 'ledger.claim(.\$1.)')"
  _eq 'flip-passing carries it'                   '1' "$(_dispatch | grep -c '_as_me_verdict flip-passing "select ledger.flip_passing')"
  _eq 'release carries it'                        '1' "$(_dispatch | grep -c '_as_me_verdict release "select ledger.release_claim')"
  _eq 'unpark carries it'                         '1' "$(_dispatch | grep -c '_as_me_verdict unpark "select ledger.unpark')"
  _eq 'wont-do carries it'                        '1' "$(_dispatch | grep -c '_as_me_verdict wont-do "select ledger.close_as_wont_do')"
  _eq 'wont-do is in the usage string'             '1' "$(_dispatch | grep -c '|wont-do <id> <why>|')"
  _eq 'park keeps the one it was given first'     '1' "$(_dispatch | grep -c '_as_me_verdict park "select ledger.park')"
  # ⚠⚠ THE NEGATIVE CONTROL, AND IT IS A REAL ONE RATHER THAN A SPARE ASSERTION. Every arm above
  # passes if the whole file were converted indiscriminately — including the READ-ONLY queries,
  # where the change would be a defect: a query returning no rows is not a refusal, and giving
  # `waiting` or `frontier` a verdict contract would turn "nothing to show" into a failing exit.
  _eq 'the QUERIES are deliberately NOT converted — nothing to show is not a refusal' '0' \
      "$(_dispatch | grep -cE '^  (board|frontier|waiting|po-queue|po-owner|orphans)\).*_as_me_verdict')"
  # ⚠ AND `answer` STAYS UNCONVERTED ON PURPOSE: it runs TWO statements and prints two verdicts, so
  # the single-verdict contract does not fit it. Named here so its absence reads as a decision.
  _eq 'answer is still on the plain helper, by decision'                               '0' \
      "$(_dispatch | grep -c '_as_me_verdict "select ledger.add_comment')"

  [[ $fails -eq 0 ]] && printf 'ledger-db --self-test: ok\n' || printf 'ledger-db --self-test: FAILED\n' >&2
  return $fails
}

# ⚠ THROUGH THE SHARED CONTRACT, NOT A HAND-ROLLED CASE ARM. My first draft matched
# `--self-test|--selftest)` inside the dispatch below and `check-selftest-flag-contract.sh` refused
# it — correctly. Hand-rolling is how the two spellings diverged across 66 scripts, and how a
# mistyped flag came to fall through and run a script's REAL ACTION while exiting 0. ⚠ Here the
# real action is a WRITE PATH to the shared ledger, so `--slef-test` falling through would have
# been considerably worse than a self-test that silently did not run.
#
# `selftest_is_flag` (not `selftest_requested`) is the form for a script with its own argument
# loop: this one dispatches on verbs, and `selftest_requested` exits 2 on any word that is not the
# flag — which would refuse every verb the script exists for.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"

# ── regenerate — AUTHOR a ticket file from its row, which nothing else in this repo can do ──────
#
#   ledger-db.sh regenerate <id> [<id> ...]        # to stdout — safe, the default
#   ledger-db.sh regenerate --out DIR <id> ...     # write DIR/<id>.json
#   ledger-db.sh regenerate --out DIR --all        # the whole corpus
#   ledger-db.sh regenerate --self-test            # the shared module's assertions
#
# ⚠ WHY THIS IS NOT `export`, AND WHY `export` MUST NOT GROW INTO IT. `export --write` PATCHES a
# file that already exists and refuses to author one — deliberately, and its own comment says so:
# "the database owns the LIFECYCLE, git owns the PROSE. An export may UPDATE what the database owns.
# It may never AUTHOR a ticket." After CUTOVER step 7 there is no file to patch, and that is exactly
# when a regenerator is needed. Two verbs, two contracts.
#
# ⚠ STDOUT IS THE DEFAULT AND `--out` IS REQUIRED TO WRITE ANYTHING. Not politeness: `export --write`
# has a history here (widening its corpus while `status` was still being overwritten would have
# written "archived" over "passing" in ~2,149 real ticket files), and a regenerator pointed at
# `features/` by default is one typo from the same shape. It never writes into `features/` unless a
# human names it.
#
# ⚠ THE RECONSTRUCTION LOGIC IS NOT IN THIS FILE. scripts/lib/ledger_reconstruct.py holds it, and
# scripts/check-ledger-reproduces-the-ticket-files.sh — the step-6 census — is its other caller.
# Both read ONE FIELD_POLICY table, so the writer's omissions and the comparator's normalisation
# cannot drift apart. If they had two tables the drift would be silent IN THE DIRECTION OF A GREEN
# GATE: the comparator forgiving a field the writer had stopped emitting.
# (infra_no_tool_can_author_a_ticket_file_from_its_database_row)
regenerate_tickets() {
  if selftest_is_flag "${1:-}"; then
    python3 "$(dirname "${BASH_SOURCE[0]}")/lib/ledger_reconstruct.py"; return $?
  fi

  local out="" all=0 ids=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="${2:-}"; shift 2 || return 64 ;;
      --all) all=1; shift ;;
      -*)    echo "regenerate: unknown flag '$1'" >&2; return 64 ;;
      *)     ids+=("$1"); shift ;;
    esac
  done
  if [[ "$all" -eq 0 && "${#ids[@]}" -eq 0 ]]; then
    echo "usage: ledger-db.sh regenerate [--out DIR] {--all | <id> ...}" >&2; return 64
  fi
  [[ -n "$out" ]] && mkdir -p "$out"

  local where="true"
  if [[ "$all" -eq 0 ]]; then
    local quoted; quoted="$(printf "'%s'," "${ids[@]}")"
    where="id in (${quoted%,})"
  fi

  local rows; rows="$(mktemp)"; trap 'rm -f "$rows"' RETURN
  # ⚠ DERIVED, NOT RETYPED — THIS WAS THE THIRD HANDWRITTEN COPY OF THE COLUMN LIST. The census and
  # its sibling check already read `--sql-columns`; this one was still spelling the list out, so a
  # field added to the module reached two callers and not the third. That is not a hypothetical: it
  # is how `drift` would have been missed here while the census restored it, and the writer and the
  # census would then have disagreed on every coerced ticket.
  # ⚠ An empty list would select nothing and regenerate a file of `{}` per ticket, so it is checked
  # rather than assumed — a silent empty here writes wrong files rather than failing.
  local cols; cols="$(python3 scripts/lib/ledger_reconstruct.py --sql-columns)" || {
    echo "regenerate: could not derive the column list from scripts/lib/ledger_reconstruct.py" >&2; return 3; }
  [[ -n "$cols" ]] || { echo "regenerate: the derived column list is EMPTY, which would select nothing" >&2; return 3; }
  docker exec -i "$CONTAINER" psql -U ledger_owner -d ledger -tAc "
    select json_build_object($cols)::text
    from ledger.ticket where $where" > "$rows" || {
    echo "regenerate: the row read failed against '$CONTAINER'" >&2; return 3; }

  # ⚠ ZERO ROWS IS A BROKEN READ OR A WRONG ID, NOT AN EMPTY LEDGER. A regenerator that writes
  # nothing and exits 0 is indistinguishable from one that worked.
  [[ -s "$rows" ]] || { echo "regenerate: read ZERO rows — a broken read or an id that does not exist" >&2; return 3; }

  LEDGER_ROWS="$rows" LEDGER_OUT="$out" python3 - <<'PY_REGEN'
import json, os, sys
sys.path.insert(0, 'scripts/lib')
from ledger_reconstruct import reconstruct, reconstruct_from_row          # THE ONE COPY

out = os.environ['LEDGER_OUT']
n = 0
for line in open(os.environ['LEDGER_ROWS']):
    line = line.strip()
    if not line:
        continue
    row = json.loads(line)
    body = json.dumps(reconstruct_from_row(row), indent=2, ensure_ascii=False) + "\n"
    if out:
        with open(os.path.join(out, row['id'] + '.json'), 'w') as fh:
            fh.write(body)
    else:
        sys.stdout.write(body)
    n += 1
print("regenerate: %d ticket(s)%s" % (n, (" -> " + out) if out else ""), file=sys.stderr)
PY_REGEN
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  # the store adapter's arms first (scripts/lib/ticket-store.sh is sourced, so it has no flag of its own)
  _store_rc=0; ticket_store_self_test || _store_rc=1
  _ldb_self_test; _ldb_rc=$?
  (( _store_rc )) && printf 'ledger-db --self-test: FAILED (ticket-store adapter)\n' >&2
  exit $(( _ldb_rc || _store_rc ))
fi

# ── THE STORE IS AN ADAPTER (scripts/lib/ticket-store.sh). With TICKET_STORE=jira every verb is handed to
# the Jira adapter before this file's database arms run; db (the default) is this file.
if [[ "$(ticket_store_name)" == jira ]]; then ticket_store_dispatch_jira "$@"; fi
# ── FILE-ERA VERBS ARE NOT IN THE TEMPLATE. The project this was seeded from migrated from ticket
# FILES (features/*.json) to the database, and sync/mirror/regenerate/freshness/export are that
# migration's instruments. A template starts on the database, has no features/ tree, and these verbs
# would read ZERO tickets and say so — honest, but a trap. They refuse by name instead.
case "${1:-}" in
  sync|mirror|regenerate|freshness|export)
    echo "ledger-db: '$1' is a FILE-ERA verb (ticket files → database sync) that this template never needed: the ledger is the only store. See docs/ledger-spec.md." >&2; exit 2 ;;
esac
case "${1:-}" in
  attach)   attach ;;
  mirror)   shift; mirror "$@" ;;
  sync)     shift; sync_all "$@" ;;
  freshness) shift; freshness_report "$@" ;;
  export)   shift; export_tickets "$@" ;;
  regenerate) shift; regenerate_tickets "$@" ;;
  whoami)   printf '%s\n' "$(_me)" ;;
  # ── ⚠ IS THE DATABASE ACTUALLY THERE? ONE ROUND TRIP, NOTHING ELSE. ──────────────────────────
  # (infra_the_database_is_first_for_the_requirement_and_the_file_is_generated)
  #
  # ⚠ THIS EXISTS BECAUSE `whoami` WAS BEING USED AS THE REACHABILITY PROBE AND CANNOT FAIL.
  # `feature-ticket.sh:736` reads `ledger-db.sh whoami` to decide between the verdicts `failed:`
  # (the database answered and refused) and `unreachable:` (nobody answered) — a distinction that
  # file spends fifteen lines arguing for, because on 2026-09-02 four agents were sent to check
  # connectivity that was fine. **But `whoami` is `printf '%s' "$(_me)"`, and `_me` contains ZERO
  # docker calls** — it resolves the AGENT NAME from the roster, locally. Driven:
  #
  #     LEDGER_CONTAINER=strength-ledger-db                whoami rc=0
  #     LEDGER_CONTAINER=strength-ledger-does-not-exist    whoami rc=0
  #     LEDGER_CONTAINER=<empty>                           whoami rc=0
  #
  # So `_reach` was ALWAYS 1 and `unreachable:` was unreachable code, in both senses. The fix for
  # that outage installed a probe that cannot detect the condition it exists for — the pendulum
  # stuck at the opposite extreme, now always blaming the verb when the database is simply down.
  #
  # ⚠ NOT `board` OR `freshness`, WHICH WERE THE OBVIOUS CANDIDATES AND DO NOT DISCRIMINATE.
  # Measured: `board` exits 1 against a live container AND a bogus one — it cannot tell them apart.
  # `freshness` exits 2 live / 1 bogus, so its codes carry a staleness verdict rather than an answer
  # to this question. A probe must have exactly one reason to fail.
  # ⚠ NO `-i`. It buys nothing for `psql -c`, which takes its statement as an argument, and `-i` is
  # the form that attaches stdin — the documented drain. A probe must not be able to block on input.
  ping)     docker exec "$CONTAINER" psql -U ledger_owner -d ledger -tAc 'select 1' >/dev/null 2>&1 ;;
  # ── ⚠ DOES THIS TICKET EXIST, ACCORDING TO THE STORE THAT IS AUTHORITATIVE FOR IT? ───────────
  # (infra_the_duplicate_check_reads_refs_and_never_the_ledger_row)
  #
  # One round trip, one column. `feature-ticket.sh exists` reads this BEFORE it scans every ref,
  # because a ticket whose branch was deleted on merge lives in exactly one place and the ref scan
  # cannot see it. Measured 2026-09-17: 38 ids are `archived` in this database, on NO ref, and not
  # in the legacy jsonl — `exists` answered "Raising it is safe" for every one of them.
  #
  # ⚠⚠ EMPTY OUTPUT WITH rc=0 MEANS "THE DATABASE ANSWERED AND THERE IS NO SUCH ROW". That is a
  # FINDING. rc != 0 means nobody answered, which is not a finding at all. **The caller must keep
  # them apart**, because on the other side of that distinction `exists` exits 1, and exit 1 is not
  # a report — it is a GRANT of permission to raise the id. Collapsing "could not look" into
  # "looked and it is not there" is the entire defect this verb was added to remove.
  #
  # ⚠ `v_ticket`, NOT `ledger.ticket`. The agent role is DENIED on the base table by design, and it
  # is granted `r` on this view — driven, as Saffron, before this was written. `v_claims` is NOT
  # granted to `ledger_agent`, which is why `board` fails for a developer; that is a separate defect
  # and this verb deliberately does not route around it by picking a view it can reach by luck.
  #
  # ⚠ EVERY STATUS, INCLUDING `archived`. The question is "has this id ever been used", not "is it
  # live" — a duplicate of finished work is exactly as expensive as a duplicate of live work, and
  # 4,082 of the 4,403 rows here are archived. A status filter would hide the majority of the answer.
  ticket-row) shift
            _tr_id="${1-}"
            if [[ -z "$_tr_id" ]]; then
              echo "usage: ledger-db.sh ticket-row <feature_id>" >&2; exit 64
            fi
            _as_me "select status from ledger.v_ticket where id = '${_tr_id//\'/\'\'}'" ;;
  # ── WHO HOLDS IT, ACCORDING TO THE ROW ─────────────────────────────────────────────────────────
  # (fix_release_abandon_gates_on_a_git_ref_that_the_cutover_made_permanently_unwritable)
  # `release --abandon` asked a pre-cutover claim branch whose claim this was, and that copy can never
  # be rewritten. The row is where ownership lives. ⚠ THE `owner:` PREFIX IS THE POINT: an unassigned
  # row prints `owner:` and a missing row prints NOTHING, so "nobody holds it" and "no such ticket"
  # stay apart — the same discipline ticket-row's callers need `ledger_row_probe` to recover.
  ticket-owner) shift
            _to_id="${1-}"
            if [[ -z "$_to_id" ]]; then
              echo "usage: ledger-db.sh ticket-owner <feature_id>" >&2; exit 64
            fi
            # ⚠ AND WHO STOOD IT DOWN. `stand-down` CLEARS claimed_by — that is the hand-back — so after
            # it the row names nobody, and the holder who is about to release the lock would read as a
            # stranger. The event log keeps who did it: the latest ownership event, if it is a
            # stand-down, names the agent still holding the lock. Tab-separated, one line.
            _as_me "select 'owner:' || coalesce(t.claimed_by,'') || E'\\t' || 'stood-down-by:' || coalesce((
                      select case when h.verb = 'stand-down' then h.actor end
                        from ledger.v_history h
                       where h.ticket_id = t.id and h.verb in ('claim','release','stand-down','owner_set')
                       order by h.seq desc limit 1), '')
                      from ledger.v_ticket t where t.id = '${_to_id//\'/\'\'}'" ;;
  # ── ⚠ WHICH TICKETS MENTION THIS SUBJECT, ACCORDING TO THE ROW? ──────────────────────────────
  # (infra_the_duplicate_check_reads_refs_and_never_the_ledger_row)
  #
  # The SUBJECT question, which is NOT the id question above and shares no code with it. Serves
  # `feature-ticket.sh search`, whose ref grep cannot see a ticket whose file is on no ref.
  #
  # ⚠ `v_ticket_detail`, because it is the only granted view carrying the requirement PROSE —
  # `title`, `user_visible_behavior`, `notes` and the `verification` array. `v_ticket` has the title
  # alone, and a subject search over titles only would answer a narrower question while looking like
  # this one.
  #
  # ⚠ THE ARRAY IS FLATTENED WITH array_to_string, NOT INDEXED. `verification` is `text[]`; matching
  # `verification[1]` would search the first item and silently ignore the rest, which is a smaller
  # denominator wearing a complete one.
  #
  # ⚠ AN INVALID PATTERN IS THE CALLER'S ERROR AND IS REPORTED AS ONE. Postgres raises `invalid
  # regular expression` for e.g. `[`, and without this arm that arrives at the caller as a failed
  # call, gets probed for reachability, finds the database up, and is reported as `failed:` — "the
  # database answered and the call FAILED". True, useless, and it sends the reader to the wrong
  # subsystem for a typo in their own pattern. (The mirror image of the 2026-09-02 incident where
  # four agents were sent to check connectivity that was fine.)
  ticket-grep) shift
            _tg_re="${1-}"
            if [[ -z "$_tg_re" ]]; then
              echo "usage: ledger-db.sh ticket-grep <extended-regex>" >&2; exit 64
            fi
            _tg_errf="$(mktemp)"
            _tg_out=""; _tg_rc=0
            _tg_out="$(_as_me "select id from ledger.v_ticket_detail
                                where coalesce(title,'') || ' '
                                   || coalesce(user_visible_behavior,'') || ' '
                                   || coalesce(notes,'') || ' '
                                   || coalesce(array_to_string(verification, ' '), '')
                                      ~* '${_tg_re//\'/\'\'}'
                                order by id" 2>"$_tg_errf")" || _tg_rc=$?
            if (( _tg_rc != 0 )) && grep -qi 'invalid regular expression' "$_tg_errf"; then
              printf 'ledger-db: %s is not a valid extended regular expression:\n' "$_tg_re" >&2
              head -2 "$_tg_errf" >&2
              rm -f "$_tg_errf"; exit 64
            fi
            rm -f "$_tg_errf"
            (( _tg_rc == 0 )) || exit "$_tg_rc"
            printf '%s\n' "$_tg_out" ;;
  # ── bring the per-agent login roles into line with ledger.agent ──────────────────────────────
  #
  # ⚠ THIS EXISTS BECAUSE A REBUILT LEDGER HAS NO AGENT ROLES AND NOTHING SAID SO. Migration 008
  # creates a role per agent from `ledger.agent`, and that table is EMPTY when initdb runs it — so a
  # fresh build has 3 roles against 11 live and every agent's write is refused. Vera measured it
  # driving Ca4 (2026-09-16) and seeded the roster by hand "because no documented step says to".
  #
  # ⚠ IT PRINTS WHAT IT DID, one row per agent, rather than exiting 0 in silence. On the LIVE
  # instance this is a no-op — the roles already exist — so a quiet version would be
  # indistinguishable from doing the job. Driven on a rebuilt instance: 2 login roles -> 16, `created
  # x14`; re-run, `confirmed x14`; on live, `confirmed x7` and nothing created.
  sync-agent-roles)
            docker exec "$CONTAINER" psql -U ledger_owner -d ledger \
              -c 'select action, agent from ledger.sync_agent_login_roles() order by action, agent' || exit 1
            printf '\n  Seed ledger.agent from agents/roster.json FIRST if this created nothing on a\n' >&2
            printf '  fresh rebuild — the function reads that table and cannot invent a roster.\n' >&2
            ;;
  # ── raise a ticket, or an epic with its children, in ONE WRITE ───────────────────────────────
  # (feat_an_agent_or_the_owner_can_raise_an_epic_with_children_in_one_write · spec §7)
  #
  # ⚠ NO --as / --raised-by FLAG, DELIBERATELY. `ledger.resolve_actor` ignores a supplied name for
  # every caller except the console, so a flag here would be inert at best — and offering one
  # invites the belief that raising as somebody else is possible. The identity is the CONNECTION:
  # `_as_me` connects as your own role, so `raised_by` is you and cannot be anything else.
  #
  # ⚠ THE JSON IS VALIDATED LOCALLY FIRST. A malformed file would otherwise reach psql as a broken
  # literal and come back as a syntax error about jsonb, which reads like a database fault rather
  # than a typo in the payload the caller just wrote.
  raise|raise-epic)
            _rv_verb="$1"; shift; _require_session_identity || exit 3
            _rv_file="${1-}"
            if [[ -z "$_rv_file" ]]; then
              echo "usage: ledger-db.sh $_rv_verb <file.json>" >&2; exit 64
            fi
            if [[ ! -r "$_rv_file" ]]; then
              echo "ledger-db: cannot read $_rv_file" >&2; exit 66
            fi
            if ! python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$_rv_file" 2>/dev/null; then
              echo "ledger-db: $_rv_file is not valid JSON — nothing was sent" >&2; exit 65
            fi
            _rv_fn=ledger.raise_ticket; [[ "$_rv_verb" == raise-epic ]] && _rv_fn=ledger.raise_epic
            # ⚠ THE VERDICT IS READ AND BRANCHED ON, not printed and forgotten. Every one of these
            # functions returns a string rather than raising, so a bare `psql` exit code is 0 for a
            # REFUSED raise — the refusal is in stdout. Treating rc as the answer would report
            # "raised" for `exists:` or `unknown-parent:`.
            _rv_out="$(_as_me "select $_rv_fn($(_sql_lit "$(cat "$_rv_file")")::jsonb)")" || exit $?
            printf '%s\n' "$_rv_out"
            case "$_rv_out" in
              ok|ok:*) ;;
              *) echo "ledger-db: the raise was REFUSED — nothing was written." >&2; exit 1 ;;
            esac ;;
  # ⚠ THE GUARD SITS HERE, ON THE DECISION, AND NOWHERE ELSE — third placement, and the first two
  # were both too broad. On `mirror` it was inconsistent (sync did the same writes unguarded); in
  # `_as_me` it caught every READ as well, because reads run as the agent too.
  # A read is free. A mirror copies a fact git already decided. Only a CLAIM asserts ownership, and
  # ownership is the one thing a wrong name makes permanently unanswerable.
  claim)    shift; _require_session_identity || exit 3; _as_me_verdict claim "select ledger.claim('$1')" ;;
  # ⚠ THE OTHER TWO LIFECYCLE VERBS, SAME SHAPE AS `claim` ON PURPOSE. Each takes identity from
  # `session_user` inside the procedure — there is no WHO argument on any of them, which is the
  # property that stops one agent acting as another and must not be "tidied" into a parameter.
  # ⚠ SINGLE-QUOTE DOUBLING ON THE FREE-TEXT ARGUMENT. A park reason is prose and routinely contains
  # apostrophes; without the escape the statement breaks on exactly the long, careful reasons this
  # ledger exists to preserve, and it breaks at the moment somebody is parking something important.
  # ⚠ THE KIND IS PASSED, NOT OMITTED, AND THAT IS THE FIX. This line used to call the two-argument
  # form, so the function's own DEFAULT supplied `blocked_on_owner` — putting the ticket on the one
  # list only the owner can clear, without any caller choosing it. 67 of 89 live parks got there
  # that way. Absent here means SQL NULL, which migration 54 reads as "not stated" and refuses on a
  # first park, rather than as "the owner".
  # (fix_park_cannot_state_its_kind_so_every_park_asserts_the_owner_is_blocked)
  # ⚠ PARSED BEFORE `_p_reason="$*"` SWALLOWS EVERYTHING. The reason is deliberately greedy so it
  # need not be quoted as one word; a flag left in that stream becomes part of the reason text and
  # is never seen as a flag.
  park)     shift; _require_session_identity || exit 3
            _p_kind=""; _p_summary=""; _p_condition=""
            while [[ "${1-}" == --* ]]; do
              case "$1" in
                --kind) _p_kind="${2-}"; shift 2 ;;
                --kind=*) _p_kind="${1#--kind=}"; shift ;;
                # ⚠ THE SUMMARY IS WHAT THE OWNER READS FIRST, and it is a SEPARATE argument rather
                # than the first line of the reason. A convention that says "lead with a summary"
                # is unenforceable and decays — 61 of 71 park markers name no runnable condition
                # today under exactly that kind of convention.
                # (fix_a_park_reason_explains_the_process_instead_of_saying_what_is_blocking_it)
                --summary) _p_summary="${2-}"; shift 2 ;;
                --summary=*) _p_summary="${1#--summary=}"; shift ;;
                # ⚠ FIVE ARGUMENTS NOW, FOR THE REASON THE COMMENT BELOW ALREADY GIVES ABOUT FOUR.
                # Migration 101 added the unblock condition and this call site reaches ledger.park
                # WITHOUT going through feature-ticket.sh — which is exactly why the verdict lives in
                # the database. Not passing it here would park with no condition from the one place
                # that bypasses the shell guard.
                --condition) _p_condition="${2-}"; shift 2 ;;
                --condition=*) _p_condition="${1#--condition=}"; shift ;;
                *) echo "park: unknown flag '$1' (expected --kind <blocked_on_owner|blocked_on_other|banked> or --summary <one sentence>)" >&2; exit 2 ;;
              esac
            done
            _p_id="$1"; shift; _p_reason="$*"
            # ⚠ VALIDATED HERE RATHER THAN LET THROUGH TO THE ENUM CAST. An unrecognised label
            # reaches Postgres as `invalid input value for enum ledger.park_kind`, which names a
            # type and not the mistake; and it would arrive after `_as_me` has already opened a
            # connection. Neither is fatal — it is the message that suffers.
            case "$_p_kind" in
              ""|blocked_on_owner|blocked_on_other|banked) ;;
              *) echo "park: '$_p_kind' is not a park kind — use blocked_on_owner, blocked_on_other or banked" >&2; exit 2 ;;
            esac
            # ⚠ FOUR ARGUMENTS ALWAYS, BECAUSE MIGRATION 62 DROPPED THE THREE-ARGUMENT FORM. A new
            # signature does not replace an old one — Postgres keeps both as overloads — so while
            # the 3-arg version existed, these two call sites would have gone on parking tickets
            # with no summary at all and the requirement would have been bypassable from the one
            # place that calls it. The drop is what makes the rule bind; passing 4 args is what
            # keeps this working after it.
            _p_kind_sql="NULL"; [[ -n "$_p_kind" ]] && _p_kind_sql="'${_p_kind}'::ledger.park_kind"
            # Absent means SQL NULL, which the function reads as "not stated" and — on a first park
            # — refuses. On a RE-park it carries the row's existing summary forward, so restoring a
            # lock a merge deleted still needs no arguments.
            _p_sum_sql="NULL"; [[ -n "$_p_summary" ]] && _p_sum_sql="'${_p_summary//\'/\'\'}'"
            # Absent means SQL NULL, which migration 101 reads as "not stated" and — on a first park
            # — refuses with `condition-need-condition`. On a RE-park it carries the row's existing
            # condition forward, so restoring a lock a merge deleted still needs no arguments.
            _p_cond_sql="NULL"; [[ -n "$_p_condition" ]] && _p_cond_sql="'${_p_condition//\'/\'\'}'"
            # ⚠ ALL FIVE ARGUMENTS, ALWAYS. A four-argument call would hit the legacy SHIM, which
            # passes a NULL condition — correct as a fallback for an unpulled checkout, wrong as the
            # behaviour of the current tool.
            _as_me_verdict park "select ledger.park('${_p_id//\'/\'\'}', '${_p_reason//\'/\'\'}', ${_p_kind_sql}, ${_p_sum_sql}, ${_p_cond_sql})" ;;
  # ⚠⚠ THE HAND-BACK, AND IT IS A CALLER RATHER THAN A PERMISSION.
  # (infra_a_holder_cannot_hand_back_a_claim_they_never_started)
  #
  # `release` refuses the HOLDER of an `in_progress` ticket with
  # `in-progress:flip the status back before releasing` -- and until migration 173 NOTHING COULD
  # FLIP IT BACK. Every other surface refused too: `groom` on source status, `unpark` sets
  # in_progress (a closed loop), `amend` says status-has-its-own-verbs. The database permitted the
  # transition the whole time; only the wrapper deadlocked.
  #
  # ⚠ DELIBERATELY NOT ROUTED THROUGH `ledger.owner_set_field`, which permits this transition and
  # would have been one line: it takes its actor as an UNCHECKED PLAIN STRING, so agents reaching
  # it would make an ownership-adjacent write unauthenticated in practice. `stand_down` takes
  # `session_user`, exactly as `release_claim` does.
  #
  # ⚠ AND IT IS IN THE USAGE STRING BELOW. `flip-passing` was a real verb missing from that string
  # for weeks, and CLAUDE.md read the absence as "not a verb" and told people the completion
  # sequence had two dead steps of three. A verb nobody can discover is a verb nobody uses.
  stand-down) shift; _require_session_identity || exit 3
            _sd_id="${1:-}"; shift 2>/dev/null || true; _sd_reason="$*"
            [[ -n "${_sd_id:-}" ]] || { echo "stand-down needs a ticket id: stand-down <id> <why>" >&2; exit 2; }
            [[ -n "${_sd_reason:-}" ]] || { echo "stand-down needs a reason: stand-down <id> <why>
  The reason is not bookkeeping. A ticket returning to the frontier is a claim about the world --
  that nobody is working this and anyone may take it. Say why, so the next reader can tell a
  stand-down from an abandonment." >&2; exit 2; }
            _as_me_verdict stand-down "select ledger.stand_down('${_sd_id//\'/\'\'}', '${_sd_reason//\'/\'\'}')" ;;
  flip-passing) shift; _require_session_identity || exit 3
            _f_id="$1"; _f_pr="${2:-}"
            [[ "$_f_pr" =~ ^[0-9]+$ ]] || { echo "flip-passing needs a PR NUMBER: flip-passing <id> <pr>" >&2; exit 2; }
            _as_me_verdict flip-passing "select ledger.flip_passing('${_f_id//\'/\'\'}', $_f_pr)" ;;
  # ⚠ ARCHIVE IS THE THIRD STEP OF A COMPLETION AND IT HAD NO DATABASE VERB AT ALL, which is why no
  # ticket could reach `archived` after the ticket files were deleted: `archive-passing.sh` MOVES
  # features/<id>.json into features/archive/, and with no files there is nothing to move, so the
  # row stayed `passing` and `release` correctly refused it. Driven 2026-09-18.
  # ⚠ THE TERMINAL OUTCOME IS SET BY THE TRANSITION, NOT PASSED IN HERE. `ledger.set_status` takes
  # archived_from_status from the row's own prior status (migration 168). A caller that supplied it
  # would be a second writer of one fact, and the copy that drifts is the one a careful agent obeys.
  # So there is deliberately no way to type the outcome on this command line.
  # (fix_the_completion_sequence_still_moves_a_file_so_no_ticket_can_reach_archived)
  archive)  shift; _require_session_identity || exit 3
            # ⚠ `${1:-}` and a guarded shift, NOT `$1` — under `set -u` a bare `$1` ABORTS on a
            # zero-arg call, so the two guards below are unreachable and the user gets
            # `line NNN: $1: unbound variable` instead of the message naming the remedy. A guard
            # whose remedy is unclear pushes people toward destructive options. The sibling arms
            # (park, flip-passing, release, unpark) carry the same shape and are NOT changed here —
            # they are pre-existing and not this ticket's diff. Named in the ticket notes.
            _a_id="${1:-}"; shift 2>/dev/null || true; _a_reason="$*"
            [[ -n "${_a_id:-}" ]] || { echo "archive needs a ticket id: archive <id> <why>" >&2; exit 2; }
            [[ -n "${_a_reason:-}" ]] || { echo "archive needs a reason: archive <id> <why>" >&2; exit 2; }
            _as_me_verdict archive "select ledger.set_status('${_a_id//\'/\'\'}', 'archived', '${_a_reason//\'/\'\'}')" ;;
  # ⚠ THE ISSUE NUMBER USED TO REACH THE ROW ONLY THROUGH A TICKET FILE, via mirror_ticket's payload
  # — so with the files retired it stopped landing. Measured 2026-09-18: 9 of 17 `in_progress` rows
  # had a NULL issue. `ledger.record_issue` FILLS ONLY and refuses a different number rather than
  # overwriting, because two issue numbers for one ticket means a duplicate issue or a confused
  # caller, and picking a winner between two OWNER records is unrecoverable.
  # ⚠ DELIBERATELY NOT PART OF `amend`, whose whitelist excludes `issue`: a requirement-field editor
  # must not be able to forge an ownership pointer.
  # (fix_the_bare_lock_guard_lost_its_bound_and_can_adopt_a_live_claim)
  record-issue) shift; _require_session_identity || exit 3
            _ri_id="${1:-}"; _ri_n="${2:-}"
            [[ -n "$_ri_id" && "$_ri_n" =~ ^[0-9]+$ ]] \
              || { echo "usage: ledger-db.sh record-issue <id> <issue-number>" >&2; exit 2; }
            _as_me_verdict record-issue "select ledger.record_issue('${_ri_id//\'/\'\'}', $_ri_n)" ;;
  # ⚠ RUN THESE FROM A REAL CHECKOUT, NOT A COPY OF THIS FILE. Both verbs resolve their libs AND
  # your identity relative to this script's own location, so a copy in /tmp finds neither: you get
  # `lib/selftest-flag.sh: No such file or directory` and then, correctly, `REFUSING TO WRITE — your
  # identity came from nothing, not your session`. Driven 2026-09-18 by the PO doing exactly that to
  # use the verbs before this branch merged. ⚠ THE REFUSAL IS THE SYSTEM WORKING: an amendment
  # attributed to a directory label instead of an agent is the wrong-OWNER defect, and a wrong owner
  # is the one thing the ledger cannot self-correct — a wrong status is fixed by the next verify.
  # ⚠ AMEND IS THE VERB THAT DID NOT EXIST, AND ITS ABSENCE MADE THE OWNER UN-ABSENT-ABLE. `raise`
  # wrote the requirement once and nothing could change it, so every amendment was a command he
  # typed. The guards live in `ledger.amend_requirement` (migration 163) and are NOT re-implemented
  # here — this reads its verdict and prints it, because a second copy of a rule is the
  # fact-in-two-places defect and the copy that drifts is the one a careful agent obeys.
  # ⚠ IT CANNOT WRITE `status`. Not by policy here — by whitelist in the function, which answers
  # `status-has-its-own-verbs`. Do not add a convenience wrapper that maps it onto a lifecycle verb.
  # ⚠ `verification` TAKES A JSON ARRAY, so a multi-item list survives one shell argument intact:
  #     ledger-db.sh amend <id> verification '["first check","second check"]' "why"
  # The holder records why a lock is held, on the row (migration 182). Post-cutover the lock branch
  # carries no ticket file, so this is where feature-ticket.sh intent writes.
  # (fix_intent_refuses_every_post_cutover_claim_because_it_reads_a_ticket_file_the_lock_no_longer_carries)
  intent)   shift; _require_session_identity || exit 3
            _li_id="${1:-}"; _li_intent="${2:-}"; _li_note="${3:-}"
            [[ -n "$_li_id" && -n "$_li_intent" ]] || { echo "usage: ledger-db.sh intent <id> <building|holding|travelling> [<note>]" >&2; exit 2; }
            _li_nsql="NULL"; [[ -n "$_li_note" ]] && _li_nsql="'${_li_note//\'/\'\'}'"
            _as_me_verdict intent "select ledger.set_lock_intent('${_li_id//\'/\'\'}', '${_li_intent//\'/\'\'}', $_li_nsql)" ;;
  amend)    shift; _require_session_identity || exit 3
            _am_id="${1:-}"; _am_field="${2:-}"; _am_value="${3:-}"; shift 3 2>/dev/null || true
            _am_reason="$*"
            if [[ -z "$_am_id" || -z "$_am_field" || -z "${_am_value:-}" || -z "${_am_reason:-}" ]]; then
              echo "usage: ledger-db.sh amend <id> <field> <value> <why>" >&2
              echo "  fields: title notes user_visible_behavior verification verification_command area priority" >&2
              echo "  ⚠ status is NOT amendable — it has its own verbs (claim/park/flip-passing/groom)." >&2
              exit 2
            fi
            _as_me_verdict amend "select ledger.amend_requirement('${_am_id//\'/\'\'}', '${_am_field//\'/\'\'}', '${_am_value//\'/\'\'}', '${_am_reason//\'/\'\'}')" ;;
  # ⚠ GROOM PERFORMS THE PO'S `— → selected` TRANSITION, which docs/ledger-spec.md §3 allows and no
  # verb implemented — so until now the ready frontier could only be fed by the owner, and whole
  # families of tickets sat `not_started` and invisible to init.sh's "next". PO-only, and the role is
  # read from the ROSTER inside the function rather than hardcoded anywhere.
  # ⚠ A SESSION ENTRY IS A ROW (migration 190). The entry arrives as JSON on STDIN, never as an
  # argument: a body is free text and can be long, and one argv string is capped at 128 KB. The SQL
  # goes to psql on stdin for the same reason, with the JSON dollar-quoted under a random tag that
  # is checked absent from the payload, so nothing in the body needs escaping. The author is the
  # connection's role (session_user), never a field.
  # (infra_session_entries_live_in_the_ledger_database_and_the_progress_directory_is_frozen_history)
  session-entry) shift; _require_session_identity || exit 3
            _se_json="$(cat)"
            jq -e 'type == "object"' >/dev/null 2>&1 <<<"$_se_json" \
              || { echo "usage: <json object> | ledger-db.sh session-entry   (keys: title, body, ticket_id, branch, pr)" >&2; exit 2; }
            _se_tag="se_$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
            [[ "$_se_json" != *"\$${_se_tag}\$"* ]] || { echo "ledger-db: session-entry quoting tag collided — retry" >&2; exit 2; }
            _se_me="$(_conn_role)" || { echo "ledger-db: cannot tell who you are — GIT_AUTHOR_NAME is unset and no .agent/name here." >&2; exit 3; }
            _se_v="$(printf 'select ledger.write_session_entry($%s$%s$%s$::jsonb);\n' "$_se_tag" "$_se_json" "$_se_tag" \
                      | docker exec -i "$CONTAINER" psql -U "$_se_me" -d ledger -v ON_ERROR_STOP=1 -tA -f -)"; _se_rc=$?
            [[ -n "$_se_v" ]] && printf '%s\n' "$_se_v"
            (( _se_rc != 0 )) && exit "$_se_rc"
            verdict_is_success session-entry "$_se_v" ;;
  # The readers' helper: newest first, as a JSON array, optionally for one agent / since a time.
  session-entries) shift; _se_agent=""; _se_since=""; _se_limit=20; _se_mine=0
            while (( $# )); do case "$1" in
              --agent) _se_agent="${2:-}"; shift 2 ;;
              --since) _se_since="${2:-}"; shift 2 ;;
              --limit) _se_limit="${2:-}"; shift 2 ;;
              # --mine filters on the CONNECTION's role, the same identity the writer stamps, so a
              # reader asking "did I write one?" cannot be answered about somebody else.
              --mine)  _se_mine=1; shift ;;
              *) echo "usage: ledger-db.sh session-entries [--mine|--agent <name>] [--since <timestamptz>] [--limit <n>]" >&2; exit 2 ;;
            esac; done
            [[ "$_se_limit" =~ ^[0-9]{1,5}$ ]] || { echo "ledger-db: --limit must be a number" >&2; exit 2; }
            _se_w="true"
            [[ -n "$_se_agent" ]] && _se_w="$_se_w and agent = '${_se_agent//\'/\'\'}'"
            (( _se_mine )) && _se_w="$_se_w and agent = session_user"
            [[ -n "$_se_since" ]] && _se_w="$_se_w and written_at > '${_se_since//\'/\'\'}'::timestamptz"
            _as_me "select coalesce(json_agg(e order by e.written_at desc, e.id desc), '[]'::json) from (select * from ledger.v_session_entry where $_se_w order by written_at desc, id desc limit $_se_limit) e" ;;
  groom)    shift; _require_session_identity || exit 3
            _gr_id="${1:-}"; shift 2>/dev/null || true; _gr_reason="$*"
            [[ -n "$_gr_id" && -n "${_gr_reason:-}" ]] || { echo "usage: ledger-db.sh groom <id> <why>" >&2; exit 2; }
            _as_me_verdict groom "select ledger.groom_to_selected('${_gr_id//\'/\'\'}', '${_gr_reason//\'/\'\'}')" ;;
  # ⚠ CLEARS A MIRROR-REFUSAL STAMP — groom's sibling, the other PO act that puts a ticket back within
  # reach of the ready frontier. After the cutover nothing else can clear one (migration 176): a refused
  # mirror records neither its payload nor an event, so only a person who has read the row can say a
  # particular stamp meant nothing. PO-only, role read from the roster; the event keeps the stamp's reason.
  # (fix_a_mirror_refusal_stamp_has_no_clearing_path_after_the_cutover_so_a_refreshed_row_drops_off_the_frontier_for_good)
  clear-refusal) shift; _require_session_identity || exit 3
            _cr_id="${1:-}"; shift 2>/dev/null || true; _cr_reason="$*"
            [[ -n "$_cr_id" && -n "${_cr_reason:-}" ]] || { echo "usage: ledger-db.sh clear-refusal <id> <why>" >&2; exit 2; }
            _as_me_verdict clear-refusal "select ledger.clear_mirror_refusal('${_cr_id//\'/\'\'}', '${_cr_reason//\'/\'\'}')" ;;
  # ⚠ THE PO CLOSES A TICKET AS WON'T-DO. docs/ledger-spec.md §3 allows `any → wont_do` for the PO,
  # with a reason, and nothing here reached it — ledger.set_status could write the status but from
  # `parked` it dies on migration 58's park-columns CHECK. ledger.close_as_wont_do (migration 177)
  # is PO-only by roster, clears the park columns in the same update, refuses delivered work, and
  # leaves claimed_by so a holder can still `release`. Its refusals are printed in its own words.
  # (infra_the_po_has_no_verb_to_close_a_ticket_as_wont_do)
  wont-do)  shift; _require_session_identity || exit 3
            _wd_id="${1:-}"; shift 2>/dev/null || true; _wd_reason="$*"
            [[ -n "$_wd_id" && -n "${_wd_reason:-}" ]] || { echo "usage: ledger-db.sh wont-do <id> <why>" >&2; exit 2; }
            _as_me_verdict wont-do "select ledger.close_as_wont_do('${_wd_id//\'/\'\'}', '${_wd_reason//\'/\'\'}')" ;;
  # ⚠ RELEASE IS THE ONLY WAY A CLAIM ENDS, AND THERE IS NO HAND-OVER TO ANYONE.
  # An agent asserts only what it knows — that it is done. Who gets the work next is the Product
  # Owner's call, and `po-queue` below is where released work lands. Same no-WHO-argument rule as
  # every other verb here: the actor is `session_user` inside the procedure and cannot be typed.
  release)  shift; _require_session_identity || exit 3
            _r_id="$1"; shift; _r_reason="$*"
            _as_me_verdict release "select ledger.release_claim('${_r_id//\'/\'\'}', '${_r_reason//\'/\'\'}')" ;;
  # unpark had no database verb at all, which left `v_owner_blocked` naming blockers that were lifted.
  unpark)   shift; _require_session_identity || exit 3
            _u_id="$1"; shift; _u_reason="$*"
            _as_me_verdict unpark "select ledger.unpark('${_u_id//\'/\'\'}', '${_u_reason//\'/\'\'}')" ;;
  # ⚠ NOT `frontier`. v_frontier is what an AGENT may pick up; this adds the parked-and-ownerless
  # rows, which are the PO's to route and which an agent must never self-serve.
  # ⚠ WHO THE PRODUCT OWNER IS, READ FROM THE ROSTER AND NEVER HARDCODED. The role is data and it
  # has changed hands. Prints nothing when the roster does not hold exactly one active PO, because
  # "two" and "none" are different defects and neither is answered by picking one.
  po-owner) _as_me "select name from ledger.v_agent where role='product-owner' and active
                    and (select count(*) from ledger.v_agent where role='product-owner' and active)=1" ;;
  po-queue) _as_me "select id,status,area,left(title,70) from ledger.v_po_queue" ;;
  # ── the owner's questions, and the only shell path that can answer one ────────────────────────
  #
  # ⚠⚠ THESE TWO VERBS EXIST BECAUSE THE QUEUE COULD ONLY GROW. `ledger.add_comment` and
  # `ledger.review_comment` were correct, granted to ledger_agent, and reachable from the admin
  # ticket page — but the people who ANSWER the owner are agents in a shell, and the shell had no
  # verb. So answers went into chat sessions, nothing recorded them where the tool reads, and
  # po-morning-brief.sh re-listed the same five comments for ever. Measured 2026-09-02:
  # 5 owner comments, 0 ever reviewed, in the lifetime of the table.
  # (infra_the_owners_comment_queue_can_only_grow_because_review_comment_has_no_caller)
  #
  # ⚠ THE TICKET SAID "no caller" AND THAT WAS A GREP ARTEFACT, worth recording so the next reader
  # does not re-derive it: it searched for `ledger.review_comment(`, and this codebase calls
  # procedures by passing the NAME AS A STRING to a generic caller (LedgerDb.cs). The pattern could
  # not match the real call site. A negative result inherits every blind spot of its method.
  # ⚠ ledger.v_comment, NOT ledger.comment. `ledger_agent` has SELECT on the view and NOT on the
  # base table — checked, not assumed: has_table_privilege says t for the view and f for the
  # table. Reading the table here fails with `permission denied` for every caller but the owner
  # role, which is exactly the caller this path is not for.
  comments) shift
            # ⚠ THE SEQ IS THE POINT. An answerer cannot act on a row it cannot identify, and the
            # brief prints prose. Without this read verb the write verb below is unusable.
            #
            # ── ⚠⚠ THE BODY IS RETURNED WHOLE. IT USED TO BE CUT AT 80 CHARACTERS ────────────────
            # (fix_the_owners_comment_is_truncated_to_eighty_characters_so_the_po_cannot_read_it)
            #
            # This read `left(replace(c.body, E'\n',' '), 80)`. The owner's comment on
            # fix_reminder_snooze_should_not_open_app ran to 193 characters and the PO saw:
            #     any interaction with the notification on the lock screen requires I unlock the p
            # ⚠ THE TRUNCATED HALF WAS THE SYMPTOM AND THE MISSING HALF WAS THE DIAGNOSIS — the
            # sentence naming the fault ("there are no snooze buttons or session lists … just the
            # notification title") was in the part that was cut. Read short, it is a complaint about
            # unlocking; read whole, it locates a defect in our own notification.
            #
            # ⚠ 80 IS A DISPLAY WIDTH AND IT WAS BEING APPLIED TO THE CONTENT. The cut was in the
            # SQL, so the full body never left the database — no wider terminal, pager or renderer
            # could recover it (driven: COLUMNS=400 changes nothing). Measured on the live store:
            # 9 of 14 comments exceed 80 characters, so this was most of what has ever been written
            # through the owner's only inbound channel.
            #
            # ⚠ NEWLINES ARE RENDERED, NOT DROPPED, AND THAT IS A DELIBERATE CHOICE RATHER THAN THE
            # OLD FLATTENING SURVIVING. Output is one row per comment (`psql -tA`), so a raw newline
            # would split one comment across lines and no reader could tell where a body ended.
            # `⏎` keeps one row per comment AND says a line break was there — the old
            # `replace(…, ' ')` silently claimed the text was one line. Nothing parses this output
            # (checked: `ledger-db.sh comments` has ZERO external callers; po-morning-brief.sh
            # re-queries ledger.v_comment itself), so the shape is free to serve the person reading.
            _c_id="${1-}"
            if [[ -n "$_c_id" ]]; then
              _as_me "select c.seq, c.ticket_id, c.author, coalesce(to_char(c.at,'DD Mon HH24:MI'),'-'),
                             case when c.reviewed_at is null then 'UNREVIEWED' else 'reviewed' end,
                             replace(c.body, E'\n', ' ⏎ ')
                        from ledger.v_comment c
                       where c.ticket_id = '${_c_id//\'/\'\'}' order by c.seq"
              _c_rc=$?
              # ⚠ AN EMPTY RESULT MUST SAY WHICH POPULATION IT JUST SHOWED YOU. Silence cannot tell
              # "this ticket has no comments" from "that id does not exist" — and rc=0 with no rows
              # reads as both.
              #
              # ⚠⚠ AND THOSE TWO ARE SEPARATED HERE RATHER THAN COLLAPSED, because collapsing them
              # is the defect this ticket is about, one level down. The first version of this said
              # "that is the ticket's whole comment history" for ANY empty result — which ASSERTS
              # THE TICKET EXISTS. Driven on `zz_no_such_ticket_at_all`: it confidently reported
              # that a ticket which does not exist has no comments.
              if [[ "$_c_rc" == 0 ]] && [[ -z "$(_as_me "select 1 from ledger.v_comment where ticket_id = '${_c_id//\'/\'\'}' limit 1")" ]]; then
                if [[ -z "$(_as_me "select 1 from ledger.v_ticket where id = '${_c_id//\'/\'\'}' limit 1")" ]]; then
                  echo "  no ticket '${_c_id}' — so this is not an empty comment history, it is an id that matches nothing." >&2
                else
                  echo "  no comments on '${_c_id}' — that is the ticket's whole comment history, not a filter." >&2
                fi
              fi
              exit "$_c_rc"
            else
              _as_me "select c.seq, c.ticket_id, c.author, coalesce(to_char(c.at,'DD Mon HH24:MI'),'-'),
                             replace(c.body, E'\n', ' ⏎ ')
                        from ledger.v_comment c
                       where c.author_kind = 'owner' and c.reviewed_at is null order by c.seq"
              _c_rc=$?
              # ⚠ THE NO-ARGUMENT FORM SHOWS ONLY *UNREVIEWED OWNER* COMMENTS, and its silence used
              # to be indistinguishable from "you gave me no id". Say which population answered.
              [[ "$_c_rc" == 0 ]] && [[ -z "$(_as_me "select 1 from ledger.v_comment where author_kind = 'owner' and reviewed_at is null limit 1")" ]] \
                && echo "  no UNREVIEWED owner comments. (This form shows only those — pass a ticket id for that ticket's full history.)" >&2
              exit "$_c_rc"
            fi ;;
  # ⚠ ONE VERB, NOT TWO, AND THAT IS THE WHOLE DESIGN. Marking an owner's question reviewed without
  # recording the answer where he asked REMOVES THE QUESTION AND LEAVES HIM NO BETTER OFF — the
  # receipt would clear his queue while the answer stayed in a chat log. So this records the reply
  # and the receipt together, and there is deliberately no bare `review` verb to reach for.
  #
  # ⚠ THEY REMAIN TWO SIGNALS IN THE DATA. Migration 44 is explicit that `review_comment` must NOT
  # produce `answered`: "has the PO read this" and "has it been answered" are different questions.
  # Coupling the ACTION is not collapsing the STATE.
  answer)   shift; _require_session_identity || exit 3
            _a_seq="${1-}"; shift || true; _a_body="$*"
            [[ "$_a_seq" =~ ^[0-9]+$ ]] || { echo "ledger-db: answer <seq> <text> — seq must be a number (see: ledger-db.sh comments)" >&2; exit 64; }
            [[ -n "${_a_body//[[:space:]]/}" ]] || { echo "ledger-db: answer <seq> <text> — refusing an empty answer; the reply IS the deliverable" >&2; exit 64; }
            # ⚠ VALIDATE BEFORE WRITING, so a bad seq cannot half-apply: add_comment would land a
            # reply on a ticket that has nothing to answer, and review_comment would then fail.
            _a_tid="$(_as_me "select ticket_id from ledger.v_comment where seq=${_a_seq} and author_kind='owner' and reviewed_at is null")" || exit 3
            [[ -n "${_a_tid//[[:space:]]/}" ]] || { echo "ledger-db: seq ${_a_seq} is not an unreviewed owner comment — nothing to answer" >&2; exit 64; }
            _as_me "select ledger.add_comment('${_a_tid//\'/\'\'}', '${_a_body//\'/\'\'}'); select ledger.review_comment(${_a_seq});" \
              && echo "answered ${_a_tid} (comment ${_a_seq}) — reply recorded and the question marked reviewed" ;;
  # ⚠ THE OWNER STATE TRAVELS WITH THE OWNER, because a name alone cannot say whether anyone is
  # coming back for the work. Measured 2026-09-05: `infra_turn_on_the_db_first_write_path...` showed
  # here as `Don` -- an ordinary live claim -- while Don had been offboarded three days earlier. It
  # was absent from v_frontier, so nobody was offered it either. **A plausible owner closes the
  # question that an absence would have opened**, which is why this is worse than a blank.
  # `owner_state` is NULL for an unclaimed row and 'active' for the normal case; both print bare, so
  # the board only gains ink where something is actually wrong. (migration 105)
  board)    _as_me "select id,area,coalesce(claimed_by,'-')||case when owner_state in ('departed','not-an-agent') then '  <= '||upper(owner_state)||', NOBODY IS COMING BACK' else '' end from ledger.v_claims order by claimed_at" ;;
  # the enumerable form of the same fact, for a re-routing pass (v_park_without_owner's analogue)
  orphans)  _as_me "select id,area,claimed_by,owner_state from ledger.v_claim_without_a_live_owner order by claimed_at" ;;
  frontier) _as_me "select id,area,priority from ledger.v_frontier order by priority,id" ;;
  # ⚠ THE ASK, NOT THE REASON, AND NOT TRUNCATED. This line read `left(parked_reason,60)` — a field
  # written for tools, cut mid-word. The live example was `UNPARK WHEN: the owner has bought Pavel's
  # Enter the Kettlebe`. `park_summary` is the one-line ask written FOR HIM, capped at 400 by
  # `park_summary_verdict`, and the longest in the corpus is 396: at 60 it is destroyed, not
  # shortened. (migration 88)
  # ⚠ AND AN ABSENT ASK SAYS SO. Falling back silently to the reason would make "nobody wrote one"
  # indistinguishable from "here it is" — and 56 of 67 live parks had no summary the morning this
  # was written, so that is the common case, not the edge.
  waiting)  _as_me "select id,coalesce(claimed_by,'-'),coalesce(park_summary,'(no ask) '||left(parked_reason,60)) from ledger.v_owner_blocked" ;;
  # ⚠ THE BOARD WAS BEING POPULATED AND SHOWN TO NOBODY. init.sh attaches the stack to the ledger
  # and syncs it at every session start, and then prints not one line of what it says. An agent
  # therefore MAINTAINS the database and never reads it, which is the whole distance between "the
  # ledger exists" and "agents use the ledger". This is the two lines that close that.
  # ⚠ DELIBERATELY NOT A REPLACEMENT FOR init.sh's OWN "next" LIST. That list carries rules the
  # board does not have (raise-branches are not claims; an epic whose children are all terminal must
  # be withheld), and swapping it for `v_frontier` would trade correctness for tidiness. Additive.
  summary)  _as_me "
      -- ⚠ v_claims, NOT ledger.ticket. The agent role can read the VIEWS and is DENIED on the base
      -- table — 'permission denied for table ticket', which is the grant design working exactly as
      -- ⚠⚠ NOT ONE BACKTICK ANYWHERE IN THIS STRING, AND THE SECOND ATTEMPT PROVED WHY. This block
      -- is a DOUBLE-QUOTED bash string, so a backtick is COMMAND SUBSTITUTION, not markdown. The
      -- original quoted the Postgres error in backticks and bash ran it: every call printed
      -- 'line 737: permission: command not found' and the words vanished from the comment. My FIRST
      -- fix then wrote an explanation OF that trap using backticks, in the same string, and printed
      -- 'line 737: ledger-db.sh:: command not found' instead. The comment describing the hazard fell
      -- into the hazard. Prose in an executable string is executable; quote it with apostrophes. This block is a DOUBLE-QUOTED bash string, so backticks in it
      -- are COMMAND SUBSTITUTION, not markdown. The quoted error message was executed: every call
      -- printed 'ledger-db.sh: line 737: permission: command not found' to stderr, and the words
      -- vanished from the comment. Harmless only because it is a comment and because init.sh filters
      -- with 'grep -E '^ledger: '' — so the noise was invisible exactly where the feature is used and
      -- visible to anyone running the command directly. Found by RUNNING it while verifying the
      -- ticket, not by reading it.
      -- intended and which a query written from the schema rather than from the role would miss.
      select 'ledger: you hold ' || (select count(*) from ledger.v_claims
                                      where claimed_by = '$(_me)')
          || ' | waiting on the owner: ' || (select count(*) from ledger.v_owner_blocked)
          || ' | free to pick up: '      || (select count(*) from ledger.v_frontier)" ;;
  *) echo "usage: ledger-db.sh {attach|mirror <id>|sync [--unattended] [--since-last] [--worktree]|freshness [--quiet]|export [--write]|regenerate [--out DIR] {--all|<id>...}|whoami|ping|ticket-row <id>|ticket-owner <id>|ticket-grep <ere>|board|orphans|frontier|po-queue|po-owner|comments [<id>]|answer <seq> <text>|waiting|release <id> <why>|unpark <id> <why>|archive <id> <why>|record-issue <id> <n>|amend <id> <field> <value> <why>|intent <id> <building|holding|travelling> [<note>]|groom <id> <why>|session-entry (JSON on stdin)|session-entries [--mine|--agent A] [--since T] [--limit N]|clear-refusal <id> <why>|stand-down <id> <why>|flip-passing <id> <pr>|raise <file.json>|wont-do <id> <why>|raise-epic <file.json>}" >&2;
     # ⚠ A BEHIND copy may simply not HAVE this verb yet — say so, rather than letting "usage" read as "no such verb".
     [[ "${STALE_TOOL_BEHIND:-0}" == 1 && -n "${1:-}" ]] && printf 'ledger-db: ⚠ '"'"'%s'"'"' is not a verb in THIS copy, which is BEHIND origin/main — it may exist there. Run it from a checkout of origin/main.\n' "$1" >&2
     exit 64 ;;
esac
