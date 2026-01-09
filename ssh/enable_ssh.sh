#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# enable_ssh.sh
#
# Temporarily enables SSH access from a single IP address.
# Intended for break-glass / maintenance access only.
#
# REQUIREMENTS:
# - Run as root
# - nftables in use
###############################################################################

OFFICE_IP="${1:-}"

if [[ -z "${OFFICE_IP}" ]]; then
  echo "Usage: $0 <OFFICE_PUBLIC_IP>"
  exit 1
fi

log() {
  echo "[enable-ssh] $*"
}

die() {
  echo "[enable-ssh] ERROR: $*" >&2
  exit 1
}

[[ $EUID -eq 0 ]] || die "Must be run as root"

###############################################################################
# Ensure OpenSSH is installed
###############################################################################

if ! command -v sshd >/dev/null 2>&1; then
  log "Installing openssh-server"
  apt update
  apt install -y openssh-server
fi

###############################################################################
# Enable SSH service
###############################################################################

log "Unmasking and enabling SSH service"
systemctl unmask ssh
systemctl enable ssh
systemctl start ssh

###############################################################################
# Enable password authentication
###############################################################################

SSHD_CONFIG="/etc/ssh/sshd_config"

log "Configuring sshd for password authentication"

sed -i \
  -e 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
  -e 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
  "${SSHD_CONFIG}"

systemctl restart ssh

###############################################################################
# Firewall: allow SSH from office IP only
###############################################################################

log "Adding nftables rule to allow SSH from ${OFFICE_IP}"

nft add rule inet filter input ip saddr "${OFFICE_IP}" tcp dport 22 accept

###############################################################################
# Final status
###############################################################################

log "SSH ENABLED (TEMPORARY)"
echo
echo "You may now SSH using:"
echo "  ssh root@<server-ip>"
echo
echo "IMPORTANT:"
echo "When finished, DISABLE SSH using:"
echo "  systemctl stop ssh"
echo "  systemctl disable ssh"
echo "  systemctl mask ssh"
echo "  apt purge -y openssh-server openssh-sftp-server"
echo
echo "And remove the firewall rule:"
echo "  nft list ruleset | grep 22"
echo "  nft delete rule inet filter input handle <HANDLE>"
echo
log "Done"
