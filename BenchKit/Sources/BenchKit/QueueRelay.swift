import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One sealed prompt as the relay holds it.
public struct QueueItem: Codable, Sendable, Hashable {
    public var id: UUID
    public var sealed: String
    public var addedAt: Date

    public init(id: UUID, sealed: String, addedAt: Date) {
        self.id = id
        self.sealed = sealed
        self.addedAt = addedAt
    }

    private enum CodingKeys: String, CodingKey { case id, sealed, addedAt }

    // The relay writes dates with milliseconds ("2026-11-08T12:00:00.000Z").
    // The usual ISO decoder rejects those, so read the date as text and
    // accept it with or without them.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        sealed = try container.decode(String.self, forKey: .sealed)
        let text = try container.decode(String.self, forKey: .addedAt)
        guard let date = Self.parse(text) else {
            throw DecodingError.dataCorruptedError(forKey: .addedAt, in: container, debugDescription: "Bad date \(text)")
        }
        addedAt = date
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sealed, forKey: .sealed)
        try container.encode(addedAt.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)), forKey: .addedAt)
    }

    static func parse(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

public enum QueueRelayError: Error, Equatable {
    /// The Mac already picked this prompt up, so it can't change.
    case taken
    /// The mailbox already holds 25 waiting prompts.
    case full
    case tooLarge
    /// The relay has no storage set up.
    case notConfigured
    case badAnswer(Int)
    case unreachable
}

/// Talks to the relay's /api/queue endpoint. Every call is a POST with the
/// mailbox id in the JSON body, never in the URL.
public struct QueueRelay: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let productionURL = URL(string: "https://workbench-push.vercel.app/api/queue")!

    /// Where this build should talk to. Debug builds only use the address in
    /// BENCH_TEST_OFFLINE_QUEUE, so a debug app never touches the real relay.
    public static func urlForBuild() -> URL? {
        #if DEBUG
        guard let text = ProcessInfo.processInfo.environment["BENCH_TEST_OFFLINE_QUEUE"],
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
        #else
        return productionURL
        #endif
    }

    public let url: URL
    public let mailbox: String
    private let transport: Transport

    public init(url: URL, mailbox: String,
                transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.url = url
        self.mailbox = mailbox
        self.transport = transport
    }

    public func add(id: UUID, sealed: String) async throws {
        _ = try await send("add", ["id": id.uuidString, "sealed": sealed])
    }

    /// Returns the prompts still waiting, plus which of `ids` the Mac has
    /// already picked up.
    public func list(asking ids: [UUID]) async throws -> (items: [QueueItem], taken: Set<UUID>) {
        let data = try await send("list", ["ids": ids.map(\.uuidString)])
        let answer = try decode(Listing.self, from: data)
        guard let items = answer.items else { throw QueueRelayError.badAnswer(200) }
        return (items, Set(answer.taken ?? []))
    }

    public func delete(id: UUID) async throws {
        _ = try await send("delete", ["id": id.uuidString])
    }

    /// The Mac's call: hands back every waiting prompt and marks them taken,
    /// plus any taken before that weren't acked. An answer without `items`
    /// is an error, not an empty mailbox.
    public func take() async throws -> [QueueItem] {
        let data = try await send("take", [:])
        guard let items = try decode(Listing.self, from: data).items else { throw QueueRelayError.badAnswer(200) }
        return items
    }

    /// The Mac's call once it has saved what `take` handed over, so the
    /// relay stops handing those back.
    public func ack(ids: [UUID]) async throws {
        _ = try await send("ack", ["ids": ids.map(\.uuidString)])
    }

    private struct Listing: Decodable {
        var items: [QueueItem]?
        var taken: [UUID]?
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw QueueRelayError.badAnswer(200)
        }
    }

    private func send(_ action: String, _ fields: [String: Any]) async throws -> Data {
        var body = fields
        body["mailbox"] = mailbox
        body["action"] = action
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw QueueRelayError.unreachable
        }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200..<300: return data
        case 409: throw QueueRelayError.taken
        case 413: throw QueueRelayError.tooLarge
        case 429: throw QueueRelayError.full
        case 503: throw QueueRelayError.notConfigured
        default: throw QueueRelayError.badAnswer(code)
        }
    }
}

/// The phone's rules for what happened to a queued prompt.
public enum QueueSync {
    public enum State: Equatable { case waiting, started, expired }

    /// Taken wins over listed: if the Mac took a prompt, it started, even
    /// when the phone's copy of the list is stale.
    public static func state(of id: UUID, items: [QueueItem], taken: Set<UUID>) -> State {
        if taken.contains(id) { return .started }
        if items.contains(where: { $0.id == id }) { return .waiting }
        return .expired
    }

    /// A warning that starts 12 days after queuing. The relay drops prompts
    /// after 14 days.
    public static func expiryNote(queuedAt: Date, now: Date) -> String? {
        let days = Int((now.timeIntervalSince(queuedAt) / 86_400).rounded(.down))
        switch days {
        case ..<12: return nil
        case 12: return "Expires in 2 days"
        case 13: return "Expires tomorrow"
        default: return "Expires today"
        }
    }
}
