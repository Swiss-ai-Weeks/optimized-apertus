cd ~/apertus-dynamo-bench
set +H
cat > 'common.sh' <<'__FIX_EOF__'
#!/usr/bin/env bash
# Shared config + helpers. Sourced by every script.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
[[ -f .env ]] || { echo "[FAIL] Missing .env  ->  cp .env.example .env  and fill in HF_TOKEN"; exit 1; }
set -a; source ./.env; set +a
mkdir -p "$RESULTS" "$HF_CACHE"
RESULTS="$(cd "$RESULTS" && pwd)"
HF_CACHE="$(cd "$HF_CACHE" && pwd)"
SRV=apertus-srv
ETCD_PORT=${ETCD_PORT:-2479}; ETCD_PEER_PORT=${ETCD_PEER_PORT:-2480}; NATS_PORT=${NATS_PORT:-4322}

log()  { printf '\n\033[1;34m[%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '  \033[32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31m[FAIL] %s\033[0m\n' "$*" >&2; exit 1; }

running() { [[ "$(docker inspect -f '{{.State.Running}}' "$SRV" 2>/dev/null || true)" == "true" ]]; }

gpu_mem_pct() {
  nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits -i "$1" \
    | awk -F', *' '{printf "%d", 100*$1/$2}'
}

gpus_for_mode() {
  case "$1" in
    vllm-1g|dyn-1w)        echo "$GPU_A" ;;
    dyn-2w-rr|dyn-2w-kv)   echo "$GPU_A $GPU_B" ;;
    *) die "Unknown mode '$1' (use: vllm-1g dyn-1w dyn-2w-rr dyn-2w-kv)" ;;
  esac
}
__FIX_EOF__
cat > '00_preflight.sh' <<'__FIX_EOF__'
#!/usr/bin/env bash
# Verifies everything that would otherwise fail halfway through a run.
source "$(dirname "$0")/common.sh"
log "Preflight"
docker rm -f apertus-srv apertus-etcd apertus-nats >/dev/null 2>&1 || true   # leftovers from an earlier run of THIS kit

command -v docker >/dev/null     || die "docker not found"
command -v nvidia-smi >/dev/null || die "nvidia-smi not found"
command -v python3 >/dev/null    || die "python3 not found (needed by smoke test)"
command -v curl >/dev/null       || die "curl not found"
ok "docker, nvidia-smi, python3, curl present"

NGPU=$(nvidia-smi -L | wc -l)
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader | sed 's/^/     /'
(( NGPU >= 2 )) || die "Only $NGPU GPU(s). 2-worker comparison needs 2. (Set MODES=\"vllm-1g dyn-1w\" to run the single-GPU part only.)"
for g in $GPU_A $GPU_B; do (( g < NGPU )) || die "GPU index $g does not exist"; done
ok "$NGPU GPUs; using GPU_A=$GPU_A GPU_B=$GPU_B"
nvidia-smi topo -m > "$RESULTS/topology.txt" && ok "topology saved to results/topology.txt"

for g in $GPU_A $GPU_B; do
  p=$(gpu_mem_pct "$g"); (( p < 10 )) || die "GPU $g already ${p}% used — stop other containers first (docker ps)"
done
ok "target GPUs are free"

[[ "$HF_TOKEN" == hf_* && "$HF_TOKEN" != "hf_xxx" ]] || die "HF_TOKEN not set in .env"
code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $HF_TOKEN" \
       "https://huggingface.co/$MODEL/resolve/main/config.json")
[[ "$code" == 200 || "$code" == 302 ]] || die "HF returned $code for $MODEL/config.json — log in on huggingface.co and click 'Agree' on the model page (gated repo)"
ok "HF token can read gated $MODEL"

free_gb=$(df -BG --output=avail "$HF_CACHE" | tail -1 | tr -dc 0-9)
(( free_gb >= 40 )) || die "Only ${free_gb} GB free at $HF_CACHE (need 40)"
ok "${free_gb} GB free for weights"

for p in "$HTTP_PORT" "$ETCD_PORT" "$ETCD_PEER_PORT" "$NATS_PORT" 8081 8082 5557 5558; do
  (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | awk '{print $4}' | grep -qE "[:.]$p\$" \
    && die "Port $p already in use (change it in .env: HTTP_PORT / ETCD_PORT / ETCD_PEER_PORT / NATS_PORT)"
done
ok "ports free"
log "Preflight passed"
__FIX_EOF__
cat > '02_infra.sh' <<'__FIX_EOF__'
#!/usr/bin/env bash
# PRIVATE etcd + NATS for this benchmark (own names + ports), so we never collide with
# or discover anything from other Dynamo stacks on the same node. Idempotent.
source "$(dirname "$0")/common.sh"
log "Starting private etcd (:$ETCD_PORT) + NATS (:$NATS_PORT)"
docker rm -f apertus-etcd apertus-nats >/dev/null 2>&1 || true
docker run -d --name apertus-etcd --network host quay.io/coreos/etcd:v3.5.21 \
  etcd --name apertus --data-dir /tmp/etcd \
       --listen-client-urls "http://127.0.0.1:$ETCD_PORT" --advertise-client-urls "http://127.0.0.1:$ETCD_PORT" \
       --listen-peer-urls "http://127.0.0.1:$ETCD_PEER_PORT" --initial-advertise-peer-urls "http://127.0.0.1:$ETCD_PEER_PORT" \
       --initial-cluster "apertus=http://127.0.0.1:$ETCD_PEER_PORT" >/dev/null
docker run -d --name apertus-nats --network host nats:2.10 -js -p "$NATS_PORT" >/dev/null
for i in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$ETCD_PORT/health" | grep -q true && break
  (( i == 30 )) && { docker logs apertus-etcd | tail -20; die "private etcd not healthy on :$ETCD_PORT"; }
  sleep 1
done
ok "etcd healthy (:$ETCD_PORT)"
for i in $(seq 1 15); do
  (exec 3<>"/dev/tcp/127.0.0.1/$NATS_PORT") 2>/dev/null && break
  (( i == 15 )) && { docker logs apertus-nats | tail -20; die "private NATS not listening on :$NATS_PORT"; }
  sleep 1
done
ok "NATS listening (:$NATS_PORT)"
__FIX_EOF__
cat > '03_start.sh' <<'__FIX_EOF__'
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
  if [[ "$MODE" == dyn-* && "$USE_VLLM_TOKENIZER" != true ]]; then
    die "Smoke test failed behind Dynamo's preprocessor (likely the 1.5 chat template). Set USE_VLLM_TOKENIZER=true in .env and re-run; then report dyn-2w-kv vs dyn-2w-rr as NOT valid (router can't see tokens)."
  fi
  die "Smoke test failed for $MODE — see $LOGDIR"
fi
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv > "$LOGDIR/gpu_mem_at_ready.csv"
log "$MODE ready on http://localhost:$HTTP_PORT"
__FIX_EOF__
cat > '99_stop.sh' <<'__FIX_EOF__'
#!/usr/bin/env bash
# Stops ONLY this kit's containers (never the node's own etcd/nats).
source "$(dirname "$0")/common.sh"
docker rm -f "$SRV" apertus-etcd apertus-nats >/dev/null 2>&1 || true
ok "stopped apertus-srv, apertus-etcd, apertus-nats"
__FIX_EOF__
cat > 'run_all.sh' <<'__FIX_EOF__'
#!/usr/bin/env bash
# Full pipeline. Re-runnable: skip build with SKIP_BUILD=1, restrict with MODES="dyn-1w dyn-2w-kv".
source "$(dirname "$0")/common.sh"
D="$(dirname "$0")"
"$D/00_preflight.sh"
[[ "${SKIP_BUILD:-0}" == 1 ]] || "$D/01_build.sh"
for M in $MODES; do
  "$D/03_start.sh" "$M"
  "$D/04_bench.sh" "$M"
  docker logs "$SRV" > "$RESULTS/$M/logs/container.log" 2>&1 || true
done
"$D/99_stop.sh"
log "Summarizing"
docker run --rm -e TTFT_SLO_MS -v "$RESULTS:/results" -v "$ROOT:/work:ro" "$CLIENT_IMAGE" \
  python /work/05_summarize.py /results
tar czf "$ROOT/results_$(date +%Y%m%d_%H%M).tgz" -C "$(dirname "$RESULTS")" "$(basename "$RESULTS")"
log "Done. Copy results_*.tgz off the LaunchPad box NOW (sessions are ephemeral)."
__FIX_EOF__
chmod +x *.sh
grep -c "apertus-etcd" 02_infra.sh 99_stop.sh 00_preflight.sh; grep -c "ETCD_PORT" 03_start.sh common.sh
