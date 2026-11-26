"""Host regression for worker retirement before Thread.start returns.

The start function and lease policy are production code; worker and GC
finalization are modeled, not a full miniJVM or iOS execution.
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
#include <stdint.h>
#include <stdlib.h>
#include <time.h>
#include "jarbox_session.h"
typedef uintptr_t thrd_t;
enum { thrd_success, thrd_error };
enum { THREAD_STATUS_NEW, THREAD_STATUS_RUNNING, THREAD_STATUS_ZOMBIE };
typedef struct Runtime Runtime;
typedef struct { int spinlock; Runtime *entry; } ArrayList;
typedef struct { JarBoxSession *session; ArrayList *thread_list; } MiniJVM;
typedef struct { Runtime *runtime; struct { void *clazz; } mb; } Instance;
typedef struct { Instance *jthread; void *context_classloader; int lock, thread_status; } Info;
struct Runtime { MiniJVM *jvm; Info *thrd_info; void *clazz; };
static int fail_create, stop_during_publish, fail_publish, stop_during_lookup;
static int removed, created, busy_once, safepoints, sleeps;
static ArrayList *active_list;
static Runtime *pending_child;
static int jthread_run(void *arg);
static void spin_lock(int *l) { assert(!*l); *l = 1; }
static int spin_trylock(int *l) {
    if (busy_once) { busy_once = 0; return 1; }
    if (*l) return 1;
    spin_lock(l); return 0;
}
static void spin_unlock(int *l) {
    assert(*l); *l = 0;
    // A real child cannot retire from the list until the parent unlocks it.
    // Model retirement and GC immediately at unlock, before parent returns.
    if (l == &active_list->spinlock && pending_child) {
        Runtime *child = pending_child;
        pending_child = NULL;
        jthread_run(child);
    }
}
static void check_suspend_and_pause(Runtime *r) { assert(r); ++safepoints; }
static void thrd_sleep(const struct timespec *t, void *unused) {
    assert(t->tv_sec == 0 && t->tv_nsec == 1000000L);
    (void)unused; ++sleeps;
}
static Runtime *jthread_get_stackframe_value(MiniJVM *vm, Instance *ins) {
    if (stop_during_lookup) jarbox_session_begin_stop(vm->session);
    return ins->runtime;
}
static int arraylist_push_back_unsafe(ArrayList *l, Runtime *r) {
    assert(l->spinlock && !l->entry && r->clazz == r->thrd_info->jthread->mb.clazz);
    assert(r->thrd_info->thread_status == THREAD_STATUS_RUNNING);
    if (fail_publish) return 0;
    l->entry = r;
    if (stop_during_publish) jarbox_session_begin_stop(r->jvm->session);
    return 1;
}
static void arraylist_remove_unsafe(ArrayList *l, Runtime *r) {
    assert(l->spinlock && l->entry == r);
    l->entry = NULL; ++removed;
}
static int jthread_run(void *arg) {
    Runtime *r = arg;
    JarBoxSession *held = r->jvm->session;
    assert(!active_list->spinlock && active_list->entry == r);
    assert(!r->thrd_info->lock);
    active_list->entry = NULL;
    r->thrd_info->jthread->runtime = NULL;
    free(r->thrd_info);
    free(r);
    jarbox_session_worker_done(held);
    return 0;
}
static int thrd_create(thrd_t *out, int (*run)(void *), void *arg) {
    assert(run == jthread_run && active_list->spinlock && active_list->entry == arg);
    ++created;
    if (fail_create) return thrd_error;
    *out = 123;
    assert(!pending_child);
    pending_child = arg;
    return thrd_success;
}
"""
MAIN = r"""
int main(void) {
    for (int i = 0; i < 16000; ++i) {
        ArrayList list = {0};
        MiniJVM vm = {.thread_list = &list};
        vm.session = jarbox_session_create(&vm);
        assert(vm.session);
        Info pi = {0}; Runtime parent = {.jvm = &vm, .thrd_info = &pi};
        Instance ins = {0}; ins.mb.clazz = &vm;
        Runtime *child = calloc(1, sizeof(*child));
        assert(child);
        child->jvm = &vm; child->thrd_info = calloc(1, sizeof(Info));
        assert(child->thrd_info);
        ins.runtime = child;
        int mode = i % 8;
        fail_create = mode == 1;
        stop_during_publish = mode == 2;
        fail_publish = mode == 5;
        stop_during_lookup = mode == 6;
        busy_once = mode == 7;
        removed = created = safepoints = sleeps = 0;
        active_list = &list;
        assert(!pending_child);
        if (mode == 3) jarbox_session_begin_stop(vm.session);
        if (mode == 4) child->thrd_info->thread_status = THREAD_STATUS_RUNNING;
        thrd_t result = jthread_start(&ins, &parent);
        assert(jarbox_session_active_lease_count(vm.session) == 0);
        assert(!list.spinlock && !list.entry && !pending_child);
        assert(safepoints == (mode == 7) && sleeps == safepoints);
        if (mode == 0 || mode == 7) {
            assert(result == 123 && !ins.runtime && removed == 0 && created == 1);
        } else {
            assert(!result && ins.runtime == child);
            assert(removed == (mode == 1 || mode == 2));
            assert(created == (mode == 1));
            assert(!child->thrd_info->lock);
            assert(!child->thrd_info->jthread);
            assert(child->thrd_info->thread_status ==
                   (mode == 3 || mode == 6 ? THREAD_STATUS_NEW :
                    mode == 4 ? THREAD_STATUS_RUNNING : THREAD_STATUS_ZOMBIE));
            free(child->thrd_info); free(child);
        }
        jarbox_session_begin_stop(vm.session);
        assert(jarbox_session_mark_dead(vm.session));
        jarbox_session_release(vm.session);
    }
    return 0;
}
"""


def harness(src):
    begin = src.index("static int jthread_start_list_lock(Runtime *parent) {")
    end = src.index("\n__refer jthread_get_name_value", begin)
    return PRELUDE + src[begin:end] + MAIN


class JavaWorkerStartHandleTest(unittest.TestCase):
    def test_worker_registration_and_fast_retirement_before_parent_returns(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "start.c"
            exe = Path(td) / "start"
            src.write_text(harness((JVM / "jvm_util.c").read_text()))
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-I", str(JVM), str(src), "-o", str(exe)],
                           check=True, timeout=30)
            subprocess.run([str(exe)], check=True, timeout=10)

    def test_native_callers_handle_failed_start_and_handle_ownership(self):
        jni = (JVM / "jni_std.c").read_text()
        start = jni.split("s32 java_lang_Thread_start(", 1)[1].split(
            "s32 java_lang_Thread_isAlive(", 1)[0]
        self.assertIn("thrd_t started = jthread_start(ins, runtime)", start)
        self.assertIn("if (!started)", start)
        self.assertIn("thrd_detach(started)", start)
        self.assertNotIn("thrd_rt->", start)
        jvm = (JVM / "jvm.c").read_text()
        self.assertIn("if (t) {\n                if (thrd_join(t, NULL)", jvm)
        self.assertIn("while (parent && !jvm->collector->exit_flag)", jvm)

    def test_success_path_does_not_read_child_runtime(self):
        src = (JVM / "jvm_util.c").read_text()
        body = src.split("thrd_t jthread_start(", 1)[1].split("\n__refer jthread_get_name_value", 1)[0]
        self.assertIn("thrd_create(&started, jthread_run, runtime)", body)
        self.assertNotIn("return runtime->", body)
        self.assertIn("return started;", body)


if __name__ == "__main__":
    unittest.main()
