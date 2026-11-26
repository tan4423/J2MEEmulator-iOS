"""Host candidate cache and timing policy tests, plus production wiring."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
NATIVE=ROOT/"J2MEEmulator/NativeBridge"

class RegionCandidateTest(unittest.TestCase):
    def test_host(self):
        cc=shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as tmp:
            for fixture in ("crop_v2_host.c","region_stage_host.c"):
                exe=Path(tmp)/"test"
                subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-I",str(NATIVE),str(Path(__file__).with_name(fixture)),"-o",str(exe)],check=True,timeout=45)
                subprocess.run([str(exe)],check=True,timeout=30)

    def test_wiring(self):
        render=(NATIVE/"j2me_render.m").read_text()
        region=render.split("static s32 treo_draw_region(",1)[1].split("\n}",1)[0]
        self.assertLess(region.index("++rc->compatible_region_culls"),region.index("stageSelected=jarbox_region_stage_selected"))
        self.assertLess(region.index("stageStart=treo_thread_cpu_ns"),region.index("copyImageSnapshot(img)"))
        self.assertLess(region.index("stageMiddle=stageSelected"),region.index("treo_draw_region_cg(rctx"))
        self.assertLess(region.index("treo_draw_region_cg(rctx"),region.index("jarbox_region_stage_record"))
        bridge=(NATIVE/"jvm_bridge.c").read_text()
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        for suffix in ("seen","samples","hit_samples","hit_ns","miss_ns","draw_ns","invalid"):
            f="region_stage_"+suffix
            self.assertIn("&state->"+f,render)
            self.assertIn("out->"+f+"=__atomic_load_n(&session->treo_state."+f,bridge)
            self.assertIn(f+r"=\(slot."+f+")",scene)
        self.assertIn('#include "jarbox_crop_cache_v2.h"',(NATIVE/"jarbox_crop_cache.h").read_text())

if __name__=="__main__":unittest.main()
