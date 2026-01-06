#!/usr/bin/env bash
set -Eeuo pipefail

to=""
subject=""
body=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to) to="$2"; shift 2;;
    --subject) subject="$2"; shift 2;;
    --body) body="$2"; shift 2;;
    *) shift;;
  esac
done

[[ -n "${to}" && -n "${subject}" ]] || exit 0

{
  echo "To: ${to}"
  echo "Subject: ${subject}"
  echo "Date: $(date -R)"
  echo
  printf "%b\n" "${body}"
} | /usr/sbin/sendmail -t
