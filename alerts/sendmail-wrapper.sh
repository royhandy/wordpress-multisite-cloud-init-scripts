#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck disable=SC1091
source /etc/server.env

# Drop mail silently if not configured
if [[ -z "${MAILGUN_SMTP_LOGIN}" || -z "${MAILGUN_SMTP_PASSWORD}" ]]; then
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
