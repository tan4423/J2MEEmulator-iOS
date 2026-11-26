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
        self.assertIn('requestGameStop(reason: "close_tab")', self.game)
        self.assertIn('requestGameStop(reason: "library_stop")', self.game)

    def test_native_token_still_guards_single_vm(self):
        self.assertIn('jvm_bridge_try_begin_session_for_jar($0, &acquiredToken)', self.game)
        self.assertIn('gameSessionToken = acquiredToken', self.game)
        self.assertIn('cloneID: instanceCloneID, token: launchingToken', self.game)
        self.assertIn('jvm_bridge_init_for_token(token, resRoot, saveRoot', self.game)
        self.assertIn('jvm_bridge_run_midlet_for_token(token, jarPath)', self.game)
        self.assertIn('jvm_bridge_destroy_for_token(token)', self.game)
        self.assertIn('jvm_bridge_finish_session_for_token(token)', self.game)
        self.assertIn('jvm_bridge_session_token() == gameSessionToken', self.game)
        self.assertIn('jvm_bridge_session_is_active()', self.game)
        self.assertIn('jvm_bridge_request_stop_for_token(token)', self.game)
        self.assertNotIn('extern int g_render_3d_scale;', self.bridge)
        self.assertIn('int render_3d_scale, int fps_limit', self.bridge)
        self.assertIn('jvm_bridge_try_begin_session(void)', self.bridge)
        self.assertIn('int jvm_bridge_try_begin_session_with_token(uint64_t *out_token)', self.bridge)
        # The header verifies the public ABI; worker implementation is C.
        implementation = (ROOT / "J2MEEmulator/NativeBridge/jvm_bridge.c").read_text(encoding="utf-8")
        self.assertIn('static JarBoxVMContext *bridge_claim_worker(uint64_t token)', implementation)
        self.assertIn('if (!slot) return -10;', implementation)
        self.assertIn('bridge_release_worker(slot);', implementation)

    def test_automatic_treo_on_library_transition(self):
        self.assertIn('unbindGameFrameView(token: gameSessionToken)', self.game)
        self.assertIn('emulatorView.clearPendingGameFrame()', self.game)
        self.assertIn('startParkedTreo()', self.game)
        renderer = (ROOT / "J2MEEmulator/NativeBridge/j2me_render.m").read_text(encoding="utf-8")
        self.assertIn('JarBoxGameStorage.treoCompatibleOnly(for: jarPath)', self.game)
        self.assertIn('treo_park_begin_for_token(gameSessionToken, compatibleOnly ? 1 : 0)', self.game)
        self.assertIn('treo_park_end_for_token(gameSessionToken)', self.game)
        self.assertIn('treo_mode_for_token(gameSessionToken)', self.game)
        # Automatic parking must use the release-safe selector, not the
        # diagnostic deep-Treo candidate (Canvas shape alone is not proof).
        transition = renderer.split("static void treo_park_transition_visitor(", 1)[1].split("\n}", 1)[0]
        self.assertIn('? jarbox_treo_safe_automatic_park_mode(state, change->compatible_only) : 0', transition)
        self.assertNotIn('jarbox_treo_park_mode(state,', transition)
        choice = renderer.split("static void treo_park_choice_visitor(", 1)[1].split("\n}", 1)[0]
        self.assertIn('choice->mode = jarbox_treo_safe_automatic_park_mode', choice)
        policy = (ROOT / "J2MEEmulator/minijvm/jvm/jarbox_treo_state.h").read_text(encoding="utf-8")
        safe = policy.split("static inline int jarbox_treo_safe_automatic_park_mode(", 1)[1].split("\n}", 1)[0]
        self.assertIn("return jarbox_treo_park_mode(state, 1);", safe)
        self.assertIn('jarbox_treo_guard_auto_set(state, mode == 8)', renderer)
        self.assertIn('jarbox_treo_smart_set(state, mode == 8)', renderer)
        self.assertIn('treo_display_wait_set_for_vm(vm, 0)', renderer)
        self.assertIn('if (mode == 8) treo_display_wait_set_for_vm(vm, 1)', renderer)
        self.assertIn('stopParkedTreo()', self.game)
        self.assertIn('bindGameFrameView(self.emulatorView, token:', self.game)
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
        self.assertNotIn('UIAction(title: "Về thư viện · tự động Treo"', self.game)
        self.assertIn('(backButton, "arrow.down.right.and.arrow.up.left", "Ẩn, giữ game chạy")', self.game)
        self.assertIn('requestGameStop(reason: "close_tab")', self.game)
        self.assertIn('requestGameStop(reason: "library_stop")', self.game)
        stop = re.search(r'func stopParkedGame\(\)\s*\{(.*?)\n    \}',
                         self.game, re.DOTALL)
        self.assertIsNotNone(stop)
        self.assertLess(stop.group(1).index('stopParkedTreo()'),
                        stop.group(1).index('requestGameStop(reason: "library_stop")'))
        self.assertIn('self.stopParkedTreo()', self.game)

    def test_library_shows_running_state_and_blocks_second_game(self):
        self.assertIn('weak var parkedGameController: GameViewController?', self.library)
        # Managed and legacy parked controllers share the retained list.
        retained = self.library.split('private var retainedGames:', 1)[1].split(
            'private func gameForTab(', 1)[0]
        self.assertIn('return managedGames + [parked]', retained)
        live = self.library.split('private var liveGames:', 1)[1].split(
            '\n    }', 1)[0]
        self.assertIn('retainedGames.filter { $0.ownsLiveGameSession() }', live)
        self.assertIn('showAnotherGameBlocked(app)', self.library)
        self.assertIn('JarBoxGameStorage.lastTab(jarPath: app.path,', self.library)
        self.assertIn('JarBoxGameStorage.rememberLastTab(jarPath: game.jarPath, cloneID: game.cloneID)', self.library)
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
        self.assertIn('running: hasRunningGame(for: app.path)', self.library)
        self.assertIn('if running { details.append("Đang chạy ẩn trong JarBox") }', self.cell)
        self.assertIn('accessibilityValue = details.isEmpty ? nil', self.cell)
        self.assertIn('navigationItem.rightBarButtonItems = [importBarButton, jarBoxMenuButton].compactMap', self.library)
        self.assertNotIn('stopRunningGameFromLibrary', self.library)
        self.assertNotIn('UIAction(title: "Vào Tab cuối"', self.library)
        self.assertIn('UIAction(title: "Cài đặt"', self.library)
        self.assertIn('return UIMenu(title: "Dừng"', self.library)
        self.assertIn('return action("Dừng", snapshots)', self.library)
        self.assertIn('game.parkedSessionToken == token', self.library)
        self.assertNotIn('UIAction(title: "Thoát game"', self.game)
        self.assertIn('(closeTabButton, "stop.fill", "Dừng tab")', self.game)
        self.assertIn('if hasNativeGame(for: destURL.path)', self.library)
        self.assertIn('UIAction(title: "Xử lý phiên kẹt"', self.library)
        self.assertIn('attributes: .destructive', self.library)
        self.assertIn('confirmTabMutation(app: app, tabs: tabs', self.library)
        self.assertIn('UIAction(title: "Thông tin trò chơi"', self.library)
        self.assertIn('showGameInformation(app)', self.library)
        self.assertIn('game.parkedSessionInformation()', self.library)
        self.assertIn('func parkedSessionInformation()', self.game)


    def test_library_tab_badge_is_static_and_reuse_safe(self):
        cell = self.cell
        library = self.library
        self.assertIn('cell.configure(name: app.name, icon: app.icon,', library)
        self.assertIn('tabCount: app.cloneCount + 1', library)
        self.assertNotIn('let groupTitle = app.cloneCount', library)
        self.assertIn('nameLabel.text = name', cell)
        self.assertIn('tabBadgeLabel.text = tabCount >= 2 ? "x" + String(tabCount) : nil', cell)
        self.assertIn('tabBadge.isHidden = tabCount < 2', cell)
        self.assertIn('tabBadge.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -2)', cell)
        self.assertIn('tabBadge.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -3)', cell)
        self.assertIn('tabBadge.isUserInteractionEnabled = false', cell)
        reuse = cell.split('override func prepareForReuse()', 1)[1].split('override var isHighlighted', 1)[0]
        self.assertIn('tabBadge.isHidden = true', reuse)
        self.assertIn('tabBadgeLabel.text = nil', reuse)
        self.assertIn('liveDot.isHidden = !running', cell)
        self.assertIn('liveDot.isHidden = true', reuse)
        self.assertIn('liveDot.topAnchor.constraint(equalTo: iconView.topAnchor', cell)
        self.assertIn('liveDot.trailingAnchor.constraint(equalTo: iconView.trailingAnchor', cell)
        self.assertIn('liveDot.isUserInteractionEnabled = false', cell)
        self.assertIn('retainedGames.contains { $0.ownsLiveGameSession(for: path) }', library)
        self.assertIn('retainedGames.contains { $0.holdsNativeGameSession(for: path) }', library)
        self.assertIn('sessionLibrary?.managedGameDidRequestStop(self)', self.game)
        stop = library.split('func managedGameDidRequestStop(', 1)[1].split('\n    }', 1)[0]
        self.assertIn('springboardCollectionView.reloadData()', stop)
        self.assertNotIn('Timer(', cell)

    def test_global_sleep_overlay_is_in_main_menu_not_per_jar(self):
        self.assertIn('UIMenu(title: "JarBox"', self.library)
        self.assertIn('UIAction(title: "Bảo vệ màn hình"', self.library)
        self.assertIn('UIAction(title: "Trạng thái"', self.library)
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
        # The simplified HUD displays the native slot count, not game names.
        hud = self.library.split('private func refreshJarBoxSleepHUD()', 1)[1].split(
            'private func showJarBoxOverview()', 1)[0]
        self.assertIn('"Tab đang chạy: " + String(jvm_bridge_active_session_count())', hud)
        self.assertIn('String(jvm_bridge_supported_concurrent_sessions())', hud)
        self.assertNotIn('ownsLiveGameSession()', hud)
        self.assertNotIn('liveGames', hud)
        self.assertIn('jvm_bridge_session_is_active()', self.library)
        self.assertNotIn('treo_render_set_afk_mode(8)', self.library)
        self.assertNotIn('jvm_bridge_try_begin_session()', self.library)

    def test_sleep_overlay_timer_lifecycle(self):
        self.assertIn('Timer(timeInterval: 1.0, repeats: true)', self.library)
        self.assertIn('timer.tolerance = 0.05', self.library)
        self.assertIn('jarBoxSleepTimer?.invalidate()', self.library)
        self.assertIn('guard let cover = jarBoxSleepCover else { return }', self.library)
        self.assertIn('if !ownsDisplay { hideJarBoxSleepInformation() }', self.library)
        self.assertIn('setJarBoxSleepSampling(false)', self.library)
        self.assertIn('setJarBoxSleepSampling(true)', self.library)
        library = self.library.split("class AppsListViewController: UIViewController,", 1)[1]
        disappear = library.split('override func viewWillDisappear(', 1)[1].split(
            'override func viewDidDisappear(', 1)[0]
        self.assertIn('if isBeingDismissed || isMovingFromParent ||', disappear)
        self.assertIn('hideJarBoxSleepScreen()', disappear)
        self.assertIn('setJarBoxSleepSampling(false)', disappear)
        self.assertIn('jarBoxSleepCover?.isHidden = true', disappear)
        self.assertIn('jarBoxSleepBatteryWasEnabled = device.isBatteryMonitoringEnabled', self.library)
        self.assertIn('UIDevice.current.isBatteryMonitoringEnabled = old', self.library)
        self.assertNotIn('UIScreen.main.brightness =', self.library)
        self.assertIn('screen.brightness = 0', self.library)
        self.assertIn('saved.screen.brightness = saved.previous', self.library)
        self.assertIn('setJarBoxSleepBrightness(ownsDisplay)', self.library)
        self.assertIn('setJarBoxSleepIdleTimer(ownsDisplay)', self.library)
        self.assertIn('self.jarBoxSleepSamplingGeneration == generation', self.library)
        self.assertIn('enabled && jarBoxSleepCover == nil', self.library)

    def test_sleep_hud_does_not_sample_cpu_on_entry_or_thermal_event(self):
        hud = self.library.split('private func refreshJarBoxSleepHUD()', 1)[1].split(
            'private func showJarBoxOverview()', 1)[0]
        sampler = self.library.split('private func sampleJarBoxSleepCPU()', 1)[1].split(
            'private func jarBoxSleepDurationText(', 1)[0]
        self.assertNotIn('treo_process_cpu_seconds()', hud)
        self.assertIn('guard elapsed >= 0.9 else { return }', sampler)
        self.assertIn('self.sampleJarBoxSleepCPU()', self.library)
        self.assertIn('"CPU tổng: đang đo"', self.library)
        self.assertIn('"Nhiệt độ: " + thermal', hud)
        self.assertIn('"Thời gian: " + jarBoxSleepDurationText(elapsed)', hud)
        self.assertNotIn('runningText', hud)
        self.assertNotIn('Chế độ pin yếu', hud)
        self.assertNotIn('Thời gian phủ', hud)
        self.assertNotIn('CPU là tổng tiến trình', hud)
        self.assertIn('info.textAlignment = .left', self.library)
        self.assertIn('info.centerXAnchor.constraint(equalTo: cover.centerXAnchor)', self.library)

    def test_sleep_hud_is_on_demand_and_expires(self):
        cover = self.library.split('private func showJarBoxSleepScreen()', 1)[1].split(
            'private func hideJarBoxSleepScreen()', 1)[0]
        show = self.library.split('private func showJarBoxSleepInformation()', 1)[1].split(
            'private func hideJarBoxSleepInformation()', 1)[0]
        hide = self.library.split('private func hideJarBoxSleepInformation()', 1)[1].split(
            'private func sampleJarBoxSleepCPU()', 1)[0]
        self.assertIn('UIStackView(arrangedSubviews: [wake, information])', cover)
        self.assertIn('jarbox-global-sleep-info', cover)
        self.assertIn('info.isHidden = true', cover)
        self.assertNotIn('Chạm nút giữa', cover)
        self.assertNotIn('Timer(', cover)
        self.assertNotIn('treo_process_cpu_seconds()', cover)
        self.assertNotIn('isBatteryMonitoringEnabled', cover)
        # A second tap must return before a fresh timer/baseline is created.
        self.assertIn('if !label.isHidden {\n            hideJarBoxSleepInformation()\n            return\n        }'.replace('\n', '\n'), show)
        self.assertIn('jarBoxSleepHUDDeadline = now + 15', show)
        self.assertIn('systemUptime < deadline', show)
        self.assertIn('self.hideJarBoxSleepInformation()', show)
        self.assertIn('jarBoxSleepTimer?.invalidate()', hide)
        self.assertIn('jarBoxSleepHUD?.isHidden = true', hide)
        self.assertIn('jarBoxSleepHUDDeadline = nil', hide)
        self.assertIn('jarBoxSleepCPUSample = nil', hide)
        self.assertIn('UIDevice.current.isBatteryMonitoringEnabled = old', hide)

    def test_does_not_claim_ios_background_execution(self):
        self.assertIn('does not grant iOS background execution', self.game)


if __name__ == "__main__":
    unittest.main()
