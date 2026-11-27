import BenchKit
import Dispatch
import Foundation

/// The whole host, put together: its store, its sessions, the server and
/// what devices connect through.
public final class WorkbenchHost {
    public static let version = "0.1.0"
    public static let defaultPort = 48810

    public let paths: HostPaths
    public let store: HostStore
    public let sessions: HostSessions
    public let server: HostServer
    private var listener: WebSocketListener?
    private var relay: RelayLink?
    private var pairingRead = Date.distantPast
    private var pairingTimer: DispatchSourceTimer?

    public init(paths: HostPaths = .standard) throws {
        self.paths = paths
        try paths.prepare()
        store = HostStore(file: paths.store)
        sessions = HostSessions(paths: paths, store: store)
        server = HostServer(store: store, sessions: sessions, pairing: HostPairing.load(paths.pairing),
                            name: Self.machineName, version: Self.version)
    }

    /// This machine's name, as the sidebar shows it.
    public static var machineName: String {
        let name = ProcessInfo.processInfo.hostName
        // "box.local" and "box.example.com" both read better as "box".
        return name.split(separator: ".").first.map(String.init) ?? name
    }

    /// Picks the sessions back up and starts answering devices.
    public func run(bind: String, port: Int) throws {
        let listener = WebSocketListener(server: server)
        try listener.start(host: bind, port: port)
        self.listener = listener
        sessions.resumeAll()
        server.start()
        startRelay()
        // `workbench-host pair` may turn the relay on while this runs.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.rereadPairing() }
        timer.resume()
        pairingTimer = timer
        hostLog("Workbench host \(Self.version) listening on \(bind):\(port), \(store.projects.count) project(s)")
    }

    private var pairingModified: Date {
        (try? paths.pairing.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private func startRelay() {
        pairingRead = pairingModified
        relay?.stop()
        relay = nil
        guard let endpoint = server.pairing.relayEndpoint, let url = endpoint.relayURL, let room = server.pairing.relayRoom else { return }
        let link = RelayLink(server: server)
        link.start(endpoint: url, room: room, token: server.pairing.token)
        relay = link
    }

    private func rereadPairing() {
        guard pairingModified != pairingRead else { return }
        let fresh = HostPairing.load(paths.pairing)
        let changed = fresh.relayKey != server.pairing.relayKey || fresh.relayAddress != server.pairing.relayAddress
            || fresh.token != server.pairing.token
        server.pairing = fresh
        if changed { startRelay() } else { pairingRead = pairingModified }
    }

    /// Ends the sessions, leaving them to be resumed by the next run.
    public func stop() {
        sessions.shutDown()
        relay?.stop()
        listener?.stop()
    }
}
