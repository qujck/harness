# Jira as the ticket store

*(feat_harness_jira_is_a_ticket_store_behind_the_same_verbs — owner, 2026-10-01: "for process it should
support jira for tickets".)*

## The short version — what Jira replaces, and where the seam is

The harness keeps **one verb set** for tickets — `raise`, `raise-epic`, `groom`, `claim`, `park`,
`unpark`, `amend`, `flip-passing`, `archive`, `wont-do`, `release`, `stand-down`, `intent`,
`ticket-row`, `ticket-owner`, `show`, `frontier`, `board`, `comments`, `answer`, `ping` — reached
through `scripts/ledger-db.sh`. **The seam is `scripts/lib/ticket-store.sh`**: `TICKET_STORE=db|jira`
in `harness.env` picks which store answers, every store prints the same verdict strings
(`ok` / `ok:<key>` / `exists:<key>` / `refused:<why>` / `unknown-parent:<key>` …) with the same exit
codes, and a verb a store lacks exits 2 loudly — never a silent pass.

With `TICKET_STORE=jira`, Jira is used **in place of**:

| harness piece | database store (`db`) | Jira store (`jira`) |
|---|---|---|
| the row a ticket lives in | `ledger.ticket` (Postgres, one per box) | a Jira issue in `JIRA_PROJECT_KEY` |
| the ticket id (and the branch name, and the lock) | the raise JSON's `id` slug | the issue **key** (`HAR-123`); the slug becomes a label |
| epic + children | `ledger.raise_epic` + `parent` | an Epic issue + `parent` on each child |
| the lifecycle (`not_started → selected → in_progress → passing → archived`, `parked`, `wont_do`) | a status column | the project workflow, through `JIRA_STATUS_MAP` |
| who holds it (`claim`) | `claimed_by` | the **assignee** (the session's account, by roster email) — **plus the pushed lock branch, which stays the atomic lock** (`feature-ticket.sh`) |
| requirement text (`notes`, `verification`, `verification_command`, `depends_on`) | columns, changed only by `amend` | description **sections** (ADF headings), rewritten only by `amend`, every change a comment naming who and why |
| the issue link (`record-issue`) | `ledger.record_issue` | nothing to record: the key *is* the issue |
| comments / answers | `ledger.comment` | Jira comments |
| session entries, agent-role sync, the PO queue views | ledger rows and views | **not provided** (exit 2, naming it): keep the database for those, or extend the adapter |

Everything above the seam — `feature-ticket.sh` (the lock branch), `init.sh` (the frontier),
`handoff.sh` (live claims), the completion rule (three row writes after the merge), the role
documents — is unchanged. To extend the Jira side elsewhere, extend `scripts/lib/ticket_store_jira.py`
(one method per verb) and the fixture in `fixtures/jira/`; the self-test in
`scripts/lib/ticket-store-jira.sh --self-test` drives the whole lifecycle.

## Assumptions (the owner corrects any)

- **Jira Cloud**, REST API **v3** (descriptions and comments are Atlassian Document Format; the
  adapter builds and parses the small subset it uses: paragraphs, headings, bullet lists, code blocks).
- Auth: **email + API token**, from `harness.env`: `JIRA_BASE_URL`, `JIRA_PROJECT_KEY`, `JIRA_EMAIL`,
  `JIRA_API_TOKEN`. The token is **never in git** — `harness.env` is gitignored and
  `scripts/check-no-committed-jira-token.sh` (run by `verify.sh`) refuses a tracked file carrying one.
- **One Jira project per harness project.**
- The session identity's Jira account is found by the roster **email** (`/rest/api/3/user/search`);
  no account for that email → `claim` is refused by name.

## The mapping, exactly

| harness | Jira | notes |
|---|---|---|
| `id` | issue key | `raise` prints `ok:<key>`; a raise whose slug already exists → `exists:<key>` |
| `title` | summary | |
| `status` | status, via `JIRA_STATUS_MAP` | default `not_started=To Do, selected=Ready, in_progress=In Progress, parked=Blocked, passing=Done pending, archived=Done, wont_do=Won't Do`. The map is **data**; before any write the adapter reads the project's real statuses and **refuses a map naming one the workflow lacks, by name** |
| `priority` 1–5 | Highest · High · Medium · Low · Lowest | |
| `area` | label `area:<area>` (`JIRA_AREA_FIELD=label`, default) or a component (`=component`) | |
| `notes` / `verification` (list) / `verification_command` / `depends_on` (list) / `user_visible_behavior` | description sections under headings of those names; the command as a code block | round-tripped verbatim by `show` |
| `parent` | `parent` | `unknown-parent:<key>` when it does not exist |
| `claim` | assignee ← session account; transition to `in_progress` | `already-yours` is a success; another assignee → `refused:claimed-by:<name>`; not `selected` → `refused:not-selected:<status>` |
| `park --kind k --summary s --condition c <id> <why>` | transition to `parked` + a comment carrying why / ASK / UNPARK WHEN | |
| `amend <id> <field> <value> <why>` | that one section rewritten (lists as JSON or newline-separated) + a comment with BEFORE/AFTER | no why → refused |
| `flip-passing <id> <pr>` | transition to `passing` + comment `passing: PR #N` | no PR number → refused |
| `archive <id> <why>` | transition to `archived` (only from `passing`) | |
| `release <id>` | nothing in Jira (the lock is the branch) — `release:archived:archived` / `ok` for `wont_do` / `refused:not-finished:<status>` otherwise | |
| `frontier` | JQL: status = selected, assignee empty → `id|area|priority` | same shape as the db store |
| `board` | JQL: status = in_progress → `id|area|claimed_by` | |

## Transport failures

`429` and `503` are retried with backoff (4 tries). A final failure is **CANNOT TELL (exit 2)** for a
read — never "no row" — and **`refused:jira-unavailable:…` (exit 1)** for a write: nothing was written.

## Fixtures and the live run

`JIRA_TRANSPORT=fixture` runs the adapter against an in-process fake of exactly the endpoints the verbs
use (`fixtures/jira/workflow.json` is the workflow it emulates). The self-test drives every verb
against it. **`bash scripts/lib/ticket-store-jira.sh --live --record`** runs the same lifecycle against
the real project named in `harness.env`, records every response under `fixtures/jira/recorded/` and
rewrites `workflow.json` from the project's real statuses, so the fake cannot drift from the API.
Record the issue key of that run in `DECISIONS.md`. *(Not yet run against a real project: the owner
has not named one.)*

## Out of scope

Jira Server / Data Center (v2 API, wiki markup), offline writes, custom fields beyond the above,
Jira-side automation.
