"""Compile the exact bridge diagnostic-record helpers on a POSIX host.

No Java VM or UIKit is used. The test exercises bounded records and stale
token rejection, not game networking or protocol changes.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"
PREAMBLE = r"""
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#define JARBOX_REGISTRY_MAX_SLOTS 2
"""
HARNESS = r"""
int main(void) {
    pthread_mutex_lock(&g_bridge_diag_lock);
    if (!bridge_diag_begin_locked(101) || bridge_diag_begin_locked(101) ||
        bridge_diag_begin_locked(0)) return 1;
    JarBoxBridgeDiagnostics *a = bridge_diag_find_locked(101);
    if (!a || bridge_diag_find_locked(0) != a) return 2;
    snprintf(a->last_error, sizeof(a->last_error), "A");
    a->popup_ticks = 11;
    if (!bridge_diag_begin_locked(202) || bridge_diag_begin_locked(303)) return 3;
    JarBoxBridgeDiagnostics *b = bridge_diag_find_locked(202);
    if (!b || b == a || b->last_error[0] || b->popup_ticks ||
        bridge_diag_find_locked(0)) return 4;
    snprintf(b->last_error, sizeof(b->last_error), "B");
    b->popup_ticks = 22;
    if (strcmp(a->last_error, "A") || a->popup_ticks != 11) return 5;
    bridge_diag_end_locked(101);
    if (bridge_diag_find_locked(101) || bridge_diag_find_locked(0) != b) return 6;
    if (!bridge_diag_begin_locked(303) || bridge_diag_find_locked(303) != a ||
        a->last_error[0] || a->popup_ticks || strcmp(b->last_error, "B") ||
        b->popup_ticks != 22) return 7;
    bridge_diag_end_locked(202);
    bridge_diag_end_locked(303);
    if (bridge_diag_find_locked(0)) return 8;
    pthread_mutex_unlock(&g_bridge_diag_lock);
    puts("bridge diagnostics: PASS");
    return 0;
}
"""

class MultiVMDiagnosticsTest(unittest.TestCase):
    def test_exact_record_helpers(self):
        cc = shutil.which("clang") or shutil.which("cc")
        if not cc:
            self.skipTest("No host compiler")
        src = BRIDGE.read_text(encoding="utf-8")
        start = src.index("// Bridge diagnostics are separate")
        end = src.index("static int bridge_diag_begin(uint64_t token)", start)
        with tempfile.TemporaryDirectory(prefix="jarbox-diagnostics-") as td:
            c, exe = Path(td) / "diag.c", Path(td) / "diag"
            c.write_text(PREAMBLE + src[start:end] + HARNESS, encoding="utf-8")
            build = subprocess.run(
                [cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
                 str(c), "-o", str(exe)], capture_output=True, text=True, timeout=30)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("bridge diagnostics: PASS", run.stdout)

    def test_worker_reads_explicit_token(self):
        game = GAME.read_text(encoding="utf-8")
        src = BRIDGE.read_text(encoding="utf-8")
        self.assertIn("jvm_bridge_last_error_for_token(token)", game)
        self.assertIn("jvm_bridge_nso_init_trace_for_token(token)", game)
        self.assertIn("bridge_diag_begin(token)", src)
        self.assertIn("bridge_diag_end(token)", src)
        self.assertNotIn("static char g_bridge_last_error[", src)
        self.assertNotIn("static char g_bridge_net_trace[", src)

if __name__ == "__main__":
    unittest.main()
