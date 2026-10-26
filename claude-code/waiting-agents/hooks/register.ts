import type { EngineInterface, Register } from 'claude-code'
import { type ContextRow, DEFAULT_THRESHOLD_S, MAX_NUDGES, NUDGE_ROLES, decide, describe, envFileValue, freshRows, idleAgents, type NudgeState, nudgeText, stateKey, statePaths } from './nudge.ts'
import { authorEmailOf, current, dueWaiting, forget, parseRoster, procStartOf, type Roster, type SessionFile } from './watch.ts'

const POLL_MS = 10_000
// How often the nudger looks at the team, in the delivery lead's session.
const NUDGE_EVERY_MS = 300_000
// The store key holding the NudgeState, so the two-nudge bound survives a session restart.
const NUDGE_STATE = 'nudgeState'

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

// The socket paths that exist now, from one listing of each directory the records name.
async function socketsPresent($: EngineInterface, files: readonly SessionFile[]): Promise<Set<string>> {
  const dirs = new Set(
    files
      .map(f => f.messagingSocketPath)
      .filter((path): path is string => typeof path === 'string' && path.includes('/'))
      .map(path => path.slice(0, path.lastIndexOf('/'))),
  )
  const present = new Set<string>()
  for (const dir of dirs) {
    for (const entry of await $.fs.list(dir).catch(() => [])) present.add(`${dir}/${entry.name}`)
  }
  return present
}

// The session files of live Claude processes: a file whose session has gone is left out. Each is
// named by its launch line's GIT_AUTHOR_EMAIL in the roster, or failing that by the session's own name.
//
// Where /proc exists the process's start time is read from it and compared with the `procStart` the
// record carries, so a pid since given to another process is not taken for the session, and the
// identity is read from the process's environment. A platform without /proc (macOS) publishes
// neither, so there a session counts as live while the socket named in its own record is still
// present: Claude Code writes both the record and the socket when a session starts and removes both
// when it exits. A session killed outright leaves both behind and is reported once more, until the
// files are cleared.
async function sessionFiles($: EngineInterface, roster: Roster): Promise<SessionFile[]> {
  const dir = await sessionsDir($)
  const hasProc = typeof (await $.fs.read('/proc/self/stat').catch(() => undefined)) === 'string'
  const found: { pid: string; file: SessionFile }[] = []
  for (const entry of await $.fs.list(dir)) {
    if (!/^\d+\.json$/.test(entry.name)) continue
    const text = await $.fs.read(`${dir}/${entry.name}`).catch(() => undefined)
    if (typeof text !== 'string') continue
    try { found.push({ pid: entry.name.slice(0, -5), file: JSON.parse(text) as SessionFile }) } catch { continue }
  }
  const sockets = hasProc ? new Set<string>() : await socketsPresent($, found.map(f => f.file))
  const live: SessionFile[] = []
  for (const { pid, file } of found) {
    let name = file.name
    if (hasProc) {
      const stat = await $.fs.read(`/proc/${pid}/stat`).catch(() => undefined)
      if (typeof stat !== 'string' || file.procStart !== procStartOf(stat)) continue
      const environ = await $.fs.read(`/proc/${pid}/environ`).catch(() => undefined)
      const email = typeof environ === 'string' ? authorEmailOf(environ) : undefined
      name = (email && roster.byEmail.get(email)) || file.name
    } else if (!file.messagingSocketPath || !sockets.has(file.messagingSocketPath)) {
      continue
    }
    live.push({ ...file, name })
  }
  return live
}

// Where the publisher writes the rows, where the nudger logs and where the pause file sits, from the
// same settings the harness scripts read (statePaths), with the checkout's harness.env text for the
// threshold. The pause file sits beside the log, one level above the context directory.
type Where = { contextDir: string; log: string; pause: string; envFile?: string }

async function whereOf($: EngineInterface): Promise<Where> {
  const root = await $.session.root()
  const envFileText = await $.fs.read(`${root}/harness.env`).catch(() => undefined)
  const envFile = typeof envFileText === 'string' ? envFileText : undefined
  // A linked worktree's `.git` is a one-line file naming the main checkout; a main checkout's is a
  // directory, and the read fails.
  const gitFileText = await $.fs.read(`${root}/.git`).catch(() => undefined)
  const home = (await $.env.get('HOME')) ?? ''
  const paths = statePaths(home, root, {
    CONTEXT_DIR: (await $.env.get('CONTEXT_DIR')) || undefined,
    HARNESS_PROJECT: (await $.env.get('HARNESS_PROJECT')) || undefined,
  }, envFile, typeof gitFileText === 'string' ? gitFileText : undefined)
  return { ...paths, pause: `${paths.log.slice(0, paths.log.lastIndexOf('/'))}/waiting-agents.paused`, envFile }
}

// One poll: does nothing unless this session is the delivery lead's. Alerts
// are sent only while that session is not mid-turn, so a message is never
// queued behind a long turn: each poll re-reads the files, and an agent that
// stopped waiting in the meantime is simply not reported.
type Nudger = { nextAt: number; problem?: string }

async function poll($: EngineInterface, told: Set<string>, nudger: Nudger): Promise<void> {
  // The mod loads in EVERY session on the machine (CLAUDE_CODE_PLUGIN_DIRS names the mods folder),
  // including ones whose root is not a checkout of the project: the house assistant's, or a developer's
  // started in ~/dev. There is no roster to read there, so there is nothing to watch, and nothing
  // is shown: the status line exists only in the session that actually watches (owner, 2026-10-16;
  // the first fix said so in the status bar, with a ⚠ the owner did not want). No ENOENT is logged
  // either (2026-10-16).
  const rosterPath = `${await $.session.root()}/agents/roster.json`
  const rosterText = await $.fs.read(rosterPath).catch(() => undefined)
  if (typeof rosterText !== 'string') { $.ui.status(undefined); return }
  const roster = parseRoster(rosterText)
  const files = await sessionFiles($, roster)
  const id = await $.session.id()
  const mine = files.find(f => f.sessionId === id)
  if (!mine?.name || !roster.lead.has(mine.name)) { $.ui.status(undefined); return }
  const agents = current(files)
  // An agent that has stopped waiting is forgotten even while paused, so a wait it starts during a
  // pause is reported once the pause ends.
  forget(agents, told)
  const where = await whereOf($)
  // While this file exists (e.g. overnight) the mod sends nothing: no waiting alerts and no nudges.
  if (typeof (await $.fs.read(where.pause).catch(() => undefined)) === 'string') { $.ui.status('paused'); return }
  const isFree = mine.status !== 'busy' && mine.status !== 'waiting'
  const lines = isFree ? dueWaiting(agents, roster.team, told, await $.clock.now()) : []
  const waiting = [...roster.team].filter(n => agents.get(n)?.status === 'waiting').length
  // The nudger's standing problem, when it has one, rides on the same line so it is never silent.
  $.ui.status(`watching ${roster.team.size}, ${waiting} waiting${nudger.problem ? `; ${nudger.problem}` : ''}`)
  if (lines.length > 0) {
    await $.prompt.submit({
      text: ['[waiting-agents mod, not the owner] A team agent is waiting for input:', ...lines].join('\n'),
    })
    return
  }
  const now = await $.clock.now()
  if (now < nudger.nextAt) return
  nudger.nextAt = now + NUDGE_EVERY_MS
  nudger.problem = await nudge($, roster, isFree, now, where)
}

// One line, prefixed with the local time, appended to the nudger's log. Every verdict is logged,
// holds included, so "did the nudger fire" is answered from the file.
async function logVerdict($: EngineInterface, path: string, nowMs: number, text: string): Promise<void> {
  const d = new Date(nowMs)
  const p = (n: number) => String(n).padStart(2, '0')
  const stamp = `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`
  const before = await $.fs.read(path).catch(() => '')
  await $.fs.write(path, `${typeof before === 'string' ? before : ''}${stamp} ${text}\n`)
}

// The nudger: tells the delivery lead, as a queued prompt of its own, which team agents have been idle
// for the threshold or more. A queued prompt never touches the prompt box, so nothing the owner is
// typing in this session is disturbed. Idleness comes from the rows the context publisher writes
// (docs/context-publisher.md); where they live, and the threshold, come from the environment or
// harness.env as the harness scripts read them (`paths`, resolved once per poll).
//
// Returns the problem that stops it reading the rows at all (the context directory is missing), so
// the status line can show it; a silent hold on a misconfigured path looks exactly like a quiet team.
async function nudge($: EngineInterface, roster: Roster, isFree: boolean, now: number, paths: Where): Promise<string | undefined> {
  const thresholdS = Number((await $.env.get('LEAD_NUDGE_THRESHOLD_S')) || envFileValue(paths.envFile, 'LEAD_NUDGE_THRESHOLD_S')) || DEFAULT_THRESHOLD_S
  const entries = await $.fs.list(paths.contextDir).catch(() => undefined)
  if (entries === undefined) {
    const problem = `context dir missing: ${paths.contextDir}`
    $.ui.log(`${problem} (set CONTEXT_DIR or HARNESS_PROJECT; see docs/context-publisher.md)`)
    return problem
  }
  const rows: ContextRow[] = []
  for (const entry of entries) {
    if (!entry.name.endsWith('.json')) continue
    const text = await $.fs.read(`${paths.contextDir}/${entry.name}`).catch(() => undefined)
    try { if (typeof text === 'string') rows.push(JSON.parse(text) as ContextRow) } catch { continue }
  }
  // Only the roles the nudger reports: the head of testing and the assistants are never nudged.
  const team = new Map([...roster.roleOf].filter(([, role]) => NUDGE_ROLES.includes(role)))
  const idle = idleAgents(team, freshRows(rows, now), thresholdS)
  if (idle.length === 0) {
    // The team is active, so the bound has covered one idle spell: the next spell, of the same agents
    // or others, starts afresh. Without this a set nudged twice stayed held for good.
    if ((await $.store.get(NUDGE_STATE)) !== undefined) await $.store.delete(NUDGE_STATE)
    await logVerdict($, paths.log, now, `hold: no team agent idle for ${thresholdS}s or more`)
    return
  }
  if (!isFree) { await logVerdict($, paths.log, now, `hold: delivery lead is mid-turn; idle: ${describe(idle)}`); return }
  const key = stateKey(idle)
  const prev = (await $.store.get(NUDGE_STATE)) as NudgeState | undefined
  const verdict = decide(key, prev, now, thresholdS)
  if (!verdict.send) { await logVerdict($, paths.log, now, `hold: ${verdict.why}; idle: ${describe(idle)}`); return }
  await $.prompt.submit({ text: nudgeText(verdict.count, idle, thresholdS) })
  await $.store.set(NUDGE_STATE, { key, count: verdict.count, lastMs: now } satisfies NudgeState)
  await logVerdict($, paths.log, now, `sent nudge ${verdict.count} of ${MAX_NUDGES}; idle: ${describe(idle)}`)
  return
}

// Loaded into every session, it acts only in the one the roster names as the
// delivery lead, polling ~/.claude/sessions every ten seconds and looking for
// idle team agents every five minutes.
export const register: Register = on => {
  const told = new Set<string>()
  const nudger: Nudger = { nextAt: 0 }
  let timer: { cancel: () => void } | undefined
  let busy = false

  on('session.start', async ($, e, next) => {
    timer?.cancel()
    timer = $.clock.every(POLL_MS, () => {
      if (busy) return
      busy = true
      poll($, told, nudger)
        .catch(err => $.ui.log(String(err)))
        .finally(() => { busy = false })
    })
    return next(e)
  })
}
