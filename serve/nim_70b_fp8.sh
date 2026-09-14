#!/usr/bin/env bash
# Apertus-70B-Instruct-2509 | dynamic FP8 (Hopper) | 1x H100 (GPU1), TP=1 | OpenAI API on :8010
set -euo pipefail
docker rm -f apertus-70b 2>/dev/null || true
docker run -d --name apertus-70b --restart unless-stopped \
  --device nvidia.com/gpu=1 --shm-size=16g \
  -e NIM_MODEL_PATH=hf://swiss-ai/Apertus-70B-Instruct-2509 \
  -e NIM_SERVED_MODEL_NAME=Apertus-70B-Instruct-2509 \
  -e NIM_PASSTHROUGH_ARGS="--quantization fp8 --gpu-memory-utilization 0.9 --max-model-len 32768" \
  -v $HOME/.cache/nim:/opt/nim/.cache \
  -p 8010:8000 \
  nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1
echo "70B-FP8 launching on :8010 (GPU1). First load ~2-3 min (reads 132G BF16 + FP8 quant)."
