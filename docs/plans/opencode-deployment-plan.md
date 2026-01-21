# OpenCode Server Deployment Plan

## Executive Summary

This document outlines a comprehensive plan for deploying OpenCode as a remote server on the Serenity Kubernetes cluster. The goal is to enable a "Claude Code-like" experience where users can connect from any device (mobile, web, desktop) to a centralized server that handles all AI processing, with persistent sessions and workspace storage.

**Key Objectives:**
- Remote OpenCode server accessible via external proxy (no auth blocking API)
- Multi-session support for working on multiple projects simultaneously
- Session persistence allowing connect/disconnect from any device
- Local filesystem storage for project workspaces
- Notification system for user interaction alerts
- Flexible LLM provider support (Anthropic, OpenAI, etc.)

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Component Requirements](#2-component-requirements)
3. [Infrastructure Design](#3-infrastructure-design)
4. [Session & Workspace Management](#4-session--workspace-management)
5. [External Access & Security](#5-external-access--security)
6. [Notification System](#6-notification-system)
7. [User Workflow](#7-user-workflow)
8. [Kubernetes Manifests](#8-kubernetes-manifests)
9. [Implementation Phases](#9-implementation-phases)
10. [Open Questions & Considerations](#10-open-questions--considerations)

---

## 1. Architecture Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              User Devices                                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐                     │
│  │  Mobile  │  │  Laptop  │  │  Desktop │  │   Web    │                     │
│  │   CLI    │  │   CLI    │  │   CLI    │  │ Browser  │                     │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘                     │
└───────┼─────────────┼─────────────┼─────────────┼───────────────────────────┘
        │             │             │             │
        └─────────────┴──────┬──────┴─────────────┘
                             │ HTTPS (opencode.${DOMAIN})
                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Cloudflare Tunnel                                    │
│                    (External Access Gateway)                                 │
└─────────────────────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster (Serenity)                           │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     Envoy External Gateway                           │    │
│  │                   (HTTPRoute → OpenCode Service)                     │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                             │                                                │
│                             ▼                                                │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                      OpenCode Server Pod                             │    │
│  │  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐  │    │
│  │  │  opencode serve │  │   Notification  │  │    Session Data     │  │    │
│  │  │   (HTTP API)    │  │     Plugin      │  │  (~/.local/share/)  │  │    │
│  │  │   Port 8080     │  │                 │  │                     │  │    │
│  │  └────────┬────────┘  └────────┬────────┘  └──────────┬──────────┘  │    │
│  │           │                    │                      │             │    │
│  └───────────┼────────────────────┼──────────────────────┼─────────────┘    │
│              │                    │                      │                   │
│              │                    ▼                      ▼                   │
│              │         ┌──────────────────┐    ┌────────────────────┐        │
│              │         │  Notification    │    │   Longhorn PVC     │        │
│              │         │  Services        │    │  (Session Storage) │        │
│              │         │  (ntfy/Discord)  │    │                    │        │
│              │         └──────────────────┘    └────────────────────┘        │
│              │                                                               │
│              ▼                                                               │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     Workspace Storage (NFS/Longhorn)                 │    │
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

### Core Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Deployment Model | Single StatefulSet | Single user, persistent state required |
| Session Architecture | Native `opencode serve` | Built-in session management, API-first |
| Storage Backend | Longhorn (sessions) + NFS (workspaces) | Distributed reliability + network access |
| External Access | Envoy External + Cloudflare Tunnel | Existing infrastructure, secure |
| Authentication | API token (OPENCODE_SERVER_PASSWORD) | Simple, works with CLI attach |
| Notifications | Plugin-based (ntfy + Discord webhook) | Flexible, multiple channels |

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
    ├── helmrelease.yaml       # App-template deployment
    ├── ocirepository.yaml     # Chart source
    ├── externalsecret.yaml    # 1Password secrets
    ├── configmap.yaml         # OpenCode configuration
    └── httproute.yaml         # External gateway route (if needed)
```

### 3.2 Network Architecture

**External Access Flow:**
```
User CLI → opencode.${SECRET_DOMAIN} → Cloudflare Tunnel
         → Envoy External Gateway → OpenCode Service (8080)
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
opencode attach --host opencode.example.com --port 443

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

## 5. External Access & Security

### 5.1 Cloudflare Tunnel Configuration

Add to existing Cloudflare Tunnel config:

```yaml
# In cloudflare-tunnel configmap
ingress:
  - hostname: opencode.${SECRET_DOMAIN}
    service: http://opencode.default.svc.cluster.local:8080
    originRequest:
      noTLSVerify: true
```

### 5.2 HTTPRoute Configuration

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: opencode
  namespace: default
spec:
  hostnames:
    - opencode.${SECRET_DOMAIN}
  parentRefs:
    - name: envoy-external
      namespace: network
      sectionName: https
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: opencode
          port: 8080
```

### 5.3 Authentication Strategy

**API Token Authentication:**
- Set `OPENCODE_SERVER_PASSWORD` for HTTP Basic Auth
- All API calls require `Authorization: Basic <base64(user:pass)>`
- CLI `attach` command handles auth automatically

**Security Considerations:**
| Concern | Mitigation |
|---------|------------|
| API exposure | Strong password, HTTPS only via Cloudflare |
| Session hijacking | Token-based auth per session |
| Data at rest | Longhorn encryption (if enabled) |
| LLM API keys | Stored in 1Password, injected via ExternalSecret |

**Important:** The requirement states "no authentication in the way" - this means:
- Cloudflare Tunnel handles TLS termination
- No Authentik/SSO in the path (direct API access)
- OpenCode's built-in HTTP Basic Auth is sufficient for API protection

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

# Configure remote server
opencode config set server.host opencode.example.com
opencode config set server.port 443
opencode config set server.tls true
opencode config set server.username opencode
opencode config set server.password <api-password>
```

**Or via environment variables:**
```bash
export OPENCODE_SERVER_HOST=opencode.example.com
export OPENCODE_SERVER_PORT=443
export OPENCODE_SERVER_PASSWORD=<api-password>
```

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
          - opencode.${SECRET_DOMAIN}
        parentRefs:
          - name: envoy-external
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

### 8.7 Cloudflare Tunnel Update

Add to existing tunnel configuration in `kubernetes/apps/network/cloudflare-tunnel/`:

```yaml
# Add to tunnel ingress rules
- hostname: opencode.${SECRET_DOMAIN}
  service: http://opencode.default.svc.cluster.local:8080
```

---

## 9. Implementation Phases

### Phase 1: Core Deployment (Week 1)

**Objectives:**
- [ ] Deploy basic OpenCode server
- [ ] Establish external connectivity
- [ ] Verify session persistence

**Tasks:**
1. Create 1Password item `opencode` with required secrets:
   - `server_password` - Strong random password (30+ chars)
   - `server_username` - `opencode`
   - `anthropic_api_key` - API key from Anthropic
   - `openai_api_key` - API key from OpenAI (optional)
   - `ntfy_topic` - (placeholder for Phase 2)
   - `discord_webhook_url` - (placeholder for Phase 2)

2. Create Kubernetes manifests:
   - `kubernetes/apps/default/opencode/ks.yaml`
   - `kubernetes/apps/default/opencode/app/kustomization.yaml`
   - `kubernetes/apps/default/opencode/app/ocirepository.yaml`
   - `kubernetes/apps/default/opencode/app/helmrelease.yaml`
   - `kubernetes/apps/default/opencode/app/externalsecret.yaml`
   - `kubernetes/apps/default/opencode/app/configmap.yaml`

3. Register app in namespace kustomization:
   - Add to `kubernetes/apps/default/kustomization.yaml`

4. Update Cloudflare Tunnel configuration:
   - Add opencode hostname to tunnel ingress

5. Test connectivity:
   ```bash
   # Verify pod is running
   kubectl get pods -n default -l app.kubernetes.io/name=opencode

   # Test API endpoint
   curl -u opencode:$PASSWORD https://opencode.example.com/

   # Test CLI attach
   opencode attach --host opencode.example.com --port 443
   ```

### Phase 2: Notifications (Week 2)

**Objectives:**
- [ ] Set up ntfy for push notifications
- [ ] Configure Discord webhook alerts
- [ ] Test notification delivery

**Tasks:**
1. **Option A - Deploy ntfy to cluster:**
   - Create `kubernetes/apps/default/ntfy/` deployment
   - Configure external access

2. **Option B - Use ntfy.sh:**
   - Generate unique topic URL
   - Store in 1Password

3. Create Discord webhook:
   - Create webhook in Discord server
   - Store URL in 1Password

4. Configure notification sidecar or plugin:
   - Update HelmRelease with notification container
   - Test event-to-notification flow

5. Test notifications:
   - Trigger permission event
   - Verify mobile push received
   - Verify Discord message posted

### Phase 3: Workspace Management (Week 3)

**Objectives:**
- [ ] Set up multiple project workspaces
- [ ] Document workspace initialization
- [ ] Test multi-session workflows

**Tasks:**
1. Create workspace initialization script:
   ```bash
   #!/bin/bash
   # init-workspace.sh
   cd /workspaces
   git clone $REPO_URL $PROJECT_NAME
   cd $PROJECT_NAME
   # Any project-specific setup
   ```

2. Document workspace management:
   - How to add new projects
   - How to manage workspace storage
   - Backup procedures

3. Test multi-session:
   - Create sessions for different projects
   - Verify session isolation
   - Test device switching

### Phase 4: Production Hardening (Week 4)

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

---

## 10. Open Questions & Considerations

### 10.1 Questions Requiring Decision

| # | Question | Options | Recommendation |
|---|----------|---------|----------------|
| 1 | Should we deploy ntfy self-hosted or use ntfy.sh? | Self-hosted / SaaS | SaaS initially (simpler), self-host if privacy needed |
| 2 | Should workspaces use Longhorn or NFS? | Longhorn / NFS | Longhorn for reliability, NFS if need larger capacity |
| 3 | Pin OpenCode version or use latest? | Pinned / Latest | Pin after initial testing for stability |
| 4 | Single namespace (default) or dedicated? | default / opencode | default follows existing patterns |
| 5 | Need Git credential management in workspaces? | Yes / No | Yes - need to plan SSH key or credential storage |

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
export OPENCODE_SERVER_HOST=opencode.example.com
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
    "host": "opencode.example.com",
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

---

**Next Steps:**
1. Review this plan and provide feedback
2. Confirm answers to open questions
3. Begin Phase 1 implementation
