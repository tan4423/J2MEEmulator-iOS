"""Host regression for Java Runtime.exit ordering (mock collector/worker boundary)."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "J2MEEmulator/minijvm/jvm/jni_std.c"
PRELUDE = r'''
#include <assert.h>
#include <stdatomic.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
typedef int s32;
typedef int RuntimeStack;
typedef int JClass;
enum { GARBAGE_THREAD_NORMAL, GARBAGE_THREAD_PAUSE, GARBAGE_THREAD_STOP, GARBAGE_THREAD_DEAD };
typedef struct { atomic_int state; int exit_flag, exit_code; } GcCollector;
typedef struct { GcCollector *collector; pthread_mutex_t list_lock; atomic_int ready; } MiniJVM;
typedef struct { MiniJVM *jvm; RuntimeStack *stack; s32 *localvar; } Runtime;
static s32 localvar_getInt(s32 *v, int index) { return v[index]; }
static void gc_request_thread_status(GcCollector *c, int requested) {
    int current = atomic_load(&c->state);
    while (current < GARBAGE_THREAD_STOP &&
           !atomic_compare_exchange_weak(&c->state, &current, requested)) {}
}
static void *collector_wait(void *arg) {
    MiniJVM *vm = arg;
    assert(!pthread_mutex_lock(&vm->list_lock));
    atomic_store(&vm->ready, 1);
    while (atomic_load(&vm->collector->state) < GARBAGE_THREAD_STOP) sched_yield();
    assert(!pthread_mutex_unlock(&vm->list_lock));
    return NULL;
}
static void thread_stop_all(MiniJVM *vm) {
    assert(vm->collector->exit_flag == 1);
    assert(atomic_load(&vm->collector->state) >= GARBAGE_THREAD_STOP);
    assert(!pthread_mutex_lock(&vm->list_lock));
    assert(!pthread_mutex_unlock(&vm->list_lock));
}
'''
MAIN = r'''
int main(void) {
    for (int i = 0; i < 100; ++i) {
        GcCollector ca = {GARBAGE_THREAD_NORMAL, 0, 0};
        GcCollector cb = {GARBAGE_THREAD_NORMAL, 0, 0};
        MiniJVM a = {&ca, PTHREAD_MUTEX_INITIALIZER, 0};
        RuntimeStack stack = 0;
        s32 vars[] = {0, i};
        Runtime runtime = {&a, &stack, vars};
        pthread_t thread;
        assert(!pthread_create(&thread, NULL, collector_wait, &a));
        while (!atomic_load(&a.ready)) sched_yield();
        assert(java_lang_Runtime_exitInternal(&runtime, NULL) == 0);
        assert(!pthread_join(thread, NULL));
        assert(ca.exit_code == i && ca.exit_flag == 1);
        assert(atomic_load(&ca.state) == GARBAGE_THREAD_STOP);
        atomic_store(&ca.state, GARBAGE_THREAD_DEAD);
        assert(java_lang_Runtime_exitInternal(&runtime, NULL) == 0);
        assert(atomic_load(&ca.state) == GARBAGE_THREAD_DEAD);
        assert(atomic_load(&cb.state) == GARBAGE_THREAD_NORMAL && !cb.exit_flag);
        assert(!pthread_mutex_destroy(&a.list_lock));
    }
    puts("Java exit GC stop ordering: OK");
    return 0;
}
'''


def harness(source):
    start = source.index("s32 java_lang_Runtime_exitInternal(")
    end = source.index("\n}", start) + 2
    return PRELUDE + source[start:end] + MAIN


class JavaExitGCStopTest(unittest.TestCase):
    def test_gc_stop_precedes_thread_list_drain(self):
        cc = shutil.which("clang") or shutil.which("cc")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "exit.c"
            exe = Path(td) / "exit"
            src.write_text(harness(SOURCE.read_text(encoding="utf-8")))
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-Wno-unused-parameter", "-Wno-unused-variable", "-Wno-unused-function",
                            "-pthread", str(src), "-o", str(exe)], check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Java exit GC stop ordering: OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
