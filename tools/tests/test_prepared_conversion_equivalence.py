"""Compare real cold and cached _changeBytesOrder with private output buffers.

Extract the production converter and opcode enum, using small platform/VM
doubles only. This tests conversion equivalence, not execution of a MIDlet.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"

PRE = r"""
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
typedef uint8_t u8;
typedef uint16_t u16;
typedef uint64_t u64;
typedef int16_t s16;
typedef int32_t s32;
typedef union { s16 s; u16 us; struct { u8 c0,c1; }; } Short2Char;
typedef union { s32 i; struct { u8 c0,c1,c2,c3; }; } Int2Float;
typedef struct { intptr_t leftl,rightl; } Pair;
typedef struct { Pair *ptr; s32 count,_alloced; } Pairlist;
static Pairlist *pairlist_create(s32 n) {
    Pairlist *p=calloc(1,sizeof(*p));
    if (!p) return NULL;
    p->ptr=calloc((size_t)n,sizeof(Pair));
    if (!p->ptr) { free(p); return NULL; }
    p->_alloced=n;
    return p;
}
static void pairlist_destroy(Pairlist *p) { if(p){free(p->ptr);free(p);} }
static s32 pairlist_putl(Pairlist *p,intptr_t l,intptr_t r) {
    if (!p) return -1;
    for (s32 i=0;i<p->count;i++) if (p->ptr[i].leftl==l) { p->ptr[i].rightl=r;return 1; }
    if(p->count==p->_alloced) {
        s32 n=p->_alloced*2;
        Pair *q=realloc(p->ptr,(size_t)n*sizeof(Pair));
        if(!q)return -1;
        p->ptr=q;p->_alloced=n;
    }
    p->ptr[p->count++]=(Pair){l,r};return 0;
}
typedef struct {u8 *code,*bytecode_for_jit;s32 code_length;int compile_lock;} CodeAttribute;
typedef struct {
    Pairlist *pos_2_label,*jump_2_pos;
    CodeAttribute *converted_code;
    int para_count_with_this,is_getter,is_setter;
} MethodInfo;
#define spin_init(lock,value) (*(lock)=(value))
#define jvm_printf(...) fprintf(stderr,__VA_ARGS__)
#include "jarbox_prepared_code_cache.h"
typedef struct {uint64_t candidates,hits,hit_bytes;} JarBoxPreparedProfile;
static _Thread_local JarBoxPreparedProfile *jarbox_prepared_profile;
"""
MAIN = r"""
#define CHECK(c) do {if(!(c)){fprintf(stderr,"failed line %d\n",__LINE__);return 1;}}while(0)
static void be32(u8 *p,s32 n) {
    uint32_t x=(uint32_t)n;
    p[0]=x>>24;p[1]=x>>16;p[2]=x>>8;p[3]=x;
}
static s32 native32(const u8 *p) {s32 x;memcpy(&x,p,4);return x;}
static u16 native16(const u8 *p) {u16 x;memcpy(&x,p,2);return x;}
int main(void) {
    u8 raw[256]={0},a[256],b[256],c[256],aj[256]={0},bj[256]={0},cj[256]={0};
    raw[0]=op_sipush;raw[1]=0x12;raw[2]=0x34;
    raw[3]=op_goto;raw[4]=0;raw[5]=125;
    raw[6]=op_ifeq;raw[7]=255;raw[8]=250;
    raw[9]=op_ldc_w;raw[10]=0;raw[11]=1;
    raw[12]=op_wide;raw[13]=op_iinc;raw[14]=1;raw[15]=2;raw[16]=255;raw[17]=254;
    raw[20]=op_tableswitch;
    be32(raw+24,100);be32(raw+28,0);be32(raw+32,1);
    be32(raw+36,108);be32(raw+40,112);
    raw[44]=op_lookupswitch;
    be32(raw+48,76);be32(raw+52,2);
    be32(raw+56,-10);be32(raw+60,84);be32(raw+64,10);be32(raw+68,88);
    raw[72]=op_goto_w;be32(raw+73,56);
    raw[255]=op_return;
    memcpy(a,raw,sizeof(raw));memcpy(b,raw,sizeof(raw));memcpy(c,raw,sizeof(raw));
    CodeAttribute ca={a,aj,256,0},cb={b,bj,256,0},cc={c,cj,256,0};
    MethodInfo ma={.converted_code=&ca},mb={.converted_code=&cb},mc={.converted_code=&cc};
    JarBoxPreparedProfile pa={0},pb={0},pc={0};
    jarbox_prepared_profile=&pa;_changeBytesOrder(&ma);
    CHECK(pa.candidates==1 && pa.hits==0 && jarbox_prepared_count==1);
    CHECK(native16(a+1)==0x1234 && native16(a+14)==0x0102 && native16(a+16)==0xfffe);
    CHECK(native32(a+24)==100 && native32(a+56)==-10 && native32(a+73)==56);
    jarbox_prepared_profile=&pb;_changeBytesOrder(&mb);
    CHECK(pb.candidates==1 && pb.hits==1 && pb.hit_bytes==256);
    CHECK(!memcmp(a,b,256) && !memcmp(aj,bj,256) && !memcmp(a,aj,256));
    CHECK(ma.pos_2_label!=mb.pos_2_label && ma.pos_2_label->ptr!=mb.pos_2_label->ptr);
    CHECK(ma.pos_2_label->count==mb.pos_2_label->count && ma.pos_2_label->count>4);
    for(s32 i=0;i<ma.pos_2_label->count;i++) {
        CHECK(ma.pos_2_label->ptr[i].leftl==mb.pos_2_label->ptr[i].leftl);
        CHECK(ma.pos_2_label->ptr[i].rightl==-1 && mb.pos_2_label->ptr[i].rightl==-1);
    }
    // Simulate execution/quickening and label updates in one VM.
    b[0]=op_nop;mb.pos_2_label->ptr[0].rightl=123;
    CHECK(a[0]==op_sipush && ma.pos_2_label->ptr[0].rightl==-1);
    jarbox_prepared_trim();CHECK(!jarbox_prepared_count);
    jarbox_prepared_profile=&pc;_changeBytesOrder(&mc);
    CHECK(pc.candidates==1 && pc.hits==0 && !memcmp(c,a,256));
    CHECK(!memcmp(cj,aj,256) && b[0]==op_nop);
    jarbox_prepared_profile=NULL;jarbox_prepared_trim();
    pairlist_destroy(ma.pos_2_label);pairlist_destroy(ma.jump_2_pos);
    pairlist_destroy(mb.pos_2_label);pairlist_destroy(mb.jump_2_pos);
    pairlist_destroy(mc.pos_2_label);pairlist_destroy(mc.jump_2_pos);
    return 0;
}
"""

class PreparedConversionEquivalenceTest(unittest.TestCase):
    def test_cold_and_hit_produce_same_private_code_and_labels(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host compiler unavailable")
        header=(JVM/"jvm.h").read_text()
        first=header.index("/* 0x00 */ op_nop")
        enum=header[header.rfind("enum {",0,first):header.index("};",first)+2]
        source=(JVM/"class_load.c").read_text()
        start=source.index("void _changeBytesOrder(MethodInfo *method) {")
        end=source.index("s32 _convert_to_code_attribute(",start)
        with tempfile.TemporaryDirectory() as td:
            c,exe=Path(td)/"convert.c",Path(td)/"convert"
            c.write_text(PRE+"\n"+enum+"\n"+source[start:end]+MAIN)
            subprocess.run([cc,"-std=c11","-O2","-pthread","-I",str(JVM),str(c),"-o",str(exe)],
                           check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)

if __name__=="__main__":
    unittest.main()
