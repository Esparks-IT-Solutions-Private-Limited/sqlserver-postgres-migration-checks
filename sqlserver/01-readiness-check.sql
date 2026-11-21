/*
  SQL Server → PostgreSQL migration readiness check
  -------------------------------------------------
  Read-only. Run it in the SOURCE database (USE [YourDb]; first) as a login that can
  read the catalog views. It changes nothing. The SQL Server Agent check also needs
  VIEW SERVER STATE; without it, that one check prints a note and the rest still runs.

  Sections:
    1. Server: version, edition, SQL Server Agent
    2. Database: recovery model, CDC enabled
    3. Tables: rows, size, primary key, CDC tracking
    4. Columns that need a decision in PostgreSQL
    5. Objects that are not plain tables (views, procedures, triggers, ...)

  Part of https://github.com/Esparks-IT-Solutions-Private-Limited/sqlserver-postgres-migration-checks
*/
SET NOCOUNT ON;

PRINT '== 1. Server ==';
SELECT
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(32))  AS product_version,
    CAST(SERVERPROPERTY('ProductLevel')   AS nvarchar(32))  AS product_level,
    CAST(SERVERPROPERTY('Edition')        AS nvarchar(128)) AS edition,
    CASE WHEN CAST(SERVERPROPERTY('EngineEdition') AS int) = 4
         THEN 'NO: Express edition has no change data capture'
         ELSE 'yes (Standard edition needs 2016 SP1 or later)' END AS cdc_supported_by_edition;

-- Change data capture needs SQL Server Agent running (it runs the capture and clean-up jobs).
-- Azure SQL Database has no Agent; CDC uses its own scheduler there.
BEGIN TRY
    EXEC (N'SELECT servicename, status_desc, startup_type_desc
            FROM sys.dm_server_services
            WHERE servicename LIKE N''SQL Server Agent%'';');
END TRY
BEGIN CATCH
    PRINT 'SQL Server Agent status not shown: it needs VIEW SERVER STATE (or this is Azure SQL Database).';
END CATCH;

PRINT '== 2. Database ==';
SELECT
    d.name                     AS database_name,
    d.recovery_model_desc      AS recovery_model,
    d.compatibility_level,
    d.collation_name,
    CASE WHEN d.collation_name LIKE N'%[_]CI[_]%' OR d.collation_name LIKE N'%[_]CI'
         THEN 'Case-insensitive: PostgreSQL compares case-sensitively. Check unique keys, joins and lookups (citext or a nondeterministic ICU collation can help)'
         ELSE '' END            AS collation_note,
    d.is_cdc_enabled,
    CASE WHEN d.is_cdc_enabled = 0
         THEN 'Enable once as a DBA: EXEC sys.sp_cdc_enable_db;' ELSE '' END AS action
FROM sys.databases AS d
WHERE d.database_id = DB_ID();

PRINT '== 3. Tables ==';
-- Tables without a primary key copy fine, but ongoing changes cannot be applied as
-- keyed upserts: add a key (or pick a unique index) before streaming them.
SELECT
    s.name                                                    AS schema_name,
    t.name                                                    AS table_name,
    (SELECT SUM(p.rows) FROM sys.partitions AS p
      WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)) AS approx_rows,
    (SELECT CAST(SUM(a.total_pages) * 8 / 1024.0 AS decimal(18, 1))
       FROM sys.partitions AS p
       JOIN sys.allocation_units AS a ON a.container_id = p.partition_id
      WHERE p.object_id = t.object_id)                        AS size_mb,
    CASE WHEN EXISTS (SELECT 1 FROM sys.key_constraints k
                      WHERE k.parent_object_id = t.object_id AND k.type = 'PK')
         THEN 'yes' ELSE 'NO' END                             AS has_primary_key,
    CASE WHEN t.is_tracked_by_cdc = 1 THEN 'yes' ELSE 'no' END AS cdc_tracked
FROM sys.tables AS t
JOIN sys.schemas AS s ON s.schema_id = t.schema_id
WHERE t.is_ms_shipped = 0
  AND s.name <> N'cdc'
ORDER BY approx_rows DESC;

PRINT '== 4. Columns that need a decision in PostgreSQL ==';
SELECT
    s.name  AS schema_name,
    t.name  AS table_name,
    c.name  AS column_name,
    CASE WHEN c.is_computed = 1 THEN 'computed' ELSE ty.name END
        + CASE WHEN ty.name IN (N'datetime2', N'datetimeoffset', N'time') THEN '(' + CAST(c.scale AS varchar(2)) + ')' ELSE '' END
        AS sql_server_type,
    CASE
        WHEN c.is_computed = 1                  THEN 'Computed column: recreate as GENERATED ALWAYS AS (...) STORED, or copy the values as a plain column'
        WHEN ty.name = N'sql_variant'           THEN 'No PostgreSQL equivalent: store as text or jsonb, or split by type'
        WHEN ty.name = N'hierarchyid'           THEN 'No equivalent: store the string form (ToString()) or use the ltree extension'
        WHEN ty.name IN (N'geography', N'geometry') THEN 'Needs PostGIS, or store as WKT text'
        WHEN ty.name IN (N'text', N'ntext', N'image') THEN 'Deprecated type: maps to text / bytea'
        WHEN ty.name = N'datetimeoffset'        THEN 'Maps to timestamptz: the instant is kept, the original offset is not'
                                                     + CASE WHEN c.scale = 7 THEN '; the 7th fractional digit is rounded or truncated to microseconds, depending on the loader' ELSE '' END
        WHEN ty.name IN (N'datetime2', N'time') AND c.scale = 7
                                                THEN 'PostgreSQL keeps microseconds (6 digits): the 7th digit is rounded or truncated, depending on the loader'
        WHEN ty.name IN (N'money', N'smallmoney') THEN 'Prefer numeric(19,4) over PostgreSQL money'
        WHEN ty.name = N'tinyint'               THEN 'No tinyint: use smallint (0-255 fits)'
        WHEN ty.name = N'xml'                   THEN 'Maps to xml; check any XQuery used by the application'
        WHEN ty.name IN (N'timestamp', N'rowversion') THEN 'Row version, not a date: usually bytea or dropped'
        WHEN ty.is_user_defined = 1             THEN 'User-defined type: map to its base type or a PostgreSQL domain'
    END AS note
FROM sys.columns AS c
JOIN sys.tables  AS t  ON t.object_id = c.object_id
JOIN sys.schemas AS s  ON s.schema_id = t.schema_id
JOIN sys.types   AS ty ON ty.user_type_id = c.user_type_id
WHERE t.is_ms_shipped = 0
  AND s.name <> N'cdc'
  AND (   c.is_computed = 1
       OR ty.is_user_defined = 1
       OR ty.name IN (N'sql_variant', N'hierarchyid', N'geography', N'geometry', N'text', N'ntext', N'image',
                      N'datetimeoffset', N'money', N'smallmoney', N'tinyint', N'xml', N'timestamp')
       OR (ty.name IN (N'datetime2', N'time') AND c.scale = 7))
ORDER BY s.name, t.name, c.column_id;

PRINT '== 5. Objects that are not plain tables ==';
-- Views can usually be translated; procedures, functions and triggers need someone to
-- rewrite them in PL/pgSQL. Identity columns move with the data, but each sequence must be
-- reset (setval) after the load so new rows don't collide.
SELECT o.type_desc AS object_type, COUNT(*) AS how_many
FROM sys.objects AS o
JOIN sys.schemas AS s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND s.name <> N'cdc'
  AND o.type IN ('V', 'P', 'FN', 'IF', 'TF', 'TR', 'SO', 'SN')
GROUP BY o.type_desc
UNION ALL
SELECT 'IDENTITY_COLUMN', COUNT(*)
FROM sys.identity_columns AS ic
JOIN sys.objects AS o ON o.object_id = ic.object_id
WHERE o.is_ms_shipped = 0 AND o.type = 'U'
ORDER BY object_type;
