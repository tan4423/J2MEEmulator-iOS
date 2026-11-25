"""Deep Treo hot-call guard and diagnostic role equivalence (host C doubles)."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
PRE=r"""
#include <stdint.h>
#include <string.h>
#include <stdio.h>
typedef uint16_t u16;
typedef const char Utf8String;
typedef struct {Utf8String *name;} JClass;
typedef struct {JClass *_this_class;Utf8String *name,*descriptor;u16 treo_mod_diag_roles;} MethodInfo;
static unsigned compares;
static int utf8_equals_c(Utf8String *s,const char *t){++compares;return s&&!strcmp(s,t);}
"""
MAIN=r"""
#define CHECK(x) do{if(!(x)){fprintf(stderr,"line %d\n",__LINE__);return 1;}}while(0)
int main(void){
    struct {const char *cl,*name,*desc;unsigned roles;} cases[]={
        {"main/a","run","()V",1},
        {"Class_cu","run","()V",1|2|64},
        {"Class_cu","run","(I)V",1|2},
        {"Class_cc","a","()V",1|16},
        {"Class_cc","a","(I)V",1|32},
        {"Class_cu","a","(I)V",1|128},
        {"Class_cu","d","(Ljava/lang/String;)V",1|4|256},
        {"Class_cu","a","(Ljava/lang/String;)V",1|256},
        {"Class_cu","<init>","()V",1|1024},
        {"GameMidlet","<init>","(I)V",1|2048},
        {"Class_ek","paint","(Ljavax/microedition/lcdui/Graphics;)V",1|4096},
        {"Class_ek","a","(LClass_bv;)V",1|8192},
        {"Class_em","a","(Ljava/lang/String;LClass_by;LClass_by;LClass_by;)V",1|512},
        {"Class_fq","d","()V",1|8},{"Class_gv","g","()V",1|8},
        {"Class_fq","x","()V",1},{"Class_ek","paint","()V",1},
        {"Class_cc","a","(J)V",1}
    };
    for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++){
        JClass cl={cases[i].cl};
        MethodInfo m={&cl,cases[i].name,cases[i].desc,0};
        CHECK(treo_mod_diag_roles(&m)==cases[i].roles);
        unsigned before=compares;
        for(unsigned n=0;n<10000;n++) CHECK(treo_mod_diag_roles(&m)==cases[i].roles);
        CHECK(compares==before);
    }
    CHECK(treo_mod_diag_roles(NULL)==0);
    JarBoxTreoState a={0},b={0};
    jarbox_treo_nso_profile_set(&a,1,0);
    jarbox_treo_nso_profile_set(&b,1,1);
    jarbox_treo_nso_canvas_note(&a);
    for(int i=0;i<10000;i++){jarbox_treo_nso_note_request(&a);jarbox_treo_nso_note_skip(&a,0);jarbox_treo_nso_note_skip(&b,1);}
    CHECK(a.nso_repaint_requests==10000 && b.nso_repaint_requests==0);
    CHECK(jarbox_treo_nso_skip_count(&a,0)==10000 && !jarbox_treo_nso_skip_count(&a,1));
    CHECK(jarbox_treo_nso_skip_count(&b,1)==10000 && !jarbox_treo_nso_skip_count(&b,0));
    jarbox_treo_render_mode_set(&a,0,0);
    CHECK(jarbox_treo_nso_skip_count(&a,0)==10000 && jarbox_treo_nso_canvas_recognized(&a));
    CHECK(!jarbox_treo_nso_skip_count(&a,3) && !jarbox_treo_nso_skip_count(NULL,0));
    return 0;
}
"""
class DeepTreoHotCallTest(unittest.TestCase):
    def test_cached_diagnostic_roles_and_owner_counters(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        s=(JVM/"interpreter.c").read_text()
        start=s.index("enum {\n    TREO_DIAG_KNOWN")
        end=s.index("\nextern void jvm_bridge_note_net_trace",start)
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"test.c",Path(td)/"test"
            p.write_text(PRE+'\n#include "jarbox_treo_state.h"\n'+s[start:end]+MAIN)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-I",str(JVM),str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_scope_and_token_wiring(self):
        s=(JVM/"interpreter.c").read_text()
        render=(ROOT/"J2MEEmulator/NativeBridge/j2me_render.m").read_text()
        self.assertIn("const int headless_scope = pruntime->thrd_info->jarbox_headless_scope;",s)
        self.assertIn("(headless_scope || TREO_VM_ARRAY_LOOKUP)",s)
        self.assertIn("if (headless_scope && (treo_paint_mode == 4 ||",s)
        self.assertEqual(render.count("runtime->thrd_info->jarbox_headless_scope = g_afk_canvas != 0;"),2)
        self.assertIn("caller_key != g_afk_canvas_owner_key",render)
        self.assertNotIn("static _Atomic uint64_t treo_ninja_skips",render)
        bridge=(ROOT/"J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        self.assertIn("jvm_bridge_visit_running_vm_for_token(token, bridge_treo_snapshot, out)",bridge)
        swift=(ROOT/"J2MEEmulator/UI/GameViewController.swift").read_text()
        self.assertIn("jvm_bridge_treo_snapshot_for_token(gameSessionToken, &treo)",swift)
if __name__=="__main__":
    unittest.main()
