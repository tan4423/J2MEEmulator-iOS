//
//  AppDelegate.swift
//  J2MEEmulator
//
//  Created by Alexander Goremykin on 19.03.2026.
//

import UIKit

@main
class AppDelegate: UIResponder, UIApplicationDelegate {



    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        return true
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        // Record exactly one process-wide warning even if all games are hidden.
        jvm_bridge_memory_note_warning()
        jvm_bridge_trim_classpath_cache()
        _ = j2me_render_trim_memory_cache()
        for scene in application.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                guard let nav = window.rootViewController as? UINavigationController,
                      let library = nav.viewControllers.first as? AppsListViewController else { continue }
                library.handleAppMemoryPressure()
            }
        }
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

