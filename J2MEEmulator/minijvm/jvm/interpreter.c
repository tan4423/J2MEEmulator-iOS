#include "jvm.h"
#include "jvm_util.h"
#include "jit.h"
#include "garbage.h"
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>

/*
 * JarBox no-dynamic-JIT interpreter. Clang's labels-as-values point only
 * to opcode handlers already compiled and code-signed inside the app.
 * Preserve the original switch for non-Clang/standard builds and JDWP.
 * Use -DTREO_VM_FORCE_SWITCH=1 to compile a matched baseline IPA.
 */
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && defined(__clang__) && !defined(TREO_VM_FORCE_SWITCH)
#define TREO_VM_DIRECT_DISPATCH 1
#define TREO_VM_HANDLER(op) treo_vm_label_##op:
#else
#define TREO_VM_DIRECT_DISPATCH 0
#define TREO_VM_HANDLER(op)
#endif

#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
static _Atomic uint64_t treo_vm_fast_method_batches;
static _Atomic uint64_t treo_vm_switch_method_batches;
// Batched per-thread instrumentation: no atomic increment on each bytecode
// and no expensive clock or event logging inside the interpreter hot loop.
static _Thread_local unsigned treo_vm_fast_pending;
static _Thread_local unsigned treo_vm_switch_pending;
static inline void treo_vm_note_method(int fast) {
    if (fast) {
        if (++treo_vm_fast_pending == 64) {
            atomic_fetch_add_explicit(&treo_vm_fast_method_batches, 64, memory_order_relaxed);
            treo_vm_fast_pending = 0;
        }
    } else if (++treo_vm_switch_pending == 64) {
        atomic_fetch_add_explicit(&treo_vm_switch_method_batches, 64, memory_order_relaxed);
        treo_vm_switch_pending = 0;
    }
}
uint64_t treo_vm_fast_method_calls(void) {
    return atomic_load_explicit(&treo_vm_fast_method_batches, memory_order_relaxed);
}
uint64_t treo_vm_switch_method_calls(void) {
    return atomic_load_explicit(&treo_vm_switch_method_batches, memory_order_relaxed);
}
#else
uint64_t treo_vm_fast_method_calls(void) { return 0; }
uint64_t treo_vm_switch_method_calls(void) { return 0; }
#endif
int treo_vm_direct_dispatch_build(void) { return TREO_VM_DIRECT_DISPATCH; }

// "Paint bridge": preserve the JAR's Canvas.paint() Java logic but skip a
// verified bundled Graphics draw wrapper when its Canvas target is headless.
// This build flag produces a matched baseline without changing the renderer.
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_VM_PAINT_BRIDGE_DISABLED)
#define TREO_VM_PAINT_BRIDGE 1
#else
#define TREO_VM_PAINT_BRIDGE 0
#endif
int treo_vm_paint_bridge_build(void) { return TREO_VM_PAINT_BRIDGE; }

#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_VM_UTF16_FAST_DISABLED)
#define TREO_VM_UTF16_FAST 1
#else
#define TREO_VM_UTF16_FAST 0
#endif
int treo_vm_utf16_fast_build(void) { return TREO_VM_UTF16_FAST; }
#if TREO_VM_UTF16_FAST
static _Atomic uint64_t treo_vm_utf16_batches;
static _Thread_local unsigned treo_vm_utf16_pending;
uint64_t treo_vm_utf16_fast_calls(void) {
    return atomic_load_explicit(&treo_vm_utf16_batches, memory_order_relaxed);
}
static inline void treo_vm_utf16_note(void) {
    if (++treo_vm_utf16_pending == 64) {
        atomic_fetch_add_explicit(&treo_vm_utf16_batches, 64, memory_order_relaxed);
        treo_vm_utf16_pending = 0;
    }
}
static inline int treo_vm_is_bootstrap_high_surrogate(MethodInfo *m) {
    u8 kind = __atomic_load_n(&m->treo_utf16_kind, __ATOMIC_RELAXED);
    if (kind != 0) return kind == 2;
    const JClass *clazz = m->_this_class;
    kind = clazz->jloader == NULL &&
           utf8_equals_c(clazz->name, "java/lang/Character") &&
           utf8_equals_c(m->name, "isHighSurrogate") &&
           utf8_equals_c(m->descriptor, "(C)Z") ? 2 : 1;
    __atomic_store_n(&m->treo_utf16_kind, kind, __ATOMIC_RELAXED);
    return kind == 2;
}
#else
uint64_t treo_vm_utf16_fast_calls(void) { return 0; }
#endif




/*
 * Experimental, opt-in micro-method inline for a narrow *bytecode pattern*,
 * not for any named JAR/class. Pattern matches the 17-byte Java method:
 *    getstatic int[]; iload_1; getstatic int; imul; iload_0; iadd;
 *    iaload; ireturn; astore_2; sipush 1000; ireturn
 * with a matching 0..11 -> 12 exception handler. All invalid/exceptional
 * accesses execute the original Java method; only valid in-bounds reads are
 * accelerated. No JAR bytecode or game state is modified.
 *
 * Dynamic static fields are read on EACH call, so map arrays and dimensions
 * can change. The 32-bit index arithmetic intentionally wraps as Java does.
 * Disabled in all production and existing diagnostic workflows until A/B
 * confirms both behavior and CPU benefit.
 */
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && defined(TREO_VM_ARRAY_LOOKUP_EXPERIMENT)
#define TREO_VM_ARRAY_LOOKUP 1
#else
#define TREO_VM_ARRAY_LOOKUP 0
#endif
int treo_vm_array_lookup_build(void) { return TREO_VM_ARRAY_LOOKUP; }
#if TREO_VM_ARRAY_LOOKUP
static _Atomic uint64_t treo_vm_array_lookup_batches;
static _Thread_local unsigned treo_vm_array_lookup_pending;
uint64_t treo_vm_array_lookup_fast_calls(void) {
    return atomic_load_explicit(&treo_vm_array_lookup_batches, memory_order_relaxed);
}
static inline void treo_vm_array_lookup_note(void) {
    if (++treo_vm_array_lookup_pending == 64) {
        atomic_fetch_add_explicit(&treo_vm_array_lookup_batches, 64, memory_order_relaxed);
        treo_vm_array_lookup_pending = 0;
    }
}
static inline int treo_vm_matches_array_lookup(MethodInfo *m) {
    u8 kind = __atomic_load_n(&m->treo_array_lookup_kind, __ATOMIC_RELAXED);
    if (kind) return kind == 2;
    CodeAttribute *ca = m->converted_code;
    int match = 0;
    if (ca && ca->code_length == 17 && ca->code &&
        ca->exception_table_length == 1 && ca->exception_table) {
        const u8 *c = ca->code;
        const ExceptionTable *e = ca->exception_table;
        match =
            (c[0] == op_getstatic || c[0] == op_getstatic_ref) &&
            c[3] == op_iload_1 &&
            (c[4] == op_getstatic || c[4] == op_getstatic_int) &&
            c[7] == op_imul && c[8] == op_iload_0 &&
            c[9] == op_iadd && c[10] == op_iaload && c[11] == op_ireturn &&
            c[12] == op_astore_2 && c[13] == op_sipush &&
            c[14] == 0x03 && c[15] == 0xe8 && c[16] == op_ireturn &&
            e->start_pc == 0 && e->end_pc == 11 && e->handler_pc == 12;
    }
    kind = match ? 2 : 1;
    __atomic_store_n(&m->treo_array_lookup_kind, kind, __ATOMIC_RELAXED);
    return match;
}
#else
uint64_t treo_vm_array_lookup_fast_calls(void) { return 0; }
#endif


#if TREO_VM_ARRAY_LOOKUP && defined(TREO_VM_ARRAY_LOOKUP_DIAGNOSTIC)
#define TREO_VM_ARRAY_LOOKUP_DIAG 1
#else
#define TREO_VM_ARRAY_LOOKUP_DIAG 0
#endif
#if TREO_VM_ARRAY_LOOKUP_DIAG
// Lightweight staged gate counters, only in the dedicated diagnostic build.
// Batches of 64; cannot be used to compare CPU with normal A/B builds.
static _Atomic uint64_t treo_array_diag_counts[9];
static _Thread_local unsigned treo_array_diag_pending[9];
static _Atomic int treo_array_diag_sample_taken;
static char treo_array_diag_sample[256];
static inline void treo_array_diag_note(int stage) {
    if (++treo_array_diag_pending[stage] == 64) {
        atomic_fetch_add_explicit(&treo_array_diag_counts[stage], 64,
                                  memory_order_relaxed);
        treo_array_diag_pending[stage] = 0;
    }
}
// A single readout, not a per-method print. Low cost on the game thread.
static inline void treo_array_diag_capture(MethodInfo *m, const u8 *code) {
    int not_started = 0;
    if (atomic_compare_exchange_strong_explicit(&treo_array_diag_sample_taken,
            &not_started, 1, memory_order_acq_rel, memory_order_relaxed)) {
        const CodeAttribute *ca = m->converted_code;
        const ExceptionTable *e = ca->exception_table;
        snprintf(treo_array_diag_sample, sizeof(treo_array_diag_sample),
                 "%s.%s b0=%02x b3=%02x b4=%02x b7=%02x b8=%02x "
                 "b9=%02x b10=%02x b11=%02x b12=%02x b13=%02x "
                 "b14=%02x b15=%02x b16=%02x et=%u %u-%u->%u",
                 utf8_cstr(m->_this_class->name), utf8_cstr(m->name),
                 code[0], code[3], code[4], code[7], code[8],
                 code[9], code[10], code[11], code[12], code[13],
                 code[14], code[15], code[16],
                 ca->exception_table_length,
                 e ? e->start_pc : 0, e ? e->end_pc : 0,
                 e ? e->handler_pc : 0);
        atomic_store_explicit(&treo_array_diag_sample_taken, 2,
                              memory_order_release);
    }
}
#endif
const char *treo_vm_array_lookup_diag_report(void) {
#if TREO_VM_ARRAY_LOOKUP_DIAG
    static char report[700];
    snprintf(report, sizeof(report),
             "[JarBoxVM][ArrayLookupDiag] enabled=1 "
             "arity_calls~%llu shape_calls~%llu loose_calls~%llu match_calls~%llu "
             "entered_calls~%llu fields_resolved~%llu "
             "types_ok~%llu array_ok~%llu inbounds_fast~%llu "
             "sample={%s}. Counts batched/64, cumulative per process; "
             "diagnostic CPU is not a valid A/B measurement.",
             (unsigned long long)atomic_load_explicit(&treo_array_diag_counts[8], memory_order_relaxed),
             (unsigned long long)atomic_load_explicit(&treo_array_diag_counts[0], memory_order_relaxed),
             (unsigned long long)atomic_load_explicit(&treo_array_diag_counts[1], memory_order_relaxed),
             (unsigned long long)atomic_load_explicit(&treo_array_diag_counts[2], memory_order_relaxed),
             (unsigned long long)atomic_load_explicit(&treo_array_diag_counts[3], memory_order_relaxed),
             (unsigned long long)atomic_load_explicit(&treo_array_diag_counts[4], memory_order_relaxed),
             (unsigned long long)atomic_load_explicit(&treo_array_diag_counts[5], memory_order_relaxed),
             (unsigned long long)atomic_load_explicit(&treo_array_diag_counts[6], memory_order_relaxed),
             (unsigned long long)atomic_load_explicit(&treo_array_diag_counts[7], memory_order_relaxed),
             atomic_load_explicit(&treo_array_diag_sample_taken,
                                  memory_order_acquire) == 2 ? treo_array_diag_sample : "none");
    return report;
#else
    return "[JarBoxVM][ArrayLookupDiag] enabled=0";
#endif
}

/* Sampled PaintHot attribution. No Java work is omitted; no bytecode hooks. */
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_VM_PAINT_SAMPLE_DISABLED)
#define TREO_VM_PAINT_SAMPLE 1
#else
#define TREO_VM_PAINT_SAMPLE 0
#endif

#if TREO_VM_PAINT_SAMPLE
extern _Atomic int treo_afk_mode;
#include <pthread.h>
#include <time.h>
#include <stdio.h>
#include <string.h>
#define PAINT_RATE 32u
#define PAINT_DEPTH 384u
#define PAINT_LOCAL 256u
#define PAINT_GLOBAL 512u
#define PAINT_PATH_KINDS 3u
#define PAINT_PATH_VARIANTS 2u
#define PAINT_PATH_LEN 640u
typedef struct {
    MethodInfo *method;
    uint64_t self_ns, all_ns, calls;
    // Copy while this method is on the live VM stack, never dereference a
    // possibly unloaded class after its paint callback has returned.
    char signature[176];
} PaintRow;
typedef struct { MethodInfo *method; uint64_t start_ns, children_ns; } PaintFrame;
typedef struct {
    unsigned scope, depth, sampled;
    uint64_t epoch, start_ns, overflow, overflow_ns, depth_errors;
    PaintRow rows[PAINT_LOCAL];
    PaintFrame frames[PAINT_DEPTH];
    char representative_path[PAINT_PATH_KINDS][PAINT_PATH_LEN];
} PaintThread;
typedef struct {
    MethodInfo *method;
    uint64_t self_ns, all_ns, calls;
    char signature[176];
} PaintGlobal;
static _Thread_local PaintThread paint_tls;
static PaintGlobal paint_global[PAINT_GLOBAL];
static pthread_mutex_t paint_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t paint_epoch = 1, paint_seen;
static uint64_t paint_samples, paint_cpu_ns, paint_overflow, paint_overflow_ns, paint_depth_errors;
// Compare measured CPU of selected and ordinary paints without any extra clock.
static _Atomic uint64_t paint_selected_count, paint_plain_count;
static _Atomic uint64_t paint_selected_ns, paint_plain_ns;
static char paint_report[8192];
static char paint_paths[PAINT_PATH_KINDS][PAINT_PATH_VARIANTS][PAINT_PATH_LEN];

static inline uint64_t paint_clock_ns(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
static inline unsigned paint_hash(MethodInfo *m, unsigned mask) {
    uintptr_t n = (uintptr_t)m;
    return (unsigned)((n >> 4) ^ (n >> 13) ^ (n >> 23)) & mask;
}
void treo_vm_paint_sample_reset(void) {
    pthread_mutex_lock(&paint_lock);
    atomic_fetch_add_explicit(&paint_epoch, 1, memory_order_release);
    atomic_store_explicit(&paint_seen, 0, memory_order_relaxed);
    memset(paint_global, 0, sizeof(paint_global));
    memset(paint_paths, 0, sizeof(paint_paths));
    paint_samples = paint_cpu_ns = paint_overflow = paint_overflow_ns = paint_depth_errors = 0;
    atomic_store_explicit(&paint_selected_count,0,memory_order_relaxed);
    atomic_store_explicit(&paint_plain_count,0,memory_order_relaxed);
    atomic_store_explicit(&paint_selected_ns,0,memory_order_relaxed);
    atomic_store_explicit(&paint_plain_ns,0,memory_order_relaxed);
    pthread_mutex_unlock(&paint_lock);
}
void treo_vm_paint_sample_begin(void) {
    PaintThread *t = &paint_tls;
    if (t->scope) { t->scope++; return; }
    if (atomic_load_explicit(&treo_afk_mode, memory_order_relaxed) != 8) return;
    t->scope = 1;
    t->epoch = atomic_load_explicit(&paint_epoch, memory_order_acquire);
    unsigned n = (unsigned)atomic_fetch_add_explicit(&paint_seen, 1, memory_order_relaxed);
    t->sampled = (n % PAINT_RATE) == 0;
    if (!t->sampled) return;
    t->depth = 0;
    t->overflow = t->overflow_ns = t->depth_errors = 0;
    memset(t->rows, 0, sizeof(t->rows));
    memset(t->representative_path, 0, sizeof(t->representative_path));
    t->start_ns = paint_clock_ns();
}

// Only one call-chain snapshot per target per sampled paint. Crucially this
// uses the already-maintained method stack, not a new CPU clock or timer.
// Representative paths are *not* an exhaustive call graph.
static inline void paint_capture_origin(PaintThread *t, MethodInfo *method) {
    unsigned kind = PAINT_PATH_KINDS;
    if (!t->representative_path[0][0] &&
        utf8_equals_c(method->_this_class->name, "java/io/ByteArrayOutputStream") &&
        utf8_equals_c(method->name, "write") &&
        utf8_equals_c(method->descriptor, "([BII)V")) kind = 0;
    else if (!t->representative_path[1][0] &&
        utf8_equals_c(method->_this_class->name, "com/sun/cldc/i18n/j2me/UTF_8_Writer") &&
        utf8_equals_c(method->name, "write") &&
        utf8_equals_c(method->descriptor, "([CII)V")) kind = 1;
    else if (!t->representative_path[2][0] &&
        utf8_equals_c(method->_this_class->name, "org/mini/fs/InnerFile") &&
        utf8_equals_c(method->name, "loadFS") &&
        utf8_equals_c(method->descriptor, "([BLorg/mini/fs/InnerFileStat;)I")) kind = 2;
    if (kind == PAINT_PATH_KINDS) return;
    char *dst = t->representative_path[kind];
    const size_t cap = PAINT_PATH_LEN;
    int used = snprintf(dst, cap, "%s.%s", utf8_cstr(method->_this_class->name),
                        utf8_cstr(method->name));
    // Show the immediate caller first and walk up toward game paint.
    const unsigned bounded_depth = t->depth < PAINT_DEPTH ? t->depth : PAINT_DEPTH;
    for (int depth = (int)bounded_depth - 1, shown = 0;
         depth >= 0 && shown < 12 && used >= 0 && (size_t)used < cap;
         --depth, ++shown) {
        MethodInfo *caller = t->frames[depth].method;
        if (!caller) break;
        used += snprintf(dst + used, cap - (size_t)used, " <- %s.%s",
                         utf8_cstr(caller->_this_class->name),
                         utf8_cstr(caller->name));
    }
}

static inline int treo_vm_paint_method_enter(MethodInfo *m) {
    PaintThread *t = &paint_tls;
    if (__builtin_expect(!t->sampled, 1)) return 0;
    // Its native callback terminates the scope before execute_method_impl returns.
    if (m->is_native && utf8_equals_c(m->name, "profilePaintEnd") &&
        utf8_equals_c(m->_this_class->name, "javax/microedition/lcdui/NativeBridge")) return 0;
    // Do not inspect bytecode or modify calls; only snapshot ancestry for
    // three known runtime hot methods, once each per sampled paint.
    if (!t->representative_path[0][0] || !t->representative_path[1][0] ||
        !t->representative_path[2][0])
        paint_capture_origin(t, m);
    unsigned d = t->depth++;
    if (d >= PAINT_DEPTH) { t->depth_errors++; return 2; }
    PaintFrame *f = &t->frames[d];
    f->method = m;
    f->children_ns = 0;
    f->start_ns = paint_clock_ns();
    return 1;
}
static inline void treo_vm_paint_method_exit(MethodInfo *m, int token) {
    if (!token) return;
    PaintThread *t = &paint_tls;
    if (!t->sampled || !t->depth) return;
    unsigned d = --t->depth;
    if (token == 2 || d >= PAINT_DEPTH) return;
    PaintFrame *f = &t->frames[d];
    uint64_t now = paint_clock_ns();
    if (f->method != m || now < f->start_ns) { t->depth_errors++; return; }
    uint64_t all = now - f->start_ns;
    uint64_t self = all >= f->children_ns ? all - f->children_ns : 0;
    if (d && d - 1 < PAINT_DEPTH) t->frames[d - 1].children_ns += all;
    unsigned index = paint_hash(m, PAINT_LOCAL - 1);
    for (unsigned i = 0; i < PAINT_LOCAL; i++) {
        PaintRow *r = &t->rows[index];
        if (!r->method || r->method == m) {
            if (!r->method) {
                snprintf(r->signature, sizeof(r->signature), "%s.%s%s",
                    utf8_cstr(m->_this_class->name), utf8_cstr(m->name),
                    utf8_cstr(m->descriptor));
            }
            r->method = m; r->calls++; r->self_ns += self; r->all_ns += all; return;
        }
        index = (index + 1) & (PAINT_LOCAL - 1);
    }
    t->overflow++; t->overflow_ns += self;
}
int treo_vm_paint_sample_end(void) {
    PaintThread *t = &paint_tls;
    if (!t->scope || --t->scope) return -1;
    const int selected = t->sampled ? 1 : 0;
    if (!selected) return 0;
    uint64_t now = paint_clock_ns();
    // If a nonlocal VM unwind bypassed any return hook, discard its
    // incomplete frames and expose the error rather than silently attributing
    // their CPU to a different paint callback.
    if (t->depth) {
        t->depth_errors += t->depth;
        t->depth = 0;
    }
    t->sampled = 0;
    pthread_mutex_lock(&paint_lock);
    if (t->epoch == atomic_load_explicit(&paint_epoch, memory_order_acquire)) {
        paint_samples++;
        if (now >= t->start_ns) paint_cpu_ns += now - t->start_ns;
        paint_overflow += t->overflow;
        paint_overflow_ns += t->overflow_ns;
        paint_depth_errors += t->depth_errors;
        for (unsigned kind = 0; kind < PAINT_PATH_KINDS; ++kind) {
            const char *path = t->representative_path[kind];
            if (!path[0]) continue;
            for (unsigned slot = 0; slot < PAINT_PATH_VARIANTS; ++slot) {
                char *dst = paint_paths[kind][slot];
                if (!dst[0]) {
                    memcpy(dst, path, PAINT_PATH_LEN);
                    break;
                }
                if (strncmp(dst, path, PAINT_PATH_LEN) == 0) break;
            }
        }
        for (unsigned i = 0; i < PAINT_LOCAL; ++i) {
            const PaintRow *src = &t->rows[i];
            if (!src->method) continue;
            unsigned index = paint_hash(src->method, PAINT_GLOBAL - 1);
            for (unsigned j = 0; j < PAINT_GLOBAL; ++j) {
                PaintGlobal *dst = &paint_global[index];
                if (!dst->method || dst->method == src->method) {
                    if (!dst->method) {
                        dst->method = src->method;
                        memcpy(dst->signature, src->signature, sizeof(dst->signature));
                    }
                    dst->calls += src->calls;
                    dst->self_ns += src->self_ns;
                    dst->all_ns += src->all_ns;
                    break;
                }
                index = (index + 1) & (PAINT_GLOBAL - 1);
                if (j == PAINT_GLOBAL - 1) {
                    paint_overflow += src->calls; paint_overflow_ns += src->self_ns;
                }
            }
        }
    }
    pthread_mutex_unlock(&paint_lock);
    return selected;
}
void treo_vm_paint_sample_note_duration(int sampled, uint64_t ns) {
    if (sampled < 0) return;
    atomic_fetch_add_explicit(sampled ? &paint_selected_count : &paint_plain_count, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(sampled ? &paint_selected_ns : &paint_plain_ns, ns, memory_order_relaxed);
}
const char *treo_vm_paint_sample_report(void) {
    pthread_mutex_lock(&paint_lock);
    int top[8];
    for (int i = 0; i < 8; ++i) top[i] = -1;
    uint64_t counted = 0;
    for (unsigned i = 0; i < PAINT_GLOBAL; ++i) {
        if (!paint_global[i].method) continue;
        counted += paint_global[i].self_ns;
        for (int k = 0; k < 8; ++k) {
            if (top[k] < 0 || paint_global[i].self_ns > paint_global[top[k]].self_ns) {
                for (int p = 7; p > k; --p) top[p] = top[p - 1];
                top[k] = (int)i; break;
            }
        }
    }
    const uint64_t selCount = atomic_load_explicit(&paint_selected_count, memory_order_relaxed);
    const uint64_t plainCount = atomic_load_explicit(&paint_plain_count, memory_order_relaxed);
    const double selMean = selCount ? (double)atomic_load_explicit(&paint_selected_ns, memory_order_relaxed) / (selCount*1000000.) : 0.;
    const double plainMean = plainCount ? (double)atomic_load_explicit(&paint_plain_ns, memory_order_relaxed) / (plainCount*1000000.) : 0.;
    int used = snprintf(paint_report, sizeof(paint_report),
        "[JarBoxVM][PaintHot] enabled=1 rate=1/32 paints=%llu sampled=%llu "
        "sampledCPU=%.2fms selfSum=%.2fms dropped=%llu droppedSelf=%.2fms depthOverflow=%llu "
        "sampled_paint_avg=%.2fms(%llu) plain_paint_avg=%.2fms(%llu) observer_ratio=%.2fx",
        (unsigned long long)atomic_load_explicit(&paint_seen, memory_order_relaxed),
        (unsigned long long)paint_samples, (double)paint_cpu_ns/1000000.,
        (double)counted/1000000., (unsigned long long)paint_overflow,
        (double)paint_overflow_ns/1000000., (unsigned long long)paint_depth_errors,
        selMean, (unsigned long long)selCount, plainMean, (unsigned long long)plainCount,
        plainMean > 0 ? selMean/plainMean : 0.);
    for (int k = 0; k < 8 && top[k] >= 0; ++k) {
        if (used < 0 || (size_t)used >= sizeof(paint_report)) break;
        const PaintGlobal *r = &paint_global[top[k]];
        used += snprintf(paint_report+used, sizeof(paint_report)-(size_t)used,
            "\n[JarBoxVM][PaintHot] #%d self=%.2fms (%.1f%% sampledCPU) inclusive=%.2fms calls=%llu %s",
            k+1, (double)r->self_ns/1000000.,
            paint_cpu_ns ? 100.0 * (double)r->self_ns / (double)paint_cpu_ns : 0.0,
            (double)r->all_ns/1000000.,
            (unsigned long long)r->calls, r->signature);
    }
    const char *const path_names[PAINT_PATH_KINDS] = {
        "ByteArrayOutputStream.write([BII)",
        "UTF_8_Writer.write([CII)",
        "InnerFile.loadFS([B,...)"};
    for (unsigned kind = 0; kind < PAINT_PATH_KINDS; ++kind) {
        for (unsigned variant = 0; variant < PAINT_PATH_VARIANTS; ++variant) {
            const char *path = paint_paths[kind][variant];
            if (!path[0] || used < 0 || (size_t)used >= sizeof(paint_report)) continue;
            used += snprintf(paint_report + used, sizeof(paint_report) - (size_t)used,
                             "\n[JarBoxVM][PaintPath] %s path%u: %s",
                             path_names[kind], variant + 1, path);
        }
    }
    pthread_mutex_unlock(&paint_lock);
    return paint_report;
}
#else
void treo_vm_paint_sample_reset(void) {}
void treo_vm_paint_sample_begin(void) {}
int treo_vm_paint_sample_end(void) { return -1; }
void treo_vm_paint_sample_note_duration(int sampled, uint64_t ns) {(void)sampled;(void)ns;}
const char *treo_vm_paint_sample_report(void) {
    return "[JarBoxVM][PaintHot] enabled=0 (same-source baseline)";
}
#endif


#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
extern _Atomic int treo_afk_mode;
extern int treo_afk_elide_graphics(JClass *clazz, Instance *receiver);
extern int treo_direct_graphics_enabled(void);

static int treo_headless_eligible(MethodInfo *m) {
    u8 tag = __atomic_load_n(&m->treo_afk_kind, __ATOMIC_RELAXED);
    if (tag) return tag == 2;
    tag = 1;
    JClass *clazz = m->_this_class;
    static const char *const allowed[][2] = {
        {"drawRegion", "(Ljavax/microedition/lcdui/Image;IIIIIIII)V"},
        {"drawImage", "(Ljavax/microedition/lcdui/Image;III)V"},
        {"drawString", "(Ljava/lang/String;III)V"},
        {"drawChar", "(CIII)V"},
        {"drawLine", "(IIII)V"}, {"fillRect", "(IIII)V"}, {"drawRect", "(IIII)V"},
        {"fillArc", "(IIIIII)V"}, {"drawArc", "(IIIIII)V"},
        {"fillRoundRect", "(IIIIII)V"}, {"drawRoundRect", "(IIIIII)V"},
        {"fillTriangle", "(IIIIII)V"}, {"drawRGB", "([IIIIIIIZ)V"}
    };
    if (utf8_equals_c(clazz->name, "javax/microedition/lcdui/Graphics")) {
        for (s32 n = 0; n < clazz->fieldPool.field_used; ++n) {
            FieldInfo *f = &clazz->fieldPool.field[n];
            if (!(f->access_flags & 8) || !utf8_equals_c(f->name, "TREO_HEADLESS_ELISION_ABI_V1") ||
                !utf8_equals_c(f->descriptor, "I")) continue;
            for (size_t k = 0; k < sizeof(allowed)/sizeof(allowed[0]); ++k) {
                if (utf8_equals_c(m->name, allowed[k][0]) && utf8_equals_c(m->descriptor, allowed[k][1])) {
                    tag = 2; break;
                }
            }
            break;
        }
    }
    __atomic_store_n(&m->treo_afk_kind, tag, __ATOMIC_RELAXED);
    return tag == 2;
}
extern int treo_try_graphics_draw_region(Runtime *runtime, JClass *clazz);
extern int treo_jar_audit_enabled(void);
extern void treo_jar_audit_tick(int active);

// Passive probe for this exact JAR helper, called once per normal game tick.
// Read the flag on the VM thread, before executing the original method.
static void treo_jar_audit_observe(MethodInfo *m, JClass *c) {
    u8 tag = __atomic_load_n(&m->treo_jar_audit_kind, __ATOMIC_RELAXED);
    if (!tag) {
        tag = (utf8_equals_c(c->name, "NickCpuSleep") &&
               utf8_equals_c(m->name, "requestFrame") &&
               utf8_equals_c(m->descriptor, "(LClass_hef;)V")) ? 2 : 1;
        __atomic_store_n(&m->treo_jar_audit_kind, tag, __ATOMIC_RELAXED);
    }
    if (tag != 2) return;
    for (s32 n = 0; n < c->fieldPool.field_used; ++n) {
        FieldInfo *f = &c->fieldPool.field[n];
        if ((f->access_flags & 0x0008) && utf8_equals_c(f->name, "active") &&
            utf8_equals_c(f->descriptor, "Z")) {
            const s8 *flag = (const s8 *)getStaticFieldPtr(f);
            if (flag) treo_jar_audit_tick(__atomic_load_n(flag, __ATOMIC_RELAXED) != 0);
            return;
        }
    }
}
static int treo_is_bundled_draw_region(MethodInfo *method, JClass *clazz) {
    u8 tag = __atomic_load_n(&method->treo_graphics_kind, __ATOMIC_RELAXED);
    if (tag) return tag == 2;
    tag = 1;
    if (utf8_equals_c(clazz->name, "javax/microedition/lcdui/Graphics") &&
        utf8_equals_c(method->name, "drawRegion") &&
        utf8_equals_c(method->descriptor, "(Ljavax/microedition/lcdui/Image;IIIIIIII)V")) {
        for (s32 n = 0; n < clazz->fieldPool.field_used; n++) {
            FieldInfo *f = &clazz->fieldPool.field[n];
            if ((f->access_flags & 0x0008) && utf8_equals_c(f->name, "TREO_DRAW_REGION_ABI_V2") &&
                utf8_equals_c(f->descriptor, "I")) { tag = 2; break; }
        }
    }
    __atomic_store_n(&method->treo_graphics_kind, tag, __ATOMIC_RELAXED);
    return tag == 2;
}
#endif


/* ==================================opcode implementation =============================*/




void _op_notsupport(u8 *opCode, Runtime *runtime) {
    invoke_deepth(runtime);
    jvm_printf("not support instruct [%x]\n", opCode[0]);
    exit(2);
}

//----------------------------------  tool func  ------------------------------------------


s32 exception_handle(RuntimeStack *stack, Runtime *runtime) {

    Instance *ins = pop_ref(stack);
    CodeAttribute *ca = runtime->method->converted_code;

#if _JVM_DEBUG_LOG_LEVEL > 3
    JClass *clazz = runtime->clazz;
    s32 lineNum = getLineNumByIndex(runtime->method->converted_code, (s32) (runtime->pc - runtime->method->converted_code->code));
    jvm_printf("Exception   at %s.%s(%s.java:%d)\n",
               utf8_cstr(clazz->name), utf8_cstr(runtime->method->name),
               utf8_cstr(clazz->name),
               lineNum
    );
#endif
    s32 index = 0;
    ExceptionTable *et = NULL;// _find_exception_handler(runtime, ins, ca, (s32) (runtime->pc - ca->code), &index);
    s32 offset = (s32) (runtime->pc - ca->code);
    s32 i;
    ExceptionTable *e = ca->exception_table;
    for (i = 0; i < ca->exception_table_length; i++) {

        if (offset >= (e + i)->start_pc
            && offset < (e + i)->end_pc) {
            if (!(e + i)->catch_type) {
                et = e + i;
                index = i;
                break;
            }
            ConstantClassRef *ccr = class_get_constant_classref(runtime->clazz, (e + i)->catch_type);
            JClass *catchClass = classes_load_get_with_clinit(runtime->clazz->jloader, ccr->name, runtime);
            if (instance_of(ins, catchClass)) {
                et = e + i;
                index = i;
                break;
            }
        }
    }
    if (et == NULL) {
        localvar_dispose(runtime);
        push_ref(stack, ins);
        return 0;
    } else {
        push_ref(stack, ins);
#if _JVM_DEBUG_LOG_LEVEL > 3
        jvm_printf("Exception : %s\n", utf8_cstr(ins->mb.clazz->name));
#endif
        runtime->pc = (ca->code + et->handler_pc);
        jit_set_exception_jump_addr(runtime, ca, index);
        return 1;
    }

}

s32 _jarray_check_exception(Instance *arr, s32 index, Runtime *runtime) {
    if (!arr) {
        Instance *exception = exception_create(JVM_EXCEPTION_NULLPOINTER, runtime);
        push_ref(runtime->stack, (__refer) exception);
    } else if (index >= arr->arr_length || index < 0) {
        Instance *exception = exception_create(JVM_EXCEPTION_ARRAYINDEXOUTOFBOUNDS, runtime);
        push_ref(runtime->stack, (__refer) exception);
    } else {
        return RUNTIME_STATUS_NORMAL;
    }
    return RUNTIME_STATUS_EXCEPTION;
}

void _outofbounds_throw_exception(RuntimeStack *stack, Runtime *runtime) {
    Instance *exception = exception_create(JVM_EXCEPTION_ARRAYINDEXOUTOFBOUNDS, runtime);
    push_ref(runtime->stack, (__refer) exception);
}

void _null_throw_exception(RuntimeStack *stack, Runtime *runtime) {
    Instance *exception = exception_create(JVM_EXCEPTION_NULLPOINTER, runtime);
    push_ref(stack, (__refer) exception);
}

void _nosuchmethod_check_exception(c8 const *mn, RuntimeStack *stack, Runtime *runtime) {
    Instance *exception = exception_create_str(JVM_EXCEPTION_NOSUCHMETHOD, runtime, mn);
    push_ref(stack, (__refer) exception);
}

void _nosuchfield_check_exception(c8 const *mn, RuntimeStack *stack, Runtime *runtime) {
    Instance *exception = exception_create_str(JVM_EXCEPTION_NOSUCHFIELD, runtime, mn);
    push_ref(stack, (__refer) exception);
}

void _arrithmetic_throw_exception(RuntimeStack *stack, Runtime *runtime) {
    Instance *exception = exception_create(JVM_EXCEPTION_ARRITHMETIC, runtime);
    push_ref(stack, (__refer) exception);
}

void _checkcast_throw_exception(RuntimeStack *stack, Runtime *runtime) {
    Instance *exception = exception_create(JVM_EXCEPTION_CLASSCAST, runtime);
    push_ref(stack, (__refer) exception);
}


static s32 filterClassName(Utf8String *clsName) {
    if (utf8_indexof_c(clsName, "com/sun") < 0
        && utf8_indexof_c(clsName, "java/") < 0
        && utf8_indexof_c(clsName, "javax/") < 0) {
        return 1;
    }
    return 0;
}

#define check_gc_pause(offset){\
    if (offset < 0 && thrd_info->suspend_count) {\
        \
        runtime->stack->sp = sp;\
        check_suspend_and_pause(runtime);\
    }\
}

s32 invokedynamic_prepare(Runtime *runtime, BootstrapMethod *bootMethod, ConstantInvokeDynamic *cid) {
    // =====================================================================
    //         run bootstrap method java.lang.invoke.LambdaMetafactory
    //
    //         public static CallSite metafactory(
    //                   MethodHandles.Lookup caller,
    //                   String invokedName,
    //                   MethodType invokedType,
    //                   MethodType samMethodType,
    //                   MethodHandle implMethod,
    //                   MethodType instantiatedMethodType
    //                   )
    //          public static CallSite altMetafactory(
    //                   MethodHandles.Lookup caller,
    //                   String invokedName,
    //                   MethodType invokedType,
    //                   MethodType methodType,
    //                   MethodHandle methodImplementation,
    //                   MethodType instantiatedMethodType,
    //                   int flags,
    //                   int markerInterfaceCount,  // IF flags has MARKERS set
    //                   Class... markerInterfaces, // IF flags has MARKERS set
    //                   int bridgeCount,           // IF flags has BRIDGES set
    //                   MethodType... bridges      // IF flags has BRIDGES set
    //                 )
    //
    //          to generate Lambda Class implementation specify interface
    //          and new a callsite
    // =====================================================================
    JClass *clazz = runtime->clazz;
    RuntimeStack *stack = runtime->stack;

    //parper bootMethod parameter
    Instance *lookup = method_handles_lookup_create(runtime, clazz);
    push_ref(stack, lookup); //lookup

    Utf8String *ustr_invokeName = class_get_constant_utf8(clazz, class_get_constant_name_and_type(clazz, cid->nameAndTypeIndex)->nameIndex)->utfstr;
    Instance *jstr_invokeName = jstring_create(ustr_invokeName, runtime);
    push_ref(stack, jstr_invokeName); //invokeName

    Utf8String *ustr_invokeType = class_get_constant_utf8(clazz, class_get_constant_name_and_type(clazz, cid->nameAndTypeIndex)->typeIndex)->utfstr;
    Instance *mt_invokeType = method_type_create(runtime, clazz->jloader, ustr_invokeType);
    push_ref(stack, mt_invokeType); //invokeMethodType

    //other bootMethod parameter

    //if bootMethod->num_bootstrap_arguments <= 3 call metafactory, if >3 call altMetafactory.
    Instance *more_args = NULL;
    s32 args_cnt = bootMethod->num_bootstrap_arguments;
    static const s32 ALT_PARA = 3;
    if (args_cnt > ALT_PARA) {
        Utf8String *ustr = utf8_create_c(STR_INS_JAVA_LANG_OBJECT);
        more_args = jarray_create_by_type_name(runtime, args_cnt, ustr, clazz->jloader);
        utf8_destroy(ustr);

        push_ref(stack, more_args);
    }
    s32 i;
    for (i = 0; i < args_cnt; i++) {
        ConstantItem *item = class_get_constant_item(clazz, bootMethod->bootstrap_arguments[i]);
        switch (item->tag) {
            case CONSTANT_METHOD_TYPE: {
                ConstantMethodType *cmt = (ConstantMethodType *) item;
                Utf8String *arg = class_get_constant_utf8(clazz, cmt->descriptor_index)->utfstr;
                Instance *mt = method_type_create(runtime, clazz->jloader, arg);
                if (args_cnt <= ALT_PARA) {
                    push_ref(stack, mt);
                } else {
                    jarray_set_field(more_args, i, (s64) (intptr_t) mt);
                }
                break;
            }
            case CONSTANT_STRING_REF: {
                ConstantStringRef *csr = (ConstantStringRef *) item;
                Utf8String *arg = class_get_constant_utf8(clazz, csr->stringIndex)->utfstr;
                Instance *spec = jstring_create(arg, runtime);
                if (args_cnt <= ALT_PARA) {
                    push_ref(stack, spec);
                } else {
                    jarray_set_field(more_args, i, (s64) (intptr_t) spec);
                }
                break;
            }
            case CONSTANT_METHOD_HANDLE: {
                ConstantMethodHandle *cmh = (ConstantMethodHandle *) item;
                MethodInfo *mip = find_methodInfo_by_methodref(clazz, cmh->reference_index, runtime);
                Instance *mh = method_handle_create(runtime, mip, cmh->reference_kind);
                if (args_cnt <= ALT_PARA) {
                    push_ref(stack, mh);
                } else {
                    jarray_set_field(more_args, i, (s64) (intptr_t) mh);
                }
                break;
            }
            case CONSTANT_INTEGER: {
                ConstantInteger *ci = (ConstantInteger *) item;
                push_int(stack, ci->value);
                s32 ret = execute_method_impl(runtime->jvm->shortcut.int_valueOf, runtime);
                if (ret != RUNTIME_STATUS_NORMAL) {
                    _null_throw_exception(stack, runtime);
                    return RUNTIME_STATUS_EXCEPTION;
                }
                if (args_cnt <= ALT_PARA) {
                } else {
                    Instance *ins = pop_ref(stack);
                    jarray_set_field(more_args, i, (s64) (intptr_t) ins);
                }
                break;
            }
            default: {
                jvm_printf("invokedynamic para parse error. para type: %d", item->tag);

                if (args_cnt <= ALT_PARA) {
                    StackEntry entry;
                    entry.lvalue = 0;
                    entry.rvalue = NULL;
                    push_entry(stack, &entry);
                } else {
                    jarray_set_field(more_args, i, 0);
                }
            }
        }

    }

    //get bootmethod
    MethodInfo *boot_m = find_methodInfo_by_methodref(clazz, class_get_method_handle(clazz, bootMethod->bootstrap_method_ref)->reference_index, runtime);
    if (!boot_m) {
        ConstantMethodRef *cmr = class_get_constant_method_ref(clazz, class_get_method_handle(clazz, bootMethod->bootstrap_method_ref)->reference_index);
        _nosuchmethod_check_exception(utf8_cstr(cmr->name), stack, runtime);
        return RUNTIME_STATUS_EXCEPTION;
    } else {
        s32 ret = execute_method_impl(boot_m, runtime);
        if (ret == RUNTIME_STATUS_NORMAL) {
            MethodInfo *finder = find_methodInfo_by_name_c("org/mini/vm/LambdaUtil",
                                                           "getMethodInfoHandle",
                                                           "(Ljava/lang/invoke/CallSite;)J", NULL,
                                                           runtime);
            if (!finder) {
                _nosuchmethod_check_exception("getMethodInfoHandle", stack, runtime);
                return RUNTIME_STATUS_EXCEPTION;
            } else {
                //run finder to convert calsite.target(MethodHandle) to MethodInfo * pointer
                ret = execute_method_impl(finder, runtime);
                if (ret == RUNTIME_STATUS_NORMAL) {
                    MethodInfo *make = (MethodInfo *) (intptr_t) pop_long(stack);
                    bootMethod->make = make;
                }
            }
        } else {
            return ret;
        }
    }
    return RUNTIME_STATUS_NORMAL;
}

s32 checkcast(Runtime *runtime, Instance *ins, s32 typeIdx) {

    JClass *clazz = runtime->clazz;
    if (ins != NULL) {
        if (ins->mb.type == MEM_TYPE_INS) {
            JClass *other = getClassByConstantClassRef(clazz, typeIdx, runtime);
            if (instance_of(ins, other)) {
                return 1;
            }
        } else if (ins->mb.type == MEM_TYPE_ARR) {
            Utf8String *utf = class_get_constant_classref(clazz, typeIdx)->name;
            u8 ch = utf8_char_at(utf, 1);
            if (getDataTypeIndex(ch) == ins->mb.clazz->mb.arr_type_index) {
                return 1;
            }
        } else if (ins->mb.type == MEM_TYPE_CLASS) {
            Utf8String *utf = class_get_constant_classref(clazz, typeIdx)->name;
            if (utf8_equals_c(utf, STR_CLASS_JAVA_LANG_CLASS)) {
                return 1;
            }
        }
    } else {
        return 1;
    }
    return 0;
}

/**
 * Store the method call parameters from the stack into the method's local variables.
 * Before calling a method, the parent program pushes the function parameters onto the stack.
 * When the method is called, the parameters from the stack need to be stored in the local variables.
 * @param method  Method being called
 * @param father  Runtime of the parent
 * @param son     Runtime of the child
 */
static inline void _synchronized_lock_method(MethodInfo *method, Runtime *runtime) {
    //synchronized process
    if (!jdwp_is_ignore_sync(runtime->jvm->jdwpserver)) {
        if (method->is_static) {
            runtime->lock = (MemoryBlock *) runtime->clazz;
        } else {
            runtime->lock = (MemoryBlock *) localvar_getRefer(runtime->localvar, 0);
        }
        jthread_lock(runtime->lock, runtime);
    }
}

static inline void _synchronized_unlock_method(MethodInfo *method, Runtime *runtime) {
    //synchronized process
    if (!jdwp_is_ignore_sync(runtime->jvm->jdwpserver)) {
        jthread_unlock(runtime->lock, runtime);
        runtime->lock = NULL;
    }
}

/**
 *    only static and special can be optimize , invokevirtual and invokeinterface may called by diff instance
 * @param subm
 * @param parent_method_code
 */
static inline void _optimize_empty_method_call(MethodInfo *subm, CodeAttribute *parent_ca, u8 *parent_method_code) {
    CodeAttribute *ca = subm->converted_code;
#ifndef TREO_IOS_GAME_JIT
    u8 *parent_jit_code = &parent_ca->bytecode_for_jit[parent_method_code - parent_ca->code];
#endif
    if (ca && ca->code_length == 1 && *ca->code == op_return) {//empty method, do nothing
        s32 paras = subm->para_slots;//

        if (paras == 0) {
            *parent_method_code = op_nop;
            *(parent_method_code + 1) = op_nop;
            *(parent_method_code + 2) = op_nop;

#ifndef TREO_IOS_GAME_JIT
            *parent_jit_code = op_nop;
            *(parent_jit_code + 1) = op_nop;
            *(parent_jit_code + 2) = op_nop;
#endif
        } else if (paras == 1) {
            *parent_method_code = op_pop;
            *(parent_method_code + 1) = op_nop;
            *(parent_method_code + 2) = op_nop;

#ifndef TREO_IOS_GAME_JIT
            *parent_jit_code = op_pop;
            *(parent_jit_code + 1) = op_nop;
            *(parent_jit_code + 2) = op_nop;
#endif
        } else if (paras == 2) {
            *parent_method_code = op_pop2;
            *(parent_method_code + 1) = op_nop;
            *(parent_method_code + 2) = op_nop;

#ifndef TREO_IOS_GAME_JIT
            *parent_jit_code = op_pop2;
            *(parent_jit_code + 1) = op_nop;
            *(parent_jit_code + 2) = op_nop;
#endif
        }
    }
}


static inline s32 _optimize_inline_getter(JClass *clazz, s32 cfrIdx, Runtime *runtime) {

    RuntimeStack *stack = runtime->stack;
    FieldInfo *fi = class_get_constant_fieldref(clazz, cfrIdx)->fieldInfo;
    if (!fi) {
        ConstantFieldRef *cfr = class_get_constant_fieldref(clazz, cfrIdx);
        fi = find_fieldInfo_by_fieldref(clazz, cfr->item.index, runtime);
        cfr->fieldInfo = fi;
        if (!fi) {
            _nosuchfield_check_exception(utf8_cstr(cfr->name), runtime->stack, runtime);
            return RUNTIME_STATUS_EXCEPTION;
        }
    }
    Instance *fins = pop_ref(stack);
    if (!fins) {
        _null_throw_exception(stack, runtime);
        return RUNTIME_STATUS_EXCEPTION;
    }
    if (fi->_this_class->status < CLASS_STATUS_CLINITED) {
        class_clinit(fi->_this_class, runtime);
    }
    if (fi->isrefer) {
        push_ref(stack, *((__refer *) (getInstanceFieldPtr(fins, fi))));
    } else {
        // check variable type to determine s64/s32/f64/f32
        s32 data_bytes = fi->datatype_bytes;
        switch (data_bytes) {
            case 4: {
                push_int(stack, *((s32 *) (getInstanceFieldPtr(fins, fi))));
                break;
            }
            case 1: {
                push_int(stack, *((s8 *) (getInstanceFieldPtr(fins, fi))));
                break;
            }
            case 8: {
                push_long(stack, *((s64 *) (getInstanceFieldPtr(fins, fi))));
                break;
            }
            case 2: {
                if (fi->datatype_idx == DATATYPE_JCHAR) {
                    push_int(stack, *((u16 *) (getInstanceFieldPtr(fins, fi))));
                } else {
                    push_int(stack, *((s16 *) (getInstanceFieldPtr(fins, fi))));
                }
                break;
            }
            default: {
                break;
            }
        }
    }
    return RUNTIME_STATUS_NORMAL;
}

static inline s32 _optimize_inline_setter(JClass *clazz, s32 cfrIdx, Runtime *runtime) {

    RuntimeStack *stack = runtime->stack;
    FieldInfo *fi = class_get_constant_fieldref(clazz, cfrIdx)->fieldInfo;
    if (!fi) {
        ConstantFieldRef *cfr = class_get_constant_fieldref(clazz, cfrIdx);
        fi = find_fieldInfo_by_fieldref(clazz, cfr->item.index, runtime);
        cfr->fieldInfo = fi;
        if (!fi) {
            _nosuchfield_check_exception(utf8_cstr(cfr->name), runtime->stack, runtime);
            return RUNTIME_STATUS_EXCEPTION;
        }
    }

    if (fi->_this_class->status < CLASS_STATUS_CLINITED) {
        class_clinit(fi->_this_class, runtime);
    }
    if (fi->isrefer) {
        __refer v = pop_ref(stack);
        Instance *fins = pop_ref(stack);
        if (!fins) {
            _null_throw_exception(stack, runtime);
            return RUNTIME_STATUS_EXCEPTION;
        }
        *((__refer *) (getInstanceFieldPtr(fins, fi))) = v;
    } else {
        // check variable type to determine s64/s32/f64/f32
        s32 data_bytes = fi->datatype_bytes;
        switch (data_bytes) {
            case 4: {
                s32 v = pop_int(stack);
                Instance *fins = pop_ref(stack);
                if (!fins) {
                    _null_throw_exception(stack, runtime);
                    return RUNTIME_STATUS_EXCEPTION;
                }
                *((s32 *) (getInstanceFieldPtr(fins, fi))) = v;
                break;
            }
            case 1: {
                s32 v = pop_int(stack);
                Instance *fins = pop_ref(stack);
                if (!fins) {
                    _null_throw_exception(stack, runtime);
                    return RUNTIME_STATUS_EXCEPTION;
                }
                *((s8 *) (getInstanceFieldPtr(fins, fi))) = v;
                break;
            }
            case 8: {
                s64 v = pop_long(stack);
                Instance *fins = pop_ref(stack);
                if (!fins) {
                    _null_throw_exception(stack, runtime);
                    return RUNTIME_STATUS_EXCEPTION;
                }
                *((s64 *) (getInstanceFieldPtr(fins, fi))) = v;
                break;
            }
            case 2: {
                s32 v = pop_int(stack);
                Instance *fins = pop_ref(stack);
                if (!fins) {
                    _null_throw_exception(stack, runtime);
                    return RUNTIME_STATUS_EXCEPTION;
                }
                *((u16 *) (getInstanceFieldPtr(fins, fi))) = v;
                break;
            }
            default: {
                break;
            }
        }
    }
    return RUNTIME_STATUS_NORMAL;
}


s32 execute_method_impl(MethodInfo *method, Runtime *pruntime) {
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
    // Retain game logic inside paint(). For a headless *Canvas* Graphics,
    // certain bundled draw wrappers are already a no-op. Skip only those
    // resolved void calls at the VM boundary, preserving evaluation of args.
    // Existing mode 4 behavior remains; mode 8 uses the guarded raster policy.
    // Offscreen Image graphics, setters/getters, pixel reads, synchronized,
    // native, unfamiliar ABIs and other methods always run normally.
    const int treo_paint_mode = atomic_load_explicit(&treo_afk_mode, memory_order_relaxed);
    if ((treo_paint_mode == 4 ||
         (TREO_VM_PAINT_BRIDGE && treo_paint_mode == 8)) &&
        method->para_slots >= 4 && method->return_slots == 0 &&
        !method->is_static && !method->is_sync && !method->is_native &&
        method->_this_class->status >= CLASS_STATUS_CLINITED &&
        !pruntime->jvm->jdwp_enable && !pruntime->thrd_info->is_stop &&
        !pruntime->thrd_info->suspend_count && treo_headless_eligible(method)) {
        RuntimeStack *caller = pruntime->stack;
        StackEntry *args = caller->sp - method->para_slots;
        if (treo_afk_elide_graphics(method->_this_class, args->ins)) {
            caller->sp = args;
            return RUNTIME_STATUS_NORMAL;
        }
    }

#if TREO_VM_UTF16_FAST
    // For the pure bootstrap predicate only; args were already evaluated.
    // Respect class initialization, thread suspension, and debugger state.
    if (method->para_slots == 1 && method->return_slots == 1 &&
        method->is_static && !method->is_native && !method->is_sync &&
        method->converted_code != NULL && method->breakpoint == NULL &&
        method->_this_class->status >= CLASS_STATUS_CLINITED &&
        !pruntime->jvm->jdwp_enable && !pruntime->thrd_info->is_stop &&
        !pruntime->thrd_info->suspend_count &&
        treo_vm_is_bootstrap_high_surrogate(method)) {
        RuntimeStack *caller = pruntime->stack;
        StackEntry *arg = caller->sp - 1;
        const u16 ch = (u16)arg->ivalue;
        caller->sp = arg;
        push_int(caller, ch >= 0xD800u && ch <= 0xDBFFu);
        treo_vm_utf16_note();
        return RUNTIME_STATUS_NORMAL;
    }
#endif

#if TREO_VM_ARRAY_LOOKUP

#if TREO_VM_ARRAY_LOOKUP_DIAG
    // Track candidate calls even if the fast-path safety preconditions reject
    // the method before the exact bytecode matcher is ever reached.
    if (treo_paint_mode == 8 && method->para_slots == 2 &&
        method->return_slots == 1 && method->is_static)
        treo_array_diag_note(8); // broader arity gate; before code length
    if (treo_paint_mode == 8 && method->para_slots == 2 &&
        method->return_slots == 1 && method->is_static &&
        method->converted_code && method->converted_code->code &&
        method->converted_code->code_length == 17) {
        const u8 *diagnostic_code = method->converted_code->code;
        treo_array_diag_note(0); // plausible 17-byte static (II)->int
        if (diagnostic_code[3] == op_iload_1 &&
            diagnostic_code[7] == op_imul &&
            diagnostic_code[10] == op_iaload) {
            treo_array_diag_note(1); // loose signature (preserves actual bytes)
            treo_array_diag_capture(method, diagnostic_code);
        }
        if (treo_vm_matches_array_lookup(method))
            treo_array_diag_note(2); // complete structural and handler match
    }
#endif
    // Only a fully initialized, resolved, in-bounds int[] read takes the fast
    // path. Null/OOB, uninitialized fields, debugger, suspension and other
    // rare conditions retain the original exception and Java semantics.
    if (treo_paint_mode == 8 && method->para_slots == 2 &&
        method->return_slots == 1 && method->is_static &&
        !method->is_native && !method->is_sync && method->breakpoint == NULL &&
        method->_this_class->status >= CLASS_STATUS_CLINITED &&
        !pruntime->jvm->jdwp_enable && !pruntime->thrd_info->is_stop &&
        !pruntime->thrd_info->suspend_count &&
        treo_vm_matches_array_lookup(method)) {
#if TREO_VM_ARRAY_LOOKUP_DIAG
        treo_array_diag_note(3); // exact candidate plus debugger/thread safety
#endif
        const u8 *code = method->converted_code->code;
        const u16 array_cp = *((const u16 *)(code + 1));
        const u16 width_cp = *((const u16 *)(code + 5));
        ConstantFieldRef *array_ref =
            class_get_constant_fieldref(method->_this_class, array_cp);
        ConstantFieldRef *width_ref =
            class_get_constant_fieldref(method->_this_class, width_cp);
        FieldInfo *array_field = array_ref ? array_ref->fieldInfo : NULL;
        FieldInfo *width_field = width_ref ? width_ref->fieldInfo : NULL;
        if (array_field && width_field) {
#if TREO_VM_ARRAY_LOOKUP_DIAG
            treo_array_diag_note(4);
#endif
        }
        if (array_field && width_field &&
            array_field->_this_class == method->_this_class &&
            width_field->_this_class == method->_this_class &&
            array_field->isrefer && !array_field->isvolatile &&
            !width_field->isrefer && !width_field->isvolatile &&
            width_field->datatype_bytes == 4 &&
            utf8_equals_c(array_field->descriptor, "[I") &&
            utf8_equals_c(width_field->descriptor, "I")) {
#if TREO_VM_ARRAY_LOOKUP_DIAG
            treo_array_diag_note(5);
#endif
            Instance *array = *((__refer *)getStaticFieldPtr(array_field));
            if (array && (array->mb.type & MEM_TYPE_ARR)) {
#if TREO_VM_ARRAY_LOOKUP_DIAG
                treo_array_diag_note(6);
#endif
                const s32 width = *((s32 *)getStaticFieldPtr(width_field));
                RuntimeStack *caller = pruntime->stack;
                StackEntry *args = caller->sp - 2;
                const u32 bits = (u32)args[1].ivalue * (u32)width +
                                 (u32)args[0].ivalue;
                const s32 index = (s32)bits;
                if (index >= 0 && index < array->arr_length) {
#if TREO_VM_ARRAY_LOOKUP_DIAG
                    treo_array_diag_note(7);
#endif
                    const s32 value = ((s32 *)array->arr_body)[index];
                    caller->sp = args;
                    push_int(caller, value);
                    treo_vm_array_lookup_note();
                    return RUNTIME_STATUS_NORMAL;
                }
            }
        }
    }
#endif
#endif

#if TREO_VM_PAINT_SAMPLE
    const int treo_paint_token = treo_vm_paint_method_enter(method);
#endif

    //shared local var for opcode
    Instance *ins;
    s32 idx;
    s32 offset;
    s32 count;
    FieldInfo *fi;
    MethodInfo *m;
    c8 *ptr;
    s32 ival1, ival2;
    f64 dval1, dval2;
    f32 fval1, fval2;
    s64 lval1, lval2;
    __refer rval1, rval2;
    ConstantMethodRef *cmr;
    ConstantFieldRef *cfr;
    JClass *other;
    StackEntry entry;
    Utf8String *ustr;
    ConstantInvokeDynamic *cid;
    BootstrapMethod *bootMethod;

    //local var for control
    MiniJVM *jvm;
    s32 ret;
    c8 const *err_msg;
    Runtime *runtime;
    JavaThreadInfo *thrd_info;
    RuntimeStack *stack;
    LocalVarItem *localvar;
    JClass *clazz;
    //register u8 *runtime->pc;
    register StackEntry *sp;

    //start
    ret = RUNTIME_STATUS_NORMAL;
    runtime = runtime_create_inl(pruntime);

    jvm = runtime->jvm;

    clazz = method->_this_class;
    runtime->clazz = clazz;
    runtime->method = method;
    while (clazz->status < CLASS_STATUS_CLINITING) {
        class_clinit(clazz, runtime);
    }
#if _JVM_DEBUG_LOG_LEVEL > 3
    invoke_deepth(pruntime);
    jvm_printf("%s.%s%s { //\n", utf8_cstr(method->_this_class->name),
               utf8_cstr(method->name), utf8_cstr(method->descriptor));
#endif

//    if (utf8_equals_c(method->name, "<clinit>")
//        && utf8_equals_c(clazz->name, "org/mini/g3d/core/gltf2/loader/GLTFJsonModule")
//            ) {
//        s32 debug = 1;
//    }

    stack = runtime->stack;

    if (!(method->is_native)) {
        CodeAttribute *ca = method->converted_code;
        if (ca) {


            if (stack->max_size < (stack->sp - stack->store) + ca->max_stack) {
                jvm_printf("Stack overflow :\n");
                print_runtime_stack(runtime);
                exit(1);
            }
            runtime->pc = ca->code;

            localvar_init(runtime, ca->max_locals, method->para_slots);

            //method sync begin
            if (method->is_sync)_synchronized_lock_method(method, runtime);

            if (runtime->thrd_info->is_stop) {//if stop=1 then exit thread
                ret = RUNTIME_STATUS_ERROR;
                goto label_exit_while;
            }

#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
            if (method->is_static && method->para_slots == 1 && method->return_slots == 0 &&
                treo_jar_audit_enabled())
                treo_jar_audit_observe(method, clazz);
            if (method->para_slots == 10 && method->return_slots == 0 &&
                !method->is_static && !method->is_sync && !jvm->jdwp_enable &&
                !runtime->thrd_info->suspend_count &&
                treo_direct_graphics_enabled() &&
                treo_is_bundled_draw_region(method, clazz) &&
                treo_try_graphics_draw_region(runtime, clazz)) {
                localvar_dispose(runtime);
                goto treo_graphics_return;
            }
#endif
#ifdef TREO_IOS_GAME_JIT
            const int treo_enabled = !jvm->jdwp_enable && treo_game_jit_is_enabled();
            if (treo_enabled && __atomic_load_n(&ca->jit.state, __ATOMIC_ACQUIRE) == JIT_GEN_SUCCESS) {
                treo_game_jit_record_call();
#else
            if (JIT_ENABLE && ca->jit.state == JIT_GEN_SUCCESS) {
#endif
                //jvm_printf("jit call %s.%s()\n", method->_this_class->name->data, method->name->data);
                ret = ca->jit.func(method, runtime);
                if (!ret) {
                    switch (method->return_slots) {
                        case 0: {// V
                            localvar_dispose(runtime);
                            break;
                        }
                        case 1: { // F I R
                            peek_entry(stack->sp - method->return_slots, &entry);
                            localvar_dispose(runtime);
                            push_entry(stack, &entry);
                            break;
                        }
                        case 2: {//J D return type , 2slots
                            lval1 = pop_long(stack);
                            localvar_dispose(runtime);
                            push_long(stack, lval1);
                            break;
                        }
                        default: {
                            break;
                        }
                    }
                }
            } else {
#ifdef TREO_IOS_GAME_JIT
                if (treo_enabled &&
                    __atomic_load_n(&ca->jit.state, __ATOMIC_ACQUIRE) == JIT_GEN_UNKNOW &&
                    treo_game_jit_can_compile(method)) {
                    const s32 count = __atomic_load_n(&ca->jit.interpreted_count, __ATOMIC_RELAXED);
                    if (count >= JIT_COMPILE_EXEC_COUNT ||
                        __atomic_add_fetch(&ca->jit.interpreted_count, 1, __ATOMIC_RELAXED) >= JIT_COMPILE_EXEC_COUNT) {
                        // The compiler owns a try-lock and rechecks state.
                        // Contending game threads keep interpreting, never spin.
                        construct_jit(method, runtime);
                    }
                }
#else
                if (JIT_ENABLE && ca->jit.state == JIT_GEN_UNKNOW) {
                    if (ca->jit.interpreted_count++ > JIT_COMPILE_EXEC_COUNT) {
                        spin_lock(&ca->compile_lock);
                        if (ca->jit.state == JIT_GEN_UNKNOW) {//re test
                            //jvm_printf("enter jit %s.%s()\n", utf8_cstr(method->_this_class->name), utf8_cstr(method->name));
                            construct_jit(method, runtime);
                        }
                        spin_unlock(&ca->compile_lock);
                    }
                }

#endif
                thrd_info = runtime->thrd_info;
                localvar = runtime->localvar;
                sp = runtime->stack->sp;
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
                const int treo_vm_use_direct = TREO_VM_DIRECT_DISPATCH && !jvm->jdwp_enable;
                treo_vm_note_method(treo_vm_use_direct);
#endif

                do {
                    // Avoid a cross-unit function call on every interpreted
                    // bytecode when this JVM has disabled JDWP at startup.
                    if (jvm->jdwp_enable && jdwp_client_count(jvm->jdwpserver)) {
                        stack->sp = sp;

                        if (!runtime->thrd_info->no_pause) {
                            //breakpoint
                            if (method->breakpoint) {
                                jdwp_check_breakpoint(runtime);
                            }
                            //debug step
                            if (thrd_info->jdwp_step->active) {//单步状态
                                thrd_info->jdwp_step->bytecode_count++;
                                jdwp_check_debug_step(runtime);
                            }
                        }
                        sp = stack->sp;
                        check_gc_pause(-1);  //step debug required
                    }
#if _JVM_DEBUG_LOG_LEVEL > 1
                    if (jvm->collector->isworldstoped && thrd_info->top_runtime != jvm->collector->runtime) {
                        jvm_printf("[ERROR] world stopped, but thread is running: %llx\n", (s64) (intptr_t) runtime->thrd_info->jthread);
                    }
#endif   //_JVM_DEBUG_LOG_LEVEL > 1


#if _JVM_DEBUG_PROFILE
                    u8 cur_inst = *runtime->pc;
                    s64 spent = 0;
                    s64 start_at = nanoTime();
#endif

/* ======================================================opcode start=================================================*/
#ifdef __JVM_DEBUG__
                    s64 inst_pc = runtime->pc - ca->code;
#endif
#if TREO_VM_DIRECT_DISPATCH
                    // Exactly 230 handlers share the original opcode bodies.
                    // Undefined/unsupported byte values take the old error path.
                    static void *const treo_vm_targets[256] = {
                        [op_nop] = &&treo_vm_label_op_nop,
                        [op_aconst_null] = &&treo_vm_label_op_aconst_null,
                        [op_iconst_m1] = &&treo_vm_label_op_iconst_m1,
                        [op_iconst_0] = &&treo_vm_label_op_iconst_0,
                        [op_iconst_1] = &&treo_vm_label_op_iconst_1,
                        [op_iconst_2] = &&treo_vm_label_op_iconst_2,
                        [op_iconst_3] = &&treo_vm_label_op_iconst_3,
                        [op_iconst_4] = &&treo_vm_label_op_iconst_4,
                        [op_iconst_5] = &&treo_vm_label_op_iconst_5,
                        [op_lconst_0] = &&treo_vm_label_op_lconst_0,
                        [op_lconst_1] = &&treo_vm_label_op_lconst_1,
                        [op_fconst_0] = &&treo_vm_label_op_fconst_0,
                        [op_fconst_1] = &&treo_vm_label_op_fconst_1,
                        [op_fconst_2] = &&treo_vm_label_op_fconst_2,
                        [op_dconst_0] = &&treo_vm_label_op_dconst_0,
                        [op_dconst_1] = &&treo_vm_label_op_dconst_1,
                        [op_bipush] = &&treo_vm_label_op_bipush,
                        [op_sipush] = &&treo_vm_label_op_sipush,
                        [op_ldc] = &&treo_vm_label_op_ldc,
                        [op_ldc_w] = &&treo_vm_label_op_ldc_w,
                        [op_ldc2_w] = &&treo_vm_label_op_ldc2_w,
                        [op_iload] = &&treo_vm_label_op_iload,
                        [op_fload] = &&treo_vm_label_op_fload,
                        [op_aload] = &&treo_vm_label_op_aload,
                        [op_lload] = &&treo_vm_label_op_lload,
                        [op_dload] = &&treo_vm_label_op_dload,
                        [op_fload_0] = &&treo_vm_label_op_fload_0,
                        [op_iload_0] = &&treo_vm_label_op_iload_0,
                        [op_fload_1] = &&treo_vm_label_op_fload_1,
                        [op_iload_1] = &&treo_vm_label_op_iload_1,
                        [op_fload_2] = &&treo_vm_label_op_fload_2,
                        [op_iload_2] = &&treo_vm_label_op_iload_2,
                        [op_fload_3] = &&treo_vm_label_op_fload_3,
                        [op_iload_3] = &&treo_vm_label_op_iload_3,
                        [op_dload_0] = &&treo_vm_label_op_dload_0,
                        [op_lload_0] = &&treo_vm_label_op_lload_0,
                        [op_dload_1] = &&treo_vm_label_op_dload_1,
                        [op_lload_1] = &&treo_vm_label_op_lload_1,
                        [op_dload_2] = &&treo_vm_label_op_dload_2,
                        [op_lload_2] = &&treo_vm_label_op_lload_2,
                        [op_dload_3] = &&treo_vm_label_op_dload_3,
                        [op_lload_3] = &&treo_vm_label_op_lload_3,
                        [op_aload_0] = &&treo_vm_label_op_aload_0,
                        [op_aload_1] = &&treo_vm_label_op_aload_1,
                        [op_aload_2] = &&treo_vm_label_op_aload_2,
                        [op_aload_3] = &&treo_vm_label_op_aload_3,
                        [op_iaload] = &&treo_vm_label_op_iaload,
                        [op_faload] = &&treo_vm_label_op_faload,
                        [op_laload] = &&treo_vm_label_op_laload,
                        [op_daload] = &&treo_vm_label_op_daload,
                        [op_aaload] = &&treo_vm_label_op_aaload,
                        [op_baload] = &&treo_vm_label_op_baload,
                        [op_caload] = &&treo_vm_label_op_caload,
                        [op_saload] = &&treo_vm_label_op_saload,
                        [op_istore] = &&treo_vm_label_op_istore,
                        [op_fstore] = &&treo_vm_label_op_fstore,
                        [op_astore] = &&treo_vm_label_op_astore,
                        [op_lstore] = &&treo_vm_label_op_lstore,
                        [op_dstore] = &&treo_vm_label_op_dstore,
                        [op_fstore_0] = &&treo_vm_label_op_fstore_0,
                        [op_istore_0] = &&treo_vm_label_op_istore_0,
                        [op_fstore_1] = &&treo_vm_label_op_fstore_1,
                        [op_istore_1] = &&treo_vm_label_op_istore_1,
                        [op_fstore_2] = &&treo_vm_label_op_fstore_2,
                        [op_istore_2] = &&treo_vm_label_op_istore_2,
                        [op_fstore_3] = &&treo_vm_label_op_fstore_3,
                        [op_istore_3] = &&treo_vm_label_op_istore_3,
                        [op_dstore_0] = &&treo_vm_label_op_dstore_0,
                        [op_lstore_0] = &&treo_vm_label_op_lstore_0,
                        [op_dstore_1] = &&treo_vm_label_op_dstore_1,
                        [op_lstore_1] = &&treo_vm_label_op_lstore_1,
                        [op_dstore_2] = &&treo_vm_label_op_dstore_2,
                        [op_lstore_2] = &&treo_vm_label_op_lstore_2,
                        [op_dstore_3] = &&treo_vm_label_op_dstore_3,
                        [op_lstore_3] = &&treo_vm_label_op_lstore_3,
                        [op_astore_0] = &&treo_vm_label_op_astore_0,
                        [op_astore_1] = &&treo_vm_label_op_astore_1,
                        [op_astore_2] = &&treo_vm_label_op_astore_2,
                        [op_astore_3] = &&treo_vm_label_op_astore_3,
                        [op_fastore] = &&treo_vm_label_op_fastore,
                        [op_iastore] = &&treo_vm_label_op_iastore,
                        [op_dastore] = &&treo_vm_label_op_dastore,
                        [op_lastore] = &&treo_vm_label_op_lastore,
                        [op_aastore] = &&treo_vm_label_op_aastore,
                        [op_bastore] = &&treo_vm_label_op_bastore,
                        [op_castore] = &&treo_vm_label_op_castore,
                        [op_sastore] = &&treo_vm_label_op_sastore,
                        [op_pop] = &&treo_vm_label_op_pop,
                        [op_pop2] = &&treo_vm_label_op_pop2,
                        [op_dup] = &&treo_vm_label_op_dup,
                        [op_dup_x1] = &&treo_vm_label_op_dup_x1,
                        [op_dup_x2] = &&treo_vm_label_op_dup_x2,
                        [op_dup2] = &&treo_vm_label_op_dup2,
                        [op_dup2_x1] = &&treo_vm_label_op_dup2_x1,
                        [op_dup2_x2] = &&treo_vm_label_op_dup2_x2,
                        [op_swap] = &&treo_vm_label_op_swap,
                        [op_iadd] = &&treo_vm_label_op_iadd,
                        [op_ladd] = &&treo_vm_label_op_ladd,
                        [op_fadd] = &&treo_vm_label_op_fadd,
                        [op_dadd] = &&treo_vm_label_op_dadd,
                        [op_isub] = &&treo_vm_label_op_isub,
                        [op_lsub] = &&treo_vm_label_op_lsub,
                        [op_fsub] = &&treo_vm_label_op_fsub,
                        [op_dsub] = &&treo_vm_label_op_dsub,
                        [op_imul] = &&treo_vm_label_op_imul,
                        [op_lmul] = &&treo_vm_label_op_lmul,
                        [op_fmul] = &&treo_vm_label_op_fmul,
                        [op_dmul] = &&treo_vm_label_op_dmul,
                        [op_idiv] = &&treo_vm_label_op_idiv,
                        [op_ldiv] = &&treo_vm_label_op_ldiv,
                        [op_fdiv] = &&treo_vm_label_op_fdiv,
                        [op_ddiv] = &&treo_vm_label_op_ddiv,
                        [op_irem] = &&treo_vm_label_op_irem,
                        [op_lrem] = &&treo_vm_label_op_lrem,
                        [op_frem] = &&treo_vm_label_op_frem,
                        [op_drem] = &&treo_vm_label_op_drem,
                        [op_ineg] = &&treo_vm_label_op_ineg,
                        [op_lneg] = &&treo_vm_label_op_lneg,
                        [op_fneg] = &&treo_vm_label_op_fneg,
                        [op_dneg] = &&treo_vm_label_op_dneg,
                        [op_ishl] = &&treo_vm_label_op_ishl,
                        [op_lshl] = &&treo_vm_label_op_lshl,
                        [op_ishr] = &&treo_vm_label_op_ishr,
                        [op_lshr] = &&treo_vm_label_op_lshr,
                        [op_iushr] = &&treo_vm_label_op_iushr,
                        [op_lushr] = &&treo_vm_label_op_lushr,
                        [op_iand] = &&treo_vm_label_op_iand,
                        [op_land] = &&treo_vm_label_op_land,
                        [op_ior] = &&treo_vm_label_op_ior,
                        [op_lor] = &&treo_vm_label_op_lor,
                        [op_ixor] = &&treo_vm_label_op_ixor,
                        [op_lxor] = &&treo_vm_label_op_lxor,
                        [op_iinc] = &&treo_vm_label_op_iinc,
                        [op_i2l] = &&treo_vm_label_op_i2l,
                        [op_i2f] = &&treo_vm_label_op_i2f,
                        [op_i2d] = &&treo_vm_label_op_i2d,
                        [op_l2i] = &&treo_vm_label_op_l2i,
                        [op_l2f] = &&treo_vm_label_op_l2f,
                        [op_l2d] = &&treo_vm_label_op_l2d,
                        [op_f2i] = &&treo_vm_label_op_f2i,
                        [op_f2l] = &&treo_vm_label_op_f2l,
                        [op_f2d] = &&treo_vm_label_op_f2d,
                        [op_d2i] = &&treo_vm_label_op_d2i,
                        [op_d2l] = &&treo_vm_label_op_d2l,
                        [op_d2f] = &&treo_vm_label_op_d2f,
                        [op_i2b] = &&treo_vm_label_op_i2b,
                        [op_i2c] = &&treo_vm_label_op_i2c,
                        [op_i2s] = &&treo_vm_label_op_i2s,
                        [op_lcmp] = &&treo_vm_label_op_lcmp,
                        [op_fcmpl] = &&treo_vm_label_op_fcmpl,
                        [op_fcmpg] = &&treo_vm_label_op_fcmpg,
                        [op_dcmpl] = &&treo_vm_label_op_dcmpl,
                        [op_dcmpg] = &&treo_vm_label_op_dcmpg,
                        [op_ifeq] = &&treo_vm_label_op_ifeq,
                        [op_ifne] = &&treo_vm_label_op_ifne,
                        [op_iflt] = &&treo_vm_label_op_iflt,
                        [op_ifge] = &&treo_vm_label_op_ifge,
                        [op_ifgt] = &&treo_vm_label_op_ifgt,
                        [op_ifle] = &&treo_vm_label_op_ifle,
                        [op_if_icmpeq] = &&treo_vm_label_op_if_icmpeq,
                        [op_if_icmpne] = &&treo_vm_label_op_if_icmpne,
                        [op_if_icmplt] = &&treo_vm_label_op_if_icmplt,
                        [op_if_icmpge] = &&treo_vm_label_op_if_icmpge,
                        [op_if_icmpgt] = &&treo_vm_label_op_if_icmpgt,
                        [op_if_icmple] = &&treo_vm_label_op_if_icmple,
                        [op_if_acmpeq] = &&treo_vm_label_op_if_acmpeq,
                        [op_if_acmpne] = &&treo_vm_label_op_if_acmpne,
                        [op_goto] = &&treo_vm_label_op_goto,
                        [op_jsr] = &&treo_vm_label_op_jsr,
                        [op_ret] = &&treo_vm_label_op_ret,
                        [op_tableswitch] = &&treo_vm_label_op_tableswitch,
                        [op_lookupswitch] = &&treo_vm_label_op_lookupswitch,
                        [op_lreturn] = &&treo_vm_label_op_lreturn,
                        [op_dreturn] = &&treo_vm_label_op_dreturn,
                        [op_ireturn] = &&treo_vm_label_op_ireturn,
                        [op_freturn] = &&treo_vm_label_op_freturn,
                        [op_areturn] = &&treo_vm_label_op_areturn,
                        [op_return] = &&treo_vm_label_op_return,
                        [op_getstatic] = &&treo_vm_label_op_getstatic,
                        [op_putstatic] = &&treo_vm_label_op_putstatic,
                        [op_getfield] = &&treo_vm_label_op_getfield,
                        [op_putfield] = &&treo_vm_label_op_putfield,
                        [op_invokevirtual] = &&treo_vm_label_op_invokevirtual,
                        [op_invokespecial] = &&treo_vm_label_op_invokespecial,
                        [op_invokestatic] = &&treo_vm_label_op_invokestatic,
                        [op_invokeinterface] = &&treo_vm_label_op_invokeinterface,
                        [op_invokedynamic] = &&treo_vm_label_op_invokedynamic,
                        [op_new] = &&treo_vm_label_op_new,
                        [op_newarray] = &&treo_vm_label_op_newarray,
                        [op_anewarray] = &&treo_vm_label_op_anewarray,
                        [op_arraylength] = &&treo_vm_label_op_arraylength,
                        [op_athrow] = &&treo_vm_label_op_athrow,
                        [op_checkcast] = &&treo_vm_label_op_checkcast,
                        [op_instanceof] = &&treo_vm_label_op_instanceof,
                        [op_monitorenter] = &&treo_vm_label_op_monitorenter,
                        [op_monitorexit] = &&treo_vm_label_op_monitorexit,
                        [op_wide] = &&treo_vm_label_op_wide,
                        [op_multianewarray] = &&treo_vm_label_op_multianewarray,
                        [op_ifnull] = &&treo_vm_label_op_ifnull,
                        [op_ifnonnull] = &&treo_vm_label_op_ifnonnull,
                        [op_goto_w] = &&treo_vm_label_op_goto_w,
                        [op_jsr_w] = &&treo_vm_label_op_jsr_w,
                        [op_breakpoint] = &&treo_vm_label_op_breakpoint,
                        [op_getstatic_ref] = &&treo_vm_label_op_getstatic_ref,
                        [op_getstatic_long] = &&treo_vm_label_op_getstatic_long,
                        [op_getstatic_int] = &&treo_vm_label_op_getstatic_int,
                        [op_getstatic_short] = &&treo_vm_label_op_getstatic_short,
                        [op_getstatic_jchar] = &&treo_vm_label_op_getstatic_jchar,
                        [op_getstatic_byte] = &&treo_vm_label_op_getstatic_byte,
                        [op_putstatic_ref] = &&treo_vm_label_op_putstatic_ref,
                        [op_putstatic_long] = &&treo_vm_label_op_putstatic_long,
                        [op_putstatic_int] = &&treo_vm_label_op_putstatic_int,
                        [op_putstatic_short] = &&treo_vm_label_op_putstatic_short,
                        [op_putstatic_byte] = &&treo_vm_label_op_putstatic_byte,
                        [op_getfield_ref] = &&treo_vm_label_op_getfield_ref,
                        [op_getfield_long] = &&treo_vm_label_op_getfield_long,
                        [op_getfield_int] = &&treo_vm_label_op_getfield_int,
                        [op_getfield_short] = &&treo_vm_label_op_getfield_short,
                        [op_getfield_jchar] = &&treo_vm_label_op_getfield_jchar,
                        [op_getfield_byte] = &&treo_vm_label_op_getfield_byte,
                        [op_putfield_ref] = &&treo_vm_label_op_putfield_ref,
                        [op_putfield_long] = &&treo_vm_label_op_putfield_long,
                        [op_putfield_int] = &&treo_vm_label_op_putfield_int,
                        [op_putfield_short] = &&treo_vm_label_op_putfield_short,
                        [op_putfield_byte] = &&treo_vm_label_op_putfield_byte,
                        [op_invokevirtual_fast] = &&treo_vm_label_op_invokevirtual_fast,
                        [op_invokespecial_fast] = &&treo_vm_label_op_invokespecial_fast,
                        [op_invokestatic_fast] = &&treo_vm_label_op_invokestatic_fast,
                        [op_invokeinterface_fast] = &&treo_vm_label_op_invokeinterface_fast,
                        [op_invokedynamic_fast] = &&treo_vm_label_op_invokedynamic_fast,
                    };
                    if (treo_vm_use_direct) {
                        void *target = treo_vm_targets[(u8)*runtime->pc];
                        if (target) goto *target;
                        goto treo_vm_label_default;
                    }
#endif
                    switch (*runtime->pc) {

                        case op_nop: TREO_VM_HANDLER(op_nop) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("nop\n");
#endif
                            runtime->pc++;

                            break;
                        }

                        case op_aconst_null: TREO_VM_HANDLER(op_aconst_null) {
                            (sp++)->rvalue = NULL;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("aconst_null: push %d into stack\n", 0);
#endif
                            runtime->pc++;

                            break;
                        }

                        case op_iconst_m1: TREO_VM_HANDLER(op_iconst_m1) {
                            (sp++)->ivalue = -1;
                            runtime->pc++;
                            break;
                        }


                        case op_iconst_0: TREO_VM_HANDLER(op_iconst_0) {
                            (sp++)->ivalue = 0;
                            runtime->pc++;
                            break;
                        }


                        case op_iconst_1: TREO_VM_HANDLER(op_iconst_1) {
                            (sp++)->ivalue = 1;
                            runtime->pc++;
                            break;
                        }


                        case op_iconst_2: TREO_VM_HANDLER(op_iconst_2) {
                            (sp++)->ivalue = 2;
                            runtime->pc++;
                            break;
                        }


                        case op_iconst_3: TREO_VM_HANDLER(op_iconst_3) {
                            (sp++)->ivalue = 3;
                            runtime->pc++;
                            break;
                        }


                        case op_iconst_4: TREO_VM_HANDLER(op_iconst_4) {
                            (sp++)->ivalue = 4;
                            runtime->pc++;
                            break;
                        }


                        case op_iconst_5: TREO_VM_HANDLER(op_iconst_5) {
                            (sp++)->ivalue = 5;
                            runtime->pc++;
                            break;
                        }


                        case op_lconst_0: TREO_VM_HANDLER(op_lconst_0) {
                            (sp++)->lvalue = 0;
                            sp++;
                            runtime->pc++;
                            break;
                        }


                        case op_lconst_1: TREO_VM_HANDLER(op_lconst_1) {
                            (sp++)->lvalue = 1;
                            sp++;
                            runtime->pc++;
                            break;
                        }


                        case op_fconst_0: TREO_VM_HANDLER(op_fconst_0) {
                            (sp++)->fvalue = 0;
                            runtime->pc++;
                            break;
                        }


                        case op_fconst_1: TREO_VM_HANDLER(op_fconst_1) {
                            (sp++)->fvalue = 1;
                            runtime->pc++;
                            break;
                        }


                        case op_fconst_2: TREO_VM_HANDLER(op_fconst_2) {
                            (sp++)->fvalue = 2;
                            runtime->pc++;
                            break;
                        }


                        case op_dconst_0: TREO_VM_HANDLER(op_dconst_0) {
                            (sp++)->dvalue = 0;
                            sp++;
                            runtime->pc++;
                            break;
                        }


                        case op_dconst_1: TREO_VM_HANDLER(op_dconst_1) {
                            (sp++)->dvalue = 1;
                            sp++;
                            runtime->pc++;
                            break;
                        }


                        case op_bipush: TREO_VM_HANDLER(op_bipush) {

                            (sp++)->ivalue = (s8) runtime->pc[1];
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("bipush a byte %d onto the stack \n", (sp - 1)->ivalue);
#endif
                            runtime->pc += 2;

                            break;
                        }


                        case op_sipush: TREO_VM_HANDLER(op_sipush) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("sipush value %d\n", *((s16 *) (runtime->pc + 1)));
#endif
                            (sp++)->ivalue = *((s16 *) (runtime->pc + 1));
                            runtime->pc += 3;

                            break;
                        }

                        case op_ldc: TREO_VM_HANDLER(op_ldc)
                        case op_ldc_w: TREO_VM_HANDLER(op_ldc_w) {
                            if (*runtime->pc == op_ldc) {
                                idx = runtime->pc[1];
                                runtime->pc += 2;
                            } else {
                                idx = *((u16 *) (runtime->pc + 1));
                                runtime->pc += 3;
                            }
                            ConstantItem *item = class_get_constant_item(clazz, idx);
                            switch (item->tag) {
                                case CONSTANT_INTEGER:
                                case CONSTANT_FLOAT: {
                                    ival1 = class_get_constant_integer(clazz, idx);
                                    (sp++)->ivalue = ival1;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                    invoke_deepth(runtime);
                                    jvm_printf("ldc: [%x] \n", ival1);
#endif
                                    break;
                                }
                                case CONSTANT_STRING_REF: {
                                    ConstantUTF8 *cutf = class_get_constant_utf8(clazz, class_get_constant_stringref(clazz, idx)->stringIndex);
                                    (sp++)->rvalue = cutf->jstr;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                    invoke_deepth(runtime);
                                    jvm_printf("ldc: [%llx] =\"%s\"\n", (s64) (intptr_t) cutf->jstr, utf8_cstr(cutf->utfstr));
#endif
                                    break;
                                }
                                case CONSTANT_CLASS: {
                                    stack->sp = sp;
                                    other = classes_load_get_with_clinit(clazz->jloader, class_get_constant_classref(clazz, idx)->name, runtime);
                                    if (!other->ins_class) {
                                        other->ins_class = insOfJavaLangClass_create_get(runtime, other);
                                    }
                                    sp = stack->sp;
                                    (sp++)->rvalue = other->ins_class;
                                    break;
                                }
                                default: {
                                    jvm_printf("ldc: something not implemention \n");
                                }
                            }
                            break;
                        }


                        case op_ldc2_w: TREO_VM_HANDLER(op_ldc2_w) {

                            lval1 = class_get_constant_long(clazz, *((u16 *) (runtime->pc + 1)));//long or double
                            (sp++)->lvalue = lval1;
                            sp++;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ldc2_w: push a constant(%d) [%llx] onto the stack \n", *((u16 *) (runtime->pc + 1)), (sp - 2)->lvalue);
#endif
                            runtime->pc += 3;

                            break;
                        }


                        case op_iload: TREO_VM_HANDLER(op_iload)
                        case op_fload: TREO_VM_HANDLER(op_fload) {
                            (sp++)->ivalue = localvar[(u8) runtime->pc[1]].ivalue;
                            runtime->pc += 2;
                            break;
                        }

                        case op_aload: TREO_VM_HANDLER(op_aload) {
                            (sp++)->rvalue = localvar[(u8) runtime->pc[1]].rvalue;
                            runtime->pc += 2;
                            break;
                        }


                        case op_lload: TREO_VM_HANDLER(op_lload)
                        case op_dload: TREO_VM_HANDLER(op_dload) {
                            (sp++)->lvalue = localvar[(u8) runtime->pc[1]].lvalue;
                            sp++;
                            runtime->pc += 2;
                            break;
                        }

                        case op_fload_0: TREO_VM_HANDLER(op_fload_0)
                        case op_iload_0: TREO_VM_HANDLER(op_iload_0) {
                            (sp++)->ivalue = localvar[0].ivalue;
                            runtime->pc++;
                            break;
                        }

                        case op_fload_1: TREO_VM_HANDLER(op_fload_1)
                        case op_iload_1: TREO_VM_HANDLER(op_iload_1) {
                            (sp++)->ivalue = localvar[1].ivalue;
                            runtime->pc++;
                            break;
                        }

                        case op_fload_2: TREO_VM_HANDLER(op_fload_2)
                        case op_iload_2: TREO_VM_HANDLER(op_iload_2) {
                            (sp++)->ivalue = localvar[2].ivalue;
                            runtime->pc++;
                            break;
                        }

                        case op_fload_3: TREO_VM_HANDLER(op_fload_3)
                        case op_iload_3: TREO_VM_HANDLER(op_iload_3) {
                            (sp++)->ivalue = localvar[3].ivalue;
                            runtime->pc++;
                            break;
                        }

                        case op_dload_0: TREO_VM_HANDLER(op_dload_0)
                        case op_lload_0: TREO_VM_HANDLER(op_lload_0) {
                            (sp++)->lvalue = localvar[0].lvalue;
                            (sp++);
                            runtime->pc++;
                            break;
                        }

                        case op_dload_1: TREO_VM_HANDLER(op_dload_1)
                        case op_lload_1: TREO_VM_HANDLER(op_lload_1) {
                            (sp++)->lvalue = localvar[1].lvalue;
                            (sp++);
                            runtime->pc++;
                            break;
                        }

                        case op_dload_2: TREO_VM_HANDLER(op_dload_2)
                        case op_lload_2: TREO_VM_HANDLER(op_lload_2) {
                            (sp++)->lvalue = localvar[2].lvalue;
                            (sp++);
                            runtime->pc++;
                            break;
                        }

                        case op_dload_3: TREO_VM_HANDLER(op_dload_3)
                        case op_lload_3: TREO_VM_HANDLER(op_lload_3) {
                            (sp++)->lvalue = localvar[3].lvalue;
                            (sp++);
                            runtime->pc++;
                            break;
                        }

                        case op_aload_0: TREO_VM_HANDLER(op_aload_0) {
                            (sp++)->rvalue = localvar[0].rvalue;
                            runtime->pc++;
                            break;
                        }


                        case op_aload_1: TREO_VM_HANDLER(op_aload_1) {
                            (sp++)->rvalue = localvar[1].rvalue;
                            runtime->pc++;
                            break;
                        }


                        case op_aload_2: TREO_VM_HANDLER(op_aload_2) {
                            (sp++)->rvalue = localvar[2].rvalue;
                            runtime->pc++;
                            break;
                        }


                        case op_aload_3: TREO_VM_HANDLER(op_aload_3) {
                            (sp++)->rvalue = localvar[3].rvalue;
                            runtime->pc++;
                            break;
                        }


                        case op_iaload: TREO_VM_HANDLER(op_iaload)
                        case op_faload: TREO_VM_HANDLER(op_faload) {
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                ival1 = *((s32 *) (ins->arr_body) + idx);
                                (sp++)->ivalue = ival1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("if_aload push arr[%llx].(%d)=%x:%d:%lf into stack\n", (u64) (intptr_t) ins, idx, ival1, ival1, *(f32 *) &ival1);
#endif
                                runtime->pc++;
                            }
                            break;
                        }


                        case op_laload: TREO_VM_HANDLER(op_laload)
                        case op_daload: TREO_VM_HANDLER(op_daload) {
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                lval1 = *(((s64 *) ins->arr_body) + idx);
                                (sp++)->lvalue = lval1;
                                (sp++);
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("ld_aload push arr[%llx].(%d)=%llx:%lld:%lf into stack\n", (u64) (intptr_t) ins, idx, lval1, lval1, *(f64 *) &lval1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_aaload: TREO_VM_HANDLER(op_aaload) {
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                rval1 = *(((__refer *) ins->arr_body) + idx);
                                (sp++)->rvalue = rval1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("aaload push arr[%llx].(%d)=%llx:%lld into stack\n", (u64) (intptr_t) ins, idx, (s64) (intptr_t) rval1, (s64) (intptr_t) rval1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_baload: TREO_VM_HANDLER(op_baload) {
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                ival1 = *(((s8 *) ins->arr_body) + idx);
                                (sp++)->ivalue = ival1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("iaload push arr[%llx].(%d)=%x:%d:%lf into stack\n", (u64) (intptr_t) ins, idx, ival1, ival1, *(f32 *) &ival1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_caload: TREO_VM_HANDLER(op_caload) {
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                ival1 = *(((u16 *) ins->arr_body) + idx);
                                (sp++)->ivalue = ival1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("iaload push arr[%llx].(%d)=%x:%d:%lf into stack\n", (u64) (intptr_t) ins, idx, ival1, ival1, *(f32 *) &ival1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_saload: TREO_VM_HANDLER(op_saload) {
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                ival1 = *(((s16 *) ins->arr_body) + idx);
                                (sp++)->ivalue = ival1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("iaload push arr[%llx].(%d)=%x:%d:%lf into stack\n", (u64) (intptr_t) ins, idx, ival1, ival1, *(f32 *) &ival1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_istore: TREO_VM_HANDLER(op_istore)
                        case op_fstore: TREO_VM_HANDLER(op_fstore) {
                            localvar[(u8) runtime->pc[1]].ivalue = (--sp)->ivalue;
                            runtime->pc += 2;
                            break;
                        }

                        case op_astore: TREO_VM_HANDLER(op_astore) {
                            localvar[(u8) runtime->pc[1]].rvalue = (--sp)->rvalue;
                            runtime->pc += 2;
                            break;
                        }


                        case op_lstore: TREO_VM_HANDLER(op_lstore)
                        case op_dstore: TREO_VM_HANDLER(op_dstore) {
                            --sp;
                            --sp;
                            localvar[(u8) runtime->pc[1]].lvalue = (sp)->lvalue;
                            runtime->pc += 2;

                            break;
                        }

                        case op_fstore_0: TREO_VM_HANDLER(op_fstore_0)
                        case op_istore_0: TREO_VM_HANDLER(op_istore_0) {
                            localvar[0].ivalue = (--sp)->ivalue;
                            runtime->pc++;
                            break;
                        }

                        case op_fstore_1: TREO_VM_HANDLER(op_fstore_1)
                        case op_istore_1: TREO_VM_HANDLER(op_istore_1) {
                            localvar[1].ivalue = (--sp)->ivalue;
                            runtime->pc++;
                            break;
                        }

                        case op_fstore_2: TREO_VM_HANDLER(op_fstore_2)
                        case op_istore_2: TREO_VM_HANDLER(op_istore_2) {
                            localvar[2].ivalue = (--sp)->ivalue;
                            runtime->pc++;
                            break;
                        }

                        case op_fstore_3: TREO_VM_HANDLER(op_fstore_3)
                        case op_istore_3: TREO_VM_HANDLER(op_istore_3) {
                            localvar[3].ivalue = (--sp)->ivalue;
                            runtime->pc++;
                            break;
                        }

                        case op_dstore_0: TREO_VM_HANDLER(op_dstore_0)
                        case op_lstore_0: TREO_VM_HANDLER(op_lstore_0) {
                            --sp;
                            localvar[0].lvalue = (--sp)->lvalue;
                            runtime->pc++;
                            break;
                        }

                        case op_dstore_1: TREO_VM_HANDLER(op_dstore_1)
                        case op_lstore_1: TREO_VM_HANDLER(op_lstore_1) {
                            --sp;
                            localvar[1].lvalue = (--sp)->lvalue;
                            runtime->pc++;
                            break;
                        }

                        case op_dstore_2: TREO_VM_HANDLER(op_dstore_2)
                        case op_lstore_2: TREO_VM_HANDLER(op_lstore_2) {
                            --sp;
                            localvar[2].lvalue = (--sp)->lvalue;
                            runtime->pc++;
                            break;
                        }

                        case op_dstore_3: TREO_VM_HANDLER(op_dstore_3)
                        case op_lstore_3: TREO_VM_HANDLER(op_lstore_3) {
                            --sp;
                            localvar[3].lvalue = (--sp)->lvalue;
                            runtime->pc++;
                            break;
                        }

                        case op_astore_0: TREO_VM_HANDLER(op_astore_0) {
                            localvar[0].rvalue = (--sp)->rvalue;
                            runtime->pc++;
                            break;
                        }


                        case op_astore_1: TREO_VM_HANDLER(op_astore_1) {
                            localvar[1].rvalue = (--sp)->rvalue;
                            runtime->pc++;
                            break;
                        }


                        case op_astore_2: TREO_VM_HANDLER(op_astore_2) {
                            localvar[2].rvalue = (--sp)->rvalue;
                            runtime->pc++;
                            break;
                        }


                        case op_astore_3: TREO_VM_HANDLER(op_astore_3) {
                            localvar[3].rvalue = (--sp)->rvalue;
                            runtime->pc++;
                            break;
                        }


                        case op_fastore: TREO_VM_HANDLER(op_fastore)
                        case op_iastore: TREO_VM_HANDLER(op_iastore) {
                            ival1 = (--sp)->ivalue;
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                *(((s32 *) ins->arr_body) + idx) = ival1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("iastore: save array[%llx].(%d)=%d)\n", (s64) (intptr_t) ins, idx, ival1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_dastore: TREO_VM_HANDLER(op_dastore)
                        case op_lastore: TREO_VM_HANDLER(op_lastore) {
                            --sp;
                            lval1 = (--sp)->lvalue;
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                *(((s64 *) ins->arr_body) + idx) = lval1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("iastore: save array[%llx].(%d)=%lld)\n", (s64) (intptr_t) ins, idx, lval1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_aastore: TREO_VM_HANDLER(op_aastore) {
                            rval1 = (--sp)->rvalue;
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                *(((__refer *) ins->arr_body) + idx) = rval1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("iastore: save array[%llx].(%d)=%llx)\n", (s64) (intptr_t) ins, idx, (s64) (intptr_t) rval1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_bastore: TREO_VM_HANDLER(op_bastore) {
                            ival1 = (--sp)->ivalue;
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                *(((s8 *) ins->arr_body) + idx) = (s8) ival1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("iastore: save array[%llx].(%d)=%d)\n", (s64) (intptr_t) ins, idx, ival1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_castore: TREO_VM_HANDLER(op_castore) {
                            ival1 = (--sp)->ivalue;
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                *(((u16 *) ins->arr_body) + idx) = (u16) ival1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("iastore: save array[%llx].(%d)=%d)\n", (s64) (intptr_t) ins, idx, ival1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_sastore: TREO_VM_HANDLER(op_sastore) {
                            ival1 = (--sp)->ivalue;
                            idx = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else if (idx < 0 || idx >= ins->arr_length) {
                                goto label_outofbounds_throw;
                            } else {
                                *(((s16 *) ins->arr_body) + idx) = (s16) ival1;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("iastore: save array[%llx].(%d)=%d)\n", (s64) (intptr_t) ins, idx, ival1);
#endif

                                runtime->pc++;
                            }
                            break;
                        }


                        case op_pop: TREO_VM_HANDLER(op_pop) {
                            --sp;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("pop\n");
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_pop2: TREO_VM_HANDLER(op_pop2) {
                            --sp;
                            --sp;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("pop2\n");
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_dup: TREO_VM_HANDLER(op_dup) {
                            *(sp - 0) = *(sp - 1);
                            sp++;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dup\n");
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_dup_x1: TREO_VM_HANDLER(op_dup_x1) {
                            *(sp - 0) = *(sp - 1);
                            *(sp - 1) = *(sp - 2);
                            *(sp - 2) = *(sp - 0);
                            sp++;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dup_x1\n");
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_dup_x2: TREO_VM_HANDLER(op_dup_x2) {
                            *(sp - 0) = *(sp - 1);
                            *(sp - 1) = *(sp - 2);
                            *(sp - 2) = *(sp - 3);
                            *(sp - 3) = *(sp - 0);
                            sp++;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dup_x2 \n");
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_dup2: TREO_VM_HANDLER(op_dup2) {
                            *(sp - 0) = *(sp - 2);
                            *(sp + 1) = *(sp - 1);
                            sp++;
                            sp++;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dup2\n");
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_dup2_x1: TREO_VM_HANDLER(op_dup2_x1) {
                            sp++;
                            sp++;
                            *(sp - 1) = *(sp - 3);
                            *(sp - 2) = *(sp - 4);
                            *(sp - 3) = *(sp - 5);
                            *(sp - 5) = *(sp - 2);
                            *(sp - 4) = *(sp - 1);


#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dup2_x1\n");
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_dup2_x2: TREO_VM_HANDLER(op_dup2_x2) {
                            sp++;
                            sp++;
                            *(sp - 1) = *(sp - 3);
                            *(sp - 2) = *(sp - 4);
                            *(sp - 3) = *(sp - 5);
                            *(sp - 4) = *(sp - 6);
                            *(sp - 6) = *(sp - 2);
                            *(sp - 5) = *(sp - 1);

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dup2_x2\n");
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_swap: TREO_VM_HANDLER(op_swap) {

                            *(sp - 0) = *(sp - 2);
                            *(sp - 2) = *(sp - 1);
                            *(sp - 1) = *(sp - 0);


#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("swap\n");
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_iadd: TREO_VM_HANDLER(op_iadd) {

                            --sp;
                            (sp - 1)->ivalue += (sp - 0)->ivalue;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("iadd:  %d\n", (sp - 1)->ivalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_ladd: TREO_VM_HANDLER(op_ladd) {
                            --sp;
                            --sp;
                            (sp - 2)->lvalue += (sp - 0)->lvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ladd:  %lld\n", (sp - 2)->lvalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_fadd: TREO_VM_HANDLER(op_fadd) {
                            --sp;
                            (sp - 1)->fvalue += (sp - 0)->fvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("fadd:  %f\n", (sp - 1)->fvalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_dadd: TREO_VM_HANDLER(op_dadd) {
                            --sp;
                            --sp;
                            (sp - 2)->dvalue += (sp - 0)->dvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dadd:  %lf\n", (sp - 2)->dvalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_isub: TREO_VM_HANDLER(op_isub) {
                            --sp;
                            (sp - 1)->ivalue -= (sp - 0)->ivalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("isub :  %d\n", (sp - 1)->ivalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_lsub: TREO_VM_HANDLER(op_lsub) {
                            --sp;
                            --sp;
                            (sp - 2)->lvalue -= (sp - 0)->lvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("lsub:  %lld\n", (sp - 2)->lvalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_fsub: TREO_VM_HANDLER(op_fsub) {
                            --sp;
                            (sp - 1)->fvalue -= (sp - 0)->fvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("fsub:  %f\n", (sp - 1)->fvalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_dsub: TREO_VM_HANDLER(op_dsub) {
                            --sp;
                            --sp;
                            (sp - 2)->dvalue -= (sp - 0)->dvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dsub:  %lf\n", (sp - 2)->dvalue);
#endif

                            runtime->pc++;

                            break;
                        }


                        case op_imul: TREO_VM_HANDLER(op_imul) {

                            --sp;
                            (sp - 1)->ivalue *= (sp - 0)->ivalue;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("imul:  %d\n", (sp - 1)->ivalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_lmul: TREO_VM_HANDLER(op_lmul) {
                            --sp;
                            --sp;
                            (sp - 2)->lvalue *= (sp - 0)->lvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("lmul:  %lld\n", (sp - 2)->lvalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_fmul: TREO_VM_HANDLER(op_fmul) {
                            --sp;
                            (sp - 1)->fvalue *= (sp - 0)->fvalue;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("fmul:  %f\n", (sp - 1)->fvalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_dmul: TREO_VM_HANDLER(op_dmul) {
                            --sp;
                            --sp;
                            (sp - 2)->dvalue *= (sp - 0)->dvalue;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dmul:  %lf\n", (sp - 2)->dvalue);
#endif
                            runtime->pc++;

                            break;
                        }


                        case op_idiv: TREO_VM_HANDLER(op_idiv) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("idiv:  %d\n", (sp - 1)->ivalue);
#endif
                            if (!(sp - 1)->ivalue) {
                                goto label_arrithmetic_throw;
                            } else {
                                --sp;
                                (sp - 1)->ivalue /= (sp - 0)->ivalue;
                                runtime->pc++;
                            }

                            break;
                        }


                        case op_ldiv: TREO_VM_HANDLER(op_ldiv) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ldiv:  %lld\n", (sp - 2)->lvalue);
#endif
                            if (!(sp - 2)->lvalue) {
                                goto label_arrithmetic_throw;
                            } else {
                                --sp;
                                --sp;
                                (sp - 2)->lvalue /= (sp - 0)->lvalue;
                                runtime->pc++;
                            }

                            break;
                        }


                        case op_fdiv: TREO_VM_HANDLER(op_fdiv) {
                            // there isn't runtime exception throw
                            // https://github.com/digitalgust/miniJVM/issues/30
                            --sp;
                            (sp - 1)->fvalue /= (sp - 0)->fvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("fdiv:  %f\n", (sp - 1)->fvalue);
#endif
                            runtime->pc++;
                            break;
                        }

                        case op_ddiv: TREO_VM_HANDLER(op_ddiv) {
                            // there isn't runtime exception throw
                            // https://github.com/digitalgust/miniJVM/issues/30
                            --sp;
                            --sp;
                            (sp - 2)->dvalue /= (sp - 0)->dvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ddiv:  %lf\n", (sp - 2)->dvalue);
#endif
                            runtime->pc++;
                            break;
                        }


                        case op_irem: TREO_VM_HANDLER(op_irem) {
                            if (!(sp - 1)->ivalue) {
                                goto label_arrithmetic_throw;
                            } else {
                                --sp;
                                (sp - 1)->ivalue %= (sp - 0)->ivalue;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("irem:  %d\n", (sp - 1)->ivalue);
#endif
                                runtime->pc++;
                            }
                            break;
                        }


                        case op_lrem: TREO_VM_HANDLER(op_lrem) {
                            if (!(sp - 2)->lvalue) {
                                goto label_arrithmetic_throw;
                            } else {
                                --sp;
                                --sp;
                                (sp - 2)->lvalue %= (sp - 0)->lvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("lrem:  %lld\n", (sp - 2)->lvalue);
#endif
                                runtime->pc++;
                            }
                            break;
                        }


                        case op_frem: TREO_VM_HANDLER(op_frem) {
                            // there isn't runtime exception throw
                            // https://github.com/digitalgust/miniJVM/issues/30
                            --sp;
                            fval1 = (sp - 0)->fvalue;
                            fval2 = (sp - 1)->fvalue;
                            f32 v = fval2 - ((s32) (fval2 / fval1) * fval1);
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("frem:  %f\n", (sp - 1)->fvalue);
#endif
                            (sp - 1)->fvalue = v;
                            runtime->pc++;
                            break;
                        }


                        case op_drem: TREO_VM_HANDLER(op_drem) {
                            // there isn't runtime exception throw
                            // https://github.com/digitalgust/miniJVM/issues/30
                            --sp;
                            --sp;
                            dval1 = (sp - 0)->dvalue;
                            dval2 = (sp - 2)->dvalue;
                            f64 v = dval2 - ((s64) (dval2 / dval1) * dval1);;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("drem:  %lf\n", (sp - 2)->dvalue);
#endif
                            (sp - 2)->dvalue = v;
                            runtime->pc++;
                            break;
                        }


                        case op_ineg: TREO_VM_HANDLER(op_ineg) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ineg:  %d\n", (sp - 1)->ivalue);
#endif
                            (sp - 1)->ivalue = -(sp - 1)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_lneg: TREO_VM_HANDLER(op_lneg) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("lneg:  %lld\n", (sp - 2)->lvalue);
#endif
                            (sp - 2)->lvalue = -(sp - 2)->lvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_fneg: TREO_VM_HANDLER(op_fneg) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("fneg:  %f\n", (sp - 1)->fvalue);
#endif
                            (sp - 1)->fvalue = -(sp - 1)->fvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_dneg: TREO_VM_HANDLER(op_dneg) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("dneg:  %lf\n", (sp - 2)->dvalue);
#endif
                            (sp - 2)->dvalue = -(sp - 2)->dvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_ishl: TREO_VM_HANDLER(op_ishl) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ishl: %x << %x  \n", (sp - 2)->ivalue, (sp - 1)->ivalue);
#endif
                            --sp;
                            (sp - 1)->ivalue <<= (sp - 0)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_lshl: TREO_VM_HANDLER(op_lshl) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("lshl: %llx << %x  \n", (sp - 3)->lvalue, (sp - 1)->ivalue);
#endif
                            --sp;
                            (sp - 2)->lvalue <<= (sp - 0)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_ishr: TREO_VM_HANDLER(op_ishr) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ishr: %x >> %x  \n", (sp - 2)->ivalue, (sp - 1)->ivalue);
#endif
                            --sp;
                            (sp - 1)->ivalue >>= (sp - 0)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_lshr: TREO_VM_HANDLER(op_lshr) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("lshr: %llx >> %x  \n", (sp - 3)->lvalue, (sp - 1)->ivalue);
#endif
                            --sp;
                            (sp - 2)->lvalue >>= (sp - 0)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_iushr: TREO_VM_HANDLER(op_iushr) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("iushr: %x >>> %x  \n", (sp - 2)->uivalue, (sp - 1)->ivalue);
#endif
                            --sp;
                            (sp - 1)->uivalue >>= (sp - 0)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_lushr: TREO_VM_HANDLER(op_lushr) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("lushr: %llx >>> %x   \n", (sp - 3)->ulvalue, (sp - 1)->ivalue);
#endif
                            --sp;
                            (sp - 2)->ulvalue >>= (sp - 0)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_iand: TREO_VM_HANDLER(op_iand) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("iand: %x & %x  \n", (sp - 2)->ivalue, (sp - 1)->ivalue);
#endif
                            --sp;
                            (sp - 1)->ivalue &= (sp - 0)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_land: TREO_VM_HANDLER(op_land) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("land: %llx  &  %llx  \n", (sp - 4)->lvalue, (sp - 2)->lvalue);
#endif
                            --sp;
                            --sp;
                            (sp - 2)->lvalue &= (sp - 0)->lvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_ior: TREO_VM_HANDLER(op_ior) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ior: %x & %x  \n", (sp - 2)->ivalue, (sp - 1)->ivalue);
#endif
                            --sp;
                            (sp - 1)->ivalue |= (sp - 0)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_lor: TREO_VM_HANDLER(op_lor) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("lor: %llx  |  %llx   \n", (sp - 4)->lvalue, (sp - 2)->lvalue);
#endif
                            --sp;
                            --sp;
                            (sp - 2)->lvalue |= (sp - 0)->lvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_ixor: TREO_VM_HANDLER(op_ixor) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ixor: %x ^ %x  \n", (sp - 2)->ivalue, (sp - 1)->ivalue);
#endif
                            --sp;
                            (sp - 1)->ivalue ^= (sp - 0)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_lxor: TREO_VM_HANDLER(op_lxor) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("lxor: %llx  ^  %llx  \n", (sp - 4)->lvalue, (sp - 2)->lvalue);
#endif
                            --sp;
                            --sp;
                            (sp - 2)->lvalue ^= (sp - 0)->lvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_iinc: TREO_VM_HANDLER(op_iinc) {
                            localvar[(u8) runtime->pc[1]].ivalue += (s8) runtime->pc[2];
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("iinc: localvar(%d) = %d , inc %d\n", (u8) runtime->pc[1], runtime->localvar[(u8) runtime->pc[1]].ivalue, (s8) runtime->pc[2]);
#endif

                            break;
                        }


                        case op_i2l: TREO_VM_HANDLER(op_i2l) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("i2l:  %d\n", (sp - 1)->ivalue);
#endif
                            ++sp;
                            (sp - 2)->lvalue = (s64) (sp - 2)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_i2f: TREO_VM_HANDLER(op_i2f) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("i2f:  %d\n", (sp - 1)->ivalue);
#endif
                            (sp - 1)->fvalue = (f32) (sp - 1)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_i2d: TREO_VM_HANDLER(op_i2d) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("i2d:  %d\n", (sp - 1)->ivalue);
#endif
                            ++sp;
                            (sp - 2)->dvalue = (f64) (sp - 2)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_l2i: TREO_VM_HANDLER(op_l2i) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("l2i:  %lld\n", (sp - 2)->lvalue);
#endif
                            --sp;
                            (sp - 1)->ivalue = (s32) (sp - 1)->lvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_l2f: TREO_VM_HANDLER(op_l2f) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("l2f:  %lld\n", (sp - 2)->lvalue);
#endif
                            --sp;
                            (sp - 1)->fvalue = (f32) (sp - 1)->lvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_l2d: TREO_VM_HANDLER(op_l2d) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("l2d:  %lld\n", (sp - 2)->lvalue);
#endif
                            (sp - 2)->dvalue = (f64) (sp - 2)->lvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_f2i: TREO_VM_HANDLER(op_f2i) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("f2i: %f\n", (sp - 1)->fvalue);
#endif
                            (sp - 1)->ivalue = (s32) (sp - 1)->fvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_f2l: TREO_VM_HANDLER(op_f2l) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("f2l: %f\n", (sp - 1)->fvalue);
#endif
                            ++sp;
                            (sp - 2)->lvalue = (s64) (sp - 2)->fvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_f2d: TREO_VM_HANDLER(op_f2d) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("f2d: %f\n", (sp - 1)->fvalue);
#endif
                            ++sp;
                            (sp - 2)->dvalue = (f64) (sp - 2)->fvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_d2i: TREO_VM_HANDLER(op_d2i) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("d2i: %lf\n", (sp - 2)->dvalue);
#endif
                            --sp;
                            (sp - 1)->ivalue = (s32) (sp - 1)->dvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_d2l: TREO_VM_HANDLER(op_d2l) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("d2l: %lf\n", (sp - 2)->dvalue);
#endif
                            (sp - 2)->lvalue = (s64) (sp - 2)->dvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_d2f: TREO_VM_HANDLER(op_d2f) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("d2f: %lf\n", (sp - 2)->dvalue);
#endif
                            --sp;
                            (sp - 1)->fvalue = (f32) (sp - 1)->dvalue;
                            runtime->pc++;

                            break;
                        }


                        case op_i2b: TREO_VM_HANDLER(op_i2b) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("i2b:  %d\n", (sp - 1)->ivalue);
#endif
                            (sp - 1)->ivalue = (s8) (sp - 1)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_i2c: TREO_VM_HANDLER(op_i2c) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("i2c:  %d\n", (sp - 1)->ivalue);
#endif
                            (sp - 1)->ivalue = (u16) (sp - 1)->ivalue;
                            runtime->pc++;

                            break;
                        }

                        case op_i2s: TREO_VM_HANDLER(op_i2s) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("i2s:  %d\n", (sp - 1)->ivalue);
#endif
                            (sp - 1)->ivalue = (s16) (sp - 1)->ivalue;
                            runtime->pc++;

                            break;
                        }


                        case op_lcmp: TREO_VM_HANDLER(op_lcmp) {
                            --sp;
                            lval1 = (--sp)->lvalue;
                            --sp;
                            lval2 = (--sp)->lvalue;
                            s32 result = lval2 == lval1 ? 0 : (lval2 > lval1 ? 1 : -1);

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("lcmp: %llx cmp %llx = %d\n", lval2, lval1, result);
#endif
                            (sp++)->ivalue = result;

                            runtime->pc++;

                            break;
                        }


                        case op_fcmpl: TREO_VM_HANDLER(op_fcmpl) {
                            fval1 = (--sp)->fvalue;
                            fval2 = (--sp)->fvalue;
                            if ((sp + 0)->uivalue == 0x7fc00000 || (sp + 1)->uivalue == 0x7fc00000) {
                                (sp++)->ivalue = -1;
                            } else {
                                s32 result = fval2 == fval1 ? 0 : (fval2 > fval1 ? 1 : -1);

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("fcmpl: %f < %f = %d\n", fval2, fval1, result);
#endif
                                (sp++)->ivalue = result;
                            }
                            runtime->pc++;

                            break;
                        }


                        case op_fcmpg: TREO_VM_HANDLER(op_fcmpg) {
                            fval1 = (--sp)->fvalue;
                            fval2 = (--sp)->fvalue;
                            if ((sp + 0)->uivalue == 0x7fc00000 || (sp + 1)->uivalue == 0x7fc00000) {
                                (sp++)->ivalue = 1;
                            } else {
                                s32 result = fval2 == fval1 ? 0 : (fval2 > fval1 ? 1 : -1);

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("fcmpg: %f > %f = %d\n", fval2, fval1, result);
#endif
                                (sp++)->ivalue = result;
                            }
                            runtime->pc++;

                            break;
                        }


                        case op_dcmpl: TREO_VM_HANDLER(op_dcmpl) {
                            --sp;
                            dval1 = (--sp)->dvalue;
                            --sp;
                            dval2 = (--sp)->dvalue;
                            if ((sp + 0)->ulvalue == 0x7ff8000000000000L || (sp + 2)->ulvalue == 0x7ff8000000000000L) {
                                (sp++)->ivalue = -1;
                            } else {
                                s32 result = dval2 == dval1 ? 0 : (dval2 > dval1 ? 1 : -1);

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("dcmpl: %lf < %lf = %d\n", lval2, dval1, result);
#endif
                                (sp++)->ivalue = result;
                            }
                            runtime->pc++;

                            break;
                        }


                        case op_dcmpg: TREO_VM_HANDLER(op_dcmpg) {
                            --sp;
                            dval1 = (--sp)->dvalue;
                            --sp;
                            dval2 = (--sp)->dvalue;
                            if ((sp + 0)->ulvalue == 0x7ff8000000000000L || (sp + 2)->ulvalue == 0x7ff8000000000000L) {
                                (sp++)->ivalue = 1;
                            } else {
                                s32 result = dval2 == dval1 ? 0 : (dval2 > dval1 ? 1 : -1);

#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("dcmpg: %lf > %lf = %d\n", lval2, dval1, result);
#endif
                                (sp++)->ivalue = result;
                            }
                            runtime->pc++;

                            break;
                        }


                        case op_ifeq: TREO_VM_HANDLER(op_ifeq) {
                            ival1 = (--sp)->ivalue;
                            if (ival1 == 0) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ifeq: %d != 0  then jump \n", ival1);
#endif


                            break;
                        }


                        case op_ifne: TREO_VM_HANDLER(op_ifne) {
                            ival1 = (--sp)->ivalue;
                            if (ival1 != 0) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ifne: %d != 0  then jump\n", ival1);
#endif


                            break;
                        }


                        case op_iflt: TREO_VM_HANDLER(op_iflt) {
                            ival1 = (--sp)->ivalue;
                            if (ival1 < 0) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("iflt: %d < 0  then jump  \n", ival1);
#endif


                            break;
                        }


                        case op_ifge: TREO_VM_HANDLER(op_ifge) {
                            ival1 = (--sp)->ivalue;
                            if (ival1 >= 0) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ifge: %d >= 0  then jump \n", ival1);
#endif


                            break;
                        }


                        case op_ifgt: TREO_VM_HANDLER(op_ifgt) {
                            ival1 = (--sp)->ivalue;
                            if (ival1 > 0) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ifgt: %d > 0  then jump \n", ival1);
#endif


                            break;
                        }


                        case op_ifle: TREO_VM_HANDLER(op_ifle) {
                            ival1 = (--sp)->ivalue;
                            if (ival1 <= 0) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ifle: %d <= 0  then jump \n", ival1);
#endif


                            break;
                        }


                        case op_if_icmpeq: TREO_VM_HANDLER(op_if_icmpeq) {
                            ival2 = (--sp)->ivalue;
                            ival1 = (--sp)->ivalue;
                            if (ival1 == ival2) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("if_icmpeq: %lld == %lld \n", (s64) (intptr_t) ival1, (s64) (intptr_t) ival2);
#endif

                            break;
                        }


                        case op_if_icmpne: TREO_VM_HANDLER(op_if_icmpne) {
                            ival2 = (--sp)->ivalue;
                            ival1 = (--sp)->ivalue;
                            if (ival1 != ival2) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("if_icmpne: %lld != %lld \n", (s64) (intptr_t) ival1, (s64) (intptr_t) ival2);
#endif

                            break;
                        }


                        case op_if_icmplt: TREO_VM_HANDLER(op_if_icmplt) {
                            ival2 = (--sp)->ivalue;
                            ival1 = (--sp)->ivalue;
                            if (ival1 < ival2) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("if_icmplt: %lld < %lld \n", (s64) (intptr_t) ival1, (s64) (intptr_t) ival2);
#endif

                            break;
                        }


                        case op_if_icmpge: TREO_VM_HANDLER(op_if_icmpge) {
                            ival2 = (--sp)->ivalue;
                            ival1 = (--sp)->ivalue;
                            if (ival1 >= ival2) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("if_icmpge: %lld >= %lld \n", (s64) (intptr_t) ival1, (s64) (intptr_t) ival2);
#endif

                            break;
                        }


                        case op_if_icmpgt: TREO_VM_HANDLER(op_if_icmpgt) {
                            ival2 = (--sp)->ivalue;
                            ival1 = (--sp)->ivalue;
                            if (ival1 > ival2) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("if_icmpgt: %lld > %lld \n", (s64) (intptr_t) ival1, (s64) (intptr_t) ival2);
#endif

                            break;
                        }


                        case op_if_icmple: TREO_VM_HANDLER(op_if_icmple) {
                            ival2 = (--sp)->ivalue;
                            ival1 = (--sp)->ivalue;
                            if (ival1 <= ival2) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("if_icmple: %lld <= %lld \n", (s64) (intptr_t) ival1, (s64) (intptr_t) ival2);
#endif

                            break;
                        }


                        case op_if_acmpeq: TREO_VM_HANDLER(op_if_acmpeq) {
                            rval2 = (--sp)->rvalue;
                            rval1 = (--sp)->rvalue;
                            if (rval1 == rval2) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("if_acmpeq: %lld == %lld \n", (s64) (intptr_t) rval1, (s64) (intptr_t) rval2);
#endif

                            break;
                        }


                        case op_if_acmpne: TREO_VM_HANDLER(op_if_acmpne) {
                            rval2 = (--sp)->rvalue;
                            rval1 = (--sp)->rvalue;
                            if (rval1 != rval2) {
                                offset = *((s16 *) (runtime->pc + 1));
                                runtime->pc += offset;
                                check_gc_pause(offset);
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("if_acmpne: %lld != %lld \n", (s64) (intptr_t) rval1, (s64) (intptr_t) rval2);
#endif

                            break;
                        }


                        case op_goto: TREO_VM_HANDLER(op_goto) {

                            offset = *((s16 *) (runtime->pc + 1));
                            runtime->pc += offset;
                            check_gc_pause(offset);

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("goto: %d\n", offset);
#endif
                            break;
                        }


                        case op_jsr: TREO_VM_HANDLER(op_jsr) {
                            offset = *((s16 *) (runtime->pc + 1));
                            (sp++)->rvalue = (runtime->pc + 3);
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("jsr: %d\n", offset);
#endif
                            runtime->pc += offset;
                            break;
                        }


                        case op_ret: TREO_VM_HANDLER(op_ret) {
                            __returnaddress addr = (__refer) (intptr_t) localvar[(u8) runtime->pc[1]].rvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ret: %x\n", (s64) (intptr_t) addr);
#endif
                            runtime->pc = (u8 *) addr;
                            break;
                        }


                        case op_tableswitch: TREO_VM_HANDLER(op_tableswitch) {
                            idx = (s32) (4 - ((((u64) (intptr_t) runtime->pc) - (u64) (intptr_t) (ca->code)) % 4));//4 byte对齐

                            s32 default_offset = *((s32 *) (runtime->pc + idx));
                            idx += 4;
                            s32 low = *((s32 *) (runtime->pc + idx));
                            idx += 4;
                            s32 high = *((s32 *) (runtime->pc + idx));
                            idx += 4;

                            ival1 = (--sp)->ivalue;// pop an int from the stack
                            offset = 0;
                            if (ival1 < low || ival1 > high) {  // if its less than <low> or greater than <high>,
                                offset = default_offset;        // branch to default
                            } else {                            // otherwise
                                idx += (ival1 - low) * 4;

                                offset = *((s32 *) (runtime->pc + idx)); // branch to entry in table
                            }

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("tableswitch: val=%d, offset=%d\n", ival1, offset);
#endif
                            runtime->pc += offset;


                            break;
                        }


                        case op_lookupswitch: TREO_VM_HANDLER(op_lookupswitch) {
                            idx = (s32) (4 - ((((u64) (intptr_t) runtime->pc) - (u64) (intptr_t) (ca->code)) % 4));//4 byte对齐

                            s32 default_offset = *((s32 *) (runtime->pc + idx));
                            idx += 4;
                            s32 n = *((s32 *) (runtime->pc + idx));
                            idx += 4;
                            s32 i, key;

                            ival1 = (--sp)->ivalue;// pop an int from the stack
                            offset = default_offset;
                            for (i = 0; i < n; i++) {

                                key = *((s32 *) (runtime->pc + idx));
                                idx += 4;
                                if (key == ival1) {
                                    offset = *((s32 *) (runtime->pc + idx));
                                    break;
                                } else {
                                    idx += 4;
                                }
                            }

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("tableswitch: val=%d, offset=%d\n", ival1, offset);
#endif
                            runtime->pc += offset;

                            break;
                        }


                        case op_lreturn: TREO_VM_HANDLER(op_lreturn)
                        case op_dreturn: TREO_VM_HANDLER(op_dreturn) {
#if _JVM_DEBUG_LOG_LEVEL > 5

                            peek_entry(stack->sp - 1, &entry);
                            invoke_deepth(runtime);
                            jvm_printf("ld_return=%lld/[%llx]\n", entry_2_long(&entry), entry_2_long(&entry));
#endif
                            --sp;
                            lval1 = (--sp)->lvalue;
                            stack->sp = sp;
                            localvar_dispose(runtime);
                            push_long(stack, lval1);
                            goto label_exit_while;
                            break;
                        }


                        case op_ireturn: TREO_VM_HANDLER(op_ireturn)
                        case op_freturn: TREO_VM_HANDLER(op_freturn) {
                            ival1 = (--sp)->ivalue;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("if_return=%d/%f\n", ival1, *(f32 *) &ival1);
#endif
                            stack->sp = sp;
                            localvar_dispose(runtime);
                            push_int(stack, ival1);
                            goto label_exit_while;
                            break;
                        }
                        case op_areturn: TREO_VM_HANDLER(op_areturn) {
                            rval1 = (--sp)->rvalue;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("a_return=[%llx]\n", (s64) (intptr_t) rval1);
#endif
                            stack->sp = sp;
                            localvar_dispose(runtime);
                            push_ref(stack, rval1);
                            goto label_exit_while;
                            break;
                        }


                        case op_return: TREO_VM_HANDLER(op_return) {
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("return: \n");
#endif
                            stack->sp = sp;
                            localvar_dispose(runtime);
                            goto label_exit_while;
                            break;
                        }


                        case op_getstatic: TREO_VM_HANDLER(op_getstatic) {
                            stack->sp = sp;
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            if (!fi) {
                                cfr = class_get_constant_fieldref(clazz, idx);
                                stack->sp = sp;
                                fi = find_fieldInfo_by_fieldref(clazz, cfr->item.index, runtime);
                                sp = stack->sp;
                                cfr->fieldInfo = fi;
                                if (!fi) {
                                    err_msg = utf8_cstr(cfr->name);
                                    goto label_nosuchfield_throw;
                                }
                            }
                            if (fi->_this_class->status < CLASS_STATUS_CLINITED) {
                                stack->sp = sp;
                                class_clinit(fi->_this_class, runtime);
                                sp = stack->sp;
                            }
                            if (fi->isrefer) {
                                *runtime->pc = op_getstatic_ref;
                            } else {
                                // check variable type to determine s64/s32/f64/f32
                                switch (fi->datatype_bytes) {
                                    case 4: {
                                        *runtime->pc = op_getstatic_int;
                                        break;
                                    }
                                    case 1: {
                                        *runtime->pc = op_getstatic_byte;
                                        break;
                                    }
                                    case 8: {
                                        *runtime->pc = op_getstatic_long;
                                        break;
                                    }
                                    case 2: {
                                        if (fi->datatype_idx == DATATYPE_JCHAR) {
                                            *runtime->pc = op_getstatic_jchar;
                                        } else {
                                            *runtime->pc = op_getstatic_short;
                                        }
                                        break;
                                    }
                                    default: {
                                        break;
                                    }
                                }
                            }
                            break;
                        }


                        case op_putstatic: TREO_VM_HANDLER(op_putstatic) {

                            idx = *((u16 *) (runtime->pc + 1));

                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            if (!fi) {
                                cfr = class_get_constant_fieldref(clazz, idx);
                                stack->sp = sp;
                                fi = find_fieldInfo_by_fieldref(clazz, cfr->item.index, runtime);
                                sp = stack->sp;

                                cfr->fieldInfo = fi;
                                if (!fi) {
                                    err_msg = utf8_cstr(cfr->name);
                                    goto label_nosuchfield_throw;
                                }
                            }
                            if (fi->_this_class->status < CLASS_STATUS_CLINITED) {
                                stack->sp = sp;
                                class_clinit(fi->_this_class, runtime);
                                sp = stack->sp;
                            }
                            if (fi->isrefer) {// garbage collection mark
                                *runtime->pc = op_putstatic_ref;
                            } else {
                                // check variable type to determain long/s32/f64/f32
                                // non-reference type
                                switch (fi->datatype_bytes) {
                                    case 4: {
                                        *runtime->pc = op_putstatic_int;
                                        break;
                                    }
                                    case 1: {
                                        *runtime->pc = op_putstatic_byte;
                                        break;
                                    }
                                    case 8: {
                                        *runtime->pc = op_putstatic_long;
                                        break;
                                    }
                                    case 2: {
                                        *runtime->pc = op_putstatic_short;
                                        break;
                                    }
                                    default: {
                                        break;
                                    }
                                }
                            }
                            break;
                        }


                        case op_getfield: TREO_VM_HANDLER(op_getfield) {
                            s8 byte_changed = 0;
                            spin_lock(&jvm->lock_cloader);
                            {
                                if (*(runtime->pc) == op_getfield) {
                                    idx = *((u16 *) (runtime->pc + 1));
                                } else {
                                    byte_changed = 1;
                                }
                            }
                            spin_unlock(&jvm->lock_cloader);

                            if (!byte_changed) {
                                fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                                if (!fi) {
                                    cfr = class_get_constant_fieldref(clazz, idx);
                                    stack->sp = sp;
                                    fi = find_fieldInfo_by_fieldref(clazz, cfr->item.index, runtime);
                                    sp = stack->sp;
                                    cfr->fieldInfo = fi;
                                    if (!fi) {
                                        err_msg = utf8_cstr(cfr->name);
                                        goto label_nosuchfield_throw;
                                    }
                                }
                                if (fi->_this_class->status < CLASS_STATUS_CLINITED) {
                                    stack->sp = sp;
                                    class_clinit(fi->_this_class, runtime);
                                    sp = stack->sp;
                                }
                                spin_lock(&jvm->lock_cloader);
                                {
                                    if (fi->isrefer) {
                                        *runtime->pc = op_getfield_ref;
                                    } else {
                                        // check variable type to determine s64/s32/f64/f32
                                        switch (fi->datatype_bytes) {
                                            case 4: {
                                                *runtime->pc = op_getfield_int;
                                                break;
                                            }
                                            case 1: {
                                                *runtime->pc = op_getfield_byte;
                                                break;
                                            }
                                            case 8: {
                                                *runtime->pc = op_getfield_long;
                                                break;
                                            }
                                            case 2: {
                                                if (fi->datatype_idx == DATATYPE_JCHAR) {
                                                    *runtime->pc = op_getfield_jchar;
                                                } else {
                                                    *runtime->pc = op_getfield_short;
                                                }
                                                break;
                                            }
                                            default: {
                                                break;
                                            }
                                        }
                                    }
                                    *((u16 *) (runtime->pc + 1)) = fi->offset_instance;
                                }
                                spin_unlock(&jvm->lock_cloader);
                            } else {
                                //jvm_printf("getfield byte code changed by other thread.\n");
                            }
                            break;
                        }


                        case op_putfield: TREO_VM_HANDLER(op_putfield) {
                            //there were a multithread error , one enter the ins but changed by another
                            s8 byte_changed = 0;

                            spin_lock(&jvm->lock_cloader);
                            {
                                if (*(runtime->pc) == op_putfield) {
                                    idx = *((u16 *) (runtime->pc + 1));
                                } else {
                                    byte_changed = 1;
                                }
                            }
                            spin_unlock(&jvm->lock_cloader);

                            if (!byte_changed) {
                                fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                                if (!fi) {
                                    cfr = class_get_constant_fieldref(clazz, idx);

                                    stack->sp = sp;
                                    fi = find_fieldInfo_by_fieldref(clazz, cfr->item.index, runtime);
                                    sp = stack->sp;
                                    cfr->fieldInfo = fi;
                                    if (!fi) {
                                        err_msg = utf8_cstr(cfr->name);
                                        goto label_nosuchfield_throw;
                                    }
                                }
                                if (fi->_this_class->status < CLASS_STATUS_CLINITED) {
                                    stack->sp = sp;
                                    class_clinit(fi->_this_class, runtime);
                                    sp = stack->sp;
                                }
                                spin_lock(&jvm->lock_cloader);
                                {
                                    if (fi->isrefer) {// garbage collection flag
                                        *runtime->pc = op_putfield_ref;
                                    } else {
                                        // non-reference type
                                        switch (fi->datatype_bytes) {
                                            case 4: {
                                                *runtime->pc = op_putfield_int;
                                                break;
                                            }
                                            case 1: {
                                                *runtime->pc = op_putfield_byte;
                                                break;
                                            }
                                            case 8: {
                                                *runtime->pc = op_putfield_long;
                                                break;
                                            }
                                            case 2: {
                                                *runtime->pc = op_putfield_short;
                                                break;
                                            }
                                            default: {
                                                break;
                                            }
                                        }
                                    }
                                    *((u16 *) (runtime->pc + 1)) = fi->offset_instance;
                                }
                                spin_unlock(&jvm->lock_cloader);
                            } else {
                                //jvm_printf("putfield byte code changed by other thread.\n");
                            }
                            break;
                        }


                        case op_invokevirtual: TREO_VM_HANDLER(op_invokevirtual) {

                            cmr = class_get_constant_method_ref(clazz, *((u16 *) (runtime->pc + 1)));

                            ins = (sp - 1 - cmr->para_slots)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                m = (MethodInfo *) pairlist_get(cmr->virtual_methods, ins->mb.clazz);
                                if (!m) {
                                    stack->sp = sp;
                                    m = find_instance_methodInfo_by_name(ins, cmr->name, cmr->descriptor, runtime);
                                    sp = stack->sp;
                                    spin_lock(&jvm->lock_cloader);
                                    {
                                        pairlist_put(cmr->virtual_methods, ins->mb.clazz, m);//放入缓存，以便下次直接调用
                                    }
                                    spin_unlock(&jvm->lock_cloader);
                                }

                                if (!m) {
                                    err_msg = utf8_cstr(cmr->name);
                                    goto label_nosuchmethod_throw;
                                } else {
                                    s8 match = 0;
                                    if (m->is_getter) {//optimize getter eg:  int getSize(){return size;}
                                        ptr = (c8 *) m->converted_code->bytecode_for_jit;//must use original bytecode
                                        match = 1;
                                        //do getter here
                                        idx = *((u16 *) (ptr + 2));//field desc index
                                        other = m->_this_class;
                                        stack->sp = sp;
                                        ret = _optimize_inline_getter(other, idx, runtime);
                                        sp = stack->sp;
                                        if (ret) {
                                            goto label_exception_handle;
                                        }
                                        //jvm_printf("methodcall getter %s.%s  %d  in    %s.%s\n", utf8_cstr(m->_this_class->name), utf8_cstr(m->name), m->_this_class->status, utf8_cstr(clazz->name), utf8_cstr(method->name));
                                        runtime->pc += 3;
                                    } else if (m->is_setter) {//optimize setter eg: void setSize(int size){this.size=size;}
                                        ptr = (c8 *) m->converted_code->bytecode_for_jit;//must use original bytecode
                                        match = 1;
                                        //do setter here
                                        idx = *((u16 *) (ptr + 3));//field desc index
                                        other = m->_this_class;
                                        stack->sp = sp;
                                        ret = _optimize_inline_setter(other, idx, runtime);
                                        sp = stack->sp;
                                        if (ret) {
                                            goto label_exception_handle;
                                        }
                                        //jvm_printf("methodcall setter %s.%s  %d  in    %s.%s\n", utf8_cstr(m->_this_class->name), utf8_cstr(m->name), m->_this_class->status, utf8_cstr(clazz->name), utf8_cstr(method->name));
                                        runtime->pc += 3;
                                    }
                                    if (!match) {
                                        *runtime->pc = op_invokevirtual_fast;
                                    }
                                }
                            }

                            break;
                        }


                        case op_invokespecial: TREO_VM_HANDLER(op_invokespecial) {
                            cmr = class_get_constant_method_ref(clazz, *((u16 *) (runtime->pc + 1)));
                            m = cmr->methodInfo;

                            if (!m) {
                                err_msg = utf8_cstr(cmr->name);
                                goto label_nosuchmethod_throw;
                            } else {
                                *runtime->pc = op_invokespecial_fast;
                                _optimize_empty_method_call(m, ca, runtime->pc);//if method is empty ,bytecode would replaced 'nop' and 'pop' para
                            }
                            break;
                        }


                        case op_invokestatic: TREO_VM_HANDLER(op_invokestatic) {
                            cmr = class_get_constant_method_ref(clazz, *((u16 *) (runtime->pc + 1)));
                            m = cmr->methodInfo;

                            if (!m) {
                                err_msg = utf8_cstr(cmr->name);
                                goto label_nosuchmethod_throw;
                            } else {
                                *runtime->pc = op_invokestatic_fast;
                                _optimize_empty_method_call(m, ca, runtime->pc);
                            }
                            break;
                        }


                        case op_invokeinterface: TREO_VM_HANDLER(op_invokeinterface) {

                            //s32 paraCount = (u8) runtime->pc[3];
                            cmr = class_get_constant_method_ref(clazz, *((u16 *) (runtime->pc + 1)));
                            ins = (sp - 1 - cmr->para_slots)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                m = (MethodInfo *) pairlist_get(cmr->virtual_methods, ins->mb.clazz);
                                if (!m) {
                                    stack->sp = sp;
                                    m = find_instance_methodInfo_by_name(ins, cmr->name, cmr->descriptor, runtime);
                                    sp = stack->sp;
                                    spin_lock(&jvm->lock_cloader);
                                    {
                                        pairlist_put(cmr->virtual_methods, ins->mb.clazz, m);// store in cache for direct use in the next call
                                    }
                                    spin_unlock(&jvm->lock_cloader);
                                }
                                if (!m) {
                                    err_msg = utf8_cstr(cmr->name);
                                    goto label_nosuchmethod_throw;
                                } else {
                                    *runtime->pc = op_invokeinterface_fast;
                                }
                            }
                            break;
                        }


                        case op_invokedynamic: TREO_VM_HANDLER(op_invokedynamic) {
                            //get bootMethod struct
                            cid = class_get_invoke_dynamic(clazz, *((u16 *) (runtime->pc + 1)));
                            bootMethod = &clazz->bootstrapMethodAttr->bootstrap_methods[cid->bootstrap_method_attr_index];//Boot

                            if (bootMethod->make == NULL) {
                                stack->sp = sp;
                                ret = invokedynamic_prepare(runtime, bootMethod, cid);
                                sp = stack->sp;
                                if (ret) {
                                    goto label_exception_handle;
                                }
                            }
                            m = bootMethod->make;

                            if (!m) {
                                err_msg = "Lambda generated method";
                                goto label_nosuchmethod_throw;
                            } else {
                                *runtime->pc = op_invokedynamic_fast;
                            }
                            break;
                        }


                        case op_new: TREO_VM_HANDLER(op_new) {
                            idx = *((u16 *) (runtime->pc + 1));

                            stack->sp = sp;
                            other = getClassByConstantClassRef(clazz, idx, runtime);
                            ins = NULL;
                            if (other) {
                                ins = instance_create(runtime, other);
                            }
                            sp = stack->sp;

                            (sp++)->rvalue = ins;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("new %s [%llx]\n", utf8_cstr(other->name), (s64) (intptr_t) ins);
#endif
                            runtime->pc += 3;
                            break;
                        }


                        case op_newarray: TREO_VM_HANDLER(op_newarray) {
                            idx = runtime->pc[1];

                            count = (--sp)->ivalue;

                            stack->sp = sp;
                            ins = jarray_create_by_type_index(runtime, count, idx);
                            sp = stack->sp;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("(a)newarray  [%llx] type:%c , count:%d  \n", (s64) (intptr_t) ins, getDataTypeTag(idx), count);
#endif
                            (sp++)->rvalue = ins;
                            runtime->pc += 2;
                            break;
                        }


                        case op_anewarray: TREO_VM_HANDLER(op_anewarray) {
                            idx = *((u16 *) (runtime->pc + 1));

                            count = (--sp)->ivalue;
                            other = pairlist_get(clazz->arr_class_type, (__refer) (intptr_t) idx);

                            stack->sp = sp;
                            if (!other) {//cache to speed
                                other = array_class_get_by_name(runtime, runtime->clazz->jloader, class_get_utf8_string(clazz, idx));
                                spin_lock(&jvm->lock_cloader);
                                {
                                    pairlist_put(clazz->arr_class_type, (__refer) (intptr_t) idx, other);
                                }
                                spin_unlock(&jvm->lock_cloader);
                            }
                            ins = jarray_create_by_class(runtime, count, other);
                            sp = stack->sp;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("(a)newarray  [%llx] type:%d , count:%d  \n", (s64) (intptr_t) ins, other->arr_class_type, count);
#endif
                            (sp++)->rvalue = ins;
                            runtime->pc += 3;
                            break;
                        }


                        case op_arraylength: TREO_VM_HANDLER(op_arraylength) {
                            ins = (--sp)->rvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("arraylength  [%llx].arr_body[%llx] len:%d  \n", (s64) (intptr_t) ins, (s64) (intptr_t) ins->arr_body, ins->arr_length);
#endif
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                (sp++)->ivalue = ins->arr_length;
                                runtime->pc++;
                            }
                            break;
                        }


                        case op_athrow: TREO_VM_HANDLER(op_athrow) {

#if _JVM_DEBUG_LOG_LEVEL > 5
                            ins = (Instance *) pop_ref(stack);
                            push_ref(stack, (__refer) ins);
                            invoke_deepth(runtime);
                            jvm_printf("athrow  [%llx].exception throws  \n", (s64) (intptr_t) ins);
#endif
                            stack->sp = sp;
                            goto label_exception_handle;
                            break;
                        }


                        case op_checkcast: TREO_VM_HANDLER(op_checkcast) {
                            idx = *((u16 *) (runtime->pc + 1));

                            ins = (--sp)->rvalue;

                            stack->sp = sp;
                            if (!checkcast(runtime, ins, idx)) {
                                goto label_checkcast_throw;
                            } else {
                                sp = stack->sp;
                                (sp++)->rvalue = ins;
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("checkcast  %s instancof %s  \n", utf8_cstr(ins->mb.clazz->name), utf8_cstr(class_get_constant_classref(clazz, idx)->name));
#endif

                            break;
                        }


                        case op_instanceof: TREO_VM_HANDLER(op_instanceof) {
                            ins = (--sp)->rvalue;
                            idx = *((u16 *) (runtime->pc + 1));

                            s8 checkok = 0;
                            if (!ins) {
                            } else if (ins->mb.type & (MEM_TYPE_INS | MEM_TYPE_ARR)) {
                                stack->sp = sp;
                                if (instance_of(ins, getClassByConstantClassRef(clazz, idx, runtime))) {
                                    checkok = 1;
                                }
                                sp = stack->sp;
                            }
                            (sp++)->ivalue = checkok;

#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("instanceof  [%llx] instancof %s  \n", (s64) (intptr_t) ins, utf8_cstr(class_get_constant_classref(clazz, idx)->name));
#endif
                            runtime->pc += 3;
                            break;
                        }


                        case op_monitorenter: TREO_VM_HANDLER(op_monitorenter) {
                            ins = (--sp)->rvalue;
                            stack->sp = sp;
                            if (!ins)goto label_null_throw;
                            jthread_lock(&ins->mb, runtime);
                            sp = stack->sp;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("monitorenter  [%llx] %s  \n", (s64) (intptr_t) ins, ins ? utf8_cstr(ins->mb.clazz->name) : "null");
#endif
                            runtime->pc++;
                            break;
                        }


                        case op_monitorexit: TREO_VM_HANDLER(op_monitorexit) {
                            ins = (--sp)->rvalue;
                            stack->sp = sp;
                            if (!ins)goto label_null_throw;
                            int ret = jthread_unlock(&ins->mb, runtime);
                            if (ret < 0) {
                                s32 debug = 1;
                            }
                            sp = stack->sp;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("monitorexit  [%llx] %s  \n", (s64) (intptr_t) ins, ins ? utf8_cstr(ins->mb.clazz->name) : "null");
#endif
                            runtime->pc++;
                            break;
                        }


                        case op_wide: TREO_VM_HANDLER(op_wide) {
#if _JVM_DEBUG_LOG_LEVEL > 5

                            invoke_deepth(runtime);
                            jvm_printf("wide  \n");
#endif
                            runtime->pc++;
                            switch (*runtime->pc) {
                                case op_iload:
                                case op_fload: {
                                    (sp++)->ivalue = localvar[*((u16 *) (runtime->pc + 1))].ivalue;
                                    runtime->pc += 3;
                                    break;
                                }
                                case op_aload: {
                                    (sp++)->rvalue = localvar[*((u16 *) (runtime->pc + 1))].rvalue;
                                    runtime->pc += 3;
                                    break;
                                }
                                case op_lload:
                                case op_dload: {
                                    (sp++)->lvalue = localvar[*((u16 *) (runtime->pc + 1))].lvalue;
                                    sp++;
                                    runtime->pc += 3;
                                    break;
                                }
                                case op_istore:
                                case op_fstore: {
                                    localvar[*((u16 *) (runtime->pc + 1))].ivalue = (--sp)->ivalue;
                                    runtime->pc += 3;
                                    break;
                                }
                                case op_astore: {
                                    localvar[*((u16 *) (runtime->pc + 1))].rvalue = (--sp)->rvalue;
                                    runtime->pc += 3;
                                    break;
                                }
                                case op_lstore:
                                case op_dstore: {
                                    --sp;
                                    localvar[*((u16 *) (runtime->pc + 1))].lvalue = (--sp)->lvalue;
                                    runtime->pc += 3;
                                    break;
                                }
                                case op_ret: {
                                    __refer addr = (__refer) (intptr_t) localvar[*((u16 *) (runtime->pc + 1))].lvalue;

#if _JVM_DEBUG_LOG_LEVEL > 5
                                    invoke_deepth(runtime);
                                    jvm_printf("wide ret: %x\n", (s64) (intptr_t) addr);
#endif
                                    runtime->pc = (u8 *) addr;
                                    break;
                                }
                                case op_iinc    : {

                                    localvar[*((u16 *) (runtime->pc + 1))].ivalue += *((s16 *) (runtime->pc + 3));
#if _JVM_DEBUG_LOG_LEVEL > 5
                                    invoke_deepth(runtime);
                                    jvm_printf("wide iinc: localvar(%d) = %d , inc %d\n", *((u16 *) (runtime->pc + 1)), runtime->localvar[*((u16 *) (runtime->pc + 1))].ivalue, *((u16 *) (runtime->pc + 3)));
#endif
                                    runtime->pc += 5;
                                    break;
                                }
                                default:
                                    _op_notsupport(runtime->pc, runtime);
                            }
                            break;
                        }


                        case op_multianewarray: TREO_VM_HANDLER(op_multianewarray) {
                            //data type index

                            ustr = class_get_utf8_string(clazz, *((u16 *) (runtime->pc + 1)));
                            //array dim
                            count = (u8) runtime->pc[3];
#ifdef __JVM_OS_VS__
                            s32 dim[32];
#else
                            s32 dim[count];
#endif
                            for (idx = 0; idx < count; idx++)
                                dim[idx] = (--sp)->ivalue;

                            stack->sp = sp;
                            ins = jarray_multi_create(runtime, dim, count, ustr, 0);
                            sp = stack->sp;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("multianewarray  [%llx] type:%s , count:%d  \n", (s64) (intptr_t) ins, utf8_cstr(ustr), count);
#endif
                            (sp++)->rvalue = ins;
                            runtime->pc += 4;
                            break;
                        }


                        case op_ifnull: TREO_VM_HANDLER(op_ifnull) {
                            ins = (--sp)->rvalue;
                            if (!ins) {

                                runtime->pc += *((s16 *) (runtime->pc + 1));
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ifnonnull: %d/%llx != 0  then jump %d \n", (s32) (intptr_t) ins, (s64) (intptr_t) ins);
#endif


                            break;
                        }


                        case op_ifnonnull: TREO_VM_HANDLER(op_ifnonnull) {
                            ins = (--sp)->rvalue;
                            if (ins) {
                                runtime->pc += *((s16 *) (runtime->pc + 1));
                            } else {
                                runtime->pc += 3;
                            }
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("ifnonnull: %d/%llx != 0  then \n", (s32) (intptr_t) ins, (s64) (intptr_t) ins);
#endif
                            break;
                        }


                        case op_goto_w: TREO_VM_HANDLER(op_goto_w) {
                            offset = *((s32 *) (runtime->pc + 1));
                            runtime->pc += offset;
                            check_gc_pause(offset);
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("goto: %d\n", offset);
#endif
                            break;
                        }


                        case op_jsr_w: TREO_VM_HANDLER(op_jsr_w) {

                            offset = *((s32 *) (runtime->pc + 1));
                            (sp++)->rvalue = (runtime->pc + 3);
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("jsr_w: %d\n", offset);
#endif
                            runtime->pc += offset;
                            break;
                        }


                        case op_breakpoint: TREO_VM_HANDLER(op_breakpoint) {
#if _JVM_DEBUG_LOG_LEVEL > 5

                            invoke_deepth(runtime);
                            jvm_printf("breakpoint \n");
#endif
                            break;
                        }


                        case op_getstatic_ref: TREO_VM_HANDLER(op_getstatic_ref) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);

                            (sp++)->rvalue = *((__refer *) ptr);
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: ref  %d = %s.%s \n", "getstatic", (s64) (intptr_t) getFieldRefer(ptr), utf8_cstr(clazz->name), utf8_cstr(fi->name), getFieldLong(ptr));
#endif
                            break;
                        }

                        case op_getstatic_long: TREO_VM_HANDLER(op_getstatic_long) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            (sp++)->lvalue = *((s64 *) ptr);
                            sp++;
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: long  %d = %s.%s \n", "getstatic", getFieldLong(ptr), utf8_cstr(clazz->name), utf8_cstr(fi->name), getFieldLong(ptr));
#endif
                            break;
                        }

                        case op_getstatic_int: TREO_VM_HANDLER(op_getstatic_int) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            (sp++)->ivalue = *((s32 *) ptr);
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: int  %d = %s.%s \n", "getstatic", (s32) getFieldInt(ptr), utf8_cstr(clazz->name), utf8_cstr(fi->name), getFieldLong(ptr));
#endif
                            break;
                        }

                        case op_getstatic_short: TREO_VM_HANDLER(op_getstatic_short) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            (sp++)->ivalue = *((s16 *) ptr);
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: short  %d = %s.%s \n", "getstatic", (s32) getFieldShort(ptr), utf8_cstr(clazz->name), utf8_cstr(fi->name), getFieldLong(ptr));
#endif
                            break;
                        }

                        case op_getstatic_jchar: TREO_VM_HANDLER(op_getstatic_jchar) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            (sp++)->ivalue = *((u16 *) ptr);
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: char  %d = %s.%s \n", "getstatic", (s32) (u16) getFieldChar(ptr), utf8_cstr(clazz->name), utf8_cstr(fi->name), getFieldLong(ptr));
#endif
                            break;
                        }

                        case op_getstatic_byte: TREO_VM_HANDLER(op_getstatic_byte) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            (sp++)->ivalue = *((s8 *) ptr);
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: byte  %d = %s.%s \n", "getstatic", (s32) getFieldByte(ptr), utf8_cstr(clazz->name), utf8_cstr(fi->name), getFieldLong(ptr));
#endif
                            break;
                        }


                        case op_putstatic_ref: TREO_VM_HANDLER(op_putstatic_ref) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            *((__refer *) ptr) = (--sp)->rvalue;
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: ref  %s.%s = %llx \n", "putstatic", utf8_cstr(clazz->name), utf8_cstr(fi->name), (s64) (intptr_t) getFieldRefer(ptr));
#endif
                            break;
                        }


                        case op_putstatic_long: TREO_VM_HANDLER(op_putstatic_long) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            --sp;
                            *((s64 *) ptr) = (--sp)->lvalue;
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: long  %s.%s = %lld \n", "putstatic", utf8_cstr(clazz->name), utf8_cstr(fi->name), getFieldLong(ptr));
#endif
                            break;
                        }

                        case op_putstatic_int: TREO_VM_HANDLER(op_putstatic_int) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            *((s32 *) ptr) = (--sp)->ivalue;
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: int  %s.%s = %d \n", "putstatic", utf8_cstr(clazz->name), utf8_cstr(fi->name), (s32) getFieldInt(ptr));
#endif
                            break;
                        }

                        case op_putstatic_short: TREO_VM_HANDLER(op_putstatic_short) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            *((s16 *) ptr) = (s16) (--sp)->ivalue;
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: short  %s.%s = %d \n", "putstatic", utf8_cstr(clazz->name), utf8_cstr(fi->name), (s32) getFieldShort(ptr));
#endif
                            break;
                        }

                        case op_putstatic_byte: TREO_VM_HANDLER(op_putstatic_byte) {
                            idx = *((u16 *) (runtime->pc + 1));
                            fi = class_get_constant_fieldref(clazz, idx)->fieldInfo;
                            ptr = getStaticFieldPtr(fi);
                            *((s8 *) ptr) = (s8) (--sp)->ivalue;
                            runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                            invoke_deepth(runtime);
                            jvm_printf("%s: byte  %s.%s = %d \n", "putstatic", utf8_cstr(clazz->name), utf8_cstr(fi->name), (s32) getFieldByte(ptr));
#endif
                            break;
                        }


                        case op_getfield_ref: TREO_VM_HANDLER(op_getfield_ref) {
                            offset = *((u16 *) (runtime->pc + 1));
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);

                                (sp++)->rvalue = *((__refer *) ptr);
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: ref %llx = %s. \n", "getfield", getFieldRefer(ptr), utf8_cstr(clazz->name));
#endif
                            }
                            break;
                        }


                        case op_getfield_long: TREO_VM_HANDLER(op_getfield_long) {
                            offset = *((u16 *) (runtime->pc + 1));
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);

                                (sp++)->lvalue = *((s64 *) ptr);
                                sp++;
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: long %lld = %s. \n", "getfield", getFieldLong(ptr), utf8_cstr(ins->mb.clazz->name));
#endif
                            }
                            break;
                        }


                        case op_getfield_int: TREO_VM_HANDLER(op_getfield_int) {
                            offset = *((u16 *) (runtime->pc + 1));
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);

                                (sp++)->ivalue = *((s32 *) ptr);
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: int %d = %s  \n", "getfield", (s32) getFieldInt(ptr), utf8_cstr(clazz->name));
#endif
                            }
                            break;
                        }


                        case op_getfield_short: TREO_VM_HANDLER(op_getfield_short) {
                            offset = *((u16 *) (runtime->pc + 1));
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);

                                (sp++)->ivalue = *((s16 *) ptr);
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: short %d = %s \n", "getfield", (s32) getFieldShort(ptr), utf8_cstr(clazz->name));
#endif
                            }
                            break;
                        }


                        case op_getfield_jchar: TREO_VM_HANDLER(op_getfield_jchar) {
                            offset = *((u16 *) (runtime->pc + 1));
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);

                                (sp++)->ivalue = *((u16 *) ptr);
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: char %d = %s \n", "getfield", (s32) (u16) getFieldChar(ptr), utf8_cstr(clazz->name));
#endif
                            }
                            break;
                        }


                        case op_getfield_byte: TREO_VM_HANDLER(op_getfield_byte) {
                            offset = *((u16 *) (runtime->pc + 1));
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);

                                (sp++)->ivalue = *((s8 *) ptr);
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: byte %d = %s \n", "getfield", (s32) getFieldByte(ptr), utf8_cstr(clazz->name));
#endif
                            }
                            break;
                        }


                        case op_putfield_ref: TREO_VM_HANDLER(op_putfield_ref) {
                            offset = *((u16 *) (runtime->pc + 1));
                            rval1 = (--sp)->rvalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                // check variable type to determain long/s32/f64/f32
                                ptr = &(ins->obj_fields[offset]);
                                *((__refer *) ptr) = rval1;
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: ref %s\n", "putfield", utf8_cstr(clazz->name));
#endif
                            }
                            break;
                        }


                        case op_putfield_long: TREO_VM_HANDLER(op_putfield_long) {
                            offset = *((u16 *) (runtime->pc + 1));
                            --sp;
                            lval1 = (--sp)->lvalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);
                                *((s64 *) ptr) = lval1;
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: long %s\n", "putfield", utf8_cstr(clazz->name));
#endif
                            }
                            break;
                        }


                        case op_putfield_int: TREO_VM_HANDLER(op_putfield_int) {
                            offset = *((u16 *) (runtime->pc + 1));
                            ival1 = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);
                                *((s32 *) ptr) = ival1;
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: int %s.= %d\n", "putfield", utf8_cstr(clazz->name), ival1);
#endif
                            }
                            break;
                        }


                        case op_putfield_short: TREO_VM_HANDLER(op_putfield_short) {
                            offset = *((u16 *) (runtime->pc + 1));
                            ival1 = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);
                                *((s16 *) ptr) = (s16) ival1;
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: short %s. = %d\n", "putfield", utf8_cstr(clazz->name), ival1);
#endif
                            }
                            break;
                        }


                        case op_putfield_byte: TREO_VM_HANDLER(op_putfield_byte) {
                            offset = *((u16 *) (runtime->pc + 1));
                            ival1 = (--sp)->ivalue;
                            ins = (--sp)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                ptr = &(ins->obj_fields[offset]);
                                *((s8 *) ptr) = (s8) ival1;
                                runtime->pc += 3;
#if _JVM_DEBUG_LOG_LEVEL > 5
                                invoke_deepth(runtime);
                                jvm_printf("%s: byte %s. = %d\n", "putfield", utf8_cstr(clazz->name), ival1);
#endif
                            }
                            break;
                        }


                        case op_invokevirtual_fast: TREO_VM_HANDLER(op_invokevirtual_fast) {

                            cmr = class_get_constant_method_ref(clazz, *((u16 *) (runtime->pc + 1)));
                            ins = (sp - 1 - cmr->para_slots)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                m = (MethodInfo *) pairlist_get(cmr->virtual_methods, ins->mb.clazz);
#if _JVM_DEBUG_PROFILE
                                spent = nanoTime() - start_at;
#endif
                                if (!m) {
                                    *runtime->pc = op_invokevirtual;
                                } else {
                                    stack->sp = sp;
                                    ret = execute_method_impl(m, runtime);
                                    sp = stack->sp;
                                    if (ret) {
                                        goto label_exception_handle;
                                    }
                                    runtime->pc += 3;
                                }
                            }

                            break;
                        }


                        case op_invokespecial_fast: TREO_VM_HANDLER(op_invokespecial_fast) {
                            cmr = class_get_constant_method_ref(clazz, *((u16 *) (runtime->pc + 1)));
                            m = cmr->methodInfo;
#if _JVM_DEBUG_PROFILE
                            spent = nanoTime() - start_at;
#endif
                            stack->sp = sp;
                            ret = execute_method_impl(m, runtime);
                            sp = stack->sp;
                            if (ret) {
                                goto label_exception_handle;
                            }
                            runtime->pc += 3;
                            break;
                        }


                        case op_invokestatic_fast: TREO_VM_HANDLER(op_invokestatic_fast) {
                            cmr = class_get_constant_method_ref(clazz, *((u16 *) (runtime->pc + 1)));
                            m = cmr->methodInfo;
#if _JVM_DEBUG_PROFILE
                            spent = nanoTime() - start_at;
#endif
                            stack->sp = sp;
                            ret = execute_method_impl(m, runtime);
                            sp = stack->sp;
                            if (ret) {
                                goto label_exception_handle;
                            }
                            runtime->pc += 3;
                            break;
                        }


                        case op_invokeinterface_fast: TREO_VM_HANDLER(op_invokeinterface_fast) {
                            //此cmr所描述的方法，对于不同的实例，有不同的method
                            cmr = class_get_constant_method_ref(clazz, *((u16 *) (runtime->pc + 1)));

                            ins = (sp - 1 - cmr->para_slots)->rvalue;
                            if (!ins) {
                                goto label_null_throw;
                            } else {
                                m = (MethodInfo *) pairlist_get(cmr->virtual_methods, ins->mb.clazz);
#if _JVM_DEBUG_PROFILE
                                spent = nanoTime() - start_at;
#endif
                                if (!m) {
                                    *runtime->pc = op_invokeinterface;
                                } else {
                                    stack->sp = sp;
                                    ret = execute_method_impl(m, runtime);
                                    sp = stack->sp;
                                    if (ret) {
                                        goto label_exception_handle;
                                    }
                                    runtime->pc += 5;
                                }
                            }
                            break;
                        }


                        case op_invokedynamic_fast: TREO_VM_HANDLER(op_invokedynamic_fast) {
                            //get bootMethod struct
                            cid = class_get_invoke_dynamic(clazz, *((u16 *) (runtime->pc + 1)));
                            bootMethod = &clazz->bootstrapMethodAttr->bootstrap_methods[cid->bootstrap_method_attr_index];//Boot
                            m = bootMethod->make;

#if _JVM_DEBUG_PROFILE
                            spent = nanoTime() - start_at;
#endif
                            // run make to generate instance of Lambda Class
                            stack->sp = sp;
                            ret = execute_method_impl(m, runtime);
                            sp = stack->sp;
                            if (ret) {
                                goto label_exception_handle;
                            }

                            runtime->pc += 5;
                            break;
                        }

                        default: TREO_VM_HANDLER(default)
                            _op_notsupport(runtime->pc, runtime);
                    }

                    /* ================================== runtime->pc end =============================*/

#if _JVM_DEBUG_PROFILE
                    //time
                    if (!spent) spent = nanoTime() - start_at;
                    profile_put(cur_inst, spent, 1);
#endif
                    continue;
                    label_outofbounds_throw:
                    {
                        stack->sp = sp;
                        push_ref(stack, (__refer) exception_create(JVM_EXCEPTION_ARRAYINDEXOUTOFBOUNDS, runtime));
                        goto label_exception_handle;
                    }

                    label_null_throw:
                    {
                        stack->sp = sp;
                        push_ref(stack, (__refer) exception_create(JVM_EXCEPTION_NULLPOINTER, runtime));
                        goto label_exception_handle;
                    }

                    label_nosuchmethod_throw:
                    {
                        stack->sp = sp;
                        push_ref(stack, (__refer) exception_create_str(JVM_EXCEPTION_NOSUCHMETHOD, runtime, err_msg));
                        goto label_exception_handle;
                    }

                    label_nosuchfield_throw:
                    {
                        stack->sp = sp;
                        push_ref(stack, (__refer) exception_create_str(JVM_EXCEPTION_NOSUCHFIELD, runtime, err_msg));
                        goto label_exception_handle;
                    }

                    label_arrithmetic_throw:
                    {
                        stack->sp = sp;
                        push_ref(stack, (__refer) exception_create(JVM_EXCEPTION_ARRITHMETIC, runtime));
                        goto label_exception_handle;
                    }

                    label_checkcast_throw:
                    {
                        stack->sp = sp;
                        push_ref(stack, (__refer) exception_create(JVM_EXCEPTION_CLASSCAST, runtime));
                        goto label_exception_handle;
                    }

                    label_exception_handle:
                    if (ret == RUNTIME_STATUS_ERROR) {
                        goto label_exit_while;
                    }
                    // there is exception handle, but not error handle

                    ret = RUNTIME_STATUS_EXCEPTION;
                    if (exception_handle(runtime->stack, runtime)) {
                        ret = RUNTIME_STATUS_NORMAL;

                        runtime_clear_stacktrack(runtime);
                    } else {
                        arraylist_push_back(runtime->thrd_info->stacktrack, method);
                        arraylist_push_back(runtime->thrd_info->lineNo, (__refer) (intptr_t) getLineNumByIndex(ca, (s32) (runtime->pc - ca->code)));
                        break;
                    }
                    sp = stack->sp;
#if _JVM_DEBUG_PROFILE
                    //time
                    if (!spent) spent = nanoTime() - start_at;
                    profile_put(cur_inst, spent, 1);
#endif
                    continue;

                    label_exit_while:
#if _JVM_DEBUG_PROFILE
                    //time
                    if (!spent) spent = nanoTime() - start_at;
                    profile_put(cur_inst, spent, 1);
#endif
                    break;

                } while (1);//end while
            }

#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
            treo_graphics_return: ;
#endif
            //sync end
            if (method->is_sync)_synchronized_unlock_method(method, runtime);

        } else {
            jvm_printf("method code attribute is null.");
        }
    } else {// native method
        localvar_init(runtime, method->para_slots, method->para_slots);
        // cache native method calls
        if (!method->native_func) { // find and cache the native method
            java_native_method *native = find_native_method(jvm, utf8_cstr(clazz->name), utf8_cstr(method->name), utf8_cstr(method->descriptor));
            if (!native) {
                _nosuchmethod_check_exception(utf8_cstr(method->name), stack, runtime);
                ret = RUNTIME_STATUS_EXCEPTION;
            } else {
                method->native_func = native->func_pointer;
            }
        }

        if (runtime->thrd_info->is_stop) {//if stop=1 then exit thread
            ret = RUNTIME_STATUS_ERROR;
        } else if (method->native_func) {
            if (method->is_sync)_synchronized_lock_method(method, runtime);
            ret = method->native_func(runtime, clazz);
            if (method->is_sync)_synchronized_unlock_method(method, runtime);
            if (ret) {
                ins = pop_ref(stack);
                localvar_dispose(runtime);
                push_ref(stack, ins);
            } else {
                switch (method->return_slots) {
                    case 0: {// V
                        localvar_dispose(runtime);
                        break;
                    }
                    case 1: { // F I R
                        peek_entry(stack->sp - method->return_slots, &entry);
                        localvar_dispose(runtime);
                        push_entry(stack, &entry);
                        break;
                    }
                    case 2: {//J D return type , 2slots
                        lval1 = pop_long(stack);
                        localvar_dispose(runtime);
                        push_long(stack, lval1);
                        break;
                    }
                    default: {
                        break;
                    }
                }
            }
        }
    }


#if _JVM_DEBUG_LOG_LEVEL > 3
    if (ret != RUNTIME_STATUS_EXCEPTION) {
        if (stack->sp != runtime->localvar + method->return_slots) {
            invoke_deepth(runtime);
            jvm_printf("Thread.stop = %d | Stack size  %s.%s%s in:%d out:%d  \n", runtime->thrd_info->is_stop, utf8_cstr(clazz->name), utf8_cstr(method->name), utf8_cstr(method->descriptor), (runtime->localvar - runtime->stack->store), stack_size(stack));
            if (!runtime->thrd_info->is_stop)exit(1);//if is_stop , the stack will confuse
        }
    }
#endif
    runtime_destroy_inl(runtime);
    pruntime->son = NULL;  //must clear , required for getLastSon()

#if _JVM_DEBUG_LOG_LEVEL > 3
    invoke_deepth(pruntime);
    jvm_printf("} // %s.%s%s\n", utf8_cstr(method->_this_class->name),
               utf8_cstr(method->name), utf8_cstr(method->descriptor));
#endif

#if TREO_VM_PAINT_SAMPLE
    treo_vm_paint_method_exit(method, treo_paint_token);
#endif
    return ret;
}

