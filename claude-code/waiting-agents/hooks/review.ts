// The pure part of the review queue's wakes (team/review-queue.py keeps the queue): which notices addressed to
// this session it has still to deliver, and whether a reviewer sitting idle with requests waiting is due a reminder.
// Every session delivers its own, so the delivery lead is never the go-between.

export type Notice = { id: string; to: string; text: string; at?: number }
export type Request = { id: number; kind: 'code' | 'test'; key: string; by: string; state: string; held?: boolean; taken_by?: string }
export type Queue = { items: Request[]; notices: Notice[] }

// The reviewer's role id on the roster (agents/roster.json) for each kind of request.
export const REVIEWER: Record<'code' | 'test', string> = { code: 'code-reviewer', test: 'test-reviewer' }
// How long a reviewer sits idle with requests waiting before a reminder, and how far apart reminders are.
export const REMIND_S = 900

export function parseQueue(text: string | undefined): Queue {
  try {
    const q = JSON.parse(text ?? '') as Partial<Queue>
    return { items: Array.isArray(q.items) ? q.items : [], notices: Array.isArray(q.notices) ? q.notices : [] }
  } catch { return { items: [], notices: [] } }
}

// The notices for `me` not yet delivered, oldest first, and the delivered ids still in the file (so the store forgets
// those the file has pruned).
export function dueNotices(q: Queue, me: string, delivered: readonly string[]): { due: Notice[]; kept: string[] } {
  const mine = q.notices.filter(n => n && n.to === me && typeof n.id === 'string' && typeof n.text === 'string')
  const was = new Set(delivered)
  return { due: mine.filter(n => !was.has(n.id)), kept: mine.filter(n => was.has(n.id)).map(n => n.id) }
}

// The kind of request `role` reviews, if any.
export function kindOf(role: string): 'code' | 'test' | undefined {
  return (Object.keys(REVIEWER) as ('code' | 'test')[]).find(k => REVIEWER[k] === role)
}

// A reminder for a reviewer idle `idleS` seconds with requests waiting and none in hand, at most one per REMIND_S.
export function reminder(q: Queue, me: string, role: string, idleS: number, sinceLastS: number): string | undefined {
  const kind = kindOf(role)
  if (!kind || idleS < REMIND_S || sinceLastS < REMIND_S) return undefined
  if (q.items.some(i => i.kind === kind && i.state === 'taken' && i.taken_by === me)) return undefined
  const waiting = q.items.filter(i => i.kind === kind && i.state === 'waiting' && !i.held)
  if (waiting.length === 0) return undefined
  return `[review-queue, not the owner] ${waiting.length} request${waiting.length === 1 ? ' is' : 's are'} waiting for you `
    + `(${waiting.map(i => i.key).join(', ')}). Run \`team/review-queue.py take ${kind}\`.`
}
