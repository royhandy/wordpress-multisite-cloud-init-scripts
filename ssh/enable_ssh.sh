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

###############################################################################
# Unmask SSH early (CRITICAL)
###############################################################################

log "Unmasking SSH units (pre-install)"
systemctl unmask ssh ssh.socket 2>/dev/null || true

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
systemctl enable ssh
systemctl restart ssh

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
echo "  systemctl mask ssh ssh.socket"
echo "  apt purge -y openssh-server openssh-sftp-server"
echo
