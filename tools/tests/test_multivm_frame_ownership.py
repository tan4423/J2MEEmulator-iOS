"""Prevent cross-tab Canvas frames both at native submit and UIKit drain.

This is a source-contract test, not proof of running two live miniJVMs.
The ownership guard runs *before* calling a native callback and *after*
an asynchronously queued image reaches the main thread.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / "J2MEEmulator/NativeBridge/j2me_render.m"
HEADER = ROOT / "J2MEEmulator/NativeBridge/j2me_render.h"
VIEW = ROOT / "J2MEEmulator/UI/EmulatorView.swift"
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"


class MultiVMFrameOwnershipTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.render = NATIVE.read_text(encoding="utf-8")
        cls.header = HEADER.read_text(encoding="utf-8")
        cls.view = VIEW.read_text(encoding="utf-8")
        cls.game = GAME.read_text(encoding="utf-8")
        cls.bridge = BRIDGE.read_text(encoding="utf-8")

    def test_render_gate_identifies_the_actual_jvm_and_canvas(self):
        for needle in (
            "g_visible_render_owner_key",
            "j2me_render_focus_vm(MiniJVM *vm)",
            "j2me_render_release_vm(MiniJVM *vm)",
            "jarbox_native_heap_key_for_vm(runtime->jvm)",
            "callerKey != rc->heap_key",
            "callerKey != visibleKey",
            "g_owned_flush_callback(image, rc->width, rc->height, rc->heap_key)",
        ):
            self.assertIn(needle, self.render)
        self.assertIn("j2me_render_release_vm(g_bridge_vm.jvm)", self.bridge)

    def test_pending_frame_keeps_its_own_vm_key(self):
        self.assertIn("private var pending: (image: CGImage, ownerKey: UInt64)?",
                      self.view)
        self.assertIn("func submit(_ frame: CGImage, ownerKey: UInt64)", self.view)
        self.assertIn("func take() -> (image: CGImage, ownerKey: UInt64)?",
                      self.view)
        self.assertIn("j2me_render_visible_owner_key() == frame.ownerKey", self.view)
        self.assertIn("j2me_render_visible_owner_key() == ownerKey", self.view)
        self.assertIn("self.layer.contents = frame.image", self.view)
        self.assertIn("j2me_render_set_owned_flush_callback(ownedFlushCallback)",
                      self.game)
        self.assertIn("j2me_flush_callback_owned", self.header)

    def test_old_unowned_callback_is_not_used_for_game_frames(self):
        match = re.search(r'if \(image\) \{(.*?)\n        \}', self.render[
            self.render.index("static s32 n_flushToScreen"):], re.DOTALL)
        self.assertIsNotNone(match)
        block = match.group(1)
        self.assertIn("if (g_owned_flush_callback)", block)
        self.assertIn("else", block)
        self.assertLess(block.index("g_owned_flush_callback(image,"),
                        block.index("g_flush_callback(image,"))
        # The legacy callback may remain in source for compatibility,
        # but the owner-aware callback is installed by every GameVC.
        self.assertIn("let ownedFlushCallback: @convention(c)", self.view)


if __name__ == "__main__":
    unittest.main()
