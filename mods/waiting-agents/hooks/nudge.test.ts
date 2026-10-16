import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import { decide, envFileValue, freshRows, roleWords, statePaths } from './nudge.ts'
import { parseRoster } from './watch.ts'

const ROSTER = JSON.stringify({
  agents: [
    { name: 'Lead', email: 'lead@example.test', role: 'delivery-lead', status: 'active' },
    { name: 'Dev', email: 'dev@example.test', role: 'developer', status: 'active' },
    { name: 'Tess', email: 'tess@example.test', role: 'head-of-testing', status: 'active' },
    { name: 'Gone', email: 'gone@example.test', role: 'developer', status: 'retired' },
  ],
  assistants: [{ name: 'Assistant' }],
})
// The session root is /home/me/dev, so without a HARNESS_PROJECT the project is "dev".
const CONTEXT = '/home/me/.local/state/dev/context'
const LOG = '/home/me/.local/state/dev/lead-nudge.log'
const T0 = Date.parse('2026-10-16T12:00:00Z')
const v = (value: unknown) => ({ value }) as never
const stat = (start: string) => `1 (claude) S ${'0 '.repeat(18)}${start} 0 0`

// Each agent's activity and how long it has been idle at T0; its row is always freshly published.
type Agent = { activity: string; idleAtT0: number }
type World = {
  leadSid: string
  leadStatus: string
  agents: Record<string, Agent>
  /** The checkout's harness.env, when it has one. */
  envFile?: string
  /** Where the publisher writes and the nudger logs; the defaults follow from HOME and the root. */
  context?: string
  log?: string
}

function stage(on: On, w: World, clock: { now: () => number }, sent: string[], log: string[]) {
  const context = w.context ?? CONTEXT
  const logPath = w.log ?? LOG
  mock.env(on, { HOME: '/home/me' })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.root', () => v('/home/me/dev'))
  on('session.id', () => v(w.leadSid))
  on('ui.log', () => v(undefined))
  on('ui.status', () => v(undefined))
  on('fs.list', ($, e) => v(
    e.path === '/home/me/.claude/sessions'
      ? [{ name: '1.json', kind: 'file', size: 1, mtimeMs: 0, isLink: false }]
      : e.path === context
        ? Object.keys(w.agents).map(a => ({ name: `${a}.json`, kind: 'file', size: 1, mtimeMs: 0, isLink: false }))
        : [],
  ))
  on('fs.read', ($, e) => {
    if (e.path.endsWith('/agents/roster.json')) return v(ROSTER)
    if (e.path === '/home/me/dev/harness.env') { if (w.envFile === undefined) throw new Error('ENOENT'); return v(w.envFile) }
    if (e.path === '/proc/1/stat') return v(stat('100'))
    if (e.path === '/home/me/.claude/sessions/1.json') {
      return v(JSON.stringify({ pid: 1, procStart: '100', sessionId: 'lead-sid', name: 'Lead', status: w.leadStatus, updatedAt: 5 }))
    }
    if (e.path.startsWith(`${context}/`)) {
      const agent = e.path.slice(context.length + 1, -5)
      const a = w.agents[agent]!
      const idle = a.activity === 'idle' ? a.idleAtT0 + (clock.now() - T0) / 1000 : null
      return v(JSON.stringify({ agent, ts: new Date(clock.now() - 5_000).toISOString(), activity: a.activity, idle_s: idle }))
    }
    if (e.path === logPath) return v(log.join(''))
    throw new Error('ENOENT')
  })
  on('fs.write', ($, e) => {
    if (e.path !== logPath) throw new Error(`unexpected write to ${e.path}`)
    log.splice(0, log.length, ...e.text.split(/(?<=\n)/))
    return v(undefined)
  })
  on('prompt.submit', ($, e) => { sent.push(e.text); return { text: e.text } as never })
}

const START = { cwd: '/home/me/dev', surface: 'terminal', isInteractive: true } as const
const world = (): World => ({
  leadSid: 'lead-sid',
  leadStatus: 'idle',
  agents: { Dev: { activity: 'idle', idleAtT0: 1000 }, Tess: { activity: 'working', idleAtT0: 0 }, Lead: { activity: 'idle', idleAtT0: 5000 } },
})
const verdicts = (log: string[]) => log.map(l => l.slice(20).trim())

test('two nudges for one state, a threshold apart, and never a third', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  mock.store(on)
  const sent: string[] = []
  const log: string[] = []
  stage(on, world(), clock, sent, log)
  await $.session.start(START)

  await clock.advance(10_000)
  expect(sent.length).toBe(1)
  expect(sent[0]).toBe('[Automated nudge 1 of 2 from the waiting-agents mod, not from the owner; it assigns nothing.] '
    + 'Team agents idle for 15 minutes or more: Dev, developer idle 16m. As delivery lead, check each one and keep the team active.')
  expect(verdicts(log)).toEqual(['sent nudge 1 of 2; idle: Dev, developer idle 16m'])

  await clock.advance(300_000)
  expect(sent.length).toBe(1)
  expect(verdicts(log).at(-1)).toContain('hold: 900s not yet passed since nudge 1 for this state')

  await clock.advance(600_000)
  expect(sent.length).toBe(2)
  expect(sent[1]).toContain('nudge 2 of 2')

  await clock.advance(3_600_000)
  expect(sent.length).toBe(2)
  expect(verdicts(log).at(-1)).toContain('hold: already nudged 2 times for this exact state')
})

test('a new state is nudged afresh, and the bound survives a restart through the store', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  mock.store(on, { nudgeState: { key: 'Dev', count: 2, lastMs: T0 - 60_000 } })
  const sent: string[] = []
  const log: string[] = []
  const w = world()
  stage(on, w, clock, sent, log)
  await $.session.start(START)

  await clock.advance(10_000)
  expect(sent).toEqual([])
  expect(verdicts(log)).toEqual(['hold: already nudged 2 times for this exact state; idle: Dev, developer idle 16m'])

  w.agents.Tess = { activity: 'idle', idleAtT0: 900 }
  await clock.advance(300_000)
  expect(sent.length).toBe(1)
  expect(sent[0]).toContain('nudge 1 of 2')
  expect(sent[0]).toContain('Dev, developer idle 21m; Tess, head of testing idle 20m')
})

test('nobody idle long enough, or the lead mid-turn, is a logged hold and nothing sent', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  mock.store(on)
  const sent: string[] = []
  const log: string[] = []
  const w = world()
  w.agents.Dev = { activity: 'idle', idleAtT0: 100 }
  stage(on, w, clock, sent, log)
  await $.session.start(START)

  await clock.advance(10_000)
  expect(verdicts(log)).toEqual(['hold: no team agent idle for 900s or more'])

  w.agents.Dev = { activity: 'idle', idleAtT0: 2000 }
  w.leadStatus = 'busy'
  await clock.advance(300_000)
  expect(sent).toEqual([])
  expect(verdicts(log).at(-1)).toContain('hold: delivery lead is mid-turn; idle: Dev')
})

test('a session that is not the delivery lead sends and logs nothing', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  mock.store(on)
  const sent: string[] = []
  const log: string[] = []
  const w = world()
  w.leadSid = 'someone-else'
  stage(on, w, clock, sent, log)
  await $.session.start(START)
  await clock.advance(1_000_000)
  expect(sent).toEqual([])
  expect(log).toEqual([])
})

test('harness.env names the project, the context directory and the threshold, as the scripts read them', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  mock.store(on)
  const sent: string[] = []
  const log: string[] = []
  const w = world()
  w.envFile = '# settings\nHARNESS_PROJECT=strength   # the ledger name\nLEAD_NUDGE_THRESHOLD_S="600"\n'
  w.context = '/home/me/.local/state/strength/context'
  w.log = '/home/me/.local/state/strength/lead-nudge.log'
  w.agents.Dev = { activity: 'idle', idleAtT0: 700 }
  stage(on, w, clock, sent, log)
  await $.session.start(START)
  await clock.advance(10_000)
  expect(sent.length).toBe(1)
  expect(sent[0]).toContain('idle for 10 minutes or more: Dev, developer idle 11m')
  expect(verdicts(log)).toEqual(['sent nudge 1 of 2; idle: Dev, developer idle 11m'])
})

test('roster roles, settings, row freshness and the bound, unit by unit', async () => {
  expect([...parseRoster(ROSTER).roleOf]).toEqual([['Dev', 'developer'], ['Tess', 'head-of-testing']])
  expect(roleWords('head-of-testing')).toBe('head of testing')

  expect(envFileValue('export CONTEXT_DIR="/srv/ctx"\n', 'CONTEXT_DIR')).toBe('/srv/ctx')
  expect(envFileValue('CONTEXT_DIR=   # default\n', 'CONTEXT_DIR')).toBe(undefined)
  expect(envFileValue(undefined, 'CONTEXT_DIR')).toBe(undefined)
  expect(statePaths('/home/me', '/home/me/proj', {}, undefined)).toEqual({ contextDir: '/home/me/.local/state/proj/context', log: '/home/me/.local/state/proj/lead-nudge.log' })
  expect(statePaths('/home/me', '/home/me/proj', { CONTEXT_DIR: '/srv/ctx' }, 'HARNESS_PROJECT=x\n')).toEqual({ contextDir: '/srv/ctx', log: '/srv/lead-nudge.log' })

  const rows = freshRows([
    { agent: 'Dev', ts: new Date(T0 - 30_000).toISOString(), activity: 'working' },
    { agent: 'Dev', ts: new Date(T0 - 5_000).toISOString(), activity: 'idle', idle_s: 999 },
    { agent: 'Tess', ts: new Date(T0 - 121_000).toISOString(), activity: 'idle', idle_s: 999 },
  ], T0)
  expect(rows.get('Dev')?.activity).toBe('idle')
  expect(rows.has('Tess')).toBe(false)

  expect(decide('a', undefined, T0, 900)).toEqual({ send: true, count: 1 })
  expect(decide('b', { key: 'a', count: 2, lastMs: T0 }, T0, 900)).toEqual({ send: true, count: 1 })
  expect(decide('a', { key: 'a', count: 1, lastMs: T0 - 899_000 }, T0, 900).send).toBe(false)
  expect(decide('a', { key: 'a', count: 1, lastMs: T0 - 900_000 }, T0, 900)).toEqual({ send: true, count: 2 })
})
