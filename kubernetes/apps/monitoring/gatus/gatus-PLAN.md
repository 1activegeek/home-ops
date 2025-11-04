### Next Steps
- Proceed to Deployarr for staging GitOps rollout.

## Deployment Staging - Re-stage after Removing Install/Upgrade Settings and Adding Status Hostname

### Rollout Plan
- **Strategy**: Standard GitOps rollout via Flux reconciliation. No canary or progressive delivery required for this monitoring app.
- **Order of Operations**:
  1. Flux detects changes in the `gatus` Kustomization.
  2. OCIRepository pulls bjw-s/app-template v4.4.0.
  3. HelmRelease installs/upgrades Gatus with embedded HTTPRoute.
  4. Persistence PVC created with Longhorn storage.
  5. HTTPRoute reconciled for internal access at `gatus.${SECRET_DOMAIN}` and `status.${SECRET_DOMAIN}`.
- **Rollback Plan**: If issues arise, revert the PR or use Flux suspend/resume on the Kustomization. Previous version (if any) can be restored via Git history.
- **Monitoring**: Post-deployment, monitor via kubectl logs and Gatus UI for endpoint health. Validatarr will handle full validation.
- **Dependencies**: Relies on envoy-internal gateway, Longhorn storage, and monitored services being available.

### Manifest Updates
- Removed any install/upgrade settings from HelmRelease spec (none were present).
- Added `status.${SECRET_DOMAIN}` to HTTPRoute hostnames for status page access.
- No other changes; configuration remains consistent with bjw-s/app-template v4.4.0.

### Simulation Results
- **Flux-Local Test**: Failed due to Python 3.14 compatibility issue with flux-local tool (TypeError in argparse). Unable to perform local dry-run validation.
- **Manual Review**: All YAML files syntactically correct. Helm values align with bjw-s/app-template structure. Hostname addition properly configured.
- **GitHub Actions**: Reliant on CI for validation (flux-local test in workflow).

### PR Draft Updated
- **PR URL**: https://github.com/1activegeek/home-ops/pull/17
- **Title**: feat: deploy gatus monitoring with bjw-s/app-template
- **Body**: Updated to reflect the latest changes: removal of install/upgrade settings and addition of status hostname.
- **Status**: PR updated with new commits. Ready for review and merge approval.

### State Changes
- **Current State**: Re-staged for GitOps reconciliation with updated hostnames.
- **Next Agent**: Ready for Validatarr post-deployment approval and application.

### Callouts
- Flux-local tool incompatibility with Python 3.14 persists; recommend updating tool or using alternative validation method.
- Ensure SECRET_DOMAIN is set in cluster-secrets for HTTPRoute hostname resolution.
- Status hostname allows access to Gatus status page at status.${SECRET_DOMAIN}.