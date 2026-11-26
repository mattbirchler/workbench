import Foundation

/// One WebSocket frame to or from the relay.
public enum RelayFrame: Sendable, Equatable {
    case data(Data)
    case text(String)
}

/// The socket a relay connection runs over. The real one is a WebSocket
/// (`WebSocketRelaySocket`). Tests use one in memory.
public protocol RelaySocket: Sendable {
    /// Queues a frame. Frames go out in the order they're queued. A send
    /// that fails shows up as `receive` throwing.
    func send(_ frame: RelayFrame)
    /// The next frame. Throws a `RelayError` once the socket has ended.
    func receive() async throws -> RelayFrame
    func close()
}

/// A WebSocket to the relay.
public final class WebSocketRelaySocket: RelaySocket {
    private let task: URLSessionWebSocketTask

    public init(request: URLRequest, session: URLSession = .shared) {
        task = session.webSocketTask(with: request)
        // The relay's own frames top out at 256 KB.
        task.maximumMessageSize = 1024 * 1024
        task.resume()
    }

    public func send(_ frame: RelayFrame) {
        let message: URLSessionWebSocketTask.Message = switch frame {
        case .data(let data): .data(data)
        case .text(let text): .string(text)
        }
        task.send(message) { _ in }
    }

    public func receive() async throws -> RelayFrame {
        do {
            switch try await task.receive() {
            case .data(let data): return .data(data)
            case .string(let text): return .text(text)
            @unknown default: throw RelayError.closed(0)
            }
        } catch let error as RelayError {
            throw error
        } catch {
            // The relay says why it closed in the close code.
            throw RelayError(closeCode: task.closeCode.rawValue)
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// A device's connection to a Mac through the relay: sealed messages in
/// and out. Make one with `connect`, which does the handshake.
public actor RelayGuest {
    private let socket: RelaySocket
    private var channel: RelayChannel

    private init(socket: RelaySocket, channel: RelayChannel) {
        self.socket = socket
        self.channel = channel
    }

    /// Joins a Mac's room and does the handshake. Throws `hostOffline` when
    /// the Mac isn't there, `wrongPairing` when it holds a different
    /// pairing code.
    public static func connect(relay: URL, room: String, token: String, session: URLSession = .shared) async throws -> RelayGuest {
        try await connect(over: WebSocketRelaySocket(request: RelayRoom.guestRequest(relay: relay, room: room), session: session),
                          room: room, token: token)
    }

    /// The same over any socket.
    public static func connect(over socket: RelaySocket, room: String, token: String) async throws -> RelayGuest {
        let hello = RelayHandshake.Guest()
        socket.send(.data(hello.frame))
        do {
            guard case .data(let reply) = try await socket.receive() else { throw RelayError.wrongPairing }
            let (channel, confirm) = try hello.finish(reply: reply, token: token, room: room)
            socket.send(.data(confirm))
            return RelayGuest(socket: socket, channel: channel)
        } catch {
            socket.close()
            throw error
        }
    }

    /// Sends one message, split into as many frames as it needs.
    public func send(_ message: Data) throws {
        // No suspension between sealing and queuing, so frames can't be
        // queued out of the order their counters were taken in.
        for frame in try channel.seal(message) { socket.send(.data(frame)) }
    }

    /// The next whole message. One caller at a time.
    public func receive() async throws -> Data {
        while true {
            guard case .data(let frame) = try await socket.receive() else { continue }
            do {
                if let message = try channel.open(frame) { return message }
            } catch {
                socket.close()
                throw error
            }
        }
    }

    public nonisolated func close() {
        socket.close()
    }
}

/// A Mac's side of its room: one socket to the relay, carrying every
/// device that joins. Each device that completes the handshake comes out
/// of `connections`.
public actor RelayHost {
    private enum Guest {
        case new
        case confirming(RelayHandshake.Host)
        case open(RelayChannel, AsyncThrowingStream<Data, Error>.Continuation)
    }

    private let socket: RelaySocket
    private let room: String
    private let token: @Sendable () -> String
    private var guests: [UInt32: Guest] = [:]
    private let arrivals: AsyncStream<RelayHostConnection>.Continuation

    /// Devices as they finish the handshake. Ends when the socket does.
    public nonisolated let connections: AsyncStream<RelayHostConnection>

    /// Hosts `room` on a relay. Call `run` to start.
    public init(relay: URL, room: RelayRoom, token: @escaping @Sendable () -> String, session: URLSession = .shared) {
        self.init(socket: WebSocketRelaySocket(request: room.hostRequest(relay: relay), session: session), room: room.id, token: token)
    }

    /// The same over any socket.
    public init(socket: RelaySocket, room: String, token: @escaping @Sendable () -> String) {
        self.socket = socket
        self.room = room
        self.token = token
        (connections, arrivals) = AsyncStream.makeStream()
    }

    /// Serves the room until the socket ends, then throws why: `replaced`
    /// when this Mac connected again elsewhere, `overLimit`, and so on.
    /// Every open connection ends with the same error.
    public func run() async throws {
        do {
            while true {
                switch try await socket.receive() {
                case .text(let text): control(text)
                case .data(let data): frame(data)
                }
            }
        } catch {
            for guest in guests.values {
                if case .open(_, let messages) = guest { messages.finish(throwing: error) }
            }
            guests.removeAll()
            arrivals.finish()
            throw error
        }
    }

    public nonisolated func close() {
        socket.close()
    }

    private struct Control: Codable {
        var t: String
        var c: UInt32
    }

    private func control(_ text: String) {
        guard let message = try? JSONDecoder().decode(Control.self, from: Data(text.utf8)) else { return }
        switch message.t {
        case "open": guests[message.c] = .new
        case "close": drop(message.c, error: RelayError.hostGone, tellRelay: false)
        default: break
        }
    }

    private func frame(_ data: Data) {
        guard data.count >= 4 else { return }
        let id = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let payload = Data(data.dropFirst(4))
        do {
            switch guests[id] {
            case .none: break
            case .new:
                let host = try RelayHandshake.Host(hello: payload, token: token(), room: room)
                guests[id] = .confirming(host)
                send(host.frame, to: id)
            case .confirming(let host):
                let channel = try host.finish(confirm: payload)
                let (messages, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
                guests[id] = .open(channel, continuation)
                arrivals.yield(RelayHostConnection(id: id, host: self, messages: messages))
            case .open(var channel, let messages):
                if let message = try channel.open(payload) { messages.yield(message) }
                guests[id] = .open(channel, messages)
            }
        } catch {
            // A device with the wrong pairing code, or a frame that was
            // tampered with: that connection is over, the rest carry on.
            drop(id, error: error, tellRelay: true)
        }
    }

    private func send(_ frame: Data, to id: UInt32) {
        socket.send(.data(withUnsafeBytes(of: id.bigEndian) { Data($0) } + frame))
    }

    fileprivate func send(_ message: Data, on id: UInt32) throws {
        guard case .open(var channel, let messages) = guests[id] else { throw RelayError.hostGone }
        for frame in try channel.seal(message) { send(frame, to: id) }
        guests[id] = .open(channel, messages)
    }

    fileprivate func close(_ id: UInt32) {
        drop(id, error: nil, tellRelay: true)
    }

    private func drop(_ id: UInt32, error: Error?, tellRelay: Bool) {
        guard let guest = guests.removeValue(forKey: id) else { return }
        if case .open(_, let messages) = guest { messages.finish(throwing: error) }
        if tellRelay, let text = try? JSONEncoder().encode(Control(t: "close", c: id)) {
            socket.send(.text(String(decoding: text, as: UTF8.self)))
        }
    }
}

/// One device connected to a Mac through the relay, as the Mac sees it.
public struct RelayHostConnection: Sendable {
    /// The relay's number for this connection, unique while the room is open.
    public let id: UInt32
    fileprivate let host: RelayHost
    /// Whole messages from the device. Ends when the device leaves, and
    /// throws when the connection breaks.
    public let messages: AsyncThrowingStream<Data, Error>

    public func send(_ message: Data) async throws {
        try await host.send(message, on: id)
    }

    public func close() async {
        await host.close(id)
    }
}
