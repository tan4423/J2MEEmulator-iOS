"""Host test of coherent completed LCDUI notices, not UIKit or Java execution."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

NATIVE = Path(__file__).resolve().parents[2] / "J2MEEmulator/NativeBridge"
C = r'''
#include <assert.h>
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include "jarbox_ui_generation.h"
static _Atomic uint64_t notice;
static atomic_int revision;
static void *writer(void *unused) {
    (void)unused;
    for(int i=1;i<=100000;i++) {
        atomic_store_explicit(&revision,i,memory_order_release);
        atomic_store_explicit(&notice,jarbox_ui_notice_pack(i%5+1,i),memory_order_release);
    }
    return NULL;
}
int main(void) {
    for(int i=0;i<10000;i++) {
        uint64_t a=jarbox_ui_notice_pack(1,i),b=jarbox_ui_notice_pack(4,i);
        assert(jarbox_ui_notice_action(a,i)==1);
        assert(jarbox_ui_notice_action(b,i)==4);
        assert(!jarbox_ui_notice_action(a,i+1));
        assert(!jarbox_ui_notice_action(0,i));
        assert(jarbox_ui_notice_action(jarbox_ui_notice_pack(3,-1),-1)==3);
    }
    pthread_t t;assert(!pthread_create(&t,NULL,writer,NULL));
    for(int i=0;i<100000;i++) {
        uint64_t n=atomic_load_explicit(&notice,memory_order_acquire);
        int rev=atomic_load_explicit(&revision,memory_order_acquire);
        int action=jarbox_ui_notice_action(n,rev);
        assert(!action||action==rev%5+1);
    }
    assert(!pthread_join(t,NULL));
    puts("LCDUI notice: 10000 sequential + 100000 concurrent snapshots PASS");
}
'''

class UINoticeTest(unittest.TestCase):
    def test_native_notice_policy(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host C compiler unavailable")
        flags = ["-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-pthread"]
        if os.environ.get("JARBOX_UI_NOTICE_SANITIZE") == "1":
            flags += ["-g", "-fsanitize=address,undefined"]
        with tempfile.TemporaryDirectory() as td:
            p, exe = Path(td) / "notice.c", Path(td) / "notice"
            p.write_text(C)
            subprocess.run([cc, *flags, "-I", str(NATIVE), str(p), "-o", str(exe)],
                           check=True, timeout=30)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("10000 sequential + 100000 concurrent snapshots PASS", r.stdout)

    def test_focus_replays_only_a_committed_notice(self):
        ui = (NATIVE / "j2me_ui.m").read_text()
        self.assertIn("_Atomic uint64_t last_notice;", ui)
        self.assertNotIn("last_action", ui)
        focus = ui.split("int j2me_ui_focus_vm(MiniJVM *vm) {", 1)[1].split("\n}", 1)[0]
        self.assertIn("jarbox_ui_notice_action(notice, revision)", focus)
        self.assertIn("if (action) ui_publish_action(action, revision, ownerKey)", focus)
        self.assertIn("jarbox_ui_notice_pack(action, revision)", ui)
        self.assertIn("jarbox_ui_notice_pack(J2ME_UI_ACTION_SHOW_CANVAS, revision)", ui)
        self.assertEqual(ui.count("atomic_store_explicit(&ctx->last_notice, 0,"), 2)

if __name__ == "__main__":
    unittest.main()
