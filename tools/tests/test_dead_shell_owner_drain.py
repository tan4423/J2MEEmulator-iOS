"""Host test of real dead-shell queue code with modeled graphics shell structs."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RENDER = Path(__file__).resolve().parents[2] / "J2MEEmulator/NativeBridge/j2me_render.m"
PRE = r'''
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdlib.h>
#include <assert.h>
#include <stdio.h>
typedef struct RenderContext { uint64_t heap_key; struct RenderContext *next_dead; } RenderContext;
typedef struct RenderImage { uint64_t heap_key; struct RenderImage *next_dead; } RenderImage;
static pthread_mutex_t g_dead_drain_lock = PTHREAD_MUTEX_INITIALIZER;
#define os_unfair_lock_lock pthread_mutex_lock
#define os_unfair_lock_unlock pthread_mutex_unlock
'''
MAIN = r'''
static void add(uint64_t key) {
    RenderContext *r = calloc(1,sizeof *r); RenderImage *i = calloc(1,sizeof *i);
    assert(r && i); r->heap_key = i->heap_key = key;
    enqueue_dead_rc(r); enqueue_dead_img(i);
}
static void check(RenderContext *r, RenderImage *i, uint64_t key, unsigned count) {
    unsigned a=0,b=0;
    for(;r;r=r->next_dead){assert(r->heap_key==key);assert(++a<=count);}
    for(;i;i=i->next_dead){assert(i->heap_key==key);assert(++b<=count);}
    assert(a==count&&b==count);
}
static void *produce(void *arg) { (void)arg; for(unsigned i=0;i<10000;i++)add(2);return NULL; }
int main(void) {
    for(unsigned n=0;n<10000;n++) {
        add(1);add(2);add(1);add(2);
        g_dead_rc_gen1=atomic_exchange(&g_dead_rc_gen0,NULL);
        g_dead_img_gen1=atomic_exchange(&g_dead_img_gen0,NULL);
        add(2);add(1);add(2);add(1);
        process_dead_shells_for_owner(0);process_dead_shells_for_owner(1);
        check(g_dead_rc_gen1,g_dead_img_gen1,2,2);
        check(atomic_load(&g_dead_rc_gen0),atomic_load(&g_dead_img_gen0),2,2);
        process_dead_shells_for_owner(1);process_dead_shells_for_owner(2);
        check(g_dead_rc_gen1,g_dead_img_gen1,2,0);
        check(atomic_load(&g_dead_rc_gen0),atomic_load(&g_dead_img_gen0),2,0);
    }
    for(unsigned n=0;n<10;n++) {
        add(1);add(2);pthread_t t;assert(!pthread_create(&t,NULL,produce,NULL));
        for(unsigned j=0;j<100;j++)process_dead_shells_for_owner(1);
        assert(!pthread_join(t,NULL));
        check(atomic_load(&g_dead_rc_gen0),atomic_load(&g_dead_img_gen0),2,10001);
        process_dead_shells_for_owner(2);
    }
    puts("PASS: 10000 mixed-generation cycles; 100000 concurrent foreign publications");
}
'''

class DeadShellOwnerDrainTest(unittest.TestCase):
    def test_owner_drain_preserves_foreign_grace_generations(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("C compiler unavailable")
        src = RENDER.read_text()
        a = src.index("static _Atomic(RenderContext *) g_dead_rc_gen0")
        b = src.index("// Canvas paint locks", a)
        c = src.index("static void process_dead_shells_for_owner(")
        d = src.index("\n}", c) + 2
        flags = ["-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror", "-pthread"]
        if os.environ.get("JARBOX_SHELL_SANITIZE") == "1":
            flags += ["-fsanitize=address,undefined"]
        with tempfile.TemporaryDirectory() as td:
            p, exe = Path(td) / "shells.c", Path(td) / "shells"
            p.write_text(PRE + src[a:b] + src[c:d] + MAIN)
            subprocess.run([cc, *flags, str(p), "-o", str(exe)], check=True, timeout=60)
            r = subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=30)
            self.assertIn("100000 concurrent foreign publications", r.stdout)

if __name__ == "__main__":
    unittest.main()
