"""Test the extracted deferred-object GC helper; Java callbacks and heap are modeled."""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

JVM = Path(__file__).resolve().parents[2] / "J2MEEmulator/minijvm/jvm"
PRELUDE = r'''
#include <assert.h>
#include <stdio.h>
#include <stddef.h>
#include <stdlib.h>
enum { GARBAGE_THREAD_NORMAL, GARBAGE_THREAD_PAUSE, GARBAGE_THREAD_STOP, GARBAGE_THREAD_DEAD };
#define MEM_TYPE_INS 1
#define GCFLAG_FINALIZED_GET(x) ((x)&0x40)
#define GCFLAG_FINALIZED_SET(x) ((x)|=0x40)
#define GCFLAG_WEAKREFERENCE_GET(x) ((x)&0x20)
typedef struct { int finalizeMethod; } JClass;
typedef struct MemoryBlock { struct MemoryBlock *next,*tmp_next; JClass *clazz; int type,garbage_mark,gcflag; } MemoryBlock;
typedef struct Instance { MemoryBlock mb; struct Instance *target; int final,weak,marks; } Instance;
typedef struct { struct { int reference_target; } shortcut; } MiniJVM;
typedef struct GcCollector { MiniJVM *jvm; MemoryBlock *header; struct GcCollector *runtime; int mark_cnt,status,stop_on_final,stop_on_weak; } GcCollector;
static int gc_thread_status(GcCollector *c){return c->status;}
static void instance_finalize(Instance *i,GcCollector *c){i->final++;if(c->stop_on_final)c->status=GARBAGE_THREAD_STOP;}
static void instance_of_reference_enqueue(Instance *i,GcCollector *c){i->weak++;if(c->stop_on_weak)c->status=GARBAGE_THREAD_STOP;}
static Instance **getInstanceFieldPtr(Instance *i,int field){(void)field;return &i->target;}
static Instance *getFieldRefer(Instance **p){return *p;}
static void _gc_mark_object(GcCollector *c,MemoryBlock *m,int mark){(void)c;Instance *i=(Instance *)m;assert(++i->marks==1);m->garbage_mark=mark;}
'''
MAIN = r'''
int main(void){
    JClass yes={1},no={0}; MiniJVM vm={0},other_vm={0};
    for(int n=0;n<10000;n++){
        int mode=n%8;
        Instance target={.mb={.clazz=&no,.type=MEM_TYPE_INS}};
        Instance b={.mb={.clazz=&yes,.type=MEM_TYPE_INS,.gcflag=0x20},.target=&target};
        Instance a={.mb={.next=&b.mb,.clazz=&yes,.type=MEM_TYPE_INS,.gcflag=0x20},.target=&target};
        Instance other={.mb={.clazz=&yes,.type=MEM_TYPE_INS}};
        GcCollector c={.jvm=&vm,.header=&a.mb,.mark_cnt=7};c.runtime=&c;
        GcCollector d={.jvm=&other_vm,.header=&other.mb,.mark_cnt=9};d.runtime=&d;
        if(mode==1)c.stop_on_final=1;
        if(mode==2)c.stop_on_weak=1;
        if(mode==3)c.status=GARBAGE_THREAD_STOP;
        if(mode==4)c.status=GARBAGE_THREAD_PAUSE;
        if(mode==5)a.mb.gcflag|=0x40;
        if(mode==6)target.mb.garbage_mark=7;
        if(mode==7)a.mb.garbage_mark=7;
        gc_process_deferred_objects(&c);
        assert(!a.mb.tmp_next && !b.mb.tmp_next);
        if(mode==3||mode==4){assert(!a.final&&!a.weak&&!a.marks&&!b.final&&!b.weak&&!b.marks);}
        else if(mode==1||mode==2){assert(a.final==1&&a.weak==(mode==2)&&a.marks==1&&!b.final&&!b.weak&&!b.marks);}
        else {assert(a.final==(mode!=5&&mode!=7)&&a.weak==(mode!=6)&&a.marks==1);assert(b.final==1&&b.weak==(mode!=6)&&b.marks==1);}
        assert(!other.final&&!other.marks);
        gc_process_deferred_objects(&d);
        assert(other.final==1&&other.marks==1&&d.status==GARBAGE_THREAD_NORMAL);
    }
    puts("finalizer/weak-reference list: 10000 modeled cycles PASS");
}
'''


class GCDeferredObjectsTest(unittest.TestCase):
    def test_deferred_object_linkage_and_terminal_stop(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host compiler unavailable")
        gc = (JVM / "garbage.c").read_text()
        a = gc.index("static void gc_process_deferred_objects(")
        b = gc.index("\n}", a) + 2
        flags = ["-std=c11", "-Wall", "-Wextra", "-Werror"]
        if os.environ.get("JARBOX_GC_DEFER_SANITIZE") == "1":
            flags += ["-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "deferred.c"
            exe = Path(td) / "deferred"
            src.write_text(PRELUDE + gc[a:b] + MAIN)
            subprocess.run([cc, *flags, str(src), "-o", str(exe)], check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("10000 modeled cycles PASS", result.stdout)

    def test_deferred_processing_remains_before_sweep(self):
        gc = (JVM / "garbage.c").read_text()
        collect = gc.split("s64 _garbage_collect(GcCollector *collector) {", 1)[1]
        self.assertLess(collect.index("gc_process_deferred_objects(collector);"),
                        collect.index("memoryblock_destroy(curmb);"))
        self.assertNotIn("instance_finalize(", collect.split("static void _list_iter_thread_pause", 1)[0])


if __name__ == "__main__":
    unittest.main()
