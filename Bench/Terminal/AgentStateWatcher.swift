import AppKit
import BenchKit
import Foundation
import UserNotifications

/// What Claude reports through Bench's hooks.
nonisolated enum AgentState: String, Sendable {
    case working, waiting, done
}

/// What a Claude tab is up to, from Bench's hooks. Feeds the Overview.
nonisolated struct AgentDetails: Equatable, Sendable {
    var state: AgentState?
    /// Your latest prompt, and when you sent it.
    var prompt: String?
    var promptAt: Date?
    /// The tool it's running or about to run, in words ("Editing Theme.swift"),
    /// and its raw name ("Edit").
    /// Shell commands read as the command itself here, so you can see what
    /// you're allowing; `plainAction` says the same in plain words.
    var action: String?
    var plainAction: String?
    /// The whole shell command, for the card that asks whether to run it.
    var command: String?
    var toolName: String?
    /// What kind of tool that is, if it's one of the known kinds.
    var tool: ToolKind? { ToolKind(name: toolName) }
    /// Its permission question, while it waits ("Claude needs your permission to use Bash").
    var question: String?
    var questionAt: Date?
    /// "permission_prompt" for an allow-or-deny question.
    var questionKind: String?
    /// The tool a permission event asked about, when the event says.
    var askedTool: AskedTool?

    struct AskedTool: Equatable, Sendable {
        var name: String
        var action: String
        var plainAction: String?
        var command: String?
    }
    /// The start of its final message, once it stops.
    var summary: String?
    var stoppedAt: Date?
    /// The session's transcript, from whichever hook reported last.
    var transcriptPath: String?
    /// The questions of its last AskUserQuestion call, and when it was made.
    var askedQuestions: [CompanionQuestion]?
    var toolAt: Date?
    /// When Claude Code last started and finished compacting.
    var compactAt: Date?
    var compactedAt: Date?
    /// The model the session started with, like "claude-opus-5-5". Missing
    /// when it resumed an older conversation.
    var startModel: String?
    /// When Claude Code last started or resumed in the tab.
    var startedAt: Date?
    /// The model Claude last switched to, like "claude-fable-5-1", from
    /// the PostModelSwitch hook. Newer than anything in the transcript.
    var switchedModel: String?

    /// The multiple-choice questions on screen, while it waits on them.
    var questions: [CompanionQuestion]? {
        guard state == .waiting, tool == .question, let askedQuestions, !askedQuestions.isEmpty else { return nil }
        return askedQuestions
    }

    /// True between compacting starting and finishing. Anything Claude
    /// does afterward also means it's over, in case the finish was missed.
    var isCompacting: Bool {
        guard let compactAt else { return false }
        let later = [compactedAt, toolAt, stoppedAt, questionAt].compactMap { $0 }
        return !later.contains { $0 >= compactAt } && Date().timeIntervalSince(compactAt) < 15 * 60
    }

    /// True when Claude is asking to run a tool, where Return means "Yes"
    /// and Escape means "No". Its multiple-choice questions and plan
    /// approvals use the same keys for other things, so they're left out.
    var isAllowOrDeny: Bool {
        guard state == .waiting else { return false }
        if let questionKind, questionKind != "permission_prompt" { return false }
        return tool != .question && tool != .planApproval
    }
}

/// Watches `claude-state/` and reports each tab's latest state and details.
///
/// The hooks replace a tab's files with a rename, which changes the folder,
/// so one folder watch covers every tab.
final class AgentStateWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let onChange: ([UUID: AgentDetails]) -> Void
    /// Final-message summaries by transcript path and stop time, so a
    /// transcript is only read once per finish.
    private var summaryCache: [String: String] = [:]

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

    /// The PreToolUse hook saves everything Claude passes to a tool,
    /// including whole file contents for edits and writes. Bench only needs
    /// a short description, so it rewrites the file keeping short strings.
    /// Only rewrites when that changes something, so it can't loop.
    /// How much of a shell command is kept. Long enough for any command
    /// someone would read before allowing it.
    private static let commandLimit = 8000

    private static func trimToolFile(_ file: URL, json: [String: Any]) {
        let limit = 500
        let input = json["tool_input"] as? [String: Any] ?? [:]
        var kept: [String: String] = [:]
        let bulky: Set<String> = ["content", "old_string", "new_string", "new_source"]
        for (key, value) in input where !bulky.contains(key) {
            // A command is shown whole before you allow it, so it keeps
            // far more than a description needs.
            if let text = value as? String { kept[key] = String(text.prefix(key == "command" ? commandLimit : limit)) }
        }
        // Questions are small and the phone needs all of them to answer.
        let questions = ToolKind(name: json["tool_name"] as? String) == .question ? input["questions"] : nil
        var trimmedInput: [String: Any] = kept
        if let questions { trimmedInput["questions"] = questions }
        var trimmed: [String: Any] = ["tool_input": trimmedInput]
        for key in ["tool_name", "transcript_path", "session_id", "hook_event_name"] {
            if let value = json[key] { trimmed[key] = value }
        }
        guard kept.count + (questions == nil ? 0 : 1) != input.count || input.keys.contains(where: bulky.contains) || trimmed.count != json.count
            || kept.contains(where: { (input[$0.key] as? String)?.count != $0.value.count }),
              let data = try? JSONSerialization.data(withJSONObject: trimmed) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func read() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: AgentSessions.stateFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var all: [UUID: AgentDetails] = [:]
        // After /clear the transcript changes, so use the newest file's path.
        var transcriptDates: [UUID: Date] = [:]
        for file in files {
            let name = file.lastPathComponent
            guard let id = UUID(uuidString: String(name.prefix(36))) else { continue }
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            var details = all[id] ?? AgentDetails()
            if name.count == 36 {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                details.state = AgentState(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
            } else if name.hasSuffix(".json"), let json = Self.json(file) {
                if let path = json["transcript_path"] as? String {
                    let newest = transcriptDates[id].map { (modified ?? .distantPast) >= $0 } ?? true
                    if newest {
                        details.transcriptPath = path
                        transcriptDates[id] = modified ?? .distantPast
                    }
                }
                switch name.dropFirst(37).dropLast(5) {
                case "prompt":
                    details.prompt = (json["prompt"] as? String).map(Self.oneLine)
                    details.promptAt = modified
                case "tool":
                    Self.trimToolFile(file, json: json)
                    details.toolName = json["tool_name"] as? String
                    details.toolAt = modified
                    details.askedQuestions = Self.questions(in: json)
                    let tool = json["tool_name"] as? String ?? "", input = json["tool_input"] as? [String: Any] ?? [:]
                    details.action = ToolWording.literal(tool: tool, input: input)
                    details.command = ToolKind(name: tool) == .shell ? (input["command"] as? String).map { String($0.prefix(Self.commandLimit)) } : nil
                    details.plainAction = Self.describe(tool: tool, input: input)
                case "question":
                    // An agent that asks through a permission event of its
                    // own says what it wants in the tool's description.
                    details.question = json["message"] as? String
                        ?? (json["tool_input"] as? [String: Any])?["description"] as? String
                    details.questionAt = modified
                    details.questionKind = json["notification_type"] as? String
                    // Such an event names the tool itself. The last tool
                    // started may be another one, run alongside it.
                    if let tool = json["tool_name"] as? String, let input = json["tool_input"] as? [String: Any] {
                        details.askedTool = AgentDetails.AskedTool(
                            name: tool, action: ToolWording.literal(tool: tool, input: input), plainAction: Self.describe(tool: tool, input: input),
                            command: ToolKind(name: tool) == .shell ? (input["command"] as? String).map { String($0.prefix(Self.commandLimit)) } : nil)
                    }
                case "compact":
                    details.compactAt = modified
                case "compacted":
                    details.compactedAt = modified
                case "start":
                    details.startModel = json["model"] as? String
                    details.startedAt = modified
                case "model":
                    details.switchedModel = json["to_model"] as? String
                case "stop":
                    details.stoppedAt = modified
                    if let path = json["transcript_path"] as? String {
                        let key = "\(path)@\(modified?.timeIntervalSince1970 ?? 0)"
                        if summaryCache[key] == nil { summaryCache[key] = Self.lastAssistantText(transcript: path) ?? "" }
                        // A recap of the whole turn when there is one, or
                        // else how Claude's final message starts.
                        details.summary = Recaps.shared.recap(transcript: path, stoppedAt: modified)
                            ?? summaryCache[key].flatMap { $0.isEmpty ? nil : $0 }
                    }
                default:
                    break
                }
            }
            all[id] = details
        }
        // Pickers don't send a Notification with words of their own (a
        // generic "needs your permission" can follow a few seconds later).
        for (id, details) in all where details.state == .waiting {
            if let asked = details.askedTool {
                all[id]?.toolName = asked.name
                all[id]?.action = asked.action
                all[id]?.command = asked.command
                all[id]?.plainAction = asked.plainAction
            }
            if let questions = details.questions {
                all[id]?.question = questions.count == 1 ? questions[0].question : "There are \(questions.count) questions for you."
            } else if details.tool == .planApproval {
                all[id]?.question = CompanionQuestion.planApprovalText
            }
        }
        onChange(all)
    }

    nonisolated private static func json(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// AskUserQuestion's questions, from its PreToolUse event.
    nonisolated private static func questions(in json: [String: Any]) -> [CompanionQuestion]? {
        guard ToolKind(name: json["tool_name"] as? String) == .question,
              let input = json["tool_input"] as? [String: Any],
              let list = input["questions"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let question = item["question"] as? String else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> CompanionQuestion.Option? in
                guard let label = option["label"] as? String else { return nil }
                return CompanionQuestion.Option(label: label, description: option["description"] as? String,
                                               preview: option["preview"] as? String)
            }
            return CompanionQuestion(question: question, header: item["header"] as? String, options: options,
                                     multiSelect: item["multiSelect"] as? Bool ?? false)
        }
    }

    nonisolated private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    /// A tool call in a few words, like "Editing Theme.swift" or "Showing recent commits".
    nonisolated static func describe(tool: String, input: [String: Any]) -> String {
        ToolWording.describe(tool: tool, input: input)
    }

    /// The first lines of Claude's final message, from the end of its transcript.
    nonisolated static func lastAssistantText(transcript path: String) -> String? {
        guard let text = lastAssistantMessage(transcript: path) else { return nil }
        let trimmed = oneLine(text)
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
    case waiting(project: String, tabID: UUID, projectID: UUID, question: String?)
    case finished(project: String, tabID: UUID, projectID: UUID, summary: String?)
    case checks(project: String, projectID: UUID, pr: PullRequestInfo)
    case deploy(project: String, projectID: UUID, deploy: DeployInfo)

    var projectID: UUID {
        switch self {
        case .waiting(_, _, let id, _), .finished(_, _, let id, _), .checks(_, let id, _), .deploy(_, let id, _): id
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

    func notifyWaiting(project: String, tabID: UUID, projectID: UUID, agent: String, question: String? = nil) {
        remote?(.waiting(project: project, tabID: tabID, projectID: projectID, question: question))
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
