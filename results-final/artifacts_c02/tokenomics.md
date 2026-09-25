# Apertus tokenomics

- Cost basis: **1 x H100-NVL-94GB** = $3.12/h on-demand, $1.63/h amortized-owned

- Utilization assumption: **45%** (730 h/month billed)

- Operating point: highest-throughput configuration that still met its p95 latency SLO.

- Unverified prices are flagged; see `tokenomics/prices.json`.


## Self-hosted cost per million tokens

| system | workload | conc | out tok/s | TTFT p95 (ms) | $/1M out (100% util) | $/1M out (@util) | $/1M blended (@util) |
|---|---|---:|---:|---:|---:|---:|---:|
| h100nvl-conf02 | agent | 64 | 2,275 | 806 | $0.38 | $0.85 | $0.42 |
| h100nvl-conf02 | batch | 128 | 1,465 | 792 | $0.59 | $1.31 | $0.15 |
| h100nvl-conf02 | chat | 64 | 2,248 | 476 | $0.39 | $0.86 | $0.28 |
| h100nvl-conf02 | rag | 4 | 430 | 642 | $2.02 | $4.48 | $0.26 |
| h100nvl-conf02 | summarize | 4 | 296 | 1208 | $2.92 | $6.50 | $0.17 |
| h100nvl-conf02 | think | 64 | 1,361 | 466 | $0.64 | $1.42 | $0.58 |
| v15-70b-tp2-len8k | chat | 4 | 145 | 448 | $5.97 | $13.27 | $4.42 |
| v15-8b-tp1-len8k | agent | 128 | 2,269 | 823 | $0.38 | $0.85 | $0.42 |
| v15-8b-tp1-len8k | batch | 128 | 1,488 | 754 | $0.58 | $1.29 | $0.14 |
| v15-8b-tp1-len8k | chat | 128 | 2,260 | 461 | $0.38 | $0.85 | $0.28 |
| v15-8b-tp1-len8k | rag | 4 | 432 | 643 | $2.01 | $4.46 | $0.26 |
| v15-8b-tp1-len8k | think | 64 | 1,346 | 432 | $0.64 | $1.43 | $0.46 |

## Versus cloud token APIs

Break-even = monthly volume above which the self-hosted deployment is cheaper. Below it, pay per token.


### chat (ISL 512 / OSL 256)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: v15-8b-tp1-len8k** | **$0.28** | - | - |
| frontier-api-tier1 ⚠ | $7.00 | 24.7x | 325.4 |
| open-weights-vendor-70b ⚠ | $0.67 | 2.4x | 3,416.4 |
| open-weights-vendor-8b ⚠ | $0.13 | 0.5x | 17,082.0 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### rag (ISL 4096 / OSL 256)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: v15-8b-tp1-len8k** | **$0.26** | - | - |
| frontier-api-tier1 ⚠ | $3.71 | 14.2x | 614.6 |
| open-weights-vendor-70b ⚠ | $0.61 | 2.3x | 3,723.0 |
| open-weights-vendor-8b ⚠ | $0.11 | 0.4x | 21,510.7 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### summarize (ISL 7500 / OSL 200)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf02** | **$0.17** | - | - |
| frontier-api-tier1 ⚠ | $3.31 | 19.8x | 687.7 |
| open-weights-vendor-70b ⚠ | $0.61 | 3.6x | 3,763.4 |
| open-weights-vendor-8b ⚠ | $0.10 | 0.6x | 22,199.4 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### agent (ISL 1024 / OSL 1024)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf02** | **$0.42** | - | - |
| frontier-api-tier1 ⚠ | $9.00 | 21.3x | 253.1 |
| open-weights-vendor-70b ⚠ | $0.70 | 1.7x | 3,253.7 |
| open-weights-vendor-8b ⚠ | $0.15 | 0.4x | 15,184.0 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### batch (ISL 1024 / OSL 128)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: v15-8b-tp1-len8k** | **$0.14** | - | - |
| frontier-api-tier1 ⚠ | $4.33 | 30.3x | 525.6 |
| open-weights-vendor-70b ⚠ | $0.62 | 4.4x | 3,660.4 |
| open-weights-vendor-8b ⚠ | $0.11 | 0.8x | 20,498.4 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### think (ISL 512 / OSL 2048)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: v15-8b-tp1-len8k** | **$0.46** | - | - |
| frontier-api-tier1 ⚠ | $12.60 | 27.2x | 180.8 |
| open-weights-vendor-70b ⚠ | $0.76 | 1.6x | 2,996.8 |
| open-weights-vendor-8b ⚠ | $0.18 | 0.4x | 12,653.3 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

## Sensitivity to utilization

The single assumption that moves the answer most.

| system | workload | $/1M out @ 20% | $/1M out @ 45% | $/1M out @ 80% | $/1M out @ 100% |
|---|---|---:|---:|---:|---:|
| h100nvl-conf02 | agent | $1.90 | $0.85 | $0.48 | $0.38 |
| h100nvl-conf02 | batch | $2.96 | $1.31 | $0.74 | $0.59 |
| h100nvl-conf02 | chat | $1.93 | $0.86 | $0.48 | $0.39 |
| h100nvl-conf02 | rag | $10.08 | $4.48 | $2.52 | $2.02 |
| h100nvl-conf02 | summarize | $14.62 | $6.50 | $3.65 | $2.92 |
| h100nvl-conf02 | think | $3.18 | $1.42 | $0.80 | $0.64 |
| v15-70b-tp2-len8k | chat | $29.86 | $13.27 | $7.47 | $5.97 |
| v15-8b-tp1-len8k | agent | $1.91 | $0.85 | $0.48 | $0.38 |
| v15-8b-tp1-len8k | batch | $2.91 | $1.29 | $0.73 | $0.58 |
| v15-8b-tp1-len8k | chat | $1.92 | $0.85 | $0.48 | $0.38 |
| v15-8b-tp1-len8k | rag | $10.03 | $4.46 | $2.51 | $2.01 |
| v15-8b-tp1-len8k | think | $3.22 | $1.43 | $0.80 | $0.64 |

## What to say about this

1. State the operating point, not the peak. Every cost number above is anchored to a configuration that met an explicit latency SLO.

2. Report the optimization delta as a percentage move in $/1M tokens, not just tokens/sec. That is the language of the study.

3. Name the assumption that would flip your conclusion (usually utilization, then GPU hourly rate).

4. Cost is not the only axis: data residency, model openness (Apertus is Apache-2.0 with open data) and rate-limit headroom belong in the same table as dollars.

