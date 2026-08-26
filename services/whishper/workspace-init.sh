#!/bin/sh
# Pre-create whishper's upload/model directories host-owned. /workspace/db
# belongs to the mongo sidecar and must keep its own ownership.
set -e
chown "${TARGET_UID:-1000}:${TARGET_GID:-1000}" /workspace
for d in uploads models logs; do
  mkdir -p "/workspace/$d"
  chown -R "${TARGET_UID:-1000}:${TARGET_GID:-1000}" "/workspace/$d"
done
