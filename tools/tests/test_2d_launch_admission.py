"""Extract native launch admission; registry/diagnostics modeled, pthread locks real."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

BRIDGE = Path(__file__).resolve().parents[2] / "J2MEEmulator/NativeBridge/jvm_bridge.c"
PRE = r'''
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
#include <assert.h>
#include <stdio.h>
typedef struct { uint64_t token; } JarBoxVMContext;
static JarBoxVMContext slots[2];
static pthread_mutex_t g_bridge_focus_transition_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_bridge_lifecycle_lock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_bridge_session_sequence;
static uint64_t g_bridge_focus, g_bridge_registry;
static int fail_claim, fail_select, fail_diag;
static int jvm_bridge_supported_concurrent_sessions(void){return 2;}
static uint64_t jarbox_focus_visible(uint64_t *f){return *f;}
static JarBoxVMContext *bridge_reserve_slot_locked(uint64_t token,unsigned cap){for(unsigned i=0;i<cap;i++)if(!slots[i].token){slots[i].token=token;return &slots[i];}return NULL;}
static void bridge_reset_slot_locked(JarBoxVMContext *s){s->token=0;}
static int jarbox_registry_claim(uint64_t *r,uint64_t *f,uint64_t token,unsigned cap){(void)r;(void)f;(void)token;(void)cap;return !fail_claim;}
static int jarbox_focus_select(uint64_t *f,uint64_t token){if(fail_select)return 0;*f=token;return 1;}
static int bridge_diag_begin(uint64_t token){(void)token;return !fail_diag;}
static int jarbox_registry_finish(uint64_t *r,uint64_t *f,uint64_t token){(void)r;if(*f==token)*f=0;return 1;}
static uint64_t jvm_bridge_push_java_thread_token(uint64_t token){return token;}
static void jvm_bridge_note_net_trace(const char *s){(void)s;}
static void jvm_bridge_pop_java_thread_token(uint64_t token){(void)token;}
'''
MAIN = r'''
static void *launch(void *p){uint64_t *token=p;jvm_bridge_try_begin_session_with_token(token);return NULL;}
int main(void){
    for(int i=0;i<10000;i++){
        uint64_t a=0,b=999;
        assert(jvm_bridge_try_begin_session_with_token(&a)&&a);
        assert(!jvm_bridge_try_begin_session_with_token(&b)&&!b&&g_bridge_focus==a&&slots[1].token==0);
        g_bridge_focus=0; // modeled completed park
        fail_claim=1;assert(!jvm_bridge_try_begin_session_with_token(&b)&&!b&&!slots[1].token&&!g_bridge_focus);fail_claim=0;
        fail_select=1;assert(!jvm_bridge_try_begin_session_with_token(&b)&&!b&&!slots[1].token&&!g_bridge_focus);fail_select=0;
        fail_diag=1;assert(!jvm_bridge_try_begin_session_with_token(&b)&&!b&&!slots[1].token&&!g_bridge_focus);fail_diag=0;
        assert(jvm_bridge_try_begin_session_with_token(&b)&&b&&g_bridge_focus==b&&slots[0].token==a);
        g_bridge_focus=0;uint64_t c=0;assert(!jvm_bridge_try_begin_session_with_token(&c)&&!c);
        slots[0].token=slots[1].token=0;
    }
    for(int i=0;i<100;i++){
        uint64_t a=0,b=0;pthread_t x,y;
        assert(!pthread_create(&x,NULL,launch,&a));assert(!pthread_create(&y,NULL,launch,&b));
        assert(!pthread_join(x,NULL));assert(!pthread_join(y,NULL));
        assert((a!=0)+(b!=0)==1&&g_bridge_focus==(a?a:b)&&!slots[1].token);
        g_bridge_focus=slots[0].token=0;
    }
    puts("admission transaction: 10000 cycles + 100 concurrent launch pairs PASS");
}
'''
class LaunchAdmissionTest(unittest.TestCase):
    def test_extracted_admission(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("C compiler unavailable")
        source = BRIDGE.read_text()
        a = source.index("int jvm_bridge_try_begin_session_with_token(uint64_t *out_token) {")
        b = source.index("\nint jvm_bridge_try_begin_session(void)", a)
        flags = ["-std=c11", "-O1", "-Wall", "-Wextra", "-Werror", "-pthread"]
        if os.environ.get("JARBOX_ADMISSION_SANITIZE") == "1":
            flags += ["-g", "-fsanitize=address,undefined"]
        with tempfile.TemporaryDirectory() as td:
            p, exe = Path(td) / "admission.c", Path(td) / "admission"
            p.write_text(PRE + source[a:b] + MAIN)
            subprocess.run([cc, *flags, str(p), "-o", str(exe)], check=True, timeout=30)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("10000 cycles + 100 concurrent launch pairs PASS", r.stdout)

    def test_source_cap_and_lock_order(self):
        src = BRIDGE.read_text()
        body = src.split("int jvm_bridge_try_begin_session_with_token(uint64_t *out_token) {", 1)[1].split("\nint jvm_bridge_try_begin_session(void)", 1)[0]
        self.assertLess(body.index("pthread_mutex_lock(&g_bridge_focus_transition_lock)"),
                        body.index("pthread_mutex_lock(&g_bridge_lifecycle_lock)"))
        self.assertLess(body.index("jarbox_focus_visible(&g_bridge_focus) != 0"),
                        body.index("bridge_reserve_slot_locked("))
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return 1;", src)

if __name__ == "__main__":
    unittest.main()
