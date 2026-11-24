"""Host Swift presentation model and source guards for rapid open/close."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIBRARY = ROOT / "J2MEEmulator/UI/AppsListViewController.swift"
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"
PRELUDE = r"""
import Foundation
class View { var window: Int? = 1 }
class GameViewController {}
class Library {
    var presentedViewController: GameViewController?
    var viewIfLoaded: View? = View()
    var isBeingDismissed = false
    private var gamePresentationInFlight = false
    var jarBoxSleepCover: Int?
    var completions: [() -> Void] = []
    var presented: [GameViewController] = []
    func setSpringboardMotion(_ enabled: Bool, reason: String) {}
    func present(_ game: GameViewController, animated: Bool, completion: @escaping () -> Void) {
        precondition(!animated)
        presented.append(game)
        // Model UIKit deferring publication of presentedViewController.
        completions.append(completion)
    }
"""
MAIN = r"""
    func launch(_ game: GameViewController) { presentGame(game, reason: "test") }
}
let lib = Library()
let game = GameViewController()
for _ in 0..<1000 {
    let before = lib.presented.count
    lib.launch(game)
    for _ in 0..<100 { lib.launch(game) }
    precondition(lib.presented.count == before + 1)
    lib.presentedViewController = game
    lib.completions.removeFirst()()
    lib.launch(game)
    precondition(lib.presented.count == before + 1)
    lib.presentedViewController = nil
}
lib.jarBoxSleepCover = 1
lib.launch(game)
precondition(lib.presented.count == 1000)
lib.jarBoxSleepCover = nil
lib.isBeingDismissed = true
lib.launch(game)
precondition(lib.presented.count == 1000)
lib.isBeingDismissed = false
lib.viewIfLoaded?.window = nil
lib.launch(game)
precondition(lib.presented.count == 1000)
print("Single-flight presentation: 1000 cycles OK")
"""


def method(source, marker):
    start = source.index(marker)
    end = source.index("\n    }", start) + len("\n    }")
    return source[start:end]


class GamePresentationGateTest(unittest.TestCase):
    def test_presentation_single_flight(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("host Swift compiler unavailable")
        lib = LIBRARY.read_text(encoding="utf-8")
        code = PRELUDE + method(lib, "    private var canPresentGame: Bool {") + "\n\n" + method(lib, "    private func presentGame(") + MAIN
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "gate.swift"
            exe = Path(td) / "gate"
            src.write_text(code, encoding="utf-8")
            subprocess.run([swift, str(src), "-o", str(exe)], check=True, timeout=60)
            result = subprocess.run([str(exe)], check=True, capture_output=True, text=True, timeout=10)
            self.assertIn("Single-flight presentation: 1000 cycles OK", result.stdout)

    def test_both_game_entry_points_use_gate_and_worker_validates_save(self):
        lib = LIBRARY.read_text(encoding="utf-8")
        game = GAME.read_text(encoding="utf-8")
        launch = method(lib, "    private func launchGameTab(")
        resume = method(lib, "    func resumeManagedGame(")
        self.assertLess(launch.index("guard canPresentGame else"), launch.index("gameForTab("))
        self.assertIn("guard canPresentGame,", resume)
        self.assertIn('presentGame(gameVC, reason: "game launching")', launch)
        self.assertIn('presentGame(game, reason: "resume retained game")', resume)
        self.assertNotIn("JarBoxGameStorage.prepareRoot(", launch)
        worker = method(game, "    nonisolated private static func runMIDlet(")
        self.assertLess(worker.index("JarBoxGameStorage.prepareRoot("), worker.index("jvm_bridge_init_for_token("))

    def test_repeat_stop_does_not_open_recovery_before_watchdog(self):
        game = GAME.read_text(encoding="utf-8")
        self.assertIn("private var stopRecoveryAvailable = false", game)
        recovery = method(game, "    private func showStuckSessionRecovery()")
        self.assertIn("guard stopRecoveryAvailable, stopRecoveryAlert == nil,", recovery)
        self.assertIn("holdsNativeGameSession()", recovery)
        self.assertLess(recovery.index("stopRecoveryAlert = alert"), recovery.index("if let previous = presentedViewController"))
        stop = method(game, "    private func requestGameStop(")
        self.assertLess(stop.index("if gameStopRequested {"), stop.index("jvm_bridge_request_stop_for_token(token)"))
        self.assertLess(stop.index("let rescue = DispatchWorkItem"), stop.index("self.stopRecoveryAvailable = true"))
        self.assertLess(stop.index("self.stopRecoveryAvailable = true"), stop.rindex("self.showStuckSessionRecovery()"))


if __name__ == "__main__":
    unittest.main()
