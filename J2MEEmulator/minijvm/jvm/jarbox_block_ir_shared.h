#ifndef JARBOX_BLOCK_IR_SHARED_H
#define JARBOX_BLOCK_IR_SHARED_H
#include <pthread.h>
#include <limits.h>
#include "jarbox_block_ir.h"

/* Only immutable program data are shared. The pool owns no Java objects,
 * loaders, runtime pointers or mutable game data. Metadata is protected by
 * one mutex used only when acquiring/releasing a CodeAttribute lease. */
enum { JBI_POOL_BUCKETS=128, JBI_POOL_MAX_ENTRIES=2048, JBI_POOL_BUDGET=4*1024*1024 };
typedef struct JbiSharedEntry {
    struct JbiSharedEntry *next;
    JbiPlan *plan;
    uint64_t hash;
    unsigned refs, size, locals, stack, nh, be;
    size_t cost;
    uint8_t key[];
} JbiSharedEntry;
typedef struct {
    pthread_mutex_t lock;
    JbiSharedEntry *bucket[JBI_POOL_BUCKETS];
    size_t bytes;
    unsigned count;
} JbiPool;
#define JBI_POOL_INIT { .lock=PTHREAD_MUTEX_INITIALIZER }
_Static_assert(sizeof(JbiHandler)==6,"handler key layout");
static inline uint64_t jbi_pool_hash(const uint8_t *c,unsigned n,unsigned locals,unsigned stack,
                                    const JbiHandler *h,unsigned nh,int be) {
    uint64_t hash=UINT64_C(14695981039346656037);
    const unsigned meta[]={n,locals,stack,nh,(unsigned)be};
    for(unsigned i=0;i<5;++i)hash=(hash^meta[i])*UINT64_C(1099511628211);
    for(unsigned i=0;i<n;++i)hash=(hash^c[i])*UINT64_C(1099511628211);
    for(unsigned i=0;i<nh;++i){
        hash=(hash^h[i].start)*UINT64_C(1099511628211);
        hash=(hash^h[i].end)*UINT64_C(1099511628211);
        hash=(hash^h[i].handler)*UINT64_C(1099511628211);
    }
    return hash;
}
static inline JbiSharedEntry *jbi_pool_find(JbiPool *pool,uint64_t hash,const uint8_t *c,
        unsigned n,unsigned locals,unsigned stack,const JbiHandler *h,unsigned nh,int be) {
    for(JbiSharedEntry *e=pool->bucket[hash%JBI_POOL_BUCKETS];e;e=e->next)
        if(e->hash==hash&&e->size==n&&e->locals==locals&&e->stack==stack&&e->nh==nh&&e->be==(unsigned)be&&
           !memcmp(e->key,c,n)&&(!nh||!memcmp(e->key+n,h,nh*sizeof(*h)))&&e->refs<UINT_MAX)
            return e;
    return NULL;
}
/* A caller owns one lease even on a hit. Contention or pool budget failure
 * takes a private plan, never waits on another VM's compilation. */
static inline JbiPlan *jbi_pool_acquire(JbiPool *pool,const uint8_t *c,unsigned n,
        unsigned locals,unsigned stack,const JbiHandler *h,unsigned nh,int be,
        JbiSharedEntry **lease,int *hit) {
    *lease=NULL;*hit=0;
    if(!c||n<5||n>JBI_MAX_CODE||nh>JBI_MAX_HANDLERS||(nh&&!h)||locals>32767||stack>32767)return NULL;
    uint64_t hash=jbi_pool_hash(c,n,locals,stack,h,nh,be);
    if(pthread_mutex_trylock(&pool->lock)==0){
        JbiSharedEntry *e=jbi_pool_find(pool,hash,c,n,locals,stack,h,nh,be);
        if(e){++e->refs;*lease=e;*hit=1;}
        pthread_mutex_unlock(&pool->lock);
        if(e)return e->plan;
    }
    JbiPlan *p=jbi_build(c,n,locals,stack,h,nh,be);
    if(!p)return NULL;
    if(pthread_mutex_trylock(&pool->lock)!=0)return p;
    JbiSharedEntry *e=jbi_pool_find(pool,hash,c,n,locals,stack,h,nh,be);
    if(e){
        ++e->refs;*lease=e;*hit=1;
        pthread_mutex_unlock(&pool->lock);free(p);return e->plan;
    }
    size_t keybytes=n+nh*sizeof(*h),cost=sizeof(*e)+keybytes+p->bytes;
    if(pool->count<JBI_POOL_MAX_ENTRIES&&cost<=JBI_POOL_BUDGET-pool->bytes){
        e=malloc(sizeof(*e)+keybytes);
        if(e){
            *e=(JbiSharedEntry){.plan=p,.hash=hash,.refs=1,.size=n,.locals=locals,
                               .stack=stack,.nh=nh,.be=(unsigned)be,.cost=cost};
            memcpy(e->key,c,n);if(nh)memcpy(e->key+n,h,nh*sizeof(*h));
            unsigned bucket=hash%JBI_POOL_BUCKETS;
            e->next=pool->bucket[bucket];pool->bucket[bucket]=e;
            ++pool->count;pool->bytes+=cost;*lease=e;
        }
    }
    pthread_mutex_unlock(&pool->lock);
    return p;
}
/* Last owner releases the tape immediately, so no process-lifetime cache
 * retention. Active frames already pin their owning class/CodeAttribute. */
static inline void jbi_pool_release(JbiPool *pool,JbiPlan *p,JbiSharedEntry *lease) {
    if(!lease){free(p);return;}
    pthread_mutex_lock(&pool->lock);
    if(--lease->refs){pthread_mutex_unlock(&pool->lock);return;}
    JbiSharedEntry **link=&pool->bucket[lease->hash%JBI_POOL_BUCKETS];
    while(*link!=lease)link=&(*link)->next;
    *link=lease->next;--pool->count;pool->bytes-=lease->cost;
    pthread_mutex_unlock(&pool->lock);
    free(lease->plan);free(lease);
}
#endif
