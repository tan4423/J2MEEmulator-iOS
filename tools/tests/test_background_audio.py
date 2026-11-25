"""Host PCM and extracted native policy; no AVFoundation/device claim."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
NATIVE=ROOT/"J2MEEmulator/NativeBridge"
PCM=r"""
#include "jarbox_ambient_pcm.h"
#include <assert.h>
#include <stdlib.h>
#include <stdio.h>
static unsigned le16(const uint8_t *p){return p[0]|((unsigned)p[1]<<8);}
static unsigned le32(const uint8_t *p){return le16(p)|(le16(p+2)<<16);}
static int sample(const uint8_t *p){unsigned x=le16(p);return x>=32768?(int)x-65536:(int)x;}
int main(void){
 uint8_t *p=malloc(JARBOX_AMBIENT_BYTES+2);assert(p);memset(p,0xa5,JARBOX_AMBIENT_BYTES+2);
 assert(!jarbox_ambient_wav(NULL,JARBOX_AMBIENT_BYTES));
 assert(!jarbox_ambient_wav(p+1,JARBOX_AMBIENT_BYTES-1));
 assert(jarbox_ambient_wav(p+1,JARBOX_AMBIENT_BYTES));
 assert(p[0]==0xa5 && p[JARBOX_AMBIENT_BYTES+1]==0xa5);const uint8_t *w=p+1;
 assert(!memcmp(w,"RIFF",4)&&!memcmp(w+8,"WAVEfmt ",8)&&!memcmp(w+36,"data",4));
 assert(le32(w+4)==JARBOX_AMBIENT_BYTES-8&&le32(w+16)==16);
 assert(le16(w+20)==1&&le16(w+22)==1&&le32(w+24)==16000&&le32(w+28)==32000);
 assert(le16(w+32)==2&&le16(w+34)==16&&le32(w+40)==128000);
 double sum=0;int peak=0;for(unsigned i=0;i<JARBOX_AMBIENT_FRAMES;++i){int x=sample(w+44+2*i);sum+=(double)x*x;if(abs(x)>peak)peak=abs(x);}
 assert(peak>1000&&peak<7601);assert(sum/JARBOX_AMBIENT_FRAMES>1000000);
 assert(abs(sample(w+44)-sample(w+JARBOX_AMBIENT_BYTES-2))<1000);
 printf("PCM WAV: frames=%d peak=%d rms=%.1f PASS\n",JARBOX_AMBIENT_FRAMES,peak,sqrt(sum/JARBOX_AMBIENT_FRAMES));free(p);
}
"""
POLICY_PRELUDE=r"""
#include <stdatomic.h>
#include <pthread.h>
#include <assert.h>
#define JARBOX_REGISTRY_MAX_SLOTS 64
enum { BRIDGE_IDLE=0,BRIDGE_STARTING=1,BRIDGE_RUNNING=2,BRIDGE_CLEANUP=3 };
typedef struct { atomic_int active,phase,stop_requested; int exclusive_3d; } JarBoxVMContext;
static JarBoxVMContext g_bridge_slots[64];
static pthread_mutex_t g_bridge_lifecycle_lock=PTHREAD_MUTEX_INITIALIZER;
"""
POLICY_MAIN=r"""
int main(void){
    assert(jvm_bridge_background_audio_policy()==0);
    JarBoxVMContext *a=&g_bridge_slots[0],*b=&g_bridge_slots[63];
    a->active=1;a->phase=BRIDGE_STARTING;
    assert(jvm_bridge_background_audio_policy()==1);
    a->phase=BRIDGE_RUNNING;
    assert(jvm_bridge_background_audio_policy()==2);
    b->active=1;b->phase=BRIDGE_STARTING;
    assert(jvm_bridge_background_audio_policy()==1);
    b->phase=BRIDGE_RUNNING;
    assert(jvm_bridge_background_audio_policy()==2);
    a->stop_requested=1;
    assert(jvm_bridge_background_audio_policy()==2);
    a->phase=BRIDGE_CLEANUP;
    assert(jvm_bridge_background_audio_policy()==2);
    b->stop_requested=1;
    assert(jvm_bridge_background_audio_policy()==1);
    b->exclusive_3d=1;
    assert(jvm_bridge_background_audio_policy()==0);
    a->active=0;b->active=0;
    assert(jvm_bridge_background_audio_policy()==0);
}
"""
class BackgroundAudioTest(unittest.TestCase):
    def compile_run(self,src):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"test.c",Path(td)/"test"
            p.write_text(src)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-pthread",
                            "-I",str(NATIVE),str(p),"-lm","-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_pcm(self):
        self.compile_run(PCM)
    def test_policy(self):
        bridge=(NATIVE/"jvm_bridge.c").read_text()
        a=bridge.index("int jvm_bridge_background_audio_policy(void) {")
        b=bridge.index("\n}",a)+2
        self.compile_run(POLICY_PRELUDE+bridge[a:b]+POLICY_MAIN)
    def test_volume_clamp(self):
        audio=(NATIVE/"j2me_audio.m").read_text()
        a=audio.index("static int background_clamp_volume(int percent) {")
        b=audio.index("\n}",a)+2
        self.compile_run("#include <assert.h>\n#include <limits.h>\n"+audio[a:b]+r"""
int main(void) {
    assert(background_clamp_volume(INT_MIN)==0);
    assert(background_clamp_volume(INT_MAX)==100);
    for (int i=-1000;i<=1000;++i)
        assert(background_clamp_volume(i)==(i<0?0:i>100?100:i));
    return 0;
}
""")
    def test_audio_wiring(self):
        audio=(NATIVE/"j2me_audio.m").read_text()
        self.assertIn("jvm_bridge_background_audio_policy()!=2",audio)
        self.assertIn("AVAudioSessionCategorySoloAmbient",audio)
        self.assertIn("AVAudioSessionCategoryOptionMixWithOthers",audio)
        self.assertIn("g_background_player.numberOfLoops=-1",audio)
        self.assertIn("AVAudioSessionInterruptionOptionShouldResume",audio)
        self.assertIn("AVAudioSessionRouteChangeReasonOldDeviceUnavailable",audio)
        self.assertIn("AVAudioSessionMediaServicesWereResetNotification",audio)
        self.assertIn("g_background_player.volume=(float)g_background_volume_percent/100.0f;",audio)
        setter=audio.split("void j2me_audio_background_set_volume(int percent) {",1)[1].split("\n}",1)[0]
        self.assertIn("g_background_player.volume=(float)percent/100.0f;",setter)
        self.assertIn("setInteger:percent forKey:kBackgroundVolumeKey",setter)
        self.assertNotIn("background_play_locked(",setter)
        self.assertNotIn("background_stop_locked(",setter)
        self.assertNotIn("setActive:",setter)
        self.assertIn("objectForKey:kBackgroundVolumeKey",audio)
        self.assertIn("out.player_volume_percent=",audio)
        self.assertIn("j2me_audio_background_revalidate();",audio)
        plist=plistlib.loads((ROOT/"J2MEEmulator/SupportingFiles/Info.plist").read_bytes())
        self.assertEqual(plist["UIBackgroundModes"],["audio"])
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        self.assertIn('audioLine("begin", audioStart)',scene)
        self.assertIn('audioLine("end", j2me_audio_background_snapshot())',scene)
        self.assertIn("j2me_audio_background_set_volume(percent)",scene)
        self.assertIn("volume_percent=",scene)
        self.assertIn("player_volume_percent=",scene)
        for name in ("GameViewController.swift","AppsListViewController.swift"):
            self.assertIn("JarBoxBackgroundDiagnostics.showAudio(from: self)",(ROOT/"J2MEEmulator/UI"/name).read_text())
if __name__=="__main__":unittest.main()
