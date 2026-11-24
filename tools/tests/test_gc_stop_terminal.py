"""Production GC status helpers and control functions, with mock VM lock."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"
PRELUDE = r"""
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
typedef uint8_t u8;
typedef struct { pthread_mutex_t lock; } MiniJVM;
typedef struct { MiniJVM *jvm; u8 _garbage_thread_status; } GcCollector;
static void vm_share_lock(MiniJVM *vm) { assert(!pthread_mutex_lock(&vm->lock)); }
static void vm_share_unlock(MiniJVM *vm) { assert(!pthread_mutex_unlock(&vm->lock)); }
"""
MAIN = r"""
static void *toggle(void *arg) {
    GcCollector *c = arg;
    for (int i = 0; i < 1000; ++i) { gc_resume(c); gc_pause(c); }
    return NULL;
}
int main(void) {
    MiniJVM a = {PTHREAD_MUTEX_INITIALIZER}, b = {PTHREAD_MUTEX_INITIALIZER};
    GcCollector ca = {&a, GARBAGE_THREAD_NORMAL}, cb = {&b, GARBAGE_THREAD_NORMAL};
    for (int i = 0; i < 100; ++i) {
        __atomic_store_n(&ca._garbage_thread_status, GARBAGE_THREAD_NORMAL, __ATOMIC_RELEASE);
        gc_pause(&ca); assert(gc_thread_status(&ca) == GARBAGE_THREAD_PAUSE);
        gc_resume(&ca); assert(gc_thread_status(&ca) == GARBAGE_THREAD_NORMAL);
        pthread_t worker;
        assert(!pthread_create(&worker, NULL, toggle, &ca));
        gc_stop(&ca);
        assert(!pthread_join(worker, NULL));
        assert(gc_thread_status(&ca) == GARBAGE_THREAD_STOP);
        gc_resume(&ca); gc_pause(&ca);
        assert(gc_thread_status(&ca) == GARBAGE_THREAD_STOP);
        __atomic_store_n(&ca._garbage_thread_status, GARBAGE_THREAD_DEAD, __ATOMIC_RELEASE);
        gc_resume(&ca); gc_pause(&ca); gc_stop(&ca);
        assert(gc_thread_status(&ca) == GARBAGE_THREAD_DEAD);
        assert(gc_thread_status(&cb) == GARBAGE_THREAD_NORMAL);
    }
    puts("GC terminal status: OK");
    return 0;
}
"""


def harness(header, source):
    begin = header.index("enum {\n    GARBAGE_THREAD_NORMAL,")
    end = header.index("// API", begin)
    controls = source.index("void gc_pause(GcCollector *collector)")
    stop_end = source.index("\n//===============================   inner", controls)
    return PRELUDE + header[begin:end] + source[controls:stop_end] + MAIN


class GCTerminalStatusTest(unittest.TestCase):
    def test_stop_and_dead_are_terminal_for_pause_resume(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "gc.c"
            exe = Path(td) / "gc"
            source.write_text(harness((JVM / "garbage.h").read_text(),
                                      (JVM / "garbage.c").read_text()))
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-pthread", str(source), "-o", str(exe)],
                           check=True, timeout=30)
            result = subprocess.run([str(exe)], check=True, capture_output=True,
                                    text=True, timeout=20)
            self.assertIn("GC terminal status: OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
