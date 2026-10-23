#!/usr/bin/env bash
# scripts/lib/week-usage.sh — how much of the account's week has been used, read from the rows the context
# publisher writes (docs/context-publisher.md). One reading for the panel and the budget, so the two never
# disagree. Sourced; parses no arguments.
#
#   week_used   -> "<used %> <epoch seconds of the freshest row>", or "-1 0" with no reading at all
#
# The figure is the HIGHEST `week.used_pct` among the rows written within a minute of the freshest one, not
# the freshest row's own: each session's figure is as of its own last request, so a session that has just
# answered can carry a lower figure than one that answered a second later, and a row nothing writes any more
# keeps its last figure for ever. Claude Code drops the figure when the week resets, so a figure from before a
# reset counts only until its row is a minute older than the freshest, which only a session that has stopped
# writing leaves behind. A file that is not JSON is skipped, not fatal.
#
# Reads CONTEXT_DIR (default ~/.local/state/<project>/context).
week_used() {
  local dir="${CONTEXT_DIR:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/context}"
  cat "$dir"/*.json 2>/dev/null | jq -rR 'fromjson? // empty | select(.week.used_pct != null)
      | [((.ts | fromdateiso8601?) // 0), .week.used_pct] | @tsv' 2>/dev/null \
    | awk -F'\t' '{ t[NR] = $1 + 0; w[NR] = $2 + 0; if ($1 + 0 > at) at = $1 + 0 }
        END { if (!NR) { print "-1 0"; exit }
              hw = -1; for (i = 1; i <= NR; i++) if (t[i] >= at - 60 && w[i] > hw) hw = w[i]
              printf "%d %d\n", hw, at }'
}
