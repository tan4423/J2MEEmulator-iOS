"""Production GC/start lock handshake under forced contention (host model).
No real Java heap or iOS runtime is simulated.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
JVM=ROOT/"J2MEEmulator/minijvm/jvm"
PRE=r"""
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>
typedef int s32;
typedef int64_t s64;
typedef struct { atomic_int thread_status, is_suspend, is_blocking; } Info;
typedef struct { pthread_mutex_t spinlock; } ArrayList;
typedef struct { atomic_int status; } Collector;
typedef struct { ArrayList *thread_list; Collector *collector; } MiniJVM;
typedef struct { MiniJVM *jvm; Info *thrd_info; } Runtime;
enum { THREAD_STATUS_NEW=0, THREAD_STATUS_RUNNING=1, THREAD_STATUS_ZOMBIE=2,
       GARBAGE_THREAD_NORMAL=1 };
static int spin_trylock(pthread_mutex_t *m) { return pthread_mutex_trylock(m); }
static void thrd_sleep(const struct timespec *t, void *unused) {
    (void)unused; nanosleep(t,NULL);
}
static atomic_int safepoints;
static void check_suspend_and_pause(Runtime *r) {
    atomic_fetch_add(&safepoints,1);
    atomic_store(&r->thrd_info->is_suspend,1);
    // In this fixture GC owns the list, and releases it after acknowledgement.
}
static s64 clock_ns;
static int wait_calls, wait_behavior;
static Info *waiting_info;
static int gc_thread_status(Collector *c) { return atomic_load(&c->status); }
static s64 nanoTime(void) { return clock_ns; }
static void vm_share_notifyall(MiniJVM *v) { (void)v; }
static void vm_share_timedwait(MiniJVM *v, int ms) {
    ++wait_calls; clock_ns += (s64)ms*1000000;
    if (wait_behavior==1) waiting_info->thread_status=THREAD_STATUS_ZOMBIE;
    if (wait_behavior==2) v->collector->status=0;
}
"""
MAIN=r"""
static void *spawner(void *arg) {
    Runtime *r=arg;
    jthread_start_list_lock(r);
    assert(atomic_load(&r->thrd_info->is_suspend)==1);
    pthread_mutex_unlock(&r->jvm->thread_list->spinlock);
    return NULL;
}
int main(void) {
    ArrayList list={PTHREAD_MUTEX_INITIALIZER};
    Collector gc={.status=GARBAGE_THREAD_NORMAL};
    Info info={.thread_status=THREAD_STATUS_RUNNING};
    MiniJVM vm={&list,&gc};
    Runtime parent={&vm,&info};
    for(int i=0;i<100;++i) {
        atomic_store(&info.is_suspend,0);
        assert(!pthread_mutex_lock(&list.spinlock));
        pthread_t th;
        assert(!pthread_create(&th,NULL,spawner,&parent));
        // Force the wait-for-safepoint while holding the registration lock.
        for(int n=0;n<5000 && !atomic_load(&info.is_suspend);++n) {
            struct timespec delay={0,1000000}; nanosleep(&delay,NULL);
        }
        assert(atomic_load(&info.is_suspend));
        pthread_mutex_unlock(&list.spinlock);
        assert(!pthread_join(th,NULL));
    }
    assert(atomic_load(&safepoints)>=100);
    info.is_suspend=0; waiting_info=&info;
    wait_behavior=0; wait_calls=0; clock_ns=0;
    assert(_gc_wait_thread_suspend(&vm,&parent)==-1 && wait_calls==20);
    wait_behavior=1; wait_calls=0; clock_ns=0;
    assert(_gc_wait_thread_suspend(&vm,&parent)==0 && wait_calls==1);
    info.thread_status=THREAD_STATUS_RUNNING;
    wait_behavior=2; wait_calls=0; clock_ns=0;
    assert(_gc_wait_thread_suspend(&vm,&parent)==-1 && wait_calls==1);
    pthread_mutex_destroy(&list.spinlock);
    puts("GC/start forced contention, timeout, exit and STOP: PASS");
}
"""
def extract(s,sig):
    i=s.index(sig)
    return s[i:s.index("\n}",i)+2]
class GCThreadStartHandshakeTest(unittest.TestCase):
    def test_forced_contention(self):
        cc=shutil.which("cc")
        if not cc:self.skipTest("host compiler unavailable")
        util=(JVM/"jvm_util.c").read_text()
        gc=(JVM/"garbage.c").read_text()
        src=PRE+extract(util,"static void jthread_start_list_lock(Runtime *parent) {")+"\n"+extract(gc,"s32 _gc_wait_thread_suspend(MiniJVM *jvm, Runtime *runtime) {")+MAIN
        with tempfile.TemporaryDirectory() as d:
            p,exe=Path(d)/"test.c",Path(d)/"test"
            p.write_text(src)
            subprocess.run([cc,"-std=c11","-Wall","-Wextra","-Werror","-pthread",str(p),"-o",str(exe)],check=True,timeout=30)
            subprocess.run([str(exe)],check=True,timeout=20)
    def test_publication_transaction(self):
        util=(JVM/"jvm_util.c").read_text()
        start=extract(util,"thrd_t jthread_start(Instance *ins, Runtime *parent) {")
        self.assertLess(start.index("jthread_start_list_lock(parent)"),start.index("arraylist_push_back_unsafe"))
        self.assertLess(start.index("arraylist_push_back_unsafe"),start.index("thrd_create(&started"))
        self.assertIn("spin_unlock(&thread_list->spinlock);\n    return started;",start)
        self.assertIn("arraylist_remove_unsafe(thread_list, runtime);",start)
        gc=(JVM/"garbage.c").read_text()
        pause=extract(gc,"s32 _gc_pause_the_world(MiniJVM *jvm) {")
        self.assertLess(pause.index("spin_lock(&thread_list->spinlock)"),pause.index("jthread_suspend("))
        self.assertLess(pause.index("jthread_suspend("),pause.index("_gc_wait_thread_suspend("))
        self.assertNotIn("arraylist_iter_safe",pause)
if __name__=="__main__":unittest.main()
