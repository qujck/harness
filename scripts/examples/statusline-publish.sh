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
# A running total of output tokens, for the panel's burn sparkline (scripts/agents-dash.sh). The payload
# gives only the LAST response's output, so each refresh whose (used, output) pair differs from the
# previous refresh's is taken as a new response and added; two responses between refreshes count as one.
used="$(jq -r '.context_window.total_input_tokens // empty' <<<"$payload")"
last_out="$(jq -r '.context_window.total_output_tokens // empty' <<<"$payload")"
tok="$DIR/.$sid.tokens"; prev_used=""; prev_out=""; out_total=0
[ -r "$tok" ] && read -r prev_used prev_out out_total < "$tok"
if [ -n "$used" ] && [ -n "$last_out" ] && { [ "$used" != "$prev_used" ] || [ "$last_out" != "$prev_out" ]; }; then
  out_total=$(( ${out_total:-0} + ${last_out%.*} ))
  printf '%s %s %s\n' "$used" "$last_out" "$out_total" > "$tok.tmp" && mv -f "$tok.tmp" "$tok"
fi
# The window the gauge is measured against. The payload's context_window_size is always the model's
# full window, but /autocompact caps where compaction fires, saved per model in settings.json
# (modelSettings.<model id>.autoCompactWindow, else autoCompactWindow). When that cap is positive and
# below the model's window it IS the window: 257k of a 500k cap is 51% full, not 25% of 1M.
model_id="$(jq -r '.model.id // empty' <<<"$payload")"; model_id=${model_id%%\[*}
cw="$(jq -r '.context_window.context_window_size // empty' <<<"$payload")"
cap="$(jq -r --arg m "$model_id" '.modelSettings[$m].autoCompactWindow // .autoCompactWindow // empty' \
        "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" 2>/dev/null)"
window="${cw:-null}"
if [ -n "$cap" ] && [ "$cap" -gt 0 ] 2>/dev/null && [ -n "$cw" ] && [ "$cap" -lt "$cw" ] 2>/dev/null; then window=$cap; fi
jq -c --arg agent "${name:-unnamed}" --arg sid "$sid" --arg ts "$(date -u +%FT%TZ)" --arg cwd "$(pwd)" \
   --arg wt "$(git rev-parse --show-toplevel 2>/dev/null | xargs -r basename)" \
   --arg activity "${CLAUDE_ACTIVITY:-working}" --argjson total "${out_total:-0}" --arg has_tokens "${last_out:+1}" \
   --argjson window "$window" '
  { agent: $agent, session_id: $sid, ts: $ts, cwd: $cwd, worktree: ($wt | if . == "" then null else . end),
    model: (.model.display_name // .model.id // "?"),
    context: { remaining_pct: (.context_window.remaining_percentage // null),
               window: $window,
               used: (.context_window.total_input_tokens // null) },
    tokens:  { output_total: (if $has_tokens == "1" then $total else null end) },
    week:    { used_pct: (.rate_limits.seven_day.used_percentage // null) },
    five_hour: { used_pct: (.rate_limits.five_hour.used_percentage // null) },
    activity: $activity }' <<<"$payload" > "$DIR/$sid.json.tmp" && mv -f "$DIR/$sid.json.tmp" "$DIR/$sid.json"
# the status line itself: what the person sees
printf '%s · ctx %s%% left · week %s%%\n' "${name:-unnamed}" "$(jq -r '.context_window.remaining_percentage // "?"' <<<"$payload")" "$(jq -r '.rate_limits.seven_day.used_percentage // "?"' <<<"$payload")"
