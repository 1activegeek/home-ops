"""Post a single Matrix m.image event carrying its own caption.

Hookshot's generic webhooks cannot send images: its transformation result type
is text/html only, and the QuickJS sandbox has no network. Apprise can upload,
but emits the image and the text as two separate events. This relay exists for
the one case neither covers -- a single event with the artwork and the text
together (MSC2530 caption), which is what Element renders as one card.

Authenticates with hookshot's appservice token so it can masquerade as the
@_webhooks_* ghosts, meaning no second appservice registration and no Synapse
restart.

Callers are identified by a per-profile bearer token. The profile -- not the
request -- decides which ghost sends and which rooms are reachable, so a leaked
token cannot be used to post as someone else or into an unrelated room. Add a
profile plus its TOKEN_<NAME> to onboard another notification source; the ghost
registers, joins its rooms and applies its name and icon at startup, before the
listener opens, so a public room needs no manual step at all.

Stdlib only, so it runs on a stock python image with no build step.
"""

import hashlib
import hmac
import json
import logging
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SYNAPSE_URL = os.environ.get("SYNAPSE_URL", "http://synapse-main.tools.svc.cluster.local:8008")
AS_TOKEN = os.environ["AS_TOKEN"]
TAUTULLI_URL = os.environ.get("TAUTULLI_URL", "http://tautulli.media.svc.cluster.local:8181")
TAUTULLI_API_KEY = os.environ.get("TAUTULLI_API_KEY", "")
PORT = int(os.environ.get("PORT", "8080"))
TIMEOUT = int(os.environ.get("HTTP_TIMEOUT", "30"))
MAX_IMAGE_BYTES = int(os.environ.get("MAX_IMAGE_BYTES", str(10 * 1024 * 1024)))
AVATAR_DIR = os.environ.get("AVATAR_DIR", "/app/avatars")
# Hosts an absolute `img` URL may be fetched from. The relay runs inside the
# cluster, so an unrestricted fetcher would be an SSRF pivot onto every internal
# service; the allowlist is what keeps `img` safe to accept from a caller.
IMAGE_HOSTS = {h.strip().lower() for h in
               os.environ.get("IMAGE_HOSTS", "image.tmdb.org").split(",") if h.strip()}
# Account-data key holding the hash of the avatar we last applied, so the
# image is only re-uploaded when it actually changes.
AVATAR_STATE = "uk.co.matrix-media-relay.avatar"
# How long to wait at startup for a freshly-set avatar to reach a room's member
# event. Only paid when an avatar actually changed, so normally zero.
MEMBER_SYNC_TIMEOUT = float(os.environ.get("MEMBER_SYNC_TIMEOUT", "10"))
MEMBER_SYNC_INTERVAL = 0.5

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("relay")


def _load_profiles():
    """{token: {"name","sender","rooms"}} built from PROFILES plus TOKEN_<NAME>.

    Keeping the routing table out of the request means a stolen token is
    confined to one sender and one room set.
    """
    raw = json.loads(os.environ.get("PROFILES", "{}"))
    table = {}
    for name, prof in raw.items():
        token = os.environ.get("TOKEN_" + name.upper().replace("-", "_"))
        if not token:
            log.warning("profile %r has no TOKEN_%s; it is unreachable",
                        name, name.upper().replace("-", "_"))
            continue
        rooms = prof.get("rooms") or []
        if not prof.get("sender") or not rooms:
            log.warning("profile %r needs both sender and rooms; skipping", name)
            continue
        table[token] = {"name": name, "sender": prof["sender"], "rooms": list(rooms),
                        "avatar": prof.get("avatar"),
                        "displayname": prof.get("displayname")}
    return table


PROFILES = _load_profiles()
_registered = set()
_joined = set()


def _authenticate(header):
    """Constant-time match so the comparison cannot be timed to guess a token."""
    if not header or not header.startswith("Bearer "):
        return None
    supplied = header[7:]
    for token, profile in PROFILES.items():
        if hmac.compare_digest(token, supplied):
            return profile
    return None


def _image_size(data):
    """(width, height) for PNG/JPEG, else (None, None). A rendering hint only --
    without it Element reflows the timeline while the image loads."""
    try:
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
        if data[:2] == b"\xff\xd8":
            i = 2
            while i < len(data) - 9:
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                # SOF0-SOF15, excluding the non-frame markers DHT/JPG/DAC
                if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                    return (int.from_bytes(data[i + 7:i + 9], "big"),
                            int.from_bytes(data[i + 5:i + 7], "big"))
                i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    except Exception:
        log.warning("could not determine image dimensions", exc_info=True)
    return None, None


def _matrix(method, path, sender, body=None, content_type="application/json", raw=False):
    sep = "&" if "?" in path else "?"
    url = SYNAPSE_URL + path + sep + "user_id=" + urllib.parse.quote(sender)
    data = body if raw else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": "Bearer " + AS_TOKEN, "Content-Type": content_type},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.load(resp)


def _ensure_registered(sender):
    """Register the ghost once per process. Hookshot creates the ghosts it owns,
    but a profile for a source hookshot has never seen would 403 without this.
    The ghost still has to be invited to any invite-only room."""
    if sender in _registered:
        return
    localpart = sender.split(":", 1)[0].lstrip("@")
    try:
        # inhibit_login is mandatory: Synapse >= 1.139 enforces MSC4190, and with
        # MAS in front it rejects an appservice registration without it
        # (IO.ELEMENT.MSC4190.M_APPSERVICE_LOGIN_UNSUPPORTED). The relay never
        # needs the access token this suppresses -- it acts through the AS token.
        _matrix("POST", "/_matrix/client/v3/register", sender,
                {"type": "m.login.application_service", "username": localpart,
                 "inhibit_login": True})
        log.info("registered ghost %s", sender)
    except urllib.error.HTTPError as exc:
        detail = exc.read()[:200]
        if b"M_USER_IN_USE" not in detail:
            log.warning("register %s returned %s: %s", sender, exc.code, detail)
    _registered.add(sender)


def _ensure_joined(sender, room):
    """Join the room once per process, so onboarding a profile does not require
    driving Element by hand.

    Synapse rejects a send from a non-member with 403 whatever the join rule is,
    so this is what makes a public notification room self-service. The same call
    accepts a pending invite, which covers invite-only rooms too -- but it cannot
    manufacture one, so an invite-only room with no invite still 403s here. That
    is logged with the room and sender and then skipped: the send that follows
    fails on its own and reports the real error, rather than this masking it.
    """
    key = (sender, room)
    if key in _joined:
        return
    try:
        # Idempotent: Synapse answers 200 for a user that is already a member,
        # so there is nothing to check before calling it.
        _matrix("POST", "/_matrix/client/v3/join/" + urllib.parse.quote(room), sender, {})
        log.info("%s is in %s", sender, room)
    except urllib.error.HTTPError as exc:
        log.warning("%s could not join %s (%s): %s -- invite it if the room is "
                    "invite-only", sender, room, exc.code, exc.read()[:200])
    except Exception:
        log.exception("joining %s as %s failed", room, sender)
    _joined.add(key)


def _ensure_displayname(sender, name):
    """Assert the ghost's display name on every send.

    Synapse sets a new user's display name to its localpart, so a ghost with no
    profile shows up as the raw `_webhooks_*` id. Hookshot also owns the name of
    any ghost one of its own webhook connections uses, and re-applies its
    `<name> (Webhook)` form when it restarts. Re-asserting here rather than
    caching the result is what makes the relay's name win back after that: the
    cost is one GET per notification, which is nothing at this traffic.
    """
    path = "/_matrix/client/v3/profile/%s/displayname" % urllib.parse.quote(sender)
    try:
        if _matrix("GET", path, sender).get("displayname") == name:
            return
    except urllib.error.HTTPError as exc:
        if exc.code != 404:  # 404 simply means no name has ever been set
            log.warning("reading display name for %s: %s", sender, exc)
    try:
        _matrix("PUT", path, sender, {"displayname": name})
        log.info("display name for %s set to %r", sender, name)
    except Exception:
        log.exception("could not set display name for %s", sender)


def _ensure_avatar(sender, filename):
    """Apply the profile's avatar, uploading only when the bytes have changed.

    Synapse mints a fresh mxc:// on every upload, so re-uploading unconditionally
    would leak media on each restart. The hash of what was last applied is kept
    in the ghost's own account data, which makes this converge: edit the PNG in
    the ConfigMap and the next request replaces the avatar, otherwise it is a
    single cheap GET.

    Hookshot rewrites display names but never touches avatars, so what is set
    here survives its restarts.

    Returns (mxc, changed). `changed` is what tells the caller whether it is
    worth waiting for the new avatar to reach room member events.
    """
    path = os.path.join(AVATAR_DIR, filename)
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as exc:
        log.warning("avatar %s unreadable: %s", path, exc)
        return None, False
    digest = hashlib.sha256(data).hexdigest()
    state_path = "/_matrix/client/v3/user/%s/account_data/%s" % (
        urllib.parse.quote(sender), AVATAR_STATE)
    try:
        cached = _matrix("GET", state_path, sender)
        if cached.get("sha256") == digest:
            return cached.get("mxc"), False
    except urllib.error.HTTPError as exc:
        if exc.code != 404:  # 404 simply means we have never set one
            log.warning("reading avatar state for %s: %s", sender, exc)
    try:
        mxc = _matrix("POST", "/_matrix/media/v3/upload?filename=" + urllib.parse.quote(filename),
                      sender, data, "image/png", raw=True)["content_uri"]
        _matrix("PUT", "/_matrix/client/v3/profile/%s/avatar_url" % urllib.parse.quote(sender),
                sender, {"avatar_url": mxc})
        _matrix("PUT", state_path, sender, {"sha256": digest, "mxc": mxc})
        log.info("avatar for %s set to %s", sender, mxc)
        return mxc, True
    except Exception:
        log.exception("could not set avatar for %s", sender)
        return None, False


def _await_member_avatar(sender, room, mxc):
    """Block until the ghost's avatar has reached this room's member event.

    Setting `avatar_url` on the profile returns as soon as the profile is
    written; Synapse then fans the change out into an m.room.member event per
    room in the background. Clients render a message's sender from the member
    state *at that event*, so a send that wins this race is displayed with no
    avatar -- permanently, because the timeline is immutable. Waiting here is
    what stops the first notification from a new ghost being the ugly one.

    Bounded and best-effort: a timeout is logged and ignored, since a missing
    icon is worth far less than a notification that never arrives.
    """
    path = "/_matrix/client/v3/rooms/%s/state/m.room.member/%s" % (
        urllib.parse.quote(room), urllib.parse.quote(sender))
    deadline = time.time() + MEMBER_SYNC_TIMEOUT
    while time.time() < deadline:
        try:
            if _matrix("GET", path, sender).get("avatar_url") == mxc:
                return True
        except urllib.error.HTTPError as exc:
            if exc.code != 404:  # 404 = not a member yet, keep waiting
                log.warning("reading member state for %s in %s: %s", sender, room, exc)
        except Exception:
            log.exception("reading member state for %s in %s", sender, room)
        time.sleep(MEMBER_SYNC_INTERVAL)
    log.warning("avatar for %s did not reach %s within %ss; its next message may "
                "render without an icon", sender, room, MEMBER_SYNC_TIMEOUT)
    return False


def _ensure_identity(profile):
    _ensure_registered(profile["sender"])
    for room in profile["rooms"]:
        _ensure_joined(profile["sender"], room)
    if profile.get("displayname"):
        _ensure_displayname(profile["sender"], profile["displayname"])
    if profile.get("avatar"):
        return _ensure_avatar(profile["sender"], profile["avatar"])
    return None, False


def prepare_profiles():
    """Dress every ghost before the listener opens.

    Doing this lazily on the first send is what produced permanently
    icon-less first messages: register, join, name and avatar all happened
    inside the request that then immediately posted. Running it at startup
    means the race is against nothing -- there is no traffic yet -- and the
    wait above only costs anything the once, when an avatar actually changed.

    Failures here are logged and swallowed on purpose. The per-send path still
    calls _ensure_identity, so a Synapse that is briefly unreachable at boot
    degrades to the old behaviour instead of crash-looping the relay.
    """
    for profile in PROFILES.values():
        try:
            mxc, changed = _ensure_identity(profile)
            if changed and mxc:
                for room in profile["rooms"]:
                    _await_member_avatar(profile["sender"], room, mxc)
        except Exception:
            log.exception("preparing profile %s failed; it will be retried on "
                          "first use", profile["name"])


def _read_image(resp, source):
    ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
    data = resp.read(MAX_IMAGE_BYTES + 1)
    if not ctype.startswith("image/"):
        # Tautulli answers an unauthenticated request with its login page, 200 OK.
        raise ValueError("%s returned %s, not an image" % (source, ctype))
    if len(data) > MAX_IMAGE_BYTES:
        raise ValueError("poster exceeds MAX_IMAGE_BYTES (%d)" % MAX_IMAGE_BYTES)
    return data, ctype


def fetch_remote(img):
    """Fetch an absolute poster URL, e.g. Seerr's {{image}} TMDB link.

    Restricted to IMAGE_HOSTS. Redirects are refused rather than followed --
    an allowlisted host that 302s elsewhere would otherwise walk straight past
    the check and let a caller aim the fetcher at a cluster-internal address.
    """
    parsed = urllib.parse.urlsplit(img)
    host = (parsed.hostname or "").lower()
    if parsed.scheme not in ("http", "https") or host not in IMAGE_HOSTS:
        raise ValueError("img host %r is not in IMAGE_HOSTS" % host)

    class _NoRedirect(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            raise ValueError("img URL redirected to %s; refusing to follow" % newurl)

    opener = urllib.request.build_opener(_NoRedirect)
    with opener.open(img, timeout=TIMEOUT) as resp:
        return _read_image(resp, host)


def fetch_poster(img):
    """Tautulli's /pms_image_proxy requires a web session; only the /api/v2
    command form accepts the API key."""
    if not TAUTULLI_API_KEY:
        raise ValueError("img supplied but TAUTULLI_API_KEY is not set")
    url = TAUTULLI_URL + "/api/v2?" + urllib.parse.urlencode({
        "apikey": TAUTULLI_API_KEY, "cmd": "pms_image_proxy",
        "img": img, "width": 400, "height": 600, "fallback": "poster",
    })
    with urllib.request.urlopen(url, timeout=TIMEOUT) as resp:
        return _read_image(resp, "Tautulli")


def fetch_image(img):
    """`img` is either an absolute URL (Seerr hands out TMDB links) or a Plex
    library path to be proxied through Tautulli."""
    if img.startswith("http://") or img.startswith("https://"):
        return fetch_remote(img)
    return fetch_poster(img)


def send(profile, payload):
    sender, allowed = profile["sender"], profile["rooms"]
    room = payload.get("room") or allowed[0]
    if room not in allowed:
        raise PermissionError("profile %r may not post to %s" % (profile["name"], room))

    text = payload.get("text") or ""
    html = payload.get("html")
    img = payload.get("img")
    _ensure_identity(profile)

    if img:
        data, ctype = fetch_image(img)
        filename = payload.get("filename") or ("poster." + (ctype.split("/")[-1] or "jpg"))
        mxc = _matrix("POST", "/_matrix/media/v3/upload?filename=" + urllib.parse.quote(filename),
                      sender, data, ctype, raw=True)["content_uri"]
        width, height = _image_size(data)
        info = {"mimetype": ctype, "size": len(data)}
        if width and height:
            info.update({"w": width, "h": height})
        # filename distinct from body is what marks body as a caption (MSC2530);
        # if they match, clients render no caption at all.
        content = {"msgtype": "m.image", "url": mxc, "filename": filename,
                   "body": text or filename, "info": info}
    else:
        content = {"msgtype": "m.notice", "body": text}

    if html:
        content.update({"format": "org.matrix.custom.html", "formatted_body": html})

    path = "/_matrix/client/v3/rooms/%s/send/m.room.message/%s" % (
        urllib.parse.quote(room), "relay-%d" % (time.time() * 1000))
    return _matrix("PUT", path, sender, content)["event_id"], room


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, body):
        raw = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path in ("/healthz", "/live", "/ready"):
            return self._reply(200, {"ok": True, "profiles": len(PROFILES)})
        self._reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/notify":
            return self._reply(404, {"error": "not found"})
        profile = _authenticate(self.headers.get("Authorization"))
        if not profile:
            log.warning("rejected unauthenticated POST from %s", self.address_string())
            return self._reply(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0:
                raise ValueError("empty body")
            payload = json.loads(self.rfile.read(length))
        except Exception as exc:
            log.warning("bad request from profile %s: %s", profile["name"], exc)
            return self._reply(400, {"error": str(exc)})
        try:
            event_id, room = send(profile, payload)
        except PermissionError as exc:
            log.warning("%s", exc)
            return self._reply(403, {"error": str(exc)})
        except Exception as exc:
            log.exception("send failed for profile %s", profile["name"])
            return self._reply(502, {"error": str(exc)})
        log.info("profile=%s room=%s sent %s", profile["name"], room, event_id)
        self._reply(200, {"event_id": event_id})

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)


if __name__ == "__main__":
    if not PROFILES:
        log.error("no usable profiles; every request will be rejected")
    for p in PROFILES.values():
        log.info("profile %s -> %s rooms=%s", p["name"], p["sender"], p["rooms"])
    # Before the listener opens, so no request can race a half-dressed ghost.
    # The readiness probe is what makes this safe to do synchronously: the pod
    # is not marked ready, and nothing is routed to it, until this returns.
    prepare_profiles()
    log.info("listening on :%d", PORT)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
