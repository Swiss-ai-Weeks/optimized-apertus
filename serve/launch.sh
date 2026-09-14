#!/usr/bin/env bash
# ============================================================================
# Apertus serving constructor - one entrypoint for any benchmark configuration.
#
#   launch.sh single  <model_id> <gpu> <port> [bf16|fp8]
#   launch.sh ngram   <model_id> <gpu> <port> [nspec=4] [bf16|fp8]   # SINGLE-model spec-decode (self, prompt-lookup)
#   launch.sh specdec <target_id> <draft_id> <port> [nspec=5]        # two-model draft->target, TP=2 (both GPUs)
#
# Engine auto-selected by model id: *v1.5* -> swiss-ai release image; else NIM vLLM.
# ngram = self-speculation, no draft model/checkpoint, ONE GPU (leaves the other free).
# specdec draft & target MUST share a tokenizer family (both -2509, or both v1.5).
# ============================================================================
set -euo pipefail
NIM_IMG=nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1
V15_IMG=ghcr.io/swiss-ai/vllm_apertus_1.5_release:latest-amd64
CACHE=$HOME/.cache/nim
img_for(){ case "$1" in *v1.5*|*V1.5*) echo "$V15_IMG";; *) echo "$NIM_IMG";; esac; }
slug(){ echo "$1" | tr '/' '-' | tr '[:upper:]' '[:lower:]'; }
# run_v15 NAME GPUS PORT EXTRA... ; run_nim NAME GPUS PORT MODEL SERVED PASS
run_v15(){ local NAME=$1 GPUS=$2 PORT=$3 MODEL=$4; shift 4
  docker run -d --name "$NAME" --restart unless-stopped $GPUS --shm-size=32g \
    -e HF_HUB_OFFLINE=1 -e HF_HOME=/opt/nim/.cache/huggingface -v $CACHE:/opt/nim/.cache -p $PORT:8000 \
    --entrypoint vllm "$V15_IMG" serve "$MODEL" --served-model-name "$MODEL" --host 0.0.0.0 --port 8000 --trust-remote-code "$@"; }
nim_envfile(){ local F=$1 MODEL=$2 SERVED=$3 PASS=$4
  { echo "NIM_MODEL_PATH=hf://$MODEL"; echo "NIM_SERVED_MODEL_NAME=$SERVED"; echo "HF_HUB_OFFLINE=1"; echo "NIM_PASSTHROUGH_ARGS=$PASS"; } > "$F"; }
mode=${1:?mode: single|ngram|specdec}; shift
case "$mode" in
single)
  MODEL=${1:?model_id}; GPU=${2:?gpu}; PORT=${3:?port}; QUANT=${4:-bf16}; NAME=apr-$(slug "$MODEL")-$PORT
  PASS="--gpu-memory-utilization 0.9 --max-model-len 8192"; [ "$QUANT" = fp8 ] && PASS="$PASS --quantization fp8"
  docker rm -f "$NAME" 2>/dev/null||true
  if [ "$(img_for "$MODEL")" = "$V15_IMG" ]; then run_v15 "$NAME" "--device nvidia.com/gpu=$GPU" "$PORT" "$MODEL" $PASS
  else F=$HOME/.$NAME.env; nim_envfile "$F" "$MODEL" "$MODEL" "$PASS"; docker run -d --name "$NAME" --restart unless-stopped --device nvidia.com/gpu=$GPU --shm-size=16g --env-file "$F" -v $CACHE:/opt/nim/.cache -p $PORT:8000 "$NIM_IMG"; fi
  echo "[single] $NAME :$PORT gpu=$GPU quant=$QUANT" ;;
ngram)
  MODEL=${1:?model_id}; GPU=${2:?gpu}; PORT=${3:?port}; NSPEC=${4:-4}; QUANT=${5:-fp8}; NAME=ngram-$PORT
  SPEC="{\"method\":\"ngram\",\"num_speculative_tokens\":$NSPEC,\"prompt_lookup_max\":4,\"prompt_lookup_min\":2}"
  PASS="--gpu-memory-utilization 0.9 --max-model-len 8192"; [ "$QUANT" = fp8 ] && PASS="$PASS --quantization fp8"
  docker rm -f "$NAME" 2>/dev/null||true
  if [ "$(img_for "$MODEL")" = "$V15_IMG" ]; then run_v15 "$NAME" "--device nvidia.com/gpu=$GPU" "$PORT" "$MODEL" $PASS --speculative-config "$SPEC"
  else F=$HOME/.$NAME.env; nim_envfile "$F" "$MODEL" ngram "$PASS --speculative-config '$SPEC'"; docker run -d --name "$NAME" --restart no --device nvidia.com/gpu=$GPU --shm-size=16g --env-file "$F" -v $CACHE:/opt/nim/.cache -p $PORT:8000 "$NIM_IMG"; fi
  echo "[ngram] $NAME :$PORT gpu=$GPU nspec=$NSPEC (single-model self-spec, no draft)" ;;
specdec)
  TARGET=${1:?target_id}; DRAFT=${2:?draft_id}; PORT=${3:?port}; NSPEC=${4:-5}; NAME=specdec-$PORT
  SPEC="{\"model\":\"$DRAFT\",\"num_speculative_tokens\":$NSPEC}"
  docker rm -f "$NAME" 2>/dev/null||true
  if [ "$(img_for "$TARGET")" = "$V15_IMG" ]; then run_v15 "$NAME" "--device nvidia.com/gpu=0 --device nvidia.com/gpu=1" "$PORT" "$TARGET" --tensor-parallel-size 2 --gpu-memory-utilization 0.9 --max-model-len 8192 --speculative-config "$SPEC"
  else F=$HOME/.$NAME.env; nim_envfile "$F" "$TARGET" specdec "--tensor-parallel-size 2 --quantization fp8 --gpu-memory-utilization 0.9 --speculative-config '$SPEC'"; docker run -d --name "$NAME" --restart no --device nvidia.com/gpu=0 --device nvidia.com/gpu=1 --shm-size=32g --env-file "$F" -v $CACHE:/opt/nim/.cache -p $PORT:8000 "$NIM_IMG"; fi
  echo "[specdec] $NAME :$PORT target=$TARGET draft=$DRAFT nspec=$NSPEC" ;;
*) echo "usage: launch.sh single|ngram|specdec ..."; exit 1 ;;
esac
