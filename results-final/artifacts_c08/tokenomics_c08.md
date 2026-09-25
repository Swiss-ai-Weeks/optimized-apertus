# Apertus tokenomics

- Cost basis: **2 x H100-NVL-94GB** = $6.24/h on-demand, $3.26/h amortized-owned

- Utilization assumption: **45%** (730 h/month billed)

- Operating point: highest-throughput configuration that still met its p95 latency SLO.

- Unverified prices are flagged; see `tokenomics/prices.json`.


## Self-hosted cost per million tokens

| system | workload | conc | out tok/s | TTFT p95 (ms) | $/1M out (100% util) | $/1M out (@util) | $/1M blended (@util) |
|---|---|---:|---:|---:|---:|---:|---:|
| h100nvl-conf08-disagg-1p1d | agent | 4 | 658 | 931 | $2.64 | $5.86 | $2.79 |
| h100nvl-conf08-disagg-1p1d | batch | 128 | 595 | 35070 | $2.92 | $6.48 | $0.72 |
| h100nvl-conf08-disagg-1p1d | chat | 1 | 184 | 190 | $9.41 | $20.92 | $6.79 |
| h100nvl-conf08-disagg-1p1d | rag | 1 | 117 | 1148 | $14.83 | $32.95 | $1.92 |
| h100nvl-conf08-disagg-1p1d | summarize | 1 | 74 | 1780 | $23.54 | $52.30 | $1.35 |
| h100nvl-conf08-disagg-1p1d | think | 4 | 725 | 420 | $2.39 | $5.31 | $1.94 |

## Versus cloud token APIs

Break-even = monthly volume above which the self-hosted deployment is cheaper. Below it, pay per token.


### chat (ISL 512 / OSL 256)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf08-disagg-1p1d** | **$6.79** | - | - |
| frontier-api-tier1 ⚠ | $7.00 | 1.0x | 650.7 |
| open-weights-vendor-70b ⚠ | $0.67 | 0.1x | 6,832.8 |
| open-weights-vendor-8b ⚠ | $0.13 | 0.0x | 34,164.0 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### rag (ISL 4096 / OSL 256)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf08-disagg-1p1d** | **$1.92** | - | - |
| frontier-api-tier1 ⚠ | $3.71 | 1.9x | 1,229.2 |
| open-weights-vendor-70b ⚠ | $0.61 | 0.3x | 7,446.0 |
| open-weights-vendor-8b ⚠ | $0.11 | 0.1x | 43,021.3 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### summarize (ISL 7500 / OSL 200)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf08-disagg-1p1d** | **$1.35** | - | - |
| frontier-api-tier1 ⚠ | $3.31 | 2.4x | 1,375.5 |
| open-weights-vendor-70b ⚠ | $0.61 | 0.4x | 7,526.8 |
| open-weights-vendor-8b ⚠ | $0.10 | 0.1x | 44,398.8 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### agent (ISL 1024 / OSL 1024)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf08-disagg-1p1d** | **$2.79** | - | - |
| frontier-api-tier1 ⚠ | $9.00 | 3.2x | 506.1 |
| open-weights-vendor-70b ⚠ | $0.70 | 0.3x | 6,507.4 |
| open-weights-vendor-8b ⚠ | $0.15 | 0.1x | 30,368.0 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### batch (ISL 1024 / OSL 128)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf08-disagg-1p1d** | **$0.72** | - | - |
| frontier-api-tier1 ⚠ | $4.33 | 6.1x | 1,051.2 |
| open-weights-vendor-70b ⚠ | $0.62 | 0.9x | 7,320.9 |
| open-weights-vendor-8b ⚠ | $0.11 | 0.2x | 40,996.8 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

### think (ISL 512 / OSL 2048)

| comparator | $/1M blended | cloud ÷ self-host (<1 = cloud cheaper) | break-even (M tok/month) |
|---|---:|---:|---:|
| **self-host: h100nvl-conf08-disagg-1p1d** | **$1.94** | - | - |
| frontier-api-tier1 ⚠ | $12.60 | 6.5x | 361.5 |
| open-weights-vendor-70b ⚠ | $0.76 | 0.4x | 5,993.7 |
| open-weights-vendor-8b ⚠ | $0.18 | 0.1x | 25,306.7 |
| swisscom-apertus-v1.5-70b | _no price on file_ | - | - |

## Sensitivity to utilization

The single assumption that moves the answer most.

| system | workload | $/1M out @ 20% | $/1M out @ 45% | $/1M out @ 80% | $/1M out @ 100% |
|---|---|---:|---:|---:|---:|
| h100nvl-conf08-disagg-1p1d | agent | $13.18 | $5.86 | $3.29 | $2.64 |
| h100nvl-conf08-disagg-1p1d | batch | $14.58 | $6.48 | $3.64 | $2.92 |
| h100nvl-conf08-disagg-1p1d | chat | $47.06 | $20.92 | $11.77 | $9.41 |
| h100nvl-conf08-disagg-1p1d | rag | $74.14 | $32.95 | $18.54 | $14.83 |
| h100nvl-conf08-disagg-1p1d | summarize | $117.68 | $52.30 | $29.42 | $23.54 |
| h100nvl-conf08-disagg-1p1d | think | $11.96 | $5.31 | $2.99 | $2.39 |

## What to say about this

1. State the operating point, not the peak. Every cost number above is anchored to a configuration that met an explicit latency SLO.

2. Report the optimization delta as a percentage move in $/1M tokens, not just tokens/sec. That is the language of the study.

3. Name the assumption that would flip your conclusion (usually utilization, then GPU hourly rate).

4. Cost is not the only axis: data residency, model openness (Apertus is Apache-2.0 with open data) and rate-limit headroom belong in the same table as dollars.

