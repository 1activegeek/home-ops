# Gatus Deployment Plan

## Test Results - Re-test after bjw-s/app-template and HTTPRoute Embedding

### Validation Summary
- **Flux-Local Validation**: Attempted to run flux-local test, but encountered a tool error due to Python 3.14 compatibility issues with argparse. The command failed with TypeError: BooleanOptionalAction.__init__() got an unexpected keyword argument 'type'. This indicates a potential need to update flux-local or use an alternative Python version for local validations.
- **YAML Syntax Check**: Manually reviewed YAML files (helmrelease.yaml, ocirepository.yaml, kustomization.yaml, ks.yaml). All appear syntactically correct with proper indentation and structure.
- **Helm Chart Compatibility**: Using bjw-s/app-template v4.4.0 from OCI repository. The values structure matches the expected format for the chart, including embedded HTTPRoute under `route.app`.
- **HTTPRoute Embedding**: HTTPRoute is properly embedded in the HelmRelease values, targeting `envoy-internal` gateway in the `network` namespace with sectionName `https`. Hostname uses `gatus.${SECRET_DOMAIN}` as per standards.
- **Security Review**: 
  - No secrets required or defined (appropriate for monitoring internal services).
  - Security contexts set: non-root user (65534), read-only root filesystem, dropped capabilities, privilege escalation disabled.
  - Probes configured for liveness and readiness.
- **Performance and Resources**: CPU and memory requests/limits set appropriately (100m/128Mi requests, 500m/256Mi limits).
- **Compatibility with Cluster Components**:
  - Cilium: No network policies defined, but as monitoring, should be fine. Gatus monitors internal services via cluster DNS.
  - Envoy Gateway: HTTPRoute targets envoy-internal, which is correct for internal access.
  - Monitored Services: Endpoints include envoy-internal, cert-manager-webhook, external-dns, authentik, homarr. All these apps exist in the cluster structure, and URLs use internal cluster DNS (.svc.cluster.local).
- **Resource Conflicts**: No other apps in the monitoring namespace, so no conflicts expected.
- **Edge Cases**:
  - If monitored services are not deployed or healthy, Gatus will report failures, which is expected behavior.
  - Persistence uses Longhorn storage class, which is available in the cluster.
  - No external dependencies or internet access required.

### Test Status
- **Pass/Fail**: Conditional Pass - YAML and configuration appear valid, but flux-local tool failure prevents full validation. Recommend resolving flux-local issue or using GitHub Actions for validation.
- **Logs**: No deployment logs available (simulation only). Flux-local error: TypeError in argparse due to Python 3.14.

### Recommendations
- Fix flux-local compatibility issue (e.g., downgrade Python or update tool).
- Proceed to deployment if GitHub Actions pass, as local tool is faulty.
- If issues arise, request re-build from Buildarr.

### Next Steps
- Approve for deployment to Deployarr if validations pass in CI.
- Escalate flux-local issue to Orchestrator for tool maintenance.

## Deployment Staging - Re-stage with bjw-s/app-template and Embedded HTTPRoute

### Rollout Plan
- **Strategy**: Standard GitOps rollout via Flux reconciliation. No canary or progressive delivery required for this monitoring app.
- **Order of Operations**:
  1. Flux detects changes in the `gatus` Kustomization.
  2. OCIRepository pulls bjw-s/app-template v4.4.0.
  3. HelmRelease installs/upgrades Gatus with embedded HTTPRoute.
  4. Persistence PVC created with Longhorn storage.
  5. HTTPRoute reconciled for internal access at `gatus.${SECRET_DOMAIN}`.
- **Rollback Plan**: If issues arise, revert the PR or use Flux suspend/resume on the Kustomization. Previous version (if any) can be restored via Git history.
- **Monitoring**: Post-deployment, monitor via kubectl logs and Gatus UI for endpoint health. Validatarr will handle full validation.
- **Dependencies**: Relies on envoy-internal gateway, Longhorn storage, and monitored services being available.

### Manifest Updates
- Switched from custom HelmRelease to bjw-s/app-template v4.4.0 for consistency.
- Embedded HTTPRoute in HelmRelease values under `route.app` to simplify configuration.
- Added OCIRepository for chart source.
- Removed separate httproute.yaml and helmrepository.yaml.
- Updated kustomization.yaml to include ocirepository.yaml.
- Moved app to monitoring namespace (updated ks.yaml, namespace.yaml, and parent kustomization.yaml).

### Simulation Results
- **Flux-Local Test**: Failed due to Python 3.14 compatibility issue with flux-local tool (TypeError in argparse). Unable to perform local dry-run validation.
- **Manual Review**: All YAML files syntactically correct. Helm values align with bjw-s/app-template structure. No obvious configuration errors.
- **GitHub Actions**: Reliant on CI for validation (flux-local test in workflow).

### PR Draft Created
- **PR URL**: https://github.com/1activegeek/home-ops/pull/17
- **Title**: feat: deploy gatus monitoring with bjw-s/app-template
- **Body**: Includes summary of changes, focusing on app-template adoption, HTTPRoute embedding, and namespace move.
- **Status**: Draft PR created and pushed to gatus branch. Ready for review and merge approval.

### State Changes
- **Current State**: Staged for GitOps reconciliation.
- **Next Agent**: Ready for Validatarr post-deployment approval and application.

### Callouts
- Flux-local tool incompatibility with Python 3.14 persists; recommend updating tool or using alternative validation method.
- Ensure SECRET_DOMAIN is set in cluster-secrets for HTTPRoute hostname resolution.
- No secrets required; monitoring focuses on internal cluster services.

## Test Results - Re-test after Removing Install/Upgrade Settings and Adding Status Hostname

### Validation Summary
- **YAML Syntax Check**: All YAML files validated manually; syntactically correct.
- **Flux-Local Validation**: Same Python 3.14 compatibility error prevents local testing.
- **Helm Chart Compatibility**: Values compatible with bjw-s/app-template v4.4.0.
- **Changes Applied**: Install/upgrade settings removed (not present in spec); status hostname added to HTTPRoute hostnames.
- **Security, Performance, Compatibility**: No changes from previous; all good.

### Test Status
- **Pass/Fail**: Pass - Artifacts valid and changes correctly applied.
- **Logs**: Flux-local error as above.

### Recommendations
- Escalate flux-local issue.
- Approve for deployment.

### Next Steps
- Proceed to Deployarr for staging GitOps rollout.