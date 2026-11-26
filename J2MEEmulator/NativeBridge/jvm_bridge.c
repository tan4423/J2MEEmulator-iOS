#include "jvm_bridge.h"
#include "jarbox_focus_policy.h"
#include "jarbox_session_registry.h"
#include "jarbox_2d_policy.h"
#include "jvm.h"
#include "jvm_util.h"
#include "jarbox_net_lifecycle.h"
#include "garbage.h"
#include "j2me_render.h"
#include "j2me_input.h"
#include "j2me_ui.h"
#include "j2me_audio.h"
#include "j2me_micro3d_gl.h"
#include "m3g/j2me_m3g.h"
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sys/stat.h>
#include <strings.h>
#include "miniz.h"
#include "jarbox_flight_gzip.h"
#include <stdlib.h>
#include "miniz_wrapper.h"
#if defined(__APPLE__) && __JVM_OS_IOS__
#include <os/proc.h>
#if defined(TREO_NINJA_CORE_EXPERIMENT) && TREO_NINJA_CORE_EXPERIMENT
#include <CommonCrypto/CommonDigest.h>
#endif
#include <time.h>
#include <mach/mach.h>
#include <sys/resource.h>
#endif

// Called only on the export queue, never from a game worker.
uint8_t *jvm_bridge_flight_gzip(const uint8_t *input,size_t input_size,size_t *output_size) {
    if (!output_size) return NULL;
    *output_size=0;
    if (!input || !input_size || input_size>2U*1024U*1024U) return NULL;
    size_t raw_size=0;
    void *raw=tdefl_compress_mem_to_heap(input,input_size,&raw_size,
        (int)tdefl_create_comp_flags_from_zip_params(6,-15,MZ_DEFAULT_STRATEGY));
    if (!raw) return NULL;
    if (raw_size>SIZE_MAX-18) {mz_free(raw);return NULL;}
    uint8_t *out=malloc(raw_size+18);
    if (out) {
        jarbox_flight_gzip_frame(out,raw,raw_size,(uint32_t)mz_crc32(0,input,input_size),(uint32_t)input_size);
        *output_size=raw_size+18;
    }
    mz_free(raw);
    return out;
}
void jvm_bridge_flight_gzip_free(uint8_t *bytes) {free(bytes);}
void jvm_bridge_trim_classpath_cache(void) {
    zip_classpath_cache_trim();
    jarbox_prepared_code_cache_trim();
}

// Conservative launch classification, not an authorization to execute 3D.
// Bound the scan; unreadable, oversized, nested or unknown archives run alone.
static int bridge_jar_requires_exclusive(const char *path) {
    struct stat st;
    if (!path || stat(path, &st) != 0 || st.st_size <= 0 ||
        st.st_size > 64 * 1024 * 1024) return 1;
    mz_zip_archive zip = {0};
    if (!mz_zip_reader_init_file(&zip, path, MZ_ZIP_FLAG_DO_NOT_SORT_CENTRAL_DIRECTORY)) return 1;
    int exclusive = 1;
    unsigned classes = 0;
    size_t total = 0;
    const mz_uint count = mz_zip_reader_get_num_files(&zip);
    if (!count || count > 20000) goto done;
    for (mz_uint i = 0; i < count; ++i) {
        mz_zip_archive_file_stat f;
        if (!mz_zip_reader_file_stat(&zip, i, &f)) goto done;
        if (mz_zip_reader_is_file_a_directory(&zip, i)) continue;
        const mz_uint name_size = mz_zip_reader_get_filename(&zip, i, NULL, 0);
        if (!name_size || name_size > sizeof(f.m_filename)) goto done;
        const size_t len = strlen(f.m_filename);
        if (name_size != len + 1) goto done;
        if (len >= 4 && (!strcasecmp(f.m_filename + len - 4, ".jar") ||
                         !strcasecmp(f.m_filename + len - 4, ".zip"))) goto done;
        if (len < 6 || strcmp(f.m_filename + len - 6, ".class")) continue;
        if (f.m_is_encrypted || f.m_uncomp_size < 4 ||
            f.m_uncomp_size > 2 * 1024 * 1024 ||
            f.m_uncomp_size > 32 * 1024 * 1024 - total) goto done;
        size_t size = 0;
        unsigned char *bytes = mz_zip_reader_extract_to_heap(&zip, i, &size, 0);
        const int suspect = !bytes || size != f.m_uncomp_size || size < 4 ||
            memcmp(bytes, "\xca\xfe\xba\xbe", 4) != 0 ||
            jarbox_class_mentions_3d((const unsigned char *)f.m_filename, len) ||
            jarbox_class_mentions_3d(bytes, size);
        if (bytes) mz_free(bytes);
        if (suspect) goto done;
        total += size;
        ++classes;
    }
    exclusive = classes == 0;
done:
    mz_zip_reader_end(&zip);
    return exclusive;
}

// Share only a successful conservative 2D classification. No session,
// bytecode, renderer or Java objects are retained. A miss, change or
// unavailable identity goes through the original fail-closed scanner.
#define JARBOX_2D_CLASS_CACHE_SLOTS 16
#define JARBOX_2D_CLASS_CACHE_PATH 1024
typedef struct {
    char path[JARBOX_2D_CLASS_CACHE_PATH];
    struct stat identity;
} JarBox2DClassification;
static JarBox2DClassification bridge_2d_class_cache[JARBOX_2D_CLASS_CACHE_SLOTS];
static unsigned bridge_2d_class_next;
static pthread_mutex_t bridge_2d_class_lock = PTHREAD_MUTEX_INITIALIZER;

static int bridge_2d_identity_equal(const struct stat *a, const struct stat *b) {
    if (a->st_dev != b->st_dev || a->st_ino != b->st_ino ||
        a->st_size != b->st_size || a->st_mtime != b->st_mtime ||
        a->st_ctime != b->st_ctime) return 0;
#if defined(__APPLE__)
    return a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
           a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
#else
    return a->st_mtim.tv_nsec == b->st_mtim.tv_nsec &&
           a->st_ctim.tv_nsec == b->st_ctim.tv_nsec;
#endif
}

static int bridge_jar_requires_exclusive_cached(const char *path) {
    struct stat before, after;
    if (!path || stat(path, &before) != 0 || !S_ISREG(before.st_mode)) return 1;
    if (strlen(path) >= JARBOX_2D_CLASS_CACHE_PATH)
        return bridge_jar_requires_exclusive(path);
    int hit = 0;
    pthread_mutex_lock(&bridge_2d_class_lock);
    for (unsigned i = 0; i < JARBOX_2D_CLASS_CACHE_SLOTS; ++i) {
        JarBox2DClassification *entry = &bridge_2d_class_cache[i];
        if (entry->path[0] && strcmp(entry->path, path) == 0) {
            hit = bridge_2d_identity_equal(&entry->identity, &before);
            if (!hit) entry->path[0] = 0;
            break;
        }
    }
    pthread_mutex_unlock(&bridge_2d_class_lock);
    if (hit) {
        // Re-check identity outside the lock; do not trust a stale safe result.
        return stat(path, &after) != 0 || !bridge_2d_identity_equal(&before, &after);
    }

    // Do not hold a global lock while decompressing classes.
    int exclusive = bridge_jar_requires_exclusive(path);
    if (exclusive || stat(path, &after) != 0 ||
        !bridge_2d_identity_equal(&before, &after)) return 1;

    pthread_mutex_lock(&bridge_2d_class_lock);
    unsigned slot = JARBOX_2D_CLASS_CACHE_SLOTS;
    for (unsigned i = 0; i < JARBOX_2D_CLASS_CACHE_SLOTS; ++i) {
        if (strcmp(bridge_2d_class_cache[i].path, path) == 0) { slot = i; break; }
        if (slot == JARBOX_2D_CLASS_CACHE_SLOTS && !bridge_2d_class_cache[i].path[0]) slot = i;
    }
    if (slot == JARBOX_2D_CLASS_CACHE_SLOTS)
        slot = bridge_2d_class_next++ % JARBOX_2D_CLASS_CACHE_SLOTS;
    JarBox2DClassification *entry = &bridge_2d_class_cache[slot];
    memcpy(entry->path, path, strlen(path) + 1);
    entry->identity = before;
    pthread_mutex_unlock(&bridge_2d_class_lock);
    return 0;
}

static atomic_int treo_exact_ninja_verified;
// Per-JAR launch diagnostic gate (NOT a Deep Treo optimization flag).
// Check exact Java class paths once in the archive; avoid name probing on
// 10,000s of VM calls/sec for other JARs, including original NSO.
_Atomic int treo_nso_init_target_active;
int treo_ninja_deep_verified(void) {
    return atomic_load_explicit(&treo_exact_ninja_verified, memory_order_acquire);
}
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_NINJA_DEEP_DISABLED)
/*
 * NSO-family identification is based on stable game resource layout, not
 * exact JAR hashes or obfuscated class names. The separate runtime Canvas
 * bytecode-shape guard prevents a similar asset bundle with different paint
 * behavior from blindly inheriting this optimization.
 *
 * One archive read at MIDlet load; no ZIP or disk work in the Treo hot loop.
 */
#if defined(TREO_NINJA_CORE_EXPERIMENT) && TREO_NINJA_CORE_EXPERIMENT
// Launch-only exact archive gate. Bounded streaming hash; no file I/O in paint.
static unsigned treo_ninja_core_archive_profile(const char *path) {
    if (!path) return 0;
    FILE *f=fopen(path,"rb");
    if (!f) return 0;
    CC_SHA256_CTX ctx;
    unsigned char buf[16384],digest[CC_SHA256_DIGEST_LENGTH];
    size_t total=0,n;
    int ok=CC_SHA256_Init(&ctx)==1;
    while (ok && (n=fread(buf,1,sizeof(buf),f))!=0) {
        total+=n;
        if (total>16U*1024U*1024U) { ok=0; break; }
        ok=CC_SHA256_Update(&ctx,buf,(CC_LONG)n)==1;
    }
    ok=ok && !ferror(f) && feof(f) && total && CC_SHA256_Final(digest,&ctx)==1;
    fclose(f);
    return ok ? jarbox_ninja_core_profile(digest) : 0;
}
#endif
static int treo_is_nso_family(const char *jar_path, int *init_target) {
    *init_target = 0;
    static const char *const resources[] = {
        "font/number",
        "font/tahoma_7",
        "map/1",
        "map/newmap",
        "x1/bg/bg00.png",
        "x1/export/0",
        "x1/e/d00.png"
    };
    if (!jar_path) return 0;
    mz_zip_archive archive = {0};
    if (!mz_zip_reader_init_file(&archive, jar_path, MZ_ZIP_FLAG_DO_NOT_SORT_CENTRAL_DIRECTORY)) return 0;
    // A mod may add/remove a few resources. Five of seven independent
    // signature assets plus map and sprite categories is sufficient.
    // The loaded Canvas bytecode shape is verified separately before skipping.
    unsigned matched = 0;
    int has_map = 0, has_sprite = 0;
    for (unsigned i = 0; i < sizeof(resources) / sizeof(resources[0]); ++i) {
        int index = mz_zip_reader_locate_file(
            &archive, resources[i], NULL, MZ_ZIP_FLAG_CASE_SENSITIVE);
        mz_zip_archive_file_stat file_stat;
        if (index >= 0 &&
            mz_zip_reader_file_stat(&archive, index, &file_stat) &&
            file_stat.m_uncomp_size != 0 &&
            !mz_zip_reader_is_file_a_directory(&archive, index)) {
            matched++;
            if (i == 2 || i == 3) has_map = 1;
            if (i >= 4) has_sprite = 1;
        }
    }
    const int family = matched >= 5 && has_map && has_sprite;
    if (family) {
        const char *const target_classes[] = {
            "GameMidlet.class", "Class_cu.class", "Class_ek.class"
        };
        int found = 0;
        for (unsigned i = 0; i < sizeof(target_classes) / sizeof(target_classes[0]); ++i)
            found += mz_zip_reader_locate_file(&archive, target_classes[i], NULL,
                                              MZ_ZIP_FLAG_CASE_SENSITIVE) >= 0;
        *init_target = found == 3;
    }
    mz_zip_reader_end(&archive);
    return family;
}

#endif


// Native executor storage is now a real slot pool, distinct from the
// session registry (which owns lifetime pins). Allocation/retirement and
// worker admission are serialized by g_bridge_lifecycle_lock. Capacity of
// storage is a technical ceiling; fresh memory headroom gates admission.
enum { BRIDGE_IDLE = 0, BRIDGE_STARTING = 1, BRIDGE_RUNNING = 2,
       BRIDGE_CLEANUP = 3 };
typedef struct {
    _Atomic(MiniJVM *) jvm;
    atomic_int stop_requested;
    atomic_int active;
    atomic_int phase;
    _Atomic uint64_t token;
    int worker_busy; // lifecycle lock; prevents release/reuse during an API call
    int legacy_3d_registered; // launch-worker owned; immutable until retirement
    int exclusive_3d; // lifecycle lock; held through STOPPING and cleanup
    uint64_t native_heap_key; // launch-worker owned, reserved before bootstrap
} JarBoxVMContext;
static JarBoxVMContext g_bridge_slots[JARBOX_REGISTRY_MAX_SLOTS];

// All *_locked helpers require the lifecycle lock, including host tests.
static JarBoxVMContext *bridge_find_slot_locked(uint64_t token) {
    if (!token) return NULL;
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxVMContext *slot = &g_bridge_slots[i];
        if (atomic_load_explicit(&slot->active, memory_order_acquire) &&
            atomic_load_explicit(&slot->token, memory_order_acquire) == token)
            return slot;
    }
    return NULL;
}
static JarBoxVMContext *bridge_reserve_slot_locked(uint64_t token, unsigned limit) {
    if (!token || !limit || limit > JARBOX_REGISTRY_MAX_SLOTS ||
        bridge_find_slot_locked(token)) return NULL;
    unsigned used = 0;
    JarBoxVMContext *empty = NULL;
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxVMContext *slot = &g_bridge_slots[i];
        if (atomic_load_explicit(&slot->active, memory_order_acquire)) ++used;
        else if (!empty) empty = slot;
    }
    if (used >= limit || !empty) return NULL;
    atomic_store_explicit(&empty->jvm, NULL, memory_order_release);
    atomic_store_explicit(&empty->stop_requested, 0, memory_order_release);
    atomic_store_explicit(&empty->phase, BRIDGE_STARTING, memory_order_release);
    atomic_store_explicit(&empty->token, token, memory_order_release);
    empty->worker_busy = 0;
    empty->legacy_3d_registered = 0;
    empty->native_heap_key = 0;
    empty->exclusive_3d = 1; // legacy admission defaults to exclusive
    atomic_store_explicit(&empty->active, 1, memory_order_release);
    return empty;
}
static int bridge_slot_can_retire_locked(const JarBoxVMContext *slot) {
    return slot && !slot->worker_busy &&
        !atomic_load_explicit(&slot->jvm, memory_order_acquire);
}
static void bridge_reset_slot_locked(JarBoxVMContext *slot) {
    slot->legacy_3d_registered = 0;
    slot->exclusive_3d = 0;
    slot->native_heap_key = 0;
    atomic_store_explicit(&slot->phase, BRIDGE_IDLE, memory_order_release);
    atomic_store_explicit(&slot->stop_requested, 0, memory_order_release);
    atomic_store_explicit(&slot->token, 0, memory_order_release);
    atomic_store_explicit(&slot->active, 0, memory_order_release);
}
static JarBoxVMContext *bridge_claim_worker_locked(uint64_t token) {
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    if (!slot || slot->worker_busy) return NULL;
    slot->worker_busy = 1;
    return slot;
}
static void bridge_release_worker_locked(JarBoxVMContext *slot) {
    slot->worker_busy = 0;
}

// Tokens are never reused, even when this context is reset and acquired again.
static _Atomic uint64_t g_bridge_session_sequence;
/* Native Java Threads do not inherit the Swift launch worker's TLS.
 * Bind each Java worker explicitly to its immutable session token so
 * native callbacks never infer identity from the visible window.
 * A token alone never pins a heap: all lookups still require a lease. */
static _Thread_local uint64_t g_bridge_java_thread_token;
uint64_t jvm_bridge_thread_token(void) {
    return g_bridge_java_thread_token;
}
uint64_t jvm_bridge_push_java_thread_token(uint64_t token) {
    uint64_t previous = g_bridge_java_thread_token;
    g_bridge_java_thread_token = token;
    return previous;
}
void jvm_bridge_pop_java_thread_token(uint64_t previous) {
    g_bridge_java_thread_token = previous;
}
// One visible window; every other live tab remains parked (never stopped).
static JarBoxFocusPolicy g_bridge_focus = JARBOX_FOCUS_POLICY_INITIALIZER;
// Registry owns a session pin per token; admission is memory-gated.
// 3D remains exclusive and shared 2D device safety still needs validation.
static JarBoxSessionRegistry g_bridge_registry = JARBOX_SESSION_REGISTRY_INITIALIZER;
// Protect the JVM pointer/phase while the cancellation watchdog interrupts
// Java threads; normal VM execution never takes this mutex.
static pthread_mutex_t g_bridge_lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
// Serialize native focus/park publication against cleanup admission closure.
// Lock order: focus transition -> lifecycle -> registry. Never hold this
// mutex while joining Java threads or waiting for the heap lease gate.
static pthread_mutex_t g_bridge_focus_transition_lock = PTHREAD_MUTEX_INITIALIZER;
static JarBoxVMContext *bridge_claim_worker(uint64_t token) {
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_claim_worker_locked(token);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return slot;
}
static void bridge_release_worker(JarBoxVMContext *slot) {
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    bridge_release_worker_locked(slot);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
}
// Bridge diagnostics are separate from the JVM heap and from the lifecycle
// mutex. A Java callback may report a diagnostic while a stop watchdog holds
// the lifecycle lock, so diagnostic lookup must never acquire that lock.
typedef struct {
    uint64_t token;
    char last_error[1536];
    char nso_init_trace[4096];
    char net_trace[8192];
    unsigned nso_init_trace_count, net_trace_count;
    uint64_t popup_ticks, stage_counts[5];
    int last_stage;
    unsigned early_exception_notes, loop_exception_notes, dispatch_notes;
    unsigned method_missing_notes, protocol_notes;
} JarBoxBridgeDiagnostics;
static JarBoxBridgeDiagnostics g_bridge_diagnostics[JARBOX_REGISTRY_MAX_SLOTS];
static pthread_mutex_t g_bridge_diag_lock = PTHREAD_MUTEX_INITIALIZER;

/* Call with g_bridge_diag_lock held. A missing explicit token never resolves
 * to another owner. Legacy owner-less reads resolve only a sole live record. */
static JarBoxBridgeDiagnostics *bridge_diag_find_locked(uint64_t token) {
    JarBoxBridgeDiagnostics *sole = NULL;
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxBridgeDiagnostics *entry = &g_bridge_diagnostics[i];
        if (!entry->token) continue;
        if (token && entry->token == token) return entry;
        if (!token) {
            if (sole) return NULL;
            sole = entry;
        }
    }
    return token ? NULL : sole;
}
static int bridge_diag_begin_locked(uint64_t token) {
    if (!token || bridge_diag_find_locked(token)) return 0;
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxBridgeDiagnostics *entry = &g_bridge_diagnostics[i];
        if (!entry->token) {
            memset(entry, 0, sizeof(*entry));
            entry->token = token;
            return 1;
        }
    }
    return 0;
}
static void bridge_diag_end_locked(uint64_t token) {
    JarBoxBridgeDiagnostics *entry = token ? bridge_diag_find_locked(token) : NULL;
    if (entry) memset(entry, 0, sizeof(*entry));
}
static int bridge_diag_begin(uint64_t token) {
    pthread_mutex_lock(&g_bridge_diag_lock);
    const int ok = bridge_diag_begin_locked(token);
    pthread_mutex_unlock(&g_bridge_diag_lock);
    return ok;
}
static void bridge_diag_end(uint64_t token) {
    pthread_mutex_lock(&g_bridge_diag_lock);
    bridge_diag_end_locked(token);
    pthread_mutex_unlock(&g_bridge_diag_lock);
}
static uint64_t bridge_diag_token_hint(void) {
    const uint64_t token = jvm_bridge_thread_token();
    return token ? token : jvm_bridge_visible_session_token();
}
// The focus lock is acquired before, not while holding the diagnostic lock.
// No pointer is returned to a caller outside the diagnostic critical section.
static JarBoxBridgeDiagnostics *bridge_diag_lock_current(void) {
    const uint64_t token = bridge_diag_token_hint();
    pthread_mutex_lock(&g_bridge_diag_lock);
    return bridge_diag_find_locked(token);
}
static void bridge_diag_unlock(void) {
    pthread_mutex_unlock(&g_bridge_diag_lock);
}
static int bridge_diag_take_budget(unsigned *counter, unsigned limit) {
    if (!counter || *counter >= limit) return 0;
    ++*counter;
    return 1;
}
int jvm_bridge_early_exception_note_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->early_exception_notes, 12);
    bridge_diag_unlock();
    return ok;
}
int jvm_bridge_mod_protocol_note_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->protocol_notes, 20);
    bridge_diag_unlock();
    return ok;
}
int jvm_bridge_mod_dispatch_probe_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->dispatch_notes, 2);
    bridge_diag_unlock();
    return ok;
}
int jvm_bridge_mod_method_missing_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->method_missing_notes, 10);
    bridge_diag_unlock();
    return ok;
}
void jvm_bridge_mod_loop_note_stage(int stage) {
    if (stage < 1 || stage > 4) return;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry) {
        entry->last_stage = stage;
        ++entry->stage_counts[stage];
    }
    bridge_diag_unlock();
}
uint64_t jvm_bridge_mod_loop_stage_count(int stage) {
    if (stage < 1 || stage > 4) return 0;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    uint64_t count = entry ? entry->stage_counts[stage] : 0;
    bridge_diag_unlock();
    return count;
}
int jvm_bridge_mod_loop_last_stage(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int stage = entry ? entry->last_stage : 0;
    bridge_diag_unlock();
    return stage;
}
int jvm_bridge_mod_loop_exception_log_slot(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    int ok = entry && bridge_diag_take_budget(&entry->loop_exception_notes, 12);
    bridge_diag_unlock();
    return ok;
}
void jvm_bridge_mod_popup_tick(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry) ++entry->popup_ticks;
    bridge_diag_unlock();
}
uint64_t jvm_bridge_mod_popup_tick_count(void) {
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    uint64_t count = entry ? entry->popup_ticks : 0;
    bridge_diag_unlock();
    return count;
}
static void bridge_diag_append(char *buffer, size_t size, unsigned *count,
                               unsigned limit, const char *separator,
                               const char *detail) {
    if (*count >= limit) return;
    size_t len = strlen(buffer);
    size_t avail = size - len;
    if (avail <= strlen(separator) + 1) return;
    int added = snprintf(buffer + len, avail, "%s%s", len ? separator : "", detail);
    if (added > 0) ++*count;
}
void jvm_bridge_note_net_trace(const char *detail) {
    if (!detail || !detail[0]) return;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry)
        bridge_diag_append(entry->net_trace, sizeof(entry->net_trace),
                           &entry->net_trace_count, 64, "\n", detail);
    bridge_diag_unlock();
    printf("[JarBoxNET] %s\n", detail);
}
void jvm_bridge_note_nso_init_trace(const char *detail) {
    if (!detail || !detail[0]) return;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry)
        bridge_diag_append(entry->nso_init_trace, sizeof(entry->nso_init_trace),
                           &entry->nso_init_trace_count, 20, " | ", detail);
    bridge_diag_unlock();
    printf("[JarBoxVM][NSOInit] %s\n", detail);
}
void jvm_bridge_set_launch_error(const char *message) {
    if (!message) return;
    JarBoxBridgeDiagnostics *entry = bridge_diag_lock_current();
    if (entry) snprintf(entry->last_error, sizeof(entry->last_error), "%s", message);
    bridge_diag_unlock();
    printf("[JarBoxVM][LaunchError] %s\n", message);
}
// Explicit per-worker snapshots outlive the critical section, not the caller.
// TLS arrays avoid returning a pointer into a reusable executor record.
static const char *bridge_diag_snapshot(uint64_t token, int kind, int explicit_token) {
    static _Thread_local char snapshot[8192];
    snapshot[0] = '\0';
    if (explicit_token && !token) return snapshot;
    pthread_mutex_lock(&g_bridge_diag_lock);
    JarBoxBridgeDiagnostics *entry = bridge_diag_find_locked(token);
    if (entry) {
        const char *value = kind == 0 ? entry->last_error :
                            kind == 1 ? entry->nso_init_trace : entry->net_trace;
        snprintf(snapshot, sizeof(snapshot), "%s", value);
    }
    pthread_mutex_unlock(&g_bridge_diag_lock);
    return snapshot;
}
const char *jvm_bridge_last_error_for_token(uint64_t token) {
    return bridge_diag_snapshot(token, 0, 1);
}
const char *jvm_bridge_nso_init_trace_for_token(uint64_t token) {
    return bridge_diag_snapshot(token, 1, 1);
}
const char *jvm_bridge_net_trace_for_token(uint64_t token) {
    return bridge_diag_snapshot(token, 2, 1);
}
const char *jvm_bridge_last_error(void) {
    return bridge_diag_snapshot(bridge_diag_token_hint(), 0, 0);
}
const char *jvm_bridge_nso_init_trace(void) {
    return bridge_diag_snapshot(bridge_diag_token_hint(), 1, 0);
}
const char *jvm_bridge_net_trace(void) {
    return bridge_diag_snapshot(bridge_diag_token_hint(), 2, 0);
}

/* Every launch receives its immutable token in the SAME admission call.
 * Never ask the asynchronous Swift worker to discover its owner by reading
 * the process's latest foreground token. The current runtime still has one
 * execution slot; this is a lifetime-safe contract for its future pool. */
// Requires lifecycle lock: STARTING and CLEANUP count as occupied.
static int bridge_3d_conflict_locked(int requested_exclusive) {
    unsigned active = 0;
    int existing_exclusive = 0;
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxVMContext *slot = &g_bridge_slots[i];
        if (!atomic_load_explicit(&slot->active, memory_order_acquire)) continue;
        ++active;
        existing_exclusive |= slot->exclusive_3d;
    }
    return jarbox_3d_conflict(active, existing_exclusive, requested_exclusive);
}

int jvm_bridge_3d_conflict_for_jar(const char *path) {
    // Existing exclusive ownership rejects all new launches, without any
    // archive I/O on the UI thread. Admission always checks again.
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    const int existing = bridge_3d_conflict_locked(0);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (existing) return 1;
    const int exclusive = bridge_jar_requires_exclusive_cached(path);
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    const int conflict = bridge_3d_conflict_locked(exclusive);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return conflict;
}

// Advisory budget, sampled fresh at each admission. Never derive it from
// installed RAM. A warning can arrive even when the app's own headroom is
// large, so give iOS a short recovery interval before admitting another VM.
static int bridge_memory_level(uint64_t available, int recent_warning) {
    if (available < UINT64_C(150) * 1024 * 1024) return 2;
    if (recent_warning || available <= UINT64_C(300) * 1024 * 1024) return 1;
    return 0;
}

#if defined(__APPLE__) && __JVM_OS_IOS__
static _Atomic uint64_t bridge_last_memory_warning;
static uint64_t bridge_memory_clock(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * UINT64_C(1000000000) + (uint64_t)ts.tv_nsec;
}
#endif

void jvm_bridge_memory_note_warning(void) {
#if defined(__APPLE__) && __JVM_OS_IOS__
    atomic_store_explicit(&bridge_last_memory_warning, bridge_memory_clock(), memory_order_release);
#endif
}

int jvm_bridge_memory_state(uint64_t *out_available) {
#if defined(__APPLE__) && __JVM_OS_IOS__
    const uint64_t available = (uint64_t)os_proc_available_memory();
    const uint64_t last = atomic_load_explicit(&bridge_last_memory_warning, memory_order_acquire);
    const uint64_t now = bridge_memory_clock();
    const int recent = last != 0 && (now < last || now - last < UINT64_C(15000000000));
#else
    // Non-iOS host smoke tests have no iOS process budget. Do not confuse
    // unsupported telemetry with zero bytes on a real device.
    const uint64_t available = UINT64_MAX;
    const int recent = 0;
#endif
    if (out_available) *out_available = available;
    return bridge_memory_level(available, recent);
}

// Serialize only the inexpensive headroom sample, never a GC or heap walk.
// Existing collectors and live Metal frames share this sample.
int jvm_bridge_memory_state_cached(void) {
#if defined(__APPLE__) && __JVM_OS_IOS__
    static pthread_mutex_t sample_lock = PTHREAD_MUTEX_INITIALIZER;
    static uint64_t last_sample;
    static int sampled_state;
    pthread_mutex_lock(&sample_lock);
    const uint64_t now = bridge_memory_clock();
    const uint64_t warning = atomic_load_explicit(&bridge_last_memory_warning, memory_order_acquire);
    if (!last_sample || now < last_sample ||
        now - last_sample >= UINT64_C(1000000000) || warning > last_sample) {
        sampled_state = jvm_bridge_memory_state(NULL);
        last_sample = now;
    }
    const int result = sampled_state;
    pthread_mutex_unlock(&sample_lock);
    return result;
#else
    return jvm_bridge_memory_state(NULL);
#endif
}

static int bridge_try_begin_session(int exclusive, uint64_t *out_token) {
    if (!out_token) return 0;
    *out_token = 0;
    // Admission is also a foreground transition. Serialize with park/focus
    // and cleanup, in the same lock order; never implicitly park another VM.
    pthread_mutex_lock(&g_bridge_focus_transition_lock);
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    int denial = 0;
    if (bridge_3d_conflict_locked(exclusive)) { denial = -1; goto denied; }
    if (jarbox_focus_visible(&g_bridge_focus) != 0) goto denied;
    if (jvm_bridge_memory_state(NULL) != 0) { denial = -2; goto denied; }
    const uint64_t token = atomic_fetch_add_explicit(
        &g_bridge_session_sequence, 1, memory_order_relaxed) + 1;
    JarBoxVMContext *slot = bridge_reserve_slot_locked(
        token, (unsigned)jvm_bridge_supported_concurrent_sessions());
    if (!slot) goto denied;
    slot->exclusive_3d = exclusive != 0;
    if (!jarbox_registry_claim(&g_bridge_registry, &g_bridge_focus,
                               token, (unsigned)jvm_bridge_supported_concurrent_sessions())) {
        bridge_reset_slot_locked(slot);
        goto denied;
    }
    if (!jarbox_focus_select(&g_bridge_focus, token) || !bridge_diag_begin(token)) {
        (void)jarbox_registry_finish(&g_bridge_registry, &g_bridge_focus, token);
        bridge_reset_slot_locked(slot);
        goto denied;
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    pthread_mutex_unlock(&g_bridge_focus_transition_lock);
    // Visible from the first frame in Chẩn đoán kết nối, regardless of
    // which Java network API the game calls. Detects an older installed IPA.
    const uint64_t prior_token = jvm_bridge_push_java_thread_token(token);
    jvm_bridge_note_net_trace("probe:java8_utf8_boot_patch=v1");
    jvm_bridge_note_net_trace("probe:java8_localtime_boot_patch=v1");
    jvm_bridge_note_net_trace("probe:vm_opcode_guard=v1");
    jvm_bridge_pop_java_thread_token(prior_token);
    printf("[JarBoxVM][Lifecycle] session=acquired phase=starting\n");
    *out_token = token;
    return 1;

denied:
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    pthread_mutex_unlock(&g_bridge_focus_transition_lock);
    return denial;
}

int jvm_bridge_try_begin_session_for_jar(const char *path, uint64_t *out_token) {
    return bridge_try_begin_session(bridge_jar_requires_exclusive_cached(path), out_token);
}

int jvm_bridge_try_begin_session_with_token(uint64_t *out_token) {
    return bridge_try_begin_session(1, out_token) == 1;
}

int jvm_bridge_try_begin_session(void) {
    uint64_t acquired = 0;
    return jvm_bridge_try_begin_session_with_token(&acquired);
}
/* Token-based synchronous VM pin. The lifecycle lock establishes a
 * consistent admission point; the callback lease keeps the heap alive while
 * UIKit/render/input callbacks finish, even when teardown starts meanwhile.
 * STARTING slots are parked in the policy without dereferencing a half-built
 * MiniJVM. Still single-live until the executor and UIKit routing are split. */
static MiniJVM *bridge_pin_running_owner(uint64_t token, JarBoxSession **held) {
    if (held) *held = NULL;
    if (!token || !held) return NULL;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    const int matches = slot &&
        atomic_load_explicit(&slot->phase, memory_order_acquire) == BRIDGE_RUNNING;
    MiniJVM *vm = matches ?
        (MiniJVM *)jarbox_registry_pin_vm(&g_bridge_registry, token, held) : NULL;
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return vm;
}
int jvm_bridge_park_session(uint64_t token) {
    pthread_mutex_lock(&g_bridge_focus_transition_lock);
    if (!jarbox_registry_contains_token(&g_bridge_registry, token)) {
        pthread_mutex_unlock(&g_bridge_focus_transition_lock);
        return 0;
    }
    JarBoxSession *held = NULL;
    MiniJVM *owner = bridge_pin_running_owner(token, &held);
    // The visible framebuffer is revoked before any deferred UIKit flush.
    // A STARTING VM has no published renderer to release yet.
    if (owner) {
        j2me_render_release_vm(owner);
        j2me_input_park_vm(owner);
        j2me_ui_park_vm(owner);
    }
    const int parked = jarbox_focus_park_one(&g_bridge_focus, token);
    if (owner) {
        if (parked) (void)jarbox_session_park(held);
        jarbox_session_callback_done(held);
    }
    pthread_mutex_unlock(&g_bridge_focus_transition_lock);
    return parked;
}

int jvm_bridge_focus_session(uint64_t token) {
    // A tab coordinator must park the previous owner before selecting B.
    pthread_mutex_lock(&g_bridge_focus_transition_lock);
    const uint64_t visible = jarbox_focus_visible(&g_bridge_focus);
    if (visible && visible != token) {
        pthread_mutex_unlock(&g_bridge_focus_transition_lock);
        return 0;
    }
    JarBoxSession *held = NULL;
    MiniJVM *owner = bridge_pin_running_owner(token, &held);
    if (!owner) {
        pthread_mutex_unlock(&g_bridge_focus_transition_lock);
        return 0;
    }
    // Renderer, input and LCDUI must agree on the same owner generation.
    // No callback may retain this raw pointer beyond the lease below.
    const int ready = j2me_render_focus_vm(owner) &&
                      j2me_input_focus_vm(owner) &&
                      j2me_ui_focus_vm(owner);
    const int selected = ready ? jarbox_focus_select(&g_bridge_focus, token) : 0;
    if (selected) {
        (void)jarbox_session_enter_foreground(held);
    } else {
        // A partial native focus acquisition must not leave an input or
        // framebuffer destination attached to a hidden/failed controller.
        j2me_render_release_vm(owner);
        j2me_input_park_vm(owner);
        j2me_ui_park_vm(owner);
        (void)jarbox_focus_park_one(&g_bridge_focus, token);
    }
    jarbox_session_callback_done(held);
    pthread_mutex_unlock(&g_bridge_focus_transition_lock);
    return selected;
}

int jvm_bridge_is_2d_running_for_token(uint64_t token) {
    if (!token) return 0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    const int ready = slot && !slot->exclusive_3d &&
        atomic_load_explicit(&slot->phase, memory_order_acquire) == BRIDGE_RUNNING &&
        !atomic_load_explicit(&slot->stop_requested, memory_order_acquire);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return ready;
}

int jvm_bridge_background_audio_policy(void) {
    int occupied=0, running=0, starting=0, exclusive=0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    for (unsigned i=0;i<JARBOX_REGISTRY_MAX_SLOTS;++i) {
        JarBoxVMContext *slot=&g_bridge_slots[i];
        if (!atomic_load_explicit(&slot->active,memory_order_acquire)) continue;
        occupied=1;
        exclusive |= slot->exclusive_3d;
        int phase=atomic_load_explicit(&slot->phase,memory_order_acquire);
        starting |= phase==BRIDGE_STARTING;
        running |= phase==BRIDGE_RUNNING &&
            !atomic_load_explicit(&slot->stop_requested,memory_order_acquire);
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (!occupied || exclusive) return 0;
    return running && !starting ? 2 : 1;
}

int jvm_bridge_session_is_parked(uint64_t token) {
    return jarbox_focus_is_parked(&g_bridge_focus, token);
}
uint64_t jvm_bridge_visible_session_token(void) {
    return jarbox_focus_visible(&g_bridge_focus);
}

// UI diagnostics and automatic Treo actions execute on a different thread
// from the collector. Pin the live JVM under the lifecycle lock; teardown
// transitions phase to CLEANUP under the same lock before destroying memory.
// NEVER return the VM pointer to an asynchronous caller.
int jvm_bridge_visit_running_vm_for_token(
        uint64_t token, void (*visitor)(MiniJVM *, void *), void *arg) {
    if (!token || !visitor) return 0;
    JarBoxSession *held_session = NULL;
    MiniJVM *vm = bridge_pin_running_owner(token, &held_session);
    // The callback lease, not a mutable slot pointer, protects this VM.
    if (!vm) return 0;
    visitor(vm, arg);
    jarbox_session_callback_done(held_session);
    return 1;
}
// TLS records are linked only during the existing worker/runner lifetime.
// Each owns a Mach send right. No VM heap/thread-list/lifecycle lock is
// acquired here. Sampling is at mode boundaries or on demand, never a timer.
#if defined(__APPLE__) && __JVM_OS_IOS__
typedef struct JarBoxCpuThread {
    struct JarBoxCpuThread *next;
    JarBoxSession *owner;
    thread_t port;
    uint64_t baseline_ns, latest_ns;
    int kind, ready;
} JarBoxCpuThread;
static pthread_mutex_t bridge_cpu_lock=PTHREAD_MUTEX_INITIALIZER;
static _Thread_local JarBoxCpuThread bridge_cpu_thread;
int jvm_bridge_cpu_is_java_worker(JarBoxSession *s) {
    return s && bridge_cpu_thread.owner==s && bridge_cpu_thread.kind==JARBOX_CPU_JAVA;
}
static int bridge_cpu_read_thread(thread_t port,uint64_t *out) {
    thread_basic_info_data_t info;
    mach_msg_type_number_t count=THREAD_BASIC_INFO_COUNT;
    if (!MACH_PORT_VALID(port) ||
        thread_info(port,THREAD_BASIC_INFO,(thread_info_t)&info,&count)!=KERN_SUCCESS ||
        count<THREAD_BASIC_INFO_COUNT) return 0;
    *out=((uint64_t)info.user_time.seconds+(uint64_t)info.system_time.seconds)*UINT64_C(1000000000)
        +((uint64_t)info.user_time.microseconds+(uint64_t)info.system_time.microseconds)*1000;
    return 1;
}
static void bridge_cpu_refresh_thread(JarBoxCpuThread *t) {
    uint64_t now;
    if (!t->ready) return;
    if (!bridge_cpu_read_thread(t->port,&now) || now<t->latest_ns) {
        ++t->owner->cpu_sample_errors;
        return;
    }
    t->latest_ns=now;
}
void jvm_bridge_cpu_worker_begin(JarBoxSession *s,int kind) {
    if (!s || kind<0 || kind>=JARBOX_CPU_KINDS) return;
    JarBoxCpuThread *t=&bridge_cpu_thread;
    pthread_mutex_lock(&bridge_cpu_lock);
    if (t->owner) {
        ++s->cpu_sample_errors;
        pthread_mutex_unlock(&bridge_cpu_lock);
        return;
    }
    t->owner=s; t->kind=kind; t->port=mach_thread_self();
    t->ready=bridge_cpu_read_thread(t->port,&t->baseline_ns);
    t->latest_ns=t->baseline_ns;
    if (!t->ready) ++s->cpu_sample_errors;
    t->next=s->cpu_threads; s->cpu_threads=t;
    pthread_mutex_unlock(&bridge_cpu_lock);
}
void jvm_bridge_cpu_worker_end(JarBoxSession *s) {
    JarBoxCpuThread *t=&bridge_cpu_thread;
    pthread_mutex_lock(&bridge_cpu_lock);
    if (s && t->owner==s) {
        bridge_cpu_refresh_thread(t);
        if (t->ready) s->cpu_retired_ns[t->kind]+=t->latest_ns-t->baseline_ns;
        JarBoxCpuThread **p=&s->cpu_threads;
        while (*p && *p!=t) p=&(*p)->next;
        if (*p==t) *p=t->next;
        if (MACH_PORT_VALID(t->port)) mach_port_deallocate(mach_task_self(),t->port);
        memset(t,0,sizeof(*t));
    }
    pthread_mutex_unlock(&bridge_cpu_lock);
}
static JarBoxCpuPoint bridge_cpu_point(JarBoxSession *s) {
    JarBoxCpuPoint p={0};
    uint64_t totals[JARBOX_CPU_KINDS];
    memcpy(totals,s->cpu_retired_ns,sizeof(totals));
    for (JarBoxCpuThread *t=s->cpu_threads;t;t=t->next) {
        bridge_cpu_refresh_thread(t);
        if (t->ready) totals[t->kind]+=t->latest_ns-t->baseline_ns;
    }
    p.runner_ns=totals[JARBOX_CPU_RUNNER]; p.java_ns=totals[JARBOX_CPU_JAVA];
    p.gc_ns=totals[JARBOX_CPU_GC]; p.errors=s->cpu_sample_errors;
    struct rusage ru;
    if (getrusage(RUSAGE_SELF,&ru)==0) {
        p.process_ok=1;
        p.process_ns=((uint64_t)ru.ru_utime.tv_sec+(uint64_t)ru.ru_stime.tv_sec)*UINT64_C(1000000000)
            +((uint64_t)ru.ru_utime.tv_usec+(uint64_t)ru.ru_stime.tv_usec)*1000;
    }
    p.gc_cycles=__atomic_load_n(&s->treo_state.gc_worker_cycles,__ATOMIC_RELAXED);
    p.requests=__atomic_load_n(&s->treo_state.nso_repaint_requests,__ATOMIC_RELAXED);
    p.skips=jarbox_treo_nso_skip_count(&s->treo_state,0);
    p.wall_ns=bridge_memory_clock();
    return p;
}
void jvm_bridge_cpu_mode_changed(JarBoxSession *s) {
    if (!s) return;
    pthread_mutex_lock(&bridge_cpu_lock);
    int mode=jarbox_treo_mode_get(&s->treo_state);
    if (!s->cpu_history.initialized || s->cpu_history.mode!=mode)
        jarbox_cpu_history_transition(&s->cpu_history,mode,bridge_cpu_point(s));
    pthread_mutex_unlock(&bridge_cpu_lock);
}
static void bridge_cpu_snapshot(MiniJVM *vm,void *arg) {
    JarBoxSession *s=vm->session;
    pthread_mutex_lock(&bridge_cpu_lock);
    JarBoxCpuPoint point=bridge_cpu_point(s);
    *(JarBoxCpuSnapshot *)arg=jarbox_cpu_history_snapshot(&s->cpu_history,point);
    if (s->cpu_history.mode!=jarbox_treo_mode_get(&s->treo_state))
        ((JarBoxCpuSnapshot *)arg)->current.valid=0;
    pthread_mutex_unlock(&bridge_cpu_lock);
}
#else
void jvm_bridge_cpu_worker_begin(JarBoxSession *s,int kind) {(void)s;(void)kind;}
void jvm_bridge_cpu_worker_end(JarBoxSession *s) {(void)s;}
int jvm_bridge_cpu_is_java_worker(JarBoxSession *s) {(void)s;return 0;}
void jvm_bridge_cpu_mode_changed(JarBoxSession *s) {(void)s;}
#endif
int jvm_bridge_cpu_snapshot_for_token(uint64_t token,JarBoxCpuSnapshot *out) {
    if (!out) return 0;
    memset(out,0,sizeof(*out));
#if defined(__APPLE__) && __JVM_OS_IOS__
    return jvm_bridge_visit_running_vm_for_token(token,bridge_cpu_snapshot,out);
#else
    (void)token;
    return 0;
#endif
}

const char *jvm_bridge_flight_hot_text(const JarBoxFlightSlot *slot) {
    return slot ? slot->hot_rows : "";
}

// Diagnostic snapshots never wait for bridge locks or walk Java heaps.
int jvm_bridge_flight_sample(JarBoxFlightProcess *process, JarBoxFlightSlot *slots,
                            int capacity, int detail) {
    if (!process || !slots || capacity<=0) return -1;
    memset(process,0,sizeof(*process));
#if defined(__APPLE__) && __JVM_OS_IOS__
    process->wall_ns=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    struct rusage ru;
    if (getrusage(RUSAGE_SELF,&ru)==0) {
        process->process_ok=1;
        process->process_ns=((uint64_t)ru.ru_utime.tv_sec+(uint64_t)ru.ru_stime.tv_sec)*UINT64_C(1000000000)
            +((uint64_t)ru.ru_utime.tv_usec+(uint64_t)ru.ru_stime.tv_usec)*1000;
    }
    task_vm_info_data_t info={0};
    mach_msg_type_number_t info_count=TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&info_count)==KERN_SUCCESS &&
        info_count>=TASK_VM_INFO_REV1_COUNT) {
        process->footprint_bytes=info.phys_footprint;
        process->footprint_ok=1;
    }
    process->memory_state=jvm_bridge_memory_state(&process->headroom_bytes);
    if (pthread_mutex_trylock(&g_bridge_lifecycle_lock)!=0) return -1;
    JarBoxSession *held[JARBOX_REGISTRY_MAX_SLOTS]={0};
    int count=0;
    for (unsigned i=0;i<JARBOX_REGISTRY_MAX_SLOTS && count<capacity;++i) {
        JarBoxVMContext *slot=&g_bridge_slots[i];
        if (!atomic_load_explicit(&slot->active,memory_order_acquire)) continue;
        JarBoxFlightSlot *out=&slots[count];
        memset(out,0,sizeof(*out));
        out->token=atomic_load_explicit(&slot->token,memory_order_acquire);
        out->phase=atomic_load_explicit(&slot->phase,memory_order_acquire);
        out->stop_requested=atomic_load_explicit(&slot->stop_requested,memory_order_acquire);
        out->mode=-1;
        // STARTING may be incomplete; CLEANUP may already be freeing the VM.
        if (detail && out->phase==BRIDGE_RUNNING) {
            MiniJVM *vm=atomic_load_explicit(&slot->jvm,memory_order_acquire);
            if (vm && vm->session && jarbox_session_reserve_callback(vm->session))
                held[count]=vm->session;
        }
        ++count;
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    unsigned budget=128;
    for (int i=0;i<count;++i) {
        JarBoxSession *session=held[i];
        if (!session) continue;
        JarBoxFlightSlot *out=&slots[i];
        out->workers=jarbox_session_worker_count(session);
        out->mode=jarbox_treo_mode_get(&session->treo_state);
        out->gc_cycles=__atomic_load_n(&session->treo_state.gc_worker_cycles,__ATOMIC_RELAXED);
        out->gc_aborts=__atomic_load_n(&session->treo_state.gc_worker_aborts,__ATOMIC_RELAXED);
#if defined(TREO_GC_PHASE_DIAG) && TREO_GC_PHASE_DIAG && defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__
        JarBoxGCPhaseStats *gp=&session->treo_state.gc_phase;
        JarBoxGCPhaseTotals gt;
        out->gc_phase_ok=jarbox_gc_phase_snapshot(gp,&gt);
        out->gc_phase_busy=__atomic_load_n(&gp->busy,__ATOMIC_RELAXED);
        out->gc_phase_invalid=__atomic_load_n(&gp->invalid,__ATOMIC_RELAXED);
        out->gc_phase_aborted=__atomic_load_n(&gp->aborted,__ATOMIC_RELAXED);
        if (out->gc_phase_ok) {
            out->gc_phase_cycles=gt.cycles;
            out->gc_phase_scanned=gt.scanned;
            out->gc_phase_reclaimed=gt.reclaimed;
            out->gc_phase_freed_bytes=gt.freed_bytes;
            out->gc_phase_pause_cpu_ns=gt.cpu[0];
            out->gc_phase_pause_wall_ns=gt.wall[0];
            out->gc_phase_roots_cpu_ns=gt.cpu[1];
            out->gc_phase_roots_wall_ns=gt.wall[1];
            out->gc_phase_mark_cpu_ns=gt.cpu[2];
            out->gc_phase_mark_wall_ns=gt.wall[2];
            out->gc_phase_resume_cpu_ns=gt.cpu[3];
            out->gc_phase_resume_wall_ns=gt.wall[3];
            out->gc_phase_deferred_cpu_ns=gt.cpu[4];
            out->gc_phase_deferred_wall_ns=gt.wall[4];
            out->gc_phase_sweep_cpu_ns=gt.cpu[5];
            out->gc_phase_sweep_wall_ns=gt.wall[5];
        }
#endif
#if defined(TREO_CANVAS_PHASE_DIAG) && TREO_CANVAS_PHASE_DIAG
        JarBoxCanvasPhaseStats *cp=&session->treo_state.canvas_phase;
        JarBoxCanvasPhaseTotals ct;
        out->canvas_phase_ok=jarbox_canvas_phase_snapshot(cp,&ct);
        out->canvas_phase_invalid=__atomic_load_n(&cp->invalid,__ATOMIC_RELAXED);
        out->canvas_phase_busy=__atomic_load_n(&cp->busy,__ATOMIC_RELAXED);
        if (out->canvas_phase_ok) {
            out->canvas_phase_frames=ct.frames;
            out->canvas_phase_pre_ns=ct.pre_ns;
            out->canvas_phase_paint_ns=ct.paint_ns;
            out->canvas_phase_post_ns=ct.post_ns;
        }
#endif
        out->repaint_requests=__atomic_load_n(&session->treo_state.nso_repaint_requests,__ATOMIC_RELAXED);
        out->array_lookup_mode1_calls=__atomic_load_n(&session->treo_state.array_lookup_mode1_calls,__ATOMIC_RELAXED);
        out->char_leaf_calls=__atomic_load_n(&session->treo_state.char_leaf_calls,__ATOMIC_RELAXED);
        out->afk_profile_paint_calls=__atomic_load_n(&session->treo_state.afk_profile_paint_calls,__ATOMIC_RELAXED);
        out->afk_profile_paint_cpu_ns=__atomic_load_n(&session->treo_state.afk_profile_paint_cpu_ns,__ATOMIC_RELAXED);
        out->compatible_font_reuses=__atomic_load_n(&session->treo_state.compatible_font_reuses,__ATOMIC_RELAXED);
        out->compatible_crop_hits=__atomic_load_n(&session->treo_state.compatible_crop_hits,__ATOMIC_RELAXED);
#if defined(TREO_HOTSPOT_DIAG) && TREO_HOTSPOT_DIAG && __JVM_OS_IOS__
        _Static_assert(sizeof(out->hot_rows)==JARBOX_HOT_TEXT,"hotspot text ABI");
        out->hot_ok=jarbox_hot_report(&session->treo_state.hotspot,&out->hot_samples,out->hot_rows);
        out->hot_busy=__atomic_load_n(&session->treo_state.hotspot.busy,__ATOMIC_RELAXED);
        out->hot_invalid=__atomic_load_n(&session->treo_state.hotspot.invalid,__ATOMIC_RELAXED);
#endif
        out->region_stage_seen=__atomic_load_n(&session->treo_state.region_stage_seen,__ATOMIC_RELAXED);
        out->region_stage_samples=__atomic_load_n(&session->treo_state.region_stage_samples,__ATOMIC_RELAXED);
        out->region_stage_hit_samples=__atomic_load_n(&session->treo_state.region_stage_hit_samples,__ATOMIC_RELAXED);
        out->region_stage_hit_ns=__atomic_load_n(&session->treo_state.region_stage_hit_ns,__ATOMIC_RELAXED);
        out->region_stage_miss_ns=__atomic_load_n(&session->treo_state.region_stage_miss_ns,__ATOMIC_RELAXED);
        out->region_stage_draw_ns=__atomic_load_n(&session->treo_state.region_stage_draw_ns,__ATOMIC_RELAXED);
        out->region_stage_invalid=__atomic_load_n(&session->treo_state.region_stage_invalid,__ATOMIC_RELAXED);
        out->compatible_crop_misses=__atomic_load_n(&session->treo_state.compatible_crop_misses,__ATOMIC_RELAXED);
        out->compatible_state_reuses=__atomic_load_n(&session->treo_state.compatible_state_reuses,__ATOMIC_RELAXED);
        out->compatible_region_culls=__atomic_load_n(&session->treo_state.compatible_region_culls,__ATOMIC_RELAXED);
        out->qos_paint_attempts=__atomic_load_n(&session->treo_state.qos_paint_attempts,__ATOMIC_RELAXED);
        out->qos_paint_applied=__atomic_load_n(&session->treo_state.qos_paint_applied,__ATOMIC_RELAXED);
        out->qos_paint_already_utility=__atomic_load_n(&session->treo_state.qos_paint_already_utility,__ATOMIC_RELAXED);
        out->qos_paint_unrestorable=__atomic_load_n(&session->treo_state.qos_paint_unrestorable,__ATOMIC_RELAXED);
        out->qos_paint_errors=__atomic_load_n(&session->treo_state.qos_paint_errors,__ATOMIC_RELAXED);
        out->qos_paint_restore_errors=__atomic_load_n(&session->treo_state.qos_paint_restore_errors,__ATOMIC_RELAXED);
        out->qos_paint_completed=__atomic_load_n(&session->treo_state.qos_paint_completed,__ATOMIC_RELAXED);
        out->qos_paint_cpu_ns=__atomic_load_n(&session->treo_state.qos_paint_cpu_ns,__ATOMIC_RELAXED);
        out->qos_paint_wall_ns=__atomic_load_n(&session->treo_state.qos_paint_wall_ns,__ATOMIC_RELAXED);
        out->qos_paint_over_budget=__atomic_load_n(&session->treo_state.qos_paint_over_budget,__ATOMIC_RELAXED);
        out->qos_paint_backoff=__atomic_load_n(&session->treo_state.qos_paint_backoff,__ATOMIC_RELAXED);
        out->qos_original_class=__atomic_load_n(&session->treo_state.qos_original_class,__ATOMIC_RELAXED);
        out->qos_observed_class=__atomic_load_n(&session->treo_state.qos_observed_class,__ATOMIC_RELAXED);
        out->qos_paint_normal_completed=__atomic_load_n(&session->treo_state.qos_paint_normal_completed,__ATOMIC_RELAXED);
        out->qos_paint_normal_wall_ns=__atomic_load_n(&session->treo_state.qos_paint_normal_wall_ns,__ATOMIC_RELAXED);
        out->compatible_text_attr_reuses=__atomic_load_n(&session->treo_state.compatible_text_attr_reuses,__ATOMIC_RELAXED);
#if defined(TREO_CORE_ABA) && TREO_CORE_ABA
        uint64_t aba_epoch=__atomic_load_n(&session->treo_state.core_aba_start_ns,__ATOMIC_ACQUIRE);
        uint64_t aba_now=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
        if (aba_epoch && aba_now>=aba_epoch &&
            aba_epoch==__atomic_load_n(&session->treo_state.core_aba_start_ns,__ATOMIC_ACQUIRE)) {
            out->core_aba_start_ns=aba_epoch;
            out->core_aba_elapsed_ns=aba_now-aba_epoch;
            out->core_aba_phase=jarbox_core_aba_phase(aba_epoch,aba_now);
        }
#endif
        out->nso_core_profile=__atomic_load_n(&session->treo_state.ninja_core.profile,__ATOMIC_RELAXED);
        out->nso_core_armed=__atomic_load_n(&session->treo_state.ninja_core.armed,__ATOMIC_RELAXED);
        out->nso_core_rejected=__atomic_load_n(&session->treo_state.ninja_core.rejected,__ATOMIC_RELAXED);
        out->nso_core_frames=__atomic_load_n(&session->treo_state.ninja_core.frames,__ATOMIC_RELAXED);
        out->nso_core_faults=__atomic_load_n(&session->treo_state.ninja_core.faults,__ATOMIC_RELAXED);
        out->scoped_native_draw_skips=__atomic_load_n(&session->treo_state.ninja_core.scoped_native_draw_skips,__ATOMIC_RELAXED);
        out->scoped_vm_draw_skips=__atomic_load_n(&session->treo_state.ninja_core.scoped_vm_draw_skips,__ATOMIC_RELAXED);
        out->native_diag_seen=__atomic_load_n(&session->treo_state.native_diag_seen,__ATOMIC_RELAXED);
        out->native_diag_selected_frames=__atomic_load_n(&session->treo_state.native_diag_selected_frames,__ATOMIC_RELAXED);
        out->native_diag_selected_cpu_ns=__atomic_load_n(&session->treo_state.native_diag_selected_cpu_ns,__ATOMIC_RELAXED);
        out->native_diag_plain_frames=__atomic_load_n(&session->treo_state.native_diag_plain_frames,__ATOMIC_RELAXED);
        out->native_diag_plain_cpu_ns=__atomic_load_n(&session->treo_state.native_diag_plain_cpu_ns,__ATOMIC_RELAXED);
        out->native_diag_discarded_frames=__atomic_load_n(&session->treo_state.native_diag_discarded_frames,__ATOMIC_RELAXED);
        out->native_diag_draw_calls=__atomic_load_n(&session->treo_state.native_diag_draw_calls,__ATOMIC_RELAXED);
        out->native_diag_draw_ns=__atomic_load_n(&session->treo_state.native_diag_draw_ns,__ATOMIC_RELAXED);
        out->native_diag_lcd_other_calls=__atomic_load_n(&session->treo_state.native_diag_lcd_other_calls,__ATOMIC_RELAXED);
        out->native_diag_lcd_other_ns=__atomic_load_n(&session->treo_state.native_diag_lcd_other_ns,__ATOMIC_RELAXED);
        out->native_diag_other_calls=__atomic_load_n(&session->treo_state.native_diag_other_calls,__ATOMIC_RELAXED);
        out->native_diag_other_ns=__atomic_load_n(&session->treo_state.native_diag_other_ns,__ATOMIC_RELAXED);
        out->native_diag_drawrgb_calls=__atomic_load_n(&session->treo_state.native_diag_drawrgb_calls,__ATOMIC_RELAXED);
        out->native_diag_drawrgb_pixels=__atomic_load_n(&session->treo_state.native_diag_drawrgb_pixels,__ATOMIC_RELAXED);
        out->native_diag_getrgb_calls=__atomic_load_n(&session->treo_state.native_diag_getrgb_calls,__ATOMIC_RELAXED);
        out->native_diag_getrgb_pixels=__atomic_load_n(&session->treo_state.native_diag_getrgb_pixels,__ATOMIC_RELAXED);
        out->nso_repaint_skips=jarbox_treo_nso_skip_count(&session->treo_state,0);
        out->nso_service_skips=jarbox_treo_nso_skip_count(&session->treo_state,1);
        out->nso_paint_skips=jarbox_treo_nso_skip_count(&session->treo_state,2);
        out->const_arith_fusions=__atomic_load_n(&session->const_arith_fusions,__ATOMIC_RELAXED);
        out->const_branch_fusions=__atomic_load_n(&session->const_branch_fusions,__ATOMIC_RELAXED);
        out->decoded_int_calls=__atomic_load_n(&session->decoded_int_calls,__ATOMIC_RELAXED);
        out->event_sleep_handled=__atomic_load_n(&session->event_sleep_handled,__ATOMIC_RELAXED);
        out->event_sleep_fallbacks=__atomic_load_n(&session->event_sleep_fallbacks,__ATOMIC_RELAXED);
        out->shared_zip_probes=__atomic_load_n(&session->shared_zip_probes,__ATOMIC_RELAXED);
        out->shared_zip_hits=__atomic_load_n(&session->shared_zip_hits,__ATOMIC_RELAXED);
        out->shared_zip_negative_hits=__atomic_load_n(&session->shared_zip_negative_hits,__ATOMIC_RELAXED);
        out->shared_prepared_candidates=__atomic_load_n(&session->shared_prepared_candidates,__ATOMIC_RELAXED);
        out->shared_prepared_hits=__atomic_load_n(&session->shared_prepared_hits,__ATOMIC_RELAXED);
        out->startup_image_decodes=__atomic_load_n(&session->startup_image_decodes,__ATOMIC_RELAXED);
        out->startup_image_hits=__atomic_load_n(&session->startup_image_hits,__ATOMIC_RELAXED);
        out->startup_image_decode_ns=__atomic_load_n(&session->startup_image_decode_ns,__ATOMIC_RELAXED);
        out->counters_ok=1;
        if (pthread_mutex_trylock(&bridge_cpu_lock)==0) {
            uint64_t totals[JARBOX_CPU_KINDS];
            memcpy(totals,session->cpu_retired_ns,sizeof(totals));
            int ok=session->cpu_sample_errors==0;
            for (JarBoxCpuThread *thread=session->cpu_threads;thread;thread=thread->next) {
                if (!budget) { ok=0; break; }
                --budget;
                uint64_t now;
                if (!thread->ready || !bridge_cpu_read_thread(thread->port,&now) ||
                    now<thread->baseline_ns || thread->kind<0 || thread->kind>=JARBOX_CPU_KINDS) {
                    ok=0; break;
                }
                totals[thread->kind]+=now-thread->baseline_ns;
            }
            if (ok) {
                out->runner_ns=totals[JARBOX_CPU_RUNNER];
                out->java_ns=totals[JARBOX_CPU_JAVA];
                out->gc_ns=totals[JARBOX_CPU_GC];
                out->cpu_ok=1;
            }
            pthread_mutex_unlock(&bridge_cpu_lock);
        }
        jarbox_session_callback_done(session);
    }
    return count;
#else
    (void)detail;
    return -1;
#endif
}

int jvm_bridge_background_tokens(uint64_t *out,int capacity) {
    if (!out || capacity<=0) return 0;
    int count=0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    for (unsigned i=0;i<JARBOX_REGISTRY_MAX_SLOTS && count<capacity;++i) {
        JarBoxVMContext *slot=&g_bridge_slots[i];
        if (atomic_load_explicit(&slot->active,memory_order_acquire))
            out[count++]=atomic_load_explicit(&slot->token,memory_order_acquire);
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return count;
}
#if defined(__APPLE__) && __JVM_OS_IOS__
typedef struct { int entering; JarBoxBackgroundSample *out; } BridgeBackgroundSample;
static void bridge_background_sample_visitor(MiniJVM *vm,void *arg) {
    BridgeBackgroundSample *call=arg;
    JarBoxBackgroundSample *out=call->out;
    JarBoxSession *s=vm->session;
    uint64_t now=clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
    if (call->entering)
        out->trace_ok=jarbox_background_begin(&s->treo_state.background_trace,now);
    else
        out->trace_ok=jarbox_background_end(&s->treo_state.background_trace,now,&out->progress);
    pthread_mutex_lock(&bridge_cpu_lock);
    out->cpu=bridge_cpu_point(s);
    pthread_mutex_unlock(&bridge_cpu_lock);
    // Unlike the CPU mode history, this window spans device sleep and mode changes.
    out->cpu.wall_ns=now;
    out->gc_aborts=__atomic_load_n(&s->treo_state.gc_worker_aborts,__ATOMIC_RELAXED);
    out->mode=jarbox_treo_mode_get(&s->treo_state);
    out->family=jarbox_treo_nso_family_verified(&s->treo_state);
    out->canvas=jarbox_treo_nso_canvas_recognized(&s->treo_state);
}
#endif
int jvm_bridge_background_sample(uint64_t token,int entering,JarBoxBackgroundSample *out) {
    if (!out) return 0;
    memset(out,0,sizeof(*out));
#if defined(__APPLE__) && __JVM_OS_IOS__
    BridgeBackgroundSample call={entering,out};
    return jvm_bridge_visit_running_vm_for_token(token,bridge_background_sample_visitor,&call);
#else
    (void)token; (void)entering;
    return 0;
#endif
}

static void bridge_treo_snapshot(MiniJVM *vm, void *arg) {
    JarBoxTreoSnapshot *out = arg;
    JarBoxTreoState *s = &vm->session->treo_state;
    out->repaint_requests = __atomic_load_n(&s->nso_repaint_requests, __ATOMIC_RELAXED);
    out->repaint_skips = jarbox_treo_nso_skip_count(s, 0);
    out->service_skips = jarbox_treo_nso_skip_count(s, 1);
    out->paint_skips = jarbox_treo_nso_skip_count(s, 2);
    out->mode = jarbox_treo_mode_get(s);
    out->family = jarbox_treo_nso_family_verified(s);
    out->canvas = jarbox_treo_nso_canvas_recognized(s);
    out->int_leaf_fast_calls = __atomic_load_n(&s->int_leaf_fast_calls, __ATOMIC_RELAXED);
    out->ref_leaf_fast_calls = __atomic_load_n(&s->ref_leaf_fast_calls, __ATOMIC_RELAXED);
    out->aload_field_fusions = __atomic_load_n(&s->aload_field_fusions, __ATOMIC_RELAXED);
    out->gc_worker_cycles = __atomic_load_n(&s->gc_worker_cycles, __ATOMIC_RELAXED);
    out->gc_worker_aborts = __atomic_load_n(&s->gc_worker_aborts, __ATOMIC_RELAXED);
    out->gc_worker_cpu_ns = __atomic_load_n(&s->gc_worker_cpu_ns, __ATOMIC_RELAXED);
    out->smart_gc_cycles = __atomic_load_n(&s->smart_cycles, __ATOMIC_RELAXED);
    out->smart_gc_cpu_ns = __atomic_load_n(&s->smart_cpu_ns, __ATOMIC_RELAXED);
    out->smart_period_ms = jarbox_treo_smart_period(s);
    out->smart_fallback = __atomic_load_n(&s->smart_fallback, __ATOMIC_RELAXED);
}
int jvm_bridge_treo_snapshot_for_token(uint64_t token, JarBoxTreoSnapshot *out) {
    if (!out) return 0;
    memset(out, 0, sizeof(*out));
    return jvm_bridge_visit_running_vm_for_token(token, bridge_treo_snapshot, out);
}

static void bridge_status_heap_snapshot(MiniJVM *vm, void *arg) {
    if (!vm || !vm->collector) return;
    *(uint64_t *)arg = __atomic_load_n(
        &vm->collector->jarbox_status_heap_sample, __ATOMIC_ACQUIRE);
}

int jvm_bridge_status_heap_bytes_for_token(uint64_t token, uint64_t *out_bytes) {
    if (!out_bytes) return 0;
    *out_bytes = 0;
    uint64_t encoded = 0;
    if (!jvm_bridge_visit_running_vm_for_token(token, bridge_status_heap_snapshot, &encoded) ||
        !encoded) return 0;
    *out_bytes = encoded - 1;
    return 1;
}

void jvm_bridge_visit_running_vm(void (*visitor)(MiniJVM *, void *), void *arg) {
    (void)jvm_bridge_visit_running_vm_for_token(jvm_bridge_session_token(),
                                                visitor, arg);
}

int jvm_bridge_session_phase(void) {
    const uint64_t token = jvm_bridge_session_token();
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    const int phase = slot ? atomic_load_explicit(&slot->phase, memory_order_acquire) : BRIDGE_IDLE;
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return phase;
}
int jvm_bridge_session_is_active(void) {
    return jarbox_registry_active_count(&g_bridge_registry) != 0;
}
int jvm_bridge_session_is_active_for_token(uint64_t token) {
    return jarbox_registry_contains_token(&g_bridge_registry, token);
}
// Experimental memory-gated multi-session device build on loader-ios-jit-probe.
// Shared launches are 2D only; 3D/unknown archives remain exclusive.
// Runtime/device safety is NOT certified. The ceiling is not a promise of RAM.
int jvm_bridge_supported_concurrent_sessions(void) {
    return JARBOX_REGISTRY_MAX_SLOTS;
}
int jvm_bridge_active_session_count(void) {
    return jarbox_registry_active_count(&g_bridge_registry);
}
uint64_t jvm_bridge_session_token(void) {
    const uint64_t bound = jvm_bridge_thread_token();
    if (bound) return bound;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    uint64_t token = jarbox_focus_visible(&g_bridge_focus);
    if (!bridge_find_slot_locked(token)) {
        // When the sole game is parked, old diagnostics still target it.
        // With several parked games an owner-less query must fail closed.
        token = 0;
        for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
            JarBoxVMContext *slot = &g_bridge_slots[i];
            if (!atomic_load_explicit(&slot->active, memory_order_acquire)) continue;
            if (token) { token = 0; break; }
            token = atomic_load_explicit(&slot->token, memory_order_acquire);
        }
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return token;
}
int jvm_bridge_finish_session_for_token(uint64_t token) {
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    if (!bridge_slot_can_retire_locked(slot) ||
        !jarbox_registry_finish(&g_bridge_registry, &g_bridge_focus, token)) {
        pthread_mutex_unlock(&g_bridge_lifecycle_lock);
        printf("[JarBoxVM][Lifecycle] ERROR: live registry owner cannot retire\n");
        return 0;
    }
    bridge_diag_end(token);
    bridge_reset_slot_locked(slot);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    printf("[JarBoxVM][Lifecycle] session=released token=%llu\n",
           (unsigned long long)token);
    return 1;
}
void jvm_bridge_finish_session(void) {
    (void)jvm_bridge_finish_session_for_token(jvm_bridge_session_token());
}
int jvm_bridge_interrupt_active_threads_for_token(uint64_t token) {
    if (!token) return 0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    MiniJVM *owner = NULL;
    JarBoxSession *held = NULL;
    if (slot && atomic_load_explicit(&slot->stop_requested, memory_order_acquire) &&
        atomic_load_explicit(&slot->phase, memory_order_acquire) == BRIDGE_RUNNING) {
        MiniJVM *vm = atomic_load_explicit(&slot->jvm, memory_order_acquire);
        // A requested stop rejects ordinary registry visitors, but this
        // exact RUNNING owner may still need an interrupt. Teardown closes
        // the heap lease gate under the same lifecycle lock.
        if (vm && jarbox_session_reserve_callback(vm->session)) {
            owner = vm;
            held = vm->session;
        }
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (!owner) return 0;
    // Java monitor acquisition can block. Do not hold the process-wide
    // lifecycle lock; jvm_destroy must wait for this heap-access lease.
    // GC may be holding the Java thread-list lock while waiting for a
    // stalled worker to suspend. Request STOP without taking that lock.
    gc_request_thread_status(owner->collector, GARBAGE_THREAD_STOP);
    thread_stop_all(owner);
    jarbox_session_callback_done(held);
    printf("[JarBoxVM][Lifecycle] stop=escalated_java_threads token=%llu\n",
           (unsigned long long)token);
    return 1;
}
int jvm_bridge_interrupt_active_threads(void) {
    return jvm_bridge_interrupt_active_threads_for_token(jvm_bridge_session_token());
}

static void bridge_discard_unstarted_vm(JarBoxVMContext *slot) {
    // No MIDlet ran. Latch cancellation and skip normal Java shutdown hooks,
    // but retain the slot until jvm_destroy has drained every heap lease.
    atomic_store_explicit(&slot->stop_requested, 1, memory_order_release);
    slot->jvm->collector->exit_flag = 1;
    jvm_destroy(slot->jvm);
    jarbox_native_heap_unregister_key(slot->native_heap_key);
    slot->native_heap_key = 0;
    slot->jvm = NULL;
    if (jvm_bridge_supported_concurrent_sessions() == 1) {
        atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
        atomic_store_explicit(&treo_nso_init_target_active, 0, memory_order_release);
    }
}

static int bridge_init_slot(JarBoxVMContext *slot, const char *res_root, const char *save_root, const char *midlet_jar,
                    int screen_width, int screen_height, int render_3d_scale,
                    int fps_limit) {
    if (!atomic_load_explicit(&slot->active, memory_order_acquire) ||
        atomic_load_explicit(&slot->phase, memory_order_acquire) != BRIDGE_STARTING) {
        printf("[JarBoxVM][Lifecycle] init denied: no acquired session\n");
        return -5;
    }
    if (slot->jvm) {
        printf("[JVM Bridge] JVM already initialized\n");
        return -1;
    }
    // Cancellation before native allocation is cheap: the worker's
    // deferred finish will retire the still-empty slot.
    if (atomic_load_explicit(&slot->stop_requested, memory_order_acquire)) return -9;
    // These results belong to this archive, not the most recent launch.
    int ninja_match = 0, init_target = 0;
    unsigned ninja_core_profile = 0;
    if (jvm_bridge_supported_concurrent_sessions() == 1)
        treo_nso_probe_reset();
#if defined(TREO_IOS_GAME_JIT) && __JVM_OS_IOS__ && !defined(TREO_NINJA_DEEP_DISABLED)
    ninja_match = treo_is_nso_family(midlet_jar, &init_target);
#if defined(TREO_NINJA_CORE_EXPERIMENT) && TREO_NINJA_CORE_EXPERIMENT
    if (ninja_match) ninja_core_profile=treo_ninja_core_archive_profile(midlet_jar);
#endif
    printf("[JarBoxVM][NinjaDeep] profile=%s (NSO resource family)\n",
           ninja_match ? "matched" : "generic");
    // Historical mod probes only recognize one set of class signatures.
    // Zero does NOT mean that another NSO JAR failed to start.
    {
        char event[80];
        snprintf(event, sizeof(event), "vm_stage:legacy_mod_probe_match=%d",
                 init_target ? 1 : 0);
        jvm_bridge_note_net_trace(event);
    }
#endif
    // Archive recognition can be slow; recheck before creating the heap.
    if (atomic_load_explicit(&slot->stop_requested, memory_order_acquire)) return -9;
    // Keep legacy telemetry for the one-VM build only. These mirrors may
    // never be used as authorization for an independently running tab.
    if (jvm_bridge_supported_concurrent_sessions() == 1) {
        atomic_store_explicit(&treo_exact_ninja_verified, ninja_match, memory_order_release);
        atomic_store_explicit(&treo_nso_init_target_active, init_target, memory_order_release);
    }
    // Note: slot->stop_requested is NOT reset here — it is reset in
    // jvm_bridge_destroy() after the previous session.  Resetting it here
    // would race with backTapped() which may have already set the flag
    // before this function runs on the background thread.

    // Build bootclasspath: minijvm_rt.jar
    char bootclasspath[1024];
    snprintf(bootclasspath, sizeof(bootclasspath), "%s/minijvm_rt.jar", res_root);

    // Build classpath: j2me_api.jar + midlet JAR
    char classpath[4096];
    snprintf(classpath, sizeof(classpath), "%s/j2me_api.jar:%s",
             res_root, midlet_jar);

    printf("[JVM Bridge] bootclasspath: %s\n", bootclasspath);
    printf("[JVM Bridge] classpath: %s\n", classpath);

    // Recheck after archive recognition, immediately before allocating the
    // new heap. The worker's existing deferred finish retires an empty slot.
    if (jvm_bridge_memory_state(NULL) != 0) return -12;
    // Create JVM instance
    slot->jvm = jvm_create();
    if (!slot->jvm) {
        printf("[JVM Bridge] ERROR: jvm_create() failed\n");
        return -2;
    }
    (void)jarbox_session_bind_token(
        slot->jvm->session,
        atomic_load_explicit(&slot->token, memory_order_acquire));
    // Reserve a fresh generation BEFORE bootstrap creates Runtime/GC
    // workers. A matching address may still belong to a retiring VM.
    // No Java state exists yet, so a failed reservation frees only the
    // freshly allocated session and MiniJVM, never the old ledger entry.
    if (!jarbox_native_heap_register_vm(slot->jvm)) {
        MiniJVM *created = slot->jvm;
        jarbox_session_begin_stop(created->session);
        (void)jarbox_session_mark_dead(created->session);
        jarbox_session_release(created->session);
        slot->jvm = NULL;
        jvm_free(created);
        return -7;
    }
    slot->native_heap_key = jarbox_native_heap_key_for_vm(slot->jvm);
    // Copy the launch-only resource signature into this JVM before any
    // Java classes execute. Later launches cannot change this owner's NSO
    // recognition or give a foreign Canvas permission to use the fast path.
    jarbox_treo_nso_profile_set(&slot->jvm->session->treo_state,
        ninja_match, init_target);
    __atomic_store_n(&slot->jvm->session->treo_state.ninja_core.profile,ninja_core_profile,__ATOMIC_RELEASE);

    jarbox_session_configure_render_scale(slot->jvm->session, render_3d_scale);
    slot->jvm->jdwp_enable = 0;
    slot->jvm->jdwp_suspend_on_start = 0;
    slot->jvm->max_heap_size = 128 * 1024 * 1024;       // 128MB Java + this JVM's native graphics
    slot->jvm->garbage_collect_period_ms = 500;          // GC every 0.5 sec
    slot->jvm->heap_overload_percent = 70;               // GC at 70% heap

    s32 ret = jvm_init(slot->jvm, (c8 *)bootclasspath, (c8 *)classpath);
    if (ret) {
        printf("[JVM Bridge] ERROR: jvm_init() failed with code %d\n", ret);
        bridge_discard_unstarted_vm(slot);
        return -3;
    }
    // The Java core is initialized, but no MIDlet or native UI has started.
    // A queued cancel can retire now instead of registering more resources.
    if (atomic_load_explicit(&slot->stop_requested, memory_order_acquire)) {
        bridge_discard_unstarted_vm(slot);
        return -9;
    }
    // The registry retains an independently owned JarBoxSession reference
    // until DEAD; token/pointer reuse cannot expose a freed session.
    if (!jarbox_registry_bind(&g_bridge_registry,
            atomic_load_explicit(&slot->token, memory_order_acquire),
            slot->jvm->session)) {
        printf("[JarBoxVM][Lifecycle] failed to bind JVM registry owner\n");
        bridge_discard_unstarted_vm(slot);
        return -8;
    }

    // Acquire a distinct native input context before exposing the remaining
    // subsystem hooks. Never start a JVM with an unbound input destination.
    if (!j2me_input_reg_natives(slot->jvm)) {
        printf("[JarBoxVM][Lifecycle] cannot reserve independent input context\n");
        bridge_discard_unstarted_vm(slot);
        return -4;
    }
    if (!j2me_ui_reg_natives(slot->jvm)) {
        printf("[JarBoxVM][Lifecycle] cannot reserve independent LCDUI context\n");
        j2me_input_release_vm(slot->jvm);
        bridge_discard_unstarted_vm(slot);
        return -6;
    }
    j2me_render_reg_natives(slot->jvm);
    j2me_audio_reg_natives(slot->jvm);
    // With cap > 1 only an exclusive reservation may register legacy 3D.
    // A missed archive marker cannot grant a shared session a 3D backend.
    if (jarbox_legacy_3d_allowed((unsigned)jvm_bridge_supported_concurrent_sessions(),
                                slot->exclusive_3d)) {
        j2me_micro3d_gl_reg_natives(slot->jvm);
        j2me_m3g_reg_natives(slot->jvm);
        slot->legacy_3d_registered = 1;
    }

    // Set system properties
    sys_properties_set_c(slot->jvm, "os.name", "iOS");
    sys_properties_set_c(slot->jvm, "app.save.root", save_root);
    sys_properties_set_c(slot->jvm, "microedition.platform", "Apple/iPhone");
    sys_properties_set_c(slot->jvm, "microedition.encoding", "UTF-8");
    sys_properties_set_c(slot->jvm, "microedition.locale", "en");
    sys_properties_set_c(slot->jvm, "microedition.profiles", "MIDP-2.0");
    sys_properties_set_c(slot->jvm, "microedition.configuration", "CLDC-1.1");

    // Screen dimensions — used by Display.java to set canvas size
    char sw[16], sh[16];
    snprintf(sw, sizeof(sw), "%d", screen_width);
    snprintf(sh, sizeof(sh), "%d", screen_height);
    sys_properties_set_c(slot->jvm, "j2me.screen.width", sw);
    sys_properties_set_c(slot->jvm, "j2me.screen.height", sh);

    // 3D supersampling scale for M3G and MascotCapsule (1=native, 2=2x AA, 3=3x AA)
    char ss[8];
    snprintf(ss, sizeof(ss), "%d", jarbox_session_render_scale(slot->jvm->session));
    sys_properties_set_c(slot->jvm, "micro3d.v3.fbo.scale", ss);  // MC3D reads this in Render.java

    // FPS limit (0 = unlimited)
    if (fps_limit > 0) {
        char fl[8];
        snprintf(fl, sizeof(fl), "%d", fps_limit);
        sys_properties_set_c(slot->jvm, "j2me.fps.limit", fl);
    }
    printf("[JVM Bridge] Screen size: %dx%d, 3D render scale: %s, FPS limit: %d\n",
           screen_width, screen_height, ss, fps_limit);

    jvm_bridge_note_net_trace("vm_stage:core_initialized");
    printf("[JVM Bridge] JVM initialized successfully\n");
    return 0;
}

static int bridge_run_slot(JarBoxVMContext *slot, const char *midlet_jar_path) {
    if (!slot->jvm ||
        atomic_load_explicit(&slot->phase, memory_order_acquire) != BRIDGE_STARTING) {
        printf("[JVM Bridge] ERROR: JVM not initialized or already run\n");
        return -1;
    }

    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    const int cancelled = atomic_load_explicit(&slot->stop_requested, memory_order_acquire);
    if (!cancelled)
        atomic_store_explicit(&slot->phase, BRIDGE_RUNNING, memory_order_release);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (cancelled) {
        printf("[JarBoxVM][Lifecycle] MIDlet start cancelled before call_main\n");
        return -9;
    }
    if (slot->jvm && slot->jvm->session)
        (void)jarbox_session_enter_foreground(slot->jvm->session);
    jvm_bridge_note_net_trace("vm_stage:midlet_runner_enter");
    printf("[JVM Bridge] Running MIDlet from: %s\n", midlet_jar_path);

    ArrayList *java_para = arraylist_create(0);
    arraylist_push_back(java_para, (void *)midlet_jar_path);

    jvm_bridge_cpu_worker_begin(slot->jvm->session,JARBOX_CPU_RUNNER);
    jvm_bridge_cpu_mode_changed(slot->jvm->session);
    s32 ret = call_main(slot->jvm, (c8 *)"javax/microedition/shell/MIDletRunner", java_para);
    jvm_bridge_cpu_worker_end(slot->jvm->session);

    arraylist_destroy(java_para);

    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    atomic_store_explicit(&slot->phase, BRIDGE_CLEANUP, memory_order_release);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    {
        char event[96];
        snprintf(event, sizeof(event), "vm_stage:midlet_runner_exit:code=%d", ret);
        jvm_bridge_note_net_trace(event);
    }
    printf("[JVM Bridge] MIDlet finished with code %d\n", ret);
    return ret;
}

static void bridge_begin_slot_cleanup(JarBoxVMContext *slot) {
    // Wait for an already admitted focus/park to finish before closing
    // admission. Subsequent focus calls cannot pin a CLEANUP slot.
    pthread_mutex_lock(&g_bridge_focus_transition_lock);
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    atomic_store_explicit(&slot->phase, BRIDGE_CLEANUP, memory_order_release);
    jarbox_registry_begin_stop(&g_bridge_registry,
        atomic_load_explicit(&slot->token, memory_order_acquire));
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    pthread_mutex_unlock(&g_bridge_focus_transition_lock);
}

static void bridge_destroy_slot(JarBoxVMContext *slot) {
    bridge_begin_slot_cleanup(slot);
    if (slot->jvm) {
        // The heap ledger generation outlives the MiniJVM allocation and
        // prevents cleanup from mistaking a reused VM pointer for this one.
        const uint64_t destroyed_render_key = slot->native_heap_key;
        printf("[JVM Bridge] Destroying JVM\n");

        // Step 1: Revoke this JVM's right to publish pixels before stopping
        // native render calls. Delayed frames must never reach a later tab.
        j2me_render_release_vm(slot->jvm);
        // Stop only this JVM's native 2D handles. A different session's
        // frame generation must remain eligible to draw after A is stopped.
        j2me_render_stop_for_owner(destroyed_render_key);

        // Step 2: Signal JVM shutdown and stop all threads.
        // exit_flag makes jvm_destroy's non-daemon wait loop exit immediately;
        // thread_stop_all sets is_stop/is_interrupt on each thread.
        slot->jvm->collector->exit_flag = 1;
        jarbox_net_stop_owner(slot->jvm->session);
        gc_request_thread_status(slot->jvm->collector, GARBAGE_THREAD_STOP);
        thread_stop_all(slot->jvm);

        // Step 3: Revoke producers and wake Display, including any
        // late audio completion. Keep the ring reserved until worker drain.
        const uint64_t destroyed_token =
            atomic_load_explicit(&slot->token, memory_order_acquire);
        j2me_input_quiesce_vm(slot->jvm);

        // Step 4: Close only this JVM's audio players.
        j2me_audio_stop_for_vm(slot->jvm);

        // Step 5: jvm_destroy waits for all real native Java worker leases,
        // not just the Java ZOMBIE status. It retains the JVM heap if a
        // pthread is stuck and keeps the single-JVM gate occupied. The UI
        // already exposes an explicit process-exit recovery for stuck games.
        jvm_destroy(slot->jvm);
        // All Java input consumers and callback leases have drained.
        // Retire by immutable token, never by the freed JVM address.
        j2me_input_release_for_token(destroyed_token);
        // Retire the original LCDUI generation, not the freed JVM address.
        j2me_ui_release_for_owner(destroyed_render_key);
        slot->jvm = NULL;

        // Step 6: Clean up other native subsystems — safe because:
        // - the generation-scoped stop denies new render acquires for this VM
        // - jvm_destroy waited for the native worker and callback barrier
        // Input reset is no longer global; that JVM was released above.
        if (slot->legacy_3d_registered) {
            j2me_micro3d_gl_cleanup_for_owner(destroyed_render_key);
            j2me_m3g_cleanup();
            slot->legacy_3d_registered = 0;
        }
        j2me_render_cleanup_for_owner(destroyed_render_key); // only this VM's 2D handles
        // Keep the ledger reservation until all native cleanup completes.
        jarbox_native_heap_unregister_key(destroyed_render_key);
        slot->native_heap_key = 0;
        // Keep cancellation asserted until the owning Swift worker releases
        // the session. A late Back click must not bleed into the next launch.
        if (jvm_bridge_supported_concurrent_sessions() == 1) {
            atomic_store_explicit(&treo_exact_ninja_verified, 0, memory_order_release);
            atomic_store_explicit(&treo_nso_init_target_active, 0, memory_order_release);
        }

        printf("[JVM Bridge] JVM destroyed, native state cleaned up\n");
    }
}

int jvm_bridge_request_stop_for_token(uint64_t token) {
    if (!token) return 0;
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    const int matching = slot != NULL;
    JarBoxSession *held = NULL;
    MiniJVM *owner = NULL;
    if (slot) {
        // Pin before marking the registry STOPPING (which rejects new
        // callbacks). Wake this Display even when it is no longer visible.
        if (atomic_load_explicit(&slot->phase, memory_order_acquire) == BRIDGE_RUNNING)
            owner = (MiniJVM *)jarbox_registry_pin_vm(&g_bridge_registry, token, &held);
        atomic_store_explicit(&slot->stop_requested, 1, memory_order_release);
        (void)jarbox_registry_request_stop(&g_bridge_registry, token);
    }
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    if (owner) {
        unsigned sockets = jarbox_net_stop_owner(owner->session);
        printf("[JarBoxNET] stop_network token=%llu sockets=%u\n", (unsigned long long)token, sockets);
        j2me_input_quiesce_vm(owner);
        jarbox_session_callback_done(held);
    }
    if (matching)
        printf("[JarBoxVM][Lifecycle] stop_requested token=%llu\n",
               (unsigned long long)token);
    return matching;
}
void jvm_bridge_request_stop(void) {
    (void)jvm_bridge_request_stop_for_token(jvm_bridge_session_token());
}

int jvm_bridge_is_stop_requested_for_token(uint64_t token) {
    pthread_mutex_lock(&g_bridge_lifecycle_lock);
    JarBoxVMContext *slot = bridge_find_slot_locked(token);
    const int stop = !slot ||
        atomic_load_explicit(&slot->stop_requested, memory_order_acquire);
    pthread_mutex_unlock(&g_bridge_lifecycle_lock);
    return stop;
}
int jvm_bridge_is_stop_requested(void) {
    const uint64_t token = jvm_bridge_session_token();
    return token ? jvm_bridge_is_stop_requested_for_token(token) : 0;
}

/* The explicit worker owns a slot for the entire native operation.
 * A concurrent stale finish/destroy cannot recycle it underneath this call.
 * The legacy ABI delegates to the same token-based path. */
int jvm_bridge_init_for_token(uint64_t token,
        const char *res_root, const char *save_root, const char *midlet_jar,
        int screen_width, int screen_height, int render_3d_scale, int fps_limit) {
    JarBoxVMContext *slot = bridge_claim_worker(token);
    if (!slot) return -10;
    const uint64_t previous = jvm_bridge_push_java_thread_token(token);
    const int result = bridge_init_slot(slot, res_root, save_root, midlet_jar,
                                         screen_width, screen_height, render_3d_scale, fps_limit);
    jvm_bridge_pop_java_thread_token(previous);
    bridge_release_worker(slot);
    return result;
}
int jvm_bridge_init(const char *res_root, const char *save_root, const char *midlet_jar,
                    int screen_width, int screen_height, int render_3d_scale, int fps_limit) {
    return jvm_bridge_init_for_token(jvm_bridge_session_token(), res_root, save_root,
                                      midlet_jar, screen_width, screen_height, render_3d_scale, fps_limit);
}
int jvm_bridge_run_midlet_for_token(uint64_t token, const char *midlet_jar_path) {
    JarBoxVMContext *slot = bridge_claim_worker(token);
    if (!slot) return -10;
    const uint64_t previous = jvm_bridge_push_java_thread_token(token);
    const int result = bridge_run_slot(slot, midlet_jar_path);
    jvm_bridge_pop_java_thread_token(previous);
    bridge_release_worker(slot);
    return result;
}
int jvm_bridge_run_midlet(const char *midlet_jar_path) {
    return jvm_bridge_run_midlet_for_token(jvm_bridge_session_token(), midlet_jar_path);
}
int jvm_bridge_destroy_for_token(uint64_t token) {
    JarBoxVMContext *slot = bridge_claim_worker(token);
    if (!slot) return 0;
    const uint64_t previous = jvm_bridge_push_java_thread_token(token);
    bridge_destroy_slot(slot);
    jvm_bridge_pop_java_thread_token(previous);
    bridge_release_worker(slot);
    return 1;
}
void jvm_bridge_destroy(void) {
    (void)jvm_bridge_destroy_for_token(jvm_bridge_session_token());
}

// Java native polling must read the stop flag of the JVM that made the
// call, never another foreground game. An unbound/tearing-down JVM is
// instructed to stop instead of accidentally inheriting a later session.
int jvm_bridge_is_stop_requested_for_vm(const void *vm) {
    // jvm_init may query the native stop bridge before it has completed
    // classpath initialization and attached to the registry. Preserve the
    // old exact STARTING-owner behavior for this narrow pre-bind interval.
    // After binding, a foreign/stale pointer always fails closed.
    if (!vm) return 1;
    // Do not take the lifecycle mutex from a Java stop poll: the interrupt
    // watchdog can hold it while acquiring Java monitors. During STARTING,
    // compare only atomic identity fields; never dereference a slot's VM.
    for (unsigned i = 0; i < JARBOX_REGISTRY_MAX_SLOTS; ++i) {
        JarBoxVMContext *slot = &g_bridge_slots[i];
        const uint64_t token = atomic_load_explicit(&slot->token, memory_order_acquire);
        if (!token || !atomic_load_explicit(&slot->active, memory_order_acquire) ||
            atomic_load_explicit(&slot->phase, memory_order_acquire) != BRIDGE_STARTING ||
            atomic_load_explicit(&slot->jvm, memory_order_acquire) != vm) continue;
        const int stop = atomic_load_explicit(&slot->stop_requested, memory_order_acquire);
        if (atomic_load_explicit(&slot->token, memory_order_acquire) == token &&
            atomic_load_explicit(&slot->phase, memory_order_acquire) == BRIDGE_STARTING &&
            atomic_load_explicit(&slot->jvm, memory_order_acquire) == vm)
            return stop;
    }
    return jarbox_registry_should_stop_vm(&g_bridge_registry, vm);
}
