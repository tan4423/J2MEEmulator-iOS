"""Exercise production focus/park and cleanup admission with mock native destinations.

The session lease header is real. UIKit, renderer, input and registry boundaries
are mocked; this is not a two-MIDlet or iPhone runtime test.
"""
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
#include <errno.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include "jarbox_session.h"

enum { BRIDGE_RUNNING = 2, BRIDGE_CLEANUP = 3 };
typedef struct { JarBoxSession *session; uint64_t key; } MiniJVM;
typedef struct {
    MiniJVM *jvm;
    atomic_int phase;
    _Atomic uint64_t token;
} JarBoxVMContext;
static JarBoxVMContext a, b;
static MiniJVM va, vb;
static int g_bridge_registry, g_bridge_focus;
static _Atomic uint64_t visible, render, input, ui;
static atomic_int attach_entered, cleanup_attempted, race_active;
static int reject_ui;
"""
MOCKS = r"""
static JarBoxVMContext *slot_for(uint64_t token) {
    return token == 11 ? &a : token == 22 ? &b : NULL;
}
static int jarbox_registry_contains_token(int *r, uint64_t token) {
    (void)r;
    return slot_for(token) != NULL;
}
static MiniJVM *bridge_pin_running_owner(uint64_t token, JarBoxSession **held) {
    *held = NULL;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = slot_for(token);
    MiniJVM *vm = slot && atomic_load(&slot->phase) == BRIDGE_RUNNING ? slot->jvm : NULL;
    if (vm && jarbox_session_reserve_callback(vm->session)) *held = vm->session;
    else vm = NULL;
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return vm;
}
static void check_transition_lock(void) {
    assert(pthread_mutex_trylock(&g_bridge_focus_transition_lock) == EBUSY);
    /* Native destination changes must not hold the lifecycle mutex. */
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
}
static void jarbox_registry_begin_stop(int *r, uint64_t token) {
    (void)r;
    assert(pthread_mutex_trylock(&g_bridge_focus_transition_lock) == EBUSY);
    JarBoxVMContext *slot = slot_for(token);
    assert(slot);
    assert(jarbox_session_callback_count(slot->jvm->session) == 0);
    jarbox_session_begin_stop(slot->jvm->session);
}
static uint64_t jarbox_focus_visible(int *p) { (void)p; return atomic_load(&visible); }
static int jarbox_focus_select(int *p, uint64_t token) {
    (void)p;
    check_transition_lock();
    atomic_store(&visible, token);
    return 1;
}
static void revoke(_Atomic uint64_t *destination, uint64_t key) {
    atomic_compare_exchange_strong(destination, &key, 0);
}
static int jarbox_focus_park_one(int *p, uint64_t token) {
    (void)p;
    check_transition_lock();
    revoke(&visible, token);
    return 1;
}
static int j2me_render_focus_vm(MiniJVM *vm) {
    check_transition_lock();
    if (vm == &va && atomic_load(&race_active)) {
        atomic_store(&attach_entered, 1);
        while (!atomic_load(&cleanup_attempted)) sched_yield();
        /* Cleanup must not close admission before this attach completes. */
        assert(atomic_load(&a.phase) == BRIDGE_RUNNING);
    }
    atomic_store(&render, vm->key);
    return 1;
}
static int j2me_input_focus_vm(MiniJVM *vm) {
    check_transition_lock(); atomic_store(&input, vm->key); return 1;
}
static int j2me_ui_focus_vm(MiniJVM *vm) {
    check_transition_lock();
    if (reject_ui) return 0;
    atomic_store(&ui, vm->key); return 1;
}
static void j2me_render_release_vm(MiniJVM *vm) {
    check_transition_lock(); revoke(&render, vm->key);
}
static void j2me_input_park_vm(MiniJVM *vm) {
    check_transition_lock(); revoke(&input, vm->key);
}
static void j2me_ui_park_vm(MiniJVM *vm) {
    check_transition_lock(); revoke(&ui, vm->key);
}
"""
MAIN = r"""
static void *focus_a(void *unused) {
    (void)unused;
    assert(jvm_bridge_focus_session(11));
    return NULL;
}
static void *cleanup_a(void *unused) {
    (void)unused;
    while (!atomic_load(&attach_entered)) sched_yield();
    atomic_store(&cleanup_attempted, 1);
    bridge_begin_slot_cleanup(&a);
    /* Model owner-only destination revocation immediately after admission
     * closes. The cleanup itself must not hold the transition mutex. */
    assert(pthread_mutex_trylock(&g_bridge_focus_transition_lock) == 0);
    pthread_mutex_unlock(&g_bridge_focus_transition_lock);
    revoke(&render, va.key); revoke(&input, va.key); revoke(&ui, va.key);
    return NULL;
}
int main(void) {
    for (int i = 0; i < 100; ++i) {
        va = (MiniJVM){jarbox_session_create(&va), 101};
        vb = (MiniJVM){jarbox_session_create(&vb), 202};
        assert(va.session && vb.session);
        a.jvm = &va; b.jvm = &vb;
        atomic_store(&a.token, 11); atomic_store(&b.token, 22);
        atomic_store(&a.phase, BRIDGE_RUNNING); atomic_store(&b.phase, BRIDGE_RUNNING);
        assert(jarbox_session_enter_foreground(va.session));
        assert(jarbox_session_enter_foreground(vb.session));
        assert(jarbox_session_park(va.session)); assert(jarbox_session_park(vb.session));
        assert(!jvm_bridge_focus_session(99)); assert(!jvm_bridge_park_session(99));
        assert(jvm_bridge_focus_session(22));
        assert(!jvm_bridge_focus_session(11));
        assert(jvm_bridge_park_session(11)); /* park hidden A, preserve B */
        assert(atomic_load(&visible) == 22 && atomic_load(&render) == 202 &&
               atomic_load(&input) == 202 && atomic_load(&ui) == 202);
        assert(jvm_bridge_park_session(22));
        reject_ui = 1;
        assert(!jvm_bridge_focus_session(11)); /* rollback partial attach */
        reject_ui = 0;
        assert(!atomic_load(&visible) && !atomic_load(&render) &&
               !atomic_load(&input) && !atomic_load(&ui));
        atomic_store(&attach_entered, 0); atomic_store(&cleanup_attempted, 0);
        atomic_store(&race_active, 1);
        pthread_t t1, t2;
        assert(!pthread_create(&t1, NULL, focus_a, NULL));
        assert(!pthread_create(&t2, NULL, cleanup_a, NULL));
        assert(!pthread_join(t1, NULL)); assert(!pthread_join(t2, NULL));
        atomic_store(&race_active, 0);
        assert(!jvm_bridge_focus_session(11));
        assert(!atomic_load(&render) && !atomic_load(&input) && !atomic_load(&ui));
        assert(jarbox_session_active_lease_count(va.session) == 0);
        assert(jarbox_session_mark_dead(va.session));
        assert(jvm_bridge_park_session(11)); /* retire policy in mock */
        assert(jvm_bridge_focus_session(22)); assert(jvm_bridge_park_session(22));
        jarbox_session_begin_stop(vb.session); assert(jarbox_session_mark_dead(vb.session));
        jarbox_session_release(va.session); jarbox_session_release(vb.session);
    }
    puts("focus/cleanup serialization: OK");
    return 0;
}
"""


def harness(src):
    locks = "\n".join(line for line in src.splitlines() if line.startswith((
        "static pthread_mutex_t g_bridge_lifecycle_lock =",
        "static pthread_mutex_t g_bridge_focus_transition_lock =")))
    begin = src.index("int jvm_bridge_park_session(")
    end = src.index("int jvm_bridge_session_is_parked(", begin)
    cleanup = src.index("static void bridge_begin_slot_cleanup(")
    destroy = src.index("static void bridge_destroy_slot(", cleanup)
    return PRELUDE + locks + "\n" + MOCKS + src[begin:end] + src[cleanup:destroy] + MAIN


class FocusCleanupSerializationTest(unittest.TestCase):
    def test_focus_and_cleanup_cannot_overtake_each_other(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "focus.c"
            exe = Path(td) / "focus"
            source.write_text(harness(BRIDGE.read_text(encoding="utf-8")))
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-pthread", "-I", str(JVM), str(source), "-o", str(exe)],
                           check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("focus/cleanup serialization: OK", result.stdout)

    def test_cleanup_closes_admission_before_revoking_native_state(self):
        src = BRIDGE.read_text(encoding="utf-8")
        body = src.split("static void bridge_destroy_slot(", 1)[1]
        self.assertLess(body.index("bridge_begin_slot_cleanup(slot);"),
                        body.index("j2me_render_release_vm(slot->jvm);"))
        close = src.split("static void bridge_begin_slot_cleanup(", 1)[1].split("\n}", 1)[0]
        self.assertLess(close.index("pthread_mutex_lock(&g_bridge_focus_transition_lock);"),
                        close.index("pthread_mutex_lock(&g_bridge_lifecycle_lock);"))
        self.assertLess(close.index("jarbox_registry_begin_stop("),
                        close.index("pthread_mutex_unlock(&g_bridge_focus_transition_lock);"))


if __name__ == "__main__":
    unittest.main()
