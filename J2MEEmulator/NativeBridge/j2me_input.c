//
// j2me_input.c — Thread-safe input event bridge between iOS and miniJVM
//
// Uses a lock-free ring buffer for single-producer (iOS main thread)
// single-consumer (JVM thread) communication.
//

#include "j2me_input.h"
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

#define INPUT_QUEUE_SIZE 256
#define INPUT_QUEUE_MASK (INPUT_QUEUE_SIZE - 1)

typedef struct {
    int type;
    int x, y;
    int keyCode;
} InputEvent;

static InputEvent g_queue[INPUT_QUEUE_SIZE];
static atomic_int g_write_pos = 0;
static atomic_int g_read_pos = 0;

// Opt-in Display idle wait. Version sampling before polling prevents lost
// native input and repaint notifications between the Java test and sleep.
static atomic_int g_display_wait_enabled;
static pthread_mutex_t g_display_wait_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_display_wait_cond = PTHREAD_COND_INITIALIZER;
static uint32_t g_display_wait_sequence = 1;
static _Atomic uint64_t g_display_poll_calls;
static _Atomic uint64_t g_display_wait_calls;
static _Atomic uint64_t g_display_gc_safe_wait_calls;
static _Atomic uint64_t g_display_wait_timeouts;
static _Atomic uint64_t g_display_wake_signals;

static void signal_display_wait(void) {
    pthread_mutex_lock(&g_display_wait_lock);
    ++g_display_wait_sequence;
    pthread_cond_broadcast(&g_display_wait_cond);
    pthread_mutex_unlock(&g_display_wait_lock);
}
void j2me_display_wake(void) {
    if (atomic_load_explicit(&g_display_wait_enabled, memory_order_acquire)) {
        atomic_fetch_add_explicit(&g_display_wake_signals, 1, memory_order_relaxed);
        signal_display_wait();
    }
}
void treo_display_wait_set(int enabled) {
    atomic_store_explicit(&g_display_wait_enabled, enabled != 0, memory_order_release);
    // Also wake when disabled, so a pending native timed wait ends now.
    signal_display_wait();
}
uint64_t treo_display_poll_calls(void) { return atomic_load_explicit(&g_display_poll_calls, memory_order_relaxed); }
uint64_t treo_display_wait_calls(void) { return atomic_load_explicit(&g_display_wait_calls, memory_order_relaxed); }
uint64_t treo_display_gc_safe_wait_calls(void) { return atomic_load_explicit(&g_display_gc_safe_wait_calls, memory_order_relaxed); }
uint64_t treo_display_wait_timeouts(void) { return atomic_load_explicit(&g_display_wait_timeouts, memory_order_relaxed); }
uint64_t treo_display_wake_signals(void) { return atomic_load_explicit(&g_display_wake_signals, memory_order_relaxed); }


static int g_canvas_width = 240;
static int g_canvas_height = 320;

void j2me_input_set_canvas_size(int width, int height) {
    g_canvas_width = width;
    g_canvas_height = height;
}

static void enqueue_event(int type, int x, int y, int keyCode) {
    int wp = atomic_load_explicit(&g_write_pos, memory_order_relaxed);
    int next_wp = (wp + 1) & INPUT_QUEUE_MASK;
    int rp = atomic_load_explicit(&g_read_pos, memory_order_acquire);

    if (next_wp == rp) {
        // Queue full — drop event
        return;
    }

    g_queue[wp].type = type;
    g_queue[wp].x = x;
    g_queue[wp].y = y;
    g_queue[wp].keyCode = keyCode;

    atomic_store_explicit(&g_write_pos, next_wp, memory_order_release);
    j2me_display_wake();
}

static int dequeue_event(InputEvent *out) {
    int rp = atomic_load_explicit(&g_read_pos, memory_order_relaxed);
    int wp = atomic_load_explicit(&g_write_pos, memory_order_acquire);

    if (rp == wp) {
        return 0; // Empty
    }

    *out = g_queue[rp];
    atomic_store_explicit(&g_read_pos, (rp + 1) & INPUT_QUEUE_MASK, memory_order_release);
    return 1;
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
    InputEvent evt;

    if (!dequeue_event(&evt)) {
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
    push_int(runtime->stack, jvm_bridge_is_stop_requested() ? 1 : 0);
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Event-driven Display wait. 250ms bounded timeout catches all lifecycle
// paths not wired to the input bridge (safe stop even if a signal is missed).
// ============================================================
static s32 n_displayWaitEnabled(Runtime *runtime, JClass *clazz) {
    push_int(runtime->stack, atomic_load_explicit(&g_display_wait_enabled, memory_order_acquire) != 0);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_displayWaitVersion(Runtime *runtime, JClass *clazz) {
    pthread_mutex_lock(&g_display_wait_lock);
    const uint32_t seq = g_display_wait_sequence;
    pthread_mutex_unlock(&g_display_wait_lock);
    push_int(runtime->stack, (s32)seq);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_displayWaitIfUnchanged(Runtime *runtime, JClass *clazz) {
    const uint32_t seq = (uint32_t)runtime->jnienv->localvar_getInt(runtime->localvar, 0);
    int milliseconds = runtime->jnienv->localvar_getInt(runtime->localvar, 1);
    if (milliseconds < 1) milliseconds = 1;
    if (milliseconds > 250) milliseconds = 250;

    int timedOut = 0;
    int vmBlocked = 0;
    pthread_mutex_lock(&g_display_wait_lock);
    if (atomic_load_explicit(&g_display_wait_enabled, memory_order_acquire)
        && g_display_wait_sequence == seq) {
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
            if (pthread_cond_timedwait(&g_display_wait_cond, &g_display_wait_lock, &until) == ETIMEDOUT) {
                atomic_fetch_add_explicit(&g_display_wait_timeouts, 1, memory_order_relaxed);
                timedOut = 1;
            }
        }
    }
    pthread_mutex_unlock(&g_display_wait_lock);
    // This can pause for an in-progress GC. Never hold the display
    // condition mutex while returning to the miniJVM safepoint protocol.
    if (vmBlocked) jthread_block_exit(runtime);
    push_int(runtime->stack, timedOut);
    return RUNTIME_STATUS_NORMAL;
}
static s32 n_displayWake(Runtime *runtime, JClass *clazz) {
    j2me_display_wake();
    return RUNTIME_STATUS_NORMAL;
}

// ============================================================
// Reset (call between game sessions)
// ============================================================

void j2me_input_reset(void) {
    treo_display_wait_set(0);
    atomic_store_explicit(&g_write_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&g_read_pos, 0, memory_order_relaxed);
    printf("[J2ME Input] Ring buffer reset\n");
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

void j2me_input_reg_natives(MiniJVM *jvm) {
    native_reg_lib(jvm, j2me_input_methods,
                   sizeof(j2me_input_methods) / sizeof(java_native_method));
    printf("[J2ME Input] Registered %lu native methods\n",
           sizeof(j2me_input_methods) / sizeof(java_native_method));
}
