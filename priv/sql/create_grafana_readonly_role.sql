-- Creates or updates the least-privilege database account used by Grafana.
-- Run as a PostgreSQL administrator with psql:
--   psql -U postgres -d teslamate -f priv/sql/create_grafana_readonly_role.sql
--
-- This role can read TeslaMate's public reporting data, but cannot modify it
-- and receives no access to the private schema that contains encrypted tokens.
-- psql securely prompts for the new Grafana password instead of placing it in
-- shell history or the operating system's process list.

\set ON_ERROR_STOP on

SELECT 'CREATE ROLE teslamate_grafana LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT'
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'teslamate_grafana')
\gexec

ALTER ROLE teslamate_grafana
  WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT;

\password teslamate_grafana

GRANT CONNECT ON DATABASE teslamate TO teslamate_grafana;
GRANT USAGE ON SCHEMA public TO teslamate_grafana;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO teslamate_grafana;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO teslamate_grafana;
GRANT EXECUTE ON FUNCTION
  public.tm_lat_for_map(TEXT, DOUBLE PRECISION, DOUBLE PRECISION),
  public.tm_lng_for_map(TEXT, DOUBLE PRECISION, DOUBLE PRECISION),
  public.tm_effective_cost(INTEGER, NUMERIC)
TO teslamate_grafana;

REVOKE ALL ON SCHEMA private FROM teslamate_grafana;

ALTER DEFAULT PRIVILEGES FOR ROLE teslamate IN SCHEMA public
  GRANT SELECT ON TABLES TO teslamate_grafana;
ALTER DEFAULT PRIVILEGES FOR ROLE teslamate IN SCHEMA public
  GRANT SELECT ON SEQUENCES TO teslamate_grafana;

\echo 'Grafana read-only role is ready. The private token schema was not granted.'
