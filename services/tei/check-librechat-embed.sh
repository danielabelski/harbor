#!/usr/bin/env bash
# Runtime proof for `harbor up librechat tei`: on a running stack, librechat-rag
# is up with TEI as its openai-compatible embedder, and ingesting a file through
# the RAG API's /embed route (the same path LibreChat's UI upload takes)
# produces an openai_embed request in TEI's log. Requires librechat + tei up;
# mints a JWT from LibreChat's JWT_SECRET, then deletes the probe document.
set -euo pipefail
cd "$(dirname "$0")/../.."
prefix=$(./harbor.sh config get container.prefix 2>/dev/null || echo harbor)
rag_port=$(./harbor.sh config get librechat.rag.host.port 2>/dev/null || echo 33892)
lc="$prefix.librechat"; rag="$prefix.librechat-rag"; tei="$prefix.tei"

docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$rag" \
  | grep -q '^RAG_OPENAI_BASEURL=http://tei:80/v1$' \
  || { echo "librechat-rag embedder is not TEI"; exit 1; }
[ "$(docker inspect -f '{{.State.Running}}' "$rag")" = "true" ] \
  || { echo "librechat-rag is not running"; exit 1; }

token=$(docker exec "$lc" node -e "
const jwt=require('jsonwebtoken');
console.log(jwt.sign({id:'000000000000000000000000'},process.env.JWT_SECRET,{expiresIn:'2m'}))")

before=$(docker logs "$tei" 2>&1 | grep -c openai_embed || true)
file_id="harbor-tei-probe-$(date +%s)"
docker exec -i -e TOKEN="$token" -e FILE_ID="$file_id" -e PORT="$rag_port" "$rag" python3 - <<'PY'
import json, os, urllib.request
b = "----harbor-tei"; fid = os.environ["FILE_ID"]; port = os.environ["PORT"]
hdr = {"Authorization": "Bearer " + os.environ["TOKEN"]}
body = ("--%s\r\nContent-Disposition: form-data; name=\"file_id\"\r\n\r\n%s\r\n"
        "--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"tei-probe.txt\"\r\n"
        "Content-Type: text/plain\r\n\r\nharbor tei probe %s\r\n--%s--\r\n" % (b, fid, b, fid, b)).encode()
r = urllib.request.Request("http://localhost:%s/embed" % port, data=body,
    headers={**hdr, "Content-Type": "multipart/form-data; boundary=" + b})
res = json.load(urllib.request.urlopen(r))
assert res.get("status"), res
d = urllib.request.Request("http://localhost:%s/documents" % port, data=json.dumps([fid]).encode(),
    headers={**hdr, "Content-Type": "application/json"}, method="DELETE")
urllib.request.urlopen(d)
PY

for _ in $(seq 1 30); do
  after=$(docker logs "$tei" 2>&1 | grep -c openai_embed || true)
  [ "$after" -gt "$before" ] && { echo "TEI served $((after-before)) openai_embed request(s) for the LibreChat upload"; exit 0; }
  sleep 1
done
echo "no openai_embed request reached TEI"; exit 1
