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
exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
