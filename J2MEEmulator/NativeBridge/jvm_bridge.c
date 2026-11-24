#include "jvm_bridge.h"
#include "jarbox_focus_policy.h"
#include "jarbox_session_registry.h"
#include "jvm.h"
#include "jvm_util.h"
#include "garbage.h"
#include "j2me_render.h"
#include "j2me_input.h"
#include "j2me_ui.h"
#include "j2me_audio.h"
#include "j2me_micro3d_gl.h"
#include "m3g/j2me_m3g.h"
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_NINJA_DEEP_DISABLED)
#include "miniz.h"
#endif

static atomic_int treo_exact_ninja_verified;
// Per-JAR launch diagnostic gate (NOT a Deep Treo optimization flag).
// Check exact Java class paths once in the archive; avoid name probing on
// 10,000s of VM calls/sec for other JARs, including original NSO.
_Atomic int treo_nso_init_target_active;
int treo_ninja_deep_verified(void) {
    return atomic_load_explicit(&treo_exact_ninja_verified, memory_order_acquire);
}
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_NINJA_DEEP_DISABLED)
/*
 * NSO-family identification is based on stable game resource layout, not
 * exact JAR hashes or obfuscated class names. The separate runtime Canvas
 * bytecode-shape guard prevents a similar asset bundle with different paint
 * behavior from blindly inheriting this optimization.
 *
 * One archive read at MIDlet load; no ZIP or disk work in the Treo hot loop.
 */
static int treo_is_nso_family(const char *jar_path, int *init_target) {
    *init_target = 0;
    static const char *const resources[] = {
        "font/number",
        "font/tahoma_7",
        "map/1",
        "map/newmap",
        "x1/bg/bg00.png",
        "x1/export/0",
        "x1/e/d00.png"
    };
    if (!jar_path) return 0;
    mz_zip_archive archive = {0};
    if (!mz_zip_reader_init_file(&archive, jar_path, 0)) return 0;
    // A mod may add/remove a few resources. Five of seven independent
    // signature assets plus map and sprite categories is sufficient.
    // The loaded Canvas bytecode shape is verified separately before skipping.
    unsigned matched = 0;
    int has_map = 0, has_sprite = 0;
    for (unsigned i = 0; i < sizeof(resources) / sizeof(resources[0]); ++i) {
        int index = mz_zip_reader_locate_file(
            &archive, resources[i], NULL, MZ_ZIP_FLAG_CASE_SENSITIVE);
        mz_zip_archive_file_stat file_stat;
        if (index >= 0 &&
            mz_zip_reader_file_stat(&archive, index, &file_stat) &&
            file_stat.m_uncomp_size != 0 &&
            !mz_zip_reader_is_file_a_directory(&archive, index)) {
            matched++;
            if (i == 2 || i == 3) has_map = 1;
            if (i >= 4) has_sprite = 1;
        }
    }
    const int family = matched >= 5 && has_map && has_sprite;
    if (family) {
        const char *const target_classes[] = {
            "GameMidlet.class", "Class_cu.class", "Class_ek.class"
        };
        int found = 0;
        for (unsigned i = 0; i < sizeof(target_classes) / sizeof(target_classes[0]); ++i)
            found += mz_zip_reader_locate_file(&archive, target_classes[i], NULL,
                                              MZ_ZIP_FLAG_CASE_SENSITIVE) >= 0;
        *init_target = found == 3;
    }
    mz_zip_reader_end(&archive);
    return family;
}

#endif


// Native executor storage is now a real slot pool, distinct from the
// session registry (which owns lifetime pins). Allocation/retirement and
// worker admission are serialized by g_bridge_lifecycle_lock. Capacity of
// storage is NOT the admitted runtime capacity; the public gate stays 1.
enum { BRIDGE_IDLE = 0, BRIDGE_STARTING = 1, BRIDGE_RUNNING = 2,
       BRIDGE_CLEANUP = 3 };
typedef struct {
    _Atomic(MiniJVM *) jvm;
    atomic_int stop_requested;
    atomic_int active;
    atomic_int phase;
    _Atomic uint64_t token;
    int worker_busy; // lifecycle lock; prevents release/reuse during an API call
} JarBoxVMContext;
static JarBoxVMContext g_bridge_slots[JARBOX_REGISTRY_MAX_SLOTS];

// All *_locked helpers require the lifecycle lock, including host tests.
static JarBoxVMContext *bridge_find_slot_locked(uint64_t token) {
    if (!token) return NULL;
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxVMContext *slot = &g_bridge_slots[i];
        if (atomic_load_explicit(&slot->active, memory_order_acquire) &&
            atomic_load_explicit(&slot->token, memory_order_acquire) == token)
            return slot;
    }
    return NULL;
}
static JarBoxVMContext *bridge_reserve_slot_locked(uint64_t token, unsigned limit) {
    if (!token || !limit || limit > JARBOX_REGISTRY_MAX_SLOTS ||
        bridge_find_slot_locked(token)) return NULL;
    unsigned used = 0;
    JarBoxVMContext *empty = NULL;
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxVMContext *slot = &g_bridge_slots[i];
        if (atomic_load_explicit(&slot->active, memory_order_acquire)) ++used;
        else if (!empty) empty = slot;
    }
    if (used >= limit || !empty) return NULL;
    atomic_store_explicit(&empty->jvm, NULL, memory_order_release);
    atomic_store_explicit(&empty->stop_requested, 0, memory_order_release);
    atomic_store_explicit(&empty->phase, BRIDGE_STARTING, memory_order_release);
    atomic_store_explicit(&empty->token, token, memory_order_release);
    empty->worker_busy = 0;
    atomic_store_explicit(&empty->active, 1, memory_order_release);
    return empty;
}
static int bridge_slot_can_retire_locked(const JarBoxVMContext *slot) {
    return slot && !slot->worker_busy &&
        !atomic_load_explicit(&slot->jvm, memory_order_acquire);
}
static void bridge_reset_slot_locked(JarBoxVMContext *slot) {
    atomic_store_explicit(&slot->phase, BRIDGE_IDLE, memory_order_release);
    atomic_store_explicit(&slot->stop_requested, 0, memory_order_release);
    atomic_store_explicit(&slot->token, 0, memory_order_release);
    atomic_store_explicit(&slot->active, 0, memory_order_release);
}
static JarBoxVMContext *bridge_claim_worker_locked(uint64_t token) {
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    if (!slot || slot->worker_busy) return NULL;
    slot->worker_busy = 1;
    return slot;
}
static void bridge_release_worker_locked(JarBoxVMContext *slot) {
    slot->worker_busy = 0;
}

// Tokens are never reused, even when this context is reset and acquired again.
static _Atomic uint64_t g_bridge_session_sequence;
/* Native Java Threads do not inherit the Swift launch worker's TLS.
 * Bind each Java worker explicitly to its immutable session token so
 * native callbacks never infer identity from the visible window.
 * A token alone never pins a heap: all lookups still require a lease. */
static _Thread_local uint64_t g_bridge_java_thread_token;
uint64_t jvm_bridge_thread_token(void) {
    return g_bridge_java_thread_token;
}
uint64_t jvm_bridge_push_java_thread_token(uint64_t token) {
    uint64_t previous = g_bridge_java_thread_token;
    g_bridge_java_thread_token = token;
    return previous;
}
void jvm_bridge_pop_java_thread_token(uint64_t previous) {
    g_bridge_java_thread_token = previous;
}
// One visible window; every other live tab remains parked (never stopped).
static JarBoxFocusPolicy g_bridge_focus = JARBOX_FOCUS_POLICY_INITIALIZER;
// Registry owns a session pin per token; runtime cap stays one until the
// native render, Treo, UI, audio and 3D state becomes fully isolated.
static JarBoxSessionRegistry g_bridge_registry = JARBOX_SESSION_REGISTRY_INITIALIZER;
// Protect the JVM pointer/phase while the cancellation watchdog interrupts
// Java threads; normal VM execution never takes this mutex.
static pthread_mutex_t g_bridge_lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
// Serialize native focus/park publication against cleanup admission closure.
// Lock order: focus transition -> lifecycle -> registry. Never hold this
// mutex while joining Java threads or waiting for the heap lease gate.
static pthread_mutex_t g_bridge_focus_transition_lock = PTHREAD_MUTEX_INITIALIZER;
static JarBoxVMContext *bridge_claim_worker(uint64_t token) {
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_claim_worker_locked(token);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return slot;
}
static void bridge_release_worker(JarBoxVMContext *slot) {
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    bridge_release_worker_locked(slot);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
}
// Bridge diagnostics are separate from the JVM heap and from the lifecycle
// mutex. A Java callback may report a diagnostic while a stop watchdog holds
// the lifecycle lock, so diagnostic lookup must never acquire that lock.
typedef struct {
    uint64_t token;
    char last_error[1536];
    char nso_init_trace[4096];
    char net_trace[8192];
    unsigned nso_init_trace_count, net_trace_count;
    uint64_t popup_ticks, stage_counts[5];
    int last_stage;
    unsigned early_exception_notes, loop_exception_notes, dispatch_notes;
    unsigned method_missing_notes, protocol_notes;
} JarBoxBridgeDiagnostics;
static JarBoxBridgeDiagnostics g_bridge_diagnostics[JARBOX_REGISTRY_MAX_SLOTS];
static pthread_mutex_t g_bridge_diag_lock = PTHREAD_MUTEX_INITIALIZER;

/* Call with g_bridge_diag_lock held. A missing explicit token never resolves
 * to another owner. Legacy owner-less reads resolve only a sole live record. */
static JarBoxBridgeDiagnostics *bridge_diag_find_locked(uint64_t token) {
    JarBoxBridgeDiagnostics *sole = NULL;
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxBridgeDiagnostics *entry = &g_bridge_diagnostics[i];
        if (!entry->token) continue;
        if (token && entry->token == token) return entry;
        if (!token) {
            if (sole) return NULL;
            sole = entry;
        }
    }
    return token ? NULL : sole;
}
static int bridge_diag_begin_locked(uint64_t token) {
    if (!token || bridge_diag_find_locked(token)) return 0;
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxBridgeDiagnostics *entry = &g_bridge_diagnostics[i];
        if (!entry->token) {
            memset(entry, 0, sizeof(*entry));
            entry->token = token;
            return 1;
        }
    }
    return 0;
}
static void bridge_diag_end_locked(uint64_t token) {
    JarBoxBridgeDiagnostics *entry = token ? bridge_diag_find_locked(token) : NULL;
    if (entry) memset(entry, 0, sizeof(*entry));
}
static int bridge_diag_begin(uint64_t token) {
    pthread_mutex_lock(&g_bridge_diag_lock);
    const int ok = bridge_diag_begin_locked(token);
    pthread_mutex_unlock(&g_bridge_diag_lock);
    return ok;
}
static void bridge_diag_end(uint64_t token) {
    pthread_mutex_lock(&g_bridge_diag_lock);
    bridge_diag_end_locked(token);
    pthread_mutex_unlock(&g_bridge_diag_lock);
}
static uint64_t bridge_diag_token_hint(void) {
    const uint64_t token = jvm_bridge_thread_token();
    return token ? token : jvm_bridge_visible_session_token();
}
// The focus lock is acquired before, not while holding the diagnostic lock.
// No pointer is returned to a caller outside the diagnostic critical section.
static JarBoxBridgeDiagnostics *bridge_diag_lock_current(void) {
    const uint64_t token = bridge_diag_token_hint();
    pthread_mutex_lock(&g_bridge_diag_lock);
    return bridge_diag_find_locked(token);
}
static void bridge_diag_unlock(void) {
    pthread_mutex_unlock(&g_bridge_diag_lock);
}
static int bridge_diag_take_budget(unsigned *counter, unsigned limit) {
    if (!counter || *counter >= limit) return 0;
    ++*counter;
    return 1;
}
int jvm_bridge_early_exception_note_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->early_exception_notes, 12);
    bridge_diag_unlock();
    return ok;
}
int jvm_bridge_mod_protocol_note_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->protocol_notes, 20);
    bridge_diag_unlock();
    return ok;
}
int jvm_bridge_mod_dispatch_probe_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->dispatch_notes, 2);
    bridge_diag_unlock();
    return ok;
}
int jvm_bridge_mod_method_missing_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->method_missing_notes, 10);
    bridge_diag_unlock();
    return ok;
}
void jvm_bridge_mod_loop_note_stage(int stage) {
    if (stage < 1 || stage > 4) return;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry) {
        entry->last_stage = stage;
        ++entry->stage_counts[stage];
    }
    bridge_diag_unlock();
}
uint64_t jvm_bridge_mod_loop_stage_count(int stage) {
    if (stage < 1 || stage > 4) return 0;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    uint64_t count = entry ? entry->stage_counts[stage] : 0;
    bridge_diag_unlock();
    return count;
}
int jvm_bridge_mod_loop_last_stage(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int stage = entry ? entry->last_stage : 0;
    bridge_diag_unlock();
    return stage;
}
int jvm_bridge_mod_loop_exception_log_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->loop_exception_notes, 12);
    bridge_diag_unlock();
    return ok;
}
void jvm_bridge_mod_popup_tick(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry) ++entry->popup_ticks;
    bridge_diag_unlock();
}
uint64_t jvm_bridge_mod_popup_tick_count(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    uint64_t count = entry ? entry->popup_ticks : 0;
    bridge_diag_unlock();
    return count;
}
static void bridge_diag_append(char *buffer, size_t size, unsigned *count,
                               unsigned limit, const char *separator,
                               const char *detail) {
    if (*count >= limit) return;
    size_t len = strlen(buffer);
    size_t avail = size - len;
    if (avail <= strlen(separator) + 1) return;
    int added = snprintf(buffer + len, avail, "%s%s", len ? separator : "", detail);
    if (added > 0) ++*count;
}
void jvm_bridge_note_net_trace(const char *detail) {
    if (!detail || !detail[0]) return;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry)
        bridge_diag_append(entry->net_trace, sizeof(entry->net_trace),
                           &entry->net_trace_count, 64, "\n", detail);
    bridge_diag_unlock();
    printf("[JarBoxNET] %s\n", detail);
}
void jvm_bridge_note_nso_init_trace(const char *detail) {
    if (!detail || !detail[0]) return;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry)
        bridge_diag_append(entry->nso_init_trace, sizeof(entry->nso_init_trace),
                           &entry->nso_init_trace_count, 20, " | ", detail);
    bridge_diag_unlock();
    printf("[JarBoxVM][NSOInit] %s\n", detail);
}
void jvm_bridge_set_launch_error(const char *message) {
    if (!message) return;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry) snprintf(entry->last_error, sizeof(entry->last_error), "%s", message);
    bridge_diag_unlock();
    printf("[JarBoxVM][LaunchError] %s\n", message);
}
// Explicit per-worker snapshots outlive the critical section, not the caller.
// TLS arrays avoid returning a pointer into a reusable executor record.
static const char *bridge_diag_snapshot(uint64_t token, int kind, int explicit_token) {
    static _Thread_local char snapshot[8192];
    snapshot[0] = '\0';
    if (explicit_token && !token) return snapshot;
    pthread_mutex_lock(&g_bridge_diag_lock);
    JarBoxBridgeDiagnostics *entry = bridge_diag_find_locked(token);
    if (entry) {
        const char *value = kind == 0 ? entry->last_error :
                            kind == 1 ? entry->nso_init_trace : entry->net_trace;
        snprintf(snapshot, sizeof(snapshot), "%s", value);
    }
    pthread_mutex_unlock(&g_bridge_diag_lock);
    return snapshot;
}
const char *jvm_bridge_last_error_for_token(uint64_t token) {
    return bridge_diag_snapshot(token, 0, 1);
}
const char *jvm_bridge_nso_init_trace_for_token(uint64_t token) {
    return bridge_diag_snapshot(token, 1, 1);
}
const char *jvm_bridge_net_trace_for_token(uint64_t token) {
    return bridge_diag_snapshot(token, 2, 1);
}
const char *jvm_bridge_last_error(void) {
    return bridge_diag_snapshot(bridge_diag_token_hint(), 0, 0);
}
const char *jvm_bridge_nso_init_trace(void) {
    return bridge_diag_snapshot(bridge_diag_token_hint(), 1, 0);
}
const char *jvm_bridge_net_trace(void) {
    return bridge_diag_snapshot(bridge_diag_token_hint(), 2, 0);
}

/* Every launch receives its immutable token in the SAME admission call.
 * Never ask the asynchronous Swift worker to discover its owner by reading
 * the process's latest foreground token. The current runtime still has one
 * execution slot; this is a lifetime-safe contract for its future pool. */
int jvm_bridge_try_begin_session_with_token(uint64_t *out_token) {
    if (!out_token) return 0;
    *out_token = 0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    const uint64_t token = atomic_fetch_add_explicit(
        &g_bridge_session_sequence, 1, memory_order_relaxed) + 1;
    JarBoxVMContext *slot = bridge_reserve_slot_locked(
        token, (unsigned)jvm_bridge_supported_concurrent_sessions());
    if (!slot) {
        pthread_mutex_unlock(&g_bridge_lifecycle_lock);
        return 0;
    }
    if (!jarbox_registry_claim(&g_bridge_registry, &g_bridge_focus,
                               token, (unsigned)jvm_bridge_supported_concurrent_sessions())) {
        bridge_reset_slot_locked(slot);
        pthread_mutex_unlock(&g_bridge_lifecycle_lock);
        return 0;
    }
    if (!bridge_diag_begin(token)) {
        (void)jarbox_registry_finish(&g_bridge_registry, &g_bridge_focus, token);
        bridge_reset_slot_locked(slot);
        pthread_mutex_unlock(&g_bridge_lifecycle_lock);
        return 0;
    }
    (void)jarbox_focus_select(&g_bridge_focus, token);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    // Visible from the first frame in Chẩn đoán kết nối, regardless of
    // which Java network API the game calls. Detects an older installed IPA.
    const uint64_t prior_token = jvm_bridge_push_java_thread_token(token);
    jvm_bridge_note_net_trace("probe:java8_utf8_boot_patch=v1");
    jvm_bridge_note_net_trace("probe:java8_localtime_boot_patch=v1");
    jvm_bridge_note_net_trace("probe:vm_opcode_guard=v1");
    jvm_bridge_pop_java_thread_token(prior_token);
    printf("[JarBoxVM][Lifecycle] session=acquired phase=starting\n");
    *out_token = token;
    return 1;
}
int jvm_bridge_try_begin_session(void) {
    uint64_t acquired = 0;
    return jvm_bridge_try_begin_session_with_token(&acquired);
}
/* Token-based synchronous VM pin. The lifecycle lock establishes a
 * consistent admission point; the callback lease keeps the heap alive while
 * UIKit/render/input callbacks finish, even when teardown starts meanwhile.
 * STARTING slots are parked in the policy without dereferencing a half-built
 * MiniJVM. Still single-live until the executor and UIKit routing are split. */
static MiniJVM *bridge_pin_running_owner(uint64_t token, JarBoxSession **held) {
    if (held) *held = NULL;
    if (!token || !held) return NULL;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    const int matches = slot &&
        atomic_load_explicit(&slot->phase, memory_order_acquire) == BRIDGE_RUNNING;
    MiniJVM *vm = matches ?
        (MiniJVM *)jarbox_registry_pin_vm(&g_bridge_registry, token, held) : NULL;
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return vm;
}
int jvm_bridge_park_session(uint64_t token) {
    pthread_mutex_lock(&g_bridge_focus_transition_lock);
    if (!jarbox_registry_contains_token(&g_bridge_registry, token)) {
        pthread_mutex_unlock(&g_bridge_focus_transition_lock);
        return 0;
    }
    JarBoxSession *held = NULL;
    MiniJVM *owner = bridge_pin_running_owner(token, &held);
    // The visible framebuffer is revoked before any deferred UIKit flush.
    // A STARTING VM has no published renderer to release yet.
    if (owner) {
        j2me_render_release_vm(owner);
        j2me_input_park_vm(owner);
        j2me_ui_park_vm(owner);
    }
    const int parked = jarbox_focus_park_one(&g_bridge_focus, token);
    if (owner) {
        if (parked) (void)jarbox_session_park(held);
        jarbox_session_callback_done(held);
    }
    pthread_mutex_unlock(&g_bridge_focus_transition_lock);
    return parked;
}

int jvm_bridge_focus_session(uint64_t token) {
    // A tab coordinator must park the previous owner before selecting B.
    pthread_mutex_lock(&g_bridge_focus_transition_lock);
    const uint64_t visible = jarbox_focus_visible(&g_bridge_focus);
    if (visible && visible != token) {
        pthread_mutex_unlock(&g_bridge_focus_transition_lock);
        return 0;
    }
    JarBoxSession *held = NULL;
    MiniJVM *owner = bridge_pin_running_owner(token, &held);
    if (!owner) {
        pthread_mutex_unlock(&g_bridge_focus_transition_lock);
        return 0;
    }
    // Renderer, input and LCDUI must agree on the same owner generation.
    // No callback may retain this raw pointer beyond the lease below.
    const int ready = j2me_render_focus_vm(owner) &&
                      j2me_input_focus_vm(owner) &&
                      j2me_ui_focus_vm(owner);
    const int selected = ready ? jarbox_focus_select(&g_bridge_focus, token) : 0;
    if (selected) {
        (void)jarbox_session_enter_foreground(held);
    } else {
        // A partial native focus acquisition must not leave an input or
        // framebuffer destination attached to a hidden/failed controller.
        j2me_render_release_vm(owner);
        j2me_input_park_vm(owner);
        j2me_ui_park_vm(owner);
        (void)jarbox_focus_park_one(&g_bridge_focus, token);
    }
    jarbox_session_callback_done(held);
    pthread_mutex_unlock(&g_bridge_focus_transition_lock);
    return selected;
}

int jvm_bridge_session_is_parked(uint64_t token) {
    return jarbox_focus_is_parked(&g_bridge_focus, token);
}
uint64_t jvm_bridge_visible_session_token(void) {
    return jarbox_focus_visible(&g_bridge_focus);
}

// UI diagnostics and automatic Treo actions execute on a different thread
// from the collector. Pin the live JVM under the lifecycle lock; teardown
// transitions phase to CLEANUP under the same lock before destroying memory.
// NEVER return the VM pointer to an asynchronous caller.
int jvm_bridge_visit_running_vm_for_token(
        uint64_t token, void (*visitor)(MiniJVM *, void *), void *arg) {
    if (!token || !visitor) return 0;
    JarBoxSession *held_session = NULL;
    MiniJVM *vm = bridge_pin_running_owner(token, &held_session);
    // The callback lease, not a mutable slot pointer, protects this VM.
    if (!vm) return 0;
    visitor(vm, arg);
    jarbox_session_callback_done(held_session);
    return 1;
}
void jvm_bridge_visit_running_vm(void (*visitor)(MiniJVM *, void *), void *arg) {
    (void)jvm_bridge_visit_running_vm_for_token(jvm_bridge_session_token(),
                                                visitor, arg);
}

int jvm_bridge_session_phase(void) {
    const uint64_t token = jvm_bridge_session_token();
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    const int phase = slot ? atomic_load_explicit(&slot->phase, memory_order_acquire) : BRIDGE_IDLE;
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return phase;
}
int jvm_bridge_session_is_active(void) {
    return jarbox_registry_active_count(&g_bridge_registry) != 0;
}
int jvm_bridge_session_is_active_for_token(uint64_t token) {
    return jarbox_registry_contains_token(&g_bridge_registry, token);
}
// Real runtime capacity, not the number of preallocated input contexts.
// Raise this only after rendering/UI/Treo/GC/3D isolation is proven.
int jvm_bridge_supported_concurrent_sessions(void) {
    return 1;
}
int jvm_bridge_active_session_count(void) {
    return jarbox_registry_active_count(&g_bridge_registry);
}
uint64_t jvm_bridge_session_token(void) {
    const uint64_t bound = jvm_bridge_thread_token();
    if (bound) return bound;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    uint64_t token = jarbox_focus_visible(&g_bridge_focus);
    if (!bridge_find_slot_locked(token)) {
        // When the sole game is parked, old diagnostics still target it.
        // With several parked games an owner-less query must fail closed.
        token = 0;
        for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
            JarBoxVMContext *slot = &g_bridge_slots[i];
            if (!atomic_load_explicit(&slot->active, memory_order_acquire)) continue;
            if (token) { token = 0; break; }
            token = atomic_load_explicit(&slot->token, memory_order_acquire);
        }
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return token;
}
int jvm_bridge_finish_session_for_token(uint64_t token) {
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    if (!bridge_slot_can_retire_locked(slot) ||
        !jarbox_registry_finish(&g_bridge_registry, &g_bridge_focus, token)) {
        pthread_mutex_unlock(&g_bridge_lifecycle_lock);
        printf("[JarBoxVM][Lifecycle] ERROR: live registry owner cannot retire\n");
        return 0;
    }
    bridge_diag_end(token);
    bridge_reset_slot_locked(slot);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    printf("[JarBoxVM][Lifecycle] session=released token=%llu\n",
           (unsigned long long)token);
    return 1;
}
void jvm_bridge_finish_session(void) {
    (void)jvm_bridge_finish_session_for_token(jvm_bridge_session_token());
}
int jvm_bridge_interrupt_active_threads_for_token(uint64_t token) {
    if (!token) return 0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    MiniJVM *owner = NULL;
    JarBoxSession *held = NULL;
    if (slot && atomic_load_explicit(&slot->stop_requested, memory_order_acquire) &&
        atomic_load_explicit(&slot->phase, memory_order_acquire) == BRIDGE_RUNNING) {
        MiniJVM *vm = atomic_load_explicit(&slot->jvm, memory_order_acquire);
        // A requested stop rejects ordinary registry visitors, but this
        // exact RUNNING owner may still need an interrupt. Teardown closes
        // the heap lease gate under the same lifecycle lock.
        if (vm && jarbox_session_reserve_callback(vm->session)) {
            owner = vm;
            held = vm->session;
        }
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (!owner) return 0;
    // Java monitor acquisition can block. Do not hold the process-wide
    // lifecycle lock; jvm_destroy must wait for this heap-access lease.
    // GC may be holding the Java thread-list lock while waiting for a
    // stalled worker to suspend. Request STOP without taking that lock.
    gc_request_thread_status(owner->collector, GARBAGE_THREAD_STOP);
    thread_stop_all(owner);
    jarbox_session_callback_done(held);
    printf("[JarBoxVM][Lifecycle] stop=escalated_java_threads token=%llu\n",
           (unsigned long long)token);
    return 1;
}
int jvm_bridge_interrupt_active_threads(void) {
    return jvm_bridge_interrupt_active_threads_for_token(jvm_bridge_session_token());
}

/* 3D supersampling scale — shared by M3G (reads directly) and MC3D (via system property) */
int g_render_3d_scale = 1;

static void bridge_discard_unstarted_vm(JarBoxVMContext *slot) {
    // No MIDlet ran. Latch cancellation and skip normal Java shutdown hooks,
    // but retain the slot until jvm_destroy has drained every heap lease.
    atomic_store_explicit(&slot->stop_requested, 1, memory_order_release);
    slot->jvm->collector->exit_flag = 1;
    jvm_destroy(slot->jvm);
    slot->jvm = NULL;
    if (jvm_bridge_supported_concurrent_sessions() == 1) {
        atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
        atomic_store_explicit(&treo_nso_init_target_active, 0, memory_order_release);
    }
}

static int bridge_init_slot(JarBoxVMContext *slot, const char *res_root, const char *save_root, const char *midlet_jar,
                    int screen_width, int screen_height, int render_3d_scale,
                    int fps_limit) {
    if (!atomic_load_explicit(&slot->active, memory_order_acquire) ||
        atomic_load_explicit(&slot->phase, memory_order_acquire) != BRIDGE_STARTING) {
        printf("[JarBoxVM][Lifecycle] init denied: no acquired session\n");
        return -5;
    }
    if (slot->jvm) {
        printf("[JVM Bridge] JVM already initialized\n");
        return -1;
    }
    // Cancellation before native allocation is cheap: the worker's
    // deferred finish will retire the still-empty slot.
    if (atomic_load_explicit(&slot->stop_requested, memory_order_acquire)) return -9;
    // These results belong to this archive, not the most recent launch.
    int ninja_match = 0, init_target = 0;
    if (jvm_bridge_supported_concurrent_sessions() == 1)
        treo_nso_probe_reset();
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_NINJA_DEEP_DISABLED)
    ninja_match = treo_is_nso_family(midlet_jar, &init_target);
    printf("[JarBoxVM][NinjaDeep] profile=%s (NSO resource family)\n",
           ninja_match ? "matched" : "generic");
    // Historical mod probes only recognize one set of class signatures.
    // Zero does NOT mean that another NSO JAR failed to start.
    {
        char event[80];
        snprintf(event, sizeof(event), "vm_stage:legacy_mod_probe_match=%d",
                 init_target ? 1 : 0);
        jvm_bridge_note_net_trace(event);
    }
#endif
    // Archive recognition can be slow; recheck before creating the heap.
    if (atomic_load_explicit(&slot->stop_requested, memory_order_acquire)) return -9;
    // Keep legacy telemetry for the one-VM build only. These mirrors may
    // never be used as authorization for an independently running tab.
    if (jvm_bridge_supported_concurrent_sessions() == 1) {
        atomic_store_explicit(&treo_exact_ninja_verified, ninja_match, memory_order_release);
        atomic_store_explicit(&treo_nso_init_target_active, init_target, memory_order_release);
    }
    // Note: slot->stop_requested is NOT reset here — it is reset in
    // jvm_bridge_destroy() after the previous session.  Resetting it here
    // would race with backTapped() which may have already set the flag
    // before this function runs on the background thread.

    // Build bootclasspath: minijvm_rt.jar
    char bootclasspath[1024];
    snprintf(bootclasspath, sizeof(bootclasspath), "%s/minijvm_rt.jar", res_root);

    // Build classpath: j2me_api.jar + midlet JAR
    char classpath[4096];
    snprintf(classpath, sizeof(classpath), "%s/j2me_api.jar:%s",
             res_root, midlet_jar);

    printf("[JVM Bridge] bootclasspath: %s\n", bootclasspath);
    printf("[JVM Bridge] classpath: %s\n", classpath);

    // Create JVM instance
    slot->jvm = jvm_create();
    if (!slot->jvm) {
        printf("[JVM Bridge] ERROR: jvm_create() failed\n");
        return -2;
    }
    (void)jarbox_session_bind_token(
        slot->jvm->session,
        atomic_load_explicit(&slot->token, memory_order_acquire));
    // Copy the launch-only resource signature into this JVM before any
    // Java classes execute. Later launches cannot change this owner's NSO
    // recognition or give a foreign Canvas permission to use the fast path.
    jarbox_treo_nso_profile_set(&slot->jvm->session->treo_state,
        ninja_match, init_target);

    slot->jvm->jdwp_enable = 0;
    slot->jvm->jdwp_suspend_on_start = 0;
    slot->jvm->max_heap_size = 128 * 1024 * 1024;       // 128MB Java + this JVM's native graphics
    slot->jvm->garbage_collect_period_ms = 500;          // GC every 0.5 sec
    slot->jvm->heap_overload_percent = 70;               // GC at 70% heap

    s32 ret = jvm_init(slot->jvm, (c8 *)bootclasspath, (c8 *)classpath);
    if (ret) {
        printf("[JVM Bridge] ERROR: jvm_init() failed with code %d\n", ret);
        bridge_discard_unstarted_vm(slot);
        return -3;
    }
    // The Java core is initialized, but no MIDlet or native UI has started.
    // A queued cancel can retire now instead of registering more resources.
    if (atomic_load_explicit(&slot->stop_requested, memory_order_acquire)) {
        bridge_discard_unstarted_vm(slot);
        return -9;
    }
    // The registry retains an independently owned JarBoxSession reference
    // until DEAD; token/pointer reuse cannot expose a freed session.
    if (!jarbox_registry_bind(&g_bridge_registry,
            atomic_load_explicit(&slot->token, memory_order_acquire),
            slot->jvm->session)) {
        printf("[JarBoxVM][Lifecycle] failed to bind JVM registry owner\n");
        bridge_discard_unstarted_vm(slot);
        return -8;
    }

    // GC's native-memory ledger is separate for each JVM and guarded by
    // a generation key (including when a subsequent heap reuses an address).
    if (!jarbox_native_heap_register_vm(slot->jvm)) {
        printf("[JarBoxVM][Lifecycle] no free native heap ledger slot\n");
        bridge_discard_unstarted_vm(slot);
        return -7;
    }

    // Acquire a distinct native input context before exposing the remaining
    // subsystem hooks. Never start a JVM with an unbound input destination.
    if (!j2me_input_reg_natives(slot->jvm)) {
        printf("[JarBoxVM][Lifecycle] cannot reserve independent input context\n");
        jarbox_native_heap_unregister_vm(slot->jvm);
        bridge_discard_unstarted_vm(slot);
        return -4;
    }
    if (!j2me_ui_reg_natives(slot->jvm)) {
        printf("[JarBoxVM][Lifecycle] cannot reserve independent LCDUI context\n");
        j2me_input_release_vm(slot->jvm);
        jarbox_native_heap_unregister_vm(slot->jvm);
        bridge_discard_unstarted_vm(slot);
        return -6;
    }
    j2me_render_reg_natives(slot->jvm);
    j2me_audio_reg_natives(slot->jvm);
    j2me_micro3d_gl_reg_natives(slot->jvm);
    j2me_m3g_reg_natives(slot->jvm);

    // Set system properties
    sys_properties_set_c(slot->jvm, "os.name", "iOS");
    sys_properties_set_c(slot->jvm, "app.save.root", save_root);
    sys_properties_set_c(slot->jvm, "microedition.platform", "Apple/iPhone");
    sys_properties_set_c(slot->jvm, "microedition.encoding", "UTF-8");
    sys_properties_set_c(slot->jvm, "microedition.locale", "en");
    sys_properties_set_c(slot->jvm, "microedition.profiles", "MIDP-2.0");
    sys_properties_set_c(slot->jvm, "microedition.configuration", "CLDC-1.1");

    // Screen dimensions — used by Display.java to set canvas size
    char sw[16], sh[16];
    snprintf(sw, sizeof(sw), "%d", screen_width);
    snprintf(sh, sizeof(sh), "%d", screen_height);
    sys_properties_set_c(slot->jvm, "j2me.screen.width", sw);
    sys_properties_set_c(slot->jvm, "j2me.screen.height", sh);

    // 3D supersampling scale for M3G and MascotCapsule (1=native, 2=2x AA, 3=3x AA)
    g_render_3d_scale = render_3d_scale > 0 ? render_3d_scale : 1;
    char ss[8];
    snprintf(ss, sizeof(ss), "%d", g_render_3d_scale);
    sys_properties_set_c(slot->jvm, "micro3d.v3.fbo.scale", ss);  // MC3D reads this in Render.java

    // FPS limit (0 = unlimited)
    if (fps_limit > 0) {
        char fl[8];
        snprintf(fl, sizeof(fl), "%d", fps_limit);
        sys_properties_set_c(slot->jvm, "j2me.fps.limit", fl);
    }
    printf("[JVM Bridge] Screen size: %dx%d, 3D render scale: %s, FPS limit: %d\n",
           screen_width, screen_height, ss, fps_limit);

    jvm_bridge_note_net_trace("vm_stage:core_initialized");
    printf("[JVM Bridge] JVM initialized successfully\n");
    return 0;
}

static int bridge_run_slot(JarBoxVMContext *slot, const char *midlet_jar_path) {
    if (!slot->jvm ||
        atomic_load_explicit(&slot->phase, memory_order_acquire) != BRIDGE_STARTING) {
        printf("[JVM Bridge] ERROR: JVM not initialized or already run\n");
        return -1;
    }

    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    const int cancelled = atomic_load_explicit(&slot->stop_requested, memory_order_acquire);
    if (!cancelled)
        atomic_store_explicit(&slot->phase, BRIDGE_RUNNING, memory_order_release);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (cancelled) {
        printf("[JarBoxVM][Lifecycle] MIDlet start cancelled before call_main\n");
        return -9;
    }
    if (slot->jvm && slot->jvm->session)
        (void)jarbox_session_enter_foreground(slot->jvm->session);
    jvm_bridge_note_net_trace("vm_stage:midlet_runner_enter");
    printf("[JVM Bridge] Running MIDlet from: %s\n", midlet_jar_path);

    ArrayList *java_para = arraylist_create(0);
    arraylist_push_back(java_para, (void *)midlet_jar_path);

    s32 ret = call_main(slot->jvm, (c8 *)"javax/microedition/shell/MIDletRunner", java_para);

    arraylist_destroy(java_para);

    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    atomic_store_explicit(&slot->phase, BRIDGE_CLEANUP, memory_order_release);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    {
        char event[96];
        snprintf(event, sizeof(event), "vm_stage:midlet_runner_exit:code=%d", ret);
        jvm_bridge_note_net_trace(event);
    }
    printf("[JVM Bridge] MIDlet finished with code %d\n", ret);
    return ret;
}

static void bridge_begin_slot_cleanup(JarBoxVMContext *slot) {
    // Wait for an already admitted focus/park to finish before closing
    // admission. Subsequent focus calls cannot pin a CLEANUP slot.
    pthread_mutex_lock(&g_bridge_focus_transition_lock);
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    atomic_store_explicit(&slot->phase, BRIDGE_CLEANUP, memory_order_release);
    jarbox_registry_begin_stop(&g_bridge_registry,
        atomic_load_explicit(&slot->token, memory_order_acquire));
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    pthread_mutex_unlock(&g_bridge_focus_transition_lock);
}

static void bridge_destroy_slot(JarBoxVMContext *slot) {
    bridge_begin_slot_cleanup(slot);
    if (slot->jvm) {
        MiniJVM *const destroyed_owner = slot->jvm;
        // The heap ledger generation outlives the MiniJVM allocation and
        // prevents cleanup from mistaking a reused VM pointer for this one.
        const uint64_t destroyed_render_key =
            jarbox_native_heap_key_for_vm(destroyed_owner);
        printf("[JVM Bridge] Destroying JVM\n");

        // Step 1: Revoke this JVM's right to publish pixels before stopping
        // native render calls. Delayed frames must never reach a later tab.
        j2me_render_release_vm(slot->jvm);
        // Stop only this JVM's native 2D handles. A different session's
        // frame generation must remain eligible to draw after A is stopped.
        j2me_render_stop_for_owner(destroyed_render_key);

        // Step 2: Signal JVM shutdown and stop all threads.
        // exit_flag makes jvm_destroy's non-daemon wait loop exit immediately;
        // thread_stop_all sets is_stop/is_interrupt on each thread.
        slot->jvm->collector->exit_flag = 1;
        gc_request_thread_status(slot->jvm->collector, GARBAGE_THREAD_STOP);
        thread_stop_all(slot->jvm);

        // Step 3: Close only the audio players owned by this JVM. An
        // unrelated JVM's players must not stop just because A exits.
        j2me_audio_stop_for_vm(slot->jvm);

        // Step 4: Unbind only this JVM's physical input and Display wait.
        // Release makes any late native poll return empty, and signals its
        // own condition variable without waking or modifying another VM.
        j2me_input_release_vm(slot->jvm);

        // Step 5: jvm_destroy waits for all real native Java worker leases,
        // not just the Java ZOMBIE status. It retains the JVM heap if a
        // pthread is stuck and keeps the single-JVM gate occupied. The UI
        // already exposes an explicit process-exit recovery for stuck games.
        jvm_destroy(slot->jvm);
        // The JVM address remains the registration key until this release;
        // no code dereferences it after jvm_destroy.
        j2me_ui_release_vm(slot->jvm);
        slot->jvm = NULL;

        // Step 6: Clean up other native subsystems — safe because:
        // - the generation-scoped stop denies new render acquires for this VM
        // - jvm_destroy gave threads 3s to exit
        // Input reset is no longer global; that JVM was released above.
        j2me_micro3d_gl_cleanup_for_owner(destroyed_render_key);
        j2me_m3g_cleanup();
        j2me_render_cleanup_for_owner(destroyed_render_key); // only this VM's 2D handles
        // The C native ledger is independent of the freed Java heap pointer.
        // Dereference is never required; compare identity and invalidate key.
        jarbox_native_heap_unregister_vm(destroyed_owner);
        // Keep cancellation asserted until the owning Swift worker releases
        // the session. A late Back click must not bleed into the next launch.
        if (jvm_bridge_supported_concurrent_sessions() == 1) {
            atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
            atomic_store_explicit(&treo_nso_init_target_active, 0, memory_order_release);
        }

        printf("[JVM Bridge] JVM destroyed, native state cleaned up\n");
    }
}

int jvm_bridge_request_stop_for_token(uint64_t token) {
    if (!token) return 0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    const int matching = slot != NULL;
    JarBoxSession *held = NULL;
    MiniJVM *owner = NULL;
    if (slot) {
        // Pin before marking the registry STOPPING (which rejects new
        // callbacks). Wake this Display even when it is no longer visible.
        if (atomic_load_explicit(&slot->phase, memory_order_acquire) == BRIDGE_RUNNING)
            owner = (MiniJVM *)jarbox_registry_pin_vm(&g_bridge_registry, token, &held);
        atomic_store_explicit(&slot->stop_requested, 1, memory_order_release);
        (void)jarbox_registry_request_stop(&g_bridge_registry, token);
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (owner) {
        j2me_display_wake_for_vm(owner);
        jarbox_session_callback_done(held);
    }
    if (matching)
        printf("[JarBoxVM][Lifecycle] stop_requested token=%llu\n",
               (unsigned long long)token);
    return matching;
}
void jvm_bridge_request_stop(void) {
    (void)jvm_bridge_request_stop_for_token(jvm_bridge_session_token());
}

int jvm_bridge_is_stop_requested_for_token(uint64_t token) {
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    const int stop = !slot ||
        atomic_load_explicit(&slot->stop_requested, memory_order_acquire);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return stop;
}
int jvm_bridge_is_stop_requested(void) {
    const uint64_t token = jvm_bridge_session_token();
    return token ? jvm_bridge_is_stop_requested_for_token(token) : 0;
}

/* The explicit worker owns a slot for the entire native operation.
 * A concurrent stale finish/destroy cannot recycle it underneath this call.
 * The legacy ABI delegates to the same token-based path. */
int jvm_bridge_init_for_token(uint64_t token,
        const char *res_root, const char *save_root, const char *midlet_jar,
        int screen_width, int screen_height, int render_3d_scale, int fps_limit) {
    JarBoxVMContext *slot = bridge_claim_worker(token);
    if (!slot) return -10;
    const uint64_t previous = jvm_bridge_push_java_thread_token(token);
    const int result = bridge_init_slot(slot, res_root, save_root, midlet_jar,
                                         screen_width, screen_height, render_3d_scale, fps_limit);
    jvm_bridge_pop_java_thread_token(previous);
    bridge_release_worker(slot);
    return result;
}
int jvm_bridge_init(const char *res_root, const char *save_root, const char *midlet_jar,
                    int screen_width, int screen_height, int render_3d_scale, int fps_limit) {
    return jvm_bridge_init_for_token(jvm_bridge_session_token(), res_root, save_root,
                                      midlet_jar, screen_width, screen_height, render_3d_scale, fps_limit);
}
int jvm_bridge_run_midlet_for_token(uint64_t token, const char *midlet_jar_path) {
    JarBoxVMContext *slot = bridge_claim_worker(token);
    if (!slot) return -10;
    const uint64_t previous = jvm_bridge_push_java_thread_token(token);
    const int result = bridge_run_slot(slot, midlet_jar_path);
    jvm_bridge_pop_java_thread_token(previous);
    bridge_release_worker(slot);
    return result;
}
int jvm_bridge_run_midlet(const char *midlet_jar_path) {
    return jvm_bridge_run_midlet_for_token(jvm_bridge_session_token(), midlet_jar_path);
}
int jvm_bridge_destroy_for_token(uint64_t token) {
    JarBoxVMContext *slot = bridge_claim_worker(token);
    if (!slot) return 0;
    const uint64_t previous = jvm_bridge_push_java_thread_token(token);
    bridge_destroy_slot(slot);
    jvm_bridge_pop_java_thread_token(previous);
    bridge_release_worker(slot);
    return 1;
}
void jvm_bridge_destroy(void) {
    (void)jvm_bridge_destroy_for_token(jvm_bridge_session_token());
}

// Java native polling must read the stop flag of the JVM that made the
// call, never another foreground game. An unbound/tearing-down JVM is
// instructed to stop instead of accidentally inheriting a later session.
int jvm_bridge_is_stop_requested_for_vm(const void *vm) {
    // jvm_init may query the native stop bridge before it has completed
    // classpath initialization and attached to the registry. Preserve the
    // old exact STARTING-owner behavior for this narrow pre-bind interval.
    // After binding, a foreign/stale pointer always fails closed.
    if (!vm) return 1;
    // Do not take the lifecycle mutex from a Java stop poll: the interrupt
    // watchdog can hold it while acquiring Java monitors. During STARTING,
    // compare only atomic identity fields; never dereference a slot's VM.
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxVMContext *slot = &g_bridge_slots[i];
        const uint64_t token = atomic_load_explicit(&slot->token, memory_order_acquire);
        if (!token || !atomic_load_explicit(&slot->active, memory_order_acquire) ||
            atomic_load_explicit(&slot->phase, memory_order_acquire) != BRIDGE_STARTING ||
            atomic_load_explicit(&slot->jvm, memory_order_acquire) != vm) continue;
        const int stop = atomic_load_explicit(&slot->stop_requested, memory_order_acquire);
        if (atomic_load_explicit(&slot->token, memory_order_acquire) == token &&
            atomic_load_explicit(&slot->phase, memory_order_acquire) == BRIDGE_STARTING &&
            atomic_load_explicit(&slot->jvm, memory_order_acquire) == vm)
            return stop;
    }
    return jarbox_registry_should_stop_vm(&g_bridge_registry, vm);
}
