"""Source contract for cancelable startup and animation-free game exit."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"


class GameStartStopUITest(unittest.TestCase):
    def setUp(self):
        self.src = GAME.read_text(encoding="utf-8")

    def test_minimize_never_cancels_startup_and_close_can_cancel(self):
        body = self.src.split("@objc private func openLibraryKeepingGame() {", 1)[1].split("\n    }", 1)[0]
        self.assertLess(body.index("if startupWatchdog != nil { return }"),
                        body.index("treo_mode_for_token(gameSessionToken)"))
        self.assertNotIn("requestGameStop(", body)
        self.assertIn('if gameStopRequested {\n            showStuckSessionRecovery()', body)
        self.assertIn('guard ownsJVMSession else {', body)
        self.assertIn('dismissEndedGame()', body)
        close = self.src.split("@objc private func closeTabTapped() {", 1)[1].split("\n    }", 1)[0]
        self.assertIn('requestGameStop(reason: "close_tab")', close)

    def test_close_has_no_game_dismissal_animation(self):
        self.assertNotRegex(self.src, r'(?m)^\s*(?:self\??\.)?dismiss\(animated: true\)')

    def test_startup_cancel_and_stop_labels(self):
        self.assertIn('closeTabButton.accessibilityLabel = "Hủy khởi động game"', self.src)
        self.assertIn('closeTabButton.accessibilityLabel = "Đang dừng game"', self.src)
        self.assertIn('backButton.isEnabled = false', self.src)
        finish = self.src.split("private func finishStartupWatchdog() {", 1)[1].split("\n    }", 1)[0]
        self.assertIn('if !gameStopRequested {', finish)
        self.assertIn('backButton.isEnabled = true', finish)
        self.assertIn('closeTabButton.accessibilityLabel = "Dừng tab"', finish)

    def test_worker_checks_cancel_before_storage_and_init(self):
        start = self.src.index('defer { _ = jvm_bridge_finish_session_for_token(token) }')
        worker = self.src[start:]
        check = 'guard jvm_bridge_is_stop_requested_for_token(token) == 0 else { return "Game startup cancelled." }'
        first = worker.index(check)
        second = worker.index(check, first + len(check))
        self.assertLess(first, worker.index('let docs = NSSearchPathForDirectoriesInDomains('))
        self.assertLess(second, worker.index('let initResult = jvm_bridge_init_for_token('))

    def test_stale_alert_does_not_cancel_startup_watchdog(self):
        body = self.src.split('func showAlert() {', 1)[1].split('\n    }', 1)[0]
        self.assertLess(body.index('guard ownsLiveGameSession() else { return }'),
                        body.index('finishStartupWatchdog()'))


if __name__ == "__main__":
    unittest.main()
