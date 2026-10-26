// The pure part of self-compact: where the request and config files live, when a nudge is due, what
// the guard says, and what a request file means. Nothing here touches the engine; register.ts does
// the reading and acting.

// With no COMPACT_AFTER configured, a nudge is due once this fraction of the room remains, or less.
export const NUDGE_AT_REMAINING = 0.20

// The room an agent needs between the nudge and the hard point to finish and save: the guard
// speaks when COMPACT_AFTER plus this would pass where the session actually auto-compacts
// (owner, 2026-10-16: 40k).
export const MIN_FINISH_ROOM = 40_000

// Auto-compact does not fire at the window: it fires this many tokens short of it. Measured on
// 2026-10-16 from compact_boundary entries (compactMetadata.preTokens) in every agent
// transcript on a 300k window: 266.7k–269.3k, so ~33k early; on 250k that is ~217k (confirmed at
// 217,132 the same morning). Used only when the engine's breakdown is not available: with it,
// `hardAt` carries the session's own buffer, read live.
export const AUTO_COMPACT_RESERVE = 33_000

export type Window = {
  /** Input tokens the last response was answered over. */
  tokens: number
  /** The compaction window: `autoCompactWindow` from the merged settings, else the model's window. */
  compactWindow: number
  /**
   * Where THIS session actually auto-compacts, from the engine's breakdown: its settled window
   * (`rawMaxTokens`, which /autocompact or the env may have set, not the settings file) less its
   * buffer row. Absent when the breakdown is not available.
   */
  hardAt?: number
  /** How the session's window was settled, as the breakdown names it (`settings`, `env`, …). */
  hardSource?: string
  /** The soft point: COMPACT_AFTER for this agent, from the config file. Absent = the 20% rule. */
  compactAfter?: number
}

// Where auto-compact fires with no live figure: the settings window less the measured reserve.
export function effectiveWindow(w: Window): number {
  return Math.max(0, w.compactWindow - AUTO_COMPACT_RESERVE)
}

// The hard point: the session's own, when the engine gave it, else the estimate.
export function hardPoint(w: Window): number {
  return w.hardAt !== undefined && w.hardAt > 0 ? w.hardAt : effectiveWindow(w)
}

// The fraction of the room (up to the hard point) still free, 0..1; no room is read as full.
export function remainingFraction(w: Window): number {
  const hard = hardPoint(w)
  if (hard <= 0) return 0
  return Math.max(0, Math.min(1, (hard - w.tokens) / hard))
}

// The compaction window: the merged settings' `autoCompactWindow` when it is a positive number,
// else the model's own window.
export function compactWindowOf(settings: unknown, modelWindow: number): number {
  const v = (settings as { autoCompactWindow?: unknown } | null | undefined)?.autoCompactWindow
  return typeof v === 'number' && v > 0 ? v : modelWindow
}

// Where this session actually auto-compacts, from `$.session.usage({ breakdown })`'s context
// breakdown: the settled window less every `buffer` row. Undefined without a breakdown.
export function hardAtOf(breakdown: unknown): { hardAt: number; source: string } | undefined {
  const b = breakdown as { rawMaxTokens?: unknown; autocompactSource?: unknown; categories?: unknown } | null | undefined
  if (!b || typeof b.rawMaxTokens !== 'number' || b.rawMaxTokens <= 0) return undefined
  const rows = Array.isArray(b.categories) ? b.categories as { kind?: unknown; tokens?: unknown }[] : []
  const buffer = rows.filter(r => r.kind === 'buffer').reduce((n, r) => n + (typeof r.tokens === 'number' ? r.tokens : 0), 0)
  return { hardAt: Math.max(0, b.rawMaxTokens - buffer), source: typeof b.autocompactSource === 'string' ? b.autocompactSource : 'unknown' }
}

type Env = { XDG_STATE_HOME?: string; XDG_CONFIG_HOME?: string; HOME?: string }

// The request file of ONE session: the only file this mod ever reads for a request, and the path
// the nudge tells the agent to write. `<state>/self-compact/<session id>.json`, where state is
// `$XDG_STATE_HOME` or `$HOME/.local/state`. No other session's id is ever put in this path.
export function requestPath(sessionId: string, env: Env): string {
  const state = env.XDG_STATE_HOME || (env.HOME ? `${env.HOME}/.local/state` : undefined)
  if (!state) throw new Error('neither XDG_STATE_HOME nor HOME is set, so the request path cannot be built')
  if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) throw new Error(`session id ${JSON.stringify(sessionId)} is not a plain token`)
  return `${state}/self-compact/${sessionId}.json`
}

// The COMPACT_AFTER file, one per box, read at every turn end so a change needs no restart:
// `<config>/self-compact/compact-after.json`, config being `$XDG_CONFIG_HOME` or `$HOME/.config`.
export function configPath(env: Env): string | undefined {
  const config = env.XDG_CONFIG_HOME || (env.HOME ? `${env.HOME}/.config` : undefined)
  return config ? `${config}/self-compact/compact-after.json` : undefined
}

// The config file's content: `{ "default": <tokens>, "agents": { "<Name>": <tokens> } }`, both
// parts optional. The agent's own entry wins over the default; a file naming neither for this
// agent yields no soft point and the 20% rule applies. Anything malformed is refused with the
// reason, so a garbled file changes nothing.
export function parseCompactAfter(text: string, agentName: string | undefined): { compactAfter: number | undefined } | { refuse: string } {
  let doc: unknown
  try { doc = JSON.parse(text) } catch { return { refuse: 'the COMPACT_AFTER file is not JSON' } }
  if (doc === null || typeof doc !== 'object' || Array.isArray(doc)) return { refuse: 'the COMPACT_AFTER file is not a JSON object' }
  const d = doc as { default?: unknown; agents?: unknown }
  const positive = (v: unknown, what: string): number | undefined | { refuse: string } => {
    if (v === undefined) return undefined
    if (typeof v !== 'number' || !Number.isFinite(v) || v <= 0) return { refuse: `${what} is not a positive number` }
    return v
  }
  if (d.agents !== undefined && (d.agents === null || typeof d.agents !== 'object' || Array.isArray(d.agents))) return { refuse: '"agents" is not an object' }
  const agents = (d.agents ?? {}) as Record<string, unknown>
  const own = agentName !== undefined ? positive(agents[agentName], `"agents"."${agentName}"`) : undefined
  if (typeof own === 'object') return own
  const dflt = positive(d.default, '"default"')
  if (typeof dflt === 'object') return dflt
  return { compactAfter: own ?? dflt }
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

// The soft point: COMPACT_AFTER when configured, else where 20% of the room remains.
export function softPoint(w: Window): number {
  return w.compactAfter ?? Math.ceil(hardPoint(w) * (1 - NUDGE_AT_REMAINING))
}

// Whether a nudge is due: the count is at or past the soft point, and no nudge has gone out since
// the count was last under it (one nudge per fill; a compaction drops the count and re-arms it).
export function nudgeDue(w: Window, nudgedAtTokens: number | undefined): boolean {
  if (w.tokens < softPoint(w)) return false
  return nudgedAtTokens === undefined || w.tokens < nudgedAtTokens
}

const n = (x: number) => Math.round(x).toLocaleString('en-GB')

// The guard: the room between the soft point and the hard point, and a warning when it is under
// MIN_FINISH_ROOM. That is the silent miss made loud: settings raised while a running session kept
// its old window, or a COMPACT_AFTER set too close. `live` says whether the hard point is the
// session's own figure or the estimate.
export function guard(w: Window): { room: number; warning?: string } {
  const room = hardPoint(w) - softPoint(w)
  if (room >= MIN_FINISH_ROOM) return { room }
  const how = w.hardAt !== undefined ? `read from this session (${w.hardSource ?? 'unknown'})` : 'estimated from the settings window'
  return {
    room,
    warning: `only ${n(room)} tokens between the nudge at ${n(softPoint(w))} and auto-compact at ${n(hardPoint(w))} (${how}); ${n(MIN_FINISH_ROOM)} is the minimum. Raise this session's window with /autocompact, or lower COMPACT_AFTER.`,
  }
}

// The status line, every turn: both points and the room, so a drift is visible before it bites.
// No mod-name prefix here or in any ui line: the engine prefixes every status and log line with
// "⚠ <mod name>: " itself, so a prefix of our own showed the name twice (owner, 2026-10-16).
export function statusText(w: Window): string {
  const g = guard(w)
  return `${n(w.tokens)} used, nudge at ${n(softPoint(w))}, auto-compact at ${n(hardPoint(w))}, room ${n(g.room)}${g.warning ? ' ⚠' : ''}`
}

// The nudge, marked as the mod's and not the owner's, naming the one command to run and what the
// compaction instructions must say, so the summary itself points back at the durable record.
export function nudgeText(w: Window, script: string): string {
  const left = Math.max(0, hardPoint(w) - w.tokens)
  return [
    `[self-compact mod, not the owner] ${n(w.tokens)} tokens used; auto-compact fires at about ${n(hardPoint(w))}, so about ${n(left)} remain to finish and save.`,
    'Finish at a natural stopping point and bring your durable record up to date (session entry, row notes, memory) before anything else.',
    `Then run: bash ${script} "<what the summary must keep>" and end your turn: this mod compacts the session between turns, with those instructions, and clears the request. Do not start new work first.`,
    'What the summary must keep names where your record is (the ticket you hold, its row notes, your latest session entry) and the very next action standing in it, so the summary points back at the record.',
  ].join('\n')
}

// The prompt queued in the session once a compaction it asked for has happened, marked as the mod's
// and not the owner's. A compaction is not a turn, so nothing would start one otherwise and the
// session would sit at a prompt; this is what carries the agent on from its record.
export const COMPACTED_TEXT = [
  '[self-compact mod, not the owner] Compacted at your request.',
  'Read your durable record first (the ticket you hold, its row notes and your latest session entry), then carry on with its next action.',
  'If that action is waiting on someone, say what you are waiting for and stop.',
].join('\n')
