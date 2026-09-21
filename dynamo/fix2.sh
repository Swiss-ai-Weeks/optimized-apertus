cd ~/apertus-dynamo-bench
set +H
pkill -f run_all.sh 2>/dev/null; docker rm -f apertus-srv apertus-etcd apertus-nats >/dev/null 2>&1; sleep 2
cat > 'Dockerfile.dynamo' <<'__FIX_EOF__'
# Dynamo runtime installed INTO the Swiss AI vLLM fork (the only vLLM that knows apertus1p5).
# DYNAMO_VERSION must match the fork's vLLM base (fork = vLLM 0.23.x -> ai-dynamo 1.3.1, which pins vllm 0.23.0).
ARG FORK_IMAGE=ghcr.io/swiss-ai/vllm_apertus_1.5_release:latest-amd64
FROM ${FORK_IMAGE}
ARG DYNAMO_VERSION=1.3.1
RUN pip freeze > /opt/pip_before.txt
# No [vllm] extra -> must not replace the forked vLLM
RUN pip install --no-cache-dir "ai-dynamo==${DYNAMO_VERSION}"
RUN pip freeze > /opt/pip_after.txt
COPY check_fork.py /opt/check_fork.py
# Fails on purpose if the fork got overwritten OR Dynamo imports vLLM symbols the fork lacks.
RUN python /opt/check_fork.py
ENTRYPOINT []
__FIX_EOF__
cat > 'check_fork.py' <<'__FIX_EOF__'
"""Build-time gate.
1) The Swiss AI vLLM fork must still register the Apertus 1.5 architecture.
2) Every UNGUARDED `from vllm... import X` in Dynamo's vLLM backend/frontend must resolve
   against THIS vLLM (catches Dynamo<->fork API mismatches that only show up on the first request).
"""
import ast, importlib, os, sys

def unguarded_vllm_imports(root):
    """Yield (file, lineno, module, name) for vllm imports not inside try/except or TYPE_CHECKING."""
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".py"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                tree = ast.parse(open(path, encoding="utf-8").read())
            except SyntaxError:
                continue
            def walk(node, guarded):
                for child in ast.iter_child_nodes(node):
                    g = guarded
                    if isinstance(child, ast.Try):
                        g = True
                    if isinstance(child, ast.If) and "TYPE_CHECKING" in ast.dump(child.test):
                        g = True
                    if (isinstance(child, ast.ImportFrom) and not g and child.module
                            and (child.module == "vllm" or child.module.startswith("vllm."))):
                        for a in child.names:
                            yield path, child.lineno, child.module, a.name
                    yield from walk(child, g)
            yield from walk(tree, False)

def check(root, resolve):
    missing, unverifiable = [], []
    for path, line, mod, name in unguarded_vllm_imports(root):
        status = resolve(mod, name)
        rel = os.path.relpath(path, root)
        if status == "missing":
            missing.append(f"{rel}:{line}  from {mod} import {name}")
        elif status != "ok":
            unverifiable.append(f"{rel}:{line}  {mod}.{name}  ({status})")
    return missing, unverifiable

def real_resolve(mod, name):
    try:
        m = importlib.import_module(mod)
    except ModuleNotFoundError as e:
        return "missing" if (e.name or "").startswith("vllm") else f"dep:{e.name}"
    except Exception as e:  # needs GPU/driver or optional deps at import time
        return f"import-error:{type(e).__name__}"
    if name == "*" or hasattr(m, name):
        return "ok"
    try:
        importlib.import_module(f"{mod}.{name}")
        return "ok"
    except Exception:
        return "missing"

if __name__ == "__main__":
    import vllm, torch
    from vllm import ModelRegistry
    archs = [a for a in ModelRegistry.get_supported_archs() if "pertus" in a.lower()]
    print("vllm", vllm.__version__, "| torch", torch.__version__, "| apertus archs:", archs)
    assert any(a != "ApertusForCausalLM" for a in archs), "Apertus 1.5 arch missing -> fork vLLM was overwritten"
    import dynamo, dynamo.vllm, dynamo.frontend  # noqa: F401
    base = os.path.dirname(dynamo.__file__)
    all_missing = []
    for sub in ("vllm", "frontend"):
        missing, unverifiable = check(os.path.join(base, sub), real_resolve)
        all_missing += missing
        print(f"dynamo/{sub}: {len(missing)} missing vLLM symbols, {len(unverifiable)} unverifiable at build time")
        for u in unverifiable[:5]:
            print("   (unverifiable)", u)
    if all_missing:
        print("\nDynamo expects vLLM symbols this fork does not have:")
        print("\n".join("   " + m for m in all_missing[:30]))
        sys.exit("FAIL: Dynamo version incompatible with the Swiss AI vLLM fork -> pin an older ai-dynamo")
    print("dynamo <-> fork vLLM API check OK")
__FIX_EOF__
cat > '01_build.sh' <<'__FIX_EOF__'
#!/usr/bin/env bash
# Pull fork, build Dynamo-on-fork + client images, download weights, detect client capabilities.
source "$(dirname "$0")/common.sh"

log "Pulling Swiss AI vLLM fork image"
docker pull "$FORK_IMAGE"

log "Building $DYN_IMAGE (Dynamo on top of the fork; verifies the fork survives)"
docker build -f Dockerfile.dynamo --build-arg FORK_IMAGE="$FORK_IMAGE" --build-arg DYNAMO_VERSION="${DYNAMO_VERSION:-1.3.1}" -t "$DYN_IMAGE" .
docker run --rm "$DYN_IMAGE" bash -c 'diff /opt/pip_before.txt /opt/pip_after.txt || true' \
  > "$RESULTS/pip_diff_dynamo_install.txt"
ok "package changes from Dynamo install -> results/pip_diff_dynamo_install.txt"

log "Building $CLIENT_IMAGE (AIPerf)"
docker build -f Dockerfile.client -t "$CLIENT_IMAGE" .

log "Downloading weights into $HF_CACHE"
docker run --rm -e HF_TOKEN -v "$HF_CACHE:/root/.cache/huggingface" --entrypoint hf \
  "$FORK_IMAGE" download "$MODEL" >/dev/null
ok "weights cached"

log "Detecting AIPerf options and tokenizer"
HELP=$(docker run --rm -e COLUMNS=400 "$CLIENT_IMAGE" aiperf profile --help 2>&1 | sed "s/\x1b\[[0-9;]*m//g" || true)
for f in --tokenizer --url --endpoint-type --streaming --synthetic-input-tokens-mean --output-tokens-mean \
         --concurrency --request-count --warmup-request-count --random-seed --artifact-dir --extra-inputs; do
  grep -q -- "$f" <<<"$HELP" || die "Installed aiperf lacks $f — check 'aiperf profile --help'"
done
PREFIX_ARGS=""
if   grep -q -- "--shared-system-prompt-length" <<<"$HELP"; then PREFIX_ARGS="--shared-system-prompt-length 3072"
elif grep -q -- "--prefix-prompt-length"        <<<"$HELP"; then PREFIX_ARGS="--prefix-prompt-length 3072 --prefix-prompt-pool-size 1"
else warn "aiperf has no shared-prefix option: 'rag' runs without a shared prefix (KV-router advantage will be understated)"; fi

TOKENIZER="$MODEL"
if ! docker run --rm -e HF_TOKEN -v "$HF_CACHE:/root/.cache/huggingface" "$CLIENT_IMAGE" \
     python -c "from transformers import AutoTokenizer as T; T.from_pretrained('$MODEL')" >/dev/null 2>&1; then
  TOKENIZER="swiss-ai/Apertus-8B-Instruct-2509"
  warn "Stock transformers can't load the 1.5 tokenizer; client uses $TOKENIZER only to SIZE synthetic prompts (server-side counts unaffected)"
fi
printf 'PREFIX_ARGS="%s"\nTOKENIZER="%s"\n' "$PREFIX_ARGS" "$TOKENIZER" > "$RESULTS/.bench_env"
ok "client settings -> results/.bench_env"
log "Build complete"
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
  if [[ "$MODE" == dyn-* ]]; then
    echo "  Backend error reported by Dynamo:"
    grep -hE "Internal server error:|Traceback|Error:" "$LOGDIR/frontend.log" "$LOGDIR"/worker*.log 2>/dev/null \
      | sed -E 's/.*backend asserted status [0-9]+: //' | tail -3 | cut -c1-300 | sed 's/^/    /'
  fi
  die "Smoke test failed for $MODE — full logs in $LOGDIR (send the lines above)"
fi
nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv > "$LOGDIR/gpu_mem_at_ready.csv"
log "$MODE ready on http://localhost:$HTTP_PORT"
__FIX_EOF__
cat > '.env.example' <<'__FIX_EOF__'
# ---- copy to .env and fill in ----
HF_TOKEN=hf_xxx                      # account that ACCEPTED the Apertus 1.5 AUP on Hugging Face
MODEL=swiss-ai/Apertus-v1.5-8B

FORK_IMAGE=ghcr.io/swiss-ai/vllm_apertus_1.5_release:latest-amd64
DYN_IMAGE=apertus15-dynamo           # built by 01_build.sh
CLIENT_IMAGE=apertus-bench-client    # built by 01_build.sh
DYNAMO_VERSION=1.3.1                 # must match the fork's vLLM base (0.23.x)
HF_CACHE=$HOME/hf-cache              # needs ~40 GB free

GPU_A=0                              # worker 1 (and the single-GPU baselines)
GPU_B=1                              # worker 2
HTTP_PORT=8000

# Identical for EVERY configuration -> fair comparison
MAX_MODEL_LEN=32768
GPU_MEM_UTIL=0.80

# Keep false: the Dynamo preprocessor must tokenize so the KV router can see prefixes.
# Set true ONLY if 03_start.sh tells you the chat template fails (KV-router results then invalid).
USE_VLLM_TOKENIZER=false

# Benchmark matrix
MODES="vllm-1g dyn-1w dyn-2w-rr dyn-2w-kv"
SCENARIOS="chat rag"
CONCURRENCIES="1 2 4 8 16 32 64"
TTFT_SLO_MS=2000                     # p95 TTFT budget used to mark rows in the summary
RESULTS=./results
__FIX_EOF__
grep -q "^DYNAMO_VERSION=" .env || echo "DYNAMO_VERSION=1.3.1" >> .env
chmod +x *.sh *.py
echo "--- checks (all should say OK) ---"
grep -q "^DYNAMO_VERSION=1.3.1" .env && echo "OK  .env pins Dynamo 1.3.1" || echo "MISSING .env DYNAMO_VERSION"
grep -q 'ai-dynamo==${DYNAMO_VERSION}' Dockerfile.dynamo && echo "OK  Dockerfile uses the pin" || echo "MISSING Dockerfile pin"
grep -q 'build-arg DYNAMO_VERSION' 01_build.sh && echo "OK  build passes the pin" || echo "MISSING build arg"
grep -q 'unguarded_vllm_imports' check_fork.py && echo "OK  stronger API check" || echo "MISSING check_fork"
grep -q 'Backend error reported by Dynamo' 03_start.sh && echo "OK  real error reporting" || echo "MISSING 03_start"
