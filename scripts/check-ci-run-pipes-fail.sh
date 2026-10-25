#!/usr/bin/env bash
# scripts/check-ci-run-pipes-fail.sh — a workflow `run:` line that PIPES its command must carry pipefail.
#
#   bash scripts/check-ci-run-pipes-fail.sh              # .github/workflows/*.yml
#   bash scripts/check-ci-run-pipes-fail.sh --self-test
#
# WHY. GitHub runs a `run:` step with `bash -e {0}`: -e, no pipefail. So `bash scripts/verify.sh 2>&1 | tee log`
# exits with tee's 0 whatever verify said. On 2026-10-25 harness #48 landed with its self-test tier RED: run
# 40236249744 printed "FAIL self-test failed: scripts/agents-budget.sh" inside the verify step and the job,
# the required check and the landing were all green. main was red until #49. The gate that was in the log
# was not in the exit code.
#
# THE RULE. In every tracked .github/workflows/*.yml, a `run:` whose command (one line, or a `run: |` block)
# contains an unquoted `|` pipe must, in the same step, either set pipefail (`set -o pipefail`, `set -eo
# pipefail`, `set -uo pipefail` …) BEFORE the piped line, or declare `shell: bash` (whose default is
# `bash --noprofile --norc -eo pipefail {0}`). A `||` is not a pipe. `|` inside quotes is not a pipe
# (a grep alternation, an awk program). Comments (`#` to end of line, outside quotes) are stripped first.
# Failing output names file:line and the offending command; exit 1. Exit 2 when it COULD NOT LOOK (no
# workflows dir, no python3).
#
# CHECK_CI_ROOT is the seam: the repository root to read (default: this one).
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
ROOT="${CHECK_CI_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# unprotected_pipes <root> -> one line per piped run line with no pipefail in scope (pure, reads files)
unprotected_pipes() {
  python3 - "$1" <<'PY'
import glob, os, re, sys
root = sys.argv[1]

def strip_comment(line):
    out, q = [], None
    for ch in line:
        if q:
            out.append(ch)
            if ch == q: q = None
        elif ch in ('"', "'"): q = ch; out.append(ch)
        elif ch == '#': break
        else: out.append(ch)
    return ''.join(out)

def has_pipe(line):
    q = None; i = 0; s = strip_comment(line)
    while i < len(s):
        ch = s[i]
        if q:
            if ch == q: q = None
        elif ch in ('"', "'"): q = ch
        elif ch == '|':
            if i + 1 < len(s) and s[i + 1] == '|': i += 1          # `||` is not a pipe
            else: return True
        i += 1
    return False

PIPEFAIL = re.compile(r'\bset\s+-[a-zA-Z]*o\s+pipefail\b|\bset\s+-o\s+pipefail\b|\bset\s+-[a-zA-Z]*\s+-o\s+pipefail\b')
bad = []
for f in sorted(glob.glob(os.path.join(root, '.github', 'workflows', '*.yml')) + glob.glob(os.path.join(root, '.github', 'workflows', '*.yaml'))):
    lines = open(f, encoding='utf-8').read().split('\n')
    rel = os.path.relpath(f, root)
    i = 0
    # a step starts at `- ` under steps:; we track per-step: shell, run lines (with numbers)
    steps = []  # list of dicts: {'shell':..., 'run':[(lineno, text)], 'start': n}
    cur = None
    for n, raw in enumerate(lines, 1):
        s = raw.rstrip('\n')
        ind = len(s) - len(s.lstrip(' '))
        st = s.strip()
        if re.match(r'^-\s+(name|uses|run|if|id|env|with|shell|working-directory|continue-on-error|timeout-minutes):', st):
            cur = {'shell': None, 'run': [], 'start': n, 'ind': ind}; steps.append(cur)
            st = re.sub(r'^-\s+', '', st); ind += 2
        if cur is None: continue
        m = re.match(r'^shell:\s*(\S+)', st)
        if m and ind == cur['ind'] + 2: cur['shell'] = m.group(1)
        m = re.match(r'^run:\s*(.*)$', st)
        if m and ind == cur['ind'] + 2:
            body = m.group(1)
            if body in ('|', '|-', '>', '>-', ''):
                j = n
                while j < len(lines):
                    nxt = lines[j]
                    if nxt.strip() == '': j += 1; continue
                    nind = len(nxt) - len(nxt.lstrip(' '))
                    if nind <= ind: break
                    cur['run'].append((j + 1, nxt.strip())); j += 1
            else:
                cur['run'].append((n, body))
    for stp in steps:
        if stp['shell'] == 'bash': continue           # GitHub's `shell: bash` is -eo pipefail
        armed = False
        for ln, text in stp['run']:
            t = strip_comment(text)
            if PIPEFAIL.search(t): armed = True
            if has_pipe(t) and not armed:
                bad.append(f'{rel}:{ln}: a piped run line without pipefail: {t.strip()}')
print('\n'.join(bad))
PY
}

selftest_reject_typo "${1:-}"
if selftest_is_flag "${1:-}"; then
  [[ $# -eq 1 ]] || { printf 'unknown argument: %s\nusage: check-ci-run-pipes-fail.sh [--self-test]\n' "$2" >&2; exit 2; }
  T="$(mktemp -d)" || exit 2; trap 'rm -rf "$T"' EXIT
  fails=0
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n       want %q\n       got  %q\n' "$1" "$3" "$2"; fails=$((fails+1)); fi; }
  mk() { mkdir -p "$T/$1/.github/workflows"; cat > "$T/$1/.github/workflows/ci.yml"; }
  mk bare <<'Y'
jobs:
  verify:
    steps:
      - name: The gate
        run: bash scripts/verify.sh 2>&1 | tee "$RUNNER_TEMP/verify-output.log"
Y
  _t "the defect: a tee'd verify with no pipefail is named, file:line" "$(unprotected_pipes "$T/bare")" \
     '.github/workflows/ci.yml:5: a piped run line without pipefail: bash scripts/verify.sh 2>&1 | tee "$RUNNER_TEMP/verify-output.log"'
  mk inline <<'Y'
jobs:
  verify:
    steps:
      - name: The gate
        run: set -o pipefail; bash scripts/verify.sh 2>&1 | tee log
      - name: Also
        run: set -euo pipefail; bash x | tee -a log
Y
  _t "set -o pipefail on the line, and set -euo pipefail, are both armed" "$(unprotected_pipes "$T/inline")" ''
  mk block <<'Y'
jobs:
  verify:
    steps:
      - name: The gate
        run: |
          set -uo pipefail
          bash scripts/verify.sh 2>&1 | tee log
      - name: Too late
        run: |
          bash scripts/verify.sh 2>&1 | tee log
          set -o pipefail
Y
  _t "a block sets it before the pipe: ok; after the pipe: not" "$(unprotected_pipes "$T/block")" \
     '.github/workflows/ci.yml:10: a piped run line without pipefail: bash scripts/verify.sh 2>&1 | tee log'
  mk shellbash <<'Y'
jobs:
  verify:
    steps:
      - name: The gate
        shell: bash
        run: bash scripts/verify.sh 2>&1 | tee log
Y
  _t "shell: bash is GitHub's -eo pipefail" "$(unprotected_pipes "$T/shellbash")" ''
  mk notpipes <<'Y'
jobs:
  verify:
    steps:
      - name: Not pipes
        run: |
          bash a.sh || echo "fell back"
          grep -E 'x|y' file && awk '$1 ~ /a|b/' file
          echo "a | b"   # a pipe in a comment | too
          bash scripts/verify.sh
Y
  _t "|| , a quoted |, a | in a comment are not pipes" "$(unprotected_pipes "$T/notpipes")" ''
  mk two <<'Y'
jobs:
  a:
    steps:
      - run: set -o pipefail; bash x | tee log
      - run: bash y | tee log
Y
  _t "pipefail in one step does not arm the next" "$(unprotected_pipes "$T/two")" \
     '.github/workflows/ci.yml:5: a piped run line without pipefail: bash y | tee log'
  _t "the real workflows are clean" "$(CHECK_CI_ROOT="$ROOT" bash "$0" >/dev/null 2>&1; echo $?)" 0
  mkdir -p "$T/none"
  _t "no workflows dir: could not look, rc 2" "$(CHECK_CI_ROOT="$T/none" bash "$0" >/dev/null 2>&1; echo $?)" 2
  # remedy arm: the defect fixture, with pipefail added as the fix would, is clean
  sed -i 's|        run: bash scripts/verify.sh|        run: set -o pipefail; bash scripts/verify.sh|' "$T/bare/.github/workflows/ci.yml"
  _t "the remedy (set -o pipefail; before the pipe) clears the defect" "$(unprotected_pipes "$T/bare")" ''
  if (( fails == 0 )); then echo "check-ci-run-pipes-fail: self-test ok"; exit 0; fi
  echo "check-ci-run-pipes-fail: self-test FAILED ($fails)"; exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "check-ci-run-pipes-fail: COULD NOT LOOK — no python3" >&2; exit 2; }
[[ -d "$ROOT/.github/workflows" ]] || { echo "check-ci-run-pipes-fail: COULD NOT LOOK — no .github/workflows under $ROOT" >&2; exit 2; }
out="$(unprotected_pipes "$ROOT")"
if [[ -z "$out" ]]; then
  echo "check-ci-run-pipes-fail: ok — every piped run line in .github/workflows carries pipefail (or shell: bash)"; exit 0
fi
echo "check-ci-run-pipes-fail: FAIL — a run: step pipes its command without pipefail, so the step exits with the LAST command's status and a red gate lands:" >&2
printf '  %s\n' $'' >&2; printf '%s\n' "$out" | sed 's/^/  /' >&2
echo "  Fix: put \`set -o pipefail;\` at the start of that run line (or \`shell: bash\` on the step)." >&2
exit 1
