#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# Globals
########################################
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="/var/lib/server-template"
PROVISIONED_MARKER="${STATE_DIR}/provisioned"
ENV_FILE="/etc/server.env"

log() { echo "[server-template] $*"; }
die() { echo "[server-template] ERROR: $*" >&2; exit 1; }

########################################
# Safety checks
########################################
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Must run as root"
}

require_certificates() {
  [[ -s /etc/ssl/cf-origin.pem ]] || die "Missing Cloudflare origin cert (/etc/ssl/cf-origin.pem)"
  [[ -s /etc/ssl/cf-origin.key ]] || die "Missing Cloudflare origin key (/etc/ssl/cf-origin.key)"
}

########################################
# Helpers
########################################
ensure_dir() {
  install -d -o root -g root -m "${2:-0755}" "$1"
}

gen_secret() {
  openssl rand -base64 48 | tr -d '\n='
}

env_set_if_missing() {
  local key="$1" value="$2"
  grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null || echo "${key}=${value}" >> "${ENV_FILE}"
}

cert_present() {
  [[ -s /etc/ssl/cf-origin.pem && -s /etc/ssl/cf-origin.key ]]
}

########################################
# /etc/server.env
########################################
ensure_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    umask 077
    cat > "${ENV_FILE}" <<EOF
# Single source of truth for this server
# root:root 0600
EOF
    chmod 600 "${ENV_FILE}"
  fi

  # Core
  env_set_if_missing TZ "UTC"
  env_set_if_missing WEB_ROOT "/var/www/wordpress"

  # Database
  env_set_if_missing DB_NAME "wp_$(openssl rand -hex 4)"
  env_set_if_missing DB_USER "wp_$(openssl rand -hex 4)"
  env_set_if_missing DB_PASSWORD "$(gen_secret)"

  # Redis
  env_set_if_missing REDIS_PASSWORD "$(gen_secret)"

  # WordPress
  env_set_if_missing WP_PRIMARY_DOMAIN "example.invalid"
  env_set_if_missing WP_ADMIN_USER "admin"
  env_set_if_missing WP_ADMIN_PASSWORD "$(gen_secret)"
  env_set_if_missing WP_ADMIN_EMAIL "root@localhost"
  env_set_if_missing WP_SUBDOMAIN_INSTALL "1"

  # Mail
  env_set_if_missing MAILGUN_SMTP_HOST "smtp.mailgun.org"
  env_set_if_missing MAILGUN_SMTP_PORT "587"
  env_set_if_missing MAILGUN_SMTP_LOGIN ""
  env_set_if_missing MAILGUN_SMTP_PASSWORD ""
  env_set_if_missing MAIL_FROM "server@example.invalid"
  env_set_if_missing ALERT_EMAIL "root@localhost"

  # Alerts
  env_set_if_missing DISK_WARN_PCT "80"
  env_set_if_missing DISK_CRIT_PCT "90"
}

source_env() {
  # shellcheck disable=SC1091
  source "${ENV_FILE}"
  export TZ
}

########################################
# Base system hardening
########################################
disable_ssh() {
  log "Removing SSH completely"
  systemctl stop ssh sshd 2>/dev/null || true
  systemctl disable ssh sshd 2>/dev/null || true
  systemctl mask ssh sshd 2>/dev/null || true
  apt-get purge -y openssh-server openssh-sftp-server || true
  rm -rf /etc/ssh
}

install_base_packages() {
  apt-get update -y
  apt-get install -y \
    ca-certificates curl gnupg lsb-release \
    cron logrotate unattended-upgrades \
    nftables msmtp
}

########################################
# Firewall & Cloudflare
########################################
install_firewall() {
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/security/nftables.conf" /etc/nftables.conf
  systemctl enable --now nftables
}

install_cloudflare_update() {
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
  apt-get install -y mariadb-server
  systemctl enable --now mariadb

  mysql <<SQL
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

########################################
# Redis
########################################
install_redis() {
  apt-get install -y redis-server
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/redis/redis.conf" /etc/redis/redis.conf
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/redis/redis-wrapper.sh" /usr/local/sbin/redis-wrapper

  mkdir -p /etc/systemd/system/redis-server.service.d
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
  apt-get install -y nginx php-fpm php-mysql php-redis php-curl php-gd php-mbstring php-xml php-zip

  install -o root -g root -m 0644 "${TEMPLATE_DIR}/nginx/nginx.conf" /etc/nginx/nginx.conf
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/nginx/catchall.conf" /etc/nginx/sites-available/catchall.conf

  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/catchall.conf /etc/nginx/sites-enabled/catchall.conf

  install -o root -g root -m 0644 "${TEMPLATE_DIR}/php/php.ini" /etc/php/*/fpm/conf.d/99-server-template.ini
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/php/php-fpm-pool.conf" /etc/php/*/fpm/pool.d/zz-server-template.conf

  mkdir -p /etc/systemd/system/php-fpm.service.d
  cat > /etc/systemd/system/php-fpm.service.d/env.conf <<EOF
[Service]
EnvironmentFile=/etc/server.env
EOF

  systemctl daemon-reload
  systemctl enable php-fpm

  # Start PHP immediately
  systemctl start php-fpm

  if cert_present; then
    log "TLS cert present — starting nginx"
    systemctl enable nginx
    systemctl start nginx
  else
    log "TLS cert missing — nginx installed but NOT started"
    log "Install Cloudflare origin cert at:"
    log "  /etc/ssl/cf-origin.pem"
    log "  /etc/ssl/cf-origin.key"
    log "Then run: systemctl start nginx"
    systemctl disable nginx || true
  fi
}

########################################
# WordPress
########################################
install_wordpress() {
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/wordpress/provision-wordpress.sh" /usr/local/sbin/provision-wordpress
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/wordpress/wp-config.php" "${WEB_ROOT}/wp-config.php" || true
  /usr/local/sbin/provision-wordpress
}

########################################
# Alerts & MOTD
########################################
install_alerts() {
  install -o root -g root -m 0755 "${TEMPLATE_DIR}/alerts/sendmail-wrapper.sh" /usr/sbin/sendmail
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/alerts/disk-check.sh" /usr/local/sbin/disk-check
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/alerts/reboot-check.sh" /usr/local/sbin/reboot-check
}

install_motd() {
  install -o root -g root -m 0755 "${TEMPLATE_DIR}/security/motd/99-server-template" /etc/update-motd.d/99-server-template
  install -o root -g root -m 0600 "${TEMPLATE_DIR}/SERVER.md" /root/SERVER.md
}

########################################
# Main
########################################
main() {
  require_root
  require_certificates
  ensure_dir "${STATE_DIR}" 0700

  ensure_env_file
  source_env

  install_base_packages
  disable_ssh
  install_firewall
  install_cloudflare_update
  install_db
  install_redis
  install_web
  install_wordpress
  install_alerts
  install_motd

  date -Is > "${PROVISIONED_MARKER}"
  chmod 0600 "${PROVISIONED_MARKER}"

  log "Provisioning complete"

  if ! cert_present; then
    cat <<EOF

========================================================================
NGINX NOT STARTED (EXPECTED)
------------------------------------------------------------------------
Cloudflare origin certificate not found.

Install certificate at:
  /etc/ssl/cf-origin.pem
  /etc/ssl/cf-origin.key

Then start nginx:
  systemctl start nginx
========================================================================
EOF
fi
}

main "$@"
