"""Test the production runner's cancellation/publication boundary on a host."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"
PRELUDE = r"""
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include "jvm_bridge.h"
typedef int s32;
typedef char c8;
enum { BRIDGE_STARTING = 1, BRIDGE_RUNNING = 2, BRIDGE_CLEANUP = 3 };
struct JarBoxSession { int marker; };
typedef struct { struct JarBoxSession *session; } MiniJVM;
typedef struct { MiniJVM *jvm; atomic_int phase, stop_requested; } JarBoxVMContext;
typedef int ArrayList;
static pthread_mutex_t g_bridge_lifecycle_lock = PTHREAD_MUTEX_INITIALIZER;
static int foreground, runs, list;
static int cpu_stage, cpu_begins, cpu_modes, cpu_ends, main_result;
static JarBoxVMContext *current;
static void check_cpu_owner(struct JarBoxSession *s) {
    assert(s && s == current->jvm->session);
    assert(atomic_load(&current->phase) == BRIDGE_RUNNING);
}
// Stateful doubles use the public bridge prototypes and actual CPU kind enum.
void jvm_bridge_cpu_worker_begin(struct JarBoxSession *s, int kind) {
    check_cpu_owner(s);
    assert(kind == JARBOX_CPU_RUNNER && cpu_stage == 0);
    assert(foreground == runs + 1);
    cpu_stage = 1;
    ++cpu_begins;
}
void jvm_bridge_cpu_mode_changed(struct JarBoxSession *s) {
    check_cpu_owner(s);
    assert(cpu_stage == 1);
    cpu_stage = 2;
    ++cpu_modes;
}
void jvm_bridge_cpu_worker_end(struct JarBoxSession *s) {
    check_cpu_owner(s);
    assert(cpu_stage == 3);
    cpu_stage = 0;
    ++cpu_ends;
}
static int jarbox_session_enter_foreground(void *s) { assert(s); ++foreground; return 1; }
static void jvm_bridge_note_net_trace(const char *s) { (void)s; }
static ArrayList *arraylist_create(int n) { (void)n; return &list; }
static void arraylist_push_back(ArrayList *a, void *b) { assert(a && b); }
static void arraylist_destroy(ArrayList *a) { assert(a == &list && cpu_stage == 0); }
static s32 call_main(MiniJVM *v, c8 *name, ArrayList *a) {
    assert(v && name && a);
    assert(atomic_load(&current->phase) == BRIDGE_RUNNING);
    assert(cpu_stage == 2 && v == current->jvm);
    cpu_stage = 3;
    ++runs;
    return main_result;
}
"""
MAIN = r"""
static void check_cpu_counts(int n) {
    assert(cpu_stage == 0 && cpu_begins == n && cpu_modes == n && cpu_ends == n);
}
int main(void) {
    static struct JarBoxSession sessions[2];
    static MiniJVM vm = {&sessions[0]};
    static JarBoxVMContext slot = {&vm, BRIDGE_STARTING, 0};
    current = &slot;
    for (int i = 0; i < 100; ++i) {
        vm.session = &sessions[i % 2];
        atomic_store(&slot.phase, BRIDGE_STARTING);
        atomic_store(&slot.stop_requested, 1);
        assert(bridge_run_slot(&slot, "game.jar") == -9);
        assert(atomic_load(&slot.phase) == BRIDGE_STARTING);
        assert(foreground == i && runs == i);
        check_cpu_counts(i);
        atomic_store(&slot.stop_requested, 0);
        main_result = i % 2 ? -7 : 0;
        assert(bridge_run_slot(&slot, "game.jar") == main_result);
        assert(atomic_load(&slot.phase) == BRIDGE_CLEANUP);
        assert(foreground == i + 1 && runs == i + 1);
        check_cpu_counts(i + 1);
        assert(bridge_run_slot(&slot, "game.jar") == -1);
        check_cpu_counts(i + 1);
    }
    return 0;
}
"""


class StartupCancelCheckpointTest(unittest.TestCase):
    def test_cancelled_runner_never_publishes_running(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host compiler unavailable")
        source = BRIDGE.read_text(encoding="utf-8")
        start = source.index("static int bridge_run_slot(")
        end = source.index("\n}", start) + 2
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "runner.c"
            exe = Path(td) / "runner"
            src.write_text(PRELUDE + source[start:end] + MAIN)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
                            "-I", str(BRIDGE.parent), str(src), "-o", str(exe)], check=True, timeout=30)
            subprocess.run([str(exe)], check=True, capture_output=True, timeout=10)

    def test_native_cancel_checks_precede_probe_and_allocation(self):
        source = BRIDGE.read_text(encoding="utf-8")
        start = source.index("static int bridge_init_slot(")
        end = source.index("\nstatic int bridge_run_slot(", start)
        body = source[start:end]
        check = "if (atomic_load_explicit(&slot->stop_requested, memory_order_acquire)) return -9;"
        first = body.index(check)
        second = body.index(check, first + len(check))
        probe = body.index("treo_is_nso_family(midlet_jar, &init_target)")
        self.assertLess(first, probe)
        self.assertLess(probe, second)
        self.assertLess(second, body.index("slot->jvm = jvm_create();"))


if __name__ == "__main__":
    unittest.main()
