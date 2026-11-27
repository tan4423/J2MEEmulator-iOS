"""Compile the production read-only binding predicate against modeled layouts.

This exercises ancestry/identity/field rejection, not actual iOS rendering,
classfile authorization, VM execution or concurrent scope stability.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
CODE=r"""
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef struct JClass JClass;
typedef struct Instance Instance;
typedef struct FieldInfo FieldInfo;
typedef struct {void *rvalue;int64_t value;} StackEntry;
typedef struct {StackEntry *store,*sp;} RuntimeStack;
typedef struct {unsigned char *code;int code_length;} CodeAttribute;
typedef struct {int is_native,is_static;JClass *_this_class;const char *name,*descriptor;CodeAttribute *converted_code;} MethodInfo;
struct FieldInfo {
    const char *name,*descriptor;JClass *_this_class;
    unsigned access_flags,offset,offset_instance,isvolatile,isrefer;
};
struct JClass {
    const char *name;void *jloader;JClass *superclass;
    int status,field_instance_len,field_static_len;unsigned char *field_static;
    struct {int field_used;FieldInfo *field;} fieldPool;
    struct {unsigned access_flags;} cff;
};
struct Instance {struct {int type;JClass *clazz;} mb;unsigned char *obj_fields;};
typedef struct Runtime Runtime;
struct Runtime {
    void *jvm,*thrd_info;RuntimeStack *stack;StackEntry *localvar;int localvar_slots;
    MethodInfo *method;unsigned char *pc;Runtime *parent;
};
enum {MEM_TYPE_INS=2,CLASS_STATUS_CLINITED=5};
static int utf8_equals_c(const char *a,const char *b){return !strcmp(a,b);}
#include "jarbox_residual_binding.h"
static void field(FieldInfo *f,JClass *owner,const char *name,const char *desc,unsigned off,int ref,int stat){
    *f=(FieldInfo){name,desc,owner,stat?8u:0u,off,off,0,(unsigned)ref};
}
static void putref(unsigned char *p,Instance *o){memcpy(p,&o,sizeof(o));}
static void putlong(unsigned char *p,int64_t v){memcpy(p,&v,sizeof(v));}
int main(void) {
    int game_loader,api_loader,vm,thread,foreign;
    unsigned char cb[80]={0},db[80]={0},wb[80]={0},gb[80]={0},cs[16]={0},code[80]={0};
    JClass cl[7]={0};
    const char *names[]={"Class_hii","Class_hmi","Class_hxb","Class_hef","Class_hvi","javax/microedition/lcdui/Canvas","javax/microedition/lcdui/Graphics"};
    for(unsigned i=0;i<7;i++) {
        cl[i].name=names[i];cl[i].jloader=i<5?(void*)&game_loader:(void*)&api_loader;
        cl[i].status=CLASS_STATUS_CLINITED;cl[i].field_instance_len=80;cl[i].cff.access_flags=16;
    }
    cl[3].superclass=&cl[5];cl[3].field_static=cs;cl[3].field_static_len=sizeof(cs);
    FieldInfo df[1],cf[2],wf[1],af[3],gf[4];
    field(df,&cl[2],"c3","LClass_hvi;",0,1,0);
    field(cf,&cl[3],"b","LClass_bs;",32,1,0);
    field(cf+1,&cl[3],"g","LClass_hef;",0,1,1);
    field(wf,&cl[4],"a","Ljavax/microedition/lcdui/Graphics;",0,1,0);
    field(af,&cl[5],"graphics","Ljavax/microedition/lcdui/Graphics;",0,1,0);
    field(af+1,&cl[5],"nativeContext","J",8,0,0);
    field(af+2,&cl[5],"treoUsesExplicitBuffer","Z",16,0,0);
    field(gf,&cl[6],"nativeContext","J",0,0,0);
    field(gf+1,&cl[6],"ownsContext","Z",8,0,0);
    field(gf+2,&cl[6],"treoPixelDependent","Z",9,0,0);
    field(gf+3,&cl[6],"headless","Z",10,0,0);
    cl[2].fieldPool.field=df;cl[2].fieldPool.field_used=1;
    cl[3].fieldPool.field=cf;cl[3].fieldPool.field_used=2;
    cl[4].fieldPool.field=wf;cl[4].fieldPool.field_used=1;
    cl[5].fieldPool.field=af;cl[5].fieldPool.field_used=3;
    cl[6].fieldPool.field=gf;cl[6].fieldPool.field_used=4;
    Instance c={{MEM_TYPE_INS,&cl[3]},cb},d={{MEM_TYPE_INS,&cl[2]},db},w={{MEM_TYPE_INS,&cl[4]},wb},g={{MEM_TYPE_INS,&cl[6]},gb};
    Instance off=g,other=w;
    putref(db,&w);putref(cb+32,&d);putref(cs,&c);putref(wb,&g);putref(cb,&g);
    putlong(cb+8,12345);putlong(gb,12345);
    CodeAttribute ca={code,sizeof(code)};
    MethodInfo m[]={
        {0,1,&cl[0],"k1","(LClass_hvi;)V",&ca},
        {0,1,&cl[1],"m","(LClass_hvi;)V",&ca},
        {0,0,&cl[2],"a","(Ljavax/microedition/lcdui/Graphics;)V",&ca},
        {0,0,&cl[3],"paint","(Ljavax/microedition/lcdui/Graphics;)V",&ca},
        {0,0,&cl[5],"doPaint","()V",&ca}
    };
    StackEntry slots[16]={0};RuntimeStack stack={slots,slots+16};Runtime r[5]={0};
    for(unsigned i=0;i<5;i++)r[i]=(Runtime){&vm,&thread,&stack,slots+3*i,3,m+i,code,i<4?r+i+1:NULL};
    r[1].pc=code+58;r[2].pc=code+30;r[3].pc=code+5;
    r[1].localvar[0].rvalue=&w;
    r[2].localvar[0].rvalue=&d;r[2].localvar[1].rvalue=&g;
    r[3].localvar[0].rvalue=&c;r[3].localvar[1].rvalue=&g;
    r[4].localvar[0].rvalue=&c;
    JarBoxResidualBinding b;
    #define GOOD() do{assert(jbr_nick_binding(r,&w,&b));assert(b.wrapper==&w&&b.canvas==&c&&b.graphics==&g&&b.context==12345);}while(0)
    #define BAD() do{assert(!jbr_nick_binding(r,&w,&b));assert(!b.wrapper&&!b.context);}while(0)
    GOOD();
    for(int i=0;i<10000;i++){
        r[2].jvm=&foreign;BAD();r[2].jvm=&vm;
        r[3].thrd_info=&foreign;BAD();r[3].thrd_info=&thread;
        r[1].pc=code+57;BAD();r[1].pc=code+58;
        r[2].pc=code+29;BAD();r[2].pc=code+30;
        r[3].pc=code+4;BAD();r[3].pc=code+5;
        r[2].localvar_slots=1;BAD();r[2].localvar_slots=3;
        putref(db,&other);BAD();putref(db,&w);
        putref(wb,&off);BAD();putref(wb,&g);
        putref(cb,&off);BAD();putref(cb,&g);
        putref(cs,NULL);BAD();putref(cs,&c);
        putref(cb+32,NULL);BAD();putref(cb+32,&d);
        for(int k=8;k<=10;k++){gb[k]=1;BAD();gb[k]=0;}
        cb[16]=1;BAD();cb[16]=0;
        putlong(gb,54321);BAD();putlong(gb,12345);
        wf[0].isvolatile=1;BAD();wf[0].isvolatile=0;
        wf[0].offset_instance=79;BAD();wf[0].offset_instance=0;
        cl[4].jloader=&api_loader;BAD();cl[4].jloader=&game_loader;
        cl[3].cff.access_flags=0;BAD();cl[3].cff.access_flags=16;
        r[4].method=&m[3];BAD();r[4].method=&m[4];
        GOOD();
    }
    JarBoxResidualScope a={1,7,12345,(uintptr_t)&w,(uintptr_t)&c,(uintptr_t)&g},z=a;
    assert(jbr_scope_same(&a,&z));z.owner++;assert(!jbr_scope_same(&a,&z));z=a;
    z.serial++;assert(!jbr_scope_same(&a,&z));z=a;z.graphics=(uintptr_t)&off;assert(!jbr_scope_same(&a,&z));z=a;
    z.context++;assert(!jbr_scope_same(&a,&z));z=a;z.canvas=0;assert(!jbr_scope_same(&a,&z));
    assert(!jbr_scope_same(&a,NULL));
    puts("residual binding: 10000 valid/invalid batches PASS");
}
"""

class BindingTest(unittest.TestCase):
    def test_binding_and_scope(self):
        cc=shutil.which(os.environ.get("CC","cc"))
        if not cc:self.skipTest("C compiler missing")
        with tempfile.TemporaryDirectory() as td:
            p=Path(td);(p/"test.c").write_text(CODE)
            exe=p/"test"
            flags=["-std=c11","-O2","-Wall","-Wextra","-Werror"]
            if os.environ.get("JARBOX_RESIDUAL_SANITIZE")=="1":
                flags+=["-g","-O1","-fsanitize=address,undefined","-fno-omit-frame-pointer","-fno-pie","-no-pie"]
            subprocess.run([cc,*flags,"-I",str(JVM),str(p/"test.c"),"-o",str(exe)],check=True,timeout=30)
            r=subprocess.run([str(exe)],capture_output=True,text=True,timeout=30,
                env={**os.environ,"ASAN_OPTIONS":"halt_on_error=1","UBSAN_OPTIONS":"halt_on_error=1"})
            self.assertEqual(r.returncode,0,r.stdout+r.stderr)
            self.assertIn("10000 valid/invalid batches PASS",r.stdout)
if __name__=="__main__":unittest.main()
