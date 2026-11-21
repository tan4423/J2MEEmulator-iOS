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
#define JARBOX_INPUT_CONTEXT_CAPACITY 4
typedef struct {
    _Atomic(MiniJVM *) vm;
    JarBoxInputRing ring;
    atomic_int display_wait_enabled;
    pthread_mutex_t display_wait_lock;
    pthread_cond_t display_wait_cond;
    uint32_t display_wait_sequence;
    int canvas_width, canvas_height;
} J2MEInputContext;

static J2MEInputContext g_input_contexts[JARBOX_INPUT_CONTEXT_CAPACITY];
static pthread_once_t g_input_context_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_input_context_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(J2MEInputContext *) g_visible_input_context;

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

static J2MEInputContext *visible_input_context(void) {
    return atomic_load_explicit(&g_visible_input_context, memory_order_acquire);
}

// Called when a new JVM's native methods are registered. A bound JVM never
// receives input events belonging to any other bound JVM.
static int bind_input_context(MiniJVM *vm) {
    if (!vm) return 0;
    pthread_once(&g_input_context_once, init_input_contexts);
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = context_for_vm(vm);
    if (!ctx) {
        for (int i = 0; i < JARBOX_INPUT_CONTEXT_CAPACITY; ++i) {
            J2MEInputContext *candidate = &g_input_contexts[i];
            if (!atomic_load_explicit(&candidate->vm, memory_order_acquire)) {
                ctx = candidate;
                jarbox_input_ring_reset(&ctx->ring);
                atomic_store_explicit(&ctx->display_wait_enabled, 0, memory_order_relaxed);
                ctx->canvas_width = 240;
                ctx->canvas_height = 320;
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
    if (ctx) atomic_store_explicit(&g_visible_input_context, ctx, memory_order_release);
    pthread_mutex_unlock(&g_input_context_lock);
    return ctx != NULL;
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
static void wake_input_context(J2MEInputContext *ctx) {
    if (!ctx) return;
    if (atomic_load_explicit(&ctx->display_wait_enabled, memory_order_acquire)) {
        atomic_fetch_add_explicit(&g_display_wake_signals, 1, memory_order_relaxed);
        signal_display_wait(ctx);
    }
}
void j2me_display_wake(void) {
    wake_input_context(visible_input_context());
}
void treo_display_wait_set(int enabled) {
    J2MEInputContext *ctx = visible_input_context();
    if (!ctx) return;
    atomic_store_explicit(&ctx->display_wait_enabled, enabled != 0, memory_order_release);
    // Also wake when disabled, so a pending native timed wait ends now.
    signal_display_wait(ctx);
}
uint64_t treo_display_poll_calls(void) { return atomic_load_explicit(&g_display_poll_calls, memory_order_relaxed); }
uint64_t treo_display_wait_calls(void) { return atomic_load_explicit(&g_display_wait_calls, memory_order_relaxed); }
uint64_t treo_display_gc_safe_wait_calls(void) { return atomic_load_explicit(&g_display_gc_safe_wait_calls, memory_order_relaxed); }
uint64_t treo_display_wait_timeouts(void) { return atomic_load_explicit(&g_display_wait_timeouts, memory_order_relaxed); }
uint64_t treo_display_wake_signals(void) { return atomic_load_explicit(&g_display_wake_signals, memory_order_relaxed); }


void j2me_input_set_canvas_size(int width, int height) {
    J2MEInputContext *ctx = visible_input_context();
    if (!ctx) return;
    ctx->canvas_width = width;
    ctx->canvas_height = height;
}

static void enqueue_event(int type, int x, int y, int keyCode) {
    J2MEInputContext *ctx = visible_input_context();
    if (!ctx) return;
    const JarBoxInputEvent event = {type, x, y, keyCode};
    if (!jarbox_input_ring_push(&ctx->ring, &event)) {
        // A full queue is a real drop, never an invented replacement key.
        trace_modal_key("drop", type, keyCode);
        return;
    }
    trace_modal_key("post", type, keyCode);
    wake_input_context(ctx);
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

void j2me_input_post_key(int type, int keyCode) {
    enqueue_event(type, 0, 0, keyCode);
}

// ============================================================
// Native method: NativeBridge.pollInputEvent() → int[] or null
// Returns int[4]: {type, x, y, keyCode}
// ============================================================

static s32 n_pollInputEvent(Runtime *runtime, JClass *clazz) {
    atomic_fetch_add_explicit(&g_display_poll_calls, 1, memory_order_relaxed);
    JniEnv *env = runtime->jnienv;
    JarBoxInputEvent evt;

    if (!dequeue_event(context_for_vm(runtime->jvm), &evt)) {
        env->push_ref(runtime->stack, NULL);
        return RUNTIME_STATUS_NORMAL;
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
    trace_modal_key("polled", evt.type, evt.keyCode);

    env->push_ref(runtime->stack, arr);
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
    push_int(runtime->stack, jvm_bridge_is_stop_requested_for_vm(runtime->jvm) ? 1 : 0);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Event-driven Display wait. 250ms bounded timeout catches all lifecycle
// paths not wired to the input bridge (safe stop even if a signal is missed).
// ============================================================
static s32 n_displayWaitEnabled(Runtime *runtime, JClass *clazz) {
    J2MEInputContext *ctx = context_for_vm(runtime->jvm);
    push_int(runtime->stack, ctx &&
        atomic_load_explicit(&ctx->display_wait_enabled, memory_order_acquire));
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_displayWaitVersion(Runtime *runtime, JClass *clazz) {
    J2MEInputContext *ctx = context_for_vm(runtime->jvm);
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

    J2MEInputContext *ctx = context_for_vm(runtime->jvm);
    if (!ctx) {
        push_int(runtime->stack, 0);
        return RUNTIME_STATUS_NORMAL;
    }
    int timedOut = 0;
    int vmBlocked = 0;
    pthread_mutex_lock(&ctx->display_wait_lock);
    if (atomic_load_explicit(&ctx->display_wait_enabled, memory_order_acquire)
        && ctx->display_wait_sequence == seq) {
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
    wake_input_context(context_for_vm(runtime->jvm));
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Reset (call between game sessions)
// ============================================================

void j2me_input_reset(void) {
    J2MEInputContext *ctx = visible_input_context();
    if (!ctx) return;
    atomic_store_explicit(&ctx->display_wait_enabled, 0, memory_order_release);
    signal_display_wait(ctx);
    jarbox_input_ring_reset(&ctx->ring);
    printf("[J2ME Input] Ring buffer reset for current JVM\n");
}

// Call during owning JVM teardown after stopping its Java threads. Stop and
// wake only *this* context; no other JVM input queue or wait may be reset.
void j2me_input_release_vm(MiniJVM *vm) {
    pthread_mutex_lock(&g_input_context_lock);
    J2MEInputContext *ctx = context_for_vm(vm);
    if (ctx) {
        atomic_store_explicit(&ctx->display_wait_enabled, 0, memory_order_release);
        signal_display_wait(ctx);
        if (visible_input_context() == ctx)
            atomic_store_explicit(&g_visible_input_context, NULL, memory_order_release);
        atomic_store_explicit(&ctx->vm, NULL, memory_order_release);
        jarbox_input_ring_reset(&ctx->ring);
        printf("[J2ME Input] Released owned JVM input context\n");
    }
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
