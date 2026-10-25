#!/usr/bin/env bash
# scripts/check-tooling-hints-never-say-closes.sh — no tracked shell script PRINTS a closing keyword before an issue number.
# (backported from strength's fix_feature_ticket_tells_the_author_to_write_closes_in_the_pr_body_which_shuts_the_issue_over_a_live_row, 2026-10-25)
# remedy-arm: reworded — the self-test rewrites the named line to `Part of #` and asserts the gate is clean.
#
# WHY. A PR body says `Part of #N`, never `Closes #N` (docs/ledger-spec.md §7a): completion is the row writes AFTER the
# merge (flip-passing → archive → release), so a closing keyword shuts the issue at merge over a row that is still live.
# In strength the ticket tool itself printed "PR body: Closes #N" at the moment the author was writing the body: the tool
# taught the forbidden form, with authority. This gate keeps every printed hint in this repository saying `Part of`.
#
# THE QUESTION is narrow on purpose: does a line that PRINTS (echo / printf at the start of the statement) carry a
# present-tense closing keyword — Close(s), Fix(es), Resolve(s), any case — followed by `#` and a number or a placeholder
# ($var, %s, <n>, {n}, N)? Those are the forms an author copies. Not judged, because they are not hints: comments, test
# fixtures fed to a parser ("$(printf 'Closes #1' | parser)" does not start the statement), and past-tense reports such as
# `echo "closed #$n"`. A hint written inside a heredoc is not seen; none exists today (grep, 2026-10-23).
#
# Usage:  bash scripts/check-tooling-hints-never-say-closes.sh [--self-test]
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh" || { echo "FATAL: cannot load selftest-flag.sh, so no self-test here can run" >&2; exit 2; }
SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
cd "$(dirname "${BASH_SOURCE[0]}")/.." || { echo "check-tooling-hints-never-say-closes: cannot cd to the repo root — nothing was checked" >&2; exit 2; }
# The repo the real run judges. Only the self-test points it elsewhere, to drive the real FAIL path.
ROOT="${CLOSES_HINT_ROOT:-.}"
HINT_RE='^[[:space:]]*(echo|printf)\b.*\b([Cc][Ll][Oo][Ss][Ee][Ss]?|[Ff][Ii][Xx]([Ee][Ss])?|[Rr][Ee][Ss][Oo][Ll][Vv][Ee][Ss]?)\b:?[[:space:]]+#(\$|%|<|\{|[0-9]|N\b|n\b)'

if selftest_requested "$@"; then
  fails=0
  ok()  { echo "  ok   $1"; }
  bad() { echo "  FAIL $1"; fails=$((fails + 1)); }
  T="$(mktemp -d)" || { echo "check-tooling-hints-never-say-closes: cannot make a temp dir — self-test not run" >&2; exit 2; }
  trap 'rm -rf "$T"' EXIT
  # run_on <repo> -> OUT, ERR, RC from the SCRIPT itself, never an inner function
  run_on() { CLOSES_HINT_ROOT="$1" bash "$SELF" </dev/null >"$T/out" 2>"$T/err"; RC=$?; OUT="$(cat "$T/out")"; ERR="$(cat "$T/err")"; }
  repo() { rm -rf "$T/r"; mkdir -p "$T/r/scripts/lib" && git -C "$T/r" init -q; }
  add()  { git -C "$T/r" add -- "$@"; }

  # The #11144 shapes, each on its own: printf with %s, echo with $var, a lower-case `fixes`, `Resolves <n>`.
  for line in "printf '  PR body: Closes #%s\\n' \"\$n\"" 'echo "    Closes #$num"' 'echo "fixes #$ISSUE"' "printf 'Resolves #<n>\\n'"; do
    repo
    printf '%s\n' '#!/usr/bin/env bash' "$line" > "$T/r/scripts/hint.sh"; add scripts/hint.sh
    run_on "$T/r"
    [[ "$RC" == 1 && "$OUT" == *"scripts/hint.sh:2:"* && "$ERR" == *FAIL* ]] \
      && ok "closing-hint: [$line] is rc 1, named file:line, the summary on stderr" \
      || bad "closing-hint: [$line] gave rc $RC; out: ${OUT:0:200}; err: ${ERR:0:200}"
  done

  # Not hints: Part of, a comment, a parser fixture, a past-tense report.
  repo
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf "  PR body: Part of #%s\n" "$n"' \
    '# a PR body used to say Closes #N here' \
    '_expect "x" "$(printf '"'"'Closes #5691\n'"'"' | parser)" ""' \
    'echo "closed #$ISSUE"' > "$T/r/scripts/fine.sh"
  add scripts/fine.sh
  run_on "$T/r"
  [[ "$RC" == 0 && "$OUT" == *"1 tracked shell scripts"* ]] \
    && ok "not-hints: Part of, a comment, a parser fixture and a past-tense report are all clean (rc 0)" \
    || bad "not-hints: rc $RC; out: ${OUT:0:300}"

  # The printed remedy, performed: reword the named line to Part of and re-run.
  repo
  # The fixture text sits in a variable so this file's own line does not start with printf + a closing keyword;
  # the FILE written still carries it, and the first run must be red before the reword can mean anything.
  hint_line='echo "    Closes #$num"'
  printf '%s\n' '#!/usr/bin/env bash' "$hint_line" > "$T/r/scripts/hint.sh"; add scripts/hint.sh
  run_on "$T/r"
  [[ "$RC" == 1 && "$OUT" == *"scripts/hint.sh:2:"* ]] && ok "reworded: before the reword the line is rc 1, named" \
    || bad "reworded: before the reword gave rc $RC; out: ${OUT:0:200}"
  sed -i 's/Closes #/Part of #/' "$T/r/scripts/hint.sh"
  run_on "$T/r"
  [[ "$RC" == 0 ]] && ok "reworded: the same line saying Part of is clean" || bad "reworded: rc $RC; out: ${OUT:0:200}"

  # Cannot look: no tracked shell script, or not a repository, is rc 2 — never "ok on 0".
  repo
  run_on "$T/r"
  [[ "$RC" == 2 && "$ERR" == *"COULD NOT LOOK"* ]] && ok "could-not-look: an empty repo is rc 2" \
    || bad "could-not-look: an empty repo gave rc $RC; out: ${OUT:0:200}"
  mkdir -p "$T/notrepo"; run_on "$T/notrepo"
  [[ "$RC" == 2 && "$ERR" == *"COULD NOT LOOK"* ]] && ok "could-not-look: a non-repo is rc 2" \
    || bad "could-not-look: a non-repo gave rc $RC; err: ${ERR:0:200}"

  if (( fails )); then echo "check-tooling-hints-never-say-closes: self-test FAILED ($fails)"; exit 1; fi
  echo "check-tooling-hints-never-say-closes: self-test ok"
  exit 0
fi

command -v git >/dev/null || { echo "check-tooling-hints-never-say-closes: COULD NOT LOOK — git is missing" >&2; exit 2; }
list="$(mktemp)" && hits="$(mktemp)" || { echo "check-tooling-hints-never-say-closes: COULD NOT LOOK — cannot make a temp file" >&2; exit 2; }
trap 'rm -f "$list" "$hits"' EXIT
git -C "$ROOT" ls-files -z -- '*.sh' 'scripts/git-hooks/*' > "$list" 2>/dev/null \
  || { echo "check-tooling-hints-never-say-closes: COULD NOT LOOK — git ls-files failed in $ROOT" >&2; exit 2; }

n=0
while IFS= read -r -d '' rel; do
  f="$ROOT/$rel"
  [[ -f "$f" && ! -L "$f" ]] || continue
  n=$((n + 1))
  grep -nE -- "$HINT_RE" "$f" </dev/null | sed "s|^|  $rel:|" >> "$hits"
done < "$list"

if (( n == 0 )); then
  echo "check-tooling-hints-never-say-closes: COULD NOT LOOK — no tracked shell script found in $ROOT, so nothing was judged" >&2
  exit 2
fi
if [[ -s "$hits" ]]; then
  cat "$hits"
  printf 'check-tooling-hints-never-say-closes: FAIL — %d printed hint(s) above tell the author to write a closing keyword. A PR body says Part of #N; the issue closes at release, after the merge and the row writes.\n' "$(wc -l < "$hits")" >&2
  exit 1
fi
echo "check-tooling-hints-never-say-closes: ok — no printed hint in $n tracked shell scripts carries a closing keyword before an issue number"
