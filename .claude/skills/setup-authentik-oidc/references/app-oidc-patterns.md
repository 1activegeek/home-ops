# Per-app OIDC patterns

Two things vary by app: the **callback path** Authentik must allow, and **where the client
credentials get injected**. Issuer, scopes, and blueprint shape are uniform.

## Callback paths

Committed in this cluster (verified against the blueprints):

| App | Redirect URI |
|---|---|
| Headlamp | `https://headlamp.${SECRET_DOMAIN}/oidc-callback` |
| Hermes | `https://hermes.${SECRET_DOMAIN}/auth/callback` |
| Matrix (via MAS) | `https://mas.${SECRET_DOMAIN}/upstream/callback/<mas-provider-ulid>` |

Documented upstream, not blueprinted here — verify against the app's current docs, since
callback paths move between major versions:

| App | Redirect URI |
|---|---|
| Grafana | `https://<host>/login/generic_oauth` |
| Gatus | `https://<host>/authorization-code/callback` |
| Forgejo | `https://<host>/user/oauth2/authentik/callback` |
| Open WebUI | `https://<host>/oauth/oidc/callback` |
| n8n | `https://<host>/rest/oauth2-credential/callback` |
| Zipline | `https://<host>/api/auth/oauth/oidc` |
| BookLore | `https://<host>/api/auth/oidc/callback` |

For anything unlisted, read the app's docs. Guessing costs a full blueprint → commit → Flux
→ test cycle to disprove, and the failure page doesn't tell you what the app actually sent.
To confirm empirically, start a login in a browser and read the `redirect_uri` query
parameter off the Authentik URL.

## The escaping trap — read before writing any config

Flux post-build substitution expands `${...}` in every manifest under `kubernetes/`. That's
why `${SECRET_DOMAIN}` works. It also means any `${VAR}` the *application* is supposed to
expand at runtime must be written `$${VAR}`, or Flux eats it and the app receives an empty
string. This bites hardest in templated config files where the OIDC credentials are
interpolated by the app itself.

## Injection patterns

### Env vars behind an app-specific prefix (Headlamp)

Many apps read config only under a private prefix and ignore the obvious name in silence.
Headlamp parses with koanf under `HEADLAMP_CONFIG_`, so a bare `OIDC_CLIENT_ID` leaves
`auth_type` empty and no login button renders.

```yaml
# externalsecret.yaml
target:
  name: headlamp-secret
  template:
    data:
      HEADLAMP_CONFIG_OIDC_CLIENT_ID: "{{ .oidc_client_id }}"
      HEADLAMP_CONFIG_OIDC_CLIENT_SECRET: "{{ .oidc_client_secret }}"
```

Issuer and scopes go in the HelmRelease as plain env:
`HEADLAMP_CONFIG_OIDC_IDP_ISSUER_URL: https://auth.${SECRET_DOMAIN}/application/o/headlamp/`,
`HEADLAMP_CONFIG_OIDC_SCOPES: openid,email,profile`.

### Config file that interpolates env (Grafana)

Grafana reads secrets via `$__env{}`, so credentials stay in the Secret and `grafana.ini`
stays committable. Working example already in the repo:
`kubernetes/apps/monitoring/grafana/app/helmrelease.yaml` (`auth.generic_oauth` — note
`role_attribute_path` maps Authentik groups to Grafana roles, which needs the `profile`
scope mapping present on the provider). Pair it with
`envFrom: [{secretRef: {name: grafana-secret}}]`.

### Credentials rendered into a config file (Gatus, MAS)

Apps wanting YAML rather than env can have the whole file rendered by the ExternalSecret
template, keeping the secret out of any ConfigMap — `kubernetes/apps/tools/mas/app/externalsecret.yaml`
shows the technique (`config.yaml` as one templated key). Gatus's block, with the escaping
applied:

```yaml
security:
  oidc:
    issuer-url: https://auth.${SECRET_DOMAIN}/application/o/gatus/
    redirect-url: https://gatus.${SECRET_DOMAIN}/authorization-code/callback
    client-id: $${OIDC_CLIENT_ID}
    client-secret: $${OIDC_CLIENT_SECRET}
    scopes: [openid, email, profile]
    allowed-subjects: ["<the sub claim your provider emits>"]
```

`allowed-subjects` is the authorization half — without it, every Authentik user gets in. Its
values must match the provider's `sub_mode` (emails for `user_email`, usernames for
`user_username`); a mismatch locks you out of your own status page.

### Auth source lives in the app's own database (Forgejo)

Some apps store the identity provider as a DB row with no config-file equivalent, so it
cannot be declared. The Authentik half still gets a blueprint; only the app-side binding is
manual. The recreate command is documented next to the HelmRelease at
`kubernetes/apps/tools/forgejo/app/helmrelease.yaml` — keep it there, not here.

### Forward auth (no provider at all)

If `docs/architecture/authentication.md` classifies the app as `forward_auth`, there is no
OAuth2 provider to create. Authentik authenticates at the Envoy Gateway via
`kubernetes/components/authentik-forward-auth`. No app consumes it yet, and its
SecurityPolicy needs `targetRefs` pointed at the app's HTTPRoute — mirror the `components:`
+ `replacements:` wiring in `kubernetes/apps/security/authentik/app/kustomization.yaml`.
