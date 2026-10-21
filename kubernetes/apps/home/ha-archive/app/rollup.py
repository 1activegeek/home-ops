"""Roll each finished month of daily JSONL into Parquet, next to the days.

    <ARCHIVE_DIR>/YYYY/MM/history.parquet
    <ARCHIVE_DIR>/YYYY/MM/logbook.parquet

A month is (re)built when its Parquet is missing, or when a day file in it is
newer than the Parquet (a late backfill). Months older than REBUILD_MONTHS are
never rebuilt: export.py prunes their JSONL after a year, and a rebuild then
would silently drop the pruned days. Parquet files are kept indefinitely.

Needs the duckdb Python package.
"""

import datetime as dt
import glob
import os
import sys

import duckdb

ARCHIVE_DIR = os.environ.get("ARCHIVE_DIR", "/archive")
REBUILD_MONTHS = int(os.environ.get("REBUILD_MONTHS", "3"))
MEMORY_LIMIT = os.environ.get("DUCKDB_MEMORY_LIMIT", "1GB")
TEMP_DIR = os.environ.get("DUCKDB_TEMP_DIR", "/tmp/duckdb")

# Fixed schemas: HA attributes vary per entity, so keep them as JSON instead of
# letting DuckDB infer a struct. Keys not listed here are dropped.
COLUMNS = {
    "history": {
        "entity_id": "VARCHAR",
        "state": "VARCHAR",
        "attributes": "JSON",
        "last_changed": "TIMESTAMPTZ",
        "last_updated": "TIMESTAMPTZ",
    },
    "logbook": {
        "when": "TIMESTAMPTZ",
        "name": "VARCHAR",
        "message": "VARCHAR",
        "entity_id": "VARCHAR",
        "state": "VARCHAR",
        "domain": "VARCHAR",
        "icon": "VARCHAR",
        "source": "VARCHAR",
        "attributes": "JSON",
        "context_id": "VARCHAR",
        "context_user_id": "VARCHAR",
        "context_event_type": "VARCHAR",
        "context_domain": "VARCHAR",
        "context_service": "VARCHAR",
        "context_entity_id": "VARCHAR",
        "context_entity_id_name": "VARCHAR",
        "context_name": "VARCHAR",
        "context_message": "VARCHAR",
        "context_source": "VARCHAR",
        "context_state": "VARCHAR",
    },
}
ORDER = {"history": "last_updated, entity_id", "logbook": '"when"'}


def sql_str(value):
    return "'" + value.replace("'", "''") + "'"


def build(con, month_dir, kind, files):
    out = os.path.join(month_dir, f"{kind}.parquet")
    tmp = out + ".partial"
    cols = ", ".join(f"{sql_str(k)}: {sql_str(v)}" for k, v in COLUMNS[kind].items())
    src = "[" + ", ".join(sql_str(f) for f in files) + "]"
    con.execute(
        f"COPY (SELECT * FROM read_json({src}, format='newline_delimited', "
        f"columns={{{cols}}}) ORDER BY {ORDER[kind]}) "
        f"TO {sql_str(tmp)} (FORMAT parquet, COMPRESSION zstd)"
    )
    rows = con.execute(f"SELECT count(*) FROM read_parquet({sql_str(tmp)})").fetchone()[0]
    os.replace(tmp, out)
    return rows


def main():
    today = dt.date.today()
    this_month = (today.year, today.month)
    oldest = today.replace(day=1)
    for _ in range(REBUILD_MONTHS):
        oldest = (oldest - dt.timedelta(days=1)).replace(day=1)

    con = duckdb.connect(config={"memory_limit": MEMORY_LIMIT, "temp_directory": TEMP_DIR})
    failed = 0
    for month_dir in sorted(glob.glob(os.path.join(ARCHIVE_DIR, "[0-9]" * 4, "[0-9]" * 2))):
        year, month = int(month_dir[-7:-3]), int(month_dir[-2:])
        if (year, month) >= this_month:
            continue  # still being written
        for kind in COLUMNS:
            files = sorted(glob.glob(os.path.join(month_dir, "[0-9][0-9]", f"{kind}.jsonl")))
            if not files:
                continue
            out = os.path.join(month_dir, f"{kind}.parquet")
            if os.path.exists(out):
                newest = max(os.path.getmtime(f) for f in files)
                if newest <= os.path.getmtime(out) or dt.date(year, month, 1) < oldest:
                    continue
            try:
                rows = build(con, month_dir, kind, files)
            except Exception as exc:
                failed += 1
                print(f"FAILED {year}-{month:02d} {kind}: {exc!r}", file=sys.stderr)
                continue
            size = os.path.getsize(out) / 1048576
            print(f"built {year}-{month:02d} {kind}.parquet: {len(files)} days, "
                  f"{rows} rows, {size:.1f} MiB")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
