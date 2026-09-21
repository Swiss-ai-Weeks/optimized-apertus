#!/usr/bin/env bash
# Start ONE configuration cleanly and block until it is fully ready.
#   vllm-1g   : plain fork vLLM, 1 GPU (no Dynamo)       -> Dynamo overhead reference
#   dyn-1w    : Dynamo frontend + 1 worker               -> scaling baseline
#   dyn-2w-rr : Dynamo + 2 workers, round-robin router   -> effect of 2nd GPU only
#   dyn-2w-kv : Dynamo + 2 workers, KV-aware router      -> effect of 2nd GPU + smart routing
source "$(dirname "$0")/common.sh"
MODE=${1:?usage: 03_start.sh <vllm-1g|dyn-1w|dyn-2w-rr|dyn-2w-kv>}
GPUS=$(gpus_for_mode "$MODE")
LOGDIR="$RESULTS/$MODE/logs"; mkdir -p "$LOGDIR"

docker rm -f "$SRV" >/dev/null 2>&1 || true
for g in $GPU_A $GPU_B; do for i in $(seq 1 30); do (( $(gpu_mem_pct "$g") < 10 )) && break; sleep 2; done; done

log "Starting $MODE on GPU(s): $GPUS"
if [[ "$MODE" == vllm-1g ]]; then
  docker run -d --name "$SRV" --gpus "\"device=$GPU_A\"" --network host --ipc host \
    -e HF_TOKEN -v "$HF_CACHE:/root/.cache/huggingface" --entrypoint vllm "$FORK_IMAGE" \
    serve "$MODEL" --port "$HTTP_PORT" \
      --max-model-len "$MAX_MODEL_LEN" --gpu-memory-utilization "$GPU_MEM_UTIL" \
      --enable-prefix-caching --chat-template-content-format string >/dev/null
else
  "$(dirname "$0")/02_infra.sh" >/dev/null
  docker run -d --name "$SRV" --gpus all --network host --ipc host \
    -e HF_TOKEN -e MODEL -e GPU_A -e GPU_B -e HTTP_PORT -e MAX_MODEL_LEN -e GPU_MEM_UTIL -e USE_VLLM_TOKENIZER \
    -e ETCD_ENDPOINTS=http://127.0.0.1:$ETCD_PORT -e NATS_SERVER=nats://127.0.0.1:$NATS_PORT \
    -v "$HF_CACHE:/root/.cache/huggingface" -v "$ROOT:/work:ro" -v "$LOGDIR:/logs" \
    "$DYN_IMAGE" bash /work/in_container.sh "$MODE" >/dev/null
fi

DEADLINE=$((SECONDS + ${READY_TIMEOUT:-1500}))
tick() { running || { docker logs "$SRV" > "$LOGDIR/container.log" 2>&1; die "$MODE: server exited — see $LOGDIR"; }
         (( SECONDS < DEADLINE )) || die "$MODE: not ready after ${READY_TIMEOUT:-1500}s — see $LOGDIR"; sleep "$1"; }

# 1) API up and model registered
until curl -sf "http://localhost:$HTTP_PORT/v1/models" | grep -qi apertus; do tick 10; done
ok "API up, model registered"

# 2) every assigned GPU actually holds a loaded engine (catches a silently-missing 2nd worker)
for g in $GPUS; do
  until (( $(gpu_mem_pct "$g") >= 50 )); do tick 5; done
  ok "GPU $g engine loaded ($(gpu_mem_pct "$g")% memory)"
done

# 3) every Dynamo worker reports healthy (503 = still starting; no answer for 180s = no status server)
if [[ "$MODE" == dyn-* ]]; then
  n=0; for g in $GPUS; do
    port=$((8081+n)); n=$((n+1)); t0=$SECONDS
    while :; do
      c=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/health" || true)
      [[ "$c" == 200 ]] && { ok "worker on GPU $g healthy (:$port)"; break; }
      if [[ "$c" != 503 ]] && (( SECONDS - t0 > 180 )); then
        warn "worker :$port exposes no /health (HTTP $c) in this Dynamo version; relying on GPU-memory + smoke checks"; break
      fi
      tick 5
    done
  done
fi
sleep 20   # let late CUDA-graph capture finish before first request

# 4) correctness gate
if "$(dirname "$0")/smoke.sh"; then ok "smoke test passed"
else
  if [[ "$MODE" == dyn-* ]]; then
    echo "  Backend error reported by Dynamo:"
    grep -hE "Internal server error:|Traceback|Error:" "$LOGDIR/frontend.log" "$LOGDIR"/worker*.log 2>/dev/null \
      | sed -E 's/.*backend asserted status [0-9]+: //' | tail -3 | cut -c1-300 | sed 's/^/    /'
  fi
  die "Smoke test failed for $MODE — full logs in $LOGDIR (send the lines above)"
fi
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv > "$LOGDIR/gpu_mem_at_ready.csv"
log "$MODE ready on http://localhost:$HTTP_PORT"
