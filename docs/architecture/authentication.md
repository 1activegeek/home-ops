# Authentication Architecture

## Purpose

This document defines the standard authentication model for routed applications in this cluster. Agents and operators should use it before adding, changing, or exposing any web application.

The goal is to make exposure decisions explicit, keep public services protected by default, and avoid accidental unauthenticated routes.

> Routing mechanics (the four route classes, split-DNS "prefer internal", and how
> to place an app in each class) live in [`routing.md`](./routing.md). This
> document defines the **auth modes** an external route may declare.

## Scope

This policy applies to HTTP(S) applications exposed through Envoy Gateway.

- `envoy-external` is the internet-facing boundary and requires an explicit auth decision for every app.
- `envoy-internal` is for local-network access and may remain open by default unless a stronger auth requirement is documented.
- Cluster-internal services with no routed UI do not need Authentik unless a specific integration requires it.

## External Exposure Policy

Every app routed through `envoy-external` must declare one of these auth modes:

1. `native_oidc` - the app integrates directly with Authentik using OIDC or OAuth.
2. `forward_auth` - Envoy/Authn policy protects the app before traffic reaches it.
3. `public_exception` - the app is intentionally reachable without Authentik.
4. `external_identity_exception` - the app uses a non-Authentik identity flow by design.

If an app is external and no auth mode has been chosen, that is a policy violation.

## Decision Rules

Use this order when choosing auth for an external app:

1. Prefer `native_oidc` when the application has stable Authentik-compatible support and the user experience is good.
2. Use `forward_auth` when the app has weak auth, no OIDC support, or should be protected consistently at the gateway.
3. Use `public_exception` only when anonymous or guest access is an intentional product requirement.
4. Use `external_identity_exception` only when the app's own external identity model is the intended experience.

For `envoy-internal`, auth is optional. Still document the chosen mode so future changes are deliberate.

## Documentation Rules

When adding or changing a routed app:

1. Record its exposure (`external`, `internal`, or `cluster_internal`) and auth mode in the relevant plan docs.
2. Update `docs/deployment-plan.md` with the high-level decision.
3. Keep sensitive operational details out of public docs. Do not commit IPs, storage paths, private email addresses, secret names, redirect URIs, or other near-secret deployment details unless they are already intentionally public.
4. Update `.private/PRD.md` only when private operational detail is truly required.
5. Update the deployment status and session log when the phase changes.

## Validation Rules

Before opening a PR for any routed app change:

1. Run `task validate:preflight`.
2. Run `task validate`.
3. Confirm the route security posture is acceptable, especially for `envoy-external` apps.

Validation is required for auth changes, route changes, new apps, and app removals.

## Configuration As Code

Authentik's own configuration is declared in blueprints under
`kubernetes/apps/security/authentik/app/blueprints/` and delivered to the pods as a ConfigMap. This
is the source of truth: an object that is not in a blueprint does not survive a rebuild.

| File | Owns |
|------|------|
| `00-foundation.yaml` | Access-tier groups, the custom scope mapping, shared policies |
| `10-auth-experience.yaml` | Passkey login, password recovery, invitation enrollment, the brand |
| `20-oidc-integrations.yaml` | OIDC providers and their applications |
| `30-proxy-integrations.yaml` | Forward-auth providers and embedded-outpost membership |
| `40-launcher-apps.yaml` | Portal tiles for apps with no provider |

Rules:

1. **Never create providers, applications, or flows through the UI or the API.** They will be lost on
   rebuild, and the next blueprint apply may partially overwrite them. Add a blueprint entry instead.
2. Client IDs are pinned literally in the blueprint. Client secrets come from `!Env`, backed by the
   `authentik-oidc-clients` ExternalSecret, so a rebuilt instance comes back with the secret the
   application already holds.
3. Blueprints do partial updates - fields a blueprint does not name are left alone. Adding a field to
   a blueprint therefore takes ownership of it.
4. Blueprint files have no guaranteed apply order. Cross-file dependencies are declared with
   `authentik_blueprints.metaapplyblueprint`, not by filename.

Adding a new integration is covered by the `/setup-authentik-oidc` command.

## App Classification Matrix

Audited against the live cluster and the manifests. `none` means the app has no authentication in
front of it - for an internal-only route that is a deliberate choice, not an omission.

| App | Exposure | Auth Mode | Rationale |
|-----|----------|-----------|-----------|
| Headlamp | internal | `native_oidc` | Blueprinted. Shares its client ID with the kube-apiserver OIDC config |
| Grafana | internal | `native_oidc` | Blueprinted. Generic OAuth against Authentik |
| Forgejo | internal | `native_oidc` | Blueprinted. The auth source also lives in Forgejo's own database |
| Hermes | internal | `native_oidc` | Blueprinted. Dashboard refuses to bind without a provider |
| Matrix (MAS) | internal | `native_oidc` | Blueprinted. Redirect URI embeds a pinned upstream-provider ID |
| Synapse | internal | `native_oidc` | Auth fully delegated to MAS. Federation disabled; no local passwords |
| Element | internal | `native_oidc` | Static client; flows through Synapse -> MAS -> Authentik |
| Z-Wave JS UI | external | `forward_auth` | Blueprinted proxy provider. The only external route actually gated |
| Home Assistant | external | `public_exception` | Opted out via the `public-access` component; uses its own auth |
| Zipline | internal | `forward_auth` | Blueprinted proxy provider |
| HA Code Server | internal | `forward_auth` | Blueprinted proxy provider; its route is currently disabled |
| Seerr | external | `external_identity_exception` | User flow is intentionally based on Plex auth |
| Shlink | external | `public_exception` | Redirect service is intended to serve public links |
| Plex | internal | `external_identity_exception` | Uses Plex.tv identity model |
| Authentik | external | `public_exception` | It is the IdP. Admin console is 404'd at the public edge |
| Echo, Flux webhook, Tesla pubkey | external | `public_exception` | Webhook and probe endpoints |
| Mattermost | internal | `none` | Team Edition licence-gates OIDC; internal-only LAN access |
| Grimmory | internal | `none` | OIDC explicitly disabled in its config |
| All other internal apps | internal | `none` | Internal-only; no gateway auth and no OIDC configured |

Apps in the last row include the *arr stack, media tooling, monitoring UIs, and the AI services. They
have a portal tile in Authentik for discoverability, but that tile does not authenticate anything.

## Default Workflow For Future Agents

Before changing any routed app:

1. Read this document.
2. Decide whether the app is `external`, `internal`, or `cluster_internal`.
3. Choose and document the auth mode.
4. Make the manifest changes.
5. Run validation.
6. Update the deployment plan status and session log.

If the right auth mode is unclear, stop and resolve the policy decision before changing manifests.

For `native_oidc` apps, use the `setup-authentik-oidc` skill: providers and applications are
declared as blueprints under `kubernetes/apps/security/authentik/app/blueprints/`, never
created in the Authentik UI or via the REST API, so they survive an Authentik rebuild.
