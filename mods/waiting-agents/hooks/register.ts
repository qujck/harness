import type { EngineInterface, Register } from 'claude-code'
import { authorEmailOf, current, dueWaiting, forget, parseRoster, procStartOf, type Roster, type SessionFile } from './watch.ts'

const POLL_MS = 10_000

// Where Claude Code writes `<pid>.json` for every live session: under its config directory, which is
// `$CLAUDE_CONFIG_DIR` when set and `~/.claude` otherwise.
//
// ⚠ NOT RELATIVE TO THE PLUGIN'S OWN DIRECTORY. The first version used `${$.plugin.root}/../../sessions`,
// which reaches ~/.claude/sessions only when the mod sits two levels under ~/.claude. Installed the way
// the README says (CLAUDE_CODE_PLUGIN_DIRS=/path/to/harness/mods/waiting-agents) it resolved to
// /path/to/harness/sessions and every poll in the delivery lead's session logged
// `$.fs.list(...) failed: ENOENT` (2026-10-15). The tests passed because their fake filesystem answered
// any path ending in /sessions; they now answer only the real one.
export async function sessionsDir($: EngineInterface): Promise<string> {
  const config = await $.env.get('CLAUDE_CONFIG_DIR')
  if (config) return `${config}/sessions`
  const home = await $.env.get('HOME')
  if (!home) throw new Error('neither CLAUDE_CONFIG_DIR nor HOME is set, so the sessions directory cannot be found')
  return `${home}/.claude/sessions`
}

// The session files of live Claude processes: a file whose pid has gone, or now belongs to another
// process, is left out. Each is named by its launch line's GIT_AUTHOR_EMAIL in the roster, or failing
// that by the session's own name.
async function sessionFiles($: EngineInterface, roster: Roster): Promise<SessionFile[]> {
  const dir = await sessionsDir($)
  const live: SessionFile[] = []
  for (const entry of await $.fs.list(dir)) {
    if (!/^\d+\.json$/.test(entry.name)) continue
    const pid = entry.name.slice(0, -5)
    const stat = await $.fs.read(`/proc/${pid}/stat`).catch(() => undefined)
    if (typeof stat !== 'string') continue
    const text = await $.fs.read(`${dir}/${entry.name}`).catch(() => undefined)
    if (typeof text !== 'string') continue
    let file: SessionFile
    try { file = JSON.parse(text) as SessionFile } catch { continue }
    if (file.procStart !== procStartOf(stat)) continue
    const environ = await $.fs.read(`/proc/${pid}/environ`).catch(() => undefined)
    const email = typeof environ === 'string' ? authorEmailOf(environ) : undefined
    const name = (email && roster.byEmail.get(email)) || file.name
    live.push({ ...file, name })
  }
  return live
}

// One poll: does nothing unless this session is the delivery lead's. Alerts
// are sent only while that session is not mid-turn, so a message is never
// queued behind a long turn: each poll re-reads the files, and an agent that
// stopped waiting in the meantime is simply not reported.
async function poll($: EngineInterface, told: Set<string>): Promise<void> {
  const roster = parseRoster(await $.fs.read(`${await $.session.root()}/agents/roster.json`) as string)
  const files = await sessionFiles($, roster)
  const id = await $.session.id()
  const mine = files.find(f => f.sessionId === id)
  if (!mine?.name || !roster.lead.has(mine.name)) return
  const agents = current(files)
  forget(agents, told)
  const isFree = mine.status !== 'busy' && mine.status !== 'waiting'
  const lines = isFree ? dueWaiting(agents, roster.team, told, await $.clock.now()) : []
  const waiting = [...roster.team].filter(n => agents.get(n)?.status === 'waiting').length
  $.ui.status(`waiting-agents: watching ${roster.team.size}, ${waiting} waiting`)
  if (lines.length === 0) return
  await $.prompt.submit({
    text: ['[waiting-agents mod, not the owner] A team agent is waiting for input:', ...lines].join('\n'),
  })
}

// Loaded into every session, it acts only in the one the roster names as the
// delivery lead, polling ~/.claude/sessions every ten seconds.
export const register: Register = on => {
  const told = new Set<string>()
  let timer: { cancel: () => void } | undefined
  let busy = false

  on('session.start', async ($, e, next) => {
    timer?.cancel()
    timer = $.clock.every(POLL_MS, () => {
      if (busy) return
      busy = true
      poll($, told)
        .catch(err => $.ui.log(`waiting-agents: ${String(err)}`))
        .finally(() => { busy = false })
    })
    return next(e)
  })
}
