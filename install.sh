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
TEMPLATE_DIR="/opt/server-template"

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
disable_ufw_if_present() {
  if command -v ufw >/dev/null 2>&1 || [[ -f /etc/ufw/ufw.conf ]]; then
    log "UFW detected; disabling"
    if command -v ufw >/dev/null 2>&1; then
      ufw disable || log "UFW disable command failed"
    else
      log "ufw command missing; skipping ufw disable command"
    fi
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -qx "ufw.service"; then
        systemctl disable --now ufw || log "UFW systemd service disable failed"
      else
        log "UFW systemd service not found; skipping systemctl disable"
      fi
    fi
  else
    log "UFW not detected; skipping disable"
  fi
}

ensure_dir() {
  install -d -o root -g root -m "${2:-0755}" "$1"
}

apt_safe_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

derive_cert_domain() {
  local domain="$1"
  local -a labels

  if [[ -z "${domain}" ]]; then
    echo ""
    return 0
  fi

  if [[ "${domain}" != *.* ]]; then
    echo "${domain}"
    return 0
  fi

  IFS='.' read -r -a labels <<<"${domain}"

  if (( ${#labels[@]} <= 2 )); then
    echo "${domain}"
    return 0
  fi

  if (( ${#labels[@]} == 3 )); then
    local second="${labels[1]}"
    local last="${labels[2]}"
    if (( ${#last} == 2 && ${#second} <= 3 )); then
      echo "${domain}"
      return 0
    fi
  fi

  echo "${domain#*.}"
}

resolve_cert_domain() {
  if [[ -n "${CERT_DOMAIN:-}" ]]; then
    return 0
  fi

  CERT_DOMAIN="$(derive_cert_domain "${WP_PRIMARY_DOMAIN}")"
  if [[ -z "${CERT_DOMAIN}" ]]; then
    die "CERT_DOMAIN is empty and could not be derived from WP_PRIMARY_DOMAIN"
  fi
}

########################################
# Certificate validation
########################################
cert_for_domain_exists() {
  local domain="$1"
  [[ -s "${CERT_BASE}/${domain}/cert.pem" && -s "${CERT_BASE}/${domain}/key.pem" ]]
}

validate_primary_cert() {
  if ! cert_for_domain_exists "${CERT_DOMAIN}"; then
    cat <<EOF
========================================================================
Missing Cloudflare Origin Certificate for primary domain

Expected:
  ${CERT_BASE}/${CERT_DOMAIN}/cert.pem
  ${CERT_BASE}/${CERT_DOMAIN}/key.pem

Install the base-domain origin certificate (or set CERT_DOMAIN), then re-run:
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
    php-fpm php-mysql php-redis php-curl php-gd php-mbstring php-xml php-zip php8.3-intl npm

  install -o root -g root -m 0644 "${TEMPLATE_DIR}/nginx/nginx.conf" /etc/nginx/nginx.conf
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/nginx/catchall.conf" /etc/nginx/sites-available/catchall.conf

  install -o root -g root -m 0644 \
    "${TEMPLATE_DIR}/nginx/conf.d/cloudflare-realip.conf" \
    /etc/nginx/conf.d/cloudflare-realip.conf

  install -o root -g root -m 0644 \
    "${TEMPLATE_DIR}/nginx/blocked-ips.conf" \
    /etc/nginx/blocked-ips.conf

  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/catchall.conf /etc/nginx/sites-enabled/catchall.conf

  PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
  PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
  
  install -o root -g root -m 0644 \
    "${TEMPLATE_DIR}/php/php.ini" \
    "/etc/php/${PHP_VERSION}/fpm/conf.d/99-server-template.ini"
  
  OLD_POOL_CONF="/etc/php/${PHP_VERSION}/fpm/pool.d/zz-server-template.conf"
  if [[ -f "${OLD_POOL_CONF}" ]]; then
    rm -f "${OLD_POOL_CONF}"
  fi

  install -o root -g root -m 0644 \
    "${TEMPLATE_DIR}/php/php-fpm-pool.conf" \
    "/etc/php/${PHP_VERSION}/fpm/pool.d/server.conf"

  ensure_dir /etc/systemd/system/php-fpm.service.d 0755
  cat > /etc/systemd/system/php-fpm.service.d/env.conf <<EOF
[Service]
EnvironmentFile=${ENV_FILE}
EOF

  systemctl daemon-reload
  systemctl enable --now "${PHP_FPM_SERVICE}"
}

########################################
# Node.js
########################################
install_nodejs() {
  if command -v node >/dev/null 2>&1; then
    NODE_MAJOR="$(node -v | sed 's/^v//' | cut -d. -f1)"
    if [ "$NODE_MAJOR" -ge 20 ]; then
      echo "[install] Node.js already installed (v$(node -v))"
      return 0
    fi
    echo "[install] Node.js present but too old, upgrading"
  else
    echo "[install] Node.js not found, installing"
  fi

  curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    || { echo "Failed to add NodeSource repo"; exit 1; }

  apt update
  apt install -y nodejs \
    || { echo "Failed to install nodejs"; exit 1; }

  node -v || exit 1
  npm -v || exit 1
}

########################################
# WordPress
########################################
install_wordpress() {
  log "Provisioning WordPress"

  ensure_dir "${WEB_ROOT}" 0755

  # Load the server env variables
  mkdir -p /etc/systemd/system/${PHP_FPM_SERVICE}.service.d
  cat > /etc/systemd/system/${PHP_FPM_SERVICE}.service.d/env.conf <<'EOF'
[Service]
EnvironmentFile=/etc/server.env
EOF

  systemctl daemon-reload
  systemctl restart ${PHP_FPM_SERVICE}

  # Install provision script
  install -o root -g root -m 0750 \
    "${TEMPLATE_DIR}/wordpress/install-wordpress.sh" \
    /usr/local/sbin/install-wordpress

  # Run provisioner FIRST (downloads core, creates structure)
  /usr/local/sbin/install-wordpress

  
}


########################################
# Install Filament
########################################
install_filament() {
  log "Installing Filament"
  
  # Install filament installer script
  install -o root -g root -m 0750 \
    "${TEMPLATE_DIR}/filament/install_filament.sh" \
    /usr/local/sbin/install_filament
  
  # Run the installer
  /usr/local/sbin/install_filament
}


########################################
# Server admin NGINX and Firewall, SSL Catchall Conf
########################################
install_server_admin_nginx() {
    set -e

    echo "Setting up server-admin nginx configuration..."

    # Required variables
    : "${WP_PRIMARY_DOMAIN:?WP_PRIMARY_DOMAIN is not set}"
    : "${CERT_DOMAIN:?CERT_DOMAIN is not set}"

    NGINX_AVAILABLE="/etc/nginx/sites-available"
    NGINX_ENABLED="/etc/nginx/sites-enabled"
    local TEMPLATE_DIR="${TEMPLATE_DIR}/nginx"

    ADMIN_CONF="server-admin.conf"
    CATCHALL_CONF="catchall.conf"

    CERT_PATH="/etc/ssl/cf-origin/${CERT_DOMAIN}/cert.pem"
    KEY_PATH="/etc/ssl/cf-origin/${CERT_DOMAIN}/key.pem"

    # -----------------------------
    # Copy server-admin.conf
    # -----------------------------
    echo "Installing ${ADMIN_CONF}..."

    install -m 644 \
        "${TEMPLATE_DIR}/${ADMIN_CONF}" \
        "${NGINX_AVAILABLE}/${ADMIN_CONF}"

    # Replace server_name
    sed -i \
        "s/server_name .*;/server_name ${WP_PRIMARY_DOMAIN};/" \
        "${NGINX_AVAILABLE}/${ADMIN_CONF}"

    # Replace SSL paths
    sed -i \
        "s|ssl_certificate .*;|ssl_certificate     ${CERT_PATH};|" \
        "${NGINX_AVAILABLE}/${ADMIN_CONF}"

    sed -i \
        "s|ssl_certificate_key .*;|ssl_certificate_key ${KEY_PATH};|" \
        "${NGINX_AVAILABLE}/${ADMIN_CONF}"

    # -----------------------------
    # Update catchall.conf SSL paths
    # -----------------------------
    echo "Updating SSL paths in ${CATCHALL_CONF}..."

    # Replace server_name
    sed -i \
        "s/server_name .*;/server_name ${WP_PRIMARY_DOMAIN};/" \
        "${NGINX_AVAILABLE}/${CATCHALL_CONF}"

    sed -i \
        "s|ssl_certificate .*;|ssl_certificate     ${CERT_PATH};|" \
        "${NGINX_AVAILABLE}/${CATCHALL_CONF}"

    sed -i \
        "s|ssl_certificate_key .*;|ssl_certificate_key ${KEY_PATH};|" \
        "${NGINX_AVAILABLE}/${CATCHALL_CONF}"

    # -----------------------------
    # Enable server-admin site
    # -----------------------------
    if [ ! -L "${NGINX_ENABLED}/${ADMIN_CONF}" ]; then
        ln -s \
            "${NGINX_AVAILABLE}/${ADMIN_CONF}" \
            "${NGINX_ENABLED}/${ADMIN_CONF}"
    fi

    # -----------------------------
    # Firewall: allow 8443
    # -----------------------------
    if command -v nft >/dev/null 2>&1; then
        echo "Allowing TCP 8443 in nftables..."

        nft list ruleset | grep -q "tcp dport 8443" || \
        nft add rule inet filter input tcp dport 8443 ct state new accept
    fi

    # -----------------------------
    # Reload nginx once
    # -----------------------------
    echo "Reloading nginx..."
    nginx -t
    systemctl reload nginx

    echo "server-admin nginx configuration complete."
}


########################################
# Alerts + MOTD
########################################
install_alerts() {
  log "Installing alert scripts"
  install -o root -g root -m 0755 "${TEMPLATE_DIR}/alerts/sendmail-wrapper.sh" /usr/sbin/sendmail
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/alerts/send-email.sh" /usr/local/sbin/send-email
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/alerts/disk-check.sh" /usr/local/sbin/disk-check
  install -o root -g root -m 0750 "${TEMPLATE_DIR}/alerts/reboot-check.sh" /usr/local/sbin/reboot-check

  install -o root -g root -m 0644 "${TEMPLATE_DIR}/security/systemd/disk-check.service" /etc/systemd/system/disk-check.service
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/security/systemd/disk-check.timer" /etc/systemd/system/disk-check.timer
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/security/systemd/reboot-check.service" /etc/systemd/system/reboot-check.service
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/security/systemd/reboot-check.timer" /etc/systemd/system/reboot-check.timer

  systemctl daemon-reload
  systemctl enable --now disk-check.timer
  systemctl enable --now reboot-check.timer
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
  resolve_cert_domain
  disable_ufw_if_present
  validate_primary_cert

  if [[ -f "${INSTALL_MARKER}" ]]; then
    log "Install already completed — reapplying idempotent steps"
  fi

  install_base_packages
  install_firewall
  install_db
  install_redis
  install_web
  install_nodejs
  install_wordpress
  install_filament
  install_server_admin_nginx
  install_alerts
  install_motd
  install_cloudflare_update
  start_nginx

  date -Is > "${INSTALL_MARKER}"
  chmod 0600 "${INSTALL_MARKER}"

  log "Install complete — system is live"
}

main "$@"
