import Foundation

/// Where Claude Code keeps its conversations, and what's in one.
public enum ClaudeSessionFiles {
    /// A past conversation, as a list shows it.
    public struct Summary: Sendable, Hashable {
        /// Claude's session id, which is also the file's name.
        public var id: String
        /// The name you gave it with /rename, or Claude's own short title.
        public var title: String?
        public var firstPrompt: String?
        public var lastPrompt: String?
        public var branch: String?
    }

    /// Claude Code keeps a project's transcripts in a folder named after its
    /// path, with every character that isn't a letter or digit turned into
    /// "-": `/Users/matt/Apps/Bench` is `-Users-matt-Apps-Bench`. `projects`
    /// is the account's `projects` folder.
    public static func folder(forProject path: String, projects: URL) -> URL {
        let name = String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return projects.appendingPathComponent(name, isDirectory: true)
    }

    /// What one of Claude Code's session files holds, from its first and
    /// last stretches. Nil for a session where nothing was ever sent.
    public static func summary(of file: URL, size: Int) -> Summary? {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }
        let headSize = 96 * 1024, tailSize = 384 * 1024
        let head = (try? handle.read(upToCount: headSize)) ?? Data()
        var tail = Data()
        if size > headSize {
            try? handle.seek(toOffset: UInt64(max(headSize, size - tailSize)))
            tail = (try? handle.readToEnd()) ?? Data()
        }

        var session = Summary(id: file.deletingPathExtension().lastPathComponent)
        var aiTitle: String?
        var customTitle: String?
        func scan(_ data: Data, isHead: Bool) {
            for line in data.split(separator: UInt8(ascii: "\n")) {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else {
                    // A message with a pasted image can be cut off at the
                    // edge of what was read. Its text comes first, so try that.
                    if isHead, session.firstPrompt == nil, let prompt = textInCutOffLine(Data(line)) {
                        session.firstPrompt = prompt
                    }
                    continue
                }
                switch entry["type"] as? String {
                case "ai-title": aiTitle = entry["aiTitle"] as? String ?? aiTitle
                case "custom-title": customTitle = entry["customTitle"] as? String ?? customTitle
                case "user":
                    guard let prompt = prompt(in: entry) else { continue }
                    if session.firstPrompt == nil, isHead { session.firstPrompt = prompt }
                    session.lastPrompt = prompt
                default: break
                }
                // "HEAD" is what a folder that isn't on a branch reports.
                if let branch = entry["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" { session.branch = branch }
            }
        }
        scan(head, isHead: true)
        scan(tail, isHead: false)
        // A long first message can push the first prompt past the head.
        if session.firstPrompt == nil { session.firstPrompt = session.lastPrompt }
        guard session.firstPrompt != nil else { return nil }
        session.title = customTitle ?? aiTitle
        return session
    }

    /// The first text block of a user message whose line was cut off.
    private static func textInCutOffLine(_ line: Data) -> String? {
        let start = String(decoding: line.prefix(64 * 1024), as: UTF8.self)
        guard start.contains(#""type":"user""#),
              let match = start.firstMatch(of: /"type":"text","text":("(?:[^"\\]|\\.)*")/),
              let text = try? JSONSerialization.jsonObject(with: Data(match.1.utf8), options: .fragmentsAllowed) as? String
        else { return nil }
        return prompt(in: ["message": ["content": text]])
    }

    /// Text you typed, skipping tool results, slash command output and
    /// Claude Code's own notes.
    private static func prompt(in entry: [String: Any]) -> String? {
        guard entry["isMeta"] as? Bool != true, entry["isCompactSummary"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            guard !blocks.contains(where: { $0["type"] as? String == "tool_result" }) else { return nil }
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
        } else {
            return nil
        }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("<"), !line.hasPrefix("Caveat:"), !line.hasPrefix("[Request interrupted"),
              !TranscriptParser.isFromTeammate(line) else { return nil }
        return line.count > 300 ? String(line.prefix(299)) + "…" : line
    }
}
