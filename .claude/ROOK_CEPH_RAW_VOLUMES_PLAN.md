# Rook-Ceph Deployment with Raw Volumes - Execution Plan

**Date**: 2025-10-18
**Strategy**: Remove userVolumes, add rawVolumes, deploy Rook-Ceph
**Timeline**: ~45 minutes
**Risk Level**: LOW (no user data, no reinstallation needed)

---

## Legend

Throughout this plan:
- 🤖 **Claude will run** - Commands executed automatically by the AI assistant
- 👤 **You will run** - Commands you need to execute manually
- 📋 **Verify** - Validation steps to confirm success
- ⚠️ **Important** - Critical notes to pay attention to

---

## Pre-Flight Checklist

Before we begin, let's verify the current state:

### 👤 You run:
```bash
# Check current node status
kubectl get nodes

# Check current partition layout on one node
talosctl -n 10.0.13.24 get volumestatus

# Verify no PVCs exist
kubectl get pvc -A

# Check current Ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
```

### 📋 Expected Results:
- ✅ All 3 nodes: Ready
- ✅ VolumeStatus shows `u-secondary` volume mounted at `/var/mnt/secondary`
- ✅ No PVCs found
- ✅ Ceph shows: `osd: 0 osds: 0 up, 0 in` (broken, as expected)

---

## Phase 1: Backup Current Configuration (5 minutes)

### 🤖 Claude will run:
```bash
# Create backups with timestamp
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops

cp talos/talconfig.yaml talos/talconfig.yaml.backup-$(date +%Y%m%d-%H%M%S)
cp kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml \
   kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml.backup-$(date +%Y%m%d-%H%M%S)

# Save current state
kubectl get nodes -o wide > /tmp/cluster-nodes-before.txt
kubectl -n rook-ceph get pods > /tmp/rook-pods-before.txt
```

### 📋 Verify:
- ✅ Backup files created in `talos/` directory
- ✅ State files saved in `/tmp/`

---

## Phase 2: Remove UserVolumes from Talos Config (5 minutes)

### 🤖 Claude will run:

**Step 2.1**: Edit `talos/talconfig.yaml` to remove the `userVolumes` section from all three nodes.

**Lines to remove** (for each node):
```yaml
# REMOVE THESE LINES:
    userVolumes:
      - name: secondary
        provisioning:
          diskSelector:
            match: "system_disk"
          minSize: 500GiB
          # maxSize not specified = uses remaining available space
```

This appears in three locations:
- Node `asgard-mpc-01`: Lines ~91-97
- Node `asgard-mpc-02`: Lines ~125-131
- Node `asgard-mpc-03`: Lines ~159-165

**Step 2.2**: Regenerate Talos configuration files
```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops
task talos:generate-config
```

**Step 2.3**: Commit the changes (but don't push yet)
```bash
git add talos/talconfig.yaml
git commit -m "chore(talos): remove userVolumes in preparation for rawVolumes

- Remove userVolumes configuration from all nodes
- Prepares for migration to raw volumes for Rook-Ceph
- Part of storage infrastructure refactoring

Related: Storage deployment plan"
```

### 📋 Verify:
- ✅ `userVolumes` section removed from all 3 node configs
- ✅ New configs generated in `talos/clusterconfig/`
- ✅ Changes committed to git (but not pushed)

---

## Phase 3: Apply Config to Unmount UserVolumes (15 minutes)

⚠️ **IMPORTANT**: We'll do this one node at a time to maintain cluster stability.

### Node 1: asgard-mpc-01 (10.0.13.24)

#### 👤 You run:
```bash
# Apply the config WITHOUT rebooting
talosctl -n 10.0.13.24 apply-config \
  --file ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops/talos/clusterconfig/kubernetes-asgard-mpc-01.yaml \
  --mode=no-reboot

# Wait 30 seconds for changes to take effect
sleep 30

# Check volume status
talosctl -n 10.0.13.24 get volumestatus
```

#### 📋 Expected Result:
- ✅ `u-secondary` volume should show as removed or unmounted
- ✅ Node should still be Running and healthy

#### 👤 You run:
```bash
# Verify partition still exists but is unmounted
talosctl -n 10.0.13.24 disks

# Check node is still Ready
kubectl get node asgard-mpc-01
```

#### 📋 Expected Result:
- ✅ Partition `nvme0n1p5` still exists (900GB)
- ✅ No longer mounted at `/var/mnt/secondary`
- ✅ Node status: Ready

---

### Node 2: asgard-mpc-02 (10.0.13.25)

#### 👤 You run:
```bash
# Apply the config WITHOUT rebooting
talosctl -n 10.0.13.25 apply-config \
  --file ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops/talos/clusterconfig/kubernetes-asgard-mpc-02.yaml \
  --mode=no-reboot

# Wait 30 seconds
sleep 30

# Check volume status
talosctl -n 10.0.13.25 get volumestatus

# Verify node health
kubectl get node asgard-mpc-02
```

#### 📋 Expected Result:
- ✅ `u-secondary` volume removed/unmounted
- ✅ Node status: Ready

---

### Node 3: asgard-mpc-03 (10.0.13.26)

#### 👤 You run:
```bash
# Apply the config WITHOUT rebooting
talosctl -n 10.0.13.26 apply-config \
  --file ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops/talos/clusterconfig/kubernetes-asgard-mpc-03.yaml \
  --mode=no-reboot

# Wait 30 seconds
sleep 30

# Check volume status
talosctl -n 10.0.13.26 get volumestatus

# Verify node health
kubectl get node asgard-mpc-03
```

#### 📋 Expected Result:
- ✅ `u-secondary` volume removed/unmounted
- ✅ Node status: Ready

---

### 🤖 Claude will verify:
```bash
# Verify all nodes are healthy
kubectl get nodes

# Check that cluster is stable
kubectl get pods -A | grep -v Running | grep -v Completed
```

#### 📋 Expected Result:
- ✅ All 3 nodes: Ready
- ✅ All system pods: Running

---

## Phase 4: Wipe Old Partitions (10 minutes)

⚠️ **CRITICAL**: This step **permanently deletes** the partition and frees the space. Make sure you don't need any data on `/var/mnt/secondary`!

### Node 1: asgard-mpc-01 (10.0.13.24)

#### 👤 You run:
```bash
# Wipe partition 5 and DROP the partition entirely
talosctl -n 10.0.13.24 wipe disk nvme0n1p5 --drop-partition

# Verify partition is gone
talosctl -n 10.0.13.24 disks
```

#### 📋 Expected Result:
- ✅ Partition `nvme0n1p5` is **deleted**
- ✅ ~900GB of free space available
- ✅ Only partitions 1-4 remain (EFI, META, STATE, EPHEMERAL)

---

### Node 2: asgard-mpc-02 (10.0.13.25)

#### 👤 You run:
```bash
# Wipe partition 5 and DROP the partition entirely
talosctl -n 10.0.13.25 wipe disk nvme0n1p5 --drop-partition

# Verify partition is gone
talosctl -n 10.0.13.25 disks
```

#### 📋 Expected Result:
- ✅ Partition `nvme0n1p5` deleted
- ✅ ~900GB free space

---

### Node 3: asgard-mpc-03 (10.0.13.26)

#### 👤 You run:
```bash
# Wipe partition 5 and DROP the partition entirely
talosctl -n 10.0.13.26 wipe disk nvme0n1p5 --drop-partition

# Verify partition is gone
talosctl -n 10.0.13.26 disks
```

#### 📋 Expected Result:
- ✅ Partition `nvme0n1p5` deleted
- ✅ ~900GB free space

---

### 🤖 Claude will verify:
```bash
# All nodes should still be healthy
kubectl get nodes
```

#### 📋 Expected Result:
- ✅ All 3 nodes: Ready (no impact from partition deletion)

---

## Phase 5: Add Raw Volumes to Talos Config (5 minutes)

### 🤖 Claude will run:

**Step 5.1**: Edit `talos/talconfig.yaml` to **add** the `rawVolumes` section to all three nodes.

**Add after the `volumes` section** (for each node):
```yaml
    rawVolumes:
      - name: ceph
        provisioning:
          diskSelector:
            match: "system_disk"
          minSize: 500GiB
```

Add this for:
- Node `asgard-mpc-01` (after line ~90)
- Node `asgard-mpc-02` (after line ~124)
- Node `asgard-mpc-03` (after line ~158)

**Step 5.2**: Regenerate Talos configuration files
```bash
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops
task talos:generate-config
```

**Step 5.3**: Commit the changes (still not pushing)
```bash
git add talos/talconfig.yaml
git commit -m "feat(talos): add rawVolumes for Rook-Ceph storage

- Add raw volume 'ceph' (500GB+) on all nodes
- Raw volumes are unformatted for CSI driver use
- Device path: /dev/disk/by-partlabel/r-ceph

Related: Storage deployment plan"
```

### 📋 Verify:
- ✅ `rawVolumes` section added to all 3 node configs
- ✅ New configs generated in `talos/clusterconfig/`
- ✅ Changes committed to git

---

## Phase 6: Apply Config to Create Raw Volumes (15 minutes)

⚠️ **NOTE**: Talos will now create new partition(s) for the raw volumes.

### Node 1: asgard-mpc-01 (10.0.13.24)

#### 👤 You run:
```bash
# Apply the config to create raw volumes
talosctl -n 10.0.13.24 apply-config \
  --file ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops/talos/clusterconfig/kubernetes-asgard-mpc-01.yaml \
  --mode=no-reboot

# Wait for volume to be provisioned (30 seconds)
sleep 30

# Check volume status - should show r-ceph
talosctl -n 10.0.13.24 get volumestatus
```

#### 📋 Expected Result:
```
NAMESPACE   TYPE           ID      VERSION   PHASE   LOCATION                          PARTITION LABEL
...
block       VolumeStatus   r-ceph  1         ready   /dev/disk/by-partlabel/r-ceph    r-ceph
```

#### 👤 You run:
```bash
# Verify the partition exists and is RAW (no filesystem)
talosctl -n 10.0.13.24 disks

# Check the symlink exists
talosctl -n 10.0.13.24 ls /dev/disk/by-partlabel/ | grep r-ceph

# Verify node health
kubectl get node asgard-mpc-01
```

#### 📋 Expected Result:
- ✅ New partition created (likely `nvme0n1p5` again, but now unformatted)
- ✅ Symlink `/dev/disk/by-partlabel/r-ceph` exists
- ✅ No filesystem on the partition (raw block device)
- ✅ Node status: Ready

---

### Node 2: asgard-mpc-02 (10.0.13.25)

#### 👤 You run:
```bash
# Apply the config
talosctl -n 10.0.13.25 apply-config \
  --file ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops/talos/clusterconfig/kubernetes-asgard-mpc-02.yaml \
  --mode=no-reboot

# Wait and verify
sleep 30
talosctl -n 10.0.13.25 get volumestatus
talosctl -n 10.0.13.25 ls /dev/disk/by-partlabel/ | grep r-ceph
kubectl get node asgard-mpc-02
```

#### 📋 Expected Result:
- ✅ VolumeStatus shows `r-ceph` in ready phase
- ✅ Symlink exists
- ✅ Node: Ready

---

### Node 3: asgard-mpc-03 (10.0.13.26)

#### 👤 You run:
```bash
# Apply the config
talosctl -n 10.0.13.26 apply-config \
  --file ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops/talos/clusterconfig/kubernetes-asgard-mpc-03.yaml \
  --mode=no-reboot

# Wait and verify
sleep 30
talosctl -n 10.0.13.26 get volumestatus
talosctl -n 10.0.13.26 ls /dev/disk/by-partlabel/ | grep r-ceph
kubectl get node asgard-mpc-03
```

#### 📋 Expected Result:
- ✅ VolumeStatus shows `r-ceph` in ready phase
- ✅ Symlink exists
- ✅ Node: Ready

---

### 🤖 Claude will verify:
```bash
# Verify all nodes healthy
kubectl get nodes

# Check cluster stability
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

#### 📋 Expected Result:
- ✅ All 3 nodes: Ready
- ✅ No pods in error state

---

## Phase 7: Update Rook-Ceph Configuration (5 minutes)

Now we need to update Rook to use the new raw volume device paths.

### 🤖 Claude will run:

**Step 7.1**: Edit `kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml`

**Find the `storage.nodes` section** (around line 88-97):

**BEFORE:**
```yaml
        nodes:
          - name: asgard-mpc-01
            devices:
              - name: /dev/disk/by-id/nvme-KINGSTON_OM8PGP41024N-A0_50026B7383A064AE-part5
          - name: asgard-mpc-02
            devices:
              - name: /dev/disk/by-id/nvme-KINGSTON_OM8PGP41024N-A0_50026B7383A073A3-part5
          - name: asgard-mpc-03
            devices:
              - name: /dev/disk/by-id/nvme-KINGSTON_OM8PGP41024N-A0_50026B7383A053D5-part5
```

**AFTER:**
```yaml
        nodes:
          - name: asgard-mpc-01
            devices:
              - name: /dev/disk/by-partlabel/r-ceph
          - name: asgard-mpc-02
            devices:
              - name: /dev/disk/by-partlabel/r-ceph
          - name: asgard-mpc-03
            devices:
              - name: /dev/disk/by-partlabel/r-ceph
```

⚠️ **Why this works**: The symlink `/dev/disk/by-partlabel/r-ceph` is the same on all nodes because they all have the same raw volume name.

**Step 7.2**: Commit the changes
```bash
git add kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml
git commit -m "feat(rook-ceph): use raw volumes for OSD storage

- Update device paths to use Talos raw volume symlinks
- Change from by-id to by-partlabel references
- Enables Rook to use unformatted block devices
- All nodes now use /dev/disk/by-partlabel/r-ceph

Related: Storage deployment plan"
```

### 📋 Verify:
- ✅ Device paths updated to `/dev/disk/by-partlabel/r-ceph`
- ✅ Changes committed

---

## Phase 8: Clean Up and Redeploy Rook-Ceph (15 minutes)

### 🤖 Claude will run:

**Step 8.1**: Delete the existing Ceph cluster (but keep the operator)
```bash
# Delete the CephCluster custom resource
kubectl -n rook-ceph delete cephcluster rook-ceph --wait=false

# Watch pods being terminated
kubectl -n rook-ceph get pods -w
```

⚠️ **Wait for**: All mon, mgr, osd pods to be terminated. Only these should remain:
- `rook-ceph-operator-*`
- `rook-ceph-tools-*`
- `rook-discover-*` (3 pods)

**Step 8.2**: Clean up Rook state on nodes

#### 👤 You run:
```bash
# Remove old Rook data directories on each node
for node in 10.0.13.24 10.0.13.25 10.0.13.26; do
  echo "=== Cleaning $node ==="
  talosctl -n $node exec -- rm -rf /var/lib/rook/rook-ceph || true
  talosctl -n $node exec -- rm -rf /var/lib/rook/mon-* || true
  talosctl -n $node exec -- rm -rf /var/lib/rook/osd-* || true
done
```

#### 📋 Expected Result:
- ✅ Old Rook data directories removed from all nodes

---

**Step 8.3**: Push all git changes

### 🤖 Claude will run:
```bash
# Push all commits to GitHub
git push origin main
```

#### 📋 Expected Result:
- ✅ All commits pushed to GitHub
- ✅ Flux will detect changes automatically

---

**Step 8.4**: Force Flux to reconcile

### 🤖 Claude will run:
```bash
# Force Flux to reconcile the Rook-Ceph cluster
flux reconcile helmrelease -n rook-ceph rook-ceph-cluster --with-source

# Watch the deployment
kubectl -n rook-ceph get pods -w
```

#### 📋 Expected Sequence:
1. **Monitors start** (rook-ceph-mon-a, -b, -c) → ~2 minutes
2. **Managers start** (rook-ceph-mgr-a, -b) → ~1 minute
3. **OSD prepare jobs run** (rook-ceph-osd-prepare-*) → ~2 minutes
4. **OSD pods start** (one per node) → ~3 minutes

⚠️ **Total wait time**: ~8-10 minutes for full cluster deployment

---

**Step 8.5**: Monitor OSD deployment

### 🤖 Claude will run:
```bash
# Check OSD prepare job status
kubectl -n rook-ceph get jobs -l app=rook-ceph-osd-prepare

# Check OSD prepare logs
kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=50

# Once OSD pods appear
kubectl -n rook-ceph get pods -l app=rook-ceph-osd
```

#### 📋 Expected Result:
- ✅ 3 OSD prepare jobs: Completed
- ✅ 3 OSD pods: Running (1 per node)
- ✅ Logs show successful OSD creation on `/dev/disk/by-partlabel/r-ceph`

---

## Phase 9: Verify Ceph Cluster Health (5 minutes)

### 🤖 Claude will run:

**Step 9.1**: Wait for Ceph to stabilize
```bash
# Wait 3 minutes for cluster to settle
sleep 180

# Check Ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status

# Check OSD tree
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree

# Check pool status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd pool ls detail
```

#### 📋 Expected Output:
```
cluster:
  id:     <cluster-id>
  health: HEALTH_OK

services:
  mon: 3 daemons, quorum a,b,c (age Xm)
  mgr: a(active, since Xm), standbys: b
  osd: 3 osds: 3 up, 3 in

data:
  pools:   1 pools, X pgs
  objects: 0 objects, 0 B
  usage:   X GiB used, ~2.7 TiB / ~2.7 TiB avail
  pgs:     X active+clean
```

⚠️ **If health is HEALTH_WARN**: Check details with:
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health detail
```

Common warnings that are OK:
- "pgs not scrubbed" → Normal for new cluster
- "clock skew detected" → Usually resolves in a few minutes

---

**Step 9.2**: Verify StorageClass

### 🤖 Claude will run:
```bash
# Check StorageClass exists and is default
kubectl get storageclass ceph-block -o yaml
```

#### 📋 Expected Result:
- ✅ StorageClass `ceph-block` exists
- ✅ Has annotation: `storageclass.kubernetes.io/is-default-class: "true"`
- ✅ Provisioner: `rook-ceph.rbd.csi.ceph.com`
- ✅ ReclaimPolicy: `Delete`
- ✅ VolumeBindingMode: `Immediate`

---

## Phase 10: Test Storage Provisioning (5 minutes)

### 🤖 Claude will run:

**Step 10.1**: Create test PVC
```bash
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

**Step 10.2**: Wait for PVC to bind
```bash
# Watch PVC status (should bind within 30 seconds)
kubectl get pvc test-ceph-pvc -w --timeout=60s

# Check PV was created
kubectl get pv

# Verify in Ceph
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- rbd ls ceph-blockpool
```

#### 📋 Expected Result:
- ✅ PVC status: Bound
- ✅ PV created automatically
- ✅ RBD image visible in Ceph pool

---

**Step 10.3**: Test with a pod

### 🤖 Claude will run:
```bash
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
kubectl exec test-ceph-pod -- sh -c "echo 'Rook-Ceph with Raw Volumes works!' > /data/test.txt"

# Read test data back
kubectl exec test-ceph-pod -- cat /data/test.txt
```

#### 📋 Expected Output:
```
Rook-Ceph with Raw Volumes works!
```

✅ **SUCCESS!** Storage is working!

---

**Step 10.4**: Clean up test resources

### 🤖 Claude will run:
```bash
# Delete test pod and PVC
kubectl delete pod test-ceph-pod
kubectl delete pvc test-ceph-pvc

# Verify PV is auto-deleted (ReclaimPolicy: Delete)
kubectl get pv
```

#### 📋 Expected Result:
- ✅ Pod deleted
- ✅ PVC deleted
- ✅ PV automatically deleted
- ✅ RBD image removed from Ceph

---

## Phase 11: Finalize and Document (5 minutes)

### 🤖 Claude will run:

**Step 11.1**: Update cluster context documentation
```bash
# Edit .claude/CLUSTER_CONTEXT.md to reflect changes
# - Update storage section to mention raw volumes
# - Remove references to userVolumes/secondary mount
# - Document device paths: /dev/disk/by-partlabel/r-ceph
# - Update storage capacity: ~900GB per node × 3 = ~2.7TB total

git add .claude/CLUSTER_CONTEXT.md
git commit -m "docs: update cluster context for raw volumes storage

- Document raw volumes implementation for Rook-Ceph
- Remove userVolumes references
- Add device path documentation
- Update storage capacity information"

git push
```

**Step 11.2**: Save final state snapshots
```bash
# Document final state
kubectl get nodes -o wide > /tmp/cluster-nodes-after.txt
kubectl -n rook-ceph get pods > /tmp/rook-pods-after.txt
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status > /tmp/ceph-status-after.txt
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree > /tmp/ceph-osd-tree-after.txt
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph df > /tmp/ceph-df-after.txt
kubectl get storageclass > /tmp/storageclasses-after.txt
```

### 📋 Verify:
- ✅ Documentation updated and committed
- ✅ State snapshots saved

---

## Success Criteria ✅

After completing all phases, verify:

- ✅ **Talos Configuration**
  - [ ] UserVolumes removed from all nodes
  - [ ] Raw volumes added to all nodes
  - [ ] Raw volume symlinks exist: `/dev/disk/by-partlabel/r-ceph`

- ✅ **Cluster Health**
  - [ ] All 3 nodes: Ready
  - [ ] All system pods: Running
  - [ ] No unexpected errors in cluster

- ✅ **Ceph Cluster**
  - [ ] Ceph status: `HEALTH_OK`
  - [ ] 3 monitor daemons running
  - [ ] 3 OSD pods running (1 per node)
  - [ ] OSDs: `3 up, 3 in`
  - [ ] Storage pool active with PGs in `active+clean` state

- ✅ **Storage Provisioning**
  - [ ] StorageClass `ceph-block` exists and is default
  - [ ] Test PVC successfully provisioned and bound
  - [ ] Test pod can write/read data to Ceph volume
  - [ ] PVC/PV cleanup working (ReclaimPolicy: Delete)

- ✅ **Git Repository**
  - [ ] All configuration changes committed
  - [ ] Changes pushed to GitHub
  - [ ] Flux reconciled successfully

---

## Troubleshooting Guide

### Issue: Raw Volume Not Provisioned After Config Apply

**Symptom**: `talosctl get volumestatus` doesn't show `r-ceph`

**Diagnosis**:
```bash
# Check Talos logs
talosctl -n <node-ip> dmesg | grep -i partition
talosctl -n <node-ip> logs controller-runtime
```

**Solutions**:
1. Verify partition was actually deleted: `talosctl -n <node-ip> disks`
2. Check if there's enough free space (need ~500GB)
3. Try rebooting the node: `talosctl -n <node-ip> reboot`

---

### Issue: OSD Prepare Jobs Fail

**Symptom**: OSD prepare jobs complete but OSDs don't start

**Diagnosis**:
```bash
kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=100
```

**Solutions**:
1. Check if raw volumes are truly unformatted:
   ```bash
   talosctl -n <node-ip> read /dev/disk/by-partlabel/r-ceph | head -c 4096
   ```
   Should show random/zero data, not filesystem signatures

2. Verify Rook can access the device:
   ```bash
   kubectl -n rook-ceph logs deploy/rook-ceph-operator | grep -i osd
   ```

3. If device has old signatures, wipe and recreate:
   ```bash
   talosctl -n <node-ip> wipe disk nvme0n1p5 --drop-partition
   # Then reapply the raw volume config
   ```

---

### Issue: Ceph Health WARN

**Symptom**: `ceph status` shows `HEALTH_WARN`

**Diagnosis**:
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health detail
```

**Common Warnings & Fixes**:

1. **"clock skew detected"**
   - Usually resolves automatically
   - If persists, check NTP on nodes:
     ```bash
     talosctl -n <node-ip> time
     ```

2. **"pgs not scrubbed in time"**
   - Normal for new cluster
   - Will resolve after first scrub cycle (~24 hours)

3. **"too few PGs per OSD"**
   - Ceph auto-scales PGs
   - Wait 5-10 minutes for autoscaler

---

### Issue: PVC Stuck in Pending

**Symptom**: Test PVC never binds

**Diagnosis**:
```bash
kubectl describe pvc test-ceph-pvc
kubectl -n rook-ceph logs -l app=csi-rbdplugin --tail=50
```

**Solutions**:
1. Verify Ceph cluster is HEALTH_OK
2. Check CSI pods are running:
   ```bash
   kubectl -n rook-ceph get pods -l app=csi-rbdplugin
   ```
3. Verify StorageClass exists:
   ```bash
   kubectl get storageclass ceph-block
   ```

---

## Rollback Procedure

If something goes catastrophically wrong, here's how to rollback:

### 🤖 Claude will run:
```bash
# Restore Talos config
cd ~/Library/Mobile\ Documents/com~apple~CloudDocs/Documents/1\ Projects/Git/home-ops
git checkout HEAD~3 talos/talconfig.yaml  # Go back 3 commits
task talos:generate-config
```

### 👤 You run:
```bash
# Apply old config to all nodes
for node in 10.0.13.24 10.0.13.25 10.0.13.26; do
  talosctl -n $node apply-config \
    --file talos/clusterconfig/kubernetes-asgard-mpc-0*.yaml \
    --mode=reboot
done

# Wait for nodes to reboot
kubectl wait --for=condition=Ready nodes --all --timeout=10m
```

This will restore the userVolumes configuration.

---

## Timeline Summary

| Phase | Duration | Description |
|-------|----------|-------------|
| Pre-flight | 2 min | Verify current state |
| Phase 1 | 2 min | Backup configurations |
| Phase 2 | 3 min | Remove userVolumes from config |
| Phase 3 | 15 min | Apply config to unmount volumes |
| Phase 4 | 10 min | Wipe old partitions |
| Phase 5 | 3 min | Add raw volumes to config |
| Phase 6 | 15 min | Apply config to create raw volumes |
| Phase 7 | 3 min | Update Rook configuration |
| Phase 8 | 15 min | Redeploy Rook-Ceph cluster |
| Phase 9 | 5 min | Verify Ceph health |
| Phase 10 | 5 min | Test storage provisioning |
| Phase 11 | 3 min | Finalize and document |
| **TOTAL** | **~80 min** | **Complete deployment** |

⚠️ **Note**: Timeline includes wait times. Active work is ~30 minutes.

---

## Post-Deployment Next Steps

Once storage is working:

1. ✅ **Monitor Ceph Health**
   - Check dashboard: `rook.${CLUSTER_DOMAIN}`
   - Watch for any warnings in first 24 hours

2. ✅ **Deploy Observability**
   - Prometheus/Grafana for Ceph metrics
   - Set up alerting for storage issues

3. ✅ **Deploy Applications**
   - Start using `ceph-block` StorageClass
   - Deploy stateful workloads

4. ✅ **Configure Backups**
   - Consider Velero or similar for PVC backups
   - Ceph snapshot configuration

---

## Questions?

Before we start execution, do you have any questions about:
- Any specific phase?
- Commands you need to run?
- Expected behaviors?
- Troubleshooting steps?

**Ready to begin?** Let me know and we'll start with Phase 1!
