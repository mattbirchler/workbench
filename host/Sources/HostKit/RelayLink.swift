import BenchKit
import Dispatch
import Foundation

/// Keeps this host's room open on the Workbench relay, so devices can
/// reach it with no Tailscale and no open port. What passes through is
/// sealed with keys from the pairing code, which the relay never sees.
public final class RelayLink: @unchecked Sendable {
    public static let defaultAddress = "wss://relay-production-7c2aaa99.up.railway.app"

    private weak var server: HostServer?
    private var running: Task<Void, Never>?

    public init(server: HostServer) {
        self.server = server
    }

    /// Opens the room and keeps it open, reconnecting when the line drops.
    public func start(endpoint: URL, room: RelayRoom, token: String) {
        stop()
        running = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                let host = RelayHost(relay: endpoint, room: room, token: { token })
                let arrivals = Task { [weak self] in
                    for await connection in host.connections { self?.accept(connection) }
                }
                let started = Date()
                do {
                    try await host.run()
                } catch {
                    if Task.isCancelled { break }
                    // One that stayed up a while was working: start the
                    // wait over.
                    if Date().timeIntervalSince(started) > 30 { failures = 0 }
                    failures += 1
                    switch error as? RelayError {
                    case .replaced:
                        hostLog("relay: another copy of this host took over its room. Not reconnecting.")
                        arrivals.cancel()
                        return
                    case .overLimit:
                        hostLog("relay: over today's allowance. Trying again in an hour.")
                        failures = max(failures, 12)
                    default:
                        if failures == 1 || failures % 10 == 0 { hostLog("relay: connection lost (\(error)). Reconnecting.") }
                    }
                }
                arrivals.cancel()
                let wait = failures >= 12 ? 3600.0 : min(60.0, pow(2.0, Double(min(failures, 6))))
                try? await Task.sleep(for: .seconds(wait))
            }
        }
        hostLog("relay: hosting a room on \(endpoint.host() ?? "the relay")")
    }

    public func stop() {
        running?.cancel()
        running = nil
    }

    /// A device finished the relay's handshake. Its hello is still checked
    /// like anyone's.
    private func accept(_ connection: RelayHostConnection) {
        // One task sends everything, so messages keep their order.
        let (outgoing, sender) = AsyncStream<Data>.makeStream()
        let pump = Task {
            for await data in outgoing { try? await connection.send(data) }
        }
        let client = HostClient(
            send: { sender.yield($0) },
            close: {
                sender.finish()
                Task { await connection.close() }
            })
        let server = server
        DispatchQueue.main.async { server?.connected(client) }
        Task {
            do {
                for try await data in connection.messages {
                    DispatchQueue.main.async { server?.received(data, from: client) }
                }
            } catch {}
            sender.finish()
            pump.cancel()
            DispatchQueue.main.async { server?.disconnected(client) }
        }
    }
}
