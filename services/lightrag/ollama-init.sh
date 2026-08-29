#!/bin/sh
# Entrypoint wrapper for `harbor up lightrag ollama` (compose.x.lightrag.ollama.yml).
# Before the server starts: pull the base model, then derive two copies of it
# that carry num_ctx (Ollama's OpenAI-compatible /v1 endpoint, the only route
# that accepts reasoning_effort=none to switch Qwen3-style thinking off,
# ignores per-request num_ctx).
#
# Two copies because Ollama keeps one runner per distinct model+parameters and
# its ROCm runner lets the previous request bleed into the next long, weakly
# constrained prompt: a keyword/extraction JSON call followed by a query answer
# call on the same runner returns that JSON instead of an answer. Giving the
# query role its own copy means no JSON-mode request ever precedes an answer
# on the runner that produces it.
#
# This runs inside the lightrag container (not a sidecar) so that
# `harbor down lightrag` has no cross-file-only service to trip over.
set -eu
host=${OLLAMA_HOST:-http://ollama:11434}
base=${LIGHTRAG_OLLAMA_BASE_MODEL:?}
extract=${LIGHTRAG_OLLAMA_EXTRACT_MODEL:?}
query=${LIGHTRAG_OLLAMA_QUERY_MODEL:?}
extract_ctx=${LIGHTRAG_OLLAMA_EXTRACT_NUM_CTX:-16384}
query_ctx=${LIGHTRAG_OLLAMA_NUM_CTX:-32768}
query_gpu=${LIGHTRAG_OLLAMA_QUERY_NUM_GPU:--1}
embedding=${LIGHTRAG_OLLAMA_EMBEDDING_MODEL:-}

# The image ships no curl/wget; python is what the server itself runs on
post() {
  python3 - "${host}$1" "$2" <<'PY'
import json, sys, urllib.request
req = urllib.request.Request(sys.argv[1], data=sys.argv[2].encode(), headers={"Content-Type": "application/json"})
with urllib.request.urlopen(req, timeout=3600) as r:
    body = json.load(r)
if body.get("status") != "success":
    print(body, file=sys.stderr); sys.exit(1)
PY
}

# Derived copies from a previous HARBOR_LIGHTRAG_OLLAMA_MODEL / num_gpu setting
# would otherwise stay in every Ollama client's model list forever; the
# lightrag/ prefix is Harbor's, so anything under it that is not the current
# pair is removed. Never touches the base or embedding models.
prune() {
  python3 - "${host}" "${extract}" "${query}" <<'PY'
import json, sys, urllib.request
host, keep = sys.argv[1], set(sys.argv[2:])
with urllib.request.urlopen(host + "/api/tags", timeout=60) as r:
    names = [m["name"] for m in json.load(r).get("models", [])]
for name in names:
    if name.startswith("lightrag/") and name not in keep and name.removesuffix(":latest") not in keep:
        print(f"Harbor: lightrag ollama init - removing stale {name}")
        req = urllib.request.Request(host + "/api/delete", data=json.dumps({"model": name}).encode(),
                                     headers={"Content-Type": "application/json"}, method="DELETE")
        urllib.request.urlopen(req, timeout=60).read()
PY
}

# $3: extra parameters JSON (e.g. num_gpu for the query copy); num_gpu below 0
# is left to Ollama's default so the copy stays on the GPU
create() {
  echo "Harbor: lightrag ollama init - creating $1 (num_ctx=$2${3:+, $3})"
  post /api/create "{\"model\":\"$1\",\"from\":\"${base}\",\"parameters\":{\"num_ctx\":$2${3:+,$3}},\"stream\":false}"
}

echo "Harbor: lightrag ollama init - pulling ${base}"
post /api/pull "{\"model\":\"${base}\",\"stream\":false}"
if [ -n "${embedding}" ]; then
  echo "Harbor: lightrag ollama init - pulling ${embedding}"
  post /api/pull "{\"model\":\"${embedding}\",\"stream\":false}"
fi
prune
create "${extract}" "${extract_ctx}"
if [ "${query_gpu}" -ge 0 ]; then
  create "${query}" "${query_ctx}" "\"num_gpu\":${query_gpu}"
else
  create "${query}" "${query_ctx}"
fi
echo "Harbor: lightrag ollama init - done, starting LightRAG"
exec /usr/local/bin/docker-entrypoint.sh python -m lightrag.api.lightrag_server
