// The pure part of the watcher: reading the roster and the session files,
// and deciding who has just started waiting.

export type Roster = {
  lead: ReadonlySet<string>
  team: ReadonlySet<string>
  // GIT_AUTHOR_EMAIL -> name: the launch line's identity, as agents/roster.json records it.
  byEmail: ReadonlyMap<string, string>
}

export type SessionFile = {
  pid: number
  procStart?: string
  sessionId?: string
  name?: string | null
  status?: string | null
  waitingFor?: string | null
  tmux?: string | null
  updatedAt?: number | null
  statusUpdatedAt?: number | null
}

// agents/roster.json: the active rows of `agents`. The delivery lead watches; every other active role
// is watched. Assistants are kept apart in `assistants` and are never watched.
export function parseRoster(json: string): Roster {
  const lead = new Set<string>()
  const team = new Set<string>()
  const byEmail = new Map<string, string>()
  const doc = JSON.parse(json) as { agents?: { name?: string; email?: string; role?: string; status?: string }[] }
  for (const a of doc.agents ?? []) {
    if (a.status !== 'active' || !a.name) continue
    if (a.email) byEmail.set(a.email, a.name)
    if (a.role === 'delivery-lead') lead.add(a.name)
    else team.add(a.name)
  }
  return { lead, team, byEmail }
}

// The GIT_AUTHOR_EMAIL in a process's NUL-separated /proc/<pid>/environ, if it has one.
export function authorEmailOf(environ: string): string | undefined {
  for (const kv of environ.split('\0')) {
    if (kv.startsWith('GIT_AUTHOR_EMAIL=')) return kv.slice('GIT_AUTHOR_EMAIL='.length)
  }
  return undefined
}

// Field 22 of /proc/<pid>/stat, the process's start time: the session file's
// `procStart`, so a pid reused by another process is not taken for the session.
export function procStartOf(stat: string): string | undefined {
  return stat.slice(stat.lastIndexOf(')') + 2).split(' ')[19]
}

// Several files can name one agent (old ones stay behind): the live one with
// the newest `updatedAt` stands for it.
export function current(files: readonly SessionFile[]): Map<string, SessionFile> {
  const byName = new Map<string, SessionFile>()
  for (const f of files) {
    if (!f.name) continue
    const held = byName.get(f.name)
    if (!held || (f.updatedAt ?? 0) > (held.updatedAt ?? 0)) byName.set(f.name, f)
  }
  return byName
}

// An agent counts as waiting once it has been waiting this long: a prompt
// answered within seconds is not worth waking the delivery lead for.
export const GRACE_MS = 25_000

// Drops from `told` every agent that is no longer waiting, so its next wait is
// reported afresh.
export function forget(agents: ReadonlyMap<string, SessionFile>, told: Set<string>): void {
  for (const name of [...told]) {
    if (agents.get(name)?.status !== 'waiting') told.delete(name)
  }
}

// The lines for team agents waiting for at least GRACE_MS and not yet reported,
// each added to `told` as it is reported.
export function dueWaiting(
  agents: ReadonlyMap<string, SessionFile>,
  team: ReadonlySet<string>,
  told: Set<string>,
  now: number,
): string[] {
  const lines: string[] = []
  for (const name of team) {
    const f = agents.get(name)
    if (f?.status !== 'waiting' || told.has(name)) continue
    const since = f.statusUpdatedAt ?? f.updatedAt ?? now
    if (now - since < GRACE_MS) continue
    told.add(name)
    lines.push(`${name} waiting: ${f.waitingFor || 'input'} (${f.tmux || 'no pane'})`)
  }
  return lines
}
