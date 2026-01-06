#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /etc/server.env

usage="$(df -P / | awk 'NR==2{gsub("%","",$5);print $5}')"

if (( usage >= DISK_CRIT_PCT )); then
  level="CRITICAL"
elif (( usage >= DISK_WARN_PCT )); then
  level="WARNING"
else
  exit 0
fi

/usr/local/sbin/send-email \
  --to "${ALERT_EMAIL}" \
  --subject "[server] Disk ${level} on $(hostname -f)" \
  --body "Disk usage is ${usage}% on /"
