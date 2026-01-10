#!/usr/bin/env bash
set -Eeuo pipefail

OFFICE_IP="${1:-}"

if [[ -z "${OFFICE_IP}" ]]; then
  echo "Usage: $0 <OFFICE_PUBLIC_IP_OR_CIDR>"
  exit 1
fi

log() { echo "[enable-ssh] $*"; }
die() { echo "[enable-ssh] ERROR: $*" >&2; exit 1; }

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemctl is not available; OpenSSH post-install will fail without systemd."
  fi
  if [[ ! -d /run/systemd/system ]]; then
    die "systemd does not appear to be PID 1; OpenSSH post-install will fail."
  fi
}

[[ $EUID -eq 0 ]] || die "Must be run as root"
require_systemd

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
    systemctl unmask "${unit}" 2>/dev/null || true
    systemctl enable "${unit}" 2>/dev/null || true
    systemctl restart "${unit}" 2>/dev/null || true
  fi
}

enable_and_start_socket() {
  local unit="$1"
  if unit_exists "${unit}"; then
    systemctl unmask "${unit}" 2>/dev/null || true
    systemctl enable "${unit}" 2>/dev/null || true
    systemctl start "${unit}" 2>/dev/null || true
  fi
}

###############################################################################
# Unmask SSH early
###############################################################################

log "Unmasking SSH units (pre-install)"
unmask_unit ssh.service
unmask_unit sshd.service
unmask_unit ssh.socket

###############################################################################
# Install OpenSSH (Ubuntu 24.04 Compatibility Fix)
###############################################################################

if ! command -v sshd >/dev/null 2>&1; then
  log "Installing openssh-server"
  
  # Prevent 'deb-systemd-invoke' errors during install by blocking service start
  printf '#!/bin/sh\nexit 101' > /usr/sbin/policy-rc.d
  chmod +x /usr/sbin/policy-rc.d
  
  apt update
  apt install -y openssh-server
  
  rm -f /usr/sbin/policy-rc.d
fi

dpkg --configure -a || true

###############################################################################
# SSH configuration
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

log "Configuring sshd drop-in for ${OFFICE_IP}"
ensure_sshd_dropin

# Fix for "Missing privilege separation directory"
if [[ ! -d /run/sshd ]]; then
    mkdir -p /run/sshd
    chmod 0755 /run/sshd
fi

if command -v sshd >/dev/null 2>&1; then
  sshd -t || die "sshd_config validation failed"
fi

log "Starting SSH service and socket"
enable_and_start_socket ssh.socket
enable_and_start_service ssh.service

###############################################################################
# Firewall (nftables)
###############################################################################

NFT_CONF="/etc/nftables.conf"
NFT_INCLUDE_FILE="/etc/nftables.d/ssh-allow.nft"

reload_nftables() {
  if systemctl list-unit-files --no-legend | grep -Fxq nftables.service; then
    log "Ensuring nftables is active"
    systemctl enable nftables >/dev/null 2>&1
    systemctl start nftables >/dev/null 2>&1
    systemctl reload nftables || systemctl restart nftables
  elif command -v nft >/dev/null 2>&1; then
    nft -f "${NFT_CONF}"
  fi
}

log "Allowing SSH from ${OFFICE_IP} via nftables"
mkdir -p /etc/nftables.d
cat > "${NFT_INCLUDE_FILE}" <<EOF
add rule inet filter input ip saddr ${OFFICE_IP} tcp dport 22 accept
EOF

# Ensure include exists in main conf
if [[ -f "${NFT_CONF}" ]] && ! grep -q "ssh-allow.nft" "${NFT_CONF}"; then
    echo 'include "/etc/nftables.d/ssh-allow.nft"' >> "${NFT_CONF}"
fi

reload_nftables

log "SSH ENABLED"
echo "You may now login: ssh root@<server-ip>"
