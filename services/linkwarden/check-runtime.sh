#!/bin/sh
# End-user workflow check against a running linkwarden stack. Exits 1 with a
# SKIP message when the stack is not up so fact checks stay honest offline.
# Registers (or reuses) a harbor-check user, logs in through NextAuth, and
# depending on the mode: proves the session, archives a link, or enables
# Auto-generate Tags and waits for AI tags from the configured backend.
# Usage: check-runtime.sh login|link|tags
set -u
mode="${1:?mode}"
cd "$(dirname "$0")/../.." || exit 1
prefix=$(./harbor.sh config get container_prefix 2>/dev/null); prefix=${prefix:-harbor}
port=$(./harbor.sh config get linkwarden.host_port 2>/dev/null); port=${port:-35070}
c="$prefix.linkwarden"
[ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)" = healthy ] || { echo "SKIP: $c is not running/healthy"; exit 1; }
base="http://localhost:$port"; api="$base/api/v1"
user=harbor-check; pass=harbor-check-password
T=$(mktemp -d -t harbor.XXXXXX); jar="$T/jar"; link=""
cleanup() { [ -n "$link" ] && curl -sf -b "$jar" -X DELETE "$api/links/$link" >/dev/null; rm -rf "$T"; }
trap cleanup EXIT

# Registration is idempotent for the check: 400 "taken" on a second run is fine
curl -s -o /dev/null -H 'Content-Type: application/json' \
  -d "{\"name\":\"Harbor Check\",\"username\":\"$user\",\"password\":\"$pass\"}" "$api/users"
csrf=$(curl -sf -c "$jar" "$api/auth/csrf" | jq -r .csrfToken)
[ -n "$csrf" ] || { echo "no csrf token from $api/auth/csrf"; exit 1; }
curl -s -o /dev/null -b "$jar" -c "$jar" --data-urlencode "csrfToken=$csrf" \
  --data-urlencode "username=$user" --data-urlencode "password=$pass" --data-urlencode "json=true" \
  "$api/auth/callback/credentials"
uid=$(curl -sf -b "$jar" "$api/auth/session" | jq -r '.user.id // empty')
[ -n "$uid" ] || { echo "login as $user failed (no session)"; exit 1; }
[ "$mode" = login ] && exit 0

if [ "$mode" = tags ]; then
  backend=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" | grep -E '^(NEXT_PUBLIC_OLLAMA_ENDPOINT_URL|CUSTOM_OPENAI_BASE_URL)=' | head -1)
  [ -n "$backend" ] || { echo "SKIP: $c has no AI backend env (start with ollama/llamacpp/vllm/mlx)"; exit 1; }
  name=$(curl -sf -b "$jar" "$api/users/$uid" | jq -r .response.name)
  curl -sf -b "$jar" -X PUT -H 'Content-Type: application/json' \
    -d "{\"name\":\"$name\",\"username\":\"$user\",\"aiTaggingMethod\":\"GENERATE\",\"aiTagExistingLinks\":false}" \
    "$api/users/$uid" | jq -e '.response.aiTaggingMethod=="GENERATE"' >/dev/null || { echo "could not enable GENERATE tagging"; exit 1; }
fi

link=$(curl -sf -b "$jar" -H 'Content-Type: application/json' \
  -d '{"url":"https://docs.docker.com/compose/","name":"","description":"","tags":[],"collection":{"name":"Unorganized"}}' \
  "$api/links" | jq -r '.response.id // empty')
[ -n "$link" ] || { echo "POST $api/links returned no id"; exit 1; }

i=0; j="{}"
while [ $i -lt 90 ]; do
  j=$(curl -sf -b "$jar" "$api/links/$link" | jq -c '.response | {preserved:(.lastPreserved!=null), aiTagged, tags:[.tags[].name]}')
  case "$mode" in
    link) echo "$j" | jq -e '.preserved' >/dev/null && exit 0 ;;
    tags) echo "$j" | jq -e '.aiTagged and (.tags|length>0)' >/dev/null && { echo "$j"; exit 0; }
          echo "$j" | jq -e '.aiTagged and (.tags|length==0)' >/dev/null && { echo "worker marked the link aiTagged without tags: $j"; exit 1; } ;;
    *) echo "unknown mode $mode"; exit 2 ;;
  esac
  i=$((i+1)); sleep 2
done
echo "$mode not reached after 180s: $j"; exit 1
