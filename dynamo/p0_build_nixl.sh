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
