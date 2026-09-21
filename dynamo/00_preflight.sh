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
