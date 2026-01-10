#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f /etc/server.env ]]; then
  # shellcheck disable=SC1091
  source /etc/server.env
else
  exit 0
fi

: "${ALERT_EMAIL:=}"

if [[ -z "${ALERT_EMAIL}" ]]; then
  exit 0
fi

if [[ -f /var/run/reboot-required ]]; then
  /usr/local/sbin/send-email \
    --to "${ALERT_EMAIL}" \
    --subject "[server] Reboot required on $(hostname -f)" \
    --body "$(cat /var/run/reboot-required)"
fi
