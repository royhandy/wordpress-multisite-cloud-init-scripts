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
# Enable password auth
###############################################################################

SSHD_CONFIG="/etc/ssh/sshd_config"

log "Enabling password authentication"

sed -i \
  -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
  "${SSHD_CONFIG}"

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
echo "SSH is now available from ${OFFICE_IP}"
echo "When finished:"
echo "  systemctl stop ssh"
echo "  systemctl disable ssh"
echo "  systemctl mask ssh ssh.socket"
echo "  apt purge -y openssh-server openssh-sftp-server"
