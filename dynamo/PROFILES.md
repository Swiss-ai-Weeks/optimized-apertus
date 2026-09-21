# C05–C08 profiles — Apertus v1.5 8B FP8 on Dynamo

All profiles share the frozen C04 inference settings (`profiles/common.env`): FP8 weights, FP8 KV cache,
8192 context, 0.80 GPU memory, 8192 batched tokens, 64 sequences, chunked prefill, prefix caching.
Each profile changes only what its row says.

| Profile | Phase | What runs | Changes vs previous |
|---|---|---|---|
| C04R | P3 | standalone vLLM (Swiss AI fork), GPU0 | C04 re-measured with the P3/P4 workloads |
| C05  | P3 | Dynamo frontend + 1 worker, GPU0 | serving layer only |
| C06  | P3 | Dynamo, 2 workers (GPU0+GPU1), KV router | scale-out + routing |
| gate | P3→P4 | lowest cost per GPU-hour wins; sweep `max-num-seqs` on the winner | decides router + batch size |
| C07  | P4 | winner settings, 2 aggregated workers, NIXL image | same-session control |
| C08  | P4 | GPU0 = prefill, GPU1 = decode, NIXL KV transfer | disaggregation only |
| C08b | P4 | C08 + prefill 16384 batched tokens, decode 2x sequences | per-role tuning |

Workloads (identical for all): chat 512/256 · rag 3072 shared + 1024 unique = 4096 in / 256 · multiturn 6 turns,
history resent (up to ~4.4k in) · longprompt 6500/256. Load levels: 1 8 32 64 128.
A request is *good* if TTFT ≤ 2000 ms and mean ITL ≤ 50 ms; a load level counts if ≥ 95 % of requests are good.

## Run order (≈ 30 min per profile)
```bash
# 0. the kit's run_all.sh must have finished ("Done" in run.log); copy its results_*.tgz off the box
./run_profiles.sh C04R C05 C06                               # Phase 3
GPU_PRICE_PER_HOUR=<price of ONE GPU per hour> ./p4_tokenomics.py   # gate: prints the winner
./run_profiles.sh <winner>:seqs=128 <winner>:seqs=256        # batch sweep on the winner
GPU_PRICE_PER_HOUR=<same> ./p4_tokenomics.py                 # final winner incl. batch size
nano profiles/p3_winner.env                                  # paste the two printed lines
./p0_build_nixl.sh                                           # NIXL image for C07/C08 (+ GPU check)
./run_profiles.sh C07 C08 C08b                               # Phase 4, back to back
GPU_PRICE_PER_HOUR=<same> ./p4_tokenomics.py                 # full report -> results/tokenomics.md
```
Short on time: fewer load levels per profile, e.g. `./run_profiles.sh C05:conc=8+32+64`.
Single steps: `./p1_up.sh C06` (deploy + verify) · `./p2_bench.sh C06` · `./p3_down.sh`.

## Built-in checks (stop with a clear [FAIL] instead of producing bad numbers)
- GPUs free, ports free, image present, kit not running; every profile spec validated before starting.
- Ready = model registered + every GPU holds an engine + every worker healthy + correct answer + all containers alive.
- C08/C08b: NIXL must initialise on the GPU first; afterwards the prefill GPU must actually work under long prompts.
- `results/<profile>/profile.json` records exactly what ran (settings, image, vLLM + Dynamo versions).

## Cost and cloud comparison
`GPU_PRICE_PER_HOUR` = what ONE H100 NVL costs you per hour (state your source in the deck).
Without it the report uses GPU-seconds per 1M tokens (same ranking). For the cloud comparison, fill
`cloud_prices.json` with real list prices and set `"verified": true`; unverified entries are ignored.

## Note on the earlier kit results
The kit's `rag` workload was labelled "ISL 4096" but sent 4096 unique + 3072 shared = 7168 input tokens.
Its numbers are valid for 7168 tokens. The profiles above use a true 4096-token RAG prompt.
