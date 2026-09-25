#!/usr/bin/env bash
# Deploy ONE profile as containers and block until it is verified ready.
#   ./p1_up.sh C05        ./p1_up.sh C06:seqs=128
source "$(dirname "$0")/profile_lib.sh"
load_profile "${1:?usage: p1_up.sh PROFILE[:seqs=N]}"
LOGDIR="$RESULTS/$TAG/logs"; mkdir -p "$LOGDIR"
log "Deploying $TAG — $DESC"

# ---------- preconditions ----------
pgrep -f run_all.sh >/dev/null && die "The benchmark kit (run_all.sh) is still running — wait for 'Done' in run.log"
"$ROOT/p3_down.sh" >/dev/null
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "Image $IMAGE not found (C07/C08/C08b need: ./p0_build_nixl.sh)"
for g in $GPUS; do (( $(gpu_mem_pct "$g") < 10 )) || die "GPU $g is in use ($(gpu_mem_pct "$g")% memory) — stop whatever runs there first"; done
PORTS="$FE_PORT"; [[ $KIND != vllm ]] && for ((i=0;i<NGPU;i++)); do PORTS+=" $((SYS_PORT_BASE+i)) $((KV_EVENT_PORT_BASE+i)) $((NIXL_PORT_BASE+i))"; done
for p in $PORTS; do ss -ltn | awk '{print $4}' | grep -qE "[:.]$p\$" && die "Port $p is busy (see: ss -ltnp | grep :$p)"; done
ok "GPUs $GPUS free, ports free, image $IMAGE present"

MOUNT=(-v "$HF_CACHE:/root/.cache/huggingface" -e HF_TOKEN)
engine_args() {  # $1 = max-num-seqs, $2 = max-num-batched-tokens  (exactly one value per setting)
  ENGINE_ARGS=(--kv-cache-dtype "$KV_DTYPE" --gpu-memory-utilization "$GPU_MEM_UTIL" --max-model-len "$MAX_MODEL_LEN"
               --max-num-batched-tokens "$2" --max-num-seqs "$1" --enable-chunked-prefill --enable-prefix-caching)
}
CONTAINERS=()

start_worker() {  # name gpu index role max-num-seqs max-num-batched-tokens
  local name=$1 gpu=$2 i=$3 role=$4; engine_args "$5" "$6"
  local role_args=() ev_args=(--kv-events-config "{\"enable_kv_cache_events\":true,\"publisher\":\"zmq\",\"topic\":\"kv-events\",\"endpoint\":\"tcp://*:$((KV_EVENT_PORT_BASE+i))\"}")
  if [[ $role == prefill || $role == decode ]]; then
    role_args=(--disaggregation-mode "$role" --kv-transfer-config '{"kv_connector":"NixlConnector","kv_role":"kv_both"}')
    [[ $role == decode ]] && ev_args=()     # decode workers do not publish KV events
  fi
  docker run -d --name "$name" --gpus "\"device=$gpu\"" --network host --ipc host "${MOUNT[@]}" "${DYN_ENV[@]}" \
    -e DYN_SYSTEM_ENABLED=true -e DYN_SYSTEM_PORT=$((SYS_PORT_BASE+i)) -e VLLM_NIXL_SIDE_CHANNEL_PORT=$((NIXL_PORT_BASE+i)) \
    "$IMAGE" python -m dynamo.vllm --model "$MODEL" "${ENGINE_ARGS[@]}" "${role_args[@]}" "${ev_args[@]}" >/dev/null
  CONTAINERS+=("$name")
}

# ---------- deploy ----------
case $KIND in
  vllm)
    engine_args "$MAX_NUM_SEQS" "$MAX_NUM_BATCHED_TOKENS"
    docker run -d --name apx-vllm --gpus "\"device=$GPUS\"" --network host --ipc host "${MOUNT[@]}" \
      --entrypoint vllm "$IMAGE" serve "$MODEL" --port "$FE_PORT" --chat-template-content-format string "${ENGINE_ARGS[@]}" >/dev/null
    CONTAINERS+=(apx-vllm) ;;
  dynamo-agg|dynamo-disagg)
    "$ROOT/02_infra.sh" >/dev/null
    DYN_ENV=(-e "ETCD_ENDPOINTS=http://127.0.0.1:$ETCD_PORT" -e "NATS_SERVER=nats://127.0.0.1:$NATS_PORT" -e PYTHONHASHSEED=0)
    if [[ $KIND == dynamo-disagg ]]; then
      log "Checking NIXL on GPU $PREFILL_GPU before starting disaggregated workers"
      docker run --rm --gpus "\"device=$PREFILL_GPU\"" --network host "$IMAGE" python -c \
        "from nixl._api import nixl_agent, nixl_agent_config; nixl_agent('probe', nixl_agent_config(backends=['UCX'])); print('NIXL agent with UCX backend: OK')" \
        > "$LOGDIR/nixl_check.log" 2>&1 || { tail -15 "$LOGDIR/nixl_check.log"; die "NIXL cannot initialise on this node — C08 is blocked here (log: $LOGDIR/nixl_check.log)"; }
      ok "$(tail -1 "$LOGDIR/nixl_check.log")"
    fi
    docker run -d --name apx-frontend --network host --ipc host "${MOUNT[@]}" "${DYN_ENV[@]}" \
      "$IMAGE" python -m dynamo.frontend --router-mode "$ROUTER" --http-port "$FE_PORT" >/dev/null
    CONTAINERS+=(apx-frontend)
    if [[ $KIND == dynamo-agg ]]; then
      i=0; for g in $GPUS; do start_worker "apx-worker$i" "$g" "$i" agg "$MAX_NUM_SEQS" "$MAX_NUM_BATCHED_TOKENS"; i=$((i+1)); done
    else
      start_worker apx-prefill "$PREFILL_GPU" 0 prefill "${PREFILL_MAX_NUM_SEQS:-$MAX_NUM_SEQS}" "${PREFILL_MAX_NUM_BATCHED_TOKENS:-$MAX_NUM_BATCHED_TOKENS}"
      start_worker apx-decode  "$DECODE_GPU"  1 decode  "${DECODE_MAX_NUM_SEQS:-$MAX_NUM_SEQS}"  "${DECODE_MAX_NUM_BATCHED_TOKENS:-$MAX_NUM_BATCHED_TOKENS}"
    fi ;;
esac
ok "containers started: ${CONTAINERS[*]}"

# ---------- readiness ----------
DEADLINE=$((SECONDS + ${READY_TIMEOUT:-1500}))
save_logs() { for c in "${CONTAINERS[@]}"; do docker logs "$c" > "$LOGDIR/$c.log" 2>&1 || true; done; }
check_alive() {
  for c in "${CONTAINERS[@]}"; do
    [[ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" == true ]] || {
      save_logs; echo "  Last lines of $c:"; tail -25 "$LOGDIR/$c.log" | cut -c1-250 | sed 's/^/    /'
      die "$TAG: container $c stopped — logs in $LOGDIR"; }
  done
}
tick() {
  check_alive
  (( SECONDS < DEADLINE )) || { save_logs; die "$TAG: not ready after ${READY_TIMEOUT:-1500}s — logs in $LOGDIR"; }
  sleep "$1"
}
until curl -sf "http://localhost:$FE_PORT/v1/models" | grep -qi apertus; do tick 10; done
ok "API up on :$FE_PORT, model registered"
for g in $GPUS; do until (( $(gpu_mem_pct "$g") >= 50 )); do tick 5; done; ok "GPU $g engine loaded ($(gpu_mem_pct "$g")% memory)"; done
if [[ $KIND != vllm ]]; then
  for ((i=0;i<NGPU;i++)); do
    port=$((SYS_PORT_BASE+i)); t0=$SECONDS
    while :; do
      c=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$port/health" || true)
      [[ $c == 200 ]] && { ok "worker :$port healthy"; break; }
      if [[ $c != 503 ]] && (( SECONDS - t0 > 180 )); then warn "worker :$port gives HTTP $c on /health; relying on GPU + smoke checks"; break; fi
      tick 5
    done
  done
fi
sleep 20
check_alive

# ---------- correctness gate ----------
ANSWER=$(curl -sf "http://localhost:$FE_PORT/v1/chat/completions" -H 'Content-Type: application/json' -d "{
  \"model\":\"$MODEL\",\"max_tokens\":80,\"temperature\":0,
  \"messages\":[{\"role\":\"user\",\"content\":\"Name the four official languages of Switzerland.\"}]}" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["choices"][0]["message"]["content"])' 2>/dev/null) || true
echo "     answer: $(tr '\n' ' ' <<<"$ANSWER" | cut -c1-160)"
hits=0; for w in german french italian roman; do grep -qi "$w" <<<"$ANSWER" && hits=$((hits+1)); done
if (( hits < 3 )); then
  save_logs; grep -hE "Internal server error:|Traceback|Error:" "$LOGDIR"/*.log 2>/dev/null | sed -E 's/.*backend asserted status [0-9]+: //' | tail -3 | cut -c1-300 | sed 's/^/    /'
  die "$TAG: smoke test failed — logs in $LOGDIR"
fi
check_alive
ok "smoke test passed"

# ---------- disaggregation evidence: the prefill GPU must actually work ----------
if [[ $KIND == dynamo-disagg ]]; then
  python3 - "$FE_PORT" "$MODEL" <<'PY' &
import json, sys, threading, urllib.request
port, model = sys.argv[1], sys.argv[2]
prompt = " ".join(f"word{i % 997}" for i in range(1200)) + "\nSummarise the text above in one sentence."
def one():
    body = json.dumps({"model": model, "max_tokens": 16, "messages": [{"role": "user", "content": prompt}]}).encode()
    try: urllib.request.urlopen(urllib.request.Request(f"http://localhost:{port}/v1/chat/completions", body, {"Content-Type": "application/json"}), timeout=120).read()
    except Exception as e: print("request error:", e)
ts = [threading.Thread(target=one) for _ in range(16)]; [t.start() for t in ts]; [t.join() for t in ts]
PY
  LOADPID=$!; peak=0
  while kill -0 $LOADPID 2>/dev/null; do
    u=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits -i "$PREFILL_GPU" | tr -dc 0-9); (( u > peak )) && peak=$u; sleep 0.2
  done
  if (( peak > 0 )); then ok "prefill GPU $PREFILL_GPU busy during long prompts (peak ${peak}% utilisation) -> prefill is disaggregated"
  else save_logs; die "$TAG: prefill GPU $PREFILL_GPU stayed idle — requests are not using the prefill worker (logs in $LOGDIR)"; fi
fi

check_alive

# ---------- record exactly what was deployed ----------
C0=${CONTAINERS[-1]}
VERS=$(docker exec "$C0" python -c "import vllm, importlib.metadata as m
try: d=m.version('ai-dynamo')
except Exception: d='n/a'
print(vllm.__version__ + '|' + d)" 2>/dev/null || echo "?|?")
python3 - "$RESULTS/$TAG/profile.json" <<PY
import json, sys
json.dump({"tag": "$TAG", "profile": "$PROFILE_NAME", "phase": "$PHASE", "desc": "$DESC", "kind": "$KIND",
  "gpus": "$GPUS".split(), "n_gpus": $NGPU, "model": "$MODEL", "kv_dtype": "$KV_DTYPE", "router": "$ROUTER" if "$KIND" != "vllm" else None,
  "max_model_len": $MAX_MODEL_LEN, "gpu_mem_util": $GPU_MEM_UTIL, "max_num_batched_tokens": $MAX_NUM_BATCHED_TOKENS,
  "max_num_seqs": $MAX_NUM_SEQS,
  "prefill_max_num_seqs": "${PREFILL_MAX_NUM_SEQS:-}", "prefill_max_num_batched_tokens": "${PREFILL_MAX_NUM_BATCHED_TOKENS:-}",
  "decode_max_num_seqs": "${DECODE_MAX_NUM_SEQS:-}", "decode_max_num_batched_tokens": "${DECODE_MAX_NUM_BATCHED_TOKENS:-}",
  "image": "$IMAGE", "vllm_version": "${VERS%%|*}", "dynamo_version": "${VERS##*|}", "containers": "${CONTAINERS[*]}".split()},
  open(sys.argv[1], "w"), indent=2)
PY
save_logs
log "$TAG ready on http://localhost:$FE_PORT  (vLLM ${VERS%%|*}, Dynamo ${VERS##*|})"
