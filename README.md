# SQL Server → PostgreSQL migration checks

Small checks and setup scripts for moving a database from SQL Server to PostgreSQL: read-only checks **before** you start, least-privilege accounts for the move, and a row-count comparison **before** you switch over.

Plain SQL plus one Python script (standard library only). Nothing to install.

| Step | File | What it does |
|---|---|---|
| Before | [`sqlserver/01-readiness-check.sql`](sqlserver/01-readiness-check.sql) | Read-only. Edition and SQL Server Agent, collation, CDC status, tables without a primary key, columns that need a decision in PostgreSQL, objects that need rewriting |
| Setup | [`sqlserver/02-cdc-reader-least-privilege.sql`](sqlserver/02-cdc-reader-least-privilege.sql) | A login that can read the source and its change data, and cannot write or change CDC settings |
| Setup | [`postgres/01-target-least-privilege.sql`](postgres/01-target-least-privilege.sql) | A role that can write to one target schema only: no superuser, no write access to other schemas, can't create databases or roles |
| Before cutover | [`compare/`](compare/) | Exact row counts on both sides, compared table by table, with an exit code you can gate a script on |

## 1. Readiness check

```sh
sqlcmd -b -S your-server -d YourDb -U your-user -i sqlserver/01-readiness-check.sql -W -s"|"
```

It changes nothing. Among other things it flags:

- **Tables without a primary key.** They copy fine, but ongoing changes can't be applied as keyed upserts.
- **Types and columns that need a decision:** `sql_variant`, `hierarchyid`, `geography`/`geometry`, computed columns, `rowversion`, `money`, `tinyint`, user-defined types.
- **Precision:** `datetime2(7)`, `time(7)` and `datetimeoffset(7)` carry 100 ns; PostgreSQL keeps microseconds. `datetimeoffset` keeps the instant but not the original offset.
- **Case-insensitive collations.** SQL Server usually compares text case-insensitively; PostgreSQL doesn't.
- **Objects that need work:** views, procedures, functions, triggers, and identity columns (reset each sequence after the load).

## 2. Least-privilege accounts

```sh
# SQL Server source: the password is passed in, never saved in the file
sqlcmd -b -S src -U admin -i sqlserver/02-cdc-reader-least-privilege.sql \
       -v SOURCE_DB="YourDb" CDC_APP_PASSWORD="a-long-random-password"

# PostgreSQL target: replace <TARGET_DB> and <TARGET_SCHEMA> in the file first
psql -v ON_ERROR_STOP=1 -d your_target_db -f postgres/01-target-least-privilege.sql
psql -d your_target_db -c '\password migration_app'
```

Run both as an administrator. Enabling CDC on the source stays a one-time DBA step; the reader login can't do it. On Azure SQL Database, use a contained user instead (see the note in the script).

## 3. Row counts before cutover

```sh
# Source (SQL Server)
sqlcmd -b -S src -d YourDb -U user -i compare/rowcounts-sqlserver.sql -s"," -W -h -1 -f o:65001 -o source.csv
# Target (PostgreSQL, psql 12 or later)
psql -v ON_ERROR_STOP=1 -h tgt -d target -U user -t --csv -f compare/rowcounts-postgres.sql -o target.csv

python3 compare/compare_rowcounts.py source.csv target.csv --schema-map dbo=public
```

```
source table                    source          target  result
dbo.addresses                    1,333           1,333  ok
dbo.orders                       2,000           1,997  DIFF -3
dbo.suppliers                       25               -  MISSING on target
(target only) public.audit_log

3 source tables, 2 with a problem, 1 only on the target.
```

| Exit code | Meaning |
|---|---|
| `0` | Every source table is on the target with the same count |
| `1` | At least one table is missing or has a different count |
| `2` | A file had no table rows, so an export probably failed. It never counts as a pass |

Use `--snake-case` if the target renamed `OrderItems` to `order_items`, and `--schema-map` (repeatable) for schema renames.

The counting queries run `COUNT(*)` on every table, so run them off-peak or on a replica, and stop writes to the source (or let replication catch up) first. Matching counts are a first check, not proof: compare keys and sampled values too before you switch over.

## Tested with

SQL Server 2022 and PostgreSQL 16, on a sample database with ten tables and the awkward types above. The comparison script has unit tests that run on every push.

## About

Maintained by [Esparks IT Solutions](https://www.esparksit.com). These checks come from our database migration work. For whole migrations (initial load, live change capture while the source stays in use, integrity checks and a gated cutover) see our [Database Migration Platform](https://www.esparksit.com/portfolio/database-migration-platform) and its [walkthrough video](https://youtu.be/-FdrK3C4HMU).

Issues and pull requests are welcome. MIT licensed.
