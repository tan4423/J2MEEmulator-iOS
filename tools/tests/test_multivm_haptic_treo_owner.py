"""Host test for deferred haptic authorization, not CoreHaptics execution."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RENDER = ROOT / "J2MEEmulator/NativeBridge/j2me_render.m"
PRELUDE = r"""
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
static uint64_t visible_token, visible_key;
static int mode_a, mode_b, change_focus, visits;
static uint64_t jvm_bridge_visible_session_token(void) { return visible_token; }
static uint64_t j2me_render_visible_owner_key(void) { return visible_key; }
static int treo_mode_for_token(uint64_t token) {
    ++visits;
    if (change_focus) {
        visible_token = 22;
        visible_key = 202;
    }
    return token == 11 ? mode_a : token == 22 ? mode_b : -1;
}
"""
MAIN = r"""
int main(void) {
    for (int i = 0; i < 100; ++i) {
        visible_token = 11; visible_key = 101;
        mode_a = 0; mode_b = 8; change_focus = 0; visits = 0;
        assert(!render_haptic_can_deliver(0, 11));
        assert(!render_haptic_can_deliver(101, 0));
        assert(!render_haptic_can_deliver(202, 22));
        assert(!visits);
        assert(render_haptic_can_deliver(101, 11));
        assert(!render_haptic_can_deliver(999, 11));
        mode_a = 8;
        assert(!render_haptic_can_deliver(101, 11));
        mode_a = 1;
        assert(!render_haptic_can_deliver(101, 11));
        mode_a = -1;
        assert(!render_haptic_can_deliver(101, 11));
        mode_a = 0;
        change_focus = 1;
        assert(!render_haptic_can_deliver(101, 11));
        change_focus = 0;
        mode_b = 0; mode_a = 8;
        assert(render_haptic_can_deliver(202, 22));
        assert(!render_haptic_can_deliver(101, 11));
    }
    puts("haptic owner mode gate: OK");
    return 0;
}
"""


def harness(src):
    begin = src.index("static int render_haptic_can_deliver(")
    end = src.index("static s32 n_vibrate(", begin)
    return PRELUDE + src[begin:end] + MAIN


class HapticTreoOwnerTest(unittest.TestCase):
    def test_deferred_owner_mode_and_focus_gate(self):
        cc = shutil.which("cc") or shutil.which("clang")
        if not cc:
            self.skipTest("host C compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "haptic.c"
            exe = Path(td) / "haptic"
            source.write_text(harness(RENDER.read_text(encoding="utf-8")))
            subprocess.run([cc, "-std=c11", "-Wall", "-Wextra", "-Werror",
                            str(source), "-o", str(exe)], check=True, timeout=30)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("haptic owner mode gate: OK", result.stdout)

    def test_reset_handler_pins_engine_identity_on_main_queue(self):
        src = RENDER.read_text(encoding="utf-8")
        setup = src.split("static void ensureHapticEngine(void)", 1)[1].split("\n}", 1)[0]
        self.assertIn("__weak CHHapticEngine *resetEngine = g_hapticEngine;", setup)
        reset = setup.split("g_hapticEngine.resetHandler = ^{", 1)[1].split("\n    };", 1)[0]
        self.assertIn("dispatch_async(dispatch_get_main_queue(), ^{", reset)
        self.assertLess(reset.index("dispatch_async("), reset.index("CHHapticEngine *engine = resetEngine;"))
        self.assertLess(reset.index("if (!engine || engine != g_hapticEngine) return;"),
                        reset.index("[engine startAndReturnError:"))
        self.assertNotIn("[g_hapticEngine startAndReturnError:", reset)
        cleanup = src.split("void j2me_render_cleanup_for_owner(", 1)[1]
        self.assertLess(cleanup.index("g_hapticEngine.resetHandler = nil;"),
                        cleanup.index("[g_hapticEngine stopWithCompletionHandler:"))

    def test_main_queue_rechecks_owner_before_stop_and_start(self):
        src = RENDER.read_text(encoding="utf-8")
        body = src.split("static s32 n_vibrate(", 1)[1].split("\n}", 1)[0]
        self.assertNotIn("j2me_render_is_afk_suspended()", body)
        self.assertIn("__atomic_load_n(&runtime->jvm->session->token, __ATOMIC_ACQUIRE)", body)
        self.assertLess(body.index("const uint64_t token ="), body.index("dispatch_async("))
        queued = body.split("dispatch_async(", 1)[1]
        self.assertNotIn("runtime->", queued)
        guard = "if (!render_haptic_can_deliver(owner_key, token))"
        self.assertEqual(queued.count(guard), 2)
        self.assertLess(queued.index(guard), queued.index("[g_hapticPlayer stopAtTime:"))
        self.assertLess(queued.index("createPlayerWithPattern:"), queued.rindex(guard))
        self.assertLess(queued.rindex(guard), queued.index("[g_hapticPlayer startAtTime:"))


if __name__ == "__main__":
    unittest.main()
