"""Guard every native owner table against a smaller hidden session limit."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "J2MEEmulator"


class MultiVMCapacityTest(unittest.TestCase):
    def test_owner_tables_cover_technical_ceiling(self):
        tables = (
            ("NativeBridge/jarbox_session_registry.h", "JARBOX_REGISTRY_MAX_SLOTS"),
            ("NativeBridge/jarbox_focus_policy.h", "JARBOX_FOCUS_MAX_SESSIONS"),
            ("NativeBridge/j2me_input.c", "JARBOX_INPUT_CONTEXT_CAPACITY"),
            ("NativeBridge/j2me_ui.m", "JARBOX_UI_CONTEXT_CAPACITY"),
            ("NativeBridge/jarbox_flush_routes.h", "JARBOX_FLUSH_MAX_ROUTES"),
            ("NativeBridge/j2me_render.m", "RENDER_STOP_OWNER_SLOTS"),
            ("minijvm/jvm/garbage.c", "JARBOX_NATIVE_HEAP_SLOTS"),
        )
        for path, name in tables:
            with self.subTest(table=name):
                match = re.search(r"^#define " + name + r" (\d+)\b", (ROOT / path).read_text(), re.M)
                self.assertIsNotNone(match)
                self.assertEqual(int(match.group(1)), 64)
        bridge = (ROOT / "NativeBridge/jvm_bridge.c").read_text()
        self.assertIn("return JARBOX_REGISTRY_MAX_SLOTS;", bridge)
        self.assertLess(64, 256)  # generation key reserves the low eight bits for slot index
        self.assertIn("maxTotalTabs = 30", (ROOT / "UI/AppsListViewController.swift").read_text())


if __name__ == "__main__":
    unittest.main()
