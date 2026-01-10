#!/usr/bin/env bash
set -Eeuo pipefail

OFFICE_IP="${1:-}"

if [[ -z "${OFFICE_IP}" ]]; then
  echo "Usage: $0 <OFFICE_PUBLIC_IP_OR_CIDR>"
  exit 1
fi

log() { echo "[enable-ssh] $*"; }
die() { echo "[enable-ssh] ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root"

unit_exists() {
  local unit="$1"
  systemctl list-unit-files --all --no-legend --type=service --type=socket 2>/dev/null \
    | awk '{print $1}' \
    | grep -Fxq "${unit}"
}

unmask_unit() {
  local unit="$1"
  if unit_exists "${unit}"; then
    systemctl unmask "${unit}" 2>/dev/null || true
  fi
}

enable_and_start_service() {
  local unit="$1"
  if unit_exists "${unit}"; then
    systemctl enable "${unit}" 2>/dev/null || true
    systemctl restart "${unit}" 2>/dev/null || true
  fi
}

enable_and_start_socket() {
  local unit="$1"
  if unit_exists "${unit}"; then
    systemctl enable "${unit}" 2>/dev/null || true
    systemctl start "${unit}" 2>/dev/null || true
  fi
}

###############################################################################
# Unmask SSH early (CRITICAL)
###############################################################################

log "Unmasking SSH units (pre-install)"
unmask_unit ssh.service
unmask_unit sshd.service
unmask_unit ssh.socket

###############################################################################
# Install OpenSSH if missing
###############################################################################

if ! command -v sshd >/dev/null 2>&1; then
  log "Installing openssh-server"
  apt update
  apt install -y openssh-server
fi

###############################################################################
# Fix dpkg state if needed
###############################################################################

dpkg --configure -a || true

###############################################################################
# Unmask SSH after install (handles previously masked units)
###############################################################################

log "Unmasking SSH units (post-install)"
unmask_unit ssh.service
unmask_unit sshd.service
unmask_unit ssh.socket

###############################################################################
# SSH configuration (drop-in, Match Address)
###############################################################################

SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSHD_DROPIN_FILE="${SSHD_DROPIN_DIR}/90-enable-ssh.conf"

ensure_sshd_dropin() {
  install -d -o root -g root -m 0755 "${SSHD_DROPIN_DIR}"

  if ! grep -Eq '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_CONFIG}"; then
    echo "Include /etc/ssh/sshd_config.d/*.conf" >> "${SSHD_CONFIG}"
  fi

  cat > "${SSHD_DROPIN_FILE}" <<EOF
# Managed by enable_ssh.sh
PasswordAuthentication no
PermitRootLogin no

Match Address ${OFFICE_IP}
  PasswordAuthentication yes
  PermitRootLogin yes
EOF

  chmod 0644 "${SSHD_DROPIN_FILE}"
}

###############################################################################
# Enable + start SSH
###############################################################################

log "Configuring sshd drop-in for root/password access from ${OFFICE_IP} only"
ensure_sshd_dropin

if command -v sshd >/dev/null 2>&1; then
  sshd -t || die "sshd_config validation failed"
fi

log "Starting SSH service"
enable_and_start_service ssh.service
enable_and_start_service sshd.service
enable_and_start_socket ssh.socket

###############################################################################
# Firewall: allow SSH from office IP only
###############################################################################

NFT_INCLUDE_DIR="/etc/nftables.d"
NFT_INCLUDE_FILE="${NFT_INCLUDE_DIR}/ssh-allow.nft"
NFT_CONF="/etc/nftables.conf"
NFT_MARKER_BEGIN="# BEGIN enable_ssh managed"
NFT_MARKER_END="# END enable_ssh managed"

ensure_nftables_include() {
  install -d -o root -g root -m 0755 "${NFT_INCLUDE_DIR}"

  if [[ -f "${NFT_CONF}" ]] && grep -Fq "${NFT_MARKER_BEGIN}" "${NFT_CONF}"; then
    local tmp
    tmp="$(mktemp)"
    awk -v begin="${NFT_MARKER_BEGIN}" -v end="${NFT_MARKER_END}" '
      $0 == begin {print begin; print "include \"/etc/nftables.d/ssh-allow.nft\""; skip=1; next}
      $0 == end {skip=0; print end; next}
      !skip {print}
    ' "${NFT_CONF}" > "${tmp}"
    mv "${tmp}" "${NFT_CONF}"
  elif [[ -f "${NFT_CONF}" ]] && grep -Fq 'include "/etc/nftables.d/ssh-allow.nft"' "${NFT_CONF}"; then
    return 0
  else
    cat >> "${NFT_CONF}" <<EOF

${NFT_MARKER_BEGIN}
include "/etc/nftables.d/ssh-allow.nft"
${NFT_MARKER_END}
EOF
  fi
}

write_nftables_allowlist() {
  local family="ip"
  if [[ "${OFFICE_IP}" == *:* ]]; then
    family="ip6"
  fi

  cat > "${NFT_INCLUDE_FILE}" <<EOF
# Managed by enable_ssh.sh
add rule inet filter input ${family} saddr ${OFFICE_IP} tcp dport 22 accept
EOF
  chmod 0644 "${NFT_INCLUDE_FILE}"
}

reload_nftables() {
  if systemctl list-unit-files --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq nftables.service; then
    systemctl reload nftables || systemctl restart nftables
  elif command -v nft >/dev/null 2>&1; then
    nft -f "${NFT_CONF}"
  else
    die "nft command not available; cannot apply SSH firewall rule"
  fi
}

log "Allowing SSH from ${OFFICE_IP} via nftables (persistent include)"
ensure_nftables_include
write_nftables_allowlist
reload_nftables

###############################################################################
# Done
###############################################################################

log "SSH ENABLED (TEMPORARY)"
echo
echo "You may now SSH using:"
echo "  ssh root@<server-ip>"
echo
echo "IMPORTANT: When finished, lock SSH back down:"
echo "  systemctl stop ssh"
echo "  systemctl disable ssh"
echo "  systemctl mask ssh sshd ssh.socket"
echo "  apt purge -y openssh-server openssh-sftp-server"
echo
