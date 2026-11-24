"""Check production 2D raster mode ownership and per-generation Metal cache.

Only the exact extracted C owner-mode function executes on the host.
Apple Metal, Objective-C memory management and iPhone UI are source-contract
checks here, NOT an end-to-end multi-JVM stress or build test.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "J2MEEmulator/NativeBridge/j2me_render.m"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"
C_PREAMBLE = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
typedef struct RenderContext {
    uint64_t heap_key;
    _Atomic int afk_mode;
} RenderContext;
typedef struct { atomic_int held; } spinlock_t;
static spinlock_t g_track_lock = {0};
static RenderContext *g_live_rc[4];
static int g_live_rc_count = 0;
static void spin_lock(spinlock_t *p) {
    while (atomic_exchange_explicit(&p->held, 1, memory_order_acquire))
        sched_yield();
}
static void spin_unlock(spinlock_t *p) {
    atomic_store_explicit(&p->held, 0, memory_order_release);
}
"""
C_TEST = r"""
typedef struct { uint64_t owner; int mode; } Work;
static void *work(void *arg) {
    Work *w = arg;
    for (int i = 0; i < 20000; ++i)
        treo_render_owner_mode_set(w->owner, w->mode);
    return NULL;
}
int main(void) {
    RenderContext a = {.heap_key = 101}, a2 = {.heap_key = 101};
    RenderContext b = {.heap_key = 202};
    g_live_rc[0] = &a;
    g_live_rc[1] = &b;
    g_live_rc[2] = &a2;
    g_live_rc_count = 3;
    Work wa = {101, 8}, wb = {202, 2};
    pthread_t t1, t2;
    if (pthread_create(&t1, NULL, work, &wa) ||
        pthread_create(&t2, NULL, work, &wb)) return 1;
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);
    if (atomic_load(&a.afk_mode) != 8 ||
        atomic_load(&a2.afk_mode) != 8 ||
        atomic_load(&b.afk_mode) != 2) return 2;
    treo_render_owner_mode_set(101, 0);
    if (atomic_load(&a.afk_mode) ||
        atomic_load(&a2.afk_mode) ||
        atomic_load(&b.afk_mode) != 2) return 3;
    treo_render_owner_mode_set(0, 8);
    if (atomic_load(&b.afk_mode) != 2) return 4;
    puts("owner mode: OK (A/B threads; stop A leaves B)");
    return 0;
}
"""


class MultiVMRenderOwnerMetalTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = RENDER.read_text(encoding="utf-8")

    def test_exact_production_owner_mode_stress(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("No host C compiler")
        start = self.src.index(
            "static void treo_render_owner_mode_set(uint64_t owner_key, int mode) {"
        )
        end = self.src.index("// Each graphics handle carries", start)
        body = self.src[start:end]
        with tempfile.TemporaryDirectory(prefix="jarbox-render-owner-") as td:
            source, exe = Path(td) / "owner.c", Path(td) / "owner"
            source.write_text(C_PREAMBLE + body + C_TEST, encoding="utf-8")
            built = subprocess.run(
                [cc, "-std=c11", "-O1", "-Wall", "-Wextra", "-Werror",
                 "-pthread", str(source), "-o", str(exe)],
                text=True, capture_output=True, timeout=40)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            run = subprocess.run(
                [str(exe)], text=True, capture_output=True, timeout=30)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("owner mode: OK", run.stdout)

    def test_canvas_contexts_use_owner_mode(self):
        src = self.src
        self.assertIn("_Atomic int afk_mode; // JVM generation-owned 2D raster mode", src)
        self.assertIn("atomic_init(&rc->afk_mode, owner && owner->session ?", src)
        self.assertIn("atomic_init(&rc->afk_mode, treo_runtime_mode(runtime));", src)
        self.assertIn("const uint64_t key = jarbox_native_heap_key_for_vm(vm);", src)
        self.assertIn("treo_render_owner_mode_set(key, mode);", src)
        self.assertIn("const int afkMode = treo_rc_mode(rc);", src)
        self.assertIn("!treo_rc_afk(rc) &&", src)
        self.assertIn("treo_rc_fast_canvas(rc)", src)

    def test_metal_per_owner_target_texture_and_retirement(self):
        src = self.src
        self.assertIn("treo_live_owner_targets[owner]", src)
        self.assertIn("treo_live_owner_textures[owner]", src)
        self.assertIn("treo_live_owner_texture_bytes[owner]", src)
        self.assertIn("treo_live_texture(s->image, s->cacheable, rc->heap_key)", src)
        self.assertIn("[treo_live_owner_targets removeObjectForKey:key]", src)
        self.assertIn("[treo_live_owner_textures removeObjectForKey:key]", src)
        self.assertIn("treo_live_release_owner(owner_key);", src)
        self.assertIn("os_unfair_lock_trylock(&treo_live_gpu_lock)", src)
        self.assertIn("[command waitUntilCompleted];", src)
        self.assertNotIn("static id<MTLTexture> treo_live_target;", src)
        self.assertIn(
            "int jvm_bridge_supported_concurrent_sessions(void) {\n    return 1;",
            BRIDGE.read_text(encoding="utf-8"),
        )


if __name__ == "__main__":
    unittest.main()
