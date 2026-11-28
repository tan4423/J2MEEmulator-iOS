

#ifndef _GARBAGE_H
#define _GARBAGE_H

#include "../utils/hashtable.h"
#include "../utils/hashset.h"
#include "../utils/linkedlist.h"
#include "jvm.h"
#include "jvm_util.h"
#include "jarbox_runtime_generation.h"
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
#include "jarbox_gc_deferred_index.h"
#endif


#ifdef __cplusplus
extern "C" {
#endif


// GC thread entities


// Each thread has its own garbage bin; too many threads would be a disaster.
struct _GcCollectorType {
    MiniJVM *jvm;

    // A lawless zone, a holder that prevents garbage collection.
    // Objects placed in it and other objects they reference will not be collected.
    Hashset *objs_holder;
    MemoryBlock *header, *tmp_header, *tmp_tailer;
    s64 obj_count;
    s64 obj_heap_size;
    // Last existing GC heap measurement + 1 (zero means not sampled).
    // Read atomically under a native session callback lease.
    uint64_t jarbox_status_heap_sample;
    // Identity/epoch invalidate thread-local weak String lookup caches when
    // a VM is recreated or a successful stop-the-world collection reclaims objects.
    uint64_t string_cache_identity;
    uint64_t string_cache_epoch;
    s64 lastgc;//last gc at mills
    Runtime *runtime;
    //

    //
    thrd_t garbage_thread;// Garbage collection thread
    int garbage_thread_started; // bootstrap owner only; join exactly once
    Hashtable *objs_2_count;

    spinlock_t lock;
    //
    ArrayList *runtime_refer_copy;
    //
    u8 _garbage_thread_status;
    u8 mark_cnt;
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
    JarBoxGCDeferredIndex deferred_index;
#if __JVM_OS_IOS__
    unsigned deferred_index_admitted,deferred_index_peak;
    uint64_t deferred_index_passes,deferred_index_entries;
#endif
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    uint64_t host_gc_index_passes;
    uint64_t host_gc_index_large_snapshots, host_gc_index_omitted;
    uint64_t host_gc_deferred_visits, host_gc_finalizers, host_gc_weak_callbacks;
#endif
#endif
    volatile u8 isgc;
    volatile u8 isworldstoped;
    s16 exit_flag;
    s16 exit_code;
};

enum {
    GARBAGE_THREAD_NORMAL,
    GARBAGE_THREAD_PAUSE,
    GARBAGE_THREAD_STOP,
    GARBAGE_THREAD_DEAD,
};

/* STOP and DEAD are terminal for external control requests. The collector
 * publishes DEAD itself after its final heap access. All readers use atomic
 * loads, including Java diagnostics that do not own vm_share_lock. */
static inline u8 gc_thread_status(const GcCollector *collector) {
    return __atomic_load_n(&collector->_garbage_thread_status, __ATOMIC_ACQUIRE);
}
static inline void gc_request_thread_status(GcCollector *collector, u8 requested) {
    u8 current = gc_thread_status(collector);
    while (current < GARBAGE_THREAD_STOP &&
           !__atomic_compare_exchange_n(&collector->_garbage_thread_status,
                                        &current, requested, 0,
                                        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) {}
}

// API

s32 gc_create(MiniJVM *jvm);
s32 gc_start(GcCollector *collector);

void gc_destroy(MiniJVM *jvm);

void gc_stop(GcCollector *collector);

void gc_pause(GcCollector *collector);

void gc_resume(GcCollector *collector);

MemoryBlock *gc_is_alive(GcCollector *collector, __refer obj);

void gc_obj_hold(GcCollector *collector, __refer ref);

void gc_obj_release(GcCollector *collector, __refer ref);

void gc_obj_reg(Runtime *runtime, __refer ref);

void gc_move_objs_thread_2_gc(Runtime *runtime);

void gc_dump_runtime(GcCollector *collector);

s64 gc_sum_heap(GcCollector *collector);

// Native CoreGraphics allocation ownership, independent of JVM heap storage.
// A generation key is retained by each native handle, so a late release from
// an old session cannot debit a newly allocated JVM at the same address.
// Register only after jvm_init; unregister after native render cleanup.
int jarbox_native_heap_register_vm(MiniJVM *jvm);
uint64_t jarbox_native_heap_key_for_vm(MiniJVM *jvm);
uint64_t jarbox_native_heap_validate_key(MiniJVM *jvm, uint64_t key);
// The original key belongs to the JavaThreadInfo, not to a recycled JVM
// pointer or whichever session happens to occupy an input/UI slot now.
static inline uint64_t jarbox_native_heap_key_for_runtime(const Runtime *runtime) {
    if (!runtime || !runtime->jvm || !runtime->thrd_info) return 0;
    const uint64_t original = runtime->thrd_info->jarbox_native_generation;
    return jarbox_native_heap_validate_key(runtime->jvm, original);
}
void jarbox_native_heap_account(uint64_t key, s64 delta_bytes);
s64 jarbox_native_heap_for_vm(MiniJVM *jvm);
void jarbox_native_heap_unregister_vm(MiniJVM *jvm);
/// Retire only the generation captured before destroying the Java heap.
void jarbox_native_heap_unregister_key(uint64_t key);
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
// Called by the existing renderer mode switch. Tracks current JVM GC cadence
// only; the renderer mode itself still needs separate per-VM ownership.
void treo_gc_set_afk_mode_for_current(int mode);
#endif


#ifdef __cplusplus
}
#endif

#endif //_GARBAGE_H
