"""Post a single Matrix m.image event carrying its own caption.

Hookshot's generic webhooks cannot send images: its transformation result type
is text/html only, and the QuickJS sandbox has no network. Apprise can upload,
but emits the image and the text as two separate events. This relay exists for
the one case neither covers -- a single event with the artwork and the text
together (MSC2530 caption), which is what Element renders as one card.

Fetches the poster from Tautulli's API, uploads it to the Synapse media repo,
and sends one m.image. Authenticates with hookshot's appservice token so it can
masquerade as the same @_webhooks_* ghost that posts the text-only messages --
no second appservice registration, so no Synapse restart.

Stdlib only, so it runs on a stock python image with no build step.
"""

import json
import logging
import os
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SYNAPSE_URL = os.environ.get("SYNAPSE_URL", "http://synapse-main.tools.svc.cluster.local:8008")
AS_TOKEN = os.environ["AS_TOKEN"]
SENDER = os.environ["SENDER"]
DEFAULT_ROOM = os.environ.get("DEFAULT_ROOM", "")
TAUTULLI_URL = os.environ.get("TAUTULLI_URL", "http://tautulli.media.svc.cluster.local:8181")
TAUTULLI_API_KEY = os.environ.get("TAUTULLI_API_KEY", "")
AUTH_TOKEN = os.environ.get("AUTH_TOKEN", "")
PORT = int(os.environ.get("PORT", "8080"))
TIMEOUT = int(os.environ.get("HTTP_TIMEOUT", "30"))
MAX_IMAGE_BYTES = int(os.environ.get("MAX_IMAGE_BYTES", str(10 * 1024 * 1024)))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("relay")


def _image_size(data):
    """(width, height) for PNG/JPEG, or (None, None). Only a rendering hint --
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


def _matrix(method, path, body=None, content_type="application/json", raw=False):
    sep = "&" if "?" in path else "?"
    url = SYNAPSE_URL + path + sep + "user_id=" + urllib.parse.quote(SENDER)
    data = body if raw else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": "Bearer " + AS_TOKEN, "Content-Type": content_type},
    )
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return json.load(resp)


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


def send(payload):
    room = payload.get("room") or DEFAULT_ROOM
    if not room:
        raise ValueError("no room supplied and DEFAULT_ROOM is unset")
    text = payload.get("text") or ""
    html = payload.get("html")
    img = payload.get("img")

    if img:
        data, ctype = fetch_poster(img)
        filename = payload.get("filename") or ("poster." + (ctype.split("/")[-1] or "jpg"))
        mxc = _matrix("POST", "/_matrix/media/v3/upload?filename=" + urllib.parse.quote(filename),
                      data, ctype, raw=True)["content_uri"]
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
    return _matrix("PUT", path, content)["event_id"]


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
            return self._reply(200, {"ok": True})
        self._reply(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/notify":
            return self._reply(404, {"error": "not found"})
        if AUTH_TOKEN and self.headers.get("Authorization") != "Bearer " + AUTH_TOKEN:
            return self._reply(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0:
                raise ValueError("empty body")
            payload = json.loads(self.rfile.read(length))
        except Exception as exc:
            log.warning("bad request: %s", exc)
            return self._reply(400, {"error": str(exc)})
        try:
            event_id = send(payload)
        except Exception as exc:
            log.exception("send failed")
            return self._reply(502, {"error": str(exc)})
        log.info("sent %s", event_id)
        self._reply(200, {"event_id": event_id})

    def log_message(self, fmt, *args):
        log.info("%s - %s", self.address_string(), fmt % args)


if __name__ == "__main__":
    log.info("listening on :%d as %s", PORT, SENDER)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
