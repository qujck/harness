# features/ — the work queue (one file per ticket)

The live work queue is this directory: **one `features/<id>.json` per ticket**,
each holding that ticket's entry object alone. Adding, flipping, or archiving a
ticket touches only its own file, so concurrent branches never conflict on the
queue (a single shared JSON array couldn't merge). Completed tickets are moved to
the append-only `feature_list.archive.jsonl` (one compact entry per line,
`merge=union`) by `scripts/archive-passing.sh`.

`scripts/_features.sh` aggregates `features/*.json` back into the legacy
`{"features":[...]}` shape, so `init.sh` (next ticket) and `handoff.sh` (WIP /
ready-frontier) read it uniformly. This `README.md` is ignored by the aggregator
(it only reads `*.json`).

## Entry schema

```jsonc
{
  "id": "kebab_case_id",          // matches the filename: features/<id>.json
  "priority": 0,                   // lower = sooner
  "area": "backend",              // surface hint; prefer different areas across agents
  "title": "Short imperative title",
  "user_visible_behavior": "What the user can now do.",
  "status": "not_started",        // not_started | in_progress | blocked | passing | wont_do
  "depends_on": [],                // ids that must be "passing" before this is on the ready frontier
  "verification": "How another agent confirms this works.",
  "verification_command": "bash scripts/verify.sh",
  "evidence": null,                // commit hash / output proving it passed
  "last_verified_commit": null,    // set when status -> passing
  "notes": "Decision context; for wont_do, record why."
  // "solo": true                  // OPTIONAL: must run alone (whole-codebase / shared core / multi-migration)
}
```

## Rules

- Add a ticket with `status: "not_started"` **before** writing code; flip to
  `"in_progress"` when you start.
- A ticket becomes `"passing"` ONLY after `scripts/verify.sh` exits 0; record the
  commit hash in `last_verified_commit`. Don't self-grade.
- `wont_do` is terminal — kept (then archived) for history so the idea isn't
  re-queued under a new name. `notes` must say why.
- Multiple `in_progress` is fine across **isolated** checkouts (own worktree or
  clone). Worktree isolation + `depends_on` are the safety, not a WIP count.
- After a ticket reaches `passing`, run `bash scripts/archive-passing.sh` to move
  it to `feature_list.archive.jsonl`.
