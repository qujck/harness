import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'

// The ONE directory the mod may list. The first tests matched any path ending in /sessions, which is
// how a path built from the plugin's own directory passed them while failing on every real install.
const SESSIONS = '/home/me/.claude/sessions'
const ROSTER = JSON.stringify({
  agents: [
    { name: 'Lead', email: 'lead@example.test', role: 'delivery-lead', status: 'active' },
    { name: 'Dev', email: 'dev@example.test', role: 'developer', status: 'active' },
    { name: 'Reviewer', email: 'reviewer@example.test', role: 'code-reviewer', status: 'active' },
    { name: 'Gone', email: 'gone@example.test', role: 'developer', status: 'retired' },
  ],
  assistants: [{ name: 'Assistant' }],
})
const v = (value: unknown) => ({ value }) as never
const stat = (start: string) => `1 (claude) S ${'0 '.repeat(18)}${start} 0 0`

type World = {
  files: Record<string, object>
  procs: Record<string, string>
  env?: Record<string, string>
  /** The process environment the mod reads; HOME=/home/me unless a test says otherwise. */
  vars?: Record<string, string>
  /** Where the session files live; the default is what HOME=/home/me implies. */
  sessions?: string
  /** The session root holds no agents/roster.json (a session started outside a checkout). */
  noRoster?: boolean
  /** The pause file exists beside the nudger's log. */
  paused?: boolean
  /** A platform without /proc (macOS): no stat, no environ. */
  noProc?: boolean
  /** The socket files present under SOCKS, by name. */
  socks?: string[]
}
const SOCKS = '/run/me/cc-socks'

function stage(on: On, world: World, sent: string[], logged: string[], status: string[] = []) {
  const sessions = world.sessions ?? SESSIONS
  mock.env(on, world.vars ?? { HOME: '/home/me' })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.root', () => v('/home/me/dev'))
  on('ui.log', ($, e) => { logged.push(e.text); return v(undefined) })
  on('ui.status', ($, e) => { status.push(e.text ?? ''); return v(undefined) })
  on('session.id', () => v('lead-sid'))
  // Only the real directories answer; any other path is ENOENT, as on a real box. The publisher's
  // context directory exists and is empty here: the nudger is covered in nudge.test.ts, and a
  // missing directory is a reported problem there, not a quiet one.
  on('fs.list', ($, e) => {
    if (e.path.endsWith('/.local/state/dev/context')) return v([])
    if (e.path === SOCKS) return v((world.socks ?? []).map(name => ({ name, kind: 'file', size: 0, mtimeMs: 0, isLink: false })))
    if (e.path !== sessions) throw new Error(`ENOENT: ${e.path}`)
    return v(Object.keys(world.files).map(name => ({ name, kind: 'file', size: 1, mtimeMs: 0, isLink: false })))
  })
  on('fs.read', ($, e) => {
    if (e.path.endsWith('/agents/roster.json')) { if (world.noRoster) throw new Error('ENOENT'); return v(ROSTER) }
    if (e.path.endsWith('/waiting-agents.paused')) { if (world.paused) return v(''); throw new Error('ENOENT') }
    if (e.path === '/proc/self/stat') { if (world.noProc) throw new Error('ENOENT'); return v(stat('1')) }
    if (e.path.endsWith('.json') && !e.path.startsWith(`${sessions}/`)) throw new Error(`ENOENT: ${e.path}`)
    const env = e.path.match(/^\/proc\/(\d+)\/environ$/)?.[1]
    if (env !== undefined) {
      const email = world.env?.[env]
      if (email === undefined) throw new Error('ENOENT')
      return v(`PATH=/usr/bin\0GIT_AUTHOR_EMAIL=${email}\0HOME=/home/me`)
    }
    const pid = e.path.match(/^\/proc\/(\d+)\/stat$/)?.[1]
    if (pid !== undefined) {
      const start = world.procs[pid]
      if (start === undefined) throw new Error('ENOENT')
      return v(stat(start))
    }
    const name = e.path.split('/').pop()!
    if (name in world.files) return v(JSON.stringify(world.files[name]))
    throw new Error('ENOENT')
  })
  // The nudger's log; the nudger itself is covered in nudge.test.ts.
  on('fs.write', () => v(undefined))
  mock.store(on)
  on('prompt.submit', ($, e) => { sent.push(e.text); return { text: e.text } as never })
}

const lead = { pid: 1, procStart: '100', sessionId: 'lead-sid', name: 'Lead', status: 'idle', updatedAt: 5 }
const dev = { pid: 2, procStart: '200', name: 'Dev', status: 'idle', tmux: 'Devs:@1.%3', updatedAt: 5 }
const START = { cwd: '/home/me/dev', surface: 'terminal', isInteractive: true } as const

function world(): World {
  return { procs: { '1': '100', '2': '200' }, files: { '1.json': { ...lead }, '2.json': { ...dev } } }
}

function wait(w: World, at: number) {
  w.files['2.json'] = { ...dev, status: 'waiting', waitingFor: 'permission prompt', statusUpdatedAt: at, updatedAt: at }
}

function leave(w: World, at: number) {
  w.files['2.json'] = { ...dev, status: 'busy', statusUpdatedAt: at, updatedAt: at }
}

test('one message per wait once it has lasted 25 seconds, and again for the next wait', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const logged: string[] = []
  const status: string[] = []
  const w = world()
  stage(on, w, sent, logged, status)
  await $.session.start(START)

  await clock.advance(10_000)
  expect(sent).toEqual([])
  expect(status.at(-1)).toBe('watching 2, 0 waiting')

  wait(w, clock.now())
  await clock.advance(20_000)
  expect(sent).toEqual([])
  await clock.advance(10_000)
  await clock.advance(10_000)
  await clock.advance(10_000)
  expect(sent.length).toBe(1)
  expect(sent[0]).toContain('Dev waiting: permission prompt (Devs:@1.%3)')
  expect(sent[0]).toContain('not the owner')
  expect(status.at(-1)).toBe('watching 2, 1 waiting')

  leave(w, clock.now())
  await clock.advance(10_000)
  wait(w, clock.now())
  await clock.advance(30_000)
  expect(sent.length).toBe(2)
  expect(logged).toEqual([])
})

test('a pause file silences every alert while it exists, shows "paused", and a wait that outlasts it is reported once it is gone', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const status: string[] = []
  const w = world()
  w.paused = true
  stage(on, w, sent, [], status)
  await $.session.start(START)

  wait(w, clock.now())
  await clock.advance(60_000)
  expect(sent).toEqual([])
  expect(status.at(-1)).toBe('paused')

  w.paused = false
  await clock.advance(10_000)
  expect(sent.length).toBe(1)
  expect(sent[0]).toContain('Dev waiting: permission prompt')
  expect(status.at(-1)).toBe('watching 2, 1 waiting')
})

test('without /proc a session is live while the socket its record names exists; one with no socket is skipped', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const logged: string[] = []
  const status: string[] = []
  const w: World = {
    noProc: true,
    procs: {},
    socks: ['1.sock', '2.sock'],
    files: {
      '1.json': { ...lead, messagingSocketPath: `${SOCKS}/1.sock` },
      '2.json': { ...dev, messagingSocketPath: `${SOCKS}/2.sock` },
      // A record naming no socket cannot be told live, so it is left out.
      '3.json': { pid: 3, procStart: '300', name: 'Reviewer', status: 'waiting', statusUpdatedAt: -60_000, updatedAt: 9 },
    },
  }
  stage(on, w, sent, logged, status)
  await $.session.start(START)
  await clock.advance(10_000)
  expect(sent).toEqual([])
  expect(status.at(-1)).toBe('watching 2, 0 waiting')

  w.files['2.json'] = { ...dev, messagingSocketPath: `${SOCKS}/2.sock`, status: 'waiting', waitingFor: 'permission prompt', statusUpdatedAt: clock.now(), updatedAt: clock.now() }
  await clock.advance(40_000)
  expect(sent.length).toBe(1)
  expect(sent[0]).toContain('Dev waiting: permission prompt')

  // The socket has gone: the session is over, whatever its record still says.
  w.socks = ['1.sock']
  await clock.advance(10_000)
  expect(status.at(-1)).toBe('watching 2, 0 waiting')
  expect(sent.length).toBe(1)
  expect(logged).toEqual([])
})

test('a prompt answered within the grace period is never reported', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const w = world()
  stage(on, w, sent, [])
  await $.session.start(START)

  wait(w, clock.now())
  await clock.advance(20_000)
  leave(w, clock.now())
  await clock.advance(60_000)
  expect(sent).toEqual([])
})

test('nothing is sent mid-turn; a wait that ends meanwhile is dropped, one that lasts is sent after', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const w = world()
  stage(on, w, sent, [])
  await $.session.start(START)

  w.files['1.json'] = { ...lead, status: 'busy' }
  wait(w, clock.now())
  await clock.advance(60_000)
  expect(sent).toEqual([])
  leave(w, clock.now())
  w.files['1.json'] = { ...lead, status: 'idle' }
  await clock.advance(30_000)
  expect(sent).toEqual([])

  w.files['1.json'] = { ...lead, status: 'busy' }
  wait(w, clock.now())
  await clock.advance(60_000)
  expect(sent).toEqual([])
  w.files['1.json'] = { ...lead, status: 'idle' }
  await clock.advance(10_000)
  expect(sent.length).toBe(1)
})

test('stale files, dead pids, Assistant and other sessions are ignored', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const logged: string[] = []
  const w: World = {
    procs: { '1': '100', '3': '300', '4': '999', '5': '500' },
    files: {
      '1.json': lead,
      // A dead process's file and a reused pid's file both say waiting.
      '2.json': { pid: 2, procStart: '200', name: 'Reviewer', status: 'waiting', statusUpdatedAt: -60_000, updatedAt: 9 },
      '4.json': { pid: 4, procStart: '400', name: 'Dev', status: 'waiting', statusUpdatedAt: -60_000, updatedAt: 9 },
      // The live Reviewer, newer, is idle; Assistant waits but is no team member.
      '3.json': { pid: 3, procStart: '300', name: 'Reviewer', status: 'idle', updatedAt: 10 },
      '5.json': { pid: 5, procStart: '500', name: 'Assistant', status: 'waiting', statusUpdatedAt: -60_000, updatedAt: 10 },
    },
  }
  stage(on, w, sent, logged)
  await $.session.start(START)
  await clock.advance(10_000)
  expect(sent).toEqual([])

  // In any session but the delivery lead's it never speaks.
  w.files['1.json'] = { ...lead, name: 'Dev' }
  w.files['3.json'] = { pid: 3, procStart: '300', name: 'Reviewer', status: 'waiting', statusUpdatedAt: -60_000, updatedAt: 11 }
  await clock.advance(60_000)
  expect(sent).toEqual([])
  expect(logged).toEqual([])
})

test('a session is known by its launch line email when it has no name', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const w: World = {
    procs: { '1': '100', '2': '200', '3': '300' },
    env: { '1': 'lead@example.test', '2': 'dev@example.test', '3': 'gone@example.test' },
    files: {
      '1.json': { pid: 1, procStart: '100', sessionId: 'lead-sid', name: null, status: 'idle', updatedAt: 5 },
      '2.json': { pid: 2, procStart: '200', name: null, status: 'waiting', waitingFor: 'permission prompt',
                  tmux: 'proj:@1.%2', statusUpdatedAt: -60_000, updatedAt: 6 },
      // A retired agent's email names nobody on the team.
      '3.json': { pid: 3, procStart: '300', name: null, status: 'waiting', statusUpdatedAt: -60_000, updatedAt: 6 },
    },
  }
  stage(on, w, sent, [])
  await $.session.start(START)
  await clock.advance(10_000)
  expect(sent.length).toBe(1)
  expect(sent[0]).toContain('Dev waiting: permission prompt (proj:@1.%2)')
  expect(sent[0]).not.toContain('Gone')
})

// The sessions directory comes from the Claude config directory, never from where the mod is
// installed. `claude plugin test` runs this file with the mod at its real path (a harness checkout,
// nowhere near ~/.claude), so a plugin-relative path would be ENOENT in every test below.
test('the session files are read under $CLAUDE_CONFIG_DIR when it is set', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const logged: string[] = []
  const w: World = { ...world(), vars: { HOME: '/home/me', CLAUDE_CONFIG_DIR: '/srv/claude-cfg' }, sessions: '/srv/claude-cfg/sessions' }
  stage(on, w, sent, logged)
  await $.session.start(START)
  wait(w, clock.now())
  await clock.advance(30_000)
  expect(sent.length).toBe(1)
  expect(logged).toEqual([])
})

test('without CLAUDE_CONFIG_DIR the session files are read under $HOME/.claude', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const logged: string[] = []
  const w: World = { ...world(), vars: { HOME: '/home/other' }, sessions: '/home/other/.claude/sessions' }
  stage(on, w, sent, logged)
  await $.session.start(START)
  wait(w, clock.now())
  await clock.advance(30_000)
  expect(sent.length).toBe(1)
  expect(logged).toEqual([])
})

test('with neither variable set every poll logs one line naming the cause and sends nothing', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const logged: string[] = []
  const w: World = { ...world(), vars: {} }
  stage(on, w, sent, logged)
  await $.session.start(START)
  wait(w, clock.now())
  await clock.advance(30_000)
  expect(sent).toEqual([])
  expect(logged.length).toBe(3)
  expect(logged[0]).toContain('neither CLAUDE_CONFIG_DIR nor HOME is set')
})

test('a session whose root has no agents/roster.json shows NO status line and logs nothing, every poll', async ($, on) => {
  const clock = mock.clock(on)
  const sent: string[] = []
  const logged: string[] = []
  const status: string[] = []
  // the house assistant's session, or a developer's started in ~/dev: no project checkout here
  const w = { ...world(), noRoster: true }
  stage(on, w, sent, logged, status)
  await $.session.start(START)
  await clock.advance(10_000)
  await clock.advance(10_000)
  await clock.advance(10_000)
  expect(sent).toEqual([])
  expect(logged).toEqual([])
  // every poll clears the line (undefined), so nothing is ever drawn there
  expect(status.filter(t => t !== '')).toEqual([])
})
