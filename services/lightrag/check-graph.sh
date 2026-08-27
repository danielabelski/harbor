#!/usr/bin/env bash
# Runtime check: with lightrag up, ingesting a short document yields a
# non-empty knowledge graph and grounded hybrid-mode answers. The document is
# deleted again afterwards, so the knowledge base is left as it was found.
# Usage: ./services/lightrag/check-graph.sh [--stack ollama|llamacpp] [--ingest-only] [--corpus] [--queries N] [--keep] [host_port] [api_key]
#   --stack        refuse to run unless the lightrag container's LLM_BINDING_HOST
#                  points at that backend (so a fact for one stack cannot pass on another)
#   --ingest-only  stop after the graph check (ingest must finish within 5 minutes)
#   --corpus       realistic knowledge base instead of one paragraph: five short
#                  notes plus a ~3,000-word file that chunks into several pieces;
#                  questions span the notes and the long file and are asked in
#                  hybrid AND naive mode (at most 1 miss per mode); ingest may
#                  take up to 20 minutes
#   --queries N    questions to run per mode (default 5); at most 1 may fail
#   --keep         leave the check documents in the knowledge base (for debugging)
set -euo pipefail

stack=""; ingest_only=false; queries=5; keep=false; corpus=false
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) stack=$2; shift 2 ;;
    --ingest-only) ingest_only=true; shift ;;
    --corpus) corpus=true; shift ;;
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

# Always remove the check documents again, whatever the outcome, and compare the
# knowledge base against the snapshot taken before ingest.
doc_id=""
cleanup() {
  local rc=$?
  trap - EXIT
  $keep && { echo "keeping check document(s) ${doc_id:-?}"; exit "${rc}"; }
  # shellcheck disable=SC2086
  [ -n "${doc_id}" ] && delete_docs ${doc_id} >/dev/null
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

ingest_text() { # $1 file name, $2 text; prints the track id
  jq -cn --arg s "$1" --arg t "$2" '{file_source:$s,text:$t}' \
    | api -X POST "${base}/documents/text" -d @- | jq -r .track_id
}
track_doc_ids() { # $@ track ids
  local t; for t in "$@"; do api "${base}/documents/track_status/${t}" | jq -r '.documents[].id'; done | sort -u | tr '\n' ' '
}

if $corpus; then
  # Five one-liner notes plus a ~3,000-word history whose unique facts sit in
  # different chunks (LightRAG chunks at 1,200 tokens); together with whatever the
  # knowledge base already holds this is the shape a real user's KB has after a week.
  tracks=()
  tracks+=("$(ingest_text "harbor-check-${tag}-kestrel.txt" "Check ${tag}. Project Kestrel is an internal inventory tool written by the Brindlewood team. Its lead engineer is Tamsin Ferrow. Kestrel stores its data in a SQLite file named ledger.db and is deployed every Thursday.")")
  tracks+=("$(ingest_text "harbor-check-${tag}-orchard.txt" "Check ${tag}. The Orchard Pass hiking route starts at the village of Dunmere and ends at Salt Ridge. It is 14 kilometres long and was surveyed by cartographer Pell Ashgrove in 1962.")")
  tracks+=("$(ingest_text "harbor-check-${tag}-vending.txt" "Check ${tag}. The office vending machine on floor 3 is serviced by Halloway Refreshments. The account manager there is Rosa Quintrell; the machine's model is a Vendo 720.")")
  tracks+=("$(ingest_text "harbor-check-${tag}-recipe.txt" "Check ${tag}. Aunt Delphine's plum cake needs 400 grams of Mirabelle plums, dark rye flour and a teaspoon of cardamom. Bake at 170 degrees for 55 minutes in the copper tin.")")
  tracks+=("$(ingest_text "harbor-check-${tag}-cat.txt" "Check ${tag}. Our office cat is named Biscuit. She was adopted from the Fenwick Lane shelter in March 2021 and is fed twice a day by the receptionist, Oren Vasquez.")")
  filler="The Society's minute books record the ordinary business of a small learned body: subscriptions received, charts lent and returned, the purchase of coal for the reading room stove, and the endless discussion of the state of the roof. Members were fined threepence for returning a chart creased and sixpence for returning one damp. The fines fund paid for the annual dinner, held each November at the Woolpack Inn, at which the Keeper of Charts traditionally gave a report on the year's surveys and the treasurer read the accounts. The minute books also record the Society's exchanges of publications with societies as far afield as Kirkholm and Sandersby, and the slow accumulation of instruments, from the first brass theodolite bought in 1899 to the total stations and GPS receivers of recent decades. "
  long="A Short History of the Veldmark Cartographic Society (check ${tag}). The Veldmark Cartographic Society was founded in 1898 in the river town of Ashcombe by Ludovic Threnody, a retired canal surveyor, and Henrietta Bassingwaite, a schoolteacher with a passion for tidal charts. The Society's first headquarters was the upper floor of the Ashcombe Corn Exchange, rented for six shillings a month.

In its first decade the Society produced the Ashcombe Basin Atlas, twelve hand-coloured sheets covering the marshes between Ashcombe and the coastal hamlet of Pellowe, engraved by the firm of Cotterill and Dunn and printed on Farrowdale paper. The first edition sold four hundred copies, mostly to barge operators. Henrietta Bassingwaite served as the Society's first Keeper of Charts, a position she held until 1921. Her successor was Aldous Penhaligon, previously the treasurer, who reorganised the chart room by tidal reach and introduced the practice of stamping every sheet with a brass die bearing the Society's heron emblem.

The heron emblem itself was designed in 1903 by the illustrator Constance Merriweather, who was paid two guineas for the work. The original drawing hangs in the Society's reading room to this day.

$(for _ in 1 2 3 4 5 6 7 8; do printf '%s' "${filler}"; done)

During the 1920s the Society surveyed the Thistlewood Fen, the Barrow Cut and the disused Hollin Navigation. The Hollin survey was led by Ezra Fallowfield, whose 1931 Marrowby estuary chart was the first Society chart to use echo soundings, taken from the Society's launch, the Grey Heron, a converted fishing boat bought in 1929 for ninety pounds and kept at Tapley's Wharf by the boatman Jonas Wickering, whose nineteen-volume voyage log forms part of the archive. The library was established in 1912 with a bequest from the brewer Marcus Ellery and catalogued by Edith Ravenscar, who classified maps by watershed rather than county. In 1936 the Society bought Harrowgate House on Mill Lane for one thousand two hundred pounds.

$(for _ in 1 2 3 4 5 6 7 8; do printf '%s' "${filler}"; done)

After the war the Society resumed its surveys under Beatrice Lomax, Keeper of Charts from 1947 to 1968. Lomax ran the Society's first aerial survey in 1952, using photographs taken from a light aircraft chartered from the Copsley aerodrome and flown by a pilot named Gideon Marsh. The photographs were interpreted by Lomax, Fallowfield and Silas Warbrick, a former army photogrammetrist who went on to replace hand-engraving with photolithography in 1961. From 1963 the Society published a quarterly journal, the Veldmark Bulletin, first edited by Prudence Kettleby.

$(for _ in 1 2 3 4 5 6 7 8; do printf '%s' "${filler}"; done)

Today the Society has around four hundred members. Its current Keeper of Charts is Wilhelmina Sorrel, appointed in 2015, who previously worked as a hydrographer for the Marrowby Port Authority. Its president is Barnaby Quillon and its treasurer is Petra Hollinshead. The Society meets on the second Tuesday of every month in the reading room at Harrowgate House, where the librarian Fenella Marchbank opens the shop on Wednesday afternoons.

Appendix: Keepers of Charts: Henrietta Bassingwaite 1898 to 1921, Aldous Penhaligon 1921 to 1947, Beatrice Lomax 1947 to 1968, Silas Warbrick 1968 to 1990, Hugo Pinnock 1990 to 2015, Wilhelmina Sorrel 2015 to date."
  echo "corpus: 5 notes + $(wc -w <<<"${long}")-word history"
  tracks+=("$(ingest_text "harbor-check-${tag}-veldmark.txt" "${long}")")
  sleep 5
  doc_id=$(track_doc_ids "${tracks[@]}")
  limit=240
  questions=(
    "Who is the lead engineer of Project Kestrel?|Tamsin Ferrow"
    "Which shelter was the office cat Biscuit adopted from?|Fenwick Lane"
    "Who was the first Keeper of Charts of the Veldmark Cartographic Society?|Henrietta Bassingwaite"
    "Who piloted the aircraft for the Veldmark Cartographic Society's 1952 aerial survey?|Gideon Marsh"
    "Who is the current Keeper of Charts of the Veldmark Cartographic Society?|Wilhelmina Sorrel"
  )
  modes=(hybrid naive)
else
  track=$(ingest_text "harbor-check-${tag}.txt" "Check ${tag}. The Quorvax Lantern is a brass navigation lamp designed by Marisol Venn in 1887 in the port city of Ostrahaven. Venn founded the Ostrahaven Optical Works, which manufactured the lantern for the Harlan Shipping Company. Harlan Shipping Company was owned by Augustus Harlan. Captain Edric Tolle of the steamship Meridian Star was the first to use a Quorvax Lantern on a transatlantic crossing.")
  sleep 5
  doc_id=$(track_doc_ids "${track}")
  limit=120
  $ingest_only && limit=60
  questions=(
    "Who owned the Harlan Shipping Company?|Augustus Harlan"
    "Who designed the Quorvax Lantern?|Marisol Venn"
    "Which company manufactured the Quorvax Lantern?|Ostrahaven Optical Works"
    "Who was the captain of the Meridian Star?|Edric Tolle"
    "In which city was the Quorvax Lantern designed?|Ostrahaven"
  )
  modes=(hybrid)
fi

wait_idle "${limit}" || { echo "FAIL: ingest still busy"; exit 1; }
[ -n "${doc_id// /}" ] || doc_id=$(track_doc_ids "${tracks[@]:-$track}")
[ -n "${doc_id// /}" ] || { echo "FAIL: check document was not registered"; exit 1; }
failed_docs=$(api "${base}/documents" | jq -r '.statuses.failed // [] | .[] | select(.file_path | startswith("harbor-check-'"${tag}"'")) | "\(.file_path): \(.error_msg // "")"')
[ -z "${failed_docs}" ] || { echo "FAIL: ingest failed: ${failed_docs}"; exit 1; }

nodes=$(api "${base}/graphs?label=*&max_depth=3&max_nodes=200" | jq '.nodes | length')
echo "graph nodes: ${nodes}"
[ "${nodes}" -gt 0 ] || { echo "FAIL: knowledge graph is empty"; exit 1; }
$ingest_only && { echo "OK (ingest only)"; exit 0; }

# Each query carries a unique suffix so LightRAG's query cache never serves a stale answer.
# Strict grading: an answer passes only if it states the expected name AND does not
# hedge that the fact is unknown, fictional or unsupported; [no-context], extraction
# JSON and leaked keyword lists fail outright.
hedge='no (record|information|mention|evidence|data)|not (a real|an actual|real|mentioned|found|available|provided|documented)|fictional|does not (exist|appear|mention|contain)|cannot (find|determine|identify|confirm)|unable to|there is no|i (do not|don'"'"'t) (have|know)|not (explicitly )?(stated|specified|known)'
rc=0
for mode in "${modes[@]}"; do
  passed=0; failed=0
  for i in $(seq 1 "${queries}"); do
    q=${questions[$(( (i - 1) % ${#questions[@]} ))]}
    question=${q%%|*}; expect=${q##*|}
    answer=$(api -X POST "${base}/query" \
      -d "{\"query\":\"${question} (check ${tag}-${i})\",\"mode\":\"${mode}\"}" | jq -r .response)
    trimmed="${answer#"${answer%%[![:space:]]*}"}"
    verdict=ok
    grep -q "${expect}" <<<"${answer}" || verdict="not grounded (expected '${expect}')"
    [ "${verdict}" = ok ] && grep -qiE "${hedge}" <<<"${answer}" && verdict="hedged ('$(grep -oiE "${hedge}" <<<"${answer}" | head -1)')"
    grep -q "no-context" <<<"${answer}" && verdict="[no-context]"
    [[ "${trimmed}" == \{* || "${trimmed}" == '```json'* ]] && verdict="extraction JSON instead of prose"
    grep -qi "high.level keywords" <<<"${answer}" && verdict="keyword list leaked from the keyword stage"
    echo "${mode} ${i}/${queries} [${verdict}]: ${answer:0:160}"
    [ "${verdict}" = ok ] && passed=$((passed + 1)) || failed=$((failed + 1))
  done
  echo "${mode}: ${passed}/${queries} grounded"
  [ "${failed}" -le 1 ] || { echo "FAIL: ${failed} of ${queries} ${mode} answers were not grounded prose"; rc=1; }
done
[ "${rc}" -eq 0 ] || exit "${rc}"
echo "OK"
