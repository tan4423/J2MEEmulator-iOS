"""Source-structure guards for JarBox's first-stage parked game UI.

The Codemagic Xcode build performs type checking; these tests ensure a future
refactor does not silently reintroduce unsafe double-JVM startup or turn the
Back button into a destructive stop. No simulator or game JAR is executed.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"
LIBRARY = ROOT / "J2MEEmulator/UI/AppsListViewController.swift"
CELL = ROOT / "J2MEEmulator/UI/SpringboardCell.swift"
BRIDGE = ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.h"


class ParkedGameLibraryTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.game = GAME.read_text(encoding="utf-8")
        cls.library = LIBRARY.read_text(encoding="utf-8")
        cls.cell = CELL.read_text(encoding="utf-8")
        cls.bridge = BRIDGE.read_text(encoding="utf-8")

    def test_back_is_non_destructive_and_menu_stop_is_explicit(self):
        back = re.search(
            r'@objc private func backTapped\(\)\s*\{(.*?)\n    \}',
            self.game, re.DOTALL,
        )
        self.assertIsNotNone(back)
        self.assertIn('openLibraryKeepingGame()', back.group(1))
        self.assertNotIn('requestGameStop', back.group(1))
        self.assertIn('requestGameStop(reason: "menu_stop")', self.game)
        self.assertIn('requestGameStop(reason: "library_stop")', self.game)

    def test_native_token_still_guards_single_vm(self):
        self.assertIn('jvm_bridge_try_begin_session()', self.game)
        self.assertIn('jvm_bridge_session_token() == gameSessionToken', self.game)
        self.assertIn('jvm_bridge_session_is_active()', self.game)
        self.assertIn('jvm_bridge_request_stop_for_token(token)', self.game)
        self.assertIn('extern int g_render_3d_scale;', self.bridge)
        self.assertIn('jvm_bridge_try_begin_session(void)', self.bridge)

    def test_offscreen_presentation_is_detached_and_restored(self):
        self.assertIn('setGlobalEmulatorView(nil)', self.game)
        self.assertIn('emulatorView.clearPendingGameFrame()', self.game)
        self.assertIn('j2me_render_set_afk_suspended(1)', self.game)
        self.assertIn('setGlobalEmulatorView(self.emulatorView)', self.game)
        self.assertIn('j2me_render_set_afk_suspended(0)', self.game)
        self.assertIn('libraryIsPresented', self.game)
        self.assertIn('overlay.dismiss(animated: false)', self.game)
        self.assertIn('JarBoxLibraryNavigationController(rootViewController: library)', self.game)

    def test_library_shows_running_state_and_blocks_second_game(self):
        self.assertIn('weak var parkedGameController: GameViewController?', self.library)
        self.assertIn('parked.ownsLiveGameSession()', self.library)
        self.assertIn('showAnotherGameBlocked(app)', self.library)
        self.assertIn('resumeParkedGame()', self.library)
        self.assertIn('stopParkedGame()', self.library)
        self.assertIn('running: parkedGameController?.ownsLiveGameSession(for: app.path)', self.library)
        self.assertIn('liveDot.isHidden = !running', self.cell)
        self.assertIn('accessibilityValue = running', self.cell)
        self.assertIn('navigationItem.rightBarButtonItems = [importBarButton, stop].compactMap', self.library)
        self.assertIn('action: #selector(stopRunningGameFromLibrary)', self.library)
        self.assertIn('if parkedGameController?.ownsLiveGameSession(for: destURL.path) == true', self.library)
        self.assertIn('action: #selector(openStuckSessionRecovery)', self.library)
        self.assertIn('attributes: isRunning ? [.destructive, .disabled]', self.library)

    def test_does_not_claim_ios_background_execution(self):
        self.assertIn('does not grant iOS background execution', self.game)


if __name__ == "__main__":
    unittest.main()
