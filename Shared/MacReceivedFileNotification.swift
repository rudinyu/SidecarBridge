#if os(macOS)
import AppKit
import Foundation
import UserNotifications

enum MacReceivedFileNotification {
    private static let filePathKey = "receivedFilePath"
    private static let notificationDelegate = ReceivedFileNotificationDelegate()

    static func installDelegate() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
    }

    static func post(for fileURL: URL) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                enqueueNotification(for: fileURL, with: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    guard granted else { return }
                    enqueueNotification(for: fileURL, with: center)
                }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }

    private static func enqueueNotification(for fileURL: URL, with center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Received \(fileURL.lastPathComponent)"
        content.body = "Saved to \(fileURL.deletingLastPathComponent().path)"
        content.sound = .default
        content.userInfo = [filePathKey: fileURL.path]

        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private final class ReceivedFileNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
            withCompletionHandler completionHandler: @escaping () -> Void
        ) {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
               let path = response.notification.request.content.userInfo[filePathKey] as? String {
                let fileURL = URL(fileURLWithPath: path)
                Task { @MainActor in
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            }
            completionHandler()
        }

        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .list, .sound])
        }
    }
}
#endif
