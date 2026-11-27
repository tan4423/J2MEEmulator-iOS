#include <assert.h>
#include <stdio.h>
#include <stdint.h>
#include <pthread.h>
typedef struct {union{int64_t lvalue;uint64_t ulvalue;int32_t ivalue;uint32_t uivalue;};void *rvalue;} StackEntry;
#include "jarbox_block_ir_shared.h"
static JbiPool pool=JBI_POOL_INIT;
static const uint8_t code[]={4,5,0x60,0x3b,0x1a,4,0x68,0x3b,0xb1};
static void *worker(void *arg){
    unsigned id=(unsigned)(uintptr_t)arg;
    for(unsigned i=0;i<1000;++i){
        JbiSharedEntry *lease;int hit;
        JbiPlan *p=jbi_pool_acquire(&pool,code,sizeof(code),1,2,NULL,0,1,&lease,&hit);
        assert(p&&p->spans==1);
        StackEntry s[4]={0},l[1]={0};l[0].ivalue=(int32_t)id;
        jbi_execute(p,p->span,s,l);assert(l[0].ivalue==3);
        jbi_pool_release(&pool,p,lease);
    }
    return NULL;
}
int main(void){
    JbiSharedEntry *a,*b,*c,*d;int hit;
    JbiPlan *p=jbi_pool_acquire(&pool,code,sizeof code,1,2,NULL,0,1,&a,&hit);
    assert(p&&a&&!hit&&pool.count==1);
    JbiPlan *q=jbi_pool_acquire(&pool,code,sizeof code,1,2,NULL,0,1,&b,&hit);
    assert(q==p&&a==b&&hit&&pool.count==1);
    uint8_t other[sizeof code];memcpy(other,code,sizeof code);other[0]=3;
    JbiPlan *r=jbi_pool_acquire(&pool,other,sizeof other,1,2,NULL,0,1,&c,&hit);
    assert(r&&r!=p&&c&&!hit&&pool.count==2);
    JbiHandler h={0,8,4};
    JbiPlan *t=jbi_pool_acquire(&pool,code,sizeof code,1,2,&h,1,1,&d,&hit);
    assert(t&&t!=p&&d&&!hit&&t->spans==2&&pool.count==3);
    jbi_pool_release(&pool,p,a);assert(pool.count==3);
    StackEntry s[4]={0},l[1]={0};jbi_execute(q,q->span,s,l);assert(l[0].ivalue==3);
    jbi_pool_release(&pool,q,b);jbi_pool_release(&pool,r,c);jbi_pool_release(&pool,t,d);
    assert(!pool.count&&!pool.bytes);
    /* Contention must yield an independent valid tape, not block. */
    pthread_mutex_lock(&pool.lock);
    p=jbi_pool_acquire(&pool,code,sizeof code,1,2,NULL,0,1,&a,&hit);
    assert(p&&!a&&!hit);jbi_pool_release(&pool,p,a);pthread_mutex_unlock(&pool.lock);
    pthread_t threads[8];
    for(unsigned i=0;i<8;++i)assert(!pthread_create(&threads[i],NULL,worker,(void *)(uintptr_t)i));
    for(unsigned i=0;i<8;++i)assert(!pthread_join(threads[i],NULL));
    assert(!pool.count&&!pool.bytes);
    puts("shared block IR: exact keys, independent lanes, 8000 concurrent leases PASS");
}
