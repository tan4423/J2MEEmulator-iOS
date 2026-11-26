import unittest
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jarbox_aba import analyze


def fixture():
    rows=[]; process=paint=frames=core=skips=0
    for seq,t in enumerate(range(15,225,5),1):
        phase=t//75*2+1+(t%75>=15)
        b=phase in (3,4)
        process+=1_500_000_000 if b else 2_000_000_000
        paint+=1_000_000_000 if b else 1_500_000_000
        frames+=125
        if b: core+=125; skips+=1000
        ns=t*1_000_000_000
        rows.append(f'run=r build=b perf=core-aba-1 seq={seq} event=sample mono_ns={ns} detail_mono_ns={ns+1000} process_cpu_ns={process} process_cpu_ok=1 gap_ns=5000000000 detail_count=1 thermal=0 low_power=0 slots=[token=1,phase=2,stop=0,mode=1,cpu_ok=1,counters_ok=1,core_aba_phase={phase},core_aba_start_ns=100,core_aba_elapsed_ns={ns},nso_core_armed=1,nso_core_rejected=0,afk_profile_paint_calls={frames},afk_profile_paint_cpu_ns={paint},repaints={frames},runner_ns=0,java_ns={process},gc_ns=0,gc_cycles={seq*10},gc_aborts=0,nso_core_frames={core},nso_core_faults=0,scoped_native_draw_skips={skips},scoped_vm_draw_skips=0]')
    return rows


class ABATest(unittest.TestCase):
    def test_valid(self):
        x=analyze('\n'.join(fixture()),'r')
        self.assertEqual([r['process_pct'] for r in x['legs']],[40,30,40])
        self.assertEqual(x['b_vs_a_mean_process_points'],-10)
        self.assertEqual(x['a2_vs_a1_process_points'],0)
        self.assertTrue(x['process_cost_reduced'])
        self.assertEqual(x['b_vs_a_mean_points']['outside_paint_pct'],0)
        self.assertEqual(x['legs'][1]['gc_cycles_per_s'],2)
        self.assertEqual(x['legs'][1]['worker_residual_pct'],0)

    def test_paint_win_process_loss(self):
        rows=fixture()
        # Add 0.6 CPU seconds per B measurement interval to process only.
        extra=0
        for i,r in enumerate(rows):
            if 'core_aba_phase=3,' in r or 'core_aba_phase=4,' in r:
                extra+=600_000_000
            value=int(r.split('process_cpu_ns=')[1].split()[0])
            rows[i]=r.replace(f'process_cpu_ns={value} ', f'process_cpu_ns={value+extra} ')
        x=analyze('\n'.join(rows),'r')
        self.assertFalse(x['process_cost_reduced'])
        self.assertAlmostEqual(x['b_vs_a_mean_process_points'],2)
        self.assertAlmostEqual(x['b_vs_a_mean_points']['paint_pct'],-10)
        self.assertAlmostEqual(x['b_vs_a_mean_points']['outside_paint_pct'],12)
    def test_reject(self):
        rows=fixture()
        bad=[rows[:-3],rows[:8]+rows[9:],rows[:8]+[rows[8].replace('token=1','token=2')]+rows[9:],
             rows[:8]+[rows[8].replace('thermal=0','thermal=1')]+rows[9:],
             rows[:8]+[rows[8].replace('nso_core_rejected=0','nso_core_rejected=1')]+rows[9:],
             rows[:8]+[rows[8].replace('core_aba_start_ns=100','core_aba_start_ns=200')]+rows[9:],
             rows[:8]+[rows[8].replace('gap_ns=5000000000','gap_ns=16000000000')]+rows[9:],
             rows[:8]+[r.replace('gc_aborts=0','gc_aborts=1') for r in rows[8:]],
             [r.replace('nso_core_frames='+r.split('nso_core_frames=')[1].split(',')[0],'nso_core_frames=0') for r in rows]]
        for x in bad:
            with self.subTest(case=x[0][:100]),self.assertRaises(ValueError): analyze('\n'.join(x),'r')

if __name__=='__main__': unittest.main()
