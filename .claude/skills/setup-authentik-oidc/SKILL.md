---
name: setup-authentik-oidc
description: Set up Authentik OIDC/OAuth2 SSO for an app in this Kubernetes cluster as a committed blueprint (config-as-code), so the provider survives an Authentik rebuild, upgrade, or database loss. Use whenever OIDC, OAuth2, SSO, single sign-on, "log in with Authentik", an identity provider, or a redirect URI comes up — "add SSO to X", "set up auth for the new app", "wire X into Authentik", "create an OAuth provider", "the login button is missing", "the OIDC callback errors" — or when deploying an app whose chart has an OIDC config block, or when a provider created by hand in the Authentik UI needs to be codified.
allowed-tools: Bash(kubectl:*), Bash(curl:*), Bash(op:*), Bash(task:*), Bash(openssl:*), Read, Write, Edit, Grep, Glob
---

# Wire an app into Authentik OIDC — as a blueprint

Authentik providers in this cluster are **declared as blueprints**, never clicked into the
UI and never POSTed to `/api/v3/`. A provider that exists only in Authentik's Postgres
disappears when that database is rebuilt, and nobody finds out until every SSO login in the
house breaks at once. The blueprint is the source of truth; the running instance is a cache.

Blueprints live in `kubernetes/apps/security/authentik/app/blueprints/`, are packed into a
ConfigMap by kustomize, and are auto-applied by the Authentik worker. The whole configuration
is captured there — every provider, application, flow, policy, and portal tile — in five
files grouped by role, not one file per app:

| File | Owns |
|---|---|
| `00-foundation.yaml` | tier groups, custom scope mappings, shared policies |
| `10-auth-experience.yaml` | passkey login, password recovery, invitation enrollment, brand |
| `20-oidc-integrations.yaml` | OIDC providers + their applications |
| `30-proxy-integrations.yaml` | forward-auth providers + embedded outpost membership |
| `40-launcher-apps.yaml` | portal tiles for apps with no provider |

Read `20-oidc-integrations.yaml` before adding to it. Files have no guaranteed apply order —
cross-file dependencies are declared with `authentik_blueprints.metaapplyblueprint`.

## Step 0 — Ground yourself in what actually exists

Requests arrive with the wrong namespace or name me routinely. Confirm before building:

```bash
ls kubernetes/apps                              # real namespaces
ls kubernetes/apps/<ns>/<app>/app/              # does the app exist at all?
grep -rn "hostnames" kubernetes/apps/<ns>/<app>/app/
```

If the app is not deployed yet, say so — this skill is the second half of the job, and the
app needs manifests first (`docs/architecture/deployment-standards.md`). Hostnames are
`<app>.${SECRET_DOMAIN}`; Flux substitutes `${SECRET_DOMAIN}` in blueprints too, so write it
literally.

Then invoke the **op-session** skill — you'll need 1Password in Step 5, and raw `op` prompts
for biometrics on every call.

## Step 1 — Confirm OIDC is the right auth mode

`docs/architecture/authentication.md` classifies every app into four modes. Check it before
building anything.

- **`native_oidc`** — the app speaks OIDC itself. That's this skill; continue.
- **`forward_auth`** — Authentik authenticates at the Envoy Gateway. Add a proxy provider and
  application to `30-proxy-integrations.yaml` and list the provider on the embedded outpost in
  the same file. No client secret is involved; it is used only between the outpost and
  Authentik. External routes are gated **by default** by the SecurityPolicy on
  `envoy-external`, so apps opt *out* with the `public-access` component — a forward-auth app
  usually needs no route change at all.
- **`public_exception` / `external_identity_exception`** — deliberately not behind Authentik.
  Don't add auth; the doc explains why per app.

## Step 2 — Write the blueprint

Get the redirect URI right first — a wrong callback is the most common failure, and Authentik
rejects it in strict mode with an opaque error that doesn't echo what the app sent. Per-app
paths are in `references/app-oidc-patterns.md`; if the app isn't listed, take the path from
its own docs rather than guessing.

Add an entry to `kubernetes/apps/security/authentik/app/blueprints/20-oidc-integrations.yaml`,
with a comment on anything odd about this app's callback or claims — house style, and what
makes these readable a year later.

```yaml
# <App> OIDC — <why this app is gated behind Authentik>.
# client_id is pinned so it survives a rebuild and keeps matching the 1Password item.
# client_secret is intentionally omitted — see below.
version: 1
metadata:
  name: <app>-oidc
entries:
  - model: authentik_providers_oauth2.oauth2provider
    id: provider-<app>
    identifiers:
      name: <app>
    attrs:
      client_type: confidential
      client_id: <pinned stable 40-char alphanumeric string>
      client_secret: !Env AUTHENTIK_OIDC_<APP>_SECRET
      sub_mode: user_email
      include_claims_in_id_token: true
      issuer_mode: per_provider
      grant_types:
        - authorization_code
        - refresh_token
      redirect_uris:
        - matching_mode: strict
          url: https://<app>.${SECRET_DOMAIN}/<callback-path>
      authorization_flow:
        !Find [authentik_flows.flow, [slug, default-provider-authorization-implicit-consent]]
      invalidation_flow:
        !Find [authentik_flows.flow, [slug, default-provider-invalidation-flow]]
      signing_key:
        !Find [authentik_crypto.certificatekeypair, [name, "authentik Self-signed Certificate"]]
      property_mappings:
        - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-openid"]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-profile"]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-email"]]
        - !Find [authentik_providers_oauth2.scopemapping, [managed, "goauthentik.io/providers/oauth2/scope-offline_access"]]

  - model: authentik_core.application
    id: app-<app>
    identifiers:
      slug: <app>
    attrs:
      name: <App>
      provider: !KeyOf provider-<app>
      policy_engine_mode: any
```

Why the fiddly bits matter:

- **`identifiers` vs `attrs`** — `identifiers` is the match key, so re-applying updates the
  existing object instead of duplicating it. That is what makes this idempotent.
- **`signing_key`** — omit it and the provider defaults to HS256, which most clients reject.
- **`property_mappings`** — omit `openid`/`email`/`profile` and `/userinfo` returns nothing,
  so the app can't resolve the user. `offline_access` is a sensible default for refresh
  tokens, not a law — the `matrix` provider omits it.
- **`sub_mode`** — `user_email` where the app keys accounts by email, `user_username` where
  it matches on username (Matrix). Changing it later orphans existing accounts, and apps
  that allowlist by `sub` (Gatus's `allowed-subjects`) depend on which one you picked.
- **`client_id` pinned** — any stable 40-char alphanumeric string; a rebuild otherwise
  regenerates a random one and silently breaks the app's stored credential.
- **`client_secret` via `!Env`** — the value never enters git; only the variable name does.
  It is fed by the `authentik-oidc-clients` ExternalSecret, which reads the same 1Password
  item and field the app itself consumes, so there is still one source of truth per secret.
  This is what makes a from-scratch rebuild work: Authentik comes back holding the secret the
  app is already configured with, instead of generating a fresh one that matches nothing.
  `!Env` takes a **scalar** — `!Env VAR`. The sequence form requires two elements
  (`!Env [VAR, default]`) and raises `IndexError` with one.

Need a claim Authentik doesn't ship (custom groups, a custom `sub`)? Add an
`authentik_providers_oauth2.scopemapping` entry with an inline `expression: |` and reference
it with `!KeyOf` — `headlamp-email-verified` in `00-foundation.yaml` shows it (shared
mappings live there, not next to the provider).

## Step 3 — Map the secret (the step everyone forgets)

The `!Env` reference resolves to nothing unless the variable is projected into the pods. Add
both halves to `kubernetes/apps/security/authentik/app/externalsecret-oidc.yaml`:

```yaml
  target:
    template:
      data:
        AUTHENTIK_OIDC_<APP>_SECRET: "{{ .<app> }}"   # <- add
  data:
    - secretKey: <app>                                # <- and this
      remoteRef:
        key: <app>
        property: oidc_client_secret
```

Because the five blueprint files are already registered in `configMapGenerator`, adding an
app needs no `kustomization.yaml` change. Verify after Flux reconciles:

```bash
kubectl -n security get cm authentik-blueprints -o jsonpath='{.data}' | grep -o '20-oidc-integrations.yaml'
kubectl -n security get secret authentik-oidc-clients -o jsonpath='{.data}' | tr ',' '\n' | grep <APP>
```

## Step 4 — Create the client secret in 1Password

You generate the secret up front now, rather than reading back whatever Authentik invented —
the blueprint pins it, so both sides agree from the first apply:

```bash
openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64; echo
```

Then hand off to the **create-1p-secret** skill — it owns the naming contract. Item `<app>`
in vault `homeops`, fields `oidc_client_id` (text, the pinned value) and `oidc_client_secret`
(password), surfaced through `kubernetes/apps/<ns>/<app>/app/externalsecret.yaml` into Secret
`<app>-secret`, with data keys named whatever *this app* reads.

## Step 5 — Wire the app itself

In `kubernetes/apps/<ns>/<app>/app/helmrelease.yaml` (or the config the ExternalSecret
templates). Every app needs the same three facts:

- issuer `https://auth.${SECRET_DOMAIN}/application/o/<app>/`
  (discovery: `.../.well-known/openid-configuration`)
- client id + secret from `<app>-secret`
- scopes `openid email profile`

Injection patterns per app — env prefixes, `grafana.ini`, templated config files, and the
`$${VAR}` escaping trap — are in `references/app-oidc-patterns.md`. Two things easy to miss:
set the app's own authorization rule (allowed users/groups) so SSO doesn't mean "any
Authentik user gets in", and confirm `reloader.stakater.com/auto: "true"` is on the workload
so a rotated secret restarts it.

## Step 6 — Validate, then PR

```bash
task validate:preflight    # needs a live 1Password session and NFS reachability
```

**Branch, never commit to main** — Flux deploys main near-instantly via webhook, so a bad
blueprint hits the live Authentik before review. Update the app's row in
`docs/architecture/authentication.md` and `docs/deployment-plan.md`, open a PR, and test a
real login at `https://<app>.${SECRET_DOMAIN}` once Flux reconciles.

Debug in this order: worker logs for blueprint errors → provider exists with the expected
`client_id` → redirect URI matches the app's request byte for byte → Secret data keys match
what the app reads.

## Verify the blueprint before it ships

`Importer.validate()` runs inside a rolled-back transaction, so it is safe against the live
instance:

```bash
W=$(kubectl get pods -n security -o name | grep worker | head -1)
kubectl exec -n security ${W#pod/} -- ak shell -c '
from authentik.blueprints.v1.importer import Importer
ok, logs = Importer.from_string(open("/blueprints/mounted/cm-authentik-blueprints/20-oidc-integrations.yaml").read()).validate()
print("valid:", ok)
for l in logs:
    if l.log_level in ("warning", "error"): print(l.event)
'
```

## After a rebuild

Nothing manual. Providers, applications, flows, and tiles come back from the blueprints, and
client secrets come back from 1Password via `authentik-oidc-clients` — so each app finds the
credential it already holds. What does **not** come back is user data: accounts, group
membership, and enrolled passkeys/TOTP devices. Users re-enrol, or you restore the database.

Full procedure: `docs/authentik-disaster-recovery.md`.
