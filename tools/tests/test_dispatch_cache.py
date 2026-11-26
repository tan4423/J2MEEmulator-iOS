"""Production dispatch header: concurrent reads, unique IDs and full-cache fallback."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
C=r"""
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include "jarbox_dispatch_cache.h"
static uint64_t counter;
static JarBoxDispatchCache cache;
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static int targets[2];
static void *reader(void *arg) {
    (void)arg;
    for (unsigned i=0;i<100000;++i) {
        void *a=jarbox_dispatch_find(&cache,1),*b=jarbox_dispatch_find(&cache,2);
        assert(!a || a==&targets[0]);assert(!b || b==&targets[1]);
        assert(!jarbox_dispatch_find(&cache,3));
    }
    return 0;
}
static void *writer(void *arg) {
    (void)arg;
    pthread_mutex_lock(&lock);
    assert(jarbox_dispatch_publish_locked(&cache,1,&targets[0]));
    assert(jarbox_dispatch_publish_locked(&cache,2,&targets[1]));
    assert(!jarbox_dispatch_publish_locked(&cache,3,&targets[0]));
    pthread_mutex_unlock(&lock);
    return 0;
}
int main(void) {
    pthread_t t[5];
    for(unsigned n=0;n<4;++n)assert(!pthread_create(&t[n],0,reader,0));
    assert(!pthread_create(&t[4],0,writer,0));
    for(unsigned n=0;n<5;++n)assert(!pthread_join(t[n],0));
    assert(jarbox_dispatch_find(&cache,1)==&targets[0]);
    assert(jarbox_dispatch_find(&cache,2)==&targets[1]);
    assert(!jarbox_dispatch_publish_locked(&cache,1,&targets[1]));
    for(unsigned i=0;i<10000;++i){
        JarBoxDispatchCache a={0},b={0};
        uint64_t one=jarbox_dispatch_next_id(&counter),two=jarbox_dispatch_next_id(&counter);
        assert(one && two==one+1);
        assert(jarbox_dispatch_publish_locked(&a,one,&targets[0]));
        assert(!jarbox_dispatch_find(&a,two));
        assert(!jarbox_dispatch_find(&b,one));
        assert(!jarbox_dispatch_publish_locked(&a,0,&targets[0]));
        assert(!jarbox_dispatch_publish_locked(&a,two,0));
        assert(jarbox_dispatch_publish_locked(&a,two,&targets[1]));
    }
    counter=UINT64_MAX-1;
    assert(jarbox_dispatch_next_id(&counter)==UINT64_MAX);
    assert(!jarbox_dispatch_next_id(&counter));
    assert(!jarbox_dispatch_next_id(&counter));
    puts("400000 concurrent read iterations; 10000 cache/identity cycles PASS");
}
"""
class DispatchCacheTest(unittest.TestCase):
    def test_cache(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)
            (p/"test.c").write_text(C)
            subprocess.run([cc,"-std=c11","-O2","-Wall","-Wextra","-Werror","-pthread","-I",str(JVM),str(p/"test.c"),"-o",str(p/"test")],check=True,timeout=30)
            subprocess.run([str(p/"test")],check=True,timeout=20)
    def test_wiring(self):
        src=(JVM/"interpreter.c").read_text()
        self.assertEqual(src.count("m = jarbox_virtual_lookup(jvm, cmr, ins);"),4)
        self.assertEqual(src.count("retained = jarbox_virtual_publish(jvm, cmr, ins, m);"),2)
        self.assertIn("if (retained) {\n                                            *runtime->pc = op_invokevirtual_fast;",src)
        self.assertIn("} else if (retained) {\n                                    *runtime->pc = op_invokeinterface_fast;",src)
        self.assertIn("receiver->mb.type!=MEM_TYPE_INS",src)
        for op,width in (("op_invokevirtual_fast",3),("op_invokeinterface_fast",5)):
            body=src.split("case "+op+": TREO_VM_HANDLER("+op+") {",1)[1].split("case op_",1)[0]
            self.assertIn("jarbox_virtual_publish(jvm, cmr, ins, m);",body)
            self.assertIn("goto label_nosuchmethod_throw;",body)
            self.assertIn("runtime->pc += "+str(width)+";",body)
            self.assertEqual(body.count("ret = execute_method_impl(m, runtime);"),1)
        cl=(JVM/"class.c").read_text()
        self.assertIn("jarbox_dispatch_next_id(&runtime->jvm->dispatch_id_counter)",cl)
        self.assertEqual(cl.count("#if !JARBOX_VM_INLINE_DISPATCH\n            cmr->virtual_methods = pairlist_create(0);"),2)
if __name__=="__main__":unittest.main()
