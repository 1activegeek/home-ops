# Healthchecks (self-hosted cron / heartbeat monitoring)

[Healthchecks](https://healthchecks.io/docs/self_hosted/) at `hc.<domain>`: an internal-only route on `envoy-internal`, in the
`monitoring` namespace. Anything that runs on a schedule (cron jobs, backup scripts, CronJobs,
devices) pings a URL when it finishes. Healthchecks alerts when a ping is late or reports failure.

| | |
|---|---|
| Manifests | `kubernetes/apps/monitoring/healthchecks/` |
| Image | official `docker.io/healthchecks/healthchecks` (UID 999, read-only root FS) |
| Database | shared CNPG cluster, role + database `healthchecks` (`docs/postgres-consolidation.md`) |
| Exposure / auth | `internal` / `forward_auth`. The UI is behind Authentik (passkey) and gated to `tier1`; pings, API and badges are open |
| Secrets | the app's 1Password item (app keys, admin login, seeded API/ping keys); DB password on the shared CNPG item; outbound mail on the shared SMTP relay item |

## How it is put together

- **Login is Authentik.** The UI route (`healthchecks-app`) carries the
  `internal-forward-auth` SecurityPolicy, so Authentik signs you in (passkey) and passes
  `X-authentik-email`. Healthchecks (`REMOTE_USER_HEADER`) then logs in the user with that email and
  creates the account on first sight. That is why the Authentik application is bound to `tier1`.
  Healthchecks' password login is disabled completely.
- **The trusted header is protected in two ways:**
  - The unauthenticated routes (`healthchecks-machine` for `/ping/`, `/api/`, `/badge/` and `/b/`,
    plus the plain-HTTP route) strip every `X-authentik-*` header.
  - A CiliumNetworkPolicy only admits Envoy, Alertmanager and kubelet probes to the pod. Without
    it, any pod could call the Service directly with a forged header and get an admin session.
- **One replica.** The image runs `sendalerts` and `sendreports` as daemons inside the web
  container, so a second replica would send every alert twice.
- **Bootstrap init container** (`app/resources/bootstrap.py`): runs `migrate`, then makes sure
  the admin user exists and re-applies the admin password, the default project's read-write and
  read-only API keys, and its ping key from 1Password. It also declares the "Jobs" project with its own keys. A rebuilt database therefore comes back with
  the same keys that scripts and Alertmanager already hold. A password changed in the UI is
  reverted on the next pod start; change it in 1Password instead. With Authentik login in front, the
  password is only a break-glass credential: it works only if `REMOTE_USER_HEADER` is removed.
- **Probes** hit `/api/v3/status/`, which runs `SELECT 1` against the database and returns `OK`. They set the
  `Host` header explicitly, because Django rejects hosts that are not in `ALLOWED_HOSTS`.
- **Weekly prune CronJob** runs `prunetokenbucket`. Pings, flips and notifications are pruned by
  the app itself.

## Ways to reach it

| Method | URL | Notes |
|---|---|---|
| HTTPS ping | `https://hc.<domain>/ping/<uuid>` or `/ping/<ping-key>/<slug>` | `/start`, `/fail`, `/log` and `/<exit-code>` suffixes; HEAD, GET or POST |
| Plain-HTTP ping | `http://hc.<domain>/ping/...` | For clients that can't do TLS. Only `/ping/` and `/api/` skip the global HTTPS redirect (`envoy-gateway/app/httproute-healthchecks-http.yaml`) |
| Management API | `https://hc.<domain>/api/v3/...` with an `X-Api-Key` header | Read-write (`hcw_…`) and read-only (`hcr_…`) keys live in 1Password. Plain HTTP works, but sends the key in cleartext; prefer HTTPS |
| In-cluster | `http://healthchecks.monitoring.svc.cluster.local:8000/ping/...` | In `ALLOWED_HOSTS`; no DNS, gateway or TLS dependency |
| Slug auto-create | `/ping/<ping-key>/<slug>?create=1` | Creates the check on its first ping (default 1-day period; tune it afterwards) |

Email pings (the built-in SMTP listener) are **not** enabled.

Example for a script:

```sh
curl -fsS -m 10 --retry 5 -o /dev/null "https://hc.<domain>/ping/<ping-key>/nightly-backup/start"
run_backup; rc=$?
curl -fsS -m 10 --retry 5 -o /dev/null --data-raw "exit $rc" "https://hc.<domain>/ping/<ping-key>/nightly-backup/$rc"
```

## Service heartbeats (long-running apps)

Long-running services are covered by the **heartbeat runner**, a `heartbeat` controller in this
HelmRelease (`app/resources/heartbeat.sh`). Scheduled jobs are covered separately, below.
It is still a dead-man's switch: Healthchecks never polls anything. The runner turns each app's own
Kubernetes health checks into pings, and silence alerts.

To opt an app in, annotate its Deployment, StatefulSet or DaemonSet. For app-template apps that's
`controllers.<name>.annotations`; other charts have their own key, such as Authentik's
`server.deploymentAnnotations` or Forgejo's `deployment.annotations`:

```yaml
healthchecks.io/slug: sonarr                                            # required; lowercase [a-z0-9_-]
healthchecks.io/url: http://sonarr.media.svc.cluster.local:8989/ping    # optional, must answer 2xx
healthchecks.io/containers: code-server=ha-code-server                  # optional, "<container>=<slug> ..."
```

`healthchecks.io/containers` adds one more check per listed container. Each one is healthy while that
container is ready in at least one pod. Use it for a sidecar that matters on its own but that the
pod-level check can't name, such as Home Assistant's code-server.

Every 60 seconds, for each annotated workload:

- **Healthy** means at least one pod is Ready (every scheduled pod, for a DaemonSet) and, if a URL is
  set, a GET straight at the Service answers 2xx. The URL skips Envoy, DNS and TLS on purpose:
  that path is Gatus' job (`docs/gatus.md`). So "Gatus down, heartbeat up" points at routing, and both down
  points at the app.
- **Healthy** sends a ping to `/<slug>`.
- **Unhealthy** sends `/<slug>/log` for the first four rounds. That records the failure without
  alerting, so rollouts and `Recreate` restarts don't page. The fifth round sends `/<slug>/fail` with
  the reason, e.g. `0/1 pods Ready (sonarr-…: CrashLoopBackOff)`, and the alert carries it.

Checks are created and updated through the API the first time the runner sees a slug. Each gets
period 2 minutes and grace 5 minutes, all integrations, and the tags `k8s <namespace>`. The runner's own
`heartbeat-runner` check has 1 minute grace, so if the runner dies its alert arrives before the
service checks it feeds go silent.

**Retiring an app:** removing the annotation does not delete the check. The check goes down, which
is correct, because a workload vanishing is exactly what this guards against. Delete the check in
the UI.

The runner reads workloads cluster-wide through a read-only ClusterRole: get/list on
deployments, statefulsets, daemonsets, cronjobs and jobs, plus list on pods for failure reasons. When a URL is set,
the runner calls the Service directly, so the app's network policy has to allow the runner in.

Apps whose network policy admits only Home Assistant are Baby Buddy, Z-Wave JS UI, and code-server,
which listens on loopback. These apps have **no URL** on purpose, because letting the runner in would
widen exactly the boundary the policy exists for. Their deep check is the kubelet's probe instead,
since kubelet probes arrive from the host, which the policies allow. Baby Buddy's readiness probe
loads the login page. Z-Wave JS UI's readiness probe hits `/health/zwave`, so the pod is Ready only
while the Z-Wave driver is up. code-server has a liveness probe on `/healthz`, not a readiness probe,
because a failing readiness probe would pull Home Assistant out of its Service.

## Scheduled jobs (the "Jobs" project)

Backups and other scheduled work live in a second project, **Jobs**, so they don't crowd out the
service checks. `bootstrap.py` declares it with its own API key and ping key (both in the app's
1Password item, `jobs_*` fields) and gives it the same email and Matrix integrations.

**In-cluster CronJobs** are watched by the same heartbeat runner, so job scripts need no changes and
the ping key isn't copied into every namespace. Annotate the CronJob:

```yaml
healthchecks.io/slug: db-backup-forgejo   # required
healthchecks.io/grace: "1200"             # optional, seconds; default 3600
```

CronJobs another controller generates can't be annotated from git. Longhorn's recurring backup and
snapshot jobs are the example here, and they are listed in the runner's `HEARTBEAT_EXTRA_CRONJOBS` env
(`<ns>/<cronjob>=<slug>`) instead.

Each one becomes a **cron-schedule check** with the CronJob's own schedule (UTC unless the CronJob
sets `timeZone`). The runner follows the Jobs it spawns:

| Job event | Ping |
|---|---|
| starts | `/<slug>/start?rid=<job uid>` (Healthchecks then shows run durations) |
| completes | `/<slug>?rid=…`, e.g. `Job db-backup-forgejo-… completed in 14s` |
| fails (backoff limit reached) | `/<slug>/fail?rid=…` with the reason, the containers' exit codes, and a `kubectl logs` hint |
| never runs | nothing. The check goes down once the scheduled time plus grace passes |

On a restart the runner compares finished Jobs with each check's last ping. It reports only a newer
run, so restarts don't replay old successes over a missed one.

**Scripts outside the cluster** (NAS, desktop, cron on another box) ping the Jobs project directly with
its ping key, as in the example above but with `jobs_ping_key`. Add `?create=1` on the first run,
then set the schedule in the UI.

## Watching the watcher

Three layers, each covering a failure the others can't see:

| Layer | Detects | Where it alerts |
|---|---|---|
| `self-check` CronJob (every 5m; `app/resources/self-check.sh`) | Healthchecks, DB, gateway, DNS or TLS broken | Local `healthchecks-self` check, **and** the healthchecks.io cloud check (`/fail` with the reason) |
| healthchecks.io cloud check | the whole cluster or network is dead (the CronJob stops pinging) | healthchecks.io, outside the cluster |
| `alertmanager-watchdog` check | Prometheus or Alertmanager down (the always-firing `Watchdog` alert stops arriving every minute) | Local Healthchecks |
| Gatus `healthchecks-machine` check on `/api/v3/status/` (body `OK`) | Healthchecks UI or API down | Alertmanager → Matrix (`GatusEndpointDown`) |
| `heartbeat-runner` check | the heartbeat runner is dead or can't read the cluster | Local Healthchecks |

The CronJob also upserts the `healthchecks-self` and `alertmanager-watchdog` checks through the
API on every run. Their timeout and grace are therefore defined in git; edits made in the UI are overwritten.

The cloud ping URL is the `cloud_ping_url` field on the app's 1Password item. While it reads
`REPLACE_ME`, the CronJob skips the cloud ping and logs that it did. Suggested cloud check
settings: period 5 minutes, grace 10 minutes.

## Break-glass (Authentik down)

Pings, the API and the self-check keep working, because none of them go through Authentik; only the UI
is unreachable. For UI access without Authentik, remove `REMOTE_USER_HEADER` from the HelmRelease
in a PR. That re-enables password login with `admin_password`.

## Alert delivery

- **Email:** the admin's address is a verified email integration, created at bootstrap. Mail goes out through
  the shared SMTP relay.
- **Matrix:** the `Matrix - Infrastructure` webhook integration posts to the Infrastructure room as
  the `Healthchecks` ghost (with its own icon) through matrix-media-relay. `bootstrap.py` declares it on
  every start; see "Wiring Healthchecks" in `docs/matrix-webhooks.md`.
- **Other webhooks:** `INTEGRATIONS_ALLOW_PRIVATE_IPS=True`, so integrations can target in-cluster
  services such as Home Assistant.

## Rotation

- **API or ping key:** generate a new value in 1Password and restart the pod; the init container
  re-seeds it. The self-check CronJob and Alertmanager read the same fields, so they follow automatically.
  The format must stay `hcw_`/`hcr_` + 28 alphanumerics, and the ping key 22 lowercase alphanumerics.
- **`secret_key`:** the API keys are stored as HMACs keyed by it. Restart the pod so the init container
  re-hashes them; existing login sessions are invalidated.
- **DB password:** rotate the field on the shared CNPG item. The role and the app both read that one field.
