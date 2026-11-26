#!/usr/bin/env python3
"""Analyze one stable single-VM mode-1 Flight Recorder E2 window.

Explicit endpoints, cumulative deltas, fail closed on missing/invalid counters.
No imputation; native shares refer only to selected inclusive native calls.
"""
import argparse
import json
from pathlib import Path


def fields(text, sep=None):
    result = {}
    for item in text.split(sep):
        if '=' not in item:
            continue
        k, v = item.split('=', 1)
        if k in result:
            raise ValueError('duplicate field: ' + k)
        result[k] = v
    return result


def number(row, key):
    value = row.get(key, '')
    if not value.isascii() or not value.isdecimal():
        raise ValueError('missing or invalid counter: ' + key)
    return int(value)


def analyze(text, run, first, last):
    if first >= last:
        raise ValueError('endpoints must be increasing')
    records = []
    for line in text.splitlines():
        if not line.startswith('run=' + run + ' '):
            continue
        prefix, marker, tail = line.partition(' slots=[')
        row = fields(prefix)
        seq = number(row, 'seq')
        if first <= seq <= last:
            if row.get('event') != 'sample' or not marker or not tail.endswith(']'):
                raise ValueError('intervening non-sample event or malformed sample')
            slots = tail[:-1].split(';')
            if len(slots) != 1 or not slots[0]:
                raise ValueError('requires exactly one VM')
            slot = fields(slots[0], ',')
            records.append((seq, row, slot))
    if len(records) != last - first + 1 or any(r[0] != first+i for i, r in enumerate(records)):
        raise ValueError('missing, duplicate or unordered sample sequence')
    identity = None
    keys = ('runner_ns', 'java_ns', 'gc_ns', 'gc_aborts', 'repaints',
            'afk_profile_paint_calls', 'afk_profile_paint_cpu_ns',
            'native_diag_seen', 'native_diag_selected_frames',
            'native_diag_selected_cpu_ns', 'native_diag_plain_frames',
            'native_diag_plain_cpu_ns', 'native_diag_discarded_frames',
            'native_diag_draw_calls', 'native_diag_draw_ns',
            'native_diag_lcd_other_ns', 'native_diag_other_ns',
            'compatible_crop_hits', 'compatible_crop_misses')
    previous = None
    for _, row, slot in records:
        current = (row.get('build'), row.get('perf'), slot.get('token'))
        if not all(current) or (identity and current != identity):
            raise ValueError('build, config or owner changed')
        identity = current
        if 'native-paint-diag-1' not in current[1].split('_'):
            raise ValueError('native paint diagnostic not enabled')
        if any(row.get(k) != v for k, v in [('process_cpu_ok', '1'), ('detail_count', '1')]) or any(slot.get(k) != v for k, v in [('phase', '2'), ('stop', '0'), ('mode', '1'), ('cpu_ok', '1'), ('counters_ok', '1')]):
            raise ValueError('invalid sample or not stable mode 1')
        if number(row, 'gap_ns') > 15_000_000_000:
            raise ValueError('possible suspension gap')
        values = [number(row, k) for k in ('mono_ns', 'process_cpu_ns')] + [number(slot, k) for k in keys]
        if previous and (values[0] <= previous[0] or any(v < p for v, p in zip(values[1:], previous[1:]))):
            raise ValueError('nonmonotonic time or counter reset')
        previous = values
    _, a, sa = records[0]
    _, b, sb = records[-1]
    elapsed = number(b, 'mono_ns') - number(a, 'mono_ns')
    process = number(b, 'process_cpu_ns') - number(a, 'process_cpu_ns')
    d = {k: number(sb, k) - number(sa, k) for k in keys}
    selected, plain = d['native_diag_selected_frames'], d['native_diag_plain_frames']
    scpu, pcpu = d['native_diag_selected_cpu_ns'], d['native_diag_plain_cpu_ns']
    paint = d['afk_profile_paint_cpu_ns']
    categories = {k: d['native_diag_' + k + '_ns'] for k in ('draw', 'lcd_other', 'other')}
    if not selected or not plain or not scpu or not pcpu or sum(categories.values()) > scpu:
        raise ValueError('insufficient or inconsistent native timing')
    if paint > process or d['native_diag_discarded_frames'] or selected + plain != d['afk_profile_paint_calls']:
        raise ValueError('inconsistent frame totals or discarded frames; choose another window')
    if scpu + pcpu != paint:
        raise ValueError('inconsistent paint CPU totals (snapshots may race)')
    categories['unclassified'] = scpu - sum(categories.values())
    hits, misses = d['compatible_crop_hits'], d['compatible_crop_misses']
    return {'build': identity[0], 'perf': identity[1], 'token': identity[2], 'run': run,
            'seq': [first, last], 'elapsed_s': elapsed / 1e9,
            'process_pct': 100 * process / elapsed, 'paint_pct': 100 * paint / elapsed,
            'paint_share_pct': 100 * paint / process, 'outside_paint_pct': 100 * (process-paint) / elapsed,
            'worker_pct': {k: 100*d[k]/elapsed for k in ('runner_ns','java_ns','gc_ns')},
            'paint_frames': selected+plain, 'paint_hz': (selected+plain)*1e9/elapsed,
            'selected_frames': selected, 'plain_frames': plain,
            'selected_ms': scpu/selected/1e6, 'plain_ms': pcpu/plain/1e6,
            'selected_plain_ratio': (scpu/selected)/(pcpu/plain),
            'selected_native_share_pct': {k: 100*v/scpu for k,v in categories.items()},
            'crop_hit_pct': 100*hits/(hits+misses) if hits+misses else None,
            'crop_misses_per_s': misses*1e9/elapsed, 'gc_aborts': d['gc_aborts'],
            'limitations': ['persisted samples cannot rule out unrecorded transitions or suspension',
                            'selected native shares are inclusive and observer-biased, not pure raster',
                            'paint overlaps Java worker CPU; do not sum',
                            'repaint cadence does not prove gameplay progress']}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('log', type=Path)
    p.add_argument('--run', required=True)
    p.add_argument('--first', type=int, required=True)
    p.add_argument('--last', type=int, required=True)
    args = p.parse_args()
    try:
        print(json.dumps(analyze(args.log.read_text(encoding='utf-8'), args.run, args.first, args.last), indent=2))
    except ValueError as e:
        p.error(str(e))


if __name__ == '__main__':
    main()
