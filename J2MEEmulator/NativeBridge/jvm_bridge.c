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
static int treo_is_nso_family(const char *jar_path) {
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
        atomic_store_explicit(&treo_nso_init_target_active, found == 3,
                              memory_order_release);
    }
    mz_zip_reader_end(&archive);
    return family;
}

#endif


// First stage of per-JVM ownership: keep all VM lifecycle fields together
// rather than scattering independent mutable process globals. This context
// owns one concrete miniJVM heap and its stop token. The input/render/audio
// native bridges are not yet independently instantiated, so the single-live
// JVM guard MUST remain until those subsystems have their own contexts.
enum { BRIDGE_IDLE = 0, BRIDGE_STARTING = 1, BRIDGE_RUNNING = 2,
       BRIDGE_CLEANUP = 3 };
typedef struct {
    _Atomic(MiniJVM *) jvm;
    atomic_int stop_requested;
    atomic_int active;
    atomic_int phase;
    _Atomic uint64_t token;
} JarBoxVMContext;
static JarBoxVMContext g_bridge_vm = {0};
// Tokens are never reused, even when this context is reset and acquired again.
static _Atomic uint64_t g_bridge_session_sequence;
// One visible window; every other live tab remains parked (never stopped).
static JarBoxFocusPolicy g_bridge_focus = JARBOX_FOCUS_POLICY_INITIALIZER;
// Registry owns a session pin per token; runtime cap stays one until the
// native render, Treo, UI, audio and 3D state becomes fully isolated.
static JarBoxSessionRegistry g_bridge_registry = JARBOX_SESSION_REGISTRY_INITIALIZER;
// Protect the JVM pointer/phase while the cancellation watchdog interrupts
// Java threads; normal VM execution never takes this mutex.
static pthread_mutex_t g_bridge_lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
// Java launcher reports a specific error BEFORE the native runner unwinds.
// One session owns this buffer, and only the owning Swift worker reads it.
static char g_bridge_last_error[1536];
// Bounded launch-only JVM field trace. Never used for normal Treo telemetry.
static pthread_mutex_t g_bridge_nso_trace_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_bridge_nso_init_trace[4096];
static unsigned g_bridge_nso_init_trace_count;

// Fixed-size, bounded event log for network failures. No per-packet tracing,
// DNS name, credentials, payloads, file IO, timers, or background pollers.
static pthread_mutex_t g_bridge_net_trace_lock = PTHREAD_MUTEX_INITIALIZER;
static char g_bridge_net_trace[8192];
static unsigned g_bridge_net_trace_count;
static _Atomic uint64_t g_mod_popup_update_ticks;
static _Atomic uint64_t g_mod_loop_stage_counts[5];
static atomic_int g_mod_loop_last_stage;
static atomic_int g_mod_loop_exception_notes;
static atomic_int g_mod_dispatch_probe_notes;
static atomic_int g_mod_method_missing_notes;
static atomic_int g_mod_protocol_notes;
/* A few caught Java exceptions before network I/O help diagnose an empty
 * game selector. No Java strings, network payloads or game-specific hacks. */
static atomic_int g_bridge_early_exception_notes;
int jvm_bridge_early_exception_note_slot(void) {
    int prior = atomic_load_explicit(&g_bridge_early_exception_notes,
                                     memory_order_relaxed);
    while (prior < 12) {
        if (atomic_compare_exchange_weak_explicit(
                &g_bridge_early_exception_notes, &prior, prior + 1,
                memory_order_relaxed, memory_order_relaxed)) return 1;
    }
    return 0;
}

int jvm_bridge_mod_protocol_note_slot(void) {
    return atomic_fetch_add_explicit(&g_mod_protocol_notes, 1,
                                     memory_order_relaxed) < 20;
}
int jvm_bridge_mod_dispatch_probe_slot(void) {
    return atomic_fetch_add_explicit(&g_mod_dispatch_probe_notes, 1,
                                     memory_order_relaxed) < 2;
}
int jvm_bridge_mod_method_missing_slot(void) {
    return atomic_fetch_add_explicit(&g_mod_method_missing_notes, 1,
                                     memory_order_relaxed) < 10;
}
void jvm_bridge_mod_loop_note_stage(int stage) {
    if (stage < 1 || stage > 4) return;
    atomic_store_explicit(&g_mod_loop_last_stage, stage, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_mod_loop_stage_counts[stage], 1, memory_order_relaxed);
}
uint64_t jvm_bridge_mod_loop_stage_count(int stage) {
    if (stage < 1 || stage > 4) return 0;
    return atomic_load_explicit(&g_mod_loop_stage_counts[stage], memory_order_relaxed);
}
int jvm_bridge_mod_loop_last_stage(void) {
    return atomic_load_explicit(&g_mod_loop_last_stage, memory_order_relaxed);
}
int jvm_bridge_mod_loop_exception_log_slot(void) {
    return atomic_fetch_add_explicit(&g_mod_loop_exception_notes, 1,
                                     memory_order_relaxed) < 12;
}
void jvm_bridge_mod_popup_tick(void) {
    atomic_fetch_add_explicit(&g_mod_popup_update_ticks, 1, memory_order_relaxed);
}
uint64_t jvm_bridge_mod_popup_tick_count(void) {
    return atomic_load_explicit(&g_mod_popup_update_ticks, memory_order_relaxed);
}
void jvm_bridge_note_net_trace(const char *detail) {
    if (!detail || !detail[0]) return;
    pthread_mutex_lock(&g_bridge_net_trace_lock);
    if (g_bridge_net_trace_count < 64) {
        size_t len = strlen(g_bridge_net_trace);
        size_t avail = sizeof(g_bridge_net_trace) - len - 1;
        if (avail >= 64) {
            int added = snprintf(g_bridge_net_trace + len, avail + 1,
                                 "%s%s", len ? "\n" : "", detail);
            if (added > 0 && (size_t)added < avail)
                ++g_bridge_net_trace_count;
        }
    }
    pthread_mutex_unlock(&g_bridge_net_trace_lock);
    printf("[JarBoxNET] %s\n", detail);
}
const char *jvm_bridge_net_trace(void) {
    // Return a stable per-calling-thread snapshot to Swift. Reading does not
    // hold the writer lock while UIAlert or clipboard methods are invoked.
    static _Thread_local char snapshot[sizeof(g_bridge_net_trace)];
    pthread_mutex_lock(&g_bridge_net_trace_lock);
    memcpy(snapshot, g_bridge_net_trace, sizeof(snapshot));
    pthread_mutex_unlock(&g_bridge_net_trace_lock);
    return snapshot;
}
void jvm_bridge_note_nso_init_trace(const char *detail) {
    if (!detail || !detail[0]) return;
    pthread_mutex_lock(&g_bridge_nso_trace_lock);
    if (g_bridge_nso_init_trace_count < 20) {
        size_t len = strlen(g_bridge_nso_init_trace);
        size_t avail = sizeof(g_bridge_nso_init_trace) - len - 1;
        if (avail >= 4) {
            const int added = snprintf(g_bridge_nso_init_trace + len, avail + 1,
                                      "%s%s", len ? " | " : "", detail);
            if (added > 0) ++g_bridge_nso_init_trace_count;
        }
    }
    pthread_mutex_unlock(&g_bridge_nso_trace_lock);
    printf("[JarBoxVM][NSOInit] %s\n", detail);
}
const char *jvm_bridge_nso_init_trace(void) {
    return g_bridge_nso_init_trace;
}

static atomic_int g_bridge_last_error_ready;
void jvm_bridge_set_launch_error(const char *message) {
    if (!message) return;
    size_t n = strlen(message);
    if (n >= sizeof(g_bridge_last_error)) n = sizeof(g_bridge_last_error) - 1;
    memcpy(g_bridge_last_error, message, n);
    g_bridge_last_error[n] = '\0';
    atomic_store_explicit(&g_bridge_last_error_ready, 1, memory_order_release);
    printf("[JarBoxVM][LaunchError] %s\n", g_bridge_last_error);
}
const char *jvm_bridge_last_error(void) {
    return atomic_load_explicit(&g_bridge_last_error_ready, memory_order_acquire)
        ? g_bridge_last_error : "";
}


int jvm_bridge_try_begin_session(void) {
    int expected = 0;
    if (!atomic_compare_exchange_strong_explicit(&g_bridge_vm.active,
            &expected, 1, memory_order_acq_rel, memory_order_acquire))
        return 0;
    const uint64_t token = atomic_fetch_add_explicit(
        &g_bridge_session_sequence, 1, memory_order_relaxed) + 1;
    // Every VM token is registered with the single-visible policy before
    // its async startup worker is scheduled. A new VM cannot steal focus.
    if (!jarbox_registry_claim(&g_bridge_registry, &g_bridge_focus,
                               token, 1 /* safe single-VM limit */)) {
        atomic_store_explicit(&g_bridge_vm.active, 0, memory_order_release);
        return 0;
    }
    (void)jarbox_focus_select(&g_bridge_focus, token);
    atomic_store_explicit(&g_bridge_vm.token, token, memory_order_release);
    atomic_store_explicit(&g_bridge_vm.stop_requested, 0, memory_order_release);
    atomic_store_explicit(&g_bridge_last_error_ready, 0, memory_order_release);
    g_bridge_last_error[0] = '\0';
    pthread_mutex_lock(&g_bridge_nso_trace_lock);
    g_bridge_nso_init_trace[0] = '\0';
    g_bridge_nso_init_trace_count = 0;
    pthread_mutex_unlock(&g_bridge_nso_trace_lock);
    pthread_mutex_lock(&g_bridge_net_trace_lock);
    g_bridge_net_trace[0] = '\0';
    g_bridge_net_trace_count = 0;
    pthread_mutex_unlock(&g_bridge_net_trace_lock);
    atomic_store_explicit(&g_mod_popup_update_ticks, 0, memory_order_release);
    for (int j = 1; j <= 4; ++j)
        atomic_store_explicit(&g_mod_loop_stage_counts[j], 0, memory_order_relaxed);
    atomic_store_explicit(&g_mod_loop_last_stage, 0, memory_order_release);
    atomic_store_explicit(&g_mod_loop_exception_notes, 0, memory_order_release);
    atomic_store_explicit(&g_mod_dispatch_probe_notes, 0, memory_order_release);
    atomic_store_explicit(&g_mod_method_missing_notes, 0, memory_order_release);
    atomic_store_explicit(&g_mod_protocol_notes, 0, memory_order_release);
    atomic_store_explicit(&g_bridge_early_exception_notes, 0, memory_order_release);
    atomic_store_explicit(&g_bridge_vm.phase, BRIDGE_STARTING, memory_order_release);
    // Visible from the first frame in Chẩn đoán kết nối, regardless of
    // which Java network API the game calls. Detects an older installed IPA.
    jvm_bridge_note_net_trace("probe:java8_utf8_boot_patch=v1");
    jvm_bridge_note_net_trace("probe:java8_localtime_boot_patch=v1");
    jvm_bridge_note_net_trace("probe:vm_opcode_guard=v1");
    printf("[JarBoxVM][Lifecycle] session=acquired phase=starting\n");
    return 1;
}
/* One visible session, all remaining JVMs parked. The existing one-JVM
 * guard remains while native Treo/renderer/GC and 3D contain globals.
 * The focus policy itself is multi-slot; these functions only act on the
 * VM we can prove owns the current bridge slot today.
 */
int jvm_bridge_park_session(uint64_t token) {
    if (!token || !atomic_load_explicit(&g_bridge_vm.active, memory_order_acquire) ||
        atomic_load_explicit(&g_bridge_vm.token, memory_order_acquire) != token)
        return 0;
    // Park revokes the native foreground framebuffer immediately, so
    // already-queued Canvas and MIDP callbacks cannot paint into the library.
    // Do not clear the input context here: deep NSO Treo's Display waiter
    // still needs its owning context until resume/stop.
    MiniJVM *owner = atomic_load_explicit(&g_bridge_vm.jvm, memory_order_acquire);
    if (owner) j2me_render_release_vm(owner);
    jarbox_focus_park_all(&g_bridge_focus);
    if (owner && owner->session)
        (void)jarbox_session_park(owner->session);
    return jarbox_focus_is_parked(&g_bridge_focus, token) == 1;
}

int jvm_bridge_focus_session(uint64_t token) {
    if (!token || !atomic_load_explicit(&g_bridge_vm.active, memory_order_acquire) ||
        atomic_load_explicit(&g_bridge_vm.token, memory_order_acquire) != token)
        return 0;
    MiniJVM *owner = atomic_load_explicit(&g_bridge_vm.jvm, memory_order_acquire);
    if (!owner) return 0;
    // The renderer must own the next frame before LCDUI replays the
    // most recent Form/List/Canvas. Physical input goes only to this VM.
    if (!j2me_render_focus_vm(owner) || !j2me_input_focus_vm(owner) ||
        !j2me_ui_focus_vm(owner)) return 0;
    const int selected = jarbox_focus_select(&g_bridge_focus, token);
    if (selected && owner->session)
        (void)jarbox_session_enter_foreground(owner->session);
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
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    const int running = atomic_load_explicit(&g_bridge_vm.phase,
                                             memory_order_acquire) == BRIDGE_RUNNING &&
                        atomic_load_explicit(&g_bridge_vm.token,
                                             memory_order_acquire) == token;
    JarBoxSession *held_session = NULL;
    MiniJVM *vm = running ?
        (MiniJVM *)jarbox_registry_pin_vm(&g_bridge_registry, token, &held_session)
        : NULL;
    // The callback lease protects the VM after the short lifecycle lock.
    // STOPPING can close admission but cannot free an in-flight visitor.
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
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
    return atomic_load_explicit(&g_bridge_vm.phase, memory_order_acquire);
}
int jvm_bridge_session_is_active(void) {
    return atomic_load_explicit(&g_bridge_vm.active, memory_order_acquire);
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
    return atomic_load_explicit(&g_bridge_vm.token, memory_order_acquire);
}
void jvm_bridge_finish_session(void) {
    // Only the owning startup worker calls this AFTER native teardown.
    if (g_bridge_vm.jvm) {
        printf("[JarBoxVM][Lifecycle] ERROR: refusing to release live JVM session\n");
        return;
    }
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    // Fail closed: stuck Java/native leases keep this slot occupied.
    const uint64_t token = atomic_load_explicit(&g_bridge_vm.token,
                                                memory_order_acquire);
    if (!jarbox_registry_finish(&g_bridge_registry, &g_bridge_focus, token)) {
        pthread_mutex_unlock(&g_bridge_lifecycle_lock);
        printf("[JarBoxVM][Lifecycle] ERROR: live registry owner cannot retire\n");
        return;
    }
    atomic_store_explicit(&g_bridge_vm.phase, BRIDGE_IDLE, memory_order_release);
    atomic_store_explicit(&g_bridge_vm.stop_requested, 0, memory_order_release);
    atomic_store_explicit(&g_bridge_vm.token, 0, memory_order_release);
    atomic_store_explicit(&g_bridge_vm.active, 0, memory_order_release);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    printf("[JarBoxVM][Lifecycle] session=released\n");
}
int jvm_bridge_interrupt_active_threads_for_token(uint64_t token) {
    if (!token) return 0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    const int matching =
        atomic_load_explicit(&g_bridge_vm.token, memory_order_acquire) == token &&
        atomic_load_explicit(&g_bridge_vm.active, memory_order_acquire);
    const int phase = atomic_load_explicit(&g_bridge_vm.phase, memory_order_acquire);
    int interrupted = 0;
    if (matching &&
        atomic_load_explicit(&g_bridge_vm.stop_requested, memory_order_acquire) &&
        phase == BRIDGE_RUNNING && g_bridge_vm.jvm) {
        thread_stop_all(g_bridge_vm.jvm);
        interrupted = 1;
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (interrupted)
        printf("[JarBoxVM][Lifecycle] stop=escalated_java_threads token=%llu\n",
               (unsigned long long)token);
    return interrupted;
}
int jvm_bridge_interrupt_active_threads(void) {
    return jvm_bridge_interrupt_active_threads_for_token(jvm_bridge_session_token());
}

/* 3D supersampling scale — shared by M3G (reads directly) and MC3D (via system property) */
int g_render_3d_scale = 1;

int jvm_bridge_init(const char *res_root, const char *save_root, const char *midlet_jar,
                    int screen_width, int screen_height, int render_3d_scale,
                    int fps_limit) {
    if (!atomic_load_explicit(&g_bridge_vm.active, memory_order_acquire)) {
        printf("[JarBoxVM][Lifecycle] init denied: no acquired session\n");
        return -5;
    }
    if (g_bridge_vm.jvm) {
        printf("[JVM Bridge] JVM already initialized\n");
        return -1;
    }
    atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
    atomic_store_explicit(&treo_nso_init_target_active, 0, memory_order_release);
    treo_nso_probe_reset();
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_NINJA_DEEP_DISABLED)
    int ninja_match = treo_is_nso_family(midlet_jar);
    atomic_store_explicit(&treo_exact_ninja_verified, ninja_match, memory_order_release);
    printf("[JarBoxVM][NinjaDeep] profile=%s (NSO resource family)\n",
           ninja_match ? "matched" : "generic");
    // Historical mod probes only recognize one set of class signatures.
    // Zero does NOT mean that another NSO JAR failed to start.
    {
        char event[80];
        snprintf(event, sizeof(event), "vm_stage:legacy_mod_probe_match=%d",
                 atomic_load_explicit(&treo_nso_init_target_active,
                                      memory_order_acquire) ? 1 : 0);
        jvm_bridge_note_net_trace(event);
    }
#endif
    // Note: g_bridge_vm.stop_requested is NOT reset here — it is reset in
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
    g_bridge_vm.jvm = jvm_create();
    if (!g_bridge_vm.jvm) {
        printf("[JVM Bridge] ERROR: jvm_create() failed\n");
        return -2;
    }
    (void)jarbox_session_bind_token(
        g_bridge_vm.jvm->session,
        atomic_load_explicit(&g_bridge_vm.token, memory_order_acquire));
    // Copy the launch-only resource signature into this JVM before any
    // Java classes execute. Later launches cannot change this owner's NSO
    // recognition or give a foreign Canvas permission to use the fast path.
    jarbox_treo_nso_profile_set(&g_bridge_vm.jvm->session->treo_state,
        atomic_load_explicit(&treo_exact_ninja_verified, memory_order_acquire),
        atomic_load_explicit(&treo_nso_init_target_active, memory_order_acquire));

    g_bridge_vm.jvm->jdwp_enable = 0;
    g_bridge_vm.jvm->jdwp_suspend_on_start = 0;
    g_bridge_vm.jvm->max_heap_size = 128 * 1024 * 1024;       // 128MB Java + this JVM's native graphics
    g_bridge_vm.jvm->garbage_collect_period_ms = 500;          // GC every 0.5 sec
    g_bridge_vm.jvm->heap_overload_percent = 70;               // GC at 70% heap

    s32 ret = jvm_init(g_bridge_vm.jvm, (c8 *)bootclasspath, (c8 *)classpath);
    if (ret) {
        printf("[JVM Bridge] ERROR: jvm_init() failed with code %d\n", ret);
        jvm_destroy(g_bridge_vm.jvm);
        g_bridge_vm.jvm = NULL;
        atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
        return -3;
    }
    // The registry retains an independently owned JarBoxSession reference
    // until DEAD; token/pointer reuse cannot expose a freed session.
    if (!jarbox_registry_bind(&g_bridge_registry,
            atomic_load_explicit(&g_bridge_vm.token, memory_order_acquire),
            g_bridge_vm.jvm->session)) {
        printf("[JarBoxVM][Lifecycle] failed to bind JVM registry owner\n");
        jvm_destroy(g_bridge_vm.jvm);
        g_bridge_vm.jvm = NULL;
        return -8;
    }

    // GC's native-memory ledger is separate for each JVM and guarded by
    // a generation key (including when a subsequent heap reuses an address).
    if (!jarbox_native_heap_register_vm(g_bridge_vm.jvm)) {
        printf("[JarBoxVM][Lifecycle] no free native heap ledger slot\n");
        jvm_destroy(g_bridge_vm.jvm);
        g_bridge_vm.jvm = NULL;
        atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
        return -7;
    }

    // Acquire a distinct native input context before exposing the remaining
    // subsystem hooks. Never start a JVM with an unbound input destination.
    if (!j2me_input_reg_natives(g_bridge_vm.jvm)) {
        printf("[JarBoxVM][Lifecycle] cannot reserve independent input context\n");
        jarbox_native_heap_unregister_vm(g_bridge_vm.jvm);
        jvm_destroy(g_bridge_vm.jvm);
        g_bridge_vm.jvm = NULL;
        atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
        return -4;
    }
    if (!j2me_ui_reg_natives(g_bridge_vm.jvm)) {
        printf("[JarBoxVM][Lifecycle] cannot reserve independent LCDUI context\n");
        j2me_input_release_vm(g_bridge_vm.jvm);
        jarbox_native_heap_unregister_vm(g_bridge_vm.jvm);
        jvm_destroy(g_bridge_vm.jvm);
        g_bridge_vm.jvm = NULL;
        atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
        return -6;
    }
    j2me_render_reg_natives(g_bridge_vm.jvm);
    j2me_audio_reg_natives(g_bridge_vm.jvm);
    j2me_micro3d_gl_reg_natives(g_bridge_vm.jvm);
    j2me_m3g_reg_natives(g_bridge_vm.jvm);

    // Set system properties
    sys_properties_set_c(g_bridge_vm.jvm, "os.name", "iOS");
    sys_properties_set_c(g_bridge_vm.jvm, "app.save.root", save_root);
    sys_properties_set_c(g_bridge_vm.jvm, "microedition.platform", "Apple/iPhone");
    sys_properties_set_c(g_bridge_vm.jvm, "microedition.encoding", "UTF-8");
    sys_properties_set_c(g_bridge_vm.jvm, "microedition.locale", "en");
    sys_properties_set_c(g_bridge_vm.jvm, "microedition.profiles", "MIDP-2.0");
    sys_properties_set_c(g_bridge_vm.jvm, "microedition.configuration", "CLDC-1.1");

    // Screen dimensions — used by Display.java to set canvas size
    char sw[16], sh[16];
    snprintf(sw, sizeof(sw), "%d", screen_width);
    snprintf(sh, sizeof(sh), "%d", screen_height);
    sys_properties_set_c(g_bridge_vm.jvm, "j2me.screen.width", sw);
    sys_properties_set_c(g_bridge_vm.jvm, "j2me.screen.height", sh);

    // 3D supersampling scale for M3G and MascotCapsule (1=native, 2=2x AA, 3=3x AA)
    g_render_3d_scale = render_3d_scale > 0 ? render_3d_scale : 1;
    char ss[8];
    snprintf(ss, sizeof(ss), "%d", g_render_3d_scale);
    sys_properties_set_c(g_bridge_vm.jvm, "micro3d.v3.fbo.scale", ss);  // MC3D reads this in Render.java

    // FPS limit (0 = unlimited)
    if (fps_limit > 0) {
        char fl[8];
        snprintf(fl, sizeof(fl), "%d", fps_limit);
        sys_properties_set_c(g_bridge_vm.jvm, "j2me.fps.limit", fl);
    }
    printf("[JVM Bridge] Screen size: %dx%d, 3D render scale: %s, FPS limit: %d\n",
           screen_width, screen_height, ss, fps_limit);

    jvm_bridge_note_net_trace("vm_stage:core_initialized");
    printf("[JVM Bridge] JVM initialized successfully\n");
    return 0;
}

int jvm_bridge_run_midlet(const char *midlet_jar_path) {
    if (!g_bridge_vm.jvm) {
        printf("[JVM Bridge] ERROR: JVM not initialized\n");
        return -1;
    }

    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    atomic_store_explicit(&g_bridge_vm.phase, BRIDGE_RUNNING, memory_order_release);
    const int cancelled = atomic_load_explicit(&g_bridge_vm.stop_requested, memory_order_acquire);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (cancelled) {
        printf("[JarBoxVM][Lifecycle] MIDlet start cancelled before call_main\n");
        return -9;
    }
    if (g_bridge_vm.jvm && g_bridge_vm.jvm->session)
        (void)jarbox_session_enter_foreground(g_bridge_vm.jvm->session);
    jvm_bridge_note_net_trace("vm_stage:midlet_runner_enter");
    printf("[JVM Bridge] Running MIDlet from: %s\n", midlet_jar_path);

    ArrayList *java_para = arraylist_create(0);
    arraylist_push_back(java_para, (void *)midlet_jar_path);

    s32 ret = call_main(g_bridge_vm.jvm, (c8 *)"javax/microedition/shell/MIDletRunner", java_para);

    arraylist_destroy(java_para);

    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    atomic_store_explicit(&g_bridge_vm.phase, BRIDGE_CLEANUP, memory_order_release);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    {
        char event[96];
        snprintf(event, sizeof(event), "vm_stage:midlet_runner_exit:code=%d", ret);
        jvm_bridge_note_net_trace(event);
    }
    printf("[JVM Bridge] MIDlet finished with code %d\n", ret);
    return ret;
}

void jvm_bridge_destroy(void) {
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    atomic_store_explicit(&g_bridge_vm.phase, BRIDGE_CLEANUP, memory_order_release);
    jarbox_registry_begin_stop(&g_bridge_registry,
        atomic_load_explicit(&g_bridge_vm.token, memory_order_acquire));
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (g_bridge_vm.jvm) {
        MiniJVM *const destroyed_owner = g_bridge_vm.jvm;
        // The heap ledger generation outlives the MiniJVM allocation and
        // prevents cleanup from mistaking a reused VM pointer for this one.
        const uint64_t destroyed_render_key =
            jarbox_native_heap_key_for_vm(destroyed_owner);
        printf("[JVM Bridge] Destroying JVM\n");

        // Step 1: Revoke this JVM's right to publish pixels before stopping
        // native render calls. Delayed frames must never reach a later tab.
        j2me_render_release_vm(g_bridge_vm.jvm);
        // Stop only this JVM's native 2D handles. A different session's
        // frame generation must remain eligible to draw after A is stopped.
        j2me_render_stop_for_owner(destroyed_render_key);

        // Step 2: Signal JVM shutdown and stop all threads.
        // exit_flag makes jvm_destroy's non-daemon wait loop exit immediately;
        // thread_stop_all sets is_stop/is_interrupt on each thread.
        g_bridge_vm.jvm->collector->exit_flag = 1;
        thread_stop_all(g_bridge_vm.jvm);

        // Step 3: Close only the audio players owned by this JVM. An
        // unrelated JVM's players must not stop just because A exits.
        j2me_audio_stop_for_vm(g_bridge_vm.jvm);

        // Step 4: Unbind only this JVM's physical input and Display wait.
        // Release makes any late native poll return empty, and signals its
        // own condition variable without waking or modifying another VM.
        j2me_input_release_vm(g_bridge_vm.jvm);

        // Step 5: jvm_destroy waits for all real native Java worker leases,
        // not just the Java ZOMBIE status. It retains the JVM heap if a
        // pthread is stuck and keeps the single-JVM gate occupied. The UI
        // already exposes an explicit process-exit recovery for stuck games.
        jvm_destroy(g_bridge_vm.jvm);
        // The JVM address remains the registration key until this release;
        // no code dereferences it after jvm_destroy.
        j2me_ui_release_vm(g_bridge_vm.jvm);
        g_bridge_vm.jvm = NULL;

        // Step 6: Clean up other native subsystems — safe because:
        // - the generation-scoped stop denies new render acquires for this VM
        // - jvm_destroy gave threads 3s to exit
        // Input reset is no longer global; that JVM was released above.
        j2me_micro3d_gl_cleanup();
        j2me_m3g_cleanup();
        j2me_render_cleanup_for_owner(destroyed_render_key); // only this VM's 2D handles
        // The C native ledger is independent of the freed Java heap pointer.
        // Dereference is never required; compare identity and invalidate key.
        jarbox_native_heap_unregister_vm(destroyed_owner);
        // Keep cancellation asserted until the owning Swift worker releases
        // the session. A late Back click must not bleed into the next launch.
        atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);

        printf("[JVM Bridge] JVM destroyed, native state cleaned up\n");
    }
}

int jvm_bridge_request_stop_for_token(uint64_t token) {
    if (!token) return 0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    const int matching =
        atomic_load_explicit(&g_bridge_vm.active, memory_order_acquire) &&
        atomic_load_explicit(&g_bridge_vm.token, memory_order_acquire) == token;
    if (matching) {
        atomic_store_explicit(&g_bridge_vm.stop_requested, 1, memory_order_release);
        (void)jarbox_registry_request_stop(&g_bridge_registry, token);
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (matching) {
        printf("[JarBoxVM][Lifecycle] stop_requested token=%llu\n",
               (unsigned long long)token);
        j2me_display_wake();
    }
    return matching;
}
void jvm_bridge_request_stop(void) {
    (void)jvm_bridge_request_stop_for_token(jvm_bridge_session_token());
}

int jvm_bridge_is_stop_requested(void) {
    return atomic_load_explicit(&g_bridge_vm.stop_requested, memory_order_acquire);
}

// Java native polling must read the stop flag of the JVM that made the
// call, never another foreground game. An unbound/tearing-down JVM is
// instructed to stop instead of accidentally inheriting a later session.
int jvm_bridge_is_stop_requested_for_vm(const void *vm) {
    return jarbox_registry_should_stop_vm(&g_bridge_registry, vm);
}
