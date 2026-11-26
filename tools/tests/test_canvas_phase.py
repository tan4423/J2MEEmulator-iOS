"""Host scope policy and source wiring; no device CPU claims."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
VM=ROOT/"J2MEEmulator/minijvm/jvm"
NATIVE=ROOT/"J2MEEmulator/NativeBridge"

class CanvasPhaseTest(unittest.TestCase):
    def test_host(self):
        cc=shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            exe=Path(td)/"canvas_phase"
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-I",str(VM),
                            str(Path(__file__).with_name("canvas_phase_host.c")),"-o",str(exe)],
                           check=True,timeout=45)
            subprocess.run([str(exe)],check=True,timeout=30)
    def test_wiring(self):
        r=(NATIVE/"j2me_render.m").read_text()
        begin=r.split("static s32 n_beginAfkPaint(Runtime *runtime, JClass *clazz) {",1)[1].split("\n}",1)[0]
        end=r.split("static s32 n_endAfkPaint(Runtime *runtime, JClass *clazz) {",1)[1].split("\n}",1)[0]
        pb=r.split("static s32 n_profilePaintBegin(Runtime *runtime, JClass *clazz) {",1)[1].split("\n}",1)[0]
        pe=r.split("static s32 n_profilePaintEnd(Runtime *runtime, JClass *clazz) {",1)[1].split("\n}",1)[0]
        self.assertIn("jarbox_canvas_phase_begin",begin)
        self.assertIn("jarbox_canvas_phase_end",end)
        self.assertIn("treo_runtime_mode(runtime)==1",begin)
        self.assertIn("treo_runtime_mode(runtime)==1",end)
        self.assertIn("1,(uint64_t)(-start)",pb)
        self.assertIn("2,end",pe)
        self.assertIn("treo_canvas_phase_owner(runtime)",pb)
        self.assertIn("treo_canvas_phase_owner(runtime)",pe)
        b=(NATIVE/"jvm_bridge.c").read_text()
        s=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        for suffix in ("ok","frames","pre_ns","paint_ns","post_ns","invalid","busy"):
            f="canvas_phase_"+suffix
            self.assertIn("out->"+f+"=",b)
            self.assertIn(f+r"=\(slot."+f+")",s)
        self.assertIn("canvas-phase-", (ROOT/"codemagic.yaml").read_text())

if __name__=="__main__":unittest.main()
