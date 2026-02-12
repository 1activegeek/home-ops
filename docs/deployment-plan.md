# Cluster Application Deployment Plan

## Context

This plan covers deploying ~30+ applications into an existing Talos Linux / Flux CD Kubernetes cluster. The cluster already has core infrastructure (Cilium, Envoy Gateway, Authentik, External Secrets + 1Password, Longhorn, NFS CSI, cert-manager, Cloudflare Tunnel, Mosquitto MQTT). The goal is a well-organized, GitOps-managed deployment with sane defaults, Authentik integration where possible, and proper inter-app connections.

Several apps are currently running as Docker containers on the Synology NAS and need to be migrated with their data intact: Prowlarr, Sonarr, Radarr, Radarr-4K, Autoscan, Overseerr/Seerr, Tautulli, Teslamate.

This plan will be committed to the repo as a living document to guide ongoing deployment work across multiple sessions.

---

## Key Architecture Decisions

### Database Strategy: Individual DBs Per App

**Deploy individual PostgreSQL/MariaDB instances per app.**

Rationale:
- **Isolation**: One app's DB issue won't cascade to others
- **Independent lifecycle**: Backup, restore, upgrade each DB independently
- **Version flexibility**: Different apps may need different PG versions
- **Simpler troubleshooting**: Each app owns its own data
- **Minimal overhead**: Small PG instances use ~64-128MB RAM each

Implementation: Each app needing a database gets a sidecar container using the official `postgres:17-alpine` or `mariadb:11` image managed via the bjw-s app-template multi-controller pattern. Database credentials stored in 1Password via ExternalSecret.

Apps needing PostgreSQL: Teslamate, Shlink, n8n, Forgejo, Zipline
Apps needing MariaDB: BookLore
All other apps: SQLite (embedded, no separate DB needed)

### Chosen Alternatives

| Original Request | Chosen App | Reason |
|-----------------|------------|--------|
| nzbget | **SABnzbd** | nzbget was abandoned 2019-2021; SABnzbd is actively maintained with better K8s support |
| rTorrent | **qBittorrent** | Modern REST API, built-in web UI, Gluetun VPN sidecar support |
| Overseerr | **Seerr** | Overseerr being deprecated; Seerr (formerly Seerr) is the unified successor supporting Plex+Jellyfin |
| Gitea | **Forgejo** | 2.5x more commits, fully open-source, OCI Helm chart, non-profit governance |
| Calibre + Calibre-web | **BookLore** (ebooks) + **Audiobookshelf** (audiobooks) | BookLore has native OIDC, modern UI; Audiobookshelf for audiobooks since BookLore doesn't support them |
| transfer.sh | **Zipline** | Zipline has native OIDC, URL shortening, rich upload features; transfer.sh is effectively abandoned |

### Namespace Organization

| Namespace | Apps |
|-----------|------|
| `media` | Plex, SABnzbd, qBittorrent+Gluetun, Prowlarr, Radarr, Radarr-4K, Sonarr, Autoscan, Seerr, Tautulli, MeTube, Bazarr, Recyclarr, Unpackerr, Notifiarr, BookLore, Audiobookshelf |
| `ai` | Ollama, OpenWebUI, n8n, Qdrant |
| `tools` | Shlink, Shlink-web, Forgejo, KMS, Zipline |
| `monitoring` | Gatus, Uptime Kuma, Grafana |
| `home` | Teslamate |

### Storage Strategy

- **App configs** (`/config`): Longhorn (fast, replicated SSD storage)
- **Media files** (`/data/media`): NFS (existing media share, high capacity)
- **Downloads** (`/data/media/download/{usenet,torrents}`): NFS (same media share, hardlink-compatible)
- **AI models** (`/models`): Longhorn (large PVC, 50-100Gi for Ollama)
- **Databases**: Longhorn (performance-critical)
- **Books**: NFS (existing ebook/audiobook folders on media share)

### NFS Media Directory Layout

The NFS media share path needs to be provided as `${NFS_MEDIA_SERVER}` and `${NFS_MEDIA_SHARE}` (e.g., the same Synology NAS at a different share path than `/volume2/kubes`).

All media apps share a single NFS mount at the root level to enable hardlinks between downloads and libraries:
```
/data/                          # NFS mount root inside containers
  media/
    movies/                     # Radarr root folder, Plex movie library
    movies-4k/                  # Radarr-4K root (was `movies4k` in Docker)
    tv/                         # Sonarr root folder, Plex TV library (was `tvshows` in Docker)
    tvrecordings/               # Plex DVR recordings library
    courses/                    # Plex courses library
    workouts/                   # Plex workouts library
    ebook/                      # BookLore library (was `ebooks` in Docker)
    audiobook/                  # Audiobookshelf library
    youtube/                    # MeTube downloads (was `metube` in Docker)
    download/                   # Download clients root (was `downloads` flat in Docker)
      usenet/
        complete/               # SABnzbd completed downloads
        incomplete/             # SABnzbd in-progress
      torrents/
        complete/               # qBittorrent completed downloads
        incomplete/             # qBittorrent in-progress
```

### Authentik Integration Summary

| App | Auth Method | Notes |
|-----|-------------|-------|
| **Native OIDC** | | |
| Gatus | Native OIDC | Built-in `security.oidc` config block |
| OpenWebUI | Native OIDC | Full OIDC with role/group sync |
| Forgejo | Native OIDC | Built-in OAuth2/OIDC provider config |
| BookLore | Native OIDC | Tested with Authentik |
| Zipline | Native OIDC | Built-in OIDC, configured via dashboard |
| Grafana | Native OIDC | Built-in generic OAuth |
| n8n | Community OIDC | Via `cweagans/n8n-oidc` hook (free) or native (enterprise) |
| **Forward-Auth** | | |
| Sonarr/Radarr/Prowlarr | Forward-auth | Set app auth to "External" |
| SABnzbd | Forward-auth | Authentik proxy provider at gateway |
| qBittorrent | Forward-auth | Authentik proxy provider at gateway |
| Tautulli | Forward-auth | Authentik proxy provider |
| Uptime Kuma | Forward-auth | No native OIDC |
| MeTube | Forward-auth | Zero built-in auth |
| Teslamate | Forward-auth | No built-in auth |
| Shlink-web | Forward-auth | API-key only natively |
| Bazarr | Forward-auth | No native OIDC |
| Audiobookshelf | Forward-auth | Has built-in auth but no OIDC |
| **Own Auth / None** | | |
| Plex | Plex.tv accounts | Own auth system |
| Seerr | Plex OAuth | Uses Plex login for users |
| KMS | N/A | TCP protocol, no web UI |
| Autoscan | N/A | Internal-only service, no UI |
| Ollama | N/A | Internal-only API |
| Qdrant | N/A | Internal-only API |
| Recyclarr | N/A | CronJob, no UI |
| Unpackerr | N/A | Daemon, no UI |
| Notifiarr | API key | Cloud service + local client |

### Public vs Internal Access

| Access | Apps |
|--------|------|
| **External** (envoy-external, via Cloudflare Tunnel) | Seerr, Shlink (redirects), Zipline |
| **Internal** (envoy-internal, local network only) | Everything else with a web UI |
| **ClusterIP only** (no ingress) | Ollama, Autoscan, Qdrant, Unpackerr, Recyclarr, Notifiarr, all databases, MQTT |

---

## Deployment Phases & Order

### Phase 0: Shared Infrastructure
**Branch: `claude/deploy-namespaces`**

Create the new namespaces and register them with Flux:
- `media`, `ai`, `tools`, `monitoring` namespaces
- (`default` already exists)
- Shared NFS PV/PVC for media data (ReadWriteMany, used by all media apps)

Files to create:
```
kubernetes/apps/media/namespace.yaml
kubernetes/apps/media/kustomization.yaml
kubernetes/apps/ai/namespace.yaml
kubernetes/apps/ai/kustomization.yaml
kubernetes/apps/tools/namespace.yaml
kubernetes/apps/tools/kustomization.yaml
kubernetes/apps/monitoring/namespace.yaml
kubernetes/apps/monitoring/kustomization.yaml
```

Also register in `kubernetes/flux/cluster/ks.yaml` (add entries for new namespace kustomizations).

---

### Phase 1: Simple Independent Apps
No dependencies on other apps. Can be deployed in parallel.

#### 1a. KMS (vlmcsd)
**Branch: `claude/deploy-kms`** | **Namespace: `tools`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `mikolatero/vlmcsd:latest` |
| Chart | bjw-s app-template |
| Storage | None |
| Database | None |
| Auth | N/A (TCP protocol only, no web UI) |
| Service | LoadBalancer on TCP 1688 |
| Resources | 5m CPU / 8Mi RAM |
| 1Password | Not needed |

Notes:
- Lightweight C-based KMS emulator (~5MB RAM, no UI)
- Switching from py-kms (Docker) to vlmcsd (smaller footprint, no UI needed)

Files:
```
kubernetes/apps/tools/kms/ks.yaml
kubernetes/apps/tools/kms/app/{kustomization,helmrelease,ocirepository}.yaml
```

#### 1b. Gatus
**Branch: `claude/deploy-gatus`** | **Namespace: `monitoring`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/twin/gatus:v5` |
| Chart | bjw-s app-template |
| Storage | 1Gi Longhorn (SQLite persistence) |
| Database | SQLite |
| Auth | **Native OIDC** (Authentik) |
| Route | `gatus.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 10m CPU / 64Mi RAM |
| 1Password | `gatus` (oidc_client_id, oidc_client_secret) |

**ConfigMap**: Endpoint monitoring configuration (YAML). Monitors all cluster apps and external services. This is version-controlled - a key advantage over UI-configured tools.

**Healthchecks.io**: Configure as a webhook alerting provider in the Gatus config. Gatus can send success/failure pings to healthchecks.io check URLs.

Files:
```
kubernetes/apps/monitoring/gatus/ks.yaml
kubernetes/apps/monitoring/gatus/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
kubernetes/apps/monitoring/gatus/app/configmap.yaml  # Monitoring endpoints config
```

#### 1c. Uptime Kuma
**Branch: `claude/deploy-uptime-kuma`** | **Namespace: `monitoring`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `louislam/uptime-kuma:1` |
| Chart | bjw-s app-template (StatefulSet) |
| Storage | 1Gi Longhorn (`/app/data`) |
| Database | SQLite (embedded) |
| Auth | Forward-auth via Authentik |
| Route | `uptime.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 50m CPU / 256Mi RAM |
| 1Password | Not needed |

Files:
```
kubernetes/apps/monitoring/uptime-kuma/ks.yaml
kubernetes/apps/monitoring/uptime-kuma/app/{kustomization,helmrelease,ocirepository}.yaml
```

#### 1d. MeTube
**Branch: `claude/deploy-metube`** | **Namespace: `media`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/alexta69/metube:latest` |
| Chart | bjw-s app-template |
| Storage | NFS mount `/data/media/youtube` |
| Auth | Forward-auth via Authentik |
| Route | `metube.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 50m CPU / 128Mi RAM |

Files:
```
kubernetes/apps/media/metube/ks.yaml
kubernetes/apps/media/metube/app/{kustomization,helmrelease,ocirepository}.yaml
```

#### 1e. Grafana (Standalone)
**Branch: `claude/deploy-grafana`** | **Namespace: `monitoring`** | **Migration: No**

| Field | Value |
|-------|-------|
| Chart | `grafana/grafana` via **HelmRepository** (no OCI available) |
| Storage | 2Gi Longhorn |
| Database | SQLite (embedded) |
| Auth | **Native OIDC** (Authentik generic OAuth) |
| Route | `grafana.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 100m CPU / 256Mi RAM |
| 1Password | `grafana` (oidc_client_id, oidc_client_secret, admin_password) |

Standalone Grafana serving multiple data sources. Dashboard provisioning via ConfigMaps with `grafana_dashboard` label + sidecar.

Initial data sources:
- Teslamate PostgreSQL (added when Teslamate deploys in Phase 7)
- Future: Prometheus, Loki, etc.

Dashboard provisioning:
- Teslamate dashboards imported as ConfigMaps with `grafana_dashboard: "1"` label
- Sidecar watches all namespaces for dashboard ConfigMaps

Files:
```
kubernetes/apps/monitoring/grafana/ks.yaml
kubernetes/apps/monitoring/grafana/app/{kustomization,helmrelease,helmrepository,externalsecret}.yaml
```

---

### Phase 2: Forgejo (Git Hosting) + Zipline (File Sharing)
Independent of each other, can deploy in parallel.

#### 2a. Forgejo
**Branch: `claude/deploy-forgejo`** | **Namespace: `tools`** | **Migration: No**

| Field | Value |
|-------|-------|
| Chart | **Official OCI** `oci://codeberg.org/forgejo-contrib/forgejo` |
| Storage | 10Gi Longhorn (repos + DB) |
| Database | PostgreSQL (bundled subchart) |
| Auth | **Native OIDC** (Authentik) |
| Route | `git.${SECRET_DOMAIN}` → envoy-internal |
| SSH | LoadBalancer on port 22 |
| Resources | 200m CPU / 512Mi RAM |
| 1Password | `forgejo` (db_password, admin_password, oidc_client_id, oidc_client_secret, secret_key, lfs_jwt_secret) |

Notes:
- Official OCI Helm chart matches cluster conventions
- Built-in PostgreSQL subchart with Longhorn storage
- Configure OIDC auto-registration from Authentik

Files:
```
kubernetes/apps/tools/forgejo/ks.yaml
kubernetes/apps/tools/forgejo/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

#### 2b. Zipline (File Sharing / Uploads)
**Branch: `claude/deploy-zipline`** | **Namespace: `tools`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/diced/zipline:latest` (v4) |
| Chart | bjw-s app-template |
| Storage | 10Gi Longhorn (`/zipline/uploads`) |
| Database | PostgreSQL 15+ (sidecar) |
| Auth | **Native OIDC** (Authentik) - configured via dashboard |
| Route | `zipline.${SECRET_DOMAIN}` → envoy-external (PUBLIC) |
| Resources | 100m CPU / 256Mi RAM |
| 1Password | `zipline` (db_password, core_secret) |

Notes:
- Replaces transfer.sh (abandoned) and can also serve as URL shortener (overlaps with Shlink)
- OIDC configured post-deploy via web dashboard (not env vars)
- `CORE_SECRET` for cookie signing, generate with `openssl rand -base64 32`
- `DATABASE_URL` as PostgreSQL connection string

Files:
```
kubernetes/apps/tools/zipline/ks.yaml
kubernetes/apps/tools/zipline/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

---

### Phase 3: Media Infrastructure (Download Clients + Plex)
Must deploy before *arr apps since Sonarr/Radarr need download clients configured.

#### 3a. Plex
**Branch: `claude/deploy-plex`** | **Namespace: `media`** | **Migration: No** (secondary server)

| Field | Value |
|-------|-------|
| Image | `ghcr.io/home-operations/plex:latest` |
| Chart | bjw-s app-template |
| Storage | `/config`: 10Gi Longhorn, `/data/media/*`: NFS (movies, movies-4k, tv, tvrecordings, courses, workouts), `/transcode`: emptyDir |
| Auth | Plex.tv accounts (own system) |
| Route | `plex.${SECRET_DOMAIN}` → envoy-internal |
| Service | Additional LoadBalancer on port 32400 |
| Resources | 500m CPU / 1Gi RAM (CPU-only transcoding) |
| 1Password | `plex` (plex_claim) |

Notes:
- Secondary Plex server (existing remote Plex continues)
- No GPU - software transcoding; configure to prefer direct play/stream
- Plex claim token needed only for initial setup (one-time use, expires in 4 minutes)

Files:
```
kubernetes/apps/media/plex/ks.yaml
kubernetes/apps/media/plex/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

#### 3b. SABnzbd
**Branch: `claude/deploy-sabnzbd`** | **Namespace: `media`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/home-operations/sabnzbd:latest` |
| Chart | bjw-s app-template |
| Storage | `/config`: 1Gi Longhorn, `/data`: NFS mount (media root) |
| Auth | Forward-auth via Authentik |
| Route | `sabnzbd.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 100m CPU / 512Mi RAM |
| 1Password | `sabnzbd` (api_key, nzb_key) |

Sane defaults:
- Categories: `movies` → `/data/media/download/usenet/complete/movies`, `tv` → `.../tv`
- Complete dir: `/data/media/download/usenet/complete`
- Incomplete dir: `/data/media/download/usenet/incomplete`

Files:
```
kubernetes/apps/media/sabnzbd/ks.yaml
kubernetes/apps/media/sabnzbd/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

#### 3c. qBittorrent + Gluetun VPN
**Branch: `claude/deploy-qbittorrent`** | **Namespace: `media`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/home-operations/qbittorrent:latest` + `ghcr.io/qdm12/gluetun:latest` |
| Chart | bjw-s app-template (multi-container pod) |
| Storage | `/config`: 1Gi Longhorn, `/data`: NFS mount (media root) |
| Auth | Forward-auth via Authentik |
| Route | `qbit.${SECRET_DOMAIN}` → envoy-internal |
| Resources | qBit: 100m/512Mi + Gluetun: 50m/128Mi |
| 1Password | `qbittorrent` (vpn_username, vpn_password, vpn_endpoint, vpn_type) |

Notes:
- **Gluetun sidecar**: All torrent traffic routed through VPN tunnel
- Gluetun container runs as init-style network namespace; qBittorrent shares its network
- Download paths match SABnzbd structure for *arr app compatibility
- Security context: Gluetun needs `NET_ADMIN` capability for VPN tunnel

Files:
```
kubernetes/apps/media/qbittorrent/ks.yaml
kubernetes/apps/media/qbittorrent/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

---

### Phase 4: *Arr Stack (Indexer + Media Management)
Depends on: Phase 3 (download clients must exist)

**MIGRATION APPS**: Prowlarr, Sonarr, Radarr, Radarr-4K are migrating from Docker. See [Migration Plan](#migration-plan) section.

#### 4a. Prowlarr (Indexer Manager) — MIGRATION
**Branch: `claude/deploy-prowlarr`** | **Namespace: `media`** | **Migration: Yes**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/home-operations/prowlarr:latest` |
| Chart | bjw-s app-template |
| Storage | `/config`: 1Gi Longhorn |
| Auth | "External" auth mode + Authentik forward-auth |
| Route | `prowlarr.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 50m CPU / 256Mi RAM |
| 1Password | `prowlarr` (api_key — migrated from existing) |

Notes:
- Central indexer manager - configure indexers once, sync to all *arr apps
- Deploy first in Phase 4; Sonarr/Radarr reference it
- Migration: Copy config, update download client URLs to K8s service names

Files:
```
kubernetes/apps/media/prowlarr/ks.yaml
kubernetes/apps/media/prowlarr/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

#### 4b. Sonarr (TV Shows) — MIGRATION
**Branch: `claude/deploy-sonarr`** | **Namespace: `media`** | **Migration: Yes**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/home-operations/sonarr:latest` |
| Chart | bjw-s app-template |
| Storage | `/config`: 2Gi Longhorn, `/data`: NFS mount (media root) |
| Auth | "External" auth mode + Authentik forward-auth |
| Route | `sonarr.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 100m CPU / 512Mi RAM |
| 1Password | `sonarr` (api_key — migrated from existing) |

Sane defaults:
- Root folder: `/data/media/tv`
- Download clients: SABnzbd (Usenet) + qBittorrent (Torrent)
- Quality: Managed by Recyclarr (TRaSH Guides)

Files:
```
kubernetes/apps/media/sonarr/ks.yaml
kubernetes/apps/media/sonarr/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

#### 4c. Radarr (Movies) — MIGRATION
**Branch: `claude/deploy-radarr`** | **Namespace: `media`** | **Migration: Yes**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/home-operations/radarr:latest` |
| Storage/Auth/Route | Same pattern as Sonarr |
| Root folder | `/data/media/movies` |
| 1Password | `radarr` (api_key — migrated) |

Files: Same structure as Sonarr under `kubernetes/apps/media/radarr/`.

#### 4d. Radarr-4K — MIGRATION
**Branch: `claude/deploy-radarr-4k`** | **Namespace: `media`** | **Migration: Yes**

Same as Radarr but:
- Separate `/config` PVC, separate API key
- Root folder: `/data/media/movies-4k`
- Quality: Ultra-HD 4K (managed by Recyclarr)
- 1Password: `radarr-4k` (api_key — migrated)

Files: Same structure under `kubernetes/apps/media/radarr-4k/`.

---

### Phase 5: Media Support & Automation Apps
Depends on: Phase 3 (Plex) and Phase 4 (*arr apps)

#### 5a. Autoscan — MIGRATION
**Branch: `claude/deploy-autoscan`** | **Namespace: `media`** | **Migration: Yes**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/hotio/autoscan:latest` |
| Chart | bjw-s app-template |
| Storage | `/config`: 256Mi Longhorn |
| Auth | N/A (ClusterIP only, receives webhooks) |
| Service | ClusterIP on port 3030 |
| Resources | 10m CPU / 64Mi RAM |
| 1Password | `autoscan` (plex_token) |

**ConfigMap** (`autoscan.yml`):
```yaml
triggers:
  sonarr:
    - name: sonarr
      priority: 2
  radarr:
    - name: radarr
      priority: 2
    - name: radarr4k
      priority: 5
targets:
  plex:
    - url: http://plex.media.svc.cluster.local:32400
      token: ${PLEX_TOKEN}
```

Inter-app connections:
- Receives webhooks from: Sonarr, Radarr, Radarr-4K (configure webhook URL: `http://autoscan.media.svc.cluster.local:3030/triggers/<type>`)
- Triggers library scans on: Plex

Files:
```
kubernetes/apps/media/autoscan/ks.yaml
kubernetes/apps/media/autoscan/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
kubernetes/apps/media/autoscan/app/configmap.yaml
```

#### 5b. Seerr (Media Requests) — MIGRATION (from Overseerr)
**Branch: `claude/deploy-seerr`** | **Namespace: `media`** | **Migration: Yes** (from Overseerr)

| Field | Value |
|-------|-------|
| Image | `fallenbagel/seerr:latest` |
| Chart | bjw-s app-template |
| Storage | `/app/config`: 1Gi Longhorn |
| Auth | Plex OAuth for users |
| Route | `requests.${SECRET_DOMAIN}` → **envoy-external** (PUBLIC) |
| Resources | 100m CPU / 256Mi RAM |
| 1Password | `seerr` (plex_token) |

Inter-app connections:
- Connects to: Plex (server discovery), Sonarr (TV requests), Radarr (movie requests), Radarr-4K (4K movie requests)
- Users submit requests → Seerr sends to appropriate *arr app → download pipeline

**Migration note**: Seerr can import Overseerr settings. Copy the `/app/config` directory, then Seerr will read the Overseerr database format.

Files:
```
kubernetes/apps/media/seerr/ks.yaml
kubernetes/apps/media/seerr/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
kubernetes/apps/media/seerr/app/httproute-external.yaml
```

#### 5c. Tautulli (Plex Monitoring) — MIGRATION
**Branch: `claude/deploy-tautulli`** | **Namespace: `media`** | **Migration: Yes**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/tautulli/tautulli:latest` |
| Chart | bjw-s app-template |
| Storage | `/config`: 1Gi Longhorn |
| Auth | Forward-auth via Authentik |
| Route | `tautulli.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 50m CPU / 256Mi RAM |
| 1Password | `tautulli` (api_key — migrated, plex_token) |

Files:
```
kubernetes/apps/media/tautulli/ks.yaml
kubernetes/apps/media/tautulli/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

#### 5d. Bazarr (Subtitles)
**Branch: `claude/deploy-bazarr`** | **Namespace: `media`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/hotio/bazarr:latest` |
| Chart | bjw-s app-template |
| Storage | `/config`: 1Gi Longhorn, `/data`: NFS mount |
| Auth | Forward-auth via Authentik |
| Route | `bazarr.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 50m CPU / 256Mi RAM |
| 1Password | Not needed (connects to Sonarr/Radarr via their API keys) |

Inter-app connections:
- Sonarr URL + API key (`http://sonarr.media.svc.cluster.local:8989`)
- Radarr URL + API key (`http://radarr.media.svc.cluster.local:7878`)
- Must mount same media paths as Sonarr/Radarr

Files:
```
kubernetes/apps/media/bazarr/ks.yaml
kubernetes/apps/media/bazarr/app/{kustomization,helmrelease,ocirepository}.yaml
```

#### 5e. Recyclarr (TRaSH Guides Quality Profiles)
**Branch: `claude/deploy-recyclarr`** | **Namespace: `media`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/recyclarr/recyclarr:latest` |
| Chart | bjw-s app-template (**CronJob**) |
| Schedule | `@daily` (midnight) |
| Storage | `/config`: 256Mi Longhorn (cache) |
| Auth | N/A (no UI) |
| Resources | 50m CPU / 128Mi RAM |
| 1Password | `recyclarr` (sonarr_api_key, radarr_api_key, radarr_4k_api_key) |

**ConfigMap** (`recyclarr.yml`):
```yaml
sonarr:
  tv-hd:
    base_url: http://sonarr.media.svc.cluster.local:8989
    api_key: !secret sonarr_api_key
    include:
      - template: sonarr-v4-quality-profile-web-1080p
      - template: sonarr-v4-custom-formats-web-1080p
radarr:
  movies-hd:
    base_url: http://radarr.media.svc.cluster.local:7878
    api_key: !secret radarr_api_key
    include:
      - template: radarr-quality-profile-hd-bluray-web
      - template: radarr-custom-formats-hd-bluray-web
  movies-4k:
    base_url: http://radarr-4k.media.svc.cluster.local:7878
    api_key: !secret radarr_4k_api_key
    include:
      - template: radarr-quality-profile-uhd-bluray-web
      - template: radarr-custom-formats-uhd-bluray-web
```

Files:
```
kubernetes/apps/media/recyclarr/ks.yaml
kubernetes/apps/media/recyclarr/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
kubernetes/apps/media/recyclarr/app/configmap.yaml
```

#### 5f. Unpackerr (Archive Extraction)
**Branch: `claude/deploy-unpackerr`** | **Namespace: `media`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/unpackerr/unpackerr:latest` |
| Chart | bjw-s app-template (Deployment daemon) |
| Storage | `/data`: NFS mount (same download paths as *arr apps) |
| Auth | N/A (no UI, headless daemon) |
| Resources | 50m CPU / 128Mi RAM |
| 1Password | `unpackerr` (sonarr_api_key, radarr_api_key, radarr_4k_api_key) |

Configuration via environment variables:
```
UN_SONARR_0_URL=http://sonarr.media.svc.cluster.local:8989
UN_SONARR_0_API_KEY=${SONARR_API_KEY}
UN_RADARR_0_URL=http://radarr.media.svc.cluster.local:7878
UN_RADARR_0_API_KEY=${RADARR_API_KEY}
UN_RADARR_1_URL=http://radarr-4k.media.svc.cluster.local:7878
UN_RADARR_1_API_KEY=${RADARR_4K_API_KEY}
```

Files:
```
kubernetes/apps/media/unpackerr/ks.yaml
kubernetes/apps/media/unpackerr/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

#### 5g. Notifiarr (Notification Hub)
**Branch: `claude/deploy-notifiarr`** | **Namespace: `media`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/notifiarr/notifiarr:latest` |
| Chart | bjw-s app-template |
| Storage | `/config`: 256Mi Longhorn |
| Auth | API key (notifiarr.com account required) |
| Service | ClusterIP on port 5454 |
| Resources | 50m CPU / 128Mi RAM |
| 1Password | `notifiarr` (api_key, sonarr_api_key, radarr_api_key, plex_token) |

**Note**: Requires a free notifiarr.com account. The local client collects data from *arr apps and sends to the cloud service for notification routing to Discord/Slack/etc.

Files:
```
kubernetes/apps/media/notifiarr/ks.yaml
kubernetes/apps/media/notifiarr/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

---

### Phase 6: Shlink Stack
**Branch: `claude/deploy-shlink`** | **Namespace: `tools`** | **Migration: Partial** (existing Shlink data uses MySQL 5.7)

Three components in one branch (tightly coupled):

**6a. Shlink Backend** (API + redirect server)
| Field | Value |
|-------|-------|
| Image | `shlinkio/shlink:4` |
| Database | PostgreSQL 17 (sidecar) - fresh install |
| Route | `s.${SECRET_DOMAIN}` → **envoy-external** (PUBLIC - short URL redirects) |
| Resources | 50m CPU / 128Mi RAM |

**Migration note**: Docker setup uses MySQL 5.7. For K8s we'll use PostgreSQL (better ecosystem, matches other apps). This means a fresh Shlink install rather than migrating the MySQL data. Short URL data can be exported/imported via Shlink's API if needed (`GET /short-urls` → `POST /short-urls`).

**6b. Shlink Web Client** (management UI)
| Field | Value |
|-------|-------|
| Image | `shlinkio/shlink-web-client:4` |
| Auth | Forward-auth via Authentik |
| Route | `shlink.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 10m CPU / 32Mi RAM |

**6c. Shlink PostgreSQL**
| Field | Value |
|-------|-------|
| Image | `postgres:17-alpine` |
| Storage | 2Gi Longhorn |

| 1Password | `shlink` (db_password, initial_api_key, geolite_license_key) |

Files:
```
kubernetes/apps/tools/shlink/ks.yaml
kubernetes/apps/tools/shlink/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

---

### Phase 7: Teslamate Stack — MIGRATION
**Branch: `claude/deploy-teslamate`** | **Namespace: `home`** | **Migration: Yes**

#### 7a. Teslamate + PostgreSQL
| Field | Value |
|-------|-------|
| Image | `teslamate/teslamate:latest` + `postgres:17-alpine` |
| Chart | bjw-s app-template (multi-controller) |
| Storage | PG: 5Gi Longhorn |
| MQTT | Existing Mosquitto: `mosquitto.home.svc.cluster.local:1883` (Docker used its own `teslamate_mqtt` - migrate to shared) |
| Auth | Forward-auth via Authentik |
| Route | `teslamate.${SECRET_DOMAIN}` → envoy-internal |
| Resources | Teslamate: 50m/256Mi, PG: 100m/256Mi |
| 1Password | `teslamate` (db_password, encryption_key, mqtt_password) |

Grafana integration:
- Docker used `teslamate/grafana` custom image (Grafana + pre-loaded dashboards). In K8s we use standalone Grafana + dashboard ConfigMaps instead.
- Grafana data source configured to point at `teslamate-postgresql.home.svc.cluster.local:5432`
- Teslamate dashboard JSONs extracted from `teslamate/grafana` image and deployed as ConfigMaps with `grafana_dashboard: "1"` label
- Dashboards auto-discovered by Grafana sidecar (deployed in Phase 1e)
- Docker env vars to migrate: `ENCRYPTION_KEY=$TESLAMATE_KEY`, `DATABASE_PASS=$TESLAMATE_DB_PASS`
- Docker used PostgreSQL 15; K8s deploys PostgreSQL 17 (compatible for pg_dump/restore)

Files:
```
kubernetes/apps/home/teslamate/ks.yaml
kubernetes/apps/home/teslamate/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
kubernetes/apps/home/teslamate/app/grafana-dashboards/  # ConfigMaps with dashboard JSONs
```

---

### Phase 8: AI Stack
Depends on: Ollama must be ready before OpenWebUI and n8n connect to it.

#### 8a. Ollama
**Branch: `claude/deploy-ollama`** | **Namespace: `ai`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ollama/ollama:latest` |
| Chart | bjw-s app-template |
| Storage | 50Gi Longhorn (`/root/.ollama`) |
| Auth | N/A (ClusterIP only) |
| Service | ClusterIP on port 11434 |
| Resources | 2000m CPU / 4Gi RAM (CPU-only) |

GPU future-proofing:
```yaml
# Uncomment when GPU node is added:
# nodeSelector:
#   gpu: "true"
# tolerations:
#   - key: nvidia.com/gpu
#     operator: Exists
#     effect: NoSchedule
# resources:
#   limits:
#     nvidia.com/gpu: 1
```

Suitable CPU-only models: `llama3.2:3b`, `phi3:mini`, `mistral:7b-instruct`, `qwen2.5:7b`

Files:
```
kubernetes/apps/ai/ollama/ks.yaml
kubernetes/apps/ai/ollama/app/{kustomization,helmrelease,ocirepository}.yaml
```

#### 8b. Qdrant (Vector Database)
**Branch: `claude/deploy-qdrant`** | **Namespace: `ai`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `qdrant/qdrant:latest` |
| Chart | bjw-s app-template |
| Storage | 5Gi Longhorn (`/qdrant/storage`) |
| Service | ClusterIP on ports 6333 (HTTP) / 6334 (gRPC) |
| Resources | 100m CPU / 256Mi RAM |

Used by: n8n (RAG workflows), OpenWebUI (document search)

Files:
```
kubernetes/apps/ai/qdrant/ks.yaml
kubernetes/apps/ai/qdrant/app/{kustomization,helmrelease,ocirepository}.yaml
```

#### 8c. OpenWebUI
**Branch: `claude/deploy-openwebui`** | **Namespace: `ai`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/open-webui/open-webui:main` |
| Chart | bjw-s app-template |
| Storage | 5Gi Longhorn (`/app/backend/data`) |
| Auth | **Native OIDC** (Authentik) |
| Route | `chat.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 200m CPU / 512Mi RAM |
| 1Password | `openwebui` (oidc_client_id, oidc_client_secret) |

Key env vars:
```
OLLAMA_BASE_URL=http://ollama.ai.svc.cluster.local:11434
OPENID_PROVIDER_URL=https://authentik.${SECRET_DOMAIN}/application/o/openwebui/.well-known/openid-configuration
ENABLE_OAUTH_SIGNUP=true
WEBUI_URL=https://chat.${SECRET_DOMAIN}
```

Files:
```
kubernetes/apps/ai/openwebui/ks.yaml
kubernetes/apps/ai/openwebui/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

#### 8d. n8n (Workflow Automation)
**Branch: `claude/deploy-n8n`** | **Namespace: `ai`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `docker.n8n.io/n8nio/n8n:latest` |
| Chart | bjw-s app-template |
| Storage | 1Gi Longhorn (`/home/node/.n8n`) |
| Database | PostgreSQL 17 (sidecar) |
| Auth | Forward-auth via Authentik (simplest), or community OIDC |
| Route | `n8n.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 200m CPU / 512Mi RAM |
| 1Password | `n8n` (db_password, encryption_key) |

Key env vars:
```
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=localhost
N8N_ENCRYPTION_KEY=${ENCRYPTION_KEY}   # CRITICAL: never change after set
WEBHOOK_URL=https://n8n.${SECRET_DOMAIN}
N8N_EDITOR_BASE_URL=https://n8n.${SECRET_DOMAIN}
```

Inter-app connections:
- Ollama: `http://ollama.ai.svc.cluster.local:11434`
- Qdrant: `http://qdrant.ai.svc.cluster.local:6333`

Files:
```
kubernetes/apps/ai/n8n/ks.yaml
kubernetes/apps/ai/n8n/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

---

### Phase 9: Books
Can deploy in parallel with other phases.

#### 9a. BookLore (eBooks)
**Branch: `claude/deploy-booklore`** | **Namespace: `media`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/booklore-app/booklore:latest` |
| Chart | bjw-s app-template |
| Storage | `/app/data`: 1Gi Longhorn, `/books`: NFS (`/data/media/ebook`), `/bookdrop`: NFS (auto-import dir) |
| Database | MariaDB 11 (sidecar) |
| Auth | **Native OIDC** (Authentik) |
| Route | `books.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 200m CPU / 512Mi RAM |
| 1Password | `booklore` (db_password, oidc_client_id, oidc_client_secret) |

Files:
```
kubernetes/apps/media/booklore/ks.yaml
kubernetes/apps/media/booklore/app/{kustomization,helmrelease,ocirepository,externalsecret}.yaml
```

#### 9b. Audiobookshelf (Audiobooks)
**Branch: `claude/deploy-audiobookshelf`** | **Namespace: `media`** | **Migration: No**

| Field | Value |
|-------|-------|
| Image | `ghcr.io/advplyr/audiobookshelf:latest` |
| Chart | bjw-s app-template |
| Storage | `/config`: 1Gi Longhorn, `/metadata`: 2Gi Longhorn, `/audiobooks`: NFS (`/data/media/audiobook`) |
| Auth | Forward-auth via Authentik (has built-in auth but no OIDC) |
| Route | `audiobooks.${SECRET_DOMAIN}` → envoy-internal |
| Resources | 100m CPU / 256Mi RAM |
| 1Password | Not needed |

Notes:
- Has built-in user management and mobile apps (iOS/Android)
- Supports audiobooks + podcasts
- Progress sync across devices
- BookLore handles ebooks, Audiobookshelf handles audiobooks

Files:
```
kubernetes/apps/media/audiobookshelf/ks.yaml
kubernetes/apps/media/audiobookshelf/app/{kustomization,helmrelease,ocirepository}.yaml
```

---

## Inter-App Connection Map

```
                     ┌─────────────┐
                     │  Seerr │ (requests.${DOMAIN}) [PUBLIC]
                     │  Port 5055  │
                     └──┬──────┬───┘
                        │      │
              Movie req │      │ TV req
                        ▼      ▼
  ┌──────────┐  ┌────────┐ ┌────────┐  ┌──────────┐
  │ Bazarr   │  │ Radarr │ │ Sonarr │  │Radarr-4K │
  │ (subs)   │→ │  7878  │ │  8989  │  │   7878   │
  │  6767    │  └──┬─────┘ └──┬─────┘  └──┬───────┘
  └──────────┘     │          │            │
                   └────┬─────┴────────────┘
                        │  "Search indexers"        │ Webhooks
                        ▼                           ▼
                  ┌───────────┐               ┌───────────┐
                  │  Prowlarr │               │ Autoscan  │
                  │   9696    │               │   3030    │
                  └───────────┘               └──┬────────┘
                        │                        │ "Trigger scan"
                 "Found release"                 ▼
                   ┌────┴────┐              ┌──────────┐
                   ▼         ▼              │   Plex   │←── Tautulli (8181)
             ┌──────────┐ ┌──────────────┐  │  32400   │
             │ SABnzbd  │ │ qBittorrent  │  └──────────┘
             │  (8080)  │ │ + Gluetun VPN│
             │  Usenet  │ │ (8080)       │
             └──┬───────┘ └──┬───────────┘
                │            │
                └────┬───────┘
                     ▼
               ┌───────────┐
               │ Unpackerr │ (extracts archives, monitors *arr apps)
               └───────────┘

  ┌───────────┐
  │ Recyclarr │ (CronJob: syncs TRaSH quality profiles to Sonarr/Radarr)
  └───────────┘

  ┌───────────┐
  │ Notifiarr │ → notifiarr.com → Discord/Slack (monitors all *arr apps + Plex)
  └───────────┘

  Teslamate Stack:
  ┌───────────┐    ┌────────────┐    ┌──────────────────┐
  │ Teslamate │───▶│ PostgreSQL │    │ Mosquitto (home)  │
  │           │    │  (sidecar) │    │ (shared, existing)│
  └─────┬─────┘    └──────┬─────┘    └──────────────────┘
        │                 │
        │                 ▼
        │           ┌───────────┐
        └──────────▶│  Grafana  │ (standalone, monitoring ns)
                    │ + dashboards via ConfigMap sidecar
                    └───────────┘

  AI Stack:
  ┌──────────┐    ┌──────────┐    ┌────────┐
  │ OpenWebUI│───▶│  Ollama  │    │ Qdrant │
  │ (chat UI)│    │ (LLM API)│    │(vectors)│
  └──────────┘    └──────────┘    └────┬───┘
                       ▲               │
                       │               │
                  ┌────┴───┐           │
                  │  n8n   │◀──────────┘
                  │(workflows)│
                  └────────┘
```

---

## Migration Plan

### Apps Being Migrated

These apps currently run as Docker containers on the Synology NAS:
- **Prowlarr**, **Sonarr**, **Radarr**, **Radarr-4K** (indexer + *arr stack)
- **Autoscan** (Plex library scanner)
- **Overseerr/Seerr** → migrating to **Seerr** (can import Overseerr DB)
- **Tautulli** (Plex monitoring)
- **Teslamate** (Tesla data logger + PostgreSQL)

### Migration Strategy Per App Type

#### *Arr Apps (Prowlarr, Sonarr, Radarr, Radarr-4K)

These store all config in a SQLite database under `/config`. Migration steps:

1. **Export from Docker**: Stop the Docker container and copy the `/config` directory
   ```bash
   # On Synology NAS - identify Docker volume paths
   docker inspect <container> | jq '.[0].Mounts'
   # Copy config directory to a known NFS path
   cp -r /volume1/docker/<app>/config /volume2/kubes/migration/<app>/
   ```

2. **Import to K8s**: Use an init container or manual copy to populate the Longhorn PVC
   ```bash
   # Option A: kubectl cp into a temp pod that mounts the PVC
   kubectl run migration-<app> --image=busybox --restart=Never \
     --overrides='{"spec":{"containers":[{"name":"migration","image":"busybox","command":["sleep","3600"],"volumeMounts":[{"name":"config","mountPath":"/config"}]}],"volumes":[{"name":"config","persistentVolumeClaim":{"claimName":"<app>-config"}}]}}' -n media
   kubectl cp /path/to/config/ migration-<app>:/config/ -n media
   kubectl delete pod migration-<app> -n media

   # Option B: NFS staging (simpler)
   # Place config at NFS path, use init container to copy from NFS to PVC on first boot
   ```

3. **Fix paths in config DB**: The *arr apps store root folder paths and download client paths in their SQLite database. These need updating:
   ```
   Docker local path: /media/movies  →  K8s NFS mount: /data/media/movies
   Docker local path: /media/tv      →  K8s NFS mount: /data/media/tv
   Docker local path: /downloads     →  K8s NFS mount: /data/media/download
   ```
   Use `sqlite3` to update paths in the database, or reconfigure via the web UI after first boot.

4. **Update API connections**: After K8s deployment, update:
   - Download client URLs: `http://sabnzbd.media.svc.cluster.local:8080`, `http://qbittorrent.media.svc.cluster.local:8080`
   - Prowlarr sync: Update *arr app URLs to K8s service names
   - Webhook URLs: Update to `http://autoscan.media.svc.cluster.local:3030/triggers/...`

5. **Preserve API keys**: Extract existing API keys from each app's config and store them in 1Password items. This allows other apps to continue using the same keys.

#### Autoscan

Autoscan uses a YAML config file and a small SQLite database:

1. Copy config from Docker volume
2. Update `autoscan.yml` with K8s service URLs (Plex, *arr webhook paths)
3. The ConfigMap in K8s will be the source of truth going forward

#### Overseerr → Seerr

Seerr is a fork that can read Overseerr's database:

1. Copy Overseerr's `/app/config` directory (contains `db/` with SQLite databases)
2. Mount into Seerr's `/app/config` volume
3. Seerr reads the Overseerr format and migrates on first startup
4. Update Plex/Sonarr/Radarr connection URLs to K8s services

#### Tautulli

Simple SQLite-based migration:

1. Copy `/config` directory from Docker volume
2. Mount into K8s PVC
3. Update Plex connection URL to `http://plex.media.svc.cluster.local:32400`

#### Teslamate (PostgreSQL)

Teslamate uses PostgreSQL, requiring a database dump/restore:

1. **Dump from Docker PostgreSQL**:
   ```bash
   docker exec teslamate-db pg_dump -U teslamate teslamate > teslamate_backup.sql
   ```

2. **Deploy K8s Teslamate with empty DB** (PostgreSQL sidecar creates the database)

3. **Restore into K8s PostgreSQL**:
   ```bash
   # Port-forward to the PG sidecar
   kubectl port-forward pod/teslamate-<hash> 5432:5432 -n home
   # Restore
   psql -h localhost -U teslamate teslamate < teslamate_backup.sql
   ```

4. Update Teslamate env vars with new DB connection (already handled by K8s config)

### Migration Execution Order

1. Deploy K8s app with empty config first (validate deployment works)
2. Scale down to 0 replicas
3. Stop Docker container on NAS
4. Copy data from Docker volume → K8s PVC (via NFS staging area)
5. Scale K8s app back up
6. Verify functionality
7. Remove Docker container only after K8s is confirmed working

### Path Mapping Reference (from docker-compose.yaml analysis)

**Environment variables in Docker:**
- `$MEDIADIR` = NFS media share root (e.g., `/volume1/media`)
- `$DOCKERDIR` = Docker config directory (e.g., `/volume1/docker`)
- `$TEMPDIR` = Temp directory

| App | Docker Volume Mount | K8s Container Path | Storage |
|-----|--------------------|--------------------|---------|
| **Plex** | `$DOCKERDIR/plex:/config` | `/config` | Longhorn 10Gi |
| | `$MEDIADIR/movies:/data/movies` | `/data/media/movies` | NFS |
| | `$MEDIADIR/movies4k:/data/movies4k` | `/data/media/movies-4k` | NFS |
| | `$MEDIADIR/tvshows:/data/tvshows` | `/data/media/tv` | NFS |
| | `$MEDIADIR/tvrecordings:/data/tvrecordings` | `/data/media/tvrecordings` | NFS |
| | `$MEDIADIR/courses:/data/courses` | `/data/media/courses` | NFS |
| | `$MEDIADIR/workouts:/data/workouts` | `/data/media/workouts` | NFS |
| | `$TEMPDIR/transcode:/transcode` | `/transcode` | emptyDir |
| **Sonarr** | `$DOCKERDIR/sonarr:/config` | `/config` | Longhorn 2Gi |
| | `$MEDIADIR/tvshows:/tv` | `/data/media/tv` | NFS |
| | `$MEDIADIR/downloads:/downloads` | `/data/media/download` | NFS |
| **Radarr** | `$DOCKERDIR/radarr:/config` | `/config` | Longhorn 2Gi |
| | `$MEDIADIR/movies:/movies` | `/data/media/movies` | NFS |
| | `$MEDIADIR/downloads:/downloads` | `/data/media/download` | NFS |
| **Radarr-4K** | `$DOCKERDIR/radarr4k:/config` | `/config` | Longhorn 2Gi |
| | `$MEDIADIR/movies4k:/movies` | `/data/media/movies-4k` | NFS |
| | `$MEDIADIR/downloads:/downloads` | `/data/media/download` | NFS |
| **Prowlarr** | `$DOCKERDIR/prowlarr:/config` | `/config` | Longhorn 1Gi |
| | `$MEDIADIR/downloads:/downloads` | `/data/media/download` | NFS |
| **Autoscan** | `$DOCKERDIR/autoscan:/config` | `/config` | Longhorn 256Mi |
| | `$MEDIADIR:/mnt/media:ro` | `/data/media` | NFS (read-only) |
| **Overseerr→Seerr** | `$DOCKERDIR/overseerr:/app/config` | `/app/config` | Longhorn 1Gi |
| **Tautulli** | `$DOCKERDIR/tautulli:/config` | `/config` | Longhorn 1Gi |
| | `$DOCKERDIR/plex/.../Logs:/plex_logs:ro` | N/A (remove in K8s) | - |
| **Teslamate** | `$DOCKERDIR/teslamate/teslamate:/opt/app/import` | `/opt/app/import` | Longhorn |
| **Teslamate DB** | `$DOCKERDIR/teslamate/teslamate_db:/var/lib/postgresql/data` | `/var/lib/postgresql/data` | Longhorn 5Gi |
| **Teslamate MQTT** | `$DOCKERDIR/teslamate/teslamate_mqtt/*` | N/A (use existing Mosquitto) | - |
| **Teslamate Grafana** | `$DOCKERDIR/teslamate/teslamate_grafana:/var/lib/grafana` | N/A (use standalone Grafana) | - |
| **MeTube** | `$MEDIADIR/metube:/downloads` | `/downloads` → `/data/media/youtube` | NFS |
| | `$DOCKERDIR/metube:/metube-config` | `/metube-config` | Longhorn 256Mi |

**Important path changes requiring config updates after migration:**
```
Docker: /movies          → K8s: /data/media/movies
Docker: /movies (4K)     → K8s: /data/media/movies-4k
Docker: /tv              → K8s: /data/media/tv
Docker: /downloads       → K8s: /data/media/download
Docker: /data (rtorrent) → K8s: /data/media/download/torrents
```

---

## Secret Automation Plan

### For Migrating Apps (Existing Secrets)
Apps that already have API keys and configs running in Docker will have their existing secrets extracted and stored in 1Password:

```bash
# Extract API key from existing *arr app config
# (Run on Synology NAS where Docker containers run)
sqlite3 /path/to/config/sonarr.db "SELECT Value FROM Config WHERE Key='ApiKey'"

# Store in 1Password using the /secrets skill
/secrets create app=sonarr fields=api_key
# Then manually set the value from the extracted key
```

### For New Apps (Auto-Generated Secrets)

For apps that are NOT migrating and need fresh secrets, we will create a bootstrap script that generates secure credentials and stores them in 1Password.

**Strategy**: Use a shell script with the 1Password CLI (`op`) to create all items:

```bash
#!/usr/bin/env bash
# scripts/create-app-secrets.sh
# Creates 1Password items with secure auto-generated credentials
# Requires: op (1Password CLI) authenticated

VAULT="homeops"

create_secret() {
  local item_name="$1"
  shift
  local fields=()
  while [[ $# -gt 0 ]]; do
    local field_name="$1"
    local field_type="${2:-password}"  # password, text
    local length="${3:-40}"
    fields+=("${field_name}[${field_type}]=$(op generate password --length=${length} --letters --digits --symbols)")
    shift 3
  done
  op item create --vault="$VAULT" --category=login --title="$item_name" "${fields[@]}"
}

# Generate all new app secrets
create_secret "gatus"      "oidc_client_id" "text" 32 "oidc_client_secret" "password" 64
create_secret "grafana"    "admin_password" "password" 40 "oidc_client_id" "text" 32 "oidc_client_secret" "password" 64
create_secret "forgejo"    "db_password" "password" 40 "admin_password" "password" 40 "oidc_client_id" "text" 32 "oidc_client_secret" "password" 64 "secret_key" "password" 64 "lfs_jwt_secret" "password" 64
create_secret "zipline"    "db_password" "password" 40 "core_secret" "password" 64
create_secret "sabnzbd"    "api_key" "password" 32 "nzb_key" "password" 32
create_secret "qbittorrent" "vpn_username" "text" 0 "vpn_password" "password" 0 "vpn_endpoint" "text" 0
create_secret "shlink"     "db_password" "password" 40 "initial_api_key" "password" 64 "geolite_license_key" "text" 0
create_secret "teslamate"  "db_password" "password" 40 "encryption_key" "password" 64 "mqtt_password" "password" 32
create_secret "n8n"        "db_password" "password" 40 "encryption_key" "password" 64
create_secret "openwebui"  "oidc_client_id" "text" 32 "oidc_client_secret" "password" 64
create_secret "booklore"   "db_password" "password" 40 "oidc_client_id" "text" 32 "oidc_client_secret" "password" 64
create_secret "plex"       "plex_claim" "text" 0
```

**Notes**:
- Fields marked with length `0` require manual input (VPN credentials, Plex claim tokens, GeoLite license keys)
- OIDC client_id/client_secret are generated by the script but must also be configured in Authentik (create an Application + OAuth2 Provider per app)
- Password specs: 40+ chars for DB passwords, 64 chars for encryption/signing keys, mixed letters+digits+symbols
- For apps that can't handle special characters: use `--no-symbols` flag
- The script is idempotent - `op item create` will fail if item already exists (use `--force` to overwrite)

**Alternative: Kubernetes Job approach** (create secrets at cluster runtime):
- Deploy a one-time Job that runs `op` CLI to generate and store secrets
- Advantage: No local CLI needed
- Disadvantage: Needs 1Password CLI and credentials in-cluster (already available via 1Password Connect)
- Decision: **CLI script is simpler and more auditable.** Run it once during initial setup.

### Authentik Application Setup

For each app using OIDC, an Authentik Application + OAuth2 Provider must be created. This can be done via the Authentik admin UI or API:

| App | Authentik Application Slug | Redirect URI |
|-----|---------------------------|-------------|
| Gatus | `gatus` | `https://gatus.${DOMAIN}/authorization-code/callback` |
| OpenWebUI | `openwebui` | `https://chat.${DOMAIN}/oauth/oidc/callback` |
| Forgejo | `forgejo` | `https://git.${DOMAIN}/user/oauth2/authentik/callback` |
| BookLore | `booklore` | `https://books.${DOMAIN}/api/auth/oidc/callback` |
| Zipline | `zipline` | `https://zipline.${DOMAIN}/api/auth/oauth/oidc` |
| Grafana | `grafana` | `https://grafana.${DOMAIN}/login/generic_oauth` |

For forward-auth apps, a single Authentik **Proxy Provider** with forward-auth mode handles all of them through the gateway-level SecurityPolicy.

---

## 1Password Items Summary

### Migrating Apps (extract existing secrets)
| Item | Fields | Source |
|------|--------|--------|
| `prowlarr` | `api_key` | Extract from Docker config DB |
| `sonarr` | `api_key` | Extract from Docker config DB |
| `radarr` | `api_key` | Extract from Docker config DB |
| `radarr-4k` | `api_key` | Extract from Docker config DB |
| `autoscan` | `plex_token` | Extract from Docker config |
| `seerr` | `plex_token` | Extract from Overseerr config |
| `tautulli` | `api_key`, `plex_token` | Extract from Docker config |
| `teslamate` | `db_password`, `encryption_key`, `mqtt_password` | Extract from Docker env/config |

### New Apps (auto-generate via script)
| Item | Fields |
|------|--------|
| `gatus` | `oidc_client_id`, `oidc_client_secret` |
| `grafana` | `admin_password`, `oidc_client_id`, `oidc_client_secret` |
| `plex` | `plex_claim` (manual: generate at plex.tv/claim) |
| `sabnzbd` | `api_key`, `nzb_key` |
| `qbittorrent` | `vpn_username`, `vpn_password`, `vpn_endpoint` (manual: VPN provider) |
| `recyclarr` | `sonarr_api_key`, `radarr_api_key`, `radarr_4k_api_key` (cross-ref from *arr items) |
| `unpackerr` | `sonarr_api_key`, `radarr_api_key`, `radarr_4k_api_key` (cross-ref from *arr items) |
| `notifiarr` | `api_key` (from notifiarr.com), `sonarr_api_key`, `radarr_api_key`, `plex_token` |
| `shlink` | `db_password`, `initial_api_key`, `geolite_license_key` (manual: MaxMind) |
| `teslamate` | `db_password`, `encryption_key`, `mqtt_password` |
| `forgejo` | `db_password`, `admin_password`, `oidc_client_id`, `oidc_client_secret`, `secret_key`, `lfs_jwt_secret` |
| `zipline` | `db_password`, `core_secret` |
| `n8n` | `db_password`, `encryption_key` |
| `openwebui` | `oidc_client_id`, `oidc_client_secret` |
| `booklore` | `db_password`, `oidc_client_id`, `oidc_client_secret` |

---

## Branch Strategy

Each app gets its own branch for isolated development:
- Branch naming: `claude/deploy-<app-name>-<session-id>`
- Each branch creates all files for one app
- Branches are merged to main in dependency order
- Parallel development possible for apps in the same phase

**Merge order** (critical path):
```
Phase 0 (namespaces) ─────────────────────────────────────────── MERGE FIRST
    │
    ├── Phase 1a-e (KMS, Gatus, Uptime Kuma, MeTube, Grafana) ── parallel
    ├── Phase 2a-b (Forgejo, Zipline) ──────────────────────────── parallel
    │
    ├── Phase 3a-c (Plex, SABnzbd, qBittorrent) ──────────────── MERGE BEFORE Phase 4
    │       │
    │       ├── Phase 4a (Prowlarr) ────────────────────── MERGE BEFORE other *arr apps
    │       │       │
    │       │       ├── Phase 4b-d (Sonarr, Radarr, Radarr-4K) ── parallel
    │       │       │       │
    │       │       │       ├── Phase 5a-h (support apps) ──────────────── parallel
    │       │
    ├── Phase 6 (Shlink) ──────────────────────────────────────── independent
    ├── Phase 7 (Teslamate → home ns) ──────────────────────────── after Grafana
    ├── Phase 8a (Ollama) → 8b-d (Qdrant, OpenWebUI, n8n) ────── sequential
    ├── Phase 9a-b (BookLore, Audiobookshelf) ─────────────────── independent
```

---

## Verification Plan

For each deployed app:

1. **Pre-commit**: `task validate` (flux-local validation)
2. **Flux sync**: `flux get ks <app-name> && flux get hr <app-name> -n <namespace>`
3. **Pod health**: `kubectl get pods -n <namespace> -l app.kubernetes.io/name=<app-name>`
4. **ExternalSecret**: `kubectl get externalsecret <app-name> -n <namespace>` → "SecretSynced"
5. **Service**: `kubectl port-forward svc/<app-name> <local-port>:<port> -n <namespace>`
6. **Route**: `curl -I https://<app>.${SECRET_DOMAIN}` (from local network)
7. **Auth**: Verify Authentik login redirect and session
8. **Inter-app**: Test API connections (e.g., Sonarr → Prowlarr, Autoscan → Plex)
9. **Migration**: For migrated apps, verify data integrity (library counts, history)

---

## Resource Estimate (Total)

| Resource | Estimate |
|----------|----------|
| CPU requests | ~5.5 cores |
| Memory requests | ~14 Gi |
| Longhorn PVCs | ~140 Gi (+ 50-100Gi Ollama models) |
| NFS (media) | Existing share |
| PostgreSQL instances | 5 (Forgejo, Zipline, Shlink, Teslamate, n8n) |
| MariaDB instances | 1 (BookLore) |

Well within a 3-node cluster capacity, though the AI stack (Ollama) will be the heaviest single consumer. Monitor Longhorn capacity closely as model storage grows.

---

## Deployment Status

This section is the **source of truth** for tracking progress across sessions. Update it after each deployment action.

**Last updated:** 2026-02-12
**Current focus:** Phase 0+1 manifests created, ready for merge and reconcile

### Status Legend

| Status | Meaning |
|--------|---------|
| `not started` | Work has not begun |
| `in progress` | Branch created, actively developing manifests |
| `deployed` | Manifests merged to main, Flux has reconciled, pods running |
| `verified` | App tested end-to-end (UI, auth, inter-app connections) |
| `migrated` | Data migrated from Docker, old container decommissioned |
| `blocked` | Cannot proceed, see Notes column |

### Phase 0: Shared Infrastructure

| Component | Status | Branch | Notes |
|-----------|--------|--------|-------|
| Namespaces (media, ai, tools, monitoring) | `in progress` | `claude/plan-cluster-deployment-KkwZ1` | Manifests created, pending merge |
| Shared NFS PV/PVC for media | `not started` | — | Deferred to Phase 3; using same NAS (`NFS_SERVER`), share `/volume1/media`; will use 1Password for hostname/IP mapping |

### Phase 1: Simple Independent Apps

| App | Status | Branch | Secrets Created | Auth Configured | Notes |
|-----|--------|--------|-----------------|-----------------|-------|
| 1a. KMS | `in progress` | `claude/plan-cluster-deployment-KkwZ1` | N/A | N/A | vlmcsd, LoadBalancer TCP/1688 |
| 1b. Gatus | `in progress` | `claude/plan-cluster-deployment-KkwZ1` | No | No | ConfigMap with basic endpoints; OIDC deferred |
| 1c. Uptime Kuma | `in progress` | `claude/plan-cluster-deployment-KkwZ1` | N/A | No | v2 tag, 2Gi Longhorn |
| 1d. MeTube | `in progress` | `claude/plan-cluster-deployment-KkwZ1` | N/A | No | Longhorn temp storage; switch to NFS in Phase 3 |
| 1e. Grafana | `in progress` | `claude/plan-cluster-deployment-KkwZ1` | No | No | Official chart v8.9.0; Teslamate datasource in Phase 7 |

### Phase 2: Forgejo + Zipline

| App | Status | Branch | Secrets Created | Auth Configured | Notes |
|-----|--------|--------|-----------------|-----------------|-------|
| 2a. Forgejo | `not started` | — | No | No | |
| 2b. Zipline | `not started` | — | No | No | OIDC configured post-deploy via UI |

### Phase 3: Media Infrastructure

| App | Status | Branch | Secrets Created | Auth Configured | Notes |
|-----|--------|--------|-----------------|-----------------|-------|
| 3a. Plex | `not started` | — | No | N/A (Plex.tv) | Claim token expires in 4min, generate at deploy time |
| 3b. SABnzbd | `not started` | — | No | No | |
| 3c. qBittorrent + Gluetun | `not started` | — | No | No | VPN creds needed (manual) |

### Phase 4: *Arr Stack

| App | Status | Branch | Secrets Created | Auth Configured | Migration | Notes |
|-----|--------|--------|-----------------|-----------------|-----------|-------|
| 4a. Prowlarr | `not started` | — | No | No | Not started | Deploy before other *arr apps |
| 4b. Sonarr | `not started` | — | No | No | Not started | |
| 4c. Radarr | `not started` | — | No | No | Not started | |
| 4d. Radarr-4K | `not started` | — | No | No | Not started | |

### Phase 5: Media Support & Automation

| App | Status | Branch | Secrets Created | Auth Configured | Migration | Notes |
|-----|--------|--------|-----------------|-----------------|-----------|-------|
| 5a. Autoscan | `not started` | — | No | N/A | Not started | |
| 5b. Seerr | `not started` | — | No | N/A (Plex OAuth) | Not started | Migrating from Overseerr |
| 5c. Tautulli | `not started` | — | No | No | Not started | |
| 5d. Bazarr | `not started` | — | N/A | No | N/A | |
| 5e. Recyclarr | `not started` | — | No | N/A | N/A | |
| 5f. Unpackerr | `not started` | — | No | N/A | N/A | |
| 5g. Notifiarr | `not started` | — | No | N/A | N/A | Needs notifiarr.com account |

### Phase 6: Shlink Stack

| App | Status | Branch | Secrets Created | Auth Configured | Notes |
|-----|--------|--------|-----------------|-----------------|-------|
| 6. Shlink + Web + PG | `not started` | — | No | No (web: forward-auth) | Fresh install (not migrating MySQL data) |

### Phase 7: Teslamate Stack

| App | Status | Branch | Secrets Created | Auth Configured | Migration | Notes |
|-----|--------|--------|-----------------|-----------------|-----------|-------|
| 7. Teslamate + PG | `not started` | — | No | No | Not started | pg_dump/restore from Docker PG15→K8s PG17 |
| 7. Grafana dashboards | `not started` | — | N/A | N/A | N/A | ConfigMaps with dashboard JSONs |

### Phase 8: AI Stack

| App | Status | Branch | Secrets Created | Auth Configured | Notes |
|-----|--------|--------|-----------------|-----------------|-------|
| 8a. Ollama | `not started` | — | N/A | N/A | CPU-only, heaviest resource consumer |
| 8b. Qdrant | `not started` | — | N/A | N/A | |
| 8c. OpenWebUI | `not started` | — | No | No | |
| 8d. n8n | `not started` | — | No | No | |

### Phase 9: Books

| App | Status | Branch | Secrets Created | Auth Configured | Notes |
|-----|--------|--------|-----------------|-----------------|-------|
| 9a. BookLore | `not started` | — | No | No | |
| 9b. Audiobookshelf | `not started` | — | N/A | No | |

### Blockers & Open Questions

| Item | Status | Details |
|------|--------|---------|
| NFS media server/share path | **Confirmed** | Same NAS as `NFS_SERVER`, share path `/volume1/media`; will use 1Password item `cluster-network` for hostname/IP mapping |
| VPN provider credentials | **Needs manual input** | qBittorrent/Gluetun: vpn_username, vpn_password, vpn_endpoint |
| Plex claim token | **Generate at deploy time** | https://plex.tv/claim — expires in 4 minutes |
| GeoLite license key | **Needs manual input** | For Shlink IP geolocation (free MaxMind account) |
| Notifiarr.com account | **Needs manual setup** | Free account required for notification routing |
| Authentik OIDC providers | **Not started** | 6 apps need OAuth2 providers created in Authentik UI |
| Authentik forward-auth | **Not started** | Proxy provider + SecurityPolicy for ~10 apps |

### Session Log

Track what was accomplished in each working session for continuity.

| Date | Session | Work Completed |
|------|---------|----------------|
| 2026-02-12 | Initial planning | Created comprehensive deployment plan with all 9 phases, architecture decisions, migration strategy, and status tracking |
| 2026-02-12 | Phase 0 + Phase 1 | Created 4 namespaces (media, ai, tools, monitoring). Deployed Phase 1 apps: KMS (tools), Gatus + Uptime Kuma + Grafana (monitoring), MeTube (media). NFS media PV/PVC deferred to Phase 3; user confirmed same NAS at `/volume1/media`, will use 1Password for hostname/IP mapping. All YAML validated. |
| | | *Next: Merge to main, reconcile, verify pods. Then Phase 2 (Forgejo + Zipline).* |
