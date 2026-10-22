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
| `name` | the HTTPRoute name |
| `url` | `https://` + the route's first hostname + its first non-`/` path match |
| `group` | `internal` / `external`, set by the gateway of the route's **first** parentRef |
| defaults | the Gateway's `gatus.home-operations.com/endpoint` annotation (`network/envoy-gateway/app/envoy.yaml`): `[STATUS] == 200`, 1m interval, 30s timeout, `severity: warning` |
| overrides | the route's own `gatus.home-operations.com/endpoint` annotation. It merges over the gateway default, and the route wins. |

Redirects are followed, so an app behind Authentik passes when the Authentik login page renders.
`[STATUS] == 200` is therefore the default for every route.

`app/resources/config.yaml` holds only Gatus' own settings and the few checks that have no route
to annotate. Currently that is one check, `public-dns`.

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
| Rename on the status page | `name: Home Assistant` (names must stay unique within a group) |
| TCP check on a Service (no route) | annotate the **Service**: `gatus.home-operations.com/endpoint: \| conditions: ["[CONNECTED] == true"]`. Services are watched opt-in only. |

**Disable the twin route when one hostname has both an internal and an external route.** In-cluster
split DNS resolves the hostname to `envoy-internal`, so a second probe would repeat the first one.
`home-assistant-external` and `authentik-external` are disabled for this reason.

Current overrides:

| Route | Override | Why |
|---|---|---|
| `healthchecks-machine` | `/api/v3/status/`, body `OK` | proves the app and its DB (this replaced the Kuma keyword monitor) |
| `hookshot` | `/ready`, `[BODY].ready == true` | `/` is a 404 |
| `matrix-media-relay` | `/healthz`, `[BODY].ok == true` | `/` is a 404 |
| `synapse-wellknown` | `/.well-known/matrix/client` | the prefix itself is a 405 |
| `tesla-pubkey` | the `.pem` path, body has `BEGIN PUBLIC KEY` | the only thing the host serves |
| `home-assistant`, `authentik-server` | `severity: critical` | everything else depends on them |
| `github-webhook`, `healthchecks-plain-http`, `*-external` twins | disabled | nothing healthy to probe, or a duplicate |

## Alerts

Gatus has no alerting providers configured. It exports `gatus_results_*` metrics, a ServiceMonitor
scrapes them, and `app/prometheusrule.yaml` alerts through Alertmanager to the Matrix Infrastructure
room. Uptime alerts therefore share grouping, inhibition, silences and the Watchdog dead-man's
switch with every other alert.

| Alert | Fires when | Severity |
|---|---|---|
| `GatusEndpointDown` | an endpoint failed every check for 3m | from the endpoint's `severity` extra-label |
| `GatusCertificateExpiringSoon` | a served certificate has less than 14 days left (cert-manager renews at 30) | warning |
| `GatusNoResults` | no results at all for 10m (Gatus down or scrape broken) | critical |

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
