# Restoring Claude sessions after a reboot

Byobu is only here so the Claude sessions survive a closed terminal or a dropped
SSH connection. Every command you need is below - nothing else to learn.

## Restore everything at once

    ~/restore-claude.sh

Safe to run at any time. It prints one line per agent and only starts the ones that aren't already running,
and an agent already running in another session is skipped rather than given a second copy of its
conversation, so it can also bring back a single agent that has died without disturbing the others.

## One session per agent

Every agent has its own byobu session, `strength-<name>` in lower case (owner, 2026-11-23: "give each agent
their own byobu session"): `strength-deacon`, `strength-boozer`. It is the name `team/agent-spawn.sh` gives a
spawned agent, so the spawn and the bench find a restored agent the same way. Two more sessions:

| Session | What runs in it |
|---|---|
| `Panel` | The team panel (`box/team-panel.sh`) |
| `Web` | The team page on http://127.0.0.1:8787 (`box/team-web.sh`) |

The script resumes each agent by conversation ID, in the directory its conversation is filed under, with its
git identity from the strength roster. Each spawned developer and tester gets its role's colour from
`box/delivery-sync.py`, which tmux runs whenever a session is created; it never moves or stops an agent.

## Who comes back

Only the agents that were running. The team page keeps a record of who is up and the session each one is in
(`~/.local/state/strength/live-agents.json`, or `LIVE_AGENTS_FILE`). It takes an agent off only after it has
watched that agent stop, which is what a bench does; a reboot or a crash stops the page too, so the record stays
as it was. The restore resumes each agent in the record by its session ID, so a spawned agent's unnamed
conversation comes back, and nobody else, so a benched agent stays benched. With no record (the page never
ran), it falls back to every active agent's newest conversation with that `/rename` title.

The house assistant is the roster's active `project-office` agent. It runs from its own folder,
`~/dev/<name>` (`~/dev/boozer`), which isn't a project. Claude Code never remembers trust for your home
folder, so running it from `~` asked every restart. Its memory folder is a link to the one in `~`, so it
keeps its memories.

## Get into a session

    byobu attach -t strength-deacon

## Get out of a session (Claude keeps running)

Press **F6**. Closing the terminal window does the same.

## See what's running

    byobu list-sessions

## Bring one agent back

Kill its session if it is still there (`byobu kill-session -t strength-<name>`), then run `~/restore-claude.sh`.

## If `claude --resume <name>` says it can't find the session

The name is set inside Claude with `/rename`. Pick from a list instead:

    cd /home/peter && claude --resume
