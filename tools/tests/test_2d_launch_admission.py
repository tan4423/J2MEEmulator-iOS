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
typedef struct { uint64_t token; int exclusive_3d; } JarBoxVMContext;
static JarBoxVMContext slots[64];
static unsigned configured_cap=2;
static pthread_mutex_t g_bridge_focus_transition_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_bridge_lifecycle_lock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_bridge_session_sequence;
static uint64_t g_bridge_focus, g_bridge_registry;
static int fail_claim, fail_select, fail_diag, memory_level;
static int jvm_bridge_memory_state(uint64_t *bytes){(void)bytes;return memory_level;}
static int jvm_bridge_supported_concurrent_sessions(void){return (int)configured_cap;}
static int bridge_3d_conflict_locked(int exclusive){for(unsigned i=0;i<configured_cap;i++)if(slots[i].token && (exclusive || slots[i].exclusive_3d))return 1;return 0;}
static uint64_t jarbox_focus_visible(uint64_t *f){return *f;}
static JarBoxVMContext *bridge_reserve_slot_locked(uint64_t token,unsigned cap){for(unsigned i=0;i<cap;i++)if(!slots[i].token){slots[i].token=token;return &slots[i];}return NULL;}
static void bridge_reset_slot_locked(JarBoxVMContext *s){s->token=0;s->exclusive_3d=0;}
static int jarbox_registry_claim(uint64_t *r,uint64_t *f,uint64_t token,unsigned cap){(void)r;(void)f;(void)token;(void)cap;return !fail_claim;}
static int jarbox_focus_select(uint64_t *f,uint64_t token){if(fail_select)return 0;*f=token;return 1;}
static int bridge_diag_begin(uint64_t token){(void)token;return !fail_diag;}
static int jarbox_registry_finish(uint64_t *r,uint64_t *f,uint64_t token){(void)r;if(*f==token)*f=0;return 1;}
static uint64_t jvm_bridge_push_java_thread_token(uint64_t token){return token;}
static void jvm_bridge_note_net_trace(const char *s){(void)s;}
static void jvm_bridge_pop_java_thread_token(uint64_t token){(void)token;}
'''
MAIN = r'''
static void *launch(void *p){uint64_t *token=p;bridge_try_begin_session(0, token);return NULL;}
int main(void){
    for(int i=0;i<10000;i++){
        uint64_t a=0,b=999;
        memory_level=2;
        assert(bridge_try_begin_session(0, &a)==-2 && !a && !slots[0].token && !g_bridge_focus);
        memory_level=0;
        assert(bridge_try_begin_session(0, &a)&&a);
        assert(!bridge_try_begin_session(0, &b)&&!b&&g_bridge_focus==a&&slots[1].token==0);
        g_bridge_focus=0; // modeled completed park
        assert(bridge_try_begin_session(1, &b)==-1 && !b);
        slots[0].exclusive_3d=1;
        assert(bridge_try_begin_session(0, &b)==-1 && !b);
        slots[0].exclusive_3d=0;
        memory_level=1;
        assert(bridge_try_begin_session(0, &b)==-2 && !b && slots[0].token==a && !slots[1].token && !g_bridge_focus);
        memory_level=0;
        fail_claim=1;assert(!bridge_try_begin_session(0, &b)&&!b&&!slots[1].token&&!g_bridge_focus);fail_claim=0;
        fail_select=1;assert(!bridge_try_begin_session(0, &b)&&!b&&!slots[1].token&&!g_bridge_focus);fail_select=0;
        fail_diag=1;assert(!bridge_try_begin_session(0, &b)&&!b&&!slots[1].token&&!g_bridge_focus);fail_diag=0;
        assert(bridge_try_begin_session(0, &b)&&b&&g_bridge_focus==b&&slots[0].token==a);
        g_bridge_focus=0;uint64_t c=0;assert(!bridge_try_begin_session(0, &c)&&!c);
        bridge_reset_slot_locked(&slots[0]);bridge_reset_slot_locked(&slots[1]);
        assert(bridge_try_begin_session(1,&a)==1&&a&&slots[0].exclusive_3d);
        g_bridge_focus=0;
        assert(bridge_try_begin_session(0,&b)==-1&&!b);
        assert(bridge_try_begin_session(1,&b)==-1&&!b);
        bridge_reset_slot_locked(&slots[0]);
        assert(bridge_try_begin_session(0,&b)==1&&b&&!slots[0].exclusive_3d);
        g_bridge_focus=0;bridge_reset_slot_locked(&slots[0]);
    }
    for(int i=0;i<100;i++){
        uint64_t a=0,b=0;pthread_t x,y;
        assert(!pthread_create(&x,NULL,launch,&a));assert(!pthread_create(&y,NULL,launch,&b));
        assert(!pthread_join(x,NULL));assert(!pthread_join(y,NULL));
        assert((a!=0)+(b!=0)==1&&g_bridge_focus==(a?a:b)&&!slots[1].token);
        g_bridge_focus=0;bridge_reset_slot_locked(&slots[0]);
    }
    configured_cap=64;
    for(unsigned i=0;i<configured_cap;i++){
        uint64_t t=0;
        assert(bridge_try_begin_session(0,&t)==1 && t && slots[i].token==t);
        g_bridge_focus=0;
        if(i==29){
            uint64_t denied=999;
            memory_level=1;
            assert(bridge_try_begin_session(0,&denied)==-2 && !denied && !slots[i+1].token);
            memory_level=0;
            assert(bridge_try_begin_session(1,&denied)==-1 && !denied);
        }
    }
    uint64_t denied=999;
    assert(!bridge_try_begin_session(0,&denied) && !denied);
    for(unsigned i=0;i<configured_cap;i++)bridge_reset_slot_locked(&slots[i]);
    puts("admission transaction: 10000 cycles + 100 concurrent launch pairs PASS");
    puts("memory-gated full capacity: PASS");
}
'''
class LaunchAdmissionTest(unittest.TestCase):
    def test_extracted_admission(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("C compiler unavailable")
        source = BRIDGE.read_text()
        a = source.index("static int bridge_try_begin_session(int exclusive, uint64_t *out_token) {")
        b = source.index("\nint jvm_bridge_try_begin_session_for_jar(", a)
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
            self.assertIn("memory-gated full capacity: PASS", r.stdout)

    def test_source_cap_and_lock_order(self):
        src = BRIDGE.read_text()
        body = src.split("static int bridge_try_begin_session(int exclusive, uint64_t *out_token) {", 1)[1].split("\nint jvm_bridge_try_begin_session_for_jar(", 1)[0]
        self.assertLess(body.index("pthread_mutex_lock(&g_bridge_focus_transition_lock)"),
                        body.index("pthread_mutex_lock(&g_bridge_lifecycle_lock)"))
        self.assertLess(body.index("jarbox_focus_visible(&g_bridge_focus) != 0"),
                        body.index("bridge_reserve_slot_locked("))
        self.assertLess(body.index("jvm_bridge_memory_state(NULL) != 0"),
                        body.index("bridge_reserve_slot_locked("))
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return JARBOX_REGISTRY_MAX_SLOTS;", src)

if __name__ == "__main__":
    unittest.main()
