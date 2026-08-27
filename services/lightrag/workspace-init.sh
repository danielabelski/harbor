#!/bin/sh
# Chown the workspace bind mount to the host user before the main container
# starts. Docker creates missing bind-mount targets as root:root; chowning here
# keeps everything under services/lightrag/data manageable without sudo.
set -e
chown -R "${TARGET_UID:-1000}:${TARGET_GID:-1000}" /workspace

mkdir -p /workspace/inputs /workspace/prompts
