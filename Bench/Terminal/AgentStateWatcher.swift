import AppKit
import BenchKit
import Foundation
import UserNotifications

/// Watches `claude-state/` and reports each tab's latest state and details.
///
/// The hooks replace a tab's files with a rename, which changes the folder,
/// so one folder watch covers every tab.
final class AgentStateWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let onChange: ([UUID: AgentDetails]) -> Void
    private var files = AgentStateFiles()

    init(onChange: @escaping ([UUID: AgentDetails]) -> Void) {
        self.onChange = onChange
        let folder = AgentSessions.stateFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        Recaps.shared.onRecap = { [weak self] in self?.read() }
        read()
    }

    deinit { source?.cancel() }

    private func read() {
        onChange(files.read(folder: AgentSessions.stateFolder,
                            fresh: { Recaps.shared.recap(transcript: $0, stoppedAt: $1) },
                            summary: { Self.lastAssistantText(transcript: $0) }))
    }

    /// A tool call in a few words, like "Editing Theme.swift" or "Showing recent commits".
    nonisolated static func describe(tool: String, input: [String: Any]) -> String {
        ToolWording.describe(tool: tool, input: input)
    }

    /// The first lines of Claude's final message, from the end of its transcript.
    nonisolated static func lastAssistantText(transcript path: String) -> String? {
        guard let text = lastAssistantMessage(transcript: path) else { return nil }
        let trimmed = AgentStateFiles.oneLine(text)
        return trimmed.count > 220 ? String(trimmed.prefix(219)) + "…" : trimmed
    }

    /// The agent's last message in a transcript, whole, for `bench read`.
    nonisolated static func lastAssistantMessage(transcript path: String) -> String? {
        Agents.transcripts(for: path).lastMessage(in: path)
    }
}

/// Mac notifications: Claude needs you (clicking opens that tab), and a
/// pull request's checks finished (clicking opens the PR).
/// Something worth telling the phone about.
enum RemoteEvent {
    /// `allowOrDeny` when a yes or no answers it, so the phone can offer both.
    case waiting(project: String, tabID: UUID, projectID: UUID, question: String?, allowOrDeny: Bool)
    case finished(project: String, tabID: UUID, projectID: UUID, summary: String?)
    case checks(project: String, projectID: UUID, pr: PullRequestInfo)
    case deploy(project: String, projectID: UUID, deploy: DeployInfo)

    var projectID: UUID {
        switch self {
        case .waiting(_, _, let id, _, _), .finished(_, _, let id, _), .checks(_, let id, _), .deploy(_, let id, _): id
        }
    }
}

final class AgentNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Set by the companion: the same moments, pushed to the phone.
    var remote: ((RemoteEvent) -> Void)?

    var openTab: ((UUID, UUID) -> Void)?
    var openOverview: (() -> Void)?
    var openQueuedPrompts: (() -> Void)?
    /// Opens a session on another Mac: its host, project and session.
    var openRemote: ((String, UUID, UUID) -> Void)?
    private var askedPermission = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    private func center() -> UNUserNotificationCenter {
        let center = UNUserNotificationCenter.current()
        if !askedPermission {
            askedPermission = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        return center
    }

    func notifyWaiting(project: String, tabID: UUID, projectID: UUID, agent: String, question: String? = nil, allowOrDeny: Bool = false) {
        remote?(.waiting(project: project, tabID: tabID, projectID: projectID, question: question, allowOrDeny: allowOrDeny))
        let center = center()
        let content = UNMutableNotificationContent()
        content.title = "\(agent) needs you"
        content.body = question.map { "\(project): \($0)" } ?? "Waiting for your permission in \(project)."
        content.sound = .default
        content.userInfo = ["tab": tabID.uuidString, "project": projectID.uuidString]
        // Reusing the tab's id replaces an older alert for the same tab.
        center.add(UNNotificationRequest(identifier: tabID.uuidString, content: content, trigger: nil))
    }

    /// An agent on another Mac is waiting on you. Tapping it opens that
    /// session here.
    func notifyRemoteWaiting(mac: String, host: String, alert: RemoteAttention.Alert) {
        let content = UNMutableNotificationContent()
        content.title = "\(alert.agent) needs you on \(mac)"
        content.body = alert.question.map { "\(alert.project): \($0)" } ?? "Waiting for your permission in \(alert.project)."
        content.sound = .default
        content.userInfo = ["remoteHost": host, "project": alert.projectID.uuidString, "session": alert.sessionID.uuidString]
        // Reusing the session's id replaces an older alert for it.
        center().add(UNNotificationRequest(identifier: alert.sessionID.uuidString, content: content, trigger: nil))
    }

    /// Claude finished while you were away. Only the phone hears about
    /// this; on the Mac the green row is enough.
    func notifyFinished(project: String, tabID: UUID, projectID: UUID, summary: String?) {
        remote?(.finished(project: project, tabID: tabID, projectID: projectID, summary: summary))
    }

    /// Something Claude was asked to tell you, through `bench notify`.
    /// Tapping it opens the tab it came from, when that's known.
    func notifyMessage(title: String, body: String, tabID: UUID?, projectID: UUID?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let tabID, let projectID {
            content.userInfo = ["tab": tabID.uuidString, "project": projectID.uuidString]
        }
        // Each message is its own banner; two in a row shouldn't replace each other.
        center().add(UNNotificationRequest(identifier: "message-\(UUID().uuidString)", content: content, trigger: nil))
    }

    /// Prompts from the phone's queue that couldn't start. Tapping it
    /// opens the list.
    func notifyQueuedFailures(count: Int, firstReason: String) {
        let content = UNMutableNotificationContent()
        content.title = count == 1 ? "A queued prompt couldn't start" : "\(count) queued prompts couldn't start"
        content.body = firstReason
        content.sound = .default
        content.userInfo = ["page": "queuedPrompts"]
        center().add(UNNotificationRequest(identifier: "queued-failures", content: content, trigger: nil))
    }

    /// `waitingToMerge` says you'd asked for a merge once the checks pass:
    /// it's on its way to Claude, or (if they failed) it isn't happening.
    func notifyChecks(project: String, projectID: UUID, pr: PullRequestInfo, waitingToMerge: Bool = false) {
        remote?(.checks(project: project, projectID: projectID, pr: pr))
        let content = UNMutableNotificationContent()
        if pr.checks == .passing {
            content.title = waitingToMerge ? "Checks passed, merging" : "Checks passed"
            content.body = waitingToMerge
                ? "The agent is merging PR #\(pr.number) in \(project): \(pr.title)"
                : "PR #\(pr.number) in \(project): \(pr.title)"
        } else {
            content.title = waitingToMerge ? "Checks failed, not merging" : "Checks failed"
            content.body = "PR #\(pr.number) in \(project). Failing: " + pr.failingNames.joined(separator: ", ")
        }
        content.sound = .default
        content.userInfo = ["url": pr.url.absoluteString]
        center().add(UNNotificationRequest(identifier: pr.url.absoluteString, content: content, trigger: nil))
    }

    func notifyDeploy(project: String, projectID: UUID, deploy: DeployInfo) {
        remote?(.deploy(project: project, projectID: projectID, deploy: deploy))
        let text = Self.deployText(project: project, deploy: deploy)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        if let url = deploy.url { content.userInfo = ["url": url.absoluteString] }
        center().add(UNNotificationRequest(identifier: "deploy-\(project)-\(deploy.prNumber)", content: content, trigger: nil))
    }

    static func deployText(project: String, deploy: DeployInfo) -> (title: String, body: String) {
        if deploy.state == .failed {
            return ("Deploy failed", "PR #\(deploy.prNumber) in \(project). Failed: " + deploy.failing.joined(separator: ", "))
        }
        return ("Deployed", "PR #\(deploy.prNumber) in \(project) is live on " + deploy.environments.joined(separator: ", "))
    }

    /// Show banners even while Bench is in front. "Needs you" alerts are
    /// only sent from the background anyway, and check results are worth
    /// seeing either way.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func clear(tabID: UUID) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [tabID.uuidString])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        if info["page"] as? String == "overview" {
            await MainActor.run { openOverview?() }
            return
        }
        if info["page"] as? String == "queuedPrompts" {
            await MainActor.run { openQueuedPrompts?() }
            return
        }
        if let url = (info["url"] as? String).flatMap(URL.init(string:)) {
            await MainActor.run { ArtifactLinks.open(url) }
            return
        }
        if let host = info["remoteHost"] as? String,
           let project = (info["project"] as? String).flatMap(UUID.init(uuidString:)),
           let session = (info["session"] as? String).flatMap(UUID.init(uuidString:)) {
            await MainActor.run { openRemote?(host, project, session) }
            return
        }
        guard let tab = (info["tab"] as? String).flatMap(UUID.init(uuidString:)),
              let project = (info["project"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        await MainActor.run { openTab?(tab, project) }
    }
}
