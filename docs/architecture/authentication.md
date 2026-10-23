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

### Applying blueprint changes

Merging a blueprint change is not always enough. Authentik's worker has been seen not to re-import a
changed blueprint on its own (the discovery task did not run), so a new provider never appeared. After
the ConfigMap updates, check that the object exists; if it does not, run
`ak apply_blueprint /blueprints/mounted/cm-authentik-blueprints/<file>` in the worker pod. The
embedded outpost then takes a few minutes to start serving a new host, and returns 404 until it does.

Define each application slug in exactly one blueprint file. Two files that both declare the same
application fight over its provider, and whichever applies last wins.

## App Classification Matrix

Audited against the live cluster and the manifests. `none` means the app has no authentication in
front of it - for an internal-only route that is a deliberate choice, not an omission.

| App | Exposure | Auth Mode | Rationale |
|-----|----------|-----------|-----------|
| Headlamp | internal | `native_oidc` | Blueprinted. Shares its client ID with the kube-apiserver OIDC config |
| Grafana | internal | `native_oidc` | Blueprinted. Generic OAuth against Authentik |
| Forgejo | internal | `native_oidc` | Blueprinted. The auth source also lives in Forgejo's own database. Self-service registration is disabled, including through the Authentik source (no auto-registration), so accounts are created by an admin. The Actions runner is user-scoped to the owner's account, not instance-wide, and is scheduled away from Home Assistant's node |
| Hermes | internal | `native_oidc` | Blueprinted. Dashboard refuses to bind without a provider |
| Homarr | internal | `native_oidc` | Blueprinted. Application bound to `tier1` + `tier2` only (tier3 and ungrouped users are denied at Authentik). Homarr syncs the `groups` claim onto same-named Homarr groups: `tier1` holds the admin permission, `tier2` gets board view. Local credentials stay enabled for one break-glass admin; no auto-login |
| Nextcloud | internal | `native_oidc` | Blueprinted. user_oidc app configured by the app's setup hook. Application bound to `tier1` + `tier2`. Single user backend, so `/login` auto-redirects to Authentik (an existing Authentik session signs straight in). Local admin is break-glass via the direct-login URL. Accounts keyed on the Authentik username; no group sync, so Nextcloud admin rights are granted inside Nextcloud |
| Matrix (MAS) | internal | `native_oidc` | Blueprinted. Redirect URI embeds a pinned upstream-provider ID |
| Synapse | internal | `native_oidc` | Auth fully delegated to MAS. Federation disabled; no local passwords |
| Element | internal | `native_oidc` | Static client; flows through Synapse -> MAS -> Authentik |
| Z-Wave JS UI | cluster_internal | `none` (HA session) | No route; reachable only from Home Assistant's node. A CiliumNetworkPolicy admits only Home Assistant (`host` entity) on the UI and Z-Wave JS server ports. The UI is reached only through an admin-only Home Assistant ingress panel (hass_ingress), so HA login is the gate. Never route it: it can run code in a privileged container and controls locks |
| Home Assistant | external | `public_exception` | Opted out via the `public-access` component; uses its own auth |
| Zipline | internal | `none` (native app login) | Zipline's own login. A proxy provider exists in the blueprint, but no SecurityPolicy attaches it to the route, so it enforces nothing |
| HA Code Server | cluster_internal | `none` (HA session) | No Service or route; bound to loopback in the HA pod. Reached only via an admin-only Home Assistant ingress panel (hass_ingress), so HA login is the gate. Never route it: it is a root shell in a privileged pod |
| Seerr | external | `external_identity_exception` | Stays on Plex sign-in by decision: Plex links household users to their Plex accounts, which is the intended experience |
| Authentik | external | `public_exception` | It is the IdP. Admin console is 404'd at the public edge |
| Echo, Flux webhook, Tesla pubkey | external | `public_exception` | Webhook and probe endpoints. Echo stays public by decision: it is the external health check |
| Grimmory | internal | `none` | OIDC explicitly disabled in its config |
| Healthchecks | internal | `forward_auth` | First **enforced** internal forward-auth (`internal-forward-auth` component) on the UI route, gated to `tier1`; app trusts `X-authentik-email` (`REMOTE_USER_HEADER`). `/ping/`, `/api/`, `/badge/` on a separate unauthenticated route (also plain HTTP for ping/api) that strips `X-authentik-*`; CiliumNetworkPolicy blocks direct pod access |
| Longhorn UI | internal | `forward_auth` | `internal-forward-auth` component (Authentik proxy provider), gated to `tier1` |
| Prometheus + Alertmanager | internal | `forward_auth` | One SecurityPolicy (`kps-forward-auth`) targets both routes; gated to `tier1`. The Prometheus admin API is disabled |
| TeslaMate | internal | `forward_auth` | `internal-forward-auth` component, gated to `tier1` |
| MeTube | internal | `forward_auth` | `internal-forward-auth` component on the whole app, gated to `tier1`. No unauthenticated exception (not even `/add`) |
| Bambuddy | internal | `forward_auth` + native login | `internal-forward-auth` component, gated to `tier1`, and Bambuddy's own login is also enabled, so users sign in twice. Its Home Assistant integration uses a non-admin HA user's token |
| Apprise | internal | `forward_auth` (UI) / `none` (API) | Split routes. The UI and config paths (`apprise-app` route) sit behind the `internal-forward-auth` component, gated to `tier1`. `/notify*` and the exact `/status` path stay open on a separate `apprise-notify` route so in-cluster senders and health checks keep working |
| Gatus | internal | `none` | Read-only status page; no write actions or secrets in the UI. Replaced Uptime Kuma (which had its own login) |
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
