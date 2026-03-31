# PAI (Personal AI Infrastructure) Deployment Design

## Context

Deploy a Personal AI Infrastructure service based on Daniel Miessler's PAI project into the existing Talos Linux / Flux CD Kubernetes cluster. PAI is a Claude Code customization layer that provides persistent memory, goal tracking (TELOS), skill routing, and continuous learning. It has no official container image — it runs as a Claude Code enhancement inside `~/.claude/`.

The goal is a **full-capability AI workstation pod** — not just a Claude Code runner. PAI should operate as if it were a dedicated Linux server: able to install packages, build software, develop applications, and interact with the cluster. It will be a key service with heavy resource allocation.

**Decisions made:**
- Base image: `ubuntu:24.04` directly from Docker Hub (no custom image build)
- Architecture: ConfigMap entrypoint + bjw-s HelmRelease (matches all cluster services)
- Cluster access: Namespaced admin in `ai`, read-only elsewhere
- NFS path: `/volume1/syncthing` (iCloud + Obsidian vault via Syncthing)
- Storage: 50Gi Longhorn PVC for home directory
- Resources: 2 CPU / 4Gi request, 8Gi memory limit
- Auth: Claude Code OAuth via SSH (one-time manual login, token persists on PVC)
- SSH keys: Authorized keys via ExternalSecret from 1Password
- User: UID 1027 / GID 100 (matches NFS media permissions)
- PAI auto-installs on first boot via entrypoint script

---

## Zero-Interaction Prerequisites

These items must be in place before deployment. All are handled during implementation:

| Prerequisite | How | Status |
|---|---|---|
| 1Password `pai` item in `homeops` vault | Created via `op` CLI with biometric auth | Implementation step |
| `authorized_keys` field in `pai` item | SSH public key from `~/.ssh/id_ed25519.pub` | Key: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICj962t+RwZGIrcycomEDvbgWAoiFVQT9X6YIvJMVPaX` |
| Kubernetes manifests committed to repo | Git commit + push triggers Flux reconciliation | Implementation step |

**Post-deploy manual step (one-time only):**
- SSH into pod and run `claude login` for Anthropic OAuth authentication
- Token persists on PVC across all future restarts

---

## Architecture

### Container Image

**Image:** `ubuntu:24.04` (standard Docker Hub image, no custom build)

All tooling is installed on first boot via an entrypoint script and persists on the 50Gi Longhorn PVC at `/home/pai`. On subsequent restarts, only `openssh-server` needs reinstall (~10-15s) since it's a system package that can't persist on the PVC.

### Entrypoint Script (ConfigMap)

Mounted as a ConfigMap at `/entrypoint.sh`. Handles two modes:

**First boot** (~2-3 minutes):
1. Install `openssh-server`, `sudo`, `git`, `curl`, `build-essential`, `python3`, `jq`, `tmux`, `vim`, `nano`, `wget`, `unzip`, `htop`
2. Create `pai` user (UID 1027, GID 100) with passwordless sudo
3. Configure SSHD (key-only auth, no root login, host keys at `/home/pai/.ssh-host-keys/`)
4. Install Node.js 22 via nvm to `/home/pai/.nvm/`
5. Install Bun to `/home/pai/.bun/`
6. Install Claude Code via npm (`~/.npm-global/`)
7. Install kubectl to `/home/pai/.local/bin/`
8. Clone PAI repo and run installer
9. Copy SSH authorized keys from secret mount
10. Mark `/home/pai/.setup-complete`
11. Start SSHD

**Subsequent restarts** (~10-15 seconds):
1. Install `openssh-server` and `sudo` (system packages, can't persist)
2. Recreate `pai` user (system user, can't persist)
3. Configure SSHD
4. Copy SSH authorized keys from secret mount
5. Start SSHD

User-local tools (node, bun, claude, kubectl) are already on the PVC and sourced via `.bashrc` PATH entries.

```bash
#!/bin/bash
set -e

PAI_HOME="/home/pai"
SETUP_MARKER="${PAI_HOME}/.setup-complete"

# --- Always required (system packages don't persist across restarts) ---

# Install openssh-server and sudo
apt-get update -qq && apt-get install -y -qq openssh-server sudo > /dev/null 2>&1

# Create pai user if not exists (system user records don't persist)
if ! id pai &>/dev/null; then
    groupadd -g 100 users 2>/dev/null || true
    useradd -m -s /bin/bash -u 1027 -g 100 -d "${PAI_HOME}" pai 2>/dev/null || true
    echo "pai ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/pai
    chmod 0440 /etc/sudoers.d/pai
fi

# Configure SSHD
mkdir -p /run/sshd
sed -i 's/#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config

# Use host keys from PVC (persistent across restarts)
HOST_KEY_DIR="${PAI_HOME}/.ssh-host-keys"
mkdir -p "${HOST_KEY_DIR}"
chown 1027:100 "${HOST_KEY_DIR}"

# Add HostKey directives if not already present
grep -q "HostKey ${HOST_KEY_DIR}" /etc/ssh/sshd_config || {
    echo "HostKey ${HOST_KEY_DIR}/ssh_host_ed25519_key" >> /etc/ssh/sshd_config
    echo "HostKey ${HOST_KEY_DIR}/ssh_host_rsa_key" >> /etc/ssh/sshd_config
}

# Generate host keys if not present
if [ ! -f "${HOST_KEY_DIR}/ssh_host_ed25519_key" ]; then
    ssh-keygen -t ed25519 -f "${HOST_KEY_DIR}/ssh_host_ed25519_key" -N ""
    ssh-keygen -t rsa -b 4096 -f "${HOST_KEY_DIR}/ssh_host_rsa_key" -N ""
fi

# Set up SSH authorized keys from secret mount
SSH_DIR="${PAI_HOME}/.ssh"
mkdir -p "${SSH_DIR}"
if [ -f /secrets/authorized_keys ]; then
    cp /secrets/authorized_keys "${SSH_DIR}/authorized_keys"
    chmod 600 "${SSH_DIR}/authorized_keys"
fi
chown -R 1027:100 "${SSH_DIR}"

# --- First boot only ---

if [ ! -f "${SETUP_MARKER}" ]; then
    echo "=== PAI First Boot Setup ==="

    # Install full toolchain
    apt-get install -y -qq git curl wget unzip jq htop tmux vim nano \
        build-essential python3 python3-pip python3-venv \
        ca-certificates gnupg > /dev/null 2>&1

    # Copy skeleton files (PVC mount overwrites /home/pai on first use)
    if [ ! -f "${PAI_HOME}/.bashrc" ]; then
        cp /etc/skel/.bashrc /etc/skel/.profile "${PAI_HOME}/" 2>/dev/null || true
    fi

    # Install Node.js 22 via nvm (persists at /home/pai/.nvm/)
    su - pai -c 'curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash'
    su - pai -c '. ~/.nvm/nvm.sh && nvm install 22 && nvm use 22 && nvm alias default 22'

    # Install Bun (persists at /home/pai/.bun/)
    su - pai -c 'curl -fsSL https://bun.sh/install | bash'

    # Install Claude Code globally for pai user
    su - pai -c '. ~/.nvm/nvm.sh && npm install -g @anthropic-ai/claude-code'

    # Install kubectl (persists at /home/pai/.local/bin/)
    su - pai -c 'mkdir -p ~/.local/bin && curl -Lo ~/.local/bin/kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x ~/.local/bin/kubectl'

    # Add PATH entries to .bashrc
    su - pai -c 'cat >> ~/.bashrc << "PATHS"

# PAI toolchain paths
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
PATHS'

    # Auto-install PAI framework (version from PAI_VERSION env var)
    PAI_VER="${PAI_VERSION:-v4.0.3}"
    su - pai -c "cd ~ && git clone https://github.com/danielmiessler/Personal_AI_Infrastructure.git"
    su - pai -c "cd ~/Personal_AI_Infrastructure/Releases/${PAI_VER} && cp -r .claude ~/ && cd ~/.claude && bash install.sh"

    chown -R 1027:100 "${PAI_HOME}"
    touch "${SETUP_MARKER}"
    echo "=== PAI First Boot Setup Complete ==="
fi

# Start SSHD
exec /usr/sbin/sshd -D -e
```

### Kubernetes Manifests

**Namespace:** `ai` (alongside Ollama, LiteLLM, OpenWebUI, Qdrant, n8n)

**File structure:**
```
kubernetes/apps/ai/pai/
  ks.yaml                    # Flux Kustomization
  app/
    kustomization.yaml       # Kustomize resource list
    helmrelease.yaml         # bjw-s app-template HelmRelease
    ocirepository.yaml       # bjw-s chart source
    externalsecret.yaml      # 1Password secret (SSH keys)
    rbac.yaml                # ServiceAccount + RBAC bindings
    configmap.yaml           # Entrypoint script
```

#### helmrelease.yaml

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: pai
spec:
  chartRef:
    kind: OCIRepository
    name: pai
  interval: 1h
  values:
    controllers:
      main:
        annotations:
          reloader.stakater.com/auto: "true"
        containers:
          app:
            image:
              repository: ubuntu
              tag: "24.04"
            command: ["/bin/bash", "/entrypoint/entrypoint.sh"]
            env:
              TZ: America/Denver
              PAI_VERSION: "v4.0.3"
            probes:
              liveness:
                enabled: true
                custom: true
                spec:
                  tcpSocket:
                    port: 22
                  periodSeconds: 30
              readiness:
                enabled: true
                custom: true
                spec:
                  tcpSocket:
                    port: 22
                  periodSeconds: 10
              startup:
                enabled: true
                custom: true
                spec:
                  tcpSocket:
                    port: 22
                  initialDelaySeconds: 10
                  periodSeconds: 5
                  failureThreshold: 60
            resources:
              requests:
                cpu: 2000m
                memory: 4Gi
              limits:
                memory: 8Gi
        pod:
          securityContext:
            fsGroup: 100

    serviceAccount:
      name: pai
      create: false

    service:
      main:
        controller: main
        type: LoadBalancer
        ports:
          ssh:
            port: 22

    persistence:
      home:
        type: persistentVolumeClaim
        storageClass: longhorn
        accessMode: ReadWriteOnce
        size: 50Gi
        globalMounts:
          - path: /home/pai
      ssh-keys:
        type: secret
        name: pai-secret
        globalMounts:
          - path: /secrets
            readOnly: true
      entrypoint:
        type: configMap
        name: pai-entrypoint
        globalMounts:
          - path: /entrypoint
            readOnly: true
      syncthing:
        type: nfs
        server: ${NFS_SERVER}
        path: /volume1/syncthing
        globalMounts:
          - path: /data/syncthing
```

**Key changes from custom image approach:**
- Image is `ubuntu:24.04` directly
- `command` overrides default entrypoint to use ConfigMap script
- Startup probe with 5-minute window (failureThreshold 60 x period 5s) for first boot
- Liveness/readiness `initialDelaySeconds: 180` for first boot tolerance
- SSH host keys stored inside home PVC at `/home/pai/.ssh-host-keys/` (eliminates separate PVC)
- Entrypoint ConfigMap mounted at `/entrypoint/`

#### configmap.yaml

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: pai-entrypoint
data:
  entrypoint.sh: |
    #!/bin/bash
    set -e
    # (full entrypoint script from above)
```

#### ocirepository.yaml

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: pai
spec:
  interval: 1h
  layerSelector:
    mediaType: application/vnd.cncf.helm.chart.content.v1.tar+gzip
    operation: copy
  ref:
    tag: 4.6.2
  url: oci://ghcr.io/bjw-s-labs/helm/app-template
```

#### externalsecret.yaml

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: pai
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-store
  target:
    name: pai-secret
  dataFrom:
    - extract:
        key: pai
```

**1Password item `pai` in `homeops` vault:**
- `authorized_keys`: `ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICj962t+RwZGIrcycomEDvbgWAoiFVQT9X6YIvJMVPaX`

#### rbac.yaml

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pai
  namespace: ai
automountServiceAccountToken: true
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pai-admin
  namespace: ai
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: admin
subjects:
  - kind: ServiceAccount
    name: pai
    namespace: ai
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: pai-cluster-viewer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - kind: ServiceAccount
    name: pai
    namespace: ai
```

#### ks.yaml

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: pai
  namespace: flux-system
spec:
  interval: 1h
  path: ./kubernetes/apps/ai/pai/app
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: ai
  wait: false
```

#### app/kustomization.yaml

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
  - ocirepository.yaml
  - externalsecret.yaml
  - rbac.yaml
  - configmap.yaml
```

### Namespace Integration

Add to `kubernetes/apps/ai/kustomization.yaml`:
```yaml
resources:
  # ... existing entries ...
  - ./pai/ks.yaml
```

---

## Storage Layout

| Mount | Type | Size | Path in Pod | Purpose |
|-------|------|------|-------------|---------|
| home | Longhorn PVC | 50Gi | /home/pai | ~/.claude/, PAI state, ~/.nvm/, ~/.bun/, ~/.local/bin/kubectl, git repos, projects |
| ssh-keys | Secret | — | /secrets | Authorized SSH public keys from 1Password |
| entrypoint | ConfigMap | — | /entrypoint | Entrypoint script (read-only) |
| syncthing | NFS | — | /data/syncthing | iCloud files + Obsidian vault (read/write) |

**Persistence across restarts:**
- All of `/home/pai` persists — Claude Code auth tokens, PAI configs, TELOS files, memory, Node.js, Bun, kubectl, Claude Code CLI, all projects
- SSH host keys persist at `/home/pai/.ssh-host-keys/` — no fingerprint change on restart
- System packages (openssh-server, sudo) reinstalled on each restart (~10-15s)
- NFS mount is stateless (data lives on Synology)

---

## Networking

| Service | Type | Port | Access |
|---------|------|------|--------|
| pai | LoadBalancer | 22 | LAN (10.0.3.x) + Tailscale subnet routing |

**Single service, single controller = no suffix** (bjw-s naming convention).

**No ingress routes initially.** SSH is the primary access method via:
1. Direct LAN: `ssh pai@<loadbalancer-ip>`
2. Tailscale: `ssh pai@<loadbalancer-ip>` (via k8s-gateway subnet routing)

**Future:** When PAI builds an API, add a second service for HTTP and expose via HTTPRoute to envoy-internal.

**Note:** Cilium LBIPAM will assign a stable IP from the pool. Record the assigned IP after first deployment for SSH config.

---

## Security

- **SSHD runs as root** (required for privilege separation and port 22 binding); user sessions run as non-root `pai` user with sudo
- **SSH key-only auth** — no passwords, keys from 1Password
- **RBAC scoped** — admin in ai namespace, view elsewhere
- **NFS permissions** — UID 1027/GID 100 matches Synology media user
- **No public ingress** — LoadBalancer only accessible from LAN + Tailscale
- **ServiceAccount token auto-mounted** — kubectl works from inside the pod

---

## First Boot Flow (Automated)

1. Flux deploys the HelmRelease
2. Pod starts with `ubuntu:24.04` image
3. Entrypoint script runs first-boot setup (~2-3 minutes):
   - Installs system packages + creates pai user
   - Installs Node.js, Bun, Claude Code, kubectl to user-local paths on PVC
   - Clones and installs PAI framework
4. SSHD starts, startup probe succeeds
5. **One manual step:** SSH in and run `claude login` for Anthropic OAuth

After step 5, everything is fully autonomous across all future restarts.

---

## Resource Summary

| Resource | Value |
|----------|-------|
| CPU request | 2000m |
| CPU limit | (none — allow burst) |
| Memory request | 4Gi |
| Memory limit | 8Gi |
| PVC (home) | 50Gi Longhorn |
| NFS | /volume1/syncthing |
| Image | ubuntu:24.04 (~78MB pull, no custom build) |

---

## Files to Create/Modify

**New files:**
- `kubernetes/apps/ai/pai/ks.yaml`
- `kubernetes/apps/ai/pai/app/helmrelease.yaml`
- `kubernetes/apps/ai/pai/app/ocirepository.yaml`
- `kubernetes/apps/ai/pai/app/externalsecret.yaml`
- `kubernetes/apps/ai/pai/app/rbac.yaml`
- `kubernetes/apps/ai/pai/app/configmap.yaml`
- `kubernetes/apps/ai/pai/app/kustomization.yaml`

**Modified files:**
- `kubernetes/apps/ai/kustomization.yaml` (add `./pai/ks.yaml` to resources)

**1Password (via `op` CLI):**
- Create `pai` item in `homeops` vault with `authorized_keys` field containing the ed25519 public key

**No container image build required.**

---

## Verification

1. **ExternalSecret syncing:** `kubectl get externalsecret pai -n ai` — SecretSynced
2. **Flux reconciliation:** `flux reconcile kustomization pai` — HelmRelease becomes True
3. **Pod running:** `kubectl get pods -n ai -l app.kubernetes.io/name=pai` — Running, 1/1 Ready
4. **SSH access:** `ssh pai@<lb-ip>` — connects successfully
5. **Claude Code:** `claude --version` — returns version
6. **NFS mount:** `ls /data/syncthing/` — shows iCloud/Obsidian files
7. **Cluster access:** `kubectl get pods -A` — lists all pods (read-only)
8. **Namespace admin:** `kubectl run test --image=alpine -n ai` — succeeds
9. **PAI installed:** `ls ~/.claude/SYSTEM/` — PAI framework files present
10. **Persistence:** Delete pod, wait for reschedule, SSH in — all tools + data intact, startup takes ~15s
