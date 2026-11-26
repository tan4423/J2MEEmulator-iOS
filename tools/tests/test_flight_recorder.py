"""Host tests of production file journal and sampling policy."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
MAIN=r"""
let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let store = JarBoxFlightStore(directory: root, limit: 128)
for i in 0..<1000 {
    try store.append("event=sample seq=\(i)", durable: false)
    precondition(store.report().utf8.count <= 256)
}
precondition(store.report().contains("seq=999"))
let reopened = JarBoxFlightStore(directory: root, limit: 128)
precondition(reopened.report() == store.report())
let before = reopened.report()
do { try reopened.append(String(repeating:"x",count:129),durable:true); fatalError("oversize accepted") } catch {}
precondition(reopened.report() == before)
for _ in 0..<10000 {
    var p = JarBoxFlightPolicy()
    var a = p.observe(wall:1_000_000_000,cpu:0,valid:true,signature:"1:2:0",urgent:false)
    precondition(a.save && a.percent == nil)
    a = p.observe(wall:6_000_000_000,cpu:1_000_000_000,valid:true,signature:"1:2:0",urgent:false)
    precondition(!a.save && a.percent == 20)
    a = p.observe(wall:11_000_000_000,cpu:6_000_000_000,valid:true,signature:"1:2:0",urgent:false)
    precondition(a.save && a.percent == 100)
    a = p.observe(wall:31_000_000_000,cpu:7_000_000_000,valid:true,signature:"1:2:0",urgent:false)
    precondition(a.save && a.gap == 20_000_000_000)
    a = p.observe(wall:36_000_000_000,cpu:1,valid:true,signature:"busy",urgent:true)
    precondition(a.save && a.percent == nil)
    a = p.observe(wall:41_000_000_000,cpu:2,valid:false,signature:"busy",urgent:true)
    precondition(a.save && a.percent == nil)
}
print("1000 journal appends; 10000 sampling sequences PASS")
"""
class FlightRecorderTest(unittest.TestCase):
    def test_store_policy(self):
        swift=shutil.which("swiftc")
        if not swift:self.skipTest("Swift unavailable")
        s=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        a=s.index("nonisolated final class JarBoxFlightStore")
        b=s.index("nonisolated final class JarBoxFlightRecorder",a)
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)
            (p/"main.swift").write_text("import Foundation\n"+s[a:b]+MAIN)
            subprocess.run([swift,str(p/"main.swift"),"-o",str(p/"test")],check=True,timeout=60)
            subprocess.run([str(p/"test")],check=True,timeout=30)
    def test_wiring(self):
        native=(ROOT/"J2MEEmulator/NativeBridge/jvm_bridge.c").read_text()
        sampler=native.split("int jvm_bridge_flight_sample(",1)[1].split("\n}",1)[0]
        for anchor in ("pthread_mutex_trylock(&g_bridge_lifecycle_lock)","pthread_mutex_trylock(&bridge_cpu_lock)","jarbox_session_reserve_callback(vm->session)","jarbox_session_callback_done(session)","unsigned budget=128"):
            self.assertIn(anchor,sampler)
        self.assertNotIn("pthread_mutex_lock(",sampler)
        self.assertNotIn("threadlist_",sampler)
        scene=(ROOT/"J2MEEmulator/SceneDelegate.swift").read_text()
        for anchor in ("completeUntilFirstUserAuthentication","repeating: .seconds(5)","timer?.cancel()"):
            self.assertIn(anchor,scene)
        self.assertIn('"JarBoxPerfProfile"',scene)
        self.assertIn(r"perf=\(perf)",scene)
        for name in ("GameViewController.swift","AppsListViewController.swift"):
            self.assertIn("JarBoxBackgroundDiagnostics.showFlight(from: self)",(ROOT/"J2MEEmulator/UI"/name).read_text())
if __name__=="__main__":unittest.main()
