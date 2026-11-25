import Foundation

/// Follows another Mac's sessions and says when one starts waiting on you,
/// so this Mac can notify about it the way it does for its own tabs.
public struct RemoteAttention: Sendable {
    /// A session that has just started waiting.
    public struct Alert: Hashable, Sendable {
        public var projectID: UUID
        public var sessionID: UUID
        public var project: String
        public var agent: String
        public var question: String?
    }

    /// The sessions waiting as of the last snapshot. Nil until the first
    /// one arrives.
    private var waiting: Set<UUID>?

    public init() {}

    /// Takes the other Mac's latest list. Returns the sessions that began
    /// waiting since the one before, and the ones that stopped. A session
    /// already waiting in the first list isn't news: it was waiting before
    /// this Mac started looking.
    public mutating func update(_ snapshot: ProjectsSnapshot) -> (started: [Alert], ended: Set<UUID>) {
        var now: Set<UUID> = []
        var started: [Alert] = []
        for project in snapshot.projects {
            for session in project.sessions where session.activity == .waiting {
                now.insert(session.id)
                if let waiting, !waiting.contains(session.id) {
                    started.append(Alert(projectID: project.id, sessionID: session.id, project: project.name,
                                         agent: session.agentTitle, question: session.question))
                }
            }
        }
        let ended = (waiting ?? []).subtracting(now)
        waiting = now
        return (started, ended)
    }
}
