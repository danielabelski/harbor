#!/bin/sh
# tei runs as the host user (HARBOR_USER_ID) so models it pulls into the shared
# HF hub cache stay host-owned. Earlier root-run TEI containers (and vllm/tgi,
# which still run as root) leave root-owned models--* dirs behind that a
# non-root tei cannot lock or refresh; fix only those. The hub root itself is
# re-owned non-recursively (so tei can create new models--* dirs), models--*
# and .locks recursively. datasets--*, spaces--* and any other tool's dirs in
# the shared cache are never touched. Mirrors the langflow/cognee init-sidecar.
set -e
uid="${TARGET_UID:-1000}"; gid="${TARGET_GID:-1000}"; root="${CACHE_ROOT:-/data}"
mkdir -p "$root"
find "$root" -maxdepth 0 ! -user "$uid" -exec chown -h "$uid:$gid" {} + 2>/dev/null || true
for d in "$root"/models--* "$root"/.locks; do
  [ -e "$d" ] || continue
  find "$d" ! -user "$uid" -exec chown -h "$uid:$gid" {} + 2>/dev/null || true
done
