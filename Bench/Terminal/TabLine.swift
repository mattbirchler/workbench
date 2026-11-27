import BenchKit
import Foundation

/// One Claude tab's line on its project's sidebar card, when the project
/// has more than one: which tab it is and what it's up to, so the card
/// speaks for every tab and not just the busiest.
struct TabLine: Identifiable, Equatable {
    let id: UUID
    var activity: TabActivity
    /// What the tab is about: the name you gave it, Claude's title for the
    /// task, or your prompt.
    var label: String
    /// What it's up to, in a word or two ("Working", "Waiting on you").
    var state: String
    /// The fuller story for the tooltip: what it's running or its recap.
    var detail: String?
    /// What the tab is about, when something says (unlike `label`, which
    /// falls back to the tab's plain title, like "Claude").
    var task: String?

    init(id: UUID, activity: TabActivity, customTitle: String?, terminalTitle: String?,
         details: AgentDetails?, initialPrompt: String?, fallbackTitle: String) {
        self.id = id
        self.activity = activity
        let prompt = details?.prompt ?? initialPrompt
        task = Self.describe(customTitle: customTitle, terminalTitle: terminalTitle, prompt: prompt)
        label = task ?? fallbackTitle
        state = Self.stateWords(activity: activity, details: details, hasPrompt: prompt != nil)
        detail = switch activity {
        case .waiting: details?.question
        case .working, .remoteWorking: details?.plainAction ?? details?.action
        default: details?.summary
        }
    }

    /// The name you gave the tab, else Claude's title for the task without
    /// its spinner, else your prompt's first line. Nil when none says anything.
    static func describe(customTitle: String?, terminalTitle: String?, prompt: String?) -> String? {
        if let customTitle = customTitle?.trimmingCharacters(in: .whitespaces), !customTitle.isEmpty { return customTitle }
        let title = String((terminalTitle ?? "").drop { !$0.isLetter && !$0.isNumber })
            .trimmingCharacters(in: .whitespaces)
        if !title.isEmpty, title != "Claude Code", title.lowercased() != "claude" { return title }
        let firstLine = prompt?.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return firstLine.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func stateWords(activity: TabActivity, details: AgentDetails?, hasPrompt: Bool) -> String {
        switch activity {
        case .waiting: return "Waiting on you"
        case .working: return "Working"
        case .remoteWorking: return "Working remotely"
        case .done: return "Finished"
        case .attention: return "Needs a look"
        case .idle:
            if details?.stoppedAt != nil { return "Done" }
            return hasPrompt ? "Starting" : "Ready"
        }
    }
}
