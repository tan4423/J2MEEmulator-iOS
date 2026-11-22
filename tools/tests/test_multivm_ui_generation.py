"""Test MIDP UIKit generation gating with the actual production C policy.

This runs on a host C compiler and is NOT a miniJVM/iPhone concurrency test.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "J2MEEmulator" / "NativeBridge"
UI = NATIVE / "j2me_ui.m"

C_TEST = r"""
#include <stdint.h>
#include <stdlib.h>
#include <pthread.h>
#include "jarbox_ui_generation.h"

typedef struct {
    uint64_t old_key, new_key;
    int errors;
} Args;

static void *stress(void *arg) {
    Args *a = (Args *)arg;
    for (int i = 0; i < 100000; ++i) {
        if (!jarbox_ui_generation_matches(a->new_key, a->new_key)) ++a->errors;
        if (jarbox_ui_generation_matches(a->old_key, a->new_key)) ++a->errors;
        if (jarbox_ui_may_present(a->old_key, a->new_key, a->new_key)) ++a->errors;
        if (!jarbox_ui_may_present(a->new_key, a->new_key, a->new_key)) ++a->errors;
        if (jarbox_ui_may_present(a->new_key, a->new_key, 0)) ++a->errors;
    }
    return NULL;
}

int main(void) {
    // Same numeric slot, different native VM generation after restart.
    if (jarbox_ui_generation_matches(101, 202)) return 1;
    if (jarbox_ui_generation_matches(0, 0)) return 2;
    if (jarbox_ui_may_present(101, 202, 202)) return 3;
    if (jarbox_ui_may_present(101, 101, 0)) return 4; // parked
    if (jarbox_ui_may_present(101, 101, 202)) return 5; // focus switched
    if (!jarbox_ui_may_present(202, 202, 202)) return 6;
    Args args[4] = {
        {101, 202, 0}, {202, 303, 0}, {303, 404, 0}, {404, 505, 0}
    };
    pthread_t threads[4];
    for (int i = 0; i < 4; ++i)
        if (pthread_create(&threads[i], NULL, stress, &args[i])) return 7;
    for (int i = 0; i < 4; ++i) {
        pthread_join(threads[i], NULL);
        if (args[i].errors) return 8;
    }
    return 0;
}
"""

class MultiVMUIGenerationTest(unittest.TestCase):
    def test_compiled_generation_checks_reject_stale_tabs(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("C compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-ui-generation-") as tmp:
            src = Path(tmp) / "policy.c"
            binary = Path(tmp) / "policy"
            src.write_text(C_TEST, encoding="utf-8")
            subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-pthread",
                 "-I", str(NATIVE), str(src), "-o", str(binary)],
                check=True, capture_output=True, text=True, timeout=45)
            subprocess.run(
                [str(binary)], check=True, capture_output=True,
                text=True, timeout=15)

    def test_real_bridge_binds_keys_and_checks_queued_browser_action(self):
        code = UI.read_text(encoding="utf-8")
        self.assertIn('#include "jarbox_ui_generation.h"', code)
        self.assertIn("g_ui_thread_key = valid ? key : 0;", code)
        self.assertIn("jarbox_ui_generation_matches(g_ui_thread_key, key)", code)
        self.assertIn("jarbox_ui_may_present(owner_key, ui_focused_owner_key()", code)
        request = code[code.index("static s32 n_platformRequest("):
                       code.index("// Native method table", code.index("static s32 n_platformRequest("))]
        self.assertIn("const uint64_t ownerKey = g_ui_thread_key;", request)
        self.assertIn("jarbox_ui_may_present(ownerKey, ui_focused_owner_key()", request)

if __name__ == "__main__":
    unittest.main()
