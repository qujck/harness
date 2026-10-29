#!/usr/bin/env bash
# team/agents-spend.sh — who spent the week's tokens, agent by agent, read from the transcripts.
#
#   bash team/agents-spend.sh                 # since this week's reset (AGENT_WEEK_RESET in harness.env)
#   bash team/agents-spend.sh --since '2026-10-29 05:00'   # any `date -d` time, local
#   bash team/agents-spend.sh --json
#   bash team/agents-spend.sh --self-test
#
# WHY. The panel's `week N% of M%` says how fast the account is burning and nothing about WHO. On 2026-10-29
# the owner saw the week run away in the first twenty minutes after the reset; the row rows said twelve
# sessions were "working", the budget said 1% — and the answer (one tester making 92 model calls in twenty
# minutes with a 230k-token context, reading 14.6 M cached tokens; one lead sending 24 messages that each
# woke a 150k-token session) was in nobody's view. This is that view.
#
# WHAT IS COUNTED. Every assistant message in a session's transcript (~/.claude/projects/*/<session>.jsonl)
# carries the request's usage: input, output, cache written, cache read. A transcript logs ONE LINE PER
# CONTENT BLOCK and each repeats the same usage, so lines are deduplicated by message.id first — without that
# the figures read about 2.2x high (Rowan, 2026-10-09); a line with NO id is counted as it comes. A subagent's
# transcript sits under <session>/subagents/ and is counted as its parent's spend. "Tokens in" is input + cache written + cache read:
# what the model read for the call, and so what the context size costs on EVERY call. Session → agent comes
# from the context rows (docs/context-publisher.md); a session with no row prints as `?` and its id.
#
# WHAT IS NOT. Dollars or the account's own weighting of cached reads: the week percentage is Anthropic's
# and this cannot reproduce it. Shares are of tokens in, which is the one figure that rises with both
# call count and context size, the two levers an agent actually holds.
#
# Reads CONTEXT_DIR (default ~/.local/state/<project>/context) and TRANSCRIPTS_DIR (default
# ~/.claude/projects). The reset is found in local time with `date`, so a reset that straddles a DST change
# lands an hour off that week; the box runs UTC. Exit: 0 printed · 2 usage, no python3, or no transcripts.
set -uo pipefail
_here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/lib/selftest-flag.sh
. "$_here/../scripts/lib/selftest-flag.sh"
# shellcheck source=../scripts/lib/harness-env.sh
. "$_here/../scripts/lib/harness-env.sh"

# The most recent occurrence of AGENT_WEEK_RESET ("Thu 05:00", local time), as epoch seconds; the empty
# string when it is unset or malformed, and the caller says what it falls back to.
reset_epoch() {
  local r="${AGENT_WEEK_RESET:-}" d h
  [[ "$r" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\ ([0-2][0-9]:[0-5][0-9])$ ]] || { echo ""; return; }
  d="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"
  local now; now="${NOW_S:-$(date +%s)}"
  local e; e="$(date -d "$(date -d "@$now" +%Y-%m-%d) $h" +%s)"
  # walk back to the named weekday, then one more week if that moment is still ahead of now
  while [[ "$(date -d "@$e" +%a)" != "$d" ]]; do e=$((e - 86400)); done
  (( e > now )) && e=$((e - 7 * 86400))
  echo "$e"
}

spend() { # <since-epoch> <json|table>
  command -v python3 >/dev/null 2>&1 || { echo "agents-spend: COULD NOT LOOK — no python3" >&2; return 2; }
  python3 - "$1" "$2" "${CONTEXT_DIR:-$HOME/.local/state/${HARNESS_PROJECT}/context}" "${TRANSCRIPTS_DIR:-$HOME/.claude/projects}" <<'PY'
import sys, os, json, glob, collections, datetime
since, mode, ctx_dir, tr_dir = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
who = {}
for f in glob.glob(os.path.join(ctx_dir, '*.json')):
    try:
        d = json.load(open(f))
        who[d['session_id']] = (d.get('agent') or '?', (d.get('context') or {}).get('used') or 0)
    except Exception:
        pass
agg = {}
files = [(p, os.path.basename(p)[:-6]) for p in glob.glob(os.path.join(tr_dir, '*', '*.jsonl'))]
files += [(p, os.path.basename(os.path.dirname(os.path.dirname(p)))) for p in glob.glob(os.path.join(tr_dir, '*', '*', 'subagents', '*.jsonl'))]
files = [(p, sid) for p, sid in files if os.path.getmtime(p) >= since]
if not files:
    print("agents-spend: no transcript written since %s under %s" % (datetime.datetime.fromtimestamp(since).strftime('%a %H:%M'), tr_dir), file=sys.stderr)
    sys.exit(2)
seen_by = collections.defaultdict(set)
for p, sid in files:
    seen = seen_by[sid]
    with open(p, errors='replace') as fh:
        for line in fh:
            try:
                j = json.loads(line)
            except Exception:
                continue
            m = j.get('message') or {}
            u = m.get('usage') if isinstance(m, dict) else None
            ts = j.get('timestamp')
            if not u or not ts:
                continue
            try:
                t = datetime.datetime.fromisoformat(ts.replace('Z', '+00:00')).timestamp()
            except Exception:
                continue
            if t < since or (m.get('id') and m.get('id') in seen):
                continue
            if m.get('id'):
                seen.add(m.get('id'))
            a = agg.setdefault(sid, collections.Counter())
            a['calls'] += 1
            a['input'] += u.get('input_tokens', 0) or 0
            a['output'] += u.get('output_tokens', 0) or 0
            a['cache_w'] += u.get('cache_creation_input_tokens', 0) or 0
            a['cache_r'] += u.get('cache_read_input_tokens', 0) or 0
rows = []
for sid, a in agg.items():
    name, ctx = who.get(sid, ('?', 0))
    tin = a['input'] + a['cache_w'] + a['cache_r']
    rows.append(dict(agent=name if name != '?' else '?' + sid[:8], session=sid, calls=a['calls'], ctx_now=ctx,
                     tokens_in=tin, per_call=(tin // a['calls']) if a['calls'] else 0, output=a['output'],
                     cache_read=a['cache_r']))
rows.sort(key=lambda r: -r['tokens_in'])
total = sum(r['tokens_in'] for r in rows) or 1
for r in rows:
    r['share_pct'] = round(100.0 * r['tokens_in'] / total, 1)
if mode == 'json':
    print(json.dumps(dict(since=since, rows=rows)))
    sys.exit(0)
print("spend since %s: %d sessions, %d calls, %.1f M tokens in, %.0f k out" % (
    datetime.datetime.fromtimestamp(since).strftime('%a %H:%M'), len(rows), sum(r['calls'] for r in rows),
    total / 1e6, sum(r['output'] for r in rows) / 1e3))
print("%-10s %6s %8s %10s %8s %10s %6s" % ("AGENT", "CALLS", "CTX-NOW", "IN/CALL", "OUT", "TOKENS-IN", "SHARE"))
for r in rows:
    print("%-10s %6d %7dk %9dk %7dk %8.1f M %5.0f%%" % (r['agent'][:10], r['calls'], r['ctx_now'] // 1000,
          r['per_call'] // 1000, r['output'] // 1000, r['tokens_in'] / 1e6, r['share_pct']))
PY
}

self_test() {
  local T; T="$(mktemp -d)"; trap 'rm -rf "$T"' RETURN
  local fails=0
  check() { # <name> <expected-rc> <needle> <output> <rc>
    if [[ "$5" == "$2" && "$4" == *"$3"* ]]; then echo "PASS $1"; else echo "FAIL $1 (rc $5, wanted $2 and '$3'):"; printf '%s\n' "$4" | sed 's/^/    /'; fails=$((fails + 1)); fi
  }
  mkdir -p "$T/ctx" "$T/tr/proj"
  printf '{"agent":"Ed","session_id":"aaaa-1","context":{"used":231361}}\n' > "$T/ctx/aaaa-1.json"
  printf '{"agent":"Carl","session_id":"bbbb-2","context":{"used":150000}}\n' > "$T/ctx/bbbb-2.json"
  line() { # <ts> <id> <in> <out> <cw> <cr>
    printf '{"type":"assistant","timestamp":"%s","message":{"id":"%s","usage":{"input_tokens":%s,"output_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s}}}\n' "$@"
  }
  { line 2026-10-29T06:00:00Z m1 10 100 1000 200000; line 2026-10-29T06:00:00Z m1 10 100 1000 200000   # the same message, twice (two content blocks)
    line 2026-10-29T06:10:00Z m2 10 100 0 230000; line 2026-10-29T04:00:00Z m0 10 9999 0 999999         # m0 is before the reset
    printf 'not json\n{"type":"user","timestamp":"2026-10-29T06:11:00Z","message":{"content":"hi"}}\n'; } > "$T/tr/proj/aaaa-1.jsonl"
  mkdir -p "$T/tr/proj/aaaa-1/subagents"
  line 2026-10-29T06:12:00Z s1 10 100 0 100000 > "$T/tr/proj/aaaa-1/subagents/agent-1.jsonl"   # Ed's subagent: Ed's spend
  { line 2026-10-29T06:05:00Z c1 5 50 0 150000
    line 2026-10-29T06:07:00Z null 5 50 0 10000 | sed 's/"id":"null",//'; line 2026-10-29T06:08:00Z null 5 50 0 10000 | sed 's/"id":"null",//'; } > "$T/tr/proj/bbbb-2.jsonl"   # two lines with no id: two calls
  line 2026-10-29T06:06:00Z z1 5 50 0 50000 > "$T/tr/proj/cccc-3.jsonl"   # no context row: unknown agent
  local since out rc; since="$(date -d '2026-10-29T05:00:00Z' +%s)"
  out="$(CONTEXT_DIR="$T/ctx" TRANSCRIPTS_DIR="$T/tr" spend "$since" table 2>&1)"; rc=$?
  check "two blocks of one message count once, a call before the reset not at all, a subagent's call as its parent's" 0 "Ed              3     231k       177k       0k      0.5 M" "$out" "$rc"
  check "two lines with no id are two calls" 0 "Carl            3     150k        56k       0k      0.2 M" "$out" "$rc"
  check "the header totals the window" 0 "3 sessions, 7 calls, 0.8 M tokens in" "$out" "$rc"
  check "a session with no context row prints as ? and its id" 0 "?cccc-3" "$out" "$rc"
  check "the heaviest agent is first" 0 "$(printf 'SHARE\nEd ')" "$out" "$rc"
  out="$(CONTEXT_DIR="$T/ctx" TRANSCRIPTS_DIR="$T/tr" spend "$since" json 2>&1)"; rc=$?
  check "json carries the same rows" 0 '"agent": "Carl", "session": "bbbb-2", "calls": 3, "ctx_now": 150000, "tokens_in": 170015' "$out" "$rc"
  out="$(CONTEXT_DIR="$T/ctx" TRANSCRIPTS_DIR="$T/none" spend "$since" table 2>&1)"; rc=$?
  check "no transcripts is could-not-look, not an empty table" 2 "no transcript written since" "$out" "$rc"
  out="$(AGENT_WEEK_RESET='Thu 05:00' NOW_S="$(date -d '2026-10-29T06:22:00' +%s)" reset_epoch)"
  check "the reset is the most recent Thursday 05:00" 0 "$(date -d '2026-10-29T05:00:00' +%s)" "$out" 0
  out="$(AGENT_WEEK_RESET='Thu 05:00' NOW_S="$(date -d '2026-10-29T04:59:00' +%s)" reset_epoch)"
  check "a minute before it, the reset is last week's" 0 "$(date -d '2026-10-22T05:00:00' +%s)" "$out" 0
  out="$(AGENT_WEEK_RESET='Thursday' reset_epoch)"
  check "a malformed reset is empty" 0 "" "$out" 0
  [[ "$out" == "" ]] || { echo "FAIL a malformed reset is empty: got '$out'"; fails=$((fails + 1)); }
  (( fails == 0 )) && echo "self-test ok" || echo "self-test failed: $fails"
  return "$(( fails > 0 ))"
}

if selftest_is_flag "${1:-}"; then self_test; exit $?; fi
MODE=table; SINCE=""
while (( $# )); do
  case "$1" in
    --json) MODE=json ;;
    --since) SINCE="$(date -d "${2:-}" +%s 2>/dev/null)" || { echo "agents-spend: --since wants a time date -d reads, not '${2:-}'" >&2; exit 2; }; shift ;;
    *) echo "agents-spend: unknown argument '$1' (usage: agents-spend.sh [--since <when>] [--json] | --self-test)" >&2; exit 2 ;;
  esac
  shift
done
if [[ -z "$SINCE" ]]; then
  SINCE="$(reset_epoch)"
  [[ -n "$SINCE" ]] || { SINCE=$(( $(date +%s) - 86400 )); echo "agents-spend: AGENT_WEEK_RESET not set in harness.env; the last 24 hours" >&2; }
fi
spend "$SINCE" "$MODE"
