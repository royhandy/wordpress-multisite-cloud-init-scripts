#!/usr/bin/env bash
set -Eeuo pipefail

if [[ -f /etc/server.env ]]; then
  # shellcheck disable=SC1091
  source /etc/server.env
else
  cat >/dev/null
  exit 0
fi

: "${MAILGUN_SMTP_LOGIN:=}"
: "${MAILGUN_SMTP_PASSWORD:=}"
: "${MAILGUN_SMTP_HOST:=}"
: "${MAILGUN_SMTP_PORT:=}"
: "${MAIL_FROM:=}"

# Drop mail silently if not configured
if [[ -z "${MAILGUN_SMTP_LOGIN}" || -z "${MAILGUN_SMTP_PASSWORD}" || -z "${MAILGUN_SMTP_HOST}" || -z "${MAILGUN_SMTP_PORT}" || -z "${MAIL_FROM}" ]]; then
  cat >/dev/null
  exit 0
fi

exec /usr/bin/msmtp \
  --host="${MAILGUN_SMTP_HOST}" \
  --port="${MAILGUN_SMTP_PORT}" \
  --auth=on \
  --tls=on \
  --user="${MAILGUN_SMTP_LOGIN}" \
  --passwordeval="printf %s '${MAILGUN_SMTP_PASSWORD}'" \
  --from="${MAIL_FROM}" \
  "$@"
