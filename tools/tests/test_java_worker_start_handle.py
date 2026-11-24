"""Host regression for a worker finishing before thrd_create returns.

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
#include "jarbox_session.h"
typedef uintptr_t thrd_t;
enum { thrd_success, thrd_error };
enum { THREAD_STATUS_NEW, THREAD_STATUS_RUNNING, THREAD_STATUS_ZOMBIE };
typedef struct { JarBoxSession *session; } MiniJVM;
typedef struct Runtime Runtime;
typedef struct { Runtime *runtime; } Instance;
typedef struct { Instance *jthread; void *context_classloader; thrd_t pthread; int lock, thread_status; } Info;
struct Runtime { MiniJVM *jvm; Info *thrd_info; };
static int fail_create, stop_during_init, removed, created;
static void spin_lock(int *l) { assert(!*l); *l = 1; }
static void spin_unlock(int *l) { assert(*l); *l = 0; }
static Runtime *jthread_get_stackframe_value(MiniJVM *vm, Instance *ins) {
    (void)vm; return ins->runtime;
}
static void jthread_init(MiniJVM *vm, Instance *ins) {
    (void)ins; if (stop_during_init) jarbox_session_begin_stop(vm->session);
}
static void threadlist_remove(Runtime *r) { (void)r; ++removed; }
static int jthread_run(void *arg) {
    Runtime *r = arg;
    JarBoxSession *held = r->jvm->session;
    r->thrd_info->jthread->runtime = NULL;
    free(r->thrd_info);
    free(r);
    jarbox_session_worker_done(held);
    return 0;
}
static int thrd_create(thrd_t *out, int (*run)(void *), void *arg) {
    ++created;
    if (fail_create) return thrd_error;
    *out = 123;
    /* A fast child and collector may finish before the parent returns. */
    run(arg);
    return thrd_success;
}
"""
MAIN = r"""
int main(void) {
    for (int i = 0; i < 10000; ++i) {
        MiniJVM vm = {0};
        vm.session = jarbox_session_create(&vm);
        Info pi = {0}; Runtime parent = {&vm, &pi}; Instance ins = {0};
        Runtime *child = calloc(1, sizeof(*child));
        child->jvm = &vm; child->thrd_info = calloc(1, sizeof(Info));
        ins.runtime = child;
        int mode = i % 5;
        fail_create = mode == 1;
        stop_during_init = mode == 2;
        removed = created = 0;
        if (mode == 3) jarbox_session_begin_stop(vm.session);
        if (mode == 4) child->thrd_info->thread_status = THREAD_STATUS_RUNNING;
        thrd_t result = jthread_start(&ins, &parent);
        assert(jarbox_session_active_lease_count(vm.session) == 0);
        if (mode == 0) {
            assert(result == 123 && !ins.runtime && removed == 0 && created == 1);
        } else {
            assert(!result && ins.runtime == child);
            assert(removed == (mode == 1 || mode == 2));
            assert(created == (mode == 1));
            assert(child->thrd_info->thread_status ==
                   (mode == 3 ? THREAD_STATUS_NEW :
                    mode == 4 ? THREAD_STATUS_RUNNING : THREAD_STATUS_ZOMBIE));
            // Model GC reclamation through the retained Java stackFrame link.
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
    begin = src.index("thrd_t jthread_start(")
    end = src.index("\n__refer jthread_get_name_value", begin)
    return PRELUDE + src[begin:end] + MAIN


class JavaWorkerStartHandleTest(unittest.TestCase):
    def test_fast_worker_can_finish_before_parent_returns(self):
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
        self.assertIn("while (parent && !jvm->collector->exit_flag &&", jvm)

    def test_success_path_does_not_read_child_runtime(self):
        src = (JVM / "jvm_util.c").read_text()
        body = src.split("thrd_t jthread_start(", 1)[1].split("\n__refer jthread_get_name_value", 1)[0]
        self.assertIn("thrd_create(&started, jthread_run, runtime)", body)
        self.assertNotIn("return runtime->", body)
        self.assertIn("return started;", body)


if __name__ == "__main__":
    unittest.main()
