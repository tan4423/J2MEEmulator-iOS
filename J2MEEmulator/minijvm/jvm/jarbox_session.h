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

typedef struct JarBoxSession {
    void *vm;                 /* non-owning; cleared before freeing MiniJVM */
    uint64_t token;           /* immutable once bound by the bridge */
    unsigned references;      /* JVM owner + independently retained clients */
    unsigned java_workers;    /* reserved before pthread creation */
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
static inline void jarbox_session_begin_stop(JarBoxSession *s) {
    if (!s) return;
    unsigned p = __atomic_load_n(&s->phase, __ATOMIC_ACQUIRE);
    while (p < JARBOX_SESSION_STOPPING &&
           !__atomic_compare_exchange_n(&s->phase, &p, JARBOX_SESSION_STOPPING,
                                        0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {}
}
static inline void jarbox_session_release(JarBoxSession *s) {
    if (s && __atomic_sub_fetch(&s->references, 1u, __ATOMIC_ACQ_REL) == 0)
        free(s);
}
/* The caller already owns a reference; this pins before callbacks can run. */
static inline int jarbox_session_retain_running(JarBoxSession *s) {
    if (!s || jarbox_session_phase(s) >= JARBOX_SESSION_STOPPING) return 0;
    __atomic_add_fetch(&s->references, 1u, __ATOMIC_ACQ_REL);
    if (jarbox_session_phase(s) >= JARBOX_SESSION_STOPPING) {
        jarbox_session_release(s);
        return 0;
    }
    return 1;
}
/* Reserve BEFORE thrd_create, so teardown cannot mistake a not-yet-started
 * worker for a finished one. Failure/return releases the reservation. */
static inline int jarbox_session_reserve_worker(JarBoxSession *s) {
    if (!jarbox_session_retain_running(s)) return 0;
    __atomic_add_fetch(&s->java_workers, 1u, __ATOMIC_ACQ_REL);
    // Closing a session may win the race between retain and reservation.
    // Revoke the reservation before the caller starts a pthread.
    if (jarbox_session_phase(s) >= JARBOX_SESSION_STOPPING) {
        __atomic_sub_fetch(&s->java_workers, 1u, __ATOMIC_ACQ_REL);
        jarbox_session_release(s);
        return 0;
    }
    return 1;
}
static inline void jarbox_session_worker_done(JarBoxSession *s) {
    if (!s) return;
    __atomic_sub_fetch(&s->java_workers, 1u, __ATOMIC_ACQ_REL);
    jarbox_session_release(s);
}
static inline unsigned jarbox_session_worker_count(const JarBoxSession *s) {
    return s ? __atomic_load_n(&s->java_workers, __ATOMIC_ACQUIRE) : 0u;
}
/* Only after all Java worker leases have returned. The owner releases its
 * ref after this call; independently pinned callbacks may release later. */
static inline int jarbox_session_mark_dead(JarBoxSession *s) {
    if (!s || jarbox_session_phase(s) < JARBOX_SESSION_STOPPING ||
        jarbox_session_worker_count(s)) return 0;
    __atomic_store_n(&s->phase, JARBOX_SESSION_DEAD, __ATOMIC_RELEASE);
    __atomic_store_n(&s->vm, NULL, __ATOMIC_RELEASE);
    return 1;
}
#endif
