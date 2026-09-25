# Apertus tokenomics

- Cost basis: **2 x H100-NVL-94GB** = $6.24/h on-demand, $3.26/h amortized-owned

- Utilization assumption: **45%** (730 h/month billed)

- Operating point: highest-throughput configuration that still met its p95 latency SLO.

- Unverified prices are flagged; see `tokenomics/prices.json`.


## Self-hosted cost per million tokens

| system | workload | conc | out tok/s | TTFT p95 (ms) | $/1M out (100% util) | $/1M out (@util) | $/1M blended (@util) |
|---|---|---:|---:|---:|---:|---:|---:|
| h100nvl-conf07 | agent | 64 | 7,671 | 857 | $0.23 | $0.50 | $0.24 |
| h100nvl-conf07 | batch | 128 | 6,043 | 1676 | $0.29 | $0.64 | $0.07 |
| h100nvl-conf07 | chat | 64 | 7,964 | 462 | $0.22 | $0.48 | $0.16 |
| h100nvl-conf07 | rag | 16 | 1,633 | 911 | $1.06 | $2.36 | $0.14 |
| h100nvl-conf07 | summarize | 16 | 1,011 | 1697 | $1.71 | $3.81 | $0.10 |
| h100nvl-conf07 | think | 64 | 5,972 | 476 | $0.29 | $0.65 | $0.21 |

## Versus cloud token APIs

Break-even = monthly volume above which the self-hosted deployment is cheaper. Below it, pay per token.


### chat (ISL 512 / OSL 256)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf07** | **$0.16** | - | - |
| frontier-api-tier1 ⚠ | $7.00 | 44.0x | 650.7 |
| open-weights-vendor-70b ⚠ | $0.67 | 4.2x | 6,832.8 |
| open-weights-vendor-8b ⚠ | $0.13 | 0.8x | 34,164.0 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### rag (ISL 4096 / OSL 256)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf07** | **$0.14** | - | - |
| frontier-api-tier1 ⚠ | $3.71 | 27.3x | 1,229.2 |
| open-weights-vendor-70b ⚠ | $0.61 | 4.5x | 7,446.0 |
| open-weights-vendor-8b ⚠ | $0.11 | 0.8x | 43,021.3 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### summarize (ISL 7500 / OSL 200)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf07** | **$0.10** | - | - |
| frontier-api-tier1 ⚠ | $3.31 | 33.7x | 1,375.5 |
| open-weights-vendor-70b ⚠ | $0.61 | 6.2x | 7,526.8 |
| open-weights-vendor-8b ⚠ | $0.10 | 1.0x | 44,398.8 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### agent (ISL 1024 / OSL 1024)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf07** | **$0.24** | - | - |
| frontier-api-tier1 ⚠ | $9.00 | 37.4x | 506.1 |
| open-weights-vendor-70b ⚠ | $0.70 | 2.9x | 6,507.4 |
| open-weights-vendor-8b ⚠ | $0.15 | 0.6x | 30,368.0 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### batch (ISL 1024 / OSL 128)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf07** | **$0.07** | - | - |
| frontier-api-tier1 ⚠ | $4.33 | 61.5x | 1,051.2 |
| open-weights-vendor-70b ⚠ | $0.62 | 8.8x | 7,320.9 |
| open-weights-vendor-8b ⚠ | $0.11 | 1.6x | 40,996.8 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### think (ISL 512 / OSL 2048)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf07** | **$0.21** | - | - |
| frontier-api-tier1 ⚠ | $12.60 | 58.7x | 361.5 |
| open-weights-vendor-70b ⚠ | $0.76 | 3.5x | 5,993.7 |
| open-weights-vendor-8b ⚠ | $0.18 | 0.8x | 25,306.7 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

## Sensitivity to utilization

The single assumption that moves the answer most.

| system | workload | $/1M out @ 20% | $/1M out @ 45% | $/1M out @ 80% | $/1M out @ 100% |
|---|---|---:|---:|---:|---:|
| h100nvl-conf07 | agent | $1.13 | $0.50 | $0.28 | $0.23 |
| h100nvl-conf07 | batch | $1.43 | $0.64 | $0.36 | $0.29 |
| h100nvl-conf07 | chat | $1.09 | $0.48 | $0.27 | $0.22 |
| h100nvl-conf07 | rag | $5.31 | $2.36 | $1.33 | $1.06 |
| h100nvl-conf07 | summarize | $8.57 | $3.81 | $2.14 | $1.71 |
| h100nvl-conf07 | think | $1.45 | $0.65 | $0.36 | $0.29 |

## What to say about this

1. State the operating point, not the peak. Every cost number above is anchored to a configuration that met an explicit latency SLO.

2. Report the optimization delta as a percentage move in $/1M tokens, not just tokens/sec. That is the language of the study.

3. Name the assumption that would flip your conclusion (usually utilization, then GPU hourly rate).

4. Cost is not the only axis: data residency, model openness (Apertus is Apache-2.0 with open data) and rate-limit headroom belong in the same table as dollars.

