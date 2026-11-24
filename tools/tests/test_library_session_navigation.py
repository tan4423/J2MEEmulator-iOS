"""Exercise the production library refresh method using host Swift UI doubles."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "J2MEEmulator/UI/AppsListViewController.swift"
PRELUDE = r'''
import Foundation

enum Style { case plain }
enum Color { case systemRed }
class UIBarButtonItem {
    let title: String
    var tintColor: Color?
    init(title: String, style: Style, target: AnyObject, action: String) {
        self.title = title
    }
}
class NavigationItem {
    var title: String?
    var leftBarButtonItem: UIBarButtonItem?
    var rightBarButtonItems: [UIBarButtonItem]?
}
class Game {
    let appName: String
    var live = true
    init(_ name: String) { appName = name }
    func ownsLiveGameSession() -> Bool { live }
}
class Library {
    let navigationItem = NavigationItem()
    var games: [Game] = []
    var liveGames: [Game] { games.filter { $0.ownsLiveGameSession() } }
    var activeCount = 0
    func jvm_bridge_session_is_active() -> Int32 { activeCount == 0 ? 0 : 1 }
    lazy var importBarButton: UIBarButtonItem? = UIBarButtonItem(title: "+", style: .plain, target: self, action: "import")
    lazy var jarBoxMenuButton: UIBarButtonItem? = UIBarButtonItem(title: "Menu", style: .plain, target: self, action: "menu")
'''
MAIN = r'''
    func refresh() { updateStuckSessionButton() }
    func expect(_ title: String, _ left: String?, _ right: [String]) {
        precondition(navigationItem.title == title, "title: \(String(describing: navigationItem.title))")
        precondition(navigationItem.leftBarButtonItem?.title == left)
        precondition(navigationItem.rightBarButtonItems?.map { $0.title } == right)
    }
}
let lib = Library()
for _ in 0..<1000 {
    let a = Game("A"), b = Game("B")
    lib.games = [a]
    lib.activeCount = 1
    lib.refresh()
    lib.expect("Đang chạy ẩn: A", "Tiếp tục", ["+", "Dừng", "Menu"])
    lib.games.append(b)
    lib.activeCount = 2
    lib.refresh()
    lib.expect("Đang chạy ẩn: 2 tab", "Tiếp tục", ["+", "Dừng", "Menu"])
    a.live = false
    lib.activeCount = 1
    lib.refresh()
    lib.expect("Đang chạy ẩn: B", "Tiếp tục", ["+", "Dừng", "Menu"])
    b.live = false
    // Stopping owners still occupy the registry; keep recovery, not Resume.
    lib.refresh()
    lib.expect("Phiên JVM chưa dừng", "Xử lý phiên kẹt", ["+", "Menu"])
    lib.activeCount = 0
    // Even if stale controllers remain, the entire navigation state resets.
    lib.refresh()
    lib.expect("Thư viện", nil, ["+", "Menu"])
    lib.games = []
    lib.refresh()
    lib.expect("Thư viện", nil, ["+", "Menu"])
}
// Direct live-to-idle transition (normal spontaneous exit or explicit stop).
lib.games = [Game("C")]
lib.activeCount = 1
lib.refresh()
lib.games = []
lib.activeCount = 0
lib.refresh()
lib.expect("Thư viện", nil, ["+", "Menu"])
print("Library navigation lifecycle: OK")
'''


def harness(source):
    start = source.index("    private func updateStuckSessionButton() {")
    end = source.index("\n    }", start) + len("\n    }")
    body = source[start:end]
    # Linux Swift lacks Objective-C interoperability. Selectors are opaque
    # button action names here; UIKit itself is not exercised.
    body = re.sub(r"#selector\((\w+)\)", r'"\1"', body)
    return PRELUDE + body + MAIN


class LibrarySessionNavigationTest(unittest.TestCase):
    def test_navigation_rebuilt_after_last_session_retires(self):
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
            self.assertIn("Library navigation lifecycle: OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
