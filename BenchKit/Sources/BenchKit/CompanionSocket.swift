import Foundation

/// The socket a companion connection runs over, so the client doesn't care
/// whether it reached the Mac directly (a WebSocket, over Tailscale or the
/// home network) or through the relay. Messages are whole and in order
/// either way.
protocol CompanionSocket: AnyObject, Sendable {
    /// Starts connecting. Sends queued before it's up go out once it is.
    func start()
    /// Queues a message. Messages go out in the order they're queued.
    func sendData(_ data: Data, completion: @escaping @Sendable (Error?) -> Void)
    /// The next message, or nil for a frame that isn't one.
    func receiveData() async throws -> Data?
    func close()
}

extension CompanionSocket {
    func sendData(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendData(data) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
}

extension URLSessionWebSocketTask: CompanionSocket {
    func start() {
        // A conversation's opening frame can run to megabytes.
        maximumMessageSize = 32 << 20
        resume()
    }

    func sendData(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        send(.data(data), completionHandler: completion)
    }

    func receiveData() async throws -> Data? {
        switch try await receive() {
        case .string(let text): Data(text.utf8)
        case .data(let data): data
        @unknown default: nil
        }
    }

    func close() {
        cancel(with: .normalClosure, reason: nil)
    }
}

/// A connection to the Mac through the relay, shaped like the WebSocket the
/// client already knows: it joins the Mac's room, does the sealing
/// handshake, and then passes whole messages.
final class RelayCompanionSocket: CompanionSocket, @unchecked Sendable {
    private typealias Outgoing = (data: Data, done: @Sendable (Error?) -> Void)
    private let connecting: Task<RelayGuest, Error>
    private let outgoing: AsyncStream<Outgoing>.Continuation
    private let pump: Task<Void, Never>

    init(relay: URL, room: String, token: String, session: URLSession = .shared) {
        let connecting = Task { try await RelayGuest.connect(relay: relay, room: room, token: token, session: session) }
        let (stream, outgoing) = AsyncStream<Outgoing>.makeStream()
        self.connecting = connecting
        self.outgoing = outgoing
        // One task sends everything, so messages keep their order even
        // when they're queued before the handshake is done.
        pump = Task {
            let guest: RelayGuest
            do {
                guest = try await connecting.value
            } catch {
                for await message in stream { message.done(error) }
                return
            }
            for await message in stream {
                do {
                    try await guest.send(message.data)
                    message.done(nil)
                } catch {
                    message.done(error)
                }
            }
        }
    }

    func start() {}

    func sendData(_ data: Data, completion: @escaping @Sendable (Error?) -> Void) {
        outgoing.yield((data, completion))
    }

    func receiveData() async throws -> Data? {
        try await connecting.value.receive()
    }

    func close() {
        outgoing.finish()
        connecting.cancel()
        let connecting = connecting
        Task { (try? await connecting.value)?.close() }
    }
}
