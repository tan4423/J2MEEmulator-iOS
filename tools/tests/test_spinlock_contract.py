"""Native recursive spin lock contract, real pthreads, original header."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
UTIL=ROOT/"J2MEEmulator/minijvm/utils"
C=r"""
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include "spinlock.h"
static spinlock_t lock;
static atomic_int entered, acquired;
static int value;
static void *waiter(void *arg) {
    (void)arg;
    assert(spin_trylock(&lock)!=0);
    assert(spin_unlock(&lock)!=0);
    assert(spin_lock_timeout(&lock,10)==ETIMEDOUT);
    atomic_store(&entered,1);
    assert(spin_lock_adaptive(&lock)==0);
    atomic_store(&acquired,1);
    assert(spin_unlock(&lock)==0);
    return NULL;
}
static void *increment(void *arg) {
    (void)arg;
    for(int i=0;i<10000;++i){
        assert(!spin_lock(&lock));
        assert(!spin_trylock(&lock));
        ++value;
        assert(!spin_unlock(&lock));
        assert(!spin_unlock(&lock));
    }
    return NULL;
}
int main(void) {
    assert(!spin_lock(&lock));
    assert(!spin_trylock(&lock));
    pthread_t t;
    assert(!pthread_create(&t,NULL,waiter,NULL));
    while(!atomic_load(&entered)) thrd_yield();
    assert(!atomic_load(&acquired));
    assert(!spin_unlock(&lock));
    assert(!atomic_load(&acquired));
    assert(!spin_unlock(&lock));
    assert(!pthread_join(t,NULL));
    assert(atomic_load(&acquired));
    assert(!spin_lock_timeout(&lock,10));
    assert(!spin_unlock(&lock));
    assert(!spin_lock_timeout(&lock,0));
    assert(!spin_unlock(&lock));
    pthread_t workers[4];
    for(int i=0;i<4;++i) assert(!pthread_create(&workers[i],NULL,increment,NULL));
    for(int i=0;i<4;++i) assert(!pthread_join(workers[i],NULL));
    assert(value==40000);
    puts("spinlock recursion, timeout, foreign unlock, contention: PASS");
}
"""
class SpinLockContractTest(unittest.TestCase):
    def test_native_lock_contract(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        with tempfile.TemporaryDirectory() as d:
            p,exe=Path(d)/"spin.c",Path(d)/"spin"
            p.write_text(C)
            subprocess.run([cc,"-std=c11","-O2","-pthread","-I",str(UTIL),str(p),str(UTIL/"tinycthread.c"),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=20)
    def test_gc_retry_and_primitive_identity(self):
        jvm=UTIL.parent/"jvm"
        gc=(jvm/"garbage.c").read_text()
        self.assertIn("collector->lastgc = gcResult < 0 ? currentTimeMillis() : cur_mil;",gc)
        src=(jvm/"jvm_util.c").read_text()
        body=src.split("JClass *primitive_class_create_get(",1)[1].split("\n}",1)[0]
        self.assertEqual(body.count("classes_get(jvm, NULL, ustr)"),2)
        self.assertLess(body.index("vm_share_lock(jvm)"),body.rindex("classes_get(jvm, NULL, ustr)"))
        self.assertLess(body.rindex("classes_get(jvm, NULL, ustr)"),body.index("class_create(runtime)"))
if __name__=="__main__":unittest.main()
