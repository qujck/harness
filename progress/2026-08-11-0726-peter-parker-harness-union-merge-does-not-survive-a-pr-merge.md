# harness: union-merge does not survive a PR merge

**Agent:** don · **UTC:** 2026-08-11 07:26

## What happened

Brought the harness's concurrency strategy in line with what the source project measured.

The harness prescribed `merge=union` in `.gitattributes` for `feature_list.archive.jsonl`,
`PROGRESS.md` and `DECISIONS.md`, and its own comment said the archive "unions cleanly".

⚠ **GitHub's PR merge IGNORES `.gitattributes` merge drivers.** A local `git merge` honours them,
so the pattern tests clean on one machine and fails on the workflow this harness prescribes
(branch + PR). In the source project it produced two full PR re-rolls in one day (2026-07-14).

⚠ **The failure mode is why this mattered enough to change rather than note.** It does not fail
early or loudly — it works perfectly for whoever tests it, and only breaks once a SECOND agent
exists, which is exactly when the harness is doing the job it was adopted for.

Replaced the driver with structure, so there is nothing to merge:

| artifact | was | is |
|---|---|---|
| completed tickets | `feature_list.archive.jsonl` appended | `features/archive/<id>.json` |
| session records | `PROGRESS.md` appended | `progress/<stamp>-<name>-<slug>.md` |

- `scripts/archive-passing.sh` writes per-ticket archive files; the legacy jsonl is left untouched
  as read-only history.
- `scripts/progress.sh` is new — one entry per session, name in the filename so two agents finishing
  in the same MINUTE still get different paths, and never clobbers.
- `scripts/handoff.sh` step 3 gates on a `progress/` entry instead of on `PROGRESS.md`.
- `.gitattributes` now sets no driver at all and says why; that absence is the decision.
- README, AGENTS.md and a DECISIONS.md entry updated so the harness stops teaching the old shape.

Driven, not assumed: archive tested end-to-end with a throwaway ticket (live file removed, archive
file written, jsonl untouched); `progress.sh new` run for real; handoff step 3 driven in BOTH
directions — passes with an entry, FAILS with the directory removed.

## What is left / next

The harness is still five weeks behind the source project on things that were not in scope here:

- **No claim lifecycle.** It advertises parallel agents but has no `feature-ticket.sh` — no
  claim/park/release, no branch-as-lock. Two agents adopting it can take the same ticket.
- **No agent identity.** No `.agent/name`, so nothing stamps ownership.
- **DoD is local `verify.sh`.** The source project moved to "the required CI check on an
  up-to-date PR" on 2026-08-04. Whether that transfers depends on the adopter's CI.
- **None of the measurement discipline** — "could this instrument have produced the other answer",
  window-vs-period, prove a gate against the real pre-fix artifact, a probe that cannot go positive.
  That is the highest-value transferable content and it is entirely absent.

## Anything the next session must not re-derive

**Do not "fix" a concurrent-write conflict with a merge driver.** It is the first thing that looks
right and it does not work through a PR. Give each writer its own file.
