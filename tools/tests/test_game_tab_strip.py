"""Source contracts for browser-style tab navigation and scoped menu actions."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2] / "J2MEEmulator/UI"
LIB = (ROOT / "AppsListViewController.swift").read_text()
GAME = (ROOT / "GameViewController.swift").read_text()


def part(source, first, last):
    return source.split(first, 1)[1].split(last, 1)[0]


class GameTabStripTest(unittest.TestCase):
    def test_context_menu_order_and_single_tab_actions(self):
        menu = part(LIB, "contextMenuConfigurationForItemsAt", "private func showGameInformation(")
        self.assertIn("return UIMenu(children: [stop, infoAction, advanced, rename,", menu)
        self.assertIn("self.clearDataMenu(for: app, tabs: tabs)", menu)
        self.assertIn("children: [cloneMenu, treoSettings, resolution, fps, quality3D]", menu)
        self.assertIn("self.clearDataMenu(for: app, tabs: tabs), delete]", menu)
        self.assertIn('UIMenu(title: "Treo",', menu)
        self.assertNotIn("dùng chung mọi tab", menu)
        stop = part(LIB, "private func stopMenu(", "private func clearDataMenu(")
        self.assertIn('if snapshots.count <= 1 { return action("Dừng", snapshots) }', stop)
        self.assertIn('children: [action("Tất cả", snapshots)] + snapshots.map', stop)
        self.assertIn("game.parkedSessionToken == token", stop)
        self.assertIn("tabs.compactMap", stop)
        self.assertIn("let token = game.parkedSessionToken else { return nil }", stop)
        clear = part(LIB, "private func clearDataMenu(", "// Keep lifecycle diagnostics")
        self.assertIn('if tabs.count == 1 { return action("Xóa dữ liệu", tabs) }', clear)
        self.assertIn('children: [action("Tất cả", tabs)] + tabs.map', clear)

    def test_fps_and_3d_are_independent_shared_menu_items(self):
        menu = part(LIB, "contextMenuConfigurationForItemsAt", "private func showGameInformation(")
        self.assertIn('UIAction(title: "FPS",', menu)
        self.assertIn('UIAction(title: "3D",', menu)
        self.assertNotIn('UIAction(title: "FPS và 3D"', menu)
        self.assertIn("showSharedFPSOptions(for: app)", menu)
        self.assertIn("showShared3DOptions(for: app)", menu)
        self.assertNotIn("showTabSettingsPicker(", LIB)
        launch = part(LIB, "private func launchGameTab(", "\n    }")
        for name in ("resolution", "fpsLimit", "is3DSupersampling"):
            self.assertIn("Self." + name + "(for: app)", launch)
            self.assertNotIn("Self." + name + "(for: app, cloneID:", LIB)

    def test_shared_setting_restarts_only_running_group(self):
        menu = part(LIB, "contextMenuConfigurationForItemsAt", "private func showGameInformation(")
        self.assertIn("self?.showSharedResolutionOptions(for: app)", menu)
        picker = part(LIB, "private func showSharedOptions(", "private func changeSharedGameSetting(")
        self.assertIn("guard !option.selected else { return }", picker)
        change = part(LIB, "private func changeSharedGameSetting(", "private func restartConfiguredTabs(")
        self.assertIn("if owners.isEmpty", change)
        self.assertIn('action: "Khởi động lại", restartAfter: true', change)
        confirm = part(LIB, "private func confirmTabMutation(", "private func finishTabMutation(")
        self.assertIn("now.filter { $0.game.parkedSessionToken == $0.token }.map { $0.game.cloneID }", confirm)
        wait = part(LIB, "private func waitForTabMutation(", "private func confirmClearGameData(")
        self.assertLess(wait.index("try operation(unrelated)"), wait.index("try await self.restartConfiguredTabs"))
        restart = part(LIB, "private func restartConfiguredTabs(", "\n    }")
        self.assertIn("for id in ids", restart)
        self.assertIn("launchGameTab(app, cloneID: id,", restart)
        self.assertIn("game.parkedSessionToken != nil", restart)
        self.assertIn("game.parkAfterSettingsRestart()", restart)
        self.assertIn("defer { JarBoxGameStorage.rememberLastTab", restart)
        park = part(GAME, "func parkAfterSettingsRestart()", "@objc private func openLibraryKeepingGame()")
        self.assertIn("startupWatchdog == nil", park)
        self.assertIn("presentedViewController == nil", park)
        self.assertIn("openLibraryKeepingGame()", park)

    def test_clone_menu_checks_capacity_and_confirms_exact_delete_targets(self):
        menu = part(LIB, "private func makeCloneMenu(", "private func addDefaultTabs(")
        self.assertIn("children: [add, remove, addMany, removeMany]", menu)
        self.assertIn("allowedAddCount(cloneCount: cloneCount) > 0", menu)
        self.assertIn("let canRemove = cloneCount > 0", menu)
        prompt = part(LIB, "private func promptTabQuantity(", "private func presentTabDeletion(")
        self.assertIn("validTabQuantity(count, maximum: maximum)", prompt)
        self.assertIn("validTabQuantity(count, maximum: current.count)", prompt)
        self.assertIn("Array(current.suffix(count))", prompt)
        confirm = part(LIB, "private func confirmDeleteTabs(", "private func launchGameTab(")
        self.assertIn('clones.map { $0.label }.joined(separator: ", ")', confirm)
        self.assertIn("cloneIDs: clones.map { $0.id }", confirm)
        storage = part(LIB, "static func removeClones(", "/// Never combine")
        self.assertLess(storage.index("ids.isSubset"), storage.index("fm.moveItem"))
        self.assertLess(storage.index("try requireMutationSafety(unrelatedTokens: unrelatedTokens)"), storage.index("fm.moveItem"))

    def test_tab_switch_reuses_park_and_waits_for_dismissal(self):
        switch = part(GAME, "private func switchGameTab(", "private func setupNGageLayout(")
        self.assertIn("startupWatchdog == nil", switch)
        self.assertIn("openLibraryKeepingGame()", switch)
        self.assertIn("defer { requestedTabSwitch = nil }", switch)
        park = part(GAME, "@objc private func openLibraryKeepingGame() {", "func resumeParkedGame()")
        self.assertLess(park.index("guard parkedTreoActive else"), park.index("let switchTab = requestedTabSwitch"))
        self.assertLess(park.index("library?.managedGameDidPark(self)"), park.index("switchTab?()"))
        launch = part(LIB, "func openGameTabAfterPark(", "private func stopMenu(")
        self.assertIn("source.parkedSessionToken != nil", launch)
        self.assertIn("launchGameTab(app, cloneID: target.id,", launch)
        self.assertIn("gameForTab(app.path, cloneID: cloneID)", LIB)

    def test_game_icon_opens_last_tab_directly(self):
        tap = part(LIB, "didSelectItemAt indexPath:", "private func showTabInformationPicker(")
        self.assertIn("JarBoxGameStorage.lastTab(jarPath: app.path,", tap)
        self.assertIn("registered: tabs.compactMap", tap)
        self.assertIn("launchGameTab(app, cloneID: id,", tap)
        self.assertNotIn("showTabChooser", tap)
        park = part(GAME, "@objc private func openLibraryKeepingGame() {", "func resumeParkedGame()")
        self.assertLess(park.index("library?.managedGameDidPark(self)"),
                        park.index("library?.rememberExitedGameTab(self)"))
        self.assertLess(park.index("library?.rememberExitedGameTab(self)"), park.index("switchTab?()"))
        strip = part(GAME, "private func refreshGameTabStrip()", "private func switchGameTab(")
        self.assertIn("gameTabStack.addArrangedSubview(button)", strip)
        self.assertIn("let selected = tab.id == cloneID", strip)

    def test_mutation_waits_for_exact_tokens_and_proves_survivors(self):
        wait = part(LIB, "private func waitForTabMutation(", "private func confirmClearGameData(")
        self.assertIn("tokens.allSatisfy { jvm_bridge_session_is_active_for_token($0) == 0 }", wait)
        self.assertIn("self.mutationOwners(path: app.path, ids: ids).isEmpty", wait)
        self.assertLess(wait.index("try JarBoxGameStorage.requireMutationSafety"), wait.index("try operation(unrelated)"))
        self.assertIn("ProcessInfo.processInfo.systemUptime + 20", wait)
        self.assertIn("!isBeingDismissed && pendingTabMutation == nil", LIB)
        safety = part(LIB, "static func requireMutationSafety(", "// Includes the original")
        self.assertIn("Set(unrelatedTokens).filter", safety)
        self.assertIn("jvm_bridge_session_is_active_for_token($0) != 0", safety)
        self.assertIn("before == after, after == active.count", safety)
        stop = part(GAME, "func requestStopForTabMutation(", "func holdsNativeInstance(")
        self.assertIn("nativeSessionToken == expectedToken", stop)
        self.assertIn("parkedSessionToken == expectedToken", stop)

    def test_reset_keeps_registry_and_revalidates_native_slots(self):
        clear = part(LIB, "private func confirmClearGameData(", "private func confirmDeleteApp(")
        self.assertIn("confirmTabMutation(app: app, tabs: tabs", clear)
        self.assertIn("unrelatedTokens: unrelated", clear)
        reset = part(LIB, "static func clearInstanceData(", "/// Retain user settings")
        self.assertIn("try requireMutationSafety(unrelatedTokens: unrelatedTokens)", reset)
        self.assertIn("cloneID: cloneID", reset)
        self.assertIn("createDirectory(atPath: root", reset)
        self.assertNotIn("removeClone(", reset)
        self.assertNotIn("writeCloneGroup(", reset)


if __name__ == "__main__":
    unittest.main()
