"""LCDUI owner routing regressions (source checks; not an iPhone simulation)."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / "J2MEEmulator/NativeBridge/j2me_ui.m"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c"


class MultiVMUIIsolationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ui = UI.read_text(encoding="utf-8")
        cls.bridge = BRIDGE.read_text(encoding="utf-8")

    def test_form_list_alert_state_is_vm_owned(self):
        for member in ("form_title[256]", "form_items[MAX_FORM_ITEMS]",
                       "form_item_count", "list_items[MAX_FORM_ITEMS][256]",
                       "alert_text[1024]", "screen_revision", "pendingText"):
            with self.subTest(member=member):
                self.assertIn(member, self.ui)
        self.assertIn("JarBoxUIScreenContext", self.ui)
        self.assertIn("ui_slot_for_vm(runtime ? runtime->jvm : NULL)", self.ui)
        self.assertIn("ui_register_vm(MiniJVM *vm)", self.ui)
        self.assertIn("j2me_ui_release_vm(MiniJVM *vm)", self.ui)
        self.assertIn("j2me_ui_focus_vm(MiniJVM *vm)", self.ui)
        self.assertIn("if (!j2me_ui_reg_natives(g_bridge_vm.jvm))", self.bridge)
        self.assertIn("j2me_ui_release_vm(g_bridge_vm.jvm)", self.bridge)
        self.assertNotIn('static char g_form_title[256]', self.ui)

    def test_stale_java_call_cannot_inherit_focused_ui(self):
        self.assertIn("g_ui_thread_index = index >= 0 ? index : -2", self.ui)
        self.assertIn("if (index == -2) return &g_empty_ui_context", self.ui)
        self.assertIn("ui_is_focused_owner() && g_ui_callback", self.ui)
        self.assertIn("g_ui_new_session_revision", self.ui)

    def test_async_url_is_copied_before_java_string_free(self):
        source = self.ui
        before = source.index("NSString *urlString =")
        freed = source.index("utf8_destroy(u);", before)
        callback = source.index("dispatch_async(dispatch_get_main_queue()", freed)
        self.assertLess(before, freed)
        self.assertLess(freed, callback)
        self.assertIn("if (!urlString || !ui_is_focused_owner())", source)

    def test_not_claiming_full_multi(self):
        # UIKit presentation callback still needs token-scoped dispatch,
        # as do the global render and Smart Treo modes.
        self.assertIn("static j2me_ui_callback g_ui_callback = NULL", self.ui)
        self.assertIn("atomic_compare_exchange_strong_explicit(&g_bridge_vm.active",
                      self.bridge)


if __name__ == "__main__":
    unittest.main()
