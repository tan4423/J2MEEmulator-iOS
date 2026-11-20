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
#include "j2me_input.h"
#include "jvm.h"
#include "jvm_util.h"
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
    float fontSize;
    int fontStyle;
    int clipSaved;
    int ownsPixels;
    CGRect regionClipBounds;
    TreoLiveRun *liveRun;
    TreoCPUCache *cpuCache;
    uint32_t *softwarePixels;
    uint64_t swRegions, swFast, swChecked, swMismatch, swDirect;
    unsigned swSequence;
    unsigned fastFillSequence;
    bool fastFillRejected;
    bool fastFontValid;
    s32 fastFontFace, fastFontStyle, fastFontSize;
    uint64_t fastFills, fastFillChecks, fastFillMismatch, fastState;
    uint32_t liveColor, liveSavedColor;
    int liveStroke, liveSavedStroke;
    CGRect liveRawClip;
    int liveBlocked;
    _Atomic int32_t refcount;
    struct RenderContext *next_dead;
} RenderContext;

typedef struct RenderImage {
    CGContextRef ctx;
    CGImageRef immutableSnapshot;
    int width;
    int height;
    int isMutable;
    const uint32_t *softwareSource;
    size_t softwareStride;
    atomic_uint softwareVerified, softwareRejected;
    _Atomic int32_t refcount;
    struct RenderImage *next_dead;
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
static j2me_flush_callback g_flush_callback = NULL;
_Atomic int treo_afk_mode = 0;
static _Atomic uint64_t treo_afk_bypass_deadline, treo_afk_bypassed, treo_afk_next_paint;
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
    const int mode = atomic_load_explicit(&treo_afk_mode, memory_order_acquire);
    if (mode == 6 || mode == 7) {
        uint64_t now = treo_afk_now_ns();
        bypass = now && now < atomic_load_explicit(&treo_afk_bypass_deadline, memory_order_relaxed);
        if (bypass && mode == 7) {
            uint64_t next = atomic_load_explicit(&treo_afk_next_paint, memory_order_relaxed);
            // One genuine paint every >=200ms, across both possible caller threads.
            while (now >= next) {
                if (atomic_compare_exchange_weak_explicit(&treo_afk_next_paint, &next,
                        now + 200000000ULL, memory_order_relaxed, memory_order_relaxed)) {
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
static atomic_int g_afk_refresh = 0;
static atomic_bool g_afk_needs_redraw;
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
uint64_t treo_afk_guarded_paints(void) { return atomic_load_explicit(&treo_guarded_paints, memory_order_relaxed); }
uint64_t treo_afk_guarded_real(void) { return atomic_load_explicit(&treo_guarded_real, memory_order_relaxed); }
uint64_t treo_afk_guarded_late(void) { return atomic_load_explicit(&treo_guarded_late, memory_order_relaxed); }
uint64_t treo_afk_layer_frames(void) { return atomic_load_explicit(&treo_layer_frames, memory_order_relaxed); }

static s32 n_afkPaintPolicy(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, atomic_load_explicit(&treo_afk_mode, memory_order_acquire));
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_afkCanvasResult(Runtime *runtime, JClass *clazz) {
    const int outcome = runtime->jnienv->localvar_getInt(runtime->localvar, 0);
    atomic_fetch_add_explicit(outcome ? &treo_guarded_paints : &treo_guarded_real, 1, memory_order_relaxed);
    if (outcome == 2) atomic_fetch_add_explicit(&treo_guarded_late, 1, memory_order_relaxed);
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
static _Thread_local s64 g_afk_canvas;
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
uint64_t treo_afk_skipped_draws(void) { return atomic_load_explicit(&g_afk_skipped_draws, memory_order_relaxed); }
uint64_t treo_afk_skipped_paints(void) { return atomic_load_explicit(&g_afk_skipped_paints, memory_order_relaxed); }

static int treo_afk_skip_draw(RenderContext *rc) {
    if (!g_afk_canvas || g_afk_canvas != (s64)(intptr_t)rc) return 0;
    g_afk_draw_count++;
    return 1;
}

static s32 n_beginAfkPaint(Runtime *runtime, JClass *clazz) {
    s64 previous = g_afk_canvas;
    const int headless = runtime->jnienv->localvar_getInt(runtime->localvar, 2);
    if (headless || atomic_load_explicit(&treo_afk_mode, memory_order_acquire) == 2) {
        s64 canvas = runtime->jnienv->localvar_getLong_2slot(runtime->localvar, 0);
        if (canvas) {
            g_afk_canvas = canvas;
            atomic_fetch_add_explicit(&g_afk_skipped_paints, 1, memory_order_relaxed);
        }
    }
    runtime->jnienv->push_long(runtime->stack, previous);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_endAfkPaint(Runtime *runtime, JClass *clazz) {
    g_afk_canvas = runtime->jnienv->localvar_getLong_2slot(runtime->localvar, 0);
    if (!g_afk_canvas && g_afk_elided_local) {
        atomic_fetch_add_explicit(&g_afk_elided, g_afk_elided_local, memory_order_relaxed);
        g_afk_elided_local = 0;
    }
    if (!g_afk_canvas && g_afk_draw_count) {
        atomic_fetch_add_explicit(&g_afk_skipped_draws, g_afk_draw_count, memory_order_relaxed);
        g_afk_draw_count = 0;
    }
    return RUNTIME_STATUS_NORMAL;
}
static void stop_afk_haptics(void);

int j2me_render_is_afk_suspended(void) {
    return atomic_load_explicit(&treo_afk_mode, memory_order_relaxed) != 0;
}

void treo_render_set_afk_mode(int mode) {
    if (mode == 6 || mode == 7) {
        const uint64_t now = treo_afk_now_ns();
        atomic_store_explicit(&treo_afk_next_paint, 0, memory_order_relaxed);
        // Mode 7 is a bounded experiment; fail open if the UI timer stalls.
        atomic_store_explicit(&treo_afk_bypass_deadline,
                              now ? now + (mode == 7 ? 65000000000ULL : 60000000000ULL) : 0,
                              memory_order_relaxed);
    }
    if ((mode >= 2 && mode <= 4) || mode == 6 || mode == 7 || mode == 8)
        atomic_store(&g_afk_needs_redraw, 1);
    int previous = atomic_exchange(&treo_afk_mode, mode);
    if (mode) {
        atomic_store(&g_afk_refresh, 0);
        if (!previous) stop_afk_haptics();
    } else if (previous) {
        atomic_store(&g_afk_refresh, atomic_exchange(&g_afk_needs_redraw, 0) ? 2 : 1);
    }
    j2me_display_wake();
}
void j2me_render_set_afk_suspended(int enabled) { treo_render_set_afk_mode(enabled ? 1 : 0); }

static s32 n_afkSuspended(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, j2me_render_is_afk_suspended());
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_takeAfkRefresh(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, atomic_load(&g_afk_refresh) ? atomic_exchange(&g_afk_refresh, 0) : 0);
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
int treo_direct_graphics_enabled(void) {
    return treo_afk_fast_canvas() || atomic_load_explicit(&treo_direct_graphics_on, memory_order_relaxed);
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

static void treo_afk_trace_begin(bool stack, bool sourceOnly) {
    treo_afk_main_trace_cancel();
#if defined(__arm64__)
    if (!treo_trace_queue) treo_trace_queue = dispatch_queue_create("treo.afk.main.trace", DISPATCH_QUEUE_SERIAL);
    treo_trace_thread = mach_thread_self();
    treo_trace_count = treo_trace_ticks = treo_trace_errors = treo_trace_chains = treo_trace_unstable = 0;
    treo_trace_has_stack = stack;
    treo_trace_source_only = sourceOnly;
    treo_trace_source_checks = treo_trace_source_changed = 0;
    treo_trace_snapshot_mode = sourceOnly || (stack && atomic_load_explicit(&treo_jar_auditing, memory_order_relaxed));
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
void treo_afk_main_trace_begin(void) { treo_afk_trace_begin(false, false); }
void treo_afk_main_stack_begin(void) { treo_afk_trace_begin(true, false); }
void treo_afk_main_source_trace_begin(void) { treo_afk_trace_begin(true, true); }

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
    unsigned deep = 0, maxDepth = 0, caSamples = 0;
    for (unsigned i = 0; i < treo_trace_count; ++i) {
        NSNumber *pc = @(treo_trace_points[i].pc), *lr = @(treo_trace_points[i].lr);
        NSString *leaf = symbols[pc];
        if (!leaf) { leaf = treo_trace_symbol(treo_trace_points[i].pc); symbols[pc] = leaf; }
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
static s32 n_profilePaintBegin(Runtime *runtime, JClass *clazz) {
    s64 start = 0;
    if (j2me_render_is_afk_suspended() || treo_jar_audit_enabled()) {
        if (!g_afk_thread_id) pthread_threadid_np(NULL, &g_afk_thread_id);
        atomic_store_explicit(&g_afk_paint_tid, g_afk_thread_id, memory_order_relaxed);
        start = -(s64)treo_thread_cpu_ns();
    }
    else if (treo_profile_active()) start = (s64)treo_thread_cpu_ns();
    runtime->jnienv->push_long(runtime->stack, start);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_profilePaintEnd(Runtime *runtime, JClass *clazz) {
    const s64 stamp = runtime->jnienv->localvar_getLong_2slot(runtime->localvar, 0);
    if (stamp < 0) {
        const uint64_t end = treo_thread_cpu_ns(), begin = (uint64_t)(-stamp);
        if (end >= begin) {
            atomic_fetch_add_explicit(&g_afk_paint_cpu_ns, end - begin, memory_order_relaxed);
            atomic_fetch_add_explicit(&g_afk_paint_count, 1, memory_order_relaxed);
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

// Set by jvm_bridge before native cleanup. All acquire functions
// check this and return NULL, so zombie threads can't touch freed resources.
static volatile int g_render_stopped = 0;

// Global tracking arrays for forced cleanup between game sessions.
// Protected by g_track_lock. Entries are added on create, removed on release (refcount→0).
#define TRACK_MAX 8192
static RenderContext *g_live_rc[TRACK_MAX];
static int            g_live_rc_count = 0;
static RenderImage   *g_live_img[TRACK_MAX];
static int            g_live_img_count = 0;
static spinlock_t     g_track_lock = {0, 0, 0};

static void track_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);
    if (g_live_rc_count < TRACK_MAX) g_live_rc[g_live_rc_count++] = rc;
    spin_unlock(&g_track_lock);
}
static void untrack_rc(RenderContext *rc) {
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_rc_count; i++) {
        if (g_live_rc[i] == rc) {
            g_live_rc[i] = g_live_rc[--g_live_rc_count];
            break;
        }
    }
    spin_unlock(&g_track_lock);
}
static void track_img(RenderImage *img) {
    spin_lock(&g_track_lock);
    if (g_live_img_count < TRACK_MAX) g_live_img[g_live_img_count++] = img;
    spin_unlock(&g_track_lock);
}
static void untrack_img(RenderImage *img) {
    spin_lock(&g_track_lock);
    for (int i = 0; i < g_live_img_count; i++) {
        if (g_live_img[i] == img) {
            g_live_img[i] = g_live_img[--g_live_img_count];
            break;
        }
    }
    spin_unlock(&g_track_lock);
}

// ============================================================
// Native memory counter — visible to miniJVM GC via gc_sum_heap()
// ============================================================
extern s64 g_native_extra_heap;

static inline void native_heap_add(s32 bytes) {
    __atomic_fetch_add(&g_native_extra_heap, (s64)bytes, __ATOMIC_RELAXED);
}
static inline void native_heap_sub(s32 bytes) {
    __atomic_fetch_sub(&g_native_extra_heap, (s64)bytes, __ATOMIC_RELAXED);
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

// ============================================================
// Reference counting: acquire / release
// ============================================================

static inline RenderContext *rc_acquire(s64 handle) {
    if (g_render_stopped || handle == 0) return NULL;
    RenderContext *rc = (RenderContext *)(intptr_t)handle;
    int32_t old = atomic_load_explicit(&rc->refcount, memory_order_relaxed);
    do {
        if (old <= 0) return NULL;
    } while (!atomic_compare_exchange_weak_explicit(
        &rc->refcount, &old, old + 1,
        memory_order_acquire, memory_order_relaxed));
    return rc;
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
        if (pixels > 0) native_heap_sub(pixels);
        enqueue_dead_rc(rc);
    }
}

static inline RenderImage *img_acquire(s64 handle) {
    if (g_render_stopped || handle == 0) return NULL;
    RenderImage *img = (RenderImage *)(intptr_t)handle;
    int32_t old = atomic_load_explicit(&img->refcount, memory_order_relaxed);
    do {
        if (old <= 0) return NULL;
    } while (!atomic_compare_exchange_weak_explicit(
        &img->refcount, &old, old + 1,
        memory_order_acquire, memory_order_relaxed));
    return img;
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
        if (ctx) CGContextRelease(ctx);
        if (pixels > 0) native_heap_sub(pixels);
        enqueue_dead_img(img);
    }
}

// ============================================================

static CGColorSpaceRef getColorSpace(void) {
    if (!g_colorSpace) {
        g_colorSpace = CGColorSpaceCreateDeviceRGB();
    }
    return g_colorSpace;
}

void j2me_render_set_flush_callback(j2me_flush_callback callback) {
    g_flush_callback = callback;
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

static RenderContext *createRenderContext(int width, int height) {
    if (width <= 0 || height <= 0 || (uint64_t)width * height > INT32_MAX / 4) return NULL;
    RenderContext *rc = (RenderContext *)calloc(1, sizeof(RenderContext));
    if (!rc) return NULL;
    atomic_init(&rc->refcount, 1);
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

    track_rc(rc);
    native_heap_add(width * height * 4);
    return rc;
}

static void destroyRenderContext(RenderContext *rc) {
    if (!rc) return;
    rc_release(rc);
}

// ============================================================
// Image management
// ============================================================

static RenderImage *createMutableImage(int width, int height) {
    RenderImage *img = (RenderImage *)calloc(1, sizeof(RenderImage));
    atomic_init(&img->refcount, 1);
    img->width = width;
    img->height = height;
    img->isMutable = 1;

    CGColorSpaceRef cs = getColorSpace();
    img->ctx = CGBitmapContextCreate(NULL, width, height, 8, width * 4,
                                      cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextClearRect(img->ctx, CGRectMake(0, 0, width, height));
    CGContextTranslateCTM(img->ctx, 0, height);
    CGContextScaleCTM(img->ctx, 1.0, -1.0);

    track_img(img);
    native_heap_add(width * height * 4);
    return img;
}

static RenderImage *createImageFromData(const uint8_t *data, int length) {
    RenderImage *img = (RenderImage *)calloc(1, sizeof(RenderImage));
    atomic_init(&img->refcount, 1);
    img->isMutable = 0;

    CFDataRef cfData = CFDataCreate(NULL, data, length);
    CGImageSourceRef source = CGImageSourceCreateWithData(cfData, NULL);
    CFRelease(cfData);

    CGImageRef cgImage = NULL;
    if (source) {
        cgImage = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
    }

    if (!cgImage) {
        free(img);
        return NULL;
    }

    img->width = (int)CGImageGetWidth(cgImage);
    img->height = (int)CGImageGetHeight(cgImage);

    CGColorSpaceRef cs = getColorSpace();
    img->ctx = CGBitmapContextCreate(NULL, img->width, img->height, 8, img->width * 4,
                                      cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextClearRect(img->ctx, CGRectMake(0, 0, img->width, img->height));
    CGContextDrawImage(img->ctx, CGRectMake(0, 0, img->width, img->height), cgImage);
    CGImageRelease(cgImage);

    // Decoded images cannot be drawing targets. Reuse the same normalized
    // bitmap snapshot for every draw; publish it before handing out the handle.
    img->immutableSnapshot = CGBitmapContextCreateImage(img->ctx);
    img->softwareSource = CGBitmapContextGetData(img->ctx);
    img->softwareStride = CGBitmapContextGetBytesPerRow(img->ctx) / 4;
    atomic_init(&img->softwareVerified, 0);
    atomic_init(&img->softwareRejected, 0);

    track_img(img);
    native_heap_add(img->width * img->height * 4);
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
    RenderContext *rc = createRenderContext(w, h);
    env->push_long(runtime->stack, (s64)(intptr_t)rc);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyContext(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (g_render_stopped || handle == 0) return RUNTIME_STATUS_NORMAL;
    destroyRenderContext((RenderContext *)(intptr_t)handle);
    return RUNTIME_STATUS_NORMAL;
}

CGImageRef j2me_render_copy_image(int64_t handle) {
    RenderImage *img = img_acquire(handle);
    if (!img) return NULL;
    CGImageRef image = copyImageSnapshot(img);
    img_release(img);
    return image;
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
    const int afk = j2me_render_is_afk_suspended();
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderContext *rc = rc_acquire(handle);
    if (rc && rc->cpuCache) treo_cpu_batch_drain(rc);
    if (rc && rc->liveRun) {
        const uint64_t start = treo_profile_active() ? treo_thread_cpu_ns() : 0;
        treo_live_drain(rc, !afk);
        if (start && treo_profile_active()) {
            const uint64_t end = treo_thread_cpu_ns();
            if (end >= start) TREO_PROF_ADD(live_boundary_ns, end - start);
        }
    }
    if (rc) { rc->liveBlocked = 0; treo_software_publish(rc); }
    if (afk || (g_afk_canvas && g_afk_canvas == handle)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    const int profiling = treo_profile_active();
    if (profiling) TREO_PROF_ADD(flushes, 1);
    if (rc && g_flush_callback) {
        const uint64_t begin = profiling ? treo_thread_cpu_ns() : 0;
        CGImageRef image = treo_canvas_snapshot(rc);
        if (profiling && treo_profile_active()) {
            const uint64_t end = treo_thread_cpu_ns();
            if (begin && end >= begin) TREO_PROF_ADD(snapshot_ns, end - begin);
            if (image) TREO_PROF_ADD(snapshots, 1);
        }
        if (image) {
            atomic_fetch_add_explicit(&sw_frames, 1, memory_order_relaxed);
            g_flush_callback(image, rc->width, rc->height);
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
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        if (rc->ownsPixels && rc->clipSaved && treo_afk_fast_canvas() && rc->liveColor == (uint32_t)argb)
            ++rc->fastState;
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
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        CGRect nextClip = CGRectIntersection(CGRectMake(0, 0, rc->width, rc->height),
                                             CGRectStandardize(CGRectMake(x, y, w, h)));
        if (rc->cpuCache) treo_cpu_batch_drain(rc);
        if (w < 0 || h < 0) treo_live_barrier(rc);
        if (rc->ownsPixels && rc->clipSaved && treo_afk_fast_canvas() &&
            w >= 0 && h >= 0 && CGRectEqualToRect(rc->liveRawClip, CGRectMake(x, y, w, h)) &&
            rc->liveColor == rc->liveSavedColor && rc->liveStroke == rc->liveSavedStroke) {
            ++rc->fastState;
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
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        if (rc->ownsPixels && rc->clipSaved && treo_afk_fast_canvas() && rc->liveStroke == style)
            ++rc->fastState;
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
    RenderContext *rc = rc_acquire(handle);
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
    if (!rc->softwarePixels || !treo_afk_fast_canvas() || rc->fastFillRejected ||
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
    RenderContext *rc = rc_acquire(handle);
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
    RenderContext *rc = rc_acquire(handle);
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
    RenderContext *rc = rc_acquire(handle);
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
    RenderContext *rc = rc_acquire(handle);
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
    RenderContext *rc = rc_acquire(handle);
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
    RenderContext *rc = rc_acquire(handle);
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
    RenderContext *rc = rc_acquire(handle);
    if (rc) {
        if (rc->ownsPixels && treo_afk_fast_canvas() && rc->font && rc->fastFontValid &&
            rc->fastFontFace == face && rc->fastFontStyle == style && rc->fastFontSize == size) {
            ++rc->fastState;
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
    RenderContext *rc = rc_acquire(handle);
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    if (!rc || !jstr) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    Utf8String *ustr = utf8_create();
    env->jstring_2_utf8(jstr, ustr, runtime);
    CFStringRef str = CFStringCreateWithCString(NULL, utf8_cstr(ustr), kCFStringEncodingUTF8);
    utf8_destroy(ustr);
    if (!str) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(NULL, 3,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(attrs, kCTFontAttributeName, rc->font);
    CFDictionarySetValue(attrs, kCTForegroundColorFromContextAttributeName, kCFBooleanTrue);

    CFAttributedStringRef attrStr = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(attrStr);

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
    RenderContext *rc = rc_acquire(handle);

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
    RenderContext *rc = rc_acquire(handle);
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
    RenderContext *rc = rc_acquire(handle);
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
    RenderImage *img = createMutableImage(w, h);
    env->push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_createImageFromData(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    Instance *arr = env->localvar_getRefer(runtime->localvar, 0);
    s32 offset = env->localvar_getInt(runtime->localvar, 1);
    s32 length = env->localvar_getInt(runtime->localvar, 2);
    if (!arr) { env->push_long(runtime->stack, 0); return RUNTIME_STATUS_NORMAL; }
    c8 *arrBody = arr->arr_body;
    RenderImage *img = createImageFromData((uint8_t *)arrBody + offset, length);
    env->push_long(runtime->stack, (s64)(intptr_t)img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_destroyImage(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    if (g_render_stopped || handle == 0) return RUNTIME_STATUS_NORMAL;
    destroyImage((RenderImage *)(intptr_t)handle);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageWidth(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle);
    env->push_int(runtime->stack, img ? img->width : 0);
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageHeight(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle);
    env->push_int(runtime->stack, img ? img->height : 0);
    img_release(img);
    return RUNTIME_STATUS_NORMAL;
}

static s32 n_getImageContext(Runtime *runtime, JClass *clazz) {
    JniEnv *env = runtime->jnienv;
    s64 handle = env->localvar_getLong_2slot(runtime->localvar, 0);
    RenderImage *img = img_acquire(handle);
    if (img && img->isMutable && img->ctx) {
        RenderContext *rc = (RenderContext *)calloc(1, sizeof(RenderContext));
        atomic_init(&rc->refcount, 1);
        rc->ctx = img->ctx;
        CGContextRetain(rc->ctx);
        rc->width = img->width;
        rc->height = img->height;
        rc->fontSize = 14.0;
        rc->font = CTFontCreateWithName(CFSTR("Helvetica"), 14.0, NULL);
        rc->ownsPixels = 0; // pixels owned by the RenderImage, not this wrapper
        track_rc(rc);
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

    RenderContext *rc = rc_acquire(ctxHandle);
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    RenderImage *img = img_acquire(imgHandle);
    if (!rc || !img) { img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    int imgW = img->width, imgH = img->height;
    if (anchor & 1) x -= imgW / 2;
    if (anchor & 8) x -= imgW;
    if (anchor & 2) y -= imgH / 2;
    if (anchor & 32) y -= imgH;

    if (rc->cpuCache) treo_cpu_batch_drain(rc);
    if (rc->softwarePixels && treo_afk_fast_canvas() &&
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
            [command commit];
            end = treo_thread_cpu_ns();
            if (run && start && end >= start) metalNS += end - start;
            // Diagnostic only: no wait or pixel readback on the live paint path.
            [command waitUntilCompleted];
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
        !rc->ownsPixels || j2me_render_is_afk_suspended()) return;
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
static id<MTLTexture> treo_live_target;
static NSMutableDictionary *treo_live_textures;
static size_t treo_live_texture_bytes;

static id<MTLTexture> treo_live_texture(CGImageRef image, int cacheable) {
    // NSDictionary retains its CF object key through an NSValue/array entry.
    NSValue *key = [NSValue valueWithPointer:image];
    NSArray *entry = cacheable ? treo_live_textures[key] : nil;
    if (entry) return entry[1];
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    size_t bytes = w * h * 4;
    if (cacheable && treo_live_texture_bytes + bytes > 16u * 1024u * 1024u) {
        [treo_live_textures removeAllObjects];
        treo_live_texture_bytes = 0;
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
        treo_live_textures[key] = @[(__bridge id)image, tex];
        treo_live_texture_bytes += bytes;
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
    if (!treo_live_pipeline) {
        treo_live_device = MTLCreateSystemDefaultDevice();
        treo_live_queue = [treo_live_device newCommandQueue];
        treo_live_pipeline = treo_sprite_pipeline(treo_live_device, NULL);
        treo_live_vertices = [treo_live_device newBufferWithLength:TreoLiveCapacity * 6 * sizeof(TreoVertex)
                                                           options:MTLResourceStorageModeShared];
        treo_live_textures = [NSMutableDictionary new];
        treo_live_texture_bytes = 0;
    }
    if (!treo_live_pipeline || !treo_live_queue || !treo_live_vertices) return 0;
    size_t w = rc->width, h = rc->height;
    if (!treo_live_target || treo_live_target.width != w || treo_live_target.height != h) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
            MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
        td.storageMode = MTLStorageModeShared;
        td.usage = MTLTextureUsageRenderTarget;
        treo_live_target = [treo_live_device newTextureWithDescriptor:td];
    }
    if (!treo_live_target) return 0;
    NSMutableArray<id<MTLTexture>> *sources = [NSMutableArray arrayWithCapacity:run->count];
    NSMutableDictionary *solids = [NSMutableDictionary new];
    for (unsigned i = 0; i < run->count; i++) {
        TreoSprite *s = &run->sprites[i];
        id<MTLTexture> tex = s->kind == TreoRect ? treo_live_solid(s->color, solids)
            : i && s->image == run->sprites[i - 1].image ? sources.lastObject
            : treo_live_texture(s->image, s->cacheable);
        if (!tex) return 0;
        [sources addObject:tex];
    }

    CGContextFlush(rc->ctx);
    const void *base = CGBitmapContextGetData(rc->ctx);
    if (!base) return 0;
    MTLRegion rect = MTLRegionMake2D(0, 0, w, h);
    [treo_live_target replaceRegion:rect mipmapLevel:0 withBytes:base
                        bytesPerRow:CGBitmapContextGetBytesPerRow(rc->ctx)];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = treo_live_target;
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
    [command commit];
    [command waitUntilCompleted];
    if (command.status != MTLCommandBufferStatusCompleted) return 0;

    // Only at frame boundary. Keep the CG backing authoritative for later
    // partial repaints, copyArea and switching the backend without a restart.
    NSMutableData *bytes = [NSMutableData dataWithLength:w * h * 4];
    if (!bytes) return 0;
    [treo_live_target getBytes:bytes.mutableBytes bytesPerRow:w * 4 fromRegion:rect mipmapLevel:0];
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
        os_unfair_lock_trylock(&treo_live_gpu_lock)) {
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
        !j2me_render_is_afk_suspended() &&
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
        treo_metal_live_enabled() || j2me_render_is_afk_suspended() ||
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
} TreoRegionArgs;

static s32 treo_draw_region(const TreoRegionArgs *p, int direct) {
    s64 ctxHandle = p->ctx, imgHandle = p->img;
    s32 xSrc = p->sx, ySrc = p->sy, wSrc = p->w, hSrc = p->h, transform = p->transform;
    int64_t xDst = p->x, yDst = p->y;
    s32 anchor = p->anchor;
    RenderContext *rc = rc_acquire(ctxHandle);
    if (!rc) return RUNTIME_STATUS_NORMAL;
    if (treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
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
        !j2me_render_is_afk_suspended() && wSrc > 0 && hSrc > 0 &&
        transform >= 0 && transform <= 7 &&
        treo_region_outside_clip(rc->regionClipBounds, xDst, yDst, outW, outH)) {
        if (treo_profile_active()) TREO_PROF_ADD(region_culled, 1);
        rc_release(rc);
        return RUNTIME_STATUS_NORMAL;
    }

    RenderImage *img = img_acquire(imgHandle);
    if (!img) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    // AFK SIMD keeps producing canvas pixels, but never presents them.
    // Use the same verified raster and CG fallback as the visible backend.
    const int afkMode = atomic_load_explicit(&treo_afk_mode, memory_order_relaxed);
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
    CGImageRef fullImage = copyImageSnapshot(img);
    if (!fullImage) { img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL; }
    CGImageRef subImage = CGImageCreateWithImageInRect(fullImage, CGRectMake(xSrc, ySrc, wSrc, hSrc));
    if (subImage) treo_replay_capture(rc, fullImage, xDst, yDst, xSrc, ySrc, wSrc, hSrc, transform);
    CGImageRelease(fullImage);
    if (!subImage) { img_release(img); rc_release(rc); return RUNTIME_STATUS_NORMAL; }

    treo_draw_region_cg(rctx, subImage, xDst, yDst, wSrc, hSrc, transform);
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
    JniEnv *env = runtime->jnienv;
    s64 ctxHandle = env->localvar_getLong_2slot(runtime->localvar, 0);
    s64 imgHandle = env->localvar_getLong_2slot(runtime->localvar, 2);
    s32 xSrc = env->localvar_getInt(runtime->localvar, 4);
    s32 ySrc = env->localvar_getInt(runtime->localvar, 5);
    s32 wSrc = env->localvar_getInt(runtime->localvar, 6);
    s32 hSrc = env->localvar_getInt(runtime->localvar, 7);
    s32 transform = env->localvar_getInt(runtime->localvar, 8);
    int64_t xDst = env->localvar_getInt(runtime->localvar, 9);
    int64_t yDst = env->localvar_getInt(runtime->localvar, 10);
    s32 anchor = env->localvar_getInt(runtime->localvar, 11);

    const TreoRegionArgs p = {ctxHandle, imgHandle, xSrc, ySrc, wSrc, hSrc,
                              transform, (s32)xDst, (s32)yDst, anchor};
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

int treo_afk_elide_graphics(JClass *clazz, Instance *receiver) {
    if (!g_afk_canvas || !receiver || receiver->mb.clazz != clazz) return 0;
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
    if (ctx != g_afk_canvas || !receiver->obj_fields[(u16)(layout >> 16)]) return 0;
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
    const int fastCanvas = treo_afk_fast_canvas();
    if (!fastCanvas && (!treo_software_enabled() || j2me_render_is_afk_suspended())) return 0;
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
    if (!go || !io || g_afk_canvas) return 0;
    s64 ctx, img;
    s32 tx, ty;
    memcpy(&ctx, graphics->obj_fields + (u16)go, sizeof(ctx));
    memcpy(&tx, graphics->obj_fields + (u16)(go >> 16), sizeof(tx));
    memcpy(&ty, graphics->obj_fields + (u16)(go >> 32), sizeof(ty));
    memcpy(&img, image->obj_fields + (u16)io, sizeof(img));
    const TreoRegionArgs p = {ctx, img, localvar_getInt(locals, 2), localvar_getInt(locals, 3),
        localvar_getInt(locals, 4), localvar_getInt(locals, 5), localvar_getInt(locals, 6),
        (s32)((u32)localvar_getInt(locals, 7) + (u32)tx),
        (s32)((u32)localvar_getInt(locals, 8) + (u32)ty), localvar_getInt(locals, 9)};
    // The AFK shortcut stays on screen Canvas only; Image Graphics uses Java.
    if (fastCanvas) {
        RenderContext *target = rc_acquire(ctx);
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

    RenderContext *rc = rc_acquire(ctxHandle);
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

    RenderImage *img = img_acquire(imgHandle);
    if (!img || !arr) { img_release(img); return RUNTIME_STATUS_NORMAL; }

    s32 *dstData = (s32 *)arr->arr_body;
    uint8_t *srcData = (uint8_t *)CGBitmapContextGetData(img->ctx);
    int imgW = img->width;

    for (int row = 0; row < h; row++) {
        for (int col = 0; col < w; col++) {
            int srcIdx = ((y + row) * imgW + (x + col)) * 4;
            uint8_t b = srcData[srcIdx + 0];
            uint8_t g = srcData[srcIdx + 1];
            uint8_t r = srcData[srcIdx + 2];
            uint8_t a = srcData[srcIdx + 3];
            s32 argb = (a << 24) | (r << 16) | (g << 8) | b;
            dstData[offset + row * scanlength + col] = argb;
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
    RenderContext *rc = rc_acquire(handle);
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
    RenderContext *rc = rc_acquire(handle);
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
    RenderContext *rc = rc_acquire(handle);
    if (rc && treo_afk_skip_draw(rc)) { rc_release(rc); return RUNTIME_STATUS_NORMAL; }
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
    g_hapticEngine.resetHandler = ^{
        NSError *startErr = nil;
        [g_hapticEngine startAndReturnError:&startErr];
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
    }
}

static s32 n_vibrate(Runtime *runtime, JClass *clazz) {
    if (j2me_render_is_afk_suspended()) return RUNTIME_STATUS_NORMAL;
    s32 durationMs = runtime->jnienv->localvar_getInt(runtime->localvar, 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (@available(iOS 13.0, *)) {
            if (g_hapticPlayer) {
                NSError *err = nil;
                [g_hapticPlayer stopAtTime:0 error:&err];
                g_hapticPlayer = nil;
            }
            if (durationMs <= 0 || j2me_render_is_afk_suspended()) return;

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
            if (err) return;

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
    {CLS, "afkCanvasResult", "(I)V", n_afkCanvasResult},
    {CLS, "afkBypassPaint", "()Z", n_afkBypassPaint},
    {CLS, "beginAfkPaint", "(JZ)J", n_beginAfkPaint},
    {CLS, "endAfkPaint", "(J)V", n_endAfkPaint},
    // Context
    {CLS, "createContext",    "(II)J",                                   n_createContext},
    {CLS, "destroyContext",   "(J)V",                                    n_destroyContext},
    {CLS, "flushToScreen",    "(J)V",                                    n_flushToScreen},

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
    native_reg_lib(jvm, j2me_render_methods,
                   sizeof(j2me_render_methods) / sizeof(java_native_method));
    printf("[J2ME Render] Registered %lu native methods\n",
           sizeof(j2me_render_methods) / sizeof(java_native_method));
}

void j2me_render_stop(void) {
    g_render_stopped = 1;
}

void j2me_render_cleanup(void) {
    // g_render_stopped must already be set (via j2me_render_stop).
    // Two passes needed: first frees gen1 and promotes gen0→gen1,
    // second frees promoted gen1 (was gen0). After both, all dead shells are freed.
    process_dead_shells();
    process_dead_shells();

    // Force-release all still-live RenderContexts (never destroyed by Java).
    // These are guaranteed valid: untrack_rc removed freed ones from the array.
    spin_lock(&g_track_lock);
    int rc_count = g_live_rc_count;
    for (int i = 0; i < g_live_rc_count; i++) {
        RenderContext *rc = g_live_rc[i];
        treo_live_discard(rc);
        if (rc->ctx) { CGContextRelease(rc->ctx); rc->ctx = NULL; }
        free(rc->softwarePixels);
        rc->softwarePixels = NULL;
        CTFontRef font = rc->font;
        rc->font = NULL;
        if (font) CFRelease(font);
        free(rc);
    }
    g_live_rc_count = 0;

    // Force-release all still-live RenderImages
    int img_count = g_live_img_count;
    for (int i = 0; i < g_live_img_count; i++) {
        RenderImage *img = g_live_img[i];
        if (img->immutableSnapshot) CGImageRelease(img->immutableSnapshot);
        if (img->ctx) { CGContextRelease(img->ctx); img->ctx = NULL; }
        free(img);
    }
    g_live_img_count = 0;
    spin_unlock(&g_track_lock);

    // Clear dead queues
    os_unfair_lock_lock(&g_dead_drain_lock);
    atomic_store_explicit(&g_dead_rc_gen0, NULL, memory_order_relaxed);
    g_dead_rc_gen1 = NULL;
    atomic_store_explicit(&g_dead_img_gen0, NULL, memory_order_relaxed);
    g_dead_img_gen1 = NULL;
    os_unfair_lock_unlock(&g_dead_drain_lock);

    // Reset native heap counter
    __atomic_store_n(&g_native_extra_heap, 0, __ATOMIC_RELAXED);

    // Stop haptic engine
    if (@available(iOS 13.0, *)) {
        if (g_hapticPlayer) {
            NSError *err = nil;
            [g_hapticPlayer stopAtTime:0 error:&err];
            g_hapticPlayer = nil;
        }
        if (g_hapticEngine) {
            [g_hapticEngine stopWithCompletionHandler:nil];
            g_hapticEngine = nil;
        }
    }

    g_render_stopped = 0; // ready for next game session
    printf("[J2ME Render] Cleanup: %d contexts, %d images released\n", rc_count, img_count);
}
