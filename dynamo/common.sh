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
