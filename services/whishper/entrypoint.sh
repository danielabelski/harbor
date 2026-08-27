#!/bin/sh
set -e

# The Go backend, nginx and the transcription worker all use /app/uploads and
# /app/models (partly hardcoded). Point those at the single host-owned
# workspace mount instead of bind-mounting each subdirectory, which Docker
# would create root-owned after whishper-init already ran.
for d in uploads models; do
  mkdir -p "/workspace/$d"
  if [ ! -L "/app/$d" ]; then
    rm -rf "/app/$d"
    ln -s "/workspace/$d" "/app/$d"
  fi
done

# The image's nginx hardcodes proxy_pass http://translate:5000 and refuses to
# start when that host does not resolve, which breaks whishper without
# libretranslate. Point it at TRANSLATION_ENDPOINT (set by the libretranslate
# cross-file) or a local loopback so nginx starts and /languages just 502s.
upstream="${TRANSLATION_ENDPOINT:-127.0.0.1:5000}"
sed "s#proxy_pass http://translate:5000;#proxy_pass http://${upstream};#" /etc/nginx/nginx.conf > /tmp/nginx.conf
mv /tmp/nginx.conf /etc/nginx/nginx.conf

# nginx must stay root to bind :80, but every file whishper writes (uploads,
# whisper models, worker temp files) comes from the backend and the worker.
# Run those as the host user so runtime writes stay host-owned without
# waiting for whishper-init's chown on the next start.
uid="${HARBOR_USER_ID:-1000}"
gid="${HARBOR_GROUP_ID:-1000}"
getent group "$gid" >/dev/null || echo "harbor:x:${gid}:" >> /etc/group
getent passwd "$uid" >/dev/null || echo "harbor:x:${uid}:${gid}::/workspace:/bin/sh" >> /etc/passwd
# The worker converts uploads in its cwd before transcribing
chown "$uid:$gid" /app/transcription
export HOME=/workspace
sed "s#^\(\[program:\(transcription\|backend\|frontend\)\]\)#\1\nuser=${uid}#" \
  /etc/supervisor/conf.d/supervisord.conf > /tmp/supervisord.conf
exec supervisord -c /tmp/supervisord.conf
