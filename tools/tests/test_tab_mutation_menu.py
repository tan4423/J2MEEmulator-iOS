"""Exercise production stop menu and registry proof with host Swift doubles.

No UIKit, disk payloads, or native JVM are executed by this harness.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[2] / "J2MEEmulator/UI/AppsListViewController.swift"

PRELUDE = r'''
import Foundation
var live: Set<UInt64> = []
var retireOnRead: UInt64? = nil
func jvm_bridge_active_session_count() -> Int32 { Int32(live.count) }
func jvm_bridge_session_is_active_for_token(_ token: UInt64) -> Int32 {
    let answer: Int32 = live.contains(token) ? 1 : 0
    if retireOnRead == token { live.remove(token); retireOnRead = nil }
    return answer
}
enum JarBoxGameStorage {
'''

DOUBLES = r'''
}
struct AppInfo { let path: String }
struct UIImage { init(systemName: String) {} }
struct Attributes: OptionSet {
    let rawValue: Int
    static let destructive = Self(rawValue: 1)
    static let disabled = Self(rawValue: 2)
}
class UIMenuElement {}
class UIAction: UIMenuElement {
    let title: String; let attributes: Attributes; let handler: (UIAction) -> Void
    init(title: String, image: UIImage?, attributes: Attributes, handler: @escaping (UIAction) -> Void) {
        self.title = title; self.attributes = attributes; self.handler = handler
    }
    func tap() { if !attributes.contains(.disabled) { handler(self) } }
}
class UIMenu: UIMenuElement {
    let title: String; let children: [UIMenuElement]
    init(title: String, image: UIImage?, children: [UIMenuElement]) {
        self.title = title; self.children = children
    }
}
class GameViewController {
    let id: UUID?; let path: String; var parkedSessionToken: UInt64?; var stops = 0
    init(_ id: UUID?, _ path: String, _ token: UInt64?) {
        self.id = id; self.path = path; parkedSessionToken = token
    }
    func stopParkedGame() { stops += 1; parkedSessionToken = nil }
}
class Library {
    var retainedGames: [GameViewController] = []
    var pendingTabMutation: UUID?
    func updateStuckSessionButton() {}
    func gameForTab(_ path: String, cloneID: UUID?) -> GameViewController? {
        retainedGames.first { $0.path == path && $0.id == cloneID && $0.parkedSessionToken != nil }
    }
    func make(_ app: AppInfo, _ tabs: [(id: UUID?, title: String)]) -> UIMenuElement {
        stopMenu(for: app, tabs: tabs)
    }
'''

MAIN = r'''
}
func allowed(_ tokens: [UInt64]) -> Bool {
    do { try JarBoxGameStorage.requireMutationSafety(unrelatedTokens: tokens); return true }
    catch { return false }
}
var checks = 0
func check(_ ok: @autoclosure () -> Bool) { precondition(ok()); checks += 1 }
for _ in 0..<1000 {
    live = []; check(allowed([])); check(allowed([999]))
    live = [1]; check(!allowed([])); check(allowed([1])); check(allowed([1,1])); check(!allowed([2]))
    live = [1,2]; check(!allowed([1])); check(allowed([1,2])); check(!allowed([1,3]))
    live = [1,2]; retireOnRead = 1; check(!allowed([1])); check(live == [2])
    live = [1,2]; retireOnRead = 1; check(!allowed([1,2]))
    let lib = Library(); let app = AppInfo(path: "A.jar")
    let ids = (0..<29).map { _ in UUID() }
    let tabs: [(UUID?, String)] = [(nil,"Tab gốc")] + ids.enumerated().map {
        (Optional($0.element), "Tab " + String($0.offset + 1))
    }
    let original = GameViewController(nil,app.path,nil)
    let a = GameViewController(ids[0],app.path,11)
    let b = GameViewController(ids[1],app.path,12)
    let other = GameViewController(nil,"B.jar",13)
    lib.retainedGames = [original,other]
    check((lib.make(app,tabs) as! UIAction).attributes.contains(.disabled))
    lib.retainedGames.append(a)
    let direct = lib.make(app,tabs) as! UIAction
    check(!direct.attributes.contains(.disabled)); check(direct.title == "Dừng")
    lib.pendingTabMutation = UUID(); direct.tap(); check(a.stops == 0)
    lib.pendingTabMutation = nil
    lib.retainedGames.append(b)
    let menu = lib.make(app,tabs) as! UIMenu
    check(menu.children.map { ($0 as! UIAction).title } == ["Tất cả","Tab 1","Tab 2"])
    a.parkedSessionToken = 99
    (menu.children[0] as! UIAction).tap()
    check(a.stops == 0); check(b.stops == 1); check(other.stops == 0)
    direct.tap(); check(a.stops == 0)
    let new = lib.make(app,tabs) as! UIAction
    new.tap(); check(a.stops == 1); check(other.stops == 0)
}
print(String(checks) + " assertions passed")
'''


def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


class TabMutationMenuTest(unittest.TestCase):
    def test_actual_menu_and_native_owner_proof(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("host Swift compiler unavailable")
        source = LIB.read_text(encoding="utf-8")
        code = PRELUDE + method(source, "    nonisolated static func requireMutationSafety(") + DOUBLES
        code += method(source, "    private func stopMenu(") + MAIN
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "mutation.swift"
            exe = Path(td) / "mutation"
            src.write_text(code, encoding="utf-8")
            subprocess.run([swift, "-swift-version", "5", str(src), "-o", str(exe)], check=True, timeout=60)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("23000 assertions passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
