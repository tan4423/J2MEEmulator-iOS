"""Exercise the production descriptor fast path without loading a JVM.

The stub represents the Utf8String byte storage and append contract only.
No full class parser, Java invocation or iOS performance claims.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
CLASS_LOAD = ROOT / "J2MEEmulator/minijvm/jvm/class_load.c"

PRE = r"""
#include <stdint.h>
#include <string.h>
#include <stdio.h>
typedef int32_t s32;
typedef struct { unsigned char *data; int length; } Utf8String;
static void utf8_append_data(Utf8String *s, const char *data, s32 n) {
    memcpy(s->data + s->length, data, n);
    s->length += n;
}
"""
MAIN = r"""
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "line %d\n", __LINE__); return 1; } } while (0)
static int check(const char *desc, const char *kinds, int slots) {
    unsigned char storage[256];
    storage[0] = '!';
    Utf8String d = {(unsigned char *)desc, (int)strlen(desc)};
    Utf8String out = {storage, 1};
    CHECK(jarbox_method_para_fast(&d, NULL) == slots);
    CHECK(jarbox_method_para_fast(&d, &out) == slots);
    CHECK(storage[0] == '!');
    CHECK(out.length == 1 + (int)strlen(kinds));
    CHECK(memcmp(storage + 1, kinds, strlen(kinds)) == 0);
    return 0;
}
int main(void) {
    CHECK(check("()V", "", 0) == 0);
    CHECK(check("(SCBIFZDJ)V", "44444488", 10) == 0);
    CHECK(check("(Ljava/lang/String;[[D[J[[[Ljava/lang/Object;I)J", "RRRR4", 5) == 0);
    CHECK(check("([B[C[F[I[Z[S[D[J)V", "RRRRRRRR", 8) == 0);
    char desc[260], types[256];
    desc[0] = '(';
    memset(desc+1, 'I', 255);
    memcpy(desc+256, ")V", 3);
    memset(types, '4', 255); types[255] = 0;
    CHECK(check(desc, types, 255) == 0);
    const char *bad[] = {"(Lbad)V", "([V)V", "(I))V", "(X)V", "(I", "()", "I)V", "(L;)V"};
    for (unsigned i=0; i<sizeof(bad)/sizeof(bad[0]); ++i) {
        unsigned char storage[2] = {'!',0};
        Utf8String d = {(unsigned char *)bad[i], (int)strlen(bad[i])};
        Utf8String out = {storage, 1};
        CHECK(jarbox_method_para_fast(&d, &out) == -1);
        CHECK(out.length == 1 && storage[0] == '!');
    }
    return 0;
}
"""

class MethodDescriptorTest(unittest.TestCase):
    def test_production_fast_path(self):
        cc = shutil.which("cc")
        if not cc:
            self.skipTest("host compiler unavailable")
        src = CLASS_LOAD.read_text()
        start = src.index("static s32 jarbox_method_para_fast(")
        end = src.index("\ns32 parseMethodPara(", start)
        with tempfile.TemporaryDirectory() as td:
            c, exe = Path(td)/"test.c", Path(td)/"test"
            c.write_text(PRE + src[start:end] + MAIN)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", str(c), "-o", str(exe)], check=True, timeout=30)
            subprocess.run([str(exe)], check=True, timeout=10)

    def test_reference_and_interface_slots_do_not_allocate_output(self):
        src = CLASS_LOAD.read_text()
        self.assertEqual(src.count("cmr->para_slots = jarbox_method_para_slots(cmr->descriptor);"), 2)
        self.assertIn("ptr->para_slots = parseMethodPara(ptr->descriptor, ptr->paraType);", src)
        self.assertIn("jarbox_method_para_fast(descriptor, NULL)", src)

if __name__ == "__main__":
    unittest.main()
