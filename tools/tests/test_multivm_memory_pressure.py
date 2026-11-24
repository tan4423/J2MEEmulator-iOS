"""Host regression for token-specific Smart GC fallback (mock bridge visitor)."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"

PRELUDE = r"""
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include "jarbox_treo_state.h"
typedef struct { JarBoxTreoState treo_state; } Session;
typedef struct { Session *session; } MiniJVM;
static Session a, b;
static MiniJVM va = {&a}, vb = {&b};
static int legacy_calls;
static int jvm_bridge_visit_running_vm_for_token(uint64_t token,
        void (*visit)(MiniJVM *, void *), void *arg) {
    MiniJVM *vm = token == 11 ? &va : token == 22 ? &vb : NULL;
    if (!vm) return 0;
    visit(vm, arg);
    return 1;
}
static void jvm_bridge_visit_running_vm(void (*visit)(MiniJVM *, void *), void *arg) {
    ++legacy_calls;
    visit(&vb, arg);
}
"""
MAIN = r"""
int main(void) {
    jarbox_treo_mode_set(&a.treo_state, 8);
    jarbox_treo_mode_set(&b.treo_state, 8);
    jarbox_treo_smart_set(&a.treo_state, 1);
    jarbox_treo_smart_set(&b.treo_state, 1);
    assert(jarbox_treo_smart_period(&a.treo_state) == 2000);
    assert(jarbox_treo_smart_period(&b.treo_state) == 2000);
    assert(!treo_gc_smart_force_safe_for_token(0));
    assert(!treo_gc_smart_force_safe_for_token(99));
    assert(treo_gc_smart_force_safe_for_token(11));
    assert(treo_gc_smart_force_safe_for_token(11));
    assert(jarbox_treo_smart_period(&a.treo_state) == 500);
    assert(jarbox_treo_smart_period(&b.treo_state) == 2000);
    assert(treo_gc_smart_force_safe_for_token(22));
    assert(jarbox_treo_smart_period(&b.treo_state) == 500);
    jarbox_treo_smart_set(&b.treo_state, 1);
    jarbox_treo_smart_set(&b.treo_state, 0);
    assert(treo_gc_smart_force_safe_for_token(22));
    assert(!b.treo_state.smart_fallback);
    assert(jarbox_treo_mode_get(&a.treo_state) == 8);
    assert(jarbox_treo_mode_get(&b.treo_state) == 8);
    assert(!legacy_calls);
    puts("token pressure fallback: OK");
    return 0;
}
"""


class MemoryPressureTest(unittest.TestCase):
    def test_owner_fallback(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        gc = (JVM / "garbage.c").read_text()
        start = gc.index("static void treo_force_safe_active(")
        end = gc.index("static void treo_afk_mode_active(", start)
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "pressure.c"
            exe = Path(td) / "pressure"
            source.write_text(PRELUDE + gc[start:end] + MAIN)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-I", str(JVM), str(source), "-o", str(exe)],
                           check=True, timeout=30)
            run = subprocess.run([str(exe)], check=True, capture_output=True,
                                 text=True, timeout=10)
            self.assertIn("token pressure fallback: OK", run.stdout)


if __name__ == "__main__":
    unittest.main()
