#ifndef JARBOX_GC_PHASE_H
#define JARBOX_GC_PHASE_H
#include <stdint.h>
#include <stddef.h>
// Six contiguous phases of a completed worker collection. No clock or lock
// in this helper; caller captures seven boundaries on the same thread.
enum { JARBOX_GC_PHASES=6 };
typedef struct {
    uint64_t cpu[7], wall[7];
    uint64_t scanned, reclaimed, freed_bytes;
} JarBoxGCPhaseCycle;
typedef struct {
    uint64_t cycles, cpu[6], wall[6], scanned, reclaimed, freed_bytes;
} JarBoxGCPhaseTotals;
typedef struct {
    unsigned lock;
    uint64_t busy, invalid, aborted;
    JarBoxGCPhaseTotals totals;
} JarBoxGCPhaseStats;
static inline int jarbox_gc_phase_try(JarBoxGCPhaseStats *s) {
    unsigned expected=0;
    return __atomic_compare_exchange_n(&s->lock,&expected,1,0,__ATOMIC_ACQUIRE,__ATOMIC_RELAXED);
}
static inline void jarbox_gc_phase_unlock(JarBoxGCPhaseStats *s) {
    __atomic_store_n(&s->lock,0,__ATOMIC_RELEASE);
}
// Publish only complete, monotonic collections; never wait on a reader.
static inline int jarbox_gc_phase_publish(JarBoxGCPhaseStats *s,const JarBoxGCPhaseCycle *c,int aborted) {
    if (aborted) {__atomic_fetch_add(&s->aborted,1,__ATOMIC_RELAXED);return 0;}
    if (!c->cpu[0] || !c->wall[0] || c->reclaimed>c->scanned) goto invalid;
    for(unsigned i=0;i<JARBOX_GC_PHASES;i++)
        if(c->cpu[i+1]<c->cpu[i] || c->wall[i+1]<c->wall[i]) goto invalid;
    if (!jarbox_gc_phase_try(s)) {__atomic_fetch_add(&s->busy,1,__ATOMIC_RELAXED);return 0;}
    JarBoxGCPhaseTotals *t=&s->totals;
    ++t->cycles;
    for(unsigned i=0;i<JARBOX_GC_PHASES;i++) {
        t->cpu[i]+=c->cpu[i+1]-c->cpu[i];
        t->wall[i]+=c->wall[i+1]-c->wall[i];
    }
    t->scanned+=c->scanned;t->reclaimed+=c->reclaimed;t->freed_bytes+=c->freed_bytes;
    jarbox_gc_phase_unlock(s);return 1;
invalid:
    __atomic_fetch_add(&s->invalid,1,__ATOMIC_RELAXED);return 0;
}
static inline int jarbox_gc_phase_snapshot(JarBoxGCPhaseStats *s,JarBoxGCPhaseTotals *out) {
    *out=(JarBoxGCPhaseTotals){0};
    if(!jarbox_gc_phase_try(s))return 0;
    *out=s->totals;
    jarbox_gc_phase_unlock(s);return 1;
}
#endif
