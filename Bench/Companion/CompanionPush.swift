import AppKit
import BenchKit
import Observation
import UniformTypeIdentifiers

/// Notifications and Live Activities for paired phones. Needs an APNs key
/// from the developer account; everything else it keeps itself.
@Observable
final class CompanionPush {
    struct Device: Codable, Hashable {
        var token: String
        var name: String
        var registered: Date
        /// The kinds of notifications this phone turned off in its settings.
        var muted: [CompanionNotificationKind]?
        /// True when the phone can open sealed notifications. Older
        /// phone builds get them in the clear.
        var sealed: Bool?
    }

    static let topic = "me.birchtree.BenchPhone"

    var keyID: String {
        didSet { UserDefaults.standard.set(keyID, forKey: "companion.apnsKeyID"); reload() }
    }
    var teamID: String {
        didSet { UserDefaults.standard.set(teamID, forKey: "companion.apnsTeamID"); reload() }
    }
    private(set) var hasKeyFile: Bool
    private(set) var devices: [Device] = []
    /// This Mac's tailnet name, so a phone paired with several Macs knows
    /// which one a notification is about.
    @ObservationIgnored var hostName: String?
    /// The pairing token, which the sealing key comes from.
    @ObservationIgnored var pairingToken: String?
    private(set) var lastResult: String?
    /// Nil when the key, team or key id is missing or wrong.
    private(set) var setupProblem: String?

    @ObservationIgnored private var sender: PushSender?
    /// Lock screen dashboards by push token, with what each was last sent.
    @ObservationIgnored private var dashboards: [String: Dashboard] = [:]

    private struct Dashboard {
        var registered: Date
        var state: DashboardAttributes.ContentState?
        var sentAt: Date?
    }

    private static let support = BenchPaths.support
    private static let keyFile = support.appendingPathComponent("apns-key.p8")
    private static let devicesFile = support.appendingPathComponent("companion-devices.json")

    var isReady: Bool { sender != nil }
    /// Whether any phone is showing the lock screen dashboard.
    var hasDashboards: Bool { !dashboards.isEmpty }

    init() {
        keyID = UserDefaults.standard.string(forKey: "companion.apnsKeyID") ?? ""
        teamID = UserDefaults.standard.string(forKey: "companion.apnsTeamID") ?? "ZPU7B69KH3"
        hasKeyFile = FileManager.default.fileExists(atPath: Self.keyFile.path)
        if let data = try? Data(contentsOf: Self.devicesFile) {
            devices = (try? JSONDecoder().decode([Device].self, from: data)) ?? []
        }
        reload()
    }

    // MARK: Setup

    /// Copies a downloaded .p8 key into Bench's own folder.
    func importKey(from url: URL) {
        do {
            try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: Self.keyFile.path) { try FileManager.default.removeItem(at: Self.keyFile) }
            try FileManager.default.copyItem(at: url, to: Self.keyFile)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.keyFile.path)
            hasKeyFile = true
            // Apple names the file AuthKey_<KEYID>.p8, which saves typing it.
            let name = url.deletingPathExtension().lastPathComponent
            if keyID.isEmpty, name.hasPrefix("AuthKey_") { keyID = String(name.dropFirst("AuthKey_".count)) }
            reload()
        } catch {
            setupProblem = error.localizedDescription
        }
    }

    /// Goes back to sending through Workbench's relay.
    func removeKey() {
        try? FileManager.default.removeItem(at: Self.keyFile)
        hasKeyFile = false
        reload()
    }

    func presentKeyPicker() {
        let panel = NSOpenPanel()
        panel.message = "Choose the APNs key (.p8) downloaded from the developer portal"
        panel.prompt = "Use Key"
        panel.allowedContentTypes = [UTType(filenameExtension: "p8") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importKey(from: url)
    }

    /// True when notifications go through Workbench's relay rather than
    /// this Mac's own key.
    var usesRelay: Bool { sender?.usesRelay ?? false }

    private func reload() {
        sender = nil
        // Without a key of its own, the Mac sends through Workbench's relay.
        guard hasKeyFile else { sender = PushSender(); setupProblem = nil; return }
        guard !keyID.trimmingCharacters(in: .whitespaces).isEmpty else { setupProblem = "Enter the key's ID."; return }
        guard !teamID.trimmingCharacters(in: .whitespaces).isEmpty else { setupProblem = "Enter your team ID."; return }
        do {
            let pem = try String(contentsOf: Self.keyFile, encoding: .utf8)
            sender = try PushSender(teamID: teamID.trimmingCharacters(in: .whitespaces), keyID: keyID.trimmingCharacters(in: .whitespaces), pem: pem)
            setupProblem = nil
        } catch {
            setupProblem = error.localizedDescription
        }
    }

    // MARK: Devices

    func register(token: String, device: String, sealed: Bool) {
        let muted = devices.first { $0.token == token }?.muted
        // By token only: two phones both called "iPhone" kept evicting each
        // other. A token that has gone stale is forgotten when Apple says so.
        devices.removeAll { $0.token == token }
        devices.append(Device(token: token, name: device, registered: .now, muted: muted, sealed: sealed))
        save()
    }

    /// The kinds of notifications a phone doesn't want, from its settings.
    func setMuted(_ kinds: [CompanionNotificationKind], token: String) {
        guard let index = devices.firstIndex(where: { $0.token == token }), devices[index].muted != kinds else { return }
        devices[index].muted = kinds
        save()
    }

    func forget(_ device: Device) {
        devices.removeAll { $0 == device }
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(devices) { try? data.write(to: Self.devicesFile, options: .atomic) }
    }

    // MARK: Notifications

    /// Sends an alert to every registered phone. Tapping it opens the
    /// session, or the URL. `category` names the buttons it gets on the
    /// phone (see `NotificationActions`); a phone that doesn't know the
    /// name shows none.
    func notify(title: String, body: String, projectID: UUID?, sessionID: UUID?, url: URL? = nil, collapseID: String? = nil,
                kind: CompanionNotificationKind? = nil, category: String? = nil) {
        guard let sender, !devices.isEmpty else { return }
        var payload: [String: Any] = [
            "aps": [
                "alert": ["title": title, "body": body],
                "sound": "default",
                "thread-id": projectID?.uuidString ?? "bench",
            ] as [String: Any],
        ]
        if let projectID { payload["project"] = projectID.uuidString }
        if let sessionID { payload["session"] = sessionID.uuidString }
        if let url { payload["url"] = url.absoluteString }
        if let hostName { payload["host"] = hostName }
        if let category, var aps = payload["aps"] as? [String: Any] {
            aps["category"] = category
            payload["aps"] = aps
        }
        let contents = NotificationSeal.Contents(title: title, body: body, project: projectID?.uuidString, session: sessionID?.uuidString,
                                                 url: url?.absoluteString, host: hostName, category: category)
        let sealedPayload = sealed(contents, threadID: projectID?.uuidString ?? "bench")
        for device in devices where kind.map({ !(device.muted ?? []).contains($0) }) ?? true {
            // Phones that can open them get the words sealed, so the relay
            // and Apple only see that something happened.
            let seals = device.sealed == true && sealedPayload != nil
            let body = seals ? sealedPayload! : payload
            let collapse = seals ? collapseID.map(NotificationSeal.opaque) : collapseID
            Task { [weak self] in
                do {
                    try await sender.send(payload: body, to: device.token, topic: Self.topic, pushType: "alert", collapseID: collapse)
                    self?.lastResult = "Sent to \(device.name) \(Date().formatted(date: .omitted, time: .shortened))"
                } catch {
                    self?.lastResult = "Couldn't send to \(device.name): \(error.localizedDescription)"
                    if (error as? PushSender.Failure)?.message == "Unregistered" { self?.forget(device) }
                }
            }
        }
    }

    /// A notification whose words only the paired phone can read: a
    /// placeholder outside, the real contents sealed with this Mac's key.
    /// Nil until the Mac knows its host and token.
    private func sealed(_ contents: NotificationSeal.Contents, threadID: String) -> [String: Any]? {
        guard let hostName, let pairingToken,
              let sealed = try? NotificationSeal.seal(contents, with: NotificationSeal.key(token: pairingToken, host: hostName)) else { return nil }
        return [
            "aps": [
                "alert": ["title": NotificationSeal.placeholderTitle, "body": NotificationSeal.placeholderBody],
                "sound": "default",
                "mutable-content": 1,
                "thread-id": NotificationSeal.opaque(threadID),
            ] as [String: Any],
            NotificationSeal.payloadKey: sealed,
            NotificationSeal.keyIDKey: NotificationSeal.keyID(host: hostName),
        ]
    }

    func sendTest() {
        notify(title: "Workbench", body: "Notifications are working.", projectID: nil, sessionID: nil)
    }

    // MARK: Lock screen dashboard

    func registerDashboard(token: String, ended: Bool) {
        if ended {
            dashboards[token] = nil
        } else if dashboards[token] == nil {
            dashboards[token] = Dashboard(registered: .now)
        }
    }

    /// Pushes the dashboard to every phone showing it, when it changed or
    /// it's been a while. Routine changes go at low priority so iOS doesn't
    /// hold them back; a session that just started needing you comes with
    /// an alert, which lights up the lock screen.
    func updateDashboards(_ state: DashboardAttributes.ContentState, now: Date = .now) {
        guard let sender, !dashboards.isEmpty else { return }
        for (token, dashboard) in dashboards {
            // iOS ends a Live Activity after 8 hours, and keeps it on the
            // lock screen up to 4 more. Past that it's surely gone.
            if now.timeIntervalSince(dashboard.registered) > 12 * 60 * 60 {
                dashboards[token] = nil
                continue
            }
            let since = dashboard.sentAt.map { now.timeIntervalSince($0) } ?? .infinity
            guard dashboard.state != state || since > DashboardActivity.heartbeat else { continue }
            let newlyWaiting = dashboard.state != nil && state.waiting > (dashboard.state?.waiting ?? 0)
            // What a busy session is doing changes every few seconds; a
            // dashboard doesn't need every step.
            guard newlyWaiting || since > 10 else { continue }
            let alert: (title: String, body: String)? = newlyWaiting
                ? state.rows.first.map { ("An agent needs you", "\($0.project): \($0.text)") } : nil
            dashboards[token]?.state = state
            dashboards[token]?.sentAt = now
            Task { [weak self] in
                do {
                    let payload = try DashboardPayload.update(state, alert: alert, now: now)
                    try await sender.send(payload: payload, to: token, topic: Self.topic + ".push-type.liveactivity",
                                          pushType: "liveactivity", priority: alert == nil ? 5 : 10)
                } catch let failure as PushSender.Failure where ["BadDeviceToken", "Unregistered", "ExpiredToken"].contains(failure.message) {
                    self?.dashboards[token] = nil
                } catch {
                    self?.lastResult = "Lock screen dashboard update failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
