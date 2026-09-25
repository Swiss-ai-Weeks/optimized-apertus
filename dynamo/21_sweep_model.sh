#!/usr/bin/env bash
# 21_sweep.sh - walk the concurrency ladder for one workload against whatever
# is currently serving on $NIM_PORT, and stop early once the SLO is violated.
#
# Usage:
#   bench/21_sweep.sh chat                       # one workload
#   bench/21_sweep.sh all                        # every workload in scenarios.json
#   SYSTEM=nim-8b-tp1 bench/21_sweep.sh rag      # label the run for the collector
#
# The point of the ladder: the knee of the throughput-vs-latency curve under
# your SLO is the only operating point whose cost-per-token means anything.
# Peak throughput at concurrency 256 with a 9-second TTFT is not a product.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=/dev/null
source .env

WL="${1:-chat}"
PORT="${NIM_PORT:-8000}"
URL="http://localhost:$PORT"
SYSTEM="${SYSTEM:-$(cat "$ARTIFACTS_DIR/serve/CURRENT" 2>/dev/null || echo unknown)}"
SCEN="bench/scenarios.json"

if [ "$WL" = "all" ]; then
  for w in $(python3 -c "import json;print(' '.join(x['name'] for x in json.load(open('$SCEN'))['workloads']))"); do
    "$0" "$w"
  done
  exit 0
fi

read -r ISL OSL TTFT_SLO ITL_SLO FIXED_OUT NEED_LEN <<EOF
$(python3 - "$SCEN" "$WL" <<'PY'
import json,sys
s=json.load(open(sys.argv[1]))
w=next(x for x in s["workloads"] if x["name"]==sys.argv[2])
slo=w.get("slo") or {}
print(w["isl"], w["osl"], slo.get("ttft_ms_p95",0), slo.get("itl_ms_p95",0),
      int(w.get("fixed_output", True)), w.get("requires_max_model_len", 0))
PY
)
EOF

# Guard: a long-context shape against a short-context server measures nothing.
if [ "${NEED_LEN:-0}" -gt 0 ] && [ "${MAX_MODEL_LEN:-8192}" -lt "$NEED_LEN" ]; then
  echo "SKIP '$WL': needs --max-model-len >= $NEED_LEN, server is at ${MAX_MODEL_LEN:-8192}."
  echo "  restart with: MAX_MODEL_LEN=$NEED_LEN bash serve/15_serve_v15.sh"
  exit 0
fi

LADDER=$(python3 -c "import json;print(' '.join(map(str,json.load(open('$SCEN'))['concurrency_ladder'])))")
NREQ=$(python3 -c "import json;print(json.load(open('$SCEN'))['request_count_per_concurrency'])")

ROOT="$ARTIFACTS_DIR/bench/$SYSTEM/$WL"
mkdir -p "$ROOT"
echo "== sweep: system=$SYSTEM workload=$WL isl=$ISL osl=$OSL =="

# Fixed-length output makes configs comparable. Thinking mode must NOT be pinned:
# the model decides how long it reasons, and forcing ignore_eos would measure a
# truncated trace instead of the real, billable cost.
OUT_ARGS=(--output-tokens-mean "$OSL" --output-tokens-stddev 0
          --extra-inputs "max_tokens:$OSL")
[ "$FIXED_OUT" = 1 ] && OUT_ARGS+=(--extra-inputs ignore_eos:true)

for C in $LADDER; do
  echo "-- concurrency $C"
  OUTDIR="$ROOT/c$C"
  mkdir -p "$OUTDIR"
  aiperf profile \
    --model "${SERVED_MODEL:-apertus}" \
    --tokenizer "${TOKENIZER:-swiss-ai/Apertus-v1.5-8B}" \
    --url "$URL" \
    --endpoint-type chat \
    --streaming \
    --synthetic-input-tokens-mean "$ISL" \
    --synthetic-input-tokens-stddev 0 \
    "${OUT_ARGS[@]}" \
    --concurrency "$C" \
    --request-count "$((NREQ > C*4 ? NREQ : C*4))" \
    --warmup-request-count 20 \
    --artifact-dir "$OUTDIR" \
    >"$OUTDIR/stdout.txt" 2>&1 || { echo "   aiperf failed, see $OUTDIR/stdout.txt"; break; }

  # early stop on SLO violation - saves a lot of GPU minutes
  if [ "$TTFT_SLO" != "0" ]; then
    VIOL=$(python3 bench/22_collect.py --check-slo "$OUTDIR" \
             --ttft-p95-ms "$TTFT_SLO" --itl-p95-ms "$ITL_SLO" || echo violated)
    echo "   slo: $VIOL"
    [ "$VIOL" = "violated" ] && { echo "   -> knee passed, stopping ladder"; break; }
  fi
done

echo "== done. collect with: python3 bench/22_collect.py --root $ARTIFACTS_DIR/bench =="
