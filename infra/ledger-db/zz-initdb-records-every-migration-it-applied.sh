#!/usr/bin/env bash
# The initdb path records every migration it applied — so a REBUILT ledger can say what it carries.
# (infra_a_rebuilt_ledger_cannot_say_which_migrations_it_carries)
#
# ⚠ WHY THIS EXISTS. Only `scripts/ledger-migrate.sh apply` writes `ledger.schema_migration`, in the
# same transaction as each file's DDL. The postgres entrypoint applies this directory's `*.sql` on an
# empty volume and writes NOTHING, so a rebuilt instance carried every migration and recorded only
# the few files that insert their own row. Measured 2026-09-27 on main: 123 files applied with 0
# errors, 24 rows, and `ledger-migrate.sh status` against it said "98 PENDING" about 98 migrations
# it carried — and `apply --all` would then re-run DDL that had already run. After the cutover a
# rebuild is the only recovery, and status is the first thing an operator asks a rebuilt instance.
#
# ⚠ WHY A `.sh` AND NOT A FINAL `.sql`. The live container mounts THIS SAME DIRECTORY, and
# `ledger-migrate.sh` applies every `*.sql` in it. A recorder written as SQL would be applied to live
# as a migration, where "every file in the directory" includes files not yet applied — it would
# record migrations that never ran. The entrypoint runs `*.sh` on an EMPTY data directory and
# nowhere else, and ledger-migrate ignores `*.sh`, so this can only ever describe an initdb.
#
# ⚠ ONE COPY OF THE FACT: the list is the directory, read with the glob the entrypoint itself used.
# Nothing here names a migration. Each row carries the same sha256 `ledger-migrate.sh` records, and
# ON CONFLICT DO NOTHING keeps any row a file wrote for itself (023's backfill, the self-recorders).
#
# ⚠ IT MUST RUN LAST. The entrypoint runs `*.sh` and `*.sql` in one lexical order, so a `.sql` that
# sorted after this file would be applied and never recorded. `zz-` sorts after every numbered
# migration; the check below FAILS THE INITDB rather than record a partial list if that stops being
# true. (A failed initdb leaves no instance, which is loud; a partial record is the silent defect
# this file exists to remove.)
# ⚠ THE WHOLE BODY RUNS IN A SUBSHELL. The entrypoint EXECUTES an executable *.sh but SOURCES one
# whose mode has dropped — and a sourced file shares the entrypoint's shell, so its `exit` would end
# the initdb and its `set -u` would outlive it. In a subshell an `exit 1` is still a failed initdb (the
# entrypoint's own set -e sees the status) and nothing else leaks. Driven at mode 755 and 644.
(
set -euo pipefail

dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
self="$(basename -- "${BASH_SOURCE[0]:-$0}")"

shopt -s nullglob
files=("$dir"/*.sql)
if (( ${#files[@]} == 0 )); then
  echo "$self: no *.sql in $dir — nothing was applied, so nothing is recorded" >&2
  exit 0
fi
last="$(basename -- "${files[-1]}")"
if [[ "$last" > "$self" ]]; then
  echo "$self: FATAL — '$last' sorts AFTER this recorder, so the entrypoint runs it later and it" >&2
  echo "  would be applied but never recorded. Rename this file so it sorts last." >&2
  exit 1
fi

values=""
for f in "${files[@]}"; do
  name="$(basename -- "$f")"
  sum="$(sha256sum "$f" | cut -d' ' -f1)"
  values+="${values:+,}('${name//\'/\'\'}', '${sum}')"
done

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -q <<SQL
INSERT INTO ledger.schema_migration (filename, applied_at, applied_by, checksum, note)
SELECT f.filename, now(), session_user, f.checksum,
       'applied at initdb, recorded by $self'
  FROM (VALUES $values) AS f(filename, checksum)
ON CONFLICT (filename) DO NOTHING;
SQL
recorded="$(psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -tAc 'select count(*) from ledger.schema_migration')"
echo "$self: ${#files[@]} migration file(s) applied at initdb; ledger.schema_migration now holds $recorded row(s)"
)
