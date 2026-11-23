#ifndef JARBOX_SESSION_H
#define JARBOX_SESSION_H
#include <stdint.h>
#include <stdlib.h>
#include "jarbox_treo_state.h"

/*
 * One Java heap, one JarBoxSession. The owner JVM holds the initial ref;
 * a Java worker/callback must retain its own ref before it can outlive the
 * caller. A bare, potentially freed session pointer cannot be "reacquired".
 *
 * This is the lifecycle foundation, NOT a parallel-JVM enable switch.
 * The foreground dispatcher, render and Treo singleton migration remain
 * separate work. In particular, the 2D renderer has one visible target.
 */
enum {
    JARBOX_SESSION_STARTING = 1,
    JARBOX_SESSION_FOREGROUND = 2,
    JARBOX_SESSION_PARKED = 3,
    JARBOX_SESSION_STOPPING = 4,
    JARBOX_SESSION_DEAD = 5
};

#define JARBOX_SESSION_LEASE_CLOSED 0x80000000u
#define JARBOX_SESSION_LEASE_COUNT_MASK 0x7fffffffu

typedef struct JarBoxSession {
    void *vm;                 /* non-owning; cleared before freeing MiniJVM */
    uint64_t token;           /* immutable once bound by the bridge */
    unsigned references;      /* JVM owner + independently retained clients */
    unsigned java_workers;    /* reserved before pthread creation */
    unsigned native_callbacks; /* pinned native visitor/async work */
    unsigned lease_gate;      /* high bit = closing; low bits = live leases */
    unsigned phase;
    // GC and AFK diagnostics now live in this session, never on a shared
    // process-global scheduler. Guarded Canvas/NSO/JAR worker migration
    // remains a separate prerequisite for parallel JVM startup.
    JarBoxTreoState treo_state;
} JarBoxSession;

static inline JarBoxSession *jarbox_session_create(void *vm) {
    if (!vm) return NULL;
    JarBoxSession *s = (JarBoxSession *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->vm = vm;
    __atomic_store_n(&s->references, 1u, __ATOMIC_RELEASE);
    __atomic_store_n(&s->phase, JARBOX_SESSION_STARTING, __ATOMIC_RELEASE);
    return s;
}
static inline int jarbox_session_bind_token(JarBoxSession *s, uint64_t token) {
    if (!s || !token) return 0;
    uint64_t expected = 0;
    return __atomic_compare_exchange_n(&s->token, &expected, token, 0,
                                       __ATOMIC_RELEASE, __ATOMIC_RELAXED);
}
static inline int jarbox_session_phase(const JarBoxSession *s) {
    return s ? (int)__atomic_load_n(&s->phase, __ATOMIC_ACQUIRE)
             : JARBOX_SESSION_DEAD;
}
static inline int jarbox_session_enter_foreground(JarBoxSession *s) {
    if (!s) return 0;
    unsigned p = __atomic_load_n(&s->phase, __ATOMIC_ACQUIRE);
    while (p == JARBOX_SESSION_STARTING || p == JARBOX_SESSION_PARKED) {
        if (__atomic_compare_exchange_n(&s->phase, &p, JARBOX_SESSION_FOREGROUND,
                                        0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
            return 1;
    }
    return p == JARBOX_SESSION_FOREGROUND;
}
static inline int jarbox_session_park(JarBoxSession *s) {
    if (!s) return 0;
    unsigned expected = JARBOX_SESSION_FOREGROUND;
    return __atomic_compare_exchange_n(&s->phase, &expected, JARBOX_SESSION_PARKED,
                                       0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE);
}
/* All heap users reserve through the *same* atomic lease gate that STOPPING
 * closes. Separate phase and worker counters alone cannot linearize races.
 * The caller must already own a session reference (owner or registry pin). */
static inline void jarbox_session_begin_stop(JarBoxSession *s) {
    if (!s) return;
    unsigned gate = __atomic_load_n(&s->lease_gate, __ATOMIC_ACQUIRE);
    while (!(gate & JARBOX_SESSION_LEASE_CLOSED) &&
           !__atomic_compare_exchange_n(&s->lease_gate, &gate,
                                        gate | JARBOX_SESSION_LEASE_CLOSED,
                                        0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {}
    unsigned p = __atomic_load_n(&s->phase, __ATOMIC_ACQUIRE);
    while (p < JARBOX_SESSION_STOPPING &&
           !__atomic_compare_exchange_n(&s->phase, &p, JARBOX_SESSION_STOPPING,
                                        0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {}
}
static inline void jarbox_session_release(JarBoxSession *s) {
    if (s && __atomic_sub_fetch(&s->references, 1u, __ATOMIC_ACQ_REL) == 0)
        free(s);
}
/* Object-only pin for existing callers; NOT a lease to access a VM heap.
 * Native VM callbacks must use reserve_callback / callback_done instead. */
static inline int jarbox_session_retain_running(JarBoxSession *s) {
    if (!s || jarbox_session_phase(s) >= JARBOX_SESSION_STOPPING) return 0;
    __atomic_add_fetch(&s->references, 1u, __ATOMIC_ACQ_REL);
    if (jarbox_session_phase(s) >= JARBOX_SESSION_STOPPING) {
        jarbox_session_release(s);
        return 0;
    }
    return 1;
}
static inline int jarbox_session_try_lease(JarBoxSession *s) {
    if (!s) return 0;
    unsigned gate = __atomic_load_n(&s->lease_gate, __ATOMIC_ACQUIRE);
    for (;;) {
        if ((gate & JARBOX_SESSION_LEASE_CLOSED) ||
            (gate & JARBOX_SESSION_LEASE_COUNT_MASK) == JARBOX_SESSION_LEASE_COUNT_MASK)
            return 0;
        if (__atomic_compare_exchange_n(&s->lease_gate, &gate, gate + 1u,
                                        0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
            break;
    }
    __atomic_add_fetch(&s->references, 1u, __ATOMIC_ACQ_REL);
    return 1;
}
static inline unsigned jarbox_session_active_lease_count(const JarBoxSession *s) {
    return s ? (__atomic_load_n(&s->lease_gate, __ATOMIC_ACQUIRE) &
                JARBOX_SESSION_LEASE_COUNT_MASK) : 0u;
}
static inline void jarbox_session_lease_done(JarBoxSession *s) {
    __atomic_sub_fetch(&s->lease_gate, 1u, __ATOMIC_ACQ_REL);
    jarbox_session_release(s);
}
static inline void jarbox_session_worker_done(JarBoxSession *s) {
    if (!s) return;
    __atomic_sub_fetch(&s->java_workers, 1u, __ATOMIC_ACQ_REL);
    jarbox_session_lease_done(s);
}
/* Reserve BEFORE thrd_create. The closing gate revokes a racing attempt;
 * a reservation completed before closure is waited on by teardown. */
static inline int jarbox_session_reserve_worker(JarBoxSession *s) {
    if (!jarbox_session_try_lease(s)) return 0;
    __atomic_add_fetch(&s->java_workers, 1u, __ATOMIC_ACQ_REL);
    if (__atomic_load_n(&s->lease_gate, __ATOMIC_ACQUIRE) & JARBOX_SESSION_LEASE_CLOSED) {
        jarbox_session_worker_done(s);
        return 0;
    }
    return 1;
}
static inline unsigned jarbox_session_worker_count(const JarBoxSession *s) {
    return s ? __atomic_load_n(&s->java_workers, __ATOMIC_ACQUIRE) : 0u;
}
/* Native callbacks hold an independent heap-access lease. The owner/registry
 * keeps the session object alive until reserve_callback returns. */
static inline void jarbox_session_callback_done(JarBoxSession *s) {
    if (!s) return;
    __atomic_sub_fetch(&s->native_callbacks, 1u, __ATOMIC_ACQ_REL);
    jarbox_session_lease_done(s);
}
static inline int jarbox_session_reserve_callback(JarBoxSession *s) {
    if (!jarbox_session_try_lease(s)) return 0;
    __atomic_add_fetch(&s->native_callbacks, 1u, __ATOMIC_ACQ_REL);
    if (__atomic_load_n(&s->lease_gate, __ATOMIC_ACQUIRE) & JARBOX_SESSION_LEASE_CLOSED) {
        jarbox_session_callback_done(s);
        return 0;
    }
    return 1;
}
static inline unsigned jarbox_session_callback_count(const JarBoxSession *s) {
    return s ? __atomic_load_n(&s->native_callbacks, __ATOMIC_ACQUIRE) : 0u;
}
/* DEAD is single-winner, only after STOPPING has closed admission and every
 * worker/callback lease has completed. A stale callback can no longer enter. */
static inline int jarbox_session_mark_dead(JarBoxSession *s) {
    if (!s || jarbox_session_phase(s) != JARBOX_SESSION_STOPPING ||
        __atomic_load_n(&s->lease_gate, __ATOMIC_ACQUIRE) != JARBOX_SESSION_LEASE_CLOSED)
        return 0;
    unsigned expected = JARBOX_SESSION_STOPPING;
    if (!__atomic_compare_exchange_n(&s->phase, &expected, JARBOX_SESSION_DEAD,
                                     0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
        return 0;
    __atomic_store_n(&s->vm, NULL, __ATOMIC_RELEASE);
    return 1;
}
#endif
