"""Exercise the production read-only ZIP wrappers against the bundled miniz.

Synthetic colliding class and resource names reproduce the NST archive layout.
No proprietary MIDlets, network requests or iOS execution are needed.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
UTILS = ROOT / "J2MEEmulator/minijvm/utils"

# The read-only functions use only ByteBuf and integer typedefs from the VM.
# Isolate them from unrelated gzip/writer and JVM allocation dependencies.
PREAMBLE = r"""
#include "miniz.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <sys/stat.h>
#include <stdatomic.h>
#include <stdio.h>
typedef int32_t s32;
typedef int64_t s64;
typedef uint32_t u32;
typedef char c8;
typedef struct { u32 _alloc_size, rp, wp; c8 *buf; } ByteBuf;
static int fail_expand = 0;
static void bytebuf_expand(ByteBuf *buf, u32 size) {
    if (fail_expand) return;
    void *p = realloc(buf->buf, size);
    if (p) { buf->buf = p; buf->_alloc_size = size; }
}
"""
PROGRAM = r"""
#define CHECK(x) do { if (!(x)) return __LINE__; } while (0)
int main(int argc, char **argv) {
    CHECK(argc == 3);
    const char *jar = argv[1];
    ByteBuf b = {1, 0, 0, malloc(1)};
    CHECK(b.buf != NULL);
    CHECK(zip_loadfile(jar, "a.class", &b) == 0);
    CHECK(b.wp == 3 && memcmp(b.buf, "low", 3) == 0);
    CHECK(zip_loadfile(jar, "/A.class", &b) == 0);
    CHECK(b.wp == 5 && memcmp(b.buf, "UPPER", 5) == 0);
    CHECK(zip_get_file_index(jar, "a.class") >= 0);
    CHECK(zip_get_file_index(jar, "a.class") != zip_get_file_index(jar, "A.class"));
    CHECK(zip_get_file_unzip_size(jar, "a.class") == 3);
    CHECK(zip_get_file_unzip_size(jar, "A.class") == 5);
    CHECK(zip_get_file_index(jar, "A.CLASS") == -1);
    CHECK(zip_get_file_unzip_size(jar, "A.CLASS") == -1);
    CHECK(zip_loadfile(jar, "A.CLASS", &b) == -1);
    char out[8] = {0};
    CHECK(zip_loadfile_to_mem(jar, "a.class", out, sizeof(out)) == 0);
    CHECK(memcmp(out, "low", 3) == 0);
    CHECK(zip_loadfile_to_mem(jar, "A.class", out, sizeof(out)) == 0);
    CHECK(memcmp(out, "UPPER", 5) == 0);
    CHECK(zip_loadfile_to_mem(jar, "A.class", out, 4) == -1);
    CHECK(zip_loadfile_to_mem(jar, "A.class", out, -1) == -1);
    CHECK(zip_loadfile_to_mem(jar, "A.CLASS", out, sizeof(out)) == -1);
    CHECK(zip_loadfile(jar, "img/Title.png", &b) == 0);
    CHECK(b.wp == 3 && memcmp(b.buf, "img", 3) == 0);
    CHECK(zip_get_file_unzip_size(jar, "img/title.png") == -1);
    CHECK(zip_loadfile(jar, "empty", &b) == 0 && b.wp == 0);
    CHECK(zip_loadfile(jar, "missing", &b) == -1);
    CHECK(zip_loadfile("missing.jar", "a.class", &b) == -1);
    CHECK(zip_loadfile(jar, NULL, &b) == -1);
    fail_expand = 1;
    CHECK(zip_loadfile(jar, "large", &b) == -1);
    fail_expand = 0;
    CHECK(zip_loadfile(jar, "large", &b) == 0 && b.wp == 1024);
    CHECK(b.buf[0] == 'x' && b.buf[1023] == 'x');
    // Cache hit/miss and exact-case collision, then replacement at same path.
    for (int n = 0; n < 1000; ++n) {
        CHECK(zip_classpath_loadfile(jar, "a.class", &b) == 0);
        CHECK(b.wp == 3 && memcmp(b.buf, "low", 3) == 0);
        CHECK(zip_classpath_loadfile(jar, "/A.class", &b) == 0);
        CHECK(b.wp == 5 && memcmp(b.buf, "UPPER", 5) == 0);
        CHECK(zip_classpath_loadfile(jar, "A.CLASS", &b) == -1);
    }
#if defined(__APPLE__) || defined(__linux__)
    CHECK(jarbox_classpath_cache[0].path != NULL);
    CHECK(jarbox_classpath_cache[1].path == NULL);
    CHECK(jarbox_classpath_data_count == 2);
    CHECK(jarbox_classpath_miss_count == 1);
    CHECK(jarbox_classpath_miss_find(&jarbox_classpath_cache[0], "A.CLASS"));
    CHECK(!jarbox_classpath_miss_find(&jarbox_classpath_cache[0], "A.class"));
    CHECK(zip_classpath_loadfile(jar, "/A.CLASS", &b) == -1);
    CHECK(jarbox_classpath_miss_count == 1);
    // A failed allocation/extraction is not proof of absence.
    ByteBuf small = {1, 0, 0, malloc(1)};
    CHECK(small.buf != NULL);
    fail_expand = 1;
    CHECK(zip_classpath_loadfile(jar, "large", &small) == -1);
    CHECK(!jarbox_classpath_miss_find(&jarbox_classpath_cache[0], "large"));
    fail_expand = 0;
    CHECK(zip_classpath_loadfile(jar, "large", &small) == 0 && small.wp == 1024);
    free(small.buf);
    // Bound a stream of unique misses independently of the positive bytes.
    for (unsigned i = 0; i < JARBOX_CLASSPATH_MISS_MAX_COUNT + 16; ++i) {
        char name[64];
        snprintf(name, sizeof(name), "absent/%u.class", i);
        CHECK(zip_classpath_loadfile(jar, name, &b) == -1);
        CHECK(jarbox_classpath_miss_bytes <= JARBOX_CLASSPATH_MISS_BUDGET);
        CHECK(jarbox_classpath_miss_count <= JARBOX_CLASSPATH_MISS_MAX_COUNT);
    }
    CHECK(jarbox_classpath_miss_count > 1);
    CHECK(jarbox_classpath_data_count == 3);
    CHECK(jarbox_classpath_data_bytes <= JARBOX_CLASSPATH_DATA_BUDGET);
    // Changing a VM's returned buffer must not change another VM's bytes.
    CHECK(zip_classpath_loadfile(jar, "a.class", &b) == 0);
    b.buf[0] = '!';
    ByteBuf other = {1, 0, 0, malloc(1)};
    CHECK(other.buf != NULL);
    fail_expand = 1;
    CHECK(zip_classpath_loadfile(jar, "a.class", &other) == -1);
    fail_expand = 0;
    CHECK(zip_classpath_loadfile(jar, "a.class", &other) == 0);
    CHECK(other.wp == 3 && memcmp(other.buf, "low", 3) == 0);
    CHECK(b.buf[0] == '!');
    free(other.buf);
    CHECK(zip_classpath_loadfile(jar, "empty", &b) == 0 && b.wp == 0);
    CHECK(jarbox_classpath_data_count == 3);
    CHECK(zip_classpath_loadfile(jar, "too-large", &b) == 0);
    CHECK(b.wp == JARBOX_CLASSPATH_DATA_MAX_ENTRY + 1);
    CHECK(jarbox_classpath_data_count == 3);
    // Fill beyond the total budget; reads must still work.
    for (int n = 0; n < 30; ++n) {
        char name[32];
        snprintf(name, sizeof(name), "resource/%d.bin", n);
        CHECK(zip_classpath_loadfile(jar, name, &b) == 0);
        CHECK(b.wp == JARBOX_CLASSPATH_DATA_MAX_ENTRY);
        CHECK(b.buf[0] == (char)n);
        CHECK(jarbox_classpath_data_bytes <= JARBOX_CLASSPATH_DATA_BUDGET);
    }
    CHECK(jarbox_classpath_data_count < 32);
    // Contention must use the uncached reader, never wait for another owner.
    CHECK(pthread_mutex_lock(&jarbox_classpath_lock) == 0);
    CHECK(zip_classpath_loadfile(jar, "a.class", &b) == 0);
    CHECK(pthread_mutex_unlock(&jarbox_classpath_lock) == 0);
#endif
    CHECK(rename(argv[2], jar) == 0);
    CHECK(zip_classpath_loadfile(jar, "a.class", &b) == 0);
    CHECK(b.wp == 7 && memcmp(b.buf, "new-low", 7) == 0);
    CHECK(zip_classpath_loadfile(jar, "A.class", &b) == -1);
#if defined(__APPLE__) || defined(__linux__)
    CHECK(jarbox_classpath_data_count == 1);
    CHECK(jarbox_classpath_miss_count == 1);
    CHECK(!jarbox_classpath_miss_find(&jarbox_classpath_cache[0], "A.CLASS"));
#endif
    CHECK(zip_classpath_loadfile(jar, "A.CLASS", &b) == 0);
    CHECK(b.wp == 5 && memcmp(b.buf, "fresh", 5) == 0);
    zip_classpath_cache_trim();
#if defined(__APPLE__) || defined(__linux__)
    for (unsigned n = 0; n < JARBOX_CLASSPATH_CACHE_SLOTS; ++n)
        CHECK(jarbox_classpath_cache[n].path == NULL);
    CHECK(jarbox_classpath_data_bytes == 0 && jarbox_classpath_data_count == 0);
    CHECK(jarbox_classpath_miss_bytes == 0 && jarbox_classpath_miss_count == 0);
#endif
    CHECK(zip_classpath_loadfile(jar, "a.class", &b) == 0);
    CHECK(b.wp == 7 && memcmp(b.buf, "new-low", 7) == 0);
    zip_classpath_cache_trim();
    free(b.buf);
    return 0;
}
"""

class ZipCaseSensitiveTest(unittest.TestCase):
    def test_read_only_wrappers(self):
        cc = shutil.which("cc")
        if cc is None:
            self.skipTest("C compiler unavailable")
        source = (UTILS / "miniz_wrapper.c").read_text(encoding="utf-8")
        start = source.index("static int jarbox_zip_find_entry(")
        end = source.index("s32 zip_savefile_mem(")
        with tempfile.TemporaryDirectory(prefix="jarbox-zip-case-") as temp:
            path = Path(temp)
            jar = path / "collision.jar"
            with zipfile.ZipFile(jar, "w", zipfile.ZIP_DEFLATED) as archive:
                for name, data in (("a.class", b"low"), ("A.class", b"UPPER"),
                                   ("img/Title.png", b"img"), ("empty", b""),
                                   ("large", b"x" * 1024)):
                    archive.writestr(name, data)
                archive.writestr("too-large", b"x" * (256 * 1024 + 1))
                for i in range(30):
                    archive.writestr(f"resource/{i}.bin", bytes([i]) * (256 * 1024))
            replacement = path / "replacement.jar"
            with zipfile.ZipFile(replacement, "w", zipfile.ZIP_DEFLATED) as archive:
                archive.writestr("a.class", b"new-low")
                archive.writestr("A.CLASS", b"fresh")
            c = path / "test.c"
            c.write_text(PREAMBLE + source[start:end] + PROGRAM, encoding="utf-8")
            exe = path / "test"
            build = subprocess.run([cc, "-std=gnu11", "-O2", "-pthread", "-I", str(UTILS),
                                    str(c), str(UTILS / "miniz.c"), "-o", str(exe)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe), str(jar), str(replacement)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr +
                             f" C check line (mod 256): {run.returncode}")

if __name__ == "__main__":
    unittest.main()
