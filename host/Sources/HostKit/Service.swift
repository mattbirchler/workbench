import Foundation

/// Keeps the host running in the background with systemd, started at boot
/// and restarted if it stops. Runs as you, not as root.
public enum Service {
    static let name = "workbench-host.service"

    static var unitFile: URL {
        let config = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return config.appendingPathComponent("systemd/user/\(name)")
    }

    /// The full path of the program that is running.
    public static var programPath: String {
        if let path = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") { return path }
        let given = CommandLine.arguments[0]
        return given.hasPrefix("/") ? given : FileManager.default.currentDirectoryPath + "/" + given
    }

    static func unit(program: String, port: Int) -> String {
        """
        [Unit]
        Description=Workbench host
        After=network-online.target
        Wants=network-online.target

        [Service]
        ExecStart="\(program)" serve --port \(port)
        Restart=always
        RestartSec=3
        # Leave the sessions' own children alone when stopping: the host
        # ends its sessions itself so they can be picked up again.
        KillMode=mixed
        TimeoutStopSec=15

        [Install]
        WantedBy=default.target

        """
    }

    public static var hasSystemd: Bool {
        guard let result = Reach.run("systemctl", ["--user", "show-environment"], timeout: 5) else { return false }
        return result.status == 0
    }

    /// Writes the unit and starts it. Returns what to tell the person.
    public static func install(port: Int) throws -> [String] {
        guard hasSystemd else {
            return [
                "This machine has no systemd for your user, so there is nothing to keep the host running for you.",
                "Start it yourself and leave it running:  nohup workbench-host serve >/dev/null 2>&1 &",
            ]
        }
        let file = unitFile
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try unit(program: programPath, port: port).write(to: file, atomically: true, encoding: .utf8)
        _ = Reach.run("systemctl", ["--user", "daemon-reload"])
        guard let started = Reach.run("systemctl", ["--user", "enable", "--now", name], timeout: 30), started.status == 0 else {
            return ["Wrote \(file.path), but systemd wouldn't start it. Look at:  journalctl --user -u workbench-host"]
        }
        // A restart picks up a new version of the program.
        _ = Reach.run("systemctl", ["--user", "restart", name], timeout: 30)
        var lines = ["The host is running in the background and starts when this machine does."]
        // Without lingering, systemd stops your services when you log out.
        let user = NSUserName()
        if let linger = Reach.run("loginctl", ["enable-linger", user], timeout: 10), linger.status == 0 {
        } else {
            lines.append("To keep it running after you log out, run once:  sudo loginctl enable-linger \(user)")
        }
        return lines
    }

    public static func uninstall() -> [String] {
        _ = Reach.run("systemctl", ["--user", "disable", "--now", name], timeout: 30)
        try? FileManager.default.removeItem(at: unitFile)
        _ = Reach.run("systemctl", ["--user", "daemon-reload"])
        return ["The host no longer runs in the background."]
    }

    /// "active", "inactive", "failed", or nil when systemd doesn't know it.
    public static var state: String? {
        guard FileManager.default.fileExists(atPath: unitFile.path),
              let result = Reach.run("systemctl", ["--user", "is-active", name], timeout: 5) else { return nil }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
