#!/usr/bin/env python3
import json, glob, os
rows=[]
for f in sorted(glob.glob(os.path.expanduser("~/optimized-apertus/results/*.json"))):
    d=json.load(open(f)); p=d.get("perf",{}); e=d.get("energy",{}); qd=d.get("quality",{})
    rows.append((str(d.get("config")),str(p.get("tok_s")),str(p.get("p50_s")),str(p.get("p99_s")),str(e.get("avg_gpu_w")),str(e.get("tok_per_wh")),(",".join(f"{k}={v}" for k,v in qd.items()) or "-")))
h=("config","tok/s","p50s","p99s","gpuW","tok/Wh","quality")
w=[max(len(r[i]) for r in ([h]+rows)) for i in range(len(h))] if rows else [len(x) for x in h]
pl=lambda r: print("  ".join(str(x).ljust(w[i]) for i,x in enumerate(r)))
pl(h); pl(tuple("-"*x for x in w)); [pl(r) for r in rows]
