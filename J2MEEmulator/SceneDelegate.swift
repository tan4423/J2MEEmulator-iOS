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
        j2me_render_set_2d_scene_active(1)
        activeGameViewController?.endSceneBackgroundTreo()
        updateSpringboardSceneActivity(true)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        j2me_render_set_2d_scene_active(0)
        activeGameViewController?.sceneSuspendGameInput()
        updateSpringboardSceneActivity(false)
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as the scene transitions from the background to the foreground.
        // Use this method to undo the changes made on entering the background.
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Called as the scene transitions from the foreground to the background.
        // Idempotent fallback if the inactive notification was missed.
        j2me_render_set_2d_scene_active(0)
        activeGameViewController?.sceneSuspendGameInput()
        activeGameViewController?.beginSceneBackgroundTreo()
        updateSpringboardSceneActivity(false)
    }


}

