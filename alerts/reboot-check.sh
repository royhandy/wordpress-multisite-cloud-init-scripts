#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /etc/server.env

if [[ -f /var/run/reboot-required ]]; then
  /usr/local/sbin/send-email \
    --to "${ALERT_EMAIL}" \
    --subject "[server] Reboot required on $(hostname -f)" \
    --body "$(cat /var/run/reboot-required)"
fi
