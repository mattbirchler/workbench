import Foundation

/// How the phone finds the Mac: its name on the tailnet and the token Bench
/// made for it. Bench shows this as a QR code; the phone keeps it.
public struct PairingInfo: Codable, Sendable, Hashable {
    /// The Mac's tailnet name, like "matts-macbook-pro-1.tail1234.ts.net".
    public var host: String
    public var token: String
    /// How to reach the Mac over the home network. Nil for codes made
    /// before that existed.
    public var local: LocalEndpoint?
    /// The Mac's room on the Workbench relay, for reaching it from away
    /// without Tailscale. Nil when the Mac hasn't turned that on.
    public var relay: RelayEndpoint?

    /// The Mac's home-network side: its random Bonjour id and the
    /// certificate's SHA-256 fingerprint, in lowercase hex.
    public struct LocalEndpoint: Codable, Sendable, Hashable {
        public var mac: String
        public var fingerprint: String

        public init(mac: String, fingerprint: String) {
            self.mac = mac
            self.fingerprint = fingerprint
        }
    }

    public init(host: String, token: String, local: LocalEndpoint? = nil, relay: RelayEndpoint? = nil) {
        self.host = host
        self.token = token
        self.local = local
        self.relay = relay
    }

    private static let localOnlySuffix = ".local-only.workbench"

    /// A stand-in host for a Mac paired without Tailscale. It isn't a real
    /// name, so it only identifies the Mac on the phone.
    public static func localOnlyHost(mac: String) -> String {
        "\(mac)\(localOnlySuffix)"
    }

    /// True when this pairing has no tailnet name and works only at home.
    public var isLocalOnly: Bool { host.hasSuffix(Self.localOnlySuffix) }

    /// What the Mac answers when the phone's pairing code is old or wrong.
    /// The phone looks for this exact text to ask for a new pairing.
    public static let rejectedMessage = "That pairing code isn't valid. Scan the code in Workbench's settings again."

    /// The companion's WebSocket address. Tailscale Serve gives the Mac
    /// HTTPS, so this is always secure.
    public var socketURL: URL? {
        if isLocalOnly { return nil }
        #if DEBUG
        // For testing two copies of Bench on one Mac: "ws://127.0.0.1:48803".
        if host.hasPrefix("ws://") { return URL(string: host) }
        #endif
        return URL(string: "wss://\(host)/ws")
    }

    /// What the QR code holds: `bench://pair?host=…&token=…`, plus
    /// `&mac=…&fp=…` when the Mac offers the home network and
    /// `&relay=…&room=…` when it offers the relay.
    public var url: URL? {
        var parts = URLComponents()
        parts.scheme = "bench"
        parts.host = "pair"
        var items = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "token", value: token)]
        if let local {
            items.append(URLQueryItem(name: "mac", value: local.mac))
            items.append(URLQueryItem(name: "fp", value: local.fingerprint))
        }
        if let relay {
            items.append(URLQueryItem(name: "relay", value: relay.url))
            items.append(URLQueryItem(name: "room", value: relay.room))
        }
        parts.queryItems = items
        return parts.url
    }

    public init?(url: URL) {
        guard url.scheme == "bench", url.host() == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let host = items.first(where: { $0.name == "host" })?.value, !host.isEmpty,
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty
        else { return nil }
        // The local part counts only when both halves are there.
        var local: LocalEndpoint?
        if let mac = items.first(where: { $0.name == "mac" })?.value, !mac.isEmpty,
           let fp = items.first(where: { $0.name == "fp" })?.value, !fp.isEmpty {
            local = LocalEndpoint(mac: mac, fingerprint: fp)
        }
        // The same for the relay, and only an address that makes sense.
        var relay: RelayEndpoint?
        if let address = items.first(where: { $0.name == "relay" })?.value,
           let room = items.first(where: { $0.name == "room" })?.value {
            let endpoint = RelayEndpoint(url: address, room: room)
            if endpoint.relayURL != nil { relay = endpoint }
        }
        self.init(host: host, token: token, local: local, relay: relay)
    }

    /// A fresh token: 32 random bytes, as letters and digits.
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "a")
            .replacingOccurrences(of: "/", with: "b")
            .replacingOccurrences(of: "=", with: "")
    }
}
