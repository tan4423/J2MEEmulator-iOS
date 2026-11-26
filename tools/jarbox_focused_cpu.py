#!/usr/bin/env python3
"""Use the existing E3 gate, then attribute CPU to Canvas and GC phases."""
import argparse
import json
from pathlib import Path
from jarbox_aba import analyze, fields, num

PHASES = ('pause', 'roots', 'mark', 'resume', 'deferred', 'sweep')
GC = tuple('gc_phase_' + k for k in ('cycles', 'busy', 'invalid', 'aborted', 'scanned', 'reclaimed', 'freed_bytes')) + tuple('gc_phase_' + p + '_' + k + '_ns' for p in PHASES for k in ('cpu', 'wall'))
CANVAS = tuple('canvas_phase_' + k for k in ('frames', 'pre_ns', 'paint_ns', 'post_ns', 'invalid', 'busy'))
PROFILE = ('core-aba-1', 'ninja-core-1', 'native-paint-diag-0', 'region-stage-0',
           'hotspot-0', 'gc-phase-1', 'canvas-phase-1', 'crop-v2-1',
           'array-mode1-0', 'char-leaf-0', 'binary-sprite-0', 'paint-qos-0',
           'decoded-int-0', 'event-sleep-0', 'const-arith-0', 'const-branch-0')


def focused(text, run):
    report = analyze(text, run)
    groups = {2: [], 4: [], 6: []}
    for line in text.splitlines():
        if not line.startswith('run=' + run + ' '):
            continue
        pre, marker, tail = line.partition(' slots=[')
        r = fields(pre)
        if r.get('event') != 'sample' or not marker or not tail.endswith(']') or ';' in tail:
            continue
        s = fields(tail[:-1], ',')
        if s.get('core_aba_phase') not in ('2', '4', '6'):
            continue
        profile = r.get('perf', '').split('_')
        if set(profile) != set(PROFILE) or len(profile) != len(PROFILE):
            raise ValueError('not the focused low-observer build')
        groups[int(s['core_aba_phase'])].append(s)
    for phase, leg in zip((2, 4, 6), report['legs']):
        rows = groups[phase]
        wall = leg['seconds'] * 1e9
        # Incomplete phase snapshots must not invalidate the original E3 result.
        # Report the lost coverage explicitly; never fill with zero.
        for name, keys, ok in [('gc', GC, 'gc_phase_ok'), ('canvas', CANVAS, 'canvas_phase_ok')]:
            if any(s.get(ok) != '1' for s in rows):
                leg[name + '_detail'] = {'valid': False, 'reason': 'snapshot unavailable'}
                continue
            values = [[num(s, k) for k in keys] for s in rows]
            if any(any(x < y for x, y in zip(b, a)) for a, b in zip(values, values[1:])):
                raise ValueError('phase counter reset')
            d = dict(zip(keys, (b-a for a,b in zip(values[0], values[-1]))))
            if name == 'gc':
                n = d['gc_phase_cycles']
                coverage = n / leg['gc_cycles'] if leg['gc_cycles'] else None
                valid = (n > 0 and coverage is not None and .95 <= coverage <= 1.05 and
                         not d['gc_phase_invalid'] and not d['gc_phase_aborted'])
                cpu = {p: d['gc_phase_'+p+'_cpu_ns'] for p in PHASES}
                leg['gc_detail'] = dict(valid=valid, cycles=n, coverage=coverage,
                    busy=d['gc_phase_busy'], invalid=d['gc_phase_invalid'], aborted=d['gc_phase_aborted'],
                    scanned=d['gc_phase_scanned'], reclaimed=d['gc_phase_reclaimed'],
                    freed_bytes=d['gc_phase_freed_bytes'],
                    cpu_pct={p:100*v/wall for p,v in cpu.items()},
                    cpu_ms_per_cycle={p:v/n/1e6 for p,v in cpu.items()} if n else None,
                    wall_ms_per_cycle={p:d['gc_phase_'+p+'_wall_ns']/n/1e6 for p in PHASES} if n else None,
                    worker_minus_phases_pct=leg['gc_pct']-100*sum(cpu.values())/wall)
            else:
                n = d['canvas_phase_frames']
                coverage = n/(leg['paint_hz']*leg['seconds'])
                parts = {p: d['canvas_phase_'+p+'_ns'] for p in ('pre','paint','post')}
                pct = {p:100*v/wall for p,v in parts.items()}
                valid = n>0 and .98<=coverage<=1.02 and not d['canvas_phase_invalid']
                leg['canvas_detail'] = dict(valid=valid, frames=n, coverage=coverage,
                    busy=d['canvas_phase_busy'], invalid=d['canvas_phase_invalid'],
                    cpu_pct=pct, cpu_ms_per_frame={p:v/n/1e6 for p,v in parts.items()} if n else None,
                    java_minus_canvas_pct=leg['java_pct']-sum(pct.values()))
    report['limitations'] += ['GC detail covers completed collection phases only; worker residual is arithmetic, not a direct category',
        'Canvas scope excludes admission and final notification; Java minus Canvas is arithmetic, not direct game logic',
        'ignore phase breakdown where valid=false; endpoint races and observer costs remain']
    return report


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('log', type=Path)
    p.add_argument('--run', required=True)
    a = p.parse_args()
    try:
        print(json.dumps(focused(a.log.read_text(encoding='utf-8'), a.run), indent=2))
    except ValueError as e:
        p.error(str(e))
