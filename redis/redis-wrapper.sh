#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/server.env"

# Ensure env file exists
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "[redis-wrapper] ERROR: ${ENV_FILE} not found"
  exit 1
fi

# shellcheck disable=SC1091
source "${ENV_FILE}"

if [[ -z "${REDIS_PASSWORD:-}" ]]; then
  echo "[redis-wrapper] ERROR: REDIS_PASSWORD not set in ${ENV_FILE}"
  exit 1
fi

exec /usr/bin/redis-server /etc/redis/redis.conf \
  --requirepass "${REDIS_PASSWORD}"
