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
profile plus its TOKEN_<NAME> to onboard another notification source.

Stdlib only, so it runs on a stock python image with no build step.
"""

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
        table[token] = {"name": name, "sender": prof["sender"], "rooms": list(rooms)}
    return table


PROFILES = _load_profiles()
_registered = set()


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
        _matrix("POST", "/_matrix/client/v3/register", sender,
                {"type": "m.login.application_service", "username": localpart})
        log.info("registered ghost %s", sender)
    except urllib.error.HTTPError as exc:
        detail = exc.read()[:200]
        if b"M_USER_IN_USE" not in detail:
            log.warning("register %s returned %s: %s", sender, exc.code, detail)
    _registered.add(sender)


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
        ctype = (resp.headers.get("Content-Type") or "").split(";")[0].strip()
        data = resp.read(MAX_IMAGE_BYTES + 1)
    if not ctype.startswith("image/"):
        # Tautulli answers an unauthenticated request with its login page, 200 OK.
        raise ValueError("Tautulli returned %s, not an image (check the API key)" % ctype)
    if len(data) > MAX_IMAGE_BYTES:
        raise ValueError("poster exceeds MAX_IMAGE_BYTES (%d)" % MAX_IMAGE_BYTES)
    return data, ctype


def send(profile, payload):
    sender, allowed = profile["sender"], profile["rooms"]
    room = payload.get("room") or allowed[0]
    if room not in allowed:
        raise PermissionError("profile %r may not post to %s" % (profile["name"], room))

    text = payload.get("text") or ""
    html = payload.get("html")
    img = payload.get("img")
    _ensure_registered(sender)

    if img:
        data, ctype = fetch_poster(img)
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
    log.info("listening on :%d", PORT)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
