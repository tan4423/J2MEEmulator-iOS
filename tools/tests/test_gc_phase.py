"""GC phase accumulator and source wiring; not an actual collector benchmark."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
VM=ROOT/"J2MEEmulator/minijvm/jvm"
NATIVE=ROOT/"J2MEEmulator/NativeBridge"

class GCPhaseTest(unittest.TestCase):
    def test_host(self):
        cc=shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            exe=Path(td)/"gc_phase"
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-pthread",
                            "-I",str(VM),str(Path(__file__).with_name("gc_phase_host.c")),"-o",str(exe)],
                           check=True,timeout=45)
            subprocess.run([str(exe)],check=True,timeout=30)

    def test_wiring(self):
        g=(VM/"garbage.c").read_text()
        worker=g.split("s32 _gc_thread_run(void *para) {",1)[1].split("\n}",1)[0]
        self.assertLess(worker.index("jarbox_gc_phase_current=&phaseCycle"),worker.index("s64 gcResult = _garbage_collect"))
        self.assertLess(worker.index("s64 gcResult = _garbage_collect"),worker.index("jarbox_gc_phase_current=NULL"))
        self.assertLess(worker.index("jarbox_gc_phase_current=NULL"),worker.index("jarbox_gc_phase_publish"))
        collect=g.split("s64 _garbage_collect(GcCollector *collector) {",1)[1].split("\n}",1)[0]
        order=["JARBOX_GC_BOUNDARY(0)","vm_share_lock(jvm)","JARBOX_GC_BOUNDARY(1)",
               "_gc_copy_objs(jvm)","JARBOX_GC_BOUNDARY(2)","_gc_big_search(collector)",
               "JARBOX_GC_BOUNDARY(3)","JARBOX_GC_BOUNDARY(4)","gc_process_deferred_objects(collector)",
               "JARBOX_GC_BOUNDARY(5)","JARBOX_GC_BOUNDARY(6)","return del"]
        self.assertEqual(sorted(collect.index(x) for x in order),[collect.index(x) for x in order])
        self.assertNotIn("jarbox_gc_phase_publish",collect)
        bridge=(NATIVE/"jvm_bridge.c").read_text()
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        for suffix in ("ok","cycles","busy","invalid","aborted","scanned","reclaimed","freed_bytes",
                       *(p+"_"+k+"_ns" for p in ("pause","roots","mark","resume","deferred","sweep") for k in ("cpu","wall"))):
            f="gc_phase_"+suffix
            self.assertIn("out->"+f+"=",bridge)
            self.assertIn(f+r"=\(slot."+f+")",scene)
        self.assertIn("gc-phase-", (ROOT/"codemagic.yaml").read_text())

if __name__=="__main__": unittest.main()
