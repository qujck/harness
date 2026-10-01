#!/usr/bin/env bash
# scripts/agent-context.sh — every live agent's remaining context and weekly usage, on one screen.
#
# WHERE THE NUMBERS COME FROM. Claude Code hands its status-line script a JSON payload with the
# session's context-window usage and the account's rate limits; the MODEL never sees that payload.
# So the status-line script (~/dev/download/claude/statusline.sh, owner-configured) writes one small
# JSON file per session to ~/.local/state/strength/context/<session_id>.json on every refresh
# (about every 5 s), and this script renders them. Owner, 2026-09-28: "each agent should log their
# current context where the other agents can see it."
#
# ⚠ WHAT THIS IS FOR, AND WHAT IT IS NOT FOR — from CLAUDE.md's guidance on context:
#   STATE is working/idle from the transcript's mtime (owner, 2026-09-28: so nobody has to scroll a pane
#   to see whether Esc would interrupt a working agent).
#   use it to WRITE THE RECORD before a compaction, to DELEGATE a wide read, to size a hand-off, and
#   to answer "how much have you got left". It is NEVER a reason to do less work or to stop: a
#   compaction is a summary, not an ending, and the work continues on the other side of it.
#
# Usage:  bash scripts/agent-context.sh            # table of live sessions (stale > 2 min are marked)
#         bash scripts/agent-context.sh --me       # this session's line only (needs AGENT_NAME or a name match)
#         bash scripts/agent-context.sh --json     # the raw rows, one JSON object per line
#         bash scripts/agent-context.sh --self-test
set -uo pipefail
# shellcheck source=lib/selftest-flag.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/harness-env.sh" 2>/dev/null || true
DIR="${CONTEXT_DIR:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/context}"   # the publisher writes one JSON per session here
STALE_S=120

rows() { # -> one JSON object per line, freshest first, with an `age_s` field added
  local now f
  now=$(date -u +%s)
  for f in "$DIR"/*.json; do
    [ -r "$f" ] || continue
    jq -c --argjson now "$now" '. + {age_s: ($now - ((.ts | fromdateiso8601?) // $now))}' "$f" 2>/dev/null
  done | sort -t$'\t' -k1 | jq -s -c 'sort_by(.age_s) | .[]' 2>/dev/null
}

render() {
  printf '%-10s %-9s %6s %6s %8s  %-8s %s\n' AGENT STATE CTX-LEFT WEEK AGE MODEL WHERE
  rows | while IFS= read -r j; do
    jq -r '[.agent, ((.activity // "?") + (if .activity=="idle" and .idle_s then " " + ((.idle_s/60)|floor|tostring) + "m" else "" end)), (.context.remaining_pct // "?"|tostring), (.week.used_pct // "?"|tostring), (.age_s|tostring), (.model // "?"), (.worktree // .cwd // "?")] | @tsv' <<<"$j" \
    | while IFS=$'\t' read -r a st c w age m where; do
        flag=""; [ "${age%.*}" -gt "$STALE_S" ] 2>/dev/null && flag=" (stale)"
        printf '%-10s %-9s %5s%% %5s%% %7ss  %-8s %s%s\n' "$a" "${st:0:9}" "${c%.*}" "${w%.*}" "${age%.*}" "${m:0:8}" "$where" "$flag"
      done
  done
}

selftest() {
  local t; t=$(mktemp -d); trap 'rm -rf "$t"' RETURN
  printf '{"agent":"a","session_id":"1","ts":"%s","cwd":"/x","worktree":"wt","model":"M","context":{"remaining_pct":12.4},"week":{"used_pct":50}}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$t/1.json"
  printf '{"agent":"b","session_id":"2","ts":"2020-01-01T00:00:00Z","cwd":"/y","worktree":null,"model":"M","context":{"remaining_pct":80},"week":{"used_pct":50}}\n' > "$t/2.json"
  local out; out=$(DIR="$t" render)
  grep -q '^a  *?  *12%' <<<"$out" || { echo "FAIL: fresh row not rendered with its remaining %"; echo "$out"; return 1; }
  grep -q 'b .*(stale)' <<<"$out" || { echo "FAIL: an old row is not marked stale"; echo "$out"; return 1; }
  [ "$(sed -n 2p <<<"$out" | awk '{print $1}')" = "a" ] || { echo "FAIL: freshest first"; echo "$out"; return 1; }
  echo "agent-context: self-test ok — fresh row rendered, stale row marked, freshest first"
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then selftest; exit $?; fi
case "${1:-}" in
  "") render ;;
  --json) rows ;;
  --me) source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/agent-name.sh" 2>/dev/null; me="$(agent_name_resolved 2>/dev/null || true)"; render | awk -v m="${me:-}" 'NR==1 || tolower($1)==tolower(m)' ;;
  *) echo "agent-context: unknown argument '$1' (usage: agent-context.sh [--me|--json|--self-test])" >&2; exit 2 ;;
esac
