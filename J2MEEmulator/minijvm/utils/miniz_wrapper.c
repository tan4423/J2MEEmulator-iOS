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


/* Classpath-only reader reuse. These slots contain archive metadata and a
 * read-only file handle, never Java objects, decompressed classes or RMS.
 * Four process-wide slots bound file descriptors and retained memory even
 * with 64 VMs. Try-lock fallback avoids blocking another VM's class load.
 * Keep the ordinary ZIP APIs and writer path uncached.
 */
#if defined(__APPLE__) || defined(__linux__)
#define JARBOX_CLASSPATH_CACHE_SLOTS 4
#define JARBOX_CLASSPATH_CACHE_MAX_BYTES (8 * 1024 * 1024)
typedef struct {
    char *path;
    struct stat identity;
    mz_zip_archive archive;
} JarBoxClasspathReader;
static JarBoxClasspathReader jarbox_classpath_cache[JARBOX_CLASSPATH_CACHE_SLOTS];
static unsigned jarbox_classpath_next;
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
static void jarbox_classpath_close(JarBoxClasspathReader *reader) {
    if (reader->path) {
        mz_zip_reader_end(&reader->archive);
        free(reader->path);
    }
    memset(reader, 0, sizeof(*reader));
}
static void jarbox_classpath_trim_locked(void) {
    if (atomic_exchange(&jarbox_classpath_trim_pending, 0)) {
        for (unsigned i = 0; i < JARBOX_CLASSPATH_CACHE_SLOTS; ++i)
            jarbox_classpath_close(&jarbox_classpath_cache[i]);
        jarbox_classpath_next = 0;
    }
}
void zip_classpath_cache_trim(void) {
    atomic_store(&jarbox_classpath_trim_pending, 1);
    if (pthread_mutex_trylock(&jarbox_classpath_lock) == 0) {
        jarbox_classpath_trim_locked();
        pthread_mutex_unlock(&jarbox_classpath_lock);
    }
}

s32 zip_classpath_loadfile(const char *jarpath, const char *filename, ByteBuf *buf) {
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
        // Prefer an empty slot; otherwise evict one bounded reader.
        for (unsigned n = 0; n < JARBOX_CLASSPATH_CACHE_SLOTS; ++n) {
            if (!jarbox_classpath_cache[n].path) {
                reader = &jarbox_classpath_cache[n];
                break;
            }
        }
        if (!reader)
            reader = &jarbox_classpath_cache[jarbox_classpath_next++ % JARBOX_CLASSPATH_CACHE_SLOTS];
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
    }

    // The same exact-case lookup and size checks as zip_loadfile.
    const char *entry = filename[0] == '/' ? filename + 1 : filename;
    int index = mz_zip_reader_locate_file(&reader->archive, entry, NULL,
                                         MZ_ZIP_FLAG_CASE_SENSITIVE);
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
    // A rename or rewrite during the read must not return stale class bytes.
    if (stat(jarpath, &after) != 0 || !jarbox_classpath_same_file(&before, &after)) {
        jarbox_classpath_close(reader);
        goto done;
    }
    fallback = 0;
done:
    jarbox_classpath_trim_locked();
    pthread_mutex_unlock(&jarbox_classpath_lock);
    return fallback ? zip_loadfile(jarpath, filename, buf) : ret;
}
#else
void zip_classpath_cache_trim(void) {}
s32 zip_classpath_loadfile(const char *jarpath, const char *filename, ByteBuf *buf) {
    return zip_loadfile(jarpath, filename, buf);
}
#endif

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
    mz_zip_archive zipArchive = {0};
    mz_zip_archive_file_stat file_stat = {0};
    int ret = 0;
    if (mz_zip_reader_init_mem(&zipArchive, zip_data, size, 0) == MZ_FALSE) {//
        ret = -1;
    } else {
        if (!mz_zip_reader_file_stat(&zipArchive, 0, &file_stat)) {
            ret = -1;
        } else {
            size_t uncompressed_size = (size_t) file_stat.m_uncomp_size;
            bytebuf_expand(data, (s32) uncompressed_size);
            mz_bool p = mz_zip_reader_extract_to_mem(&zipArchive, 0, data->buf, uncompressed_size, 0);
            if (p == MZ_FALSE) {
                ret = -1;
            } else {
                data->wp = uncompressed_size;
            }
        }
        mz_zip_reader_end(&zipArchive);
    }
    return ret;
}

s32 zip_compress(char *data, int size, ByteBuf *zip_data) {
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
                bytebuf_write_batch(zip_data, buf, (s32) outSize);
            }
        }
        mz_zip_writer_end(&zipArchive);
    }
    return ret;
}

// 修改gzip_compress函数，生成完整的GZIP格式
s32 gzip_compress(char *data, int size, ByteBuf *gzip_data) {
    mz_stream stream = {0};
    int status;
    mz_ulong crc = mz_crc32(MZ_CRC32_INIT, (const unsigned char *) data, size);

    // 分配压缩缓冲区 - 预留头部(10字节)和尾部(8字节)的空间
    mz_ulong compressed_size = mz_compressBound(size) + 18;
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
    *(mz_uint32 *) footer = crc;
    *(mz_uint32 *) (footer + 4) = size;

    // 写入到输出缓冲区
    bytebuf_write_batch(gzip_data, (char *) compressed_data, compressed_len + 18);
    MZ_FREE(compressed_data);

    return 0;
}

// 修改gzip_extract函数，解析标准GZIP格式
s32 gzip_extract(char *gzip_data, int size, ByteBuf *data) {
    if (size < 18 ||
        (unsigned char) gzip_data[0] != 0x1F ||
        (unsigned char) gzip_data[1] != 0x8B ||
        (unsigned char) gzip_data[2] != 0x08) {
        return -1;  // 无效的GZIP格式
    }

    mz_stream stream = {0};
    int status;

    // 读取原始大小(从尾部)
    mz_uint32 original_size = *(mz_uint32 *) (gzip_data + size - 4);
    mz_uint32 expected_crc = *(mz_uint32 *) (gzip_data + size - 8);

    // 分配解压缓冲区
    unsigned char *uncompressed_data = (unsigned char *) MZ_MALLOC(original_size);
    if (!uncompressed_data) {
        return -1;
    }

    // 设置解压流
    stream.next_in = (unsigned char *) gzip_data + 10;  // 跳过GZIP头
    stream.avail_in = size - 18;  // 减去头和尾的大小
    stream.next_out = uncompressed_data;
    stream.avail_out = original_size;

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
    bytebuf_write_batch(data, (char *) uncompressed_data, original_size);
    MZ_FREE(uncompressed_data);

    return 0;
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
