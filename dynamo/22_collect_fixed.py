#!/usr/bin/env python3
"""Flatten AIPerf / GenAI-Perf JSON exports into one tidy CSV.

The export schema has shifted between releases, so this parser is deliberately
tolerant: it walks the JSON, finds metric objects by name, and pulls whichever
of avg/p50/p95/p99 exist. If a metric is missing you get an empty cell rather
than a crash at 3am.

Usage
-----
  python3 bench/22_collect.py --root artifacts/bench -o artifacts/results.csv
  python3 bench/22_collect.py --check-slo <dir> --ttft-p95-ms 500 --itl-p95-ms 50
"""
from __future__ import annotations

import argparse
import csv
import json
import re
import sys
from pathlib import Path

# canonical name -> substrings that may appear in an export
METRICS = {
    "ttft_ms": ("time_to_first_token", "time to first token"),
    "itl_ms": ("inter_token_latency", "inter token latency"),
    "tpot_ms": ("time_per_output_token", "time per output token"),
    "e2e_ms": ("request_latency", "request latency"),
    "req_per_s": ("request_throughput", "request throughput"),
    "out_tok_per_s": ("output_token_throughput", "output token throughput"),
    "out_tok_per_s_per_user": ("output_token_throughput_per_user",
                               "output token throughput per user"),
}
STATS = ("avg", "p50", "p90", "p95", "p99", "min", "max")


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


def _walk(obj, out, path=()):
    """Collect every dict that looks like {stat: number} keyed by its name."""
    if isinstance(obj, dict):
        # AIPerf >=0.12 also exports a 'warmup_metrics' section with the SAME metric names;
        # without this line the warm-up values overwrite the real benchmark values.
        obj = {k: v for k, v in obj.items() if k != "warmup_metrics"}
        stat_like = {k: v for k, v in obj.items()
                     if _norm(k) in STATS and isinstance(v, (int, float))}
        if stat_like and path:
            out[_norm(path[-1])] = stat_like
        for k, v in obj.items():
            if isinstance(v, (int, float)) and not stat_like:
                out.setdefault(_norm(k), {})["avg"] = v
            _walk(v, out, path + (str(k),))
    elif isinstance(obj, list):
        for v in obj:
            _walk(v, out, path)


def load_metrics(run_dir: Path) -> dict:
    """Find the deepest *_aiperf.json / *_genai_perf.json under run_dir."""
    cands = sorted(run_dir.rglob("*aiperf.json")) + \
        sorted(run_dir.rglob("*genai_perf.json")) + \
        sorted(run_dir.rglob("profile_export*.json"))
    cands = [c for c in cands if "logs" not in c.parts]
    if not cands:
        return {}
    with cands[-1].open() as fh:
        try:
            raw = json.load(fh)
        except json.JSONDecodeError:
            return {}
    flat: dict = {}
    _walk(raw, flat)

    row: dict = {}
    for canon, aliases in METRICS.items():
        for alias in aliases:
            key = _norm(alias)
            if key in flat:
                for stat, val in flat[key].items():
                    row[f"{canon}_{_norm(stat)}"] = val
                break
    return row


def unit_fix(row: dict) -> dict:
    """AIPerf reports latencies in ms. If a value looks like seconds, scale it."""
    for k, v in list(row.items()):
        if k.endswith("_ms") or "_ms_" in k:
            if isinstance(v, (int, float)) and 0 < v < 1.0:
                row[k] = v * 1000.0
    return row


def collect(root: Path) -> list[dict]:
    rows = []
    # layout: artifacts/bench/<system>/<workload>/c<N>/...
    for cdir in sorted(root.glob("*/*/c*")):
        if not cdir.is_dir():
            continue
        system, workload = cdir.parent.parent.name, cdir.parent.name
        try:
            conc = int(cdir.name.lstrip("c"))
        except ValueError:
            continue
        m = load_metrics(cdir)
        if not m:
            print(f"  ! no metrics in {cdir}", file=sys.stderr)
            continue
        rows.append(unit_fix({"system": system, "workload": workload,
                              "concurrency": conc, **m}))
    return rows


def check_slo(run_dir: Path, ttft_p95: float, itl_p95: float) -> str:
    m = unit_fix(load_metrics(run_dir))
    if not m:
        return "unknown"
    t = m.get("ttft_ms_p95") or m.get("ttft_ms_avg")
    i = m.get("itl_ms_p95") or m.get("itl_ms_avg") or m.get("tpot_ms_p95")
    bad = []
    if ttft_p95 and t and t > ttft_p95:
        bad.append(f"ttft {t:.0f}>{ttft_p95:.0f}ms")
    if itl_p95 and i and i > itl_p95:
        bad.append(f"itl {i:.1f}>{itl_p95:.0f}ms")
    return "violated" if bad else "ok"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", type=Path, default=Path("artifacts/bench"))
    ap.add_argument("-o", "--out", type=Path, default=Path("artifacts/results.csv"))
    ap.add_argument("--check-slo", type=Path)
    ap.add_argument("--ttft-p95-ms", type=float, default=0)
    ap.add_argument("--itl-p95-ms", type=float, default=0)
    a = ap.parse_args()

    if a.check_slo:
        print(check_slo(a.check_slo, a.ttft_p95_ms, a.itl_p95_ms))
        return 0

    rows = collect(a.root)
    if not rows:
        print(f"no results under {a.root}", file=sys.stderr)
        return 1
    cols = ["system", "workload", "concurrency"]
    cols += sorted({k for r in rows for k in r} - set(cols))
    a.out.parent.mkdir(parents=True, exist_ok=True)
    with a.out.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {len(rows)} rows -> {a.out}")

    print("\nbest throughput per system/workload:")
    best: dict = {}
    for r in rows:
        k = (r["system"], r["workload"])
        tp = r.get("out_tok_per_s_avg", 0) or 0
        if tp > (best.get(k, {}).get("out_tok_per_s_avg", 0) or 0):
            best[k] = r
    for (s, w_), r in sorted(best.items()):
        print(f"  {s:28s} {w_:10s} c={r['concurrency']:<4} "
              f"{r.get('out_tok_per_s_avg', 0):8.1f} out tok/s  "
              f"ttft_p95={r.get('ttft_ms_p95', float('nan')):7.0f} ms")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
