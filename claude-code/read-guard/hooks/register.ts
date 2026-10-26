import type { Register } from 'claude-code'
import { judge } from './guard.ts'

// What each loop has read: the main conversation under 'main', a subagent or teammate under its id.
// A compaction of a loop forgets that loop's set, because the summary that replaces its transcript
// carries no image, so the next read of one is new again. Module state, like waiting-agents' `told`:
// a session is one process and a hot reload starts the module over, which only ever lets one extra
// read through.
type Seen = Map<string, Set<string>>

export const register: Register = on => {
  const seen: Seen = new Map()
  const setFor = (agentId: string | undefined) => {
    const id = agentId ?? 'main'
    let s = seen.get(id)
    if (!s) { s = new Set(); seen.set(id, s) }
    return s
  }

  on('session.start', ($, e, next) => { seen.clear(); return next(e) })

  on('tool.call', { tool: 'Read' }, async ($, e, next) => {
    const stat = await $.fs.stat(e.file_path, { resolve: true }).catch(() => undefined)
    // A path the guard cannot stat (missing, a permission the tool itself will report) is the tool's to answer.
    if (!stat || stat.kind !== 'file') return next(e)
    const loop = setFor(e.agentId)
    const verdict = judge(e, stat.size, loop)
    if ('deny' in verdict) {
      $.ui.log(verdict.deny)
      return { deny: verdict.deny }
    }
    const ran = await next(e)
    // Remember an image only once it was actually read: a deny beneath, or an error, leaves it unseen.
    if (verdict.key !== undefined && ran.deny === undefined && ran.isError !== true) loop.add(verdict.key)
    return ran
  }).catch(($, e, next) => {
    // The guard failing must never cost a read: it exists to save context, not to gate work.
    $.ui.log('read-guard: its guard failed; the read went through')
    return next(e)
  })

  on('session.compact', async ($, e, next) => {
    const result = await next(e)
    if (!('skip' in result && result.skip)) seen.delete(e.agentId ?? 'main')
    return result
  })
}
