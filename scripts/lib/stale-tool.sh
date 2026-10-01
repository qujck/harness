# shellcheck shell=bash
# scripts/lib/stale-tool.sh — "is THIS copy of the script behind origin/main?", for every ledger tool.
# (infra_a_ledger_tool_cannot_say_which_revision_of_itself_ran;
#  infra_the_stale_script_warning_arrives_above_the_output_you_asked_for_and_nobody_reads_it)
#
# Sourced by scripts/feature-ticket.sh and scripts/ledger-db.sh. Moved here from feature-ticket.sh so the
# second script stops being a copy that can drift: ledger-db.sh had NO stale-copy detection at all, and on
# 2026-09-20 a 308-commit-old copy of it answered "no such verb" for `amend`, a verb main had.
#
# Usage, at the top of a tool:
#     STALE_TOOL_NAME=feature-ticket
#     . "$(dirname "${BASH_SOURCE[0]}")/lib/stale-tool.sh"
#     warn_if_stale_tool "${BASH_SOURCE[0]}"
#     [[ "$STALE_TOOL_BEHIND" == 1 ]] && trap _stale_tool_trailer EXIT
# A tool that installs its own EXIT trap later must chain `_stale_tool_trailer` into it.
STALE_TOOL_NAME="${STALE_TOOL_NAME:-tool}"

# ── WHICH REVISION OF THIS TOOL IS RUNNING? ──────────────────────────────────────────────────────
# (infra_a_ledger_tool_cannot_say_which_revision_of_itself_ran)
#
# A ledger tool run from a worktree parked on an old branch executes THAT BRANCH's copy of itself —
# silently. Every guard, message and verdict is the one from whenever that branch was cut, so the
# tool can behave like a version whose defects were fixed days ago and nothing anywhere says so. It
# is the sibling of the stale-DATA defect fixed alongside it in this branch: same cause, but the
# stale thing is the CODE rather than the ticket.
#
# tool_revision_verdict <blob-here> <blob-on-main> -> current | differs | unknown           (pure)
#
# ⚠ IT WARNS, IT DOES NOT RE-EXEC, and that is a deliberate departure from the other fixes in this
# class. Re-execing origin/main's copy is right for an UNATTENDED timer and wrong here: an agent
# editing this script must still be able to run the script they just edited. Silently swapping the
# executable under someone testing a change is a worse bug than the one being fixed — and it would
# have made every `--self-test` run in this session a test of main's copy rather than of mine.
#
# ⚠ UNKNOWN IS NOT STALE. Offline, a fresh clone, a detached CI checkout — origin/main may simply
# not be there, and a tool that cries wolf whenever it cannot compare gets muted within a day, which
# is the same outcome as not having it. Say nothing unless both sides are known AND they differ.
#
# ⚠⚠ AND `differs` IS NOT `behind`. This compares BLOB HASHES of one file; it never compares commits,
# so it CANNOT know which side is older. An uncommitted edit to this file produces the identical
# verdict, and then the executing copy is NEWER than main. The message must therefore state what was
# measured and name both causes — see fix_the_stale_tool_warning_asserts_a_direction_it_has_not_established.
# ⚠ DO NOT "FIX" THAT BY COMPUTING THE DIRECTION HERE. `ticket_copy_verdict` below does take a
# main-moved-since count and does distinguish them — that is right for the TICKET FILE, whose two
# cases need opposite handling. This guard is deliberately one hash-object and one rev-parse and
# nothing else, and it runs on every invocation. Say what was measured; do not measure more.
tool_revision_verdict() {
  local here="${1:-}" main="${2:-}"
  [[ -n "$here" && -n "$main" ]] || { printf 'unknown'; return; }
  [[ "$here" == "$main" ]] && printf 'current' || printf 'differs'
}

# tool_staleness_cause <uncommitted 0|1> <branch-changed-it 0|1> <merge-base-known 0|1> -> local | behind | unknown
#                                                                                                    (pure)
# ⚠ WHY THE DIRECTION IS NOW MEASURED, WHEN THE NOTE ABOVE SAYS NOT TO MEASURE MORE. The preamble was right
# and was read past: four agents on 2026-09-15, and Ed twice more on 2026-09-20/21 — once on the very
# night he wrote the warning up. It prints ABOVE a result that looks fine, and a behind copy's `exists`
# returns the same exit 1 ("Raising it is safe") from older EVIDENCE. So the fact has to reach the reader
# where they are looking, and a verb that GRANTS must stop granting — and both of those would nag or block
# the person EDITING this script unless the two causes can be told apart. So they are, but ONLY once the
# blobs already differ (the rare path; the common path is untouched): an uncommitted edit, or a change to
# this file on the checkout's own branch since it left main, is LOCAL — the editor, whose copy is newer.
# Otherwise main changed it and this copy is BEHIND. No merge base, no verdict: UNKNOWN stays silent.
# (infra_the_stale_script_warning_arrives_above_the_output_you_asked_for_and_nobody_reads_it)
tool_staleness_cause() {
  local uncommitted="${1:-0}" branch_changed="${2:-0}" base_known="${3:-0}"
  [[ "$uncommitted" == 1 || "$branch_changed" == 1 ]] && { printf 'local'; return; }
  [[ "$base_known" == 1 ]] && { printf 'behind'; return; }
  printf 'unknown'
}

# Set by warn_if_stale_tool when THIS copy is behind origin/main (never for a local edit). It is what
# makes the trailer print and the grant verbs refuse to grant.
STALE_TOOL_BEHIND=0
STALE_TOOL_REL=""

# The trailer: ONE line, printed at EXIT, after the output the reader asked for — where the eye goes. It
# prints only when behind, so a current copy and an editor's copy gain no new line at all.
_stale_tool_trailer() {
  [[ "${STALE_TOOL_BEHIND:-0}" == 1 ]] || return 0
  printf '%s: ⚠ THE RESULT ABOVE CAME FROM A STALE COPY of %s — this checkout is BEHIND origin/main, so its guards and verdicts are that branch'"'"'s, not main'"'"'s. Re-run it from a checkout of origin/main before acting on it.\n' "$STALE_TOOL_NAME" "${STALE_TOOL_REL:-this script}" >&2
}

# The fetch half. NO NETWORK: origin/main is the local remote-tracking ref these tools already keep
# fresh, so the common path costs one hash-object and one rev-parse and nothing else.
warn_if_stale_tool() { # <path to the running script>
  local f="${1:-}" rel here main
  [[ -n "$f" && -f "$f" ]] || return 0
  # Captured, then cut to the first line — no `| head -1`, whose early exit pipefail turns into a failure.
  rel="$(git ls-files --full-name -- "$f" 2>/dev/null || true)"; rel="${rel%%$'\n'*}"
  [[ -n "$rel" ]] || return 0
  here="$(git hash-object -- "$f" 2>/dev/null || true)"
  main="$(git rev-parse --verify --quiet "origin/main:$rel" 2>/dev/null || true)"
  [[ "$(tool_revision_verdict "$here" "$main")" == "differs" ]] || return 0
  {
    printf '%s: WARNING you are running a DIFFERENT revision of %s than origin/main.\n' "$STALE_TOOL_NAME" "$rel"
    printf '%s:   this copy   %s   (what is executing)\n' "$STALE_TOOL_NAME" "${here:0:9}"
    printf '%s:   origin/main %s\n' "$STALE_TOOL_NAME" "${main:0:9}"
    printf '%s:   ⚠ THAT IS A BLOB COMPARISON OF THIS ONE FILE. It does not say which\n' "$STALE_TOOL_NAME"
    printf '%s:   side is older — nothing above compared commits. TWO THINGS PRODUCE IT:\n' "$STALE_TOOL_NAME"
    printf '%s:     · this checkout PREDATES main — the guards and messages you are\n' "$STALE_TOOL_NAME"
    printf '%s:       seeing are the ones from whenever it was cut; or\n' "$STALE_TOOL_NAME"
    printf '%s:     · you have UNCOMMITTED changes to this file — the copy executing\n' "$STALE_TOOL_NAME"
    printf '%s:       is your own, and is NEWER than main rather than older.\n' "$STALE_TOOL_NAME"
    printf '%s:   Either way nothing was re-executed. To tell them apart:\n' "$STALE_TOOL_NAME"
    printf '%s:     git status --short -- %s\n' "$STALE_TOOL_NAME" "$rel"
    printf '%s:     git rev-list --count HEAD..origin/main   # 0 = not behind\n' "$STALE_TOOL_NAME"
  } >&2
  local uncommitted=0 branch_changed=0 base_known=0 base
  git diff --quiet HEAD -- "$f" 2>/dev/null || uncommitted=1
  if base="$(git merge-base HEAD origin/main 2>/dev/null)" && [[ -n "$base" ]]; then
    base_known=1
    git diff --quiet "$base" HEAD -- "$f" 2>/dev/null || branch_changed=1
  fi
  if [[ "$(tool_staleness_cause "$uncommitted" "$branch_changed" "$base_known")" == behind ]]; then
    STALE_TOOL_BEHIND=1; STALE_TOOL_REL="$rel"
  fi
}

# run DIRECTLY (not sourced): only --self-test means anything; a mistyped flag is refused (exit 2)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/selftest-flag.sh"
  selftest_reject_typo "${1:-}"
  if selftest_is_flag "${1:-}"; then echo "stale-tool.sh carries no self-test of its own (its arms run inside ledger-db.sh's); nothing to run" >&2; exit 2; fi
  echo "stale-tool.sh is a sourced library with no CLI" >&2; exit 2
fi
