#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/server.env"
WEB_ROOT="/var/www/wordpress"

log() { echo "[wp-provision] $*"; }

# Load environment
# shellcheck disable=SC1091
source "${ENV_FILE}"

mkdir -p "${WEB_ROOT}"
cd "${WEB_ROOT}"

# Install WP-CLI if missing
if ! command -v wp >/dev/null 2>&1; then
  log "Installing WP-CLI"
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /usr/local/bin/wp
  chmod +x /usr/local/bin/wp
fi

# Download WordPress core if missing
if [[ ! -f wp-settings.php ]]; then
  log "Downloading WordPress core"
  wp core download --locale=en_US --allow-root
fi

log "WordPress core ready"

# install Wordpress

log "Installing Wordpress"

wp core multisite-install \
  --url="$WP_PRIMARY_DOMAIN" \
  --title="$WP_PRIMARY_NAME" \
  --admin_user="$WP_ADMIN_USER" \
  --admin_password="$WP_ADMIN_PASSWORD" \
  --admin_email="$ADMIN_EMAIL" \
  --subdomains \
  --allow-root

# Now place wp-config.php
install -o root -g root -m 0640 \
  "${TEMPLATE_DIR}/wordpress/wp-config.php" \
  "${WEB_ROOT}/wp-config.php"
  
# Ensure ownership
chown -R www-data:www-data "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 0755 {} \;
find "${WEB_ROOT}" -type f -exec chmod 0644 {} \;
chmod 0640 "${WEB_ROOT}"/wp-config.php

log "Wordpress installed and file permissions set"
