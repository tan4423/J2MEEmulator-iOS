"""Host test of the extracted 2D GPU owner predicate and source wiring.

No Apple Metal, Java Runtime or UIKit execution is claimed.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RENDER = Path(__file__).resolve().parents[2] / "J2MEEmulator/NativeBridge/j2me_render.m"
PRELUDE = r'''
#include <assert.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
typedef struct { uint64_t heap_key; _Atomic int afk_mode; } RenderContext;
static _Atomic uint64_t g_visible_render_owner_key;
static inline int treo_rc_afk(const RenderContext *rc) {
    return rc && atomic_load_explicit(&rc->afk_mode,memory_order_acquire)!=0;
}
'''
MAIN = r'''
static void *stress(void *unused) {
    (void)unused;
    for (unsigned i=0;i<100000;i++)
        atomic_store_explicit(&g_visible_render_owner_key,i%3,memory_order_release);
    return NULL;
}
int main(void) {
    RenderContext a={.heap_key=1}, b={.heap_key=2}, stale={.heap_key=3}, missing={0};
    for(int i=0;i<10000;i++) {
        atomic_store(&g_visible_render_owner_key,1);
        assert(treo_rc_may_submit(&a)&&!treo_rc_may_submit(&b));
        atomic_store(&g_visible_render_owner_key,0);
        assert(!treo_rc_may_submit(&a)&&!treo_rc_may_submit(&b));
        atomic_store(&a.afk_mode,8);
        atomic_store(&g_visible_render_owner_key,2);
        assert(!treo_rc_may_submit(&a)&&treo_rc_may_submit(&b));
        atomic_store(&g_visible_render_owner_key,1);
        assert(!treo_rc_may_submit(&a)&&!treo_rc_may_submit(&b));
        atomic_store(&a.afk_mode,0);
        assert(treo_rc_may_submit(&a));
        assert(!treo_rc_may_submit(&missing)&&!treo_rc_may_submit(NULL)&&!treo_rc_may_submit(&stale));
    }
    pthread_t t; assert(!pthread_create(&t,NULL,stress,NULL));
    for(int i=0;i<100000;i++) {
        assert(!treo_rc_may_submit(&stale));
        assert(!treo_rc_may_submit(&missing));
    }
    assert(!pthread_join(t,NULL));
    puts("2D GPU owner gate: 10000 sequential cycles + 100000 concurrent checks PASS");
}
'''


class GPUFocusGateTest(unittest.TestCase):
    def test_owner_predicate(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host C compiler unavailable")
        src = RENDER.read_text()
        a = src.index("static inline int treo_rc_may_submit(")
        b = src.index("\n}", a) + 2
        flags = ["-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-pthread"]
        if os.environ.get("JARBOX_GPU_GATE_SANITIZE") == "1":
            flags += ["-g", "-fsanitize=address,undefined"]
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "focus.c"
            exe = Path(td) / "focus"
            path.write_text(PRELUDE + src[a:b] + MAIN)
            subprocess.run([cc, *flags, str(path), "-o", str(exe)], check=True, timeout=30)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("10000 sequential cycles + 100000 concurrent checks PASS", r.stdout)

    def test_record_submit_and_fallback_order(self):
        src = RENDER.read_text()
        record = src.split("static int treo_live_recording(RenderContext *rc) {", 1)[1].split("\n}", 1)[0]
        render = src.split("static int treo_live_render(RenderContext *rc, TreoLiveRun *run) {", 1)[1].split("\n}", 1)[0]
        drain = src.split("static void treo_live_drain(RenderContext *rc, int allowMetal) {", 1)[1].split("\n}", 1)[0]
        flush = src.split("static s32 n_flushToScreen(", 1)[1].split("\n}", 1)[0]
        self.assertIn("treo_rc_may_submit(rc)", record)
        self.assertLess(render.index("if (!treo_rc_may_submit(rc)) return 0;"), render.index("if (!treo_live_pipeline)"))
        self.assertIn("[enc endEncoding];", render)
        self.assertLess(render.rindex("if (!treo_rc_may_submit(rc)) return 0;"), render.index("[command commit]"))
        self.assertIn("treo_rc_may_submit(rc) && os_unfair_lock_trylock", drain)
        self.assertIn("if (usedMetal)", drain)
        self.assertIn("treo_live_clear(run);", drain)
        self.assertLess(flush.index("treo_live_drain(rc, !afk)"), flush.index("treo_rc_may_submit(rc)"))
        self.assertGreaterEqual(flush.count("!treo_rc_may_submit(rc)"), 2)


if __name__ == "__main__":
    unittest.main()
