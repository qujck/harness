#!/usr/bin/env bash
# scripts/check-steps-invoke-their-scripts.sh — a verify step that NAMES a script must INVOKE it for real.
# (feat_harness_self_tests_follow_one_flag_contract_and_a_tier_manifest_that_verify_runs)
#
#   bash scripts/check-steps-invoke-their-scripts.sh              # scripts/verify.sh
#   bash scripts/check-steps-invoke-their-scripts.sh --self-test
#
# The seeded project's lesson (fix_the_progress_freeze_gate_let_four_progress_files_onto_main_after_the_cutover):
# verify.sh had `step "… — scripts/check-no-new-progress-files.sh"` and, beneath it, ONLY
# `bash scripts/check-no-new-progress-files.sh --self-test`. The arms were green every day; the gate
# itself never ran; four files it existed to refuse reached main. A check that is only self-tested is
# not a check. So: for every `step "… — scripts/<x>.sh"` promise, the lines until the next `step`
# must invoke scripts/<x>.sh at least once WITHOUT a self-test flag. Comments are stripped first.
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# broken_promises <verify.sh path> -> one line per step whose named script is only ever self-tested beneath it (pure)
broken_promises() {
  python3 - "$1" <<'PY'
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
lines = [re.sub(r'(^|\s)#.*$', '', l) for l in text.split('\n')]   # comments stripped
steps = [(i, l) for i, l in enumerate(lines) if re.match(r'^\s*step\s+"', l)]
bad = []
for n, (i, l) in enumerate(steps):
    m = re.search(r'—\s*(scripts/[A-Za-z0-9_./-]+\.(?:sh|py))', l)
    if not m: continue
    script = m.group(1)
    end = steps[n + 1][0] if n + 1 < len(steps) else len(lines)
    body = lines[i + 1:end]
    real = [b for b in body if script in b and not re.search(r'--self-?test\b|--selftest\b', b)]
    any_ = [b for b in body if script in b]
    if any_ and not real:
        bad.append(f'{script}: the step at line {i + 1} promises it, but beneath it only a self-test flag runs it')
print('\n'.join(bad))
PY
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  f=0; d="$(mktemp -d)"
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; f=1; fi; }
  printf 'step "gate — scripts/check-x.sh"\nbash scripts/check-x.sh --self-test || fail x\nstep "next"\n' > "$d/v1.sh"
  _t "NEGATIVE CONTROL: a promised script run only with --self-test is a broken promise, named" \
     "scripts/check-x.sh: the step at line 1 promises it, but beneath it only a self-test flag runs it" "$(broken_promises "$d/v1.sh")"
  printf 'step "gate — scripts/check-x.sh"\nbash scripts/check-x.sh --self-test || fail x\nbash scripts/check-x.sh || fail y\nstep "next"\n' > "$d/v2.sh"
  _t "POSITIVE CONTROL: the same step with a real invocation keeps its promise" "" "$(broken_promises "$d/v2.sh")"
  printf 'step "gate — scripts/check-x.sh"\n# bash scripts/check-x.sh   (a comment is not an invocation)\nbash scripts/check-x.sh --selftest\n' > "$d/v3.sh"
  _t "a commented-out invocation does not count" \
     "scripts/check-x.sh: the step at line 1 promises it, but beneath it only a self-test flag runs it" "$(broken_promises "$d/v3.sh")"
  printf 'step "prose only, no script named"\nbash scripts/other.sh --self-test\n' > "$d/v4.sh"
  _t "a step that names no script makes no promise" "" "$(broken_promises "$d/v4.sh")"
  _t "the shipped verify.sh keeps every promise" "" "$(broken_promises "$ROOT/scripts/verify.sh")"
  rm -rf "$d"
  (( f == 0 )) && echo "check-steps-invoke-their-scripts: self-test ok" || { echo "check-steps-invoke-their-scripts: self-test FAILED" >&2; exit 1; }
  exit 0
fi
out="$(broken_promises "$ROOT/scripts/verify.sh")"
if [[ -n "$out" ]]; then printf 'check-steps-invoke-their-scripts: FAIL — a step promises a gate it only self-tests:\n%s\n' "$out" | sed '2,$s/^/  /' >&2; exit 1; fi
echo "check-steps-invoke-their-scripts: ok — every step that names a script invokes it for real"
