#!/usr/bin/env bash
# Benchmark matrix orchestrator. DEDICATED WINDOW: takes over BOTH GPUs and removes
# other apr-*/specdec endpoints between runs. Do NOT run while the team uses :8000.
# Each CONFIG: "name|<launch.sh args>|port". Env: CONC, REQ, MT.
set -uo pipefail
D=$HOME/optimized-apertus; L=$D/serve/launch.sh; B=$D/bench/bench.py
ready(){ for i in $(seq 1 120); do for ep in health v1/health/ready; do
  [ "$(curl -s -o /dev/null -w '%{http_code}' http://localhost:$1/$ep 2>/dev/null)" = 200 ] && return 0; done; sleep 5; done; return 1; }
CONFIGS=(
 "8b_2509_bf16|single swiss-ai/Apertus-8B-Instruct-2509 0 8000 bf16|8000"
 "70b_2509_fp8|single swiss-ai/Apertus-70B-Instruct-2509 0 8000 fp8|8000"
 "specdec_2509_n5|specdec swiss-ai/Apertus-70B-Instruct-2509 swiss-ai/Apertus-8B-Instruct-2509 8000 5|8000"
 "specdec_2509_n3|specdec swiss-ai/Apertus-70B-Instruct-2509 swiss-ai/Apertus-8B-Instruct-2509 8000 3|8000"
 "v15_8b|single swiss-ai/Apertus-v1.5-8B 0 8000 bf16|8000"
)
CONC=${CONC:-8}; REQ=${REQ:-32}; MT=${MT:-256}
for c in "${CONFIGS[@]}"; do
  name="${c%%|*}"; tmp="${c#*|}"; args="${tmp%|*}"; port="${tmp##*|}"
  echo "================ $name ================"
  docker ps -aq --filter name=apr- --filter name=specdec | xargs -r docker rm -f >/dev/null 2>&1
  bash "$L" $args || { echo "[skip] launch failed"; continue; }
  echo "waiting for :$port ..."; ready "$port" || { echo "[skip] not ready"; docker logs $(docker ps -lq) 2>&1 | tail -6; continue; }
  MODEL=$(curl -s http://localhost:$port/v1/models | python3 -c 'import sys,json;print(json.load(sys.stdin)["data"][0]["id"])')
  python3 "$B" --url http://localhost:$port --model "$MODEL" --name "$name" --concurrency $CONC --requests $REQ --max-tokens $MT
done
docker ps -aq --filter name=apr- --filter name=specdec | xargs -r docker rm -f >/dev/null 2>&1
echo "DONE -> python3 $D/analyze/table.py"
