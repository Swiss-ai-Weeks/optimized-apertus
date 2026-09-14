#!/usr/bin/env bash
# ============================================================================
# Apertus serving constructor - one entrypoint for any benchmark configuration.
#
#   launch.sh single  <model_id> <gpu> <port> [bf16|fp8]
#   launch.sh specdec <target_id> <draft_id> <port> [nspec=5]   # draft->target, TP=2
#
# Engine auto-selected by model id:
#   *v1.5*  -> swiss-ai release image (multimodal apertus1p5), via `vllm serve`
#   else    -> NIM vLLM (vllm-model-free-nim:2.1.1)
# Spec-decode: draft & target MUST share a tokenizer family (both -2509, or both v1.5).
# Cross-family (2509 x v1.5) is invalid. v1.5 spec-decode is experimental (multimodal).
# ============================================================================
set -euo pipefail
NIM_IMG=nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1
V15_IMG=ghcr.io/swiss-ai/vllm_apertus_1.5_release:latest-amd64
CACHE=$HOME/.cache/nim
img_for(){ case "$1" in *v1.5*|*V1.5*) echo "$V15_IMG";; *) echo "$NIM_IMG";; esac; }
slug(){ echo "$1" | tr '/' '-' | tr '[:upper:]' '[:lower:]'; }
mode=${1:?mode: single|specdec}; shift
case "$mode" in
single)
  MODEL=${1:?model_id}; GPU=${2:?gpu}; PORT=${3:?port}; QUANT=${4:-bf16}
  IMG=$(img_for "$MODEL"); NAME=apr-$(slug "$MODEL")-$PORT
  PASS="--gpu-memory-utilization 0.9 --max-model-len 8192"
  [ "$QUANT" = fp8 ] && PASS="$PASS --quantization fp8"
  docker rm -f "$NAME" 2>/dev/null || true
  if [ "$IMG" = "$V15_IMG" ]; then
    docker run -d --name "$NAME" --restart unless-stopped --device nvidia.com/gpu=$GPU --shm-size=16g \
      -e HF_HUB_OFFLINE=1 -e HF_HOME=/opt/nim/.cache/huggingface -v $CACHE:/opt/nim/.cache -p $PORT:8000 \
      --entrypoint vllm "$IMG" serve "$MODEL" --served-model-name "$MODEL" --host 0.0.0.0 --port 8000 $PASS --trust-remote-code
  else
    docker run -d --name "$NAME" --restart unless-stopped --device nvidia.com/gpu=$GPU --shm-size=16g \
      -e NIM_MODEL_PATH=hf://$MODEL -e NIM_SERVED_MODEL_NAME="$MODEL" -e HF_HUB_OFFLINE=1 \
      -e NIM_PASSTHROUGH_ARGS="$PASS" -v $CACHE:/opt/nim/.cache -p $PORT:8000 "$IMG"
  fi
  echo "[single] $NAME :$PORT gpu=$GPU quant=$QUANT img=${IMG##*/}" ;;
specdec)
  TARGET=${1:?target_id}; DRAFT=${2:?draft_id}; PORT=${3:?port}; NSPEC=${4:-5}
  IMG=$(img_for "$TARGET"); NAME=specdec-$PORT
  SPEC="{\"model\":\"$DRAFT\",\"num_speculative_tokens\":$NSPEC}"
  docker rm -f "$NAME" 2>/dev/null || true
  if [ "$IMG" = "$V15_IMG" ]; then
    docker run -d --name "$NAME" --restart no --device nvidia.com/gpu=0 --device nvidia.com/gpu=1 --shm-size=32g \
      -e HF_HUB_OFFLINE=1 -e HF_HOME=/opt/nim/.cache/huggingface -v $CACHE:/opt/nim/.cache -p $PORT:8000 \
      --entrypoint vllm "$IMG" serve "$TARGET" --served-model-name specdec --host 0.0.0.0 --port 8000 \
      --tensor-parallel-size 2 --gpu-memory-utilization 0.9 --max-model-len 8192 --trust-remote-code --speculative-config "$SPEC"
  else
    ENVF=$HOME/.specdec_$PORT.env
    { echo "NIM_MODEL_PATH=hf://$TARGET"; echo "NIM_SERVED_MODEL_NAME=specdec"; echo "HF_HUB_OFFLINE=1"; \
      echo "NIM_PASSTHROUGH_ARGS=--tensor-parallel-size 2 --quantization fp8 --gpu-memory-utilization 0.9 --speculative-config '$SPEC'"; } > "$ENVF"
    docker run -d --name "$NAME" --restart no --device nvidia.com/gpu=0 --device nvidia.com/gpu=1 --shm-size=32g \
      --env-file "$ENVF" -v $CACHE:/opt/nim/.cache -p $PORT:8000 "$IMG"
  fi
  echo "[specdec] $NAME :$PORT target=$TARGET draft=$DRAFT nspec=$NSPEC img=${IMG##*/}" ;;
*) echo "usage: launch.sh single|specdec ..."; exit 1 ;;
esac
