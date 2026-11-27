//
// j2me_render.m — Core Graphics rendering bridge for J2ME LCDUI
//
// Maps J2ME Graphics operations to iOS Core Graphics (CGContext).
// Analogous to J2ME-Loader's mapping of Graphics → Android Canvas (Skia).
//

#import <CoreGraphics/CoreGraphics.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#include <string.h>
#include <stdlib.h>
#include <stddef.h>
#if defined(__ARM_NEON)
#include <arm_neon.h>
#endif
#import <CoreHaptics/CoreHaptics.h>
#include "j2me_render.h"
#include "jarbox_flush_routes.h"
#include "jarbox_scene_gpu_gate.h"
#include "jarbox_crop_cache.h"
#include "jarbox_region_stage.h"
#include "jarbox_binary_sprite.h"
#include "jarbox_binary_trial.h"
#include "jarbox_paint_qos_policy.h"
#include "jvm_bridge.h"
#include "j2me_input.h"
#include "jvm.h"
#include "jvm_util.h"
#if defined(TREO_NINJA_CORE_EXPERIMENT) && TREO_NINJA_CORE_EXPERIMENT
#include "jarbox_residual_binding.h"
#if defined(TREO_RESIDUAL_EXPERIMENT) && TREO_RESIDUAL_EXPERIMENT
extern int treo_game_jit_is_enabled(void);
#endif
#endif
#include "garbage.h"
#include <stdio.h>
#include <stdatomic.h>
#include <time.h>
#include <sys/resource.h>
#include <os/lock.h>
#include <mach/mach.h>
#include <mach/thread_info.h>
#include <mach/arm/thread_status.h>
#include <dlfcn.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <errno.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

// Main-thread-only QoS sweep. Active only during a reversible A/B/C/A audit.
static qos_class_t treo_main_saved_qos = QOS_CLASS_UNSPECIFIED;
static int treo_main_saved_relative = 0;
static int treo_main_qos_active = 0;

int treo_main_qos_begin(void) {
    if (!pthread_main_np()) return EPERM;
    if (treo_main_qos_active) return EBUSY;
    qos_class_t original = QOS_CLASS_UNSPECIFIED;
    int relative = 0;
    int rc = pthread_get_qos_class_np(pthread_self(), &original, &relative);
    if (rc) return rc;
    // This API cannot set UNSPECIFIED, so never start if exact restoration is impossible.
    if (original == QOS_CLASS_UNSPECIFIED) return ENOTSUP;
    treo_main_saved_qos = original;
    treo_main_saved_relative = relative;
    treo_main_qos_active = 1;
    return 0;
}
int treo_main_qos_current(void) {
    if (!pthread_main_np()) return -1;
    qos_class_t current = QOS_CLASS_UNSPECIFIED;
    if (pthread_get_qos_class_np(pthread_self(), &current, NULL)) return -1;
    return (int)current;
}
int treo_main_qos_expected(int mode) {
    if (mode == 0) return treo_main_qos_active ? (int)treo_main_saved_qos : -1;
    if (mode == 1) return (int)QOS_CLASS_USER_INITIATED;
    if (mode == 2) return (int)QOS_CLASS_UTILITY;
    return -1;
}
int treo_main_qos_apply(int mode) {
    if (!pthread_main_np() || !treo_main_qos_active) return EPERM;
    int desired = treo_main_qos_expected(mode);
    if (desired < 0) return EINVAL;
    int relative = mode == 0 ? treo_main_saved_relative : 0;
    int rc = pthread_set_qos_class_self_np((qos_class_t)desired, relative);
    if (rc) return rc;
    return treo_main_qos_current() == desired ? 0 : EIO;
}
int treo_main_qos_finish(void) {
    if (!treo_main_qos_active) return 0;
    int rc = treo_main_qos_apply(0);
    if (rc == 0) treo_main_qos_active = 0;
    return rc;
}

// ============================================================
// Internal structures
// ============================================================
// Thread safety is provided by three complementary mechanisms:
//
// 1. Refcounting (rc_acquire/rc_release, img_acquire/img_release):
//    Prevents use-after-free of CF resources. GC finalize() releases
//    the owner reference; struct stays alive while native code uses it.
//
// 2. paintLock (Java synchronized in Canvas.doPaint/flushBuffer/destroyContext):
//    Prevents concurrent CGContext access on the same Canvas.
//    CGContext is NOT thread-safe; concurrent Save/RestoreGState corrupts it.
//
// 3. Two-generation deferred shell free (process_dead_shells):
//    When refcount reaches 0, CF resources are released immediately but
//    the struct shell is kept for one frame to prevent ABA in acquire.

typedef struct TreoLiveRun TreoLiveRun;
typedef struct TreoCPUCache TreoCPUCache;
typedef struct RenderContext {
    CGContextRef ctx;
    int width;
    int height;
    CTFontRef font;
    CFDictionaryRef textAttrs; // immutable attributes, Canvas-owned
    CTFontRef textAttrsFont; // retained identity while attributes exist
    float fontSize;
    int fontStyle;
    int clipSaved;
    int ownsPixels;
    CGRect regionClipBounds;
    TreoLiveRun *liveRun;
    TreoCPUCache *cpuCache;
    JarBoxCropCache *cropCache; // only immutable sources, owned by this Canvas
#if defined(TREO_REGION_STAGE_DIAG) && TREO_REGION_STAGE_DIAG
    JarBoxRegionStage regionStage;
    uint64_t regionStageSequence;
#endif
    uint64_t compatible_crop_hits, compatible_crop_misses, compatible_state_reuses, compatible_region_culls;
    uint64_t compatible_text_attr_reuses;
    uint32_t *softwarePixels;
    uint64_t swRegions, swFast, swChecked, swMismatch, swDirect;
    unsigned swSequence;
#if defined(TREO_BINARY_SPRITE_EXPERIMENT) && TREO_BINARY_SPRITE_EXPERIMENT
    unsigned binarySequence;
    bool binaryReady, binaryRejected;
    uint64_t binaryFast, binaryChecks, binaryMismatch;
#endif
    unsigned fastFillSequence;
    bool fastFillRejected;
    bool fastFontValid;
    s32 fastFontFace, fastFontStyle, fastFontSize;
    uint64_t fastFills, fastFillChecks, fastFillMismatch, fastState;
    uint32_t liveColor, liveSavedColor;
    int liveStroke, liveSavedStroke;
    CGRect liveRawClip;
    int liveBlocked;
    uint64_t heap_key; // owning JVM generation for native GC
    _Atomic int afk_mode; // JVM generation-owned 2D raster mode
    _Atomic int32_t refcount;
    struct RenderContext *next_dead;
    struct RenderContext *next_live; // collision chain in safe handle lookup
    _Atomic int java_owned; // exactly one Java handle owns the base reference
} RenderContext;

typedef struct RenderImage {
    CGContextRef ctx;
    CGImageRef immutableSnapshot;
    CFDataRef immutablePixels; // retained read-only pixel copy; no shared CGContext
    int width;
    int height;
    int isMutable;
    const uint32_t *softwareSource;
    size_t softwareStride;
    atomic_uint softwareVerified, softwareRejected;
#if defined(TREO_BINARY_SPRITE_EXPERIMENT) && TREO_BINARY_SPRITE_EXPERIMENT
    atomic_uint binaryKind, binaryVerified;
#endif
    uint64_t heap_key;
    _Atomic int32_t refcount;
    struct RenderImage *next_dead;
    struct RenderImage *next_live;
    _Atomic int java_owned;
} RenderImage;

static atomic_int treo_replay_state; // 0 idle/done, 1 capture, 2 benchmark
static int treo_sw_draw(RenderContext *, RenderImage *, int64_t, int64_t, int, int, int, int, int, int);
static void treo_cpu_batch_drain(RenderContext *rc);
static void treo_cpu_batch_free(RenderContext *rc);
static void treo_live_discard(RenderContext *rc);
static void treo_live_drain(RenderContext *rc, int allowMetal);
static void treo_live_barrier(RenderContext *rc);
typedef void (^TreoShapeDraw)(CGContextRef);
static int treo_live_shape(RenderContext *rc, CGRect bounds, TreoShapeDraw draw);
static int treo_live_rect(RenderContext *rc, int x, int y, int w, int h);
static int treo_live_text(RenderContext *rc, CTLineRef line, CGFloat x, CGFloat baseline);
static int treo_live_image(RenderContext *rc, CGImageRef image, int64_t x, int64_t y,
                           int sx, int sy, int w, int h, int transform, int cacheable);
static int treo_live_enqueue(RenderContext *rc, RenderImage *img, int64_t x, int64_t y,
                             int sx, int sy, int w, int h, int transform);
// Copy each callback into an immutable owner route when a JVM generation
// registers; a later launch must not overwrite a still-live tab's route.
static JarBoxFlushRoutes g_flush_routes = JARBOX_FLUSH_ROUTES_INITIALIZER;
// Frame publication is controlled by a *generation* bound to one VM,
// never by JAR path (clones all share the same binary) or stale pointers.
// Java rendering into offscreen buffers may continue, but only the VM
// currently owning the visible screen can publish its pixels to UIKit.
static _Atomic uint64_t g_visible_render_owner_key;
static JarBoxSceneGpuGate g_scene_gpu_gate = JARBOX_SCENE_GPU_GATE_INITIALIZER;

// Main-thread scene boundary; does not change VM ownership or game state.
void j2me_render_set_2d_scene_active(int active) {
    jarbox_scene_gpu_set_active(&g_scene_gpu_gate, active);
}
// A queued UIKit haptic request must still belong to the visible VM when
// it runs on the main thread. Process-wide engine remains shared.
static _Atomic uint64_t g_haptic_player_owner_key;
static void render_haptic_release_owner(uint64_t owner_key);

int j2me_render_focus_vm(MiniJVM *vm) {
    const uint64_t key = jarbox_native_heap_key_for_vm(vm);
    if (!key) return 0;
    atomic_store_explicit(&g_visible_render_owner_key, key, memory_order_release);
    return 1;
}
void j2me_render_release_vm(MiniJVM *vm) {
    const uint64_t key = jarbox_native_heap_key_for_vm(vm);
    if (!key) return;
    uint64_t expected = key;
    (void)atomic_compare_exchange_strong_explicit(
        &g_visible_render_owner_key, &expected, 0,
        memory_order_acq_rel, memory_order_acquire);
    // The main-queue stop verifies the generation again; a later VM's
    // haptic player can never be stopped by this old release callback.
    render_haptic_release_owner(key);
}

// Legacy process-wide raster/Metal compatibility mirror while cap=1.
_Atomic int treo_afk_mode = 0;
static _Atomic uint64_t treo_afk_bypassed;
static JarBoxTreoState *treo_runtime_state(Runtime *r) {
    return r && r->jvm && r->jvm->session ? &r->jvm->session->treo_state : NULL;
}
static int treo_runtime_mode(Runtime *r) {
    return jarbox_treo_mode_get(treo_runtime_state(r));
}
// Defined after live context registry, updates only the matching generation.
static void treo_render_owner_mode_set(uint64_t owner_key, int mode);
// Only control transitions take this mutex; ordinary rendering and GC
// read their own atomic fields. Never acquire a bridge lease while held.
static pthread_mutex_t g_treo_transition_lock = PTHREAD_MUTEX_INITIALIZER;
static void treo_apply_mode_locked(MiniJVM *vm, int mode, uint64_t now_ns) {
    jarbox_treo_render_mode_set(&vm->session->treo_state, mode, now_ns);
    jvm_bridge_cpu_mode_changed(vm->session);
    const uint64_t key = jarbox_native_heap_key_for_vm(vm);
    treo_render_owner_mode_set(key, mode);
    if (jvm_bridge_supported_concurrent_sessions() == 1)
        atomic_store_explicit(&treo_afk_mode, mode, memory_order_release);
    if (mode) render_haptic_release_owner(key);
}
static inline int treo_rc_mode(const RenderContext *rc) {
    return rc ? atomic_load_explicit(&rc->afk_mode, memory_order_acquire) : 0;
}
static inline int treo_rc_afk(const RenderContext *rc) { return treo_rc_mode(rc) != 0; }
// A hidden Canvas must not record or submit new Metal work merely because
// its asynchronous Treo mode transition has not yet completed.
static inline int treo_rc_may_submit(const RenderContext *rc) {
    return rc && rc->heap_key && !treo_rc_afk(rc) &&
        jarbox_scene_gpu_is_active(&g_scene_gpu_gate) &&
        rc->heap_key == atomic_load_explicit(&g_visible_render_owner_key, memory_order_acquire);
}
static void process_dead_shells(void);
static uint64_t treo_afk_now_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}
uint64_t treo_afk_bypassed_paints(void) {
    return atomic_load_explicit(&treo_afk_bypassed, memory_order_relaxed);
}
static s32 n_afkBypassPaint(Runtime *runtime, JClass *clazz) {
    int bypass = 0;
    JarBoxTreoState *state = treo_runtime_state(runtime);
    const int mode = treo_runtime_mode(runtime);
    if (state && (mode == 6 || mode == 7)) {
        uint64_t now = treo_afk_now_ns();
        bypass = now && now < __atomic_load_n(&state->render_bypass_deadline_ns, __ATOMIC_ACQUIRE);
        if (bypass && mode == 7) {
            uint64_t next = __atomic_load_n(&state->render_next_paint_ns, __ATOMIC_RELAXED);
            // One genuine paint every >=200ms, across both possible caller threads.
            while (now >= next) {
                if (__atomic_compare_exchange_n(&state->render_next_paint_ns, &next,
                        now + UINT64_C(200000000), 1, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
                    bypass = 0;
                    break;
                }
            }
        }
        if (bypass) {
            // Preserve the native resource housekeeping normally done by flush.
            process_dead_shells();
            atomic_fetch_add_explicit(&treo_afk_bypassed, 1, memory_order_relaxed);
        }
    }
    push_int(runtime->stack, bypass);
    return RUNTIME_STATUS_NORMAL;
}
// Explicit-buffer AFK audit: the rendered GameCanvas Image is never skipped;
// only the redundant copy from Image to the hidden Canvas is optional.
static atomic_bool g_afk_buffer_audit, g_afk_buffer_skip;
static _Atomic uint64_t g_afk_buffer_copies, g_afk_buffer_skipped;
static _Atomic uint64_t g_afk_buffer_skipped_pixels, g_afk_buffer_copy_cpu_ns;
static uint64_t treo_thread_cpu_ns(void);
void treo_afk_buffer_audit_set(int enabled, int skip) {
    // No writes/reset of the counters in-flight: UI takes leg deltas.
    atomic_store_explicit(&g_afk_buffer_audit, false, memory_order_release);
    atomic_store_explicit(&g_afk_buffer_skip, enabled && skip, memory_order_release);
    atomic_store_explicit(&g_afk_buffer_audit, enabled != 0, memory_order_release);
}
uint64_t treo_afk_buffer_copied(void) {
    return atomic_load_explicit(&g_afk_buffer_copies, memory_order_acquire);
}
uint64_t treo_afk_buffer_skipped(void) {
    return atomic_load_explicit(&g_afk_buffer_skipped, memory_order_acquire);
}
uint64_t treo_afk_buffer_pixels_saved(void) {
    return atomic_load_explicit(&g_afk_buffer_skipped_pixels, memory_order_acquire);
}
uint64_t treo_afk_buffer_copy_cpu_ns(void) {
    return atomic_load_explicit(&g_afk_buffer_copy_cpu_ns, memory_order_acquire);
}
static s32 n_afkBufferBlitBegin(Runtime *runtime, JClass *clazz) {
    s64 stamp = 0;
    if (atomic_load_explicit(&g_afk_buffer_audit, memory_order_acquire) &&
        treo_runtime_mode(runtime) == 8) {
        const int w = runtime->jnienv->localvar_getInt(runtime->localvar, 0);
        const int h = runtime->jnienv->localvar_getInt(runtime->localvar, 1);
        const int safe = runtime->jnienv->localvar_getInt(runtime->localvar, 2);
        if (safe && atomic_load_explicit(&g_afk_buffer_skip, memory_order_acquire)) {
            atomic_fetch_add_explicit(&g_afk_buffer_skipped, 1, memory_order_relaxed);
            if (w > 0 && h > 0)
                atomic_fetch_add_explicit(&g_afk_buffer_skipped_pixels,
                                          (uint64_t)w * (uint64_t)h, memory_order_relaxed);
            stamp = -1;
        } else {
            atomic_fetch_add_explicit(&g_afk_buffer_copies, 1, memory_order_relaxed);
            stamp = (s64)treo_thread_cpu_ns();
        }
    }
    runtime->jnienv->push_long(runtime->stack, stamp);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_afkBufferBlitEnd(Runtime *runtime, JClass *clazz) {
    const s64 stamp = runtime->jnienv->localvar_getLong_2slot(runtime->localvar, 0);
    if (stamp > 0 && atomic_load_explicit(&g_afk_buffer_audit, memory_order_acquire)) {
        const uint64_t end = treo_thread_cpu_ns();
        if (end >= (uint64_t)stamp)
            atomic_fetch_add_explicit(&g_afk_buffer_copy_cpu_ns,
                                      end - (uint64_t)stamp, memory_order_relaxed);
    }
    return RUNTIME_STATUS_NORMAL;
}
static _Atomic uint64_t g_afk_skipped_draws, g_afk_skipped_paints;
static _Atomic uint64_t g_afk_paint_count, g_afk_paint_cpu_ns;

// Defined with the JAR audit controls later in this file.
int treo_jar_audit_enabled(void);

// Diagnostic sparse Java paint: only enabled inside its dedicated audit.
// The Display thread polls this at its EXISTING 16ms cadence. Never spawn
// a display timer, touch the game loop or submit a native frame.
static atomic_int treo_sparse_paint_hz;
static _Atomic uint64_t treo_sparse_next_ns, treo_sparse_due_count;
void treo_jar_sparse_paint_set(int hz) {
    if (hz != 1 && hz != 3) hz = 0;
    // Disable first so an in-flight Display poll cannot re-arm the old mode.
    atomic_store_explicit(&treo_sparse_paint_hz, 0, memory_order_release);
    atomic_store_explicit(&treo_sparse_next_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_sparse_paint_hz, hz, memory_order_release);
}
uint64_t treo_jar_sparse_paint_due_count(void) {
    return atomic_load_explicit(&treo_sparse_due_count, memory_order_relaxed);
}
static s32 n_jarSparsePaintDue(Runtime *runtime, JClass *clazz) {
    const int hz = atomic_load_explicit(&treo_sparse_paint_hz, memory_order_acquire);
    int due = 0;
    if ((hz == 1 || hz == 3) && treo_jar_audit_enabled()) {
        const uint64_t now = treo_afk_now_ns();
        const uint64_t interval = UINT64_C(1000000000) / (uint64_t)hz;
        uint64_t next = atomic_load_explicit(&treo_sparse_next_ns, memory_order_relaxed);
        if (now && next == 0) {
            // Start after one full interval; avoid a burst on a leg transition.
            (void)atomic_compare_exchange_strong_explicit(&treo_sparse_next_ns,
                &next, now + interval, memory_order_relaxed, memory_order_relaxed);
        } else if (now && now >= next) {
            due = atomic_compare_exchange_strong_explicit(&treo_sparse_next_ns,
                &next, now + interval, memory_order_relaxed, memory_order_relaxed);
            if (due) atomic_fetch_add_explicit(&treo_sparse_due_count, 1, memory_order_relaxed);
        }
    }
    push_int(runtime->stack, due);
    return RUNTIME_STATUS_NORMAL;
}

uint64_t treo_afk_paint_count(void) { return atomic_load_explicit(&g_afk_paint_count, memory_order_relaxed); }
uint64_t treo_afk_paint_cpu_ns(void) { return atomic_load_explicit(&g_afk_paint_cpu_ns, memory_order_relaxed); }

static _Atomic uint64_t treo_guarded_paints, treo_guarded_real, treo_guarded_late, treo_layer_frames;
// Generic JarBox deep-Treo: never skip paint() Java itself. If a Canvas
// unexpectedly reads its pixels/native context after guarded elision began,
// fall back to compatible AFK presentation-only mode for the current session.
// This opt-in guard does not affect the pre-existing mode-8 A/B/A diagnostics.
static void treo_guard_set_visitor(MiniJVM *vm, void *arg) {
    pthread_mutex_lock(&g_treo_transition_lock);
    jarbox_treo_guard_auto_set(&vm->session->treo_state, *(int *)arg);
    pthread_mutex_unlock(&g_treo_transition_lock);
}
void treo_afk_guard_auto_set(int enabled) {
    jvm_bridge_visit_running_vm(treo_guard_set_visitor, &enabled);
}
int treo_afk_guard_auto_set_for_token(uint64_t token, int enabled) {
    return jvm_bridge_visit_running_vm_for_token(token, treo_guard_set_visitor,
                                                  &enabled);
}
static void treo_guard_read_visitor(MiniJVM *vm, void *arg) {
    *(int *)arg = jarbox_treo_guard_fell_back(&vm->session->treo_state);
}
int treo_afk_guard_auto_fell_back(void) {
    int result = 0;
    jvm_bridge_visit_running_vm(treo_guard_read_visitor, &result);
    return result;
}
int treo_afk_guard_auto_fell_back_for_token(uint64_t token) {
    int result = 0;
    (void)jvm_bridge_visit_running_vm_for_token(token, treo_guard_read_visitor,
                                                &result);
    return result;
}
uint64_t treo_afk_guarded_paints(void) { return atomic_load_explicit(&treo_guarded_paints, memory_order_relaxed); }
uint64_t treo_afk_guarded_real(void) { return atomic_load_explicit(&treo_guarded_real, memory_order_relaxed); }
uint64_t treo_afk_guarded_late(void) { return atomic_load_explicit(&treo_guarded_late, memory_order_relaxed); }
uint64_t treo_afk_layer_frames(void) { return atomic_load_explicit(&treo_layer_frames, memory_order_relaxed); }


/* Native A/B switch + batched counters for the headless JAR image-byte cache. */
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_VM_IMAGE_CACHE_DISABLED)
#define TREO_VM_IMAGE_CACHE 1
#else
#define TREO_VM_IMAGE_CACHE 0
#endif
int treo_image_cache_build(void) { return TREO_VM_IMAGE_CACHE; }
static _Atomic uint64_t g_image_cache_hits, g_image_cache_stores, g_image_cache_stored_bytes;
uint64_t treo_image_cache_hits(void) {
    return atomic_load_explicit(&g_image_cache_hits, memory_order_relaxed);
}
uint64_t treo_image_cache_stores(void) {
    return atomic_load_explicit(&g_image_cache_stores, memory_order_relaxed);
}
uint64_t treo_image_cache_stored_bytes(void) {
    return atomic_load_explicit(&g_image_cache_stored_bytes, memory_order_relaxed);
}
static s32 n_afkImageCacheEnabled(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, TREO_VM_IMAGE_CACHE && treo_runtime_mode(runtime) == 8);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_imageCacheNote(Runtime *runtime, JClass *clazz) {
    int hits = runtime->jnienv->localvar_getInt(runtime->localvar, 0);
    int bytes = runtime->jnienv->localvar_getInt(runtime->localvar, 1);
    if (hits > 0)
        atomic_fetch_add_explicit(&g_image_cache_hits, (uint64_t)hits, memory_order_relaxed);
    if (bytes > 0) {
        atomic_fetch_add_explicit(&g_image_cache_stores, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_image_cache_stored_bytes, (uint64_t)bytes,
                                  memory_order_relaxed);
    }
    return RUNTIME_STATUS_NORMAL;
}

// 0 = repaint, 1 = serviceRepaints, 2 = doPaint.
// Suppress only for recognized NSO JAR + structurally verified Canvas in mode 8.
uint64_t treo_ninja_deep_skipped(int stage) {
    JarBoxTreoSnapshot snapshot = {0};
    if (stage < 0 || stage > 2 ||
        !jvm_bridge_treo_snapshot_for_token(jvm_bridge_session_token(), &snapshot)) return 0;
    return stage == 0 ? snapshot.repaint_skips :
        stage == 1 ? snapshot.service_skips : snapshot.paint_skips;
}

/*
 * Low-impact NSO game-loop heartbeat *proxy*. All three inspected NSO run()
 * loops request a repaint per iteration. Counting these requests measures
 * loop cadence, NOT actual progress, server activity, or auto correctness.
 * Use 16 one-second atomic bins to sample the ~8s immediately before Treo,
 * without a foreground UI timer, per-bytecode instrumentation or game-JAR edit.
 */
enum { TREO_NSO_BINS = 16 };
static _Atomic int treo_nso_canvas_seen;
static _Atomic uint64_t treo_nso_request_count;
static _Atomic uint64_t treo_nso_last_request_ns;
static _Atomic uint64_t treo_nso_request_bins[TREO_NSO_BINS];


/*
 * NSO game-thread compute-speed probe. At most one 60k-step benchmark
 * every 5 seconds, on the SAME non-main pthread that repeatedly requests
 * NSO frames (before and during Treo). Uses the same integer operations
 * for a side-by-side phase comparison. NEVER claims a hardware core ID,
 * clock rate, P/E assignment, real game tick, or battery power.
 */
enum { TREO_NSO_WORK_STEPS = 60000, TREO_NSO_WORK_PHASES = 2 };
typedef struct {
    _Atomic uint64_t count, cpu_ns, wall_ns;
    _Atomic int first_qos, last_qos;
} TreoNSOWork;
static TreoNSOWork treo_nso_work[TREO_NSO_WORK_PHASES];
static _Atomic uint64_t treo_nso_work_owner;
static _Atomic uint64_t treo_nso_work_last_ns[TREO_NSO_WORK_PHASES];
static _Thread_local uint64_t treo_nso_work_sink = UINT64_C(0x9e3779b97f4a7c15);

uint64_t treo_nso_work_samples(int phase) {
    return phase >= 0 && phase < TREO_NSO_WORK_PHASES
         ? atomic_load_explicit(&treo_nso_work[phase].count, memory_order_acquire)
         : 0;
}
double treo_nso_work_ns_per_step(int phase, int wall) {
    if (phase < 0 || phase >= TREO_NSO_WORK_PHASES) return -1.0;
    const uint64_t count = treo_nso_work_samples(phase);
    if (count == 0) return -1.0;
    const uint64_t ns = atomic_load_explicit(
        wall ? &treo_nso_work[phase].wall_ns : &treo_nso_work[phase].cpu_ns,
        memory_order_relaxed);
    return (double)ns / (double)(count * TREO_NSO_WORK_STEPS);
}
int treo_nso_work_qos(int phase) {
    return phase >= 0 && phase < TREO_NSO_WORK_PHASES &&
           treo_nso_work_samples(phase) > 0
         ? atomic_load_explicit(&treo_nso_work[phase].last_qos, memory_order_acquire)
         : -1;
}
uint64_t treo_nso_work_thread(void) {
    return atomic_load_explicit(&treo_nso_work_owner, memory_order_acquire);
}
static void treo_nso_work_probe(Runtime *runtime, uint64_t now) {
    if (!now || pthread_main_np()) return;
    const int mode = treo_runtime_mode(runtime);
    if (mode != 0 && mode != 8) return;
    const int phase = mode == 8 ? 1 : 0;
    // Reject 99%+ of calls before querying thread identity. Keep the
    // continuous repaint hot path as light as possible.
    uint64_t previous = atomic_load_explicit(&treo_nso_work_last_ns[phase],
                                             memory_order_relaxed);
    if (previous && (now < previous || now - previous < UINT64_C(5000000000)))
        return;
    // One thread is compared against itself, not against another app thread.
    uint64_t thread_id = 0;
    if (pthread_threadid_np(NULL, &thread_id) || !thread_id) return;
    uint64_t owner = atomic_load_explicit(&treo_nso_work_owner, memory_order_acquire);
    if (!owner) {
        uint64_t expected = 0;
        atomic_compare_exchange_strong_explicit(&treo_nso_work_owner, &expected,
             thread_id, memory_order_acq_rel, memory_order_relaxed);
        owner = atomic_load_explicit(&treo_nso_work_owner, memory_order_acquire);
    }
    if (owner != thread_id) return;
    if (!atomic_compare_exchange_strong_explicit(
            &treo_nso_work_last_ns[phase], &previous, now,
            memory_order_relaxed, memory_order_relaxed))
        return;
    qos_class_t qos = QOS_CLASS_UNSPECIFIED;
    if (pthread_get_qos_class_np(pthread_self(), &qos, NULL))
        qos = QOS_CLASS_UNSPECIFIED;
    volatile uint64_t result = treo_nso_work_sink;
    const uint64_t cpu0 = treo_thread_cpu_ns();
    const uint64_t wall0 = treo_afk_now_ns();
    if (!cpu0 || !wall0) return;
    for (unsigned i = 0; i < TREO_NSO_WORK_STEPS; ++i)
        result = result * UINT64_C(6364136223846793005)
                        + UINT64_C(1442695040888963407);
    const uint64_t cpu1 = treo_thread_cpu_ns();
    const uint64_t wall1 = treo_afk_now_ns();
    treo_nso_work_sink = result;
    if (cpu1 <= cpu0 || wall1 <= wall0) return;
    TreoNSOWork *stat = &treo_nso_work[phase];
    const uint64_t n = atomic_fetch_add_explicit(&stat->count, 1,
                                                  memory_order_acq_rel);
    if (n == 0)
        atomic_store_explicit(&stat->first_qos, (int)qos, memory_order_release);
    atomic_store_explicit(&stat->last_qos, (int)qos, memory_order_release);
    atomic_fetch_add_explicit(&stat->cpu_ns, cpu1 - cpu0, memory_order_relaxed);
    atomic_fetch_add_explicit(&stat->wall_ns, wall1 - wall0, memory_order_relaxed);
}
void treo_nso_probe_reset(void) {
    atomic_store_explicit(&treo_nso_work_owner, 0, memory_order_release);
    for (unsigned i = 0; i < TREO_NSO_WORK_PHASES; ++i) {
        atomic_store_explicit(&treo_nso_work[i].count, 0, memory_order_relaxed);
        atomic_store_explicit(&treo_nso_work[i].cpu_ns, 0, memory_order_relaxed);
        atomic_store_explicit(&treo_nso_work[i].wall_ns, 0, memory_order_relaxed);
        atomic_store_explicit(&treo_nso_work[i].first_qos, -1, memory_order_relaxed);
        atomic_store_explicit(&treo_nso_work[i].last_qos, -1, memory_order_relaxed);
        atomic_store_explicit(&treo_nso_work_last_ns[i], 0, memory_order_relaxed);
    }
    atomic_store_explicit(&treo_nso_canvas_seen, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_nso_request_count, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_nso_last_request_ns, 0, memory_order_relaxed);
    for (unsigned i = 0; i < TREO_NSO_BINS; ++i)
        atomic_store_explicit(&treo_nso_request_bins[i], 0, memory_order_relaxed);
}
int treo_nso_canvas_recognized(void) {
    return treo_ninja_deep_verified() &&
           atomic_load_explicit(&treo_nso_canvas_seen, memory_order_acquire);
}
typedef struct { int compatible_only, mode; } TreoParkChoice;
static void treo_park_choice_visitor(MiniJVM *vm, void *arg) {
    TreoParkChoice *choice = arg;
    choice->mode = jarbox_treo_safe_automatic_park_mode(&vm->session->treo_state,
                                         choice->compatible_only);
}
int treo_park_mode_for_token(uint64_t token, int compatible_only) {
    TreoParkChoice choice = {compatible_only, 0};
    if (!jvm_bridge_visit_running_vm_for_token(token, treo_park_choice_visitor, &choice))
        return 0;
    return choice.mode;
}
uint64_t treo_nso_repaint_requests(void) {
    return atomic_load_explicit(&treo_nso_request_count, memory_order_relaxed);
}
static void treo_nso_note_request(Runtime *runtime) {
    const uint64_t ns = treo_afk_now_ns();
    // During and before Treo, a 5s-gated *same-thread* fixed-work sample.
    treo_nso_work_probe(runtime, ns);
    atomic_fetch_add_explicit(&treo_nso_request_count, 1, memory_order_relaxed);
    if (!ns) return;
    atomic_store_explicit(&treo_nso_last_request_ns, ns, memory_order_relaxed);
    const uint64_t epoch = ns / 1000000000ULL;
    const unsigned slot = (unsigned)(epoch % TREO_NSO_BINS);
    const uint64_t fresh = (epoch << 32) | 1ULL;
    uint64_t current = atomic_load_explicit(&treo_nso_request_bins[slot],
                                            memory_order_relaxed);
    while ((current >> 32) != epoch) {
        if (atomic_compare_exchange_weak_explicit(&treo_nso_request_bins[slot],
                &current, fresh, memory_order_relaxed, memory_order_relaxed))
            return;
    }
    atomic_fetch_add_explicit(&treo_nso_request_bins[slot], 1,
                              memory_order_relaxed);
}
// A rolling *pre-Treo* baseline: full prior seconds only, minimum six
// observed active seconds out of eight, otherwise return unknown (-1).
double treo_nso_prior_repaint_hz(void) {
    if (!treo_nso_canvas_recognized()) return -1.0;
    const uint64_t ns = treo_afk_now_ns();
    if (ns < 9000000000ULL) return -1.0;
    const uint64_t epoch = ns / 1000000000ULL;
    uint64_t sum = 0;
    unsigned live = 0;
    for (unsigned age = 1; age <= 8; ++age) {
        const uint64_t wanted = epoch - age;
        const uint64_t packed = atomic_load_explicit(
            &treo_nso_request_bins[wanted % TREO_NSO_BINS],
            memory_order_relaxed);
        if ((packed >> 32) == wanted && (uint32_t)packed > 0) {
            sum += (uint32_t)packed;
            live++;
        }
    }
    return live >= 6 && sum >= 12 ? (double)sum / 8.0 : -1.0;
}
double treo_nso_last_repaint_gap_ms(void) {
    const uint64_t last = atomic_load_explicit(&treo_nso_last_request_ns,
                                               memory_order_relaxed);
    const uint64_t now = treo_afk_now_ns();
    if (!treo_nso_canvas_recognized() || !last || now < last) return -1.0;
    return (double)(now - last) / 1000000.0;
}
/* Java calls must read the owner JVM's Treo mode and NSO signature, never
 * the most recently launched process-wide diagnostic flags. The live Java
 * thread already holds its worker lease throughout this native invocation. */
static inline int ninja_profile_for_runtime(const Runtime *runtime) {
    return runtime && runtime->jvm && runtime->jvm->session &&
           jarbox_treo_nso_family_verified(&runtime->jvm->session->treo_state);
}
static inline int ninja_deep_active(const Runtime *runtime) {
    return ninja_profile_for_runtime(runtime) &&
           jarbox_treo_mode_get(&runtime->jvm->session->treo_state) == 8;
}
/*
 * All three supplied NSO builds have a direct Canvas subclass with exactly:
 *   aload_0; getfield OBJECT; aload_1;
 *   invokevirtual / invokestatic DRAW_DELEGATE; return
 * i.e. 9-byte paint(Graphics). Target class/constant-pool indices differ
 * across mods and are intentionally not used as an identity check.
 * Accept miniJVM's already-quickened invoke/getfield opcodes as well.
 */
static int treo_nso_simple_canvas_paint(JClass *canvas_class) {
    if (!canvas_class) return 0;
    u8 kind = __atomic_load_n(&canvas_class->treo_nso_canvas_kind, __ATOMIC_RELAXED);
    if (kind) return kind == 2;
    int safe_shape = 0;
    if (canvas_class->superclass &&
        utf8_equals_c(canvas_class->superclass->name,
                      "javax/microedition/lcdui/Canvas")) {
        MethodPool *pool = &canvas_class->methodPool;
        for (s32 i = 0; i < pool->method_used; i++) {
            MethodInfo *method = &pool->method[i];
            if (!utf8_equals_c(method->name, "paint") ||
                !utf8_equals_c(method->descriptor,
                               "(Ljavax/microedition/lcdui/Graphics;)V"))
                continue;
            CodeAttribute *ca = method->converted_code;
            if (!method->is_native && !method->is_sync && ca &&
                ca->code && ca->code_length == 9 &&
                ca->exception_table_length == 0) {
                const u8 *c = ca->code;
                safe_shape =
                    c[0] == op_aload_0 &&
                    (c[1] == op_getfield || c[1] == op_getfield_ref) &&
                    c[4] == op_aload_1 &&
                    (c[5] == op_invokevirtual || c[5] == op_invokevirtual_fast ||
                     c[5] == op_invokestatic || c[5] == op_invokestatic_fast) &&
                    c[8] == op_return;
            }
            break;
        }
    }
    __atomic_store_n(&canvas_class->treo_nso_canvas_kind,
                     safe_shape ? 2 : 1, __ATOMIC_RELAXED);
    return safe_shape;
}
static s32 n_ninjaDeepActive(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, ninja_deep_active(runtime));
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_ninjaDeepSkip(Runtime *runtime, JClass *clazz) {
    Instance *canvas = runtime->jnienv->localvar_getRefer(runtime->localvar, 0);
    int stage = runtime->jnienv->localvar_getInt(runtime->localvar, 1);
    // Recognition is allowed while visible, for a pre-Treo heartbeat
    // baseline. Only mode 8 may skip any actual rendering operation.
    const int qualified = stage >= 0 && stage <= 2 &&
        ninja_profile_for_runtime(runtime) && canvas &&
        (canvas->mb.type & MEM_TYPE_INS) &&
        treo_nso_simple_canvas_paint(canvas->mb.clazz);
    if (qualified) {
        jarbox_treo_nso_canvas_note(treo_runtime_state(runtime));
        if (stage == 0) {
            JarBoxTreoState *state=treo_runtime_state(runtime);
            jarbox_treo_nso_note_request(state);
            if (state && jarbox_background_enabled(&state->background_trace))
                jarbox_background_note(&state->background_trace,
                    clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW));
        }
        // Legacy heartbeat/work probes are process-wide diagnostics. Do
        // not mix samples from two tabs or run the extra benchmark in multi.
        if (jvm_bridge_supported_concurrent_sessions() == 1) {
            atomic_store_explicit(&treo_nso_canvas_seen, 1, memory_order_release);
            if (stage == 0) treo_nso_note_request(runtime);
        }
    }
    const int skip = qualified && ninja_deep_active(runtime);
    if (skip) jarbox_treo_nso_note_skip(treo_runtime_state(runtime), stage);
    push_int(runtime->stack, skip);
    return RUNTIME_STATUS_NORMAL;
}
// Candidate is a scoped screen sink, NOT a skipped paint or a new mode.
static s32 n_ninjaCorePaint(Runtime *runtime, JClass *clazz) {
    int enabled=0;
#if defined(TREO_NINJA_CORE_EXPERIMENT) && TREO_NINJA_CORE_EXPERIMENT
    JarBoxTreoState *state=treo_runtime_state(runtime);
    Instance *canvas=runtime->jnienv->localvar_getRefer(runtime->localvar,0);
    enabled=state && jarbox_ninja_core_active(&state->ninja_core,treo_runtime_mode(runtime)) &&
        ninja_profile_for_runtime(runtime) && canvas &&
        (canvas->mb.type & MEM_TYPE_INS) && treo_nso_simple_canvas_paint(canvas->mb.clazz);
#if defined(TREO_RESIDUAL_EXPERIMENT) && TREO_RESIDUAL_EXPERIMENT && __JVM_OS_IOS__
    // No sink-only candidate on a cold/unrecognized method or failed plan.
    enabled=enabled&&__atomic_load_n(&state->residual_plan_ready,__ATOMIC_ACQUIRE)&&
        !__atomic_load_n(&state->residual_faults,__ATOMIC_RELAXED)&&!treo_game_jit_is_enabled();
#endif
#if defined(TREO_CORE_ABA) && TREO_CORE_ABA
    if (enabled) {
        uint64_t epoch=__atomic_load_n(&state->core_aba_start_ns,__ATOMIC_ACQUIRE);
        unsigned phase=jarbox_core_aba_phase(epoch,clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW));
        enabled=jarbox_core_aba_sink(phase) &&
            epoch==__atomic_load_n(&state->core_aba_start_ns,__ATOMIC_ACQUIRE) &&
            jarbox_ninja_core_active(&state->ninja_core,treo_runtime_mode(runtime));
    }
#endif
#endif
    push_int(runtime->stack,enabled);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_ninjaCorePaintResult(Runtime *runtime, JClass *clazz) {
    JarBoxTreoState *state=treo_runtime_state(runtime);
    unsigned reason=(unsigned)runtime->jnienv->localvar_getInt(runtime->localvar,0);
    if (state) jarbox_ninja_core_finish(&state->ninja_core,reason);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_afkPaintPolicy(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, treo_runtime_mode(runtime));
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_afkCanvasResult(Runtime *runtime, JClass *clazz) {
    const int outcome = runtime->jnienv->localvar_getInt(runtime->localvar, 0);
    atomic_fetch_add_explicit(outcome ? &treo_guarded_paints : &treo_guarded_real, 1, memory_order_relaxed);
    if (outcome == 2) {
        atomic_fetch_add_explicit(&treo_guarded_late, 1, memory_order_relaxed);
        JarBoxTreoState *state = treo_runtime_state(runtime);
        pthread_mutex_lock(&g_treo_transition_lock);
        if (jarbox_treo_guard_note_late(state)) {
            // Keep the fallback inside this transition. A resume cannot
            // interleave between the late check and re-entering mode 1.
            // The Java worker already owns a lease; no foreground lookup.
            treo_display_wait_set_for_vm(runtime->jvm, 0);
            jarbox_treo_smart_force_safe(state);
            treo_apply_mode_locked(runtime->jvm, 1, treo_afk_now_ns());
        }
        pthread_mutex_unlock(&g_treo_transition_lock);
    }
    return RUNTIME_STATUS_NORMAL;
}

static uint64_t treo_main_wake_count;
static CFRunLoopObserverRef treo_main_wake_observer;
static void treo_main_woke(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *context) {
    ++treo_main_wake_count;
}
void treo_afk_wakes_set(int enabled) {
    if (enabled && !treo_main_wake_observer) {
        treo_main_wake_count = 0;
        treo_main_wake_observer = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopAfterWaiting,
                                                        true, 0, treo_main_woke, NULL);
        if (treo_main_wake_observer)
            CFRunLoopAddObserver(CFRunLoopGetMain(), treo_main_wake_observer, kCFRunLoopCommonModes);
    } else if (!enabled && treo_main_wake_observer) {
        CFRunLoopObserverInvalidate(treo_main_wake_observer);
        CFRelease(treo_main_wake_observer);
        treo_main_wake_observer = NULL;
    }
}
uint64_t treo_afk_main_wakes(void) { return treo_main_wake_count; }
/* A pthread may execute another generation after a prior MIDlet exits.
 * Never let a TLS headless Canvas handle carry over to a different VM. */
static _Thread_local s64 g_afk_canvas;
static _Thread_local uint64_t g_afk_canvas_owner_key;
#if defined(TREO_NINJA_CORE_EXPERIMENT) && TREO_NINJA_CORE_EXPERIMENT
static _Thread_local uint64_t g_afk_scope_serial;
static inline void treo_residual_scope_advance(void) {
    if(++g_afk_scope_serial==0)++g_afk_scope_serial;
}
#endif
static _Thread_local uint64_t g_afk_elided_local, g_afk_thread_id;
static _Atomic uint64_t g_afk_elided, g_afk_paint_tid, g_afk_gc_tid;
static atomic_bool treo_jar_auditing;
static _Atomic uint64_t treo_jar_game_tid;
uint64_t treo_afk_elided_calls(void) { return atomic_load_explicit(&g_afk_elided, memory_order_relaxed); }
void treo_afk_mark_gc_thread(void) {
    uint64_t tid = 0;
    pthread_threadid_np(NULL, &tid);
    atomic_store_explicit(&g_afk_gc_tid, tid, memory_order_relaxed);
}
static _Thread_local uint64_t g_afk_draw_count;
#if defined(TREO_BINARY_ABA) && TREO_BINARY_ABA
static _Thread_local JarBoxBinaryTrialScope binary_trial_scope;
#endif
uint64_t treo_afk_skipped_draws(void) { return atomic_load_explicit(&g_afk_skipped_draws, memory_order_relaxed); }
uint64_t treo_afk_skipped_paints(void) { return atomic_load_explicit(&g_afk_skipped_paints, memory_order_relaxed); }

static int treo_afk_skip_draw(RenderContext *rc) {
    if (!g_afk_canvas || !g_afk_canvas_owner_key ||
        g_afk_canvas_owner_key != rc->heap_key ||
        g_afk_canvas != (s64)(intptr_t)rc) return 0;
    g_afk_draw_count++;
    return 1;
}

#if defined(TREO_CANVAS_PHASE_DIAG) && TREO_CANVAS_PHASE_DIAG
static _Thread_local JarBoxCanvasPhaseScope treo_canvas_phase;
static inline uint64_t treo_canvas_phase_owner(Runtime *r) {
    return r && r->jvm && r->jvm->session ?
        __atomic_load_n(&r->jvm->session->token,__ATOMIC_ACQUIRE) : 0;
}
#endif
static s32 n_beginAfkPaint(Runtime *runtime, JClass *clazz) {
#if defined(TREO_NINJA_CORE_EXPERIMENT) && TREO_NINJA_CORE_EXPERIMENT
    treo_residual_scope_advance();
#endif
    const uint64_t key = jarbox_native_heap_key_for_runtime(runtime);
#if defined(TREO_CANVAS_PHASE_DIAG) && TREO_CANVAS_PHASE_DIAG
    uint64_t phaseOwner=key?treo_canvas_phase_owner(runtime):0;
    int phaseActive=phaseOwner && treo_runtime_mode(runtime)==1;
    jarbox_canvas_phase_begin(&treo_canvas_phase,phaseOwner,phaseActive,
                              phaseActive?treo_thread_cpu_ns():0);
#endif
    // Reset stale TLS Canvas state on a generation switch, not only on a
    // well-paired begin/end. No Java input is allowed to inherit this state.
    if (!key || key != g_afk_canvas_owner_key) {
        g_afk_canvas = 0;
        g_afk_draw_count=0;
        g_afk_elided_local=0;
        g_afk_canvas_owner_key = key;
    }
    s64 previous = g_afk_canvas;
    const int headless = runtime->jnienv->localvar_getInt(runtime->localvar, 2);
#if defined(TREO_BINARY_ABA) && TREO_BINARY_ABA
    JarBoxTreoState *trial=treo_runtime_state(runtime);
    uint64_t epoch=trial?__atomic_load_n(&trial->core_aba_start_ns,__ATOMIC_ACQUIRE):0;
    uint64_t now=epoch?clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW):0;
    int64_t canvas=runtime->jnienv->localvar_getLong_2slot(runtime->localvar,0);
    jarbox_binary_trial_begin(&binary_trial_scope,key,canvas,treo_runtime_mode(runtime),
                              headless,epoch,now);
    if (epoch && epoch!=__atomic_load_n(&trial->core_aba_start_ns,__ATOMIC_ACQUIRE))
        jarbox_binary_trial_end(&binary_trial_scope);
#endif
    if (key && (headless ||
        jarbox_treo_mode_get(&runtime->jvm->session->treo_state) == 2)) {
        s64 canvas = runtime->jnienv->localvar_getLong_2slot(runtime->localvar, 0);
        if (canvas) {
            g_afk_canvas = canvas;
            atomic_fetch_add_explicit(&g_afk_skipped_paints, 1, memory_order_relaxed);
        }
    }
    runtime->thrd_info->jarbox_headless_scope = g_afk_canvas != 0;
    runtime->jnienv->push_long(runtime->stack, previous);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_endAfkPaint(Runtime *runtime, JClass *clazz) {
#if defined(TREO_NINJA_CORE_EXPERIMENT) && TREO_NINJA_CORE_EXPERIMENT
    treo_residual_scope_advance();
#endif
#if defined(TREO_BINARY_ABA) && TREO_BINARY_ABA
    jarbox_binary_trial_end(&binary_trial_scope);
#endif
    const uint64_t key = jarbox_native_heap_key_for_runtime(runtime);
    const int same_owner=key && key==g_afk_canvas_owner_key;
    g_afk_canvas = same_owner ?
        runtime->jnienv->localvar_getLong_2slot(runtime->localvar, 0) : 0;
    if (!same_owner) { g_afk_elided_local=0; g_afk_draw_count=0; }
    if (!g_afk_canvas) g_afk_canvas_owner_key = 0;
    runtime->thrd_info->jarbox_headless_scope = g_afk_canvas != 0;
    JarBoxTreoState *state=same_owner ? treo_runtime_state(runtime) : NULL;
    if (!g_afk_canvas && g_afk_elided_local) {
        if (state) __atomic_fetch_add(&state->ninja_core.scoped_vm_draw_skips,g_afk_elided_local,__ATOMIC_RELAXED);
        atomic_fetch_add_explicit(&g_afk_elided, g_afk_elided_local, memory_order_relaxed);
        g_afk_elided_local = 0;
    }
    if (!g_afk_canvas && g_afk_draw_count) {
        if (state) __atomic_fetch_add(&state->ninja_core.scoped_native_draw_skips,g_afk_draw_count,__ATOMIC_RELAXED);
        atomic_fetch_add_explicit(&g_afk_skipped_draws, g_afk_draw_count, memory_order_relaxed);
        g_afk_draw_count = 0;
    }
#if defined(TREO_CANVAS_PHASE_DIAG) && TREO_CANVAS_PHASE_DIAG
    uint64_t phaseOwner=key?treo_canvas_phase_owner(runtime):0;
    JarBoxTreoState *phaseState=phaseOwner?treo_runtime_state(runtime):NULL;
    int phaseActive=phaseState && treo_runtime_mode(runtime)==1;
    uint64_t phaseEnd=treo_canvas_phase.active && treo_canvas_phase.depth==1 ?
        treo_thread_cpu_ns():0;
    jarbox_canvas_phase_end(&treo_canvas_phase,phaseState?&phaseState->canvas_phase:NULL,
                            phaseOwner,phaseActive,phaseEnd);
#endif
    return RUNTIME_STATUS_NORMAL;
}
static void stop_afk_haptics(void);

int j2me_render_is_afk_suspended(void) {
    return atomic_load_explicit(&treo_afk_mode, memory_order_relaxed) != 0;
}

typedef struct { int mode; uint64_t now_ns; } TreoModeChange;
static void treo_render_mode_visitor(MiniJVM *vm, void *arg) {
    const TreoModeChange *change = arg;
    pthread_mutex_lock(&g_treo_transition_lock);
    jarbox_ninja_core_arm(&vm->session->treo_state.ninja_core,0);
    treo_apply_mode_locked(vm, change->mode, change->now_ns);
    pthread_mutex_unlock(&g_treo_transition_lock);
    j2me_display_wake_for_vm(vm);
}
void treo_render_set_afk_mode(int mode) {
    const TreoModeChange change = {mode, treo_afk_now_ns()};
    const uint64_t token = jvm_bridge_session_token();
    if (!jvm_bridge_visit_running_vm_for_token(token, treo_render_mode_visitor,
                                                 (void *)&change) &&
        jvm_bridge_supported_concurrent_sessions() == 1) {
        // Startup/teardown compatibility mirror, never another VM's mode.
        atomic_store_explicit(&treo_afk_mode, mode, memory_order_release);
    }
}
int treo_render_set_afk_mode_for_token(uint64_t token, int mode) {
    const TreoModeChange change = {mode, treo_afk_now_ns()};
    return jvm_bridge_visit_running_vm_for_token(token, treo_render_mode_visitor,
                                                 (void *)&change);
}

/* Automatic parking is one serialized owner transition, not four
 * separately leased Swift calls. The 9-byte forwarder is recognition,
 * not a proof of delegate purity: automatic parking uses compatible mode.
 * Explicit diagnostic modes remain separate. No per-tab timer is needed. */
typedef struct { int compatible_only, mode, entering; } TreoParkTransition;
static void treo_park_transition_visitor(MiniJVM *vm, void *arg) {
    TreoParkTransition *change = arg;
    JarBoxTreoState *state = &vm->session->treo_state;
    pthread_mutex_lock(&g_treo_transition_lock);
    const int mode = change->entering
        ? jarbox_treo_safe_automatic_park_mode(state, change->compatible_only) : 0;
    jarbox_ninja_core_arm(&state->ninja_core,change->entering && !change->compatible_only &&
        mode==1 && jarbox_treo_nso_canvas_recognized(state));
    jarbox_treo_guard_auto_set(state, mode == 8);
    jarbox_treo_smart_set(state, mode == 8);
    if (mode == 8 && jvm_bridge_memory_state(NULL) != 0)
        jarbox_treo_smart_force_safe(state);
    treo_display_wait_set_for_vm(vm, 0);
    treo_apply_mode_locked(vm, mode, treo_afk_now_ns());
#if defined(TREO_BINARY_ABA) && TREO_BINARY_ABA
    // Same monotonic one-shot schedule, no scoped Core admission.
    if (change->entering && mode==1 && !state->core_aba_used) {
        uint64_t epoch=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (epoch) {
            state->core_aba_used=1;
            __atomic_store_n(&state->core_aba_start_ns,epoch,__ATOMIC_RELEASE);
        }
    }
#elif defined(TREO_CORE_ABA) && TREO_CORE_ABA
    // One eligible automatic park per owner lifetime. The existing core
    // admission, rejection and Java Canvas guards remain authoritative.
    if (change->entering && !change->compatible_only && !state->core_aba_used &&
        jarbox_ninja_core_active(&state->ninja_core,mode)) {
        uint64_t epoch=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (epoch) {
            state->core_aba_used=1;
            __atomic_store_n(&state->core_aba_start_ns,epoch,__ATOMIC_RELEASE);
        }
    }
#endif
    if (mode == 8) treo_display_wait_set_for_vm(vm, 1);
    change->mode = mode;
    pthread_mutex_unlock(&g_treo_transition_lock);
}
int treo_park_begin_for_token(uint64_t token, int compatible_only) {
    TreoParkTransition change = {compatible_only, 0, 1};
    if (!jvm_bridge_visit_running_vm_for_token(token, treo_park_transition_visitor, &change))
        return 0;
    return change.mode;
}
int treo_park_end_for_token(uint64_t token) {
    TreoParkTransition change = {0, 0, 0};
    return jvm_bridge_visit_running_vm_for_token(token, treo_park_transition_visitor, &change);
}
static void treo_read_mode_visitor(MiniJVM *vm, void *arg) {
    *(int *)arg = jarbox_treo_mode_get(&vm->session->treo_state);
}
int treo_mode_for_token(uint64_t token) {
    int mode = -1;
    (void)jvm_bridge_visit_running_vm_for_token(token, treo_read_mode_visitor, &mode);
    return mode;
}
void j2me_render_set_afk_suspended(int enabled) { treo_render_set_afk_mode(enabled ? 1 : 0); }

static s32 n_afkSuspended(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, treo_runtime_mode(runtime) != 0);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_takeAfkRefresh(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack,
             jarbox_treo_render_take_refresh(treo_runtime_state(runtime)));
    return RUNTIME_STATUS_NORMAL;
}

// Per-thread CPU time excludes sleeps and time waiting to be scheduled.
static atomic_bool treo_profile_enabled;
static atomic_bool treo_software_on;
static atomic_bool treo_direct_graphics_on;
static _Atomic uint64_t sw_frames, sw_regions, sw_fast, sw_checked, sw_mismatch, sw_direct;
enum { TreoAFKFastCanvas = 9 };
static _Atomic uint64_t treo_fast_fills, treo_fast_fill_checks, treo_fast_fill_mismatch, treo_fast_state;
TreoFastCanvasStats treo_fast_canvas_stats(void) {
    return (TreoFastCanvasStats){
        atomic_load_explicit(&treo_fast_fills, memory_order_relaxed),
        atomic_load_explicit(&treo_fast_fill_checks, memory_order_relaxed),
        atomic_load_explicit(&treo_fast_fill_mismatch, memory_order_relaxed),
        atomic_load_explicit(&treo_fast_state, memory_order_relaxed)
    };
}
static inline int treo_afk_fast_canvas(void) {
    return atomic_load_explicit(&treo_afk_mode, memory_order_relaxed) == TreoAFKFastCanvas;
}
static inline int treo_rc_fast_canvas(const RenderContext *rc) {
    return treo_rc_mode(rc) == TreoAFKFastCanvas;
}
// Extend only exact duplicate state operations, never the mode-9 raster policy.
static inline int treo_rc_reuse_state(const RenderContext *rc) {
    const int mode=treo_rc_mode(rc);
    return mode == TreoAFKFastCanvas || (mode == 1 &&
        !atomic_load_explicit(&treo_replay_state,memory_order_relaxed));
}
static inline void treo_note_state_reuse(RenderContext *rc) {
    ++rc->fastState;
    if (treo_rc_mode(rc)==1) ++rc->compatible_state_reuses;
}
int treo_direct_graphics_enabled(void) {
    return treo_afk_fast_canvas() || atomic_load_explicit(&treo_direct_graphics_on, memory_order_relaxed);
}
// The Java fast-path dispatch must not inherit another tab's mode 9.
// The historical global A/B switch is available only in one-VM builds.
int treo_direct_graphics_enabled_for_runtime(Runtime *runtime) {
    return treo_runtime_mode(runtime) == TreoAFKFastCanvas ||
        (jvm_bridge_supported_concurrent_sessions() == 1 &&
         atomic_load_explicit(&treo_direct_graphics_on, memory_order_relaxed));
}
void treo_direct_graphics_set_enabled(int enabled) {
    atomic_store_explicit(&treo_direct_graphics_on, enabled != 0, memory_order_relaxed);
}
int treo_software_enabled(void) {
    return atomic_load_explicit(&treo_software_on, memory_order_relaxed);
}
void treo_software_set_enabled(int enabled) {
    atomic_store_explicit(&treo_software_on, enabled != 0, memory_order_relaxed);
}
TreoSoftwareStats treo_software_stats(void) {
    return (TreoSoftwareStats){
        atomic_load_explicit(&sw_frames, memory_order_relaxed),
        atomic_load_explicit(&sw_regions, memory_order_relaxed),
        atomic_load_explicit(&sw_fast, memory_order_relaxed),
        atomic_load_explicit(&sw_checked, memory_order_relaxed),
        atomic_load_explicit(&sw_mismatch, memory_order_relaxed),
        atomic_load_explicit(&sw_direct, memory_order_relaxed),
    };
}
static void treo_software_publish(RenderContext *rc) {
    if (rc->swRegions) atomic_fetch_add_explicit(&sw_regions, rc->swRegions, memory_order_relaxed);
    if (rc->swFast) atomic_fetch_add_explicit(&sw_fast, rc->swFast, memory_order_relaxed);
    if (rc->swChecked) atomic_fetch_add_explicit(&sw_checked, rc->swChecked, memory_order_relaxed);
    if (rc->swMismatch) atomic_fetch_add_explicit(&sw_mismatch, rc->swMismatch, memory_order_relaxed);
    if (rc->swDirect) atomic_fetch_add_explicit(&sw_direct, rc->swDirect, memory_order_relaxed);
    if (rc->fastFills) atomic_fetch_add_explicit(&treo_fast_fills, rc->fastFills, memory_order_relaxed);
    if (rc->fastFillChecks) atomic_fetch_add_explicit(&treo_fast_fill_checks, rc->fastFillChecks, memory_order_relaxed);
    if (rc->fastFillMismatch) atomic_fetch_add_explicit(&treo_fast_fill_mismatch, rc->fastFillMismatch, memory_order_relaxed);
    if (rc->fastState) atomic_fetch_add_explicit(&treo_fast_state, rc->fastState, memory_order_relaxed);
    rc->fastFills = rc->fastFillChecks = rc->fastFillMismatch = rc->fastState = 0;
    rc->swRegions = rc->swFast = rc->swChecked = rc->swMismatch = rc->swDirect = 0;
}
static atomic_bool treo_region_cull_enabled;
int treo_render_region_cull_enabled(void) {
    return atomic_load_explicit(&treo_region_cull_enabled, memory_order_relaxed);
}
void treo_render_set_region_cull_enabled(int enabled) {
    atomic_store_explicit(&treo_region_cull_enabled, enabled != 0, memory_order_relaxed);
}
static _Atomic uint64_t treo_prof_paints;
static _Atomic uint64_t treo_prof_paint_ns;
static _Atomic uint64_t treo_prof_flushes;
static _Atomic uint64_t treo_prof_snapshots;
static _Atomic uint64_t treo_prof_snapshot_ns;
static _Atomic uint64_t treo_prof_replaced;
static _Atomic uint64_t treo_prof_submitted;
static _Atomic uint64_t treo_prof_region_calls;
static _Atomic uint64_t treo_prof_region_culled;
static _Atomic uint64_t treo_prof_live_boundary_ns;
static _Atomic uint64_t treo_prof_region_samples;
static _Atomic uint64_t treo_prof_region_sample_ns;
#define TREO_PROF_ADD(field, amount) atomic_fetch_add_explicit(&treo_prof_##field, (amount), memory_order_relaxed)
static int treo_profile_active(void) {
    return atomic_load_explicit(&treo_profile_enabled, memory_order_acquire)
        && !j2me_render_is_afk_suspended();
}
static uint64_t treo_thread_cpu_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

// Diagnostic: fixed instruction/work mix to distinguish slower execution
// from additional UIKit work. 120k dependent volatile integer operations
// sampled 12 times per 30-second leg (<1% duty). Never spins continuously.
static volatile uint64_t treo_main_bench_sink = UINT64_C(0x9e3779b97f4a7c15);
double treo_main_fixed_work_ns_per_step(void) {
    if (!pthread_main_np()) return -1;
    enum { Steps = 120000 };
    volatile uint64_t value = treo_main_bench_sink;
    const uint64_t start = treo_thread_cpu_ns();
    if (!start) return -1;
    for (unsigned i = 0; i < Steps; ++i) {
        value = value * UINT64_C(6364136223846793005) + UINT64_C(1442695040888963407);
    }
    const uint64_t end = treo_thread_cpu_ns();
    treo_main_bench_sink = value;
    if (end <= start) return -1;
    return (double)(end - start) / (double)Steps;
}
// Fixed identical integer-work probe on the EXISTING main/JAR/GC pthreads.
// CPU thread-clock excludes sleep; monotonic wall-clock includes descheduling.
// Diagnostic only: never infers P/E core, frequencies, watts or game throughput.
enum { TreoDiagThreads = 3, TreoDiagSteps = 120000 };
typedef struct { _Atomic uint64_t n, cpu, wall, last; } TreoDiagStat;
static TreoDiagStat g_diag_stat[3];
static _Atomic uint64_t g_diag_epoch;
static atomic_bool g_diag_active;
static _Atomic uint64_t g_diag_gc_n, g_diag_gc_cpu, g_diag_gc_wall;
static _Thread_local uint64_t g_diag_sink = UINT64_C(0x9e3779b97f4a7c15);
static _Thread_local uint64_t g_diag_gc_start_cpu, g_diag_gc_start_wall, g_diag_gc_start_epoch;
void treo_diag_set(int on) {
    atomic_store_explicit(&g_diag_active, false, memory_order_release);
    atomic_fetch_add_explicit(&g_diag_epoch, 1, memory_order_acq_rel);
    if (on) {
        for (int i = 0; i < TreoDiagThreads; ++i) {
            atomic_store(&g_diag_stat[i].n, 0);
            atomic_store(&g_diag_stat[i].cpu, 0);
            atomic_store(&g_diag_stat[i].wall, 0);
            atomic_store(&g_diag_stat[i].last, 0);
        }
        atomic_store(&g_diag_gc_n, 0);
        atomic_store(&g_diag_gc_cpu, 0);
        atomic_store(&g_diag_gc_wall, 0);
        atomic_store_explicit(&g_diag_active, true, memory_order_release);
    }
}
void treo_diag_sample(int kind) {
    if (kind < 0 || kind >= TreoDiagThreads ||
        !atomic_load_explicit(&g_diag_active, memory_order_acquire)) return;
    const uint64_t epoch = atomic_load_explicit(&g_diag_epoch, memory_order_acquire);
    const uint64_t now = treo_afk_now_ns();
    if (!now) return;
    if (kind != 0) {
        uint64_t last = atomic_load_explicit(&g_diag_stat[kind].last, memory_order_relaxed);
        if (now < last || now - last < UINT64_C(2000000000)) return;
        if (!atomic_compare_exchange_strong_explicit(&g_diag_stat[kind].last, &last,
                now, memory_order_relaxed, memory_order_relaxed)) return;
    }
    volatile uint64_t value = g_diag_sink;
    const uint64_t c0 = treo_thread_cpu_ns(), w0 = treo_afk_now_ns();
    if (!c0 || !w0) return;
    for (unsigned i = 0; i < TreoDiagSteps; ++i)
        value = value * UINT64_C(6364136223846793005) + UINT64_C(1442695040888963407);
    const uint64_t c1 = treo_thread_cpu_ns(), w1 = treo_afk_now_ns();
    g_diag_sink = value;
    if (c1 < c0 || w1 < w0 || 
        !atomic_load_explicit(&g_diag_active, memory_order_acquire) ||
        atomic_load_explicit(&g_diag_epoch, memory_order_acquire) != epoch) return;
    atomic_fetch_add_explicit(&g_diag_stat[kind].cpu, c1 - c0, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_diag_stat[kind].wall, w1 - w0, memory_order_relaxed);
    atomic_fetch_add_explicit(&g_diag_stat[kind].n, 1, memory_order_release);
}
uint64_t treo_diag_samples(int kind) {
    return (kind >= 0 && kind < TreoDiagThreads)
        ? atomic_load_explicit(&g_diag_stat[kind].n, memory_order_acquire) : 0;
}
double treo_diag_ns_per_step(int kind, int wall) {
    if (kind < 0 || kind >= TreoDiagThreads) return -1;
    uint64_t n = treo_diag_samples(kind);
    if (!n) return -1;
    const uint64_t elapsed = atomic_load_explicit(wall ?
        &g_diag_stat[kind].wall : &g_diag_stat[kind].cpu, memory_order_acquire);
    return (double)elapsed / ((double)n * TreoDiagSteps);
}
void treo_diag_gc_cycle_begin(void) {
    g_diag_gc_start_epoch = 0;
    if (!atomic_load_explicit(&g_diag_active, memory_order_acquire)) return;
    g_diag_gc_start_epoch = atomic_load_explicit(&g_diag_epoch, memory_order_acquire);
    g_diag_gc_start_cpu = treo_thread_cpu_ns();
    g_diag_gc_start_wall = treo_afk_now_ns();
}
void treo_diag_gc_cycle_end(void) {
    if (!g_diag_gc_start_epoch || !g_diag_gc_start_cpu || !g_diag_gc_start_wall) return;
    const uint64_t c = treo_thread_cpu_ns(), w = treo_afk_now_ns();
    if (atomic_load_explicit(&g_diag_active, memory_order_acquire) &&
        atomic_load_explicit(&g_diag_epoch, memory_order_acquire) == g_diag_gc_start_epoch &&
        c >= g_diag_gc_start_cpu && w >= g_diag_gc_start_wall) {
        atomic_fetch_add_explicit(&g_diag_gc_cpu, c - g_diag_gc_start_cpu, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_diag_gc_wall, w - g_diag_gc_start_wall, memory_order_relaxed);
        atomic_fetch_add_explicit(&g_diag_gc_n, 1, memory_order_release);
    }
    g_diag_gc_start_epoch = 0;
}
uint64_t treo_diag_gc_cycles(void) { return atomic_load_explicit(&g_diag_gc_n, memory_order_acquire); }
double treo_diag_gc_cpu_ms(void) { return (double)atomic_load_explicit(&g_diag_gc_cpu, memory_order_acquire) / 1000000.0; }
double treo_diag_gc_wall_ms(void) { return (double)atomic_load_explicit(&g_diag_gc_wall, memory_order_acquire) / 1000000.0; }

// Main-thread-only diagnostic snapshots, taken at leg boundaries, not per frame.
static NSDictionary<NSNumber *, NSArray<NSNumber *> *> *treo_afk_thread_start;
static struct rusage treo_afk_rusage_start;
static int treo_afk_rusage_valid;
static double treo_mach_time(time_value_t t) { return t.seconds + t.microseconds / 1e6; }
static NSDictionary<NSNumber *, NSArray<NSNumber *> *> *treo_afk_read_threads(void) {
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return nil;
    NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *out = [NSMutableDictionary new];
    for (mach_msg_type_number_t i = 0; i < count; ++i) {
        thread_identifier_info_data_t ident;
        thread_basic_info_data_t info;
        mach_msg_type_number_t ic = THREAD_IDENTIFIER_INFO_COUNT, bc = THREAD_BASIC_INFO_COUNT;
        if (thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&ident, &ic) == KERN_SUCCESS &&
            thread_info(threads[i], THREAD_BASIC_INFO, (thread_info_t)&info, &bc) == KERN_SUCCESS) {
            out[@(ident.thread_id)] = @[@(treo_mach_time(info.user_time)), @(treo_mach_time(info.system_time))];
        }
        mach_port_deallocate(mach_task_self(), threads[i]);
    }
    vm_deallocate(mach_task_self(), (vm_address_t)threads, (vm_size_t)count * sizeof(*threads));
    return out;
}
double treo_afk_current_thread_cpu(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) != 0) return -1;
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

// Legacy trace reads main live. The explicit JAR profile can briefly suspend
// it for a bounded stack snapshot. Symbolization always happens afterward.
static dispatch_queue_t treo_trace_queue;
static dispatch_source_t treo_trace_timer;
static thread_t treo_trace_thread;
enum { TreoTraceMax = 2048, TreoTraceDepth = 64 };
static struct { uintptr_t pc, lr, frames[TreoTraceDepth]; unsigned depth; } treo_trace_points[TreoTraceMax];
static unsigned treo_trace_count, treo_trace_ticks, treo_trace_errors, treo_trace_chains, treo_trace_unstable;
static bool treo_trace_has_stack, treo_trace_snapshot_mode, treo_trace_source_only;
// Main writes; sampler checks the same epoch again with main suspended.
// Low bit marks the interval opened by the BeforeSources marker.
static _Atomic uint64_t treo_trace_source_epoch;
static unsigned treo_trace_source_checks, treo_trace_source_changed;

void treo_afk_main_source_mark(int active) {
    uint64_t old = atomic_load_explicit(&treo_trace_source_epoch, memory_order_relaxed);
    atomic_store_explicit(&treo_trace_source_epoch, ((old + 2) & ~UINT64_C(1)) | (active != 0),
                          memory_order_release);
}

#if defined(__arm64__)
static unsigned treo_trace_walk(uintptr_t fp, uintptr_t low, uintptr_t high,
                                uintptr_t frames[TreoTraceDepth]) {
    unsigned depth = 0;
    while (depth < TreoTraceDepth && fp >= low && high >= 16 && fp <= high - 16 && !(fp & 15)) {
        uintptr_t pair[2];
        vm_size_t copied = 0;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof(pair),
                              (vm_address_t)(uintptr_t)pair, &copied) != KERN_SUCCESS ||
            copied != sizeof(pair)) break;
        uintptr_t ret = pair[1];
#if __has_feature(ptrauth_calls)
        ret = (uintptr_t)ptrauth_strip((void *)ret, ptrauth_key_return_address);
#endif
        if (!ret || (ret & 3)) break;
        frames[depth++] = ret - 4; // call site, not the next instruction
        if (pair[0] <= fp) break;
        fp = pair[0];
    }
    return depth;
}
#endif

#if defined(__arm64__)
// Single bounded copy; no allocation, ObjC, unwinding, or symbolization while
// main is suspended. The buffer is private to the serial sampler queue.
// 1 = captured, 0 = Mach error, -1 = phase changed before suspension.
static int treo_trace_snapshot(thread_t target, uintptr_t low, uintptr_t high, unsigned slot, uint64_t epoch) {
    static uintptr_t words[16384 / sizeof(uintptr_t)];
    arm_thread_state64_t state;
    mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
    vm_size_t copied = 0;
    uintptr_t sp = 0, fp = 0;
    if (thread_suspend(target) != KERN_SUCCESS) return 0;
    if (epoch && atomic_load_explicit(&treo_trace_source_epoch, memory_order_acquire) != epoch)
        return thread_resume(target) == KERN_SUCCESS ? -1 : 0;
    kern_return_t status = thread_get_state(target, ARM_THREAD_STATE64, (thread_state_t)&state, &n);
    if (status == KERN_SUCCESS) {
        sp = (uintptr_t)arm_thread_state64_get_sp(state);
        fp = (uintptr_t)arm_thread_state64_get_fp(state);
        if (sp >= low && sp < high && fp >= sp && !(sp & 15)) {
            const size_t size = MIN(high - sp, sizeof(words));
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)sp, size,
                                  (vm_address_t)(uintptr_t)words, &copied) != KERN_SUCCESS)
                copied = 0;
        }
    }
    const kern_return_t resumed = thread_resume(target);
    if (status != KERN_SUCCESS || resumed != KERN_SUCCESS) return false;

    treo_trace_points[slot].pc = (uintptr_t)arm_thread_state64_get_pc(state);
    treo_trace_points[slot].lr = (uintptr_t)arm_thread_state64_get_lr(state);
    unsigned depth = 0;
    while (depth < TreoTraceDepth && copied >= 16 && fp >= sp &&
           fp - sp <= copied - 16 && !(fp & 15)) {
        const size_t idx = (fp - sp) / sizeof(uintptr_t);
        uintptr_t ret = words[idx + 1];
#if __has_feature(ptrauth_calls)
        ret = (uintptr_t)ptrauth_strip((void *)ret, ptrauth_key_return_address);
#endif
        if (ret < 4 || (ret & 3)) break;
        treo_trace_points[slot].frames[depth++] = ret - 4;
        if (words[idx] <= fp) break;
        fp = words[idx];
    }
    treo_trace_points[slot].depth = depth;
    if (depth) ++treo_trace_chains;
    return 1;
}
#endif

static void treo_afk_trace_begin(bool stack, bool sourceOnly, bool requireSnapshot) {
    treo_afk_main_trace_cancel();
#if defined(__arm64__)
    if (!treo_trace_queue) treo_trace_queue = dispatch_queue_create("treo.afk.main.trace", DISPATCH_QUEUE_SERIAL);
    treo_trace_thread = mach_thread_self();
    treo_trace_count = treo_trace_ticks = treo_trace_errors = treo_trace_chains = treo_trace_unstable = 0;
    treo_trace_has_stack = stack;
    treo_trace_source_only = sourceOnly;
    treo_trace_source_checks = treo_trace_source_changed = 0;
    treo_trace_snapshot_mode = requireSnapshot || sourceOnly || (stack && atomic_load_explicit(&treo_jar_auditing, memory_order_relaxed));
    const pthread_t main = pthread_self();
    const uintptr_t high = (uintptr_t)pthread_get_stackaddr_np(main);
    const size_t stack_size = pthread_get_stacksize_np(main);
    const uintptr_t low = stack_size <= high ? high - stack_size : high;
    const thread_t target = treo_trace_thread;
    treo_trace_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, treo_trace_queue);
    const uint64_t interval = treo_trace_snapshot_mode ? 47000000 : (stack ? 53000000 : 43000000);
    dispatch_source_set_timer(treo_trace_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval), interval, 9000000);
    dispatch_source_set_event_handler(treo_trace_timer, ^{
        ++treo_trace_ticks;
        uint64_t epoch = 0;
        if (sourceOnly) {
            epoch = atomic_load_explicit(&treo_trace_source_epoch, memory_order_acquire);
            if (!(epoch & 1)) return;
            ++treo_trace_source_checks;
        }
        thread_basic_info_data_t info;
        mach_msg_type_number_t n = THREAD_BASIC_INFO_COUNT;
        if (thread_info(target, THREAD_BASIC_INFO, (thread_info_t)&info, &n) != KERN_SUCCESS) {
            ++treo_trace_errors; return;
        }
        if (info.run_state != TH_STATE_RUNNING || treo_trace_count == TreoTraceMax) return;
        if (treo_trace_snapshot_mode) {
            int captured = treo_trace_snapshot(target, low, high, treo_trace_count, epoch);
            if (captured > 0) ++treo_trace_count;
            else if (captured < 0) ++treo_trace_source_changed;
            else ++treo_trace_errors;
            return;
        }
        arm_thread_state64_t state;
        n = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(target, ARM_THREAD_STATE64, (thread_state_t)&state, &n) != KERN_SUCCESS) {
            ++treo_trace_errors; return;
        }
        const unsigned slot = treo_trace_count++;
        const uintptr_t pc = (uintptr_t)arm_thread_state64_get_pc(state);
        treo_trace_points[slot].pc = pc;
        treo_trace_points[slot].lr = (uintptr_t)arm_thread_state64_get_lr(state);
        treo_trace_points[slot].depth = 0;
        if (!stack) return;
        const uintptr_t fp = (uintptr_t)arm_thread_state64_get_fp(state);
        const uintptr_t sp = (uintptr_t)arm_thread_state64_get_sp(state);
        if (sp < low || sp >= high || fp < sp) return;
        unsigned depth = treo_trace_walk(fp, sp, high, treo_trace_points[slot].frames);
        if (!depth) return;
        arm_thread_state64_t after;
        n = ARM_THREAD_STATE64_COUNT;
        if (thread_get_state(target, ARM_THREAD_STATE64, (thread_state_t)&after, &n) != KERN_SUCCESS ||
            pc != (uintptr_t)arm_thread_state64_get_pc(after) ||
            fp != (uintptr_t)arm_thread_state64_get_fp(after) ||
            sp != (uintptr_t)arm_thread_state64_get_sp(after) ||
            treo_trace_points[slot].lr != (uintptr_t)arm_thread_state64_get_lr(after)) {
            ++treo_trace_unstable;
            return;
        }
        treo_trace_points[slot].depth = depth;
        ++treo_trace_chains;
    });
    dispatch_resume(treo_trace_timer);
#endif
}
void treo_afk_main_trace_begin(void) { treo_afk_trace_begin(false, false, false); }
void treo_afk_main_stack_begin(void) { treo_afk_trace_begin(true, false, false); }
void treo_afk_main_source_trace_begin(void) { treo_afk_trace_begin(true, true, true); }
// Always use a bounded, consistent stack snapshot for the JarBox AFK probe.
void treo_afk_main_stack_snapshot_begin(void) { treo_afk_trace_begin(true, false, true); }

void treo_afk_main_trace_cancel(void) {
    if (!treo_trace_timer) return;
    dispatch_source_cancel(treo_trace_timer);
    dispatch_sync(treo_trace_queue, ^{});
    treo_trace_timer = nil;
    mach_port_deallocate(mach_task_self(), treo_trace_thread);
    treo_trace_thread = MACH_PORT_NULL;
}
static NSString *treo_trace_symbol(uintptr_t address) {
    if (!address) return @"?";
    Dl_info info = {0};
    if (!dladdr((const void *)address, &info)) return [NSString stringWithFormat:@"0x%llx", (unsigned long long)address];
    NSString *image = info.dli_fname ? [NSString stringWithUTF8String:info.dli_fname].lastPathComponent : @"?";
    // dyld can supply the literal name "<redacted>" for many unrelated PCs.
    // Keep the exact image-relative address instead of collapsing those PCs.
    if (info.dli_sname && strcmp(info.dli_sname, "<redacted>") != 0)
        return [NSString stringWithFormat:@"%@:%s", image, info.dli_sname];
    return [NSString stringWithFormat:@"%@+0x%llx", image, (unsigned long long)(address - (uintptr_t)info.dli_fbase)];
}
static void treo_trace_append_chains(NSMutableString *out, NSDictionary<NSString *, NSNumber *> *hist,
                                    NSUInteger limit) {
    NSArray<NSString *> *keys = [hist keysSortedByValueUsingSelector:@selector(compare:)];
    for (NSUInteger k = keys.count, shown = 0; k && shown < limit; --k, ++shown) {
        NSString *key = keys[k - 1];
        [out appendFormat:@"\n%@ × %@", hist[key], key];
    }
}

static char *treo_trace_source_report(void) {
    NSMutableDictionary<NSNumber *, NSString *> *symbols = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSNumber *> *work = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSNumber *> *wait = [NSMutableDictionary new];
    unsigned waits = 0, capped = 0;
    for (unsigned i = 0; i < treo_trace_count; ++i) {
        uintptr_t pc = treo_trace_points[i].pc;
        NSString *leaf = symbols[@(pc)];
        if (!leaf) { leaf = treo_trace_symbol(pc); symbols[@(pc)] = leaf; }
        NSString *name = [[leaf componentsSeparatedByString:@":"] lastObject];
        // Identify recognizable wait/syscall leaves only. Remaining samples
        // can still be runnable or in an unrecognized wait, not necessarily on CPU.
        bool looksWaiting = [name hasPrefix:@"mach_msg"] || [name hasPrefix:@"__mach_msg"]
            || [name hasPrefix:@"semaphore_wait"] || [name hasPrefix:@"semaphore_timedwait"]
            || [name hasPrefix:@"__psynch_cvwait"] || [name hasPrefix:@"__psynch_mutexwait"]
            || [name hasPrefix:@"__ulock_wait"] || [name hasPrefix:@"__semwait_signal"]
            || [name hasPrefix:@"kevent"] || [name hasPrefix:@"__kevent"];
        NSMutableString *key = [NSMutableString stringWithString:leaf];
        unsigned depth = treo_trace_points[i].depth;
        if (depth == TreoTraceDepth) ++capped;
        for (unsigned j = 0; j < depth; ++j) {
            NSNumber *addr = @(treo_trace_points[i].frames[j]);
            NSString *frame = symbols[addr];
            if (!frame) { frame = treo_trace_symbol(addr.unsignedLongLongValue); symbols[addr] = frame; }
            [key appendFormat:@" ← %@", frame];
        }
        if (!depth) [key appendFormat:@" | LR %@", treo_trace_symbol(treo_trace_points[i].lr)];
        if (looksWaiting) ++waits;
        NSMutableDictionary<NSString *, NSNumber *> *bucket = looksWaiting ? wait : work;
        bucket[key] = @(bucket[key].unsignedIntValue + 1);
    }
    NSMutableString *out = [NSMutableString stringWithFormat:
        @"Stack sau mốc Source: %u mẫu / %u lần trong pha / %u lần kiểm; %u đổi mốc, %u lỗi; %u có chuỗi FP, %u chạm giới hạn %u frame.",
        treo_trace_count, treo_trace_source_checks, treo_trace_ticks, treo_trace_source_changed,
        treo_trace_errors, treo_trace_chains, capped, TreoTraceDepth];
    [out appendFormat:@"\nKhông thấy leaf chờ đã biết (%u mẫu), chuỗi hay gặp:", treo_trace_count - waits];
    treo_trace_append_chains(out, work, 5);
    [out appendFormat:@"\nLeaf dạng chờ/Mach IPC (%u mẫu), chuỗi hay gặp:", waits];
    treo_trace_append_chains(out, wait, 2);
    return strdup(out.UTF8String);
}

char *treo_afk_main_trace_end(void) {
    treo_afk_main_trace_cancel();
    if (treo_trace_source_only) return treo_trace_source_report();
    NSMutableDictionary<NSString *, NSNumber *> *hist = [NSMutableDictionary new];
    NSMutableDictionary<NSNumber *, NSString *> *symbols = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSNumber *> *caEntry = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSNumber *> *moduleHist = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSNumber *> *leafHist = [NSMutableDictionary new];
    unsigned deep = 0, maxDepth = 0, caSamples = 0;
    for (unsigned i = 0; i < treo_trace_count; ++i) {
        NSNumber *pc = @(treo_trace_points[i].pc), *lr = @(treo_trace_points[i].lr);
        NSString *leaf = symbols[pc];
        if (!leaf) { leaf = treo_trace_symbol(treo_trace_points[i].pc); symbols[pc] = leaf; }
        leafHist[leaf] = @(leafHist[leaf].unsignedIntValue + 1);
        Dl_info moduleInfo = {0};
        NSString *moduleName = @"unknown";
        if (dladdr((const void *)treo_trace_points[i].pc, &moduleInfo) && moduleInfo.dli_fname) {
            NSString *fileName = [NSString stringWithUTF8String:moduleInfo.dli_fname];
            if (fileName) moduleName = fileName.lastPathComponent;
        }
        moduleHist[moduleName] = @(moduleHist[moduleName].unsignedIntValue + 1);
        NSString *link = symbols[lr];
        if (!link) { link = treo_trace_symbol(treo_trace_points[i].lr); symbols[lr] = link; }
        if (treo_trace_snapshot_mode) {
            const unsigned depth = treo_trace_points[i].depth;
            if (depth == TreoTraceDepth) ++deep;
            if (depth > maxDepth) maxDepth = depth;
            NSString *entry = ([leaf hasPrefix:@"QuartzCore+"] || [leaf hasPrefix:@"QuartzCore:"]) ? leaf : nil;
            NSString *boundary = nil;
            for (unsigned j = 0; j < depth; ++j) {
                const uintptr_t addr = treo_trace_points[i].frames[j];
                NSNumber *idKey = @(addr);
                NSString *frame = symbols[idKey];
                if (!frame) { frame = treo_trace_symbol(addr); symbols[idKey] = frame; }
                if ([frame hasPrefix:@"QuartzCore+"] || [frame hasPrefix:@"QuartzCore:"]) {
                    entry = frame;
                    boundary = nil;
                } else if (entry && !boundary) {
                    boundary = frame;
                }
            }
            if (entry) {
                ++caSamples;
                NSString *key = [NSString stringWithFormat:@"%@ ← %@", entry, boundary ?: @"(chưa tới caller ngoài QuartzCore)"];
                caEntry[key] = @(caEntry[key].unsignedIntValue + 1);
            }
        }
        NSMutableString *key = [NSMutableString stringWithString:leaf];
        if (treo_trace_points[i].depth) {
            unsigned depth = treo_trace_points[i].depth;
            for (unsigned j = 0; j < depth; ++j) {
                // Keep the near callers and the outermost frames in a compact report.
                if (j == 5 && depth > 8) { [key appendString:@" ← …"]; j = depth - 2; }
                uintptr_t addr = treo_trace_points[i].frames[j];
                NSNumber *idKey = @(addr);
                NSString *frame = symbols[idKey];
                if (!frame) { frame = treo_trace_symbol(addr); symbols[idKey] = frame; }
                [key appendFormat:@" ← %@", frame];
            }
        } else {
            [key appendFormat:@" | LR %@", link];
        }
        hist[key] = @(hist[key].unsignedIntValue + 1);
    }
    NSMutableString *result = [NSMutableString stringWithFormat:@"Main PC/LR: %u mẫu runnable / %u lần lấy; %u lỗi",
                               treo_trace_count, treo_trace_ticks, treo_trace_errors];
    if (treo_trace_snapshot_mode) {
        [result appendString:@"\nModule xuất hiện nhiều (số mẫu, không phải % CPU của module):"];
        treo_trace_append_chains(result, moduleHist, 8);
        [result appendString:@"\nPC/hàm xuất hiện nhiều:"];
        treo_trace_append_chains(result, leafHist, 8);
        [result appendFormat:@"\n%u chuỗi FP · sâu nhất %u · %u chạm giới hạn %u frame (16 KiB/mẫu)",
            treo_trace_chains, maxDepth, deep, TreoTraceDepth];
        [result appendFormat:@"\nBiên QuartzCore trong %u mẫu (frame QuartzCore ngoài cùng đã thấy ← caller):", caSamples];
        NSArray<NSString *> *entries = [caEntry keysSortedByValueUsingSelector:@selector(compare:)];
        for (NSUInteger k = entries.count, shown = 0; k && shown < 8; --k, ++shown) {
            NSString *key = entries[k-1];
            [result appendFormat:@"\n%@ × %@", caEntry[key], key];
        }
        [result appendString:@"\nChuỗi gọi hay gặp:"];
    } else if (treo_trace_has_stack)
        [result appendFormat:@"\n%u chuỗi FP giữ lại · %u mẫu đổi trong lúc đọc (chỉ giữ PC/LR)",
            treo_trace_chains, treo_trace_unstable];
    NSArray<NSString *> *keys = [hist keysSortedByValueUsingSelector:@selector(compare:)];
    for (NSUInteger k = keys.count, shown = 0; k && shown < 6; --k, ++shown) {
        NSString *key = keys[k-1];
        [result appendFormat:@"\n%@ × %@", hist[key], key];
    }
    return strdup(result.UTF8String);
}

void treo_afk_threads_begin(void) {
    treo_afk_thread_start = treo_afk_read_threads();
    treo_afk_rusage_valid = getrusage(RUSAGE_SELF, &treo_afk_rusage_start) == 0;
}
static double treo_afk_timeval(struct timeval t) { return t.tv_sec + t.tv_usec / 1e6; }
char *treo_afk_threads_report(double seconds) {
    if (seconds <= 0) return NULL;
    struct rusage end;
    NSMutableString *out = [NSMutableString string];
    if (treo_afk_rusage_valid && getrusage(RUSAGE_SELF, &end) == 0) {
        double u = treo_afk_timeval(end.ru_utime) - treo_afk_timeval(treo_afk_rusage_start.ru_utime);
        double k = treo_afk_timeval(end.ru_stime) - treo_afk_timeval(treo_afk_rusage_start.ru_stime);
        [out appendFormat:@"User %.1f%% · kernel %.1f%%", 100*u/seconds, 100*k/seconds];
    }
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *after = treo_afk_read_threads();
    if (!after || !treo_afk_thread_start) return strdup(out.length ? out.UTF8String : "Không đọc được CPU từng luồng");
    uint64_t mainID = 0;
    pthread_threadid_np(NULL, &mainID);
    uint64_t paintID = atomic_load_explicit(&g_afk_paint_tid, memory_order_relaxed);
    uint64_t gcID = atomic_load_explicit(&g_afk_gc_tid, memory_order_relaxed);
    NSMutableDictionary<NSNumber *, NSNumber *> *delta = [NSMutableDictionary new];
    for (NSNumber *tid in after) {
        NSArray<NSNumber *> *a = treo_afk_thread_start[tid], *b = after[tid];
        if (!a) continue;
        double d = b[0].doubleValue + b[1].doubleValue - a[0].doubleValue - a[1].doubleValue;
        delta[tid] = @(MAX(0.0, 100*d/seconds));
    }
    [out appendString:@"\nLuồng:"];
    const bool jarAudit = atomic_load_explicit(&treo_jar_auditing, memory_order_relaxed);
    const uint64_t gameID = atomic_load_explicit(&treo_jar_game_tid, memory_order_relaxed);
    if (jarAudit) {
        NSNumber *value = gameID ? delta[@(gameID)] : nil;
        [out appendFormat:@" game %@%@", value ? [NSString stringWithFormat:@"%.1f%%", value.doubleValue] : @"–",
            value && gameID == paintID ? @" (cùng luồng paint*)" : @""];
    }
    uint64_t roles[] = {paintID, gcID, mainID};
    NSArray<NSString *> *labels = @[@"paint*", @"GC", @"UI"];
    for (int n = 0; n < 3; ++n) {
        NSNumber *tid = @(roles[n]), *value = delta[tid];
        [out appendFormat:@" %@ %@", labels[n], value ? [NSString stringWithFormat:@"%.1f%%", value.doubleValue] : @"–"];
        [delta removeObjectForKey:tid];
    }
    if (jarAudit && gameID) [delta removeObjectForKey:@(gameID)];
    NSArray<NSNumber *> *others = [delta keysSortedByValueUsingSelector:@selector(compare:)];
    for (NSUInteger n = others.count, shown = 0; n > 0 && shown < 5; --n, ++shown) {
        NSNumber *tid = others[n-1];
        [out appendFormat:@" · #%@ %.1f%%", tid, delta[tid].doubleValue];
    }
    treo_afk_thread_start = nil;
    return strdup(out.UTF8String);
}

double treo_process_cpu_seconds(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1.0;
    return (double)usage.ru_utime.tv_sec + (double)usage.ru_stime.tv_sec +
           ((double)usage.ru_utime.tv_usec + (double)usage.ru_stime.tv_usec) / 1000000.0;
}

void treo_render_profile_start(void) {
    atomic_store_explicit(&treo_prof_paints, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_paint_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_flushes, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_snapshots, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_snapshot_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_replaced, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_submitted, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_region_calls, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_region_culled, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_live_boundary_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_region_samples, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_prof_region_sample_ns, 0, memory_order_relaxed);
    atomic_store_explicit(&treo_profile_enabled, 1, memory_order_release);
}
TreoRenderProfile treo_render_profile_stop(void) {
    atomic_store_explicit(&treo_profile_enabled, 0, memory_order_release);
    return (TreoRenderProfile){
        .paints = atomic_load_explicit(&treo_prof_paints, memory_order_relaxed),
        .paint_ns = atomic_load_explicit(&treo_prof_paint_ns, memory_order_relaxed),
        .flushes = atomic_load_explicit(&treo_prof_flushes, memory_order_relaxed),
        .snapshots = atomic_load_explicit(&treo_prof_snapshots, memory_order_relaxed),
        .snapshot_ns = atomic_load_explicit(&treo_prof_snapshot_ns, memory_order_relaxed),
        .replaced = atomic_load_explicit(&treo_prof_replaced, memory_order_relaxed),
        .submitted = atomic_load_explicit(&treo_prof_submitted, memory_order_relaxed),
        .region_calls = atomic_load_explicit(&treo_prof_region_calls, memory_order_relaxed),
        .region_culled = atomic_load_explicit(&treo_prof_region_culled, memory_order_relaxed),
        .live_boundary_ns = atomic_load_explicit(&treo_prof_live_boundary_ns, memory_order_relaxed),
        .region_samples = atomic_load_explicit(&treo_prof_region_samples, memory_order_relaxed),
        .region_sample_ns = atomic_load_explicit(&treo_prof_region_sample_ns, memory_order_relaxed),
    };
}
void treo_render_profile_replaced(void) {
    if (treo_profile_active()) TREO_PROF_ADD(replaced, 1);
}
void treo_render_profile_submitted(void) {
    atomic_fetch_add_explicit(&treo_layer_frames, 1, memory_order_relaxed);
    if (treo_profile_active()) TREO_PROF_ADD(submitted, 1);
}
static _Atomic uint64_t treo_jar_ticks_on, treo_jar_ticks_off;
void treo_jar_audit_set(int enabled) {
    if (enabled) {
        atomic_store_explicit(&treo_jar_game_tid, 0, memory_order_relaxed);
        atomic_store_explicit(&g_afk_paint_tid, 0, memory_order_relaxed);
    }
    atomic_store_explicit(&treo_jar_auditing, enabled != 0, memory_order_relaxed);
}
int treo_jar_audit_enabled(void) { return atomic_load_explicit(&treo_jar_auditing, memory_order_relaxed); }
// Opt-in causal probe: restore CPU work at the old paint call site without
// touching pixels, allocating objects, scheduling UI, or changing Java state.
// Diagnostic-only pulse modes: 0=idle, 1=game compute, 2=game sleep, 3=worker compute.
static atomic_int treo_jar_load_mode;
static _Atomic uint64_t treo_jar_worker_period_ns = UINT64_C(39400000);
static _Atomic int treo_jar_game_qos = 0, treo_jar_worker_qos = 0;
static pthread_t treo_jar_worker;
static bool treo_jar_worker_started;
static void *treo_jar_worker_main(void *ignored);
void treo_jar_load_worker_period_set(uint64_t ns) {
    if (ns < UINT64_C(20000000)) ns = UINT64_C(20000000);
    if (ns > UINT64_C(100000000)) ns = UINT64_C(100000000);
    atomic_store_explicit(&treo_jar_worker_period_ns, ns, memory_order_relaxed);
}
int treo_jar_load_game_qos(void) { return atomic_load_explicit(&treo_jar_game_qos, memory_order_relaxed); }
int treo_jar_load_worker_qos(void) { return atomic_load_explicit(&treo_jar_worker_qos, memory_order_relaxed); }
static _Atomic uint64_t treo_jar_load_ns, treo_jar_wall_ns, treo_jar_calls;
static _Atomic uint64_t treo_jar_compute_wall, treo_jar_compute_calls, treo_jar_sleep_target;
void treo_jar_load_set(int mode) {
    // Mode changes come from main. Join on exit outside any measured CPU window.
    const int old = atomic_exchange_explicit(&treo_jar_load_mode, mode, memory_order_acq_rel);
    if (old == 3 && mode != 3 && treo_jar_worker_started) {
        pthread_join(treo_jar_worker, NULL);
        treo_jar_worker_started = false;
    }
    if (mode == 1) {
        atomic_store_explicit(&treo_jar_game_qos, 0, memory_order_relaxed);
        atomic_store(&treo_jar_compute_wall, 0);
        atomic_store(&treo_jar_compute_calls, 0);
    } else if (mode == 2) {
        uint64_t count = atomic_load(&treo_jar_compute_calls);
        uint64_t mean = count ? atomic_load(&treo_jar_compute_wall) / count : UINT64_C(10000000);
        atomic_store(&treo_jar_sleep_target, MIN(mean, UINT64_C(12000000)));
    }
    if (mode == 3 && old != 3) {
        atomic_store_explicit(&treo_jar_worker_qos, 0, memory_order_relaxed);
        if (pthread_create(&treo_jar_worker, NULL, treo_jar_worker_main, NULL) == 0)
            treo_jar_worker_started = true;
        else
            atomic_store_explicit(&treo_jar_worker_qos, -1, memory_order_relaxed);
    }
}
uint64_t treo_jar_load_wall_ns(void) { return atomic_load(&treo_jar_wall_ns); }
uint64_t treo_jar_load_calls(void) { return atomic_load(&treo_jar_calls); }
uint64_t treo_jar_load_cpu_ns(void) {
    return atomic_load_explicit(&treo_jar_load_ns, memory_order_relaxed);
}
static void treo_jar_load_pulse(int expectedMode) {
    const uint64_t wallStart = treo_afk_now_ns(), cpuStart = treo_thread_cpu_ns();
    if (!wallStart || !cpuStart) return;
    uint64_t cpu = cpuStart;
    volatile uint64_t value = cpuStart;
    do {
        for (unsigned i = 0; i < 512; ++i)
            value = value * UINT64_C(6364136223846793005) + UINT64_C(1);
        cpu = treo_thread_cpu_ns();
        const uint64_t wall = treo_afk_now_ns();
        if (cpu < cpuStart || wall < wallStart || wall - wallStart >= UINT64_C(12000000)) break;
    } while (cpu - cpuStart < UINT64_C(10000000) &&
             atomic_load_explicit(&treo_jar_load_mode, memory_order_relaxed) == expectedMode);
    if (cpu >= cpuStart) atomic_fetch_add_explicit(&treo_jar_load_ns, cpu - cpuStart, memory_order_relaxed);
}
// Separate pthread: same arithmetic as game pulse, paced to B tick frequency.
// Never accesses Java objects, view hierarchy, or the rendering buffer.
static void *treo_jar_worker_main(void *ignored) {
    (void)ignored;
    const int gameQoS = atomic_load_explicit(&treo_jar_game_qos, memory_order_relaxed);
    if (gameQoS > 0) (void)pthread_set_qos_class_self_np((qos_class_t)gameQoS, 0);
    qos_class_t workerQoS = QOS_CLASS_UNSPECIFIED;
    (void)pthread_get_qos_class_np(pthread_self(), &workerQoS, NULL);
    atomic_store_explicit(&treo_jar_worker_qos, (int)workerQoS, memory_order_relaxed);
    while (atomic_load_explicit(&treo_jar_load_mode, memory_order_acquire) == 3) {
        const uint64_t start = treo_afk_now_ns();
        treo_jar_load_pulse(3);
        const uint64_t done = treo_afk_now_ns();
        if (start && done >= start) {
            atomic_fetch_add_explicit(&treo_jar_wall_ns, done - start, memory_order_relaxed);
            atomic_fetch_add_explicit(&treo_jar_calls, 1, memory_order_relaxed);
        }
        const uint64_t period = atomic_load_explicit(&treo_jar_worker_period_ns, memory_order_relaxed);
        const uint64_t spent = done >= start ? done - start : period;
        if (spent < period && atomic_load_explicit(&treo_jar_load_mode, memory_order_relaxed) == 3) {
            const uint64_t remaining = period - spent;
            const struct timespec delay = {(time_t)(remaining / UINT64_C(1000000000)),
                                           (long)(remaining % UINT64_C(1000000000))};
            nanosleep(&delay, NULL);
        }
    }
    return NULL;
}
void treo_jar_audit_tick(int active) {
    // Sample on the real game Java thread (called from requestFrame hook).
    treo_diag_sample(1);
    const int mode = atomic_load_explicit(&treo_jar_load_mode, memory_order_acquire);
    if (active && mode == 1) {
        qos_class_t gameQoS = QOS_CLASS_UNSPECIFIED;
        (void)pthread_get_qos_class_np(pthread_self(), &gameQoS, NULL);
        atomic_store_explicit(&treo_jar_game_qos, (int)gameQoS, memory_order_relaxed);
    }
    if (active && (mode == 1 || mode == 2)) {
        const uint64_t start = treo_afk_now_ns();
        if (mode == 1) {
            treo_jar_load_pulse(1);
        } else {
            const struct timespec delay = {0, (long)atomic_load(&treo_jar_sleep_target)};
            nanosleep(&delay, NULL); // No spin and no retry; measure actual wall time.
        }
        const uint64_t end = treo_afk_now_ns();
        if (start && end >= start) {
            atomic_fetch_add(&treo_jar_wall_ns, end - start);
            atomic_fetch_add(&treo_jar_calls, 1);
            if (mode == 1) {
                atomic_fetch_add(&treo_jar_compute_wall, end - start);
                atomic_fetch_add(&treo_jar_compute_calls, 1);
            }
        }
    }
    if (!g_afk_thread_id) pthread_threadid_np(NULL, &g_afk_thread_id);
    atomic_store_explicit(&treo_jar_game_tid, g_afk_thread_id, memory_order_relaxed);
    atomic_fetch_add_explicit(active ? &treo_jar_ticks_on : &treo_jar_ticks_off, 1, memory_order_relaxed);
}
uint64_t treo_jar_audit_ticks(int active) {
    return atomic_load_explicit(active ? &treo_jar_ticks_on : &treo_jar_ticks_off, memory_order_relaxed);
}
#if defined(TREO_PAINT_QOS_EXPERIMENT) && TREO_PAINT_QOS_EXPERIMENT
// Only a registered Java pthread may enter. Never change UIKit, a GCD runner,
// GC, or another VM. Scope has no reference to a freed Runtime or session.
typedef struct {
    uint64_t owner, wall_start;
    unsigned depth;
    int changed, utility;
    qos_class_t original;
    int relative;
} TreoPaintQoSScope;
static _Thread_local TreoPaintQoSScope treo_paint_qos;
#define QOS_NOTE(s,f,n) __atomic_fetch_add(&(s)->f,(uint64_t)(n),__ATOMIC_RELAXED)
static int treo_qos_restore(JarBoxTreoState *s) {
    TreoPaintQoSScope *q=&treo_paint_qos;
    if (!q->changed) return 1;
    qos_class_t actual=QOS_CLASS_UNSPECIFIED; int relative=0;
    if (pthread_set_qos_class_self_np(q->original,q->relative) ||
        pthread_get_qos_class_np(pthread_self(),&actual,&relative) ||
        actual!=q->original || relative!=q->relative) {
        QOS_NOTE(s,qos_paint_restore_errors,1);
        __atomic_store_n(&s->qos_paint_backoff,1,__ATOMIC_RELAXED);
        return 0; // retry at next paint boundary; never start another trial
    }
    q->changed=0;
    return 1;
}
static void treo_paint_qos_begin(Runtime *runtime,s64 stamp) {
    JarBoxTreoState *s=treo_runtime_state(runtime);
    if (!s || !runtime->jvm->session ||
        !jvm_bridge_cpu_is_java_worker(runtime->jvm->session) || pthread_main_np()) return;
    TreoPaintQoSScope *q=&treo_paint_qos;
    const uint64_t owner=jarbox_native_heap_key_for_runtime(runtime);
    if (!owner) return;
    if (q->depth) { if (q->owner==owner && stamp<0) ++q->depth; return; }
    if (q->changed) {
        if (q->owner!=owner || !treo_qos_restore(s)) return;
    }
    if (stamp>=0 || treo_runtime_mode(runtime)!=1) return;
    *q=(TreoPaintQoSScope){.owner=owner,.depth=1,.wall_start=treo_afk_now_ns()};
    if (__atomic_load_n(&s->qos_paint_backoff,__ATOMIC_RELAXED)) return;
    QOS_NOTE(s,qos_paint_attempts,1);
    qos_class_t before=QOS_CLASS_UNSPECIFIED; int relative=0;
    if (pthread_get_qos_class_np(pthread_self(),&before,&relative)) {
        QOS_NOTE(s,qos_paint_errors,1);
        __atomic_store_n(&s->qos_paint_backoff,1,__ATOMIC_RELAXED);
        return;
    }
    __atomic_store_n(&s->qos_original_class,(uint64_t)before,__ATOMIC_RELAXED);
    __atomic_store_n(&s->qos_observed_class,(uint64_t)before,__ATOMIC_RELAXED);
    if (before==QOS_CLASS_UTILITY) {
        q->utility=1; QOS_NOTE(s,qos_paint_already_utility,1); return;
    }
    // Do not promote Background, demote interactive, or change UNSPECIFIED:
    // the public API cannot restore an unspecified class exactly.
    if (before!=QOS_CLASS_DEFAULT && before!=QOS_CLASS_USER_INITIATED) {
        QOS_NOTE(s,qos_paint_unrestorable,1);
        return;
    }
    q->original=before; q->relative=relative;
    if (pthread_set_qos_class_self_np(QOS_CLASS_UTILITY,0)) {
        QOS_NOTE(s,qos_paint_errors,1);
        __atomic_store_n(&s->qos_paint_backoff,1,__ATOMIC_RELAXED);
        return;
    }
    q->changed=1;
    qos_class_t actual=QOS_CLASS_UNSPECIFIED; int rel=0;
    int error=pthread_get_qos_class_np(pthread_self(),&actual,&rel);
    __atomic_store_n(&s->qos_observed_class,(uint64_t)actual,__ATOMIC_RELAXED);
    if (error || actual!=QOS_CLASS_UTILITY || rel!=0) {
        QOS_NOTE(s,qos_paint_errors,1);
        __atomic_store_n(&s->qos_paint_backoff,1,__ATOMIC_RELAXED);
        (void)treo_qos_restore(s);
        return;
    }
    q->utility=1; QOS_NOTE(s,qos_paint_applied,1);
}
static void treo_paint_qos_end(Runtime *runtime,uint64_t cpu_ns,int cpu_valid) {
    TreoPaintQoSScope *q=&treo_paint_qos;
    JarBoxTreoState *s=treo_runtime_state(runtime);
    if (!s || !q->depth || q->owner!=jarbox_native_heap_key_for_runtime(runtime)) return;
    if (--q->depth) return;
    uint64_t end=treo_afk_now_ns();
    if (q->wall_start && end>=q->wall_start) {
        uint64_t wall=end-q->wall_start;
        if (q->utility && cpu_valid) {
            QOS_NOTE(s,qos_paint_completed,1);
            QOS_NOTE(s,qos_paint_cpu_ns,cpu_ns);
            QOS_NOTE(s,qos_paint_wall_ns,wall);
            if (jarbox_paint_qos_over_budget(wall)) {
                uint64_t strikes=__atomic_add_fetch(&s->qos_paint_over_budget,1,__ATOMIC_RELAXED);
                if (jarbox_paint_qos_backoff(strikes))
                    __atomic_store_n(&s->qos_paint_backoff,1,__ATOMIC_RELAXED);
            }
        } else {
            QOS_NOTE(s,qos_paint_normal_completed,1);
            QOS_NOTE(s,qos_paint_normal_wall_ns,wall);
        }
    }
    (void)treo_qos_restore(s);
    q->utility=0;
}
#undef QOS_NOTE
#endif

#if defined(TREO_NATIVE_PAINT_DIAG) && TREO_NATIVE_PAINT_DIAG
extern void treo_native_paint_diag_begin(Runtime *r);
extern void treo_native_paint_diag_end(Runtime *r,uint64_t total,int valid);
#endif
static s32 n_profilePaintBegin(Runtime *runtime, JClass *clazz) {
    s64 start = 0;
    if (treo_runtime_mode(runtime) != 0 || treo_jar_audit_enabled()) {
        if (!g_afk_thread_id) pthread_threadid_np(NULL, &g_afk_thread_id);
        atomic_store_explicit(&g_afk_paint_tid, g_afk_thread_id, memory_order_relaxed);
        start = -(s64)treo_thread_cpu_ns();
#if defined(TREO_CANVAS_PHASE_DIAG) && TREO_CANVAS_PHASE_DIAG
        if (treo_canvas_phase.active && start<0)
            jarbox_canvas_phase_point(&treo_canvas_phase,treo_canvas_phase_owner(runtime),1,(uint64_t)(-start));
#endif
        treo_vm_paint_sample_begin();
#if defined(TREO_NATIVE_PAINT_DIAG) && TREO_NATIVE_PAINT_DIAG
        if (start<0) treo_native_paint_diag_begin(runtime);
#endif
    }
    else if (treo_profile_active()) start = (s64)treo_thread_cpu_ns();
#if defined(TREO_PAINT_QOS_EXPERIMENT) && TREO_PAINT_QOS_EXPERIMENT
    treo_paint_qos_begin(runtime,start);
#endif
    runtime->jnienv->push_long(runtime->stack, start);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_profilePaintEnd(Runtime *runtime, JClass *clazz) {
    const s64 stamp = runtime->jnienv->localvar_getLong_2slot(runtime->localvar, 0);
    if (stamp < 0) {
        const int sampled = treo_vm_paint_sample_end();
        const uint64_t end = treo_thread_cpu_ns(), begin = (uint64_t)(-stamp);
#if defined(TREO_CANVAS_PHASE_DIAG) && TREO_CANVAS_PHASE_DIAG
        if (treo_canvas_phase.active)
            jarbox_canvas_phase_point(&treo_canvas_phase,treo_canvas_phase_owner(runtime),2,end);
#endif
#if defined(TREO_NATIVE_PAINT_DIAG) && TREO_NATIVE_PAINT_DIAG
        treo_native_paint_diag_end(runtime,end>=begin ? end-begin : 0,end>=begin);
#endif
#if defined(TREO_PAINT_QOS_EXPERIMENT) && TREO_PAINT_QOS_EXPERIMENT
        treo_paint_qos_end(runtime,end>=begin ? end-begin : 0,end>=begin);
#endif
        if (end >= begin) {
            const uint64_t elapsed = end - begin;
            atomic_fetch_add_explicit(&g_afk_paint_cpu_ns, elapsed, memory_order_relaxed);
            atomic_fetch_add_explicit(&g_afk_paint_count, 1, memory_order_relaxed);
            // Reuse the existing negative-stamp AFK/audit measurement.
            // A paint spanning a mode transition remains in this bucket.
            JarBoxTreoState *state = treo_runtime_state(runtime);
            if (state) {
                __atomic_fetch_add(&state->afk_profile_paint_calls, 1, __ATOMIC_RELAXED);
                __atomic_fetch_add(&state->afk_profile_paint_cpu_ns, elapsed, __ATOMIC_RELAXED);
            }
            treo_vm_paint_sample_note_duration(sampled, elapsed);
        }
        return RUNTIME_STATUS_NORMAL;
    }
    if (!treo_profile_active()) return RUNTIME_STATUS_NORMAL;
    uint64_t begin = (uint64_t)stamp;
    uint64_t end = treo_thread_cpu_ns();
    if (begin && end >= begin) {
        TREO_PROF_ADD(paints, 1);
        TREO_PROF_ADD(paint_ns, end - begin);
    }
    return RUNTIME_STATUS_NORMAL;
}

static CGColorSpaceRef g_colorSpace = NULL;

// A VM can stop while other tabs keep running. New handle acquisitions
// check the exact owning JVM generation under g_track_lock; never use a
// process-wide renderer stop bit to stop an unrelated session.
#define RENDER_STOP_OWNER_SLOTS 64
static uint64_t g_stopped_render_owners[RENDER_STOP_OWNER_SLOTS];
static int g_stopped_render_owner_count;
static int g_render_stop_registry_overflow; // fail closed if impossible cap exceeded
static inline int render_owner_stopped_locked(uint64_t key) {
    if (g_render_stop_registry_overflow) return 1;
    if (!key) return 1;
    for (int i = 0; i < g_stopped_render_owner_count; ++i)
        if (g_stopped_render_owners[i] == key) return 1;
    return 0;
}

// Global tracking arrays for forced cleanup between game sessions.
// Protected by g_track_lock. Entries are added on create, removed on release (refcount→0).
#define TRACK_MAX 8192
static RenderContext *g_live_rc[TRACK_MAX];
static int            g_live_rc_count = 0;
static RenderImage   *g_live_img[TRACK_MAX];
static int            g_live_img_count = 0;
static spinlock_t     g_track_lock = {0, 0, 0};
// Indexed membership avoids dereferencing untrusted Java long handles.
// Collisions are rare at the 8K image cap; all walks are under g_track_lock.
#define RENDER_HANDLE_BUCKETS 8192u
static RenderContext *g_rc_live_buckets[RENDER_HANDLE_BUCKETS];
static RenderImage *g_img_live_buckets[RENDER_HANDLE_BUCKETS];
static inline unsigned render_handle_bucket(s64 handle) {
    uint64_t bits = (uint64_t)(uintptr_t)handle >> 4;
    bits ^= bits >> 17;
    bits *= UINT64_C(0x9e3779b97f4a7c15);
    return (unsigned)(bits >> 51);
}

static int track_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);
    if (g_live_rc_count < TRACK_MAX) {
        g_live_rc[g_live_rc_count++] = rc;
        unsigned bucket = render_handle_bucket((s64)(intptr_t)rc);
        rc->next_live = g_rc_live_buckets[bucket];
        g_rc_live_buckets[bucket] = rc;
        spin_unlock(&g_track_lock);
        return 1;
    }
    spin_unlock(&g_track_lock);
    return 0;
}
static void untrack_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_rc_count; i++) {
        if (g_live_rc[i] == rc) {
            g_live_rc[i] = g_live_rc[--g_live_rc_count];
            break;
        }
    }
    unsigned bucket = render_handle_bucket((s64)(intptr_t)rc);
    RenderContext **cursor = &g_rc_live_buckets[bucket];
    while (*cursor && *cursor != rc) cursor = &(*cursor)->next_live;
    if (*cursor) *cursor = rc->next_live;
    rc->next_live = NULL;
    spin_unlock(&g_track_lock);
}
static int track_img(RenderImage *img) {
    spin_lock(&g_track_lock);
    if (g_live_img_count < TRACK_MAX) {
        g_live_img[g_live_img_count++] = img;
        unsigned bucket = render_handle_bucket((s64)(intptr_t)img);
        img->next_live = g_img_live_buckets[bucket];
        g_img_live_buckets[bucket] = img;
        spin_unlock(&g_track_lock);
        return 1;
    }
    spin_unlock(&g_track_lock);
    return 0;
}
static void untrack_img(RenderImage *img) {
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_img_count; i++) {
        if (g_live_img[i] == img) {
            g_live_img[i] = g_live_img[--g_live_img_count];
            break;
        }
    }
    unsigned bucket = render_handle_bucket((s64)(intptr_t)img);
    RenderImage **cursor = &g_img_live_buckets[bucket];
    while (*cursor && *cursor != img) cursor = &(*cursor)->next_live;
    if (*cursor) *cursor = img->next_live;
    img->next_live = NULL;
    spin_unlock(&g_track_lock);
}

/* A transition never mutates buffers owned by a different JVM. The live
 * context registry lock also serializes new registration and retirement. */
static void treo_render_owner_mode_set(uint64_t owner_key, int mode) {
    if (!owner_key) return;
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_rc_count; ++i) {
        RenderContext *rc = g_live_rc[i];
        if (rc && rc->heap_key == owner_key)
            atomic_store_explicit(&rc->afk_mode, mode, memory_order_release);
    }
    spin_unlock(&g_track_lock);
}

// Each graphics handle carries an owning JVM generation; GC must never
// include native memory used by a different game tab.
static inline void native_heap_add(uint64_t key, s32 bytes) {
    jarbox_native_heap_account(key, (s64)bytes);
}
static inline void native_heap_sub(uint64_t key, s32 bytes) {
    jarbox_native_heap_account(key, -(s64)bytes);
}

// ============================================================
// Dead shell reclamation (two-generation)
// ============================================================
// When refcount reaches 0, CF resources are released immediately but
// the struct shell is kept alive (ABA prevention). Dead shells are
// pushed onto gen0 (atomic, any thread). Each flushToScreen call:
//   1. free(gen1) — shells dead for 1+ frames, safe to free
//   2. gen1 = gen0; gen0 = NULL — promote current to previous
// This bounds the leak to at most 2 frames' worth of shells.

static _Atomic(RenderContext *) g_dead_rc_gen0 = NULL;
static RenderContext            *g_dead_rc_gen1 = NULL;
static _Atomic(RenderImage *)   g_dead_img_gen0 = NULL;
static RenderImage              *g_dead_img_gen1 = NULL;

static void enqueue_dead_rc(RenderContext *rc) {
    RenderContext *old;
    do {
        old = atomic_load_explicit(&g_dead_rc_gen0, memory_order_relaxed);
        rc->next_dead = old;
    } while (!atomic_compare_exchange_weak_explicit(
        &g_dead_rc_gen0, &old, rc,
        memory_order_release, memory_order_relaxed));
}

static void enqueue_dead_img(RenderImage *img) {
    RenderImage *old;
    do {
        old = atomic_load_explicit(&g_dead_img_gen0, memory_order_relaxed);
        img->next_dead = old;
    } while (!atomic_compare_exchange_weak_explicit(
        &g_dead_img_gen0, &old, img,
        memory_order_release, memory_order_relaxed));
}

// Canvas paint locks are per instance. Different VM threads can flush
// concurrently (including during an x12 display transition).
static os_unfair_lock g_dead_drain_lock = OS_UNFAIR_LOCK_INIT;

static void process_dead_shells(void) {
    // Only one drain owns gen1. The producers still enqueue atomically.
    os_unfair_lock_lock(&g_dead_drain_lock);
    RenderContext *rc = g_dead_rc_gen1;
    while (rc) { RenderContext *next = rc->next_dead; free(rc); rc = next; }
    RenderImage *img = g_dead_img_gen1;
    while (img) { RenderImage *next = img->next_dead; free(img); img = next; }
    // Promote gen0 → gen1
    g_dead_rc_gen1 = atomic_exchange_explicit(&g_dead_rc_gen0, NULL, memory_order_acquire);
    g_dead_img_gen1 = atomic_exchange_explicit(&g_dead_img_gen0, NULL, memory_order_acquire);
    os_unfair_lock_unlock(&g_dead_drain_lock);
}

// Called only after the retiring owner's worker and callback leases drain.
// Keep foreign shells in their current grace generation; do not advance
// their reclamation epoch just because a different game stops.
static void process_dead_shells_for_owner(uint64_t owner_key) {
    if (!owner_key) return;
    os_unfair_lock_lock(&g_dead_drain_lock);
    RenderContext *rc = atomic_exchange_explicit(&g_dead_rc_gen0, NULL, memory_order_acquire);
    while (rc) {
        RenderContext *next = rc->next_dead;
        if (rc->heap_key == owner_key) free(rc);
        else enqueue_dead_rc(rc);
        rc = next;
    }
    RenderImage *img = atomic_exchange_explicit(&g_dead_img_gen0, NULL, memory_order_acquire);
    while (img) {
        RenderImage *next = img->next_dead;
        if (img->heap_key == owner_key) free(img);
        else enqueue_dead_img(img);
        img = next;
    }
    RenderContext **r = &g_dead_rc_gen1;
    while (*r) {
        RenderContext *node = *r;
        if (node->heap_key == owner_key) {
            *r = node->next_dead;
            free(node);
        } else r = &node->next_dead;
    }
    RenderImage **i = &g_dead_img_gen1;
    while (*i) {
        RenderImage *node = *i;
        if (node->heap_key == owner_key) {
            *i = node->next_dead;
            free(node);
        } else i = &node->next_dead;
    }
    os_unfair_lock_unlock(&g_dead_drain_lock);
}

// ============================================================
// Reference counting: acquire / release
// ============================================================

static inline RenderContext *rc_acquire_locked(s64 handle, uint64_t owner_key) {
    if (!handle || !owner_key) return NULL;
    // Compare the address as an integer; don't dereference until live
    // membership AND JVM generation are both validated under the same lock.
    RenderContext *result = NULL;
    RenderContext *target = (RenderContext *)(intptr_t)handle;
    for (RenderContext *candidate = g_rc_live_buckets[render_handle_bucket(handle)];
         candidate; candidate = candidate->next_live) {
        if (candidate != target) continue;
        if (candidate->heap_key == owner_key) {
            int32_t prev = atomic_load_explicit(&candidate->refcount, memory_order_relaxed);
            while (prev > 0 && prev < INT32_MAX) {
                if (atomic_compare_exchange_weak_explicit(
                        &candidate->refcount, &prev, prev + 1,
                        memory_order_acquire, memory_order_relaxed)) {
                    result = candidate;
                    break;
                }
            }
        }
        break;
    }
    return result;
}

// Caller must not hold g_track_lock. The locked helper validates membership
// and owner and acquires a positive reference, but does not check STOP.
static inline RenderContext *rc_acquire(s64 handle, uint64_t owner_key) {
    if (!handle || !owner_key) return NULL;
    spin_lock(&g_track_lock);
    RenderContext *result=render_owner_stopped_locked(owner_key) ? NULL :
        rc_acquire_locked(handle,owner_key);
    spin_unlock(&g_track_lock);
    return result;
}

static inline void rc_release(RenderContext *rc) {
    if (!rc) return;
    if (atomic_fetch_sub_explicit(&rc->refcount, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);
        untrack_rc(rc); // remove from live tracking before freeing resources
        treo_live_discard(rc);
        int pixels = rc->ownsPixels ? rc->width * rc->height * 4 : 0;
        CGContextRef ctx = rc->ctx;
        CTFontRef font = __atomic_exchange_n(&rc->font, NULL, __ATOMIC_ACQ_REL);
        rc->ctx = NULL;
        rc->ownsPixels = 0;
        if (ctx) CGContextRelease(ctx);
        free(rc->softwarePixels);
        rc->softwarePixels = NULL;
        if (font) CFRelease(font);
        if (pixels > 0) native_heap_sub(rc->heap_key, pixels);
        enqueue_dead_rc(rc);
    }
}

static inline RenderImage *img_acquire_locked(s64 handle, uint64_t owner_key) {
    if (!handle || !owner_key) return NULL;
    RenderImage *result = NULL;
    RenderImage *target = (RenderImage *)(intptr_t)handle;
    for (RenderImage *candidate = g_img_live_buckets[render_handle_bucket(handle)];
         candidate; candidate = candidate->next_live) {
        if (candidate != target) continue;
        if (candidate->heap_key == owner_key) {
            int32_t prev = atomic_load_explicit(&candidate->refcount, memory_order_relaxed);
            while (prev > 0 && prev < INT32_MAX) {
                if (atomic_compare_exchange_weak_explicit(
                        &candidate->refcount, &prev, prev + 1,
                        memory_order_acquire, memory_order_relaxed)) {
                    result = candidate;
                    break;
                }
            }
        }
        break;
    }
    return result;
}

// Caller must not hold g_track_lock. The locked helper validates membership
// and owner and acquires a positive reference, but does not check STOP.
static inline RenderImage *img_acquire(s64 handle, uint64_t owner_key) {
    if (!handle || !owner_key) return NULL;
    spin_lock(&g_track_lock);
    RenderImage *result=render_owner_stopped_locked(owner_key) ? NULL :
        img_acquire_locked(handle,owner_key);
    spin_unlock(&g_track_lock);
    return result;
}

// In compatible Treo, admit the Canvas and Image together under the
// registry lock. STOP is linearized before or after the entire admission;
// already admitted references may finish as with ordinary native drawing.
// No renderer work, release or queue drain occurs while holding this lock.
static inline RenderContext *region_acquire(s64 ctx,s64 image,uint64_t owner,
        int allow_pair,RenderImage **out,int *paired) {
    *out=NULL;
    *paired=0;
    if (!ctx || !owner) return NULL;
    spin_lock(&g_track_lock);
    RenderContext *rc=NULL;
    if (!render_owner_stopped_locked(owner)) {
        rc=rc_acquire_locked(ctx,owner);
        if (rc && allow_pair &&
            atomic_load_explicit(&rc->afk_mode,memory_order_acquire)==1) {
            *paired=1;
            *out=img_acquire_locked(image,owner);
        }
    }
    spin_unlock(&g_track_lock);
    return rc;
}

// LCDUI icon reads are infrequent, so validate the handle in the live
// registry BEFORE dereferencing it. A stale/foreign pointer must not be
// treated as a RenderImage merely because it has a nonzero address.
static RenderImage *img_acquire_for_owner(s64 handle, uint64_t owner_key) {
    if (!handle || !owner_key) return NULL;
    RenderImage *result = NULL;
    RenderImage *target = (RenderImage *)(intptr_t)handle;
    spin_lock(&g_track_lock);
    if (render_owner_stopped_locked(owner_key)) {
        spin_unlock(&g_track_lock);
        return NULL;
    }
    for (int i = 0; i < g_live_img_count; ++i) {
        RenderImage *candidate = g_live_img[i];
        if (candidate != target) continue;
        if (candidate->heap_key == owner_key) {
            int32_t previous = atomic_load_explicit(&candidate->refcount,
                                                    memory_order_relaxed);
            while (previous > 0) {
                if (atomic_compare_exchange_weak_explicit(
                        &candidate->refcount, &previous, previous + 1,
                        memory_order_acquire, memory_order_relaxed)) {
                    result = candidate;
                    break;
                }
            }
        }
        break;
    }
    spin_unlock(&g_track_lock);
    return result;
}

static inline void img_release(RenderImage *img) {
    if (!img) return;
    if (atomic_fetch_sub_explicit(&img->refcount, 1, memory_order_release) == 1) {
        atomic_thread_fence(memory_order_acquire);
        untrack_img(img); // remove from live tracking before freeing resources
        int pixels = img->width * img->height * 4;
        CGContextRef ctx = img->ctx;
        img->ctx = NULL;
        if (img->immutableSnapshot) CGImageRelease(img->immutableSnapshot);
        if (img->immutablePixels) CFRelease(img->immutablePixels);
        if (ctx) CGContextRelease(ctx);
        if (pixels > 0) native_heap_sub(img->heap_key, pixels);
        enqueue_dead_img(img);
    }
}

// ============================================================

static CGColorSpaceRef getColorSpace(void) {
    // Immutable shared color space, safely initialized by competing VM threads.
    static dispatch_once_t once;
    dispatch_once(&once, ^{ g_colorSpace = CGColorSpaceCreateDeviceRGB(); });
    return g_colorSpace;
}

void j2me_render_set_flush_callback(j2me_flush_callback callback) {
    jarbox_flush_default_legacy(&g_flush_routes, callback);
}
void j2me_render_set_owned_flush_callback(j2me_flush_callback_owned callback) {
    jarbox_flush_default_owned(&g_flush_routes, callback);
}
uint64_t j2me_render_visible_owner_key(void) {
    if (!jarbox_scene_gpu_is_active(&g_scene_gpu_gate)) return 0;
    return atomic_load_explicit(&g_visible_render_owner_key, memory_order_acquire);
}

// ============================================================
// Helper
// ============================================================

static inline void setColorFromARGB(CGContextRef ctx, int argb) {
    CGFloat a = ((argb >> 24) & 0xFF) / 255.0;
    CGFloat r = ((argb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((argb >> 8) & 0xFF) / 255.0;
    CGFloat b = (argb & 0xFF) / 255.0;
    CGContextSetRGBFillColor(ctx, r, g, b, a);
    CGContextSetRGBStrokeColor(ctx, r, g, b, a);
}

// ============================================================
// Context management
// ============================================================

static RenderContext *createRenderContext(MiniJVM *owner, int width, int height) {
    if (width <= 0 || height <= 0 || (uint64_t)width * height > INT32_MAX / 4) return NULL;
    RenderContext *rc = (RenderContext *)calloc(1, sizeof(RenderContext));
    if (!rc) return NULL;
    atomic_init(&rc->refcount, 1);
    atomic_init(&rc->java_owned, 1);
    rc->heap_key = jarbox_native_heap_key_for_vm(owner);
    if (!rc->heap_key) { free(rc); return NULL; }
    atomic_init(&rc->afk_mode, owner && owner->session ?
                jarbox_treo_mode_get(&owner->session->treo_state) : 0);
    rc->width = width;
    rc->height = height;

    CGColorSpaceRef cs = getColorSpace();
    const size_t stride = (size_t)width * 4;
    const CGBitmapInfo format = kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little;
    // CPU/CG share stable storage. Published images must never alias it.
    if (width <= 1024 && height <= 1024) {
        uint32_t *pixels = calloc((size_t)width * height, sizeof(uint32_t));
        if (pixels) {
            rc->ctx = CGBitmapContextCreate(pixels, width, height, 8, stride, cs, format);
            if (rc->ctx) rc->softwarePixels = pixels;
            else free(pixels);
        }
    }
    if (!rc->ctx) rc->ctx = CGBitmapContextCreate(NULL, width, height, 8, stride, cs, format);
    if (!rc->ctx) { free(rc); return NULL; }
    CGContextTranslateCTM(rc->ctx, 0, height);
    CGContextScaleCTM(rc->ctx, 1.0, -1.0);

    CGContextSetLineWidth(rc->ctx, 1.0);
    CGContextSetLineCap(rc->ctx, kCGLineCapSquare);
    CGContextSetLineJoin(rc->ctx, kCGLineJoinMiter);

    rc->fontSize = 14.0;
    rc->fontStyle = 0;
    rc->font = CTFontCreateWithName(CFSTR("Helvetica"), rc->fontSize, NULL);
    rc->ownsPixels = 1;
    rc->liveColor = 0xff000000u;
    rc->regionClipBounds = CGRectMake(0, 0, width, height);

    if (!track_rc(rc)) {
        // Never hand Java an untracked native pointer. No native heap
        // accounting has been charged at this point.
        if (rc->ctx) CGContextRelease(rc->ctx);
        if (rc->font) CFRelease(rc->font);
        free(rc->softwarePixels);
        free(rc);
        return NULL;
    }
    native_heap_add(rc->heap_key, width * height * 4);
    return rc;
}

static void destroyRenderContext(RenderContext *rc) {
    if (!rc) return;
    rc_release(rc);
}

// ============================================================
// Image management
// ============================================================

static RenderImage *createMutableImage(MiniJVM *owner, int width, int height) {
    if (width <= 0 || height <= 0 ||
        (uint64_t)width * (uint64_t)height > INT32_MAX / 4) return NULL;
    const uint64_t owner_key = jarbox_native_heap_key_for_vm(owner);
    if (!owner_key) return NULL;
    RenderImage *img = (RenderImage *)calloc(1, sizeof(RenderImage));
    if (!img) return NULL;
    atomic_init(&img->refcount, 1);
    atomic_init(&img->java_owned, 1);
    img->heap_key = owner_key;
    img->width = width;
    img->height = height;
    img->isMutable = 1;

    CGColorSpaceRef cs = getColorSpace();
    img->ctx = CGBitmapContextCreate(NULL, width, height, 8, width * 4,
                                      cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!img->ctx) { free(img); return NULL; }
    CGContextClearRect(img->ctx, CGRectMake(0, 0, width, height));
    CGContextTranslateCTM(img->ctx, 0, height);
    CGContextScaleCTM(img->ctx, 1.0, -1.0);

    if (!track_img(img)) {
        if (img->ctx) CGContextRelease(img->ctx);
        free(img);
        return NULL;
    }
    native_heap_add(img->heap_key, width * height * 4);
    return img;
}

/* JARBOX_DECODED_CACHE_BEGIN: portable core exercised with retain/release fixtures.
 * Exact encoded contents, immutable snapshot and immutable pixel bytes only.
 * Each VM owns a separate tracked RenderImage; no Java or CGContext shared.
 */
#define JARBOX_DECODED_SLOTS 128u
#define JARBOX_DECODED_BUDGET (6u * 1024u * 1024u)
#define JARBOX_DECODED_MAX_ENCODED (256u * 1024u)
#define JARBOX_DECODED_MAX_PIXELS (512u * 1024u)
typedef struct {
    CFDataRef encoded;
    CFDataRef pixels;
    CGImageRef snapshot;
    uint64_t hash, stamp;
    size_t stride, cost;
    int width, height;
} JarBoxDecodedEntry;
static JarBoxDecodedEntry jarbox_decoded_cache[JARBOX_DECODED_SLOTS];
static pthread_mutex_t jarbox_decoded_lock = PTHREAD_MUTEX_INITIALIZER;
static size_t jarbox_decoded_used;
static uint64_t jarbox_decoded_stamp;
static atomic_uint jarbox_decoded_epoch;

static uint64_t jarbox_decoded_hash(CFDataRef data) {
    uint64_t hash = UINT64_C(14695981039346656037);
    const uint8_t *p = CFDataGetBytePtr(data);
    for (CFIndex i = 0, n = CFDataGetLength(data); i < n; ++i)
        hash = (hash ^ p[i]) * UINT64_C(1099511628211);
    return hash;
}
static JarBoxDecodedEntry *jarbox_decoded_find_locked(CFDataRef data, uint64_t hash) {
    for (unsigned i = 0; i < JARBOX_DECODED_SLOTS; ++i) {
        JarBoxDecodedEntry *entry = &jarbox_decoded_cache[i];
        if (entry->encoded && entry->hash == hash &&
            CFDataGetLength(entry->encoded) == CFDataGetLength(data) &&
            CFEqual(entry->encoded, data)) return entry;
    }
    return NULL;
}
static void jarbox_decoded_attach(RenderImage *img, JarBoxDecodedEntry *entry) {
    img->ctx = NULL;
    img->immutablePixels = (CFDataRef)CFRetain(entry->pixels);
    img->immutableSnapshot = CGImageRetain(entry->snapshot);
    img->width = entry->width;
    img->height = entry->height;
    img->softwareSource = (const uint32_t *)CFDataGetBytePtr(img->immutablePixels);
    img->softwareStride = entry->stride;
    entry->stamp = ++jarbox_decoded_stamp;
}
static void jarbox_decoded_drop_locked(JarBoxDecodedEntry *entry) {
    if (!entry->encoded) return;
    jarbox_decoded_used -= entry->cost;
    CFRelease(entry->encoded);
    CFRelease(entry->pixels);
    CGImageRelease(entry->snapshot);
    memset(entry, 0, sizeof(*entry));
}
static void jarbox_decoded_clear_locked(void) {
    for (unsigned i = 0; i < JARBOX_DECODED_SLOTS; ++i)
        jarbox_decoded_drop_locked(&jarbox_decoded_cache[i]);
}
static JarBoxDecodedEntry *jarbox_decoded_oldest_locked(void) {
    JarBoxDecodedEntry *oldest = NULL;
    for (unsigned i = 0; i < JARBOX_DECODED_SLOTS; ++i) {
        JarBoxDecodedEntry *entry = &jarbox_decoded_cache[i];
        if (entry->encoded && (!oldest || entry->stamp < oldest->stamp))
            oldest = entry;
    }
    return oldest;
}
static int jarbox_decoded_lookup(RenderImage *img, CFDataRef data, uint64_t hash) {
    if (pthread_mutex_trylock(&jarbox_decoded_lock) != 0) return 0;
    JarBoxDecodedEntry *entry = jarbox_decoded_find_locked(data, hash);
    if (entry) jarbox_decoded_attach(img, entry);
    pthread_mutex_unlock(&jarbox_decoded_lock);
    return entry != NULL;
}
static void jarbox_decoded_publish(RenderImage *img, CFDataRef data, uint64_t hash,
                                   unsigned epoch) {
    if (img->isMutable || !img->ctx || !img->immutableSnapshot ||
        !img->softwareSource || img->width <= 0 || img->height <= 0 ||
        img->softwareStride < (size_t)img->width ||
        img->softwareStride > JARBOX_DECODED_MAX_PIXELS / 4u / (size_t)img->height)
        return;
    const size_t encoded = (size_t)CFDataGetLength(data);
    if (!encoded || encoded > JARBOX_DECODED_MAX_ENCODED) return;
    const size_t pixels = img->softwareStride * 4u * (size_t)img->height;
    // Conservatively charge both the CGImage snapshot and the software
    // pixel copy, even if CoreGraphics internally shares storage.
    const size_t cost = encoded + pixels * 2u + sizeof(JarBoxDecodedEntry);
    if (cost > JARBOX_DECODED_BUDGET ||
        epoch != atomic_load_explicit(&jarbox_decoded_epoch, memory_order_acquire)) return;
    CFDataRef pixelCopy = CFDataCreate(NULL, (const UInt8 *)img->softwareSource, (CFIndex)pixels);
    if (!pixelCopy) return;
    // Software raster uses uint32_t/NEON loads. Do not assume that every
    // CFData allocator supplies suitably aligned inline byte storage.
    if ((uintptr_t)CFDataGetBytePtr(pixelCopy) % _Alignof(uint32_t)) {
        CFRelease(pixelCopy);
        return;
    }
    if (pthread_mutex_trylock(&jarbox_decoded_lock) != 0) {
        CFRelease(pixelCopy);
        return;
    }
    if (epoch != atomic_load_explicit(&jarbox_decoded_epoch, memory_order_acquire)) {
        pthread_mutex_unlock(&jarbox_decoded_lock);
        CFRelease(pixelCopy);
        return;
    }
    JarBoxDecodedEntry *entry = jarbox_decoded_find_locked(data, hash);
    if (!entry) {
        while (jarbox_decoded_used > JARBOX_DECODED_BUDGET - cost) {
            JarBoxDecodedEntry *oldest = jarbox_decoded_oldest_locked();
            if (!oldest) break;
            jarbox_decoded_drop_locked(oldest);
        }
        for (unsigned i = 0; i < JARBOX_DECODED_SLOTS; ++i)
            if (!jarbox_decoded_cache[i].encoded) { entry = &jarbox_decoded_cache[i]; break; }
        if (!entry) {
            entry = jarbox_decoded_oldest_locked();
            if (entry) jarbox_decoded_drop_locked(entry);
        }
        if (entry) {
            *entry = (JarBoxDecodedEntry){
                .encoded = (CFDataRef)CFRetain(data), .pixels = (CFDataRef)CFRetain(pixelCopy),
                .snapshot = CGImageRetain(img->immutableSnapshot), .hash = hash,
                .stride = img->softwareStride, .cost = cost, .width = img->width, .height = img->height
            };
            jarbox_decoded_used += cost;
        }
    }
    CGContextRef privateContext = img->ctx;
    CGImageRef privateSnapshot = img->immutableSnapshot;
    if (entry) jarbox_decoded_attach(img, entry);
    pthread_mutex_unlock(&jarbox_decoded_lock);
    if (entry) {
        CGImageRelease(privateSnapshot);
        CGContextRelease(privateContext);
    }
    CFRelease(pixelCopy);
}
/* JARBOX_DECODED_CACHE_END */
static atomic_int jarbox_decoded_trim_queued;
static void jarbox_decoded_trim(void) {
    atomic_fetch_add_explicit(&jarbox_decoded_epoch, 1u, memory_order_acq_rel);
    if (pthread_mutex_trylock(&jarbox_decoded_lock) == 0) {
        jarbox_decoded_clear_locked();
        pthread_mutex_unlock(&jarbox_decoded_lock);
        return;
    }
    if (!atomic_exchange_explicit(&jarbox_decoded_trim_queued, 1, memory_order_acq_rel)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            pthread_mutex_lock(&jarbox_decoded_lock);
            jarbox_decoded_clear_locked();
            atomic_store_explicit(&jarbox_decoded_trim_queued, 0, memory_order_release);
            pthread_mutex_unlock(&jarbox_decoded_lock);
        });
    }
}

static RenderImage *createImageFromData(MiniJVM *owner, const uint8_t *data, int length) {
    const uint64_t owner_key = jarbox_native_heap_key_for_vm(owner);
    if (!owner_key || !data || length <= 0) return NULL;
    const uint64_t started = treo_afk_now_ns();
    RenderImage *img = (RenderImage *)calloc(1, sizeof(RenderImage));
    if (!img) return NULL;
    atomic_init(&img->refcount, 1);
    atomic_init(&img->java_owned, 1);
    atomic_init(&img->softwareVerified, 0);
    atomic_init(&img->softwareRejected, 0);
#if defined(TREO_BINARY_SPRITE_EXPERIMENT) && TREO_BINARY_SPRITE_EXPERIMENT
    atomic_init(&img->binaryKind,JB_BIN_UNKNOWN);
    atomic_init(&img->binaryVerified,0);
#endif
    img->heap_key = owner_key;
    img->isMutable = 0;

    // Stable copied key: the source Java byte[] may be reused or modified.
    CFDataRef cfData = CFDataCreate(NULL, data, length);
    if (!cfData) { free(img); return NULL; }
    const int eligible = (size_t)length <= JARBOX_DECODED_MAX_ENCODED;
    const unsigned epoch = atomic_load_explicit(&jarbox_decoded_epoch, memory_order_acquire);
    const uint64_t hash = eligible ? jarbox_decoded_hash(cfData) : 0;
    int hit = eligible && jarbox_decoded_lookup(img, cfData, hash);

    if (!hit) {
        CGImageSourceRef source = CGImageSourceCreateWithData(cfData, NULL);
        CGImageRef cgImage = NULL;
        if (source) {
            cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
            CFRelease(source);
        }
        if (!cgImage) { CFRelease(cfData); free(img); return NULL; }

        const size_t imageWidth = CGImageGetWidth(cgImage);
        const size_t imageHeight = CGImageGetHeight(cgImage);
        if (!imageWidth || !imageHeight ||
            imageWidth > INT32_MAX || imageHeight > INT32_MAX ||
            (uint64_t)imageWidth * (uint64_t)imageHeight > INT32_MAX / 4) {
            CGImageRelease(cgImage); CFRelease(cfData); free(img); return NULL;
        }
        img->width = (int)imageWidth;
        img->height = (int)imageHeight;
        CGColorSpaceRef cs = getColorSpace();
        img->ctx = CGBitmapContextCreate(NULL, img->width, img->height, 8, img->width * 4,
                                         cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        if (!img->ctx) { CGImageRelease(cgImage); CFRelease(cfData); free(img); return NULL; }
        CGContextClearRect(img->ctx, CGRectMake(0, 0, img->width, img->height));
        CGContextDrawImage(img->ctx, CGRectMake(0, 0, img->width, img->height), cgImage);
        CGImageRelease(cgImage);
        img->immutableSnapshot = CGBitmapContextCreateImage(img->ctx);
        img->softwareSource = CGBitmapContextGetData(img->ctx);
        img->softwareStride = CGBitmapContextGetBytesPerRow(img->ctx) / 4;
        if (eligible) jarbox_decoded_publish(img, cfData, hash, epoch);
    }
    CFRelease(cfData);

    if (!track_img(img)) {
        if (img->immutableSnapshot) CGImageRelease(img->immutableSnapshot);
        if (img->immutablePixels) CFRelease(img->immutablePixels);
        if (img->ctx) CGContextRelease(img->ctx);
        free(img);
        return NULL;
    }
    // Retain conservative per-owner logical pixel accounting. Shared
    // backing can be released by another owner or by cache trim independently.
    native_heap_add(img->heap_key, img->width * img->height * 4);
    if (owner->session) {
        if (hit) __atomic_fetch_add(&owner->session->startup_image_hits, 1, __ATOMIC_RELAXED);
        else {
            __atomic_fetch_add(&owner->session->startup_image_decodes, 1, __ATOMIC_RELAXED);
            uint64_t done = treo_afk_now_ns();
            if (started && done >= started)
                __atomic_fetch_add(&owner->session->startup_image_decode_ns, done - started, __ATOMIC_RELAXED);
        }
    }
    return img;
}

// Caller holds an image reference. Return an owned CGImage in either path.
static CGImageRef copyImageSnapshot(RenderImage *img) {
    if (img->immutableSnapshot) return CGImageRetain(img->immutableSnapshot);
    return CGBitmapContextCreateImage(img->ctx);
}

static void destroyImage(RenderImage *img) {
    if (!img) return;
    img_release(img);
}

// ============================================================
// Native method implementations
// ============================================================

static s32 n_createContext(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s32 w = env->localvar_getInt(runtime->localvar, 0);
    s32 h = env->localvar_getInt(runtime->localvar, 1);
    // Refuse new B-owned objects from a stale A Java thread.
    if (!jarbox_native_heap_key_for_runtime(runtime)) {
        env->push_long(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }
    RenderContext *rc = createRenderContext(runtime->jvm, w, h);
    env->push_long(runtime->stack, (s64)(intptr_t)rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyContext(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc) {
        if (atomic_exchange_explicit(&rc->java_owned, 0, memory_order_acq_rel))
            destroyRenderContext(rc); // Java base reference, once
        rc_release(rc); // temporary safe lookup reference
    }
    return RUNTIME_STATUS_NORMAL;
}

CGImageRef j2me_render_copy_image(int64_t handle) {
    // Retained for ABI compatibility; no VM argument means no owner proof.
    (void)handle;
    return NULL;
}

CGImageRef j2me_render_copy_image_for_vm(int64_t handle, MiniJVM *vm) {
    const uint64_t owner_key = jarbox_native_heap_key_for_vm(vm);
    RenderImage *img = img_acquire_for_owner(handle, owner_key);
    if (!img) return NULL;
    CGImageRef image = copyImageSnapshot(img);
    img_release(img);
    return image;
}

void *j2me_render_acquire_canvas(Runtime *runtime, int64_t handle,
                                 CGContextRef *out_context) {
    if (!out_context) return NULL;
    *out_context = NULL;
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (!rc) return NULL;
    if (!rc->ctx) {
        rc_release(rc);
        return NULL;
    }
    // Pixel reads/writes must see preceding queued 2D drawing, even when
    // the game is parked. Do not start a global Metal replay here.
    treo_live_barrier(rc);
    *out_context = rc->ctx;
    return rc;
}
void j2me_render_release_canvas(void *lease) {
    rc_release((RenderContext *)lease);
}

static CGImageRef treo_canvas_snapshot(RenderContext *rc) {
    if (!rc->softwarePixels) return CGBitmapContextCreateImage(rc->ctx);
    const size_t stride = (size_t)rc->width * 4;
    CFDataRef pixels = CFDataCreate(NULL, (const UInt8 *)rc->softwarePixels,
                                    (CFIndex)(stride * rc->height));
    if (!pixels) return NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
    CFRelease(pixels);
    if (!provider) return NULL;
    CGImageRef snapshot = CGImageCreate(rc->width, rc->height, 8, 32, stride,
        getColorSpace(), kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    return snapshot;
}

static s32 n_flushToScreen(Runtime *runtime, JClass *clazz) {
    process_dead_shells();
    const int afk = treo_runtime_mode(runtime) != 0;
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && rc->cpuCache) treo_cpu_batch_drain(rc);
    if (rc && rc->liveRun) {
        const uint64_t start = treo_profile_active() ? treo_thread_cpu_ns() : 0;
        treo_live_drain(rc, !afk);
        if (start && treo_profile_active()) {
            const uint64_t end = treo_thread_cpu_ns();
            if (end >= start) TREO_PROF_ADD(live_boundary_ns, end - start);
        }
    }
    if (rc) {
        rc->liveBlocked = 0; treo_software_publish(rc);
        // Publish Canvas-local counters at the existing flush boundary.
        JarBoxTreoState *state=treo_runtime_state(runtime);
        if (state) {
            if (rc->compatible_crop_hits) __atomic_fetch_add(&state->compatible_crop_hits,rc->compatible_crop_hits,__ATOMIC_RELAXED);
            if (rc->compatible_crop_misses) __atomic_fetch_add(&state->compatible_crop_misses,rc->compatible_crop_misses,__ATOMIC_RELAXED);
            if (rc->compatible_state_reuses) __atomic_fetch_add(&state->compatible_state_reuses,rc->compatible_state_reuses,__ATOMIC_RELAXED);
            if (rc->compatible_region_culls) __atomic_fetch_add(&state->compatible_region_culls,rc->compatible_region_culls,__ATOMIC_RELAXED);
        }
        if (state && rc->compatible_text_attr_reuses)
            __atomic_fetch_add(&state->compatible_text_attr_reuses,rc->compatible_text_attr_reuses,__ATOMIC_RELAXED);
        rc->compatible_text_attr_reuses=0;
#if defined(TREO_REGION_STAGE_DIAG) && TREO_REGION_STAGE_DIAG
        if (state) {
            if (rc->regionStage.seen) __atomic_fetch_add(&state->region_stage_seen,rc->regionStage.seen,__ATOMIC_RELAXED);
            if (rc->regionStage.samples) __atomic_fetch_add(&state->region_stage_samples,rc->regionStage.samples,__ATOMIC_RELAXED);
            if (rc->regionStage.hit_samples) __atomic_fetch_add(&state->region_stage_hit_samples,rc->regionStage.hit_samples,__ATOMIC_RELAXED);
            if (rc->regionStage.hit_ns) __atomic_fetch_add(&state->region_stage_hit_ns,rc->regionStage.hit_ns,__ATOMIC_RELAXED);
            if (rc->regionStage.miss_ns) __atomic_fetch_add(&state->region_stage_miss_ns,rc->regionStage.miss_ns,__ATOMIC_RELAXED);
            if (rc->regionStage.draw_ns) __atomic_fetch_add(&state->region_stage_draw_ns,rc->regionStage.draw_ns,__ATOMIC_RELAXED);
            if (rc->regionStage.invalid) __atomic_fetch_add(&state->region_stage_invalid,rc->regionStage.invalid,__ATOMIC_RELAXED);
        }
        rc->regionStage=(JarBoxRegionStage){0};
#endif
#if defined(TREO_BINARY_SPRITE_EXPERIMENT) && TREO_BINARY_SPRITE_EXPERIMENT
        if (state) {
            if (rc->binaryFast) __atomic_fetch_add(&state->binary_sprite_fast,rc->binaryFast,__ATOMIC_RELAXED);
            if (rc->binaryChecks) __atomic_fetch_add(&state->binary_sprite_checks,rc->binaryChecks,__ATOMIC_RELAXED);
            if (rc->binaryMismatch) __atomic_fetch_add(&state->binary_sprite_mismatch,rc->binaryMismatch,__ATOMIC_RELAXED);
        }
        rc->binaryFast=rc->binaryChecks=rc->binaryMismatch=0;
#endif
        rc->compatible_crop_hits=rc->compatible_crop_misses=0;
        rc->compatible_state_reuses=rc->compatible_region_culls=0;
    }
    // A native framebuffer is owned by its creating VM. It may never be
    // published when another tab owns the visible screen or when its VM
    // no longer has a live generation key. Avoid a snapshot as well.
    const uint64_t callerKey = jarbox_native_heap_key_for_runtime(runtime);
    const uint64_t visibleKey = atomic_load_explicit(
        &g_visible_render_owner_key, memory_order_acquire);
    if (!rc || !callerKey || callerKey != rc->heap_key ||
        callerKey != visibleKey || afk || !treo_rc_may_submit(rc) ||
        (g_afk_canvas && g_afk_canvas_owner_key == callerKey &&
         g_afk_canvas == handle)) {
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }
    const int profiling = treo_profile_active();
    if (profiling) TREO_PROF_ADD(flushes, 1);
    JarBoxFlushLegacy legacy_flush = NULL;
    JarBoxFlushOwned owned_flush = NULL;
    if (rc && jarbox_flush_route_lookup(&g_flush_routes, callerKey,
                                        &legacy_flush, &owned_flush)) {
        const uint64_t begin = profiling ? treo_thread_cpu_ns() : 0;
        CGImageRef image = treo_canvas_snapshot(rc);
        if (profiling && treo_profile_active()) {
            const uint64_t end = treo_thread_cpu_ns();
            if (begin && end >= begin) TREO_PROF_ADD(snapshot_ns, end - begin);
            if (image) TREO_PROF_ADD(snapshots, 1);
        }
        if (image) {
            // Focus may have changed while creating this CGImage snapshot.
            // UIKit also validates the generation when draining queued frames.
            if (!treo_rc_may_submit(rc) || callerKey != atomic_load_explicit(
                    &g_visible_render_owner_key, memory_order_acquire)) {
                CGImageRelease(image);
            } else if (!jarbox_flush_route_lookup(&g_flush_routes, callerKey,
                                                  &legacy_flush, &owned_flush)) {
                // Unregistered during CGImage snapshot: no callback is sent
                // after the owner has begun native teardown.
                CGImageRelease(image);
            } else if (owned_flush) {
                atomic_fetch_add_explicit(&sw_frames, 1, memory_order_relaxed);
                const uint64_t token = runtime->jvm->session ?
                    __atomic_load_n(&runtime->jvm->session->token, __ATOMIC_ACQUIRE) : 0;
                if (token) owned_flush(image, rc->width, rc->height, rc->heap_key, token);
                else CGImageRelease(image);
            } else if (legacy_flush && jvm_bridge_supported_concurrent_sessions() == 1) {
                // The old no-owner ABI is allowed only with the exclusive
                // single-JVM gate; a future 2-JVM mode requires owned frames.
                atomic_fetch_add_explicit(&sw_frames, 1, memory_order_relaxed);
                legacy_flush(image, rc->width, rc->height);
            } else {
                CGImageRelease(image);
            }
        }
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- Color & State ---

static s32 n_setColor(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 argb = env->localvar_getInt(runtime->localvar, 2);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc) {
        if (rc->ownsPixels && rc->clipSaved && treo_rc_reuse_state(rc) && rc->liveColor == (uint32_t)argb)
            treo_note_state_reuse(rc);
        else setColorFromARGB(rc->ctx, argb);
        rc->liveColor = (uint32_t)argb;
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_setClip(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc) {
        CGRect nextClip = CGRectIntersection(CGRectMake(0, 0, rc->width, rc->height),
                                             CGRectStandardize(CGRectMake(x, y, w, h)));
        if (rc->cpuCache) treo_cpu_batch_drain(rc);
        if (w < 0 || h < 0) treo_live_barrier(rc);
        if (rc->ownsPixels && rc->clipSaved && treo_rc_reuse_state(rc) &&
            w >= 0 && h >= 0 && CGRectEqualToRect(rc->liveRawClip, CGRectMake(x, y, w, h)) &&
            rc->liveColor == rc->liveSavedColor && rc->liveStroke == rc->liveSavedStroke) {
            treo_note_state_reuse(rc);
            rc_release(rc);
            return RUNTIME_STATUS_NORMAL;
        }
        if (rc->clipSaved) {
            CGContextRestoreGState(rc->ctx);
            rc->liveColor = rc->liveSavedColor;
            rc->liveStroke = rc->liveSavedStroke;
        } else {
            rc->liveSavedColor = rc->liveColor;
            rc->liveSavedStroke = rc->liveStroke;
        }
        CGContextSaveGState(rc->ctx);
        rc->clipSaved = 1;
        rc->liveRawClip = CGRectMake(x, y, w, h);
        CGContextClipToRect(rc->ctx, rc->liveRawClip);
        // Canvas CTM is restored after each draw; clip and draw share its user space.
        if (rc->ownsPixels) {
            rc->regionClipBounds = nextClip;
        }
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static void treo_apply_stroke(CGContextRef ctx, int style) {
    const CGFloat dash[] = {2.0, 2.0};
    CGContextSetLineDash(ctx, 0, style == 1 ? dash : NULL, style == 1 ? 2 : 0);
}

// The only persistent canvas state modified after saving its base clip is
// fill/stroke color and dash. Temporarily pop that clip for full-frame writes.
static void treo_unclip_canvas(RenderContext *rc) {
    if (rc->clipSaved) CGContextRestoreGState(rc->ctx);
    CGContextSaveGState(rc->ctx);
}
static void treo_restore_canvas(RenderContext *rc) {
    CGContextRestoreGState(rc->ctx);
    if (rc->clipSaved) {
        CGContextSaveGState(rc->ctx);
        CGContextClipToRect(rc->ctx, rc->liveRawClip);
        setColorFromARGB(rc->ctx, (int)rc->liveColor);
        treo_apply_stroke(rc->ctx, rc->liveStroke);
    }
}

static s32 n_setStrokeStyle(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 style = env->localvar_getInt(runtime->localvar, 2);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc) {
        if (rc->ownsPixels && rc->clipSaved && treo_rc_reuse_state(rc) && rc->liveStroke == style)
            treo_note_state_reuse(rc);
        else treo_apply_stroke(rc->ctx, style);
        rc->liveStroke = style;
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- Drawing ---

static s32 n_drawLine(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x1 = env->localvar_getInt(runtime->localvar, 2);
    s32 y1 = env->localvar_getInt(runtime->localvar, 3);
    s32 x2 = env->localvar_getInt(runtime->localvar, 4);
    s32 y2 = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (rc) {
        TreoShapeDraw draw = ^(CGContextRef target) {
            CGContextBeginPath(target);
            CGContextMoveToPoint(target, x1 + 0.5, y1 + 0.5);
            CGContextAddLineToPoint(target, x2 + 0.5, y2 + 0.5);
            CGContextStrokePath(target);
        };
        CGRect bounds = CGRectInset(CGRectMake(MIN(x1, x2), MIN(y1, y2), fabs((double)x2 - x1), fabs((double)y2 - y1)), -4, -4);
        if (!(treo_live_shape(rc, bounds, draw))) {
            treo_live_barrier(rc);
            draw(rc->ctx);
        }
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// Opaque integer fills can write straight into the Canvas bitmap. Periodic
// reference draws leave CG's pixels in place and permanently disable the fast
// path for this context on mismatch. No assumptions about image/offscreen GCs.
static int treo_fast_opaque_rect(RenderContext *rc, int x, int y, int w, int h) {
    if (!rc->softwarePixels || !treo_rc_fast_canvas(rc) || rc->fastFillRejected ||
        !rc->clipSaved || (rc->liveColor >> 24) != 255 || w <= 0 || h <= 0 ||
        rc->liveRawClip.size.width < 0 || rc->liveRawClip.size.height < 0) return 0;
    CGRect raw = CGRectMake(x, y, w, h);
    CGRect rect = CGRectIntersection(rc->regionClipBounds, raw);
    if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) return 0;
    treo_live_barrier(rc);
    const uint32_t color = rc->liveColor;
    const int left = (int)CGRectGetMinX(rect), right = (int)CGRectGetMaxX(rect);
    const int top = (int)CGRectGetMinY(rect), bottom = (int)CGRectGetMaxY(rect);
    if (left < 0 || top < 0 || right > rc->width || bottom > rc->height) return 0;
    unsigned seq = ++rc->fastFillSequence;
    if (seq <= 8 || (seq & 1023u) == 0) {
        CGContextFillRect(rc->ctx, raw);
        ++rc->fastFillChecks;
        for (int yy = top; yy < bottom; ++yy) {
            const uint32_t *row = rc->softwarePixels + yy * rc->width;
            for (int xx = left; xx < right; ++xx) {
                if (row[xx] != color) {
                    rc->fastFillRejected = true;
                    ++rc->fastFillMismatch;
                    return 1;
                }
            }
        }
    } else {
#if defined(__ARM_NEON)
        const uint32x4_t v = vdupq_n_u32(color);
#endif
        for (int yy = top; yy < bottom; ++yy) {
            uint32_t *row = rc->softwarePixels + yy * rc->width;
            int xx = left;
#if defined(__ARM_NEON)
            for (; xx + 4 <= right; xx += 4) vst1q_u32(row + xx, v);
#endif
            for (; xx < right; ++xx) row[xx] = color;
        }
        ++rc->fastFills;
    }
    return 1;
}

static s32 n_fillRect(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (rc && !treo_fast_opaque_rect(rc, x, y, w, h) && !treo_live_rect(rc, x, y, w, h)) {
        treo_live_barrier(rc);
        CGContextFillRect(rc->ctx, CGRectMake(x, y, w, h));
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRect(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (rc) {
        TreoShapeDraw draw = ^(CGContextRef target) {
            CGContextStrokeRect(target, CGRectMake(x + 0.5, y + 0.5, w, h));
        };
        CGRect bounds = CGRectInset(CGRectStandardize(CGRectMake(x, y, w, h)), -4, -4);
        if (!(treo_live_shape(rc, bounds, draw))) {
            treo_live_barrier(rc);
            draw(rc->ctx);
        }
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillArc(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 startAngle = env->localvar_getInt(runtime->localvar, 6);
    s32 arcAngle = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (rc) {
        TreoShapeDraw draw = ^(CGContextRef target) {
            CGFloat cx = x + w / 2.0, cy = y + h / 2.0;
            CGFloat rx = w / 2.0, ry = h / 2.0;
            CGContextSaveGState(target);
            CGContextTranslateCTM(target, cx, cy);
            CGContextScaleCTM(target, 1.0, ry / rx);
            CGContextBeginPath(target);
            CGContextMoveToPoint(target, 0, 0);
            CGFloat sa = -startAngle * M_PI / 180.0;
            CGFloat ea = -(startAngle + arcAngle) * M_PI / 180.0;
            CGContextAddArc(target, 0, 0, rx, sa, ea, arcAngle > 0 ? 1 : 0);
            CGContextClosePath(target);
            CGContextFillPath(target);
            CGContextRestoreGState(target);
        };
        CGRect bounds = CGRectInset(CGRectStandardize(CGRectMake(x, y, w, h)), -4, -4);
        if (!(w > 0 && h > 0 && treo_live_shape(rc, bounds, draw))) {
            treo_live_barrier(rc);
            draw(rc->ctx);
        }
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawArc(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 startAngle = env->localvar_getInt(runtime->localvar, 6);
    s32 arcAngle = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (rc) {
        TreoShapeDraw draw = ^(CGContextRef target) {
            CGFloat cx = x + w / 2.0, cy = y + h / 2.0;
            CGFloat rx = w / 2.0, ry = h / 2.0;
            CGContextSaveGState(target);
            CGContextTranslateCTM(target, cx, cy);
            CGContextScaleCTM(target, 1.0, ry / rx);
            CGContextBeginPath(target);
            CGFloat sa = -startAngle * M_PI / 180.0;
            CGFloat ea = -(startAngle + arcAngle) * M_PI / 180.0;
            CGContextAddArc(target, 0, 0, rx, sa, ea, arcAngle > 0 ? 1 : 0);
            CGContextStrokePath(target);
            CGContextRestoreGState(target);
        };
        CGRect bounds = CGRectInset(CGRectStandardize(CGRectMake(x, y, w, h)), -4, -4);
        if (!(w > 0 && h > 0 && treo_live_shape(rc, bounds, draw))) {
            treo_live_barrier(rc);
            draw(rc->ctx);
        }
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_fillRoundRect(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 aw = env->localvar_getInt(runtime->localvar, 6);
    s32 ah = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (rc) {
        TreoShapeDraw draw = ^(CGContextRef target) {
            CGFloat radius = fmin(aw, ah) / 2.0;
            CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(x, y, w, h), radius, radius, NULL);
            CGContextAddPath(target, path);
            CGContextFillPath(target);
            CGPathRelease(path);
        };
        CGRect bounds = CGRectInset(CGRectStandardize(CGRectMake(x, y, w, h)), -4, -4);
        if (!(treo_live_shape(rc, bounds, draw))) {
            treo_live_barrier(rc);
            draw(rc->ctx);
        }
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawRoundRect(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 x = env->localvar_getInt(runtime->localvar, 2);
    s32 y = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 aw = env->localvar_getInt(runtime->localvar, 6);
    s32 ah = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (rc) {
        TreoShapeDraw draw = ^(CGContextRef target) {
            CGFloat radius = fmin(aw, ah) / 2.0;
            CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(x + 0.5, y + 0.5, w, h), radius, radius, NULL);
            CGContextAddPath(target, path);
            CGContextStrokePath(target);
            CGPathRelease(path);
        };
        CGRect bounds = CGRectInset(CGRectStandardize(CGRectMake(x, y, w, h)), -4, -4);
        if (!(treo_live_shape(rc, bounds, draw))) {
            treo_live_barrier(rc);
            draw(rc->ctx);
        }
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- Text ---

static s32 n_setFont(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 face = env->localvar_getInt(runtime->localvar, 2);
    s32 style = env->localvar_getInt(runtime->localvar, 3);
    s32 size = env->localvar_getInt(runtime->localvar, 4);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc) {
        // Reuse an identical, successfully created immutable CoreText font
        // in compatible parking too. The Canvas paint lock serializes its
        // graphics state; do not extend the other mode-9 raster shortcuts.
        const int mode = treo_rc_mode(rc);
        if (rc->ownsPixels && (mode == 1 || mode == TreoAFKFastCanvas) &&
            rc->font && rc->fastFontValid &&
            rc->fastFontFace == face && rc->fastFontStyle == style && rc->fastFontSize == size) {
            ++rc->fastState;
            if (mode == 1) {
                JarBoxTreoState *state = treo_runtime_state(runtime);
                if (state) __atomic_fetch_add(&state->compatible_font_reuses, 1, __ATOMIC_RELAXED);
            }
            rc_release(rc);
            return RUNTIME_STATUS_NORMAL;
        }
        CGFloat ptSize;
        switch (size) {
            case 8:  ptSize = 10.0; break;
            case 0:  ptSize = 14.0; break;
            case 16: ptSize = 18.0; break;
            default: ptSize = 14.0; break;
        }

        CFStringRef fontName;
        if (style & 1) {
            if (style & 2) fontName = CFSTR("Helvetica-BoldOblique");
            else fontName = CFSTR("Helvetica-Bold");
        } else if (style & 2) {
            fontName = CFSTR("Helvetica-Oblique");
        } else {
            if (face == 32) fontName = CFSTR("Courier");
            else fontName = CFSTR("Helvetica");
        }

        CTFontRef newFont = CTFontCreateWithName(fontName, ptSize, NULL);
        rc->fastFontValid = newFont != NULL;
        rc->fastFontFace = face;
        rc->fastFontStyle = style;
        rc->fastFontSize = size;
        CTFontRef oldFont = __atomic_exchange_n(&rc->font, newFont, __ATOMIC_ACQ_REL);
        rc->fontSize = ptSize;
        rc->fontStyle = style;
        if (oldFont) CFRelease(oldFont);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawString(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *jstr = env->localvar_getRefer(runtime->localvar, 2);
    s32 x = env->localvar_getInt(runtime->localvar, 3);
    s32 y = env->localvar_getInt(runtime->localvar, 4);
    s32 anchor = env->localvar_getInt(runtime->localvar, 5);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    if (!rc || !jstr) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    Utf8String *ustr = utf8_create();
    env->jstring_2_utf8(jstr, ustr, runtime);
    CFStringRef str = CFStringCreateWithCString(NULL, utf8_cstr(ustr), kCFStringEncodingUTF8);
    utf8_destroy(ustr);
    if (!str) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    // Keep immutable attributes for the exact same font. CTLine is still
    // created and used on the calling thread; never cache a mutable layout.
    const int cacheAttrs=rc->ownsPixels && treo_rc_mode(rc)==1;
    CFDictionaryRef attrs=NULL;
    if (cacheAttrs && rc->textAttrs && rc->textAttrsFont==rc->font && rc->font) {
        attrs=(CFDictionaryRef)CFRetain(rc->textAttrs);
        ++rc->compatible_text_attr_reuses;
    } else if (rc->font) {
        const void *keys[]={kCTFontAttributeName,kCTForegroundColorFromContextAttributeName};
        const void *values[]={rc->font,kCFBooleanTrue};
        attrs=CFDictionaryCreate(NULL,keys,values,2,
            &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        if (attrs && cacheAttrs) {
            if (rc->textAttrs) CFRelease(rc->textAttrs);
            if (rc->textAttrsFont) CFRelease(rc->textAttrsFont);
            rc->textAttrs=(CFDictionaryRef)CFRetain(attrs);
            rc->textAttrsFont=(CTFontRef)CFRetain(rc->font);
        }
    }
    if (!attrs) { CFRelease(str); rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    CFAttributedStringRef attrStr = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = attrStr ? CTLineCreateWithAttributedString(attrStr) : NULL;
    if (!line) {
        if (attrStr) CFRelease(attrStr);
        CFRelease(attrs); CFRelease(str); rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    CGFloat ascent, descent, leading;
    double textWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    CGFloat textHeight = ascent + descent;

    CGFloat dx = x, dy = y;
    if (anchor & 1) dx -= textWidth / 2;
    if (anchor & 8) dx -= textWidth;
    if (anchor & 4) dy -= 0;
    if (anchor & 32) dy -= textHeight;
    if (anchor == 0 || (anchor & 16)) dy += 0;

    if (!treo_live_text(rc, line, dx, dy + ascent)) {
        treo_live_barrier(rc);
        CGContextSaveGState(rc->ctx);
        CGContextTranslateCTM(rc->ctx, dx, dy + ascent);
        CGContextScaleCTM(rc->ctx, 1.0, -1.0);
        CGContextSetTextPosition(rc->ctx, 0, 0);
        CTLineDraw(line, rc->ctx);
        CGContextRestoreGState(rc->ctx);
    }

    CFRelease(line);
    CFRelease(attrStr);
    CFRelease(attrs);
    CFRelease(str);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getStringWidth(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *jstr = env->localvar_getRefer(runtime->localvar, 2);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));

    if (!rc || !jstr) { rc_release(rc); env->push_int(runtime->stack, 0); return RUNTIME_STATUS_NORMAL; }

    Utf8String *ustr = utf8_create();
    env->jstring_2_utf8(jstr, ustr, runtime);
    CFStringRef str = CFStringCreateWithCString(NULL, utf8_cstr(ustr), kCFStringEncodingUTF8);
    utf8_destroy(ustr);
    if (!str) { rc_release(rc); env->push_int(runtime->stack, 0); return RUNTIME_STATUS_NORMAL; }

    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCTFontAttributeName, rc->font);
    CFAttributedStringRef attrStr = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(attrStr);
    double w = CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line); CFRelease(attrStr); CFRelease(attrs); CFRelease(str);
    rc_release(rc);
    env->push_int(runtime->stack, (s32)ceil(w));
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getFontHeight(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (!rc) { env->push_int(runtime->stack, 14); return RUNTIME_STATUS_NORMAL; }
    CGFloat ascent = CTFontGetAscent(rc->font);
    CGFloat descent = CTFontGetDescent(rc->font);
    rc_release(rc);
    env->push_int(runtime->stack, (s32)ceil(ascent + descent));
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getFontAscent(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (!rc) { env->push_int(runtime->stack, 12); return RUNTIME_STATUS_NORMAL; }
    CGFloat ascent = CTFontGetAscent(rc->font);
    rc_release(rc);
    env->push_int(runtime->stack, (s32)ceil(ascent));
    return RUNTIME_STATUS_NORMAL;
}

// --- Image ---

static s32 n_createMutableImage(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s32 w = env->localvar_getInt(runtime->localvar, 0);
    s32 h = env->localvar_getInt(runtime->localvar, 1);
    // Refuse new B-owned objects from a stale A Java thread.
    if (!jarbox_native_heap_key_for_runtime(runtime)) {
        env->push_long(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }
    RenderImage *img = createMutableImage(runtime->jvm, w, h);
    env->push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_createImageFromData(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *arr = env->localvar_getRefer(runtime->localvar, 0);
    s32 offset = env->localvar_getInt(runtime->localvar, 1);
    s32 length = env->localvar_getInt(runtime->localvar, 2);
    if (!arr || arr->mb.type != MEM_TYPE_ARR || arr->mb.arr_type_index != DATATYPE_BYTE ||
        !arr->arr_body || offset < 0 || length <= 0 ||
        offset > arr->arr_length || length > arr->arr_length - offset) {
        env->push_long(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }
    c8 *arrBody = arr->arr_body;
    // Refuse new B-owned objects from a stale A Java thread.
    if (!jarbox_native_heap_key_for_runtime(runtime)) {
        env->push_long(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }
    RenderImage *img = createImageFromData(runtime->jvm, (uint8_t *)arrBody + offset, length);
    env->push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyImage(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (img) {
        if (atomic_exchange_explicit(&img->java_owned, 0, memory_order_acq_rel))
            destroyImage(img); // Java base reference, once
        img_release(img); // temporary safe lookup reference
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageWidth(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    env->push_int(runtime->stack, img ? img->width : 0);
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageHeight(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    env->push_int(runtime->stack, img ? img->height : 0);
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageContext(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (img && img->isMutable && img->ctx) {
        RenderContext *rc = (RenderContext *)calloc(1, sizeof(RenderContext));
        if (!rc) {
            img_release(img);
            env->push_long(runtime->stack, 0);
            return RUNTIME_STATUS_NORMAL;
        }
        atomic_init(&rc->refcount, 1);
        atomic_init(&rc->java_owned, 1);
        rc->ctx = img->ctx;
        CGContextRetain(rc->ctx);
        rc->width = img->width;
        rc->height = img->height;
        rc->fontSize = 14.0;
        rc->font = CTFontCreateWithName(CFSTR("Helvetica"), 14.0, NULL);
        rc->ownsPixels = 0; // pixels owned by the RenderImage, not this wrapper
        rc->heap_key = img->heap_key;
        atomic_init(&rc->afk_mode, treo_runtime_mode(runtime));
        if (!track_rc(rc)) {
            CGContextRelease(rc->ctx);
            if (rc->font) CFRelease(rc->font);
            free(rc);
            img_release(img);
            env->push_long(runtime->stack, 0);
            return RUNTIME_STATUS_NORMAL;
        }
        img_release(img);
        env->push_long(runtime->stack, (s64)(intptr_t)rc);
    } else {
        img_release(img);
        env->push_long(runtime->stack, 0);
    }
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawImage(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 ctxHandle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s64 imgHandle = env->localvar_getLong_2slot(runtime->localvar, 2);
    s32 x = env->localvar_getInt(runtime->localvar, 4);
    s32 y = env->localvar_getInt(runtime->localvar, 5);
    s32 anchor = env->localvar_getInt(runtime->localvar, 6);

    RenderContext *rc = rc_acquire(ctxHandle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    RenderImage *img = img_acquire(imgHandle, jarbox_native_heap_key_for_runtime(runtime));
    if (!rc || !img) { img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    int imgW = img->width, imgH = img->height;
    if (anchor & 1) x -= imgW / 2;
    if (anchor & 8) x -= imgW;
    if (anchor & 2) y -= imgH / 2;
    if (anchor & 32) y -= imgH;

    if (rc->cpuCache) treo_cpu_batch_drain(rc);
    if (rc->softwarePixels && treo_rc_fast_canvas(rc) &&
        !atomic_load_explicit(&treo_replay_state, memory_order_relaxed)) {
        treo_live_barrier(rc);
        ++rc->swRegions;
        if (treo_sw_draw(rc, img, x, y, 0, 0, imgW, imgH, 0, 1)) {
            img_release(img);
            rc_release(rc);
            return RUNTIME_STATUS_NORMAL;
        }
    }
    if (treo_live_enqueue(rc, img, x, y, 0, 0, imgW, imgH, 0)) {
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }
    treo_live_barrier(rc);
    CGImageRef cgImage = copyImageSnapshot(img);
    if (cgImage) {
        CGContextSaveGState(rc->ctx);
        CGContextTranslateCTM(rc->ctx, x, y + imgH);
        CGContextScaleCTM(rc->ctx, 1.0, -1.0);
        CGContextDrawImage(rc->ctx, CGRectMake(0, 0, imgW, imgH), cgImage);
        CGContextRestoreGState(rc->ctx);
        CGImageRelease(cgImage);
    }
    img_release(img);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- drawRegion ---

#define TRANS_NONE           0
#define TRANS_ROT90          5
#define TRANS_ROT180         3
#define TRANS_ROT270         6
#define TRANS_MIRROR         2
#define TRANS_MIRROR_ROT90   7
#define TRANS_MIRROR_ROT180  1
#define TRANS_MIRROR_ROT270  4

// A bounding-box rejection only. Keep a one-pixel guard at clip edges and
// leave all overlapping sprites on the original Core Graphics path.
static int treo_region_outside_clip(CGRect clip, int64_t x, int64_t y, int w, int h) {
    if (CGRectIsNull(clip) || CGRectIsEmpty(clip)) return 1;
    return x + w <= CGRectGetMinX(clip) - 1 ||
           y + h <= CGRectGetMinY(clip) - 1 ||
           x >= CGRectGetMaxX(clip) + 1 ||
           y >= CGRectGetMaxY(clip) + 1;
}

static void treo_draw_region_cg(CGContextRef rctx, CGImageRef subImage,
                                int64_t xDst, int64_t yDst, int wSrc, int hSrc, int transform) {
    CGContextSaveGState(rctx);
    CGContextTranslateCTM(rctx, xDst, yDst);

    /* CTM transforms for J2ME drawRegion on a bottom-up CGContext.
     *
     * CGContextDrawImage maps source pixel (sx, sy) to draw-rect position
     * (sx, hSrc - sy) because CG draws top of image at higher Y.
     * We need the final CG position to match the J2ME output position.
     *
     * For each J2ME transform T, source pixel (sx, sy) should appear at
     * J2ME output position T(sx, sy) offset by (xDst, yDst).
     * The CTM must satisfy: CTM * (sx, hSrc-sy) = desired CG position.
     *
     * All operations below are relative to the initial translate(xDst, yDst). */
    switch (transform) {
        case TRANS_NONE:
            CGContextTranslateCTM(rctx, 0, hSrc);
            CGContextScaleCTM(rctx, 1, -1);
            break;
        case TRANS_MIRROR_ROT180: /* = vertical flip, cancels CG's Y-flip */
            break;
        case TRANS_MIRROR:
            CGContextTranslateCTM(rctx, wSrc, hSrc);
            CGContextScaleCTM(rctx, -1, -1);
            break;
        case TRANS_ROT180:
            CGContextTranslateCTM(rctx, wSrc, 0);
            CGContextScaleCTM(rctx, -1, 1);
            break;
        case TRANS_ROT90:
            CGContextRotateCTM(rctx, M_PI_2);
            CGContextScaleCTM(rctx, 1, -1);
            break;
        case TRANS_ROT270:
            CGContextTranslateCTM(rctx, hSrc, wSrc);
            CGContextRotateCTM(rctx, -M_PI_2);
            CGContextScaleCTM(rctx, 1, -1);
            break;
        case TRANS_MIRROR_ROT90:
            CGContextTranslateCTM(rctx, 0, wSrc);
            CGContextRotateCTM(rctx, -M_PI_2);
            break;
        case TRANS_MIRROR_ROT270:
            CGContextTranslateCTM(rctx, hSrc, 0);
            CGContextRotateCTM(rctx, M_PI_2);
            break;
    }

    CGContextDrawImage(rctx, CGRectMake(0, 0, wSrc, hSrc), subImage);
    CGContextRestoreGState(rctx);
}

// Bounded, opt-in replay of an ordered drawRegion workload. All live draws
// still use Core Graphics; other LCDUI commands are not part of this replay.
enum { TreoReplayCount = 768, TreoReplayRepeats = 16 };
typedef struct {
    CGImageRef image;
    CGRect clip;
    int64_t x, y;
    int sx, sy, w, h, transform;
    uint32_t color;
    int kind, cacheable;
    CTLineRef line;
    CGFloat textX, textY;
    void *shape;
    int stroke;
} TreoSprite;
typedef struct { float x, y, u, v, l, t, r, b; } TreoVertex;
static os_unfair_lock treo_replay_lock = OS_UNFAIR_LOCK_INIT;
static TreoSprite treo_replay_sprites[TreoReplayCount];
static unsigned treo_replay_count, treo_replay_width, treo_replay_height;
static uintptr_t treo_replay_context;
static size_t treo_replay_bytes;
static uint64_t treo_replay_generation;
static char treo_replay_report[1024];

static CGContextRef treo_replay_bitmap(size_t w, size_t h) {
    return CGBitmapContextCreate(NULL, w, h, 8, w * 4, getColorSpace(),
                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
}

static void treo_replay_vertex(TreoVertex *v, const TreoSprite *s, int right, int bottom,
                               size_t tw, size_t th, size_t w, size_t h) {
    int sx = right ? s->w : 0, sy = bottom ? s->h : 0;
    int x = sx, y = sy;
    switch (s->transform) {
        case 1: y = s->h - sy; break;
        case 2: x = s->w - sx; break;
        case 3: x = s->w - sx; y = s->h - sy; break;
        case 4: x = sy; y = sx; break;
        case 5: x = s->h - sy; y = sx; break;
        case 6: x = sy; y = s->w - sx; break;
        case 7: x = s->h - sy; y = s->w - sx; break;
    }
    *v = (TreoVertex){
        2.0f * (float)(s->x + x) / w - 1.0f, 1.0f - 2.0f * (float)(s->y + y) / h,
        (float)(s->sx + sx) / tw, (float)(s->sy + sy) / th,
        (float)CGRectGetMinX(s->clip), (float)CGRectGetMinY(s->clip),
        (float)CGRectGetMaxX(s->clip), (float)CGRectGetMaxY(s->clip)
    };
}

static id<MTLRenderPipelineState> treo_sprite_pipeline(id<MTLDevice> device, NSError **error) {
    NSString *shader = @
        "#include <metal_stdlib>\n"
        "using namespace metal;\n"
        "struct V { float4 xyuv; float4 clip; };\n"
        "struct O { float4 p [[position]]; float2 uv; float4 clip [[flat]]; };\n"
        "vertex O treo_v(const device V *v [[buffer(0)]], uint i [[vertex_id]]) {\n"
        "  O o; o.p=float4(v[i].xyuv.xy,0,1); o.uv=v[i].xyuv.zw; o.clip=v[i].clip; return o;\n"
        "}\n"
        "fragment float4 treo_f(O i [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
        "  if (any(i.p.xy<i.clip.xy) || any(i.p.xy>=i.clip.zw)) discard_fragment();\n"
        "  constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::nearest);\n"
        "  return tex.sample(smp,i.uv);\n"
        "}\n";
    id<MTLLibrary> library = [device newLibraryWithSource:shader options:nil error:error];
    if (!library) return nil;
    MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new];
    p.vertexFunction = [library newFunctionWithName:@"treo_v"];
    p.fragmentFunction = [library newFunctionWithName:@"treo_f"];
    p.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    p.colorAttachments[0].blendingEnabled = YES;
    p.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    p.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    p.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    p.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    return [device newRenderPipelineStateWithDescriptor:p error:error];
}

static NSString *treo_run_metal_replay(void) {
    if (!jarbox_scene_gpu_is_active(&g_scene_gpu_gate)) return @"Dừng replay: app không hiển thị.";
    const size_t w = treo_replay_width, h = treo_replay_height;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) return @"Không tạo được Metal command queue.";
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = treo_sprite_pipeline(device, &error);
    if (!pipeline) return [NSString stringWithFormat:@"Pipeline Metal lỗi: %@", error.localizedDescription];

    NSMutableDictionary<NSValue *, id<MTLTexture>> *textures = [NSMutableDictionary new];
    NSMutableArray<id<MTLTexture>> *sources = [NSMutableArray arrayWithCapacity:TreoReplayCount];
    for (unsigned i = 0; i < TreoReplayCount; i++) {
        CGImageRef image = treo_replay_sprites[i].image;
        NSValue *key = [NSValue valueWithPointer:image];
        id<MTLTexture> tex = textures[key];
        if (!tex) {
            size_t tw = CGImageGetWidth(image), th = CGImageGetHeight(image);
            MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                MTLPixelFormatBGRA8Unorm width:tw height:th mipmapped:NO];
            td.storageMode = MTLStorageModeShared;
            td.usage = MTLTextureUsageShaderRead;
            tex = [device newTextureWithDescriptor:td];
            CGContextRef bitmap = treo_replay_bitmap(tw, th);
            if (!tex || !bitmap) {
                if (bitmap) CGContextRelease(bitmap);
                return @"Không cấp phát được texture nguồn.";
            }
            CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
            CGContextDrawImage(bitmap, CGRectMake(0, 0, tw, th), image);
            [tex replaceRegion:MTLRegionMake2D(0, 0, tw, th) mipmapLevel:0
                     withBytes:CGBitmapContextGetData(bitmap) bytesPerRow:tw * 4];
            CGContextRelease(bitmap);
            textures[key] = tex;
        }
        [sources addObject:tex];
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> target = [device newTextureWithDescriptor:td];
    id<MTLBuffer> vertices = [device newBufferWithLength:TreoReplayCount * 6 * sizeof(TreoVertex)
                                                 options:MTLResourceStorageModeShared];
    if (!target || !vertices) return @"Không cấp phát được đích hoặc bộ đệm Metal.";
    CGContextRef cg = treo_replay_bitmap(w, h);
    if (!cg) return @"Không cấp phát được đích Core Graphics.";
    CGContextTranslateCTM(cg, 0, h);
    CGContextScaleCTM(cg, 1, -1);

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    uint64_t cgNS = 0, metalNS = 0;
    double gpuMS = 0;
    unsigned gpuSamples = 0, batches = 0;
    for (unsigned run = 0; run <= TreoReplayRepeats; run++) {
        @autoreleasepool {
            if (!jarbox_scene_gpu_is_active(&g_scene_gpu_gate)) {
                CGContextRelease(cg);
                return @"Dừng replay: app không hiển thị.";
            }
            uint64_t start = treo_thread_cpu_ns();
            CGContextClearRect(cg, CGRectMake(0, 0, w, h));
            CGRect clip = CGRectMake(0, 0, w, h);
            CGContextSaveGState(cg);
            for (unsigned i = 0; i < TreoReplayCount; i++) {
                const TreoSprite *s = &treo_replay_sprites[i];
                if (!CGRectEqualToRect(s->clip, clip)) {
                    CGContextRestoreGState(cg);
                    CGContextSaveGState(cg);
                    clip = s->clip;
                    CGContextClipToRect(cg, clip);
                }
                CGImageRef crop = CGImageCreateWithImageInRect(s->image, CGRectMake(s->sx, s->sy, s->w, s->h));
                if (!crop) { CGContextRelease(cg); return @"Core Graphics không tạo được ảnh con."; }
                treo_draw_region_cg(cg, crop, s->x, s->y, s->w, s->h, s->transform);
                CGImageRelease(crop);
            }
            CGContextRestoreGState(cg);
            CGContextFlush(cg);
            uint64_t end = treo_thread_cpu_ns();
            if (run && start && end >= start) cgNS += end - start;

            start = treo_thread_cpu_ns();
            id<MTLCommandBuffer> command = [queue commandBuffer];
            id<MTLRenderCommandEncoder> enc = [command renderCommandEncoderWithDescriptor:pass];
            if (!enc) { CGContextRelease(cg); return @"Không tạo được Metal render encoder."; }
            [enc setRenderPipelineState:pipeline];
            [enc setVertexBuffer:vertices offset:0 atIndex:0];
            TreoVertex *v = (TreoVertex *)vertices.contents;
            const unsigned corners[6] = {0, 1, 2, 2, 1, 3};
            batches = 0;
            for (unsigned i = 0; i < TreoReplayCount;) {
                unsigned first = i;
                id<MTLTexture> tex = sources[i];
                do {
                    const TreoSprite *s = &treo_replay_sprites[i];
                    for (unsigned k = 0; k < 6; k++)
                        treo_replay_vertex(&v[i * 6 + k], s, corners[k] & 1, corners[k] >> 1,
                                           tex.width, tex.height, w, h);
                    i++;
                } while (i < TreoReplayCount && sources[i] == tex);
                [enc setFragmentTexture:tex atIndex:0];
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:first * 6 vertexCount:(i - first) * 6];
                batches++;
            }
            [enc endEncoding];
            if (!jarbox_scene_gpu_try_begin(&g_scene_gpu_gate)) {
                CGContextRelease(cg);
                return @"Dừng replay: Metal đang bận hoặc app không hiển thị.";
            }
            [command commit];
            end = treo_thread_cpu_ns();
            if (run && start && end >= start) metalNS += end - start;
            // Drain this submitted command before allowing scene deactivation.
            [command waitUntilCompleted];
            jarbox_scene_gpu_end(&g_scene_gpu_gate);
            if (command.status != MTLCommandBufferStatusCompleted) {
                CGContextRelease(cg);
                return [NSString stringWithFormat:@"GPU lỗi: %@", command.error.localizedDescription];
            }
            if (run && command.GPUStartTime > 0 && command.GPUEndTime >= command.GPUStartTime) {
                gpuMS += (command.GPUEndTime - command.GPUStartTime) * 1000.0;
                gpuSamples++;
            }
        }
    }

    NSMutableData *metalPixels = [NSMutableData dataWithLength:w * h * 4];
    [target getBytes:metalPixels.mutableBytes bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    const uint8_t *a = CGBitmapContextGetData(cg), *b = metalPixels.bytes;
    size_t different = 0, overOne = 0, visible = 0;
    unsigned maxDelta = 0;
    for (size_t i = 0; i < w * h; i++) {
        unsigned peak = 0;
        if (a[i * 4 + 3]) visible++;
        for (unsigned k = 0; k < 4; k++) {
            unsigned d = (unsigned)abs((int)a[i * 4 + k] - (int)b[i * 4 + k]);
            if (d > peak) peak = d;
        }
        different += peak > 0;
        overOne += peak > 1;
        if (peak > maxDelta) maxDelta = peak;
    }
    CGContextRelease(cg);
    NSString *gpu = gpuSamples ? [NSString stringWithFormat:@"%.3f ms", gpuMS / gpuSamples] : @"không có";
    return [NSString stringWithFormat:
        @"%u lệnh · %lu texture · %u lô\nCore Graphics: %.3f ms CPU/lượt\n"
         "Metal dựng lệnh + submit: %.3f ms CPU/lượt\nGPU: %@/lượt\n"
         "Pixel có nội dung (CG): %zu/%zu\nPixel lệch: %zu · lệch >1: %zu · max: %u\n"
         "Replay ngoài màn hình, không tính nạp texture/đọc lại pixel.",
        TreoReplayCount, (unsigned long)textures.count, batches,
        cgNS / (1e6 * TreoReplayRepeats), metalNS / (1e6 * TreoReplayRepeats),
        gpu, visible, w * h, different, overOne, maxDelta];
}

static void treo_replay_complete(NSString *report) {
    for (unsigned i = 0; i < treo_replay_count; i++) {
        CGImageRelease(treo_replay_sprites[i].image);
        treo_replay_sprites[i].image = NULL;
    }
    snprintf(treo_replay_report, sizeof(treo_replay_report), "%s", report.UTF8String);
    treo_replay_count = 0;
    atomic_store_explicit(&treo_replay_state, 0, memory_order_release);
}

int treo_metal_replay_start(void) {
    if (!jarbox_scene_gpu_is_active(&g_scene_gpu_gate)) return 0;
    os_unfair_lock_lock(&treo_replay_lock);
    if (atomic_load_explicit(&treo_replay_state, memory_order_relaxed)) {
        os_unfair_lock_unlock(&treo_replay_lock);
        return 0;
    }
    treo_replay_context = 0;
    treo_replay_bytes = 0;
    const uint64_t generation = ++treo_replay_generation;
    treo_replay_report[0] = '\0';
    atomic_store_explicit(&treo_replay_state, 1, memory_order_release);
    os_unfair_lock_unlock(&treo_replay_lock);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        os_unfair_lock_lock(&treo_replay_lock);
        if (generation == treo_replay_generation &&
            atomic_load_explicit(&treo_replay_state, memory_order_relaxed) == 1) {
            treo_replay_complete(@"Không thu đủ lệnh. Thử khi đang ở map và game đang hiện.");
        }
        os_unfair_lock_unlock(&treo_replay_lock);
    });
    return 1;
}

char *treo_metal_replay_copy_report(void) {
    os_unfair_lock_lock(&treo_replay_lock);
    int state = atomic_load_explicit(&treo_replay_state, memory_order_relaxed);
    const char *message = state == 1 ? "Đang thu lệnh vẽ." :
                          state == 2 ? "Đang chạy replay Metal và Core Graphics." :
                          treo_replay_report[0] ? treo_replay_report : "Chưa đo Metal.";
    char *copy = strdup(message);
    os_unfair_lock_unlock(&treo_replay_lock);
    return copy;
}

static void treo_replay_capture(RenderContext *rc, CGImageRef image, int64_t x, int64_t y,
                                int sx, int sy, int w, int h, int transform) {
    if (atomic_load_explicit(&treo_replay_state, memory_order_relaxed) != 1 ||
        !rc->ownsPixels || treo_rc_afk(rc) || !jarbox_scene_gpu_is_active(&g_scene_gpu_gate)) return;
    size_t tw = CGImageGetWidth(image), th = CGImageGetHeight(image);
    if (rc->width <= 0 || rc->height <= 0 || rc->width > 2048 || rc->height > 2048 ||
        tw > 4096 || th > 4096 || sx < 0 || sy < 0 || w <= 0 || h <= 0 ||
        (size_t)sx + (size_t)w > tw || (size_t)sy + (size_t)h > th ||
        transform < 0 || transform > 7) return;
    os_unfair_lock_lock(&treo_replay_lock);
    if (atomic_load_explicit(&treo_replay_state, memory_order_relaxed) != 1) {
        os_unfair_lock_unlock(&treo_replay_lock);
        return;
    }
    if (!treo_replay_context) {
        treo_replay_context = (uintptr_t)rc;
        treo_replay_width = (unsigned)rc->width;
        treo_replay_height = (unsigned)rc->height;
    }
    if (treo_replay_context != (uintptr_t)rc || treo_replay_width != (unsigned)rc->width ||
        treo_replay_height != (unsigned)rc->height) {
        os_unfair_lock_unlock(&treo_replay_lock);
        return;
    }
    unsigned seen = 0;
    for (unsigned i = treo_replay_count; i > 0; i--) {
        if (treo_replay_sprites[i - 1].image == image) { seen = 1; break; }
    }
    size_t extra = seen ? 0 : tw * th * 4;
    if (treo_replay_bytes + extra > 32u * 1024u * 1024u) {
        treo_replay_complete(@"Dừng capture: ảnh nguồn vượt giới hạn 32 MiB.");
        os_unfair_lock_unlock(&treo_replay_lock);
        return;
    }
    treo_replay_bytes += extra;
    CGRect clip = rc->regionClipBounds;
    if (CGRectIsNull(clip)) clip = CGRectZero;
    treo_replay_sprites[treo_replay_count++] = (TreoSprite){
        CGImageRetain(image), clip, x, y, sx, sy, w, h, transform
    };
    if (treo_replay_count == TreoReplayCount) {
        atomic_store_explicit(&treo_replay_state, 2, memory_order_release);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                NSString *report = treo_run_metal_replay();
                os_unfair_lock_lock(&treo_replay_lock);
                treo_replay_complete(report);
                os_unfair_lock_unlock(&treo_replay_lock);
            }
        });
    }
    os_unfair_lock_unlock(&treo_replay_lock);
}

// Record the ordered canvas stream until flush, not just the last sprite run.
// A non-recordable draw commits the recorded prefix to CG and pins the
// remainder of that frame to CG. GPU submission occurs only at flush.
enum { TreoLiveCapacity = 4096, TreoImage = 0, TreoRect = 1, TreoText = 2, TreoShape = 3 };
struct TreoLiveRun { unsigned count; size_t transientBytes; TreoSprite sprites[TreoLiveCapacity]; };
static atomic_bool treo_live_enabled;
static _Atomic uint64_t treo_live_frames, treo_live_sprites, treo_live_fallback;
int treo_metal_live_enabled(void) { return atomic_load(&treo_live_enabled); }
void treo_metal_live_set_enabled(int enabled) { atomic_store(&treo_live_enabled, enabled != 0); }
uint64_t treo_metal_live_frames(void) { return atomic_load(&treo_live_frames); }
uint64_t treo_metal_live_sprites(void) { return atomic_load(&treo_live_sprites); }
uint64_t treo_metal_live_fallback_sprites(void) { return atomic_load(&treo_live_fallback); }

static void treo_live_clear(TreoLiveRun *run) {
    for (unsigned i = 0; i < run->count; i++) {
        if (run->sprites[i].image) CGImageRelease(run->sprites[i].image);
        if (run->sprites[i].line) CFRelease(run->sprites[i].line);
        if (run->sprites[i].shape) { id released = (__bridge_transfer id)run->sprites[i].shape; (void)released; }
    }
    run->count = 0;
    run->transientBytes = 0;
}

static void treo_live_discard(RenderContext *rc) {
    if (rc->textAttrs) { CFRelease(rc->textAttrs); rc->textAttrs=NULL; }
    if (rc->textAttrsFont) { CFRelease(rc->textAttrsFont); rc->textAttrsFont=NULL; }
    if (rc->cropCache) {
        native_heap_sub(rc->heap_key,(s32)(sizeof(*rc->cropCache)+rc->cropCache->bytes));
        jarbox_crop_clear(rc->cropCache);
        free(rc->cropCache);
        rc->cropCache=NULL;
    }
    treo_cpu_batch_free(rc);
    if (!rc->liveRun) return;
    treo_live_clear(rc->liveRun);
    free(rc->liveRun);
    rc->liveRun = NULL;
}

// Serialized GPU workspace. Cache keys retain immutable CGImage identities
// so released source images cannot alias a previously cached texture.
static os_unfair_lock treo_live_gpu_lock = OS_UNFAIR_LOCK_INIT;
static id<MTLDevice> treo_live_device;
static id<MTLCommandQueue> treo_live_queue;
static id<MTLRenderPipelineState> treo_live_pipeline;
static id<MTLBuffer> treo_live_vertices;
/* The GPU queue, pipeline and vertex buffer are serialized by
 * treo_live_gpu_lock; mutable textures/targets belong to a heap generation.
 * A parked A's CG textures must never be found by B, even if a pointer recurs. */
static NSMutableDictionary *treo_live_owner_targets;       // NSNumber(key) -> MTLTexture
static NSMutableDictionary *treo_live_owner_textures;      // NSNumber(key) -> image cache
static NSMutableDictionary *treo_live_owner_texture_bytes; // NSNumber(key) -> NSNumber(bytes)
// Regenerable image textures are bounded both per owner and across the
// process. Nominal pixel bytes, not the full Metal allocation footprint.
#define TREO_TEXTURE_OWNER_BUDGET (16u * 1024u * 1024u)
#define TREO_TEXTURE_TOTAL_BUDGET (32u * 1024u * 1024u)
static _Atomic int treo_texture_trim_queued;

static int treo_texture_cache_fits(size_t used, size_t bytes, size_t limit) {
    return bytes <= limit && used <= limit - bytes;
}

// Caller holds treo_live_gpu_lock; live targets and canvas backing survive.
static void treo_live_trim_textures_locked(void) {
    [treo_live_owner_textures removeAllObjects];
    [treo_live_owner_texture_bytes removeAllObjects];
}

// Do not block UIKit on a GPU command. A single coalesced recovery task
// waits for the workspace if it is busy, without retaining any JVM pointer.
int j2me_render_trim_memory_cache(void) {
    jarbox_decoded_trim();
    if (os_unfair_lock_trylock(&treo_live_gpu_lock)) {
        treo_live_trim_textures_locked();
        os_unfair_lock_unlock(&treo_live_gpu_lock);
        return 1;
    }
    if (!atomic_exchange_explicit(&treo_texture_trim_queued, 1, memory_order_acq_rel)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                os_unfair_lock_lock(&treo_live_gpu_lock);
                treo_live_trim_textures_locked();
                atomic_store_explicit(&treo_texture_trim_queued, 0, memory_order_release);
                os_unfair_lock_unlock(&treo_live_gpu_lock);
            }
        });
    }
    return 0;
}

static void treo_live_release_owner(uint64_t owner_key) {
    if (!owner_key) return;
    os_unfair_lock_lock(&treo_live_gpu_lock);
    NSNumber *key = @(owner_key);
    [treo_live_owner_targets removeObjectForKey:key];
    [treo_live_owner_textures removeObjectForKey:key];
    [treo_live_owner_texture_bytes removeObjectForKey:key];
    os_unfair_lock_unlock(&treo_live_gpu_lock);
}

static id<MTLTexture> treo_live_texture(CGImageRef image, int cacheable,
                                       uint64_t owner_key) {
    if (!owner_key) return nil;
    // Accessed only with the GPU workspace lock held. Owner identity is
    // unchanged; the shared budget applies only to regenerable textures.
    NSNumber *owner = @(owner_key);
    NSMutableDictionary *cache = treo_live_owner_textures[owner];
    NSValue *key = [NSValue valueWithPointer:image];
    NSArray *entry = cacheable ? cache[key] : nil;
    if (entry) return entry[1];
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    if (!w || !h || w > SIZE_MAX / 4 / h) return nil;
    size_t bytes = w * h * 4;
    size_t used = [treo_live_owner_texture_bytes[owner] unsignedLongLongValue];
    if (!treo_texture_cache_fits(0, bytes, TREO_TEXTURE_OWNER_BUDGET))
        cacheable = 0;
    if (cacheable) {
        if (!treo_texture_cache_fits(used, bytes, TREO_TEXTURE_OWNER_BUDGET)) {
            [cache removeAllObjects];
            treo_live_owner_texture_bytes[owner] = @0;
            used = 0;
        }
        size_t total = 0;
        for (NSNumber *amount in [treo_live_owner_texture_bytes allValues])
            total += amount.unsignedLongLongValue;
        if (!treo_texture_cache_fits(total, bytes, TREO_TEXTURE_TOTAL_BUDGET)) {
            treo_live_trim_textures_locked();
            cache = nil;
            used = 0;
        }
        if (!cache) {
            cache = [NSMutableDictionary new];
            treo_live_owner_textures[owner] = cache;
        }
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [treo_live_device newTextureWithDescriptor:td];
    if (!tex) return nil;
    CGContextRef bitmap = treo_replay_bitmap(w, h);
    if (!bitmap) return nil;
    CGContextSetBlendMode(bitmap, kCGBlendModeCopy);
    CGContextDrawImage(bitmap, CGRectMake(0, 0, w, h), image);
    CGContextFlush(bitmap);
    [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0
             withBytes:CGBitmapContextGetData(bitmap) bytesPerRow:w * 4];
    CGContextRelease(bitmap);
    if (cacheable) {
        cache[key] = @[(__bridge id)image, tex];
        treo_live_owner_texture_bytes[owner] = @(used + bytes);
    }
    return tex;
}

static id<MTLTexture> treo_live_solid(uint32_t color, NSMutableDictionary *solids) {
    NSNumber *key = @(color);
    id<MTLTexture> tex = solids[key];
    if (tex) return tex;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
        MTLPixelFormatBGRA8Unorm width:1 height:1 mipmapped:NO];
    td.storageMode = MTLStorageModeShared;
    tex = [treo_live_device newTextureWithDescriptor:td];
    if (!tex) return nil;
    unsigned a = color >> 24;
    uint8_t pixel[4] = {
        (uint8_t)(((color & 255) * a + 127) / 255),
        (uint8_t)((((color >> 8) & 255) * a + 127) / 255),
        (uint8_t)((((color >> 16) & 255) * a + 127) / 255), (uint8_t)a
    };
    [tex replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 withBytes:pixel bytesPerRow:4];
    solids[key] = tex;
    return tex;
}

static int treo_live_render(RenderContext *rc, TreoLiveRun *run) {
    // Recheck after acquiring the shared GPU workspace lock.
    if (!treo_rc_may_submit(rc)) return 0;
    // Under process memory pressure the original CG path avoids creating
    // another Metal texture set/readback buffer. The recorded run survives.
    if (jvm_bridge_memory_state_cached() != 0) {
        treo_live_trim_textures_locked();
        return 0;
    }
    if (!treo_live_pipeline) {
        treo_live_device = MTLCreateSystemDefaultDevice();
        treo_live_queue = [treo_live_device newCommandQueue];
        treo_live_pipeline = treo_sprite_pipeline(treo_live_device, NULL);
        treo_live_vertices = [treo_live_device newBufferWithLength:TreoLiveCapacity * 6 * sizeof(TreoVertex)
                                                           options:MTLResourceStorageModeShared];
        treo_live_owner_targets = [NSMutableDictionary new];
        treo_live_owner_textures = [NSMutableDictionary new];
        treo_live_owner_texture_bytes = [NSMutableDictionary new];
    }
    if (!treo_live_pipeline || !treo_live_queue || !treo_live_vertices ||
        !rc->heap_key) return 0;
    size_t w = rc->width, h = rc->height;
    NSNumber *owner = @(rc->heap_key);
    id<MTLTexture> target = treo_live_owner_targets[owner];
    if (!target || target.width != w || target.height != h) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget;
        target = [treo_live_device newTextureWithDescriptor:td];
        if (target) treo_live_owner_targets[owner] = target;
    }
    if (!target) return 0;
    NSMutableArray<id<MTLTexture>> *sources = [NSMutableArray arrayWithCapacity:run->count];
    NSMutableDictionary *solids = [NSMutableDictionary new];
    for (unsigned i = 0; i < run->count; i++) {
        TreoSprite *s = &run->sprites[i];
        id<MTLTexture> tex = s->kind == TreoRect ? treo_live_solid(s->color, solids)
            : i && s->image == run->sprites[i - 1].image ? sources.lastObject
            : treo_live_texture(s->image, s->cacheable, rc->heap_key);
        if (!tex) return 0;
        [sources addObject:tex];
    }

    CGContextFlush(rc->ctx);
    const void *base = CGBitmapContextGetData(rc->ctx);
    if (!base) return 0;
    MTLRegion rect = MTLRegionMake2D(0, 0, w, h);
    [target replaceRegion:rect mipmapLevel:0 withBytes:base
                        bytesPerRow:CGBitmapContextGetBytesPerRow(rc->ctx)];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> command = [treo_live_queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [command renderCommandEncoderWithDescriptor:pass];
    if (!enc) return 0;
    [enc setRenderPipelineState:treo_live_pipeline];
    [enc setVertexBuffer:treo_live_vertices offset:0 atIndex:0];
    TreoVertex *vertices = treo_live_vertices.contents;
    const unsigned corners[6] = {0, 1, 2, 2, 1, 3};
    for (unsigned i = 0; i < run->count;) {
        unsigned start = i;
        id<MTLTexture> tex = sources[i];
        do {
            for (unsigned k = 0; k < 6; k++) {
                TreoVertex *v = &vertices[i * 6 + k];
                treo_replay_vertex(v, &run->sprites[i], corners[k] & 1,
                                   corners[k] >> 1, tex.width, tex.height, w, h);
                if (run->sprites[i].kind == TreoRect) v->u = v->v = 0.5f;
            }
            i++;
        } while (i < run->count && sources[i] == tex);
        [enc setFragmentTexture:tex atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:start * 6 vertexCount:(i - start) * 6];
    }
    [enc endEncoding];
    // Focus may move while preparing textures/vertices. The command has
    // not been submitted yet; preserve the recorded run via CG fallback.
    if (!treo_rc_may_submit(rc)) return 0;
    if (!jarbox_scene_gpu_try_begin(&g_scene_gpu_gate)) return 0;
    if (!treo_rc_may_submit(rc)) {
        jarbox_scene_gpu_end(&g_scene_gpu_gate);
        return 0;
    }
    [command commit];
    [command waitUntilCompleted];
    jarbox_scene_gpu_end(&g_scene_gpu_gate);
    if (command.status != MTLCommandBufferStatusCompleted) return 0;

    // Only at frame boundary. Keep the CG backing authoritative for later
    // partial repaints, copyArea and switching the backend without a restart.
    NSMutableData *bytes = [NSMutableData dataWithLength:w * h * 4];
    if (!bytes) return 0;
    [target getBytes:bytes.mutableBytes bytesPerRow:w * 4 fromRegion:rect mipmapLevel:0];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    if (!provider) return 0;
    CGImageRef image = CGImageCreate(w, h, 8, 32, w * 4, getColorSpace(),
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, NULL, false,
        kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    if (!image) return 0;
    treo_unclip_canvas(rc);
    CGContextSetBlendMode(rc->ctx, kCGBlendModeCopy);
    CGContextSetInterpolationQuality(rc->ctx, kCGInterpolationNone);
    treo_draw_region_cg(rc->ctx, image, 0, 0, (int)w, (int)h, 0);
    treo_restore_canvas(rc);
    CGImageRelease(image);
    return 1;
}

static void treo_live_drain(RenderContext *rc, int allowMetal) {
    TreoLiveRun *run = rc->liveRun;
    if (!run || !run->count) return;
    int usedMetal = 0;
    if (allowMetal && !rc->liveBlocked && treo_metal_live_enabled() &&
        treo_rc_may_submit(rc) && os_unfair_lock_trylock(&treo_live_gpu_lock)) {
        @autoreleasepool { usedMetal = treo_live_render(rc, run); }
        os_unfair_lock_unlock(&treo_live_gpu_lock);
    }
    if (usedMetal) {
        atomic_fetch_add_explicit(&treo_live_frames, 1, memory_order_relaxed);
        atomic_fetch_add_explicit(&treo_live_sprites, run->count, memory_order_relaxed);
    } else {
        atomic_fetch_add_explicit(&treo_live_fallback, run->count, memory_order_relaxed);
        treo_unclip_canvas(rc);
        CGRect clip = CGRectMake(0, 0, rc->width, rc->height);
        CGContextSaveGState(rc->ctx);
        for (unsigned i = 0; i < run->count; i++) {
            TreoSprite *s = &run->sprites[i];
            if (!CGRectEqualToRect(clip, s->clip)) {
                CGContextRestoreGState(rc->ctx);
                CGContextSaveGState(rc->ctx);
                clip = s->clip;
                CGContextClipToRect(rc->ctx, clip);
            }
            if (s->kind == TreoRect) {
                setColorFromARGB(rc->ctx, (int)s->color);
                CGContextFillRect(rc->ctx, CGRectMake(s->x, s->y, s->w, s->h));
            } else if (s->kind == TreoShape) {
                CGContextSaveGState(rc->ctx);
                setColorFromARGB(rc->ctx, (int)s->color);
                treo_apply_stroke(rc->ctx, s->stroke);
                TreoShapeDraw draw = (__bridge TreoShapeDraw)s->shape;
                draw(rc->ctx);
                CGContextRestoreGState(rc->ctx);
            } else if (s->kind == TreoText) {
                CGContextSaveGState(rc->ctx);
                setColorFromARGB(rc->ctx, (int)s->color);
                CGContextTranslateCTM(rc->ctx, s->textX, s->textY);
                CGContextScaleCTM(rc->ctx, 1, -1);
                CGContextSetTextPosition(rc->ctx, 0, 0);
                CTLineDraw(s->line, rc->ctx);
                CGContextRestoreGState(rc->ctx);
            } else {
                CGImageRef sub = (s->sx == 0 && s->sy == 0 &&
                    (size_t)s->w == CGImageGetWidth(s->image) && (size_t)s->h == CGImageGetHeight(s->image))
                    ? CGImageRetain(s->image)
                    : CGImageCreateWithImageInRect(s->image, CGRectMake(s->sx, s->sy, s->w, s->h));
                if (!sub) continue;
                treo_draw_region_cg(rc->ctx, sub, s->x, s->y, s->w, s->h, s->transform);
                CGImageRelease(sub);
            }
        }
        CGContextRestoreGState(rc->ctx);
        treo_restore_canvas(rc);
    }
    treo_live_clear(run);
}

static void treo_live_barrier(RenderContext *rc) {
    if (!rc || !rc->ownsPixels) return;
    if (rc->cpuCache) treo_cpu_batch_drain(rc);
    if (rc->liveRun && rc->liveRun->count) treo_live_drain(rc, 0);
    if (treo_metal_live_enabled()) rc->liveBlocked = 1;
}

static int treo_live_recording(RenderContext *rc) {
    return rc->ownsPixels && !rc->liveBlocked && treo_metal_live_enabled() &&
        treo_rc_may_submit(rc) &&
        !atomic_load_explicit(&treo_replay_state, memory_order_relaxed) &&
        rc->width > 0 && rc->height > 0 && rc->width <= 1024 && rc->height <= 1024;
}

static TreoSprite *treo_live_slot(RenderContext *rc) {
    if (!rc->liveRun) rc->liveRun = calloc(1, sizeof(TreoLiveRun));
    TreoLiveRun *run = rc->liveRun;
    if (!run || run->count == TreoLiveCapacity) return NULL;
    TreoSprite *s = &run->sprites[run->count++];
    *s = (TreoSprite){0};
    s->clip = CGRectIsNull(rc->regionClipBounds) ? CGRectZero : rc->regionClipBounds;
    return s;
}

static int treo_live_image(RenderContext *rc, CGImageRef image, int64_t x, int64_t y,
                           int sx, int sy, int w, int h, int transform, int cacheable) {
    if (!treo_live_recording(rc) || !image || sx < 0 || sy < 0 || w <= 0 || h <= 0 ||
        transform < 0 || transform > 7 || x < -32768 || x > 32768 || y < -32768 || y > 32768)
        return 0;
    size_t tw = CGImageGetWidth(image), th = CGImageGetHeight(image);
    if (tw > 2048 || th > 2048 || (size_t)sx + (size_t)w > tw || (size_t)sy + (size_t)h > th)
        return 0;
    size_t bytes = cacheable ? 0 : tw * th * 4;
    if (bytes + (rc->liveRun ? rc->liveRun->transientBytes : 0) > 4u * 1024u * 1024u) return 0;
    TreoSprite *s = treo_live_slot(rc);
    if (!s) return 0;
    s->image = CGImageRetain(image);
    s->x = x; s->y = y; s->sx = sx; s->sy = sy;
    s->w = w; s->h = h; s->transform = transform; s->cacheable = cacheable;
    rc->liveRun->transientBytes += bytes;
    return 1;
}

static int treo_live_enqueue(RenderContext *rc, RenderImage *img, int64_t x, int64_t y,
                             int sx, int sy, int w, int h, int transform) {
    if (!treo_live_recording(rc)) return 0;
    if (img->immutableSnapshot)
        return treo_live_image(rc, img->immutableSnapshot, x, y, sx, sy, w, h, transform, 1);
    if (!img->ctx || img->width > 1024 || img->height > 1024) return 0;
    CGImageRef snapshot = copyImageSnapshot(img);
    if (!snapshot) return 0;
    int ok = treo_live_image(rc, snapshot, x, y, sx, sy, w, h, transform, 0);
    CGImageRelease(snapshot);
    return ok;
}

static int treo_live_rect(RenderContext *rc, int x, int y, int w, int h) {
    if (!treo_live_recording(rc) || w < 0 || h < 0) return 0;
    if (!w || !h || !(rc->liveColor >> 24)) return 1;
    CGRect rect = CGRectIntersection(rc->regionClipBounds, CGRectMake(x, y, w, h));
    if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) return 1;
    TreoSprite *s = treo_live_slot(rc);
    if (!s) return 0;
    s->kind = TreoRect; s->color = rc->liveColor;
    s->x = (int64_t)rect.origin.x; s->y = (int64_t)rect.origin.y;
    s->w = (int)rect.size.width; s->h = (int)rect.size.height;
    return 1;
}

static int treo_live_shape(RenderContext *rc, CGRect bounds, TreoShapeDraw draw) {
    if (!treo_live_recording(rc)) return 0;
    bounds = CGRectIntersection(CGRectIntegral(bounds), rc->regionClipBounds);
    if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds)) return 1;
    size_t w = (size_t)bounds.size.width, h = (size_t)bounds.size.height;
    CGContextRef bitmap = treo_replay_bitmap(w, h);
    if (!bitmap) return 0;
    CGContextTranslateCTM(bitmap, -bounds.origin.x, h + bounds.origin.y);
    CGContextScaleCTM(bitmap, 1, -1);
    CGContextSetLineWidth(bitmap, 1);
    CGContextSetLineCap(bitmap, kCGLineCapSquare);
    CGContextSetLineJoin(bitmap, kCGLineJoinMiter);
    setColorFromARGB(bitmap, (int)rc->liveColor);
    treo_apply_stroke(bitmap, rc->liveStroke);
    draw(bitmap);
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    if (!image) return 0;
    int ok = treo_live_image(rc, image, (int64_t)bounds.origin.x, (int64_t)bounds.origin.y, 0, 0, (int)w, (int)h, 0, 0);
    CGImageRelease(image);
    if (ok) {
        TreoSprite *s = &rc->liveRun->sprites[rc->liveRun->count - 1];
        s->kind = TreoShape; s->color = rc->liveColor; s->stroke = rc->liveStroke;
        s->shape = (__bridge_retained void *)[draw copy];
    }
    return ok;
}

static int treo_live_text(RenderContext *rc, CTLineRef line, CGFloat x, CGFloat baseline) {
    if (!treo_live_recording(rc)) return 0;
    CGRect glyph = CTLineGetBoundsWithOptions(line, kCTLineBoundsUseGlyphPathBounds);
    if (CGRectIsNull(glyph) || CGRectIsEmpty(glyph)) return 0;
    CGRect bounds = CGRectIntegral(CGRectInset(
        CGRectMake(x + glyph.origin.x, baseline - CGRectGetMaxY(glyph), glyph.size.width, glyph.size.height), -4, -4));
    bounds = CGRectIntersection(bounds, rc->regionClipBounds);
    if (CGRectIsNull(bounds) || CGRectIsEmpty(bounds)) return 1;
    size_t w = (size_t)bounds.size.width, h = (size_t)bounds.size.height;
    CGContextRef bitmap = treo_replay_bitmap(w, h);
    if (!bitmap) return 0;
    setColorFromARGB(bitmap, (int)rc->liveColor);
    CGContextSetTextPosition(bitmap, x - bounds.origin.x, h - (baseline - bounds.origin.y));
    CTLineDraw(line, bitmap);
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    CGContextRelease(bitmap);
    if (!image) return 0;
    int ok = treo_live_image(rc, image, (int64_t)bounds.origin.x, (int64_t)bounds.origin.y, 0, 0, (int)w, (int)h, 0, 0);
    CGImageRelease(image);
    if (ok) {
        TreoSprite *s = &rc->liveRun->sprites[rc->liveRun->count - 1];
        s->kind = TreoText; s->color = rc->liveColor;
        s->line = (CTLineRef)CFRetain(line);
        s->textX = x; s->textY = baseline;
    }
    return ok;
}

// Exact CPU raster reuse. A hit requires the same ordered commands, same
// clip and byte-for-byte identical destination pixels before the batch.
enum { TreoBatchSize = 32, TreoBatchSlots = 8, TreoBatchMaxPixels = 48000 };
typedef struct {
    CGImageRef image;
    int x, y, sx, sy, w, h, transform;
} TreoBatchDraw;
typedef struct {
    TreoBatchDraw draws[TreoBatchSize];
    CGRect clip, area;
    uint8_t *before;
    CGImageRef after;
} TreoBatchEntry;
struct TreoCPUCache {
    unsigned count, next;
    TreoBatchDraw pending[TreoBatchSize];
    TreoBatchEntry entries[TreoBatchSlots];
};
static atomic_bool treo_batch_enabled;
static _Atomic uint64_t treo_batch_reused, treo_batch_queued;
int treo_cpu_batch_enabled(void) { return atomic_load_explicit(&treo_batch_enabled, memory_order_relaxed); }
void treo_cpu_batch_set_enabled(int enabled) { atomic_store_explicit(&treo_batch_enabled, enabled != 0, memory_order_relaxed); }
uint64_t treo_cpu_batch_reused(void) { return atomic_load_explicit(&treo_batch_reused, memory_order_relaxed); }
uint64_t treo_cpu_batch_queued(void) { return atomic_load_explicit(&treo_batch_queued, memory_order_relaxed); }

static void treo_batch_entry_clear(TreoBatchEntry *entry) {
    if (!entry->after) return;
    for (unsigned i = 0; i < TreoBatchSize; i++) CGImageRelease(entry->draws[i].image);
    CGImageRelease(entry->after);
    free(entry->before);
    *entry = (TreoBatchEntry){0};
}
static void treo_batch_pending_clear(TreoCPUCache *cache) {
    for (unsigned i = 0; i < cache->count; i++) CGImageRelease(cache->pending[i].image);
    cache->count = 0;
}
static void treo_cpu_batch_free(RenderContext *rc) {
    TreoCPUCache *cache = rc->cpuCache;
    if (!cache) return;
    treo_batch_pending_clear(cache);
    for (unsigned i = 0; i < TreoBatchSlots; i++) treo_batch_entry_clear(&cache->entries[i]);
    free(cache);
    rc->cpuCache = NULL;
}
static int treo_batch_matches(const TreoBatchDraw *a, const TreoBatchDraw *b) {
    for (unsigned i = 0; i < TreoBatchSize; i++, a++, b++) {
        if (a->image != b->image || a->x != b->x || a->y != b->y ||
            a->sx != b->sx || a->sy != b->sy || a->w != b->w || a->h != b->h ||
            a->transform != b->transform) return 0;
    }
    return 1;
}
static void treo_cpu_batch_drain(RenderContext *rc) {
    TreoCPUCache *cache = rc->cpuCache;
    if (!cache || !cache->count) return;
    int full = cache->count == TreoBatchSize && treo_cpu_batch_enabled();
    CGRect clip = rc->regionClipBounds;
    CGRect area = CGRectNull;
    if (full) {
        for (unsigned i = 0; i < TreoBatchSize; i++) {
            const TreoBatchDraw *d = &cache->pending[i];
            int turned = d->transform >= 4;
            CGRect rect = CGRectInset(CGRectMake(d->x, d->y, turned ? d->h : d->w,
                                                   turned ? d->w : d->h), -2, -2);
            area = CGRectUnion(area, rect);
        }
        area = CGRectIntersection(area, clip);
    }
    uint8_t *before = NULL;
    size_t stride = 0, row = 0, height = 0;
    uint8_t *base = NULL;
    TreoBatchEntry *replace = NULL;
    if (full && !CGRectIsNull(area) && !CGRectIsEmpty(area) &&
        area.size.width * area.size.height <= TreoBatchMaxPixels) {
        CGContextFlush(rc->ctx);
        stride = CGBitmapContextGetBytesPerRow(rc->ctx);
        uint8_t *data = CGBitmapContextGetData(rc->ctx);
        if (data && stride >= (size_t)rc->width * 4) {
            base = data + (size_t)area.origin.y * stride + (size_t)area.origin.x * 4;
            row = (size_t)area.size.width * 4;
            height = (size_t)area.size.height;
            for (unsigned i = 0; i < TreoBatchSlots; i++) {
                TreoBatchEntry *entry = &cache->entries[i];
                if (!entry->after || !CGRectEqualToRect(clip, entry->clip) ||
                    !CGRectEqualToRect(area, entry->area) ||
                    !treo_batch_matches(cache->pending, entry->draws)) continue;
                size_t j = 0;
                while (j < height && memcmp(base + j * stride, entry->before + j * row, row) == 0) j++;
                if (j == height) {
                    CGContextSaveGState(rc->ctx);
                    CGContextSetBlendMode(rc->ctx, kCGBlendModeCopy);
                    CGContextSetInterpolationQuality(rc->ctx, kCGInterpolationNone);
                    treo_draw_region_cg(rc->ctx, entry->after, (int)area.origin.x, (int)area.origin.y,
                                        (int)area.size.width, (int)area.size.height, TRANS_NONE);
                    CGContextRestoreGState(rc->ctx);
                    atomic_fetch_add_explicit(&treo_batch_reused, TreoBatchSize, memory_order_relaxed);
                    treo_batch_pending_clear(cache);
                    return;
                }
                replace = entry;
            }
            before = malloc(row * height);
            if (before) for (size_t j = 0; j < height; j++) memcpy(before + j * row, base + j * stride, row);
        }
    }
    for (unsigned i = 0; i < cache->count; i++) {
        const TreoBatchDraw *d = &cache->pending[i];
        CGImageRef crop = CGImageCreateWithImageInRect(d->image, CGRectMake(d->sx, d->sy, d->w, d->h));
        if (!crop) continue;
        treo_draw_region_cg(rc->ctx, crop, d->x, d->y, d->w, d->h, d->transform);
        CGImageRelease(crop);
    }
    if (before) {
        CGContextFlush(rc->ctx);
        // Copy only the rectangle, not a snapshot that keeps a whole canvas alive.
        uint8_t *current = CGBitmapContextGetData(rc->ctx);
        CFMutableDataRef pixels = current ? CFDataCreateMutable(NULL, (CFIndex)(row * height)) : NULL;
        if (pixels) {
            CFDataSetLength(pixels, (CFIndex)(row * height));
            uint8_t *dst = CFDataGetMutableBytePtr(pixels);
            current += (size_t)area.origin.y * stride + (size_t)area.origin.x * 4;
            for (size_t j = 0; j < height; j++) memcpy(dst + j * row, current + j * stride, row);
            CGDataProviderRef provider = CGDataProviderCreateWithCFData(pixels);
            CGImageRef result = provider ? CGImageCreate(row / 4, height, 8, 32, row, getColorSpace(),
                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little, provider, NULL,
                false, kCGRenderingIntentDefault) : NULL;
            if (provider) CGDataProviderRelease(provider);
            CFRelease(pixels);
            if (result) {
                if (!replace) replace = &cache->entries[(cache->next++) % TreoBatchSlots];
                treo_batch_entry_clear(replace);
                replace->after = result;
                replace->before = before;
                replace->clip = clip;
                replace->area = area;
                for (unsigned i = 0; i < TreoBatchSize; i++) {
                    replace->draws[i] = cache->pending[i];
                    CGImageRetain(replace->draws[i].image);
                }
                before = NULL;
            }
        }
        free(before);
    }
    treo_batch_pending_clear(cache);
}

static int treo_cpu_batch_enqueue(RenderContext *rc, RenderImage *img, int64_t x, int64_t y,
                                  int sx, int sy, int w, int h, int transform) {
    if (!rc->ownsPixels || !img->immutableSnapshot || !treo_cpu_batch_enabled() ||
        treo_metal_live_enabled() || treo_rc_afk(rc) ||
        atomic_load_explicit(&treo_replay_state, memory_order_relaxed) ||
        (rc->liveRun && rc->liveRun->count) || x < -32768 || x > 32768 || y < -32768 || y > 32768 ||
        transform < 0 || transform > 7 || sx < 0 || sy < 0 || w <= 0 || h <= 0 ||
        (int64_t)sx + w > img->width || (int64_t)sy + h > img->height) return 0;
    if (!rc->cpuCache) rc->cpuCache = calloc(1, sizeof(TreoCPUCache));
    TreoCPUCache *cache = rc->cpuCache;
    if (!cache) return 0;
    cache->pending[cache->count++] = (TreoBatchDraw){
        CGImageRetain(img->immutableSnapshot), (int)x, (int)y, sx, sy, w, h, transform
    };
    if (cache->count == TreoBatchSize) {
        atomic_fetch_add_explicit(&treo_batch_queued, TreoBatchSize, memory_order_relaxed);
        treo_cpu_batch_drain(rc);
    }
    return 1;
}

// Ordered software compositor: no crop objects, transforms or per-sprite CG calls
// on the accepted path. Keep mutable images and unusual contexts on the reference path.
static inline uint32_t treo_sw_over(uint32_t s, uint32_t d) {
    unsigned alpha = s >> 24;
    if (alpha == 255) return s;
    if (!alpha) return d;
    unsigned f = 255 - alpha;
    uint32_t result = 0;
    for (unsigned k = 0; k < 32; k += 8) {
        unsigned q = ((d >> k) & 255) * f + 128;
        unsigned v = ((s >> k) & 255) + ((q + (q >> 8)) >> 8);
        result |= (v < 255 ? v : 255) << k;
    }
    return result;
}

static inline void treo_sw_row(uint32_t *d, const uint32_t *s, int n, int binaryFast) {
#if defined(__ARM_NEON)
    for (; n >= 8; n -= 8, s += 8, d += 8) {
        uint8x8x4_t src = vld4_u8((const uint8_t *)s);
        if (vminv_u8(src.val[3]) == 255) { vst4_u8((uint8_t *)d, src); continue; }
        if (vmaxv_u8(src.val[3]) == 0) continue;
        uint8x8x4_t dst = vld4_u8((const uint8_t *)d);
        if (binaryFast) {
            uint8x8_t opaque = vceq_u8(src.val[3], vdup_n_u8(255));
            uint8x8_t clear = vceq_u8(src.val[3], vdup_n_u8(0));
            if (vminv_u8(vorr_u8(opaque, clear)) == 255) {
                for (int k = 0; k < 4; k++) dst.val[k] = vbsl_u8(opaque, src.val[k], dst.val[k]);
                vst4_u8((uint8_t *)d, dst);
                continue;
            }
        }
        uint8x8_t f = vmvn_u8(src.val[3]);
        for (int k = 0; k < 4; k++) {
            uint16x8_t q = vaddq_u16(vmull_u8(dst.val[k], f), vdupq_n_u16(128));
            dst.val[k] = vqadd_u8(src.val[k], vshrn_n_u16(vaddq_u16(q, vshrq_n_u16(q, 8)), 8));
        }
        vst4_u8((uint8_t *)d, dst);
    }
#endif
    for (int i = 0; i < n; i++) d[i] = treo_sw_over(s[i], d[i]);
}

static void treo_sw_raster(RenderContext *rc, RenderImage *img, int x, int y,
                            int sx, int sy, int w, int h, int t,
                            int l, int top, int right, int bottom, int binaryFast) {
    const ptrdiff_t stride = (ptrdiff_t)img->softwareStride;
    const uint32_t *origin = img->softwareSource + sy * stride + sx;
    for (int dy = top; dy < bottom; dy++) {
        uint32_t *d = rc->softwarePixels + dy * rc->width + l;
        int u = l - x, v = dy - y;
        if (t == 0 || t == 1) {
            int row = t == 0 ? v : h - 1 - v;
            treo_sw_row(d, origin + row * stride + u, right - l, binaryFast);
            continue;
        }
        ptrdiff_t index, step;
        switch (t) {
            case 2: index = v * stride + w - 1 - u; step = -1; break;
            case 3: index = (h - 1 - v) * stride + w - 1 - u; step = -1; break;
            case 4: index = u * stride + v; step = stride; break;
            case 5: index = (h - 1 - u) * stride + v; step = -stride; break;
            case 6: index = u * stride + w - 1 - v; step = stride; break;
            default: index = (h - 1 - u) * stride + w - 1 - v; step = -stride; break;
        }
        for (int dx = l; dx < right; dx++, index += step, d++) *d = treo_sw_over(origin[index], *d);
    }
}

static int treo_sw_draw(RenderContext *rc, RenderImage *img, int64_t x, int64_t y,
                        int sx, int sy, int w, int h, int t, int binaryFast) {
    if (!rc->softwarePixels || !img->immutableSnapshot || !img->softwareSource ||
        t < 0 || t > 7 || x < -32768 || x > 32768 || y < -32768 || y > 32768 ||
        sx < 0 || sy < 0 || w <= 0 || h <= 0 ||
        (int64_t)sx + w > img->width || (int64_t)sy + h > img->height ||
        rc->liveRawClip.size.width < 0 || rc->liveRawClip.size.height < 0) return 0;
    unsigned bit = 1u << t;
    if (atomic_load_explicit(&img->softwareRejected, memory_order_relaxed) & bit) return 0;
    CGRect clip = rc->regionClipBounds;
    if (CGRectIsNull(clip) || CGRectIsEmpty(clip)) { rc->swFast++; return 1; }
    int l = MAX((int)x, (int)CGRectGetMinX(clip));
    int top = MAX((int)y, (int)CGRectGetMinY(clip));
    int r = MIN((int)x + (t >= 4 ? h : w), (int)CGRectGetMaxX(clip));
    int b = MIN((int)y + (t >= 4 ? w : h), (int)CGRectGetMaxY(clip));
    if (r <= l || b <= top) { rc->swFast++; return 1; }
    int verified = (atomic_load_explicit(&img->softwareVerified, memory_order_relaxed) & bit) != 0;
    // Validate first use of each image/transform and periodically thereafter.
    // Compare on real background pixels, and always keep the CG result on checks.
    if (!verified || ((++rc->swSequence & 1023u) == 0)) {
        size_t row = (size_t)(r - l), n = row * (size_t)(b - top);
        uint32_t *scratch = malloc(n * 2 * sizeof(*scratch));
        if (!scratch) return 0;
        CGImageRef crop = CGImageCreateWithImageInRect(img->immutableSnapshot, CGRectMake(sx, sy, w, h));
        if (!crop) { free(scratch); return 0; }
        uint32_t *base = rc->softwarePixels + top * rc->width + l;
        for (int i = 0; i < b - top; i++) memcpy(scratch + i * row, base + i * rc->width, row * 4);
        treo_sw_raster(rc, img, (int)x, (int)y, sx, sy, w, h, t, l, top, r, b, binaryFast);
        for (int i = 0; i < b - top; i++) {
            memcpy(scratch + n + i * row, base + i * rc->width, row * 4);
            memcpy(base + i * rc->width, scratch + i * row, row * 4);
        }
        treo_draw_region_cg(rc->ctx, crop, x, y, w, h, t);
        CGImageRelease(crop);
        int equal = 1;
        for (int i = 0; i < b - top; i++)
            if (memcmp(scratch + n + i * row, base + i * rc->width, row * 4)) { equal = 0; break; }
        free(scratch);
        rc->swChecked++;
        if (equal) atomic_fetch_or_explicit(&img->softwareVerified, bit, memory_order_relaxed);
        else {
            rc->swMismatch++;
            atomic_fetch_or_explicit(&img->softwareRejected, bit, memory_order_relaxed);
        }
        return 1;
    }
    treo_sw_raster(rc, img, (int)x, (int)y, sx, sy, w, h, t, l, top, r, b, binaryFast);
    rc->swFast++;
    return 1;
}

typedef struct {
    s64 ctx, img;
    s32 sx, sy, w, h, transform, x, y, anchor;
    uint64_t owner_key;
} TreoRegionArgs;
#include "jarbox_region_slots.h"

// Same CG crop result, reused only for valid immutable source regions on the
// compatible parked Canvas. Keep replay, mutable images and offscreen on CG.
static CGImageRef treo_compatible_crop(RenderContext *rc, CGImageRef source,
                                      int x,int y,int w,int h) {
    if (!rc->cropCache) {
        rc->cropCache=calloc(1,sizeof(*rc->cropCache));
        if (rc->cropCache) native_heap_add(rc->heap_key,(s32)sizeof(*rc->cropCache));
    }
    size_t before=rc->cropCache ? rc->cropCache->bytes : 0;
    int hit;
    CGImageRef crop=jarbox_crop_get(rc->cropCache,source,x,y,w,h,&hit);
    if (rc->cropCache) {
        size_t after=rc->cropCache->bytes;
        if (after>before) native_heap_add(rc->heap_key,(s32)(after-before));
        else if (before>after) native_heap_sub(rc->heap_key,(s32)(before-after));
    }
    if (hit) ++rc->compatible_crop_hits;
    else ++rc->compatible_crop_misses;
    return crop;
}

#if defined(TREO_BINARY_SPRITE_EXPERIMENT) && TREO_BINARY_SPRITE_EXPERIMENT
/* Strict subset of the existing software backend. No partial-alpha blend,
 * no rotation, no mutable image/offscreen context, no speculative write on
 * a canary. Caller has drained prior draw queues and holds both leases. */
static int treo_binary_mode1_draw(RenderContext *rc,RenderImage *img,int64_t x,int64_t y,
                                  int sx,int sy,int w,int h) {
    if (rc->binaryRejected || !rc->softwarePixels || img->isMutable ||
        !img->immutableSnapshot || !img->softwareSource ||
        (uint64_t)w*(uint64_t)h>65536 || rc->width>1024 || rc->height>1024) return 0;
    CGRect clip=rc->regionClipBounds;
    if (CGRectIsNull(clip) || CGRectIsEmpty(clip)) return 0;
    CGFloat l=CGRectGetMinX(clip),t=CGRectGetMinY(clip),rr=CGRectGetMaxX(clip),bb=CGRectGetMaxY(clip);
    if (!(l>=0 && t>=0 && rr<=rc->width && bb<=rc->height) ||
        l!=(int)l || t!=(int)t || rr!=(int)rr || bb!=(int)bb) return 0;
    JarBoxBinaryRect p;
    if (!jarbox_binary_rect(&p,x,y,sx,sy,w,h,img->width,img->height,rc->width,rc->height,
                            (int)l,(int)t,(int)rr,(int)bb) || !p.w || !p.h) return 0;
    unsigned kind=atomic_load_explicit(&img->binaryKind,memory_order_relaxed);
    if (!kind) {
        kind=jarbox_binary_kind(img->softwareSource,img->width,img->height,img->softwareStride);
        atomic_store_explicit(&img->binaryKind,kind,memory_order_relaxed);
    }
    if (kind<JB_BIN_MIXED || kind>JB_BIN_CLEAR) return 0;
    uint32_t *dst=rc->softwarePixels+(size_t)p.y*rc->width+p.x;
    const uint32_t *src=img->softwareSource+(size_t)p.sy*img->softwareStride+p.sx;
    const int check=!rc->binaryReady ||
        !atomic_load_explicit(&img->binaryVerified,memory_order_relaxed) ||
        ((++rc->binarySequence&1023u)==0);
    if (check) {
        CGAffineTransform ctm=CGContextGetCTM(rc->ctx);
        if (ctm.a!=1 || ctm.b!=0 || ctm.c!=0 || ctm.d!=-1 || ctm.tx!=0 || ctm.ty!=rc->height ||
            !CGRectEqualToRect(CGContextGetClipBoundingBox(rc->ctx),clip) ||
            CGBitmapContextGetData(rc->ctx)!=rc->softwarePixels ||
            CGBitmapContextGetBytesPerRow(rc->ctx)!=(size_t)rc->width*4) {
            rc->binaryRejected=true; ++rc->binaryMismatch; return 0;
        }
        size_t row=(size_t)p.w*4;
        uint32_t *expected=malloc(row*(size_t)p.h);
        if (!expected) return 0;
        CGImageRef crop=CGImageCreateWithImageInRect(img->immutableSnapshot,CGRectMake(sx,sy,w,h));
        if (!crop) {free(expected);return 0;}
        CGContextFlush(rc->ctx);
        for (int i=0;i<p.h;i++) memcpy(expected+(size_t)i*p.w,dst+(size_t)i*rc->width,row);
        jarbox_binary_blit(expected,p.w,src,img->softwareStride,p.w,p.h,kind);
        // Only reference pixels touch the actual Canvas on a check.
        treo_draw_region_cg(rc->ctx,crop,x,y,w,h,TRANS_NONE);
        CGImageRelease(crop); CGContextFlush(rc->ctx);
        int equal=1;
        for (int i=0;i<p.h;i++) if (memcmp(expected+(size_t)i*p.w,dst+(size_t)i*rc->width,row)) {equal=0;break;}
        free(expected); ++rc->binaryChecks;
        if (equal) {rc->binaryReady=true;atomic_store_explicit(&img->binaryVerified,1,memory_order_relaxed);}
        else {rc->binaryRejected=true;++rc->binaryMismatch;}
        return 1;
    }
    jarbox_binary_blit(dst,rc->width,src,img->softwareStride,p.w,p.h,kind);
    ++rc->binaryFast;
    return 1;
}
#endif

static s32 treo_draw_region(const TreoRegionArgs *p, int direct) {
    s64 ctxHandle = p->ctx, imgHandle = p->img;
    s32 xSrc = p->sx, ySrc = p->sy, wSrc = p->w, hSrc = p->h, transform = p->transform;
    int64_t xDst = p->x, yDst = p->y;
    s32 anchor = p->anchor;
    RenderImage *img=NULL;
    int paired=0;
    RenderContext *rc=region_acquire(ctxHandle,imgHandle,p->owner_key,
                                     !g_afk_canvas,&img,&paired);
    if (!rc) return RUNTIME_STATUS_NORMAL;
    if (treo_afk_skip_draw(rc)) { img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (direct && rc->ownsPixels) rc->swDirect++;

    int outW = wSrc, outH = hSrc;
    if (transform == TRANS_ROT90 || transform == TRANS_ROT270 ||
        transform == TRANS_MIRROR_ROT90 || transform == TRANS_MIRROR_ROT270) {
        outW = hSrc; outH = wSrc;
    }

    if (anchor & 1) xDst -= outW / 2;
    if (anchor & 8) xDst -= outW;
    if (anchor & 2) yDst -= outH / 2;
    if (anchor & 32) yDst -= outH;

    if (rc->ownsPixels && treo_render_region_cull_enabled() &&
        !treo_rc_afk(rc) && wSrc > 0 && hSrc > 0 &&
        transform >= 0 && transform <= 7 &&
        treo_region_outside_clip(rc->regionClipBounds, xDst, yDst, outW, outH)) {
        if (treo_profile_active()) TREO_PROF_ADD(region_culled, 1);
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    if (!paired) img = img_acquire(imgHandle, p->owner_key);
    if (!img) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    // AFK SIMD keeps producing canvas pixels, but never presents them.
    // Use the same verified raster and CG fallback as the visible backend.
    const int afkMode = treo_rc_mode(rc);
    const int afkSIMD = afkMode == 5 || afkMode == TreoAFKFastCanvas;
    if (rc->softwarePixels &&
        (afkSIMD || (afkMode == 0 && treo_software_enabled() &&
                    !treo_metal_live_enabled() && !treo_cpu_batch_enabled())) &&
        !atomic_load_explicit(&treo_replay_state, memory_order_relaxed)) {
        rc->swRegions++;
        // Finish any commands queued before changing mode, preserving draw order.
        if (rc->cpuCache) treo_cpu_batch_drain(rc);
        if (rc->liveRun && rc->liveRun->count) treo_live_drain(rc, 0);
        if (treo_sw_draw(rc, img, xDst, yDst, xSrc, ySrc, wSrc, hSrc, transform, direct || afkSIMD)) {
            img_release(img);
            rc_release(rc);
            return RUNTIME_STATUS_NORMAL;
        }
    }
    if (treo_cpu_batch_enqueue(rc, img, xDst, yDst, xSrc, ySrc, wSrc, hSrc, transform)) {
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }
    if (rc->cpuCache) treo_cpu_batch_drain(rc);
    if (treo_live_enqueue(rc, img, xDst, yDst, xSrc, ySrc, wSrc, hSrc, transform)) {
        img_release(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }
    treo_live_barrier(rc);
    CGContextRef rctx = rc->ctx;
    const int compatible = afkMode==1 && rc->ownsPixels && rc->clipSaved &&
        !img->isMutable && img->immutableSnapshot &&
        xSrc>=0 && ySrc>=0 && wSrc>0 && hSrc>0 && transform>=0 && transform<=7 &&
        (int64_t)xSrc+wSrc<=img->width && (int64_t)ySrc+hSrc<=img->height &&
        rc->liveRawClip.size.width>=0 && rc->liveRawClip.size.height>=0 &&
        !atomic_load_explicit(&treo_replay_state,memory_order_relaxed);
    // After all older draws drain; no persistent graphics state is changed.
    if (compatible && treo_region_outside_clip(rc->regionClipBounds,xDst,yDst,outW,outH)) {
        ++rc->compatible_region_culls;
        img_release(img); rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }
#if defined(TREO_BINARY_SPRITE_EXPERIMENT) && TREO_BINARY_SPRITE_EXPERIMENT
    if (compatible && transform==TRANS_NONE &&
#if defined(TREO_BINARY_ABA) && TREO_BINARY_ABA
        jarbox_binary_trial_allowed(&binary_trial_scope,p->owner_key,ctxHandle) &&
#endif
        treo_binary_mode1_draw(rc,img,xDst,yDst,xSrc,ySrc,wSrc,hSrc)) {
        img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL;
    }
#endif
#if defined(TREO_REGION_STAGE_DIAG) && TREO_REGION_STAGE_DIAG
    // Sparse eligible-region tail timing, after handle acquisition, barriers and culling.
    int stageSelected=0;
    uint64_t stageStart=0, stageHits=0;
    if (compatible) {
        ++rc->regionStage.seen;
        stageSelected=jarbox_region_stage_selected(rc->regionStageSequence++);
        if (stageSelected) {
            stageHits=rc->compatible_crop_hits;
            stageStart=treo_thread_cpu_ns();
        }
    }
#endif
    // img_acquire keeps the RenderImage and its immutable snapshot alive
    // through draw and replay capture. The compatible path can borrow the
    // image already owned by img; mutable/noncompatible paths stay owned.
    CGImageRef fullImage = compatible ? img->immutableSnapshot : copyImageSnapshot(img);
    if (!fullImage) {
#if defined(TREO_REGION_STAGE_DIAG) && TREO_REGION_STAGE_DIAG
        if (stageSelected) ++rc->regionStage.invalid;
#endif
        img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL;
    }
    CGImageRef subImage = compatible ? treo_compatible_crop(rc,fullImage,xSrc,ySrc,wSrc,hSrc)
        : CGImageCreateWithImageInRect(fullImage, CGRectMake(xSrc, ySrc, wSrc, hSrc));
    if (subImage) treo_replay_capture(rc, fullImage, xDst, yDst, xSrc, ySrc, wSrc, hSrc, transform);
    if (!compatible) CGImageRelease(fullImage);
    if (!subImage) {
#if defined(TREO_REGION_STAGE_DIAG) && TREO_REGION_STAGE_DIAG
        if (stageSelected) ++rc->regionStage.invalid;
#endif
        img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL;
    }
#if defined(TREO_REGION_STAGE_DIAG) && TREO_REGION_STAGE_DIAG
    uint64_t stageMiddle=stageSelected ? treo_thread_cpu_ns() : 0;
#endif
    treo_draw_region_cg(rctx, subImage, xDst, yDst, wSrc, hSrc, transform);
#if defined(TREO_REGION_STAGE_DIAG) && TREO_REGION_STAGE_DIAG
    if (stageSelected)
        jarbox_region_stage_record(&rc->regionStage,stageStart,stageMiddle,treo_thread_cpu_ns(),
                                   rc->compatible_crop_hits!=stageHits);
#endif
    CGImageRelease(subImage);
    img_release(img);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// Time one call in 64 per render thread; no clock read for each sprite.
static s32 treo_profiled_region(const TreoRegionArgs *p, int direct) {
    static _Thread_local unsigned sequence;
    if (!treo_profile_active()) return treo_draw_region(p, direct);
    TREO_PROF_ADD(region_calls, 1);
    if ((++sequence & 63u) != 0) return treo_draw_region(p, direct);
    uint64_t begin = treo_thread_cpu_ns();
    s32 result = treo_draw_region(p, direct);
    uint64_t end = treo_thread_cpu_ns();
    if (begin && end >= begin && treo_profile_active()) {
        TREO_PROF_ADD(region_samples, 1);
        TREO_PROF_ADD(region_sample_ns, end - begin);
    }
    return result;
}

static s32 n_profiledDrawRegion(Runtime *runtime, JClass *clazz) {
    // Preserve native frame, stop/exception behavior and renderer entry.
    // The JNI getters delegate to the same VM local slot accessors.
    const TreoRegionArgs p=jarbox_region_args(runtime->localvar,
                                            jarbox_native_heap_key_for_runtime(runtime));
    return treo_profiled_region(&p, 0);
}

static int treo_instance_offset(JClass *clazz, const char *name, const char *type, size_t size) {
    for (s32 n = 0; n < clazz->fieldPool.field_used; n++) {
        FieldInfo *f = &clazz->fieldPool.field[n];
        if (!(f->access_flags & 0x0008) && !f->isvolatile &&
            utf8_equals_c(f->name, name) && utf8_equals_c(f->descriptor, type) &&
            clazz->field_instance_len >= (s32)((size_t)f->offset_instance + size)) return f->offset_instance;
    }
    return -1;
}

#if defined(TREO_NINJA_CORE_EXPERIMENT) && TREO_NINJA_CORE_EXPERIMENT
// Read-only real renderer preflight. No residual is admitted by this
// function alone; exact code/API certification is an additional gate.
// Do not retain the object identities beyond the invoking rooted frame.
static int treo_residual_scope_capture_impl(Runtime *runtime,Instance *wrapper,JarBoxResidualScope *out,int generic) {
    if(!out)return 0;
    memset(out,0,sizeof(*out));
    if(!runtime||!runtime->jvm||!runtime->thrd_info||!runtime->jvm->session||
       runtime->jvm->jdwp_enable||runtime->thrd_info->is_stop||
       runtime->thrd_info->suspend_count||!runtime->thrd_info->jarbox_headless_scope)return 0;
    JarBoxSession *session=runtime->jvm->session;
    JarBoxTreoState *state=&session->treo_state;
    if(jarbox_session_phase(session)!=JARBOX_SESSION_PARKED||
       __atomic_load_n(&state->ninja_core.profile,__ATOMIC_ACQUIRE)!=2||
       !jarbox_ninja_core_active(&state->ninja_core,treo_runtime_mode(runtime)))return 0;
    const uint64_t key=jarbox_native_heap_key_for_runtime(runtime);
    if(!key||key!=g_afk_canvas_owner_key||!g_afk_canvas||!g_afk_scope_serial)return 0;
    JarBoxResidualBinding b;
    int bound;
#if defined(JARBOX_RECONSTRUCT_EXPERIMENT) && JARBOX_RECONSTRUCT_EXPERIMENT
    if(generic==2)bound=jbr_nick_glyph_binding(runtime,wrapper,&b);
    else
#endif
    bound=generic?jbr_nick_paint_binding_at(runtime,wrapper,&b,30,5):
                 jbr_nick_binding(runtime,wrapper,&b);
    if(!bound||b.context!=g_afk_canvas)return 0;
    RenderContext *rc=rc_acquire(b.context,key);
    int screen=rc&&rc->ownsPixels&&rc->heap_key==key;
    rc_release(rc);
    if(!screen)return 0;
    // Recheck control-plane eligibility after the registry lease. The
    // current paint's TLS scope remains valid until paired paint end;
    // a mode change is grounds for the next checkpoint to resume.
    if(jarbox_session_phase(session)!=JARBOX_SESSION_PARKED||
       !jarbox_ninja_core_active(&state->ninja_core,treo_runtime_mode(runtime)))return 0;
    *out=(JarBoxResidualScope){.owner=key,.serial=g_afk_scope_serial,.context=b.context,
        .wrapper=(uintptr_t)b.wrapper,.canvas=(uintptr_t)b.canvas,.graphics=(uintptr_t)b.graphics};
    if(!jbr_scope_prepare_fields(out)){memset(out,0,sizeof(*out));return 0;}
    return 1;
}
int treo_residual_scope_capture(Runtime *runtime,Instance *wrapper,JarBoxResidualScope *out) {
    return treo_residual_scope_capture_impl(runtime,wrapper,out,0);
}
#if defined(JARBOX_RENDER_ISLAND_EXPERIMENT) && JARBOX_RENDER_ISLAND_EXPERIMENT
int treo_render_island_scope_capture(Runtime *runtime,Instance *wrapper,JarBoxResidualScope *out) {
    return treo_residual_scope_capture_impl(runtime,wrapper,out,1);
}
#if defined(JARBOX_RECONSTRUCT_EXPERIMENT) && JARBOX_RECONSTRUCT_EXPERIMENT
int treo_glyph_scope_capture(Runtime *runtime,Instance *wrapper,JarBoxResidualScope *out){
    return treo_residual_scope_capture_impl(runtime,wrapper,out,2);
}
#endif
#endif
#if (defined(TREO_RESIDUAL_EXPERIMENT) && TREO_RESIDUAL_EXPERIMENT && __JVM_OS_IOS__)
// Fast checkpoint guard, no registry lock or repeated ancestry walk. The
// admitted Canvas holds paintLock until endAfkPaint; TLS serial changes on
// nested paint/end. All objects remain rooted in the original paint frames.
int treo_residual_scope_valid(Runtime *r,Instance *wrapper,const JarBoxResidualScope *s) {
    if(!r||!r->jvm||!r->jvm->session||!r->thrd_info||!s||!wrapper||
       (uintptr_t)wrapper!=s->wrapper||!s->serial||s->serial!=g_afk_scope_serial||
       !s->owner||s->owner!=g_afk_canvas_owner_key||s->context!=g_afk_canvas||
       r->thrd_info->is_stop||r->thrd_info->suspend_count||r->jvm->jdwp_enable||
       treo_game_jit_is_enabled()||!r->thrd_info->jarbox_headless_scope)return 0;
    JarBoxSession *session=r->jvm->session;
    JarBoxTreoState *st=&session->treo_state;
    if(jarbox_session_phase(session)!=JARBOX_SESSION_PARKED||
       !jarbox_ninja_core_active(&st->ninja_core,treo_runtime_mode(r))||
       s->owner!=jarbox_native_heap_key_for_runtime(r))return 0;
    // Recheck all mutable target/pixel-dependency fields after retained calls.
    // Layout offsets were certified once; no per-draw metadata scan.
    return jbr_scope_fields_valid(s,wrapper);
}
#endif
#endif

int treo_afk_elide_graphics(Runtime *runtime, JClass *clazz, Instance *receiver, int core) {
    const uint64_t caller_key = jarbox_native_heap_key_for_runtime(runtime);
    if (!caller_key || caller_key != g_afk_canvas_owner_key ||
        !g_afk_canvas || !receiver || receiver->mb.clazz != clazz)
        return 0;
    u64 layout = __atomic_load_n(&clazz->treo_afk_layout, __ATOMIC_RELAXED);
    if (!layout) {
        int ctx = treo_instance_offset(clazz, "nativeContext", "J", 8);
        int flag = treo_instance_offset(clazz, "headless", "Z", 1);
        if (ctx < 0 || flag < 0) return 0;
        layout = (1ULL << 32) | (u64)ctx | ((u64)flag << 16);
        __atomic_store_n(&clazz->treo_afk_layout, layout, __ATOMIC_RELAXED);
    }
    s64 ctx;
    memcpy(&ctx, receiver->obj_fields + (u16)layout, sizeof(ctx));
    if (ctx != g_afk_canvas) return 0;
    // Core uses the existing TLS Canvas scope, without changing the shared
    // Java Graphics.headless flag. Non-core modes keep their old guard.
    if (core) {
        JarBoxTreoState *state=treo_runtime_state(runtime);
        if (!state || !jarbox_ninja_core_active(&state->ninja_core,treo_runtime_mode(runtime))) return 0;
    } else if (!receiver->obj_fields[(u16)(layout >> 16)]) return 0;
    ++g_afk_elided_local;
    return 1;
}

static u64 treo_graphics_offsets(JClass *clazz, int image) {
    u64 cached = __atomic_load_n(&clazz->treo_graphics_layout, __ATOMIC_RELAXED);
    if (cached) return cached;
    int a = treo_instance_offset(clazz, image ? "nativeHandle" : "nativeContext", "J", 8);
    int x = image ? 0 : treo_instance_offset(clazz, "translateX", "I", 4);
    int y = image ? 0 : treo_instance_offset(clazz, "translateY", "I", 4);
    if (a < 0 || x < 0 || y < 0) return 0;
    cached = ((u64)(image ? 2 : 1) << 48) | (u64)a | ((u64)x << 16) | ((u64)y << 32);
    __atomic_store_n(&clazz->treo_graphics_layout, cached, __ATOMIC_RELAXED);
    return cached;
}

// The original Java bytecode stays available for the A/B baseline and any
// incompatible layout. Only replace the tiny bundled Graphics API wrapper.
int treo_try_graphics_draw_region(Runtime *runtime, JClass *clazz) {
    const int currentMode = treo_runtime_mode(runtime);
    const int fastCanvas = currentMode == TreoAFKFastCanvas;
    if (!fastCanvas && (!treo_software_enabled() || currentMode != 0)) return 0;
    LocalVarItem *locals = runtime->localvar;
    Instance *graphics = localvar_getRefer(locals, 0);
    Instance *image = localvar_getRefer(locals, 1);
    if (!image) return 1; // Graphics.drawRegion(null, ...) is a no-op.
    if (!graphics || graphics->mb.clazz != clazz || !image->mb.clazz) return 0;
    JClass *ic = image->mb.clazz;
    if (ic->jloader != clazz->jloader) return 0;
    u64 io = __atomic_load_n(&ic->treo_graphics_layout, __ATOMIC_RELAXED);
    if (!io) {
        if (!utf8_equals_c(ic->name, "javax/microedition/lcdui/Image")) return 0;
        io = treo_graphics_offsets(ic, 1);
    }
    if ((io >> 48) != 2) return 0;
    u64 go = treo_graphics_offsets(clazz, 0);
    if (!go || !io ||
        (g_afk_canvas &&
         g_afk_canvas_owner_key == jarbox_native_heap_key_for_runtime(runtime)))
        return 0;
    s64 ctx, img;
    s32 tx, ty;
    memcpy(&ctx, graphics->obj_fields + (u16)go, sizeof(ctx));
    memcpy(&tx, graphics->obj_fields + (u16)(go >> 16), sizeof(tx));
    memcpy(&ty, graphics->obj_fields + (u16)(go >> 32), sizeof(ty));
    memcpy(&img, image->obj_fields + (u16)io, sizeof(img));
    const TreoRegionArgs p = {ctx, img, localvar_getInt(locals, 2), localvar_getInt(locals, 3),
        localvar_getInt(locals, 4), localvar_getInt(locals, 5), localvar_getInt(locals, 6),
        (s32)((u32)localvar_getInt(locals, 7) + (u32)tx),
        (s32)((u32)localvar_getInt(locals, 8) + (u32)ty), localvar_getInt(locals, 9),
        jarbox_native_heap_key_for_runtime(runtime)};
    // The AFK shortcut stays on screen Canvas only; Image Graphics uses Java.
    if (fastCanvas) {
        RenderContext *target = rc_acquire(ctx, p.owner_key);
        int canvas = target && target->ownsPixels;
        rc_release(target);
        if (!canvas) return 0;
    }
    treo_profiled_region(&p, 1);
    return 1;
}

// --- drawRGB ---

static s32 n_drawRGB(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 ctxHandle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *arr = env->localvar_getRefer(runtime->localvar, 2);
    s32 offset = env->localvar_getInt(runtime->localvar, 3);
    s32 scanlength = env->localvar_getInt(runtime->localvar, 4);
    s32 x = env->localvar_getInt(runtime->localvar, 5);
    s32 y = env->localvar_getInt(runtime->localvar, 6);
    s32 w = env->localvar_getInt(runtime->localvar, 7);
    s32 h = env->localvar_getInt(runtime->localvar, 8);
    s32 processAlpha = env->localvar_getInt(runtime->localvar, 9);

    RenderContext *rc = rc_acquire(ctxHandle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (!rc || !arr || w <= 0 || h <= 0) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    s32 arrLen = arr->arr_length;
    s32 *srcData = (s32 *)arr->arr_body;
    CGColorSpaceRef cs = getColorSpace();
    CGContextRef tmpCtx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    if (!tmpCtx) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    uint8_t *dst = (uint8_t *)CGBitmapContextGetData(tmpCtx);
    for (int row = 0; row < h; row++) {
        for (int col = 0; col < w; col++) {
            int srcIdx = offset + row * scanlength + col;
            if (srcIdx < 0 || srcIdx >= arrLen) continue;
            s32 argb = srcData[srcIdx];
            int dstIdx = (row * w + col) * 4;
            uint8_t a = processAlpha ? ((argb >> 24) & 0xFF) : 0xFF;
            uint8_t r = (argb >> 16) & 0xFF;
            uint8_t g = (argb >> 8) & 0xFF;
            uint8_t b = argb & 0xFF;
            if (a < 255 && a > 0) {
                r = (uint8_t)(r * a / 255);
                g = (uint8_t)(g * a / 255);
                b = (uint8_t)(b * a / 255);
            } else if (a == 0) {
                r = g = b = 0;
            }
            dst[dstIdx + 0] = b;
            dst[dstIdx + 1] = g;
            dst[dstIdx + 2] = r;
            dst[dstIdx + 3] = a;
        }
    }

    CGImageRef img = CGBitmapContextCreateImage(tmpCtx);
    CGContextRelease(tmpCtx);

    if (img && treo_live_image(rc, img, x, y, 0, 0, w, h, 0, 0)) {
        CGImageRelease(img);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }
    if (img) {
        treo_live_barrier(rc);
        CGContextSaveGState(rc->ctx);
        CGContextTranslateCTM(rc->ctx, x, y + h);
        CGContextScaleCTM(rc->ctx, 1, -1);
        CGContextDrawImage(rc->ctx, CGRectMake(0, 0, w, h), img);
        CGContextRestoreGState(rc->ctx);
        CGImageRelease(img);
    }
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- getImageRGB ---

static int jarbox_image_rgb_range(int iw, int ih, int capacity, int offset,
                                  int scan, int x, int y, int w, int h) {
    if (iw < 0 || ih < 0 || capacity < 0 || x < 0 || y < 0 || w < 0 || h < 0 ||
        x > iw || y > ih || w > iw - x || h > ih - y) return 0;
    if (!w || !h) return 1;
    if ((int64_t)scan < w && -(int64_t)scan < w) return 0;
    int64_t last = (int64_t)offset + (int64_t)(h - 1) * scan;
    int64_t low = last < offset ? last : offset;
    int64_t high = last > offset ? last : offset;
    return low >= 0 && high + w <= capacity;
}

static s32 n_getImageRGB(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 imgHandle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *arr = env->localvar_getRefer(runtime->localvar, 2);
    s32 offset = env->localvar_getInt(runtime->localvar, 3);
    s32 scanlength = env->localvar_getInt(runtime->localvar, 4);
    s32 x = env->localvar_getInt(runtime->localvar, 5);
    s32 y = env->localvar_getInt(runtime->localvar, 6);
    s32 w = env->localvar_getInt(runtime->localvar, 7);
    s32 h = env->localvar_getInt(runtime->localvar, 8);

    RenderImage *img = img_acquire(imgHandle, jarbox_native_heap_key_for_runtime(runtime));
    if (!img || !arr || arr->mb.type != MEM_TYPE_ARR || arr->mb.arr_type_index != DATATYPE_INT ||
        !jarbox_image_rgb_range(img->width, img->height, arr->arr_length, offset, scanlength, x, y, w, h) ||
        !w || !h || !arr->arr_body) { img_release(img); return RUNTIME_STATUS_NORMAL; }

    s32 *dstData = (s32 *)arr->arr_body;
    const uint8_t *srcData = img->softwareSource ? (const uint8_t *)img->softwareSource :
                             img->ctx ? (const uint8_t *)CGBitmapContextGetData(img->ctx) : NULL;
    size_t stride = img->softwareSource ? img->softwareStride * 4u :
                    img->ctx ? CGBitmapContextGetBytesPerRow(img->ctx) : 0;
    if (!srcData || stride < (size_t)img->width * 4u) { img_release(img); return RUNTIME_STATUS_NORMAL; }

    for (int row = 0; row < h; row++) {
        for (int col = 0; col < w; col++) {
            size_t srcIdx = (size_t)(y + row) * stride + (size_t)(x + col) * 4u;
            uint8_t b = srcData[srcIdx + 0];
            uint8_t g = srcData[srcIdx + 1];
            uint8_t r = srcData[srcIdx + 2];
            uint8_t a = srcData[srcIdx + 3];
            s32 argb = (s32)(((uint32_t)a << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | b);
            dstData[(int64_t)offset + (int64_t)row * scanlength + col] = argb;
        }
    }
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

// --- fillPolygon / drawPolygon ---

static s32 n_fillPolygon(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *xArr = env->localvar_getRefer(runtime->localvar, 2);
    Instance *yArr = env->localvar_getRefer(runtime->localvar, 3);
    s32 nPoints = env->localvar_getInt(runtime->localvar, 4);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (!rc || !xArr || !yArr || nPoints < 3) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    s32 *xPts = (s32 *)xArr->arr_body;
    s32 *yPts = (s32 *)yArr->arr_body;
    if (treo_live_recording(rc) && nPoints <= 1024 &&
        nPoints <= xArr->arr_length && nPoints <= yArr->arr_length) {
        CGMutablePathRef path = CGPathCreateMutable();
        if (path) {
            CGPathMoveToPoint(path, NULL, xPts[0] + 0.0, yPts[0] + 0.0);
            for (int i = 1; i < nPoints; i++)
                CGPathAddLineToPoint(path, NULL, xPts[i] + 0.0, yPts[i] + 0.0);
            CGPathCloseSubpath(path);
            // Capture an owning ARC reference, never a pointer into Java's heap.
            id ownedPath = (__bridge_transfer id)path;
            int recorded = treo_live_shape(rc, CGRectInset(CGPathGetPathBoundingBox(path), -6, -6),
                ^(CGContextRef target) {
                    CGContextBeginPath(target);
                    CGContextAddPath(target, (__bridge CGPathRef)ownedPath);
                    CGContextFillPath(target);
                });
            if (recorded) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
        }
    }
    treo_live_barrier(rc);
    CGContextBeginPath(rc->ctx);
    CGContextMoveToPoint(rc->ctx, xPts[0], yPts[0]);
    for (int i = 1; i < nPoints; i++) {
        CGContextAddLineToPoint(rc->ctx, xPts[i], yPts[i]);
    }
    CGContextClosePath(rc->ctx);
    CGContextFillPath(rc->ctx);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_drawPolygon(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    Instance *xArr = env->localvar_getRefer(runtime->localvar, 2);
    Instance *yArr = env->localvar_getRefer(runtime->localvar, 3);
    s32 nPoints = env->localvar_getInt(runtime->localvar, 4);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (!rc || !xArr || !yArr || nPoints < 3) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    s32 *xPts = (s32 *)xArr->arr_body;
    s32 *yPts = (s32 *)yArr->arr_body;
    if (treo_live_recording(rc) && nPoints <= 1024 &&
        nPoints <= xArr->arr_length && nPoints <= yArr->arr_length) {
        CGMutablePathRef path = CGPathCreateMutable();
        if (path) {
            CGPathMoveToPoint(path, NULL, xPts[0] + 0.5, yPts[0] + 0.5);
            for (int i = 1; i < nPoints; i++)
                CGPathAddLineToPoint(path, NULL, xPts[i] + 0.5, yPts[i] + 0.5);
            CGPathCloseSubpath(path);
            // Capture an owning ARC reference, never a pointer into Java's heap.
            id ownedPath = (__bridge_transfer id)path;
            int recorded = treo_live_shape(rc, CGRectInset(CGPathGetPathBoundingBox(path), -6, -6),
                ^(CGContextRef target) {
                    CGContextBeginPath(target);
                    CGContextAddPath(target, (__bridge CGPathRef)ownedPath);
                    CGContextStrokePath(target);
                });
            if (recorded) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
        }
    }
    treo_live_barrier(rc);
    CGContextBeginPath(rc->ctx);
    CGContextMoveToPoint(rc->ctx, xPts[0] + 0.5, yPts[0] + 0.5);
    for (int i = 1; i < nPoints; i++) {
        CGContextAddLineToPoint(rc->ctx, xPts[i] + 0.5, yPts[i] + 0.5);
    }
    CGContextClosePath(rc->ctx);
    CGContextStrokePath(rc->ctx);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// --- copyArea ---

static s32 n_copyArea(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s32 xSrc = env->localvar_getInt(runtime->localvar, 2);
    s32 ySrc = env->localvar_getInt(runtime->localvar, 3);
    s32 w = env->localvar_getInt(runtime->localvar, 4);
    s32 h = env->localvar_getInt(runtime->localvar, 5);
    s32 xDst = env->localvar_getInt(runtime->localvar, 6);
    s32 yDst = env->localvar_getInt(runtime->localvar, 7);
    RenderContext *rc = rc_acquire(handle, jarbox_native_heap_key_for_runtime(runtime));
    if (rc && treo_runtime_mode(runtime)!=1 && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    if (!rc || w <= 0 || h <= 0) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    treo_live_barrier(rc);
    CGImageRef fullImg = treo_canvas_snapshot(rc);
    if (!fullImg) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    CGImageRef subImg = CGImageCreateWithImageInRect(fullImg, CGRectMake(xSrc, ySrc, w, h));
    CGImageRelease(fullImg);
    if (!subImg) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    CGContextSaveGState(rc->ctx);
    CGContextTranslateCTM(rc->ctx, xDst, yDst + h);
    CGContextScaleCTM(rc->ctx, 1, -1);
    CGContextDrawImage(rc->ctx, CGRectMake(0, 0, w, h), subImg);
    CGContextRestoreGState(rc->ctx);
    CGImageRelease(subImg);
    rc_release(rc);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Native method table
// ============================================================
// Haptics
// ============================================================

static CHHapticEngine *g_hapticEngine API_AVAILABLE(ios(13.0)) = nil;
static id<CHHapticPatternPlayer> g_hapticPlayer API_AVAILABLE(ios(13.0)) = nil;

static void ensureHapticEngine(void) API_AVAILABLE(ios(13.0)) {
    if (g_hapticEngine) return;
    NSError *err = nil;
    g_hapticEngine = [[CHHapticEngine alloc] initAndReturnError:&err];
    if (err) {
        printf("[Haptics] Engine init error: %s\n", err.localizedDescription.UTF8String);
        g_hapticEngine = nil;
        return;
    }
    // CoreHaptics invokes resetHandler on its own queue. Never resolve a
    // replacement global engine there or retain an old engine through its block.
    __weak CHHapticEngine *resetEngine = g_hapticEngine;
    g_hapticEngine.resetHandler = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            CHHapticEngine *engine = resetEngine;
            if (!engine || engine != g_hapticEngine) return;
            NSError *startErr = nil;
            [engine startAndReturnError:&startErr];
        });
    };
    [g_hapticEngine startAndReturnError:&err];
    if (err) {
        printf("[Haptics] Engine start error: %s\n", err.localizedDescription.UTF8String);
        g_hapticEngine = nil;
    }
}

// Called by the AFK toggle on UIKit's main thread.
static void stop_afk_haptics(void) {
    if (@available(iOS 13.0, *)) {
        if (g_hapticPlayer) {
            [g_hapticPlayer stopAtTime:0 error:nil];
            g_hapticPlayer = nil;
        }
        atomic_store_explicit(&g_haptic_player_owner_key, 0, memory_order_release);
    }
}

static void render_haptic_release_owner(uint64_t owner_key) {
    if (!owner_key) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (atomic_load_explicit(&g_haptic_player_owner_key, memory_order_acquire) ==
            owner_key) stop_afk_haptics();
    });
}

// Main-queue haptics never authorize a request using the process-wide
// AFK compatibility mirror. Re-read the exact running owner's Treo mode
// through a pinned token visitor; do not retain Runtime or MiniJVM here.
static int render_haptic_can_deliver(uint64_t owner_key, uint64_t token) {
    if (!owner_key || !token || token != jvm_bridge_visible_session_token()) return 0;
    if (treo_mode_for_token(token) != 0) return 0;
    // Focus may have changed during the visitor. Check both identities again.
    return owner_key == j2me_render_visible_owner_key() &&
           token == jvm_bridge_visible_session_token();
}

static s32 n_vibrate(Runtime *runtime, JClass *clazz) {
    const uint64_t owner_key = jarbox_native_heap_key_for_runtime(runtime);
    if (!owner_key || owner_key != j2me_render_visible_owner_key() ||
        treo_runtime_mode(runtime) != 0) return RUNTIME_STATUS_NORMAL;
    const uint64_t token = runtime->jvm->session ?
        __atomic_load_n(&runtime->jvm->session->token, __ATOMIC_ACQUIRE) : 0;
    if (!token) return RUNTIME_STATUS_NORMAL;
    s32 durationMs = runtime->jnienv->localvar_getInt(runtime->localvar, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        // An old Tab must never vibrate or stop a new Tab's player.
        if (owner_key != j2me_render_visible_owner_key()) return;
        if (!render_haptic_can_deliver(owner_key, token)) return;
        if (@available(iOS 13.0, *)) {
            if (g_hapticPlayer) {
                NSError *err = nil;
                [g_hapticPlayer stopAtTime:0 error:&err];
                g_hapticPlayer = nil;
                atomic_store_explicit(&g_haptic_player_owner_key, 0, memory_order_release);
            }
            if (durationMs <= 0) return;

            ensureHapticEngine();
            if (!g_hapticEngine) return;

            float duration = durationMs / 1000.0f;
            CHHapticEventParameter *intensity =
                [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity
                                                              value:0.35f];
            CHHapticEventParameter *sharpness =
                [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticSharpness
                                                              value:0.1f];
            CHHapticEvent *event =
                [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous
                                             parameters:@[intensity, sharpness]
                                           relativeTime:0
                                               duration:duration];
            NSError *err = nil;
            CHHapticPattern *pattern =
                [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
            if (err) return;

            g_hapticPlayer = [g_hapticEngine createPlayerWithPattern:pattern error:&err];
            if (err || !g_hapticPlayer) return;
            // Pattern/player creation can take time. Reject a retired or
            // parked owner before actually starting the hardware player.
            if (!render_haptic_can_deliver(owner_key, token)) {
                g_hapticPlayer = nil;
                return;
            }
            atomic_store_explicit(&g_haptic_player_owner_key, owner_key, memory_order_release);

            [g_hapticPlayer startAtTime:0 error:&err];
        }
    });
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_render_methods[] = {
    {CLS, "jarSparsePaintDue", "()Z", n_jarSparsePaintDue},
    {CLS, "profilePaintBegin", "()J", n_profilePaintBegin},
    {CLS, "profilePaintEnd", "(J)V", n_profilePaintEnd},
    {CLS, "afkSuspended",     "()Z", n_afkSuspended},
    {CLS, "takeAfkRefresh",   "()I", n_takeAfkRefresh},
    {CLS, "afkPaintPolicy", "()I", n_afkPaintPolicy},
    {CLS, "ninjaDeepActive", "()Z", n_ninjaDeepActive},
    {CLS, "ninjaDeepSkip", "(Ljava/lang/Object;I)Z", n_ninjaDeepSkip},
    {CLS, "ninjaCorePaint", "(Ljava/lang/Object;)Z", n_ninjaCorePaint},
    {CLS, "ninjaCorePaintResult", "(I)V", n_ninjaCorePaintResult},
    {CLS, "afkImageCacheEnabled", "()Z", n_afkImageCacheEnabled},
    {CLS, "imageCacheNote", "(II)V", n_imageCacheNote},
    {CLS, "afkCanvasResult", "(I)V", n_afkCanvasResult},
    {CLS, "afkBypassPaint", "()Z", n_afkBypassPaint},
    {CLS, "beginAfkPaint", "(JZ)J", n_beginAfkPaint},
    {CLS, "endAfkPaint", "(J)V", n_endAfkPaint},
    // Context
    {CLS, "createContext",    "(II)J",                                   n_createContext},
    {CLS, "destroyContext",   "(J)V",                                    n_destroyContext},
    {CLS, "flushToScreen",    "(J)V",                                    n_flushToScreen},
    {CLS, "afkBufferBlitBegin", "(IIZ)J",                                n_afkBufferBlitBegin},
    {CLS, "afkBufferBlitEnd",   "(J)V",                                  n_afkBufferBlitEnd},

    // Color & State
    {CLS, "setColor",         "(JI)V",                                   n_setColor},
    {CLS, "setClip",          "(JIIII)V",                                n_setClip},
    {CLS, "setStrokeStyle",   "(JI)V",                                   n_setStrokeStyle},

    // Drawing
    {CLS, "drawLine",         "(JIIII)V",                                n_drawLine},
    {CLS, "fillRect",         "(JIIII)V",                                n_fillRect},
    {CLS, "drawRect",         "(JIIII)V",                                n_drawRect},
    {CLS, "fillArc",          "(JIIIIII)V",                              n_fillArc},
    {CLS, "drawArc",          "(JIIIIII)V",                              n_drawArc},
    {CLS, "fillRoundRect",    "(JIIIIII)V",                              n_fillRoundRect},
    {CLS, "drawRoundRect",    "(JIIIIII)V",                              n_drawRoundRect},

    // Text
    {CLS, "setFont",          "(JIII)V",                                 n_setFont},
    {CLS, "drawString",       "(JLjava/lang/String;III)V",               n_drawString},
    {CLS, "getStringWidth",   "(JLjava/lang/String;)I",                  n_getStringWidth},
    {CLS, "getFontHeight",    "(J)I",                                    n_getFontHeight},
    {CLS, "getFontAscent",    "(J)I",                                    n_getFontAscent},

    // Image
    {CLS, "createMutableImage",  "(II)J",                                n_createMutableImage},
    {CLS, "createImageFromData", "([BII)J",                              n_createImageFromData},
    {CLS, "destroyImage",        "(J)V",                                 n_destroyImage},
    {CLS, "getImageWidth",       "(J)I",                                 n_getImageWidth},
    {CLS, "getImageHeight",      "(J)I",                                 n_getImageHeight},
    {CLS, "getImageContext",     "(J)J",                                 n_getImageContext},
    {CLS, "drawImage",           "(JJIII)V",                             n_drawImage},
    {CLS, "drawRegion",          "(JJIIIIIIII)V",                        n_profiledDrawRegion},
    {CLS, "drawRGB",             "(J[IIIIIIII)V",                        n_drawRGB},
    {CLS, "getImageRGB",         "(J[IIIIIII)V",                         n_getImageRGB},
    {CLS, "fillPolygon",         "(J[I[II)V",                            n_fillPolygon},
    {CLS, "drawPolygon",         "(J[I[II)V",                            n_drawPolygon},
    {CLS, "copyArea",            "(JIIIIII)V",                           n_copyArea},

    // Haptics
    {CLS, "vibrate",             "(I)V",                                 n_vibrate},
};

#undef CLS

void j2me_render_reg_natives(MiniJVM *jvm) {
    // Preserve the existing one-game behavior while refusing unowned VMs.
    if (atomic_load_explicit(&g_visible_render_owner_key,
                             memory_order_acquire) == 0)
        (void)j2me_render_focus_vm(jvm);
    const uint64_t owner_key = jarbox_native_heap_key_for_vm(jvm);
    if (!jarbox_flush_route_bind(&g_flush_routes, owner_key))
        fprintf(stderr, "[J2ME Render] no owned frame callback for JVM generation %llu\n",
                (unsigned long long)owner_key);
    native_reg_lib(jvm, j2me_render_methods,
                   sizeof(j2me_render_methods) / sizeof(java_native_method));
    printf("[J2ME Render] Registered %lu native methods\n",
           sizeof(j2me_render_methods) / sizeof(java_native_method));
}

void j2me_render_stop_for_owner(uint64_t owner_key) {
    if (!owner_key) return;
    // Revoke frame delivery before unhooking this generation's 2D handles.
    // B's route is untouched, including during an A/B focus transition.
    (void)jarbox_flush_route_unbind(&g_flush_routes, owner_key);
    spin_lock(&g_track_lock);
    if (!render_owner_stopped_locked(owner_key)) {
        if (g_stopped_render_owner_count < RENDER_STOP_OWNER_SLOTS)
            g_stopped_render_owners[g_stopped_render_owner_count++] = owner_key;
        else
            g_render_stop_registry_overflow = 1;
    }
    // The stop registry covers the full native heap owner capacity. Overflow should
    // be unreachable; should it occur, block every new render acquire.
    spin_unlock(&g_track_lock);
}

// Ownership is by native JVM generation. Never free a foreign VM's context.
// Release outside g_track_lock: cache disposal can re-enter untrack_img().
static RenderContext *take_rc_for_owner(uint64_t key) {
    RenderContext *found = NULL;
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_rc_count; ++i) {
        if (g_live_rc[i]->heap_key == key) {
            found = g_live_rc[i];
            g_live_rc[i] = g_live_rc[--g_live_rc_count];
            unsigned bucket = render_handle_bucket((s64)(intptr_t)found);
            RenderContext **cursor = &g_rc_live_buckets[bucket];
            while (*cursor && *cursor != found) cursor = &(*cursor)->next_live;
            if (*cursor) *cursor = found->next_live;
            found->next_live = NULL;
            break;
        }
    }
    spin_unlock(&g_track_lock);
    return found;
}
static RenderImage *take_img_for_owner(uint64_t key) {
    RenderImage *found = NULL;
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_img_count; ++i) {
        if (g_live_img[i]->heap_key == key) {
            found = g_live_img[i];
            g_live_img[i] = g_live_img[--g_live_img_count];
            unsigned bucket = render_handle_bucket((s64)(intptr_t)found);
            RenderImage **cursor = &g_img_live_buckets[bucket];
            while (*cursor && *cursor != found) cursor = &(*cursor)->next_live;
            if (*cursor) *cursor = found->next_live;
            found->next_live = NULL;
            break;
        }
    }
    spin_unlock(&g_track_lock);
    return found;
}

void j2me_render_cleanup_for_owner(uint64_t owner_key) {
    // Capture the ledger key before jvm_destroy, even if JVM address is reused.
    if (!owner_key) {
        fprintf(stderr, "[J2ME Render] Reject cleanup with missing owner key\n");
        return;
    }
    // The bridge calls this only after the owning JVM's workers drain.
    // Do not advance any other generation's dead-shell grace period.
    process_dead_shells_for_owner(owner_key);

    int rc_count = 0, img_count = 0;
    RenderContext *rc;
    while ((rc = take_rc_for_owner(owner_key)) != NULL) {
        ++rc_count;
        treo_live_discard(rc);
        if (rc->ctx) { CGContextRelease(rc->ctx); rc->ctx = NULL; }
        free(rc->softwarePixels);
        rc->softwarePixels = NULL;
        CTFontRef font = rc->font;
        rc->font = NULL;
        if (font) CFRelease(font);
        if (rc->ownsPixels && rc->width > 0 && rc->height > 0)
            native_heap_sub(owner_key, rc->width * rc->height * 4);
        free(rc);
    }
    // Cache disposal above may release tracked RenderImages, so scan anew.
    RenderImage *img;
    while ((img = take_img_for_owner(owner_key)) != NULL) {
        ++img_count;
        if (img->immutableSnapshot) CGImageRelease(img->immutableSnapshot);
        if (img->immutablePixels) CFRelease(img->immutablePixels);
        if (img->ctx) { CGContextRelease(img->ctx); img->ctx = NULL; }
        if (img->width > 0 && img->height > 0)
            native_heap_sub(owner_key, img->width * img->height * 4);
        free(img);
    }
    // No Metal texture or framebuffer target of owner A may remain cached
    // after A's native context teardown; B's targets remain intact.
    treo_live_release_owner(owner_key);
    // Owner-local cache disposal above can enqueue additional dead shells.
    // Reclaim them even when the other tab is parked and produces no frames.
    process_dead_shells_for_owner(owner_key);

    // The CHHapticEngine and player are main-queue UI resources. Cleanup must
    // not touch them from the JVM teardown worker or stop a newly focused VM.
    // Keep process-wide haptic engine teardown only for the one-JVM runtime.
    if (jvm_bridge_supported_concurrent_sessions() == 1) {
        const uint64_t teardown_key = owner_key;
        dispatch_async(dispatch_get_main_queue(), ^{
            // A new Tab may have focused between teardown and this block.
            if (j2me_render_visible_owner_key() != 0) return;
            const uint64_t haptic_owner = atomic_load_explicit(
                &g_haptic_player_owner_key, memory_order_acquire);
            if (haptic_owner != 0 && haptic_owner != teardown_key) return;
            if (@available(iOS 13.0, *)) {
                stop_afk_haptics();
                if (g_hapticEngine) {
                    // A reset already queued on the main queue will reject
                    // this retired engine even if a new one is installed.
                    g_hapticEngine.resetHandler = nil;
                    [g_hapticEngine stopWithCompletionHandler:nil];
                    g_hapticEngine = nil;
                }
            }
        });
    }
    // Retire only the owner whose resources have just been reclaimed.
    // Other render generations remain enabled and their bucket chains remain.
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_stopped_render_owner_count; ++i) {
        if (g_stopped_render_owners[i] == owner_key) {
            g_stopped_render_owners[i] =
                g_stopped_render_owners[--g_stopped_render_owner_count];
            break;
        }
    }
    spin_unlock(&g_track_lock);
    printf("[J2ME Render] Owner %llu cleanup: %d contexts, %d images\n",
           (unsigned long long)owner_key, rc_count, img_count);
}

// Unscoped cleanup must not guess an owner from the foreground Tab.
void j2me_render_cleanup(void) {
    fprintf(stderr, "[J2ME Render] Reject unscoped cleanup; owner key required\n");
}
