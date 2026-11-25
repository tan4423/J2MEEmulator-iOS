"""Exact original-bytecode primitive leaf patterns and Java wraparound."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
C=r"""
#include <stdio.h>
#include <limits.h>
#include "jarbox_int_leaf.h"
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d\n",__LINE__);return 1;}} while(0)
static int32_t signed_bits(uint32_t x) {int32_t v;memcpy(&v,&x,4);return v;}
int main(void) {
    uint8_t a[]={0x1a,0x9e,0,5,0x1a,0xac,0x1a,0x74,0xac};
    uint8_t b[]={0x1a,0x9e,0,7,0x1a,0xa7,0,5,0x1a,0x74,0xac};
    CHECK(jarbox_int_leaf_match(a,9,"(I)I",1,1,0)==JARBOX_LEAF_ABS);
    CHECK(jarbox_int_leaf_match(b,11,"(I)I",1,1,0)==JARBOX_LEAF_ABS);
    for(int i=0;i<9;i++){uint8_t old=a[i];a[i]^=1;CHECK(!jarbox_int_leaf_match(a,9,"(I)I",1,1,0));a[i]=old;}
    for(int i=0;i<11;i++){uint8_t old=b[i];b[i]^=1;CHECK(!jarbox_int_leaf_match(b,11,"(I)I",1,1,0));b[i]=old;}
    CHECK(!jarbox_int_leaf_match(a,9,"(F)I",1,1,0));
    CHECK(!jarbox_int_leaf_match(a,9,"(I)I",2,1,0));
    CHECK(!jarbox_int_leaf_match(a,9,"(I)I",1,0,0));
    CHECK(!jarbox_int_leaf_match(a,9,"(I)I",1,1,1));
    CHECK(!jarbox_int_leaf_match(a,8,"(I)I",1,1,0));
    uint8_t id[]={0x1a,0xac}, neg[]={0x1a,0x74,0xac};
    CHECK(jarbox_int_leaf_match(id,2,"(I)I",1,1,0)==JARBOX_LEAF_IDENTITY);
    CHECK(jarbox_int_leaf_match(neg,3,"(I)I",1,1,0)==JARBOX_LEAF_NEGATE);
    for(int i=2;i<=8;i++){
        uint8_t code[]={(uint8_t)i,0xac};
        uint8_t kind=jarbox_int_leaf_match(code,2,"()I",0,1,0);
        CHECK(kind==JARBOX_LEAF_CONST_M1+i-2);
        CHECK(jarbox_int_leaf_eval(kind,123,456)==i-3);
        CHECK(!!jarbox_int_leaf_match(code,2,"()Z",0,1,0)==(i==3||i==4));
    }
    uint8_t ops[]={0x60,0x64,0x68,0x7e,0x80,0x82};
    for(int i=0;i<6;i++){
        uint8_t code[]={0x1a,0x1b,ops[i],0xac};
        CHECK(jarbox_int_leaf_match(code,4,"(II)I",2,2,0)==JARBOX_LEAF_ADD+i);
        code[2]=0x6c;CHECK(!jarbox_int_leaf_match(code,4,"(II)I",2,2,0));
    }
    CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_ABS,INT32_MIN,0)==INT32_MIN);
    uint32_t x=1;
    for(int i=0;i<100000;i++){
        x=x*1664525u+1013904223u;uint32_t y=x*1103515245u+12345u;
        int32_t v=signed_bits(x),w=signed_bits(y);
        CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_ABS,v,w)==(v==INT32_MIN?v:v<0?-v:v));
        CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_IDENTITY,v,w)==v);
        CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_NEGATE,v,w)==signed_bits(0u-x));
        CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_ADD,v,w)==signed_bits(x+y));
        CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_SUB,v,w)==signed_bits(x-y));
        CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_MUL,v,w)==signed_bits(x*y));
        CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_AND,v,w)==signed_bits(x&y));
        CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_OR,v,w)==signed_bits(x|y));
        CHECK(jarbox_int_leaf_eval(JARBOX_LEAF_XOR,v,w)==signed_bits(x^y));
    }
    return 0;
}
"""
class IntLeafTest(unittest.TestCase):
    def test_patterns_and_java_int_arithmetic(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"leaf.c",Path(td)/"leaf"
            p.write_text(C)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-I",str(JVM),str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_classification_and_runtime_guards(self):
        source=(JVM/"class_load.c").read_text()
        block=source.split("ptr->converted_code = ca;",1)[1].split("_changeBytesOrder(ptr);",1)[0]
        self.assertIn("jarbox_int_leaf_match(",block)
        self.assertIn("ptr->is_static && !ptr->is_native && !ptr->is_sync",block)
        self.assertIn("ca->exception_table_length",block)
        interpreter=(JVM/"interpreter.c").read_text()
        fast=interpreter.split("const u8 int_leaf = method->treo_int_leaf_kind;",1)[1].split("// Retain game logic inside paint()",1)[0]
        for guard in ("CLASS_STATUS_CLINITED","!pruntime->jvm->jdwp_enable","!method->breakpoint",
                      "!pruntime->thrd_info->is_stop","!pruntime->thrd_info->suspend_count",
                      "!treo_game_jit_is_enabled()","leaf_code->max_stack <= caller->max_size - used",
                      "caller->sp = args;","push_int(caller, result);"):
            self.assertIn(guard,fast)
        self.assertIn("jarbox_int_leaf_pending == 64",fast)
if __name__=="__main__":
    unittest.main()
