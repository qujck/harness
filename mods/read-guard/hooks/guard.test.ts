import type { On } from 'claude-code'
import { expect, test } from 'claude-code/testing'
import { LARGE_BYTES, imageKey, judge } from './guard.ts'

const PNG = '/home/me/dev/proj/docs/shot.png'
const PNG2 = '/home/me/dev/proj-worktree/docs/shot.png'
const BIG = '/home/me/dev/proj/build/generated.mjs'
const SMALL = '/home/me/dev/proj/src/small.ts'

type World = { sizes: Record<string, number>; reads: string[] }

// Nothing sits beneath the mod: `fs.stat` answers from the world's sizes and the engine's Read records
// the path it was asked for and answers a text result.
function stage(on: On, w: World) {
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('ui.log', () => ({ value: undefined }) as never)
  on('fs.stat', ($, e) => {
    const size = w.sizes[e.path]
    if (size === undefined) throw new Error(`ENOENT: ${e.path}`)
    return { value: { kind: 'file', size, mtimeMs: 1, isLink: false } } as never
  })
  on('tool.call', { tool: 'Read' }, ($, e) => {
    w.reads.push(e.file_path)
    return { result: { type: 'text', file: { filePath: e.file_path, content: '', numLines: 0, startLine: 1, totalLines: 0 } } } as never
  })
}

test('judge: an image is allowed once and refused as a repeat, by name and size across checkouts', async () => {
  const seen = new Set<string>()
  const first = judge({ file_path: PNG }, 90_000, seen)
  expect('allow' in first).toBe(true)
  if ('allow' in first) seen.add(first.key!)
  const again = judge({ file_path: PNG2 }, 90_000, seen)
  expect('deny' in again).toBe(true)
  if ('deny' in again) expect(again.deny).toMatch(/shot\.png.*already in this context/)
  // The same name at another size is another image.
  expect('allow' in judge({ file_path: PNG2 }, 90_001, seen)).toBe(true)
  expect(imageKey(PNG, 5)).toBe('shot.png:5')
})

test('judge: a large text file needs offset/limit or allow_large; a small one and a pdf never do', async () => {
  const none = new Set<string>()
  const whole = judge({ file_path: BIG }, LARGE_BYTES + 1, none)
  expect('deny' in whole).toBe(true)
  if ('deny' in whole) expect(whole.deny).toMatch(/offset and limit/)
  expect('allow' in judge({ file_path: BIG, offset: 848, limit: 400 }, LARGE_BYTES + 1, none)).toBe(true)
  expect('allow' in judge({ file_path: BIG, limit: 480 }, LARGE_BYTES + 1, none)).toBe(true)
  expect('allow' in judge({ file_path: BIG, allow_large: true }, LARGE_BYTES + 1, none)).toBe(true)
  expect('allow' in judge({ file_path: BIG }, LARGE_BYTES, none)).toBe(true)
  expect('allow' in judge({ file_path: SMALL }, 1_000, none)).toBe(true)
  expect('allow' in judge({ file_path: '/x/big.pdf' }, 10 * LARGE_BYTES, none)).toBe(true)
})

test('the hook lets a first image read through, refuses the repeat, and forgets it after a compaction', async ($, on) => {
  const w: World = { sizes: { [PNG]: 90_000, [PNG2]: 90_000 }, reads: [] }
  stage(on, w)
  // a compaction leaves at least one message: the summary in the transcript's place
  on('session.compact', () => ({ messages: [{ role: 'user', text: 'summary', toolUses: [] }] }) as never)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const first = await $.tool.call({ tool: 'Read', file_path: PNG })
  expect(first.deny).toBeUndefined()
  const again = await $.tool.call({ tool: 'Read', file_path: PNG2 })
  expect(again.deny).toMatch(/read-guard: shot\.png/)
  expect(w.reads).toEqual([PNG])

  // The engine hands the hooks the transcript being compacted; a test's call names it itself.
  await $.session.compact({ messages: [{ role: 'user', text: 'the transcript', toolUses: [] }] } as never)
  const after = await $.tool.call({ tool: 'Read', file_path: PNG2 })
  expect(after.deny).toBeUndefined()
  expect(w.reads).toEqual([PNG, PNG2])
})

test('the hook refuses a whole read of a large file and lets the bounded read through', async ($, on) => {
  const w: World = { sizes: { [BIG]: 400_000, [SMALL]: 2_000 }, reads: [] }
  stage(on, w)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })

  const whole = await $.tool.call({ tool: 'Read', file_path: BIG })
  expect(whole.deny).toMatch(/read-guard: generated\.mjs is 391 KiB/)
  const part = await $.tool.call({ tool: 'Read', file_path: BIG, offset: 848, limit: 400 })
  expect(part.deny).toBeUndefined()
  const small = await $.tool.call({ tool: 'Read', file_path: SMALL })
  expect(small.deny).toBeUndefined()
  expect(w.reads).toEqual([BIG, SMALL])
})

test('a path that cannot be stat-ed is left to the tool', async ($, on) => {
  const w: World = { sizes: {}, reads: [] }
  stage(on, w)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  const r = await $.tool.call({ tool: 'Read', file_path: '/nowhere/x.png' })
  expect(r.deny).toBeUndefined()
  expect(w.reads).toEqual(['/nowhere/x.png'])
})

test('subagent loops keep their own seen set', async ($, on) => {
  const w: World = { sizes: { [PNG]: 90_000 }, reads: [] }
  stage(on, w)
  await $.session.start({ cwd: '/', surface: 'terminal', isInteractive: true })
  await $.tool.call({ tool: 'Read', file_path: PNG })
  const sub = await $.tool.call({ tool: 'Read', file_path: PNG, agentId: 'sub-1' } as never)
  expect(sub.deny).toBeUndefined()
  expect(w.reads).toEqual([PNG, PNG])
})
