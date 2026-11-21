"""Compile JarBoxGameStorage's *actual Swift code* and test clone storage.

The test extracts only the Foundation/CryptoKit storage enum (not UIKit).
On macOS Codemagic, swiftc exercises the same functions used by JarBox.
On hosts without CryptoKit it skips rather than pretending to test Swift.
"""
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFT = ROOT / "J2MEEmulator/UI/AppsListViewController.swift"
GAME = ROOT / "J2MEEmulator/UI/GameViewController.swift"

HARNESS = r'''
import Foundation
import CryptoKit

var nativeSessionCount: Int32 = 0
func jvm_bridge_active_session_count() -> Int32 { nativeSessionCount }

'''

MAIN = r'''
@main
struct CloneHarness {
    static func require(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }

    static func main() throws {
        let fm = FileManager.default
        let docs = fm.temporaryDirectory.appendingPathComponent(
            "jarbox-clone-test-" + UUID().uuidString).path
        defer { try? fm.removeItem(atPath: docs) }
        let gameDir = (docs as NSString).appendingPathComponent("games")
        try fm.createDirectory(atPath: gameDir, withIntermediateDirectories: true)
        let jar = (gameDir as NSString).appendingPathComponent("Avatar.jar")
        try Data([0x50, 0x4b]).write(to: URL(fileURLWithPath: jar))
        let base = try JarBoxGameStorage.prepareRoot(jarPath: jar, documents: docs)
        let rms = (base as NSString).appendingPathComponent("rms")
        try fm.createDirectory(atPath: rms, withIntermediateDirectories: true)
        let original = (rms as NSString).appendingPathComponent("account.rsr")
        try Data("ORIGINAL_ACCOUNT_SAVE".utf8).write(to: URL(fileURLWithPath: original))
        let defaults = UserDefaults.standard
        let baseKey = JarBoxGameStorage.settingsId(jarPath: jar)
        defaults.set(60, forKey: "fpsLimit_" + baseKey)
        defaults.set(999, forKey: "resW_" + baseKey)

        let a = try JarBoxGameStorage.createDefaultClone(
            jarPath: jar, documents: docs, label: "Tab 1")
        let b = try JarBoxGameStorage.createDefaultClone(
            jarPath: jar, documents: docs, label: "Tab 2")
        require(a.id != b.id, "UUID reuse")
        let rootA = try JarBoxGameStorage.prepareRoot(
            jarPath: jar, documents: docs, cloneID: a.id)
        let rootB = try JarBoxGameStorage.prepareRoot(
            jarPath: jar, documents: docs, cloneID: b.id)
        require(base != rootA && base != rootB && rootA != rootB,
                "data roots collided")
        require((try fm.contentsOfDirectory(atPath: rootA)).isEmpty,
                "Tab 1 copied original save or log")
        require((try fm.contentsOfDirectory(atPath: rootB)).isEmpty,
                "Tab 2 copied original save or log")
        let keyA = JarBoxGameStorage.settingsId(jarPath: jar, cloneID: a.id)
        let keyB = JarBoxGameStorage.settingsId(jarPath: jar, cloneID: b.id)
        require(keyA != keyB && keyA != baseKey, "settings key collision")
        require(defaults.object(forKey: "fpsLimit_" + keyA) == nil,
                "Tab 1 inherited FPS setting")
        require(defaults.object(forKey: "resW_" + keyB) == nil,
                "Tab 2 inherited resolution")
        defaults.set(20, forKey: "fpsLimit_" + keyA)
        defaults.set(15, forKey: "fpsLimit_" + keyB)
        let recordA = (rootA as NSString).appendingPathComponent("account.rsr")
        let recordB = (rootB as NSString).appendingPathComponent("account.rsr")
        try Data("ACCOUNT_A".utf8).write(to: URL(fileURLWithPath: recordA))
        try Data("ACCOUNT_B".utf8).write(to: URL(fileURLWithPath: recordB))

        nativeSessionCount = 1
        do {
            try JarBoxGameStorage.removeClone(
                jarPath: jar, documents: docs, cloneID: a.id)
            fatalError("deleted a tab while JVM was alive")
        } catch { }
        require(fm.fileExists(atPath: recordA), "live-tab deletion mutated save")
        nativeSessionCount = 0
        try JarBoxGameStorage.removeClone(jarPath: jar, documents: docs,
                                           cloneID: a.id)
        require(!fm.fileExists(atPath: rootA), "deleted tab still on disk")
        require(defaults.object(forKey: "fpsLimit_" + keyA) == nil,
                "deleted tab's settings not cleared")
        require(defaults.object(forKey: "fpsLimit_" + keyB) as? Int == 15,
                "sibling settings changed")
        require(String(data: try Data(contentsOf: URL(fileURLWithPath: recordB)),
                       encoding: .utf8) == "ACCOUNT_B", "sibling save changed")
        require(String(data: try Data(contentsOf: URL(fileURLWithPath: original)),
                       encoding: .utf8) == "ORIGINAL_ACCOUNT_SAVE",
                "original account save changed")
        require(defaults.object(forKey: "fpsLimit_" + baseKey) as? Int == 60,
                "original settings changed")
        let remaining = try JarBoxGameStorage.registeredClones(
            jarPath: jar, documents: docs)
        require(remaining.count == 1 && remaining[0].id == b.id,
                "group registry lost sibling")
        do {
            _ = try JarBoxGameStorage.prepareRoot(
                jarPath: jar, documents: docs, cloneID: a.id)
            fatalError("deleted clone could launch again")
        } catch { }
        try JarBoxGameStorage.removeClone(jarPath: jar, documents: docs,
                                           cloneID: b.id)
        require(try JarBoxGameStorage.registeredClones(
            jarPath: jar, documents: docs).isEmpty, "group not emptied")
        require(fm.fileExists(atPath: original), "base deleted with final tab")
        require(fm.fileExists(atPath: jar), "shared source JAR deleted")
    }
}
'''


class CloneInstanceStorageTest(unittest.TestCase):
    def test_compiled_swift_clone_defaults_and_deletion(self):
        swiftc = shutil.which("swiftc")
        if not swiftc:
            self.skipTest("swiftc unavailable")
        crypto = subprocess.run(
            [swiftc, "-typecheck", "-"],
            input="import CryptoKit\n", capture_output=True,
            text=True, timeout=15)
        if crypto.returncode != 0:
            self.skipTest("Host Swift toolchain does not include CryptoKit")
        source = SWIFT.read_text(encoding="utf-8")
        begin = source.index("enum JarBoxGameStorage {")
        end = source.index("\n}\n\n// The parked library", begin) + 2
        storage = source[begin:end]
        self.assertIn("createDefaultClone(", storage)
        self.assertIn("removeClone(", storage)
        self.assertNotIn("copyItem(atPath: source", storage)
        with tempfile.TemporaryDirectory(prefix="jarbox-clone-swift-") as temp:
            src = Path(temp) / "CloneHarness.swift"
            exe = Path(temp) / "CloneHarness"
            src.write_text(HARNESS + storage + "\n" + MAIN)
            subprocess.run(
                [swiftc, "-swift-version", "5", "-parse-as-library",
                 str(src), "-o", str(exe)],
                check=True, capture_output=True, text=True, timeout=70)
            subprocess.run([str(exe)], check=True,
                           capture_output=True, text=True, timeout=30)

    def test_launch_carries_instance_uuid_to_save_root(self):
        source = GAME.read_text(encoding="utf-8")
        self.assertIn("let cloneID: UUID?", source)
        self.assertIn("self.cloneID = cloneID", source)
        self.assertIn("let instanceCloneID = cloneID", source)
        self.assertIn("cloneID: instanceCloneID", source)
        self.assertIn("documents: docs, cloneID: cloneID)", source)
        self.assertIn("ownsLiveInstance(for path: String", source)

    def test_group_ui_uses_plus_and_minus_as_destructive(self):
        source = SWIFT.read_text(encoding="utf-8")
        self.assertIn('title: "+ Tab"', source)
        self.assertIn('title: "− Tab"', source)
        self.assertIn("createDefaultClone(", source)
        self.assertIn("removeClone(", source)
        self.assertIn("showTabChooser(for: app, clones: clones)", source)
        self.assertIn("cloneCount:", source)
        self.assertIn("cloneID: cloneID)", source)
        self.assertIn('showTabInformationPicker(for: app, clones: clones)', source)
        self.assertIn("rms-events.log", source)
        self.assertIn("settings-events.log", source)
        self.assertIn("Hãy xóa các Tab nhân bản bằng − Tab", source)


if __name__ == "__main__":
    unittest.main()
