# Tasks & Ideas

## Core Infra to Deploy
- [x] Implement External Secrets Operator
- [x] Deploy 1Password integrated with External Secrets
- [x] Add longhorn for persistent storage
- [x] Enable NFS for external storage access
- [ ] Authentik for SSO/Passkey/Enroll
  - [ ] Fix/handle HTTPS redirect after success (https://gateway-api.sigs.k8s.io/guides/http-redirect-rewrite/#http-to-https-redirects)
- [ ] Observability Stack (see below)
- [ ] User Landing Page
- [ ] Optimize core deployment
- [ ] Automation bot for working with PRs and automatically applying or group applying

## Observability Stack
- [ ] openobserve

Decide on whether to add any of these additionally:
- kube-prometheus-stack
- grafana
- opentelemetry
- loki

## User Landing Page
Choose one of the following
- homepage
- homer
- dashy
- homarr

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


## Virtualization
- [ ] Research/validate best option to deploy virtualization on top of cluster
- [ ] configure UI to manage
- [ ] Dedicated jump/bastion host

## Some Future Enhancements
1. Migrate existing SOPS-encrypted application secrets to External Secrets (if any exist)
2. Evaluate where secrets can be removed from cluster secrets and use 1Password
3. Create ExternalSecret resources for actual applications that need secrets
4. Document how to add new secrets to the 1Password homeops vault
5. Configure Longhorn recurring snapshots and backup targets (S3/NFS)