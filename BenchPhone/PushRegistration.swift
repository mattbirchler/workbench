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
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    /// A tap on a notification, or on one of its buttons.
    ///
    /// These are the completion-handler forms on purpose. UIKit insists the
    /// handler is called on the main thread and ends the app if it isn't
    /// ("Call must be made on main thread"). The `async` forms call it from
    /// wherever the method happens to finish, which for a method that isn't
    /// on the main actor is a background thread: every tap ended the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let tap = Tap(response)
        let done = MainThreadCallback(completionHandler)
        Task { @MainActor in
            await Self.handle(tap)
            done.call()
        }
    }

    /// What a tapped notification says, taken out of it so it can cross to
    /// the main actor.
    private nonisolated struct Tap: Sendable {
        let project: UUID?
        let projectText: String?
        let session: UUID?
        let url: URL?
        let host: String?
        let thread: String
        let answer: NotificationAnswers.Answer?

        init(_ response: UNNotificationResponse) {
            let content = response.notification.request.content
            let info = content.userInfo
            projectText = info["project"] as? String
            project = projectText.flatMap(UUID.init(uuidString:))
            session = (info["session"] as? String).flatMap(UUID.init(uuidString:))
            url = (info["url"] as? String).flatMap(URL.init(string:))
            host = info["host"] as? String
            thread = content.threadIdentifier
            answer = NotificationAnswers.answer(for: response)
        }
    }

    /// The system's completion handler, which may only be called on the
    /// main thread.
    private nonisolated struct MainThreadCallback: @unchecked Sendable {
        private let handler: () -> Void
        init(_ handler: @escaping () -> Void) { self.handler = handler }
        @MainActor func call() { handler() }
    }

    private static func handle(_ tap: Tap) async {
        // A button on the notification: answer from here, without opening
        // the app. iOS keeps the app running until the handler is called.
        if let answer = tap.answer, let session = tap.session {
            Analytics.capture(.notificationAnswered)
            let problem = await NotificationAnswers.send(answer, sessionID: session, host: tap.host,
                                                         client: client, pairing: pairing)
            if let problem {
                NotificationAnswers.report(problem, thread: tap.thread, project: tap.projectText, session: session.uuidString, host: tap.host)
            }
            return
        }
        Analytics.capture(.notificationOpened)
        // The notification may be from a Mac other than the one we're
        // showing. Older Mac builds don't say, so assume the current one.
        if let host = tap.host, host != pairing?.info?.host { pairing?.select(host: host) }
        if let project = tap.project {
            if let navigator {
                navigator.open(projectID: project, sessionID: tap.session)
            } else {
                pendingOpen = (project, tap.session)
            }
        } else if let url = tap.url {
            navigator?.pendingURL = url
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
