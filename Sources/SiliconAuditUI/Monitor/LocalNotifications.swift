import Foundation
#if canImport(UserNotifications) && !os(tvOS)
import UserNotifications
#endif

/// The app's local notifications: a changed reading, or a report delivered from Apple Watch.
/// Nothing here talks to a server; the system shows what the app posts, if the user allowed it.
public enum LocalNotifications {
    public static let changesThread = "silicon-audit-changes"
    public static let receivedThread = "silicon-audit-received"

    /// Posts one notification if the user has authorized them. Silent otherwise.
    public static func post(id: String, title: String, body: String, thread: String, sound: Bool, route: String) async {
        #if canImport(UserNotifications) && !os(tvOS)
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound ? .default : nil
        content.threadIdentifier = thread
        content.userInfo = ["route": route]
        try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        #endif
    }

    /// Shows the app's notifications as banners while the app is in the foreground too (the
    /// system hides them by default). Call once at launch.
    public static func installPresenter() {
        #if canImport(UserNotifications) && !os(tvOS)
        UNUserNotificationCenter.current().delegate = Presenter.shared
        #endif
    }

    #if canImport(UserNotifications) && !os(tvOS)
    final class Presenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
        static let shared = Presenter()

        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
            #if os(watchOS)
            [.banner, .sound]
            #else
            [.banner, .list, .sound]
            #endif
        }
    }
    #endif
}
