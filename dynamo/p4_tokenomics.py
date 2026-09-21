#!/usr/bin/env python3
"""Tokenomics + phase-gate report for the P3/P4 profiles.

usage:  GPU_PRICE_PER_HOUR=<price of ONE GPU per hour> [CURRENCY=USD] ./p4_tokenomics.py [results_dir]

Rules (fixed before measuring, read from profiles/common.env):
  * a request is GOOD if TTFT <= SLO_TTFT_MS and its mean inter-token latency <= SLO_ITL_MS (AIPerf --goodput)
  * a concurrency level QUALIFIES if >= GOOD_FRACTION of its requests are good
  * capacity  = the highest useful output tokens/s among qualifying levels
  * cost      = GPU-seconds per 1M useful output tokens (price-free)  -> x price/3600 = cost per 1M tokens
  * P3 winner = lowest geometric-mean cost across all workloads (per GPU-hour, so 1 vs 2 GPUs is fair)
"""
import glob, json, math, os, re, sys

ROOT = os.path.dirname(os.path.abspath(__file__))
RES = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "results")

def env_file(path):
    out = {}
    for line in open(path):
        m = re.match(r'\s*([A-Z_0-9]+)=("?)([^"#\n]*)\2', line)
        if m: out[m.group(1)] = m.group(3).strip()
    return out

cfg = env_file(os.path.join(ROOT, "profiles", "common.env"))
SLO_TTFT, SLO_ITL = float(cfg["SLO_TTFT_MS"]), float(cfg["SLO_ITL_MS"])
GOOD_FRACTION = float(cfg.get("GOOD_FRACTION", "0.95"))
PRICE = float(os.environ["GPU_PRICE_PER_HOUR"]) if os.environ.get("GPU_PRICE_PER_HOUR") else None
CUR = os.environ.get("CURRENCY", "USD")
WORKLOADS = ["chat", "rag", "multiturn", "longprompt"]

def m(d, tag, stat="avg"):
    v = (d.get(tag) or {}).get(stat)
    return float(v) if v is not None else None

# ---------- load every run ----------
profiles, runs = {}, []
for pj in glob.glob(os.path.join(RES, "*", "profile.json")):
    p = json.load(open(pj)); profiles[p["tag"]] = p
    for f in glob.glob(os.path.join(os.path.dirname(pj), "*", "c*", "profile_export_aiperf.json")):
        wl, c = f.split(os.sep)[-3], int(f.split(os.sep)[-2][1:])
        d = json.load(open(f))
        req, good, tok = m(d, "request_throughput"), m(d, "goodput"), m(d, "output_token_throughput")
        if not req or tok is None: continue
        frac = min(1.0, (good or 0.0) / req)
        runs.append(dict(tag=p["tag"], wl=wl, c=c, n_gpus=p["n_gpus"], req=req, good_req=good or 0.0, frac=frac,
                         tok=tok, useful=tok * frac, ttft95=m(d, "time_to_first_token", "p95"),
                         itl95=m(d, "inter_token_latency", "p95"), itl99=m(d, "inter_token_latency", "p99"),
                         isl=m(d, "input_sequence_length"), osl=m(d, "output_sequence_length")))
if not runs: sys.exit(f"No profile results under {RES} (expected <tag>/profile.json and <tag>/<workload>/c<N>/profile_export_aiperf.json)")

def best(tag, wl):
    q = [r for r in runs if r["tag"] == tag and r["wl"] == wl and r["frac"] >= GOOD_FRACTION and r["useful"] > 0]
    return max(q, key=lambda r: r["useful"]) if q else None

def gpu_s_per_m(r): return r["n_gpus"] * 1e6 / r["useful"]
def fmt(x, n=0): return "-" if x is None else f"{x:,.{n}f}"
def order(tag): return (re.sub(r"-.*", "", tag), tag)

tags = sorted({r["tag"] for r in runs}, key=order)
L = [f"# Tokenomics — Apertus v1.5 8B (FP8) on Dynamo\n",
     f"Good request: TTFT ≤ {SLO_TTFT:.0f} ms and mean ITL ≤ {SLO_ITL:.0f} ms. A load level counts only if ≥ {GOOD_FRACTION:.0%} of requests are good.  ",
     f"Cost basis: {'%s %.2f per GPU-hour' % (CUR, PRICE) if PRICE else 'GPU-seconds per 1M tokens (set GPU_PRICE_PER_HOUR for money)'}.\n"]

# ---------- capacity & cost per workload ----------
for wl in WORKLOADS:
    rows = [(t, best(t, wl)) for t in tags if any(r["tag"] == t and r["wl"] == wl for r in runs)]
    if not rows: continue
    L += [f"\n## {wl}\n", f"| config | GPUs | best load in SLO | useful tok/s | tok/s per GPU | TTFT p95 ms | ITL p99 ms | GPU-s per 1M tok | {CUR} per 1M tok |",
          "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for t, b in rows:
        n = profiles[t]["n_gpus"]
        if b is None:
            L.append(f"| {t} | {n} | none within SLO | - | - | - | - | - | - |"); continue
        g = gpu_s_per_m(b)
        L.append(f"| {t} | {n} | {b['c']} | {fmt(b['useful'])} | {fmt(b['useful']/n)} | {fmt(b['ttft95'])} | {fmt(b['itl99'],1)} | "
                 f"{fmt(g)} | {fmt(g/3600*PRICE,3) if PRICE else '-'} |")

# ---------- P3 gate ----------
def score(tag):
    vals = [best(tag, wl) for wl in WORKLOADS]
    if any(v is None for v in vals): return None
    return math.exp(sum(math.log(gpu_s_per_m(v)) for v in vals) / len(vals))
p3 = [t for t in tags if profiles[t].get("phase") == "P3"]
if p3:
    L += ["\n## Phase-3 gate (lowest cost per GPU-hour wins)\n", "| config | GPUs | geo-mean GPU-s per 1M tok (all 4 workloads) | relative |", "|---|---:|---:|---:|"]
    scored = sorted([(score(t), t) for t in p3 if score(t) is not None])
    for s, t in scored:
        L.append(f"| {t} | {profiles[t]['n_gpus']} | {fmt(s)} | {s/scored[0][0]:.2f}x |")
    missing = [t for t in p3 if score(t) is None]
    if missing: L.append(f"\nNot scored (a workload had no load level within SLO, or is missing): {', '.join(missing)}")
    if scored:
        w = profiles[scored[0][1]]
        router = w.get("router") or "kv"
        L += [f"\n**Winner: {w['tag']}** — {w['desc']}\n",
              "Carry forward into `profiles/p3_winner.env`:\n", "```", f"P3_WINNER={w['tag']}", f"P3_ROUTER={router}", f"P3_MAX_NUM_SEQS={w['max_num_seqs']}", "```"]
        if w["kind"] == "vllm":
            L.append("\n(Winner is standalone vLLM. C07/C08 still need Dynamo on 2 GPUs; they inherit its batch size, router defaults to kv.)")

# ---------- P4: disaggregation vs same-session control ----------
p4 = [t for t in tags if profiles[t].get("phase") == "P4"]
if p4:
    L += ["\n## Phase-4: disaggregated vs aggregated control (same load levels)\n"]
    for wl in WORKLOADS:
        cs = sorted({r["c"] for r in runs if r["wl"] == wl and r["tag"] in p4})
        if not cs: continue
        L += [f"\n**{wl}** — useful tok/s · TTFT p95 ms · ITL p99 ms\n", "| load | " + " | ".join(p4) + " |", "|---:|" + "---:|" * len(p4)]
        for c in cs:
            cells = []
            for t in p4:
                r = next((x for x in runs if x["tag"] == t and x["wl"] == wl and x["c"] == c), None)
                cells.append("-" if r is None else f"{fmt(r['useful'])} · {fmt(r['ttft95'])} · {fmt(r['itl99'],1)}")
            L.append(f"| {c} | " + " | ".join(cells) + " |")

# ---------- cloud comparison (only with verified prices) ----------
cp = os.path.join(ROOT, "cloud_prices.json")
if PRICE and os.path.exists(cp):
    apis = [a for a in json.load(open(cp)).get("apis", []) if a.get("verified") and a.get("input_per_1m") is not None]
    if apis:
        L += [f"\n## Self-hosted vs cloud APIs — cost per 1,000 requests ({CUR})\n",
              "| workload | best self-hosted config | self-hosted | " + " | ".join(a["name"] for a in apis) + " |",
              "|---|---|---:|" + "---:|" * len(apis)]
        for wl in WORKLOADS:
            cands = [(t, best(t, wl)) for t in tags]; cands = [(t, b) for t, b in cands if b and b["good_req"] > 0]
            if not cands: continue
            t, b = min(cands, key=lambda x: x[1]["n_gpus"] / x[1]["good_req"])
            self_cost = b["n_gpus"] * PRICE / 3600 / b["good_req"] * 1000
            api = [(b["isl"] * a["input_per_1m"] + b["osl"] * a["output_per_1m"]) / 1e6 * 1000 for a in apis]
            L.append(f"| {wl} | {t} | {self_cost:,.3f} | " + " | ".join(f"{x:,.3f}" for x in api) + " |")
        L.append("\nSelf-hosted assumes the GPUs are fully used at that load; at lower utilisation divide by the utilisation fraction.")
    else:
        L.append("\n(cloud_prices.json has no entries marked \"verified\": true — no cloud comparison printed.)")

with open(os.path.join(RES, "all_runs.csv"), "w") as fh:
    keys = list(runs[0]); fh.write(",".join(keys) + "\n")
    for r in sorted(runs, key=lambda r: (order(r["tag"]), r["wl"], r["c"])): fh.write(",".join(str(r[k]) for k in keys) + "\n")
open(os.path.join(RES, "tokenomics.md"), "w").write("\n".join(L) + "\n")
print("\n".join(L))
