# Runbook: `main` is red

*(The lane this describes is `.github/workflows/ci.yml`'s `repair` job and `hourly-full-suite.yml`;
the mechanics are in [ci-lanes.md](ci-lanes.md). "Red main" means the newest concluded hourly full
suite on `main` failed, so `scripts/full-suite-gate.sh` exits 1 and the merge queue is blocked.)*

## One owner, ahead of everything

**Whoever reads the red first owns it** until a repair PR is armed — and says so where the team
can see it, so nobody else is also fixing it. A red `main` outranks every ticket: the merge queue is
blocked, so every other PR is waiting on this one. The PO makes sure the owner exists; the owner
does not hand it back without a named successor.

## Repair over revert

Repair in place; revert only when the repair is not findable within the cap *({{e.g. 90 minutes}}
— the owner sets it)*. Ship the runbook or lane change WITH the fix when the red exposed one.

## The repair lane

1. Open the repair PR from a `-hotfix`/`-ptN` branch (never the bare ticket id — that deletes the
   lock on merge). **Label it `repair-main` and then push an empty commit**: the label must be on
   the PR at the moment the run is created, and `gh pr create --label` applies it after the opened
   event, so a run created by `create` never sees it.
2. The lane runs the **full suite on the repair PR's merged tree** — that run is the evidence, not
   `main`'s last word. A red repair job is a human stop: read it; do not drop the label to take the
   ordinary verify, because that would merge a repair untested.
3. The gate admits the repair on its own evidence and the merge queue reopens when `main`'s next
   full suite is green. **The label ends when the block ends** — remove it then.
4. Record the mechanism on the row and in `DECISIONS.md` if a rule changed.

## Reading the gate

The full-suite gate prints one of: *admitted on run <id> @ <sha>* (green, named); *THE MERGE QUEUE
IS BLOCKED — main's last full suite was <red>* (exit 1; this branch was not judged bad); *CANNOT
TELL* (exit 2 — a failed query or an unreadable newer run; the verify step proceeds on it by
policy, which is why the gate judges on the newest concluded run rather than saying cannot-tell
when its page is proven behind). "Red" and "could not look" are different states; never treat
the second as the first.

## After a workflow change

If the fix changed how runs share the box (compose project, seat, runner), **replace** every run
created before the change with a new event (an empty commit, or close/reopen); never `gh run
rerun` — a rerun replays the ORIGINAL workflow snapshot.

## What not to do

- Flip the owner's "full suite on every PR" switch; it is the owner's.
- Rerun a red hoping it goes green; name the mechanism.
- Fix the red in the same PR as unrelated work.
