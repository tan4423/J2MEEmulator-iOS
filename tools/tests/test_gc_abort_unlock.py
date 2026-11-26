"""Exercise production pause-world cancellation with a modeled thread list."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"
PRELUDE = r"""
#include <assert.h>
#include <stddef.h>
#include <pthread.h>
#include <stdio.h>
typedef int s32;
typedef struct { int fail, moved; } Runtime;
typedef struct {
    pthread_mutex_t spinlock;
    int length;
    Runtime *items[3];
} ArrayList;
typedef struct { Runtime *runtime; } GcCollector;
typedef struct { GcCollector *collector; ArrayList *thread_list; } MiniJVM;
static void spin_lock(pthread_mutex_t *m) { assert(!pthread_mutex_lock(m)); }
static void spin_unlock(pthread_mutex_t *m) { assert(!pthread_mutex_unlock(m)); }
static void jthread_suspend(Runtime *r) { (void)r; }
/* The production accessor is called under the already-held list lock. */
static Runtime *arraylist_get_value_unsafe(ArrayList *l, int i) { return l->items[i]; }
static int _gc_wait_thread_suspend(MiniJVM *vm, Runtime *r) {
    (void)vm; return r->fail ? -1 : 0;
}
static void gc_move_objs_thread_2_gc(Runtime *r) { ++r->moved; }
"""
MAIN = r"""
static void *probe(void *arg) {
    ArrayList *l = arg;
    assert(!pthread_mutex_trylock(&l->spinlock));
    spin_unlock(&l->spinlock);
    return NULL;
}
int main(void) {
    Runtime a = {0}, b = {0}, c = {0}, gc = {0};
    ArrayList list = {PTHREAD_MUTEX_INITIALIZER, 3, {&a, &b, &c}};
    GcCollector collector = {&gc};
    MiniJVM vm = {&collector, &list};
    for (int i = 0; i < 100; ++i) {
        Runtime *r = list.items[i % 3];
        r->fail = 1;
        assert(_gc_pause_the_world(&vm) == -1);
        pthread_t t;
        assert(!pthread_create(&t, NULL, probe, &list));
        assert(!pthread_join(t, NULL));
        r->fail = 0;
        assert(_gc_pause_the_world(&vm) == 0);
        assert(!pthread_create(&t, NULL, probe, &list));
        assert(!pthread_join(t, NULL));
    }
    assert(gc.moved == 100);
    assert(!pthread_mutex_destroy(&list.spinlock));
    puts("GC abort unlock: OK");
    return 0;
}
"""


class GCAbortUnlockTest(unittest.TestCase):
    def test_abort_releases_thread_list_for_another_worker(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        src = (JVM / "garbage.c").read_text()
        begin = src.index("s32 _gc_pause_the_world(MiniJVM *jvm) {")
        end = src.index("\n}", begin) + 2
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "abort.c"
            exe = Path(td) / "abort"
            source.write_text(PRELUDE + src[begin:end] + "\n" + MAIN)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-pthread", str(source), "-o", str(exe)], check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("GC abort unlock: OK", result.stdout)

    def test_abort_clears_gc_flag_before_unlock(self):
        src = (JVM / "garbage.c").read_text()
        abort = src.split("if (_gc_pause_the_world(jvm) != 0) {", 1)[1].split("return -1;", 1)[0]
        self.assertLess(abort.index("collector->isgc = 0;"), abort.index("vm_share_unlock(jvm);"))

    def test_stop_breaks_gc_wait_before_thread_list_lock(self):
        bridge = BRIDGE.read_text()
        jvm = (JVM / "jvm.c").read_text()
        for src, owner in ((bridge, "owner"), (bridge, "slot->jvm"), (jvm, "jvm")):
            request = f"gc_request_thread_status({owner}->collector, GARBAGE_THREAD_STOP);"
            self.assertLess(src.index(request), src.index(f"thread_stop_all({owner});"))


if __name__ == "__main__":
    unittest.main()
