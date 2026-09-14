docker run --gpus '"device=0"' \
  --ipc=host \
  -e NIM_MODEL_PATH="hf://swiss-ai/Apertus-8B-Instruct-2509" \
  -e NIM_SERVED_MODEL_NAME="Apertus-8B-Instruct-2509" \
  -v "$HOME/.cache/nim:/opt/nim/.cache" \
  -p 8000:8000 \
  nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1 \
  --dtype bfloat16 \
  --gpu-memory-utilization 0.90
