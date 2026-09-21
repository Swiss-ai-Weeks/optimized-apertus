#!/usr/bin/env bash
# Apertus-8B-Instruct-2509 on TensorRT-LLM via AutoDeploy (PROVEN WORKING).
# TRT-LLM does NOT ship an Apertus model definition, but the AutoDeploy backend
# traces the HF checkpoint into a graph directly -> no manual model port needed.
#
# Gotcha: Apertus uses QK-Norm (RMSNorm on attention head_dim). The fused RMSNorm
# kernels (flashinfer AND triton) both crash on that layout (illegal memory access).
# Fix: disable the 3 rmsnorm-fusion transforms (see serve/ad_apertus.yaml). RMSNorm
# then stays as native decomposed torch ops -> correct, slightly slower on that op.
set -euo pipefail

IMAGE=nvcr.io/nvidia/tensorrt-llm/release:1.3.0rc9
GPU=${GPU:-1}
PORT=${PORT:-8030}
NAME=${NAME:-trt_ad_8b}
# Weights live in the NIM HF cache (config+safetensors together):
SNAP=/root/.cache/huggingface/hub/models--swiss-ai--Apertus-8B-Instruct-2509/snapshots/b946d40447b2b597999b9c86d44bee0b452c919f
HERE=$(cd "$(dirname "$0")" && pwd)

docker rm -f "$NAME" 2>/dev/null || true
docker run -d --name "$NAME" --gpus "\"device=${GPU}\"" \\
  -v /home/nvidia/.cache/nim/huggingface:/root/.cache/huggingface \\
  -v "${HERE}/ad_apertus.yaml":/root/ad_apertus.yaml:ro \\
  -e HF_HUB_OFFLINE=1 -p ${PORT}:${PORT} "$IMAGE" \\
  trtllm-serve "$SNAP" --backend _autodeploy \\
    --host 0.0.0.0 --port ${PORT} --max_batch_size 8 \\
    --extra_llm_api_options /root/ad_apertus.yaml

echo "Launched $NAME on GPU$GPU :$PORT (first build ~65s + one slow warmup request)."
