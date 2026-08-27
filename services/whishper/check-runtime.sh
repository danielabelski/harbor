#!/bin/sh
# End-user workflow check against a running whishper stack. Exits 1 with a
# SKIP message when the stack is not up so fact checks stay honest offline.
# Usage: check-runtime.sh transcribe|ownership|translate
set -u
mode="${1:?mode}"
cd "$(dirname "$0")/../.." || exit 1
prefix=$(./harbor.sh config get container_prefix 2>/dev/null); prefix=${prefix:-harbor}
port=$(./harbor.sh config get whishper.host_port 2>/dev/null); port=${port:-35060}
ws=$(./harbor.sh config get whishper.workspace 2>/dev/null); ws=${ws:-./services/whishper/data}
c="$prefix.whishper"
[ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)" = healthy ] || { echo "SKIP: $c is not running/healthy"; exit 1; }
command -v espeak-ng >/dev/null || { echo "SKIP: espeak-ng not installed"; exit 1; }
api="http://localhost:$port/api"
T=$(mktemp -d -t harbor.XXXXXX); id=""
cleanup() { [ -n "$id" ] && curl -sf -X DELETE "$api/transcriptions/$id" >/dev/null; rm -rf "$T"; }
trap cleanup EXIT

espeak-ng -s 130 -w "$T/in.wav" "Hello world. One two three four five." 2>/dev/null || { echo "espeak-ng failed"; exit 1; }
id=$(curl -sf -F file=@"$T/in.wav" -F language=en -F modelSize=base -F device=cpu "$api/transcriptions" | jq -r '.id // .ID // empty')
[ -n "$id" ] || { echo "POST /api/transcriptions returned no id"; exit 1; }
i=0; status=""
while [ $i -lt 60 ]; do
  status=$(curl -sf "$api/transcriptions/$id" | jq -r '.status'); [ "$status" = 2 ] && break
  [ "$status" = "-1" ] && { echo "transcription failed (status -1)"; exit 1; }
  i=$((i+1)); sleep 2
done
[ "$status" = 2 ] || { echo "status $status after 120s"; exit 1; }
text=$(curl -sf "$api/transcriptions/$id" | jq -r '.result.text' | tr 'A-Z' 'a-z')

case "$mode" in
  transcribe) echo "$text" | grep -q "hello" && echo "$text" | grep -q "two" && echo "$text" | grep -q "three" ;;
  ownership)
    f=$(find "$ws/uploads" -name '*.wav' -newer "$T/in.wav" | head -1); [ -n "$f" ] || f=$(ls -t "$ws/uploads"/*.wav | head -1)
    [ -O "$f" ] || { echo "$f not owned by $(id -u)"; exit 1; }
    uids=$(docker exec "$c" sh -c 'for p in /proc/[0-9]*; do printf "%s %s\n" "$(awk "/^Uid:/{print \$2}" $p/status)" "$(tr "\0" " " < $p/cmdline | cut -c1-40)"; done')
    echo "$uids" | grep -E '^[0-9]+ /bin/whishper' | grep -qv '^0 ' && echo "$uids" | grep -E '^[0-9]+ node' | grep -qv '^0 ' && echo "$uids" | grep -E '^[0-9]+ python3 /app/transcription' | grep -qv '^0 ' && echo "$uids" | grep -q '^0 nginx: master' && echo "$uids" | grep -Eq '^0 .*supervisord' ;;
  translate)
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$prefix.libretranslate" 2>/dev/null)" = healthy ] || { echo "SKIP: $prefix.libretranslate is not healthy"; exit 1; }
    curl -sf "$api/translate/$id/es" >/dev/null && curl -sf "$api/transcriptions/$id" | jq -e '.translations | length > 0' >/dev/null ;;
  *) echo "unknown mode $mode"; exit 2 ;;
esac
