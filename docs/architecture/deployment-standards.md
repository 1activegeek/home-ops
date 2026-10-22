# Deployment Standards

Canonical patterns for deploying any application into this cluster. Any agent or operator adding or changing an app follows this document. Where `AGENTS.md` gives the step-by-step recipe, this document defines the *decisions* — which pattern is the standard, and which observed variants are non-standard.

Companion docs:
- `docs/architecture/authentication.md` — auth mode policy (required reading for any routed app)
- `AGENTS.md` — full add-an-app recipe, validation pipeline, secret workflow

## 1. Directory layout

```
kubernetes/apps/<namespace>/<app>/
├── ks.yaml                  # Flux Kustomization
└── app/
    ├── kustomization.yaml   # lists all app resources (+ components)
    ├── ocirepository.yaml   # chart source (app-template or upstream)
    ├── helmrelease.yaml
    ├── externalsecret.yaml  # if the app needs secrets
    └── httproute*.yaml      # only when route can't live in HelmRelease values
```

- Register the app by adding `./<app>/ks.yaml` to the **namespace** `kustomization.yaml`. There is no top-level `apps/kustomization.yaml`; namespaces are discovered by the root `cluster-apps` Kustomization over the path.
- Namespace `kustomization.yaml` must include `../../components/sops` and `namespace.yaml`.
- One app = one directory = one `ks.yaml`. Do not nest multiple Flux Kustomizations inside an app dir (teslamate is the legacy exception, not a pattern).
- `db-backup/` dirs (raw CronJob manifests per namespace) are the sanctioned non-HelmRelease shape for logical DB dumps.

## 2. Chart sourcing

- **Standard:** bjw-s `app-template` via per-app `OCIRepository` + `spec.chartRef` in the HelmRelease. The app-template version is pinned fleet-wide (currently `5.0.1`) — when bumping, bump everywhere.
- Dedicated upstream charts (operators, infra) also use `OCIRepository` + `chartRef`.
- `HelmRepository` + `spec.chart` is allowed **only** when no OCI distribution exists. (Legacy holdouts: authentik, longhorn, onepassword-connect, tailscale-operator.)
- Every `OCIRepository` **must pin a `tag:`**. Never track a floating ref.
- Raw manifests (no HelmRelease) only for trivial static workloads (tesla-pubkey, connectors, CronJobs).

## 3. ks.yaml (Flux Kustomization)

Standard spec:

```yaml
spec:
  interval: 1h
  path: ./kubernetes/apps/<ns>/<app>/app
  prune: true
  sourceRef: {kind: GitRepository, name: flux-system, namespace: flux-system}
  targetNamespace: <ns>
  wait: false
  postBuild:
    substituteFrom:
      - kind: Secret
        name: cluster-secrets
```

Rules:
- `wait: true` **only** for infra/CRD providers that other apps depend on (flux-operator, longhorn, external-secrets, onepassword-connect, authentik, cert-manager class, CNI/DNS, csi drivers, tailscale-operator, cloudflare-dns).
- `substituteFrom` is `cluster-secrets` only. Add `cluster-1p-secrets` **only when a manifest in that app actually consumes one of its variables** — never copy it in by habit.
- `dependsOn` only for real ordering requirements, but shared infrastructure the app consumes **always counts** — declare it directly, even if another dependency already covers it transitively:
  - contains an `ExternalSecret` → `external-secrets` (namespace `security`; its health check waits for the 1Password store, so this means "secrets can actually be fetched")
  - its own manifests contain a `PersistentVolumeClaim`, or its health check waits on Longhorn-backed storage → `longhorn` (namespace `longhorn-system`). Chart-created PVCs alone don't need it.
  - a CRD or webhook another Kustomization provides (e.g. a `Certificate` → `cert-manager`), the shared CNPG `postgres`, or the IdP
  - Do **not** add app-to-app dependencies for things that only matter at runtime (e.g. the arrs on their download client); pods retry on their own.

  Note the shell-var gotcha: Flux `postBuild` rewrites `${VAR}` — escape `$${VAR}` in scripts.
- `targetNamespace` is always set.
- No per-app `retryInterval`/`timeout` unless there is a documented reason. `retryInterval: 2m` is already set for every Kustomization by the root `cluster-apps` patch, so a failed reconcile (e.g. a webhook not serving yet after a cold boot) retries in minutes instead of waiting a full `interval`.

## 4. HelmRelease

- `interval: 1h`, `chartRef` to the app's OCIRepository.
- **No per-app remediation/rollback blocks.** The root `cluster-apps` Kustomization (`kubernetes/flux/cluster/ks.yaml`) patches every HelmRelease with retry/remediate/cleanupOnFail/rollback-recreate globally. Per-app blocks are redundant drift.
- **No explicit `strategy: RollingUpdate`** — it's the default; stating it is noise.
- `strategy: Recreate` is required for any single-replica workload with a ReadWriteOnce PVC (most stateful app-template apps). Apply it consistently, not selectively.
- `driftDetection` and `valuesFrom` are not used (authentik's `valuesFrom` is the one sanctioned exception).

## 5. Secrets

- **Apps:** `ExternalSecret` → `ClusterSecretStore` `onepassword-store`, `refreshInterval: 1h`, `dataFrom.extract` + `target.template` mapping 1Password snake_case fields to the env names the app expects. Use the `create-1p-secret` skill for new items.
- **Bootstrap/infra only:** SOPS-encrypted `*.sops.yaml` (cert-manager, flux-instance, cloudflare-dns, cloudflare-tunnel, onepassword-connect). Never add SOPS secrets for ordinary apps.
- Never commit plaintext secrets, and never put near-secrets (IPs, redirect URIs, item names) in public docs.

## 6. Networking & routes

- **Standard:** define the route in HelmRelease values (`route:` block) for app-template apps. Separate `httproute.yaml` files only for non-app-template charts or routes needing kustomize `components:` + `replacements:`.
- Hostname convention: `<app>.${SECRET_DOMAIN}` (or `{{ .Release.Name }}.${SECRET_DOMAIN}`).
- Gateways: `envoy-internal` (default, LAN), `envoy-external` (internet via cloudflare-tunnel wildcard).
- File naming: `httproute.yaml` = internal, `httproute-external.yaml` = external.
- **External exposure is a security decision** — `envoy-external` carries a gateway-level default forward-auth SecurityPolicy (`envoy-external-default-auth`). To expose something *without* Authentik, opt out explicitly with the `kubernetes/components/public-access` component. **Never write an inline one-off SecurityPolicy.** Per-route auth is declared as a proxy provider in `kubernetes/apps/security/authentik/app/blueprints/30-proxy-integrations.yaml`, not as a second SecurityPolicy.
- Every routed app declares an auth mode per `docs/architecture/authentication.md` before merge.
- **Internal forward-auth** is opt-in per route via the `kubernetes/components/internal-forward-auth` component (JSON-patch its target to the rendered route name). This component is the sanctioned shape — still no inline one-off SecurityPolicies.
- Remember: the Tailscale subnet router makes *all* internal services tailnet-reachable — "internal" is not "unreachable".

## 7. Storage

- App state → `longhorn` storageClass (the only sanctioned class; `longhorn-nobackup` only with an explicit no-backup rationale).
- Bulk/media data → NFS (csi-driver-nfs).
- Scratch → `emptyDir`.
- PVCs live in HelmRelease `persistence:`; standalone `pvc.yaml` only for raw-manifest workloads.
- Stateful DBs get: Longhorn recurring backups (block) **plus** a logical dump CronJob in the namespace's `db-backup/` dir (pattern: `db-backups` PVC, postgres alpine image, `RETENTION_DAYS=14`).

## 8. Ops hygiene (required on every app-template app)

- `resources.requests` (and limits where sensible)
- liveness/readiness probes
- `securityContext` — default `runAsUser/fsGroup: 65534` unless the image requires otherwise (`task validate:security-ctx` flags mismatches)
- `reloader.stakater.com/auto: "true"` annotation on **any** app consuming an ExternalSecret or ConfigMap
- Image tags: pinned semver only. Never `latest`, `main`, or channel tags. No digests currently — semver is the standard.
- Dashboard tiles live in Homarr's database (managed in its UI), not in Git.

## 8a. Monitoring standard (observability stack, 2026-07)

The stack: **kube-prometheus-stack** (Prometheus + Alertmanager + node-exporter + kube-state-metrics), **Loki** + **Alloy** (logs), **Gatus** (uptime), existing **Grafana** — all in `monitoring`. When deploying a new app, wire it in with these standard hooks (everything is picked up automatically, no central config to edit):

- **Metrics** — enable the chart's `serviceMonitor`/`metrics` values, or ship a `ServiceMonitor`/`PodMonitor` next to the app. Prometheus watches ALL monitors cluster-wide (nil selectors) — no labels or registration needed.
- **Alerts** — ship a `PrometheusRule` CR next to the app; also auto-discovered. Alertmanager delivers to Matrix through a matrix-hookshot generic webhook (see `docs/matrix-webhooks.md`); severity tiers inhibit downward (critical > warning > info). `InfoInhibitor` is nulled; `Watchdog` is routed every minute to the self-hosted Healthchecks `alertmanager-watchdog` check as a dead-man's switch (`docs/healthchecks.md`). (History: this was Discord, then Mattermost `#infrastructure` — both retired.)
- **Logs** — automatic. Alloy (DaemonSet) tails every pod on its node and pushes to Loki with labels `namespace, pod, container, node, app`. Nothing to configure per app.
- **Dashboards** — ConfigMap labeled `grafana_dashboard: "1"` (any namespace) with the JSON under `data:`; the Grafana sidecar auto-loads it. Datasources likewise via `grafana_datasource: "1"`.
- **Uptime** — automatic. Gatus checks every HTTPRoute on `envoy-internal`/`envoy-external` (`gatus.` internal route) through DNS → Envoy → TLS, expecting a 200 after redirects. If the app's `/` isn't a 200, or a health path/body check is better, annotate the route with `gatus.home-operations.com/endpoint` (path, conditions, `extra-labels: {severity: critical}`); `gatus.home-operations.com/enabled: "false"` opts out. Alerts go Gatus metrics → Prometheus → Alertmanager → Matrix. See `docs/gatus.md`.
- **Heartbeats** — key long-running services get the `healthchecks.io/slug` (+ optional `healthchecks.io/url`) annotation on their workload; the heartbeat runner turns readiness into pings. CronJobs (backups, maintenance) get `healthchecks.io/slug` (+ optional `healthchecks.io/grace`) and become cron-schedule checks in the "Jobs" project, fed by the same runner from Job results. Scripts outside the cluster ping the Jobs project directly: `/ping/<jobs-ping-key>/<slug>?create=1`. See `docs/healthchecks.md`.

In-cluster endpoints (for automations/AI analysis):

| Service | Endpoint |
|---|---|
| Prometheus | `http://kps-prometheus.monitoring.svc.cluster.local:9090` |
| Alertmanager | `http://kps-alertmanager.monitoring.svc.cluster.local:9093` |
| Loki | `http://loki.monitoring.svc.cluster.local:3100` |
| Grafana | `http://grafana.monitoring.svc.cluster.local:80` |
| Gatus | `http://gatus.monitoring.svc.cluster.local:8080` |
| Healthchecks | `http://healthchecks.monitoring.svc.cluster.local:8000` |

Prometheus retains 14d/25GB, Loki 14d — both on `longhorn-nobackup` (rebuildable telemetry; the explicit no-backup rationale per §7). Gatus' check history is on `longhorn-nobackup` too — its checks live in git, so the PVC is only history.

## 9. Validation & workflow

1. Branch per change; **never commit to main** — Flux deploys main near-instantly via webhook.
2. `task validate:preflight` before building, `task validate` (or `task validate:all`) before PR.
3. CI only runs `flux-local` — the secrets/images/routes/substitutions/security checks are local-only. Running them is mandatory, not optional.
4. Route/auth changes additionally require the security posture check (`task validate:security`).
5. Renovate config lives in `.renovaterc.json5` (real config: 3-day burn-in gate, weekend schedule, custom managers) plus `renovate.json` (single onepassword-connect pin). Don't add a third.
