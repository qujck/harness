# harness full update: claims, identity, METHOD

**Agent:** don · **UTC:** 2026-08-11 07:38

## What happened

Closed the four gaps this repo's previous PR had listed as out of scope, so the harness is no
longer five weeks behind the project it was extracted from.

**1. Claims — `scripts/feature-ticket.sh`.** The harness advertised parallel agents and shipped no
way to take a ticket. ⚠ **A ticket status is not a lock**: two agents can both read `not_started`,
both write `in_progress`, and both start. Checking for a branch first is not a lock either — both
look, both see nothing, both proceed. One operation here is atomic across machines:
`git push origin <id>`, which the remote rejects for the second pusher. So the claim IS the push.
Branch is based on `origin/main`, never HEAD, so a claim cannot absorb another agent's commits.
Verbs: `claim`, `claims`, `park`, `release`, `exists`.

**2. Identity — `scripts/lib/agent-name.sh`.** An ownership record that says "agent" is worthless,
and ownership is the one field the ledger cannot self-correct — a wrong status is fixed by the next
verify, a wrong owner just persists. ⚠ `.agent/name` names a DIRECTORY, not a session, which is the
concrete reason to work in your own worktree.

**3. `METHOD.md`.** The scripts make the workflow hard to get wrong; METHOD is about the
measurement. **A broken test fails; a broken measurement passes and you act on it.** Every rule is
drawn from a real incident. The two that catch most: *could this instrument have produced the other
answer* and *is this count a window or a period*.

**4. Lifecycle + the sibling the first PR missed.** `selected` added as the ready frontier.
`features/README.md:14` still taught `merge=union` — a copy the union-merge PR did not sweep, found
only by grepping the whole repo for the pattern afterwards.

## What is left / next

- **DoD is still a local `verify.sh`.** The source project moved to "the required CI check on an
  up-to-date PR". Whether that transfers depends on the adopter's CI, so it is not ported.
- **No takeover verb, no batch claims, no issue integration** — conveniences, deliberately omitted.
  What is here is the part that makes concurrency safe.
- **`DECISIONS.md` is still one append-only file** and still exposed to the conflict its own
  `.gitattributes` note describes. Trade accepted and stated.

## Anything the next session must not re-derive

**Two of METHOD's own rules were broken while writing it, and both were caught by looking at the
OUTPUT rather than the diff:**

- The refusal message in `feature-ticket.sh` used backticks inside a double-quoted string —
  command substitution — so printing the error EXECUTED `release` and mangled the message. Found by
  driving the refusal path, which is the path least likely to be exercised and most likely to be
  read when something has already gone wrong.
- A regex edit to `features/README.md` matched across a sentence boundary and corrupted the very
  paragraph it was fixing.

**Also: `$?` after a pipe is the LAST command's status.** `cmd | head; echo $?` reported 0 for a
command that exited 1, twice in this session. Capture with `out="$(cmd)"; rc=$?`.
