#!/usr/bin/env bash
# scripts/check-no-committed-jira-token.sh — a Jira API token must never be in git.
# (feat_harness_jira_is_a_ticket_store_behind_the_same_verbs)
#
#   bash scripts/check-no-committed-jira-token.sh              # the TRACKED tree (git ls-files)
#   bash scripts/check-no-committed-jira-token.sh --self-test
#
# Refuses when any tracked file sets JIRA_API_TOKEN= (or JIRA_TOKEN=) to a non-empty value, or carries
# an Atlassian token shape (ATATT3x…), or a Basic auth header. `harness.env` is gitignored; this is the
# check for the day somebody force-adds it, pastes a token into a doc, or commits a recorded fixture
# with the Authorization header in it. Comments and the `.example` file's empty value are fine.
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# token_lines <file> -> the offending lines (empty = clean). Pure over the file's text.
token_lines() {
  awk '
    /^[[:space:]]*#/ { next }
    /JIRA_(API_)?TOKEN[[:space:]]*=[[:space:]]*["'"'"']?[^"'"'"'#[:space:]]+/ { print FILENAME ":" FNR ": " $0; next }
    /ATATT3x[A-Za-z0-9_=-]{20,}/ { print FILENAME ":" FNR ": " $0; next }
    /Authorization"?: *"?Basic [A-Za-z0-9+\/=]{20,}/ { print FILENAME ":" FNR ": " $0 }
  ' "$1" 2>/dev/null
}

if selftest_is_flag "${1:-}"; then
  fails=0; d="$(mktemp -d)"
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; fails=1; fi; }
  printf 'JIRA_API_TOKEN=\nJIRA_EMAIL=me@x\n# JIRA_API_TOKEN=secret in a comment\n' > "$d/example.env"
  _t "an empty value and a commented example are clean" 0 "$(token_lines "$d/example.env" | grep -c .)"
  printf 'JIRA_API_TOKEN=                    # NEVER in git: the example file is tracked\n' > "$d/trailing.env"
  _t "an empty value with a trailing comment is clean (the .example file, 2026-10-01: a false red)" 0 "$(token_lines "$d/trailing.env" | grep -c .)"
  printf 'JIRA_API_TOKEN=ATATT3xFfGF0abcdefghijklmnopqrstuvwxyz\n' > "$d/planted.env"
  _t "a planted token is refused" 1 "$(token_lines "$d/planted.env" | grep -c .)"
  printf 'JIRA_TOKEN="abc123def456"\n' > "$d/quoted.env"
  _t "a quoted JIRA_TOKEN value is refused" 1 "$(token_lines "$d/quoted.env" | grep -c .)"
  printf '{"headers": {"Authorization": "Basic bWVAeC5jb206QVRBVFQzeEZmR0YwYWJj"}}\n' > "$d/recorded.json"
  _t "a recorded Basic auth header is refused" 1 "$(token_lines "$d/recorded.json" | grep -c .)"
  printf 'See ATATT3x in the docs — the token shape, not a token\n' > "$d/doc.md"
  _t "the bare prefix without a token body is clean" 0 "$(token_lines "$d/doc.md" | grep -c .)"
  rm -rf "$d"
  (( fails == 0 )) && echo "check-no-committed-jira-token: self-test ok" || { echo "check-no-committed-jira-token: self-test FAILED" >&2; exit 1; }
  exit 0
fi

cd "$ROOT" || exit 2
hits=0
while IFS= read -r f; do
  [[ -f "$f" ]] || continue
  case "$f" in scripts/check-no-committed-jira-token.sh) continue ;; esac
  out="$(token_lines "$f")"
  [[ -n "$out" ]] && { printf '%s\n' "$out"; hits=$((hits+1)); }
done < <(git ls-files 2>/dev/null)
if (( hits )); then
  echo "check-no-committed-jira-token: FAIL — $hits tracked file(s) carry a Jira token or auth header. Rotate the token in Atlassian NOW (a committed token is burned), then remove it." >&2
  exit 1
fi
echo "check-no-committed-jira-token: ok — no tracked file carries a Jira token"
