# NZBGet → SABnzbd Migration Plan

Status: **planning / awaiting approval**. No cluster or arr changes made yet.
Discovery: 2026-09-02, from NZBGet 26.0 on the Synology (`10.0.3.2:10007`) via its unauthenticated
JSON-RPC API (`/jsonrpc/config`, `/listgroups`, `/history`) — no UI scraping required.
Revision 2 (2026-09-02): incorporates decisions on servers, priorities, local scratch storage, and a
split pre-stage/cutover phase.

---

## 1. Current state (verified, not assumed)

### NZBGet (Synology, outside the cluster)

| Item | Value |
|---|---|
| Version | 26.0 |
| Root (`MainDir`) | `/downloads` → **`/volume1/media/downloads`** (same NFS export the cluster already mounts) |
| Complete / Incomplete | `/downloads/complete`, `/downloads/incomplete` |
| News servers | 12 (see §3) — 360 total connections configured |
| Categories | `movies`, `movies-4k`, `tvshows`, `music`, `software`, `private` |
| RSS feeds | none |
| Post-processing | `nzbgeek-reporting.py` referenced in config but **the file does not exist** — dropped |
| Queue at discovery | 0 items |
| History | 150 items — 109 success, **41 `FAILURE/HEALTH` (27%)** |

### Cluster side

- `kubernetes/apps/media/sabnzbd/` **exists but is commented out** of `kubernetes/apps/media/kustomization.yaml`
  (alongside `plex` and `qbittorrent`). SABnzbd has never run; there is no PVC and no state to preserve.
- Existing HelmRelease already: app-template 5.0.1, image `ghcr.io/home-operations/sabnzbd:5.1.2`,
  UID 1027 / GID 100 (matches NFS ownership), Longhorn 1Gi `/config`, NFS `/volume1/media` → `/data/media`,
  internal route, ExternalSecret pulling `api_key` / `nzb_key` from the 1Password `sabnzbd` item.
- Sonarr / Radarr / Radarr4k all point at **NZBGet `10.0.3.2:10007`** with categories
  `tvshows` / `movies` / `movies-4k`, each with a remote path mapping keyed to host `10.0.3.2`.
- Prowlarr: 16 indexers (11 usenet, 5 torrent), full-sync to all three arrs, one download client (`nzbget`).
- Unpackerr points at `/data/media/downloads/complete/{sonarr,radarr,radarr4k}` — **these directories do not
  exist**; the real ones are `movies`, `tvshows`, `movies-4k`. Unpackerr has been a no-op.

### The single most important discovery

NZBGet's `/downloads` **is** `/volume1/media/downloads` — the same export SABnzbd already mounts at
`/data/media`. SABnzbd's `complete_dir` lands on byte-identical paths. So:

- Hardlinks / atomic moves into `/data/media/{movies,tvshows,movies4k}` keep working. No copy penalty.
- No data migration. Nothing to copy. The complete tree is reused in place.
- The arrs' remote path mappings are keyed by **host** `10.0.3.2`; the SABnzbd client's host will be
  `sabnzbd.media.svc.cluster.local`, so the mappings simply won't match it. They are inert rather than
  dangerous — cleaned up at cutover rather than being a cutover-blocking edit.

---

## 2. Target architecture

```
Prowlarr ──sync──▶ Sonarr / Radarr / Radarr4k ──nzb──▶ SABnzbd (media ns, in-cluster)
                                                            │
              ┌─────────────────────────────────────────────┤
              │ /config          Longhorn 1Gi   (SAB-owned, UI-writable, backed up)
              │ /downloads/incomplete  Longhorn 250Gi on longhorn-scratch  ← NEW, local SSD
              │ /data/media      NFS csi-driver-nfs PV, hard mount
              │                    └── downloads/complete/<category>  →  library
              └── watchdog sidecar + canary probes ──▶ halt on NFS loss
```

Deliberate departures from today:
- **Incomplete work moves off NFS onto local Longhorn SSD.** Par2 verify/repair and unpack — the write-
  amplifying phases — stay entirely local. Only the finished release crosses the NAS link, which is the
  same bytes that would have been written anyway. See §5c for sizing.
- SABnzbd unpacks natively with Direct Unpack on → **unpackerr becomes unnecessary** (retired in §8).
- Aggressive early-failure detection turned on from day one (§5d) — this is the 27% problem.
- NZBGet retired on the Synology after soak.

---

## 3. News servers — all 12 carried over, priorities preserved

**Decision (confirmed): keep all 12, keep the priority ordering exactly as it is.** The ordering is
intentional, not an accident: it is a *breadth-first* strategy. The ten smaller / bespoke / block accounts
sit at tier 0 and are tried first, because between them they reach articles the big providers don't carry.
The paid `Newshosting (Personal)` account sits at tier 3 as the reliable fallback, and `Tweak (free)` at
tier 4 provides the 4300-day deep-retention backfill. This deliberately spares the primary account's
capacity and maximises the chance of finding obscure content. NZBGet's `Level` maps 1:1 onto SABnzbd's
server `priority` (lower = tried first), so this transfers exactly.

| NZBGet # | Name | Host:Port | Conn | Priority | Optional | Retention |
|---|---|---|---|---|---|---|
| 3 | NewsDemon | news.newsdemon.com:**80** | 40 | 0 | yes | — |
| 5 | Usenet.farm | news4.usenet.farm:563 | 40 | 0 | yes | — |
| 7 | NewsGroupNinja | news.newsgroup.ninja:563 | 40 | 0 | yes | — |
| 10 | NewsGroup Direct | nl.newsgroupdirect.com:563 | 40 | 0 | yes | — |
| 4 | SuperNews | news.supernews.com:443 | 25 | 0 | yes | — |
| 8 | TweakNews | news.tweaknews.eu:563 | 20 | 0 | yes | — |
| 11 | Newshosting (2nd acct) | news.newshosting.com:443 | 20 | 0 | yes | — |
| 2 | AstraWeb | ssl-us.astraweb.com:443 | 15 | 0 | yes | — |
| 6 | UsenetServer-2 | news.usenetserver.com:443 | 10 | 0 | yes | — |
| 9 | EasyNews | secure.news.easynews.com:8000 | 10 | 0 | yes | — |
| 1 | **Newshosting (Personal)** | news.newshosting.com:443 | 60 | 3 | no | — |
| 12 | Tweak (newshosting free) | newshosting.tweaknews.eu:563 | 40 | 4 | no | 4300d |

**Correction from P1 testing:** `NewsDemon` is configured as port **80** with `Encryption=yes`, which
looks contradictory — 80 is the plaintext NNTP port. It was flagged as a fix in revision 2. Live testing
proved that wrong: NewsDemon genuinely serves **TLS on port 80** (plaintext on 80 times out, TLS on 80
authenticates, and 563 also works). The config is correct as written and is migrated unchanged.

### P1 connectivity test results (2026-09-02, TLS connect + `AUTHINFO` against each server)

**5 of 12 authenticate. 7 fail.** This is almost certainly the mechanism behind the 27% `FAILURE/HEALTH`
rate: seven of the ten tier-0 servers — the ones tried *first* — are dead, so every grab burns retries
against them before reaching a working provider.

| Server | Priority | Result |
|---|---|---|
| NewsDemon | 0 | ✅ OK (TLS on :80 confirmed) |
| Usenet.farm | 0 | ✅ OK |
| NewsGroupNinja | 0 | ✅ OK |
| **Newshosting (Personal)** | 3 | ✅ OK |
| **Tweak (newshosting free)** | 4 | ✅ OK |
| NewsGroup Direct | 0 | ❌ `502 Connection failure. Please contact technical support.` |
| SuperNews | 0 | ❌ `481 Invalid username or password` |
| TweakNews | 0 | ❌ `502 Authentication Failed` |
| Newshosting (2nd acct) | 0 | ❌ `502 Authentication Failed` |
| AstraWeb | 0 | ❌ `502 Authentication Failed` |
| UsenetServer-2 | 0 | ❌ `502 Authentication Failed` |
| EasyNews | 0 | ❌ `502 Authentication Failed` |

All 12 are migrated. The 7 failures ship with `enable = 0` and a note recording the exact error and test
date, so nothing is lost and any account you renew is a one-flag change. **The breadth-first strategy is
sound, but it is currently running on 3 working tier-0 servers, not 10** — worth knowing before judging
whether breadth is delivering.

---

## 4. Setting-by-setting mapping

| NZBGet | Value | SABnzbd equivalent | Target value |
|---|---|---|---|
| `MainDir` | `/downloads` | — | — |
| `InterDir` | `/downloads/incomplete` (NFS) | `download_dir` | **`/downloads/incomplete` (local Longhorn)** |
| `DestDir` | `/downloads/complete` | `complete_dir` | `/data/media/downloads/complete` (NFS, unchanged) |
| `NzbDir` | `/downloads/nzb` | `dirscan_dir` | `/data/media/downloads/nzb` |
| `QueueDir`/`TempDir` | `/downloads/{queue,tmp}` | internal `/config/admin` | SAB-managed, on Longhorn |
| `ScriptDir` | `/config/scripts` | `script_dir` | `/config/scripts` (empty — no scripts carried over) |
| `Unpack = yes` | | `enable_unrar`, `enable_7zip` | on |
| `DirectUnpack = no` | | `direct_unpack` | **on** (upgrade) |
| `UnpackCleanupDisk = yes` | | `cleanup_list`, `del_failed` | on |
| `ParCheck = auto` | | `quick_check` | on — par only when quick-check fails |
| `ParRepair = yes` | | `enable_par_repair` | on |
| `ParScan = extended` | | `par2_multicore` | on |
| `HealthCheck = delete` | | `fail_hopeless_jobs`, `abort_on_missing_files` | on — see §5d |
| `DupeCheck = yes` | | `no_dupes` / `no_series_dupes` | on |
| `ArticleCache = 200` MB | | `cache_limit` | `512M` (pod limit 2Gi) |
| `DiskSpace = 250` MB | | `download_free` | **`40G`** on the scratch volume (§5c) |
| — | | `complete_free` | `25G` on the NFS volume |
| `KeepHistory = 30` d | | `history_retention` | 30 days |
| `ExtCleanupDisk` | `.par2,.sfv,_brokenlog.txt` | `cleanup_list` | `par2,sfv,nfo,txt,srr` |
| `UnpackIgnoreExt` | `.cbr` | — | leave `.cbr` untouched |
| `DownloadRate = 0` | unlimited | `bandwidth_max` | unlimited |
| `Extensions` | `nzbgeek-reporting.py` | — | **dropped** (file doesn't exist) |

### Category mapping

| Category | SAB dir | Consumer | NZBGet aliases → SAB "indexer categories" |
|---|---|---|---|
| `movies` | `movies` | Radarr | `movies*, 2000, 2030, 2040, 2050` |
| `movies-4k` | `movies-4k` | Radarr4k | (none today) |
| `tvshows` | `tvshows` | Sonarr | `tv*, TV*` |
| `music` | `music` | manual | `audio*` |
| `software` | `software` | manual | `pc*` |
| `private` | `private` | manual | `xxx*, private*, 6000-6070` |

---

## 5. Design decisions

### 5a. Storage safeguard — "halt if the NAS goes away" (both mechanisms, as requested)

Three layers, defence in depth:

1. **Dedicated NFS PV with explicit mount options.** The current `persistence.media.type: nfs` uses an
   inline volume, which cannot set mount options. Replace with a `PersistentVolume`/`PVC` pair on the
   existing `csi-driver-nfs` with `mountOptions: [hard, nfsvers=4.1, timeo=600, retrans=2, nconnect=8]`.
   `hard` (not `soft`) is deliberate: `soft` returns IO errors mid-write and can corrupt a partially
   written file. Under `hard`, an outage *blocks* IO — which is exactly what the probes detect.

2. **Canary probes (the enforcement mechanism).** `startup`, `liveness` and `readiness` exec probes:
   ```
   test -f /data/media/.sabnzbd-canary && test -w /data/media/downloads/complete
   ```
   `timeoutSeconds: 10`, `periodSeconds: 30`, `failureThreshold: 2`. A hung `hard` mount makes the exec
   time out → probe failure → liveness restarts the pod and readiness pulls it from the Service, so the
   arrs stop queueing to it. With the NAS down the pod settles into CrashLoopBackOff — halted, as
   requested — and self-heals when storage returns.

3. **Watchdog sidecar (fast halt + explicit signal).** `shareProcessNamespace: true`; a busybox sidecar
   stats the canary every 15s and on failure logs a structured line and `SIGTERM`s the SABnzbd process
   immediately rather than waiting up to a full liveness cycle. Alloy already ships that log to Loki, and
   a `PrometheusRule` beside the app alerts to Matrix on (a) readiness 0 for 2m, (b) restarts > 3/15m.

Note the scratch volume changes the blast radius for the better: with incomplete work on local SSD, an NFS
outage can no longer corrupt an in-progress unpack — it can only block the final move.

### 5b. Config delivery — encrypted, declarative, *and* still editable in the UI

**Seed-and-merge**, not overwrite:

- The complete `sabnzbd.ini` lives as a single multi-line field (`config_seed`) on the existing 1Password
  **`sabnzbd`** item (confirmed OK to add), surfaced by the existing ExternalSecret. Nothing readable in
  git; encrypted at rest in 1Password; no SOPS exception needed (matches repo standard §5).
- An **init container** (reusing the SABnzbd image — python3 already present) runs every start:
  - `/config/sabnzbd.ini` **missing** → write the seed verbatim. First boot / PVC loss = full recovery.
  - `/config/sabnzbd.ini` **present** → merge only an explicitly declared *managed key set*
    (`[servers]`, `[categories]`, `api_key`, `nzb_key`, `download_dir`, `complete_dir`, `host_whitelist`)
    and leave every other key exactly as SABnzbd wrote it.
- **So UI edits persist.** Anything outside the managed set is never touched. Anything inside it is
  1Password-authoritative by design — you don't want a hand-edited news server drifting silently.
- **Round-trip:** `./scripts/sabnzbd-export-config.sh` dumps the running ini, strips volatile runtime keys, and
  writes it back to the 1Password field so the seed stays current.
- **Backup regardless:** a daily CronJob copies `sabnzbd.ini` + `/config/admin` to
  `/data/media/.backups/sabnzbd/`, 14-day retention, on top of the Longhorn recurring backup of the PVC.

### 5c. Local scratch sizing — how big does the incomplete volume need to be?

Measured from the last 150 completed jobs (924 GB total):

| Category | n | mean | median | p90 | p99 | max |
|---|---|---|---|---|---|---|
| movies | 30 | 21.0 G | 21.6 G | 37.7 G | 39.1 G | **39.1 G** |
| tvshows | 120 | 2.5 G | 2.9 G | 3.9 G | 6.4 G | 6.5 G |
| all | 150 | 6.2 G | 3.0 G | 24.1 G | 38.3 G | 39.1 G |

Your instinct was right — the tail is entirely 1080p BluRay remuxes at 32–39 GB. Sizing:

- **One worst-case job, RAR'd:** 39 G archive + 39 G extracted concurrently = **~80 G**
- **Post-processing overlap:** SAB post-processes job N while downloading job N+1 → **+40 G**
- **Queue burst headroom:** a couple more large movies or a full season pack queued → **+80 G**
- **`download_free` guard:** SAB pauses rather than filling the volume → **+40 G**

**Planned: a 250Gi PVC.** That is ~3× the single-job worst case and covers a realistic burst of
4–5 remuxes in flight, with SAB pausing (not failing) if it somehow gets deeper than that.

**Corrected at deploy time (P3): 150Gi.** The 250Gi volume would not schedule. Longhorn does not
schedule against raw free disk (~695 GB/node) but against
`storageMaximum - storageReserved - storageScheduled`, and the default 30% reservation (247 GB/node)
leaves only **223 / 186 / 100 GB** schedulable. 150Gi fits on two nodes, so the volume can still
reschedule if one is drained; 200Gi would have fit only `asgard-mpc-01` and pinned the workload there.
`download_free` drops 40G → 25G to match the smaller volume (leaving ~125 GB usable). The class sets
`allowVolumeExpansion: true`, so this grows in place once local SSD is expanded — no migration needed.

Practical effect at 150Gi: a single 39 GB RAR'd remux (≈80 GB with its extracted output) still has room
alongside a second job downloading. Back-to-back remuxes may briefly pause the queue on the free-space
guard, which is safe behaviour, not failure.

**On a new `longhorn-scratch` StorageClass — `numberOfReplicas: "1"`, backups excluded.** This matters:

- Both existing classes are `numberOfReplicas: 2`, which would make a 250Gi volume consume **500 GB** of
  cluster storage. Current Longhorn free-to-schedule capacity is 472 / 434 / 348 GB across the three
  nodes (824 GB each, 100% over-provisioning cap), so 500 GB would eat more than half the remaining
  headroom on two nodes.
- Replicating *scratch* data is pure waste — it doubles SSD write amplification on exactly the workload
  that churns hardest, to protect data that is definitionally re-downloadable.
- At replicas 1, the 250Gi lands on one node with room to spare. If that node dies, in-flight downloads
  are lost and SAB/the arrs re-grab. That is the correct trade for temp data.
- Backups excluded (`recurringJobSelector: exclude`) — backing up 250 GB of churning temp files to the
  NFS backup target would be actively harmful.

Net effect: 250 GB of cluster storage consumed, all par2 repair and unpack IO moved off the NAS link.

**Measured, not assumed** (2026-09-02, 1 GiB `dd` with `O_DIRECT` from pods in `media`):

| | write | read | rename |
|---|---|---|---|
| NFS (`/data/media`) | 105 MB/s | 112 MB/s | 5 ms |
| Longhorn (default class, 2 replicas) | 109 MB/s | 230 MB/s | — |

The NAS link is ~1GbE and already saturated; that is the binding constraint on the whole pipeline. Honest
accounting of what the move buys:

- **Per 39 GB RAR'd job**, bytes crossing the node NIC drop from **117 GB** (download write + unpack read +
  extracted write, all to NFS) to **39 GB** (only the final copy). History is 65 `SUCCESS/UNPACK` vs 44
  `SUCCESS/PAR`, so ~60% of jobs are RAR'd — blended, roughly a **55% cut in NAS traffic**, not 3×.
- **The regression:** the move to `complete` stops being a free 5 ms same-filesystem rename and becomes a
  real copy — **~6 min per 39 GB remux**, ~25 s per TV episode. For the ~40% of jobs that arrive unRAR'd,
  local scratch is a net loss on wall-clock.
- **The two arguments that actually carry it** are contention and latency, not throughput. Download bytes
  and NFS-write bytes share one 1GbE NIC, so writing incomplete to NFS caps effective download speed near
  half the link — and Direct Unpack makes that worse. Local scratch gives the download the whole link and
  stops unpack churn from stepping on Plex streams. Separately, par2 **repair** is random-access and
  latency-bound, where NFS is far worse than the friendly sequential `dd` gap above suggests.
- The 109 MB/s Longhorn write is on the **2-replica** default class and is network-bound by synchronous
  replication. `longhorn-scratch` at `numberOfReplicas: 1` writes to local disk only, so real scratch
  throughput should be well above that. **This is an inference, not a measurement** — verify directly in P3.

Decision (2026-09-02): proceed with local scratch; local storage expansion is planned independently.

### 5d. Early failure detection — turning on the 27% fix

41 of 150 history items are `FAILURE/HEALTH`. Promoted from "suggestion" into the migration itself:

| SABnzbd setting | Target | What it kills |
|---|---|---|
| `fail_hopeless_jobs` | on | jobs whose remaining articles can't reach the completion threshold — aborted immediately instead of downloading to a guaranteed par failure |
| `abort_on_missing_files` | on | jobs missing files outright at queue time |
| `req_completion_rate` | `100.2` | the health floor below which a job is declared dead |
| `unwanted_extensions` | `exe,com,bat,scr,vbs,lnk,pif` | malware-bait releases |
| `action_on_unwanted_extensions` | `2` (fail job) | ...and fails them rather than just warning |
| `pause_on_pwrar` | `2` (abort) | password-protected RARs — a common cause of a "successful" download that can never be unpacked |
| `enable_all_par` | off | don't pull par2 blocks you don't need |
| `propagation_delay` | `15` min | don't grab an NZB before the articles have finished propagating — a meaningful share of health failures |

The payoff is a job that would have failed anyway fails in seconds instead of after 39 GB, and the arrs
get the failure signal fast enough to try the next release while the search is still fresh.

---

## 6. Gaps

| # | Gap | Impact | Resolution |
|---|---|---|---|
| 1 | Unpackerr paths point at non-existent dirs | Silent no-op today | Retire unpackerr for usenet (SAB unpacks natively) — §8 |
| 2 | Prowlarr download client is `nzbget` | Prowlarr manual grabs break at cutover | SAB added disabled in P4, enabled in P5 |
| 3 | Stale remote path mappings on all 3 arrs | **Inert** — keyed to host `10.0.3.2`, won't match SAB | Delete during P5 cleanup |
| 4 | Some of the 12 servers may have expired credentials | Wasted connections, auth noise | Connectivity test in P1; failures ship disabled with a report |
| 5 | `NewsDemon` port 80 + `Encryption=yes` | Broken or downgraded TLS | Correct to 563 during seed generation |
| 6 | SAB runs UID 1027/GID 100, repo default is 65534 | `task validate:security-ctx` warning | Intentional (NFS ownership is 1027:users) — document the exception |
| 7 | `sabnzbd` ks is commented out of `apps/media/kustomization.yaml` | — | One-line uncomment in P2 |
| 8 | Arr/Prowlarr config is DB state, not GitOps | P4/P5 changes can't be expressed in Flux | Applied via idempotent scripts committed to `scripts/`, so they're reviewable and repeatable |

---

## 7. Phased plan

Branch: `1activegeek/nzbget-sabnzbd-conversion`. Never commit to main (Flux deploys instantly).

| Phase | Work | Gate |
|---|---|---|
| **P0** ✅ | Discovery — NZBGet config, arr/Prowlarr state, NFS layout, size distribution | done |
| **P1** ✅ | Connectivity-tested all 12 servers (5 pass / 7 fail); generated the `sabnzbd.ini` seed — priorities preserved, 7 dead servers disabled with notes, failure-detection baked in — validated every key against SABnzbd 5.1.2 source; pushed to 1Password `sabnzbd.config_seed` (6262 bytes) | done |
| **P2** ✅ | Manifests: `longhorn-scratch` SC, 250Gi scratch PVC, NFS PV/PVC with mount options, canary probes, watchdog sidecar, seed-merge init container, config-backup CronJob, PrometheusRule, uncomment ks. validated | **PR open — your approval** |
| **P3** | Deploy. Verify: pod healthy, per-server connection report, one manual test NZB → download → unpack → lands in `complete/<cat>`. Pull the NFS mount and confirm the pod halts and recovers. | verification report |
| **P4** | **Pre-stage, everything disabled.** Add SABnzbd as a download client to Sonarr, Radarr, Radarr4k and Prowlarr with `enable: false`, correct categories, and run each client's built-in **Test** to prove connectivity and auth. NZBGet stays enabled and untouched. Nothing changes behaviourally. | pre-flight report for you to validate |
| **P5** | 🔒 **CUTOVER — gated on your explicit go.** Flip `enable: true` on the four SAB clients, `enable: false` on the four NZBGet clients. Delete the stale remote path mappings. Retire unpackerr. | your word |
| **P6** | Soak 7 days, then retire NZBGet on the Synology and reclaim `/downloads/{queue,tmp,nzb,incomplete}` | — |

**P1–P4 are entirely non-disruptive.** NZBGet keeps running and keeps serving the arrs throughout. At the
end of P4 everything is wired, tested and sitting inert — the cutover in P5 is four enable-flag flips, and
rollback is flipping them back. Each phase's script is idempotent and committed, so P5 is a single command
whenever you're ready.

---

## 8. Suggested upgrades (post-merge follow-ons)

Ranked by value. Items 1–2 from revision 1 have been **promoted into the migration itself** (Direct Unpack
in §4, failure detection in §5d), and local scratch storage is now in scope (§5c).

1. **Retire unpackerr** *(agreed)*. Its only job was NZBGet's post-unpack gap, its paths are wrong, and SAB
   unpacks natively with Direct Unpack on. One fewer deployment, one fewer NFS mount.
2. **Metrics + dashboard.** `sabnzbd_exporter` → ServiceMonitor → Grafana dashboard ConfigMap, with alerts
   for queue stalled, zero servers connected, scratch volume filling, and `download_free` low.
3. **Matrix notifications** for failed jobs via the existing hookshot webhook (`docs/matrix-webhooks.md`) —
   pairs naturally with the §5d failure detection so you see *what* is failing, not just that it failed.
4. **Uptime Kuma monitor** on `sabnzbd.${SECRET_DOMAIN}` per the monitoring standard.
5. **Server health scoring.** Once metrics exist, per-server article-miss rates will show which of the ten
   tier-0 accounts are actually earning their place in the breadth-first strategy and which are just adding
   latency before the fallback. Data-driven, rather than pruning on assumption.
6. **Re-evaluate `nconnect`** after a week of real traffic — with unpack IO off the NAS the link profile
   changes, and the optimum may differ from the initial 8.
7. **Revisit `plex` and `qbittorrent`**, both also commented out of `apps/media/kustomization.yaml` —
   out of scope here, but worth a decision.

---

## 9. Open items

None blocking. P1 through P4 can run unattended once the P2 PR is approved; P5 waits on your explicit go.
