#!/usr/bin/env python3
"""Collect AIPerf exports -> results/summary.csv, summary.md, and charts."""
import csv, glob, json, os, re, sys

RES = sys.argv[1] if len(sys.argv) > 1 else "results"
SLO = float(os.environ.get("TTFT_SLO_MS", "2000"))
ORDER = ["vllm-1g", "dyn-1w", "dyn-2w-rr", "dyn-2w-kv"]
WANT = {"ttft": "time_to_first_token", "itl": "inter_token_latency",
        "tok_s": "output_token_throughput", "req_s": "request_throughput",
        "e2e": "request_latency"}

def metrics_of(path):
    d = json.load(open(path))
    recs = d.get("records", d) if isinstance(d, dict) else d
    if isinstance(recs, list):
        recs = {r.get("tag", r.get("name", "")): r for r in recs if isinstance(r, dict)}
    return recs

def pick(recs, tag, stat):
    for k, v in recs.items():
        if k == tag and isinstance(v, dict):
            val = v.get(stat, v.get("avg"))
            return float(val) if val is not None else None
    return None

rows, seen = [], {}
files = sorted(glob.glob(f"{RES}/*/*/c*/**/*.json", recursive=True),
               key=lambda f: "profile_export" not in f)  # prefer the main export if several match
for f in files:
    if os.path.basename(f) != "profile_export_aiperf.json":
        continue
    m = re.search(r"/([^/]+)/([^/]+)/c(\d+)/", f[len(RES):] + "/")
    if not m: continue
    mode, sc, c = m.group(1), m.group(2), int(m.group(3))
    if (mode, sc, c) in seen: continue
    seen[(mode, sc, c)] = f
    try: r = metrics_of(f)
    except Exception as e: print("skip", f, e); continue
    row = dict(mode=mode, scenario=sc, concurrency=c,
               ttft_p50_ms=pick(r, WANT["ttft"], "p50"), ttft_p95_ms=pick(r, WANT["ttft"], "p95"),
               itl_avg_ms=pick(r, WANT["itl"], "avg"), e2e_p95_ms=pick(r, WANT["e2e"], "p95"),
               out_tok_s=pick(r, WANT["tok_s"], "avg"), req_s=pick(r, WANT["req_s"], "avg"))
    row["meets_slo"] = row["ttft_p95_ms"] is not None and row["ttft_p95_ms"] <= SLO
    rows.append(row)

if not rows: sys.exit(f"No AIPerf exports found under {RES}")
key = lambda r: (r["scenario"], ORDER.index(r["mode"]) if r["mode"] in ORDER else 9, r["concurrency"])
rows.sort(key=key)
with open(f"{RES}/summary.csv", "w", newline="") as fh:
    w = csv.DictWriter(fh, fieldnames=list(rows[0])); w.writeheader(); w.writerows(rows)

def fmt(x, n=0): return "-" if x is None else f"{x:,.{n}f}"
idx = {(r["mode"], r["scenario"], r["concurrency"]): r for r in rows}
md = [f"# Apertus 1.5 8B — Dynamo 1 vs 2 workers\n\np95 TTFT SLO = {SLO:.0f} ms (✗ = missed)\n"]
for sc in sorted({r["scenario"] for r in rows}):
    md += [f"\n## Scenario: {sc}\n", "| mode | conc | TTFT p50 | TTFT p95 | ITL avg | out tok/s | req/s | SLO |",
           "|---|---:|---:|---:|---:|---:|---:|:-:|"]
    for r in [r for r in rows if r["scenario"] == sc]:
        md.append(f"| {r['mode']} | {r['concurrency']} | {fmt(r['ttft_p50_ms'])} | {fmt(r['ttft_p95_ms'])} | "
                  f"{fmt(r['itl_avg_ms'],1)} | {fmt(r['out_tok_s'])} | {fmt(r['req_s'],2)} | {'✓' if r['meets_slo'] else '✗'} |")
    md += ["\n**Ratios (output tok/s)**\n", "| conc | dyn-1w / vllm-1g (overhead) | 2w-rr / 1w (2nd GPU) | 2w-kv / 2w-rr (router) | 2w-kv / 1w (total) |",
           "|---:|---:|---:|---:|---:|"]
    def ratio(a, b, c):
        x, y = idx.get((a, sc, c)), idx.get((b, sc, c))
        return f"{x['out_tok_s']/y['out_tok_s']:.2f}×" if x and y and x["out_tok_s"] and y["out_tok_s"] else "-"
    for c in sorted({r["concurrency"] for r in rows if r["scenario"] == sc}):
        md.append(f"| {c} | {ratio('dyn-1w','vllm-1g',c)} | {ratio('dyn-2w-rr','dyn-1w',c)} | "
                  f"{ratio('dyn-2w-kv','dyn-2w-rr',c)} | {ratio('dyn-2w-kv','dyn-1w',c)} |")
    best = {}
    for r in rows:
        if r["scenario"] == sc and r["meets_slo"] and r["out_tok_s"]:
            best[r["mode"]] = max(best.get(r["mode"], 0), r["out_tok_s"])
    if best:
        md += ["\n**Max throughput within SLO**\n"] + [f"- {m}: {v:,.0f} tok/s" for m, v in sorted(best.items(), key=lambda kv: ORDER.index(kv[0]) if kv[0] in ORDER else 9)]
open(f"{RES}/summary.md", "w").write("\n".join(md) + "\n")

try:
    import matplotlib; matplotlib.use("Agg"); import matplotlib.pyplot as plt
    for sc in sorted({r["scenario"] for r in rows}):
        fig, ax = plt.subplots(1, 2, figsize=(12, 4.5))
        for mode in ORDER:
            pts = [r for r in rows if r["scenario"] == sc and r["mode"] == mode and r["out_tok_s"]]
            if not pts: continue
            ax[0].plot([p["concurrency"] for p in pts], [p["out_tok_s"] for p in pts], "o-", label=mode)
            ax[1].plot([p["ttft_p95_ms"] or 0 for p in pts], [p["out_tok_s"] for p in pts], "o-", label=mode)
        ax[0].set(xscale="log", xlabel="concurrency", ylabel="output tok/s", title=f"{sc}: throughput")
        ax[1].axvline(SLO, ls="--", c="grey"); ax[1].set(xlabel="p95 TTFT (ms)", ylabel="output tok/s", title=f"{sc}: throughput vs latency")
        for a in ax: a.grid(alpha=.3); a.legend()
        fig.tight_layout(); fig.savefig(f"{RES}/chart_{sc}.png", dpi=130)
except ImportError:
    pass
print(open(f"{RES}/summary.md").read())
