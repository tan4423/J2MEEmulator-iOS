"""Host-only test of production TreoState policy (no iOS, Java or Metal)."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "J2MEEmulator/minijvm/jvm/jarbox_treo_state.h"

C = r"""
#include "jarbox_treo_state.h"
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
typedef struct { JarBoxTreoState *state; uint64_t offset; } Work;
static void *work(void *ptr) {
    Work *w = ptr;
    for (int i = 0; i < 100000; ++i) {
        jarbox_treo_peak_note(&w->state->probe_heap_peak, (uint64_t)i + w->offset);
        if (i % 7 == 0) jarbox_treo_smart_note_heap(w->state, (uint64_t)i);
    }
    return NULL;
}
int main(void) {
    JarBoxTreoState a = {0}, b = {0};
    if (jarbox_treo_smart_period(&a) != 500) return 1;
    jarbox_treo_mode_set(&a, 8);
    jarbox_treo_smart_set(&a, 1);
    jarbox_treo_probe_set(&a, 2000);
    if (jarbox_treo_smart_period(&a) != 2000 ||
        jarbox_treo_smart_period(&b) != 500) return 2;
    if (jarbox_treo_probe_period(&a) != 2000 ||
        jarbox_treo_probe_period(&b) != 0) return 3;
    Work wa = {&a, 0}, wb = {&b, 1000000};
    pthread_t ta, tb;
    if (pthread_create(&ta, NULL, work, &wa)) return 4;
    if (pthread_create(&tb, NULL, work, &wb)) return 5;
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    if (a.probe_heap_peak != 99999 || b.probe_heap_peak != 1099999) return 6;
    jarbox_treo_smart_force_safe(&a);
    jarbox_treo_probe_fallback(&a);
    if (jarbox_treo_smart_period(&a) != 500 ||
        jarbox_treo_probe_period(&a) != 0 ||
        a.probe_fallback_count != 1 ||
        b.probe_fallback_count != 0) return 7;
    jarbox_treo_smart_record_gc(&a, 2500);
    if (a.smart_cycles != 1 || a.smart_cpu_ns != 2500 ||
        b.smart_cycles != 0) return 8;
    jarbox_treo_mode_set(&a, 0);
    puts("TreoState host model: OK (two independent states; pthread peak stress)");
    return 0;
}
"""

class MultiVMTreoStateTest(unittest.TestCase):
    def test_two_independent_treo_gc_states(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if cc is None:
            self.skipTest("Host C compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-treo-state-") as temp:
            source = Path(temp) / "treo.c"
            program = Path(temp) / "treo"
            source.write_text(C, encoding="utf-8")
            build = subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-pthread", "-I", str(HEADER.parent),
                 str(source), "-o", str(program)],
                capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(program)], capture_output=True,
                                 text=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("TreoState host model: OK", run.stdout)

    def test_collector_and_lifecycle_bridge_are_generation_scoped(self):
        collector = (ROOT / "J2MEEmulator/minijvm/jvm/garbage.c").read_text()
        vm = (ROOT / "J2MEEmulator/minijvm/jvm/jvm.h").read_text()
        session = (ROOT / "J2MEEmulator/minijvm/jvm/jarbox_session.h").read_text()
        bridge = (ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        renderer = (ROOT / "J2MEEmulator/NativeBridge/j2me_render.m").read_text()
        self.assertIn("JarBoxSession *session;", vm)
        self.assertIn("JarBoxTreoState treo_state;", session)
        self.assertNotIn("JarBoxTreoState treo_state;", vm)
        self.assertIn("jarbox_treo_smart_period(&jvm->session->treo_state)", collector)
        self.assertIn("jarbox_treo_probe_period(&jvm->session->treo_state)", collector)
        self.assertIn("jarbox_treo_smart_force_safe(&jvm->session->treo_state)", collector)
        self.assertIn("jarbox_treo_probe_fallback(&jvm->session->treo_state)", collector)
        self.assertIn("jarbox_treo_smart_record_gc(&jvm->session->treo_state", collector)
        self.assertNotIn("static int treo_gc_probe_requested_ms;", collector)
        self.assertNotIn("static int treo_gc_smart_enabled,", collector)
        self.assertIn("void jvm_bridge_visit_running_vm(", bridge)
        self.assertIn("pthread_mutex_lock(&g_bridge_lifecycle_lock);", bridge)
        self.assertIn("memory_order_acquire) == BRIDGE_RUNNING", bridge)
        self.assertIn("treo_gc_set_afk_mode_for_current(mode);", renderer)

    def test_still_rejects_parallel_jvm(self):
        bridge = (ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return 1;", bridge)

if __name__ == "__main__":
    unittest.main()
