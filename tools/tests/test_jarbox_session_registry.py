"""Native ownership registry host-model test; does NOT test UIKit or real JVMs."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
REGISTRY = ROOT / "J2MEEmulator/NativeBridge/jarbox_session_registry.h"
SESSION = ROOT / "J2MEEmulator/minijvm/jvm/jarbox_session.h"
C = r"""
#include <stdint.h>
#include <stdio.h>
#include <pthread.h>
#include "jarbox_session_registry.h"
static JarBoxSession *make(uint64_t t, uintptr_t ptr) {
    JarBoxSession *s=jarbox_session_create((void *)ptr);
    if (!s || !jarbox_session_bind_token(s,t)) return NULL;
    return s;
}
int main(void) {
    JarBoxFocusPolicy f=JARBOX_FOCUS_POLICY_INITIALIZER;
    JarBoxSessionRegistry r=JARBOX_SESSION_REGISTRY_INITIALIZER;
    JarBoxSession *a=make(101,0x1234), *b=make(102,0x5678);
    if(!a||!b||!jarbox_registry_claim(&r,&f,101,1)||
       jarbox_registry_claim(&r,&f,102,1)||
       !jarbox_registry_bind(&r,101,a)) return 1;
    if(!jarbox_registry_contains_token(&r,101) ||
       jarbox_registry_contains_token(&r,102) ||
       jarbox_registry_should_stop_vm(&r,a->vm) ||
       !jarbox_registry_should_stop_vm(&r,b->vm)) return 12;
    JarBoxSession *pin=NULL;
    if(jarbox_registry_pin_vm(&r,101,&pin)!=(void *)(uintptr_t)0x1234 ||
       pin!=a) return 2;
    jarbox_registry_begin_stop(&r,101);
    if(jarbox_session_mark_dead(a)||
       jarbox_registry_pin_vm(&r,101,&pin)||
       jarbox_registry_finish(&r,&f,101)) return 3;
    jarbox_session_callback_done(a);
    if(!jarbox_session_mark_dead(a)||
       !jarbox_registry_finish(&r,&f,101)) return 4;
    jarbox_session_release(a);
    if(!jarbox_registry_claim(&r,&f,102,1)||
       !jarbox_registry_bind(&r,102,b)||
       jarbox_registry_pin_vm(&r,101,&pin)) return 5;
    jarbox_registry_begin_stop(&r,102);
    if(!jarbox_session_mark_dead(b)||
       !jarbox_registry_finish(&r,&f,102)) return 6;
    jarbox_session_release(b);
    /* Back can arrive before jvm_init finishes. The stopped STARTING slot
     * still needs a session binding for safe teardown, but never a callback. */
    JarBoxSession *early=make(105,0x9abc);
    if(!early || !jarbox_registry_claim(&r,&f,105,1) ||
       !jarbox_registry_request_stop(&r,105) ||
       !jarbox_registry_bind(&r,105,early) ||
       jarbox_registry_pin_vm(&r,105,&pin)) return 10;
    jarbox_registry_begin_stop(&r,105);
    if(!jarbox_session_mark_dead(early) ||
       !jarbox_registry_finish(&r,&f,105) ||
       jarbox_registry_active_count(&r)!=0) return 11;
    jarbox_session_release(early);
    a=make(103,0x1234); b=make(104,0x5678);
    if(!a||!b||!jarbox_registry_claim(&r,&f,103,2)||
       !jarbox_registry_claim(&r,&f,104,2)||
       !jarbox_registry_bind(&r,103,a)||
       !jarbox_registry_bind(&r,104,b)||
       jarbox_registry_should_stop_vm(&r,a->vm) ||
       jarbox_registry_should_stop_vm(&r,b->vm) ||
       jarbox_registry_active_count(&r)!=2 ||
       !jarbox_focus_select(&f,103)||
       !jarbox_focus_select(&f,104)||
       jarbox_focus_visible(&f)!=104) return 7;
    if(!jarbox_registry_request_stop(&r,103) ||
       !jarbox_registry_should_stop_vm(&r,a->vm) ||
       jarbox_registry_should_stop_vm(&r,b->vm) ||
       !jarbox_registry_contains_token(&r,104)) return 13;
    jarbox_registry_begin_stop(&r,103);
    if(!jarbox_session_mark_dead(a)||
       !jarbox_registry_finish(&r,&f,103)||
       jarbox_registry_active_count(&r)!=1 ||
       jarbox_focus_visible(&f)!=104) return 8;
    jarbox_session_release(a);
    if(!jarbox_registry_should_stop_vm(&r,(void *)(uintptr_t)0x1234) ||
       jarbox_registry_should_stop_vm(&r,b->vm)) return 14;
    jarbox_registry_begin_stop(&r,104);
    if(!jarbox_session_mark_dead(b)||
       !jarbox_registry_finish(&r,&f,104)) return 9;
    jarbox_session_release(b);
    puts("JarBox registry: OK (stop A keeps B and single focus)");
    return 0;
}
"""


class JarBoxRegistryTest(unittest.TestCase):
    def test_owned_session_stop_and_focus(self):
        cc=shutil.which("cc") or shutil.which("clang")
        if not cc: self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-registry-") as d:
            src,exe=Path(d)/"registry.c",Path(d)/"registry"
            src.write_text(C,encoding="utf-8")
            build=subprocess.run([cc,"-std=c11","-O1","-g","-pthread",
                "-Wall","-Wextra","-Werror","-I",str(REGISTRY.parent),
                "-I",str(SESSION.parent),str(src),"-o",str(exe)],
                capture_output=True,text=True,timeout=45)
            self.assertEqual(build.returncode,0,build.stdout+build.stderr)
            run=subprocess.run([str(exe)],capture_output=True,text=True,timeout=30)
            self.assertEqual(run.returncode,0,run.stdout+run.stderr)
            self.assertIn("JarBox registry: OK",run.stdout)


if __name__=="__main__":
    unittest.main()
