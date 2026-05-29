#!/usr/bin/env bash
# .claude/hooks/user-prompt-check.sh — fired by Claude Code on UserPromptSubmit.
#
# Prints a one-line reminder to stderr when .agent/session.active is missing.
# Claude Code surfaces hook stderr as additional context the agent sees on its
# next turn, so this nudges the agent to run scripts/init.sh before real work
# without blocking the user's prompt.

set -uo pipefail

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"

if [[ ! -f .agent/session.active ]]; then
  printf 'reminder: .agent/session.active is missing — run `bash scripts/init.sh` before any code change. (See AGENTS.md hard rules.)\n' >&2
fi

exit 0
