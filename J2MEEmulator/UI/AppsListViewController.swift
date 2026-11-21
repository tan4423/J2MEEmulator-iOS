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
    nonisolated static func exactFileName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
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

    /// The original keeps its current save directory for backward compatibility.
    /// Every clone gets a sibling directory, never a child of the original:
    /// deleting the original must never delete another instance's RMS.
    nonisolated static func rootPath(jarPath: String, documents: String,
                                     cloneID: UUID? = nil) -> String {
        let group = installId(for: jarPath)
        let suffix = cloneID.map { "-clone-" + $0.uuidString.lowercased() } ?? ""
        return (documents as NSString).appendingPathComponent("Games Data/inst-" + group + suffix)
    }

    nonisolated static func settingsId(jarPath: String, cloneID: UUID? = nil) -> String {
        let group = installId(for: jarPath)
        return cloneID.map { group + "_clone_" + $0.uuidString.lowercased() } ?? group
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

    private static let cloneRegistryLock = NSLock()

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
        cloneRegistryLock.lock()
        defer { cloneRegistryLock.unlock() }
        let title = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty && title.count <= 80 else {
            throw NSError(domain: "JarBox.GameStorage", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Tên tab mới không hợp lệ."])
        }
        guard FileManager.default.fileExists(atPath: jarPath) else {
            throw NSError(domain: "JarBox.GameStorage", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Không tìm thấy file JAR nguồn."])
        }
        var group = try readCloneGroup(jarPath: jarPath, documents: documents)
        guard group.clones.count < 16 else {
            throw NSError(domain: "JarBox.GameStorage", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Tối đa 16 bản nhân cho một JAR."])
        }
        let record = CloneRecord(id: UUID(), label: title, createdAt: Date())
        let target = rootPath(jarPath: jarPath, documents: documents, cloneID: record.id)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target) else {
            throw NSError(domain: "JarBox.GameStorage", code: 8,
                userInfo: [NSLocalizedDescriptionKey: "Thư mục tab mới đã tồn tại."])
        }
        let base = (documents as NSString).appendingPathComponent("Games Data")
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        // Empty private root: the MIDlet will create its own RMS defaults.
        // Do not copy the original's save, settings, account or log.
        try fm.createDirectory(atPath: target, withIntermediateDirectories: false)
        do {
            group.clones.append(record)
            try writeCloneGroup(group, jarPath: jarPath, documents: documents)
        } catch {
            try? fm.removeItem(atPath: target)
            throw error
        }
        return record
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
        cloneRegistryLock.lock()
        defer { cloneRegistryLock.unlock() }
        guard jvm_bridge_active_session_count() == 0 else {
            throw NSError(domain: "JarBox.GameStorage", code: 13,
                userInfo: [NSLocalizedDescriptionKey: "Dừng game trước khi xóa tab."])
        }
        var group = try readCloneGroup(jarPath: jarPath, documents: documents)
        guard group.clones.contains(where: { $0.id == cloneID }) else {
            throw NSError(domain: "JarBox.GameStorage", code: 14,
                userInfo: [NSLocalizedDescriptionKey: "Tab nhân bản không tồn tại."])
        }
        let target = rootPath(jarPath: jarPath, documents: documents, cloneID: cloneID)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: target, isDirectory: &isDirectory),
              isDirectory.boolValue, !isSymbolicLink(target) else {
            throw NSError(domain: "JarBox.GameStorage", code: 15,
                userInfo: [NSLocalizedDescriptionKey: "Thư mục tab không an toàn hoặc đã mất."])
        }
        // Rename to a private tombstone before changing the registry.
        // On a registry failure we can restore the save untouched.
        let tomb = target + ".deleting-" + UUID().uuidString
        try fm.moveItem(atPath: target, toPath: tomb)
        let originalGroup = group
        group.clones.removeAll(where: { $0.id == cloneID })
        do {
            try writeCloneGroup(group, jarPath: jarPath, documents: documents)
        } catch {
            try? fm.moveItem(atPath: tomb, toPath: target)
            throw error
        }
        do {
            try fm.removeItem(atPath: tomb)
        } catch {
            // The user must not see a successful deletion when save bytes
            // were not actually removed.
            try? fm.moveItem(atPath: tomb, toPath: target)
            try? writeCloneGroup(originalGroup, jarPath: jarPath, documents: documents)
            throw error
        }
        let defaults = UserDefaults.standard
        let instance = settingsId(jarPath: jarPath, cloneID: cloneID)
        for prefix in ["displayName_", "ss3d_", "resW_", "resH_", "fpsLimit_"] {
            defaults.removeObject(forKey: prefix + instance)
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

class AppsListViewController: UIViewController,
                      UICollectionViewDataSource,
                      UICollectionViewDelegate,
                      UIDocumentPickerDelegate {

    private var springboardCollectionView: UICollectionView!
    private let emptyStateLabel = UILabel()
    private var lastLayoutWidth: CGFloat = 0
    private weak var animatedBackground: AnimatedBackgroundView?
    private var springboardVisible = false
    private var importBarButton: UIBarButtonItem?
    private var jarBoxMenuButton: UIBarButtonItem?
    // CPU sampling is event-based, process-wide; never attribute it to one game.
    private var libraryCPUEntry: (time: TimeInterval, cpu: Double)?
    // JarBox-wide black sleep cover. Only its 15-second HUD timer performs
    // periodic work, and only while the cover is visible in the foreground.
    private var jarBoxSleepCover: UIView?
    private weak var jarBoxSleepHUD: UILabel?
    private var jarBoxSleepTimer: Timer?
    private var jarBoxSleepCPUSample: (time: TimeInterval, cpu: Double)?
    private var jarBoxSleepCPUText = "CPU tổng: đang đo"
    private var jarBoxSleepBatteryWasEnabled: Bool?
    private var jarBoxSleepStartedAt: TimeInterval?

    // Set only for a library presented over its *own* live GameViewController.
    // A weak reference plus the native session token prevents stale UI controls
    // from treating a subsequent game as this session.
    weak var parkedGameController: GameViewController?

    // Keep lifecycle diagnostics but do not restart any decorative work.
    func sceneActivityChanged(_ active: Bool) {
        guard springboardVisible else { return }
        setSpringboardMotion(active, reason: active ? "scene active" : "scene inactive")
        setJarBoxSleepSampling(active)
    }

    private func setSpringboardMotion(_ enabled: Bool, reason: String) {
        animatedBackground?.setAnimationsActive(enabled, reason: reason)
    }

    /// Directory where imported JARs are stored
    private static var gamesDirectory: String {
        documentsDirectory + "/games"
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

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
            menu: UIMenu(title: "JarBox", children: [
                UIAction(title: "Màn hình Treo",
                         image: UIImage(systemName: "moon.zzz")) { [weak self] _ in
                    self?.showJarBoxSleepScreen()
                },
                UIAction(title: "Thông tin chung",
                         image: UIImage(systemName: "info.circle")) { [weak self] _ in
                    self?.showJarBoxOverview()
                }
            ]))
        globalMenu.accessibilityLabel = "Menu tổng JarBox"
        jarBoxMenuButton = globalMenu
        navigationItem.rightBarButtonItems = [importButton, globalMenu]

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
        libraryCPUEntry = (ProcessInfo.processInfo.systemUptime, treo_process_cpu_seconds())
        let sceneActive = view.window?.windowScene?.activationState == .foregroundActive
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
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        springboardVisible = false
        hideJarBoxSleepScreen()
        libraryCPUEntry = nil
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
    }

    // Event-driven recovery for sessions stranded by an unexpected UI exit.
    // No timer, animation or background polling on the low-power library.
    private func updateStuckSessionButton() {
        if let parked = parkedGameController {
            if parked.ownsLiveGameSession() {
                navigationItem.title = "Đang chạy ẩn: " + parked.appName
                navigationItem.leftBarButtonItem = UIBarButtonItem(
                    title: "Tiếp tục", style: .plain,
                    target: self, action: #selector(resumeParkedGame))
                let stop = UIBarButtonItem(
                    title: "Dừng", style: .plain,
                    target: self, action: #selector(stopRunningGameFromLibrary))
                stop.tintColor = .systemRed
                navigationItem.rightBarButtonItems = [importBarButton, stop, jarBoxMenuButton].compactMap { $0 }
                return
            }
            navigationItem.rightBarButtonItems = [importBarButton, jarBoxMenuButton].compactMap { $0 }
            if jvm_bridge_session_is_active() != 0 {
                navigationItem.title = "Đang dừng game..."
                navigationItem.leftBarButtonItem = UIBarButtonItem(
                    title: "Xử lý phiên kẹt", style: .plain,
                    target: self, action: #selector(openStuckSessionRecovery))
                return
            }
            navigationItem.title = "Thư viện"
            navigationItem.leftBarButtonItem = nil
            return
        }
        if jvm_bridge_session_is_active() != 0 {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "Dừng phiên kẹt", style: .plain,
                target: self, action: #selector(openStuckSessionRecovery))
        } else {
            navigationItem.leftBarButtonItem = nil
        }
    }

    @objc private func resumeParkedGame() {
        parkedGameController?.resumeParkedGame()
    }

    @objc private func stopRunningGameFromLibrary() {
        parkedGameController?.stopParkedGame()
        updateStuckSessionButton()
    }

    private func showAnotherGameBlocked(_ app: AppInfo) {
        guard let parked = parkedGameController, parked.ownsLiveGameSession() else { return }
        let alert = UIAlertController(
            title: "Đang có game chạy ẩn",
            message: parked.appName + " vẫn đang chạy. MiniJVM hiện chỉ có " +
                "một phiên trong tiến trình, nên không thể mở " + app.name +
                " đồng thời mà không làm hỏng dữ liệu JVM. " +
                "Bạn có thể quay lại game cũ hoặc dừng nó trước khi mở game mới.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Tiếp tục game cũ", style: .default) { [weak self] _ in
            self?.resumeParkedGame()
        })
        alert.addAction(UIAlertAction(title: "Dừng game đang chạy", style: .destructive) { [weak self] _ in
            self?.parkedGameController?.stopParkedGame()
            self?.updateStuckSessionButton()
        })
        alert.addAction(UIAlertAction(title: "Ở lại thư viện", style: .cancel))
        present(alert, animated: true)
    }

    @objc private func openStuckSessionRecovery() {
        guard jvm_bridge_session_is_active() != 0 else {
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
        // Event-based refresh avoids extra sampling while the cover is hidden.
        if jarBoxSleepCover != nil { refreshJarBoxSleepHUD() }
    }

    // Global screen cover, independent from a parked game's native Treo.
    // The native JVM is already in mode 8 from Back -> library. Opening
    // this display must not reset it, change game clocks or create a JVM.
    private func showJarBoxSleepScreen() {
        guard springboardVisible, jarBoxSleepCover == nil,
              presentedViewController == nil else { return }
        let container = navigationController?.view ?? view!
        let cover = UIView()
        cover.backgroundColor = .black
        cover.isOpaque = true
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.accessibilityIdentifier = "jarbox-global-sleep-screen"
        container.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: container.topAnchor),
            cover.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        let title = UILabel()
        title.text = "JarBox · Màn hình Treo\nChạm nút giữa để trở lại thư viện"
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = UIColor(white: 0.64, alpha: 1)
        title.textAlignment = .center
        title.numberOfLines = 2
        title.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(title)

        let wake = UIButton(type: .system)
        wake.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        wake.tintColor = UIColor(white: 0.92, alpha: 1)
        wake.backgroundColor = UIColor(white: 0.20, alpha: 1)
        wake.layer.cornerRadius = 36
        wake.layer.borderColor = UIColor(white: 0.43, alpha: 1).cgColor
        wake.layer.borderWidth = 1
        wake.accessibilityLabel = "Thoát màn hình Treo JarBox"
        wake.accessibilityIdentifier = "jarbox-global-sleep-wake"
        wake.translatesAutoresizingMaskIntoConstraints = false
        wake.addTarget(self, action: #selector(hideJarBoxSleepScreen), for: .touchUpInside)
        cover.addSubview(wake)

        let info = UILabel()
        info.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        info.textColor = UIColor(white: 0.70, alpha: 1)
        info.numberOfLines = 0
        info.textAlignment = .center
        info.adjustsFontSizeToFitWidth = true
        info.minimumScaleFactor = 0.85
        info.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(info)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            title.bottomAnchor.constraint(equalTo: wake.topAnchor, constant: -38),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: cover.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: cover.trailingAnchor, constant: -16),
            wake.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            wake.centerYAnchor.constraint(equalTo: cover.centerYAnchor, constant: -24),
            wake.widthAnchor.constraint(equalToConstant: 72),
            wake.heightAnchor.constraint(equalToConstant: 72),
            info.topAnchor.constraint(equalTo: wake.bottomAnchor, constant: 26),
            info.leadingAnchor.constraint(equalTo: cover.leadingAnchor, constant: 16),
            info.trailingAnchor.constraint(equalTo: cover.trailingAnchor, constant: -16),
            info.bottomAnchor.constraint(lessThanOrEqualTo: cover.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        // Overlay intercepts all stray taps; only the wake control closes it.
        container.bringSubviewToFront(cover)
        jarBoxSleepCover = cover
        jarBoxSleepHUD = info
        jarBoxSleepStartedAt = ProcessInfo.processInfo.systemUptime
        jarBoxSleepCPUText = "CPU tổng: đang đo"
        let device = UIDevice.current
        jarBoxSleepBatteryWasEnabled = device.isBatteryMonitoringEnabled
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        setSpringboardMotion(false, reason: "JarBox sleep screen")
        setJarBoxSleepSampling(view.window?.windowScene?.activationState == .foregroundActive)
        refreshJarBoxSleepHUD()
    }

    @objc private func hideJarBoxSleepScreen() {
        guard let cover = jarBoxSleepCover else { return }
        jarBoxSleepTimer?.invalidate()
        jarBoxSleepTimer = nil
        jarBoxSleepCPUSample = nil
        jarBoxSleepStartedAt = nil
        jarBoxSleepHUD = nil
        if let old = jarBoxSleepBatteryWasEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = old
            jarBoxSleepBatteryWasEnabled = nil
        }
        jarBoxSleepCover = nil
        cover.removeFromSuperview()
        let active = view.window?.windowScene?.activationState == .foregroundActive
        setSpringboardMotion(springboardVisible && active, reason: "JarBox sleep screen closed")
    }

    @objc private func jarBoxWillResignActive() {
        setJarBoxSleepSampling(false)
    }

    private func setJarBoxSleepSampling(_ active: Bool) {
        guard jarBoxSleepCover != nil else { return }
        jarBoxSleepTimer?.invalidate()
        jarBoxSleepTimer = nil
        jarBoxSleepCPUSample = nil
        guard active, springboardVisible else { return }
        jarBoxSleepCPUSample = (ProcessInfo.processInfo.systemUptime,
                               treo_process_cpu_seconds())
        refreshJarBoxSleepHUD()
        let timer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshJarBoxSleepHUD()
            }
        }
        timer.tolerance = 3.0
        jarBoxSleepTimer = timer
    }

    private func refreshJarBoxSleepHUD() {
        guard jarBoxSleepCover != nil, let label = jarBoxSleepHUD else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let cpuNow = treo_process_cpu_seconds()
        if let prev = jarBoxSleepCPUSample, prev.cpu >= 0, cpuNow >= prev.cpu,
           now > prev.time {
            jarBoxSleepCPUText = String(format: "CPU tổng JarBox: %.1f%%",
                                        100 * (cpuNow - prev.cpu) / (now - prev.time))
        }
        if jarBoxSleepTimer != nil {
            jarBoxSleepCPUSample = (now, cpuNow)
        }

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
        let active = jvm_bridge_session_is_active() != 0
        let runningText: String
        if let parked = parkedGameController, parked.ownsLiveGameSession() {
            runningText = parked.appName + " · Treo tự động"
        } else if active {
            runningText = "Phiên JVM đang khởi động/dừng"
        } else {
            runningText = "Không có game đang chạy"
        }
        let elapsed = max(0, now - (jarBoxSleepStartedAt ?? now))
        let lines = [
            jarBoxSleepCPUText,
            "Pin: " + battery,
            "Áp lực nhiệt: " + thermal,
            "Chế độ pin yếu: " + (ProcessInfo.processInfo.isLowPowerModeEnabled ? "Bật" : "Tắt"),
            "Tab đang chạy: " + String(jvm_bridge_active_session_count()) +
                "/" + String(jvm_bridge_supported_concurrent_sessions()),
            runningText,
            String(format: "Thời gian phủ: %.0f giây", elapsed),
            "CPU là tổng tiến trình, không phải CPU của riêng game.",
            "Nhiệt là mức iOS, không phải nhiệt độ °C."
        ]
        let updated = lines.joined(separator: "\n")
        if label.text != updated { label.text = updated }
    }

    // General JarBox information is intentionally separated from game metadata.
    // iOS exposes thermal *pressure*, not an exact chip temperature in °C.
    // Read only when the user requests it; no background HUD or sampling timer.
    private func showJarBoxOverview() {
        let info = ProcessInfo.processInfo
        let thermal: String
        switch info.thermalState {
        case .nominal: thermal = "Bình thường"
        case .fair: thermal = "Tăng nhẹ"
        case .serious: thermal = "Cao"
        case .critical: thermal = "Rất cao"
        @unknown default: thermal = "Không xác định"
        }
        let device = UIDevice.current
        let previousBatteryMonitoring = device.isBatteryMonitoringEnabled
        if !previousBatteryMonitoring { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        if !previousBatteryMonitoring { device.isBatteryMonitoringEnabled = false }
        let battery = level >= 0
            ? String(format: "%.0f%%", Double(level) * 100)
            : "iOS chưa cung cấp"

        let phase = jvm_bridge_session_phase()
        let phaseLabel: String
        switch phase {
        case 0: phaseLabel = "Không có phiên JVM"
        case 1: phaseLabel = "Đang khởi động"
        case 2: phaseLabel = "Đang chạy"
        case 3: phaseLabel = "Đang dừng"
        default: phaseLabel = "Không xác định"
        }
        let activeCount = jvm_bridge_active_session_count()
        var cpuText = "Chưa có khoảng đo hợp lệ"
        if let entry = libraryCPUEntry {
            let elapsed = ProcessInfo.processInfo.systemUptime - entry.time
            let end = treo_process_cpu_seconds()
            if elapsed >= 1, entry.cpu >= 0, end >= entry.cpu {
                cpuText = String(format: "%.1f%% (TB %.0f giây)", 100 * (end - entry.cpu) / elapsed, elapsed)
            }
        }
        let lines = [
            "CPU toàn JarBox: " + cpuText,
            "Áp lực nhiệt iOS: " + thermal,
            "Pin: " + battery,
            "Tiết kiệm pin iOS: " + (info.isLowPowerModeEnabled ? "Bật" : "Tắt"),
            "Phiên JVM trong tiến trình: " + String(activeCount) +
                "/" + String(jvm_bridge_supported_concurrent_sessions()),
            "Trạng thái JVM: " + phaseLabel,
            "CPU là của toàn JarBox, không phải riêng game.",
            "Nhiệt là mức áp lực hệ thống, không phải số °C.",
            "Thông số được cập nhật khi mở mục này."
        ]
        let alert = UIAlertController(title: "Thông tin chung · JarBox",
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đóng", style: .default))
        present(alert, animated: true)
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
            if parkedGameController?.ownsLiveGameSession(for: destURL.path) == true {
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
        let groupTitle = app.cloneCount == 0 ? app.name :
            app.name + " · " + String(app.cloneCount + 1) + " tab"
        cell.configure(name: groupTitle, icon: app.icon,
                       running: parkedGameController?.ownsLiveGameSession(for: app.path) == true)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first else { return nil }
        let app = apps[indexPath.item]
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            let isRunning = self?.parkedGameController?.ownsLiveGameSession(for: app.path) == true
            let infoAction = UIAction(title: "Thông tin trò chơi",
                                      image: UIImage(systemName: "info.circle")) { [weak self] _ in
                self?.showGameInformation(app)
            }
            let saveLogAction = UIAction(title: "Nhật ký save & cài đặt",
                                         image: UIImage(systemName: "doc.text")) { [weak self] _ in
                self?.showSaveLog(for: app)
            }
            let addTab = UIAction(title: "+ Tab · dữ liệu mặc định",
                                  image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                self?.addDefaultTab(for: app)
            }
            let removeTab = UIAction(title: "− Tab · xóa dữ liệu riêng",
                                     image: UIImage(systemName: "minus.square"),
                                     attributes: .destructive) { [weak self] _ in
                self?.presentTabDeletion(for: app)
            }
            var sessionActions: [UIMenuElement] = []
            if isRunning {
                sessionActions = [
                    UIAction(title: "Tiếp tục game", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                        self?.resumeParkedGame()
                    },
                    UIAction(title: "Dừng game hoàn toàn", image: UIImage(systemName: "stop.fill"),
                             attributes: .destructive) { [weak self] _ in
                        self?.parkedGameController?.stopParkedGame()
                        self?.updateStuckSessionButton()
                    }
                ]
            }
            let ssEnabled = Self.is3DSupersampling(for: app)
            let toggle3D = UIAction(title: ssEnabled ? "Disable 3D Enhancement" : "Enable 3D Enhancement",
                                    subtitle: ssEnabled ? "Lower quality, but closer to original" : "Smoother 3D, but not original-accurate",
                                    image: UIImage(systemName: "cube"),
                                    state: ssEnabled ? .on : .off) { _ in
                Self.set3DSupersampling(!ssEnabled, for: app)
            }
            let rename = UIAction(title: "Đổi tên",
                                  image: UIImage(systemName: "pencil")) { _ in
                self?.promptRenameApp(app)
            }
            let clearData = UIAction(title: "Clear Game Data",
                                     image: UIImage(systemName: "eraser"),
                                     attributes: isRunning ? .disabled : []) { _ in
                self?.confirmClearGameData(for: app)
            }
            let delete = UIAction(title: "Delete", image: UIImage(systemName: "trash"),
                                  attributes: isRunning ? [.destructive, .disabled] : .destructive) { _ in
                self?.confirmDeleteApp(at: indexPath)
            }
            let currentRes = Self.resolution(for: app)
            let resActions = Self.resolutionOptions.map { opt in
                UIAction(title: opt.label,
                         state: (opt.w == currentRes.w && opt.h == currentRes.h) ? .on : .off) { _ in
                    Self.setResolution(w: opt.w, h: opt.h, for: app)
                }
            }
            let resMenu = UIMenu(title: "Screen Resolution",
                                  image: UIImage(systemName: "aspectratio"),
                                  children: resActions)

            let currentFps = Self.fpsLimit(for: app)
            let fpsActions = Self.fpsLimitOptions.map { opt in
                UIAction(title: opt.label,
                         state: opt.value == currentFps ? .on : .off) { _ in
                    Self.setFpsLimit(opt.value, for: app)
                }
            }
            let fpsMenu = UIMenu(title: "FPS Limit",
                                  subtitle: "High FPS may break some games",
                                  image: UIImage(systemName: "gauge.with.needle"),
                                  children: fpsActions)

            let advanced = UIMenu(title: "Nâng cao",
                                  image: UIImage(systemName: "slider.horizontal.3"),
                                  children: [toggle3D, fpsMenu])
            let settings = UIMenu(options: .displayInline, children: [resMenu, advanced])
            let actions = UIMenu(options: .displayInline, children: [rename, clearData, delete])
            let tabActions = UIMenu(title: "Các tab · cùng JAR, save độc lập",
                                    image: UIImage(systemName: "square.on.square"),
                                    children: [addTab, removeTab])
            let information = UIMenu(options: .displayInline, children: [infoAction, saveLogAction])
            return UIMenu(children: sessionActions + [tabActions, information, settings, actions])
        })
    }

    // Read metadata and current counters only on demand from the long-press
    // "Thông tin" entry. Never start a timer for game badges or telemetry.
    private func showGameInformation(_ app: AppInfo, cloneID: UUID? = nil,
                                     tabName: String = "Tab gốc") {
        let resolution = Self.resolution(for: app, cloneID: cloneID)
        let fps = Self.fpsLimit(for: app, cloneID: cloneID)
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: app.path)[.size] as? NSNumber)?.int64Value
        let sizeText = fileBytes.map {
            String(format: "%.2f MB", Double($0) / 1_048_576)
        } ?? "Không đọc được"
        let active = parkedGameController?.ownsLiveInstance(
            for: app.path, cloneID: cloneID) == true
        var lines: [String] = [
            "Tab: " + tabName,
            "Tệp JAR: " + app.fileName,
            "Dung lượng: " + sizeText,
            "Phiên bản: " + (app.version ?? "Không khai báo"),
            "Nhà phát triển: " + (app.vendor ?? "Không khai báo"),
            "Màn hình: " + String(resolution.w) + " × " + String(resolution.h),
            "Giới hạn FPS: " + (fps == 0 ? "Không giới hạn" : String(fps)),
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
        if active, let game = parkedGameController {
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
                             tabName: String = "Tab gốc") {
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

    static func is3DSupersampling(for app: AppInfo, cloneID: UUID? = nil) -> Bool {
        UserDefaults.standard.object(forKey: "ss3d_" + JarBoxGameStorage.settingsId(
            jarPath: app.path, cloneID: cloneID)) as? Bool ?? false
    }

    static func set3DSupersampling(_ enabled: Bool, for app: AppInfo,
                                   cloneID: UUID? = nil) {
        UserDefaults.standard.set(enabled, forKey: "ss3d_" +
            JarBoxGameStorage.settingsId(jarPath: app.path, cloneID: cloneID))
        JarBoxGameStorage.appendSettingEvent(jarPath: app.path,
            documents: documentsDirectory, event: "SUPERSAMPLING",
            value: enabled ? "1" : "0", cloneID: cloneID)
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

    static func resolution(for app: AppInfo, cloneID: UUID? = nil) -> (w: Int, h: Int) {
        let gid = JarBoxGameStorage.settingsId(jarPath: app.path, cloneID: cloneID)
        let w = UserDefaults.standard.object(forKey: "resW_\(gid)") as? Int ?? 240
        let h = UserDefaults.standard.object(forKey: "resH_\(gid)") as? Int ?? 320
        return (w, h)
    }

    private static func setResolution(w: Int, h: Int, for app: AppInfo,
                                      cloneID: UUID? = nil) {
        let gid = JarBoxGameStorage.settingsId(jarPath: app.path, cloneID: cloneID)
        UserDefaults.standard.set(w, forKey: "resW_\(gid)")
        UserDefaults.standard.set(h, forKey: "resH_\(gid)")
        JarBoxGameStorage.appendSettingEvent(jarPath: app.path,
            documents: documentsDirectory, event: "RESOLUTION",
            value: String(w) + "x" + String(h), cloneID: cloneID)
    }

    private static let fpsLimitOptions: [(label: String, value: Int)] = [
        ("Unlimited", 0),
        ("15 FPS",   15),
        ("20 FPS",   20),
        ("30 FPS",   30),
        ("60 FPS",   60),
    ]

    static func fpsLimit(for app: AppInfo, cloneID: UUID? = nil) -> Int {
        UserDefaults.standard.object(forKey: "fpsLimit_" +
            JarBoxGameStorage.settingsId(jarPath: app.path, cloneID: cloneID)) as? Int ?? 0
    }

    private static func setFpsLimit(_ fps: Int, for app: AppInfo,
                                    cloneID: UUID? = nil) {
        UserDefaults.standard.set(fps, forKey: "fpsLimit_" +
            JarBoxGameStorage.settingsId(jarPath: app.path, cloneID: cloneID))
        JarBoxGameStorage.appendSettingEvent(jarPath: app.path,
            documents: documentsDirectory, event: "FPS", value: String(fps),
            cloneID: cloneID)
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

    private func confirmClearGameData(for app: AppInfo) {
        let alert = UIAlertController(title: "Xóa save game",
                                      message: "Xóa toàn bộ dữ liệu RMS của \(app.name)? Không thể hoàn tác.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Xóa save", style: .destructive) { [weak self] _ in
            guard let self else { return }
            // No active Java thread may race with an external RMS deletion.
            guard jvm_bridge_session_is_active() == 0 else {
                self.presentSaveOperationError(NSError(domain: "JarBox.GameStorage", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Hãy dừng các phiên JVM trước khi xóa save."]))
                return
            }
            do {
                let root = try JarBoxGameStorage.prepareRoot(
                    jarPath: app.path, documents: Self.documentsDirectory)
                try FileManager.default.removeItem(atPath: root)
            } catch {
                self.presentSaveOperationError(error)
            }
        })
        present(alert, animated: true)
    }

    private func confirmDeleteApp(at indexPath: IndexPath) {
        let app = apps[indexPath.item]
        let alert = UIAlertController(title: "Xóa game",
                                      message: "Xóa \(app.name), RMS và cài đặt riêng của JAR này?",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Xóa game", style: .destructive) { [weak self] _ in
            guard let self else { return }
            guard jvm_bridge_session_is_active() == 0 else {
                self.presentSaveOperationError(NSError(domain: "JarBox.GameStorage", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Hãy dừng các phiên JVM trước khi xóa JAR."]))
                return
            }
            do {
                let clones = try JarBoxGameStorage.registeredClones(
                    jarPath: app.path, documents: Self.documentsDirectory)
                guard clones.isEmpty else {
                    throw NSError(domain: "JarBox.GameStorage", code: 16,
                        userInfo: [NSLocalizedDescriptionKey:
                            "Hãy xóa các Tab nhân bản bằng − Tab trước khi xóa JAR gốc."])
                }
                let root = try JarBoxGameStorage.prepareRoot(
                    jarPath: app.path, documents: Self.documentsDirectory)
                // Keep JAR intact if RMS cleanup fails; never silently orphan
                // live data behind a success-looking delete animation.
                try FileManager.default.removeItem(atPath: root)
                try FileManager.default.removeItem(atPath: app.path)
            } catch {
                self.presentSaveOperationError(error)
                return
            }
            let gid = Self.gameId(for: app)
            for prefix in ["displayName_", "ss3d_", "resW_", "resH_", "fpsLimit_"] {
                UserDefaults.standard.removeObject(forKey: prefix + gid)
            }
            self.springboardCollectionView.performBatchUpdates {
                self.apps.remove(at: indexPath.item)
                self.springboardCollectionView.deleteItems(at: [indexPath])
            }
            self.emptyStateLabel.isHidden = !self.apps.isEmpty
        })
        present(alert, animated: true)
    }

    func collectionView(_ collectionView: UICollectionView,
                        didSelectItemAt indexPath: IndexPath) {
        let app = apps[indexPath.item]
        do {
            let clones = try JarBoxGameStorage.registeredClones(
                jarPath: app.path, documents: Self.documentsDirectory)
            if clones.isEmpty {
                launchGameTab(app, cloneID: nil, tabTitle: app.name)
            } else {
                showTabChooser(for: app, clones: clones)
            }
        } catch {
            presentSaveOperationError(error)
        }
    }

    /// A group tile expands into independent windows/tabs. No clone is
    /// started until tapped; each gets a separately resolved save root.
    private func showTabChooser(for app: AppInfo,
                                clones: [JarBoxGameStorage.CloneRecord]) {
        let menu = UIAlertController(title: app.name + " · " + String(clones.count + 1) + " tab",
                                     message: "Chọn tab cần mở. Các tab dùng chung JAR, không chung dữ liệu.",
                                     preferredStyle: .actionSheet)
        menu.addAction(UIAlertAction(title: "Tab gốc", style: .default) { [weak self] _ in
            self?.launchGameTab(app, cloneID: nil, tabTitle: app.name)
        })
        for clone in clones {
            menu.addAction(UIAlertAction(title: clone.label, style: .default) { [weak self] _ in
                self?.launchGameTab(app, cloneID: clone.id, tabTitle: app.name + " · " + clone.label)
            })
        }
        menu.addAction(UIAlertAction(title: "+ Tab", style: .default) { [weak self] _ in
            self?.addDefaultTab(for: app)
        })
        menu.addAction(UIAlertAction(title: "− Tab", style: .destructive) { [weak self] _ in
            self?.presentTabDeletion(for: app)
        })
        menu.addAction(UIAlertAction(title: "ⓘ Thông tin các tab", style: .default) { [weak self] _ in
            self?.showTabInformationPicker(for: app, clones: clones)
        })
        menu.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        if let popover = menu.popoverPresentationController {
            popover.sourceView = springboardCollectionView
            popover.sourceRect = CGRect(x: springboardCollectionView.bounds.midX,
                                        y: springboardCollectionView.bounds.midY,
                                        width: 1, height: 1)
        }
        present(menu, animated: true)
    }

    private func showTabInformationPicker(for app: AppInfo,
                                          clones: [JarBoxGameStorage.CloneRecord]) {
        let picker = UIAlertController(title: "Thông tin các tab · " + app.name,
                                       message: "Cài đặt và nhật ký riêng của mỗi tab.",
                                       preferredStyle: .actionSheet)
        picker.addAction(UIAlertAction(title: "Tab gốc", style: .default) { [weak self] _ in
            self?.showGameInformation(app)
        })
        for clone in clones {
            picker.addAction(UIAlertAction(title: clone.label, style: .default) { [weak self] _ in
                self?.showGameInformation(app, cloneID: clone.id, tabName: clone.label)
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

    private func addDefaultTab(for app: AppInfo) {
        do {
            let entries = try JarBoxGameStorage.registeredClones(
                jarPath: app.path, documents: Self.documentsDirectory)
            let used = Set(entries.map { $0.label })
            var n = 1
            while used.contains("Tab " + String(n)) { n += 1 }
            let clone = try JarBoxGameStorage.createDefaultClone(
                jarPath: app.path, documents: Self.documentsDirectory,
                label: "Tab " + String(n))
            scanApps()
            let alert = UIAlertController(
                title: "Đã tạo " + clone.label,
                message: "Tab mới dùng chung file JAR nhưng bắt đầu với RMS và cài đặt mặc định, không sao chép save gốc.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        } catch {
            presentSaveOperationError(error)
        }
    }

    private func presentTabDeletion(for app: AppInfo) {
        do {
            let clones = try JarBoxGameStorage.registeredClones(
                jarPath: app.path, documents: Self.documentsDirectory)
            guard !clones.isEmpty else {
                let alert = UIAlertController(title: "Chưa có tab nhân bản",
                    message: "Tab gốc không thể xóa bằng − Tab.",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
                return
            }
            let picker = UIAlertController(title: "− Tab · " + app.name,
                message: "Chọn bản nhân cần xóa cùng RMS, cài đặt và log của bản đó.",
                preferredStyle: .actionSheet)
            for clone in clones {
                picker.addAction(UIAlertAction(title: "Xóa " + clone.label,
                    style: .destructive) { [weak self] _ in
                    self?.confirmDeleteTab(app, clone: clone)
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
        } catch {
            presentSaveOperationError(error)
        }
    }

    private func confirmDeleteTab(_ app: AppInfo, clone: JarBoxGameStorage.CloneRecord) {
        let alert = UIAlertController(title: "Xóa " + clone.label + "?",
            message: "Toàn bộ RMS, save, nhật ký và cài đặt riêng của tab sẽ bị xóa vĩnh viễn. Tab gốc và các bản nhân khác không bị ảnh hưởng.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "− Xóa Tab", style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try JarBoxGameStorage.removeClone(
                    jarPath: app.path, documents: Self.documentsDirectory,
                    cloneID: clone.id)
                self.scanApps()
            } catch {
                self.presentSaveOperationError(error)
            }
        })
        present(alert, animated: true)
    }

    private func launchGameTab(_ app: AppInfo, cloneID: UUID?, tabTitle: String) {
        // The library may overlay an existing JVM. Never treat the same JAR
        // file as the same running *tab* unless the instance UUID also matches.
        if let parked = parkedGameController {
            if parked.ownsLiveGameSession() {
                if parked.ownsLiveInstance(for: app.path, cloneID: cloneID) {
                    resumeParkedGame()
                } else {
                    showAnotherGameBlocked(app)
                }
            } else if jvm_bridge_session_is_active() != 0 {
                updateStuckSessionButton()
                openStuckSessionRecovery()
            } else {
                let alert = UIAlertController(title: "Đang đóng phiên cũ",
                    message: "Hãy chờ JarBox quay về thư viện chính trước khi mở tab tiếp theo.",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
            return
        }
        if jvm_bridge_session_is_active() != 0 {
            updateStuckSessionButton()
            openStuckSessionRecovery()
            return
        }

        // No clone may launch without a registered, existing private root.
        do {
            if cloneID != nil {
                _ = try JarBoxGameStorage.prepareRoot(
                    jarPath: app.path, documents: Self.documentsDirectory, cloneID: cloneID)
            }
        } catch {
            presentSaveOperationError(error)
            return
        }

        let render3dScale = Self.is3DSupersampling(for: app, cloneID: cloneID) ? 3 : 1
        let res = Self.resolution(for: app, cloneID: cloneID)
        let fps = Self.fpsLimit(for: app, cloneID: cloneID)
        let gameVC = GameViewController(jarPath: app.path, appName: tabTitle,
            appIcon: app.icon, canvasWidth: res.w, canvasHeight: res.h,
            render3dScale: render3dScale, fpsLimit: fps, cloneID: cloneID)
        gameVC.modalPresentationStyle = .fullScreen
        setSpringboardMotion(false, reason: "game launching")
        present(gameVC, animated: false)
    }
}
