#!/bin/sh
# tei runs as the host user (HARBOR_USER_ID) so models it pulls into the shared
# HF hub cache stay host-owned. Earlier root-run TEI containers (and vllm/tgi,
# which still run as root) leave root-owned models--* dirs behind that a
# non-root tei cannot lock or refresh; fix only those, leave everything else
# in the cache untouched. Mirrors the langflow/cognee init-sidecar pattern.
set -e
mkdir -p /data
for d in /data /data/models--* /data/.locks; do
  [ -e "$d" ] || continue
  find "$d" ! -user "${TARGET_UID:-1000}" -exec chown -h "${TARGET_UID:-1000}:${TARGET_GID:-1000}" {} + 2>/dev/null || true
done
