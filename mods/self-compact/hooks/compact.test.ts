import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import { compactWindowOf, effectiveWindow, nudgeDue, parseRequest, remainingFraction, requestPath } from './compact.ts'

const v = (value: unknown) => ({ value }) as never
const SID = 'sid-1'
const HOME_PATH = `/home/me/.local/state/self-compact/${SID}.json`

type World = {
  tokens: number
  window?: number
  settings?: object
  /** The request file, if present: its text and mtime. */
  request?: { text: string; mtimeMs: number }
  store: Record<string, unknown>
}

type Seen = { sent: string[]; compacted: object[]; logged: string[]; status: string[] }

type Stage = {
  /** The process environment the mod reads; HOME=/home/me unless a test says otherwise. */
  vars?: Record<string, string>
  /** Where the request file is expected; HOME_PATH unless a test says otherwise. */
  path?: string
  /** A hook beneath that vetoes every compaction with this reason. */
  veto?: string
}

// Every event the mod uses is answered here, once; the engine's own `turn.complete` beneath the
// plugin answers `{ text }` as core does.
function stage(on: On, w: World, seen: Seen, opts: Stage = {}) {
  const path = opts.path ?? HOME_PATH
  mock.env(on, opts.vars ?? { HOME: '/home/me' })
  on('turn.complete', ($, e) => ({ text: e.answer }))
  on('session.id', () => v(SID))
  on('session.usage', () => v({ startedAt: 0, context: { tokens: w.tokens, window: w.window ?? 1_000_000 }, rateLimits: [] }))
  on('settings.read', () => v(w.settings ?? { autoCompactWindow: 250_000 }))
  on('fs.exists', ($, e) => v(e.path === path && w.request !== undefined))
  on('fs.stat', ($, e) => {
    if (e.path !== path || !w.request) throw new Error(`ENOENT: ${e.path}`)
    return v({ kind: 'file', size: w.request.text.length, mtimeMs: w.request.mtimeMs, isLink: false })
  })
  on('fs.read', ($, e) => {
    if (e.path !== path || !w.request) throw new Error(`ENOENT: ${e.path}`)
    return v(w.request.text)
  })
  on('store.get', ($, e) => v(w.store[e.key]))
  on('store.set', ($, e) => { w.store[e.key] = e.value; return v(undefined) })
  on('store.delete', ($, e) => { delete w.store[e.key]; return v(undefined) })
  on('ui.log', ($, e) => { seen.logged.push(e.text); return v(undefined) })
  on('ui.status', ($, e) => { seen.status.push(e.text ?? ''); return v(undefined) })
  on('prompt.submit', ($, e) => { seen.sent.push(e.text); return { text: e.text } as never })
  on('session.compact', ($, e) => {
    if (opts.veto) return { skip: opts.veto } as never
    seen.compacted.push({ instructions: e.instructions })
    // a compaction leaves at least one message: the summary in the transcript's place
    return { messages: [{ role: 'user', text: 'summary', toolUses: [] }] } as never
  })
}

const seen = (): Seen => ({ sent: [], compacted: [], logged: [], status: [] })
const TURN = { answer: 'done', durationMs: 1, isAborted: false, turnId: 't', reason: 'answer' } as const

async function turn($: { turn: { complete: (e: unknown) => Promise<unknown> } }, extra: object = {}) {
  await $.turn.complete({ ...TURN, ...extra })
}

test('under the threshold nothing is sent and nothing compacts', async ($, on) => {
  const s = seen(); const w: World = { tokens: 150_000, store: {} }
  stage(on, w, s)
  await turn($ as never)
  expect(s.sent).toEqual([]); expect(s.compacted).toEqual([]); expect(s.logged).toEqual([])
})

test('at 20% remaining ONE nudge goes out, naming the path and the mod; later turns do not repeat it', async ($, on) => {
  const s = seen(); const w: World = { tokens: 200_000, store: {} }
  stage(on, w, s)
  await turn($ as never)
  expect(s.sent.length).toBe(1)
  expect(s.sent[0]).toContain('[self-compact mod, not the owner]')
  expect(s.sent[0]).toContain('8% of your room remains: 200,000 tokens used, and auto-compact fires at about 217,000')
  expect(s.sent[0]).toContain(HOME_PATH)
  w.tokens = 215_000
  await turn($ as never)
  await turn($ as never)
  expect(s.sent.length).toBe(1)
  expect(s.compacted).toEqual([])
})

test('a compaction drops the count and re-arms the nudge for the next fill', async ($, on) => {
  const s = seen(); const w: World = { tokens: 205_000, store: {} }
  stage(on, w, s)
  await turn($ as never)
  expect(s.sent.length).toBe(1)
  w.tokens = 60_000                     // compacted (by whoever)
  await turn($ as never)
  expect(s.sent.length).toBe(1)
  w.tokens = 230_000                    // filled again
  await turn($ as never)
  expect(s.sent.length).toBe(2)
})

test('a request file compacts the session with its instructions, once, and no nudge rides along', async ($, on) => {
  const s = seen(); const w: World = { tokens: 210_000, store: {}, request: { text: '{"instructions":"keep the plan"}', mtimeMs: 1000 } }
  stage(on, w, s)
  await turn($ as never)
  expect(s.compacted).toEqual([{ instructions: 'keep the plan' }])
  expect(s.sent).toEqual([])
  expect(s.logged).toEqual(["self-compact: compacted at the agent's request"])
  // the same file, unchanged, is not acted on again; a rewritten one is
  w.tokens = 40_000
  await turn($ as never)
  expect(s.compacted.length).toBe(1)
  w.request = { text: '{}', mtimeMs: 2000 }
  await turn($ as never)
  expect(s.compacted.length).toBe(2)
  expect(s.compacted[1]).toEqual({ instructions: undefined })
})

test('a garbled request compacts nothing and says why once (the NEGATIVE CONTROL)', async ($, on) => {
  const s = seen(); const w: World = { tokens: 100_000, store: {}, request: { text: 'not json', mtimeMs: 5 } }
  stage(on, w, s)
  await turn($ as never)
  await turn($ as never)
  expect(s.compacted).toEqual([])
  expect(s.logged).toEqual([`self-compact: ${HOME_PATH} ignored — the request file is not JSON`])
})

test('a vetoed compaction is reported, not retried', async ($, on) => {
  const s = seen(); const w: World = { tokens: 100_000, store: {}, request: { text: '{}', mtimeMs: 5 } }
  stage(on, w, s, { veto: 'off' })
  await turn($ as never)
  await turn($ as never)
  expect(s.compacted).toEqual([])
  expect(s.logged).toEqual(['self-compact: a hook vetoed the compaction — off'])
})

test("a subagent's turn is passed through untouched", async ($, on) => {
  const s = seen(); const w: World = { tokens: 240_000, store: {}, request: { text: '{}', mtimeMs: 5 } }
  stage(on, w, s)
  await turn($ as never, { agentId: 'a-1' })
  expect(s.sent).toEqual([]); expect(s.compacted).toEqual([])
})

test('the request path is under $XDG_STATE_HOME when set, and is only ever this session\'s', async ($, on) => {
  const s = seen(); const w: World = { tokens: 100_000, store: {}, request: { text: '{}', mtimeMs: 5 } }
  stage(on, w, s, { vars: { HOME: '/home/me', XDG_STATE_HOME: '/var/state' }, path: `/var/state/self-compact/${SID}.json` })
  await turn($ as never)
  expect(s.compacted.length).toBe(1)
  expect(requestPath('abc', { HOME: '/h' })).toBe('/h/.local/state/self-compact/abc.json')
  expect(() => requestPath('../other', { HOME: '/h' })).toThrow()
  expect(() => requestPath('abc', {})).toThrow()
})

test('with neither HOME nor XDG_STATE_HOME the turn logs one line and does nothing else', async ($, on) => {
  const s = seen(); const w: World = { tokens: 240_000, store: {} }
  stage(on, w, s, { vars: {} })
  await turn($ as never)
  expect(s.sent).toEqual([]); expect(s.compacted).toEqual([])
  expect(s.logged.length).toBe(1)
  expect(s.logged[0]).toContain('neither XDG_STATE_HOME nor HOME')
})

test('pure parts: window arithmetic, settings fallback, request parsing', async () => {
  // the effective window is 250k − 33k = 217k: remaining is measured against THAT, not the nominal window
  expect(effectiveWindow({ tokens: 0, compactWindow: 250_000 })).toBe(217_000)
  expect(effectiveWindow({ tokens: 0, compactWindow: 20_000 })).toBe(0)
  expect(remainingFraction({ tokens: 173_600, compactWindow: 250_000 })).toBe(0.2)
  expect(remainingFraction({ tokens: 300_000, compactWindow: 250_000 })).toBe(0)
  expect(remainingFraction({ tokens: 1, compactWindow: 0 })).toBe(0)
  expect(compactWindowOf({ autoCompactWindow: 250_000 }, 1_000_000)).toBe(250_000)
  expect(compactWindowOf({}, 1_000_000)).toBe(1_000_000)
  expect(compactWindowOf({ autoCompactWindow: 'big' }, 1_000_000)).toBe(1_000_000)
  // on 250k the nudge is due at 173,600 used (20% of 217k left), which leaves ~43k before auto-compact
  expect(nudgeDue({ tokens: 173_599, compactWindow: 250_000 }, undefined)).toBe(false)
  expect(nudgeDue({ tokens: 173_600, compactWindow: 250_000 }, undefined)).toBe(true)
  // the old threshold, 200k used, is now far past due: Anthony's pilot restarts at ~184k and must be nudged at once
  expect(nudgeDue({ tokens: 184_000, compactWindow: 250_000 }, undefined)).toBe(true)
  expect(nudgeDue({ tokens: 210_000, compactWindow: 250_000 }, 200_000)).toBe(false)
  expect(parseRequest('{}')).toEqual({ request: {} })
  expect(parseRequest('{"instructions":"x"}')).toEqual({ request: { instructions: 'x' } })
  expect(parseRequest('[]')).toEqual({ refuse: 'the request file is not a JSON object' })
  expect(parseRequest('{"instructions":3}')).toEqual({ refuse: '"instructions" is not a string' })
})
