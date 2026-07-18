# Routing Architecture — Four Route Classes + Split DNS

How traffic reaches apps in this cluster, how "prefer internal on-LAN" is
guaranteed, and how to place any app into one of four route classes.

Read alongside [`authentication.md`](./authentication.md) (auth modes) and
[`deployment-standards.md`](./deployment-standards.md) (manifest patterns).

## The two gateways

| Gateway | GatewayClass | LB IP | Reached by | Auth |
|---|---|---|---|---|
| `envoy-internal` | `envoy` | `10.0.3.53` | LAN clients (direct) | none at gateway |
| `envoy-external` | `envoy-external` | `10.0.3.54` | Cloudflare Tunnel (internet) | Authentik forward-auth **by default** |

Both share one `EnvoyProxy` config and the wildcard TLS cert. They are separated
by **GatewayClass** (not just name) so the internal split-DNS resolver can tell
them apart — see below.

- **External auth is default-deny.** A gateway-level `SecurityPolicy`
  (`envoy-external-default-auth`) forces Authentik forward-auth on every route
  attached to `envoy-external`. Opt-outs are explicit (per route).
- **Internal is open at the gateway.** LAN traffic is trusted; per-app auth
  (native OIDC, app login) still applies where the app has it.

## The four route classes

The class is a property of the **hostname/app**, decided entirely by which
gateway(s) its HTTPRoute(s) attach to, plus (for external) an optional public
opt-out. Nothing in UniFi changes per app.

| # | Class | Internal route (`envoy-internal`) | External route (`envoy-external`) | On-LAN resolves to | From internet |
|---|---|---|---|---|---|
| 1 | **internal-only** (default) | ✅ | — | `.53` | not reachable |
| 2 | **internal + external (auth)** | ✅ | ✅ (default auth) | `.53` (no auth) | `.54` → Authentik |
| 3 | **internal + external (public)** | ✅ | ✅ + public opt-out | `.53` (no auth) | `.54` no auth |
| 4 | **external-only** | — | ✅ | public → Tunnel (hairpin) | `.54` (auth unless opt-out) |

Current members (from `task validate:security`):

- **Class 3 (public):** `hass` (Home Assistant), `requests` (Seerr),
  `auth` (Authentik IdP), `s` (Shlink redirects), `echo` (test)
- **Class 4 (external-only):** `flux-webhook`, `tesladev` (Tesla pubkey)
- **Class 1:** everything else (~46 apps)
- **Class 2:** none currently (valid empty class — use it for an internet app
  that should sit behind Authentik forward-auth)

**Class 4 is reserved for machine-to-machine endpoints** — hosts that are only
ever called by an external service (GitHub webhooks, Tesla's fleet API fetching
`.well-known`) and never browsed on-LAN, so the hairpin never applies to them
and an internal route would be pure surface. Anything a human might open on-LAN
should be dual (class 2 or 3), not external-only.

## Split DNS — how "prefer internal" is guaranteed

The requirement: on-LAN, if a host has an internal route use it (no auth); if it
only has an external route still reach it; never send LAN traffic to the
auth-gated external gateway when an internal path exists.

This is enforced **entirely in-cluster** — UniFi keeps a single, unchanging
domain forward and holds **zero per-host entries**.

```
LAN client
  → UniFi resolver (dnsmasq):  server=/${SECRET_DOMAIN}/10.0.3.52   (one rule, static)
      → k8s-gateway (CoreDNS k8s_gateway plugin) at 10.0.3.52
          • gatewayClasses = [envoy]   → only resolves INTERNAL-tier routes
          • fallthrough                → hosts with no internal route pass through
          • forward . 1.1.1.1 1.0.0.1  → fallthrough goes to PUBLIC DNS (no loop)
```

Per class, on-LAN:

- **internal-only / dual** → the host has an internal-tier (class `envoy`) route,
  so `k8s_gateway` answers with `10.0.3.53` **only**. Because it is filtered to
  the internal class, it never sees the external route of a dual host — so a
  dual host deterministically resolves to `.53`. This is the fix for the old
  bug where both `.53` and `.54` were returned (and `loadbalance` shuffled them).
- **external-only** → no internal-tier route → `k8s_gateway` produces no record →
  `fallthrough` → forwarded to public resolvers → Cloudflare (proxied) →
  Cloudflare Tunnel → `envoy-external`. Reachable on-LAN, via a hairpin.

Off-LAN, everything resolves via public Cloudflare DNS → Tunnel → `envoy-external`
(auth by default). Internal-only hosts have no public record and are unreachable.

### Why GatewayClass split (not per-host DNS records)

`k8s_gateway` can only filter by **GatewayClass** (`gatewayClasses`), not by
gateway name. With both gateways on one class it returned every matching
gateway's IP for a host — hence the nondeterministic `.53/.54` answers on dual
hosts. Giving the external gateway its own class (`envoy-external`) lets the
resolver ignore it, so the cluster — not a UniFi record list — decides internal
vs external from each app's route config. No webhook, no UniFi API, no
per-host entries to maintain.

### Tradeoff: external-only hairpins on-LAN

A class-4 host resolves out to Cloudflare and back through the Tunnel when
queried on-LAN (extra latency). By policy class 4 is reserved for
machine-to-machine hosts (`flux-webhook`, `tesladev`) that are never queried
on-LAN, so the hairpin does not occur in practice. If a class-4 host ever needs
LAN-direct access, add an `envoy-internal` parentRef to its route (a second
parentRef on the same HTTPRoute is enough) — it becomes class 2 or 3.

## How to declare each class

All routes use `sectionName: https`, `namespace: network`, hostnames
`<sub>.${SECRET_DOMAIN}`.

**Class 1 — internal-only (default).** One route on `envoy-internal`
(embedded in the HelmRelease `route:` block or a standalone HTTPRoute):

```yaml
parentRefs:
  - name: envoy-internal
    namespace: network
    sectionName: https
```

**Class 2 — internal + external (auth).** Add a second route on `envoy-external`
with the **same hostname**. No SecurityPolicy needed — the gateway default
applies Authentik forward-auth.

```yaml
# second route
parentRefs:
  - name: envoy-external
    namespace: network
    sectionName: https
```

**Class 3 — internal + external (public).** Same as class 2, plus a public
opt-out on the external route. Two patterns:

- *Standalone external HTTPRoute* → use the reusable component
  `kubernetes/components/public-access` (see `apps/default/echo`).
- *Embedded (bjw-s `route:`) external route* → add an inline `SecurityPolicy`
  with an empty `extAuth`, targeting the rendered HTTPRoute
  (`<release>-<routeKey>`). See `apps/tools/shlink/app/securitypolicy-public.yaml`
  (`s.` redirect) and `apps/media/seerr` (`requests.`).

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: <route>-public
  namespace: <ns>
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: <route>        # rendered HTTPRoute name
  # empty extAuth = opt out of gateway default auth
```

**Class 4 — external-only.** One route on `envoy-external` only. Add a public
opt-out (as class 3) if it must be anonymous.

## Validation

```bash
task validate:security     # static: classify all routes into the 4 classes,
                           # assert every external route has an auth posture
task validate:dns-split \  # live (run ON the LAN): prove prefer-internal holds
  DOMAIN=<domain>          # dual hosts must resolve to .53 ONLY
task validate:routes       # backendRef → service-name integrity
```

`validate:dns-split` is the regression test for the split-DNS invariant: it
queries `10.0.3.52` and fails if any dual host returns the external gateway IP.

## Moving pieces (files)

| Concern | File |
|---|---|
| Gateways + GatewayClasses | `kubernetes/apps/network/envoy-gateway/app/envoy.yaml` |
| External default auth | `.../envoy-gateway/app/securitypolicy-external-default.yaml` |
| Internal split-DNS resolver | `kubernetes/apps/network/k8s-gateway/app/helmrelease.yaml` |
| Public opt-out (reusable) | `kubernetes/components/public-access/` |
| Forward-auth (reusable) | `kubernetes/components/authentik-forward-auth/` |
| External DNS publish (Cloudflare) | `kubernetes/apps/network/cloudflare-dns/` |
| Public tunnel | `kubernetes/apps/network/cloudflare-tunnel/` |
| UniFi forward | dnsmasq `server=/${SECRET_DOMAIN}/10.0.3.52` (single rule, on the UCG) |
