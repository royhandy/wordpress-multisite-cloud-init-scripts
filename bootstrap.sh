#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# Globals
########################################
ENV_FILE="/etc/server.env"
STATE_DIR="/var/lib/server-template"
CERT_BASE="/etc/ssl/cf-origin"
BOOTSTRAP_MARKER="${STATE_DIR}/bootstrap.completed"

log() { echo "[bootstrap] $*"; }
die() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

########################################
# Safety
########################################
require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Must be run as root"
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

gen_short_secret() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10
}

gen_short_secret2() {
  tr -dc 'A-Za-z0-9' </dev/urandom | head -c 10
}

env_set_if_missing() {
  local key="$1" value="$2"
  grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null || echo "${key}=${value}" >> "${ENV_FILE}"
}

########################################
# Disable cloud-init permanently
########################################
disable_cloud_init() {
  log "Disabling cloud-init permanently"
  touch /etc/cloud/cloud-init.disabled
}

########################################
# Disable SSH permanently
########################################
disable_ssh() {
  log "Removing SSH completely (console-only access)"
  systemctl stop ssh sshd 2>/dev/null || true
  systemctl disable ssh sshd 2>/dev/null || true
  systemctl mask ssh sshd 2>/dev/null || true

  apt-get purge -y openssh-server openssh-sftp-server || true
  rm -rf /etc/ssh
}

########################################
# /etc/server.env
########################################
ensure_env_file() {
  if [[ ! -f "${ENV_FILE}" ]]; then
    umask 077
    cat > "${ENV_FILE}" <<'EOF'
# =====================================================
# server.env — single source of truth
# Generated once by bootstrap.sh
# root:root 0600
# =====================================================
EOF
    chmod 600 "${ENV_FILE}"
    chown root:root "${ENV_FILE}"
  fi

  # Core
  env_set_if_missing TZ "UTC"
  env_set_if_missing WEB_ROOT "/var/www/wordpress"
  env_set_if_missing STATE_DIR "${STATE_DIR}"
  env_set_if_missing ADMIN_NAME "Admin User"
  env_set_if_missing ADMIN_EMAIL "root@localhost"

  # Filament Server Admin App
  env_set_if_missing FILAMENT_ADMIN_PASSWORD "$(gen_short_secret)"

  # Database (generated once)
  env_set_if_missing DB_NAME "wp_$(openssl rand -hex 4)"
  env_set_if_missing DB_USER "wp_$(openssl rand -hex 4)"
  env_set_if_missing DB_PASSWORD "$(gen_secret)"

  # Redis
  env_set_if_missing REDIS_PASSWORD "$(gen_secret)"

  # WordPress core
  env_set_if_missing WP_PRIMARY_DOMAIN "example.invalid"
  env_set_if_missing WP_PRIMARY_NAME "Wordpress Network"
  env_set_if_missing WP_ADMIN_USER "admin"
  env_set_if_missing WP_ADMIN_PASSWORD "$(gen_short_secret2)"
  env_set_if_missing WP_SUBDOMAIN_INSTALL "1"

  # WordPress auth keys & salts (CRITICAL — generate once)
  env_set_if_missing WP_AUTH_KEY "$(gen_secret)"
  env_set_if_missing WP_SECURE_AUTH_KEY "$(gen_secret)"
  env_set_if_missing WP_LOGGED_IN_KEY "$(gen_secret)"
  env_set_if_missing WP_NONCE_KEY "$(gen_secret)"
  env_set_if_missing WP_AUTH_SALT "$(gen_secret)"
  env_set_if_missing WP_SECURE_AUTH_SALT "$(gen_secret)"
  env_set_if_missing WP_LOGGED_IN_SALT "$(gen_secret)"
  env_set_if_missing WP_NONCE_SALT "$(gen_secret)"

  # Mail (configured later)
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

########################################
# Certificate directory layout
########################################
prepare_cert_directories() {
  log "Preparing Cloudflare Origin cert directories"

  ensure_dir "${CERT_BASE}" 0755

  # Per-domain layout:
  # /etc/ssl/cf-origin/example.com/cert.pem
  # /etc/ssl/cf-origin/example.com/key.pem
  chmod 0755 "${CERT_BASE}"
}

########################################
# State directory
########################################
prepare_state_dir() {
  ensure_dir "${STATE_DIR}" 0700
}

########################################
# Install Enable SSH Script
########################################
install_enable_ssh() {
  log "Installing enable_ssh helper"

  install -o root -g root -m 0755 \
    "${TEMPLATE_DIR}/ssh/enable_ssh.sh" \
    /usr/local/sbin/enable_ssh
}

########################################
# Main
########################################
main() {
  require_root

  if [[ -f "${BOOTSTRAP_MARKER}" ]]; then
    log "Bootstrap already completed — exiting"
    exit 0
  fi

  log "Starting bootstrap phase (cloud-init safe)"

  prepare_state_dir
  ensure_env_file
  prepare_cert_directories

  disable_ssh
  disable_cloud_init

  date -Is > "${BOOTSTRAP_MARKER}"
  chmod 0600 "${BOOTSTRAP_MARKER}"

  log "Bootstrap complete"
  log "Next steps:"
  log "  1. Upload Cloudflare Origin certs to ${CERT_BASE}/<domain>/"
  log "  2. Edit /etc/server.env (domain + mail credentials)"
  log "  3. Run: /opt/server-template/install.sh"
  log "  ---"
  log "  enable_ssh [YOUR_IP_ADDRESS] to allow SSH"
}

main "$@"
