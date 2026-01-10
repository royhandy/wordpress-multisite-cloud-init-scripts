#!/usr/bin/env bash
set -Eeuo pipefail

OFFICE_IP="${1:-}"

if [[ -z "${OFFICE_IP}" ]]; then
  echo "Usage: $0 <OFFICE_PUBLIC_IP>"
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
# Configure sshd_config (EXPLICIT)
###############################################################################

SSHD_CONFIG="/etc/ssh/sshd_config"

log "Configuring sshd_config for password auth + root login"

# Ensure PasswordAuthentication yes
if grep -Eq '^\s*PasswordAuthentication\s+' "${SSHD_CONFIG}"; then
  sed -i 's/^\s*#\?\s*PasswordAuthentication\s\+.*/PasswordAuthentication yes/' "${SSHD_CONFIG}"
else
  echo "PasswordAuthentication yes" >> "${SSHD_CONFIG}"
fi

# Ensure PermitRootLogin yes
if grep -Eq '^\s*PermitRootLogin\s+' "${SSHD_CONFIG}"; then
  sed -i 's/^\s*#\?\s*PermitRootLogin\s\+.*/PermitRootLogin yes/' "${SSHD_CONFIG}"
else
  echo "PermitRootLogin yes" >> "${SSHD_CONFIG}"
fi

###############################################################################
# Enable + start SSH
###############################################################################

log "Starting SSH service"
enable_and_start_service ssh.service
enable_and_start_service sshd.service
enable_and_start_socket ssh.socket

###############################################################################
# Firewall: allow SSH from office IP only
###############################################################################

log "Allowing SSH from ${OFFICE_IP} via nftables"
nft add rule inet filter input ip saddr "${OFFICE_IP}" tcp dport 22 accept

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
