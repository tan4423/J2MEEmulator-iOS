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
void j2me_render_set_afk_suspended(int enabled);
int j2me_render_is_afk_suspended(void);
// 0: visible, 1: legacy blackout, 2: native raster suppression, 3: headless Graphics.
void treo_render_set_afk_mode(int mode);
uint64_t treo_afk_skipped_draws(void);
uint64_t treo_afk_skipped_paints(void);
uint64_t treo_afk_paint_count(void);
uint64_t treo_afk_elided_calls(void);
void treo_afk_threads_begin(void);
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
