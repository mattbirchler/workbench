import Foundation
import Testing
@testable import BenchKit

/// A socket in memory: what one end sends, the test's relay decides where
/// to deliver.
final class MemorySocket: RelaySocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [RelayFrame] = []
    private var ended: RelayError?
    private var waiter: CheckedContinuation<RelayFrame, Error>?
    var onSend: (@Sendable (RelayFrame) -> Void)?
    var onClose: (@Sendable () -> Void)?

    func send(_ frame: RelayFrame) { onSend?(frame) }

    func receive() async throws -> RelayFrame {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let frame = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: frame)
            } else if let ended {
                lock.unlock()
                continuation.resume(throwing: ended)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func deliver(_ frame: RelayFrame) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: frame)
        } else {
            inbox.append(frame)
            lock.unlock()
        }
    }

    func end(_ error: RelayError) {
        lock.lock()
        guard ended == nil else { return lock.unlock() }
        ended = error
        let waiter = waiter
        self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: error)
    }

    func close() {
        onClose?()
        end(.closed(1000))
    }
}

/// The relay's forwarding, in memory: one host socket, guests tagged with a
/// connection id, the same messages as relay-live/relay.js.
final class MemoryRelay: @unchecked Sendable {
    let host = MemorySocket()
    private let lock = NSLock()
    private var guests: [UInt32: MemorySocket] = [:]
    private var next: UInt32 = 1
    /// Changes frames on their way to the Mac, as a relay that meant harm could.
    var tamper: (@Sendable (Data) -> Data)?

    init() {
        host.onSend = { [weak self] frame in
            guard let self else { return }
            switch frame {
            case .data(let data):
                let id = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                self.guest(id)?.deliver(.data(Data(data.dropFirst(4))))
            case .text(let text):
                guard text.contains("\"close\""), let id = UInt32(text.filter(\.isNumber)) else { return }
                self.remove(id)?.end(.hostGone)
            }
        }
    }

    private func guest(_ id: UInt32) -> MemorySocket? {
        lock.lock()
        defer { lock.unlock() }
        return guests[id]
    }

    private func remove(_ id: UInt32) -> MemorySocket? {
        lock.lock()
        defer { lock.unlock() }
        return guests.removeValue(forKey: id)
    }

    func join() -> MemorySocket {
        let socket = MemorySocket()
        lock.lock()
        let id = next
        next += 1
        guests[id] = socket
        lock.unlock()
        host.deliver(.text("{\"t\":\"open\",\"c\":\(id)}"))
        socket.onSend = { [weak self] frame in
            guard let self, case .data(let data) = frame else { return }
            let sent = self.tamper?(data) ?? data
            self.host.deliver(.data(withUnsafeBytes(of: id.bigEndian) { Data($0) } + sent))
        }
        socket.onClose = { [weak self] in
            guard let self, self.remove(id) != nil else { return }
            self.host.deliver(.text("{\"t\":\"close\",\"c\":\(id)}"))
        }
        return socket
    }
}

@Suite struct RelayConnectionTests {
    let token = PairingInfo.makeToken()
    let room = RelayRoom.make()

    /// A relay with the Mac's side running.
    func serving() -> (relay: MemoryRelay, host: RelayHost, running: Task<RelayError?, Never>) {
        let relay = MemoryRelay()
        let token = token
        let host = RelayHost(socket: relay.host, room: room.id, token: { token })
        let running = Task { () -> RelayError? in
            do { try await host.run() } catch { return error as? RelayError }
            return nil
        }
        return (relay, host, running)
    }

    func first(_ host: RelayHost) async -> RelayHostConnection? {
        for await connection in host.connections { return connection }
        return nil
    }

    @Test func aDeviceAndAMacTalkThroughTheRelay() async throws {
        let (relay, host, _) = serving()
        let phone = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let mac = try #require(await first(host))

        try await phone.send(Data("hello mac".utf8))
        var fromPhone = mac.messages.makeAsyncIterator()
        #expect(try await fromPhone.next() == Data("hello mac".utf8))

        try await mac.send(Data("hello phone".utf8))
        #expect(try await phone.receive() == Data("hello phone".utf8))

        // Bigger than one frame, both ways.
        let big = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try await phone.send(big)
        #expect(try await fromPhone.next() == big)
        try await mac.send(big)
        #expect(try await phone.receive() == big)
    }

    @Test func twoDevicesGetTheirOwnConnections() async throws {
        let (relay, host, _) = serving()
        var arrivals = host.connections.makeAsyncIterator()
        let phone = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let forPhone = try #require(await arrivals.next())
        let tablet = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let forTablet = try #require(await arrivals.next())
        #expect(forPhone.id != forTablet.id)

        try await forTablet.send(Data("tablet only".utf8))
        try await forPhone.send(Data("phone only".utf8))
        #expect(try await tablet.receive() == Data("tablet only".utf8))
        #expect(try await phone.receive() == Data("phone only".utf8))
    }

    @Test func aDeviceWithAnotherPairingCodeIsTurnedAwayAndTheRestCarryOn() async throws {
        let (relay, host, _) = serving()
        await #expect(throws: RelayError.wrongPairing) {
            _ = try await RelayGuest.connect(over: relay.join(), room: room.id, token: "not the token")
        }
        let phone = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let mac = try #require(await first(host))
        try await mac.send(Data("still serving".utf8))
        #expect(try await phone.receive() == Data("still serving".utf8))
    }

    @Test func aFrameChangedOnTheWayEndsThatConnectionOnly() async throws {
        let (relay, host, _) = serving()
        var arrivals = host.connections.makeAsyncIterator()
        let phone = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let forPhone = try #require(await arrivals.next())
        let tablet = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let forTablet = try #require(await arrivals.next())

        relay.tamper = { frame in
            var changed = frame
            changed[changed.count - 1] ^= 1
            return changed
        }
        try await phone.send(Data("allow".utf8))
        var fromPhone = forPhone.messages.makeAsyncIterator()
        await #expect(throws: RelayError.wrongPairing) { _ = try await fromPhone.next() }
        // The Mac closed it, and the phone hears.
        await #expect(throws: RelayError.hostGone) { _ = try await phone.receive() }

        relay.tamper = nil
        try await tablet.send(Data("fine".utf8))
        var fromTablet = forTablet.messages.makeAsyncIterator()
        #expect(try await fromTablet.next() == Data("fine".utf8))
    }

    @Test func aDeviceLeavingEndsItsMessages() async throws {
        let (relay, host, _) = serving()
        let phone = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let mac = try #require(await first(host))
        phone.close()
        var messages = mac.messages.makeAsyncIterator()
        await #expect(throws: RelayError.hostGone) { _ = try await messages.next() }
        await #expect(throws: RelayError.hostGone) { try await mac.send(Data("too late".utf8)) }
    }

    @Test func theMacClosingOneDeviceLeavesTheOther() async throws {
        let (relay, host, _) = serving()
        var arrivals = host.connections.makeAsyncIterator()
        let phone = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let forPhone = try #require(await arrivals.next())
        let tablet = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let forTablet = try #require(await arrivals.next())

        await forPhone.close()
        await #expect(throws: RelayError.hostGone) { _ = try await phone.receive() }
        try await forTablet.send(Data("you stay".utf8))
        #expect(try await tablet.receive() == Data("you stay".utf8))
    }

    @Test func whenTheRoomEndsEveryConnectionHearsWhy() async throws {
        let (relay, host, running) = serving()
        _ = try await RelayGuest.connect(over: relay.join(), room: room.id, token: token)
        let mac = try #require(await first(host))
        relay.host.end(.replaced)
        #expect(await running.value == .replaced)
        var messages = mac.messages.makeAsyncIterator()
        await #expect(throws: RelayError.replaced) { _ = try await messages.next() }
    }

    @Test func aDeviceIsToldWhenTheMacIsOffline() async {
        let socket = MemorySocket()
        socket.end(.hostOffline)
        await #expect(throws: RelayError.hostOffline) {
            _ = try await RelayGuest.connect(over: socket, room: room.id, token: token)
        }
    }
}

#if os(macOS)
/// The real relay from relay-live, started on a spare port. These run only
/// where Node and the relay's packages are installed (`npm install` in
/// relay-live), and are skipped elsewhere.
enum LiveRelay {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("relay-live")

    static let node: String? = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    static var isAvailable: Bool {
        node != nil && FileManager.default.fileExists(atPath: folder.appendingPathComponent("node_modules/ws").path)
    }

    /// Starts it and waits until it answers. The caller terminates it.
    static func start() async throws -> (process: Process, url: URL) {
        let port = Int.random(in: 20000...50000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node ?? "")
        process.arguments = ["start.js"]
        process.currentDirectoryURL = folder
        process.environment = ["PORT": "\(port)", "RELAY_MAX_GUESTS": "2"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<50 {
            if let (_, response) = try? await URLSession.shared.data(from: health), (response as? HTTPURLResponse)?.statusCode == 200 {
                return (process, URL(string: "ws://127.0.0.1:\(port)")!)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        process.terminate()
        throw RelayError.closed(0)
    }
}

@Suite(.enabled(if: LiveRelay.isAvailable), .serialized) struct LiveRelayTests {
    @Test func aWholeSessionThroughTheRealRelay() async throws {
        let (process, relay) = try await LiveRelay.start()
        defer { process.terminate() }
        let token = PairingInfo.makeToken()
        let room = RelayRoom.make()

        // Nobody home yet.
        await #expect(throws: RelayError.hostOffline) {
            _ = try await RelayGuest.connect(relay: relay, room: room.id, token: token)
        }

        let host = RelayHost(relay: relay, room: room, token: { token })
        let running = Task { () -> RelayError? in
            do { try await host.run() } catch { return error as? RelayError }
            return nil
        }
        var arrivals = host.connections.makeAsyncIterator()

        // The Mac's socket may still be connecting: try until it's in.
        var phone: RelayGuest?
        for _ in 0..<50 where phone == nil {
            phone = try? await RelayGuest.connect(relay: relay, room: room.id, token: token)
            if phone == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let guest = try #require(phone)
        let mac = try #require(await arrivals.next())

        let big = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        try await guest.send(big)
        var fromPhone = mac.messages.makeAsyncIterator()
        #expect(try await fromPhone.next() == big)
        try await mac.send(big)
        #expect(try await guest.receive() == big)

        // The wrong pairing code gets nowhere, and the session carries on.
        await #expect(throws: RelayError.wrongPairing) {
            _ = try await RelayGuest.connect(relay: relay, room: room.id, token: "wrong")
        }
        try await mac.send(Data("still here".utf8))
        #expect(try await guest.receive() == Data("still here".utf8))

        // A second Mac socket with the same key takes the room over.
        let again = RelayHost(relay: relay, room: room, token: { token })
        let second = Task { try? await again.run() }
        #expect(await running.value == .replaced)
        await #expect(throws: RelayError.hostGone) { _ = try await guest.receive() }
        again.close()
        _ = await second.value
    }

    @Test func aWrongKeyCantHostARoom() async throws {
        let (process, relay) = try await LiveRelay.start()
        defer { process.terminate() }
        let room = RelayRoom.make()
        var request = RelayRoom.make().hostRequest(relay: relay)
        request.url = room.hostRequest(relay: relay).url
        let host = RelayHost(socket: WebSocketRelaySocket(request: request), room: room.id, token: { "t" })
        await #expect(throws: RelayError.closed(4401)) { try await host.run() }
    }
}
#endif
