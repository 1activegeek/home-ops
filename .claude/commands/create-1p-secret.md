---
description: Create 1Password secret items for Kubernetes app deployments in the homeops vault
allowed-tools: Bash(op item get:*), Bash(op item create:*), Bash(op item list:*), Bash(op generate password:*), Bash(op vault list:*)
---

Create a 1Password secret item for a Kubernetes application deployment.

## Context

This cluster uses External Secrets Operator with 1Password Connect. All app secrets are stored in the `homeops` vault. Secret items follow a naming convention of `<app-name>` and each field maps to a Kubernetes secret key.

The cluster's ExternalSecret resources reference items by their title in 1Password, and field names map to secret data keys using snake_case.

## Default Password Parameters

Unless the user specifies otherwise, all generated passwords use:
- Length: **30 characters**
- Character set: uppercase letters, lowercase letters, digits, symbols
- `op generate password --length 30 --uppercase --lowercase --digits --symbols`

For apps that can't handle special characters (e.g., SABnzbd API keys), use:
- `op generate password --length 32 --uppercase --lowercase --digits`

For high-security fields (encryption keys, signing secrets, JWT secrets):
- `op generate password --length 64 --uppercase --lowercase --digits --symbols`

## Step 1: Verify 1Password CLI auth

```bash
op account list
```

If this fails or shows no accounts, tell the user to run `eval $(op signin)` in their terminal and retry. If it succeeds, proceed.

Try a quick test:
```bash
op vault list 2>&1
```

If this returns an authorization error or hangs, inform the user that 1Password requires interactive authentication and they should run the command from their terminal directly.

## Step 2: Parse the request

The user will provide one of:
- `app=<name>` — the app name (becomes the 1Password item title)
- `fields=<field1>,<field2>,...` — fields to create
- `vault=<name>` — optional vault override (default: `homeops`)
- `no-symbols` — flag to generate passwords without special characters
- `force` — overwrite if item already exists

If the user just says something like "create secrets for gatus with fields oidc_client_id and oidc_client_secret", extract:
- `app=gatus`
- `fields=oidc_client_id,oidc_client_secret`

## Step 3: Check if item already exists

```bash
op item get "<app-name>" --vault homeops 2>&1
```

If the item exists and `force` was not specified, list its current fields and ask the user whether to overwrite, add fields, or skip.

## Step 4: Determine field types and generate values

For each field, decide the type and generation strategy based on the field name:

| Field name pattern | Type | Generation |
|-------------------|------|------------|
| `*_password`, `*_pass` | `password` | 30 chars, all character types |
| `*_secret`, `*_key` (non-API) | `password` | 64 chars, all character types |
| `*_api_key`, `*api*key*` | `password` | 32 chars, no symbols |
| `*_id`, `*client_id` | `text` | Manual input required — client IDs are assigned by the identity provider, not generated |
| `*_token` | `password` | 64 chars, no symbols |
| `plex_claim` | `text` | Manual only — expires in 4 min, must come from https://plex.tv/claim |
| `*_username`, `*_user` | `text` | Manual input required |
| `*_url`, `*_host`, `*_endpoint` | `text` | Manual input required |
| `*_license*` | `text` | Manual input required |

Fields requiring manual input: prompt the user to provide values, or create the item with placeholder text `REPLACE_ME` and note it.

**Exception for OIDC fields:** `oidc_client_id` and `oidc_client_secret` should BOTH be generated as passwords/text for now. The client_id can be a UUID (generate with `uuidgen | tr '[:upper:]' '[:lower:]'`) and the client_secret as a 64-char password. These will be used when creating the Authentik OIDC provider — Authentik accepts client_id/secret that you supply.

## Step 5: Create the item

Build the `op item create` command:

```bash
op item create \
  --vault homeops \
  --category login \
  --title "<app-name>" \
  "field1[type]=value1" \
  "field2[type]=value2"
```

For fields with generated passwords, pipe through `op generate password`:

```bash
# Example for gatus
CLIENT_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
CLIENT_SECRET=$(op generate password --length 64 --uppercase --lowercase --digits --symbols)

op item create \
  --vault homeops \
  --category login \
  --title "gatus" \
  "oidc_client_id[text]=${CLIENT_ID}" \
  "oidc_client_secret[password]=${CLIENT_SECRET}"
```

## Step 6: Retrieve and display the created item

After creation, fetch the item back and display all field values:

```bash
op item get "<app-name>" --vault homeops --format json | \
  python3 -c "
import sys, json
item = json.load(sys.stdin)
print(f'Item: {item[\"title\"]}')
print(f'ID: {item[\"id\"]}')
print()
for f in item.get('fields', []):
    if f.get('value') and f['purpose'] != 'USERNAME':
        print(f'  {f[\"label\"]}: {f[\"value\"]}')
"
```

## Step 7: Output Kubernetes manifest snippets

After creating the item, output the corresponding ExternalSecret manifest snippet:

```yaml
# ExternalSecret template for <app-name>
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: <app-name>
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: ClusterSecretStore
    name: onepassword-store
  target:
    name: <app-name>-secret
    template:
      data:
        # Map field names to Kubernetes secret keys:
        FIELD_NAME: "{{ .<field_name> }}"
  dataFrom:
    - extract:
        key: <app-name>
```

Also output the HelmRelease envFrom snippet:
```yaml
# In HelmRelease values:
envFrom:
  - secretRef:
      name: <app-name>-secret
```

## Notes

- Never log or store secret values in files — display only in terminal output
- The `homeops` vault is the default for all cluster apps
- Items are titled exactly as `<app-name>` (lowercase, matching the Kubernetes app name)
- Field names use snake_case matching what the ExternalSecret `.template.data` references
- After running this command, also run `/setup-authentik-oidc` if the app uses OIDC
