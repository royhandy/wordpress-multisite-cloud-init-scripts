#!/usr/bin/env bash
set -Eeuo pipefail

LOCK="/var/lock/cloudflare-update.lock"
exec 9>"${LOCK}"
flock -n 9 || exit 0

# shellcheck disable=SC1091
source /etc/server.env

STATE_DIR="${STATE_DIR:-/var/lib/server-template}"
CF_STATE="${STATE_DIR}/cloudflare"
REALIP_CONF="/etc/nginx/conf.d/cloudflare-realip.conf"

CF_V4_URL="https://www.cloudflare.com/ips-v4"
CF_V6_URL="https://www.cloudflare.com/ips-v6"

mkdir -p "${CF_STATE}"
chmod 0700 "${STATE_DIR}" "${CF_STATE}"

log() { echo "[cloudflare-update] $*"; }

alert() {
  [[ -n "${ALERT_EMAIL:-}" ]] || return 0
  /usr/local/sbin/send-email \
    --to "${ALERT_EMAIL}" \
    --subject "[server] Cloudflare IP update FAILED on $(hostname -f)" \
    --body "$1" || true
}

fetch() {
  curl -fsS "$1" | awk 'NF' | tr -d '\r'
}

apply_set() {
  local family="$1" set="$2" file="$3"
  nft flush set inet filter "${set}" || true
  while read -r cidr; do
    nft add element inet filter "${set}" { "${cidr}" } || true
  done < "${file}"
}

regen_realip() {
  local v4="$1" v6="$2" out="$3"

  {
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
    while read -r cidr; do echo "set_real_ip_from ${cidr};"; done < "${v4}"
    while read -r cidr; do echo "set_real_ip_from ${cidr};"; done < "${v6}"
  } > "${out}.tmp"

  chmod 0644 "${out}.tmp"
  mv "${out}.tmp" "${out}"
}

main() {
  local v4="${CF_STATE}/ips-v4.txt"
  local v6="${CF_STATE}/ips-v6.txt"

  local old_v4 old_v6
  old_v4="$(sha256sum "${v4}" 2>/dev/null | awk '{print $1}')"
  old_v6="$(sha256sum "${v6}" 2>/dev/null | awk '{print $1}')"

  fetch "${CF_V4_URL}" > "${v4}.new" || { alert "Failed to fetch IPv4 list"; exit 1; }
  fetch "${CF_V6_URL}" > "${v6}.new" || { alert "Failed to fetch IPv6 list"; exit 1; }

  mv "${v4}.new" "${v4}"
  mv "${v6}.new" "${v6}"

  local new_v4 new_v6
  new_v4="$(sha256sum "${v4}" | awk '{print $1}')"
  new_v6="$(sha256sum "${v6}" | awk '{print $1}')"

  if [[ "${old_v4}" != "${new_v4}" || "${old_v6}" != "${new_v6}" ]]; then
    log "Cloudflare IP ranges changed; applying firewall + nginx real IP"

    nft -f /etc/nftables.conf

    apply_set ip  cf4 "${v4}"
    apply_set ip6 cf6 "${v6}"

    local old_realip
    old_realip="$(sha256sum "${REALIP_CONF}" 2>/dev/null | awk '{print $1}')"

    regen_realip "${v4}" "${v6}" "${REALIP_CONF}"

    local new_realip
    new_realip="$(sha256sum "${REALIP_CONF}" | awk '{print $1}')"

    if [[ "${old_realip}" != "${new_realip}" ]]; then
      if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
      else
        alert "nginx -t failed after regenerating real IP config"
        exit 1
      fi
    fi
  fi
}

main
