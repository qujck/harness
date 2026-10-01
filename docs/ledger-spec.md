# The ledger

*Template note: this specification was carried over from the project the template was seeded from, together
with its schema as one baseline (`infra/ledger-db/001-baseline.sql`). Mentions of "migration N" and of ticket
FILES (`features/<id>.json`) are that project's history: the template starts on the database, with no file era.*

What a ticket is, what states it can be in, who may move it, and what you see.

This page is the definition. Where CLAUDE.md, AGENTS.md, a migration header or a script disagrees
with it, this page wins and the other is a bug. The problem, in one line: **the database declares
more statuses than anything uses, and uses more than anything writes down** — declared-minus-used is
dead vocabulary, used-minus-documented is why no two tools agree.

---

## 1. Five statuses

| status | means |
|---|---|
| `backlog` | captured, nobody has decided it should be done |
| `ready` | decided, groomed, and free for anyone to pick up |
| `in_progress` | somebody is holding it |
| `done` | it shipped |
| `wont_do` | decided against, with a reason |

There are no others. A ticket is in exactly one of these at any moment.

**`archived` is not a status.** It was one, and it destroyed information: an archived ticket's real
outcome — shipped or abandoned — was overwritten before storage, so that distinction now exists only
in files scheduled for deletion. Where a row *lives* is storage; whether it *shipped* is `done` vs
`wont_do`. **The two must never share a word.**

**`passing` is not a status either** — it named a fact about a pull request, not a ticket. **Zero
rows now**, and *now* is the honest word: the mirror keeps no history, so "never" is not checkable.

---

## 2. One field beside the status: `waiting_on`

A ticket somebody holds may still be unable to move. That is not a different status — it is the
same status with a reason attached.

| field | values | meaning |
|---|---|---|
| `waiting_on` | `owner` · `other` · `null` | who or what it is waiting for |
| `ask` | text, ≤400 chars | required when `waiting_on = owner`. What you must do. |
| `waiting_for` | list of ticket ids | required when waiting on another ticket |

**`waiting_on = owner` will not be settable without an `ask`** — enforced by the database, not by
convention. *Will*, not *does*: rows lack one today, and 400 is the existing limit, so a shorter cap
would truncate asks already written. The ask is for someone who does not work on this repo; the long
version stays in `notes`, which the queue does not show.

This replaces `parked`, `blocked`, `held` and `banked` — all four meant "in progress but stuck". Two
are not what they look like:

- **`parked` is a status today**, settled 2026-09-01 — not an ambiguity to resolve. Three prose
  copies still call it a marker on `in_progress` and have their own ticket.
- **`held` was never a status at all** — a derived boolean, today *claimed and not in progress*,
  which is why finished-but-unreleased tickets show up as held. ⚠ **That derivation is itself the bug
  and must exclude terminal statuses: *claimed, not in progress, and neither `done` nor `wont_do`*** —
  carried across unchanged it reproduces on day one the defect it is given as the reason for.
  (Saffron.)

---

## 3. Who may move it

| from → to | who | must carry |
|---|---|---|
| — → `backlog` | any session | a title |
| `backlog` → `ready` | PO | — |
| `ready` → `in_progress` | any session (becomes the holder) | its name |
| `in_progress` → `in_progress` + `waiting_on` | the holder † | an `ask` if `owner` |
| `in_progress` → `done` | the holder † | a PR number |
| `in_progress` → `ready` | the holder † | a reason (hand-back) |
| any → `wont_do` | PO or owner | a reason |
| any → any | owner | — |

† **or the PO, when the named holder is `retired`.** Not otherwise — see (b) below.

Two fixes sit in that table and must be judged separately — the first is cheap, the second grants
power. **Both are needed and neither subsumes the other**: of the parked tickets no live person can
maintain today, most are reachable only by (b), at least one only by (a).

**(a) One identity field decides.** Three verbs gate on two fields today (`park`/`unpark` on
`claimed_by`, `reclassify_park` on `parked_by`), so an agent can be refused permission to update **a
park she wrote herself**. One field asking the wrong question; fixing it grants nobody anything.
⚠ Migration 55 justifies its choice on the grounds that *`claimed_by` is null for a parked row* —
**false for every parked row since migrations 48/49 made `parked` a status.**

**(b) The PO may act when the named holder is `retired`** — scoped to `status: retired`, no wider;
widening it is the owner's call. A `critical` ticket sat unreachable for three days because its
claimant had retired, and **no field choice recovers from that: there is no live person to gate on.**
⚠ Provenance: the motivating incidents were reported by the PO, who is its beneficiary.

⚠ **Say `retired`, not "off the roster".** Retired agents are still *on* the roster carrying
`status: retired`, so "off the roster" has no field to read and `status` does. **A rule whose
condition cannot be evaluated is not a rule.**

⚠⚠ **AND IT HAS A HOLE — THE OWNER'S TO CLOSE.** An agent can be **removed from the roster
entirely** rather than retired, and `status: retired` cannot evaluate for someone with no row. One
live ticket is held that way today and nothing can release it. **The evaluable predicate is *the
holder is not named by any roster entry whose `status` is `active`*.** ⚠ Wider than the owner
granted, so **not in force**. Do not pick a `claimed_by` for such a row meanwhile: an unrostered name
fails `check-roster-coverage`, `null` erases a live claim, and the absent key is correct.

**The holder is who is *doing* it, never who is *allowed* to.** Every move is by a **named person**;
the owner's writes are under his name. `ledger_console` is a connection, not an author.

---

## 4. What the owner sees

Two lists. Nothing else is required on either.

**The owner queue** — everything with `waiting_on = owner`:
> title · who is waiting · **the ask** · how long · a box to reply in

**The work list** — everything else live:
> title · who holds it · status · waiting on · last activity

Last activity is the last real event: a commit, a PR, a check, a merge, a status change. Today the
board shows no GitHub activity at all, so a ticket finished a day ago and one abandoned a week ago
look identical. **A row that cannot show its last activity is not finished.**

---

## 5. The event log

Every transition is an event: **what moved, who moved it, when, and why.** The mirror's snapshot
writes are not events — a snapshot says what a row looks like now, an event says what happened, and
only the second answers "why is this still open" or "who changed this".

**A count with no recency is not an answer** — a dead field reports the same confident total as a
live one. **Anything showing a total shows when it last moved, beside it.** (Cara.)

The reason this section exists: **a fact produced correctly, delivered to someone with no stake in
it, and never stored, is a fact the system does not have.**

---

## 6. When the stores disagree

Until the files are deleted, the same ticket exists in a database row and a file, and they can
differ.

- **The database is the source of truth**; files are derived output.

- ⚠⚠ **A PARK'S TEXT HAS ONE HOME: THE DATABASE. No verb reads the lock ref back. While the files
  still exist they are written FROM the row, never the reverse.** (Owner, 2026-09-02 — decided, not
  open.)

  ⚠ **The damage is latent in the REFS**: repairing a file leaves the frozen lock ref unchanged, so
  the next re-park truncates again. **A repair pass run before this rule lands must repair the refs.**
  ⚠ **And one home means no rebuild path** — `park_summary` is a column git has never held, so a
  restore-from-files destroys those asks silently. Backup is the only recovery.

- ⚠⚠ **A PARK IS A FIELD *SET*, AND ANY NUMBER REPORTED OVER PARKS SAYS WHICH FIELDS IT READ.** The
  set is **`parked`, `park_summary`, `parked_by`, `parked_at`, `park_kind`**, cleared through
  **`unparked_by`, `unparked_reason`, `unpark_check`**. Pin one and the other seven go unwatched —
  three independent censuses all read `parked` alone, **so their agreement was never corroboration.**

- ⚠⚠ **NOT YET — the exception destroys data.** One fact lives *only* in the files: whether an
  archived ticket **shipped** or was **abandoned**. **Until it is read out of them, the files are not
  derived output and deleting them is irreversible** (§8; `CUTOVER.md` step 7). It sits beside the
  authority claim because a reader who takes "derived output" at face value concludes they are safe
  to delete.

- ⚠⚠ **OWNERSHIP IS NOT DERIVED OUTPUT, AND THE ROW IS THE LEAST AUTHORITATIVE STORE FOR IT.** The
  database says so of itself — *"Git is authoritative during the migration; this is an observer"* —
  and CLAUDE.md ranks the stores: the GitHub **issue** first, the lock **ref** second,
  `features/<id>.json` on the claim ref third, on `main` fourth, the **row last**. **So a file writer
  MUST NOT write `claimed_by` from the row**, and a disagreement there is recorded as drift like any
  other. ⚠ **This is not a hedge about migration timing — it does not lapse when the files are
  deleted**, because the issue remains authoritative for ownership afterwards. ⚠ **It sits beside the
  authority claim for the same reason the bullet above does: a reader who takes "derived output" at
  face value builds a writer that promotes an observer's stale value into the one field nothing
  downstream can detect as wrong.** (Live instance:
  `infra_preprod_destructive_ops_need_the_owners_token`, row `Cara` against issue and main `Vera`,
  stale on the lock ref since 2026-08-12 and promoted by an ordinary mirror on 2026-09-06.)

  ⚠ **AND THE INSTANCE WAS SETTLED WITHOUT CONSULTING ANY OTHER STORE, WHICH IS THE REUSABLE PART.**
  The lock ref contradicted *itself*: one file, `claimed_by: Cara` and `parked_by: Vera`. **A ticket
  cannot be parked by someone who does not hold it**, so the wrong half is identifiable from that
  file alone. Three stores agreeing against a fourth could be one blind spot counted three times;
  **a self-contradiction cannot be.** Prefer an internal inconsistency to a majority vote when both
  are available — and this holds whoever notices it, which is why it is stated as a rule rather
  than credited to the reader who happened to spot it.

- A disagreement is **recorded as drift, never silently resolved** — the other side's value is kept,
  with the time it was seen. **Losing a fact is not drift, it is an incident**: drift is two answers,
  LOST is none, and **a file with no row is not LOST** but usually sync backlog. Never count the two
  together.

**"Can the database reproduce the files" stops being the bar**, so a near-total `differs` count is
not a regression. ⚠ **But it is not formatting: the check compares VALUES key by key, not bytes**,
despite its verdict literal being named `byte-equal`. It stops being a release gate; it does not stop
being a signal. (Ed.)

---

## 7. How work is raised

A session raises a ticket directly — a full ticket, or an epic with children. No approval step, no
second tool.

---

## 7a. The PR↔issue trailer: read the number, do not recall it

A PR that finishes a ticket says `Closes #N`; one that delivers part of it says `Part of #N`. Both
name the ticket's **tracking issue**, and the number comes from the ticket **row** — `ledger-db.sh
regenerate --out <dir> <id>`, then read `.issue`.

⚠ **WRITE THE TRAILER FROM THE ROW, BEFORE THE MESSAGE — NOT AT THE END, FROM MEMORY.** This is a
rule about *ordering*, not about care, and the reason is that the trailer is the last line written,
at the moment the work feels finished and the number feels remembered. Every instance below was
produced by somebody who knew the rule.

⚠⚠ **NOTHING READS A `Part of` TRAILER.** `check-closing-keyword-archives.sh` looks for *closing*
verbs — by design, since `Part of` exists precisely to avoid closing the issue. So a wrong `Part of`
merges silently and **permanently**: the cross-reference is made at merge, and editing the body
afterwards does not unmake it.

⚠ **AND THE WRONG NUMBER USUALLY EXISTS AND BELONGS TO SOMEBODY ELSE.** A non-existent id announces
itself; a real one does not. Two shapes to know:

* **A stranger's live ticket.** Nothing about the reference looks odd.
* **The adjacent sibling from your own batch.** `claim <a> <b>` mints **consecutive** issue numbers,
  so the neighbouring wrong number is the most plausible one you can write.

⚠ **After cutting `<id>-pt1` the number is NOT readable from your tree.** `claim` commits the issue
number to the **lock branch**, and `-pt1` is cut from `origin/main`, which has never seen that
commit. So "go and look it up" silently degrades into "recall it" unless you go to the row — the
general trap that *a rule saying "look it up" assumes the thing is lookable*.

### Why there is no gate for this, measured rather than assumed

Measured 2026-09-20 over the **200 most recent merged PRs**: **65** carry a `Part of #N`; **one** is
wrong (PR #9008, the cutover PR, pointing at an unrelated ticket). **~1.5%.**

⚠ **The rate is not what settled it — the achievable PRECISION is.** A naive comparison of the
trailer's issue against the PR title's ticket id flags **10**, and **nine are false**. A gate at
1-in-10 gets disabled within a week, and the surface is then unguarded **and believed guarded**,
which is worse than today.

Anyone revisiting this starts from the exclusion set rather than rediscovering it:

| excluded | why it is not a defect |
|---|---|
| `-pt\d+`, `-notes`, `-hotfix`, `-raise` branches | a suffix branch correctly names its **base** ticket's issue |
| PR titles with no ticket-id prefix | `chore:`, `progress:`, `cutover step 7:` are legitimate |
| lane names (`repair-main`) | a lane, not a ticket id |
| unlisted id prefixes | `perf_` is real and was missing from the first matcher |

**The remedy is the ordering rule above, not a check.**

---

## 8. Mapping from what exists now

Every status word in use anywhere in the repo today, and what it becomes:

| today | becomes | note |
|---|---|---|
| `not_started` | `backlog` | |
| `selected` | `ready` | |
| `in_progress` | `in_progress` | |
| `passing` | `done` | zero rows now; the word came from the test gate |
| `archived` + file says `passing` | `done` | |
| `archived` + file says `wont_do` | `wont_do` | |
| `wont_do` | `wont_do` | |
| `blocked` | `in_progress` + `waiting_on=other` | |
| `parked` + `park_kind=blocked_on_owner` | `in_progress` + `waiting_on=owner` | **needs an `ask`** |
| `parked` + `park_kind=blocked_on_other` | `in_progress` + `waiting_on=other` | |
| `parked` + `park_kind=banked` | `in_progress` + `waiting_on=null` | |
| `draft` | `backlog` | zero rows now |
| `reviewed` | `ready` | zero rows now |
| `held` | *(not a status)* | derived — see §2 for the corrected derivation |

**The mapping is total**: every archived row matches a file, and files carry only those two values.
The abandoned rows are a few percent of the archive and are the ones that become indistinguishable,
so **counting the whole archive first is what hides them.**

**Stated so it can be refuted: for rows archived before migration 52, no database column separates
the abandoned from the shipped.** `import_drift` never kept the pre-coercion value, `verified_by_pr`
appears on both classes, `ticket_event` carries no outcome verb. **Name a fourth that works and this
hazard is void.** ⚠ Migration 52 records `from`/`to`, so rows archived *after* it are recoverable
from the event log — count that subset, do not assume it. (Ed.)

⚠⚠ **SO READ THE OUTCOME OUT OF THE FILES AND INTO THE DATABASE BEFORE THEY ARE DELETED. This is the
load-bearing line of the whole cutover; nothing deletes a file before it.** (Owner, 2026-09-02.) It
cannot be redone, and in the wrong order it merges the abandoned into the shipped silently — every
row still holding a status, every count still adding up.

⚠ Every `waiting_on=owner` row needs its `ask` written before the move. Asks cannot be generated: a
park reason is written for tools, an ask for a person.

⚠⚠ **EVERY NUMBER ON THIS PAGE IS ILLUSTRATIVE, INCLUDING ANY THAT LOOKS STRUCTURAL — count from the
corpus, quote nothing from here.**
