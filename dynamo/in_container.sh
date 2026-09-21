#!/usr/bin/env bash
# Runs INSIDE the Dynamo container: frontend + 1 or 2 vLLM workers, identical worker flags.
set -euo pipefail
MODE=$1
case "$MODE" in
  dyn-1w)    NW=1; ROUTER=kv ;;
  dyn-2w-rr) NW=2; ROUTER=round-robin ;;
  dyn-2w-kv) NW=2; ROUTER=kv ;;
  *) echo "bad mode $MODE"; exit 2 ;;
esac
GPUS=("$GPU_A" "$GPU_B")
export PYTHONHASHSEED=0 DYN_VLLM_USE_TOKENIZER="$USE_VLLM_TOKENIZER"

python -m dynamo.frontend --router-mode "$ROUTER" --http-port "$HTTP_PORT" > /logs/frontend.log 2>&1 &

for ((i=0; i<NW; i++)); do
  KVCFG="{\"enable_kv_cache_events\":true,\"publisher\":\"zmq\",\"topic\":\"kv-events\",\"endpoint\":\"tcp://*:$((5557+i))\"}"
  CUDA_VISIBLE_DEVICES="${GPUS[$i]}" DYN_SYSTEM_ENABLED=true DYN_SYSTEM_PORT=$((8081+i)) \
  python -m dynamo.vllm \
      --model "$MODEL" \
      --max-model-len "$MAX_MODEL_LEN" \
      --gpu-memory-utilization "$GPU_MEM_UTIL" \
      --enable-prefix-caching \
      --kv-events-config "$KVCFG" \
      > "/logs/worker$i.log" 2>&1 &
done
echo "mode=$MODE router=$ROUTER workers=$NW started"
wait -n
echo "A Dynamo process exited — container stops. See /logs/*.log"
exit 1
