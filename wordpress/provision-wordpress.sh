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

# Ensure ownership
chown -R www-data:www-data "${WEB_ROOT}"

log "WordPress core ready"
