import type { On } from 'claude-code'
import { expect, mock, test } from 'claude-code/testing'
import { compactWindowOf, configPath, effectiveWindow, guard, hardAtOf, nudgeDue, parseCompactAfter, parseRequest, remainingFraction, requestPath, softPoint } from './compact.ts'

const v = (value: unknown) => ({ value }) as never
const SID = 'sid-1'
const HOME_PATH = `/home/me/.local/state/self-compact/${SID}.json`
const CONFIG_PATH = '/home/me/.config/self-compact/compact-after.json'

type World = {
  tokens: number
  window?: number
  settings?: object
  /** The engine's context breakdown, when the session gives one: its settled window and buffer. */
  breakdown?: { rawMaxTokens: number; source: string; buffer: number }
  /** The COMPACT_AFTER file's text, when present. */
  config?: string
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
  on('session.usage', () => {
    const b = w.breakdown
    const breakdown = b && {
      rawMaxTokens: b.rawMaxTokens, maxTokens: b.rawMaxTokens, autocompactSource: b.source, totalTokens: w.tokens, percentage: 0, gridRows: [],
      categories: [{ name: 'Messages', tokens: w.tokens, color: 'x', isDeferred: false, kind: 'used' }, { name: 'Autocompact buffer', tokens: b.buffer, color: 'x', isDeferred: false, kind: 'buffer' }],
    }
    return v({ startedAt: 0, context: { tokens: w.tokens, window: w.window ?? 1_000_000, breakdown }, rateLimits: [] })
  })
  on('settings.read', () => v(w.settings ?? { autoCompactWindow: 250_000 }))
  on('fs.exists', ($, e) => v((e.path === path && w.request !== undefined) || (e.path === CONFIG_PATH && w.config !== undefined)))
  on('fs.stat', ($, e) => {
    if (e.path !== path || !w.request) throw new Error(`ENOENT: ${e.path}`)
    return v({ kind: 'file', size: w.request.text.length, mtimeMs: w.request.mtimeMs, isLink: false })
  })
  on('fs.read', ($, e) => {
    if (e.path === CONFIG_PATH && w.config !== undefined) return v(w.config)
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

// A session on a 300k window the engine reports itself: auto-compact at 300k − 33k = 267k.
const LIVE_300K = { rawMaxTokens: 300_000, source: 'settings', buffer: 33_000 }

test('under the threshold nothing is sent and nothing compacts; the status line shows both points', async ($, on) => {
  const s = seen(); const w: World = { tokens: 150_000, store: {} }
  stage(on, w, s)
  await turn($ as never)
  expect(s.sent).toEqual([]); expect(s.compacted).toEqual([]); expect(s.logged).toEqual([])
  expect(s.status).toEqual(['self-compact: 150,000 used, nudge at 173,600, auto-compact at 217,000, room 43,400'])
})

test('with no COMPACT_AFTER, at 20% of the room ONE nudge goes out, naming the path and the mod; later turns do not repeat it', async ($, on) => {
  const s = seen(); const w: World = { tokens: 200_000, store: {} }
  stage(on, w, s)
  await turn($ as never)
  expect(s.sent.length).toBe(1)
  expect(s.sent[0]).toContain('[self-compact mod, not the owner] 200,000 tokens used; auto-compact fires at about 217,000, so about 17,000 remain')
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

test('COMPACT_AFTER from the config file is the nudge point: default 200k on a live 300k window, room 67k, no warning', async ($, on) => {
  const s = seen(); const w: World = { tokens: 199_999, store: {}, breakdown: LIVE_300K, config: '{"default":200000}' }
  stage(on, w, s)
  await turn($ as never)
  expect(s.sent).toEqual([])
  expect(s.status.at(-1)).toBe('self-compact: 199,999 used, nudge at 200,000, auto-compact at 267,000, room 67,000')
  w.tokens = 200_000
  await turn($ as never)
  expect(s.sent.length).toBe(1)
  expect(s.sent[0]).toContain('200,000 tokens used; auto-compact fires at about 267,000, so about 67,000 remain')
  expect(s.logged).toEqual([])
})

test('a per-agent entry, keyed by the launch line\'s GIT_AUTHOR_NAME, wins over the default; another name gets the default', async ($, on) => {
  const config = '{"default":200000,"agents":{"Vera":230000}}'
  const s = seen(); const w: World = { tokens: 215_000, store: {}, breakdown: LIVE_300K, config }
  stage(on, w, s, { vars: { HOME: '/home/me', GIT_AUTHOR_NAME: 'Vera' } })
  await turn($ as never)
  expect(s.sent).toEqual([])
  expect(s.status.at(-1)).toContain('nudge at 230,000')
  w.tokens = 230_000
  await turn($ as never)
  expect(s.sent.length).toBe(1)
  // the file is re-read every turn end: a change needs no restart
  w.config = '{"default":200000,"agents":{"Vera":240000}}'
  w.tokens = 235_000
  await turn($ as never)
  expect(s.status.at(-1)).toContain('nudge at 240,000')
  expect(parseCompactAfter(config, 'Cara')).toEqual({ compactAfter: 200_000 })
})

test('the GUARD: a session still on its old 250k window with COMPACT_AFTER 200k has 17k of room, which is said once, in the status line and the log', async ($, on) => {
  // settings were raised to 300k, but this running session settled at 250k when it started
  const s = seen(); const w: World = { tokens: 100_000, store: {}, settings: { autoCompactWindow: 300_000 }, breakdown: { rawMaxTokens: 250_000, source: 'settings', buffer: 33_000 }, config: '{"default":200000}' }
  stage(on, w, s)
  await turn($ as never)
  await turn($ as never)
  expect(s.status.at(-1)).toBe('self-compact: 100,000 used, nudge at 200,000, auto-compact at 217,000, room 17,000 ⚠')
  expect(s.logged).toEqual(['self-compact: only 17,000 tokens between the nudge at 200,000 and auto-compact at 217,000 (read from this session (settings)); 40,000 is the minimum. Raise this session\'s window with /autocompact, or lower COMPACT_AFTER.'])
  // /autocompact 300000 in that session clears it
  w.breakdown = LIVE_300K
  await turn($ as never)
  expect(s.status.at(-1)).toBe('self-compact: 100,000 used, nudge at 200,000, auto-compact at 267,000, room 67,000')
  expect(s.logged.length).toBe(1)
})

test('a garbled COMPACT_AFTER file changes nothing and is named once; the 20% rule applies (NEGATIVE CONTROL)', async ($, on) => {
  const s = seen(); const w: World = { tokens: 150_000, store: {}, breakdown: LIVE_300K, config: '{"default":"lots"}' }
  stage(on, w, s)
  await turn($ as never)
  await turn($ as never)
  expect(s.sent).toEqual([])
  expect(s.logged).toEqual([`self-compact: ${CONFIG_PATH} ignored — "default" is not a positive number`])
  expect(s.status.at(-1)).toBe('self-compact: 150,000 used, nudge at 213,600, auto-compact at 267,000, room 53,400')
})

test('the live breakdown beats the settings estimate: a session the engine says is on 300k is not nudged at the 250k point', async ($, on) => {
  const s = seen(); const w: World = { tokens: 200_000, store: {}, breakdown: LIVE_300K }
  stage(on, w, s)
  await turn($ as never)
  expect(s.sent).toEqual([])
  w.tokens = 213_600
  await turn($ as never)
  expect(s.sent.length).toBe(1)
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
  expect(configPath({ HOME: '/h' })).toBe('/h/.config/self-compact/compact-after.json')
  expect(configPath({ HOME: '/h', XDG_CONFIG_HOME: '/etc/x' })).toBe('/etc/x/self-compact/compact-after.json')
  expect(configPath({})).toBe(undefined)
})

test('with neither HOME nor XDG_STATE_HOME the turn logs one line and does nothing else', async ($, on) => {
  const s = seen(); const w: World = { tokens: 240_000, store: {} }
  stage(on, w, s, { vars: {} })
  await turn($ as never)
  expect(s.sent).toEqual([]); expect(s.compacted).toEqual([])
  expect(s.logged.length).toBe(1)
  expect(s.logged[0]).toContain('neither XDG_STATE_HOME nor HOME')
})

test('pure parts: window arithmetic, settings fallback, breakdown reading, config and request parsing, the guard', async () => {
  // the estimate: 250k − 33k = 217k; remaining is measured against THAT, not the nominal window
  expect(effectiveWindow({ tokens: 0, compactWindow: 250_000 })).toBe(217_000)
  expect(effectiveWindow({ tokens: 0, compactWindow: 20_000 })).toBe(0)
  expect(remainingFraction({ tokens: 173_600, compactWindow: 250_000 })).toBe(0.2)
  expect(remainingFraction({ tokens: 300_000, compactWindow: 250_000 })).toBe(0)
  expect(remainingFraction({ tokens: 1, compactWindow: 0 })).toBe(0)
  expect(compactWindowOf({ autoCompactWindow: 250_000 }, 1_000_000)).toBe(250_000)
  expect(compactWindowOf({}, 1_000_000)).toBe(1_000_000)
  expect(compactWindowOf({ autoCompactWindow: 'big' }, 1_000_000)).toBe(1_000_000)
  // the session's own figure: settled window less every buffer row
  expect(hardAtOf({ rawMaxTokens: 300_000, autocompactSource: 'env', categories: [{ kind: 'used', tokens: 5 }, { kind: 'buffer', tokens: 33_000 }] })).toEqual({ hardAt: 267_000, source: 'env' })
  expect(hardAtOf({ rawMaxTokens: 300_000 })).toEqual({ hardAt: 300_000, source: 'unknown' })
  expect(hardAtOf(undefined)).toBe(undefined)
  expect(hardAtOf({ rawMaxTokens: 0 })).toBe(undefined)
  // on 250k with no COMPACT_AFTER the nudge is due at 173,600 used (20% of 217k left), ~43k before auto-compact
  expect(softPoint({ tokens: 0, compactWindow: 250_000 })).toBe(173_600)
  expect(nudgeDue({ tokens: 173_599, compactWindow: 250_000 }, undefined)).toBe(false)
  expect(nudgeDue({ tokens: 173_600, compactWindow: 250_000 }, undefined)).toBe(true)
  expect(nudgeDue({ tokens: 184_000, compactWindow: 250_000 }, undefined)).toBe(true)
  expect(nudgeDue({ tokens: 210_000, compactWindow: 250_000 }, 200_000)).toBe(false)
  // with COMPACT_AFTER the soft point is exactly that
  expect(softPoint({ tokens: 0, compactWindow: 250_000, compactAfter: 200_000 })).toBe(200_000)
  expect(nudgeDue({ tokens: 199_999, compactWindow: 300_000, hardAt: 267_000, compactAfter: 200_000 }, undefined)).toBe(false)
  expect(nudgeDue({ tokens: 200_000, compactWindow: 300_000, hardAt: 267_000, compactAfter: 200_000 }, undefined)).toBe(true)
  // the guard: 40k minimum, estimate named as such when there is no live figure
  expect(guard({ tokens: 0, compactWindow: 300_000, hardAt: 267_000, compactAfter: 200_000 })).toEqual({ room: 67_000 })
  expect(guard({ tokens: 0, compactWindow: 300_000, hardAt: 267_000, compactAfter: 227_000 })).toEqual({ room: 40_000 })
  expect(guard({ tokens: 0, compactWindow: 250_000, compactAfter: 200_000 }).warning).toContain('(estimated from the settings window)')
  // config parsing
  expect(parseCompactAfter('{"default":200000}', 'Cara')).toEqual({ compactAfter: 200_000 })
  expect(parseCompactAfter('{"default":200000,"agents":{"Cara":230000}}', 'Cara')).toEqual({ compactAfter: 230_000 })
  expect(parseCompactAfter('{"agents":{"Cara":230000}}', 'Ed')).toEqual({ compactAfter: undefined })
  expect(parseCompactAfter('{"default":200000}', undefined)).toEqual({ compactAfter: 200_000 })
  expect(parseCompactAfter('{}', 'Cara')).toEqual({ compactAfter: undefined })
  expect(parseCompactAfter('nope', 'Cara')).toEqual({ refuse: 'the COMPACT_AFTER file is not JSON' })
  expect(parseCompactAfter('[]', 'Cara')).toEqual({ refuse: 'the COMPACT_AFTER file is not a JSON object' })
  expect(parseCompactAfter('{"agents":[]}', 'Cara')).toEqual({ refuse: '"agents" is not an object' })
  expect(parseCompactAfter('{"agents":{"Cara":-1}}', 'Cara')).toEqual({ refuse: '"agents"."Cara" is not a positive number' })
  expect(parseRequest('{}')).toEqual({ request: {} })
  expect(parseRequest('{"instructions":"x"}')).toEqual({ request: { instructions: 'x' } })
  expect(parseRequest('[]')).toEqual({ refuse: 'the request file is not a JSON object' })
  expect(parseRequest('{"instructions":3}')).toEqual({ refuse: '"instructions" is not a string' })
})
