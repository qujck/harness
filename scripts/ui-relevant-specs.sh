#!/usr/bin/env bash
# scripts/ui-relevant-specs.sh — changed paths (stdin) -> a Playwright --grep ERE, or __ALL__.
# (feat_harness_ci_routes_a_pr_by_diff_runs_a_test_subset_and_gates_merges_on_the_hourly_full_suite)
#
#   git diff --name-only main...HEAD | bash scripts/ui-relevant-specs.sh             # the ERE, or __ALL__
#   git diff --name-only main...HEAD | bash scripts/ui-relevant-specs.sh --surface   # the paths that decide a browser run
#   bash scripts/ui-relevant-specs.sh --self-test
#
# The map is scripts/ui-map.txt (its header states the two properties). Config, from harness.env:
#   UI_BROWSER_SURFACE_RE   ERE of the paths that can affect the browser at all (default: frontend/, e2e-ui/).
#                           A diff with NO surface path selects NOTHING (prints nothing, exit 0): the
#                           browser step is skipped — a backend-only or docs-only PR runs no browser test.
#   UI_SPEC_DIR             where the spec files live (fragments are checked against their names)
#   UI_ALWAYS_SPECS         fragment(s) always included when anything is selected (property 2)
#
# ⚠ EVERY PATH THAT CANNOT PRODUCE A REAL SELECTION EMITS __ALL__, NEVER AN EMPTY GREP: no map file,
# a surface path with no row, a fragment that matches no spec on disk (a renamed spec would otherwise
# silently select nothing). The seeded project's by-content resolver and generated map are NOT ported:
# this is the path-row contract alone, which is what a new project starts with.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"; REPO_ROOT="$(cd "$HERE/.." && pwd)"
. "$HERE/lib/selftest-flag.sh"
. "$HERE/lib/harness-env.sh"
MAP="${UI_MAP:-$REPO_ROOT/scripts/ui-map.txt}"
SPEC_DIR="${UI_SPEC_DIR:-$REPO_ROOT/e2e-ui/tests}"
ALWAYS_SPECS="${UI_ALWAYS_SPECS-}"
BROWSER_SURFACE_RE="${UI_BROWSER_SURFACE_RE:-^(frontend/|e2e-ui/)}"

# selection_verdict <unmapped 0|1> <n fragments> -> all | subset   (pure)
selection_verdict() {
  local unmapped="${1-1}" n="${2-0}"
  [[ "$unmapped" =~ ^[01]$ && "$n" =~ ^[0-9]+$ ]] || { printf 'all\n'; return 0; }
  (( unmapped == 1 )) && { printf 'all\n'; return 0; }
  (( n > 0 )) && { printf 'subset\n'; return 0; }
  printf 'all\n'
}
# browser_surface: stdin paths -> the ones that decide a browser run   (pure over the RE)
browser_surface() { awk -v re="$BROWSER_SURFACE_RE" '$0 ~ re' ; }
# map_rows: the map without comments/blanks, as "regex<TAB>fragments"
map_rows() { [[ -r "$MAP" ]] && awk -F'\t' '!/^[[:space:]]*#/ && NF>=2 {print $1 "\t" $2}' "$MAP"; }
# fragments_for <path> -> the union of fragments of every row the path matches; "" when unmapped
fragments_for() { local p="$1"; map_rows | awk -F'\t' -v p="$p" 'p ~ $1 {print $2}' | tr '|' '\n' | awk 'NF' | sort -u; }
# fragment_has_spec <fragment> -> 0 when some spec file name contains it
fragment_has_spec() { [[ -d "$SPEC_DIR" ]] && find "$SPEC_DIR" -type f -name "*${1}*" 2>/dev/null | head -1 | awk 'END{exit NR==0}'; }

select_ere() { # stdin: changed paths -> stdout: ERE | __ALL__ | "" (nothing to run)
  local paths surface p f unmapped=0 frags=""
  paths="$(cat)"; surface="$(printf '%s\n' "$paths" | browser_surface)"
  [[ -n "$surface" ]] || { echo "ui-relevant-specs: no browser-surface path in the diff — no browser test selected" >&2; return 0; }
  [[ -r "$MAP" ]] || { echo "ui-relevant-specs: no map at $MAP — running EVERYTHING" >&2; printf '__ALL__\n'; return 0; }
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    f="$(fragments_for "$p")"
    if [[ -z "$f" ]]; then unmapped=1; echo "ui-relevant-specs: $p has no map row — running EVERYTHING" >&2; continue; fi
    # a row's fragments are ALTERNATIVE names; the row is live when at least one names a spec on disk.
    # A row whose fragments name NO spec (every spec renamed) must not select nothing: everything runs.
    local live=0; for fr in $f; do fragment_has_spec "$fr" && { live=1; break; }; done
    if (( live == 0 )); then echo "ui-relevant-specs: the row(s) for $p name no spec under $SPEC_DIR ($(paste -sd'|' <<<"$f")) — running EVERYTHING (a renamed spec must not select nothing)" >&2; printf '__ALL__\n'; return 0; fi
    frags="$frags"$'\n'"$f"
  done <<<"$surface"
  frags="$(printf '%s\n' "$frags" | awk 'NF' | sort -u)"
  local n; n="$(printf '%s\n' "$frags" | awk 'NF' | wc -l)"
  if [[ "$(selection_verdict "$unmapped" "$n")" == all ]]; then printf '__ALL__\n'; return 0; fi
  [[ -n "$ALWAYS_SPECS" ]] && frags="$frags"$'\n'"$(tr '|' '\n' <<<"$ALWAYS_SPECS")"
  local ere; ere="$(printf '%s\n' "$frags" | awk 'NF' | sort -u | paste -sd'|')"
  echo "ui-relevant-specs: $n fragment(s) selected${ALWAYS_SPECS:+ (always: $ALWAYS_SPECS)}" >&2
  printf '%s\n' "$ere"
}

if selftest_is_flag "${1:-}"; then
  fails=0; d="$(mktemp -d)"
  _t() { if [[ "$2" == "$3" ]]; then printf '  ok    %s\n' "$1"; else printf '  FAIL  %s (want %q got %q)\n' "$1" "$2" "$3"; fails=1; fi; }
  mkdir -p "$d/specs"; : > "$d/specs/login.spec.js"; : > "$d/specs/nav.spec.js"; : > "$d/specs/smoke.spec.js"
  printf '# example\n^frontend/src/pages/login/\tlogin|sign-in\n^frontend/src/components/nav/\tnav|header\n^frontend/src/renamed/\tgone\n' > "$d/map.txt"
  run() { UI_MAP="$d/map.txt" UI_SPEC_DIR="$d/specs" UI_ALWAYS_SPECS="${ALWAYS-}" UI_BROWSER_SURFACE_RE='^(frontend/|e2e-ui/)' bash "${BASH_SOURCE[0]}" 2>/dev/null; }
  _t "pure: unmapped -> all"                      all    "$(selection_verdict 1 3)"
  _t "pure: mapped with fragments -> subset"      subset "$(selection_verdict 0 2)"
  _t "pure: mapped with zero fragments -> all"    all    "$(selection_verdict 0 0)"
  _t "pure: garbage -> all (never an empty grep)" all    "$(selection_verdict x y)"
  _t "a mapped page selects exactly its row's fragments (alternatives kept)" "login|sign-in" "$(printf 'frontend/src/pages/login/Form.tsx\n' | run)"
  _t "two mapped paths union their fragments"     "header|login|nav|sign-in" "$(printf 'frontend/src/pages/login/a.tsx\nfrontend/src/components/nav/b.tsx\n' | run)"
  _t "an unmapped SURFACE path runs everything"   __ALL__ "$(printf 'frontend/src/pages/unmapped/x.tsx\n' | run)"
  _t "a mapped path beside an unmapped one still runs everything" __ALL__ "$(printf 'frontend/src/pages/login/a.tsx\nfrontend/src/pages/unmapped/x.tsx\n' | run)"
  _t "docs-only / backend-only diff selects NOTHING (no browser run)" "" "$(printf 'docs/x.md\nbackend/src/y.cs\n' | run)"
  _t "a fragment matching no spec on disk runs everything (a renamed spec)" __ALL__ "$(printf 'frontend/src/renamed/a.tsx\n' | run)"
  _t "no map file at all runs everything"         __ALL__ "$(printf 'frontend/src/pages/login/a.tsx\n' | UI_MAP="$d/none.txt" UI_SPEC_DIR="$d/specs" bash "${BASH_SOURCE[0]}" 2>/dev/null)"
  _t "the always-specs are added to every real selection" "login|sign-in|smoke" "$(printf 'frontend/src/pages/login/a.tsx\n' | ALWAYS=smoke run)"
  _t "--surface prints only the browser-deciding paths" "frontend/src/a.tsx" "$(printf 'docs/x.md\nfrontend/src/a.tsx\n' | UI_BROWSER_SURFACE_RE='^frontend/' bash "${BASH_SOURCE[0]}" --surface)"
  _t "the shipped example map parses to rows"     4 "$(UI_MAP="$REPO_ROOT/scripts/ui-map.txt" bash -c '. "'"$HERE"'/lib/harness-env.sh"; MAP="'"$REPO_ROOT"'/scripts/ui-map.txt"; '"$(declare -f map_rows)"'; map_rows | wc -l')"
  rm -rf "$d"
  (( fails == 0 )) && echo "ui-relevant-specs: self-test ok" || { echo "ui-relevant-specs: self-test FAILED" >&2; exit 1; }
  exit 0
fi
if [[ "${1:-}" == --surface ]]; then browser_surface; exit 0; fi
select_ere
