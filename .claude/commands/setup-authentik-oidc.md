---
description: Set up Authentik OIDC OAuth2 provider and application for a cluster app, create secrets, and update Kubernetes manifests
allowed-tools: Bash(curl:*), Bash(kubectl:*), Bash(op item get:*), Bash(op item edit:*), Bash(cat:*)
---

Configure Authentik OIDC authentication for a new cluster application. This creates the OAuth2 Provider and Application in Authentik, stores credentials in 1Password, creates/updates ExternalSecret manifests, and updates the HelmRelease with OIDC config.

## Cluster Context

- **Authentik URL**: `https://auth.thegeekybits.com` (external) or `http://authentik.security.svc.cluster.local:9000` (internal)
- **Domain**: `thegeekybits.com`
- **Default gateway**: `envoy-internal` for internal apps, `envoy-external` for public apps
- **Secret store**: 1Password vault `homeops`, ClusterSecretStore `onepassword-store`
- **App namespace pattern**: app hostnames follow `<release-name>.thegeekybits.com`

## Step 1: Gather required information

Ask the user for (or infer from context/manifests):
- `APP_NAME` — the app's Kubernetes release name (e.g., `gatus`, `grafana`)
- `NAMESPACE` — the app's namespace (e.g., `monitoring`, `tools`)
- `AUTH_METHOD` — `native_oidc` or `forward_auth` (most apps needing OIDC setup here use native_oidc)
- `AUTHENTIK_TOKEN` — an Authentik API token (see Step 2)

Infer hostname from the app's existing route in `kubernetes/apps/<namespace>/<app>/app/`:
```bash
grep -r "hostnames" kubernetes/apps/<namespace>/<app>/app/
```
Or from the deployed route:
```bash
KUBECONFIG="./kubeconfig" kubectl get httproute -n <namespace> <app> \
  -o jsonpath='{.spec.hostnames[0]}' 2>/dev/null
```

## Step 2: Get or create Authentik API token

Check 1Password for an existing token:
```bash
op item get "authentik" --vault homeops --fields label=api_token 2>/dev/null
```

If no token exists, instruct the user to:
1. Log into Authentik at `https://auth.thegeekybits.com`
2. Go to **Admin Interface** → **Directory** → **Tokens & App Passwords**
3. Create a token with identifier `claude-api-token`, intent: **API**
4. Copy the token key
5. Run: `op item edit "authentik" --vault homeops "api_token[password]=<token>"`

Store the token in variable `AUTHENTIK_TOKEN` for subsequent API calls.

## Step 3: Determine OIDC redirect URI

Based on the app type, the redirect URI follows these patterns:

| App | Redirect URI Pattern |
|-----|---------------------|
| Gatus | `https://<hostname>/authorization-code/callback` |
| Grafana | `https://<hostname>/login/generic_oauth` |
| Forgejo | `https://<hostname>/user/oauth2/authentik/callback` |
| OpenWebUI | `https://<hostname>/oauth/oidc/callback` |
| BookLore | `https://<hostname>/api/auth/oidc/callback` |
| Zipline | `https://<hostname>/api/auth/oauth/oidc` |
| n8n | `https://<hostname>/rest/oauth2-credential/callback` |

For unknown apps, check the app's documentation or use:
`https://<hostname>/auth/callback` as a starting point and note it may need adjustment.

## Step 4: Create the OAuth2 Provider in Authentik

Use the Authentik API. The provider name follows `<APP_NAME>-provider` convention.

First, get the authorization flow ID:
```bash
AUTH_FLOW=$(curl -s -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
  "https://auth.thegeekybits.com/api/v3/flows/instances/?designation=authorization&slug=default-provider-authorization-implicit-consent" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['results'][0]['pk'])")
```

Get the invalidation flow ID:
```bash
INVAL_FLOW=$(curl -s -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
  "https://auth.thegeekybits.com/api/v3/flows/instances/?designation=invalidation" \
  | python3 -c "import sys,json; data=json.load(sys.stdin); print(data['results'][0]['pk']) if data['results'] else print('')")
```

Generate client credentials:
```bash
CLIENT_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
CLIENT_SECRET=$(op generate password --length 64 --uppercase --lowercase --digits --symbols 2>/dev/null \
  || openssl rand -base64 48 | tr -d '=' | head -c 64)
```

Create the provider:
```bash
PROVIDER_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://auth.thegeekybits.com/api/v3/providers/oauth2/" \
  -d "{
    \"name\": \"${APP_NAME}-provider\",
    \"client_type\": \"confidential\",
    \"client_id\": \"${CLIENT_ID}\",
    \"client_secret\": \"${CLIENT_SECRET}\",
    \"redirect_uris\": \"${REDIRECT_URI}\",
    \"authorization_flow\": \"${AUTH_FLOW}\",
    \"sub_mode\": \"hashed_user_id\",
    \"include_claims_in_id_token\": true,
    \"signing_key\": null
  }")

PROVIDER_PK=$(echo "$PROVIDER_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['pk'])")
echo "Created provider PK: $PROVIDER_PK"
```

## Step 5: Create the Authentik Application

```bash
APP_RESPONSE=$(curl -s -X POST \
  -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://auth.thegeekybits.com/api/v3/core/applications/" \
  -d "{
    \"name\": \"${APP_NAME}\",
    \"slug\": \"${APP_NAME}\",
    \"provider\": ${PROVIDER_PK},
    \"meta_launch_url\": \"https://${HOSTNAME}\",
    \"policy_engine_mode\": \"any\"
  }")

APP_SLUG=$(echo "$APP_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['slug'])")
echo "Created application slug: $APP_SLUG"
```

If the application creation fails with a "slug already exists" error, the app already exists — update it instead:
```bash
curl -s -X PATCH \
  -H "Authorization: Bearer ${AUTHENTIK_TOKEN}" \
  -H "Content-Type: application/json" \
  "https://auth.thegeekybits.com/api/v3/core/applications/${APP_SLUG}/" \
  -d "{\"provider\": ${PROVIDER_PK}}"
```

## Step 6: Store credentials in 1Password

Check if item already exists:
```bash
op item get "${APP_NAME}" --vault homeops 2>/dev/null | head -5
```

If item exists, add/update OIDC fields:
```bash
op item edit "${APP_NAME}" --vault homeops \
  "oidc_client_id[text]=${CLIENT_ID}" \
  "oidc_client_secret[password]=${CLIENT_SECRET}"
```

If item doesn't exist, create it:
```bash
op item create \
  --vault homeops \
  --category login \
  --title "${APP_NAME}" \
  "oidc_client_id[text]=${CLIENT_ID}" \
  "oidc_client_secret[password]=${CLIENT_SECRET}"
```

## Step 7: Create or update ExternalSecret manifest

Check if ExternalSecret already exists:
```bash
ls kubernetes/apps/${NAMESPACE}/${APP_NAME}/app/externalsecret.yaml 2>/dev/null
```

**If no ExternalSecret exists**, create `kubernetes/apps/${NAMESPACE}/${APP_NAME}/app/externalsecret.yaml`:

```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: ${APP_NAME}
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-store
  target:
    name: ${APP_NAME}-secret
    template:
      data:
        OIDC_CLIENT_ID: "{{ .oidc_client_id }}"
        OIDC_CLIENT_SECRET: "{{ .oidc_client_secret }}"
  dataFrom:
    - extract:
        key: ${APP_NAME}
```

Update `kubernetes/apps/${NAMESPACE}/${APP_NAME}/app/kustomization.yaml` to include:
```yaml
resources:
  - ./externalsecret.yaml
```

**If ExternalSecret already exists**, add the OIDC fields to the template.data section.

Also add `reloader.stakater.com/auto: "true"` to podAnnotations in the HelmRelease if not already present.

## Step 8: Update the HelmRelease with OIDC config

This step varies significantly by app. Apply the appropriate pattern:

### Gatus (native OIDC)
Add to `helmrelease.yaml` values under `controllers.gatus.containers.app.env`:
```yaml
OIDC_CLIENT_ID:
  valueFrom:
    secretKeyRef:
      name: gatus-secret
      key: OIDC_CLIENT_ID
OIDC_CLIENT_SECRET:
  valueFrom:
    secretKeyRef:
      name: gatus-secret
      key: OIDC_CLIENT_SECRET
```

Add to `configmap.yaml` in the Gatus config YAML:
```yaml
security:
  oidc:
    issuer-url: https://auth.thegeekybits.com/application/o/gatus/
    redirect-url: https://gatus.thegeekybits.com/authorization-code/callback
    client-id: ${OIDC_CLIENT_ID}
    client-secret: ${OIDC_CLIENT_SECRET}
    scopes: [openid, email, profile]
```

### Grafana (native OAuth)
Add to `helmrelease.yaml` in `grafana.ini` section:
```yaml
grafana.ini:
  auth.generic_oauth:
    enabled: true
    name: Authentik
    allow_sign_up: true
    client_id: $__env{OIDC_CLIENT_ID}
    client_secret: $__env{OIDC_CLIENT_SECRET}
    scopes: openid email profile
    auth_url: https://auth.thegeekybits.com/application/o/authorize/
    token_url: https://auth.thegeekybits.com/application/o/token/
    api_url: https://auth.thegeekybits.com/application/o/userinfo/
    role_attribute_path: contains(groups[*], 'authentik Admins') && 'Admin' || 'Viewer'
```

Add `envFrom` in the HelmRelease:
```yaml
envFrom:
  - secretRef:
      name: grafana-secret
```

### Forward-auth apps (Sonarr, SABnzbd, etc.)
Forward-auth is handled at the gateway level via Authentik's proxy provider — no changes needed to the app's HelmRelease. Instead, a separate `SecurityPolicy` or `AuthorizationPolicy` is applied to the HTTPRoute. Document this but don't modify the app manifest.

## Step 9: Output summary

Print a summary:
```
=== OIDC Setup Complete: <APP_NAME> ===

Authentik Application:
  Name: <APP_NAME>
  Slug: <APP_NAME>
  Launch URL: https://<hostname>

OAuth2 Provider:
  Name: <APP_NAME>-provider
  Client ID: <client_id>
  Redirect URI: <redirect_uri>
  Discovery URL: https://auth.thegeekybits.com/application/o/<APP_NAME>/.well-known/openid-configuration

1Password:
  Vault: homeops
  Item: <APP_NAME>
  Fields: oidc_client_id, oidc_client_secret

Manifests updated:
  - kubernetes/apps/<namespace>/<app>/app/externalsecret.yaml (created/updated)
  - kubernetes/apps/<namespace>/<app>/app/helmrelease.yaml (updated with OIDC config)
  - kubernetes/apps/<namespace>/<app>/app/kustomization.yaml (updated if externalsecret added)

Next steps:
  1. git add + git commit the manifest changes
  2. Push to remote and create PR
  3. After Flux reconciles, test auth at https://<hostname>
```
