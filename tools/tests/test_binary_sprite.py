"""Exact binary blit helper; Apple oracle compares entire destination buffers."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
NATIVE=ROOT/"J2MEEmulator/NativeBridge"


class BinarySpriteTest(unittest.TestCase):
    def run_fixture(self,name,extra):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            exe=Path(tmp)/"binary"
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-I",str(NATIVE),
                            str(Path(__file__).with_name(name)),*extra,"-o",str(exe)],check=True,timeout=45)
            subprocess.run([str(exe)],check=True,timeout=30)

    def test_host(self):
        self.run_fixture("binary_sprite_host.c",[])

    @unittest.skipUnless(platform.system()=="Darwin","CoreGraphics oracle requires Apple runner")
    def test_coregraphics(self):
        self.run_fixture("binary_sprite_cg.c",["-framework","CoreGraphics"])

    def test_wiring(self):
        r=(NATIVE/"j2me_render.m").read_text()
        draw=r.split("static s32 treo_draw_region(const TreoRegionArgs *p, int direct) {",1)[1].split("\n}",1)[0]
        self.assertLess(draw.index("treo_live_barrier(rc);"),draw.index("treo_binary_mode1_draw"))
        self.assertIn("if (compatible && transform==TRANS_NONE",draw)
        self.assertIn("afkMode==1 && rc->ownsPixels && rc->clipSaved",draw)
        candidate=r.split("static int treo_binary_mode1_draw(",1)[1].split("\n}",1)[0]
        self.assertIn("img->isMutable",candidate)
        self.assertIn("jarbox_binary_kind",candidate)
        self.assertIn("rc->binaryRejected=true",candidate)
        self.assertIn("jarbox_binary_blit(expected,",candidate)
        self.assertIn("treo_draw_region_cg(rc->ctx,crop",candidate)
        self.assertIn("jarbox_binary_blit(dst,",candidate)
        self.assertIn('JARBOX_BINARY_SPRITE_EXPERIMENT: "0"',(ROOT/"codemagic.yaml").read_text())
        for k in ("fast","checks","mismatch"):
            self.assertIn("out->binary_sprite_"+k,(NATIVE/"jvm_bridge.c").read_text())
            self.assertIn(r"binary_sprite_"+k+r"=\(slot.binary_sprite_"+k+")",(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text())

if __name__=="__main__":unittest.main()
