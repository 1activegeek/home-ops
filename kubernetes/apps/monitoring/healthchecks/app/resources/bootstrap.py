# Idempotent first-run setup, executed by the bootstrap init container via
# `manage.py shell` after `manage.py migrate`.
#
# Makes 1Password the source of truth for the admin login and the project's
# API keys and ping key, so a rebuilt database (or a fresh install) comes back
# with the same credentials every script, cron and Alertmanager already holds.
#
# Healthchecks stores API keys as "<first 8 chars of random part>.<HMAC-SHA256
# (SECRET_KEY, key)>" (hc/accounts/models.py Project._make_api_key), so the
# plain keys from 1Password are hashed here exactly the same way. Rotating
# SECRET_KEY therefore requires a pod restart to re-hash, which reloader does.
#
# Note: the admin password is re-applied on every start. Day to day, login is
# Authentik forward-auth (REMOTE_USER_HEADER) and password login is disabled;
# the password is a break-glass credential for when that env var is removed.
# HC_ADMIN_EMAIL must match the admin's Authentik email, or the header login
# would auto-create a second, non-superuser account.

import hmac
import json
import os
from uuid import uuid4

from django.conf import settings
from django.contrib.auth.models import User

from hc.accounts.models import Project
from hc.accounts.views import _make_user
from hc.api.models import Channel, Check

email = os.environ["HC_ADMIN_EMAIL"]
password = os.environ["HC_ADMIN_PASSWORD"]


def hash_key(key: str) -> str:
    prefix, secret = key[:4], key[4:]
    if prefix not in ("hcw_", "hcr_") or len(key) != 32:
        raise SystemExit(f"bootstrap: malformed API key (prefix {prefix!r}, length {len(key)})")
    digest = hmac.digest(settings.SECRET_KEY.encode(), key.encode(), "sha256")
    return secret[:8] + "." + digest.hex()


user = User.objects.filter(email=email).first()
if user is None:
    # Same helper the signup flow uses: creates the user, a default project,
    # a verified email integration for this address, and a sample check.
    user = _make_user(email)
    Check.objects.filter(project__owner=user, slug="my-first-check").delete()
    print(f"bootstrap: created admin user and project for {email}")

user.is_staff = True
user.is_superuser = True
user.set_password(password)
user.save()

# The default project: services and infrastructure (heartbeat runner,
# self-check, Alertmanager Watchdog). Oldest project owned by the admin.
project = Project.objects.filter(owner=user).order_by("id").first()
if project is None:
    project = Project(owner=user, badge_key=user.username)

project.name = project.name or "Homelab"
project.api_key = hash_key(os.environ["HC_API_KEY"])
project.api_key_readonly = hash_key(os.environ["HC_API_KEY_READONLY"])
project.ping_key = os.environ["HC_PING_KEY"]
project.show_slugs = True
project.save()

print(f"bootstrap: project {project.code} keys synced from 1Password")

projects = [project]

# Second project, "Jobs": backups and other scheduled work. Its own ping key
# keeps job slugs in their own namespace and lets scripts outside the cluster
# report without holding the services project's key. Found by name, so
# renaming it in the UI would make the next start create a fresh one.
jobs_api_key = os.environ.get("HC_JOBS_API_KEY")
jobs_ping_key = os.environ.get("HC_JOBS_PING_KEY")
if jobs_api_key and jobs_ping_key:
    jobs = Project.objects.filter(owner=user, name="Jobs").first()
    if jobs is None:
        jobs = Project(owner=user, name="Jobs")
        # Same as the "add project" view.
        jobs.code = jobs.badge_key = str(uuid4())
        print("bootstrap: created project Jobs")
    jobs.api_key = hash_key(jobs_api_key)
    jobs.ping_key = jobs_ping_key
    jobs.show_slugs = True
    jobs.save()
    projects.append(jobs)

    # _make_user gave the default project an email integration; match it.
    if not Channel.objects.filter(project=jobs, kind="email").exists():
        Channel.objects.create(project=jobs, kind="email", value=email, email_verified=True)
        print("bootstrap: created email integration for Jobs")

# Matrix Infrastructure room, through matrix-media-relay as the
# @_webhooks_healthchecks ghost (own name + icon, like Uptime Kuma/Longhorn).
# Declared here rather than clicked into the UI so it survives a DB rebuild and
# follows relay-token rotation. The body is Healthchecks' structured
# placeholders, not a pre-rendered card: Healthchecks cannot HTML-escape a check
# name, so the relay renders the card (render_healthchecks in relay.py).
# Edits made to this integration in the UI are overwritten on the next start.
relay_url = os.environ.get("HC_MATRIX_RELAY_URL")
relay_token = os.environ.get("HC_MATRIX_RELAY_TOKEN")
if relay_url and relay_token:
    body = json.dumps(
        {"healthchecks": {"status": "$STATUS", "check": "@JSON@", "body": "@BODY@",
                          "site": settings.SITE_ROOT}}
    ).replace('"@JSON@"', "$JSON").replace('"@BODY@"', "$BODY_JSON")
    headers = {"Authorization": f"Bearer {relay_token}", "Content-Type": "application/json"}
    channel_name = "Matrix - Infrastructure"
    value = json.dumps(
        {
            "name": channel_name,
            "method_down": "POST", "url_down": relay_url, "body_down": body, "headers_down": headers,
            "method_up": "POST", "url_up": relay_url, "body_up": body, "headers_up": headers,
        },
        sort_keys=True,
    )
    for p in projects:
        channel = Channel.objects.filter(project=p, kind="webhook", name=channel_name).first()
        if channel is None:
            channel = Channel.objects.create(project=p, kind="webhook", name=channel_name, value=value)
            # Only on creation: unassigning a check from it later in the UI sticks.
            channel.checks.add(*Check.objects.filter(project=p))
            print(f"bootstrap: created Matrix webhook integration for {p.name}")
        elif channel.value != value:
            channel.value = value
            channel.save()
            print(f"bootstrap: updated Matrix webhook integration for {p.name}")
