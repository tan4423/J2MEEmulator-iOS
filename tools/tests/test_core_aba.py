"""Host schedule policy and source wiring; not an iOS runtime benchmark."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
VM=ROOT/"J2MEEmulator/minijvm/jvm"
NATIVE=ROOT/"J2MEEmulator/NativeBridge"


class CoreABATest(unittest.TestCase):
    def test_host(self):
        cc=shutil.which("cc")
        if not cc:
            self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            exe=Path(td)/"aba"
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-I",str(VM),
                            str(Path(__file__).with_name("core_aba_host.c")),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)

    def test_wiring(self):
        r=(NATIVE/"j2me_render.m").read_text()
        gate=r.split("static s32 n_ninjaCorePaint(",1)[1].split("\n}",1)[0]
        self.assertIn("jarbox_ninja_core_active",gate)
        self.assertIn("treo_core_audited_canvas",gate)
        audit=r.split("static int treo_core_audited_canvas(",1)[1].split("\n}",1)[0]
        self.assertIn("treo_nso_simple_canvas_paint(cl)",audit)
        self.assertIn("jarbox_ninja_core_canvas(profile)",audit)
        self.assertIn("enabled=jarbox_core_aba_sink(phase)",gate)
        park=r.split("static void treo_park_transition_visitor(",1)[1].split("\n}",1)[0]
        self.assertIn("!state->core_aba_used",park)
        self.assertLess(park.index("treo_apply_mode_locked"),park.index("state->core_aba_used=1"))
        state=(VM/"jarbox_treo_state.h").read_text()
        self.assertIn("__atomic_store_n(&s->core_aba_start_ns,0,__ATOMIC_RELEASE);",state)
        b=(NATIVE/"jvm_bridge.c").read_text()
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        for k in ("core_aba_start_ns","core_aba_elapsed_ns","core_aba_phase"):
            self.assertIn("out->"+k+"=",b)
            self.assertIn(k+r"=\(slot."+k+")",scene)
        self.assertIn("if decision.save || abaSave",scene)
        config=(ROOT/"codemagic.yaml").read_text()
        # Measured E3 regression: diagnostic remains selectable, but both
        # automatic scoped-sink admission switches default OFF.
        self.assertIn('JARBOX_CORE_ABA: "0"',config)
        self.assertIn('JARBOX_NINJA_CORE_EXPERIMENT: "0"',config)
        self.assertIn("-DTREO_CORE_ABA=1",config)


if __name__=="__main__":
    unittest.main()
