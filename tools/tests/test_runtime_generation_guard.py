"""Host C check + source regression for immutable Java Runtime generations.

This does not run real miniJVM, UIKit, Metal or an NSO game.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
JVM = ROOT / "J2MEEmulator/minijvm/jvm"
NATIVE = ROOT / "J2MEEmulator/NativeBridge"

C = r"""
#include <stdint.h>
#include <stdio.h>
#include "jarbox_runtime_generation.h"
int main(void) {
    // The old and new MiniJVM both use the same address.
    const uintptr_t old_pointer = 0x1000, new_pointer = 0x1000;
    if (old_pointer != new_pointer) return 1;
    if (jarbox_runtime_generation_if_current(101, 202) != 0) return 2;
    if (jarbox_runtime_generation_if_current(202, 202) != 202) return 3;
    if (jarbox_runtime_generation_if_current(0, 202) != 0) return 4;
    if (jarbox_runtime_generation_if_current(101, 0) != 0) return 5;
    if (jarbox_runtime_generation_if_current(101, 101) != 101) return 6;
    puts("Runtime generation host guard: OK (recycled pointer, reject A / accept B)");
    return 0;
}
"""

class RuntimeGenerationGuardTest(unittest.TestCase):
    def test_compiled_generation_predicate(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if cc is None:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory(prefix="jarbox-generation-") as td:
            src = Path(td) / "generation.c"
            exe = Path(td) / "generation"
            src.write_text(C, encoding="utf-8")
            build = subprocess.run(
                [cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-I", str(JVM), str(src), "-o", str(exe)],
                capture_output=True, text=True, timeout=30)
            self.assertEqual(build.returncode, 0,
                             build.stdout + build.stderr)
            run = subprocess.run([str(exe)],
                                 capture_output=True, text=True, timeout=15)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn("Runtime generation host guard: OK", run.stdout)

    def test_root_snapshot_nested_frames_inherit(self):
        vm = (JVM / "jvm.h").read_text()
        runtime = (JVM / "runtime.c").read_text()
        util = (JVM / "jvm_util.h").read_text()
        garbage = (JVM / "garbage.h").read_text()
        self.assertIn("uint64_t jarbox_native_generation;", vm)
        self.assertIn("runtime->thrd_info->jarbox_native_generation =", runtime)
        self.assertIn("jarbox_native_heap_key_for_vm(jvm);", runtime)
        self.assertIn("runtime->thrd_info = parent->thrd_info;", util)
        self.assertIn("jarbox_native_heap_validate_key(runtime->jvm, original)", garbage)
        hot = garbage.split("static inline uint64_t jarbox_native_heap_key_for_runtime(", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("jarbox_native_heap_key_for_vm(", hot)
        source = (JVM / "garbage.c").read_text()
        validate = source.split("uint64_t jarbox_native_heap_validate_key(", 1)[1].split("\n}", 1)[0]
        self.assertIn("slot->owner == jvm && slot->key == key", validate)
        self.assertIn("spin_lock(&g_native_heap_lock)", validate)
        self.assertIn("spin_unlock(&g_native_heap_lock)", validate)

    def test_stale_runtime_denied_in_2d_ui_and_input(self):
        render = (NATIVE / "j2me_render.m").read_text()
        ui = (NATIVE / "j2me_ui.m").read_text()
        inputs = (NATIVE / "j2me_input.c").read_text()
        self.assertGreaterEqual(
            render.count("jarbox_native_heap_key_for_runtime(runtime)"), 30)
        self.assertNotIn("jarbox_native_heap_key_for_vm(runtime->jvm)", render)
        self.assertIn("? jarbox_native_heap_key_for_runtime(runtime) : 0;", ui)
        self.assertIn("if (!jarbox_native_heap_key_for_runtime(runtime) ||", ui)
        self.assertIn("static J2MEInputContext *context_for_runtime(", inputs)
        self.assertIn('#include "garbage.h"', inputs)
        self.assertGreaterEqual(inputs.count("context_for_runtime(runtime)"), 5)
        self.assertIn(
            "const int stale = !jarbox_native_heap_key_for_runtime(runtime);",
            inputs)

if __name__ == "__main__":
    unittest.main()
