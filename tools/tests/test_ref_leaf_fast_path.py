"""Static reference leaf shape and runtime guard regression."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
C=r"""
#include <stdio.h>
#include "jarbox_ref_leaf.h"
#define CHECK(x) do {if(!(x)){fprintf(stderr,"line %d\n",__LINE__);return 1;}}while(0)
int main(void){
    uint8_t a[]={0xb2,0,53,0xc7,0,13,0xbb,0,24,0x59,0xb7,0,79,0xb3,0,53,0xb2,0,53,0xb0};
    uint8_t b[]={0xb2,0,32,0xc7,0,15,0xbb,0,7,0x59,0xb7,0,52,0x59,0xb3,0,32,0xb0,0xb2,0,32,0xb0};
    uint8_t c[]={0xb2,0,44,0xc7,0,17,0xbb,0,2,0x59,0xb7,0,45,0x59,0xb3,0,44,0xa7,0,6,0xb2,0,44,0xb0};
    uint8_t d[]={0xb2,1,2,0xb0};
    CHECK(jarbox_ref_leaf_match(d,4,"()Ljava/lang/Object;",0,1,0)==258);
    CHECK(jarbox_ref_leaf_match(d,4,"()[I",0,1,0)==258);
    uint8_t *v[]={a,b,c};int lengths[]={20,22,24};
    for(int i=0;i<3;i++){
        uint8_t *p=v[i];int n=lengths[i];uint32_t expected=0x10000u|p[2];
        CHECK(jarbox_ref_leaf_match(p,n,"()Lx;",0,2,0)==expected);
        CHECK(!jarbox_ref_leaf_match(p,n,"()I",0,2,0));
        CHECK(!jarbox_ref_leaf_match(p,n,"(I)Lx;",0,2,0));
        CHECK(!jarbox_ref_leaf_match(p,n,"()Lx;",1,2,0));
        CHECK(!jarbox_ref_leaf_match(p,n,"()Lx;",0,1,0));
        CHECK(!jarbox_ref_leaf_match(p,n,"()Lx;",0,2,1));
        for(int j=0;j<n;j++){
            if(j==7||j==8||j==11||j==12)continue;
            p[j]^=1;CHECK(!jarbox_ref_leaf_match(p,n,"()Lx;",0,2,0));p[j]^=1;
        }
        for(int j=0;j<n;j++)CHECK(!jarbox_ref_leaf_match(p,j,"()Lx;",0,2,0));
    }
    return 0;
}
"""

RUNTIME_PRE=r"""
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
typedef uint32_t u32; typedef uint16_t u16; typedef int32_t s32; typedef char c8; typedef void *__refer;
enum {CONSTANT_FIELD_REF=9, ACC_STATIC=8, ACC_VOLATILE=64};
typedef struct {int tag;} ConstantItem;
typedef struct {int constant_item_count; ConstantItem **constant_item_ptr; char *field_static; int field_static_len;} JClass;
typedef struct {JClass *_this_class; int access_flags,isrefer,isvolatile,offset;} FieldInfo;
typedef struct {ConstantItem item; FieldInfo *fieldInfo;} ConstantFieldRef;
typedef struct {int max_stack;} CodeAttribute;
typedef struct {u32 treo_ref_leaf; JClass *_this_class; CodeAttribute *converted_code;} MethodInfo;
typedef struct {__refer *store,*sp; int max_size;} RuntimeStack;
typedef struct {RuntimeStack *stack;} Runtime;
static ConstantItem *class_get_constant_item(JClass *cl,int cp){return cl->constant_item_ptr[cp];}
static c8 *getStaticFieldPtr(FieldInfo *fi){return fi->_this_class->field_static+fi->offset;}
static void push_ref(RuntimeStack *s,__refer v){*s->sp++=v;}
"""
RUNTIME_MAIN=r"""
#define CHECK(x) do{if(!(x)){fprintf(stderr,"line %d\n",__LINE__);return 1;}}while(0)
int main(void){
 int objects[2]={1,2}; __refer a=NULL,b=&objects[1];
 ConstantItem *acp[2]={0},*bcp[2]={0};
 JClass ca={2,acp,(char*)&a,sizeof(a)},cb={2,bcp,(char*)&b,sizeof(b)};
 FieldInfo fa={&ca,ACC_STATIC,1,0,0},fb={&cb,ACC_STATIC,1,0,0};
 ConstantFieldRef ra={{CONSTANT_FIELD_REF},&fa},rb={{CONSTANT_FIELD_REF},&fb};acp[1]=&ra.item;bcp[1]=&rb.item;
 CodeAttribute code={2};MethodInfo ma={0x10001,&ca,&code},mb={0x10001,&cb,&code};
 __refer data[4]={0};RuntimeStack st={data,data,4};Runtime r={&st};
 CHECK(!jarbox_try_ref_leaf(&ma,&r)&&st.sp==data);
 for(int i=0;i<100000;i++){a=&objects[i&1];CHECK(jarbox_try_ref_leaf(&ma,&r)&&data[0]==a);st.sp=data;CHECK(jarbox_try_ref_leaf(&mb,&r)&&data[0]==b);st.sp=data;}
 a=NULL;ma.treo_ref_leaf=1;CHECK(jarbox_try_ref_leaf(&ma,&r)&&data[0]==NULL);st.sp=data;
 ma.treo_ref_leaf=0x10001;a=&objects[0];
 fa.isvolatile=1;CHECK(!jarbox_try_ref_leaf(&ma,&r));fa.isvolatile=0;
 fa.access_flags=ACC_STATIC|ACC_VOLATILE;CHECK(!jarbox_try_ref_leaf(&ma,&r));fa.access_flags=ACC_STATIC;
 fa.access_flags=0;CHECK(!jarbox_try_ref_leaf(&ma,&r));fa.access_flags=ACC_STATIC;
 fa.isrefer=0;CHECK(!jarbox_try_ref_leaf(&ma,&r));fa.isrefer=1;
 ra.fieldInfo=&fb;CHECK(!jarbox_try_ref_leaf(&ma,&r));ra.fieldInfo=NULL;CHECK(!jarbox_try_ref_leaf(&ma,&r));ra.fieldInfo=&fa;
 ra.item.tag=0;CHECK(!jarbox_try_ref_leaf(&ma,&r));ra.item.tag=CONSTANT_FIELD_REF;
 ca.field_static_len=1;CHECK(!jarbox_try_ref_leaf(&ma,&r));ca.field_static_len=sizeof(a);
 fa.offset=1;CHECK(!jarbox_try_ref_leaf(&ma,&r));fa.offset=0;
 ma.treo_ref_leaf=0x10002;CHECK(!jarbox_try_ref_leaf(&ma,&r));ma.treo_ref_leaf=0x10001;
 st.sp=data+3;CHECK(!jarbox_try_ref_leaf(&ma,&r)&&st.sp==data+3);
 return 0;
}
"""

class RefLeafTest(unittest.TestCase):
    def test_live_field_and_fallback(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        s=(JVM/"interpreter.c").read_text()
        a=s.index("static inline int jarbox_try_ref_leaf(")
        b=s.index("\n}\n",a)+3
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"runtime.c",Path(td)/"runtime"
            p.write_text(RUNTIME_PRE+s[a:b]+RUNTIME_MAIN)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror",str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)

    def test_shape(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"test.c",Path(td)/"test"
            p.write_text(C)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-I",str(JVM),str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_runtime_guards(self):
        s=(JVM/"interpreter.c").read_text()
        body=s.split("static inline int jarbox_try_ref_leaf(",1)[1].split("\n}\n",1)[0]
        for guard in ("cp >= cl->constant_item_count","item->tag != CONSTANT_FIELD_REF",
                      "fi->_this_class != cl","ACC_STATIC","fi->isvolatile","ACC_VOLATILE",
                      "field_static_len","_Alignof(__refer)","ca->max_stack > stack->max_size - used",
                      "if (!value) return 0;","push_ref(stack, value);"):
            self.assertIn(guard,body)
        self.assertEqual(body.count("__atomic_load_n((__refer *)address, __ATOMIC_RELAXED)"),2)
        self.assertIn("!treo_game_jit_enabled_fast() && jarbox_try_ref_leaf(method, pruntime)",s)
        self.assertIn("jarbox_ref_leaf_pending == 64",s)
        cl=(JVM/"class_load.c").read_text()
        self.assertIn("ptr->treo_ref_leaf = jarbox_ref_leaf_match(",cl)
if __name__=="__main__":unittest.main()
