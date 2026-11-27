#include <errno.h>
#include <stdint.h>
#include <time.h>
#include "jvm.h"
#include "garbage.h"
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
#include "../../NativeBridge/jvm_bridge.h"
#endif
#include "jvm_util.h"

s32 _gc_thread_run(void *para);

void _dump_refer(GcCollector *collector);

void _gc_get_obj_name(GcCollector *collector, void *memblock, Utf8String *name);

void _garbage_clear(GcCollector *collector);

s32 _gc_copy_objs(MiniJVM *jvm);

s32 _gc_big_search(GcCollector *collector);

s32 _gc_pause_the_world(MiniJVM *jvm);

s32 _gc_resume_the_world(MiniJVM *jvm);

s32 _gc_wait_thread_suspend(MiniJVM *jvm, Runtime *runtime);

void _gc_mark_object(GcCollector *collector, __refer ref, u8 flag_cnt);

s32 _gc_copy_objs_from_thread(Runtime *pruntime);

s64 _garbage_collect(GcCollector *collector);

void _gc_print_obj_list(GcCollector *pType);

/**
 * Creates a garbage collection thread.
 *
 * The collection method works as follows:
 * When an object is created, it is registered with the garbage collector and included in its monitoring system.
 *
 * The objects registered include:
 * - Class objects
 * - Instance objects (including array objects)
 *
 * During garbage collection, the garbage collection thread collects objects from the `collector->header` linked list.
 * The collection process involves marking objects that are not referenced by any thread, directly destroying them,
 * and freeing their memory.
 *
 * The garbage collection thread will pause all currently executing Java threads. Once collection is complete,
 * the paused threads are resumed.
 *
 * Runtime objects in the JDWP debugging thread are not eligible for garbage collection.
 *
 * Collection steps:
 *
 * 1. Stop the world (pause all Java threads).
 * 2. Add all register/hold/release operations to a temporary linked list.
 * 3. Copy all runtime references.
 * 4. Mark objects referenced by threads.
 * 5. Resume the world (resume all Java threads).
 * 6. Release the memory of unmarked objects.
 * 7. Move the temporary linked list back to the main list.
 *
 * @return Error code
 */



s32 gc_create(MiniJVM *jvm) {
    GcCollector *collector = jvm_calloc(sizeof(GcCollector));
    jvm->collector = collector;
    collector->jvm = jvm;
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    collector->deferred_index.disabled = !jvm->host_gc_index_enabled;
#elif __JVM_OS_IOS__ && defined(TREO_RESIDUAL_EXPERIMENT) && TREO_RESIDUAL_EXPERIMENT
    // The bridge verifies the exact Nick archive and packaged boot/API
    // before jvm_init. Index from the first heap batch, never enable it
    // halfway through a populated heap or on a foreign archive.
    collector->deferred_index.disabled = !jvm->session || jvm->jdwp_enable ||
        !__atomic_load_n(&jvm->session->treo_state.residual_archive_verified,__ATOMIC_ACQUIRE);
    collector->deferred_index_admitted = !collector->deferred_index.disabled;
#else
    collector->deferred_index.disabled = 1;
#endif
#endif
    collector->objs_holder = hashset_create();
    collector->objs_2_count = hashtable_create(UNICODE_STR_HASH_FUNC, UNICODE_STR_EQUALS_FUNC);

    collector->runtime_refer_copy = arraylist_create(256);

    collector->runtime = runtime_create(jvm);
    collector->runtime->thrd_info->type = THREAD_TYPE_GC;
    gc_request_thread_status(collector, GARBAGE_THREAD_PAUSE);
    thread_lock_init(&jvm->threadlock);

    collector->lastgc = currentTimeMillis();

    return 0;
}

s32 gc_start(GcCollector *collector) {
    // Only the bootstrap owner starts this thread, once the Java core is ready.
    if (collector->garbage_thread_started ||
        gc_thread_status(collector) >= GARBAGE_THREAD_STOP) return -1;
    gc_resume(collector);
    s32 rc = thrd_create(&collector->garbage_thread, _gc_thread_run, collector);
    if (rc != thrd_success) {
        jvm_printf("ERROR: garbage thread can't create is %d\n", rc);
        __atomic_store_n(&collector->_garbage_thread_status, GARBAGE_THREAD_DEAD, __ATOMIC_RELEASE);
        return -1;
    }
    collector->garbage_thread_started = 1;
    return 0;
}

void gc_destroy(MiniJVM *jvm) {
    GcCollector *collector = jvm->collector;
    if (collector->garbage_thread_started) {
        gc_stop(collector);
        // Join without holding the VM-share lock; the collector may need it
        // to leave an interrupted stop-the-world cycle.
        if (thrd_join(collector->garbage_thread, NULL) != thrd_success) {
            jvm_printf("[WARN] GC join failed; waiting for final heap access\n");
            vm_share_lock(jvm);
            while (gc_thread_status(collector) != GARBAGE_THREAD_DEAD) {
                vm_share_timedwait(jvm, 100);
            }
            vm_share_unlock(jvm);
        }
    } else {
        // Bootstrap failed or was cancelled before a collector was started.
        // No worker can access this heap, so do not wait for a DEAD signal.
        __atomic_store_n(&collector->_garbage_thread_status, GARBAGE_THREAD_DEAD, __ATOMIC_RELEASE);
    }
    //
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
    // Worker joined (or never started); terminal cleanup uses the old path.
#if __JVM_OS_IOS__
    jvm_printf("[JarBoxVM][GCIndex] admitted=%u indexed_passes=%llu candidate_entries=%llu peak_entries=%u disabled=%d\n",
        collector->deferred_index_admitted,
        (unsigned long long)collector->deferred_index_passes,
        (unsigned long long)collector->deferred_index_entries,
        collector->deferred_index_peak,collector->deferred_index.disabled);
#endif
    gc_deferred_index_disable(&collector->deferred_index);
#endif
    _garbage_clear(collector);
    //
    hashset_destroy(collector->objs_holder);
    collector->objs_holder = NULL;

    arraylist_destroy(collector->runtime_refer_copy);
    hashtable_destroy(collector->objs_2_count);

    //
    runtime_destroy(collector->runtime);
    jvm_free(collector);
    jvm->collector = NULL;
}


// Negative collection results retain the heap. During terminal cleanup
// do not busy-loop on a failed snapshot or free an incompletely scanned heap.
static void gc_clear_until_empty(GcCollector *collector) {
    for (;;) {
        s64 result = _garbage_collect(collector);
        if (result == 0) return;
        if (result < 0) threadSleep(100);
    }
}

void _garbage_clear(GcCollector *collector) {
#if _JVM_DEBUG_LOG_LEVEL > 1
    jvm_printf("[INFO]garbage clear start\n");
    jvm_printf("[INFO]objs size :%lld\n", collector->obj_count);
#endif
    MiniJVM *jvm = collector->jvm;

    //After all references are removed, all objects are collected
    gc_clear_until_empty(collector);//collect instance

#if _JVM_DEBUG_LOG_LEVEL > 1
    jvm_printf("[INFO]objs size :%lld\n", collector->obj_count);
    jvm_printf("[INFO]clear class static field \n");
#endif
    hashset_clear(collector->objs_holder);
    classloaders_clear_all_static(jvm);
    gc_clear_until_empty(collector);//collect classes

#if _JVM_DEBUG_LOG_LEVEL > 1
    jvm_printf("[INFO]objs size :%lld\n", collector->obj_count);
    jvm_printf("[INFO]clear boot classes \n");
#endif
    classloader_remove_all_class(jvm->boot_classloader);
    gc_clear_until_empty(collector);//collect classes
    classloaders_destroy_all(jvm);

    //
#if _JVM_DEBUG_LOG_LEVEL > 1
    jvm_printf("[INFO]objs size :%lld\n", collector->obj_count);
#endif
    //dump_refer();
}


void gc_pause(GcCollector *collector) {
    vm_share_lock(collector->jvm);
    gc_request_thread_status(collector, GARBAGE_THREAD_PAUSE);
    vm_share_unlock(collector->jvm);
}

void gc_resume(GcCollector *collector) {
    vm_share_lock(collector->jvm);
    gc_request_thread_status(collector, GARBAGE_THREAD_NORMAL);
    vm_share_unlock(collector->jvm);
}

void gc_stop(GcCollector *collector) {
    vm_share_lock(collector->jvm);
    gc_request_thread_status(collector, GARBAGE_THREAD_STOP);
    vm_share_unlock(collector->jvm);
}

//===============================   inner  ====================================
void _gc_add_obj_count(GcCollector *collector, MemoryBlock *mb) {
    if (mb->type == MEM_TYPE_CLASS) {
        return;
    }
    if (gc_thread_status(collector) != GARBAGE_THREAD_NORMAL) {
        return;
    }
    if (utf8_equals_c(mb->clazz->name, "javax/microedition/lcdui/Display$SerialCallTimerTask")) {
        s32 debug = 1;
    }
    HashtableValue v = hashtable_get(collector->objs_2_count, mb->clazz->name);
    if (!v) {
        s64 count = 1;
        if (sizeof(void *) == 8) {
            count = count << 32;
            count = count | mb->heap_size;
        }
        hashtable_put(collector->objs_2_count, mb->clazz->name, (HashtableValue) (intptr_t) count);
    } else {
        s64 val = (s64) (intptr_t) v;
        if (sizeof(void *) == 8) {
            s32 pc = (s32) (val >> 32);
            s32 msize = (s32) val;
            pc++;
            val = ((s64) pc) << 32;
            msize += mb->heap_size;
            val = val | msize;
        } else {
            val++;
        }
        hashtable_put(collector->objs_2_count, mb->clazz->name, (HashtableValue) (intptr_t) val);
    }
}


void _gc_print_obj_list(GcCollector *collector) {
    jvm_printf("[INFO]--------------------------types: %d\n", collector->objs_2_count->entries);
    jvm_printf("[INFO] -----count----- ---memo size---  ----name---\n");
    HashtableIterator hti;
    hashtable_iterate(collector->objs_2_count, &hti);
    for (; hashtable_iter_has_more(&hti);) {
        Utf8String *clsName = hashtable_iter_next_key(&hti);
        if (utf8_equals_c(clsName, "javax/microedition/lcdui/Display$SerialCallTimerTask")) {
            s32 debug = 1;
        }
        s64 val = (s64) (intptr_t) hashtable_get(collector->objs_2_count, clsName);
        s32 pc = 0, msize = 0;
        if (sizeof(void *) == 8) {
            pc = (s32) (val >> 32);
            msize = (s32) val;
        } else {
            pc = (s32) val;
        }
        jvm_printf("[INFO] %15d %15d  %s\n", pc, msize, utf8_cstr(clsName));
        //utf8_destroy(clsName);
    }
    hashtable_clear(collector->objs_2_count);
    jvm_printf("[INFO]--------------------------\n");
}
//=============================   debug ===================================

void _gc_get_obj_name(GcCollector *collector, void *memblock, Utf8String *name) {

    MemoryBlock *mb = (MemoryBlock *) memblock;
    if (!mb) {
        utf8_append_c(name, "NULL");
    } else {
        switch (mb->type) {
            case MEM_TYPE_CLASS: {
                utf8_append_c(name, "C");
                JClass *clazz = gc_thread_status(collector) == GARBAGE_THREAD_NORMAL ? (JClass *) mb : NULL;
                if (clazz)
                    utf8_append(name, clazz->name);
                break;
            }
            case MEM_TYPE_INS: {
                Instance *ins = (Instance *) mb;
                utf8_append_c(name, "L");
                JClass *clazz = gc_thread_status(collector) == GARBAGE_THREAD_NORMAL ? ins->mb.clazz : NULL;
                if (clazz)
                    utf8_append(name, clazz->name);
                utf8_append_c(name, ";");
                break;
            }
            case MEM_TYPE_ARR: {
                Instance *arr = (Instance *) mb;

                utf8_append_c(name, "Array{");
                JClass *clazz = gc_thread_status(collector) == GARBAGE_THREAD_NORMAL ? arr->mb.clazz : NULL;
                if (clazz)
                    utf8_append(name, clazz->name);
                utf8_append_c(name, "}");
                break;
            }
            default:
                utf8_append_c(name, "ERROR");
        }
    }
}


s32 _getMBSize(MemoryBlock *mb) {
    return mb->heap_size;
}

/**
 * For debugging: Print all reference information
 */
void _dump_refer(GcCollector *collector) {
    //jvm_printf("%d\n",sizeof(struct _Hashset));
    MemoryBlock *mb = collector->tmp_header;
    while (mb) {
        Utf8String *name = utf8_create();
        _gc_get_obj_name(collector, mb, name);
        jvm_printf("   %s[%llx] \n", utf8_cstr(name), (s64) (intptr_t) mb);
        utf8_destroy(name);
        mb = mb->next;
    }
}

void gc_dump_runtime(GcCollector *collector) {
    s32 i;
    //jvm_printf("thread set size:%d\n", thread_list->length);
    Utf8String *name = utf8_create();
    for (i = 0; i < collector->jvm->thread_list->length; i++) {
        Runtime *runtime = threadlist_get(collector->jvm, i);

        jvm_printf("[INFO]============ runtime dump [%llx] ============\n", (s64) (intptr_t) runtime);
        s32 j;
        StackEntry *entry;
        RuntimeStack *stack = runtime->stack;
        for (j = 0; j < stack_size(stack); j++) {
            entry = stack->store + j;
            if (entry->rvalue) {
                __refer ref = entry->rvalue;
                if (ref) {
                    utf8_clear(name);
                    _gc_get_obj_name(collector, ref, name);
                    jvm_printf("   %s[%llx] \n", utf8_cstr(name), (s64) (intptr_t) ref);
                    utf8_destroy(name);
                }
            }
        }

    }
}


// The collector reads its own JVM's TreoState. UIKit's existing no-arg
// controls visit only the current RUNNING VM while the bridge lifecycle lock
// protects its allocation. No JVM reads another JVM's GC mode or statistics.
// Thresholds / 250ms pressure checks / Deep Treo fallback remain unchanged.
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
static void treo_probe_set_active(MiniJVM *vm, void *arg) {
    jarbox_treo_probe_set(&vm->session->treo_state, *(int *)arg);
}
void treo_gc_probe_set_period_ms(int requested) {
    jvm_bridge_visit_running_vm(treo_probe_set_active, &requested);
}
static void treo_smart_set_active(MiniJVM *vm, void *arg) {
    jarbox_treo_smart_set(&vm->session->treo_state, *(int *)arg);
}
void treo_gc_smart_set(int enabled) {
    jvm_bridge_visit_running_vm(treo_smart_set_active, &enabled);
}
int treo_gc_smart_set_for_token(uint64_t token, int enabled) {
    return jvm_bridge_visit_running_vm_for_token(token, treo_smart_set_active,
                                                  &enabled);
}
static void treo_force_safe_active(MiniJVM *vm, void *arg) {
    (void)arg;
    jarbox_treo_smart_force_safe(&vm->session->treo_state);
    if (jarbox_treo_probe_period(&vm->session->treo_state) > 0)
        jarbox_treo_probe_fallback(&vm->session->treo_state);
}
void treo_gc_smart_force_safe(void) {
    jvm_bridge_visit_running_vm(treo_force_safe_active, NULL);
}
int treo_gc_smart_force_safe_for_token(uint64_t token) {
    return jvm_bridge_visit_running_vm_for_token(token, treo_force_safe_active, NULL);
}
static void treo_afk_mode_active(MiniJVM *vm, void *arg) {
    jarbox_treo_mode_set(&vm->session->treo_state, *(int *)arg);
}
void treo_gc_set_afk_mode_for_current(int mode) {
    jvm_bridge_visit_running_vm(treo_afk_mode_active, &mode);
}
typedef struct {
    int probe_ms, smart_fallback, smart_period;
    uint64_t probe_peak, probe_fallbacks, smart_peak, smart_cycles, smart_cpu;
} TreoGCSnapshot;
static void treo_gc_snapshot_active(MiniJVM *vm, void *arg) {
    TreoGCSnapshot *s = (TreoGCSnapshot *)arg;
    JarBoxTreoState *t = &vm->session->treo_state;
    s->probe_ms = jarbox_treo_probe_period(t);
    s->probe_peak = __atomic_load_n(&t->probe_heap_peak, __ATOMIC_ACQUIRE);
    s->probe_fallbacks = __atomic_load_n(&t->probe_fallback_count, __ATOMIC_ACQUIRE);
    s->smart_fallback = __atomic_load_n(&t->smart_fallback, __ATOMIC_ACQUIRE);
    s->smart_period = jarbox_treo_smart_period(t);
    s->smart_peak = __atomic_load_n(&t->smart_heap_peak, __ATOMIC_ACQUIRE);
    s->smart_cycles = __atomic_load_n(&t->smart_cycles, __ATOMIC_ACQUIRE);
    s->smart_cpu = __atomic_load_n(&t->smart_cpu_ns, __ATOMIC_ACQUIRE);
}
static TreoGCSnapshot treo_gc_snapshot(void) {
    TreoGCSnapshot s = {0};
    s.smart_period = 500;
    jvm_bridge_visit_running_vm(treo_gc_snapshot_active, &s);
    return s;
}
int treo_gc_probe_current_period_ms(void) { return treo_gc_snapshot().probe_ms; }
uint64_t treo_gc_probe_peak_heap_bytes(void) { return treo_gc_snapshot().probe_peak; }
uint64_t treo_gc_probe_fallbacks(void) { return treo_gc_snapshot().probe_fallbacks; }
int treo_gc_smart_period_ms(void) { return treo_gc_snapshot().smart_period; }
int treo_gc_smart_fell_back(void) { return treo_gc_snapshot().smart_fallback; }
uint64_t treo_gc_smart_heap_peak(void) { return treo_gc_snapshot().smart_peak; }
uint64_t treo_gc_smart_count(void) { return treo_gc_snapshot().smart_cycles; }
double treo_gc_smart_cpu_ms(void) {
    return (double)treo_gc_snapshot().smart_cpu / 1000000.0;
}
static uint64_t treo_gc_smart_thread_cpu(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t) != 0) return 0;
    return (uint64_t)t.tv_sec * UINT64_C(1000000000) + (uint64_t)t.tv_nsec;
}
#endif

// Generation-keyed per-JVM native memory accounting: old render handles must
// never debit a later VM when allocator addresses are reused.
#define JARBOX_NATIVE_HEAP_SLOTS 64
typedef struct { MiniJVM *owner; uint64_t key; s64 bytes; } JarBoxNativeHeapSlot;
static JarBoxNativeHeapSlot g_native_heaps[JARBOX_NATIVE_HEAP_SLOTS];
static uint64_t g_native_heap_sequence;
static spinlock_t g_native_heap_lock = {0, 0, 0};

int jarbox_native_heap_register_vm(MiniJVM *jvm) {
    if (!jvm) return 0;
    spin_lock(&g_native_heap_lock);
    int acquired = 0;
    for (int i = 0; i < JARBOX_NATIVE_HEAP_SLOTS; ++i) {
        if (g_native_heaps[i].owner == jvm) {
            spin_unlock(&g_native_heap_lock);
            return 0;
        }
    }
    for (int i = 0; i < JARBOX_NATIVE_HEAP_SLOTS; ++i) {
        JarBoxNativeHeapSlot *slot = &g_native_heaps[i];
        if (slot->owner) continue;
        slot->owner = jvm;
        slot->bytes = 0;
        uint64_t seq = ++g_native_heap_sequence;
        slot->key = (seq << 8) | (uint64_t)(i + 1);
        acquired = 1;
        break;
    }
    spin_unlock(&g_native_heap_lock);
    return acquired;
}
uint64_t jarbox_native_heap_key_for_vm(MiniJVM *jvm) {
    uint64_t result = 0;
    spin_lock(&g_native_heap_lock);
    for (int i = 0; i < JARBOX_NATIVE_HEAP_SLOTS; ++i) {
        if (jvm && g_native_heaps[i].owner == jvm) {
            result = g_native_heaps[i].key; break;
        }
    }
    spin_unlock(&g_native_heap_lock);
    return result;
}
// A Java thread already carries the immutable generation. Decode its
// slot index, then validate BOTH owner and full key under the ledger lock.
// This avoids a 64-slot scan on every graphics/input/UI native call.
uint64_t jarbox_native_heap_validate_key(MiniJVM *jvm, uint64_t key) {
    unsigned index = (unsigned)(key & 0xffU);
    if (!jvm || !key || !index || index > JARBOX_NATIVE_HEAP_SLOTS) return 0;
    spin_lock(&g_native_heap_lock);
    JarBoxNativeHeapSlot *slot = &g_native_heaps[index - 1];
    uint64_t result = slot->owner == jvm && slot->key == key ? key : 0;
    spin_unlock(&g_native_heap_lock);
    return result;
}

void jarbox_native_heap_account(uint64_t key, s64 delta_bytes) {
    if (!key || !delta_bytes) return;
    unsigned index = (unsigned)(key & 0xffU);
    if (!index || index > JARBOX_NATIVE_HEAP_SLOTS) return;
    spin_lock(&g_native_heap_lock);
    JarBoxNativeHeapSlot *slot = &g_native_heaps[index - 1];
    if (slot->owner && slot->key == key) {
        slot->bytes += delta_bytes;
        if (slot->bytes < 0) slot->bytes = 0;
    }
    spin_unlock(&g_native_heap_lock);
}
s64 jarbox_native_heap_for_vm(MiniJVM *jvm) {
    s64 result = 0;
    spin_lock(&g_native_heap_lock);
    for (int i = 0; i < JARBOX_NATIVE_HEAP_SLOTS; ++i) {
        if (jvm && g_native_heaps[i].owner == jvm) {
            result = g_native_heaps[i].bytes; break;
        }
    }
    spin_unlock(&g_native_heap_lock);
    return result;
}
// A late cleanup must not remove a new JVM at a recycled address.
void jarbox_native_heap_unregister_key(uint64_t key) {
    unsigned index = (unsigned)(key & 0xffU);
    if (!index || index > JARBOX_NATIVE_HEAP_SLOTS) return;
    spin_lock(&g_native_heap_lock);
    JarBoxNativeHeapSlot *slot = &g_native_heaps[index - 1];
    if (slot->owner && slot->key == key) {
        slot->owner = NULL; slot->key = 0; slot->bytes = 0;
    }
    spin_unlock(&g_native_heap_lock);
}

// Legacy live-owner API only; teardown must use the captured generation.
void jarbox_native_heap_unregister_vm(MiniJVM *jvm) {
    spin_lock(&g_native_heap_lock);
    for (int i = 0; i < JARBOX_NATIVE_HEAP_SLOTS; ++i) {
        JarBoxNativeHeapSlot *slot = &g_native_heaps[i];
        if (jvm && slot->owner == jvm) {
            slot->owner = NULL; slot->key = 0; slot->bytes = 0; break;
        }
    }
    spin_unlock(&g_native_heap_lock);
}

// Sample the native ledger only once; the GC report must use the same
// native value as the total heap sample, even during concurrent rendering.
static s64 gc_sum_heap_sample(GcCollector *collector, s64 *out_native) {
    s64 hsize = threadlist_sum_heap(collector->jvm);
    spin_lock(&collector->lock);
    {
        hsize += collector->obj_heap_size;
    }
    spin_unlock(&collector->lock);
    s64 native_extra = jarbox_native_heap_for_vm(collector->jvm);
    if (native_extra > 0) hsize += native_extra;
    if (out_native) *out_native = native_extra;
    return hsize;
}

s64 gc_sum_heap(GcCollector *collector) {
    return gc_sum_heap_sample(collector, NULL);
}
#if defined(TREO_GC_PHASE_DIAG) && TREO_GC_PHASE_DIAG && defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
// The GC worker lends its own stack record for one synchronous collection.
// Terminal cleanup and other callers leave this NULL. Never retain it in
// session state, and never publish while holding a stopped-world lock.
static _Thread_local JarBoxGCPhaseCycle *jarbox_gc_phase_current;
static inline void jarbox_gc_phase_boundary(unsigned i) {
    JarBoxGCPhaseCycle *c=jarbox_gc_phase_current;
    if (c) {
        c->cpu[i]=treo_gc_smart_thread_cpu();
        c->wall[i]=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    }
}
#define JARBOX_GC_BOUNDARY(i) jarbox_gc_phase_boundary(i)
#else
#define JARBOX_GC_BOUNDARY(i) ((void)0)
#endif
//==============================   thread_run() =====================================
/**
 * Garbage Collection Thread Function.
 *
 * @param para A pointer to the GcCollector instance which provides garbage collection context.
 * @return 0 on successful termination of the thread.

 * This function implements a dedicated garbage collection thread that performs the following tasks:
 * 1. Continuously monitors the JVM's heap status and garbage collection parameters.
   *   It uses `currentTimeMillis()` to track time and `gc_sum_heap` to get current heap usage.
 * 2. Checks the garbage collector thread's status (`collector->_garbage_thread_status`) and pauses or terminates as needed.
 * 3. If the specified garbage collection period has elapsed (determined by `jvm->garbage_collect_period_ms`) or the heap usage exceeds a pre-defined threshold (`jvm->max_heap_size * jvm->heap_overload_percent / 100`),
   *   it initiates a garbage collection cycle with `_garbage_collect`.
 * 4. Updates the last garbage collection timestamp (`collector->lastgc`) after successfully completing a GC cycle.
 * 5. Sleeps for 1 second if no garbage collection is required.
 * 6. When signaled to stop, changes the garbage collector thread status to `GARBAGE_THREAD_DEAD` and exits gracefully using `thrd_exit(0)`.
 */

s32 _gc_thread_run(void *para) {
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
    extern void treo_afk_mark_gc_thread(void);
    extern void treo_diag_sample(int kind);
    extern void treo_diag_gc_cycle_begin(void);
    extern void treo_diag_gc_cycle_end(void);
    treo_afk_mark_gc_thread();
#endif
    GcCollector *collector = (GcCollector *) para;
    MiniJVM *jvm = collector->jvm;
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
    jvm_bridge_cpu_worker_begin(jvm->session,JARBOX_CPU_GC);
#endif

    while (1) {
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
        // Real miniJVM collector pthread; no extra worker.
        treo_diag_sample(2);
#endif
        s64 cur_mil = currentTimeMillis();

        if (gc_thread_status(collector) == GARBAGE_THREAD_STOP) {
            break;
        }
        if (gc_thread_status(collector) == GARBAGE_THREAD_PAUSE) {
            threadSleep(1000);
            continue;
        }
        if (cur_mil - collector->lastgc < jvm->garbage_collect_period_ms) {
            threadSleep(jvm->garbage_collect_period_ms / 2);
            continue;
        };

        s64 native_extra = 0;
        s64 heap = gc_sum_heap_sample(collector, &native_extra);
        if (heap >= 0) {
            __atomic_store_n(&collector->jarbox_status_heap_sample,
                             (uint64_t)heap + 1, __ATOMIC_RELEASE);
        }
        s64 threshold = jvm->max_heap_size * jvm->heap_overload_percent / 100;
        s64 desired = jvm->garbage_collect_period_ms;
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
        if (heap >= 0) {
            jarbox_treo_peak_note(&jvm->session->treo_state.probe_heap_peak, (uint64_t)heap);
            jarbox_treo_smart_note_heap(&jvm->session->treo_state, (uint64_t)heap);
        }
        // Existing GC workers share a process headroom sample. Detect
        // aggregate pressure before iOS delivers a memory warning, without
        // a new poller or a syscall per parked JVM.
        if ((jarbox_treo_smart_period(&jvm->session->treo_state) > desired ||
             jarbox_treo_probe_period(&jvm->session->treo_state) > desired) &&
            jvm_bridge_memory_state_cached() != 0) {
            treo_force_safe_active(jvm, NULL);
        }
        // Keep the Java/native heap pressure threshold unchanged. If the
        // memory headroom shrinks, latch at 500 ms until the user leaves AFK.
        if (jarbox_treo_smart_period(&jvm->session->treo_state) > desired) {
            if (heap >= threshold * 3 / 4) {
                jarbox_treo_smart_force_safe(&jvm->session->treo_state);
            } else {
                desired = 2000;
            }
        }
        int probe = jarbox_treo_probe_period(&jvm->session->treo_state);
        if (probe > desired) {
            if (heap >= threshold * 3 / 4) {
                // Conservative exit if heap reaches 52.5% of max_heap_size.
                jarbox_treo_probe_fallback(&jvm->session->treo_state);
            } else {
                desired = probe;
            }
        }
        if (desired > jvm->garbage_collect_period_ms &&
            cur_mil - collector->lastgc < desired) {
            // Keep the original ~250ms heap-pressure polling cadence.
            threadSleep(jvm->garbage_collect_period_ms / 2);
            continue;
        }
#endif
        if (cur_mil - collector->lastgc >= desired || heap >= threshold) {
            s64 heap_before = heap;
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
            treo_diag_gc_cycle_begin();
            const int smartRecord = __atomic_load_n(&jvm->session->treo_state.smart_enabled, __ATOMIC_ACQUIRE);
            const uint64_t gcCpuStart = treo_gc_smart_thread_cpu();
#endif
#if defined(TREO_GC_PHASE_DIAG) && TREO_GC_PHASE_DIAG && defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
            JarBoxGCPhaseCycle phaseCycle={0};
            jarbox_gc_phase_current=&phaseCycle;
#endif
            s64 gcResult = _garbage_collect(collector);
#if defined(TREO_GC_PHASE_DIAG) && TREO_GC_PHASE_DIAG && defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
            jarbox_gc_phase_current=NULL;
#endif
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
            const uint64_t gcCpuEnd = treo_gc_smart_thread_cpu();
            JarBoxTreoState *metrics = &jvm->session->treo_state;
            // Lifetime totals include attempted cycles (including aborts).
            // Two clock reads per collection, not per object or game tick.
            if (gcCpuStart && gcCpuEnd >= gcCpuStart) {
                uint64_t elapsed = gcCpuEnd - gcCpuStart;
                __atomic_fetch_add(&metrics->gc_worker_cpu_ns, elapsed, __ATOMIC_RELAXED);
                if (smartRecord && __atomic_load_n(&metrics->smart_enabled, __ATOMIC_ACQUIRE))
                    jarbox_treo_smart_record_gc(metrics, elapsed);
            }
            __atomic_fetch_add(&metrics->gc_worker_cycles, 1, __ATOMIC_RELAXED);
            if (gcResult < 0)
                __atomic_fetch_add(&metrics->gc_worker_aborts, 1, __ATOMIC_RELAXED);
            treo_diag_gc_cycle_end();
#if defined(TREO_GC_PHASE_DIAG) && TREO_GC_PHASE_DIAG && defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
            jarbox_gc_phase_publish(&metrics->gc_phase,&phaseCycle,gcResult<0);
#endif
#elif defined(JARBOX_HOST_INTRINSIC_TEST) && !__JVM_OS_IOS__
            // Host gate must prove the real worker collected during the run.
            if (gcResult>=0)
                __atomic_fetch_add(&jvm->session->treo_state.gc_worker_cycles,1,__ATOMIC_RELAXED);
#else
            (void)gcResult;
#endif
            s64 native_after = 0;
            s64 heap_after = gc_sum_heap_sample(collector, &native_after);
            if (heap_after >= 0) {
                __atomic_store_n(&collector->jarbox_status_heap_sample,
                                 (uint64_t)heap_after + 1, __ATOMIC_RELEASE);
            }
            jvm_printf("[GC] collected: java %lldKB→%lldKB, native %lldKB, total %lldKB→%lldKB (threshold %lldKB) objs=%lld\n",
                       (heap_before - native_extra) / 1024, (heap_after - native_after) / 1024,
                       native_after / 1024,
                       heap_before / 1024, heap_after / 1024,
                       threshold / 1024,
                       (s64)collector->obj_count);
            // A stalled/aborted stop-world attempt may have consumed its
            // entire period. Do not immediately re-suspend the same JVM.
            collector->lastgc = gcResult < 0 ? currentTimeMillis() : cur_mil;
        } else {
            threadSleep(jvm->garbage_collect_period_ms / 2);
        }
    }
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
    jvm_bridge_cpu_worker_end(jvm->session);
#endif
    __atomic_store_n(&collector->_garbage_thread_status, GARBAGE_THREAD_DEAD, __ATOMIC_RELEASE);
    thrd_exit(0);
    return 0;
}


#if defined(JARBOX_HOST_GC_INDEX_TEST)
// Independent stopped-world coverage/order check. Test builds only: this
// deliberately walks the heap and is NOT a performance benchmark.
static void gc_test_shadow_deferred_index(GcCollector *collector) {
    JarBoxGCDeferredIndex *index = &collector->deferred_index;
    if (index->disabled) return;
    size_t cursor = index->count;
    uint64_t omitted = 0;
    for (MemoryBlock *mb = collector->header; mb; mb = mb->next) {
        if (cursor && index->items[cursor-1] == mb) {
            --cursor;
        } else {
            // Missing any potentially effectful instance is a test failure,
            // including not-yet-initialized classes and finalized weak refs.
            if (mb->type == MEM_TYPE_INS &&
                (GCFLAG_WEAKREFERENCE_GET(mb->gcflag) || !mb->clazz ||
                 mb->clazz->status != CLASS_STATUS_CLINITED || mb->clazz->finalizeMethod))
                abort();
            ++omitted;
        }
    }
    if (cursor) abort(); // stale, duplicate or misordered index entries
    __atomic_fetch_add(&collector->host_gc_index_omitted, omitted, __ATOMIC_RELAXED);
    if (omitted >= 10000)
        __atomic_fetch_add(&collector->host_gc_index_large_snapshots, 1, __ATOMIC_RELAXED);
}
#endif

static void gc_process_deferred_objects(GcCollector *collector) {
    MiniJVM *jvm = collector->jvm;
    MemoryBlock *head = NULL;
    if (gc_thread_status(collector) != GARBAGE_THREAD_NORMAL) return;
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
    JarBoxGCDeferredIndex *index = &collector->deferred_index;
    const int indexed = !index->disabled;
    size_t cursor = index->count;
#if __JVM_OS_IOS__
    // Collector-owned per-pass admission evidence. No per-object counters
    // or extra heap traversal. Read only after worker join.
    if(indexed){
        ++collector->deferred_index_passes;
        collector->deferred_index_entries+=cursor;
        if(cursor>collector->deferred_index_peak)collector->deferred_index_peak=(unsigned)cursor;
    }
#endif
    MemoryBlock *curmb = indexed ? (cursor ? index->items[--cursor] : NULL) : collector->header;
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    if (indexed) __atomic_fetch_add(&collector->host_gc_index_passes, 1, __ATOMIC_RELAXED);
#endif
#else
    MemoryBlock *curmb = collector->header;
#endif
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    uint64_t visits = 0, finalizers = 0, weak_callbacks = 0;
#endif
    for (; curmb;) {
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
        MemoryBlock *nextmb = indexed ? (cursor ? index->items[--cursor] : NULL) : curmb->next;
#else
        MemoryBlock *nextmb = curmb->next;
#endif
        // STOP is terminal. Finish remarking already dispatched objects,
        // but do not begin another Java callback after observing STOP.
        if (gc_thread_status(collector) >= GARBAGE_THREAD_STOP) break;
#if defined(JARBOX_HOST_GC_INDEX_TEST)
        ++visits;
#endif
        if (curmb->type == MEM_TYPE_INS) {
            int defer = 0;
            // Most objects are already marked. Do not chase a class pointer
            // for those, or for instances already finalized.
            if (curmb->garbage_mark != collector->mark_cnt &&
                !GCFLAG_FINALIZED_GET(curmb->gcflag) &&
                curmb->clazz->finalizeMethod) {
                instance_finalize((Instance *)curmb, collector->runtime);
#if defined(JARBOX_HOST_GC_INDEX_TEST)
                ++finalizers;
#endif
                GCFLAG_FINALIZED_SET(curmb->gcflag);
                defer = 1;
            }
            if (gc_thread_status(collector) < GARBAGE_THREAD_STOP &&
                GCFLAG_WEAKREFERENCE_GET(curmb->gcflag)) {
                Instance *target = getFieldRefer(getInstanceFieldPtr(
                    (Instance *)curmb, jvm->shortcut.reference_target));
                if (target && target->mb.garbage_mark != collector->mark_cnt) {
                    instance_of_reference_enqueue((Instance *)curmb, collector->runtime);
#if defined(JARBOX_HOST_GC_INDEX_TEST)
                    ++weak_callbacks;
#endif
                    defer = 1;
                }
            }
            // One object may qualify for BOTH callbacks. Link it once;
            // a second insertion would set tmp_next to itself.
            if (defer) {
                curmb->tmp_next = head;
                head = curmb;
            }
        }
        curmb = nextmb;
    }
    while (head) {
        MemoryBlock *curmb = head;
        head = curmb->tmp_next;
        curmb->tmp_next = NULL;
        _gc_mark_object(collector, curmb, collector->mark_cnt);
    }
#if defined(JARBOX_HOST_GC_INDEX_TEST)
    __atomic_fetch_add(&collector->host_gc_deferred_visits, visits, __ATOMIC_RELAXED);
    __atomic_fetch_add(&collector->host_gc_finalizers, finalizers, __ATOMIC_RELAXED);
    __atomic_fetch_add(&collector->host_gc_weak_callbacks, weak_callbacks, __ATOMIC_RELAXED);
#endif
}

/**
 * Executes a full garbage collection cycle.
 *
 * @param collector A pointer to the GcCollector instance that manages garbage collection for the JVM.
 * @return The number of objects deleted during this GC cycle.

 * This function performs a complete garbage collection process, including:
 * 1. Initiates garbage collection by setting the `isgc` flag and recording the start time.
 * 2. Pauses the world by stopping all threads and preparing resources for GC using `_gc_pause_the_world`.
   *   If pausing fails, resumes the world and returns -1.
 * 3. Merges temporary object lists into the main list and copies references from runtime stacks.
 * 4. Begins the mark phase with `_gc_big_search`, incrementing the mark counter and marking reachable objects.
 * 5. Processes finalize methods for eligible objects and enqueues weak references for objects no longer reachable.
   *   Re-marks these objects for collection on the next cycle.
 * 6. Clears unreachable objects, updates total memory usage stats, and destroys them.
 * 7. Updates the count of live objects and heap size after clearing dead objects.
 * 8. Logs performance metrics related to GC timing.
 * 9. Resumes the world and unlocks shared resources.
 * 10. Optionally calls `jvm_squeeze` if MEM_ALLOC_LTALLOC is defined.
 * 11. Resets the `isgc` flag and returns the number of deleted objects.
 */

s64 _garbage_collect(GcCollector *collector) {
    collector->isgc = 1;
    s64 mem_total = 0, mem_free = 0;
    s64 del = 0;
    s64 time, start;
    MiniJVM *jvm = collector->jvm;

    start = time = currentTimeMillis();

    //prepar gc resource ,
    JARBOX_GC_BOUNDARY(0);
    vm_share_lock(jvm);
    {
        if (_gc_pause_the_world(jvm) != 0) {
            _gc_resume_the_world(jvm);
            collector->isgc = 0;
            vm_share_unlock(jvm);
            jvm_printf("[WARN] GC canceled - failed to pause the world\n");
            return -1;
        }
        collector->isworldstoped = 1;
        JARBOX_GC_BOUNDARY(1);
#if _JVM_DEBUG_GARBAGE
        jvm_printf("garbage_move_cache %lld\n", (currentTimeMillis() - time));
        time = currentTimeMillis();
#endif
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
        // No metadata certificate is assumed under debugger or terminal GC.
        if (jvm->jdwp_enable || gc_thread_status(collector) != GARBAGE_THREAD_NORMAL)
            gc_deferred_index_disable(&collector->deferred_index);
        MemoryBlock *old_head = collector->header;
#endif
        if (collector->tmp_header) {
            collector->tmp_tailer->next = collector->header;//接起来
            collector->header = collector->tmp_header;
            collector->tmp_header = NULL;
            collector->tmp_tailer = NULL;
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
            // Publish the index together with the merged list, even if the
            // subsequent root snapshot aborts this collection.
            gc_deferred_index_add(&collector->deferred_index, collector->header, old_head);
#endif
        }
#if _JVM_DEBUG_GARBAGE
        jvm_printf("garbage_move_cache %lld\n", (currentTimeMillis() - time));
        time = currentTimeMillis();
#endif
#if defined(JARBOX_HOST_GC_INDEX_TEST)
        gc_test_shadow_deferred_index(collector);
#endif
        if (_gc_copy_objs(jvm) != 0) {
            // A partial root set is never safe to mark/sweep. Objects
            // already moved into the collector list remain owned by it.
            arraylist_clear(collector->runtime_refer_copy);
            collector->isworldstoped = 0;
            _gc_resume_the_world(jvm);
            collector->isgc = 0;
            vm_share_unlock(jvm);
            jvm_printf("[WARN] GC canceled - incomplete root snapshot\n");
            return -1;
        }
        //
#if _JVM_DEBUG_GARBAGE
        jvm_printf("garbage_copy_refer %lld\n", (currentTimeMillis() - time));
        time = currentTimeMillis();
#endif
        JARBOX_GC_BOUNDARY(2);
        //real GC start
        //
        collector->mark_cnt++;
        if (collector->mark_cnt == 0) {
            collector->mark_cnt = 1;
        }
        _gc_big_search(collector);
        JARBOX_GC_BOUNDARY(3);
        //
#if _JVM_DEBUG_GARBAGE
        jvm_printf("garbage_big_search %lld\n", (currentTimeMillis() - time));
        time = currentTimeMillis();
#endif

#if _JVM_DEBUG_GARBAGE_DUMP > 0
        _gc_print_obj_list(collector);
#endif

        collector->isworldstoped = 0;
        _gc_resume_the_world(jvm);
    }
    vm_share_unlock(jvm);
    JARBOX_GC_BOUNDARY(4);

#if _JVM_DEBUG_GARBAGE
    jvm_printf("garbage_resume_the_world %lld\n", (currentTimeMillis() - time));
#endif

#if _JVM_DEBUG_LOG_LEVEL > 1
    s64 time_stopWorld = currentTimeMillis() - start;
#endif
    time = currentTimeMillis();
    //


    gc_process_deferred_objects(collector);
#if defined(JARBOX_GC_DEFERRED_INDEX_EXPERIMENT) && JARBOX_GC_DEFERRED_INDEX_EXPERIMENT
    gc_deferred_index_prune(&collector->deferred_index, collector->mark_cnt);
#endif
    JARBOX_GC_BOUNDARY(5);
    MemoryBlock *nextmb, *curmb, *prevmb = NULL;

#if _JVM_DEBUG_GARBAGE
    jvm_printf("garbage_finalize %lld\n", (currentTimeMillis() - time));
    time = currentTimeMillis();
#endif
    //clear
    nextmb = collector->header;
    prevmb = NULL;
    s64 iter = 0;
    while (nextmb) {
        iter++;
        curmb = nextmb;
        nextmb = curmb->next;
        s32 size = curmb->heap_size;
        mem_total += size;
        if (curmb->garbage_mark != collector->mark_cnt) {
            mem_free += size;
            //
#if _JVM_DEBUG_GARBAGE_DUMP > 1
            Utf8String *sus = utf8_create();
            _gc_get_obj_name(collector, curmb, sus);
            jvm_printf("X: %s[%llx]\n", utf8_cstr(sus), (s64) (intptr_t) curmb);
            utf8_destroy(sus);
#endif
            if (curmb->type == MEM_TYPE_CLASS) {
                classes_remove(collector->jvm, (JClass *) curmb);
            } else if (GCFLAG_JLOADER_GET(curmb->gcflag)) {// curmb->class might be destroyed, when gc_destroy() called
#if _JVM_DEBUG_GARBAGE_DUMP > 1
                jvm_printf("X: [%llx] classloader\n", (s64) (intptr_t) curmb);
#endif
                PeerClassLoader *pcl = classLoaders_find_by_instance(jvm, (Instance *) curmb);
                if (pcl) {
                    classloaders_remove(jvm, pcl);
                    classloader_destroy(pcl);
                }
            } else if (GCFLAG_JTHREAD_GET(curmb->gcflag)) {//process thread if it created but not started
                Runtime *ort = jthread_get_stackframe_value(jvm, (Instance *) curmb);
                jthread_run_finalize(ort);
            }
            memoryblock_destroy(curmb);
            if (prevmb)prevmb->next = nextmb;
            else collector->header = nextmb;
            del++;
        } else {
            prevmb = curmb;
        }
    }
    spin_lock(&collector->lock);
    collector->obj_count = iter - del;
    collector->obj_heap_size -= mem_free;
    spin_unlock(&collector->lock);

#if _JVM_DEBUG_LOG_LEVEL > 1
    s64 time_gc = currentTimeMillis() - time;
    jvm_printf("[INFO]gc obj: %lld->%lld   heap : %lld -> %lld  stop_world: %lld  gc:%lld\n", iter, collector->obj_count, mem_total, collector->obj_heap_size, time_stopWorld, time_gc);
#endif

#ifdef MEM_ALLOC_LTALLOC
    jvm_squeeze(0);
#endif
#if defined(TREO_GC_PHASE_DIAG) && TREO_GC_PHASE_DIAG && defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
    if (jarbox_gc_phase_current && iter>=0 && del>=0 && mem_free>=0) {
        jarbox_gc_phase_current->scanned=(uint64_t)iter;
        jarbox_gc_phase_current->reclaimed=(uint64_t)del;
        jarbox_gc_phase_current->freed_bytes=(uint64_t)mem_free;
    }
#endif
    collector->isgc = 0;
    JARBOX_GC_BOUNDARY(6);
    return del;
}


/**
 * Each thread marks the objects it still needs to use, indicating they cannot be collected.
 */
s32 _gc_pause_the_world(MiniJVM *jvm) {
    GcCollector *collector = jvm->collector;
    ArrayList *thread_list = jvm->thread_list;
    s32 i;
    // One list transaction: no new thread may slip between the suspend
    // request pass and the acknowledgement pass. Thread.start cooperates
    // with safepoints while contending on this lock.
    spin_lock(&thread_list->spinlock);
    {
        for (i = 0; i < thread_list->length; i++)
            jthread_suspend((Runtime *)arraylist_get_value_unsafe(thread_list, i));
        {
            for (i = 0; i < thread_list->length; i++) {
                Runtime *runtime = arraylist_get_value_unsafe(thread_list, i);
                if (_gc_wait_thread_suspend(jvm, runtime) == -1) {
                    // Abort must release the list before resuming Java or
                    // the stop worker will wait on this lock forever.
                    spin_unlock(&thread_list->spinlock);
                    return -1;
                }
                gc_move_objs_thread_2_gc(runtime);

#if _JVM_DEBUG_GARBAGE_DUMP > 1
                Utf8String *stack = utf8_create();
                getRuntimeStack(runtime, stack);
                jvm_printf("%s\n", utf8_cstr(stack));
                utf8_destroy(stack);
#endif
            }
        }
    }
    spin_unlock(&thread_list->spinlock);
    gc_move_objs_thread_2_gc(collector->runtime);// maybe someone new object in finalize...

    return 0;
}

s32 _gc_resume_the_world(MiniJVM *jvm) {
    GcCollector *collector = jvm->collector;
    ArrayList *thread_list = jvm->thread_list;
    s32 i;
    spin_lock(&thread_list->spinlock);
    for (i = 0; i < thread_list->length; i++) {
        Runtime *runtime = arraylist_get_value_unsafe(thread_list, i);
        if (runtime) {
#if _JVM_DEBUG_GARBAGE_DUMP > 1
            Utf8String *stack = utf8_create();
            getRuntimeStack(runtime, stack);
            jvm_printf("%s\n", utf8_cstr(stack));
            utf8_destroy(stack);
#endif
            jthread_resume(runtime);
        }
    }
    spin_unlock(&thread_list->spinlock);
    vm_share_notifyall(jvm);

    return 0;
}


s32 _gc_wait_thread_suspend(MiniJVM *jvm, Runtime *runtime) {
    // Abort this collection rather than keeping a non-cooperating worker
    // and the registry locked forever (e.g. no_pause in class init).
    // The existing caller resumes all threads and skips mark/sweep on -1.
    const s64 started = nanoTime();
    unsigned waits = 0;
    for (;;) {
        // Terminal runtimes need no acknowledgement, including during
        // synchronous heap cleanup after gc_destroy has joined the collector.
        // Never treat a live blocked/suspended worker as safe on STOP.
        if (runtime->thrd_info->thread_status == THREAD_STATUS_NEW ||
            runtime->thrd_info->thread_status == THREAD_STATUS_ZOMBIE)
            return 0;
        if (gc_thread_status(jvm->collector) != GARBAGE_THREAD_NORMAL)
            return -1;
        if (runtime->thrd_info->is_suspend || runtime->thrd_info->is_blocking)
            return 0;
        const s64 now = nanoTime();
        if ((now >= started && now - started >= INT64_C(2000000000)) ||
            ++waits >= 2000)
            return -1;
        vm_share_notifyall(jvm);
        vm_share_timedwait(jvm, 100);
    }
}

//=================================  big_search ==================================

/**
 * on all threads stoped ,
 * mark thread's localvar and stack refered obj and deep search
 * @return ret
 */
// The collector owns its root snapshot and the stopped-world reference
// arrays. Their contents/length cannot change while this traversal runs.
// Do not acquire a list lock or decode an array element type per reference.
static void gc_mark_unmarked(GcCollector *collector, MemoryBlock *mb, u8 flag_cnt);

// The collector is the sole writer of the mark tag. Keep duplicate/null
// edges in the caller's scan loop instead of dispatching a recursive
// function for each of them. First-visit DFS order is unchanged.
static inline void gc_mark_ref_if_needed(GcCollector *collector, __refer ref, u8 flag_cnt) {
    MemoryBlock *mb = (MemoryBlock *)ref;
    if (mb && mb->garbage_mark != flag_cnt)
        gc_mark_unmarked(collector, mb, flag_cnt);
}

static inline void gc_mark_refs(GcCollector *collector, const __refer *refs,
                                s32 length, u8 flag_cnt) {
    for (s32 i = 0; i < length; ++i)
        gc_mark_ref_if_needed(collector, refs[i], flag_cnt);
}

s32 _gc_big_search(GcCollector *collector) {
    // Private copy; _gc_copy_objs completed with the world stopped.
    ArrayList *roots = collector->runtime_refer_copy;
    gc_mark_refs(collector, roots->data, roots->length, collector->mark_cnt);

    //holder mark
    HashsetIterator hi;
    hashset_iterate(collector->objs_holder, &hi);
    while (hashset_iter_has_more(&hi)) {
        HashsetKey k = hashset_iter_next_key(&hi);
        gc_mark_ref_if_needed(collector, k, collector->mark_cnt);
    }
    //bootclassloader mark
    HashtableIterator hti;
    hashtable_iterate(collector->jvm->boot_classloader->classes, &hti);
    while (hashtable_iter_has_more(&hti)) {
        HashtableValue v = hashtable_iter_next_value(&hti);
        gc_mark_ref_if_needed(collector, v, collector->mark_cnt);
    }

    return 0;
}

// Registered shutdown hooks are strong Java references owned by this JVM.
// Snapshot them under the queue lock while the collector owns the root copy.
static s32 gc_copy_shutdown_hook_roots(MiniJVM *jvm) {
    ArrayList *hooks = jvm->shutdown_hook;
    spin_lock(&hooks->spinlock);
    for (s32 i = 0; i < hooks->length; ++i) {
        ArrayListValue hook = arraylist_get_value_unsafe(hooks, i);
        if (hook && !arraylist_push_back_unsafe(jvm->collector->runtime_refer_copy, hook)) {
            spin_unlock(&hooks->spinlock);
            return -1;
        }
    }
    spin_unlock(&hooks->spinlock);
    return 0;
}

s32 _gc_copy_objs(MiniJVM *jvm) {
    arraylist_clear(jvm->collector->runtime_refer_copy);
    if (gc_copy_shutdown_hook_roots(jvm) != 0) return -1;
    // Pin list membership during root traversal. A terminating runtime
    // cannot remove itself and free its stack between lookup and copy.
    ArrayList *threads = jvm->thread_list;
    spin_lock(&threads->spinlock);
    for (s32 i = 0; i < threads->length; ++i) {
        Runtime *runtime = arraylist_get_value_unsafe(threads, i);
        if (runtime && runtime->thrd_info->thread_status != THREAD_STATUS_ZOMBIE &&
            _gc_copy_objs_from_thread(runtime) != 0) {
            spin_unlock(&threads->spinlock);
            return -1;
        }
    }
    spin_unlock(&threads->spinlock);
    if (jvm->jdwp_enable && jvm->jdwpserver) {
        Runtime *runtime = jdwp_get_runtime(jvm->jdwpserver);
        if (runtime && _gc_copy_objs_from_thread(runtime) != 0) return -1;
    }
    return 0;
}

/**
 * Copies object references from a thread's runtime stack and temporary holder for garbage collection.
 *
 * @param pruntime A pointer to the Runtime instance representing the current thread.
 * @return 0 on successful completion.

 * This function performs the following actions:
 * 1. Retrieves the GcCollector instance associated with the JVM.
 * 2. Adds the thread's JavaThreadInfo (`pruntime->thrd_info->jthread`) to the collector's runtime reference copy list (`collector->runtime_refer_copy`).
 * 3. Resets the free stack space by marking the current stack pointer as the clean point, and clears unused stack entries.
 * 4. Iterates over the stack of the given thread's Runtime and adds each non-null reference value found in the StackEntry to the reference copy list.
 * 5. Traverses the temporary holder list (`runtime->thrd_info->tmp_holder`) for the thread and adds each MemoryBlock to the reference copy list.
 * 6. Upon completion, it signals that the references have been copied and are ready for garbage collection.
 */

s32 _gc_copy_objs_from_thread(Runtime *pruntime) {
    GcCollector *collector = pruntime->jvm->collector;
    if (pruntime->thrd_info->jthread &&
        !arraylist_push_back_unsafe(collector->runtime_refer_copy, pruntime->thrd_info->jthread))
        return -1;

    Runtime *runtime = pruntime;
    RuntimeStack *stack = runtime->stack;

//    jvm_printf("stack:%llx:", (s64) (intptr_t) stack);
//    s32 j;
//    for (j = stack_size(stack); j < stack->max_size; j++) {
//        if ((stack->store + j)->rvalue) {
//            jvm_printf("%d->%llx,", j, (s64) (intptr_t) (stack->store + j)->rvalue);
//        }
//    }
//    jvm_printf("\n");

    //reset free stack space
    stack->gc_clean = stack->sp;
    memset(stack->sp, 0, sizeof(StackEntry) * (stack->max_size - stack_size(stack)));

    s32 i, imax;
    StackEntry *entry;
    for (i = 0, imax = stack_size(stack); i < imax; i++) {
        entry = stack->store + i;
        if (entry->rvalue) {
            if (!arraylist_push_back_unsafe(collector->runtime_refer_copy, entry->rvalue))
                return -1;
        }
    }
    MemoryBlock *next = runtime->thrd_info->tmp_holder;
    for (; next;) {
        if (!arraylist_push_back_unsafe(collector->runtime_refer_copy, next))
            return -1;
        next = next->hold_next;
    }

    //jvm_printf("[%llx] notified\n", (s64) (intptr_t) pruntime->threadInfo->jthread);
    return 0;
}


static inline void _gc_instance_mark(GcCollector *collector, Instance *ins, u8 flag_cnt) {
    s32 i, len;
    JClass *clazz = ins->mb.clazz;
    while (clazz) {
        ArrayList *fiList = clazz->insFieldPtrIndex;
        for (i = 0, len = fiList->length; i < len; i++) {
            FieldInfo *fi = fiList->data[i];

            if (fi->is_ref_target && GCFLAG_WEAKREFERENCE_GET(ins->mb.gcflag)) continue;//skip weakreference target mark, but others mark need
            c8 *ptr = getInstanceFieldPtr(ins, fi);
            if (ptr) {
                __refer ref = getFieldRefer(ptr);
                gc_mark_ref_if_needed(collector, ref, flag_cnt);
            }
            // Preserve the original first-visit order (and recursion depth
            // behavior); avoid repeated calls once this owner is marked.
            gc_mark_ref_if_needed(collector, fi->_this_class, flag_cnt);
        }
        gc_mark_ref_if_needed(collector, clazz, flag_cnt);//keep class and classloader alive
        clazz = getSuperClass(clazz);
    }

    if (GCFLAG_JLOADER_GET(ins->mb.gcflag)) {//if the instance is created from java.lang.ClassLoader
        PeerClassLoader *pcl = classLoaders_find_by_instance(collector->jvm, ins);
        if (pcl) {// pcl maybe finalized
            HashtableIterator hi;
            hashtable_iterate(pcl->classes, &hi);
            while (hashtable_iter_has_more(&hi)) {
                HashtableValue v = hashtable_iter_next_value(&hi);
                gc_mark_ref_if_needed(collector, v, flag_cnt);
            }
        }
    }
}


static inline void _gc_jarray_mark(GcCollector *collector, Instance *arr, u8 flag_cnt) {
    if (arr && arr->mb.type == MEM_TYPE_ARR) {
//        if (utf8_equals_c(arr->mb.clazz->name, "[[D")) {
//            jvm_printf("check %llx\n", (s64) (intptr_t) arr);
//        }
        // Identical to isDataReferByIndex in jvm_util.c; avoid an external
        // call for every array, including primitive leaf arrays.
        if (arr->mb.arr_type_index == DATATYPE_REFERENCE || arr->mb.arr_type_index == DATATYPE_ARRAY) {
            gc_mark_refs(collector, (const __refer *)arr->arr_body,
                         arr->arr_length, flag_cnt);
        }
    }
    return;
}

/**
 * mark class static field is used
 * @param clazz class
 */
static inline void _gc_class_mark(GcCollector *collector, JClass *clazz, u8 flag_cnt) {
    s32 i, len;
    if (clazz->field_static) {
        ArrayList *fiList = clazz->staticFieldPtrIndex;
        for (i = 0, len = fiList->length; i < len; i++) {
            FieldInfo *fi = fiList->data[i];
            c8 *ptr = getStaticFieldPtr(fi);
            if (ptr) {
                __refer ref = getFieldRefer(ptr);
                gc_mark_ref_if_needed(collector, ref, flag_cnt);
            }
        }
    }
    if (clazz->ins_class) {
        gc_mark_ref_if_needed(collector, clazz->ins_class, flag_cnt);
    }
    if (clazz->jloader) {
        gc_mark_ref_if_needed(collector, clazz->jloader, flag_cnt);
    }
}


/**
 * Recursively mark all descendants of the object.
 * @param ref Address of the object
 */

static void gc_mark_unmarked(GcCollector *collector, MemoryBlock *mb, u8 flag_cnt) {
#if _JVM_DEBUG_GARBAGE_DUMP > 0
    _gc_add_obj_count(collector, mb);
#endif
    mb->garbage_mark = flag_cnt;
    switch (mb->type) {
        case MEM_TYPE_INS:
            _gc_instance_mark(collector, (Instance *)mb, flag_cnt);
            break;
        case MEM_TYPE_ARR:
            _gc_jarray_mark(collector, (Instance *)mb, flag_cnt);
            break;
        case MEM_TYPE_CLASS:
            _gc_class_mark(collector, (JClass *)mb, flag_cnt);
            break;
    }
}

void _gc_mark_object(GcCollector *collector, __refer ref, u8 flag_cnt) {
    gc_mark_ref_if_needed(collector, ref, flag_cnt);
}
//=================================  reg unreg ==================================

s32 _gc_is_alive_in_link(MemoryBlock *header, MemoryBlock *target) {
    MemoryBlock *mb = header;
    while (mb) {
        if (mb == target) {
            return 1;
        }
        mb = mb->next;
    }
    return 0;
}

MemoryBlock *gc_is_alive(GcCollector *collector, __refer ref) {
    __refer result = hashset_get(collector->objs_holder, ref);
    if (result)return ref;

    MiniJVM *jvm = collector->jvm;
    spin_lock(&collector->lock);
    if (!result) {
        MemoryBlock *mb = collector->header;
        if (_gc_is_alive_in_link(mb, ref)) {
            result = ref; //don't return ,there is a lock need unlock
        }
    }
    if (!result) {
        MemoryBlock *mb = jvm->collector->tmp_header;
        if (_gc_is_alive_in_link(mb, ref)) {
            result = ref;//don't return ,there is a lock need unlock
        }
    }
    if (!result) {
        s32 i;
        for (i = 0; i < jvm->thread_list->length; i++) {
            Runtime *runtime = threadlist_get(jvm, i);
            MemoryBlock *mb = runtime->thrd_info->objs_header;
            if (_gc_is_alive_in_link(mb, ref)) {
                result = ref;//don't return ,there is a lock need unlock
            }
        }
    }
    if (!result) {
        if (jvm->jdwp_enable) {
            Runtime *runtime = jdwp_get_runtime(jvm->jdwpserver);
            if (runtime) {
                MemoryBlock *mb = runtime->thrd_info->objs_header;
                if (_gc_is_alive_in_link(mb, ref)) {
                    result = ref;//don't return ,there is a lock need unlock
                }
            }
        }
    }
    spin_unlock(&jvm->collector->lock);
    return (MemoryBlock *) result;
}

/**
 * Add the object to the thread's object list.
 * @param runtime Runtime environment
 * @param ref Reference to the object
 */
void gc_obj_reg(Runtime *runtime, __refer ref) {
    if (!ref)return;
    MemoryBlock *mb = (MemoryBlock *) ref;
    if (!GCFLAG_REG_GET(mb->gcflag)) {
        GCFLAG_REG_SET(mb->gcflag);
        JavaThreadInfo *ti = runtime->thrd_info;
        mb->next = ti->objs_header;
        ti->objs_header = ref;
        if (!ti->objs_tailer) {
            ti->objs_tailer = ref;
        }
        ti->objs_heap_of_thread += mb->heap_size;

#ifdef HARD_LIMIT
        //HARD_LIMIT define will limit heap use alaways less than MAX_HEAP_SIZE
        //but the performance down
        while (MAX_HEAP_SIZE * GARBAGE_OVERLOAD / 100 - collector->obj_heap_size < 0) {
            jthread_block_enter(runtime);
            jthread_block_exit(runtime);//for jthread pause waiting for gc
        }
#endif

#if _JVM_DEBUG_GARBAGE_DUMP > 1
        Utf8String *sus = utf8_create();
        _gc_get_obj_name(runtime->jvm->collector, mb, sus);
        getRuntimeStackWithOutReturn(runtime, sus);
        jvm_printf("R: [%llx]%s\n", (s64) (intptr_t) mb, utf8_cstr(sus));
        utf8_destroy(sus);
#endif
    } else {
        s32 debug = 1;
    }
}

/**
 * Link all objects held by the thread to the GC's linked list.
 * Move the thread's jobject to garbage collection.
 * @param runtime Runtime environment
 */
void gc_move_objs_thread_2_gc(Runtime *runtime) {
    if (runtime) {
        JavaThreadInfo *ti = runtime->thrd_info;
        GcCollector *collector = runtime->jvm->collector;
        //lock
        spin_lock(&collector->lock);
        {
            if (ti->objs_header) {
#if _JVM_DEBUG_GARBAGE_DUMP > 1
                MemoryBlock *mb = ti->objs_header;
                while (mb) {
                    Utf8String *sus = utf8_create();
                    _gc_get_obj_name(runtime->jvm->collector, mb, sus);
                    jvm_printf("M: %s[%llx]\n", utf8_cstr(sus), (s64) (intptr_t) mb);
                    utf8_destroy(sus);
                    mb = mb->next;
                }
#endif
                ti->objs_tailer->next = collector->tmp_header;
                if (!collector->tmp_tailer) {
                    collector->tmp_tailer = ti->objs_tailer;
                }
                collector->tmp_header = ti->objs_header;
                collector->obj_heap_size += ti->objs_heap_of_thread;

                ti->objs_header = NULL;
                ti->objs_tailer = NULL;

                ti->objs_heap_of_thread = 0;
            }
        }
        spin_unlock(&collector->lock);
    }
}

void gc_obj_hold(GcCollector *collector, __refer ref) {
    if (ref) {
        hashset_put(collector->objs_holder, ref);
    }
}

void gc_obj_release(GcCollector *collector, __refer ref) {
    if (ref) {
        hashset_remove(collector->objs_holder, ref, 0);
    }
}

