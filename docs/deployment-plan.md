# Cluster Application Deployment Plan

> **Note:** Sensitive details (network topology, internal service URLs, secret naming, migration commands, storage paths, redirect URIs, and private contact details) are stored in `.private/PRD.md` (gitignored). This public version covers architecture, phases, auth policy, and status tracking.

## Context

This plan covers deploying ~30+ applications into an existing Talos Linux / Flux CD Kubernetes cluster. The cluster already has core infrastructure (Cilium, Envoy Gateway, Authentik, External Secrets + 1Password, Longhorn, NFS CSI, cert-manager, Cloudflare Tunnel, Mosquitto MQTT). The goal is a well-organized, GitOps-managed deployment with explicit auth decisions for routed apps, sane defaults, and proper inter-app connections.

Several apps are currently running as Docker containers on the NAS and need to be migrated with their data intact.

---

## Key Architecture Decisions

### Database Strategy: Individual DBs Per App

**Deploy individual PostgreSQL/MariaDB instances per app** as sidecar containers using the bjw-s app-template multi-controller pattern.

Rationale:
- **Isolation**: One app's DB issue won't cascade to others
- **Independent lifecycle**: Backup, restore, upgrade each DB independently
- **Version flexibility**: Different apps may need different PG versions
- **Simpler troubleshooting**: Each app owns its own data
- **Minimal overhead**: Small PG instances use ~64-128MB RAM each

### Chosen Alternatives

| Original Request | Chosen App | Reason |
|-----------------|------------|--------|
| nzbget | **SABnzbd** | nzbget was abandoned 2019-2021; SABnzbd is actively maintained with better K8s support |
| rTorrent | **qBittorrent** | Modern REST API, built-in web UI, Gluetun VPN sidecar support |
| Overseerr | **Seerr** | Overseerr being deprecated; Seerr is the unified successor supporting Plex+Jellyfin |
| Gitea | **Forgejo** | 2.5x more commits, fully open-source, OCI Helm chart, non-profit governance |
| Calibre + Calibre-web | **Grimmory** (ebooks) + **Audiobookshelf** (audiobooks) | Grimmory is the BookLore successor; Audiobookshelf remains the audiobook app |
| transfer.sh | **Zipline** | Zipline has native OIDC, URL shortening, rich upload features; transfer.sh is effectively abandoned |

### Namespace Organization

| Namespace | Apps |
|-----------|------|
| `media` | Plex, SABnzbd, qBittorrent+Gluetun, Prowlarr, Radarr, Radarr-4K, Sonarr, Autoscan, Seerr, Tautulli, MeTube, Bazarr, Recyclarr, Unpackerr, Notifiarr, Grimmory, Audiobookshelf |
| `ai` | Ollama, OpenWebUI, n8n, Qdrant |
| `tools` | Shlink, Shlink-web, Forgejo, KMS, Zipline |
| `monitoring` | Gatus, Grafana |
| `home` | Teslamate |

### Storage Strategy

- **App configs** (`/config`): Longhorn (fast, replicated SSD storage)
- **Media files**: NFS (existing media share, high capacity)
- **Downloads**: NFS (same media share, hardlink-compatible)
- **AI models**: Longhorn (large PVC, 50-100Gi for Ollama)
- **Databases**: Longhorn (performance-critical)
- **Books**: NFS (existing ebook/audiobook folders on media share)

### Authentication Strategy

Authentication policy is defined in `docs/architecture/authentication.md`.

- **External apps** must always have an explicit auth decision recorded.
- **Internal apps** may remain open by default, but the chosen auth mode should still be documented.
- **Allowed modes** are native OIDC/OAuth, forward-auth, public exception, and app-native external identity exceptions.

### Public vs Internal Access

| Access | Apps |
|--------|------|
| **External** (via Cloudflare Tunnel) | Seerr, Shlink (redirects), Zipline |
| **Internal** (local network only) | Everything else with a web UI |
| **ClusterIP only** (no ingress) | Internal-only APIs, daemons, databases |

---

## Deployment Phases & Order

### Phase 0: Shared Infrastructure

Create new namespaces (`media`, `ai`, `tools`, `monitoring`) and register them with Flux.

Also includes **Tailscale Operator** (network namespace) for Tailnet connectivity:
- Exit node capability
- Cluster resource access from Tailnet
- Home network access from Tailnet

### Phase 1: Simple Independent Apps

No dependencies on other apps. Can be deployed in parallel.

| App | Namespace | Chart | Auth | Notes |
|-----|-----------|-------|------|-------|
| 1a. KMS (vlmcsd) | tools | app-template | N/A (TCP only) | LoadBalancer TCP/1688 |
| 1b. Gatus | monitoring | app-template | Native OIDC | Endpoint monitoring, ConfigMap-driven |
| 1c. MeTube | media | app-template | Forward-auth | YouTube downloader |
| 1d. Grafana | monitoring | Official chart | Native OIDC | Dashboard sidecar for auto-discovery |

### Phase 2: Forgejo + Zipline

Independent of each other, can deploy in parallel.

| App | Namespace | Chart | Auth | Notes |
|-----|-----------|-------|------|-------|
| 2a. Forgejo | tools | Official OCI | Native OIDC | Git hosting, bundled PostgreSQL |
| 2b. Zipline | tools | app-template | Native OIDC | File sharing, PostgreSQL sidecar, PUBLIC |

### Phase 3: Media Infrastructure

Must deploy before *arr apps since Sonarr/Radarr need download clients configured.

| App | Namespace | Chart | Auth | Notes |
|-----|-----------|-------|------|-------|
| 3a. Plex | media | app-template | Plex.tv | Secondary server, CPU transcoding |
| 3b. SABnzbd | media | app-template | Forward-auth | Usenet download client |
| 3c. qBittorrent + Gluetun | media | app-template | Forward-auth | Torrent client with VPN sidecar |

### Phase 4: *Arr Stack

Depends on Phase 3. **MIGRATION APPS** from Docker.

| App | Namespace | Migration | Notes |
|-----|-----------|-----------|-------|
| 4a. Prowlarr | media | Yes | Deploy first; other *arr apps reference it |
| 4b. Sonarr | media | Yes | TV show management |
| 4c. Radarr | media | Yes | Movie management |
| 4d. Radarr-4K | media | Yes | 4K movie management (separate instance) |

### Phase 5: Media Support & Automation

Depends on Phase 3 (Plex) and Phase 4 (*arr apps).

| App | Namespace | Migration | Notes |
|-----|-----------|-----------|-------|
| 5a. Autoscan | media | Yes | Plex library scanner, receives webhooks from *arr apps |
| 5b. Seerr | media | Yes (from Overseerr) | Media request UI, PUBLIC |
| 5c. Tautulli | media | Yes | Plex monitoring |
| 5d. Bazarr | media | No | Subtitle management |
| 5e. Recyclarr | media | No | TRaSH Guides quality profiles (CronJob) |
| 5f. Unpackerr | media | No | Archive extraction daemon |
| 5g. Notifiarr | media | No | Notification hub (requires notifiarr.com account) |

### Phase 6: Shlink Stack

| App | Namespace | Notes |
|-----|-----------|-------|
| 6. Shlink + Web + PostgreSQL | tools | Fresh install (not migrating MySQL data), PUBLIC redirects |

### Phase 7: Teslamate Stack

| App | Namespace | Migration | Notes |
|-----|-----------|-----------|-------|
| 7. Teslamate + PostgreSQL | home | Yes | pg_dump/restore, Grafana dashboards via ConfigMaps |

### Phase 8: AI Stack

Ollama must be ready before OpenWebUI and n8n connect to it.

| App | Namespace | Notes |
|-----|-----------|-------|
| 8a. Ollama | ai | CPU-only LLM inference, 50Gi model storage |
| 8b. Qdrant | ai | Vector database for RAG |
| 8c. OpenWebUI | ai | Chat UI, Native OIDC |
| 8d. n8n | ai | Workflow automation, PostgreSQL sidecar |

### Phase 9: Books

Can deploy in parallel with other phases.

| App | Namespace | Notes |
|-----|-----------|-------|
| 9a. Grimmory | media | eBook management, MariaDB sidecar, internal-only for now |
| 9b. Audiobookshelf | media | Audiobook management, Forward-auth |

---

## Migration Strategy

Apps migrating from Docker follow this general process:

1. Deploy K8s app with empty config (validate deployment works)
2. Scale down to 0 replicas
3. Stop Docker container on NAS
4. Copy data from Docker volume to K8s PVC (via NFS staging area)
5. Update internal paths and service URLs in config
6. Scale K8s app back up
7. Verify functionality
8. Remove Docker container only after K8s is confirmed working

**Apps being migrated:** Prowlarr, Sonarr, Radarr, Radarr-4K, Autoscan, Overseerr (to Seerr), Tautulli, Teslamate

See `.private/PRD.md` for detailed migration commands, path mappings, and secret extraction steps.

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
    |
    +-- Phase 1a-d (KMS, Gatus, MeTube, Grafana) -------------- parallel
    +-- Phase 2a-b (Forgejo, Zipline) -------------------------- parallel
    |
    +-- Phase 3a-c (Plex, SABnzbd, qBittorrent) --------------- MERGE BEFORE Phase 4
    |       |
    |       +-- Phase 4a (Prowlarr) ---------------------------- MERGE BEFORE other *arr apps
    |       |       |
    |       |       +-- Phase 4b-d (Sonarr, Radarr, Radarr-4K) -- parallel
    |       |       |       |
    |       |       |       +-- Phase 5a-g (support apps) -------- parallel
    |
    +-- Phase 6 (Shlink) -------------------------------------- independent
    +-- Phase 7 (Teslamate) ------------------------------------ after Grafana
    +-- Phase 8a (Ollama) -> 8b-d (Qdrant, OpenWebUI, n8n) ---- sequential
    +-- Phase 9a-b (Grimmory, Audiobookshelf) ------------------ independent
```

---

## Verification Plan

For each deployed app:

1. **Pre-commit**: `task validate:preflight`, then `task validate`
2. **Flux sync**: Check Kustomization and HelmRelease status
3. **Pod health**: Verify pods are running
4. **ExternalSecret**: Verify secret sync status
5. **Service**: Port-forward and test connectivity
6. **Route**: Verify HTTPS access via domain
7. **Auth**: Verify the documented auth behavior for the app when applicable
8. **Inter-app**: Test API connections between dependent apps
9. **Migration**: For migrated apps, verify data integrity

---

## Resource Estimate (Total)

| Resource | Estimate |
|----------|----------|
| CPU requests | ~5.5 cores |
| Memory requests | ~14 Gi |
| Longhorn PVCs | ~140 Gi (+ 50-100Gi Ollama models) |
| NFS (media) | Existing share |
| PostgreSQL instances | 5 |
| MariaDB instances | 1 |

Well within a 3-node cluster capacity, though the AI stack (Ollama) will be the heaviest single consumer.

---

## Deployment Status

This section is the **source of truth** for tracking progress across sessions. Update it after each deployment action.

**Last updated:** 2026-03-07
**Current focus:** Auth governance, tracker reconciliation, and deployment policy cleanup

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
| Namespaces (media, ai, tools, monitoring) | `deployed` | `main` | Present in cluster and managed by Flux |
| Shared NFS PV/PVC for media | `not started` | -- | Deferred to Phase 3 |
| Tailscale Operator + Gateway | `deployed` | `main` | Flux Kustomizations and pods are healthy |

### Phase 1: Simple Independent Apps

| App | Status | Branch | Notes |
|-----|--------|--------|-------|
| 1a. KMS | `deployed` | `main` | HelmRelease healthy; app running |
| 1b. Gatus | `deployed` | `main` | HelmRelease healthy; app running |
| 1c. MeTube | `deployed` | `main` | HelmRelease deployed; 2026-03-30 tuned to `MAX_CONCURRENT_DOWNLOADS=3` and `3Gi` memory limit after OOMKills under queued batch processing |
| 1d. Grafana | `deployed` | `main` | HelmRelease healthy; app running |

### Phases 2-9

| Phase | Status | Notes |
|-------|--------|-------|
| Phase 2: Forgejo + Zipline | `deployed` | Both apps are running; auth follow-up remains |
| Phase 3: Media Infrastructure | `deployed` | Plex, SABnzbd, and qBittorrent are running |
| Phase 4: *Arr Stack | `not started` | Migration apps |
| Phase 5: Media Support | `not started` | |
| Phase 6: Shlink | `not started` | |
| Phase 7: Teslamate | `not started` | Migration app |
| Phase 8: AI Stack | `not started` | |
| Phase 9: Books | `not started` | |

### Blockers & Open Questions

| Item | Status | Details |
|------|--------|---------|
| NFS media share path | **Confirmed** | Using 1Password for hostname/IP mapping |
| VPN provider credentials | **Needs manual input** | For qBittorrent/Gluetun |
| Plex claim token | **Generate at deploy time** | Expires in 4 minutes |
| GeoLite license key | **Needs manual input** | For Shlink IP geolocation |
| Notifiarr.com account | **Needs manual setup** | Free account required |
| Tailscale OAuth client | **Needs manual setup** | Create in Tailscale Admin Console |
| Tailscale ACL policy | **Needs manual setup** | Tags + autoApprovers |
| Auth policy alignment | **In progress** | See `docs/architecture/authentication.md` for the new standard |
| Authentik OIDC providers | **In progress** | Deployed apps still need to be reviewed against the new auth policy |
| Authentik forward-auth | **In progress** | External exposure must follow the documented default policy |

### Session Log

| Date | Session | Work Completed |
|------|---------|----------------|
| 2026-02-12 | Initial planning | Created comprehensive deployment plan with all 9 phases, architecture decisions, migration strategy |
| 2026-02-12 | Phase 0 + Phase 1 | Created 4 namespaces. Created Phase 1 apps: KMS, Gatus, Uptime Kuma, Grafana, MeTube. NFS deferred to Phase 3. |
| 2026-02-12 | Tailscale | Added Tailscale Operator + Gateway to plan and created manifests |
| 2026-02-12 | Branch split | Split monolithic branch into per-app branches for independent PRs |
| 2026-02-15 | Security cleanup | Moved sensitive details to `.private/deployment-plan.md`, created redacted public version |
| 2026-03-07 | Reconciliation and auth governance | Reconciled the tracker against the live cluster, documented the auth standard, and removed Uptime Kuma from the planned stack in favor of Gatus. |
| 2026-03-30 | MeTube stability tuning | Confirmed `OOMKilled` restarts during queued download processing and raised MeTube memory limit to `3Gi` while keeping concurrent downloads at `3` to preserve throughput. |
| | | *Next: Continue with Phase 4 and remaining auth cleanup.* |
