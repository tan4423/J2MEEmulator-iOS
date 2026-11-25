//
//  SceneDelegate.swift
//  J2MEEmulator
//
//  Created by Alexander Goremykin on 19.03.2026.
//

import UIKit

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

// Main-actor, process-wide diagnostic. No timer, background task or audio
// is started here. Retained values contain tokens and counters, not VM pointers.
@MainActor enum JarBoxBackgroundDiagnostics {
    private static let key = "jarbox.background.report.v1"
    private static var entered: Date?
    private static var visible: UInt64 = 0
    private static var starts: [(UInt64, JarBoxBackgroundSample?)] = []
    private static var audioStart = JarBoxBackgroundAudioSnapshot()
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
                       "Không phát được audio", "iOS không cho tự phát lại"]
        let reasonIndex = Int(a.reason)
        let reason = reasons.indices.contains(reasonIndex) ? reasons[reasonIndex] : "Không rõ"
        let message = "Trạng thái: \(state) · \(reason)\nÂm lượng riêng: \(a.volume_percent)%\n\n0% là tắt tiếng âm nền, không phải dừng player. Khả năng Treo ở 0% chưa được kiểm chứng trên thiết bị. Không ảnh hưởng âm lượng game hoặc ứng dụng khác."
        let alert = UIAlertController(title: "Âm nền Treo (thử nghiệm)", message: message, preferredStyle: .alert)
        if a.requested != 0 {
            alert.addAction(UIAlertAction(title: "Tắt âm nền", style: .destructive) { _ in j2me_audio_background_stop() })
        } else if a.policy == 2 {
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
        entered = Date()
        audioStart = j2me_audio_background_snapshot()
        visible = jvm_bridge_visible_session_token()
        var tokens = [UInt64](repeating: 0, count: 64)
        let capacity = Int32(tokens.count)
        let count = tokens.withUnsafeMutableBufferPointer {
            jvm_bridge_background_tokens($0.baseAddress, capacity)
        }
        starts = tokens.prefix(max(0, min(Int(count), tokens.count))).filter { $0 != 0 }.map { token in
            var point = JarBoxBackgroundSample()
            let ok = jvm_bridge_background_sample(token, 1, &point) != 0
            return (token, ok ? point : nil)
        }
        let ids = starts.map { String($0.0) }.joined(separator: ",")
        save("JarBox Background v1\nbuild=\(build)\nstatus=INCOMPLETE_NO_RESUME_RECORDED\nentered=\(entered!)\nvisible_token=\(visible)\ntokens=\(ids)\n\(audioLine("begin", audioStart))")
    }
    private static func delta(_ a: UInt64, _ b: UInt64) -> String {
        b >= a ? String(b - a) : "unavailable"
    }
    static func end() {
        guard let startDate = entered else { return }
        entered = nil
        let seconds = Date().timeIntervalSince(startDate)
        var lines = ["JarBox Background v1", "build=\(build)", "status=RETURNED",
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

