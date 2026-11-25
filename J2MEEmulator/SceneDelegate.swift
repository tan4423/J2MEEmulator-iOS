//
//  SceneDelegate.swift
//  J2MEEmulator
//
//  Created by Alexander Goremykin on 19.03.2026.
//

import UIKit
import Darwin

/// Forwards orientation queries to the top view controller
private class OrientationNavigationController: UINavigationController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        topViewController?.supportedInterfaceOrientations ?? .portrait
    }
}

// Observe actual touch activity without adding a competing recognizer or
// swallowing any UIKit/game input. The library ignores events offscreen.
private final class JarBoxActivityWindow: UIWindow {
    weak var library: AppsListViewController?
    override func sendEvent(_ event: UIEvent) {
        super.sendEvent(event)
        guard event.type == .touches, let touches = event.allTouches, !touches.isEmpty else { return }
        let active = touches.contains {
            $0.phase != .ended && $0.phase != .cancelled
        }
        library?.libraryInputChanged(activeTouch: active)
    }
}

// Bounded, event-driven evidence; a notification not delivered while the
// process is suspended is not an observation. No timers or wake requests.
struct JarBoxPowerEvidence {
    private(set) var worstThermal = -1
    private(set) var lowPowerSeen = false
    private(set) var powerChanges = 0
    private(set) var thermalChanges = 0
    private var previousLowPower: Bool?
    private var previousThermal: Int?
    mutating func observe(thermal: Int, lowPower: Bool) {
        if thermal >= 0 {
            worstThermal = max(worstThermal, thermal)
            if let previousThermal, previousThermal != thermal { thermalChanges += 1 }
            previousThermal = thermal
        }
        if let previousLowPower, previousLowPower != lowPower { powerChanges += 1 }
        previousLowPower = lowPower
        lowPowerSeen = lowPowerSeen || lowPower
    }
    var log: String {
        "worst_thermal_observed=\(worstThermal),low_power_seen=\(lowPowerSeen ? 1 : 0),power_changes_observed=\(powerChanges),thermal_changes_observed=\(thermalChanges)"
    }
}

// Main-actor, process-wide diagnostic. No timer, background task or audio
// is started here. Retained values contain tokens and counters, not VM pointers.
@MainActor enum JarBoxBackgroundDiagnostics {
    private static let key = "jarbox.background.report.v1"
    private static var entered: Date?
    private static var visible: UInt64 = 0
    private static var starts: [(UInt64, JarBoxBackgroundSample?)] = []
    private static var audioStart = JarBoxBackgroundAudioSnapshot()
    private static var environmentStart = ""
    private static var powerEvidence = JarBoxPowerEvidence()
    private static var observers: [NSObjectProtocol] = []
    private static func thermalCode() -> Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return -1
        }
    }
    private static func machineIdentifier() -> String {
        var info = utsname()
        guard uname(&info) == 0 else { return "unknown" }
        let capacity = MemoryLayout.size(ofValue: info.machine)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
        }
    }
    private static func environmentLine(_ label: String) -> String {
        // Battery monitoring is a shared UIKit setting used by existing
        // dashboards/audits. Borrow synchronously and restore immediately;
        // never hold a competing lease across background transitions.
        let device = UIDevice.current
        let previous = device.isBatteryMonitoringEnabled
        if !previous { device.isBatteryMonitoringEnabled = true }
        defer { if !previous { device.isBatteryMonitoringEnabled = false } }
        let level = device.batteryLevel
        let battery = level >= 0 && level <= 1 ? String(Int((level * 100).rounded())) : "unknown"
        let state: String
        switch device.batteryState {
        case .unplugged: state = "unplugged"
        case .charging: state = "charging"
        case .full: state = "full"
        default: state = "unknown"
        }
        let info = ProcessInfo.processInfo
        return "environment_\(label):battery_percent=\(battery),battery_state=\(state),low_power=\(info.isLowPowerModeEnabled ? 1 : 0),thermal=\(thermalCode())"
    }
    static func installEnvironmentObservers() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                DispatchQueue.main.async { JarBoxBackgroundDiagnostics.environmentChanged() }
            })
        }
    }
    private static func environmentChanged() {
        if entered != nil {
            powerEvidence.observe(thermal: thermalCode(), lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }
        // No restart on power/thermal changes. Native revalidation stops
        // optional playback at critical heat, without touching any JVM.
        if thermalCode() == 3 { j2me_audio_background_revalidate() }
    }
    private static func audioLine(_ name: String, _ a: JarBoxBackgroundAudioSnapshot) -> String {
        let state = "requested=\(a.requested),playing=\(a.playing),interrupted=\(a.interrupted),policy=\(a.policy),reason=\(a.reason)"
        let counts = "starts=\(a.starts),stops=\(a.stops),interruptions=\(a.interruptions),route_changes=\(a.route_changes),media_resets=\(a.media_resets),failures=\(a.failures)"
        let volume = "volume_percent=\(a.volume_percent),player_volume_percent=\(a.player_volume_percent),volume_changes=\(a.volume_changes)"
        return "audio_\(name):" + state + "," + counts + "," + volume
    }
    static func showAudio(from controller: UIViewController) {
        guard controller.presentedViewController == nil else { return }
        let a = j2me_audio_background_snapshot()
        let state = a.playing != 0 ? "Đang phát" : a.requested != 0 ? "Tạm gián đoạn" : "Đang tắt"
        let reasons = ["Tắt", "Đang phát", "Phiên chưa sẵn sàng hoặc không phải 2D",
                       "Audio bị gián đoạn", "Thiết bị nghe bị ngắt", "Media services reset",
                       "Không phát được audio", "iOS không cho tự phát lại", "Đã dừng âm nền vì nhiệt độ critical"]
        let reasonIndex = Int(a.reason)
        let reason = reasons.indices.contains(reasonIndex) ? reasons[reasonIndex] : "Không rõ"
        let warning = thermalCode() >= 2 ? "\nMáy đang nóng: giảm số tab, không tiếp tục thử dài hạn khi nhiệt độ cao." : ProcessInfo.processInfo.isLowPowerModeEnabled ? "\nĐang bật tiết kiệm pin: iOS có thể hạn chế chạy nền." : ""
        let message = "Trạng thái: \(state) · \(reason)\nÂm lượng riêng: \(a.volume_percent)%\n\n0% chỉ tắt tiếng, không dừng player. Mức 0% cần kiểm thử trên thiết bị. Không ảnh hưởng âm lượng game hoặc ứng dụng khác." + warning
        let alert = UIAlertController(title: "Âm nền Treo (thử nghiệm)", message: message, preferredStyle: .alert)
        if a.requested != 0 {
            alert.addAction(UIAlertAction(title: "Tắt âm nền", style: .destructive) { _ in j2me_audio_background_stop() })
        } else if a.policy == 2 && thermalCode() != 3 {
            alert.addAction(UIAlertAction(title: "Bật âm nền", style: .default) { _ in
                let ok = j2me_audio_background_start()
                NSLog("[JarBoxAudio] user_start=%d", ok)
            })
        }
        // Direct actions avoid presenting another alert while dismissing this one.
        for percent: Int32 in [0, 1, 5, 15, 35, 70, 100] {
            let name = percent == 0 ? "0% · Im lặng" : "Âm lượng \(percent)%"
            let title = percent == a.volume_percent ? name + " ✓" : name
            alert.addAction(UIAlertAction(title: title, style: .default) { _ in
                j2me_audio_background_set_volume(percent)
            })
        }
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        controller.present(alert, animated: true)
    }
    private static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "JarBoxBuildCommit") as? String ?? "unknown"
    }
    private static func save(_ report: String) {
        UserDefaults.standard.set(report, forKey: key)
        NSLog("%@", report)
    }
    static func begin() {
        guard entered == nil else { return }
        visible = jvm_bridge_visible_session_token()
        var tokens = [UInt64](repeating: 0, count: 64)
        let capacity = Int32(tokens.count)
        let count = tokens.withUnsafeMutableBufferPointer {
            jvm_bridge_background_tokens($0.baseAddress, capacity)
        }
        // Do not overwrite the previous game report when an empty library
        // is backgrounded (including after an interrupted/relaunched app).
        guard count > 0 else { return }
        entered = Date()
        audioStart = j2me_audio_background_snapshot()
        environmentStart = environmentLine("begin")
        powerEvidence = JarBoxPowerEvidence()
        powerEvidence.observe(thermal: thermalCode(), lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        starts = tokens.prefix(max(0, min(Int(count), tokens.count))).filter { $0 != 0 }.map { token in
            var point = JarBoxBackgroundSample()
            let ok = jvm_bridge_background_sample(token, 1, &point) != 0
            return (token, ok ? point : nil)
        }
        let ids = starts.map { String($0.0) }.joined(separator: ",")
        save("JarBox Background v1\nbuild=\(build)\nstatus=INCOMPLETE_NO_RESUME_RECORDED\nentered=\(entered!)\nvisible_token=\(visible)\ntokens=\(ids)\n\(audioLine("begin", audioStart))\n\(environmentStart)")
    }
    private static func delta(_ a: UInt64, _ b: UInt64) -> String {
        b >= a ? String(b - a) : "unavailable"
    }
    static func end() {
        guard let startDate = entered else { return }
        entered = nil
        let seconds = Date().timeIntervalSince(startDate)
        powerEvidence.observe(thermal: thermalCode(), lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled)
        var lines = ["JarBox Background v1", "build=\(build)", "status=RETURNED",
                     "device_model=\(machineIdentifier()),ios=\(UIDevice.current.systemVersion),physical_ram_bytes=\(ProcessInfo.processInfo.physicalMemory)",
                     environmentStart, environmentLine("end"), "power_observations:" + powerEvidence.log,
                     "source=\(visible == 0 ? "library" : "game")", "visible_token=\(visible)",
                     "wall_seconds=\(seconds)", "sessions=\(starts.count)",
                     audioLine("begin", audioStart),
                     audioLine("end", j2me_audio_background_snapshot())]
        for (token, before) in starts {
            var after = JarBoxBackgroundSample()
            let ok = jvm_bridge_background_sample(token, 0, &after) != 0
            guard let before, ok else {
                let stillActive = jvm_bridge_session_is_active_for_token(token) != 0
                lines.append("token=\(token),status=\(stillActive ? "unavailable" : "retired"),start_sample=\(before == nil ? 0 : 1),end_sample=\(ok ? 1 : 0)")
                continue
            }
            let p = after.progress
            let valid = before.trace_ok != 0 && after.trace_ok != 0 && p.start_ns != 0
            let cpu = jarbox_cpu_window(before.cpu, after.cpu, before.mode)
            let status = !valid ? "trace_unavailable" : p.samples == 0 ? "no_qualified_heartbeat" : "heartbeat_observed"
            let first = valid && p.samples > 0 ? delta(p.start_ns, p.first_ns) : "unavailable"
            let last = valid && p.samples > 0 ? delta(p.start_ns, p.last_ns) : "unavailable"
            lines.append("token=\(token),status=\(status),mode_before=\(before.mode),mode_after=\(after.mode),family=\(after.family),canvas=\(after.canvas)")
            lines.append("elapsed_ns=\(valid ? delta(p.start_ns,p.end_ns) : "unavailable"),samples=\(p.samples),first_offset_ns=\(first),last_offset_ns=\(last),max_observed_gap_ns=\(valid ? String(p.max_gap_ns) : "unavailable")")
            lines.append("requests_delta=\(delta(before.cpu.requests,after.cpu.requests)),skips_delta=\(delta(before.cpu.skips,after.cpu.skips)),cpu_valid=\(cpu.threads_ok),runner_cpu_ns=\(cpu.runner_ns),java_cpu_ns=\(cpu.java_ns),gc_cpu_ns=\(cpu.gc_ns),sample_errors=\(cpu.sample_errors)")
        }
        starts.removeAll()
        save(lines.joined(separator: "\n"))
    }
    static func report() -> String {
        UserDefaults.standard.string(forKey: key) ?? "Chưa có lần thử tắt màn hình. Hãy khóa máy rồi mở lại."
    }
    static func show(from controller: UIViewController) {
        guard controller.presentedViewController == nil else { return }
        let text = report()
        let alert = UIAlertController(title: "Log Treo tắt màn hình", message: text, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Sao chép", style: .default) { _ in UIPasteboard.general.string = text })
        alert.addAction(UIAlertAction(title: "Đóng", style: .cancel))
        controller.present(alert, animated: true)
    }
}

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?


    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        JarBoxBackgroundDiagnostics.installEnvironmentObservers()

        let vc = AppsListViewController()
        let nav = OrientationNavigationController(rootViewController: vc)
        nav.navigationBar.prefersLargeTitles = false

        // Opaque navigation bar in the same neutral gray, avoiding
        // transparent-bar backdrop blending over the library.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = AnimatedBackgroundView.backgroundGray
        appearance.shadowColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.white]
        nav.navigationBar.standardAppearance = appearance
        nav.navigationBar.scrollEdgeAppearance = appearance
        nav.navigationBar.tintColor = .white

        let activityWindow = JarBoxActivityWindow(windowScene: windowScene)
        activityWindow.library = vc
        window = activityWindow
        window?.rootViewController = nav
        window?.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        // Called as the scene is being released by the system.
        // This occurs shortly after the scene enters the background, or when its session is discarded.
        // Release the foreground protection display lease even if the
        // inactive callback was skipped before this scene was disconnected.
        j2me_render_set_2d_scene_active(0)
        activeGameViewController?.sceneSuspendGameInput()
        updateSpringboardSceneActivity(false)
    }

    private func updateSpringboardSceneActivity(_ active: Bool) {
        // Only the visible springboard has decorative work to resume.
        // Game lifecycle is handled independently by the scene callbacks.
        guard let nav = window?.rootViewController as? UINavigationController,
              let springboard = nav.viewControllers.first as? AppsListViewController else { return }
        springboard.sceneActivityChanged(active)
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        JarBoxBackgroundDiagnostics.end()
        j2me_audio_background_revalidate()
        j2me_render_set_2d_scene_active(1)
        activeGameViewController?.endSceneBackgroundTreo()
        updateSpringboardSceneActivity(true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        j2me_audio_background_revalidate()
        j2me_render_set_2d_scene_active(0)
        activeGameViewController?.sceneSuspendGameInput()
        updateSpringboardSceneActivity(false)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Freeze the report before foreground rendering and Treo recovery.
        JarBoxBackgroundDiagnostics.end()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Idempotent fallback if the inactive notification was missed.
        j2me_render_set_2d_scene_active(0)
        activeGameViewController?.sceneSuspendGameInput()
        activeGameViewController?.beginSceneBackgroundTreo()
        j2me_audio_background_revalidate()
        JarBoxBackgroundDiagnostics.begin()
        updateSpringboardSceneActivity(false)
    }


}

