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
        self.assertIn("children: [treoSettings, settings, addTab, removeTab, delete]", menu)
        stop = part(LIB, "private func stopMenu(", "private func clearDataMenu(")
        self.assertIn('if snapshots.count == 1 { return action("Dừng", snapshots) }', stop)
        self.assertIn('children: [action("Tất cả", snapshots)] + snapshots.map', stop)
        self.assertIn("game.parkedSessionToken == token", stop)
        clear = part(LIB, "private func clearDataMenu(", "// Keep lifecycle diagnostics")
        self.assertIn('if tabs.count == 1 { return action("Xóa dữ liệu", tabs) }', clear)
        self.assertIn('children: [action("Tất cả", tabs)] + tabs.map', clear)

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

    def test_reset_keeps_registry_and_revalidates_native_slots(self):
        clear = part(LIB, "private func confirmClearGameData(", "private func confirmDeleteApp(")
        self.assertLess(clear.index("jvm_bridge_session_is_active() == 0"), clear.index("clearInstanceData("))
        self.assertIn("tabs.allSatisfy", clear)
        reset = part(LIB, "static func clearInstanceData(", "/// Retain user settings")
        self.assertIn("jvm_bridge_active_session_count() == 0", reset)
        self.assertIn("cloneID: cloneID", reset)
        self.assertIn("createDirectory(atPath: root", reset)
        self.assertNotIn("removeClone(", reset)
        self.assertNotIn("writeCloneGroup(", reset)


if __name__ == "__main__":
    unittest.main()
