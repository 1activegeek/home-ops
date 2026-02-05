# OpenCode Server Deployment Plan

## Executive Summary

This document outlines a comprehensive plan for deploying OpenCode as a remote server on the Serenity Kubernetes cluster. The goal is to enable a "Claude Code-like" experience where users can connect from any device (mobile, web, desktop) to a centralized server that handles all AI processing, with persistent sessions and workspace storage.

**Key Objectives:**
- Remote OpenCode server accessible via internal network (Phase 1)
- External access with proper security controls (Phase 3 - future)
- Multi-session support for working on multiple projects simultaneously
- Session persistence allowing connect/disconnect from any device
- Local filesystem storage for project workspaces
- Notification system for user interaction alerts (Phase 2 - future)
- Flexible LLM provider support (Anthropic, OpenAI, etc.)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Component Requirements](#2-component-requirements)
3. [Infrastructure Design](#3-infrastructure-design)
4. [Session & Workspace Management](#4-session--workspace-management)
5. [Access & Security](#5-access--security)
6. [Notification System](#6-notification-system) *(Phase 2)*
7. [User Workflow](#7-user-workflow)
8. [Kubernetes Manifests](#8-kubernetes-manifests)
9. [Implementation Phases](#9-implementation-phases)
10. [Open Questions & Considerations](#10-open-questions--considerations)

---

## 1. Architecture Overview

### High-Level Architecture

**Phase 1: Internal Access Only**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Local Network Devices                                │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                                   │
│  │  Laptop  │  │  Desktop │  │  Other   │                                   │
│  │   CLI    │  │   CLI    │  │ Internal │                                   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                                   │
└───────┼─────────────┼─────────────┼─────────────────────────────────────────┘
        │             │             │
        └─────────────┴──────┬──────┘
                             │ HTTPS (oc.${DOMAIN}) - Internal DNS
                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster (Serenity)                           │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     Envoy Internal Gateway                           │    │
│  │                   (HTTPRoute → OpenCode Service)                     │    │
│  │                   No authentication layer                            │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                             │                                                │
│                             ▼                                                │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                      OpenCode Server Pod                             │    │
│  │  ┌─────────────────┐                       ┌─────────────────────┐  │    │
│  │  │  opencode serve │                       │    Session Data     │  │    │
│  │  │   (HTTP API)    │                       │  (~/.local/share/)  │  │    │
│  │  │   Port 8080     │                       │                     │  │    │
│  │  └────────┬────────┘                       └──────────┬──────────┘  │    │
│  │           │                                           │             │    │
│  └───────────┼───────────────────────────────────────────┼─────────────┘    │
│              │                                           ▼                   │
│              │                                 ┌────────────────────┐        │
│              │                                 │   Longhorn PVC     │        │
│              │                                 │  (Session Storage) │        │
│              │                                 └────────────────────┘        │
│              ▼                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     Workspace Storage (Longhorn)                     │    │
│  │   /workspaces/project-1/  /workspaces/project-2/  ...               │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                             │                                                │
│                             ▼                                                │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                        LLM Providers (External)                      │    │
│  │         Anthropic API    │    OpenAI API    │    Others              │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

**Phase 3 (Future): External Access with Authentik**
```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Remote Devices                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                                   │
│  │  Mobile  │  │  Remote  │  │   Web    │                                   │
│  │   CLI    │  │  Laptop  │  │ Browser  │                                   │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘                                   │
└───────┼─────────────┼─────────────┼─────────────────────────────────────────┘
        │             │             │
        └─────────────┴──────┬──────┘
                             │ HTTPS (oc.${DOMAIN})
                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Cloudflare Tunnel                                    │
└─────────────────────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Envoy External Gateway → Authentik Forward-Auth → OpenCode Service         │
│  (Default-deny: all external routes protected by Authentik SSO)             │
│                                                                              │
│  Options for API access:                                                     │
│  1. Authentik Application Token (header-based auth)                          │
│  2. Public-access component (bypass SSO, use OpenCode's HTTP Basic Auth)    │
└─────────────────────────────────────────────────────────────────────────────┘
```

### Core Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Deployment Model | Single StatefulSet | Single user, persistent state required |
| Session Architecture | Native `opencode serve` | Built-in session management, API-first |
| Storage Backend | Longhorn (sessions + workspaces) | Distributed reliability, single storage class |
| Phase 1 Access | Envoy Internal Gateway | Internal network only, no auth overhead |
| Phase 3 Access (Future) | Envoy External + Authentik | External access with SSO protection |
| Authentication | API token (OPENCODE_SERVER_PASSWORD) | Simple, works with CLI attach |
| Notifications | Phase 2 (deferred) | Plugin-based (ntfy + Discord webhook) |

---

## 2. Component Requirements

### 2.1 OpenCode Server

**Image:** `ghcr.io/sst/opencode:latest` (or pinned version)

**Server Mode:**
```bash
opencode serve --hostname 0.0.0.0 --port 8080
```

**Required Environment Variables:**
| Variable | Purpose | Source |
|----------|---------|--------|
| `OPENCODE_SERVER_PASSWORD` | API authentication | 1Password ExternalSecret |
| `OPENCODE_SERVER_USERNAME` | API username (optional) | 1Password ExternalSecret |
| `ANTHROPIC_API_KEY` | Claude API access | 1Password ExternalSecret |
| `OPENAI_API_KEY` | OpenAI API access | 1Password ExternalSecret |
| `XDG_DATA_HOME` | Data directory override | ConfigMap (set to /data) |
| `HOME` | Home directory | ConfigMap (set to /home/opencode) |

**Storage Requirements:**
| Mount Path | Purpose | Type | Size |
|------------|---------|------|------|
| `/data` | Session data, SQLite DB | Longhorn PVC | 5Gi |
| `/workspaces` | Project working directories | NFS or Longhorn | 50Gi |
| `/home/opencode/.config/opencode` | Config files | ConfigMap | N/A |

### 2.2 Notification Plugin

**Recommended:** `opencode-notifier` or `opencode-notify`

**Events to Monitor:**
- `permission` - When tool execution needs approval
- `question` - When AI asks for user input
- `complete` - When a task finishes
- `error` - When something fails

**Notification Targets:**
1. **ntfy** (Push notifications) - Self-hosted or ntfy.sh
2. **Discord Webhook** - For chat-based alerts

### 2.3 LLM Provider Configuration

OpenCode supports multiple providers through environment variables:

```yaml
# Provider priority and configuration
ANTHROPIC_API_KEY: "sk-ant-..."     # Primary
OPENAI_API_KEY: "sk-..."            # Secondary/Alternative
# Additional providers as needed
```

---

## 3. Infrastructure Design

### 3.1 Kubernetes Resources

```
kubernetes/apps/default/opencode/
├── ks.yaml                    # Flux Kustomization
└── app/
    ├── kustomization.yaml     # Resource list
    ├── helmrelease.yaml       # App-template deployment (name: opencode)
    ├── ocirepository.yaml     # Chart source
    ├── externalsecret.yaml    # 1Password secrets
    └── configmap.yaml         # OpenCode configuration
```

**Note:** The app directory is named `opencode` but the hostname will be `oc.${SECRET_DOMAIN}` for brevity.

### 3.2 Network Architecture

**Phase 1: Internal Access Flow**
```
User CLI (local network) → oc.${SECRET_DOMAIN} → Internal DNS (k8s-gateway)
                        → Envoy Internal Gateway (10.0.3.53)
                        → OpenCode Service (8080)
```

**Phase 3 (Future): External Access Flow**
```
User CLI (remote) → oc.${SECRET_DOMAIN} → Cloudflare Tunnel
                 → Envoy External Gateway → Authentik Forward-Auth
                 → OpenCode Service (8080)
```

**Endpoints Exposed:**
| Path | Purpose |
|------|---------|
| `/` | API root, health check |
| `/session/*` | Session management |
| `/event` | SSE event stream |
| `/pty` | Terminal sessions (WebSocket) |
| `/global/event` | Global event stream |

### 3.3 Storage Architecture

**Option A: Dual Storage (Recommended)**
```yaml
persistence:
  # Session data - needs fast access, reliability
  data:
    type: persistentVolumeClaim
    storageClass: longhorn
    accessMode: ReadWriteOnce
    size: 5Gi
    globalMounts:
      - path: /data

  # Workspaces - needs more space, network accessible
  workspaces:
    type: persistentVolumeClaim
    storageClass: longhorn  # or nfs-slow for larger capacity
    accessMode: ReadWriteOnce
    size: 50Gi
    globalMounts:
      - path: /workspaces
```

**Option B: Single Large Volume**
```yaml
persistence:
  data:
    type: persistentVolumeClaim
    storageClass: longhorn
    accessMode: ReadWriteOnce
    size: 60Gi
    globalMounts:
      - path: /data
      - path: /workspaces
        subPath: workspaces
```

---

## 4. Session & Workspace Management

### 4.1 Session Lifecycle

OpenCode sessions are stored in SQLite at `~/.local/share/opencode/storage/`.

**Session States:**
- `idle` - Waiting for input
- `busy` - Processing request
- `error` - Encountered an issue

**Session Operations via API:**
```bash
# List sessions
GET /session

# Get session status
GET /session/:id/status

# Create new session
POST /session

# Resume session (attach from CLI)
opencode attach --host oc.example.com --port 443

# Export session
GET /session/:id/export

# Import session
POST /session/import
```

### 4.2 Workspace Organization

**Recommended Structure:**
```
/workspaces/
├── project-1/           # Git repo clone
│   ├── .git/
│   ├── src/
│   └── ...
├── project-2/           # Another project
├── project-3/
└── scratch/             # Temporary work area
```

**Workspace Initialization:**
Each project workspace should be pre-initialized or cloned via:
```bash
# Inside the pod or via exec
cd /workspaces
git clone https://github.com/user/repo project-name
```

### 4.3 Multi-Session Workflow

Since OpenCode supports multiple concurrent sessions pointing to different directories:

1. **Session A** → `/workspaces/project-1` (working on feature X)
2. **Session B** → `/workspaces/project-2` (debugging issue Y)
3. **Session C** → `/workspaces/project-3` (code review)
4. **Session D** → `/workspaces/scratch` (experiments)

The `directory` query parameter in API calls specifies which workspace context to use.

---

## 5. Access & Security

### 5.1 Phase 1: Internal Access (Initial Deployment)

**No external access** - the service is only reachable from the local network via the internal gateway.

**Security Model:**
- Network isolation provides primary security (internal network only)
- OpenCode's built-in HTTP Basic Auth provides API protection
- No Authentik/SSO in the path for internal access

**Internal HTTPRoute Configuration:**
```yaml
# Embedded in HelmRelease via app-template route
route:
  app:
    hostnames:
      - oc.${SECRET_DOMAIN}
    parentRefs:
      - name: envoy-internal    # Internal gateway - no Authentik
        namespace: network
        sectionName: https
    rules:
      - backendRefs:
          - name: opencode
            port: 8080
```

### 5.2 Phase 3 (Future): External Access with Authentik

When external access is needed, there are two options:

**Option A: Authentik SSO (Recommended)**
- Use `envoy-external` gateway (default-deny with Authentik)
- All requests go through Authentik forward-auth
- User authenticates via SSO, then accesses OpenCode
- Pros: Consistent with other external apps, SSO convenience
- Cons: CLI needs to handle Authentik auth flow

**Option B: Public Access with API Token**
- Use `public-access` component to bypass Authentik
- Rely solely on OpenCode's `OPENCODE_SERVER_PASSWORD`
- Pros: Simple CLI auth (HTTP Basic)
- Cons: Single point of security (password only)

**External Access Configuration (Phase 3):**
```yaml
# Option A: With Authentik (default for envoy-external)
route:
  app:
    hostnames:
      - oc.${SECRET_DOMAIN}
    parentRefs:
      - name: envoy-external
        namespace: network
        sectionName: https

# Option B: Public access (bypass Authentik)
# Requires adding public-access component to kustomization.yaml
# See kubernetes/components/public-access/ for pattern
```

**Cloudflare Tunnel (Phase 3 only):**
```yaml
# Add to cloudflare-tunnel configmap when ready for external access
ingress:
  - hostname: oc.${SECRET_DOMAIN}
    service: http://opencode.default.svc.cluster.local:8080
    originRequest:
      noTLSVerify: true
```

### 5.3 Authentication Strategy

**Phase 1 (Internal):**
- Set `OPENCODE_SERVER_PASSWORD` for HTTP Basic Auth
- All API calls require `Authorization: Basic <base64(user:pass)>`
- CLI `attach` command handles auth automatically
- Network isolation is the primary security layer

**Security Considerations:**
| Concern | Mitigation |
|---------|------------|
| API exposure | Internal network only (Phase 1), Authentik SSO (Phase 3) |
| Session hijacking | Token-based auth per session |
| Data at rest | Longhorn encryption (if enabled) |
| LLM API keys | Stored in 1Password, injected via ExternalSecret |

---

## 6. Notification System

### 6.1 Plugin Architecture

OpenCode plugins are installed via npm in the OpenCode config directory:

```bash
# Install notification plugin
cd ~/.config/opencode
npm install opencode-notifier
# or
npm install opencode-notify
```

**Plugin Configuration (`~/.config/opencode/config.json`):**
```json
{
  "plugins": ["opencode-notifier"],
  "opencode-notifier": {
    "events": {
      "permission": true,
      "question": true,
      "complete": true,
      "error": true
    },
    "sound": false,
    "desktop": false
  }
}
```

### 6.2 ntfy Integration (Push Notifications)

**Option A: Self-hosted ntfy**
Deploy ntfy to the cluster:
```yaml
# Separate deployment in kubernetes/apps/default/ntfy/
```

**Option B: ntfy.sh (SaaS)**
Use the public ntfy.sh service with a private topic.

**Notification Flow:**
```
OpenCode Event → Plugin → HTTP POST → ntfy → Mobile Push
```

**ntfy Configuration:**
```bash
# Topic URL
NTFY_TOPIC=https://ntfy.sh/opencode-alerts-${RANDOM_SUFFIX}

# Send notification
curl -d "OpenCode needs input: Session xyz" $NTFY_TOPIC
```

### 6.3 Discord Webhook Integration

**Webhook Setup:**
1. Create Discord webhook in target channel
2. Store webhook URL in 1Password
3. Configure plugin to POST to webhook

**Discord Message Format:**
```json
{
  "content": "🤖 **OpenCode Alert**",
  "embeds": [{
    "title": "Interaction Required",
    "description": "Session `project-1` needs your input",
    "color": 15844367,
    "fields": [
      {"name": "Event", "value": "permission", "inline": true},
      {"name": "Session", "value": "abc123", "inline": true}
    ]
  }]
}
```

### 6.4 Custom Notification Sidecar (Alternative)

If plugins don't meet needs, deploy a sidecar container:

```yaml
containers:
  notification-bridge:
    image: curlimages/curl:latest
    command:
      - /bin/sh
      - -c
      - |
        # Subscribe to OpenCode SSE events and forward to notification services
        while true; do
          curl -N "http://localhost:8080/global/event" | while read line; do
            # Parse and forward to ntfy/Discord
            echo "$line" | jq -r '.type' | xargs -I {} curl -d "Event: {}" $NTFY_URL
          done
          sleep 5
        done
```

---

## 7. User Workflow

### 7.1 Initial Setup (One-time)

**Client Machine Configuration:**

```bash
# Install OpenCode CLI
npm install -g @opencode-ai/cli

# Configure remote server (Phase 1: internal access)
opencode config set server.host oc.example.com
opencode config set server.port 443
opencode config set server.tls true
opencode config set server.username opencode
opencode config set server.password <api-password>
```

**Or via environment variables:**
```bash
export OPENCODE_SERVER_HOST=oc.example.com
export OPENCODE_SERVER_PORT=443
export OPENCODE_SERVER_PASSWORD=<api-password>
```

**Note:** Phase 1 requires client to be on the internal network. Phase 3 will enable external access.

### 7.2 Daily Workflow

```
┌─────────────────────────────────────────────────────────────────┐
│                      User Daily Workflow                         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  Launch CLI     │
                    │  opencode       │
                    └────────┬────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │ Connect to      │
                    │ Remote Server   │
                    └────────┬────────┘
                              │
                              ▼
              ┌───────────────┴───────────────┐
              │                               │
              ▼                               ▼
    ┌─────────────────┐             ┌─────────────────┐
    │ List Sessions   │             │ Create New      │
    │ opencode list   │             │ Session         │
    └────────┬────────┘             └────────┬────────┘
              │                               │
              ▼                               │
    ┌─────────────────┐                       │
    │ Resume Session  │                       │
    │ opencode attach │◄──────────────────────┘
    │ --session <id>  │
    └────────┬────────┘
              │
              ▼
    ┌─────────────────┐
    │ Work on Tasks   │
    │ (AI Processing  │
    │  on Server)     │
    └────────┬────────┘
              │
              ▼
    ┌─────────────────┐
    │ Disconnect      │
    │ (Ctrl+D or      │
    │  close terminal)│
    └────────┬────────┘
              │
              ▼
    ┌─────────────────┐
    │ Session Persists│
    │ on Server       │
    │ (Resume Later)  │
    └─────────────────┘
```

### 7.3 Multi-Device Scenario

```
Morning (Laptop):
  1. opencode attach --session project-1
  2. Start feature implementation
  3. Disconnect (commute)

Commute (Mobile):
  4. Receive ntfy notification: "Implementation complete"
  5. opencode attach --session project-1 (view results)
  6. Quick review, approve changes
  7. Disconnect

Evening (Desktop):
  8. opencode attach --session project-1
  9. Continue refinements
  10. Commit and push
```

### 7.4 Session Discovery Commands

```bash
# List all sessions with status
opencode session list

# Output:
# ID          | Directory           | Status | Last Active
# ------------|---------------------|--------|------------
# abc123      | /workspaces/proj-1  | idle   | 2 hours ago
# def456      | /workspaces/proj-2  | busy   | 5 min ago
# ghi789      | /workspaces/proj-3  | idle   | 1 day ago

# Get detailed session info
opencode session info abc123

# Attach to specific session
opencode attach --session abc123
```

---

## 8. Kubernetes Manifests

### 8.1 Flux Kustomization (ks.yaml)

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: opencode
spec:
  interval: 1h
  path: ./kubernetes/apps/default/opencode/app
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: default
  wait: false
```

### 8.2 OCI Repository (ocirepository.yaml)

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: opencode
spec:
  interval: 1h
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
  ref:
    tag: "4.6.0"
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
```

### 8.3 HelmRelease (helmrelease.yaml)

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: opencode
spec:
  chartRef:
    kind: OCIRepository
    name: opencode
  interval: 1h
  values:
    controllers:
      opencode:
        type: StatefulSet
        replicas: 1

        containers:
          app:
            image:
              repository: ghcr.io/sst/opencode
              tag: latest  # Pin to specific version in production

            command:
              - opencode
              - serve
              - --hostname
              - "0.0.0.0"
              - --port
              - "8080"

            env:
              TZ: America/New_York
              XDG_DATA_HOME: /data
              HOME: /home/opencode

            envFrom:
              - secretRef:
                  name: opencode-secret

            probes:
              liveness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /
                    port: 8080
                  initialDelaySeconds: 10
                  periodSeconds: 30
                  timeoutSeconds: 5
                  failureThreshold: 3
              readiness:
                enabled: true
                custom: true
                spec:
                  httpGet:
                    path: /
                    port: 8080
                  initialDelaySeconds: 5
                  periodSeconds: 10

            resources:
              requests:
                cpu: 100m
                memory: 256Mi
              limits:
                memory: 1Gi

            securityContext:
              allowPrivilegeEscalation: false
              capabilities: { drop: ["ALL"] }

    defaultPodOptions:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000

    podAnnotations:
      reloader.stakater.com/auto: "true"

    service:
      app:
        controller: opencode
        ports:
          http:
            port: 8080

    persistence:
      data:
        type: persistentVolumeClaim
        storageClass: longhorn
        accessMode: ReadWriteOnce
        size: 5Gi
        globalMounts:
          - path: /data

      workspaces:
        type: persistentVolumeClaim
        storageClass: longhorn
        accessMode: ReadWriteOnce
        size: 50Gi
        globalMounts:
          - path: /workspaces

      config:
        type: configMap
        name: opencode-config
        globalMounts:
          - path: /home/opencode/.config/opencode/config.json
            subPath: config.json

      # Temp directory for read-only root filesystem
      tmp:
        type: emptyDir
        globalMounts:
          - path: /tmp

    route:
      app:
        hostnames:
          - oc.${SECRET_DOMAIN}
        parentRefs:
          - name: envoy-internal    # Phase 1: Internal access only
            namespace: network
            sectionName: https
        rules:
          - backendRefs:
              - name: opencode
                port: 8080
```

### 8.4 ExternalSecret (externalsecret.yaml)

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: opencode
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-store
  target:
    name: opencode-secret
    template:
      data:
        OPENCODE_SERVER_PASSWORD: "{{ .server_password }}"
        OPENCODE_SERVER_USERNAME: "{{ .server_username }}"
        ANTHROPIC_API_KEY: "{{ .anthropic_api_key }}"
        OPENAI_API_KEY: "{{ .openai_api_key }}"
        NTFY_TOPIC: "{{ .ntfy_topic }}"
        DISCORD_WEBHOOK_URL: "{{ .discord_webhook_url }}"
  dataFrom:
    - extract:
        key: opencode
```

### 8.5 ConfigMap (configmap.yaml)

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: opencode-config
data:
  config.json: |
    {
      "providers": {
        "anthropic": {
          "enabled": true
        },
        "openai": {
          "enabled": true
        }
      },
      "defaultProvider": "anthropic",
      "defaultModel": "claude-sonnet-4-20250514",
      "plugins": [],
      "server": {
        "host": "0.0.0.0",
        "port": 8080
      }
    }
```

### 8.6 Kustomization (app/kustomization.yaml)

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  - ./externalsecret.yaml
  - ./configmap.yaml
```

### 8.7 Cloudflare Tunnel Update (Phase 3 Only)

**Note:** This is NOT needed for Phase 1 (internal access only).

When implementing Phase 3 (external access), add to existing tunnel configuration in `kubernetes/apps/network/cloudflare-tunnel/`:

```yaml
# Add to tunnel ingress rules (Phase 3)
- hostname: oc.${SECRET_DOMAIN}
  service: http://opencode.default.svc.cluster.local:8080
```

---

## 9. Implementation Phases

### Phase 1: Core Deployment (Internal Access)

**Objectives:**
- [ ] Deploy basic OpenCode server
- [ ] Establish internal connectivity via `oc.${SECRET_DOMAIN}`
- [ ] Verify session persistence
- [ ] Test multi-session workflows

**Tasks:**
1. Create 1Password item `opencode` with required secrets:
   - `server_password` - Strong random password (30+ chars)
   - `server_username` - `opencode`
   - `anthropic_api_key` - API key from Anthropic
   - `openai_api_key` - API key from OpenAI (optional)

2. Create Kubernetes manifests:
   - `kubernetes/apps/default/opencode/ks.yaml`
   - `kubernetes/apps/default/opencode/app/kustomization.yaml`
   - `kubernetes/apps/default/opencode/app/ocirepository.yaml`
   - `kubernetes/apps/default/opencode/app/helmrelease.yaml`
   - `kubernetes/apps/default/opencode/app/externalsecret.yaml`
   - `kubernetes/apps/default/opencode/app/configmap.yaml`

3. Register app in namespace kustomization:
   - Add to `kubernetes/apps/default/kustomization.yaml`

4. Test connectivity (internal network):
   ```bash
   # Verify pod is running
   kubectl get pods -n default -l app.kubernetes.io/name=opencode

   # Test API endpoint (from internal network)
   curl -u opencode:$PASSWORD https://oc.example.com/

   # Test CLI attach
   opencode attach --host oc.example.com --port 443
   ```

5. Test workspace and session management:
   - Create multiple sessions pointing to different workspaces
   - Verify session persistence across pod restarts
   - Test attach/detach workflow

### Phase 2: Notifications (Future)

**Objectives:**
- [ ] Set up ntfy for push notifications
- [ ] Configure Discord webhook alerts
- [ ] Test notification delivery

**Prerequisites:** Phase 1 complete and stable

**Tasks:**
1. **Option A - Deploy ntfy to cluster:**
   - Create `kubernetes/apps/default/ntfy/` deployment
   - Configure internal access initially

2. **Option B - Use ntfy.sh:**
   - Generate unique topic URL
   - Store in 1Password

3. Create Discord webhook:
   - Create webhook in Discord server
   - Store URL in 1Password

4. Update 1Password `opencode` item with notification secrets:
   - `ntfy_topic` - ntfy topic URL
   - `discord_webhook_url` - Discord webhook URL

5. Configure notification plugin or sidecar:
   - Update HelmRelease with notification configuration
   - Test event-to-notification flow

6. Test notifications:
   - Trigger permission event
   - Verify mobile push received
   - Verify Discord message posted

### Phase 3: External Access (Future)

**Objectives:**
- [ ] Enable external access via Cloudflare Tunnel
- [ ] Configure authentication (Authentik SSO or public-access)
- [ ] Test remote CLI connectivity

**Prerequisites:** Phase 1 complete and stable

**Decision Required:** Authentication strategy
- **Option A:** Authentik SSO (recommended for browser/web access)
- **Option B:** Public-access with API token only (simpler for CLI)

**Tasks:**
1. Choose authentication strategy and document decision

2. Update Cloudflare Tunnel configuration:
   ```yaml
   # Add to cloudflare-tunnel configmap
   ingress:
     - hostname: oc.${SECRET_DOMAIN}
       service: http://opencode.default.svc.cluster.local:8080
   ```

3. Create external HTTPRoute:
   - If using Authentik: Simply change `parentRefs` to `envoy-external`
   - If using public-access: Add `public-access` component

4. Test external connectivity:
   ```bash
   # From external network
   curl -u opencode:$PASSWORD https://oc.example.com/

   # Test CLI attach from external
   opencode attach --host oc.example.com --port 443
   ```

5. Document external access procedures and security considerations

### Phase 4: Production Hardening

**Objectives:**
- [ ] Pin container versions
- [ ] Set up backups
- [ ] Document operations

**Tasks:**
1. Pin OpenCode image to specific version tag
2. Configure Longhorn backup schedule for PVCs
3. Create operational runbook:
   - Troubleshooting guide
   - Backup/restore procedures
   - Upgrade procedures
4. Set up workspace initialization scripts
5. Document multi-session best practices

---

## 10. Open Questions & Considerations

### 10.1 Questions Requiring Decision

**Phase 1 (Core Deployment):**

| # | Question | Options | Recommendation |
|---|----------|---------|----------------|
| 1 | Should workspaces use Longhorn or NFS? | Longhorn / NFS | Longhorn for reliability, NFS if need larger capacity |
| 2 | Pin OpenCode version or use latest? | Pinned / Latest | Latest initially for testing, pin once stable |
| 3 | Single namespace (default) or dedicated? | default / opencode | default follows existing patterns |
| 4 | Need Git credential management in workspaces? | Yes / No | Yes - need to plan SSH key or credential storage |

**Phase 2 (Notifications - Deferred):**

| # | Question | Options | Recommendation |
|---|----------|---------|----------------|
| 5 | Should we deploy ntfy self-hosted or use ntfy.sh? | Self-hosted / SaaS | SaaS initially (simpler), self-host if privacy needed |

**Phase 3 (External Access - Deferred):**

| # | Question | Options | Recommendation |
|---|----------|---------|----------------|
| 6 | Authentication strategy for external access? | Authentik SSO / Public-access with API token | Authentik SSO recommended for security, API token simpler for CLI |
| 7 | Can OpenCode CLI handle Authentik OAuth flow? | Research needed | May need to test or use public-access bypass |

### 10.2 Security Considerations

- **API Key Exposure:** LLM API keys are stored server-side only; clients never see them
- **Session Data:** Contains conversation history, potentially sensitive code
- **Workspace Access:** All projects accessible to anyone with server password
- **Network:** All traffic encrypted via Cloudflare Tunnel TLS

**Mitigations:**
- Strong server password (30+ characters)
- Regular rotation of credentials
- Longhorn encryption at rest (if configured)
- Backup encryption

### 10.3 Limitations & Known Issues

1. **Single User Design:** Current architecture optimized for single user
   - Multi-user would require session isolation, separate workspaces
   - Consider namespace-per-user if scaling needed later

2. **Mobile CLI Experience:** Limited compared to desktop
   - Consider web UI option for mobile (OpenCode web mode)
   - Terminal apps like Termux work but with UX limitations

3. **Session State Recovery:** If pod restarts mid-session
   - Session data in SQLite should persist (PVC-backed)
   - Active operations may need to be re-initiated

4. **Resource Limits:** AI processing can be CPU/memory intensive
   - Monitor resource usage and adjust limits
   - Consider node affinity if dedicated hardware needed

### 10.4 Future Enhancements

1. **Web Interface:** Deploy `opencode web` mode for browser access
2. **Backup Automation:** Scheduled workspace backups to external storage
3. **Metrics:** Prometheus metrics for session activity, costs
4. **Multi-User:** Session isolation for multiple users
5. **MCP Servers:** Add Model Context Protocol servers for enhanced capabilities

---

## Appendix A: 1Password Item Structure

Create item named `opencode` in `homeops` vault:

| Field | Type | Description |
|-------|------|-------------|
| `server_password` | Password | Generated, 30+ chars with symbols |
| `server_username` | Text | `opencode` |
| `anthropic_api_key` | Password | From Anthropic Console |
| `openai_api_key` | Password | From OpenAI Platform |
| `ntfy_topic` | Text | ntfy topic URL |
| `discord_webhook_url` | Password | Discord webhook URL |

---

## Appendix B: Client Configuration Reference

### Environment Variables

```bash
# Required
export OPENCODE_SERVER_HOST=oc.example.com
export OPENCODE_SERVER_PORT=443
export OPENCODE_SERVER_PASSWORD=<password>

# Optional
export OPENCODE_SERVER_USERNAME=opencode
export OPENCODE_SERVER_TLS=true
```

### Config File (~/.config/opencode/config.json)

```json
{
  "server": {
    "host": "oc.example.com",
    "port": 443,
    "tls": true,
    "username": "opencode",
    "password": "<password>"
  }
}
```

### CLI Commands

```bash
# Attach to server (interactive session picker)
opencode attach

# Attach to specific session
opencode attach --session <session-id>

# List sessions
opencode session list

# Create new session in specific directory
opencode session new --directory /workspaces/project-1

# Export session for backup
opencode session export <session-id> > session-backup.json

# Import session
opencode session import < session-backup.json
```

---

## Appendix C: Troubleshooting

### Common Issues

**Issue: Cannot connect to server**
```bash
# Check pod status
kubectl get pods -n default -l app.kubernetes.io/name=opencode

# Check logs
kubectl logs -n default -l app.kubernetes.io/name=opencode -f

# Test internal connectivity
kubectl exec -it -n default deploy/opencode -- curl localhost:8080/
```

**Issue: Sessions not persisting**
```bash
# Verify PVC is mounted
kubectl exec -it -n default deploy/opencode -- ls -la /data

# Check SQLite database
kubectl exec -it -n default deploy/opencode -- ls -la /data/opencode/storage/
```

**Issue: Notifications not working**
```bash
# Test ntfy manually
curl -d "Test notification" https://ntfy.sh/<topic>

# Check webhook
curl -X POST -H "Content-Type: application/json" \
  -d '{"content":"Test"}' $DISCORD_WEBHOOK_URL
```

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 0.1 | 2025-01-21 | Claude | Initial draft |
| 0.2 | 2025-02-05 | Claude | Updated per user feedback: internal-only Phase 1, subdomain changed to `oc`, notifications deferred to Phase 2, external access moved to Phase 3 with Authentik considerations |

---

**Next Steps:**
1. Review this plan and provide feedback
2. Confirm answers to open questions
3. Begin Phase 1 implementation
