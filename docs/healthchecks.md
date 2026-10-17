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
  the admin user exists and re-applies the admin password, the project's read-write and
  read-only API keys, and its ping key from 1Password. A rebuilt database therefore comes back with
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

## Watching the watcher

Three layers, each covering a failure the others can't see:

| Layer | Detects | Where it alerts |
|---|---|---|
| `self-check` CronJob (every 5m; `app/resources/self-check.sh`) | Healthchecks, DB, gateway, DNS or TLS broken | Local `healthchecks-self` check, **and** the healthchecks.io cloud check (`/fail` with the reason) |
| healthchecks.io cloud check | the whole cluster or network is dead (the CronJob stops pinging) | healthchecks.io, outside the cluster |
| `alertmanager-watchdog` check | Prometheus or Alertmanager down (the always-firing `Watchdog` alert stops arriving every minute) | Local Healthchecks |
| Uptime Kuma monitor on `/api/v3/status/` | Healthchecks UI or API down | Uptime Kuma |

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
- **Matrix / webhooks:** `INTEGRATIONS_ALLOW_PRIVATE_IPS=True`, so webhook integrations can target
  in-cluster services such as matrix-hookshot (`docs/matrix-webhooks.md`) or Home Assistant.

## Rotation

- **API or ping key:** generate a new value in 1Password and restart the pod; the init container
  re-seeds it. The self-check CronJob and Alertmanager read the same fields, so they follow automatically.
  The format must stay `hcw_`/`hcr_` + 28 alphanumerics, and the ping key 22 lowercase alphanumerics.
- **`secret_key`:** the API keys are stored as HMACs keyed by it. Restart the pod so the init container
  re-hashes them; existing login sessions are invalidated.
- **DB password:** rotate the field on the shared CNPG item. The role and the app both read that one field.
