#!/usr/bin/env bash
# scripts/check-mods-tests-pass.sh — every mod under claude-code/ passes `claude plugin test`.
# (feat_harness_optional_code_reviewer_and_tester_roles_and_a_waiting_agents_mod)
#
#   bash scripts/check-mods-tests-pass.sh [mods-dir]     # default: claude-code/ beside this repo's scripts/
#   bash scripts/check-mods-tests-pass.sh --self-test
#
# WHY: a mod's tests run only under the Claude Code test runner, which no tier of verify.sh invoked, so
# claude-code/waiting-agents landed with five tests nothing in the pipeline ran. A mod is one directory holding
# `.claude-plugin/plugin.json`; each is tested on its own so the red names the mod.
#
# Verdicts (exit code): 0 every mod green, or no mods dir at all (named, never silent); 1 a mod's tests
# failed; 2 CANNOT LOOK — a mods dir exists but the `claude` CLI is not on PATH, so nothing was tested
# (never a pass: the runner is the instrument, and a missing instrument is not a measured zero).
#
# remedy-arm: performs-the-remedy
#   --self-test plants a throwaway mod with a failing test and sees exit 1 naming it, fixes the test
#   (the remedy the red asks for) and sees exit 0; and an empty tree is exit 0 saying "no mods".
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"

# mods_verdict <mods-dir> -> prints one line per mod; echoes the final verdict on the last line:
#   ok:<n> | no-mods | cannot-look:no-claude-cli | failed:<mod> [<mod>…]
mods_verdict() {
  local dir="$1" m failed=() n=0
  [[ -d "$dir" ]] || { printf 'no-mods\n'; return 0; }
  local mods=()
  for m in "$dir"/*/.claude-plugin/plugin.json; do [[ -f "$m" ]] && mods+=("$(dirname "$(dirname "$m")")"); done
  (( ${#mods[@]} )) || { printf 'no-mods\n'; return 0; }
  command -v claude >/dev/null 2>&1 || { printf 'cannot-look:no-claude-cli\n'; return 0; }
  for m in "${mods[@]}"; do
    if claude plugin test "$m" >/dev/null 2>&1; then printf '  ok    %s\n' "$m"; n=$((n+1))
    else printf '  FAIL  %s  (run: claude plugin test %s)\n' "$m" "$m"; failed+=("$m"); fi
    # A mod's shell helpers (claude-code/<mod>/*.sh) carry their own --self-test, and THIS is what runs it:
    # check-selftests-are-invoked.sh sweeps scripts/ and infra/ only, so a selftest-tiers.txt row for
    # a path under claude-code/ is dead and verify's tier step would never run it (found 2026-10-16 when
    # self-compact/compact-me.sh was added). A red helper fails its mod.
    local h
    for h in "$m"/*.sh; do
      [[ -f "$h" ]] || continue
      if bash "$h" --self-test >/dev/null 2>&1; then printf '  ok    %s --self-test\n' "$h"
      else printf '  FAIL  %s --self-test\n' "$h"; failed+=("$h"); fi
    done
  done
  (( ${#failed[@]} )) && { printf 'failed:%s\n' "${failed[*]}"; return 0; }
  printf 'ok:%s\n' "$n"
}

if selftest_is_flag "${1:-}"; then
  f=0
  _t() { local what="$1" want="$2" got="$3"; if [[ "$got" == "$want" ]]; then echo "  ok    $what"; else echo "  FAIL  $what: wanted '$want', got '$got'"; f=1; fi; }
  t="$(mktemp -d)" || exit 2
  trap 'rm -rf "$t"' EXIT
  _t "no mods dir is 'no-mods', not a silent pass"  no-mods "$(mods_verdict "$t/none" | tail -1)"
  mkdir -p "$t/empty/not-a-mod"
  _t "a mods dir with no plugin.json is 'no-mods'"  no-mods "$(mods_verdict "$t/empty" | tail -1)"
  if command -v claude >/dev/null 2>&1; then
    mkdir -p "$t/mods/planted/.claude-plugin" "$t/mods/planted/hooks"
    printf '{ "name": "planted", "version": "0.0.1", "description": "self-test fixture" }\n' > "$t/mods/planted/.claude-plugin/plugin.json"
    printf '{ "modules": ["./register.ts"] }\n' > "$t/mods/planted/hooks/hooks.json"
    printf "import type { Register } from 'claude-code'\nexport const register: Register = () => {}\n" > "$t/mods/planted/hooks/register.ts"
    printf "import { expect, test } from 'claude-code/testing'\ntest('planted red', () => { expect(1).toBe(2) })\n" > "$t/mods/planted/hooks/planted.test.ts"
    _t "a mod with a failing test is named as failed"  "failed:$t/mods/planted" "$(mods_verdict "$t/mods" | tail -1)"
    # the remedy: fix the test
    printf "import { expect, test } from 'claude-code/testing'\ntest('planted green', () => { expect(1).toBe(1) })\n" > "$t/mods/planted/hooks/planted.test.ts"
    _t "the same mod passes once its test is fixed"  "ok:1" "$(mods_verdict "$t/mods" | tail -1)"
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == --self-test ]] && exit 1\n' > "$t/mods/planted/helper.sh"
    _t "a mod whose shell helper's --self-test is red is named as failed"  "failed:$t/mods/planted/helper.sh" "$(mods_verdict "$t/mods" | tail -1)"
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == --self-test ]] && exit 0\n' > "$t/mods/planted/helper.sh"
    _t "the same mod passes once its helper is green"  "ok:1" "$(mods_verdict "$t/mods" | tail -1)"
  else
    mkdir -p "$t/mods/x/.claude-plugin"; echo '{}' > "$t/mods/x/.claude-plugin/plugin.json"
    _t "no claude CLI with a mod present is CANNOT LOOK"  cannot-look:no-claude-cli "$(mods_verdict "$t/mods" | tail -1)"
    echo "  skipped  the planted-red arms need the claude CLI (not on PATH) — said, not silently passed"
  fi
  (( f == 0 )) && echo "check-mods-tests-pass: self-test ok" || echo "check-mods-tests-pass: self-test FAILURES"
  exit "$f"
fi

case "${1:-}" in --*) echo "check-mods-tests-pass: unknown flag ${1} (only --self-test, or a mods directory)" >&2; exit 2 ;; esac
(( $# <= 1 )) || { echo "check-mods-tests-pass: one argument at most (a mods directory)" >&2; exit 2; }
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="$(mods_verdict "${1:-$ROOT/claude-code}")"
printf '%s\n' "$out" | sed '$d'
case "$(printf '%s\n' "$out" | tail -1)" in
  ok:*)     echo "check-mods-tests-pass: ${out##*ok:} mod(s) green"; exit 0 ;;
  no-mods)  echo "check-mods-tests-pass: no mods to test (claude-code/ holds no .claude-plugin/plugin.json)"; exit 0 ;;
  failed:*) echo "check-mods-tests-pass: FAILED — ${out##*failed:}" >&2; exit 1 ;;
  *)        echo "check-mods-tests-pass: CANNOT LOOK — mods exist but the claude CLI is not on PATH; nothing was tested" >&2; exit 2 ;;
esac
