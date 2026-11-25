"""Compare production mark traversal with a locked generic reference scan.

Use VM-layout doubles; test reachability, not iOS execution or GC scheduling.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
PRE=r"""
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
typedef void *__refer;
typedef int32_t s32;
typedef uint8_t u8;
typedef char c8;
enum {MEM_TYPE_INS=1,MEM_TYPE_ARR,MEM_TYPE_CLASS};
#define _JVM_DEBUG_GARBAGE_DUMP 0
#define GCFLAG_WEAKREFERENCE_GET(x) ((x)&1)
#define GCFLAG_JLOADER_GET(x) ((x)&2)
typedef struct JClass JClass;
typedef struct Instance Instance;
typedef struct {int type;u8 garbage_mark,gcflag,arr_type_index;JClass *clazz;} MemoryBlock;
typedef struct {void **data;int length;} ArrayList;
typedef struct {JClass *_this_class;int offset,is_ref_target;} FieldInfo;
struct JClass {MemoryBlock mb;ArrayList *insFieldPtrIndex,*staticFieldPtrIndex;char *field_static;Instance *ins_class,*jloader;JClass *super;};
struct Instance {MemoryBlock mb;int arr_length;char *arr_body,*obj_fields;};
typedef struct {ArrayList *classes;} PeerClassLoader;
typedef struct {PeerClassLoader *boot_classloader;} MiniJVM;
typedef struct {ArrayList *runtime_refer_copy,*objs_holder;MiniJVM *jvm;u8 mark_cnt;} GcCollector;
typedef struct {ArrayList *list;int i;} HashsetIterator,HashtableIterator;
typedef void *HashsetKey; typedef void *HashtableValue;
static void hashset_iterate(ArrayList *l,HashsetIterator *i){i->list=l;i->i=0;}
static int hashset_iter_has_more(HashsetIterator *i){return i->i<i->list->length;}
static void *hashset_iter_next_key(HashsetIterator *i){return i->list->data[i->i++];}
static void hashtable_iterate(ArrayList *l,HashtableIterator *i){hashset_iterate(l,i);}
static int hashtable_iter_has_more(HashtableIterator *i){return hashset_iter_has_more(i);}
static void *hashtable_iter_next_value(HashtableIterator *i){return hashset_iter_next_key(i);}
static JClass *getSuperClass(JClass *c){return c->super;}
static PeerClassLoader *loader;
static PeerClassLoader *classLoaders_find_by_instance(MiniJVM *j,Instance *i){(void)j;(void)i;return loader;}
static c8 *getInstanceFieldPtr(Instance *i,FieldInfo *f){return i->obj_fields+f->offset;}
static c8 *getStaticFieldPtr(FieldInfo *f){return f->_this_class->field_static+f->offset;}
static __refer getFieldRefer(c8 *p){return *(__refer *)p;}
static int isDataReferByIndex(int i){return i==1;}
static void _gc_mark_object(GcCollector *,__refer,u8);
"""
MAIN=r"""
#define CHECK(x) do{if(!(x)){fprintf(stderr,"failed line %d\n",__LINE__);return 1;}}while(0)
// Independent baseline traverses the same graph, including field-owner
// edges, weak reference exclusion, superclass and loader references.
static void old_mark(GcCollector *g,void *p,u8 mark){
    if(!p)return;
    MemoryBlock *mb=p;if(mb->garbage_mark==mark)return;mb->garbage_mark=mark;
    if(mb->type==MEM_TYPE_INS){
        Instance *in=p;
        for(JClass *cl=in->mb.clazz;cl;cl=cl->super){
            for(int i=0;i<cl->insFieldPtrIndex->length;i++){
                FieldInfo *f=cl->insFieldPtrIndex->data[i];
                if(f->is_ref_target&&(in->mb.gcflag&1))continue;
                old_mark(g,getFieldRefer(getInstanceFieldPtr(in,f)),mark);
                old_mark(g,f->_this_class,mark);
            }
            old_mark(g,cl,mark);
        }
        if((in->mb.gcflag&2)&&loader)
            for(int i=0;i<loader->classes->length;i++)old_mark(g,loader->classes->data[i],mark);
    }else if(mb->type==MEM_TYPE_ARR){
        Instance *in=p;if(in->mb.arr_type_index==1)
            for(int i=0;i<in->arr_length;i++)old_mark(g,((void**)in->arr_body)[i],mark);
    }else if(mb->type==MEM_TYPE_CLASS){
        JClass *cl=p;
        if(cl->field_static)for(int i=0;i<cl->staticFieldPtrIndex->length;i++){
            FieldInfo *f=cl->staticFieldPtrIndex->data[i];
            old_mark(g,getFieldRefer(getStaticFieldPtr(f)),mark);
        }
        old_mark(g,cl->ins_class,mark);old_mark(g,cl->jloader,mark);
    }
}
int main(void){
    ArrayList empty={0};
    JClass cl={.mb={.type=MEM_TYPE_CLASS},.insFieldPtrIndex=&empty,.staticFieldPtrIndex=&empty};
    JClass parent=cl,foreign=cl;
    cl.super=&parent;
    FieldInfo f0={&cl,0,0},f1={&cl,sizeof(void*),1},fp={&foreign,2*sizeof(void*),0};
    void *fl[]={&f0,&f1},*pl[]={&fp};ArrayList fields={fl,2},pf={pl,1};
    cl.insFieldPtrIndex=&fields;parent.insFieldPtrIndex=&pf;
    Instance o[12]={0};
    void *slots[12][3]={0},*refs[16]={0};
    for(int i=0;i<12;i++){o[i].mb.type=MEM_TYPE_INS;o[i].mb.clazz=&cl;o[i].obj_fields=(char*)slots[i];}
    o[0].mb.type=MEM_TYPE_ARR;o[0].mb.arr_type_index=1;o[0].arr_length=16;o[0].arr_body=(char*)refs;
    o[1].mb.gcflag=1;
    o[2].mb.gcflag=2;
    o[3].mb.type=MEM_TYPE_ARR;o[3].mb.arr_type_index=0;o[3].arr_length=16;o[3].arr_body=(char*)refs;
    void *rootdata[]={&o[0],&o[1],NULL,&o[3],&o[0]},*holddata[]={&o[2]},*bootdata[]={&parent},*lddata[]={&foreign};
    ArrayList roots={rootdata,5},holder={holddata,1},boot={bootdata,1},ld={lddata,1};
    PeerClassLoader bl={&boot},dl={&ld};loader=&dl;
    MiniJVM j={&bl};GcCollector g={&roots,&holder,&j,1};
    MemoryBlock *all[15];for(int i=0;i<12;i++)all[i]=&o[i].mb;all[12]=&cl.mb;all[13]=&parent.mb;all[14]=&foreign.mb;
    uint32_t seed=7;
    for(int round=0;round<10000;round++){
        for(int i=0;i<12;i++)for(int k=0;k<3;k++){
            seed=seed*1664525u+1013904223u;unsigned n=(seed>>16)%16;
            slots[i][k]=n<12?&o[n]:NULL;
        }
        for(int i=0;i<16;i++){seed=seed*1664525u+1013904223u;unsigned n=(seed>>16)%16;refs[i]=n<12?&o[n]:NULL;}
        for(int i=0;i<15;i++)all[i]->garbage_mark=0;
        for(int i=0;i<roots.length;i++)old_mark(&g,roots.data[i],1);
        for(int i=0;i<holder.length;i++)old_mark(&g,holder.data[i],1);
        for(int i=0;i<boot.length;i++)old_mark(&g,boot.data[i],1);
        u8 expected[15];for(int i=0;i<15;i++){expected[i]=all[i]->garbage_mark;all[i]->garbage_mark=0;}
        _gc_big_search(&g);
        for(int i=0;i<15;i++)CHECK(expected[i]==all[i]->garbage_mark);
    }
    // Empty array and empty root list require no dereference.
    gc_mark_refs(&g,NULL,0,2);
    // Isolated weak edge must not retain target.
    for(int i=0;i<15;i++)all[i]->garbage_mark=0;
    memset(slots,0,sizeof(slots));slots[1][1]=&o[11];
    _gc_mark_object(&g,&o[1],1);CHECK(o[11].mb.garbage_mark==0);
    puts("GC mark reachability: 10000 graphs PASS");return 0;
}
"""
class GCMarkScanTest(unittest.TestCase):
    def test_reachability(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        s=(JVM/"garbage.c").read_text()
        a=s.index("static inline void gc_mark_refs(")
        b=s.index("// Registered shutdown hooks",a)
        c=s.index("static inline void _gc_instance_mark(")
        d=s.index("//=================================  reg unreg",c)
        flags=["-std=c11","-O2","-Wall","-Wextra","-Werror"]
        if os.environ.get("JARBOX_GC_SCAN_SANITIZE")=="1":
            flags+=["-fsanitize=address,undefined","-fno-omit-frame-pointer"]
        with tempfile.TemporaryDirectory() as td:
            src,exe=Path(td)/"test.c",Path(td)/"test"
            src.write_text(PRE+s[a:b]+s[c:d]+MAIN)
            subprocess.run([cc,*flags,str(src),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=15)
    def test_owner_and_scan_wiring(self):
        s=(JVM/"garbage.c").read_text()
        mark=s.split("s32 _gc_big_search(GcCollector *collector) {",1)[1].split("// Registered shutdown hooks",1)[0]
        self.assertIn("gc_mark_refs(collector, roots->data, roots->length",mark)
        self.assertNotIn("arraylist_get_value(",mark)
        arr=s.split("static inline void _gc_jarray_mark(",1)[1].split("static inline void _gc_class_mark(",1)[0]
        self.assertIn("isDataReferByIndex(arr->mb.arr_type_index)",arr)
        self.assertNotIn("jarray_get_field(",arr)
        self.assertIn("if (fi->_this_class != clazz)",s)
        self.assertIn("GCFLAG_WEAKREFERENCE_GET(ins->mb.gcflag)",s)
        worker=s.split("s32 _gc_thread_run(void *para) {",1)[1].split("static void gc_process_deferred_objects",1)[0]
        self.assertIn("gc_worker_cpu_ns",worker)
        self.assertEqual(worker.count("treo_gc_smart_thread_cpu()"),2)
if __name__=="__main__":unittest.main()
