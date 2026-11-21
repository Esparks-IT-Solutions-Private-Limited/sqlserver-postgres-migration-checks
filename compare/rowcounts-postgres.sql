-- Exact row count of every user table, as schema,table,rows. Partitioned tables are
-- counted once at the parent (their partitions are not listed separately).
-- Read-only; runs count(*) on each table. Needs psql 12+ for --csv. For example:
--   psql -v ON_ERROR_STOP=1 -h host -d target -U user -t --csv -f rowcounts-postgres.sql -o target.csv
SELECT n.nspname AS schema_name,
       c.relname AS table_name,
       (xpath('/row/n/text()',
              query_to_xml(format('SELECT count(*) AS n FROM %I.%I', n.nspname, c.relname),
                           false, true, '')))[1]::text::bigint AS row_count
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p')
  AND NOT c.relispartition
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
  AND n.nspname NOT LIKE 'pg_toast%'
  AND n.nspname NOT LIKE 'pg_temp%'
ORDER BY 1, 2;
