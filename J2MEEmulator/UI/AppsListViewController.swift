//
//  AppsListViewController.swift
//  J2MEEmulator
//
//  Springboard-style home screen with app grid.
//

import UIKit
import UniformTypeIdentifiers
import Darwin

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

    // Set only for a library presented over its *own* live GameViewController.
    // A weak reference plus the native session token prevents stale UI controls
    // from treating a subsequent game as this session.
    weak var parkedGameController: GameViewController?

    // Keep lifecycle diagnostics but do not restart any decorative work.
    func sceneActivityChanged(_ active: Bool) {
        guard springboardVisible else { return }
        setSpringboardMotion(active, reason: active ? "scene active" : "scene inactive")
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add, primaryAction: UIAction { [weak self] _ in
                self?.addAppTapped()
            })

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
        setSpringboardMotion(sceneActive, reason: sceneActive
                             ? "springboard visible and scene active"
                             : "springboard visible, waiting for active scene")
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(springboardThermalChanged),
                                               name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        logSpringboardEnergyState("library appeared")
        updateStuckSessionButton()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        springboardVisible = false
        setSpringboardMotion(false, reason: "springboard disappearing")
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    @objc private func appDidBecomeActive() {
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
                return
            }
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
            return UIMenu(children: sessionActions + [settings, actions])
        })
    }

    // MARK: - Per-game settings

    private static func gameId(forPath path: String) -> String {
        let jarName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return jarName.replacingOccurrences(of: "[^a-zA-Z0-9._-]", with: "_", options: .regularExpression)
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
    }

    private static var documentsDirectory: String {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.path
    }

    private func confirmClearGameData(for app: AppInfo) {
        let alert = UIAlertController(title: "Clear Game Data",
                                       message: "Delete all save data for \(app.name)?",
                                       preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { _ in
            let gid = Self.gameId(for: app)
            try? FileManager.default.removeItem(atPath: Self.documentsDirectory + "/Games Data/" + gid)
        })
        present(alert, animated: true)
    }

    private func confirmDeleteApp(at indexPath: IndexPath) {
        let app = apps[indexPath.item]
        let alert = UIAlertController(title: "Delete Game",
                                       message: "Delete \(app.name) and all its save data?",
                                       preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self else { return }
            let gid = Self.gameId(for: app)
            try? FileManager.default.removeItem(atPath: Self.documentsDirectory + "/Games Data/" + gid)
            try? FileManager.default.removeItem(atPath: app.path)
            UserDefaults.standard.removeObject(forKey: "displayName_\(gid)")
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
        if let parked = parkedGameController, parked.ownsLiveGameSession() {
            if parked.jarPath == app.path {
                resumeParkedGame()
            } else {
                showAnotherGameBlocked(app)
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
