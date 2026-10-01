# AGENTS.md

Single entry point for any agent (or human) starting a session in this repo.
Routing file — short on purpose. The rules here are the harness; the project's own map and
commands live in a per-project `CLAUDE.md`.

> Replace the `{{PLACEHOLDERS}}` below, then delete this line.

---

## What is this project

{{ONE_PARAGRAPH: what it is, the stack, where it runs in production}}

Full project map and commands: [CLAUDE.md](CLAUDE.md) *(create this per-project; the harness
doesn't ship one).*

---

## Know which role you are in, and read its prompt — first, every session

Four roles exist in every project that uses this harness, whatever the team size:
[Product Owner / team lead](docs/roles/product-owner.md) · [Developer](docs/roles/developer.md) ·
[Head of Testing](docs/roles/head-of-testing.md) · [Process improvement](docs/roles/process-improvement.md).
Who holds which is the [roster](docs/roles/roster.md). Each document says what you own and — the
load-bearing half — what you must not touch. The rules below bind all four roles.

---

## Hard rules — non-negotiable

0. **Work in an isolated checkout when more than one agent may run at once.** On one machine:
   `git worktree add --no-track ../<project>-<you> -b <ticket-id> origin/main`, named after YOU.
   Two agents in one checkout corrupt each other, and the silent failure is a wrong name on the
   ownership record. `init.sh` refuses to start where another agent's live marker already is.
   *(The machine-wide stack cap and the context publisher arrive with
   `feat_harness_a_machine_wide_agent_stack_cap_and_each_agents_context_published_for_the_others`.)*
1. **Your identity is set when the session launches and cannot be set afterwards.** Launch with
   the line `bash scripts/agent-onboard.sh --launch-line <Name>` prints from `agents/roster.json`;
   check `agent_name_resolved / agent_name_source` prints your name and `session` before anything
   writes. `.agent/name` is a directory's label, never a session's identity. *(The roster and the
   onboarding script arrive with
   `feat_harness_identity_comes_from_the_session_via_a_roster_and_session_entries_are_ledger_rows`;
   until then export `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` yourself and the scripts read those.)*
2. **One ticket per change, and the ticket store is the ledger, behind one verb set.** A raise
   creates a row at `not_started` (`bash scripts/feature-ticket.sh raise <id>` with a hand-authored
   JSON you never commit); `selected` is the PO's move (`groom`); claim before you start
   (`feature-ticket.sh claim <id>` — the pushed branch is the atomic lock, the row holds the claim);
   requirement edits only through `ledger-db.sh amend <id> <field> <value> <why>`. The store is
   the database (`TICKET_STORE=db`, the default — one Postgres per box, brought up from
   `infra/ledger-db/`, defined in [docs/ledger-spec.md](docs/ledger-spec.md)) or Jira
   (`TICKET_STORE=jira`), same verbs; `scripts/lib/ticket-store.sh` is the adapter. A write needs a
   session identity: `GIT_AUTHOR_EMAIL` must map to a row in `agents/roster.json`, or the ledger
   refuses (exit 3). Jira: [docs/ticket-store-jira.md](docs/ticket-store-jira.md) — the same verbs
   over a Jira project (the issue key is the ticket id; the branch stays the lock).
3. **Don't self-grade.** The required check on your PR is the definition of done; `passing` is a row
   write after the merge, with the PR number, never a judgement.
4. **Completion is three row writes AFTER the merge**: `ledger-db.sh flip-passing <id> <pr>` →
   `ledger-db.sh set-status <id> archived "<why>"` → `feature-ticket.sh release <id>`. Nothing
   rides in the PR, so the PR says `Part of #N`, **never `Closes`** — a closing keyword shuts the
   issue over a live row.
5. **Before you trust any measurement, read [METHOD.md](METHOD.md).** Especially: could this
   instrument have produced the OTHER answer; is this count a window or a period; a negative
   result inherits every blind spot of the method that produced it.
6. **Write this session's entry before a block boundary, as a ledger row** — `bash
   scripts/progress.sh new "<title>" --body-file <file>` — never as a file, never as a commit (an
   entry committed after the PR opens supersedes its verify). `handoff.sh` refuses a session with
   no entry. *(Rows arrive with `feat_harness_identity_comes_from_the_session_via_a_roster_and_session_entries_are_ledger_rows`; a file under `progress/` until then.)*
7. **Append to `DECISIONS.md`** for any choice another agent might re-debate. A decision is
   binding until superseded — and **a decision recorded with a reason lapses when the reason
   does**: re-ask it, do not obey it.
8. **Every self-test is invoked by something, through one flag contract, or says why not.** A
   check that only ever runs its own arms is not a check. *(The contract, the tier manifest and
   the step-promise gate arrive with
   `feat_harness_self_tests_follow_one_flag_contract_and_a_tier_manifest_that_verify_runs`.)*
9. {{PROJECT-SPECIFIC RULE — e.g. module isolation, naming, layering. Delete if none.}}

> These rules implement *Learn Harness Engineering* (L02–L12): the ledger is a harness primitive
> (L08), agents can't self-grade (L09), e2e proves boundary defects a unit test cannot see (L10).

---

## Session entry — clock in

```bash
bash scripts/init.sh
```

Refuses a checkout holding another agent's live marker; brings the stack up; waits on the health
endpoint; installs the pre-commit hook; marks the session; prints your role prompt (all four) and
the ready frontier — `selected` rows whose dependencies are done and that nobody has claimed.

---

## Session exit — clock out

```bash
bash scripts/handoff.sh
```

Checks: clean tree (or commits made), a session entry this session, no debug artifacts, every
piece of work you started in a terminal state (merged or armed, parked with the reason on the row,
or handed back with `release --abandon`). A Stop hook runs the lenient form after every turn.

---

## How a PR reaches `main`

*(Arrives with `feat_harness_ci_routes_a_pr_by_diff_runs_a_test_subset_and_gates_merges_on_the_hourly_full_suite`;
until then a PR runs `scripts/verify.sh` as its required check.)* The shape it will have: a
**route** job reads the diff and picks a lane; **verify** runs the tiered gate on the merged tree
(a browser SUBSET selected by a path map for page diffs; the full suite hourly on `main`); a red
hourly **blocks the merge queue** through a gate that judges on the newest concluded run; the
sanctioned exit from a red `main` is the **repair lane**
([docs/runbooks/main-is-red.md](docs/runbooks/main-is-red.md)); after a change to the workflow,
old runs are **replaced, never rerun**. Merge by rebase; arm `--auto` and move on; nothing is held
for review; destructive ops need an explicit ask (`--force-with-lease` after a rebase and
`feature-ticket.sh release` are the standing exceptions).

---

## Adding a feature — checklist

1. `feature-ticket.sh exists <id>` (exit 1 = safe; exit 2 = CANNOT TELL, never raise on it), then
   `raise` with a hand-authored JSON: a real `verification_command` another agent could run,
   verification items that NAME what a test could read (a selector, an id, a path, a spec), and
   `depends_on` for real ordering. It arrives `not_started`; ask the PO to `groom` it.
2. `claim`, in your own checkout. Cut the work branch from `origin/main` as `<id>-pt1`.
3. Implement it, with unit tests for what you wrote. {{project-specific layering notes}}
4. Push freely while no PR exists (the first run is created by opening it); open the PR when the
   work is finished, titled `<id>: <summary> — <you>`, body `Part of #N`; arm auto-merge.
5. After the merge: the three row writes (rule 4). Then the session entry (rule 6) and `handoff.sh`.

---

## Configuration

All stack-specific commands live in `harness.env` (copied from `harness.env.example`): build, test,
e2e, health, the ticket store (`TICKET_STORE=db|jira` and its settings), the merge-seat labels
and counts, the alert transport. The scripts are generic. First-time setup in Claude Code:
**`/configure`** — it detects the stack, confirms every value, fills `harness.env` and the
placeholders here, and writes a starter `CLAUDE.md`.
