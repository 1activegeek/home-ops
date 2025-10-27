# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a GitOps-based Kubernetes cluster template for home lab deployments. The cluster runs on **Talos Linux** (v1.11.3) with **Kubernetes** (v1.34.1) managed by **Flux CD** (v2.7.2). All secrets are encrypted with **SOPS + age** encryption.

**Core Stack:**
- **OS:** Talos Linux (immutable, API-managed container OS)
- **GitOps:** Flux CD (declarative cluster management)
- **CNI:** Cilium (container networking)
- **Ingress:** Envoy Gateway (API gateway with internal/external gateways)
- **DNS:** k8s_gateway (internal), external-dns (Cloudflare)
- **Certificates:** cert-manager
- **Tunneling:** Cloudflare Tunnel (cloudflared)
- **Secrets:** SOPS + age encryption
- **Other:** Spegel (image mirroring), Reloader (config reloading)

## Core Development Principles

**CRITICAL: These principles must be followed at all times when working in this repository.**

### 1. Never Commit Unencrypted Secrets

**All secrets, passwords, API tokens, certificates, and any sensitive data MUST be encrypted with SOPS before committing to Git.**

- ❌ **NEVER** commit plaintext secrets, even temporarily
- ❌ **NEVER** commit files containing passwords, API keys, or confidential information without encryption
- ✅ **ALWAYS** use SOPS to encrypt secrets (files with `.sops.yaml` suffix)
- ✅ **ALWAYS** verify encryption before `git push`:
  ```bash
  # Check that all .sops.yaml files are encrypted (should show 'sops' metadata)
  grep -r "sops:" kubernetes/**/*.sops.yaml talos/**/*.sops.yaml
  ```

**Exception:** For application secrets, use External Secrets Operator with 1Password (deployed in `security` namespace). SOPS is still required for bootstrap secrets (1Password credentials, Flux tokens, etc.) that External Secrets depends on.

### 2. GitOps-Only Changes (No Direct kubectl apply)

**This is a GitOps cluster - all configuration changes MUST go through Git and Flux.**

- ❌ **NEVER** use `kubectl apply`, `kubectl create`, `kubectl edit`, or `kubectl patch` to make permanent changes
- ❌ **NEVER** modify resources directly in the cluster (except for troubleshooting)
- ✅ **ALWAYS** commit changes to Git and let Flux reconcile them
- ✅ **ALLOWED** for troubleshooting only: `kubectl get`, `kubectl describe`, `kubectl logs`, `kubectl port-forward`

**Why?** Direct kubectl changes will be reverted by Flux on the next reconciliation. All permanent changes must be declarative and tracked in Git.

**Workflow:**
```bash
# 1. Make changes to YAML files in kubernetes/ directory
# 2. Commit and push to Git
git add .
git commit -m "feat: add new application"
git push

# 3. Force Flux to sync (optional, otherwise waits for poll interval)
task reconcile

# 4. Watch rollout
kubectl get pods -A -w
```

### 3. Validate Before Committing

**Always run flux-local validation before committing to catch configuration errors early.**

```bash
# Run flux-local to validate all Kustomizations and HelmReleases
# This catches issues before they reach the cluster
flux-local diff

# Or use the GitHub Actions workflow locally (if configured)
```

**This prevents:**
- Invalid YAML syntax
- Missing secret references
- Broken Kustomization paths
- HelmRelease configuration errors
- Dependency issues

**Note:** The GitHub Actions workflow (`.github/workflows/flux-local.yaml`) also runs this validation automatically on PRs.

### 4. Use creator repo for inspriation

When being asked to add new apps or resources, check if the creator repo has a similar deployment.
- **SHOULD** be used for some simple sane defaults
- **SHOULD NOT** be taken as verbatim option to deploy
- Can answer some basic questions about structure
- Great way to find other resources for helm charts


## Architecture

### Directory Structure

```
.
├── bootstrap/          # Initial bootstrap files (SOPS age keys)
├── kubernetes/
│   ├── apps/          # Applications organized by namespace
│   │   ├── cert-manager/
│   │   ├── default/
│   │   ├── flux-system/
│   │   ├── kube-system/
│   │   └── network/
│   ├── components/    # Shared components (SOPS integration)
│   └── flux/          # Flux configuration
├── talos/
│   ├── clusterconfig/ # Generated Talos machine configs
│   ├── patches/       # Node-specific patches
│   ├── talconfig.yaml # Main Talos cluster config
│   └── talenv.yaml    # Version specifications
├── scripts/           # Bootstrap automation scripts
└── .taskfiles/        # Task automation definitions
```

### Kubernetes App Structure

Applications follow a standard Flux structure:
```
kubernetes/apps/<namespace>/<app-name>/
├── ks.yaml                    # Flux Kustomization (entrypoint)
└── app/
    ├── helmrelease.yaml       # Helm chart deployment
    ├── ocirepository.yaml     # OCI chart source
    ├── secret.sops.yaml       # Encrypted secrets (optional)
    └── kustomization.yaml     # Kustomize manifest
```

**Key Conventions:**
- `ks.yaml` files define Flux Kustomizations that reference the `app/` subdirectory
- Secrets use the `.sops.yaml` suffix and are encrypted with SOPS
- OCI repositories are preferred over traditional Helm repos
- Each namespace has its own `namespace.yaml` and root `kustomization.yaml`

### Flux Reconciliation Flow

1. Flux monitors the Git repository for changes
2. Changes to `kubernetes/flux/` trigger cluster-level reconciliation
3. Changes to `kubernetes/apps/` trigger namespace-level reconciliation
4. Flux applies changes via Kustomizations (`ks.yaml`) and HelmReleases
5. SOPS integration automatically decrypts secrets during reconciliation

## Development Environment

### Setup

**Tool Management:** Uses [mise](https://mise.jdx.dev/) for reproducible tooling.

```bash
# Trust the mise configuration
mise trust

# Install Python dependencies (required for makejinja)
pip install pipx

# Install all tools defined in .mise.toml
mise install
```

**Environment Variables:**
- `KUBECONFIG`: Points to `./kubeconfig` (auto-set by mise)
- `SOPS_AGE_KEY_FILE`: Points to `./age.key` (auto-set by mise)
- `TALOSCONFIG`: Points to `./talos/clusterconfig/talosconfig` (auto-set by mise)

### Common Commands

**Task Runner:** All operations use [Task](https://taskfile.dev/) (see [Taskfile.yaml](Taskfile.yaml))

```bash
# List all available tasks
task

# Force Flux to sync from Git
task reconcile

# Bootstrap Talos cluster
task bootstrap:talos

# Bootstrap applications (Cilium, CoreDNS, Spegel, Flux)
task bootstrap:apps

# Generate Talos configuration
task talos:generate-config

# Apply Talos config to a node
task talos:apply-node IP=<node-ip> MODE=auto

# Upgrade Talos on a node
task talos:upgrade-node IP=<node-ip>

# Upgrade Kubernetes version
task talos:upgrade-k8s

# Reset cluster (WARNING: destructive)
task talos:reset
```

**Direct Kubectl/Flux Commands:**
```bash
# Watch all pods
kubectl get pods --all-namespaces --watch

# Check Flux status
flux check
flux get sources git flux-system
flux get ks -A          # Kustomizations
flux get hr -A          # HelmReleases

# Check Cilium status
cilium status

# Describe certificates
kubectl -n kube-system describe certificates
```

## Secret Management

### Primary Method: External Secrets + 1Password (Preferred for Application Secrets)

**For all new application secrets, use External Secrets Operator with 1Password.**

**Architecture:**
- **1Password Connect Server:** Deployed in `security` namespace, provides API access to 1Password vaults
- **External Secrets Operator (ESO):** Syncs secrets from 1Password to Kubernetes Secrets
- **ClusterSecretStore:** Cluster-wide access to 1Password vaults

**Adding Application Secrets:**

1. **Store secret in 1Password vault:**
   - Use 1Password app or CLI to create items
   - Recommended vault: `kubernetes` (or app-specific vaults)

2. **Create an ExternalSecret resource:**
   ```yaml
   apiVersion: external-secrets.io/v1
   kind: ExternalSecret
   metadata:
     name: my-app-secret
     namespace: default
   spec:
     refreshInterval: 1h
     secretStoreRef:
       kind: ClusterSecretStore
       name: onepassword-store
     target:
       name: my-app-secret
       creationPolicy: Owner
     data:
       - secretKey: username
         remoteRef:
           key: my-app-credentials  # 1Password item name
           property: username        # Field name in 1Password
       - secretKey: password
         remoteRef:
           key: my-app-credentials
           property: password
   ```

3. **Reference the secret in your application:**
   ```yaml
   envFrom:
     - secretRef:
         name: my-app-secret
   ```

**Checking ExternalSecret Status:**
```bash
# Check if ExternalSecret is syncing
kubectl get externalsecret -A
kubectl describe externalsecret <name> -n <namespace>

# Verify the Kubernetes Secret was created
kubectl get secret <secret-name> -n <namespace>
```

### Legacy Method: SOPS (Required for Bootstrap Secrets Only)

**SOPS Configuration:** See [.sops.yaml](.sops.yaml)

**SOPS is ONLY used for:**
- 1Password Connect Server credentials (`security/onepassword-connect/app/secret.sops.yaml`)
- Flux GitHub tokens
- Talos machine secrets
- Any secrets that External Secrets Operator depends on (bootstrap secrets)

**Encryption Rules:**
- `talos/*.sops.yaml`: Fully encrypted with MAC
- `kubernetes/*.sops.yaml`: Only `data` and `stringData` fields encrypted
- Age public key: `age1azd5x9cmhpaqn8ww60q7yqwc6dhlw3z66cz7mjwmnkfqdqf0lytskc8asw`

**Working with SOPS Secrets (Bootstrap Only):**
```bash
# Edit encrypted secret (auto-decrypts/encrypts)
sops kubernetes/apps/security/onepassword-connect/app/secret.sops.yaml

# Encrypt a new bootstrap secret
kubectl create secret generic my-secret \
  --from-literal=key=value \
  --dry-run=client -o yaml | \
  sops --filename-override kubernetes/apps/default/my-app/app/secret.sops.yaml \
  --encrypt /dev/stdin > kubernetes/apps/default/my-app/app/secret.sops.yaml

# Verify secrets are encrypted before committing
grep -r "sops:" kubernetes/**/*.sops.yaml talos/**/*.sops.yaml
```

**Important:** Never commit unencrypted secrets. Always verify `*.sops.yaml` files are encrypted before pushing.

### When to Use Which Method

| Use Case | Method | Reason |
|----------|--------|--------|
| Application database credentials | External Secrets + 1Password | Centralized secret rotation, easier management |
| API keys for services | External Secrets + 1Password | Can be rotated in 1Password without GitOps changes |
| OAuth tokens | External Secrets + 1Password | Automatic sync from 1Password |
| 1Password Connect credentials | SOPS | Bootstrap dependency - ESO needs this to function |
| Flux GitHub tokens | SOPS | Bootstrap dependency - Flux needs this to pull repo |
| Talos machine secrets | SOPS | Infrastructure bootstrap secrets |

## Debugging Workflows

### Flux Not Syncing

1. Check Flux status:
   ```bash
   flux check
   flux get sources git -A
   flux get ks -A
   flux get hr -A
   ```

2. Force reconciliation:
   ```bash
   task reconcile
   # Or manually:
   flux reconcile source git flux-system
   flux reconcile kustomization flux-system --with-source
   ```

3. Check Kustomization/HelmRelease for errors:
   ```bash
   flux get ks -A
   kubectl -n <namespace> describe kustomization <name>
   kubectl -n <namespace> describe helmrelease <name>
   ```

### Pod Issues

1. Check pod status:
   ```bash
   kubectl -n <namespace> get pods -o wide
   ```

2. Check pod logs:
   ```bash
   kubectl -n <namespace> logs <pod-name> -f
   kubectl -n <namespace> logs <pod-name> --previous  # Previous container
   ```

3. Describe the pod:
   ```bash
   kubectl -n <namespace> describe pod <pod-name>
   ```

4. Check namespace events:
   ```bash
   kubectl -n <namespace> get events --sort-by='.metadata.creationTimestamp'
   ```

### Network/Ingress Issues

1. Check Cilium connectivity:
   ```bash
   cilium status
   cilium connectivity test  # WARNING: creates test resources
   ```

2. Check Envoy Gateway status:
   ```bash
   kubectl -n network get gateway -A
   kubectl -n network get httproute -A
   kubectl -n network describe gateway envoy-internal
   kubectl -n network describe gateway envoy-external
   ```

3. Test DNS resolution:
   ```bash
   # Replace variables with actual values from cluster.yaml
   dig @<cluster_dns_gateway_addr> echo.<cloudflare_domain>
   ```

4. Check external connectivity:
   ```bash
   # Replace variables with actual values
   nmap -Pn -n -p 443 <cluster_gateway_addr> <cloudflare_gateway_addr> -vv
   ```

### Certificate Issues

```bash
# Check certificate status
kubectl -n kube-system get certificates
kubectl -n kube-system describe certificate <cert-name>

# Check cert-manager logs
kubectl -n cert-manager logs -l app=cert-manager -f

# Check ClusterIssuer
kubectl describe clusterissuer letsencrypt-production
```

## Talos-Specific Considerations

**Talos is an immutable OS** - all configuration changes must be applied via the API:

1. Modify `talos/talconfig.yaml` or patches in `talos/patches/`
2. Regenerate config: `task talos:generate-config`
3. Apply to node(s): `task talos:apply-node IP=<node-ip>`

**Never SSH into Talos nodes** - use `talosctl` instead:
```bash
# Get node status
talosctl -n <node-ip> get members

# Check node logs
talosctl -n <node-ip> logs

# Run a command in a container (emergency only)
talosctl -n <node-ip> containers
```

## Gateway Configuration

**Two Envoy Gateways:**
- `envoy-internal`: Private network access (use for internal apps)
- `envoy-external`: Public internet access via Cloudflare Tunnel

**HTTPRoute Example:**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
spec:
  parentRefs:
    - name: envoy-internal  # or envoy-external for public
      namespace: network
  hostnames:
    - my-app.example.com
  rules:
    - backendRefs:
        - name: my-app
          port: 80
```

## Important Notes

- **Renovate:** Automated dependency updates run weekly (Sundays 4am UTC). Check the Dependency Dashboard issue for pending updates.
- **Flux Local Testing:** GitHub Actions run `flux-local` to validate manifests before merge.
- **Image Caching:** Spegel provides distributed image caching across nodes.
- **Config Reloading:** Reloader automatically restarts pods when ConfigMaps/Secrets change.
- **Wildcard Certificate:** A wildcard cert is auto-provisioned by cert-manager for the configured domain.

## Version Management

Update versions in these files:
- **Talos/Kubernetes versions:** [talos/talenv.yaml](talos/talenv.yaml)
- **Tool versions:** [.mise.toml](.mise.toml)
- **Flux components:** Renovate handles automatically via [.renovaterc.json5](.renovaterc.json5)
