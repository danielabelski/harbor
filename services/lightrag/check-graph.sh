#!/usr/bin/env bash
# Runtime check: with lightrag up, ingesting a short document yields a
# non-empty knowledge graph and grounded hybrid-mode answers.
# Usage: ./services/lightrag/check-graph.sh [--stack ollama|llamacpp] [--ingest-only] [--queries N] [host_port] [api_key]
#   --stack        refuse to run unless the lightrag container's LLM_BINDING_HOST
#                  points at that backend (so a fact for one stack cannot pass on another)
#   --ingest-only  stop after the graph check (ingest must finish within 5 minutes)
#   --queries N    hybrid queries to run (default 5); at most 1 may fail
set -euo pipefail

stack=""; ingest_only=false; queries=5
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) stack=$2; shift 2 ;;
    --ingest-only) ingest_only=true; shift ;;
    --queries) queries=$2; shift 2 ;;
    *) break ;;
  esac
done
port=${1:-$(./harbor.sh config get lightrag.host_port)}
key=${2:-$(./harbor.sh config get lightrag.api_key)}
base="http://localhost:${port}"
auth=(-H "X-API-Key: ${key}" -H "Content-Type: application/json")
tag=$(date +%s)

container="$(./harbor.sh config get container.prefix).lightrag"
llm_host=$(docker inspect "${container}" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^LLM_BINDING_HOST=//p')
[ -n "${llm_host}" ] || { echo "SKIP: ${container} is not running"; exit 1; }
echo "lightrag LLM host: ${llm_host}"
if [ -n "${stack}" ] && [[ "${llm_host}" != *"//${stack}:"* ]]; then
  echo "SKIP: expected the ${stack} stack, lightrag is using ${llm_host}"; exit 1
fi

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

# Each query carries a unique suffix so LightRAG's query cache never serves a stale answer.
# Every answer must contain the expected name, not be [no-context], and not be the
# keyword/entity-extraction JSON or the keyword list leaking out of the keyword stage.
questions=(
  "Who owned the Harlan Shipping Company?|Augustus Harlan"
  "Who designed the Quorvax Lantern?|Marisol Venn"
  "Which company manufactured the Quorvax Lantern?|Ostrahaven Optical Works"
  "Who was the captain of the Meridian Star?|Edric Tolle"
  "In which city was the Quorvax Lantern designed?|Ostrahaven"
)
passed=0; failed=0
for i in $(seq 1 "${queries}"); do
  q=${questions[$(( (i - 1) % ${#questions[@]} ))]}
  question=${q%%|*}; expect=${q##*|}
  answer=$(curl -sf "${auth[@]}" -X POST "${base}/query" \
    -d "{\"query\":\"${question} (check ${tag}-${i})\",\"mode\":\"hybrid\"}" | jq -r .response)
  trimmed="${answer#"${answer%%[![:space:]]*}"}"
  verdict=ok
  grep -q "${expect}" <<<"${answer}" || verdict="not grounded (expected '${expect}')"
  grep -q "no-context" <<<"${answer}" && verdict="[no-context]"
  [[ "${trimmed}" == \{* || "${trimmed}" == '```json'* ]] && verdict="extraction JSON instead of prose"
  grep -qi "high.level keywords" <<<"${answer}" && verdict="keyword list leaked from the keyword stage"
  echo "hybrid ${i}/${queries} [${verdict}]: ${answer:0:160}"
  [ "${verdict}" = ok ] && passed=$((passed + 1)) || failed=$((failed + 1))
done
echo "hybrid: ${passed}/${queries} grounded"
[ "${failed}" -le 1 ] || { echo "FAIL: ${failed} of ${queries} hybrid answers were not grounded prose"; exit 1; }
echo "OK"
