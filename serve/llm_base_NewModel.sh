bash
set -euo pipefail

export VLLM_DEEP_GEMM_WARMUP=skip
export VLLM_USE_DEEP_GEMM=0

docker rm -f apertus-8b 2>/dev/null || true

docker run -d \
  --name apertus-8b \
  --restart unless-stopped \
  --device nvidia.com/gpu=0 \
  --shm-size=16g \
  --ipc=host \
  --network=host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864 \
  -e VLLM_DEEP_GEMM_WARMUP \
  -e VLLM_USE_DEEP_GEMM \
  -e NIM_MODEL_PATH=hf://swiss-ai/Apertus-v1.5-8B \
  -e NIM_SERVED_MODEL_NAME=Apertus-v1.5-8B \
  -e NIM_PASSTHROUGH_ARGS="--trust-remote-code --tensor-parallel-size 1" \
  -v "$HOME/.cache/nim:/opt/nim/.cache" \
  nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1

echo "Apertus v1.5 8B launching on GPU 0."
echo "Deep GEMM disabled."
echo "Tensor parallel size: 1"
echo "Health: curl -s localhost:8000/v1/health/ready"
echo "Logs: docker logs -f apertus-8b"
