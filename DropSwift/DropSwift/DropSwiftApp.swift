//
//  DropSwiftApp.swift
//  DropSwift
//
//  Created by Avik Sengupta on 24/06/26.
//

import SwiftUI

@main
struct DropSwiftApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Bridges the background URLSession's relaunch events into the uploader so a
/// transfer that finishes while the app is suspended can wake the app, deliver
/// its completion, and continue the queue.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions:
                        [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Recreate the background session up front so its delegate is ready to
        // receive events for any transfers still running from a previous launch.
        BackgroundUploader.shared.activate()
        return true
    }

    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        BackgroundUploader.shared.setSystemCompletion(completionHandler)
    }
}
