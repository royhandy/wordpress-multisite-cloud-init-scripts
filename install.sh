#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# Globals
########################################
ENV_FILE="/etc/server.env"
STATE_DIR="/var/lib/server-template"
BOOTSTRAP_MARKER="${STATE_DIR}/bootstrap.completed"
INSTALL_MARKER="${STATE_DIR}/install.completed"

CERT_BASE="/etc/ssl/cf-origin"
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo "[install] $*"; }
die() { echo "[install] ERROR: $*" >&2; exit 1; }

########################################
# Safety checks
########################################
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Must be run as root"
}

refuse_cloud_init() {
  if systemctl is-active --quiet cloud-init 2>/dev/null; then
    die "Refusing to run under cloud-init"
  fi
  if [[ -f /etc/cloud/cloud-init.disabled ]]; then
    return 0
  fi
}

require_bootstrap() {
  [[ -f "${BOOTSTRAP_MARKER}" ]] || die "bootstrap.sh has not completed"
}

require_env() {
  [[ -f "${ENV_FILE}" ]] || die "/etc/server.env missing"
  # shellcheck disable=SC1091
  source "${ENV_FILE}"
}

########################################
# Helpers
########################################
ensure_dir() {
  install -d -o root -g root -m "${2:-0755}" "$1"
}

apt_safe_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

########################################
# Certificate validation
########################################
cert_for_domain_exists() {
  local domain="$1"
  [[ -s "${CERT_BASE}/${domain}/cert.pem" && -s "${CERT_BASE}/${domain}/key.pem" ]]
}

validate_primary_cert() {
  if ! cert_for_domain_exists "${WP_PRIMARY_DOMAIN}"; then
    cat <<EOF
========================================================================
Missing Cloudflare Origin Certificate for primary domain

Expected:
  ${CERT_BASE}/${WP_PRIMARY_DOMAIN}/cert.pem
  ${CERT_BASE}/${WP_PRIMARY_DOMAIN}/key.pem

Install the exact-hostname origin certificate, then re-run:
  ./install.sh
========================================================================
EOF
    exit 1
  fi
}

########################################
# Base packages
########################################
install_base_packages() {
  log "Installing base packages"
  apt_safe_install \
    ca-certificates curl gnupg lsb-release \
    cron logrotate unattended-upgrades \
    nftables msmtp bsd-mailx
}

########################################
# Firewall + Cloudflare
########################################
install_firewall() {
  log "Configuring firewall"
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/security/nftables.conf" /etc/nftables.conf
  systemctl enable --now nftables
}

install_cloudflare_update() {
  log "Installing Cloudflare IP updater"
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/security/cloudflare-update.sh" /usr/local/sbin/cloudflare-update
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/security/systemd/cloudflare-update.service" /etc/systemd/system/cloudflare-update.service
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/security/systemd/cloudflare-update.timer" /etc/systemd/system/cloudflare-update.timer
  systemctl daemon-reload
  systemctl enable --now cloudflare-update.timer
  /usr/local/sbin/cloudflare-update || true
}

########################################
# Database
########################################
install_db() {
  log "Installing MariaDB"
  apt_safe_install mariadb-server
  systemctl enable --now mariadb

  mysql <<SQL
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

########################################
# Redis
########################################
install_redis() {
  log "Installing Redis"
  apt_safe_install redis-server

  install -o root -g root -m 0644 "${TEMPLATE_DIR}/redis/redis.conf" /etc/redis/redis.conf
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/redis/redis-wrapper.sh" /usr/local/sbin/redis-wrapper

  ensure_dir /etc/systemd/system/redis-server.service.d 0755
  cat > /etc/systemd/system/redis-server.service.d/override.conf <<EOF
[Service]
EnvironmentFile=${ENV_FILE}
ExecStart=
ExecStart=/usr/local/sbin/redis-wrapper
EOF

  systemctl daemon-reload
  systemctl enable --now redis-server
}

########################################
# Web stack
########################################
install_web() {
  log "Installing nginx + PHP"
  apt_safe_install \
    nginx \
    php-fpm php-mysql php-redis php-curl php-gd php-mbstring php-xml php-zip

  install -o root -g root -m 0644 "${TEMPLATE_DIR}/nginx/nginx.conf" /etc/nginx/nginx.conf
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/nginx/catchall.conf" /etc/nginx/sites-available/catchall.conf

  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/catchall.conf /etc/nginx/sites-enabled/catchall.conf

  install -o root -g root -m 0644 "${TEMPLATE_DIR}/php/php.ini" /etc/php/*/fpm/conf.d/99-server-template.ini
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/php/php-fpm-pool.conf" /etc/php/*/fpm/pool.d/zz-server-template.conf

  ensure_dir /etc/systemd/system/php-fpm.service.d 0755
  cat > /etc/systemd/system/php-fpm.service.d/env.conf <<EOF
[Service]
EnvironmentFile=${ENV_FILE}
EOF

  systemctl daemon-reload
  systemctl enable --now php-fpm
}

########################################
# WordPress
########################################
install_wordpress() {
  log "Provisioning WordPress"
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/wordpress/provision-wordpress.sh" /usr/local/sbin/provision-wordpress
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/wordpress/wp-config.php" "${WEB_ROOT}/wp-config.php" || true
  /usr/local/sbin/provision-wordpress
}

########################################
# Alerts + MOTD
########################################
install_alerts() {
  log "Installing alert scripts"
  install -o root -g root -m 0755 "${TEMPLATE_DIR}/alerts/sendmail-wrapper.sh" /usr/sbin/sendmail
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/alerts/disk-check.sh" /usr/local/sbin/disk-check
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/alerts/reboot-check.sh" /usr/local/sbin/reboot-check
}

install_motd() {
  install -o root -g root -m 0755 "${TEMPLATE_DIR}/security/motd/99-server-template" /etc/update-motd.d/99-server-template
  install -o root -g root -m 0600 "${TEMPLATE_DIR}/SERVER.md" /root/SERVER.md
}

########################################
# Nginx startup
########################################
start_nginx() {
  log "Validating nginx configuration"
  nginx -t

  log "Starting nginx"
  systemctl enable --now nginx
}

########################################
# Main
########################################
main() {
  require_root
  refuse_cloud_init
  require_bootstrap
  require_env
  validate_primary_cert

  if [[ -f "${INSTALL_MARKER}" ]]; then
    log "Install already completed — reapplying idempotent steps"
  fi

  install_base_packages
  install_firewall
  install_cloudflare_update
  install_db
  install_redis
  install_web
  install_wordpress
  install_alerts
  install_motd
  start_nginx

  date -Is > "${INSTALL_MARKER}"
  chmod 0600 "${INSTALL_MARKER}"

  log "Install complete — system is live"
}

main "$@"
