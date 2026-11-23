"""Compile the real renderer's owner partition helpers with two VM generations.

This is a host C test for the ownership *selection algorithm*, not proof
that CoreGraphics, callbacks, teardown or two JVMs run safely on iPhone.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "J2MEEmulator/NativeBridge/j2me_render.m"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"

PREAMBLE = r"""
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#include <stdlib.h>
#include <stdio.h>
typedef long long s64;
typedef struct RenderContext {
    uint64_t heap_key; int id; struct RenderContext *next_live;
} RenderContext;
typedef struct RenderImage {
    uint64_t heap_key; int id; struct RenderImage *next_live;
} RenderImage;
typedef struct { atomic_int held; } spinlock_t;
static spinlock_t g_track_lock = {0};
static RenderContext *g_live_rc[1024];
static RenderImage *g_live_img[1024];
static int g_live_rc_count, g_live_img_count;
#define RENDER_HANDLE_BUCKETS 8192u
static RenderContext *g_rc_live_buckets[RENDER_HANDLE_BUCKETS];
static RenderImage *g_img_live_buckets[RENDER_HANDLE_BUCKETS];
static void spin_lock(spinlock_t *l) {
    while (atomic_exchange_explicit(&l->held, 1, memory_order_acquire))
        sched_yield();
}
static void spin_unlock(spinlock_t *l) {
    atomic_store_explicit(&l->held, 0, memory_order_release);
}
"""

TEST = r"""
enum { A = 101, B = 202, C = 303, N = 128 };
static RenderContext rc[3*N];
static RenderImage img[3*N];

typedef struct { uint64_t key; int rc_count, img_count; } Work;
static void *release_owner(void *arg) {
    Work *w = arg;
    RenderContext *r;
    RenderImage *im;
    while ((r = take_rc_for_owner(w->key))) {
        if (r->heap_key != w->key) abort();
        ++w->rc_count;
    }
    while ((im = take_img_for_owner(w->key))) {
        if (im->heap_key != w->key) abort();
        ++w->img_count;
    }
    return NULL;
}

int main(void) {
    for (int i = 0; i < 3*N; ++i) {
        uint64_t key = i%3 == 0 ? A : i%3 == 1 ? B : C;
        rc[i].heap_key = img[i].heap_key = key;
        rc[i].id = img[i].id = i;
        g_live_rc[g_live_rc_count++] = &rc[i];
        g_live_img[g_live_img_count++] = &img[i];
        unsigned rb = render_handle_bucket((s64)(intptr_t)&rc[i]);
        unsigned ib = render_handle_bucket((s64)(intptr_t)&img[i]);
        rc[i].next_live = g_rc_live_buckets[rb];
        g_rc_live_buckets[rb] = &rc[i];
        img[i].next_live = g_img_live_buckets[ib];
        g_img_live_buckets[ib] = &img[i];
    }
    if (take_rc_for_owner(0) || take_img_for_owner(0)) return 1;
    Work a = {A, 0, 0}, b = {B, 0, 0};
    pthread_t a_thread, b_thread;
    if (pthread_create(&a_thread, NULL, release_owner, &a)) return 2;
    if (pthread_create(&b_thread, NULL, release_owner, &b)) return 3;
    pthread_join(a_thread, NULL);
    pthread_join(b_thread, NULL);
    if (a.rc_count != N || a.img_count != N) return 4;
    if (b.rc_count != N || b.img_count != N) return 5;
    if (g_live_rc_count != N || g_live_img_count != N) return 6;
    for (int i = 0; i < N; ++i)
        if (g_live_rc[i]->heap_key != C ||
            g_live_img[i]->heap_key != C) return 7;
    // Reused JVM pointer with a NEW generation must not match old ownership.
    Work old_a = {A, 0, 0};
    release_owner(&old_a);
    if (old_a.rc_count || old_a.img_count) return 8;
    Work c = {C, 0, 0};
    release_owner(&c);
    if (c.rc_count != N || c.img_count != N) return 9;
    if (g_live_rc_count || g_live_img_count) return 10;
    return 0;
}
"""

class MultiVMRenderCleanupTest(unittest.TestCase):
    def test_compiled_real_owner_partition_keeps_other_vm_handles(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("C compiler unavailable")
        src = RENDER.read_text(encoding="utf-8")
        start = src.index("static RenderContext *take_rc_for_owner(")
        end = src.index("\nvoid j2me_render_cleanup_for_owner(", start)
        production = src[start:end]
        hash_start = src.index("static inline unsigned render_handle_bucket(")
        hash_end = src.index("\nstatic int track_rc(", hash_start)
        hash_lookup = src[hash_start:hash_end]
        self.assertIn("g_live_rc[i]->heap_key == key", production)
        self.assertIn("g_live_img[i]->heap_key == key", production)
        with tempfile.TemporaryDirectory(prefix="jarbox-render-owner-") as tmp:
            path = Path(tmp)
            c_file = path / "partition.c"
            exe = path / "partition"
            c_file.write_text(PREAMBLE + hash_lookup + production + "\n" + TEST)
            subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-pthread",
                 str(c_file), "-o", str(exe)],
                check=True, capture_output=True, text=True, timeout=45)
            subprocess.run([str(exe)], check=True, capture_output=True,
                           text=True, timeout=15)

    def test_image_creation_and_frame_publish_are_generation_guarded(self):
        render = RENDER.read_text(encoding="utf-8")
        self.assertIn("if (!rc->heap_key) { free(rc); return NULL; }", render)
        self.assertIn("if (!owner_key || !data || length <= 0) return NULL;", render)
        self.assertIn("if (!img->ctx) { free(img); return NULL; }", render)
        self.assertIn("CGImageRelease(cgImage);\n        free(img);", render)
        flush = render[render.index("static s32 n_flushToScreen("):
                       render.index("// --- Color & State ---", render.index("static s32 n_flushToScreen("))]
        self.assertIn("callerKey != visibleKey", flush)
        self.assertIn("callerKey != atomic_load_explicit(", flush)
        self.assertIn("CGImageRelease(image);", flush)
        self.assertIn("owned_flush(image, rc->width, rc->height, rc->heap_key)", flush)

    def test_haptic_callbacks_require_live_foreground_vm_generation(self):
        render = RENDER.read_text(encoding="utf-8")
        self.assertIn("render_haptic_release_owner(key);", render)
        self.assertIn("if (owner_key != j2me_render_visible_owner_key()) return;", render)
        self.assertIn("atomic_store_explicit(&g_haptic_player_owner_key, owner_key", render)
        self.assertIn("atomic_load_explicit(&g_haptic_player_owner_key, memory_order_acquire)", render)

    def test_bridge_cleanup_sequence_and_scoped_stop_are_truthful(self):
        render = RENDER.read_text(encoding="utf-8")
        bridge = BRIDGE.read_text(encoding="utf-8")
        start = bridge.index("void jvm_bridge_destroy(void)")
        body = bridge[start:]
        self.assertLess(body.index("jarbox_native_heap_key_for_vm(destroyed_owner)"),
                        body.index("jvm_destroy(g_bridge_vm.jvm)"))
        self.assertLess(body.index("j2me_render_cleanup_for_owner(destroyed_render_key)"),
                        body.index("jarbox_native_heap_unregister_vm(destroyed_owner)"))
        cleanup = render[render.index("void j2me_render_cleanup_for_owner("):]
        self.assertIn("take_rc_for_owner(owner_key)", cleanup)
        self.assertIn("take_img_for_owner(owner_key)", cleanup)
        self.assertNotIn("g_live_rc_count = 0;", cleanup)
        self.assertNotIn("g_live_img_count = 0;", cleanup)
        self.assertIn("g_stopped_render_owners[i] == owner_key", cleanup)
        self.assertIn("if (*cursor) *cursor = found->next_live;", render)
        self.assertIn("jvm_bridge_supported_concurrent_sessions() == 1", cleanup)
        self.assertIn("dispatch_async(dispatch_get_main_queue(), ^{", cleanup)
        self.assertIn("haptic_owner != teardown_key", cleanup)
        self.assertIn("single_vm_shutdown = jvm_bridge_supported_concurrent_sessions() == 1", cleanup)
        # A stopped A must not disable B. The one-JVM gate is kept for the
        # remaining shared UI/Metal/Treo components, not this 2D stop bit.
        self.assertNotIn("g_render_stopped", render)
        self.assertIn("j2me_render_stop_for_owner(destroyed_render_key);", bridge)
        self.assertIn("render_owner_stopped_locked(owner_key)", render)
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return 1;", bridge)

if __name__ == "__main__":
    unittest.main()
