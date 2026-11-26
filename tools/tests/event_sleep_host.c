#define _POSIX_C_SOURCE 200809L
#if defined(__APPLE__)
#define _DARWIN_C_SOURCE
#endif
#include <pthread.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <assert.h>
#include <time.h>
#include <stdatomic.h>
#include <sched.h>
typedef int64_t s64;
typedef pthread_mutex_t mtx_t;
typedef pthread_cond_t cnd_t;
#define mtx_plain 0
#define thrd_success 0
static int mtx_init(mtx_t *m,int t){(void)t;return pthread_mutex_init(m,NULL);}
static int cnd_init(cnd_t *c){return pthread_cond_init(c,NULL);}
#define mtx_lock pthread_mutex_lock
#define mtx_unlock pthread_mutex_unlock
#define mtx_destroy pthread_mutex_destroy
#define cnd_destroy pthread_cond_destroy
#define cnd_signal pthread_cond_signal
#define spin_lock pthread_mutex_lock
#define spin_unlock pthread_mutex_unlock
typedef struct JarBoxMonitorWaiter {mtx_t mutex;cnd_t cond;int done;struct JarBoxMonitorWaiter *next;} JarBoxMonitorWaiter;
typedef struct {mtx_t lock;int is_stop,is_interrupt;JarBoxMonitorWaiter *sleep_waiter;} JavaThreadInfo;
typedef struct {JavaThreadInfo *thrd_info;} Runtime;
static int jarbox_waiter_signal(JarBoxMonitorWaiter *w) {
    if (!w) return 0;
    mtx_lock(&w->mutex);
    int changed = !w->done;
    if (changed) {w->done=1;cnd_signal(&w->cond);}
    mtx_unlock(&w->mutex);
    return changed;
}
#include "jarbox_event_sleep.h"
typedef struct {JavaThreadInfo info;Runtime runtime;s64 result,ms;atomic_int done;} Worker;
static s64 stamp(void){struct timespec t;assert(!clock_gettime(CLOCK_MONOTONIC,&t));return (s64)t.tv_sec*1000000000+t.tv_nsec;}
static void init(Worker *w,s64 ms){*w=(Worker){0};assert(!pthread_mutex_init(&w->info.lock,NULL));w->runtime.thrd_info=&w->info;w->ms=ms;}
static void *run(void *arg){Worker *w=arg;w->result=jarbox_event_sleep(&w->runtime,w->ms);atomic_store(&w->done,1);return NULL;}
static void ready(Worker *w){s64 limit=stamp()+INT64_C(2000000000);for(;;){spin_lock(&w->info.lock);int r=w->info.sleep_waiter!=NULL;spin_unlock(&w->info.lock);if(r)return;assert(stamp()<limit);sched_yield();}}
static void cancel(Worker *w,int stop){spin_lock(&w->info.lock);w->info.is_interrupt=1;w->info.is_stop=stop;jarbox_waiter_signal(w->info.sleep_waiter);spin_unlock(&w->info.lock);}
static void finish(Worker *w,pthread_t p){assert(!pthread_join(p,NULL));assert(!w->result&&!w->info.sleep_waiter&&atomic_load(&w->done));pthread_mutex_destroy(&w->info.lock);}
int main(void){
    for(int i=0;i<100;i++){
        Worker a,b;pthread_t pa,pb;init(&a,10000);init(&b,10000);
        assert(!pthread_create(&pa,NULL,run,&a));ready(&a);
        assert(!pthread_create(&pb,NULL,run,&b));ready(&b);
        cancel(&a,i&1);finish(&a,pa);assert(!atomic_load(&b.done));
        cancel(&b,1);finish(&b,pb);
        init(&a,10000);cancel(&a,0);assert(!pthread_create(&pa,NULL,run,&a));finish(&a,pa);
    }
    Worker a;pthread_t p;init(&a,30);s64 start=stamp();assert(!pthread_create(&p,NULL,run,&a));ready(&a);
    // An unrelated signal must not terminate the requested sleep early.
    spin_lock(&a.info.lock);mtx_lock(&a.info.sleep_waiter->mutex);cnd_signal(&a.info.sleep_waiter->cond);mtx_unlock(&a.info.sleep_waiter->mutex);spin_unlock(&a.info.lock);
    finish(&a,p);assert(stamp()-start>=INT64_C(30000000));
    puts("event sleep: 100 targeted wake batches and deadline PASS");
}
