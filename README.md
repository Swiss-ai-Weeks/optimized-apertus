# optimized-apertus

Serving + inference optimization of **Apertus** (Swiss AI) on 2x H100 NVL via NVIDIA NIM (vLLM backend).
HPE & NVIDIA Agentic AI Hackathon.

## Hardware
- 2x NVIDIA H100 NVL (~94 GB each), NVLink active, driver 595.71, CUDA 13
- Docker + nvidia runtime; NIM image `nvcr.io/nim/nvidia/vllm-model-free-nim:2.1.1`

## Serving configs (`serve/`)
| script | model | precision | GPU | port |
|---|---|---|---|---|
| `nim_8b_bf16.sh` | Apertus-8B-Instruct-2509 | BF16 | GPU0 (TP=1) | 8000 |
| `nim_70b_fp8.sh` | Apertus-70B-Instruct-2509 | FP8 (dynamic, Hopper) | GPU1 (TP=1) | 8010 |
| `specdec_8b_draft_70b.sh` | 70B target + 8B draft | FP8 | both (TP=2) | 8020 |

8B and 70B run in parallel (one card each). Spec-decode uses BOTH cards -> stop the parallel pair first.

## OpenAI-compatible API
    curl -s http://localhost:8000/v1/chat/completions -H 'Content-Type: application/json' \
      -d '{"model":"Apertus-8B-Instruct-2509","messages":[{"role":"user","content":"..."}],"max_tokens":128}'
logprobs enabled -> lm-eval-harness loglikelihood tasks work (local-completions / local-chat-completions).

## Speculative decoding (8B draft -> 70B target)
Verified: mean acceptance length **3.32**, per-position 0.72/0.52/0.45/0.38/0.25, avg draft acceptance 46.3%,
**~1.7x tok/s** vs plain 70B-FP8. Output distribution == plain 70B by construction.
- Tuning: num_speculative_tokens 3-4 likely beats 5 (tail positions rarely accepted).
- min_p / logit_bias are unsupported under spec decode.

### NIM passthrough fix
NIM tokenizes `NIM_PASSTHROUGH_ARGS` with shlex and strips the escaped double-quotes inside the
`--speculative-config` JSON, so vLLM exits with code 2. Fix: pass the args via `--env-file`
(`serve/specdec_nim.env`) with the JSON wrapped in **single** quotes; shlex then keeps the double quotes.
A raw-vLLM fallback (bypassing the NIM wrapper) is included in the script and is end-to-end verified.

## TensorRT-LLM path
Parked: toolchain absent (pull needs NGC login to `nvcr.io/nvidia/tensorrt-llm`) and Apertus
(`ApertusForCausalLM`) not confirmed supported by TRT-LLM `convert_checkpoint`. vLLM path used instead.

## Benchmark constructor
One launcher for any config (GPU-exclusive -> run benchmarks in a dedicated window):

    serve/launch.sh single  <model_id> <gpu> <port> [bf16|fp8]
    serve/launch.sh specdec <target_id> <draft_id> <port> [nspec]   # draft->target, TP=2

Engine auto-selected: `*v1.5*` -> swiss-ai release image; else NIM vLLM.
Spec-decode requires draft & target to share a tokenizer family:
- valid:   2509-8B -> 2509-70B (via NIM env-file);  v1.5-8B -> v1.5-70B (swiss-ai img, experimental)
- invalid: any 2509 <-> v1.5 mix (different vocab/arch)

2x H100 (188 GB) cannot co-host all models + a spec-decode engine at once - configs are
mutually exclusive and swapped in one at a time by the matrix runner.

Measure + aggregate (unified JSON schema per run):

    bench/bench.py --url http://localhost:PORT --model ID --name NAME [--concurrency N --requests M --max-tokens T]
      -> results/<name>.json  {perf:{tok_s,p50_s,p99_s}, energy:{avg_gpu_w,tok_per_wh}, quality:{}, cost:{}}
    bench/run_matrix.sh     # launch each CONFIG -> wait ready -> benchmark -> teardown
    analyze/table.py        # print results/ as one table (Pareto view)

`quality{}` is the slot for lm-eval-harness scores (run separately, merged by config name).
