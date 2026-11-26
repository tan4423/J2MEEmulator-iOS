import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host_multivm_smoke"))
from benchmark_summary import analyze


def fixture():
    rows = []
    for r in range(4):
        for p in range(4):
            m = (r + p) % 4
            t = (1000 + r * 100) * (10 - m) // 10
            rows.append(f"bench round={r} mask={m} thread_ns={t} process_ns={t*2} array={160000 if m&1 else 0} char={131008 if m&2 else 0} gc=16")
    return rows + ["intrinsic_bench: PASS"]


class HostBenchmarkTest(unittest.TestCase):
    def test_paired(self):
        report = analyze("\n".join(fixture()))
        self.assertAlmostEqual(report["legs"]["both"]["thread_paired_median_change_pct"], -30)
        self.assertAlmostEqual(report["legs"]["char"]["process_paired_median_change_pct"], -20)
        self.assertEqual(report["legs"]["baseline"]["thread_paired_ratio"], [1]*4)

    def test_fail_closed(self):
        rows = fixture()
        invalid = [rows[:-1], rows[1:], rows[:1]+rows, [r.replace("array=160000","array=0") for r in rows],
                   [r.replace("char=0","char=64") for r in rows],
                   [r.replace("gc=16","gc=0") for r in rows],
                   [r.replace("mask=3","mask=4") for r in rows],
                   [r.replace("thread_ns=1000","thread_ns=0") for r in rows]]
        for x in invalid:
            with self.subTest(row=x[0]), self.assertRaises(ValueError):
                analyze("\n".join(x))


if __name__ == "__main__":
    unittest.main()
