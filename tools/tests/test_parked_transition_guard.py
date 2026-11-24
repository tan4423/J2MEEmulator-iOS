"""Source contract for Back: no hiding a game until its own Treo succeeds."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"


class ParkedTransitionGuardTest(unittest.TestCase):
    def test_both_library_paths_require_running_owner_and_successful_park(self):
        source = GAME.read_text(encoding="utf-8")
        body = source.split("@objc private func openLibraryKeepingGame() {", 1)[1].split("\n    }", 1)[0]
        # A STARTING or STOPPING owner must not lose its startup watchdog,
        # diagnostics or focus just because Back was tapped.
        ready = body.index("guard treo_mode_for_token(gameSessionToken) >= 0 else { return }")
        self.assertNotIn("jvm_bridge_session_phase()", body)
        for effect in ("stopJarAudit()", "discardCPUProfile()", "releaseDirection(code)",
                       "hideBlackout()", "startParkedTreo()"):
            self.assertLess(ready, body.index(effect), effect)
        park = body.index("startParkedTreo()")
        confirmed = body.index("guard parkedTreoActive else { return }")
        self.assertLess(park, confirmed)
        self.assertEqual(body.count("startParkedTreo()"), 1)
        # The no-owner escape hatch may dismiss without Treo; a live
        # owner's managed dismissal must still follow confirmed park.
        no_owner = body.index("guard ownsJVMSession else {")
        self.assertLess(no_owner, body.index("dismiss(animated: false)"))
        self.assertLess(body.index("dismiss(animated: false)"), ready)
        self.assertLess(confirmed, body.index("dismiss(animated: false)", confirmed))
        for effect in ("finishStartupWatchdog()", "if let library = sessionLibrary",
                       "libraryIsPresented = true", "setGlobalEmulatorView(nil)",
                       "emulatorView.clearPendingGameFrame()",
                       "present(navigation, animated: false)"):
            self.assertLess(confirmed, body.index(effect), effect)


if __name__ == "__main__":
    unittest.main()
