# Storage Testing

This directory contains test manifests for validating storage deployments.

## Test Files

- **test-pvc-longhorn.yaml**: Tests Longhorn persistent storage with a test PVC and pod
- **test-pvc-nfs.yaml**: Tests NFS external storage with a test PVC and pod

## Testing Procedure

### 1. Verify Storage Classes

```bash
# Check that storage classes are created
kubectl get storageclass

# Expected output should show:
# - longhorn (default)
# - nfs-slow
```

### 2. Test Longhorn Storage

```bash
# Apply test PVC and pod
kubectl apply -f test-pvc-longhorn.yaml

# Wait for PVC to be bound
kubectl get pvc -n storage test-longhorn-pvc -w

# Check PV was created
kubectl get pv

# Check pod logs
kubectl logs -n storage test-longhorn-pod

# Expected log output:
# Testing Longhorn volume...
# Longhorn test data - <timestamp>
# Volume test successful!

# Verify in Longhorn UI
# Navigate to: https://longhorn.${SECRET_DOMAIN}
# Check that volume appears in the dashboard

# Cleanup
kubectl delete -f test-pvc-longhorn.yaml
```

### 3. Test NFS Storage

```bash
# Apply test PVC and pod
kubectl apply -f test-pvc-nfs.yaml

# Wait for PVC to be bound
kubectl get pvc -n storage test-nfs-pvc -w

# Check PV was created
kubectl get pv

# Check pod logs
kubectl logs -n storage test-nfs-pod

# Expected log output:
# Testing NFS volume...
# NFS test data - <timestamp>
# Volume test successful!

# Verify on NFS server (atlantis.local)
# Check that data was written to /volume2/kubes

# Cleanup
kubectl delete -f test-pvc-nfs.yaml
```

### 4. Test Default Storage Class

```bash
# Create a PVC without specifying storageClassName
# It should automatically use Longhorn (default)
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

# Verify it used Longhorn
kubectl get pvc -n storage test-default-pvc -o jsonpath='{.spec.storageClassName}'

# Expected output: longhorn

# Cleanup
kubectl delete pvc -n storage test-default-pvc
```

## Troubleshooting

### Longhorn Issues

```bash
# Check Longhorn manager logs
kubectl logs -n storage -l app=longhorn-manager -f

# Check Longhorn driver logs
kubectl logs -n storage -l app=longhorn-driver-deployer -f

# Check node status in Longhorn
kubectl get nodes.longhorn.io -n storage

# Verify mount path exists on nodes
talosctl -n 10.0.13.24 ls /var/mnt/longhorn-data
```

### NFS Issues

```bash
# Check CSI driver logs
kubectl logs -n storage -l app=csi-nfs-controller -f
kubectl logs -n storage -l app=csi-nfs-node -f

# Test NFS connectivity from cluster
kubectl run -it --rm debug --image=busybox --restart=Never -- sh
# Inside the pod:
# apk add nfs-utils
# mount -t nfs -o vers=4.1 atlantis.local:/volume2/kubes /mnt
```

## Success Criteria

- [x] Longhorn storage class exists and is marked as default
- [x] NFS storage class exists
- [x] Longhorn PVC can be created and bound
- [x] NFS PVC can be created and bound
- [x] Test pods can write to their respective volumes
- [x] Longhorn UI is accessible at longhorn.${SECRET_DOMAIN}
- [x] PVCs without storageClassName use Longhorn by default
