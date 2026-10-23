# Home Assistant history archive

Home Assistant's recorder keeps **30 days** of state history and logbook in its
live database (`purge_keep_days: 30` in `configuration.yaml` on the HA config
volume). Anything older lives in an archive on the NAS. The archive is meant for
agents and offline analysis, not for HA's own UI.

| Tier | Where | Kept | Format |
|---|---|---|---|
| Live | HA recorder (SQLite on the HA volume) | 30 days | HA UI, REST and WebSocket APIs |
| Daily | NAS `backup` share, `home-assistant-archive/` | 12 months | Uncompressed JSONL, one directory per local day |
| Monthly | same folder | indefinitely | Parquet (zstd), one file per kind per month |
| Long-term statistics | HA recorder | forever (HA default) | Hourly mean/min/max/sum per numeric sensor, back to 2021 |

For numeric trends ("average office temperature in March"), HA's long-term
statistics already cover the full history. Use the archive for individual
state changes and logbook activity.

## Layout

```
home-assistant-archive/
  2026/
    10/
      19/
        history.jsonl     every state change that day
        logbook.jsonl     the logbook, as the HA UI shows it
      history.parquet     whole month, written on the 2nd of the next month
      logbook.parquet
```

Days are **local** (America/New_York) calendar days. A day directory only
exists once `history.jsonl` is complete; files are written to `*.partial` and
renamed.

### history.jsonl

One HA state object per line, sorted by `last_updated`:

```json
{"entity_id":"binary_sensor.kitchen_motion","state":"on","attributes":{"device_class":"motion","friendly_name":"Kitchen Motion"},"last_changed":"2026-10-19T11:34:40.504215+00:00","last_updated":"2026-10-19T11:34:40.504215+00:00"}
```

Timestamps are UTC ISO-8601. `attributes` is the full attribute set at that
change. The state an entity already had at midnight is not repeated; it is in
the previous day's file.

### logbook.jsonl

One `/api/logbook` entry per line. Always present: `when`, `name`. Usually
present: `entity_id`, `state`, or `message` + `domain` for non-state events.
`context_*` fields say what caused the entry (for example
`context_name: "Button - Cadens Nightstand"`, `context_event_type:
"automation_triggered"`, `context_user_id`).

### Parquet

`history.parquet`: `entity_id, state, attributes (JSON), last_changed, last_updated`
(timestamps are TIMESTAMPTZ).
`logbook.parquet`: `when, name, message, entity_id, state, domain, icon, source,
attributes (JSON), context_*`.

## Querying

Plain text, no tooling:

```sh
rg '"entity_id":"lock.front_door"' home-assistant-archive/2026/10/*/history.jsonl
rg -l 'DISMISS_LAUNDRY' home-assistant-archive/2026/*/*/logbook.jsonl
```

DuckDB over Parquet (fast; only reads the months it needs):

```sql
-- How often did the garage door open per month?
SELECT date_trunc('month', last_updated) AS month, count(*)
FROM read_parquet('home-assistant-archive/*/*/history.parquet')
WHERE entity_id = 'cover.garage_door' AND state = 'open'
GROUP BY ALL ORDER BY month;

-- What did automations do to the lights last week? (daily JSONL, current month)
SELECT "when", name, state, context_name
FROM read_json('home-assistant-archive/2026/10/*/logbook.jsonl', format = 'newline_delimited')
WHERE entity_id LIKE 'light.%' AND context_event_type = 'automation_triggered';
```

For JSONL, read `attributes` as JSON rather than letting DuckDB infer a struct:
`read_json(..., columns = {'entity_id': 'VARCHAR', 'state': 'VARCHAR', 'attributes': 'JSON', 'last_changed': 'TIMESTAMPTZ', 'last_updated': 'TIMESTAMPTZ'})`.

## How it is produced

`kubernetes/apps/home/ha-archive/` (namespace `home`). Two CronJobs mount the
NAS share and run stock `python:*-slim` with the scripts from a ConfigMap:

- **`ha-archive-export`**, daily at 01:30 local (`export.py`). Reads
  `/api/history/period` (all entities, in batches of 150) and `/api/logbook` for
  each missing day in the last 28, writes the day, then deletes day directories
  older than 365 days. Missed nights backfill themselves while the recorder
  still has the data. Days the recorder doesn't cover from midnight are skipped
  rather than written partial.
- **`ha-archive-rollup`**, on the 2nd at 03:15 (`rollup.py`). Installs a pinned
  `duckdb` (Renovate-tracked) and writes each finished month's Parquet. A month
  is rebuilt if a day in it is newer than its Parquet, but only within the last
  3 months, so a rebuild can never run over days that have been pruned.

Both report to the Healthchecks "Jobs" project (`ha-archive-export`,
`ha-archive-rollup`). The HA token is a dedicated long-lived token
("ha-archive (home-ops CronJob)") in the 1P item `ha-archive`, field `ha_token`.

Size: about 15 MB/day of JSONL (~5.5 GB for the 12 months kept) and about
0.6 MB/day of Parquet (~220 MB/year).

### Limits

- The entity list comes from `/api/states` at run time. An entity deleted before
  its day is exported is missing from that day's history (its logbook entries
  are still there).
- Recorder-excluded entities (see `recorder: exclude:`) are never recorded, so
  never archived.
- The archive starts with the oldest full day the recorder still held on the
  first run (around 2026-10-11). Earlier history was already purged.
