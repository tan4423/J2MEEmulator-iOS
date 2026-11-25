#ifndef __TINY_JVM_MINIZ_WRAPPER_H__
#define __TINY_JVM_MINIZ_WRAPPER_H__

#ifdef __cplusplus
extern "C" {
#endif

#include "bytebuf.h"
#include "arraylist.h"
#include "utf8_string.h"

s32 zip_loadfile(char const *jarpath, char const *filename, ByteBuf *buf);

// Bounded read-only classpath cache, never used by mutable ZIP APIs.
s32 zip_classpath_loadfile(const char *jarpath, const char *filename, ByteBuf *buf);
// Optional outcome: 0 normal/fallback/error, 1 verified byte hit,
// 2 verified negative lookup hit. Identical load result and ownership.
s32 zip_classpath_loadfile_profiled(const char *jarpath, const char *filename, ByteBuf *buf, int *hit_kind);
void zip_classpath_cache_trim(void);

s32 zip_loadfile_to_mem(char const *jarpath, char const *filename, c8 *buf, s64 bufsize);

s64 zip_get_file_unzip_size(char const *jarpath, char const *filename);

s32 zip_get_file_index(char const *jarpath, char const *filename);

s32 zip_savefile(char const *jarpath, char const *filename, ByteBuf *buf);

s32 zip_savefile_mem(char const *jarpath, char const *filename, char const *buf, int size);

ArrayList *zip_get_filenames(char *jarpath);

void zip_destroy_filenames_list(ArrayList *list);

s32 zip_filecount(char *jarpath);

s32 zip_is_directory(char *jarpath, int index);

s32 zip_compress(char *data, int size, ByteBuf *zip_data);

s32 zip_extract(char *zip_data, int size, ByteBuf *data);

s32 gzip_compress(char *data, int size, ByteBuf *gzip_data);

s32 gzip_extract(char *gzip_data, int size, ByteBuf *data);

#ifdef __cplusplus
}
#endif

#endif
