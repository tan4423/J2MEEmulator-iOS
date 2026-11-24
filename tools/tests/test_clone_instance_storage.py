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
        let treoKey = JarBoxGameStorage.treoPreferenceKey(for: jar)
        let otherJAR = (gameDir as NSString).appendingPathComponent("Other Game.jar")
        defer {
            defaults.removeObject(forKey: treoKey)
            defaults.removeObject(forKey: JarBoxGameStorage.treoPreferenceKey(for: otherJAR))
        }
        defaults.removeObject(forKey: treoKey)
        defaults.removeObject(forKey: JarBoxGameStorage.treoPreferenceKey(for: otherJAR))
        require(!JarBoxGameStorage.treoCompatibleOnly(for: jar), "default Treo is not auto")
        require(treoKey != JarBoxGameStorage.treoPreferenceKey(for: otherJAR),
                "different games share Treo config")
        JarBoxGameStorage.setTreoCompatibleOnly(true, for: jar)
        require(JarBoxGameStorage.treoCompatibleOnly(for: jar) &&
                !JarBoxGameStorage.treoCompatibleOnly(for: otherJAR),
                "game Treo preference leaked")
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
            try JarBoxGameStorage.clearInstanceData(jarPath: jar, documents: docs, cloneID: b.id)
            fatalError("reset while JVM alive")
        } catch { }
        require(fm.fileExists(atPath: recordB), "live reset mutated save")
        nativeSessionCount = 0
        try JarBoxGameStorage.clearInstanceData(jarPath: jar, documents: docs, cloneID: b.id)
        require((try fm.contentsOfDirectory(atPath: rootB)).isEmpty, "reset did not empty clone root")
        require(try JarBoxGameStorage.registeredClones(jarPath: jar, documents: docs).contains { $0.id == b.id },
                "reset removed clone registry")
        require(fm.fileExists(atPath: recordA) && fm.fileExists(atPath: original), "reset touched sibling")
        require(defaults.object(forKey: "fpsLimit_" + keyB) as? Int == 15, "reset erased preferences")
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
        require(JarBoxGameStorage.treoCompatibleOnly(for: jar),
                "clone deletion removed shared game Treo policy")
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

        // Two installed JARs can have the same sanitized legacy save name.
        // Never guess which one owns the old account data.
        let collidingA = (gameDir as NSString).appendingPathComponent("Shared name.jar")
        let collidingB = (gameDir as NSString).appendingPathComponent("Shared@name.jar")
        try Data([0x50, 0x4b]).write(to: URL(fileURLWithPath: collidingA))
        try Data([0x50, 0x4b]).write(to: URL(fileURLWithPath: collidingB))
        let collision = (docs as NSString).appendingPathComponent("Games Data/Shared_name")
        try fm.createDirectory(atPath: collision, withIntermediateDirectories: true)
        let collisionSave = (collision as NSString).appendingPathComponent("account.rsr")
        try Data("UNTOUCHED_LEGACY_SAVE".utf8).write(to: URL(fileURLWithPath: collisionSave))
        do {
            _ = try JarBoxGameStorage.prepareRoot(jarPath: collidingA, documents: docs)
            fatalError("ambiguous legacy migration was allowed")
        } catch let error as NSError {
            require(error.domain == "JarBox.GameStorage" && error.code == 2,
                    "unexpected ambiguous migration error")
        }
        require(String(data: try Data(contentsOf: URL(fileURLWithPath: collisionSave)),
                       encoding: .utf8) == "UNTOUCHED_LEGACY_SAVE",
                "ambiguous migration touched legacy RMS")
        require(!fm.fileExists(atPath: JarBoxGameStorage.rootPath(
            jarPath: collidingA, documents: docs)),
                "created new root after migration was rejected")

        // A unique owner may still migrate legacy RMS by an atomic rename.
        let only = (gameDir as NSString).appendingPathComponent("Only Owner.jar")
        try Data([0x50, 0x4b]).write(to: URL(fileURLWithPath: only))
        let oldRoot = (docs as NSString).appendingPathComponent("Games Data/Only_Owner")
        try fm.createDirectory(atPath: oldRoot, withIntermediateDirectories: true)
        let oldSave = (oldRoot as NSString).appendingPathComponent("account.rsr")
        try Data("PRESERVED".utf8).write(to: URL(fileURLWithPath: oldSave))
        let moved = try JarBoxGameStorage.prepareRoot(jarPath: only, documents: docs)
        require(!fm.fileExists(atPath: oldRoot), "unique legacy root not moved")
        require(String(data: try Data(contentsOf: URL(fileURLWithPath:
                    (moved as NSString).appendingPathComponent("account.rsr"))),
                       encoding: .utf8) == "PRESERVED",
                "unique legacy account changed during migration")

        // Existing symbolic links must never become save roots.
        let linkedJAR = (gameDir as NSString).appendingPathComponent("Linked.jar")
        try Data([0x50, 0x4b]).write(to: URL(fileURLWithPath: linkedJAR))
        let linkedRoot = JarBoxGameStorage.rootPath(jarPath: linkedJAR, documents: docs)
        try fm.createSymbolicLink(atPath: linkedRoot, withDestinationPath: moved)
        do {
            _ = try JarBoxGameStorage.prepareRoot(jarPath: linkedJAR, documents: docs)
            fatalError("symbolic link save root accepted")
        } catch let error as NSError {
            require(error.domain == "JarBox.GameStorage" && error.code == 1,
                    "unexpected symlink validation error")
        }
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
            compile_result = subprocess.run(
                [swiftc, "-swift-version", "5", "-parse-as-library",
                 str(src), "-o", str(exe)],
                capture_output=True, text=True, timeout=70)
            self.assertEqual(
                compile_result.returncode, 0,
                "Swift storage harness compilation failed.\n"
                + compile_result.stdout + compile_result.stderr)
            run_result = subprocess.run(
                [str(exe)], capture_output=True, text=True, timeout=30)
            self.assertEqual(
                run_result.returncode, 0,
                "Swift storage harness runtime failed.\n"
                + run_result.stdout + run_result.stderr)

    def test_storage_helpers_are_in_compilable_extracted_enum(self):
        source = SWIFT.read_text(encoding="utf-8")
        begin = source.index("enum JarBoxGameStorage {")
        end = source.index("\n}\n\n// The parked library", begin) + 2
        storage = source[begin:end]
        self.assertIn("func legacyOwners(jarPath: String,", storage)
        self.assertIn("func isSymbolicLink(_ path: String)", storage)
        self.assertIn("values?.isSymbolicLink ?? true", storage)
        self.assertIn('name.lowercased().hasSuffix(".jar")', storage)

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
        self.assertIn("func gameTabItems(for game: GameViewController)", source)
        self.assertIn("func openGameTabAfterPark(", source)
        self.assertIn("cloneCount:", source)
        self.assertIn("cloneID: cloneID)", source)
        self.assertIn('showTabInformationPicker(for: app, clones: clones)', source)
        self.assertIn('showTabSettingsPicker(for: app, clones: clones)', source)
        self.assertIn('Self.setResolution(w: option.w, h: option.h, for: app, cloneID: cloneID)', source)
        self.assertIn('Self.setFpsLimit(option.value, for: app, cloneID: cloneID)', source)
        self.assertIn('Self.set3DSupersampling(!enhanced3D, for: app, cloneID: cloneID)', source)
        self.assertIn('gameForTab(app.path, cloneID: tab.id) != nil', source)
        self.assertIn('return UIMenu(children: [stop, infoAction, advanced, rename,', source)
        self.assertIn('blockedClonedJAR = true', source)
        self.assertIn('try fm.replaceItemAt(destURL, withItemAt: pending)', source)
        self.assertIn("rms-events.log", source)
        self.assertIn("settings-events.log", source)
        self.assertIn("Hãy xóa các Tab nhân bản bằng − Tab", source)


if __name__ == "__main__":
    unittest.main()
