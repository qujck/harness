#!/usr/bin/env bash
# scripts/examples/statusline-publish.sh — AN EXAMPLE of the context publisher, for the project owner to adapt.
# (feat_harness_a_machine_wide_agent_stack_cap_and_each_agents_context_published_for_the_others)
#
# Claude Code calls a status-line command every few seconds with a JSON payload on stdin. This example
# turns that payload into ONE file per session under the context directory, in the shape
# scripts/agent-context.sh reads (docs/context-publisher.md states the contract). The real status-line
# script is the owner's, outside the repo; this is the shape it must write, not the file to install.
#
#   bash scripts/examples/statusline-publish.sh < <(printf '{"session_id":"abc","model":{"display_name":"Opus"},"cwd":"/w","context_window":{"remaining_percentage":42},"rate_limits":{"seven_day":{"used_percentage":18}}}')
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)/harness-env.sh" 2>/dev/null || true
DIR="${CONTEXT_DIR:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/context}"
payload="$(cat)"
sid="$(jq -r '.session_id // "unknown"' <<<"$payload")"
# the agent's NAME comes from the session (GIT_AUTHOR_EMAIL -> roster), the same source every write uses
name="$(cd "$(dirname -- "${BASH_SOURCE[0]}")/../.." && source scripts/lib/agent-name.sh 2>/dev/null && agent_name_resolved 2>/dev/null || true)"
mkdir -p "$DIR"
jq -c --arg agent "${name:-unnamed}" --arg sid "$sid" --arg ts "$(date -u +%FT%TZ)" --arg cwd "$(pwd)" \
   --arg wt "$(git rev-parse --show-toplevel 2>/dev/null | xargs -r basename)" \
   --arg activity "${CLAUDE_ACTIVITY:-working}" '
  { agent: $agent, session_id: $sid, ts: $ts, cwd: $cwd, worktree: ($wt | if . == "" then null else . end),
    model: (.model.display_name // .model.id // "?"),
    context: { remaining_pct: (.context_window.remaining_percentage // null) },
    week:    { used_pct: (.rate_limits.seven_day.used_percentage // null) },
    activity: $activity }' <<<"$payload" > "$DIR/$sid.json.tmp" && mv "$DIR/$sid.json.tmp" "$DIR/$sid.json"
# the status line itself: what the person sees
printf '%s · ctx %s%% left · week %s%%\n' "${name:-unnamed}" "$(jq -r '.context_window.remaining_percentage // "?"' <<<"$payload")" "$(jq -r '.rate_limits.seven_day.used_percentage // "?"' <<<"$payload")"
