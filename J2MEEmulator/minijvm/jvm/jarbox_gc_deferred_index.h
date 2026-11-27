#ifndef JARBOX_GC_DEFERRED_INDEX_H
#define JARBOX_GC_DEFERRED_INDEX_H
#include <stddef.h>
#include <string.h>

/* Collector-local, non-owning index in REVERSE heap-list order. Only the
 * collector changes this index; it is never a root or a shared cache. */
enum { JARBOX_GC_DEFERRED_LIMIT = 16384 };
typedef struct {
    MemoryBlock **items;
    size_t count, capacity;
    int disabled;
} JarBoxGCDeferredIndex;

static inline void gc_deferred_index_disable(JarBoxGCDeferredIndex *index) {
    if (index->items) jvm_free(index->items);
    index->items = NULL;
    index->count = index->capacity = 0;
    index->disabled = 1;
}

static inline int gc_deferred_index_push(JarBoxGCDeferredIndex *index, MemoryBlock *mb) {
    if (index->count == index->capacity) {
        if (index->capacity >= JARBOX_GC_DEFERRED_LIMIT) return 0;
        size_t capacity = index->capacity ? index->capacity * 2 : 64;
        MemoryBlock **items = jvm_malloc(capacity * sizeof(*items));
        if (!items) return 0;
        if (index->count) memcpy(items, index->items, index->count * sizeof(*items));
        if (index->items) jvm_free(index->items);
        index->items = items;
        index->capacity = capacity;
    }
    index->items[index->count++] = mb;
    return 1;
}

/* The stopped-world merge prepends [first, old_head) to the heap.
 * Weak flags are set before registration (also copied on clone). A class
 * may gain a finalizer during clinit, so keep ALL not-yet-initialized
 * instances. Only CLINITED classes with no finalizer are excluded.
 * Do not prune finalized candidates: weak targets can change. */
static inline void gc_deferred_index_add(JarBoxGCDeferredIndex *index,
                                        MemoryBlock *first, MemoryBlock *old_head) {
    if (index->disabled) return;
    size_t start = index->count;
    for (MemoryBlock *mb = first; mb != old_head; mb = mb->next) {
        if (!mb) { gc_deferred_index_disable(index); return; }
        if (mb->type != MEM_TYPE_INS) continue;
        if (!GCFLAG_WEAKREFERENCE_GET(mb->gcflag) && mb->clazz &&
            mb->clazz->status == CLASS_STATUS_CLINITED && !mb->clazz->finalizeMethod)
            continue;
        if (!gc_deferred_index_push(index, mb)) {
            gc_deferred_index_disable(index);
            return;
        }
    }
    /* Reverse just the new batch: backward iteration now visits the exact
     * original forward heap order, including all earlier survivor batches. */
    size_t end = index->count;
    while (start < end && start < --end) {
        MemoryBlock *tmp = index->items[start];
        index->items[start++] = index->items[end];
        index->items[end] = tmp;
    }
}

/* Called AFTER deferred remark and BEFORE the unchanged sweep. The GC is
 * the only mark writer; remove entries that sweep is about to destroy. */
static inline void gc_deferred_index_prune(JarBoxGCDeferredIndex *index, unsigned mark) {
    if (index->disabled) return;
    size_t out = 0;
    for (size_t i = 0; i < index->count; ++i) {
        MemoryBlock *mb = index->items[i];
        if (mb->garbage_mark == mark) index->items[out++] = mb;
    }
    index->count = out;
}
#endif
