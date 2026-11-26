#!/usr/bin/env python3
"""Analyze E3 same-park A/B/A. Reject mixed, incomplete or unstable windows."""
import argparse
import json
from pathlib import Path

KEYS = ('afk_profile_paint_calls', 'afk_profile_paint_cpu_ns', 'repaints',
        'java_ns', 'gc_ns', 'nso_core_frames', 'nso_core_faults',
        'scoped_native_draw_skips', 'scoped_vm_draw_skips')


def fields(s, sep=None):
    out = {}
    for part in s.split(sep):
        if '=' in part:
            k, v = part.split('=', 1)
            if k in out:
                raise ValueError('duplicate ' + k)
            out[k] = v
    return out


def num(d, k):
    v = d.get(k, '')
    if not v.isascii() or not v.isdecimal():
        raise ValueError('invalid ' + k)
    return int(v)


def analyze(text, run):
    rows = []
    for line in text.splitlines():
        if not line.startswith('run=' + run + ' '):
            continue
        pre, marker, tail = line.partition(' slots=[')
        r = fields(pre)
        if r.get('event') == 'sample' and marker and tail.endswith(']'):
            slots = tail[:-1].split(';')
            if len(slots) == 1 and slots[0]:
                rows.append((r, fields(slots[0], ',')))
    picked = [(r, s) for r, s in rows if s.get('core_aba_phase') in ('2','3','4','5','6')]
    if not picked:
        raise ValueError('no E3 measurement')
    identity = None
    prior = None
    groups = {2: [], 4: [], 6: []}
    seen = set()
    for r, s in picked:
        seq, phase, start = num(r,'seq'), num(s,'core_aba_phase'), num(s,'core_aba_start_ns')
        now, cpu = num(r,'mono_ns'), num(r,'process_cpu_ns')
        detail = num(r,'detail_mono_ns')
        elapsed = num(s,'core_aba_elapsed_ns')
        if phase != min(7, (elapsed//75_000_000_000)*2+1+(elapsed%75_000_000_000>=15_000_000_000)):
            raise ValueError('phase clock mismatch')
        cur = (r.get('build'),r.get('perf'),s.get('token'),start,r.get('thermal'),r.get('low_power'))
        if not all(cur) or (identity and cur != identity) or 'core-aba-1' not in cur[1].split('_'):
            raise ValueError('mixed owner, epoch, configuration or thermal/power state')
        identity = cur
        if any(r.get(k)!=v for k,v in [('process_cpu_ok','1'),('detail_count','1')]) or any(s.get(k)!=v for k,v in [('phase','2'),('stop','0'),('mode','1'),('cpu_ok','1'),('counters_ok','1'),('nso_core_armed','1'),('nso_core_rejected','0')]):
            raise ValueError('unstable mode or core rejected')
        if num(r,'gap_ns')>15_000_000_000 or abs(detail-now)>250_000_000 or abs(detail-start-elapsed)>250_000_000:
            raise ValueError('gap or stale detail sample')
        v = [num(s,k) for k in KEYS]
        if prior:
            ps, pp, pt, pc, pe, pv = prior
            if seq!=ps+1 or phase<pp or phase>pp+1 or now<=pt or now-pt>15_000_000_000 or elapsed<=pe or cpu<pc or any(x<y for x,y in zip(v,pv)):
                raise ValueError('missing/interleaved sample, gap or counter reset')
        prior = (seq,phase,now,cpu,elapsed,v)
        seen.add(phase)
        if phase in groups:
            groups[phase].append((now,cpu,v))
    if seen != {2,3,4,5,6}:
        raise ValueError('incomplete ABA including warmups')
    result = []
    for phase, label in [(2,'A1'),(4,'B'),(6,'A2')]:
        g = groups[phase]
        a,b = g[0],g[-1]
        wall = b[0]-a[0]
        if wall < 45_000_000_000 or wall > 60_000_000_000:
            raise ValueError('insufficient stable leg: '+label)
        p = b[1]-a[1]
        d = dict(zip(KEYS,(x-y for x,y in zip(b[2],a[2]))))
        frames=d['afk_profile_paint_calls']; paint=d['afk_profile_paint_cpu_ns']
        core=d['nso_core_frames']; skips=d['scoped_native_draw_skips']+d['scoped_vm_draw_skips']
        if not frames or paint>p or d['nso_core_faults'] or (phase==4 and (core<.95*frames or core>1.05*frames or not skips)) or (phase!=4 and (core or skips)):
            raise ValueError('candidate not actually exercised or mixed leg: '+label)
        result.append(dict(leg=label,seconds=wall/1e9,process_pct=100*p/wall,paint_pct=100*paint/wall,
                           paint_ms=paint/frames/1e6,paint_hz=frames*1e9/wall,
                           repaint_hz=d['repaints']*1e9/wall,java_pct=100*d['java_ns']/wall,gc_pct=100*d['gc_ns']/wall,
                           core_frames=core,scoped_skips=skips))
    a,b,c=result
    return {'run':run,'epoch':identity[3],'legs':result,
            'b_vs_a_mean_process_points':b['process_pct']-(a['process_pct']+c['process_pct'])/2,
            'a2_vs_a1_process_points':c['process_pct']-a['process_pct'],
            'limitations':['not randomized; scene/logic progression must be checked separately',
                           'process includes other app threads; Java and paint overlap',
                           'repaint rate is not gameplay proof; no automatic promotion']}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('log',type=Path)
    p.add_argument('--run',required=True)
    a=p.parse_args()
    try:
        print(json.dumps(analyze(a.log.read_text(encoding='utf-8'),a.run),indent=2))
    except ValueError as e:
        p.error(str(e))

if __name__=='__main__':
    main()
