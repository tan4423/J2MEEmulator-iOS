"""Ensure multi-JVM remains gated until mutable native resources are isolated."""
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
from multivm_readiness import audit


class MultiVMReadinessTest(unittest.TestCase):
    def test_implemented_isolation_and_real_blockers(self):
        report = audit()
        self.assertTrue(report["owned_native_components"]["vm_lifecycle"])
        self.assertTrue(report["owned_native_components"]["input_queue_display_wait"])
        self.assertTrue(report["owned_native_components"]["wav_midi_players"])
        self.assertTrue(report["owned_native_components"]["lcd_ui_screen_buffers"])
        self.assertTrue(report["enforced_single_active_jvm"])
        self.assertFalse(report["concurrent_jvms_safe_to_enable"])
        bridge = (ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        ui = (ROOT / "J2MEEmulator/UI/AppsListViewController.swift").read_text()
        self.assertIn('int jvm_bridge_supported_concurrent_sessions(void) {\n    return 1;', bridge)
        self.assertIn('jvm_bridge_active_session_count()', ui)
        self.assertIn('jvm_bridge_supported_concurrent_sessions()', ui)
        blockers = report["unisolated_native_blockers"]
        self.assertNotIn("lcd_ui_single_form_state", blockers)
        for item in (
            "render_single_flush_callback",
            "lcd_ui_single_callback",
            "treo_single_global_mode",
            "gc_single_native_memory_account",
            "3d_single_supersampling",
        ):
            with self.subTest(blocker=item):
                self.assertTrue(blockers[item])

    def test_audit_does_not_claim_runtime_proof(self):
        report = audit()
        self.assertTrue(report["verified_source_structure_only"])
        self.assertIn("Input contexts (capacity four) are not four working JVM sessions.",
                      report["notes"])


if __name__ == "__main__":
    unittest.main()
