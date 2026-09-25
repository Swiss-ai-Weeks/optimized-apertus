# Apertus v1.5 on NVIDIA Dynamo — deployment, benchmarks and tokenomics

Challenge C5 (NVIDIA + HPE, Swiss {ai} Weeks): deploy Apertus efficiently, benchmark
configurations, and compare the economics against cloud APIs.

Hardware: one node, **2 × NVIDIA H100 NVL** (94 GB each, NVLink).

---

## 1. The problem we had to solve first

Apertus **v1.5** declares the architecture `Apertus1p5ForConditionalGeneration`, which is
**not in upstream vLLM**. Consequence:

| Stack | Can it load Apertus v1.5? |
|---|---|
| NVIDIA NIM | ❌ architecture not in its bundled engine |
| Stock Dynamo container (Dynamo + upstream vLLM) | ❌ same reason |
| vLLM nightly | ❌ the upstream PR was still open |
| **Swiss AI vLLM fork** (`ghcr.io/swiss-ai/vllm_apertus_1.5_release`) | ✅ the only engine that works |

So there was no off-the-shelf option. We **installed Dynamo into the fork's container**
(image `apertus15-dynamo`), rather than using NVIDIA's prebuilt Dynamo image.

**Version pinning matters.** Dynamo 1.5.0 loaded the model, passed health checks, then
failed on the *first request*: it imports `VLLMClientError`, which exists in vLLM 0.28 but
not in the fork's vLLM 0.23. We pinned **Dynamo 1.3.1**, which targets vLLM 0.23, and added
a build-time check (`check_fork.py`) that scans every unguarded `from vllm... import X` in
Dynamo's source against the fork:

    Dynamo 1.5.0 → 3 missing symbols
    Dynamo 1.3.1 → 0 missing symbols

The check runs during the image build, so a mismatch fails the build instead of surfacing
later as a failed user request.

---

## 2. Configurations

Four phases, one variable between neighbours. Every deployment was verified afterwards from
its container definition (`docker inspect`); the records are in `deployment-records/`.

| Config | Phase | Weights / KV | GPUs | Serving | Variable under test |
|---|---|---|---|---|---|
| C01 | P1 | BF16 / BF16 | 1 | vLLM direct | conservative baseline (mem 0.70, 4k batched, 32 seqs, no chunked prefill/prefix caching) |
| C02 | P1 | BF16 / BF16 | 1 | vLLM direct | tuning package (mem 0.80, 8k batched, 64 seqs, chunked prefill + prefix caching) |
| C03 | P2 | **FP8** / BF16 | 1 | vLLM direct | FP8 weights |
| C04 | P2 | FP8 / **FP8** | 1 | vLLM direct | FP8 KV cache |
| C05 | P3 | FP8 / FP8 | 1 | **Dynamo 1.3.1**, 1 worker, KV router | the Dynamo layer |
| C06 | P3 | FP8 / FP8 | 2 | Dynamo, 2 workers, KV router | the second GPU |
| C07 | P4 | FP8 / FP8 | 2 | Dynamo, 2 workers (NIXL image) | control: same setup, rebuilt |
| C08 | P4 | FP8 / FP8 | 2 | **disaggregated**: GPU0 prefill, GPU1 decode, NIXL | prefill/decode split |
| NIM BF16 | — | BF16 / BF16 | 1 | NIM 2.0.13, local text-stack model | the vendor stack |
| NIM FP8 | — | FP8 / FP8 | 1 | NIM 2.0.13 | FP8 inside NIM |

Models: `swiss-ai/Apertus-v1.5-8B` (BF16) and `onprem-ai/Apertus-v1.5-8B-FP8`.
The NIM runs use a locally prepared **text-only** derivative of v1.5, which presents as an
architecture stock NIM can load.

---

## 3. Benchmark method

* Client: **NVIDIA AIPerf 0.12.0**, identical for every configuration.
* Workloads (input/output tokens): chat 512/256 · RAG 4096/256 · summarise 7500/200 ·
  agent 1024/1024 · think 512/2048 · batch 1024/128.
* Load ladder: **1, 4, 16, 64, 128** concurrent users (C04 and the NIM runs also have
  2, 3, 6, 8, 32).
* Per-workload latency targets (p95): TTFT 0.5 s (chat, think) to 4 s (summarise);
  ITL 40–80 ms. `batch` has no target.
* **SLO frontier**: each configuration is reported at the *highest load that still meets its
  targets*, never at one shared load.
* Cost: **$3.12 per H100-NVL-hour** × GPUs occupied ÷ useful throughput → $ per 1M output
  tokens, at full utilisation.

---

## 4. Results

Throughput at equal load unless noted; cost is $ per 1M output tokens at each configuration's
SLO frontier.

| Step | Throughput | Latency | Cost | Note |
|---|---|---|---|---|
| C01 → C02 (tuning) | **0%** | unchanged | $0.48 → $0.48 | but 7.5k-token prompts go from **rejected** to servable |
| C02 → C03 (FP8 weights) | **+32%** | TTFT −13% | **$0.48 → $0.37** | biggest single win |
| C03 → C04 (FP8 KV) | +4% | agent TTFT −17% | $0.37 → $0.35 | agent frontier 16 → 32 users |
| C04 → C05 (+ Dynamo) | −2% (noise) | **TTFT −24%** | $0.35 → $0.36 | no measurable overhead |
| C05 → C06 (+ 2nd GPU) | **+95%** at 128 users, **0%** at 1 user | TTFT −46% | **$0.36 → $0.22** | capacity 16 → 64 users (chat) |
| C06 → C07 (rebuild) | 1% median, 7% worst | no change | $0.22 → $0.22 | **defines our noise floor** |
| C07 → C08 (disaggregated) | **−90%** | TTFT 21× worse; **ITL −58%** | $0.22 → **$9.41** | one GPU idle (0%/100%) during decode |
| C04 vs NIM FP8 | 1.00× | TTFT 338 vs 312 ms | $0.35 vs $0.35 | **identical**, see caveat below |
| FP8 vs NVFP4 | −15% at 16 users | TTFT +64%, misses target | $0.35 → $1.09 | NVFP4 needs Blackwell; Hopper emulates it |
| 8B vs 70B (chat, 4 users) | −82% | 27 ms vs 4.6 ms per token | $1.05 → $12.00 | short test only, 70B in BF16 |

**Cost per 1M output tokens, by workload:**

| Setup | chat | RAG | summarise | agent | batch |
|---|---|---|---|---|---|
| C02 · 1 GPU BF16 | $0.48 | $2.04 | $1.96 | $0.49 | $0.39 |
| C04 · 1 GPU FP8+FP8 KV | $0.35 | **$0.76** | **$1.41** | $0.22 | **$0.28** |
| C05 · 1 GPU + Dynamo | $0.36 | $0.76 | $1.42 | $0.35 | $0.28 |
| **C06 · 2 GPUs + Dynamo** | **$0.22** | $1.05 | $1.74 | **$0.22** | $0.29 |
| NIM FP8 · 1 GPU | $0.35 | $0.77 | $1.42 | $0.22 | $0.26 |
| C08 · disaggregated | $9.41 | $14.83 | $23.54 | $2.64 | $2.92 |

**Conclusions**

1. **Two winners, chosen by workload shape.** Two GPUs with Dynamo for interactive work
   (chat, agents): 64 users inside the latency target at $0.22/1M. One GPU for document work
   and batch jobs: same user count, half the hardware.
2. **Compression is the cheapest lever**: a different checkpoint, no hardware change, −23%
   on chat and −63% on RAG.
3. **Dynamo's orchestration is free** (2%, below our noise floor); its value is scale-out
   and routing.
4. **Disaggregation is the wrong tool at 8B on 2 GPUs.** A fixed 1:1 split idles one GPU and
   pays a KV-transfer cost per request. Its one real gain: **2.4× smoother token flow** at
   high load (ITL p95 7.9 ms vs 18.9 ms).
5. **The vendor stack matches a self-built one** on identical hardware; it buys packaging and
   support, not performance.

---

## 5. Measurement integrity — read this before reusing the collector

`bench/22_collect.py` (upstream in this repo) mis-reads AIPerf 0.12 output. See
[`COLLECTOR_BUG.md`](COLLECTOR_BUG.md): AIPerf writes a `warmup_metrics` section using the
**same metric names** as the real measurement, and the collector's `_walk()` lets those
values overwrite the benchmark values. Measured effect on our data: throughput and TTFT
understated by ~30%, and up to 2.5× at high load.

The tell-tale sign is **TTFT falling as concurrency rises**, which is physically impossible.

Fixed version: [`22_collect_fixed.py`](22_collect_fixed.py). No benchmarks need re-running —
the raw AIPerf files are correct, only the reader was wrong. All results in `results-final/`
were re-collected with the fixed version.

---

## 6. Reproducing this

Prerequisites: 2 × H100 (or 1 for C01–C05), Docker with GPU support, a Hugging Face token
with access to `swiss-ai/Apertus-v1.5-8B`, and AIPerf 0.12.0.

```bash
# 1. toolkit
bash install_profiles.sh                 # installs profiles into ~/apertus-dynamo-bench
cd ~/apertus-dynamo-bench
echo "HF_TOKEN=hf_..." > .env

# 2. build the images (runs the fork/Dynamo API check)
./01_build.sh                            # apertus15-dynamo
./p0_build_nixl.sh                       # apertus15-dynamo-nixl (needed for C08)

# 3. deploy one configuration (verifies model, GPUs, workers, smoke test)
./p1_up.sh C05                           # or C06, C07, C08

# 4. benchmark it
SYSTEM=<label> SERVED_MODEL=onprem-ai/Apertus-v1.5-8B-FP8 \
  TOKENIZER=swiss-ai/Apertus-v1.5-8B bash 21_sweep_model.sh all

# 5. collect and price  (use the FIXED collector)
python3 22_collect_fixed.py --root <artifacts>/bench -o results.csv
python3 tokenomics/40_tokenomics.py --results results.csv \
  --gpu H100-NVL-94GB --gpus-per-replica <1 or 2> --out tokenomics.md

# 6. tear down
./p3_down.sh
```

`21_sweep_model.sh` is `21_sweep.sh` with `--model "${SERVED_MODEL:-apertus}"`: Dynamo serves
the model under its full repository name, so the hard-coded `--model apertus` returns HTTP 404.

Phase gates are enforced in code: C07/C08 refuse to deploy until `profiles/p3_winner.env`
records the Phase-3 winner.

---

## 7. Limitations

Stated plainly, because they bound every number above.

1. **Coarse load ladder** (1, 4, 16, 64, 128). The true capacity limit sits *between* rungs,
   so every "users served" figure is a lower bound. In particular, C06's "16 → 64 users"
   exaggerates the effect: the verified scaling is **1.95×**, so roughly 2× the users is the
   defensible claim, and 32 users was never tested on C05/C06.
2. **One run per measurement.** We quantified spread with a control (C06 vs C07: 1% median,
   7% worst up to 64 users, 12% at 128) rather than with repeats, and claim only differences
   clearly larger than that.
3. **The NIM comparison is not perfectly controlled**: NIM ran with 256 sequences and memory
   0.85 against our 64 and 0.80. At equal load the two are identical, but where NIM serves
   more users, part of that belongs to the batching setting rather than to NIM.
4. **Quality was not measured.** No accuracy evaluation of FP8 weights or the uncalibrated
   FP8 KV cache, and no output-parity check between the text-only NIM derivative and the
   official model.
5. **Two Dynamo features never got a fair test.** Cache-aware routing needs workloads that
   share prompt prefixes, and ours do not; prefill/decode disaggregation needs more than two
   GPUs for the ratio to be tunable.
6. **The 70B comparison rests on a short test**: chat only, 1 and 4 users, BF16 (not FP8).
7. **Costs assume a fully used GPU.** At a realistic 45% utilisation every figure roughly
   doubles, and that doubled figure is the one to compare against cloud API prices. The cloud
   comparator prices in `tokenomics/prices.json` are unverified list prices; only the
   H100-NVL hourly price was verified.
8. **Single node, ephemeral environment.** All results come from one LaunchPad node; nothing
   was tested across nodes, and the environment no longer exists.

---

## 8. Layout
dynamo/
README.md this file
COLLECTOR_BUG.md the AIPerf warm-up contamination and its fix
22_collect_fixed.py fixed collector ← use this one
21_sweep_model.sh sweep with a configurable served model name
install_profiles.sh installs the C05–C08 + NIM profiles
p1_up.sh / p3_down.sh deploy / tear down a configuration
p0_build_nixl.sh builds the NIXL image and tests NIXL on a GPU
check_fork.py build-time Dynamo ↔ vLLM API check
profiles/ one .env per configuration
deployment-records/ profile.json + container specs per configuration (tokens redacted)
results-final/
ALL_fixed.csv every measurement, re-collected with the fixed collector
artifacts_c01 … c08/ per-configuration results.csv and tokenomics.md
artifacts_cNIM*/ the two NIM runs

Raw per-run AIPerf output (~1.5 GB) is **not** in this repository.
