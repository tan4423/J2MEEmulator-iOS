import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jarbox_focused_cpu import focused, PROFILE, PHASES
from test_jarbox_aba import fixture


def log():
    rows=[]
    for n,r in enumerate(fixture(),1):
        r=r.replace('perf=core-aba-1','perf='+'_'.join(PROFILE))
        r=r.replace('gc_ns=0,','gc_ns='+str(n*100_000_000)+',')
        d=dict(gc_phase_ok=1,gc_phase_cycles=n*10,gc_phase_busy=0,gc_phase_invalid=0,
               gc_phase_aborted=0,gc_phase_scanned=n*1000,gc_phase_reclaimed=n*500,gc_phase_freed_bytes=n*10000,
               canvas_phase_ok=1,canvas_phase_frames=n*125,canvas_phase_pre_ns=n*50_000_000,
               canvas_phase_post_ns=n*50_000_000,canvas_phase_invalid=0,canvas_phase_busy=0)
        d['canvas_phase_paint_ns']=int(r.split('afk_profile_paint_cpu_ns=')[1].split(',')[0])
        for p in PHASES:
            d['gc_phase_'+p+'_cpu_ns']=n*10_000_000
            d['gc_phase_'+p+'_wall_ns']=n*20_000_000
        rows.append(r[:-1]+','+','.join(k+'='+str(v) for k,v in d.items())+']')
    return '\n'.join(rows)


class FocusedTest(unittest.TestCase):
    def test_valid(self):
        report=focused(log(),'r')
        for leg in report['legs']:
            self.assertTrue(leg['gc_detail']['valid'])
            self.assertTrue(leg['canvas_detail']['valid'])
            self.assertEqual(leg['gc_detail']['cpu_ms_per_cycle']['mark'],1)
            self.assertAlmostEqual(leg['gc_detail']['worker_minus_phases_pct'],.8)
            self.assertAlmostEqual(leg['canvas_detail']['cpu_pct']['post'],1)
    def test_snapshot(self):
        x=focused(log().replace('canvas_phase_ok=1','canvas_phase_ok=0'),'r')
        self.assertFalse(x['legs'][0]['canvas_detail']['valid'])
        self.assertTrue(x['legs'][0]['gc_detail']['valid'])
    def test_wrong_profile(self):
        with self.assertRaises(ValueError):
            focused(log().replace('hotspot-0','hotspot-1'),'r')
    def test_reset(self):
        rows=log().splitlines()
        rows[1]=rows[1].replace('gc_phase_scanned=2000','gc_phase_scanned=1')
        with self.assertRaises(ValueError):
            focused('\n'.join(rows),'r')


if __name__=='__main__': unittest.main()
