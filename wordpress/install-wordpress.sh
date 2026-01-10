#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/server.env"
WEB_ROOT="/var/www/wordpress"
TEMPLATE_DIR="/opt/server-template"

log() { echo "[wp-provision] $*"; }
die() { echo "[wp-provision] ERROR: $*" >&2; exit 1; }

# Load environment
[[ -f "${ENV_FILE}" ]] || die "${ENV_FILE} missing"
set -a
# shellcheck disable=SC1091
source "${ENV_FILE}"
set +a

mkdir -p "${WEB_ROOT}"
cd "${WEB_ROOT}"

# Install WP-CLI if missing
if ! command -v wp >/dev/null 2>&1; then
  log "Installing WP-CLI"

  wp_cli_url="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
  wp_cli_sha_url="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar.sha512"

  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "${tmp_dir}"' RETURN
  wp_cli_phar="${tmp_dir}/wp-cli.phar"
  wp_cli_sha="${tmp_dir}/wp-cli.phar.sha512"

  curl -fsSL "${wp_cli_url}" -o "${wp_cli_phar}" || die "Failed to download WP-CLI"
  curl -fsSL "${wp_cli_sha_url}" -o "${wp_cli_sha}" || die "Failed to download WP-CLI checksum"

  (cd "${tmp_dir}" && sha512sum -c "$(basename "${wp_cli_sha}")") \
    || die "WP-CLI checksum verification failed"

  install -m 0755 "${wp_cli_phar}" /usr/local/bin/wp
fi

# Download WordPress core if missing
if [[ ! -f wp-settings.php ]]; then
  log "Downloading WordPress core"
  wp core download --locale=en_US --allow-root
fi

log "WordPress core ready"

# Copy wp-config FIRST so WP-CLI has DB credentials
install -o root -g root -m 0640 \
  "${TEMPLATE_DIR}/wordpress/wp-config.php" \
  "${WEB_ROOT}/wp-config.php"

# Very important: test DB connection early!
log "Testing database connection..."
wp db check --allow-root || { log "Database connection failed!"; exit 1; }

log "Installing WordPress Multisite"

wp_subdomain_install="${WP_SUBDOMAIN_INSTALL:-}"
case "${wp_subdomain_install,,}" in
  1|true) subdomain_args=(--subdomains) ;;
  *) subdomain_args=() ;;
esac

wp_primary_url="${WP_PRIMARY_URL:-https://${WP_PRIMARY_DOMAIN}}"
if [[ "${wp_primary_url}" != *"://"* ]]; then
  wp_primary_url="https://${wp_primary_url}"
fi

if wp core is-installed --allow-root; then
  if wp core is-installed --allow-root --network; then
    log "WordPress multisite already installed; skipping install"
  else
    log "WordPress already installed (non-multisite); skipping multisite install"
  fi
else
  wp core multisite-install \
    --url="${wp_primary_url}" \
    --title="$WP_PRIMARY_NAME" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASSWORD" \
    --admin_email="$ADMIN_EMAIL" \
    "${subdomain_args[@]}" \
    --skip-email \
    --allow-root
fi

# Ensure ownership & permissions
chown -R www-data:www-data "${WEB_ROOT}"
find "${WEB_ROOT}" -type d -exec chmod 0755 {} +
find "${WEB_ROOT}" -type f -exec chmod 0644 {} +
chmod 0640 "${WEB_ROOT}/wp-config.php"

log "WordPress multisite installed and permissions set"
