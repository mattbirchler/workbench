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
        hostLog("Workbench host \(Self.version) listening on \(bind):\(port), \(store.projects.count) project(s)")
    }

    /// Ends the sessions, leaving them to be resumed by the next run.
    public func stop() {
        sessions.shutDown()
        listener?.stop()
    }
}
