"""Owner-local raster trial schedule and strict device log admission."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/"tools"))
from jarbox_aba import analyze
from test_jarbox_aba import fixture
PROFILE=('const-arith-0_const-branch-0_decoded-int-0_event-sleep-0_paint-qos-0_'
         'ninja-core-0_native-paint-diag-0_crop-v2-1_region-stage-0_hotspot-0_core-aba-0_'
         'gc-phase-1_canvas-phase-1_array-mode1-0_char-leaf-0_binary-sprite-2')
def log():
    rows=[];fast=checks=0
    for r in fixture():
        if 'core_aba_phase=3,' in r or 'core_aba_phase=4,' in r:
            fast+=100000;checks+=100
        r=r.replace('perf=core-aba-1','perf='+PROFILE+' memory_state=0')
        for key in ('nso_core_frames','scoped_vm_draw_skips','scoped_native_draw_skips','nso_core_armed'):
            old=r.split(key+'=')[1].split(',')[0].split(']')[0]
            r=r.replace(key+'='+old,key+'=0')
        rows.append(r[:-1]+f',binary_sprite_fast={fast},binary_sprite_checks={checks},binary_sprite_mismatch=0,nso_repaint_skips=0,nso_service_skips=0,nso_paint_skips=0]')
    return '\n'.join(rows)

class BinaryTrialTest(unittest.TestCase):
    def test_schedule(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        src=r'''
#include "jarbox_binary_trial.h"
#include <assert.h>
int main(void) {
    JarBoxBinaryTrialScope s={0},other={0};
    uint64_t epoch=123;
    for(uint64_t t=0;t<240000;t++){
        int active=t>=75000&&t<150000;
        jarbox_binary_trial_begin(&s,1,1234,1,0,epoch,epoch+t*1000000);
        assert(jarbox_binary_trial_allowed(&s,1,1234)==active);
        assert(!jarbox_binary_trial_allowed(&s,2,1234));
        assert(!jarbox_binary_trial_allowed(&s,1,1235));
        assert(!jarbox_binary_trial_allowed(&other,1,1234));
        jarbox_binary_trial_end(&s);
        assert(!jarbox_binary_trial_allowed(&s,1,1234));
    }
    jarbox_binary_trial_begin(&s,1,1234,1,1,epoch,epoch+90000000000ULL);
    assert(!jarbox_binary_trial_allowed(&s,1,1234));
    jarbox_binary_trial_begin(&s,1,1234,0,0,epoch,epoch+90000000000ULL);
    assert(!jarbox_binary_trial_allowed(&s,1,1234));
    jarbox_binary_trial_begin(&s,1,1234,1,0,epoch,epoch+90000000000ULL);
    jarbox_binary_trial_begin(&s,2,1235,1,0,0,0);
    assert(!jarbox_binary_trial_allowed(&s,1,1234));
    return 0;
}
'''
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/"scope.c";p.write_text(src);exe=Path(d)/"scope"
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-O2",
                            "-DTREO_BINARY_ABA=1","-DTREO_BINARY_SPRITE_EXPERIMENT=1",
                            "-I",str(ROOT/"J2MEEmulator/minijvm/jvm"),str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_log(self):
        report=analyze(log(),'r','binary')
        self.assertEqual(report['b_vs_a_mean_process_points'],-10)
        self.assertEqual(report['legs'][1]['binary_fast'],1100000)
        self.assertEqual(report['legs'][0]['binary_fast'],0)
        self.assertEqual(report['legs'][2]['binary_fast'],0)
    def test_reject(self):
        a=log()
        bad=[a.replace('binary_sprite_mismatch=0','binary_sprite_mismatch=1'),
             a.replace('nso_paint_skips=0','nso_paint_skips=1'),
             a.replace('memory_state=0','memory_state=1'),
             a.replace('binary-sprite-2','binary-sprite-1'),
             a.replace('ninja-core-0','ninja-core-1'),
             '\n'.join(a.splitlines()[:-3]),
             '\n'.join(r.replace('binary_sprite_fast='+r.split('binary_sprite_fast=')[1].split(',')[0],'binary_sprite_fast=0') for r in a.splitlines())]
        for x in bad:
            with self.assertRaises(ValueError):
                analyze(x,'r','binary')
    def test_wiring(self):
        r=(ROOT/"J2MEEmulator/NativeBridge/j2me_render.m").read_text()
        self.assertIn("jarbox_binary_trial_begin(&binary_trial_scope",r)
        self.assertIn("jarbox_binary_trial_end(&binary_trial_scope)",r)
        self.assertIn("jarbox_binary_trial_allowed(&binary_trial_scope,p->owner_key,ctxHandle)",r)
        y=(ROOT/"codemagic.yaml").read_text()
        self.assertIn("JarBox Treo - optimization trial",y)
        self.assertIn('JARBOX_BINARY_SPRITE_EXPERIMENT: "2"',y)
        self.assertIn('JARBOX_CORE_ABA: "0"',y.split('  treo-optimization-trial:')[1])

if __name__=="__main__":unittest.main()
