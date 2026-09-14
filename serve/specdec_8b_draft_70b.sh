#!/usr/bin/env bash
# ==========================================================================
# Speculative decoding: Apertus-8B (draft) proposes, Apertus-70B-FP8 (target)
# verifies. ONE engine, BOTH H100s (TP=2). Output == plain 70B; goal = speedup.
# Serves OpenAI API on :8020.  WARNING: needs ALL GPU memory ->
#   docker stop apertus-8b apertus-70b   # free both cards first
# VERIFIED: mean acceptance length 3.32, ~1.7x tok/s vs plain 70B-FP8.
#
# NOTE: We bypass the NIM wrapper and call vLLM directly, because NIM's
# NIM_PASSTHROUGH_ARGS strips the quotes inside --speculative-config JSON
# (vLLM then exits with code 2). Raw vLLM lets us quote the JSON correctly.
# ==========================================================================
set -euo pipefail
DRAFT=swiss-ai/Apertus-8B-Instruct-2509
TARGET=swiss-ai/Apertus-70B-Instruct-2509
NSPEC=${1:-5}   # num_speculative_tokens; per-position acceptance decays fast -> try 3-4
docker rm -f apertus-specdec 2>/dev/null || true
docker run -d --name apertus-specdec --restart no \
  --device nvidia.com/gpu=0 --device nvidia.com/gpu=1 --shm-size=32g \
  -e HF_HOME=/opt/nim/.cache/huggingface -e HF_HUB_OFFLINE=1 \
  -v $HOME/.cache/nim:/opt/nim/.cache -p 8020:8000 \
  --entrypoint python3 nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1 \
  -m vllm.entrypoints.openai.api_server --model ${TARGET} \
  --served-model-name Apertus-70B-specdec --tensor-parallel-size 2 \
  --quantization fp8 --gpu-memory-utilization 0.9 --max-model-len 32768 --port 8000 \
  --speculative-config '{"model":"'${DRAFT}'","num_speculative_tokens":'${NSPEC}'}'
echo "spec-decode on :8020 (draft=8B, target=70B-FP8, TP=2, nspec=${NSPEC})."
echo "health: curl -s localhost:8020/health ; metrics in: docker logs apertus-specdec | grep SpecDecoding"
