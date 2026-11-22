"""Host-only regression for MiniJVM-local Math.random stream.

Compiles the exact atomic stepping helper from jni_std.c, with stub MiniJVM.
This is not a test of the interpreter, JIT, UIKit or real game sessions.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JNI = ROOT / "J2MEEmulator/minijvm/jvm/jni_std.c"
JVM = ROOT / "J2MEEmulator/minijvm/jvm/jvm.c"
HEADER = ROOT / "J2MEEmulator/minijvm/jvm/jvm.h"

PREAMBLE = r"""
#include <stdint.h>
#include <stdatomic.h>
#include <pthread.h>
typedef uint64_t u64;
typedef struct { u64 math_random_state; } MiniJVM;
"""
RUNNER = r"""
typedef struct { MiniJVM *vm; int failed; } Job;
static void *worker(void *p) {
    Job *j = p;
    for (int i=0;i<200000;i++) {
        u64 value = jarbox_vm_math_random_next(j->vm);
        if (value == 0) j->failed++;
    }
    return NULL;
}
int main(void) {
    MiniJVM a = {123456789ULL}, b = {987654321ULL};
    Job x={&a,0}, y={&b,0};
    pthread_t t[4];
    pthread_create(&t[0],NULL,worker,&x);
    pthread_create(&t[1],NULL,worker,&x);
    pthread_create(&t[2],NULL,worker,&y);
    pthread_create(&t[3],NULL,worker,&y);
    for(int i=0;i<4;i++) pthread_join(t[i],NULL);
    if (x.failed || y.failed) return 1;
    if (a.math_random_state == b.math_random_state) return 2;
    if (a.math_random_state == 123456789ULL) return 3;
    if (b.math_random_state == 987654321ULL) return 4;
    return 0;
}
"""

class MultiVMMathRandomTest(unittest.TestCase):
    def test_atomic_state_from_real_production_helper(self):
        cc = shutil.which("gcc") or shutil.which("clang")
        if not cc:
            self.skipTest("No host C compiler")
        source = JNI.read_text(encoding="utf-8")
        start = source.index("static u64 jarbox_vm_math_random_next(")
        end = source.index("\ns32 com_sun_cldc_io_ConsoleOutputStream_write(", start)
        helper = source[start:end]
        self.assertNotIn("srand(", source)
        self.assertNotIn("is_random_init", source)
        self.assertIn("u64 math_random_state;", HEADER.read_text(encoding="utf-8"))
        self.assertIn("__atomic_store_n(&jvm->math_random_state", JVM.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory(prefix="jarbox-vm-rng-") as temp:
            src = Path(temp) / "rng.c"
            binary = Path(temp) / "rng"
            src.write_text(PREAMBLE + helper + RUNNER)
            subprocess.run(
                [cc, "-std=c11", "-O1", "-g", "-pthread", "-Wall", "-Wextra",
                 str(src), "-o", str(binary)],
                check=True, text=True, capture_output=True, timeout=45)
            subprocess.run([str(binary)], check=True, text=True,
                           capture_output=True, timeout=15)

if __name__ == "__main__":
    unittest.main()
