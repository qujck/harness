#!/usr/bin/env bash
# scripts/check-docs-markers-match-landed-children.sh — a doc that says a mechanism "arrives with"
# a child must stop saying so once that child has landed.
# (feat_harness_agents_md_and_method_md_teach_the_current_process_and_the_four_role_documents_are_added)
#
#   bash scripts/check-docs-markers-match-landed-children.sh              # check
#   bash scripts/check-docs-markers-match-landed-children.sh --self-test  # drive both directions
#
# ── WHY ─────────────────────────────────────────────────────────────────────────────────────────
# The docs were rewritten to the target process before the mechanisms existed, so each section that
# depends on a later child says "(arrives with `<child-id>`)". That marker is honest on the day it
# is written and wrong on the day the child lands — and a doc that keeps describing a mechanism as
# future after it shipped is the exact drift this template was refreshed to remove. So the marker
# is a CLAIM the build checks: every `<child-id>` named in a marker must be ABSENT from
# docs/landed-children.txt, and the child's own PR adds its id there and deletes its markers.
#
# ── THE FLAG CONTRACT ───────────────────────────────────────────────────────────────────────────
# Either spelling of the self-test flag is accepted and any other argument is refused with exit 2,
# so a mistyped flag can never fall through to the real check and exit 0. The shared library that
# supplies this (scripts/lib/selftest-flag.sh) arrives with the self-test child; this script carries
# the same two lines inline until then and switches to the library when it lands.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANDED="${LANDED_CHILDREN_FILE:-$ROOT/docs/landed-children.txt}"
DOCS_DEFAULT=("$ROOT/AGENTS.md" "$ROOT/README.md" "$ROOT/docs")

# the shared flag contract (scripts/lib/selftest-flag.sh): a mistyped flag exits 2, never falls through
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"
if selftest_is_flag "${1-}"; then SELFTEST=1
elif [[ -n "${1-}" ]]; then echo "check-docs-markers-match-landed-children: unknown argument '$1' (usage: [--self-test])" >&2; exit 2; fi

# markers_in <file-or-dir>… -> one "file<TAB>line<TAB>child-id" per marker. A marker may wrap across a
# line break between "arrives with" and the backticked id (prose is wrapped at ~100 columns), so the
# extraction reads whole files, not lines — a line-based grep found 1 of 6 on the first run.
markers_in() {
  python3 - "$@" <<'PYX'
import os, re, sys
pat = re.compile(r'arrives? with\s+`([a-z0-9_]+)`', re.I)
files = []
for a in sys.argv[1:]:
    if os.path.isdir(a):
        for d, _, fs in os.walk(a):
            files += [os.path.join(d, f) for f in fs if f.endswith(('.md', '.txt'))]
    elif os.path.isfile(a): files.append(a)
for f in sorted(files):
    try: s = open(f, encoding='utf-8', errors='replace').read()
    except OSError: continue
    for m in pat.finditer(s):
        print(f"{f}\t{s.count(chr(10), 0, m.start()) + 1}\t{m.group(1)}")
PYX
}
# landed_ids <file> -> ids, comments and blanks stripped
landed_ids() { [[ -f "$1" ]] || return 0; sed -E 's/#.*//' "$1" | awk 'NF{print $1}'; }

# check <landed-file> <doc>… -> prints each stale marker; returns 1 if any
check() {
  local landed="$1"; shift; local rc=0 m id f ln
  while IFS=$'\t' read -r f ln id; do
    [[ -n "${id:-}" ]] || continue
    if landed_ids "$landed" | grep -qxF -- "$id"; then
      printf '%s:%s: says "%s" arrives later, but docs/landed-children.txt lists it as LANDED — delete the marker and describe the mechanism as present\n' "$f" "$ln" "$id"; rc=1
    fi
  done < <(markers_in "$@")
  return $rc
}

if [[ "${SELFTEST:-0}" == 1 ]]; then
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT; fails=0
  printf 'The roster (arrives with `feat_x_roster`) is the register.\nJira (arrives with `feat_y_jira`).\n' > "$t/a.md"
  printf '# landed\nfeat_x_roster\n' > "$t/landed.txt"
  _arm() { local d="$1" want="$2"; shift 2; local got; check "$@" >/dev/null && got=0 || got=1
           if [[ "$got" == "$want" ]]; then printf '  ok    %s\n' "$d"; else printf '  FAIL  %s (want %s got %s)\n' "$d" "$want" "$got"; fails=1; fi; }
  _arm "a marker for a LANDED child is refused"                1 "$t/landed.txt" "$t/a.md"
  printf '# landed\n' > "$t/none.txt"
  _arm "markers for unlanded children pass"                    0 "$t/none.txt" "$t/a.md"
  _arm "a missing landed file means nothing has landed: pass"  0 "$t/absent.txt" "$t/a.md"
  printf 'Nothing arrives later here.\n' > "$t/b.md"
  _arm "a doc with no marker passes"                           0 "$t/landed.txt" "$t/b.md"
  out="$(check "$t/landed.txt" "$t/a.md")" || true
  if grep -q 'a.md:1: says "feat_x_roster" arrives later' <<<"$out"; then printf '  ok    the refusal names file:line and the child\n'; else printf '  FAIL  refusal text: %s\n' "$out"; fails=1; fi
  # POSITIVE CONTROL on the real docs: the markers the template ships today all name ids that exist in
  # the epic (a typo in a marker would never be caught by the landed list)
  n="$(markers_in "${DOCS_DEFAULT[@]}" | wc -l)"
  if (( n > 0 )); then printf '  ok    the real docs carry %s marker(s) for the check to govern\n' "$n"; else printf '  FAIL  no markers found in the real docs — the check would pass vacuously\n'; fails=1; fi
  (( fails == 0 )) && { echo "check-docs-markers-match-landed-children: self-test ok"; exit 0; }
  echo "check-docs-markers-match-landed-children: self-test FAILED"; exit 1
fi

if check "$LANDED" "${DOCS_DEFAULT[@]}"; then
  echo "check-docs-markers-match-landed-children: ok — no doc describes a landed child as still to come ($(markers_in "${DOCS_DEFAULT[@]}" | wc -l) marker(s) outstanding)"
else
  echo "check-docs-markers-match-landed-children: FAILED"; exit 1
fi
