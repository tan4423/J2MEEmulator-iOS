"""Exercise the production unstarted-VM discard helper with a mock JVM drain."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / 'J2MEEmulator/NativeBridge/jvm_bridge.c'
PRELUDE = r'''
#include <assert.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
typedef struct { int exit_flag; } Collector;
typedef struct { Collector *collector; } MiniJVM;
typedef struct { _Atomic(MiniJVM *) jvm; atomic_int stop_requested; uint64_t native_heap_key; } JarBoxVMContext;
static atomic_int treo_exact_ninja_verified, treo_nso_init_target_active;
static int cap, destroys, retires;
static void jarbox_native_heap_unregister_key(uint64_t key) { assert(key == 101); ++retires; }
static JarBoxVMContext *current;
static int jvm_bridge_supported_concurrent_sessions(void) { return cap; }
static void jvm_destroy(MiniJVM *vm) {
    assert(vm && current->jvm == vm);
    assert(vm->collector->exit_flag == 1);
    assert(atomic_load(&current->stop_requested) == 1);
    ++destroys;
}
'''
MAIN = r'''
int main(void) {
    for (int i = 0; i < 100; ++i) {
        Collector ca = {0}, cb = {0}; MiniJVM a = {&ca}, b = {&cb};
        JarBoxVMContext sa = {&a, 0, 101}, sb = {&b, 0, 202};
        current = &sa;
        cap = i % 2 ? 1 : 2;
        atomic_store(&treo_exact_ninja_verified, 1);
        atomic_store(&treo_nso_init_target_active, 1);
        bridge_discard_unstarted_vm(&sa);
        assert(!sa.jvm && sa.stop_requested && ca.exit_flag && !sa.native_heap_key);
        assert(sb.native_heap_key == 202);
        assert(sb.jvm == &b && !sb.stop_requested && !cb.exit_flag);
        assert(treo_exact_ninja_verified == (cap == 2));
        assert(treo_nso_init_target_active == (cap == 2));
    }
    assert(destroys == 100 && retires == 100);
    puts("startup rollback: OK");
    return 0;
}
'''


def harness(source):
    start = source.index('static void bridge_discard_unstarted_vm(')
    end = source.index('\n}', start) + 2
    return PRELUDE + source[start:end] + MAIN


class NativeStartupRollbackTest(unittest.TestCase):
    def test_discard_stops_exact_owner_before_destroy(self):
        cc = shutil.which('clang') or shutil.which('cc')
        if not cc:
            self.skipTest('host compiler unavailable')
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / 'rollback.c'
            exe = Path(td) / 'rollback'
            src.write_text(harness(BRIDGE.read_text(encoding='utf-8')))
            subprocess.run([cc, '-std=c11', '-Wall', '-Wextra', '-Werror', str(src), '-o', str(exe)], check=True, timeout=30)
            run = subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn('startup rollback: OK', run.stdout)

    def test_all_init_failures_use_discard_and_keep_native_release_order(self):
        source = BRIDGE.read_text(encoding='utf-8')
        body = source.split('static int bridge_init_slot(', 1)[1].split('\nstatic int bridge_run_slot(', 1)[0]
        self.assertNotIn('jvm_destroy(slot->jvm);', body)
        self.assertEqual(body.count('bridge_discard_unstarted_vm(slot);'), 5)
        for code in (-3, -8, -4, -6):
            self.assertIn(f'bridge_discard_unstarted_vm(slot);\n        return {code};', body)
        cancel = body.index('if (atomic_load_explicit(&slot->stop_requested, memory_order_acquire)) {')
        self.assertLess(body.index('s32 ret = jvm_init('), cancel)
        self.assertLess(cancel, body.index('jarbox_registry_bind('))
        self.assertIn('j2me_input_release_vm(slot->jvm);\n        bridge_discard_unstarted_vm(slot);', body)
        self.assertLess(body.index("jarbox_native_heap_register_vm(slot->jvm)"), body.index("s32 ret = jvm_init("))
        self.assertIn("jvm_free(created);\n        return -7;", body)
        discard = source.split("static void bridge_discard_unstarted_vm(", 1)[1].split("\n}", 1)[0]
        self.assertLess(discard.index("jvm_destroy(slot->jvm)"), discard.index("jarbox_native_heap_unregister_key(slot->native_heap_key)"))


if __name__ == '__main__':
    unittest.main()
