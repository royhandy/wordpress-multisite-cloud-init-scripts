#!/usr/bin/env bash
set -Eeuo pipefail

log() { echo "[wp-provision] $*"; }
die() { echo "[wp-provision] ERROR: $*" >&2; exit 1; }

# shellcheck disable=SC1091
source /etc/server.env

WEB_ROOT="${WEB_ROOT:-/var/www/wordpress}"
WP_CLI="/usr/local/bin/wp"

install_wp_cli() {
  if [[ -x "${WP_CLI}" ]]; then
    return 0
  fi
  log "Installing wp-cli"
  curl -fsSLo "${WP_CLI}" https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod 0755 "${WP_CLI}"
}

wp() {
  "${WP_CLI}" --path="${WEB_ROOT}" --allow-root "$@"
}

ensure_web_root() {
  install -d -o www-data -g www-data -m 0755 "${WEB_ROOT}"
}

download_core_if_needed() {
  if [[ -f "${WEB_ROOT}/wp-includes/version.php" ]]; then
    return 0
  fi
  log "Downloading WordPress core"
  wp core download --skip-content
}

install_multisite_if_needed() {
  if wp core is-installed >/dev/null 2>&1; then
    log "WordPress already installed"
    return 0
  fi

  local url="https://${WP_PRIMARY_DOMAIN}"

  log "Installing WordPress multisite (${url})"
  wp core multisite-install \
    --url="${url}" \
    --title="WordPress Network" \
    --admin_user="${WP_ADMIN_USER}" \
    --admin_password="${WP_ADMIN_PASSWORD}" \
    --admin_email="${WP_ADMIN_EMAIL}" \
    --subdomains="$([[ "${WP_SUBDOMAIN_INSTALL}" == "1" ]] && echo 1 || echo 0)"
}

install_redis_cache() {
  if ! wp plugin is-installed redis-cache >/dev/null 2>&1; then
    log "Installing redis-cache plugin"
    wp plugin install redis-cache --activate --quiet
  else
    wp plugin activate redis-cache >/dev/null 2>&1 || true
  fi

  wp redis enable >/dev/null 2>&1 || true
}

lock_down_filesystem() {
  log "Locking filesystem permissions"

  chown -R www-data:www-data "${WEB_ROOT}"

  find "${WEB_ROOT}" -type d -exec chmod 0755 {} \;
  find "${WEB_ROOT}" -type f -exec chmod 0644 {} \;

  install -d -o www-data -g www-data -m 0775 "${WEB_ROOT}/wp-content/uploads"
  install -d -o www-data -g www-data -m 0775 "${WEB_ROOT}/wp-content/cache"
}

main() {
  install_wp_cli
  ensure_web_root
  download_core_if_needed

  install -o root -g root -m 0644 \
    "$(dirname "$0")/wp-config.php" \
    "${WEB_ROOT}/wp-config.php"

  install_multisite_if_needed
  install_redis_cache
  lock_down_filesystem

  log "WordPress provisioning complete"
}

main "$@"
