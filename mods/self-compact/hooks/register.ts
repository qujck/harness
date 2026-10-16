import type { EngineInterface, Register } from 'claude-code'
import { compactWindowOf, nudgeDue, nudgeText, parseRequest, requestPath, type Window } from './compact.ts'

// Store keys, per session: the token count at the last nudge (re-armed when the count drops under it),
// and the mtime of the last request file acted on (a file is acted on once; the agent may write it again).
const NUDGED_AT = 'nudgedAtTokens'
const HANDLED_MTIME = 'handledRequestMtimeMs'

// Where this session's request file is: its OWN id in the path and nothing else. There is no way to
// name another session here, and `$.session.compact` takes no target, so a request can only ever
// compact the session that reads it.
async function ownRequestPath($: EngineInterface): Promise<string> {
  const env = { XDG_STATE_HOME: await $.env.get('XDG_STATE_HOME'), HOME: await $.env.get('HOME') }
  return requestPath(await $.session.id(), env)
}

async function windowOf($: EngineInterface): Promise<Window | undefined> {
  const { context } = await $.session.usage()
  if (typeof context.tokens !== 'number') return undefined
  const settings = await $.settings.read().catch(() => ({}))
  return { tokens: context.tokens, compactWindow: compactWindowOf(settings, context.window) }
}

// A request file newer than the last one handled is read, acted on, and remembered by its mtime.
// The compact call runs between turns and rejects while a turn runs, so a request written mid-turn
// is simply read at the next turn's end.
async function actOnRequest($: EngineInterface, path: string): Promise<boolean> {
  if (!(await $.fs.exists(path))) return false
  const { mtimeMs } = await $.fs.stat(path)
  const handled = await $.store.get(HANDLED_MTIME)
  if (typeof handled === 'number' && mtimeMs <= handled) return false
  await $.store.set(HANDLED_MTIME, mtimeMs)
  const parsed = parseRequest(await $.fs.read(path))
  if ('refuse' in parsed) {
    $.ui.log(`self-compact: ${path} ignored — ${parsed.refuse}`)
    return false
  }
  const result = await $.session.compact(parsed.request.instructions === undefined ? {} : { instructions: parsed.request.instructions })
  if ('skip' in result && result.skip) $.ui.log(`self-compact: a hook vetoed the compaction — ${result.skip}`)
  else $.ui.log('self-compact: compacted at the agent\'s request')
  return true
}

// Once per fill: when the compaction window is nearly full and nothing has been requested, the agent
// is asked (as a prompt of its own, marked as the mod's) to find a stopping point and write the file.
async function nudgeIfDue($: EngineInterface, path: string): Promise<void> {
  const w = await windowOf($)
  if (!w) return
  const nudgedAt = await $.store.get(NUDGED_AT)
  const prior = typeof nudgedAt === 'number' ? nudgedAt : undefined
  if (prior !== undefined && w.tokens < prior) await $.store.delete(NUDGED_AT)
  if (!nudgeDue(w, prior)) return
  await $.store.set(NUDGED_AT, w.tokens)
  $.ui.status(`self-compact: ${Math.round((1 - (w.compactWindow - w.tokens) / w.compactWindow) * 100)}% of the compaction window used, nudged`)
  await $.prompt.submit({ text: nudgeText(w, path) })
}

// After every main-loop turn (a subagent's or fork's turns are passed through untouched): act on a
// request if one is waiting, else nudge if the window says so. Errors are logged, never thrown into
// the turn.
export const register: Register = on => {
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if ((e as { agentId?: string }).agentId !== undefined) return result
    try {
      const path = await ownRequestPath($)
      if (!(await actOnRequest($, path))) await nudgeIfDue($, path)
    } catch (err) {
      $.ui.log(`self-compact: ${String(err)}`)
    }
    return result
  })
}
