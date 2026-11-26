import BenchKit
import Foundation
import Observation
import UserNotifications

/// Looks into feedback on its own. When it's on, Workbench checks the
/// relay's feedback queue once a day and starts an agent for each new
/// message, in its own worktree of the chosen project, with the message
/// and screenshots saved there for it to read. Meant for the developer's
/// own Mac, so it's hidden until `availableKey` is set.
///
/// The feedback comes from strangers, so the agent's prompt treats it as
/// a report, not instructions, and Claude keeps asking before anything
/// risky. No more than `dailyLimit` agents start in a day. The rest wait
/// on the relay.
@Observable
final class FeedbackAgent {
    /// Shows the settings. `defaults write me.birchtree.Bench feedbackAgentAvailable -bool YES`
    static let availableKey = "feedbackAgentAvailable"
    private static let enabledKey = "feedbackAgentEnabled"
    private static let projectKey = "feedbackAgentProjectID"
    private static let secretKey = "feedbackAgentSecret"
    private static let startsKey = "feedbackAgentStarts"
    private static let worktreesKey = "feedbackAgentWorktrees"
    private static let lastCheckKey = "feedbackAgentLastCheck"

    static let dailyLimit = 5
    static var queueURL: URL {
        #if DEBUG
        // For testing against a stand-in queue.
        if let test = ProcessInfo.processInfo.environment["BENCH_TEST_FEEDBACK_QUEUE"].flatMap(URL.init(string:)) { return test }
        #endif
        return PushSender.relayURL.deletingLastPathComponent().appendingPathComponent("feedback-queue")
    }
    /// How often to see whether a day has gone by since the queue last
    /// answered. Only that daily check reaches the relay: every request
    /// there counts against the queue database's monthly allowance. A
    /// check that failed is tried again on the next tick.
    private static let tick: TimeInterval = 60 * 60

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { checkSoon(force: true) } else { status = nil }
        }
    }

    /// The project agents start in.
    var projectID: UUID? {
        didSet { UserDefaults.standard.set(projectID?.uuidString, forKey: Self.projectKey) }
    }

    /// The relay's FEEDBACK_QUEUE_SECRET.
    var secret: String {
        didSet { UserDefaults.standard.set(secret, forKey: Self.secretKey) }
    }

    /// What happened last, for Settings.
    private(set) var status: String?
    private(set) var isProblem = false
    private(set) var isChecking = false

    /// When each agent started, for the daily limit.
    @ObservationIgnored private var starts: [Date]
    /// The worktrees started for feedback: the only ones
    /// `bench discard-feedback` may throw away.
    @ObservationIgnored private var worktrees: Set<UUID>
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private weak var terminals: TerminalManager?
    @ObservationIgnored private weak var cleaner: WorktreeCleaner?
    @ObservationIgnored private var timer: Timer?
    /// Tells the paired phone. Set by the app.
    @ObservationIgnored var notifyPhone: ((_ title: String, _ body: String, _ projectID: UUID?, _ tabID: UUID?) -> Void)?

    init(store: AppStore, terminals: TerminalManager, cleaner: WorktreeCleaner) {
        self.store = store
        self.terminals = terminals
        self.cleaner = cleaner
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        projectID = defaults.string(forKey: Self.projectKey).flatMap(UUID.init)
        secret = defaults.string(forKey: Self.secretKey) ?? ""
        starts = (defaults.array(forKey: Self.startsKey) as? [Date]) ?? []
        worktrees = Set((defaults.stringArray(forKey: Self.worktreesKey) ?? []).compactMap(UUID.init))
        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        if isEnabled { checkSoon() }
    }

    static var isAvailable: Bool { UserDefaults.standard.bool(forKey: availableKey) }

    /// Whether everything needed to start agents is set.
    var isReady: Bool {
        !secret.trimmingCharacters(in: .whitespaces).isEmpty && projectID.flatMap { store?.project($0) } != nil
    }

    private var startsToday: Int {
        starts.filter { Date().timeIntervalSince($0) < 24 * 60 * 60 }.count
    }

    private func checkSoon(force: Bool = false) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if force { self?.check() } else { self?.checkIfDue() }
        }
    }

    /// The daily check: does nothing until a day has passed since the
    /// queue last answered, so relaunching doesn't ask again.
    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        guard FeedbackTask.isCheckDue(lastCheck: last, now: Date()) else { return }
        check()
    }

    // MARK: Checking

    /// Picks up waiting feedback and starts an agent for each, up to the
    /// daily limit. Asks the relay right away, whenever it last did: this
    /// is what Check Now and turning the agent on do.
    func check() {
        guard isEnabled, isReady, !isChecking, Self.isAvailable else { return }
        isChecking = true
        Task {
            defer { isChecking = false }
            // The daily limit is the brake on a pile of messages.
            for _ in 0..<Self.dailyLimit {
                guard startsToday < Self.dailyLimit else {
                    report("Paused: \(Self.dailyLimit) agents started in the last day. The rest wait on the relay.", problem: false)
                    return
                }
                let answer: FeedbackItem.QueueAnswer
                do {
                    answer = try await takeOldest()
                } catch {
                    report(error.localizedDescription, problem: true)
                    return
                }
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                guard let item = answer.item else {
                    // Keep the last thing that happened on screen, unless it was a problem.
                    if status == nil || isProblem { report("No feedback waiting.", problem: false) }
                    return
                }
                await start(item)
                if (answer.remaining ?? 0) == 0 { return }
            }
        }
    }

    private struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    private func takeOldest() async throws -> FeedbackItem.QueueAnswer {
        var request = URLRequest(url: Self.queueURL, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret.trimmingCharacters(in: .whitespaces))", forHTTPHeaderField: "authorization")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure(message: "Couldn't reach the feedback queue. Workbench tries again in an hour.")
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
            throw Failure(message: reason ?? "The feedback queue answered \(status).")
        }
        do {
            return try JSONDecoder().decode(FeedbackItem.QueueAnswer.self, from: data)
        } catch {
            throw Failure(message: "The feedback queue sent something Workbench couldn't read.")
        }
    }

    // MARK: Starting

    private func start(_ item: FeedbackItem) async {
        guard let store, let terminals, let parent = projectID.flatMap({ store.project($0) }) else { return }
        let screenshots = item.screenshotData
        let names = screenshots.indices.map { "screenshot-\($0 + 1).jpg" }
        do {
            let id = try await AgentLauncher.start(
                parent: parent, branch: FeedbackTask.branch(for: item), base: await AgentLauncher.preferredBase(repo: parent.url),
                prompt: FeedbackTask.prompt(projectName: parent.name),
                files: parent.setupFiles ?? Worktrees.suggestedSetupFiles(repo: parent.url), command: parent.setupCommand,
                select: false, savesSetup: false, store: store, terminals: terminals
            ) { folder in
                let saved = folder.appendingPathComponent(FeedbackTask.folder, isDirectory: true)
                try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
                try FeedbackTask.gitignore.write(to: saved.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
                try FeedbackTask.document(for: item, screenshotNames: names)
                    .write(to: saved.appendingPathComponent("feedback.md"), atomically: true, encoding: .utf8)
                for (data, name) in zip(screenshots, names) {
                    try data.write(to: saved.appendingPathComponent(name))
                }
            }
            starts = starts.filter { Date().timeIntervalSince($0) < 24 * 60 * 60 } + [Date()]
            UserDefaults.standard.set(starts, forKey: Self.startsKey)
            worktrees.insert(id)
            saveWorktrees()
            let topic = Self.topic(of: item.message)
            report("Started an agent for “\(topic)” \(Date().formatted(date: .omitted, time: .shortened)).", problem: false)
            let tab = store.project(id)?.tabs.first { $0.kind == .agent }?.id
            notify(title: "Looking into feedback", body: topic, projectID: id, tabID: tab)
        } catch {
            // The message was still emailed, so nothing's lost but the agent.
            report("Couldn't start an agent for “\(Self.topic(of: item.message))”: \(error.localizedDescription) It's still in your email.", problem: true)
        }
    }

    private static func topic(of message: String) -> String {
        let first = message.split(separator: "\n").first.map(String.init) ?? message
        return first.count > 70 ? String(first.prefix(70)) + "…" : first
    }

    // MARK: Discarding

    /// `bench discard-feedback`, run by the agent from its worktree when
    /// the feedback needs nothing done. Only throws away worktrees this
    /// started, and waits a moment so the command can answer first.
    func discard(folder: String) -> (ok: Bool, message: String) {
        guard let store else { return (false, "Workbench isn't ready.") }
        let path = WorktreeList.resolved(folder)
        let worktree = store.projects.first { project in
            guard project.isWorktree else { return false }
            let root = WorktreeList.resolved(project.path)
            return path == root || path.hasPrefix(root + "/")
        }
        guard let worktree, worktrees.contains(worktree.id) else {
            return (false, "This isn't a worktree Workbench started for feedback, so it won't be thrown away.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { await self?.remove(worktree) }
        }
        return (true, "Workbench will throw this worktree and its branch away in a few seconds.")
    }

    private func remove(_ worktree: Project) async {
        do {
            try await cleaner?.removeForRemote(worktree)
            worktrees.remove(worktree.id)
            saveWorktrees()
            report("Discarded \(worktree.branch ?? worktree.name): nothing to do.", problem: false)
            notify(title: "Feedback needed nothing", body: "The agent found nothing to fix, so \(worktree.branch ?? worktree.name) was thrown away.",
                   projectID: nil, tabID: nil)
        } catch {
            report("Couldn't discard \(worktree.branch ?? worktree.name): \(error.localizedDescription)", problem: true)
        }
    }

    private func saveWorktrees() {
        // Forget ones that are gone some other way.
        if let store { worktrees = worktrees.filter { store.project($0) != nil } }
        UserDefaults.standard.set(worktrees.map(\.uuidString), forKey: Self.worktreesKey)
    }

    // MARK: Reporting

    private func report(_ text: String, problem: Bool) {
        status = text
        isProblem = problem
    }

    private func notify(title: String, body: String, projectID: UUID?, tabID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "feedback-\(UUID())", content: content, trigger: nil))
        notifyPhone?(title, body, projectID, tabID)
    }
}
