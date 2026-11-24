"""Test extracted native owner-bound MIDP input admission, with modeled queues."""
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
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
typedef struct { uint64_t heap_key; int received; } J2MEInputContext;
static pthread_mutex_t g_input_context_lock=PTHREAD_MUTEX_INITIALIZER;
static J2MEInputContext a={11,0},b={22,0};
static J2MEInputContext *visible;
static J2MEInputContext *visible_input_context(void){return visible;}
static void enqueue_to_context(J2MEInputContext *ctx,int type,int x,int y,int keyCode){
    assert(ctx->heap_key==(uint64_t)x);
    assert(type==10&&y==7&&keyCode==0);
    ctx->received++;
}
'''
MAIN = r'''
static void *switcher(void *unused){
    (void)unused;
    for(int i=0;i<100000;i++){
        pthread_mutex_lock(&g_input_context_lock);
        visible=i%3==0?NULL:i%3==1?&a:&b;
        pthread_mutex_unlock(&g_input_context_lock);
    }
    return NULL;
}
int main(void){
    for(int i=0;i<10000;i++){
        a.heap_key=11;a.received=b.received=0;visible=&a;
        j2me_input_post_touch_for_owner(11,10,11,7);
        j2me_input_post_touch_for_owner(22,10,22,7);
        assert(a.received==1&&b.received==0);
        visible=&b;
        j2me_input_post_touch_for_owner(11,10,11,7);
        j2me_input_post_touch_for_owner(22,10,22,7);
        assert(a.received==1&&b.received==1);
        visible=NULL;
        j2me_input_post_touch_for_owner(22,10,22,7);
        assert(b.received==1);
        a.heap_key=33;visible=&a;
        j2me_input_post_touch_for_owner(11,10,11,7);
        j2me_input_post_touch_for_owner(0,10,0,7);
        assert(a.received==1);
        j2me_input_post_touch_for_owner(33,10,33,7);
        assert(a.received==2);
    }
    pthread_t t;assert(!pthread_create(&t,NULL,switcher,NULL));
    for(int i=0;i<100000;i++){
        j2me_input_post_touch_for_owner(33,10,33,7);
        j2me_input_post_touch_for_owner(22,10,22,7);
        j2me_input_post_touch_for_owner(11,10,11,7);
    }
    assert(!pthread_join(t,NULL));
    puts("MIDP input owner gate: 10000 cycles + 300000 concurrent submissions PASS");
}
'''


class MIDPOwnedInputTest(unittest.TestCase):
    def test_owner_admission_under_focus_switch_and_slot_reuse(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host C compiler unavailable")
        src = (ROOT / "NativeBridge/j2me_input.c").read_text()
        a = src.index("void j2me_input_post_touch_for_owner(")
        b = src.index("\n}", a) + 2
        flags = ["-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-pthread"]
        if os.environ.get("JARBOX_MIDP_SANITIZE") == "1":
            flags += ["-g", "-fsanitize=address,undefined"]
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "owner.c"
            exe = Path(td) / "owner"
            p.write_text(PRELUDE + src[a:b] + MAIN)
            subprocess.run([cc, *flags, str(p), "-o", str(exe)], check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("10000 cycles + 300000 concurrent submissions PASS", result.stdout)

    def test_form_list_alert_use_origin_generation(self):
        input_c = (ROOT / "NativeBridge/j2me_input.c").read_text()
        self.assertIn("ctx->heap_key = heap_key;", input_c)
        self.assertIn("ctx->heap_key = 0;", input_c)
        ui = (ROOT / "NativeBridge/j2me_ui.m").read_text()
        stage = ui.split("void j2me_ui_stage_text_for_owner(", 1)[1].split("\n}", 1)[0]
        self.assertIn("jarbox_ui_may_present(owner_key, ui_focused_owner_key()", stage)
        self.assertIn("&ctx->screen_revision", stage)
        self.assertIn("objects->pendingText", stage)
        self.assertNotIn("g_pending_text", stage)
        form = (ROOT / "UI/FormView.swift").read_text()
        self.assertEqual(form.count("screenOwnerKey = ownerKey"), 2)
        self.assertEqual(form.count("let commandOwner = screenOwnerKey"), 2)
        self.assertNotIn("j2me_input_post_touch(", form)
        self.assertNotIn("j2me_ui_stage_text(", form)
        game = (ROOT / "UI/GameViewController.swift").read_text()
        self.assertIn("vc.showFormView(ownerKey: ownerKey)", game)
        self.assertIn("vc.showListView(ownerKey: ownerKey)", game)
        self.assertEqual(game.count("j2me_input_post_touch_for_owner(originKey,"), 3)


if __name__ == "__main__":
    unittest.main()
