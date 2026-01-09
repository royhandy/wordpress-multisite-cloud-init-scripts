#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/server.env"
WEB_ROOT="/var/www/wordpress"
TEMPLATE_DIR="/some/path"   # ← you need to define this!

log() { echo "[wp-provision] $*"; }

# Load environment
# shellcheck disable=SC1091
source "${ENV_FILE}"

mkdir -p "${WEB_ROOT}"
cd "${WEB_ROOT}"

# Install WP-CLI if missing
if ! command -v wp >/dev/null 2>&1; then
  log "Installing WP-CLI"
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o wp-cli.phar
  chmod +x wp-cli.phar
  mv wp-cli.phar /usr/local/bin/wp
fi

# Download WordPress core if missing
if [[ ! -f wp-settings.php ]]; then
  log "Downloading WordPress core"
  wp core download --locale=en_US --allow-root
fi

log "WordPress core ready"

# Very important: test DB connection early!
log "Testing database connection..."
wp db check --allow-root || { log "Database connection failed!"; exit 1; }

log "Installing WordPress Multisite"

# Copy your prepared wp-config.php FIRST (must contain DB credentials!)
install -o root -g root -m 0640 \
  "${TEMPLATE_DIR}/wordpress/wp-config.php" \
  "${WEB_ROOT}/wp-config.php"

wp core multisite-install \
  --url="$WP_PRIMARY_DOMAIN" \
  --title="$WP_PRIMARY_NAME" \
  --admin_user="$WP_ADMIN_USER" \
  --admin_password="$WP_ADMIN_PASSWORD" \
  --admin_email="$ADMIN_EMAIL" \
  --subdomains \
  --skip-email \
  --allow-root

# Ensure ownership & permissions
chown -R www-data:www-data "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 0755 {} +
find "${WEB_ROOT}" -type f -exec chmod 0644 {} +
chmod 0640 "${WEB_ROOT}/wp-config.php"

log "WordPress multisite installed and permissions set"
