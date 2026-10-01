#!/usr/bin/env bash
# scripts/check-context-is-never-a-reason-to-do-less.sh — no document in this repo may cite context as a
# reason to stop, defer, narrow scope or hand work to "someone with more context".
# (feat_harness_a_machine_wide_agent_stack_cap_and_each_agents_context_published_for_the_others)
#
#   bash scripts/check-context-is-never-a-reason-to-do-less.sh              # AGENTS.md, README.md, docs/
#   bash scripts/check-context-is-never-a-reason-to-do-less.sh --self-test
#
# The owner's rule (2026-09-28, verbatim in AGENTS.md): "at no point should it be used as a reason to
# not do more work — this would be a disaster". Context is a fact you can read — the publisher writes
# it, agent-context.sh shows it — and the ONLY uses are: write the durable record before a compaction,
# hand a wide read to a subagent, prefer the agent with room when routing, answer "how much have you
# got left" with the number. The sentence that must never appear is the one that makes a low number an
# ending. This check greps for its shapes; the rule's own statement of them is exempt (it is inside the
# AGENTS.md rule and quotes the forbidden phrases to forbid them).
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# forbidden_lines <file> -> the offending lines (empty = clean). Pure over the file's text.
# A line carrying the exemption marker `(forbidden phrase, quoted here to forbid it)` is skipped.
forbidden_lines() {
  awk 'BEGIN{IGNORECASE=1}
       /forbidden phrase, quoted here to forbid it/ {next}
       /leav(e|ing) (this|it|the rest) (for|to) (someone|an agent|somebody) with more context/ ||
       /(context|window) is (too )?low,? so (I|we)('"'"'ll| will| should)? (stop|defer|skip|leave|narrow)/ ||
       /not enough context (left )?to (finish|continue|do)/ ||
       /(stop|defer|narrow|skip)[a-z]* .* (because|since|as) (my |the )?(context|window) (is|was) (low|nearly full|almost full)/ ||
       /(low|little) context (left )?(so|therefore|hence) .* (stop|defer|skip|narrow|later)/ {print FILENAME ":" FNR ": " $0}' "$1" 2>/dev/null
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  fails=0; d="$(mktemp -d)"
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; fails=1; fi; }
  printf 'I am leaving this for someone with more context.\n' > "$d/a.md"
  _t "NEGATIVE CONTROL: 'leaving this for someone with more context' is refused" 1 "$(forbidden_lines "$d/a.md" | awk 'END{print NR}')"
  printf 'My context is low so I will stop here and defer the rest.\n' > "$d/b.md"
  _t "'context is low so I will stop' is refused" 1 "$(forbidden_lines "$d/b.md" | awk 'END{print NR}')"
  printf 'There is not enough context left to finish the migration.\n' > "$d/c.md"
  _t "'not enough context left to finish' is refused" 1 "$(forbidden_lines "$d/c.md" | awk 'END{print NR}')"
  printf 'Context is a fact you can read: write the durable record before a compaction and carry on.\n' > "$d/ok.md"
  _t "POSITIVE CONTROL: the rule itself, stated the right way round, is clean" 0 "$(forbidden_lines "$d/ok.md" | awk 'END{print NR}')"
  printf 'Never say "leaving this for someone with more context" (forbidden phrase, quoted here to forbid it).\n' > "$d/q.md"
  _t "a quoted phrase with the exemption marker is clean" 0 "$(forbidden_lines "$d/q.md" | awk 'END{print NR}')"
  rm -rf "$d"
  (( fails == 0 )) && echo "check-context-is-never-a-reason-to-do-less: self-test ok" || { echo "check-context-is-never-a-reason-to-do-less: self-test FAILED" >&2; exit 1; }
  exit 0
fi
hits=0
while IFS= read -r f; do out="$(forbidden_lines "$f")"; [[ -n "$out" ]] && { printf '%s\n' "$out"; hits=$((hits+1)); }; done < <(find "$ROOT/AGENTS.md" "$ROOT/README.md" "$ROOT/docs" -name '*.md' 2>/dev/null)
if (( hits )); then echo "check-context-is-never-a-reason-to-do-less: FAIL — a document cites context as a reason to do less (the owner, 2026-09-28: a disaster)" >&2; exit 1; fi
echo "check-context-is-never-a-reason-to-do-less: ok — no document makes a low number an ending"
