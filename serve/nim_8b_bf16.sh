#!/usr/bin/env bash
# Apertus-8B-Instruct-2509 | BF16 | 1x H100 (GPU0), TP=1 | OpenAI API on :8000
set -euo pipefail
docker rm -f apertus-8b 2>/dev/null || true
docker run -d --name apertus-8b --restart unless-stopped \
  --device nvidia.com/gpu=0 --shm-size=16g \
  -e NIM_MODEL_PATH=hf://swiss-ai/Apertus-8B-Instruct-2509 \
  -e NIM_SERVED_MODEL_NAME=Apertus-8B-Instruct-2509 \
  -v $HOME/.cache/nim:/opt/nim/.cache \
  -p 8000:8000 \
  nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1
echo "8B launching on :8000 (GPU0). Poll: curl -s localhost:8000/v1/health/ready"
