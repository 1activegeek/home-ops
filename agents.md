# Agent Context Document

## ⚠️ CRITICAL SECURITY NOTICE ⚠️

**THIS IS A PUBLIC REPOSITORY - NO SECRETS ALLOWED**

This repository is publicly accessible on GitHub. Before making ANY changes or creating ANY files:

- **NEVER** commit secrets, passwords, API keys, certificates, or credentials in plain text
- **NEVER** commit private keys, tokens, or authentication data
- **NEVER** commit IP addresses, domain names, or hostnames that should remain private
- **ALWAYS** use SOPS encryption for sensitive data (see [Secret Management](#secret-management))
- **ALWAYS** use variable substitution (`${SECRET_DOMAIN}`, `${SECRET_EMAIL}`, etc.) for private values
- **ALWAYS** review diffs before committing to ensure no sensitive data is exposed
- **ALWAYS** check with the user if uncertain whether something should be encrypted

All secrets MUST be encrypted with SOPS or stored in external secret managers (1Password). When in doubt, ask the user before proceeding.

### Variable Substitution

This document uses variable placeholders to avoid exposing sensitive information. All variables are defined in [kubernetes/components/common/cluster-secrets.sops.yaml](kubernetes/components/common/cluster-secrets.sops.yaml) (SOPS-encrypted).

**Available Variables:**
- `${SECRET_DOMAIN}` - Primary domain name
- `${CLUSTER_DOMAIN}` - Cluster domain (may differ from SECRET_DOMAIN)
- `${CLUSTER_VIP}` - Control plane Virtual IP
- `${CLUSTER_NODE_1_IP}`, `${CLUSTER_NODE_2_IP}`, `${CLUSTER_NODE_3_IP}` - Node IP addresses
- `${CLUSTER_LB_IP}` - LoadBalancer IP for ingress controllers
- `${CLUSTER_DNS_IP}` - k8s_gateway DNS service IP
- `${CLUSTER_POD_CIDR}` - Pod network CIDR
- `${CLUSTER_SVC_CIDR}` - Service network CIDR

**Note**: These variables are automatically substituted by Flux CD when deploying Kubernetes resources.

---

## Repository Overview

This is a **home-ops** repository implementing a production-grade Kubernetes cluster for home lab use. The cluster is managed using GitOps principles with Flux CD, running on Talos Linux nodes, and configured entirely through declarative infrastructure-as-code.

**Key Characteristics:**
- **GitOps-First**: Everything in Git, automated reconciliation
- **Immutable Infrastructure**: Talos Linux (no SSH, API-driven)
- **High Availability**: 3-node control plane with VIP-based HA
- **Security-Focused**: SOPS encryption, cert automation, zero-trust networking
- **Cloud-Native**: Modern tooling (Cilium, Flux, Helm, Kustomize)

---

## Cluster Goals & Philosophy

### Primary Goals
1. **Learning Platform**: Hands-on experience with enterprise Kubernetes patterns
2. **Home Automation**: Self-hosted services for personal/home use
3. **High Availability**: Production-like reliability on consumer hardware
4. **Security**: Industry best practices for secret management and network security
5. **Automation**: Minimal manual intervention, automated updates and reconciliation

### Design Philosophy
- **Minimalist**: Template-based, opinionated, single-cluster focus
- **Declarative**: All configuration in Git, no imperative changes
- **Cattle, Not Pets**: Nodes are replaceable, stateless where possible
- **Fail Fast**: Automated health checks and self-healing
- **Documentation**: Code as documentation, supplemented with markdown

---

## Cluster Architecture

### Infrastructure Layer

**Kubernetes Distribution**: Talos Linux v1.11.3
**Kubernetes Version**: v1.34.1
**Cluster Name**: kubernetes
**Control Plane VIP**: ${CLUSTER_VIP}

**Nodes** (3x Mini PC):
- `asgard-mpc-01`: ${CLUSTER_NODE_1_IP} (control-plane + worker)
- `asgard-mpc-02`: ${CLUSTER_NODE_2_IP} (control-plane + worker)
- `asgard-mpc-03`: ${CLUSTER_NODE_3_IP} (control-plane + worker)

**Hardware Requirements** (per node):
- 4+ CPU cores
- 16GB+ RAM
- 256GB+ NVMe SSD
- Gigabit Ethernet

**Volume Provisioning**:
- **EPHEMERAL**: 20-50GB on system disk (limited capacity, for temporary data)
- **secondary**: Remaining disk space for persistent application data

### Networking

**CNI**: Cilium v1.18.2
- Native routing with autoDirectNodeRoutes
- eBPF-based masquerading and KubeProxy replacement
- L2 announcements for LoadBalancer IPs
- Pod CIDR: ${CLUSTER_POD_CIDR}
- Service CIDR: ${CLUSTER_SVC_CIDR}

**Dual Ingress Architecture**:

1. **Internal Ingress** (IngressClass: `internal`)
   - LoadBalancer IP: ${CLUSTER_LB_IP}
   - nginx-ingress controller
   - Local network access only
   - k8s_gateway DNS (${CLUSTER_DNS_IP}) for split-horizon DNS

2. **External Ingress** (IngressClass: `external`)
   - LoadBalancer IP: ${CLUSTER_LB_IP}
   - nginx-ingress controller
   - Cloudflare tunnel for internet access (no port forwarding)
   - external-dns for automatic Cloudflare DNS updates

**DNS Strategy**:
- **Internal**: k8s_gateway for local `.cluster.local` resolution
- **External**: Cloudflare DNS managed by external-dns
- **CoreDNS**: Kubernetes cluster DNS

### GitOps & Automation

**Flux CD** v2.7.2 (Flux Operator v0.32.0)

**Git Source**: GitHub repository (this repo)
**Branch**: main
**Reconciliation**: Hourly polling + webhook on push

**Kustomization Hierarchy**:
1. `cluster-meta`: Deploys Helm repositories (entry point)
2. `cluster-apps`: Deploys all applications (depends on cluster-meta)

**Root Configuration**: [kubernetes/flux/cluster/ks.yaml](kubernetes/flux/cluster/ks.yaml)

**Automation Tools**:
- **Renovate**: Automated dependency updates (weekly, auto-merge patches/minors)
- **Task**: CLI task runner for common operations
- **mise**: Development environment management

### Storage

**Current Setup**:
- **CSI Driver NFS**: NFS volume provisioning
- **Snapshot Controller**: Volume snapshot support
- **Volume Expansion**: Enabled

**Note**: Rook-Ceph was previously used but recently removed (see git history). Storage architecture may be evolving.

### Security & Secrets

**Secret Management**:
- **SOPS + Age**: Secrets encrypted at rest in Git
  - Age key location: `/age.key` (local environment)
  - SOPS config: [.sops.yaml](.sops.yaml)
  - Encrypted files: `*.sops.yaml`
- **external-secrets**: Syncs from external providers
- **1Password Connect**: Integration with 1Password vault for sensitive secrets

**Certificate Management**:
- **cert-manager** v1.19.1
- Let's Encrypt automated certificate issuance
- DNS-01 challenge support via Cloudflare

**Network Security**:
- TLS 1.2 & 1.3 only
- HSTS enabled (1 year max-age)
- Force SSL redirects
- OCSP stapling
- Bot blocking (AI crawlers, etc.)

---

## Key Applications & Services

### Core Infrastructure (kube-system)
- **Cilium**: CNI and network policies
- **CoreDNS**: Cluster DNS
- **Spegel**: Distributed container registry mirror
- **Reloader**: Auto-restart pods on ConfigMap/Secret changes
- **Metrics-Server**: Resource usage metrics

### Security (security namespace)
- **external-secrets**: Secret synchronization
- **1password-connect**: 1Password integration

### Networking (network namespace)
- **ingress-nginx** (internal + external)
- **k8s_gateway**: Split-horizon DNS
- **external-dns**: Cloudflare DNS automation
- **cloudflared**: Cloudflare tunnel

### Platform Services
- **cert-manager**: TLS certificate automation
- **CSI Driver NFS**: NFS storage provisioning

### GitOps (flux-system)
- **Flux Operator**: Flux CD controller
- **GitHub Webhook Receiver**: Immediate reconciliation on push

---

## Directory Structure

```
/home-ops
├── agents.md                    # THIS FILE - AI agent context
├── README.md                    # Human-readable setup guide
├── Taskfile.yaml               # Task automation definitions
├── .taskfiles/                 # Task automation modules
├── .sops.yaml                  # SOPS encryption rules
├── age.key                     # Age encryption key (LOCAL ONLY, .gitignored)
│
├── bootstrap/                  # Initial cluster bootstrap
│   └── helmfile.yaml          # Bootstrap Helmfile
│
├── kubernetes/                 # ALL Kubernetes manifests
│   ├── flux/                  # Flux CD configuration
│   │   ├── cluster/           # Root Kustomization (entry point)
│   │   ├── meta/              # Helm repositories
│   │   └── vars/              # Cluster-wide variables
│   ├── apps/                  # Application deployments (by namespace)
│   │   ├── cert-manager/
│   │   ├── default/
│   │   ├── flux-system/
│   │   ├── kube-system/
│   │   ├── network/
│   │   ├── security/
│   │   └── storage/
│   └── components/            # Reusable Kustomize components
│
├── talos/                     # Talos Linux configuration
│   ├── talconfig.yaml         # Main cluster configuration
│   ├── talenv.yaml            # Version specifications
│   ├── talsecret.sops.yaml    # Encrypted Talos secrets
│   ├── clusterconfig/         # Generated node configs (apply these)
│   └── patches/               # Configuration patches
│       ├── global/            # Patches for all nodes
│       └── controller/        # Patches for control plane only
│
├── scripts/                   # Utility scripts
└── .github/workflows/         # CI/CD workflows
```

---

## Common Workflows

### Reconciling Changes

After pushing changes to the repository:

```bash
# Force immediate Flux reconciliation
task reconcile

# Or manually:
flux reconcile source git home-ops
flux reconcile kustomization cluster-apps
```

**Note**: GitHub webhook should trigger automatic reconciliation within seconds.

### Deploying New Applications

1. Create namespace directory: `kubernetes/apps/<namespace>/<app-name>/`
2. Add Helm release or Kustomization manifests
3. Include in namespace's `kustomization.yaml`
4. Commit and push (Flux auto-deploys)

**Template structure**:
```
kubernetes/apps/<namespace>/<app-name>/
├── app/
│   ├── helmrelease.yaml       # Helm release definition
│   └── kustomization.yaml
└── ks.yaml                    # Flux Kustomization (references ./app)
```

### Managing Secrets

**Creating SOPS-encrypted secrets**:
```bash
# Create secret file
kubectl create secret generic my-secret \
  --from-literal=key=value \
  --dry-run=client -o yaml > secret.yaml

# Encrypt with SOPS
sops --encrypt --in-place secret.yaml
mv secret.yaml secret.sops.yaml

# Commit encrypted file
git add secret.sops.yaml
git commit -m "feat: add my-secret"
```

**Using 1Password secrets**:
- Define `ExternalSecret` CRD pointing to 1Password Connect
- Reference in pod via normal `secretRef`
- See [kubernetes/apps/default/secret-printer/](kubernetes/apps/default/secret-printer/) for example

### Updating Talos Configuration

```bash
# 1. Edit talconfig.yaml or patches
# 2. Regenerate configs
task talos:generate-config

# 3. Apply to nodes
talosctl apply-config --nodes ${CLUSTER_NODE_1_IP} --file talos/clusterconfig/<node>.yaml

# 4. Commit changes
git add talos/
git commit -m "feat(talos): update configuration"
```

### Upgrading the Cluster

**Talos/Kubernetes versions**:
```bash
# 1. Update versions in talenv.yaml
# 2. Regenerate configs
task talos:generate-config

# 3. Apply upgrades (one node at a time)
talosctl upgrade --nodes ${CLUSTER_NODE_1_IP} --image ghcr.io/siderolabs/installer:v1.11.3

# 4. Upgrade Kubernetes
talosctl upgrade-k8s --nodes ${CLUSTER_VIP} --to 1.34.1
```

**Application updates**: Renovate handles automated PRs for Helm charts, Docker images, and GitHub Actions.

---

## Development Environment

### Required Tools (via mise)

Install mise and run:
```bash
mise install
```

**Core tools**:
- kubectl, helm, flux, talosctl
- sops, age, kustomize
- cilium-cli, kubeconform
- talhelper, makejinja
- cloudflared, yq, jq

### Kubeconfig Access

```bash
# Generate kubeconfig
talosctl kubeconfig --nodes ${CLUSTER_VIP}

# Verify access
kubectl get nodes
```

---

## Security Review Guidelines

When reviewing configurations or making changes, verify:

### 1. Secret Exposure
- [ ] No plain text secrets in YAML files
- [ ] All sensitive values use SOPS encryption or external-secrets
- [ ] Variable substitution used for private domains/emails
- [ ] No credentials in ConfigMaps
- [ ] No API keys or tokens in code

### 2. Network Policies
- [ ] Ingress controllers use appropriate IngressClass
- [ ] External services use `external` IngressClass
- [ ] Internal services use `internal` IngressClass
- [ ] No unnecessary public exposure

### 3. RBAC & Permissions
- [ ] ServiceAccounts follow least-privilege principle
- [ ] No cluster-admin unless absolutely necessary
- [ ] Namespace isolation respected

### 4. Container Security
- [ ] Images use specific tags (not `latest`)
- [ ] Non-root users where possible
- [ ] Resource limits defined
- [ ] Security contexts configured

### 5. TLS/Certificates
- [ ] All external services use HTTPS
- [ ] cert-manager issues valid certificates
- [ ] TLS 1.2+ only
- [ ] HSTS headers enabled

---

## Troubleshooting

### Check Cluster Health

```bash
# Talos health
talosctl health --nodes ${CLUSTER_VIP}

# Kubernetes nodes
kubectl get nodes

# Flux reconciliation
flux get all

# Cilium status
cilium status

# Pod status across all namespaces
kubectl get pods -A
```

### Common Issues

**Flux stuck reconciling**:
```bash
flux suspend kustomization <name>
flux resume kustomization <name>
```

**Certificate issues**:
```bash
kubectl get certificates -A
kubectl describe certificate <name> -n <namespace>
kubectl get certificaterequests -A
```

**Ingress not working**:
```bash
# Check LoadBalancer IPs assigned
kubectl get svc -n network

# Check Cilium L2 announcements
cilium status

# Verify Ingress resources
kubectl get ingress -A
```

**SOPS decryption failures**:
- Ensure `age.key` exists and is readable
- Verify `.sops.yaml` rules match file patterns
- Check Flux has access to `sops-age` secret

---

## Important Notes for AI Agents

### When Creating New Files
1. **Always** check if similar files exist in the repository
2. **Follow** existing patterns and conventions (Kustomize, Helm, etc.)
3. **Never** create files with secrets in plain text
4. **Use** SOPS encryption or external-secrets for sensitive data
5. **Reference** existing examples before creating new structures

### When Modifying Configurations
1. **Read** the entire file before editing
2. **Preserve** formatting and indentation
3. **Maintain** consistency with existing patterns
4. **Test** with `kubeconform` or `kustomize build` before committing
5. **Update** relevant Kustomization files if adding new resources

### When Debugging Issues
1. **Check** Flux reconciliation status first
2. **Review** recent commits for related changes
3. **Inspect** pod logs and events
4. **Verify** secrets are properly decrypted
5. **Consult** existing documentation (README.md, .claude/CLUSTER_CONTEXT.md)

### Best Practices
- **Commit frequently** with clear, conventional commit messages
- **Test locally** with `kustomize build` or `helm template` when possible
- **Use** Task automation instead of manual kubectl commands
- **Document** non-obvious decisions in comments or markdown
- **Ask** the user if uncertain about secret handling or architecture changes

---

## Additional Resources

- **Main README**: [README.md](README.md) - Comprehensive setup guide
- **Cluster Context**: `.claude/CLUSTER_CONTEXT.md` - Detailed AI assistant context
- **Talos Patches**: [talos/patches/README.md](talos/patches/README.md) - Patch documentation
- **Flux Documentation**: https://fluxcd.io/docs/
- **Talos Documentation**: https://www.talos.dev/
- **Cilium Documentation**: https://docs.cilium.io/

---

## Questions to Ask Before Making Changes

1. **Does this change require encryption?** If so, use SOPS or external-secrets
2. **Is this service internal or external?** Use correct IngressClass
3. **What namespace should this go in?** Follow existing namespace organization
4. **Does this need persistent storage?** Consider volume provisioning strategy
5. **Will this be publicly accessible?** Ensure proper security measures
6. **Is this change reversible?** Consider backup or rollback strategy
7. **Does this align with cluster goals?** Consult with user if unsure

---

**Remember**: When in doubt, ask the user. It's better to clarify than to compromise security or cluster stability.
