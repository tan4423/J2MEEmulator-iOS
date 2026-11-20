//
//  GameViewController.swift
//  J2MEEmulator
//
//  Runs a single J2ME MIDlet. Presented modally with zoom transition.
//  Layout mode determines the arrangement of screen and controls.
//

import UIKit
import CoreFoundation

// MARK: - Layout mode (extensible for future layouts)

enum GameLayoutMode {
    case portrait
    case ngage      // Landscape: D-pad left, screen center, numpad right
    // Future: .classic   — Portrait: screen top, keyboard bottom
    // Future: .fullscreen — Landscape: screen fills, overlay controls
}

// Passive UIKit phase observer, active only inside a measured audit leg.
@MainActor private final class JarCommitBudget {
    struct Result {
        let pairs: Int
        let dropped: Int
        let cpu: Double
        let wall: Double

        var pairsPerSecond: Double { Double(pairs) / wall }
        var millisecondsPerPair: Double { cpu * 1000 / Double(max(1, pairs)) }
        var millisecondsPerSecond: Double { cpu * 1000 / wall }

        var detail: String {
            guard pairs > 0 else {
                return "Mốc commit UIKit: không có cặp hợp lệ (\(dropped) lỗi ghép/đồng hồ)."
            }
            return String(format: "Mốc commit UIKit: %.2f cặp/s · %.3f ms CPU/cặp · %.1f ms CPU/s",
                          pairsPerSecond, millisecondsPerPair, millisecondsPerSecond)
                + " · \(pairs) cặp · \(dropped) lỗi ghép/đồng hồ"
        }
    }

    private var disable: (() -> Void)?
    private var pending: (modelTime: Double, cpu: Double)?
    private var pairs = 0
    private var dropped = 0
    private var cpu = 0.0

    @available(iOS 18.0, *)
    func start(in view: UIView) {
        let link = UIUpdateLink(view: view)
        // Keep UIKit's default passive mode. On iOS 18.6.2, writing
        // requiresContinuousUpdates before registering actions can trap even for false.
        link.addAction(to: .beforeCATransactionCommit) { [weak self] _, info in
            let now = treo_afk_current_thread_cpu()
            guard let self else { return }
            if self.pending != nil { self.dropped += 1 }
            if now >= 0 {
                self.pending = (info.modelTime, now)
            } else {
                self.pending = nil
                self.dropped += 1
            }
        }
        link.addAction(to: .afterCATransactionCommit) { [weak self] _, info in
            let now = treo_afk_current_thread_cpu()
            guard let self else { return }
            let start = self.pending
            self.pending = nil
            guard let start, start.modelTime == info.modelTime, now >= start.cpu else {
                self.dropped += 1
                return
            }
            self.pairs += 1
            self.cpu += now - start.cpu
        }
        disable = { link.isEnabled = false }
        link.isEnabled = true
    }

    func finish(wall: Double) -> Result {
        let result = Result(pairs: pairs, dropped: dropped + (pending == nil ? 0 : 1), cpu: cpu, wall: wall)
        stop()
        return result
    }

    func stop() {
        disable?()
        disable = nil
        pending = nil
    }
}

// Passive iOS 18 UIKit update phase probe. On this iPhone,
// afterUpdateComplete was not observed, so a cycle ends at CA commit.
// These values are
// main-thread CPU between public UIKit phase boundaries, NOT individual
// framework/function attribution. It never requests continuous updates.
@MainActor private final class JarUIKitPhaseBudget {
    static let labels = [
        "Scheduled→Event", "Event dispatch", "Event→DisplayLink",
        "DisplayLink callbacks", "DisplayLink→CA", "CA commit"
    ]

    @MainActor struct Result {
        let cpuSeconds: [Double]
        let pairs: [Int]
        let completedCycles: Int
        let dropped: Int
        let wall: Double

        var valid: Bool {
            completedCycles >= 10 && dropped <= max(10, completedCycles / 10)
                && pairs.allSatisfy { $0 >= 10 }
        }
        var cpuMSPerSecond: [Double] { cpuSeconds.map { $0 * 1000 / max(0.001, wall) } }
        var cyclesPerSecond: Double { Double(completedCycles) / max(0.001, wall) }
        var detail: String {
            let data = cpuMSPerSecond
            var lines = [String(format: "Các pha UIKit: %.2f chu kỳ/s · %d chu kỳ đủ · %d mốc mất/khác nhịp · %@",
                                cyclesPerSecond, completedCycles, dropped, valid ? "hợp lệ" : "KHÔNG ĐỦ MỐC")]
            for i in 0..<JarUIKitPhaseBudget.labels.count {
                lines.append(String(format: "%@: %.1f ms CPU/s [%d cặp]",
                                    JarUIKitPhaseBudget.labels[i], data[i], pairs[i]))
            }
            lines.append(String(format: "Tổng CPU trong các khoảng UIKit đo được: %.1f ms/s (KHÔNG cộng vào các pha runloop).",
                                data.reduce(0, +)))
            return lines.joined(separator: "\n")
        }
    }

    private var link: UIUpdateLink?
    private var last: (index: Int, modelTime: Double, cpu: Double)?
    private var cpu = Array(repeating: 0.0, count: JarUIKitPhaseBudget.labels.count)
    private var counts = Array(repeating: 0, count: JarUIKitPhaseBudget.labels.count)
    private var cycles = 0
    private var dropped = 0

    @available(iOS 18.0, *)
    func start(in view: UIView) {
        stop()
        cpu = Array(repeating: 0.0, count: Self.labels.count)
        counts = Array(repeating: 0, count: Self.labels.count)
        cycles = 0
        dropped = 0

        let probe = UIUpdateLink(view: view)
        let boundaries: [UIUpdateActionPhase] = [
            .afterUpdateScheduled, .beforeEventDispatch, .afterEventDispatch,
            .beforeCADisplayLinkDispatch, .afterCADisplayLinkDispatch,
            .beforeCATransactionCommit, .afterCATransactionCommit
        ]
        for (index, boundary) in boundaries.enumerated() {
            probe.addAction(to: boundary) { [weak self] _, info in
                self?.record(index: index, modelTime: info.modelTime)
            }
        }
        // Never touch requiresContinuousUpdates: it previously caused SIGTRAP
        // on iOS 18.6.2 when accessed before phase actions were registered.
        link = probe
        probe.isEnabled = true
    }

    private func record(index: Int, modelTime: Double) {
        let time = treo_afk_current_thread_cpu()
        guard time >= 0 else { dropped += 1; last = nil; return }
        if index == 0 {
            if last != nil { dropped += 1 }
            last = (index, modelTime, time)
            return
        }
        guard let previous = last, previous.index + 1 == index,
              previous.modelTime == modelTime, time >= previous.cpu else {
            dropped += 1
            last = nil
            return
        }
        cpu[index - 1] += time - previous.cpu
        counts[index - 1] += 1
        if index == Self.labels.count {
            cycles += 1
            last = nil
        } else {
            last = (index, modelTime, time)
        }
    }

    func finish(wall: Double) -> Result {
        let result = Result(cpuSeconds: cpu, pairs: counts, completedCycles: cycles,
                            dropped: dropped + (last == nil ? 0 : 1), wall: wall)
        stop()
        return result
    }
    func stop() {
        link?.isEnabled = false
        link = nil
        last = nil
    }
}

// Partition the main thread's CPU clock between run-loop markers.
// These are time windows, not attribution to an individual observer or framework.
@MainActor private enum JarMainBudget {
    enum Group: Int, CaseIterable {
        case beforeTimers, beforeSources, waitingObservers, poll, wakeObservers, afterWake, other
        var label: String {
            switch self {
            case .beforeTimers: return "Timer→Source"
            case .beforeSources: return "Sau mốc Source"
            case .waitingObservers: return "Observer trước ngủ"
            case .poll: return "Giữa ngủ/thức"
            case .wakeObservers: return "Observer sau thức"
            case .afterWake: return "Sau observer thức"
            case .other: return "Mốc khác"
            }
        }
    }
    private enum Marker: Equatable {
        case entry, exit, timers, sources, beforeWaitFirst, beforeWaitLast, afterWaitFirst, afterWaitLast
    }
    private static var observers: [CFRunLoopObserver] = []
    private static var last: (marker: Marker, cpu: Double)?
    private static var cpu = Array(repeating: 0.0, count: Group.allCases.count)
    private static var counts = Array(repeating: 0, count: Group.allCases.count)
    private static var failed = false
    private static var sampleSource = false

    static func start(sampleSource: Bool) {
        stop()
        cpu = Array(repeating: 0, count: Group.allCases.count)
        counts = Array(repeating: 0, count: Group.allCases.count)
        failed = false
        self.sampleSource = sampleSource
        if sampleSource { treo_afk_main_source_mark(0) }
        let early = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
            | CFRunLoopActivity.beforeTimers.rawValue | CFRunLoopActivity.beforeSources.rawValue
            | CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        let late = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        guard let first = CFRunLoopObserverCreateWithHandler(nil, early, true, Int.min, { _, activity in
            MainActor.assumeIsolated { record(activity, late: false) }
        }), let final = CFRunLoopObserverCreateWithHandler(nil, late, true, Int.max, { _, activity in
            MainActor.assumeIsolated { record(activity, late: true) }
        }) else {
            failed = true
            return
        }
        observers = [first, final]
        for observer in observers {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, CFRunLoopMode.commonModes)
        }
    }

    static func stop() {
        if sampleSource { treo_afk_main_source_mark(0) }
        sampleSource = false
        for observer in observers { CFRunLoopObserverInvalidate(observer) }
        observers.removeAll()
        last = nil
    }

    private static func record(_ activity: CFRunLoopActivity, late: Bool) {
        let marker: Marker
        switch activity {
        case .entry: marker = .entry
        case .exit: marker = .exit
        case .beforeTimers: marker = .timers
        case .beforeSources: marker = .sources
        case .beforeWaiting: marker = late ? .beforeWaitLast : .beforeWaitFirst
        case .afterWaiting: marker = late ? .afterWaitLast : .afterWaitFirst
        default: return
        }
        if sampleSource { treo_afk_main_source_mark(marker == .sources ? 1 : 0) }
        let now = treo_afk_current_thread_cpu()
        guard now >= 0 else { failed = true; last = nil; return }
        if let prev = last {
            guard now >= prev.cpu else { failed = true; last = nil; return }
            let group: Group
            switch (prev.marker, marker) {
            case (.beforeWaitFirst, .beforeWaitLast): group = .waitingObservers
            case (.afterWaitFirst, .afterWaitLast): group = .wakeObservers
            case (.beforeWaitLast, .afterWaitFirst): group = .poll
            case (.timers, .sources): group = .beforeTimers
            case (.sources, .beforeWaitFirst), (.sources, .timers): group = .beforeSources
            case (.afterWaitLast, .timers), (.afterWaitLast, .exit): group = .afterWake
            default: group = .other
            }
            cpu[group.rawValue] += now - prev.cpu
            counts[group.rawValue] += 1
        }
        last = (marker, now)
    }

    static func finish(wall: Double, mainPercent: Double?) -> [Double]? {
        let valid = observers.count == 2 && !failed && last != nil && counts.contains(where: { $0 > 0 })
        stop()
        guard valid, wall > 0, let mainPercent else { return nil }
        let measured = cpu.map { $0 * 1000 / wall }
        return measured + [mainPercent * 10 - measured.reduce(0, +)]
    }

    static func detail(_ values: [Double]) -> String {
        let groups = Group.allCases.map { group in
            let i = group.rawValue
            return "\(group.label) \(String(format: "%.1f", values[i])) [\(counts[i])]"
        }
        return (groups + [String(format: "Ngoài mốc %.1f", values[Group.allCases.count])]).joined(separator: " · ")
    }
}

// MARK: - GameViewController

class GameViewController: UIViewController {

    let jarPath: String
    let appName: String
    let appIcon: UIImage
    let canvasWidth: Int
    let canvasHeight: Int
    let render3dScale: Int
    let fpsLimit: Int
    let layoutMode: GameLayoutMode

    private let emulatorView = EmulatorView()
    private let glowContainer = UIView()
    private let glowContentView = UIView()
    private lazy var formView = FormView()
    private lazy var listView = J2MEListView()
    private let backButton = UIButton(type: .system)
    private let lskButton = UIButton(type: .system)
    private let rskButton = UIButton(type: .system)
    private let softKeyHaptic = UIImpactFeedbackGenerator(style: .light)
    private(set) var placeholderIconView: UIImageView?

    // Controls — created based on layoutMode
    private var joystickView: JoystickView?
    private var numpadView: NumpadView?
    private enum PadMode { case directions, numbers, hidden }
    private var padMode: PadMode = .directions
    private var directionalPad: UIStackView?
    private var portraitPanel: UIView?
    private var portraitControlsHeight: NSLayoutConstraint?
    private var portraitPadBottomPins: [NSLayoutConstraint] = []
    private let screenMenu = UIButton(type: .system)
    private var blackout: UIButton?
    private var blackoutScreen: UIScreen?
    private var previousBrightness: CGFloat?
    private var heldDirections: Set<Int32> = []
    private var directionTimers: [Int32: Timer] = [:]

    init(jarPath: String, appName: String, appIcon: UIImage,
         canvasWidth: Int = 240, canvasHeight: Int = 320,
         render3dScale: Int = 3, fpsLimit: Int = 0,
         layoutMode: GameLayoutMode = .portrait) {
        self.jarPath = jarPath
        self.appName = appName
        self.appIcon = appIcon
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.render3dScale = render3dScale
        self.fpsLimit = fpsLimit
        self.layoutMode = layoutMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // The render target is weak. An older controller must not clear the
        // render target that a newer game session has already registered.
        alertTimeoutWork?.cancel()
        startupWatchdog?.cancel()
        measurementDeadline?.cancel()
        afkMeasure?.cancel()
        jarAuditWork?.cancel()
    }

    private var alertTimeoutWork: DispatchWorkItem?
    private var didStartGame = false
    private var cpuProfileStartedAt: TimeInterval?
    private var powerRun: PowerRun?
    private var afkMeasure: DispatchWorkItem?
    private var afkMeasureID: UUID?
    private var afkComparisonDone = false
    private var guardedBlackout = false
    private var jarAuditID: UUID?
    private var jarAuditWork: DispatchWorkItem?
    private var jarAuditJIT: Int32 = 0
    private var jarMainProfile = false
    private var jarLoadComparison = false
    private var jarWorkerComparison = false
    private var jarEnergyAudit = false
    private var jarEnergyOldMonitoring: Bool?
    private var jarEnergyOldIdleTimer: Bool?
    private var jarEnergyLeg = -1
    private var jarEnergySamples: [JarPowerSnapshot] = []
    private var jarSparsePaintAudit = false
    private var jarUIKitPhaseAudit = false
    private var jarUIKitPhaseBudget: JarUIKitPhaseBudget?
    private var jarMainBenchLeg = -1
    private var jarMainBenchSamples: [Double] = []
    private var jarMainQoSAudit = false
    private var jarMainQoSRestoreStatus: Int32 = 0
    private var jarDisplayWaitAudit = false
    private var jarWindowAudit = false
    private weak var jarOriginalWindow: UIWindow?
    private var jarProbeWindow: UIWindow?
    private var jarBudgetAudit = false
    private var jarCommitAudit = false
    private var jarCommitBudget: JarCommitBudget?
    private var jarDetachAudit = false
    private var jarDetachShield: UIView?
    private var jarDetachedViews: [UIView] = []
    private var jarDetachedConstraints: [NSLayoutConstraint] = []
    private var afkOriginalJIT: Int32?
    private var lastAFKTrace = ""
    private var afkFrozenLayers: [CALayer] = []

    private func setAFKUICut(_ enabled: Bool) {
        treo_afk_ui_cut_set(enabled ? 1 : 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if enabled {
            // The wake button keeps its own clock. Leave any custom layer clocks alone.
            for child in view.subviews where child !== blackout {
                let layer = child.layer
                guard layer.speed == 1, layer.timeOffset == 0, layer.beginTime == 0 else { continue }
                let local = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
                layer.timeOffset = local
                afkFrozenLayers.append(layer)
            }
            emulatorView.clearPendingGameFrame()
        } else {
            for layer in afkFrozenLayers {
                let local = layer.timeOffset
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
                layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - local
            }
            afkFrozenLayers.removeAll()
        }
        CATransaction.commit()
    }
    private var measurementDeadline: DispatchWorkItem?
    private var measurementID: UUID?
    private var lastMeasurement: (title: String, message: String)?
    private var cpuMetalBaseline: (UInt64, UInt64, UInt64) = (0, 0, 0)
    private var startupWatchdog: DispatchWorkItem?

    override var prefersStatusBarHidden: Bool { true }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        switch layoutMode {
        case .portrait: return .portrait
        case .ngage: return .landscape
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        emulatorView.canvasWidth = canvasWidth
        emulatorView.canvasHeight = canvasHeight

        switch layoutMode {
        case .portrait: setupNGageLayout(portrait: true)
        case .ngage: setupNGageLayout()
        }

        // Placeholder icon — visible until first game frame
        let iconIV = UIImageView(image: appIcon)
        iconIV.contentMode = .center
        iconIV.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(iconIV)
        NSLayoutConstraint.activate([
            iconIV.centerXAnchor.constraint(equalTo: emulatorView.centerXAnchor),
            iconIV.centerYAnchor.constraint(equalTo: emulatorView.centerYAnchor),
        ])
        placeholderIconView = iconIV
        view.bringSubviewToFront(backButton)

        // Fade out placeholder on first rendered frame
        emulatorView.onFirstFrame = { [weak self] in
            NSLog("[J2ME Treo] First game frame displayed")
            self?.finishStartupWatchdog()
            guard let icon = self?.placeholderIconView else { return }
            UIView.animate(withDuration: 0.2) {
                icon.alpha = 0
            } completion: { _ in
                icon.removeFromSuperview()
                self?.placeholderIconView = nil
            }
        }

        if layoutMode == .ngage {
            emulatorView.onFrame = { [weak self] cgImage in
                self?.glowContentView.layer.contents = cgImage
            }
        }

        // Register native callbacks
        setGlobalEmulatorView(emulatorView)
        j2me_render_set_afk_suspended(0)
        j2me_render_set_flush_callback(flushCallback)
        j2me_ui_set_callback(gameUICallback)
        activeGameViewController = self
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startGame()
    }

    // ============================================================
    // MARK: - N-Gage layout
    // ============================================================
    //
    //  ┌──────────────────────────────────────────────────────┐
    //  │ [X]                                                   │
    //  │  ┌─────────┐  ┌──────────────┐  ┌───────────────┐  │
    //  │  │         │  │              │  │ [LSK]   [RSK] │  │
    //  │  │  ╭───╮  │  │  J2ME Canvas │  │ [1] [2] [3]  │  │
    //  │  │  │ ○ │  │  │   240×320    │  │ [4] [5] [6]  │  │
    //  │  │  ╰───╯  │  │              │  │ [7] [8] [9]  │  │
    //  │  │joystick │  │              │  │ [*] [0] [#]  │  │
    //  │  └─────────┘  └──────────────┘  └───────────────┘  │
    //  └──────────────────────────────────────────────────────┘

    private func setupNGageLayout(portrait: Bool = false) {
        let joystick = JoystickView()
        let numpad = NumpadView()
        self.joystickView = joystick
        self.numpadView = numpad

        // Glow: container with game content mirror + NeutralBlurView on top
        glowContainer.isUserInteractionEnabled = false
        glowContainer.clipsToBounds = true

        glowContentView.layer.magnificationFilter = .trilinear
        glowContentView.layer.minificationFilter = .trilinear
        glowContentView.alpha = 0.6
        glowContainer.addSubview(glowContentView)

        // glowContentView fills glowContainer
        glowContentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glowContentView.topAnchor.constraint(equalTo: glowContainer.topAnchor),
            glowContentView.leadingAnchor.constraint(equalTo: glowContainer.leadingAnchor),
            glowContentView.trailingAnchor.constraint(equalTo: glowContainer.trailingAnchor),
            glowContentView.bottomAnchor.constraint(equalTo: glowContainer.bottomAnchor),
        ])

        // Full-screen blur over the glow (no hard edge)
        let glowBlur = NeutralBlurView(radius: 100)
        glowBlur.isUserInteractionEnabled = false

        for v: UIView in [glowContainer, glowBlur, joystick, emulatorView, numpad, lskButton, rskButton, formView, listView, backButton] {
            v.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(v)
        }

        formView.isHidden = true
        listView.isHidden = true

        // Soft keys — flanking the game screen at bottom
        for (btn, title) in [(lskButton, "L"), (rskButton, "R")] {
            btn.setTitle(title, for: .normal)
            btn.titleLabel?.font = .systemFont(ofSize: 18, weight: .medium)
            btn.setTitleColor(.white, for: .normal)
            btn.backgroundColor = UIColor(white: 0.12, alpha: 1)
            btn.layer.cornerRadius = 10
            btn.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
            btn.layer.borderWidth = 1
            btn.addTarget(self, action: #selector(softKeyDown(_:)), for: .touchDown)
            btn.addTarget(self, action: #selector(softKeyUp(_:)),
                          for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        lskButton.tag = -6
        rskButton.tag = -7

        // Back button
        backButton.setTitle("  \u{2715}  ", for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 20, weight: .medium)
        backButton.backgroundColor = UIColor(white: 0.15, alpha: 0.85)
        backButton.setTitleColor(.white, for: .normal)
        backButton.layer.cornerRadius = 10
        backButton.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        backButton.layer.borderWidth = 1
        backButton.addTarget(self, action: #selector(backTapped), for: .touchUpInside)

        let canvasRatio: CGFloat = CGFloat(emulatorView.canvasWidth) / CGFloat(emulatorView.canvasHeight)
        let pad: CGFloat = 8

        if portrait {
            let safe = view.safeAreaLayoutGuide
            let panel = UIView()
            portraitPanel = panel
            panel.translatesAutoresizingMaskIntoConstraints = false
            panel.backgroundColor = UIColor(white: 0.07, alpha: 1)
            view.addSubview(panel)
            let dpad = makeDirectionalPad()
            directionalPad = dpad
            for control in [numpad as UIView, dpad as UIView, lskButton, rskButton] {
                panel.addSubview(control)
                control.translatesAutoresizingMaskIntoConstraints = false
            }
            joystick.isHidden = true
            glowContainer.isHidden = true
            glowBlur.isHidden = true
            emulatorView.layer.contentsGravity = .resizeAspect
            emulatorView.clipsToBounds = true
            screenMenu.translatesAutoresizingMaskIntoConstraints = false
            screenMenu.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            screenMenu.tintColor = .white
            screenMenu.accessibilityLabel = "Tùy chọn game"
            screenMenu.showsMenuAsPrimaryAction = true
            view.addSubview(screenMenu)
            let height = panel.heightAnchor.constraint(equalToConstant: 198)
            height.priority = .defaultHigh
            portraitControlsHeight = height
            NSLayoutConstraint.activate([
                backButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: 4),
                backButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
                backButton.heightAnchor.constraint(equalToConstant: 36),
                screenMenu.topAnchor.constraint(equalTo: backButton.topAnchor),
                screenMenu.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
                screenMenu.widthAnchor.constraint(equalToConstant: 44),
                screenMenu.heightAnchor.constraint(equalToConstant: 36),
                emulatorView.topAnchor.constraint(equalTo: backButton.bottomAnchor, constant: 4),
                emulatorView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                emulatorView.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                emulatorView.bottomAnchor.constraint(equalTo: panel.topAnchor),
                panel.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
                panel.trailingAnchor.constraint(equalTo: safe.trailingAnchor),
                panel.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
                height
            ])
            let left = lskButton
            let right = rskButton
            NSLayoutConstraint.activate([
                left.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
                right.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
                left.topAnchor.constraint(equalTo: panel.topAnchor, constant: 4),
                right.topAnchor.constraint(equalTo: left.topAnchor),
                left.widthAnchor.constraint(equalToConstant: 54),
                right.widthAnchor.constraint(equalToConstant: 54),
                left.heightAnchor.constraint(equalToConstant: 30),
                right.heightAnchor.constraint(equalToConstant: 30)
            ])
            left.setTitle("L", for: .normal)
            right.setTitle("R", for: .normal)
            for padView in [numpad as UIView, dpad as UIView] {
                // Optional bottom pin lets the hidden panel collapse without conflicting constraints.
                let bottom = padView.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -6)
                portraitPadBottomPins.append(bottom)
                NSLayoutConstraint.activate([
                    padView.topAnchor.constraint(equalTo: left.bottomAnchor, constant: 4),
                    padView.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
                    padView.widthAnchor.constraint(equalTo: panel.widthAnchor, multiplier: 0.76)
                ])
            }
            for overlay in [formView as UIView, listView as UIView] {
                NSLayoutConstraint.activate([
                    overlay.topAnchor.constraint(equalTo: backButton.bottomAnchor),
                    overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                    overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
                ])
                view.bringSubviewToFront(overlay)
            }
            applyPadMode()
            return
        }

        // Layout guides for centering controls in the side panels
        let leftArea = UILayoutGuide()
        let rightArea = UILayoutGuide()
        view.addLayoutGuide(leftArea)
        view.addLayoutGuide(rightArea)

        NSLayoutConstraint.activate([
            leftArea.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            leftArea.trailingAnchor.constraint(equalTo: emulatorView.leadingAnchor),

            rightArea.leadingAnchor.constraint(equalTo: emulatorView.trailingAnchor),
            rightArea.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            // Glow content: slightly larger than emulator, sits behind it
            glowContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            glowContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            glowContainer.widthAnchor.constraint(equalTo: emulatorView.widthAnchor),
            glowContainer.heightAnchor.constraint(equalTo: emulatorView.heightAnchor),

            // Blur: full screen (no hard edge at glow boundary)
            glowBlur.topAnchor.constraint(equalTo: view.topAnchor),
            glowBlur.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            glowBlur.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            glowBlur.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Emulator: centered, aspect ratio, full height with padding
            emulatorView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emulatorView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: pad),
            emulatorView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -pad),
            emulatorView.widthAnchor.constraint(equalTo: emulatorView.heightAnchor, multiplier: canvasRatio),

            // Joystick: centered horizontally between safe area left and emulator left
            joystick.centerXAnchor.constraint(equalTo: leftArea.centerXAnchor),
            joystick.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 80),
            joystick.widthAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.42),
            joystick.heightAnchor.constraint(equalTo: joystick.widthAnchor),

            // Numpad: centered in right panel, same width as joystick, top 48pt
            numpad.centerXAnchor.constraint(equalTo: rightArea.centerXAnchor),
            numpad.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 80),
            numpad.widthAnchor.constraint(equalTo: joystick.widthAnchor),
            numpad.heightAnchor.constraint(equalTo: numpad.widthAnchor, multiplier: 1.33),

            // Soft keys: flanking game screen at bottom
            lskButton.trailingAnchor.constraint(equalTo: emulatorView.leadingAnchor, constant: -6),
            lskButton.bottomAnchor.constraint(equalTo: emulatorView.bottomAnchor),
            lskButton.widthAnchor.constraint(equalToConstant: 68),
            lskButton.heightAnchor.constraint(equalToConstant: 40),

            rskButton.leadingAnchor.constraint(equalTo: emulatorView.trailingAnchor, constant: 6),
            rskButton.bottomAnchor.constraint(equalTo: emulatorView.bottomAnchor),
            rskButton.widthAnchor.constraint(equalToConstant: 68),
            rskButton.heightAnchor.constraint(equalToConstant: 40),

            // Form / List: full screen (overlays everything when visible)
            formView.topAnchor.constraint(equalTo: view.topAnchor),
            formView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            formView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            formView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            listView.topAnchor.constraint(equalTo: view.topAnchor),
            listView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Back button: top-left
            backButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            backButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 4),
        ])

        // Game screen rounded corners + border
        emulatorView.layer.cornerRadius = 8
        emulatorView.clipsToBounds = true
        emulatorView.layer.borderColor = UIColor(white: 1, alpha: 0.12).cgColor
        emulatorView.layer.borderWidth = 1

        view.bringSubviewToFront(formView)
        view.bringSubviewToFront(listView)
        view.bringSubviewToFront(backButton)
    }

    private func makeDirectionalPad() -> UIStackView {
        // Nokia/MIDP direction and FIRE codes, also used by upstream J2ME Loader.
        let rows: [[(String, Int)]] = [
            [("", 0), ("↑", -1), ("", 0)],
            [("←", -3), ("OK", -5), ("→", -4)],
            [("", 0), ("↓", -2), ("", 0)]
        ]
        let stack = UIStackView()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 4
        for keys in rows {
            let row = UIStackView()
            row.distribution = .fillEqually
            row.spacing = 4
            for (title, code) in keys {
                if code == 0 {
                    row.addArrangedSubview(UIView())
                    continue
                }
                let button = UIButton(type: .system)
                button.tag = code
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: 19, weight: .semibold)
                button.setTitleColor(.white, for: .normal)
                button.backgroundColor = UIColor(white: 0.17, alpha: 1)
                button.layer.cornerRadius = 9
                button.addTarget(self, action: #selector(directionDown(_:)), for: .touchDown)
                button.addTarget(self, action: #selector(directionUp(_:)),
                                 for: [.touchUpInside, .touchUpOutside, .touchCancel])
                row.addArrangedSubview(button)
            }
            stack.addArrangedSubview(row)
        }
        return stack
    }

    @objc private func directionDown(_ sender: UIButton) {
        let code = Int32(sender.tag)
        guard heldDirections.insert(code).inserted else { return }
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), code)
        if code != -5 {
            let timer = Timer(fireAt: Date(timeIntervalSinceNow: 0.36), interval: 0.085,
                              target: self, selector: #selector(repeatDirection(_:)),
                              userInfo: code, repeats: true)
            directionTimers[code] = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    @objc private func repeatDirection(_ timer: Timer) {
        guard let code = timer.userInfo as? Int32, heldDirections.contains(code) else { return }
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_REPEATED), code)
    }

    @objc private func directionUp(_ sender: UIButton) {
        releaseDirection(Int32(sender.tag))
    }

    private func releaseDirection(_ code: Int32) {
        directionTimers.removeValue(forKey: code)?.invalidate()
        if heldDirections.remove(code) != nil {
            j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), code)
        }
    }

    private func setPadMode(_ mode: PadMode) {
        for code in Array(heldDirections) { releaseDirection(code) }
        padMode = mode
        applyPadMode()
    }

    private func applyPadMode() {
        guard let panel = portraitPanel else { return }
        let canvasIsVisible = !emulatorView.isHidden
        let padIsVisible = canvasIsVisible && padMode != .hidden
        panel.isHidden = !padIsVisible
        screenMenu.isHidden = !canvasIsVisible
        directionalPad?.isHidden = padMode != .directions
        numpadView?.isHidden = padMode != .numbers
        portraitControlsHeight?.constant = padIsVisible ? 198 : 0
        for pin in portraitPadBottomPins { pin.isActive = padIsVisible }
        if jarAuditID != nil {
            screenMenu.menu = UIMenu(children: [
                UIAction(title: "Hủy chẩn đoán CPU JAR", attributes: .destructive) { [weak self] _ in self?.stopJarAudit() }
            ])
            return
        }
        screenMenu.menu = UIMenu(children: [
            UIAction(title: "Phím điều hướng", state: padMode == .directions ? .on : .off) { [weak self] _ in self?.setPadMode(.directions) },
            UIAction(title: "Phím số", state: padMode == .numbers ? .on : .off) { [weak self] _ in self?.setPadMode(.numbers) },
            UIAction(title: "Ẩn phím · màn hình lớn", state: padMode == .hidden ? .on : .off) { [weak self] _ in self?.setPadMode(.hidden) },
            UIAction(title: "Xem kết quả đo gần nhất",
                     attributes: lastMeasurement == nil ? .disabled : []) { [weak self] _ in
                self?.showLastMeasurement()
            },
            UIAction(title: powerRun == nil ? "Bắt đầu đo nhiệt và CPU tổng" : "Dừng đo nhiệt và CPU tổng",
                     attributes: cpuProfileStartedAt == nil ? [] : .disabled) { [weak self] _ in
                self?.togglePowerRun()
            },
            UIAction(title: "Thử chờ thụ động · CPU main") { [weak self] _ in self?.confirmJarAudit(compareLoad: true) },
            UIAction(title: "So tải game và luồng native · JAR") { [weak self] _ in
                self?.confirmJarAudit(workerComparison: true)
            },
            UIAction(title: "Thử hạ QoS main · JAR") { [weak self] _ in
                self?.confirmJarAudit(mainQoSAudit: true)
            },
            UIAction(title: "Thử Display chờ sự kiện · JAR") { [weak self] _ in
                self?.confirmJarAudit(displayWaitAudit: true)
            },
            UIAction(title: "Thử cửa sổ đen foreground · JAR") { [weak self] _ in
                self?.confirmJarAudit(windowOcclusion: true)
            },
            UIAction(title: "Thử tháo giao diện game · JAR") { [weak self] _ in
                self?.confirmJarAudit(budgetMain: true, detachUI: true)
            },
            UIAction(title: "Đo nhanh CPU, pin & nhiệt · 6 phút") { [weak self] _ in
                self?.confirmJarAudit(energyAudit: true)
            },
            UIAction(title: "Thử paint thưa 1/3 Hz · JAR") { [weak self] _ in
                self?.confirmJarAudit(sparsePaintAudit: true)
            },
            UIAction(title: "Đo 6 pha UIKit · tắt → bật → tắt",
                     attributes: Self.jarCommitAuditSupported ? [] : .disabled) { [weak self] _ in
                self?.confirmJarAudit(uikitPhases: true)
            },
            UIAction(title: "Đo CPU quanh commit UIKit · JAR",
                     attributes: Self.jarCommitAuditSupported ? [] : .disabled) { [weak self] _ in
                self?.confirmJarAudit(budgetMain: true, measureCommit: true)
            },
            UIAction(title: "Đo pha CPU main · JAR") { [weak self] _ in self?.confirmJarAudit(budgetMain: true) },
            UIAction(title: "Tìm stack sau Source · JAR") { [weak self] _ in
                self?.confirmJarAudit(profileMain: true, budgetMain: true)
            },
            UIAction(title: "Chẩn đoán CPU JAR · tắt → bật → tắt") { [weak self] _ in self?.confirmJarAudit() },
            UIAction(title: "Treo tối đa · màn hình đen") { [weak self] _ in self?.showBlackout() },
            UIAction(title: "Treo · vẽ SIMD ngầm (thử nghiệm)") { [weak self] _ in self?.showBlackout(mode: 5) },
            UIAction(title: "So CPU treo · Canvas nhanh",
                     attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in self?.startGuardedComparison(fast: true) },
            UIAction(title: "So CPU treo · Canvas không dựng hình",
                     attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in self?.confirmGuardedComparison() },
            UIAction(title: "So CPU treo · paint 5 Hz / JIT") { [weak self] _ in self?.confirmAfkPaintTest() },
            UIAction(title: treo_game_jit_is_enabled() != 0 ? "Tắt JIT Java (thử nghiệm)" : "Bật JIT Java (thử nghiệm)", attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in
                guard let self else { return }
                if treo_game_jit_is_enabled() != 0 {
                    treo_game_jit_set_enabled(0)
                    self.applyPadMode()
                    return
                }
                let prompt = UIAlertController(title: "JIT Java thử nghiệm",
                    message: "Chỉ bật sau khi StikDebug đã attach vào tiến trình này. Phương thức game chạy nhiều sẽ được biên dịch; tính năng có thể gây lỗi hoặc thoát app.",
                    preferredStyle: .alert)
                prompt.addAction(UIAlertAction(title: "Hủy", style: .cancel))
                prompt.addAction(UIAlertAction(title: "Bật JIT Java", style: .default) { [weak self] _ in
                    let smoke = treo_jit_probe()
                    let result = smoke == 42 ? treo_game_jit_backend_probe() : smoke
                    if result == 42 {
                        treo_game_jit_set_enabled(1)
                        self?.applyPadMode()
                    } else {
                        let report = UIAlertController(title: "Không bật được JIT Java",
                            message: "Mã lỗi kiểm tra thực thi: \(result). Game vẫn chạy bằng trình thông dịch.",
                            preferredStyle: .alert)
                        report.addAction(UIAlertAction(title: "OK", style: .default))
                        self?.present(report, animated: true)
                    }
                })
                self.present(prompt, animated: true)
            },
            UIAction(title: "Bỏ sprite ngoài vùng vẽ (thử nghiệm)",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil ? [] : .disabled,
                     state: treo_render_region_cull_enabled() != 0 ? .on : .off) { [weak self] _ in
                let enabled = treo_render_region_cull_enabled() != 0
                treo_render_set_region_cull_enabled(enabled ? 0 : 1)
                self?.applyPadMode()
            },
            UIAction(title: cpuProfileStartedAt == nil ? "Bắt đầu đo CPU" : "Dừng và xem số liệu CPU",
                     attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in
                self?.toggleCPUProfile()
            },
            UIAction(title: "Vẽ sprite trực tiếp · CPU SIMD",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil ? [] : .disabled,
                     state: treo_software_enabled() != 0 ? .on : .off) { [weak self] _ in
                let enabling = treo_software_enabled() == 0
                if enabling {
                    treo_cpu_batch_set_enabled(0)
                    treo_metal_live_set_enabled(0)
                    treo_render_set_region_cull_enabled(0)
                }
                treo_software_set_enabled(enabling ? 1 : 0)
                self?.applyPadMode()
            },
            UIAction(title: "Đường vẽ trực tiếp · SIMD+",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil && treo_software_enabled() != 0 ? [] : .disabled,
                     state: treo_direct_graphics_enabled() != 0 && treo_software_enabled() != 0 ? .on : .off) { [weak self] _ in
                treo_direct_graphics_set_enabled(treo_direct_graphics_enabled() == 0 ? 1 : 0)
                self?.applyPadMode()
            },
            UIAction(title: "Dùng lại cụm sprite (CPU)",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil ? [] : .disabled,
                     state: treo_cpu_batch_enabled() != 0 ? .on : .off) { [weak self] _ in
                let enabling = treo_cpu_batch_enabled() == 0
                if enabling { treo_metal_live_set_enabled(0); treo_software_set_enabled(0) }
                treo_cpu_batch_set_enabled(enabling ? 1 : 0)
                self?.applyPadMode()
            },
            UIAction(title: "Metal toàn khung (thử nghiệm)",
                     attributes: cpuProfileStartedAt == nil && powerRun == nil ? [] : .disabled,
                     state: treo_metal_live_enabled() != 0 ? .on : .off) { [weak self] _ in
                let enabling = treo_metal_live_enabled() == 0
                if enabling { treo_cpu_batch_set_enabled(0); treo_software_set_enabled(0) }
                treo_metal_live_set_enabled(enabling ? 1 : 0)
                self?.applyPadMode()
            },
            UIAction(title: "Đo thử Metal · drawRegion", attributes: powerRun == nil ? [] : .disabled) { [weak self] _ in
                self?.showMetalReplay()
            },
            UIAction(title: "Thống kê JIT Java") { [weak self] _ in
                let compiled = treo_game_jit_compiled_count()
                let calls = treo_game_jit_call_count()
                let report = UIAlertController(title: "Thống kê JIT Java",
                    message: "Từ khi mở app: \(compiled) phương thức đã biên dịch · \(calls) lượt mã máy.\n\(treo_game_jit_fallback_count()) lần biên dịch không dùng được; tiếp tục thông dịch.\nBộ nhớ mã Java: \(treo_game_jit_code_kib()) KiB / 32 MiB.",
                    preferredStyle: .alert)
                report.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(report, animated: true)
            }
        ])
    }

    private func cancelMeasurementDeadline() {
        measurementDeadline?.cancel()
        measurementDeadline = nil
        measurementID = nil
    }

    private func scheduleMeasurementDeadline(power: Bool) {
        cancelMeasurementDeadline()
        let id = UUID()
        measurementID = id
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.measurementID == id else { return }
            if power {
                if self.powerRun != nil { self.togglePowerRun() }
            } else if self.cpuProfileStartedAt != nil {
                self.toggleCPUProfile()
            }
        }
        measurementDeadline = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(60), execute: work)
    }

    private func publishMeasurement(title: String, message: String) {
        lastMeasurement = (title, message)
        applyPadMode()
        showLastMeasurement()
    }

    private func showLastMeasurement() {
        guard let report = lastMeasurement, viewIfLoaded?.window != nil,
              presentedViewController == nil, !isBeingDismissed,
              UIApplication.shared.applicationState == .active else { return }
        let alert = UIAlertController(title: report.title, message: report.message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sao chép", style: .default) { _ in
            if report.title == "CPU luồng chính", !self.lastAFKTrace.isEmpty {
                UIPasteboard.general.string = report.message + "\n\n" + self.lastAFKTrace
            } else {
                UIPasteboard.general.string = report.message
            }
        })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        present(alert, animated: true)
    }

    private struct PowerRun {
        let time: TimeInterval
        let cpu: Double
        let thermal: ProcessInfo.ThermalState
        let metal: Int32
        let jit: Int32
        let cull: Int32
        let gpuFrames: UInt64
        let batch: Int32
        let queued: UInt64
        let reused: UInt64
        let software: Int32
        let softwareStats: TreoSoftwareStats
        let direct: Int32
    }

    private func togglePowerRun() {
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = treo_process_cpu_seconds()
        let thermal = ProcessInfo.processInfo.thermalState
        let metal = treo_metal_live_enabled()
        let jit = treo_game_jit_is_enabled()
        let cull = treo_render_region_cull_enabled()
        let gpuFrames = treo_metal_live_frames()
        guard let start = powerRun else {
            powerRun = PowerRun(time: now, cpu: cpu, thermal: thermal, metal: metal, jit: jit,
                                cull: cull, gpuFrames: gpuFrames, batch: treo_cpu_batch_enabled(),
                                queued: treo_cpu_batch_queued(), reused: treo_cpu_batch_reused(),
                                software: treo_software_enabled(), softwareStats: treo_software_stats(), direct: treo_direct_graphics_enabled())
            scheduleMeasurementDeadline(power: true)
            applyPadMode()
            return
        }
        cancelMeasurementDeadline()
        powerRun = nil
        let duration = now - start.time
        let valid = start.cpu >= 0 && cpu >= start.cpu && duration > 0
        let cpuText = valid ? String(format: "%.1f%% một lõi", 100.0 * (cpu - start.cpu) / duration) : "Không đọc được"
        func thermalLabel(_ value: ProcessInfo.ThermalState) -> String {
            switch value {
            case .nominal: return "Bình thường"
            case .fair: return "Tăng nhẹ"
            case .serious: return "Cao"
            case .critical: return "Rất cao"
            @unknown default: return "Không rõ"
            }
        }
        let sw = treo_software_stats()
        let fps = Double(sw.frames &- start.softwareStats.frames) / max(0.001, duration)
        let report = """
        SIMD: \(start.software != 0 ? "Bật" : "Tắt") · \(String(format: "%.1f", fps)) khung gửi/giây
        SIMD+: \(start.direct != 0 && start.software != 0 ? "Bật" : "Tắt") · \(sw.direct &- start.softwareStats.direct) lệnh API trực tiếp
        Vẽ nhanh: \(sw.fast &- start.softwareStats.fast)/\(sw.regions &- start.softwareStats.regions)
        Đối chiếu CG: \(sw.checked &- start.softwareStats.checked) · Lệch: \(sw.mismatch &- start.softwareStats.mismatch)
        Thời gian: \(String(format: "%.1f", duration)) s
        CPU toàn app: \(cpuText)
        Mức nhiệt iOS (đầu → cuối): \(thermalLabel(start.thermal)) → \(thermalLabel(thermal))
        Metal: \(metal != 0 ? "Bật" : "Tắt") · \(gpuFrames &- start.gpuFrames) khung GPU
        JIT: \(jit != 0 ? "Bật" : "Tắt") · Bỏ sprite: \(cull != 0 ? "Bật" : "Tắt")
        Cụm sprite CPU: \(start.batch != 0 ? "Bật" : "Tắt")
        Lệnh dùng lại: \(treo_cpu_batch_reused() &- start.reused)/\(treo_cpu_batch_queued() &- start.queued) lệnh gom đủ cụm
        Không đo công suất, độ C hoặc mức tải GPU.
        """
        publishMeasurement(title: "Nhiệt và CPU tổng", message: report)
    }

    private func showMetalReplay() {
        let raw = treo_metal_replay_copy_report()
        let report = raw.map { String(cString: $0) } ?? "Không đọc được báo cáo."
        if let raw { free(raw) }
        let alert = UIAlertController(title: "Replay Metal · drawRegion", message: report, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        alert.addAction(UIAlertAction(title: "Sao chép", style: .default) { _ in
            UIPasteboard.general.string = report
        })
        if cpuProfileStartedAt == nil && treo_render_region_cull_enabled() == 0 && treo_metal_live_enabled() == 0 && treo_cpu_batch_enabled() == 0 {
            alert.addAction(UIAlertAction(title: "Thu và đo", style: .default) { _ in
                _ = treo_metal_replay_start()
            })
        }
        present(alert, animated: true)
    }

    private func toggleCPUProfile() {
        guard let start = cpuProfileStartedAt else {
            cpuMetalBaseline = (treo_metal_live_frames(), treo_metal_live_sprites(), treo_metal_live_fallback_sprites())
            treo_render_profile_start()
            cpuProfileStartedAt = ProcessInfo.processInfo.systemUptime
            scheduleMeasurementDeadline(power: false)
            applyPadMode()
            return
        }
        cancelMeasurementDeadline()
        let result = treo_render_profile_stop()
        let seconds = ProcessInfo.processInfo.systemUptime - start
        cpuProfileStartedAt = nil
        let paint = Double(result.paint_ns) / 1_000_000
        let snapshot = Double(result.snapshot_ns) / 1_000_000
        let region = Double(result.region_sample_ns) / 1_000_000
        let cullMode = treo_render_region_cull_enabled() != 0 ? "Bật" : "Tắt"
        let cullPercent = 100.0 * Double(result.region_culled) / max(1.0, Double(result.region_calls))
        let metalMode = treo_metal_live_enabled() != 0 ? "Bật" : "Tắt"
        let metalFrames = treo_metal_live_frames() &- cpuMetalBaseline.0
        let metalSprites = treo_metal_live_sprites() &- cpuMetalBaseline.1
        let metalFallback = treo_metal_live_fallback_sprites() &- cpuMetalBaseline.2
        let report = """
        Metal live: \(metalMode) · \(metalFrames) khung · \(metalSprites) lệnh GPU
        Lệnh đã xếp hàng nhưng vẽ lại bằng CG: \(metalFallback)
        Xử lý sprite cuối khung (ngoài paint): \(String(format: "%.1f", Double(result.live_boundary_ns) / 1_000_000)) ms CPU
        Bỏ sprite ngoài vùng vẽ: \(cullMode)
        Bỏ sớm: \(result.region_culled)/\(result.region_calls) · \(String(format: "%.1f", cullPercent))%
        Thời gian đo: \(String(format: "%.1f", seconds)) s
        paint(): \(result.paints) lần · \(String(format: "%.1f", paint)) ms CPU
        Flush: \(result.flushes) · Ảnh tạo: \(result.snapshots)
        Tạo ảnh: \(String(format: "%.1f", snapshot)) ms CPU
        Gửi lên layer: \(result.submitted) · Bị thay trong hàng đợi: \(result.replaced)
        drawRegion: \(result.region_calls) lượt · \(result.region_samples) mẫu, \(String(format: "%.1f", region)) ms CPU trong mẫu
        """
        NSLog("[TREO-CPU] %@", report)
        publishMeasurement(title: "CPU khi hiện game", message: report)
    }

    private func discardCPUProfile() {
        cancelMeasurementDeadline()
        let hadPowerRun = powerRun != nil
        powerRun = nil
        guard cpuProfileStartedAt != nil else {
            if hadPowerRun { applyPadMode() }
            return
        }
        _ = treo_render_profile_stop()
        cpuProfileStartedAt = nil
        applyPadMode()
    }

    fileprivate func keepBlackoutOnTop() {
        if let blackout { view.bringSubviewToFront(blackout) }
    }

    private func showBlackout(mode: Int32 = 1) {
        guard blackout == nil else { return }
        discardCPUProfile()
        for code in Array(heldDirections) { releaseDirection(code) }
        let cover = UIButton(type: .custom)
        cover.backgroundColor = .black
        cover.setTitle("Chạm để hiện game", for: .normal)
        cover.setTitleColor(UIColor(white: 0.36, alpha: 1), for: .normal)
        cover.titleLabel?.font = .systemFont(ofSize: 14)
        cover.accessibilityLabel = "Hiện lại game"
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.addTarget(self, action: #selector(hideBlackout), for: .touchUpInside)
        view.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: view.topAnchor),
            cover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        blackout = cover
        treo_render_set_afk_mode(mode)
        if let screen = view.window?.windowScene?.screen {
            blackoutScreen = screen
            previousBrightness = screen.brightness
            screen.brightness = 0
        }
        NotificationCenter.default.addObserver(self, selector: #selector(hideBlackout), name: UIApplication.willResignActiveNotification, object: nil)
    }

    @objc private func hideBlackout() {
        guard blackout != nil else { return }
        afkMeasure?.cancel()
        treo_afk_main_trace_cancel()
        if guardedBlackout {
            treo_afk_wakes_set(0)
            guardedBlackout = false
        }
        if !afkFrozenLayers.isEmpty || afkMeasureID != nil { setAFKUICut(false) }
        afkMeasure = nil
        afkMeasureID = nil
        restoreAfkJIT()
        let showComparison = afkComparisonDone
        afkComparisonDone = false
        j2me_render_set_afk_suspended(0)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        if let screen = blackoutScreen, let brightness = previousBrightness, screen.brightness == 0 {
            screen.brightness = brightness
        }
        blackoutScreen = nil
        previousBrightness = nil
        blackout?.removeFromSuperview()
        blackout = nil
        if showComparison { showLastMeasurement() }
    }

    private struct JarAuditSample {
        let base = AfkSample()
        let loadNS = treo_jar_load_cpu_ns()
        let loadWall = treo_jar_load_wall_ns()
        let loadCalls = treo_jar_load_calls()
        let on = treo_jar_audit_ticks(1)
        let off = treo_jar_audit_ticks(0)
        let frames = treo_afk_layer_frames()
        let wakes = treo_afk_main_wakes()
        let displayPolls = treo_display_poll_calls()
        let displayWaits = treo_display_wait_calls()
        let displayGcSafeWaits = treo_display_gc_safe_wait_calls()
        let displayTimeouts = treo_display_wait_timeouts()
        let displaySignals = treo_display_wake_signals()
        let sparseDue = treo_jar_sparse_paint_due_count()
    }

    private func installJarDetachShield() {
        // Same static cancel control in all legs; intercept touches before the game.
        let shield = UIView(frame: view.bounds)
        shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let cancel = UIButton(type: .system)
        cancel.setTitle("Hủy đo", for: .normal)
        cancel.tintColor = .white
        cancel.backgroundColor = .black
        cancel.addTarget(self, action: #selector(stopJarAudit), for: .touchUpInside)
        cancel.frame = CGRect(x: 12, y: view.safeAreaInsets.top + 8, width: 88, height: 44)
        shield.addSubview(cancel)
        view.addSubview(shield)
        jarDetachShield = shield
    }

    private func detachJarGameViews() -> Bool {
        guard let shield = jarDetachShield, shield.superview === view,
              view.window != nil, jarDetachedViews.isEmpty else { return false }
        let children = view.subviews.filter { $0 !== shield }
        guard !children.isEmpty else { return false }
        // Save active constraints that UIKit may remove with the views. Include
        // installed constraints below the root (nested views/layout guides).
        func activeConstraints(in root: UIView) -> [NSLayoutConstraint] {
            root.constraints.filter { $0.isActive } + root.subviews.flatMap { activeConstraints(in: $0) }
        }
        jarDetachedViews = children
        jarDetachedConstraints = activeConstraints(in: view)
        UIView.performWithoutAnimation {
            for child in children { child.removeFromSuperview() }
        }
        return isJarGameUIActuallyDetached()
    }

    private func isJarGameUIActuallyDetached() -> Bool {
        guard let shield = jarDetachShield, view.window != nil,
              view.subviews.count == 1, view.subviews.first === shield,
              !jarDetachedViews.isEmpty else { return false }
        return jarDetachedViews.allSatisfy {
            $0.superview == nil && $0.window == nil && $0.layer.superlayer == nil
        }
    }

    private func restoreJarGameViews() {
        guard !jarDetachedViews.isEmpty else { return }
        let children = jarDetachedViews
        let constraints = jarDetachedConstraints
        jarDetachedViews.removeAll()
        jarDetachedConstraints.removeAll()
        UIView.performWithoutAnimation {
            for child in children { view.addSubview(child) }
            if let shield = jarDetachShield, shield.superview === view {
                view.bringSubviewToFront(shield)
            }
            NSLayoutConstraint.activate(constraints.filter { !$0.isActive })
            view.layoutIfNeeded()
        }
    }

    // Foreground-only visibility experiment. The original UIWindow remains
    // owned by SceneDelegate and keeps its game controller/VM alive.
    private func installJarProbeWindow() -> Bool {
        guard jarProbeWindow == nil, let original = view.window,
              !original.isHidden, let scene = original.windowScene,
              scene.activationState == .foregroundActive,
              UIApplication.shared.applicationState == .active else { return false }

        let controller = UIViewController()
        controller.view.backgroundColor = .black
        let title = UILabel()
        title.text = "Đang đo cửa sổ đen · tự hiện lại game"
        title.textColor = .white
        title.font = .systemFont(ofSize: 13)
        title.textAlignment = .center
        title.numberOfLines = 0
        title.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(title)

        let cancel = UIButton(type: .system)
        cancel.setTitle("Hủy đo · hiện game", for: .normal)
        cancel.tintColor = .white
        cancel.addTarget(self, action: #selector(stopJarAudit), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(cancel)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: controller.view.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(lessThanOrEqualTo: controller.view.trailingAnchor, constant: -20),
            cancel.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            cancel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])

        let replacement = UIWindow(windowScene: scene)
        replacement.windowLevel = UIWindow.Level(rawValue: original.windowLevel.rawValue + 1)
        replacement.rootViewController = controller
        jarOriginalWindow = original
        jarProbeWindow = replacement
        replacement.makeKeyAndVisible()
        original.isHidden = true
        return isJarProbeWindowVisible()
    }

    private func isJarProbeWindowVisible() -> Bool {
        guard let original = jarOriginalWindow, let replacement = jarProbeWindow else { return false }
        return original.isHidden && !replacement.isHidden && replacement.isKeyWindow
            && replacement.rootViewController?.view.window === replacement
            && replacement.windowScene?.activationState == .foregroundActive
            && UIApplication.shared.applicationState == .active
    }

    private func restoreJarProbeWindow() {
        if let original = jarOriginalWindow {
            original.isHidden = false
            original.makeKeyAndVisible()
        }
        jarProbeWindow?.isHidden = true
        jarProbeWindow?.rootViewController = nil
        jarProbeWindow = nil
        jarOriginalWindow = nil
    }

    private static var jarCommitAuditSupported: Bool {
        if #available(iOS 18.0, *) { return true }
        return false
    }

    private func confirmJarAudit(profileMain: Bool = false, compareLoad: Bool = false, workerComparison: Bool = false, windowOcclusion: Bool = false, displayWaitAudit: Bool = false, mainQoSAudit: Bool = false, uikitPhases: Bool = false, sparsePaintAudit: Bool = false, energyAudit: Bool = false, budgetMain: Bool = false, detachUI: Bool = false, measureCommit: Bool = false) {
        guard !(measureCommit || windowOcclusion || displayWaitAudit || mainQoSAudit || uikitPhases) || Self.jarCommitAuditSupported else { return }
        guard jarAuditID == nil, blackout == nil, powerRun == nil, cpuProfileStartedAt == nil else { return }
        let sourceProfile = budgetMain && profileMain
        let alert = UIAlertController(title: energyAudit ? "Đo hao pin & nhiệt · JAR" :
                sparsePaintAudit ? "Thử paint thưa 1/3 Hz · JAR" :
                uikitPhases ? "Đo 6 pha UIKit · tắt → bật → tắt" :
                mainQoSAudit ? "Thử hạ QoS main · JAR" :
                displayWaitAudit ? "Thử Display chờ sự kiện · JAR" :
                windowOcclusion ? "Thử cửa sổ đen foreground · JAR" :
                workerComparison ? "So tải game và luồng native · JAR" : measureCommit ? "Đo CPU quanh commit UIKit · JAR" :
                detachUI ? "Thử tháo giao diện game · JAR" :
                sourceProfile ? "Tìm stack sau Source · JAR" :
                budgetMain ? "Đo pha CPU main · JAR" :
                (compareLoad ? "Thử chờ thụ động · CPU main" :
                 (profileMain ? "Tìm hàm ăn CPU main" : "Chẩn đoán CPU JAR")),
            message: energyAudit
                ? "Map 37, auto x1, bắt đầu với Treo trong JAR đang TẮT. Đo A1 TẮT → B BẬT → A2 TẮT, chỉ 2 phút/lượt (6 phút tổng); tự nhắc bạn đổi trạng thái giữa các lượt. GIỮ iPhone trên pin (không sạc), cùng độ sáng cố định, không đổi mạng, không khóa màn hình, không kéo Trung tâm thông báo. Không chặn khung native: A1/A2 là game hiển thị bình thường, B là treo JAR thực tế; tắt JIT suốt bài. Ghi CPU time từ getrusage, pin, nhiệt hệ thống, độ sáng, tick và benchmark. Vì mỗi lượt chỉ 2 phút, biến động pin 0–1% KHÔNG đủ kết luận mức hao pin; ưu tiên CPU time và benchmark. Không đo watt hay nhiệt độ °C. Có Hủy và tự hoàn nguyên cài đặt."
                : sparsePaintAudit
                ? "Map 37, auto x1, BẬT Treo tối ưu CPU trong JAR trước. Không bật màn đen JarBox. 4 lượt × 30 giây: A1 không paint → B ép paint thật 1 lần/giây → C 3 lần/giây → A2 không paint; tự chuyển, không cần chạm. Khung game vẫn bị chặn native. Đo CPU tổng/main, tốc độ phép tính cố định, tick và số paint thực. CẢNH BÁO: paint của JAR có thể chứa logic, chỉ dùng để chẩn đoán. Có Hủy; tự tắt ép paint sau thử."
                : uikitPhases
                ? "Map 37, auto x1, ban đầu TẮT treo trong JAR. Đo A1 tắt → B bật → A2 tắt, mỗi lượt 30 giây và chuyển theo hướng dẫn trên màn hình. Cả ba lượt cùng chặn khung native, tạm tắt JIT, không thêm tải giả và không sửa QoS. Đo 6 khoảng UIKit và 12 lần tính toán cố định rất ngắn trên main mỗi lượt, kiểm tra tốc độ xử lý thay vì cố ép QoS. Kiểm tra treo đúng trạng thái từ 3 giây đầu. Chỉ kết luận nếu mốc ghép đủ và game giữ nhịp."
                : mainQoSAudit
                ? "Map 37, auto x1, BẬT treo trong JAR trước. Không bật màn đen JarBox hay kéo Trung tâm thông báo. A1 QoS gốc → B User Initiated → C Utility → A2 QoS gốc, 4 lượt × 30 giây. Không tạo tải giả, chỉ đổi QoS main thread; VM/game giữ nguyên. Đo CPU tổng, main, tick và cập nhật UIKit. Nếu iOS từ chối đổi QoS hoặc game chậm, báo không hợp lệ. Có Hủy và tự khôi phục QoS khi kết thúc."
                : displayWaitAudit
                ? "Map 37, auto x1, BẬT treo trong JAR trước, không bật màn đen JarBox riêng. Đo A1 chờ 16ms cũ → B chờ tín hiệu input/repaint (tối đa 250ms) → A2 chờ cũ. Ba lượt 30 giây, tự chuyển; JIT tắt và chặn khung đều như nhau. Giữ nguyên auto, không chạm. Có nút hủy; nếu tick game lệch hoặc Display không thật sự ngủ theo tín hiệu, báo không kết luận."
                : windowOcclusion
                ? "Map 37, auto x1, BẬT treo trong JAR trước. Không bật màn đen JarBox. Ba lượt tự động A1 cửa sổ game → B cửa sổ đen tối giản → A2 khôi phục. Mỗi lượt 25 giây, app vẫn foreground; JIT tắt và không xuất khung game cả ba lượt. Nếu scene không active hoặc nhịp game sai, bài đo sẽ báo không hợp lệ. Có nút Hủy và tự khôi phục cửa sổ."
                : workerComparison
                ? "Map 37, auto x1, BẬT treo trong JAR trước. Không bật màn đen riêng. A1 → tải CPU trên game → tải trên pthread riêng → A2, mỗi lượt 30 giây. Cả bốn lượt chặn khung, tắt JIT, đo pha main và mốc UIKit; tự chuyển lượt, không cần chạm. Tải chỉ dùng chẩn đoán."
                : measureCommit
                ? "Map 37, auto x1, treo trong JAR đang TẮT. Đo tắt → bật → tắt theo lời nhắc. Không bật màn đen Treo riêng. App chặn khung, tạm tắt JIT và chỉ quan sát các mốc UIKit; không lấy stack."
                : detachUI
                ? "Map 37, auto x1, BẬT treo trong JAR trước. Ba lượt tự động: giao diện gắn → tháo thật khỏi cửa sổ → gắn lại. Giữ treo JAR bật suốt bài. Không bật màn đen Treo. Chặn khung, tắt JIT trong bài, không lấy stack. Có nút Hủy đo."
                : sourceProfile
                ? "Map 37, auto x1, treo trong JAR đang TẮT. Ba lượt × 60 giây: tắt → bật → tắt theo lời nhắc. Không bật màn đen Treo. App chặn khung, tạm tắt JIT, và chỉ lấy stack trong khoảng sau mốc Source."
                : budgetMain
                ? "Map 37, auto x1, treo trong JAR đang TẮT. Ba lượt × 60 giây: tắt → bật → tắt theo lời nhắc. Không bật màn đen Treo. Cả ba lượt chặn khung và tạm tắt JIT. Không lấy stack hay tạo tải giả."
                : compareLoad
                ? "Trong map 37, để auto chạy và BẬT Treo tối ưu CPU trong game trước. Không bật màn đen Treo. App tự đo 4 lượt × 25 giây: mốc đầu → xung tính toán → chờ thụ động cùng vị trí → mốc cuối. Giữ treo JAR bật, không vẽ, không lấy stack. Hình đứng yên do chặn khung. Không chạm vào vùng game trong lúc đo."
                : profileMain
                ? "Dùng Farm-Clean-CPU.jar trong map 37, auto đang chạy, treo trong game đang TẮT. App lấy stack main ở hai lượt tắt/bật, mỗi lượt 20 giây. Hình đứng yên khi lấy mẫu vì app chặn khung game. Bật treo khi được nhắc. Đây không phải bài chấm CPU. Không bật màn đen Treo."
                : "Dùng Farm-Clean-CPU.jar trong map 37, auto đang chạy, mục treo trong game đang TẮT. App đo 3 lượt × 60 giây, cùng chặn khung game. Chỉ thao tác bật treo và chạm để thoát khi app nhắc. Không bật màn đen Treo. JIT tạm tắt trong bài đo.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: profileMain ? "Lấy mẫu" : "Đo", style: .default) { [weak self] _ in
            self?.startJarAudit(profileMain: profileMain, compareLoad: compareLoad, workerComparison: workerComparison, windowOcclusion: windowOcclusion, displayWaitAudit: displayWaitAudit, mainQoSAudit: mainQoSAudit, uikitPhases: uikitPhases, sparsePaintAudit: sparsePaintAudit, energyAudit: energyAudit, budgetMain: budgetMain, detachUI: detachUI, measureCommit: measureCommit)
        })
        present(alert, animated: true)
    }

    private func startJarAudit(profileMain: Bool, compareLoad: Bool, workerComparison: Bool, windowOcclusion: Bool, displayWaitAudit: Bool, mainQoSAudit: Bool, uikitPhases: Bool, sparsePaintAudit: Bool, energyAudit: Bool, budgetMain: Bool, detachUI: Bool, measureCommit: Bool) {
        guard jarAuditID == nil, blackout == nil, powerRun == nil, cpuProfileStartedAt == nil else { return }
        if mainQoSAudit {
            let code = treo_main_qos_begin()
            guard code == 0 else {
                publishMeasurement(title: "Thử hạ QoS main · JAR",
                                   message: "Không chạy: không lưu được QoS main gốc (lỗi \(code)). Chưa thay đổi QoS hay game.")
                return
            }
        }
        if energyAudit {
            let device = UIDevice.current
            let originalMonitoring = device.isBatteryMonitoringEnabled
            device.isBatteryMonitoringEnabled = true
            guard device.batteryState == .unplugged && device.batteryLevel >= 0 else {
                device.isBatteryMonitoringEnabled = originalMonitoring
                publishMeasurement(title: "Đo hao pin & nhiệt · JAR",
                    message: "Không bắt đầu: iPhone phải rút sạc, cho phép đọc mức pin và trạng thái pin phải xác định.")
                return
            }
            jarEnergyOldMonitoring = originalMonitoring
            jarEnergyOldIdleTimer = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        }
        jarMainQoSRestoreStatus = 0
        jarEnergyAudit = energyAudit
        jarMainQoSAudit = mainQoSAudit
        jarUIKitPhaseAudit = uikitPhases
        jarSparsePaintAudit = sparsePaintAudit
        jarMainProfile = profileMain
        jarLoadComparison = compareLoad
        jarWorkerComparison = workerComparison
        jarWindowAudit = windowOcclusion
        jarDisplayWaitAudit = displayWaitAudit
        jarBudgetAudit = budgetMain || workerComparison || windowOcclusion || displayWaitAudit || mainQoSAudit || uikitPhases || sparsePaintAudit
        jarCommitAudit = measureCommit || workerComparison || windowOcclusion || displayWaitAudit || mainQoSAudit
        jarDetachAudit = detachUI
        let id = UUID()
        jarAuditID = id
        jarAuditJIT = treo_game_jit_is_enabled()
        treo_game_jit_set_enabled(0)
        treo_jar_audit_set(1)
        treo_afk_wakes_set(1)
        NotificationCenter.default.addObserver(self, selector: #selector(stopJarAudit),
            name: UIApplication.willResignActiveNotification, object: nil)
        applyPadMode()
        if detachUI { installJarDetachShield() }
        runJarAudit(id: id, leg: 0, rows: [], results: [])
    }

    @objc private func stopJarAudit() {
        guard jarAuditID != nil else { return }
        jarAuditID = nil
        jarAuditWork?.cancel()
        jarAuditWork = nil
        if jarMainProfile { treo_afk_main_trace_cancel() }
        jarMainProfile = false
        if jarBudgetAudit { JarMainBudget.stop() }
        jarBudgetAudit = false
        jarCommitBudget?.stop()
        jarCommitBudget = nil
        jarCommitAudit = false
        jarUIKitPhaseBudget?.stop()
        jarUIKitPhaseBudget = nil
        jarUIKitPhaseAudit = false
        if jarEnergyAudit {
            if let prior = jarEnergyOldIdleTimer {
                UIApplication.shared.isIdleTimerDisabled = prior
            }
            if let prior = jarEnergyOldMonitoring {
                UIDevice.current.isBatteryMonitoringEnabled = prior
            }
        }
        jarEnergyAudit = false
        jarEnergyOldMonitoring = nil
        jarEnergyOldIdleTimer = nil
        jarEnergyLeg = -1
        jarEnergySamples.removeAll()
        treo_jar_sparse_paint_set(0)
        jarSparsePaintAudit = false
        jarMainBenchLeg = -1
        jarMainBenchSamples.removeAll()
        if jarMainQoSAudit {
            jarMainQoSRestoreStatus = treo_main_qos_finish()
            jarMainQoSAudit = false
            if jarMainQoSRestoreStatus != 0 {
                NSLog("[J2ME Treo] WARNING: main QoS restore failed (\(jarMainQoSRestoreStatus))")
            }
        }
        treo_display_wait_set(0)
        jarDisplayWaitAudit = false
        if jarWindowAudit { restoreJarProbeWindow() }
        jarWindowAudit = false
        if jarDetachAudit {
            restoreJarGameViews()
            jarDetachShield?.removeFromSuperview()
            jarDetachShield = nil
            jarDetachAudit = false
        }
        treo_jar_load_set(0)
        jarLoadComparison = false
        jarWorkerComparison = false
        treo_jar_audit_set(0)
        treo_afk_wakes_set(0)
        treo_render_set_afk_mode(0)
        treo_game_jit_set_enabled(jarAuditJIT)
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        applyPadMode()
    }

    private func scheduleJarAudit(id: UUID, after seconds: Double, _ action: @escaping () -> Void) {
        let work = DispatchWorkItem { [weak self] in
            guard self?.jarAuditID == id else { return }
            action()
        }
        jarAuditWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private struct JarPowerSnapshot {
        let battery = Double(UIDevice.current.batteryLevel)
        let state = UIDevice.current.batteryState
        let thermal = ProcessInfo.processInfo.thermalState
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let brightness = Double(UIScreen.main.brightness)

        var unplugged: Bool { state == .unplugged && battery >= 0 }
        var thermalName: String {
            switch thermal {
            case .nominal: return "nominal"
            case .fair: return "fair"
            case .serious: return "serious"
            case .critical: return "critical"
            @unknown default: return "unknown"
            }
        }
    }

    private func scheduleJarEnergySample(id: UUID, leg: Int, remaining: Int) {
        guard remaining > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.jarAuditID == id, self.jarEnergyAudit,
                  self.jarEnergyLeg == leg else { return }
            self.jarEnergySamples.append(JarPowerSnapshot())
            self.scheduleJarEnergySample(id: id, leg: leg, remaining: remaining - 1)
        }
    }

    private func scheduleJarMainBench(id: UUID, leg: Int, left: Int) {
        guard left > 0 else { return }
        let interval = jarEnergyAudit ? 7.0 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.jarAuditID == id,
                  (self.jarUIKitPhaseAudit || self.jarSparsePaintAudit || self.jarEnergyAudit),
                  self.jarMainBenchLeg == leg else { return }
            let time = treo_main_fixed_work_ns_per_step()
            if time > 0 { self.jarMainBenchSamples.append(time) }
            self.scheduleJarMainBench(id: id, leg: leg, left: left - 1)
        }
    }

    private struct JarAuditResult {
        let total: Double?
        let main: Double?
        let ticks: Double
        let paint: Double
        let budget: [Double]?
        let commit: JarCommitBudget.Result?
        let phases: JarUIKitPhaseBudget.Result?
        let mainBenchNS: Double?
        let sparseRate: Double
        let actualPaintRate: Double
        let batteryDropPerHour: Double?
        let energyStable: Bool
        let loadCPU: Double
        let loadRate: Double
    }

    private func runJarAudit(id: UUID, leg: Int, rows: [String], results: [JarAuditResult]) {
        // Energy audit measures ACTUAL usage: normal game presents frames,
        // JAR treo does not. CPU microbench audits still suppress both arms.
        treo_render_set_afk_mode(jarEnergyAudit ? 0 : 1)
        let sparseAudit = jarSparsePaintAudit
        let sparseHz: Int32 = sparseAudit ? (leg == 1 ? 1 : leg == 2 ? 3 : 0) : 0
        treo_jar_sparse_paint_set(sparseHz)
        let qosAudit = jarMainQoSAudit
        let qosMode: Int32 = leg == 1 ? 1 : leg == 2 ? 2 : 0
        if qosAudit {
            let code = treo_main_qos_apply(qosMode)
            guard code == 0 else {
                finishJarAudit(rows: rows + ["KHÔNG HỢP LỆ: đổi QoS main thất bại ở lượt \(leg), lỗi \(code)."], results: [])
                return
            }
        }
        let displayAudit = jarDisplayWaitAudit
        treo_display_wait_set(displayAudit && leg == 1 ? 1 : 0)
        let workerCompare = jarWorkerComparison
        let loadMode: Int32 = workerCompare ? (leg == 1 ? 1 : leg == 2 ? 3 : 0)
            : (jarLoadComparison && (leg == 1 || leg == 2) ? Int32(leg) : 0)
        treo_jar_load_set(loadMode)
        let detachUI = jarDetachAudit
        let windowAudit = jarWindowAudit
        if windowAudit {
            if leg == 1 {
                guard installJarProbeWindow() else {
                    finishJarAudit(rows: rows + ["Không hợp lệ: không tạo được cửa sổ đen foreground."], results: [])
                    return
                }
            } else if leg == 2 {
                restoreJarProbeWindow()
            }
        }
        if detachUI {
            if leg == 1 {
                guard detachJarGameViews() else {
                    finishJarAudit(rows: rows + ["Không hợp lệ: không tháo được cây view game."], results: [])
                    return
                }
            } else if leg == 2 {
                restoreJarGameViews()
            }
        }
        let settleOn = treo_jar_audit_ticks(1)
        let settleOff = treo_jar_audit_ticks(0)
        scheduleJarAudit(id: id, after: 3) { [weak self] in
            guard let self else { return }
            if self.jarUIKitPhaseAudit || self.jarSparsePaintAudit || self.jarEnergyAudit {
                let observedOn = treo_jar_audit_ticks(1) &- settleOn
                let observedOff = treo_jar_audit_ticks(0) &- settleOff
                let expectedOn = self.jarSparsePaintAudit || leg == 1
                guard (expectedOn && observedOn > 0 && observedOff == 0)
                    || (!expectedOn && observedOff > 0 && observedOn == 0) else {
                    self.finishJarAudit(rows: rows + [
                        "DỪNG TRƯỚC KHI ĐO: lượt \(self.jarSparsePaintAudit ? (leg == 0 ? "A1" : leg == 1 ? "B" : leg == 2 ? "C" : "A2") : (leg == 1 ? "B" : leg == 0 ? "A1" : "A2")) yêu cầu JAR \(expectedOn ? "BẬT" : "TẮT") treo; 3 giây chuẩn bị có \(observedOn) tick bật / \(observedOff) tick tắt. Chỉnh trạng thái trong game rồi chạy lại."
                    ], results: [])
                    return
                }
            }
            if detachUI && leg == 1 && !self.isJarGameUIActuallyDetached() {
                self.finishJarAudit(rows: rows + ["Không hợp lệ: cây view không còn tách ở đầu lượt B."], results: [])
                return
            }
            let detachedCount = self.jarDetachedViews.count
            treo_afk_threads_begin()
            let start = JarAuditSample()
            let profileMain = self.jarMainProfile
            let budgetMain = self.jarBudgetAudit
            let sourceProfile = budgetMain && profileMain
            let powerStart: JarPowerSnapshot? = self.jarEnergyAudit ? JarPowerSnapshot() : nil
            if self.jarEnergyAudit {
                self.jarEnergyLeg = leg
                self.jarEnergySamples.removeAll()
                self.scheduleJarEnergySample(id: id, leg: leg, remaining: 3)
            }
            if self.jarUIKitPhaseAudit || self.jarSparsePaintAudit || self.jarEnergyAudit {
                self.jarMainBenchLeg = leg
                self.jarMainBenchSamples.removeAll()
                self.scheduleJarMainBench(id: id, leg: leg, left: 12)
            }
            if budgetMain { JarMainBudget.start(sampleSource: sourceProfile) }
            if self.jarUIKitPhaseAudit, #available(iOS 18.0, *) {
                let phaseBudget = JarUIKitPhaseBudget()
                self.jarUIKitPhaseBudget = phaseBudget
                phaseBudget.start(in: self.view)
            }
            if self.jarCommitAudit, #available(iOS 18.0, *) {
                let commitBudget = JarCommitBudget()
                self.jarCommitBudget = commitBudget
                commitBudget.start(in: (windowAudit && leg == 1
                    ? (self.jarProbeWindow?.rootViewController?.view ?? self.view) : self.view))
            }
            if sourceProfile { treo_afk_main_source_trace_begin() }
            else if profileMain { treo_afk_main_stack_begin() }
            self.scheduleJarAudit(id: id, after: self.jarEnergyAudit ? 120 : (profileMain && !sourceProfile ? 20 : ((self.jarMainQoSAudit || self.jarDisplayWaitAudit || self.jarUIKitPhaseAudit || self.jarSparsePaintAudit) ? 30 : (self.jarWindowAudit ? 25 : (self.jarWorkerComparison ? 30 : (self.jarLoadComparison ? 25 : 60))))) { [weak self] in
                guard let self else { return }
                let end = JarAuditSample()
                let powerEnd: JarPowerSnapshot? = self.jarEnergyAudit ? JarPowerSnapshot() : nil
                let energySamples = self.jarEnergySamples
                self.jarEnergyLeg = -1
                let dt = max(0.001, end.base.time - start.base.time)
                let on = end.on &- start.on, off = end.off &- start.off
                let compareLoad = self.jarLoadComparison
                let workerCompare = self.jarWorkerComparison
                let names = self.jarEnergyAudit
                    ? ["A1 · JAR tắt (pin)", "B · JAR bật (pin)", "A2 · JAR tắt lại (pin)"]
                    : sparseAudit
                    ? ["A1 · Không paint", "B · Paint 1 Hz", "C · Paint 3 Hz", "A2 · Không paint"]
                    : qosAudit
                    ? ["A1 · QoS gốc", "B · User Initiated", "C · Utility", "A2 · QoS gốc"]
                    : displayAudit
                    ? ["A1 · Display polling", "B · Display chờ sự kiện", "A2 · Display polling"]
                    : windowAudit
                    ? ["A1 · Cửa sổ game", "B · Chỉ cửa sổ đen", "A2 · Cửa sổ game"]
                    : workerCompare
                    ? ["A1 · Không tải", "B · Tải trên game", "C · Tải trên pthread", "A2 · Không tải"]
                    : detachUI
                    ? ["A1 · Gắn UI", "B · Tháo UI", "A2 · Gắn lại UI"]
                    : compareLoad
                    ? ["A1 · Mốc đầu", "B · Xung tính toán", "C · Chờ thụ động", "A2 · Mốc cuối"]
                    : ["A1 · JAR tắt", "B · JAR bật", "A2 · JAR tắt"]
                let total = end.base.cpuPercent(since: start.base)
                let paint = Double(end.base.paintNS &- start.base.paintNS) / dt / 10_000_000
                let paints = Double(end.base.paints &- start.base.paints) / dt
                let main: Double? = start.base.mainCPU >= 0 && end.base.mainCPU >= start.base.mainCPU
                    ? 100 * (end.base.mainCPU - start.base.mainCPU) / dt : nil
                let budget = budgetMain ? JarMainBudget.finish(wall: dt, mainPercent: main) : nil
                let commit = self.jarCommitBudget?.finish(wall: dt)
                self.jarCommitBudget = nil
                let phases = self.jarUIKitPhaseBudget?.finish(wall: dt)
                self.jarUIKitPhaseBudget = nil
                let bench = self.jarMainBenchSamples.sorted()
                let mainBenchNS: Double? = (self.jarUIKitPhaseAudit || self.jarSparsePaintAudit || self.jarEnergyAudit) && bench.count >= 6
                    ? (bench.count.isMultiple(of: 2)
                        ? (bench[bench.count / 2 - 1] + bench[bench.count / 2]) / 2
                        : bench[bench.count / 2])
                    : nil
                self.jarMainBenchLeg = -1
                let ticks = Double(on + off) / dt
                let frames = end.frames &- start.frames
                let cpuText = total.map { String(format: "%.1f%%", $0) } ?? "?"
                let mainText = main.map { String(format: "%.1f%%", $0) } ?? "?"
                var row = "\(names[leg]): \(cpuText) tổng · \(mainText) main"
                row += String(format: "\n%.1f s · %.1f%% trong paint · %.2f paint/s · %.1f wake/s",
                    dt, paint, paints, Double(end.wakes &- start.wakes) / dt)
                row += String(format: "\n%.2f vòng game/s", ticks)
                row += " · \(off) tick tắt / \(on) tick bật · \(frames) khung lên layer"
                let validState = (detachUI || compareLoad || workerCompare || windowAudit || displayAudit || qosAudit || sparseAudit || leg == 1) ? (on > 0 && off == 0) : (off > 0 && on == 0)
                let validUI = !detachUI || leg != 1 || self.isJarGameUIActuallyDetached()
                let validWindow = !windowAudit
                    || (leg == 1 ? self.isJarProbeWindowVisible()
                        : (self.jarProbeWindow == nil && self.view.window?.isHidden == false
                            && self.view.window?.windowScene?.activationState == .foregroundActive
                            && UIApplication.shared.applicationState == .active))
                if qosAudit {
                    let expected = treo_main_qos_expected(qosMode)
                    let actual = treo_main_qos_current()
                    row += "\nQoS main: mong đợi \(expected) · đọc lại \(actual)"
                    row += " · \(expected == actual ? "hợp lệ" : "KHÔNG HỢP LỆ")"
                }
                if windowAudit {
                    row += "\nTrạng thái: \(UIApplication.shared.applicationState == .active ? "app active" : "app không active")"
                    row += " · \(validWindow ? "cửa sổ đúng điều kiện" : "KHÔNG HỢP LỆ: cửa sổ/scene đổi trạng thái")"
                }
                if detachUI {
                    row += "\n\(detachedCount) view gốc đã tháo · \(self.view.subviews.count) view con, \(self.view.layer.sublayers?.count ?? 0) layer con còn ở view game"
                    if !validUI { row += "\nKhông hợp lệ: cây view không còn tách ở cuối lượt B." }
                }
                if !validState { row += "\nKhông hợp lệ: tick không đúng trạng thái trong lượt." }
                if !self.jarEnergyAudit && frames != 0 {
                    row += "\nKhông hợp lệ: vẫn có khung lên layer."
                }
                if self.jarEnergyAudit && leg != 1 && frames == 0 {
                    row += "\nKHÔNG HỢP LỆ: lượt game thường không xuất khung hình."
                }
                var batteryDropPerHour: Double?
                var energyStable = true
                if self.jarEnergyAudit {
                    let snapshots = ([powerStart].compactMap { $0 }) + energySamples +
                        ([powerEnd].compactMap { $0 })
                    if let startPower = powerStart, let endPower = powerEnd {
                        if startPower.battery >= 0 && endPower.battery >= 0 {
                            let points = 100 * (startPower.battery - endPower.battery)
                            batteryDropPerHour = points * 3600 / dt
                            row += String(format: "\nPin: %.0f%% → %.0f%% · hao %+.2f điểm/%.1f phút · %.2f điểm/giờ (ước lượng thô).",
                                startPower.battery * 100, endPower.battery * 100, points, dt / 60,
                                batteryDropPerHour ?? 0)
                        }
                        row += "\nNhiệt: \(startPower.thermalName) → \(endPower.thermalName) (trạng thái iOS, không phải °C)"
                        let nominal = snapshots.filter { $0.thermal == .nominal }.count
                        let fair = snapshots.filter { $0.thermal == .fair }.count
                        let serious = snapshots.filter { $0.thermal == .serious }.count
                        let critical = snapshots.filter { $0.thermal == .critical }.count
                        row += "\nMẫu nhiệt: nominal \(nominal) · fair \(fair) · serious \(serious) · critical \(critical)"
                        row += String(format: "\nĐộ sáng: %.3f → %.3f · mẫu kiểm tra: %d · Low Power Mode: %@ → %@",
                            startPower.brightness, endPower.brightness, snapshots.count,
                            startPower.lowPower ? "bật" : "tắt", endPower.lowPower ? "bật" : "tắt")
                        energyStable = snapshots.count >= 3 && snapshots.allSatisfy {
                            $0.unplugged && abs($0.brightness - startPower.brightness) <= 0.02
                            && $0.lowPower == startPower.lowPower
                        }
                    } else { energyStable = false }
                    if !energyStable { row += "\nKHÔNG HỢP LỆ: đổi sạc/độ sáng/chế độ nguồn hoặc thiếu mẫu pin." }
                }
                let sparseRate = Double(end.sparseDue &- start.sparseDue) / dt
                if sparseAudit {
                    row += String(format: "\nPaint thưa: đặt %d Hz · gọi ép %.2f/s · paint Java thực %.2f/s.",
                                  sparseHz, sparseRate, paints)
                }
                let displayPolls = Double(end.displayPolls &- start.displayPolls) / dt
                let displayWaits = Double(end.displayWaits &- start.displayWaits) / dt
                let displayGcSafeWaits = Double(end.displayGcSafeWaits &- start.displayGcSafeWaits) / dt
                let displayTimeouts = Double(end.displayTimeouts &- start.displayTimeouts) / dt
                let displaySignals = Double(end.displaySignals &- start.displaySignals) / dt
                if displayAudit {
                    row += String(format: "\nDisplay: %.2f poll/s · %.2f native wait/s · %.2f GC-safe wait/s · %.2f timeout/s · %.2f tín hiệu/s",
                                  displayPolls, displayWaits, displayGcSafeWaits, displayTimeouts, displaySignals)
                    if leg == 1 && (displayWaits < 1 || abs(displayGcSafeWaits - displayWaits) > 0.1) {
                        row += "\nKHÔNG HỢP LỆ: B không thực sự chờ, hoặc chưa khai báo trạng thái chờ với GC."
                    }
                }
                if let raw = treo_afk_threads_report(dt) {
                    row += "\n" + String(cString: raw)
                    free(raw)
                }
                if profileMain, let raw = treo_afk_main_trace_end() {
                    row += "\n" + String(cString: raw)
                    free(raw)
                }
                if budgetMain {
                    if let budget {
                        row += "\nCPU main (ms/s): " + JarMainBudget.detail(budget)
                    } else {
                        row += "\nKhông đủ mốc hợp lệ để chia CPU theo pha."
                    }
                }
                if let commit { row += "\n" + commit.detail }
                if self.jarUIKitPhaseAudit || sparseAudit || self.jarEnergyAudit {
                    if let mainBenchNS {
                        row += String(format: "\nViệc cố định main: %.3f ns/phép · %d mẫu (median); chỉ kiểm tra tốc độ tính toán, không đo xung CPU.",
                                      mainBenchNS, bench.count)
                    } else {
                        row += "\nViệc cố định main: KHÔNG ĐỦ MẪU"
                    }
                }
                if let phases {
                    row += "\n" + phases.detail
                    if let main {
                        let covered = phases.cpuMSPerSecond.reduce(0, +)
                        row += String(format: "\nMain ngoài 6 khoảng UIKit đo được: %.1f ms CPU/s (không gán cho framework).",
                                      main * 10 - covered)
                    }
                }
                if compareLoad || workerCompare {
                    let calls = end.loadCalls &- start.loadCalls
                    let wall = Double(end.loadWall &- start.loadWall) / Double(max(1, calls)) / 1_000_000
                    row += String(format: "\nCPU xung: %.1f điểm · thời gian thực/xung: %.2f ms · %.2f xung/s · %llu xung",
                        Double(end.loadNS &- start.loadNS) / dt / 10_000_000, wall, Double(calls) / dt, calls)
                    if workerCompare {
                        row += "\nQoS game: \(treo_jar_load_game_qos()) · QoS pthread: \(treo_jar_load_worker_qos())"
                    }
                }
                let all = rows + [row]
                let validDisplay = !displayAudit || leg != 1 ||
                    (displayWaits >= 1 && abs(displayGcSafeWaits - displayWaits) <= 0.1)
                let validQoS = !qosAudit || treo_main_qos_expected(qosMode) == treo_main_qos_current()
                let validEnergy = !self.jarEnergyAudit || energyStable
                let targetHz = Double(sparseHz)
                let validSparse = !sparseAudit || (targetHz == 0
                    ? (sparseRate <= 0.15 && paints <= 0.15)
                    : (abs(sparseRate - targetHz) <= 0.45
                       && abs(paints - targetHz) <= 0.45))
                if !validSparse { row += "\nKHÔNG HỢP LỆ: paint thực tế khác tần suất yêu cầu." }
                let validFrames = self.jarEnergyAudit ? (leg == 1 || frames > 0) : frames == 0
                guard validState && validUI && validWindow && validDisplay && validQoS && validSparse && validEnergy && validFrames else {
                    self.finishJarAudit(rows: all, results: [])
                    return
                }
                let measured = results + [JarAuditResult(total: total, main: main, ticks: ticks, paint: paint,
                    budget: budget, commit: commit, phases: phases, mainBenchNS: mainBenchNS,
                    sparseRate: sparseRate, actualPaintRate: paints,
                    batteryDropPerHour: batteryDropPerHour, energyStable: energyStable,
                    loadCPU: Double(end.loadNS &- start.loadNS) / dt / 10_000_000,
                    loadRate: Double(end.loadCalls &- start.loadCalls) / dt)]
                if workerCompare && leg == 1 {
                    treo_jar_load_worker_period_set(UInt64((1_000_000_000.0 / max(1.0, ticks)).rounded()))
                }
                if leg == (compareLoad || workerCompare || qosAudit || sparseAudit ? 3 : 2) || (profileMain && !sourceProfile && leg == 1) {
                    self.finishJarAudit(rows: all, results: measured)
                } else if compareLoad || workerCompare || detachUI || windowAudit || displayAudit || qosAudit || sparseAudit {
                    self.runJarAudit(id: id, leg: leg + 1, rows: all, results: measured)
                } else {
                    self.promptJarAudit(id: id, nextLeg: leg + 1, rows: all, results: measured)
                }
            }
        }
    }

    private func promptJarAudit(id: UUID, nextLeg: Int, rows: [String], results: [JarAuditResult]) {
        treo_render_set_afk_mode(0)
        let turnOn = nextLeg == 1
        let target: Int32 = turnOn ? 1 : 0
        let previous = treo_jar_audit_ticks(target)
        let alert = UIAlertController(title: turnOn ? "Bật treo trong game" : "Thoát treo trong game",
            message: turnOn
                ? "Bấm OK, vào menu game và bật Treo tối ưu CPU. Sau đó không chạm game."
                : "Bấm OK, rồi chạm một lần vào vùng game để thoát treo. Sau đó không chạm game.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel) { [weak self] _ in self?.stopJarAudit() })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.waitForJarAudit(id: id, nextLeg: nextLeg, target: target, previous: previous,
                                 tries: 240, rows: rows, results: results)
        })
        present(alert, animated: true)
    }

    private func waitForJarAudit(id: UUID, nextLeg: Int, target: Int32, previous: UInt64,
                                 tries: Int, rows: [String], results: [JarAuditResult]) {
        guard jarAuditID == id else { return }
        if treo_jar_audit_ticks(target) != previous {
            runJarAudit(id: id, leg: nextLeg, rows: rows, results: results)
        } else if tries == 0 {
            finishJarAudit(rows: rows + ["Không nhận được tick ở trạng thái mới."], results: [])
        } else {
            scheduleJarAudit(id: id, after: 0.25) { [weak self] in
                self?.waitForJarAudit(id: id, nextLeg: nextLeg, target: target, previous: previous,
                                      tries: tries - 1, rows: rows, results: results)
            }
        }
    }

    private func finishJarAudit(rows: [String], results: [JarAuditResult]) {
        let profileMain = jarMainProfile
        let compareLoad = jarLoadComparison
        let workerCompare = jarWorkerComparison
        let windowAudit = jarWindowAudit
        let displayAudit = jarDisplayWaitAudit
        let qosAudit = jarMainQoSAudit
        let phaseAudit = jarUIKitPhaseAudit
        let sparseAudit = jarSparsePaintAudit
        let energyAudit = jarEnergyAudit
        let budgetMain = jarBudgetAudit
        let detachUI = jarDetachAudit
        let measureCommit = jarCommitAudit
        stopJarAudit()
        let qosRestoreNote = qosAudit
            ? "\nKhôi phục QoS main: " + (jarMainQoSRestoreStatus == 0
                ? "OK" : "LỖI \(jarMainQoSRestoreStatus) — hãy khởi động lại app")
            : ""
        if profileMain && !budgetMain {
            publishMeasurement(title: "Tìm hàm ăn CPU main", message:
                "JIT tắt · cùng chặn khung game ở hai lượt. CPU chỉ để tham khảo vì có sampler; dùng chuỗi gọi để đối chiếu. Mẫu runnable không đồng nghĩa thời gian CPU.\n\n"
                + rows.joined(separator: "\n\n"))
            return
        }
        var summary = ""
        if sparseAudit && results.count == 4 {
            let a = results[0], b = results[1], c = results[2], d = results[3]
            let referenceTotal = ((a.total ?? 0) + (d.total ?? 0)) / 2
            let referenceMain = ((a.main ?? 0) + (d.main ?? 0)) / 2
            summary = String(format: "So với A1/A2 không paint: B 1Hz tổng %+.1f điểm · main %+.1f điểm; C 3Hz tổng %+.1f điểm · main %+.1f điểm.\n",
                (b.total ?? 0) - referenceTotal, (b.main ?? 0) - referenceMain,
                (c.total ?? 0) - referenceTotal, (c.main ?? 0) - referenceMain)
            summary += String(format: "Nhịp game: A1 %.2f · B %.2f · C %.2f · A2 %.2f tick/s.\n",
                                     a.ticks, b.ticks, c.ticks, d.ticks)
            summary += String(format: "Paint thực: %.2f · %.2f · %.2f · %.2f paint/s.\n",
                                     a.actualPaintRate, b.actualPaintRate, c.actualPaintRate, d.actualPaintRate)
            if let x = a.mainBenchNS, let y = b.mainBenchNS, let z = c.mainBenchNS, let w = d.mainBenchNS {
                let baseline = (x + w) / 2
                summary += String(format: "Việc cố định main: A1 %.3f · B %.3f · C %.3f · A2 %.3f ns/phép. B/A %.2f× · C/A %.2f×.\n",
                    x, y, z, w, y / max(0.001, baseline), z / max(0.001, baseline))
            }
            let baselineTicks = (a.ticks + d.ticks) / 2
            if abs(b.ticks - baselineTicks) > 0.5 || abs(c.ticks - baselineTicks) > 0.5
                || abs(a.ticks - d.ticks) > 0.5 {
                summary += "KHÔNG KẾT LUẬN: nhịp game lệch trên 0,5 tick/s.\n"
            }
            if abs((a.total ?? 0) - (d.total ?? 0)) > 4 {
                summary += "CẢNH BÁO: A1/A2 trôi trên 4 điểm CPU tổng.\n"
            }
            summary += "Đây chỉ là thử ép paint có thể đổi hành vi JAR; KHÔNG kích hoạt mặc định.\n\n"
        }
        if qosAudit && results.count == 4 {
            let a = results[0], b = results[1], c = results[2], d = results[3]
            let baseTotal = ((a.total ?? 0) + (d.total ?? 0)) / 2
            let baseMain = ((a.main ?? 0) + (d.main ?? 0)) / 2
            summary = String(format: "B User Initiated: tổng %+.1f · main %+.1f điểm. C Utility: tổng %+.1f · main %+.1f điểm.\n",
                (b.total ?? 0) - baseTotal, (b.main ?? 0) - baseMain,
                (c.total ?? 0) - baseTotal, (c.main ?? 0) - baseMain)
            summary += String(format: "Nhịp game: A1 %.2f · B %.2f · C %.2f · A2 %.2f vòng/s.\n",
                a.ticks, b.ticks, c.ticks, d.ticks)
            if abs(b.ticks - (a.ticks + d.ticks) / 2) > 0.5
                || abs(c.ticks - (a.ticks + d.ticks) / 2) > 0.5 {
                summary += "KHÔNG KẾT LUẬN: QoS làm thay đổi nhịp game >0,5/s.\n"
            }
            if abs((a.total ?? 0) - (d.total ?? 0)) > 3
                || abs((a.main ?? 0) - (d.main ?? 0)) > 3 {
                summary += "CẢNH BÁO: A1/A2 trôi >3 điểm, cần thận trọng với thay đổi nhỏ.\n"
            }
            let comm = results.compactMap(\.commit)
            if comm.count == 4 {
                summary += String(format: "CPU quanh mốc UIKit: %.1f · %.1f · %.1f · %.1f ms/s.\n",
                    comm[0].millisecondsPerSecond, comm[1].millisecondsPerSecond,
                    comm[2].millisecondsPerSecond, comm[3].millisecondsPerSecond)
            }
            summary += "\n"
        }
        if workerCompare && results.count == 4 {
            let a = results[0], b = results[1], c = results[2], d = results[3]
            let baselineMain = ((a.main ?? 0) + (d.main ?? 0)) / 2
            summary = String(format: "B tải game: main %+.1f điểm · tổng %.1f%% · tải %.1f điểm.\nC tải pthread: main %+.1f điểm · tổng %.1f%% · tải %.1f điểm.\n",
                             (b.main ?? 0) - baselineMain, b.total ?? -1, b.loadCPU,
                             (c.main ?? 0) - baselineMain, c.total ?? -1, c.loadCPU)
            summary += String(format: "B/C: chênh tải %+.1f điểm · chênh tick %+.2f/s · xung %.2f/%.2f mỗi giây.\n",
                              c.loadCPU - b.loadCPU, c.ticks - b.ticks, b.loadRate, c.loadRate)
            if abs(c.loadCPU - b.loadCPU) > 3.0 || abs(c.ticks - b.ticks) > 0.5 || c.loadRate < 15 || b.loadRate < 15 {
                summary += "KHÔNG TƯƠNG ĐƯƠNG: tải hoặc nhịp lệch; không dùng để quy nguyên nhân.\n"
            }
            if let ab = a.budget, let bb = b.budget, let cb = c.budget, let db = d.budget {
                let idx = JarMainBudget.Group.allCases.firstIndex(where: { $0.label == "Sau mốc Source" })
                if let idx {
                    summary += String(format: "Sau Source: A1 %.1f · B %.1f · C %.1f · A2 %.1f ms/s.\n", ab[idx], bb[idx], cb[idx], db[idx])
                }
            }
            let uc = results.compactMap(\.commit)
            if uc.count == 4 {
                summary += String(format: "UIKit mốc commit: A1 %.1f · B %.1f · C %.1f · A2 %.1f ms CPU/s.\n",
                    uc[0].millisecondsPerSecond, uc[1].millisecondsPerSecond, uc[2].millisecondsPerSecond, uc[3].millisecondsPerSecond)
            }
            summary += "\n"
        }
        if results.count == 3 {
            let a = results[0], b = results[1], c = results[2]
            func delta(_ x: Double?, _ y: Double?, _ z: Double?) -> String {
                guard let x, let y, let z else { return "?" }
                return String(format: "%+.1f", y - (x + z) / 2)
            }
            summary = "B − trung bình A1/A2: \(delta(a.total, b.total, c.total)) điểm tổng; "
                + "\(delta(a.main, b.main, c.main)) điểm main; \(delta(a.paint, b.paint, c.paint)) điểm trong paint; "
                + "\(delta(a.ticks, b.ticks, c.ticks)) vòng/s.\nĐối chiếu B với từng mốc A bên dưới.\n\n"
            if windowAudit || displayAudit {
                let expectedTicks = (a.ticks + c.ticks) / 2
                if abs(b.ticks - expectedTicks) > 0.5 || abs(a.ticks - c.ticks) > 0.5 {
                    summary += "KHÔNG KẾT LUẬN: nhịp game lệch quá 0,5 vòng/s giữa các lượt.\n\n"
                }
                let threeCommits = results.compactMap(\.commit)
                if threeCommits.count == 3 {
                    summary += String(format: "Mốc UIKit: A1 %.2f · B %.2f · A2 %.2f cặp/s; CPU %.1f · %.1f · %.1f ms/s.\n\n",
                        threeCommits[0].pairsPerSecond, threeCommits[1].pairsPerSecond, threeCommits[2].pairsPerSecond,
                        threeCommits[0].millisecondsPerSecond, threeCommits[1].millisecondsPerSecond, threeCommits[2].millisecondsPerSecond)
                }
            }
        }
        if energyAudit && results.count == 3 {
            let a = results[0], b = results[1], c = results[2]
            summary += "THỬ PIN/NHIỆT DÀI HẠN (không đo watt hay nhiệt độ °C)\n"
            summary += String(format: "CPU tổng A1 %.1f%% · B %.1f%% · A2 %.1f%%; tick %.2f · %.2f · %.2f/s.\n",
                a.total ?? -1, b.total ?? -1, c.total ?? -1, a.ticks, b.ticks, c.ticks)
            if let x = a.batteryDropPerHour, let y = b.batteryDropPerHour,
               let z = c.batteryDropPerHour {
                let reference = (x + z) / 2
                summary += String(format: "Hao pin ước lượng A1 %.2f · B %.2f · A2 %.2f điểm phần trăm/giờ; B − A = %+.2f điểm/giờ.\n", x, y, z, y - reference)
                summary += "Chỉ đo 2 phút/lượt: pin iOS làm tròn khoảng 1%, nên tốc độ quy đổi theo giờ có thể sai rất lớn. KHÔNG kết luận tiết kiệm năng lượng chỉ từ chênh pin; ưu tiên CPU, tick, tốc độ main và trạng thái nhiệt.\n"
            } else { summary += "Không đọc được mức pin, không kết luận hao năng lượng.\n" }
            if abs(b.ticks - (a.ticks + c.ticks) / 2) > 0.5 ||
               abs(a.ticks - c.ticks) > 0.5 {
                summary += "KHÔNG KẾT LUẬN: tick game lệch trên 0,5/s.\n"
            }
            if abs((a.total ?? 0) - (c.total ?? 0)) > 5 {
                summary += "CẢNH BÁO: CPU A1/A2 trôi hơn 5 điểm; điều kiện có thể thay đổi.\n"
            }
            if !a.energyStable || !b.energyStable || !c.energyStable {
                summary += "KHÔNG KẾT LUẬN: điều kiện pin/độ sáng/nguồn không ổn định.\n"
            }
            summary += "\n"
        }
        if phaseAudit && results.count == 3 {
            let a = results[0], b = results[1], c = results[2]
            if let x = a.mainBenchNS, let y = b.mainBenchNS, let z = c.mainBenchNS {
                let baseline = (x + z) / 2
                summary += String(format: "Tốc độ việc tính toán cố định trên main (ns/phép): A1 %.3f · B %.3f · A2 %.3f; B/A %.2f lần.\n",
                                  x, y, z, y / max(0.001, baseline))
                if y > baseline * 1.7 {
                    summary += "GỢI Ý: cùng một phép tính chạy chậm hơn rõ khi treo JAR bật; kiểm tra hiệu năng lõi/tần số, chưa quy nguyên nhân cho core.\n"
                } else {
                    summary += "GỢI Ý: không thấy chậm tương ứng trong phép tính cố định; phần CPU main tăng có thể do công việc/đường xử lý khác.\n"
                }
            } else {
                summary += "KHÔNG ĐỦ MẪU benchmark main để so tốc độ.\n"
            }
            let baselineTicks = (a.ticks + c.ticks) / 2
            if abs(b.ticks - baselineTicks) > 0.5 || abs(a.ticks - c.ticks) > 0.5 {
                summary += "KHÔNG KẾT LUẬN: nhịp game thay đổi hơn 0,5 vòng/s.\n"
            }
            if let x = a.total, let z = c.total, abs(x - z) > 4 {
                summary += "CẢNH BÁO: CPU tổng A1/A2 trôi quá 4 điểm.\n"
            }
            if let pa = a.phases, let pb = b.phases, let pc = c.phases,
               pa.valid && pb.valid && pc.valid {
                summary += "Chênh CPU giữa mốc UIKit, B − trung bình A1/A2 (ms CPU/s):\n"
                var deltaSum = 0.0
                for i in 0..<JarUIKitPhaseBudget.labels.count {
                    let delta = pb.cpuMSPerSecond[i] - (pa.cpuMSPerSecond[i] + pc.cpuMSPerSecond[i]) / 2
                    deltaSum += delta
                    summary += String(format: "%@: %+.1f\n", JarUIKitPhaseBudget.labels[i], delta)
                }
                summary += String(format: "Tổng 6 khoảng đo được: %+.1f ms CPU/s.\n", deltaSum)
                let fullMainDelta = ((b.main ?? 0) - ((a.main ?? 0) + (c.main ?? 0)) / 2) * 10
                summary += String(format: "Chênh main ngoài 6 khoảng đo được: %+.1f ms CPU/s.\n",
                                  fullMainDelta - deltaSum)
            } else {
                summary += "KHÔNG KẾT LUẬN: thiếu chu kỳ UIKit ghép đủ, hãy xem mốc lỗi từng lượt.\n"
            }
            let mainDelta = (b.main ?? 0) - ((a.main ?? 0) + (c.main ?? 0)) / 2
            summary += String(format: "Chênh CPU main toàn bộ: %+.1f điểm (%.1f ms/s). Không đồng nhất tổng khoảng UIKit với toàn main.\n\n",
                mainDelta, mainDelta * 10)
        }
        if budgetMain || energyAudit {
            if results.count == 3, let a = results[0].budget, let b = results[1].budget, let c = results[2].budget {
                let indices = JarMainBudget.Group.allCases
                let measured = indices.map { group in
                    let i = group.rawValue
                    return "\(group.label) \(String(format: "%+.1f", b[i] - (a[i] + c[i]) / 2))"
                }
                let i = indices.count
                let residual = String(format: "%+.1f", b[i] - (a[i] + c[i]) / 2)
                summary += "Chênh CPU main theo pha (ms/s): "
                    + (measured + ["Ngoài mốc \(residual)"]).joined(separator: " · ") + "\n\n"
            }
            if measureCommit, results.count == 3 {
                let commits = results.compactMap(\.commit)
                if commits.count == 3, commits.allSatisfy({ $0.pairs > 0 && $0.dropped <= max(2, $0.pairs / 100) }) {
                    let a = commits[0], b = commits[1], c = commits[2]
                    summary += String(format: "B − trung bình A1/A2 quanh commit UIKit: %+.1f ms CPU/s · %+.2f cặp/s · %+.3f ms CPU/cặp.\n\n",
                                      b.millisecondsPerSecond - (a.millisecondsPerSecond + c.millisecondsPerSecond) / 2,
                                      b.pairsPerSecond - (a.pairsPerSecond + c.pairsPerSecond) / 2,
                                      b.millisecondsPerPair - (a.millisecondsPerPair + c.millisecondsPerPair) / 2)
                } else {
                    summary += "Mốc UIKit không đủ hoặc lỗi ghép nhiều: không kết luận về commit.\n\n"
                }
            }
            let title = energyAudit ? "Đo hao pin & nhiệt · JAR" :
                sparseAudit ? "Thử paint thưa 1/3 Hz · JAR" :
                phaseAudit ? "Đo 6 pha UIKit · JAR" :
                qosAudit ? "Thử hạ QoS main · JAR" :
                displayAudit ? "Thử Display chờ sự kiện · JAR" :
                windowAudit ? "Thử cửa sổ đen foreground · JAR" :
                workerCompare ? "So tải game và luồng native · JAR" :
                measureCommit ? "Đo CPU quanh commit UIKit · JAR" :
                detachUI ? "Thử tháo giao diện game · JAR" :
                (profileMain ? "Tìm stack sau Source · JAR" : "Đo pha CPU main · JAR")
            let sampling = energyAudit
                ? "A1 tắt → B bật → A2 tắt, mỗi lượt 2 phút (6 phút tổng); không chặn khung game nên đo tình huống sử dụng thực tế (A1/A2 hiển thị game, B treo). JIT tắt suốt bài. Theo dõi getrusage CPU time, pin iOS, trạng thái nhiệt, độ sáng, Low Power Mode và tick. Mức pin ngắn hạn chỉ tham khảo, tốc độ %/giờ ngoại suy có sai số rất lớn; KHÔNG đo watt, nhiệt độ °C hoặc năng lượng riêng CPU."
                : sparseAudit
                ? "JAR treo BẬT suốt bốn lượt. A1/A2 không ép vẽ, B ép 1Hz, C ép 3Hz từ luồng Display; khung vẫn chặn ở native. Đo CPU tổng, main, nhịp game, paint thật và tốc độ việc cố định trên main. Không thay đổi vòng game, không sử dụng tải giả; paint có thể chứa logic và thử nghiệm tự hoàn nguyên."
                : phaseAudit
                ? "Tắt → bật → tắt Treo tối ưu CPU trong JAR. UIUpdateLink thụ động quan sát 7 mốc/6 khoảng. Mỗi lượt thêm 12 mẫu phép tính cố định rất ngắn trên main, đo ns CPU/phép để kiểm tra giả thuyết tốc độ CPU. Không đo xung, không tự nhận diện lõi. Phần CPU ngoài 6 khoảng báo riêng. Không đổi tốc độ vòng game."
                : qosAudit
                ? "A1/A2 giữ QoS main ban đầu; B User Initiated; C Utility. Chỉ đổi QoS main (API công khai), không tạo tải giả; đọc lại QoS từng lượt, khôi phục sau bài. QoS không trực tiếp đo tần số CPU."
                : displayAudit
                ? "A1/A2 chờ 16ms cũ; B chờ điều kiện GC-safe 250ms, thông báo miniJVM is_blocking trước wait và safepoint khi trở lại Java. Đo GC-safe wait/s cùng poll/wait/timeout/s, CPU tổng và game tick/s; bắt buộc nhịp game không lệch >0,5/s. Không đổi vòng game."
                : windowAudit
                ? "A1/A2 dùng cửa sổ game; B ẩn cửa sổ gốc và hiển thị UIWindow đen tối giản. App foreground-active cả ba lượt, không giả lập inactive. Mốc UIUpdateLink đo trên cửa sổ đang hiện; không coi đó là mọi commit QuartzCore."
                : workerCompare
                ? "B dùng tải CPU game; C dùng pthread riêng, cố gắng khớp QoS và tải 10 ms/xung. Cả hai chỉ là tải chẩn đoán; không coi main giảm là tổng giảm. Không lấy stack."
                : measureCommit
                ? "UIUpdateLink thụ động, không yêu cầu cập nhật liên tục. Chỉ đo CPU main giữa hai mốc UIKit; không đếm mọi commit QuartzCore. Không cộng số này vào CPU theo pha. Đối chiếu với mức tăng sau Source cũ (~253 ms/s); nếu không tái hiện thì không quy kết."
                : profileMain
                ? "Lấy mẫu sau Source. Kiểm tra chênh pha so với bài không lấy stack (~+253 ms/s); nếu lệch rõ thì không quy nguyên nhân từ mẫu. Số mẫu không phải CPU time."
                : (detachUI ? "JAR bật cả ba lượt. Tháo view con ở B; giữ controller, cửa sổ và VM. Không lấy stack." : "Không lấy stack.")
            publishMeasurement(title: title, message:
                "JIT tắt · FPS cap: \(fpsLimit) · \(sampling)\n\n" + summary +
                rows.joined(separator: "\n\n") + qosRestoreNote +
                "\n\n[ ]: số khoảng giữa mốc. Ngoài mốc = CPU main tổng trừ phần ghép được. Đồng hồ CPU không tính thời gian ngủ. Mốc đo chỉ gắn vào common modes; pha không định danh hàm hay framework.")
            return
        }
        let uiNote = compareLoad ? "\n\nTreo JAR bật suốt bài. B thêm tính toán, C ngủ bằng nanosleep tại cùng chỗ trên luồng game. C lấy thời lượng mục tiêu từ B; đối chiếu thời gian thực/xung và vòng game/s trước khi diễn giải. Chỉ C mới là ứng viên giảm CPU; không dùng B để tối ưu." : ""
        publishMeasurement(title: compareLoad ? "Thử chờ thụ động · CPU main" : "Chẩn đoán CPU JAR", message:
            "Giới hạn FPS Treo: \(fpsLimit) · JIT tắt trong phép đo.\n\n" + summary +
            rows.joined(separator: "\n\n") +
            "\n\nCả ba lượt chặn khung native, không đổi độ sáng. CPU quy về một lõi. game là luồng gọi helper mỗi vòng; paint* là luồng paint gần nhất, có thể trùng game, không cộng hai số này. Không đo GPU." + uiNote)
    }

    private struct GuardedSample {
        let cpu = AfkSample()
        let discarded = treo_afk_guarded_paints()
        let real = treo_afk_guarded_real()
        let late = treo_afk_guarded_late()
        let native = treo_afk_skipped_draws()
        let frames = treo_afk_layer_frames()
        let wakes = treo_afk_main_wakes()
        let software = treo_software_stats()
        let fast = treo_fast_canvas_stats()
    }

    private func confirmGuardedComparison() {
        guard blackout == nil, powerRun == nil else { return }
        let file = URL(fileURLWithPath: jarPath).lastPathComponent
        let alert = UIAlertController(title: "Thử treo không dựng hình",
            message: "JAR đang chạy: \(file)\nChỉ thử trên x1. App đo CPU từng luồng trong 3 lượt, rồi lấy mẫu chuỗi gọi main trong 2 lượt riêng. Mỗi lượt 60 giây. Có thể chạm màn đen để dừng và kiểm tra lại game. Màn đen thường không thay đổi.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Đo x1", style: .default) { [weak self] _ in
            self?.startGuardedComparison()
        })
        present(alert, animated: true)
    }

    private func startGuardedComparison(fast: Bool = false) {
        guard blackout == nil, powerRun == nil else { return }
        showBlackout()
        treo_afk_main_trace_cancel()
        let id = UUID()
        afkMeasureID = id
        guardedBlackout = true
        treo_afk_wakes_set(1)
        runGuardedLeg(id: id, index: 0, rows: [], fast: fast)
    }

    private func runGuardedLeg(id: UUID, index: Int, rows: [String], fast: Bool) {
        let tracing = index >= 3
        treo_render_set_afk_mode(index == 1 || index == 4 ? (fast ? 9 : 8) : 1)
        blackout?.setTitle("Đang đo \(index + 1)/\(fast ? 3 : 5) · Chạm để hủy", for: .normal)
        // CPU scoring and diagnostic stack sampling use disjoint windows.
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.afkMeasureID == id else { return }
            if tracing { treo_afk_main_stack_begin() }
            else { treo_afk_threads_begin() }
            let start = GuardedSample()
            let measure = DispatchWorkItem { [weak self] in
                guard let self, self.afkMeasureID == id else { return }
                let end = GuardedSample()
                if tracing {
                    let raw = treo_afk_main_trace_end()
                    let report = raw.map { String(cString: $0) } ?? "Không đọc được chuỗi gọi."
                    if let raw { free(raw) }
                    let name = index == 3 ? "Main · màn đen cũ" : "Main · không dựng hình"
                    let all = rows + [name + "\n" + report]
                    if index == 3 {
                        self.runGuardedLeg(id: id, index: 4, rows: all, fast: false)
                    } else {
                        // Restore ordinary blackout before presenting the report.
                        treo_render_set_afk_mode(1)
                        treo_afk_wakes_set(0)
                        self.afkMeasure = nil
                        self.afkMeasureID = nil
                        self.afkComparisonDone = true
                        self.lastMeasurement = ("Chẩn đoán CPU treo", all.joined(separator: "\n\n") +
                            "\n\nCPU quy về một lõi. Chuỗi FP lấy ở lượt riêng, có thể thiếu frame; số mẫu không phải CPU %. Không đo GPU %.")
                        self.blackout?.setTitle("Đo xong · Chạm xem kết quả", for: .normal)
                    }
                    return
                }
                let seconds = max(0.001, end.cpu.time - start.cpu.time)
                func percent(_ value: Double?) -> String {
                    value.map { String(format: "%.1f%%", $0) } ?? "?"
                }
                let main: Double? = start.cpu.mainCPU >= 0 && end.cpu.mainCPU >= start.cpu.mainCPU
                    ? 100 * (end.cpu.mainCPU - start.cpu.mainCPU) / seconds : nil
                let name = ["Cũ 1", fast ? "Canvas nhanh" : "Không dựng hình", "Cũ 2"][index]
                let paint = Double(end.cpu.paintNS &- start.cpu.paintNS) / seconds / 10_000_000
                let rate = Double(end.cpu.paints &- start.cpu.paints) / seconds
                let wakes = Double(end.wakes &- start.wakes) / seconds
                var row = "\(name): \(percent(end.cpu.cpuPercent(since: start.cpu))) tổng · \(percent(main)) main · \(percent(paint)) paint"
                row += String(format: "\n%.1f paint/s · %.1f wake/s · %llu khung lên layer", rate, wakes, end.frames &- start.frames)
                if index == 1 && fast {
                    row += "\nSIMD \(end.software.fast &- start.software.fast) · gọi tắt \(end.software.direct &- start.software.direct) · kiểm \(end.software.checked &- start.software.checked) · lệch \(end.software.mismatch &- start.software.mismatch)."
                    row += "\nTô nhanh \(end.fast.fills &- start.fast.fills) · kiểm \(end.fast.checks &- start.fast.checks) · lệch \(end.fast.mismatch &- start.fast.mismatch) · trạng thái trùng \(end.fast.state &- start.fast.state)."
                }
                if index == 1 && !fast {
                    row += "\nCanvas: \(end.discarded &- start.discarded) lượt bỏ raster · \(end.real &- start.real) lượt vẽ thật."
                    row += "\nNative bỏ \(end.native &- start.native) lệnh (không tính lệnh trả sớm ở Java)."
                    if end.late != start.late {
                        row += "\nCó truy cập pixel/handle phát hiện muộn: không xác nhận tương thích."
                    }
                }
                if let raw = treo_afk_threads_report(seconds) {
                    row += "\n" + String(cString: raw)
                    free(raw)
                }
                let all = rows + [row]
                if fast && index == 2 {
                    treo_afk_wakes_set(0)
                    self.afkMeasure = nil
                    self.afkMeasureID = nil
                    self.afkComparisonDone = true
                    self.lastMeasurement = ("So CPU · Canvas nhanh", all.joined(separator: "\n\n") +
                        "\n\nCùng màn đen, giữ nhịp paint và cấu hình JIT. CPU quy về một lõi. Không đo GPU %.")
                    self.blackout?.setTitle("Đo xong · Chạm xem kết quả", for: .normal)
                } else {
                    self.runGuardedLeg(id: id, index: index + 1, rows: all, fast: fast)
                }
            }
            self.afkMeasure = measure
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(60), execute: measure)
        }
        afkMeasure = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2), execute: settle)
    }

    private struct AfkSample {
        let time = ProcessInfo.processInfo.systemUptime
        let cpu = treo_process_cpu_seconds()
        let paints = treo_afk_paint_count()
        let paintNS = treo_afk_paint_cpu_ns()
        let bypassed = treo_afk_bypassed_paints()
        let mainCPU = treo_afk_current_thread_cpu()
        let jitCalls = treo_game_jit_call_count()
        let jitCompiled = treo_game_jit_compiled_count()

        func cpuPercent(since start: AfkSample) -> Double? {
            let seconds = time - start.time
            guard seconds > 0, start.cpu >= 0, cpu >= start.cpu else { return nil }
            return 100 * (cpu - start.cpu) / seconds
        }
    }

    private func confirmAfkPaintTest() {
        let alert = UIAlertController(title: "Thử ở màn hình chờ",
            message: "Thử giới hạn callback paint tối đa 5 lần/giây khi màn đen. Có thể đổi hành vi nếu paint chứa logic; chỉ thử trước đăng nhập. Nếu đã bật JIT bằng StikDebug, app tự đo thêm lượt JIT ở nhịp paint gốc.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Bắt đầu", style: .default) { [weak self] _ in
            self?.startAfkComparison()
        })
        present(alert, animated: true)
    }

    fileprivate func stopAfkPaintTestForPrompt() {
        stopJarAudit()
        if afkMeasureID != nil || guardedBlackout { hideBlackout() }
    }

    private func startAfkComparison() {
        guard blackout == nil else { return }
        showBlackout()
        let id = UUID()
        afkMeasureID = id
        let original = treo_game_jit_is_enabled()
        afkOriginalJIT = original
        let modes: [Int32] = original != 0 ? [0, 1, 2, 0] : [0, 2, 0]
        runAfkLeg(id: id, index: 0, modes: modes, results: [])
    }

    private func restoreAfkJIT() {
        if let original = afkOriginalJIT {
            afkOriginalJIT = nil
            treo_game_jit_set_enabled(original)
        }
    }

    private struct AfkLeg {
        let label: String
        let cpu: Double?
        let mainCPU: Double?
        let paintCPU: Double
        let paintRate: Double
        let bypassed: UInt64
        let jitCalls: UInt64
        let jitCompiled: UInt64
    }

    private func runAfkLeg(id: UUID, index: Int, modes: [Int32], results: [AfkLeg]) {
        let mode = modes[index]
        treo_game_jit_set_enabled(mode == 1 ? 1 : 0)
        treo_render_set_afk_mode(mode == 2 ? 7 : 1)
        blackout?.setTitle("Đang đo \(index + 1)/\(modes.count) · Chạm để hủy", for: .normal)
        let start = AfkSample()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.afkMeasureID == id, self.blackout != nil else { return }
            let end = AfkSample()
            let seconds = max(0.001, end.time - start.time)
            let label = mode == 2 ? "Paint ≤5 Hz" : (mode == 1 ? "JIT · nhịp gốc" : (index == 0 ? "Cũ 1" : "Cũ 2"))
            let leg = AfkLeg(label: label, cpu: end.cpuPercent(since: start),
                             mainCPU: start.mainCPU >= 0 && end.mainCPU >= start.mainCPU
                                ? 100 * (end.mainCPU - start.mainCPU) / seconds : nil,
                             paintCPU: Double(end.paintNS &- start.paintNS) / seconds / 10_000_000,
                             paintRate: Double(end.paints &- start.paints) / seconds,
                             bypassed: end.bypassed &- start.bypassed,
                             jitCalls: UInt64(UInt32(bitPattern: end.jitCalls &- start.jitCalls)),
                             jitCompiled: UInt64(UInt32(bitPattern: end.jitCompiled &- start.jitCompiled)))
            let all = results + [leg]
            if index + 1 < modes.count {
                self.runAfkLeg(id: id, index: index + 1, modes: modes, results: all)
                return
            }
            self.restoreAfkJIT()
            func percent(_ value: Double?) -> String {
                value.map { String(format: "%.1f%%", $0) } ?? "?"
            }
            let rows = all.map { v in
                "\(v.label): \(percent(v.cpu)) tổng · main \(percent(v.mainCPU)) · \(String(format: "%.1f%%", v.paintCPU)) trong paint · \(String(format: "%.1f", v.paintRate)) paint/s"
            }.joined(separator: "\n")
            let paced = all.first { $0.label == "Paint ≤5 Hz" }
            let jit = all.first { $0.label == "JIT · nhịp gốc" }
            let jitText = jit.map { "JIT: \($0.jitCalls) lượt mã máy · \($0.jitCompiled) biên dịch mới." } ?? "Không đo JIT (chưa bật trước bài thử)."
            let report = """
            \(rows)
            Bỏ \(paced?.bypassed ?? 0) yêu cầu paint ở lượt 5 Hz.
            \(jitText)
            Cùng màn đen; CPU quy về một lõi. Không lấy mẫu hàm hay đo GPU %.
            """
            self.afkMeasure = nil
            self.afkMeasureID = nil
            self.afkComparisonDone = true
            self.lastMeasurement = ("So CPU treo", report)
            self.applyPadMode()
            self.blackout?.setTitle("Đo xong · Chạm xem kết quả", for: .normal)
        }
        afkMeasure = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(60), execute: work)
    }

    // MARK: - Soft keys

    @objc private func softKeyDown(_ sender: UIButton) {
        softKeyHaptic.impactOccurred(intensity: 0.6)
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_PRESSED), Int32(sender.tag))
        sender.backgroundColor = UIColor(white: 0.30, alpha: 1)
    }

    @objc private func softKeyUp(_ sender: UIButton) {
        j2me_input_post_key(Int32(J2ME_INPUT_KEY_RELEASED), Int32(sender.tag))
        sender.backgroundColor = UIColor(white: 0.12, alpha: 1)
    }

    // ============================================================
    // MARK: - Game lifecycle
    // ============================================================

    private func startGame() {
        guard !didStartGame else { return }
        didStartGame = true
        NSLog("[J2ME Treo] Game view appeared; scheduling JVM startup")

        guard let resRoot = Bundle.main.resourcePath,
              ["minijvm_rt.jar", "j2me_api.jar"].allSatisfy({
                  FileManager.default.isReadableFile(atPath: resRoot + "/" + $0)
              }),
              FileManager.default.isReadableFile(atPath: jarPath) else {
            showLaunchFailure("The game JAR or a bundled Java runtime file is missing.")
            return
        }

        // Copy plain values on the main actor; the VM worker never reads the view controller.
        let gamePath = jarPath
        let width = Int32(canvasWidth)
        let height = Int32(canvasHeight)
        let scale = Int32(render3dScale)
        let fps = Int32(fpsLimit)
        let worker = DispatchWorkItem { [weak self] in
            let failure = GameViewController.runMIDlet(
                resRoot: resRoot, jarPath: gamePath, width: width,
                height: height, scale: scale, fps: fps
            )
            DispatchQueue.main.async { [weak self] in
                if let self {
                    self.stopJarAudit()
                    self.finishStartupWatchdog()
                    self.discardCPUProfile()
                    self.hideBlackout()
                    for code in Array(self.heldDirections) { self.releaseDirection(code) }
                }
                if let failure {
                    self?.showLaunchFailure(failure)
                } else {
                    self?.dismiss(animated: true)
                }
            }
        }
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, let icon = self.placeholderIconView, !icon.isHidden else { return }
            NSLog("[J2ME Treo] Startup: no game frame or native screen after 15 seconds")
        }
        startupWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: watchdog)
        DispatchQueue.global(qos: .userInitiated).async(execute: worker)
    }

    private func finishStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
    }

    private func showLaunchFailure(_ message: String) {
        NSLog("[J2ME Treo] Launch failed: %@", message)
        let alert = UIAlertController(title: "Game could not start", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Back", style: .default) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        present(alert, animated: true)
    }

    nonisolated private static func runMIDlet(resRoot: String, jarPath: String,
                                              width: Int32, height: Int32,
                                              scale: Int32, fps: Int32) -> String? {
        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let jarFileName = URL(fileURLWithPath: jarPath).deletingPathExtension().lastPathComponent
        let gameId = jarFileName.replacingOccurrences(of: "[^a-zA-Z0-9._-]",
                                                       with: "_", options: .regularExpression)
        let saveRoot = docs + "/Games Data/" + gameId
        do {
            try FileManager.default.createDirectory(atPath: saveRoot, withIntermediateDirectories: true)
        } catch {
            return "Cannot create the game's save directory."
        }

        NSLog("[J2ME Treo] Entering JVM initialization")
        let initResult = jvm_bridge_init(resRoot, saveRoot, jarPath, width, height, scale, fps)
        NSLog("[J2ME Treo] JVM initialization returned %d", initResult)
        guard initResult == 0 else { return "Java runtime initialization failed (\(initResult))." }

        NSLog("[J2ME Treo] Entering MIDlet runner")
        let runResult = jvm_bridge_run_midlet(jarPath)
        NSLog("[J2ME Treo] MIDlet runner returned %d; cleaning up", runResult)
        jvm_bridge_destroy()
        NSLog("[J2ME Treo] JVM cleanup complete")
        return runResult == 0 ? nil : "Game execution failed (\(runResult))."
    }

    @objc private func backTapped() {
        stopJarAudit()
        backButton.isEnabled = false
        discardCPUProfile()
        finishStartupWatchdog()
        for code in Array(heldDirections) { releaseDirection(code) }
        jvm_bridge_request_stop()
    }

    // ============================================================
    // MARK: - View switching
    // ============================================================

    func showCanvasView() {
        emulatorView.isHidden = false
        joystickView?.isHidden = layoutMode == .portrait
        numpadView?.isHidden = false
        formView.isHidden = true
        listView.isHidden = true
        if layoutMode == .ngage { numpadView?.updateCommands() }
        applyPadMode()
    }

    func showFormView() {
        finishStartupWatchdog()
        placeholderIconView?.isHidden = true
        formView.buildFromNativeData()
        formView.isHidden = false
        emulatorView.isHidden = true
        joystickView?.isHidden = true
        numpadView?.isHidden = true
        listView.isHidden = true
        for code in Array(heldDirections) { releaseDirection(code) }
        applyPadMode()
    }

    func showListView() {
        finishStartupWatchdog()
        placeholderIconView?.isHidden = true
        listView.buildFromNativeData()
        listView.isHidden = false
        emulatorView.isHidden = true
        joystickView?.isHidden = true
        numpadView?.isHidden = true
        formView.isHidden = true
        for code in Array(heldDirections) { releaseDirection(code) }
        applyPadMode()
    }

    func showAlert() {
        finishStartupWatchdog()
        let revision = j2me_ui_revision()
        let title = String(cString: j2me_ui_get_form_title())
        let text = String(cString: j2me_ui_get_alert_text())

        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)

        alertTimeoutWork?.cancel()
        alertTimeoutWork = nil

        let cmdCount = j2me_ui_get_command_count()
        if cmdCount == 0 {
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                self?.alertTimeoutWork?.cancel()
                j2me_input_post_touch(Int32(J2ME_UI_ALERT_DISMISSED), revision, 0)
            })
        } else {
            for i in 0..<cmdCount {
                let label = String(cString: j2me_ui_get_command_label(Int32(i)))
                let cmdId = j2me_ui_get_command_id(Int32(i))
                alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                    self?.alertTimeoutWork?.cancel()
                    j2me_input_post_touch(Int32(J2ME_UI_COMMAND_ACTION), revision, cmdId)
                })
            }
        }

        present(alert, animated: true)

        let timeout = j2me_ui_get_alert_timeout()
        if timeout > 0 {
            let work = DispatchWorkItem { [weak alert] in
                alert?.dismiss(animated: true) {
                    j2me_input_post_touch(Int32(J2ME_UI_ALERT_DISMISSED), revision, 0)
                }
            }
            alertTimeoutWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(timeout) / 1000.0, execute: work)
        }
    }
}

// MARK: - Game UI callback (global)

private(set) weak var activeGameViewController: GameViewController?

let gameUICallback: @convention(c) (Int32, Int32) -> Void = { action, revision in
    DispatchQueue.main.async {
        j2me_ui_lock_screen()
        defer { j2me_ui_unlock_screen() }
        guard revision == j2me_ui_revision(), let vc = activeGameViewController else { return }
        switch action {
        case Int32(J2ME_UI_ACTION_SHOW_FORM), Int32(J2ME_UI_ACTION_SHOW_TEXTBOX),
             Int32(J2ME_UI_ACTION_SHOW_LIST), Int32(J2ME_UI_ACTION_SHOW_ALERT):
            vc.stopAfkPaintTestForPrompt()
        default: break
        }
        switch action {
        case Int32(J2ME_UI_ACTION_SHOW_CANVAS):
            vc.showCanvasView()
            treo_afk_ui_canvas_applied(revision)
        case Int32(J2ME_UI_ACTION_SHOW_FORM), Int32(J2ME_UI_ACTION_SHOW_TEXTBOX): vc.showFormView()
        case Int32(J2ME_UI_ACTION_SHOW_LIST):    vc.showListView()
        case Int32(J2ME_UI_ACTION_SHOW_ALERT):   vc.showAlert()
        default: break
        }
        vc.keepBlackoutOnTop()
    }
}
