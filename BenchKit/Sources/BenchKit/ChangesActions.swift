import Foundation

/// The git steps the Changes panel offers: Commit, Push and Open PR. Each
/// is a message to the project's agent, which does the git work itself, so
/// they work the same whichever host the repo lives on. The Mac's buttons
/// start from these words (and can be reworded there); the phone sends
/// them as they are.
public enum ChangesAction: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
    case commit, push, pullRequest

    public var id: String { rawValue }

    /// The button's label.
    public var name: String {
        switch self {
        case .commit: "Commit"
        case .push: "Push"
        case .pullRequest: "Open PR"
        }
    }

    /// An SF Symbol for the button.
    public var symbol: String {
        switch self {
        case .commit: "checkmark.circle"
        case .push: "arrow.up.circle"
        case .pullRequest: "arrow.triangle.pull"
        }
    }

    /// What's sent to the agent. `{branch}` and `{base}` are filled in by
    /// `filledPrompt`.
    public var prompt: String {
        switch self {
        case .commit:
            """
            Commit the current changes on {branch}. Look over what's staged and unstaged, stage what belongs \
            together, and leave out anything that looks accidental (secrets, scratch files) and tell me about it. \
            Write the message in this repo's style, going by recent commits. Don't push.
            """
        case .push:
            """
            Push {branch} to its remote, setting the upstream if it doesn't have one yet. If the push is rejected \
            because the remote has commits this branch doesn't, stop and tell me instead of forcing.
            """
        case .pullRequest:
            """
            Open a pull request for {branch} against {base}. Commit anything uncommitted first and push the branch. \
            Use whatever this repo's host uses: gh for GitHub, glab for GitLab, or the host's web URL if there's no \
            CLI. Write a title and description that say what changed and why, in this repo's style (check the PR \
            template or recent PRs if there are any). When it's up, tell me the URL.
            """
        }
    }

    /// The prompt with the branch names put in. Without a branch (a
    /// detached checkout) or a base, the words say so instead.
    public func filledPrompt(branch: String?, base: String?) -> String {
        prompt
            .replacingOccurrences(of: "{branch}", with: branch ?? "the current branch")
            .replacingOccurrences(of: "{base}", with: base ?? "the default branch")
    }

    /// The prompt for a project as its Changes panel stands.
    public func filledPrompt(for snapshot: ChangesSnapshot) -> String {
        filledPrompt(branch: snapshot.branch, base: snapshot.shortBase)
    }

    /// Whether there's anything for it to do: Commit needs changes, Push
    /// needs commits the remote doesn't have, and Open PR needs a branch
    /// of its own with no pull request yet.
    public func isAvailable(in snapshot: ChangesSnapshot, pullRequest: CompanionPullRequest?) -> Bool {
        guard snapshot.isRepository else { return false }
        switch self {
        case .commit:
            return !(snapshot.staged.isEmpty && snapshot.unstaged.isEmpty)
        case .push:
            guard snapshot.branch != nil else { return false }
            // No upstream yet: worth pushing once the branch has commits.
            // (An older Mac doesn't say, and looks the same.)
            guard snapshot.upstream != nil else { return !snapshot.commits.isEmpty || (snapshot.aheadOfBase ?? 0) > 0 }
            return (snapshot.unpushed ?? 1) > 0
        case .pullRequest:
            guard pullRequest == nil, let branch = snapshot.branch, branch != snapshot.shortBase else { return false }
            return !snapshot.commits.isEmpty || !(snapshot.staged.isEmpty && snapshot.unstaged.isEmpty)
        }
    }

    /// The steps that can be taken now, in the order they'd be taken.
    public static func available(in snapshot: ChangesSnapshot, pullRequest: CompanionPullRequest?) -> [ChangesAction] {
        allCases.filter { $0.isAvailable(in: snapshot, pullRequest: pullRequest) }
    }

    /// The action a message came from, for the demo to act it out.
    public static func matching(prompt text: String) -> ChangesAction? {
        allCases.first { action in
            guard let opening = action.prompt.components(separatedBy: "{").first, !opening.isEmpty else { return false }
            return text.hasPrefix(opening)
        }
    }
}

extension ChangesSnapshot {
    /// The base without its remote: "main" for "origin/main".
    public var shortBase: String? {
        guard let base = baseRef else { return nil }
        for remote in [remoteName, "origin"].compactMap({ $0 }) where base.hasPrefix(remote + "/") {
            return String(base.dropFirst(remote.count + 1))
        }
        return base
    }
}

/// One Commit, Push or Open PR sent from a device that can only watch:
/// what it was waiting for, and how it came out. The agent does the work
/// in its own time, so the outcome is read off what the Mac reports next:
/// the repo's state, the pull request, and whether the agent is still at it.
public struct ChangesActionRun: Sendable, Hashable {
    public enum Phase: Sendable, Hashable {
        /// Sent, and the agent is on it (or about to be).
        case running
        /// The agent stopped to ask something, like a permission.
        case needsYou
        case succeeded(Outcome)
        /// Why it didn't happen, in words to show.
        case failed(String)
    }

    public enum Outcome: Sendable, Hashable {
        /// The new commit's subject, when the Mac lists it.
        case committed(subject: String?)
        /// The remote branch it went to, like "origin/feat/x".
        case pushed(upstream: String?)
        /// The pull request. The number and title are nil when all there
        /// is to go on is the link the agent gave.
        case pullRequest(number: Int?, title: String?, url: URL)
        /// The agent finished, and the Mac is too old to say whether it
        /// worked. Its last words, to show instead.
        case finished(summary: String?)
    }

    /// The repo as it stood when the action was sent.
    struct Baseline: Sendable, Hashable {
        var head: String?
        var uncommitted: Int
        var upstream: String?
        var unpushed: Int?
        var pullRequest: Int?
    }

    public let action: ChangesAction
    /// The session it was sent to. Nil while a new tab for it is opening.
    public private(set) var sessionID: UUID?
    public let startedAt: Date
    public private(set) var phase: Phase = .running
    /// When the agent was first seen stopped without the result showing
    /// yet. The Mac's next read of the repo usually settles it.
    public private(set) var stoppedAt: Date?

    let baseline: Baseline
    /// The project's sessions when it was sent, to spot the new tab.
    let knownSessions: Set<UUID>
    var sawWorking = false

    /// How long after the agent stops to keep looking for the result: the
    /// Mac reads a watched repo every few seconds, and checks for a pull
    /// request once a minute.
    static func settleTime(for action: ChangesAction) -> TimeInterval {
        action == .pullRequest ? 75 : 10
    }
    /// How long a message can sit before the agent is seen to pick it up.
    static let startTime: TimeInterval = 20

    public init(action: ChangesAction, sessionID: UUID?, project: CompanionProject?, changes: ChangesSnapshot?, now: Date = .now) {
        self.action = action
        self.sessionID = sessionID
        startedAt = now
        knownSessions = Set(project?.sessions.map(\.id) ?? [])
        baseline = Baseline(head: changes?.commits.first?.hash,
                            uncommitted: (changes?.staged.count ?? 0) + (changes?.unstaged.count ?? 0),
                            upstream: changes?.upstream, unpushed: changes?.unpushed,
                            pullRequest: project?.pullRequest?.number)
    }

    /// A run that couldn't be sent at all.
    public init(action: ChangesAction, problem: String, now: Date = .now) {
        self.init(action: action, sessionID: nil, project: nil, changes: nil, now: now)
        phase = .failed(problem)
    }

    /// True once it has come out one way or the other.
    public var isOver: Bool {
        switch phase {
        case .running, .needsYou: false
        case .succeeded, .failed: true
        }
    }

    /// True while the agent has stopped and the result hasn't shown yet.
    public var isSettling: Bool { phase == .running && stoppedAt != nil }

    /// When to look again if nothing arrives from the Mac first, or nil
    /// when it's over.
    public var nextCheck: Date? {
        guard !isOver else { return nil }
        if let stoppedAt { return stoppedAt.addingTimeInterval(Self.settleTime(for: action) + 0.5) }
        return sawWorking ? nil : startedAt.addingTimeInterval(Self.startTime + 0.5)
    }

    /// Reads the latest from the Mac. `sendProblem` is why the message
    /// didn't reach the session, and `startProblem` why a new tab didn't
    /// open, when the Mac said so.
    public mutating func update(project: CompanionProject?, changes: ChangesSnapshot?,
                                sendProblem: String? = nil, startProblem: String? = nil, now: Date = .now) {
        guard !isOver else { return }
        if let outcome = outcome(project: project, changes: changes) {
            phase = .succeeded(outcome)
            return
        }
        guard let project else { return }
        if sessionID == nil {
            sessionID = project.sessions.last { !knownSessions.contains($0.id) }?.id
        }
        guard let sessionID else {
            if let startProblem {
                phase = .failed(startProblem)
            } else if now.timeIntervalSince(startedAt) > Self.startTime {
                phase = .failed("Workbench didn't open a tab for it on your Mac.")
            }
            return
        }
        if let sendProblem {
            phase = .failed(sendProblem)
            return
        }
        guard let session = project.sessions.first(where: { $0.id == sessionID }) else {
            phase = .failed("The tab was closed before it finished.")
            return
        }
        switch session.activity {
        case .working, .remoteWorking:
            sawWorking = true
            stoppedAt = nil
            phase = .running
        case .waiting, .attention:
            sawWorking = true
            stoppedAt = nil
            phase = .needsYou
        case .done, .idle:
            // Not picked up yet: the Mac's list can be a beat behind.
            guard sawWorking || now.timeIntervalSince(startedAt) > Self.startTime else { return }
            phase = .running
            let stopped = stoppedAt ?? now
            stoppedAt = stopped
            // The agent says the link before the Mac finds the pull request.
            if action == .pullRequest, let url = Self.pullRequestURL(in: session.summary) ?? Self.pullRequestURL(in: session.note) {
                phase = .succeeded(.pullRequest(number: Self.number(in: url), title: nil, url: url))
            } else if now.timeIntervalSince(stopped) >= Self.settleTime(for: action) {
                phase = canTell(changes) ? .failed(Self.stoppedShort(action, name: session.agentName ?? "Claude", summary: session.summary))
                                         : .succeeded(.finished(summary: Self.firstLine(session.summary)))
            }
        }
    }

    /// The result, once the Mac's numbers show it.
    private func outcome(project: CompanionProject?, changes: ChangesSnapshot?) -> Outcome? {
        switch action {
        case .commit:
            guard let changes else { return nil }
            let newest = changes.commits.first
            if let newest, newest.hash != baseline.head {
                return .committed(subject: newest.subject)
            }
            // The commit isn't listed when the branch is its own base.
            let uncommitted = changes.staged.count + changes.unstaged.count
            if uncommitted < baseline.uncommitted, let before = baseline.unpushed, let unpushed = changes.unpushed, unpushed > before {
                return .committed(subject: nil)
            }
            return uncommitted == 0 && baseline.uncommitted > 0 && sawWorking ? .committed(subject: nil) : nil
        case .push:
            guard let changes, let upstream = changes.upstream, changes.unpushed == 0 else { return nil }
            return baseline.upstream == nil || (baseline.unpushed ?? 1) > 0 ? .pushed(upstream: upstream) : nil
        case .pullRequest:
            guard let pr = project?.pullRequest, pr.number != baseline.pullRequest, pr.state == .open || pr.state == .draft else { return nil }
            return .pullRequest(number: pr.number, title: pr.title, url: pr.url)
        }
    }

    /// Whether the Mac reports enough to know the action didn't happen.
    private func canTell(_ changes: ChangesSnapshot?) -> Bool {
        switch action {
        case .commit, .pullRequest: true
        // Older Macs don't say what's unpushed.
        case .push: changes?.branches != nil
        }
    }

    /// "Claude stopped without pushing.", then what it said.
    static func stoppedShort(_ action: ChangesAction, name: String, summary: String?) -> String {
        let what = switch action {
        case .commit: "committing"
        case .push: "pushing"
        case .pullRequest: "opening a pull request"
        }
        let lead = "\(name) stopped without \(what)."
        guard let said = firstLine(summary) else { return lead }
        return "\(lead) It said: \(said)"
    }

    static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// A pull or merge request's link in what the agent said.
    static func pullRequestURL(in text: String?) -> URL? {
        guard let text else { return nil }
        for word in text.split(whereSeparator: { $0.isWhitespace || "()[]<>\"'`".contains($0) }) {
            let link = word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?*"))
            guard link.hasPrefix("https://"), link.contains("/pull/") || link.contains("/merge_requests/") || link.contains("/pull-requests/"),
                  let url = URL(string: link) else { continue }
            return url
        }
        return nil
    }

    /// The number a pull request's link ends in.
    static func number(in url: URL) -> Int? {
        url.pathComponents.reversed().lazy.compactMap { Int($0) }.first
    }
}
