# Tasks & Ideas

## Core Infra to Deploy
- [x] Implement External Secrets Operator
- [x] Deploy 1Password integrated with External Secrets
- [x] Add longhorn for persistent storage
- [x] Enable NFS for external storage access
- [ ] Evaluate where secrets can be removed from cluster secrets and use 1Password
- [ ] Setup auth structure and SSO - look into passkey options
- [ ] Add monitoring stack - TBD - Promehteus/Grafana or others?
- [ ] Optimize core deployment
- [ ] Automation bot for working with PRs and automatically applying or group applying


## Services/Apps to Deploy
- [ ] Home Assistant
  - [ ] Get hardware mapping complete for external USB interfaces (Ademco Alarm Panel + ZWave Stick)
- [ ] Ollama
- [ ] OpenWebUI
- [ ] LibreChat
- [ ] Gitea
- [ ] Teslamate

## Virtualization
- [ ] Research/validate best option to deploy virtualization on top of cluster
- [ ] configure UI to manage
- [ ] Dedicated jump/bastion host

## Some Future Enhancements
1. Migrate existing SOPS-encrypted application secrets to External Secrets (if any exist)
2. Create ExternalSecret resources for actual applications that need secrets
3. Document how to add new secrets to the 1Password homeops vault
4. Configure Longhorn recurring snapshots and backup targets (S3/NFS)