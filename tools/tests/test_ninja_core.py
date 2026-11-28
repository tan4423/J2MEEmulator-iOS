"""Host policy and integration wiring, not real MiniJVM or iOS gameplay."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
VM=ROOT/"J2MEEmulator/minijvm/jvm"
NATIVE=ROOT/"J2MEEmulator/NativeBridge"
DIGESTS=[
"96f811dc1317ec41ba01953350436dc8f850090c3018a26b4ae35f3124c2e95d",
"11b1d4c11f9082b9d07bc7bd92a9ad3abad40764853e23686cc86686869c966c",
"3420df8cb91bcc33852230d1c6f9166a99d6ce3f2c4a332cf1bad851c3f7b276",
"c48f8e40e8c619a8503626b14940693d3fd37f1ecbba1c1342f53957d42f0080",
"0e1594b98d4c439adcae55cbd35ec05af5339ac9dcbadaa2c24b113e9c775ddb",
"1e79927643228d369c1f590879bdefe2051820080606dd433db7da349028b9f9",
"0000000000000000000000000000000000000000000000000000000000000000"]
class NinjaCoreTest(unittest.TestCase):
    def test_policy(self):
        cc=shutil.which(os.environ.get("CC","cc"))
        if not cc:self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            exe=Path(td)/"test"
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-I",str(VM),str(Path(__file__).with_name("ninja_core_policy_host.c")),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe),*DIGESTS],check=True,timeout=10)
    def test_wiring(self):
        canvas=(ROOT/"j2me_api/src/javax/microedition/lcdui/Canvas.java").read_text()
        api=(ROOT/"j2me_api/src/javax/microedition/lcdui/NativeBridge.java").read_text()
        r=(NATIVE/"j2me_render.m").read_text()
        h=(VM/"jarbox_treo_state.h").read_text()
        i=(VM/"interpreter.c").read_text()
        b=(NATIVE/"jvm_bridge.c").read_text()
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        paint=canvas.split("public void doPaint()",1)[1].split("void refreshAfterAfk",1)[0]
        self.assertIn("policy == 1 && !treoUsesExplicitBuffer && !target.treoPixelDependent",paint)
        self.assertIn("fullRepaint && !(this instanceof javax.microedition.lcdui.game.GameCanvas)",paint)
        self.assertIn("NativeBridge.ninjaCorePaint(this)",paint)
        self.assertIn("NativeBridge.beginAfkPaint(nativeContext, headless || core)",paint)
        self.assertIn("target.headless = headless;",paint)
        self.assertIn("treoSkippedCanvasPixels = discard || core;",paint)
        self.assertEqual(paint.count("paint(target);"),1)
        self.assertIn("if (core) NativeBridge.ninjaCorePaintResult(",paint)
        self.assertIn("static native boolean ninjaCorePaint(Object canvas);",api)
        self.assertIn('"ninjaCorePaint", "(Ljava/lang/Object;)Z", n_ninjaCorePaint',r)
        self.assertIn("jarbox_treo_safe_automatic_park_mode(state, change->compatible_only)",r)
        self.assertIn("change->entering && !change->compatible_only",r)
        self.assertIn("jarbox_ninja_core_active(&s->ninja_core,mode)",h)
        self.assertIn("ninja_core_profile=treo_ninja_core_archive_profile(midlet_jar)",b)
        self.assertIn("CC_SHA256_Final(digest,&ctx)",b)
        self.assertIn("(!core_sink || __atomic_load_n(&method->treo_afk_kind,__ATOMIC_RELAXED)==3)",i)
        self.assertIn("tag = (k == 3 || k >= 11) ? 2 : 3",i)
        self.assertIn("if (ctx != g_afk_canvas) return 0;",r)
        self.assertIn("caller_key != g_afk_canvas_owner_key",r)
        for f in ("nso_core_profile","nso_core_armed","nso_core_rejected","nso_core_frames","nso_core_faults","scoped_native_draw_skips","scoped_vm_draw_skips"):
            self.assertIn("out->"+f+"=",b)
            self.assertIn(f+r"=\(slot."+f+")",scene)
    def test_residual_warmup_never_executes_foreground(self):
        i=(VM/"interpreter.c").read_text().split("static const JarBoxResidualOp *jbr_live_compile(",1)[1].split("\n#endif\n#endif",1)[0]
        self.assertIn("phase==JARBOX_SESSION_FOREGROUND && mode==0 && !in_scope",i)
        self.assertIn("if(in_scope&&!parked)return NULL;",i)
        self.assertIn("if(!in_scope)return NULL;",i)
        self.assertIn("return in_scope?plan:NULL;",i)
        self.assertIn("if(visible_warmup)__atomic_fetch_or(&st->residual_visible_ready",i)
        self.assertIn("treo_residual_scope_capture(r,wrapper,scope)",i)
        r=(NATIVE/"j2me_render.m").read_text()
        sink=r.split("static s32 n_ninjaCorePaint(",1)[1].split("static s32 n_ninjaCorePaintResult(",1)[0]
        self.assertNotIn("residual_plan_ready",sink)
        self.assertIn("treo_core_audited_canvas(state,canvas->mb.clazz)",sink)
        self.assertIn("state->residual_faults",sink)
        self.assertIn("ca->code_length==20&&ca->exception_table_length==1",r)
        b=(NATIVE/"jvm_bridge.c").read_text()
        self.assertIn("residual_archive_verified,ninja_core_profile==2",b)
        self.assertIn("ninja_core_profile&&!treo_residual_api_identity(res_root)",b)
        self.assertNotIn("ninja_core_profile!=2||",b)
if __name__=="__main__":unittest.main()
