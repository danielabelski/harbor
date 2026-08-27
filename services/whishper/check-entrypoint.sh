#!/bin/sh
# Executes entrypoint.sh / workspace-init.sh under stubs (no root, no container)
# and asserts one behavioural claim. Paths under /etc, /app and /workspace are
# redirected into a temp root by the stubs; chown/ln/rm/mkdir/supervisord are
# logged instead of executed. Usage: check-entrypoint.sh <mode>
set -u
mode="${1:?mode}"
cd "$(dirname "$0")/../.." || exit 1
T=$(mktemp -d -t harbor.XXXXXX)
trap 'rm -rf "$T"' EXIT
uid=4242; gid=4343

mkdir -p "$T/bin" "$T/etc/nginx" "$T/etc/supervisor/conf.d" "$T/workspace"
cat > "$T/etc/nginx/nginx.conf" <<'NGX'
server {
        listen 80;
        location /languages {
            proxy_pass http://translate:5000;
        }
        location /api/ {
            proxy_pass http://127.0.0.1:8080;
        }
}
NGX
for p in transcription frontend backend nginx; do
  printf '[program:%s]\ncommand=%s\nautorestart=true\nstderr_logfile=/var/log/whishper/%s.err.log\nstdout_logfile=/var/log/whishper/%s.out.log\n\n' "$p" "$p" "$p" "$p"
done > "$T/etc/supervisor/conf.d/supervisord.conf"

# Real tools with /etc,/app,/workspace arguments redirected into $T
for t in sed mv; do
  real=$(command -v "$t")
  cat > "$T/bin/$t" <<STUB
#!/bin/sh
for a in "\$@"; do case "\$a" in /etc/*|/app/*|/workspace/*) set -- "\$@" "$T\$a";; *) set -- "\$@" "\$a";; esac; shift; done
exec "$real" "\$@"
STUB
done
# Logged-only tools
for t in chown ln rm mkdir supervisord; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/log"\n' "$t" "$T" > "$T/bin/$t"
done
printf '#!/bin/sh\necho "%s $*" >> "%s/log"\ncp "$2" "%s/supervisord.final"\n' supervisord "$T" "$T" > "$T/bin/supervisord"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/getent"
chmod +x "$T"/bin/*

run() { PATH="$T/bin:$PATH" HARBOR_USER_ID=$uid HARBOR_GROUP_ID=$gid "$@" sh services/whishper/entrypoint.sh >"$T/out" 2>&1; }
logged() { grep -qx "$1" "$T/log"; }
section() { awk -v s="[program:$1]" '$0==s{f=1;next} /^\[/{f=0} f' "$T/supervisord.final"; }

sh -n services/whishper/entrypoint.sh && sh -n services/whishper/workspace-init.sh || { echo "syntax error"; exit 1; }

case "$mode" in
  nginx-default)
    run env -u TRANSLATION_ENDPOINT || { cat "$T/out"; exit 1; }
    grep -q 'proxy_pass http://127.0.0.1:5000;' "$T/etc/nginx/nginx.conf" && ! grep -q 'translate:5000' "$T/etc/nginx/nginx.conf" && grep -q 'proxy_pass http://127.0.0.1:8080;' "$T/etc/nginx/nginx.conf" ;;
  nginx-endpoint)
    run env TRANSLATION_ENDPOINT=libretranslate:5000 || { cat "$T/out"; exit 1; }
    grep -q 'proxy_pass http://libretranslate:5000;' "$T/etc/nginx/nginx.conf" && ! grep -v libretranslate "$T/etc/nginx/nginx.conf" | grep -q 'translate:5000;' ;;
  symlinks)
    run env || { cat "$T/out"; exit 1; }
    for d in uploads models; do logged "mkdir -p /workspace/$d" && logged "rm -rf /app/$d" && logged "ln -s /workspace/$d /app/$d" || exit 1; done
    [ "$(grep -c '^ln ' "$T/log")" = 2 ] ;;
  chown)
    run env || { cat "$T/out"; exit 1; }
    logged "chown $uid:$gid /workspace" && logged "chown $uid:$gid /workspace/uploads" && logged "chown $uid:$gid /workspace/models" && logged "chown $uid:$gid /app/transcription" && [ "$(grep -c '^chown' "$T/log")" = 4 ] ;;
  supervisord)
    run env || { cat "$T/out"; exit 1; }
    logged "supervisord -c /tmp/supervisord.conf" && test -f "$T/supervisord.final" || exit 1
    for p in transcription backend frontend; do section "$p" | grep -qx "user=$uid" || { echo "no user=$uid for $p"; exit 1; }; done
    ! section nginx | grep -q '^user=' || exit 1
    for p in transcription backend; do section "$p" | grep -qx 'stderr_logfile=/dev/stderr' && section "$p" | grep -qx 'stderr_logfile_maxbytes=0' && ! section "$p" | grep -q "$p.err.log" || { echo "stderr not mirrored for $p"; exit 1; }; done
    section frontend | grep -qx 'stderr_logfile=/var/log/whishper/frontend.err.log' && section nginx | grep -qx 'stderr_logfile=/var/log/whishper/nginx.err.log' ;;
  passwd)
    grep -q 'getent passwd "$uid" >/dev/null || echo "harbor:x:${uid}:${gid}::/workspace:/bin/sh" >> /etc/passwd' services/whishper/entrypoint.sh && grep -q 'getent group "$gid" >/dev/null || echo "harbor:x:${gid}:" >> /etc/group' services/whishper/entrypoint.sh && grep -q '^export HOME=/workspace$' services/whishper/entrypoint.sh ;;
  init)
    PATH="$T/bin:$PATH" TARGET_UID=$uid TARGET_GID=$gid sh services/whishper/workspace-init.sh || exit 1
    logged "chown $uid:$gid /workspace" || exit 1
    for d in uploads models logs; do logged "mkdir -p /workspace/$d" && logged "chown -R $uid:$gid /workspace/$d" || exit 1; done
    ! grep -q db "$T/log" && [ "$(grep -c '^chown' "$T/log")" = 4 ] ;;
  *) echo "unknown mode $mode"; exit 2 ;;
esac
