# Tasks & Ideas

## Observability Stack
- App
  Name: openobserve
  Namespace: monitoring
  Helm/OCI Repo:
  Replicas:
  ExternalSecret: openobserve-secret
  Values: document any values I would need and any that should be a secret so they can be populated
  Storage: [Longhorn, NFS]
  Route: internal only
  Hostnames: default, plus observe.{$SECRET_DOMAIN}

Decide on whether to add any of these additionally:
- kube-prometheus-stack
- grafana
- opentelemetry
- loki

## Virtualization
- [ ] Research/validate best option to deploy virtualization on top of cluster
- [ ] configure UI to manage
- [ ] Dedicated jump/bastion host

## Optimizations
- Cleanup secrets naming
- Plan PVC monitoring to keep space consumption optimal (kill old dangling PVC)
- Customize README for Repo - move odl to template ref, update with current state
- Switch over old helm repo url to OCI format

## Some Future Enhancements
- 1Password
  - Upgrade 1Password to use itself for secrets vs SOPS
  - Migrate existing SOPS-encrypted application secrets to External Secrets (if any exist)
  - Evaluate where secrets can be removed from cluster secrets and use 1Password
  - Create ExternalSecret resources for actual applications that need secrets
  - Create ExternalSecret standards for claude.md file
  - Document how to add new secrets to the 1Password homeops vault
- Authentik
  - Configure User configs in Authentik
  - Fix/handle HTTPS redirect after success (https://gateway-api.sigs.k8s.io/guides/http-redirect-rewrite/#http-to-https-redirects)
- Longhorn
  - Configure Longhorn recurring snapshots and backup targets (S3/NFS)

