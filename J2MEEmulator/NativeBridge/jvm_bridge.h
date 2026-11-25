#ifndef JVM_BRIDGE_H
#define JVM_BRIDGE_H
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Legacy exclusive session admission BEFORE dispatching the worker.
/// Returns 1 if acquired, 0 if admission is denied.
int jvm_bridge_try_begin_session(void);
/// Atomic launch admission + immutable session token for the Swift worker.
/// Never infer a worker's token from the global visible/foreground session.
int jvm_bridge_try_begin_session_with_token(uint64_t *out_token);
/// Classify the JAR before admission. 1 acquired, -1 exclusive 3D conflict,
/// -2 memory budget denied,
/// 0 other admission failure. No existing session is stopped automatically.
int jvm_bridge_try_begin_session_for_jar(const char *path, uint64_t *out_token);
/// Current process headroom in bytes (UINT64_MAX on non-iOS host).
/// 0 safe, 1 warning (<=300 MiB or recent system warning), 2 critical (<150 MiB).
/// Samples fresh; no timer or heap traversal. Zero headroom is critical.
int jvm_bridge_memory_state(uint64_t *out_available);
/// Shared GC/render sample (normally at most one refresh per second process-wide).
/// Native launch admission must continue using the fresh API above.
int jvm_bridge_memory_state_cached(void);
/// Record a process-wide memory warning; admissions re-evaluate after 15s.
void jvm_bridge_memory_note_warning(void);
/// Drop only regenerable read-only classpath readers; never touch JVM heaps.
void jvm_bridge_trim_classpath_cache(void);
/// Advisory UI check only; admission rechecks under the lifecycle lock.
int jvm_bridge_3d_conflict_for_jar(const char *path);
/// Per-worker execution/cleanup entry points claim one native executor slot
/// by immutable token. Shared 2D admission is memory-gated.
/// Init returns -12 if the memory budget became unsafe before allocation.
int jvm_bridge_init_for_token(uint64_t token, const char *res_root,
                              const char *save_root, const char *midlet_jar,
                              int screen_width, int screen_height,
                              int render_3d_scale, int fps_limit);
int jvm_bridge_run_midlet_for_token(uint64_t token, const char *midlet_jar_path);
int jvm_bridge_is_stop_requested_for_token(uint64_t token);
int jvm_bridge_destroy_for_token(uint64_t token);
int jvm_bridge_finish_session_for_token(uint64_t token);
/// 0 idle, 1 starting, 2 running, 3 tearing down.
int jvm_bridge_session_phase(void);
struct _MiniJVM;
// Synchronous visitor, allowed only while this session is RUNNING. The VM
// pointer is never returned; the callback lease protects it until the
// synchronous visitor finishes. No new poller/thread.
void jvm_bridge_visit_running_vm(void (*visitor)(struct _MiniJVM *, void *),
                                 void *arg);
/// Explicit token-scoped visitor; returns 1 only if the exact owner was
/// pinned and visited during RUNNING. Never returns a heap pointer.
int jvm_bridge_visit_running_vm_for_token(
    uint64_t token, void (*visitor)(struct _MiniJVM *, void *), void *arg);
/// Checks whether a token still occupies a claimed/starting/running/stopping
/// slot without dereferencing a JVM. Useful to retain a parked VC identity.
int jvm_bridge_session_is_active_for_token(uint64_t token);
/// Last GC-measured Java heap + accounted native bytes (not physical footprint).
/// Returns 1 with a sample, 0 if unavailable. Does not walk or collect the heap.
int jvm_bridge_status_heap_bytes_for_token(uint64_t token, uint64_t *out_bytes);
/// Check the actual ownership flag (phase may briefly be idle during start).
int jvm_bridge_session_is_active(void);
/// Truthful number of reserved live native VM slots.
int jvm_bridge_active_session_count(void);
/// Technical registry ceiling, not a guaranteed safe live count.
/// Fresh RAM headroom and 3D exclusivity additionally gate admission.
int jvm_bridge_supported_concurrent_sessions(void);
/// Monotonically increasing ID of the active session, zero if none.
/// Used to reject callbacks from a previously closed game instance.
uint64_t jvm_bridge_session_token(void);
/// Scoped to the current Java pthread; binds a token, never a VM pointer.
/// push/pop must be paired along all Java worker exit paths.
uint64_t jvm_bridge_thread_token(void);
uint64_t jvm_bridge_push_java_thread_token(uint64_t token);
void jvm_bridge_pop_java_thread_token(uint64_t previous);
/// Focus invariant: at most one JVM is visible, all others stay parked.
/// A zero visible token means library: every live session is in Treo.
/// Operations resolve a slot by token; only one session is visible.
int jvm_bridge_park_session(uint64_t token);
int jvm_bridge_focus_session(uint64_t token);
/// -1 = stale/unknown token, 0 = focused, 1 = parked.
int jvm_bridge_session_is_parked(uint64_t token);
uint64_t jvm_bridge_visible_session_token(void);
int jvm_bridge_request_stop_for_token(uint64_t token);
/// Stop state as seen by one concrete native JVM. Foreign/stale JVMs must
/// not see a subsequent game's stop state; they report stop requested.
int jvm_bridge_is_stop_requested_for_vm(const void *vm);
int jvm_bridge_interrupt_active_threads_for_token(uint64_t token);
/// Must only be called by the owning worker AFTER native cleanup.
void jvm_bridge_finish_session(void);
/// After user cancellation grace period, interrupt Java wait/sleep/loops.
/// Returns 1 when active Java threads were interrupted, 0 otherwise.
int jvm_bridge_interrupt_active_threads(void);

/// Record a Java launcher failure and return its UTF-8 diagnostic to Swift.
/// The message belongs to this token and survives cleanup until retirement.
void jvm_bridge_set_launch_error(const char *message);
// Launch-only diagnostic: trace Class_ek delegate assignment vs first paint.
// Keeps bounded events across JVM teardown until the next launch.
void jvm_bridge_note_nso_init_trace(const char *detail);
const char *jvm_bridge_nso_init_trace(void);
const char *jvm_bridge_last_error(void);
/// Snapshot the exact worker's diagnostics before its session retires.
const char *jvm_bridge_last_error_for_token(uint64_t token);
const char *jvm_bridge_nso_init_trace_for_token(uint64_t token);
const char *jvm_bridge_net_trace_for_token(uint64_t token);

// Network event diagnostics live outside the Java stack, one bounded
// record per token. Only connection attempts and failures are stored.
void jvm_bridge_note_net_trace(const char *detail);
const char *jvm_bridge_net_trace(void);

// Sampled on demand from the debug menu. An atomic game-loop counter is
// cheaper and safer than polling/walking live Java threads or their stack.
void jvm_bridge_mod_popup_tick(void);
uint64_t jvm_bridge_mod_popup_tick_count(void);
// Four exact method-call-site counters in the known mod's game-loop thread.
// 1: modal update, 2: repaint, 3: serviceRepaints, 4: Thread.sleep.
void jvm_bridge_mod_loop_note_stage(int stage);
uint64_t jvm_bridge_mod_loop_stage_count(int stage);
int jvm_bridge_mod_loop_last_stage(void);
// Bound exception notes to the first 12 per session; no Java heap access.
int jvm_bridge_mod_loop_exception_log_slot(void);
// One-shot JVM method-resolution diagnostics for the mod. These counters
// are independent of the repeating UI exception notes.
int jvm_bridge_mod_dispatch_probe_slot(void);
int jvm_bridge_mod_method_missing_slot(void);
// Bounded, content-free diagnostics for the mod's version-response branches.
int jvm_bridge_mod_protocol_note_slot(void);

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
