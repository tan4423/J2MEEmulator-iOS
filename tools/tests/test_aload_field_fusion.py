"""Host differential test for the actual bounded dispatch fusion macro.

The existing field handlers remain unchanged. Test direct/fallback routing,
all six widths, exception PC, batching, session separation and short buffers.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
CORE=ROOT/"J2MEEmulator/minijvm/jvm"
PRE=r"""
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stddef.h>
typedef uint8_t u8;
typedef uint16_t u16;
enum { op_getfield_ref=0xd6,op_getfield_long,op_getfield_int,
       op_getfield_short,op_getfield_jchar,op_getfield_byte };
#define TREO_VM_DIRECT_DISPATCH 1
#define _JVM_DEBUG_PROFILE 0
#define _JVM_DEBUG_LOG_LEVEL 0
typedef struct { u8 *pc; } Runtime;
typedef struct { u16 jarbox_aload_field_pending; } Thread;
typedef struct { uint64_t aload_field_fusions; } State;
typedef struct { State treo_state; } Session;
typedef struct { Session *session; } VM;
"""
MAIN=r"""
#define CHECK(x) do{if(!(x)){fprintf(stderr,"line %d\n",__LINE__);return 1;}}while(0)
// Model the unchanged aload and existing getfield dispatch/handler entry.
// The macro under test is extracted verbatim from interpreter.c.
static int run(u8 *bytes, int n, int direct, VM *jvm,Thread *thrd_info,
               int null_receiver, int *pc, int *stack) {
    Runtime rt={bytes};Runtime *runtime=&rt;
    const u8 *treo_vm_code_end=bytes+n;
    const int treo_vm_use_direct=direct;
    static void *const treo_vm_targets[256]={
        [op_getfield_ref]=&&f0,[op_getfield_long]=&&f1,
        [op_getfield_int]=&&f2,[op_getfield_short]=&&f3,
        [op_getfield_jchar]=&&f4,[op_getfield_byte]=&&f5
    };
    ++*stack; ++runtime->pc;
    TREO_VM_FUSE_ALOAD_FIELD();
    *pc=(int)(runtime->pc-bytes);return -1;
f0:
    if(null_receiver){--*stack;*pc=(int)(runtime->pc-bytes);return -2;}
    runtime->pc+=3;*pc=(int)(runtime->pc-bytes);return 0;
f1:
    if(null_receiver){--*stack;*pc=(int)(runtime->pc-bytes);return -2;}
    ++*stack;runtime->pc+=3;*pc=(int)(runtime->pc-bytes);return 1;
f2: f3: f4: f5:
    if(null_receiver){--*stack;*pc=(int)(runtime->pc-bytes);return -2;}
    {int type=*runtime->pc-op_getfield_ref;runtime->pc+=3;*pc=(int)(runtime->pc-bytes);return type;}
}
int main(void) {
    Session a={0},b={0}; VM va={&a},vb={&b};Thread ta={0},tb={0};
    u8 bytes[4]={0x2a,0,0,0};
    int pc,stack,result;
    for(int i=0;i<6;i++){
        bytes[1]=op_getfield_ref+i;
        pc=stack=0;result=run(bytes,4,1,&va,&ta,0,&pc,&stack);
        CHECK(result==i && pc==4 && stack==(i==1?2:1));
        pc=stack=0;CHECK(run(bytes,4,1,&va,&ta,1,&pc,&stack)==-2 && pc==1 && stack==0);
        for(int len=1;len<4;len++){pc=stack=0;CHECK(run(bytes,len,1,&va,&ta,0,&pc,&stack)==-1 && pc==1 && stack==1);}
        pc=stack=0;CHECK(run(bytes,4,0,&va,&ta,0,&pc,&stack)==-1 && pc==1 && stack==1);
    }
    for(int op=0;op<256;op++){
        if(op>=op_getfield_ref && op<=op_getfield_byte)continue;
        bytes[1]=(u8)op;pc=stack=0;
        CHECK(run(bytes,4,1,&va,&ta,0,&pc,&stack)==-1 && pc==1 && stack==1);
    }
    CHECK(ta.jarbox_aload_field_pending==12 && a.treo_state.aload_field_fusions==0);
    bytes[1]=op_getfield_int;
    for(int i=0;i<256*1000;i++){
        pc=stack=0;CHECK(run(bytes,4,1,&vb,&tb,0,&pc,&stack)==2);
    }
    CHECK(b.treo_state.aload_field_fusions==256000 && tb.jarbox_aload_field_pending==0);
    CHECK(a.treo_state.aload_field_fusions==0 && ta.jarbox_aload_field_pending==12);
    puts("aload-field dispatch fusion: PASS");
    return 0;
}
"""
class AloadFieldFusionTest(unittest.TestCase):
    def test_production_macro(self):
        cc=shutil.which("clang")
        if not cc:self.skipTest("computed goto requires clang")
        s=(CORE/"interpreter.c").read_text()
        a=s.index("#if TREO_VM_DIRECT_DISPATCH && !_JVM_DEBUG_PROFILE")
        e=s.index("#endif",a)+len("#endif")
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"test.c",Path(td)/"test"
            p.write_text(PRE+s[a:e]+"\n"+MAIN)
            subprocess.run([cc,"-std=gnu11","-O2","-Wall","-Wextra","-Werror",str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_original_handlers_and_guard(self):
        s=(CORE/"interpreter.c").read_text()
        for i in range(4):
            body=s.split(f"case op_aload_{i}: TREO_VM_HANDLER(op_aload_{i}) {{",1)[1].split("}",1)[0]
            self.assertLess(body.index(f"(sp++)->rvalue = localvar[{i}].rvalue;"),body.index("runtime->pc++;"))
            self.assertLess(body.index("runtime->pc++;"),body.index("TREO_VM_FUSE_ALOAD_FIELD();"))
        for suffix in ("ref","long","int","short","jchar","byte"):
            op="op_getfield_"+suffix
            body=s.split(f"case {op}: TREO_VM_HANDLER({op}) {{",1)[1].split("case op_",1)[0]
            self.assertIn("ins = (--sp)->rvalue;",body)
            self.assertIn("goto label_null_throw;",body)
            self.assertIn("runtime->pc += 3;",body)
            self.assertIn(f"[{op}] = &&treo_vm_label_{op}",s)
        self.assertIn("TREO_VM_ALOAD_FIELD_FUSION_DISABLED",s)
        self.assertIn("TREO_VM_DIRECT_DISPATCH && !jvm->jdwp_enable",s)
        self.assertIn("treo_vm_code_end - runtime->pc >= 3",s)
if __name__=="__main__":unittest.main()
