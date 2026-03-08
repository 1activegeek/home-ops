# Auth Governance Design

## Goal

Establish a durable authentication standard for routed applications, reconcile the rollout tracker with the actual cluster state, and remove Uptime Kuma in favor of Gatus.

## Approved Design

### Documentation model

- Keep `docs/deployment-plan.md` as the public rollout tracker.
- Keep `.private/deployment-plan.md` as the private operational companion.
- Add `docs/architecture/authentication.md` as the canonical auth policy for future app work.
- Add a short pointer in `AGENTS.md` so future agents discover the auth policy early.

### Auth policy

- `envoy-external` requires an explicit auth decision for every routed app.
- Preferred order for external apps: native OIDC/OAuth, then forward-auth, then explicit public exception, then explicit external identity exception when the app's own identity flow is intentional.
- `envoy-internal` may remain open by default, but the chosen auth mode still needs to be documented.
- Public exposure without a documented auth decision is considered a policy violation.

### Planning rules

- Public docs must avoid sensitive operational details such as private IPs, storage paths, private email addresses, secret names, and redirect URIs.
- Future app work should follow the current validation guidance, including `task validate:preflight` and `task validate`.
- Deployment trackers and session logs must be updated as phases move forward.

### Monitoring direction

- Gatus becomes the only planned status and endpoint monitor.
- Uptime Kuma is removed from the rollout plan and from Git-managed manifests.

## Expected Outcomes

- Future agents have a single auth policy to follow.
- The deployment tracker reflects the apps that are already deployed in the cluster.
- Monitoring scope is simplified around Gatus.
