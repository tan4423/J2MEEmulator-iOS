//
// j2me_input.c — Thread-safe input event bridge between iOS and miniJVM
//
// Uses a lock-free ring buffer for single-producer (iOS main thread)
// single-consumer (JVM thread) communication.
//

#include "j2me_input.h"
#include "jarbox_input_ring.h"
#include "jvm_bridge.h"
#include "jvm.h"
#include "jvm_util.h"
#include "garbage.h" // jarbox_native_heap_key_for_runtime: immutable Java thread generation
#include <stdio.h>
#include <stdatomic.h>
#include <pthread.h>
#include <time.h>
#include <stdint.h>
#include <errno.h>

// ============================================================
// Ring buffer
// ============================================================

// First native subsystem with true *per-VM* storage. Each bound miniJVM
// owns a distinct input ring and GC-safe Display wait. A JVM's native calls
// are dispatched through runtime->jvm, never through another game's UI slot.
// This does NOT yet enable multi-game execution: rendering, MIDP UI, audio,
// and several VM diagnostics still use process globals.
#define JARBOX_INPUT_CONTEXT_CAPACITY 64
typedef struct {
    _Atomic(MiniJVM *) vm;
    uint64_t generation; // guarded by g_input_context_lock
    uint64_t heap_key;   // native generation, guarded by g_input_context_lock
    uint64_t session_token; // launch identity, guarded by g_input_context_lock
    JarBoxInputRing ring;
    atomic_int accepting_input; // terminal revocation, before worker drain
    atomic_int display_wait_enabled;
    atomic_int angel_sleep_requested; // per-session reliable control mailbox
    int angel_sleep_delivered; // only the Java Display polling consumer writes
    pthread_mutex_t display_wait_lock;
    pthread_cond_t display_wait_cond;
    uint32_t display_wait_sequence;
    int canvas_width, canvas_height;
} J2MEInputContext;

static J2MEInputContext g_input_contexts[JARBOX_INPUT_CONTEXT_CAPACITY];
static pthread_once_t g_input_context_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_input_context_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(J2MEInputContext *) g_visible_input_context;
static uint64_t g_input_next_generation; // guarded by g_input_context_lock

static void init_input_contexts(void) {
    for (int i = 0; i < JARBOX_INPUT_CONTEXT_CAPACITY; ++i) {
        J2MEInputContext *ctx = &g_input_contexts[i];
        pthread_mutex_init(&ctx->display_wait_lock, NULL);
        pthread_cond_init(&ctx->display_wait_cond, NULL);
        ctx->display_wait_sequence = 1;
        ctx->canvas_width = 240;
        ctx->canvas_height = 320;
    }
}

static J2MEInputContext *context_for_vm(MiniJVM *vm) {
    if (!vm) return NULL;
    for (int i = 0; i < JARBOX_INPUT_CONTEXT_CAPACITY; ++i) {
        J2MEInputContext *ctx = &g_input_contexts[i];
        if (atomic_load_explicit(&ctx->vm, memory_order_acquire) == vm)
            return ctx;
    }
    return NULL;
}

// Never choose B's input slot for A's stale Java Runtime.
static J2MEInputContext *context_for_runtime(Runtime *runtime) {
    if (!jarbox_native_heap_key_for_runtime(runtime)) return NULL;
    J2MEInputContext *ctx = context_for_vm(runtime->jvm);
    return ctx && atomic_load_explicit(&ctx->accepting_input, memory_order_acquire) ? ctx : NULL;
}

static J2MEInputContext *visible_input_context(void) {
    return atomic_load_explicit(&g_visible_input_context, memory_order_acquire);
}

// Called when a new JVM's native methods are registered. A bound JVM never
// receives input events belonging to any other bound JVM.
static int bind_input_context(MiniJVM *vm) {
    if (!vm) return 0;
    const uint64_t heap_key = jarbox_native_heap_key_for_vm(vm);
    const uint64_t token = vm->session ?
        __atomic_load_n(&vm->session->token, __ATOMIC_ACQUIRE) : 0;
    if (!heap_key || !token) return 0;
    pthread_once(&g_input_context_once, init_input_contexts);
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = context_for_vm(vm);
    // A retired address must not inherit the previous launch's input slot.
    if (ctx && (ctx->session_token != token || ctx->heap_key != heap_key ||
                !atomic_load_explicit(&ctx->accepting_input, memory_order_acquire))) {
        pthread_mutex_unlock(&g_input_context_lock);
        return 0;
    }
    if (!ctx) {
        for (int i = 0; i < JARBOX_INPUT_CONTEXT_CAPACITY; ++i) {
            J2MEInputContext *candidate = &g_input_contexts[i];
            if (!atomic_load_explicit(&candidate->vm, memory_order_acquire)) {
                ctx = candidate;
                jarbox_input_ring_reset(&ctx->ring);
                atomic_store_explicit(&ctx->display_wait_enabled, 0, memory_order_relaxed);
                atomic_store_explicit(&ctx->angel_sleep_requested, 0, memory_order_relaxed);
                ctx->angel_sleep_delivered = 0;
                ctx->canvas_width = 240;
                ctx->canvas_height = 320;
                ctx->generation = ++g_input_next_generation;
                if (ctx->generation == 0) ctx->generation = ++g_input_next_generation;
                ctx->heap_key = heap_key;
                ctx->session_token = token;
                atomic_store_explicit(&ctx->accepting_input, 1, memory_order_release);
                atomic_store_explicit(&ctx->vm, vm, memory_order_release);
                break;
            }
        }
    }
    // Existing one-JVM lifecycle continues to select its input destination.
    // A future multi-JVM scheduler must explicitly set focus when switching.
    if (ctx && !visible_input_context())
        atomic_store_explicit(&g_visible_input_context, ctx, memory_order_release);
    pthread_mutex_unlock(&g_input_context_lock);
    return ctx != NULL;
}

// The UI can select exactly which bound JVM receives physical input. This
// selects a destination only; it does not create/start/stop a Java VM.
int j2me_input_focus_vm(MiniJVM *vm) {
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = context_for_vm(vm);
    const int ready = ctx && atomic_load_explicit(&ctx->accepting_input, memory_order_acquire);
    if (ready) atomic_store_explicit(&g_visible_input_context, ctx, memory_order_release);
    pthread_mutex_unlock(&g_input_context_lock);
    return ready;
}

/* Parking revokes physical input only; Java event queues and the Display
 * waiter remain bound to this exact JVM. A hidden owner cannot clear B. */
void j2me_input_park_vm(MiniJVM *vm) {
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = context_for_vm(vm);
    if (ctx && visible_input_context() == ctx)
        atomic_store_explicit(&g_visible_input_context, NULL, memory_order_release);
    pthread_mutex_unlock(&g_input_context_lock);
}

// Only enabled for the known TrungDucTV NSO mod during its normal game
// runtime. Do not log every key or every frame on other Java ME games.
extern _Atomic int treo_nso_init_target_active;
static void trace_modal_key(const char *where, int type, int keyCode) {
    if (!atomic_load_explicit(&treo_nso_init_target_active, memory_order_relaxed))
        return;
    if ((type != J2ME_INPUT_KEY_PRESSED && type != J2ME_INPUT_KEY_RELEASED)
            || (keyCode != -5 && keyCode != -6 && keyCode != -7 && keyCode != 53))
        return;
    char event[128];
    snprintf(event, sizeof(event), "input_%s:key=%d,action=%s", where,
             keyCode, type == J2ME_INPUT_KEY_PRESSED ? "press" : "release");
    jvm_bridge_note_net_trace(event);
}

// Opt-in Display idle wait. Version sampling before polling prevents lost
// native input and repaint notifications between the Java test and sleep.
// Process-wide diagnostic counters; they are deliberately not labelled
// per-game. The actual wait/condition state lives in each input context.
static _Atomic uint64_t g_display_poll_calls;
static _Atomic uint64_t g_display_wait_calls;
static _Atomic uint64_t g_display_gc_safe_wait_calls;
static _Atomic uint64_t g_display_wait_timeouts;
static _Atomic uint64_t g_display_wake_signals;

static void signal_display_wait(J2MEInputContext *ctx) {
    if (!ctx) return;
    pthread_mutex_lock(&ctx->display_wait_lock);
    ++ctx->display_wait_sequence;
    pthread_cond_broadcast(&ctx->display_wait_cond);
    pthread_mutex_unlock(&ctx->display_wait_lock);
}
static int display_should_wait(J2MEInputContext *ctx) {
    return ctx && (atomic_load_explicit(&ctx->display_wait_enabled, memory_order_acquire) ||
                   atomic_load_explicit(&ctx->angel_sleep_requested, memory_order_acquire));
}
static void wake_input_context(J2MEInputContext *ctx) {
    if (!ctx) return;
    if (display_should_wait(ctx)) {
        atomic_fetch_add_explicit(&g_display_wake_signals, 1, memory_order_relaxed);
        signal_display_wait(ctx);
    }
}
void j2me_display_wake(void) {
    pthread_mutex_lock(&g_input_context_lock);
    wake_input_context(visible_input_context());
    pthread_mutex_unlock(&g_input_context_lock);
}
void j2me_display_wake_for_vm(MiniJVM *vm) {
    pthread_mutex_lock(&g_input_context_lock);
    wake_input_context(context_for_vm(vm));
    pthread_mutex_unlock(&g_input_context_lock);
}
void treo_display_wait_set(int enabled) {
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = visible_input_context();
    if (ctx && atomic_load_explicit(&ctx->accepting_input, memory_order_acquire)) {
        atomic_store_explicit(&ctx->display_wait_enabled, enabled != 0, memory_order_release);
        signal_display_wait(ctx);
    }
    pthread_mutex_unlock(&g_input_context_lock);
}
/* Set the Display wait mode for the *actual JVM token*, not whichever Tab
 * happens to own the physical input destination. The bridge lease protects
 * the JVM while the input-context mutex protects slot reuse. */
void treo_display_wait_set_for_vm(MiniJVM *vm, int enabled) {
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = context_for_vm(vm);
    if (ctx && atomic_load_explicit(&ctx->accepting_input, memory_order_acquire)) {
        atomic_store_explicit(&ctx->display_wait_enabled, enabled != 0,
                              memory_order_release);
        signal_display_wait(ctx);
    }
    pthread_mutex_unlock(&g_input_context_lock);
}
static void treo_wait_visitor(MiniJVM *vm, void *arg) {
    treo_display_wait_set_for_vm(vm, *(const int *)arg);
}
int treo_display_wait_set_for_token(uint64_t token, int enabled) {
    if (!token) return 0;
    return jvm_bridge_visit_running_vm_for_token(token, treo_wait_visitor, &enabled);
}
uint64_t treo_display_poll_calls(void) { return atomic_load_explicit(&g_display_poll_calls, memory_order_relaxed); }
uint64_t treo_display_wait_calls(void) { return atomic_load_explicit(&g_display_wait_calls, memory_order_relaxed); }
uint64_t treo_display_gc_safe_wait_calls(void) { return atomic_load_explicit(&g_display_gc_safe_wait_calls, memory_order_relaxed); }
uint64_t treo_display_wait_timeouts(void) { return atomic_load_explicit(&g_display_wait_timeouts, memory_order_relaxed); }
uint64_t treo_display_wake_signals(void) { return atomic_load_explicit(&g_display_wake_signals, memory_order_relaxed); }


void j2me_input_set_canvas_size(int width, int height) {
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = visible_input_context();
    if (ctx && atomic_load_explicit(&ctx->accepting_input, memory_order_acquire)) {
        ctx->canvas_width = width;
        ctx->canvas_height = height;
    }
    pthread_mutex_unlock(&g_input_context_lock);
}

static void enqueue_to_context(J2MEInputContext *ctx,
                               int type, int x, int y, int keyCode) {
    if (!ctx || !atomic_load_explicit(&ctx->accepting_input, memory_order_acquire)) return;
    const JarBoxInputEvent event = {type, x, y, keyCode};
    if (!jarbox_input_ring_push(&ctx->ring, &event)) {
        // A full queue is a real drop, never an invented replacement key.
        trace_modal_key("drop", type, keyCode);
        return;
    }
    trace_modal_key("post", type, keyCode);
    wake_input_context(ctx);
}

static void enqueue_event(int type, int x, int y, int keyCode) {
    pthread_mutex_lock(&g_input_context_lock);
    enqueue_to_context(visible_input_context(), type, x, y, keyCode);
    pthread_mutex_unlock(&g_input_context_lock);
}

static int dequeue_event(J2MEInputContext *ctx, JarBoxInputEvent *out) {
    return ctx && jarbox_input_ring_pop(&ctx->ring, out);
}

// ============================================================
// Public API (called from Swift/main thread)
// ============================================================

void j2me_input_post_touch(int type, int x, int y) {
    enqueue_event(type, x, y, 0);
}

// LCDUI commands carry the exact heap generation of the presenting view.
// Focus/release/rebind cannot change this destination between check and push.
void j2me_input_post_touch_for_owner(uint64_t owner_key, int type, int x, int y) {
    if (!owner_key) return;
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = visible_input_context();
    if (ctx && ctx->heap_key == owner_key)
        enqueue_to_context(ctx, type, x, y, 0);
    pthread_mutex_unlock(&g_input_context_lock);
}

void j2me_input_post_key(int type, int keyCode) {
    enqueue_event(type, 0, 0, keyCode);
}

// Physical Canvas controls identify the owning launch, not current focus.
static void enqueue_event_for_token(uint64_t token, int type, int x, int y, int keyCode) {
    if (!token) return;
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = visible_input_context();
    if (ctx && ctx->session_token == token)
        enqueue_to_context(ctx, type, x, y, keyCode);
    pthread_mutex_unlock(&g_input_context_lock);
}
// Unlike the input ring, start/stop cannot be dropped on queue overflow.
int j2me_angel_sleep_set_for_token(uint64_t token, int enabled) {
    if (!token) return 0;
    int found = 0;
    pthread_mutex_lock(&g_input_context_lock);
    for (int i = 0; i < JARBOX_INPUT_CONTEXT_CAPACITY; ++i) {
        J2MEInputContext *ctx = &g_input_contexts[i];
        if (ctx->session_token != token || !atomic_load_explicit(&ctx->accepting_input, memory_order_acquire)) continue;
        if (enabled && visible_input_context() != ctx) break;
        atomic_store_explicit(&ctx->angel_sleep_requested, enabled != 0, memory_order_release);
        signal_display_wait(ctx);
        found = 1;
        break;
    }
    pthread_mutex_unlock(&g_input_context_lock);
    return found;
}
void j2me_input_post_key_for_token(uint64_t token, int type, int keyCode) {
    enqueue_event_for_token(token, type, 0, 0, keyCode);
}
void j2me_input_post_touch_for_token(uint64_t token, int type, int x, int y) {
    enqueue_event_for_token(token, type, x, y, 0);
}

// Audio completion events must target the JVM that created the sound, even
// after UI input focus changes. Generation prevents a delayed event from an
// old JVM whose address is reused by the allocator for a later session.
uint64_t j2me_input_binding_generation(MiniJVM *vm) {
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = context_for_vm(vm);
    const uint64_t generation = ctx && atomic_load_explicit(&ctx->accepting_input, memory_order_acquire) ? ctx->generation : 0;
    pthread_mutex_unlock(&g_input_context_lock);
    return generation;
}

// Call only from the same main-thread producer used for physical iOS input.
void j2me_input_post_key_to_vm(MiniJVM *vm, uint64_t generation,
                               int type, int keyCode) {
    if (!generation) return;
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = context_for_vm(vm);
    if (ctx && ctx->generation == generation)
        enqueue_to_context(ctx, type, 0, 0, keyCode);
    pthread_mutex_unlock(&g_input_context_lock);
}

// ============================================================
// Native method: NativeBridge.pollInputEvent() → int[] or null
// Returns int[4]: {type, x, y, keyCode}
// ============================================================

static s32 n_pollInputEvent(Runtime *runtime, JClass *clazz) {
    atomic_fetch_add_explicit(&g_display_poll_calls, 1, memory_order_relaxed);
    JniEnv *env = runtime->jnienv;
    JarBoxInputEvent evt;

    J2MEInputContext *ctx = context_for_runtime(runtime);
    int control = 0;
    if (!dequeue_event(ctx, &evt)) {
        const int requested = ctx ? atomic_load_explicit(&ctx->angel_sleep_requested, memory_order_acquire) : 0;
        if (!ctx || requested == ctx->angel_sleep_delivered) {
            env->push_ref(runtime->stack, NULL);
            return RUNTIME_STATUS_NORMAL;
        }
        // Drain existing input (including key releases) before changing Canvas.
        // This event never enters the bounded ring or the game's key handler.
        evt = (JarBoxInputEvent){90, requested, 0, 0};
        control = 1;
    }

    // Create int[4] array
    Utf8String *type_name = utf8_create_c("[I");
    Instance *arr = jarray_create_by_type_index(runtime, 4, DATATYPE_INT);
    if (!arr) {
        utf8_destroy(type_name);
        env->push_ref(runtime->stack, NULL);
        return RUNTIME_STATUS_NORMAL;
    }
    utf8_destroy(type_name);

    // Fill array
    s32 *body = (s32 *)arr->arr_body;
    body[0] = evt.type;
    body[1] = evt.x;
    body[2] = evt.y;
    body[3] = evt.keyCode;
    if (control) ctx->angel_sleep_delivered = evt.x;
    trace_modal_key("polled", evt.type, evt.keyCode);

    env->push_ref(runtime->stack, arr);
    return RUNTIME_STATUS_NORMAL;
}

// One event per launcher phase. Use only fixed labels and elapsed time.
static s32 n_startupPhase(Runtime *runtime, JClass *clazz) {
    int phase = localvar_getInt(runtime->localvar, 0);
    s64 elapsed = localvar_getLong(runtime->localvar, 1);
    const char *name = phase == 1 ? "manifest" : phase == 2 ? "load_class" :
                       phase == 3 ? "constructor" : phase == 4 ? "start_app" : NULL;
    if (name && elapsed >= 0) {
        char event[96];
        snprintf(event, sizeof(event), "startup_java_%s_ms=%.1f", name,
                 (double)elapsed / 1000000.0);
        jvm_bridge_note_net_trace(event);
        if ((phase == 3 || phase == 4) && runtime->jvm && runtime->jvm->session) {
            JarBoxSession *session = runtime->jvm->session;
            char image_event[160];
            snprintf(image_event, sizeof(image_event),
                     "startup_images:phase=%s,decoded=%llu,hits=%llu,decode_ms=%.1f",
                     name,
                     (unsigned long long)__atomic_load_n(&session->startup_image_decodes, __ATOMIC_RELAXED),
                     (unsigned long long)__atomic_load_n(&session->startup_image_hits, __ATOMIC_RELAXED),
                     (double)__atomic_load_n(&session->startup_image_decode_ns, __ATOMIC_RELAXED) / 1000000.0);
            jvm_bridge_note_net_trace(image_event);
            // Cumulative per-session snapshots, no per-resource log lines.
            char shared_event[384];
            snprintf(shared_event, sizeof(shared_event),
                     "startup_shared:phase=%s,zip_probes=%llu,zip_hits=%llu,zip_negative_hits=%llu,zip_hit_bytes=%llu,prepared_candidates=%llu,prepared_hits=%llu,prepared_hit_bytes=%llu",
                     name,
                     (unsigned long long)__atomic_load_n(&session->shared_zip_probes, __ATOMIC_RELAXED),
                     (unsigned long long)__atomic_load_n(&session->shared_zip_hits, __ATOMIC_RELAXED),
                     (unsigned long long)__atomic_load_n(&session->shared_zip_negative_hits, __ATOMIC_RELAXED),
                     (unsigned long long)__atomic_load_n(&session->shared_zip_hit_bytes, __ATOMIC_RELAXED),
                     (unsigned long long)__atomic_load_n(&session->shared_prepared_candidates, __ATOMIC_RELAXED),
                     (unsigned long long)__atomic_load_n(&session->shared_prepared_hits, __ATOMIC_RELAXED),
                     (unsigned long long)__atomic_load_n(&session->shared_prepared_hit_bytes, __ATOMIC_RELAXED));
            jvm_bridge_note_net_trace(shared_event);
        }
    }
    return RUNTIME_STATUS_NORMAL;
}

// Java launcher exception bridge. A failed MIDlet should display the real
// Java exception name/message rather than only "game execution failed (1)".
static s32 n_reportLaunchError(Runtime *runtime, JClass *clazz) {
    Instance *message = runtime->jnienv->localvar_getRefer(runtime->localvar, 0);
    if (message) {
        Utf8String *str = utf8_create();
        runtime->jnienv->jstring_2_utf8(message, str, runtime);
        jvm_bridge_set_launch_error(utf8_cstr(str));
        utf8_destroy(str);
    }
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Native method: NativeBridge.isStopRequested() → boolean
// ============================================================

static s32 n_isStopRequested(Runtime *runtime, JClass *clazz) {
    // A stale A Runtime reports stop even if A and B share a pointer value.
    const int stale = !jarbox_native_heap_key_for_runtime(runtime);
    push_int(runtime->stack,
             stale || jvm_bridge_is_stop_requested_for_vm(runtime->jvm) ? 1 : 0);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Event-driven Display wait. 250ms bounded timeout catches all lifecycle
// paths not wired to the input bridge (safe stop even if a signal is missed).
// ============================================================
static s32 n_displayWaitEnabled(Runtime *runtime, JClass *clazz) {
    J2MEInputContext *ctx = context_for_runtime(runtime);
    push_int(runtime->stack, display_should_wait(ctx));
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_displayWaitVersion(Runtime *runtime, JClass *clazz) {
    J2MEInputContext *ctx = context_for_runtime(runtime);
    if (!ctx) {
        push_int(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }
    pthread_mutex_lock(&ctx->display_wait_lock);
    const uint32_t seq = ctx->display_wait_sequence;
    pthread_mutex_unlock(&ctx->display_wait_lock);
    push_int(runtime->stack, (s32)seq);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_displayWaitIfUnchanged(Runtime *runtime, JClass *clazz) {
    const uint32_t seq = (uint32_t)runtime->jnienv->localvar_getInt(runtime->localvar, 0);
    int milliseconds = runtime->jnienv->localvar_getInt(runtime->localvar, 1);
    if (milliseconds < 1) milliseconds = 1;
    if (milliseconds > 250) milliseconds = 250;

    J2MEInputContext *ctx = context_for_runtime(runtime);
    if (!ctx) {
        push_int(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }
    int timedOut = 0;
    int vmBlocked = 0;
    pthread_mutex_lock(&ctx->display_wait_lock);
    if (display_should_wait(ctx) && ctx->display_wait_sequence == seq) {
        struct timespec until;
        if (clock_gettime(CLOCK_REALTIME, &until) == 0) {
            until.tv_sec += milliseconds / 1000;
            until.tv_nsec += (long)(milliseconds % 1000) * 1000000L;
            if (until.tv_nsec >= 1000000000L) {
                ++until.tv_sec;
                until.tv_nsec -= 1000000000L;
            }
            // This native call can sleep while GC runs. The miniJVM GC waits
            // for all Java threads to be suspended OR explicitly marked
            // is_blocking. Without this transition it can wait for a thread
            // which is simply sleeping in pthread_cond_timedwait(), stalling
            // VM progress and lowering the JAR's requestFrame tick rate.
            // Match jthread_sleep/jthread_waitTime and publish the state
            // BEFORE blocking. Do not read Java heap while marked blocked.
            jthread_block_enter(runtime);
            vmBlocked = 1;
            atomic_fetch_add_explicit(&g_display_gc_safe_wait_calls, 1, memory_order_relaxed);
            atomic_fetch_add_explicit(&g_display_wait_calls, 1, memory_order_relaxed);
            if (pthread_cond_timedwait(&ctx->display_wait_cond, &ctx->display_wait_lock, &until) == ETIMEDOUT) {
                atomic_fetch_add_explicit(&g_display_wait_timeouts, 1, memory_order_relaxed);
                timedOut = 1;
            }
        }
    }
    pthread_mutex_unlock(&ctx->display_wait_lock);
    // This can pause for an in-progress GC. Never hold the display
    // condition mutex while returning to the miniJVM safepoint protocol.
    if (vmBlocked) jthread_block_exit(runtime);
    push_int(runtime->stack, timedOut);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_displayWake(Runtime *runtime, JClass *clazz) {
    wake_input_context(context_for_runtime(runtime));
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Reset (call between game sessions)
// ============================================================

void j2me_input_reset(void) {
    // A visible context can still have a Java consumer. The unscoped ABI
    // cannot establish its retirement; only the owner release may reset it.
    // Intentionally fail closed.
}

static void input_quiesce_locked(J2MEInputContext *ctx) {
    if (!ctx) return;
    atomic_store_explicit(&ctx->accepting_input, 0, memory_order_release);
    if (visible_input_context() == ctx)
        atomic_store_explicit(&g_visible_input_context, NULL, memory_order_release);
    atomic_store_explicit(&ctx->display_wait_enabled, 0, memory_order_release);
    atomic_store_explicit(&ctx->angel_sleep_requested, 0, memory_order_release);
    signal_display_wait(ctx);
}
void j2me_input_quiesce_vm(MiniJVM *vm) {
    pthread_mutex_lock(&g_input_context_lock);
    input_quiesce_locked(context_for_vm(vm));
    pthread_mutex_unlock(&g_input_context_lock);
}
static void input_release_locked(J2MEInputContext *ctx) {
    if (!ctx) return;
    input_quiesce_locked(ctx);
    jarbox_input_ring_reset(&ctx->ring);
    ctx->heap_key = 0;
    ctx->session_token = 0;
    atomic_store_explicit(&ctx->vm, NULL, memory_order_release);
}
void j2me_input_release_for_token(uint64_t token) {
    if (!token) return;
    pthread_mutex_lock(&g_input_context_lock);
    for (int i = 0; i < JARBOX_INPUT_CONTEXT_CAPACITY; ++i) {
        J2MEInputContext *ctx = &g_input_contexts[i];
        if (ctx->session_token == token) {
            input_release_locked(ctx);
            break;
        }
    }
    pthread_mutex_unlock(&g_input_context_lock);
}

// Startup rollback only, before a MIDlet or Java input consumer has started.
void j2me_input_release_vm(MiniJVM *vm) {
    pthread_mutex_lock(&g_input_context_lock);
    input_release_locked(context_for_vm(vm));
    pthread_mutex_unlock(&g_input_context_lock);
}

// ============================================================
// Native method table
// ============================================================

#define CLS "javax/microedition/lcdui/NativeBridge"

static java_native_method j2me_input_methods[] = {
    {CLS, "pollInputEvent", "()[I", n_pollInputEvent},
    {CLS, "isStopRequested", "()Z", n_isStopRequested},
    {CLS, "reportLaunchError", "(Ljava/lang/String;)V", n_reportLaunchError},
    {CLS, "startupPhase", "(IJ)V", n_startupPhase},
    {CLS, "displayWaitEnabled", "()Z", n_displayWaitEnabled},
    {CLS, "displayWaitVersion", "()I", n_displayWaitVersion},
    {CLS, "displayWaitIfUnchanged", "(II)I", n_displayWaitIfUnchanged},
    {CLS, "displayWake", "()V", n_displayWake},
};

#undef CLS

int j2me_input_reg_natives(MiniJVM *jvm) {
    if (!bind_input_context(jvm)) {
        printf("[J2ME Input] ERROR: no free per-JVM input context\n");
        return 0;
    }
    native_reg_lib(jvm, j2me_input_methods,
                   sizeof(j2me_input_methods) / sizeof(java_native_method));
    printf("[J2ME Input] Registered %lu native methods for owned JVM\n",
           sizeof(j2me_input_methods) / sizeof(java_native_method));
    return 1;
}
