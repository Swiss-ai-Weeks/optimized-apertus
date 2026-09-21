#!/usr/bin/env bash
# Adds the C05-C08 profile toolkit to ~/apertus-dynamo-bench (does not touch run_all.sh or its files).
set -e
cd ~/apertus-dynamo-bench
mkdir -p profiles
cat > 'profile_lib.sh' <<'__P_EOF__'
#!/usr/bin/env bash
# Loads a profile spec:  NAME[:seqs=N][,bt=N][,conc=A+B+C]   e.g.  C06   C06:seqs=128
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_profile() {
  local spec=$1 name ovr pair k v
  name=${spec%%:*}; ovr=""; [[ $spec == *:* ]] && ovr=${spec#*:}
  [[ -f "$ROOT/profiles/$name.env" ]] || die "Unknown profile '$name' (available: $(ls "$ROOT/profiles" | grep -vE '^(common|p3_winner)' | sed 's/\.env$//' | tr '\n' ' '))"
  unset DESC PHASE KIND GPUS PREFILL_GPU DECODE_GPU PREFILL_MAX_NUM_SEQS PREFILL_MAX_NUM_BATCHED_TOKENS DECODE_MAX_NUM_SEQS DECODE_MAX_NUM_BATCHED_TOKENS
  set -a
  source "$ROOT/profiles/common.env"
  source "$ROOT/profiles/p3_winner.env"
  source "$ROOT/profiles/$name.env"
  set +a
  TAG=$name; PROFILE_NAME=$name
  if [[ -n $ovr ]]; then
    IFS=',' read -ra _pairs <<<"$ovr"
    for pair in "${_pairs[@]}"; do
      k=${pair%%=*}; v=${pair#*=}
      [[ -n $k && -n $v && $pair == *=* ]] || die "Bad override '$pair' (use seqs=N, bt=N, conc=A+B+C)"
      case $k in
        seqs) MAX_NUM_SEQS=$v ;;
        bt)   MAX_NUM_BATCHED_TOKENS=$v ;;
        conc) CONCURRENCIES=${v//+/ } ;;
        *) die "Unknown override '$k' (use seqs=, bt=, conc=)" ;;
      esac
      [[ $k == conc ]] || TAG="$TAG-$k$v"
    done
  fi
  [[ ${PHASE:-} == P4 && -z ${P3_WINNER:-} ]] && die "Phase-3 gate not decided: set P3_WINNER, P3_ROUTER, P3_MAX_NUM_SEQS in profiles/p3_winner.env"
  NGPU=$(wc -w <<<"$GPUS")
  [[ $KIND =~ ^(vllm|dynamo-agg|dynamo-disagg)$ ]] || die "Profile $name: KIND must be vllm | dynamo-agg | dynamo-disagg"
  [[ $KIND == vllm && $NGPU != 1 ]] && die "Profile $name: standalone vLLM profile must use exactly 1 GPU"
  [[ $KIND == dynamo-disagg && ( -z ${PREFILL_GPU:-} || -z ${DECODE_GPU:-} ) ]] && die "Profile $name: set PREFILL_GPU and DECODE_GPU"
  return 0
}
__P_EOF__
cat > 'p0_build_nixl.sh' <<'__P_EOF__'
#!/usr/bin/env bash
# Build apertus15-dynamo-nixl (needed by C07, C08, C08b) and prove NIXL initialises on a GPU.
source "$(dirname "$0")/common.sh"
docker image inspect apertus15-dynamo >/dev/null 2>&1 || die "Base image apertus15-dynamo missing — run ./01_build.sh first"
log "Building apertus15-dynamo-nixl"
docker build -f Dockerfile.nixl --build-arg BASE=apertus15-dynamo -t apertus15-dynamo-nixl .
docker run --rm apertus15-dynamo-nixl bash -c 'diff /opt/pip_before_nixl.txt /opt/pip_after_nixl.txt || true' > "$RESULTS/pip_diff_nixl.txt"
ok "package changes -> results/pip_diff_nixl.txt (expected: only nixl, nixl-cu13)"
G=${1:-$GPU_A}
(( $(gpu_mem_pct "$G") < 10 )) || die "GPU $G busy — the GPU runtime check needs a free GPU (pass another index: ./p0_build_nixl.sh 1)"
log "Runtime check on GPU $G"
docker run --rm --gpus "\"device=$G\"" --network host apertus15-dynamo-nixl python -c \
  "from nixl._api import nixl_agent, nixl_agent_config; nixl_agent('probe', nixl_agent_config(backends=['UCX'])); print('NIXL agent with UCX backend: OK')" \
  || die "NIXL could not initialise on GPU $G — C08 is blocked on this node (keep this output as evidence)"
ok "apertus15-dynamo-nixl ready"
__P_EOF__
cat > 'p1_up.sh' <<'__P_EOF__'
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
prompt = " ".join(f"word{i % 997}" for i in range(3000)) + "\nSummarise the text above in one sentence."
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
__P_EOF__
cat > 'p2_bench.sh' <<'__P_EOF__'
#!/usr/bin/env bash
# Benchmark the deployed profile with the four P3/P4 workloads.   ./p2_bench.sh C06[:seqs=128]
source "$(dirname "$0")/profile_lib.sh"
load_profile "${1:?usage: p2_bench.sh PROFILE[:seqs=N]}"
[[ -f "$RESULTS/$TAG/profile.json" ]] || die "Deploy first: ./p1_up.sh $1"
TOKENIZER=swiss-ai/Apertus-v1.5-8B        # identical tokenizer to the FP8 checkpoint; already cached
[[ -f "$RESULTS/.bench_env" ]] && { source "$RESULTS/.bench_env"; }
GOODPUT="time_to_first_token:$SLO_TTFT_MS inter_token_latency:$SLO_ITL_MS"
curl -sf "http://localhost:$FE_PORT/v1/models" >/dev/null || die "No server on :$FE_PORT — run ./p1_up.sh $1"

run_aiperf() {  # outdir, then workload-specific args
  local out=$1; shift
  if [[ ${CLIENT:-docker} == local ]]; then     # used only for offline testing of this script
    aiperf profile "$@" --artifact-dir "$RESULTS/$out" > "$RESULTS/$out/aiperf_stdout.txt" 2>&1
  else
    docker run --rm --network host -e HF_TOKEN -v "$HF_CACHE:/root/.cache/huggingface" -v "$RESULTS:/results" "$CLIENT_IMAGE" \
      aiperf profile "$@" --artifact-dir "/results/$out" > "$RESULTS/$out/aiperf_stdout.txt" 2>&1
  fi
}

for WL in $WORKLOADS; do
  for C in $CONCURRENCIES; do
    OUT="$TAG/$WL/c$C"; mkdir -p "$RESULTS/$OUT"
    COMMON=(--model "$MODEL" --tokenizer "$TOKENIZER" --url "http://localhost:$FE_PORT" --endpoint-type chat --streaming
            --output-tokens-mean 256 --output-tokens-stddev 0 --extra-inputs ignore_eos:true
            --synthetic-input-tokens-stddev 0 --concurrency "$C" --random-seed 42 --ui-type none --goodput "$GOODPUT")
    N=$(( C*4 > 64 ? C*4 : 64 ))
    case $WL in
      chat)       ARGS=(--synthetic-input-tokens-mean 512  --request-count "$N" --warmup-request-count "$C"); DESCW="512 in / 256 out" ;;
      rag)        ARGS=(--synthetic-input-tokens-mean 1024 --shared-system-prompt-length 3072 --request-count "$N" --warmup-request-count "$C")
                  DESCW="3072 shared + 1024 unique = 4096 in / 256 out" ;;
      multiturn)  S=$(( C > 8 ? C : 8 ))
                  ARGS=(--synthetic-input-tokens-mean 512 --conversation-num "$S" --conversation-turn-mean 6 --conversation-turn-stddev 0
                        --conversation-turn-delay-mean 0 --request-count $((S*6)))
                  DESCW="$S sessions x 6 turns, +512 in per turn (history resent), 256 out" ;;
      longprompt) ARGS=(--synthetic-input-tokens-mean 6500 --request-count "$N" --warmup-request-count "$C"); DESCW="6500 in / 256 out" ;;
      *) die "Unknown workload $WL" ;;
    esac
    log "$TAG | $WL ($DESCW) | concurrency $C"
    if run_aiperf "$OUT" "${COMMON[@]}" "${ARGS[@]}" && [[ -f "$RESULTS/$OUT/profile_export_aiperf.json" ]]; then :
    else
      warn "aiperf failed for $OUT — see results/$OUT/aiperf_stdout.txt"
      curl -sf "http://localhost:$FE_PORT/v1/models" >/dev/null || die "Server on :$FE_PORT stopped responding during $OUT"
    fi
  done
done
ok "$TAG benchmark done"
__P_EOF__
cat > 'p3_down.sh' <<'__P_EOF__'
#!/usr/bin/env bash
# Remove ONLY this toolkit's profile containers (apx-*) and its private etcd/NATS.
source "$(dirname "$0")/common.sh"
ids=$(docker ps -aq --filter name='^apx-'); [[ -n $ids ]] && docker rm -f $ids >/dev/null
docker rm -f apertus-etcd apertus-nats >/dev/null 2>&1 || true
ok "profile containers removed"
__P_EOF__
cat > 'p4_tokenomics.py' <<'__P_EOF__'
#!/usr/bin/env python3
"""Tokenomics + phase-gate report for the P3/P4 profiles.

usage:  GPU_PRICE_PER_HOUR=<price of ONE GPU per hour> [CURRENCY=USD] ./p4_tokenomics.py [results_dir]

Rules (fixed before measuring, read from profiles/common.env):
  * a request is GOOD if TTFT <= SLO_TTFT_MS and its mean inter-token latency <= SLO_ITL_MS (AIPerf --goodput)
  * a concurrency level QUALIFIES if >= GOOD_FRACTION of its requests are good
  * capacity  = the highest useful output tokens/s among qualifying levels
  * cost      = GPU-seconds per 1M useful output tokens (price-free)  -> x price/3600 = cost per 1M tokens
  * P3 winner = lowest geometric-mean cost across all workloads (per GPU-hour, so 1 vs 2 GPUs is fair)
"""
import glob, json, math, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RES = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "results")

def env_file(path):
    out = {}
    for line in open(path):
        m = re.match(r'\s*([A-Z_0-9]+)=("?)([^"#\n]*)\2', line)
        if m: out[m.group(1)] = m.group(3).strip()
    return out

cfg = env_file(os.path.join(ROOT, "profiles", "common.env"))
SLO_TTFT, SLO_ITL = float(cfg["SLO_TTFT_MS"]), float(cfg["SLO_ITL_MS"])
GOOD_FRACTION = float(cfg.get("GOOD_FRACTION", "0.95"))
PRICE = float(os.environ["GPU_PRICE_PER_HOUR"]) if os.environ.get("GPU_PRICE_PER_HOUR") else None
CUR = os.environ.get("CURRENCY", "USD")
WORKLOADS = ["chat", "rag", "multiturn", "longprompt"]

def m(d, tag, stat="avg"):
    v = (d.get(tag) or {}).get(stat)
    return float(v) if v is not None else None

# ---------- load every run ----------
profiles, runs = {}, []
for pj in glob.glob(os.path.join(RES, "*", "profile.json")):
    p = json.load(open(pj)); profiles[p["tag"]] = p
    for f in glob.glob(os.path.join(os.path.dirname(pj), "*", "c*", "profile_export_aiperf.json")):
        wl, c = f.split(os.sep)[-3], int(f.split(os.sep)[-2][1:])
        d = json.load(open(f))
        req, good, tok = m(d, "request_throughput"), m(d, "goodput"), m(d, "output_token_throughput")
        if not req or tok is None: continue
        frac = min(1.0, (good or 0.0) / req)
        runs.append(dict(tag=p["tag"], wl=wl, c=c, n_gpus=p["n_gpus"], req=req, good_req=good or 0.0, frac=frac,
                         tok=tok, useful=tok * frac, ttft95=m(d, "time_to_first_token", "p95"),
                         itl95=m(d, "inter_token_latency", "p95"), itl99=m(d, "inter_token_latency", "p99"),
                         isl=m(d, "input_sequence_length"), osl=m(d, "output_sequence_length")))
if not runs: sys.exit(f"No profile results under {RES} (expected <tag>/profile.json and <tag>/<workload>/c<N>/profile_export_aiperf.json)")

def best(tag, wl):
    q = [r for r in runs if r["tag"] == tag and r["wl"] == wl and r["frac"] >= GOOD_FRACTION and r["useful"] > 0]
    return max(q, key=lambda r: r["useful"]) if q else None

def gpu_s_per_m(r): return r["n_gpus"] * 1e6 / r["useful"]
def fmt(x, n=0): return "-" if x is None else f"{x:,.{n}f}"
def order(tag): return (re.sub(r"-.*", "", tag), tag)

tags = sorted({r["tag"] for r in runs}, key=order)
L = [f"# Tokenomics — Apertus v1.5 8B (FP8) on Dynamo\n",
     f"Good request: TTFT ≤ {SLO_TTFT:.0f} ms and mean ITL ≤ {SLO_ITL:.0f} ms. A load level counts only if ≥ {GOOD_FRACTION:.0%} of requests are good.  ",
     f"Cost basis: {'%s %.2f per GPU-hour' % (CUR, PRICE) if PRICE else 'GPU-seconds per 1M tokens (set GPU_PRICE_PER_HOUR for money)'}.\n"]

# ---------- capacity & cost per workload ----------
for wl in WORKLOADS:
    rows = [(t, best(t, wl)) for t in tags if any(r["tag"] == t and r["wl"] == wl for r in runs)]
    if not rows: continue
    L += [f"\n## {wl}\n", f"| config | GPUs | best load in SLO | useful tok/s | tok/s per GPU | TTFT p95 ms | ITL p99 ms | GPU-s per 1M tok | {CUR} per 1M tok |",
          "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for t, b in rows:
        n = profiles[t]["n_gpus"]
        if b is None:
            L.append(f"| {t} | {n} | none within SLO | - | - | - | - | - | - |"); continue
        g = gpu_s_per_m(b)
        L.append(f"| {t} | {n} | {b['c']} | {fmt(b['useful'])} | {fmt(b['useful']/n)} | {fmt(b['ttft95'])} | {fmt(b['itl99'],1)} | "
                 f"{fmt(g)} | {fmt(g/3600*PRICE,3) if PRICE else '-'} |")

# ---------- P3 gate ----------
def score(tag):
    vals = [best(tag, wl) for wl in WORKLOADS]
    if any(v is None for v in vals): return None
    return math.exp(sum(math.log(gpu_s_per_m(v)) for v in vals) / len(vals))
p3 = [t for t in tags if profiles[t].get("phase") == "P3"]
if p3:
    L += ["\n## Phase-3 gate (lowest cost per GPU-hour wins)\n", "| config | GPUs | geo-mean GPU-s per 1M tok (all 4 workloads) | relative |", "|---|---:|---:|---:|"]
    scored = sorted([(score(t), t) for t in p3 if score(t) is not None])
    for s, t in scored:
        L.append(f"| {t} | {profiles[t]['n_gpus']} | {fmt(s)} | {s/scored[0][0]:.2f}x |")
    missing = [t for t in p3 if score(t) is None]
    if missing: L.append(f"\nNot scored (a workload had no load level within SLO, or is missing): {', '.join(missing)}")
    if scored:
        w = profiles[scored[0][1]]
        router = w.get("router") or "kv"
        L += [f"\n**Winner: {w['tag']}** — {w['desc']}\n",
              "Carry forward into `profiles/p3_winner.env`:\n", "```", f"P3_WINNER={w['tag']}", f"P3_ROUTER={router}", f"P3_MAX_NUM_SEQS={w['max_num_seqs']}", "```"]
        if w["kind"] == "vllm":
            L.append("\n(Winner is standalone vLLM. C07/C08 still need Dynamo on 2 GPUs; they inherit its batch size, router defaults to kv.)")

# ---------- P4: disaggregation vs same-session control ----------
p4 = [t for t in tags if profiles[t].get("phase") == "P4"]
if p4:
    L += ["\n## Phase-4: disaggregated vs aggregated control (same load levels)\n"]
    for wl in WORKLOADS:
        cs = sorted({r["c"] for r in runs if r["wl"] == wl and r["tag"] in p4})
        if not cs: continue
        L += [f"\n**{wl}** — useful tok/s · TTFT p95 ms · ITL p99 ms\n", "| load | " + " | ".join(p4) + " |", "|---:|" + "---:|" * len(p4)]
        for c in cs:
            cells = []
            for t in p4:
                r = next((x for x in runs if x["tag"] == t and x["wl"] == wl and x["c"] == c), None)
                cells.append("-" if r is None else f"{fmt(r['useful'])} · {fmt(r['ttft95'])} · {fmt(r['itl99'],1)}")
            L.append(f"| {c} | " + " | ".join(cells) + " |")

# ---------- cloud comparison (only with verified prices) ----------
cp = os.path.join(ROOT, "cloud_prices.json")
if PRICE and os.path.exists(cp):
    apis = [a for a in json.load(open(cp)).get("apis", []) if a.get("verified") and a.get("input_per_1m") is not None]
    if apis:
        L += [f"\n## Self-hosted vs cloud APIs — cost per 1,000 requests ({CUR})\n",
              "| workload | best self-hosted config | self-hosted | " + " | ".join(a["name"] for a in apis) + " |",
              "|---|---|---:|" + "---:|" * len(apis)]
        for wl in WORKLOADS:
            cands = [(t, best(t, wl)) for t in tags]; cands = [(t, b) for t, b in cands if b and b["good_req"] > 0]
            if not cands: continue
            t, b = min(cands, key=lambda x: x[1]["n_gpus"] / x[1]["good_req"])
            self_cost = b["n_gpus"] * PRICE / 3600 / b["good_req"] * 1000
            api = [(b["isl"] * a["input_per_1m"] + b["osl"] * a["output_per_1m"]) / 1e6 * 1000 for a in apis]
            L.append(f"| {wl} | {t} | {self_cost:,.3f} | " + " | ".join(f"{x:,.3f}" for x in api) + " |")
        L.append("\nSelf-hosted assumes the GPUs are fully used at that load; at lower utilisation divide by the utilisation fraction.")
    else:
        L.append("\n(cloud_prices.json has no entries marked \"verified\": true — no cloud comparison printed.)")

with open(os.path.join(RES, "all_runs.csv"), "w") as fh:
    keys = list(runs[0]); fh.write(",".join(keys) + "\n")
    for r in sorted(runs, key=lambda r: (order(r["tag"]), r["wl"], r["c"])): fh.write(",".join(str(r[k]) for k in keys) + "\n")
open(os.path.join(RES, "tokenomics.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
__P_EOF__
cat > 'run_profiles.sh' <<'__P_EOF__'
#!/usr/bin/env bash
# Deploy -> verify -> benchmark -> tear down, for each profile in order; then the tokenomics report.
#   ./run_profiles.sh C04R C05 C06            (Phase 3)
#   ./run_profiles.sh C06:seqs=128 C06:seqs=256   (batch sweep on the P3 winner)
#   ./run_profiles.sh C07 C08 C08b            (Phase 4, back to back = same session)
source "$(dirname "$0")/profile_lib.sh"
(( $# )) || die "usage: ./run_profiles.sh PROFILE [PROFILE ...]   e.g. C04R C05 C06"
for spec in "$@"; do load_profile "$spec"; done          # validate every spec before starting anything
D="$(dirname "$0")"
for spec in "$@"; do
  "$D/p1_up.sh" "$spec"
  "$D/p2_bench.sh" "$spec"
  "$D/p3_down.sh"
done
log "Tokenomics report"
"$D/p4_tokenomics.py" "$RESULTS" | tail -40
tar czf "$ROOT/profiles_results_$(date +%Y%m%d_%H%M).tgz" -C "$(dirname "$RESULTS")" "$(basename "$RESULTS")"
log "Done — full report: results/tokenomics.md · raw: results/all_runs.csv · archive: profiles_results_*.tgz (copy it off the box)"
__P_EOF__
cat > 'Dockerfile.nixl' <<'__P_EOF__'
# apertus15-dynamo + NIXL (KV-cache transfer between GPUs) for disaggregated serving (C07/C08/C08b).
# nixl==1.3.0 matches the Swiss AI fork's own requirements (requirements/kv_connectors.txt).
# nixl is a thin wrapper; nixl-cu13 is the CUDA-13 library matching the fork's torch (cu130).
# --no-deps: the plain "nixl" package would otherwise also pull the CUDA-12 variant.
ARG BASE=apertus15-dynamo
FROM ${BASE}
RUN pip freeze > /opt/pip_before_nixl.txt
RUN pip install --no-cache-dir --no-deps "nixl==1.3.0" "nixl-cu13==1.3.0"
RUN pip freeze > /opt/pip_after_nixl.txt
# Same fork/Dynamo API gate as the base image (proves vLLM + Dynamo are untouched)
RUN python /opt/check_fork.py
RUN python -c "import importlib.util as u; \
assert u.find_spec('nixl') and u.find_spec('nixl_cu13'), 'nixl packages missing'; \
assert u.find_spec('vllm.distributed.kv_transfer.kv_connector.v1.nixl'), 'vLLM NixlConnector missing'; \
print('NIXL 1.3.0 (cu13) installed; vLLM NixlConnector present')"
ENTRYPOINT []
__P_EOF__
cat > 'PROFILES.md' <<'__P_EOF__'
# C05–C08 profiles — Apertus v1.5 8B FP8 on Dynamo

All profiles share the frozen C04 inference settings (`profiles/common.env`): FP8 weights, FP8 KV cache,
8192 context, 0.80 GPU memory, 8192 batched tokens, 64 sequences, chunked prefill, prefix caching.
Each profile changes only what its row says.

| Profile | Phase | What runs | Changes vs previous |
|---|---|---|---|
| C04R | P3 | standalone vLLM (Swiss AI fork), GPU0 | C04 re-measured with the P3/P4 workloads |
| C05  | P3 | Dynamo frontend + 1 worker, GPU0 | serving layer only |
| C06  | P3 | Dynamo, 2 workers (GPU0+GPU1), KV router | scale-out + routing |
| gate | P3→P4 | lowest cost per GPU-hour wins; sweep `max-num-seqs` on the winner | decides router + batch size |
| C07  | P4 | winner settings, 2 aggregated workers, NIXL image | same-session control |
| C08  | P4 | GPU0 = prefill, GPU1 = decode, NIXL KV transfer | disaggregation only |
| C08b | P4 | C08 + prefill 16384 batched tokens, decode 2x sequences | per-role tuning |

Workloads (identical for all): chat 512/256 · rag 3072 shared + 1024 unique = 4096 in / 256 · multiturn 6 turns,
history resent (up to ~4.4k in) · longprompt 6500/256. Load levels: 1 8 32 64 128.
A request is *good* if TTFT ≤ 2000 ms and mean ITL ≤ 50 ms; a load level counts if ≥ 95 % of requests are good.

## Run order (≈ 30 min per profile)
```bash
# 0. the kit's run_all.sh must have finished ("Done" in run.log); copy its results_*.tgz off the box
./run_profiles.sh C04R C05 C06                               # Phase 3
GPU_PRICE_PER_HOUR=<price of ONE GPU per hour> ./p4_tokenomics.py   # gate: prints the winner
./run_profiles.sh <winner>:seqs=128 <winner>:seqs=256        # batch sweep on the winner
GPU_PRICE_PER_HOUR=<same> ./p4_tokenomics.py                 # final winner incl. batch size
nano profiles/p3_winner.env                                  # paste the two printed lines
./p0_build_nixl.sh                                           # NIXL image for C07/C08 (+ GPU check)
./run_profiles.sh C07 C08 C08b                               # Phase 4, back to back
GPU_PRICE_PER_HOUR=<same> ./p4_tokenomics.py                 # full report -> results/tokenomics.md
```
Short on time: fewer load levels per profile, e.g. `./run_profiles.sh C05:conc=8+32+64`.
Single steps: `./p1_up.sh C06` (deploy + verify) · `./p2_bench.sh C06` · `./p3_down.sh`.

## Built-in checks (stop with a clear [FAIL] instead of producing bad numbers)
- GPUs free, ports free, image present, kit not running; every profile spec validated before starting.
- Ready = model registered + every GPU holds an engine + every worker healthy + correct answer + all containers alive.
- C08/C08b: NIXL must initialise on the GPU first; afterwards the prefill GPU must actually work under long prompts.
- `results/<profile>/profile.json` records exactly what ran (settings, image, vLLM + Dynamo versions).

## Cost and cloud comparison
`GPU_PRICE_PER_HOUR` = what ONE H100 NVL costs you per hour (state your source in the deck).
Without it the report uses GPU-seconds per 1M tokens (same ranking). For the cloud comparison, fill
`cloud_prices.json` with real list prices and set `"verified": true`; unverified entries are ignored.

## Note on the earlier kit results
The kit's `rag` workload was labelled "ISL 4096" but sent 4096 unique + 3072 shared = 7168 input tokens.
Its numbers are valid for 7168 tokens. The profiles above use a true 4096-token RAG prompt.
__P_EOF__
cat > 'profiles/common.env' <<'__P_EOF__'
# Shared settings for ALL Phase-3/4 profiles = the frozen C04 inference configuration.
# Change nothing here between profiles; a profile file changes only what its row in the plan says.
MODEL=onprem-ai/Apertus-v1.5-8B-FP8
KV_DTYPE=fp8
MAX_MODEL_LEN=8192
GPU_MEM_UTIL=0.80
MAX_NUM_BATCHED_TOKENS=8192
MAX_NUM_SEQS=64
IMAGE=apertus15-dynamo
ROUTER=kv
FE_PORT=8000                 # Dynamo frontend (or standalone vLLM) API
SYS_PORT_BASE=8001           # worker health/metrics: 8001, 8002
KV_EVENT_PORT_BASE=5567      # KV-cache event streams: 5567, 5568
NIXL_PORT_BASE=5600          # NIXL side channels (disaggregated only): 5600, 5601
# Benchmark matrix (identical for every profile)
WORKLOADS="chat rag multiturn longprompt"
CONCURRENCIES="1 8 32 64 128"
SLO_TTFT_MS=2000             # a request is "good" only if TTFT <= this ...
SLO_ITL_MS=50                # ... and its average inter-token latency <= this
GOOD_FRACTION=0.95           # a concurrency level counts only if >= 95% of requests are good
__P_EOF__
cat > 'profiles/C04R.env' <<'__P_EOF__'
DESC="C04 re-measured with the P3/P4 workloads: standalone vLLM (Swiss AI fork), FP8 weights + FP8 KV, GPU0"
PHASE=P3
KIND=vllm
GPUS="0"
__P_EOF__
cat > 'profiles/C05.env' <<'__P_EOF__'
DESC="C04 settings + Dynamo frontend + 1 aggregated worker, GPU0 (same GPU as C04)"
PHASE=P3
KIND=dynamo-agg
GPUS="0"
__P_EOF__
cat > 'profiles/C06.env' <<'__P_EOF__'
DESC="C04 settings + 2 aggregated Dynamo workers (GPU0+GPU1), KV-aware router"
PHASE=P3
KIND=dynamo-agg
GPUS="0 1"
ROUTER=kv
__P_EOF__
cat > 'profiles/C07.env' <<'__P_EOF__'
DESC="P4 control: Phase-3 winner settings, 2 aggregated Dynamo workers, same image + session as C08"
PHASE=P4
KIND=dynamo-agg
GPUS="0 1"
ROUTER=$P3_ROUTER
MAX_NUM_SEQS=$P3_MAX_NUM_SEQS
IMAGE=apertus15-dynamo-nixl      # identical image to C08 -> only disaggregation differs
__P_EOF__
cat > 'profiles/C08.env' <<'__P_EOF__'
DESC="P4: identical to C07 except disaggregated: GPU0 = prefill, GPU1 = decode, NIXL KV transfer"
PHASE=P4
KIND=dynamo-disagg
GPUS="0 1"
PREFILL_GPU=0
DECODE_GPU=1
ROUTER=$P3_ROUTER
MAX_NUM_SEQS=$P3_MAX_NUM_SEQS
IMAGE=apertus15-dynamo-nixl
__P_EOF__
cat > 'profiles/C08b.env' <<'__P_EOF__'
DESC="P4 extra: C08 with role-tuned workers (prefill: 2x batched tokens, decode: 2x sequences)"
PHASE=P4
KIND=dynamo-disagg
GPUS="0 1"
PREFILL_GPU=0
DECODE_GPU=1
ROUTER=$P3_ROUTER
MAX_NUM_SEQS=$P3_MAX_NUM_SEQS
PREFILL_MAX_NUM_BATCHED_TOKENS=16384                 # prefill: bigger prompt chunks per step
DECODE_MAX_NUM_SEQS=$((P3_MAX_NUM_SEQS * 2))       # decode: more concurrent generations
IMAGE=apertus15-dynamo-nixl
__P_EOF__
if [ ! -f 'profiles/p3_winner.env' ]; then cat > 'profiles/p3_winner.env' <<'__P_EOF__'
# Phase-3 decisions inherited by C07 / C08 / C08b.
# Fill these in AFTER the P3 gate: ./p4_tokenomics.py prints the recommended values.
P3_ROUTER=kv
P3_MAX_NUM_SEQS=64
P3_WINNER=            # C05 or C06, set after the gate. C07/C08 refuse to run while empty.
__P_EOF__
fi
if [ ! -f 'cloud_prices.json' ]; then cat > 'cloud_prices.json' <<'__P_EOF__'
{
  "_note": "Fill in real list prices (per 1M tokens, same currency as GPU_PRICE_PER_HOUR) and set verified=true. Unverified entries are ignored.",
  "apis": [
    {"name": "Cloud API A (e.g. hosted Apertus / similar 8B)", "input_per_1m": null, "output_per_1m": null, "source": "", "verified": false},
    {"name": "Cloud API B (frontier model)",                  "input_per_1m": null, "output_per_1m": null, "source": "", "verified": false}
  ]
}
__P_EOF__
fi
grep -q '^P3_WINNER=' profiles/p3_winner.env || printf 'P3_WINNER=            # C05 or C06, set after the gate. C07/C08 refuse to run while empty.\n' >> profiles/p3_winner.env
chmod +x profile_lib.sh p0_build_nixl.sh p1_up.sh p2_bench.sh p3_down.sh p4_tokenomics.py run_profiles.sh
for f in p0_build_nixl.sh p1_up.sh p2_bench.sh p3_down.sh profile_lib.sh run_profiles.sh; do bash -n "$f" || echo "SYNTAX PROBLEM in $f"; done
python3 -m py_compile p4_tokenomics.py && echo "OK  profile toolkit installed (read PROFILES.md)"
