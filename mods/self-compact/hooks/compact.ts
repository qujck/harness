// The pure part of self-compact: where the request file lives, when a nudge is due, and what a
// request file means. Nothing here touches the engine; register.ts does the reading and acting.

// A nudge is due once this fraction of the EFFECTIVE window remains, or less.
export const NUDGE_AT_REMAINING = 0.20

// Auto-compact does not fire at the window: it fires this many tokens short of it. Measured by
// Alfred on 2026-10-16 from compact_boundary entries (compactMetadata.preTokens) in every agent
// transcript on a 300k window: 266.7k–269.3k, so ~33k early; on 250k that is ~217k. The first
// version measured "remaining" against the nominal window, which on 250k nudged at 200k used and
// left the agent ~17k to finish and save, one large read's worth — the exact case the mod exists
// to prevent. Remaining is now measured against the effective threshold.
export const AUTO_COMPACT_RESERVE = 33_000

export type Window = {
  /** Input tokens the last response was answered over. */
  tokens: number
  /** The compaction window: `autoCompactWindow` from the merged settings, else the model's window. */
  compactWindow: number
}

// Where auto-compact actually fires: the window less the reserve (never under 0).
export function effectiveWindow(w: Window): number {
  return Math.max(0, w.compactWindow - AUTO_COMPACT_RESERVE)
}

// The fraction of the EFFECTIVE window still free, 0..1; an effective window of 0 is read as full.
export function remainingFraction(w: Window): number {
  const eff = effectiveWindow(w)
  if (eff <= 0) return 0
  return Math.max(0, Math.min(1, (eff - w.tokens) / eff))
}

// The compaction window: the merged settings' `autoCompactWindow` when it is a positive number,
// else the model's own window.
export function compactWindowOf(settings: unknown, modelWindow: number): number {
  const v = (settings as { autoCompactWindow?: unknown } | null | undefined)?.autoCompactWindow
  return typeof v === 'number' && v > 0 ? v : modelWindow
}

// The request file of ONE session: the only file this mod ever reads for a request, and the path
// the nudge tells the agent to write. `<state>/self-compact/<session id>.json`, where state is
// `$XDG_STATE_HOME` or `$HOME/.local/state`. No other session's id is ever put in this path.
export function requestPath(sessionId: string, env: { XDG_STATE_HOME?: string; HOME?: string }): string {
  const state = env.XDG_STATE_HOME || (env.HOME ? `${env.HOME}/.local/state` : undefined)
  if (!state) throw new Error('neither XDG_STATE_HOME nor HOME is set, so the request path cannot be built')
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) throw new Error(`session id ${JSON.stringify(sessionId)} is not a plain token`)
  return `${state}/self-compact/${sessionId}.json`
}

export type Request = { instructions?: string }

// A request file's content: `{ "instructions": "..." }` or `{}`; anything else is refused with the
// reason, so a garbled file compacts nothing.
export function parseRequest(text: string): { request: Request } | { refuse: string } {
  let doc: unknown
  try { doc = JSON.parse(text) } catch { return { refuse: 'the request file is not JSON' } }
  if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) return { refuse: 'the request file is not a JSON object' }
  const i = (doc as { instructions?: unknown }).instructions
  if (i !== undefined && typeof i !== 'string') return { refuse: '"instructions" is not a string' }
  return { request: i === undefined ? {} : { instructions: i } }
}

// Whether a nudge is due: the window is at or under the threshold, and no nudge has gone out since
// the count was last under it (one nudge per fill; a compaction drops the count and re-arms it).
export function nudgeDue(w: Window, nudgedAtTokens: number | undefined): boolean {
  if (remainingFraction(w) > NUDGE_AT_REMAINING) return false
  return nudgedAtTokens === undefined || w.tokens < nudgedAtTokens
}

// The nudge, marked as the mod's and not the owner's, carrying the exact path to write.
export function nudgeText(w: Window, path: string): string {
  const pct = Math.round(remainingFraction(w) * 100)
  return [
    `[self-compact mod, not the owner] ${pct}% of your room remains: ${w.tokens.toLocaleString('en-GB')} tokens used, and auto-compact fires at about ${effectiveWindow(w).toLocaleString('en-GB')} (your ${w.compactWindow.toLocaleString('en-GB')}-token window less the ~${AUTO_COMPACT_RESERVE.toLocaleString('en-GB')} it keeps back).`,
    'Finish at a natural stopping point and bring your durable record up to date (session entry, row notes, memory) before anything else.',
    `Then write {"instructions":"<what the summary must keep>"} to ${path} and end your turn: this mod compacts the session between turns, with those instructions, and clears the request. Do not start new work first.`,
  ].join('\n')
}
