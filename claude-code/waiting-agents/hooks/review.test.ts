import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import { dueNotices, kindOf, parseQueue, reminder, type Queue } from './review.ts'

const ROSTER = JSON.stringify({
  agents: [
    { name: 'Lead', email: 'lead@example.test', role: 'delivery-lead', status: 'active' },
    { name: 'Dev', email: 'dev@example.test', role: 'developer', status: 'active' },
    { name: 'Rev', email: 'rev@example.test', role: 'code-reviewer', status: 'active' },
  ],
})
// The state directory a checkout at /home/me/dev with no harness.env implies, beside the nudger's log.
const QUEUE = '/home/me/.local/state/dev/review-queue.json'
const PAUSE = '/home/me/.local/state/dev/waiting-agents.paused'
const v = (value: unknown) => ({ value }) as never
const stat = (start: string) => `1 (claude) S ${'0 '.repeat(18)}${start} 0 0`
const T0 = Date.parse('2026-11-26T12:00:00Z')

type World = { me: object; queue?: Queue; paused?: boolean }

function stage(on: On, w: World, sent: string[]) {
  mock.env(on, { HOME: '/home/me' })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('session.root', () => v('/home/me/dev'))
  on('session.id', () => v('rev-sid'))
  on('ui.log', () => v(undefined))
  on('ui.status', () => v(undefined))
  on('fs.list', ($, e) => {
    if (e.path !== '/home/me/.claude/sessions') throw new Error(`ENOENT: ${e.path}`)
    return v([{ name: '3.json', kind: 'file', size: 1, mtimeMs: 0, isLink: false }])
  })
  on('fs.read', ($, e) => {
    if (e.path === '/home/me/dev/agents/roster.json') return v(ROSTER)
    if (e.path === QUEUE) { if (!w.queue) throw new Error('ENOENT'); return v(JSON.stringify(w.queue)) }
    if (e.path === PAUSE) { if (!w.paused) throw new Error('ENOENT'); return v('') }
    if (e.path === '/proc/self/stat') return v(stat('1'))
    if (e.path === '/proc/3/stat') return v(stat('300'))
    if (e.path === '/proc/3/environ') return v('PATH=/usr/bin\0GIT_AUTHOR_EMAIL=rev@example.test\0HOME=/home/me')
    if (e.path === '/home/me/.claude/sessions/3.json') return v(JSON.stringify(w.me))
    throw new Error(`ENOENT: ${e.path}`)
  })
  on('fs.write', () => v(undefined))
  mock.store(on)
  on('prompt.submit', ($, e) => { sent.push(e.text); return { text: e.text } as never })
}

const START = { cwd: '/home/me/dev', surface: 'terminal', isInteractive: true } as const
const rev = (status: string, at = T0) => ({ pid: 3, procStart: '300', sessionId: 'rev-sid', name: 'whatever', status, statusUpdatedAt: at, updatedAt: at })
const notice = (id: string, to = 'Rev') => ({ id, to, text: `[review-queue, not the owner] notice ${id}`, at: 1 })
const req = (id: number, state = 'waiting', more = {}) => ({ id, kind: 'code' as const, key: `AB-${id}`, by: 'Dev', state, ...more })

test('each notice for this session is delivered once, as a queued prompt, and never while it waits on a prompt', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const sent: string[] = []
  const w: World = { me: rev('waiting'), queue: { items: [req(1)], notices: [notice('a'), notice('b', 'Tess')] } }
  stage(on, w, sent)
  await $.session.start(START)

  await clock.advance(10_000)
  expect(sent).toEqual([])

  w.me = rev('busy')
  await clock.advance(30_000)
  expect(sent).toEqual(['[review-queue, not the owner] notice a'])

  await clock.advance(30_000)
  expect(sent.length).toBe(1)

  w.queue!.notices.push(notice('c'), notice('d'))
  await clock.advance(30_000)
  expect(sent.at(-1)).toBe('[review-queue, not the owner] notice c\n[review-queue, not the owner] notice d')
})

test('a reviewer idle with requests waiting is reminded once it has been idle fifteen minutes, and fifteen apart', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const sent: string[] = []
  const w: World = { me: rev('idle', T0), queue: { items: [req(1), req(2, 'waiting', { held: true })], notices: [] } }
  stage(on, w, sent)
  await $.session.start(START)

  await clock.advance(870_000)
  expect(sent).toEqual([])
  await clock.advance(60_000)
  expect(sent).toEqual(['[review-queue, not the owner] 1 request is waiting for you (AB-1). Run `team/review-queue.py take code`.'])
  await clock.advance(600_000)
  expect(sent.length).toBe(1)
  await clock.advance(330_000)
  expect(sent.length).toBe(2)
})

test('no reminder while the reviewer has a request in hand, or while paused', async ($, on) => {
  const clock = mock.clock(on, { now: T0 })
  const sent: string[] = []
  const w: World = { me: rev('idle', T0 - 3_600_000), queue: { items: [req(1), req(3, 'taken', { taken_by: 'Rev' })], notices: [] } }
  stage(on, w, sent)
  await $.session.start(START)

  await clock.advance(60_000)
  expect(sent).toEqual([])

  w.queue!.items.pop()
  w.paused = true
  await clock.advance(60_000)
  expect(sent).toEqual([])

  w.paused = false
  await clock.advance(60_000)
  expect(sent.length).toBe(1)
})

test('the pure parts', () => {
  expect(parseQueue('not json')).toEqual({ items: [], notices: [] })
  const q = parseQueue(JSON.stringify({ items: [], notices: [notice('a'), notice('b'), notice('x', 'Dev')] }))
  expect(dueNotices(q, 'Rev', ['a', 'gone'])).toEqual({ due: [notice('b')], kept: ['a'] })
  expect(kindOf('test-reviewer')).toBe('test')
  expect(kindOf('developer')).toBe(undefined)
  const two = { items: [req(1), req(2)], notices: [] }
  expect(reminder(two, 'Rev', 'code-reviewer', 900, 900)).toBe('[review-queue, not the owner] 2 requests are waiting for you (AB-1, AB-2). Run `team/review-queue.py take code`.')
  expect(reminder(two, 'Rev', 'test-reviewer', 9999, 9999)).toBe(undefined)
  expect(reminder(two, 'Rev', 'code-reviewer', 899, 9999)).toBe(undefined)
  expect(reminder(two, 'Dev', 'developer', 9999, 9999)).toBe(undefined)
})
