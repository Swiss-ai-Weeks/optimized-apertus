# Apertus 8B NIM Benchmark Results

Workload: 128 input tokens, 128 output tokens, streaming enabled.

## Performance results

| Deployment | Configuration | Concurrency | Output tokens/s | Requests/s | TTFT avg (ms) | Request latency avg (ms) | ITL avg (ms) |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | Default | 1 | 166.07 | 1.30 | 36.74 | 763.92 | 5.74 |
| 1 | Default | 4 | 645.17 | 5.06 | 56.06 | 785.51 | 5.76 |
| 1 | Default | 8 | 1222.24 | 9.58 | 85.70 | 829.35 | 5.87 |
| 1 | Default | 16 | 2346.78 | 18.39 | 125.35 | 863.92 | 5.83 |
| 1 | Default | 32 | 4024.46 | 31.52 | 180.06 | 1008.70 | 6.54 |
| 1 | Default | 64 | 6371.10 | 49.89 | 263.26 | 1271.27 | 7.96 |
| 2 | Fixed/custom parameters | 1 | 165.59 | 1.30 | 49.49 | 765.98 | 5.65 |
| 2 | Fixed/custom parameters | 16 | 2261.80 | 17.71 | 159.12 | 897.24 | 5.82 |
| 2 | Fixed/custom parameters | 32 | 3918.16 | 30.68 | 216.88 | 1035.90 | 6.46 |
| 2 | Fixed/custom parameters | 64 | 4344.86 | 34.03 | 990.26 | 1863.43 | 6.89 |
| 3 | Fixed/custom parameters | 1 | 166.12 | 1.30 | 46.63 | 762.90 | 5.65 |
| 3 | Fixed/custom parameters | 16 | 2265.76 | 17.74 | 156.32 | 895.56 | 5.83 |
| 3 | Fixed/custom parameters | 32 | 3698.26 | 28.97 | 249.67 | 1097.14 | 6.69 |
| 3 | Fixed/custom parameters | 64 | 4235.91 | 33.17 | 1003.89 | 1912.54 | 7.17 |
| 4 | Fixed/custom parameters, max sequences 128 | 1 | 162.46 | 1.27 | 39.45 | 780.91 | 5.85 |
| 4 | Fixed/custom parameters, max sequences 128 | 32 | 3761.84 | 29.46 | 215.72 | 1079.44 | 6.82 |
| 4 | Fixed/custom parameters, max sequences 128 | 64 | 6266.05 | 49.08 | 288.24 | 1294.62 | 7.95 |
| 4 | Fixed/custom parameters, max sequences 128 | 128 | 7835.05 | 61.37 | 546.49 | 2069.18 | 12.02 |

## Deployment 4 GPU results

| Concurrency | Samples | Avg GPU utilization | Max GPU utilization | Avg power | Max power | Max temperature |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 49 | 75.9% | 100.0% | 324.9 W | 391.6 W | 67 C |
| 32 | 66 | 73.4% | 100.0% | 331.8 W | 402.7 W | 72 C |
| 64 | 78 | 73.7% | 100.0% | 324.7 W | 399.7 W | 73 C |
| 128 | 120 | 80.1% | 100.0% | 347.8 W | 408.3 W | 75 C |

## Main findings

- Deployment 4 achieved the highest measured throughput: 7,835 output tokens/s at concurrency 128.
- Concurrency 64 provides the best balance between throughput and interactive latency.
- Deployment 4 at concurrency 64 reached approximately 98% of the default deployment's throughput.
- Compared with Deployment 3 at concurrency 64, Deployment 4 increased throughput by approximately 48% and reduced average TTFT by approximately 71%.
- Concurrency 128 is most suitable for batch throughput, while concurrency 32 or 64 is preferable for latency-sensitive workloads.
