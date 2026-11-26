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

// Bounded disk journal, serialized by the recorder's utility queue.
nonisolated final class JarBoxFlightStore {
    let directory: URL
    let limit: Int
    private let fm = FileManager.default
    private var current: URL { directory.appendingPathComponent("current.log") }
    private var previous: URL { directory.appendingPathComponent("previous.log") }
    init(directory: URL, limit: Int = 512 * 1024) {
        self.directory = directory
        self.limit = limit
    }
    func append(_ line: String, durable: Bool) throws {
        let data = Data((line + "\n").utf8)
        guard data.count <= limit else { throw CocoaError(.fileWriteOutOfSpace) }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        #endif
        let size = (try? fm.attributesOfItem(atPath: current.path)[.size] as? NSNumber)?.intValue ?? 0
        if size > limit - data.count {
            if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
            try fm.moveItem(at: current, to: previous)
        }
        if !fm.fileExists(atPath: current.path) {
            #if os(iOS)
            let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            #else
            let attributes: [FileAttributeKey: Any] = [:]
            #endif
            guard fm.createFile(atPath: current.path, contents: nil, attributes: attributes) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let file = try FileHandle(forWritingTo: current)
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: data)
        if durable { try file.synchronize() }
    }
    func report() -> String {
        [previous, current].compactMap { url in
            guard let data = try? Data(contentsOf: url), data.count <= limit else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.joined()
    }
}

nonisolated struct JarBoxFlightPolicy {
    private var lastWall: UInt64 = 0
    private var lastCPU: UInt64 = 0
    private var lastValid = false
    private var lastSaved: UInt64 = 0
    private var lastSignature = ""
    mutating func observe(wall: UInt64, cpu: UInt64, valid: Bool, signature: String,
                          urgent: Bool) -> (percent: Double?, gap: UInt64, save: Bool) {
        let gap = lastWall > 0 && wall > lastWall ? wall - lastWall : 0
        let percent: Double? = valid && lastValid && gap > 0 && cpu >= lastCPU
            ? Double(cpu - lastCPU) * 100 / Double(gap) : nil
        let high = (percent ?? 0) >= 60
        let changed = signature != lastSignature
        let due = lastSaved == 0 || wall < lastSaved || wall - lastSaved >= 60_000_000_000
        let save = high || urgent || changed || due || gap > 15_000_000_000
        lastWall = wall
        lastCPU = cpu
        lastValid = valid
        lastSignature = signature
        if save { lastSaved = wall }
        return (percent, gap, save)
    }
}

// All mutable state and disk I/O are confined to queue. No game payloads.
nonisolated final class JarBoxFlightRecorder: @unchecked Sendable {
    static let shared = JarBoxFlightRecorder()
    private let queue = DispatchQueue(label: "app.jarbox.flight", qos: .utility)
    private let run = UUID().uuidString
    private let store: JarBoxFlightStore
    private var timer: DispatchSourceTimer?
    private var pending = Set<UInt64>()
    private var emptyTicks = 0
    private var policy = JarBoxFlightPolicy()
    private var sequence: UInt64 = 0
    private var writeFailures = 0
    private var build = "unknown"
    private var perf = "unknown"
    private init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        store = JarBoxFlightStore(directory: root.appendingPathComponent("JarBoxFlight-v1", isDirectory: true))
    }
    private func write(_ content: String, durable: Bool = true) {
        sequence &+= 1
        let line = "run=\(run) build=\(build) perf=\(perf) seq=\(sequence) epoch=\(Date().timeIntervalSince1970) " + content
        do { try store.append(line, durable: durable) }
        catch { writeFailures += 1 }
    }
    func event(_ name: String, token: UInt64 = 0) {
        queue.async {
            self.write("event=\(name) token=\(token)")
            switch name {
            case "launch_requested", "launch_admitted":
                if token != 0 { self.pending.insert(token) }
                self.start()
            case "first_surface", "worker_failed", "worker_returned":
                self.pending.remove(token)
            case "park_entered", "park_exited":
                self.tick(forceSave: true)
            default: break
            }
        }
    }
    func boot(build: String, model: String, os: String) {
        queue.async {
            self.build = build
            self.perf = Bundle.main.object(forInfoDictionaryKey: "JarBoxPerfProfile") as? String ?? "unknown"
            self.write("event=boot schema=1 device=\(model) ios=\(os) ram=\(ProcessInfo.processInfo.physicalMemory)")
        }
    }
    private func start() {
        emptyTicks = 0
        guard timer == nil else { return }
        policy = JarBoxFlightPolicy()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .seconds(5), leeway: .milliseconds(500))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }
    private func tick(forceSave: Bool = false) {
        var process = JarBoxFlightProcess()
        var slots = [JarBoxFlightSlot](repeating: JarBoxFlightSlot(), count: 64)
        let count = slots.withUnsafeMutableBufferPointer {
            jvm_bridge_flight_sample(&process, $0.baseAddress, Int32($0.count), 0)
        }
        let rows = slots.prefix(max(0, min(Int(count), slots.count)))
        let signature = count < 0 ? "busy" : rows.map { "\($0.token):\($0.phase):\($0.stop_requested)" }.joined(separator: ",")
        let urgent = !pending.isEmpty || count < 0 || rows.contains { $0.phase != 2 || $0.stop_requested != 0 }
        let decision = policy.observe(wall: process.wall_ns, cpu: process.process_ns,
                                      valid: process.process_ok != 0, signature: signature, urgent: urgent || forceSave)
        if decision.save {
            let percent = decision.percent.map { String(format: "%.2f", $0) } ?? "unavailable"
            var detailProcess = JarBoxFlightProcess()
            let detailCount = slots.withUnsafeMutableBufferPointer {
                jvm_bridge_flight_sample(&detailProcess, $0.baseAddress, Int32($0.count), 1)
            }
            let detail = slots.prefix(max(0, min(Int(detailCount), slots.count))).map { slot in
                "token=\(slot.token),phase=\(slot.phase),stop=\(slot.stop_requested),mode=\(slot.mode),workers=\(slot.workers),counters_ok=\(slot.counters_ok),gc_cycles=\(slot.gc_cycles),gc_aborts=\(slot.gc_aborts),repaints=\(slot.repaint_requests),afk_profile_paint_calls=\(slot.afk_profile_paint_calls),afk_profile_paint_cpu_ns=\(slot.afk_profile_paint_cpu_ns),compatible_font_reuses=\(slot.compatible_font_reuses),compatible_crop_hits=\(slot.compatible_crop_hits),compatible_crop_misses=\(slot.compatible_crop_misses),compatible_state_reuses=\(slot.compatible_state_reuses),compatible_region_culls=\(slot.compatible_region_culls),nso_repaint_skips=\(slot.nso_repaint_skips),nso_service_skips=\(slot.nso_service_skips),nso_paint_skips=\(slot.nso_paint_skips),cpu_ok=\(slot.cpu_ok),runner_ns=\(slot.runner_ns),java_ns=\(slot.java_ns),gc_ns=\(slot.gc_ns),const_arith_fusions=\(slot.const_arith_fusions),const_branch_fusions=\(slot.const_branch_fusions),decoded_int_calls=\(slot.decoded_int_calls),event_sleep_handled=\(slot.event_sleep_handled),event_sleep_fallbacks=\(slot.event_sleep_fallbacks),shared_zip_probes=\(slot.shared_zip_probes),shared_zip_hits=\(slot.shared_zip_hits),shared_zip_negative_hits=\(slot.shared_zip_negative_hits),shared_prepared_candidates=\(slot.shared_prepared_candidates),shared_prepared_hits=\(slot.shared_prepared_hits),startup_image_decodes=\(slot.startup_image_decodes),startup_image_hits=\(slot.startup_image_hits),startup_image_decode_ns=\(slot.startup_image_decode_ns)"
            }.joined(separator: ";")
            write("event=sample mono_ns=\(process.wall_ns) gap_ns=\(decision.gap) process_cpu_ok=\(process.process_ok) process_cpu_ns=\(process.process_ns) cpu_percent=\(percent) headroom_bytes=\(process.headroom_bytes) footprint_ok=\(process.footprint_ok) footprint_bytes=\(process.footprint_bytes) memory_state=\(process.memory_state) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) low_power=\(ProcessInfo.processInfo.isLowPowerModeEnabled ? 1 : 0) registry=\(signature) detail_mono_ns=\(detailProcess.wall_ns) detail_count=\(detailCount) slots=[\(detail)]", durable: forceSave || urgent || (decision.percent ?? 0) >= 60)
        }
        // Explicit samples are not periodic timer ticks for idle shutdown.
        if forceSave { return }
        emptyTicks = count == 0 ? emptyTicks + 1 : 0
        if emptyTicks >= 3 {
            timer?.cancel()
            timer = nil
            pending.removeAll()
            write("event=idle_sampling_stopped")
        }
    }
    func export(extra: String, completion: @escaping @Sendable (String) -> Void) {
        queue.async {
            self.tick(forceSave: true)
            self.write("event=manual_export")
            completion("JarBox Flight Recorder v1\nwrite_failures_this_run=\(self.writeFailures)\nphase: 1 STARTING, 2 RUNNING, 3 CLEANUP; CPU one core=100%; counters cumulative; gaps may be suspension\n\n" + self.store.report() + "\n\n--- Latest background report ---\n" + extra)
        }
    }
}

// Main-actor, process-wide diagnostic. No timer, background task or audio
// is started here. Retained values contain tokens and counters, not VM pointers.
@MainActor enum JarBoxBackgroundDiagnostics {
    private static let key = "jarbox.background.report.v1"
    private static let incidentKey = "jarbox.background.incidents.v1"
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
        var available: UInt64 = 0
        let memoryState = jvm_bridge_memory_state(&available)
        return "environment_\(label):battery_percent=\(battery),battery_state=\(state),low_power=\(info.isLowPowerModeEnabled ? 1 : 0),thermal=\(thermalCode()),headroom_bytes=\(available),memory_state=\(memoryState)"
    }
    static func installEnvironmentObservers() {
        guard observers.isEmpty else { return }
        JarBoxFlightRecorder.shared.boot(build: build, model: machineIdentifier(), os: UIDevice.current.systemVersion)
        let center = NotificationCenter.default
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange] {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { _ in
                DispatchQueue.main.async { JarBoxBackgroundDiagnostics.environmentChanged() }
            })
        }
    }
    private static func environmentChanged() {
        JarBoxFlightRecorder.shared.event("power_or_thermal_change")
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
            // Process CPU includes every JVM and app/audio/UI overhead.
            // It overlaps across token windows: never sum these values.
            lines.append("gc_cycles_delta=\(delta(before.cpu.gc_cycles,after.cpu.gc_cycles)),gc_aborts_delta=\(delta(before.gc_aborts,after.gc_aborts)),process_cpu_valid=\(cpu.process_ok),process_cpu_ns=\(cpu.process_ns)")
        }
        starts.removeAll()
        save(lines.joined(separator: "\n"))
    }
    // Bounded main-thread breadcrumbs at existing lifecycle boundaries.
    // Best-effort persistence, not a crash handler or a watchdog timer.
    static func recordIncident(_ event: String, token: UInt64 = 0) {
        JarBoxFlightRecorder.shared.event(event, token: token)
        let defaults = UserDefaults.standard
        var recent = defaults.stringArray(forKey: incidentKey) ?? []
        var headroom: UInt64 = 0
        let memoryState = jvm_bridge_memory_state(&headroom)
        var tokens = [UInt64](repeating: 0, count: 64)
        let capacity = Int32(tokens.count)
        let count = tokens.withUnsafeMutableBufferPointer {
            jvm_bridge_background_tokens($0.baseAddress, capacity)
        }
        var owners: [String] = []
        for owner in tokens.prefix(max(0, min(Int(count), tokens.count))) where owner != 0 {
            var bytes: UInt64 = 0
            let sampled = jvm_bridge_status_heap_bytes_for_token(owner, &bytes) != 0
            let heap = sampled ? String(bytes) : "unavailable"
            owners.append("\(owner):\(heap):\(treo_mode_for_token(owner))")
        }
        let line = "time=\(Date()),build=\(build),event=\(event),token=\(token),headroom_bytes=\(headroom),memory_state=\(memoryState),owners(token:heap_bytes:mode)=\(owners.joined(separator: ";"))"
        recent.append(line)
        defaults.set(Array(recent.suffix(8)), forKey: incidentKey)
        NSLog("%@", line)
    }
    static func report() -> String {
        let defaults = UserDefaults.standard
        let background = defaults.string(forKey: key) ?? "Chưa có lần thử tắt màn hình. Hãy khóa máy rồi mở lại."
        let incidents = defaults.stringArray(forKey: incidentKey) ?? []
        return background + "\n\nRecent lifecycle events (best effort):\n" + incidents.joined(separator: "\n")
    }
    static func showFlight(from controller: UIViewController) {
        guard controller.presentedViewController == nil else { return }
        let extra = report()
        JarBoxFlightRecorder.shared.export(extra: extra) { [weak controller] text in
            DispatchQueue.main.async {
                guard let controller, controller.presentedViewController == nil else { return }
                let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = controller.view
                activity.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
                controller.present(activity, animated: true)
            }
        }
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
        JarBoxFlightRecorder.shared.event("scene_disconnect")
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
        JarBoxFlightRecorder.shared.event("scene_active")
        JarBoxBackgroundDiagnostics.end()
        j2me_audio_background_revalidate()
        j2me_render_set_2d_scene_active(1)
        activeGameViewController?.endSceneBackgroundTreo()
        updateSpringboardSceneActivity(true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        JarBoxFlightRecorder.shared.event("scene_inactive")
        j2me_audio_background_revalidate()
        j2me_render_set_2d_scene_active(0)
        activeGameViewController?.sceneSuspendGameInput()
        updateSpringboardSceneActivity(false)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        JarBoxFlightRecorder.shared.event("scene_foreground")
        // Called as the scene transitions from the background to the foreground.
        // Freeze the report before foreground rendering and Treo recovery.
        JarBoxBackgroundDiagnostics.end()
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        JarBoxFlightRecorder.shared.event("scene_background")
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

