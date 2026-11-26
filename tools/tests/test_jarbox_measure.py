"""Synthetic counter validation; no device performance claims."""
import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jarbox_measure import analyze


def sample(seq, n):
    slot = dict(token=1, phase=2, stop=0, mode=1, cpu_ok=1, counters_ok=1,
                runner_ns=10*n, java_ns=300*n, gc_ns=10*n, gc_aborts=0, repaints=32*n,
                afk_profile_paint_calls=32*n, afk_profile_paint_cpu_ns=330*n,
                native_diag_seen=32*n, native_diag_selected_frames=n,
                native_diag_selected_cpu_ns=20*n, native_diag_plain_frames=31*n,
                native_diag_plain_cpu_ns=310*n, native_diag_discarded_frames=0,
                native_diag_draw_calls=100*n, native_diag_draw_ns=12*n,
                native_diag_lcd_other_ns=n, native_diag_other_ns=2*n,
                compatible_crop_hits=10*n, compatible_crop_misses=90*n)
    return (f'run=r build=b perf=native-paint-diag-1 seq={seq} event=sample '
            f'mono_ns={1000*n+1} process_cpu_ns={400*n} process_cpu_ok=1 gap_ns=1000 '
            'detail_count=1 slots=[' + ','.join(f'{k}={v}' for k,v in slot.items()) + ']')


class MeasureTest(unittest.TestCase):
    def test_delta(self):
        log='\n'.join(sample(i,i) for i in range(1,4))
        r=analyze(log,'r',1,3)
        self.assertEqual(r['process_pct'],40)
        self.assertEqual(r['paint_pct'],33)
        self.assertEqual(r['selected_native_share_pct']['draw'],60)
        self.assertEqual(r['selected_native_share_pct']['unclassified'],25)
        self.assertEqual(r['selected_plain_ratio'],2)
        self.assertEqual(r['crop_hit_pct'],10)
        self.assertEqual(r['paint_frames'],64)

    def test_reject(self):
        a,b,c=(sample(i,i) for i in range(1,4))
        bad=[a+'\n'+c, a+'\n'+b+'\n'+b+'\n'+c,
             a+'\n'+b.replace('mode=1','mode=0')+'\n'+c,
             a+'\n'+b.replace('cpu_ok=1','cpu_ok=0')+'\n'+c,
             a+'\n'+b.replace('token=1','token=2')+'\n'+c,
             a+'\n'+b.replace('gap_ns=1000','gap_ns=16000000000')+'\n'+c,
             a+'\n'+b.replace('java_ns=600','java_ns=0')+'\n'+c,
             a+'\n'+b.replace('native_diag_draw_ns=24,','')+'\n'+c,
             a+'\n'+b+'\n'+c.replace('native_diag_draw_ns=36','native_diag_draw_ns=1000'),
             a+'\n'+b+'\n'+c.replace('native_diag_plain_cpu_ns=930','native_diag_plain_cpu_ns=931'),
             a+'\n'+b.replace('event=sample','event=park_entered')+'\n'+c]
        for log in bad:
            with self.subTest(log=log), self.assertRaises(ValueError):
                analyze(log,'r',1,3)

if __name__ == '__main__':
    unittest.main()
