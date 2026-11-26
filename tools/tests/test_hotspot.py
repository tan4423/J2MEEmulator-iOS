"""Bounded cooperative profiler policy and production source wiring."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
VM = ROOT / "J2MEEmulator/minijvm/jvm"
NATIVE = ROOT / "J2MEEmulator/NativeBridge"

class HotspotTest(unittest.TestCase):
    def test_host(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            exe = Path(td) / "hotspot"
            subprocess.run([cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-pthread",
                            "-I", str(VM), str(Path(__file__).with_name("hotspot_host.c")), "-o", str(exe)],
                           check=True, timeout=45)
            subprocess.run([str(exe)], check=True, timeout=30)

    def test_wiring(self):
        i = (VM / "interpreter.c").read_text()
        self.assertIn("JARBOX_HOT_CHECK(pruntime,method,NULL);", i)
        self.assertIn("if (offset < 0) JARBOX_HOT_CHECK(runtime,method,runtime->pc);", i)
        self.assertIn("(++t->jarbox_hot_ticks&255u)!=0", i)
        self.assertIn("jarbox_treo_mode_get(&s->treo_state)!=1", i)
        self.assertIn("jarbox_hot_note(&s->treo_state.hotspot", i)
        b = (NATIVE / "jvm_bridge.c").read_text()
        self.assertIn("jarbox_hot_report(&session->treo_state.hotspot", b)
        s = (ROOT / "J2MEEmulator/SceneDelegate.swift").read_text()
        self.assertIn("withUnsafePointer(to: slot)", s)
        self.assertIn(r"hot_rows=\(hot)", s)
        self.assertIn("hotspot-", (ROOT / "codemagic.yaml").read_text())

if __name__ == "__main__":
    unittest.main()
