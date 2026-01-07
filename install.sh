#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# Globals
########################################
TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="/etc/server.env"
CERT_DIR="/etc/ssl/cf-origin"

log() { echo "[install] $*"; }
die() { echo "[install] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must run as root"

########################################
# Helpers
########################################
any_cert_present() {
  compgen -G "${CERT_DIR}/*.pem" > /dev/null
}

########################################
# Source env
########################################
# shellcheck disable=SC1091
source "${ENV_FILE}"
export TZ

########################################
# Firewall + Cloudflare
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
# Web stack
########################################
install_web() {
  apt-get install -y nginx php-fpm php-mysql php-redis php-curl php-gd php-mbstring php-xml php-zip

  install -o root -g root -m 0644 "${TEMPLATE_DIR}/nginx/nginx.conf" /etc/nginx/nginx.conf
  install -o root -g root -m 0644 "${TEMPLATE_DIR}/nginx/catchall.conf" /etc/nginx/sites-available/catchall.conf

  rm -f /etc/nginx/sites-enabled/default
  ln -sf /etc/nginx/sites-available/catchall.conf /etc/nginx/sites-enabled/catchall.conf

  systemctl enable php-fpm
  systemctl start php-fpm

  if any_cert_present; then
    systemctl enable nginx
    systemctl start nginx
  else
    log "No certs found — nginx installed but not started"
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
# Alerts + MOTD
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
  install_firewall
  install_cloudflare_update
  install_web
  install_wordpress
  install_alerts
  install_motd

  log "Install complete"
}

main "$@"
