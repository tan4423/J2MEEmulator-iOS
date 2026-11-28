"""Extract the native Canvas token gate; model queues, not UIKit or the full VM."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "J2MEEmulator"
PRELUDE = r'''
#include <assert.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
typedef struct { uint64_t session_token; unsigned count; atomic_int accepting_input, angel_sleep_requested; unsigned wakes; } J2MEInputContext;
#define JARBOX_INPUT_CONTEXT_CAPACITY 2
static J2MEInputContext g_input_contexts[JARBOX_INPUT_CONTEXT_CAPACITY];
static pthread_mutex_t g_input_context_lock=PTHREAD_MUTEX_INITIALIZER;
#define a (g_input_contexts[0])
#define b (g_input_contexts[1])
static void signal_display_wait(J2MEInputContext *ctx) { ctx->wakes++; }
static J2MEInputContext *visible;
static J2MEInputContext *visible_input_context(void){return visible;}
static void enqueue_to_context(J2MEInputContext *ctx,int type,int x,int y,int keyCode){
    assert(type==3 || type==0);
    assert(ctx->session_token==(uint64_t)(type==3?keyCode:x));
    assert(y==0);ctx->count++;
}
'''
MAIN = r'''
static void *switcher(void *unused) {
    (void)unused;
    for(int i=0;i<100000;i++) {
        pthread_mutex_lock(&g_input_context_lock);
        visible=i%3==0?NULL:i%3==1?&a:&b;
        pthread_mutex_unlock(&g_input_context_lock);
    }
    return NULL;
}
int main(void) {
    a.session_token=11;b.session_token=22;
    atomic_store(&a.accepting_input,1);atomic_store(&b.accepting_input,1);
    visible=&a;
    assert(!j2me_angel_sleep_set_for_token(0,1));
    assert(!j2me_angel_sleep_set_for_token(22,1));
    assert(j2me_angel_sleep_set_for_token(11,1));
    assert(atomic_load(&a.angel_sleep_requested)==1 && a.wakes==1 && a.count==0);
    assert(!atomic_load(&b.angel_sleep_requested) && !b.wakes);
    visible=&b;
    assert(j2me_angel_sleep_set_for_token(11,0));
    assert(!atomic_load(&a.angel_sleep_requested) && a.wakes==2);
    assert(j2me_angel_sleep_set_for_token(22,1));
    atomic_store(&b.accepting_input,0);
    assert(!j2me_angel_sleep_set_for_token(22,0));
    assert(atomic_load(&b.angel_sleep_requested)==1 && b.wakes==1);
    atomic_store(&b.accepting_input,1);assert(j2me_angel_sleep_set_for_token(22,0));
    b.session_token=44;assert(!j2me_angel_sleep_set_for_token(22,1));b.session_token=22;
    for(int i=0;i<10000;i++) {
        a.session_token=11;a.count=b.count=0;visible=&a;
        j2me_input_post_key_for_token(11,3,11);
        j2me_input_post_key_for_token(22,3,22);
        assert(a.count==1&&b.count==0);
        visible=&b;
        j2me_input_post_touch_for_token(11,0,11,0);
        j2me_input_post_touch_for_token(22,0,22,0);
        assert(a.count==1&&b.count==1);
        visible=NULL;
        j2me_input_post_key_for_token(22,3,22);
        assert(b.count==1);
        a.session_token=33;visible=&a;
        j2me_input_post_key_for_token(11,3,11);
        j2me_input_post_key_for_token(0,3,0);
        assert(a.count==1);
        j2me_input_post_touch_for_token(33,0,33,0);
        assert(a.count==2);
    }
    pthread_t t;assert(!pthread_create(&t,NULL,switcher,NULL));
    for(int i=0;i<100000;i++) {
        j2me_input_post_key_for_token(33,3,33);
        j2me_input_post_touch_for_token(22,0,22,0);
        j2me_input_post_key_for_token(11,3,11);
    }
    assert(!pthread_join(t,NULL));
    puts("token input: 10000 cycles + 300000 concurrent submissions PASS");
}
'''


class CanvasInputTokenTest(unittest.TestCase):
    def test_native_token_gate(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host C compiler unavailable")
        src = (ROOT / "NativeBridge/j2me_input.c").read_text()
        a = src.index("static void enqueue_event_for_token(")
        z = src.index("\n}", src.index("void j2me_input_post_touch_for_token(", a)) + 2
        flags = ["-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-pthread"]
        if os.environ.get("JARBOX_CANVAS_INPUT_SANITIZE") == "1":
            flags += ["-g", "-fsanitize=address,undefined"]
        with tempfile.TemporaryDirectory() as td:
            p, exe = Path(td) / "gate.c", Path(td) / "gate"
            p.write_text(PRELUDE + src[a:z] + MAIN)
            subprocess.run([cc, *flags, str(p), "-o", str(exe)], check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("10000 cycles + 300000 concurrent submissions PASS", result.stdout)

    def test_control_ownership_and_parking_cleanup(self):
        input_c = (ROOT / "NativeBridge/j2me_input.c").read_text()
        self.assertIn("ctx->session_token = token;", input_c)
        self.assertIn("ctx->session_token = 0;", input_c)
        game = (ROOT / "UI/GameViewController.swift").read_text()
        back = game.split("@objc private func openLibraryKeepingGame() {", 1)[1].split("func resumeParkedGame()", 1)[0]
        self.assertLess(back.index("cancelGameInput()"), back.index("startParkedTreo()"))
        for name in ("EmulatorView", "NumpadView", "JoystickView"):
            src = (ROOT / "UI" / (name + ".swift")).read_text()
            self.assertIn("var inputSessionToken: UInt64 = 0", src)
            self.assertIn("func cancelGameInput()", src)
            self.assertNotIn("j2me_input_post_key(", src)
            self.assertNotIn("j2me_input_post_touch(", src)
            if name != "EmulatorView":
                self.assertIn("self.repeatTimer === timer", src)
                self.assertIn("timer.invalidate()", src)
        self.assertNotIn("j2me_input_post_key(", game)


if __name__ == "__main__":
    unittest.main()
