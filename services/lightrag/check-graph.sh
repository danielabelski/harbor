#!/usr/bin/env bash
# Runtime check: with lightrag up (any backend), ingesting a short document
# yields a non-empty knowledge graph and a grounded hybrid-mode answer.
# Usage: ./services/lightrag/check-graph.sh [--ingest-only] [host_port] [api_key]
# --ingest-only stops after the graph check (ingest must finish within 5 minutes)
set -euo pipefail

ingest_only=false
[ "${1:-}" = "--ingest-only" ] && { ingest_only=true; shift; }
port=${1:-$(./harbor.sh config get lightrag.host_port)}
key=${2:-$(./harbor.sh config get lightrag.api_key)}
base="http://localhost:${port}"
auth=(-H "X-API-Key: ${key}" -H "Content-Type: application/json")
tag=$(date +%s)

curl -sf "${auth[@]}" -X POST "${base}/documents/text" -d @- <<JSON >/dev/null
{"file_source":"harbor-check-${tag}.txt","text":"Check ${tag}. The Quorvax Lantern is a brass navigation lamp designed by Marisol Venn in 1887 in the port city of Ostrahaven. Venn founded the Ostrahaven Optical Works, which manufactured the lantern for the Harlan Shipping Company. Harlan Shipping Company was owned by Augustus Harlan. Captain Edric Tolle of the steamship Meridian Star was the first to use a Quorvax Lantern on a transatlantic crossing."}
JSON

limit=120
$ingest_only && limit=60
for _ in $(seq 1 "${limit}"); do
  sleep 5
  [ "$(curl -sf "${auth[@]}" "${base}/documents/pipeline_status" | jq -r .busy)" = "false" ] && break
done
[ "$(curl -sf "${auth[@]}" "${base}/documents/pipeline_status" | jq -r .busy)" = "false" ] || { echo "FAIL: ingest still busy"; exit 1; }

nodes=$(curl -sf "${auth[@]}" "${base}/graphs?label=*&max_depth=3&max_nodes=200" | jq '.nodes | length')
echo "graph nodes: ${nodes}"
[ "${nodes}" -gt 0 ] || { echo "FAIL: knowledge graph is empty"; exit 1; }
$ingest_only && { echo "OK (ingest only)"; exit 0; }

# The tag keeps the query text unique so LightRAG's LLM query cache never serves a stale answer
answer=$(curl -sf "${auth[@]}" -X POST "${base}/query" \
  -d "{\"query\":\"Who owned the Harlan Shipping Company? (check ${tag})\",\"mode\":\"hybrid\"}" | jq -r .response)
echo "hybrid answer: ${answer:0:200}"
grep -q "Augustus Harlan" <<<"${answer}" || { echo "FAIL: hybrid answer is not grounded"; exit 1; }
grep -q "no-context" <<<"${answer}" && { echo "FAIL: hybrid answered [no-context]"; exit 1; }
# A JSON body here means the LLM echoed the keyword/entity-extraction payload as the answer
trimmed="${answer#"${answer%%[![:space:]]*}"}"
[[ "${trimmed}" == \{* || "${trimmed}" == '```json'* ]] && { echo "FAIL: hybrid answer is extraction JSON, not prose"; exit 1; }
echo "OK"
