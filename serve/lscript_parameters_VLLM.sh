docker run --gpus '"device=0"' \
  --ipc=host \
  -e NIM_MODEL_PATH="hf://swiss-ai/Apertus-8B-Instruct-2509" \
  -e NIM_SERVED_MODEL_NAME="Apertus-8B-Instruct-2509" \
  -v "$HOME/.cache/nim:/opt/nim/.cache" \
  -p 8000:8000 \
  nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1 \
  --dtype bfloat16 \
  --gpu-memory-utilization 0.90 \
  --enable-prefix-caching \
  --max-num-batched-tokens 8192 \
  --max-num-seqs 32 \
  --max-model-len 8192


#!/bin/bash

set -euo pipefail

# ============================================================
# Apertus AI Weeks - Optimized Deployment Experiment Runner
# ============================================================
#
# Model:
#   swiss-ai/Apertus-8B-Instruct-2509
#
# NIM:
#   vLLM Model-Free NIM 2.1.1
#
# The CONFIGS table contains all experiment parameters.
#
# Fields:
#   ID
#   ENGINE
#   PRECISION
#   GPU_LIST
#   TP
#   PP
#   GPU_MEMORY_UTILIZATION
#   MAX_NUM_BATCHED_TOKENS
#   MAX_NUM_SEQS
#   MAX_MODEL_LEN
#   CHUNKED_PREFILL
#   PREFIX_CACHING
#   DYNAMO_MODE
# ============================================================


# ============================================================
# Global settings
# ============================================================

MODEL="hf://swiss-ai/Apertus-8B-Instruct-2509"
SERVED_MODEL="Apertus-8B-Instruct-2509"

VLLM_IMAGE="nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1"

CACHE_DIR="$HOME/.cache/nim"

BASE_PORT=8000


# ============================================================
# Optional credentials
# ============================================================

# If your Hugging Face model access requires authentication,
# export HF_TOKEN before running this script.
#
# Example:
#   export HF_TOKEN="hf_xxxxxxxxx"
#
# The script will automatically pass it to the container.

HF_ARGS=()

if [ -n "${HF_TOKEN:-}" ]; then
    HF_ARGS+=(
        -e "HF_TOKEN=$HF_TOKEN"
    )
fi


# ============================================================
# Experiment configurations
# ============================================================
#
# Format:
#
# ID |
# ENGINE |
# PRECISION |
# GPU_LIST |
# TP |
# PP |
# GPU_MEMORY_UTILIZATION |
# MAX_NUM_BATCHED_TOKENS |
# MAX_NUM_SEQS |
# MAX_MODEL_LEN |
# CHUNKED_PREFILL |
# PREFIX_CACHING |
# DYNAMO_MODE
#
# ============================================================

CONFIGS=(

    # --------------------------------------------------------
    # C01 - vLLM BF16 TP8 baseline
    # --------------------------------------------------------
    "c01|vllm|bf16|0,1,2,3,4,5,6,7|8|1|0.90|4096|32|8192|false|false|none"


    # --------------------------------------------------------
    # C02 - vLLM BF16 TP4 high concurrency
    # --------------------------------------------------------
    "c02|vllm|bf16|0,1,2,3|4|1|0.90|8192|128|8192|true|false|none"


    # --------------------------------------------------------
    # C03 - vLLM FP8 TP4
    # --------------------------------------------------------
    "c03|vllm|fp8|0,1,2,3|4|1|0.90|8192|128|8192|true|true|none"


    # --------------------------------------------------------
    # C04 - TensorRT-LLM BF16 TP8
    # --------------------------------------------------------
    "c04|trtllm|bf16|0,1,2,3,4,5,6,7|8|1|0.90|4096|32|8192|false|false|none"


    # --------------------------------------------------------
    # C05 - TensorRT-LLM FP8 TP4
    # --------------------------------------------------------
    "c05|trtllm|fp8|0,1,2,3|4|1|0.90|8192|128|8192|true|false|none"


    # --------------------------------------------------------
    # C06 - TensorRT-LLM FP8 TP4 aggressive batch
    # --------------------------------------------------------
    "c06|trtllm|fp8|0,1,2,3|4|1|0.95|16384|256|8192|true|false|none"


    # --------------------------------------------------------
    # C07 - Dynamo + vLLM FP8
    #
    # 4 workers x 2 GPUs
    # --------------------------------------------------------
    "c07|dynamo-vllm|fp8|0,1|2|1|0.90|8192|128|8192|true|true|agg"


    # --------------------------------------------------------
    # C08 - Dynamo + TensorRT-LLM FP8
    #
    # 4 workers x 2 GPUs
    # --------------------------------------------------------
    "c08|dynamo-trtllm|fp8|0,1|2|1|0.90|8192|128|8192|true|false|agg"


    # --------------------------------------------------------
    # C09 - Dynamo + TensorRT-LLM P/D disaggregation
    #
    # 2 prefill workers x 2 GPUs
    # 2 decode workers  x 2 GPUs
    # --------------------------------------------------------
    "c09|dynamo-trtllm|fp8|0,1|2|1|0.90|8192|128|8192|true|false|pd"


    # --------------------------------------------------------
    # C10 - Champion
    #
    # This is intentionally a placeholder.
    # The benchmark results should determine the winner.
    # --------------------------------------------------------
    "c10|champion|auto|0,1,2,3,4,5,6,7|8|1|0.90|8192|128|8192|true|true|auto"

)


# ============================================================
# Helper functions
# ============================================================

print_config() {

    echo
    echo "============================================================"
    echo "Configuration"
    echo "============================================================"
    echo "ID:                       $ID"
    echo "Engine:                   $ENGINE"
    echo "Precision:                $PRECISION"
    echo "GPU list:                 $GPU_LIST"
    echo "Tensor Parallel:          $TP"
    echo "Pipeline Parallel:        $PP"
    echo "GPU Memory Utilization:   $GPU_MEMORY_UTILIZATION"
    echo "Max Batched Tokens:       $MAX_NUM_BATCHED_TOKENS"
    echo "Max Sequences:            $MAX_NUM_SEQS"
    echo "Max Model Length:         $MAX_MODEL_LEN"
    echo "Chunked Prefill:          $CHUNKED_PREFILL"
    echo "Prefix Caching:           $PREFIX_CACHING"
    echo "Dynamo Mode:              $DYNAMO_MODE"
    echo "============================================================"
    echo
}


# ============================================================
# Run vLLM configuration
# ============================================================

run_vllm() {

    CONTAINER_NAME="apertus-${ID}-${ENGINE}-${PRECISION}-tp${TP}"

    PORT=$((BASE_PORT + CONFIG_INDEX))

    echo "Starting container:"
    echo "  $CONTAINER_NAME"
    echo "  port: $PORT"

    ARGS=(
        --dtype "$PRECISION"
        --tensor-parallel-size "$TP"
        --pipeline-parallel-size "$PP"
        --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION"
        --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS"
        --max-num-seqs "$MAX_NUM_SEQS"
        --max-model-len "$MAX_MODEL_LEN"
    )


    # --------------------------------------------------------
    # Chunked prefill
    # --------------------------------------------------------

    if [ "$CHUNKED_PREFILL" = "true" ]; then
        ARGS+=(
            --enable-chunked-prefill
        )
    fi


    # --------------------------------------------------------
    # Prefix caching
    # --------------------------------------------------------

    if [ "$PREFIX_CACHING" = "true" ]; then
        ARGS+=(
            --enable-prefix-caching
        )
    fi


    # --------------------------------------------------------
    # Run Docker
    # --------------------------------------------------------

    docker run \
        --name "$CONTAINER_NAME" \
        --gpus "device=$GPU_LIST" \
        --ipc=host \
        -e "NIM_MODEL_PATH=$MODEL" \
        -e "NIM_SERVED_MODEL_NAME=$SERVED_MODEL" \
        -v "$CACHE_DIR:/opt/nim/.cache" \
        -p "$PORT:8000" \
        "${HF_ARGS[@]}" \
        "$VLLM_IMAGE" \
        "${ARGS[@]}"
}


# ============================================================
# TRT-LLM configuration
# ============================================================

run_trtllm() {

    echo
    echo "------------------------------------------------------------"
    echo "TRT-LLM configuration detected: $ID"
    echo "------------------------------------------------------------"
    echo
    echo "This configuration is defined, but the validated"
    echo "TensorRT-LLM NIM image/profile for Apertus has not yet"
    echo "been supplied."
    echo
    echo "Do NOT substitute the vLLM image here."
    echo
    echo "Required next step:"
    echo "  1. Identify the TRT-LLM NIM image."
    echo "  2. Run list-model-profiles."
    echo "  3. Confirm Apertus supports the requested TP/PP/precision."
    echo
    echo "Configuration that would be tested:"
    echo
    echo "  Precision:              $PRECISION"
    echo "  TP:                     $TP"
    echo "  PP:                     $PP"
    echo "  GPU memory fraction:    $GPU_MEMORY_UTILIZATION"
    echo "  Max batch tokens:       $MAX_NUM_BATCHED_TOKENS"
    echo "  Max batch size:         $MAX_NUM_SEQS"
    echo "  Max sequence length:    $MAX_MODEL_LEN"
    echo
    echo "Skipping $ID."
    echo

    return 0
}


# ============================================================
# Dynamo + vLLM
# ============================================================

run_dynamo_vllm() {

    echo
    echo "------------------------------------------------------------"
    echo "Dynamo + vLLM configuration detected: $ID"
    echo "------------------------------------------------------------"
    echo
    echo "Dynamo requires its own worker/frontend topology."
    echo
    echo "Configuration:"
    echo "  Worker GPUs:             $GPU_LIST"
    echo "  TP:                      $TP"
    echo "  PP:                      $PP"
    echo "  Precision:               $PRECISION"
    echo "  Max batched tokens:      $MAX_NUM_BATCHED_TOKENS"
    echo "  Max sequences:           $MAX_NUM_SEQS"
    echo "  Max model length:        $MAX_MODEL_LEN"
    echo "  Chunked prefill:         $CHUNKED_PREFILL"
    echo "  Prefix caching:          $PREFIX_CACHING"
    echo "  Dynamo mode:             $DYNAMO_MODE"
    echo
    echo "Skipping $ID until the Dynamo deployment topology is"
    echo "configured."
    echo

    return 0
}


# ============================================================
# Dynamo + TRT-LLM
# ============================================================

run_dynamo_trtllm() {

    echo
    echo "------------------------------------------------------------"
    echo "Dynamo + TRT-LLM configuration detected: $ID"
    echo "------------------------------------------------------------"
    echo
    echo "This requires:"
    echo "  - validated TRT-LLM NIM/backend"
    echo "  - Dynamo worker configuration"
    echo "  - TP/PP configuration"
    echo "  - frontend/router configuration"
    echo "  - KV-transfer configuration for P/D"
    echo
    echo "Configuration:"
    echo "  Precision:               $PRECISION"
    echo "  TP:                      $TP"
    echo "  PP:                      $PP"
    echo "  GPU memory:              $GPU_MEMORY_UTILIZATION"
    echo "  Max tokens:              $MAX_NUM_BATCHED_TOKENS"
    echo "  Max sequences:           $MAX_NUM_SEQS"
    echo "  Max model length:        $MAX_MODEL_LEN"
    echo "  Dynamo mode:             $DYNAMO_MODE"
    echo
    echo "Skipping $ID until the Dynamo/TRT-LLM deployment topology"
    echo "is configured."
    echo

    return 0
}


# ============================================================
# Main experiment loop
# ============================================================

CONFIG_INDEX=0

for CONFIG in "${CONFIGS[@]}"; do

    CONFIG_INDEX=$((CONFIG_INDEX + 1))

    IFS='|' read -r \
        ID \
        ENGINE \
        PRECISION \
        GPU_LIST \
        TP \
        PP \
        GPU_MEMORY_UTILIZATION \
        MAX_NUM_BATCHED_TOKENS \
        MAX_NUM_SEQS \
        MAX_MODEL_LEN \
        CHUNKED_PREFILL \
        PREFIX_CACHING \
        DYNAMO_MODE \
        <<< "$CONFIG"


    print_config


    case "$ENGINE" in

        vllm)
            run_vllm
            ;;

        trtllm)
            run_trtllm
            ;;

        dynamo-vllm)
            run_dynamo_vllm
            ;;

        dynamo-trtllm)
            run_dynamo_trtllm
            ;;

        champion)
            echo
            echo "============================================================"
            echo "C10 CHAMPION"
            echo "============================================================"
            echo
            echo "C10 should be populated after benchmarking C01-C09."
            echo
            ;;

        *)
            echo "ERROR: Unknown engine: $ENGINE"
            exit 1
            ;;

    esac

done


echo
echo "============================================================"
echo "Experiment configuration processing complete."
echo "============================================================"