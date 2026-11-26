#ifndef JARBOX_DISPATCH_CACHE_H
#define JARBOX_DISPATCH_CACHE_H
#include <stdint.h>

/* Two write-once entries per constant-pool reference. Writers are serialized
 * by the VM loader lock; readers acquire the published receiver ID. */
typedef struct {
    uint64_t receiver_id;
    void *target;
} JarBoxDispatchEntry;
typedef struct {
    JarBoxDispatchEntry entries[2];
} JarBoxDispatchCache;

static inline uint64_t jarbox_dispatch_next_id(uint64_t *counter) {
    uint64_t old=__atomic_load_n(counter,__ATOMIC_RELAXED);
    for (;;) {
        if (old==UINT64_MAX) return 0;
        if (__atomic_compare_exchange_n(counter,&old,old+1,0,
                                        __ATOMIC_RELAXED,__ATOMIC_RELAXED))
            return old+1;
    }
}
static inline void *jarbox_dispatch_find(const JarBoxDispatchCache *cache,uint64_t id) {
    if (!id) return 0;
    for (unsigned i=0;i<2;++i)
        if (__atomic_load_n(&cache->entries[i].receiver_id,__ATOMIC_ACQUIRE)==id)
            return cache->entries[i].target;
    return 0;
}
/* A published slot is immutable. A matching target or a completely full
 * cache is a final answer; only a potentially free slot needs the writer
 * lock. Acquire before reading target, and never dereference cached pointers.
 * -1 = retry under lock, 0 = cannot retain, 1 = already retained. */
static inline int jarbox_dispatch_fixed_result(const JarBoxDispatchCache *cache,uint64_t id,void *target) {
    if (!id || !target) return 0;
    for (unsigned i=0;i<2;++i) {
        const JarBoxDispatchEntry *entry=&cache->entries[i];
        uint64_t key=__atomic_load_n(&entry->receiver_id,__ATOMIC_ACQUIRE);
        if (key==id) return entry->target==target;
        if (!key) return -1;
    }
    return 0;
}
/* Caller guarantees target lifetime while the exact receiver identity lives. */
static inline int jarbox_dispatch_publish_locked(JarBoxDispatchCache *cache,uint64_t id,void *target) {
    if (!id || !target) return 0;
    for (unsigned i=0;i<2;++i) {
        JarBoxDispatchEntry *entry=&cache->entries[i];
        uint64_t key=__atomic_load_n(&entry->receiver_id,__ATOMIC_RELAXED);
        if (key==id) return entry->target==target;
        if (!key) {
            entry->target=target;
            __atomic_store_n(&entry->receiver_id,id,__ATOMIC_RELEASE);
            return 1;
        }
    }
    return 0;
}
#endif
