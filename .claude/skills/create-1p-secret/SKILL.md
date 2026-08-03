---
name: create-1p-secret
description: Create or update a 1Password item in the `homeops` vault for a Kubernetes app in this cluster and wire it into the app's ExternalSecret so the value reaches the pod. Use whenever an app needs a password, API key, token, client secret, connection string, or any env var that must not be committed to git — "add a secret for X", "the app needs an API key", "generate a password for X", "create the ExternalSecret", "store this in 1Password", "1Password item for <app>" — or when a manifest references a Secret field that does not exist yet, when `task validate:secrets` reports a missing 1Password field, or when a pod crashloops on an empty env var that should have come from a secret.
allowed-tools: Bash(op:*), Bash(task:*), Bash(kubectl:*), Read, Write, Edit, Grep, Glob
---

# Create a 1Password secret and map it into the cluster

Secrets live in the 1Password `homeops` vault and reach pods through External Secrets
Operator. Git holds only the reference. Do both halves: put the value in 1Password *and*
wire the ExternalSecret — a 1Password item nobody references is dead weight, and an
ExternalSecret pointing at a field that does not exist renders an empty Secret.

## Step 0 — op-session

Invoke the **op-session** skill before any `op` command, and before `task validate:secrets`
— that task shells out to raw `op item get` once per ExternalSecret, which means 40+
biometric prompts (or a hung shell) if there is no session. Re-invoke it if `op` later
fails with an auth error.

## The naming contract

External Secrets resolves these positionally; a mismatch produces an empty or missing
Secret rather than a useful error.

| Thing | Value | Why |
|---|---|---|
| Vault | `homeops` | The only vault `onepassword-store` searches |
| 1Password item title | the app name, lowercase (`grafana`) | Becomes `dataFrom.extract.key` |
| Field label | `snake_case` (`oidc_client_secret`) | Referenced as `{{ .oidc_client_secret }}`; Go templates cannot resolve a hyphen |
| ExternalSecret `metadata.name` | the app name | Repo convention |
| `target.name` | `<app>-secret` | What the pod's `secretRef` / `secretKeyRef` names |
| File name | exactly `externalsecret.yaml` | `task validate:secrets` globs that literal name — `grafana-externalsecret.yaml` and `externalsecret-dotenv.yaml` exist today and are never validated |
| Secret data key | the env var the app actually reads | See below |

That last row is where the real bugs are. The data key is whatever the *application*
expects, not a tidied-up version of the 1Password label. Headlamp only reads
`HEADLAMP_CONFIG_OIDC_CLIENT_ID`; a bare `OIDC_CLIENT_ID` is ignored, `auth_type` stays
empty, and no login button ever renders. Check the app's docs or chart values first.

## Step 1 — Decide the fields and where each value comes from

Split the fields into generated vs. supplied. Generating a value the provider is supposed
to issue (an OAuth client secret, a license key) yields a credential that authenticates
against nothing.

**Generate** — you own the value:

```bash
op generate password --length 30 --uppercase --lowercase --digits --symbols   # default
op generate password --length 48 --uppercase --lowercase --digits             # API keys, tokens
```

Drop `--symbols` for anything that lands in a URL, a header, or a connection string, and
for apps that mangle them (SABnzbd). Use 64 chars for encryption/signing/JWT keys.

**Ask the user** — the value exists elsewhere: usernames, URLs, license keys, third-party
tokens, `plex_claim` (expires in 4 minutes, from plex.tv/claim), and any OIDC
`client_secret` Authentik generated. Never invent these. If one isn't available yet, create
the field as `REPLACE_ME` and say plainly which fields are placeholders.

**Postgres is the exception.** Per-app database credentials do *not* go in the app's own
item — they live in the `cnpg-postgres` item and surface as a `cnpg-role-<app>`
ExternalSecret in `kubernetes/apps/database/postgres/app/externalsecret.yaml`, alongside a
`managed.roles[]` entry in `cluster.yaml`. See `docs/postgres-consolidation.md`.

## Step 2 — Create or update the item

Check first — a duplicate title breaks `dataFrom.extract`:

```bash
op item get "<app>" --vault homeops --format json 2>/dev/null | jq -r '.fields[].label'
```

```bash
# new item
op item create --vault homeops --category login --title "<app>" \
  "admin_password[password]=$(op generate password --length 30 --uppercase --lowercase --digits --symbols)" \
  "admin_user[text]=admin"

# existing item — edit, never recreate; recreating orphans every other field
op item edit "<app>" --vault homeops "oidc_client_secret[password]=<value>"
```

`[password]` for sensitive values, `[text]` for identifiers and URLs. The type affects
1Password's concealment, not what ESO retrieves. Include the non-secret companions the app
needs (`admin_user` next to `admin_password`) so the whole config arrives from one place.

## Step 3 — Wire it into the manifest

`kubernetes/apps/<ns>/<app>/app/externalsecret.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app>
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-store
  target:
    name: <app>-secret
    template:
      data:
        ADMIN_PASSWORD: "{{ .admin_password }}"
  dataFrom:
    - extract:
        key: <app>
```

`dataFrom.extract` is the default and the only shape `task validate:secrets` inspects.
`data: [{secretKey, remoteRef: {key, property}}]` (with `template.engineVersion: v2`) is
also in use and perfectly valid — for pulling from two different items (`tools/mas`) or
cherry-picking single fields (`home/mosquitto`, `ai/open-webui`). Choose on need; just know
a `data:`-only manifest is skipped by the validator, so check it by hand.

Then close the loop, or the value never reaches the container:

1. Add `- ./externalsecret.yaml` to the app's `app/kustomization.yaml` (repo order:
   ocirepository → externalsecret → helmrelease).
2. Consume it — `envFrom: [{secretRef: {name: <app>-secret}}]`, or per-var
   `valueFrom.secretKeyRef` when only a couple of vars come from the secret.
3. Ensure `reloader.stakater.com/auto: "true"` is on the workload so a rotated value
   restarts the pod instead of sitting stale.

If this is a brand-new app, the ExternalSecret is inert until the app is registered: it also
needs `ks.yaml` (with `postBuild.substituteFrom: cluster-secrets`) and a `./<app>/ks.yaml`
entry in the namespace `kustomization.yaml`. See `docs/architecture/deployment-standards.md`.

## Step 4 — Verify before you commit

```bash
task validate:secrets      # then: task validate:preflight
```

Know its limits so you don't over-trust it: it only reads files named `externalsecret.yaml`,
skips any ExternalSecret without both `dataFrom.extract.key` and `target.template.data`, and
normalizes `_` to `-` when comparing labels — so a hyphenated 1Password label passes
validation and still fails at runtime. Eyeball the labels against the template refs.

If the app is deployed, confirm the Secret actually populated:

```bash
kubectl -n <ns> get externalsecret <app> \
  -o jsonpath='{.status.conditions[*].reason}{"\n"}{.status.conditions[*].message}'
```

A missing *item* raises `SecretSyncedError` (also the symptom of a broken ClusterSecretStore
— read the message, not just the reason). A missing *field* inside a found item is the quiet
one: the Secret syncs successfully with that key empty.

## Guardrails

- Never commit a plaintext secret; keep near-secrets (real hostnames, redirect URIs) out of
  anything under `docs/`. Branch, never commit to main — Flux deploys main via webhook.
- Don't write secret values to files or echo them into the transcript unless the user must
  paste one somewhere manually. Report which fields exist, not what they hold.
- `${VAR}` in a manifest is consumed by Flux post-build substitution. If the *app* needs a
  literal `${VAR}`, escape it as `$${VAR}`.

OIDC client secrets are generated by Authentik, not by you — start with the
**setup-authentik-oidc** skill, which blueprints the provider and then returns here.
