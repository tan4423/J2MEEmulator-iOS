"""Exercise the actual one-shot protection and restart coordinator using host doubles.

No iOS hardware or native JVM execution is claimed by this test.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

LIB = Path(__file__).resolve().parents[2] / "J2MEEmulator/UI/AppsListViewController.swift"

PRELUDE = r'''
import Foundation
enum Activation { case foregroundActive, background }
class Scene { var activationState: Activation = .foregroundActive }
class Window { var windowScene: Scene? = Scene() }
class View { var window: Window? = Window() }
class Collection { var isDragging = false; var isDecelerating = false }

class Timer {
    let interval: TimeInterval
    let repeats: Bool
    var invalidated = false
    let handler: (Timer) -> Void
    init(timeInterval: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) {
        interval = timeInterval; self.repeats = repeats; handler = block
    }
    func invalidate() { invalidated = true }
    func fire() { if !invalidated { handler(self) } }
}
class RunLoop {
    enum Mode { case `default` }
    static let main = RunLoop()
    func add(_ timer: Timer, forMode: Mode) {}
}
enum JarBoxProtectionPreferences {
    static var automatic = false
    static var seconds = 60
}
struct AppInfo { let path: String; let name: String }
enum JarBoxGameStorage {
    static var selected: UUID?
    static func lastTab(jarPath: String, registered: [UUID]) -> UUID? {
        guard let selected, registered.contains(selected) else { return nil }
        return selected
    }
    static func rememberLastTab(jarPath: String, cloneID: UUID?) { selected = cloneID }
}
@MainActor
class Game {
    let jarPath: String
    let cloneID: UUID?
    var parkedSessionToken: UInt64?
    var parked: (() -> Void)?
    init(_ path: String, _ id: UUID?) { jarPath = path; cloneID = id }
    func parkAfterSettingsRestart() { parkedSessionToken = 1; parked?() }
}
@MainActor
class Library {
    var autoProtectionGeneration: UInt64 = 0
    var autoProtectionTimer: Timer?
    var jarBoxSleepCover: Int?
    var libraryTouchActive = false
    var springboardVisible = true
    var pendingTabMutation: UUID?
    var gamePresentationInFlight = false
    var contextMenuVisible = false
    let view = View()
    var viewIfLoaded: View? { view }
    let springboardCollectionView = Collection()
    var presentedViewController: AnyObject?
    var idle = false
    var opens = 0
    var managedGames: [Game] = []
    var tabs: [(id: UUID?, title: String)] = []
    var launched: [UUID?] = []
    var failLaunch = false
    func setJarBoxSleepIdleTimer(_ value: Bool) { idle = value }
    func showJarBoxSleepScreen() { opens += 1; jarBoxSleepCover = 1 }
    func registeredTabs(for app: AppInfo) throws -> [(id: UUID?, title: String)] { tabs }
    func mutationError(_ text: String) -> NSError {
        NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
    func launchGameTab(_ app: AppInfo, cloneID: UUID?, tabTitle: String) {
        precondition(pendingTabMutation == nil)
        launched.append(cloneID)
        if failLaunch { return }
        let game = Game(app.path, cloneID)
        game.parked = { [weak self] in
            self?.presentedViewController = nil
            self?.springboardVisible = true
            JarBoxGameStorage.selected = cloneID
        }
        managedGames.append(game)
        springboardVisible = false
        presentedViewController = game
    }
    func arm() { armAutoProtection() }
    func cancel() { cancelAutoProtection() }
    func restart(_ ticket: UUID, _ app: AppInfo, _ ids: [UUID?]) async throws {
        try await restartConfiguredTabs(ticket, app: app, ids: ids)
    }
'''

MAIN = r'''
}
@main
struct Harness {
    @MainActor static func drain() async {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    @MainActor static func main() async throws {
        let lib = Library()
        JarBoxProtectionPreferences.automatic = false
        lib.arm()
        precondition(lib.autoProtectionTimer == nil && !lib.idle)
        JarBoxProtectionPreferences.automatic = true
        for _ in 0..<100 {
            lib.jarBoxSleepCover = nil
            lib.opens = 0
            lib.arm()
            let old = lib.autoProtectionTimer!
            precondition(old.interval == 60 && !old.repeats && lib.idle)
            // The timer fired, but an input arrives before the queued task.
            old.fire()
            lib.libraryInputChanged(activeTouch: true)
            await drain()
            precondition(lib.opens == 0 && lib.autoProtectionTimer == nil && !lib.idle)
            lib.libraryInputChanged(activeTouch: false)
            precondition(lib.autoProtectionTimer != nil && lib.idle)
            lib.contextMenuVisible = true
            lib.autoProtectionTimer!.fire()
            await drain()
            precondition(lib.opens == 0 && lib.autoProtectionTimer == nil && !lib.idle)
            lib.contextMenuVisible = false
            lib.arm()
            lib.presentedViewController = NSObject()
            lib.autoProtectionTimer!.fire()
            await drain()
            precondition(lib.opens == 0 && !lib.idle)
            lib.presentedViewController = nil
            lib.arm()
            lib.view.window!.windowScene!.activationState = .background
            lib.autoProtectionTimer!.fire()
            await drain()
            precondition(lib.opens == 0 && !lib.idle)
            lib.view.window!.windowScene!.activationState = .foregroundActive
            lib.pendingTabMutation = UUID()
            lib.arm()
            precondition(lib.autoProtectionTimer == nil)
            lib.pendingTabMutation = nil
            lib.arm()
            lib.autoProtectionTimer!.fire()
            await drain()
            precondition(lib.opens == 1 && lib.autoProtectionTimer == nil)
            lib.arm()
            precondition(lib.autoProtectionTimer == nil)
        }
        lib.jarBoxSleepCover = nil
        let a = UUID(), b = UUID()
        let ticket = UUID(), app = AppInfo(path: "A.jar", name: "A")
        lib.tabs = [(nil, "Tab gốc"), (a, "Tab 1"), (b, "Tab 2")]
        JarBoxGameStorage.selected = b
        lib.pendingTabMutation = ticket
        try await lib.restart(ticket, app, [nil, a])
        precondition(lib.launched == [nil, a])
        precondition(lib.managedGames.count == 2 && lib.managedGames.allSatisfy { $0.parkedSessionToken != nil })
        precondition(JarBoxGameStorage.selected == b && lib.pendingTabMutation == ticket)
        lib.failLaunch = true
        do {
            try await lib.restart(ticket, app, [b])
            fatalError("failed launch accepted")
        } catch {}
        precondition(JarBoxGameStorage.selected == b && lib.pendingTabMutation == ticket)
        print("Idle protection: 100 cycles; restart sequencing: PASS")
    }
}
'''

def method(source, signature):
    start = source.index(signature)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


class SharedSettingsAndProtectionTest(unittest.TestCase):
    def test_actual_idle_generation_and_restart_sequence(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("host Swift compiler unavailable")
        source = LIB.read_text(encoding="utf-8")
        code = PRELUDE + "\n".join(method(source, name) for name in (
            "    private func cancelAutoProtection()",
            "    func libraryInputChanged(",
            "    private func armAutoProtection()",
            "    private func restartConfiguredTabs(",
        )) + MAIN
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "settings.swift"
            exe = Path(td) / "settings"
            src.write_text(code, encoding="utf-8")
            subprocess.run([swift, "-swift-version", "5", "-parse-as-library", str(src), "-o", str(exe)],
                           check=True, timeout=60)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Idle protection: 100 cycles; restart sequencing: PASS", result.stdout)

    def test_settings_and_lifecycle_wiring(self):
        source = LIB.read_text(encoding="utf-8")
        self.assertIn('UIAction(title: "Cài đặt"', source)
        self.assertNotIn('UIAction(title: "Vào Tab cuối"', source)
        self.assertIn('let proxy = UIAlertAction(title: "Proxy"', source)
        self.assertIn("proxy.isEnabled = false", source)
        self.assertIn('UISegmentedControl(items: ["Tự động", "Ấn tay"])', source)
        self.assertIn("seconds.isEnabled = enabled", source)
        self.assertIn("(5...3600).contains(value)", source)
        self.assertIn("repeats: false", method(source, "    private func armAutoProtection()"))
        for signature in ("    override func viewWillDisappear(", "    @objc private func jarBoxWillResignActive()"):
            self.assertIn("cancelAutoProtection()", method(source, signature))
        self.assertIn("armAutoProtection()", method(source, "    @objc private func hideJarBoxSleepScreen()"))
        scene = (LIB.parents[1] / "SceneDelegate.swift").read_text(encoding="utf-8")
        self.assertIn("override func sendEvent(_ event: UIEvent)", scene)
        self.assertIn("super.sendEvent(event)", scene)
        self.assertIn("library?.libraryInputChanged(activeTouch: active)", scene)


if __name__ == "__main__":
    unittest.main()
