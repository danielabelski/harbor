#!/usr/bin/env bash
# Runtime proof for `harbor up anythingllm tei`: on a running stack, AnythingLLM
# embeds with TEI (generic-openai at http://tei:80/v1) and a real-sized
# document -- 3,000+ words, which AnythingLLM chunks into 50+ inputs sent in a
# single /v1/embeddings call -- is vectorized end to end: TEI's log gains
# openai_embed lines and no "batch size" 422, and the workspace lists the
# document. Requires anythingllm + tei up; creates a throwaway workspace and
# document and removes both afterwards. Works in single-user mode without a
# password (the default); set ANYTHINGLLM_TOKEN to a session JWT otherwise.
set -euo pipefail
cd "$(dirname "$0")/../.."
prefix=$(./harbor.sh config get container.prefix 2>/dev/null || echo harbor)
port=$(./harbor.sh config get anythingllm.host.port 2>/dev/null || echo 34171)
tei="$prefix.tei"; allm="$prefix.anythingllm"

# Stack guard: SKIP (exit 1) instead of failing noisily when the stack is down.
for c in "$tei" "$allm"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = true ] || { echo "SKIP: $c is not running"; exit 1; }
done
api="http://localhost:$port/api"
auth=(); [ -n "${ANYTHINGLLM_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $ANYTHINGLLM_TOKEN")

docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$allm" \
  | grep -q '^EMBEDDING_BASE_PATH=http://tei:80/v1$' \
  || { echo "anythingllm embedder is not TEI"; exit 1; }
curl -sf "$api/setup-complete" | grep -q '"EmbeddingEngine":"generic-openai"' \
  || { echo "anythingllm reports an embedding engine other than generic-openai"; exit 1; }

stamp=$(date +%s); slug="tei-probe-$stamp"
tmp=$(mktemp -t harbor-tei.XXXXXX.txt)
# 3,200 words of varied text so the collector yields dozens of chunks
for i in $(seq 1 400); do
  echo "Paragraph $i of the harbor tei probe $stamp describes embedding batch number $i in detail."
done > "$tmp"
cleanup() {
  rm -f "$tmp"
  # The workspace only lists the document when embedding succeeded; on a failed
  # embed the uploaded file still sits in system documents, so collect it by name too
  docs=$( { curl -s "${auth[@]}" "$api/workspace/$slug" | jq -r '.workspace.documents[]?.docpath' 2>/dev/null;
    curl -s "${auth[@]}" "$api/system/local-files" | jq -r --arg s "$slug" '.localFiles.items[]? | .name as $dir | .items[]? | select(.name | contains($s)) | "\($dir)/\(.name)"' 2>/dev/null; } | sort -u || true)
  curl -s "${auth[@]}" -X DELETE "$api/workspace/$slug" >/dev/null 2>&1 || true
  [ -n "$docs" ] && curl -s "${auth[@]}" -X DELETE "$api/system/remove-documents" \
    -H 'Content-Type: application/json' \
    -d "$(printf '%s\n' "$docs" | jq -R . | jq -sc '{names:.}')" >/dev/null 2>&1 || true
}
trap cleanup EXIT

curl -sf "${auth[@]}" -X POST "$api/workspace/new" -H 'Content-Type: application/json' \
  -d "{\"name\":\"$slug\"}" | jq -e '.workspace.slug' >/dev/null \
  || { echo "could not create workspace $slug"; exit 1; }

before=$(docker logs "$tei" 2>&1 | grep -c openai_embed || true)
errs_before=$(docker logs "$tei" 2>&1 | grep -c 'batch size' || true)
resp=$(curl -s "${auth[@]}" -X POST "$api/workspace/$slug/upload-and-embed" -F "file=@$tmp;filename=tei-probe-$stamp.txt")
echo "$resp" | jq -e '.success == true' >/dev/null \
  || { echo "upload failed: $(echo "$resp" | jq -r '.error // .message // .' | cut -c1-300)"; exit 1; }
curl -sf "${auth[@]}" "$api/workspace/$slug" | jq -e '.workspace.documents | length >= 1' >/dev/null \
  || { echo "workspace $slug lists no documents (AnythingLLM logged 'Failed to vectorize'?)"; exit 1; }

after=$(docker logs "$tei" 2>&1 | grep -c openai_embed || true)
errs_after=$(docker logs "$tei" 2>&1 | grep -c 'batch size' || true)
[ "$errs_after" -gt "$errs_before" ] && { echo "TEI rejected the request: $(docker logs "$tei" 2>&1 | grep 'batch size' | tail -1)"; exit 1; }
[ "$after" -gt "$before" ] || { echo "no openai_embed request reached TEI"; exit 1; }
cache=$(ls -t services/anythingllm/storage/vector-cache/*.json 2>/dev/null | head -1 || true)
chunks=$([ -n "$cache" ] && jq '.[0]|length' "$cache" 2>/dev/null || echo "?")
echo "TEI served $((after-before)) openai_embed request(s) for $chunks chunks; workspace $slug lists the document"
