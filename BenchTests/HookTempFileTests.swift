import Foundation
import Testing
@testable import Bench

/// The hooks that write through a temp file and a rename, run many at
/// once the way an agent fires them when it runs tools in parallel. Each
/// hook needs a temp file of its own: with a shared name, one hook's
/// rename takes the file away from another, which fails with "No such
/// file or directory", and a hook still writing can be renamed into
/// place half done (BIR-619).
@MainActor
struct HookTempFileTests {
    /// Every command Workbench gives an agent that writes through a temp
    /// file.
    private func commands(_ agent: String) -> [String] {
        func walk(_ value: Any) -> [String] {
            if let hook = value as? [String: Any], let command = hook["command"] as? String { return [command] }
            if let dictionary = value as? [String: Any] { return dictionary.values.flatMap(walk) }
            if let array = value as? [Any] { return array.flatMap(walk) }
            return []
        }
        let all = agent == "claude" ? walk(ClaudeProvider.hooks) : CodexProvider.hooks.flatMap { $0.commands.flatMap(walk) }
        return Array(Set(all.filter { $0.contains(".tmp") })).sorted()
    }

    @Test(arguments: ["claude", "codex"])
    func hooksRunAtOnceAllSucceedAndNeverLeaveAPartFile(agent: String) throws {
        let commands = commands(agent)
        // The state, the tool finishing, and the events each saves.
        #expect(commands.count >= 6)
        for command in commands { try race(command) }
    }

    private func race(_ command: String) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bench-hook-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stateFile = folder.appendingPathComponent("tab")
        let environment = ["BENCH_STATE_FILE": stateFile.path, "PATH": "/usr/bin:/bin"]

        // Watches the folder the whole time, the way Workbench does, and
        // notes any file that isn't whole.
        let watch = FolderWatch(folder: folder)
        let watcher = Thread { watch.run() }
        watcher.start()

        // Start them all first, then let them go together: each waits on
        // its input, so closing the inputs back to back lines up the
        // writes and renames as closely as an agent's parallel tools do.
        let count = 48
        let padding = String(repeating: "x", count: 16_000)
        var running: [(process: Process, input: Pipe, errors: Pipe)] = []
        for n in 0..<count {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = environment
            let input = Pipe(), errors = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            try process.run()
            input.fileHandleForWriting.write(Data(#"{"hook_event_name":"Test","n":\#(n),"padding":"\#(padding)"}"#.utf8))
            running.append((process, input, errors))
        }
        for hook in running { try hook.input.fileHandleForWriting.close() }

        var failures: [String] = []
        for hook in running {
            hook.process.waitUntilExit()
            let said = String(decoding: hook.errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if hook.process.terminationStatus != 0 || !said.isEmpty {
                failures.append("exit \(hook.process.terminationStatus): \(said)")
            }
        }
        watch.stop()
        while !watcher.isFinished { Thread.sleep(forTimeInterval: 0.01) }

        #expect(failures.isEmpty, "\(command.prefix(120)): \(failures.count) of \(count) hooks failed, first: \(failures.first ?? "")")
        let partial = watch.partial
        #expect(partial.isEmpty, "\(command.prefix(120)): read a partial file: \(partial.prefix(3))")
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(left.filter { $0.hasSuffix(".tmp") }.isEmpty, "\(command.prefix(120)): temp files left behind: \(left)")
        #expect(!left.isEmpty, "the hook wrote nothing")
    }
}

/// Reads every finished file in a folder over and over until stopped,
/// noting any that isn't whole: a state that isn't one of the states, or
/// JSON that doesn't parse.
nonisolated private final class FolderWatch: @unchecked Sendable {
    private let folder: URL
    private let lock = NSLock()
    private var watching = true
    private var found: [String] = []

    init(folder: URL) { self.folder = folder }

    var partial: [String] { lock.withLock { found } }
    func stop() { lock.withLock { watching = false } }

    func run() {
        let states = Set(["working", "waiting", "done"])
        while lock.withLock({ watching }) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names where !name.hasSuffix(".tmp") {
                guard let data = FileManager.default.contents(atPath: folder.appendingPathComponent(name).path) else { continue }
                let whole = name == "tab"
                    ? states.contains(String(decoding: data, as: UTF8.self))
                    : (try? JSONSerialization.jsonObject(with: data)) != nil
                if !whole { lock.withLock { found.append("\(name): \(data.count) bytes") } }
            }
        }
    }
}
