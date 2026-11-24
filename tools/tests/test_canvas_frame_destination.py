"""Compile the exact Swift foreground frame route with a fake view on Linux/macOS."""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "J2MEEmulator"
MAIN = r'''
final class FakeView: @unchecked Sendable {}
private let route = GameFrameDestination<FakeView>()
let a = FakeView(), b = FakeView()
for _ in 0..<10000 {
    route.bind(a, token: 11)
    precondition(route.lookup(token: 11) === a && route.lookup(token: 22) == nil)
    route.bind(b, token: 22)
    route.unbind(token: 11)
    precondition(route.lookup(token: 11) == nil && route.lookup(token: 22) === b)
    route.unbind(token: 22)
    precondition(route.lookup(token: 22) == nil)
    route.bind(a, token: 33)
    precondition(route.lookup(token: 11) == nil && route.lookup(token: 33) === a)
    route.unbind(token: 33)
}
var temporary: FakeView? = FakeView()
route.bind(temporary!, token: 44)
temporary = nil
precondition(route.lookup(token: 44) == nil)
DispatchQueue.concurrentPerform(iterations: 4) { index in
    for _ in 0..<10000 {
        if index == 0 { route.bind(a, token: 11); route.unbind(token: 11) }
        else if index == 1 { route.bind(b, token: 22); route.unbind(token: 22) }
        else {
            if let v = route.lookup(token: 11) { precondition(v === a) }
            if let v = route.lookup(token: 22) { precondition(v === b) }
            precondition(route.lookup(token: 0) == nil)
        }
    }
}
print("frame route: 10000 cycles + concurrent 40000 iterations PASS")
'''


class CanvasFrameDestinationTest(unittest.TestCase):
    def test_exact_swift_route(self):
        swift = shutil.which("swiftc")
        if not swift:
            self.skipTest("Swift compiler unavailable")
        source = (ROOT / "UI/EmulatorView.swift").read_text()
        a = source.index("nonisolated private final class GameFrameDestination<")
        b = source.index("\n}", a) + 2
        with tempfile.TemporaryDirectory() as td:
            p, exe = Path(td) / "route.swift", Path(td) / "route"
            p.write_text("import Foundation\n" + source[a:b] + "\n" + MAIN)
            subprocess.run([swift, "-swift-version", "6", "-strict-concurrency=complete",
                            "-warnings-as-errors", str(p), "-o", str(exe)], check=True, timeout=60)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=15)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn("10000 cycles + concurrent 40000 iterations PASS", r.stdout)

    def test_native_token_and_main_drain(self):
        source = (ROOT / "UI/EmulatorView.swift").read_text()
        self.assertNotIn("globalEmulatorView", source)
        self.assertNotIn("j2me_render_is_afk_suspended()", source)
        self.assertIn("gameFrameDestination.lookup(token: frame.token) === self", source)
        self.assertIn("treo_mode_for_token(frame.token) == 0", source)
        self.assertIn("self.inputSessionToken == frame.token", source)
        render = (ROOT / "NativeBridge/j2me_render.m").read_text()
        self.assertIn("owned_flush(image, rc->width, rc->height, rc->heap_key, token)", render)
        game = (ROOT / "UI/GameViewController.swift").read_text()
        self.assertIn("unbindGameFrameView(token: launchingToken)", game)
        self.assertIn("bindGameFrameView(emulatorView, token: acquiredToken)", game)
        self.assertNotIn("setGlobalEmulatorView", game)


if __name__ == "__main__":
    unittest.main()
