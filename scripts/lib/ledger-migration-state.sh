#!/usr/bin/env bash
# The ledger migration record's PURE verdicts, in one place.
# (infra_nothing_records_which_ledger_migrations_are_applied_to_the_live_instance)
#
# ⚠ ONE IMPLEMENTATION, TWO CALLERS. `scripts/ledger-migrate.sh` decides what to apply from these;
# `scripts/check-ledger-schema-rebuilds.sh` decides what to SAY from them. If they each carried
# their own copy, the tool and the gate could disagree about whether an instance is behind — and the
# gate's whole problem was that it could not say which side was stale. Two answers to that question
# would be worse than the none it had.
#
# The self-test lives in `scripts/ledger-migrate.sh --selftest` (tiered `verify`), which is what
# gives these coverage; the gate is ci-exempt and runs only when somebody chooses to run it.

# migration_key <filename> -> the migration's IDENTITY, independent of zero-padding.
#
# ⚠ WHY THIS EXISTS: A MIGRATION'S NAME CHANGED WITHOUT THE MIGRATION CHANGING.
# The corpus was padded to three digits on 2026-09-05 so that initdb's BYTE order would agree with
# numeric order again — unpadded, `100-` sorts between `10-` and `11-` and a fresh build fails on
# columns that do not exist yet. Every filename moved. But `ledger.schema_migration` records what
# ran under the name it had AT THE TIME, and that record is history: it is not rewritten, because a
# row saying `23-record-…` is TRUE — that is the file that ran.
#   (infra_a_three_digit_migration_number_executes_ninety_files_early_and_breaks_every_rebuild)
#
# So the tool must recognise that `23-record-x.sql` and `023-record-x.sql` are the same migration.
# Without it, the padding rename makes every recorded migration read as PENDING on every existing
# instance, and the order guard then refuses to apply anything at all — measured: 80 applied rows,
# 0 recognised.
#
# ⚠ THE ALTERNATIVE WAS A DATA MIGRATION AND IT IS THE WRONG SHAPE, which is worth recording because
# it was written first and abandoned. A migration UPDATE-ing the 80 recorded filenames to padded
# form cannot apply: the order guard sees the earlier files as pending and refuses to run it —
# chicken-and-egg, and the refusal was correct. It would also rewrite history to match a spelling
# decision taken later, in a table whose value is that it says what actually happened.
#
# ⚠ NUMBER-BASED, NOT CONTENT-BASED, AND THE DIFFERENCE IS LOAD-BEARING. A checksum compare looks
# more rigorous and fails here: the bootstrap records its own filename in its own body and one
# header names itself, so those two files legitimately changed content in the same commit as the
# rename. Hashing would call exactly those two unrecognised. A migration's identity is its NUMBER.
migration_key() { # $1 filename (basename or path)
  local b n d
  b="${1##*/}"
  case "$b" in
    [0-9]*-*) : ;;
    *) printf '%s\n' "$b"; return 0 ;;      # not a numbered migration; identity is the name itself
  esac
  n="${b%%-*}"; d="${n%%[a-z]*}"
  # ⚠ `10#` IS NOT DECORATION: `$((099))` is a bash error, because a leading zero means octal.
  printf '%s%s-%s\n' "$((10#$d))" "${n#"$d"}" "${b#*-}"
}

# PURE: (filename, recorded, bootstrap) -> applied | predates-the-record | pending
#
# ⚠ THE THIRD STATE IS THE ONE THAT MATTERS AND IT IS NOT `pending`. A file ordered below the
# bootstrap migration with no row did NOT fail to be applied — on a rebuilt instance it ran via
# initdb before the record existed, and on a caught-up instance the tool recorded it. Reporting it
# as `pending` would invite RE-RUNNING migrations that have already run.
#
# Concretely this is how migration 22 is handled: `22-nothing-can-read-…` was on an open PR and not
# on main when the bootstrap backfill was written, so it is deliberately absent from that list. If
# it lands it sorts below the bootstrap, and this returns `predates-the-record` — honest in both
# directions, and never work to do.
# ⚠ A FOURTH VERDICT, AND IT EXISTS BECAUSE AN ALARM NOBODY CAN CLEAR TEACHES EVERYONE TO IGNORE
# THE INSTRUMENT. After a concurrent RENUMBER, a file can be unrecorded under its own name while its
# CONTENT is already applied under the old one — `schema_migration` is append-only by trigger, so the
# old row is permanent and correct. The tool called that PENDING and told every agent the database
# was BEHIND, handing them `apply --all`, a command they must not run. **It is the reporting that was
# wrong, not the record.**
#
# ⚠ THE CALLER DECIDES THE MATCH, NOT THIS FUNCTION. `$4` is the filename of a RECORDED row whose
# checksum equals this file's — computed by whoever has the database and the disk. Keeping the
# lookup outside keeps this pure and keeps the one source of verdicts shared with
# check-ledger-schema-rebuilds.sh, which must not grow a second opinion about what "behind" means.
#
# ⚠ AND `$4` IS OPTIONAL. Every existing caller passes three arguments and keeps its old behaviour
# exactly; a checksum nobody looked up cannot silently reclassify a file as applied.
file_verdict() { # $1 filename · $2 recorded (yes|no) · $3 bootstrap filename · $4 same-content recorded file
  local f="${1-}" rec="${2-}" boot="${3-}" twin="${4-}"
  [[ -n "$f" && -n "$boot" ]] || { printf 'pending\n'; return 0; }
  [[ "$rec" == yes ]] && { printf 'applied\n'; return 0; }
  # ⚠ ONLY WHEN THE TWIN IS A DIFFERENT FILE. A row matching this file's OWN name is the `applied`
  # case above; treating a self-match as "applied elsewhere" would mislabel every ordinary row.
  [[ -n "$twin" && "$twin" != "$f" ]] && { printf 'applied-elsewhere\n'; return 0; }
  # LC_ALL=C so the ordering is byte order — the same order Postgres's initdb mount uses.
  if [[ "$(printf '%s\n%s\n' "$f" "$boot" | LC_ALL=C sort | head -1)" == "$f" && "$f" != "$boot" ]]; then
    printf 'predates-the-record\n'; return 0
  fi
  printf 'pending\n'
}

# PURE: is applying <file> in order, given the lowest pending file? -> ok | out-of-order | nothing-pending
#
# ⚠ REFUSING TO SKIP IS WHAT MAKES THE BOOTSTRAP'S BACKFILL TRUE. That file asserts every migration
# below it has run. Applied in order that is true by construction; applied to an instance missing an
# earlier file it records a FALSEHOOD, and a falsehood in a record built to be trusted is worse than
# the absence it replaced.
order_verdict() { # $1 requested · $2 lowest-pending ('' when none)
  local want="${1-}" low="${2-}"
  [[ -n "$low" ]] || { printf 'nothing-pending\n'; return 0; }
  [[ "$want" == "$low" ]] && printf 'ok\n' || printf 'out-of-order\n'
}

# PURE: (table-exists, n-applied, n-pending) -> no-record | behind | current | empty-record
# ⚠ `no-record` IS NOT `nothing-applied`. An instance predating the bootstrap has every migration
# applied and no table to say so; reading that as "nothing has run" is the fail-toward-alarming
# direction and would prompt a full re-apply.
instance_verdict() { # $1 has-table (yes|no) · $2 applied · $3 pending
  local has="${1-}" ap="${2-0}" pend="${3-0}"
  [[ "$has" == yes ]] || { printf 'no-record\n'; return 0; }
  [[ "$pend" -gt 0 ]] && { printf 'behind\n'; return 0; }
  [[ "$ap" -gt 0 ]] && { printf 'current\n'; return 0; }
  printf 'empty-record\n'
}

# PURE: why do the repo's schema and the live schema differ?
#   (record-readable, n-unapplied, n-extra) -> unclassifiable | live-behind | repo-behind
#                                            | both | unrecorded-change
#
# ⚠⚠ THIS IS WHAT REPLACES THE DECISION TREE, AND THE DECISION TREE WAS NOT MERELY UNHELPFUL — IT
# WAS WRONG IN THE COMMONEST CASE. The gate used to tell the reader:
#
#     both directions -> do not guess: these are two separate facts, not one drift.
#
# But a migration that DROPs something necessarily shows as a `<` line while its siblings show as
# `>`. **One fact — "live has not been deployed" — presents as two.** Measured on this repo:
# 17 drops `parked_only_while_owned` (a `<` line) while 19 and 21 add objects (`>` lines), so the
# gate reported both directions for a SINGLE cause and then told the reader they were two.
# (Found by Saffron, verified by Don, 2026-08-29.)
#
# The record settles it without inference: `unapplied` counts migration FILES the live instance has
# no row for, which is a fact about deployment, not about object shapes. A DROP and an ADD in the
# same unapplied file are one number here, however many directions they take in a diff.
#
# ⚠ `unrecorded-change` IS THE COMPLEMENT CASE AND IS WHY THE SCHEMA DIFF STAYS. Every migration is
# accounted for and the schemas STILL differ — so something was changed outside a migration. The
# record cannot see that by construction (it records what RAN, not what the schema IS) and the diff
# cannot name it. Only the two together can, which is the argument against retiring either.
#
# ⚠ `unclassifiable` IS NOT A FAILURE OF THIS FUNCTION. An instance with no record genuinely cannot
# be classified, and saying so is the honest answer — the same discipline as the gate's own
# exit 2 = CANNOT TELL. It is the state the whole ledger was in before this table existed.
drift_verdict() { # $1 record-readable (yes|no) · $2 n-unapplied · $3 n-extra
  local have="${1-}" un="${2-0}" ex="${3-0}"
  [[ "$have" == yes ]] || { printf 'unclassifiable\n'; return 0; }
  if   [[ "$un" -gt 0 && "$ex" -gt 0 ]]; then printf 'both\n'
  elif [[ "$un" -gt 0 ]];                then printf 'live-behind\n'
  elif [[ "$ex" -gt 0 ]];                then printf 'repo-behind\n'
  else                                        printf 'unrecorded-change\n'
  fi
}

# PURE: can this checkout's file list be trusted as the whole population?
#   (fetch-state, n-migrations-upstream-but-absent-here) -> complete | incomplete | unknown
#
# ⚠⚠ THIS EXISTS BECAUSE `status` ANSWERS A QUESTION ABOUT YOUR CHECKOUT WHILE APPEARING TO ANSWER
# ONE ABOUT THE DATABASE. `SRC="infra/ledger-db"` is the WORKING TREE, so `pending` means
# "migrations IN MY TREE the database has not applied" -- and a tree behind main does not have the
# files at all, so it reports them as nothing. **It says `current -- 0 pending` while migrations are
# outstanding**, which is the reassuring direction and therefore the dangerous one.
#
# Measured 2026-08-30, two independent instances ten minutes apart, both by agents who knew the
# tool: Saffron read `0 pending` from a checkout 7 commits behind, Don read the same from a `-pt1`
# branch cut before the files landed. Truth from a current tree was BEHIND -- 3 PENDING.
# **28 and 29 sat merged-but-unapplied for about four hours while the mirror went on wiping claims**,
# with this command reporting current to everyone who asked.
#
# ⚠ THE FIX IS NOT TO READ origin/main INSTEAD. A developer authoring a migration needs their own
# tree enumerated or their new file is invisible to the tool that applies it. So the tree stays the
# subject and the REPORT states which tree it was and whether that tree is the whole population.
#
# ⚠ `unknown` IS NOT `complete`. If we could not refresh origin/main, zero-missing may mean "nothing
# is missing" or "our copy of origin/main is as old as our tree" -- and those are different facts.
# Saying so is the same discipline as this tool's exit 2 = CANNOT LOOK.
# (infra_ledger_migrate_status_reads_your_checkout_so_a_stale_tree_reports_zero_pending)
tree_verdict() { # $1 fetch-state (fresh|stale) · $2 n-upstream-absent-here
  local fetch="${1-}" missing="${2-0}"
  [[ "$missing" =~ ^[0-9]+$ ]] || { printf 'unknown\n'; return 0; }
  [[ "$missing" -gt 0 ]] && { printf 'incomplete\n'; return 0; }
  [[ "$fetch" == fresh ]] && { printf 'complete\n'; return 0; }
  printf 'unknown\n'
}
