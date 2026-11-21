#ifndef JVM_BRIDGE_H
#define JVM_BRIDGE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 3D supersampling scale factor (shared by M3G and MascotCapsule).
/// Set by jvm_bridge_init, read by j2me_m3g_jni.c and MC3D via system property.
extern int g_render_3d_scale;

/// Acquire the sole in-process JVM slot BEFORE dispatching the worker.
/// Returns 1 if acquired, 0 if another game is launching/running/tearing down.
int jvm_bridge_try_begin_session(void);
/// 0 idle, 1 starting, 2 running, 3 tearing down.
int jvm_bridge_session_phase(void);
/// Must only be called by the owning worker AFTER native cleanup.
void jvm_bridge_finish_session(void);
/// After user cancellation grace period, interrupt Java wait/sleep/loops.
/// Returns 1 when active Java threads were interrupted, 0 otherwise.
int jvm_bridge_interrupt_active_threads(void);

/// Record a Java launcher failure and return its UTF-8 diagnostic to Swift.
/// The message persists across JVM teardown until the next session begins.
void jvm_bridge_set_launch_error(const char *message);
// Launch-only diagnostic: trace Class_ek delegate assignment vs first paint.
// Keeps bounded events across JVM teardown until the next launch.
void jvm_bridge_note_nso_init_trace(const char *detail);
const char *jvm_bridge_nso_init_trace(void);
const char *jvm_bridge_last_error(void);

/// Initialize miniJVM with the given resource and save directories.
/// @param res_root         Path to directory containing runtime JARs
/// @param save_root        Path to writable directory for app data
/// @param midlet_jar       Path to the MIDlet JAR to include in classpath
/// @param screen_width     J2ME virtual screen width (e.g. 240)
/// @param screen_height    J2ME virtual screen height (e.g. 320)
/// @param render_3d_scale  3D supersampling factor for M3G & MC3D (1=native, 2=2x, 3=3x)
/// @param fps_limit        Max frames per second (0 = unlimited)
/// @return 0 on success, non-zero on failure
int jvm_bridge_init(const char *res_root, const char *save_root, const char *midlet_jar,
                    int screen_width, int screen_height, int render_3d_scale,
                    int fps_limit);

/// Run a MIDlet from a JAR file via MIDletRunner.
/// @param midlet_jar_path Path to the MIDlet JAR file
/// @return 0 on success, non-zero on failure
int jvm_bridge_run_midlet(const char *midlet_jar_path);

/// Destroy the JVM instance and free resources.
void jvm_bridge_destroy(void);

/// Request graceful MIDlet stop (non-blocking, thread-safe).
/// Can be called from any thread (e.g. main UI thread).
/// The Display event loop will detect this and call notifyDestroyed().
void jvm_bridge_request_stop(void);

/// Check if stop has been requested. Called from native methods on JVM thread.
int jvm_bridge_is_stop_requested(void);

// Set by NSO family-resource matching; Canvas structure is checked separately.
int treo_ninja_deep_verified(void);

// Passive verification for code-signed interpreter fast dispatch.
// Counts of interpreted Java method invocations are batched in groups of 64.
int treo_vm_direct_dispatch_build(void);
int treo_vm_paint_bridge_build(void);
uint64_t treo_vm_fast_method_calls(void);
int treo_vm_utf16_fast_build(void);
uint64_t treo_vm_utf16_fast_calls(void);
int treo_vm_array_lookup_build(void);
uint64_t treo_vm_array_lookup_fast_calls(void);
const char *treo_vm_array_lookup_diag_report(void);
uint64_t treo_vm_switch_method_calls(void);
uint64_t treo_vm_monitor_contentions(void);
uint64_t treo_vm_monitor_retries(void);

// Bounded one-in-32 Canvas.paint call-tree CPU sampler. No extra timer.
void treo_vm_paint_sample_reset(void);
void treo_vm_paint_sample_begin(void);
// 1 sampled, 0 unsampled mode-8, -1 if no scope.
int treo_vm_paint_sample_end(void);
void treo_vm_paint_sample_note_duration(int sampled, uint64_t elapsed_ns);
const char *treo_vm_paint_sample_report(void);

#ifdef __cplusplus
}
#endif

#endif /* JVM_BRIDGE_H */
