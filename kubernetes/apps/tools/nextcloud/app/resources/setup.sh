#!/bin/sh
# Nextcloud before-starting hook: installs Nextcloud if it isn't yet and converges the settings
# below on every start, so the instance can be rebuilt from git plus the database and data share.
#
# The image's own auto-install only runs when no version.php exists on the volume. A failed first
# install leaves version.php behind and the instance stuck at the setup wizard forever, so the
# install is driven from here instead.
set -eu

occ() { php /var/www/html/occ "$@"; }

if ! occ status --output=json | grep -q '"installed":true'; then
    echo "=> Installing Nextcloud"
    occ maintenance:install -n \
        --database pgsql \
        --database-host "$POSTGRES_HOST" \
        --database-name "$POSTGRES_DB" \
        --database-user "$POSTGRES_USER" \
        --database-pass "$POSTGRES_PASSWORD" \
        --admin-user "$NEXTCLOUD_ADMIN_USER" \
        --admin-pass "$NEXTCLOUD_ADMIN_PASSWORD" \
        --data-dir "$NEXTCLOUD_DATA_DIR"
fi

if occ status --output=json | grep -q '"maintenance":true'; then
    echo "=> Maintenance mode is on; skipping configuration"
    exit 0
fi

echo "=> Applying system configuration"
occ config:system:set trusted_domains 0 --value="$NEXTCLOUD_DOMAIN"
occ config:system:set overwrite.cli.url --value="https://$NEXTCLOUD_DOMAIN"
occ config:system:set default_phone_region --value="$NEXTCLOUD_PHONE_REGION"
# Hour (UTC) after which heavy background jobs may run.
occ config:system:set maintenance_window_start --type=integer --value=8
# The OIDC discovery URL resolves to the internal gateway, a private address Nextcloud's HTTP
# client refuses by default.
occ config:system:set allow_local_remote_servers --type=boolean --value=true
occ background:cron
occ db:add-missing-indices
occ db:add-missing-columns
occ db:add-missing-primary-keys
occ maintenance:repair --include-expensive >/dev/null

echo "=> Configuring Authentik login"
if ! occ app:list --output=json | grep -q '"user_oidc"'; then
    occ app:install user_oidc || {
        echo "==> user_oidc could not be installed (app store unreachable?); retrying on next start"
        exit 0
    }
fi
occ app:enable user_oidc
occ user_oidc:provider authentik \
    --clientid="$OIDC_CLIENT_ID" \
    --clientsecret="$OIDC_CLIENT_SECRET" \
    --discoveryuri="$OIDC_DISCOVERY_URI" \
    --scope="openid email profile" \
    --unique-uid=0 \
    --mapping-uid=preferred_username \
    --mapping-display-name=name \
    --mapping-email=email
# One user backend means /login redirects straight to Authentik, so a browser that already has an
# Authentik session lands in Nextcloud without a prompt. The local admin still signs in at
# /login?direct=1.
occ config:app:set user_oidc allow_multiple_user_backends --value=0
