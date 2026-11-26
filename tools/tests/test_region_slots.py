"""Native argument layout and snapshot lifetime contract."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
NATIVE=ROOT/"J2MEEmulator/NativeBridge"

class RegionSlotsTest(unittest.TestCase):
    def test_slots(self):
        cc=shutil.which("cc")
        if not cc: self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            exe=Path(tmp)/"slots"
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror",
                            "-I",str(NATIVE),str(Path(__file__).with_name("region_slots_host.c")),
                            "-o",str(exe)],check=True,timeout=45)
            subprocess.run([str(exe)],check=True,timeout=20)

    def test_wiring(self):
        r=(NATIVE/"j2me_render.m").read_text()
        f=r.split("static s32 n_profiledDrawRegion(Runtime *runtime, JClass *clazz) {",1)[1].split("\n}",1)[0]
        self.assertIn("jarbox_region_args(runtime->localvar,",f)
        self.assertIn("jarbox_native_heap_key_for_runtime(runtime)",f)
        self.assertIn("return treo_profiled_region(&p, 0);",f)
        self.assertNotIn("env->",f)
        region=r.split("static s32 treo_draw_region(",1)[1].split("\n}",1)[0]
        order=["img_acquire(imgHandle, p->owner_key)", "const int compatible",
               "compatible ? img->immutableSnapshot : copyImageSnapshot(img)",
               "treo_compatible_crop(rc,fullImage", "treo_replay_capture(rc, fullImage",
               "if (!compatible) CGImageRelease(fullImage);",
               "treo_draw_region_cg(rctx, subImage", "CGImageRelease(subImage);"]
        self.assertEqual([region.index(k) for k in order],sorted(region.index(k) for k in order))
        self.assertIn("img_release(img);\n    rc_release(rc);",region)
        rt=(ROOT/"J2MEEmulator/minijvm/jvm/runtime.c").read_text()
        self.assertIn("return localvar_getLong(localvar, index);",rt)
        self.assertIn("return localvar_getInt(localvar, index);",rt)

if __name__=="__main__":unittest.main()
