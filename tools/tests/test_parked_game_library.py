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
        self.assertIn('jvm_bridge_try_begin_session_with_token(&acquiredToken)', self.game)
        self.assertIn('gameSessionToken = acquiredToken', self.game)
        self.assertIn('cloneID: instanceCloneID, token: launchingToken', self.game)
        self.assertIn('jvm_bridge_init_for_token(token, resRoot, saveRoot', self.game)
        self.assertIn('jvm_bridge_run_midlet_for_token(token, jarPath)', self.game)
        self.assertIn('jvm_bridge_destroy_for_token(token)', self.game)
        self.assertIn('jvm_bridge_finish_session_for_token(token)', self.game)
        self.assertIn('jvm_bridge_session_token() == gameSessionToken', self.game)
        self.assertIn('jvm_bridge_session_is_active()', self.game)
        self.assertIn('jvm_bridge_request_stop_for_token(token)', self.game)
        self.assertIn('extern int g_render_3d_scale;', self.bridge)
        self.assertIn('jvm_bridge_try_begin_session(void)', self.bridge)
        self.assertIn('int jvm_bridge_try_begin_session_with_token(uint64_t *out_token)', self.bridge)
        # The header verifies the public ABI; worker implementation is C.
        implementation = (ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c").read_text(encoding="utf-8")
        self.assertIn('static JarBoxVMContext *bridge_claim_worker(uint64_t token)', implementation)
        self.assertIn('if (!slot) return -10;', implementation)
        self.assertIn('bridge_release_worker(slot);', implementation)

    def test_automatic_treo_on_library_transition(self):
        self.assertIn('setGlobalEmulatorView(nil)', self.game)
        self.assertIn('emulatorView.clearPendingGameFrame()', self.game)
        self.assertIn('startParkedTreo()', self.game)
        renderer = (ROOT / "J2MEEmulator/NativeBridge/j2me_render.m").read_text(encoding="utf-8")
        self.assertIn('JarBoxGameStorage.treoCompatibleOnly(for: jarPath)', self.game)
        self.assertIn('treo_park_begin_for_token(gameSessionToken, compatibleOnly ? 1 : 0)', self.game)
        self.assertIn('treo_park_end_for_token(gameSessionToken)', self.game)
        self.assertIn('treo_mode_for_token(gameSessionToken)', self.game)
        self.assertIn('jarbox_treo_park_mode(state, change->compatible_only)', renderer)
        self.assertIn('jarbox_treo_guard_auto_set(state, mode == 8)', renderer)
        self.assertIn('jarbox_treo_smart_set(state, mode == 8)', renderer)
        self.assertIn('treo_display_wait_set_for_vm(vm, 0)', renderer)
        self.assertIn('if (mode == 8) treo_display_wait_set_for_vm(vm, 1)', renderer)
        self.assertIn('stopParkedTreo()', self.game)
        self.assertIn('setGlobalEmulatorView(self.emulatorView)', self.game)
        self.assertIn('libraryIsPresented', self.game)
        self.assertIn('overlay.dismiss(animated: false)', self.game)
        self.assertIn('JarBoxLibraryNavigationController(rootViewController: library)', self.game)
        # Source semantics, not byte-for-byte adjacency: the parked Alert
        # branch intentionally documents why owner verification is deferred.
        # Whitespace and explanatory comments must not break this guard.
        self.assertRegex(
            self.game,
            r'if libraryIsPresented\s*\{(?:\s*//[^\n]*\n)*\s*deferredGameAlert\s*=\s*true'
        )
        self.assertIn('if self.deferredGameAlert', self.game)
        self.assertIn('self.showAlert()', self.game)

    def test_treo_is_automatic_not_manual_menu_choice(self):
        self.assertNotIn('UIAction(title: "Treo tiết kiệm', self.game)
        self.assertNotIn('UIAction(title: "Treo tương thích', self.game)
        self.assertIn('UIAction(title: "Về thư viện · tự động Treo"', self.game)
        self.assertIn('requestGameStop(reason: "menu_stop")', self.game)
        self.assertIn('requestGameStop(reason: "library_stop")', self.game)
        stop = re.search(r'func stopParkedGame\(\)\s*\{(.*?)\n    \}',
                         self.game, re.DOTALL)
        self.assertIsNotNone(stop)
        self.assertLess(stop.group(1).index('stopParkedTreo()'),
                        stop.group(1).index('requestGameStop(reason: "library_stop")'))
        self.assertIn('self.stopParkedTreo()', self.game)

    def test_library_shows_running_state_and_blocks_second_game(self):
        self.assertIn('weak var parkedGameController: GameViewController?', self.library)
        self.assertIn('parked.ownsLiveGameSession()', self.library)
        self.assertIn('showAnotherGameBlocked(app)', self.library)
        self.assertIn('if let parked = games.first, parked.ownsLiveGameSession() {', self.library)
        self.assertIn('private var managedGames: [GameViewController] = []', self.library)
        self.assertIn('managedGames.append(gameVC)', self.library)
        self.assertIn('gameVC.sessionLibrary = self', self.library)
        self.assertIn('gameForTab(app.path, cloneID: cloneID)', self.library)
        self.assertIn('if count >= jvm_bridge_supported_concurrent_sessions()', self.library)
        self.assertIn('managedGames.removeAll { $0 === game }', self.library)
        self.assertIn('guard !game.holdsNativeGameSession() else', self.library)
        self.assertIn('restoreManagedGameFocus()', self.game)
        self.assertIn('library?.managedGameDidPark(self)', self.game)
        self.assertIn('title: "Đang đóng phiên cũ"', self.library)
        self.assertIn('resumeParkedGame()', self.library)
        self.assertIn('stopParkedGame()', self.library)
        self.assertIn('running: hasNativeGame(for: app.path)', self.library)
        self.assertIn('liveDot.isHidden = !running', self.cell)
        self.assertIn('accessibilityValue = running', self.cell)
        self.assertIn('navigationItem.rightBarButtonItems = [importBarButton, stop, jarBoxMenuButton].compactMap', self.library)
        self.assertIn('action: #selector(stopRunningGameFromLibrary)', self.library)
        self.assertIn('if hasNativeGame(for: destURL.path)', self.library)
        self.assertIn('action: #selector(openStuckSessionRecovery)', self.library)
        self.assertIn('attributes: isRunning ? [.destructive, .disabled]', self.library)
        self.assertIn('UIAction(title: "Thông tin trò chơi"', self.library)
        self.assertIn('showGameInformation(app)', self.library)
        self.assertIn('game.parkedSessionInformation()', self.library)
        self.assertIn('func parkedSessionInformation()', self.game)

    def test_global_sleep_overlay_is_in_main_menu_not_per_jar(self):
        self.assertIn('UIMenu(title: "JarBox"', self.library)
        self.assertIn('UIAction(title: "Màn hình Treo"', self.library)
        self.assertIn('UIAction(title: "Thông tin chung"', self.library)
        self.assertIn('showJarBoxSleepScreen()', self.library)
        self.assertIn('jarbox-global-sleep-screen', self.library)
        self.assertIn('jarbox-global-sleep-wake', self.library)
        self.assertIn('private func hideJarBoxSleepScreen()', self.library)
        self.assertIn('container.bringSubviewToFront(cover)', self.library)
        self.assertIn('navigationController?.view ?? view!', self.library)
        self.assertIn('private func refreshJarBoxSleepHUD()', self.library)
        self.assertIn('treo_process_cpu_seconds()', self.library)
        self.assertIn('ProcessInfo.processInfo.thermalState', self.library)
        self.assertIn('UIDevice.current.batteryLevel', self.library)
        self.assertIn('parked.ownsLiveGameSession()', self.library)
        self.assertIn('jvm_bridge_session_is_active()', self.library)
        self.assertNotIn('treo_render_set_afk_mode(8)', self.library)
        self.assertNotIn('jvm_bridge_try_begin_session()', self.library)

    def test_sleep_overlay_timer_lifecycle(self):
        self.assertIn('Timer.scheduledTimer(withTimeInterval: 15.0', self.library)
        self.assertIn('timer.tolerance = 3.0', self.library)
        self.assertIn('jarBoxSleepTimer?.invalidate()', self.library)
        self.assertIn('guard jarBoxSleepCover != nil else { return }', self.library)
        self.assertIn('guard active, springboardVisible else { return }', self.library)
        self.assertIn('setJarBoxSleepSampling(false)', self.library)
        self.assertIn('setJarBoxSleepSampling(true)', self.library)
        self.assertIn('hideJarBoxSleepScreen()\n        libraryCPUEntry = nil', self.library)
        self.assertIn('jarBoxSleepBatteryWasEnabled = device.isBatteryMonitoringEnabled', self.library)
        self.assertIn('UIDevice.current.isBatteryMonitoringEnabled = old', self.library)
        self.assertNotIn('UIScreen.main.brightness =', self.library)

    def test_does_not_claim_ios_background_execution(self):
        self.assertIn('does not grant iOS background execution', self.game)


if __name__ == "__main__":
    unittest.main()
