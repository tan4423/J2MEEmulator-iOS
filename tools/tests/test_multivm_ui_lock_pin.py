"""Compile real MIDP screen lock/unlock entry points in a host C harness.

The harness simulates a UIKit focus change between lock and unlock. It does
not run Objective-C UIKit or real miniJVM threads on iOS.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "J2MEEmulator/NativeBridge/j2me_ui.m"

PREAMBLE = r"""
#include <stdatomic.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
typedef struct {
    pthread_mutex_t screen_lock;
    int id;
} JarBoxUIScreenContext;
static JarBoxUIScreenContext contexts[2];
static _Atomic int focused_index = 0;
static _Thread_local JarBoxUIScreenContext *g_ui_locked_context = NULL;
static JarBoxUIScreenContext *ui_context(void) {
    if (g_ui_locked_context) return g_ui_locked_context;
    return &contexts[atomic_load(&focused_index)];
}
"""

TEST = r"""
int main(void) {
    for (int i = 0; i < 2; ++i) {
        pthread_mutex_init(&contexts[i].screen_lock, NULL);
        contexts[i].id = i;
    }
    // UIKit takes screen A, but a game selection focuses screen B.
    atomic_store(&focused_index, 0);
    j2me_ui_lock_screen();
    if (g_ui_locked_context != &contexts[0]) return 1;
    atomic_store(&focused_index, 1);
    if (ui_context() != &contexts[0]) return 2;
    j2me_ui_unlock_screen();
    if (g_ui_locked_context != NULL) return 3;
    if (ui_context() != &contexts[1]) return 4;
    // Both mutexes must be free: old code unlocked B and left A locked.
    if (pthread_mutex_trylock(&contexts[0].screen_lock)) return 5;
    pthread_mutex_unlock(&contexts[0].screen_lock);
    if (pthread_mutex_trylock(&contexts[1].screen_lock)) return 6;
    pthread_mutex_unlock(&contexts[1].screen_lock);
    j2me_ui_unlock_screen(); // stray unlock must be harmless
    return 0;
}
"""

class MultiVMUILockPinTest(unittest.TestCase):
    def test_real_native_lock_unlock_pin_across_focus_change(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("C compiler unavailable")
        code = UI.read_text(encoding="utf-8")
        start = code.index("void j2me_ui_lock_screen(void) {")
        end = code.index("\nstatic s32 n_lockScreen(", start)
        production = code[start:end]
        self.assertIn("g_ui_locked_context = ctx;", production)
        self.assertIn("pthread_mutex_unlock(&ctx->screen_lock);", production)
        with tempfile.TemporaryDirectory(prefix="jarbox-ui-lock-pin-") as tmp:
            source = Path(tmp) / "test.c"
            executable = Path(tmp) / "test"
            source.write_text(PREAMBLE + "\n" + production + "\n" + TEST)
            subprocess.run(
                [cc, "-std=c11", "-Wall", "-Wextra", "-O2", "-pthread",
                 str(source), "-o", str(executable)],
                check=True, capture_output=True, text=True, timeout=45)
            subprocess.run([str(executable)], check=True,
                           capture_output=True, text=True, timeout=15)

    def test_focused_getters_stay_pinned_to_the_locked_screen(self):
        code = UI.read_text(encoding="utf-8")
        start = code.index("static JarBoxUIScreenContext *ui_context(void)")
        end = code.index("\nstatic void ui_bind_runtime(", start)
        body = code[start:end]
        self.assertIn("if (g_ui_locked_context)", body)
        self.assertIn("return g_ui_locked_context;", body)
        self.assertIn("jarbox_ui_generation_matches(", body)

if __name__ == "__main__":
    unittest.main()
