#!/usr/bin/env bash
# Runtime check: with lightrag up (any backend), ingesting a short document
# yields a non-empty knowledge graph and a grounded hybrid-mode answer.
# Usage: ./services/lightrag/check-graph.sh [host_port] [api_key]
set -euo pipefail

port=${1:-$(./harbor.sh config get lightrag.host_port)}
key=${2:-$(./harbor.sh config get lightrag.api_key)}
base="http://localhost:${port}"
auth=(-H "X-API-Key: ${key}" -H "Content-Type: application/json")
tag=$(date +%s)

curl -sf "${auth[@]}" -X POST "${base}/documents/text" -d @- <<JSON >/dev/null
{"file_source":"harbor-check-${tag}.txt","text":"Check ${tag}. The Quorvax Lantern is a brass navigation lamp designed by Marisol Venn in 1887 in the port city of Ostrahaven. Venn founded the Ostrahaven Optical Works, which manufactured the lantern for the Harlan Shipping Company. Harlan Shipping Company was owned by Augustus Harlan. Captain Edric Tolle of the steamship Meridian Star was the first to use a Quorvax Lantern on a transatlantic crossing."}
JSON

for _ in $(seq 1 120); do
  sleep 5
  [ "$(curl -sf "${auth[@]}" "${base}/documents/pipeline_status" | jq -r .busy)" = "false" ] && break
done

nodes=$(curl -sf "${auth[@]}" "${base}/graphs?label=*&max_depth=3&max_nodes=200" | jq '.nodes | length')
echo "graph nodes: ${nodes}"
[ "${nodes}" -gt 0 ] || { echo "FAIL: knowledge graph is empty"; exit 1; }

answer=$(curl -sf "${auth[@]}" -X POST "${base}/query" \
  -d '{"query":"Who owned the Harlan Shipping Company?","mode":"hybrid"}' | jq -r .response)
echo "hybrid answer: ${answer:0:200}"
grep -q "Augustus Harlan" <<<"${answer}" || { echo "FAIL: hybrid answer is not grounded"; exit 1; }
grep -q "no-context" <<<"${answer}" && { echo "FAIL: hybrid answered [no-context]"; exit 1; }
# A JSON body here means the LLM returned the keyword-extraction payload as the answer
[[ "${answer#"${answer%%[![:space:]]*}"}" == \{* ]] && { echo "FAIL: hybrid answer is the keyword JSON, not prose"; exit 1; }
echo "OK"
