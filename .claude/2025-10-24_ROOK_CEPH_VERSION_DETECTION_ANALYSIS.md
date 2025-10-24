# Rook-Ceph Version Detection Issue - Deep Analysis
**Date**: 2025-10-24
**Status**: Investigating - Stuck at "Detecting Ceph version"
**Duration**: 30+ minutes (abnormal - should complete in 1-2 minutes)

---

## Current Cluster State

### Symptom
CephCluster resource shows:
```
Phase: Progressing
Message: Detecting Ceph version
State: Creating
```

### Observations
1. **No MON/MGR/OSD pods** - Cluster never progresses past version detection
2. **Version detection jobs complete** - Jobs run and exit successfully (exit 0)
3. **ConfigMap never created** - Job completes but doesn't create result ConfigMap
4. **Operator times out** - After 3 minutes, operator reports timeout waiting for ConfigMap
5. **Infinite retry loop** - Operator keeps creating new detection jobs that fail the same way

### What's Working
- ✅ Rook operator running (v1.18.2)
- ✅ Rook tools pod operational
- ✅ Rook discovery working (found all 3 r-ceph partitions)
- ✅ Raw volumes provisioned correctly on all 3 nodes (969GB each)
- ✅ Device paths correct: `/dev/disk/by-partlabel/r-ceph`
- ✅ All other cluster pods healthy (flux, cilium, coredns, etc.)

### What's Broken
- ❌ Version detection job completes but doesn't create ConfigMap
- ❌ CSI operator mode misconfigured (enabled when should be disabled)
- ❌ CephCluster stuck in "Detecting Ceph version" for 30+ minutes

---

## Technical Analysis

### Version Detection Process (How It Should Work)

1. **Operator creates Job**: `rook-ceph-detect-version`
2. **Job runs two containers**:
   - `init-copy-binaries`: Copies Rook binaries from operator image
   - `cmd-reporter`: Runs Ceph version check and writes result to ConfigMap
3. **ConfigMap created**: `rook-ceph-detect-version` with version info
4. **Operator reads ConfigMap**: Proceeds with MON/MGR/OSD deployment

### What's Actually Happening

From events and logs:
```
Normal   SuccessfulCreate   job/rook-ceph-detect-version   Created pod: rook-ceph-detect-version-twqbf
Normal   Completed          job/rook-ceph-detect-version   Job completed
Warning  ReconcileFailed    cephcluster/rook-ceph          failed to reconcile... timed out waiting for results ConfigMap
```

**Timeline**:
- Job created and completes successfully
- No ConfigMap appears in namespace
- After 3 minutes, operator times out
- Operator deletes job and tries again
- Cycle repeats infinitely

### Root Cause Hypotheses

#### Hypothesis #1: ConfigMap Write Permission Issue (Most Likely)
**Evidence**:
- Job completes (exit 0) but ConfigMap never appears
- No error messages in job logs (would need to check)
- RBAC might be missing write permission for ConfigMap

**Why this could happen**:
- Job uses ServiceAccount that lacks ConfigMap write permissions
- In past Rook versions, this permission was sometimes missing
- Helm chart may not have created proper RBAC

**How to verify**:
```bash
kubectl -n rook-ceph get sa rook-ceph-cmd-reporter -o yaml
kubectl -n rook-ceph get role,rolebinding | grep cmd-reporter
```

#### Hypothesis #2: CSI Operator Mode Misconfiguration (Contributing Factor)
**Evidence**:
- Operator logs: "disabling csi-driver since EnableCSIOperator is true"
- HelmRelease specifies: `enableCSIOperator: false`
- But operator doesn't have env var: `ROOK_CSI_ENABLE_OPERATOR=false`

**Why this matters**:
- CSI operator mode changes how Rook initializes the cluster
- May interfere with version detection or subsequent deployment
- Helm chart v1.18.2 doesn't automatically set this env var

**Historical context** (from state file):
- Previous sessions attempted to fix this
- Added `enableCSIOperator: false` to HelmRelease
- But env var not propagated to operator pod

#### Hypothesis #3: Ceph Image Pull/Access Issue (Less Likely)
**Evidence**:
- Image specified: `quay.io/ceph/ceph:v19.2.3`
- Job containers show "Container image already present on machine"
- So image pull is working

**Why unlikely**:
- Image is cached and available
- Init container (`init-copy-binaries`) succeeds
- Only the version detection logic fails

#### Hypothesis #4: Networking/DNS Issue (Unlikely)
**Evidence**:
- Earlier in session, pods had transient API connectivity issues
- But those were resolved by pod restarts
- Version detection doesn't require external connectivity

**Why unlikely**:
- Job runs to completion
- Problem is ConfigMap creation, not networking

---

## Configuration Analysis

### Current Rook-Ceph Configuration

**Operator HelmRelease** (`kubernetes/apps/rook-ceph/rook-ceph/app/helmrelease.yaml`):
```yaml
values:
  enableCSIOperator: false  # Disable CSI operator mode
  enableDiscoveryDaemon: true
  csi:
    cephFSKernelMountOptions: ms_mode=prefer-crc
    enableCephfsDriver: false
    enableCephfsSnapshotter: false
    enableLiveness: true
    serviceMonitor:
      enabled: true
```

**Cluster HelmRelease** (`kubernetes/apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml`):
```yaml
cephClusterSpec:
  cephVersion:
    image: quay.io/ceph/ceph:v19.2.3
  storage:
    useAllNodes: false
    useAllDevices: false
    config:
      osdsPerDevice: "1"
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

**Talos Raw Volumes** (`talos/patches/global/raw-volumes.yaml`):
```yaml
apiVersion: v1alpha1
kind: RawVolumeConfig
name: ceph
provisioning:
  diskSelector:
    match: system_disk
  minSize: 500GiB
```

### Device Discovery Results

From `rook-discover` logs and ConfigMaps, all 3 nodes report:
```json
{
  "name": "nvme0n1p5",
  "size": 969260662784,
  "filesystem": "",
  "mountpoint": "",
  "empty": true,
  "devLinks": "/dev/disk/by-partlabel/r-ceph ..."
}
```

**Key observations**:
- ✅ Partition exists (nvme0n1p5)
- ✅ Size correct (~969GB)
- ✅ No filesystem (empty=true) ← CRITICAL for raw volumes
- ✅ Symlink exists: `/dev/disk/by-partlabel/r-ceph`

---

## Proposed Solution

### Phase 1: Document & Research (CURRENT)
1. ✅ Document analysis to MD file
2. ⏳ Research working implementations:
   - onedr0p/home-ops (template creator)
   - haraldkoch/kochhaus-home (similar setup)
3. ⏳ Compare configurations
4. ⏳ Identify missing pieces

### Phase 2: Clean Slate
**Rationale**: CephCluster may be in corrupted state after 30+ minutes of retries

1. Delete CephCluster resource (keeps operator, tools, discover)
2. Wait for any Ceph pods to terminate (currently none exist)
3. Clear operator reconciliation state

### Phase 3: Fix CSI Operator Mode
**Rationale**: Operator is running in wrong CSI mode despite HelmRelease setting

1. Patch `rook-ceph-operator` deployment:
   ```yaml
   env:
   - name: ROOK_CSI_ENABLE_OPERATOR
     value: "false"
   ```
2. Delete operator pod to force restart
3. Verify operator logs show correct CSI mode

### Phase 4: Verify Version Detection Job
**Rationale**: Need to see actual job logs if it fails again

1. Watch for new `rook-ceph-detect-version` job
2. Immediately check pod logs (both containers)
3. Check for ConfigMap creation
4. If fails, inspect:
   - ServiceAccount permissions
   - RBAC roles/bindings
   - Job pod events

### Phase 5: Monitor Cluster Deployment
**Expected timeline** (if version detection succeeds):
- 0-2 min: Version detected, operator proceeds
- 2-5 min: MON pods start (3x)
- 5-7 min: MGR pods start (2x)
- 7-12 min: OSD prepare jobs run (3x)
- 12-15 min: OSD pods start (3x)
- 15+ min: Cluster reaches HEALTH_OK

---

## Success Criteria

### Immediate Success (Phase 4)
- ✅ Version detection job completes
- ✅ ConfigMap `rook-ceph-detect-version` created with version data
- ✅ Operator logs: "detected ceph version: ..."
- ✅ CephCluster status changes from "Detecting" to deploying MONs

### Full Success (Phase 5)
- ✅ 3 MON pods: Running
- ✅ 2 MGR pods: Running (1 active, 1 standby)
- ✅ 3 OSD pods: Running (1 per node)
- ✅ Ceph status: `HEALTH_OK`
- ✅ OSDs: `3 up, 3 in`
- ✅ Storage pool created with replication=3
- ✅ Test PVC provisions successfully

---

## Contingency Plans

### If Version Detection Still Fails

**Option A: Manual Version Detection**
Run version detection manually to see actual error:
```bash
kubectl -n rook-ceph run manual-version-check \
  --image=quay.io/ceph/ceph:v19.2.3 \
  --restart=Never \
  -- ceph --version
```

**Option B: Check RBAC**
```bash
kubectl -n rook-ceph get serviceaccount rook-ceph-cmd-reporter
kubectl -n rook-ceph describe role rook-ceph-cmd-reporter
kubectl auth can-i create configmap --as=system:serviceaccount:rook-ceph:rook-ceph-cmd-reporter
```

**Option C: Check for Job Pod Errors**
```bash
kubectl -n rook-ceph get events --field-selector involvedObject.kind=Pod | grep detect-version
kubectl -n rook-ceph logs -l job-name=rook-ceph-detect-version --all-containers
```

### If OSDs Don't Deploy

**Check OSD Prepare Logs**:
```bash
kubectl -n rook-ceph logs -l app=rook-ceph-osd-prepare --tail=200
```

**Common issues**:
- Old Ceph signatures on partition → Wipe and recreate
- Device not accessible → Check Talos raw volume mounting
- Insufficient permissions → Check OSD pod security context

### If Cluster Won't Reach HEALTH_OK

**Check Ceph Details**:
```bash
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph status
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph health detail
kubectl -n rook-ceph exec -it deploy/rook-ceph-tools -- ceph osd tree
```

**Common warnings** (usually resolve automatically):
- Clock skew → Check NTP sync
- PGs not scrubbed → Normal for new cluster
- Too few PGs → Auto-scaler adjusts after 5-10 minutes

---

## Historical Context

### Recent Attempts (Last 5 Days)

From git history:
```
ecdfa52 feat(talos): re-enable raw volumes with clean partitions
7997d4f chore(talos): temporarily disable raw volumes to wipe old Ceph metadata
1c3897b fix(rook-ceph): correctly disable CSI operator in operator helmrelease
3e64986 fix(rook-ceph): disable CSI operator mode to resolve ClientProfile CRD issue
bdb49d9 feat(rook-ceph): re-enable deployment with validated configuration
```

**Key learnings**:
1. Raw volumes were created successfully
2. Old Ceph metadata was wiped from partitions
3. CSI operator mode was identified as an issue
4. Multiple attempts to fix CSI mode configuration
5. Clean partitions now available (no old signatures)

### What Changed Since Last Session
- Pod networking issues resolved (flux-operator, external-secrets-webhook, etc.)
- CoreDNS fixed (removed failed signature verification)
- All system pods healthy
- **But**: CephCluster still stuck at same point

**Implication**: The CSI operator mode and/or version detection RBAC are likely the remaining blockers.

---

## Reference Information

### Rook Versions
- Operator: v1.18.2
- Helm Chart: v1.18.2
- Ceph Image: v19.2.3

### Cluster Details
- Nodes: 3x control-plane (asgard-mpc-01/02/03)
- Talos: v1.11.3
- Kubernetes: v1.34.1
- Storage per node: 969GB raw partition (nvme0n1p5)
- Total capacity: ~2.7TB (with 3x replication = ~900GB usable)

### Related Documentation
- Main plan: `.claude/ROOK_CEPH_RAW_VOLUMES_PLAN.md`
- Cluster context: `.claude/CLUSTER_CONTEXT.md`
- Previous session: `.claude/2025-10-23 State.md`

---

## Research Findings - Configuration Comparison

### Critical Discovery: Wrong Helm Parameter Name!

**Problem**: Our configuration uses an invalid Helm parameter name!

**What we have**:
```yaml
values:
  enableCSIOperator: false  # ❌ This parameter doesn't exist!
```

**What it should be** (from official Rook Helm chart):
```yaml
values:
  csi:
    rookUseCsiOperator: false  # ✅ Correct parameter name
```

**Impact**:
- Helm chart doesn't recognize `enableCSIOperator`
- Falls back to default: `csi.rookUseCsiOperator: true`
- Operator runs in CSI operator mode (unintended)
- This explains why logs show "EnableCSIOperator is true"

### Comparison with Working Configurations

**From official Rook Helm chart documentation**:
- `csi.rookUseCsiOperator`: Controls CSI operator mode (default: `true`)
- `csi.disableCsiDriver`: Completely disable CSI driver (default: `"false"`)
- `csi.enableRbdDriver`: Enable RBD driver (default: `true`)
- `csi.enableCephfsDriver`: Enable CephFS driver (default: `true`)

**From Talos official documentation**:
- No mention of disabling CSI operator mode
- Talos guide uses default settings (CSI operator mode enabled)
- Raw volumes work fine with CSI operator mode
- No special configuration needed for Talos compatibility

**From Harald Koch's kochhaus-home** (working cluster):
- Uses standard device paths (not raw volumes)
- Successfully deploys with NVMe devices
- Configuration includes proper monitoring and resource limits

### Secondary Finding: CSI Operator Mode May Not Be The Issue

**New hypothesis**:
1. CSI operator mode (default in v1.18) should work fine
2. Many users successfully run Rook v1.18 with CSI operator enabled
3. Talos official docs don't disable it
4. The version detection failure might be unrelated to CSI mode

**Evidence**:
- Operator can detect version regardless of CSI mode
- Version detection happens before CSI driver deployment
- Other Talos users use default CSI operator mode successfully

### Root Cause Re-evaluation

**Primary Issue: Version Detection Job Failure**
The version detection job completes but doesn't create the ConfigMap. This is likely:

**Option A: RBAC Permission Issue**
- Job ServiceAccount lacks ConfigMap write permission
- Rook v1.18 may have changed RBAC requirements
- Helm chart might not create proper permissions

**Option B: Job Implementation Bug**
- The `cmd-reporter` container logic may be failing silently
- Exit code 0 despite not completing task
- Network/API timeout during ConfigMap creation

**Secondary Issue: Wrong CSI Configuration Parameter**
- Using invalid parameter name
- Should be corrected regardless of whether it's causing issues
- Ensures configuration matches intent

## Revised Solution Strategy

### Phase 1: Fix Configuration Errors (HIGH PRIORITY)
1. **Correct the CSI operator parameter name**:
   - Change: `enableCSIOperator: false`
   - To: `csi.rookUseCsiOperator: false`

2. **Verify Helm chart will apply the change correctly**

### Phase 2: Investigate Version Detection (MEDIUM PRIORITY)
1. **Check RBAC for version detection job**:
   ```bash
   kubectl -n rook-ceph get serviceaccount,role,rolebinding | grep -i detect
   kubectl auth can-i create configmap --as=system:serviceaccount:rook-ceph:<sa-name>
   ```

2. **Manually run version detection to see actual errors**

### Phase 3: Alternative Approach (IF NEEDED)
**Option 1**: Use default CSI operator mode (remove the disable setting entirely)
- This is what Talos guide recommends
- Many users successfully run with CSI operator enabled
- Simpler configuration

**Option 2**: Add explicit RBAC if missing
- Create Role/RoleBinding for version detection job
- Grant ConfigMap create/update permissions

## Updated Execution Plan

### Phase 1: Fix Helm Configuration (REQUIRED)

**Action**: Update rook-ceph operator HelmRelease

**File**: `kubernetes/apps/rook-ceph/rook-ceph/app/helmrelease.yaml`

**Change**:
```yaml
# BEFORE (WRONG):
values:
  enableCSIOperator: false

# AFTER (CORRECT):
values:
  csi:
    rookUseCsiOperator: false  # If we want to disable CSI operator
    # OR remove this entirely to use default (CSI operator enabled)
```

**Decision Point**: Should we disable CSI operator at all?
- **Pro**: Matches original intent, uses built-in CSI drivers
- **Con**: Goes against Rook v1.18 defaults and Talos recommendations
- **Recommendation**: Try with default (CSI operator enabled) first

### Phase 2: Clean Slate & Monitor

1. Delete stuck CephCluster
2. Apply corrected Helm configuration
3. Restart operator pod
4. Watch version detection carefully
5. Check for RBAC errors in events

### Phase 3: Troubleshoot Version Detection (IF STILL FAILS)

1. Inspect job logs immediately upon creation
2. Check ServiceAccount permissions
3. Manually test version detection command
4. Add explicit RBAC if needed

## Recommendation

**Best approach**: Remove the CSI operator override entirely and use Rook v1.18 defaults

**Rationale**:
1. CSI operator mode is the recommended configuration for v1.18
2. Talos documentation doesn't disable it
3. Version detection issue is likely unrelated to CSI mode
4. Simpler = fewer things to go wrong

**Modified config**:
```yaml
values:
  csi:
    cephFSKernelMountOptions: ms_mode=prefer-crc
    enableCephfsDriver: false
    enableCephfsSnapshotter: false
    enableLiveness: true
    serviceMonitor:
      enabled: true
  # Don't override rookUseCsiOperator - use default (true)
  enableDiscoveryDaemon: true
```

## Next Steps

**Status**: Research complete, ready for execution
- [x] Research onedr0p/home-ops configuration
- [x] Research haraldkoch/kochhaus-home configuration
- [x] Research official Rook and Talos documentation
- [x] Compare with our configuration
- [x] Identify missing/wrong pieces
- [x] Finalize execution plan
- [ ] Get user approval
- [ ] Execute plan

---

**End of Analysis Document**
