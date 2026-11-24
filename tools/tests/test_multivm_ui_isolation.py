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
        self.assertIn("ui_slot_for_vm(vm)", self.ui)
        self.assertIn("ui_register_vm(MiniJVM *vm)", self.ui)
        self.assertIn("j2me_ui_release_vm(MiniJVM *vm)", self.ui)
        self.assertIn("j2me_ui_focus_vm(MiniJVM *vm)", self.ui)
        self.assertIn("void j2me_ui_park_vm(MiniJVM *vm)", self.ui)
        self.assertIn("j2me_ui_park_vm(owner)", self.bridge)
        self.assertIn("if (!j2me_ui_reg_natives(slot->jvm))", self.bridge)
        self.assertIn("j2me_ui_release_vm(slot->jvm)", self.bridge)
        self.assertNotIn('static char g_form_title[256]', self.ui)

    def test_stale_java_call_cannot_inherit_focused_ui(self):
        self.assertIn("g_ui_thread_index = valid ? index : -2", self.ui)
        self.assertIn("if (index == -2) return &g_empty_ui_context", self.ui)
        self.assertIn("jarbox_ui_may_present(g_ui_thread_key, ui_focused_owner_key()", self.ui)
        self.assertIn("g_ui_new_session_revision", self.ui)
        self.assertIn("j2me_render_copy_image_for_vm(handle, runtime->jvm)", self.ui)

    def test_async_url_is_copied_before_java_string_free(self):
        source = self.ui
        before = source.index("NSString *urlString =")
        freed = source.index("utf8_destroy(u);", before)
        callback = source.index("dispatch_async(dispatch_get_main_queue()", freed)
        self.assertLess(before, freed)
        self.assertLess(freed, callback)
        self.assertIn("if (!urlString || !ui_is_focused_owner())", source)

    def test_generation_binding_survives_slot_reuse_and_park(self):
        self.assertIn("static _Thread_local uint64_t g_ui_thread_key = 0;", self.ui)
        self.assertIn("_Atomic uint64_t heap_key;", self.ui)
        self.assertIn("jarbox_ui_generation_matches(g_ui_thread_key, key)", self.ui)
        self.assertIn("jarbox_ui_generation_matches(key, slot_key)", self.ui)
        self.assertIn("atomic_store_explicit(&ctx->heap_key, 0, memory_order_release)", self.ui)
        self.assertIn("jarbox_ui_may_present(owner_key, ui_focused_owner_key()", self.ui)

    def test_queued_platform_request_rechecks_owner_on_main_queue(self):
        source = self.ui
        begin = source.index("static s32 n_platformRequest(")
        end = source.index("// Native method table", begin)
        body = source[begin:end]
        self.assertIn("const uint64_t ownerKey = g_ui_thread_key;", body)
        self.assertIn("dispatch_async(dispatch_get_main_queue(), ^{", body)
        self.assertIn("jarbox_ui_may_present(ownerKey, ui_focused_owner_key()", body)
        self.assertLess(body.index("dispatch_async("), body.index("jarbox_ui_may_present("))

    def test_owned_midp_ui_callback_survives_async_focus_switch(self):
        game = (ROOT / "J2MEEmulator/UI/GameViewController.swift").read_text(encoding="utf-8")
        header = (ROOT / "J2MEEmulator/NativeBridge/j2me_ui.h").read_text(encoding="utf-8")
        self.assertIn("j2me_ui_callback_owned", header)
        self.assertIn("ui_publish_action(int action, int revision, uint64_t owner_key)", self.ui)
        self.assertIn("g_ui_thread_key", self.ui)
        self.assertIn("j2me_ui_set_owned_callback(ownedGameUICallback)", game)
        self.assertIn("let ownedGameUICallback: @convention(c)", game)
        self.assertIn("j2me_render_visible_owner_key() == ownerKey", game)
        self.assertIn("j2me_ui_focused_owner_key() == ownerKey", game)
        self.assertIn("uint64_t j2me_ui_focused_owner_key(void)", header)
        self.assertIn("guard revision == j2me_ui_revision()", game)

    def test_lcdui_callback_cannot_migrate_to_recycled_generation(self):
        self.assertIn("j2me_ui_callback_owned owned_ui_callback;", self.ui)
        self.assertIn("ctx->owned_ui_callback = g_owned_ui_callback;", self.ui)
        self.assertIn("ctx->owned_ui_callback = NULL;", self.ui)
        self.assertIn("owner_key == atomic_load_explicit(&ctx->heap_key", self.ui)
        self.assertIn("owned(action, revision, owner_key);", self.ui)
        self.assertIn("legacy && jvm_bridge_supported_concurrent_sessions() == 1", self.ui)
        self.assertIn("pthread_mutex_lock(&g_ui_contexts_lock);", self.ui)

    def test_not_claiming_full_multi(self):
        # UIKit presentation callback still needs token-scoped dispatch,
        # as do the global render and Smart Treo modes.
        self.assertIn("static j2me_ui_callback g_ui_callback = NULL", self.ui)
        self.assertIn("(unsigned)jvm_bridge_supported_concurrent_sessions()",
                      self.bridge)


if __name__ == "__main__":
    unittest.main()
