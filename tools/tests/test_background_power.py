"""Power observation model extracted from Swift production source (not UIKit)."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
SCENE=ROOT/"J2MEEmulator/SceneDelegate.swift"
MAIN=r"""
for _ in 0..<10000 {
    var e = JarBoxPowerEvidence()
    precondition(e.worstThermal == -1 && !e.lowPowerSeen)
    e.observe(thermal: 0, lowPower: false)
    e.observe(thermal: 0, lowPower: false)
    e.observe(thermal: 2, lowPower: true)
    e.observe(thermal: -1, lowPower: true)
    e.observe(thermal: 3, lowPower: false)
    e.observe(thermal: 1, lowPower: false)
    precondition(e.worstThermal == 3 && e.lowPowerSeen)
    precondition(e.powerChanges == 2 && e.thermalChanges == 3)
    precondition(e.log.contains("worst_thermal_observed=3"))
    let next = JarBoxPowerEvidence()
    precondition(next.worstThermal == -1 && next.powerChanges == 0)
}
print("Power observation: 10000 windows PASS")
"""
class BackgroundPowerTest(unittest.TestCase):
    def test_evidence(self):
        swift=shutil.which("swiftc")
        if not swift:self.skipTest("host Swift compiler unavailable")
        s=SCENE.read_text()
        a=s.index("struct JarBoxPowerEvidence {")
        b=s.index("\n}",a)+2
        with tempfile.TemporaryDirectory() as td:
            p,exe=Path(td)/"power.swift",Path(td)/"power"
            p.write_text("import Foundation\n"+s[a:b]+"\n"+MAIN)
            subprocess.run([swift,str(p),"-o",str(exe)],check=True,timeout=60)
            subprocess.run([str(exe)],check=True,timeout=10)
    def test_wiring(self):
        s=SCENE.read_text()
        self.assertIn("guard count > 0 else { return }",s)
        self.assertIn("environmentLine(\"begin\")",s)
        self.assertIn("environmentLine(\"end\")",s)
        self.assertIn("defer { if !previous { device.isBatteryMonitoringEnabled = false } }",s)
        self.assertIn("Notification.Name.NSProcessInfoPowerStateDidChange",s)
        self.assertIn("ProcessInfo.thermalStateDidChangeNotification",s)
        self.assertIn("if thermalCode() == 3 { j2me_audio_background_revalidate() }",s)
        self.assertIn("powerEvidence = JarBoxPowerEvidence()",s)
if __name__=="__main__":unittest.main()
