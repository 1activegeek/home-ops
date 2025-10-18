# Cluster Context & Configuration Memory

This document provides context for AI assistants working with this infrastructure repository.

## Overview

This is a home operations Kubernetes cluster deployed using:
- **Base Template**: [onedr0p/cluster-template](https://github.com/onedr0p/cluster-template)
- **Operating System**: Talos Linux (immutable, API-driven)
- **GitOps**: FluxCD v2 with SOPS encryption
- **Orchestration**: Kubernetes cluster with 3 control plane nodes

## Cluster Architecture

### Node Configuration
- **3x Control Plane Nodes**: Mini PC hardware with NVMe storage
- **Cluster Endpoint**: High-availability VIP configuration
- **Network**: Static IP addressing with dedicated gateway
- **Talos Image**: Custom factory image with specific extensions

### Storage Strategy

**Volume Provisioning** (per node):
- **EPHEMERAL**: System operations volume (20-50GB, static size)
- **secondary**: Application data volume (500GB+, uses remaining space)

**Distributed Storage**:
- **Rook-Ceph v1.18.2**: 3-node replicated block storage
- **Storage Class**: `ceph-block` (default)
  - 3-way replication with host-level fault domain
  - zstd compression (aggressive mode)
  - Volume expansion enabled
  - Discard/TRIM support
  - Snapshot capability
- **OSD Devices**: Specific NVMe partitions per node (part5)

## Network Architecture

### Ingress Controllers (Dual Path)
1. **Internal**: ingress-nginx with `internal` IngressClass
2. **External**: ingress-nginx with `external` IngressClass + Cloudflare tunnel

### DNS Configuration
- **Internal DNS**: k8s_gateway for split-horizon DNS resolution
- **External DNS**: external-dns with Cloudflare provider
- **Core DNS**: CoreDNS for cluster DNS

### Service Mesh
- **CNI**: Cilium v1.18.2 with native routing
- **Network Policy**: Cilium-based
- **Service Mesh Features**: Available via Cilium capabilities

## Application Stack

### Core Infrastructure (kube-system namespace)
| Application | Version | Purpose |
|-------------|---------|---------|
| Cilium | v1.18.2 | Container networking (CNI) |
| CoreDNS | v1.45.0 | Cluster DNS resolution |
| Spegel | v0.4.0 | Distributed container registry mirror |
| Reloader | Latest | Automatic pod restarts on ConfigMap/Secret changes |
| Metrics-Server | Latest | Resource usage metrics |
| Snapshot-Controller | Latest | Volume snapshot management |

### Security (security namespace)
- **External-Secrets** v0.20.3: Syncs secrets from external providers
- **OnePassword Connect**: Integration with 1Password for secret management
- **Cert-Manager** v1.19.1: Automated TLS certificate management (Let's Encrypt)

### Storage (storage + rook-ceph namespaces)
- **Rook-Ceph Operator** v1.18.2: Distributed storage orchestration
- **Rook-Ceph Cluster**: Active cluster with monitoring & dashboard
- **CSI Driver NFS**: NFS volume support

### Networking (network namespace)
**Internal** (network/internal):
- ingress-nginx: Internal traffic routing
- k8s-gateway: Internal DNS gateway for split-horizon

**External** (network/external):
- ingress-nginx: External traffic routing
- external-dns: Automated DNS record management
- cloudflared: Cloudflare tunnel for external access

### GitOps (flux-system namespace)
- **Flux Operator** v0.32.0: Flux controller manager
- **Flux Instance** v0.32.0: Flux runtime components
- **GitHub Integration**: Git source tracking with webhook support

### Observability
- **Ceph Dashboard**: Available via internal ingress
- **Prometheus Integration**: Configured for Ceph metrics
- **Monitoring Ready**: Metrics endpoints exposed

### Demo/Testing (default namespace)
- **Echo**: Public endpoint demonstration
- **Secret-Printer**: Secret injection testing

## GitOps Workflow

### Repository Structure
```
.
├── bootstrap/          # Initial cluster bootstrap (Helmfile)
├── kubernetes/         # Flux-managed Kubernetes resources
│   ├── apps/          # Application deployments by namespace
│   ├── components/    # Reusable Kustomize components
│   └── flux/          # Flux CD configuration
│       ├── cluster/   # Root Kustomization (entry point)
│       └── meta/      # Helm repositories
├── talos/             # Talos Linux configuration
│   ├── talconfig.yaml # Cluster & node definitions
│   ├── talenv.yaml    # Version specifications
│   └── patches/       # Talos configuration patches
└── scripts/           # Utility scripts
```

### Flux Reconciliation Flow
1. **GitRepository** → `flux-system` namespace tracks GitHub main branch
2. **cluster-meta Kustomization** → Deploys Helm repositories
3. **cluster-apps Kustomization** → Deploys all applications from `/kubernetes/apps/`
4. **SOPS Decryption**: Automatic decryption of `.sops.yaml` files using Age keys

### Secret Management
- **Encryption**: SOPS + Age encryption for secrets at rest
- **Key Storage**: Age keys stored as Kubernetes secrets (managed by Flux)
- **Decryption**: Automatic decryption by Flux during reconciliation
- **Pattern**: `.sops.yaml` files in repository, encrypted data/stringData fields only

### Deployment Pattern
- **Push to GitHub** → Flux detects changes → Applies to cluster
- **Webhook**: GitHub webhook configured for immediate reconciliation
- **Reconciliation Interval**: 1 hour (automatic polling)
- **Force Sync**: `task reconcile` command available

## Automation

### Renovate Configuration
- **Schedule**: Weekly (weekends)
- **Auto-Merge**: Patches and minor updates (3-day minimum age)
- **Grouped Updates**: System components (Cert-Manager, CoreDNS, Flux, Spegel)
- **Supported Managers**: Flux, Helm, Kustomize, Docker, GitHub Actions
- **Dashboard**: Renovate Dependency Dashboard issue in repository

### Task Automation (Taskfile)
Common tasks available via `task` command:
- `task bootstrap:talos` - Install Talos on nodes
- `task bootstrap:apps` - Bootstrap core applications
- `task reconcile` - Force Flux reconciliation
- `task talos:generate-config` - Regenerate Talos configs
- `task talos:upgrade-node IP=<ip>` - Upgrade Talos version
- `task talos:upgrade-k8s` - Upgrade Kubernetes version

## Development Environment

### Tool Management
- **mise**: Development environment manager (configured in `.mise.toml`)
- **Key Tools**: kubectl, helm, flux, talosctl, sops, age, kustomize, cilium-cli

### Configuration Files
- `.sops.yaml` - SOPS encryption rules and key configuration
- `Taskfile.yaml` - Task automation definitions
- `.renovaterc.json5` - Renovate dependency automation
- `.mise.toml` - Development tool versions and environment variables

## Operational Notes

### Storage Considerations
- **Ceph Health**: Monitor via dashboard or `ceph status` in toolbox pod
- **OSD Distribution**: One OSD per node on specific NVMe partitions
- **Replication**: 3-way replication ensures data availability with 1 node failure
- **Compression**: Aggressive zstd compression saves space
- **Performance**: Direct block access with discard/TRIM support

### Network Access Patterns
- **Internal Services**: Use `internal` IngressClass + k8s_gateway DNS
- **External Services**: Use `external` IngressClass + Cloudflare tunnel
- **Certificate Management**: Automatic via cert-manager + Let's Encrypt

### Maintenance Procedures
1. **Talos Updates**: Update `talenv.yaml` → Generate config → Apply to nodes
2. **Kubernetes Updates**: Update `talenv.yaml` → Run upgrade task
3. **Application Updates**: Renovate PRs → Review → Merge → Flux applies
4. **Configuration Changes**: Edit files → Commit → Push → Flux reconciles

## Key Design Decisions

### Why Talos Linux?
- Immutable infrastructure (no SSH access needed)
- API-driven configuration
- Minimal attack surface
- Built for Kubernetes

### Why Rook-Ceph?
- Native Kubernetes integration
- Replicated block storage
- Dynamic provisioning
- Snapshot support
- No external storage dependency

### Why Dual Volume Provisioning?
- Isolate system operations from application data
- Prevent system disk exhaustion
- Optimize for different I/O patterns

### Why Dual Ingress Controllers?
- Security isolation (internal vs. external traffic)
- Different routing policies
- Cloudflare integration for external access
- Local network access without internet dependency

## Common Operations

### Checking Cluster Health
```bash
# Talos health
talosctl health --nodes <node-ip>

# Kubernetes health
kubectl get nodes
kubectl get pods -A

# Cilium status
cilium status

# Flux status
flux get all -A

# Ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

### Debugging Application Issues
1. Check Flux reconciliation: `flux get hr -A`
2. Check pod status: `kubectl -n <namespace> get pods`
3. Check pod logs: `kubectl -n <namespace> logs <pod>`
4. Check events: `kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'`

### Adding New Applications
1. Create directory in `kubernetes/apps/<namespace>/<app-name>/`
2. Add Kustomization resource (`ks.yaml`)
3. Add HelmRelease or Kustomize manifests
4. Commit and push to GitHub
5. Flux will automatically reconcile

## Reference Documentation

- **Talos Linux**: https://www.talos.dev/
- **Flux CD**: https://fluxcd.io/
- **Rook-Ceph**: https://rook.io/
- **Cilium**: https://cilium.io/
- **Cluster Template**: https://github.com/onedr0p/cluster-template

## Change History

- **Initial Bootstrap**: Completed with 3-node mini PC cluster
- **Storage Deployment**: Rook-Ceph configured with NVMe partitions
- **Hardware Migration**: Changed from Raspberry Pi to mini PC nodes
- **Renovate Active**: Automated dependency management operational

---

**Last Updated**: 2025-10-18
**Cluster Status**: Operational
**GitOps State**: Clean (all changes committed)
