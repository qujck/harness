import type { EngineInterface, Register } from 'claude-code'
import { COMPACTED_TEXT, compactWindowOf, configPath, guard, hardAtOf, nudgeDue, nudgeText, parseCompactAfter, parseRequest, requestPath, statusText, type Window } from './compact.ts'

// Store keys, per session: the token count at the last nudge (re-armed when the count drops under it),
// the mtime of the last request file acted on (a file is acted on once; the agent may write it again),
// and the last guard warning and config refusal logged (each is logged once, not every turn).
const NUDGED_AT = 'nudgedAtTokens'
const HANDLED_MTIME = 'handledRequestMtimeMs'
const WARNED = 'guardWarningLogged'
const REFUSED = 'configRefusalLogged'

async function envOf($: EngineInterface) {
  return {
    XDG_STATE_HOME: await $.env.get('XDG_STATE_HOME'),
    XDG_CONFIG_HOME: await $.env.get('XDG_CONFIG_HOME'),
    HOME: await $.env.get('HOME'),
  }
}

// Where this session's request file is: its OWN id in the path and nothing else. There is no way to
// name another session here, and `$.session.compact` takes no target, so a request can only ever
// compact the session that reads it.
async function ownRequestPath($: EngineInterface): Promise<string> {
  return requestPath(await $.session.id(), await envOf($))
}

// COMPACT_AFTER for this agent: the config file is read every turn end (no restart to change it),
// the agent is the launch line's GIT_AUTHOR_NAME. No file, or no entry for this agent, means none.
async function compactAfterOf($: EngineInterface): Promise<number | undefined> {
  const path = configPath(await envOf($))
  if (!path || !(await $.fs.exists(path))) return undefined
  const parsed = parseCompactAfter(await $.fs.read(path), await $.env.get('GIT_AUTHOR_NAME'))
  if ('refuse' in parsed) {
    const line = `${path} ignored — ${parsed.refuse}`
    if ((await $.store.get(REFUSED)) !== line) { await $.store.set(REFUSED, line); $.ui.log(line) }
    return undefined
  }
  return parsed.compactAfter
}

// The window as this session has it. The breakdown (`summary`: local estimates, no API call) carries
// the session's SETTLED window and its buffer row, so the hard point is read, not assumed: a running
// session keeps the window it started with, or the one /autocompact gave it, whatever the settings
// file says now. Without a breakdown the settings window less the measured reserve stands in.
async function windowOf($: EngineInterface): Promise<Window | undefined> {
  const { context } = await $.session.usage({ breakdown: 'summary' })
  if (typeof context.tokens !== 'number') return undefined
  const settings = await $.settings.read().catch(() => ({}))
  const live = hardAtOf((context as { breakdown?: unknown }).breakdown)
  return {
    tokens: context.tokens,
    compactWindow: compactWindowOf(settings, context.window),
    hardAt: live?.hardAt,
    hardSource: live?.source,
    compactAfter: await compactAfterOf($),
  }
}

// A request file newer than the last one handled is read, acted on, and remembered by its mtime.
// The compact call runs between turns and rejects while a turn runs, so a request written mid-turn
// is simply read at the next turn's end. A compaction that happened is followed by one prompt of
// the mod's own: a compaction is not a turn, so without it the session would wait for input, and
// the standing rule to read the durable record first would never fire. A veto or a refused request
// compacted nothing, so neither is followed by anything.
async function actOnRequest($: EngineInterface, path: string): Promise<boolean> {
  if (!(await $.fs.exists(path))) return false
  const { mtimeMs } = await $.fs.stat(path)
  const handled = await $.store.get(HANDLED_MTIME)
  if (typeof handled === 'number' && mtimeMs <= handled) return false
  await $.store.set(HANDLED_MTIME, mtimeMs)
  const parsed = parseRequest(await $.fs.read(path))
  if ('refuse' in parsed) {
    $.ui.log(`${path} ignored — ${parsed.refuse}`)
    return false
  }
  const result = await $.session.compact(parsed.request.instructions === undefined ? {} : { instructions: parsed.request.instructions })
  if ('skip' in result && result.skip) {
    $.ui.log(`a hook vetoed the compaction — ${result.skip}`)
    return true
  }
  $.ui.log('compacted at the agent\'s request')
  await $.prompt.submit({ text: COMPACTED_TEXT })
  return true
}

// Every turn: the status line shows both points and the room; a guard warning is logged once per
// distinct text. Once per fill: when the soft point is reached and nothing has been requested, the
// agent is asked (as a prompt of its own, marked as the mod's) to find a stopping point and run
// compact-me.sh.
async function reportAndNudge($: EngineInterface): Promise<void> {
  const w = await windowOf($)
  if (!w) return
  $.ui.status(statusText(w))
  const { warning } = guard(w)
  if (warning && (await $.store.get(WARNED)) !== warning) { await $.store.set(WARNED, warning); $.ui.log(warning) }
  if (!warning && (await $.store.get(WARNED)) !== undefined) await $.store.delete(WARNED)
  const nudgedAt = await $.store.get(NUDGED_AT)
  const prior = typeof nudgedAt === 'number' ? nudgedAt : undefined
  if (prior !== undefined && w.tokens < prior) await $.store.delete(NUDGED_AT)
  if (!nudgeDue(w, prior)) return
  await $.store.set(NUDGED_AT, w.tokens)
  await $.prompt.submit({ text: nudgeText(w, `${$.plugin.root}/compact-me.sh`) })
}

// After every main-loop turn (a subagent's or fork's turns are passed through untouched): act on a
// request if one is waiting, else report and nudge if the window says so. Errors are logged, never
// thrown into the turn.
export const register: Register = on => {
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    if ((e as { agentId?: string }).agentId !== undefined) return result
    try {
      const path = await ownRequestPath($)
      if (!(await actOnRequest($, path))) await reportAndNudge($)
    } catch (err) {
      $.ui.log(String(err))
    }
    return result
  })
}
