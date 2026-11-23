#ifndef JARBOX_FLUSH_ROUTES_H
#define JARBOX_FLUSH_ROUTES_H
/* Frame callback routing by immutable native heap generation.
 * This table contains no Java pointers, UI objects or image ownership.
 * Every lookup copies a callback pointer while holding the table lock.
 * The callback must STILL verify the generation after queuing to UIKit. */
#include <pthread.h>
#include <stdint.h>

#define JARBOX_FLUSH_MAX_ROUTES 8
typedef void (*JarBoxFlushLegacy)(void *image, int width, int height);
typedef void (*JarBoxFlushOwned)(void *image, int width, int height, uint64_t owner);
typedef struct {
    uint64_t owner_key;
    JarBoxFlushLegacy legacy;
    JarBoxFlushOwned owned;
} JarBoxFlushRoute;
typedef struct {
    pthread_mutex_t lock;
    JarBoxFlushLegacy default_legacy;
    JarBoxFlushOwned default_owned;
    JarBoxFlushRoute entries[JARBOX_FLUSH_MAX_ROUTES];
} JarBoxFlushRoutes;
#define JARBOX_FLUSH_ROUTES_INITIALIZER { .lock = PTHREAD_MUTEX_INITIALIZER }

static inline void jarbox_flush_default_legacy(JarBoxFlushRoutes *r,
                                                JarBoxFlushLegacy fn) {
    if (!r) return;
    pthread_mutex_lock(&r->lock);
    r->default_legacy = fn;
    pthread_mutex_unlock(&r->lock);
}
static inline void jarbox_flush_default_owned(JarBoxFlushRoutes *r,
                                               JarBoxFlushOwned fn) {
    if (!r) return;
    pthread_mutex_lock(&r->lock);
    r->default_owned = fn;
    pthread_mutex_unlock(&r->lock);
}
/* Capture the callback function for this owner at registration, not at flush.
 * A newer Tab may change the default without mutating A's callback route. */
static inline int jarbox_flush_route_bind(JarBoxFlushRoutes *r, uint64_t key) {
    if (!r || !key) return 0;
    pthread_mutex_lock(&r->lock);
    int empty = -1, result = 0;
    for (int i = 0; i < JARBOX_FLUSH_MAX_ROUTES; ++i) {
        if (r->entries[i].owner_key == key) goto done;
        if (!r->entries[i].owner_key && empty < 0) empty = i;
    }
    if (empty >= 0 && (r->default_owned || r->default_legacy)) {
        r->entries[empty] = (JarBoxFlushRoute){key, r->default_legacy,
                                                   r->default_owned};
        result = 1;
    }
done:
    pthread_mutex_unlock(&r->lock);
    return result;
}
static inline int jarbox_flush_route_lookup(JarBoxFlushRoutes *r,
                                             uint64_t key,
                                             JarBoxFlushLegacy *legacy,
                                             JarBoxFlushOwned *owned) {
    if (legacy) *legacy = NULL;
    if (owned) *owned = NULL;
    if (!r || !key || !legacy || !owned) return 0;
    pthread_mutex_lock(&r->lock);
    int found = 0;
    for (int i = 0; i < JARBOX_FLUSH_MAX_ROUTES; ++i) {
        const JarBoxFlushRoute *e = &r->entries[i];
        if (e->owner_key == key) {
            *legacy = e->legacy;
            *owned = e->owned;
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&r->lock);
    return found;
}
/* Stop A must never remove B's callback, even if A's VM address is reused. */
static inline int jarbox_flush_route_unbind(JarBoxFlushRoutes *r, uint64_t key) {
    if (!r || !key) return 0;
    pthread_mutex_lock(&r->lock);
    int found = 0;
    for (int i = 0; i < JARBOX_FLUSH_MAX_ROUTES; ++i)
        if (r->entries[i].owner_key == key) {
            r->entries[i] = (JarBoxFlushRoute){0};
            found = 1;
            break;
        }
    pthread_mutex_unlock(&r->lock);
    return found;
}
#endif
