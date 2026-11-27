import Foundation

/// What Claude reports through Bench's hooks.
public enum AgentState: String, Sendable {
    case working, waiting, done
}

/// What a Claude tab is up to, from Bench's hooks. Feeds the Overview.
public struct AgentDetails: Equatable, Sendable {
    public init(state: AgentState? = nil,
                prompt: String? = nil,
                promptAt: Date? = nil,
                action: String? = nil,
                plainAction: String? = nil,
                command: String? = nil,
                toolName: String? = nil,
                question: String? = nil,
                questionAt: Date? = nil,
                questionKind: String? = nil,
                askedTool: AskedTool? = nil,
                summary: String? = nil,
                stoppedAt: Date? = nil,
                transcriptPath: String? = nil,
                askedQuestions: [CompanionQuestion]? = nil,
                toolAt: Date? = nil,
                compactAt: Date? = nil,
                compactedAt: Date? = nil,
                startModel: String? = nil,
                startedAt: Date? = nil,
                switchedModel: String? = nil) {
        self.state = state
        self.prompt = prompt
        self.promptAt = promptAt
        self.action = action
        self.plainAction = plainAction
        self.command = command
        self.toolName = toolName
        self.question = question
        self.questionAt = questionAt
        self.questionKind = questionKind
        self.askedTool = askedTool
        self.summary = summary
        self.stoppedAt = stoppedAt
        self.transcriptPath = transcriptPath
        self.askedQuestions = askedQuestions
        self.toolAt = toolAt
        self.compactAt = compactAt
        self.compactedAt = compactedAt
        self.startModel = startModel
        self.startedAt = startedAt
        self.switchedModel = switchedModel
    }

    public var state: AgentState?
    /// Your latest prompt, and when you sent it.
    public var prompt: String?
    public var promptAt: Date?
    /// The tool it's running or about to run, in words ("Editing Theme.swift"),
    /// and its raw name ("Edit").
    /// Shell commands read as the command itself here, so you can see what
    /// you're allowing; `plainAction` says the same in plain words.
    public var action: String?
    public var plainAction: String?
    /// The whole shell command, for the card that asks whether to run it.
    public var command: String?
    public var toolName: String?
    /// What kind of tool that is, if it's one of the known kinds.
    public var tool: ToolKind? { ToolKind(name: toolName) }
    /// Its permission question, while it waits ("Claude needs your permission to use Bash").
    public var question: String?
    public var questionAt: Date?
    /// "permission_prompt" for an allow-or-deny question.
    public var questionKind: String?
    /// The tool a permission event asked about, when the event says.
    public var askedTool: AskedTool?

    public struct AskedTool: Equatable, Sendable {
        public var name: String
        public var action: String
        public var plainAction: String?
        public var command: String?

        public init(name: String, action: String, plainAction: String? = nil, command: String? = nil) {
            self.name = name
            self.action = action
            self.plainAction = plainAction
            self.command = command
        }
    }
    /// The start of its final message, once it stops.
    public var summary: String?
    public var stoppedAt: Date?
    /// The session's transcript, from whichever hook reported last.
    public var transcriptPath: String?
    /// The questions of its last AskUserQuestion call, and when it was made.
    public var askedQuestions: [CompanionQuestion]?
    public var toolAt: Date?
    /// When Claude Code last started and finished compacting.
    public var compactAt: Date?
    public var compactedAt: Date?
    /// The model the session started with, like "claude-opus-5-5". Missing
    /// when it resumed an older conversation.
    public var startModel: String?
    /// When Claude Code last started or resumed in the tab.
    public var startedAt: Date?
    /// The model Claude last switched to, like "claude-fable-5-1", from
    /// the PostModelSwitch hook. Newer than anything in the transcript.
    public var switchedModel: String?

    /// The multiple-choice questions on screen, while it waits on them.
    public var questions: [CompanionQuestion]? {
        guard state == .waiting, tool == .question, let askedQuestions, !askedQuestions.isEmpty else { return nil }
        return askedQuestions
    }

    /// True between compacting starting and finishing. Anything Claude
    /// does afterward also means it's over, in case the finish was missed.
    public var isCompacting: Bool {
        guard let compactAt else { return false }
        let later = [compactedAt, toolAt, stoppedAt, questionAt].compactMap { $0 }
        return !later.contains { $0 >= compactAt } && Date().timeIntervalSince(compactAt) < 15 * 60
    }

    /// True when Claude is asking to run a tool, where Return means "Yes"
    /// and Escape means "No". Its multiple-choice questions and plan
    /// approvals use the same keys for other things, so they're left out.
    public var isAllowOrDeny: Bool {
        guard state == .waiting else { return false }
        if let questionKind, questionKind != "permission_prompt" { return false }
        return tool != .question && tool != .planApproval
    }
}

/// Reads what the agents' hooks left in a state folder (see `AgentHookCommands`):
/// one word per tab for its state, and the JSON of the latest prompt, tool,
/// question and stop beside it.
public struct AgentStateFiles {
    /// Final-message summaries by transcript path and stop time, so a
    /// transcript is only read once per finish.
    private var summaryCache: [String: String] = [:]

    public init() {}

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

    /// Every tab's state and details, from the files in a state folder.
    /// `summary` turns a stop into a line about what the agent did: the
    /// transcript's path and when it stopped. It's asked once per stop,
    /// unless `fresh` gives a newer answer (a recap that arrived later).
    public mutating func read(folder: URL, fresh: (_ transcript: String, _ stoppedAt: Date?) -> String? = { _, _ in nil },
                              summary: (_ transcript: String) -> String?) -> [UUID: AgentDetails] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
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
                    details.plainAction = ToolWording.describe(tool: tool, input: input)
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
                            name: tool, action: ToolWording.literal(tool: tool, input: input), plainAction: ToolWording.describe(tool: tool, input: input),
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
                        if summaryCache[key] == nil { summaryCache[key] = summary(path) ?? "" }
                        // A recap of the whole turn when there is one, or
                        // else how Claude's final message starts.
                        details.summary = fresh(path, modified)
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
        return all
    }

    private static func json(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// AskUserQuestion's questions, from its PreToolUse event.
    private static func questions(in json: [String: Any]) -> [CompanionQuestion]? {
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

    public static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
