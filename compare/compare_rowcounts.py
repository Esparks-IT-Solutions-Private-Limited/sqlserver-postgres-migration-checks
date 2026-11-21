#!/usr/bin/env python3
"""Compare per-table row counts from a SQL Server source and a PostgreSQL target.

Input: two CSV files with rows "schema,table,row_count" (no header needed), produced by
rowcounts-sqlserver.sql and rowcounts-postgres.sql. Standard library only.

    python3 compare_rowcounts.py source.csv target.csv --snake-case --schema-map dbo=public

Exit code: 0 when every source table is on the target with the same count, 1 when at
least one isn't, and 2 when a file has no table rows (an export that failed must never
pass), so it can gate a cutover script. Counts only prove that the numbers match; pair them with
key and value checks before you switch over.
"""
import argparse
import csv
import re
import sys


def snake(name: str) -> str:
    """PascalCase / camelCase → snake_case (OrderItems → order_items, HTTPLog → http_log)."""
    s = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    return s.replace("-", "_").replace(" ", "_").lower()


def load(path):
    counts = {}
    with open(path, newline="", encoding="utf-8-sig") as f:
        for row in csv.reader(f):
            row = [c.strip() for c in row]
            if len(row) < 3 or not row[2].lstrip("-").isdigit():
                continue  # headers, blank lines, sqlcmd footers
            counts[(row[0], row[1])] = int(row[2])
    return counts


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("source", help="CSV from rowcounts-sqlserver.sql")
    ap.add_argument("target", help="CSV from rowcounts-postgres.sql")
    ap.add_argument("--snake-case", action="store_true", help="the target uses snake_case names")
    ap.add_argument("--schema-map", action="append", default=[], metavar="SRC=DST",
                    help="map a source schema to a target schema, e.g. dbo=public (repeatable)")
    a = ap.parse_args()

    schema_map = {}
    for m in a.schema_map:
        if "=" not in m:
            ap.error(f"--schema-map expects SRC=DST, got {m!r}")
        k, v = m.split("=", 1)
        schema_map[k.lower()] = v
    src, tgt = load(a.source), load(a.target)
    for name, rows in (("source", src), ("target", tgt)):
        if not rows:
            print(f"No table rows read from the {name} file: check that its export ran without errors.",
                  file=sys.stderr)
            sys.exit(2)
    tgt_lower = {(s.lower(), t.lower()): n for (s, t), n in tgt.items()}

    def target_key(schema, table):
        schema = schema_map.get(schema.lower(), schema)
        table = snake(table) if a.snake_case else table
        return schema.lower(), table.lower()

    problems = 0
    width = max((len(f"{s}.{t}") for s, t in src), default=10)
    print(f"{'source table':<{width}}  {'source':>14}  {'target':>14}  result")
    for (schema, table), n in sorted(src.items()):
        m = tgt_lower.get(target_key(schema, table))
        if m is None:
            result, shown = "MISSING on target", "-"
        elif m == n:
            result, shown = "ok", f"{m:,}"
        else:
            result, shown = f"DIFF {m - n:+,}", f"{m:,}"
        problems += result != "ok"
        print(f"{schema + '.' + table:<{width}}  {n:>14,}  {shown:>14}  {result}")

    matched = {target_key(s, t) for s, t in src}
    extra = sorted(k for k in tgt_lower if k not in matched)
    for s, t in extra:
        print(f"(target only) {s}.{t}")
    print(f"\n{len(src)} source tables, {problems} with a problem, {len(extra)} only on the target.")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
