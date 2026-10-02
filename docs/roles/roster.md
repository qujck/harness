# Roster — which name holds which role

The register is `agents/roster.json`, written by `bash scripts/agent-onboard.sh <Name> <role>`
(which also prints the launch line that gives the session its identity). One row per agent that has ever
worked in the repo: `name`, `role`, `email`, `status` (`active` | `retired`), `onboarded`,
`offboarded`, `evidence`. Four roles exist in every project that uses this harness, whatever the
team size — a solo project holds all four in one head and still benefits from knowing which hat
is on:

| role | document | owns |
|---|---|---|
| `product-owner` | [product-owner.md](product-owner.md) | the ledger, the pipeline's routing, who works on what |
| `developer` | [developer.md](developer.md) | the code and everything they start, to a terminal state |
| `head-of-testing` | [head-of-testing.md](head-of-testing.md) | what is TRUE about the system under load, and pre-prod; fixes nothing it finds |
| `process-improvement` | [process-improvement.md](process-improvement.md) | the path to `main`, recovery from a red `main`, the gates and the scheduled jobs |

## What a name IS comes from the session, not from a directory

An agent's identity is set when its session launches: the `GIT_AUTHOR_*` / `GIT_COMMITTER_*` line
that `bash scripts/agent-onboard.sh --launch-line <Name>` prints from the roster. That is what
stamps commits, claims and session entries with *you*. A `.agent/name` file says who a **directory**
belongs to; it cannot say who a **session** is, and a project that read it as identity once had five
live sessions resolve to one name. Resolution order is the session first, the directory never for a
write: `agent_name_resolved` must print your name and `agent_name_source` must print `session`
before anything writes.

## `evidence` is the field that makes the register honest

Every row says *how we know* its role: `declared — <who>, <date>: "<words>"`, or
`inferred — <what was read>`. A role nobody declared is a guess, and the router should know it is
routing on a guess. Count the inferred rows with the register, never in prose here.

## Retired names are never reused

A retired row stays for ever. Old commits carry the address, so re-onboarding a name would hand one
person's history to another. `roster_add` refuses a known name whatever its status, and anything
asking *"is this name free?"* counts retired rows as taken — filtering to `active` first gets that
exactly backwards. **Do not route to a retired name, and do not read a claim stamped with one as a
live owner.** A retired holder's open claims need a per-ticket decision, never a bulk release.

## Assistants and machines are recorded, not rostered

A session with a human name that a person talks to but that holds no role, takes no claims and
writes no code (a house assistant) is recorded in a separate array so its absence from the team
stops reading as an oversight — and **nothing enumerates that array for work**. The same for
machine identities (timers, runners): recorded for address-to-name lookup only. The moment a reader
assigns work from either array it has become a second rota, and that is an owner question.
An assistant's terms of reference are [personal-assistant.md](personal-assistant.md) — a template:
the holder is not a team member, and that document says what it does instead.

## Adding or changing an entry

`bash scripts/agent-onboard.sh add <Name> <role> <email>` with the evidence line; retire with
`retire <Name> "<why>"`. Never edit a row's `name` or `email`.
