#!/usr/bin/env bash
# claude-code/self-compact/compact-me.sh — write THIS session's self-compact request, in one command.
#
#   bash claude-code/self-compact/compact-me.sh "<what the summary must keep>"   # then END YOUR TURN
#   bash claude-code/self-compact/compact-me.sh --self-test                      # pure, touches nothing real
#
# The self-compact mod compacts a session between turns when it finds `{"instructions": …}` at
# `<state>/self-compact/<session id>.json` (state = $XDG_STATE_HOME, else $HOME/.local/state). This
# writes that file for the session the command runs in, and nothing else: the id comes from
# CLAUDE_CODE_SESSION_ID, which Claude Code sets in every Bash the agent runs (seen in two agents'
# shells on 2026-10-16, where it matched the session file's sessionId).
#
# ⚠ IT REFUSES RATHER THAN GUESSES. No CLAUDE_CODE_SESSION_ID, or one that is not a plain token,
# or no state directory: exit 2 with one line, and no file is written. A guessed id could only ever
# name a file no session reads (the mod reads its OWN id's file and no other), so a guess would be
# a silent no-op, which is worse than a refusal. The write is atomic (temp file + mv), so a half-
# written file is never read as a request; the text is JSON-escaped by python3, never by hand.
#
# The compaction happens at the END of the turn, not on this command: write the durable record
# first (session entry, row notes, memory), run this, then stop talking.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/selftest-flag.sh
. "$HERE/../../scripts/lib/selftest-flag.sh"

# ── pure parts ───────────────────────────────────────────────────────────────────────────────────

# The request path for a session id under an environment, or exit 2 with the reason on stderr.
# Mirrors requestPath() in hooks/compact.ts: the id must be a plain token, state is XDG or HOME.
request_path() { # <session id> <XDG_STATE_HOME> <HOME>
  local sid="$1" xdg="$2" home="$3" state
  if [[ -z "$sid" ]]; then echo "compact-me: CLAUDE_CODE_SESSION_ID is not set; this is not an agent's Bash, so there is no session to compact (refusing to guess)" >&2; return 2; fi
  if [[ ! "$sid" =~ ^[A-Za-z0-9_-]+$ ]]; then echo "compact-me: CLAUDE_CODE_SESSION_ID is not a plain token: $sid" >&2; return 2; fi
  if [[ -n "$xdg" ]]; then state="$xdg"; elif [[ -n "$home" ]]; then state="$home/.local/state"; else
    echo "compact-me: neither XDG_STATE_HOME nor HOME is set, so the request path cannot be built" >&2; return 2; fi
  printf '%s/self-compact/%s.json\n' "$state" "$sid"
}

# The request document: {"instructions": <text>} with the text JSON-escaped; empty text → {}.
request_json() { # <text>
  python3 -c 'import json,sys; t=sys.argv[1]; print(json.dumps({"instructions": t} if t else {}))' "$1"
}

# ── the action ───────────────────────────────────────────────────────────────────────────────────

write_request() { # <text> <path>
  local text="$1" path="$2" tmp
  mkdir -p "$(dirname "$path")"
  tmp="$(mktemp "$(dirname "$path")/.compact-me.XXXXXX")"
  request_json "$text" > "$tmp"
  mv -f "$tmp" "$path"
}

# ── self-test ────────────────────────────────────────────────────────────────────────────────────

self_test() {
  local fails=0 d p
  _t() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }
  _t "path under HOME" '[[ "$(request_path abc "" /h)" == "/h/.local/state/self-compact/abc.json" ]]'
  _t "XDG_STATE_HOME wins" '[[ "$(request_path abc /var/state /h)" == "/var/state/self-compact/abc.json" ]]'
  _t "no session id refuses (exit 2), writes nothing" '! request_path "" "" /h 2>/dev/null; [[ $(request_path "" "" /h 2>/dev/null; echo $?) == 2 ]]'
  _t "a non-token id refuses (exit 2)" '[[ $(request_path "../other" "" /h 2>/dev/null; echo $?) == 2 ]]'
  _t "no state dir refuses (exit 2)" '[[ $(request_path abc "" "" 2>/dev/null; echo $?) == 2 ]]'
  _t "text is JSON-escaped" '[[ "$(request_json "keep the \"plan\", and
the row")" == "{\"instructions\": \"keep the \\\"plan\\\", and\\nthe row\"}" ]]'
  _t "empty text is {}" '[[ "$(request_json "")" == "{}" ]]'
  d="$(mktemp -d)"; p="$d/self-compact/sid.json"
  _t "the write is atomic and parses" 'write_request "x" "$p" && python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$p" && [[ -z "$(ls -A "$d/self-compact" | grep -v "^sid.json$")" ]]'
  _t "a second write replaces, not appends" 'write_request "y" "$p" && [[ "$(cat "$p")" == "{\"instructions\": \"y\"}" ]]'
  rm -rf "$d"
  # the real entry point, both ways: the refusal names ITS reason (not some other exit 2), and a call
  # with an id and a state dir leaves the file where the mod reads it, with the text inside
  local err rc=0
  err="$(env -u CLAUDE_CODE_SESSION_ID bash "$HERE/compact-me.sh" "x" 2>&1 >/dev/null)" || rc=$?   # || so set -e lets the refusal through
  _t "the real env refuses without CLAUDE_CODE_SESSION_ID, naming it" '[[ $rc == 2 && "$err" == *"CLAUDE_CODE_SESSION_ID is not set"* ]]'
  d="$(mktemp -d)"
  _t "the real entry point writes the request for a given id under XDG_STATE_HOME" 'CLAUDE_CODE_SESSION_ID=test-0000 XDG_STATE_HOME="$d" bash "$HERE/compact-me.sh" "keep run 8" >/dev/null 2>&1 && [[ "$(cat "$d/self-compact/test-0000.json")" == "{\"instructions\": \"keep run 8\"}" ]]'
  _t "the real entry point with no text refuses (exit 2), writes nothing" '[[ $(CLAUDE_CODE_SESSION_ID=test-0001 XDG_STATE_HOME="$d" bash "$HERE/compact-me.sh" >/dev/null 2>&1; echo $?) == 2 && ! -e "$d/self-compact/test-0001.json" ]]'
  rm -rf "$d"
  if (( fails == 0 )); then echo "compact-me --self-test: ok"; else echo "compact-me --self-test: $fails FAILED"; return 1; fi
}

# ── main ─────────────────────────────────────────────────────────────────────────────────────────

selftest_reject_typo "${1:-}"
# ⚠ selftest_is_flag, NOT selftest_requested: the latter is for scripts whose ONLY argument is the
# flag, and its catch-all branch exits 2 on any other first argument, which here is the instructions
# text itself. At b0b2feb every real call exited 2 "unknown argument" and wrote nothing, and the
# self-test stayed green because its refusal arm asserted only the exit code, which the wrong
# rejection also produced (found 2026-10-16). Both arms below now assert the reason and the file.
if selftest_is_flag "${1:-}"; then self_test; exit $?; fi

TEXT="${1:-}"
if [[ -z "$TEXT" ]]; then
  echo "compact-me: say what the summary must keep: bash ${BASH_SOURCE[0]} \"<what the summary must keep>\"" >&2
  exit 2
fi
PATH_OUT="$(request_path "${CLAUDE_CODE_SESSION_ID:-}" "${XDG_STATE_HOME:-}" "${HOME:-}")"
write_request "$TEXT" "$PATH_OUT"
echo "compact-me: request written to $PATH_OUT"
echo "Now END YOUR TURN: the self-compact mod compacts this session between turns, with those instructions, and clears the request. Do not start new work first."
