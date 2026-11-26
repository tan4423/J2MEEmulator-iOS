"""Host differential check of the production constant handler chaining gate.

The VM is modeled here. The macro, flags, opcodes and target selection are
production; arithmetic and branches use an independent defined-width model.
The source assertions separately guard handler wiring and safepoint retention.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"
PRE = r"""
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <limits.h>
// JVM opcode values from jvm.h, verified below.
enum { op_iadd=0x60, op_isub=0x64, op_imul=0x68,
       op_ishl=0x78, op_ishr=0x7a, op_iushr=0x7c,
       op_iand=0x7e, op_ior=0x80, op_ixor=0x82,
       op_if_icmpeq=0x9f, op_if_icmpne=0xa0, op_if_icmplt=0xa1,
       op_if_icmpge=0xa2, op_if_icmpgt=0xa3, op_if_icmple=0xa4 };
#include "jarbox_const_fusion.h"
typedef struct { unsigned char *pc; } Runtime;
typedef struct { uint32_t stack[2]; int depth, pc, pauses, chained; } Result;
static int arithmetic(unsigned op) {
    switch(op) {
        case 0x60: case 0x64: case 0x68: case 0x78: case 0x7a:
        case 0x7c: case 0x7e: case 0x80: case 0x82: return 1;
        default: return 0;
    }
}
static int comparison(unsigned op) { return op>=0x9f && op<=0xa4; }
static uint32_t math(unsigned op,uint32_t a,uint32_t b) {
    unsigned n=b&31u;
    switch(op) {
        case 0x60:return a+b; case 0x64:return a-b; case 0x68:return a*b;
        case 0x78:return a<<n;
        case 0x7a:return (a>>n)|((a&0x80000000u)&&n?(UINT32_MAX<<(32-n)):0);
        case 0x7c:return a>>n; case 0x7e:return a&b; case 0x80:return a|b;
        case 0x82:return a^b; default:assert(0);return 0;
    }
}
static int compare(unsigned op,uint32_t a,uint32_t b) {
    // Compare signed Java ints without an implementation-defined cast.
    uint32_t x=a^0x80000000u,y=b^0x80000000u;
    switch(op){case 0x9f:return x==y;case 0xa0:return x!=y;
        case 0xa1:return x<y;case 0xa2:return x>=y;
        case 0xa3:return x>y;case 0xa4:return x<=y;default:assert(0);return 0;}
}
static Result run(unsigned op, uint32_t a,uint32_t b,int direct,int remaining,int displacement) {
    unsigned char bytes[16]={0};bytes[8]=(unsigned char)op;
    Runtime rt={bytes+8};Runtime *runtime=&rt;
    Result r={{a,b},2,8,0,0};
#if TREO_VM_CONST_FUSION
    const unsigned char *treo_vm_code_end=bytes+8+remaining;
    const int treo_vm_use_direct=direct;
    static void *const treo_vm_targets[256]={
        [op_iadd]=&&chain,[op_isub]=&&chain,[op_imul]=&&chain,
        [op_ishl]=&&chain,[op_ishr]=&&chain,[op_iushr]=&&chain,
        [op_iand]=&&chain,[op_ior]=&&chain,[op_ixor]=&&chain,
        [op_if_icmpeq]=&&chain,[op_if_icmpne]=&&chain,[op_if_icmplt]=&&chain,
        [op_if_icmpge]=&&chain,[op_if_icmpgt]=&&chain,[op_if_icmple]=&&chain};
#else
    (void)direct;(void)runtime;
#endif
    TREO_VM_FUSE_INT_CONSTANT();
    if (!remaining || (!arithmetic(op) && (!comparison(op)||remaining<3))) return r;
    goto execute;
#if TREO_VM_CONST_FUSION
chain:
    assert(runtime->pc==bytes+8 && r.depth==2);
    r.chained=1;
#endif
execute:
    if(arithmetic(op)){r.stack[0]=math(op,a,b);r.depth=1;r.pc+=1;}
    else {r.depth=0;if(compare(op,a,b)){r.pc+=displacement;r.pauses++;}else r.pc+=3;}
    return r;
}
int main(void){
    const uint32_t vals[]={0,1,31,32,UINT32_MAX,0x80000000u,0x7fffffffu,123456789u};
    unsigned count=0;
    for(unsigned op=0;op<256;++op)for(int remaining=0;remaining<=3;++remaining)
    for(unsigned i=0;i<sizeof(vals)/sizeof(vals[0]);++i)
    for(unsigned j=0;j<sizeof(vals)/sizeof(vals[0]);++j)
    for(int disp=-4;disp<=4;disp+=8){
        Result baseline=run(op,vals[i],vals[j],0,remaining,disp);
        Result actual=run(op,vals[i],vals[j],1,remaining,disp);
        int expect=TREO_VM_CONST_FUSION && remaining>0 &&
            ((TREO_VM_CONST_ARITH_FUSION_EXPERIMENT && arithmetic(op)) ||
             (TREO_VM_CONST_BRANCH_FUSION_EXPERIMENT && remaining>=3 && comparison(op)));
        assert(!baseline.chained && actual.chained==expect);
        assert(actual.depth==baseline.depth && actual.pc==baseline.pc && actual.pauses==baseline.pauses);
        assert(!memcmp(actual.stack,baseline.stack,sizeof(actual.stack)));
        ++count;
    }
    printf("constant fusion: %u cases PASS (enabled=%d)\n",count,TREO_VM_CONST_FUSION);
}
"""


class ConstFusionTest(unittest.TestCase):
    def test_production_gate_and_differential_model(self):
        cc = shutil.which(os.environ.get("CC", "clang"))
        if not cc:
            self.skipTest("computed goto compiler unavailable")
        flags = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror"]
        if os.environ.get("JARBOX_CONST_FUSION_SANITIZE") == "1":
            flags += ["-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        configurations = [(0,0,1,0,0,0), (1,0,1,0,0,0), (0,1,1,0,0,0), (1,1,1,0,0,0),
                          (1,1,0,0,0,0), (1,1,1,1,0,0), (1,1,1,0,1,0), (1,1,1,0,0,1)]
        keys = ("TREO_VM_CONST_ARITH_FUSION_EXPERIMENT", "TREO_VM_CONST_BRANCH_FUSION_EXPERIMENT",
                "TREO_VM_DIRECT_DISPATCH", "_JVM_DEBUG_PROFILE", "_JVM_DEBUG_LOG_LEVEL")
        with tempfile.TemporaryDirectory() as td:
            p = Path(td)
            (p / "test.c").write_text(PRE)
            for config in configurations:
                with self.subTest(config=config):
                    defs = [f"-D{k}={v}" for k,v in zip(keys,config)]
                    if config[-1]:
                        defs.append("-D__JVM_DEBUG__=1")
                    exe = p / "test"
                    subprocess.run([cc, *flags, *defs, "-I", str(JVM), str(p / "test.c"), "-o", str(exe)], check=True, timeout=30)
                    run = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
                    self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
                    self.assertIn("131072 cases PASS", run.stdout)

    def test_production_handler_wiring(self):
        s = (JVM / "interpreter.c").read_text()
        constants = ["iconst_m1", *[f"iconst_{i}" for i in range(6)], "bipush", "sipush"]
        for op in constants:
            body = s.split(f"case op_{op}: TREO_VM_HANDLER(op_{op}) {{",1)[1].split("case op_",1)[0]
            self.assertIn("TREO_VM_FUSE_INT_CONSTANT();",body)
            self.assertLess(body.index("runtime->pc"),body.index("TREO_VM_FUSE_INT_CONSTANT();"))
        self.assertEqual(s.count("TREO_VM_FUSE_INT_CONSTANT();"),len(constants))
        h = (JVM / "jvm.h").read_text()
        for value,name in ((0x60,"iadd"),(0x64,"isub"),(0x68,"imul"),(0x78,"ishl"),
                           (0x7a,"ishr"),(0x7c,"iushr"),(0x7e,"iand"),(0x80,"ior"),(0x82,"ixor"),
                           *[(0x9f+i,"if_icmp"+x) for i,x in enumerate(("eq","ne","lt","ge","gt","le"))]):
            self.assertIn(f"/* 0x{value:02x} */ op_{name},",h.lower())
            self.assertIn(f"[op_{name}] = &&treo_vm_label_op_{name}",s)
            if name.startswith("if_icmp"):
                body = s.split(f"case op_{name}: TREO_VM_HANDLER(op_{name}) {{",1)[1].split("case op_",1)[0]
                self.assertIn("check_gc_pause(offset);",body)
        self.assertIn("TREO_VM_DIRECT_DISPATCH && !jvm->jdwp_enable",s)
        self.assertIn("#if TREO_VM_ALOAD_FIELD_FUSION || TREO_VM_CONST_FUSION",s)


if __name__ == "__main__":
    unittest.main()
