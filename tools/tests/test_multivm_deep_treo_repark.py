"""Host policy regression: a late Canvas failure is sticky for one JVM."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "J2MEEmulator/minijvm/jvm/jarbox_treo_state.h"
C = r"""
#include <assert.h>
#include <stddef.h>
#include "jarbox_treo_state.h"

static void recognize(JarBoxTreoState *s) {
    jarbox_treo_nso_profile_set(s, 1, 1);
    jarbox_treo_nso_canvas_note(s);
}

int main(void) {
    JarBoxTreoState a = {0}, b = {0}, restarted = {0};
    recognize(&a);
    recognize(&b);
    assert(jarbox_treo_park_mode(&a, 0) == 8);
    assert(jarbox_treo_park_mode(&b, 0) == 8);
    jarbox_treo_guard_auto_set(&a, 1);
    jarbox_treo_render_mode_set(&a, 8, 1);
    assert(jarbox_treo_guard_note_late(&a));
    jarbox_treo_render_mode_set(&a, 1, 2);
    jarbox_treo_guard_auto_set(&a, 0);
    jarbox_treo_render_mode_set(&a, 0, 3);
    /* A later positive Canvas observation cannot undo a known failure. */
    jarbox_treo_nso_canvas_note(&a);
    for (int i = 0; i < 100; ++i) {
        assert(jarbox_treo_park_mode(&a, 0) == 1);
        assert(jarbox_treo_park_mode(&a, 1) == 1);
        assert(jarbox_treo_park_mode(&b, 0) == 8);
        jarbox_treo_guard_auto_set(&a, 0);
        jarbox_treo_render_mode_set(&a, 1, 4);
        jarbox_treo_render_mode_set(&a, 0, 5);
    }
    /* Rearming a legacy diagnostic does not erase automatic rejection. */
    jarbox_treo_guard_auto_set(&a, 1);
    assert(jarbox_treo_park_mode(&a, 0) == 1);
    assert(jarbox_treo_park_mode(&b, 0) == 8);
    assert(jarbox_treo_park_mode(&restarted, 0) == 1);
    recognize(&restarted);
    assert(jarbox_treo_park_mode(&restarted, 0) == 8);
    assert(jarbox_treo_park_mode(NULL, 0) == 1);
    return 0;
}
"""


class DeepTreoReparkTest(unittest.TestCase):
    def test_late_canvas_failure_is_not_rearmed_by_back(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "repark.c"
            exe = Path(td) / "repark"
            source.write_text(C, encoding="utf-8")
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            "-I", str(HEADER.parent), str(source), "-o", str(exe)],
                           check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
