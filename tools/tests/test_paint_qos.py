"""Compile the production budget guard; source-check scope and ownership.
Actual iOS scheduling, CoreText and pixel behavior require device tests.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
NATIVE=ROOT/"J2MEEmulator/NativeBridge"
class PaintQoSTest(unittest.TestCase):
    def test_budget(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)
            (p/"q.c").write_text('#include <assert.h>\n#include "jarbox_paint_qos_policy.h"\nint main(void){assert(!jarbox_paint_qos_over_budget(40000000));assert(jarbox_paint_qos_over_budget(40000001));for(unsigned i=0;i<100000;i++)assert(jarbox_paint_qos_backoff(i)==(i>=3));return 0;}\n')
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-I",str(NATIVE),str(p/"q.c"),"-o",str(p/"q")],check=True,timeout=30)
            subprocess.run([str(p/"q")],check=True,timeout=10)
    def test_wiring(self):
        m=(NATIVE/"j2me_render.m").read_text()
        begin=m.split("static void treo_paint_qos_begin(",1)[1].split("\n}",1)[0]
        end=m.split("static void treo_paint_qos_end(",1)[1].split("\n}",1)[0]
        restore=m.split("static int treo_qos_restore(",1)[1].split("\n}",1)[0]
        self.assertIn("!jvm_bridge_cpu_is_java_worker(runtime->jvm->session) || pthread_main_np()",begin)
        self.assertIn("stamp>=0 || treo_runtime_mode(runtime)!=1",begin)
        self.assertIn("before!=QOS_CLASS_DEFAULT && before!=QOS_CLASS_USER_INITIATED",begin)
        self.assertIn("pthread_set_qos_class_self_np(QOS_CLASS_UTILITY,0)",begin)
        self.assertIn("actual!=QOS_CLASS_UTILITY || rel!=0",begin)
        self.assertIn("pthread_set_qos_class_self_np(q->original,q->relative)",restore)
        self.assertIn("actual!=q->original || relative!=q->relative",restore)
        self.assertIn("if (--q->depth) return;",end)
        self.assertIn("jarbox_paint_qos_backoff(strikes)",end)
        self.assertIn("(void)treo_qos_restore(s);",end)
        self.assertIn("treo_paint_qos_begin(runtime,start)",m)
        self.assertIn("treo_paint_qos_end(runtime,end>=begin ? end-begin : 0,end>=begin)",m)
        draw=m.split("static s32 n_drawString(",1)[1].split("\n}",1)[0]
        self.assertIn("rc->textAttrsFont==rc->font",draw)
        self.assertIn("CTLineCreateWithAttributedString(attrStr)",draw)
        self.assertIn("CTLineDraw(line, rc->ctx)",draw)
        self.assertIn("CFRelease(rc->textAttrsFont)",m.split("static void treo_live_discard(RenderContext *rc) {",1)[1].split("\n}",1)[0])
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        self.assertIn("qos_core_residency=unknown",scene)
if __name__=="__main__":unittest.main()
