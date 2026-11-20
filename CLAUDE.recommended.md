# Recommended rules

Rules that work well with the team but are not on by default. To use one, copy its section into your own
`.claude/local/AGENTS.md` (git-ignored; `AGENTS.md` reads it).

# Threads in messages to the owner

The team page shows each agent's conversation with the owner in threads, one per ticket or topic. The page files a
message under the thread its tag names; without the tag, everything from that agent is in General.

Every agent that is not a developer or a tester starts each
message it writes to the owner in its own pane with that message's thread, in square brackets, at the very start:

- a ticket's key for work on a ticket: `[SE-2736]`;
- a short name for anything with no ticket, written the same way every time for the same thing: `[GitHub billing block]`;
- ` · ask` added when the message asks the owner something: `[GitHub billing block · ask]`. Asking the same thing
  again, before the owner answers, keeps the same tag.
- Each paragraph about another thread opens with that thread's tag, so nothing about one thing sits under another's
  tag: "Nothing else needs you" and other general remarks go under `[General]`. A message about nothing in particular
  has no tag.
- An ask names what is wanted in its own paragraph, the last one before any command to run, so the page can show it.

The page hides the tag and files the message under it. The tag is the only place a ticket key may open a question to
the owner. A message from the owner that starts "Re <thread>: " is about that thread: answer it under the same tag.
Developers and testers write no tag: their thread is the ticket they hold.
