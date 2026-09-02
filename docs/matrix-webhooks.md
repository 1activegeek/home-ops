# Matrix webhooks (matrix-hookshot)

Webhook integration for the Matrix stack. Tools push notifications into Matrix
over per-room webhook URLs; Matrix rooms can push events back out over HTTP.

**Important:** webhook connections are stored as **Matrix room state events**
(`uk.half-shot.matrix-hookshot.generic.hook`), not in git and not in a database.
This document is the recovery record for everything that lives outside the repo.

## What's deployed

> **Placeholders in this document.** `${SECRET_DOMAIN}` is a Flux substitution
> variable: it resolves automatically inside `kubernetes/` manifests, but **not**
> in anything pasted into another app's configuration UI. Wherever a snippet is
> destined for an external tool, substitute the real values manually. The real
> domain is deliberately kept out of this repo.


| Piece | Where |
|---|---|
| Hookshot | `kubernetes/apps/tools/hookshot/` — `ghcr.io/matrix-org/matrix-hookshot:7.4.4`, ns `tools` |
| Appservice registration | `kubernetes/apps/tools/synapse/app/externalsecret-appservice.yaml` → secret `hookshot-registration` |
| Synapse wiring | `app_service_config_files: [/as/hookshot-registration.yml]` in `synapse/app/externalsecret.yaml` |
| Route | `hookshot.${SECRET_DOMAIN}` on `envoy-internal` → port 9000 |
| Secrets | 1Password item `hookshot` (`as_token`, `hs_token`, `passkey`) |

Ports: **9000** webhooks (routed, plus `/live` + `/ready` probes), **9001** metrics,
**9993** appservice (`/_matrix/app/*`, cluster-internal only — never routed).

No database, no Redis, no PVC. Hookshot performs no runtime disk writes, so it
runs with `readOnlyRootFilesystem: true` and read-only secret mounts.

## Hard constraints

- **E2EE must stay off.** MAS has no `m.login.application_service`, so encrypted
  bridges cannot authenticate
  ([MAS#2580](https://github.com/element-hq/matrix-authentication-service/issues/2580)).
  Never add an `encryption:` block. Keep notification rooms unencrypted.
  Omitting encryption is also what removes the Redis requirement.
- **Hookshot must be ≥ 7.4.4.** Synapse ≥ 1.139 enforces MSC4190, which broke
  older Hookshot ([#1089](https://github.com/matrix-org/matrix-hookshot/issues/1089),
  fixed in [#1092](https://github.com/matrix-org/matrix-hookshot/pull/1092)).
- **`url` in registration.yml must point at port 9993**, not 9000. Port 9000
  serves a different Express app with no `/_matrix/app/*` routes, so Synapse's
  appservice ping 404s and the bridge is marked down
  ([#1265](https://github.com/matrix-org/matrix-hookshot/issues/1265)).
- **`generic.userIdPrefix` must match the registration `users.regex`** (`_webhooks_`).
- **No `provisioning:` block** — removed in Hookshot 7.x. `listeners.resources`
  accepts only `webhooks`, `widgets`, `metrics`. The rendered upstream docs are
  stale on this point.
- A malformed registration file **crash-loops Synapse**. Roll back the two
  synapse files if that happens.

## Images: matrix-media-relay

Hookshot **cannot send images**. Its generic-webhook result type is text/html
only (no `url`/`info`/`file`), and transformation functions run in QuickJS with
no network, so they cannot upload. Separately, Element destroys any `<img>`
whose `src` is not an `mxc://` URI:

```js
// element-web apps/web/src/Linkify.ts
if (!src.startsWith("mxc://")) { return { tagName, attribs: {} }; }
```

So a remote poster URL can never render, by any combination of webhook JSON.

Apprise *can* upload (`POST /_matrix/media/v3/upload` → `m.image`), but sends the
image and the text as **two separate events** with no caption support. For a
single event carrying both, `kubernetes/apps/tools/matrix-media-relay/` fetches
the artwork, uploads it, and sends one `m.image` with an MSC2530 caption.

The caption only works when `filename` differs from `body` — if they match,
clients render no caption at all.

**Auth:** the relay uses **hookshot's appservice token** to masquerade as the
same `@_webhooks_*` ghost that posts the text-only messages, so notifications
keep one consistent sender. This needs no second appservice registration and
therefore no Synapse restart. Consequence: rotating hookshot's `as_token`
rotates the relay's too. `AS_TOKEN` and `TAUTULLI_API_KEY` are referenced
directly from the `hookshot` and `tautulli` 1Password items rather than copied,
so there is no drift.

The relay is stdlib-only Python mounted from a ConfigMap into a stock `python`
image — no image build, no registry, and Renovate still tracks the base tag.

### Authorization model

Callers are identified by a **per-profile bearer token**. The profile -- not the
request -- decides which ghost sends and which rooms are reachable, so a stolen
token cannot post as another sender or into an unrelated room. Tokens are
compared with `hmac.compare_digest`, and `room` in the payload is optional: when
supplied it must be in the profile's list, otherwise the request is refused with
403 before anything is sent.

Profiles live in `PROFILES` in the HelmRelease (routing, non-secret); each needs
a matching `TOKEN_<NAME>` in the ExternalSecret. A profile with no token is
logged at startup and skipped rather than left open.

**Adding another notification source:**

1. Add a profile to `PROFILES` with its `sender` and `rooms`.
2. Add `TOKEN_<NAME>` to the ExternalSecret, and a `token_<name>` property to
   the `matrix-media-relay` 1Password item.
3. **Invite the ghost to the room.** The relay registers a ghost it has not seen
   before, but an invite-only room cannot be self-joined.

The registration call must pass `inhibit_login: true`. Synapse >= 1.139 enforces
MSC4190, and with MAS in front it rejects an appservice registration without it:

```
IO.ELEMENT.MSC4190.M_APPSERVICE_LOGIN_UNSUPPORTED
This server uses OAuth2, so the inhibit_login parameter must be set to true
for appservice registrations.
```

This is the same MSC4190 enforcement that broke older Hookshot builds. It only
bites the first time a given ghost is created, so a profile reusing a ghost
hookshot already made will appear to work while a genuinely new sender fails.

**Ghost avatars** are declared per profile with `"avatar": "<file>.png"`, and the
PNG lives in the relay's ConfigMap next to `relay.py`. The relay uploads it and
sets `avatar_url` on first use, recording the image's sha256 in the ghost's
account data so restarts do not re-upload -- Synapse mints a fresh `mxc://`
every upload, so an unconditional re-apply would leak media. Replace the PNG and
the next request rolls the avatar over.

Doing it this way keeps the icon reproducible after a homeserver rebuild rather
than being one-off manual state, the same problem the room-state webhooks have.
`avatar-plex.svg` is the editable source; it was rasterized with
`qlmanage -t -s 512`, recolored to Plex's palette, and inset to 58% so Element's
circular crop does not clip the chevron.

Hookshot rewrites display names on restart but never touches avatars, so what
the relay sets here survives (verified by restarting hookshot and re-firing).

Two constraints worth knowing before designing around this:

- Any sender must stay inside hookshot's **exclusive `@_webhooks_*` namespace**,
  because the relay borrows hookshot's appservice token. A different prefix
  (`@_alerts_*`) would need its own appservice registration in
  `synapse/app/externalsecret-appservice.yaml` -- and therefore a Synapse
  restart, which is the operation that caused the outage documented above.
- Ghost display names are owned by hookshot for any name it also uses, so a
  profile sharing a name with a hookshot webhook inherits its `(Webhook)`
  suffix.

### Wiring Tautulli to it

Tautulli's `/pms_image_proxy` requires a **web session**; only the `/api/v2`
command form accepts an API key, which is what the relay calls. `{poster_url}`
is empty unless notification image hosting is enabled, so pass the library path
built from `{rating_key}` instead — the bare `/thumb` path resolves fine.

Webhook URL `http://matrix-media-relay.tools.svc.cluster.local:8080/notify`, POST.

> **Substitute by hand.** Everything below is pasted into Tautulli's own UI, not
> rendered by Flux, so **nothing expands `${SECRET_DOMAIN}`** and no placeholder
> resolves itself. Before saving, replace `${SECRET_DOMAIN}` with the real
> domain, `!YOUR_ROOM_ID` with the target room's ID (Element → Room Settings →
> Advanced), and `<token_plex>` with the value from 1Password (item `matrix-media-relay`). Leaving
> `${SECRET_DOMAIN}` in place sends a literal, invalid room ID and the relay
> rejects it.

JSON Headers:

```json
{"Authorization": "Bearer <token_plex from 1P matrix-media-relay>", "Content-Type": "application/json"}
```

JSON Data (Recently Added):

```json
{"room": "!YOUR_ROOM_ID:matrix.${SECRET_DOMAIN}",
 "img": "/library/metadata/{rating_key}/thumb",
 "text": "New {media_type!c} Available\n\n<movie>{title} ({year}) [{video_full_resolution}] - Runtime: {duration}\n{imdb_url}</movie><episode>{show_name} - S{season_num00}E{episode_num00} - {episode_name} [{video_full_resolution}]\n{thetvdb_url}</episode>",
 "html": "<b>New {media_type!c} Available</b><br><movie><a href=\"{imdb_url}\">{title}</a> ({year}) <span data-mx-color=\"#888888\">[{video_full_resolution}] &middot; {duration}</span></movie><episode><a href=\"{thetvdb_url}\">{show_name}</a> - S{season_num00}E{episode_num00}<br>{episode_name}</episode>"}
```

Omit `img` and the relay sends a plain `m.notice` instead, so it degrades
gracefully for sources with no artwork.

## Known-good noise

Hookshot logs this on **every** start:

```
**WARNING**: The homeserver reports it is unable to contact Hookshot.
This will render Hookshot unusable until fixed.
```

**It is cosmetic — the bridge works.** Verified 2026-08-28: the bot responds to
`!hookshot help`, and every Synapse-side appservice call (`whoami`,
`capabilities`, `profile`, `joined_rooms`) returns 200 under the AS token.

Only Synapse's own self-ping fails, with `ConnectionDone` at ~0.30s. A manual
request from inside the Synapse pod to the same URL succeeds — Hookshot answers
with its own `400 transaction_id did not match`, proving auth passes and the
route exists:

```sh
kubectl -n tools exec deploy/synapse-main -c app -- python3 -c "
import json,urllib.request
tok=[l.split(':',1)[1].strip().strip('\"') for l in open('/as/hookshot-registration.yml')
     if l.strip().startswith('hs_token:')][0]
req=urllib.request.Request('http://hookshot.tools.svc.cluster.local:9993/_matrix/app/v1/ping',
  data=json.dumps({'transaction_id':'test'}).encode(),
  headers={'Authorization':'Bearer '+tok,'Content-Type':'application/json'}, method='POST')
try: print(urllib.request.urlopen(req,timeout=10).status)
except Exception as e: print(type(e).__name__, e, getattr(e,'read',lambda:b'')()[:200])
"
```

Expect `400 transaction_id did not match`. A **404** is the real failure — it
means the registration `url` points at the webhooks listener (9000) instead of
the appservice port (9993). Anything else means the bridge is fine; ignore the
warning.

## Trap: ESO and Helm apply the appservice change separately

This took Synapse down for ~95 minutes on first deploy. It will recur on a
cluster rebuild or any change that touches both halves at once.

`app_service_config_files` lives in the **ExternalSecret** (ESO-managed), while
the `/as` volume that satisfies it lives in the **HelmRelease** (Helm-managed).
They are applied by different controllers with no ordering between them. When
ESO wins the race:

1. ESO syncs the new `homeserver.yaml`; reloader restarts Synapse
2. Synapse crashes — `FileNotFoundError: /as/hookshot-registration.yml`
3. Helm's readiness wait times out and it **rolls back**, which removes the
   volume while the ESO-managed config still demands the file
4. Deadlock. Flux retries the doomed rollback indefinitely (~18 times observed);
   it does **not** self-heal

Recovery — force Helm to the git desired state instead of rolling back:

```sh
flux -n tools reconcile helmrelease synapse --force
```

Synapse comes up immediately, since by then both the volume and the secret exist.

To avoid it entirely when re-introducing this from scratch, land the mount
first: add the `appservice` persistence entry to synapse's HelmRelease in one
commit (harmless on its own — the file is simply unused), then add
`app_service_config_files` in a second commit.

## Trap: duplicate 1Password field labels

ESO's `dataFrom.extract` requires **unique** field labels. Creating the
`hookshot` item with an explicit `notesPlain` field produces a second one
alongside 1Password's native notes field, and both ExternalSecrets fail with:

```
error processing spec.dataFrom[0].extract, err:
expected one 1Password ItemField matching: 'notesPlain' in 'hookshot', got 2
```

Never add `notesPlain` to the item template. Let `op item create` make its own,
then set the text afterwards with `op item edit hookshot notesPlain="..."`.

## Adding a webhook for a new tool

1. Create a room in Element (unencrypted).
2. Invite `@hookshot:matrix.${SECRET_DOMAIN}`.
3. Raise the bot to Moderator (50) so it can send state events.
4. Run `!hookshot webhook <name>` (name 3–64 chars).

The bot confirms in-room and **DMs the secret URL** in an admin room it creates.
Each URL is bound to that one room — this is the per-app/per-room separation.

Other commands: `!hookshot webhook list`, `!hookshot webhook remove <name>`,
`!hookshot help`.

Use the in-cluster URL `http://hookshot.tools.svc.cluster.local:9000/webhook/<hookId>`
for cluster senders, and `https://hookshot.${SECRET_DOMAIN}/webhook/<hookId>`
for LAN senders.

### Payload formatting

Hookshot reads **only** `text`, `html`, and `username` from an incoming payload.
There is no `body` or `message` fallback — anything else is dumped into the room
as a pretty-printed JSON code block.

- **Simple senders** (Home Assistant `rest_command`, n8n HTTP node, shell
  CronJobs): just POST `{"text": "..."}`. Markdown is rendered. No transform.
- **Fixed-schema senders** (Alertmanager, Uptime Kuma, Forgejo): need a JS
  transformation function.

### Transformation functions

They live in the room state event's `transformationFunction` key and must be set
with the client's state-event editor — there is no bot command for this in 7.x.
Scripts run in a sandboxed QuickJS VM with a 2s limit, enabled globally by
`generic.allowJsTransformationFunctions: true`.

Anyone who can send state events in the room can rewrite the script, so keep
room power levels tight.

Assign to `result` using the v2 API. Alertmanager:

```js
const alerts = data.alerts || [];
const rows = alerts.map(a => {
  const icon = a.status === 'firing' ? '🔥' : '✅';
  const l = a.labels || {}, ann = a.annotations || {};
  return `${icon} <b>${l.alertname || 'unknown'}</b> [${l.severity || '-'}] ${l.namespace || ''}<br>` +
         `${ann.summary || ann.description || ''}`;
});
const critical = alerts.some(a => (a.labels || {}).severity === 'critical' && a.status === 'firing');
result = {
  version: "v2",
  empty: rows.length === 0,
  plain: `${data.status}: ${alerts.length} alert(s)`,
  html: rows.join('<br>'),
  msgtype: "m.notice",
  mentions: { room: critical }
};
```

## Outbound (Matrix → HTTP)

`generic.outbound: true` is already set and needs nothing else. Per room:

```
!hookshot outbound-hook <name> <url>
```

Hookshot PUTs `multipart/form-data` — an `event` part with the raw Matrix event
JSON, plus an optional `media` part — with headers `X-Matrix-Hookshot-EventId`,
`-RoomId`, and `-Token`. Authenticate on the token header.

**Every event in the room is forwarded.** The receiver must filter on `type`.

## Room → webhook map

Fill in as webhooks are created. Keep this current — it is the only record
outside room state.

| Room | Source | Direction | Transform | Hook ID stored in |
|---|---|---|---|---|
| _(tbd)_ | Alertmanager | in | yes (above) | 1P `hookshot-hooks` |
| _(tbd)_ | Longhorn backup CronJob | in | no (`{"text": ...}`) | 1P `hookshot-hooks` |
| _(tbd)_ | Uptime Kuma | in | yes | 1P `hookshot-hooks` |
| _(tbd)_ | Forgejo | in | yes | 1P `hookshot-hooks` |

## Verification

```sh
# Appservice ping — a 404 means registration `url` targets the wrong port
kubectl -n tools run curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -XPOST -H "Authorization: Bearer $HS_TOKEN" -H 'Content-Type: application/json' \
  -d '{}' http://hookshot.tools.svc.cluster.local:9993/_matrix/app/v1/ping

# Probes
curl http://hookshot.tools.svc.cluster.local:9000/live    # {"ok":true}
curl http://hookshot.tools.svc.cluster.local:9000/ready   # {"ready":true}

# Round trip
curl -X POST -H 'Content-Type: application/json' -d '{"text":"hello"}' <webhook url>
```

Validate config changes before deploying (needs Docker):

```sh
docker run --rm -v $PWD/config.yml:/config.yml \
  ghcr.io/matrix-org/matrix-hookshot:7.4.4 node config/Config.js /config.yml
```

## Not enabled

Hookshot also ships GitHub, GitLab, Jira, RSS/Atom, and Figma connectors. Each
needs its own `users.regex` namespace in the registration file plus a config
section (and, for GitHub, an OAuth app). The generic webhook covers every
current source. RSS feed resumption across restarts is the one feature that
would justify adding Redis later.
