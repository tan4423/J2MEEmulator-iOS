"""Host policy/framing and source wiring; no device CPU claim."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
VM=ROOT/"J2MEEmulator/minijvm/jvm"
NATIVE=ROOT/"J2MEEmulator/NativeBridge"
class NativePaintDiagTest(unittest.TestCase):
    def test_policy_gzip(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            exe=Path(td)/"test"
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-I",str(VM),"-I",str(NATIVE),str(Path(__file__).with_name("native_paint_diag_host.c")),"-lz","-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=30)
    def test_source_wiring(self):
        i=(VM/"interpreter.c").read_text()
        r=(NATIVE/"j2me_render.m").read_text()
        b=(NATIVE/"jvm_bridge.c").read_text()
        s=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        self.assertIn("jarbox_treo_mode_get(&s->treo_state)!=1",i)
        self.assertIn("d->owner!=r->jvm->session",i)
        self.assertIn("d->invalid || d->in_native",i)
        self.assertIn("jarbox_native_paint_valid(total,d->ns[0],d->ns[1],d->ns[2])",i)
        self.assertIn("const int native_paint_token=treo_native_paint_enter(runtime,method);",i)
        self.assertIn("treo_native_paint_exit(native_paint_token);",i)
        self.assertIn("if (start<0) treo_native_paint_diag_begin(runtime);",r)
        self.assertIn("treo_native_paint_diag_end(runtime,end>=begin ? end-begin : 0,end>=begin);",r)
        self.assertIn("tdefl_create_comp_flags_from_zip_params(6,-15,MZ_DEFAULT_STRATEGY)",b)
        self.assertIn("mz_free(raw)",b)
        for f in ("native_diag_seen","native_diag_selected_frames","native_diag_selected_cpu_ns","native_diag_plain_frames","native_diag_plain_cpu_ns","native_diag_discarded_frames","native_diag_draw_calls","native_diag_draw_ns","native_diag_lcd_other_calls","native_diag_lcd_other_ns","native_diag_other_calls","native_diag_other_ns","native_diag_drawrgb_calls","native_diag_drawrgb_pixels","native_diag_getrgb_calls","native_diag_getrgb_pixels"):
            self.assertIn("out->"+f+"=__atomic_load_n(&session->treo_state."+f+",__ATOMIC_RELAXED);",b)
            self.assertIn(f+r"=\(slot."+f+")",s)
if __name__=="__main__":unittest.main()
