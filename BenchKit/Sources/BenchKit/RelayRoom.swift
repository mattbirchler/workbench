import CryptoKit
import Foundation

/// A Mac's room on the Workbench relay, the way a phone reaches it without
/// Tailscale. The Mac makes a random key and keeps it. The room's id is the
/// key's SHA-256, so the id can go in a pairing code while only the Mac can
/// host the room, and the relay needs no accounts to tell who owns what.
public struct RelayRoom: Sendable, Hashable, Codable {
    /// 32 random bytes in lowercase hex. Never leaves the Mac except to
    /// the relay, as proof it owns the room.
    public let key: String

    public init(key: String) {
        self.key = key
    }

    public static func make() -> RelayRoom {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return RelayRoom(key: bytes.map { String(format: "%02x", $0) }.joined())
    }

    /// What devices use to find the room. Safe to share: it can't be turned
    /// back into the key.
    public var id: String {
        SHA256.hash(data: Self.bytes(hex: key)).map { String(format: "%02x", $0) }.joined()
    }

    /// The Mac's request to host its room on a relay.
    public func hostRequest(relay: URL) -> URLRequest {
        var request = URLRequest(url: Self.url(relay: relay, room: id, role: "host"))
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// A device's request to join a room.
    public static func guestRequest(relay: URL, room: String) -> URLRequest {
        URLRequest(url: url(relay: relay, room: room, role: "guest"))
    }

    private static func url(relay: URL, room: String, role: String) -> URL {
        relay.appendingPathComponent("v1").appendingPathComponent("rooms").appendingPathComponent(room).appendingPathComponent(role)
    }

    static func bytes(hex: String) -> Data {
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), index < hex.endIndex {
            data.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return data
    }
}

/// Why a relay connection ended or couldn't start.
public enum RelayError: Error, Equatable, Sendable {
    /// The Mac isn't connected to the relay: asleep, off, or offline.
    case hostOffline
    /// The Mac went away, or closed this connection. Worth trying again.
    case hostGone
    /// The room already has as many devices as the relay allows.
    case roomFull
    /// The room used up today's allowance, or this address tried too often.
    case overLimit
    /// The Mac connected to its room again from somewhere else.
    case replaced
    /// The other end doesn't hold this pairing code, or someone in between
    /// changed what was sent.
    case wrongPairing
    /// A message bigger than either end will put back together.
    case tooLarge
    /// The relay is restarting. Worth trying again.
    case relayRestarting
    /// Anything else, with the WebSocket close code when there was one.
    case closed(Int)

    /// What the relay's close codes mean (see relay-live/README.md).
    public init(closeCode: Int) {
        switch closeCode {
        case 4404: self = .hostOffline
        case 4410, 4508: self = .hostGone
        case 4403: self = .roomFull
        case 4429: self = .overLimit
        case 4409: self = .replaced
        case 4413: self = .tooLarge
        case 1001: self = .relayRestarting
        default: self = .closed(closeCode)
        }
    }

    /// True when connecting again straight away could work.
    public var isWorthRetrying: Bool {
        switch self {
        case .hostGone, .relayRestarting, .closed: true
        case .hostOffline, .roomFull, .overLimit, .replaced, .wrongPairing, .tooLarge: false
        }
    }
}
