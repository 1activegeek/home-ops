"""Archive Home Assistant history and logbook to the NAS as daily JSONL.

Writes one directory per local calendar day:

    <ARCHIVE_DIR>/YYYY/MM/DD/history.jsonl   one state change per line
    <ARCHIVE_DIR>/YYYY/MM/DD/logbook.jsonl   one logbook entry per line

Every run fills in any missing day from the last BACKFILL_DAYS (the live
recorder keeps 30), so a missed run heals itself the next night. Day
directories older than RETENTION_DAYS are deleted; the monthly Parquet files
written by rollup.py are kept.

Uses the REST API rather than the SQLite file, so it does not depend on the
recorder schema and never touches the live database.

Stdlib only. Local days follow TZ, which may be a POSIX rule string so the
image needs no tzdata.
"""

import datetime as dt
import json
import os
import shutil
import sys
import time
import urllib.parse
import urllib.request

HA_URL = os.environ["HA_URL"].rstrip("/")
HA_TOKEN = os.environ["HA_TOKEN"]
ARCHIVE_DIR = os.environ.get("ARCHIVE_DIR", "/archive")
BACKFILL_DAYS = int(os.environ.get("BACKFILL_DAYS", "28"))
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "365"))
# The history API needs an explicit entity list; batch it to keep URLs short.
BATCH = 150

time.tzset()


def get(path, params=None):
    url = HA_URL + path
    if params:
        url += "?" + urllib.parse.urlencode(params, safe=",")
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + HA_TOKEN})
    with urllib.request.urlopen(req, timeout=300) as resp:
        return json.load(resp)


def local_midnight(day):
    """UTC datetime of local 00:00 on `day`, honouring DST."""
    epoch = time.mktime((day.year, day.month, day.day, 0, 0, 0, 0, 0, -1))
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc)


def parse_ts(value):
    return dt.datetime.fromisoformat(value)


def day_dir(day):
    return os.path.join(ARCHIVE_DIR, f"{day:%Y}", f"{day:%m}", f"{day:%d}")


def write_jsonl(path, rows):
    tmp = path + ".partial"
    with open(tmp, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")))
            fh.write("\n")
    os.replace(tmp, path)


def export_day(day, entity_ids):
    start, end = local_midnight(day), local_midnight(day + dt.timedelta(days=1))
    window = {"end_time": end.isoformat()}
    start_path = urllib.parse.quote(start.isoformat())

    history, start_rows = [], 0
    for i in range(0, len(entity_ids), BATCH):
        params = dict(window, significant_changes_only="0",
                      filter_entity_id=",".join(entity_ids[i:i + BATCH]))
        for series in get(f"/api/history/period/{start_path}", params):
            for row in series:
                # The API prepends each entity's state as of `start`, stamped
                # exactly `start`. It belongs to an earlier day; drop it.
                if parse_ts(row["last_updated"]) > start:
                    history.append(row)
                else:
                    start_rows += 1
    if not start_rows:
        # No entity had a recorded state at midnight: the recorder's data
        # begins later than this day does. Writing it would leave an empty or
        # partial day that looks complete, so leave it out.
        return None
    history.sort(key=lambda r: (r["last_updated"], r["entity_id"]))

    logbook = get(f"/api/logbook/{start_path}", window)

    out = day_dir(day)
    os.makedirs(out, exist_ok=True)
    write_jsonl(os.path.join(out, "logbook.jsonl"), logbook)
    # history.jsonl last: its presence marks the day as complete.
    write_jsonl(os.path.join(out, "history.jsonl"), history)
    return len(history), len(logbook)


def prune(today):
    cutoff = today - dt.timedelta(days=RETENTION_DAYS)
    for year in sorted(os.listdir(ARCHIVE_DIR)):
        if not year.isdigit():
            continue
        for month in sorted(os.listdir(os.path.join(ARCHIVE_DIR, year))):
            mdir = os.path.join(ARCHIVE_DIR, year, month)
            if not (month.isdigit() and os.path.isdir(mdir)):
                continue
            for d in sorted(os.listdir(mdir)):
                ddir = os.path.join(mdir, d)
                if d.isdigit() and os.path.isdir(ddir):
                    if dt.date(int(year), int(month), int(d)) < cutoff:
                        shutil.rmtree(ddir)
                        print(f"pruned {year}-{month}-{d} (older than {RETENTION_DAYS}d)")


def main():
    today = dt.date.today()
    os.makedirs(ARCHIVE_DIR, exist_ok=True)
    entity_ids = sorted(s["entity_id"] for s in get("/api/states"))
    print(f"{len(entity_ids)} entities; checking {BACKFILL_DAYS} days before {today}")

    failed = 0
    for n in range(BACKFILL_DAYS, 0, -1):
        day = today - dt.timedelta(days=n)
        if os.path.exists(os.path.join(day_dir(day), "history.jsonl")):
            continue
        t0 = time.monotonic()
        try:
            counts = export_day(day, entity_ids)
        except Exception as exc:  # keep going; one bad day must not block the rest
            failed += 1
            print(f"FAILED {day}: {exc!r}", file=sys.stderr)
            continue
        if counts is None:
            print(f"skipped {day}: before the recorder's oldest data")
            continue
        h, lb = counts
        print(f"exported {day}: {h} states, {lb} logbook entries "
              f"in {time.monotonic() - t0:.1f}s")

    prune(today)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
