import BenchKit
import UIKit
import UserNotifications

/// Answering from a notification: Allow, Deny or a typed reply, sent to
/// the Mac without opening the app.
@MainActor
enum NotificationAnswers {
    enum Answer {
        case allow, deny
        case reply(String)
    }

    /// Tells iOS which buttons each kind of notification gets. The Mac
    /// names the kind (see `NotificationActions`).
    nonisolated static func register() {
        // Allow lets an agent run something on your Mac and a reply is a
        // new instruction, so both need the phone unlocked. Deny only
        // ever stops something.
        let allow = UNNotificationAction(identifier: NotificationActions.allow, title: "Allow",
                                         options: [.authenticationRequired], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: NotificationActions.deny, title: "Deny",
                                        options: [], icon: UNNotificationActionIcon(systemImageName: "xmark"))
        let reply = UNTextInputNotificationAction(identifier: NotificationActions.reply, title: "Reply",
                                                  options: [.authenticationRequired],
                                                  icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: NotificationActions.permissionCategory, actions: [allow, deny, reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: NotificationActions.replyCategory, actions: [reply], intentIdentifiers: []),
        ])
    }

    /// The answer a tapped button stands for, or nil for a plain tap.
    nonisolated static func answer(for response: UNNotificationResponse) -> Answer? {
        switch response.actionIdentifier {
        case NotificationActions.allow: return .allow
        case NotificationActions.deny: return .deny
        case NotificationActions.reply:
            let text = (response as? UNTextInputNotificationResponse)?.userText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : .reply(text)
        default: return nil
        }
    }

    /// Sends the answer to the Mac the notification came from. Returns
    /// what went wrong, in words to show, or nil when it went through.
    static func send(_ answer: Answer, sessionID: UUID, host: String?, client main: CompanionClient?, pairing: PairingStore?) async -> String? {
        let known = pairing?.macs ?? []
        guard let info = host.flatMap({ host in known.first { $0.host == host } }) ?? (host == nil ? pairing?.info : nil) else {
            return "This phone isn't paired with that Mac any more."
        }
        // The app's own connection when it's up and on that Mac. In the
        // background it's closed, so a connection of our own for the
        // moment it takes.
        let own: CompanionClient?
        let client: CompanionClient
        if let main, main.status == .connected, main.host == info.host {
            own = nil
            client = main
        } else {
            // With the relay, so an answer gets through away from home too.
            let fresh = CompanionClient(deviceName: UIDevice.current.name, features: [CompanionFeature.relay])
            fresh.connect(info)
            own = fresh
            client = fresh
        }
        defer { own?.disconnect() }

        func session() -> CompanionSession? {
            client.snapshot?.projects.lazy.flatMap(\.sessions).first { $0.id == sessionID }
        }
        guard await wait(seconds: 15, until: { client.status == .connected && client.snapshot != nil }) else {
            return "Couldn't reach your Mac."
        }
        guard let now = session() else { return "That session has ended." }

        switch answer {
        case .allow, .deny:
            // Answered at the Mac in the meantime, or it has moved on to
            // asking something else: don't answer a question you didn't see.
            guard now.isAllowOrDeny else { return "That was already answered." }
            let allow = if case .allow = answer { true } else { false }
            client.answer(sessionID: sessionID, allow: allow)
            let settled = await wait(seconds: 6) { client.sendProblems[sessionID] != nil || session()?.isAllowOrDeny != true }
            if let problem = client.sendProblems[sessionID] { return problem }
            return settled ? nil : "Your Mac didn't confirm the answer."
        case .reply(let text):
            client.reply(sessionID: sessionID, text: text)
            // The Mac only speaks up when it couldn't send.
            _ = await wait(seconds: 2.5) { client.sendProblems[sessionID] != nil }
            return client.sendProblems[sessionID]
        }
    }

    /// A notification saying the answer didn't go through. Tapping it
    /// opens the session, like the one it was an answer to.
    static func report(_ problem: String, thread: String, project: String?, session: String, host: String?) {
        let content = UNMutableNotificationContent()
        content.title = "Your answer wasn't sent"
        content.body = "\(problem) Open Workbench to answer."
        content.sound = .default
        content.threadIdentifier = thread
        var info: [String: String] = ["session": session]
        info["project"] = project
        info["host"] = host
        content.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func wait(seconds: Double, until done: () -> Bool) async -> Bool {
        let end = Date.now.addingTimeInterval(seconds)
        while !done() {
            if Date.now >= end { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return true
    }
}
