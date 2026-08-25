# Authentik Disaster Recovery

## What is recoverable

Everything Authentik needs to serve SSO is declared in
`kubernetes/apps/security/authentik/app/blueprints/`. A rebuild from an empty database reproduces:

- OIDC providers and their applications, with the **same client IDs and client secrets** the
  applications already hold
- Forward-auth proxy providers and their membership in the embedded outpost
- The passkey login flow, password recovery, and invitation enrollment, with every stage and policy
- Access-tier groups and the brand
- All portal tiles

What is **not** in blueprints, by design:

| Not recovered | Why | Impact |
|---|---|---|
| User accounts | User data, not configuration | Recreate accounts, or restore the DB |
| Group membership | Would be reconciled away on every apply | Re-add members |
| Registered passkeys / TOTP devices | Bound to the old instance's credentials | Users re-enroll |
| Signing certificates | Authentik generates its own on first boot | New keys; OIDC clients re-fetch JWKS automatically |

So a blueprint-only rebuild gives you a working IdP with every integration wired, and users
re-enrolling their credentials. A database restore gives you everything including users.

## Rebuild from blueprints

1. Ensure the `authentik` and `authentik-oidc-clients` secrets resolve (they come from 1Password via
   External Secrets). Without the second one, providers come back with no client secret and every
   integration fails.
2. Let Flux reconcile the HelmRelease. The chart mounts the blueprint ConfigMap at
   `/blueprints/mounted/cm-authentik-blueprints/`.
3. The worker discovers all five files, registers a `BlueprintInstance` for each, and applies them.
   `00-foundation.yaml` is pulled in first by the `metaapplyblueprint` dependency the others declare.
4. Confirm every blueprint applied:

```bash
W=$(kubectl get pods -n security -o name | grep worker | head -1)
kubectl exec -n security ${W#pod/} -- ak shell -c '
from authentik.blueprints.models import BlueprintInstance
for b in BlueprintInstance.objects.filter(path__startswith="mounted"):
    print(b.status, b.path)
'
```

All five must report `successful`. A blueprint that reports an error retries on the next hourly
discovery run.

5. Create an admin user (`ak create_admin_group` / the recovery flow) and re-enrol credentials.

## Restore from database backup

The `db-backup` CronJob dumps the Authentik database nightly. To take one on demand:

```bash
PG=$(kubectl get pods -n security -o name | grep postgresql | head -1)
kubectl exec -n security ${PG#pod/} -- bash -c \
  'PGPASSWORD=$(cat $POSTGRES_PASSWORD_FILE) pg_dump -U authentik -d authentik' > authentik-$(date +%F).sql
```

Restore procedure is in [`database-dumps-restore.md`](./database-dumps-restore.md).

Note: the `postgres` superuser password stored in the chart's secret does **not** match the database
(the mapping is commented out in the HelmRelease, so the chart generated one after the volume was
already initialised). Use the `authentik` role for dumps and restores.

## Rolling back a bad blueprint change

Blueprints do **partial** updates - they only touch fields they name, and they never delete. So a bad
change is a field-level problem, not a destroyed object.

1. Revert the commit. Flux re-applies the previous ConfigMap and the worker reconciles within a
   minute.
2. If that is not enough, remove the file from `configMapGenerator` in `kustomization.yaml`. Authentik
   stops managing those objects and they freeze in place.
3. Only if both fail, restore the database dump.

## Rehearsing a rebuild

The only test that actually proves recovery works is standing up an instance with an empty
database and comparing it to production. Blueprint validation does not catch what this does —
the first rehearsal found that the whole login experience was silently lost.

```bash
kubectl create namespace authentik-dr

# the exact blueprints and OIDC secrets production is running
kubectl get cm authentik-blueprints -n security -o yaml \
  | sed 's/namespace: security/namespace: authentik-dr/' | kubectl apply -f -
kubectl get secret authentik-oidc-clients -n security -o json \
  | jq '{apiVersion,kind,type,data,metadata:{name:.metadata.name,namespace:"authentik-dr"}}' \
  | kubectl apply -f -

helm install authentik-dr authentik/authentik --version <same as HelmRelease> -n authentik-dr \
  --set-json 'global.envFrom=[{"secretRef":{"name":"authentik-oidc-clients"}}]' \
  --set 'blueprints.configMaps[0]=authentik-blueprints' \
  --set authentik.secret_key=throwaway --set authentik.postgresql.password=throwaway \
  --set postgresql.enabled=true --set postgresql.auth.password=throwaway \
  --set postgresql.primary.persistence.enabled=false \
  --set server.route.main.enabled=false
```

Every blueprint must report `successful`:

```bash
DW=$(kubectl get pods -n authentik-dr -l app.kubernetes.io/component=worker -o name)
kubectl exec -n authentik-dr ${DW#pod/} -- ak shell -c '
from authentik.blueprints.models import BlueprintInstance
for b in BlueprintInstance.objects.filter(path__startswith="mounted"):
    print(b.status, b.path)
'
```

Then compare object inventories. Compare by **natural key** (slug/name), never by primary key —
those differ between instances — and resolve foreign keys to names first, or the diff is noise.
Expect these to differ legitimately:

- user accounts, group membership, enrolled passkeys and TOTP devices (not blueprinted)
- proxy provider `client_id`/`client_secret` (generated per instance; used only between the
  embedded outpost and authentik, so nothing external depends on them)
- primary keys on authentik's own default notification rules and roles

Tear down with `kubectl delete namespace authentik-dr && helm uninstall authentik-dr -n authentik-dr`.

**Watch for the failure mode this catches:** a single invalid entry rolls back its *entire*
blueprint file (`Importer.apply()` wraps everything in one transaction). One bad object does not
degrade gracefully - it takes every object in that file with it.

## Verifying a change before it ships

`Importer.validate()` runs inside a rolled-back transaction, so it is safe against production. To
prove a blueprint is a no-op, apply it inside a transaction and diff the full export before and
after - `Exporter().export_to_string()` on both sides, compared by `(model, pk)` rather than by line,
since export ordering is not stable.
