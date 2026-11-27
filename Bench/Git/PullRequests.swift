import AppKit
import Foundation
import Observation

/// The GitHub pull request for a project's current branch, and its checks.
nonisolated struct PullRequestInfo: Equatable, Sendable {
    enum State: Sendable { case open, draft, merged, closed }
    enum Checks: Sendable { case none, pending, passing, failing }

    var number: Int
    var title: String
    var url: URL
    var state: State
    var checks: Checks
    var passedCount = 0
    var totalCount = 0
    var failingNames: [String] = []
    /// The last commit on the PR's branch, as GitHub knows it.
    var headCommit: String?
    /// The commit the merge made on the base branch, which is what gets
    /// deployed.
    var mergeCommit: String?
    var mergedAt: Date?

    var summary: String {
        var text = "PR #\(number): \(title)"
        switch state {
        case .draft: text += "\nDraft"
        case .merged: text += "\nMerged"
        case .closed: text += "\nClosed"
        case .open: break
        }
        switch checks {
        case .none: break
        case .pending: text += "\nChecks running (\(passedCount) of \(totalCount) passed so far)"
        case .passing: text += "\nAll \(totalCount) checks passed"
        case .failing: text += "\nFailing: " + failingNames.joined(separator: ", ")
        }
        return text
    }
}

/// Asks the GitHub CLI (`gh`) about each project's branch. Projects that
/// aren't on GitHub, or a Mac without `gh`, simply show nothing.
@Observable
final class PullRequests {
    private(set) var info: [UUID: PullRequestInfo] = [:]
    /// Pull requests to merge once their checks pass, by project: the PR's
    /// number and what to send Claude then. Workbench does the waiting, so
    /// Claude isn't stuck watching CI.
    private(set) var mergeWhenReady: [UUID: PendingMerge] = [:]

    struct PendingMerge: Equatable {
        var number: Int
        var prompt: String
    }

    /// Called with the project's id and name when a PR's checks go from
    /// running to passed or failed, and whether it was waiting to merge
    /// (it's merging now if they passed).
    @ObservationIgnored var onChecksFinished: ((UUID, String, PullRequestInfo, _ waitingToMerge: Bool) -> Void)?
    /// Called when a pull request waiting to merge has passed its checks,
    /// with the project's id and the prompt to send Claude.
    @ObservationIgnored var onReadyToMerge: ((UUID, String) -> Void)?
    /// Called once a PR is seen merged, with the repo's own project (a
    /// worktree's parent) and its name.
    @ObservationIgnored var onMerged: ((UUID, String, PullRequestInfo) -> Void)?

    private struct Entry {
        var root: URL
        var name: String
        var branch: String
        /// The repo's own project: a worktree's parent, or the project.
        var homeID: UUID
        var repoName: String
        var checked: Date?
        /// When the branch was switched to or its PR or last commit changed.
        /// For a few minutes after, a PR (or its checks) may still be on
        /// the way, so it's checked as often as running checks are.
        var changed: Date
    }
    @ObservationIgnored private var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var inFlight: Set<UUID> = []
    @ObservationIgnored private var timer: Timer?

    nonisolated static var ghPath: String? { Tools.path("gh") }

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStale() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStale(force: true) }
        }
    }

    /// Merges the project's pull request once its checks pass. Only while
    /// they're running; otherwise there's nothing to wait for.
    func mergeWhenReady(_ projectID: UUID, prompt: String) {
        guard let pr = info[projectID], pr.state == .open, pr.checks == .pending else { return }
        mergeWhenReady[projectID] = PendingMerge(number: pr.number, prompt: prompt)
    }

    func cancelMerge(_ projectID: UUID) {
        mergeWhenReady[projectID] = nil
    }

    /// For tests: what GitHub last said about a project's pull request.
    func setInfoForTesting(_ pr: PullRequestInfo?, for projectID: UUID) {
        info[projectID] = pr
    }

    /// Call when a project's branch is known or changes.
    func track(_ project: Project, branch: String?, baseRef: String?) {
        // The base branch (like main) usually has no PR of its own.
        guard let branch, branch != baseRef?.split(separator: "/").last.map(String.init) else {
            leaveBranch(project.id)
            entries[project.id] = nil
            info[project.id] = nil
            mergeWhenReady[project.id] = nil
            return
        }
        if entries[project.id]?.branch == branch { return }
        // A switch to a new branch may be followed by a PR; the branches
        // picked up at launch are just checked as usual.
        let switched = entries[project.id] != nil
        leaveBranch(project.id)
        mergeWhenReady[project.id] = nil
        entries[project.id] = Entry(root: project.url, name: project.name, branch: branch,
                                    homeID: project.parentID ?? project.id, repoName: project.repoName,
                                    changed: switched ? .now : .distantPast)
        info[project.id] = nil
        fetch(project.id)
    }

    func forget(keeping ids: Set<UUID>) {
        for id in entries.keys where !ids.contains(id) {
            entries[id] = nil
            info[id] = nil
            mergeWhenReady[id] = nil
        }
    }

    /// Merging often switches the project back to main before the next
    /// check, so look once more at a branch whose PR was still open.
    private func leaveBranch(_ id: UUID) {
        guard let entry = entries[id], let pr = info[id], pr.state == .open || pr.state == .draft,
              let gh = Self.ghPath else { return }
        Task.detached(priority: .utility) {
            guard let result = Self.load(gh: gh, root: entry.root, branch: entry.branch) else { return }
            await MainActor.run { [weak self] in self?.noticeMerge(entry, old: pr, new: result) }
        }
    }

    private func noticeMerge(_ entry: Entry, old: PullRequestInfo?, new: PullRequestInfo) {
        guard new.state == .merged, old?.state != .merged else { return }
        // On launch every merged branch shows up as new. Only recent merges
        // can still be deploying.
        if old == nil, new.mergedAt.map({ Date.now.timeIntervalSince($0) > 30 * 60 }) ?? true { return }
        onMerged?(entry.homeID, entry.repoName, new)
    }

    /// Re-checks every minute, or every 15 seconds while checks are running
    /// or a new PR's checks haven't shown up yet. In the background, only
    /// those are followed, so Bench can say when checks finish (and merge
    /// one that's waiting).
    private func refreshStale(force: Bool = false) {
        let active = NSApp.isActive
        for (id, entry) in entries {
            let awaited = info[id].map { $0.state == .open && $0.checks == .none } ?? true
            let running = info[id]?.checks == .pending
                || (awaited && Date.now.timeIntervalSince(entry.changed) < 3 * 60)
            guard active || running else { continue }
            let interval: TimeInterval = running ? 15 : 60
            if force || entry.checked.map({ Date.now.timeIntervalSince($0) >= interval }) ?? true {
                fetch(id)
            }
        }
    }

    private func fetch(_ id: UUID) {
        guard let entry = entries[id], !inFlight.contains(id), let gh = Self.ghPath else { return }
        inFlight.insert(id)
        Task.detached(priority: .utility) {
            let result = Self.load(gh: gh, root: entry.root, branch: entry.branch)
            await MainActor.run { [weak self] in
                guard let self else { return }
                inFlight.remove(id)
                // Ignore answers for a branch we've since moved off.
                guard entries[id]?.branch == entry.branch else { return }
                entries[id]?.checked = .now
                let old = info[id]
                // The first answer for a branch isn't a change.
                if entry.checked != nil, old?.number != result?.number || old?.headCommit != result?.headCommit {
                    entries[id]?.changed = .now
                }
                if old != result { info[id] = result }
                if let result { noticeMerge(entry, old: old, new: result) }
                let wasWaiting = mergeWhenReady[id] != nil
                settleMerge(id, result)
                if let old, let result, old.number == result.number, old.checks == .pending,
                   result.checks == .passing || result.checks == .failing {
                    onChecksFinished?(id, entry.name, result, wasWaiting)
                }
            }
        }
    }

    /// Acts on a pull request waiting to merge, once there's news: sends
    /// the merge when its checks pass, and gives up when they fail, go
    /// away, or the pull request isn't the open one it was. Returns
    /// whether it sent the merge.
    @discardableResult
    func settleMerge(_ id: UUID, _ pr: PullRequestInfo?) -> Bool {
        // No answer (offline, gh hiccup) isn't news. Wait for the next one.
        guard let pending = mergeWhenReady[id], let pr else { return false }
        guard pr.number == pending.number, pr.state == .open else {
            mergeWhenReady[id] = nil
            return false
        }
        switch pr.checks {
        case .pending:
            return false
        case .passing:
            mergeWhenReady[id] = nil
            onReadyToMerge?(id, pending.prompt)
            return true
        case .failing, .none:
            mergeWhenReady[id] = nil
            return false
        }
    }

    private nonisolated static let fields = "number,title,url,state,isDraft,statusCheckRollup,headRefOid,mergeCommit,mergedAt"

    private nonisolated static func load(gh: String, root: URL, branch: String) -> PullRequestInfo? {
        // Fork pull requests aren't the branch's PR in the repo `gh` picks:
        // GitHub indexes them under owner:branch, which `pr view <branch>`
        // doesn't match, so ask the list for the branch's pull requests.
        let list = run(gh, ["pr", "list", "--head", branch, "--state", "all", "--json", fields, "--limit", "10"], root: root)
        guard let json = try? JSONSerialization.jsonObject(with: list) as? [[String: Any]] else { return nil }
        return pick(from: json)
    }

    /// A branch usually has one pull request; pick the open one, falling
    /// back to the first of any state (a merged branch's last PR).
    nonisolated static func pick(from json: [[String: Any]]) -> PullRequestInfo? {
        let parsed = json.compactMap(parse)
        return parsed.first { $0.state == .open } ?? parsed.first
    }

    /// Runs gh and returns its output; exits non-zero when there's no PR,
    /// no GitHub remote, or no login.
    private nonisolated static func run(_ gh: String, _ arguments: [String], root: URL) -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.environment = Tools.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return Data() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return Data() }
        return data
    }

    nonisolated static func parse(_ data: Data) -> PullRequestInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(from: json)
    }

    nonisolated static func parse(from json: [String: Any]) -> PullRequestInfo? {
        guard let number = json["number"] as? Int,
              let urlString = json["url"] as? String, let url = URL(string: urlString) else { return nil }
        let state: PullRequestInfo.State
        switch json["state"] as? String {
        case "MERGED": state = .merged
        case "CLOSED": state = .closed
        default: state = (json["isDraft"] as? Bool ?? false) ? .draft : .open
        }
        var result = PullRequestInfo(number: number, title: json["title"] as? String ?? "", url: url, state: state, checks: .none)
        result.headCommit = json["headRefOid"] as? String
        result.mergeCommit = (json["mergeCommit"] as? [String: Any])?["oid"] as? String
        result.mergedAt = (json["mergedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }

        var pending = 0
        for check in json["statusCheckRollup"] as? [[String: Any]] ?? [] {
            result.totalCount += 1
            let name = check["name"] as? String ?? check["context"] as? String ?? "check"
            // Check runs (GitHub Actions) have status and conclusion; older
            // status contexts have a single state.
            let outcome: String
            if let status = check["status"] as? String {
                outcome = status == "COMPLETED" ? (check["conclusion"] as? String ?? "") : "PENDING"
            } else {
                outcome = check["state"] as? String ?? ""
            }
            switch outcome {
            case "SUCCESS", "NEUTRAL", "SKIPPED": result.passedCount += 1
            case "PENDING", "EXPECTED", "": pending += 1
            default: result.failingNames.append(name)
            }
        }
        if result.totalCount > 0 {
            result.checks = !result.failingNames.isEmpty ? .failing : pending > 0 ? .pending : .passing
        }
        return result
    }
}
