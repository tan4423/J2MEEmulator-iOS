#ifndef JARBOX_TREO_STATE_H
#define JARBOX_TREO_STATE_H

#include <stdint.h>

// Owned by one MiniJVM allocation and never shared with a different JVM.
// Atomic builtins allow the collector thread and the UIKit control thread
// to change the same session without unsynchronised field access.
// This first stage owns GC and an AFK-mode mirror; canvas, GPU, JAR worker,
// guarded-AFK and NSO state remain separate, blocking concurrent JVMs.
typedef struct JarBoxTreoState {
    int afk_mode;
    int probe_requested_ms;
    uint64_t probe_heap_peak;
    uint64_t probe_fallback_count;
    int smart_enabled;
    int smart_fallback;
    uint64_t smart_heap_peak;
    uint64_t smart_cycles;
    uint64_t smart_cpu_ns;
} JarBoxTreoState;

static inline void jarbox_treo_mode_set(JarBoxTreoState *state, int mode) {
    __atomic_store_n(&state->afk_mode, mode, __ATOMIC_RELEASE);
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
