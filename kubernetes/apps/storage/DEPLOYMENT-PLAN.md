# Storage Deployment Plan

## Overview

This document outlines the deployment plan for Longhorn persistent storage and CSI-driver-NFS external storage in the `storage` namespace.

## Components Being Deployed

### 1. Longhorn v1.8.1
- **Purpose**: Distributed block storage for Kubernetes
- **Storage Class**: `longhorn` (default)
- **Replica Count**: 3
- **Storage Path**: `/var/mnt/longhorn-data` (900GB per node)
- **Data Locality**: best-effort
- **Features**: Snapshot support enabled, fast replica rebuild
- **UI**: Internal only at `https://longhorn.${SECRET_DOMAIN}`

### 2. CSI-driver-NFS
- **Purpose**: External NFS storage provisioner
- **Storage Class**: `nfs-slow`
- **NFS Server**: `atlantis.local`
- **NFS Share**: `/volume2/kubes`
- **Mount Options**: NFSv4.1, nconnect=16, hard, noatime
- **Access Mode**: ReadWriteMany

## Prerequisites

### Required Tools

The following tools must be installed before deployment:

1. **kubectl** - ✅ Already installed
   - Used for: Validation, deployment monitoring, testing

2. **flux** (optional) - For manual reconciliation
   - Used for: `task reconcile` or `flux reconcile ks storage`

### Infrastructure Prerequisites

1. **Talos Nodes**: Each node must have:
   - `longhorn-data` userVolume configured (✅ Already configured in talconfig.yaml)
   - ~900GB available space on each node
   - Mount path: `/var/mnt/longhorn-data` (✅ Already mounted with rshared propagation)

2. **NFS Server**:
   - Server `atlantis.local` must be accessible from the cluster
   - Share `/volume2/kubes` must exist and have proper permissions
   - NFSv4.1 must be enabled

3. **Gateway**:
   - `envoy-internal` Gateway must be deployed in `network` namespace (✅ Already deployed)
   - Used for Longhorn UI HTTPRoute

## Deployment Steps

### Phase 1: Pre-Deployment Validation

```bash
# 1. Verify kustomization builds correctly
kubectl kustomize kubernetes/apps/storage/ > /dev/null
echo "✅ Storage kustomization valid"

kubectl kustomize kubernetes/apps/storage/longhorn/app/ > /dev/null
echo "✅ Longhorn kustomization valid"

kubectl kustomize kubernetes/apps/storage/csi-driver-nfs/app/ > /dev/null
echo "✅ CSI-driver-nfs kustomization valid"

# 2. Check NFS connectivity (from a test pod)
kubectl run -it --rm nfs-test --image=busybox --restart=Never -- sh -c "
  apk add nfs-utils && \
  mount -t nfs -o vers=4.1 atlantis.local:/volume2/kubes /mnt && \
  echo 'NFS mount successful!' && \
  umount /mnt
"

# 3. Verify Gateway exists
kubectl get gateway -n network envoy-internal
```

### Phase 2: Git Commit (Local Only)

```bash
# Stage all changes
git add kubernetes/apps/storage/
git add TODO.md

# Commit changes
git commit -m "$(cat <<'EOF'
feat(storage): add Longhorn and NFS persistent storage

Deploy Longhorn v1.8.1 for distributed block storage and CSI-driver-NFS
for external NFS storage access.

Components deployed:
- Longhorn v1.8.1
  - 3 replicas for high availability
  - 900GB storage per node at /var/mnt/longhorn-data
  - Uses existing Talos userVolumes (already mounted with rshared propagation)
  - Default storage class for PVCs
  - Best-effort data locality
  - Snapshot support enabled
  - Internal UI at longhorn.${SECRET_DOMAIN}
- CSI-driver-NFS
  - Storage class: nfs-slow
  - NFS server: atlantis.local:/volume2/kubes
  - NFSv4.1 with optimized mount options
  - ReadWriteMany access mode

Namespace: storage
Storage Classes: longhorn (default), nfs-slow
Test manifests: kubernetes/apps/storage/tests/

Related TODO updates:
- Marked External Secrets and 1Password as completed
- Added Longhorn snapshots to future enhancements
EOF
)"

# Verify commit (DO NOT PUSH YET)
git log -1 --stat
git status
```

### Phase 3: Deployment

**Option A: Push to Git and let Flux reconcile (Recommended)**

```bash
# ⚠️ ONLY after manual testing is successful
git push origin main

# Watch Flux reconciliation
watch flux get kustomizations -A

# Or force immediate reconciliation
flux reconcile source git flux-system
flux reconcile kustomization cluster-apps --with-source
```

**Option B: Manual kubectl apply (for testing only)**

```bash
# ⚠️ This violates GitOps principles - only for validation
kubectl apply -k kubernetes/apps/storage/

# Watch deployment
kubectl get pods -n storage -w
```

### Phase 4: Deployment Monitoring

```bash
# 1. Watch Flux Kustomizations
kubectl get kustomizations -n flux-system -w

# 2. Watch HelmReleases
kubectl get helmreleases -n storage -w

# 3. Watch pod rollout
kubectl get pods -n storage -w

# Expected pods:
# - longhorn-manager (DaemonSet - 3 pods, one per node)
# - longhorn-driver-deployer
# - longhorn-ui
# - csi-nfs-controller
# - csi-nfs-node (DaemonSet - 3 pods, one per node)

# 4. Check for errors
kubectl get events -n storage --sort-by='.metadata.creationTimestamp'

# 5. Check Longhorn manager logs
kubectl logs -n storage -l app=longhorn-manager -f

# 6. Check CSI NFS logs
kubectl logs -n storage -l app=csi-nfs-controller -f
```

### Phase 5: Post-Deployment Validation

```bash
# 1. Verify storage classes
kubectl get storageclass

# Expected output:
# NAME                PROVISIONER              RECLAIMPOLICY   VOLUMEBINDINGMODE
# longhorn (default)  driver.longhorn.io       Delete          Immediate
# nfs-slow            nfs.csi.k8s.io           Delete          Immediate

# 2. Verify Longhorn nodes
kubectl get nodes.longhorn.io -n storage

# Expected: All 3 nodes should be Ready and Schedulable

# 3. Check HTTPRoute for Longhorn UI
kubectl get httproute -n storage longhorn-ui

# 4. Access Longhorn UI
# Navigate to: https://longhorn.${SECRET_DOMAIN}
# Should show dashboard with 3 nodes, 0 volumes

# 5. Verify CSI drivers
kubectl get csidrivers
# Should show: driver.longhorn.io and nfs.csi.k8s.io

# 6. Run comprehensive tests (see Phase 6)
```

### Phase 6: Comprehensive Testing

#### Test 1: Longhorn Storage

```bash
# Apply test PVC and pod
kubectl apply -f kubernetes/apps/storage/tests/test-pvc-longhorn.yaml

# Wait for PVC to be bound
kubectl get pvc -n storage test-longhorn-pvc -w

# Verify PVC is bound and PV is created
kubectl get pvc -n storage test-longhorn-pvc
kubectl get pv | grep test-longhorn

# Check pod logs
kubectl logs -n storage test-longhorn-pod

# Expected output:
# Testing Longhorn volume...
# Longhorn test data - <timestamp>
# Volume test successful!

# Verify in Longhorn UI
# Should see 1 volume with 3 replicas

# Cleanup
kubectl delete -f kubernetes/apps/storage/tests/test-pvc-longhorn.yaml
```

#### Test 2: NFS Storage

```bash
# Apply test PVC and pod
kubectl apply -f kubernetes/apps/storage/tests/test-pvc-nfs.yaml

# Wait for PVC to be bound
kubectl get pvc -n storage test-nfs-pvc -w

# Verify PVC is bound and PV is created
kubectl get pvc -n storage test-nfs-pvc
kubectl get pv | grep test-nfs

# Check pod logs
kubectl logs -n storage test-nfs-pod

# Expected output:
# Testing NFS volume...
# NFS test data - <timestamp>
# Volume test successful!

# Verify on NFS server
# SSH to atlantis.local and check /volume2/kubes
# Should see a directory created by the CSI driver

# Cleanup
kubectl delete -f kubernetes/apps/storage/tests/test-pvc-nfs.yaml
```

#### Test 3: Default Storage Class

```bash
# Create PVC without specifying storageClassName
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-default-pvc
  namespace: storage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# Verify it uses Longhorn
kubectl get pvc -n storage test-default-pvc -o jsonpath='{.spec.storageClassName}'
# Expected output: longhorn

# Cleanup
kubectl delete pvc -n storage test-default-pvc
```

#### Test 4: Multi-Replica Validation

```bash
# Create a PVC and verify replica distribution
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-replicas-pvc
  namespace: storage
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn
  resources:
    requests:
      storage: 5Gi
EOF

# Wait for PVC to be bound
kubectl wait --for=condition=Bound pvc/test-replicas-pvc -n storage --timeout=60s

# Get the volume name
VOLUME_NAME=$(kubectl get pvc -n storage test-replicas-pvc -o jsonpath='{.spec.volumeName}')

# Check replicas in Longhorn UI or via API
kubectl get volumes.longhorn.io -n storage $VOLUME_NAME -o yaml | grep -A 10 replicas

# Should show 3 replicas across different nodes

# Cleanup
kubectl delete pvc -n storage test-replicas-pvc
```

## Rollback Plan

If deployment fails or issues are discovered:

### Rollback Kubernetes Resources

```bash
# Remove storage namespace (will delete all PVCs and data!)
kubectl delete namespace storage

# Or selectively remove components
kubectl delete -k kubernetes/apps/storage/longhorn/app/
kubectl delete -k kubernetes/apps/storage/csi-driver-nfs/app/
```

### Rollback Git Changes

```bash
# If not pushed yet
git reset --hard HEAD~1

# If already pushed
git revert HEAD
git push origin main
```

## Troubleshooting

### Longhorn Issues

**Symptom**: Longhorn manager pods not starting

```bash
# Check manager logs
kubectl logs -n storage -l app=longhorn-manager --tail=100

# Common issues:
# 1. Mount path not available - verify with: talosctl -n <node-ip> ls /var/mnt/longhorn-data
# 2. Insufficient permissions - check pod security policy
# 3. Missing kernel modules - verify Talos image includes required modules
```

**Symptom**: Longhorn nodes showing as "Down"

```bash
# Check node status
kubectl describe nodes.longhorn.io -n storage

# Verify mount propagation
kubectl get pods -n storage -l app=longhorn-manager -o yaml | grep -A 5 mountPropagation

# Should show: mountPropagation: Bidirectional
```

**Symptom**: PVC stuck in Pending

```bash
# Check PVC events
kubectl describe pvc <pvc-name> -n storage

# Check if nodes are schedulable
kubectl get nodes.longhorn.io -n storage -o wide

# Verify storage class exists
kubectl get storageclass longhorn
```

### NFS Issues

**Symptom**: NFS PVC stuck in Pending

```bash
# Check CSI driver logs
kubectl logs -n storage -l app=csi-nfs-controller --tail=100

# Test NFS connectivity
kubectl run -it --rm nfs-test --image=busybox --restart=Never -- sh -c "
  apk add nfs-utils && \
  mount -t nfs -o vers=4.1 atlantis.local:/volume2/kubes /mnt
"

# Common issues:
# 1. NFS server not accessible - check network/firewall
# 2. Share doesn't exist - verify on NFS server
# 3. Permission denied - check NFS export permissions
```

**Symptom**: CSI driver not starting

```bash
# Check node driver pods
kubectl get pods -n storage -l app=csi-nfs-node -o wide

# Check controller logs
kubectl logs -n storage -l app=csi-nfs-controller -f

# Verify storage class
kubectl get storageclass nfs-slow -o yaml
```

### General Issues

**Symptom**: Flux not reconciling storage namespace

```bash
# Check Flux kustomization
kubectl describe kustomization -n flux-system cluster-apps

# Force reconciliation
flux reconcile source git flux-system
flux reconcile kustomization cluster-apps --with-source

# Check for Flux errors
flux logs -A --level=error
```

## Success Criteria

Deployment is successful when:

- [ ] Longhorn HelmRelease is Ready
- [ ] CSI-driver-NFS HelmRelease is Ready
- [ ] All Longhorn manager pods are Running (3 pods)
- [ ] All CSI NFS node pods are Running (3 pods)
- [ ] Storage classes exist: `longhorn` (default) and `nfs-slow`
- [ ] All Longhorn nodes are Ready and Schedulable
- [ ] Longhorn UI is accessible at `https://longhorn.${SECRET_DOMAIN}`
- [ ] Test Longhorn PVC can be created, bound, and used
- [ ] Test NFS PVC can be created, bound, and used
- [ ] PVCs without storageClassName use Longhorn by default
- [ ] Longhorn volumes show 3 replicas distributed across nodes

## Post-Deployment Tasks

After successful deployment:

1. **Update TODO.md**: Mark Longhorn and NFS items as completed
   ```bash
   # Already done in this deployment
   ```

2. **Monitor for 24 hours**: Watch for any stability issues
   ```bash
   kubectl get pods -n storage -w
   kubectl top nodes
   ```

3. **Create application PVCs**: Start migrating applications to use Longhorn
   - Update application deployments to use persistent storage
   - Create PVCs with `storageClassName: longhorn`

4. **Document for team**: Share Longhorn UI access and storage class usage

5. **Plan for snapshots**: Schedule recurring snapshots (future enhancement)

6. **Plan for backups**: Configure S3/NFS backup target (future enhancement)

## Files Created/Modified

### New Files Created:
```
kubernetes/apps/storage/
├── namespace.yaml
├── kustomization.yaml
├── longhorn/
│   ├── ks.yaml
│   └── app/
│       ├── kustomization.yaml
│       ├── helmrelease.yaml
│       ├── ocirepository.yaml
│       └── httproute.yaml
├── csi-driver-nfs/
│   ├── ks.yaml
│   └── app/
│       ├── kustomization.yaml
│       ├── helmrelease.yaml
│       └── ocirepository.yaml
└── tests/
    ├── README.md
    ├── test-pvc-longhorn.yaml
    └── test-pvc-nfs.yaml
```

### Modified Files:
```
TODO.md (marked ESO/1PC complete, added snapshots to future enhancements)
```

## Notes

- **DO NOT PUSH to upstream until all testing is complete**
- All commits remain local for review
- Talos userVolumes are already mounted with proper rshared propagation - no Talos changes needed
- Longhorn will automatically discover and use all 3 nodes
- NFS storage class is supplementary - use for ReadWriteMany or external access
- Longhorn is now the default storage class for all new PVCs
- Remember to clean up test PVCs after validation

## Next Steps

After successful deployment:

1. Deploy applications that need persistent storage
2. Configure recurring snapshots (future enhancement)
3. Set up backup targets for Longhorn (future enhancement)
4. Monitor storage usage and performance
5. Consider adding monitoring/alerting for Longhorn metrics
