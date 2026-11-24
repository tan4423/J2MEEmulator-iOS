"""Compile the production VM wait deadline calculation with a mock clock."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "J2MEEmulator/minijvm/jvm/jvm_util.c"
PRELUDE = r"""
#include <assert.h>
#include <stdint.h>
#include <time.h>
#include <stdio.h>
typedef int64_t s64;
typedef int s32;
typedef struct { struct { int thread_cond, mutex_lock; } threadlock; } MiniJVM;
static struct timespec now, actual;
static int clock_ok = 1, calls;
static int fake_timespec_get(struct timespec *t, int base) {
    assert(base == TIME_UTC);
    if (!clock_ok) return 0;
    *t = now;
    return TIME_UTC;
}
#define timespec_get fake_timespec_get
static int cnd_timedwait(int *cond, int *lock, const struct timespec *t) {
    assert(cond && lock);
    assert(t->tv_nsec >= 0 && t->tv_nsec < 1000000000L);
    actual = *t;
    ++calls;
    return 0;
}
"""
MAIN = r"""
int main(void) {
    MiniJVM vm = {0};
    /* First case reliably overflows the original implementation. */
    now = (struct timespec){123, 950000000};
    vm_share_timedwait(&vm, 100);
    assert(actual.tv_sec == 124 && actual.tv_nsec == 50000000);
    for (long ns = 0; ns < 1000000000L; ns += 1000000L) {
        now = (struct timespec){123, ns};
        const s64 waits[] = {0, 1, 5, 20, 100, 250, 500, 999, 1000, 1001, 86400001};
        for (unsigned i = 0; i < sizeof(waits) / sizeof(waits[0]); ++i) {
            vm_share_timedwait(&vm, waits[i]);
            s64 expected = (s64)now.tv_sec * 1000000000 + ns + waits[i] * 1000000;
            assert((s64)actual.tv_sec * 1000000000 + actual.tv_nsec == expected);
        }
    }
    now = (struct timespec){123, 0};
    vm_share_timedwait(&vm, -1);
    assert(actual.tv_sec == 123 && actual.tv_nsec == 0);
    int before = calls;
    clock_ok = 0;
    vm_share_timedwait(&vm, 100);
    assert(calls == before);
    puts("VM absolute wait deadline: OK");
    return 0;
}
"""


def harness(source):
    start = source.index("void vm_share_timedwait(MiniJVM *jvm, s64 ms) {")
    end = source.index("\n}", start) + 2
    return PRELUDE + source[start:end] + MAIN


class VMShareDeadlineTest(unittest.TestCase):
    def test_normalized_absolute_wait_and_clock_failure(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "deadline.c"
            exe = Path(td) / "deadline"
            src.write_text(harness(SOURCE.read_text()))
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-Wno-unused-variable",
                            str(src), "-o", str(exe)], check=True, timeout=30)
            run = subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("VM absolute wait deadline: OK", run.stdout)


if __name__ == "__main__":
    unittest.main()
