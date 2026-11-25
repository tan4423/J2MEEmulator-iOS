#ifndef JARBOX_PREPARED_CODE_CACHE_H
#define JARBOX_PREPARED_CODE_CACHE_H
/* Included only by class_load.c, after the VM type declarations.
 * Cache exact raw method bytes -> endian-converted bytes + integer branch
 * offsets. Never retain a MethodInfo, JClass, Pairlist, or runtime pointer.
 * All output buffers and labels remain private to the requesting method. */
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define JARBOX_PREPARED_MIN_CODE 128
#define JARBOX_PREPARED_MAX_CODE 16384
#define JARBOX_PREPARED_MAX_LABELS 2048
#define JARBOX_PREPARED_MAX_COUNT 2048u
#define JARBOX_PREPARED_BUDGET (4u * 1024u * 1024u)
#define JARBOX_PREPARED_BUCKETS 256u

typedef struct JarBoxPreparedCode {
    struct JarBoxPreparedCode *next;
    uint64_t hash;
    s32 length, labels;
    s32 offsets[]; // followed by exact raw bytes and converted bytes
} JarBoxPreparedCode;
static JarBoxPreparedCode *jarbox_prepared_buckets[JARBOX_PREPARED_BUCKETS];
static pthread_mutex_t jarbox_prepared_lock = PTHREAD_MUTEX_INITIALIZER;
static atomic_uint jarbox_prepared_epoch;
static atomic_int jarbox_prepared_trim_pending;
static size_t jarbox_prepared_bytes;
static unsigned jarbox_prepared_count;

static uint64_t jarbox_prepared_hash(const u8 *raw, s32 length) {
    if (!raw || length < JARBOX_PREPARED_MIN_CODE || length > JARBOX_PREPARED_MAX_CODE) return 0;
    // Sample only to select candidates; full memcmp is mandatory on hits.
    uint64_t h = UINT64_C(14695981039346656037) ^ (uint64_t)length;
    for (unsigned i = 0; i < 16; ++i)
        h = (h ^ raw[(size_t)i * (size_t)(length - 1) / 15]) * UINT64_C(1099511628211);
    return h ? h : 1;
}
static const u8 *jarbox_prepared_raw(const JarBoxPreparedCode *entry) {
    return (const u8 *)(entry->offsets + entry->labels);
}
static JarBoxPreparedCode *jarbox_prepared_find(uint64_t hash, const u8 *raw, s32 length) {
    for (JarBoxPreparedCode *e = jarbox_prepared_buckets[hash % JARBOX_PREPARED_BUCKETS]; e; e = e->next)
        if (e->hash == hash && e->length == length && !memcmp(jarbox_prepared_raw(e), raw, (size_t)length)) return e;
    return NULL;
}
static void jarbox_prepared_trim_locked(void) {
    if (!atomic_exchange(&jarbox_prepared_trim_pending, 0)) return;
    for (unsigned i = 0; i < JARBOX_PREPARED_BUCKETS; ++i) {
        JarBoxPreparedCode *e = jarbox_prepared_buckets[i];
        while (e) { JarBoxPreparedCode *next = e->next; free(e); e = next; }
        jarbox_prepared_buckets[i] = NULL;
    }
    jarbox_prepared_count = 0;
    jarbox_prepared_bytes = 0;
}
static void jarbox_prepared_trim(void) {
    atomic_fetch_add(&jarbox_prepared_epoch, 1);
    atomic_store(&jarbox_prepared_trim_pending, 1);
    if (pthread_mutex_trylock(&jarbox_prepared_lock) == 0) {
        jarbox_prepared_trim_locked();
        pthread_mutex_unlock(&jarbox_prepared_lock);
    }
}
static int jarbox_prepared_lookup(MethodInfo *method, uint64_t hash, unsigned epoch) {
    if (!hash || !method->pos_2_label || pthread_mutex_trylock(&jarbox_prepared_lock) != 0) return 0;
    jarbox_prepared_trim_locked();
    CodeAttribute *ca = method->converted_code;
    JarBoxPreparedCode *e = epoch == atomic_load(&jarbox_prepared_epoch) ?
        jarbox_prepared_find(hash, ca->code, ca->code_length) : NULL;
    int hit = 0;
    if (e) {
        Pairlist *labels = method->pos_2_label;
        if (labels->_alloced < e->labels) {
            Pairlist *larger = pairlist_create(e->labels);
            if (larger) { pairlist_destroy(labels); method->pos_2_label = labels = larger; }
        }
        if (labels->_alloced >= e->labels) {
            for (s32 i = 0; i < e->labels; ++i) {
                labels->ptr[i].leftl = e->offsets[i];
                labels->ptr[i].rightl = -1;
            }
            labels->count = e->labels;
            memcpy(ca->code, jarbox_prepared_raw(e) + e->length, (size_t)e->length);
            hit = 1;
        }
    }
    jarbox_prepared_trim_locked();
    pthread_mutex_unlock(&jarbox_prepared_lock);
    return hit;
}
static void jarbox_prepared_publish(MethodInfo *method, uint64_t hash, unsigned epoch) {
    if (!hash || !method->pos_2_label || epoch != atomic_load(&jarbox_prepared_epoch)) return;
    CodeAttribute *ca = method->converted_code;
    Pairlist *labels = method->pos_2_label;
    if (ca->code_length < JARBOX_PREPARED_MIN_CODE || ca->code_length > JARBOX_PREPARED_MAX_CODE ||
        labels->count < 0 || labels->count > JARBOX_PREPARED_MAX_LABELS) return;
    for (s32 i = 0; i < labels->count; ++i)
        if (labels->ptr[i].rightl != -1 || labels->ptr[i].leftl < 0 || labels->ptr[i].leftl > ca->code_length) return;
    const size_t cost = sizeof(JarBoxPreparedCode) + (size_t)labels->count * sizeof(s32) + (size_t)ca->code_length * 2;
    if (pthread_mutex_trylock(&jarbox_prepared_lock) != 0) return;
    jarbox_prepared_trim_locked();
    if (epoch == atomic_load(&jarbox_prepared_epoch) && jarbox_prepared_count < JARBOX_PREPARED_MAX_COUNT &&
        cost <= JARBOX_PREPARED_BUDGET - jarbox_prepared_bytes &&
        !jarbox_prepared_find(hash, ca->bytecode_for_jit, ca->code_length)) {
        JarBoxPreparedCode *e = malloc(cost);
        if (e) {
            e->hash = hash; e->length = ca->code_length; e->labels = labels->count;
            for (s32 i = 0; i < e->labels; ++i) e->offsets[i] = (s32)labels->ptr[i].leftl;
            u8 *raw = (u8 *)(e->offsets + e->labels);
            memcpy(raw, ca->bytecode_for_jit, (size_t)e->length);
            memcpy(raw + e->length, ca->code, (size_t)e->length);
            unsigned bucket = hash % JARBOX_PREPARED_BUCKETS;
            e->next = jarbox_prepared_buckets[bucket]; jarbox_prepared_buckets[bucket] = e;
            jarbox_prepared_bytes += cost; ++jarbox_prepared_count;
        }
    }
    jarbox_prepared_trim_locked();
    pthread_mutex_unlock(&jarbox_prepared_lock);
}
#endif
