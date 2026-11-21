-- Least-privilege PostgreSQL role for loading a migration target: it can read and write one
-- schema, and cannot become superuser, create databases or roles, or write to other schemas.
--
-- Run with psql as a role that can create roles (superuser or CREATEROLE) and owns the target
-- schema, connected to the target database:
--   psql -v ON_ERROR_STOP=1 -d <TARGET_DB> -f postgres/01-target-least-privilege.sql
-- Replace <TARGET_DB> and <TARGET_SCHEMA> first. The role is created WITHOUT a password, so no
-- password ends up in this file or in the server log; set one afterwards in psql with:
--   \password migration_app

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'migration_app') THEN
        CREATE ROLE migration_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
    END IF;
END $$;

GRANT CONNECT ON DATABASE "<TARGET_DB>" TO migration_app;

-- CREATE lets a loader create its own tables. If you pre-create the tables as the DBA,
-- grant USAGE only.
GRANT USAGE, CREATE ON SCHEMA "<TARGET_SCHEMA>" TO migration_app;

-- Read and write existing tables (TRUNCATE for loaders that empty a table before the first
-- load). UPDATE on sequences lets the loader reset identity sequences with setval() afterwards.
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON ALL TABLES IN SCHEMA "<TARGET_SCHEMA>" TO migration_app;
GRANT USAGE, SELECT, UPDATE ON ALL SEQUENCES IN SCHEMA "<TARGET_SCHEMA>" TO migration_app;

-- The same privileges on tables and sequences that the role running this script creates later.
-- (Tables migration_app creates are its own already. If a different role will create them,
-- add FOR ROLE <that_role> to these two statements.)
ALTER DEFAULT PRIVILEGES IN SCHEMA "<TARGET_SCHEMA>"
    GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE ON TABLES TO migration_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA "<TARGET_SCHEMA>"
    GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO migration_app;

-- Things every role gets through PUBLIC, which this script does not change:
--   * PostgreSQL 14 and earlier: anyone can create objects in schema public. To stop that
--     (affects all roles):  REVOKE CREATE ON SCHEMA public FROM PUBLIC;   -- the default since 15
--   * CONNECT and TEMP on every database. Revoke them per database if you need to.
