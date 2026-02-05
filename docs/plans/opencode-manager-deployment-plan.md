# OpenCode Manager Deployment Plan

## Executive Summary

This document outlines the deployment plan for OpenCode Manager as an alternative approach to remote OpenCode access. Unlike the CLI-based `opencode serve` approach, OpenCode Manager provides a **mobile-first web interface** for managing OpenCode AI agents.

**Key Differences from OpenCode Server Approach:**

| Aspect | OpenCode Server (CLI) | OpenCode Manager (Web UI) |
|--------|----------------------|---------------------------|
| Interface | CLI via `opencode attach` | Web browser / PWA |
| Mobile Access | Terminal apps required | Native mobile-first design |
| Git Integration | Manual (exec/CLI) | Built-in UI with PR support |
| File Browsing | None | Full tree view with syntax highlighting |
| Session Management | API/CLI commands | Visual UI |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              User Devices                                    │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐                     │
│  │  Mobile  │  │  Tablet  │  │  Desktop │  │  Laptop  │                     │
│  │ Browser  │  │ Browser  │  │ Browser  │  │ Browser  │                     │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘                     │
└───────┼─────────────┼─────────────┼─────────────┼───────────────────────────┘
        │             │             │             │
        └─────────────┴──────┬──────┴─────────────┘
                             │ HTTPS (ocm.${DOMAIN})
                             ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster (Serenity)                           │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                     Envoy Internal Gateway                           │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                             │                                                │
│                             ▼                                                │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                   OpenCode Manager Pod                               │    │
│  │  ┌─────────────────────────────────────────────────────────────┐    │    │
│  │  │                    Web Application                           │    │    │
│  │  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │    │    │
│  │  │  │ React UI    │  │ Hono API    │  │ OpenCode Server     │  │    │    │
│  │  │  │ (Frontend)  │  │ (Backend)   │  │ (AI Processing)     │  │    │    │
│  │  │  │ Port 5003   │  │             │  │                     │  │    │    │
│  │  │  └─────────────┘  └─────────────┘  └─────────────────────┘  │    │    │
│  │  └─────────────────────────────────────────────────────────────┘    │    │
│  │                             │                                        │    │
│  │              ┌──────────────┼──────────────┐                        │    │
│  │              ▼              ▼              ▼                        │    │
│  │  ┌────────────────┐ ┌────────────────┐ ┌────────────────┐          │    │
│  │  │ /app/data      │ │ /workspace     │ │ LLM APIs       │          │    │
│  │  │ (SQLite DB)    │ │ (Git repos)    │ │ (External)     │          │    │
│  │  │ Longhorn 5Gi   │ │ Longhorn 50Gi  │ │                │          │    │
│  │  └────────────────┘ └────────────────┘ └────────────────┘          │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Components

### Container Image

- **Repository:** `ghcr.io/chriswritescode-dev/opencode-manager`
- **Tag:** `0.8.22` (or `latest`)
- **Architectures:** linux/amd64, linux/arm64

### Features

1. **Mobile-First PWA**
   - Installable on home screen
   - Responsive design for all devices
   - iOS keyboard/swipe optimization

2. **Git Integration**
   - Clone multiple repositories
   - Git worktrees for branch management
   - Unified diff viewer
   - Direct PR creation

3. **File Management**
   - Tree-view directory browser
   - Syntax highlighting
   - File create/rename/delete
   - Drag-and-drop uploads

4. **AI Chat Interface**
   - Real-time SSE streaming
   - Slash commands (`/help`, `/new`, `/compact`)
   - File referencing via `@filename`
   - Mermaid diagram rendering
   - Text-to-speech / Speech-to-text

5. **Authentication**
   - Single admin account (default)
   - Optional OAuth (GitHub, Google, Discord)
   - Passkey/WebAuthn support

---

## Kubernetes Resources

### Directory Structure

```
kubernetes/apps/default/opencode-manager/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── helmrelease.yaml
    ├── ocirepository.yaml
    └── externalsecret.yaml
```

### Persistence

| Volume | Path | Size | Purpose |
|--------|------|------|---------|
| data | /app/data | 5Gi | SQLite database, settings |
| workspace | /workspace | 50Gi | Git repositories, code |

### Environment Variables

| Variable | Purpose | Source |
|----------|---------|--------|
| `AUTH_SECRET` | Session encryption | ExternalSecret |
| `ADMIN_EMAIL` | Admin account email | ExternalSecret |
| `ADMIN_PASSWORD` | Admin account password | ExternalSecret |
| `ANTHROPIC_API_KEY` | Claude API | ExternalSecret |
| `OPENAI_API_KEY` | OpenAI API | ExternalSecret |
| `GITHUB_PAT` | Private repo access | ExternalSecret |

---

## 1Password Item Structure

Create item named `opencode-manager` in `homeops` vault:

| Field | Type | Description |
|-------|------|-------------|
| `auth_secret` | Password | Generated, 32+ bytes base64 |
| `admin_email` | Text | Admin email address |
| `admin_password` | Password | Admin login password |
| `anthropic_api_key` | Password | Anthropic API key |
| `openai_api_key` | Password | OpenAI API key (optional) |
| `github_pat` | Password | GitHub PAT for private repos |

**Generate auth_secret:**
```bash
openssl rand -base64 32
```

---

## Access

### Internal (Phase 1)

- **URL:** `https://ocm.${SECRET_DOMAIN}`
- **Gateway:** `envoy-internal`
- **Authentication:** Built-in admin account

### External (Future)

When external access is needed:
1. Add `envoy-external` route (will auto-protect with Authentik)
2. Or use `public-access` component with internal auth only

---

## User Workflow

### First Launch

1. Navigate to `https://ocm.${SECRET_DOMAIN}`
2. Create admin account (or use pre-configured credentials)
3. Configure AI model/provider settings
4. Clone first repository

### Daily Use

1. Open web UI from any device
2. Select or create chat session
3. Work with AI assistant via chat interface
4. Review file changes in source control panel
5. Create PRs directly from UI

### Mobile Workflow

1. Install PWA on home screen
2. Quick access from any location on internal network
3. Review code, approve changes
4. Create commits and PRs on the go

---

## Comparison with OpenCode Server

### Pros of OpenCode Manager

- **Better mobile experience** - Native PWA vs terminal apps
- **Visual interface** - File browser, diff viewer, chat UI
- **Git integration** - Built-in PR creation, branch management
- **Lower barrier to entry** - No CLI knowledge required
- **All-in-one solution** - UI + AI processing in single container

### Cons of OpenCode Manager

- **No CLI attach** - Can't use `opencode attach` from terminal
- **Larger footprint** - More resources (web UI overhead)
- **Less flexible** - Tied to web interface
- **Newer project** - Less mature than core OpenCode

---

## Implementation Tasks

1. Create 1Password item `opencode-manager` with required fields
2. Deploy via Flux (manifests already created)
3. Wait for pod to become ready
4. Access web UI and create admin account
5. Configure AI provider settings
6. Clone first repository and test

---

## Document History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 0.1 | 2025-02-05 | Claude | Initial draft |
