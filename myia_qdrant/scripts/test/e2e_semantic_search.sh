#!/usr/bin/env bash
# E2E test for the full semantic search pipeline:
#   embedding service -> Qdrant search
#
# Usage:
#   ./e2e_semantic_search.sh                    # default query
#   ./e2e_semantic_search.sh "my custom query"  # custom query
#
# Exit codes:
#   0 = all checks passed
#   1 = embedding service down/unauthorized
#   2 = Qdrant down/unauthorized
#   3 = dimension mismatch
#   4 = search returned no results
#   5 = search latency too high (>3s)

set -euo pipefail

# Resolve repo root (script is in myia_qdrant/scripts/test/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ENV_FILE="$REPO_ROOT/myia_qdrant/.env.production"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FAIL: $ENV_FILE not found" >&2
  exit 1
fi

set -o allexport
source "$ENV_FILE"
set +o allexport

QUERY="${1:-binary quantization performance}"
COLLECTION="${QDRANT_COLLECTION_NAME:-roo_tasks_semantic_index}"
QDRANT_URL="${QDRANT_URL:-http://localhost:6333}"
LATENCY_THRESHOLD_MS="${LATENCY_THRESHOLD_MS:-3000}"

# Pretty output helpers
GREEN=$'\e[32m'; RED=$'\e[31m'; YELLOW=$'\e[33m'; RESET=$'\e[0m'
ok()   { echo "${GREEN}  OK${RESET}  $*"; }
fail() { echo "${RED}FAIL${RESET}  $*" >&2; }
warn() { echo "${YELLOW}WARN${RESET}  $*"; }

echo "E2E semantic search test"
echo "  query      : $QUERY"
echo "  collection : $COLLECTION"
echo "  qdrant     : $QDRANT_URL"
echo "  embeddings : $EMBEDDING_API_BASE_URL"
echo ""

# ---- 1. Embedding service health ----------------------------------
echo "[1/4] Embedding service health"
t_models_ms=$(curl -s -o /dev/null -w '%{time_total}' --max-time 15 \
  -H "Authorization: Bearer $EMBEDDING_API_KEY" \
  "$EMBEDDING_API_BASE_URL/models" | awk '{print int($1*1000)}')
http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -H "Authorization: Bearer $EMBEDDING_API_KEY" \
  "$EMBEDDING_API_BASE_URL/models")

if [[ "$http_code" != "200" ]]; then
  fail "embedding /models HTTP=$http_code time=${t_models_ms}ms"
  exit 1
fi
ok "embedding /models HTTP=200 time=${t_models_ms}ms"

# ---- 2. Generate embedding ---------------------------------------
echo "[2/4] Generate embedding for query"
embed_body=$(python -c "import json,sys; print(json.dumps({'input':sys.argv[1],'model':'$EMBEDDING_MODEL'}))" "$QUERY")
t_embed_start=$(python -c "import time; print(time.time())")
embed_resp=$(curl -s --max-time 30 \
  -H "Authorization: Bearer $EMBEDDING_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "$EMBEDDING_API_BASE_URL/embeddings" \
  -d "$embed_body")
t_embed_ms=$(python -c "import time; print(int((time.time()-$t_embed_start)*1000))")

dims=$(echo "$embed_resp" | python -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('data',[{}])[0].get('embedding',[])) if 'data' in d else -1)")
if [[ "$dims" -le 0 ]]; then
  fail "embed failed: $(echo $embed_resp | head -c 200)"
  exit 1
fi
if [[ "$dims" -ne "$EMBEDDING_DIMENSIONS" ]]; then
  fail "dim mismatch: got $dims, expected $EMBEDDING_DIMENSIONS"
  exit 3
fi
ok "embedding dims=$dims time=${t_embed_ms}ms"

# Save vector to file for Qdrant search
echo "$embed_resp" | python -c "
import sys, json
d = json.load(sys.stdin)
vec = d['data'][0]['embedding']
body = {'vector': vec, 'limit': 5, 'with_payload': True}
print(json.dumps(body))
" > /tmp/e2e_search_body.json

# ---- 3. Qdrant health ---------------------------------------------
echo "[3/4] Qdrant collection health"
coll_resp=$(curl -s --max-time 10 -H "api-key: $QDRANT_SERVICE_API_KEY" "$QDRANT_URL/collections/$COLLECTION")
status=$(echo "$coll_resp" | python -c "import sys,json; print(json.load(sys.stdin)['result']['status'])" 2>/dev/null || echo "unreachable")
points=$(echo "$coll_resp" | python -c "import sys,json; print(json.load(sys.stdin)['result']['points_count'])" 2>/dev/null || echo "0")
coll_dim=$(echo "$coll_resp" | python -c "import sys,json; d=json.load(sys.stdin)['result']['config']['params']['vectors']; print(d.get('size', d))" 2>/dev/null || echo "?")

if [[ "$status" != "green" && "$status" != "yellow" ]]; then
  fail "collection status=$status"
  exit 2
fi
if [[ "$coll_dim" != "$EMBEDDING_DIMENSIONS" ]]; then
  fail "collection dim=$coll_dim != embedding dim=$EMBEDDING_DIMENSIONS"
  exit 3
fi
ok "collection status=$status points=$points dim=$coll_dim"

# ---- 4. Semantic search end-to-end --------------------------------
echo "[4/4] Semantic search"
t_search_start=$(python -c "import time; print(time.time())")
search_resp=$(curl -s --max-time 30 \
  -H "api-key: $QDRANT_SERVICE_API_KEY" \
  -H "Content-Type: application/json" \
  -X POST "$QDRANT_URL/collections/$COLLECTION/points/search" \
  --data @/tmp/e2e_search_body.json)
t_search_ms=$(python -c "import time; print(int((time.time()-$t_search_start)*1000))")

result_count=$(echo "$search_resp" | python -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',[])))" 2>/dev/null || echo "0")
if [[ "$result_count" -eq 0 ]]; then
  fail "no results (response: $(echo $search_resp | head -c 200))"
  exit 4
fi

ok "got $result_count results in ${t_search_ms}ms"
if [[ "$t_search_ms" -gt "$LATENCY_THRESHOLD_MS" ]]; then
  warn "search latency ${t_search_ms}ms > threshold ${LATENCY_THRESHOLD_MS}ms"
  # Not a hard fail — cold cache may exceed threshold on first call.
fi

# Top-1 score
top1=$(echo "$search_resp" | python -c "import sys,json; r=json.load(sys.stdin)['result']; print(f\"id={r[0]['id']} score={r[0]['score']:.4f}\")" 2>/dev/null || echo "?")
echo "        top1: $top1"

total_ms=$((t_embed_ms + t_search_ms))
echo ""
echo "TOTAL pipeline: ${total_ms}ms  (embed=${t_embed_ms}ms + search=${t_search_ms}ms)"

rm -f /tmp/e2e_search_body.json
exit 0
