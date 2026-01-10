#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f /etc/server.env ]]; then
  # shellcheck disable=SC1091
  source /etc/server.env
else
  exit 0
fi

: "${ALERT_EMAIL:=}"
: "${DISK_WARN_PCT:=}"
: "${DISK_CRIT_PCT:=}"

if [[ -z "${ALERT_EMAIL}" || -z "${DISK_WARN_PCT}" || -z "${DISK_CRIT_PCT}" ]]; then
  exit 0
fi

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
