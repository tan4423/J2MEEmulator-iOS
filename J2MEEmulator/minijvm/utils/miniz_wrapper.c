#include "miniz.h"
#include "miniz_wrapper.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#if defined(__APPLE__) || defined(__linux__)
#include <pthread.h>
#include <sys/stat.h>
#include <stdatomic.h>
#endif

/*
 * Java archive entry names are case-sensitive. Obfuscated MIDlets commonly
 * contain distinct a.class/A.class (and similar) entries. Resolve once, then
 * extract by index so a second case-insensitive lookup cannot change identity.
 * Exact lookup is linear in miniz, so skip its unused case-folded sort on
 * each short-lived read-only archive. Do not change ZIP writer behavior.
 */
static int jarbox_zip_find_entry(mz_zip_archive *archive, const char *jarpath,
                                 const char *filename, mz_zip_archive_file_stat *stat) {
    if (!jarpath || !filename) return -1;
    if (filename[0] == '/') filename++;
    if (mz_zip_reader_init_file(archive, jarpath,
                                MZ_ZIP_FLAG_DO_NOT_SORT_CENTRAL_DIRECTORY) == MZ_FALSE) {
        return -1;
    }
    int index = mz_zip_reader_locate_file(archive, filename, NULL,
                                          MZ_ZIP_FLAG_CASE_SENSITIVE);
    if (index < 0 || !mz_zip_reader_file_stat(archive, (mz_uint) index, stat)) {
        mz_zip_reader_end(archive);
        return -1;
    }
    return index;
}

s32 zip_loadfile(char const *jarpath, char const *filename, ByteBuf *buf) {
    if (!buf) return -1;
    mz_zip_archive archive = {0};
    mz_zip_archive_file_stat stat = {0};
    int index = jarbox_zip_find_entry(&archive, jarpath, filename, &stat);
    if (index < 0) return -1;
    s32 ret = -1;
    /* ByteBuf and the Java byte-array API cannot represent larger entries. */
    if (stat.m_uncomp_size <= INT32_MAX) {
        u32 size = (u32) stat.m_uncomp_size;
        if (size > buf->_alloc_size) bytebuf_expand(buf, size);
        /* bytebuf_expand leaves the old allocation intact on failure. */
        if (buf->buf && size <= buf->_alloc_size &&
            mz_zip_reader_extract_to_mem(&archive, (mz_uint) index, buf->buf, size, 0)) {
            buf->rp = 0;
            buf->wp = size;
            ret = 0;
        }
    }
    mz_zip_reader_end(&archive);
    return ret;
}

s32 zip_loadfile_to_mem(char const *jarpath, char const *filename, c8 *buf, s64 bufsize) {
    if (bufsize < 0 || (uint64_t) bufsize > SIZE_MAX || (!buf && bufsize != 0)) return -1;
    mz_zip_archive archive = {0};
    mz_zip_archive_file_stat stat = {0};
    int index = jarbox_zip_find_entry(&archive, jarpath, filename, &stat);
    if (index < 0) return -1;
    s32 ret = -1;
    if (stat.m_uncomp_size <= (uint64_t) bufsize &&
        mz_zip_reader_extract_to_mem(&archive, (mz_uint) index, buf, (size_t) bufsize, 0)) {
        ret = 0;
    }
    mz_zip_reader_end(&archive);
    return ret;
}

s64 zip_get_file_unzip_size(char const *jarpath, char const *filename) {
    mz_zip_archive archive = {0};
    mz_zip_archive_file_stat stat = {0};
    int index = jarbox_zip_find_entry(&archive, jarpath, filename, &stat);
    if (index < 0) return -1;
    s64 size = stat.m_uncomp_size <= INT32_MAX ? (s64) stat.m_uncomp_size : -1;
    mz_zip_reader_end(&archive);
    return size;
}

s32 zip_get_file_index(char const *jarpath, char const *filename) {
    mz_zip_archive archive = {0};
    mz_zip_archive_file_stat stat = {0};
    int index = jarbox_zip_find_entry(&archive, jarpath, filename, &stat);
    if (index >= 0) mz_zip_reader_end(&archive);
    return index;
}


/* Classpath-only reader and immutable entry-byte reuse. The cached bytes
 * are never handed to a JVM directly. Every lookup returns a private copy.
 * Four process-wide slots bound file descriptors and retained memory even
 * with 64 VMs. Try-lock fallback avoids blocking another VM's class load.
 * Keep the ordinary ZIP APIs and writer path uncached.
 */
#if defined(__APPLE__) || defined(__linux__)
#define JARBOX_CLASSPATH_CACHE_SLOTS 4
#define JARBOX_CLASSPATH_CACHE_MAX_BYTES (8 * 1024 * 1024)
// Process-wide budget includes entry headers, names and decompressed bytes.
// Reader metadata remains separately bounded by the existing reader limits.
#define JARBOX_CLASSPATH_DATA_BUDGET (6u * 1024u * 1024u)
#define JARBOX_CLASSPATH_DATA_MAX_ENTRY (256u * 1024u)
#define JARBOX_CLASSPATH_DATA_MAX_COUNT 2048u
#define JARBOX_CLASSPATH_DATA_BUCKETS 256u
// Keep misses separate from useful byte entries: one bad resource probe
// cannot evict or consume the existing 6 MiB positive cache budget.
#define JARBOX_CLASSPATH_MISS_BUDGET (128u * 1024u)
#define JARBOX_CLASSPATH_MISS_MAX_COUNT 2048u
typedef struct JarBoxClasspathMiss {
    struct JarBoxClasspathMiss *next;
    size_t cost;
    char name[];
} JarBoxClasspathMiss;
static size_t jarbox_classpath_miss_bytes;
static unsigned jarbox_classpath_miss_count;
typedef struct JarBoxClasspathData {
    struct JarBoxClasspathData *next;
    size_t name_bytes;
    u32 size;
    char payload[]; // exact entry name including NUL, then immutable bytes
} JarBoxClasspathData;
static size_t jarbox_classpath_data_bytes;
static unsigned jarbox_classpath_data_count;
// Optional exact-name index; immutable archive metadata only. A separate
// 512 KiB per-reader cap limits four readers to 2 MiB extra.
#define JARBOX_NAME_INDEX_BUDGET (512u * 1024u)
typedef struct {
    uint32_t hash, ordinal, offset;
} JarBoxNameEntry;
typedef struct {
    JarBoxNameEntry *entries;
    char *names;
    unsigned count;
} JarBoxNameIndex;

static uint32_t jarbox_name_hash(const char *name) {
    uint32_t h=2166136261u;
    for (; *name; ++name) h=(h^(unsigned char)*name)*16777619u;
    return h;
}
static int jarbox_name_compare(const void *a,const void *b) {
    const JarBoxNameEntry *x=a,*y=b;
    if (x->hash != y->hash) return x->hash < y->hash ? -1 : 1;
    return (x->ordinal > y->ordinal) - (x->ordinal < y->ordinal);
}
static void jarbox_name_index_clear(JarBoxNameIndex *index) {
    free(index->entries);
    free(index->names);
    memset(index,0,sizeof(*index));
}
static void jarbox_name_index_build(JarBoxNameIndex *index,mz_zip_archive *archive) {
    const unsigned count=mz_zip_reader_get_num_files(archive);
    if (count<32 || count>20000 || count>JARBOX_NAME_INDEX_BUDGET/sizeof(JarBoxNameEntry)) return;
    size_t remaining=JARBOX_NAME_INDEX_BUDGET-count*sizeof(JarBoxNameEntry);
    size_t bytes=0;
    for (unsigned i=0;i<count;++i) {
        unsigned n=mz_zip_reader_get_filename(archive,i,NULL,0);
        if (!n || n>remaining-bytes) return;
        bytes+=n;
    }
    JarBoxNameEntry *entries=malloc(count*sizeof(*entries));
    char *names=malloc(bytes);
    if (!entries || !names) { free(entries); free(names); return; }
    size_t offset=0;
    for (unsigned i=0;i<count;++i) {
        unsigned n=mz_zip_reader_get_filename(archive,i,NULL,0);
        if (!n || n>bytes-offset ||
            mz_zip_reader_get_filename(archive,i,names+offset,n)!=n ||
            memchr(names+offset,0,n-1)!=NULL || names[offset+n-1]!=0) {
            free(entries); free(names); return;
        }
        entries[i]=(JarBoxNameEntry){jarbox_name_hash(names+offset),i,(uint32_t)offset};
        offset+=n;
    }
    qsort(entries,count,sizeof(*entries),jarbox_name_compare);
    index->entries=entries;
    index->names=names;
    index->count=count;
}
// -2 means no index (or unsupported name); -1 means definite absence.
// Hash collisions require byte equality; identical names choose the original
// first archive ordinal, matching miniz's case-sensitive linear scan.
static int jarbox_name_index_find(const JarBoxNameIndex *index,const char *name) {
    if (!index->count || strlen(name)>UINT16_MAX) return -2;
    uint32_t hash=jarbox_name_hash(name);
    unsigned lo=0,hi=index->count;
    while (lo<hi) {
        unsigned mid=lo+(hi-lo)/2;
        if (index->entries[mid].hash<hash) lo=mid+1; else hi=mid;
    }
    for (;lo<index->count && index->entries[lo].hash==hash;++lo) {
        const JarBoxNameEntry *entry=&index->entries[lo];
        if (!strcmp(index->names+entry->offset,name)) return (int)entry->ordinal;
    }
    return -1;
}

typedef struct {
    char *path;
    struct stat identity;
    uint64_t last_used;
    mz_zip_archive archive;
    JarBoxNameIndex names;
    JarBoxClasspathData *data[JARBOX_CLASSPATH_DATA_BUCKETS];
    JarBoxClasspathMiss *misses[JARBOX_CLASSPATH_DATA_BUCKETS];
} JarBoxClasspathReader;
static JarBoxClasspathReader jarbox_classpath_cache[JARBOX_CLASSPATH_CACHE_SLOTS];
static uint64_t jarbox_classpath_clock;
static pthread_mutex_t jarbox_classpath_lock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int jarbox_classpath_trim_pending;

static int jarbox_classpath_same_file(const struct stat *a, const struct stat *b) {
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
// All entry cache operations are protected by the existing reader lock.
// Hashing is only a bucket selection; strcmp establishes exact identity.
static unsigned jarbox_classpath_data_bucket(const char *entry) {
    uint32_t hash = 2166136261u;
    for (const unsigned char *p = (const unsigned char *)entry; *p; ++p)
        hash = (hash ^ *p) * 16777619u;
    return hash % JARBOX_CLASSPATH_DATA_BUCKETS;
}
// Exact-case negative entries belong to a single validated archive identity.
// Only miniz's definitive FILE_NOT_FOUND result is eligible.
static int jarbox_classpath_miss_find(const JarBoxClasspathReader *reader,
                                      const char *entry) {
    for (JarBoxClasspathMiss *item = reader->misses[jarbox_classpath_data_bucket(entry)];
         item; item = item->next) {
        if (strcmp(item->name, entry) == 0) return 1;
    }
    return 0;
}
static void jarbox_classpath_miss_add(JarBoxClasspathReader *reader, const char *entry) {
    size_t len = strlen(entry) + 1;
    if (len > 1024 || jarbox_classpath_miss_count >= JARBOX_CLASSPATH_MISS_MAX_COUNT)
        return;
    size_t cost = sizeof(JarBoxClasspathMiss) + len;
    if (cost > JARBOX_CLASSPATH_MISS_BUDGET - jarbox_classpath_miss_bytes)
        return;
    JarBoxClasspathMiss *item = malloc(cost);
    if (!item) return;
    item->cost = cost;
    memcpy(item->name, entry, len);
    unsigned bucket = jarbox_classpath_data_bucket(entry);
    item->next = reader->misses[bucket];
    reader->misses[bucket] = item;
    jarbox_classpath_miss_bytes += cost;
    ++jarbox_classpath_miss_count;
}
static void jarbox_classpath_miss_clear(JarBoxClasspathReader *reader) {
    for (unsigned n = 0; n < JARBOX_CLASSPATH_DATA_BUCKETS; ++n) {
        JarBoxClasspathMiss *item = reader->misses[n];
        while (item) {
            JarBoxClasspathMiss *next = item->next;
            jarbox_classpath_miss_bytes -= item->cost;
            --jarbox_classpath_miss_count;
            free(item);
            item = next;
        }
        reader->misses[n] = NULL;
    }
}
static JarBoxClasspathData *jarbox_classpath_data_find(JarBoxClasspathReader *reader,
                                                      const char *entry) {
    for (JarBoxClasspathData *item = reader->data[jarbox_classpath_data_bucket(entry)];
         item; item = item->next) {
        if (strcmp(item->payload, entry) == 0) return item;
    }
    return NULL;
}
static void jarbox_classpath_data_add(JarBoxClasspathReader *reader, const char *entry,
                                      const ByteBuf *buf) {
    if (!buf->buf || !buf->wp || buf->wp > JARBOX_CLASSPATH_DATA_MAX_ENTRY ||
        jarbox_classpath_data_count >= JARBOX_CLASSPATH_DATA_MAX_COUNT)
        return;
    size_t name_bytes = strlen(entry) + 1;
    if (name_bytes > 1024) return;
    size_t cost = sizeof(JarBoxClasspathData) + name_bytes + buf->wp;
    if (cost > JARBOX_CLASSPATH_DATA_BUDGET - jarbox_classpath_data_bytes)
        return;
    JarBoxClasspathData *item = malloc(cost);
    if (!item) return;
    item->name_bytes = name_bytes;
    item->size = buf->wp;
    memcpy(item->payload, entry, name_bytes);
    memcpy(item->payload + name_bytes, buf->buf, item->size);
    unsigned bucket = jarbox_classpath_data_bucket(entry);
    item->next = reader->data[bucket];
    reader->data[bucket] = item;
    jarbox_classpath_data_bytes += cost;
    ++jarbox_classpath_data_count;
}
static s32 jarbox_classpath_data_copy(const JarBoxClasspathData *item, ByteBuf *buf) {
    if (item->size > buf->_alloc_size) bytebuf_expand(buf, item->size);
    if (!buf->buf || item->size > buf->_alloc_size) return -1;
    memcpy(buf->buf, item->payload + item->name_bytes, item->size);
    buf->rp = 0;
    buf->wp = item->size;
    return 0;
}
static void jarbox_classpath_data_clear(JarBoxClasspathReader *reader) {
    for (unsigned n = 0; n < JARBOX_CLASSPATH_DATA_BUCKETS; ++n) {
        JarBoxClasspathData *item = reader->data[n];
        while (item) {
            JarBoxClasspathData *next = item->next;
            jarbox_classpath_data_bytes -= sizeof(*item) + item->name_bytes + item->size;
            --jarbox_classpath_data_count;
            free(item);
            item = next;
        }
        reader->data[n] = NULL;
    }
}
static void jarbox_classpath_close(JarBoxClasspathReader *reader) {
    jarbox_name_index_clear(&reader->names);
    jarbox_classpath_data_clear(reader);
    jarbox_classpath_miss_clear(reader);
    if (reader->path) {
        mz_zip_reader_end(&reader->archive);
        free(reader->path);
    }
    memset(reader, 0, sizeof(*reader));
}
/* All reader recency updates happen under jarbox_classpath_lock. On an
 * empty slot prefer admission; otherwise evict the least recently used
 * archive, not a hot boot/API reader just because its turn came around. */
static JarBoxClasspathReader *jarbox_classpath_victim(void) {
    JarBoxClasspathReader *victim = &jarbox_classpath_cache[0];
    for (unsigned n = 0; n < JARBOX_CLASSPATH_CACHE_SLOTS; ++n) {
        JarBoxClasspathReader *candidate = &jarbox_classpath_cache[n];
        if (!candidate->path) return candidate;
        if (candidate->last_used < victim->last_used) victim = candidate;
    }
    return victim;
}
static void jarbox_classpath_touch(JarBoxClasspathReader *reader) {
    if (++jarbox_classpath_clock == 0) {
        // Counter wrap affects only eviction preference, never identity.
        for (unsigned n = 0; n < JARBOX_CLASSPATH_CACHE_SLOTS; ++n)
            jarbox_classpath_cache[n].last_used = 0;
        jarbox_classpath_clock = 1;
    }
    reader->last_used = jarbox_classpath_clock;
}

static void jarbox_classpath_trim_locked(void) {
    if (atomic_exchange(&jarbox_classpath_trim_pending, 0)) {
        for (unsigned i = 0; i < JARBOX_CLASSPATH_CACHE_SLOTS; ++i)
            jarbox_classpath_close(&jarbox_classpath_cache[i]);
        jarbox_classpath_clock = 0;
    }
}
void zip_classpath_cache_trim(void) {
    atomic_store(&jarbox_classpath_trim_pending, 1);
    if (pthread_mutex_trylock(&jarbox_classpath_lock) == 0) {
        jarbox_classpath_trim_locked();
        pthread_mutex_unlock(&jarbox_classpath_lock);
    }
}

s32 zip_classpath_loadfile_profiled(const char *jarpath, const char *filename, ByteBuf *buf, int *hit_kind) {
    if (hit_kind) *hit_kind = 0;
    if (!jarpath || !filename || !buf) return -1;
    if (pthread_mutex_trylock(&jarbox_classpath_lock) != 0)
        return zip_loadfile(jarpath, filename, buf);
    jarbox_classpath_trim_locked();

    struct stat before, after;
    JarBoxClasspathReader *reader = NULL;
    int fallback = 1;
    s32 ret = -1;
    if (stat(jarpath, &before) != 0 || !S_ISREG(before.st_mode) ||
        before.st_size <= 0 || before.st_size > JARBOX_CLASSPATH_CACHE_MAX_BYTES)
        goto done;

    for (unsigned n = 0; n < JARBOX_CLASSPATH_CACHE_SLOTS; ++n) {
        JarBoxClasspathReader *candidate = &jarbox_classpath_cache[n];
        if (candidate->path && strcmp(candidate->path, jarpath) == 0) {
            if (jarbox_classpath_same_file(&candidate->identity, &before)) {
                reader = candidate;
            } else {
                jarbox_classpath_close(candidate);
            }
            break;
        }
    }
    if (!reader) {
        reader = jarbox_classpath_victim();
        jarbox_classpath_close(reader);
        size_t len = strlen(jarpath) + 1;
        char *copy = malloc(len);
        if (!copy) goto done;
        memcpy(copy, jarpath, len);
        if (!mz_zip_reader_init_file(&reader->archive, jarpath,
                                    MZ_ZIP_FLAG_DO_NOT_SORT_CENTRAL_DIRECTORY)) {
            free(copy);
            memset(reader, 0, sizeof(*reader));
            goto done;
        }
        reader->path = copy;
        reader->identity = before;
        if (mz_zip_reader_get_num_files(&reader->archive) > 20000 ||
            stat(jarpath, &after) != 0 || !jarbox_classpath_same_file(&before, &after)) {
            jarbox_classpath_close(reader);
            goto done;
        }
        jarbox_name_index_build(&reader->names,&reader->archive);
    }

    // Cache hits avoid both the ZIP name lookup and decompression. A
    // private caller buffer is required because class parsing may mutate it.
    const char *entry = filename[0] == '/' ? filename + 1 : filename;
    JarBoxClasspathData *cached = jarbox_classpath_data_find(reader, entry);
    int definitive_miss = 0;
    int cached_miss = 0;
    if (cached) {
        ret = jarbox_classpath_data_copy(cached, buf);
    } else if ((cached_miss = jarbox_classpath_miss_find(reader, entry)) == 0) {
        int index = jarbox_name_index_find(&reader->names,entry);
        if (index == -2) {
            index = mz_zip_reader_locate_file(&reader->archive, entry, NULL,
                                             MZ_ZIP_FLAG_CASE_SENSITIVE);
            if (index < 0)
                definitive_miss = mz_zip_get_last_error(&reader->archive) == MZ_ZIP_FILE_NOT_FOUND;
        } else if (index == -1) definitive_miss = 1;
        mz_zip_archive_file_stat info = {0};
        if (index >= 0 && mz_zip_reader_file_stat(&reader->archive, (mz_uint)index, &info) &&
            info.m_uncomp_size <= INT32_MAX) {
            u32 size = (u32)info.m_uncomp_size;
            if (size > buf->_alloc_size) bytebuf_expand(buf, size);
            if (buf->buf && size <= buf->_alloc_size &&
                mz_zip_reader_extract_to_mem(&reader->archive, (mz_uint)index, buf->buf, size, 0)) {
                buf->rp = 0;
                buf->wp = size;
                ret = 0;
            }
        }
    }
    // A rename or rewrite during the read must not return stale class bytes.
    if (stat(jarpath, &after) != 0 || !jarbox_classpath_same_file(&before, &after)) {
        jarbox_classpath_close(reader);
        goto done;
    }
    // Publish only after rechecking the archive identity. Cache allocation
    // failure or budget exhaustion must not affect the caller's result.
    if (!cached && ret == 0) jarbox_classpath_data_add(reader, entry, buf);
    if (definitive_miss) jarbox_classpath_miss_add(reader, entry);
    jarbox_classpath_touch(reader);
    // Only count validated cache results, not an unsuccessful copy or a
    // stale archive that needs the uncached fallback.
    if (hit_kind) {
        if (cached && ret == 0) *hit_kind = 1;
        else if (cached_miss) *hit_kind = 2;
    }
    fallback = 0;
done:
    jarbox_classpath_trim_locked();
    pthread_mutex_unlock(&jarbox_classpath_lock);
    return fallback ? zip_loadfile(jarpath, filename, buf) : ret;
}
#else
void zip_classpath_cache_trim(void) {}
s32 zip_classpath_loadfile_profiled(const char *jarpath, const char *filename, ByteBuf *buf, int *hit_kind) {
    if (hit_kind) *hit_kind = 0;
    return zip_loadfile(jarpath, filename, buf);
}
#endif

s32 zip_classpath_loadfile(const char *jarpath, const char *filename, ByteBuf *buf) {
    return zip_classpath_loadfile_profiled(jarpath, filename, buf, NULL);
}

s32 zip_savefile_mem(char const *jarpath, char const *filename, char const *buf, int size) {
    int file_index = 0;
    mz_zip_archive zipArchive = {0};
    mz_zip_archive_file_stat file_stat = {0};

    //skit the first '/'
    if (filename && filename[0] == '/') {
        filename += 1;
    }

    int ret = 0;
    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {//
        if (mz_zip_writer_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {//
            ret = -1;
        }
    } else {
        if (mz_zip_writer_init_from_reader(&zipArchive, jarpath) == MZ_FALSE) {//
            ret = -1;
        }
    }
    if (ret == 0) {
        if (mz_zip_writer_add_mem(&zipArchive, filename, buf, size, MZ_DEFAULT_COMPRESSION) == MZ_FALSE) {//
            ret = -1;
        }
        if (mz_zip_writer_finalize_archive(&zipArchive) == MZ_FALSE) {//
            ret = -1;
        }
        mz_zip_writer_end(&zipArchive);
    }
    return ret;
}


s32 zip_savefile(char const *jarpath, char const *filename, ByteBuf *buf) {
    return zip_savefile_mem(jarpath, filename, buf->buf, buf->wp);
}

s32 zip_filecount(char *jarpath) {
    int file_index = 0;
    mz_zip_archive zipArchive = {0};
    mz_zip_archive_file_stat file_stat = {0};

    int ret = 0;
    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {//
        ret = -1;
    } else {
        ret = mz_zip_reader_get_num_files(&zipArchive);
        mz_zip_reader_end(&zipArchive);
    }
    return ret;
}

ArrayList *zip_get_filenames(char *jarpath) {
    mz_zip_archive zipArchive = {0};

    ArrayList *list = arraylist_create(0);
    int ret = 0;
    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {//
        ret = -1;
    } else {
        int count = mz_zip_reader_get_num_files(&zipArchive);
        int i;
        for (i = 0; i < count; i++) {
            char buf[1024];
            mz_uint requiremore = mz_zip_reader_get_filename(&zipArchive, i, buf, 1024);
            if (strlen(buf)) {
                Utf8String *ustr = utf8_create_c(buf);
                arraylist_push_back_unsafe(list, ustr);
            }
        }

        mz_zip_reader_end(&zipArchive);
    }
    return list;
}

void zip_destroy_filenames_list(ArrayList *list) {
    s32 i;
    for (i = 0; i < list->length; i++) {
        Utf8String *ustr = arraylist_get_value_unsafe(list, i);
        if (ustr) {
            utf8_destroy(ustr);
        }
    }
    arraylist_destroy(list);
}

s32 zip_is_directory(char *jarpath, int index) {
    mz_zip_archive zipArchive = {0};

    int ret = -1;
    if (mz_zip_reader_init_file(&zipArchive, jarpath, 0) == MZ_FALSE) {//
        ret = -1;
    } else {

        ret = mz_zip_reader_is_file_a_directory(&zipArchive, index);
        mz_zip_reader_end(&zipArchive);
    }
    return ret;
}

s32 zip_extract(char *zip_data, int size, ByteBuf *data) {
    if (!zip_data || size <= 0 || !data || !data->buf) return -1;
    mz_zip_archive zipArchive = {0};
    mz_zip_archive_file_stat file_stat = {0};
    int ret = 0;
    if (mz_zip_reader_init_mem(&zipArchive, zip_data, size, 0) == MZ_FALSE) {//
        ret = -1;
    } else {
        if (!mz_zip_reader_file_stat(&zipArchive, 0, &file_stat)) {
            ret = -1;
        } else {
            ret = -1;
            if (file_stat.m_uncomp_size <= INT32_MAX) {
                const u32 uncompressed_size = (u32)file_stat.m_uncomp_size;
                if (uncompressed_size > data->_alloc_size)
                    bytebuf_expand(data, uncompressed_size);
                // Growth can fail. Never hand miniz a larger capacity than
                // the actual allocation, even on the non-classpath path.
                if (uncompressed_size <= data->_alloc_size &&
                    mz_zip_reader_extract_to_mem(&zipArchive, 0, data->buf, uncompressed_size, 0)) {
                    data->rp = 0;
                    data->wp = uncompressed_size;
                    ret = 0;
                }
            }
        }
        mz_zip_reader_end(&zipArchive);
    }
    return ret;
}

s32 zip_compress(char *data, int size, ByteBuf *zip_data) {
    if (size < 0 || (size && !data) || !zip_data || !zip_data->buf) return -1;
    mz_zip_archive zipArchive = {0};
    int ret = 0;
    if (mz_zip_writer_init_heap(&zipArchive, 0, 0) == MZ_FALSE) {//
        ret = -1;
    } else {
        if (mz_zip_writer_add_mem(&zipArchive, "", data, size, MZ_DEFAULT_COMPRESSION) == MZ_FALSE) {//
            ret = -1;
        } else {
            void *buf = NULL;
            size_t outSize = 0;
            if (mz_zip_writer_finalize_heap_archive(&zipArchive, &buf, &outSize) == MZ_FALSE) {//
                ret = -1;
            } else {
                if (outSize > INT32_MAX ||
                    bytebuf_write_batch(zip_data, buf, (s32)outSize) != (s32)outSize)
                    ret = -1;
                // finalize_heap_archive transfers ownership to the caller.
                mz_free(buf);
            }
        }
        mz_zip_writer_end(&zipArchive);
    }
    return ret;
}

// 修改gzip_compress函数，生成完整的GZIP格式
// GZIP footer integers are little endian and need not be aligned.
static void jarbox_gzip_put_le32(unsigned char *p, uint32_t v) {
    for (unsigned i=0; i<4; ++i) p[i]=(unsigned char)(v >> (8*i));
}
static uint32_t jarbox_gzip_get_le32(const unsigned char *p) {
    uint32_t v=0;
    for (unsigned i=0; i<4; ++i) v |= (uint32_t)p[i] << (8*i);
    return v;
}

s32 gzip_compress(char *data, int size, ByteBuf *gzip_data) {
    if (size < 0 || (size && !data) || !gzip_data || !gzip_data->buf) return -1;
    mz_stream stream = {0};
    int status;
    mz_ulong crc = mz_crc32(MZ_CRC32_INIT, (const unsigned char *) data, size);

    // 分配压缩缓冲区 - 预留头部(10字节)和尾部(8字节)的空间
    mz_ulong bound = mz_compressBound(size);
    if (bound > INT32_MAX - 18) return -1;
    mz_ulong compressed_size = bound + 18;
    unsigned char *compressed_data = (unsigned char *) MZ_MALLOC(compressed_size);
    if (!compressed_data) {
        return -1;
    }

    // 写入GZIP头部
    compressed_data[0] = 0x1F;  // ID1
    compressed_data[1] = 0x8B;  // ID2
    compressed_data[2] = 0x08;  // CM = DEFLATE
    compressed_data[3] = 0x00;  // FLG
    compressed_data[4] = 0x00;  // MTIME (4 bytes)
    compressed_data[5] = 0x00;
    compressed_data[6] = 0x00;
    compressed_data[7] = 0x00;
    compressed_data[8] = 0x00;  // XFL
    compressed_data[9] = 0xFF;  // OS = unknown

    // 设置压缩流
    stream.next_in = (const unsigned char *) data;
    stream.avail_in = size;
    stream.next_out = compressed_data + 10;  // 跳过GZIP头
    stream.avail_out = compressed_size - 18;  // 减去头和尾的大小

    // 初始化deflate
    status = mz_deflateInit2(&stream, MZ_DEFAULT_LEVEL, MZ_DEFLATED, -MZ_DEFAULT_WINDOW_BITS, 8, MZ_DEFAULT_STRATEGY);
    if (status != MZ_OK) {
        MZ_FREE(compressed_data);
        return -1;
    }

    // 执行压缩
    status = mz_deflate(&stream, MZ_FINISH);
    if (status != MZ_STREAM_END) {
        mz_deflateEnd(&stream);
        MZ_FREE(compressed_data);
        return -1;
    }

    // 获取压缩后的大小
    mz_ulong compressed_len = stream.total_out;
    mz_deflateEnd(&stream);

    // 写入CRC32和原始大小(8字节尾部)
    unsigned char *footer = compressed_data + 10 + compressed_len;
    jarbox_gzip_put_le32(footer, (uint32_t)crc);
    jarbox_gzip_put_le32(footer + 4, (uint32_t)size);

    // 写入到输出缓冲区
    s32 written = bytebuf_write_batch(gzip_data, (char *)compressed_data, (s32)(compressed_len + 18));
    MZ_FREE(compressed_data);

    return written == (s32)(compressed_len + 18) ? 0 : -1;
}

// 修改gzip_extract函数，解析标准GZIP格式
s32 gzip_extract(char *gzip_data, int size, ByteBuf *data) {
    if (!gzip_data || !data || !data->buf || size < 18 ||
        (unsigned char) gzip_data[0] != 0x1F ||
        (unsigned char) gzip_data[1] != 0x8B ||
        (unsigned char) gzip_data[2] != 0x08) {
        return -1;  // 无效的GZIP格式
    }

    mz_stream stream = {0};
    int status;

    // 读取原始大小(从尾部)
    mz_uint32 original_size = jarbox_gzip_get_le32((const unsigned char *)gzip_data + size - 4);
    mz_uint32 expected_crc = jarbox_gzip_get_le32((const unsigned char *)gzip_data + size - 8);
    if (original_size > INT32_MAX) return -1;

    // 分配解压缓冲区
    unsigned char *uncompressed_data = (unsigned char *) MZ_MALLOC(original_size ? original_size : 1);
    if (!uncompressed_data) {
        return -1;
    }

    // 设置解压流
    stream.next_in = (unsigned char *) gzip_data + 10;  // 跳过GZIP头
    stream.avail_in = size - 18;  // 减去头和尾的大小
    stream.next_out = uncompressed_data;
    stream.avail_out = original_size ? original_size : 1;

    // 初始化inflate
    status = mz_inflateInit2(&stream, -MZ_DEFAULT_WINDOW_BITS);
    if (status != MZ_OK) {
        MZ_FREE(uncompressed_data);
        return -1;
    }

    // 执行解压
    status = mz_inflate(&stream, MZ_FINISH);
    mz_inflateEnd(&stream);

    if (status != MZ_STREAM_END || stream.total_out != original_size) {
        MZ_FREE(uncompressed_data);
        return -1;
    }

    // 验证CRC32
    mz_uint32 computed_crc = mz_crc32(MZ_CRC32_INIT, uncompressed_data, original_size);
    if (computed_crc != expected_crc) {
        MZ_FREE(uncompressed_data);
        return -1;
    }

    // 写入到输出缓冲区
    s32 written = bytebuf_write_batch(data, (char *)uncompressed_data, (s32)original_size);
    MZ_FREE(uncompressed_data);

    return written == (s32)original_size ? 0 : -1;
}

//
//
//void test_gzip_compression() {
//    // 测试数据
//    const char *original_data = "这是一个测试字符串，用于验证gzip压缩和解压功能是否正常工作。";
//    int original_size = strlen(original_data) + 1; // 包含null终止符
//
//    // 初始化缓冲区
//    ByteBuf *compressed_buf = bytebuf_create(1024);
//    ByteBuf *decompressed_buf = bytebuf_create(1024);
//
//    // 压缩数据
//    printf("开始压缩...\n");
//    int compress_result = gzip_compress((char *) original_data, original_size, compressed_buf);
//    if (compress_result != 0) {
//        printf("压缩失败!\n");
//        return;
//    }
//    printf("压缩成功，压缩后大小: %d 字节\n", compressed_buf->wp);
//
//    // 解压数据
//    printf("开始解压...\n");
//    int decompress_result = gzip_extract(compressed_buf->buf, compressed_buf->wp, decompressed_buf);
//    if (decompress_result != 0) {
//        printf("解压失败!\n");
//        return;
//    }
//    printf("解压成功，解压后大小: %d 字节\n", decompressed_buf->wp);
//
//    // 比较数据
//    if (original_size != decompressed_buf->wp) {
//        printf("数据大小不一致! 原始: %d, 解压后: %d\n", original_size, decompressed_buf->wp);
//    } else if (memcmp(original_data, decompressed_buf->buf, original_size) != 0) {
//        printf("数据内容不一致!\n");
//    } else {
//        printf("测试通过! 原始数据和解压数据完全一致。\n");
//    }
//
//    // 清理
//    bytebuf_destroy(compressed_buf);
//    bytebuf_destroy(decompressed_buf);
//}
//
//void test_gzip_file_compression() {
//    const char *input_file = "./f"; // 输入文件路径
//    const char *compressed_file = "./test_compressed.gz"; // 压缩后文件路径
//    const char *decompressed_file = "./test_decompressed.dat"; // 解压后文件路径
//
//    // 1. 读取原始文件内容
//    ByteBuf *original_buf = bytebuf_create(0);
//    FILE *fp = fopen(input_file, "rb");
//    if (!fp) {
//        printf("无法打开输入文件: %s\n", input_file);
//        return;
//    }
//
//    fseek(fp, 0, SEEK_END);
//    long file_size = ftell(fp);
//    fseek(fp, 0, SEEK_SET);
//
//    bytebuf_expand(original_buf, file_size);
//    fread(original_buf->buf, 1, file_size, fp);
//    original_buf->wp = file_size;
//    fclose(fp);
//
//    // 2. 压缩数据
//    ByteBuf *compressed_buf = bytebuf_create(0);
//    printf("开始压缩文件...\n");
//    if (gzip_compress(original_buf->buf, original_buf->wp, compressed_buf) != 0) {
//        printf("文件压缩失败\n");
//        goto cleanup;
//    }
//    printf("压缩成功，压缩后大小: %d 字节\n", compressed_buf->wp);
//
//
//    // 保存压缩文件
//    fp = fopen(compressed_file, "wb");
//    if (!fp) {
//        printf("无法创建压缩文件\n");
//        goto cleanup;
//    }
//    fwrite(compressed_buf->buf, 1, compressed_buf->wp, fp);
//    fclose(fp);
//
//
//
//    compressed_file = "./f_c.gz";
//    FILE *fp1 = fopen(compressed_file, "rb");
//    if (!fp1) {
//        printf("无法打开输入文件: %s\n", compressed_file);
//        return;
//    }
//
//    fseek(fp1, 0, SEEK_END);
//    long file_size1 = ftell(fp1);
//    fseek(fp1, 0, SEEK_SET);
//
//    bytebuf_expand(compressed_buf, file_size1);
//    fread(compressed_buf->buf, 1, file_size, fp1);
//    compressed_buf->wp = file_size1;
//    fclose(fp1);
//    // 3. 解压数据
//    ByteBuf *decompressed_buf = bytebuf_create(0);
//    printf("开始解压文件...\n");
//    if (gzip_extract(compressed_buf->buf, compressed_buf->wp, decompressed_buf) != 0) {
//        printf("文件解压失败\n");
//        goto cleanup;
//    }
//    printf("解压成功，解压后大小: %d 字节\n", decompressed_buf->wp);
//
//    // 保存解压文件
//    fp = fopen(decompressed_file, "wb");
//    if (!fp) {
//        printf("无法创建解压文件\n");
//        goto cleanup;
//    }
//    fwrite(decompressed_buf->buf, 1, decompressed_buf->wp, fp);
//    fclose(fp);
//
//    // 4. 验证数据一致性
//    if (original_buf->wp != decompressed_buf->wp) {
//        printf("警告: 文件大小不一致 (原始: %d, 解压后: %d)\n", original_buf->wp, decompressed_buf->wp);
//    } else if (memcmp(original_buf->buf, decompressed_buf->buf, original_buf->wp) != 0) {
//        printf("警告: 文件内容不一致\n");
//    } else {
//        printf("测试成功! 原始文件和解压文件完全一致\n");
//    }
//
//    cleanup:
//    // 释放资源
//    if (original_buf) bytebuf_destroy(original_buf);
//    if (compressed_buf) bytebuf_destroy(compressed_buf);
//    if (decompressed_buf) bytebuf_destroy(decompressed_buf);
//}
//
//
//int main() {
//    test_gzip_compression();
//    test_gzip_file_compression();
//    return 0;
//}
