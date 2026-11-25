#ifndef JARBOX_BACKGROUND_TRACE_H
#define JARBOX_BACKGROUND_TRACE_H
#include <stdint.h>

// Diagnostic only, one record per JVM. No worker, timer or Java reference.
// A contended observation is dropped rather than blocking the game thread.
typedef struct {
    int lock, enabled;
    uint64_t start_ns, first_ns, last_ns, max_gap_ns, samples;
} JarBoxBackgroundTrace;
typedef struct {
    uint64_t start_ns, end_ns, first_ns, last_ns, max_gap_ns, samples;
} JarBoxBackgroundProgress;
static inline int jarbox_background_try_lock(JarBoxBackgroundTrace *t) {
    int expected=0;
    return __atomic_compare_exchange_n(&t->lock,&expected,1,0,__ATOMIC_ACQUIRE,__ATOMIC_RELAXED);
}
static inline void jarbox_background_unlock(JarBoxBackgroundTrace *t) {
    __atomic_store_n(&t->lock,0,__ATOMIC_RELEASE);
}
static inline int jarbox_background_enabled(const JarBoxBackgroundTrace *t) {
    return __atomic_load_n(&t->enabled,__ATOMIC_ACQUIRE);
}
static inline int jarbox_background_begin(JarBoxBackgroundTrace *t,uint64_t now) {
    __atomic_store_n(&t->enabled,0,__ATOMIC_RELEASE);
    if (!now || !jarbox_background_try_lock(t)) return 0;
    t->start_ns=now; t->first_ns=0; t->last_ns=0; t->max_gap_ns=0; t->samples=0;
    __atomic_store_n(&t->enabled,1,__ATOMIC_RELEASE);
    jarbox_background_unlock(t);
    return 1;
}
static inline void jarbox_background_note(JarBoxBackgroundTrace *t,uint64_t now) {
    if (!jarbox_background_enabled(t) || !jarbox_background_try_lock(t)) return;
    if (jarbox_background_enabled(t) && now>=t->start_ns &&
        (!t->last_ns || (now>=t->last_ns && now-t->last_ns>=UINT64_C(1000000000)))) {
        uint64_t gap=now-(t->last_ns?t->last_ns:t->start_ns);
        if (gap>t->max_gap_ns) t->max_gap_ns=gap;
        if (!t->first_ns) t->first_ns=now;
        t->last_ns=now; ++t->samples;
    }
    jarbox_background_unlock(t);
}
static inline int jarbox_background_end(JarBoxBackgroundTrace *t,uint64_t now,JarBoxBackgroundProgress *out) {
    int was=__atomic_exchange_n(&t->enabled,0,__ATOMIC_ACQ_REL);
    if (!was || !jarbox_background_try_lock(t)) return 0;
    int valid=now>=t->start_ns && now>=t->last_ns;
    if (valid) {
        uint64_t tail=now-(t->last_ns?t->last_ns:t->start_ns);
        *out=(JarBoxBackgroundProgress){t->start_ns,now,t->first_ns,t->last_ns,
            tail>t->max_gap_ns?tail:t->max_gap_ns,t->samples};
    }
    jarbox_background_unlock(t);
    return valid;
}
#endif
