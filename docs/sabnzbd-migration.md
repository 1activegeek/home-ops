# NZBGet → SABnzbd Migration

Revision 3 (2026-10-01): **SABnzbd runs on the Synology, not in the cluster.** Revisions 1–2 planned and
built an in-cluster deployment; that was deployed, verified, and then deliberately removed. The reasoning
and what it taught us are in §9.

Status: cluster side merged and ready. Awaiting the container being started on the Synology, after which
configuration and validation are automated. Cutover remains gated.

---

## 1. Architecture

```
Prowlarr ──sync──▶ Sonarr / Radarr / Radarr4k
                        │  download client: sabnzbd.media.svc.cluster.local:8080
                        ▼
      Service (selectorless) + EndpointSlice  ──▶  10.0.3.2:10008
                        ▲                               │
   HTTPRoute sabnzbd.${SECRET_DOMAIN}                   ▼
   (envoy-internal, cert-manager TLS)        SABnzbd container on the Synology
                                             /volume1/docker/sabnzbd → /config
                                             /volume1/media          → /data/media
```

Three properties make this work:

1. **Local storage.** SABnzbd's working set never crosses the network. par2 repair and unpack are local
   disk IO, and the move into the library is a rename on the same volume rather than a copy. The entire
   "halt if remote storage disconnects" problem is **deleted rather than solved** — no watchdog, no canary
   probes, no mount options, no scratch volume.
2. **Path parity.** `/volume1/media` is mounted at **`/data/media`** inside the container, so SABnzbd
   reports exactly the paths the `*arr`s already see over NFS. **No remote path mappings** — the thing
   that has been quietly wrong in the NZBGet setup for years.
3. **No IPs in app config.** A selectorless Service plus a hand-written EndpointSlice gives the cluster a
   stable internal name for an off-box service. Moving the NAS changes one file.

### Reaching it

| From | Path |
|---|---|
| Sonarr / Radarr / Radarr4k / Prowlarr | `sabnzbd.media.svc.cluster.local:8080` (Service → EndpointSlice) |
| Phone / laptop on the home network | `https://sabnzbd.${SECRET_DOMAIN}` (envoy-internal, cert-manager TLS) |
| Direct, cluster-down fallback | `http://atlantis.server.mix.net:10008` |
| Off-network | Tailscale, same as other internal apps |

`host_whitelist` carries all four names. It is set from the container environment, not the seed — SABnzbd
rejects any Host header not on that list, which is a real failure mode we hit during the cluster build.

---

## 2. Repository layout

| Path | Purpose |
|---|---|
| `synology/sabnzbd/docker-compose.yaml` | The container definition for Container Manager. Renovate tracks the image tag here. |
| `kubernetes/apps/media/sabnzbd/app/service.yaml` | Selectorless Service + EndpointSlice → `${NFS_SERVER}:10008` |
| `kubernetes/apps/media/sabnzbd/app/httproute.yaml` | `sabnzbd.${SECRET_DOMAIN}` on envoy-internal |
| `scripts/sabnzbd-build-seed.py` | Builds the config seed from live NZBGet + probes every news server |
| `scripts/sabnzbd-apply-config.py` | Pushes the seed to 1Password and into SABnzbd over its API; `--verify` reads back |
| `scripts/sabnzbd-prestage-arrs.sh` | Stages SABnzbd as a **disabled** client in all four apps |
| `scripts/sabnzbd-cutover.sh` | Flips the enable flags; `--rollback` reverses |

Ports: NZBGet keeps **10007**, SABnzbd takes **10008**, so both run in parallel until cutover.

---

## 3. Why container and not a SynoCommunity package

NZBGet on the Synology is **already a Docker container** — its paths are `/app/nzbget`, `/config`,
`/downloads`, `/logs`, which is container mount convention, not a package install under
`/var/packages/`. So the container pattern is the status quo, not a new burden.

Two things decide it, and neither is update ergonomics:

- **UID/GID control.** The container runs as `1027:100`, matching ownership on `/volume1/media`. The
  `*arr`s import over NFS as the same uid/gid, so anything SABnzbd writes they can move, hardlink and
  delete. A SynoCommunity package runs as its own `sc-sabnzbd` user — workable, but an extra failure mode
  in exactly the handoff that has to be reliable.
- **Path parity.** Arbitrary mounts let the container present `/data/media`. A package sees real DSM paths,
  which means re-adding three remote path mappings.

Honest counterpoint: Package Center updates are one click, and **SynoCommunity's SABnzbd is 5.1.3 —
not behind upstream**. The container's compensation is that Renovate watches the tag in
`synology/sabnzbd/docker-compose.yaml` and opens the bump PR, which is closer to the existing flow.

---

## 4. Configuration: 1Password → API, no SSH, no .env

There is no init container on the NAS and no cluster filesystem to render into, so the entire
configuration is applied **over SABnzbd's HTTP API**.

- The complete `sabnzbd.ini` seed lives encrypted in 1Password (vault `homeops`, item `sabnzbd`, field
  `config_seed`), alongside `api_key` and `nzb_key`.
- `scripts/sabnzbd-build-seed.py` regenerates that seed from the **live NZBGet config**, so server
  credentials are never hand-copied and never committed.
- `scripts/sabnzbd-apply-config.py` reads it through `op-session` and pushes it in:
  `[misc]` one key per `set_config` call, `[servers]` and `[categories]` through SABnzbd's dedicated
  handlers. Nothing is printed — not the seed, not credentials, not the API key.
- `--verify` reads the live config back for an independent check.

Every key emitted was validated against SABnzbd 5.1.3's own `cfg.py`. That check caught four plausible
but non-existent keys during the cluster build (`quick_check`, `par2_multicore`,
`abort_on_missing_files`, `cleanup_empty_dir`) and is worth keeping.

`api_key`, `nzb_key` and `host_whitelist` are **environment-managed, not seed-managed** — the applier
skips them so it can never fight the container's own startup injection.

---

## 5. Setting-by-setting mapping (NZBGet → SABnzbd)

| NZBGet | Value | SABnzbd | Target |
|---|---|---|---|
| `MainDir` | `/downloads` (= `/volume1/media/downloads`) | — | — |
| `InterDir` | `/downloads/incomplete` | `download_dir` | `/data/media/downloads/incomplete-sab` |
| `DestDir` | `/downloads/complete` | `complete_dir` | `/data/media/downloads/complete` |
| `NzbDir` | `/downloads/nzb` | `dirscan_dir` | `/data/media/downloads/nzb` |
| `ScriptDir` | `/config/scripts` | `script_dir` | `/config/scripts` |
| `Unpack` | yes | `enable_unrar`, `enable_7zip` | on |
| `DirectUnpack` | no | `direct_unpack` | **on** (upgrade) |
| `UnpackCleanupDisk` | yes | `enable_par_cleanup`, `cleanup_list` | on |
| `ParRepair` | yes | par repair | on |
| `HealthCheck` | delete | `fail_hopeless_jobs`, `fast_fail` | on — see §6 |
| `DupeCheck` | yes | `no_dupes`, `no_smart_dupes`, `dupes_propercheck` | on |
| `ArticleCache` | 200 MB | `cache_limit` | `512M` |
| `DiskSpace` | 250 MB | `download_free` / `complete_free` | **`25G`** each |
| `KeepHistory` | 30 d | `history_retention_option` / `_number` | `days-delete` / `30` |
| `ExtCleanupDisk` | `.par2,.sfv,_brokenlog.txt` | `cleanup_list` | `par2, sfv, nfo, txt, srr, srs` |
| `DownloadRate` | 0 | `bandwidth_max` | unlimited |
| `Extensions` | `nzbgeek-reporting.py` | — | **dropped** — the file does not exist on disk |

`download_dir` is deliberately **`incomplete-sab`**, not the shared `incomplete`, so SABnzbd and NZBGet
cannot trip over each other while both run. `complete_dir` is shared safely — job directories don't
collide, and it means the `*arr`s see finished work in the same place either way.

### Categories

| Category | Dir | Consumer | NZBGet aliases → `newzbin` |
|---|---|---|---|
| `movies` | `movies` | Radarr | `movies*, 2000, 2030, 2040, 2050` |
| `movies-4k` | `movies-4k` | Radarr4k | (none) |
| `tvshows` | `tvshows` | Sonarr | `tv*, TV*` |
| `music` | `music` | manual | `audio*` |
| `software` | `software` | manual | `pc*` |
| `private` | `private` | manual | `xxx*, private*, 6000-6070` |

---

## 6. News servers — all 12, priorities preserved

NZBGet's `Level` maps 1:1 onto SABnzbd's `priority` (lower = tried first). The ordering is **intentional
and is preserved exactly**: the smaller/bespoke accounts sit at tier 0 and are tried first because between
them they reach articles the big providers don't carry; the paid `Newshosting (Personal)` is the tier-3
fallback and `Tweak (free)` the tier-4 deep-retention backfill (4300 d). This spares the primary account's
capacity and maximises the chance of finding obscure content. Do not "optimise" it.

**7 of the 12 fail authentication** — unchanged across tests a month apart (2026-09-02 and 2026-10-01):

| Working (5) | Failing (7) |
|---|---|
| NewsDemon, Usenet.farm, NewsGroupNinja, Newshosting (Personal), Tweak (free) | NewsGroup Direct (`502 Connection failure`), SuperNews (`481 Invalid username or password`), TweakNews, Newshosting (2nd acct), AstraWeb, UsenetServer-2, EasyNews (all `502 Authentication Failed`) |

This is very likely the mechanism behind the **27% `FAILURE/HEALTH`** rate in NZBGet's history: seven of
the ten servers tried *first* are dead, so every grab burns retries before reaching a working provider.
All 12 are carried over; the failures ship `enable = 0` with the exact error and test date in their notes,
so re-enabling a renewed account is a one-flag change.

**The breadth-first strategy is sound but currently runs on 3 working tier-0 servers, not 10.**

Note: NewsDemon's port 80 + TLS looks contradictory but is correct — it genuinely serves TLS on 80
(plaintext on 80 times out, TLS on 80 authenticates, 563 also works). Migrated unchanged.

### Early failure detection (§6 settings, on from day one)

| Setting | Target | What it kills |
|---|---|---|
| `fail_hopeless_jobs` | on | jobs that can't reach the completion threshold — aborted instead of downloading to a guaranteed par failure |
| `fast_fail` | on | fails the job as soon as it's hopeless rather than at the end |
| `req_completion_rate` | `100.2` | the health floor below which a job is declared dead |
| `propagation_delay` | `15` min | don't grab an NZB before articles have propagated — a real share of health failures |
| `pause_on_pwrar` | `2` (abort) | password-protected RARs: a "successful" download that can never be unpacked |
| `unwanted_extensions` + `action_on_unwanted_extensions=2` | fail job | malware-bait releases |
| `enable_all_par` | off | don't pull par2 blocks you don't need |

---

## 7. Phases

| Phase | Work | State |
|---|---|---|
| **P0** | Discovery — full NZBGet config, `*arr`/Prowlarr state, path layout, size distribution | ✅ |
| **P1** | Seed built from live NZBGet, all 12 servers probed, validated against SABnzbd source, stored in 1Password | ✅ |
| **P2** | Cluster side: Service + EndpointSlice + HTTPRoute; in-cluster deployment removed | ✅ merged |
| **P3** | **You:** start the container on the Synology (§8) | ⏳ |
| **P4** | Apply config over the API, verify every setting, end-to-end test NZB, path/permission/ownership checks | ⏳ automated |
| **P5** | Stage SABnzbd as a **disabled** client in all four apps and connectivity-test | ✅ already done, still intact |
| **P6** | 🔒 **CUTOVER — gated.** `./scripts/sabnzbd-cutover.sh` flips four enable flags, deletes stale path mappings | ⏳ your go |
| **P7** | Soak, then stop the NZBGet container and retire its `/downloads/{queue,tmp,nzb}` dirs | ⏳ |

P5 was completed during the cluster build and **survived the architecture change unchanged**, because the
`*arr`s were always pointed at `sabnzbd.media.svc.cluster.local:8080` rather than an IP.

---

## 8. What you need to do (P3)

Everything else is automated. This is the only manual step.

1. Create the config folder on the NAS: **`/volume1/docker/sabnzbd`**
2. In **Container Manager → Project**, create a project from
   `synology/sabnzbd/docker-compose.yaml`.
3. Replace the two placeholder values with the real ones from **1Password → vault `homeops` → item
   `sabnzbd`**:
   - `SABNZBD__API_KEY` ← field `api_key`
   - `SABNZBD__NZB_KEY` ← field `nzb_key`

   These **must** match 1Password: the `*arr`s are already staged with that API key, and the config
   automation authenticates with it. If SABnzbd generates its own instead, nothing can talk to it.
4. Start the project and confirm `http://atlantis.server.mix.net:10008` loads.

Do **not** hand-configure anything in the UI — step 4 of §4 applies the whole configuration, and
hand-edits to managed keys will be overwritten.

### Then, unattended

```bash
op-session exec python3 scripts/sabnzbd-apply-config.py --build --push --apply --verify
```

---

## 9. Appendix: the in-cluster attempt, and what it taught us

Revisions 1–2 built, deployed and verified SABnzbd **inside** the cluster: Longhorn scratch volume for the
working set, static NFS PV with `hard`/`nconnect` mount options for the media share, canary exec probes, a
watchdog sidecar in a shared PID namespace, a seed-merge init container, and a config-backup sidecar. It
worked — a 167 MB test NZB downloaded in 1 s at 90.9 MB/s, and a storage-loss drill halted the pod in 30 s
and recovered it automatically in ~50 s.

It was removed because running on the NAS is simply better: local storage eliminates the requirement that
all of that machinery existed to satisfy.

Five defects found during that build, each a real design error worth remembering:

| # | Defect | Root cause |
|---|---|---|
| 1 | 250Gi scratch PVC wouldn't schedule | Sized against Longhorn's `storageAvailable` (raw free disk ~695 GB/node) instead of `storageMaximum - storageReserved - storageScheduled`; the default 30% reservation (247 GB/node) left only 223/186/100 GB schedulable. Reduced to 150Gi. |
| 2 | SABnzbd generated its own `api_key`, ignoring 1Password | The seed omitted `api_key`/`nzb_key`/`host_whitelist`, assuming the image entrypoint would inject them. Its `sed` only substitutes into lines that **already exist**, so it was a silent no-op. |
| 3 | `host_whitelist` contained only the pod name | Same root cause; SABnzbd auto-added its own hostname. Would have broken the route. |
| 4 | Watchdog logged "every s" | `${INTERVAL}` in a ConfigMap was consumed by Flux variable substitution — the gotcha documented in `AGENTS.md`. Escape as `$${VAR}`. |
| 5 | `config-backup` logged "tar failed" then slept 24 h | Ran before SABnzbd had created `/config/admin`. |

Defects 2 and 3 are the instructive ones: SABnzbd looked completely healthy, and the failure would only
have surfaced at cutover when every `*arr` failed to authenticate. Hence §4's rule that `api_key`,
`nzb_key` and `host_whitelist` are environment-managed and explicitly excluded from the seed.

**Measurements worth keeping** (1 GiB `dd`, `O_DIRECT`, from pods in `media`): NFS to the Synology wrote at
105 MB/s and read at 112 MB/s — i.e. the NAS link is ~1GbE and was already saturated. That is the number
that makes local storage the right call: on the NAS, a 39 GB RAR'd job's unpack IO (another ~78 GB of
read+write) never touches the wire at all, and the move into the library is a 5 ms rename instead of a
~6 minute copy.

---

## 10. Follow-ups

1. **Retire unpackerr.** Its paths (`downloads/complete/{sonarr,radarr,radarr4k}`) don't exist — the real
   dirs are `movies`/`tvshows`/`movies-4k` — so it has been a no-op. SABnzbd unpacks natively with Direct
   Unpack on. One fewer deployment.
2. **Uptime Kuma monitor** on `sabnzbd.${SECRET_DOMAIN}`. SABnzbd is now outside cluster metrics
   (no pod, no PVC, no ServiceMonitor), so uptime checking is the monitoring story. There is no blackbox
   exporter in the cluster today.
3. **Prowlarr's NZBGet client points at host `nzbget:6789`**, which doesn't resolve in-cluster — it has
   almost certainly been non-functional. Worth confirming, since it means Prowlarr test/manual grabs have
   been failing silently.
4. **Server health scoring.** Once there's data, per-server article-miss rates will show which tier-0
   accounts earn their place in the breadth-first strategy and which just add latency before the fallback.
   Data-driven, rather than pruning on assumption.
5. **A `prowlarr` category** if interactive Prowlarr grabs landing in the root of `complete/` becomes
   annoying. Today it has no category set, which SABnzbd accepts with an advisory warning.
