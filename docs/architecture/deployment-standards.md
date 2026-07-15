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
- `dependsOn` only for real ordering requirements (CRDs, an IdP, a DB the app can't start without). Note the shell-var gotcha: Flux `postBuild` rewrites `${VAR}` — escape `$${VAR}` in scripts.
- `targetNamespace` is always set.
- No `retryInterval`/`timeout` unless there is a documented reason.

## 4. HelmRelease

- `interval: 1h`, `chartRef` to the app's OCIRepository.
- **No per-app remediation/rollback blocks.** The root `cluster-apps` Kustomization (`kubernetes/flux/cluster/ks.yaml`) patches every HelmRelease with retry/remediate/cleanupOnFail/rollback-recreate globally. Per-app blocks are redundant drift.
- **No explicit `strategy: RollingUpdate`** — it's the default; stating it is noise.
- `strategy: Recreate` is required for any single-replica workload with a ReadWriteOnce PVC (most stateful app-template apps). Apply it consistently, not selectively.
- `driftDetection` and `valuesFrom` are not used (authentik's `valuesFrom` is the one sanctioned exception).

## 5. Secrets

- **Apps:** `ExternalSecret` → `ClusterSecretStore` `onepassword-store`, `refreshInterval: 1h`, `dataFrom.extract` + `target.template` mapping 1Password snake_case fields to the env names the app expects. Use `/create-1p-secret` workflow for new items.
- **Bootstrap/infra only:** SOPS-encrypted `*.sops.yaml` (cert-manager, flux-instance, cloudflare-dns, cloudflare-tunnel, onepassword-connect). Never add SOPS secrets for ordinary apps.
- Never commit plaintext secrets, and never put near-secrets (IPs, redirect URIs, item names) in public docs.

## 6. Networking & routes

- **Standard:** define the route in HelmRelease values (`route:` block) for app-template apps. Separate `httproute.yaml` files only for non-app-template charts or routes needing kustomize `components:` + `replacements:`.
- Hostname convention: `<app>.${SECRET_DOMAIN}` (or `{{ .Release.Name }}.${SECRET_DOMAIN}`).
- Gateways: `envoy-internal` (default, LAN), `envoy-external` (internet via cloudflare-tunnel wildcard).
- File naming: `httproute.yaml` = internal, `httproute-external.yaml` = external.
- **External exposure is a security decision** — `envoy-external` carries a gateway-level default forward-auth SecurityPolicy (`envoy-external-default-auth`). To expose something *without* Authentik, opt out explicitly with the `kubernetes/components/public-access` component. **Never write an inline one-off SecurityPolicy.** Path-scoped carve-outs use `kubernetes/components/authentik-forward-auth`.
- Every routed app declares an auth mode per `docs/architecture/authentication.md` before merge.
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
- Monitoring: Gatus endpoints are centrally defined in the gatus configmap — when adding a routed app, add its endpoint there. Homepage entries likewise live in homepage's own config.

## 9. Validation & workflow

1. Branch per change; **never commit to main** — Flux deploys main near-instantly via webhook.
2. `task validate:preflight` before building, `task validate` (or `task validate:all`) before PR.
3. CI only runs `flux-local` — the secrets/images/routes/substitutions/security checks are local-only. Running them is mandatory, not optional.
4. Route/auth changes additionally require the security posture check (`task validate:security`).
5. Renovate config lives in `.renovaterc.json5` (real config: 3-day burn-in gate, weekend schedule, custom managers) plus `renovate.json` (single onepassword-connect pin). Don't add a third.
