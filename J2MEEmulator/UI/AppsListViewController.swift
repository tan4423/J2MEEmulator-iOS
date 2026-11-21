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
    static func exactFileName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func installId(for path: String) -> String {
        let name = exactFileName(for: path)
        let digest = SHA256.hash(data: Data(name.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func legacyId(for path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_",
                                  options: .regularExpression)
    }

    static func rootPath(jarPath: String, documents: String) -> String {
        (documents as NSString).appendingPathComponent("Games Data/inst-" + installId(for: jarPath))
    }

    private static func isSymbolicLink(_ path: String) -> Bool {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink ?? false
    }

    private static func legacyOwners(jarPath: String, documents: String) -> [String] {
        let directory = (documents as NSString).appendingPathComponent("games")
        let slug = legacyId(for: jarPath)
        let filenames = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return filenames.filter {
            $0.lowercased().hasSuffix(".jar") &&
            legacyId(for: (directory as NSString).appendingPathComponent($0)) == slug
        }
    }

    /// Never combine two colliding legacy saves or launch against the wrong
    /// legacy directory. A same-filesystem move preserves RMS bytes intact.
    /// Failure leaves the original untouched and stops launch, not a blank save.
    static func prepareRoot(jarPath: String, documents: String) throws -> String {
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
    static func migratePreferencesIfUnique(for path: String, documents: String) {
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
    static func appendSettingEvent(jarPath: String, documents: String,
                                   event: String, value: String = "") {
        let safeEvent = event.filter { $0.isASCII && ($0.isLetter || $0 == "_") }
        guard !safeEvent.isEmpty else { return }
        do {
            let root = try prepareRoot(jarPath: jarPath, documents: documents)
            let logPath = (root as NSString).appendingPathComponent("save-events.log")
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

            // If file with same name exists, remove it (overwrite)
            try? fm.removeItem(at: destURL)

            do {
                try fm.copyItem(at: url, to: destURL)
                imported += 1
            } catch {
                print("[Swift] Failed to import \(url.lastPathComponent): \(error)")
            }
        }

        if imported > 0 {
            scanApps()
        }
        if blockedRunningJAR {
            let alert = UIAlertController(
                title: "Game đang chạy",
                message: "Hãy dừng game trước khi thay thế JAR của phiên đó.",
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
                        icon: Self.springboardIcon(t.5, name: t.0, index: index))
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
        cell.configure(name: app.name, icon: app.icon,
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
            let information = UIMenu(options: .displayInline, children: [infoAction, saveLogAction])
            return UIMenu(children: sessionActions + [information, settings, actions])
        })
    }

    // Read metadata and current counters only on demand from the long-press
    // "Thông tin" entry. Never start a timer for game badges or telemetry.
    private func showGameInformation(_ app: AppInfo) {
        let resolution = Self.resolution(for: app)
        let fps = Self.fpsLimit(for: app)
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: app.path)[.size] as? NSNumber)?.int64Value
        let sizeText = fileBytes.map {
            String(format: "%.2f MB", Double($0) / 1_048_576)
        } ?? "Không đọc được"
        let active = parkedGameController?.ownsLiveGameSession(for: app.path) == true
        var lines: [String] = [
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
            jarPath: app.path, documents: Self.documentsDirectory) as NSString)
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
        let alert = UIAlertController(title: "Thông tin · " + app.name,
                                      message: lines.joined(separator: "\n"),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đóng", style: .default))
        present(alert, animated: true)
    }

    /// On-demand metadata log stored under the same *install-specific* root.
    /// It contains no saved record bodies; the user can inspect or copy it.
    private func showSaveLog(for app: AppInfo) {
        let log = (JarBoxGameStorage.rootPath(
            jarPath: app.path, documents: Self.documentsDirectory) as NSString)
            .appendingPathComponent("save-events.log")
        let fm = FileManager.default
        var lines = "Chưa có nhật ký. Nhật ký chỉ ghi các thao tác RMS và cài đặt kể từ phiên bản hỗ trợ."
        if let attr = try? fm.attributesOfItem(atPath: log),
           let size = attr[.size] as? NSNumber,
           size.intValue <= 128 * 1024,
           let contents = try? String(contentsOfFile: log, encoding: .utf8) {
            let entries = contents.split(separator: "\n", omittingEmptySubsequences: true)
            lines = entries.isEmpty
                ? "Chưa có thao tác nào."
                : entries.suffix(24).joined(separator: "\n")
            if entries.count > 24 {
                lines = "24 sự kiện gần nhất / " + String(entries.count) + " sự kiện\n\n" + lines
            }
        }
        let alert = UIAlertController(title: "Save & cài đặt · " + app.name,
                                      message: lines,
                                      preferredStyle: .alert)
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
        UserDefaults.standard.object(forKey: "ss3d_\(gameId(for: app))") as? Bool ?? false
    }

    static func set3DSupersampling(_ enabled: Bool, for app: AppInfo) {
        UserDefaults.standard.set(enabled, forKey: "ss3d_\(gameId(for: app))")
        JarBoxGameStorage.appendSettingEvent(jarPath: app.path,
            documents: documentsDirectory, event: "SUPERSAMPLING",
            value: enabled ? "1" : "0")
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
        let gid = gameId(for: app)
        let w = UserDefaults.standard.object(forKey: "resW_\(gid)") as? Int ?? 240
        let h = UserDefaults.standard.object(forKey: "resH_\(gid)") as? Int ?? 320
        return (w, h)
    }

    private static func setResolution(w: Int, h: Int, for app: AppInfo) {
        let gid = gameId(for: app)
        UserDefaults.standard.set(w, forKey: "resW_\(gid)")
        UserDefaults.standard.set(h, forKey: "resH_\(gid)")
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
        UserDefaults.standard.object(forKey: "fpsLimit_\(gameId(for: app))") as? Int ?? 0
    }

    private static func setFpsLimit(_ fps: Int, for app: AppInfo) {
        UserDefaults.standard.set(fps, forKey: "fpsLimit_\(gameId(for: app))")
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
        // Never launch a second view hierarchy from the *parked* overlay,
        // even in the brief gap after the native slot becomes idle but before
        // the old owner finishes its UIKit teardown.
        if let parked = parkedGameController {
            if parked.ownsLiveGameSession() {
                if parked.jarPath == app.path {
                    resumeParkedGame()
                } else {
                    showAnotherGameBlocked(app)
                }
            } else if jvm_bridge_session_is_active() != 0 {
                updateStuckSessionButton()
                openStuckSessionRecovery()
            } else {
                let alert = UIAlertController(
                    title: "Đang đóng phiên cũ",
                    message: "Hãy chờ JarBox quay lại thư viện chính trước khi mở game tiếp theo.",
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

        let render3dScale = Self.is3DSupersampling(for: app) ? 3 : 1
        let res = Self.resolution(for: app)
        let fps = Self.fpsLimit(for: app)
        let gameVC = GameViewController(jarPath: app.path, appName: app.name, appIcon: app.icon,
                                         canvasWidth: res.w, canvasHeight: res.h,
                                         render3dScale: render3dScale, fpsLimit: fps)
        gameVC.modalPresentationStyle = .fullScreen

        // Pause as soon as the user opens a game, without waiting for the
        // fullscreen presentation's view-controller lifecycle callback.
        setSpringboardMotion(false, reason: "game launching")
        // Do not couple the game's orientation change to the springboard zoom animation.
        present(gameVC, animated: false)
    }
}
