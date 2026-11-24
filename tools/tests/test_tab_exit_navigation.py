"""Run the actual tab routing helpers with host Swift; UIKit is not executed."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

UI = Path(__file__).resolve().parents[2] / "J2MEEmulator/UI"
LIB = UI / "AppsListViewController.swift"
GAME = UI / "GameViewController.swift"

MAIN = r'''
}
var checks = 0
let all: [UUID?] = [nil] + (0..<16).map { _ in Optional(UUID()) }
let stale = UUID()
for size in 1...17 {
    let tabs = Array(all.prefix(size))
    // All subsets of size <= 2, the actual native concurrency limit.
    var sets: [Set<UUID?>] = [[]]
    for a in tabs.indices {
        sets.append([tabs[a]])
        for b in tabs.indices where b > a { sets.append([tabs[a],tabs[b]]) }
    }
    for live in sets {
        for i in tabs.indices {
            let expected = Array(tabs.indices.dropFirst(i+1)).first { live.contains(tabs[$0]) } ??
                Array(tabs.indices.prefix(i)).first { live.contains(tabs[$0]) }
            precondition(JarBoxGameStorage.nextRunningTabIndex(ordered: tabs, closing: tabs[i], running: live) == expected)
            checks += 1
            let entry = live.contains(tabs[i]) ? i : (tabs.firstIndex { live.contains($0) } ?? 0)
            precondition(JarBoxGameStorage.entryTabIndex(ordered: tabs, remembered: tabs[i], running: live) == entry)
            checks += 1
        }
        precondition(JarBoxGameStorage.entryTabIndex(ordered: tabs, remembered: stale, running: live) ==
            (tabs.firstIndex { live.contains($0) } ?? 0))
        checks += 1
        precondition(JarBoxGameStorage.nextRunningTabIndex(ordered: tabs, closing: stale, running: live) == nil)
        checks += 1
    }
}
precondition(JarBoxGameStorage.entryTabIndex(ordered: [], remembered: nil, running: []) == nil)
print("\(checks) route assertions passed")
var deletionChecks = 0
for size in 1...17 {
    let tabs = Array(all.prefix(size))
    for mask in 0..<(1 << size) where mask.nonzeroBitCount <= 2 {
        let running = Set(tabs.indices.filter { mask & (1 << $0) != 0 }.map { tabs[$0] })
        for origin in tabs.indices {
            let candidates = tabs.indices.filter { $0 != origin }
            let expected = candidates.filter { $0 < origin && running.contains(tabs[$0]) }.max() ??
                candidates.filter { $0 > origin && running.contains(tabs[$0]) }.min() ??
                candidates.filter { $0 < origin }.max() ?? candidates.filter { $0 > origin }.min()
            precondition(JarBoxGameStorage.deletionNeighborIndex(ordered: tabs, deleting: tabs[origin], running: running) == expected)
            deletionChecks += 1
        }
        precondition(JarBoxGameStorage.deletionNeighborIndex(ordered: tabs, deleting: stale, running: running) == nil)
        deletionChecks += 1
    }
}
precondition(JarBoxGameStorage.deletionNeighborIndex(ordered: [], deleting: nil, running: []) == nil)
print("Deletion-neighbor selection: \(deletionChecks + 1) cases passed")
'''

def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


class TabExitNavigationTest(unittest.TestCase):
    def test_circular_and_entry_selection(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("host Swift compiler unavailable")
        source = LIB.read_text(encoding="utf-8")
        code = "import Foundation\nenum JarBoxGameStorage {\n" + "\n".join(
            method(source, "    nonisolated static func " + name + "(")
            for name in ("nextRunningTabIndex", "entryTabIndex", "deletionNeighborIndex")) + MAIN
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "route.swift"
            exe = Path(td) / "route"
            src.write_text(code, encoding="utf-8")
            subprocess.run([swift, "-swift-version", "5", str(src), "-o", str(exe)], check=True, timeout=60)
            result = subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=20)
            self.assertIn("27472 route assertions passed", result.stdout)
            self.assertIn("Deletion-neighbor selection: 13737 cases passed", result.stdout)

    def test_tab_actions_and_transition_cover(self):
        game = GAME.read_text(encoding="utf-8")
        lib = LIB.read_text(encoding="utf-8")
        strip = method(game, "    private func refreshGameTabStrip()")
        self.assertIn("button.setTitle(tab.title, for: .normal)", strip)
        self.assertIn("if tab.running {", strip)
        self.assertIn("dot.backgroundColor = .systemGreen", strip)
        self.assertIn("dot.centerYAnchor.constraint(equalTo: button.topAnchor)", strip)
        self.assertIn("tabs.count > 1 && cloneID != nil && ready", strip)
        layout = method(game, "    private func setupGameTabStrip()")
        self.assertIn("gameTabScroll.trailingAnchor.constraint(equalTo: tabActions.leadingAnchor, constant: -14)", layout)
        self.assertLess(layout.index('(tabRemoveButton, "minus",'), layout.index('(tabAddButton, "plus",'))
        self.assertIn("tabActions.spacing = 8", layout)
        self.assertIn("gameTabStack.spacing = 8", layout)
        self.assertIn("gameTabScroll.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 8)", layout)
        self.assertIn("gameTabScroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12)", layout)
        self.assertIn("gameTabStack.heightAnchor.constraint(equalTo: gameTabScroll.frameLayoutGuide.heightAnchor, constant: -10)", layout)
        self.assertIn("button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)", strip)
        self.assertIn("gameTabHeight?.constant = 50", strip)
        self.assertIn('(backButton, "arrow.down.right.and.arrow.up.left", "Ẩn, giữ game chạy")', game)
        self.assertIn('(closeTabButton, "stop.fill", "Dừng tab")', game)
        self.assertIn("button.tintColor = button === closeTabButton ? .systemRed : .white", game)
        self.assertIn("closeTabButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 10)", game)
        self.assertIn("emulatorView.topAnchor.constraint(equalTo: gameTabScroll.bottomAnchor, constant: 8)", game)
        add = method(lib, "    func createTabBeside(")
        self.assertLess(add.index("try requireNewTabSlot(for: app)"), add.index("createCloneAfter("))
        switch = method(game, "    private func switchGameTab(")
        self.assertLess(switch.index("try library.validateGameTabSwitch"), switch.index("openLibraryKeepingGame()"))
        delete = method(lib, "    private func completeForegroundTabDeletion(")
        self.assertLess(delete.index("jvm_bridge_session_is_active_for_token(deletion.token) == 0"), delete.index("removeClones("))
        self.assertLess(delete.index("mutationOwners("), delete.index("removeClones("))
        self.assertLess(delete.index("removeClones("), delete.index("launchGameTab("))
        park = method(game, "    @objc private func openLibraryKeepingGame()")
        self.assertLess(park.index("library.beginGameTabTransition()"), park.index("dismiss(animated: false)"))
        self.assertIn("defer { library?.finishGameTabTransitionIfIdle() }", park)
        cover = method(lib, "    func beginGameTabTransition()")
        self.assertIn("cover.backgroundColor = .black", cover)
        self.assertNotIn("snapshotView", cover)
        present = method(lib, "    private func presentGame(")
        self.assertLess(present.index("self?.gamePresentationInFlight = false"), present.index("self?.finishGameTabTransitionIfIdle()"))
        hud = method(lib, "    private func refreshJarBoxSleepHUD()")
        self.assertIn("jarBoxRAMText()", hud)
        ram = method(lib, "    private func jarBoxRAMText()")
        self.assertIn("vm.phys_footprint", ram)
        self.assertIn("ProcessInfo.processInfo.physicalMemory", ram)
        self.assertIn("RAM: %.1f%% (%.0f MB)", ram)

    def test_visible_exit_routes_only_after_retirement_and_dismissal(self):
        game = GAME.read_text(encoding="utf-8")
        lib = LIB.read_text(encoding="utf-8")
        close = method(game, "    private func dismissEndedGame()")
        self.assertIn("guard !holdsNativeGameSession(), !endedTabDismissalInFlight", close)
        self.assertLess(close.index("self.dismiss(animated: false)"), close.index("library?.openNextRunningTabAfterExit("))
        worker = game.split("if self.sessionLibrary != nil && self.libraryIsPresented {", 1)[1]
        hidden = worker.split("                self.ownsJVMSession = false\n                self.gameSessionToken = 0\n", 1)[0]
        self.assertNotIn("dismissEndedGame()", hidden)
        self.assertNotIn("openNextRunningTabAfterExit(", hidden)
        self.assertIn("self.sessionLibrary?.managedGameDidEnd(self)", hidden)
        route = method(lib, "    func openNextRunningTabAfterExit(")
        self.assertIn("guard canPresentGame, jvm_bridge_visible_session_token() == 0", route)
        self.assertIn("JarBoxGameStorage.nextRunningTabIndex(", route)
        self.assertIn("game.parkedSessionToken != nil", route)
        self.assertIn("game.resumeParkedGame()", route)
        self.assertNotIn("launchGameTab(", route)
        self.assertIn("if running.isEmpty { JarBoxGameStorage.rememberLastTab", route)


if __name__ == "__main__":
    unittest.main()
