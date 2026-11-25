import BenchKit
import UIKit
import UserNotifications

/// Asks for notification permission, hands the device token to the client,
/// and routes a tapped notification to its session.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var client: CompanionClient?
    static weak var navigator: Navigator? {
        didSet {
            // A tap on a cold launch arrives before the navigator exists.
            guard let navigator, let open = pendingOpen else { return }
            pendingOpen = nil
            navigator.open(projectID: open.project, sessionID: open.session)
        }
    }
    static weak var pairing: PairingStore?
    /// Where a tapped notification wanted to go, until there's a navigator.
    private static var pendingOpen: (project: UUID, session: UUID?)?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        NotificationAnswers.register()
        #if DEBUG
        // Testing sealed notifications in the simulator: quiet permission
        // with no prompt, then the delivered notifications' words written to
        // Documents/delivered.txt after this many seconds.
        if let wait = ProcessInfo.processInfo.environment["BENCH_NOTIFICATION_TEST"].flatMap(Double.init) {
            Task {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.provisional, .alert, .sound])
                application.registerForRemoteNotifications()
                try? await Task.sleep(for: .seconds(wait))
                let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                let text = delivered.map { "\($0.request.content.title) | \($0.request.content.body) | \($0.request.content.userInfo["host"] ?? "no host")" }
                let file = URL.documentsDirectory.appendingPathComponent("delivered.txt")
                try? text.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            }
        }
        if ProcessInfo.processInfo.environment["BENCH_PAIR_URL"] != nil { return true }  // screenshots: no permission prompt
        #endif
        // Notifications are opt-in: only re-register if you turned them on.
        // Phones that allowed them before they became opt-in keep them.
        Task {
            await PhoneNotifications.settle()
            if PhoneNotifications.isOn { application.registerForRemoteNotifications() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Self.client?.setPushToken(token)
        #if DEBUG
        if ProcessInfo.processInfo.environment["BENCH_NOTIFICATION_TEST"] != nil {
            try? token.write(to: URL.documentsDirectory.appendingPathComponent("token.txt"), atomically: true, encoding: .utf8)
        }
        #endif
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.client?.notePushProblem(error.localizedDescription)
    }

    /// Show banners even while the app is open, since you may be looking
    /// at a different project.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let project = (info["project"] as? String).flatMap(UUID.init(uuidString:))
        let session = (info["session"] as? String).flatMap(UUID.init(uuidString:))
        let url = (info["url"] as? String).flatMap(URL.init(string:))
        let host = info["host"] as? String
        // A button on the notification: answer from here, without opening
        // the app. iOS keeps the app running until this returns.
        if let answer = NotificationAnswers.answer(for: response), let session {
            let thread = response.notification.request.content.threadIdentifier
            let projectText = info["project"] as? String
            await MainActor.run { Analytics.capture(.notificationAnswered) }
            let problem = await NotificationAnswers.send(answer, sessionID: session, host: host,
                                                         client: Self.client, pairing: Self.pairing)
            if let problem {
                await NotificationAnswers.report(problem, thread: thread, project: projectText, session: session.uuidString, host: host)
            }
            return
        }
        await MainActor.run {
            Analytics.capture(.notificationOpened)
            // The notification may be from a Mac other than the one we're
            // showing. Older Mac builds don't say, so assume the current one.
            if let host, host != Self.pairing?.info?.host { Self.pairing?.select(host: host) }
            if let project {
                if let navigator = Self.navigator {
                    navigator.open(projectID: project, sessionID: session)
                } else {
                    Self.pendingOpen = (project, session)
                }
            } else if let url {
                Self.navigator?.pendingURL = url
            }
        }
    }
}

/// Notifications from your Mac are off until you turn them on in the
/// menu, so the app doesn't ask for permission up front.
enum PhoneNotifications {
    static let key = "notificationsEnabled"

    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// The first time, keeps notifications on for a phone that allowed
    /// them before they became opt-in.
    static func settle() async {
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        UserDefaults.standard.set(settings.authorizationStatus == .authorized, forKey: key)
    }

    /// Asks for permission and registers. False if permission was refused.
    @MainActor
    static func turnOn() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        UserDefaults.standard.set(granted, forKey: key)
        if granted { UIApplication.shared.registerForRemoteNotifications() }
        return granted
    }

    @MainActor
    static func turnOff() {
        UserDefaults.standard.set(false, forKey: key)
        UIApplication.shared.unregisterForRemoteNotifications()
    }
}
