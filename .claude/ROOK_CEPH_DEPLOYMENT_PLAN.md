# Rook-Ceph Storage Deployment Plan (Option 1)

**Date**: 2025-10-18
**Objective**: Remove Talos userVolumes, reclaim partition space, and deploy functional Rook-Ceph distributed storage

---

## Pre-Deployment Assessment

### Current State
- ✅ 3-node Kubernetes cluster operational
- ✅ No existing PVCs (safe to modify storage)
- ❌ Ceph cluster health: WARN (0 OSDs running)
- ❌ Storage pool exists but inactive (ceph-blockpool)
- ⚠️ Partition 5 (nvme0n1p5) formatted with XFS, mounted at `/var/mnt/secondary` (~900GB per node)
- ⚠️ Rook cannot use formatted/mounted partitions

### Risk Assessment
- **Risk Level**: MEDIUM
- **Data Loss**: No user data at risk (no PVCs exist)
- **Cluster Availability**: Core services remain operational throughout
- **Recovery Time**: ~30-60 minutes total
- **Rollback**: Possible by reverting Talos config changes

---

## Deployment Strategy

**Approach**: Rolling update without full cluster reprovisioning

**Key Decision**: We will **NOT** bootstrap from scratch. Instead:
1. Update Talos config to remove userVolumes
2. Apply config changes to nodes one at a time
3. Manually wipe partition 5 on each node
4. Update and redeploy Rook-Ceph to use freed space

**Advantages**:
- No cluster downtime
- Preserves existing cluster state
- Faster than full bootstrap
- Less risky

---

## Detailed Step-by-Step Plan

### Phase 1: Preparation & Backup (10 minutes)

#### Step 1.1: Document Current State
```bash
# Save current Talos config
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops
cp talos/talconfig.yaml talos/talconfig.yaml.backup-$(date +%Y%m%d)

# Save current Rook-Ceph config
cp kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml \
   kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml.backup-$(date +%Y%m%d)

# Document current cluster state
kubectl get nodes -o wide > /tmp/cluster-state-nodes.txt
kubectl -n rook-ceph get pods > /tmp/cluster-state-rook-pods.txt
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status > /tmp/ceph-status-before.txt 2>&1
```

#### Step 1.2: Verify No Critical Workloads
```bash
# Check for any PVCs (should be none)
kubectl get pvc -A

# Check for any pods using local storage
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.spec.volumes[*].hostPath.path}{"\n"}{end}' | grep secondary
```

**Expected Result**: No PVCs, no pods using `/var/mnt/secondary`

---

### Phase 2: Update Talos Configuration (5 minutes)

#### Step 2.1: Modify Talos Config File

Edit `talos/talconfig.yaml` and **remove** the `userVolumes` section from all three nodes.

**Before** (lines ~91-97 for each node):
```yaml
    userVolumes:
      - name: secondary
        provisioning:
          diskSelector:
            match: "system_disk"
          minSize: 500GiB
```

**After**: Delete the entire `userVolumes` section

Do this for all three nodes:
- `asgard-mpc-01` (lines 91-97)
- `asgard-mpc-02` (lines 125-131)
- `asgard-mpc-03` (lines 159-165)

#### Step 2.2: Regenerate Talos Configs
```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops
task talos:generate-config
```

**Expected Output**: New Talos configs generated in `talos/clusterconfig/`

#### Step 2.3: Commit Configuration Changes
```bash
git add talos/talconfig.yaml
git commit -m "chore(talos): remove userVolumes to enable Rook-Ceph storage"
# Do NOT push yet - we'll push after validation
```

---

### Phase 3: Apply Talos Config & Wipe Partitions (30 minutes)

**IMPORTANT**: Do this **one node at a time** to maintain cluster quorum.

#### Step 3.1: Node 1 - asgard-mpc-01 (10.0.13.24)

**3.1.1: Apply Talos Configuration**
```bash
# Apply the updated config (this will NOT reboot the node)
task talos:apply-node IP=10.0.13.24 MODE=no-reboot

# Verify config applied
talosctl get machineconfig -n 10.0.13.24
```

**3.1.2: Unmount and Wipe Partition 5**
```bash
# Check current mount
talosctl -n 10.0.13.24 ls /var/mnt/secondary

# Unmount the partition (if mounted - may fail if already unmounted)
talosctl -n 10.0.13.24 unmount /var/mnt/secondary 2>/dev/null || echo "Not mounted or already unmounted"

# Wipe partition 5 filesystem signature
talosctl -n 10.0.13.24 wipe /dev/nvme0n1p5

# Verify partition is now empty
talosctl -n 10.0.13.24 get disks
```

**Expected Result**: Partition 5 exists but has no filesystem

**3.1.3: Soft Reboot Node** (Optional but recommended)
```bash
# Graceful reboot to ensure clean state
talosctl -n 10.0.13.24 reboot

# Wait for node to come back online (2-3 minutes)
kubectl wait --for=condition=Ready node/asgard-mpc-01 --timeout=5m

# Verify node is healthy
kubectl get node asgard-mpc-01
```

#### Step 3.2: Node 2 - asgard-mpc-02 (10.0.13.25)

Repeat the same process:
```bash
# Apply config
task talos:apply-node IP=10.0.13.25 MODE=no-reboot

# Unmount and wipe
talosctl -n 10.0.13.25 unmount /var/mnt/secondary 2>/dev/null || true
talosctl -n 10.0.13.25 wipe /dev/nvme0n1p5

# Reboot
talosctl -n 10.0.13.25 reboot
kubectl wait --for=condition=Ready node/asgard-mpc-02 --timeout=5m
```

#### Step 3.3: Node 3 - asgard-mpc-03 (10.0.13.26)

Repeat the same process:
```bash
# Apply config
task talos:apply-node IP=10.0.13.26 MODE=no-reboot

# Unmount and wipe
talosctl -n 10.0.13.26 unmount /var/mnt/secondary 2>/dev/null || true
talosctl -n 10.0.13.26 wipe /dev/nvme0n1p5

# Reboot
talosctl -n 10.0.13.26 reboot
kubectl wait --for=condition=Ready node/asgard-mpc-03 --timeout=5m
```

#### Step 3.4: Verify All Nodes
```bash
# Check all nodes are Ready
kubectl get nodes

# Verify partition 5 is clean on all nodes
for node in 10.0.13.24 10.0.13.25 10.0.13.26; do
  echo "=== Node $node ==="
  talosctl -n $node get disks | grep nvme0n1p5
done
```

**Expected Result**: All nodes Ready, partition 5 exists but no filesystem/mountpoint

---

### Phase 4: Update Rook-Ceph Configuration (5 minutes)

#### Step 4.1: Review Current Rook-Ceph Config

The current config specifies:
```yaml
storage:
  useAllNodes: false
  useAllDevices: false
  nodes:
    - name: asgard-mpc-01
      devices:
        - name: /dev/disk/by-id/nvme-KINGSTON_OM8PGP41024N-A0_50026B7383A064AE-part5
```

**Problem**: This references part5, which we're keeping but wiping for Ceph to use.

#### Step 4.2: Modify Rook-Ceph Cluster Config

We have **two approaches**:

**Approach A: Keep Using Partition 5** (Simpler)
- Partition 5 still exists, just wiped clean
- Rook can now use it since it has no filesystem
- Minimal config changes

**Approach B: Let Rook Use Entire Remaining Space** (Cleaner)
- Change to `useAllDevices: true` with filters
- Rook automatically discovers available space
- More flexible

**RECOMMENDED: Approach A** (Keep using part5)

No changes needed to the Rook config! The existing config already targets part5. Once we wipe it, Rook will be able to use it.

#### Step 4.3: Alternative - If Approach A Doesn't Work

If Rook still can't find part5 after wiping, we'll switch to using the raw device:

Edit `kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml`:

```yaml
storage:
  useAllNodes: false
  useAllDevices: false
  config:
    osdsPerDevice: "1"
  nodes:
    - name: asgard-mpc-01
      devices:
        - name: /dev/nvme0n1p5  # Keep as-is, or change to /dev/nvme0n1 if issues
    - name: asgard-mpc-02
      devices:
        - name: /dev/nvme0n1p5
    - name: asgard-mpc-03
      devices:
        - name: /dev/nvme0n1p5
```

**For now, we'll keep the config as-is and see if Rook picks up the wiped partition.**

---

### Phase 5: Redeploy Rook-Ceph Cluster (10 minutes)

#### Step 5.1: Delete Existing Ceph Cluster (Preserve Operator)

```bash
# Delete the CephCluster resource (this will clean up OSDs, mons, etc.)
kubectl -n rook-ceph delete cephcluster rook-ceph --wait=false

# Wait for cluster to be fully removed (may take 2-3 minutes)
kubectl -n rook-ceph get pods -w

# You should see monitors, managers, OSDs being terminated
# Keep watching until only these remain: operator, tools, discover pods
```

**Expected State After Deletion**:
- rook-ceph-operator: Running
- rook-ceph-tools: Running
- rook-discover-*: Running (3 pods)
- All mon, mgr, osd pods: Terminated/Gone

#### Step 5.2: Clean Up Rook State on Nodes (Critical!)

```bash
# This removes any leftover Rook state that might prevent OSD creation
for node in 10.0.13.24 10.0.13.25 10.0.13.26; do
  echo "=== Cleaning Rook state on $node ==="

  # Remove dataDirHostPath contents
  talosctl -n $node ls /var/lib/rook
  talosctl -n $node rm /var/lib/rook/rook-ceph || true
  talosctl -n $node rm /var/lib/rook/mon-* || true
  talosctl -n $node rm /var/lib/rook/osd-* || true
done
```

#### Step 5.3: Reconcile Rook-Ceph via Flux

```bash
# Force Flux to reconcile the Rook-Ceph cluster HelmRelease
flux reconcile helmrelease -n rook-ceph rook-ceph-cluster --with-source

# Watch the deployment
kubectl -n rook-ceph get pods -w
```

**Expected Sequence**:
1. Monitors start (rook-ceph-mon-a, -b, -c) - ~2 minutes
2. Managers start (rook-ceph-mgr-a, -b) - ~1 minute
3. **OSD prepare jobs run** (rook-ceph-osd-prepare-*) - ~2 minutes
4. **OSD pods start** (rook-ceph-osd-0-*, -1-*, -2-*) - ~3 minutes

#### Step 5.4: Monitor OSD Deployment

```bash
# Watch OSD prepare jobs
kubectl -n rook-ceph get jobs -l app=rook-ceph-osd-prepare -w

# Check OSD prepare logs for errors
kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=50

# Once OSD pods appear, check their status
kubectl -n rook-ceph get pods -l app=rook-ceph-osd
```

**Success Indicators**:
- OSD prepare jobs complete successfully
- 3 OSD pods running (1 per node)
- No CrashLoopBackOff errors

---

### Phase 6: Verify Ceph Cluster Health (5 minutes)

#### Step 6.1: Check Ceph Status

```bash
# Wait for Ceph to stabilize (may take 2-3 minutes)
sleep 180

# Check Ceph cluster status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# Check OSD tree
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# Check pool status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd pool ls detail
```

**Expected Output**:
```
cluster:
  health: HEALTH_OK

services:
  mon: 3 daemons, quorum a,b,c
  mgr: a(active), standbys: b
  osd: 3 osds: 3 up, 3 in

data:
  pools:   1 pools, X pgs
  objects: 0 objects, 0 B
  usage:   X GiB used, X TiB / X TiB avail
  pgs:     X active+clean
```

#### Step 6.2: Verify Storage Class

```bash
# Check StorageClass exists and is default
kubectl get storageclass

# Should show:
# NAME                  PROVISIONER                     RECLAIMPOLICY   VOLUMEBINDINGMODE   ALLOWVOLUMEEXPANSION   AGE
# ceph-block (default)  rook-ceph.rbd.csi.ceph.com     Delete          Immediate           true                   Xm
```

---

### Phase 7: Test Storage Provisioning (5 minutes)

#### Step 7.1: Create Test PVC

```bash
# Create test PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-ceph-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ceph-block
EOF
```

#### Step 7.2: Verify PVC Binding

```bash
# Check PVC status (should be Bound within 30 seconds)
kubectl get pvc test-ceph-pvc -w

# Check PV created
kubectl get pv

# Verify in Ceph
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd ls ceph-blockpool
```

**Expected Result**: PVC bound, PV created, RBD image visible in Ceph

#### Step 7.3: Test with Pod

```bash
# Create test pod using the PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: test-ceph-pod
  namespace: default
spec:
  containers:
  - name: test
    image: nginx:alpine
    volumeMounts:
    - name: test-volume
      mountPath: /data
  volumes:
  - name: test-volume
    persistentVolumeClaim:
      claimName: test-ceph-pvc
EOF

# Wait for pod to be Running
kubectl wait --for=condition=Ready pod/test-ceph-pod --timeout=2m

# Write test data
kubectl exec test-ceph-pod -- sh -c "echo 'Ceph storage works!' > /data/test.txt"

# Read test data
kubectl exec test-ceph-pod -- cat /data/test.txt
```

**Expected Output**: "Ceph storage works!"

#### Step 7.4: Cleanup Test Resources

```bash
# Delete test resources
kubectl delete pod test-ceph-pod
kubectl delete pvc test-ceph-pvc

# Verify PV is deleted (ReclaimPolicy: Delete)
kubectl get pv
```

---

### Phase 8: Finalize and Document (5 minutes)

#### Step 8.1: Commit All Changes

```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops

# Add any Rook config changes (if we modified anything)
git add kubernetes/apps/rook-ceph/

# Commit
git commit -m "fix(storage): deploy functional Rook-Ceph with cleaned partitions

- Removed Talos userVolumes to free partition 5
- Wiped partition 5 on all nodes to remove XFS filesystem
- Redeployed Rook-Ceph cluster with 3 OSDs (1 per node)
- Verified storage provisioning with test PVC
- Ceph cluster health: HEALTH_OK

Fixes #<issue-number-if-applicable>

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>"

# Push to GitHub
git push
```

#### Step 8.2: Update Cluster Context Documentation

Update `.claude/CLUSTER_CONTEXT.md` to reflect the storage changes:
- Remove references to `secondary` userVolume
- Document Rook-Ceph OSD configuration using part5
- Update storage capacity numbers

#### Step 8.3: Take Final Snapshots

```bash
# Document final state
kubectl get nodes -o wide > /tmp/cluster-state-nodes-after.txt
kubectl -n rook-ceph get pods > /tmp/cluster-state-rook-pods-after.txt
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status > /tmp/ceph-status-after.txt
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree > /tmp/ceph-osd-tree.txt
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph df > /tmp/ceph-df.txt
```

---

## Troubleshooting Guide

### Issue: OSDs Still Not Creating After Wipe

**Symptom**: OSD prepare jobs fail or complete but no OSDs start

**Diagnosis**:
```bash
kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=100
kubectl -n rook-ceph logs deploy/rook-ceph-operator --tail=100 | grep -i osd
```

**Solution**:
1. Check if partition 5 still has filesystem signature:
   ```bash
   talosctl -n 10.0.13.24 read /dev/nvme0n1p5 | head -c 4096
   ```
2. If still formatted, wipe again more aggressively:
   ```bash
   talosctl -n 10.0.13.24 wipe /dev/nvme0n1p5
   # Or use dd to zero out the first few MB:
   talosctl -n 10.0.13.24 exec -- dd if=/dev/zero of=/dev/nvme0n1p5 bs=1M count=10
   ```

### Issue: Partition 5 Doesn't Exist After Config Change

**Symptom**: After applying Talos config, partition 5 is gone

**Solution**: This is actually expected if Talos removes the partition. In this case:
1. Update Rook config to use `useAllDevices: true` or point to `/dev/nvme0n1` directly
2. Rook will create its own partitions

### Issue: Ceph Health WARN After Deployment

**Symptom**: `ceph status` shows HEALTH_WARN

**Diagnosis**:
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health detail
```

**Common Warnings**:
- "clock skew detected" → Check NTP on nodes
- "pgs not scrubbed" → Normal for new cluster, will resolve
- "too few PGs" → Ceph will auto-scale PGs, wait 5-10 minutes

### Issue: PVC Stuck in Pending

**Symptom**: Test PVC never binds

**Diagnosis**:
```bash
kubectl describe pvc test-ceph-pvc
kubectl -n rook-ceph logs -l app=csi-rbdplugin
```

**Solution**:
1. Check CSI pods are running:
   ```bash
   kubectl -n rook-ceph get pods -l app=csi-rbdplugin
   ```
2. Verify StorageClass exists and has correct provisioner
3. Check Ceph cluster is HEALTH_OK

---

## Rollback Plan

If something goes catastrophically wrong:

### Rollback Step 1: Restore Talos Config
```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops
git checkout talos/talconfig.yaml
task talos:generate-config

# Apply to all nodes
for ip in 10.0.13.24 10.0.13.25 10.0.13.26; do
  task talos:apply-node IP=$ip MODE=no-reboot
done
```

### Rollback Step 2: Reboot Nodes
```bash
for ip in 10.0.13.24 10.0.13.25 10.0.13.26; do
  talosctl -n $ip reboot
done

# Wait for all nodes to be Ready
kubectl wait --for=condition=Ready nodes --all --timeout=10m
```

### Rollback Step 3: Restore Secondary Mount
The secondary partition will be recreated and remounted by Talos.

---

## Summary

**Total Time**: ~60 minutes
**Downtime**: None (rolling updates)
**Risk Level**: Medium (no user data at risk)
**Outcome**: Functional Rook-Ceph cluster with 3 OSDs, ~900GB usable storage per node

**Key Success Metrics**:
- ✅ 3 OSD pods running (1 per node)
- ✅ Ceph status: HEALTH_OK
- ✅ Test PVC successfully provisions and binds
- ✅ Test pod can read/write to Ceph storage
- ✅ StorageClass `ceph-block` is default

**Next Steps After Deployment**:
1. Deploy observability stack (Prometheus/Grafana) to monitor Ceph
2. Set up Ceph dashboard access via ingress
3. Deploy production applications using Ceph storage
4. Configure backup solutions for Ceph data

---

**Questions Before Proceeding?**
- Are you comfortable with the rolling node update approach?
- Do you want to keep partition 5 or let Rook manage the entire disk?
- Any specific concerns about the timeline or steps?
