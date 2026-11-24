"""Real C SPSC ring tests plus source guards for JarBox's native VM ownership.

These tests compile the same portable header used by j2me_input.c.
The native iOS/JVM integration still requires Codemagic and device testing.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "J2MEEmulator/NativeBridge"
RING = BRIDGE / "jarbox_input_ring.h"
INPUT = BRIDGE / "j2me_input.c"
JVM = BRIDGE / "jvm_bridge.c"

SOURCE = r'''
#include "jarbox_input_ring.h"
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    JarBoxInputRing *ring;
    int tag;
    int n;
    int error;
} Worker;

static void *writer(void *opaque) {
    Worker *w = (Worker *)opaque;
    for (int i = 0; i < w->n; i++) {
        JarBoxInputEvent item = {w->tag, i, w->tag ^ i, w->tag + i};
        while (!jarbox_input_ring_push(w->ring, &item)) sched_yield();
    }
    return NULL;
}

static void *reader(void *opaque) {
    Worker *w = (Worker *)opaque;
    for (int i = 0; i < w->n; i++) {
        JarBoxInputEvent item;
        while (!jarbox_input_ring_pop(w->ring, &item)) sched_yield();
        if (item.type != w->tag || item.x != i ||
            item.y != (w->tag ^ i) || item.keyCode != w->tag + i)
            w->error = 1;
    }
    return NULL;
}

int main(void) {
    JarBoxInputRing a = {0}, b = {0};
    JarBoxInputEvent item, out;
    if (jarbox_input_ring_pop(&a, &out)) return 1;

    // 255 is the SPSC capacity (one reserved slot).
    for (int i = 0; i < 255; ++i) {
        item = (JarBoxInputEvent){1, i, 0, 0};
        if (!jarbox_input_ring_push(&a, &item)) return 2;
    }
    item = (JarBoxInputEvent){1, 255, 0, 0};
    if (jarbox_input_ring_push(&a, &item)) return 3;

    // Ring B is independent of a full A.
    item = (JarBoxInputEvent){2, 123, 456, 789};
    if (!jarbox_input_ring_push(&b, &item)) return 4;
    if (!jarbox_input_ring_pop(&b, &out) ||
        out.type != 2 || out.x != 123) return 5;

    for (int i = 0; i < 255; ++i) {
        if (!jarbox_input_ring_pop(&a, &out) || out.x != i) return 6;
    }
    if (jarbox_input_ring_pop(&a, &out)) return 7;
    jarbox_input_ring_reset(&a);

    // Real concurrent producers/consumers on *separate* context rings.
    Worker wa = {&a, 100, 12000, 0};
    Worker wb = {&b, 200, 12000, 0};
    pthread_t pa, ca, pb, cb;
    if (pthread_create(&pa, NULL, writer, &wa) != 0) return 8;
    if (pthread_create(&pb, NULL, writer, &wb) != 0) return 9;
    if (pthread_create(&ca, NULL, reader, &wa) != 0) return 10;
    if (pthread_create(&cb, NULL, reader, &wb) != 0) return 11;
    pthread_join(pa, NULL); pthread_join(pb, NULL);
    pthread_join(ca, NULL); pthread_join(cb, NULL);
    if (wa.error || wb.error) return 12;
    if (jarbox_input_ring_pop(&a, &out) ||
        jarbox_input_ring_pop(&b, &out)) return 13;

    // Resetting A never modifies B's unread events.
    item = (JarBoxInputEvent){99, 5, 6, 7};
    if (!jarbox_input_ring_push(&b, &item)) return 14;
    jarbox_input_ring_reset(&a);
    if (!jarbox_input_ring_pop(&b, &out) || out.type != 99) return 15;
    return 0;
}
'''


class MultiVMInputIsolationTest(unittest.TestCase):
    def test_real_concurrent_ring_isolation(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("No C compiler available")
        with tempfile.TemporaryDirectory(prefix="jarbox-isolated-input-") as t:
            path = Path(t)
            src = path / "input_test.c"
            exe = path / "input_test"
            src.write_text(SOURCE)
            subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-pthread", "-I", str(BRIDGE), str(src), "-o", str(exe)],
                capture_output=True, text=True, check=True, timeout=60,
            )
            subprocess.run([str(exe)], capture_output=True,
                           text=True, check=True, timeout=25)

    def test_native_routing_is_by_owning_jvm(self):
        native = INPUT.read_text(encoding="utf-8")
        bridge = JVM.read_text(encoding="utf-8")
        self.assertIn('#include "jarbox_input_ring.h"', native)
        self.assertIn('JarBoxInputRing ring;', native)
        self.assertIn('JARBOX_INPUT_CONTEXT_CAPACITY 64', native)
        self.assertIn('context_for_runtime(runtime)', native)
        self.assertIn('#include "garbage.h"', native)
        self.assertIn('jarbox_input_ring_push(&ctx->ring', native)
        self.assertIn('jarbox_input_ring_pop(&ctx->ring', native)
        self.assertIn('j2me_input_binding_generation(MiniJVM *vm)', native)
        self.assertIn('j2me_input_post_key_to_vm(MiniJVM *vm, uint64_t generation', native)
        self.assertIn('ctx->generation == generation', native)
        self.assertIn('ctx->display_wait_cond', native)
        self.assertIn('ctx->display_wait_lock', native)
        self.assertIn('j2me_input_release_vm(MiniJVM *vm)', native)
        self.assertIn('void j2me_input_park_vm(MiniJVM *vm)', native)
        self.assertIn('if (ctx && visible_input_context() == ctx)', native)
        self.assertIn('j2me_input_park_vm(owner)', bridge)
        self.assertIn('j2me_input_quiesce_vm(owner)', bridge)
        self.assertIn('j2me_input_release_for_token(destroyed_token)', bridge)
        self.assertIn('j2me_input_release_vm(slot->jvm)', bridge)
        self.assertIn('if (!j2me_input_reg_natives(slot->jvm))', bridge)
        self.assertIn('JarBoxVMContext', bridge)
        self.assertIn('atomic_int stop_requested;', bridge)
        self.assertIn('jvm_bridge_is_stop_requested_for_vm', bridge)
        self.assertIn('jarbox_registry_should_stop_vm(&g_bridge_registry, vm)', bridge)
        self.assertIn('jvm_bridge_visit_running_vm_for_token(', bridge)
        self.assertIn('treo_display_wait_set_for_token(uint64_t token, int enabled)', native)
        self.assertIn('jvm_bridge_visit_running_vm_for_token(token, treo_wait_visitor, &enabled)', native)
        self.assertIn('pthread_mutex_lock(&g_input_context_lock);', native)
        self.assertIn('_Atomic uint64_t token;', bridge)
        # Keep the global singleton gate until every native subsystem is isolated.
        self.assertIn('bridge_reserve_slot_locked(', bridge)
        self.assertNotIn('static InputEvent g_queue', native)
        self.assertNotIn('atomic_int g_write_pos', native)
        self.assertNotIn('atomic_int g_read_pos', native)


if __name__ == "__main__":
    unittest.main()
