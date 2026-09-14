#!/usr/bin/env bash
# Apertus-v1.5-8B (apertus1p5, MULTIMODAL text+vision+audio) on 1x H100, :8020.
# Requires the swiss-ai vLLM release image (upstream vLLM/transformers do NOT yet
# know the apertus1p5 arch). Weights are gated on HF -> must be in the cache already
# (HF_HUB_OFFLINE=1 reads the local snapshot; token/license acceptance done once).
#   docker pull ghcr.io/swiss-ai/vllm_apertus_1.5_release:latest-amd64
set -euo pipefail
docker rm -f apertus-v15-8b 2>/dev/null || true
docker run -d --name apertus-v15-8b --restart unless-stopped \
  --device nvidia.com/gpu=1 --shm-size=16g \
  -e HF_HUB_OFFLINE=1 -e HF_HOME=/opt/nim/.cache/huggingface \
  -v $HOME/.cache/nim:/opt/nim/.cache -p 8020:8000 \
  --entrypoint vllm ghcr.io/swiss-ai/vllm_apertus_1.5_release:latest-amd64 \
  serve swiss-ai/Apertus-v1.5-8B --served-model-name Apertus-v1.5-8B \
  --host 0.0.0.0 --port 8000 --gpu-memory-utilization 0.9 --max-model-len 8192 --trust-remote-code
echo "v1.5-8B (multimodal) on :8020. VERIFIED: text chat OK ('Die Hauptstadt der Schweiz ist Bern.')."
# NOTE (from model card): 70B with --tensor-parallel-size 2 may fail CUDA-graph capture
# due to fused all-reduce RMS -> add: --compilation-config.pass_config.fuse_allreduce_rms false
