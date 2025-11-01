### Next Steps
- Approve for deployment; hand off to Deployarr.

## Deployment Staging by k8s-deployarr (2025-10-31)

### Rollout Plan
- **Strategy**: Standard rollout for new stateless application. Deploy single replica with immediate full traffic, as Homarr is a dashboard with no external dependencies beyond secrets and storage.
- **Progressive Delivery**: Not applicable for initial deployment; can implement blue-green or canary in future updates if needed.
- **Pre-Deployment Checks**:
  - Confirm 1Password vault 'homeops' contains item 'homarr-secret' with fields: HOMARR_PASSWORD (for admin auth), PLEX_API_KEY, SONARR_API_KEY (for integrations, optional).
  - Ensure cluster secrets (e.g., SECRET_DOMAIN) are substituted correctly via Flux postBuild.
  - Verify no conflicts with existing apps in default namespace (only echo app present, no overlap).
- **Steps**:
  1. Create and merge PR from 'homarr' branch to 'main'.
  2. Flux reconciles the Kustomization 'homarr' in default namespace.
  3. Monitor HelmRelease: `flux get hr homarr -n default`.
  4. Check pod readiness: `kubectl get pods -n default -l app.kubernetes.io/name=homarr`.
  5. Verify access: Internal route at `https://home.${SECRET_DOMAIN}` via envoy-internal.
  6. Confirm ExternalSecret syncs secrets to 'homarr-secret' Kubernetes Secret.
- **Resource Allocation**:
  - CPU: 100m request / 500m limit
  - Memory: 256Mi request / 512Mi limit
  - Storage: 5Gi PVC for SQLite database
- **Rollback Plan**: If deployment fails, scale HelmRelease replicas to 0 or delete Kustomization to remove resources. Revert PR if needed.
- **Post-Deployment**: Hand off to Validatarr for health checks and validation.

### Simulation Results
- **Flux-Local Diff**: Unable to run due to Python 3.14 compatibility issues (BooleanOptionalAction error). Used kustomize build as alternative.
- **Manifest Validation**: Kustomize build successful; all resources (HelmRelease, OCIRepository, ExternalSecret, HTTPRoute) valid and compatible.
- **Compatibility**: No conflicts with Envoy Gateway, External Secrets, or storage. Security context and RBAC appropriate.
- **Status**: Ready for PR creation and deployment.

### PR Draft
- **Title**: feat: Deploy Homarr dashboard to default namespace
- **Body**:
  ## Summary
  Deploys Homarr, a modern dashboard for home labs, to the default namespace. Includes HelmRelease, OCI repository, ExternalSecret for 1Password integration, and HTTPRoute for internal access at `home.${SECRET_DOMAIN}`.

  ## Changes
  - Add `kubernetes/apps/default/homarr/` with app manifests.
  - Update `kubernetes/apps/default/kustomization.yaml` to include `./homarr/ks.yaml`.

  ## Rollout
  - Standard deployment: Single replica, stateless.
  - Resources: 100m CPU / 256Mi mem requests; 500m CPU / 512Mi mem limits; 5Gi PVC.
  - Security: Non-root user, read-only FS, secrets via ExternalSecret.

  ## Validation
  - Tested with kustomize build; manifests valid.
  - No conflicts with existing cluster resources.

### Next Steps
- Create PR from 'homarr' branch to 'main'.
- After merge, monitor Flux reconciliation.
- Hand off to Validatarr for post-deploy validation.