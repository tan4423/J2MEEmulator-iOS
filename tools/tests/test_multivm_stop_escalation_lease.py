"""Compile the production escalation function with a mock VM/monitor boundary."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"
JVM = ROOT / "J2MEEmulator/minijvm/jvm"
PRELUDE = r"""
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include "jarbox_session.h"

enum { BRIDGE_STARTING = 1, BRIDGE_RUNNING = 2, BRIDGE_CLEANUP = 3 };
typedef struct { JarBoxSession *session; } MiniJVM;
typedef struct {
    _Atomic(MiniJVM *) jvm;
    atomic_int stop_requested, phase;
} JarBoxVMContext;
static pthread_mutex_t g_bridge_lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
static JarBoxVMContext a, b;
static MiniJVM va, vb;
static int calls;
static JarBoxVMContext *bridge_find_slot_locked(uint64_t token) {
    return token == 11 ? &a : token == 22 ? &b : NULL;
}
static void thread_stop_all(MiniJVM *vm) {
    assert(vm == &va);
    /* A Java monitor owner can need the lifecycle lock. Never wait for
     * that monitor while holding the process-wide lifecycle lock. */
    assert(pthread_mutex_trylock(&g_bridge_lifecycle_lock) == 0);
    assert(jarbox_session_callback_count(vm->session) == 1);
    assert(jarbox_session_active_lease_count(vm->session) == 1);
    /* Simulate teardown winning immediately after the unlock. The heap
     * must remain pinned until escalation's final VM access is complete. */
    atomic_store(&a.phase, BRIDGE_CLEANUP);
    jarbox_session_begin_stop(vm->session);
    assert(!jarbox_session_mark_dead(vm->session));
    assert(!jarbox_session_reserve_callback(vm->session));
    assert(jarbox_session_phase(vb.session) == JARBOX_SESSION_FOREGROUND);
    assert(jarbox_session_active_lease_count(vb.session) == 0);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    ++calls;
}
"""
MAIN = r"""
int main(void) {
    for (int i = 0; i < 100; ++i) {
        va.session = jarbox_session_create(&va);
        vb.session = jarbox_session_create(&vb);
        assert(va.session && vb.session);
        assert(jarbox_session_bind_token(va.session, 11));
        assert(jarbox_session_bind_token(vb.session, 22));
        assert(jarbox_session_enter_foreground(va.session));
        assert(jarbox_session_enter_foreground(vb.session));
        atomic_store(&a.jvm, &va);
        atomic_store(&b.jvm, &vb);
        atomic_store(&a.stop_requested, 1);
        atomic_store(&b.stop_requested, 0);
        atomic_store(&a.phase, BRIDGE_STARTING);
        atomic_store(&b.phase, BRIDGE_RUNNING);
        assert(!jvm_bridge_interrupt_active_threads_for_token(0));
        assert(!jvm_bridge_interrupt_active_threads_for_token(99));
        assert(!jvm_bridge_interrupt_active_threads_for_token(11));
        assert(!jvm_bridge_interrupt_active_threads_for_token(22));
        atomic_store(&a.phase, BRIDGE_RUNNING);
        assert(jvm_bridge_interrupt_active_threads_for_token(11));
        assert(jarbox_session_active_lease_count(va.session) == 0);
        assert(jarbox_session_callback_count(va.session) == 0);
        assert(!jvm_bridge_interrupt_active_threads_for_token(11));
        assert(jarbox_session_mark_dead(va.session));
        assert(jarbox_session_phase(vb.session) == JARBOX_SESSION_FOREGROUND);
        atomic_store(&b.stop_requested, 1);
        jarbox_session_begin_stop(vb.session);
        /* Even a RUNNING slot cannot bypass a closed heap lease gate. */
        assert(!jvm_bridge_interrupt_active_threads_for_token(22));
        assert(jarbox_session_mark_dead(vb.session));
        jarbox_session_release(va.session);
        jarbox_session_release(vb.session);
        atomic_store(&a.jvm, NULL);
        atomic_store(&b.jvm, NULL);
    }
    assert(calls == 100);
    puts("stop escalation lease: OK");
    return 0;
}
"""


class StopEscalationLeaseTest(unittest.TestCase):
    def test_escalation_releases_lifecycle_mutex_and_pins_heap(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        src = BRIDGE.read_text(encoding="utf-8")
        begin = src.index("int jvm_bridge_interrupt_active_threads_for_token(")
        end = src.index("int jvm_bridge_interrupt_active_threads(void)", begin)
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "stop.c"
            exe = Path(td) / "stop"
            source.write_text(PRELUDE + src[begin:end] + MAIN, encoding="utf-8")
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-pthread", "-I", str(JVM), str(source), "-o", str(exe)],
                           check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("stop escalation lease: OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
