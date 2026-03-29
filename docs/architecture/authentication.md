# Authentication Architecture

## Purpose

This document defines the standard authentication model for routed applications in this cluster. Agents and operators should use it before adding, changing, or exposing any web application.

The goal is to make exposure decisions explicit, keep public services protected by default, and avoid accidental unauthenticated routes.

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

## App Classification Matrix

| App | Exposure | Auth Mode | Rationale |
|-----|----------|-----------|-----------|
| Gatus | internal | `native_oidc` | Native OIDC support and operator UI access |
| Grafana | internal | `native_oidc` | Native generic OAuth with Authentik |
| MeTube | internal | `forward_auth` | No built-in auth; easy gateway protection if desired later |
| Forgejo | internal | `native_oidc` | Strong native OIDC support |
| Zipline | external | `native_oidc` | Public app with supported OIDC flow |
| Plex | internal | `external_identity_exception` | Uses Plex.tv identity model |
| SABnzbd | internal | `forward_auth` | No native OIDC; gateway auth is the preferred pattern |
| qBittorrent | internal | `forward_auth` | No native OIDC; gateway auth is the preferred pattern |
| Seerr | external | `external_identity_exception` | User flow is intentionally based on Plex auth |
| Shlink | external | `public_exception` | Redirect service is intended to serve public links |
| Shlink Web | internal | `forward_auth` | Admin UI should not be publicly exposed |
| Tautulli | internal | `forward_auth` | No native OIDC |
| Bazarr | internal | `forward_auth` | No native OIDC |
| Audiobookshelf | internal | `forward_auth` | Built-in auth exists, but no native OIDC |
| Grimmory | internal | `none` | Deployed internal-only first; auth deferred to a follow-up change |
| OpenWebUI | internal | `native_oidc` | Native OIDC support |
| n8n | internal | `native_oidc` | Prefer Authentik-backed OIDC when configured |
| Teslamate | internal | `forward_auth` | No native OIDC |

## Default Workflow For Future Agents

Before changing any routed app:

1. Read this document.
2. Decide whether the app is `external`, `internal`, or `cluster_internal`.
3. Choose and document the auth mode.
4. Make the manifest changes.
5. Run validation.
6. Update the deployment plan status and session log.

If the right auth mode is unclear, stop and resolve the policy decision before changing manifests.
