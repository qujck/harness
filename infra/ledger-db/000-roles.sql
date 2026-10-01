-- 000-roles.sql — the group roles the ledger's grants refer to. Per-agent LOGIN roles are created by
-- `ledger-db.sh sync-agent-roles` from agents/roster.json (identity child); these three are NOLOGIN
-- groups. ledger_owner is the database owner created by the container's POSTGRES_USER.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_agent')   THEN CREATE ROLE ledger_agent   NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_console') THEN CREATE ROLE ledger_console NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'ledger_sync')    THEN CREATE ROLE ledger_sync    NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'release_claims_janitor') THEN CREATE ROLE release_claims_janitor NOLOGIN; END IF;
END $$;
