//
//  GameViewController.swift
//  J2MEEmulator
//
//  Runs a single J2ME MIDlet. Presented modally with zoom transition.
//  Layout mode determines the arrangement of screen and controls.
//

import UIKit
import CoreFoundation
import Darwin

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
    // nil is the original installation; non-nil is an independent tab
    // using the same immutable JAR bytes but its own RMS and settings.
    let cloneID: UUID?
    let appName: String
    let appIcon: UIImage
    let canvasWidth: Int
    let canvasHeight: Int
    let render3dScale: Int
    let fpsLimit: Int
    let layoutMode: GameLayoutMode

    private let emulatorView = EmulatorView()
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
    // Black cover swallows all touches; only the small centered child button
    // can wake the game. Neither touchesMoved nor taps outside it end Treo.
    private var blackoutThermalObserver: NSObjectProtocol?
    private var blackoutWorstThermal: ProcessInfo.ThermalState?
    private var blackoutThermalEvents = 0
    // Passive Treo HUD: four screen updates/minute, no JVM hot-loop hooks.
    private weak var blackoutStatsLabel: UILabel?
    private var blackoutStatsTimer: Timer?
    private var blackoutLastCPUSample: (time: TimeInterval, cpu: Double)?
    private var blackoutLastCPUText = "CPU: đang đo"
    private var blackoutBatteryMonitoringWasEnabled: Bool?
    private var blackoutHUDUpdates = 0
    private var blackoutRequestedMode: Int32 = 0
    // Capture the 8-second live NSO repaint-request cadence BEFORE Treo.
    // -1 means unavailable; this is a heartbeat proxy, not a proven game tick.
    private var blackoutNSOLiveHz: Double = -1
    // NSO-only: park the otherwise idle Display/JVM polling thread on its
    // existing GC-safe event-driven condition variable during JarBox mode 8.
    private var blackoutNSODeepIdle = false
    private var blackoutScreen: UIScreen?
    private var previousBrightness: CGFloat?
    private var jarBoxSmartTreo = false
    private var jarBoxSmartStartedAt: TimeInterval?
    private var vmTreoProbeStart: VMTreoProbe?
    private var jarBoxDeepTreoStart: GenericTreoSnapshot?
    private var genericTreoComparisonID: UUID?
    private var genericTreoWork: DispatchWorkItem?
    private var gameCanvasBlitAuditID: UUID?
    private var gameCanvasBlitAuditWork: DispatchWorkItem?
    private var mainStackAuditID: UUID?
    private var mainStackAuditWork: DispatchWorkItem?
    private var heldDirections: Set<Int32> = []
    private var directionTimers: [Int32: Timer] = [:]

    init(jarPath: String, appName: String, appIcon: UIImage,
         canvasWidth: Int = 240, canvasHeight: Int = 320,
         render3dScale: Int = 3, fpsLimit: Int = 0,
         layoutMode: GameLayoutMode = .portrait,
         cloneID: UUID? = nil) {
        self.jarPath = jarPath
        self.cloneID = cloneID
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
        stopEscalationWork?.cancel()
        stopRescueWork?.cancel()
        measurementDeadline?.cancel()
        afkMeasure?.cancel()
        jarAuditWork?.cancel()
        genericTreoWork?.cancel()
        gameCanvasBlitAuditWork?.cancel()
        mainStackAuditWork?.cancel()
        blackoutStatsTimer?.invalidate()
        if let wasEnabled = blackoutBatteryMonitoringWasEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = wasEnabled
        }
        if let blackoutThermalObserver {
            NotificationCenter.default.removeObserver(blackoutThermalObserver)
        }
        if mainStackAuditID != nil { treo_afk_main_trace_cancel() }
        // An old controller may die while a newer session owns the VM.
        if activeGameViewController === self &&
            ownsJVMSession && gameSessionToken != 0 &&
            jvm_bridge_session_token() == gameSessionToken &&
            jvm_bridge_session_is_active() != 0 {
            // Only this controller's still-live JVM may modify process-wide
            // Treo/GC state. In particular, token 0 must never authorize an
            // old controller after a newly started game inherited the UI.
            if parkedTreoActive {
                // deinit may not be actor-isolated under strict Swift checks.
                // Keep this last-resort native reset direct, without
                // invoking an actor-isolated instance method from deinit.
                if parkedNSODeepIdle { _ = treo_display_wait_set_for_token(gameSessionToken, 0) }
                treo_afk_guard_auto_set(0)
                treo_gc_smart_set(0)
                treo_render_set_afk_mode(0)
            }
            treo_afk_buffer_audit_set(0, 0)
            if jarBoxSmartTreo { treo_gc_smart_set(0) }
            treo_afk_guard_auto_set(0)
            if blackoutNSODeepIdle {
                treo_display_wait_set(0)
                blackoutNSODeepIdle = false
            }
        }
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
    private var jarGCPeriodAudit = false
    private var jarThroughputAudit = false
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
    private var stopEscalationWork: DispatchWorkItem?
    private var stopRescueWork: DispatchWorkItem?
    private var ownsJVMSession = false
    private var gameSessionToken: UInt64 = 0
    private var gameStopRequested = false
    // One *live* miniJVM remains owned by this controller while the library
    // overlays it. This is a parked foreground session, not a second JVM.
    private var libraryIsPresented = false
    // The root library holds a strong reference to this controller while
    // its JVM lives. The reverse link must remain weak.
    weak var sessionLibrary: AppsListViewController?
    // Automatic Treo belongs to the parked JVM, not a black-screen UI.
    // Explicitly undone on resume, Stop and JVM termination.
    private var parkedTreoActive = false
    private var parkedNSODeepIdle = false
    // Event-based measurements only: no library timer or CPU poller.
    private var parkedStartedAt: TimeInterval?
    private var parkedCPUStart: Double?
    // Raw per-session baselines for on-demand game details. Never poll in the library.
    private var parkedSkippedDrawsStart: UInt64 = 0
    private var parkedGuardedPaintsStart: UInt64 = 0
    private var parkedGCCyclesStart: UInt64 = 0
    // A game may request an MIDP Alert while the library covers the game.
    // Present it only after returning to the game, not atop the library.
    private var deferredGameAlert = false
    private var startupTimeoutShown = false
    private var gameIdleTimerPreviouslyDisabled: Bool?

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
        if layoutMode == .ngage {
            // Landscape previously lacked the floating game menu entirely.
            screenMenu.translatesAutoresizingMaskIntoConstraints = false
            screenMenu.setImage(UIImage(systemName: "ellipsis.circle"), for: .normal)
            screenMenu.tintColor = .white
            screenMenu.accessibilityLabel = "Tùy chọn game"
            screenMenu.showsMenuAsPrimaryAction = true
            screenMenu.menu = UIMenu(children: [
                UIAction(title: "Về thư viện · tự động Treo",
                         image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in
                    self?.openLibraryKeepingGame()
                },
                UIAction(title: "Dừng game hoàn toàn",
                         image: UIImage(systemName: "stop.fill"),
                         attributes: .destructive) { [weak self] _ in
                    self?.stopGameFromMenu()
                }
            ])
            view.addSubview(screenMenu)
            NSLayoutConstraint.activate([
                screenMenu.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
                screenMenu.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
                screenMenu.widthAnchor.constraint(equalToConstant: 44),
                screenMenu.heightAnchor.constraint(equalToConstant: 36),
            ])
            view.bringSubviewToFront(screenMenu)
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

        // Remove the startup placeholder immediately; no fade animation
        // and no second per-frame game-image copy behind the canvas.
        emulatorView.onFirstFrame = { [weak self] in
            NSLog("[J2ME Treo] First game frame displayed")
            self?.finishStartupWatchdog()
            self?.placeholderIconView?.removeFromSuperview()
            self?.placeholderIconView = nil
        }

        // Register native callbacks only after acquiring the exclusive
        // miniJVM slot in startGame. Early registration could make a stale
        // controller steal an active game's render target.
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Keep the screen awake only while the game is visible. Locking the
        // phone while NSO auto/Treo is active may suspend Java execution.
        // The library itself must NOT permanently disable auto-lock.
        if gameIdleTimerPreviouslyDisabled == nil {
            gameIdleTimerPreviouslyDisabled = UIApplication.shared.isIdleTimerDisabled
        }
        UIApplication.shared.isIdleTimerDisabled = true
        if sessionLibrary != nil, libraryIsPresented {
            restoreManagedGameFocus()
        } else {
            startGame()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if let previous = gameIdleTimerPreviouslyDisabled {
            UIApplication.shared.isIdleTimerDisabled = previous
            gameIdleTimerPreviouslyDisabled = nil
        }
        if !ownsJVMSession && (isBeingDismissed || presentingViewController == nil) {
            sessionLibrary?.managedGameDidEnd(self)
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Don't wait for the next native heap snapshot if iOS itself
        // reports memory pressure. The AFK overlay may remain visible.
        if jarBoxSmartTreo { treo_gc_smart_force_safe() }
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

        // The game Canvas is the only rendered game image.
        // Do not instantiate the GPU-heavy glow mirror/backdrop blur.
        for v: UIView in [joystick, emulatorView, numpad, lskButton, rskButton, formView, listView, backButton] {
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
        backButton.setTitle("‹ Thư viện", for: .normal)
        backButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        backButton.accessibilityLabel = "Về thư viện, giữ game chạy"
        backButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
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
        // Keep Stop and Back-to-Library reachable on MIDP Forms/Lists too.
        // A hidden canvas is not the same as a finished JVM session.
        screenMenu.isHidden = false
        directionalPad?.isHidden = padMode != .directions
        numpadView?.isHidden = padMode != .numbers
        portraitControlsHeight?.constant = padIsVisible ? 198 : 0
        for pin in portraitPadBottomPins { pin.isActive = padIsVisible }
        if jarAuditID != nil {
            screenMenu.menu = UIMenu(children: [
                UIAction(title: "Về thư viện · tự động Treo") { [weak self] _ in self?.openLibraryKeepingGame() },
                UIAction(title: "Chẩn đoán kết nối") { [weak self] _ in self?.showNetworkDiagnostics() },
                UIAction(title: "Hủy chẩn đoán CPU JAR", attributes: .destructive) { [weak self] _ in self?.stopJarAudit() },
                UIAction(title: "Dừng game hoàn toàn", attributes: .destructive) { [weak self] _ in self?.stopGameFromMenu() }
            ])
            return
        }
        // User-facing menu: stable functions + exactly ONE active experiment.
        // Historical probes remain in source for rollback, not in the UI.
        screenMenu.menu = UIMenu(children: [
            UIAction(title: "Về thư viện · tự động Treo",
                     image: UIImage(systemName: "square.grid.2x2")) { [weak self] _ in
                self?.openLibraryKeepingGame()
            },
            UIAction(title: "Phím điều hướng", state: padMode == .directions ? .on : .off) { [weak self] _ in self?.setPadMode(.directions) },
            UIAction(title: "Phím số", state: padMode == .numbers ? .on : .off) { [weak self] _ in self?.setPadMode(.numbers) },
            UIAction(title: "Ẩn phím · màn hình lớn", state: padMode == .hidden ? .on : .off) { [weak self] _ in self?.setPadMode(.hidden) },
            UIAction(title: "Xem kết quả đo gần nhất",
                     attributes: lastMeasurement == nil ? .disabled : []) { [weak self] _ in
                self?.showLastMeasurement()
            },
            UIAction(title: "Chẩn đoán kết nối") { [weak self] _ in
                self?.showNetworkDiagnostics()
            },
            UIAction(title: "Dừng game hoàn toàn", attributes: .destructive) { [weak self] _ in
                self?.stopGameFromMenu()
            }
        ])
    }

    private func stopGameFromMenu() {
        requestGameStop(reason: "menu_stop")
    }

    // A hung JVM cannot safely have its singleton flag cleared while Java
    // threads still hold pointers into its heap. Offer a *confirmed*
    // process-level escape hatch rather than a fake view dismissal.
    private func showStuckSessionRecovery() {
        guard ownsJVMSession, viewIfLoaded?.window != nil, !isBeingDismissed else { return }
        let phase = jvm_bridge_session_phase()
        let alert = UIAlertController(
            title: "Game chưa dừng hẳn",
            message: "JVM vẫn đang hoạt động hoặc dọn dẹp (pha \(phase)). " +
                     "Bạn có thể tiếp tục chờ, hoặc đóng hẳn JarBox để giải phóng " +
                     "phiên kẹt. Không thể mở chồng JVM khác khi phiên này còn sống.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Tiếp tục chờ", style: .cancel))
        alert.addAction(UIAlertAction(title: "Buộc đóng JarBox", style: .destructive) { [weak self] _ in
            self?.confirmEmergencyExit()
        })
        if let previous = presentedViewController {
            previous.dismiss(animated: false) { [weak self] in
                guard let self, self.ownsJVMSession, self.view.window != nil else { return }
                self.present(alert, animated: true)
            }
        } else {
            present(alert, animated: true)
        }
    }

    private func confirmEmergencyExit() {
        guard jvm_bridge_session_is_active() != 0 else { return }
        // A stale confirmation must not kill a newly launched game/clone.
        let expectedToken = gameSessionToken != 0
            ? gameSessionToken : jvm_bridge_session_token()
        guard expectedToken != 0 else { return }
        let alert = UIAlertController(
            title: "Đóng toàn bộ JarBox?",
            message: "Chỉ dùng nếu game kẹt không thể dừng. Dữ liệu chưa lưu " +
                     "có thể mất. JarBox sẽ tắt hoàn toàn và cần được mở lại.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Không", style: .cancel))
        alert.addAction(UIAlertAction(title: "Đóng JarBox ngay", style: .destructive) { _ in
            guard jvm_bridge_session_token() == expectedToken else { return }
            NSLog("[JarBoxVM][Lifecycle] confirmed_hard_process_exit phase=%d",
                  jvm_bridge_session_phase())
            // A process stop releases all VM threads/sockets, unlike
            // unsafely clearing the session flag of an active JVM.
            Darwin.exit(0)
        })
        present(alert, animated: true)
    }

    private func showNetworkDiagnostics() {
        guard viewIfLoaded?.window != nil, presentedViewController == nil else { return }
        let trace = String(cString: jvm_bridge_net_trace())
        // This identity is embedded by Codemagic into the *packaged IPA*,
        // independent of JVM startup, diagnostics or Java class loading.
        // Old installations lacking it are immediately distinguishable.
        let packagedCommit = Bundle.main.object(forInfoDictionaryKey: "JarBoxBuildCommit") as? String
        let packagedPatch = Bundle.main.object(forInfoDictionaryKey: "JarBoxBootPatch") as? String
        let buildID = packagedCommit ?? "không có (IPA cũ/chưa gắn phiên bản)"
        let bootPatch = packagedPatch ?? "không có"
        let hasStartupProbe = trace.contains("probe:java8_utf8_boot_patch=v1")
        // The cumulative counters can be compared across two copied
        // snapshots to distinguish a frozen Java Display or game loop
        // from a working loop that simply awaits a modal acknowledgement.
        let report = "JarBoxNET\n" +
            "build_commit=" + buildID + "\n" +
            "boot_patch=" + bootPatch + "\n" +
            "vm_start_probe=" + (hasStartupProbe ? "seen" : "missing") + "\n" +
            "display_poll_count=" + String(treo_display_poll_calls()) + "\n" +
            "popup_update_count=" + String(jvm_bridge_mod_popup_tick_count()) + "\n" +
            "game_loop_last_call=" + String(jvm_bridge_mod_loop_last_stage()) + "\n" +
            "game_loop_calls=popup:" + String(jvm_bridge_mod_loop_stage_count(1)) +
            ",repaint:" + String(jvm_bridge_mod_loop_stage_count(2)) +
            ",serviceRepaints:" + String(jvm_bridge_mod_loop_stage_count(3)) +
            ",sleep:" + String(jvm_bridge_mod_loop_stage_count(4)) + "\n" +
            (trace.isEmpty
                ? "Chưa ghi nhận TCP hoặc exception mạng của game."
                : trace)
        let alert = UIAlertController(title: "Chẩn đoán kết nối",
                                      message: report, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sao chép", style: .default) { _ in
            UIPasteboard.general.string = report
        })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        present(alert, animated: true)
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

    // This user-facing mode preserves all Java paint() callbacks, but skips
    // compatible raster calls inside those callbacks when output is invisible.
    // Some games depend on the pixels, so this mode remains explicitly opt-in.
    private func confirmGenericDeepTreo() {
        guard blackout == nil, jarAuditID == nil else { return }
        let alert = UIAlertController(
            title: "Treo sâu của JarBox · thử nghiệm",
            message: "Không cần sửa JAR. Java paint() và vòng game vẫn được gọi, nhưng JarBox thử bỏ các lệnh vẽ Canvas khi màn hình bị che. GameCanvas, đường vẽ trực tiếp và thao tác phụ thuộc pixel được giữ hoặc tự quay về chế độ tương thích khi phát hiện. Tuy nhiên không thể đảm bảo mọi game đều an toàn: hãy thử ngắn và kiểm tra mạng, auto, nhiệm vụ sau khi thoát treo.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Hủy", style: .cancel))
        alert.addAction(UIAlertAction(title: "Bật Treo sâu", style: .default) { [weak self] _ in
            self?.showBlackout(mode: 8, smartGC: true, deepPaint: true)
        })
        present(alert, animated: true)
    }

    // Snapshot uses only monotonic counters and CPU clocks; no new pthread.
    private struct GenericTreoSnapshot {
        let cpu = AfkSample()
        let guarded = treo_afk_guarded_paints()
        let real = treo_afk_guarded_real()
        let late = treo_afk_guarded_late()
        let nativeSkipped = treo_afk_skipped_draws()
        let javaElided = treo_afk_elided_calls()
        let submitted = treo_afk_layer_frames()
    }
    private struct GenericTreoLeg {
        let total: Double?
        let main: Double?
        let paint: Double
        let paintHz: Double
        let guarded: UInt64
        let real: UInt64
        let late: UInt64
        let nativeSkipped: UInt64
        let javaElided: UInt64
        let frames: UInt64
        let fellBack: Bool
        let duration: Double
    }

    // Compare existing compatible presentation skip (mode 1) with guarded
    // Java raster skip (mode 8), all with adaptive GC enabled and no JAR mods.
    private func startGenericTreoComparison() {
        guard blackout == nil, jarAuditID == nil, powerRun == nil else { return }
        showBlackout(mode: 1, smartGC: true)
        guard blackout != nil else { return }
        let id = UUID()
        genericTreoComparisonID = id
        runGenericTreoComparisonLeg(id: id, leg: 0, results: [])
    }

    private func runGenericTreoComparisonLeg(id: UUID, leg: Int,
                                               results: [GenericTreoLeg]) {
        guard genericTreoComparisonID == id, blackout != nil else { return }
        let deep = leg == 1
        treo_afk_guard_auto_set(deep ? 1 : 0)
        treo_render_set_afk_mode(deep ? 8 : 1)
        blackout?.setTitle("So Treo JarBox \(leg + 1)/3 · \(deep ? "bỏ raster" : "tương thích") · chạm hủy",
                          for: .normal)
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.genericTreoComparisonID == id, self.blackout != nil else { return }
            let start = GenericTreoSnapshot()
            let measure = DispatchWorkItem { [weak self] in
                guard let self, self.genericTreoComparisonID == id, self.blackout != nil else { return }
                let end = GenericTreoSnapshot()
                let dt = max(0.001, end.cpu.time - start.cpu.time)
                let main: Double? = start.cpu.mainCPU >= 0 && end.cpu.mainCPU >= start.cpu.mainCPU
                    ? 100 * (end.cpu.mainCPU - start.cpu.mainCPU) / dt : nil
                let result = GenericTreoLeg(
                    total: end.cpu.cpuPercent(since: start.cpu),
                    main: main,
                    paint: Double(end.cpu.paintNS &- start.cpu.paintNS) / dt / 10_000_000,
                    paintHz: Double(end.cpu.paints &- start.cpu.paints) / dt,
                    guarded: end.guarded &- start.guarded,
                    real: end.real &- start.real,
                    late: end.late &- start.late,
                    nativeSkipped: end.nativeSkipped &- start.nativeSkipped,
                    javaElided: end.javaElided &- start.javaElided,
                    frames: end.submitted &- start.submitted,
                    fellBack: deep && treo_afk_guard_auto_fell_back() != 0,
                    duration: dt)
                let all = results + [result]
                if leg < 2 {
                    self.runGenericTreoComparisonLeg(id: id, leg: leg + 1, results: all)
                    return
                }
                self.genericTreoComparisonID = nil
                self.genericTreoWork = nil
                treo_afk_guard_auto_set(0)
                treo_render_set_afk_mode(1)
                let a = all[0], b = all[1], c = all[2]
                func number(_ x: Double?) -> String {
                    x.map { String(format: "%.1f", $0) } ?? "?"
                }
                var lines = [
                    "JAR: \(URL(fileURLWithPath: self.jarPath).lastPathComponent)",
                    "A1 tương thích → B bỏ raster có bảo vệ → A2 tương thích; 20 giây/lượt, 2 giây ổn định/lượt. Cả 3: màn đen, độ sáng 0, GC thích ứng, JIT giữ nguyên.",
                ]
                for (i, x) in all.enumerated() {
                    lines.append(String(format:
                        "%@: tổng %@%% · main %@%% · paint %.1f%% (%.2f/s) · bỏ raster %llu · vẽ thật %llu · lệnh native bỏ %llu · Java bỏ %llu · lên layer %llu",
                        ["A1", "B", "A2"][i], number(x.total), number(x.main),
                        x.paint, x.paintHz, x.guarded, x.real, x.nativeSkipped,
                        x.javaElided, x.frames))
                }
                if let x = a.total, let y = b.total, let z = c.total {
                    lines.append(String(format:
                        "B − trung bình A1/A2: tổng %+.1f điểm CPU · main %+.1f điểm CPU · paint %+.1f điểm.",
                        y - (x + z) / 2,
                        (b.main ?? 0) - ((a.main ?? 0) + (c.main ?? 0))/2,
                        b.paint - (a.paint + c.paint)/2))
                    if abs(x - z) > 3 {
                        lines.append("KHÔNG KẾT LUẬN: CPU tổng A1/A2 trôi >3 điểm.")
                    }
                }
                if b.fellBack || b.late > 0 {
                    lines.append("KHÔNG HỢP LỆ: phát hiện Canvas phụ thuộc pixel; đã tự lui về Treo tương thích.")
                }
                let baseHz = (a.paintHz + c.paintHz) / 2
                if baseHz < 1 || abs(b.paintHz - baseHz) > max(1, baseHz * 0.1) {
                    lines.append("KHÔNG KẾT LUẬN: tần suất paint không tương đương hoặc quá ít.")
                }
                if b.guarded == 0 {
                    lines.append("Không bỏ được raster: có thể JAR dùng GameCanvas, direct buffer hoặc phụ thuộc pixel.")
                }
                let stableCPU = a.total != nil && b.total != nil && c.total != nil &&
                    abs((a.total ?? 0) - (c.total ?? 0)) <= 3
                let stablePaint = baseHz >= 1 &&
                    abs(b.paintHz - baseHz) <= max(1, baseHz * 0.1)
                let compatible = !b.fellBack && b.late == 0 && b.guarded > 0 &&
                    b.frames == 0 && a.frames == 0 && c.frames == 0
                if stableCPU && stablePaint && compatible,
                   let cpuA = a.total, let cpuB = b.total, let cpuC = c.total {
                    let saved = (cpuA + cpuC)/2 - cpuB
                    lines.append(saved >= 2
                        ? String(format: "ỨNG VIÊN CÓ LỢI: giảm %.1f điểm CPU tổng trên cùng JAR, cùng chế độ treo. Chưa chứng minh giảm watt.", saved)
                        : String(format: "CHƯA THẤY LỢI ÍCH CPU TỔNG: cải thiện %+.1f điểm; không nên bật Treo sâu mặc định.", saved))
                } else {
                    lines.append("KHÔNG ĐỦ CĂN CỨ CHẤM TỐI ƯU: dữ liệu trôi, raster không được bỏ, game không paint đều hoặc xảy ra fallback.")
                }
                lines.append("Không đo watt/lõi CPU hay tick game dùng chung. CPU giảm chỉ là ứng viên; phải kiểm tra auto, mạng và trạng thái game sau khi thoát.")
                self.lastMeasurement = ("So CPU Treo JarBox · A/B/A", lines.joined(separator: "\n\n"))
                self.afkComparisonDone = true
                self.blackout?.setTitle("Đo xong · chạm để xem kết quả", for: .normal)
            }
            self.genericTreoWork = measure
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: measure)
        }
        genericTreoWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: settle)
    }


    // Single active diagnostic; the game, JIT, GC policy and rendering
    // semantics remain identical throughout the measurement.
    private func startMainStackAudit() {
        guard blackout == nil, jarAuditID == nil, powerRun == nil,
              mainStackAuditID == nil, gameCanvasBlitAuditID == nil,
              genericTreoComparisonID == nil else { return }
        lastAFKTrace = ""
        showBlackout(mode: 8, smartGC: true, deepPaint: true)
        guard blackout != nil else { return }
        let id = UUID()
        mainStackAuditID = id
        blackout?.setTitle("CPU main · ổn định 2 giây · chạm hủy", for: .normal)

        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.mainStackAuditID == id, self.blackout != nil else { return }
            let start = AfkSample()
            let framesStart = treo_afk_layer_frames()
            // The native sampler briefly suspends main to copy a bounded stack.
            // Symbolization happens after resuming main, not while suspended.
            treo_afk_main_stack_snapshot_begin()
            self.blackout?.setTitle("Đang đo stack CPU main · chạm hủy", for: .normal)

            let finish = DispatchWorkItem { [weak self] in
                guard let self, self.mainStackAuditID == id, self.blackout != nil else { return }
                // Stop the CPU measurement clock BEFORE doing the potentially
                // expensive symbolization/report assembly on main.
                let end = AfkSample()
                let raw = treo_afk_main_trace_end()
                let dt = max(0.001, end.time - start.time)
                let main: Double? = start.mainCPU >= 0 && end.mainCPU >= start.mainCPU
                    ? 100 * (end.mainCPU - start.mainCPU) / dt : nil
                let fullTrace = raw.map { String(cString: $0) }
                    ?? "Không lấy được báo cáo stack native."
                if let raw { free(raw) }
                let totalText = end.cpuPercent(since: start)
                    .map { String(format: "%.1f%%", $0) } ?? "?"
                let mainText = main.map { String(format: "%.1f%%", $0) } ?? "?"
                let paint = Double(end.paintNS &- start.paintNS) / dt / 10_000_000
                let paintHz = Double(end.paints &- start.paints) / dt
                let frames = treo_afk_layer_frames() &- framesStart
                let fallback = treo_afk_guard_auto_fell_back() != 0
                let jar = URL(fileURLWithPath: self.jarPath).lastPathComponent
                let heading = String(format:
                    "JAR: %@\nTreo sâu + Smart GC · JIT không đổi · 2 giây ổn định, %.1f giây đo.\nCPU toàn app %@ · main %@ · paint %.1f%% (%.2f/s).\nKhung lên layer %llu · Canvas fallback: %@.",
                    jar, dt, totalText, mainText, paint, paintHz, frames,
                    fallback ? "có" : "không")
                let caution = "\nĐây là mẫu main đang runnable, không phải % CPU hay watt từng hàm. " +
                    "Sampler có chi phí riêng. Không có tick Java dùng chung; kiểm tra auto/mạng và hình sau khi thoát."
                self.lastAFKTrace = heading + "\n\n" + fullTrace + caution
                let preview = fullTrace.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(11).joined(separator: "\n")
                self.lastMeasurement = ("CPU luồng chính",
                    heading + "\n\n" + preview +
                    "\n\nBấm Sao chép để lấy báo cáo stack đầy đủ." + caution)
                self.mainStackAuditID = nil
                self.mainStackAuditWork = nil
                self.afkComparisonDone = true
                self.blackout?.setTitle("Đo xong · chạm xem báo cáo", for: .normal)
            }
            self.mainStackAuditWork = finish
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: finish)
        }
        mainStackAuditWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: settle)
    }

    // Historical GameCanvas test retained for rollback but hidden from the menu.
    // One active experiment. GameCanvas maintains a real offscreen Image;
    // this changes only the redundant Image -> hidden Canvas copy.
    private struct GameCanvasBlitSnapshot {
        let base = AfkSample()
        let copies = treo_afk_buffer_copied()
        let skipped = treo_afk_buffer_skipped()
        let savedPixels = treo_afk_buffer_pixels_saved()
        let copyCpu = treo_afk_buffer_copy_cpu_ns()
        let frames = treo_afk_layer_frames()
    }
    private struct GameCanvasBlitResult {
        let total: Double?
        let main: Double?
        let paint: Double
        let copies: UInt64
        let skipped: UInt64
        let savedPixels: UInt64
        let copyCpuMsPerS: Double
        let blitRate: Double
        let frames: UInt64
        let duration: Double
        let canvasFallback: Bool
    }

    private func startGameCanvasBlitAudit() {
        guard blackout == nil, jarAuditID == nil, powerRun == nil,
              gameCanvasBlitAuditID == nil else { return }
        // All legs use the same already-developed deep Treo + adaptive GC.
        showBlackout(mode: 8, smartGC: true, deepPaint: true)
        guard blackout != nil else { return }
        let id = UUID()
        gameCanvasBlitAuditID = id
        runGameCanvasBlitLeg(id: id, leg: 0, results: [])
    }

    private func runGameCanvasBlitLeg(id: UUID, leg: Int,
                                     results: [GameCanvasBlitResult]) {
        guard gameCanvasBlitAuditID == id, blackout != nil else { return }
        let skip = leg == 1
        // Keep Java/GameCanvas behavior, JIT, GC and blackout identical.
        treo_afk_buffer_audit_set(1, skip ? 1 : 0)
        blackout?.setTitle("GameCanvas A/B/A \(leg + 1)/3 · \(skip ? "bỏ bản sao" : "bản gốc") · chạm hủy",
                           for: .normal)
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.gameCanvasBlitAuditID == id, self.blackout != nil else { return }
            let begin = GameCanvasBlitSnapshot()
            let measure = DispatchWorkItem { [weak self] in
                guard let self, self.gameCanvasBlitAuditID == id, self.blackout != nil else { return }
                let end = GameCanvasBlitSnapshot()
                let dt = max(0.001, end.base.time - begin.base.time)
                let main: Double? = begin.base.mainCPU >= 0 && end.base.mainCPU >= begin.base.mainCPU
                    ? 100 * (end.base.mainCPU - begin.base.mainCPU) / dt : nil
                let copies = end.copies &- begin.copies
                let skipped = end.skipped &- begin.skipped
                let result = GameCanvasBlitResult(
                    total: end.base.cpuPercent(since: begin.base),
                    main: main,
                    paint: Double(end.base.paintNS &- begin.base.paintNS) / dt / 10_000_000,
                    copies: copies,
                    skipped: skipped,
                    savedPixels: end.savedPixels &- begin.savedPixels,
                    copyCpuMsPerS: Double(end.copyCpu &- begin.copyCpu) / dt / 1_000_000,
                    blitRate: Double(copies + skipped) / dt,
                    frames: end.frames &- begin.frames,
                    duration: dt,
                    canvasFallback: treo_afk_guard_auto_fell_back() != 0)
                let all = results + [result]
                if leg < 2 {
                    self.runGameCanvasBlitLeg(id: id, leg: leg + 1, results: all)
                    return
                }
                self.gameCanvasBlitAuditID = nil
                self.gameCanvasBlitAuditWork = nil
                treo_afk_buffer_audit_set(0, 0)
                let a = all[0], b = all[1], c = all[2]
                let avgRate = (a.blitRate + c.blitRate) / 2
                let copyCPUBaseline = (a.copyCpuMsPerS + c.copyCpuMsPerS) / 2
                func fmt(_ value: Double?) -> String {
                    value.map { String(format: "%.1f", $0) } ?? "?"
                }
                var report = [
                    "JAR: \(URL(fileURLWithPath: self.jarPath).lastPathComponent)",
                    "A1 sao chép → B bỏ bản sao GameCanvas → A2 sao chép. 20 giây/lượt, thêm 2 giây ổn định/lượt. Cả ba giữ Treo sâu, GC thông minh, JIT không đổi. Buffer Image thật của GameCanvas không bị bỏ.",
                ]
                for (index, v) in all.enumerated() {
                    report.append(String(format:
                        "%@: CPU tổng %@%% · main %@%% · paint %.1f%% · %.2f flush/s · sao chép %llu · bỏ %llu · CPU bản sao %.2f ms/s · pixel tránh chép %llu · khung layer %llu",
                        ["A1", "B", "A2"][index], fmt(v.total), fmt(v.main),
                        v.paint, v.blitRate, v.copies, v.skipped,
                        v.copyCpuMsPerS, v.savedPixels, v.frames))
                }
                report.append(String(format:
                    "B tránh chép ước tính %.2f MiB pixel RGBA8 vào Canvas ẩn (không phải số byte cấp phát hay số byte bộ nhớ đo thực tế).",
                    Double(b.savedPixels) * 4 / 1_048_576))
                if let x = a.total, let y = b.total, let z = c.total {
                    report.append(String(format:
                        "B − trung bình A1/A2: %+.1f điểm CPU tổng; baseline CPU bản sao %.2f ms/s.",
                        y - (x + z)/2, copyCPUBaseline))
                }
                let stable = a.total != nil && b.total != nil && c.total != nil &&
                    abs((a.total ?? 0) - (c.total ?? 0)) <= 3 &&
                    avgRate >= 1 &&
                    abs(a.blitRate - c.blitRate) <= max(1, avgRate * 0.1) &&
                    abs(b.blitRate - avgRate) <= max(1, avgRate * 0.1)
                let valid = stable && a.copies >= 5 && c.copies >= 5 &&
                    b.skipped >= 5 && !b.canvasFallback &&
                    a.frames == 0 && b.frames == 0 && c.frames == 0
                if valid, let x = a.total, let y = b.total, let z = c.total {
                    let saved = (x+z)/2 - y
                    report.append(saved >= 2
                        ? String(format: "ỨNG VIÊN CÓ LỢI: bỏ bản sao GameCanvas giảm %.1f điểm CPU tổng.", saved)
                        : String(format: "CHƯA CÓ LỢI ÍCH CPU TỔNG RÕ RÀNG: thay đổi %.1f điểm; giữ cách vẽ cũ.", saved))
                } else {
                    report.append("CHƯA ĐỦ CĂN CỨ: kiểm tra số lượt flush, ổn định A1/A2, fallback và khung layer. Nếu B bỏ 0, JAR có thể không dùng GameCanvas.")
                }
                report.append("Bài này không có bộ đếm tick Java chung cho mọi JAR. Hãy kiểm tra auto, kết nối mạng, hiển thị sau khi chạm thoát; không suy CPU% thành watt.")
                self.lastMeasurement = ("GameCanvas · bỏ bản sao A/B/A", report.joined(separator: "\n\n"))
                self.afkComparisonDone = true
                self.blackout?.setTitle("Đo xong · chạm để xem kết quả", for: .normal)
            }
            self.gameCanvasBlitAuditWork = measure
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: measure)
        }
        gameCanvasBlitAuditWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: settle)
    }


    // Reads cumulative monotonic counters only. No per-frame clock, timer,
    // UI observer, or instrumentation is added to the game hot loop.
    private static func treoThermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    // Localized labels are for the tiny on-screen HUD only.
    // Keep stable English thermal categories in diagnostic log fields.
    private static func treoThermalDisplayLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "Bình thường"
        case .fair: return "Tăng nhẹ"
        case .serious: return "Cao"
        case .critical: return "Rất cao"
        @unknown default: return "Không rõ"
        }
    }

    private func recordTreoThermalChange() {
        guard blackout != nil else { return }
        let state = ProcessInfo.processInfo.thermalState
        blackoutThermalEvents &+= 1
        if let previous = blackoutWorstThermal {
            if state.rawValue > previous.rawValue { blackoutWorstThermal = state }
        } else {
            blackoutWorstThermal = state
        }
    }


    // Labels name the ACTUAL recognized mode, never just the ZIP resource hit.
    // The VM checks the active Canvas's small paint-forwarding shape before
    // enabling NSO-specific skips.
    private func blackoutModeName() -> String {
        if blackoutRequestedMode == 8 && treo_ninja_deep_verified() != 0 &&
           treo_nso_canvas_recognized() != 0 {
            return "Chuyên biệt (NSO)"
        }
        return "Chuẩn"
    }

    private func blackoutModeTitle() -> String {
        return "Chế độ treo: " + blackoutModeName() +
            "\nChạm nút tròn giữa màn hình để trở lại"
    }

    // CPU here is the preceding ~15-second process average, not instantaneous.
    // This uses existing monotonic counters and never instruments Java calls.
    private func updateBlackoutDashboard() {
        guard blackout != nil, let label = blackoutStatsLabel else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let cpu = treo_process_cpu_seconds()
        if let last = blackoutLastCPUSample, last.cpu >= 0, cpu >= last.cpu,
           now > last.time {
            blackoutLastCPUText = String(
                format: "CPU: %.1f%%", 100.0 * (cpu - last.cpu) / (now - last.time))
        }
        blackoutLastCPUSample = (now, cpu)
        // Do not overwrite the detailed title used by legacy audit sessions.
        if let cover = blackout,
           let oldTitle = cover.title(for: .normal),
           oldTitle.hasPrefix("Chế độ treo:") {
            let newTitle = blackoutModeTitle()
            if oldTitle != newTitle { cover.setTitle(newTitle, for: .normal) }
        }
        let charge = UIDevice.current.batteryLevel
        let chargeText = charge >= 0 ? String(format: "%.0f%%", Double(charge) * 100) : "không rõ"
        let heat = Self.treoThermalDisplayLabel(ProcessInfo.processInfo.thermalState)
        let newText = blackoutLastCPUText
            + "\nPin: " + chargeText
            + "\nNhiệt: " + heat
        if label.text != newText {
            label.text = newText
            blackoutHUDUpdates &+= 1
        }
    }

    private func stopBlackoutDashboard() {
        blackoutStatsTimer?.invalidate()
        blackoutStatsTimer = nil
        blackoutStatsLabel = nil
        blackoutLastCPUSample = nil
        blackoutLastCPUText = "CPU: đang đo"
        if let wasEnabled = blackoutBatteryMonitoringWasEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = wasEnabled
            blackoutBatteryMonitoringWasEnabled = nil
        }
    }

    private struct VMTreoProbe {
        let time = ProcessInfo.processInfo.systemUptime
        let thermal = ProcessInfo.processInfo.thermalState
        let appCPU = treo_process_cpu_seconds()
        let mainCPU = treo_afk_current_thread_cpu()
        let direct = treo_vm_fast_method_calls()
        let fallback = treo_vm_switch_method_calls()
        let contended = treo_vm_monitor_contentions()
        let retries = treo_vm_monitor_retries()
        let elidedDraws = treo_afk_elided_calls()
        let utf16Fast = treo_vm_utf16_fast_calls()
        let arrayLookupFast = treo_vm_array_lookup_fast_calls()
        let ninjaMatched = treo_ninja_deep_verified()
        let ninjaRepaints = treo_ninja_deep_skipped(0)
        let ninjaServices = treo_ninja_deep_skipped(1)
        let ninjaPaints = treo_ninja_deep_skipped(2)
        let displayPolls = treo_display_poll_calls()
        let displayWaits = treo_display_wait_calls()
        let displayTimeouts = treo_display_wait_timeouts()
        let displayWakeSignals = treo_display_wake_signals()
        let displayGCSafeWaits = treo_display_gc_safe_wait_calls()
        let nsoRequests = treo_nso_repaint_requests()
        let nsoCanvasSeen = treo_nso_canvas_recognized()
        let imageHits = treo_image_cache_hits()
        let imageStores = treo_image_cache_stores()
        let imageStoredBytes = treo_image_cache_stored_bytes()
        let paintCPU = treo_afk_paint_cpu_ns()
        let paints = treo_afk_paint_count()
        let layerFrames = treo_afk_layer_frames()
        let gcCycles = treo_gc_smart_count()
        let springboardMotion = AnimatedBackgroundView.springboardAnimating
        let springboardPauseLayers = AnimatedBackgroundView.springboardPauseLayers
        let springboardLoops = AnimatedBackgroundView.springboardAnimationLoops
    }

    private func showBlackout(mode: Int32 = 1, smartGC: Bool = false,
                              deepPaint: Bool = false) {
        guard blackout == nil, jarAuditID == nil else { return }
        discardCPUProfile()
        blackoutRequestedMode = mode
        blackoutNSOLiveHz = treo_nso_prior_repaint_hz()
        for code in Array(heldDirections) { releaseDirection(code) }
        let cover = UIButton(type: .custom)
        cover.backgroundColor = .black
        cover.setTitle(blackoutModeTitle(), for: .normal)
        cover.setTitleColor(UIColor(white: 0.48, alpha: 1), for: .normal)
        cover.titleLabel?.font = .systemFont(ofSize: 14)
        cover.titleLabel?.numberOfLines = 0
        cover.titleLabel?.textAlignment = .center
        // Place status above the center. Do not animate or update it every frame.
        cover.titleEdgeInsets = UIEdgeInsets(top: 0, left: 16, bottom: 142, right: 16)
        cover.isAccessibilityElement = false
        cover.translatesAutoresizingMaskIntoConstraints = false
        // Intentionally do NOT attach hideBlackout to the full-screen cover.
        // It absorbs touches outside the explicit wake button so the JAR
        // never sees them and moving a finger cannot accidentally dismiss.
        view.addSubview(cover)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: view.topAnchor),
            cover.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cover.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        let wake = UIButton(type: .custom)
        wake.setImage(UIImage(systemName: "arrow.uturn.backward"), for: .normal)
        wake.tintColor = UIColor(white: 0.88, alpha: 1)
        wake.backgroundColor = UIColor(white: 0.18, alpha: 1)
        wake.layer.cornerRadius = 36
        wake.layer.borderColor = UIColor(white: 0.40, alpha: 1).cgColor
        wake.layer.borderWidth = 1
        wake.accessibilityLabel = "Thoát Treo và trở lại game"
        wake.accessibilityHint = "Chỉ nút tròn ở giữa mới thoát chế độ Treo"
        wake.accessibilityIdentifier = "jarbox-treo-wake"
        wake.translatesAutoresizingMaskIntoConstraints = false
        wake.addTarget(self, action: #selector(hideBlackout), for: .touchUpInside)
        cover.addSubview(wake)
        NSLayoutConstraint.activate([
            wake.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            wake.centerYAnchor.constraint(equalTo: cover.centerYAnchor),
            wake.widthAnchor.constraint(equalToConstant: 72),
            wake.heightAnchor.constraint(equalToConstant: 72)
        ])
        // Three separate, non-interactive status lines below the wake control.
        let stats = UILabel()
        stats.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        stats.textColor = UIColor(white: 0.62, alpha: 1)
        stats.textAlignment = .center
        stats.numberOfLines = 3
        stats.isUserInteractionEnabled = false
        stats.translatesAutoresizingMaskIntoConstraints = false
        cover.addSubview(stats)
        NSLayoutConstraint.activate([
            stats.centerXAnchor.constraint(equalTo: cover.centerXAnchor),
            stats.topAnchor.constraint(equalTo: wake.bottomAnchor, constant: 24),
            stats.leadingAnchor.constraint(greaterThanOrEqualTo: cover.leadingAnchor, constant: 16),
            stats.trailingAnchor.constraint(lessThanOrEqualTo: cover.trailingAnchor, constant: -16)
        ])
        blackout = cover
        blackoutStatsLabel = stats
        blackoutHUDUpdates = 0
        blackoutBatteryMonitoringWasEnabled = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        updateBlackoutDashboard()
        let statsTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in self?.updateBlackoutDashboard() }
        }
        statsTimer.tolerance = 3.0
        blackoutStatsTimer = statsTimer
        // Reset sampling before AFK starts. The springboard animation fix is untouched.
        treo_vm_paint_sample_reset()
        treo_render_set_afk_mode(mode)
        // Only verified NSO Canvas in the specialized mode. Its repaint and
        // serviceRepaints paths are already elided, so the Display thread can
        // wait for input, screen changes or the forced wake instead of
        // polling every ~16ms. GC treats the native wait as a blocked thread.
        blackoutNSODeepIdle = mode == 8 && deepPaint &&
            treo_ninja_deep_verified() != 0 && treo_nso_canvas_recognized() != 0
        if blackoutNSODeepIdle { treo_display_wait_set(1) }
        if deepPaint {
            treo_afk_guard_auto_set(1)
            jarBoxDeepTreoStart = GenericTreoSnapshot()
        }
        jarBoxSmartTreo = smartGC
        if smartGC {
            jarBoxSmartStartedAt = ProcessInfo.processInfo.systemUptime
            treo_gc_smart_set(1)
        }
        if let screen = view.window?.windowScene?.screen {
            blackoutScreen = screen
            previousBrightness = screen.brightness
            screen.brightness = 0
        }
        // iOS provides coarse device thermal pressure, not a chip temperature
        // in Celsius. Read the state before registering (Apple requirement).
        // Notification-based: no recurring timer or CPU sampling work.
        blackoutWorstThermal = ProcessInfo.processInfo.thermalState
        blackoutThermalEvents = 0
        blackoutThermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recordTreoThermalChange() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(hideBlackout), name: UIApplication.willResignActiveNotification, object: nil)
        vmTreoProbeStart = VMTreoProbe()
    }

    @objc private func hideBlackout() {
        guard blackout != nil else { return }
        // Stop all passive UI work and restore monitoring before teardown.
        let hudUpdates = blackoutHUDUpdates
        stopBlackoutDashboard()
        blackoutHUDUpdates = 0
        if let blackoutThermalObserver {
            NotificationCenter.default.removeObserver(blackoutThermalObserver)
            self.blackoutThermalObserver = nil
        }
        let thermalEnd = ProcessInfo.processInfo.thermalState
        let thermalPeak = [blackoutWorstThermal, thermalEnd].compactMap { $0 }
            .max { $0.rawValue < $1.rawValue } ?? thermalEnd
        let thermalEvents = blackoutThermalEvents
        blackoutWorstThermal = nil
        blackoutThermalEvents = 0

        let vmLog: String? = vmTreoProbeStart.map { start in
            let end = VMTreoProbe()
            let dt = max(0.001, end.time - start.time)
            func percent(_ a: Double, _ b: Double) -> String {
                guard a >= 0, b >= a else { return "?" }
                return String(format: "%.1f", 100 * (b - a) / dt)
            }
            let direct = end.direct &- start.direct
            let fallback = end.fallback &- start.fallback
            let monitors = end.contended &- start.contended
            let retries = end.retries &- start.retries
            let backend = treo_vm_direct_dispatch_build() != 0 ? "computed-goto" : "switch"
            let bridge = treo_vm_paint_bridge_build() != 0 ? "on" : "off"
            let paintsHz = Double(end.paints &- start.paints) / dt
            let frames = end.layerFrames &- start.layerFrames
            let gc = end.gcCycles &- start.gcCycles
            let springboardMotion = end.springboardMotion ? "running" : "paused"
            let springboardLoops = end.springboardLoops &- start.springboardLoops
            let elided = end.elidedDraws &- start.elidedDraws
            let utf16Fast = end.utf16Fast &- start.utf16Fast
            let arrayLookupFast = end.arrayLookupFast &- start.arrayLookupFast
            let arrayLookupBuild = treo_vm_array_lookup_build() != 0 ? "on" : "off"
            let ninjaProfile = end.ninjaMatched != 0 ? "matched" : "generic"
            let ninjaRepaints = end.ninjaRepaints &- start.ninjaRepaints
            let ninjaServices = end.ninjaServices &- start.ninjaServices
            let ninjaPaints = end.ninjaPaints &- start.ninjaPaints
            let utf16Build = treo_vm_utf16_fast_build() != 0 ? "on" : "off"
            let imageCacheBuild = treo_image_cache_build() != 0 ? "on" : "off"
            let imageCacheHits = end.imageHits &- start.imageHits
            let imageCacheStores = end.imageStores &- start.imageStores
            let imageStoredBytes = end.imageStoredBytes &- start.imageStoredBytes
            let paintCPUmsPerSecond = Double(end.paintCPU &- start.paintCPU) / dt / 1_000_000
            return String(format:
                "[JarBoxVM][Treo] %.1fs · dispatch=%@ · paint_bridge=%@ · bridge_elided_draw_calls=%llu · utf16_fast=%@ · utf16_fast_calls~%llu · array_lookup=%@ · array_lookup_fast_calls~%llu · ninja_profile=%@ · ninja_repaint_skips=%llu · ninja_service_skips=%llu · ninja_paint_skips=%llu · image_cache=%@ · image_cache_hits~%llu · image_cache_stores=%llu · image_cache_stored_bytes_total=%llu · paint_CPU=%.2fms/s · direct_methods~%llu · switch_methods~%llu · monitor_contended=%llu · monitor_failed_acquires=%llu · app_CPU=%@%% · main_CPU=%@%% · paint=%.2f/s · layer_frames=%llu · smart_GC=%llu · springboard_motion=%@ · springboard_layers_at_pause=%d · springboard_loops_during_treo=%llu · thermal_start=%@ · thermal_end=%@ · thermal_peak=%@ · thermal_changes=%d · hud_updates=%d. Counts batched/64; paint is not game ticks; CPU is not watts; thermal state is not degrees Celsius.",
                dt, backend, bridge, elided, utf16Build, utf16Fast,
                 arrayLookupBuild, arrayLookupFast,
                ninjaProfile, ninjaRepaints, ninjaServices, ninjaPaints,
                imageCacheBuild, imageCacheHits, imageCacheStores, imageStoredBytes,
                paintCPUmsPerSecond,
                direct, fallback, monitors, retries,
                percent(start.appCPU, end.appCPU), percent(start.mainCPU, end.mainCPU),
                paintsHz, frames, gc,
                springboardMotion, end.springboardPauseLayers, springboardLoops,
                Self.treoThermalLabel(start.thermal), Self.treoThermalLabel(thermalEnd),
                Self.treoThermalLabel(
                    thermalPeak.rawValue >= start.thermal.rawValue ? thermalPeak : start.thermal),
                thermalEvents, hudUpdates)
        }
        let pulseLog: String? = vmTreoProbeStart.map { start in
            let end = VMTreoProbe()
            let dt = max(0.001, end.time - start.time)
            let requests = end.nsoRequests &- start.nsoRequests
            let skips = (end.ninjaRepaints &- start.ninjaRepaints) +
                        (end.ninjaServices &- start.ninjaServices) +
                        (end.ninjaPaints &- start.ninjaPaints)
            let specialized = blackoutRequestedMode == 8 &&
                              end.ninjaMatched != 0 && end.nsoCanvasSeen != 0 &&
                              skips > 0
            let mode = specialized ? "chuyen_biet_NSO" : "chuan"
            let pulseHz = Double(requests) / dt
            let baseline = blackoutNSOLiveHz
            let gapMs = treo_nso_last_repaint_gap_ms()
            func rateText(_ rate: Double) -> String {
                return rate >= 0 && rate.isFinite
                    ? String(format: "%.2f", rate) : "?"
            }
            let ratio = baseline > 0
                ? String(format: "%.1f%%", 100.0 * pulseHz / baseline) : "?"
            let status: String
            if !specialized {
                status = "khong_co_tin_hieu_chuyen_biet"
            } else if requests == 0 || (gapMs >= 5000) {
                status = "nghi_ngung_nhip"
            } else if baseline <= 0 {
                status = "chua_co_moc_truoc_treo"
            } else if pulseHz < baseline * 0.85 {
                status = "nghi_cham_nhip"
            } else {
                status = "nhip_yeu_cau_khung_hinh_on"
            }
            return "[JarBoxVM][GamePulse] mode=\(mode) · source=NSO_Canvas.repaint_requests" +
                " · pre_8s_hz=\(rateText(baseline)) · treo_hz=\(rateText(pulseHz))" +
                " · rate_ratio=\(ratio) · requests=\(requests)" +
                " · last_request_gap_ms=\(rateText(gapMs)) · status=\(status)." +
                " Đây chỉ là nhịp yêu cầu vẽ từ vòng game, không xác nhận logic/auto/mạng/server vẫn tiến triển."
        }
        // Same integer-work probe on the SAME NSO repaint-requesting thread,
        // before vs. during Treo. QoS and ns/step are observable; physical
        // P/E-core assignments and CPU frequency are NOT available here.
        let computeLog: String? = vmTreoProbeStart.map { _ in
            let preN = treo_nso_work_samples(0)
            let duringN = treo_nso_work_samples(1)
            let preCPU = treo_nso_work_ns_per_step(0, 0)
            let duringCPU = treo_nso_work_ns_per_step(1, 0)
            let preWall = treo_nso_work_ns_per_step(0, 1)
            let duringWall = treo_nso_work_ns_per_step(1, 1)
            let preQoS = treo_nso_work_qos(0)
            let duringQoS = treo_nso_work_qos(1)
            let owner = treo_nso_work_thread()
            func value(_ amount: Double) -> String {
                return amount > 0 && amount.isFinite
                    ? String(format: "%.3f", amount) : "?"
            }
            let valid = preN >= 3 && duringN >= 6 &&
                preCPU > 0 && duringCPU > 0 && preWall > 0 && duringWall > 0
            let cpuRatio = valid ? duringCPU / preCPU : -1
            let wallRatio = valid ? duringWall / preWall : -1
            let qosText = preQoS >= 0 && duringQoS >= 0
                ? (preQoS == duringQoS ? "unchanged" : "changed") : "unknown"
            let speedStatus: String
            if !valid {
                speedStatus = "chua_du_mau"
            } else if cpuRatio > 1.30 {
                speedStatus = "nghi_giam_toc_tinh_toan"
            } else if wallRatio > 1.35 && cpuRatio <= 1.15 {
                speedStatus = "nghi_tang_do_tre_lap_lich"
            } else {
                speedStatus = "khong_thay_giam_toc_ro"
            }
            return "[JarBoxVM][NSOCompute] same_thread_id=\(owner)" +
                " · samples_pre=\(preN) · samples_treo=\(duringN)" +
                " · cpu_ns_per_step=\(value(preCPU))->\(value(duringCPU))" +
                " · wall_ns_per_step=\(value(preWall))->\(value(duringWall))" +
                " · cpu_slowdown=\(value(cpuRatio))x" +
                " · wall_slowdown=\(value(wallRatio))x" +
                " · thread_qos=\(preQoS)->\(duringQoS)(\(qosText))" +
                " · status=\(speedStatus)." +
                " Fixed-work proxy only; not P/E core ID, CPU MHz, watts or proof of game/server progress."
        }
        let displayIdleLog: String? = vmTreoProbeStart.map { start in
            let end = VMTreoProbe()
            let dt = max(0.001, end.time - start.time)
            let polls = end.displayPolls &- start.displayPolls
            let waits = end.displayWaits &- start.displayWaits
            let timeouts = end.displayTimeouts &- start.displayTimeouts
            let wakes = end.displayWakeSignals &- start.displayWakeSignals
            let gcSafe = end.displayGCSafeWaits &- start.displayGCSafeWaits
            return String(format:
                "[JarBoxVM][DisplayIdle] enabled=%d · display_polls=%llu · polls_hz=%.2f · waits=%llu · waits_hz=%.2f · timeouts=%llu · wake_signals=%llu · gc_safe_waits=%llu. Display-thread only; not game tick rate or power consumption.",
                blackoutNSODeepIdle ? 1 : 0,
                polls, Double(polls) / dt, waits, Double(waits) / dt,
                timeouts, wakes, gcSafe)
        }
        vmTreoProbeStart = nil
        let paintHotReport = String(cString: treo_vm_paint_sample_report())
        if let vmLog { NSLog("%@", vmLog) }
        if let pulseLog { NSLog("%@", pulseLog) }
        if let computeLog { NSLog("%@", computeLog) }
        if let displayIdleLog { NSLog("%@", displayIdleLog) }
        let arrayLookupDiag = String(cString: treo_vm_array_lookup_diag_report())
        if arrayLookupDiag.hasPrefix("[JarBoxVM][ArrayLookupDiag] enabled=1") {
            NSLog("%@", arrayLookupDiag)
        }
        NSLog("%@", paintHotReport)
        afkMeasure?.cancel()
        genericTreoWork?.cancel()
        genericTreoWork = nil
        genericTreoComparisonID = nil
        gameCanvasBlitAuditWork?.cancel()
        gameCanvasBlitAuditWork = nil
        gameCanvasBlitAuditID = nil
        mainStackAuditWork?.cancel()
        mainStackAuditWork = nil
        mainStackAuditID = nil
        treo_afk_buffer_audit_set(0, 0)
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
        let deepEnd = jarBoxDeepTreoStart.map { start -> String in
            let end = GenericTreoSnapshot()
            let skipped = end.guarded &- start.guarded
            let real = end.real &- start.real
            let late = end.late &- start.late
            let fallback = treo_afk_guard_auto_fell_back() != 0
            return "\nCanvas bỏ raster \(skipped) lượt; giữ vẽ \(real) lượt; pixel muộn \(late). " +
                (fallback ? "Đã tự lui về Treo tương thích." : "Không phát hiện fallback.")
        } ?? ""
        treo_afk_guard_auto_set(0)
        jarBoxDeepTreoStart = nil
        // Unpark Display before forced screen redraw on wake.
        if blackoutNSODeepIdle {
            treo_display_wait_set(0)
            blackoutNSODeepIdle = false
        }
        j2me_render_set_afk_suspended(0)
        if jarBoxSmartTreo {
            let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - (jarBoxSmartStartedAt ?? ProcessInfo.processInfo.systemUptime))
            let gcCount = treo_gc_smart_count()
            let gcCpu = treo_gc_smart_cpu_ms()
            let peak = Double(treo_gc_smart_heap_peak()) / 1_048_576
            let fallback = treo_gc_smart_fell_back() != 0
            treo_gc_smart_set(0)
            jarBoxSmartTreo = false
            jarBoxSmartStartedAt = nil
            if !showComparison {
                lastMeasurement = (deepEnd.isEmpty ? "Treo JarBox · GC thông minh" : "Treo sâu JarBox · GC & Raster",
                    String(format: "Thời gian treo %.1f giây. GC thật %llu chu kỳ; CPU GC %.2f ms/s; heap peak %.1f MiB (Java + native theo bộ đếm GC). %@. Chế độ 500ms được khôi phục. Không đo watt, không xác nhận logic game vẫn chạy nếu game phụ thuộc hiển thị.",
                        elapsed, gcCount, gcCpu / elapsed, peak,
                        fallback ? "GC đã tự trở về 500ms vì áp lực bộ nhớ" : "Không có cảnh báo GC fallback") + deepEnd)
            }
        }
        NotificationCenter.default.removeObserver(self, name: UIApplication.willResignActiveNotification, object: nil)
        if let screen = blackoutScreen, let brightness = previousBrightness, screen.brightness == 0 {
            screen.brightness = brightness
        }
        blackoutScreen = nil
        previousBrightness = nil
        blackout?.removeFromSuperview()
        blackout = nil
        blackoutRequestedMode = 0
        blackoutNSOLiveHz = -1
        if let vmLog {
            if let report = lastMeasurement {
                lastMeasurement = (report.title, report.message + "\n\n" + vmLog +
                    (pulseLog.map { "\n\n" + $0 } ?? "") +
                    (computeLog.map { "\n\n" + $0 } ?? "") +
                    (displayIdleLog.map { "\n\n" + $0 } ?? "") + "\n\n" + paintHotReport)
            } else {
                lastMeasurement = ("JarBoxVM · hiệu năng", vmLog + (pulseLog.map { "\n\n" + $0 } ?? "") +
                    (computeLog.map { "\n\n" + $0 } ?? "") +
                    (displayIdleLog.map { "\n\n" + $0 } ?? "") + "\n\n" + paintHotReport)
            }
        }
        applyPadMode()
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

    private func confirmJarAudit(profileMain: Bool = false, compareLoad: Bool = false, workerComparison: Bool = false, windowOcclusion: Bool = false, displayWaitAudit: Bool = false, mainQoSAudit: Bool = false, uikitPhases: Bool = false, sparsePaintAudit: Bool = false, energyAudit: Bool = false, throughputAudit: Bool = false, gcPeriodAudit: Bool = false, budgetMain: Bool = false, detachUI: Bool = false, measureCommit: Bool = false) {
        guard !(measureCommit || windowOcclusion || displayWaitAudit || mainQoSAudit || uikitPhases) || Self.jarCommitAuditSupported else { return }
        guard jarAuditID == nil, blackout == nil, powerRun == nil, cpuProfileStartedAt == nil else { return }
        let sourceProfile = budgetMain && profileMain
        let alert = UIAlertController(title: gcPeriodAudit ? "Thử giảm chu kỳ GC · JAR" :
                throughputAudit ? "Đo tốc độ main/game/GC · JAR" :
                energyAudit ? "Đo hao pin & nhiệt · JAR" :
                sparsePaintAudit ? "Thử paint thưa 1/3 Hz · JAR" :
                uikitPhases ? "Đo 6 pha UIKit · tắt → bật → tắt" :
                mainQoSAudit ? "Thử hạ QoS main · JAR" :
                displayWaitAudit ? "Thử Display GC-safe · JAR" :
                windowOcclusion ? "Thử cửa sổ đen foreground · JAR" :
                workerComparison ? "So tải game và luồng native · JAR" : measureCommit ? "Đo CPU quanh commit UIKit · JAR" :
                detachUI ? "Thử tháo giao diện game · JAR" :
                sourceProfile ? "Tìm stack sau Source · JAR" :
                budgetMain ? "Đo pha CPU main · JAR" :
                (compareLoad ? "Thử chờ thụ động · CPU main" :
                 (profileMain ? "Tìm hàm ăn CPU main" : "Chẩn đoán CPU JAR")),
            message: gcPeriodAudit
                ? "Map 37, auto x1, BẬT Treo tối ưu CPU trong JAR từ trước; giữ BẬT suốt cả 3 lượt. A1 thu gom GC gốc mỗi 0,5s → B thử mỗi 2s → A2 trở về 0,5s, tự chuyển, 30 giây/lượt. Bộ nhớ vượt 52,5% heap tối đa sẽ tự hủy thử B và về 0,5s. Cả ba lượt chặn khung native, tắt JIT. Đo số chu kỳ GC, thời gian CPU GC, bộ nhớ peak, CPU tổng, main, tốc độ game; không can thiệp logic/auto/network."
                : throughputAudit
                ? "Map 37, auto x1, đầu tiên TẮT Treo tối ưu CPU trong JAR. Đo A1 tắt → B bật → A2 tắt, 30 giây/lượt, có hướng dẫn đổi trạng thái. Mỗi lượt giữ chặn khung native, tắt JIT. Ghi cùng 120.000 phép tính trên main, game, GC thật (CPU time và thời gian thực) cùng số lần/chi phí thu gom GC. Lấy mẫu thưa, không tạo luồng tải giả; không đo trực tiếp watt, lõi P/E hay xung nhịp. Chỉ kết luận nếu game giữ nhịp và đủ mẫu."
                : energyAudit
                ? "Map 37, auto x1, bắt đầu với Treo trong JAR đang TẮT. Đo A1 TẮT → B BẬT → A2 TẮT, chỉ 2 phút/lượt (6 phút tổng); tự nhắc bạn đổi trạng thái giữa các lượt. GIỮ iPhone trên pin (không sạc), cùng độ sáng cố định, không đổi mạng, không khóa màn hình, không kéo Trung tâm thông báo. Không chặn khung native: A1/A2 là game hiển thị bình thường, B là treo JAR thực tế; tắt JIT suốt bài. Ghi CPU time từ getrusage, pin, nhiệt hệ thống, độ sáng, tick và benchmark. Vì mỗi lượt chỉ 2 phút, biến động pin 0–1% KHÔNG đủ kết luận mức hao pin; ưu tiên CPU time và benchmark. Không đo watt hay nhiệt độ °C. Có Hủy và tự hoàn nguyên cài đặt."
                : sparsePaintAudit
                ? "Map 37, auto x1, BẬT Treo tối ưu CPU trong JAR trước. Không bật màn đen JarBox. 4 lượt × 30 giây: A1 không paint → B ép paint thật 1 lần/giây → C 3 lần/giây → A2 không paint; tự chuyển, không cần chạm. Khung game vẫn bị chặn native. Đo CPU tổng/main, tốc độ phép tính cố định, tick và số paint thực. CẢNH BÁO: paint của JAR có thể chứa logic, chỉ dùng để chẩn đoán. Có Hủy; tự tắt ép paint sau thử."
                : uikitPhases
                ? "Map 37, auto x1, ban đầu TẮT treo trong JAR. Đo A1 tắt → B bật → A2 tắt, mỗi lượt 30 giây và chuyển theo hướng dẫn trên màn hình. Cả ba lượt cùng chặn khung native, tạm tắt JIT, không thêm tải giả và không sửa QoS. Đo 6 khoảng UIKit và 12 lần tính toán cố định rất ngắn trên main mỗi lượt, kiểm tra tốc độ xử lý thay vì cố ép QoS. Kiểm tra treo đúng trạng thái từ 3 giây đầu. Chỉ kết luận nếu mốc ghép đủ và game giữ nhịp."
                : mainQoSAudit
                ? "Map 37, auto x1, BẬT treo trong JAR trước. Không bật màn đen JarBox hay kéo Trung tâm thông báo. A1 QoS gốc → B User Initiated → C Utility → A2 QoS gốc, 4 lượt × 30 giây. Không tạo tải giả, chỉ đổi QoS main thread; VM/game giữ nguyên. Đo CPU tổng, main, tick và cập nhật UIKit. Nếu iOS từ chối đổi QoS hoặc game chậm, báo không hợp lệ. Có Hủy và tự khôi phục QoS khi kết thúc."
                : displayWaitAudit
                ? "Map 37, auto x1, BẬT treo trong JAR trước, không bật màn đen JarBox riêng. A1 polling cũ → B chờ native GC-safe tối đa 250ms → A2 polling cũ, mỗi lượt 30 giây. B khai báo is_blocking cho miniJVM GC trong lúc ngủ và bắt buộc nhịp game ~25,5/s; kiểm tra poll/wait/GC-safe/timeout và CPU tổng. JIT tắt, chặn khung như nhau; giữ auto, không chạm game. Không tự bật tối ưu sau thử."
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
            self?.startJarAudit(profileMain: profileMain, compareLoad: compareLoad, workerComparison: workerComparison, windowOcclusion: windowOcclusion, displayWaitAudit: displayWaitAudit, mainQoSAudit: mainQoSAudit, uikitPhases: uikitPhases, sparsePaintAudit: sparsePaintAudit, energyAudit: energyAudit, throughputAudit: throughputAudit, gcPeriodAudit: gcPeriodAudit, budgetMain: budgetMain, detachUI: detachUI, measureCommit: measureCommit)
        })
        present(alert, animated: true)
    }

    private func startJarAudit(profileMain: Bool, compareLoad: Bool, workerComparison: Bool, windowOcclusion: Bool, displayWaitAudit: Bool, mainQoSAudit: Bool, uikitPhases: Bool, sparsePaintAudit: Bool, energyAudit: Bool, throughputAudit: Bool, gcPeriodAudit: Bool, budgetMain: Bool, detachUI: Bool, measureCommit: Bool) {
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
        jarThroughputAudit = throughputAudit
        jarGCPeriodAudit = gcPeriodAudit
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
        treo_diag_set(0)
        treo_gc_probe_set_period_ms(0)
        jarGCPeriodAudit = false
        jarThroughputAudit = false
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

    // Identical short native integer-work benchmark on three existing pthreads.
    // These are mean nanoseconds/iteration, NOT MHz, P/E core IDs or Joules.
    private struct JarThroughputStats {
        let mainN = treo_diag_samples(0)
        let gameN = treo_diag_samples(1)
        let gcN = treo_diag_samples(2)
        let mainCPU = treo_diag_ns_per_step(0, 0)
        let gameCPU = treo_diag_ns_per_step(1, 0)
        let gcCPU = treo_diag_ns_per_step(2, 0)
        let mainWall = treo_diag_ns_per_step(0, 1)
        let gameWall = treo_diag_ns_per_step(1, 1)
        let gcWall = treo_diag_ns_per_step(2, 1)
        let cycles = treo_diag_gc_cycles()
        let cycleCPUms = treo_diag_gc_cpu_ms()
        let cycleWallms = treo_diag_gc_wall_ms()

        var valid: Bool {
            mainN >= 8 && gameN >= 8 && gcN >= 2 &&
            mainCPU > 0 && gameCPU > 0 && gcCPU > 0
        }

        func detail(wallSeconds: Double) -> String {
            var rows: [String] = []
            let samples: [(String, UInt64, Double, Double)] = [
                ("main", mainN, mainCPU, mainWall),
                ("game", gameN, gameCPU, gameWall),
                ("GC", gcN, gcCPU, gcWall)
            ]
            for (name, count, cpu, wall) in samples {
                rows.append(String(format: "%@: %llu mẫu · CPU %.3f ns/phép · wall %.3f ns/phép",
                                   name, count, cpu, wall))
            }
            rows.append(String(format:
                "GC thật: %llu chu kỳ · CPU %.1f ms/s · wall %.1f ms/s (thời gian ngừng thế giới có thể nằm trong wall)",
                cycles, cycleCPUms / max(0.001, wallSeconds), cycleWallms / max(0.001, wallSeconds)))
            return rows.joined(separator: "\n")
        }
    }

    private func scheduleJarMainBench(id: UUID, leg: Int, left: Int) {
        guard left > 0 else { return }
        let interval = jarEnergyAudit ? 7.0 : 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, self.jarAuditID == id,
                  (self.jarUIKitPhaseAudit || self.jarSparsePaintAudit || self.jarEnergyAudit || self.jarThroughputAudit || self.jarGCPeriodAudit),
                  self.jarMainBenchLeg == leg else { return }
            if self.jarThroughputAudit || self.jarGCPeriodAudit {
                treo_diag_sample(0)
            } else {
                let time = treo_main_fixed_work_ns_per_step()
                if time > 0 { self.jarMainBenchSamples.append(time) }
            }
            self.scheduleJarMainBench(id: id, leg: leg, left: left - 1)
        }
    }

    private struct JarAuditResult {
        let wallDuration: Double
        let total: Double?
        let main: Double?
        let ticks: Double
        let paint: Double
        let budget: [Double]?
        let commit: JarCommitBudget.Result?
        let phases: JarUIKitPhaseBudget.Result?
        let mainBenchNS: Double?
        let throughput: JarThroughputStats?
        let gcPeakBytes: UInt64
        let gcFallbacks: UInt64
        let gcPeriodMs: Int32
        let sparseRate: Double
        let actualPaintRate: Double
        let batteryDropPerHour: Double?
        let energyStable: Bool
        let loadCPU: Double
        let loadRate: Double
    }

    private func runJarAudit(id: UUID, leg: Int, rows: [String], results: [JarAuditResult]) {
        // Energy audit measures ACTUAL usage; cross-thread diagnostics use
        // matching native frame suppression in all three A/B/A legs.
        treo_render_set_afk_mode(jarEnergyAudit ? 0 : 1)
        treo_diag_set(0)
        let gcPeriodMs: Int32 = jarGCPeriodAudit && leg == 1 ? 2000 : 0
        treo_gc_probe_set_period_ms(gcPeriodMs)
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
            if self.jarUIKitPhaseAudit || self.jarSparsePaintAudit || self.jarEnergyAudit || self.jarThroughputAudit || self.jarGCPeriodAudit {
                let observedOn = treo_jar_audit_ticks(1) &- settleOn
                let observedOff = treo_jar_audit_ticks(0) &- settleOff
                let expectedOn = self.jarSparsePaintAudit || self.jarGCPeriodAudit || leg == 1
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
            if self.jarThroughputAudit || self.jarGCPeriodAudit { treo_diag_set(1) }
            let powerStart: JarPowerSnapshot? = self.jarEnergyAudit ? JarPowerSnapshot() : nil
            if self.jarEnergyAudit {
                self.jarEnergyLeg = leg
                self.jarEnergySamples.removeAll()
                self.scheduleJarEnergySample(id: id, leg: leg, remaining: 3)
            }
            if self.jarUIKitPhaseAudit || self.jarSparsePaintAudit || self.jarEnergyAudit || self.jarThroughputAudit || self.jarGCPeriodAudit {
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
            // Explicit branch selection avoids a fragile nested ternary that
            // previously left the scheduleJarAudit call with an unmatched ')'.
            let measurementSeconds: Double
            if self.jarEnergyAudit {
                measurementSeconds = 120
            } else if profileMain && !sourceProfile {
                measurementSeconds = 20
            } else if self.jarMainQoSAudit || self.jarDisplayWaitAudit ||
                        self.jarUIKitPhaseAudit || self.jarSparsePaintAudit || self.jarThroughputAudit || self.jarGCPeriodAudit {
                measurementSeconds = 30
            } else if self.jarWindowAudit {
                measurementSeconds = 25
            } else if self.jarWorkerComparison {
                measurementSeconds = 30
            } else if self.jarLoadComparison {
                measurementSeconds = 25
            } else {
                measurementSeconds = 60
            }
            self.scheduleJarAudit(id: id, after: measurementSeconds) { [weak self] in
                guard let self else { return }
                let end = JarAuditSample()
                if self.jarThroughputAudit || self.jarGCPeriodAudit { treo_diag_set(0) }
                let throughput: JarThroughputStats? =
                    (self.jarThroughputAudit || self.jarGCPeriodAudit) ? JarThroughputStats() : nil
                let gcPeakBytes = treo_gc_probe_peak_heap_bytes()
                let gcFallbacks = treo_gc_probe_fallbacks()
                let gcActivePeriod = treo_gc_probe_current_period_ms()
                let powerEnd: JarPowerSnapshot? = self.jarEnergyAudit ? JarPowerSnapshot() : nil
                let energySamples = self.jarEnergySamples
                self.jarEnergyLeg = -1
                let dt = max(0.001, end.base.time - start.base.time)
                let on = end.on &- start.on, off = end.off &- start.off
                let compareLoad = self.jarLoadComparison
                let workerCompare = self.jarWorkerComparison
                let names = self.jarGCPeriodAudit
                    ? ["A1 · GC 500ms", "B · GC 2000ms", "A2 · GC 500ms"]
                    : self.jarThroughputAudit
                    ? ["A1 · JAR tắt (luồng)", "B · JAR bật (luồng)", "A2 · JAR tắt (luồng)"]
                    : self.jarEnergyAudit
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
                let validState = (detachUI || compareLoad || workerCompare || windowAudit || displayAudit || qosAudit || sparseAudit || self.jarGCPeriodAudit || leg == 1) ? (on > 0 && off == 0) : (off > 0 && on == 0)
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
                if self.jarGCPeriodAudit {
                    row += String(format: "\nGC đặt %dms · sau kiểm tra %dms · peak %.1f MiB (Java+native) · fallback %llu.",
                        gcPeriodMs == 0 ? 500 : gcPeriodMs,
                        gcActivePeriod == 0 ? 500 : gcActivePeriod,
                        Double(gcPeakBytes) / 1048576, gcFallbacks)
                }
                if (self.jarThroughputAudit || self.jarGCPeriodAudit), let throughput {
                    row += "\n" + throughput.detail(wallSeconds: dt)
                    if !throughput.valid {
                        row += "\nKHÔNG ĐỦ MẪU: main/game cần ít nhất 8, GC ít nhất 2."
                    }
                }
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
                if self.jarGCPeriodAudit && (gcFallbacks > 0 || gcActivePeriod != gcPeriodMs) {
                    row += "\nKHÔNG HỢP LỆ: GC không giữ được chu kỳ yêu cầu vì áp lực bộ nhớ."
                }
                let all = rows + [row]
                let validDisplay = !displayAudit || leg != 1 ||
                    (displayWaits >= 1 && abs(displayGcSafeWaits - displayWaits) <= 0.1)
                let validQoS = !qosAudit || treo_main_qos_expected(qosMode) == treo_main_qos_current()
                let validEnergy = !self.jarEnergyAudit || energyStable
                let validThroughput = !(self.jarThroughputAudit || self.jarGCPeriodAudit) || (throughput?.valid ?? false)
                let validGCPeriod = !self.jarGCPeriodAudit ||
                    (gcFallbacks == 0 && (gcActivePeriod == gcPeriodMs))
                let targetHz = Double(sparseHz)
                let validSparse = !sparseAudit || (targetHz == 0
                    ? (sparseRate <= 0.15 && paints <= 0.15)
                    : (abs(sparseRate - targetHz) <= 0.45
                       && abs(paints - targetHz) <= 0.45))
                if !validSparse { row += "\nKHÔNG HỢP LỆ: paint thực tế khác tần suất yêu cầu." }
                let validFrames = self.jarEnergyAudit ? (leg == 1 || frames > 0) : frames == 0
                guard validState && validUI && validWindow && validDisplay && validQoS && validSparse && validEnergy && validThroughput && validGCPeriod && validFrames else {
                    self.finishJarAudit(rows: all, results: [])
                    return
                }
                let measured = results + [JarAuditResult(wallDuration: dt, total: total, main: main, ticks: ticks, paint: paint,
                    budget: budget, commit: commit, phases: phases, mainBenchNS: mainBenchNS,
                    throughput: throughput,
                    gcPeakBytes: gcPeakBytes, gcFallbacks: gcFallbacks, gcPeriodMs: gcActivePeriod,
                    sparseRate: sparseRate, actualPaintRate: paints,
                    batteryDropPerHour: batteryDropPerHour, energyStable: energyStable,
                    loadCPU: Double(end.loadNS &- start.loadNS) / dt / 10_000_000,
                    loadRate: Double(end.loadCalls &- start.loadCalls) / dt)]
                if workerCompare && leg == 1 {
                    treo_jar_load_worker_period_set(UInt64((1_000_000_000.0 / max(1.0, ticks)).rounded()))
                }
                if leg == (compareLoad || workerCompare || qosAudit || sparseAudit ? 3 : 2) || (profileMain && !sourceProfile && leg == 1) {
                    self.finishJarAudit(rows: all, results: measured)
                } else if compareLoad || workerCompare || detachUI || windowAudit || displayAudit || qosAudit || sparseAudit || self.jarGCPeriodAudit {
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
        let throughputAudit = jarThroughputAudit
        let gcPeriodAudit = jarGCPeriodAudit
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
        if gcPeriodAudit && results.count == 3,
           let a = results[0].throughput,
           let b = results[1].throughput,
           let c = results[2].throughput {
            let gcACPU = (a.cycleCPUms / Double(max(UInt64(1), a.cycles)) + c.cycleCPUms / Double(max(UInt64(1), c.cycles))) / 2
            summary += "THỬ GC THƯA KHI JAR TREO (3 lượt đều bật treo):\n"
            summary += String(format:
                "Chu kỳ GC: A1 %llu · B %llu · A2 %llu; CPU GC %.1f · %.1f · %.1f ms/s.\n",
                a.cycles, b.cycles, c.cycles,
                a.cycleCPUms / max(0.001, results[0].wallDuration),
                b.cycleCPUms / max(0.001, results[1].wallDuration),
                c.cycleCPUms / max(0.001, results[2].wallDuration))
            summary += String(format: "CPU/chu kỳ GC: mốc A %.2f ms · B %.2f ms.\n",
                                      gcACPU, b.cycleCPUms / Double(max(UInt64(1), b.cycles)))
            let ra = results[0], rb = results[1], rc = results[2]
            summary += String(format: "GC peak (MiB): A1 %.1f · B %.1f · A2 %.1f; fallback B %llu.\n",
                Double(ra.gcPeakBytes) / 1048576, Double(rb.gcPeakBytes) / 1048576,
                Double(rc.gcPeakBytes) / 1048576, rb.gcFallbacks)
            summary += String(format: "CPU tổng: A1 %.1f%% · B %.1f%% · A2 %.1f%%; tick %.2f · %.2f · %.2f/s.\n",
                ra.total ?? -1, rb.total ?? -1, rc.total ?? -1,
                ra.ticks, rb.ticks, rc.ticks)
            if abs(rb.ticks - (ra.ticks + rc.ticks)/2) > 0.5 ||
                abs(ra.ticks - rc.ticks) > 0.5 {
                summary += "KHÔNG KẾT LUẬN: nhịp game lệch trên 0,5 tick/s.\n"
            }
            if abs((ra.total ?? 0) - (rc.total ?? 0)) > 3 {
                summary += "CẢNH BÁO: CPU tổng A1/A2 trôi trên 3 điểm.\n"
            }
            summary += "GC=500ms vẫn là mặc định; nhánh 2000ms chỉ tồn tại trong lượt B và tự hoàn nguyên.\n\n"
        }
        if throughputAudit && results.count == 3,
           let a = results[0].throughput,
           let b = results[1].throughput,
           let c = results[2].throughput {
            summary += "ĐỐI CHIẾU CÙNG MỘT PHÉP TÍNH TRÊN LUỒNG THẬT (B / trung bình A1,A2):\n"
            let measures: [(String, Double, Double, Double, Double, Double, Double)] = [
                ("main", a.mainCPU, b.mainCPU, c.mainCPU, a.mainWall, b.mainWall, c.mainWall),
                ("game", a.gameCPU, b.gameCPU, c.gameCPU, a.gameWall, b.gameWall, c.gameWall),
                ("GC", a.gcCPU, b.gcCPU, c.gcCPU, a.gcWall, b.gcWall, c.gcWall)
            ]
            for (name, aCPU, bCPU, cCPU, aWall, bWall, cWall) in measures {
                summary += String(format:
                    "%@: CPU %.2f× · wall %.2f× (B %.3f ns CPU/phép).\n",
                    name, bCPU / max(0.001, (aCPU + cCPU) / 2),
                    bWall / max(0.001, (aWall + cWall) / 2), bCPU)
            }
            summary += String(format:
                "GC chu kỳ A1 %llu · B %llu · A2 %llu; CPU GC chu kỳ tổng %.1f · %.1f · %.1f ms/lượt.\n",
                a.cycles, b.cycles, c.cycles, a.cycleCPUms, b.cycleCPUms, c.cycleCPUms)
            let ta = results[0].ticks, tb = results[1].ticks, tc = results[2].ticks
            if abs(tb - (ta + tc) / 2) > 0.5 || abs(ta - tc) > 0.5 {
                summary += "KHÔNG KẾT LUẬN: nhịp requestFrame lệch quá 0,5 lần/s.\n"
            }
            if a.gcN < 4 || b.gcN < 4 || c.gcN < 4 {
                summary += "CẢNH BÁO: ít mẫu GC, không diễn giải hệ số nhỏ.\n"
            }
            summary += "CPU ns/phép không phải chu kỳ máy; wall ns/phép gồm thời gian deschedule. Không xác định P/E core hay Joule.\n\n"
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
        if budgetMain || energyAudit || throughputAudit || gcPeriodAudit {
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
            let title = gcPeriodAudit ? "Thử GC thưa 500/2000ms · JAR" :
                throughputAudit ? "Đo tốc độ main/game/GC · JAR" :
                energyAudit ? "Đo hao pin & nhiệt · JAR" :
                sparseAudit ? "Thử paint thưa 1/3 Hz · JAR" :
                phaseAudit ? "Đo 6 pha UIKit · JAR" :
                qosAudit ? "Thử hạ QoS main · JAR" :
                displayAudit ? "Thử Display GC-safe · JAR" :
                windowAudit ? "Thử cửa sổ đen foreground · JAR" :
                workerCompare ? "So tải game và luồng native · JAR" :
                measureCommit ? "Đo CPU quanh commit UIKit · JAR" :
                detachUI ? "Thử tháo giao diện game · JAR" :
                (profileMain ? "Tìm stack sau Source · JAR" : "Đo pha CPU main · JAR")
            let sampling = gcPeriodAudit
                ? "JAR treo BẬT suốt 3 lượt, mỗi lượt 30 giây. A1 GC 500ms → B GC 2000ms (đủ heap mới cho phép) → A2 GC 500ms; theo dõi GC CPU/chu kỳ, tổng CPU, peak Java+native heap và nhịp game. Trên 52,5% heap tối đa, B tự trở về 500ms. Không đo watt hay sửa JAR."
                : throughputAudit
                ? "A1 tắt → B bật → A2 tắt, mỗi lượt 30 giây, cùng chặn khung native và JIT tắt. Đo cùng phép tính ngắn trên main, game, GC thật (CPU/wall ns/phép), GC chu kỳ và tick. Không tạo tải giả liên tục; không đo watt, core ID hay xung."
                : energyAudit
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

        // Reserve this worker's token together with its native slot. The
        // background launcher never reads a token that might belong to B.
        var acquiredToken: UInt64 = 0
        guard jvm_bridge_try_begin_session_with_token(&acquiredToken) != 0,
              acquiredToken != 0 else {
            showBlockedSessionAlert()
            return
        }
        ownsJVMSession = true
        gameSessionToken = acquiredToken
        setGlobalEmulatorView(emulatorView)
        j2me_render_set_afk_suspended(0)
        j2me_render_set_flush_callback(flushCallback)
        j2me_render_set_owned_flush_callback(ownedFlushCallback)
        j2me_ui_set_callback(gameUICallback)
        j2me_ui_set_owned_callback(ownedGameUICallback)
        activeGameViewController = self

        // Copy plain values on the main actor; the VM worker never reads the view controller.
        let gamePath = jarPath
        let instanceCloneID = cloneID
        let width = Int32(canvasWidth)
        let height = Int32(canvasHeight)
        let scale = Int32(render3dScale)
        let fps = Int32(fpsLimit)
        // Captured before the async worker starts. A recycled controller
        // reference or a late main-queue completion cannot inherit B's token.
        let launchingToken = gameSessionToken
        let worker = DispatchWorkItem { [weak self] in
            let failure = GameViewController.runMIDlet(
                resRoot: resRoot, jarPath: gamePath, width: width,
                height: height, scale: scale, fps: fps,
                cloneID: instanceCloneID, token: launchingToken
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ownsJVMSession,
                      self.gameSessionToken == launchingToken,
                      launchingToken != 0 else { return }
                // The native worker has already finished/unregistered A.
                // If B acquired the global slot meanwhile, A's late UIKit
                // cleanup must not reset B's Treo or render state.
                // A failed finish may leave a live slot (e.g. undrained
                // callbacks). Keep its controller and recovery identity.
                if jvm_bridge_session_is_active_for_token(launchingToken) != 0 {
                    self.gameStopRequested = true
                    self.finishStartupWatchdog()
                    self.sessionLibrary?.managedGameDidEnd(self)
                    self.showStuckSessionRecovery()
                    return
                }
                let currentToken = jvm_bridge_session_token()
                let mayResetNative = currentToken == 0 ||
                    currentToken == launchingToken
                // Hidden managed tabs have no UIKit destination. Their
                // completion must not dismiss or reset a different tab.
                if self.sessionLibrary != nil && self.libraryIsPresented {
                    self.stopEscalationWork?.cancel()
                    self.stopRescueWork?.cancel()
                    self.alertTimeoutWork?.cancel()
                    self.finishStartupWatchdog()
                    self.parkedTreoActive = false
                    self.parkedNSODeepIdle = false
                    self.ownsJVMSession = false
                    self.gameSessionToken = 0
                    self.libraryIsPresented = false
                    self.sessionLibrary?.managedGameDidEnd(self)
                    if let failure {
                        NSLog("[JarBoxVM][Lifecycle] managed parked session exited: %@", failure)
                    }
                    return
                }
                self.ownsJVMSession = false
                self.gameSessionToken = 0
                self.sessionLibrary?.managedGameDidEnd(self)
                if !mayResetNative && self.sessionLibrary == nil {
                    self.parkedTreoActive = false
                    self.parkedNSODeepIdle = false
                    self.parkedStartedAt = nil
                    self.parkedCPUStart = nil
                    self.stopEscalationWork?.cancel()
                    self.stopRescueWork?.cancel()
                    self.finishStartupWatchdog()
                    return
                }
                if !mayResetNative {
                    // Managed foreground A exited while another native
                    // owner exists. Never reset process-wide diagnostics.
                    self.finishStartupWatchdog()
                    self.dismiss(animated: true)
                    return
                }
                self.stopEscalationWork?.cancel()
                self.stopEscalationWork = nil
                self.stopRescueWork?.cancel()
                self.stopRescueWork = nil
                self.stopJarAudit()
                self.stopParkedTreo()
                self.finishStartupWatchdog()
                self.discardCPUProfile()
                self.hideBlackout()
                for code in Array(self.heldDirections) { self.releaseDirection(code) }
                if self.libraryIsPresented {
                    // Close the parked library *before* dismissing its presenting
                    // game controller. A live VM must never be abandoned behind UI.
                    self.libraryIsPresented = false
                    if let overlay = self.presentedViewController {
                        overlay.dismiss(animated: false) { [weak self] in
                            self?.dismiss(animated: true)
                        }
                    } else {
                        self.dismiss(animated: true)
                    }
                    if let failure {
                        NSLog("[JarBoxVM][Lifecycle] parked session exited: %@", failure)
                    }
                } else if self.gameStopRequested {
                    self.dismiss(animated: true)
                } else if let failure {
                    self.showLaunchFailure(failure)
                } else {
                    self.dismiss(animated: true)
                }
            }
        }
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.ownsJVMSession, !self.gameStopRequested,
                  !self.startupTimeoutShown,
                  let icon = self.placeholderIconView, !icon.isHidden else { return }
            self.startupTimeoutShown = true
            NSLog("[JarBoxVM][Lifecycle] startup_no_frame=20s phase=%d",
                  jvm_bridge_session_phase())
            guard self.presentedViewController == nil else { return }
            let alert = UIAlertController(
                title: "Game khởi động lâu",
                message: "Sau 20 giây JarBox chưa nhận được hình. " +
                         "Bạn có thể tiếp tục chờ hoặc hủy an toàn mà không phải tắt ứng dụng.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Tiếp tục chờ", style: .cancel))
            alert.addAction(UIAlertAction(title: "Hủy game", style: .destructive) {
                [weak self] _ in self?.requestGameStop(reason: "startup_timeout")
            })
            self.present(alert, animated: true)
        }
        startupWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: watchdog)
        DispatchQueue.global(qos: .userInitiated).async(execute: worker)
    }

    private func finishStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
    }

    private func showBlockedSessionAlert() {
        if sessionLibrary != nil {
            showLaunchFailure("Không còn slot JVM trống. Hãy quay về thư viện và chọn tab.")
            return
        }
        let blockedToken = jvm_bridge_session_token()
        let alert = UIAlertController(
            title: "Phiên JVM cũ chưa kết thúc",
            message: "JVM của game trước vẫn còn hoạt động (pha \(jvm_bridge_session_phase())). " +
                     "Chờ thêm sẽ không giải quyết được nếu luồng Java bị treo. " +
                     "Hãy thử ngắt phiên cũ; nếu vẫn kẹt, đóng hẳn JarBox.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Ngắt phiên cũ", style: .default) { [weak self] _ in
            let signalled = jvm_bridge_request_stop_for_token(blockedToken)
            DispatchQueue.global(qos: .userInitiated).async {
                let result = signalled != 0
                    ? jvm_bridge_interrupt_active_threads_for_token(blockedToken) : 0
                NSLog("[JarBoxVM][Lifecycle] blocked_slot_interrupt=%d", result)
            }
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Buộc đóng JarBox", style: .destructive) { [weak self] _ in
            self?.confirmEmergencyExit()
        })
        present(alert, animated: true)
    }

    private func showLaunchFailure(_ message: String) {
        NSLog("[J2ME Treo] Launch failed: %@", message)
        guard view.window != nil else { return }
        let alert = UIAlertController(title: "Không thể mở game", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sao chép lỗi", style: .default) { _ in
            UIPasteboard.general.string = message
        })
        alert.addAction(UIAlertAction(title: "Về thư viện", style: .cancel) { [weak self] _ in
            guard let self else { return }
            self.sessionLibrary?.managedGameDidEnd(self)
            self.dismiss(animated: true)
        })
        // A startup-timeout alert may still be open when the Java worker
        // fails; dismiss it first so the real Java error is not hidden.
        if let existing = presentedViewController {
            existing.dismiss(animated: false) { [weak self] in
                guard let self, self.view.window != nil else { return }
                self.present(alert, animated: true)
            }
        } else {
            present(alert, animated: true)
        }
    }

    nonisolated private static func runMIDlet(resRoot: String, jarPath: String,
                                              width: Int32, height: Int32,
                                              scale: Int32, fps: Int32,
                                              cloneID: UUID? = nil,
                                              token: UInt64) -> String? {
        // Every bridge operation is guarded by THIS worker's admission
        // token, not the most recently launched/visible tab.
        defer { _ = jvm_bridge_finish_session_for_token(token) }
        let docs = NSSearchPathForDirectoriesInDomains(
            .documentDirectory, .userDomainMask, true).first ?? NSTemporaryDirectory()
        let saveRoot: String
        do {
            saveRoot = try JarBoxGameStorage.prepareRoot(jarPath: jarPath,
                                                         documents: docs, cloneID: cloneID)
        } catch {
            NSLog("[JarBoxStorage] save root preparation failed: %@", error.localizedDescription)
            return "Không thể mở dữ liệu lưu an toàn: " + error.localizedDescription
        }
        // Metadata-only audit. The RMS records themselves remain unchanged.
        JarBoxGameStorage.appendSettingEvent(jarPath: jarPath, documents: docs,
                                            event: "SESSION_START", cloneID: cloneID)

        NSLog("[J2ME Treo] Entering JVM initialization")
        let initResult = jvm_bridge_init_for_token(token, resRoot, saveRoot,
                                                    jarPath, width, height, scale, fps)
        NSLog("[J2ME Treo] JVM initialization returned %d", initResult)
        guard initResult == 0 else { return "Java runtime initialization failed (\(initResult))." }
        if jvm_bridge_is_stop_requested_for_token(token) != 0 {
            NSLog("[JarBoxVM][Lifecycle] cancelled after JVM init, before MIDlet start")
            _ = jvm_bridge_destroy_for_token(token)
            return "Game startup cancelled."
        }

        NSLog("[J2ME Treo] Entering MIDlet runner")
        let runResult = jvm_bridge_run_midlet_for_token(token, jarPath)
        NSLog("[J2ME Treo] MIDlet runner returned %d; cleaning up", runResult)
        let javaError = String(cString: jvm_bridge_last_error())
        let nsoInitTrace = String(cString: jvm_bridge_nso_init_trace())
        _ = jvm_bridge_destroy_for_token(token)
        JarBoxGameStorage.appendSettingEvent(jarPath: jarPath, documents: docs,
                                            event: "SESSION_END", value: String(runResult),
                                            cloneID: cloneID)
        NSLog("[J2ME Treo] JVM cleanup complete")
        if runResult == 0 { return nil }
        return "Game execution failed (\(runResult))." +
            (javaError.isEmpty ? " Xem [MIDletRunner] trong log để xác định lỗi." :
                "\n\nLỗi Java: " + javaError) +
            (nsoInitTrace.isEmpty ? "" : "\n\nNSOInit: " + nsoInitTrace)
    }

    private func requestGameStop(reason: String) {
        guard ownsJVMSession else {
            dismiss(animated: true)
            return
        }
        if gameStopRequested {
            showStuckSessionRecovery()
            return
        }
        gameStopRequested = true
        NSLog("[JarBoxVM][Lifecycle] cancel_requested reason=%@ phase=%d",
              reason, jvm_bridge_session_phase())
        finishStartupWatchdog()
        stopJarAudit()
        discardCPUProfile()
        for code in Array(heldDirections) { releaseDirection(code) }
        if blackout != nil { hideBlackout() }
        // Leave Back usable: another tap opens stuck-session recovery.
        // Scope stop to THIS game so a late callback cannot stop a clone.
        let token = gameSessionToken
        _ = jvm_bridge_request_stop_for_token(token)

        // Cooperative stop first; interrupt the still-running Java threads
        // only after a grace period, on a background queue.
        let escalate = DispatchWorkItem { [weak self] in
            guard let self, self.gameStopRequested, self.ownsJVMSession else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let interrupted = jvm_bridge_interrupt_active_threads_for_token(token)
                NSLog("[JarBoxVM][Lifecycle] cancel_escalation result=%d token=%llu",
                      interrupted, token)
            }
        }
        stopEscalationWork = escalate
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: escalate)

        // NEVER dismiss a live JVM after an arbitrary timeout. Previously
        // the 7-second UI rescue hid the active worker behind the library,
        // leaving no way to stop it and blocking every subsequent game.
        let rescue = DispatchWorkItem { [weak self] in
            guard let self, self.gameStopRequested, self.ownsJVMSession else { return }
            NSLog("[JarBoxVM][Lifecycle] stop_pending_recovery phase=%d",
                  jvm_bridge_session_phase())
            self.showStuckSessionRecovery()
        }
        stopRescueWork = rescue
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: rescue)
    }

    /// A parked tab keeps its immutable token while another tab is focused.
    /// Never decide whether A is alive by comparing against B's foreground.
    func ownsLiveGameSession(for path: String? = nil) -> Bool {
        ownsJVMSession && !gameStopRequested && gameSessionToken != 0 &&
        jvm_bridge_session_is_active_for_token(gameSessionToken) != 0 &&
        (path == nil || path == jarPath)
    }

    /// Path alone does not identify a tab: clones share one original JAR.
    func ownsLiveInstance(for path: String, cloneID candidate: UUID?) -> Bool {
        ownsLiveGameSession(for: path) && candidate == cloneID
    }

    func holdsNativeGameSession(for path: String? = nil) -> Bool {
        ownsJVMSession && gameSessionToken != 0 &&
        jvm_bridge_session_is_active_for_token(gameSessionToken) != 0 &&
        (path == nil || path == jarPath)
    }

    func holdsNativeInstance(for path: String, cloneID candidate: UUID?) -> Bool {
        holdsNativeGameSession(for: path) && candidate == cloneID
    }

    // The same proven mode-8 headless Canvas + smart GC path as Treo.
    // On suspicious late-pixel access, the native guard automatically falls
    // back to the compatible mode 1. No timer, fullscreen black cover or
    // artificial Java-loop slowdown is added while browsing the library.
    private func startParkedTreo() {
        guard ownsLiveGameSession(), !parkedTreoActive else { return }
        // A library is not a visible JVM: all running games must stay
        // parked. This is separate from the Treo CPU-reduction mechanism.
        guard jvm_bridge_park_session(gameSessionToken) != 0 else {
            NSLog("[JarBoxVM][ParkTreo] refused stale/foreign owner token=%llu",
                  gameSessionToken)
            return
        }
        parkedTreoActive = true
        parkedStartedAt = ProcessInfo.processInfo.systemUptime
        parkedCPUStart = treo_process_cpu_seconds()
        parkedSkippedDrawsStart = treo_afk_skipped_draws()
        parkedGuardedPaintsStart = treo_afk_guarded_paints()
        parkedGCCyclesStart = treo_gc_smart_count()
        _ = treo_afk_guard_auto_set_for_token(gameSessionToken, 1)
        _ = treo_gc_smart_set_for_token(gameSessionToken, 1)
        _ = treo_render_set_afk_mode_for_token(gameSessionToken, 8)
        // Only park Display's polling thread for the structurally verified
        // NSO Canvas; arbitrary games retain their normal event semantics.
        parkedNSODeepIdle = treo_ninja_deep_verified() != 0 &&
                            treo_nso_canvas_recognized() != 0
        if parkedNSODeepIdle { _ = treo_display_wait_set_for_token(gameSessionToken, 1) }
        NSLog("[JarBoxVM][ParkTreo] enabled token=%llu deep_idle=%d",
              gameSessionToken, parkedNSODeepIdle ? 1 : 0)
    }

    /// Values attributable to this parked session's active Treo interval.
    /// Process-wide CPU/thermal/battery belong in the *global* JarBox menu,
    /// never under an individual JAR's resource consumption.
    func parkedSessionInformation() -> String {
        guard ownsLiveGameSession(for: jarPath), parkedTreoActive else {
            return "Phiên Java: không có phiên Treo đang hoạt động."
        }
        let seconds = max(0, ProcessInfo.processInfo.systemUptime - (parkedStartedAt ?? ProcessInfo.processInfo.systemUptime))
        let fallback = treo_afk_guard_auto_fell_back_for_token(gameSessionToken) != 0
        let mode = fallback ? "Tương thích (tự chuyển khi Canvas không an toàn)"
                            : "Treo sâu tự động"
        let deepIdle = parkedNSODeepIdle ? "Đã bật cho Canvas NSO được xác minh" : "Không áp dụng"
        let skipped = treo_afk_skipped_draws() &- parkedSkippedDrawsStart
        let guarded = treo_afk_guarded_paints() &- parkedGuardedPaintsStart
        let gcCycles = treo_gc_smart_count() &- parkedGCCyclesStart
        return [
            "Trạng thái: Đang chạy ẩn trong JarBox",
            "Treo: " + mode,
            "Thời gian Treo: " + String(format: "%.0f giây", seconds),
            "Lượt vẽ native bỏ qua: " + String(skipped),
            "Lượt Canvas có bảo vệ: " + String(guarded),
            "Chu kỳ GC trong phiên Treo: " + String(gcCycles),
            "Display chờ theo sự kiện: " + deepIdle,
            "Phiên JVM: " + String(gameSessionToken),
            "Các bộ đếm đo lúc mở mục này, không làm chậm nhịp game."
        ].joined(separator: "\n")
    }

    private func stopParkedTreo() {
        guard parkedTreoActive else { return }
        // The native session can finish before this controller's deferred
        // completion. Never reset Treo of an unrelated newly acquired tab.
        guard gameSessionToken != 0 &&
              jvm_bridge_session_is_active_for_token(gameSessionToken) != 0 else {
            parkedTreoActive = false
            parkedNSODeepIdle = false
            parkedStartedAt = nil
            parkedCPUStart = nil
            return
        }
        parkedTreoActive = false
        let fallback = treo_afk_guard_auto_fell_back_for_token(gameSessionToken) != 0
        let elapsed = parkedStartedAt.map {
            max(0.001, ProcessInfo.processInfo.systemUptime - $0)
        } ?? 0
        let cpuAtEnd = treo_process_cpu_seconds()
        let percent: String
        if let start = parkedCPUStart, start >= 0, cpuAtEnd >= start, elapsed > 0 {
            percent = String(format: "%.1f", 100 * (cpuAtEnd - start) / elapsed)
        } else {
            percent = "?"
        }
        parkedStartedAt = nil
        parkedCPUStart = nil
        // Restore the Display waiter before waking/refreshing the Canvas.
        if parkedNSODeepIdle {
            _ = treo_display_wait_set_for_token(gameSessionToken, 0)
            parkedNSODeepIdle = false
        }
        _ = treo_afk_guard_auto_set_for_token(gameSessionToken, 0)
        _ = treo_gc_smart_set_for_token(gameSessionToken, 0)
        _ = treo_render_set_afk_mode_for_token(gameSessionToken, 0)
        NSLog("[JarBoxVM][ParkTreo] disabled elapsed=%.1fs process_CPU=%@%% canvas_fallback=%d",
              elapsed, percent, fallback ? 1 : 0)
    }

    /// Safe one-slot library multitasking. The game keeps its Java state,
    /// sockets and threads, while the *full Treo* pipeline reduces offscreen
    /// drawing and GC overhead. This does not grant iOS background execution
    /// or start another miniJVM.
    @objc private func openLibraryKeepingGame() {
        guard ownsLiveGameSession(), !libraryIsPresented, presentedViewController == nil else { return }
        finishStartupWatchdog()
        stopJarAudit()
        discardCPUProfile()
        for code in Array(heldDirections) { releaseDirection(code) }
        if blackout != nil { hideBlackout() }  // restore screen brightness and probes

        if let library = sessionLibrary {
            // Do not detach a STARTING VM: mode-8 visitors need a RUNNING
            // owner. Leave the existing startup/cancel controls available.
            guard jvm_bridge_session_phase() == 2 else { return }
            startParkedTreo()
            guard parkedTreoActive else { return }
            libraryIsPresented = true
            alertTimeoutWork?.cancel()
            alertTimeoutWork = nil
            setGlobalEmulatorView(nil)
            emulatorView.clearPendingGameFrame()
            if activeGameViewController === self { activeGameViewController = nil }
            dismiss(animated: false) { [weak self, weak library] in
                guard let self else { return }
                library?.managedGameDidPark(self)
            }
            return
        }

        let library = AppsListViewController()
        library.parkedGameController = self
        let navigation = JarBoxLibraryNavigationController(rootViewController: library)
        navigation.modalPresentationStyle = .fullScreen
        // Match the main library, not UIKit's default bright navigation bar.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = AnimatedBackgroundView.backgroundGray
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        navigation.navigationBar.standardAppearance = appearance
        navigation.navigationBar.scrollEdgeAppearance = appearance
        navigation.navigationBar.tintColor = .white

        libraryIsPresented = true
        // Reuse Treo, not the old mode-1-only offscreen path. The library
        // itself performs no recurring CPU sampling or background animation.
        setGlobalEmulatorView(nil)
        emulatorView.clearPendingGameFrame()
        startParkedTreo()
        NSLog("[JarBoxVM][Park] session=%llu jar=%@", gameSessionToken,
              URL(fileURLWithPath: jarPath).lastPathComponent)
        present(navigation, animated: false)
    }

    func resumeParkedGame() {
        if let library = sessionLibrary {
            guard libraryIsPresented, ownsLiveGameSession() else { return }
            library.resumeManagedGame(self)
            return
        }
        guard libraryIsPresented,
              let navigation = presentedViewController as? UINavigationController else { return }
        navigation.dismiss(animated: false) { [weak self] in
            guard let self else { return }
            self.libraryIsPresented = false
            guard self.ownsLiveGameSession() else { return }
            // Select the exact previously parked VM before waking its Treo
            // state. Never create/reload a Java heap just to show a tab.
            guard jvm_bridge_focus_session(self.gameSessionToken) != 0 else {
                NSLog("[JarBoxVM][Focus] failed token=%llu", self.gameSessionToken)
                return
            }
            stopParkedTreo()
            setGlobalEmulatorView(self.emulatorView)
            if self.deferredGameAlert {
                self.deferredGameAlert = false
                self.showAlert()
            }
            NSLog("[JarBoxVM][Park] resumed session=%llu", self.gameSessionToken)
        }
    }

    private func restoreManagedGameFocus() {
        guard ownsLiveGameSession(),
              jvm_bridge_focus_session(self.gameSessionToken) != 0 else {
            NSLog("[JarBoxVM][Focus] failed managed token=%llu", gameSessionToken)
            dismiss(animated: false)
            return
        }
        activeGameViewController = self
        libraryIsPresented = false
        setGlobalEmulatorView(self.emulatorView)
        stopParkedTreo()
        if deferredGameAlert {
            deferredGameAlert = false
            showAlert()
        }
    }

    func stopParkedGame() {
        guard ownsLiveGameSession() else { return }
        // Restore native wait/GC state before cooperative shutdown.
        stopParkedTreo()
        requestGameStop(reason: "library_stop")
    }

    @objc private func backTapped() {
        openLibraryKeepingGame()
        // Back must remain an escape hatch if launch failed before we
        // acquired a JVM token, or if an earlier Stop is still pending.
        if !ownsJVMSession {
            dismiss(animated: true)
        } else if gameStopRequested {
            showStuckSessionRecovery()
        }
    }

    // ============================================================
    // MARK: - View switching
    // ============================================================

    func showCanvasView() {
        deferredGameAlert = false
        emulatorView.isHidden = false
        joystickView?.isHidden = layoutMode == .portrait
        numpadView?.isHidden = false
        formView.isHidden = true
        listView.isHidden = true
        if layoutMode == .ngage { numpadView?.updateCommands() }
        applyPadMode()
    }

    func showFormView() {
        deferredGameAlert = false
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
        deferredGameAlert = false
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
        // Capture *both* the worker's immutable session token and the
        // MIDP render owner for every deferred Alert action and timeout.
        guard ownsLiveGameSession() else { return }
        let originToken = gameSessionToken
        if libraryIsPresented {
            // Keep the pending game Alert when Deep Treo revoked native
            // visibility; the token and owner are validated upon resume.
            deferredGameAlert = true
            return
        }
        let originKey = j2me_ui_focused_owner_key()
        guard originKey != 0,
              j2me_render_visible_owner_key() == originKey else { return }
        let revision = j2me_ui_revision()
        // A revision alone is not enough: A and B may use the same value.
        // An Alert created by A must never post input to the focused B.
        let canDeliver: () -> Bool = { [weak self] in
            guard let self else { return false }
            return self.ownsJVMSession &&
                self.gameSessionToken == originToken &&
                jvm_bridge_session_token() == originToken &&
                jvm_bridge_session_is_active() != 0 &&
                j2me_ui_focused_owner_key() == originKey &&
                j2me_render_visible_owner_key() == originKey &&
                j2me_ui_revision() == revision
        }
        let title = String(cString: j2me_ui_get_form_title())
        let text = String(cString: j2me_ui_get_alert_text())

        let alert = UIAlertController(title: title, message: text, preferredStyle: .alert)

        alertTimeoutWork?.cancel()
        alertTimeoutWork = nil

        let cmdCount = j2me_ui_get_command_count()
        if cmdCount == 0 {
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
                guard canDeliver() else { return }
                self?.alertTimeoutWork?.cancel()
                j2me_input_post_touch(Int32(J2ME_UI_ALERT_DISMISSED), revision, 0)
            })
        } else {
            for i in 0..<cmdCount {
                let label = String(cString: j2me_ui_get_command_label(Int32(i)))
                let cmdId = j2me_ui_get_command_id(Int32(i))
                alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                    guard canDeliver() else { return }
                    self?.alertTimeoutWork?.cancel()
                    j2me_input_post_touch(Int32(J2ME_UI_COMMAND_ACTION), revision, cmdId)
                })
            }
        }

        present(alert, animated: true)

        let timeout = j2me_ui_get_alert_timeout()
        if timeout > 0 {
            let work = DispatchWorkItem { [weak alert] in
                guard canDeliver() else { return }
                alert?.dismiss(animated: true) {
                    guard canDeliver() else { return }
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

// UIKit rendering happens asynchronously. Validate the *same JVM generation*
// after the main-thread hop; a queued MIDP Alert from Tab A must never appear
// on Tab B even when their JAR path and screen revision happen to coincide.
private func dispatchMIDPScreenAction(_ action: Int32, _ revision: Int32,
                                      ownerKey: UInt64 = 0) {
    // The unowned legacy callback cannot prove whether A or B queued an
    // event. All iOS sessions install ownedGameUICallback; fail closed.
    guard ownerKey != 0 else { return }
    let sourceToken = jvm_bridge_session_token()
    guard sourceToken != 0 else { return }
    DispatchQueue.main.async {
        guard jvm_bridge_session_token() == sourceToken,
              jvm_bridge_session_is_active() != 0,
              j2me_render_visible_owner_key() == ownerKey,
              j2me_ui_focused_owner_key() == ownerKey else { return }
        j2me_ui_lock_screen()
        defer { j2me_ui_unlock_screen() }
        guard revision == j2me_ui_revision(),
              j2me_render_visible_owner_key() == ownerKey,
              j2me_ui_focused_owner_key() == ownerKey,
              let vc = activeGameViewController,
              vc.ownsLiveGameSession() else { return }
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

let gameUICallback: @convention(c) (Int32, Int32) -> Void = { action, revision in
    dispatchMIDPScreenAction(action, revision)
}

let ownedGameUICallback: @convention(c) (Int32, Int32, UInt64) -> Void = {
    action, revision, ownerKey in
    guard ownerKey != 0 else { return }
    dispatchMIDPScreenAction(action, revision, ownerKey: ownerKey)
}
