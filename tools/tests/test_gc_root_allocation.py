"""Inject allocation failures into GC root copy; production bodies, modeled heap."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
UTIL=JVM.parent/"utils"
PRE=r"""
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef int s32;
typedef void *ArrayListValue;
typedef struct {int length,spinlock; void *items[32];} ArrayList;
typedef struct MemoryBlock {struct MemoryBlock *hold_next;} MemoryBlock;
typedef struct {void *rvalue;} StackEntry;
typedef struct {StackEntry *store,*sp,*gc_clean; int max_size;} RuntimeStack;
typedef struct {void *jthread; MemoryBlock *tmp_holder; int thread_status;} Info;
typedef struct {ArrayList *runtime_refer_copy;} GcCollector;
typedef struct MiniJVM MiniJVM;
typedef struct {MiniJVM *jvm; Info *thrd_info; RuntimeStack *stack;} Runtime;
struct MiniJVM {GcCollector *collector; ArrayList *shutdown_hook,*thread_list; int jdwp_enable; Runtime *jdwpserver;};
enum {THREAD_STATUS_ZOMBIE=2};
static int fail_after;
static void spin_lock(int *l){assert(!*l);*l=1;}
static void spin_unlock(int *l){assert(*l);*l=0;}
static void *arraylist_get_value_unsafe(ArrayList *l,int i){return l->items[i];}
static void arraylist_clear(ArrayList *l){l->length=0;}
static int arraylist_push_back_unsafe(ArrayList *l,void *v){
    if(fail_after==0)return 0;
    if(fail_after>0)--fail_after;
    assert(l->length<32); l->items[l->length++]=v;return 1;
}
static int stack_size(RuntimeStack *s){return (int)(s->sp-s->store);}
static Runtime *jdwp_get_runtime(Runtime *r){return r;}
static s32 _gc_copy_objs_from_thread(Runtime *r);
"""
MAIN=r"""
int main(void){
    int hook=1,thread=2,ref=3;
    MemoryBlock b={0},a={&b};
    StackEntry slots[4]={{&ref},{0},{&ref},{0}};
    RuntimeStack stack={slots,slots+2,NULL,4};
    Info info={&thread,&a,0},dead={0,0,THREAD_STATUS_ZOMBIE};
    ArrayList roots={0},hooks={.length=1,.items={&hook}},list={0};
    GcCollector gc={&roots};
    MiniJVM vm={&gc,&hooks,&list,0,NULL};
    Runtime live={&vm,&info,&stack},zombie={&vm,&dead,NULL};
    list.items[0]=&live;list.items[1]=&zombie;list.length=2;
    for(int i=0;i<10000;++i){
        for(int failure=0;failure<5;++failure){
            fail_after=failure;
            assert(_gc_copy_objs(&vm)==-1);
            assert(!hooks.spinlock && !list.spinlock);
        }
        fail_after=-1;
        assert(_gc_copy_objs(&vm)==0 && roots.length==5);
        assert(roots.items[0]==&hook && roots.items[1]==&thread &&
               roots.items[2]==&ref && roots.items[3]==&a && roots.items[4]==&b);
        assert(!hooks.spinlock && !list.spinlock);
    }
    puts("50000 injected root failures; 10000 successful snapshots: PASS");
}
"""
def extract(s,sig):
    i=s.index(sig)
    return s[i:s.index("\n}",i)+2]
class RootAllocationTest(unittest.TestCase):
    def test_each_root_failure(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        s=(JVM/"garbage.c").read_text()
        code=PRE+"\n"+ "\n".join(extract(s,x) for x in ("static s32 gc_copy_shutdown_hook_roots(MiniJVM *jvm) {","s32 _gc_copy_objs(MiniJVM *jvm) {","s32 _gc_copy_objs_from_thread(Runtime *pruntime) {"))+MAIN
        with tempfile.TemporaryDirectory() as d:
            p,exe=Path(d)/"root.c",Path(d)/"root"
            p.write_text(code)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror",str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=15)
    def test_abort_before_mark(self):
        s=(JVM/"garbage.c").read_text()
        body=extract(s,"s64 _garbage_collect(GcCollector *collector) {")
        abort=body.split("if (_gc_copy_objs(jvm) != 0) {",1)[1].split("return -1;",1)[0]
        for expr in ("arraylist_clear(","collector->isworldstoped = 0","_gc_resume_the_world(jvm)","collector->isgc = 0","vm_share_unlock(jvm)"):
            self.assertIn(expr,abort)
        self.assertLess(body.index("if (_gc_copy_objs(jvm) != 0)"),body.index("collector->mark_cnt++"))
        self.assertLess(body.index("if (_gc_copy_objs(jvm) != 0)"),body.index("memoryblock_destroy(curmb)"))
        self.assertIn("if (result < 0) threadSleep(100);",s)
if __name__=="__main__":unittest.main()
