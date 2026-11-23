"""Compile exact production 2D handle hash/acquire/stop helpers for POSIX.

This exercises two *simulated owner generations* and pthread contention,
not two MiniJVMs, UIKit, CoreGraphics, Metal or a running MIDlet.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "J2MEEmulator/NativeBridge/j2me_render.m"

PREAMBLE = r"""
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include "jarbox_flush_routes.h"
// The production stop helper now revokes the matching generation's
// callback route as well as its Canvas handle generation.
static JarBoxFlushRoutes g_flush_routes = JARBOX_FLUSH_ROUTES_INITIALIZER;
static void host_flush(void *image, int width, int height, uint64_t owner_key) {
    (void)image; (void)width; (void)height; (void)owner_key;
}
typedef long long s64;
typedef struct RenderContext {
    uint64_t heap_key;
    _Atomic int32_t refcount;
    _Atomic int java_owned;
    struct RenderContext *next_live;
} RenderContext;
typedef struct RenderImage {
    uint64_t heap_key;
    _Atomic int32_t refcount;
    _Atomic int java_owned;
    struct RenderImage *next_live;
} RenderImage;
typedef struct { atomic_int held; } spinlock_t;
static spinlock_t g_track_lock = {0};
#define TRACK_MAX 8192
static RenderContext *g_live_rc[TRACK_MAX];
static int g_live_rc_count;
static RenderImage *g_live_img[TRACK_MAX];
static int g_live_img_count;
#define RENDER_HANDLE_BUCKETS 8192u
static RenderContext *g_rc_live_buckets[RENDER_HANDLE_BUCKETS];
static RenderImage *g_img_live_buckets[RENDER_HANDLE_BUCKETS];
static void spin_lock(spinlock_t *lock) {
    while (atomic_exchange_explicit(&lock->held, 1, memory_order_acquire))
        sched_yield();
}
static void spin_unlock(spinlock_t *lock) {
    atomic_store_explicit(&lock->held, 0, memory_order_release);
}
"""
PROGRAM = r"""
typedef struct { s64 handle; uint64_t owner; int is_image; int failed; } Job;
static void *worker(void *arg) {
    Job *j = arg;
    for (int i = 0; i < 18000; ++i) {
        if (j->is_image) {
            RenderImage *p = img_acquire(j->handle, j->owner);
            if (!p || p->heap_key != j->owner) { j->failed++; continue; }
            atomic_fetch_sub(&p->refcount, 1);
        } else {
            RenderContext *p = rc_acquire(j->handle, j->owner);
            if (!p || p->heap_key != j->owner) { j->failed++; continue; }
            atomic_fetch_sub(&p->refcount, 1);
        }
    }
    return NULL;
}
int main(void) {
    RenderContext a = {0}, b = {0};
    RenderImage ai = {0}, bi = {0};
    a.heap_key = ai.heap_key = 101;
    b.heap_key = bi.heap_key = 202;
    atomic_init(&a.refcount, 1); atomic_init(&b.refcount, 1);
    atomic_init(&ai.refcount, 1); atomic_init(&bi.refcount, 1);
    atomic_init(&a.java_owned, 1); atomic_init(&b.java_owned, 1);
    if (!track_rc(&a) || !track_rc(&b) ||
        !track_img(&ai) || !track_img(&bi)) return 1;
    // Bind callbacks for both owner generations before the real stop code.
    jarbox_flush_default_owned(&g_flush_routes, host_flush);
    if (!jarbox_flush_route_bind(&g_flush_routes, 101) ||
        !jarbox_flush_route_bind(&g_flush_routes, 202)) return 19;
    if (rc_acquire((s64)(intptr_t)&a, 202)) return 2;
    if (img_acquire((s64)(intptr_t)&ai, 202)) return 3;
    if (rc_acquire((s64)0x1234, 101)) return 4;
    if (img_acquire((s64)0x1234, 101)) return 5;
    Job jobs[4] = {
        {(s64)(intptr_t)&a, 101, 0, 0},
        {(s64)(intptr_t)&ai, 101, 1, 0},
        {(s64)(intptr_t)&b, 202, 0, 0},
        {(s64)(intptr_t)&bi, 202, 1, 0}};
    pthread_t threads[4];
    for (int i = 0; i < 4; ++i)
        if (pthread_create(&threads[i], NULL, worker, &jobs[i])) return 6;
    for (int i = 0; i < 4; ++i) pthread_join(threads[i], NULL);
    for (int i = 0; i < 4; ++i) if (jobs[i].failed) return 7;
    if (atomic_load(&a.refcount) != 1 ||
        atomic_load(&ai.refcount) != 1 ||
        atomic_load(&b.refcount) != 1 ||
        atomic_load(&bi.refcount) != 1) return 8;
    j2me_render_stop_for_owner(101);
    // Revoking A must leave B's frame callback and handles intact.
    JarBoxFlushLegacy legacy = NULL;
    JarBoxFlushOwned owned = NULL;
    if (jarbox_flush_route_lookup(&g_flush_routes, 101, &legacy, &owned) ||
        !jarbox_flush_route_lookup(&g_flush_routes, 202, &legacy, &owned) ||
        owned != host_flush) return 20;
    if (rc_acquire((s64)(intptr_t)&a, 101) ||
        img_acquire((s64)(intptr_t)&ai, 101)) return 9;
    RenderContext *bRef = rc_acquire((s64)(intptr_t)&b, 202);
    RenderImage *biRef = img_acquire((s64)(intptr_t)&bi, 202);
    if (bRef != &b || biRef != &bi) return 10;
    atomic_fetch_sub(&b.refcount, 1);
    atomic_fetch_sub(&bi.refcount, 1);
    if (take_rc_for_owner(101) != &a || take_img_for_owner(101) != &ai)
        return 11;
    if (rc_acquire((s64)(intptr_t)&a, 101) ||
        img_acquire((s64)(intptr_t)&ai, 101)) return 12;
    bRef = rc_acquire((s64)(intptr_t)&b, 202);
    if (bRef != &b) return 13;
    atomic_fetch_sub(&b.refcount, 1);
    if (take_rc_for_owner(202) != &b ||
        take_img_for_owner(202) != &bi) return 14;
    if (g_live_rc_count || g_live_img_count) return 15;
    for (int i = 0; i < 8192; ++i)
        if (g_rc_live_buckets[i] || g_img_live_buckets[i]) return 16;
    if (atomic_exchange(&a.java_owned, 0) != 1) return 17;
    if (atomic_exchange(&a.java_owned, 0) != 0) return 18;

    /* The sliced production source also contains untrack_rc/untrack_img.
     * Exercise real removal instead of disabling -Werror for unused helpers.
     * A new generation's callbacks and handles must not inherit stale entries. */
    RenderContext c = {0};
    RenderImage ci = {0};
    c.heap_key = ci.heap_key = 303;
    atomic_init(&c.refcount, 1);
    atomic_init(&ci.refcount, 1);
    atomic_init(&c.java_owned, 1);
    atomic_init(&ci.java_owned, 1);
    if (!track_rc(&c) || !track_img(&ci)) return 21;
    untrack_rc(&c);
    untrack_img(&ci);
    if (g_live_rc_count || g_live_img_count ||
        rc_acquire((s64)(intptr_t)&c, 303) ||
        img_acquire((s64)(intptr_t)&ci, 303)) return 22;
    for (int i = 0; i < 8192; ++i)
        if (g_rc_live_buckets[i] || g_img_live_buckets[i]) return 23;

    puts("2D owned handle host harness: OK (two generations, threads, stop A / retain B)");
    return 0;
}
"""

def section(code, start, end):
    first = code.index(start)
    second = code.index(end, first)
    return code[first:second]

class MultiVMRenderHandleHashTest(unittest.TestCase):
    def test_prod_2d_registry_and_owner_stop(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if cc is None:
            self.skipTest("C compiler missing")
        code = RENDER.read_text(encoding="utf-8")
        source = (
            PREAMBLE +
            section(code, "#define RENDER_STOP_OWNER_SLOTS",
                    "// Global tracking arrays") +
            section(code, "static inline unsigned render_handle_bucket(",
                    "static int track_rc(") +
            # Only extract the 2D live registry helpers. The following
            # per-owner AFK-mode updater has its own exact-source pthread test
            # and requires RenderContext.afk_mode, absent from this mock struct.
            section(code, "static int track_rc(",
                    "/* A transition never mutates buffers") +
            section(code, "static inline RenderContext *rc_acquire(",
                    "static inline void rc_release(") +
            section(code, "static inline RenderImage *img_acquire(",
                    "// LCDUI icon reads") +
            section(code, "void j2me_render_stop_for_owner(",
                    "// Ownership is by native JVM generation") +
            section(code, "static RenderContext *take_rc_for_owner(",
                    "void j2me_render_cleanup_for_owner(") +
            PROGRAM)
        self.assertIn("render_owner_stopped_locked(owner_key)", source)
        self.assertIn("candidate->heap_key == owner_key", source)
        self.assertIn("g_rc_live_buckets", source)
        self.assertIn("untrack_rc(&c);", source)
        self.assertIn("untrack_img(&ci);", source)
        with tempfile.TemporaryDirectory(prefix="jarbox-render-hash-") as t:
            src = Path(t) / "owned.c"
            exe = Path(t) / "owned"
            src.write_text(source, encoding="utf-8")
            build = subprocess.run(
                [cc, "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror",
                 "-pthread", "-I", str(RENDER.parent), str(src), "-o", str(exe)],
                capture_output=True, text=True, timeout=45)
            self.assertEqual(build.returncode, 0,
                             build.stdout + build.stderr)
            run = subprocess.run([str(exe)], capture_output=True,
                                 text=True, timeout=30)
            self.assertEqual(run.returncode, 0,
                             run.stdout + run.stderr)
            self.assertIn("2D owned handle host harness: OK", run.stdout)

    def test_no_raw_dereference_in_any_java_2d_native_acquire(self):
        code = RENDER.read_text(encoding="utf-8")
        self.assertNotIn("g_render_stopped", code)
        self.assertNotIn("RenderContext *rc = (RenderContext *)(intptr_t)handle;", code)
        self.assertNotIn("RenderImage *img = (RenderImage *)(intptr_t)handle;", code)
        self.assertIn("rc->heap_key = img->heap_key;", code)
        self.assertIn("atomic_exchange_explicit(&rc->java_owned, 0,", code)
        self.assertIn("atomic_exchange_explicit(&img->java_owned, 0,", code)
        self.assertIn("if (!track_rc(rc))", code)
        self.assertIn("if (!track_img(img))", code)

if __name__ == "__main__":
    unittest.main()
