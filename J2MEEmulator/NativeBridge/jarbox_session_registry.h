#ifndef JARBOX_SESSION_REGISTRY_H
#define JARBOX_SESSION_REGISTRY_H
#include <pthread.h>
#include <stdint.h>
#include "jarbox_session.h"
#include "jarbox_focus_policy.h"

/* Two structural slots for a future experiment. The bridge must use
 * max_live=1 until renderer, Treo/Canvas and native resources are isolated. */
#define JARBOX_REGISTRY_MAX_SLOTS 2
typedef struct {
    uint64_t token;
    JarBoxSession *session; /* owned reference through final retirement */
    void *vm;              /* non-owning; usable only with callback lease */
    int stop_requested;
} JarBoxRegistryEntry;
typedef struct {
    pthread_mutex_t mutex;
    JarBoxRegistryEntry entries[JARBOX_REGISTRY_MAX_SLOTS];
} JarBoxSessionRegistry;
#define JARBOX_SESSION_REGISTRY_INITIALIZER { .mutex = PTHREAD_MUTEX_INITIALIZER }

static inline int jarbox_registry_claim(JarBoxSessionRegistry *r,
                                        JarBoxFocusPolicy *focus,
                                        uint64_t token, unsigned max_live) {
    if (!r || !focus || !token || !max_live || max_live > JARBOX_REGISTRY_MAX_SLOTS)
        return 0;
    pthread_mutex_lock(&r->mutex);
    unsigned used = 0;
    int empty = -1, result = 0;
    for (int i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        if (r->entries[i].token == token) goto done;
        if (r->entries[i].token) ++used;
        else if (empty < 0) empty = i;
    }
    if (used >= max_live || empty < 0 || !jarbox_focus_register(focus, token))
        goto done;
    r->entries[empty] = (JarBoxRegistryEntry){.token = token};
    result = 1;
done:
    pthread_mutex_unlock(&r->mutex);
    return result;
}
static inline int jarbox_registry_bind(JarBoxSessionRegistry *r,
                                       uint64_t token, JarBoxSession *s) {
    if (!r || !token || !s || !s->vm ||
        __atomic_load_n(&s->token, __ATOMIC_ACQUIRE) != token ||
        jarbox_session_phase(s) >= JARBOX_SESSION_STOPPING) return 0;
    pthread_mutex_lock(&r->mutex);
    int result = 0;
    for (int i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxRegistryEntry *entry = &r->entries[i];
        if (entry->token != token) continue;
        // A stop request during STARTING does not destroy the VM. Bind the
        // newly initialized JVM even when cancellation is already pending,
        // so its owner can still unwind and retire the registry entry safely.
        // pin_vm() continues to reject callbacks after stop_requested.
        if (entry->session) break;
        /* Never bind identical live JVM pointers to different generations. */
        for (int j = 0; j < JARBOX_REGISTRY_MAX_SLOTS; ++j)
            if (j != i && r->entries[j].vm == s->vm) goto done;
        __atomic_add_fetch(&s->references, 1u, __ATOMIC_ACQ_REL);
        entry->session = s;
        entry->vm = s->vm;
        result = 1;
        break;
    }
done:
    pthread_mutex_unlock(&r->mutex);
    return result;
}
static inline int jarbox_registry_request_stop(JarBoxSessionRegistry *r,
                                               uint64_t token) {
    if (!r || !token) return 0;
    pthread_mutex_lock(&r->mutex);
    int result = 0;
    for (int i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i)
        if (r->entries[i].token == token) {
            r->entries[i].stop_requested = 1;
            result = 1;
            break;
        }
    pthread_mutex_unlock(&r->mutex);
    return result;
}
/* Called for actual teardown, not a UI stop request: Java must first unwind. */
static inline void jarbox_registry_begin_stop(JarBoxSessionRegistry *r,
                                              uint64_t token) {
    if (!r || !token) return;
    pthread_mutex_lock(&r->mutex);
    for (int i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i)
        if (r->entries[i].token == token) {
            r->entries[i].stop_requested = 1;
            if (r->entries[i].session)
                jarbox_session_begin_stop(r->entries[i].session);
            break;
        }
    pthread_mutex_unlock(&r->mutex);
}
/* Returns a VM with a native callback lease; caller MUST call
 * jarbox_session_callback_done(*held) after the last VM access. */
static inline void *jarbox_registry_pin_vm(JarBoxSessionRegistry *r,
                                           uint64_t token, JarBoxSession **held) {
    if (held) *held = NULL;
    if (!r || !token || !held) return NULL;
    pthread_mutex_lock(&r->mutex);
    void *vm = NULL;
    for (int i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxRegistryEntry *e = &r->entries[i];
        if (e->token == token && e->session && e->vm && !e->stop_requested &&
            jarbox_session_reserve_callback(e->session)) {
            *held = e->session;
            vm = e->vm;
            break;
        }
    }
    pthread_mutex_unlock(&r->mutex);
    return vm;
}
/* A UI controller keeps a generation token, never an unleased VM pointer.
 * Claimed STARTING slots count as live; STOPPING remains live until finish. */
static inline int jarbox_registry_contains_token(JarBoxSessionRegistry *r,
                                                  uint64_t token) {
    if (!r || !token) return 0;
    pthread_mutex_lock(&r->mutex);
    int found = 0;
    for (int i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i)
        if (r->entries[i].token == token) { found = 1; break; }
    pthread_mutex_unlock(&r->mutex);
    return found;
}
/* Java may poll stop from a non-UI pthread. Resolve by the *actual* VM
 * address in a registry-protected generation binding, never foreground B.
 * Missing/retired/STOPPING bindings must fail closed. */
static inline int jarbox_registry_should_stop_vm(JarBoxSessionRegistry *r,
                                                 const void *vm) {
    if (!r || !vm) return 1;
    pthread_mutex_lock(&r->mutex);
    int stop = 1;
    for (int i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        const JarBoxRegistryEntry *e = &r->entries[i];
        if (e->token && e->session && e->vm == vm) {
            stop = e->stop_requested ||
                jarbox_session_phase(e->session) >= JARBOX_SESSION_STOPPING;
            break;
        }
    }
    pthread_mutex_unlock(&r->mutex);
    return stop;
}
static inline int jarbox_registry_active_count(JarBoxSessionRegistry *r) {
    if (!r) return 0;
    pthread_mutex_lock(&r->mutex);
    int count = 0;
    for (int i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i)
        if (r->entries[i].token) ++count;
    pthread_mutex_unlock(&r->mutex);
    return count;
}
/* Retire only a DEAD session whose VM pointer is null and leases are drained.
 * A stuck heap occupies the slot, preventing unsafe automatic restart. */
static inline int jarbox_registry_finish(JarBoxSessionRegistry *r,
                                         JarBoxFocusPolicy *focus, uint64_t token) {
    if (!r || !focus || !token) return 0;
    pthread_mutex_lock(&r->mutex);
    int ok = 0;
    JarBoxSession *retired = NULL;
    for (int i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxRegistryEntry *e = &r->entries[i];
        if (e->token != token) continue;
        if (e->session &&
            (jarbox_session_phase(e->session) != JARBOX_SESSION_DEAD ||
             __atomic_load_n(&e->session->vm, __ATOMIC_ACQUIRE) != NULL ||
             jarbox_session_active_lease_count(e->session) != 0)) break;
        if (!jarbox_focus_unregister(focus, token)) break;
        retired = e->session;
        *e = (JarBoxRegistryEntry){0};
        ok = 1;
        break;
    }
    pthread_mutex_unlock(&r->mutex);
    if (retired) jarbox_session_release(retired);
    return ok;
}
#endif
