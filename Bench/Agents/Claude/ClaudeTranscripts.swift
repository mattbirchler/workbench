import BenchKit
import Foundation

/// Claude Code's session files: one `.jsonl` per session, in a folder per
/// project under the account's `projects` folder.
nonisolated struct ClaudeTranscripts: AgentTranscripts {
    var agent: AgentID { .claude }
    var format: any TranscriptFormat { ClaudeTranscriptFormat() }

    func owns(_ path: String) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        return ClaudeAccounts.all.contains { file.hasPrefix($0.projectsURL.standardizedFileURL.path + "/") }
    }

    // MARK: One session

    func lastMessage(in path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // The last 256 KB is plenty to reach the final message.
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 262_144 ? end - 262_144 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  entry["type"] as? String == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n\n")
            if !text.isEmpty { return text }
        }
        return nil
    }

    func recapTurn(in path: String) -> RecapTurn? { Recaps.claudeTurn(transcript: path) }

    func queuedMessages(in path: String) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 2_000_000 ? end - 2_000_000 : 0)
        guard let data = try? handle.readToEnd() else { return [] }
        var queue: [String] = []
        let options = TranscriptParser.Options(keepsQueue: true)
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Cheap check before parsing: only queue changes matter here.
            guard line.range(of: Data("queue-operation".utf8)) != nil else { continue }
            for message in format.messages(in: Data(line), options: options) {
                switch message.queue {
                case .added: queue.append(message.text)
                case .left: if let index = queue.firstIndex(of: message.text) { queue.remove(at: index) } else if !queue.isEmpty { queue.removeFirst() }
                case .cleared: queue.removeAll()
                case nil: break
                }
            }
        }
        return queue
    }

    /// The newest user or assistant entry in the last stretch of the file.
    func lastActivity(in file: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 512_000 ? end - 512_000 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for line in data.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant",
                  let stamp = entry["timestamp"] as? String,
                  let date = formatter.date(from: stamp) else { continue }
            return date
        }
        return nil
    }

    func read(lines: Data, into stats: inout SessionStats) { ClaudeSessionStats.read(lines: lines, into: &stats) }

    func makeSubagentReader() -> (any SubagentReading)? { AgentReader() }

    // MARK: Past sessions

    /// Claude Code keeps a project's transcripts in a folder named after its
    /// path, with every character that isn't a letter or digit turned into
    /// "-": `/Users/matt/Apps/Bench` is `-Users-matt-Apps-Bench`. Each
    /// Claude account has its own.
    static func folder(forProject path: String, account: ClaudeProfile) -> URL {
        ClaudeSessionFiles.folder(forProject: path, projects: account.projectsURL)
    }

    func sessionFiles(forProject path: String, account: ClaudeProfile) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.folder(forProject: path, account: account),
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }
    }

    func sessionFile(_ id: String, forProject path: String, account: ClaudeProfile) -> URL? {
        let file = Self.folder(forProject: path, account: account).appendingPathComponent("\(id).jsonl")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func pastSession(in file: URL, modified: Date, size: Int) -> PastSession? {
        SessionHistory.readClaude(file, modified: modified, size: size)
    }

    func recentFolders() -> [String: Date] {
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [:] }
        var newest: [String: Date] = [:]
        for folder in folders {
            let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let transcripts = files.filter { $0.pathExtension == "jsonl" }
                .compactMap { url in
                    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) }
                }
                .sorted { $0.1 > $1.1 }
            // The newest transcript that says where it ran.
            for (file, date) in transcripts.prefix(3) {
                guard let path = Self.workingDirectory(in: file) else { continue }
                if date > (newest[path] ?? .distantPast) { newest[path] = date }
                break
            }
        }
        // Not Claude Code's own folders.
        return newest.filter { !$0.key.contains("/.claude/") }
    }

    /// The "cwd" from the first lines of a transcript.
    private static func workingDirectory(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        for line in data.split(separator: UInt8(ascii: "\n")).prefix(60) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = object["cwd"] as? String, !cwd.isEmpty else { continue }
            return URL(fileURLWithPath: cwd).standardizedFileURL.path
        }
        return nil
    }

    // MARK: Spend

    func allSessionFiles(account: ClaudeProfile) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: account.projectsURL,
                                                          includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" { files.append(url) }
        return files
    }

    func ledgerEntries(in file: URL) -> [UsageLedger.Entry] { UsageLedger.readClaude(file) }
}
