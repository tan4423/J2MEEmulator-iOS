"""Compile real GC native-heap ledger in isolation with pthread stress.

The compiled C functions are literally extracted from garbage.c. No stub
replacement algorithm is used; only MiniJVM/spinlock platform types are stubbed.
Xcode device integration remains necessary before enabling multi-JVM.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
GC = ROOT / "J2MEEmulator/minijvm/jvm/garbage.c"
RENDER = ROOT / "J2MEEmulator/NativeBridge/j2me_render.m"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"

PREAMBLE = r"""
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
typedef long long s64;
typedef struct { int id; } MiniJVM;
typedef struct { atomic_int held; int unused1, unused2; } spinlock_t;
static void spin_lock(spinlock_t *l) {
    while (atomic_exchange_explicit(&l->held, 1, memory_order_acquire))
        sched_yield();
}
static void spin_unlock(spinlock_t *l) {
    atomic_store_explicit(&l->held, 0, memory_order_release);
}
"""

TEST = r"""
typedef struct { MiniJVM *vm; uint64_t key; int iterations; int failures; } W;
static void *worker(void *p) {
    W *w = p;
    for (int i = 0; i < w->iterations; ++i) {
        jarbox_native_heap_account(w->key, 5);
        jarbox_native_heap_account(w->key, -2);
    }
    return NULL;
}
int main(void) {
    MiniJVM a={1}, b={2};
    if (!jarbox_native_heap_register_vm(&a) ||
        !jarbox_native_heap_register_vm(&b)) return 1;
    uint64_t k1 = jarbox_native_heap_key_for_vm(&a);
    uint64_t k2 = jarbox_native_heap_key_for_vm(&b);
    if (!k1 || !k2 || k1 == k2) return 2;
    W wa = {&a,k1,20000,0}, wb = {&b,k2,20000,0};
    pthread_t t1,t2;
    if (pthread_create(&t1,NULL,worker,&wa) ||
        pthread_create(&t2,NULL,worker,&wb)) return 3;
    pthread_join(t1,NULL);
    pthread_join(t2,NULL);
    if (jarbox_native_heap_for_vm(&a) != 60000 ||
        jarbox_native_heap_for_vm(&b) != 60000) return 4;
    if (jarbox_native_heap_register_vm(&a)) return 11;
    jarbox_native_heap_unregister_key(k1);
    // Old handle release after A terminated must never affect live B.
    jarbox_native_heap_account(k1, -60000);
    if (jarbox_native_heap_for_vm(&b) != 60000) return 5;
    // Reusing exact JVM pointer address must also get a NEW generation key.
    a.id = 3;
    if (!jarbox_native_heap_register_vm(&a)) return 6;
    uint64_t k3 = jarbox_native_heap_key_for_vm(&a);
    if (k3 == k1 || !k3) return 7;
    jarbox_native_heap_unregister_key(k1);
    if (jarbox_native_heap_key_for_vm(&a) != k3) return 12;
    jarbox_native_heap_account(k1, 2000);
    jarbox_native_heap_account(k1, -9999999);
    if (jarbox_native_heap_for_vm(&a) != 0) return 8;
    jarbox_native_heap_account(k3, 120);
    if (jarbox_native_heap_for_vm(&a) != 120 ||
        jarbox_native_heap_for_vm(&b) != 60000) return 9;
    jarbox_native_heap_unregister_key(k3);
    jarbox_native_heap_unregister_key(k2);
    for (int i = 0; i < 10000; ++i) {
        if (!jarbox_native_heap_register_vm(&a)) return 13;
        uint64_t old = jarbox_native_heap_key_for_vm(&a);
        if (jarbox_native_heap_register_vm(&a)) return 14;
        jarbox_native_heap_unregister_key(old);
        if (!jarbox_native_heap_register_vm(&a)) return 15;
        uint64_t now = jarbox_native_heap_key_for_vm(&a);
        jarbox_native_heap_unregister_key(old);
        jarbox_native_heap_account(old, 99);
        if (now == old || jarbox_native_heap_key_for_vm(&a) != now ||
            jarbox_native_heap_for_vm(&a)) return 16;
        jarbox_native_heap_unregister_key(now);
    }
    return 0;
}
"""


class MultiVMNativeHeapLedgerTest(unittest.TestCase):
    def test_real_ledger_isolation_with_old_generation_races(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("C compiler unavailable")
        source = GC.read_text(encoding="utf-8")
        start = source.index("#define JARBOX_NATIVE_HEAP_SLOTS")
        end = source.index("\ns64 gc_sum_heap(", start)
        production = source[start:end]
        self.assertIn("slot->key == key", production)
        with tempfile.TemporaryDirectory(prefix="jarbox-native-heap-") as temp:
            path = Path(temp)
            src = path / "heap.c"
            executable = path / "heap"
            src.write_text(PREAMBLE + production + "\n" + TEST)
            subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra",
                 "-pthread", str(src), "-o", str(executable)],
                check=True, capture_output=True, text=True, timeout=45,
            )
            subprocess.run([str(executable)], check=True,
                           capture_output=True, text=True, timeout=15)

    def test_gc_and_render_are_scoped_to_owner(self):
        gc = GC.read_text(encoding="utf-8")
        render = RENDER.read_text(encoding="utf-8")
        bridge = BRIDGE.read_text(encoding="utf-8")
        self.assertNotIn("g_native_extra_heap", gc)
        self.assertNotIn("g_native_extra_heap", render)
        self.assertIn("jarbox_native_heap_for_vm(collector->jvm)", gc)
        self.assertIn("jarbox_native_heap_for_vm(jvm)", gc)
        self.assertIn("uint64_t heap_key;", render)
        self.assertIn("jarbox_native_heap_key_for_vm(owner)", render)
        self.assertIn("native_heap_sub(rc->heap_key, pixels)", render)
        self.assertIn("native_heap_sub(img->heap_key, pixels)", render)
        self.assertIn("native_heap_add(rc->heap_key", render)
        self.assertIn("native_heap_add(img->heap_key", render)
        self.assertIn("jarbox_native_heap_register_vm(slot->jvm)", bridge)
        self.assertIn("jarbox_native_heap_unregister_key(destroyed_render_key)", bridge)
        self.assertLess(bridge.index("jarbox_native_heap_register_vm(slot->jvm)"),
                        bridge.index("s32 ret = jvm_init(slot->jvm,"))
        self.assertIn("const uint64_t destroyed_render_key = slot->native_heap_key;", bridge)


if __name__ == "__main__":
    unittest.main()
