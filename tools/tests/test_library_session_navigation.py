"""Run production library ownership and main-menu methods with Swift host doubles."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "J2MEEmulator/UI/AppsListViewController.swift"
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"
PRELUDE = r'''
import Foundation

struct UIImage { init(systemName: String) {} }
struct Attributes: OptionSet {
    let rawValue: Int
    static let disabled = Attributes(rawValue: 1)
}
class UIMenuElement {}
class UIAction: UIMenuElement {
    let title: String
    let attributes: Attributes
    let handler: (UIAction) -> Void
    init(title: String, image: UIImage? = nil, attributes: Attributes = [],
         handler: @escaping (UIAction) -> Void) {
        self.title = title
        self.attributes = attributes
        self.handler = handler
    }
}
class UIMenu {
    let children: [UIMenuElement]
    init(title: String, children: [UIMenuElement]) { self.children = children }
}
class UIBarButtonItem {
    let title: String
    var menu: UIMenu?
    init(_ title: String) { self.title = title }
}
class NavigationItem {
    var title: String?
    var leftBarButtonItem: UIBarButtonItem?
    var rightBarButtonItems: [UIBarButtonItem]?
}
class GameViewController {
    var live = true
    var native = true
    var resumes = 0
    var token: UInt64 = 1
    var parked = true
    var parkedSessionToken: UInt64? { parked && live && token != 0 ? token : nil }
    func ownsLiveGameSession() -> Bool { live }
    func holdsNativeGameSession() -> Bool { native }
    func resumeParkedGame() { resumes += 1 }
    func gameTabStateDidChange() {}
}
class Collection { func reloadData() {} }
// Stateful diagnostic doubles: verify the action targets the exact library
// that owns the menu, rather than relying on global visible-game state.
enum JarBoxBackgroundDiagnostics {
    static func showAudio(from controller: Library) { controller.audioMenuCalls += 1 }
    static func show(from controller: Library) { controller.logMenuCalls += 1 }
}
class Library {
    var audioMenuCalls = 0
    var logMenuCalls = 0
    let navigationItem = NavigationItem()
    let springboardCollectionView = Collection()
    var activeCount = 0
    var canPresentGame = true
    var presentedViewController: AnyObject?
    var managedGames: [GameViewController] = []
    weak var parkedGameController: GameViewController?
    var importBarButton: UIBarButtonItem? = UIBarButtonItem("+")
    var jarBoxMenuButton: UIBarButtonItem? = UIBarButtonItem("Menu")
    func jvm_bridge_session_is_active() -> Int32 { activeCount == 0 ? 0 : 1 }
    func showJarBoxSleepScreen() {}
    func showJarBoxOverview() {}
    func showJarBoxSettings() {}
    func openStuckSessionRecovery() {}
'''
MAIN = r'''
    func refresh() { updateStuckSessionButton() }
    func setLegacy(_ game: GameViewController?) {
        parkedGameController = game
        refresh()
    }
    func menuAction(_ title: String) -> UIAction? {
        jarBoxMenuButton?.menu?.children.compactMap { $0 as? UIAction }
            .first { $0.title == title }
    }
    func expect(_ recovery: Bool) {
        precondition(navigationItem.title == "Thư viện")
        precondition(navigationItem.leftBarButtonItem == nil)
        precondition(navigationItem.rightBarButtonItems?.map { $0.title } == ["+", "Menu"])
        precondition(menuAction("Vào Tab cuối") == nil)
        precondition(menuAction("Cài đặt") != nil)
        precondition(menuAction("Trạng thái") != nil)
        precondition(menuAction("Thông tin chung") == nil)
        precondition((menuAction("Xử lý phiên kẹt") != nil) == recovery)
        precondition(menuAction("Bảo vệ màn hình") != nil)
        guard let audio = menuAction("Âm nền Treo (thử nghiệm)"),
              let log = menuAction("Log Treo tắt màn hình") else {
            preconditionFailure("Missing background controls")
        }
        let previousAudio = audioMenuCalls
        let previousLog = logMenuCalls
        audio.handler(audio)
        precondition(audioMenuCalls == previousAudio + 1 && logMenuCalls == previousLog)
        log.handler(log)
        precondition(logMenuCalls == previousLog + 1 && audioMenuCalls == previousAudio + 1)
    }
}
let lib = Library()
for _ in 0..<1000 {
    let a = GameViewController(), b = GameViewController()
    a.token = 1; b.token = 2
    lib.managedGames = [a, b]
    lib.activeCount = 2
    lib.managedGameDidPark(a)
    lib.expect(false)
    lib.managedGameDidPark(b)
    lib.expect(false)
    b.live = false
    lib.managedGameDidEnd(b)
    precondition(lib.managedGames.contains { $0 === b })
    lib.expect(false)
    b.native = false
    lib.activeCount = 1
    lib.managedGameDidEnd(b)
    precondition(!lib.managedGames.contains { $0 === b })
    lib.expect(false)
    a.live = false
    lib.managedGameDidEnd(a)
    precondition(lib.managedGames.contains { $0 === a })
    lib.expect(true)
    a.native = false
    lib.activeCount = 0
    lib.managedGameDidEnd(a)
    precondition(lib.managedGames.isEmpty)
    lib.expect(false)
    let legacy = GameViewController()
    lib.activeCount = 1
    lib.setLegacy(legacy)
    lib.expect(false)
    legacy.live = false
    lib.refresh()
    lib.expect(true)
    lib.activeCount = 0
    lib.setLegacy(nil)
    lib.expect(false)
}
precondition(lib.audioMenuCalls == 9000 && lib.logMenuCalls == 9000)
print("Library ownership and menu: 1000 cycles OK")
'''

def harness(source):
    starts = (
        "    private var retainedGames:",
        "    private var liveGames:",
        "    func managedGameDidPark(",
        "    func managedGameDidEnd(",
        "    private func updateStuckSessionButton()",
        "    private func makeLibraryMenu()",
    )
    methods = []
    for signature in starts:
        start = source.index(signature)
        end = source.index("\n    }", start) + len("\n    }")
        methods.append(source[start:end])
    return PRELUDE + "\n".join(methods) + MAIN


class LibrarySessionNavigationTest(unittest.TestCase):
    def test_parked_token_and_recovery_guards(self):
        game = GAME.read_text(encoding="utf-8")
        self.assertIn("guard libraryIsPresented, parkedTreoActive, ownsLiveGameSession()", game)
        library = LIBRARY.read_text(encoding="utf-8")
        self.assertIn("game.parkedSessionToken == token", library)
        self.assertIn("JarBoxGameStorage.lastTab(jarPath: app.path,", library)
        self.assertNotIn('UIAction(title: "Vào Tab cuối"', library)
        self.assertIn("guard liveGames.isEmpty, jvm_bridge_session_is_active() != 0", library)

    def test_retained_owner_and_menu_lifecycle(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("host Swift compiler unavailable")
        with tempfile.TemporaryDirectory() as td:
            source = Path(td) / "navigation.swift"
            exe = Path(td) / "navigation"
            source.write_text(harness(LIBRARY.read_text(encoding="utf-8")), encoding="utf-8")
            subprocess.run([swift, str(source), "-o", str(exe)], check=True, timeout=60)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Library ownership and menu: 1000 cycles OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
