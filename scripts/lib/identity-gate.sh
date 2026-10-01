#!/usr/bin/env bash
# scripts/lib/identity-gate.sh — the two pure decisions init.sh makes about WHO is starting a session.
# (feat_harness_identity_comes_from_the_session_via_a_roster_and_session_entries_are_ledger_rows)
# Sourced by scripts/init.sh; no CLI of its own except `--self-test` through the shared contract.
#
#   identity_verdict <resolved name> <source>                -> ok | no-identity | file-identity
#   checkout_occupancy_kind <allow_shared 0|1> <marker_present 0|1> <requested> <incumbent> -> ok | occupied
#
# ⚠ WHY A SESSION, NOT A FILE. `.agent/name` is a label on a DIRECTORY. Several agents can share one
# checkout (measured in the seeded project: three names reporting from one cwd, claims stamped with the
# wrong one), so a name read from a file is not evidence of who is typing. The session's identity is
# GIT_AUTHOR_EMAIL resolved through agents/roster.json (scripts/lib/agent-name.sh, source=session), set
# by the launch line `bash scripts/agent-onboard.sh --launch-line <Name>` prints — and cannot be set
# afterwards. init.sh REFUSES a session whose name came from anywhere else; the old "kept from
# .agent/name" prompt is gone, not ported. A live marker (.agent/session.active) plus a DIFFERENT name
# in .agent/name means somebody else is here: refused, unless ALLOW_SHARED_CHECKOUT=1 says the hand-off
# is deliberate.

identity_verdict() {
  local name="${1-}" source="${2-}"
  [[ -n "$name" ]] || { printf 'no-identity\n'; return 0; }
  [[ "$source" == session ]] && { printf 'ok\n'; return 0; }
  printf 'file-identity\n'
}

checkout_occupancy_kind() {   # $1 allow_shared(0|1) · $2 marker_present(0|1) · $3 requested · $4 incumbent
  local allow_shared="${1-0}" marker="${2-0}" requested="${3-}" incumbent="${4-}"
  if [[ "$allow_shared" == 1 || "$marker" != 1 || -z "$requested" || -z "$incumbent" ]]; then
    echo ok
  elif [[ "$requested" == "$incumbent" ]]; then
    echo ok
  else
    echo occupied
  fi
}

_identity_gate_self_test() {
  local fails=0
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; fails=1; fi; }
  _t "a session-sourced name is ok"                              ok            "$(identity_verdict Wren session)"
  _t "a name from .agent/name is refused: file-identity"          file-identity "$(identity_verdict Wren file)"
  _t "a name from \$AGENT_NAME is refused too (env is not a session)" file-identity "$(identity_verdict Wren env)"
  _t "no name at all is no-identity"                             no-identity   "$(identity_verdict '' '')"
  _t "no marker: nobody is here"                                 ok            "$(checkout_occupancy_kind 0 0 Wren Bert)"
  _t "marker + same name: the incumbent re-running init"         ok            "$(checkout_occupancy_kind 0 1 Wren Wren)"
  _t "marker + a different name: OCCUPIED"                       occupied      "$(checkout_occupancy_kind 0 1 Wren Bert)"
  _t "…unless the hand-off is deliberate (ALLOW_SHARED_CHECKOUT=1)" ok          "$(checkout_occupancy_kind 1 1 Wren Bert)"
  _t "marker but no incumbent recorded: ok (nothing to compare)" ok            "$(checkout_occupancy_kind 0 1 Wren '')"
  (( fails == 0 )) && echo "identity-gate --self-test: ok" || { echo "identity-gate --self-test: FAILED" >&2; return 1; }
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/selftest-flag.sh"
  if selftest_is_flag "${1:-}"; then _identity_gate_self_test; exit $?; fi
  echo "identity-gate.sh is a sourced library (identity_verdict, checkout_occupancy_kind); only --self-test runs it directly" >&2; exit 64
fi
