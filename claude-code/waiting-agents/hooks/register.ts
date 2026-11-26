import type { EngineInterface, Register } from 'claude-code'
import { type ContextRow, DEFAULT_THRESHOLD_S, type DayTrip, dayTripText, dayVerdict, MAX_NUDGES, NUDGE_ROLES, TARGET_ROLE, decide, describe, envFileValue, freshRows, idleAgents, type NudgeState, nudgeText, parseTarget, selfNudgeText, spellOf, statePaths, ticketsOf } from './nudge.ts'
import { dueNotices, kindOf, parseQueue, reminder } from './review.ts'
import { authorEmailOf, current, dueWaiting, forget, leadWaitingLine, parseLeadWaiting, parseRoster, procStartOf, type Roster, type SessionFile } from './watch.ts'

const POLL_MS = 10_000
// How often the nudger looks at the team, in the delivery lead's session.
const NUDGE_EVERY_MS = 300_000
// The store key holding the NudgeState, so the two-nudge bound survives a session restart.
const NUDGE_STATE = 'nudgeState'
// How often the delivery lead's session asks whether the development day is over, and the store key of what it did.
const DAY_EVERY_MS = 60_000
const DAY_TRIP = 'dayTrip'
// How often each session looks at the review queue for wakes addressed to it.
const REVIEW_EVERY_MS = 30_000

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
// threshold. The pause file and the nudge-target file sit beside the log, one level above the context
// directory.
type Where = { contextDir: string; log: string; pause: string; target: string; leadWaiting: string; envFile?: string }

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
  const dir = paths.log.slice(0, paths.log.lastIndexOf('/'))
  return { ...paths, pause: `${dir}/waiting-agents.paused`, target: `${dir}/nudge-target`, leadWaiting: `${dir}/lead-waiting`, envFile }
}

// One poll: in every session the roster names, the review queue's wakes (reviewWakes); beyond that, nothing unless this
// session is the delivery lead's, or the head of testing's while the
// nudge-target switch says `testing` (then it nudges and does nothing else). Alerts
// are sent only while that session is not mid-turn, so a message is never
// queued behind a long turn: each poll re-reads the files, and an agent that
// stopped waiting in the meantime is simply not reported.
// `sentAt` is when the team nudge last went, so the self-nudge never goes in the same poll; `self` counts the
// self-nudges of the lead's current idle stretch and `selfAt` when the last went; `waiting` is the lead-waiting line last written; `teamActive`, whether
// any team agent was at work at the last look; `reviewAt` when the review queue is next read, and `remindedAt` when this
// session last had a review wake.
type Nudger = { nextAt: number; problem?: string; dayAt?: number; sentAt?: number; self?: number; selfAt?: number; waiting?: string; teamActive?: boolean; reviewAt: number; remindedAt: number }

async function poll($: EngineInterface, told: Set<string>, nudger: Nudger): Promise<void> {
  // The mod loads in EVERY session on the machine (CLAUDE_CODE_PLUGIN_DIRS names the mods folder),
  // including ones whose root is not a checkout of the project: the house assistant's, or a developer's
  // started in ~/dev. There is no roster to read there, so there is nothing to watch, and nothing
  // is shown: the status line exists only in the session that actually watches (owner, 2026-10-16;
  // the first fix said so in the status bar, with a ⚠ the owner did not want). No ENOENT is logged
  // either (2026-10-16).
  const rosterPath = `${await $.session.root()}/agents/roster.json`
  const rosterText = await $.fs.read(rosterPath).catch(() => undefined)
  if (typeof rosterText !== 'string') { $.ui.status(undefined); await assistant($, told); return }
  const roster = parseRoster(rosterText)
  const files = await sessionFiles($, roster)
  const id = await $.session.id()
  const mine = files.find(f => f.sessionId === id)
  if (mine?.name && (roster.lead.has(mine.name) || roster.team.has(mine.name))) await reviewWakes($, roster, mine, nudger)
  const isLead = !!mine?.name && roster.lead.has(mine.name)
  // The head of testing's session runs the nudger, and nothing else, while the switch says `testing`.
  const isTesting = !!mine?.name && roster.roleOf.get(mine.name) === 'head-of-testing'
  if (!mine || (!isLead && !isTesting)) { $.ui.status(undefined); return }
  const agents = current(files)
  // An agent that has stopped waiting is forgotten even while paused, so a wait it starts during a
  // pause is reported once the pause ends.
  if (isLead) forget(agents, told)
  const where = await whereOf($)
  const targetText = await $.fs.read(where.target).catch(() => undefined)
  const target = parseTarget(typeof targetText === 'string' ? targetText : undefined)
  const nudges = isLead ? target === 'lead' : target === 'testing'
  // A head of testing out of verification time has nothing to show and nothing to do.
  if (!isLead && !nudges) { $.ui.status(undefined); return }
  // While this file exists (e.g. overnight) the mod sends nothing: no waiting alerts and no nudges.
  if (typeof (await $.fs.read(where.pause).catch(() => undefined)) === 'string') { $.ui.status('paused'); return }
  const isFree = mine.status !== 'busy' && mine.status !== 'waiting'
  // The lead on duty waiting on its own prompt is told to the roster's assistants, through a file their session reads.
  if (nudges) await leadWaiting($, nudger, where, roster, mine)
  // The nudger's standing problem, when it has one, rides on the same line so it is never silent.
  const problem = nudges && nudger.problem ? `; ${nudger.problem}` : ''
  if (isLead) await dayTrip($, nudger, where, target)
  if (isLead) {
    // The waiting alerts stay with the delivery lead whatever the switch says; the owner has not moved them.
    const lines = isFree ? dueWaiting(agents, roster.team, told, await $.clock.now()) : []
    const waiting = [...roster.team].filter(n => agents.get(n)?.status === 'waiting').length
    const elsewhere = typeof target === 'object' ? `; nudge target '${target.bad}'?` : nudges ? '' : `; nudges: ${target}`
    $.ui.status(`watching ${roster.team.size}, ${waiting} waiting${elsewhere}${problem}`)
    if (lines.length > 0) {
      await $.prompt.submit({
        text: ['[waiting-agents mod, not the owner] A team agent is waiting for input:', ...lines].join('\n'),
      })
      return
    }
  } else {
    $.ui.status(`nudging for testing${problem}`)
  }
  if (!nudges) return
  const now = await $.clock.now()
  if (now < nudger.nextAt) return
  nudger.nextAt = now + NUDGE_EVERY_MS
  nudger.problem = await nudge($, roster, isFree, now, where, isLead ? 'lead' : 'testing', nudger)
  if (nudger.sentAt !== now && !nudger.problem && nudger.teamActive === false) await selfNudge($, mine, now, where, isLead ? 'lead' : 'testing', nudger)
}

// The review queue's wakes, in every session the roster names: each notice the queue (team/review-queue.py) addresses to
// this session, delivered once as a queued prompt within REVIEW_EVERY_MS (never while the session waits on a prompt of
// its own), and, for a reviewer idle with requests waiting and none in hand, a reminder at most every REMIND_S, held
// while the pause file exists. The queue is $AGENT_REVIEW_QUEUE, else review-queue.json in the state directory beside
// the nudger's log. The delivered ids are kept in the store under the session's name, so a restart does not deliver
// them again.
async function reviewWakes($: EngineInterface, roster: Roster, mine: SessionFile, nudger: Nudger): Promise<void> {
  if (mine.status === 'waiting' || !mine.name) return
  const now = await $.clock.now()
  if (now < nudger.reviewAt) return
  nudger.reviewAt = now + REVIEW_EVERY_MS
  const where = await whereOf($)
  const path = (await $.env.get('AGENT_REVIEW_QUEUE')) || `${where.log.slice(0, where.log.lastIndexOf('/'))}/review-queue.json`
  const text = await $.fs.read(path).catch(() => undefined)
  if (typeof text !== 'string') return
  const q = parseQueue(text)
  if (q.notices.some(n => n?.to === mine.name)) {
    const key = `reviewDelivered:${mine.name}`
    const stored = (await $.store.get(key)) as string[] | undefined
    const delivered = Array.isArray(stored) ? stored : []
    const { due, kept } = dueNotices(q, mine.name, delivered)
    if (due.length) {
      await $.prompt.submit({ text: due.map(n => n.text).join('\n') })
      await $.store.set(key, [...kept, ...due.map(n => n.id)])
      nudger.remindedAt = now
      return
    }
    if (kept.length !== delivered.length) await $.store.set(key, kept)
  }
  const role = roster.roleOf.get(mine.name) ?? ''
  if (!kindOf(role) || mine.status !== 'idle' || !mine.statusUpdatedAt) return
  const words = reminder(q, mine.name, role, (now - mine.statusUpdatedAt) / 1000, (now - nudger.remindedAt) / 1000)
  if (!words) return
  if (typeof (await $.fs.read(where.pause).catch(() => undefined)) === 'string') return
  await $.prompt.submit({ text: words })
  nudger.remindedAt = now
}

// The lead's own idle stretch (nudge.ts, selfNudgeText), while no team agent is at work: once it has lasted the
// threshold, a nudge of its own, at most MAX_NUDGES for the stretch. A session record without `statusUpdatedAt` says nothing of how long, and is left alone.
async function selfNudge($: EngineInterface, mine: SessionFile, now: number, paths: Where, target: 'lead' | 'testing', nudger: Nudger): Promise<void> {
  if (mine.status === 'shell' || mine.status === 'waiting') { nudger.self = undefined; return }
  if (mine.status !== 'idle' || !mine.statusUpdatedAt) return
  const thresholdS = await thresholdOf($, paths)
  const idleS = (now - mine.statusUpdatedAt) / 1000
  if (idleS < thresholdS) return
  if (now - (nudger.selfAt ?? 0) < thresholdS * 1000) return
  const count = (nudger.self ?? 0) + 1
  if (count > MAX_NUDGES) { await logVerdict($, paths.log, now, `hold: the ${TARGET_ROLE[target]} already nudged ${MAX_NUDGES} times while idle`); return }
  await $.prompt.submit({ text: selfNudgeText(count, idleS, target) })
  nudger.self = count
  nudger.selfAt = now
  await logVerdict($, paths.log, now, `sent self-nudge ${count} of ${MAX_NUDGES} to the ${TARGET_ROLE[target]}, idle ${Math.floor(idleS)}s`)
}

// Writes the lead-waiting file when the lead's wait has lasted GRACE_MS, and empties it once the lead moves on; only
// a change is written.
async function leadWaiting($: EngineInterface, nudger: Nudger, where: Where, roster: Roster, mine: SessionFile): Promise<void> {
  if (roster.assistants.length === 0) return
  const now = await $.clock.now()
  const line = leadWaitingLine(mine, now)
  if ((line ?? '') === (nudger.waiting ?? '')) return
  nudger.waiting = line
  await $.fs.write(where.leadWaiting, line ? `${JSON.stringify({ to: roster.assistants, line, since: mine.statusUpdatedAt ?? mine.updatedAt ?? now })}\n` : '')
  if (line) await logVerdict($, where.log, now, `told ${roster.assistants.join(', ')}: ${line}`)
}

// In a session outside any checkout (the house assistant's): each project's lead-waiting file under
// ~/.local/state that names this session is told once, as a queued prompt, while the session is not mid-turn.
async function assistant($: EngineInterface, told: Set<string>): Promise<void> {
  const home = await $.env.get('HOME')
  if (!home) return
  const id = await $.session.id()
  const dir = await sessionsDir($)
  let me: SessionFile | undefined
  for (const entry of await $.fs.list(dir).catch(() => [])) {
    if (!/^\d+\.json$/.test(entry.name)) continue
    const text = await $.fs.read(`${dir}/${entry.name}`).catch(() => undefined)
    try { const f = typeof text === 'string' ? JSON.parse(text) as SessionFile : undefined; if (f?.sessionId === id) { me = f; break } } catch { continue }
  }
  if (!me?.name || me.status === 'busy' || me.status === 'waiting') return
  const state = `${home}/.local/state`
  for (const project of await $.fs.list(state).catch(() => [])) {
    const text = await $.fs.read(`${state}/${project.name}/lead-waiting`).catch(() => undefined)
    const w = parseLeadWaiting(typeof text === 'string' ? text : undefined)
    const key = `${project.name} ${w?.since}`
    if (!w || !w.to.includes(me.name)) { for (const k of [...told]) if (k.startsWith(`${project.name} `)) told.delete(k); continue }
    if (told.has(key)) continue
    told.add(key)
    await $.prompt.submit({ text: `[waiting-agents mod, not the owner] The ${project.name} lead is waiting for input: ${w.line}` })
  }
}

// The development day's trip (nudge.ts, dayVerdict): asks the harness's agents-day-budget.sh, two levels above this
// mod, for the project whose state sits beside the log. A status it cannot get is logged and asked again next minute.
async function dayTrip($: EngineInterface, nudger: Nudger, where: Where, target: ReturnType<typeof parseTarget>): Promise<void> {
  const now = await $.clock.now()
  if (now < (nudger.dayAt ?? 0)) return
  nudger.dayAt = now + DAY_EVERY_MS
  const dir = where.log.slice(0, where.log.lastIndexOf('/'))
  const project = dir.slice(dir.lastIndexOf('/') + 1)
  const script = `${$.plugin.root}/../../team/agents-day-budget.sh`
  const status = await $.process.run(['bash', script, 'status'], { env: { HARNESS_PROJECT: project } }).catch(err => ({ exitCode: -1, stdout: '', stderr: String(err) }))
  const line = status.stdout.trim().split('\n')[0] ?? ''
  if (!line.startsWith('day  ')) { $.ui.log(`day budget status: exit ${status.exitCode} ${status.stderr.trim()}`); return }
  const state = await $.fs.read(`${dir}/agents-day-budget`).catch(() => undefined)
  const day = typeof state === 'string' ? state.trim().split(/\s+/)[0] || undefined : undefined
  const prev = (await $.store.get(DAY_TRIP)) as DayTrip | undefined
  const verdict = dayVerdict(line, day, prev, target)
  if (verdict.target) await $.fs.write(where.target, `${verdict.target}\n`)
  if (verdict.store) await $.store.set(DAY_TRIP, verdict.store)
  if (verdict.alert) {
    await $.prompt.submit({ text: dayTripText(line) })
    await logVerdict($, where.log, now, `sent day trip: ${line}${verdict.target ? '; nudge target testing' : ''}`)
  } else if (verdict.target) {
    await logVerdict($, where.log, now, `a new development day: nudge target ${verdict.target}`)
  }
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

// The nudger: tells the delivery lead (or the head of testing, per the switch), as a queued prompt of its own, which team agents have been idle
// for the threshold or more. A queued prompt never touches the prompt box, so nothing the owner is
// typing in this session is disturbed. Idleness comes from the rows the context publisher writes
// (docs/context-publisher.md); where they live, and the threshold, come from the environment or
// harness.env as the harness scripts read them (`paths`, resolved once per poll).
//
// Returns the problem that stops it reading the rows at all (the context directory is missing), so
// the status line can show it; a silent hold on a misconfigured path looks exactly like a quiet team.
async function thresholdOf($: EngineInterface, paths: Where): Promise<number> {
  return Number((await $.env.get('LEAD_NUDGE_THRESHOLD_S')) || envFileValue(paths.envFile, 'LEAD_NUDGE_THRESHOLD_S')) || DEFAULT_THRESHOLD_S
}

async function nudge($: EngineInterface, roster: Roster, isFree: boolean, now: number, paths: Where, target: 'lead' | 'testing', nudger: Nudger): Promise<string | undefined> {
  const thresholdS = await thresholdOf($, paths)
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
  const fresh = freshRows(rows, now)
  // The ticket store is asked only when someone has been idle long enough.
  const anyIdle = idleAgents(team, fresh, thresholdS)
  const tickets = anyIdle.length ? await heldTickets($, paths) : new Map<string, string | null>()
  const idle = tickets ? idleAgents(team, fresh, thresholdS, tickets) : anyIdle
  // A team agent at work will message the lead, so the lead's own idleness counts only while none is.
  nudger.teamActive = [...team.keys()].some(name => { const a = fresh.get(name)?.activity; return !!a && a !== 'idle' })
  if (nudger.teamActive) nudger.self = undefined
  const unread = tickets ? '' : ' (ticket store unread: every idle agent counts)'
  if (idle.length === 0) {
    if ((await $.store.get(NUDGE_STATE)) !== undefined) await $.store.delete(NUDGE_STATE)
    await logVerdict($, paths.log, now, `hold: no team agent idle for ${thresholdS}s or more and not waiting on anyone`)
    return
  }
  if (!isFree) { await logVerdict($, paths.log, now, `hold: ${TARGET_ROLE[target]} is mid-turn; idle: ${describe(idle)}${unread}`); return }
  const prev = (await $.store.get(NUDGE_STATE)) as NudgeState | undefined
  const { fresh: news, told } = decide(idle, prev, target)
  if (news.length === 0) {
    await $.store.set(NUDGE_STATE, { told } satisfies NudgeState)
    await logVerdict($, paths.log, now, `hold: already nudged about each; idle: ${describe(idle)}${unread}`)
    return
  }
  await $.prompt.submit({ text: nudgeText(news, thresholdS, target) })
  nudger.sentAt = now
  await $.store.set(NUDGE_STATE, { told: idle.map(i => spellOf(i, target)) } satisfies NudgeState)
  const to = target === 'lead' ? '' : ` to the ${TARGET_ROLE[target]}`
  await logVerdict($, paths.log, now, `sent nudge${to}; idle: ${describe(news)}${unread}`)
  return
}

// What each agent holds (ticketsOf), read from the ticket store (`ledger-db.sh agent-tickets`, two levels above this
// mod) for the project whose state sits beside the log; undefined when it cannot be read, which the log says.
async function heldTickets($: EngineInterface, paths: Where): Promise<Map<string, string | null> | undefined> {
  const dir = paths.log.slice(0, paths.log.lastIndexOf('/'))
  const project = dir.slice(dir.lastIndexOf('/') + 1)
  const script = `${$.plugin.root}/../../scripts/ledger-db.sh`
  const out = await $.process.run(['bash', script, 'agent-tickets'], { env: { HARNESS_PROJECT: project } }).catch(err => ({ exitCode: -1, stdout: '', stderr: String(err) }))
  if (out.exitCode !== 0) { $.ui.log(`agent-tickets: exit ${out.exitCode} ${out.stderr.trim()}`); return undefined }
  return ticketsOf(out.stdout)
}

// Loaded into every session, it acts only in the one the roster names as the
// delivery lead (and in the head of testing's while the switch says `testing`),
// polling ~/.claude/sessions every ten seconds and looking for idle team
// agents every five minutes.
export const register: Register = on => {
  const told = new Set<string>()
  const nudger: Nudger = { nextAt: 0, reviewAt: 0, remindedAt: 0 }
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
