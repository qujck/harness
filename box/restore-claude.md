# Restoring Claude sessions after a reboot

Byobu is only here so the Claude sessions survive a closed terminal or a dropped
SSH connection. Every command you need is below - nothing else to learn.

## Restore everything at once

    ~/restore-claude.sh

Safe to run at any time. It prints one line per session and only starts the ones
that aren't already running, so it can also bring back a single agent that has
died without disturbing the others.

## Rename a session that came up as a number

If a session shows as `11` instead of a name:

    byobu rename-session -t 11 Delivery

## Restore each agent individually

The script is the reliable route: it resumes each agent by conversation ID, in the
directory its conversation is filed under, with its git identity from the strength
roster. Run it to bring back any single missing session. Sessions and who is in them:

| Session | Panes |
|---|---|
| `Delivery` | Columns of two (top / bottom), worked out from the roster: developers, then testers, then anyone else, with the code reviewer always in the bottom-right pane. Developers and testers never share a column; a gap is an empty shell. Never fewer than 8 panes, more columns as the team grows. |
| `Delivery Lead` | The delivery lead, with the team panel in 32 columns on the right |
| `Project` | Process improvement on the left (an empty slot when the role is vacant), the house assistant on the right |
| `Ops` | The head of testing on the left, the head of operations on the right |

The house assistant runs from its own folder, `~/dev/<name>` (`~/dev/boozer`), which isn't a
project. Claude Code never remembers trust for your home folder, so running it from `~` asked
every restart. Its memory folder is a link to the one in `~`, so it keeps its memories.

Delivery, Project and Ops come back whole or not at all. In Delivery a pane whose agent exits stays in
place, marked dead; bring that one back with `byobu respawn-pane -t <pane>`. Kill and re-run the
whole session only to pick up a roster change. A session name with a space needs quotes:
`byobu attach -t 'Delivery Lead'`.

## Get into a session

    byobu attach -t Project

Names: `Delivery`, `Delivery Lead`, `Project`, `Ops`.

## Get out of a session (Claude keeps running)

Press **F6**. Closing the terminal window does the same.

## Move between the panes in `Delivery`, `Project` or `Ops`

**Shift+F3** / **Shift+F4**, or click the pane.

## See what's running

    byobu list-sessions

## Kill a session so you can recreate it

    byobu kill-session -t Project

## If `claude --resume <name>` says it can't find the session

The name is set inside Claude with `/rename`. Pick from a list instead:

    cd /home/peter && claude --resume

## Adding a new agent

Onboard it in strength first (`scripts/agent-onboard.sh <Name> <role>`), launch it
with `-n <Name>` so its conversation carries the name, then add the name to the
right `columns` or `start` line in `restore-claude.sh` (the `-` in the Delivery line is
the empty slot, ready for one). Until an agent has a named
conversation the script leaves it out with a note rather than failing.
