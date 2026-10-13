import SwiftUI
import UIKit

// NOTE: file kept at its historical name so the Xcode synchronized file group
// doesn't reshuffle. The app is Udha.

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        #if DEBUG
        // The permission alert is modal and would sit on top of every
        // screenshot during mock-mode UI testing.
        if !MockHost.isEnabled { NotificationManager.shared.requestPermission() }
        #else
        NotificationManager.shared.requestPermission()
        #endif
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        // Posts `.deviceTokenReceived`, which RootView forwards to the relay so
        // the host can push "needs approval" while the app is backgrounded.
        NotificationManager.shared.deviceToken = token
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }
}

@main
struct UdhaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var notificationManager = NotificationManager.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(notificationManager)
        }
    }
}
