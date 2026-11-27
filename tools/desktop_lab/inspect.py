#!/usr/bin/env python3
"""Live/offline dashboard for the desktop lab's cumulative trace. No game data."""
import argparse
import csv
import json
import pathlib
import time

ROLES = {
    "Class_hpa.run": "Auto",
    "Class_hxb.run": "Game/update loop",
    "Class_hii.k1": "Map paint",
    "Class_hii.i3": "Map overlay",
    "Class_hii.r2": "Minimap",
    "Class_hac.a0": "HUD/UI paint",
    "Class_hda.a0": "Actor paint / skill progression",
    "Class_hda.n1": "Skill completion",
    "Class_hui.a": "Glyph paint",
    "Class_hxb.j1": "Background paint",
}
def role(method):
    return ROLES.get(method.split("(", 1)[0], "unclassified")
def report(path, window):
    with path.open() as f:
        rows = [r for r in csv.DictReader(f) if r.get("mode") in ("plain","graph")]
    if len(rows) < 2:
        return {"status": "waiting for complete samples"}
    b=rows[-1]
    a=next((r for r in reversed(rows[:-1]) if int(b["monotonic_ns"])-int(r["monotonic_ns"])>=window*1e9),rows[0])
    dt=int(b["monotonic_ns"])-int(a["monotonic_ns"])
    if dt<=0: raise ValueError("invalid monotonic interval")
    def delta(key):
        n=int(b[key])-int(a[key])
        if n<0: raise ValueError("counter reset: "+key)
        return n
    out={"seconds":round(dt/1e9,3),"mode":b["mode"],"cpu_one_core_pct":round(delta("process_cpu_ns")/dt*100,3),
         "paint_cpu_pct":round(delta("paint_cpu_ns")/dt*100,3),"gc_cpu_pct":round(delta("gc_cpu_ns")/dt*100,3),
         "paint_hz":round(delta("paints")*1e9/dt,2),"frames_hz":round(delta("frames")*1e9/dt,2),
         "draws_per_second":round(delta("draw_calls")*1e9/dt,2),"image_allocs_per_second":round(delta("image_allocs")*1e9/dt,2),
         "gc_cycles":delta("gc_cycles"),"input_events":delta("input_events"),"native_surface_bytes":int(b["native_surface_bytes"]),
         "benchmark_eligible":b["mode"]=="plain","note":"Paint is inclusive; graph mode perturbs execution. Role names are static hypotheses, not proof."}
    edge_path=pathlib.Path(str(path)+".edges.tsv")
    if edge_path.exists():
        with edge_path.open() as f: edges=list(csv.DictReader(f,delimiter="\t"))
        out["graph_overflow"]=sum(int(e["calls"]) for e in edges if e["caller"]=="<overflow>")
        edges=[e for e in edges if e["caller"]!="<overflow>"]
        out["top_edges"]=[dict(e, calls=int(e["calls"]), role=role(e["callee"])) for e in sorted(edges,key=lambda e:int(e["calls"]),reverse=True)[:20]]
    return out
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("trace",type=pathlib.Path);p.add_argument("--window",type=float,default=10);p.add_argument("--watch",action="store_true")
    a=p.parse_args()
    while True:
        try: print(json.dumps(report(a.trace,a.window),ensure_ascii=False,indent=2),flush=True)
        except FileNotFoundError:
            if not a.watch:raise
            print("Waiting for lab trace...",flush=True)
        if not a.watch:break
        time.sleep(2)
if __name__=="__main__":main()
