#!/bin/sh
# paperless-gpt only authenticates with an API token, which paperless-ngx
# cannot pre-seed from env. Exchange the Harbor admin credentials for a token
# via /api/token/ unless the user provided one explicitly.
set -e

if [ -z "$PAPERLESS_API_TOKEN" ]; then
  echo "[harbor] fetching paperless API token for user '$HARBOR_PAPERLESS_ADMIN_USER'"
  i=0
  while [ $i -lt 60 ]; do
    resp=$(wget -q -O - --post-data "username=$HARBOR_PAPERLESS_ADMIN_USER&password=$HARBOR_PAPERLESS_ADMIN_PASSWORD" \
      "$PAPERLESS_BASE_URL/api/token/" 2>/dev/null || true)
    token=$(printf '%s' "$resp" | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
    if [ -n "$token" ]; then
      export PAPERLESS_API_TOKEN="$token"
      echo "[harbor] token acquired"
      break
    fi
    i=$((i + 1))
    sleep 2
  done
  if [ -z "$PAPERLESS_API_TOKEN" ]; then
    echo "[harbor] could not obtain a paperless API token from $PAPERLESS_BASE_URL" >&2
    exit 1
  fi
fi

unset HARBOR_PAPERLESS_ADMIN_PASSWORD
exec /app/entrypoint.sh "$@"
