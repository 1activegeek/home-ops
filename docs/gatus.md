# Gatus (uptime checks)

Gatus (`monitoring/gatus`) probes every routed app from inside the cluster through the same path
users take: DNS, then Envoy, then TLS, then the app. It replaced Uptime Kuma in 2026-10. All checks
live in git. Nothing is configured by clicking in the UI, and there is no database of monitors to
lose.

- UI: `https://gatus.<domain>`. Internal gateway, auth mode `none`. The page is read-only.
- In-cluster: `http://gatus.monitoring.svc.cluster.local:8080` (`/metrics`, `/api/v1/endpoints/statuses`).

## How checks get created

```
HTTPRoute ──▶ gatus-sidecar ──▶ /config/gatus-sidecar.yaml ─┐
Gateway annotation (defaults) ┘                             ├─▶ Gatus ──▶ /metrics ──▶ Prometheus ──▶ Alertmanager ──▶ Matrix
                            app/resources/config.yaml ──────┘
```

The pod runs [gatus-sidecar](https://github.com/home-operations/gatus-sidecar) as a native sidecar.
It watches every HTTPRoute attached to `envoy-internal` or `envoy-external` and writes one Gatus
endpoint per route. Gatus hot-reloads the file. **A new app with a route gets a check
automatically**, with nothing to register.

How a generated endpoint is built:

| Field | Source |
|---|---|
| `name` | the `name:` in the route's annotation (the display name every route carries), else the HTTPRoute name |
| `url` | `https://` + the route's first hostname + its first non-`/` path match |
| `group` | `internal` / `external`, set by the gateway of the route's **first** parentRef |
| defaults | the Gateway's `gatus.home-operations.com/endpoint` annotation (`network/envoy-gateway/app/envoy.yaml`): `[STATUS] == 200`, 1m interval, 30s timeout, `severity: warning`. `envoy-external` also sets `client.dns-resolver: tcp://1.1.1.1:53` (see Outside-in checks below) |
| overrides | the route's own `gatus.home-operations.com/endpoint` annotation. It merges over the gateway default, and the route wins. |

Redirects are followed, so an app behind Authentik passes when the Authentik login page renders.
`[STATUS] == 200` is therefore the default for every route.

`app/resources/config.yaml` holds only Gatus' own settings and the checks that have no route to
annotate: `Public DNS` (the tunnel target resolves on 1.1.1.1) and `Domain registration` (WHOIS
expiry of the domain, hourly, because Gatus refuses intervals under 5m for this check).

## Outside-in checks

Every route on `envoy-external` resolves its hostname through public DNS (1.1.1.1) instead of the
cluster's split DNS. The probe therefore leaves the cluster, reaches Cloudflare's edge, and comes
back through the tunnel and the external gateway, including its default forward-auth. Because the
tunnel is outbound-only, that is the same path an internet user takes. It catches tunnel,
Cloudflare, public-DNS and external-gateway breakage that an internal check can't see.

What it cannot catch is the home connection being down. In that case Gatus still alerts, but
Matrix (also at home) can't deliver the alert. That gap is covered by the healthchecks.io cloud
check (`docs/healthchecks.md`), which alerts from outside when the cluster stops pinging.

Hostnames that have both an internal and an external route get two checks: the internal one and
an `(external)` twin, for example `Home Assistant` and `Home Assistant (external)`. Routes whose
**first** parentRef is `envoy-internal` (echo, Seerr) are checked internally only. Add a separate
external route or a static check if one of those needs the outside view.

## Annotating a route

Put the annotation on the HTTPRoute. For app-template, that means `route.<id>.annotations` in the
HelmRelease:

```yaml
route:
  app:
    annotations:
      gatus.home-operations.com/endpoint: |
        path: /healthz                 # probe this path instead of the route's
        conditions:                    # replaces the default list
          - "[STATUS] == 200"
          - "[BODY].status == ok"
          - "[RESPONSE_TIME] < 1500"
        name: My App                   # display name (every route sets one)
        extra-labels:
          severity: critical           # alert severity (default warning)
    hostnames: [...]
```

Any [Gatus endpoint field](https://github.com/TwiN/gatus#endpoints) works, including `interval`,
`method`, `headers`, `body`, `client`, `ui`, `maintenance-windows` and `name`. Fields the sidecar
doesn't recognise are passed through unchanged.

| Want | Annotation |
|---|---|
| No check for this route | `gatus.home-operations.com/enabled: "false"` |
| Probe a health endpoint | `path: /health` |
| Check the body, not just the status | `conditions: ["[STATUS] == 200", "[BODY] == OK"]`, or `[BODY].field == value` for JSON |
| Page louder | `extra-labels: {severity: critical}` |
| Display name | `name: Home Assistant`. Set it on every new route; names must stay unique within a group. Charts that can't annotate their route (Homarr) get it through a HelmRelease `postRenderers` patch. |
| TCP check on a Service (no route) | annotate the **Service**: `gatus.home-operations.com/endpoint: \| conditions: ["[CONNECTED] == true"]`. Services are watched opt-in only. |

Current overrides:

| Route | Override | Why |
|---|---|---|
| `healthchecks-machine` | `/api/v3/status/`, body `OK` | proves the app and its DB (this replaced the Kuma keyword monitor) |
| `hookshot` | `/ready`, `[BODY].ready == true` | `/` is a 404 |
| `matrix-media-relay` | `/healthz`, `[BODY].ok == true` | `/` is a 404 |
| `synapse-wellknown` | `/.well-known/matrix/client` | the prefix itself is a 405 |
| `tesla-pubkey` | the `.pem` path, body has `BEGIN PUBLIC KEY` | the only thing the host serves |
| `home-assistant`, `authentik-server` | `severity: critical` | everything else depends on them |
| `authentik-external` | `path: ""` | its first path match is the admin console, which is a 404 at the edge |
| `github-webhook`, `healthchecks-plain-http` | disabled | nothing healthy to probe, or a duplicate |

## Alerts

Gatus has no alerting providers configured. It exports `gatus_results_*` metrics, a ServiceMonitor
scrapes them, and `app/prometheusrule.yaml` alerts through Alertmanager to the Matrix Infrastructure
room. Uptime alerts therefore share grouping, inhibition, silences and the Watchdog dead-man's
switch with every other alert.

| Alert | Fires when | Severity |
|---|---|---|
| `GatusEndpointDown` | an endpoint failed every check for 3m | from the endpoint's `severity` extra-label |
| `GatusCertificateExpiringSoon` | a served certificate has less than 14 days left (cert-manager renews at 30) | warning |
| `GatusDomainExpiringSoon` | domain registration has less than 30 days left (the check itself fails, as critical, at 14) | warning |
| `GatusNoResults` | no results at all for 10m (Gatus down or scrape broken) | critical |

Dashboard: **Gatus — Uptime** in Grafana (`app/resources/dashboard.json`, loaded by the sidecar).
It shows up/down counts, 24h uptime, the nearest certificate and domain expiry, a status timeline
per endpoint, an endpoint table (status, 24h/7d uptime, response time, certificate expiry),
response times, and non-200 responses. Filter it by group and endpoint.

To silence a planned outage, use an Alertmanager silence or a `maintenance-windows` annotation on
the route.

## How it relates to the other monitors

| Tool | Question it answers |
|---|---|
| Gatus | Can a user reach the app through DNS, Envoy and TLS? |
| Healthchecks heartbeats | Are the pods Ready? The optional URL probe goes straight at the Service. |
| Prometheus rules | Is the platform healthy (nodes, PVCs, pods, Flux)? |

If Gatus is down and the heartbeat is up, suspect routing. If both are down, suspect the app.

## Troubleshooting

**A renamed check still shows its old name on the status page.** Gatus keeps the name it first
stored for an endpoint key, and the key is the lowercased group and name, so `sonarr` → `Sonarr`
keeps `sonarr`. Alerts and the dashboard are unaffected, because they use metric labels. To reset
the names, change `storage.path` in `app/resources/config.yaml`; that drops the check history.

```bash
kubectl -n monitoring logs deploy/gatus -c sidecar     # discovery: "updated endpoint ... url=..."
kubectl -n monitoring logs deploy/gatus -c app         # check results and config reload errors
kubectl -n monitoring exec deploy/gatus -c app -- cat /config/gatus-sidecar.yaml
```

Annotation YAML that doesn't parse is caught by the sidecar. It logs the error and leaves that one
route out. Valid YAML that Gatus itself rejects is different: a malformed condition, a duplicate
name in the same group, or an unknown field type. Gatus then exits on reload, and the pod
crash-loops until the annotation is fixed. `GatusNoResults` fires after 10 minutes, and the `app`
log names the endpoint at fault. Check annotation edits with `flux-local` and read the sidecar
output after merging.
