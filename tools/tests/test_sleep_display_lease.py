"""Run actual Swift screen-protection display lease methods with host doubles.

The host simulates UIKit state transitions, not iOS hardware or real brightness.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = ROOT / "J2MEEmulator/UI/AppsListViewController.swift"
SCENE = ROOT / "J2MEEmulator/SceneDelegate.swift"

PRELUDE = r'''
import Foundation
class UIScreen { var brightness: CGFloat = 0.6 }
class UIApplication {
    static let shared = UIApplication()
    var isIdleTimerDisabled = false
}
enum Activation { case foregroundActive, foregroundInactive, background }
class Scene {
    let screen = UIScreen()
    var activationState = Activation.foregroundActive
}
class Window { var windowScene: Scene? = Scene() }
class View {
    var window: Window? = Window()
    var isHidden = false
}
class Library {
    var jarBoxSleepCover: View? = View()
    var springboardVisible = true
    let view = View()
    var jarBoxSleepBrightness: (screen: UIScreen, previous: CGFloat)?
    var jarBoxSleepIdleTimerWasDisabled: Bool?
    var hudVisible = false
    func hideJarBoxSleepInformation() { hudVisible = false }
'''

MAIN = r'''
    func event(_ active: Bool) { setJarBoxSleepSampling(active) }
}
let lib = Library()
let screen = lib.view.window!.windowScene!.screen
let scene = lib.view.window!.windowScene!
let app = UIApplication.shared
for _ in 0..<1000 {
    // Foreground acquire, duplicate positive notifications, and HUD lifetime.
    screen.brightness = 0.6
    app.isIdleTimerDisabled = false
    lib.event(true)
    lib.event(true)
    precondition(screen.brightness == 0 && app.isIdleTimerDisabled)
    lib.hudVisible = true
    // Control Center / app switch: release before actual scene state changes.
    lib.event(false)
    precondition(screen.brightness == 0.6 && !app.isIdleTimerDisabled && !lib.hudVisible)
    scene.activationState = .foregroundInactive
    lib.event(false)
    lib.event(true)  // stale positive event
    precondition(screen.brightness == 0.6 && !app.isIdleTimerDisabled)
    // User changes brightness outside cover; next lease saves new baseline.
    screen.brightness = 0.8
    scene.activationState = .foregroundActive
    lib.event(true)
    precondition(screen.brightness == 0 && app.isIdleTimerDisabled)
    // Temporary controller presentation: release while retaining cover.
    lib.springboardVisible = false
    lib.event(false)
    lib.jarBoxSleepCover!.isHidden = true
    precondition(screen.brightness == 0.8 && !app.isIdleTimerDisabled)
    lib.event(true)
    precondition(screen.brightness == 0.8)
    lib.springboardVisible = true
    lib.jarBoxSleepCover!.isHidden = false
    lib.event(true)
    precondition(screen.brightness == 0 && app.isIdleTimerDisabled)
    // External brightness change is not clobbered by release.
    screen.brightness = 0.4
    lib.event(false)
    precondition(screen.brightness == 0.4 && !app.isIdleTimerDisabled)
    // Prior auto-lock override must survive the lease.
    app.isIdleTimerDisabled = true
    lib.event(true)
    lib.event(false)
    precondition(app.isIdleTimerDisabled && screen.brightness == 0.4)
    // Explicit Back destroys cover; future positive events are inert.
    lib.jarBoxSleepCover = nil
    lib.event(true)
    precondition(screen.brightness == 0.4 && app.isIdleTimerDisabled)
    lib.jarBoxSleepCover = View()
}
print("Protection display lease: 1000 cycles OK")
'''

def method(source, name):
    start = source.index("    private func " + name + "(")
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


class SleepDisplayLeaseTest(unittest.TestCase):
    def test_display_lease_transitions(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("host Swift compiler unavailable")
        source = LIB.read_text(encoding="utf-8")
        code = PRELUDE + "\n".join(method(source, name) for name in (
            "setJarBoxSleepBrightness", "setJarBoxSleepIdleTimer", "setJarBoxSleepSampling"
        )) + MAIN
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "lease.swift"
            exe = Path(td) / "lease"
            src.write_text(code, encoding="utf-8")
            subprocess.run([swift, str(src), "-o", str(exe)], check=True, timeout=60)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("Protection display lease: 1000 cycles OK", result.stdout)

    def test_lifecycle_does_not_destroy_cover_on_temporary_disappearance(self):
        src = LIB.read_text(encoding="utf-8")
        # Scope to the library, not the status modal's identically named hooks.
        library = src.split("class AppsListViewController: UIViewController,", 1)[1]
        disappear = library.split("override func viewWillDisappear(", 1)[1].split(
            "override func viewDidDisappear(", 1)[0]
        appear = library.split("override func viewDidAppear(", 1)[1].split(
            "override func viewWillDisappear(", 1)[0]
        self.assertIn("if isBeingDismissed || isMovingFromParent ||", disappear)
        self.assertIn("setJarBoxSleepSampling(false)", disappear)
        self.assertIn("jarBoxSleepCover?.isHidden = true", disappear)
        self.assertIn("cover.isHidden = false", appear)
        self.assertIn("setJarBoxSleepSampling(sceneActive)", appear)
        self.assertIn("jarBoxSleepCover == nil && !gamePresentationInFlight", src)
        self.assertIn("cover.accessibilityViewIsModal = true", src)
        scene = SCENE.read_text(encoding="utf-8")
        for name in ("sceneDidDisconnect", "sceneDidEnterBackground"):
            body = scene.split("func " + name + "(", 1)[1].split("\n    }", 1)[0]
            self.assertIn("updateSpringboardSceneActivity(false)", body)


if __name__ == "__main__":
    unittest.main()
