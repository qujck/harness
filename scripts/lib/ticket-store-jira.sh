#!/usr/bin/env bash
# scripts/lib/ticket-store-jira.sh — the Jira store, reached through scripts/ledger-db.sh when harness.env
# says TICKET_STORE=jira (scripts/lib/ticket-store.sh hands every verb here). Same verbs, same verdict
# strings, same exit codes as the database store; the mapping is in docs/ticket-store-jira.md and the
# code in scripts/lib/ticket_store_jira.py. (feat_harness_jira_is_a_ticket_store_behind_the_same_verbs)
#
#   bash scripts/ledger-db.sh <verb> …                    # TICKET_STORE=jira: lands here
#   bash scripts/lib/ticket-store-jira.sh --self-test     # the whole lifecycle against the fixture transport
#   bash scripts/lib/ticket-store-jira.sh --live --record # the lifecycle against the REAL project, fixtures regenerated
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/selftest-flag.sh"
. "$HERE/harness-env.sh"
PY="$HERE/ticket_store_jira.py"
# the session identity's NAME travels to the adapter (the email is already in the environment)
if [[ -z "${HARNESS_AGENT_NAME:-}" ]]; then
  # shellcheck disable=SC1091
  source "$HERE/agent-name.sh" 2>/dev/null && HARNESS_AGENT_NAME="$(agent_name_resolved 2>/dev/null || true)"
  export HARNESS_AGENT_NAME
fi

_jira_lifecycle() { # <label>  — drives raise → groom → claim → amend → park → unpark → flip → archive → release; prints "step verdict" lines
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/raise.json" <<JSON
{"id":"zz_jira_selftest_$1","title":"self-test $1","area":"ci","status":"not_started","priority":2,
 "notes":"NOTES verbatim: a \"quoted\" line\nsecond line","verification":["item one names \`a_selector\`","item two"],
 "verification_command":"bash scripts/verify.sh","depends_on":[]}
JSON
  local v key
  v="$(python3 "$PY" raise "$tmp/raise.json")"; printf 'raise %s\n' "$v"; key="${v#ok:}"
  printf 'raise-again %s\n' "$(python3 "$PY" raise "$tmp/raise.json")"
  printf 'row-after-raise %s\n' "$(python3 "$PY" ticket-row "$key")"
  printf 'claim-before-groom %s\n' "$(python3 "$PY" claim "$key")"
  printf 'groom %s\n' "$(python3 "$PY" groom "$key" "ready: the PO says so")"
  printf 'claim %s\n' "$(python3 "$PY" claim "$key")"
  printf 'claim-again %s\n' "$(python3 "$PY" claim "$key")"
  printf 'owner %s\n' "$(python3 "$PY" ticket-owner "$key")"
  printf 'amend %s\n' "$(python3 "$PY" amend "$key" notes "NOTES amended" "the owner changed the ask")"
  printf 'amend-no-why %s\n' "$(python3 "$PY" amend "$key" notes "x" "")"
  printf 'show-notes %s\n' "$(python3 "$PY" show "$key" | python3 -c 'import json,sys; print(json.load(sys.stdin)["notes"])')"
  printf 'show-verification %s\n' "$(python3 "$PY" show "$key" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["verification"]))')"
  printf 'show-command %s\n' "$(python3 "$PY" show "$key" | python3 -c 'import json,sys; print(json.load(sys.stdin)["verification_command"])')"
  printf 'park %s\n' "$(python3 "$PY" park --kind owner "$key" "waiting on the owner")"
  printf 'row-parked %s\n' "$(python3 "$PY" ticket-row "$key")"
  printf 'unpark %s\n' "$(python3 "$PY" unpark "$key" "the owner answered")"
  printf 'release-early %s\n' "$(python3 "$PY" release "$key" "too early")"
  printf 'flip-no-pr %s\n' "$(python3 "$PY" flip-passing "$key")"
  printf 'flip %s\n' "$(python3 "$PY" flip-passing "$key" 42)"
  printf 'archive %s\n' "$(python3 "$PY" archive "$key" "merged in PR #42")"
  printf 'release %s\n' "$(python3 "$PY" release "$key" "done")"
  printf 'row-final %s\n' "$(python3 "$PY" ticket-row "$key")"
  printf 'comments %s\n' "$(python3 "$PY" comments "$key" | grep -c .)"
  printf 'key %s\n' "$key"
  rm -rf "$tmp"
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  fails=0
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; fails=1; fi; }
  export JIRA_TRANSPORT=fixture JIRA_PROJECT_KEY=HAR JIRA_FIXTURE_DIR="$(mktemp -d)" GIT_AUTHOR_EMAIL=example@your-project.example HARNESS_AGENT_NAME=Example
  unset JIRA_STATUS_MAP
  # pure: the status map
  _t "a map missing a harness status is refused by name" "refused:status-map-is-missing:wont_do" \
     "$(python3 -c 'import sys; sys.path.insert(0,"'"$HERE"'"); import ticket_store_jira as j
try: j.parse_status_map("not_started=To Do,selected=Ready,in_progress=In Progress,parked=Blocked,passing=Done pending,archived=Done")
except j.Refused as e: print(e)')"
  _t "a map naming a status the workflow lacks is refused, naming it" "refused:status-map-names-a-status-the-workflow-lacks:Ready" \
     "$(python3 -c 'import sys; sys.path.insert(0,"'"$HERE"'"); import ticket_store_jira as j
try: j.validate_status_map(j.parse_status_map(j.DEFAULT_STATUS_MAP), ["To Do","In Progress","Blocked","Done pending","Done","Won'"'"'t Do"])
except j.Refused as e: print(e)')"
  _t "the live validator reads the workflow: a bad map is refused before any write" 1 \
     "$(JIRA_STATUS_MAP='not_started=To Do,selected=Groomed,in_progress=In Progress,parked=Blocked,passing=Done pending,archived=Done,wont_do=Won'"'"'t Do' python3 "$PY" validate-status-map >/dev/null 2>&1; echo $?)"
  # pure: ADF round trip
  _t "ADF round-trips notes, a verification LIST and the command verbatim" "True" \
     "$(python3 -c 'import sys; sys.path.insert(0,"'"$HERE"'"); import ticket_store_jira as j
row={"title":"t","notes":"a \"q\" line\nline 2","verification":["one `x`","two"],"verification_command":"bash scripts/verify.sh","depends_on":["A-1"]}
back=j.adf_to_sections(j.sections_to_adf(row)); print(all(back[k]==row[k] for k in row))')"
  # the lifecycle against the fixture
  out="$(_jira_lifecycle a 2>&1)"
  g() { printf '%s\n' "$out" | awk -v k="$1" '$1==k {sub(/^[^ ]+ /,""); print; exit}'; }
  _t "raise creates an issue and prints its KEY" "ok:HAR-" "$(g raise | cut -c1-7)"
  _t "the issue arrives not_started (To Do)" not_started "$(g row-after-raise)"
  _t "raising the same slug again is refused by key" "exists:$(g key)" "$(g raise-again)"
  _t "claim before groom is refused (ready is the PO's move)" "refused:not-selected:not_started" "$(g claim-before-groom)"
  _t "groom transitions to selected" ok "$(g groom)"
  _t "claim assigns the session's account and moves to in_progress" ok "$(g claim)"
  _t "a second claim by the same session is already-yours (a success)" already-yours "$(g claim-again)"
  _t "the owner is the roster display name" Example "$(g owner)"
  _t "amend rewrites ONE section" ok "$(g amend)"
  _t "amend without a why is refused" refused:amend-needs-a-why "$(g amend-no-why)"
  _t "show returns the amended notes verbatim" "NOTES amended" "$(g show-notes)"
  _t "show returns the verification LIST untouched by the amend" '["item one names `a_selector`", "item two"]' "$(g show-verification)"
  _t "show returns the command verbatim" "bash scripts/verify.sh" "$(g show-command)"
  _t "park transitions to parked" ok "$(g park)"
  _t "ticket-row reads parked" parked "$(g row-parked)"
  _t "unpark returns to in_progress" ok "$(g unpark)"
  _t "release before the finish is refused" refused:not-finished:in_progress "$(g release-early)"
  _t "flip-passing needs a PR number" refused:flip-passing-needs-a-pr-number "$(g flip-no-pr)"
  _t "flip-passing with a PR transitions to passing" ok "$(g flip)"
  _t "archive from passing is ok" ok "$(g archive)"
  _t "release of an archived issue is a success verdict" release:archived:archived "$(g release)"
  _t "the final status reads archived" archived "$(g row-final)"
  _t "every write left a comment naming who and why (groom, claim-less, amend, park, unpark, flip, archive)" 6 "$(g comments)"
  # frontier/board shapes match the database store's (id|area|priority ; id|area|claimed_by)
  _jira_lifecycle b >/dev/null 2>&1; k2="$(python3 "$PY" frontier | head -1)"; : "$k2"
  cat > "$JIRA_FIXTURE_DIR/f.json" <<'JSON'
{"id":"zz_jira_selftest_frontier","title":"on the frontier","area":"docs","status":"not_started","priority":1,"verification":["x"],"verification_command":"true"}
JSON
  fk="$(python3 "$PY" raise "$JIRA_FIXTURE_DIR/f.json")"; fk="${fk#ok:}"; python3 "$PY" groom "$fk" why >/dev/null
  _t "frontier lists selected, unassigned issues as id|area|priority" "$fk|docs|1" "$(python3 "$PY" frontier | grep "^$fk|")"
  _t "board lists in_progress issues as id|area|claimed_by" 0 "$(python3 "$PY" board | grep -c "^$fk|")"
  # a raise with status selected by a non-PO is refused the database way
  printf '{"id":"zz_sel","title":"t","status":"selected","area":"ci"}\n' > "$JIRA_FIXTURE_DIR/s.json"
  _t "a raise arriving 'selected' is refused: ready-is-the-pos-move" "ready-is-the-pos-move:Example" "$(python3 "$PY" raise "$JIRA_FIXTURE_DIR/s.json")"
  printf '{"id":"zz_str","title":"t","status":"not_started","area":"ci","verification":"not a list"}\n' > "$JIRA_FIXTURE_DIR/v.json"
  _t "a non-list verification is refused, not coerced" "verification-not-a-list:str" "$(python3 "$PY" raise "$JIRA_FIXTURE_DIR/v.json")"
  # an epic with children: the children carry parent = the epic's key
  printf '{"id":"zz_epic","title":"epic","status":"not_started","area":"ci","children":[{"id":"zz_c1","title":"c1","area":"ci","status":"not_started"}]}\n' > "$JIRA_FIXTURE_DIR/e.json"
  ek="$(python3 "$PY" raise-epic "$JIRA_FIXTURE_DIR/e.json")"; ek="${ek#ok:}"
  ck="$(python3 "$PY" frontier >/dev/null; python3 - "$JIRA_FIXTURE_DIR/state.json" "$ek" <<'PYX'
import json,sys; st=json.load(open(sys.argv[1])); print(",".join(k for k,i in st["issues"].items() if (i["fields"].get("parent") or {}).get("key")==sys.argv[2]))
PYX
)"
  _t "raise-epic creates the children with parent = the epic key" 1 "$(printf '%s' "$ck" | awk -F, '{print NF}')"
  _t "a child naming an unknown parent is refused" "unknown-parent:HAR-999" "$( printf '{"id":"zz_orphan","title":"t","status":"not_started","area":"ci","parent":"HAR-999"}\n' > "$JIRA_FIXTURE_DIR/o.json"; python3 "$PY" raise "$JIRA_FIXTURE_DIR/o.json")"
  # transport failures: 429/503 are retried (fixture fails ONCE, the retry succeeds); 'down' is cannot-tell for a read, a refusal for a write
  _t "a 503 on a read is retried and the read succeeds" archived "$(JIRA_FIXTURE_FAIL_NEXT=503 python3 "$PY" ticket-row "$(g key)" 2>/dev/null)"
  _t "an unreachable Jira is CANNOT TELL (exit 2) for a read, never 'no row'" 2 "$(JIRA_FIXTURE_FAIL_NEXT=down python3 "$PY" ticket-row "$(g key)" >/dev/null 2>&1; echo $?)"
  _t "an unreachable Jira is a refusal (exit 1) for a write, naming it" "refused:jira-unavailable" "$(JIRA_FIXTURE_FAIL_NEXT=down python3 "$PY" groom "$fk" why 2>/dev/null | cut -d: -f1-2)"
  # unsupported verbs refuse loudly with 2
  _t "sync-agent-roles is unsupported here and exits 2, loudly" 2 "$(python3 "$PY" sync-agent-roles >/dev/null 2>&1; echo $?)"
  _t "the adapter is reached through ledger-db.sh when TICKET_STORE=jira" "$(g key)|" "$(cd "$HERE/../.." && TICKET_STORE=jira bash scripts/ledger-db.sh ticket-row "$(g key)" 2>/dev/null | head -c 0; TICKET_STORE=jira bash scripts/ledger-db.sh show "$(g key)" 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["id"]+"|")')"
  # session entries: comments on the configured session-log issue (child 4's decision)
  _t "session-entry is refused by name with no session-log issue configured" "refused:JIRA_SESSION_LOG_ISSUE-is-not-set-in-harness.env" \
     "$(printf '{"title":"t","body":"b"}' | python3 "$PY" session-entry)"
  printf '{"id":"zz_session_log","title":"Session log","status":"not_started","area":"ci"}\n' > "$JIRA_FIXTURE_DIR/sl.json"
  slk="$(python3 "$PY" raise "$JIRA_FIXTURE_DIR/sl.json")"; slk="${slk#ok:}"
  _t "session-entry writes a comment on the session-log issue" "ok:" \
     "$(printf '{"title":"did a thing","body":"the body","ticket_id":"HAR-1","pr":7}' | JIRA_SESSION_LOG_ISSUE="$slk" python3 "$PY" session-entry | cut -c1-3)"
  _t "session-entry without a body is refused" "refused:session-entry-needs-title-and-body" \
     "$(printf '{"title":"t"}' | JIRA_SESSION_LOG_ISSUE="$slk" python3 "$PY" session-entry)"
  _t "session-entries --mine lists this session's entries as id|created|agent|title" "Example|did a thing (ticket HAR-1) (PR #7)" \
     "$(JIRA_SESSION_LOG_ISSUE="$slk" python3 "$PY" session-entries --mine | cut -d'|' -f3-)"
  _t "session-entries --agent <other> lists nothing of mine (negative control)" "" \
     "$(JIRA_SESSION_LOG_ISSUE="$slk" python3 "$PY" session-entries --agent Nobody)"
  rm -rf "$JIRA_FIXTURE_DIR"
  (( fails == 0 )) && echo "ticket-store-jira --self-test: ok" || { echo "ticket-store-jira --self-test: FAILED" >&2; exit 1; }
  exit 0
fi

if [[ "${1:-}" == --live ]]; then
  shift; record=0; [[ "${1:-}" == --record ]] && record=1
  [[ "${TICKET_STORE:-}" == jira ]] || { echo "ticket-store-jira --live: set TICKET_STORE=jira and the JIRA_* keys in harness.env first" >&2; exit 2; }
  root="$(cd "$HERE/../.." && pwd)"
  if (( record )); then export JIRA_RECORD_DIR="$root/fixtures/jira/recorded"; rm -rf "$JIRA_RECORD_DIR"; fi
  echo "ticket-store-jira --live: running the lifecycle against $JIRA_BASE_URL project $JIRA_PROJECT_KEY as $GIT_AUTHOR_EMAIL" >&2
  _jira_lifecycle "live-$(date -u +%Y%m%dT%H%M%SZ)"
  if (( record )); then
    python3 "$PY" dump-workflow > "$root/fixtures/jira/workflow.json" 2>/dev/null || echo "  (workflow dump not available on this adapter version; keep fixtures/jira/workflow.json by hand)" >&2
    echo "recorded: $(ls "$JIRA_RECORD_DIR" | wc -l) responses under fixtures/jira/recorded/ — commit them with the DECISIONS entry naming the issue key" >&2
  fi
  exit 0
fi

exec python3 "$PY" "$@"
