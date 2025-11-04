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