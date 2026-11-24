"""Real host threads exercise the production monitor wait/stop functions.

Runtime, Java heap, GC and spinlock plumbing are modeled; the iOS app,
TinyCThread, interpreter and Java exception machinery are not exercised.
Set JARBOX_MONITOR_SANITIZE=1 for ASan+UBSan with a suitable compiler.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"
PRELUDE = r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <threads.h>
#include <stdatomic.h>
#include <time.h>
typedef int s32; typedef int64_t s64; typedef unsigned char u8; typedef void *__refer;
typedef mtx_t spinlock_t;
#define spin_lock mtx_lock
#define spin_unlock mtx_unlock
typedef struct JarBoxMonitorWaiter JarBoxMonitorWaiter;
typedef struct { mtx_t mutex_lock; void *owner_thread; int count; spinlock_t waiters_lock; JarBoxMonitorWaiter *waiters; } ThreadLock;
typedef struct { ThreadLock *thread_lock; } MemoryBlock;
typedef struct { spinlock_t lock; u8 no_pause,is_stop,is_interrupt,thread_status; MemoryBlock *curThreadLock; JarBoxMonitorWaiter *monitor_waiter; } JavaThreadInfo;
typedef struct { JavaThreadInfo *thrd_info; void *stack; } Runtime;
typedef struct { spinlock_t spinlock; int length; Runtime *items[3]; } ArrayList;
typedef struct { ArrayList *thread_list; } MiniJVM;
#define THREAD_STATUS_WAIT 2
#define JVM_EXCEPTION_ILLEGALMONITORSTATE 1
#define RUNTIME_STATUS_EXCEPTION 1
#define RUNTIME_STATUS_ERROR 2
static Runtime *arraylist_get_value_unsafe(ArrayList *list,int i){return list->items[i];}
static void jthreadlock_create(Runtime *r,MemoryBlock *mb){(void)r;(void)mb;abort();}
static void *exception_create(int n,Runtime *r){(void)n;(void)r;return NULL;}
static void push_ref(void *s,void *r){(void)s;(void)r;}
static void jthread_block_enter(Runtime *r){(void)r;}
static void jthread_block_exit(Runtime *r){(void)r;}
static s32 check_throw_interruptexception(Runtime *r){spin_lock(&r->thrd_info->lock);int x=r->thrd_info->is_interrupt;r->thrd_info->is_interrupt=0;spin_unlock(&r->thrd_info->lock);return x;}
static s64 currentTimeMillis(void){struct timespec t;timespec_get(&t,TIME_UTC);return (s64)t.tv_sec*1000+t.tv_nsec/1000000;}
'''
MAIN = r'''
typedef struct { Runtime r; JavaThreadInfo info; MemoryBlock *mb; atomic_int returned; int depth, result; s64 timeout; } Worker;
static void init_worker(Worker *w,MemoryBlock *mb,int depth,s64 timeout){
    *w=(Worker){0};w->r.thrd_info=&w->info;w->mb=mb;w->depth=depth;w->timeout=timeout;
    assert(mtx_init(&w->info.lock,mtx_plain)==thrd_success);
}
static int run(void *p){
    Worker *w=p;ThreadLock *l=w->mb->thread_lock;
    for(int i=0;i<w->depth;i++)assert(mtx_lock(&l->mutex_lock)==thrd_success);
    l->owner_thread=&w->info;l->count=w->depth;
    w->result=jthread_waitTime(w->mb,&w->r,w->timeout);
    assert(l->owner_thread==&w->info&&l->count==w->depth);
    l->owner_thread=NULL;l->count=0;
    for(int i=0;i<w->depth;i++)mtx_unlock(&l->mutex_lock);
    atomic_store(&w->returned,1);return 0;
}
static void await_registered(Worker *w){
    for(;;){spin_lock(&w->info.lock);int ready=w->info.monitor_waiter!=NULL;
        spin_unlock(&w->info.lock);if(ready)return;thrd_yield();}
}
static void done(Worker *w,thrd_t t,int result){
    assert(thrd_join(t,NULL)==thrd_success);assert(w->result==result);
    assert(!w->info.monitor_waiter);mtx_destroy(&w->info.lock);
}
int main(void){
    for(int i=0;i<100;i++){
        ThreadLock l={0};
        assert(mtx_init(&l.mutex_lock,mtx_recursive)==thrd_success);
        assert(mtx_init(&l.waiters_lock,mtx_plain)==thrd_success);
        MemoryBlock mb={&l};Worker a,b;thrd_t ta,tb;
        init_worker(&a,&mb,2,0);init_worker(&b,&mb,1,0);
        assert(thrd_create(&ta,run,&a)==thrd_success);await_registered(&a);
        assert(thrd_create(&tb,run,&b)==thrd_success);await_registered(&b);
        // A Java monitor owned by another pthread cannot block stop_all.
        mtx_lock(&l.mutex_lock);
        ArrayList list={0};mtx_init(&list.spinlock,mtx_plain);
        list.length=1;list.items[0]=&a.r;MiniJVM j={&list};
        thread_stop_all(&j);
        assert(mtx_trylock(&list.spinlock)==thrd_success);mtx_unlock(&list.spinlock);
        assert(!atomic_load(&a.returned)&&!atomic_load(&b.returned));
        mtx_unlock(&l.mutex_lock);done(&a,ta,1);assert(!atomic_load(&b.returned));
        jthread_notify(&mb,&b.r);done(&b,tb,0);assert(!l.waiters);
        mtx_destroy(&list.spinlock);

        init_worker(&a,&mb,1,0);a.info.is_interrupt=1;
        assert(thrd_create(&ta,run,&a)==thrd_success);done(&a,ta,1);
        init_worker(&a,&mb,1,1);
        assert(thrd_create(&ta,run,&a)==thrd_success);done(&a,ta,0);

        init_worker(&a,&mb,1,0);init_worker(&b,&mb,1,0);
        assert(thrd_create(&ta,run,&a)==thrd_success);await_registered(&a);
        assert(thrd_create(&tb,run,&b)==thrd_success);await_registered(&b);
        mtx_lock(&l.mutex_lock);jthread_notifyAll(&mb,&a.r);mtx_unlock(&l.mutex_lock);
        done(&a,ta,0);done(&b,tb,0);assert(!l.waiters);

        init_worker(&a,&mb,1,0);init_worker(&b,&mb,1,0);
        assert(thrd_create(&ta,run,&a)==thrd_success);await_registered(&a);
        assert(thrd_create(&tb,run,&b)==thrd_success);await_registered(&b);
        mtx_lock(&l.mutex_lock);
        assert(jthread_interrupt(&a.r)==0);assert(jthread_interrupt(&a.r)==0);
        mtx_unlock(&l.mutex_lock);done(&a,ta,1);assert(!atomic_load(&b.returned));
        jthread_notify(&mb,&b.r);done(&b,tb,0);assert(!l.waiters);
        mtx_destroy(&l.waiters_lock);mtx_destroy(&l.mutex_lock);
    }
    puts("monitor wait host: 100 cycles PASS");
}
'''

def function(source, signature):
    a = source.index(signature)
    b = source.index("\n}", a) + 2
    return source[a:b]


def harness(source):
    a = source.index("struct JarBoxMonitorWaiter {")
    b = source.index("\n};", a) + 3
    signatures = ("static int jarbox_waiter_signal(", "void thread_stop_all(",
                  "static void jarbox_monitor_notify(", "s32 jthread_notify(",
                  "s32 jthread_notifyAll(", "s32 jthread_interrupt(",
                  "s32 jthread_waitTime(", "s32 jthread_wakeup(")
    return PRELUDE + source[a:b] + "\n" + "\n".join(
        function(source, sig) for sig in signatures) + MAIN


class JavaMonitorStopTest(unittest.TestCase):
    def test_stop_signals_without_acquiring_java_monitor(self):
        source = (JVM / "jvm_util.c").read_text()
        stop = function(source, "void thread_stop_all(")
        self.assertNotIn("jthread_lock(", stop)
        self.assertIn("jarbox_waiter_signal(info->monitor_waiter)", stop)
        self.assertIn("spin_init(&lock->waiters_lock, 0)", source)
        self.assertIn("spin_destroy(&lock->waiters_lock)", source)

    def test_host_monitor_wait(self):
        compiler = shutil.which(os.environ.get("CC", "cc"))
        if not compiler:
            self.skipTest("host C compiler unavailable")
        flags = ["-std=c11", "-pthread", "-Wall", "-Wextra", "-Werror"]
        if os.environ.get("JARBOX_MONITOR_SANITIZE") == "1":
            flags += ["-g", "-O1", "-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
        with tempfile.TemporaryDirectory() as td:
            c = Path(td) / "monitor.c"
            exe = Path(td) / "monitor"
            c.write_text(harness((JVM / "jvm_util.c").read_text()))
            subprocess.run([compiler, *flags, str(c), "-o", str(exe)], check=True, timeout=60)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("monitor wait host: 100 cycles PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
