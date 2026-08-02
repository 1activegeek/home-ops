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
ConfigMap by kustomize, and are auto-applied by the Authentik worker. Read
`headlamp-oidc.yaml` or `hermes-oidc.yaml` before writing a new one.

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
- **`forward_auth`** — Authentik authenticates at the Envoy Gateway; **no OAuth2 provider is
  needed**. The `kubernetes/components/authentik-forward-auth` component exists but has no
  in-repo consumer yet, and its SecurityPolicy needs `targetRefs` wired to the app's
  HTTPRoute — copy the `components:` + `replacements:` pattern from
  `kubernetes/apps/security/authentik/app/kustomization.yaml` and expect to work it out.
- **`public_exception` / `external_identity_exception`** — deliberately not behind Authentik.
  Don't add auth; the doc explains why per app.

## Step 2 — Write the blueprint

Get the redirect URI right first — a wrong callback is the most common failure, and Authentik
rejects it in strict mode with an opaque error that doesn't echo what the app sent. Per-app
paths are in `references/app-oidc-patterns.md`; if the app isn't listed, take the path from
its own docs rather than guessing.

Create `kubernetes/apps/security/authentik/app/blueprints/<app>-oidc.yaml`, opening with a
comment block on why this app has SSO and anything odd about its callback or claims — house
style, and what makes these readable a year later.

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
  tokens, not a law — `matrix-oidc.yaml` omits it.
- **`sub_mode`** — `user_email` where the app keys accounts by email, `user_username` where
  it matches on username (Matrix). Changing it later orphans existing accounts, and apps
  that allowlist by `sub` (Gatus's `allowed-subjects`) depend on which one you picked.
- **`client_id` pinned** — any stable 40-char alphanumeric string; a rebuild otherwise
  regenerates a random one and silently breaks the app's stored credential.
- **`client_secret` omitted deliberately** — committing it would put a plaintext secret in
  git. On a live instance Authentik leaves an existing secret untouched, so re-applying never
  disturbs a working provider; on a from-scratch rebuild it generates a new one, which you
  capture into 1Password (Step 4).

Need a claim Authentik doesn't ship (custom groups, a custom `sub`)? Add an
`authentik_providers_oauth2.scopemapping` entry with an inline `expression: |` and reference
it with `!KeyOf` — `headlamp-oidc.yaml` shows it.

## Step 3 — Register the blueprint (the step everyone forgets)

A blueprint file does nothing until it is listed in the ConfigMap generator. Add it to
`configMapGenerator.files` in `kubernetes/apps/security/authentik/app/kustomization.yaml`:

```yaml
configMapGenerator:
  - name: authentik-blueprints
    files:
      - blueprints/setup-passkey.yaml
      - blueprints/<app>-oidc.yaml   # <- add this
```

`passwordless-passkey.yaml` sits in that directory unregistered and has never applied — the
file existing is not the same as it being live. After Flux reconciles (the ConfigMap name is
stable because `disableNameSuffixHash: true`):

```bash
kubectl -n security get cm authentik-blueprints -o jsonpath='{.data}' | grep -o '<app>-oidc.yaml'
kubectl -n security logs deploy/authentik-worker --tail=100 | grep -i blueprint
```

## Step 4 — Capture the client secret into 1Password

Once applied, Authentik has generated the secret. Read it from **Admin → Applications →
Providers → `<app>`**, or via the API if the `authentik` 1Password item carries a token
(check its fields — don't assume a field name):

```bash
AUTHENTIK_TOKEN=$(op item get authentik --vault homeops --format json | jq -r '.fields[] | select(.label|test("token")) | .value')
curl -s -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
  "https://auth.${SECRET_DOMAIN}/api/v3/providers/oauth2/?name=<app>" | jq -r '.results[0].client_secret'
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

## After a rebuild

Blueprints recreate every provider and application automatically; the client secrets are the
one manual step, since Authentik regenerates them. For each app, redo Step 4 and update the
1Password field — the ExternalSecret repopulates within `refreshInterval` (1h), or sooner if
you delete the target Secret. Note this in the PR for any new app so it lands in the recovery
runbook rather than in someone's memory.
