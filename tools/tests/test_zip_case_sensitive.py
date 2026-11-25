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
    CHECK(argc == 2);
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
            c = path / "test.c"
            c.write_text(PREAMBLE + source[start:end] + PROGRAM, encoding="utf-8")
            exe = path / "test"
            build = subprocess.run([cc, "-std=gnu11", "-O2", "-I", str(UTILS),
                                    str(c), str(UTILS / "miniz.c"), "-o", str(exe)],
                                   capture_output=True, text=True, timeout=60)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(exe), str(jar)], capture_output=True, text=True, timeout=10)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr +
                             f" C check line (mod 256): {run.returncode}")

if __name__ == "__main__":
    unittest.main()
