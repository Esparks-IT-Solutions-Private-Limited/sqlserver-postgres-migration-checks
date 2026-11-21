-- Least-privilege SQL Server login for reading a database with change data capture (CDC):
-- it can read the tables and their change data, and cannot write or change CDC settings.
--
-- Run as an administrator AFTER the database exists and CDC has been enabled on it (enabling
-- CDC is a one-time DBA step; this login must not be able to do it). Run it with sqlcmd and
-- pass the database and a password, so no password is ever saved in this file:
--   sqlcmd -b -S host -U admin -i sqlserver/02-cdc-reader-least-privilege.sql
--          -v SOURCE_DB="YourDb" CDC_APP_PASSWORD="a-long-random-password"
-- (In SSMS, turn on Query > SQLCMD Mode and set both with :setvar.)
--
-- Azure SQL Database has no server logins from a user database and no USE across databases:
-- connect to the database itself, create a contained user instead
--   CREATE USER [cdc_app] WITH PASSWORD = '...';
-- and run the grants below.

USE [master];
GO
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'cdc_app')
    CREATE LOGIN [cdc_app] WITH PASSWORD = N'$(CDC_APP_PASSWORD)', CHECK_POLICY = ON;
GO

USE [$(SOURCE_DB)];
GO
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'cdc_app')
    CREATE USER [cdc_app] FOR LOGIN [cdc_app];
GO

-- Read the source tables (for the initial copy). To narrow it, grant SELECT on specific
-- tables instead of db_datareader.
ALTER ROLE [db_datareader] ADD MEMBER [cdc_app];

-- Read the change data: SELECT and EXECUTE on the cdc schema (change tables and fn_cdc_* functions).
GRANT SELECT ON SCHEMA :: [cdc] TO [cdc_app];
GRANT EXECUTE ON SCHEMA :: [cdc] TO [cdc_app];
GRANT VIEW DATABASE STATE TO [cdc_app];

-- If capture instances were enabled with a gating role (@role_name), add the user to it:
--   ALTER ROLE [<cdc_role>] ADD MEMBER [cdc_app];

-- No writes and no schema changes, even if someone later adds the user to a wider role.
DENY INSERT, UPDATE, DELETE, ALTER TO [cdc_app];
GO
