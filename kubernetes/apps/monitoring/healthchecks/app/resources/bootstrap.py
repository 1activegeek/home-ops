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
# Note: the admin password is re-applied on every start. A password changed in
# the UI is reverted on the next restart; change it in 1Password instead.

import hmac
import os

from django.conf import settings
from django.contrib.auth.models import User

from hc.accounts.models import Project
from hc.accounts.views import _make_user
from hc.api.models import Check

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
