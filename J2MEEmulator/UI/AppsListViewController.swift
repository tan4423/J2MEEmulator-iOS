//
//  AppsListViewController.swift
//  J2MEEmulator
//
//  Springboard-style home screen with app grid.
//

import UIKit
import UniformTypeIdentifiers
import Darwin
import CryptoKit

// Stable, collision-resistant per-install data paths shared by the game
// runner, library settings and RMS diagnostics. A copied JAR with a distinct
// filename gets distinct data; changing only its display alias does not.
enum JarBoxGameStorage {
    // Default callers require an idle registry. The main-actor coordinator
    // can explicitly account for unrelated live owners before a mutation.
    nonisolated static func requireMutationSafety(unrelatedTokens: [UInt64] = []) throws {
        // Admissions occur on the main actor. Reject a changing registry:
        // a retiring known token must not mask an unknown surviving owner.
        let before = Int(jvm_bridge_active_session_count())
        let active = Set(unrelatedTokens).filter {
            $0 != 0 && jvm_bridge_session_is_active_for_token($0) != 0
        }
        let after = Int(jvm_bridge_active_session_count())
        guard (unrelatedTokens.isEmpty || Thread.isMainThread),
              before == after, after == active.count else {
            throw NSError(domain: "JarBox.GameStorage", code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Chưa xác nhận các phiên cần xóa đã dừng hẳn."])
        }
    }

    // Includes the original; independent of the number of live JVM slots.
    // Preserve the previous limit of 16 clones + one original.
    nonisolated static let maxTotalTabs = 30

    nonisolated static func allowedAddCount(cloneCount: Int) -> Int {
        max(0, maxTotalTabs - 1 - cloneCount)
    }

    nonisolated static func validTabQuantity(_ count: Int, maximum: Int) -> Bool {
        count >= 1 && count <= maximum
    }

    nonisolated static func tabQuantityError(maximum: Int) -> NSError {
        NSError(domain: "JarBox.GameStorage", code: 12,
            userInfo: [NSLocalizedDescriptionKey: maximum > 0
                ? "Số lượng phải từ 1 đến " + String(maximum) + "."
                : "Không còn tab có thể thêm hoặc xóa."])
    }

    nonisolated static func exactFileName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // Treo configuration belongs to the installed JAR group. A clone UUID
    // is intentionally NOT part of this key. Clone save/FPS keys remain
    // independent; deleting a clone must not delete the group's policy.
    nonisolated static func treoPreferenceKey(for jarPath: String) -> String {
        "treoCompatibleOnly_" + installId(for: jarPath)
    }

    nonisolated static func treoCompatibleOnly(for jarPath: String) -> Bool {
        UserDefaults.standard.bool(forKey: treoPreferenceKey(for: jarPath))
    }

    nonisolated static func setTreoCompatibleOnly(_ enabled: Bool, for jarPath: String) {
        UserDefaults.standard.set(enabled, forKey: treoPreferenceKey(for: jarPath))
    }

    nonisolated static func installId(for path: String) -> String {
        let name = exactFileName(for: path)
        let digest = SHA256.hash(data: Data(name.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func legacyId(for path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_",
                                  options: .regularExpression)
    }

    // Reject symlink save directories before any migration or destructive
    // operation. If metadata cannot be read, fail closed (treat as unsafe).
    nonisolated private static func isSymbolicLink(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink ?? true
    }

    // Legacy saves were keyed by a sanitized JAR basename. Different JARs
    // can collapse to the same name (e.g. "A B.jar" and "A@B.jar").
    // Never migrate or inherit a legacy RMS directory unless precisely one
    // installed source JAR is a possible owner.
    nonisolated private static func legacyOwners(jarPath: String,
                                                 documents: String) -> [String] {
        let games = (documents as NSString).appendingPathComponent("games")
        guard let names = try? FileManager.default.contentsOfDirectory(
            atPath: games) else { return [] }
        let legacyName = legacyId(for: jarPath)
        return names.filter { name in
            name.lowercased().hasSuffix(".jar") &&
                legacyId(for: (games as NSString).appendingPathComponent(name)) == legacyName
        }.sorted()
    }

    /// The original keeps its current save directory for backward compatibility.
    /// Every clone gets a sibling directory, never a child of the original:
    /// deleting the original must never delete another instance's RMS.
    nonisolated static func rootPath(jarPath: String, documents: String,
                                     cloneID: UUID? = nil) -> String {
        let group = installId(for: jarPath)
        let suffix = cloneID.map { "-clone-" + $0.uuidString.lowercased() } ?? ""
        return (documents as NSString).appendingPathComponent("Games Data/inst-" + group + suffix)
    }

    // Resolution is a group preference. Keep the original installation's
    // existing keys so upgrades preserve its chosen dimensions.
    nonisolated static func sharedResolution(jarPath: String) -> (w: Int, h: Int) {
        let gid = installId(for: jarPath)
        let w = UserDefaults.standard.object(forKey: "resW_" + gid) as? Int ?? 240
        let h = UserDefaults.standard.object(forKey: "resH_" + gid) as? Int ?? 320
        return (w, h)
    }

    nonisolated static func setSharedResolution(w: Int, h: Int, jarPath: String) {
        let gid = installId(for: jarPath)
        UserDefaults.standard.set(w, forKey: "resW_" + gid)
        UserDefaults.standard.set(h, forKey: "resH_" + gid)
    }

    nonisolated static func sharedFPS(jarPath: String) -> Int {
        UserDefaults.standard.integer(forKey: "fpsLimit_" + installId(for: jarPath))
    }

    nonisolated static func setSharedFPS(_ fps: Int, jarPath: String) {
        UserDefaults.standard.set(fps, forKey: "fpsLimit_" + installId(for: jarPath))
    }

    nonisolated static func shared3D(jarPath: String) -> Bool {
        UserDefaults.standard.bool(forKey: "ss3d_" + installId(for: jarPath))
    }

    nonisolated static func setShared3D(_ enabled: Bool, jarPath: String) {
        UserDefaults.standard.set(enabled, forKey: "ss3d_" + installId(for: jarPath))
    }

    nonisolated static func settingsId(jarPath: String, cloneID: UUID? = nil) -> String {
        let group = installId(for: jarPath)
        return cloneID.map { group + "_clone_" + $0.uuidString.lowercased() } ?? group
    }

    // Remember the last exited tab per installed JAR, independent of the
    // global last-live-token shortcut. UUIDs survive app relaunch.
    nonisolated static func rememberLastTab(jarPath: String, cloneID: UUID?) {
        let key = "lastTab_" + installId(for: jarPath)
        if let cloneID {
            UserDefaults.standard.set(cloneID.uuidString, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    nonisolated static func lastTab(jarPath: String, registered: [UUID]) -> UUID? {
        let key = "lastTab_" + installId(for: jarPath)
        guard let value = UserDefaults.standard.string(forKey: key),
              let id = UUID(uuidString: value), registered.contains(id) else { return nil }
        return id
    }

    // The original tab is nil; use an optional INDEX to distinguish it
    // from the absence of a candidate. Never wrap more than once.
    nonisolated static func nextRunningTabIndex(ordered: [UUID?], closing: UUID?,
                                                running: Set<UUID?>) -> Int? {
        guard let origin = ordered.firstIndex(of: closing), ordered.count > 1 else { return nil }
        for offset in 1..<ordered.count {
            let index = (origin + offset) % ordered.count
            if running.contains(ordered[index]) { return index }
        }
        return nil
    }

    // Prefer the nearest running tab on the left, then any running tab
    // on the right. Only launch a stopped neighbor if no running tab remains.
    nonisolated static func deletionNeighborIndex(ordered: [UUID?], deleting: UUID?,
                                                 running: Set<UUID?>) -> Int? {
        guard let origin = ordered.firstIndex(of: deleting), ordered.count > 1 else { return nil }
        let left = ordered.indices.prefix(origin).reversed()
        let right = ordered.indices.dropFirst(origin + 1)
        return left.first { running.contains(ordered[$0]) } ??
            right.first { running.contains(ordered[$0]) } ?? left.first ?? right.first
    }

    nonisolated static func entryTabIndex(ordered: [UUID?], remembered: UUID?,
                                          running: Set<UUID?>) -> Int? {
        guard !ordered.isEmpty else { return nil }
        if running.contains(remembered), let index = ordered.firstIndex(of: remembered) {
            return index
        }
        return ordered.firstIndex { running.contains($0) } ?? 0
    }

    struct CloneRecord: Codable, Equatable {
        let id: UUID
        let label: String
        let createdAt: Date
    }

    private struct CloneGroup: Codable {
        let sourceJARFileName: String
        var clones: [CloneRecord]
    }

    // Save registry mutations run from both the main UI and a JVM worker.
    nonisolated private static let cloneRegistryLock = NSLock()

    nonisolated private static func cloneRegistryPath(jarPath: String,
                                                       documents: String) -> String {
        (documents as NSString).appendingPathComponent(
            "Game Instances/" + installId(for: jarPath) + ".json")
    }

    /// Read-only group metadata. Malformed JSON fails loudly instead of
    /// pretending clones do not exist. No action touches save payloads.
    nonisolated static func registeredClones(jarPath: String,
                                             documents: String) throws -> [CloneRecord] {
        cloneRegistryLock.lock()
        defer { cloneRegistryLock.unlock() }
        return try readCloneGroup(jarPath: jarPath, documents: documents).clones
    }

    nonisolated private static func readCloneGroup(jarPath: String,
                                                    documents: String) throws -> CloneGroup {
        let path = cloneRegistryPath(jarPath: jarPath, documents: documents)
        let name = exactFileName(for: jarPath)
        guard FileManager.default.fileExists(atPath: path) else {
            return CloneGroup(sourceJARFileName: name, clones: [])
        }
        let group = try JSONDecoder().decode(CloneGroup.self,
                                      from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard group.sourceJARFileName == name else {
            throw NSError(domain: "JarBox.GameStorage", code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Nhóm bản nhân không khớp JAR gốc."])
        }
        return group
    }

    /// Create a factory-default instance: the same immutable JAR bytes, but
    /// no original RMS, session logs, display alias or preference values.
    /// Never copy from the running original. No JVM is started here.
    nonisolated static func createDefaultClone(jarPath: String, documents: String,
                                                label: String) throws -> CloneRecord {
        let records = try createClones(jarPath: jarPath, documents: documents,
                                       count: 1, explicitLabel: label)
        return records[0]
    }

    nonisolated static func createCloneAfter(jarPath: String, documents: String,
                                             after: UUID?) throws -> CloneRecord {
        try createClones(jarPath: jarPath, documents: documents, count: 1,
                         explicitLabel: nil, insertionAfter: [after])[0]
    }

    nonisolated static func createDefaultClones(jarPath: String, documents: String,
                                                 count: Int) throws -> [CloneRecord] {
        try createClones(jarPath: jarPath, documents: documents,
                         count: count, explicitLabel: nil)
    }

    nonisolated private static func createClones(jarPath: String, documents: String,
                                                   count: Int, explicitLabel: String?,
                                                   insertionAfter: [UUID?] = []) throws -> [CloneRecord] {
        cloneRegistryLock.lock()
        defer { cloneRegistryLock.unlock() }
        guard FileManager.default.fileExists(atPath: jarPath) else {
            throw NSError(domain: "JarBox.GameStorage", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy file JAR nguồn."])
        }
        var group = try readCloneGroup(jarPath: jarPath, documents: documents)
        let maximum = allowedAddCount(cloneCount: group.clones.count)
        guard validTabQuantity(count, maximum: maximum) else {
            throw tabQuantityError(maximum: maximum)
        }
        // [] means append; [nil] means directly after the original.
        let insertion: Int
        if insertionAfter.isEmpty {
            insertion = group.clones.count
        } else if let after = insertionAfter[0] {
            guard let index = group.clones.firstIndex(where: { $0.id == after }) else {
                throw NSError(domain: "JarBox.GameStorage", code: 14,
                    userInfo: [NSLocalizedDescriptionKey: "Tab nguồn không còn tồn tại."])
            }
            insertion = index + 1
        } else {
            insertion = 0
        }
        var used = Set(group.clones.map { $0.label })
        var records: [CloneRecord] = []
        var next = 1
        for _ in 0..<count {
            let title: String
            if let explicitLabel {
                title = explicitLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                while used.contains("Tab " + String(next)) { next += 1 }
                title = "Tab " + String(next)
            }
            guard !title.isEmpty && title.count <= 80 else {
                throw NSError(domain: "JarBox.GameStorage", code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Tên tab mới không hợp lệ."])
            }
            used.insert(title)
            records.append(CloneRecord(id: UUID(), label: title, createdAt: Date()))
        }
        let fm = FileManager.default
        let base = (documents as NSString).appendingPathComponent("Games Data")
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        var created: [String] = []
        do {
            for record in records {
                let target = rootPath(jarPath: jarPath, documents: documents, cloneID: record.id)
                guard !fm.fileExists(atPath: target) else {
                    throw NSError(domain: "JarBox.GameStorage", code: 8,
                        userInfo: [NSLocalizedDescriptionKey: "Thư mục tab mới đã tồn tại."])
                }
                try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
                created.append(target)
            }
            group.clones.insert(contentsOf: records, at: insertion)
            try writeCloneGroup(group, jarPath: jarPath, documents: documents)
        } catch {
            for target in created { try? fm.removeItem(atPath: target) }
            throw error
        }
        return records
    }

    nonisolated private static func writeCloneGroup(_ group: CloneGroup,
                                                      jarPath: String,
                                                      documents: String) throws {
        let path = cloneRegistryPath(jarPath: jarPath, documents: documents)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try JSONEncoder().encode(group).write(
            to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Deletes exactly one independent clone's save and preferences.
    /// The original JAR and all sibling roots are untouched. Until the
    /// native coordinator supports per-instance teardown, require idle JVMs.
    nonisolated static func removeClone(jarPath: String, documents: String,
                                        cloneID: UUID) throws {
        try removeClones(jarPath: jarPath, documents: documents, cloneIDs: [cloneID])
    }

    // Validate the complete selection and stage all roots before publishing
    // a single registry update. Never remove the original (no UUID).
    nonisolated static func removeClones(jarPath: String, documents: String,
                                         cloneIDs: [UUID], unrelatedTokens: [UInt64] = []) throws {
        cloneRegistryLock.lock()
        defer { cloneRegistryLock.unlock() }
        try requireMutationSafety(unrelatedTokens: unrelatedTokens)
        var group = try readCloneGroup(jarPath: jarPath, documents: documents)
        guard validTabQuantity(cloneIDs.count, maximum: group.clones.count) else {
            throw tabQuantityError(maximum: group.clones.count)
        }
        let ids = Set(cloneIDs)
        guard ids.count == cloneIDs.count,
              ids.isSubset(of: Set(group.clones.map { $0.id })) else {
            throw NSError(domain: "JarBox.GameStorage", code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Danh sách tab cần xóa đã thay đổi hoặc không hợp lệ."])
        }
        let fm = FileManager.default
        var targets: [(root: String, tomb: String)] = []
        for id in cloneIDs {
            let target = rootPath(jarPath: jarPath, documents: documents, cloneID: id)
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: target, isDirectory: &directory),
                  directory.boolValue, !isSymbolicLink(target) else {
                throw NSError(domain: "JarBox.GameStorage", code: 15,
                    userInfo: [NSLocalizedDescriptionKey: "Thư mục tab không an toàn hoặc đã mất."])
            }
            targets.append((target, target + ".deleting-" + UUID().uuidString))
        }
        var staged: [(root: String, tomb: String)] = []
        do {
            for target in targets {
                try fm.moveItem(atPath: target.root, toPath: target.tomb)
                staged.append(target)
            }
            group.clones.removeAll { ids.contains($0.id) }
            try writeCloneGroup(group, jarPath: jarPath, documents: documents)
        } catch {
            for item in staged.reversed() { try? fm.moveItem(atPath: item.tomb, toPath: item.root) }
            throw error
        }
        // The registry is committed. Never restore a partially erased root.
        // If disk cleanup fails, report it explicitly rather than resurrect
        // a tab whose files might already have been deleted.
        var cleanupFailed = false
        for target in staged {
            do { try fm.removeItem(atPath: target.tomb) }
            catch { cleanupFailed = true; NSLog("[JarBoxStorage] clone cleanup failed: %@", error.localizedDescription) }
        }
        let defaults = UserDefaults.standard
        for id in cloneIDs {
            let instance = settingsId(jarPath: jarPath, cloneID: id)
            for prefix in ["displayName_", "ss3d_", "resW_", "resH_", "fpsLimit_"] {
                defaults.removeObject(forKey: prefix + instance)
            }
        }
        if cleanupFailed {
            throw NSError(domain: "JarBox.GameStorage", code: 18,
                userInfo: [NSLocalizedDescriptionKey: "Đã bỏ các tab khỏi danh sách nhưng chưa dọn hết dữ liệu trên đĩa."])
        }
    }

    /// Never combine two colliding legacy saves or launch against the wrong
    /// legacy directory. A same-filesystem move preserves RMS bytes intact.
    /// Failure leaves the original untouched and stops launch, not a blank save.
    nonisolated static func prepareRoot(jarPath: String, documents: String,
                                        cloneID: UUID? = nil) throws -> String {
        // Clone startup must never migrate or fall back to the original RMS.
        if let cloneID {
            let clones = try registeredClones(jarPath: jarPath, documents: documents)
            guard clones.contains(where: { $0.id == cloneID }) else {
                throw NSError(domain: "JarBox.GameStorage", code: 9,
                    userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy bản nhân đã đăng ký."])
            }
            let privateRoot = rootPath(jarPath: jarPath, documents: documents, cloneID: cloneID)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: privateRoot, isDirectory: &isDirectory),
                  isDirectory.boolValue, !isSymbolicLink(privateRoot) else {
                throw NSError(domain: "JarBox.GameStorage", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "Save của bản nhân bị thiếu hoặc không an toàn."])
            }
            return privateRoot
        }
        let fm = FileManager.default
        let root = rootPath(jarPath: jarPath, documents: documents)
        if fm.fileExists(atPath: root) {
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &directory),
                  directory.boolValue, !isSymbolicLink(root) else {
                throw NSError(domain: "JarBox.GameStorage", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Thư mục save không an toàn."])
            }
            return root
        }
        let base = (documents as NSString).appendingPathComponent("Games Data")
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        let legacyName = legacyId(for: jarPath)
        // Avoid accessing Games Data or its parent for unusual dot-only names.
        if legacyName != "." && legacyName != ".." && !legacyName.isEmpty {
            let legacy = (base as NSString).appendingPathComponent(legacyName)
            if fm.fileExists(atPath: legacy) {
                let owners = legacyOwners(jarPath: jarPath, documents: documents)
                guard owners.count == 1,
                      owners[0] == exactFileName(for: jarPath),
                      !isSymbolicLink(legacy) else {
                    throw NSError(domain: "JarBox.GameStorage", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey:
                                    "Save cũ có thể thuộc nhiều JAR. Không tự di chuyển để tránh ghi đè."])
                }
                // Atomic rename on the same Documents volume: no partial copy,
                // no loss of legacy RMS state if the operation fails.
                try fm.moveItem(atPath: legacy, toPath: root)
                return root
            }
        }
        try fm.createDirectory(atPath: root, withIntermediateDirectories: false)
        return root
    }

    /// Reset only the selected instance's files, not its UUID, preferences
    /// or shared JAR. Keep an empty registered clone root for next startup.
    nonisolated static func clearInstanceData(jarPath: String, documents: String,
                                                cloneID: UUID?, unrelatedTokens: [UInt64] = []) throws {
        try requireMutationSafety(unrelatedTokens: unrelatedTokens)
        let root = try prepareRoot(jarPath: jarPath, documents: documents, cloneID: cloneID)
        let fm = FileManager.default
        let tomb = root + ".reset-" + UUID().uuidString
        try fm.moveItem(atPath: root, toPath: tomb)
        do {
            try fm.createDirectory(atPath: root, withIntermediateDirectories: false)
        } catch {
            try? fm.moveItem(atPath: tomb, toPath: root)
            throw error
        }
        try fm.removeItem(atPath: tomb)
    }

    /// Retain user settings from before install-ID migration only when the
    /// legacy sanitized JAR name has one unambiguous owner on disk.
    nonisolated static func migratePreferencesIfUnique(for path: String, documents: String) {
        let old = legacyId(for: path)
        let new = installId(for: path)
        guard legacyOwners(jarPath: path, documents: documents) == [exactFileName(for: path)]
              else { return }
        let defaults = UserDefaults.standard
        let prefix = ["displayName_", "ss3d_", "resW_", "resH_", "fpsLimit_"]
        for key in prefix {
            if defaults.object(forKey: key + new) == nil,
               let value = defaults.object(forKey: key + old) {
                defaults.set(value, forKey: key + new)
            }
        }
    }

    // Metadata only: never save RMS bodies, passwords or arbitrary game text.
    // Records are bounded and appended only on lifecycle/settings actions.
    nonisolated static func appendSettingEvent(jarPath: String, documents: String,
                                   event: String, value: String = "",
                                   cloneID: UUID? = nil) {
        let safeEvent = event.filter { $0.isASCII && ($0.isLetter || $0 == "_") }
        guard !safeEvent.isEmpty else { return }
        do {
            let root = try prepareRoot(jarPath: jarPath, documents: documents,
                                       cloneID: cloneID)
            let logPath = (root as NSString).appendingPathComponent("settings-events.log")
            let fm = FileManager.default
            if !fm.fileExists(atPath: logPath) {
                _ = fm.createFile(atPath: logPath, contents: nil)
            }
            let attributes = try fm.attributesOfItem(atPath: logPath)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 < 128 * 1024
                else { return }
            let safeValue = value.filter { $0.isASCII && ($0.isNumber || $0 == "x" || $0 == "_") }
            let row = "\(Int64(Date().timeIntervalSince1970 * 1000))\tSETTINGS_\(safeEvent)\t\(safeValue)\n"
            guard let bytes = row.data(using: .utf8) else { return }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: logPath))
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            handle.write(bytes)
        } catch {
            // Optional diagnostics cannot alter user settings or game logic.
            NSLog("[JarBoxStorage] metadata audit unavailable: %@", error.localizedDescription)
        }
    }
}

// The parked library always uses portrait, even over an N-Gage game.
final class JarBoxLibraryNavigationController: UINavigationController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
}

// Stored independently from game/Treo settings. Manual is the safe default.
enum JarBoxProtectionPreferences {
    static var automatic: Bool { UserDefaults.standard.bool(forKey: "jarbox.protection.automatic") }
    static var seconds: Int {
        let value = UserDefaults.standard.integer(forKey: "jarbox.protection.seconds")
        return (5...3600).contains(value) ? value : 60
    }
}

final class JarBoxProtectionSettingsController: UIViewController {
    var onSaved: (() -> Void)?
    private let mode = UISegmentedControl(items: ["Tự động", "Ấn tay"])
    private let timeLabel = UILabel()
    private let seconds = UITextField()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Bảo vệ màn hình"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
            target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .save,
            target: self, action: #selector(save))
        mode.selectedSegmentIndex = JarBoxProtectionPreferences.automatic ? 0 : 1
        mode.addTarget(self, action: #selector(updateMode), for: .valueChanged)
        timeLabel.text = "Thời gian vào trạng thái (giây)"
        timeLabel.font = .preferredFont(forTextStyle: .body)
        timeLabel.numberOfLines = 0
        seconds.borderStyle = .roundedRect
        seconds.keyboardType = .numberPad
        seconds.text = String(JarBoxProtectionPreferences.seconds)
        seconds.accessibilityLabel = "Thời gian chờ, từ 5 đến 3600 giây"
        let stack = UIStackView(arrangedSubviews: [mode, timeLabel, seconds])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            seconds.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        updateMode()
    }

    @objc private func updateMode() {
        let enabled = mode.selectedSegmentIndex == 0
        seconds.isEnabled = enabled
        seconds.alpha = enabled ? 1 : 0.4
        timeLabel.alpha = enabled ? 1 : 0.4
        if !enabled { seconds.resignFirstResponder() }
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func save() {
        let automatic = mode.selectedSegmentIndex == 0
        if automatic {
            guard let value = Int(seconds.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""),
                  (5...3600).contains(value) else {
                let alert = UIAlertController(title: "Thời gian không hợp lệ",
                    message: "Nhập số nguyên từ 5 đến 3600 giây.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
                return
            }
            UserDefaults.standard.set(value, forKey: "jarbox.protection.seconds")
        }
        UserDefaults.standard.set(automatic, forKey: "jarbox.protection.automatic")
        let callback = onSaved
        dismiss(animated: true) { callback?() }
    }
}

// Shared native policy for every installed game, not a per-tab RAM quota.
enum JarBoxMemoryProtection {
    static func launchDenialMessage() -> String? {
        var bytes: UInt64 = 0
        guard jvm_bridge_memory_state(&bytes) != 0 else { return nil }
        return String(format: "RAM khả dụng: %.0f MB. Chưa đủ an toàn để mở thêm game. Hãy dừng bớt tab hoặc thử lại khi bộ nhớ phục hồi.",
                      Double(bytes) / 1_048_576)
    }

    static func statusText() -> String {
        var bytes: UInt64 = 0
        let state = jvm_bridge_memory_state(&bytes)
        if bytes == UInt64.max { return "RAM khả dụng: —" }
        let label = state == 2 ? "Nguy hiểm" : state == 1 ? "Cảnh báo" : "An toàn"
        return String(format: "RAM khả dụng: %.0f MB · %@", Double(bytes) / 1_048_576, label)
    }
}

// A status screen, not a background monitor. Sampling owns a timer only
// while the actual screen and scene are active.
// Shared profile metadata; selecting a profile does not alter live sockets.
struct JarBoxProxyProfile: Codable {
    let id: UUID
    var name: String
    var host: String
    var port: Int
    var kind: String
}

enum JarBoxProxyProfiles {
    private static let profilesKey = "jarbox.proxy.profiles.v1"
    private static let selectionKey = "jarbox.proxy.selections.v1"

    static func all() -> [JarBoxProxyProfile] {
        guard let data = UserDefaults.standard.data(forKey: profilesKey),
              let profiles = try? JSONDecoder().decode([JarBoxProxyProfile].self, from: data) else { return [] }
        return profiles
    }

    static func save(_ profiles: [JarBoxProxyProfile]) {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        UserDefaults.standard.set(data, forKey: profilesKey)
        let ids = Set(profiles.map { $0.id.uuidString })
        let selections = UserDefaults.standard.dictionary(forKey: selectionKey) as? [String: String] ?? [:]
        UserDefaults.standard.set(selections.filter { ids.contains($0.value) }, forKey: selectionKey)
    }

    static func tabKey(path: String, cloneID: UUID?) -> String {
        URL(fileURLWithPath: path).lastPathComponent + "|" + (cloneID?.uuidString ?? "original")
    }

    static func selection(for key: String) -> UUID? {
        let selections = UserDefaults.standard.dictionary(forKey: selectionKey) as? [String: String] ?? [:]
        guard let value = selections[key], let id = UUID(uuidString: value),
              all().contains(where: { $0.id == id }) else { return nil }
        return id
    }

    static func select(_ id: UUID?, for key: String) {
        if let id, !all().contains(where: { $0.id == id }) { return }
        var selections = UserDefaults.standard.dictionary(forKey: selectionKey) as? [String: String] ?? [:]
        selections[key] = id?.uuidString
        UserDefaults.standard.set(selections, forKey: selectionKey)
    }
}

final class JarBoxProxySettingsController: UITableViewController {
    private var profiles: [JarBoxProxyProfile] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Proxy"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Đóng", style: .done, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .add, target: self, action: #selector(addProfile))
        reloadProfiles()
    }

    private func reloadProfiles() {
        profiles = JarBoxProxyProfiles.all()
        tableView.reloadData()
    }

    @objc private func close() { dismiss(animated: true) }
    @objc private func addProfile() { editProfile(nil) }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { profiles.count }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Tạo profile rồi chọn trong menu game. Hiện chỉ lưu cấu hình, chưa chuyển lưu lượng qua proxy."
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let profile = profiles[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = profile.name
        cell.detailTextLabel?.text = "\(profile.kind) · \(profile.host):\(profile.port)"
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        editProfile(profiles[indexPath.row])
    }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        let id = profiles[indexPath.row].id
        JarBoxProxyProfiles.save(JarBoxProxyProfiles.all().filter { $0.id != id })
        reloadProfiles()
    }

    private func editProfile(_ previous: JarBoxProxyProfile?) {
        let alert = UIAlertController(title: previous == nil ? "Thêm profile" : "Sửa profile",
                                      message: "Loại: HTTP hoặc SOCKS5", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Tên"; $0.text = previous?.name }
        alert.addTextField { $0.placeholder = "Host"; $0.text = previous?.host; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addTextField { $0.placeholder = "Port"; $0.text = previous.map { String($0.port) }; $0.keyboardType = .numberPad }
        alert.addTextField { $0.placeholder = "HTTP / SOCKS5"; $0.text = previous?.kind ?? "SOCKS5"; $0.autocapitalizationType = .allCharacters }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Lưu", style: .default) { [weak self, weak alert] _ in
            guard let self, let fields = alert?.textFields, fields.count == 4 else { return }
            let values = fields.map { ($0.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let kind = values[3].uppercased()
            guard !values[0].isEmpty, !values[1].isEmpty,
                  values[1].rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                  let port = Int(values[2]), (1...65535).contains(port),
                  ["HTTP", "SOCKS5"].contains(kind) else {
                let error = UIAlertController(title: "Profile không hợp lệ", message: "Kiểm tra tên, host, port 1–65535 và loại proxy.", preferredStyle: .alert)
                error.addAction(UIAlertAction(title: "OK", style: .default))
                self.present(error, animated: true)
                return
            }
            let profile = JarBoxProxyProfile(id: previous?.id ?? UUID(), name: values[0], host: values[1], port: port, kind: kind)
            var updated = JarBoxProxyProfiles.all()
            if let index = updated.firstIndex(where: { $0.id == profile.id }) { updated[index] = profile }
            else { updated.append(profile) }
            JarBoxProxyProfiles.save(updated)
            self.reloadProfiles()
        })
        present(alert, animated: true)
    }
}

final class JarBoxStatusController: UIViewController {
    typealias TabRow = (game: String, path: String, tab: String, token: UInt64)
    var readRAM: (() -> String)?
    var readTabs: (() -> [TabRow])?
    private let cpuLabel = UILabel()
    private let ramLabel = UILabel()
    private let ramAvailableLabel = UILabel()
    private let thermalLabel = UILabel()
    private let batteryLabel = UILabel()
    private let cpuDetail = UILabel()
    private let ramDetail = UILabel()
    private let cpuButton = UIButton(type: .system)
    private let ramButton = UIButton(type: .system)
    private var timer: Timer?
    private var generation: UInt64 = 0
    private var visible = false
    private var previousBatteryMonitoring: Bool?
    private var baseline: (time: TimeInterval, cpu: Double)?
    private var cpuText = "CPU App: đang đo"

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Trạng thái"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Đóng", style: .done,
            target: self, action: #selector(close))
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        for label in [cpuLabel, ramLabel, ramAvailableLabel, thermalLabel, batteryLabel, cpuDetail, ramDetail] {
            label.textAlignment = .left
            label.numberOfLines = 0
            label.font = .monospacedDigitSystemFont(ofSize: 16, weight: .regular)
            label.textColor = .label
        }
        for label in [cpuDetail, ramDetail] {
            label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
            label.textColor = .secondaryLabel
            label.isHidden = true
        }
        for button in [cpuButton, ramButton] {
            button.contentHorizontalAlignment = .right
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        }
        cpuButton.setTitle("Chi tiết ▸", for: .normal)
        ramButton.setTitle("Chi tiết ▸", for: .normal)
        cpuButton.addTarget(self, action: #selector(toggleCPU), for: .touchUpInside)
        ramButton.addTarget(self, action: #selector(toggleRAM), for: .touchUpInside)
        cpuButton.accessibilityLabel = "Chi tiết CPU"
        ramButton.accessibilityLabel = "Chi tiết RAM (heap)"
        func metricRow(_ label: UILabel, _ button: UIButton) -> UIStackView {
            let row = UIStackView(arrangedSubviews: [label, button])
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 8
            return row
        }
        let cpuRow = metricRow(cpuLabel, cpuButton)
        let ramRow = metricRow(ramLabel, ramButton)
        for child in [cpuRow, cpuDetail, ramRow, ramDetail, ramAvailableLabel,
                      thermalLabel, batteryLabel] as [UIView] {
            stack.addArrangedSubview(child)
        }
        stack.setCustomSpacing(20, after: cpuDetail)
        stack.setCustomSpacing(20, after: ramDetail)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(startSampling),
                           name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(stopSampling),
                           name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(stopSampling),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneActivated(_:)),
                           name: UIScene.didActivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDeactivated(_:)),
                           name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(self, selector: #selector(sceneDeactivated(_:)),
                           name: UIScene.didDisconnectNotification, object: nil)
        startSampling()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        visible = false
        stopSampling()
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func sceneActivated(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === view.window?.windowScene else { return }
        startSampling()
    }

    @objc private func sceneDeactivated(_ note: Notification) {
        guard let scene = note.object as? UIScene, scene === view.window?.windowScene else { return }
        stopSampling()
    }

    @objc private func startSampling() {
        guard visible, timer == nil,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else { return }
        let device = UIDevice.current
        previousBatteryMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        baseline = nil
        cpuText = "CPU App: đang đo"
        refreshStatus()
        generation &+= 1
        let current = generation
        let next = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.timer != nil else { return }
                guard self.visible,
                      self.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else {
                    self.stopSampling()
                    return
                }
                self.refreshStatus()
            }
        }
        next.tolerance = 0.05
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    @objc private func stopSampling() {
        generation &+= 1
        timer?.invalidate()
        timer = nil
        baseline = nil
        if let previous = previousBatteryMonitoring {
            UIDevice.current.isBatteryMonitoringEnabled = previous
            previousBatteryMonitoring = nil
        }
    }

    @objc private func toggleCPU() {
        cpuDetail.isHidden.toggle()
        cpuButton.setTitle(cpuDetail.isHidden ? "Chi tiết ▸" : "Chi tiết ▾", for: .normal)
        if !cpuDetail.isHidden { refreshDetails() }
    }

    @objc private func toggleRAM() {
        ramDetail.isHidden.toggle()
        ramButton.setTitle(ramDetail.isHidden ? "Chi tiết ▸" : "Chi tiết ▾", for: .normal)
        if !ramDetail.isHidden { refreshDetails() }
    }

    private func refreshStatus() {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = treo_process_cpu_seconds()
        if cpu.isFinite, cpu >= 0, now.isFinite {
            if let before = baseline, cpu >= before.cpu, now >= before.time {
                let elapsed = now - before.time
                if elapsed >= 0.9 {
                    let rate = (cpu - before.cpu) / elapsed
                    cpuText = String(format: "CPU App: %.1f%% (%.0f ms/s)", 100 * rate, 1000 * rate)
                    baseline = (now, cpu)
                }
            } else {
                baseline = (now, cpu)
                cpuText = "CPU App: đang đo"
            }
        } else {
            baseline = nil
            cpuText = "CPU App: —"
        }
        cpuLabel.text = cpuText
        ramLabel.text = readRAM?() ?? "RAM App: —"
        ramAvailableLabel.text = JarBoxMemoryProtection.statusText()
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Bình thường"
        case .fair: thermal = "Tăng nhẹ"
        case .serious: thermal = "Cao"
        case .critical: thermal = "Rất cao"
        @unknown default: thermal = "Không xác định"
        }
        thermalLabel.text = "Nhiệt độ: " + thermal
        let battery = UIDevice.current.batteryLevel
        batteryLabel.text = battery >= 0 ? String(format: "Pin: %.0f%%", Double(battery) * 100) : "Pin: —"
        refreshDetails()
    }

    private func refreshDetails() {
        guard visible, viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
              !cpuDetail.isHidden || !ramDetail.isHidden else { return }
        let rows = readTabs?() ?? []
        if !cpuDetail.isHidden {
            cpuDetail.text = detailLines(rows) { _ in "Chưa đo riêng" }
        }
        if !ramDetail.isHidden {
            let total = ProcessInfo.processInfo.physicalMemory
            ramDetail.text = detailLines(rows) { row in
                var bytes: UInt64 = 0
                guard total > 0, jvm_bridge_status_heap_bytes_for_token(row.token, &bytes) != 0 else {
                    return "Đang chờ mẫu"
                }
                return String(format: "%.1f%% (%.1f MB)", 100 * Double(bytes) / Double(total),
                              Double(bytes) / 1_048_576)
            }
        }
    }

    private func detailLines(_ rows: [TabRow], value: (TabRow) -> String) -> String {
        guard !rows.isEmpty else { return "Không có tab đang chạy" }
        var lastPath: String?
        var lines: [String] = []
        for row in rows {
            let prefix = row.path == lastPath ? "    " : row.game + " — "
            lines.append(prefix + row.tab + " — " + value(row))
            lastPath = row.path
        }
        return lines.joined(separator: "\n")
    }
}

class AppsListViewController: UIViewController,
                      UICollectionViewDataSource,
                      UICollectionViewDelegate,
                      UIDocumentPickerDelegate {

    private var springboardCollectionView: UICollectionView!
    private let emptyStateLabel = UILabel()
    private var lastLayoutWidth: CGFloat = 0
    private weak var animatedBackground: AnimatedBackgroundView?
    private var springboardVisible = false
    private var gamePresentationInFlight = false
    private var gameTabTransitionCover: UIView?
    private var pendingTabMutation: UUID?
    private var foregroundTabDeletion: (ticket: UUID, path: String, id: UUID, token: UInt64)?
    private var pendingMutationNotice: String?
    private var autoProtectionTimer: Timer?
    private var autoProtectionGeneration: UInt64 = 0
    private var contextMenuVisible = false
    private var libraryTouchActive = false
    private var importBarButton: UIBarButtonItem?
    private var jarBoxMenuButton: UIBarButtonItem?
    // CPU sampling is event-based, process-wide; never attribute it to one game.
    // Black cover is idle by default. A requested HUD runs at 1 Hz for
    // 15 seconds; no periodic HUD work while it is hidden.
    private var jarBoxSleepCover: UIView?
    private weak var jarBoxSleepHUD: UILabel?
    private var jarBoxSleepTimer: Timer?
    private var jarBoxSleepCPUSample: (time: TimeInterval, cpu: Double)?
    private var jarBoxSleepCPUText = "CPU tổng: đang đo"
    private var jarBoxSleepBatteryWasEnabled: Bool?
    private var jarBoxSleepStartedAt: TimeInterval?
    private var jarBoxSleepHUDDeadline: TimeInterval?
    private var jarBoxSleepSamplingGeneration: UInt64 = 0
    private var jarBoxSleepBrightness: (screen: UIScreen, previous: CGFloat)?
    private var jarBoxSleepIdleTimerWasDisabled: Bool?

    // Set only for a library presented over its *own* live GameViewController.
    // A weak reference plus the native session token prevents stale UI controls
    // from treating a subsequent game as this session.
    weak var parkedGameController: GameViewController?

    // Root library owns the controllers of all admitted tabs. UIKit modal
    // presentation is only the visible surface, never the lifetime owner.
    // Keep STARTING/STOPPING controllers until their native tokens retire.
    private var managedGames: [GameViewController] = []


    private var retainedGames: [GameViewController] {
        if let parked = parkedGameController,
           !managedGames.contains(where: { $0 === parked }) {
            return managedGames + [parked]
        }
        return managedGames
    }

    private func gameForTab(_ path: String, cloneID: UUID?) -> GameViewController? {
        retainedGames.first { $0.ownsLiveInstance(for: path, cloneID: cloneID) }
    }

    private func hasNativeGame(for path: String) -> Bool {
        retainedGames.contains { $0.holdsNativeGameSession(for: path) }
    }

    private func hasRunningGame(for path: String) -> Bool {
        retainedGames.contains { $0.ownsLiveGameSession(for: path) }
    }

    private var liveGames: [GameViewController] {
        retainedGames.filter { $0.ownsLiveGameSession() }
    }

    func managedGameDidPark(_ game: GameViewController) {
        guard managedGames.contains(where: { $0 === game }) else { return }
        updateStuckSessionButton()
        springboardCollectionView.reloadData()
    }

    func managedGameDidRequestStop(_ game: GameViewController) {
        guard retainedGames.contains(where: { $0 === game }) else { return }
        // The last live tab removes the dot immediately, even while native
        // cleanup still owns the token. Other tabs keep the indicator on.
        springboardCollectionView.reloadData()
    }

    func managedGameDidEnd(_ game: GameViewController) {
        // A failed/stuck cleanup must retain the controller as long as the
        // exact native token still occupies a slot.
        guard !game.holdsNativeGameSession() else {
            updateStuckSessionButton()
            springboardCollectionView.reloadData()
            return
        }
        managedGames.removeAll { $0 === game }
        updateStuckSessionButton()
        springboardCollectionView.reloadData()
        (presentedViewController as? GameViewController)?.gameTabStateDidChange()
    }

    private var canPresentGame: Bool {
        jarBoxSleepCover == nil && !gamePresentationInFlight && presentedViewController == nil &&
        viewIfLoaded?.window != nil && !isBeingDismissed && pendingTabMutation == nil
    }

    // Cover only the library during UIKit's dismiss/present handoff.
    // Retain one transient snapshot of the outgoing game view instead of
    // flashing a black interstitial. Never use it as a live game frame,
    // never persist it, and release it when presentation completes.
    func beginGameTabTransition(from source: UIView?) {
        guard gameTabTransitionCover == nil else { return }
        cancelAutoProtection()
        setSpringboardMotion(false, reason: "tab handoff")
        let container = navigationController?.view ?? view!
        let cover = UIView()
        cover.backgroundColor = .black
        cover.isOpaque = true
        cover.accessibilityViewIsModal = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: container.topAnchor),
            cover.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        container.layoutIfNeeded()
        if let source, source.window != nil,
           let snapshot = source.snapshotView(afterScreenUpdates: false) {
            snapshot.frame = cover.bounds
            snapshot.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            snapshot.isUserInteractionEnabled = false
            snapshot.accessibilityElementsHidden = true
            cover.addSubview(snapshot)
        }
        gameTabTransitionCover = cover
        container.layoutIfNeeded()
    }

    func finishGameTabTransitionIfIdle() {
        guard !gamePresentationInFlight, let cover = gameTabTransitionCover else { return }
        gameTabTransitionCover = nil
        cover.removeFromSuperview()
        let visible = springboardVisible && presentedViewController == nil &&
            viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        setSpringboardMotion(visible, reason: "tab handoff complete")
        if visible { armAutoProtection() }
    }

    private func presentGame(_ game: GameViewController, reason: String) {
        guard canPresentGame else { return }
        gamePresentationInFlight = true
        setSpringboardMotion(false, reason: reason)
        present(game, animated: false) { [weak self] in
            self?.gamePresentationInFlight = false
            self?.finishGameTabTransitionIfIdle()
        }
    }

    func resumeManagedGame(_ game: GameViewController) {
        guard canPresentGame, managedGames.contains(where: { $0 === game }),
              game.ownsLiveGameSession(),
              jvm_bridge_visible_session_token() == 0 else { return }
        presentGame(game, reason: "resume retained game")
    }

    // All registered tabs, including stopped ones. Native ownership remains
    // with the existing GameVC and token, never with a UI button.
    // Position is derived from the ordered registry; UUID and save paths
    // never change when a new tab is inserted or an old one is removed.
    private func displayTabs(_ clones: [JarBoxGameStorage.CloneRecord]) -> [(id: UUID?, title: String)] {
        [(nil, "1 Gốc")] + clones.enumerated().map { index, clone in
            let legacy = clone.label.hasPrefix("Tab ") && Int(clone.label.dropFirst(4)) != nil
            let name = legacy ? "Tab" : clone.label
            return (Optional(clone.id), String(index + 2) + " " + name)
        }
    }

    private func registeredTabs(for app: AppInfo) throws -> [(id: UUID?, title: String)] {
        let clones = try JarBoxGameStorage.registeredClones(
            jarPath: app.path, documents: Self.documentsDirectory)
        return displayTabs(clones)
    }

    func gameTabItems(for game: GameViewController) -> [(id: UUID?, title: String, running: Bool)] {
        guard let app = apps.first(where: { $0.path == game.jarPath }),
              let tabs = try? registeredTabs(for: app) else {
            return [(game.cloneID, game.appName, true)]
        }
        return tabs.map { tab in
            (tab.id, tab.title, gameForTab(app.path, cloneID: tab.id) != nil)
        }
    }

    func rememberExitedGameTab(_ game: GameViewController) {
        guard managedGames.contains(where: { $0 === game }),
              game.parkedSessionToken != nil else { return }
        JarBoxGameStorage.rememberLastTab(jarPath: game.jarPath, cloneID: game.cloneID)
    }

    // Only a foreground dismissal completion calls this. Hidden worker
    // exits must never steal focus from the tab the user is playing.
    func openNextRunningTabAfterExit(path: String, closing: UUID?) {
        if let deletion = foregroundTabDeletion, deletion.path == path, deletion.id == closing {
            completeForegroundTabDeletion(deletion)
            return
        }
        guard canPresentGame, jvm_bridge_visible_session_token() == 0,
              let app = apps.first(where: { $0.path == path }) else { return }
        do {
            let tabs = try registeredTabs(for: app)
            let running = Set(tabs.filter {
                gameForTab(path, cloneID: $0.id)?.parkedSessionToken != nil
            }.map { $0.id })
            guard let index = JarBoxGameStorage.nextRunningTabIndex(
                ordered: tabs.map { $0.id }, closing: closing, running: running),
                  let game = gameForTab(path, cloneID: tabs[index].id),
                  game.parkedSessionToken != nil else {
                // No surviving tab: future icon taps start the original.
                if running.isEmpty { JarBoxGameStorage.rememberLastTab(jarPath: path, cloneID: nil) }
                return
            }
            game.resumeParkedGame()
        } catch { presentSaveOperationError(error) }
    }

    func validateGameTabSwitch(_ source: GameViewController, target: UUID?) throws {
        guard pendingTabMutation == nil, presentedViewController === source,
              source.ownsVisibleGameSession(),
              let app = apps.first(where: { $0.path == source.jarPath }),
              try registeredTabs(for: app).contains(where: { $0.id == target }) else {
            throw mutationError("Tab hoặc phiên game đã thay đổi.")
        }
        if let game = gameForTab(app.path, cloneID: target), game.parkedSessionToken != nil {
            return
        }
        guard !retainedGames.contains(where: { $0.holdsNativeInstance(for: app.path, cloneID: target) }) else {
            throw mutationError("Tab này vẫn đang khởi động hoặc đang dừng.")
        }
        try requireNewTabSlot(for: app)
    }

    private func memoryLaunchDenial() -> String? {
        guard JarBoxMemoryProtection.launchDenialMessage() != nil else { return nil }
        _ = j2me_render_trim_memory_cache()
        restoreRetainedGamesForMemoryPressure()
        // Re-sample after trimming; never grant admission using old headroom.
        return JarBoxMemoryProtection.launchDenialMessage()
    }

    private func requireNewTabSlot(for app: AppInfo) throws {
        if let reason = memoryLaunchDenial() {
            throw mutationError(reason)
        }
        guard jvm_bridge_active_session_count() < jvm_bridge_supported_concurrent_sessions(),
              app.path.withCString({ jvm_bridge_3d_conflict_for_jar($0) }) == 0 else {
            throw mutationError("Không thể mở thêm tab. Đã hết slot JVM hoặc game phải chạy riêng.")
        }
    }

    // Check capacity before touching the registry or parking the current VM.
    func createTabBeside(_ source: GameViewController) throws -> UUID {
        guard pendingTabMutation == nil, presentedViewController === source,
              source.ownsVisibleGameSession(),
              let app = apps.first(where: { $0.path == source.jarPath }) else {
            throw mutationError("Phiên game đã thay đổi.")
        }
        let tabs = try registeredTabs(for: app)
        guard tabs.count < JarBoxGameStorage.maxTotalTabs else {
            throw JarBoxGameStorage.tabQuantityError(maximum: 0)
        }
        try requireNewTabSlot(for: app)
        let clone = try JarBoxGameStorage.createCloneAfter(jarPath: app.path,
            documents: Self.documentsDirectory, after: source.cloneID)
        updateRegisteredCloneCount(for: app.path, count: tabs.count)
        return clone.id
    }

    // Deletion is armed only by explicit confirmation in the visible game.
    // The worker completion retires the token before any disk mutation.
    func armForegroundTabDeletion(_ source: GameViewController, expectedToken: UInt64) throws {
        guard pendingTabMutation == nil, presentedViewController === source,
              source.ownsVisibleGameSession(), source.nativeSessionToken == expectedToken,
              let id = source.cloneID,
              let app = apps.first(where: { $0.path == source.jarPath }) else {
            throw mutationError("Tab gốc không thể xóa hoặc phiên đã thay đổi.")
        }
        let tabs = try registeredTabs(for: app)
        guard tabs.count > 1, tabs.contains(where: { $0.id == id }) else {
            throw mutationError("Không thể xóa tab cuối cùng.")
        }
        try JarBoxGameStorage.requireMutationSafety(unrelatedTokens: retainedGames.compactMap { $0.nativeSessionToken })
        let ticket = UUID()
        pendingTabMutation = ticket
        foregroundTabDeletion = (ticket, app.path, id, expectedToken)
        cancelAutoProtection()
        springboardCollectionView.isUserInteractionEnabled = false
        importBarButton?.isEnabled = false
        jarBoxMenuButton?.isEnabled = false
    }

    private func completeForegroundTabDeletion(_ deletion: (ticket: UUID, path: String, id: UUID, token: UInt64)) {
        guard pendingTabMutation == deletion.ticket else { return }
        foregroundTabDeletion = nil
        do {
            guard jvm_bridge_session_is_active_for_token(deletion.token) == 0,
                  mutationOwners(path: deletion.path, ids: [deletion.id]).isEmpty,
                  let app = apps.first(where: { $0.path == deletion.path }) else {
                throw mutationError("Phiên chưa dừng hẳn. Chưa xóa dữ liệu.")
            }
            let tabs = try registeredTabs(for: app)
            let running = Set(tabs.filter {
                gameForTab(app.path, cloneID: $0.id)?.parkedSessionToken != nil
            }.map { $0.id })
            guard let index = JarBoxGameStorage.deletionNeighborIndex(
                ordered: tabs.map { $0.id }, deleting: deletion.id, running: running) else {
                throw mutationError("Không còn tab hợp lệ để chuyển.")
            }
            let target = tabs[index]
            let unrelated = retainedGames.compactMap { $0.nativeSessionToken }
            try JarBoxGameStorage.removeClones(jarPath: app.path, documents: Self.documentsDirectory,
                                               cloneIDs: [deletion.id], unrelatedTokens: unrelated)
            updateRegisteredCloneCount(for: app.path, count: tabs.count - 2)
            finishTabMutation(deletion.ticket)
            let updated = try registeredTabs(for: app)
            guard let next = updated.first(where: { $0.id == target.id }) else { return }
            guard viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else {
                JarBoxGameStorage.rememberLastTab(jarPath: app.path, cloneID: next.id)
                return
            }
            launchGameTab(app, cloneID: next.id,
                          tabTitle: next.id == nil ? app.name : app.name + " · " + next.title)
        } catch {
            finishTabMutation(deletion.ticket)
            scanApps()
            presentSaveOperationError(error)
        }
    }

    func openGameTabAfterPark(_ source: GameViewController, cloneID: UUID?) {
        guard canPresentGame, managedGames.contains(where: { $0 === source }),
              source.parkedSessionToken != nil, source.cloneID != cloneID,
              let app = apps.first(where: { $0.path == source.jarPath }) else { return }
        do {
            let tabs = try registeredTabs(for: app)
            guard let target = tabs.first(where: { $0.id == cloneID }) else { return }
            launchGameTab(app, cloneID: target.id,
                          tabTitle: target.id == nil ? app.name : app.name + " · " + target.title)
        } catch {
            presentSaveOperationError(error)
        }
    }

    private func stopMenu(for app: AppInfo, tabs: [(id: UUID?, title: String)]) -> UIMenuElement {
        let snapshots = tabs.compactMap { tab -> (title: String, game: GameViewController?, token: UInt64?)? in
            guard let game = gameForTab(app.path, cloneID: tab.id),
                  let token = game.parkedSessionToken else { return nil }
            return (tab.title, game, token)
        }
        func action(_ title: String, _ targets: [(title: String, game: GameViewController?, token: UInt64?)]) -> UIAction {
            let available = targets.contains { $0.token != nil }
            return UIAction(title: title, image: UIImage(systemName: "stop.fill"),
                            attributes: available ? .destructive : [.destructive, .disabled]) { [weak self] _ in
                guard let self, self.pendingTabMutation == nil else { return }
                for target in targets {
                    guard let game = target.game, let token = target.token,
                          self.retainedGames.contains(where: { $0 === game }),
                          game.parkedSessionToken == token else { continue }
                    game.stopParkedGame()
                }
                self.updateStuckSessionButton()
            }
        }
        if snapshots.count <= 1 { return action("Dừng", snapshots) }
        return UIMenu(title: "Dừng", image: UIImage(systemName: "stop.fill"),
                      children: [action("Tất cả", snapshots)] + snapshots.map { action($0.title, [$0]) })
    }

    private func clearDataMenu(for app: AppInfo, tabs: [(id: UUID?, title: String)]) -> UIMenuElement {
        func action(_ title: String, _ targets: [(id: UUID?, title: String)]) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: "eraser"),
                     attributes: .destructive) { [weak self] _ in
                self?.confirmClearGameData(for: app, tabs: targets)
            }
        }
        if tabs.count == 1 { return action("Xóa dữ liệu", tabs) }
        return UIMenu(title: "Xóa dữ liệu", image: UIImage(systemName: "eraser"),
                      children: [action("Tất cả", tabs)] + tabs.map {
                          action(tabStatusTitle($0.title, path: app.path, cloneID: $0.id), [$0])
                      })
    }

    private func tabStatusTitle(_ title: String, path: String, cloneID: UUID?) -> String {
        if gameForTab(path, cloneID: cloneID) != nil { return title + " · Đang chạy" }
        if retainedGames.contains(where: { $0.holdsNativeInstance(for: path, cloneID: cloneID) }) {
            return title + " · Đang dừng"
        }
        return title
    }

    // Keep lifecycle diagnostics but do not restart any decorative work.
    func sceneActivityChanged(_ active: Bool) {
        guard springboardVisible else { return }
        setSpringboardMotion(active, reason: active ? "scene active" : "scene inactive")
        setJarBoxSleepSampling(active)
        libraryTouchActive = false
        if active { armAutoProtection() } else { cancelAutoProtection() }
    }

    private func setSpringboardMotion(_ enabled: Bool, reason: String) {
        animatedBackground?.setAnimationsActive(enabled && jarBoxSleepCover == nil &&
            gameTabTransitionCover == nil, reason: reason)
    }

    /// Directory where imported JARs are stored
    private static var gamesDirectory: String {
        documentsDirectory + "/games"
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        restoreRetainedGamesForMemoryPressure()
    }

    private func restoreRetainedGamesForMemoryPressure() {
        // Parked controllers are retained offscreen. Forward this event to
        // each exact owner; do not depend on hidden views receiving it.
        for game in retainedGames {
            game.restoreSafeGCForMemoryPressure()
        }
    }

    private var lastMemoryNotice: TimeInterval?
    // AppDelegate receives the warning even when this library is hidden.
    // No forced stop, no destructive cleanup and no extra polling timer.
    func handleAppMemoryPressure() {
        restoreRetainedGamesForMemoryPressure()
        var bytes: UInt64 = 0
        let state = jvm_bridge_memory_state(&bytes)
        NSLog("[JarBoxMemory] warning headroom=%llu state=%d", bytes, state)
        guard springboardVisible, pendingTabMutation == nil, jarBoxSleepCover == nil,
              gameTabTransitionCover == nil, !gamePresentationInFlight, !contextMenuVisible,
              !isBeingDismissed, presentedViewController == nil,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastMemoryNotice, now - last < 30 { return }
        lastMemoryNotice = now
        cancelAutoProtection()
        let alert = UIAlertController(title: state == 2 ? "RAM rất thấp" : "Cảnh báo bộ nhớ",
            message: "iOS đang thiếu bộ nhớ. JarBox tạm chặn mở game mới. Hãy dừng bớt tab nếu cần để tránh iOS đóng toàn bộ ứng dụng.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel) { [weak self] _ in self?.armAutoProtection() })
        present(alert, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AnimatedBackgroundView.backgroundGray

        // Single opaque gray view; no raster or animation work
        let bg = AnimatedBackgroundView()
        animatedBackground = bg
        bg.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bg)
        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: view.topAnchor),
            bg.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bg.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // "+" button — import JAR from Files
        let importButton = UIBarButtonItem(
            systemItem: .add, primaryAction: UIAction { [weak self] _ in
                self?.addAppTapped()
            })
        importBarButton = importButton
        let globalMenu = UIBarButtonItem(
            title: nil,
            image: UIImage(systemName: "ellipsis.circle"),
            primaryAction: nil,
            menu: nil)
        globalMenu.accessibilityLabel = "Menu tổng JarBox"
        jarBoxMenuButton = globalMenu
        updateStuckSessionButton()

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 10

        springboardCollectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        springboardCollectionView.dataSource = self
        springboardCollectionView.delegate = self
        springboardCollectionView.backgroundColor = .clear
        springboardCollectionView.alwaysBounceVertical = true
        springboardCollectionView.showsVerticalScrollIndicator = false
        springboardCollectionView.register(SpringboardCell.self,
                                           forCellWithReuseIdentifier: SpringboardCell.reuseID)
        springboardCollectionView.contentInsetAdjustmentBehavior = .always
        springboardCollectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(springboardCollectionView)

        NSLayoutConstraint.activate([
            springboardCollectionView.topAnchor.constraint(equalTo: view.topAnchor),
            springboardCollectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            springboardCollectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            springboardCollectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Empty state
        emptyStateLabel.text = "No Games Yet\nTap + to add a .jar file"
        emptyStateLabel.textColor = .secondaryLabel
        emptyStateLabel.font = .systemFont(ofSize: 17)
        emptyStateLabel.textAlignment = .center
        emptyStateLabel.numberOfLines = 0
        emptyStateLabel.isHidden = true
        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyStateLabel)
        NSLayoutConstraint.activate([
            emptyStateLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -40),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
        ])

        // Ensure games directory exists
        try? FileManager.default.createDirectory(atPath: Self.gamesDirectory,
                                                  withIntermediateDirectories: true)
        scanApps()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        springboardVisible = true
        let sceneActive = view.window?.windowScene?.activationState == .foregroundActive
        // A temporary UIKit presentation must not forget protection mode.
        if let cover = jarBoxSleepCover {
            cover.isHidden = false
            cover.superview?.bringSubviewToFront(cover)
        }
        setJarBoxSleepSampling(sceneActive)
        setSpringboardMotion(sceneActive, reason: sceneActive
                             ? "springboard visible and scene active"
                             : "springboard visible, waiting for active scene")
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(jarBoxWillResignActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(springboardThermalChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        logSpringboardEnergyState("library appeared")
        updateStuckSessionButton()
        if let notice = pendingMutationNotice {
            pendingMutationNotice = nil
            presentSaveOperationError(mutationError(notice))
        }
        armAutoProtection()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        springboardVisible = false
        libraryTouchActive = false
        contextMenuVisible = false
        cancelAutoProtection()
        // Release display ownership before another controller becomes visible.
        // Keep protection armed across temporary disappearance, but not when
        // the owning library/navigation controller is actually removed.
        if isBeingDismissed || isMovingFromParent ||
            navigationController?.isBeingDismissed == true {
            hideJarBoxSleepScreen()
        } else {
            setJarBoxSleepSampling(false)
            jarBoxSleepCover?.isHidden = true
        }
        setSpringboardMotion(false, reason: "springboard disappearing")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
        setJarBoxSleepSampling(true)
        scanApps()
        updateStuckSessionButton()
        logSpringboardEnergyState("app became active")
        if let notice = pendingMutationNotice, presentedViewController == nil, springboardVisible {
            pendingMutationNotice = nil
            presentSaveOperationError(mutationError(notice))
        }
        libraryTouchActive = false
        armAutoProtection()
    }

    // Event-driven refresh only. Ordinary stop/resume actions do not occupy
    // the navigation bar; exceptional native recovery remains reachable.
    private func updateStuckSessionButton() {
        navigationItem.title = "Thư viện"
        navigationItem.leftBarButtonItem = nil
        navigationItem.rightBarButtonItems = [importBarButton, jarBoxMenuButton].compactMap { $0 }
        jarBoxMenuButton?.menu = makeLibraryMenu()
    }

    private func makeLibraryMenu() -> UIMenu {
        var actions: [UIMenuElement] = [
            UIAction(title: "Bảo vệ màn hình",
                     image: UIImage(systemName: "moon.zzz")) { [weak self] _ in
                self?.showJarBoxSleepScreen()
            },
            UIAction(title: "Trạng thái",
                     image: UIImage(systemName: "chart.bar.xaxis")) { [weak self] _ in
                self?.showJarBoxOverview()
            },
            UIAction(title: "Âm nền Treo (thử nghiệm)", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                if let self { JarBoxBackgroundDiagnostics.showAudio(from: self) }
            },
            UIAction(title: "Log Treo tắt màn hình", image: UIImage(systemName: "doc.text")) { [weak self] _ in
                if let self { JarBoxBackgroundDiagnostics.show(from: self) }
            },
            UIAction(title: "Cài đặt", image: UIImage(systemName: "gearshape")) { [weak self] _ in
                self?.showJarBoxSettings()
            }
        ]
        if liveGames.isEmpty, jvm_bridge_session_is_active() != 0 {
            actions.append(UIAction(title: "Xử lý phiên kẹt",
                                    image: UIImage(systemName: "exclamationmark.triangle")) { [weak self] _ in
                self?.openStuckSessionRecovery()
            })
        }
        return UIMenu(title: "JarBox", children: actions)
    }

    private func showJarBoxSettings() {
        guard pendingTabMutation == nil, jarBoxSleepCover == nil else { return }
        let picker = UIAlertController(title: "Cài đặt", message: nil, preferredStyle: .actionSheet)
        let proxy = UIAlertAction(title: "Proxy", style: .default) { [weak self] _ in
            guard let self else { return }
            self.cancelAutoProtection()
            let settings = JarBoxProxySettingsController(style: .insetGrouped)
            let nav = JarBoxLibraryNavigationController(rootViewController: settings)
            nav.modalPresentationStyle = .fullScreen
            self.present(nav, animated: true)
        }
        picker.addAction(proxy)
        picker.addAction(UIAlertAction(title: "Tự động bảo vệ màn hình", style: .default) { [weak self] _ in
            guard let self else { return }
            let settings = JarBoxProtectionSettingsController()
            settings.onSaved = { [weak self] in self?.armAutoProtection() }
            let nav = JarBoxLibraryNavigationController(rootViewController: settings)
            nav.modalPresentationStyle = .fullScreen
            self.present(nav, animated: true)
        })
        picker.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        if let popover = picker.popoverPresentationController {
            popover.barButtonItem = jarBoxMenuButton
        }
        present(picker, animated: true)
    }

    private func showAnotherGameBlocked(_ app: AppInfo) {
        let limit = jvm_bridge_supported_concurrent_sessions()
        let alert = UIAlertController(
            title: "Đã đạt giới hạn phiên JVM",
            message: "JarBox hiện cho phép tối đa " + String(limit) +
                " phiên đồng thời. Hãy giữ icon game đang chạy và chọn Dừng trước khi mở " +
                app.name + ".",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func openStuckSessionRecovery() {
        guard liveGames.isEmpty, jvm_bridge_session_is_active() != 0 else {
            updateStuckSessionButton()
            return
        }
        let blockedToken = jvm_bridge_session_token()
        let alert = UIAlertController(
            title: "Phiên game cũ chưa dừng",
            message: "Bạn đã về thư viện nhưng JVM vẫn tồn tại (pha \(jvm_bridge_session_phase())). " +
                     "Hãy thử ngắt Java thread trước. Nếu không thể dừng, " +
                     "bạn có thể đóng JarBox để giải phóng toàn bộ tiến trình.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Ngắt luồng Java", style: .default) { _ in
            let signalled = jvm_bridge_request_stop_for_token(blockedToken)
            DispatchQueue.global(qos: .userInitiated).async {
                let interrupted = signalled != 0
                    ? jvm_bridge_interrupt_active_threads_for_token(blockedToken) : 0
                NSLog("[JarBoxVM][Lifecycle] library_interrupt=%d", interrupted)
            }
        })
        alert.addAction(UIAlertAction(title: "Buộc đóng JarBox", style: .destructive) { [weak self] _ in
            self?.confirmLibraryEmergencyExit()
        })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        present(alert, animated: true)
    }

    private func confirmLibraryEmergencyExit() {
        guard jvm_bridge_session_is_active() != 0 else { return }
        let expectedToken = jvm_bridge_session_token()
        guard expectedToken != 0 else { return }
        let alert = UIAlertController(
            title: "Đóng toàn bộ JarBox?",
            message: "Dữ liệu game chưa lưu có thể mất. JarBox sẽ tắt hẳn " +
                     "để kết thúc mọi luồng JVM và socket. Bạn cần tự mở lại.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Không", style: .cancel))
        alert.addAction(UIAlertAction(title: "Đóng JarBox ngay", style: .destructive) { _ in
            guard jvm_bridge_session_token() == expectedToken else { return }
            NSLog("[JarBoxVM][Lifecycle] library_process_exit_confirmed")
            Darwin.exit(0)
        })
        present(alert, animated: true)
    }

    @objc private func springboardThermalChanged() {
        logSpringboardEnergyState("thermal state changed")
        // The on-demand HUD reads thermal state on its next tick.
    }

    // Global screen cover, independent from a parked game's native Treo.
    // The native JVM is already in mode 8 from Back -> library. Opening
    // this display must not reset it, change game clocks or create a JVM.
    // A one-shot idle deadline, not an always-on polling loop. Any library
    // input, presentation or inactive scene invalidates the old generation.
    private func cancelAutoProtection() {
        autoProtectionGeneration &+= 1
        autoProtectionTimer?.invalidate()
        autoProtectionTimer = nil
        if jarBoxSleepCover == nil { setJarBoxSleepIdleTimer(false) }
    }

    func libraryInputChanged(activeTouch: Bool) {
        guard springboardVisible, jarBoxSleepCover == nil else { return }
        libraryTouchActive = activeTouch
        if activeTouch { cancelAutoProtection() } else { armAutoProtection() }
    }

    private func armAutoProtection() {
        cancelAutoProtection()
        guard JarBoxProtectionPreferences.automatic, springboardVisible,
              jarBoxSleepCover == nil, pendingTabMutation == nil, gameTabTransitionCover == nil,
              !gamePresentationInFlight, !contextMenuVisible, !libraryTouchActive,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else { return }
        // Keep iOS auto-lock from winning the configured countdown, but
        // never hold this lease while another controller is presented.
        if presentedViewController == nil { setJarBoxSleepIdleTimer(true) }
        let generation = autoProtectionGeneration
        let timer = Timer(timeInterval: TimeInterval(JarBoxProtectionPreferences.seconds),
                          repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.autoProtectionGeneration == generation else { return }
                self.cancelAutoProtection()
                guard JarBoxProtectionPreferences.automatic, self.springboardVisible,
                      !self.contextMenuVisible, !self.libraryTouchActive,
                      !self.gamePresentationInFlight, self.pendingTabMutation == nil,
                      self.gameTabTransitionCover == nil, self.presentedViewController == nil,
                      self.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
                      !self.springboardCollectionView.isDragging,
                      !self.springboardCollectionView.isDecelerating else { return }
                self.showJarBoxSleepScreen()
            }
        }
        autoProtectionTimer = timer
        RunLoop.main.add(timer, forMode: .default)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { armAutoProtection() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate: Bool) {
        if !willDecelerate { armAutoProtection() }
    }

    func collectionView(_ collectionView: UICollectionView,
                        willDisplayContextMenu configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionAnimating?) {
        contextMenuVisible = true
        cancelAutoProtection()
    }

    func collectionView(_ collectionView: UICollectionView,
                        willEndContextMenu configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionAnimating?) {
        let finished = { [weak self] in
            self?.contextMenuVisible = false
            self?.armAutoProtection()
        }
        if let animator { animator.addCompletion(finished) } else { finished() }
    }

    private func showJarBoxSleepScreen() {
        guard springboardVisible, jarBoxSleepCover == nil, pendingTabMutation == nil,
              gameTabTransitionCover == nil, presentedViewController == nil,
              viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive else { return }
        cancelAutoProtection()
        let container = navigationController?.view ?? view!
        let cover = UIView()
        cover.backgroundColor = .black
        cover.isOpaque = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.accessibilityIdentifier = "jarbox-global-sleep-screen"
        cover.accessibilityViewIsModal = true
        container.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: container.topAnchor),
            cover.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        let wake = UIButton(type: .system)
        wake.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        wake.tintColor = UIColor(white: 0.58, alpha: 1)
        wake.backgroundColor = .clear
        wake.accessibilityLabel = "Thoát bảo vệ màn hình JarBox"
        wake.accessibilityIdentifier = "jarbox-global-sleep-wake"
        wake.translatesAutoresizingMaskIntoConstraints = false
        wake.addTarget(self, action: #selector(hideJarBoxSleepScreen), for: .touchUpInside)
        let information = UIButton(type: .system)
        information.setImage(UIImage(systemName: "info.circle"), for: .normal)
        information.tintColor = wake.tintColor
        information.backgroundColor = .clear
        information.accessibilityLabel = "Thông tin JarBox"
        information.accessibilityIdentifier = "jarbox-global-sleep-info"
        information.addTarget(self, action: #selector(showJarBoxSleepInformation), for: .touchUpInside)

        let controls = UIStackView(arrangedSubviews: [wake, information])
        controls.axis = .horizontal
        controls.alignment = .center
        controls.distribution = .fillEqually
        controls.spacing = 16
        controls.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(controls)
        information.translatesAutoresizingMaskIntoConstraints = false

        let info = UILabel()
        info.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        info.textColor = UIColor(white: 0.48, alpha: 1)
        info.numberOfLines = 0
        info.isHidden = true
        info.textAlignment = .left
        info.adjustsFontSizeToFitWidth = true
        info.minimumScaleFactor = 0.85
        info.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(info)
        let infoWidth = info.widthAnchor.constraint(equalToConstant: 220)
        infoWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            infoWidth,
            controls.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            wake.widthAnchor.constraint(equalToConstant: 56),
            wake.heightAnchor.constraint(equalToConstant: 56),
            information.heightAnchor.constraint(equalToConstant: 56),
            info.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 20),
            info.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            info.leadingAnchor.constraint(greaterThanOrEqualTo: cover.leadingAnchor, constant: 16),
            info.trailingAnchor.constraint(lessThanOrEqualTo: cover.trailingAnchor, constant: -16),
            info.bottomAnchor.constraint(lessThanOrEqualTo: cover.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        // Overlay intercepts all stray taps; only the wake control closes it.
        container.bringSubviewToFront(cover)
        jarBoxSleepCover = cover
        jarBoxSleepHUD = info
        jarBoxSleepStartedAt = ProcessInfo.processInfo.systemUptime
        jarBoxSleepCPUText = "CPU tổng: đang đo"
        NSLog("[JarBoxSleep] opened")
        setSpringboardMotion(false, reason: "JarBox sleep screen")
        setJarBoxSleepSampling(view.window?.windowScene?.activationState == .foregroundActive)
    }

    @objc private func hideJarBoxSleepScreen() {
        guard let cover = jarBoxSleepCover else { return }
        setJarBoxSleepSampling(false)
        jarBoxSleepStartedAt = nil
        jarBoxSleepHUD = nil
        jarBoxSleepCover = nil
        cover.removeFromSuperview()
        NSLog("[JarBoxSleep] closed")
        let active = view.window?.windowScene?.activationState == .foregroundActive
        setSpringboardMotion(springboardVisible && active, reason: "JarBox sleep screen closed")
        armAutoProtection()
    }

    @objc private func jarBoxWillResignActive() {
        libraryTouchActive = false
        cancelAutoProtection()
        setJarBoxSleepSampling(false)
    }

    // Only change brightness while the foreground cover owns it. Restore on
    // exit and before Control Center, app switching, or device lock.
    private func setJarBoxSleepBrightness(_ active: Bool) {
        if active {
            guard jarBoxSleepBrightness == nil,
                  let screen = view.window?.windowScene?.screen else { return }
            jarBoxSleepBrightness = (screen, screen.brightness)
            screen.brightness = 0
        } else if let saved = jarBoxSleepBrightness {
            jarBoxSleepBrightness = nil
            // Do not overwrite a brightness adjustment made by the user.
            if saved.screen.brightness == 0 {
                saved.screen.brightness = saved.previous
            }
        }
    }

    // Auto-lock would suspend the process and defeat foreground Treo.
    // Lease the idle timer only while this cover owns the active display.
    private func setJarBoxSleepIdleTimer(_ active: Bool) {
        let app = UIApplication.shared
        if active {
            guard jarBoxSleepIdleTimerWasDisabled == nil else { return }
            jarBoxSleepIdleTimerWasDisabled = app.isIdleTimerDisabled
            app.isIdleTimerDisabled = true
        } else if let previous = jarBoxSleepIdleTimerWasDisabled {
            jarBoxSleepIdleTimerWasDisabled = nil
            if app.isIdleTimerDisabled { app.isIdleTimerDisabled = previous }
        }
    }

    private func setJarBoxSleepSampling(_ active: Bool) {
        guard let cover = jarBoxSleepCover else { return }
        // UIApplication and UIScene can deliver overlapping notifications.
        // A positive event alone is not proof this cover is foreground.
        let ownsDisplay = active && springboardVisible && !cover.isHidden &&
            view.window?.windowScene?.activationState == .foregroundActive
        let wasOwning = jarBoxSleepIdleTimerWasDisabled != nil
        setJarBoxSleepBrightness(ownsDisplay)
        setJarBoxSleepIdleTimer(ownsDisplay)
        if !ownsDisplay { hideJarBoxSleepInformation() }
        if wasOwning != ownsDisplay {
            NSLog("[JarBoxSleep] display ownership %@", ownsDisplay ? "acquired" : "released")
        }
    }

    @objc private func showJarBoxSleepInformation() {
        guard jarBoxSleepCover != nil, springboardVisible,
              view.window?.windowScene?.activationState == .foregroundActive,
              let label = jarBoxSleepHUD else { return }
        // A second tap closes the HUD without closing the protection cover.
        if !label.isHidden {
            hideJarBoxSleepInformation()
            return
        }
        // A new opening starts with a fresh CPU baseline and deadline.
        hideJarBoxSleepInformation()
        let now = ProcessInfo.processInfo.systemUptime
        jarBoxSleepHUDDeadline = now + 15
        jarBoxSleepCPUSample = (now, treo_process_cpu_seconds())
        let device = UIDevice.current
        jarBoxSleepBatteryWasEnabled = device.isBatteryMonitoringEnabled
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        label.isHidden = false
        refreshJarBoxSleepHUD()
        let generation = jarBoxSleepSamplingGeneration
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.jarBoxSleepSamplingGeneration == generation,
                      self.jarBoxSleepTimer != nil,
                      let deadline = self.jarBoxSleepHUDDeadline else { return }
                guard ProcessInfo.processInfo.systemUptime < deadline else {
                    self.hideJarBoxSleepInformation()
                    return
                }
                self.sampleJarBoxSleepCPU()
                self.refreshJarBoxSleepHUD()
            }
        }
        timer.tolerance = 0.05
        jarBoxSleepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func hideJarBoxSleepInformation() {
        jarBoxSleepSamplingGeneration &+= 1
        jarBoxSleepTimer?.invalidate()
        jarBoxSleepTimer = nil
        jarBoxSleepHUDDeadline = nil
        jarBoxSleepCPUSample = nil
        jarBoxSleepCPUText = "CPU tổng: đang đo"
        jarBoxSleepHUD?.isHidden = true
        jarBoxSleepHUD?.text = nil
        if let old = jarBoxSleepBatteryWasEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = old
            jarBoxSleepBatteryWasEnabled = nil
        }
    }

    private func sampleJarBoxSleepCPU() {
        let now = ProcessInfo.processInfo.systemUptime
        let cpuNow = treo_process_cpu_seconds()
        guard cpuNow.isFinite, cpuNow >= 0 else {
            jarBoxSleepCPUSample = nil
            jarBoxSleepCPUText = "CPU tổng: đang đo"
            return
        }
        guard let prev = jarBoxSleepCPUSample, prev.cpu.isFinite,
              prev.cpu >= 0, cpuNow >= prev.cpu, now >= prev.time else {
            jarBoxSleepCPUSample = (now, cpuNow)
            jarBoxSleepCPUText = "CPU tổng: đang đo"
            return
        }
        // Never divide by an entry-time or notification-time micro-interval.
        // Keep the baseline until a meaningful measurement has elapsed.
        let elapsed = now - prev.time
        guard elapsed >= 0.9 else { return }
        jarBoxSleepCPUText = String(format: "CPU tổng: %.1f%%",
                                    100 * (cpuNow - prev.cpu) / elapsed)
        jarBoxSleepCPUSample = (now, cpuNow)
    }

    private func jarBoxSleepDurationText(_ elapsed: TimeInterval) -> String {
        let minutes = Int(max(0, elapsed) / 60)
        if minutes < 60 { return "\(minutes) phút" }
        return "\(minutes / 60) giờ \(minutes % 60) phút"
    }

    // mach task footprint includes the native and Java heaps of this process.
    // Read only while the existing HUD is visible (or the overview is opened).
    private func jarBoxRAMText() -> String {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size /
                                           MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS, total > 0, vm.phys_footprint > 0 else {
            return "RAM: Chưa có dữ liệu"
        }
        let bytes = Double(vm.phys_footprint)
        return String(format: "RAM: %.1f%% (%.0f MB)", 100 * bytes / Double(total),
                      bytes / 1_048_576)
    }

    private func refreshJarBoxSleepHUD() {
        guard jarBoxSleepCover != nil, let label = jarBoxSleepHUD,
              !label.isHidden, jarBoxSleepHUDDeadline != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime

        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "Bình thường"
        case .fair: thermal = "Tăng nhẹ"
        case .serious: thermal = "Cao"
        case .critical: thermal = "Rất cao"
        @unknown default: thermal = "Không xác định"
        }
        let batteryLevel = UIDevice.current.batteryLevel
        let battery = batteryLevel >= 0
            ? String(format: "%.0f%%", Double(batteryLevel) * 100)
            : "Chưa có dữ liệu"
        let elapsed = max(0, now - (jarBoxSleepStartedAt ?? now))
        let lines = [
            jarBoxSleepCPUText,
            jarBoxRAMText(),
            "Pin: " + battery,
            "Nhiệt độ: " + thermal,
            "Tab đang chạy: " + String(jvm_bridge_active_session_count()) +
                "/" + String(jvm_bridge_supported_concurrent_sessions()),
            "Thời gian: " + jarBoxSleepDurationText(elapsed)
        ]
        let updated = lines.joined(separator: "\n")
        if label.text != updated { label.text = updated }
    }

    private func statusTabRows() -> [(game: String, path: String, tab: String, token: UInt64)] {
        // Use the registered display order, not the order controllers were opened.
        var rows: [(game: String, path: String, tab: String, token: UInt64)] = []
        let owners = retainedGames.filter { $0.nativeSessionToken != nil }
        let paths = Set(owners.map { $0.jarPath })
        for app in apps where paths.contains(app.path) {
            guard let tabs = try? registeredTabs(for: app) else { continue }
            for tab in tabs {
                guard let owner = owners.first(where: {
                    $0.holdsNativeInstance(for: app.path, cloneID: tab.id)
                }), let token = owner.nativeSessionToken else { continue }
                rows.append((app.name, app.path, tab.title, token))
            }
        }
        return rows
    }

    private func showJarBoxOverview() {
        guard presentedViewController == nil, pendingTabMutation == nil,
              jarBoxSleepCover == nil, gameTabTransitionCover == nil else { return }
        cancelAutoProtection()
        let status = JarBoxStatusController()
        status.readRAM = { [weak self] in self?.jarBoxRAMText().replacingOccurrences(of: "RAM:", with: "RAM App:") ?? "RAM App: —" }
        // No game can be admitted while this full-screen modal is open.
        // Capture labels once; filter retired tokens on every detail refresh.
        let rows = statusTabRows()
        status.readTabs = { rows.filter { jvm_bridge_session_is_active_for_token($0.token) != 0 } }
        let nav = JarBoxLibraryNavigationController(rootViewController: status)
        nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }

    private func logSpringboardEnergyState(_ reason: String) {
        guard springboardVisible else { return }
        // Event-based only. No timer, continuous sampling, GPU profiling, or
        // recurring work is introduced on the low-power library screen.
        let thermalName: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermalName = "nominal"
        case .fair: thermalName = "fair"
        case .serious: thermalName = "serious"
        case .critical: thermalName = "critical"
        @unknown default: thermalName = "unknown"
        }
        NSLog("[JarBoxBG][Idle] %@ thermal=%@ brightness=%.2f idle_timer_disabled=%d jvm_phase=%d bg_animated=%d bg_animation_layers=%d",
              reason, thermalName, UIScreen.main.brightness,
              UIApplication.shared.isIdleTimerDisabled ? 1 : 0,
              jvm_bridge_session_phase(),
              AnimatedBackgroundView.springboardAnimating ? 1 : 0,
              animatedBackground?.activeAnimationLayers ?? -1)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = springboardCollectionView.bounds.width
        guard width > 0, width != lastLayoutWidth else { return }
        lastLayoutWidth = width

        let columns: CGFloat = 4
        let iconSize = SpringboardCell.iconSize
        let cellWidth = (width + iconSize) / (columns + 1)
        let horizontalInset = (cellWidth - iconSize) / 2

        guard let layout = springboardCollectionView.collectionViewLayout as? UICollectionViewFlowLayout else { return }
        layout.itemSize = CGSize(width: cellWidth, height: 96)
        layout.sectionInset = UIEdgeInsets(top: 20, left: horizontalInset,
                                            bottom: 20, right: horizontalInset)
    }

    // ============================================================
    // MARK: - Import JAR from Files
    // ============================================================

    private func addAppTapped() {
        let jarType = UTType(filenameExtension: "jar") ?? .data
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [jarType])
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController,
                        didPickDocumentsAt urls: [URL]) {
        let fm = FileManager.default
        var imported = 0
        var blockedRunningJAR = false
        var blockedClonedJAR = false

        for url in urls {
            guard url.pathExtension.lowercased() == "jar" else { continue }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let destURL = URL(fileURLWithPath: Self.gamesDirectory)
                .appendingPathComponent(url.lastPathComponent)

            // Never overwrite the JAR that the still-running JVM owns.
            if hasNativeGame(for: destURL.path) {
                blockedRunningJAR = true
                continue
            }

            // The JAR bytes are shared by all tabs in this group.
            // Never silently replace a binary while its clone group exists.
            do {
                let clones = try JarBoxGameStorage.registeredClones(
                    jarPath: destURL.path, documents: Self.documentsDirectory)
                if !clones.isEmpty {
                    blockedClonedJAR = true
                    continue
                }
            } catch {
                blockedClonedJAR = true
                continue
            }

            // Stage first; a failed copy must not destroy the installed JAR.
            let pending = destURL.deletingLastPathComponent().appendingPathComponent(
                ".import-" + UUID().uuidString + ".jar")
            do {
                try fm.copyItem(at: url, to: pending)
                if fm.fileExists(atPath: destURL.path) {
                    _ = try fm.replaceItemAt(destURL, withItemAt: pending)
                } else {
                    try fm.moveItem(at: pending, to: destURL)
                }
                imported += 1
            } catch {
                try? fm.removeItem(at: pending)
                NSLog("[JarBoxStorage] JAR import failed: %@", error.localizedDescription)
            }
        }

        if imported > 0 {
            scanApps()
        }
        if blockedRunningJAR || blockedClonedJAR {
            let alert = UIAlertController(
                title: "Không thể thay JAR",
                message: blockedClonedJAR
                    ? "JAR này còn bản nhân đang tham chiếu. Hãy xóa các Tab nhân bản trước hoặc nhập bằng tên JAR khác."
                    : "Hãy dừng game trước khi thay thế JAR của phiên đó.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    // ============================================================
    // MARK: - App scanning (Documents/games/)
    // ============================================================

    struct AppInfo {
        let name: String
        let path: String
        let fileName: String
        let version: String?
        let vendor: String?
        let icon: UIImage
        let cloneCount: Int
    }
    private var apps: [AppInfo] = []

    // Tab mutations change only the registry count, not the JAR, icon or
    // manifest. Do not launch a whole-library JAR scan on the handoff path.
    private func updateRegisteredCloneCount(for path: String, count: Int) {
        guard let index = apps.firstIndex(where: { $0.path == path }) else { return }
        let app = apps[index]
        apps[index] = AppInfo(name: app.name, path: app.path, fileName: app.fileName,
                              version: app.version, vendor: app.vendor, icon: app.icon,
                              cloneCount: max(0, count))
        // The library is covered or offscreen during tab handoff.
        springboardCollectionView.reloadData()
    }

    private func scanApps() {
        let gamesDir = Self.gamesDirectory

        DispatchQueue.global(qos: .userInitiated).async {
            var jarPaths: [(name: String, path: String)] = []

            if let files = try? FileManager.default.contentsOfDirectory(atPath: gamesDir) {
                for file in files where file.hasSuffix(".jar") {
                    jarPaths.append((name: String(file.dropLast(4)), path: gamesDir + "/" + file))
                }
            }

            var unsorted = jarPaths.map { jar -> (String, String, String, String?, String?, UIImage?) in
                let meta = JARMetadata.read(from: jar.path)
                let jarIcon = meta?.readIcon(from: jar.path)
                let fileName = URL(fileURLWithPath: jar.path).lastPathComponent
                JarBoxGameStorage.migratePreferencesIfUnique(
                    for: jar.path, documents: Self.documentsDirectory)
                let defaultName = meta?.midletName ?? jar.name
                let key = "displayName_" + Self.gameId(forPath: jar.path)
                let savedName = UserDefaults.standard.string(forKey: key)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                // A display alias never changes the JAR filename, RMS path,
                // or per-game preferences. Safe to read while scanning.
                let appName = (savedName?.isEmpty == false) ? savedName! : defaultName
                return (appName, jar.path, fileName, meta?.version, meta?.vendor, jarIcon)
            }
            unsorted.sort { $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending }

            let scannedApps = unsorted.enumerated().map { (index, t) in
                AppInfo(name: t.0, path: t.1, fileName: t.2,
                        version: t.3, vendor: t.4,
                        icon: Self.springboardIcon(t.5, name: t.0, index: index),
                        cloneCount: (try? JarBoxGameStorage.registeredClones(
                            jarPath: t.1, documents: Self.documentsDirectory).count) ?? 0)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.apps = scannedApps
                self.springboardCollectionView.reloadData()
                self.emptyStateLabel.isHidden = !scannedApps.isEmpty
                print("[Swift] Found \(scannedApps.count) MIDlet JARs in \(gamesDir)")
            }
        }
    }

    // ============================================================
    // MARK: - Icon generation
    // ============================================================

    private static let iconSize: CGFloat = SpringboardCell.iconSize

    private static func springboardIcon(_ jarIcon: UIImage?, name: String, index: Int) -> UIImage {
        let size = CGSize(width: iconSize, height: iconSize)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let rect = CGRect(origin: .zero, size: size)

            UIBezierPath(roundedRect: rect, cornerRadius: SpringboardCell.iconCornerRadius).addClip()

            if let img = jarIcon {
                UIColor(white: 0.22, alpha: 1).setFill()
                UIBezierPath(rect: rect).fill()
                img.draw(in: rect)
            } else {
                // Missing-icon fallback: one muted gray fill, drawn only
                // when the library icon is prepared, not per frame.
                UIColor(white: 0.29, alpha: 1).setFill()
                ctx.fill(rect)
                let letter = String(name.prefix(1)).uppercased()
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: UIColor.white.withAlphaComponent(0.9),
                    .font: UIFont.systemFont(ofSize: iconSize * 0.42, weight: .semibold)
                ]
                let strSize = (letter as NSString).size(withAttributes: attrs)
                (letter as NSString).draw(
                    at: CGPoint(x: (iconSize - strSize.width) / 2,
                                y: (iconSize - strSize.height) / 2),
                    withAttributes: attrs)
            }

            let borderPath = UIBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                           cornerRadius: SpringboardCell.iconCornerRadius - 0.5)
            UIColor(white: 1.0, alpha: 0.12).setStroke()
            borderPath.lineWidth = 1
            borderPath.stroke()
        }
    }

    // ============================================================
    // MARK: - UICollectionView
    // ============================================================

    func collectionView(_ collectionView: UICollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        apps.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: SpringboardCell.reuseID, for: indexPath) as! SpringboardCell
        let app = apps[indexPath.item]
        // Clone count was resolved during the existing background JAR scan.
        // Cell reuse and scrolling do no filesystem I/O or timer polling.
        cell.configure(name: app.name, icon: app.icon,
                       tabCount: app.cloneCount + 1,
                       running: hasRunningGame(for: app.path))
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard pendingTabMutation == nil, let indexPath = indexPaths.first,
              apps.indices.contains(indexPath.item) else { return nil }
        let app = apps[indexPath.item]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            guard let self else { return nil }
            let clones: [JarBoxGameStorage.CloneRecord]
            let tabs: [(id: UUID?, title: String)]
            do {
                clones = try JarBoxGameStorage.registeredClones(
                    jarPath: app.path, documents: Self.documentsDirectory)
                tabs = self.displayTabs(clones)
            } catch {
                return UIMenu(children: [UIAction(title: "Không đọc được các tab",
                                                   attributes: .disabled) { _ in }])
            }
            let isRunning = self.hasNativeGame(for: app.path)
            let stop = self.stopMenu(for: app, tabs: tabs)
            let infoAction = UIAction(title: "Thông tin trò chơi",
                                      image: UIImage(systemName: "info.circle")) { [weak self] _ in
                if clones.isEmpty { self?.showGameInformation(app) }
                else { self?.showTabInformationPicker(for: app, clones: clones) }
            }
            let resolution = UIAction(title: "Độ phân giải",
                image: UIImage(systemName: "rectangle.expand.vertical")) { [weak self] _ in
                self?.showSharedResolutionOptions(for: app)
            }
            let fps = UIAction(title: "FPS", image: UIImage(systemName: "speedometer")) { [weak self] _ in
                self?.showSharedFPSOptions(for: app)
            }
            let quality3D = UIAction(title: "3D", image: UIImage(systemName: "cube")) { [weak self] _ in
                self?.showShared3DOptions(for: app)
            }
            // Group-wide Treo preference remains locked during any live tab.
            let compatible = JarBoxGameStorage.treoCompatibleOnly(for: app.path)
            let treoActions = [false, true].map { value in
                UIAction(title: value ? "Tương thích" : "Tự động",
                         attributes: isRunning ? .disabled : [],
                         state: value == compatible ? .on : .off) { [weak self] _ in
                    guard let self, !self.hasNativeGame(for: app.path) else { return }
                    JarBoxGameStorage.setTreoCompatibleOnly(value, for: app.path)
                }
            }
            let treoSettings = UIMenu(title: "Treo",
                image: UIImage(systemName: "moon.zzz"), children: treoActions)
            let cloneMenu = self.makeCloneMenu(for: app, cloneCount: clones.count)
            let delete = UIAction(title: "Xóa game", image: UIImage(systemName: "trash"),
                                  attributes: .destructive) { [weak self] _ in
                self?.confirmDeleteApp(for: app)
            }
            let advanced = UIMenu(title: "Nâng cao",
                                  image: UIImage(systemName: "slider.horizontal.3"),
                                  children: [cloneMenu, treoSettings, resolution, fps, quality3D])
            let rename = UIAction(title: "Đổi tên", image: UIImage(systemName: "pencil")) { [weak self] _ in
                self?.promptRenameApp(app)
            }
            return UIMenu(children: [stop, infoAction, advanced, rename,
                                     self.clearDataMenu(for: app, tabs: tabs), delete])
        })
    }

    // Read metadata and current counters only on demand from the long-press
    // "Thông tin" entry. Never start a timer for game badges or telemetry.
    private func showGameInformation(_ app: AppInfo, cloneID: UUID? = nil,
                                     tabName: String = "1 Gốc") {
        let resolution = Self.resolution(for: app)
        let fps = Self.fpsLimit(for: app)
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: app.path)[.size] as? NSNumber)?.int64Value
        let sizeText = fileBytes.map {
            String(format: "%.2f MB", Double($0) / 1_048_576)
        } ?? "Không đọc được"
        let activeGame = gameForTab(app.path, cloneID: cloneID)
        let active = activeGame != nil
        var lines: [String] = [
            "Tab: " + tabName,
            "Tệp JAR: " + app.fileName,
            "Dung lượng: " + sizeText,
            "Phiên bản: " + (app.version ?? "Không khai báo"),
            "Nhà phát triển: " + (app.vendor ?? "Không khai báo"),
            "Màn hình: " + String(resolution.w) + " × " + String(resolution.h),
            "Giới hạn FPS: " + (fps == 0 ? "Không giới hạn" : String(fps)),
            "Treo: " +
                (JarBoxGameStorage.treoCompatibleOnly(for: app.path) ? "Tương thích" : "Tự động"),
            "Trạng thái: " + (active ? "Đang chạy ẩn" : "Không chạy ẩn")
        ]
        // Filesystem metadata only: never inspect binary RMS contents.
        let rmsPath = (JarBoxGameStorage.rootPath(
            jarPath: app.path, documents: Self.documentsDirectory,
            cloneID: cloneID) as NSString)
            .appendingPathComponent("rms")
        if let files = try? FileManager.default.contentsOfDirectory(atPath: rmsPath) {
            let storeCount = files.filter { $0.hasSuffix(".rsh") }.count
            let recordCount = files.filter { $0.hasSuffix(".rsr") }.count
            lines.append("RMS: " + String(storeCount) + " kho, " +
                         String(recordCount) + " bản ghi trên đĩa")
        } else {
            lines.append("RMS: chưa có hoặc chưa chuyển dữ liệu cũ")
        }
        if let game = activeGame {
            lines.append("")
            lines.append(game.parkedSessionInformation())
        }
        let alert = UIAlertController(title: "Thông tin · " + app.name + " · " + tabName,
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Nhật ký save", style: .default) { [weak self] _ in
            self?.showSaveLog(for: app, cloneID: cloneID, tabName: tabName)
        })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        present(alert, animated: true)
    }

    /// On-demand metadata log stored under the same *install-specific* root.
    /// It contains no saved record bodies; the user can inspect or copy it.
    private func showSaveLog(for app: AppInfo, cloneID: UUID? = nil,
                             tabName: String = "1 Gốc") {
        let root = JarBoxGameStorage.rootPath(
            jarPath: app.path, documents: Self.documentsDirectory, cloneID: cloneID)
        // The JVM and Swift use different append files to avoid cross-thread
        // seek/write races. Both files belong only to this instance.
        let fm = FileManager.default
        var entries: [String] = []
        for file in ["rms-events.log", "settings-events.log"] {
            let path = (root as NSString).appendingPathComponent(file)
            guard let attr = try? fm.attributesOfItem(atPath: path),
                  let size = attr[.size] as? NSNumber,
                  size.intValue <= 128 * 1024,
                  let contents = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }
            for row in contents.split(separator: "\n", omittingEmptySubsequences: true) {
                entries.append(String(row))
            }
        }
        // Both sources start with Unix milliseconds. Nothing is polled
        // while a game is in Treo; this sorts only on user request.
        entries.sort {
            let left = Int64($0.split(separator: "\t").first ?? "") ?? 0
            let right = Int64($1.split(separator: "\t").first ?? "") ?? 0
            return left < right
        }
        var lines = entries.isEmpty
            ? "Chưa có nhật ký. Chỉ ghi thao tác RMS và cài đặt từ bản hỗ trợ."
            : entries.suffix(24).joined(separator: "\n")
        if entries.count > 24 {
            lines = "24 sự kiện gần nhất / " + String(entries.count) + " sự kiện\n\n" + lines
        }
        let alert = UIAlertController(title: "Save & cài đặt · " + app.name + " · " + tabName,
                                      message: lines, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sao chép", style: .default) { _ in
            UIPasteboard.general.string = lines
        })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Per-game settings

    private static func gameId(forPath path: String) -> String {
        JarBoxGameStorage.installId(for: path)
    }

    private static func gameId(for app: AppInfo) -> String {
        gameId(forPath: app.path)
    }

    private func promptRenameApp(_ app: AppInfo) {
        let alert = UIAlertController(title: "Đổi tên game",
                                      message: "Chỉ đổi tên hiển thị, không đổi JAR hoặc dữ liệu lưu.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = app.name
            field.placeholder = "Tên game"
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .words
        }
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Lưu", style: .default) { [weak self, weak alert] _ in
            guard let raw = alert?.textFields?.first?.text else { return }
            let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80 else {
                self?.showRenameError()
                return
            }
            UserDefaults.standard.set(name, forKey: "displayName_\(Self.gameId(for: app))")
            JarBoxGameStorage.appendSettingEvent(jarPath: app.path,
                documents: Self.documentsDirectory, event: "RENAME")
            self?.scanApps()
        })
        present(alert, animated: true)
    }

    private func showRenameError() {
        let alert = UIAlertController(title: "Tên không hợp lệ",
                                      message: "Tên phải dài từ 1 đến 80 ký tự.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    static func is3DSupersampling(for app: AppInfo) -> Bool {
        JarBoxGameStorage.shared3D(jarPath: app.path)
    }

    static func set3DSupersampling(_ enabled: Bool, for app: AppInfo) {
        JarBoxGameStorage.setShared3D(enabled, jarPath: app.path)
        JarBoxGameStorage.appendSettingEvent(jarPath: app.path,
            documents: documentsDirectory, event: "SUPERSAMPLING", value: enabled ? "1" : "0")
    }

    private static let resolutionOptions: [(label: String, w: Int, h: Int)] = [
        // Common J2ME resolutions (portrait / square only)
        ("101×80",   101,  80),
        ("128×128",  128, 128),
        ("128×160",  128, 160),
        ("132×176",  132, 176),
        ("160×128",  160, 128),
        ("176×208",  176, 208),
        ("176×220",  176, 220),
        ("208×208",  208, 208),
        ("220×220",  220, 220),
        ("240×266",  240, 266),
        ("240×320",  240, 320),
        ("240×400",  240, 400),
        ("320×480",  320, 480),
        ("352×416",  352, 416),
        ("360×640",  360, 640),
        ("480×800",  480, 800),
    ]

    static func resolution(for app: AppInfo) -> (w: Int, h: Int) {
        JarBoxGameStorage.sharedResolution(jarPath: app.path)
    }

    private static func setResolution(w: Int, h: Int, for app: AppInfo) {
        JarBoxGameStorage.setSharedResolution(w: w, h: h, jarPath: app.path)
        JarBoxGameStorage.appendSettingEvent(jarPath: app.path,
            documents: documentsDirectory, event: "RESOLUTION",
            value: String(w) + "x" + String(h))
    }

    private static let fpsLimitOptions: [(label: String, value: Int)] = [
        ("Unlimited", 0),
        ("15 FPS",   15),
        ("20 FPS",   20),
        ("30 FPS",   30),
        ("60 FPS",   60),
    ]

    static func fpsLimit(for app: AppInfo) -> Int {
        JarBoxGameStorage.sharedFPS(jarPath: app.path)
    }

    private static func setFpsLimit(_ fps: Int, for app: AppInfo) {
        JarBoxGameStorage.setSharedFPS(fps, jarPath: app.path)
        JarBoxGameStorage.appendSettingEvent(jarPath: app.path,
            documents: documentsDirectory, event: "FPS", value: String(fps))
    }

    private static var documentsDirectory: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
    }

    private func presentSaveOperationError(_ error: Error) {
        let alert = UIAlertController(title: "Không thể thay đổi dữ liệu lưu",
                                      message: error.localizedDescription,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đóng", style: .default))
        present(alert, animated: true)
    }

    // Main-actor admission and filesystem mutation are serialized. Include
    // stopping slots: a zero visible token does not imply an empty registry.
    private func mutationOwners(path: String, ids: [UUID?]) -> [(game: GameViewController, token: UInt64)] {
        retainedGames.compactMap { game in
            guard game.jarPath == path, ids.contains(game.cloneID),
                  let token = game.nativeSessionToken else { return nil }
            return (game, token)
        }
    }

    private func mutationError(_ text: String) -> NSError {
        NSError(domain: "JarBox.GameStorage", code: 19,
                userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func confirmTabMutation(app: AppInfo, tabs: [(id: UUID?, title: String)],
                                    title: String, message: String, action: String,
                                    restartAfter: Bool = false,
                                    operation: @escaping ([UInt64]) throws -> Void) {
        guard pendingTabMutation == nil, !tabs.isEmpty else { return }
        let ids = tabs.map { $0.id }
        let owners = mutationOwners(path: app.path, ids: ids)
        let warning = owners.isEmpty ? "" : (restartAfter
            ? "\n\nBạn muốn dừng, áp dụng cấu hình rồi mở lại các tab đang chạy của game này không? Game khác vẫn chạy."
            : "\n\nCó tab đang chạy hoặc đang dừng. Bạn muốn dừng các tab được chọn rồi " +
                action.lowercased() + " không? Các tab khác vẫn chạy.")
        let alert = UIAlertController(title: title, message: message + warning, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: owners.isEmpty || restartAfter ? action : "Dừng và " + action.lowercased(),
                                     style: .destructive) { [weak self] _ in
            guard let self, self.pendingTabMutation == nil else { return }
            do {
                let current = try self.registeredTabs(for: app)
                guard ids.allSatisfy({ id in current.contains { $0.id == id } }) else {
                    throw self.mutationError("Danh sách tab đã thay đổi. Hãy chọn lại.")
                }
                let now = self.mutationOwners(path: app.path, ids: ids)
                guard now.allSatisfy({ owner in owners.contains {
                    $0.game === owner.game && $0.token == owner.token
                } }) else { throw self.mutationError("Phiên game đã thay đổi. Hãy xác nhận lại.") }
                try JarBoxGameStorage.requireMutationSafety(
                    unrelatedTokens: self.retainedGames.compactMap { $0.nativeSessionToken })
                let restartIDs = restartAfter ? now.filter { $0.game.parkedSessionToken == $0.token }.map { $0.game.cloneID } : []
                let ticket = UUID()
                self.pendingTabMutation = ticket
                self.cancelAutoProtection()
                self.navigationItem.prompt = now.isEmpty ? "Đang xử lý…" : "Đang dừng tab…"
                self.springboardCollectionView.isUserInteractionEnabled = false
                self.importBarButton?.isEnabled = false
                self.jarBoxMenuButton?.isEnabled = false
                for owner in now {
                    if jvm_bridge_session_is_active_for_token(owner.token) == 0 { continue }
                    guard owner.game.requestStopForTabMutation(expectedToken: owner.token) ||
                          jvm_bridge_session_is_active_for_token(owner.token) == 0 else {
                        self.finishTabMutation(ticket)
                        throw self.mutationError("Không thể dừng phiên đã chọn. Chưa áp dụng thay đổi.")
                    }
                }
                self.waitForTabMutation(ticket, app: app, ids: ids,
                    tokens: now.map { $0.token }, restartIDs: restartIDs, operation: operation)
            } catch { self.presentSaveOperationError(error) }
        })
        present(alert, animated: true)
    }

    private func finishTabMutation(_ ticket: UUID) {
        guard pendingTabMutation == ticket else { return }
        pendingTabMutation = nil
        navigationItem.prompt = nil
        springboardCollectionView.isUserInteractionEnabled = true
        importBarButton?.isEnabled = true
        jarBoxMenuButton?.isEnabled = true
        armAutoProtection()
    }

    private func waitForTabMutation(_ ticket: UUID, app: AppInfo, ids: [UUID?],
                                    tokens: [UInt64], restartIDs: [UUID?] = [], operation: @escaping ([UInt64]) throws -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            defer { self.finishTabMutation(ticket) }
            do {
                while true {
                    guard self.pendingTabMutation == ticket else { return }
                    guard ProcessInfo.processInfo.systemUptime < deadline else {
                        throw self.mutationError("Chưa dừng được phiên trong 20 giây. Chưa áp dụng thay đổi.")
                    }
                    let retired = tokens.allSatisfy { jvm_bridge_session_is_active_for_token($0) == 0 }
                    if retired && self.presentedViewController == nil { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                guard self.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
                      self.pendingTabMutation == ticket, !self.gamePresentationInFlight,
                      self.jarBoxSleepCover == nil else {
                    throw self.mutationError("Thư viện không còn ở trạng thái an toàn. Chưa áp dụng thay đổi.")
                }
                let current = try self.registeredTabs(for: app)
                guard ids.allSatisfy({ id in current.contains { $0.id == id } }),
                      self.mutationOwners(path: app.path, ids: ids).isEmpty else {
                    throw self.mutationError("Tab hoặc phiên đã thay đổi. Chưa áp dụng thay đổi.")
                }
                // No suspension between the ownership proof and disk mutation.
                let unrelated = self.retainedGames.compactMap { $0.nativeSessionToken }
                try JarBoxGameStorage.requireMutationSafety(unrelatedTokens: unrelated)
                try operation(unrelated)
                self.scanApps()
                if !restartIDs.isEmpty {
                    self.navigationItem.prompt = "Đang khởi động lại…"
                    try await self.restartConfiguredTabs(ticket, app: app, ids: restartIDs)
                }
            } catch {
                self.scanApps()
                if self.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
                   self.presentedViewController == nil {
                    self.presentSaveOperationError(error)
                } else {
                    self.pendingMutationNotice = error.localizedDescription
                    NSLog("[JarBoxStorage] mutation cancelled: %@", error.localizedDescription)
                }
            }
        }
    }

    private func confirmClearGameData(for app: AppInfo, tabs: [(id: UUID?, title: String)]) {
        let names = tabs.map { $0.title }.joined(separator: ", ")
        confirmTabMutation(app: app, tabs: tabs, title: "Xóa dữ liệu",
            message: app.name + " · " + names + ". Không thể hoàn tác. Giữ nguyên JAR, tab và cài đặt.",
            action: "Xóa dữ liệu") { unrelated in
            for tab in tabs {
                _ = try JarBoxGameStorage.prepareRoot(jarPath: app.path,
                    documents: Self.documentsDirectory, cloneID: tab.id)
            }
            for tab in tabs {
                try JarBoxGameStorage.clearInstanceData(jarPath: app.path,
                    documents: Self.documentsDirectory, cloneID: tab.id,
                    unrelatedTokens: unrelated)
            }
        }
    }

    private func confirmDeleteApp(for app: AppInfo) {
        do {
            let clones = try JarBoxGameStorage.registeredClones(
                jarPath: app.path, documents: Self.documentsDirectory)
            guard clones.isEmpty else {
                throw mutationError("Hãy xóa các tab nhân bản trong mục Nhân bản trước khi xóa game gốc.")
            }
            confirmTabMutation(app: app, tabs: [(nil, "1 Gốc")], title: "Xóa game",
                message: "Xóa " + app.name + ", RMS và cài đặt riêng của JAR này?",
                action: "Xóa game") { unrelated in
                try JarBoxGameStorage.requireMutationSafety(unrelatedTokens: unrelated)
                let current = try JarBoxGameStorage.registeredClones(
                    jarPath: app.path, documents: Self.documentsDirectory)
                guard current.isEmpty else {
                    throw NSError(domain: "JarBox.GameStorage", code: 16,
                        userInfo: [NSLocalizedDescriptionKey: "Danh sách tab đã thay đổi."])
                }
                let root = try JarBoxGameStorage.prepareRoot(
                    jarPath: app.path, documents: Self.documentsDirectory)
                try FileManager.default.removeItem(atPath: root)
                try FileManager.default.removeItem(atPath: app.path)
                let gid = Self.gameId(for: app)
                UserDefaults.standard.removeObject(forKey: JarBoxGameStorage.treoPreferenceKey(for: app.path))
                JarBoxGameStorage.rememberLastTab(jarPath: app.path, cloneID: nil)
                for prefix in ["displayName_", "ss3d_", "resW_", "resH_", "fpsLimit_"] {
                    UserDefaults.standard.removeObject(forKey: prefix + gid)
                }
            }
        } catch { presentSaveOperationError(error) }
    }

    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {
        guard canPresentGame, apps.indices.contains(indexPath.item) else { return }
        let app = apps[indexPath.item]
        // Resume the minimized tab only if it is still live. Otherwise
        // prefer the first running tab in display order; if none, original.
        do {
            let tabs = try registeredTabs(for: app)
            let remembered = JarBoxGameStorage.lastTab(jarPath: app.path,
                                                       registered: tabs.compactMap { $0.id })
            let running = Set(tabs.filter {
                gameForTab(app.path, cloneID: $0.id)?.parkedSessionToken != nil
            }.map { $0.id })
            guard let index = JarBoxGameStorage.entryTabIndex(
                ordered: tabs.map { $0.id }, remembered: remembered, running: running) else { return }
            let target = tabs[index]
            let id = target.id
            launchGameTab(app, cloneID: id,
                          tabTitle: id == nil ? app.name : app.name + " · " + target.title)
        } catch {
            presentSaveOperationError(error)
        }
    }

    private func showTabInformationPicker(for app: AppInfo,
                                          clones: [JarBoxGameStorage.CloneRecord]) {
        let picker = UIAlertController(title: "Thông tin các tab · " + app.name,
                                       message: "Cài đặt và nhật ký riêng của mỗi tab.",
                                       preferredStyle: .actionSheet)
        for tab in displayTabs(clones) {
            picker.addAction(UIAlertAction(title: tab.title, style: .default) { [weak self] _ in
                self?.showGameInformation(app, cloneID: tab.id, tabName: tab.title)
            })
        }
        picker.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        if let popover = picker.popoverPresentationController {
            popover.sourceView = springboardCollectionView
            popover.sourceRect = CGRect(x: springboardCollectionView.bounds.midX,
                                        y: springboardCollectionView.bounds.midY,
                                        width: 1, height: 1)
        }
        present(picker, animated: true)
    }

    private func showShared3DOptions(for app: AppInfo) {
        let current = Self.is3DSupersampling(for: app)
        showSharedOptions(app: app, title: "3D", options: [
            ("Bình thường", !current, { Self.set3DSupersampling(false, for: app) }),
            ("Nâng chất lượng 3D", current, { Self.set3DSupersampling(true, for: app) })
        ])
    }

    private func showSharedResolutionOptions(for app: AppInfo) {
        let current = Self.resolution(for: app)
        showSharedOptions(app: app, title: "Độ phân giải", options: Self.resolutionOptions.map { option in
            (option.label, option.w == current.w && option.h == current.h,
             { Self.setResolution(w: option.w, h: option.h, for: app) })
        })
    }

    private func showSharedFPSOptions(for app: AppInfo) {
        let current = Self.fpsLimit(for: app)
        showSharedOptions(app: app, title: "FPS", options: Self.fpsLimitOptions.map { option in
            (option.label, option.value == current, { Self.setFpsLimit(option.value, for: app) })
        })
    }

    private func showSharedOptions(app: AppInfo, title: String,
                                   options: [(label: String, selected: Bool, apply: () -> Void)]) {
        guard pendingTabMutation == nil else { return }
        let picker = UIAlertController(title: title + " · " + app.name,
                                       message: "Áp dụng chung cho tất cả tab.",
                                       preferredStyle: .actionSheet)
        for option in options {
            picker.addAction(UIAlertAction(title: option.label + (option.selected ? " ✓" : ""),
                                           style: .default) { [weak self] _ in
                guard !option.selected else { return }
                self?.changeSharedGameSetting(app, title: title, apply: option.apply)
            })
        }
        picker.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        if let popover = picker.popoverPresentationController {
            popover.sourceView = springboardCollectionView
            popover.sourceRect = CGRect(x: springboardCollectionView.bounds.midX,
                                        y: springboardCollectionView.bounds.midY, width: 1, height: 1)
        }
        present(picker, animated: true)
    }

    private func changeSharedGameSetting(_ app: AppInfo, title: String, apply: @escaping () -> Void) {
        guard pendingTabMutation == nil, !gamePresentationInFlight else { return }
        do {
            let tabs = try registeredTabs(for: app)
            let owners = mutationOwners(path: app.path, ids: tabs.map { $0.id })
            try JarBoxGameStorage.requireMutationSafety(unrelatedTokens: retainedGames.compactMap { $0.nativeSessionToken })
            if owners.isEmpty {
                apply()
                scanApps()
                return
            }
            confirmTabMutation(app: app, tabs: tabs, title: title,
                message: "Cần khởi động lại các tab đang chạy để áp dụng thay đổi. Game sẽ mở lại từ đầu, không tự đăng nhập.",
                action: "Khởi động lại", restartAfter: true) { _ in apply() }
        } catch { presentSaveOperationError(error) }
    }

    // Reuse native admission and the ordinary Back/Treo transition.
    private func restartConfiguredTabs(_ ticket: UUID, app: AppInfo, ids: [UUID?]) async throws {
        let before = try registeredTabs(for: app)
        let selected = JarBoxGameStorage.lastTab(jarPath: app.path, registered: before.compactMap { $0.id })
        // Automatic parking is not a user navigation choice.
        defer { JarBoxGameStorage.rememberLastTab(jarPath: app.path, cloneID: selected) }
        for id in ids {
            guard pendingTabMutation == ticket, springboardVisible,
                  let scene = view.window?.windowScene, scene.activationState == .foregroundActive,
                  presentedViewController == nil else {
                throw mutationError("Đã lưu cấu hình; việc mở lại tab bị gián đoạn.")
            }
            let tabs = try registeredTabs(for: app)
            guard let target = tabs.first(where: { $0.id == id }) else {
                throw mutationError("Tab cần mở lại không còn tồn tại.")
            }
            let previous = Set(managedGames.map { ObjectIdentifier($0) })
            // Only this synchronous launch is allowed through the mutation gate.
            pendingTabMutation = nil
            launchGameTab(app, cloneID: id,
                          tabTitle: id == nil ? app.name : app.name + " · " + target.title)
            pendingTabMutation = ticket
            guard let game = managedGames.first(where: {
                !previous.contains(ObjectIdentifier($0)) && $0.jarPath == app.path && $0.cloneID == id
            }) else {
                throw mutationError("Đã lưu cấu hình nhưng không thể mở lại " + target.title + ".")
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 35
            while true {
                // The root and modal view may briefly have no window during
                // presentation. Track the same scene instead of treating that
                // transition as a trip into the background.
                guard pendingTabMutation == ticket, scene.activationState == .foregroundActive else {
                    throw mutationError("Đã lưu cấu hình; việc mở lại tab bị gián đoạn.")
                }
                if game.parkedSessionToken != nil, springboardVisible,
                   presentedViewController == nil, !gamePresentationInFlight { break }
                guard managedGames.contains(where: { $0 === game }),
                      ProcessInfo.processInfo.systemUptime < deadline else {
                    throw mutationError("Đã lưu cấu hình nhưng chưa mở lại hết tab. Kiểm tra game và mở các tab còn lại.")
                }
                if !gamePresentationInFlight { game.parkAfterSettingsRestart() }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }


    private func makeCloneMenu(for app: AppInfo, cloneCount: Int) -> UIMenu {
        let canAdd = JarBoxGameStorage.allowedAddCount(cloneCount: cloneCount) > 0
        let canRemove = cloneCount > 0
        let add = UIAction(title: "Thêm", attributes: canAdd ? [] : .disabled) { [weak self] _ in
            self?.addDefaultTabs(for: app, count: 1)
        }
        let remove = UIAction(title: "Xóa", attributes: canRemove ? .destructive : [.destructive, .disabled]) { [weak self] _ in
            self?.presentTabDeletion(for: app)
        }
        let addMany = UIAction(title: "Thêm theo số lượng", attributes: canAdd ? [] : .disabled) { [weak self] _ in
            self?.promptTabQuantity(for: app, removing: false)
        }
        let removeMany = UIAction(title: "Xóa theo số lượng",
            attributes: canRemove ? .destructive : [.destructive, .disabled]) { [weak self] _ in
            self?.promptTabQuantity(for: app, removing: true)
        }
        return UIMenu(title: "Nhân bản", image: UIImage(systemName: "plus.square.on.square"),
                      children: [add, remove, addMany, removeMany])
    }

    private func addDefaultTabs(for app: AppInfo, count: Int) {
        guard pendingTabMutation == nil else { return }
        do {
            let clones = try JarBoxGameStorage.createDefaultClones(
                jarPath: app.path, documents: Self.documentsDirectory, count: count)
            scanApps()
            let alert = UIAlertController(title: "Đã thêm " + String(clones.count) + " tab",
                message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        } catch {
            presentSaveOperationError(error)
        }
    }

    private func promptTabQuantity(for app: AppInfo, removing: Bool) {
        guard pendingTabMutation == nil else { return }
        do {
            let clones = try JarBoxGameStorage.registeredClones(
                jarPath: app.path, documents: Self.documentsDirectory)
            let maximum = removing ? clones.count :
                JarBoxGameStorage.allowedAddCount(cloneCount: clones.count)
            guard maximum > 0 else { throw JarBoxGameStorage.tabQuantityError(maximum: maximum) }
            let title = removing ? "Xóa theo số lượng" : "Thêm theo số lượng"
            let message = "Nhập số nguyên từ 1 đến " + String(maximum) +
                (removing ? ". Chọn các tab cuối danh sách, không xóa tab gốc." : ".")
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addTextField { field in
                field.keyboardType = .numberPad
                field.placeholder = "1–" + String(maximum)
            }
            alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
            alert.addAction(UIAlertAction(title: "Tiếp tục", style: .default) { [weak self, weak alert] _ in
                guard let self else { return }
                let input = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard let count = Int(input),
                      JarBoxGameStorage.validTabQuantity(count, maximum: maximum) else {
                    self.presentSaveOperationError(JarBoxGameStorage.tabQuantityError(maximum: maximum))
                    return
                }
                if removing {
                    do {
                        let current = try JarBoxGameStorage.registeredClones(
                            jarPath: app.path, documents: Self.documentsDirectory)
                        guard JarBoxGameStorage.validTabQuantity(count, maximum: current.count) else {
                            throw JarBoxGameStorage.tabQuantityError(maximum: current.count)
                        }
                        self.confirmDeleteTabs(app, clones: Array(current.suffix(count)))
                    } catch { self.presentSaveOperationError(error) }
                } else {
                    self.addDefaultTabs(for: app, count: count)
                }
            })
            present(alert, animated: true)
        } catch { presentSaveOperationError(error) }
    }

    private func presentTabDeletion(for app: AppInfo) {
        do {
            let clones = try JarBoxGameStorage.registeredClones(
                jarPath: app.path, documents: Self.documentsDirectory)
            guard !clones.isEmpty else { throw JarBoxGameStorage.tabQuantityError(maximum: 0) }
            if clones.count == 1 {
                confirmDeleteTabs(app, clones: clones)
                return
            }
            let picker = UIAlertController(title: "Xóa · " + app.name,
                message: "Chọn bản nhân cần xóa cùng dữ liệu và cài đặt.",
                preferredStyle: .actionSheet)
            let display = displayTabs(clones)
            for clone in clones {
                let title = display.first(where: { $0.id == clone.id })?.title ?? clone.label
                picker.addAction(UIAlertAction(title: "Xóa " + tabStatusTitle(title, path: app.path, cloneID: clone.id),
                    style: .destructive) { [weak self] _ in
                    self?.confirmDeleteTabs(app, clones: [clone])
                })
            }
            picker.addAction(UIAlertAction(title: "Hủy", style: .cancel))
            if let popover = picker.popoverPresentationController {
                popover.sourceView = springboardCollectionView
                popover.sourceRect = CGRect(x: springboardCollectionView.bounds.midX,
                                            y: springboardCollectionView.bounds.midY,
                                            width: 1, height: 1)
            }
            present(picker, animated: true)
        } catch { presentSaveOperationError(error) }
    }

    private func confirmDeleteTabs(_ app: AppInfo, clones: [JarBoxGameStorage.CloneRecord]) {
        guard !clones.isEmpty else { return }
        guard let registered = try? registeredTabs(for: app) else { return }
        let ids = Set(clones.map { $0.id })
        let tabs = registered.filter { tab in tab.id.map { ids.contains($0) } ?? false }
        guard tabs.count == clones.count else { return }
        let names = tabs.map { $0.title }.joined(separator: ", ")
        confirmTabMutation(app: app, tabs: tabs, title: "Xóa " + String(clones.count) + " tab?",
            message: names + "\n\nDữ liệu và cài đặt của các tab này sẽ bị xóa vĩnh viễn. Tab gốc được giữ nguyên.",
            action: "Xóa tab") { unrelated in
            try JarBoxGameStorage.removeClones(jarPath: app.path, documents: Self.documentsDirectory,
                                              cloneIDs: clones.map { $0.id }, unrelatedTokens: unrelated)
        }
    }

    private func launchGameTab(_ app: AppInfo, cloneID: UUID?, tabTitle: String) {
        let launchRequestedAt = ProcessInfo.processInfo.systemUptime
        guard canPresentGame else { return }
        // The same JAR may have several independent clone roots. Resume
        // exactly the selected instance; never start another worker for it.
        if let game = gameForTab(app.path, cloneID: cloneID) {
            game.resumeParkedGame()
            return
        }
        if parkedGameController != nil {
            // Legacy overlay is only a fallback for externally-created VCs.
            showAnotherGameBlocked(app)
            return
        }
        if retainedGames.contains(where: { $0.holdsNativeInstance(for: app.path, cloneID: cloneID) }) {
            let alert = UIAlertController(title: "Đang đóng phiên cũ",
                message: "Tab này vẫn đang khởi động hoặc dừng; không thể dùng chung dữ liệu.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let count = jvm_bridge_active_session_count()
        if count > 0 && app.path.withCString({ jvm_bridge_3d_conflict_for_jar($0) }) != 0 {
            let alert = UIAlertController(title: "Chưa hỗ trợ chạy song song game 3D",
                message: "Game 3D hoặc game chưa xác định phải chạy riêng. Hãy giữ icon các game đang chạy và chọn Dừng trước khi mở game khác.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, animated: true)
            return
        }
        if count >= jvm_bridge_supported_concurrent_sessions() {
            if liveGames.isEmpty {
                updateStuckSessionButton()
                openStuckSessionRecovery()
            } else {
                showAnotherGameBlocked(app)
            }
            return
        }

        if let reason = memoryLaunchDenial() {
            let alert = UIAlertController(title: "Không đủ RAM", message: reason, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel))
            present(alert, animated: true)
            return
        }

        // The startup worker validates the exact save root before native init.
        // Do not repeat that filesystem work on the UI thread.

        let render3dScale = Self.is3DSupersampling(for: app) ? 3 : 1
        let res = Self.resolution(for: app)
        let fps = Self.fpsLimit(for: app)
        let gameVC = GameViewController(jarPath: app.path, appName: tabTitle,
            appIcon: app.icon, canvasWidth: res.w, canvasHeight: res.h,
            render3dScale: render3dScale, fpsLimit: fps, cloneID: cloneID)
        gameVC.modalPresentationStyle = .fullScreen
        gameVC.sessionLibrary = self
        gameVC.startupRequestedAt = launchRequestedAt
        managedGames.append(gameVC)
        presentGame(gameVC, reason: "game launching")
    }
}
