#!/usr/bin/env bash
# scripts/lib/ticket-store.sh — the ticket store is an ADAPTER behind one verb set.
# (feat_harness_the_ledger_is_a_database_with_raise_groom_claim_amend_flip_archive_and_release_verbs)
#
# Sourced by scripts/ledger-db.sh; parses no arguments. Reads TICKET_STORE (harness.env, via
# scripts/lib/harness-env.sh) and tells the caller which implementation answers:
#     db    — the ledger database (this child; the port of the project this template was seeded from)
#     jira  — a Jira project (feat_harness_jira_is_a_ticket_store_behind_the_same_verbs)
#
# ⚠ THE VERB SET IS THE CONTRACT, NOT THE STORE. Every store answers the same verbs with the same
# verdict strings (ok / ok:<n> / exists:<store> / refused:<why> / unknown-parent:<id> …), so a script
# built on `ledger-db.sh raise` works unchanged when TICKET_STORE flips. A store that lacks a verb says
# so — `ticket_store_unsupported` prints the refusal and exits 2 — and never silently succeeds.
# (A silent success is how a flag typo once replaced a gate with one that always passed: METHOD.md.)
TICKET_STORE_VERBS="raise raise-epic groom claim park unpark release amend flip-passing archive wont-do \
frontier exists search ticket-row ticket-owner ticket-grep whoami ping board waiting summary comments answer \
po-owner po-queue record-issue intent session-entry session-entries sync-agent-roles clear-refusal stand-down orphans"

# ticket_store_name -> db | jira, or exits 2 for anything else
ticket_store_name() {
  case "${TICKET_STORE:-db}" in
    db|jira) printf '%s\n' "${TICKET_STORE:-db}" ;;
    *) echo "ticket-store: TICKET_STORE='${TICKET_STORE}' is not a store this harness knows (db | jira) — set it in harness.env" >&2; exit 2 ;;
  esac
}

# ticket_store_is_verb <word> -> 0 if the word is one of the shared verbs
ticket_store_is_verb() {
  local v; for v in $TICKET_STORE_VERBS; do [[ "$v" == "$1" ]] && return 0; done; return 1
}

# ticket_store_unsupported <store> <verb> — the refusal for a verb this store has not implemented
ticket_store_unsupported() {
  echo "ticket-store: '$2' is not supported by the '$1' store — not a silent pass: the verb exists in the contract, this store lacks it" >&2
  exit 2
}

# ticket_store_dispatch_jira <verb> [args…] — hands a verb to the Jira adapter when it has landed,
# and refuses honestly until then. ledger-db.sh calls this FIRST when TICKET_STORE=jira.
ticket_store_dispatch_jira() {
  local impl="${HARNESS_ROOT:-.}/scripts/lib/ticket-store-jira.sh"
  if [[ -x "$impl" ]]; then exec bash "$impl" "$@"; fi
  echo "ticket-store: TICKET_STORE=jira, but the Jira adapter (scripts/lib/ticket-store-jira.sh) has not landed in this checkout — it arrives with \`feat_harness_jira_is_a_ticket_store_behind_the_same_verbs\`. Set TICKET_STORE=db, or land that child." >&2
  exit 2
}

# ── self-test (run by scripts/ledger-db.sh --self-test, not by its own flag: this file is sourced) ──
ticket_store_self_test() {
  local fails=0
  _ts() { local d="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then printf '  ok    %s\n' "$d"; else printf '  FAIL  %s (want %q got %q)\n' "$d" "$want" "$got"; fails=1; fi; }
  _ts "the default store is db"                      db   "$(TICKET_STORE= ticket_store_name)"
  _ts "jira is a known store"                        jira "$(TICKET_STORE=jira ticket_store_name)"
  _ts "an unknown store exits 2"                     2    "$( (TICKET_STORE=filing-cabinet ticket_store_name >/dev/null 2>&1); echo $?)"
  _ts "raise is a contract verb"                     0    "$(ticket_store_is_verb raise; echo $?)"
  _ts "a made-up word is not"                        1    "$(ticket_store_is_verb frobnicate; echo $?)"
  _ts "an unsupported verb exits 2, loudly"          2    "$( (ticket_store_unsupported db frobnicate >/dev/null 2>&1); echo $?)"
  _ts "jira without its adapter refuses with 2, naming the child" 2 "$( (HARNESS_ROOT=/nonexistent ticket_store_dispatch_jira raise >/dev/null 2>&1); echo $?)"
  (( fails == 0 )) && printf '  ok    ticket-store adapter: %d verbs in the contract\n' "$(wc -w <<<"$TICKET_STORE_VERBS")"
  return $fails
}

# run DIRECTLY (not sourced): only --self-test means anything; a mistyped flag is refused (exit 2)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/selftest-flag.sh"
  selftest_reject_typo "${1:-}"
  if selftest_is_flag "${1:-}"; then ticket_store_self_test; exit $?; fi
  echo "ticket-store.sh is a sourced library; only --self-test runs it directly" >&2; exit 2
fi
