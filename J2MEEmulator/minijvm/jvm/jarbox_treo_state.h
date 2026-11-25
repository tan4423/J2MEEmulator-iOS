#ifndef JARBOX_TREO_STATE_H
#define JARBOX_TREO_STATE_H

#include <stdint.h>

// Owned by one MiniJVM allocation and never shared with a different JVM.
// Atomic builtins allow the collector thread and the UIKit control thread
// to change the same session without unsynchronised field access.
// Runtime Treo policy, Canvas proof and GC belong to the session. Shared
// GPU/JAR profiling infrastructure remains outside this state.
typedef struct JarBoxTreoState {
    int afk_mode;
    int render_refresh;
    int render_needs_redraw;
    int guard_auto_enabled;
    int guard_auto_fallback;
    int deep_canvas_rejected; // sticky for the lifetime of this JVM
    uint64_t render_bypass_deadline_ns;
    uint64_t render_next_paint_ns;
    int probe_requested_ms;
    uint64_t probe_heap_peak;
    uint64_t probe_fallback_count;
    int smart_enabled;
    int smart_fallback;
    // Per-JVM NSO signature; do not let launching B change A's fast path.
    int nso_family_verified;
    int nso_init_target_active;
    int nso_canvas_seen;
    uint64_t nso_repaint_requests, nso_skips[3];
    uint64_t int_leaf_fast_calls; // batched count, all modes, per JVM
    uint64_t ref_leaf_fast_calls;
    uint64_t smart_heap_peak;
    uint64_t smart_cycles;
    uint64_t smart_cpu_ns;
} JarBoxTreoState;

static inline void jarbox_treo_mode_set(JarBoxTreoState *state, int mode) {
    __atomic_store_n(&state->afk_mode, mode, __ATOMIC_RELEASE);
}
static inline int jarbox_treo_mode_get(const JarBoxTreoState *state) {
    return state ? __atomic_load_n(&state->afk_mode, __ATOMIC_ACQUIRE) : 0;
}
/* All Canvas/native-Java decisions are owned by the invoking JVM. */
static inline void jarbox_treo_render_mode_set(JarBoxTreoState *s,
                                                int mode, uint64_t now_ns) {
    if (!s) return;
    if (mode == 6 || mode == 7) {
        __atomic_store_n(&s->render_next_paint_ns, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&s->render_bypass_deadline_ns,
                         now_ns ? now_ns + (mode == 7 ? UINT64_C(65000000000) :
                                            UINT64_C(60000000000)) : 0,
                         __ATOMIC_RELEASE);
    }
    if ((mode >= 2 && mode <= 4) || mode == 6 || mode == 7 || mode == 8)
        __atomic_store_n(&s->render_needs_redraw, 1, __ATOMIC_RELEASE);
    int prior = __atomic_exchange_n(&s->afk_mode, mode, __ATOMIC_ACQ_REL);
    if (mode) __atomic_store_n(&s->render_refresh, 0, __ATOMIC_RELEASE);
    else if (prior)
        __atomic_store_n(&s->render_refresh,
            __atomic_exchange_n(&s->render_needs_redraw, 0, __ATOMIC_ACQ_REL) ? 2 : 1,
            __ATOMIC_RELEASE);
}
static inline int jarbox_treo_render_take_refresh(JarBoxTreoState *s) {
    return s ? __atomic_exchange_n(&s->render_refresh, 0, __ATOMIC_ACQ_REL) : 0;
}
static inline void jarbox_treo_guard_auto_set(JarBoxTreoState *s, int enabled) {
    if (!s) return;
    __atomic_store_n(&s->guard_auto_enabled, 0, __ATOMIC_RELEASE);
    if (enabled) __atomic_store_n(&s->guard_auto_fallback, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&s->guard_auto_enabled, enabled != 0, __ATOMIC_RELEASE);
}
static inline int jarbox_treo_guard_fell_back(const JarBoxTreoState *s) {
    return s ? __atomic_load_n(&s->guard_auto_fallback, __ATOMIC_ACQUIRE) : 0;
}
static inline int jarbox_treo_guard_note_late(JarBoxTreoState *s) {
    if (!s || !__atomic_load_n(&s->guard_auto_enabled, __ATOMIC_ACQUIRE) ||
        jarbox_treo_mode_get(s) != 8) return 0;
    __atomic_store_n(&s->deep_canvas_rejected, 1, __ATOMIC_RELEASE);
    __atomic_store_n(&s->guard_auto_fallback, 1, __ATOMIC_RELEASE);
    return 1;
}
static inline void jarbox_treo_nso_profile_set(JarBoxTreoState *state,
                                               int family, int init_target) {
    if (!state) return;
    __atomic_store_n(&state->nso_init_target_active,
                     family && init_target ? 1 : 0, __ATOMIC_RELEASE);
    __atomic_store_n(&state->nso_family_verified, family != 0, __ATOMIC_RELEASE);
}
static inline int jarbox_treo_nso_family_verified(const JarBoxTreoState *state) {
    return state ? __atomic_load_n(&state->nso_family_verified, __ATOMIC_ACQUIRE) : 0;
}
static inline int jarbox_treo_nso_init_target_active(const JarBoxTreoState *state) {
    return state ? __atomic_load_n(&state->nso_init_target_active, __ATOMIC_ACQUIRE) : 0;
}
/* A different tab of the same JAR must independently prove its Canvas.
 * Archive recognition is necessary but not sufficient for NSO deep idle. */
static inline void jarbox_treo_nso_canvas_note(JarBoxTreoState *state) {
    if (jarbox_treo_nso_family_verified(state) &&
        !__atomic_load_n(&state->nso_canvas_seen, __ATOMIC_RELAXED))
        __atomic_store_n(&state->nso_canvas_seen, 1, __ATOMIC_RELEASE);
}
static inline int jarbox_treo_nso_canvas_recognized(const JarBoxTreoState *state) {
    return jarbox_treo_nso_family_verified(state) &&
           __atomic_load_n(&state->nso_canvas_seen, __ATOMIC_ACQUIRE);
}
// Cumulative per-session metrics, independent of the foreground tab.
static inline void jarbox_treo_nso_note_request(JarBoxTreoState *s) {
    if (s) __atomic_fetch_add(&s->nso_repaint_requests, 1, __ATOMIC_RELAXED);
}
static inline void jarbox_treo_nso_note_skip(JarBoxTreoState *s, int stage) {
    if (s && stage >= 0 && stage <= 2)
        __atomic_fetch_add(&s->nso_skips[stage], 1, __ATOMIC_RELAXED);
}
static inline uint64_t jarbox_treo_nso_skip_count(const JarBoxTreoState *s, int stage) {
    return s && stage >= 0 && stage <= 2 ?
        __atomic_load_n(&s->nso_skips[stage], __ATOMIC_RELAXED) : 0;
}
/* Configuration is shared by game identity on the UIKit side; the actual
 * mode is selected using this JVM's own proof. Unknown games fail safe. */
static inline int jarbox_treo_park_mode(const JarBoxTreoState *state, int compatible_only) {
    return !compatible_only && jarbox_treo_nso_canvas_recognized(state) &&
           !__atomic_load_n(&state->deep_canvas_rejected, __ATOMIC_ACQUIRE) ? 8 : 1;
}
static inline void jarbox_treo_probe_set(JarBoxTreoState *state, int requested) {
    __atomic_store_n(&state->probe_requested_ms, requested == 2000 ? 2000 : 0, __ATOMIC_RELEASE);
    __atomic_store_n(&state->probe_heap_peak, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&state->probe_fallback_count, 0, __ATOMIC_RELEASE);
}
static inline int jarbox_treo_probe_period(const JarBoxTreoState *state) {
    return __atomic_load_n(&state->probe_requested_ms, __ATOMIC_ACQUIRE);
}
static inline void jarbox_treo_probe_fallback(JarBoxTreoState *state) {
    __atomic_store_n(&state->probe_requested_ms, 0, __ATOMIC_RELEASE);
    __atomic_add_fetch(&state->probe_fallback_count, 1, __ATOMIC_RELAXED);
}
static inline void jarbox_treo_peak_note(uint64_t *field, uint64_t value) {
    uint64_t prior = __atomic_load_n(field, __ATOMIC_RELAXED);
    while (value > prior && !__atomic_compare_exchange_n(
               field, &prior, value, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {}
}
static inline void jarbox_treo_smart_set(JarBoxTreoState *state, int enabled) {
    if (enabled) {
        __atomic_store_n(&state->smart_fallback, 0, __ATOMIC_RELEASE);
        __atomic_store_n(&state->smart_heap_peak, 0, __ATOMIC_RELAXED);
        __atomic_store_n(&state->smart_cycles, 0, __ATOMIC_RELAXED);
        __atomic_store_n(&state->smart_cpu_ns, 0, __ATOMIC_RELAXED);
    }
    __atomic_store_n(&state->smart_enabled, enabled != 0, __ATOMIC_RELEASE);
}
static inline void jarbox_treo_smart_force_safe(JarBoxTreoState *state) {
    if (__atomic_load_n(&state->smart_enabled, __ATOMIC_ACQUIRE))
        __atomic_store_n(&state->smart_fallback, 1, __ATOMIC_RELEASE);
}
static inline int jarbox_treo_smart_period(const JarBoxTreoState *state) {
    return __atomic_load_n(&state->smart_enabled, __ATOMIC_ACQUIRE) &&
           !__atomic_load_n(&state->smart_fallback, __ATOMIC_ACQUIRE) &&
           __atomic_load_n(&state->afk_mode, __ATOMIC_ACQUIRE) != 0 ? 2000 : 500;
}
static inline void jarbox_treo_smart_note_heap(JarBoxTreoState *state, uint64_t bytes) {
    if (__atomic_load_n(&state->smart_enabled, __ATOMIC_ACQUIRE))
        jarbox_treo_peak_note(&state->smart_heap_peak, bytes);
}
static inline void jarbox_treo_smart_record_gc(JarBoxTreoState *state, uint64_t cpu_ns) {
    if (!__atomic_load_n(&state->smart_enabled, __ATOMIC_ACQUIRE)) return;
    __atomic_add_fetch(&state->smart_cpu_ns, cpu_ns, __ATOMIC_RELAXED);
    __atomic_add_fetch(&state->smart_cycles, 1, __ATOMIC_RELAXED);
}
#endif
