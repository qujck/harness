# METHOD — how to know whether you actually found what you think you found

The harness makes the *workflow* hard to get wrong. This file is about the other half: the
**measurement**. Every rule below is here because it cost real time in the project this was
extracted from, and every one of them produced a **confident wrong answer rather than an error**.

That is the whole theme. A broken test fails. A broken *measurement* passes, and you act on it.

---

## The two questions that catch most of it

### 1. Could this instrument have produced the other answer?

If your check cannot go **positive**, a negative result means nothing.

- A probe written to reproduce a reported bug returned "not reproduced" — because it had been built
  to the shape the reader *assumed*, which was not the shape that failed. "The report is wrong" and
  "my probe is wrong" look identical from the outside.
- An audit grepped for `FAIL:` in a log that said `FAIL` (no colon, inside ANSI escapes) and
  reported zero — of a run that had failed twice. A control grep proved the *log* was greppable; it
  did not prove the *needle* was right, because it used a different needle.

**Before trusting a miss, make the search hit something you know is there.** A control must exercise
the same predicate, differing only in that its target is known present.

### 2. Is this count a WINDOW or a PERIOD?

`--limit N` answers "the last N". It never answers "that day".

A finding that "twelve PRs merged, largest six files, no large PR merged at all" turned out to be a
three-and-a-half-hour window reported as a day. The real day merged **70**, largest **75 files** —
and the single PR the finding rested on was itself the largest merge of that day.

⚠ **The defect was in the recorded procedure**, which said `--limit 12`. So everyone who followed
the instructions faithfully reproduced the artifact and then agreed with each other. **Agreement
between people running the same broken procedure is not corroboration** — and writing the procedure
down spread the error further than an unwritten habit would have.

**Corroborate by a DIFFERENT ROUTE.** Re-running the same query proves nothing.

---

## Rules for building a check

**Prove a new gate against the real pre-fix artifact.** Green proves nothing. Reconstruct the state
that produced the bug and watch the gate fail; then fix it and watch it pass. A gate never observed
to fire is an assumption.

**Mutation-test it, with a positive control first.** Break the thing on purpose and confirm the
check notices. ⚠ Run the *unmutated* suite first and confirm it passes — one harness reported six
false MISSes because the mutant resolved its repo root to a scratch directory, died before running
anything, and **exited 0**.

**A harness that mutates real files must restore on a SIGNAL, not just an exception.** `finally`
does not run when the process is killed. One did not, and left a library mutated in the working
tree where a later commit could have taken it.

**Fail toward the ACTION, never toward the silence.** A check that fails toward "and therefore do
nothing about it" is self-sealing and nothing downstream can notice.

- A readiness probe answered "ready" for a port held by an unrelated service — and the caller
  *skipped the repair step* on that answer, so the false reading prevented the very fix it needed.
- A pager was wired behind `if [[ -f … ]]` with no `else`. The file was missing, so it silently did
  nothing, and two failing PRs sat for seven hours.

**Do not put a CLI on a sourced library.** A sourced file that reads `$1` reads its *caller's* argv.
One answered its caller's own `--self-test` and exited 0 — silently replacing a real gate with one
that always passes.

**A test that is disabled by the system becoming healthy protects nothing.** One assertion ran only
when a permission was missing, and printed `skip` otherwise — so installing the permission switched
off the test for the only case it was about. Drive both branches.

---

**A negative result inherits every blind spot of the method that produced it.** "I looked and found
none" and "I looked with a tool that cannot see this" are the same sentence, and only the first
reads as safety. One board sweep reported "nothing red" from check conclusions, which cannot see a
CONFLICTING PR at all; one "zero others" came from a count keyed on SHA that reads non-zero for work
already landed under a rebase. **State the denominator and the method beside the zero, always**, and
where a population is structurally unreadable say *unmeasurable*, never *clean*. "Unknown" invites a
detector; "zero" closes the question. *(From a project where four such zeros landed in one shift.)*

**Rank a population by what protects each member — not by what it is called, and not by how many
there are.** Both intuitive orderings put the SAFE majority first. 127 branches tracked `main`
(protected, loudly rejected) against 11 tracking a live ticket ref (unguarded, silently
overwritten); 27 queued jobs of which ONE could clear a red. Ask "what happens to THIS member if it
goes wrong?", member by member, before any total. *(Three instances in one week, each corrected
four people at once.)*

**A decision recorded with a reason lapses when the reason does, and nothing re-asks.** A merge
method armed because the branch carried a merge commit stayed armed after the commit was rebased
away; a gate's exemption stayed in force after the claim that justified it expired; a seat probe
alerted on "two runners share a label" after the second seat became the decision. None is caught by
a check that asserts the decision; all need something that re-checks the REASON. **A control that
asserts its own justification beats one that asserts its own existence.** When you find a rule
whose reason has lapsed, re-ask it — do not obey it.

**A check that only runs its own self-test is not a check.** A verify step named "No new
session-entry files" ran the gate's `--self-test` and nothing else for a while; the inventory asked
"is the self-test run?" and it was. Ask "is the CHECK invoked, against the thing it judges?" — and
read a verification list against the test's assertions item by item: a row can meet a smaller
requirement than it records, and a passing flip cannot see the gap.

---

## Rules for fixing

**Find the siblings before you close it.** Fix the *pattern*, not the site where you noticed it:
the other callers of the helper, the other copies of the constant, the sibling script doing the same
job for a different surface. One project was bitten by a single defect three times in six weeks
because each fix was applied only where the bug was found.

⚠ **A correct enumeration fails by stopping at the first entry that is already green.** In one case
a comment *predicted the exact failure and named the other copy* — the author followed it as far as
the red, fixed that, and stopped. **A comment that predicts a failure does not prevent it.** The red
is a terminator; a written list is not.

**A fact held in more than one place needs every copy enumerated** — repairing one tells you nothing
about the others, and consulting one tells you nothing either. And: **knowing a copy can be stale is
not the same as checking the one that cannot be.** A gate that compared two files in git passed
happily while ten of the eleven jobs it described were not running, because neither file was the
machine.

**A component that stops running does not only stop doing its job — it invalidates every decision
made because it existed.** When one stops, grep for the *dependency*, not the symptom: a message
promising it would tidy up, and a gate softened on the grounds that it would.

---

## Rules for reporting

**Distinguish the record from reality, and say which you checked.** A PR being merged is not a
ticket being finished. `systemctl show` on a replaced manager cannot tell "never ran" from "ran 90
times under the previous one". A field that answers a narrower question than the one you asked will
answer it confidently, in the direction that looks clean.

**Say what you dropped.** A silent truncation reads as "that was all of it". And when you truncate a
failure list, **keep the HEAD** — the first failure is the causal one; keeping the tail discards the
cause and leaves a plausible list of consequences.

**State the limits of your instrument.** If the fetch hit its row cap, say which day is a floor. If
a probe cannot see a case, say so rather than reporting its silence as absence.
