"""Source regression checks for delayed Swift UI actions (not iPhone runtime proof)."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / "J2MEEmulator/UI/GameViewController.swift"

def between(s, begin, end):
    return s[s.index(begin):s.index(end, s.index(begin))]

class SessionCallbackOwnershipTest(unittest.TestCase):
    def setUp(self):
        self.swift = SWIFT.read_text(encoding="utf-8")

    def test_midp_main_queue_requires_original_owner_and_token(self):
        callback = between(
            self.swift, "private func dispatchMIDPScreenAction(",
            "\nlet gameUICallback:")
        self.assertIn("guard ownerKey != 0 else { return }", callback)
        self.assertNotIn("let sourceToken = jvm_bridge_session_token()", callback)
        self.assertIn("vc.ownsVisibleGameSession()", callback)
        self.assertIn("jvm_bridge_visible_session_token() == gameSessionToken", self.swift)
        self.assertIn("j2me_ui_focused_owner_key() == ownerKey", callback)
        self.assertIn("j2me_render_visible_owner_key() == ownerKey", callback)
        self.assertIn("vc.ownsVisibleGameSession()", callback)
        self.assertNotIn("ownerKey == 0 ||", callback)

    def test_alert_action_and_timeout_reject_stale_session(self):
        alert = between(self.swift, "    func showAlert() {", "\n}\n\n// MARK: - Game UI callback")
        self.assertIn("let originToken = gameSessionToken", alert)
        self.assertLess(alert.index("if libraryIsPresented"),
                        alert.index("let originKey = j2me_ui_focused_owner_key()"))
        self.assertIn("self.gameSessionToken == originToken", alert)
        self.assertIn("jvm_bridge_visible_session_token() == originToken", alert)
        self.assertIn("jvm_bridge_session_is_active_for_token(originToken)", alert)
        self.assertIn("j2me_ui_focused_owner_key() == originKey", alert)
        self.assertIn("j2me_render_visible_owner_key() == originKey", alert)
        self.assertIn("j2me_ui_revision() == revision", alert)
        # An OK action, each command, and both timeout stages check identity.
        self.assertGreaterEqual(alert.count("guard canDeliver() else { return }"), 4)

    def test_async_worker_teardown_never_resets_foreign_treo(self):
        code = self.swift
        self.assertIn("let launchingToken = gameSessionToken", code)
        self.assertIn("self.gameSessionToken == launchingToken", code)
        self.assertIn("let mayResetNative = currentToken == 0 ||", code)
        self.assertIn("if !mayResetNative {", code)
        self.assertIn("jvm_bridge_session_token() == gameSessionToken &&", code)
        self.assertIn("activeGameViewController === self &&", code)

if __name__ == "__main__":
    unittest.main()
