#ifndef J2ME_RENDER_H
#define J2ME_RENDER_H

#include "jvm.h"
#include <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Register all J2ME rendering native methods with the JVM.
void j2me_render_reg_natives(MiniJVM *jvm);

/// Callback type for pixel flush — called when a frame is ready to display.
/// @param cgImage A CGImageRef containing the rendered frame. Caller must CFRelease.
/// @param width   Image width
/// @param height  Image height
typedef void (*j2me_flush_callback)(void *cgImage, int width, int height);

/// Set the callback for receiving rendered frames.
void j2me_render_set_flush_callback(j2me_flush_callback callback);

/// Owning JVM generation accompanies every frame all the way to the UIKit
/// main-thread drain. This prevents stale queued frames after a tab switch.
typedef void (*j2me_flush_callback_owned)(void *cgImage, int width, int height,
                                          uint64_t owner_key);
void j2me_render_set_owned_flush_callback(j2me_flush_callback_owned callback);
uint64_t j2me_render_visible_owner_key(void);

// Select which *owned JVM generation* may publish Canvas frames to UIKit.
// Both original and clone tabs run the same JAR, so identity is by VM.
// Selecting focus never starts or stops a JVM.
int j2me_render_focus_vm(MiniJVM *vm);
// Suppress later foreground flushes from a JVM that is shutting down.
// Native CoreGraphics resources are still cleaned by the VM owner.
void j2me_render_release_vm(MiniJVM *vm);
void j2me_render_set_afk_suspended(int enabled);
int j2me_render_is_afk_suspended(void);
// 0: visible, 1: legacy blackout, 2: native suppression, 3: headless Graphics,
// 4: headless VM elision, 5: blackout with canvas raster kept on SIMD.
void treo_render_set_afk_mode(int mode);
uint64_t treo_afk_skipped_draws(void);
uint64_t treo_afk_skipped_paints(void);
void treo_jar_audit_set(int enabled);
void treo_jar_load_set(int mode);
void treo_jar_load_worker_period_set(uint64_t period_ns);
int treo_jar_load_game_qos(void);
int treo_jar_load_worker_qos(void);
uint64_t treo_jar_load_cpu_ns(void);
uint64_t treo_jar_load_wall_ns(void);
uint64_t treo_jar_load_calls(void);
uint64_t treo_jar_audit_ticks(int active);
// Explicitly enabled ONLY in cross-thread diagnostic A/B/A.
// JarBox-wide safe AFK GC: native presentation off, fallback at heap pressure.
void treo_gc_smart_set(int enabled);
void treo_gc_smart_force_safe(void);
int treo_gc_smart_period_ms(void);
int treo_gc_smart_fell_back(void);
uint64_t treo_gc_smart_heap_peak(void);
uint64_t treo_gc_smart_count(void);
double treo_gc_smart_cpu_ms(void);
// Opt-in GC cadence test: 0 = original 500 ms, 2000 = test mode.
void treo_gc_probe_set_period_ms(int requested);
int treo_gc_probe_current_period_ms(void);
uint64_t treo_gc_probe_peak_heap_bytes(void);
uint64_t treo_gc_probe_fallbacks(void);
void treo_diag_set(int on);
void treo_diag_sample(int kind); // 0=main, 1=game, 2=GC
uint64_t treo_diag_samples(int kind);
double treo_diag_ns_per_step(int kind, int wall);
void treo_diag_gc_cycle_begin(void);
void treo_diag_gc_cycle_end(void);
uint64_t treo_diag_gc_cycles(void);
double treo_diag_gc_cpu_ms(void);
double treo_diag_gc_wall_ms(void);
// Opt-in diagnostic only: 0/1/3 Java paints per second in an audit leg.
void treo_jar_sparse_paint_set(int hz);
uint64_t treo_jar_sparse_paint_due_count(void);
// Reversible QoS experiment: call from main thread only.
int treo_main_qos_begin(void);
int treo_main_qos_current(void);
int treo_main_qos_expected(int mode);
int treo_main_qos_apply(int mode);
int treo_main_qos_finish(void);
uint64_t treo_afk_paint_count(void);
// Experimental bounded JAR resource-byte cache, mode 8 only.
int treo_image_cache_build(void);
uint64_t treo_image_cache_hits(void);
uint64_t treo_ninja_deep_skipped(int stage);
// Repaint request cadence is only a game-loop heartbeat proxy, not a real tick.
void treo_nso_probe_reset(void);
int treo_nso_canvas_recognized(void);
uint64_t treo_nso_repaint_requests(void);
double treo_nso_prior_repaint_hz(void);
double treo_nso_last_repaint_gap_ms(void);
// Controlled NSO fixed integer-work proxy, not direct evidence of P/E core.
// Phase 0: normal play; phase 1: JarBox mode 8; CPU vs wall ns/step.
uint64_t treo_nso_work_samples(int phase);
double treo_nso_work_ns_per_step(int phase, int wall);
int treo_nso_work_qos(int phase);
uint64_t treo_nso_work_thread(void);
uint64_t treo_image_cache_stores(void);
uint64_t treo_image_cache_stored_bytes(void);
// Opt-in safety fallback for JarBox's generic guarded Java Canvas AFK.
void treo_afk_guard_auto_set(int enabled);
int treo_afk_guard_auto_fell_back(void);
// One dedicated A/B/A test of redundant GameCanvas Image->Canvas blits.
void treo_afk_buffer_audit_set(int enabled, int skip);
uint64_t treo_afk_buffer_copied(void);
uint64_t treo_afk_buffer_skipped(void);
uint64_t treo_afk_buffer_pixels_saved(void);
uint64_t treo_afk_buffer_copy_cpu_ns(void);
uint64_t treo_afk_guarded_paints(void);
uint64_t treo_afk_guarded_real(void);
uint64_t treo_afk_guarded_late(void);
uint64_t treo_afk_layer_frames(void);
// Access the run-loop observer from the main thread only.
void treo_afk_wakes_set(int enabled);
uint64_t treo_afk_main_wakes(void);
uint64_t treo_afk_bypassed_paints(void);
uint64_t treo_afk_elided_calls(void);
void treo_afk_threads_begin(void);
double treo_afk_current_thread_cpu(void);
// Samples brief, identical integer work on main; CPU nanoseconds per iteration.
double treo_main_fixed_work_ns_per_step(void);
void treo_afk_main_trace_begin(void);
void treo_afk_main_stack_begin(void);
void treo_afk_main_stack_snapshot_begin(void);
void treo_afk_main_source_trace_begin(void);
void treo_afk_main_source_mark(int active);
void treo_afk_main_trace_cancel(void);
char * _Nullable treo_afk_main_trace_end(void); // caller frees
void treo_afk_ui_cut_set(int enabled);
void treo_afk_ui_canvas_applied(int revision);
uint64_t treo_afk_ui_notices_saved(void);
char * _Nullable treo_afk_threads_report(double seconds); // caller frees
uint64_t treo_afk_paint_cpu_ns(void);

// Foreground CPU diagnostics; only the UI controls the measurement window.
typedef struct {
    uint64_t paints;
    uint64_t paint_ns;
    uint64_t flushes;
    uint64_t snapshots;
    uint64_t snapshot_ns;
    uint64_t replaced;
    uint64_t submitted;
    uint64_t region_calls;
    uint64_t region_culled;
    uint64_t live_boundary_ns;
    uint64_t region_samples;
    uint64_t region_sample_ns;
} TreoRenderProfile;
// Experimental foreground drawRegion rejection. Off by default.
int treo_render_region_cull_enabled(void);
void treo_render_set_region_cull_enabled(int enabled);
// Offscreen A/B of captured drawRegion commands; never replaces live rendering.
int treo_metal_replay_start(void);
int treo_metal_live_enabled(void);
void treo_metal_live_set_enabled(int enabled);
uint64_t treo_metal_live_frames(void);
uint64_t treo_metal_live_sprites(void);
uint64_t treo_metal_live_fallback_sprites(void);
char * _Nullable treo_metal_replay_copy_report(void); // caller frees
// Total CPU of all threads in this app, in seconds; negative on error.
double treo_process_cpu_seconds(void);
typedef struct {
    uint64_t frames, regions, fast, checked, mismatch, direct;
} TreoSoftwareStats;
typedef struct { uint64_t fills, checks, mismatch, state; } TreoFastCanvasStats;
TreoFastCanvasStats treo_fast_canvas_stats(void);
int treo_software_enabled(void);
int treo_direct_graphics_enabled(void);
void treo_direct_graphics_set_enabled(int enabled);
void treo_software_set_enabled(int enabled);
TreoSoftwareStats treo_software_stats(void);
int treo_cpu_batch_enabled(void);
void treo_cpu_batch_set_enabled(int enabled);
uint64_t treo_cpu_batch_reused(void);
uint64_t treo_cpu_batch_queued(void);
void treo_render_profile_start(void);
TreoRenderProfile treo_render_profile_stop(void);
void treo_render_profile_replaced(void);
void treo_render_profile_submitted(void);

CGImageRef _Nullable j2me_render_copy_image(int64_t handle) CF_RETURNS_RETAINED;

/// Signal render subsystem to stop (all acquire calls return NULL).
/// Must be called before cleanup to protect against zombie threads.
void j2me_render_stop(void);

/// Clean up all render resources. Call between game sessions (after j2me_render_stop).
void j2me_render_cleanup(void);

#ifdef __cplusplus
}
#endif

#endif /* J2ME_RENDER_H */
