"""Compile extracted input retirement functions with modeled slots and consumers."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

NATIVE = Path(__file__).resolve().parents[2] / "J2MEEmulator/NativeBridge"
PRE = r'''
#include <assert.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
typedef struct MiniJVM { int id; } MiniJVM;
typedef struct { atomic_uint read_pos,write_pos; } JarBoxInputRing;
static void jarbox_input_ring_reset(JarBoxInputRing *ring) { atomic_store(&ring->write_pos,0); atomic_store(&ring->read_pos,0); }
typedef struct { _Atomic(MiniJVM *) vm; uint64_t heap_key,session_token; atomic_int accepting_input,display_wait_enabled,angel_sleep_requested; JarBoxInputRing ring; unsigned wakes; } J2MEInputContext;
#define JARBOX_INPUT_CONTEXT_CAPACITY 4
static J2MEInputContext g_input_contexts[JARBOX_INPUT_CONTEXT_CAPACITY];
static pthread_mutex_t g_input_context_lock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic(J2MEInputContext *) g_visible_input_context;
static J2MEInputContext *visible_input_context(void) { return atomic_load(&g_visible_input_context); }
static J2MEInputContext *context_for_vm(MiniJVM *vm) { if(!vm)return NULL;for(int i=0;i<JARBOX_INPUT_CONTEXT_CAPACITY;i++) if(atomic_load(&g_input_contexts[i].vm)==vm)return &g_input_contexts[i];return NULL; }
static void signal_display_wait(J2MEInputContext *ctx) { ctx->wakes++; }
'''
MAIN = r'''
static void bind_model(J2MEInputContext *ctx, MiniJVM *vm, uint64_t token) {
    atomic_store(&ctx->vm,vm);ctx->heap_key=token+100;ctx->session_token=token;
    atomic_store(&ctx->accepting_input,1);atomic_store(&ctx->display_wait_enabled,1);atomic_store(&ctx->angel_sleep_requested,1);
    atomic_store(&ctx->ring.read_pos,3);atomic_store(&ctx->ring.write_pos,7);ctx->wakes=0;
}
static void *consume(void *p) {
    J2MEInputContext *ctx=p;
    while(atomic_load_explicit(&ctx->accepting_input,memory_order_acquire)) {
        atomic_fetch_add(&ctx->ring.read_pos,1);
    }
    return NULL;
}
int main(void) {
    MiniJVM a={1},b={2};J2MEInputContext *x=&g_input_contexts[0],*y=&g_input_contexts[1];
    for(int i=0;i<10000;i++) {
        bind_model(x,&a,11);bind_model(y,&b,22);atomic_store(&g_visible_input_context,y);
        j2me_input_quiesce_vm(&a);
        assert(!atomic_load(&x->accepting_input)&&!atomic_load(&x->display_wait_enabled)&&!atomic_load(&x->angel_sleep_requested));
        assert(atomic_load(&x->vm)==&a&&x->session_token==11&&x->heap_key==111);
        assert(atomic_load(&x->ring.read_pos)==3&&atomic_load(&x->ring.write_pos)==7);
        assert(visible_input_context()==y&&atomic_load(&y->accepting_input)&&atomic_load(&y->angel_sleep_requested)&&y->wakes==0);
        j2me_input_release_for_token(0);j2me_input_release_for_token(99);
        assert(x->session_token==11&&y->session_token==22);
        j2me_input_release_for_token(11);
        assert(!atomic_load(&x->vm)&&!x->session_token&&!x->heap_key);
        assert(!atomic_load(&x->ring.read_pos)&&!atomic_load(&x->ring.write_pos));
        bind_model(x,&a,33);atomic_store(&g_visible_input_context,x);
        j2me_input_release_for_token(11);
        assert(x->session_token==33&&atomic_load(&x->accepting_input));
        j2me_input_quiesce_vm(&a);assert(!visible_input_context());
        j2me_input_release_for_token(33);j2me_input_release_for_token(22);
    }
    for(int i=0;i<100;i++) {
        bind_model(x,&a,11);atomic_store(&g_visible_input_context,x);
        pthread_t t;assert(!pthread_create(&t,NULL,consume,x));
        j2me_input_quiesce_vm(&a);assert(!pthread_join(t,NULL));
        assert(atomic_load(&x->ring.read_pos)>=3&&atomic_load(&x->ring.write_pos)==7);
        j2me_input_release_for_token(11);assert(!atomic_load(&x->ring.read_pos));
    }
    puts("input teardown: 10000 cycles + 100 consumer drains PASS");
}
'''
class InputTeardownTest(unittest.TestCase):
    def test_input_quiesce_preserves_ring_until_retirement(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("C compiler unavailable")
        source = (NATIVE / "j2me_input.c").read_text()
        a = source.index("static void input_quiesce_locked(")
        b = source.index("// Startup rollback only,", a)
        flags = ["-std=c11", "-pthread", "-O1", "-Wall", "-Wextra", "-Werror"]
        if os.environ.get("JARBOX_INPUT_SANITIZE") == "1":
            flags += ["-g", "-fsanitize=address,undefined"]
        with tempfile.TemporaryDirectory() as td:
            p, exe = Path(td) / "input.c", Path(td) / "input"
            p.write_text(PRE + source[a:b] + MAIN)
            subprocess.run([cc, *flags, str(p), "-o", str(exe)], check=True, timeout=30)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)
            self.assertEqual(r.returncode, 0, r.stdout+r.stderr)
            self.assertIn("10000 cycles + 100 consumer drains PASS", r.stdout)
    def test_bridge_retires_only_after_worker_drain(self):
        bridge = (NATIVE / "jvm_bridge.c").read_text()
        body = bridge.split("static void bridge_destroy_slot(JarBoxVMContext *slot) {", 1)[1].split("\nint jvm_bridge_request_stop_for_token", 1)[0]
        self.assertLess(body.index("j2me_input_quiesce_vm(slot->jvm)"), body.index("jvm_destroy(slot->jvm)"))
        self.assertLess(body.index("jvm_destroy(slot->jvm)"), body.index("j2me_input_release_for_token(destroyed_token)"))
        self.assertNotIn("j2me_input_release_vm(slot->jvm)", body)
        source = (NATIVE / "j2me_input.c").read_text()
        self.assertIn("ctx->session_token != token || ctx->heap_key != heap_key", source)
        quiesce = source.split("static void input_quiesce_locked(", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("jarbox_input_ring_reset", quiesce)
        self.assertIn("accepting_input", quiesce)
        self.assertIn("signal_display_wait(ctx)", quiesce)

if __name__ == "__main__":
    unittest.main()
