"""Exercise the exact native executor slot helpers with independent pthreads.

The C mock supplies two distinct MiniJVM identities, not real Java heaps.
This tests allocation/retirement and worker ownership; device concurrency
remains a separate milestone.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"
PREAMBLE = r"""
#include <stdint.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdio.h>
#include <pthread.h>
#include <sched.h>
#define JARBOX_REGISTRY_MAX_SLOTS 2
typedef struct {int dummy;} MiniJVM;
"""
HARNESS = r"""
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_int failed;
typedef struct {uint64_t token; MiniJVM *vm; int stop;} Worker;
static void *work(void *arg) {
    Worker *w = arg;
    for (int i = 0; i < 10000; ++i) {
        pthread_mutex_lock(&lock);
        JarBoxVMContext *slot = bridge_claim_worker_locked(w->token);
        if (!slot || bridge_slot_can_retire_locked(slot) ||
            bridge_claim_worker_locked(w->token)) {
            atomic_store(&failed, 1);
            pthread_mutex_unlock(&lock);
            return NULL;
        }
        pthread_mutex_unlock(&lock);
        if (slot->jvm != w->vm || atomic_load(&slot->stop_requested) != w->stop ||
            atomic_load(&slot->token) != w->token) atomic_store(&failed, 2);
        if (i % 137 == 0) sched_yield();
        pthread_mutex_lock(&lock);
        bridge_release_worker_locked(slot);
        pthread_mutex_unlock(&lock);
    }
    return NULL;
}
int main(void) {
    MiniJVM avm = {0}, bvm = {0};
    JarBoxVMContext *a = bridge_reserve_slot_locked(101, 1);
    if (!a || bridge_reserve_slot_locked(202, 1)) return 1;
    JarBoxVMContext *b = bridge_reserve_slot_locked(202, 2);
    if (!b || b == a || bridge_reserve_slot_locked(303, 2) ||
        bridge_reserve_slot_locked(101, 2)) return 2;
    if (bridge_claim_worker_locked(101) != a || bridge_slot_can_retire_locked(a)) return 3;
    bridge_release_worker_locked(a);
    a->jvm = &avm; b->jvm = &bvm;
    atomic_store(&a->stop_requested, 1);
    atomic_store(&a->phase, BRIDGE_CLEANUP);
    atomic_store(&b->phase, BRIDGE_RUNNING);
    if (bridge_slot_can_retire_locked(a) || bridge_slot_can_retire_locked(b)) return 4;
    Worker wa = {101, &avm, 1}, wb = {202, &bvm, 0};
    pthread_t ta, tb;
    if (pthread_create(&ta, NULL, work, &wa) || pthread_create(&tb, NULL, work, &wb)) return 5;
    pthread_join(ta, NULL); pthread_join(tb, NULL);
    if (atomic_load(&failed)) return 6;
    a->jvm = NULL;
    if (!bridge_slot_can_retire_locked(a)) return 7;
    bridge_reset_slot_locked(a);
    if (bridge_find_slot_locked(101) || bridge_claim_worker_locked(101)) return 8;
    JarBoxVMContext *c = bridge_reserve_slot_locked(303, 2);
    if (c != a || atomic_load(&c->stop_requested) || atomic_load(&c->phase) != BRIDGE_STARTING ||
        c->jvm || b->jvm != &bvm || atomic_load(&b->token) != 202 ||
        atomic_load(&b->phase) != BRIDGE_RUNNING || atomic_load(&b->stop_requested)) return 9;
    if (!bridge_slot_can_retire_locked(c)) return 10;
    bridge_reset_slot_locked(c);
    b->jvm = NULL;
    if (!bridge_slot_can_retire_locked(b)) return 11;
    bridge_reset_slot_locked(b);
    puts("executor pool: PASS (2 slots, independent workers, stale token rejected)");
    return 0;
}
"""

class MultiVMExecutorPoolTest(unittest.TestCase):
    def test_two_mock_executors_and_stale_tokens(self):
        cc = shutil.which("clang") or shutil.which("cc")
        if not cc:
            self.skipTest("No C11 host compiler")
        src = BRIDGE.read_text(encoding="utf-8")
        first = src.index("enum { BRIDGE_IDLE")
        end = src.index("// Tokens are never reused", first)
        with tempfile.TemporaryDirectory(prefix="jarbox-executor-pool-") as td:
            program, exe = Path(td) / "pool.c", Path(td) / "pool"
            program.write_text(PREAMBLE + src[first:end] + HARNESS, encoding="utf-8")
            build = subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-pthread", str(program), "-o", str(exe)],
                capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("executor pool: PASS", result.stdout)

    def test_production_claim_and_retirement_use_real_slots(self):
        src = BRIDGE.read_text(encoding="utf-8")
        self.assertNotIn("static JarBoxVMContext g_bridge_vm", src)
        self.assertIn("g_bridge_slots[JARBOX_REGISTRY_MAX_SLOTS]", src)
        self.assertIn("bridge_reserve_slot_locked(", src)
        self.assertIn("(unsigned)jvm_bridge_supported_concurrent_sessions()", src)
        self.assertIn("if (!bridge_slot_can_retire_locked(slot)", src)
        self.assertIn("jarbox_registry_finish(&g_bridge_registry, &g_bridge_focus, token)", src)
        self.assertEqual(src.count("JarBoxVMContext *slot = bridge_claim_worker(token);"), 3)
        self.assertEqual(src.count("bridge_release_worker(slot);"), 3)

if __name__ == "__main__":
    unittest.main()
