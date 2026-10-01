#!/usr/bin/env bash
# Sync the ledger database's DEPLOYMENT DIRECTORY from the repository.
#
# ⚠ THE LIVE LEDGER DOES NOT RUN FROM THE REPO, AND THAT IS DELIBERATE — but nothing kept the two
# in step, so they diverged the same day they were created. Measured 2026-08-26 21:55Z:
#
#     the repository        01, 01a, 02 … 11        (twelve files)
#     ~/.local/state/…      01, 02, 03, 04          (four, copied by hand at 18:28)
#     the live DATABASE     everything, because 05-11 were applied by `docker exec`
#
# **Three copies of one schema, all different, and the running service was reading the poorest of
# them.** A rebuild from the deployment directory would have produced the four-file schema — the one
# with the `owned_iff_in_progress` biconditional and no `blocked` — while the repo said otherwise
# and the live instance behaved correctly. Every one of the three was internally consistent.
#
# ⚠ WHY THE DEPLOYMENT DIRECTORY EXISTS AT ALL, so nobody "simplifies" it away: the ledger is
# ALWAYS-ON and shared by every worktree. Running it out of a checkout would tie one shared service
# to one agent's directory — which can be deleted, switched to another branch, or pruned by
# `git worktree`. The state directory is the right call; the missing half was keeping it derived.
#
# ⚠ IT DOES NOT RESTART ANYTHING. Copying files cannot change a running Postgres: the initdb mount
# is read ONLY on an empty data directory. This makes the NEXT rebuild correct. A live instance
# still needs each new migration applied by hand, and conflating those is how you ship a deploy
# script that appears to have fixed a running system and has not.
set -uo pipefail
cd "$(dirname "$0")/.."

DEPLOY="${LEDGER_DEPLOY_DIR:-$LEDGER_DEPLOY_DIR}"
SRC="infra/ledger-db"

[[ -d "$SRC" ]] || { echo "ledger-db-deploy: $SRC is missing — wrong checkout?" >&2; exit 1; }
mkdir -p "$DEPLOY"

changed=0 same=0 added=0
# ⚠ `zz-initdb-*.sh` RIDE WITH THE MIGRATIONS. The live container mounts THIS deploy directory as
# /docker-entrypoint-initdb.d, so a rebuild of the live deployment runs whatever is here — and
# without the recorder it rebuilds a ledger that carries every migration and records almost none
# of them (infra_a_rebuilt_ledger_cannot_say_which_migrations_it_carries). A glob, not a name, so
# the next initdb-only script ships without anyone remembering this list.
for f in "$SRC"/*.sql "$SRC"/zz-initdb-*.sh "$SRC"/docker-compose.yml "$SRC"/backup.sh "$SRC"/README.md; do
  [[ -e "$f" ]] || continue
  b="$(basename "$f")"
  if [[ ! -e "$DEPLOY/$b" ]]; then
    cp "$f" "$DEPLOY/$b"; added=$((added+1)); printf '  + %s\n' "$b"
  elif ! cmp -s "$f" "$DEPLOY/$b"; then
    cp "$f" "$DEPLOY/$b"; changed=$((changed+1)); printf '  ~ %s\n' "$b"
  else
    same=$((same+1))
  fi
done

# ⚠ pgpass IS A SECRET AND IS NEVER COPIED EITHER WAY. It is not in the repository, is not
# gitignored (so it is one `git add -A` from being committed), and the README did not mention it —
# a rebuilder hits `bind source path does not exist` before reaching a single line of schema.
if [[ ! -s "$DEPLOY/pgpass" ]]; then
  echo "  ⚠ $DEPLOY/pgpass is missing or empty — the stack cannot start." >&2
  echo "     Create it (it is a secret, never committed):" >&2
  echo "       head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20 > $DEPLOY/pgpass" >&2
  echo "       chmod 600 $DEPLOY/pgpass" >&2
  exit 1
fi

# ⚠ SAY THE SUBJECT COUNT. "synced" with no numbers is indistinguishable from a run that copied
# nothing — and a deploy script that silently no-ops is exactly how the two copies drifted.
printf 'ledger-db-deploy: %d added, %d updated, %d already current -> %s\n' "$added" "$changed" "$same" "$DEPLOY"
if [[ $((added + changed)) -gt 0 ]]; then
  echo "  ⚠ The RUNNING database is unchanged — initdb only reads these on an EMPTY data directory."
  echo "    Apply the pending ones, in order, and RECORD that you did:"
  echo "      bash scripts/ledger-migrate.sh status"
  echo "      bash scripts/ledger-migrate.sh apply --all"
  # ⚠ THIS USED TO PRINT THE RAW `docker exec … psql -f -` LINE, AND THAT LINE RECORDED NOTHING.
  # It was the sanctioned apply path, printed by this script on every run, and it is why the
  # database could not say which of its own migrations it was carrying: five merged migrations sat
  # unapplied with nothing anywhere saying so, one of them (18) leaving the owner's work-items
  # screen returning `permission denied for table request`. `ledger-migrate.sh` applies the DDL and
  # writes `ledger.schema_migration` in the SAME transaction, so a migration that half-applied
  # cannot leave a row claiming it ran — which is worse than leaving no row at all.
  # (infra_nothing_records_which_ledger_migrations_are_applied_to_the_live_instance)
fi
