# Homarr Deployment README

## Overview
Homarr is a sleek, modern dashboard application designed for organizing and accessing links, apps, and services in a clean, customizable interface. It serves as a user landing page in this home-ops cluster, allowing easy access to internal tools (e.g., monitoring, media apps) without exposing them externally. It fits into the larger cluster ecosystem by providing a centralized hub for users, integrating with authentication (via Authentik) and routing through Envoy Gateway. Key features include widgets for weather, RSS feeds, and app shortcuts, with a focus on simplicity and performance.

## Current Setup
- **Exposure**: Accessible internally via HTTPRoute on the `envoy-internal` gateway. Hostnames: `homarr.${SECRET_DOMAIN}` and `home.${SECRET_DOMAIN}`. Routes HTTPS traffic to port 7575 on the Homarr pod.
- **Moving Pieces/Parts**:
  - **Deployment**: HelmRelease in `app/helmrelease.yaml`, using OCI chart from `ghcr.io/homarr-labs/homarr:v1.43.1`.
  - **Persistence**: 1Gi PVC for the database (`homarrDatabase`), backed by Longhorn storage class for HA and snapshots.
  - **Secrets**: Uses External Secrets with 1Password (`homarr-secret` for DB encryption key). RBAC enabled for cluster access.
  - **Networking**: HTTPRoute embedded in Helm values; no separate route file.
  - **Functionality**: Runs as a stateless web app with database storage. Authenticates via credentials; integrates with cluster services via links/widgets.
- **Operation in Cluster**: Deploys to `default` namespace. Flux reconciles changes; Longhorn ensures data durability. No external exposure—internal only for security.

## Important Notes about Config
- **Key Details**: Env vars include `AUTH_PROVIDERS: "credentials"` and `TZ: "America/New_York"`. Database encryption uses a secret key from 1Password.
- **Gotchas/Issues**:
  - Persistence is critical—PVC retains data on removal/re-add, but ensure Longhorn backups for recovery.
  - If re-deploying, PVC re-attaches automatically if specs match; manual intervention may be needed for name mismatches.
  - RBAC must be enabled for proper operation; disable only if troubleshooting.
  - HTTPRoute embedding requires chart support—verify in future updates.
  - No external auth yet; relies on internal access controls.
- **Updates**: Monitor Homarr releases for new features (e.g., integrations). Use Renovate for automated chart updates.

## Tasks
- **Completed**: Initial deployment with persistence, routing, and secrets (marked done in TODO.md).
- **Remaining/Future**:
  - Evaluate integration with Authentik for SSO (noted in TODO.md under Authentik enhancements).
  - Add recurring Longhorn snapshots for Homarr PVC (configure in Longhorn settings).
  - Plan updates for new Homarr versions (e.g., check for route embedding changes).
  - If issues arise (e.g., data loss), document and update this README.