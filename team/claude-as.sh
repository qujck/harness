#!/usr/bin/env bash
# team/claude-as.sh — start claude on a named login instead of the box's own, so a session is paid for by another
# subscription and is still a local member of this box's team.
#
#   bash team/claude-as.sh <label> [claude arguments]
#   bash team/claude-as.sh --self-test
#
# The login is the long-lived token `claude setup-token` prints, kept by the owner in
# ~/.claude/logins/<label>.token (mode 600; AGENT_LOGINS names another directory). A label is lower-case letters,
# digits and dashes. The token reaches claude through its environment only (CLAUDE_CODE_OAUTH_TOKEN), so it is never
# on a command line, in `ps` or on a pane; blanks and line ends around a pasted token are dropped. AGENT_LOGIN carries
# the label, so the session's status-line row says which login it is on (docs/context-publisher.md) and the budget,
# the panel and the page leave its usage figures out of this box's. A session on such a login has no Remote Control.
# team/agent-spawn.sh starts a name whose roster row has a "login" through this; box/restore-claude.sh resumes it so.
#
# Exit: claude's own once started · 1 no login file of that label, or an empty one · 2 a usage error.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SELF="$_here/$(basename -- "${BASH_SOURCE[0]}")"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"

# PURE: is this a login's label? $1 -> 0 | 1
# LC_ALL=C: under en_US.UTF-8 bash's [a-z] admits é and ß (found by strength's tester on its roster.sh, 2026-11-27).
claude_as_label_ok() { local LC_ALL=C; [[ "${1-}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; }

claude_as_self_test() {
  local fails=0 T out rc bad
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"
         else printf '  FAIL %s\n       want %q\n       got  %q\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  _has() { if grep -qF -- "$3" <<<"$2"; then printf '  ok   %s\n' "$1"
           else printf '  FAIL %s\n       no %q in:\n%s\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  _not() { if ! grep -qF -- "$3" <<<"$2"; then printf '  ok   %s\n' "$1"
           else printf '  FAIL %s\n       found %q in:\n%s\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  T="$(mktemp -d)" || return 2
  trap 'rm -rf "$T"' RETURN
  # A throwaway HOME and a stand-in claude that says what it was started with; nothing live is read.
  mkdir -p "$T/bin" "$T/home/.claude/logins"
  printf '#!/usr/bin/env bash\necho "token=${CLAUDE_CODE_OAUTH_TOKEN:-none}"; echo "login=${AGENT_LOGIN:-none}"; printf "arg=%%s\\n" "$@"; echo "cmdline=$(tr "\\0" " " < /proc/$$/cmdline 2>/dev/null)"\n' > "$T/bin/claude"
  chmod +x "$T/bin/claude"
  as() { env -u CLAUDE_CODE_OAUTH_TOKEN -u AGENT_LOGIN -u AGENT_LOGINS HOME="$T/home" PATH="$T/bin:$PATH" ${LOGINS:+AGENT_LOGINS="$LOGINS"} bash "$SELF" "$@" 2>&1; }

  printf 'tok-123\n' > "$T/home/.claude/logins/second.token"
  out="$(as second --model sonnet --name Ada "/color blue")"; rc=$?
  _t "a named login starts claude" "$rc" 0
  _has "  with its token in the environment" "$out" "token=tok-123"
  _has "  and the arguments unchanged" "$out" "arg=/color blue"
  _has "  and its label, for the status line" "$out" "login=second"
  if grep -q 'cmdline=.*tok-123' <<<"$out"; then _t "  the token is on no command line" on-it nowhere
  else _t "  the token is on no command line" nowhere nowhere; fi

  printf '  tok-456 \r\n\n' > "$T/home/.claude/logins/padded.token"
  _has "blanks and line ends around a pasted token are dropped" "$(as padded)" "token=tok-456"

  out="$(as third --name Ada)"; rc=$?
  _t "a login with no file is refused" "$rc" 1
  _has "  by name" "$out" "claude-as: no login named third"
  _not "  before claude starts" "$out" "token="

  : > "$T/home/.claude/logins/empty.token"
  out="$(as empty)"; rc=$?
  _t "an empty login is refused" "$rc" 1
  _has "  by name" "$out" "the login named empty is empty"

  for bad in "" ../second Second "a b"; do
    out="$(as "$bad" --name Ada)"; rc=$?
    _t "'$bad' is not a label" "$rc" 2
  done

  # é and ß are not labels in a UTF-8 locale either: a token file by that name must not be reached.
  printf 'tok-u\n' > "$T/home/.claude/logins/é.token"; printf 'tok-u\n' > "$T/home/.claude/logins/ß.token"
  for bad in é ß; do
    out="$(LC_ALL=en_US.UTF-8 as "$bad" --name Ada)"; rc=$?
    _t "'$bad' is not a label under en_US.UTF-8" "$rc" 2
    _not "  and its token is not read" "$out" "token=tok-u"
  done
  mkdir -p "$T/elsewhere"; printf 'tok-789\n' > "$T/elsewhere/other.token"
  _has "AGENT_LOGINS names another directory" "$(LOGINS="$T/elsewhere" as other)" "token=tok-789"

  if (( fails == 0 )); then echo "claude-as --self-test: PASS"; return 0; fi
  echo "claude-as --self-test: FAIL ($fails)"; return 1
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  [[ $# -eq 1 ]] || { printf 'unknown argument: %s\n' "$2" >&2; exit 2; }
  claude_as_self_test; exit $?
fi

label="${1:-}"
claude_as_label_ok "$label" || { echo "claude-as: usage: claude-as.sh <label> [claude arguments] (a label is lower-case letters, digits and dashes)" >&2; exit 2; }
shift
file="${AGENT_LOGINS:-$HOME/.claude/logins}/$label.token"
[[ -r "$file" ]] || { echo "claude-as: no login named $label" >&2; exit 1; }
token="$(tr -d ' \r\n' <"$file")"
[[ -n "$token" ]] || { echo "claude-as: the login named $label is empty" >&2; exit 1; }
AGENT_LOGIN="$label" CLAUDE_CODE_OAUTH_TOKEN="$token" exec claude "$@"
