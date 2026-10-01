#!/usr/bin/env bash
# check-no-new-progress-files.sh — progress/ and PROGRESS.md are FROZEN HISTORY: a change may not add
# or modify a session-entry file there. A session entry is a ledger row (migration 190), written by
# `bash scripts/progress.sh new "<title>" --body-file <file>`, and never a commit.
# (infra_session_entries_live_in_the_ledger_database_and_the_progress_directory_is_frozen_history, pt3)
#
# WHY: an entry describes what happened, so it is written at the END of a session, after the PR is
# open, and every entry commit restarted that PR's verify. Measured over origin/main since
# 2026-09-27: 37 of 40 progress-only commits landed after their PR was opened.
#
# ⚠ IT REFUSES NEW FILES, NOT APPENDS (PO, 2026-09-28). Agents keep long-running records by appending to
# an existing file, and that stays allowed. The comparison is by PATH: a file already on main carries a
# pre-freeze stamp, so modifying it is grandfathered. Pinned by an arm that appends to one.
#
# ⚠ THE FREEZE HAS A GRANDFATHER, AND IT IS NOT A LOOPHOLE. When this merges, every OPEN PR (anyone's)
# that already carries an entry file would go red, because CI tests each PR merged with current main.
# That would mean dozens of reds for work that followed the rule of its day. So a file whose filename
# stamp is BEFORE $FREEZE_AT passes, and is NAMED as grandfathered. One stamped at or after it, or one
# with no stamp in the name, is refused. The window closes on its own: after FREEZE_AT no new stamp can
# be earlier than it.
#
# remedy-arm: performs-the-remedy
#   The refusal prints: take the file out of the diff and write the entry as a row. `--self-test`
#   plants a refused file in a throwaway repo, performs that remedy (git rm the file, write nothing
#   under progress/), and sees the same check pass.
set -uo pipefail
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/selftest-flag.sh"

# UTC, in the filename stamp's own shape (YYYY-MM-DD-HHMM), so the comparison is a plain string compare.
FREEZE_AT="${NO_NEW_PROGRESS_FREEZE_AT:-2026-09-30-0000}"

# progress_file_verdict <status A|M|R|C|D…> <path> <freeze> -> ok | grandfathered | refused:<why>
progress_file_verdict() {
  local st="$1" p="$2" freeze="$3" b stamp
  case "$st" in D*) printf 'ok\n'; return 0 ;; esac          # removing history is not writing it
  case "$p" in
    PROGRESS.md) printf 'refused:PROGRESS.md is frozen history\n'; return 0 ;;
    progress/*) ;;
    *) printf 'ok\n'; return 0 ;;
  esac
  b="${p#progress/}"
  stamp="${b:0:15}"
  if [[ "$b" == */* || ! "$stamp" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}$ ]]; then
    printf 'refused:not a dated session-entry file, and progress/ takes no new shapes\n'; return 0
  fi
  if [[ "$stamp" < "$freeze" ]]; then printf 'grandfathered\n'; else printf 'refused:stamped %s, at or after the freeze (%s)\n' "$stamp" "$freeze"; fi
}

# check_diff <repo> <base> -> prints findings; returns 1 if anything is refused
check_diff() {
  local repo="$1" base="$2" st p v bad=0 gf=0 lines
  lines="$(git -C "$repo" diff --name-status --no-renames "$base"...HEAD -- PROGRESS.md progress/ 2>/dev/null)" || return 2
  while IFS=$'\t' read -r st p; do
    [[ -n "$st" && -n "$p" ]] || continue
    v="$(progress_file_verdict "$st" "$p" "$FREEZE_AT")"
    case "$v" in
      refused:*) printf '  \033[1;31mREFUSED\033[0m %s %s — %s\n' "$st" "$p" "${v#refused:}"; bad=1 ;;
      grandfathered) printf '  grandfathered %s (stamped before the %s freeze)\n' "$p" "$FREEZE_AT"; gf=$((gf+1)) ;;
    esac
  done <<<"$lines"
  return "$bad"
}

remedy() {
  printf '\nA session entry is a LEDGER ROW now, never a commit. Take the file out of this diff:\n'
  printf '    git rm --cached <file>      (or git restore --staged, then delete it)\n'
  printf 'and write the entry as a row instead:\n'
  printf '    bash scripts/progress.sh new "<title>" --body-file <the file>\n'
}

if selftest_requested "$@"; then
  f=0; n=0
  _v() { n=$((n+1)); local got; got="$(progress_file_verdict "$2" "$3" 2026-09-30-0000)"
    if [[ "$got" == "$1"* ]]; then printf '  ok   %s\n' "$4"; else printf '  FAIL %s — got %s\n' "$4" "$got"; f=1; fi; }
  _v refused       A progress/2026-09-30-0000-ed-x.md       "a file stamped AT the freeze is refused"
  _v refused       A progress/2026-10-02-0915-ed-x.md       "a file stamped after the freeze is refused"
  _v refused       M progress/2026-10-02-0915-ed-x.md       "…and MODIFYING one is refused too"
  _v grandfathered A progress/2026-09-28-1911-ed-x.md       "a file stamped before the freeze is grandfathered (an in-flight PR stays green)"
  _v grandfathered M progress/2026-09-18-1245-carl-long-record.md "APPENDING to an existing record passes — the gate refuses NEW files, not appends (PO)"
  _v refused       A progress/notes.md                      "an undated file is refused — progress/ takes no new shapes"
  _v refused       A progress/sub/2026-09-28-1911-ed-x.md   "a nested path is refused"
  _v refused       M PROGRESS.md                            "PROGRESS.md is frozen"
  _v ok            D progress/2026-10-02-0915-ed-x.md       "deleting is not writing"
  _v ok            A docs/progress/notes.md                 "a path merely CONTAINING progress/ is not the directory"

  # ── END TO END in a throwaway repo, with the POSITIVE CONTROL, then the REMEDY PERFORMED ──────────
  t="$(mktemp -d)" || exit 2
  trap 'rm -rf "$t"' EXIT
  ( unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
    g=(-c user.email=t@example.invalid -c user.name=t)
    git -C "$t" init -q -b main && mkdir -p "$t/progress" \
      && echo old > "$t/progress/2026-09-01-0000-old.md" && git -C "$t" add -A && git -C "$t" "${g[@]}" commit -q -m base \
      && git -C "$t" checkout -q -b work ) || { echo "  FAIL could not build the throwaway repo — NOT a pass"; exit 1; }
  base="$(git -C "$t" rev-parse main)"
  ( cd "$t" && echo x > docs.md && git add docs.md && git -c user.email=t@e.invalid -c user.name=t commit -q -m docs )
  n=$((n+1)); if check_diff "$t" "$base" >/dev/null; then echo "  ok   e2e: a diff with no entry file passes"; else echo "  FAIL e2e: a clean diff was refused"; f=1; fi
  ( cd "$t" && echo e > progress/2026-10-02-0915-ed-new.md && git add progress && git -c user.email=t@e.invalid -c user.name=t commit -q -m entry )
  n=$((n+1)); out="$(check_diff "$t" "$base")"; rc=$?
  if [[ "$rc" == 1 && "$out" == *REFUSED*2026-10-02-0915-ed-new.md* ]]; then echo "  ok   POSITIVE CONTROL: a new entry file in the diff is REFUSED, and named"
  else echo "  FAIL POSITIVE CONTROL: rc=$rc — a new entry file was not refused: $out"; f=1; fi
  # performs-the-remedy: take it out of the diff (the entry would be written as a row instead)
  ( cd "$t" && git rm -q progress/2026-10-02-0915-ed-new.md && git -c user.email=t@e.invalid -c user.name=t commit -q -m 'entry is a row now' )
  n=$((n+1)); if check_diff "$t" "$base" >/dev/null; then echo "  ok   performs-the-remedy: with the file taken out of the diff, the same check passes"
  else echo "  FAIL performs-the-remedy: still refused after the printed remedy"; f=1; fi
  # ⚠ THE APPEND CASE, PINNED (PO, 2026-09-28): several agents keep a long-running record by appending
  # to their existing file. Comparison is by PATH (the filename stamp), so an existing file is always
  # pre-freeze and an append always passes. Driven, not reasoned: append to the base's file.
  ( cd "$t" && echo 'appended line' >> progress/2026-09-01-0000-old.md && git add progress && git -c user.email=t@e.invalid -c user.name=t commit -q -m append )
  n=$((n+1)); out="$(check_diff "$t" "$base")"; rc=$?
  if [[ "$rc" == 0 && "$out" == *grandfathered*2026-09-01-0000-old.md* ]]; then echo "  ok   e2e: APPENDING to an existing record passes (named grandfathered), it is not a new file"
  else echo "  FAIL e2e: an append to an existing record was refused rc=$rc: $out"; f=1; fi
  ( cd "$t" && echo g > progress/2026-09-28-1911-ed-inflight.md && git add progress && git -c user.email=t@e.invalid -c user.name=t commit -q -m inflight )
  n=$((n+1)); out="$(check_diff "$t" "$base")"; rc=$?
  if [[ "$rc" == 0 && "$out" == *grandfathered*inflight* ]]; then echo "  ok   e2e: an in-flight entry stamped before the freeze passes, NAMED as grandfathered"
  else echo "  FAIL e2e: an in-flight pre-freeze entry rc=$rc: $out"; f=1; fi
  (( f == 0 )) && echo "check-no-new-progress-files: self-test ok — $n assertions" || echo "check-no-new-progress-files: self-test FAILED"
  exit "$f"
fi

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_PREFIX
base="$(git merge-base origin/main HEAD 2>/dev/null)" \
  || { echo "check-no-new-progress-files: CANNOT LOOK — no merge-base with origin/main (fetch it)" >&2; exit 2; }
out="$(check_diff . "$base")"; rc=$?
[[ -n "$out" ]] && printf '%s\n' "$out"
case "$rc" in
  0) echo "check-no-new-progress-files: ok — no new session-entry file in this change (freeze $FREEZE_AT)" ;;
  1) remedy; echo "check-no-new-progress-files: FAILED"; exit 1 ;;
  *) echo "check-no-new-progress-files: CANNOT LOOK — the diff could not be read" >&2; exit 2 ;;
esac
