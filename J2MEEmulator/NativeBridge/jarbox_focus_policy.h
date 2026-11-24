#ifndef JARBOX_FOCUS_POLICY_H
#define JARBOX_FOCUS_POLICY_H
/*
 * JarBox single-visible-session policy, independent of UIKit.
 *
 * The policy is NOT a VM executor: it never starts/stops Java threads or
 * changes global Treo flags. A native session coordinator must apply the
 * transition to per-VM render/input/Treo/GC contexts before multi-VM is
 * unlocked. This explicit policy prevents a UI implementation from showing
 * two tabs or silently promoting a background JVM when another closes.
 *
 * A zero visible token means library / black Treo cover: ALL running tabs
 * must be parked. Tokens are immutable, monotonically increasing VM IDs.
 */
#include <pthread.h>
#include <stdint.h>
#include <stddef.h>

#define JARBOX_FOCUS_MAX_SESSIONS 16

typedef struct {
    uint64_t token;
    int live;
    int parked; /* 0 = only foreground owner, 1 = native Treo requested */
} JarBoxFocusEntry;

typedef struct {
    pthread_mutex_t mutex;
    uint64_t visible_token;
    JarBoxFocusEntry entries[JARBOX_FOCUS_MAX_SESSIONS];
} JarBoxFocusPolicy;

#define JARBOX_FOCUS_POLICY_INITIALIZER { .mutex = PTHREAD_MUTEX_INITIALIZER }

static inline int jarbox_focus_register(JarBoxFocusPolicy *policy, uint64_t token) {
    if (!policy || !token) return 0;
    pthread_mutex_lock(&policy->mutex);
    int result = 0, empty = -1;
    for (int i = 0; i < JARBOX_FOCUS_MAX_SESSIONS; ++i) {
        JarBoxFocusEntry *entry = &policy->entries[i];
        if (entry->live && entry->token == token) goto out;
        if (!entry->live && empty < 0) empty = i;
    }
    if (empty >= 0) {
        JarBoxFocusEntry *entry = &policy->entries[empty];
        entry->token = token;
        entry->live = 1;
        /* Do not steal the foreground from any already selected session. */
        entry->parked = 1;
        result = 1;
    }
out:
    pthread_mutex_unlock(&policy->mutex);
    return result;
}

/* Only one foreground owner. All other registered sessions become parked. */
static inline int jarbox_focus_select(JarBoxFocusPolicy *policy, uint64_t token) {
    if (!policy || !token) return 0;
    pthread_mutex_lock(&policy->mutex);
    int found = 0;
    for (int i = 0; i < JARBOX_FOCUS_MAX_SESSIONS; ++i)
        if (policy->entries[i].live && policy->entries[i].token == token)
            found = 1;
    if (found) {
        policy->visible_token = token;
        for (int i = 0; i < JARBOX_FOCUS_MAX_SESSIONS; ++i) {
            JarBoxFocusEntry *e = &policy->entries[i];
            if (e->live) e->parked = (e->token != token);
        }
    }
    pthread_mutex_unlock(&policy->mutex);
    return found;
}

/* Park just this token. Parking A while B is visible must not blank B's
 * window. A stale token has no authority to mutate the focus policy. */
static inline int jarbox_focus_park_one(JarBoxFocusPolicy *policy, uint64_t token) {
    if (!policy || !token) return 0;
    pthread_mutex_lock(&policy->mutex);
    int found = 0;
    for (int i = 0; i < JARBOX_FOCUS_MAX_SESSIONS; ++i) {
        JarBoxFocusEntry *entry = &policy->entries[i];
        if (entry->live && entry->token == token) {
            entry->parked = 1;
            if (policy->visible_token == token) policy->visible_token = 0;
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&policy->mutex);
    return found;
}

/* Back -> library: every live VM stays alive but becomes parked. */
static inline void jarbox_focus_park_all(JarBoxFocusPolicy *policy) {
    if (!policy) return;
    pthread_mutex_lock(&policy->mutex);
    policy->visible_token = 0;
    for (int i = 0; i < JARBOX_FOCUS_MAX_SESSIONS; ++i)
        if (policy->entries[i].live) policy->entries[i].parked = 1;
    pthread_mutex_unlock(&policy->mutex);
}

/* Explicit stopping of one tab never stops/unparks any other tab. */
static inline int jarbox_focus_unregister(JarBoxFocusPolicy *policy, uint64_t token) {
    if (!policy || !token) return 0;
    pthread_mutex_lock(&policy->mutex);
    int removed = 0;
    for (int i = 0; i < JARBOX_FOCUS_MAX_SESSIONS; ++i) {
        JarBoxFocusEntry *e = &policy->entries[i];
        if (e->live && e->token == token) {
            e->token = 0;
            e->live = 0;
            e->parked = 0;
            removed = 1;
            break;
        }
    }
    if (policy->visible_token == token)
        policy->visible_token = 0;
    pthread_mutex_unlock(&policy->mutex);
    return removed;
}

/* One lock guards both a live flag and its parked state. */
static inline int jarbox_focus_is_parked(JarBoxFocusPolicy *policy,
                                         uint64_t token) {
    if (!policy || !token) return -1;
    pthread_mutex_lock(&policy->mutex);
    int status = -1;
    for (int i = 0; i < JARBOX_FOCUS_MAX_SESSIONS; ++i) {
        JarBoxFocusEntry *e = &policy->entries[i];
        if (e->live && e->token == token) { status = e->parked; break; }
    }
    pthread_mutex_unlock(&policy->mutex);
    return status; /* -1 unknown, 0 foreground, 1 parked */
}

static inline uint64_t jarbox_focus_visible(JarBoxFocusPolicy *policy) {
    if (!policy) return 0;
    pthread_mutex_lock(&policy->mutex);
    uint64_t token = policy->visible_token;
    pthread_mutex_unlock(&policy->mutex);
    return token;
}

static inline int jarbox_focus_live_count(JarBoxFocusPolicy *policy) {
    if (!policy) return 0;
    pthread_mutex_lock(&policy->mutex);
    int count = 0;
    for (int i = 0; i < JARBOX_FOCUS_MAX_SESSIONS; ++i)
        count += !!policy->entries[i].live;
    pthread_mutex_unlock(&policy->mutex);
    return count;
}

#endif
