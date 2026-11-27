import Foundation

/// Where the host keeps what it knows: its projects, its pairing code and
/// what each session's hooks report.
public struct HostPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `WORKBENCH_HOST_HOME` when set, for tests and second copies.
    /// Otherwise the usual place for a program's own data.
    public static var standard: HostPaths {
        let environment = ProcessInfo.processInfo.environment
        if let custom = environment["WORKBENCH_HOST_HOME"], !custom.isEmpty {
            return HostPaths(root: URL(fileURLWithPath: custom, isDirectory: true))
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #if os(macOS)
        return HostPaths(root: home.appendingPathComponent("Library/Application Support/WorkbenchHost", isDirectory: true))
        #else
        let data = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
            ?? home.appendingPathComponent(".local/share", isDirectory: true)
        return HostPaths(root: data.appendingPathComponent("workbench-host", isDirectory: true))
        #endif
    }

    /// Projects and their open sessions.
    public var store: URL { root.appendingPathComponent("state.json") }
    /// The pairing code and relay room.
    public var pairing: URL { root.appendingPathComponent("pairing.json") }
    /// The phones that asked for notifications.
    public var pushDevices: URL { root.appendingPathComponent("push-devices.json") }
    /// One word per session ("working", "waiting", "done") and the JSON of
    /// its latest events. Named as on the Mac, where the same hooks write.
    public var stateFolder: URL { root.appendingPathComponent("claude-state", isDirectory: true) }
    /// Which Claude session each tab is running, to pick it back up.
    public var sessionsFolder: URL { root.appendingPathComponent("claude-sessions", isDirectory: true) }
    /// The settings file Claude Code is started with: Workbench's hooks.
    public var hooksFile: URL { root.appendingPathComponent("claude-hooks.json") }
    /// Pictures sent along with a message, until Claude has read them.
    public var attachments: URL { root.appendingPathComponent("attachments", isDirectory: true) }
    public var log: URL { root.appendingPathComponent("host.log") }

    public func stateFile(_ tab: UUID) -> URL { stateFolder.appendingPathComponent(tab.uuidString) }
    public func sessionFile(_ tab: UUID) -> URL { sessionsFolder.appendingPathComponent("\(tab.uuidString).json") }

    public func prepare() throws {
        for folder in [root, stateFolder, sessionsFolder, attachments] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        // Pairing codes and prompts live here: nobody else's business.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}

func hostLog(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
}
