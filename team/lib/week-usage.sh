#!/usr/bin/env bash
# team/lib/week-usage.sh — how much of the account's week has been used, read from the rows the context
# publisher writes (docs/context-publisher.md). One reading for the panel and the budget, so the two never
# disagree. Sourced; parses no arguments.
#
#   week_used   -> "<used %> <epoch seconds of the freshest row>", or "-1 0" with no reading at all
#
# The figure is the HIGHEST `week.used_pct` among the rows whose session last made a request within a minute
# of the latest request any row reports, not the freshest row's own: each session's figure is as of its own last
# request, so a session that has just answered can carry a lower figure than one that answered a second later.
# A row's last request is its `resp_at`, the time its publisher last saw a new response, and without one its `ts`
# less its `idle_s` when it is idle (docs/context-publisher.md). A session that wakes from idle goes `working` at
# once but keeps its old figure until its first response comes back, so a session idle since before a reset read
# 99% for that moment when judged by `ts` (2026-11-22: two false day-over alerts). `resp_at` keeps it out. An idle session
# keeps rewriting its row with the figure from before it went idle, and a reset of the week can leave
# `resets_at` unchanged, so judging rows by `ts` alone let sessions idle since before a reset hold the reading at
# 99% while working ones read 1% (owner, 2026-11-21). A row nothing writes any more drops out the same way. A
# file that is not JSON is skipped, not fatal. A row with a `login` is a session on a named login (team/claude-as.sh):
# its figure is another subscription's week, so it is left out.
#
# Reads CONTEXT_DIR (default ~/.local/state/<project>/context).
week_used() {
  local dir="${CONTEXT_DIR:-$HOME/.local/state/${HARNESS_PROJECT:-harness}/context}"
  cat "$dir"/*.json 2>/dev/null | jq -rR 'fromjson? // empty | select(.week.used_pct != null and .login == null)
      | ((.ts | fromdateiso8601?) // 0) as $t
      | [$t, .week.used_pct,
         (if (.resp_at | type) == "number" then .resp_at
          else $t - (if .activity == "idle" and (.idle_s | type) == "number" then .idle_s else 0 end) end)]
      | @tsv' 2>/dev/null \
    | awk -F'\t' '{ w[NR] = $2 + 0; q[NR] = $3 + 0; if ($1 + 0 > at) at = $1 + 0; if ($3 + 0 > lq) lq = $3 + 0 }
        END { if (!NR) { print "-1 0"; exit }
              hw = -1; for (i = 1; i <= NR; i++) if (q[i] >= lq - 60 && w[i] > hw) hw = w[i]
              printf "%d %d\n", hw, at }'
}
