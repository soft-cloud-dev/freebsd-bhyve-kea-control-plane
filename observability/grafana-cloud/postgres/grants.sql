\set ON_ERROR_STOP on

-- Run this file as the owner of the monitored database after creating the
-- login role:
--
--   CREATE ROLE "db-o11y" LOGIN PASSWORD 'REPLACE_WITH_SECRET';
--
-- Repeat CREATE EXTENSION and schema grants in every logical database that
-- should appear in Grafana Cloud Database Observability.

CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

GRANT pg_monitor TO "db-o11y";
GRANT pg_read_all_stats TO "db-o11y";
ALTER ROLE "db-o11y" SET pg_stat_statements.track = 'none';

-- Scope detailed schema and explain-plan access to the BKCP application schema.
GRANT USAGE ON SCHEMA bkcp TO "db-o11y";
GRANT SELECT ON ALL TABLES IN SCHEMA bkcp TO "db-o11y";

-- Run as each table owner whose future BKCP tables should be visible.
ALTER DEFAULT PRIVILEGES IN SCHEMA bkcp
    GRANT SELECT ON TABLES TO "db-o11y";
