// The pure part of the nudger: which team agents have been idle long enough to wake the delivery lead
// for, and whether this state has already been nudged as often as it may be.
//
// An agent runs one turn per prompt and then stops; nothing inside its session restarts it. The
// nudger tells the delivery lead, who decides what each one should do. It never talks to the idle
// agents and it assigns nothing. The owner, 2026-10-02: "I only want you to have a nudger so you
// ensure the team remain active".

export const DEFAULT_THRESHOLD_S = 900
// A context row older than this says nothing about what the agent is doing now.
export const STALE_S = 120
// At most this many nudges for one state (the same agents idle).
export const MAX_NUDGES = 2

// One row of the context directory (docs/context-publisher.md), published by each session's status line.
export type ContextRow = { agent?: string; ts?: string; activity?: string; idle_s?: number | null }

export type Idle = { name: string; role: string; idleS: number }

// What has been sent for the current state: the state's key, how many nudges, and when the last went.
export type NudgeState = { key: string; count: number; lastMs: number }

// The value of `KEY=value` in harness.env, which scripts/lib/harness-env.sh sources: an optional
// `export`, quotes around the value and a trailing comment are allowed; an empty value is no value.
export function envFileValue(text: string | undefined, key: string): string | undefined {
  for (const line of (text ?? '').split('\n')) {
    const m = line.match(new RegExp(`^\\s*(?:export\\s+)?${key}=(.*)$`))
    if (!m) continue
    let value = m[1]!.trim()
    const quoted = value.match(/^"([^"]*)"|^'([^']*)'/)
    value = quoted ? (quoted[1] ?? quoted[2] ?? '') : value.replace(/(^|\s+)#.*$/, '').trim()
    return value === '' ? undefined : value
  }
  return undefined
}

// Where the publisher writes the rows and where the nudger logs, from the same settings the harness
// scripts read: `CONTEXT_DIR`, else `~/.local/state/<HARNESS_PROJECT>/context` with the project
// defaulting to the checkout's directory name. The log sits beside the context directory.
export function statePaths(
  home: string,
  root: string,
  vars: { CONTEXT_DIR?: string; HARNESS_PROJECT?: string },
  envFile: string | undefined,
): { contextDir: string; log: string } {
  const project = vars.HARNESS_PROJECT ?? envFileValue(envFile, 'HARNESS_PROJECT') ?? root.slice(root.lastIndexOf('/') + 1)
  const contextDir = vars.CONTEXT_DIR ?? envFileValue(envFile, 'CONTEXT_DIR') ?? `${home}/.local/state/${project}/context`
  return { contextDir, log: `${contextDir.slice(0, contextDir.lastIndexOf('/'))}/lead-nudge.log` }
}

// The freshest row per agent, leaving out rows older than STALE_S.
export function freshRows(rows: readonly ContextRow[], nowMs: number): Map<string, ContextRow & { ageS: number }> {
  const best = new Map<string, ContextRow & { ageS: number }>()
  for (const row of rows) {
    if (!row.agent) continue
    const ts = Date.parse(row.ts ?? '')
    if (Number.isNaN(ts)) continue
    const ageS = (nowMs - ts) / 1000
    if (ageS > STALE_S) continue
    const held = best.get(row.agent)
    if (!held || ageS < held.ageS) best.set(row.agent, { ...row, ageS })
  }
  return best
}

// The role id of agents/roster.json as the message says it: `head-of-testing` reads "head of testing".
export function roleWords(role: string): string {
  return role.replace(/-/g, ' ')
}

// The team agents (name to role) idle for `thresholdS` or more, in roster order.
export function idleAgents(team: ReadonlyMap<string, string>, rows: ReadonlyMap<string, ContextRow>, thresholdS: number): Idle[] {
  const idle: Idle[] = []
  for (const [name, role] of team) {
    const row = rows.get(name)
    if (row?.activity !== 'idle' || (row.idle_s ?? 0) < thresholdS) continue
    idle.push({ name, role, idleS: Math.floor(row.idle_s ?? 0) })
  }
  return idle
}

// The state a nudge is about: the same agents idle is the same state, however long they stay idle.
export function stateKey(idle: readonly Idle[]): string {
  return idle.map(i => i.name).sort().join('\n')
}

export function describe(idle: readonly Idle[]): string {
  return idle.map(i => `${i.name}, ${roleWords(i.role)} idle ${Math.floor(i.idleS / 60)}m`).join('; ')
}

// Whether a nudge may go now: a new state may always be nudged; the same state at most MAX_NUDGES
// times, a full threshold apart. A bound, not a cadence: no amount of time produces a third.
export function decide(
  key: string,
  prev: NudgeState | undefined,
  nowMs: number,
  thresholdS: number,
): { send: true; count: number } | { send: false; why: string } {
  const sent = prev?.key === key ? prev : undefined
  if (!sent) return { send: true, count: 1 }
  if (sent.count >= MAX_NUDGES) return { send: false, why: `already nudged ${MAX_NUDGES} times for this exact state` }
  if (nowMs - sent.lastMs < thresholdS * 1000) return { send: false, why: `${thresholdS}s not yet passed since nudge ${sent.count} for this state` }
  return { send: true, count: sent.count + 1 }
}

export function nudgeText(count: number, idle: readonly Idle[], thresholdS: number): string {
  return `[Automated nudge ${count} of ${MAX_NUDGES} from the waiting-agents mod, not from the owner; it assigns nothing.] `
    + `Team agents idle for ${Math.floor(thresholdS / 60)} minutes or more: ${describe(idle)}. `
    + 'As delivery lead, check each one and keep the team active.'
}
