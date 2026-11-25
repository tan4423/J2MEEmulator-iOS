"""Host test of the real event-driven trace, not an iOS suspend test."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
C=r"""
#include <assert.h>
#include "jarbox_background_trace.h"
#define S UINT64_C(1000000000)
int main(void) {
    JarBoxBackgroundTrace a={0},b={0};
    JarBoxBackgroundProgress p={0};
    assert(!jarbox_background_end(&a,S,&p));
    for(int i=0;i<10000;i++) {
        assert(jarbox_background_begin(&a,S));
        assert(jarbox_background_begin(&b,S));
        jarbox_background_note(&a,2*S);
        jarbox_background_note(&a,2*S+1);
        jarbox_background_note(&a,3*S);
        jarbox_background_note(&a,12*S);
        jarbox_background_note(&a,2*S);
        assert(jarbox_background_end(&a,15*S,&p));
        assert(p.samples==3 && p.first_ns==2*S && p.last_ns==12*S && p.max_gap_ns==9*S);
        jarbox_background_note(&a,16*S);
        assert(!jarbox_background_end(&a,17*S,&p));
        assert(jarbox_background_end(&b,15*S,&p));
        assert(p.samples==0 && p.max_gap_ns==14*S);
        assert(jarbox_background_begin(&a,20*S));
        jarbox_background_note(&a,19*S);
        assert(jarbox_background_end(&a,21*S,&p) && p.samples==0);
    }
    assert(jarbox_background_begin(&a,S));
    assert(jarbox_background_try_lock(&a));
    jarbox_background_note(&a,2*S);
    assert(!jarbox_background_end(&a,3*S,&p));
    jarbox_background_unlock(&a);
    assert(!jarbox_background_enabled(&a));
    return 0;
}
"""
class BackgroundTraceTest(unittest.TestCase):
    def test_trace(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory() as d:
            p,exe=Path(d)/"trace.c",Path(d)/"trace"
            p.write_text(C)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-I",str(JVM),str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_scene_and_owner_wiring(self):
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        self.assertIn("JarBoxBackgroundDiagnostics.begin()",scene)
        self.assertIn("JarBoxBackgroundDiagnostics.end()",scene)
        self.assertIn("jvm_bridge_background_tokens",scene)
        self.assertIn("INCOMPLETE_NO_RESUME_RECORDED",scene)
        bridge=(ROOT/"J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        self.assertIn("jvm_bridge_visit_running_vm_for_token(token,bridge_background_sample_visitor,&call)",bridge)
        render=(ROOT/"J2MEEmulator/NativeBridge/j2me_render.m").read_text()
        self.assertIn("jarbox_background_note(&state->background_trace,",render)
        for name in ("GameViewController.swift","AppsListViewController.swift"):
            self.assertIn("JarBoxBackgroundDiagnostics.show(from: self)",(ROOT/"J2MEEmulator/UI"/name).read_text())
if __name__=="__main__":unittest.main()
