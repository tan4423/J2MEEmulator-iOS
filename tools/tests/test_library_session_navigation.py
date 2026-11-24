"""Run production library navigation and last-tab methods with Swift host doubles."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "J2MEEmulator/UI/AppsListViewController.swift"
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
    func ownsLiveGameSession() -> Bool { live }
    func holdsNativeGameSession() -> Bool { native }
    func resumeParkedGame() { resumes += 1 }
}
class Collection { func reloadData() {} }
class Library {
    let navigationItem = NavigationItem()
    let springboardCollectionView = Collection()
    var activeCount = 0
    var canPresentGame = true
    var managedGames: [GameViewController] = []
    weak var lastManagedParkedGame: GameViewController?
    weak var parkedGameController: GameViewController?
    var importBarButton: UIBarButtonItem? = UIBarButtonItem("+")
    var jarBoxMenuButton: UIBarButtonItem? = UIBarButtonItem("Menu")
    func jvm_bridge_session_is_active() -> Int32 { activeCount == 0 ? 0 : 1 }
    func showJarBoxSleepScreen() {}
    func showJarBoxOverview() {}
    func openStuckSessionRecovery() {}
'''
MAIN = r'''
    func refresh() { updateStuckSessionButton() }
    func menuAction(_ title: String) -> UIAction? {
        jarBoxMenuButton?.menu?.children.compactMap { $0 as? UIAction }
            .first { $0.title == title }
    }
    func expect(_ resumable: Bool, _ recovery: Bool) {
        precondition(navigationItem.title == "Thư viện")
        precondition(navigationItem.leftBarButtonItem == nil)
        precondition(navigationItem.rightBarButtonItems?.map { $0.title } == ["+", "Menu"])
        precondition(menuAction("Vào Tab cuối")?.attributes.contains(.disabled) == !resumable)
        precondition((menuAction("Xử lý phiên kẹt") != nil) == recovery)
        precondition(menuAction("Bảo vệ màn hình") != nil)
    }
    func resume() {
        let action = menuAction("Vào Tab cuối")!
        action.handler(action)
    }
}
let lib = Library()
for _ in 0..<1000 {
    let a = GameViewController(), b = GameViewController()
    lib.managedGames = [a, b]
    lib.activeCount = 2
    lib.managedGameDidPark(a)
    lib.expect(true, false)
    lib.resume()
    precondition(a.resumes == 1 && b.resumes == 0)
    lib.managedGameDidPark(b)
    lib.expect(true, false)
    lib.resume()
    precondition(a.resumes == 1 && b.resumes == 1)
    lib.canPresentGame = false
    lib.resume()
    precondition(b.resumes == 1)
    lib.canPresentGame = true
    let stale = lib.menuAction("Vào Tab cuối")!
    b.live = false
    stale.handler(stale)
    precondition(a.resumes == 1 && b.resumes == 1)
    lib.managedGameDidEnd(b)
    lib.expect(false, false)
    b.native = false
    lib.activeCount = 1
    lib.managedGameDidEnd(b)
    lib.expect(false, false)
    a.live = false
    lib.managedGameDidEnd(a)
    lib.expect(false, true)
    a.native = false
    lib.activeCount = 0
    lib.managedGameDidEnd(a)
    lib.expect(false, false)
    let legacy = GameViewController()
    lib.parkedGameController = legacy
    lib.activeCount = 1
    lib.refresh()
    lib.expect(true, false)
    lib.resume()
    precondition(legacy.resumes == 1)
    lib.parkedGameController = nil
    lib.activeCount = 0
    lib.refresh()
    lib.expect(false, false)
}
print("Library last-tab navigation: 1000 cycles OK")
'''

def harness(source):
    starts = (
        "    private var retainedGames:",
        "    private var liveGames:",
        "    private var lastParkedGame:",
        "    func managedGameDidPark(",
        "    func managedGameDidEnd(",
        "    private func updateStuckSessionButton()",
        "    private func makeLibraryMenu()",
        "    private func resumeLastParkedGame()",
    )
    methods = []
    for signature in starts:
        start = source.index(signature)
        end = source.index("\n    }", start) + len("\n    }")
        methods.append(source[start:end])
    return PRELUDE + "\n".join(methods) + MAIN


class LibrarySessionNavigationTest(unittest.TestCase):
    def test_last_parked_owner_and_menu_lifecycle(self):
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
            self.assertIn("Library last-tab navigation: 1000 cycles OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
