"""Ensure multi-JVM remains gated until mutable native resources are isolated."""
import sys
from tempfile import TemporaryDirectory
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from multivm_readiness import FILES, audit


class MultiVMReadinessTest(unittest.TestCase):
    def test_implemented_isolation_and_real_blockers(self):
        report = audit()
        self.assertTrue(report["owned_native_components"]["vm_lifecycle"])
        self.assertTrue(report["owned_native_components"]["input_queue_display_wait"])
        self.assertTrue(report["owned_native_components"]["wav_midi_players"])
        self.assertTrue(report["owned_native_components"]["lcd_ui_screen_buffers"])
        self.assertTrue(report["owned_native_components"]["gc_native_graphics_accounting"])
        self.assertTrue(report["owned_native_components"]["treo_gc_afk_state"])
        self.assertTrue(report["enforced_single_active_jvm"])
        self.assertFalse(report["concurrent_jvms_safe_to_enable"])
        bridge = (ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        ui = (ROOT / "J2MEEmulator/UI/AppsListViewController.swift").read_text()
        self.assertIn('int jvm_bridge_supported_concurrent_sessions(void) {\n    return 1;', bridge)
        self.assertIn('jvm_bridge_active_session_count()', ui)
        self.assertIn('jvm_bridge_supported_concurrent_sessions()', ui)
        blockers = report["unisolated_native_blockers"]
        self.assertNotIn("lcd_ui_single_form_state", blockers)
        self.assertNotIn("gc_single_native_memory_account", blockers)
        self.assertNotIn("gc_single_smart_treo_scheduler", blockers)
        self.assertNotIn("render_global_stop_and_cleanup", blockers)
        self.assertNotIn("render_global_stop_barrier", blockers)
        self.assertNotIn("render_raw_unscoped_handle_acquire", blockers)
        # Frame callbacks are now captured in the generation-scoped
        # JarBoxFlushRoutes registry, not the old singleton pointer.
        self.assertNotIn("render_single_flush_callback", blockers)
        render = (ROOT / "J2MEEmulator/NativeBridge/j2me_render.m").read_text()
        routes = (ROOT / "J2MEEmulator/NativeBridge/jarbox_flush_routes.h").read_text()
        self.assertIn("jarbox_flush_route_lookup(&g_flush_routes, callerKey", render)
        self.assertIn("jarbox_flush_route_unbind(&g_flush_routes, owner_key)", render)
        self.assertIn("JARBOX_FLUSH_MAX_ROUTES", routes)
        for item in (
            "render_shared_metal_workspace",
            "render_global_haptic_teardown",
            "lcd_ui_single_callback",
            "treo_single_global_mode",
            "3d_single_supersampling",
            "3d_global_m3g_cleanup",
        ):
            with self.subTest(blocker=item):
                self.assertTrue(blockers[item])

    def test_source_gate_requires_treo_and_owner_safe_m3g_cleanup(self):
        # Synthetic source fixture: every existing ownership predicate passes,
        # with no other known blocker. This tests the gate, not native safety.
        snippets = {
            "lifecycle": """typedef struct { JarBoxVMContext
                g_bridge_slots[JARBOX_REGISTRY_MAX_SLOTS]
                bridge_claim_worker_locked slot->stop_requested
                jvm_bridge_is_stop_requested_for_vm""",
            "input": """JarBoxInputRing ring; context_for_runtime(runtime)
                j2me_input_binding_generation j2me_input_release_vm
                #include "garbage.h"
                """,
            "audio": """g_audio_owners g_midi_owners
                j2me_audio_stop_for_vm(MiniJVM *vm)
                audio_owned_by_vm(runtime->jvm j2me_input_post_key_to_vm""",
            "lcd_ui": """JarBoxUIScreenContext ui_slot_for_vm(vm)
                j2me_ui_release_vm(MiniJVM *vm) j2me_ui_focus_vm(MiniJVM *vm)
                g_ui_thread_key = valid ? key : 0;
                jarbox_ui_generation_matches(key, slot_key)
                jarbox_native_heap_key_for_runtime(runtime)""",
            "gc": """jarbox_native_heap_register_vm(MiniJVM *jvm)
                jarbox_native_heap_for_vm(collector->jvm) slot->key == key
                jarbox_treo_smart_period(&jvm->session->treo_state)
                jarbox_treo_probe_period(&jvm->session->treo_state)
                jvm_bridge_visit_running_vm""",
            "render": """uint64_t heap_key; jarbox_native_heap_key_for_vm(owner)
                native_heap_sub(rc->heap_key, pixels)
                jarbox_native_heap_key_for_runtime(runtime)
                treo_apply_mode_locked(vm, change->mode, change->now_ns);
                jarbox_treo_smart_set(state, mode == 8);""",
            "runtime": "runtime->thrd_info->jarbox_native_generation",
            "vm": "uint64_t jarbox_native_generation; JarBoxSession *session;",
            "session": "JarBoxTreoState treo_state;",
        }
        with TemporaryDirectory() as td:
            root = Path(td)
            for label, content in snippets.items():
                path = root / FILES[label]
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            baseline = audit(root)
            self.assertTrue(baseline["source_prerequisites_met"])
            self.assertFalse(baseline["concurrent_jvms_safe_to_enable"])
            session = root / FILES["session"]
            session.write_text("", encoding="utf-8")
            missing_treo = audit(root)
            self.assertFalse(missing_treo["owned_native_components"]["treo_gc_afk_state"])
            self.assertFalse(missing_treo["source_prerequisites_met"])
            session.write_text(snippets["session"], encoding="utf-8")
            bridge = root / FILES["lifecycle"]
            bridge.write_text(snippets["lifecycle"] + "\nj2me_m3g_cleanup();", encoding="utf-8")
            shared_cleanup = audit(root)
            self.assertTrue(shared_cleanup["unisolated_native_blockers"]["3d_global_m3g_cleanup"])
            self.assertFalse(shared_cleanup["source_prerequisites_met"])
            bridge.write_text(snippets["lifecycle"] + "\nj2me_m3g_cleanup_for_owner(key);", encoding="utf-8")
            owned_cleanup = audit(root)
            self.assertNotIn("3d_global_m3g_cleanup", owned_cleanup["unisolated_native_blockers"])
            self.assertTrue(owned_cleanup["source_prerequisites_met"])
            self.assertFalse(owned_cleanup["concurrent_jvms_safe_to_enable"])

    def test_audit_does_not_claim_runtime_proof(self):
        report = audit()
        self.assertTrue(report["verified_source_structure_only"])
        self.assertFalse(report["runtime_device_concurrency_validated"])
        self.assertFalse(report["concurrent_jvms_safe_to_enable"])
        self.assertIn("Input contexts (capacity four) are not four working JVM sessions.",
                      report["notes"])
        # The audit wording evolves as raster/Metal ownership is improved.
        # Check the actual safety disclosures, not a frozen sentence fragment.
        self.assertTrue(any(
            "2D" in note and "handle" in note and "generation" in note
            for note in report["notes"]
        ))
        self.assertTrue(any(
            "Metal" in note and "shared" in note
            for note in report["notes"]
        ))


if __name__ == "__main__":
    unittest.main()
