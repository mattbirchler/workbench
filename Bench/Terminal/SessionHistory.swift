import BenchKit
import Foundation

/// A conversation from a project's past, read from the session files its
/// agent keeps (`AgentTranscripts`).
nonisolated struct PastSession: Identifiable, Hashable, Sendable {
    /// Claude's session id, which is also the transcript's file name.
    var id: String
    /// The name you gave it with /rename, or Claude's own short title.
    var title: String?
    var firstPrompt: String?
    var lastPrompt: String?
    var branch: String?
    var modified: Date
    /// The Claude account whose folder it's in.
    var accountID = ClaudeProfile.mainID
    /// The agent whose session it is.
    var agent = AgentID.claude
}

/// Finds and reads a project's past sessions.
nonisolated enum SessionHistory {
    /// Every session file of a project: from each agent, under each account.
    static func files(forProject path: String) -> [(account: ClaudeProfile, reader: any AgentTranscripts, file: URL)] {
        Agents.allTranscripts.flatMap { reader in
            ClaudeAccounts.all.flatMap { account in
                reader.sessionFiles(forProject: path, account: account).map { (account, reader, $0) }
            }
        }
    }

    /// Where one of a project's sessions is kept, and under which account.
    private static func file(ofSession id: String, projectPath: String) -> (account: ClaudeProfile, file: URL, agent: AgentID)? {
        for reader in Agents.allTranscripts {
            for account in ClaudeAccounts.all {
                if let file = reader.sessionFile(id, forProject: projectPath, account: account) { return (account, file, reader.agent) }
            }
        }
        return nil
    }

    /// The agent a past session was with: whichever has its file.
    static func agent(ofSession id: String, projectPath: String) -> AgentID? {
        file(ofSession: id, projectPath: projectPath)?.agent
    }

    /// The account a past session ran under: whichever has its transcript.
    static func account(ofSession id: String, projectPath: String) -> UUID? {
        file(ofSession: id, projectPath: projectPath)?.account.id
    }

    /// The Codex account a past Codex session ran under: whichever folder
    /// holds its file.
    static func codexAccount(ofSession id: String, projectPath: String) -> UUID? {
        guard let found = file(ofSession: id, projectPath: projectPath), found.agent == .codex else { return nil }
        return CodexAccounts.profile(forSession: found.file.path)?.id
    }

    /// The project's sessions from every account, newest first. Ones where
    /// nothing was ever asked are left out.
    static func load(projectPath: String) async -> [PastSession] {
        await Task.detached(priority: .userInitiated) {
            var sessions: [PastSession] = []
            for (account, reader, file) in files(forProject: projectPath) {
                let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let modified = values?.contentModificationDate ?? .distantPast
                if var session = cache.session(for: file, modified: modified, size: values?.fileSize ?? 0, reader: reader) {
                    session.accountID = account.id
                    session.agent = reader.agent
                    sessions.append(session)
                }
            }
            return sessions.sorted { $0.modified > $1.modified }
        }.value
    }

    /// A past session's title, shortened for a tab. Cheap: the cache
    /// already has it after a `load`.
    static func title(of sessionID: String, projectPath: String) -> String? {
        guard let file = file(ofSession: sessionID, projectPath: projectPath)?.file else { return nil }
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        guard let title = cache.session(for: file, modified: values?.contentModificationDate ?? .distantPast, size: values?.fileSize ?? 0,
                                        reader: Agents.transcripts(for: file.path))?.title else { return nil }
        return title.count > 24 ? String(title.prefix(23)) + "…" : title
    }

    /// Reads each transcript once per change. Only its start and end are
    /// read, since transcripts can run to many megabytes.
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (modified: Date, size: Int, session: PastSession?)] = [:]

        func session(for file: URL, modified: Date, size: Int, reader: any AgentTranscripts) -> PastSession? {
            lock.lock()
            if let entry = entries[file.path], entry.modified == modified, entry.size == size {
                lock.unlock()
                return entry.session
            }
            lock.unlock()
            let session = reader.pastSession(in: file, modified: modified, size: size)
            lock.lock()
            entries[file.path] = (modified, size, session)
            lock.unlock()
            return session
        }
    }

    private static let cache = Cache()

    /// One of Claude Code's transcripts, as a past session.
    static func readClaude(_ file: URL, modified: Date, size: Int) -> PastSession? {
        guard let found = ClaudeSessionFiles.summary(of: file, size: size) else { return nil }
        var session = PastSession(id: found.id, modified: modified)
        session.title = found.title
        session.firstPrompt = found.firstPrompt
        session.lastPrompt = found.lastPrompt
        session.branch = found.branch
        return session
    }
}
