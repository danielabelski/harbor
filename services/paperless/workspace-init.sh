#!/bin/sh
# Pre-create paperless' app directories host-owned before the main container
# starts. Only the app dirs are touched: /workspace/valkey belongs to the valkey
# sidecar and must keep its own ownership.
set -e
chown "${TARGET_UID:-1000}:${TARGET_GID:-1000}" /workspace
for d in data media consume export; do
  mkdir -p "/workspace/$d"
  chown -R "${TARGET_UID:-1000}:${TARGET_GID:-1000}" "/workspace/$d"
done
