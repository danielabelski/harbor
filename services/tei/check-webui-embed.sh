#!/usr/bin/env bash
# Runtime proof for `harbor up webui tei`: on a running stack, the persisted
# Open WebUI embedder is TEI and uploading a file produces an openai_embed
# request in TEI's log. Requires webui + tei up; mints an admin JWT from the
# container's WEBUI_SECRET_KEY; the uploaded probe file is deleted on exit so no
# user state is left behind.
set -euo pipefail
cd "$(dirname "$0")/../.."
prefix=$(./harbor.sh config get container.prefix 2>/dev/null || echo harbor)
port=$(./harbor.sh config get webui.host.port 2>/dev/null || echo 33801)
webui="$prefix.webui"; tei="$prefix.tei"

token=$(docker exec "$webui" python -W ignore -c "
import jwt,os,sqlite3
uid=sqlite3.connect('/app/backend/data/webui.db').execute(\"select id from user where role='admin' limit 1\").fetchone()[0]
print(jwt.encode({'id':uid},os.environ['WEBUI_SECRET_KEY'],algorithm='HS256'))")

curl -sf -H "Authorization: Bearer $token" "http://localhost:$port/api/v1/retrieval/embedding" \
  | grep -q '"RAG_EMBEDDING_ENGINE":"openai".*"url":"http://tei:80/v1"' \
  || { echo "effective embedder is not TEI"; exit 1; }

before=$(docker logs "$tei" 2>&1 | grep -c openai_embed || true)
tmp=$(mktemp -t harbor-tei.XXXXXX); echo "harbor tei probe $(date +%s)" > "$tmp"
file_id=""
cleanup() {
  rm -f "$tmp"
  [ -n "$file_id" ] && curl -s -H "Authorization: Bearer $token" -X DELETE "http://localhost:$port/api/v1/files/$file_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT
file_id=$(curl -sf -H "Authorization: Bearer $token" -F "file=@$tmp;filename=tei-probe.txt" "http://localhost:$port/api/v1/files/" | jq -r '.id // empty')
[ -n "$file_id" ] || { echo "upload returned no file id"; exit 1; }
for _ in $(seq 1 30); do
  after=$(docker logs "$tei" 2>&1 | grep -c openai_embed || true)
  [ "$after" -gt "$before" ] && { echo "TEI served $((after-before)) openai_embed request(s) for the upload"; exit 0; }
  sleep 1
done
echo "no openai_embed request reached TEI"; exit 1
