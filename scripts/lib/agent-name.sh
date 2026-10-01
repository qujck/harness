#!/usr/bin/env bash
# scripts/lib/agent-name.sh — who is this agent? ONE resolver, used by every script that asks.
# (fix_agent_name_requires_init_sh_so_non_stack_agents_cannot_claim)
#
# WHY THIS EXISTS. Being NAMED and RUNNING A STACK are separate things, and the harness had them
# conflated: the only way to be named was `.agent/name`, which only `init.sh` writes, and `init.sh`
# brings up a complete per-stream stack. So an agent whose whole job is to raise and groom tickets —
# no build, no containers — could not claim a ticket at all. `AGENT_NAME=doug feature-ticket.sh claim`
# was tried first and silently ignored, because nothing consulted the variable. The workaround was to
# hand-write the dotfile: undocumented folklore the next person has to rediscover.
#
# It bites more than one role. Anyone triaging on a box already at the four-stack cap, or capturing a
# ticket from a checkout they never intend to build in, hits the same wall — and the old error's advice
# ("run scripts/init.sh first") is advice they should NOT take, because it spends a stack slot on a
# JSON edit. verify.sh already knows the distinction: it has a fast lane that skips build, unit and e2e
# entirely for docs/ledger/spec-only diffs.
#
# ── THE PRECEDENCE ─────────────────────────────────────────────────────────────────────────────
#
#   0. `$GIT_AUTHOR_EMAIL` → agents/roster.json → name   — the SESSION's identity          ← wins
#   1. `.agent/name`, if present and non-empty           — a DIRECTORY's label (warns)
#   2. `$AGENT_NAME` from the environment                — named without a stack
#   3. refuse                                            — naming every route
#
# ⚠ RUNG 0 WAS ADDED 2026-08-13 AND IT DELIBERATELY OUTRANKS THE FILE.
# (feat_agent_identity_is_session_scoped)
#
# The header below already says "TWO DIFFERENT QUESTIONS, AND CONFLATING THEM WOULD BE A BUG", and
# then rung 1 answers "what is MY name?" by reading a file out of the current directory — which is
# `agent_name_of(cwd)`, the other question. The intent was documented; the mechanism never achieved
# it. **`.agent/name` can only ever answer "who owns this DIRECTORY".** On 2026-08-13 one agent
# registered herself as another by running a single command from the shared checkout, and nothing
# was wrong with her behaviour: she read a directory's label as an identity, which is a reasonable
# thing to do and wrong.
#
# `$GIT_AUTHOR_EMAIL` is set at session launch, so it belongs to the PROCESS and travels with every
# child of it. It cannot be borrowed by standing somewhere.
#
# ⚠ AND IT IS NOT THE SAME HAZARD AS LETTING $AGENT_NAME WIN, which the note below rightly forbids.
# A stray `AGENT_NAME` re-stamps a claim with a name that appears NOWHERE else, so the ledger and the
# commits disagree and nothing detects it. `GIT_AUTHOR_EMAIL` is the address git will author the
# commit with **whatever this resolver decides** — so resolving the name FROM it is what makes
# `claimed_by` and the commit author incapable of disagreeing. That is the entire point: one identity
# source, not two. Any other order reintroduces the second source it exists to remove.
#
# ⚠ AN UNROSTERED ADDRESS DOES NOT NAME YOU. It falls through to the rungs below rather than
# inventing a name from the local-part — a name that never reaches the roster cannot be routed to,
# and `feature-ticket.sh claim` refuses it outright, which is the real forcing function.
#
# ⚠ THE ORDER OF 1 AND 2 MUST NOT BE FLIPPED. If the environment won there, a stray AGENT_NAME left
# in a shell would silently re-stamp a properly-initialised agent's claims with somebody else's name.
# File first, env as fallback.
#
# ⚠ THIS IS A SECOND WAY TO BE NAMED, NOT PERMISSION TO BE NAMELESS. Unset, empty and whitespace-only
# all still refuse.
#
# ⚠ TWO DIFFERENT QUESTIONS, AND CONFLATING THEM WOULD BE A BUG.
#   * `agent_name_resolved` answers "what is MY name?" — file, then environment.
#   * `agent_name_of <dir>` answers "who holds THAT worktree?" — the FILE ONLY, never the environment.
# The environment belongs to the process reading it, not to the directory being read. agent-stacks.sh
# scans peer worktrees to say who is on the box; if it fell back to $AGENT_NAME it would label another
# agent's stack with the name of whoever happened to run the command — a confident, wrong answer to the
# one question that tool exists to answer.

# The name recorded IN a directory. File only. Empty if absent, unreadable or blank.
agent_name_of() {
  local f="${1:-.}/.agent/name" n
  [[ -r "$f" ]] || return 0
  n="$(tr -d '\r\n' < "$f" 2>/dev/null || true)"
  # shellcheck disable=SC2001
  n="$(printf '%s' "$n" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  printf '%s' "$n"
}

# The same shape init.sh enforces when it writes the file. Applied to the ENVIRONMENT route because
# that route is new and unvalidated; a name reaches branch names, issue text and the stand-up board's
# filename key, so "  " or "a/b" must not get in. The FILE route is accepted as written: init.sh
# already validated it, and re-validating could lock out an agent whose name predates this check.
agent_name_valid() { [[ "${1:-}" =~ ^[A-Za-z][A-Za-z0-9_-]{1,31}$ ]]; }

# The SESSION's name: $GIT_AUTHOR_EMAIL → roster → name. Empty if the variable is unset or the
# address is not in the register.
#
# ⚠ THIS IS THE ONLY IDENTITY FACT THAT BELONGS TO THE PROCESS RATHER THAN TO A DIRECTORY, which is
# exactly why it can settle a question no file in a directory can. It never falls back to anything
# on disk — that fallback is the bug this rung was added to remove.
agent_name_from_session() {
  local e n
  # shellcheck disable=SC2001
  e="$(printf '%s' "${GIT_AUTHOR_EMAIL:-}" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "$e" ]] || return 0
  # The roster library is optional at this layer: agent-name.sh is sourced by scripts that run before
  # anything is set up, and a missing helper must degrade to the old behaviour rather than explode.
  if ! declare -F roster_lookup_name >/dev/null 2>&1; then
    local lib="${BASH_SOURCE[0]%/*}/roster.sh"
    [[ -r "$lib" ]] || return 0
    # shellcheck disable=SC1090
    . "$lib"
  fi
  n="$(roster_lookup_name "$e" 2>/dev/null)"
  [[ -n "$n" ]] && agent_name_valid "$n" && printf '%s' "$n"
}

# ── RUNG 2: $AGENT_NAME — NAMED WITHOUT A STACK, AND IT MUST BE A NAME THE ROSTER KNOWS ────────
#
# ⚠ FACTORED OUT BECAUSE agent_name_resolved AND agent_name_source BOTH IMPLEMENTED THIS RUNG, and
# two copies of a rule is one copy that gets fixed. Validating in one and not the other would make
# them disagree about the same environment — the resolver naming somebody the source cannot account
# for, which is the exact confusion this file exists to end.
#
# WHY THE ROSTER CHECK. Rung 0 resolves an ADDRESS through the roster and REJECTS an unrostered one.
# Rung 2 accepted any string, so the two rungs disagreed about what a name is:
#
#     AGENT_NAME=Cara                 -> Cara                 (rostered)
#     AGENT_NAME=NotARealAgentAtAll   -> NotARealAgentAtAll   <- ACCEPTED, no roster check
#
# and the ledger stamps `claimed_by`, the issue title, `parked_by` and the progress filename from
# THIS field while the pre-commit gate validates GIT_AUTHOR_EMAIL — a DIFFERENT field. So a bogus
# name alongside a valid git identity passed every gate there is, because nothing downstream looks
# at this one. (infra_the_identity_refusal_offers_the_one_rung_that_validates_nothing)
#
# ⚠⚠ AND BE HONEST ABOUT WHAT THIS IS. It proves the provenance of an ENVIRONMENT VARIABLE, not of
# an agent: anyone may set this to any name in the roster. It is an ANTI-MISTAKE control — it
# catches the invented name, the typo, and the copied-from-a-neighbour label, which is the accident
# that actually happened — and it is NOT a boundary against deliberate misattribution. Do not
# describe it as one, and do not "harden" it: every stronger rung available here is equally
# settable one layer down, and the ones that are not block a session that genuinely cannot relaunch
# itself.
#
# ⚠ AND WHEN THE ROSTER CANNOT BE READ, IT SAYS SO RATHER THAN PRETENDING EITHER WAY. Refusing would
# break a bootstrap on a checkout that has no roster yet — a real state: on 2026-08-14 a checkout 31
# commits behind had no agents/roster.json at all. Silently accepting would be a validation that did
# not happen wearing the badge of one that did. So it accepts and warns, once, on stderr.
agent_name_from_env() {
  local n
  # shellcheck disable=SC2001
  n="$(printf '%s' "${AGENT_NAME:-}" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "$n" ]] || return 0
  agent_name_valid "$n" || return 0
  # The roster library is optional at this layer, exactly as it is for rung 0 above.
  if ! declare -F roster_has_name >/dev/null 2>&1; then
    local lib="${BASH_SOURCE[0]%/*}/roster.sh"
    if [[ -r "$lib" ]]; then
      # shellcheck disable=SC1090
      . "$lib"
    fi
  fi
  # ⚠ "THE ROSTER SAYS NOBODY" IS NOT "THIS NAME IS NOT IN THE ROSTER", AND roster.sh CANNOT TELL
  # YOU WHICH. `_roster_json` falls back to `{"agents":[]}` when the file is unreadable, so a missing
  # roster and an empty one are byte-identical downstream — every name reads as unrostered. Rung 0
  # tolerates that (it finds no name and falls through); a rung that REFUSES on it would lock out a
  # legitimately rostered agent running from anywhere the roster is not reachable — which is most
  # pre-stack scripts and every temp-dir fixture, since roster_file() is
  # `${ROSTER_FILE:-${REPO_ROOT:-.}/agents/roster.json}`. Caught by this file's own self-test, which
  # went from naming an agent to naming nobody the moment validation landed.
  #
  # A real roster always lists somebody. So: no names at all == COULD NOT LOOK -> accept and say so.
  local known=''
  if declare -F roster_list_known >/dev/null 2>&1; then
    known="$(roster_list_known 2>/dev/null | head -1)"
  fi
  if [[ -z "$known" ]] || ! declare -F roster_has_name >/dev/null 2>&1; then
    [[ -n "${_AGENT_NAME_ROSTERLESS_WARNED:-}" ]] || {
      _AGENT_NAME_ROSTERLESS_WARNED=1
      printf 'agent-name: the roster could not be read, so AGENT_NAME=%q was NOT checked against it. This is "could not look", not "looked and it is fine".\n' "$n" >&2
    }
    printf '%s' "$n"; return 0
  fi
  roster_has_name "$n" 2>/dev/null || return 0
  printf '%s' "$n"
}

# MY name, by the precedence above. Echoes it and returns 0, or echoes nothing and returns 1.
agent_name_resolved() {
  local root="${1:-${REPO_ROOT:-.}}" n
  n="$(agent_name_from_session)"
  if [[ -n "$n" ]]; then printf '%s' "$n"; return 0; fi
  n="$(agent_name_of "$root")"
  if [[ -n "$n" ]]; then printf '%s' "$n"; return 0; fi
  n="$(agent_name_from_env)"
  if [[ -n "$n" ]]; then printf '%s' "$n"; return 0; fi
  return 1
}

# Which rung answered — 'session', 'file', 'env' or '' — so a caller can say so out loud.
#
# ⚠ CALLERS ARE EXPECTED TO WARN ON 'file'. A directory's label is a legacy identity: it is usually
# right and it is the one that produced a wrong owner on a claim. Saying which rung answered is what
# lets the warning exist at all.
agent_name_source() {
  local root="${1:-${REPO_ROOT:-.}}" n
  [[ -n "$(agent_name_from_session)" ]] && { printf 'session'; return 0; }
  [[ -n "$(agent_name_of "$root")" ]] && { printf 'file'; return 0; }
  n="$(agent_name_from_env 2>/dev/null)"
  [[ -n "$n" ]] && { printf 'env'; return 0; }
  printf ''
}

# ── WHICH SESSION OWNS THIS DIRECTORY? (fix_agent_cannot_identify_its_own_session) ──────────────
#
# ⚠ THE HEADER OF THIS FILE ALREADY SAYS "TWO DIFFERENT QUESTIONS, AND CONFLATING THEM WOULD BE A
# BUG" — and then `agent_name_resolved` answers "what is MY name?" by reading `.agent/name` from the
# current directory, which IS `agent_name_of(cwd)`. The intent was documented; the mechanism never
# achieved it. `.agent/name` can only ever answer "who owns this DIRECTORY".
#
# MEASURED 2026-08-09: an agent spent two exchanges genuinely unsure which of two agents she was, and
# could not settle it from anything on disk. Her shell sat in the shared checkout, so the name she
# read was that DIRECTORY's label. Two different directories' name files both read `Don`, NEITHER
# with a live marker — the file was actively misleading, not merely silent. It was resolvable only
# from OUTSIDE the box, by intersecting two agent listings on the property that a session does not
# list itself: the name missing from your own listing is you.
#
# ⚠ NEITHER AGENT WAS CARELESS, so a fix aimed at behaviour would have missed it. One set the name by
# hand and never ran init.sh; the other read a directory's name as an identity, which is a reasonable
# thing to do and wrong. Two sensible acts produced a wrong owner on a claim.
#
# THE MISSING FACT IS A SESSION ID, and it already exists: $CLAUDE_CODE_SESSION_ID is present in the
# environment of any script an agent runs, and matches that session's own transcript filename.
# `session.active` now carries it on line 2 — line 1 stays the timestamp, which handoff.sh displays.

# The session id recorded in a directory's marker. Empty if absent, old-format or unreadable.
agent_session_of() {
  local f="${1:-.}/.agent/session.active"
  [[ -r "$f" ]] || return 0
  sed -n 's/^session[[:space:]]\{1,\}//p' "$f" 2>/dev/null | head -1 | tr -d '\r\n'
}

# MY session id, from the environment. This is the ONE identity fact that belongs to the PROCESS
# rather than to a directory — which is exactly why it can settle a question no file in a directory
# can. Never falls back to anything on disk: that fallback is the bug.
agent_session_id() { printf '%s' "${CLAUDE_CODE_SESSION_ID:-}"; }

# PURE: does this session own that marker? Every fact is an argument, so the verdict table is driven
# by --self-test with no filesystem and no second live agent.
#
#   mine    the marker names MY session
#   other   the marker names a DIFFERENT session — the name in that directory is NOT mine
#   legacy  a marker with no session id, or this process has no session id to compare
#
# ⚠ `legacy` MUST STAY PERMISSIVE. Markers written before this shipped carry no id, and agents are
# live under them right now — treating an old marker as a mismatch would lock out every session
# already running at the moment this merges.
agent_session_verdict() { # <marker_session_id> <my_session_id>
  local theirs="${1:-}" mine="${2:-}"
  [[ -z "$theirs" || -z "$mine" ]] && { printf 'legacy\n'; return 0; }
  [[ "$theirs" == "$mine" ]] && { printf 'mine\n'; return 0; }
  printf 'other\n'
}

# The whole answer for a directory, including the no-marker case the pure verdict cannot see.
#   mine | other | legacy | none
#
# ⚠ `none` IS NOT AN ERROR AND MUST NOT BECOME ONE. A finished worktree keeps its `.agent/name` so
# the name can be REUSED; requiring a live marker is what stops every retired worktree reserving its
# name for ever. `none` means "do not infer identity from this file", not "something is wrong".
agent_directory_identity() {
  local root="${1:-${REPO_ROOT:-.}}"
  [[ -f "$root/.agent/session.active" ]] || { printf 'none\n'; return 0; }
  agent_session_verdict "$(agent_session_of "$root")" "$(agent_session_id)"
}

# May this session take its NAME from this directory? Echoes `ok`, or the reason it may not.
#
# ⚠ REFUSE ONLY ON A PROVABLE MISMATCH. `other` is the single case where the file demonstrably
# belongs to somebody else — another session wrote that marker and is live in it. `none` and `legacy`
# are ambiguous, and a guard that fires on ambiguity rather than on evidence gets switched off, after
# which it guards nothing. Refusing on them would also break the documented AGENT_NAME route, every
# agent already running under an old marker, and the reuse of a retired worktree's name.
agent_name_trust() { # <identity verdict> <name in the directory>
  case "${1:-}" in
    other) printf "the .agent/name here says '%s', but this directory's session.active belongs to a DIFFERENT session — that name is not yours\n" "${2:-}" ;;
    *)     printf 'ok\n' ;;
  esac
}

# The refusal. ⚠ IT NAMES THE VALIDATED ROUTE FIRST, AND THAT ORDER IS THE FIX.
#
# This message has now been repaired twice and the FIRST repair caused the defect the second one
# removes. It originally named only init.sh — "the one thing that did not need to be true" — so it
# was widened to add `AGENT_NAME=`, which at the time accepted ANY string. A gate that refuses
# correctly and then prints a route around itself has not protected anything; it has published the
# bypass with the authority of an error message.
# (feedback_a_remedy_a_tool_prints_must_not_create_the_state_the_gate_forbids,
#  infra_the_identity_refusal_offers_the_one_rung_that_validates_nothing)
#
# `agent-onboard.sh --launch-line` is first because it is the route CLAUDE.md calls the single
# generator — the one that makes commits, claims, park markers and progress filenames say YOU, and
# the only one that cannot be satisfied by inventing a string. AGENT_NAME stays, because several
# scripts run before a stack exists and Anthony's self-test fix depends on it — it is now
# roster-checked, which is what makes naming it safe.
agent_name_refusal() {
  printf 'no agent name. Get your launch line from `bash scripts/agent-onboard.sh --launch-line <Name>` (the sanctioned route — one generator, and it is the one that makes your commits, claims and progress files say YOU). %s %s' \
    'Otherwise: AGENT_NAME=<a name in agents/roster.json>, or run scripts/init.sh (which writes .agent/name).' \
    'Every agent MUST be named — an unnamed claim is the ownership ambiguity naming exists to remove. Names are 2-32 chars, letters/digits/-/_, starting with a letter, and must be in the roster.'
}

# Is a session identity being OFFERED but not taken? -> '' when fine, else why.
#
# ⚠ THE DIFFERENCE BETWEEN "NO IDENTITY WAS GIVEN" AND "AN IDENTITY WAS GIVEN AND SILENTLY IGNORED".
#
# Rung 0 returns empty for three completely different situations and the caller cannot tell them
# apart, so all three fall through to the directory label and answer confidently:
#
#   a) GIT_AUTHOR_EMAIL unset            — nothing was offered. The fallback is doing its job.
#   b) set, but no roster in this tree   — the operator did everything right and it did not take.
#   c) set, but the address is unrostered— likewise, and probably a typo in the launch line.
#
# (b) is not hypothetical and it is why the launch line alone was not the whole fix. Measured
# 2026-08-14: every session's process cwd is /home/peter/dev/strength, which was 31 commits behind
# main and had no agents/roster.json at all — so rung 0 COULD NOT ANSWER even with the variable set
# correctly, and the resolution fell to a directory file for all five sessions.
#
# ⚠ (b) and (c) are the worse shape by far: correct input, silent failure, confident wrong answer.
# An operator who sets the variable has every reason to believe it worked, and nothing says
# otherwise. That is the same self-sealing failure as a probe that fails toward "everything is fine"
# — and it is what let one name serve five sessions for six days.
# (feat_agent_onboarding_and_offboarding)
agent_name_identity_warning() { # $1 repo root
  local root="${1:-${REPO_ROOT:-.}}" e n
  e="$(printf '%s' "${GIT_AUTHOR_EMAIL:-}" | tr -d '\r\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [[ -n "$e" ]] || return 0                                   # (a) nothing offered — not a warning
  [[ -n "$(agent_name_from_session)" ]] && return 0            # took correctly — nothing to say
  # ⚠ ASK THE SAME QUESTION RUNG 0 ASKED, ALONG THE SAME PATH. My first version tested
  # "$root/agents/roster.json" while rung 0 resolves through roster_file() — ROSTER_FILE, else
  # REPO_ROOT, else cwd. Those are different paths and they DID disagree: the diagnosis said "no
  # roster here" about a lookup that had actually succeeded against a roster somewhere else. A
  # diagnostic that does not retrace the exact step it is explaining will confidently misdiagnose —
  # which is the failure it exists to prevent, one level up. My own test caught it.
  local rf=""
  declare -F roster_file >/dev/null 2>&1 && rf="$(roster_file 2>/dev/null)"
  [[ -n "$rf" ]] || rf="${ROSTER_FILE:-${REPO_ROOT:-$root}/agents/roster.json}"
  if [[ ! -r "$rf" ]]; then
    printf 'GIT_AUTHOR_EMAIL is set to %s but no roster is readable at %s, so it could not be resolved and the name fell back to a directory label. That tree is probably behind main.' "$e" "$rf"
    return 0
  fi
  printf 'GIT_AUTHOR_EMAIL is set to %s but that address is not in agents/roster.json, so it was ignored and the name fell back to this directory label. Check the address in your launch line.' "$e"
}

# ── self-test ─────────────────────────────────────────────────────────────────────────────────
# Proves the precedence, both refusals and the peer-directory rule without touching a real worktree.
# ── is another LIVE worktree already using my name? ────────────────────────────────────────────
# (infra_agent_names_are_not_unique_across_worktrees)
#
# ⚠ THE CROSS-WORKTREE SCAN ALREADY EXISTED IN init.sh AND WAS CORRECT. What it could not cover is
# an agent who never RAN init.sh: writing `.agent/name` by hand (or exporting AGENT_NAME) skips the
# scan entirely, so the name is never checked — and, because that worktree also has no
# `session.active`, it is invisible to every OTHER agent's correct scan too. Both directions fail
# silently, which is why it produced a duplicate rather than a refusal. Observed 2026-08-08: two
# live agents both called Don.
#
# The fix is to ask the question where the name is READ, not only where it is written — so it is
# here, in the one resolver every reader already shares, and init.sh and feature-ticket.sh call the
# same code rather than growing a second copy that can drift.

# The per-sibling decision. Pure, self-tested.
#   agent_name_conflict_kind <my_name> <their_name> <their_marker: 1|0> [<their_identity>] -> conflict | ok
#
# ⚠ THE LIVE MARKER REQUIREMENT STAYS, and must not be "fixed" away. It is what lets a FINISHED
# worktree's name be reused; matching on `.agent/name` alone would make every retired worktree
# reserve its name for ever, and the box accumulates those.
#
# ⚠ `their_identity` IS THE FIX FOR `infra_the_name_uniqueness_guard_stores_the_session_id_and_never_reads_it`.
# The scan used to decide "is a live agent here?" with `[[ -f session.active ]]` — file EXISTENCE, never
# the session id INSIDE it. So the guard could not tell an agent's own abandoned marker from a live
# rival. Driven case: on 2026-08-23 it refused Don the name `Don`, naming
# `/home/peter/dev/strength-don` — whose marker holds HIS OWN session id, written on 11 August in a
# worktree he had left. The guard blocked him on his own behalf, and he could not clear it without
# deleting state in a directory that might have belonged to somebody else.
#
# ⚠ THE REMEDY IS NOT A STALENESS HEURISTIC, and that must not be "simplified" back in later. Ageing a
# marker out makes the guard fail toward *two live agents sharing one name* — the exact failure it
# exists to prevent, and the one whose cost is an unrecoverable wrong owner on a claim. The id is
# already in the file. Read it.
#
# ⚠ AND NOTE THE ASYMMETRY WITH `agent_name_trust`, WHICH LOOKS LIKE AN INCONSISTENCY AND IS NOT.
# Both consume the same four-valued verdict and treat `legacy` in OPPOSITE directions:
#   agent_name_trust      asks "is this name MINE?"        -> refuse only on PROOF of another owner
#                                                             (`other`), be permissive on `legacy`.
#   agent_name_conflict_kind asks "is someone ELSE here?"  -> block unless PROVEN to be me (`mine`),
#                                                             so `legacy` still blocks.
# Each is permissive toward the answer whose error is cheap and strict toward the one whose error is
# expensive, and those are different answers for the two questions. Collapsing them into one rule
# reintroduces either this bug or the lockout `legacy` was added to prevent.
#
# `their_identity` DEFAULTS TO EMPTY = "not provably mine" = the old behaviour. That default is safe
# in the fail-closed direction: a caller that cannot determine identity still gets a conflict. It is
# NOT the "default that reproduces the defect" trap, because the defect was failing OPEN (letting a
# stale own-marker block), and this default fails CLOSED.
agent_name_conflict_kind() {
  local mine="${1:-}" theirs="${2:-}" live="${3:-0}" their_identity="${4:-}"
  # My own marker in a worktree I have left is not a rival. Only `mine` — a PROVEN id match — clears
  # it; `other`, `legacy`, `none` and an unknown/absent verdict all still count as a live peer.
  [[ "$their_identity" == mine ]] && { printf 'ok\n'; return 0; }
  [[ -n "$mine" && -n "$theirs" && "$live" == 1 && "$mine" == "$theirs" ]] \
    && { printf 'conflict\n'; return 0; }
  printf 'ok\n'
}

# The scan. Prints the colliding worktree path and returns 0 when my name is taken by a LIVE peer.
#
# ⚠ THE INCUMBENT IS NEVER THE ONE REFUSED, and that falls out of the marker rule rather than being
# special-cased: a peer is only considered when IT is live. Whoever legitimately holds the name keeps
# working; only the newcomer — the one who never ran init.sh, and so has no marker of their own — is
# asked to choose. Backwards, this would evict the working agent, which is worse than the bug.
agent_name_taken_by() {
  local root="$1" mine="$2" n nroot
  [[ -n "$mine" ]] || return 1
  for n in "$root"/../"${HARNESS_PROJECT:-$(basename -- "$root" | sed "s/-[^-]*$//")}"*/.agent/name; do
    [[ -f "$n" ]] || continue
    nroot="${n%/.agent/name}"
    [[ "$(cd "$nroot" 2>/dev/null && pwd)" == "$root" ]] && continue
    local live=0; [[ -f "$nroot/.agent/session.active" ]] && live=1
    # ⚠ READ THE MARKER, DO NOT MERELY NOTICE IT. `agent_directory_identity` is the SAME reader
    # `agent_name_trust` already uses ten lines up — this scan was the one place that tested the
    # filename instead of the file, so the fix is to call the existing reader rather than to add one.
    if [[ "$(agent_name_conflict_kind "$mine" "$(agent_name_of "$nroot")" "$live" \
             "$(agent_directory_identity "$nroot")")" == conflict ]]; then
      # Normalised, because this path goes into an error message a human has to act on:
      # "/w/strength-b/../strength-a" is the same directory but reads like a different one.
      printf '%s\n' "$(cd "$nroot" 2>/dev/null && pwd || printf '%s' "$nroot")"; return 0
    fi
  done
  return 1
}

# Run DIRECTLY, the self-test flag is the only argument — anything else fell past the guard below
# and exited 0 in silence. Guarded on BASH_SOURCE: when SOURCED, $1 is the caller's.
# (chore_unify_selftest_flag_spelling)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  . "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/selftest-flag.sh"
  if [[ -n "${1:-}" ]] && ! selftest_is_flag "${1:-}"; then
    printf 'unknown argument: %s\n' "$1" >&2
    printf 'usage: agent-name.sh [--self-test]\n' >&2
    exit 2
  fi
fi

if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && selftest_is_flag "${1:-}"; then
  set -uo pipefail
  t_fail() { printf 'agent-name selftest FAIL: %s\n' "$*" >&2; exit 1; }
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  # ⚠ UNSET FIRST. This variable is now rung 0, so a real one inherited from the session running the
  # test would outrank every fixture below and the whole file would assert against the tester's
  # identity instead of the fixtures'. Restored at the end for the rung-0 cases.
  unset GIT_AUTHOR_EMAIL
  mkdir -p "$tmp/withname/.agent" "$tmp/noname/.agent" "$tmp/blank/.agent"
  printf 'sophie\n' > "$tmp/withname/.agent/name"
  printf '   \n'    > "$tmp/blank/.agent/name"

  # 1. The file wins, and keeps winning even when the environment disagrees. This is the whole reason
  #    the order is file-first: a stray variable must never re-stamp an initialised agent.
  # ⚠ ROSTERED FIXTURE NAMES, DERIVED NOT TYPED. Rung 2 is roster-checked since
  # infra_the_identity_refusal_offers_the_one_rung_that_validates_nothing, so the invented names
  # this self-test used ('intruder', 'me') no longer resolve — and these cases assert that the ENV
  # RUNG ANSWERS and that the FILE OUTRANKS IT, not that any string is accepted. Deriving them from
  # the roster means they cannot rot when an agent retires and hardcodes no colleague.
  # ⚠ SOURCE THE ROSTER EXPLICITLY. This file loads roster.sh LAZILY, inside the rung functions, so
  # at this point in the self-test `roster_list_known` is not yet defined — and an undefined function
  # yields an empty name, which is indistinguishable from an empty roster. That is the same
  # missing-vs-empty confusion this change exists to separate, met inside its own test.
  _rostered="$( . "${BASH_SOURCE[0]%/*}/roster.sh" 2>/dev/null
                roster_list_known 2>/dev/null | head -1 | cut -f1 )"
  [[ -n "$_rostered" ]] || t_fail "the roster names nobody — every env-rung case below would assert nothing"
  AGENT_NAME="$_rostered"
  [[ "$(agent_name_resolved "$tmp/withname")" == "sophie" ]] \
    || t_fail ".agent/name must win over AGENT_NAME"
  [[ "$(agent_name_source "$tmp/withname")" == "file" ]] || t_fail "source must report 'file'"

  # 2. Without a file, the environment names you — the point of the ticket.
  [[ "$(agent_name_resolved "$tmp/noname")" == "$_rostered" ]] \
    || t_fail "a ROSTERED AGENT_NAME names an agent that has no .agent/name"
  [[ "$(agent_name_source "$tmp/noname")" == "env" ]] || t_fail "source must report 'env'"

  # 3. A blank file falls through to the environment rather than naming you the empty string.
  [[ "$(agent_name_resolved "$tmp/blank")" == "$_rostered" ]] \
    || t_fail "a whitespace-only .agent/name must not count as a name"

  # 4. THE ANONYMITY GUARD IS NOT WEAKENED. Unset, empty and whitespace-only all refuse.
  unset AGENT_NAME
  agent_name_resolved "$tmp/noname" >/dev/null && t_fail "no name anywhere must refuse"
  AGENT_NAME="" ; agent_name_resolved "$tmp/noname" >/dev/null && t_fail "empty AGENT_NAME must refuse"
  AGENT_NAME="   "; agent_name_resolved "$tmp/noname" >/dev/null && t_fail "whitespace AGENT_NAME must refuse"
  # ⚠ THE ROSTER CHECK ITSELF, AND IT IS THE POINT OF THE CHANGE. A well-formed name that names
  # nobody must NOT resolve: the ledger stamps claimed_by, the issue title, parked_by and the
  # progress filename from this field, and the pre-commit gate validates GIT_AUTHOR_EMAIL — a
  # DIFFERENT field — so an invented name here passed every gate there was.
  AGENT_NAME="NotARealAgentAtAll"
  agent_name_resolved "$tmp/noname" >/dev/null \
    && t_fail "an AGENT_NAME that is in no roster must not resolve"
  [[ -z "$(agent_name_source "$tmp/noname")" ]] \
    || t_fail "source must report nothing for an unrostered AGENT_NAME — resolved and source must agree"
  AGENT_NAME="$_rostered"
  [[ "$(agent_name_resolved "$tmp/noname")" == "$_rostered" ]] \
    || t_fail "…and a ROSTERED name still resolves — validation, not removal"

  AGENT_NAME="1bad"; agent_name_resolved "$tmp/noname" >/dev/null && t_fail "a name must start with a letter"
  AGENT_NAME="a/b"; agent_name_resolved "$tmp/noname" >/dev/null && t_fail "a name must not contain a slash"

  # 5. THE PEER-DIRECTORY RULE. agent_name_of reads the FILE and nothing else, so scanning somebody
  #    else's worktree can never borrow this process's environment and label their stack with my name.
  AGENT_NAME="$_rostered"
  [[ "$(agent_name_of "$tmp/noname")" == "" ]] \
    || t_fail "agent_name_of must never fall back to the environment — that is another agent's directory"
  [[ "$(agent_name_of "$tmp/withname")" == "sophie" ]] || t_fail "agent_name_of must read the file"

  # 6. The refusal names BOTH routes. The old one named only init.sh, which is why the variable was
  #    tried and abandoned as unsupported.
  msg="$(agent_name_refusal)"
  [[ "$msg" == *AGENT_NAME* ]] || t_fail "the refusal must name the AGENT_NAME route"
  # ⚠ THE VALIDATED ROUTE MUST COME FIRST, ASSERTED RATHER THAN MERELY EDITED. This message has been
  # repaired twice and the FIRST repair is what introduced the defect: it added `AGENT_NAME=` — at
  # the time the only rung that validated nothing — and never mentioned the generator. A gate that
  # prints a route around itself has published the bypass with the authority of an error message.
  [[ "$msg" == *"agent-onboard.sh --launch-line"* ]] \
    || t_fail "the refusal must name agent-onboard.sh --launch-line, the sanctioned route"
  [[ "${msg%%AGENT_NAME*}" == *"agent-onboard.sh --launch-line"* ]] \
    || t_fail "the refusal must name the VALIDATED route BEFORE the variable, or it still steers wrong"
  [[ "$msg" == *roster* ]] \
    || t_fail "the refusal must say the name has to be in the roster"
  [[ "$msg" == *init.sh*    ]] || t_fail "the refusal must still name init.sh"

  # 7. ⚠ THE NAME-COLLISION DECISION (infra_agent_names_are_not_unique_across_worktrees).
  #    The case that actually occurred is NOT "two agents pick the same name" — init.sh already
  #    refuses that. It is an agent who never ran init.sh at all.
  _snc() { local got; got="$(agent_name_conflict_kind "$2" "$3" "$4")"
    [[ "$got" == "$1" ]] || t_fail "conflict_kind($2,$3,$4): expected $1, got $got"; }
  _snc conflict Don Don 1        # the observed duplicate: same name, peer is live
  _snc ok       Don Don 0        # peer has no live marker — a finished worktree may reuse its name
  _snc ok       Don Wren 1       # different agents
  _snc ok       ''  Don 1        # I have no name to collide with
  _snc ok       Don ''  1        # the peer has none on disk
  _snc ok       Do  Don 1        # ⚠ EXACT match only — a prefix is a different agent

  # 7. ── WHICH SESSION AM I? (fix_agent_cannot_identify_its_own_session) ────────────────────────
  #
  # THE VERDICT TABLE, pure — no filesystem, no second live agent.
  [[ "$(agent_session_verdict abc abc)" == mine   ]] || t_fail "same session id must be 'mine'"
  [[ "$(agent_session_verdict abc xyz)" == other  ]] || t_fail "a different session id must be 'other'"
  # ⚠ BOTH PERMISSIVE CASES MATTER MORE THAN THE STRICT ONE. Markers written before this shipped
  # carry no id, and agents are live under them right now — treating an old marker as a mismatch
  # would lock out every session already running at the moment this merges.
  [[ "$(agent_session_verdict '' abc)"  == legacy ]] || t_fail "a marker with no id must be 'legacy', never 'other'"
  [[ "$(agent_session_verdict abc '')"  == legacy ]] || t_fail "no session id in MY env must be 'legacy', never 'other'"
  [[ "$(agent_session_verdict '' '')"   == legacy ]] || t_fail "neither side known must be 'legacy'"

  # ⚠ REFUSE ONLY ON PROVABLE MISMATCH. A guard that fires on ambiguity gets switched off, after
  # which it guards nothing — so `none` and `legacy` must be trusted, and only `other` refused.
  [[ "$(agent_name_trust other Don)" != ok   ]] || t_fail "a proven different session must NOT be trusted"
  [[ "$(agent_name_trust other Don)" == *Don* ]] || t_fail "the refusal must name the name it is rejecting"
  [[ "$(agent_name_trust none Don)"   == ok   ]] || t_fail "a leftover label must not be refused — a finished worktree's name is REUSABLE"
  [[ "$(agent_name_trust legacy Don)" == ok   ]] || t_fail "an old-format marker must not be refused"
  [[ "$(agent_name_trust mine Don)"   == ok   ]] || t_fail "my own directory must be trusted"

  # THE REAL LAYOUT THAT PRODUCED THE WRONG OWNER, reconstructed on disk: two directories whose
  # .agent/name both read the same name, NEITHER with a live marker. Measured 2026-08-09.
  mkdir -p "$tmp/shared/.agent" "$tmp/theirs/.agent" "$tmp/mine/.agent"
  printf 'Don\n' > "$tmp/shared/.agent/name"
  printf 'Don\n' > "$tmp/theirs/.agent/name"
  printf 'Cara\n' > "$tmp/mine/.agent/name"
  [[ "$(agent_directory_identity "$tmp/shared")" == none ]] \
    || t_fail "a name file with no marker must read as 'none' — a leftover label, not an identity"
  [[ "$(agent_directory_identity "$tmp/theirs")" == none ]] || t_fail "the second Don directory likewise"

  # Now give one of them a live marker belonging to somebody else. THIS is the provable case.
  CLAUDE_CODE_SESSION_ID=cara-session
  printf '2026-08-09T07:29:12Z\nsession don-session\n' > "$tmp/theirs/.agent/session.active"
  [[ "$(agent_session_of "$tmp/theirs")" == don-session ]] || t_fail "the session id must be read from line 2"
  [[ "$(agent_directory_identity "$tmp/theirs")" == other ]] \
    || t_fail "a marker naming another session must be 'other' — this is the case that puts a wrong name on a claim"

  # ⚠ NEGATIVE CONTROL, BOTH DIRECTIONS. A check that answers "not you" everywhere is exactly as
  # useless as one that answers "you" everywhere, and the first version of any such guard passes the
  # bug report while failing the job.
  printf '2026-08-09T07:29:12Z\nsession cara-session\n' > "$tmp/mine/.agent/session.active"
  [[ "$(agent_directory_identity "$tmp/mine")" == mine ]] \
    || t_fail "NEGATIVE CONTROL: my own worktree must still resolve to me"
  [[ "$(agent_name_trust "$(agent_directory_identity "$tmp/mine")" Cara)" == ok ]] \
    || t_fail "NEGATIVE CONTROL: my own name must still be usable, with no new friction"
  # …and the two verdicts must DIFFER on the same layout, or the check is not discriminating at all.
  [[ "$(agent_directory_identity "$tmp/mine")" != "$(agent_directory_identity "$tmp/theirs")" ]] \
    || t_fail "the same input shape must produce different verdicts — otherwise nothing is being decided"

  # LINE 1 REMAINS THE TIMESTAMP. handoff.sh displays it and init.sh's guards stat this file; a
  # format change that broke either would be a silent regression in a different script.
  [[ "$(head -1 "$tmp/mine/.agent/session.active")" == 2026-08-09T07:29:12Z ]] \
    || t_fail "line 1 of session.active must stay the timestamp"
  unset CLAUDE_CODE_SESSION_ID

  # ── THE SIBLING SCAN MUST READ THE MARKER, NOT MERELY NOTICE IT ─────────────────────────────────
  # (infra_the_name_uniqueness_guard_stores_the_session_id_and_never_reads_it)
  #
  # ⚠ THE VERDICT TABLE, AND `mine` IS THE ONLY ROW THAT CLEARS. Everything else — including an
  # absent 4th argument — still blocks, because the expensive error here is TWO LIVE AGENTS SHARING
  # ONE NAME, which puts an unrecoverable wrong owner on a claim.
  _snc4() { local got; got="$(agent_name_conflict_kind Don Don 1 "$2")"
    [[ "$got" == "$1" ]] || t_fail "conflict_kind(Don,Don,1,'$2'): expected $1, got $got"; }
  _snc4 ok       mine      # my own abandoned marker is not a rival — THE FIX
  _snc4 conflict other     # a different live session IS a rival
  _snc4 conflict legacy    # ⚠ an old marker with no id must STILL block: it may be a live agent
  _snc4 conflict none
  _snc4 conflict ''        # ⚠ absent argument = not provably mine = fail CLOSED

  # ⚠ AND THE ASYMMETRY WITH agent_name_trust, ASSERTED SO IT CANNOT BE "TIDIED" AWAY. The same
  # verdict `legacy` is TRUSTED when asking "is this name mine?" and BLOCKS when asking "is someone
  # else here?". Each is permissive toward the cheap error and strict toward the expensive one.
  [[ "$(agent_name_trust legacy Don)" == ok ]] \
    || t_fail "legacy must stay TRUSTED for name-taking, or every session under an old marker is locked out"
  [[ "$(agent_name_conflict_kind Don Don 1 legacy)" == conflict ]] \
    || t_fail "legacy must stay BLOCKING for the sibling scan, or an unknown live peer is waved through"

  # ── DON'S CASE, RECONSTRUCTED ON DISK, 2026-08-23 ───────────────────────────────────────────────
  # He was refused the name `Don`, cited against /home/peter/dev/strength-don — a worktree he had
  # abandoned on 11 August, whose marker holds HIS OWN session id. The guard blocked him on his own
  # behalf and he had no way to clear it without deleting state in a directory that might have been
  # somebody else's.
  mkdir -p "$tmp/wt/strength-me/.agent" "$tmp/wt/strength-don/.agent"
  printf 'Don\n' > "$tmp/wt/strength-me/.agent/name"
  printf 'Don\n' > "$tmp/wt/strength-don/.agent/name"
  CLAUDE_CODE_SESSION_ID=don-session
  printf '2026-08-11T12:19:10Z\nsession don-session\n' > "$tmp/wt/strength-don/.agent/session.active"
  agent_name_taken_by "$tmp/wt/strength-me" Don >/dev/null \
    && t_fail "REGRESSION: my own abandoned worktree must not hold my name against me"

  # ⚠ NEGATIVE CONTROL — the same layout, one field changed, must still refuse. Without this the
  # test above passes against a guard that simply never refuses anybody.
  printf '2026-08-11T12:19:10Z\nsession somebody-else\n' > "$tmp/wt/strength-don/.agent/session.active"
  agent_name_taken_by "$tmp/wt/strength-me" Don >/dev/null \
    || t_fail "NEGATIVE CONTROL: a marker naming a DIFFERENT live session must still take the name"

  # ⚠ …and an OLD-FORMAT marker must still refuse, because it might be a live agent. This is the row
  # a staleness heuristic would get wrong in the expensive direction.
  printf '2026-08-11T12:19:10Z\n' > "$tmp/wt/strength-don/.agent/session.active"
  agent_name_taken_by "$tmp/wt/strength-me" Don >/dev/null \
    || t_fail "an id-less marker must still take the name — ambiguity is not permission"
  unset CLAUDE_CODE_SESSION_ID

  # 8. ── RUNG 0: IDENTITY COMES FROM THE SESSION (feat_agent_identity_is_session_scoped) ────────
  #
  # ⚠ THE LOAD-BEARING TEST, AND IT IS THE REAL 2026-08-13 FAILURE RECONSTRUCTED: a session carrying
  # one agent's GIT_AUTHOR_EMAIL, standing in a worktree whose .agent/name says somebody else.
  # Before this rung the directory won and the agent was silently renamed. That is how Vera
  # registered herself as Don by running one command from the shared checkout.
  ROSTER_FILE="$tmp/roster.json"
  cat > "$ROSTER_FILE" <<'JSON'
{"agents":[
  {"name":"Ed","email":"ed@weaversite.co.uk","role":"developer","status":"active"},
  {"name":"Don","email":"don@weaversite.co.uk","role":"product-owner","status":"active"}
]}
JSON
  mkdir -p "$tmp/donsdir/.agent"; printf 'Don\n' > "$tmp/donsdir/.agent/name"
  unset AGENT_NAME
  GIT_AUTHOR_EMAIL=ed@weaversite.co.uk
  [[ "$(agent_name_resolved "$tmp/donsdir")" == "Ed" ]] \
    || t_fail "THE HEADLINE: the SESSION must name the agent, not the directory it is standing in"
  [[ "$(agent_name_source "$tmp/donsdir")" == "session" ]] \
    || t_fail "the source must report 'session' so callers can warn on the legacy rung"

  # ⚠ NEGATIVE CONTROL. Without it, a rung 0 that returned a constant would pass the case above and
  # every agent on the box would resolve to the same name.
  GIT_AUTHOR_EMAIL=don@weaversite.co.uk
  [[ "$(agent_name_resolved "$tmp/donsdir")" == "Don" ]] \
    || t_fail "NEGATIVE CONTROL: a different address must resolve to a different name"
  [[ "$(agent_name_resolved "$tmp/noname")" == "Don" ]] \
    || t_fail "…and the directory is irrelevant to the answer, which is the whole point"

  # ⚠ AN UNROSTERED ADDRESS MUST NOT NAME YOU. Deriving a name from the local-part would invent an
  # identity that is in no register, cannot be routed to, and would still stamp a claim.
  GIT_AUTHOR_EMAIL=stranger@weaversite.co.uk
  [[ "$(agent_name_resolved "$tmp/donsdir")" == "Don" ]] \
    || t_fail "an unrostered address must FALL THROUGH to the directory, not invent 'stranger'"
  [[ "$(agent_name_source "$tmp/donsdir")" == "file" ]] \
    || t_fail "…and must report the rung that actually answered"
  GIT_AUTHOR_EMAIL=stranger@weaversite.co.uk
  agent_name_resolved "$tmp/noname" >/dev/null \
    && t_fail "an unrostered address with no other rung must REFUSE, not invent a name"

  # A malformed or empty address is not an identity either.
  GIT_AUTHOR_EMAIL=""
  [[ "$(agent_name_resolved "$tmp/donsdir")" == "Don" ]] || t_fail "an empty address falls through"
  unset GIT_AUTHOR_EMAIL
  [[ "$(agent_name_resolved "$tmp/donsdir")" == "Don" ]] || t_fail "an unset address falls through"

  # ⚠ THE PEER-DIRECTORY RULE SURVIVES RUNG 0. agent_name_of answers "who owns THAT worktree" and
  # must never consult the environment — least of all now, when the environment is authoritative for
  # the OTHER question. Borrowing it here would label every peer's stack with the reader's name.
  GIT_AUTHOR_EMAIL=ed@weaversite.co.uk
  [[ "$(agent_name_of "$tmp/donsdir")" == "Don" ]] \
    || t_fail "agent_name_of must still read the FILE — the session names ME, never THAT directory"
  [[ "$(agent_name_of "$tmp/noname")" == "" ]] \
    || t_fail "agent_name_of must not fall back to the session identity"
  unset GIT_AUTHOR_EMAIL ROSTER_FILE

  # ── rung 0 OFFERED BUT NOT TAKEN ──────────────────────────────────────────────────────────────
  # ⚠ The three ways rung 0 returns empty are NOT the same event, and collapsing them is what let a
  # directory label answer for five sessions over six days. Measured 2026-08-14: every session's
  # process cwd was the shared checkout, which was 31 commits behind main and carried no
  # agents/roster.json — so rung 0 could not answer EVEN WITH THE VARIABLE SET CORRECTLY.
  # (feat_agent_onboarding_and_offboarding)
  mkdir -p "$tmp/noroster" "$tmp/hasroster/agents"
  printf '{"agents":[{"name":"Wren","email":"wren@weaversite.co.uk","status":"active"}]}\n' \
    > "$tmp/hasroster/agents/roster.json"

  unset GIT_AUTHOR_EMAIL
  [[ -z "$(REPO_ROOT="$tmp/hasroster" agent_name_identity_warning "$tmp/hasroster")" ]] \
    || t_fail "an UNSET GIT_AUTHOR_EMAIL is not a warning — nothing was offered"

  # (b) offered, but the tree has no roster to resolve it against. THE LIVE CASE.
  _w="$(GIT_AUTHOR_EMAIL=wren@weaversite.co.uk REPO_ROOT="$tmp/noroster" \
        agent_name_identity_warning "$tmp/noroster")"
  [[ -n "$_w" ]] || t_fail "a set address with NO roster must warn — this is how five sessions shared one name"
  [[ "$_w" == *"no roster is readable"* ]] || t_fail "the no-roster warning must say so, not blame the address"

  # (c) offered, roster present, address not in it — a different problem with a different fix.
  _u="$(GIT_AUTHOR_EMAIL=nobody@example.com REPO_ROOT="$tmp/hasroster" \
        agent_name_identity_warning "$tmp/hasroster")"
  [[ -n "$_u" ]] || t_fail "an UNROSTERED address must warn — it is a typo in the launch line"
  [[ "$_u" != "$_w" ]] || t_fail "b and c must not share a message; they send you to different fixes"

  # (d) offered and resolved — silent, or the warning becomes noise and gets ignored.
  [[ -z "$(GIT_AUTHOR_EMAIL=wren@weaversite.co.uk REPO_ROOT="$tmp/hasroster" \
           agent_name_identity_warning "$tmp/hasroster")" ]] \
    || t_fail "a correctly resolved identity must be SILENT"
  unset GIT_AUTHOR_EMAIL

  printf 'agent-name selftest ok\n'
  exit 0
fi
