"""Use the real heap sampler with a ledger stub that changes every read."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
GC=ROOT/"J2MEEmulator/minijvm/jvm/garbage.c"
PRE=r"""
#include <stdint.h>
#include <stddef.h>
typedef int64_t s64;
typedef struct {s64 thread_bytes,native_bytes;int reads;} MiniJVM;
typedef struct {MiniJVM *jvm;s64 obj_heap_size;int lock;} GcCollector;
static void spin_lock(int *l){++*l;}
static void spin_unlock(int *l){--*l;}
static s64 threadlist_sum_heap(MiniJVM *vm){return vm->thread_bytes;}
static s64 jarbox_native_heap_for_vm(MiniJVM *vm){++vm->reads;return vm->native_bytes++;}
"""
MAIN=r"""
int main(void){
    MiniJVM a={100,30,0},b={200,70,0};
    GcCollector ca={&a,400,0},cb={&b,800,0};
    for(int i=0;i<10000;i++){
        s64 n=-1;
        s64 total=gc_sum_heap_sample(&ca,&n);
        if(total!=500+n||n!=30+i||a.reads!=i+1||ca.lock)return 1;
        total=gc_sum_heap_sample(&cb,&n);
        if(total!=1000+n||n!=70+i||b.reads!=i+1||cb.lock)return 2;
    }
    if(gc_sum_heap(&ca)!=10530||a.reads!=10001||b.reads!=10000)return 3;
    return 0;
}
"""
class GCHeapSampleTest(unittest.TestCase):
    def test_one_native_read_per_sample(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        source=GC.read_text()
        a=source.index("static s64 gc_sum_heap_sample(")
        b=source.index("//==============================",a)
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"test.c",Path(td)/"test"
            p.write_text(PRE+source[a:b]+MAIN)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror",str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=10)
if __name__=="__main__":unittest.main()
