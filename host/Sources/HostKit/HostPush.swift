import BenchKit
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Tells paired phones when a session needs you or has finished. The
/// notification goes through Workbench's push relay, which hands it to
/// Apple. Phones that can open them get the words sealed with a key from
/// the pairing code, so the relay and Apple only see that something
/// happened.
public final class HostPush: @unchecked Sendable {
    struct Device: Codable, Equatable {
        var token: String
        var name: String
        var sealed: Bool
        /// "sandbox" or "production", once Apple has taken one.
        var environment: String?
    }

    static let relayURL = URL(string: "https://workbench-push.vercel.app/api/push")!
    static let topic = "me.birchtree.BenchPhone"

    private let file: URL
    private var devices: [Device] = []
    /// The name phones paired with, which their key is made from. Nil
    /// until `workbench-host pair` has run.
    public var hostName: String?
    public var pairingToken: String?

    public init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([Device].self, from: data) {
            devices = saved
        }
    }

    public func register(token: String, device: String, sealed: Bool) {
        let environment = devices.first { $0.token == token }?.environment
        devices.removeAll { $0.token == token }
        devices.append(Device(token: token, name: device, sealed: sealed, environment: environment))
        save()
        hostLog("notifications: \(device) registered")
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Sends an alert to every registered phone. Tapping it opens the session.
    public func notify(title: String, body: String, projectID: UUID, sessionID: UUID, category: String) {
        guard !devices.isEmpty else { return }
        let thread = projectID.uuidString
        var plain: [String: Any] = [
            "aps": [
                "alert": ["title": title, "body": body],
                "sound": "default",
                "thread-id": thread,
                "category": category,
            ] as [String: Any],
            "project": projectID.uuidString,
            "session": sessionID.uuidString,
        ]
        if let hostName { plain["host"] = hostName }
        var sealedPayload: [String: Any]?
        if let hostName, let pairingToken {
            let contents = NotificationSeal.Contents(title: title, body: body, project: projectID.uuidString, session: sessionID.uuidString,
                                                     url: nil, host: hostName, category: category)
            if let sealed = try? NotificationSeal.seal(contents, with: NotificationSeal.key(token: pairingToken, host: hostName)) {
                sealedPayload = [
                    "aps": [
                        "alert": ["title": NotificationSeal.placeholderTitle, "body": NotificationSeal.placeholderBody],
                        "sound": "default",
                        "mutable-content": 1,
                        "thread-id": NotificationSeal.opaque(thread),
                    ] as [String: Any],
                    NotificationSeal.payloadKey: sealed,
                    NotificationSeal.keyIDKey: NotificationSeal.keyID(host: hostName),
                ]
            }
        }
        for device in devices {
            let seals = device.sealed && sealedPayload != nil
            let payload = seals ? sealedPayload! : plain
            let collapse = seals ? NotificationSeal.opaque(sessionID.uuidString) : sessionID.uuidString
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { continue }
            let known = device.environment
            Task { [weak self] in
                // A build from Xcode uses Apple's sandbox, TestFlight and the
                // App Store use production. Try the one that worked before.
                let order = known.map { [$0] } ?? ["production", "sandbox"]
                for (index, environment) in order.enumerated() {
                    let reason = await Self.post(data, token: device.token, environment: environment, collapseID: collapse)
                    if reason == nil {
                        if known == nil { DispatchQueue.main.async { self?.remember(environment, for: device.token) } }
                        return
                    }
                    if reason == "BadDeviceToken", index + 1 < order.count { continue }
                    if reason == "Unregistered" || (reason == "BadDeviceToken" && known != nil) {
                        DispatchQueue.main.async { self?.forget(device.token) }
                    }
                    hostLog("notifications: couldn't send to \(device.name): \(reason ?? "")")
                    return
                }
            }
        }
    }

    private func remember(_ environment: String, for token: String) {
        guard let index = devices.firstIndex(where: { $0.token == token }) else { return }
        devices[index].environment = environment
        save()
    }

    private func forget(_ token: String) {
        devices.removeAll { $0.token == token }
        save()
    }

    /// Nil when Apple took it, otherwise why not.
    private static func post(_ payload: Data, token: String, environment: String, collapseID: String) async -> String? {
        var request = URLRequest(url: relayURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let envelope: [String: Any] = [
            "environment": environment, "token": token, "topic": topic, "pushType": "alert", "priority": 10,
            "payload": (try? JSONSerialization.jsonObject(with: payload)) ?? [:], "collapseID": String(collapseID.prefix(64)),
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: envelope)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "No response." }
            if http.statusCode == 200 { return nil }
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            return reason ?? "The push relay answered \(http.statusCode)."
        } catch {
            return error.localizedDescription
        }
    }
}
