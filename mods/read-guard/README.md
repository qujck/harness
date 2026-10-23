# read-guard

A Claude Code mod that refuses the two `Read` calls that put the most context into a session for
nothing. It loads in every session on the box and acts on the session it runs in, subagent loops
included, each loop judged on its own.

**Why.** Measured on the owner's box, 2026-10-23, 14:12–15:12 UTC, seven busy agents: 3.0M characters
of tool output reached the models in the hour, 1.5M of it from twenty whole-file `Read`s. Eleven were
PNG screenshots at 90k–180k characters each, three of them read twice by one agent from two checkouts of
the same commit; one was a 400k-character generated script read whole and then read again as the slice
that was wanted. That hour also held nine compactions, each a 40k–70k summary plus the re-reads it
causes. The engine already answers a repeat `Read` of an unchanged *text* file with `file_unchanged`
and pages a text file over its token cap, so the mod covers only what the engine leaves open.

**The two rules**, each a `tool.call` hook on `Read` that returns `{ deny }` with the remedy in it:

1. **An image already in this context is not read again.** An image (`.png .jpg .jpeg .gif .webp`) is
   remembered by *name and byte size* once it has actually been read, so the same screenshot under a
   worktree's path is the same image, and a re-saved one (another size) is new. The set is per loop
   (main conversation, or a subagent's id) and is **forgotten when that loop compacts**: the summary
   carries no image, so the next read is new again.
2. **A large text file is not read whole by accident.** A `Read` of a file over 64 KiB (about 1,500
   lines of code) with no `offset`, no `limit` and no `allow_large: true` is refused; the message says
   to pass the range, search first, or set `allow_large` when every line is truly wanted. PDFs and
   notebooks have their own paging and are left alone.

A path the mod cannot stat is the tool's to answer, and a failure inside the guard lets the read through
and logs one line: it exists to save context, never to gate work. Every refusal is one line in the
session log (`read-guard: …`), so "why did my Read fail" is answered there.

`claude plugin test mods/read-guard` runs its tests; `scripts/check-mods-tests-pass.sh` runs them on
every PR.
