//
//  NotificationManager.swift
//  Udha
//
//

import Foundation
import UserNotifications
import UIKit
import Combine

class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published var isAuthorized = false
    @Published var didTapNotification = false
    @Published var deviceToken: String? {
        didSet {
            if let token = deviceToken {
                print("Device token set: \(token)")
                // Notify any listeners that we have a new device token
                NotificationCenter.default.post(name: .deviceTokenReceived, object: token)
            }
        }
    }

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DispatchQueue.main.async {
                self.isAuthorized = granted
                if granted {
                    // Register for remote notifications
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
            }
            if let error = error {
                print("Notification permission error: \(error.localizedDescription)")
            }
        }
    }

    func reconcileAttention(sessions: [SessionRow]) {
        let known = Dictionary(sessions.filter(\.supportsAttentionEvents).map { ($0.id.lowercased(), $0.attentionState.events) }, uniquingKeysWith: { a, _ in a })
        UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
            let obsolete = notifications.compactMap { notification -> String? in
                let info = notification.request.content.userInfo
                guard let session = info["sessionId"] as? String,
                      let event = info["eventId"] as? String,
                      let events = known[session.lowercased()] else { return nil }
                return events.contains(where: { $0.id == event && $0.visible }) ? nil : notification.request.identifier
            }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: obsolete)
        }
    }

    func sendNotification(title: String, body: String) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Failed to send notification: \(error.localizedDescription)")
            }
        }
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Don't show banner when app is in foreground
        completionHandler([])
    }

    // Handle notification tap
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // The relay puts the originating session in the APNs payload so a tap
        // lands on the card that needs a human, not just the fleet.
        let info = response.notification.request.content.userInfo
        let sessionID = (info["sessionId"] as? String) ?? (info["session_id"] as? String)
        DispatchQueue.main.async {
            self.didTapNotification = true
            if let sessionID, !sessionID.isEmpty {
                NotificationCenter.default.post(name: .openSessionRequested, object: sessionID)
            }
        }
        completionHandler()
    }
}

// Notification name for device token
extension Notification.Name {
    static let deviceTokenReceived = Notification.Name("deviceTokenReceived")
    /// Carries a session UUID string; posted on notification tap and deep link.
    static let openSessionRequested = Notification.Name("openSessionRequested")
    /// Posted for `udha://live` — the recording Live Activity being tapped.
    static let openLiveMeetingRequested = Notification.Name("openLiveMeetingRequested")
}
