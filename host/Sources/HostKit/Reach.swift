import BenchKit
import Foundation

/// How devices get to this host: Tailscale when the machine is on a
/// tailnet, the Workbench relay when you ask for it.
public enum Reach {
    /// Runs a program and returns what it printed, or nil if it isn't
    /// there or failed.
    public static func run(_ program: String, _ arguments: [String], timeout: TimeInterval = 15) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [program] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        DispatchQueue.global().async {
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// This machine's name on its tailnet, like "box.tail1234.ts.net", or
    /// nil when Tailscale isn't installed, running or signed in.
    public static func tailnetName() -> String? {
        guard let result = run("tailscale", ["status", "--json"]), result.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any],
              json["BackendState"] as? String == "Running",
              let me = json["Self"] as? [String: Any], let name = me["DNSName"] as? String else { return nil }
        let trimmed = name.hasSuffix(".") ? String(name.dropLast()) : name
        return trimmed.isEmpty ? nil : trimmed
    }

    public enum ServeResult: Equatable {
        case ready
        /// Tailscale wouldn't take it, with what it said.
        case failed(String)
    }

    /// Has Tailscale Serve put the host's port on the tailnet over HTTPS,
    /// which is where the apps look: `wss://<name>/ws`.
    public static func serve(port: Int, name: String) -> ServeResult {
        let proxy = "http://127.0.0.1:\(port)"
        if let status = run("tailscale", ["serve", "status", "--json"]), status.status == 0 {
            let config = TailscaleServeConfig(statusJSON: Data(status.output.utf8))
            if config.entries.contains(where: { $0.host == name && $0.proxy == proxy && ($0.path == "/" || $0.path == "/ws") }) {
                return .ready
            }
        }
        guard let result = run("tailscale", ["serve", "--bg", "--https=443", "--set-path=/ws", proxy], timeout: 30) else {
            return .failed("Couldn't run tailscale.")
        }
        return result.status == 0 ? .ready : .failed(result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
