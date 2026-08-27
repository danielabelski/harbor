#!/bin/sh
# Prepare the Ollama models LightRAG uses on the ollama cross-file: pull the base
# model, then derive two copies of it that carry num_ctx (Ollama's OpenAI-
# compatible /v1 endpoint, the only route that accepts reasoning_effort=none to
# switch Qwen3-style thinking off, ignores per-request num_ctx).
#
# Two copies because Ollama keeps one runner per distinct model+parameters and
# its ROCm runner lets the previous request bleed into the next long, weakly
# constrained prompt: a keyword/extraction JSON call followed by a query answer
# call on the same runner returns that JSON instead of an answer. Giving the
# query role its own copy means no JSON-mode request ever precedes an answer
# on the runner that produces it.
set -eu
host=${OLLAMA_HOST:-http://ollama:11434}
base=${LIGHTRAG_OLLAMA_BASE_MODEL:?}
extract=${LIGHTRAG_OLLAMA_EXTRACT_MODEL:?}
query=${LIGHTRAG_OLLAMA_QUERY_MODEL:?}
extract_ctx=${LIGHTRAG_OLLAMA_EXTRACT_NUM_CTX:-16384}
query_ctx=${LIGHTRAG_OLLAMA_NUM_CTX:-32768}

post() {
  wget -qO- --header 'Content-Type: application/json' --post-data "$2" "${host}$1"
}

create() {
  echo "Harbor: lightrag ollama init - creating $1 (num_ctx=$2)"
  post /api/create "{\"model\":\"$1\",\"from\":\"${base}\",\"parameters\":{\"num_ctx\":$2},\"stream\":false}" | grep -q '"success"'
}

echo "Harbor: lightrag ollama init - pulling ${base}"
post /api/pull "{\"model\":\"${base}\",\"stream\":false}" | grep -q '"success"'
create "${extract}" "${extract_ctx}"
create "${query}" "${query_ctx}"
