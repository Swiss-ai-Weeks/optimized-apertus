#!/usr/bin/env python3
# Unified perf+energy probe for an OpenAI-compatible endpoint. Stdlib only.
# Writes results/<name>.json: {perf, energy, quality(slot for lm-eval), cost}.
import argparse, json, os, time, threading, subprocess, urllib.request, statistics
def power_sampler(stop, out):
    while not stop.is_set():
        try:
            o=subprocess.check_output(["nvidia-smi","--query-gpu=power.draw","--format=csv,noheader,nounits"],text=True)
            out.append(sum(float(x) for x in o.split()))
        except Exception: pass
        time.sleep(1)
def req(url, model, prompt, mt):
    body=json.dumps({"model":model,"messages":[{"role":"user","content":prompt}],"max_tokens":mt,"temperature":0.7}).encode()
    t0=time.time(); r=urllib.request.Request(url+"/v1/chat/completions",body,{"Content-Type":"application/json"})
    with urllib.request.urlopen(r,timeout=180) as resp: d=json.load(resp)
    return time.time()-t0, d.get("usage",{}).get("completion_tokens",0)
def main():
    p=argparse.ArgumentParser()
    p.add_argument("--url",required=True); p.add_argument("--model",required=True); p.add_argument("--name",required=True)
    p.add_argument("--concurrency",type=int,default=8); p.add_argument("--requests",type=int,default=32); p.add_argument("--max-tokens",type=int,default=256)
    p.add_argument("--out",default=os.path.expanduser("~/optimized-apertus/results"))
    a=p.parse_args(); prompt="Erklaere die Schweizer Demokratie ausfuehrlich in mehreren Saetzen."
    lat=[]; toks=[]; lock=threading.Lock(); q=list(range(a.requests)); stop=threading.Event(); ps=[]
    pt=threading.Thread(target=power_sampler,args=(stop,ps)); pt.start()
    def w():
        while True:
            with lock:
                if not q: return
                q.pop()
            try:
                dt,ct=req(a.url,a.model,prompt,a.max_tokens)
                with lock: lat.append(dt); toks.append(ct)
            except Exception:
                with lock: lat.append(None)
    t0=time.time(); T=[threading.Thread(target=w) for _ in range(a.concurrency)]
    [t.start() for t in T]; [t.join() for t in T]; wall=time.time()-t0; stop.set(); pt.join()
    ok=sorted(x for x in lat if x is not None); tt=sum(toks); aw=statistics.mean(ps) if ps else None
    res={"config":a.name,"model":a.model,"concurrency":a.concurrency,"requests":a.requests,
      "perf":{"tok_s":round(tt/wall,2) if wall else None,"p50_s":round(statistics.median(ok),3) if ok else None,
        "p99_s":round(ok[max(0,int(len(ok)*0.99)-1)],3) if ok else None,"wall_s":round(wall,2),"completion_tokens":tt,"errors":lat.count(None)},
      "energy":{"avg_gpu_w":round(aw,1) if aw else None,"tok_per_wh":round(tt/(aw*wall/3600),2) if aw and wall else None},
      "quality":{},"cost":{}}
    os.makedirs(a.out,exist_ok=True); fp=os.path.join(a.out,a.name+".json"); json.dump(res,open(fp,"w"),indent=2)
    print(json.dumps(res,indent=2)); print("wrote",fp)
main()
