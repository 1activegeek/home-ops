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
3. Drop the icon PNG next to `relay.py`, add it to the `matrix-media-relay-avatars`
   generator and its mount, and reference it as `"avatar"` on the profile.

That is the whole procedure for a **public** room: at startup the relay
registers the ghost and joins it to every room in its profile, because Synapse
rejects a send from a non-member with 403 regardless of the join rule.

**Identity is applied at startup, not on first send, and that ordering is
load-bearing.** `PUT /profile/{user}/avatar_url` returns as soon as the profile
row is written; Synapse then fans the change out into an `m.room.member` event
per room *in the background*. Clients render a message's sender from the member
state **at that event**, so a send that beats the fan-out is displayed with no
avatar — permanently, because the timeline is immutable. Doing it lazily inside
the first request lost that race every time, which is why the first Uptime Kuma,
Longhorn and Cloudflare messages show letter avatars and always will:

```
01:33:15 _uptimekuma  MEMBER   avatar=NO -> NO
01:33:15 _uptimekuma  MESSAGE  ✅ Up - relay round-trip test      <- no avatar
01:33:15 _uptimekuma  MEMBER   avatar=NO -> yes                  <- 200ms too late
```

`prepare_profiles()` now runs before the listener opens, and
`_await_member_avatar` polls the room member event until the new `mxc://`
actually appears (`MEMBER_SYNC_TIMEOUT`, default 10s). It is only paid when an
avatar genuinely changed, so a normal restart waits for nothing. The readiness
probe is what makes a synchronous startup safe: nothing is routed to the pod
until the HTTP server is up. The timeout is bounded well inside the liveness
budget (~100s) even if every profile changed at once, and a timeout is logged
and ignored — a missing icon is worth far less than a dropped notification.

**Note this cannot be repaired retroactively.** There is no way to refresh the
icon on an already-sent message; only new messages pick up current state.

An **invite-only** room still needs the ghost invited first — the join call
accepts a pending invite but cannot manufacture one. The failure is logged with
the sender and room and then skipped, so the send that follows reports the real
error rather than being masked by it.

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

**Display names are declared per profile** with `"displayname": "<name>"`.
Without one a ghost shows up as its raw localpart (`_webhooks_requests`),
because Synapse sets a new user's display name to the localpart at
registration. Unlike the avatar this is re-asserted on **every** send rather
than cached: hookshot owns the name of any ghost one of its own webhook
connections uses and re-applies its `<name> (Webhook)` form on restart, so
re-checking is what wins the name back afterwards. The cost is one GET per
notification.

Dropping the `(Webhook)` suffix permanently is a **rename**, not a deletion.
Hookshot derives its ghost as `@<userIdPrefix><name lowercased, stripped>` and
hardcodes `<name> (Webhook)`, re-applying it on every message it sends through
that connection. So a connection named `Plex` owns `@_webhooks_plex` and will
keep reclaiming it. Renaming that connection to `Tautulli` moves it onto
`@_webhooks_tautulli` and leaves `@_webhooks_plex` to the relay for good —
which is what was done here. Deleting the connection would work too, but costs
the webhook URL for no extra benefit.

**Ghost avatars are declared per profile** with `"avatar": "<file>.png"`, the PNG
living in the relay's ConfigMap next to `relay.py`. This is the intended path for
giving every notification source its own icon: adding a webhook is one profile
entry, its `TOKEN_<NAME>`, and its PNG. The relay uploads it and
sets `avatar_url` on first use, recording the image's sha256 in the ghost's
account data so restarts do not re-upload -- Synapse mints a fresh `mxc://`
every upload, so an unconditional re-apply would leak media. Replace the PNG and
the next request rolls the avatar over.

**Room avatars are not managed here** -- they are set once against the
homeserver and left in room state, which the nightly Synapse `pg_dump` and the
Longhorn PVC backups already cover. To set one by hand:

```
POST /_matrix/media/v3/upload?filename=x.png                 -> {"content_uri": "mxc://..."}
PUT  /_matrix/client/v3/rooms/{roomId}/state/m.room.avatar/?user_id={sender}
     {"url": "mxc://..."}
```

`m.room.avatar` requires **PL50** and the `@_webhooks_*` ghosts sit at
`users_default` (0), so use the hookshot bot, which holds PL50.

That asymmetry is deliberate: a ghost icon is reproducible from the ConfigMap
after a homeserver rebuild, a room avatar is not -- like the webhook connections
themselves, it lives only in room state.

A hand-made icon keeps its `.svg` next to it as the editable source, rasterized
with `qlmanage -t -s 512`: `avatar-plex.svg` was recolored to Plex's palette and
inset to 58% so Element's circular crop does not clip the chevron. Where the
source project already ships a square icon, vendor that instead of redrawing it
-- `avatar-requests.png` is Seerr's own `public/android-chrome-512x512.png`,
copied verbatim, so it has no `.svg` beside it.

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

### Poster sources: Tautulli paths vs absolute URLs

`img` accepts either form and the relay picks the fetcher:

- a **relative Plex library path** (`/library/metadata/.../thumb`) is proxied
  through Tautulli's `/api/v2` command form, which is the only one that accepts
  an API key;
- an **absolute `http(s)` URL** is fetched directly, but only if its host is in
  `IMAGE_HOSTS`. Sources that hand out public artwork links (Seerr's TMDB URLs)
  use this path.

The allowlist is load-bearing, not tidiness: the relay sits inside the cluster,
so an unrestricted fetcher would be an SSRF pivot onto every internal service.
For the same reason redirects are **refused rather than followed** — an
allowlisted host that 302s elsewhere would otherwise walk straight past the
check. Add a host to `IMAGE_HOSTS` in the HelmRelease to onboard another
artwork source.

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


### Wiring a request manager (Seerr) to it

Seerr's **Webhook** notification agent posts a user-defined JSON body, which
means it can talk to the relay directly with no transformation function. It is a
separate profile from Plex on purpose: its own bearer token, its own
`@_webhooks_*` ghost and avatar, so "requested/approved" traffic is visually
distinct from "new media available" in the same room.

> **Substitute by hand.** This is pasted into Seerr's own UI, so **nothing
> expands `${SECRET_DOMAIN}`** and no placeholder resolves itself. Replace the
> domain, the room ID (Element → Room Settings → Advanced), and the token (1P
> item `matrix-media-relay`, property `token_requests`) before saving.

Settings → Notifications → Webhook:

| Field | Value |
|---|---|
| Webhook URL | `http://matrix-media-relay.tools.svc.cluster.local:8080/notify` |
| Authorization Header | `Bearer <token_requests>` |
| Notification Types | only the ones wanted (e.g. auto-approved, available) |

JSON payload template. Seerr's stock template is a flat dump of every variable
it knows; the relay reads only `room`, `text`, `html`, and `img`, so the useful
conversion is to spend those variables on one rendered card rather than carry
the unread keys:

```json
{
  "room": "!YOUR_ROOM_ID:matrix.${SECRET_DOMAIN}",
  "img": "{{image}}",
  "text": "{{event}}\n\n{{subject}}\nRequested by {{requestedBy_username}}\n\n{{message}}",
  "html": "<b>{{event}}</b><br><a href=\"https://www.themoviedb.org/{{media_type}}/{{media_tmdbid}}\">{{subject}}</a><br><span data-mx-color=\"#888888\">Requested by {{requestedBy_username}}</span><blockquote>{{message}}</blockquote>"
}
```

`{{event}}` already reads as the headline ("Movie Request Automatically
Approved", "Movie Now Available"), `{{subject}}` is the title and year, and
`{{media_type}}` is `movie` or `tv` — which is exactly TMDB's own URL segment,
so the title links to the right page with no mapping table.

Four things to know before editing that template:

- **`{{image}}` is an absolute TMDB URL**, so `image.tmdb.org` has to be in
  `IMAGE_HOSTS` or the relay rejects the request and nothing is posted. It is
  there by default. An empty `img` degrades to a plain `m.notice`, which is
  what a test event (no media attached) produces.
- Substitution is a plain **first-occurrence** `String.replace` per key, so a
  placeholder repeated inside one value only expands once. Repeat it across
  different keys instead, as `text` and `html` do above.
- Seerr renders **one template for every enabled notification type**, so the
  wording has to work for all of them — `{{event}}` is what distinguishes
  them at runtime. Wanting genuinely different text per type means a second
  webhook agent, which Seerr does not support; use `{{event}}` instead.
- Configuring this over the API rather than the UI means knowing that `types`
  is a **bitmask** of the `Notification` enum in `server/lib/notifications/`
  (`MEDIA_AVAILABLE = 8`, `MEDIA_AUTO_APPROVED = 128`, so both is `136`), and
  that `options.jsonPayload` is posted as a **JSON string** which the server
  double-encodes before storing — `JSON.parse(JSON.parse(...))` is what reads
  it back.

Fire a test event from Seerr's own UI (the agent has a **Test** button) rather
than waiting for a real request. A 401 means the header is not literally
`Bearer <token>`; a 403 means the room ID is not one the profile owns.

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

## Trap: a HelmRelease whose *first* install failed stalls forever

Found 2026-09-02, six days after the fact. Hookshot's pod was healthy and every
webhook worked, but `flux get helmreleases -n tools` showed:

```
Stalled   True   MissingRollbackTarget  Failed to perform remediation:
                 missing target release for rollback: cannot remediate failed release
Ready     False  UpgradeFailed
```

`helm -n tools history hookshot` told the story:

```
1  Aug 27 23:44  failed  Release "hookshot" failed: timeout waiting for: [Deployment/tools/hookshot status: 'InProgress']
2  Aug 27 23:54  failed  Upgrade "hookshot" failed: failed early due to stalled resources: [Deployment/tools/hookshot status: 'Failed']
```

Both attempts landed inside the ~95 minute Synapse outage documented below, so
the Deployment never went Ready in time. **The install itself failed**, which
means there was never a `deployed` revision — and with no good revision to roll
back to, Flux's remediation cannot run, sets `Stalled`, and **stops retrying
permanently**. It does not self-heal even after the underlying problem is fixed.

This is the nasty part: **nothing looks broken.** The pod runs, the bridge
works, notifications deliver. The only symptom is a HelmRelease that quietly
stopped being managed. The consequence only arrives later — evict or reschedule
that pod and Flux will not bring it back.

Recovery, once the underlying cause is actually fixed:

```sh
flux -n tools reconcile helmrelease hookshot --force
```

`--force` is required specifically because `Stalled` means Flux will not retry
on its own. This produced `revision 3 ... deployed` with **no pod restart** —
Helm applied an identical spec, so nothing rolled. Chart version was unchanged
(`5.0.1` in `ocirepository.yaml`, same as both failed attempts), so this was
purely Helm bookkeeping catching up with reality.

If `--force` is not enough, the next step is deleting the failed release secrets
(`kubectl -n tools delete secret -l owner=helm,name=hookshot`) and letting Flux
install fresh — the live resources carry `meta.helm.sh/release-name` and
`app.kubernetes.io/managed-by: Helm`, so Helm 3 **adopts** them rather than
colliding. Verify those annotations are present before trying it.

**Worth checking periodically**, since this failure mode is invisible from the
application side:

```sh
flux get helmreleases -A --status-selector ready=false
```

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

Assign to `result` using the v2 API. Both deployed functions are
reproduced below — this is the only copy outside room state, so edit here
and re-apply if you change one.

**Alertmanager** — one line per alert, `@room` only when something
critical is still firing, so resolved batches never ping.

Each alert carries its own links, which is the behaviour the Mattermost
`slack_configs` receiver gave for free and a plain `webhook_configs` does not:
Slack's schema has a title link, hookshot's payload has no link field at all,
and `webhook_configs` has no body templating — so the links have to be *built
here* from the payload. Alertmanager exposes no per-alert permalink, so
`Alertmanager` and `Silence` point at its alert list and silence form filtered
to the alert's own labels (`{alertname="…",namespace="…"}`), which is strictly
more specific than Slack's receiver-level `titlelink`. `Graph` is the alert's
`generatorURL` (Prometheus) and `Runbook` its `runbook_url` annotation; each is
omitted when the payload lacks it, and every link disappears if `externalURL` is
unset.

`externalURL` is the payload field Alertmanager fills from
`alertmanagerSpec.externalUrl` in the kube-prometheus-stack HelmRelease. Unset
it and the alerts still render, just with no links — which is why that value is
load-bearing rather than cosmetic:

```js
const alerts = data.alerts || [];
const esc = (s) => String(s == null ? "" : s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;")
  .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const a = (href, text) => href
  ? '<a href="' + esc(href) + '">' + esc(text) + "</a>" : esc(text);
// Alertmanager has no per-alert permalink, so the nearest equivalent is its own
// alert list filtered to this alert's identifying labels. The same expression
// prefills the silence form's matchers. `instance` is left out on purpose: it
// is an ephemeral IP:port that stops matching as soon as the target restarts.
const base = String(data.externalURL || "").replace(/\/+$/, "");
const matcher = (l) => "{" +
  ["alertname", "namespace", "job_name", "pod"]
    .filter((k) => l[k]).map((k) => k + '="' + l[k] + '"').join(",") + "}";
const amUrl = (path, l) => base
  ? base + path + "?filter=" + encodeURIComponent(matcher(l)) : "";

const rows = alerts.map((al) => {
  const icon = al.status === "firing" ? "🔥" : "✅";
  const l = al.labels || {}, ann = al.annotations || {};
  const where = [l.namespace, l.pod || l.instance].filter(Boolean).join("/");
  const detail = amUrl("/#/alerts", l);
  const links = [
    detail ? a(detail, "Alertmanager") : "",
    base ? a(amUrl("/#/silences/new", l), "Silence") : "",
    al.generatorURL ? a(al.generatorURL, "Graph") : "",
    ann.runbook_url ? a(ann.runbook_url, "Runbook") : "",
  ].filter(Boolean).join(" &middot; ");
  return icon + " <b>" + a(detail, l.alertname || "unknown") + "</b> [" +
    esc(l.severity || "-") + "]" + (where ? " " + esc(where) : "") + "<br>" +
    "&nbsp;&nbsp;" + esc(ann.summary || ann.description || "") +
    (links ? '<br>&nbsp;&nbsp;<span data-mx-color="#888888">' + links +
      "</span>" : "");
});
const plain = alerts.map((al) => {
  const l = al.labels || {}, ann = al.annotations || {};
  const detail = amUrl("/#/alerts", l);
  return (al.status === "firing" ? "FIRING" : "RESOLVED") + " " +
    (l.alertname || "unknown") + " [" + (l.severity || "-") + "] " +
    (l.namespace || "") + " - " + (ann.summary || ann.description || "") +
    (detail ? "\n  " + detail : "");
}).join("\n");
const critical = alerts.some(
  (al) => (al.labels || {}).severity === "critical" && al.status === "firing");
result = {
  version: "v2",
  empty: rows.length === 0,
  plain: plain || (data.status + ": no alerts"),
  html: rows.join("<br>"),
  msgtype: "m.notice",
  mentions: { room: critical },
};
```

**Forgejo** — Forgejo sends one fixed schema per event type with **no
discriminator in the body**; the event name is only in the
`X-Forgejo-Event` header, which a transformation function never sees. So
the payload shape is what identifies it. It also does the PR-sub-event
filtering that Forgejo itself cannot (see Wiring Forgejo below):

```js
// Forgejo sends one fixed schema per event type with no discriminator in the
// body -- the event name is only in the X-Forgejo-Event header, which a
// transformation function never sees. So the shape of the payload is what
// identifies it, checked most-specific first.
//
// Scope is deliberately PRs and CI only. Forgejo's `pull_request` subscription
// is an umbrella that expands server-side into every pull_request_* sub-event
// with no way to narrow it, so the assign/label/milestone/comment churn is
// filtered out HERE instead, by inspecting `action`.
const esc = (s) => String(s == null ? "" : s)
  .replace(/&/g, "&amp;").replace(/</g, "&lt;")
  .replace(/>/g, "&gt;").replace(/"/g, "&quot;");
const link = (href, text) =>
  href ? '<a href="' + esc(href) + '">' + esc(text) + "</a>" : esc(text);

const repo = (data.repository || {});
const repoName = repo.full_name || "unknown";
const repoUrl = repo.html_url || "";
const who = (data.sender && (data.sender.login || data.sender.username)) || "someone";

let plain = "", html = "", notify = false, empty = false;

if (data.run) {
  // Forgejo Actions: {action: failure|success|recover, run: ActionRun,
  // prior_status}. Only failure and recover are subscribed, so `success` here
  // would be a subscription change rather than noise to filter.
  const r = data.run;
  const act = String(data.action || r.status || "");
  const rRepo = (r.repository || repo);
  const rRepoName = rRepo.full_name || repoName;
  const trigger = (r.trigger_user && (r.trigger_user.login || r.trigger_user.username)) || who;
  const title = r.title || ("run #" + (r.index_in_repo || r.id || ""));
  const where = (r.prettyref ? " on " + r.prettyref : "") +
                (r.commit_sha ? " @" + String(r.commit_sha).slice(0, 8) : "");
  if (act === "success") {
    empty = true;
  } else {
    const recovered = act === "recover";
    notify = !recovered;
    plain = (recovered ? "CI recovered: " : "CI failed: ") + title +
      " in " + rRepoName + where + " (" + trigger + ")";
    html = (recovered ? "✅ <b>CI recovered</b> " : "❌ <b>CI failed</b> ") +
      link(r.html_url, title) + " in " + link(rRepo.html_url || repoUrl, rRepoName) +
      "<br><span data-mx-color=\"#888888\">" + esc(where.replace(/^ /, "")) +
      " · " + esc(trigger) + "</span>";
  }
} else if (data.pull_request) {
  const pr = data.pull_request;
  const act = String(data.action || "");
  // A pull_request_comment arrives with both pull_request and comment set.
  const KEEP = ["opened", "closed", "reopened", "reviewed"];
  if (data.comment || KEEP.indexOf(act) === -1) {
    empty = true;
  } else {
    const merged = act === "closed" && pr.merged;
    const verb = merged ? "merged" : act;
    const icon = merged ? "🎉" : (act === "opened" ? "🔀" : (act === "closed" ? "🚫" : "💬"));
    plain = who + " " + verb + " PR #" + pr.number + " in " + repoName + ": " + pr.title;
    html = icon + " <b>" + esc(who) + "</b> " + esc(verb) + " " +
      link(pr.html_url, "#" + pr.number + " " + pr.title) +
      " in " + link(repoUrl, repoName);
  }
} else {
  // Nothing else is subscribed. Say so rather than dumping the payload --
  // includeHookBody is false here, so a silent empty would lose the event
  // entirely and hide a subscription that was widened by accident.
  plain = "Unsubscribed Forgejo event from " + repoName;
  html = "📦 Unsubscribed Forgejo event from " + link(repoUrl, repoName);
}

result = {
  version: "v2",
  empty: empty,
  plain: plain,
  html: html,
  msgtype: "m.notice",
  mentions: { room: notify },
};
```

Both escape every interpolated value. Element sanitizes `formatted_body`
anyway, but a commit message containing `<` would otherwise silently lose
the rest of the line.

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

Hookshot connections (state key is what `!hookshot webhook remove <x>` takes,
which is not necessarily the display name):

| Room | Source | State key | Name | Hook ID stored in |
|---|---|---|---|---|
| Media Server | Tautulli (standby — the active path is the relay) | `tautulli` | `Tautulli` | 1P `hookshot-hooks` (`tautulli_hook_id`, `tautulli_url`) |
| Infrastructure | Alertmanager | `Alertmanager` | `Alertmanager` | 1P `hookshot-hooks` (`alertmanager_hook_id`, `alertmanager_url`) |
| Infrastructure | Forgejo | `Forgejo` | `Forgejo` | 1P `hookshot-hooks` (`forgejo_hook_id`, `forgejo_url`) |

Longhorn, Uptime Kuma and the Cloudflare DNS monitor are **not** in this table —
they take the relay path instead (see the relay profiles table below).

**`@hookshot` must hold PL50 in a room before either of these can exist.** The
Infrastructure room's `state_default` is 50 and the bot joins at `users_default`
(0), so it cannot write its own connection state until a room admin raises it to
Moderator. Nothing server-side can shortcut this: the AS token masquerades only
within its own namespace, and every `@_webhooks_*` ghost sits at 0 like the bot.

Relay profiles (no hookshot connection involved — these post straight to
Synapse):

| Room | Source | Sender | Display name |
|---|---|---|---|
| Media Server | Tautulli → `/notify` | `@_webhooks_plex` | `Plex` |
| Media Server | Seerr → `/notify` | `@_webhooks_requests` | `Requests` |
| Infrastructure | Uptime Kuma → `/notify` | `@_webhooks_uptimekuma` | `Uptime Kuma` |
| Infrastructure | Longhorn backup CronJob → `/notify` | `@_webhooks_longhorn` | `Longhorn` |
| Infrastructure | Cloudflare DNS monitor CronJob → `/notify` | `@_webhooks_cloudflare` | `Cloudflare` |

## The Infrastructure room

Room ID `!xSEmyzzqJYzDgEAdrj:matrix.${SECRET_DOMAIN}` — **public, unencrypted**,
which is what lets the relay ghosts self-join on first use with no invite.

Five infrastructure sources land here, split across the two delivery paths for
one reason: **whether the sender can shape its own JSON body.**

| Source | Path | Why |
|---|---|---|
| Alertmanager | hookshot + JS transform | `webhook_configs` has no body templating |
| Forgejo | hookshot + JS transform | fixed Forgejo webhook schema |
| Uptime Kuma | relay | its webhook notification supports a custom JSON body |
| Longhorn backup alert | relay | our CronJob, we own the payload |
| Cloudflare DNS monitor | relay | our CronJob, we own the payload |

The split is not cosmetic. A relay-delivered source gets a **clean display
name** and a **git-declared avatar**; a hookshot-delivered one inherits
hookshot's hardcoded `<name> (Webhook)` suffix and gets no avatar at all unless
one is applied by hand (see below). So prefer the relay whenever the sender can
emit `{"text": ..., "html": ...}` on its own.

Neither CronJob sends `room`. The relay falls back to the single room its
profile owns, which keeps the room ID declared once — in the relay HelmRelease —
rather than copied into every caller.

### Avatars for hookshot-delivered ghosts

Hookshot never touches avatars, and the relay only applies one while handling a
`/notify` it is the sender for. `@_webhooks_alertmanager` and
`@_webhooks_forgejo` are hookshot's ghosts with **no relay profile**, so their
icons are set once against the homeserver and live only in Synapse — **not
reproducible from this repo**, the same category as a room avatar.

Their PNGs are still committed next to the relay's, deliberately **outside** the
`matrix-media-relay-avatars` ConfigMap generator: nothing mounts them, they
exist so this recovery step needs no network. Re-run after a homeserver rebuild
or a deliberate icon change:

```sh
# From a checkout, with cluster access. The AS token is read inside the pod and
# never leaves it; the PNGs are piped in from git, so this works offline.
D=kubernetes/apps/tools/matrix-media-relay/app
python3 -c "
import base64, json
print(json.dumps({'domain': 'matrix.<your domain>', 'avatars': {
  '_webhooks_alertmanager': base64.b64encode(open('$D/avatar-alertmanager.png','rb').read()).decode(),
  '_webhooks_forgejo':      base64.b64encode(open('$D/avatar-forgejo.png','rb').read()).decode()}}))
" > /tmp/avspec.json

kubectl -n tools exec -i deploy/synapse-main -c app -- sh -c 'cat > /tmp/setav.py' <<'PY'
import base64, json, sys, urllib.parse, urllib.request
SPEC = json.load(sys.stdin); DOMAIN = SPEC["domain"]; HS = "http://localhost:8008"
tok = [l.split(":", 1)[1].strip().strip('"')
       for l in open("/as/hookshot-registration.yml")
       if l.strip().startswith("as_token:")][0]
for ghost, b64 in SPEC["avatars"].items():
    png = base64.b64decode(b64)
    sender = "@%s:%s" % (ghost, DOMAIN)
    q = urllib.parse.urlencode({"user_id": sender, "filename": ghost + ".png"})
    req = urllib.request.Request(HS + "/_matrix/media/v3/upload?" + q, data=png,
        headers={"Authorization": "Bearer " + tok, "Content-Type": "image/png"})
    mxc = json.load(urllib.request.urlopen(req, timeout=60))["content_uri"]
    req = urllib.request.Request(
        HS + "/_matrix/client/v3/profile/%s/avatar_url?%s"
        % (urllib.parse.quote(sender), urllib.parse.urlencode({"user_id": sender})),
        data=json.dumps({"avatar_url": mxc}).encode(), method="PUT",
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"})
    urllib.request.urlopen(req, timeout=30).read()
    print(sender, "->", mxc, file=sys.stderr)
PY

kubectl -n tools exec -i deploy/synapse-main -c app -- python3 /tmp/setav.py < /tmp/avspec.json
```

Every upload mints a fresh `mxc://`, so re-running this leaks the previous
media. Run it only on a rebuild or a deliberate icon change — this is exactly
the bookkeeping the relay's sha256 account-data cache exists to avoid, and the
reason a relay profile is the better home for an icon when the source allows it.

## Provisioning a hookshot connection without the bot command

`!hookshot webhook <name>` needs a human in the room. These two were created
directly against the homeserver instead, which requires knowing something the
upstream docs do not say plainly:

**The hookId is not in the state event.** It lives in the *bot's room account
data* under the same type, as a `{hookId: stateKey}` map. The state event holds
only `{name, transformationFunction, includeHookBody, ...}`.

That matters because of this branch in `Connections/GenericHook.js`:

```js
if (!hookId) {
    if (as.isNamespacedUser(event.sender)) {
        throw new Error(`No hookId found for "${state.name}". Refusing to generate a hookId as it's owned by us.`);
    }
```

Writing the state event as `@hookshot` — the natural choice, since it is the
user holding PL50 — makes `isNamespacedUser` true, so hookshot **refuses** to
mint a hookId and the connection is dead on arrival. **Seed the account data
first**, then write the state event:

```
PUT /_matrix/client/v3/user/{@hookshot}/rooms/{roomId}/account_data/uk.half-shot.matrix-hookshot.generic.hook
    {"<uuid4>": "Alertmanager"}          # merge, do not overwrite other hooks

PUT /_matrix/client/v3/rooms/{roomId}/state/uk.half-shot.matrix-hookshot.generic.hook/Alertmanager
    {"name": "Alertmanager", "transformationFunction": "...", "includeHookBody": false}
```

Both calls use hookshot's AS token with `?user_id=@hookshot:...`. Hookshot picks
the connection up live — look for `New connected added to !room: GenericHookConnection <hookId>`
in its logs. The state key is the connection name, and the ghost is
`@_webhooks_<name lowercased>`.

**`includeHookBody: false` is not optional here.** The global config sets it
`true`, which attaches the raw payload to every event. Hookshot's oversize
trimming drops the rendered HTML *before* it drops that blob, so a large Forgejo
push would arrive as a JSON dump instead of the formatted message.

## Wiring Alertmanager

`webhook_configs`, not `slack_configs` — hookshot reads only `text`, `html` and
`username` from a payload, so Slack's schema lands in the room as a JSON code
block. Config lives in
`kubernetes/apps/monitoring/kube-prometheus-stack/app/externalsecret.yaml`, with
the URL pulled from 1P `hookshot-hooks` (`alertmanager_url`) — the in-cluster
`http://hookshot.tools.svc.cluster.local:9000/webhook/<hookId>` form, so the
alerting path has no external DNS or TLS dependency on the things it alerts
about.

`max_alerts: 0` disables Alertmanager's own truncation; the transformation
function renders one line per alert and hookshot trims oversize events itself.

The hookId in that URL is the only credential a generic webhook has, which is
why it is stored concealed rather than written into the manifest.

## Wiring Forgejo

Scope is **pull requests and CI only**. That takes two kinds of hook, because of
a quirk worth knowing before touching any of this:

| Hook | Where | Events | Covers |
|---|---|---|---|
| System hook `2` | `/api/v1/admin/hooks` | `pull_request` | every repo, including future ones |
| Repo hooks `4`,`5`,`6` | `/api/v1/repos/{owner}/{repo}/hooks` | `action_run_failure`, `action_run_recover` | that one repo |

All four point at the same in-cluster hookshot URL from 1P `hookshot-hooks`
(`forgejo_url`), so they share one connection, one ghost and one transformation
function.

### The quirk: system hooks reject CI events, repo hooks accept them

Forgejo **does** support Actions webhooks — `action_run_failure`,
`action_run_success`, `action_run_recover`, added in
[forgejo#7508](https://codeberg.org/forgejo/forgejo/pulls/7508) (merged June
2025). But on 15.0.2+gitea-1.22.0 the **system-hook** endpoint silently drops
them, while the **repo-hook** endpoint accepts them. Verified empirically
against this instance:

```
PATCH /api/v1/admin/hooks/2      events:[push, action_run_failure]  -> [push]
POST  /api/v1/repos/{r}/hooks    events:[push, action_run_failure]  -> [push, action_run_failure]
```

Every candidate name was probed against the system endpoint —
`action_run_failure`, `action_run_success`, `action_run_recover`,
`workflow_run`, `workflow_job`, `actions`, `action_run`, `status` — and **all**
were dropped. So the earlier note that "this Forgejo does not emit CI events"
was wrong: it does, just not from a system hook.

**Unknown events are dropped, not rejected.** The API returns 200 with a
silently shortened list, so always read the response's `events` back rather than
trusting the request. That is what hid this in the first place.

### The other quirk: `pull_request` is an umbrella

Subscribing to `pull_request` expands server-side into every `pull_request_*`
sub-event — assign, label, milestone, comment, and the review ones. There is no
API or UI way to subscribe to just opened/closed.

So the filtering happens in the **transformation function** instead, which
keeps only `opened`, `closed`, `reopened` and `reviewed` and returns
`empty: true` for the rest (and for any payload carrying a `comment`, which is
how a PR comment arrives). Verified: of seven representative payloads, the four
intended ones posted and CI-success, PR-label and PR-comment stayed silent.

`closed` with `pull_request.merged` true is rendered as **merged**, since
Forgejo has no separate merge action.

### Actions payload shape

`{action: "failure"|"success"|"recover", run: ActionRun, prior_status}`. The
useful `run` fields are `title`, `html_url`, `index_in_repo`, `prettyref`,
`commit_sha`, `trigger_user`, `status`, `repository`. Note there is **no
`conclusion`** field — `action` and `run.status` carry that.

Only failure and recover are subscribed, so the room says when CI broke and when
it came back, and nothing on a normal green run.

### Coverage gap

Repo hooks are per repo. **A newly created repo gets PR notifications
automatically (system hook) but no CI notifications** until a hook is added to
it. Forgejo's "default webhooks" — templates copied into new repos — would close
this, but `/api/v1/admin/hooks` has no `type` parameter (confirmed against this
instance's `swagger.v1.json`), so they are **UI-only**: Site Administration →
Default Webhooks. Add one there pointing at the same URL with the two
`action_run_*` events if repos start multiplying.

### Admin token

Managing any of this needs a `write:admin` token; the long-lived
`orca_api_token` (user `jarvis`) has repo scope only. Tokens were minted for
each change and **revoked immediately after** (revocation verified by a
subsequent 401). Nothing admin-scoped is left in 1Password by design — mint
another the same way:

```sh
op-session exec op run --no-masking --env-file=/dev/stdin -- sh -c '
curl -s -X POST -u "$U:$P" -H "Content-Type: application/json" \
  -d "{\"name\":\"tmp\",\"scopes\":[\"write:admin\",\"write:repository\"]}" \
  https://git.<domain>/api/v1/users/$U/tokens' <<'ENV'
U=op://homeops/forgejo/admin_username
P=op://homeops/forgejo/admin_password
ENV
```

### Icon sources

Ghost icons come from
[`homarr-labs/dashboard-icons`](https://github.com/homarr-labs/dashboard-icons),
already the source Homepage and the Authentik launcher blueprints use, so the
room matches the dashboards.

`avatar-uptimekuma.png` is upstream's 512×512 PNG **vendored verbatim** — per the
rule above, a project shipping a square icon gets copied, not redrawn. The other
three are not square (Forgejo 328×512, Longhorn 621×512, Cloudflare 1132×512) and
Element's circular crop would clip them, so each keeps an `avatar-*.svg` beside
it: a 512×512 canvas embedding the upstream SVG inset to 68–86%, rasterized with
`qlmanage -t -s 512`. Longhorn's canvas is filled `#5F224A` — its own brand
purple, taken from the upstream SVG — so the crop reads as white horns on a
solid purple disc instead of a clipped rounded-rect card.

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
