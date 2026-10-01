#!/usr/bin/env bash
# scripts/progress.sh — session entries. An entry is a LEDGER ROW (migration 190), never a file.
# (infra_session_entries_live_in_the_ledger_database_and_the_progress_directory_is_frozen_history)
#
#   bash scripts/progress.sh new "<title>" --body-file <file>|-  [--ticket <id>] [--pr <n>]
#   bash scripts/progress.sh tail [n]            # the n newest entries, rows first (default 3)
#   bash scripts/progress.sh list [n]            # '#id  written_at  agent  title', newest first
#   bash scripts/progress.sh list --files [n]    # the frozen history files' paths
#   bash scripts/progress.sh --self-test
#
# WHY A ROW. An entry says what happened, so it is written at the END of a session, after the PR is
# open, and as a file every entry was a commit that restarted that PR's verify. Measured over
# origin/main since 2026-09-27: 37 of 40 progress-only commits landed after their PR was opened. A
# row is written straight to the ledger and touches no branch.
#
# ⚠ progress/ AND PROGRESS.md ARE FROZEN HISTORY. Nothing writes there, scripts/check-no-new-progress-
# files.sh refuses a change that does, and `tail` still reads them for everything before the rows.
#
# ⚠ THE AUTHOR IS THE LEDGER CONNECTION, NOT THIS SCRIPT. ledger.write_session_entry takes session_user,
# so there is no name to resolve here and no name that can be wrong. (This file used to resolve one for
# the filename and the heading, and that resolver once stamped five sessions with one agent's name.)
#
# History: infra_progress_entries_become_per_session_files moved PROGRESS.md to one file per session
# (2026-08-06), because concurrent agents cannot share a file. This moves the entry off the branch
# altogether, because concurrent PRs cannot absorb a late commit either.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
. "scripts/lib/selftest-flag.sh"

PROGRESS_DIR="${PROGRESS_DIR:-progress}"

# ⚠ COLLAPSE A TITLE TO ONE LINE. The commonest way to produce a multi-line title is pasting a whole
# session BODY where a title belongs; the words are kept and it is said.
# (fix_a_multiline_progress_title_puts_a_newline_in_the_filename)
oneline() {
    printf '%s' "${1-}" | tr '\n\r\t' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

_ldb() { printf '%s' "${PROGRESS_LEDGER_DB:-scripts/ledger-db.sh}"; }

# write_entry_row <title> <body> <ticket-or-empty> <pr-or-empty> -> 0 when the row was written.
# The ticket defaults to the branch's ticket (the branch whole, then without a -ptN/-raise/-notes/-hotfix
# suffix). A DERIVED ticket the ledger does not know is dropped and the write retried, because an entry
# on a ticketless branch is still an entry. An EXPLICIT --ticket the ledger refuses is reported, never
# dropped: that is the caller's mistake to see.
write_entry_row() {
    local title="$1" body="$2" ticket="$3" pr="$4" branch derived=0 json verdict rc bodyf jrc
    local ldb; ldb="$(_ldb)"
    branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    [ "$branch" = "HEAD" ] && branch=""
    if [ -z "$ticket" ] && [ -n "$branch" ]; then ticket="$branch"; derived=1; fi
    # ⚠ THE BODY GOES THROUGH A FILE, NOT `--arg`: one argv string is capped at 128 KB, and an entry
    # long enough to hit that would lose its row. (check-a-session-entry-is-a-ledger-row.sh arm H2)
    bodyf="$(mktemp)" || { printf 'progress.sh: ⚠ mktemp failed — the entry was NOT written.\n' >&2; return 1; }
    printf '%s' "$body" > "$bodyf"
    json="$(jq -nc --arg title "$title" --rawfile body "$bodyf" --arg ticket "$ticket" --arg branch "$branch" --arg pr "$pr" \
              '{title:$title, body:$body, ticket_id:$ticket, branch:$branch, pr:$pr}')"; jrc=$?
    rm -f "$bodyf"
    [ "$jrc" = 0 ] || { printf 'progress.sh: ⚠ could not build the entry JSON (is jq installed?) — the entry was NOT written.\n' >&2; return 1; }
    verdict="$(bash "$ldb" session-entry <<<"$json" 2>&1)"; rc=$?
    if [ "$rc" != 0 ] && [ "$derived" = 1 ]; then
        case "$verdict" in
            *no-such-ticket:*)
                local base="${ticket%-pt[0-9]*}"; base="${base%-raise}"; base="${base%-notes}"; base="${base%-hotfix}"
                if [ "$base" != "$ticket" ]; then
                    json="$(jq -c --arg t "$base" '.ticket_id=$t' <<<"$json")"
                    verdict="$(bash "$ldb" session-entry <<<"$json" 2>&1)"; rc=$?
                fi
                if [ "$rc" != 0 ]; then case "$verdict" in *no-such-ticket:*)
                    json="$(jq -c '.ticket_id=""' <<<"$json")"
                    verdict="$(bash "$ldb" session-entry <<<"$json" 2>&1)"; rc=$? ;;
                esac; fi ;;
        esac
    fi
    if [ "$rc" = 0 ]; then
        # The verdict is the ok:<id> LINE, not the last line: a behind copy of ledger-db.sh prints its
        # stale-copy trailer at exit, after the verdict.
        ROW_ID="$(/usr/bin/grep -m1 '^ok:' <<<"$verdict")"; ROW_ID="${ROW_ID#ok:}"
        return 0
    fi
    # The ERROR line names the problem; psql's HINT that follows it only suggests type casts.
    local why; why="$(/usr/bin/grep -m1 'ERROR:' <<<"$verdict")"; [ -n "$why" ] || why="${verdict##*$'\n'}"
    printf 'progress.sh: ⚠ the session entry was NOT written (rc=%s): %s\n' "$rc" "$why" >&2
    return 1
}

cmd_new() {
    local title="${1:-}" body_file="" body="" ticket="" pr=""
    [ -n "$title" ] || { echo "usage: progress.sh new \"<title>\" --body-file <file>|- [--ticket <id>] [--pr <n>]" >&2; return 2; }
    shift
    # ⚠ stdin is read ONLY on `--body-file -`. An agent's shell can hand this script a stdin that never
    # closes, and an implicit `cat` would hang the session.
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --body-file) body_file="${2:-}"; shift 2 ;;
            --ticket)    ticket="${2:-}"; shift 2 ;;
            --pr)        pr="${2:-}"; shift 2 ;;
            *) echo "progress.sh new: unknown argument: $1" >&2; return 2 ;;
        esac
    done
    case "$title" in
        *$'\n'*|*$'\r'*)
            title="$(oneline "$title")"
            printf 'progress.sh: ⚠ your title spanned MORE THAN ONE LINE — collapsed to a single line.\n' >&2
            printf 'progress.sh:   `new` takes a TITLE; the body goes in --body-file.\n' >&2 ;;
    esac
    # ⚠ THE BODY IS REQUIRED. An entry is a row and a row needs its body; a title alone is not an entry,
    # and there is no file any more to type the rest into afterwards.
    [ -n "$body_file" ] || {
        echo "progress.sh new: a session entry needs its BODY — write it to a file and pass --body-file <file> (or - for stdin)" >&2
        return 2; }
    if [ "$body_file" = "-" ]; then body="$(cat)"; else
        [ -r "$body_file" ] || { echo "progress.sh new: cannot read --body-file $body_file" >&2; return 2; }
        body="$(cat "$body_file")"
    fi
    case "$body" in *[![:space:]]*) ;; *) echo "progress.sh new: the body is empty" >&2; return 2 ;; esac
    ROW_ID=""
    write_entry_row "$title" "$body" "$ticket" "$pr" || return 1
    # stdout is the machine-readable contract: one line, the row.
    printf 'session entry #%s\n' "$ROW_ID"
}

# ── READING. Rows first; the frozen files only for what is OLDER than the oldest row shown ──────────
# (so an entry dual-written as a row AND a file while the move was in progress is not printed twice).
# A ledger that cannot be read is SAID, never shown as "no entries".
list_entries() {
    local n="${1:-3}"
    [ -d "$PROGRESS_DIR" ] || return 0
    find "$PROGRESS_DIR" -maxdepth 1 -name '*.md' -type f 2>/dev/null \
        | sort -r | head -n "$n"
}

rows_json() {
    local out
    out="$(bash "$(_ldb)" session-entries --limit "${1:-3}" 2>/dev/null)" || return 1
    jq -e 'type == "array"' >/dev/null 2>&1 <<<"$out" || return 1
    printf '%s\n' "$out"
}

files_older_than() {
    # Counted in the loop rather than piped into `head`: an early-exiting reader SIGPIPEs its
    # producer, which pipefail reports as a failure (check-pipefail-grep-q.sh).
    local cut="$1" n="$2" f b c=0 all
    all="$(list_entries 100000)"
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ "$c" -ge "$n" ] && break
        b="$(basename "$f")"
        if [ -z "$cut" ] || [ "${b:0:15}" \< "$cut" ]; then printf '%s\n' "$f"; c=$((c+1)); fi
    done <<<"$all"
}

cmd_list() {
    if [ "${1:-}" = "--files" ]; then list_entries "${2:-3}"; return 0; fi
    local rows
    if rows="$(rows_json "${1:-3}")"; then
        jq -r '.[] | "#\(.id)\t\(.written_at)\t\(.agent)\t\(.title)"' <<<"$rows"
    else
        echo "progress.sh: could not read session entries from the ledger — NOT 'no entries'. Files: progress.sh list --files" >&2
        return 2
    fi
}

cmd_tail() {
    local n="${1:-3}" rows shown=0 cut="" f any=0 oldest
    if rows="$(rows_json "$n")"; then
        shown="$(jq 'length' <<<"$rows")"
        if [ "$shown" -gt 0 ]; then
            any=1
            jq -r '.[] | "\n\u001b[1;36m━━ #\(.id)  \(.written_at)  \(.agent)\(if .ticket_id then "  [[\(.ticket_id)]]" else "" end)\(if .pr then "  #\(.pr)" else "" end)\u001b[0m\n# \(.title)\n\n\(.body)"' <<<"$rows"
            oldest="$(jq -r '.[-1].written_at' <<<"$rows")"
            cut="$(date -u -d "$oldest" +%Y-%m-%d-%H%M 2>/dev/null)" || cut=""
            # A timestamp that will not parse must not widen the window to "every file": say so, stop.
            [ -n "$cut" ] || { echo "progress.sh: could not read the oldest row's time ($oldest) — frozen files not shown" >&2; return 0; }
        fi
    else
        echo "progress.sh: ⚠ could not read session entries from the ledger — this is NOT 'no entries'; the FILES follow" >&2
    fi
    if [ "$shown" -lt "$n" ]; then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            any=1
            printf '\n\033[1;36m━━ %s\033[0m  (frozen history — a file, from before entries were rows)\n' "$f"
            cat "$f"
        done <<< "$(files_older_than "$cut" "$(( n - shown ))")"
    fi
    if [ "$any" = 0 ]; then
        echo "no session entries yet — the older history is in progress/ and PROGRESS.md"
    fi
}

# ⚠ RETIRED, NOT DELETED: a caller that still asks gets the reason instead of "unknown argument".
# An entry was a file, so it rode in a PR, and that PR needed a title; a row needs neither.
cmd_print_pr_title() {
    echo "progress.sh: --print-pr-title is retired — a session entry is a ledger row now, so there is no entry PR to title." >&2
    echo "  Write it with: bash scripts/progress.sh new \"<title>\" --body-file <file>" >&2
    return 2
}

self_test() {
    local fails=0 tmp out
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
    check() { if [ "$2" = 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fails=1; fi; }
    echo "progress.sh self-test"

    [ "$(oneline $'a\nb\r\tc')" = "a b c" ]; check "oneline collapses newlines, CRs and tabs" $?

    # A STUB ledger-db that records every call. STUB_REFUSE_TICKETS=1 answers no-such-ticket for any
    # non-empty ticket_id; STUB_WRITE_FAIL=1 fails every write; STUB_READ_FAIL=1 fails every read.
    local stub="$tmp/stub-ledger-db.sh" calls="$tmp/calls.jsonl"
    cat > "$stub" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = session-entries ]; then
  [ "${STUB_READ_FAIL:-0}" = 1 ] && { echo "psql: error: connection refused" >&2; exit 2; }
  printf '%s\n' "${STUB_ROWS:-[]}"; exit 0
fi
[ "${1:-}" = session-entry ] || { echo "stub: unexpected verb ${1:-}" >&2; exit 64; }
j="$(cat)"; printf '%s\n' "$j" >> "$STUB_CALLS"
[ "${STUB_WRITE_FAIL:-0}" = 1 ] && { echo "ERROR:  function ledger.write_session_entry(jsonb) does not exist"; echo "HINT:  No function matches"; exit 3; }
t="$(jq -r '.ticket_id' <<<"$j")"
if [ "${STUB_REFUSE_TICKETS:-0}" = 1 ] && [ -n "$t" ]; then echo "no-such-ticket:$t"; exit 1; fi
echo "ok:$(wc -l < "$STUB_CALLS" | tr -d ' ')"
# A BEHIND copy of ledger-db.sh prints its stale-copy trailer at exit, AFTER the verdict.
[ "${STUB_TRAILER:-0}" = 1 ] && echo "ledger-db:   origin/main e7d637948"
exit 0
STUB
    local bf="$tmp/body.md"; printf 'Did the thing.\nIt worked.\n' > "$bf"
    export PROGRESS_LEDGER_DB="$stub" STUB_CALLS="$calls"

    ( PROGRESS_DIR="$tmp/p1"; : > "$calls"
      out="$(cmd_new 'Row only' --body-file "$bf" --pr 42 2>"$tmp/e1")" || exit 1
      [ "$out" = "session entry #1" ] || exit 2                                   # stdout: one line, the row
      [ "$(wc -l < "$calls")" = 1 ] || exit 3
      [ "$(jq -r '.title+"|"+.body+"|"+.pr' "$calls")" = "Row only|Did the thing.
It worked.|42" ] || exit 4
      [ ! -e "$tmp/p1" ] || exit 5 )                                              # ⚠ NO FILE, NO DIRECTORY
    check "new writes ONE row (title, body, pr), prints '#id', and writes NOTHING under progress/" $?

    ( PROGRESS_DIR="$tmp/p1t"; : > "$calls"; export STUB_TRAILER=1
      out="$(cmd_new 'Row only' --body-file "$bf" 2>/dev/null)" || exit 1
      [ "$out" = "session entry #1" ] || exit 2 )
    check "the row id is read from the ok: LINE, not the last line (a stale-copy trailer follows it)" $?

    ( PROGRESS_DIR="$tmp/p2"; : > "$calls"
      cmd_new 'Title only' >/dev/null 2>"$tmp/e2"; rc=$?
      [ "$rc" = 2 ] && [ ! -s "$calls" ] && [ ! -e "$tmp/p2" ] || exit 1
      grep -q 'needs its BODY' "$tmp/e2" || exit 2 )
    check "NEGATIVE CONTROL: no body -> refused (rc=2), nothing written, and the remedy is named" $?

    ( PROGRESS_DIR="$tmp/p3"; : > "$calls"; export STUB_WRITE_FAIL=1
      cmd_new 'Ledger down' --body-file "$bf" >/dev/null 2>"$tmp/e3"; rc=$?
      [ "$rc" = 1 ] && [ ! -e "$tmp/p3" ] || exit 1
      grep -q 'NOT written.*ERROR:  function ledger.write_session_entry' "$tmp/e3" || exit 2 )
    check "NEGATIVE CONTROL: a refused write FAILS the command (rc=1), names the ERROR line, and falls back to NO file" $?

    ( : > "$calls"; export STUB_REFUSE_TICKETS=1
      cmd_new 'Derived ticket unknown' --body-file "$bf" >/dev/null 2>&1 || exit 1
      [ "$(tail -1 "$calls" | jq -r .ticket_id)" = "" ] || exit 2 )
    check "a DERIVED ticket the ledger does not know is dropped and the row still written" $?

    ( : > "$calls"; export STUB_REFUSE_TICKETS=1
      cmd_new 'Explicit ticket wrong' --body-file "$bf" --ticket no_such_thing >/dev/null 2>"$tmp/e4"; rc=$?
      [ "$rc" = 1 ] && [ "$(wc -l < "$calls")" = 1 ] || exit 1
      grep -q 'no-such-ticket:no_such_thing' "$tmp/e4" || exit 2 )
    check "NEGATIVE CONTROL: an EXPLICIT --ticket the ledger refuses fails the command, never silently dropped" $?

    ( : > "$calls"; printf 'From stdin.\n' | cmd_new 'Stdin body' --body-file - >/dev/null 2>&1 || exit 1
      [ "$(jq -r .body "$calls")" = "From stdin." ] || exit 2 )
    check "--body-file - reads the body from stdin" $?

    ( : > "$calls"; printf '   \n' > "$tmp/blank.md"
      cmd_new 'Blank body' --body-file "$tmp/blank.md" >/dev/null 2>&1; rc=$?
      [ "$rc" = 2 ] && [ ! -s "$calls" ] || exit 1 )
    check "NEGATIVE CONTROL: a whitespace-only body is refused before anything is written" $?

    ( : > "$calls"; out="$(cmd_new $'Pasted\nbody as a title' --body-file "$bf" 2>"$tmp/e5")" || exit 1
      [ "$(jq -r .title "$calls")" = "Pasted body as a title" ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] || exit 2
      grep -q 'MORE THAN ONE LINE' "$tmp/e5" || exit 3 )
    check "a multi-line title is collapsed to one line, every word kept, and it is said" $?

    # ── READING: rows first, then only the files OLDER than the oldest row ─────────────────────────
    local rows2='[{"id":9,"written_at":"2026-09-28T19:30:00+00:00","agent":"Ed","ticket_id":"t_x","branch":"b","pr":12,"title":"Newest row","body":"row body nine"},{"id":8,"written_at":"2026-09-28T18:00:00+00:00","agent":"Vera","ticket_id":null,"branch":null,"pr":null,"title":"Older row","body":"row body eight"}]'
    ( PROGRESS_DIR="$tmp/ptail"; mkdir -p "$PROGRESS_DIR"
      printf '# dup\ndual-written twin of row 9\n' > "$PROGRESS_DIR/2026-09-28-1930-ed-newest-row.md"
      printf '# history\nan entry from before rows\n' > "$PROGRESS_DIR/2026-09-20-1000-cara-old-history.md"
      export STUB_ROWS="$rows2"
      out="$(cmd_tail 3 2>/dev/null)"
      grep -q 'row body nine' <<<"$out" && grep -q 'row body eight' <<<"$out" || exit 1
      grep -q 'an entry from before rows' <<<"$out" || exit 2
      ! grep -q 'dual-written twin' <<<"$out" || exit 3 )
    check "tail: the newest ROWS with their bodies, then only files OLDER than the oldest row — a dual-written twin is not shown twice" $?

    ( PROGRESS_DIR="$tmp/ptail"; export STUB_READ_FAIL=1
      out="$(cmd_tail 3 2>"$tmp/te")"
      grep -q 'NOT .no entries' "$tmp/te" || exit 1
      grep -q 'an entry from before rows' <<<"$out" || exit 2 )
    check "NEGATIVE CONTROL: an unreadable ledger is SAID (never 'no entries') and the files still print" $?

    ( export STUB_ROWS="$rows2"
      out="$(cmd_list 3 2>/dev/null)"
      [ "$(printf '%s\n' "$out" | wc -l)" = 2 ] && [[ "$out" == '#9'$'\t'* ]] || exit 1
      STUB_READ_FAIL=1 cmd_list 3 >/dev/null 2>&1; [ "$?" = 2 ] || exit 2
      PROGRESS_DIR="$tmp/ptail"; [ "$(cmd_list --files 9 | wc -l)" = 2 ] || exit 3 )
    check "list: rows as '#id  written_at  agent  title'; unreadable is rc=2, not empty; --files lists the history" $?

    ( PROGRESS_DIR="$tmp/nope"; [ -z "$(list_entries 3)" ] ); check "an absent history directory lists nothing, quietly" $?

    cmd_print_pr_title >/dev/null 2>"$tmp/e6"; rc=$?
    [ "$rc" = 2 ] && grep -q 'retired' "$tmp/e6"; check "--print-pr-title is retired with the reason, not an unknown-argument error" $?

    [ "$fails" = 0 ] && echo "all cases passed"
    return "$fails"
}

case "${1:-}" in
    --self-test|--selftest) self_test; exit $? ;;
    --print-pr-title) cmd_print_pr_title; exit $? ;;
    new)         shift; cmd_new "$@"; exit $? ;;
    tail)        shift; cmd_tail "${1:-3}"; exit $? ;;
    list)        shift; cmd_list "$@"; exit $? ;;
    ''|--help|-h)
        sed -n '2,9p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
        exit 0 ;;
    *)
        echo "usage: progress.sh {new \"<title>\" --body-file <file>|- [--ticket <id>] [--pr <n>]|tail [n]|list [n]|list --files [n]|--self-test}" >&2
        exit 2 ;;
esac
