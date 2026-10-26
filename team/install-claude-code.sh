#!/usr/bin/env bash
# team/install-claude-code.sh — wire Claude Code on THIS box to the harness, once: the status line that
# publishes each session's row, the mods folder, and the activity hooks. Adds to ~/.claude/settings.json
# alongside what is there; never replaces a value the person set; keeps the old file as settings.json.bak.
#
#   bash team/install-claude-code.sh             # show what would be added, ask, then write
#   bash team/install-claude-code.sh --dry-run   # show only
#   bash team/install-claude-code.sh --yes       # write without asking (for a script)
#   bash team/install-claude-code.sh --self-test
#
# What it adds, each only when absent:
#   statusLine                 bash <repo>/team/statusline-publish.sh, every 5 s (docs/context-publisher.md)
#   env.CLAUDE_CODE_PLUGIN_DIRS  <repo>/claude-code appended to whatever is listed (the three mods load in every session);
#                                a stale <repo>/mods entry (the folder's name before 2f96cd0, 2026-10-26) is dropped,
#                                not kept beside it: a box left on it loads no mods in any new session
#   hooks                      bash <repo>/team/activity-hook.sh <Event> for the eight events it records;
#                              the four tool events carry matcher "*"
# The file is Claude Code's user settings (`$CLAUDE_CONFIG_DIR/settings.json`, default ~/.claude), not the
# repo's .claude/settings.json: the row, the mods and the hooks are per session on the box, not per repo.
# Takes effect in sessions started afterwards (README, setup step 5).
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/../scripts/lib/selftest-flag.sh"

EVENTS='["UserPromptSubmit","Stop","SessionStart","SessionEnd"]'
TOOL_EVENTS='["PreToolUse","PermissionRequest","PostToolUse","PostToolUseFailure"]'

# merge_settings <repo root> : current settings JSON on stdin -> merged JSON on stdout   (pure)
merge_settings() {
  jq --arg mods "$1/claude-code" --arg old "$1/mods" --arg sl "bash $1/team/statusline-publish.sh" --arg hook "bash $1/team/activity-hook.sh" \
     --argjson ev "$EVENTS" --argjson tev "$TOOL_EVENTS" '
    .statusLine //= {type: "command", command: $sl, refreshInterval: 5}
    | .env //= {}
    | .env.CLAUDE_CODE_PLUGIN_DIRS = ((((.env.CLAUDE_CODE_PLUGIN_DIRS // "") | split(":") | map(select(. != "" and . != $mods and . != $old))) + [$mods]) | join(":"))
    | .hooks //= {}
    | reduce ($ev + $tev)[] as $e (.;
        if ([.hooks[$e][]?.hooks[]?.command // ""] | any(test("activity-hook\\.sh"))) then .
        else .hooks[$e] = ((.hooks[$e] // []) + [
          ({hooks: [{type: "command", command: ($hook + " " + $e), timeout: 5}]}
           | if ($tev | index($e)) != null then .matcher = "*" else . end) ])
        end)'
}

# additions <current> <merged> -> one line per thing the merge adds   (pure)
additions() {
  jq -rn --argjson c "$1" --argjson m "$2" '
    (if $c.statusLine == null then "  statusLine: \($m.statusLine.command)" else empty end),
    (if ($c.env.CLAUDE_CODE_PLUGIN_DIRS // "") != $m.env.CLAUDE_CODE_PLUGIN_DIRS then "  env CLAUDE_CODE_PLUGIN_DIRS: \($m.env.CLAUDE_CODE_PLUGIN_DIRS)" else empty end),
    ([$m.hooks | keys[] | select(($c.hooks[.] // []) != $m.hooks[.])] | select(length > 0) | "  hooks: activity-hook.sh on \(join(", "))")'
}

DRY=0; YES=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --yes) YES=1 ;;
    *) selftest_is_flag "$a" || { echo "install-claude-code: unknown argument $a (--dry-run, --yes or --self-test)" >&2; exit 2; } ;;
  esac
done

if selftest_is_flag "${1:-}"; then
  f=0; d="$(mktemp -d)"; _t() { [[ "$2" == "$3" ]] && printf '  ok    %s\n' "$1" || { printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; f=1; }; }
  m="$(merge_settings /r <<<'{}')"
  _t "an empty file gains the publisher as its status line" "bash /r/team/statusline-publish.sh" "$(jq -r .statusLine.command <<<"$m")"
  _t "and the mods folder" "/r/claude-code" "$(jq -r .env.CLAUDE_CODE_PLUGIN_DIRS <<<"$m")"
  _t "and a hook for each of the eight events" 8 "$(jq -r '.hooks | length' <<<"$m")"
  _t "a tool event's hook carries matcher *" '*' "$(jq -r '.hooks.PreToolUse[0].matcher' <<<"$m")"
  _t "a stop's hook carries none" null "$(jq -r '.hooks.Stop[0].matcher' <<<"$m")"
  _t "the hook names its event" "bash /r/team/activity-hook.sh PermissionRequest" "$(jq -r '.hooks.PermissionRequest[0].hooks[0].command' <<<"$m")"
  m2="$(merge_settings /r <<<"$m")"
  _t "merging again changes nothing" "$(jq -S . <<<"$m")" "$(jq -S . <<<"$m2")"
  _t "and says so" "" "$(additions "$m" "$m2")"
  own='{"statusLine":{"type":"command","command":"mine"},"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/x:/r/claude-code"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash /elsewhere/activity-hook.sh Stop"}]}]}}'
  m3="$(merge_settings /r <<<"$own")"
  _t "a status line the person set is kept" mine "$(jq -r .statusLine.command <<<"$m3")"
  _t "other plugin dirs are kept, ours once, at the end" "/x:/r/claude-code" "$(jq -r .env.CLAUDE_CODE_PLUGIN_DIRS <<<"$m3")"
  m4="$(merge_settings /r <<<'{"env":{"CLAUDE_CODE_PLUGIN_DIRS":"/x:/r/mods"}}')"
  _t "the pre-2f96cd0 mods folder is replaced, not kept beside the new one" "/x:/r/claude-code" "$(jq -r .env.CLAUDE_CODE_PLUGIN_DIRS <<<"$m4")"
  _t "an event that already runs an activity hook gains no second one" 1 "$(jq -r '.hooks.Stop | length' <<<"$m3")"
  _t "the additions name only what is new" "  hooks: activity-hook.sh on PermissionRequest, PostToolUse, PostToolUseFailure, PreToolUse, SessionEnd, SessionStart, UserPromptSubmit" "$(additions "$own" "$m3")"
  # the real action against a throwaway config dir: a dry run writes nothing; --yes writes and keeps a .bak
  mkdir -p "$d/cfg"; printf '{"permissions":{}}\n' > "$d/cfg/settings.json"
  CLAUDE_CONFIG_DIR="$d/cfg" bash "$HERE/install-claude-code.sh" --dry-run >/dev/null 2>&1
  _t "a dry run leaves the file as it was" '{"permissions":{}}' "$(jq -c . "$d/cfg/settings.json")"
  CLAUDE_CONFIG_DIR="$d/cfg" bash "$HERE/install-claude-code.sh" --yes >/dev/null 2>&1
  _t "--yes writes the merge" 8 "$(jq -r '.hooks | length' "$d/cfg/settings.json")"
  _t "and keeps what was there" '{}' "$(jq -c .permissions "$d/cfg/settings.json")"
  _t "and the old file as .bak" '{"permissions":{}}' "$(jq -c . "$d/cfg/settings.json.bak")"
  _t "a second --yes says there is nothing to add" "install-claude-code: nothing to add" "$(CLAUDE_CONFIG_DIR="$d/cfg" bash "$HERE/install-claude-code.sh" --yes 2>&1 | tail -1)"
  rm -rf "$d"
  (( f == 0 )) && { echo "install-claude-code: self-test ok"; exit 0; } || { echo "install-claude-code: self-test FAILED" >&2; exit 1; }
fi

command -v jq >/dev/null || { echo "install-claude-code: jq is required" >&2; exit 1; }
SETTINGS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"
current='{}'
if [[ -e "$SETTINGS" ]]; then
  current="$(cat "$SETTINGS")"
  jq -e 'type == "object"' <<<"$current" >/dev/null 2>&1 || { echo "install-claude-code: $SETTINGS is not a JSON object; fix it by hand first" >&2; exit 1; }
fi
merged="$(merge_settings "$ROOT" <<<"$current")"
if [[ "$(jq -S . <<<"$current")" == "$(jq -S . <<<"$merged")" ]]; then echo "install-claude-code: nothing to add"; exit 0; fi
echo "install-claude-code: $SETTINGS would gain"
additions "$current" "$merged"
(( DRY )) && { echo "  (dry run: nothing written)"; exit 0; }
if (( ! YES )); then
  [[ -t 0 ]] || { echo "install-claude-code: not a terminal; run with --yes to write, or --dry-run to look" >&2; exit 2; }
  read -r -p "  Add these to $SETTINGS? [y/N] " a; [[ "$a" =~ ^[Yy]$ ]] || { echo "  nothing written"; exit 0; }
fi
mkdir -p "$(dirname "$SETTINGS")"
[[ -e "$SETTINGS" ]] && cp "$SETTINGS" "$SETTINGS.bak" && echo "  the old file is kept as $SETTINGS.bak"
jq . <<<"$merged" > "$SETTINGS.tmp" && mv -f "$SETTINGS.tmp" "$SETTINGS" && echo "  written $SETTINGS; it takes effect in sessions started from now"
