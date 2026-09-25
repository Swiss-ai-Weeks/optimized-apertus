# AIPerf warm-up contamination in 22_collect.py

AIPerf 0.12 writes a `warmup_metrics` section using the **same metric names** as the real
measurement. `_walk()` indexes metrics by name, so the warm-up values (20 requests, low
effective load) overwrite the benchmark values.

Measured effect on our data: throughput and TTFT understated by ~30%, up to 2.5x at high
load. The tell-tale sign is TTFT *falling* as concurrency rises, which is impossible.

Fix (see 22_collect_fixed.py), inside `_walk()`:

    obj = {k: v for k, v in obj.items() if k != "warmup_metrics"}

No benchmarks need re-running - the raw files are correct, only the reader was wrong:

    python3 22_collect_fixed.py --root <artifacts>/bench -o results.csv
