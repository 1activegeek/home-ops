# Tasks & Ideas

## Core Infra to Deploy
- [x] Implement External Secrets Operator
- [x] Deploy 1Password integrated with External Secrets
- [x] Add longhorn for persistent storage
- [x] Enable NFS for external storage access
- [x] Authentik for SSO/Passkey/Enroll
- [x] User Landing Page (see below)
- [ ] Optimize core deployment
- [ ] Automation bot for working with PRs and automatically applying or group applying
- [ ] Observability Stack (see below)

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

## Fixarr


## User Landing Page
In case Homarr doesn't work out: homer

## Services/Apps to Deploy
- Home Assistant
  - Get hardware mapping complete for external USB interfaces (Ademco Alarm Panel + ZWave Stick)
- Ollama
- OpenWebUI
- LibreChat
- n8n
- Gitea
- Teslamate
- tailscale
- nextcloud
- uptime kuma
- gatus
- pihole
- audiobookshelf
- unpoller
- docuseal
- glances
- scrutiny
- tailscale
- teleport





## Virtualization
- [ ] Research/validate best option to deploy virtualization on top of cluster
- [ ] configure UI to manage
- [ ] Dedicated jump/bastion host

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

 ## Others
- Make list of the common Gotchas I get snagged on
  - formatting issues, forgetting the proper {{ .ReleaseName }} or ${ENV_VAR}
setup standards for dpeloyment of routes, secret handling, substitutions

