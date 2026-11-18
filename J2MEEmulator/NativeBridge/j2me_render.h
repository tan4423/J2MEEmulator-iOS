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
    uint64_t region_samples;
    uint64_t region_sample_ns;
} TreoRenderProfile;
// Experimental foreground drawRegion rejection. Off by default.
int treo_render_region_cull_enabled(void);
void treo_render_set_region_cull_enabled(int enabled);
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
