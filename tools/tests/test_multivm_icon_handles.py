"""Compile production RenderImage owner lookup in a pthread host harness.

This does not simulate Metal, CoreGraphics, GC/JIT or running two miniJVMs.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "J2MEEmulator/NativeBridge/j2me_render.m"
UI = ROOT / "J2MEEmulator/NativeBridge/j2me_ui.m"

PREAMBLE = r"""
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>
typedef long long s64;
typedef struct {
    uint64_t heap_key;
    _Atomic int32_t refcount;
} RenderImage;
typedef struct { atomic_int busy; } spinlock_t;
static spinlock_t g_track_lock = {0};
static RenderImage *g_live_img[16];
static int g_live_img_count = 0;
static uint64_t stopped_owner;
static int render_owner_stopped_locked(uint64_t key) {
    return key == stopped_owner;
}
static void spin_lock(spinlock_t *l) {
    while (atomic_exchange_explicit(&l->busy, 1, memory_order_acquire))
        sched_yield();
}
static void spin_unlock(spinlock_t *l) {
    atomic_store_explicit(&l->busy, 0, memory_order_release);
}
"""

TEST = r"""
typedef struct {
    s64 handle;
    uint64_t owner_key;
    int failed;
} Job;

static void *worker(void *arg) {
    Job *job = (Job *)arg;
    for (int i = 0; i < 50000; ++i) {
        RenderImage *img = img_acquire_for_owner(job->handle, job->owner_key);
        if (!img || img->heap_key != job->owner_key) {
            ++job->failed;
            continue;
        }
        atomic_fetch_sub_explicit(&img->refcount, 1, memory_order_release);
    }
    return NULL;
}

int main(void) {
    RenderImage a, b;
    a.heap_key = 101;
    b.heap_key = 202;
    atomic_init(&a.refcount, 1);
    atomic_init(&b.refcount, 1);
    g_live_img[0] = &a;
    g_live_img[1] = &b;
    g_live_img_count = 2;
    if (img_acquire_for_owner((s64)(intptr_t)&a, 202)) return 1;
    if (img_acquire_for_owner((s64)(intptr_t)&b, 101)) return 2;
    if (img_acquire_for_owner((s64)0x1234, 101)) return 3;
    if (img_acquire_for_owner((s64)(intptr_t)&a, 0)) return 4;
    Job wa = {(s64)(intptr_t)&a, 101, 0};
    Job wb = {(s64)(intptr_t)&b, 202, 0};
    pthread_t ta, tb;
    if (pthread_create(&ta, NULL, worker, &wa)) return 5;
    if (pthread_create(&tb, NULL, worker, &wb)) return 6;
    pthread_join(ta, NULL);
    pthread_join(tb, NULL);
    if (wa.failed || wb.failed ||
        atomic_load(&a.refcount) != 1 ||
        atomic_load(&b.refcount) != 1) return 7;
    stopped_owner = 101;
    if (img_acquire_for_owner((s64)(intptr_t)&a, 101)) return 8;
    if (!img_acquire_for_owner((s64)(intptr_t)&b, 202)) return 11;
    atomic_fetch_sub(&b.refcount, 1);
    stopped_owner = 0;
    // Simulate a new native VM generation reusing the same tracked slot.
    a.heap_key = 303;
    if (img_acquire_for_owner((s64)(intptr_t)&a, 101)) return 9;
    RenderImage *newA = img_acquire_for_owner((s64)(intptr_t)&a, 303);
    if (newA != &a) return 10;
    atomic_fetch_sub(&a.refcount, 1);
    return atomic_load(&a.refcount) != 1;
}
"""

class MultiVMIconHandlesTest(unittest.TestCase):
    def test_real_image_lookup_rejects_foreign_or_stale_handle(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("C compiler unavailable")
        renderer = RENDER.read_text(encoding="utf-8")
        start = renderer.index("static RenderImage *img_acquire_for_owner(")
        end = renderer.index("\nstatic inline void img_release(", start)
        production = renderer[start:end]
        self.assertIn("candidate->heap_key == owner_key", production)
        self.assertIn("candidate != target", production)
        with tempfile.TemporaryDirectory(prefix="jarbox-icon-handles-") as tmp:
            src = Path(tmp) / "test.c"
            executable = Path(tmp) / "test"
            src.write_text(PREAMBLE + production + "\n" + TEST)
            subprocess.run(
                [cc, "-std=c11", "-Wall", "-Wextra", "-O2", "-pthread",
                 str(src), "-o", str(executable)],
                check=True, capture_output=True, text=True, timeout=45)
            subprocess.run([str(executable)], check=True,
                           capture_output=True, text=True, timeout=15)

    def test_midp_icon_uses_owned_snapshot_not_legacy_lookup(self):
        ui = UI.read_text(encoding="utf-8")
        self.assertIn("j2me_render_copy_image_for_vm(handle, runtime->jvm)", ui)
        self.assertNotIn("j2me_render_copy_image(handle)", ui)

if __name__ == "__main__":
    unittest.main()
