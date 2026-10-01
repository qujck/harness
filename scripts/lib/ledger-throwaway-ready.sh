# shellcheck shell=bash
# When is a throwaway ledger postgres actually usable?
# (infra_the_throwaway_ledger_gates_redden_prs_whose_diffs_cannot_cause_it)
#
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# ⚠ `pg_isready` ANSWERS A DIFFERENT QUESTION FROM THE ONE THE GATES ASK.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# It reports whether the SERVER accepts connections. It does not check that the named database
# exists, and it cannot know that the server it just answered for is about to be stopped —
# postgres:16's entrypoint runs a TEMPORARY server for its init scripts, stops it, and then starts
# the real one.
#
# So there is a window in which `pg_isready -d ledger` says READY and `psql -d ledger` fails. Seven
# gates broke their wait loop on the first `pg_isready` success, never asserted the loop had
# succeeded, and went straight into applying migrations against that.
#
# ── DRIVEN 2026-09-08 (Anthony), not inferred from a log ────────────────────────────────────────
# Polling both signals every 0.1s from container start, three runs, one container, idle box:
#
#     0.09s  notready/FAIL   …failed: No such file or directory
#     0.47s  READY/FAIL      …failed: FATAL:  database "ledger" does not exist
#     0.68s  notready/OK     <- the temporary server being stopped
#     0.89s  READY/OK
#
#     window width: 0.19s, 0.20s, 0.40s
#
# ⚠ ONE MECHANISM, BOTH RECORDED SYMPTOMS. Where your query lands in that window decides which
# message you get: early gives `database "ledger" does not exist`, later gives `the database system
# is shutting down`. They were logged as two unrelated sightings on two different gates.
#
# ⚠ AND THE FAILURE ITSELF IS REPRODUCED, WHICH THE ORIGINAL DIAGNOSIS COULD NOT DO — it named the
# mechanism honestly and said so: "I did NOT reproduce the CI flake locally". Running the seven
# gates' exact loop (1s interval, break on first success), two independent rounds of ten:
#
#     unfixed, serial       n=20:  0 failed
#     unfixed, concurrent   n=20:  4 failed   (1 of 10, then 3 of 10)
#     THIS PREDICATE, conc. n=20:  0 failed   (0 of 10, twice)
#
# ⚠ AND ONE ROUND PRODUCED BOTH RECORDED SIGNATURES AT ONCE — two containers said "FATAL:  the
# database system is shutting down" and one said "FATAL:  database \"ledger\" does not exist". That
# is the single clearest piece of evidence that the two sightings are one mechanism.
#
# Contention did not create the fault. It widened the window in which it was visible, exactly as
# CLAUDE.md says — and "it passed when I ran it alone" is the closed window, not the diagnosis:
# the same loop failed 0 of 20 serially and 4 of 20 concurrently.
#
# ⚠ HONEST LIMIT ON THE 0-of-20: it is supporting evidence, not the argument. The argument is the
# MECHANISM — three consecutive real queries a second apart cannot be satisfied by a server across
# its own shutdown, so the predicate cannot return early into the window by construction. A rate
# comparison at n=20 could not carry that on its own and is not asked to.
#
# ── ⚠ WHY THIS IS A LIBRARY AND NOT A FIX IN ONE GATE ───────────────────────────────────────────
# It WAS a fix in one gate. fix_the_mirror_guard_gate_reports_could_not_look_on_a_different_migration_each_run
# named this mechanism correctly and repaired
# check-mirror-normalises-the-shaped-extra-keys.sh — and the other seven kept the old shape, because
# the readiness loop was copied into every gate rather than shared. That is the same reasoning
# lib/ledger-throwaway-sweep.sh was created for, one defect further along.
#
# ⚠ THIS IS NOT A REGRESSION OF `fix_the_throwaway_ledger_gates_share_one_container_name` OR OF
# `fix_two_overlapping_ledger_gates_on_one_daemon_delete_each_others_containers`. Both are archived
# and both are about a container going MISSING; this is about a container that is PRESENT and whose
# database is not yet usable. Starting from "the sweep did it" burns an afternoon.
#
# ── THE CONTRACT ────────────────────────────────────────────────────────────────────────────────
#   ledger_throwaway_ready <container> [tries] [needed]
#       0  -> the database answered `needed` (default 3) CONSECUTIVE real queries, one second
#             apart. A temporary server cannot satisfy three in a row across its own shutdown.
#       1  -> it did not, within `tries` (default 60) seconds. $LEDGER_READY_LAST_ERROR holds the
#             server's own last words.
#
# ⚠ THE CALLER MUST TREAT 1 AS **CANNOT TELL (exit 2)**, NEVER AS A FINDING. A gate that cannot
# reach its own database has learned nothing about the diff, and the seven unfixed gates said
# `FAIL … did not apply` and exited 1 — a verdict about somebody's PR. That is the half that cost
# the time: agents were sent to look at a diff of two markdown files.
#
# ── ⚠ THE ONE CALLER DELIBERATELY NOT FOLDED IN, NAMED SO IT DOES NOT READ AS AN OVERSIGHT ──────
# `scripts/check-stranded-census-measures-database-age.sh` waits on a throwaway postgres too, and it
# is NOT a copy of this predicate: it connects as `strength` to the `postgres` database, and its
# wait is TWO successes half a second apart rather than three a second apart. It is a sibling asking
# a different question, not a straggler. Generalising this library's user and database for one
# caller would buy nothing and would make the contract vaguer for the other ten.
#
# ⚠ IT IS NOT A RETRY, A LONGER TIMEOUT, OR SERIALISATION. Those close the window and leave the
# defect. This replaces a signal that answers the wrong question with one that answers the right
# one; the bound is unchanged at 60s and nothing is re-run.

# Pure: given a run of consecutive successes, are we there yet?
ledger_ready_verdict() { # <streak> <needed> -> ready | waiting | unreadable
  local s="${1-}" n="${2-}"
  [[ "$s" =~ ^[0-9]+$ && "$n" =~ ^[1-9][0-9]*$ ]] || { printf 'unreadable'; return; }
  if (( s >= n )); then printf 'ready'; else printf 'waiting'; fi
}

LEDGER_READY_LAST_ERROR=""

ledger_throwaway_ready() { # <container> [tries] [needed]
  local c="${1-}" tries="${2:-60}" needed="${3:-3}"
  local streak=0 i err
  LEDGER_READY_LAST_ERROR=""
  [[ -n "$c" ]] || { LEDGER_READY_LAST_ERROR="no container name given"; return 1; }
  for ((i = 0; i < tries; i++)); do
    if err="$(docker exec "$c" psql -U ledger_owner -d ledger -tAc 'select 1' 2>&1)"; then
      streak=$((streak + 1))
      [[ "$(ledger_ready_verdict "$streak" "$needed")" == ready ]] && return 0
    else
      # ⚠ KEEP THE LAST FAILURE, NOT THE FIRST. The first is always "socket does not exist yet",
      # which is normal startup and tells the next reader nothing. The last one is the server's
      # account of why it never settled, and it is the whole reason this is worth printing.
      LEDGER_READY_LAST_ERROR="$(head -1 <<<"$err")"
      streak=0
    fi
    sleep 1
  done
  [[ -n "$LEDGER_READY_LAST_ERROR" ]] \
    || LEDGER_READY_LAST_ERROR="no error text — the server answered but never ${needed} times in a row"
  return 1
}

# Print the CANNOT TELL line a caller should die with, so the wording cannot drift between gates.
ledger_throwaway_cannot_look() { # <gate-name>
  printf '%s: COULD NOT LOOK — the throwaway postgres never became stably usable. NOT a pass, and NOT a finding about your diff.\n' "${1-a ledger gate}" >&2
  printf '  the database said: %s\n' "${LEDGER_READY_LAST_ERROR:-<nothing>}" >&2
  printf '  (pg_isready answers a different question — see scripts/lib/ledger-throwaway-ready.sh)\n' >&2
}

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# ⚠ THE SECOND SHAPE: A THROWAWAY WHOSE MIGRATIONS ARE APPLIED BY THE IMAGE'S OWN INITDB, AND WHY
#   `ledger_throwaway_ready` ABOVE IS NOT SAFE FOR IT.
# (infra_the_slow_static_gates_in_verify_read_the_tree_once_instead_of_line_by_line)
# ═══════════════════════════════════════════════════════════════════════════════════════════════
#   ledger_throwaway_initdb_ready <container> [limit_s]
#       0  -> the REAL server answered `select 1` over TCP, so init has finished
#       1  -> the container stopped, is gone, or `limit_s` (default 180) passed.
#             $LEDGER_READY_LAST_ERROR holds the last error text.
#
# Twenty-one gates bring up infra/ledger-db/docker-compose.yml, which mounts the migrations at
# /docker-entrypoint-initdb.d. They waited for `{{.State.Health.Status}} == healthy`, and that
# compose file's healthcheck runs every 10s, so a gate could not start before ~10s. The database
# was usable long before that. DRIVEN 2026-09-27 against one gate-shaped container:
#
#     1.86s  a socket query works  <- the TEMPORARY server, still applying the migrations
#     3.43s  a TCP query works, and the log says "PostgreSQL init process complete"
#    10.74s  healthy
#
# ⚠ THE SOCKET READING IS THE TRAP. Everything in initdb runs on that temporary server, so three
# socket queries a second apart CAN all succeed while migrations are still being applied — the
# predicate above is sound only because its callers apply their migrations AFTER it returns. Here
# the image applies them first. The temporary server is started with listen_addresses='' (the
# postgres image's docker_temp_server_start), so it takes NO TCP connection: a query over
# 127.0.0.1 can be answered only by the real server, which starts only after init has finished.
#
# ⚠ AND IT FAILS FAST WHERE THE HEALTH LOOP COULD NOT. A migration that errors stops the
# entrypoint and the container EXITS. An exited container keeps its last health status, so the
# health loop polled it until its 180s deadline. This returns as soon as the container is not
# running, and the caller's `throwaway_health_message` then says "STARTED AND THEN EXITED".
# Measured: a broken migration returned in 2s.
ledger_throwaway_initdb_ready() { # <container> [limit_s]
  local c="${1-}" limit="${2:-180}" deadline err state
  LEDGER_READY_LAST_ERROR=""
  [[ -n "$c" ]] || { LEDGER_READY_LAST_ERROR="no container name given"; return 1; }
  deadline=$(( SECONDS + limit ))
  while (( SECONDS < deadline )); do
    if err="$(docker exec "$c" psql -h 127.0.0.1 -U ledger_owner -d ledger -tAc 'select 1' 2>&1)"; then
      return 0
    fi
    LEDGER_READY_LAST_ERROR="$(head -1 <<<"$err")"
    state="$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null)"
    [[ "$state" == running || "$state" == created ]] || return 1
    sleep 0.25
  done
  return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  # ⚠ THE SHARED FLAG CONTRACT, AND IT IS SOURCED **INSIDE** THE DIRECT-EXECUTION GUARD. A sourced
  # file that touches argv reads its CALLER'S argv — scripts/lib/janitor.sh once answered
  # feature-ticket.sh's own `--self-test` with its own suite and exited 0, silently replacing a real
  # gate with an easier one. Keeping the source in here means sourcing this library defines the two
  # functions above and nothing else. (chore_unify_selftest_flag_spelling)
  # Sibling path: from inside scripts/lib/ there is no `lib/` left to traverse.
  # shellcheck disable=SC1090
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/selftest-flag.sh"
  selftest_requested "$@" || { printf 'usage: %s [--self-test]\n' "$(basename -- "$0")" >&2; exit 2; }
  _f=0; _n=0
  _t() { _n=$((_n+1)); if [[ "$2" == "$3" ]]; then printf '  ok %d - %s\n' "$_n" "$1"
         else printf '  NOT OK %d - %s (want %q got %q)\n' "$_n" "$1" "$2" "$3"; _f=$((_f+1)); fi; }

  _t "a streak below the bar is waiting"            waiting    "$(ledger_ready_verdict 2 3)"
  _t "exactly the bar is ready (boundary)"          ready      "$(ledger_ready_verdict 3 3)"
  _t "above the bar is ready"                       ready      "$(ledger_ready_verdict 9 3)"
  _t "zero is waiting, never ready"                 waiting    "$(ledger_ready_verdict 0 3)"
  # ⚠ A NEEDED OF ZERO WOULD MAKE EVERY CONTAINER INSTANTLY READY — the exact defect being fixed,
  # reintroduced through the back door. It is refused rather than clamped.
  _t "needed=0 is unreadable, not 'ready'"          unreadable "$(ledger_ready_verdict 5 0)"
  _t "a non-numeric streak is unreadable"           unreadable "$(ledger_ready_verdict x 3)"
  _t "an empty needed is unreadable"                unreadable "$(ledger_ready_verdict 5 '')"

  ledger_throwaway_ready "" 1 3 && _t "an empty container name returns 1" fail pass \
                                || _t "an empty container name returns 1" pass pass
  _t "…and it says why" "no container name given" "$LEDGER_READY_LAST_ERROR"

  # ⚠ THE DOCKER ARM IS DRIVEN WHEN A DAEMON IS REACHABLE AND ANNOUNCED WHEN IT IS NOT. A silently
  # skipped arm is the vacuous pass this whole library is about.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    _c="ledger-ready-selftest-$$"
    docker rm -f "$_c" >/dev/null 2>&1
    if docker run -d --name "$_c" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=ledger \
         -e POSTGRES_USER=ledger_owner postgres:16 >/dev/null 2>&1; then
      if ledger_throwaway_ready "$_c" 90 3; then _t "a real container becomes stably ready" pass pass
      else _t "a real container becomes stably ready" pass "fail: $LEDGER_READY_LAST_ERROR"; fi
      # ⚠ NEGATIVE CONTROL: against a container that is GONE it must fail and keep the server's words,
      # never hang and never report ready.
      docker rm -f "$_c" >/dev/null 2>&1
      ledger_throwaway_ready "$_c" 2 3 && _t "a removed container is NOT ready" fail pass \
                                       || _t "a removed container is NOT ready" pass pass
      [[ -n "$LEDGER_READY_LAST_ERROR" ]] && _t "…and it kept the error text" pass pass \
                                          || _t "…and it kept the error text" pass fail
    else
      printf '  SKIP - could not start postgres; the docker arms did not run\n'
    fi
    docker rm -f "$_c" >/dev/null 2>&1
  else
    printf '  SKIP - no reachable docker daemon; the docker arms did not run (this is announced, not swallowed)\n'
  fi

  ledger_throwaway_initdb_ready "" 1 && _t "initdb: an empty container name returns 1" fail pass \
                                     || _t "initdb: an empty container name returns 1" pass pass
  _t "…and it says why" "no container name given" "$LEDGER_READY_LAST_ERROR"

  # ⚠ THE INITDB ARMS RUN THE REAL SCHEMA THROUGH THE IMAGE'S OWN INITDB, the way the 21 gates do.
  # The property under test is WHEN it returns: never before init has finished, which is the one
  # thing a socket query cannot promise.
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    # ⚠ THE *.sql FILES ONLY, COPIED, EXACTLY AS THE GATES DO. Mounting infra/ledger-db itself also
    # hands the entrypoint backup.sh, which it RUNS, and the container exits — found by this arm's
    # first run, which the fast-fail path reported as "not running" in seconds.
    _schema="$(mktemp -d)"
    cp "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"/infra/ledger-db/*.sql "$_schema/"
    chmod 755 "$_schema"; chmod 644 "$_schema"/*.sql
    _c="ledger-initdb-selftest-$$"
    docker rm -f "$_c" >/dev/null 2>&1
    if docker run -d --name "$_c" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=ledger -e POSTGRES_USER=ledger_owner \
         -v "$_schema:/docker-entrypoint-initdb.d:ro" postgres:16-alpine >/dev/null 2>&1; then
      if ledger_throwaway_initdb_ready "$_c" 180; then
        _t "initdb: a real schema becomes ready" pass pass
        _t "…and ONLY once init had finished" 1 \
           "$(docker logs "$_c" 2>&1 | grep -c 'PostgreSQL init process complete')"
      else
        _t "initdb: a real schema becomes ready" pass "fail: $LEDGER_READY_LAST_ERROR"
      fi
      # ⚠ NEGATIVE CONTROL: a container that is GONE returns 1 at once and keeps the daemon's words.
      docker rm -f "$_c" >/dev/null 2>&1
      _s=$SECONDS
      ledger_throwaway_initdb_ready "$_c" 30 && _t "initdb: a removed container is NOT ready" fail pass \
                                             || _t "initdb: a removed container is NOT ready" pass pass
      _t "…without waiting out its limit" fast "$( (( SECONDS - _s < 10 )) && echo fast || echo "slow: $((SECONDS - _s))s")"
    else
      printf '  SKIP - could not start postgres:16-alpine; the initdb schema arms did not run\n'
    fi
    docker rm -f "$_c" >/dev/null 2>&1
    rm -rf "$_schema"
    # ⚠ A MIGRATION THAT ERRORS STOPS THE ENTRYPOINT AND THE CONTAINER EXITS. The health loop this
    # replaces could not see that and polled to its 180s deadline; this must come back NOT READY,
    # and quickly.
    _bad="$(mktemp -d)"
    printf 'select no_such_function_planted_by_the_selftest();\n' > "$_bad/01-broken.sql"
    chmod 755 "$_bad"; chmod 644 "$_bad/01-broken.sql"
    if docker run -d --name "$_c" -e POSTGRES_PASSWORD=x -e POSTGRES_DB=ledger -e POSTGRES_USER=ledger_owner \
         -v "$_bad:/docker-entrypoint-initdb.d:ro" postgres:16-alpine >/dev/null 2>&1; then
      _s=$SECONDS
      ledger_throwaway_initdb_ready "$_c" 120 && _t "initdb: a broken migration is NOT ready" fail pass \
                                              || _t "initdb: a broken migration is NOT ready" pass pass
      _t "…and says so without waiting out its limit" fast "$( (( SECONDS - _s < 60 )) && echo fast || echo "slow: $((SECONDS - _s))s")"
    else
      printf '  SKIP - could not start postgres:16-alpine; the broken-migration arm did not run\n'
    fi
    docker rm -f "$_c" >/dev/null 2>&1
    rm -rf "$_bad"
  else
    printf '  SKIP - no reachable docker daemon; the initdb arms did not run (this is announced, not swallowed)\n'
  fi

  # ⚠ THE ARM THE CONTRACT GATE ASKS FOR BY NAME: assert that SOURCING this file with a flag in argv
  # consumes nothing. Without it the direct-execution guard is a comment somebody can drop, and the
  # failure mode is a library answering its caller's `--self-test` with its own suite and exiting 0.
  _src="$( set -- --self-test
           # shellcheck disable=SC1090
           . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/ledger-throwaway-ready.sh"
           printf '%s' "${1-<gone>}" )"
  _t "sourcing with --self-test in argv consumes nothing" "--self-test" "$_src"

  printf '%d arms, %d failed\n' "$_n" "$_f"
  [[ "$_f" -eq 0 ]]
fi
