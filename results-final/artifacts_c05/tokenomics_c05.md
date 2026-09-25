# Apertus tokenomics

- Cost basis: **1 x H100-NVL-94GB** = $3.12/h on-demand, $1.63/h amortized-owned

- Utilization assumption: **45%** (730 h/month billed)

- Operating point: highest-throughput configuration that still met its p95 latency SLO.

- Unverified prices are flagged; see `tokenomics/prices.json`.


## Self-hosted cost per million tokens

| system | workload | conc | out tok/s | TTFT p95 (ms) | $/1M out (100% util) | $/1M out (@util) | $/1M blended (@util) |
|---|---|---:|---:|---:|---:|---:|---:|
| p3-c05-dynamo1w-fp8weights-fp8kv | agent | 16 | 2,451 | 474 | $0.35 | $0.79 | $0.38 |
| p3-c05-dynamo1w-fp8weights-fp8kv | batch | 128 | 3,065 | 3806 | $0.28 | $0.63 | $0.07 |
| p3-c05-dynamo1w-fp8weights-fp8kv | chat | 16 | 2,405 | 258 | $0.36 | $0.80 | $0.26 |
| p3-c05-dynamo1w-fp8weights-fp8kv | rag | 16 | 1,147 | 1692 | $0.76 | $1.68 | $0.10 |
| p3-c05-dynamo1w-fp8weights-fp8kv | summarize | 16 | 610 | 2808 | $1.42 | $3.15 | $0.08 |
| p3-c05-dynamo1w-fp8weights-fp8kv | think | 16 | 2,028 | 272 | $0.43 | $0.95 | $0.37 |

## Versus cloud token APIs

Break-even = monthly volume above which the self-hosted deployment is cheaper. Below it, pay per token.


### chat (ISL 512 / OSL 256)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: p3-c05-dynamo1w-fp8weights-fp8kv** | **$0.26** | - | - |
| frontier-api-tier1 ⚠ | $7.00 | 26.8x | 325.4 |
| open-weights-vendor-70b ⚠ | $0.67 | 2.6x | 3,416.4 |
| open-weights-vendor-8b ⚠ | $0.13 | 0.5x | 17,082.0 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### rag (ISL 4096 / OSL 256)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: p3-c05-dynamo1w-fp8weights-fp8kv** | **$0.10** | - | - |
| frontier-api-tier1 ⚠ | $3.71 | 37.7x | 614.6 |
| open-weights-vendor-70b ⚠ | $0.61 | 6.2x | 3,723.0 |
| open-weights-vendor-8b ⚠ | $0.11 | 1.1x | 21,510.7 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### summarize (ISL 7500 / OSL 200)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: p3-c05-dynamo1w-fp8weights-fp8kv** | **$0.08** | - | - |
| frontier-api-tier1 ⚠ | $3.31 | 40.7x | 687.7 |
| open-weights-vendor-70b ⚠ | $0.61 | 7.4x | 3,763.4 |
| open-weights-vendor-8b ⚠ | $0.10 | 1.3x | 22,199.4 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### agent (ISL 1024 / OSL 1024)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: p3-c05-dynamo1w-fp8weights-fp8kv** | **$0.38** | - | - |
| frontier-api-tier1 ⚠ | $9.00 | 23.5x | 253.1 |
| open-weights-vendor-70b ⚠ | $0.70 | 1.8x | 3,253.7 |
| open-weights-vendor-8b ⚠ | $0.15 | 0.4x | 15,184.0 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### batch (ISL 1024 / OSL 128)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: p3-c05-dynamo1w-fp8weights-fp8kv** | **$0.07** | - | - |
| frontier-api-tier1 ⚠ | $4.33 | 62.2x | 525.6 |
| open-weights-vendor-70b ⚠ | $0.62 | 8.9x | 3,660.4 |
| open-weights-vendor-8b ⚠ | $0.11 | 1.6x | 20,498.4 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### think (ISL 512 / OSL 2048)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: p3-c05-dynamo1w-fp8weights-fp8kv** | **$0.37** | - | - |
| frontier-api-tier1 ⚠ | $12.60 | 34.2x | 180.8 |
| open-weights-vendor-70b ⚠ | $0.76 | 2.1x | 2,996.8 |
| open-weights-vendor-8b ⚠ | $0.18 | 0.5x | 12,653.3 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

## Sensitivity to utilization

The single assumption that moves the answer most.

| system | workload | $/1M out @ 20% | $/1M out @ 45% | $/1M out @ 80% | $/1M out @ 100% |
|---|---|---:|---:|---:|---:|
| p3-c05-dynamo1w-fp8weights-fp8kv | agent | $1.77 | $0.79 | $0.44 | $0.35 |
| p3-c05-dynamo1w-fp8weights-fp8kv | batch | $1.41 | $0.63 | $0.35 | $0.28 |
| p3-c05-dynamo1w-fp8weights-fp8kv | chat | $1.80 | $0.80 | $0.45 | $0.36 |
| p3-c05-dynamo1w-fp8weights-fp8kv | rag | $3.78 | $1.68 | $0.94 | $0.76 |
| p3-c05-dynamo1w-fp8weights-fp8kv | summarize | $7.10 | $3.15 | $1.77 | $1.42 |
| p3-c05-dynamo1w-fp8weights-fp8kv | think | $2.14 | $0.95 | $0.53 | $0.43 |

## What to say about this

1. State the operating point, not the peak. Every cost number above is anchored to a configuration that met an explicit latency SLO.

2. Report the optimization delta as a percentage move in $/1M tokens, not just tokens/sec. That is the language of the study.

3. Name the assumption that would flip your conclusion (usually utilization, then GPU hourly rate).

4. Cost is not the only axis: data residency, model openness (Apertus is Apache-2.0 with open data) and rate-limit headroom belong in the same table as dollars.

