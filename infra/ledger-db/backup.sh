#!/usr/bin/env bash
# Nightly ledger backup -> OneDrive (owner, 2026-08-26: "here - with regular backups to onedrive").
# ⚠ pipefail is not optional: without it a failed pg_dumpall still produces a VALID GZIP OF NOTHING
# and exits 0. That is the failure this most needs not to have.
# ⚠ NOT DURING A REBUILD. This file sits in the directory docker-compose.yml mounts as
# /docker-entrypoint-initdb.d, and the postgres entrypoint runs every *.sh there on an EMPTY volume —
# EXECUTING it at mode 755 and SOURCING it otherwise. Run there, `docker exec` does not exist and the
# failure aborted the initdb: a rebuild of the ledger, the only way back since the cutover, never
# completed (fix_a_ledger_rebuild_dies_at_initdb_because_the_backup_script_sits_in_the_initdb_directory).
# `return` first, because a SOURCED `exit` would end the entrypoint's own shell mid-init; and this
# runs BEFORE `set -euo pipefail`, which a sourced file would otherwise leave switched on for it.
case "$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" in
  /docker-entrypoint-initdb.d)
    echo "backup.sh: running inside an initdb — a rebuild is not a backup; nothing to do" >&2
    return 0 2>/dev/null || exit 0 ;;
esac
set -euo pipefail
# The state root is overridable so the dump can be DRIVEN into a scratch directory; the nightly unit
# sets nothing and gets exactly the path it always had.
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/harness-env.sh"
D="${LEDGER_BACKUP_ROOT:-$LEDGER_DEPLOY_DIR}"
OUT="$D/backup/ledger-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"
docker exec "$LEDGER_CONTAINER" pg_dumpall -U ledger_owner | gzip -9 > "$OUT"
gzip -t "$OUT"
grep -qa 'PostgreSQL database cluster dump complete' <(gzip -dc "$OUT") \
  || { echo "backup: no terminator — truncated dump, refusing"; rm -f "$OUT"; exit 1; }
echo "backup: $OUT ($(stat -c%s "$OUT") bytes)"
# retain 14
ls -1t "$D"/backup/ledger-*.sql.gz | tail -n +15 | xargs -r rm -f
# ⚠ OneDrive leg is NOT wired yet — needs the owner's path/credentials. Until then this is local only.
