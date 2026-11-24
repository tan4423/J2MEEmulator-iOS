"""Exercise actual memory-budget code using deterministic iOS API doubles.

The simulator supplies headroom and monotonic time; no real device memory
pressure or native game execution is claimed.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"
LIB = ROOT / "J2MEEmulator/UI/AppsListViewController.swift"
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"
RENDER = ROOT / "J2MEEmulator/NativeBridge/j2me_render.m"
APP = ROOT / "J2MEEmulator/AppDelegate.swift"

PRE = r'''
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>
#include <pthread.h>
#include <time.h>
#include <assert.h>
#include <stdio.h>
#ifndef __APPLE__
#define __APPLE__ 1
#endif
#define __JVM_OS_IOS__ 1
static uint64_t headroom, monotonic_ns;
static unsigned samples;
static size_t os_proc_available_memory(void) { samples++; return (size_t)headroom; }
static int fake_clock_gettime(clockid_t clock, struct timespec *ts) {
    (void)clock;
    ts->tv_sec = (time_t)(monotonic_ns / UINT64_C(1000000000));
    ts->tv_nsec = (long)(monotonic_ns % UINT64_C(1000000000));
    return 0;
}
#define clock_gettime fake_clock_gettime
'''
MAIN = r'''
int main(void) {
    const uint64_t mb = UINT64_C(1048576);
    uint64_t bytes = 0;
    unsigned checks = 0;
    for (unsigned i = 0; i < 1000; ++i) {
        monotonic_ns = UINT64_C(100000000000) + i * UINT64_C(60000000000);
        headroom = 0;
        assert(jvm_bridge_memory_state(&bytes) == 2 && bytes == 0); checks++;
        headroom = 150*mb-1;
        assert(jvm_bridge_memory_state(&bytes) == 2 && bytes == headroom); checks++;
        headroom = 150*mb;
        assert(jvm_bridge_memory_state(NULL) == 1); checks++;
        headroom = 300*mb;
        assert(jvm_bridge_memory_state(NULL) == 1); checks++;
        headroom++;
        assert(jvm_bridge_memory_state(&bytes) == 0 && bytes == headroom); checks++;
        jvm_bridge_memory_note_warning();
        assert(jvm_bridge_memory_state(NULL) == 1); checks++;
        monotonic_ns += UINT64_C(14999999999);
        assert(jvm_bridge_memory_state(NULL) == 1); checks++;
        monotonic_ns++;
        assert(jvm_bridge_memory_state(NULL) == 0); checks++;
        headroom = 200*mb;
        assert(jvm_bridge_memory_state(NULL) == 1); checks++;
        headroom = 400*mb;
        assert(jvm_bridge_memory_state(NULL) == 0); checks++;
        jvm_bridge_memory_note_warning();
        headroom = 100*mb;
        assert(jvm_bridge_memory_state(NULL) == 2); checks++;
        headroom = 800*mb;
        assert(jvm_bridge_memory_state(NULL) == 1); checks++;
    }
    printf("%u memory budget checks passed\n", checks);
    monotonic_ns += UINT64_C(60000000000);
    headroom=800*mb;
    unsigned before=samples;
    assert(jvm_bridge_memory_state_cached()==0);
    assert(samples==before+1);
    headroom=100*mb;
    for(unsigned i=0;i<1000;i++) assert(jvm_bridge_memory_state_cached()==0);
    assert(samples==before+1);
    monotonic_ns+=UINT64_C(1000000000);
    assert(jvm_bridge_memory_state_cached()==2 && samples==before+2);
    monotonic_ns+=UINT64_C(1000000000);
    headroom=800*mb;
    assert(jvm_bridge_memory_state_cached()==0);
    monotonic_ns++;
    jvm_bridge_memory_note_warning();
    assert(jvm_bridge_memory_state_cached()==1);
    puts("shared GC sample and warning invalidation: PASS");
    return 0;
}
'''


def between(source, start, end):
    return source.split(start, 1)[1].split(end, 1)[0]


class MemoryBudgetTest(unittest.TestCase):
    def test_actual_policy_boundaries_and_warning_recovery(self):
        cc = shutil.which(os.environ.get("CC", "cc"))
        if not cc:
            self.skipTest("host C compiler unavailable")
        src = BRIDGE.read_text()
        policy = "static int bridge_memory_level(" + between(
            src, "static int bridge_memory_level(", "static int bridge_try_begin_session(")
        with tempfile.TemporaryDirectory() as td:
            code, exe = Path(td) / "budget.c", Path(td) / "budget"
            code.write_text(PRE + policy + MAIN)
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pthread",
                            str(code), "-o", str(exe)], check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True,
                                    check=True, timeout=10)
            self.assertIn("12000 memory budget checks passed", result.stdout)
            self.assertIn("shared GC sample and warning invalidation: PASS", result.stdout)

    def test_gate_before_reservation_and_allocation(self):
        src = BRIDGE.read_text()
        admission = between(src, "static int bridge_try_begin_session(",
                            "int jvm_bridge_try_begin_session_for_jar(")
        self.assertLess(admission.index("jvm_bridge_memory_state(NULL)"),
                        admission.index("bridge_reserve_slot_locked("))
        self.assertIn("denial = -2; goto denied;", admission)
        init = between(src, "static int bridge_init_slot(", "static int bridge_run_slot(")
        self.assertLess(init.index("jvm_bridge_memory_state(NULL)"), init.index("slot->jvm = jvm_create()"))
        self.assertIn("if (jvm_bridge_memory_state(NULL) != 0) return -12;", init)
        game = GAME.read_text()
        worker = between(game, "nonisolated private static func runMIDlet(", "\n    }")
        self.assertIn("defer { _ = jvm_bridge_finish_session_for_token(token) }", worker)
        self.assertIn("if initResult == -12", worker)
        self.assertIn("if admission == -2", game)
        self.assertIn("int jvm_bridge_supported_concurrent_sessions(void) {\n    return JARBOX_REGISTRY_MAX_SLOTS;", src)

    def test_resume_and_offline_tab_storage_do_not_require_new_heap(self):
        lib = LIB.read_text().split("class AppsListViewController: UIViewController,", 1)[1]
        launch = between(lib, "private func launchGameTab(", "\n    }")
        self.assertLess(launch.index("game.resumeParkedGame()"), launch.index("memoryLaunchDenial()"))
        slot = between(lib, "private func requireNewTabSlot(", "\n    }")
        self.assertIn("memoryLaunchDenial()", slot)
        switch = between(lib, "func validateGameTabSwitch(", "\n    }")
        self.assertLess(switch.index("game.parkedSessionToken != nil"), switch.index("try requireNewTabSlot"))
        add = between(lib, "func createTabBeside(", "\n    }")
        self.assertLess(add.index("try requireNewTabSlot"), add.index("createCloneAfter("))
        offline = between(lib, "private func addDefaultTabs(", "\n    }")
        self.assertNotIn("memoryLaunchDenial", offline)

    def test_warning_is_event_driven_and_cache_only(self):
        app = APP.read_text()
        warning = between(app, "func applicationDidReceiveMemoryWarning(", "\n    }")
        self.assertIn("jvm_bridge_memory_note_warning()", warning)
        self.assertIn("j2me_render_trim_memory_cache()", warning)
        self.assertIn("library.handleAppMemoryPressure()", warning)
        lib = LIB.read_text()
        pressure = between(lib, "func handleAppMemoryPressure()", "\n    }")
        self.assertIn("restoreRetainedGamesForMemoryPressure()", pressure)
        self.assertNotIn("Timer(", pressure)
        self.assertNotIn("stopParkedGame(", pressure)
        self.assertNotIn("removeItem(", pressure)
        trim = between(RENDER.read_text(), "int j2me_render_trim_memory_cache(void)", "\n}")
        self.assertIn("os_unfair_lock_trylock(&treo_live_gpu_lock)", trim)
        clear = between(RENDER.read_text(), "static void treo_live_trim_textures_locked(void)", "\n}")
        self.assertIn("[treo_live_owner_textures removeAllObjects]", clear)
        self.assertIn("[treo_live_owner_texture_bytes removeAllObjects]", clear)
        self.assertNotIn("treo_live_owner_targets", clear)
        self.assertIn("treo_live_trim_textures_locked()", trim)
        self.assertIn("atomic_exchange_explicit(&treo_texture_trim_queued", trim)
        self.assertIn("dispatch_async", trim)
        self.assertNotIn("treo_live_owner_targets", trim)
        self.assertNotIn("jvm_destroy", trim)
        status = between(lib, "final class JarBoxStatusController:", "class AppsListViewController:")
        self.assertIn("ramAvailableLabel.text = JarBoxMemoryProtection.statusText()", status)


if __name__ == "__main__":
    unittest.main()
