"""Exercise production GC start/destroy functions with a real host pthread.

Heap destruction and collection work are mocked, not a full JVM test.
"""
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
#include <stdlib.h>
#include <stdio.h>
#include <sched.h>
#include <stdatomic.h>
typedef int s32;
typedef uint8_t u8;
typedef pthread_t thrd_t;
enum { thrd_success, thrd_error };
enum { GARBAGE_THREAD_NORMAL, GARBAGE_THREAD_PAUSE, GARBAGE_THREAD_STOP, GARBAGE_THREAD_DEAD };
typedef struct GcCollector GcCollector;
typedef struct { GcCollector *collector; } MiniJVM;
struct GcCollector {
    MiniJVM *jvm;
    thrd_t garbage_thread;
    int garbage_thread_started;
    u8 _garbage_thread_status;
    void *objs_holder, *runtime_refer_copy, *objs_2_count, *runtime;
};
static int fail_create, creates, joins, clears;
static atomic_int exited;
static u8 gc_thread_status(const GcCollector *c) { return __atomic_load_n(&c->_garbage_thread_status, __ATOMIC_ACQUIRE); }
static void gc_resume(GcCollector *c) { __atomic_store_n(&c->_garbage_thread_status, GARBAGE_THREAD_NORMAL, __ATOMIC_RELEASE); }
static void gc_stop(GcCollector *c) { if (gc_thread_status(c) < GARBAGE_THREAD_STOP) __atomic_store_n(&c->_garbage_thread_status, GARBAGE_THREAD_STOP, __ATOMIC_RELEASE); }
static int _gc_thread_run(void *arg) {
    GcCollector *c = arg;
    while (gc_thread_status(c) != GARBAGE_THREAD_STOP) sched_yield();
    __atomic_store_n(&c->_garbage_thread_status, GARBAGE_THREAD_DEAD, __ATOMIC_RELEASE);
    atomic_store(&exited, 1);
    return 0;
}
static void *run(void *arg) { _gc_thread_run(arg); return NULL; }
static int thrd_create(thrd_t *t, int (*fn)(void *), void *arg) {
    assert(fn == _gc_thread_run);
    ++creates;
    if (fail_create) return thrd_error;
    return pthread_create(t, NULL, run, arg) == 0 ? thrd_success : thrd_error;
}
static int thrd_join(thrd_t t, int *res) {
    (void)res;
    ++joins;
    return pthread_join(t, NULL) == 0 ? thrd_success : thrd_error;
}
static void vm_share_lock(MiniJVM *v) { (void)v; assert(0 && "normal join must not poll"); }
static void vm_share_unlock(MiniJVM *v) { (void)v; }
static void vm_share_timedwait(MiniJVM *v, int ms) { (void)v; (void)ms; }
static void _garbage_clear(GcCollector *c) {
    assert(gc_thread_status(c) == GARBAGE_THREAD_DEAD);
    if (c->garbage_thread_started) assert(atomic_load(&exited) == 1);
    ++clears;
}
#define jvm_printf(...) ((void)0)
#define hashset_destroy free
#define arraylist_destroy free
#define hashtable_destroy free
#define runtime_destroy free
#define jvm_free free
"""
MAIN = r"""
static GcCollector *fresh(MiniJVM *v) {
    GcCollector *c = calloc(1, sizeof(*c));
    assert(c);
    c->jvm = v;
    c->_garbage_thread_status = GARBAGE_THREAD_PAUSE;
    v->collector = c;
    atomic_store(&exited, 0);
    return c;
}
int main(void) {
    for (int i = 0; i < 100; ++i) {
        MiniJVM v = {0};
        GcCollector *c = fresh(&v);
        gc_destroy(&v); /* bootstrap failed before creating a worker */
        assert(!v.collector && creates == i * 2 && joins == i);
        c = fresh(&v);
        fail_create = 1;
        assert(gc_start(c) != 0);
        assert(gc_thread_status(c) == GARBAGE_THREAD_DEAD);
        assert(!c->garbage_thread_started);
        assert(gc_start(c) != 0); /* terminal failure cannot restart */
        gc_destroy(&v);
        assert(!v.collector && creates == i * 2 + 1 && joins == i);
        c = fresh(&v);
        fail_create = 0;
        assert(gc_start(c) == 0);
        assert(gc_start(c) != 0); /* no second collector */
        gc_destroy(&v);
        assert(!v.collector && creates == i * 2 + 2 && joins == i + 1);
    }
    assert(clears == 300);
    puts("GC worker lifecycle: OK (100 joins, 100 failed creates, 100 unstarted)");
    return 0;
}
"""


def harness(source):
    begin = source.index("s32 gc_start(GcCollector *collector) {")
    end = source.index("\n}", source.index("void gc_destroy(MiniJVM *jvm) {", begin)) + 2
    return PRELUDE + source[begin:end] + MAIN


class GCWorkerLifecycleTest(unittest.TestCase):
    def test_creation_failure_and_join_before_heap_cleanup(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "gc.c"
            exe = Path(td) / "gc"
            source.write_text(harness((JVM / "garbage.c").read_text()))
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
                            str(source), "-o", str(exe)], check=True, timeout=30)
            run = subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("GC worker lifecycle: OK", run.stdout)

    def test_bootstrap_starts_worker_only_after_core_initialization(self):
        source = (JVM / "jvm.c").read_text()
        body = source.split("s32 jvm_init(", 1)[1].split("\n}", 1)[0]
        self.assertLess(body.index("gc_create(jvm);"), body.index("classes_load_get_with_clinit("))
        self.assertLess(body.index("runtime_destroy(runtime);"), body.index("gc_start(jvm->collector)"))
        self.assertIn("if (gc_start(jvm->collector) != 0)", body)
        create = (JVM / "garbage.c").read_text().split("s32 gc_create(MiniJVM *jvm) {", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("thrd_create(", create)


if __name__ == "__main__":
    unittest.main()
