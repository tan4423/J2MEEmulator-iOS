"""Portrait directional-grid behavior using the actual Swift geometry helper.

UIKit touch delivery and constraints still require an iPhone build/device test.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"


class PortraitDirectionPadTests(unittest.TestCase):
    def test_grid_hit_testing(self):
        swift = shutil.which("swift")
        if not swift:
            self.skipTest("Swift host compiler unavailable")
        source = GAME.read_text()
        start = source.index("private enum JarBoxPadGrid {")
        end = source.index("// One continuous touch", start)
        helper = source[start:end].replace("private enum JarBoxPadGrid", "enum JarBoxPadGrid", 1)
        main = r'''
let expected: [Int32] = [49, -1, 51, -3, -5, -4, 55, -2, 57]
var checks = 0
for width in [CGFloat(320), 375, 390, 430] {
    let b = CGRect(x: 0, y: 0, width: width * 2 / 3, height: 132)
    for i in 0..<9 {
        let cell = JarBoxPadGrid.cell(i, in: b)
        let center = CGPoint(x: cell.midX, y: cell.midY)
        precondition(JarBoxPadGrid.code(at: center, in: b, previous: nil) == expected[i])
        for old in expected {
            precondition(JarBoxPadGrid.code(at: center, in: b, previous: old) == expected[i])
            checks += 1
        }
    }
    for _ in 0..<1000 {
        let edge = b.width / 3 * 2
        precondition(JarBoxPadGrid.code(at: CGPoint(x: edge + 1, y: 22), in: b, previous: -1) == -1)
        precondition(JarBoxPadGrid.code(at: CGPoint(x: edge + 5, y: 22), in: b, previous: -1) == 51)
        precondition(JarBoxPadGrid.code(at: CGPoint(x: edge + 5, y: 66), in: b, previous: 51) == -4)
        precondition(JarBoxPadGrid.code(at: CGPoint(x: -1, y: 66), in: b, previous: -4) == nil)
        checks += 4
    }
}
print("Portrait pad geometry: \(checks) checks PASS")
'''
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "pad.swift"
            # macOS exposes CGRect through Foundation but its geometry APIs
            # require CoreGraphics. Linux Foundation supplies them directly.
            imports = "import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n"
            p.write_text(imports + helper + main)
            result = subprocess.run([swift, str(p)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("16324 checks PASS", result.stdout)

    def test_touch_lifecycle_and_layout_wiring(self):
        source = GAME.read_text()
        pad = source.split("private final class JarBoxDirectionalPad:", 1)[1].split("// MARK: - GameViewController", 1)[0]
        route = source.split("private func makeDirectionalPad()", 1)[1].split("private func directionDown", 1)[0]
        self.assertIn("button.isUserInteractionEnabled = false", pad)
        self.assertIn("override func touchesMoved", pad)
        self.assertIn("ObjectIdentifier($0) == trackedTouch", pad)
        self.assertIn("visibleToken?() == trackedToken", pad)
        self.assertIn("transition(to: nil)", pad)
        self.assertIn("trackedTouch = nil", pad)
        self.assertIn("token == self.gameSessionToken", route)
        self.assertLess(route.index("self.releaseDirection(previous)"), route.index("self.directionDown(next)"))
        self.assertIn("directionalPad?.cancelGameInput()", source)
        self.assertIn("multiplier: 2.0 / 3.0", source)
        self.assertIn("greaterThanOrEqualToConstant: 144", source)
        self.assertIn("portraitPanelCollapsedHeight?.isActive = true", source)
        self.assertIn("portraitCanvasAspect?.isActive = true", source)
        self.assertIn('UIImage(systemName: "square.fill")', pad)
        self.assertIn('UIImage(systemName: "minus")', source)


if __name__ == "__main__":
    unittest.main()
