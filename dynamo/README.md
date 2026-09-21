# Apertus 1.5 8B — Dynamo 1 vs 2 workers (NVIDIA LaunchPad, Docker)

## Run
```bash
cp .env.example .env        # put your HF_TOKEN in (account must have ACCEPTED the Apertus 1.5 AUP)
./run_all.sh                # preflight -> build -> 4 configs x sweep -> summary (~2-3 h on 2x H100)
```
Output: `results/summary.md`, `results/summary.csv`, `results/chart_chat.png`, `results/chart_rag.png`,
and `results_<timestamp>.tgz`. **Copy the tgz off the box right away** (LaunchPad sessions expire).

Re-run parts: `SKIP_BUILD=1 MODES="dyn-2w-kv" ./run_all.sh` · one config by hand: `./03_start.sh dyn-1w && ./04_bench.sh dyn-1w`
· stop everything: `./99_stop.sh`

## What is compared (same flags, same GPU type, only one thing changes each step)
| Mode | GPUs | What changes vs previous | Answers |
|---|---|---|---|
| `vllm-1g`   | 1 | plain Swiss AI fork vLLM          | reference |
| `dyn-1w`    | 1 | + Dynamo frontend, 1 worker       | Dynamo overhead |
| `dyn-2w-rr` | 2 | + 2nd worker, round-robin router  | value of the 2nd GPU |
| `dyn-2w-kv` | 2 | round-robin -> KV-aware router    | value of cache-aware routing |

Scenarios: `chat` (512 in / 256 out) and `rag` (4096 in / 256 out, 3072-token shared prefix → where KV routing should win).

## Built-in gates (the run stops with a clear message instead of producing bad numbers)
- **Preflight**: 2 free GPUs, gated HF access works, disk, ports.
- **Build**: fails if installing Dynamo overwrote the forked vLLM (Apertus 1.5 arch must still be registered);
  records the package diff in `results/pip_diff_dynamo_install.txt`. Checks every AIPerf flag used exists.
- **Start**: model registered, *each* assigned GPU holds a loaded engine (catches a missing 2nd worker),
  workers healthy, and a smoke test (Swiss languages question, plain-string content) passes.
- **Bench**: aborts if the server dies mid-sweep. Rows missing the p95 TTFT SLO are marked ✗ and excluded
  from "max throughput within SLO".

## If 03_start.sh reports the smoke test failed behind Dynamo
Dynamo's own preprocessor applies the chat template (it must, so the KV router can see token prefixes).
If it can't render the Apertus 1.5 template, set `USE_VLLM_TOKENIZER=true` in `.env` and re-run.
Then `dyn-2w-kv` vs `dyn-2w-rr` is **not a valid router comparison** — report only 1w vs 2w.

## Files
`00_preflight.sh` · `01_build.sh` (+ `Dockerfile.dynamo`, `check_fork.py`, `Dockerfile.client`) · `02_infra.sh` (etcd + NATS)
· `03_start.sh` (+ `in_container.sh`, `smoke.sh`) · `04_bench.sh` (AIPerf) · `05_summarize.py` · `run_all.sh` · `99_stop.sh`
