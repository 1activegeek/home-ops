# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Project Overview

This is a GitOps-based Kubernetes home lab cluster running on **Talos Linux** with **Flux CD** for declarative cluster management.

**Infrastructure:**
- **OS:** Talos Linux v1.12.1 (immutable, API-managed)
- **Kubernetes:** v1.35.0
- **GitOps:** Flux CD v2.7.5
- **Cluster:** 3-node HA control plane (10.0.3.21-23, VIP: 10.0.3.51)

**Core Components:**
- **CNI:** Cilium (with L2 announcements for LoadBalancer IPs)
- **Ingress:** Envoy Gateway (dual gateway: internal + external)
- **DNS:** k8s-gateway (internal), external-dns (Cloudflare)
- **Certificates:** cert-manager (Let's Encrypt production)
- **Tunneling:** Cloudflare Tunnel (public access)
- **Secrets:** External Secrets Operator + 1Password (apps), SOPS + age (bootstrap)
- **Storage:** Longhorn (distributed block storage), NFS CSI driver
- **Other:** Spegel (P2P image caching), Reloader (auto pod restarts)

## Critical Principles

### 1. GitOps-Only Changes

**All changes MUST go through Git - never modify the cluster directly.**

```bash
# ALLOWED (read-only troubleshooting)
kubectl get pods -A
kubectl describe pod <name> -n <namespace>
kubectl logs <pod> -n <namespace>
kubectl port-forward svc/<name> 8080:80 -n <namespace>

# NEVER DO (will be reverted by Flux)
kubectl apply -f ...
kubectl create ...
kubectl edit ...
kubectl patch ...
kubectl delete ...
```

**Workflow:**
1. Edit YAML files in `kubernetes/apps/`
2. Commit and push to Git
3. Run `task reconcile` to force immediate sync (or wait for 1h interval)
4. Monitor: `kubectl get pods -A -w`

### 2. Never Commit Unencrypted Secrets

**Application Secrets:** Always use External Secrets + 1Password
**Bootstrap Secrets:** Only use SOPS for infrastructure that External Secrets depends on

```bash
# Verify all .sops.yaml files are encrypted before committing
grep -l "sops:" kubernetes/**/*.sops.yaml talos/**/*.sops.yaml
```

### 3. Validate Before Committing

```bash
# Run flux-local validation
task validate

# Or manually:
flux-local test --enable-helm --all-namespaces --path ./kubernetes/flux/cluster -v
```

## Directory Structure

```
.
├── kubernetes/
│   ├── flux/cluster/ks.yaml    # Root Kustomization (patches all apps)
│   ├── apps/                   # Applications by namespace
│   │   ├── <namespace>/
│   │   │   ├── kustomization.yaml
│   │   │   ├── namespace.yaml
│   │   │   └── <app-name>/
│   │   │       ├── ks.yaml           # Flux Kustomization
│   │   │       └── app/
│   │   │           ├── kustomization.yaml
│   │   │           ├── helmrelease.yaml
│   │   │           ├── ocirepository.yaml
│   │   │           └── [externalsecret.yaml]
│   └── components/sops/        # Shared SOPS component
├── talos/
│   ├── talconfig.yaml          # Cluster configuration
│   ├── talenv.yaml             # Version specs
│   ├── talsecret.sops.yaml     # Encrypted machine secrets
│   ├── clusterconfig/          # Generated configs (gitignored)
│   └── patches/                # Global and controller patches
├── bootstrap/                  # Helmfile bootstrap configs
├── scripts/                    # Bootstrap scripts
└── .taskfiles/                 # Task definitions
```

## Adding New Applications

### Standard App Structure

Create this structure for new apps:

```
kubernetes/apps/<namespace>/<app-name>/
├── ks.yaml
└── app/
    ├── kustomization.yaml
    ├── helmrelease.yaml
    ├── ocirepository.yaml
    └── externalsecret.yaml      # If app needs secrets
```

### 1. Flux Kustomization (ks.yaml)

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app-name>
spec:
  interval: 1h
  path: ./kubernetes/apps/<namespace>/<app-name>/app
  postBuild:
    substituteFrom:
      - name: cluster-secrets
        kind: Secret
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
    namespace: flux-system
  targetNamespace: <namespace>
  wait: false
```

**Notes:**
- Use `wait: true` only for critical infrastructure dependencies
- Add `dependsOn` when app requires another to be ready first
- Add `healthChecks` for custom resources that need readiness verification

### 2. OCI Repository (ocirepository.yaml)

```yaml
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: <app-name>
spec:
  interval: 1h
  url: oci://<registry>/<path>/<chart>
  ref:
    tag: "<version>"
  layerSelector:
    mediaType: "application/vnd.cncf.helm.chart.content.v1.tar+gzip"
```

**Always use OCI repositories** - only use HelmRepository for charts not available via OCI.

### 3. HelmRelease (helmrelease.yaml)

```yaml
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: <app-name>
spec:
  chartRef:
    kind: OCIRepository
    name: <app-name>
  interval: 1h
  values:
    # App-specific values here
```

**Key patterns from existing apps:**

```yaml
values:
  # Use Helm template variables for hostnames
  route:
    app:
      hostnames: ["{{ .Release.Name }}.${SECRET_DOMAIN}"]
      parentRefs:
        - name: envoy-internal    # or envoy-external for public
          namespace: network
          sectionName: https

  # Always add reloader annotation for apps with secrets/configmaps
  podAnnotations:
    reloader.stakater.com/auto: "true"

  # Security best practices
  defaultPodOptions:
    securityContext:
      runAsNonRoot: true
      runAsUser: 65534
      runAsGroup: 65534

  # Reference secrets from ExternalSecret
  envFrom:
    - secretRef:
        name: <app-name>-secret
```

### 4. Kustomization (app/kustomization.yaml)

```yaml
---
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./helmrelease.yaml
  - ./ocirepository.yaml
  - ./externalsecret.yaml    # Include if present
```

### 5. Register App in Namespace

Add to `kubernetes/apps/<namespace>/kustomization.yaml`:

```yaml
resources:
  - ./namespace.yaml
  - ./<existing-app>/ks.yaml
  - ./<new-app>/ks.yaml        # Add this line
```

## Secret Management

### Application Secrets: External Secrets + 1Password

**All application secrets MUST use this method.**

1. **Create item in 1Password** (vault: `homeops`)
   - Item name becomes the `key` in ExternalSecret
   - Field names become the secret data keys

2. **Create ExternalSecret resource:**

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app-name>
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-store
  target:
    name: <app-name>-secret
    template:
      data:
        DB_PASSWORD: "{{ .db_password }}"
        API_KEY: "{{ .api_key }}"
  dataFrom:
    - extract:
        key: <1password-item-name>
```

**Template pattern:** Maps 1Password field names (snake_case) to secret keys.

3. **Reference in HelmRelease:**

```yaml
values:
  envFrom:
    - secretRef:
        name: <app-name>-secret
  # Or for specific fields:
  envSecrets:
    someCredential:
      existingSecret: "<app-name>-secret"
      key: "DB_PASSWORD"
```

### Bootstrap Secrets: SOPS (Infrastructure Only)

**Only use SOPS for secrets that External Secrets depends on:**
- 1Password Connect credentials
- Flux GitHub tokens
- Talos machine secrets
- Cluster-wide variables (`cluster-secrets`)

```bash
# Edit existing SOPS secret
sops kubernetes/apps/<namespace>/<app>/app/secret.sops.yaml

# Create new SOPS secret (bootstrap only)
kubectl create secret generic my-secret \
  --from-literal=key=value \
  --dry-run=client -o yaml | \
  sops --filename-override kubernetes/path/secret.sops.yaml \
  --encrypt /dev/stdin > kubernetes/path/secret.sops.yaml
```

## Gateway & Networking

### Two Envoy Gateways

| Gateway | Use Case | Access |
|---------|----------|--------|
| `envoy-internal` | Private apps (dashboards, admin UIs) | Local network only |
| `envoy-external` | Public apps via Cloudflare Tunnel | Internet accessible |

### HTTPRoute Patterns

**Option 1: Embedded in HelmRelease** (preferred when chart supports it)

```yaml
# In helmrelease.yaml values
values:
  httproute:
    enabled: true
    hostnames:
      - <app>.${SECRET_DOMAIN}
    parentRefs:
      - name: envoy-internal
        namespace: network
        sectionName: https
    rules:
      - backendRefs:
          - name: <service-name>
            port: 80
```

**Option 2: Separate HTTPRoute file** (when chart doesn't support routes)

```yaml
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: <app-name>
spec:
  hostnames:
    - <app>.${SECRET_DOMAIN}
  parentRefs:
    - name: envoy-internal
      namespace: network
      sectionName: https
  rules:
    - backendRefs:
        - name: <service-name>
          port: 80
```

### Gateway IPs (Cilium L2 Announcements)

- Internal gateway: `10.0.3.53`
- External gateway: `10.0.3.54`

## Common Commands

```bash
# List all tasks
task

# Force Flux sync
task reconcile

# Validate configs locally
task validate

# Check Flux status
flux check
flux get ks -A
flux get hr -A

# Watch pod status
kubectl get pods -A -w

# Check HelmRelease status
kubectl describe hr <name> -n <namespace>

# Check ExternalSecret sync
kubectl get externalsecret -A
kubectl describe externalsecret <name> -n <namespace>

# Check certificate status
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>
```

### Talos Commands

```bash
# Generate configs after talconfig.yaml changes
task talos:generate-config

# Apply config to node
task talos:apply-node IP=10.0.3.21

# Upgrade Talos on node
task talos:upgrade-node IP=10.0.3.21

# Upgrade Kubernetes
task talos:upgrade-k8s

# Check node status
talosctl -n 10.0.3.21 get members
talosctl -n 10.0.3.21 health
```

## Debugging

### Flux Issues

```bash
# Check source sync
flux get sources git -A

# Check Kustomization status
flux get ks -A
kubectl describe kustomization <name> -n flux-system

# Check HelmRelease
flux get hr -A
kubectl describe helmrelease <name> -n <namespace>

# Force reconcile specific app
flux reconcile ks <app-name> --with-source
```

### Pod Issues

```bash
# Get events sorted by time
kubectl get events -n <namespace> --sort-by='.metadata.creationTimestamp'

# Check pod logs
kubectl logs <pod> -n <namespace> -f
kubectl logs <pod> -n <namespace> --previous

# Describe pod for status/events
kubectl describe pod <pod> -n <namespace>
```

### Network Issues

```bash
# Check Cilium
cilium status

# Check gateways
kubectl get gateway -A
kubectl describe gateway envoy-internal -n network

# Check routes
kubectl get httproute -A
kubectl describe httproute <name> -n <namespace>
```

## Helm Chart Conventions

When adding new apps, follow these patterns observed in the codebase:

### Hostnames
- Use `{{ .Release.Name }}.${SECRET_DOMAIN}` for primary hostname
- Additional subdomains: `subdomain.${SECRET_DOMAIN}`

### Secrets
- Name: `<app-name>-secret`
- Store ALL app secrets in single 1Password item
- Use `template.data` mapping in ExternalSecret

### Security
```yaml
defaultPodOptions:
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534

containers:
  app:
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities: { drop: ["ALL"] }
```

### Reloader
Add to any deployment using secrets/configmaps:
```yaml
podAnnotations:
  reloader.stakater.com/auto: "true"
```

### Storage
Use `longhorn` StorageClass for persistent volumes:
```yaml
persistence:
  data:
    enabled: true
    storageClassName: "longhorn"
    size: 1Gi
```

## Version Management

| Component | Location | Update Method |
|-----------|----------|---------------|
| Talos/K8s versions | `talos/talenv.yaml` | Renovate auto-updates |
| CLI tools | `.mise.toml` | Renovate auto-updates |
| Helm charts | `*/ocirepository.yaml` | Renovate auto-updates |
| Container images | `*/helmrelease.yaml` | Renovate auto-updates |

Renovate runs weekly (weekends) and auto-merges minor/patch updates for tools and GitHub Actions.

## Important Files

- **Root Kustomization:** `kubernetes/flux/cluster/ks.yaml` - Global patches for all HelmReleases
- **Cluster Secrets:** `kubernetes/components/sops/cluster-secrets.sops.yaml` - Shared variables
- **SOPS Config:** `.sops.yaml` - Encryption rules
- **Tool Versions:** `.mise.toml`
- **Tasks:** `Taskfile.yaml`, `.taskfiles/`
