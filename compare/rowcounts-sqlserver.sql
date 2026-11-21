/*
  Exact row count of every user table, as schema,table,rows.
  Read-only, but it runs COUNT(*) on each table: on a busy server, run it off-peak or
  against a replica. Works on SQL Server 2016 and later. Export to CSV, for example:
    sqlcmd -b -S host -d YourDb -U user -i rowcounts-sqlserver.sql -s"," -W -h -1 -f o:65001 -o source.csv
*/
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;  -- needed by the XML method below; sqlcmd turns it off by default
DECLARE @sql nvarchar(max) = STUFF((
    SELECT N' UNION ALL SELECT N' + QUOTENAME(s.name, '''') + N' AS schema_name, N' + QUOTENAME(t.name, '''')
         + N' AS table_name, COUNT_BIG(*) AS row_count FROM ' + QUOTENAME(s.name) + N'.' + QUOTENAME(t.name)
    FROM sys.tables AS t
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE t.is_ms_shipped = 0 AND s.name <> N'cdc'
    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 11, N'');
IF @sql IS NOT NULL EXEC (@sql + N' ORDER BY schema_name, table_name');
