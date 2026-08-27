#!/usr/bin/env bash
# Runtime check: with lightrag up, ingesting a short document yields a
# non-empty knowledge graph and grounded hybrid-mode answers. The document is
# deleted again afterwards, so the knowledge base is left as it was found.
# Usage: ./services/lightrag/check-graph.sh [--stack ollama|llamacpp] [--ingest-only] [--queries N] [--keep] [host_port] [api_key]
#   --stack        refuse to run unless the lightrag container's LLM_BINDING_HOST
#                  points at that backend (so a fact for one stack cannot pass on another)
#   --ingest-only  stop after the graph check (ingest must finish within 5 minutes)
#   --queries N    hybrid queries to run (default 5); at most 1 may fail
#   --keep         leave the check document in the knowledge base (for debugging)
set -euo pipefail

stack=""; ingest_only=false; queries=5; keep=false
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) stack=$2; shift 2 ;;
    --ingest-only) ingest_only=true; shift ;;
    --queries) queries=$2; shift 2 ;;
    --keep) keep=true; shift ;;
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

api() { curl -sf "${auth[@]}" "$@"; }
pipeline_idle() { [ "$(api "${base}/documents/pipeline_status" | jq -r .busy)" = "false" ]; }
wait_idle() {
  for _ in $(seq 1 "$1"); do pipeline_idle && return 0; sleep 5; done
  pipeline_idle
}
doc_ids() { api "${base}/documents" | jq -r '.statuses[][] | .id' | sort; }
delete_docs() {
  local ids; ids=$(jq -cn --args '$ARGS.positional' "$@")
  api -X DELETE "${base}/documents/delete_document" \
    -d "{\"doc_ids\":${ids},\"delete_file\":true,\"delete_llm_cache\":true}" | jq -r .status
  wait_idle 60
}

wait_idle 12 || { echo "FAIL: pipeline busy before the check started"; exit 1; }

before=$(doc_ids)
echo "documents before: $(grep -c . <<<"${before}" || true)"

# Always remove the check document again, whatever the outcome, and compare the
# knowledge base against the snapshot taken before ingest.
doc_id=""
cleanup() {
  local rc=$?
  trap - EXIT
  $keep && { echo "keeping check document ${doc_id:-?}"; exit "${rc}"; }
  [ -n "${doc_id}" ] && delete_docs "${doc_id}" >/dev/null
  local after; after=$(doc_ids)
  if [ "${after}" != "${before}" ]; then
    echo "FAIL: knowledge base differs from the pre-check snapshot after cleanup"
    diff <(echo "${before}") <(echo "${after}") || true
    exit 1
  fi
  echo "cleanup: knowledge base restored ($(grep -c . <<<"${after}" || true) documents)"
  exit "${rc}"
}
trap cleanup EXIT

track=$(api -X POST "${base}/documents/text" -d @- <<JSON | jq -r .track_id
{"file_source":"harbor-check-${tag}.txt","text":"Check ${tag}. The Quorvax Lantern is a brass navigation lamp designed by Marisol Venn in 1887 in the port city of Ostrahaven. Venn founded the Ostrahaven Optical Works, which manufactured the lantern for the Harlan Shipping Company. Harlan Shipping Company was owned by Augustus Harlan. Captain Edric Tolle of the steamship Meridian Star was the first to use a Quorvax Lantern on a transatlantic crossing."}
JSON
)
sleep 5
doc_id=$(api "${base}/documents/track_status/${track}" | jq -r '.documents[0].id // empty')

limit=120
$ingest_only && limit=60
wait_idle "${limit}" || { echo "FAIL: ingest still busy"; exit 1; }
[ -n "${doc_id}" ] || doc_id=$(api "${base}/documents/track_status/${track}" | jq -r '.documents[0].id // empty')
[ -n "${doc_id}" ] || { echo "FAIL: check document was not registered"; exit 1; }

nodes=$(api "${base}/graphs?label=*&max_depth=3&max_nodes=200" | jq '.nodes | length')
echo "graph nodes: ${nodes}"
[ "${nodes}" -gt 0 ] || { echo "FAIL: knowledge graph is empty"; exit 1; }
$ingest_only && { echo "OK (ingest only)"; exit 0; }

# Each query carries a unique suffix so LightRAG's query cache never serves a stale answer.
# Strict grading: an answer passes only if it states the expected name AND does not
# hedge that the fact is unknown, fictional or unsupported; [no-context], extraction
# JSON and leaked keyword lists fail outright.
questions=(
  "Who owned the Harlan Shipping Company?|Augustus Harlan"
  "Who designed the Quorvax Lantern?|Marisol Venn"
  "Which company manufactured the Quorvax Lantern?|Ostrahaven Optical Works"
  "Who was the captain of the Meridian Star?|Edric Tolle"
  "In which city was the Quorvax Lantern designed?|Ostrahaven"
)
hedge='no (record|information|mention|evidence|data)|not (a real|an actual|real|mentioned|found|available|provided|documented)|fictional|does not (exist|appear|mention|contain)|cannot (find|determine|identify|confirm)|unable to|there is no|i (do not|don'"'"'t) (have|know)|not (explicitly )?(stated|specified|known)'
passed=0; failed=0
for i in $(seq 1 "${queries}"); do
  q=${questions[$(( (i - 1) % ${#questions[@]} ))]}
  question=${q%%|*}; expect=${q##*|}
  answer=$(api -X POST "${base}/query" \
    -d "{\"query\":\"${question} (check ${tag}-${i})\",\"mode\":\"hybrid\"}" | jq -r .response)
  trimmed="${answer#"${answer%%[![:space:]]*}"}"
  verdict=ok
  grep -q "${expect}" <<<"${answer}" || verdict="not grounded (expected '${expect}')"
  [ "${verdict}" = ok ] && grep -qiE "${hedge}" <<<"${answer}" && verdict="hedged ('$(grep -oiE "${hedge}" <<<"${answer}" | head -1)')"
  grep -q "no-context" <<<"${answer}" && verdict="[no-context]"
  [[ "${trimmed}" == \{* || "${trimmed}" == '```json'* ]] && verdict="extraction JSON instead of prose"
  grep -qi "high.level keywords" <<<"${answer}" && verdict="keyword list leaked from the keyword stage"
  echo "hybrid ${i}/${queries} [${verdict}]: ${answer:0:160}"
  [ "${verdict}" = ok ] && passed=$((passed + 1)) || failed=$((failed + 1))
done
echo "hybrid: ${passed}/${queries} grounded"
[ "${failed}" -le 1 ] || { echo "FAIL: ${failed} of ${queries} hybrid answers were not grounded prose"; exit 1; }
echo "OK"
