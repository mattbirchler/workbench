import BenchKit
import Foundation
import Observation

/// Counts of what went through the relay. Never what was said.
struct RelayUsage: Codable, Equatable {
    var connections = 0
    var messagesIn = 0
    var messagesOut = 0
    var bytesIn = 0
    var bytesOut = 0

    static func + (a: RelayUsage, b: RelayUsage) -> RelayUsage {
        RelayUsage(connections: a.connections + b.connections, messagesIn: a.messagesIn + b.messagesIn,
                   messagesOut: a.messagesOut + b.messagesOut, bytesIn: a.bytesIn + b.bytesIn, bytesOut: a.bytesOut + b.bytesOut)
    }

    var isEmpty: Bool { self == RelayUsage() }
}

/// This Mac's side of the Workbench relay: it keeps the Mac's room open so
/// paired devices can reach it from anywhere without Tailscale, and hands
/// each device that joins to the companion server.
///
/// Off unless turned on, in Settings > iPhone.
@MainActor
@Observable
final class CompanionRelay {
    /// The relay Workbench runs.
    static let defaultAddress = "wss://relay-production-7c2aaa99.up.railway.app"
    static let enabledKey = "companion.relay.enabled"
    static let addressKey = "companion.relay.url"
    private static let usageKey = "companion.relay.usage"
    private static let usageDayKey = "companion.relay.usageDay"

    enum State: Equatable {
        case off
        case connecting
        case connected
        /// Not connected, and why, in words for the settings screen.
        case problem(String)
    }

    private(set) var state = State.off
    private(set) var room: RelayRoom
    /// Whether this Mac keeps a room on the relay. Saved.
    private(set) var isOn = UserDefaults.standard.bool(forKey: CompanionRelay.enabledKey)
    /// The address typed in Settings, empty for Workbench's own relay. Saved.
    private(set) var customAddress = UserDefaults.standard.string(forKey: CompanionRelay.addressKey) ?? ""
    @ObservationIgnored private let roomFile: URL
    @ObservationIgnored private let token: @Sendable () -> String
    @ObservationIgnored private let accept: (RelayHostConnection) -> Void
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var host: RelayHost?
    /// Called when the room or the relay's address changes, so connected
    /// devices hear the new one.
    @ObservationIgnored var onChange: (() -> Void)?

    init(support: URL, token: @escaping @Sendable () -> String, accept: @escaping (RelayHostConnection) -> Void) {
        roomFile = support.appendingPathComponent("companion-relay-room")
        self.token = token
        self.accept = accept
        room = Self.loadOrMakeRoom(at: roomFile)
    }

    func setOn(_ on: Bool) {
        guard on != isOn else { return }
        isOn = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        Analytics.capture(.relayToggled, ["on": on, "own_relay": address != Self.defaultAddress])
        if on { start() } else { stop() }
        onChange?()
    }

    /// Points this Mac at another relay, or back at Workbench's when
    /// empty. Devices hear the new address over the connection they have.
    func setCustomAddress(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != customAddress else { return }
        customAddress = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.addressKey)
        if isOn {
            stop()
            start()
        }
        onChange?()
    }

    /// The relay's address: Workbench's, or one the person hosts.
    var address: String {
        customAddress.isEmpty ? Self.defaultAddress : customAddress
    }

    var isProblem: Bool {
        if case .problem = state { return true }
        return false
    }

    /// The state in words, for Settings.
    var statusText: String {
        switch state {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .problem(let text): text
        }
    }

    /// What goes in the pairing code, or nil while the relay is off.
    var endpoint: RelayEndpoint? {
        let endpoint = RelayEndpoint(url: address, room: room.id)
        return isOn && endpoint.relayURL != nil ? endpoint : nil
    }

    /// Keeps the room open, reconnecting whenever the line drops.
    func start() {
        guard isOn, running == nil else { return }
        guard let url = RelayEndpoint(url: address, room: room.id).relayURL else {
            state = .problem("The relay's address isn't one Workbench can use.")
            return
        }
        state = .connecting
        let room = room, token = token
        running = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let host = RelayHost(relay: url, room: room, token: token)
                self?.host = host
                let arrivals = Task { [weak self] in
                    for await connection in host.connections { self?.accept(connection) }
                }
                // The socket says nothing when it opens, so count it as up
                // once it has stayed up for a few seconds.
                let settled = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    self?.state = .connected
                    failures = 0
                }
                var wait = Duration.seconds(2)
                do {
                    try await host.run()
                } catch {
                    settled.cancel()
                    arrivals.cancel()
                    guard !Task.isCancelled, let self else { return }
                    failures += 1
                    let relayError = error as? RelayError
                    switch relayError {
                    case .replaced:
                        // Another copy of Workbench has this room. Fighting
                        // over it would drop both, so back off for a while.
                        self.state = .problem("Another copy of Workbench on this Mac is using the relay.")
                        wait = .seconds(60)
                    case .overLimit:
                        self.state = .problem("This Mac has used today's allowance on the relay. It works again tomorrow.")
                        wait = .seconds(600)
                    default:
                        self.state = failures > 2 ? .problem("Can't reach the relay. Trying again.") : .connecting
                        wait = .seconds(min(30, Int(pow(2, Double(min(failures, 5))))))
                    }
                }
                try? await Task.sleep(for: wait)
            }
        }
    }

    func stop() {
        running?.cancel()
        running = nil
        host?.close()
        host = nil
        state = .off
    }

    /// A new room, with the new pairing code: devices paired before can't
    /// find this Mac on the relay any more.
    func newRoom() {
        room = RelayRoom.make()
        Self.save(room, at: roomFile)
        if isOn {
            stop()
            start()
        }
        onChange?()
    }

    // MARK: Usage

    /// Adds to today's counts, and sends yesterday's once the day turns.
    func note(_ usage: RelayUsage) {
        let defaults = UserDefaults.standard
        let today = Int(Date.now.timeIntervalSince1970 / 86_400)
        var total = (defaults.data(forKey: Self.usageKey)).flatMap { try? JSONDecoder().decode(RelayUsage.self, from: $0) } ?? RelayUsage()
        let day = defaults.integer(forKey: Self.usageDayKey)
        if day != today {
            if day != 0, !total.isEmpty {
                Analytics.capture(.relayUsage, [
                    "connections": total.connections, "messages_in": total.messagesIn, "messages_out": total.messagesOut,
                    "bytes_in": total.bytesIn, "bytes_out": total.bytesOut, "own_relay": address != Self.defaultAddress,
                ])
            }
            total = RelayUsage()
            defaults.set(today, forKey: Self.usageDayKey)
        }
        total = total + usage
        defaults.set(try? JSONEncoder().encode(total), forKey: Self.usageKey)
    }

    // MARK: The room's key

    private static func loadOrMakeRoom(at file: URL) -> RelayRoom {
        if let data = try? Data(contentsOf: file) {
            let key = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if key.count == 64, key.allSatisfy(\.isHexDigit) { return RelayRoom(key: key) }
        }
        let room = RelayRoom.make()
        save(room, at: file)
        return room
    }

    private static func save(_ room: RelayRoom, at file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(room.key.utf8).write(to: file, options: .atomic)
        // Readable by you only, like the pairing token beside it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
