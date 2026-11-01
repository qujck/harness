// The pure part of the nudger: which team agents have been idle long enough to wake the delivery lead
// (or, in verification time, the head of testing) for, and whether this state has already been nudged
// as often as it may be.
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
// The roles the nudger reports, by their roster ids, whoever is told. The delivery lead is never
// reported; the head of testing defines what is true rather than working a ticket; assistants are not
// on the team.
export const NUDGE_ROLES: readonly string[] = ['developer', 'tester', 'code-reviewer', 'process-improvement']

// Who the idle-team nudge goes to, from the one word in the `nudge-target` file beside the pause file.
// The owner, 2026-10-31: "I'd like the nudger changed to either be nudging you or Vera or be off. No one
// else." `lead` nudges the delivery lead (development time), `testing` the head of testing (verification
// time), `off` nobody. No file, or an empty one, is `lead`, as before the switch; any other word is no
// target at all, and the delivery lead's status line says so, since a typo that silently picked a mode
// would look exactly like that mode working.
export type NudgeTarget = 'lead' | 'testing' | 'off'

export function parseTarget(text: string | undefined): NudgeTarget | { bad: string } {
  const word = (text ?? '').trim()
  if (word === '') return 'lead'
  return word === 'lead' || word === 'testing' || word === 'off' ? word : { bad: word }
}

// The nudged role as the log and the message say it.
export const TARGET_ROLE: Record<'lead' | 'testing', string> = { lead: 'delivery lead', testing: 'head of testing' }

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

// The main checkout a linked worktree belongs to, from the one-line `.git` FILE git leaves in the
// worktree (`gitdir: /path/to/project/.git/worktrees/<name>`); undefined for a main checkout, where
// `.git` is a directory and there is no such text.
export function mainCheckoutOf(gitFile: string | undefined): string | undefined {
  const m = (gitFile ?? '').match(/^\s*gitdir:\s*(.+?)\/\.git\/worktrees\/[^/\s]+\/?\s*$/m)
  return m?.[1]
}

// Where the publisher writes the rows and where the nudger logs, from the same settings the harness
// scripts read: `CONTEXT_DIR`, else `~/.local/state/<HARNESS_PROJECT>/context` with the project
// defaulting to the checkout's directory name. The log sits beside the context directory.
//
// ⚠ The checkout is the MAIN one, not the session's worktree. The delivery lead works in a linked
// worktree named after themself (AGENTS.md rule 0: `../<project>-<you>`), so the session root's
// basename is `acme-carl` while the publisher writes under `acme`. The first version took
// the root's basename, found no rows, and logged "hold: no team agent idle" on every tick, in a log
// directory that did not exist either (review, 2026-10-16). `gitFile` is the text of
// `<root>/.git` when the root is a linked worktree.
export function statePaths(
  home: string,
  root: string,
  vars: { CONTEXT_DIR?: string; HARNESS_PROJECT?: string },
  envFile: string | undefined,
  gitFile?: string,
): { contextDir: string; log: string } {
  const checkout = mainCheckoutOf(gitFile) ?? root
  const project = vars.HARNESS_PROJECT ?? envFileValue(envFile, 'HARNESS_PROJECT') ?? checkout.slice(checkout.lastIndexOf('/') + 1)
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

// The prompt itself names the idle agents and nothing more: each role and idle time stays in the log
// (`describe`), since every word here is spent again by the nudged session (owner, 2026-10-31: "It's a
// waste of tokens to nudge everyone when you're keeping them busy"). With nothing to do, the lead ends the turn
// silently: Vera answered both nudges on 2026-11-01 with a paragraph saying nothing had changed (owner: "Only write
// something if it's useful").
export function nudgeText(count: number, idle: readonly Idle[], thresholdS: number, target: 'lead' | 'testing' = 'lead'): string {
  return `[Automated nudge ${count} of ${MAX_NUDGES} from the waiting-agents mod, not from the owner; it assigns nothing.] `
    + `Team agents idle for ${Math.floor(thresholdS / 60)} minutes or more: ${idle.map(i => i.name).join(', ')}. `
    + `As ${TARGET_ROLE[target]}, check each one and keep the team active. If nothing needs doing, end your turn without writing anything.`
}

// The development day's trip. agents-day-budget.sh `status` says `day  over` once the day has spent more than its
// share, and the runbook pauses the team then; but the delivery lead heard of it only by asking, and on 2026-11-01 the
// team developed on past 16 of 15 (owner: "We're missing the signal"). So the lead's session asks every minute and,
// the first time a day reads over, queues one prompt and hands the nudger to the head of testing; when the next
// development day opens it hands it back. `day` is the day's start (the first field of the budget's state file),
// so each day trips once, a restart included. The lead hands the shift to the head of testing without asking: the
// owner, the same evening, "I can't approve starting every verification day"; and the shift rule (owner, 2026-10-31)
// has the head of testing run the verification day while the lead is benched. The pause is counted by session
// entries, not replies: three agents paused that evening but answered in their own panes.
export type DayTrip = { day: string; switched: boolean }

export type DayVerdict = { alert: boolean; target?: 'lead' | 'testing'; store?: DayTrip }

export function dayVerdict(statusLine: string, day: string | undefined, prev: DayTrip | undefined, target: NudgeTarget | { bad: string }): DayVerdict {
  if (!day) return { alert: false }
  if (statusLine.startsWith('day  over')) {
    if (prev?.day === day) return { alert: false }
    // Only `lead` is moved: `off`, or a word set by hand, is the owner's and stays.
    const move = target === 'lead'
    return { alert: true, target: move ? 'testing' : undefined, store: { day, switched: move } }
  }
  if (statusLine.startsWith('day  on') && prev?.switched && prev.day !== day && target === 'testing') {
    return { alert: false, target: 'lead', store: { day: prev.day, switched: false } }
  }
  return { alert: false }
}

export function dayTripText(statusLine: string): string {
  return '[Automated alert from the waiting-agents mod, not from the owner.] The development day is over: '
    + `${statusLine.replace(/^day  over: /, '').replace(/: write your durable record and pause$/, '')}. `
    + 'As delivery lead, pause the team now (docs/runbooks/development-and-verification-days.md §3): tell every live agent '
    + 'to write its durable record, pause where it stands and reply to you with SendMessage; count the pause by their '
    + 'session entries (bash scripts/progress.sh list), not by replies; armed PRs stay armed. Then hand the shift to the '
    + 'head of testing without asking the owner (docs/roles/delivery-lead.md, the shift handover): write your session '
    + 'entry and run bash scripts/agent-spawn.sh spawn head-of-testing --name <Name>. They start the verification day '
    + 'and bench you. The nudger now nudges the head of testing.'
}
