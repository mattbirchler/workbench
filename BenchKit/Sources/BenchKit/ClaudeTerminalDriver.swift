import Foundation

/// Claude Code's terminal: its keys, its window title and what its screen
/// looks like.
public struct ClaudeTerminalDriver: AgentTerminalDriver {
    public init() {}

    // MARK: Keys

    public var allowKey: Key { .returnKey }
    public var denyKey: Key { .escape }
    public var interruptKey: Key { .escape }
    /// Ctrl+Return.
    public var sendQueueNowKey: Key? { .controlReturn }
    /// Shift-Tab.
    public var nextModeKey: Key? { .backTab }
    public var takesBackQueue: Bool { true }

    // MARK: The window title

    /// The first character of Claude Code's title while it works. Older
    /// versions used a braille spinner; newer ones alternate ◐ and ◑.
    /// Anything else up front reads as Claude having left the terminal.
    public func isWorkingMark(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(scalar.value) || (0x25D0...0x25D3).contains(scalar.value)
    }

    /// Claude Code keeps the title: a spinner while it works, and
    /// "✳ Claude Code" or "✳ <task>" otherwise.
    public func titleIsAgents(_ title: String?) -> Bool {
        guard let title, let first = title.unicodeScalars.first else { return true }
        return first.value == 0x2733 || title.lowercased().hasPrefix("claude")
    }

    public func titleIsStarting(_ title: String?) -> Bool { title?.hasPrefix("claude") == true }

    // MARK: The screen

    /// What's in Claude Code's message box, from its screen: the lines
    /// between the last two rules, without the ❯. nil when it isn't there.
    public func messageBox(in screen: String?) -> String? {
        guard let lines = screen?.components(separatedBy: "\n") else { return nil }
        let rules = lines.indices.filter { index in
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            return line.count >= 20 && line.allSatisfy { $0 == "─" }
        }
        guard rules.count >= 2 else { return nil }
        let (top, bottom) = (rules[rules.count - 2], rules[rules.count - 1])
        guard bottom > top + 1 else { return nil }
        var inside = lines[(top + 1)..<bottom].map { $0.trimmingCharacters(in: .whitespaces) }
        guard inside[0].hasPrefix("❯") else { return nil }
        inside[0] = String(inside[0].dropFirst()).trimmingCharacters(in: .whitespaces)
        return inside.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func isHint(_ box: String) -> Bool { box.hasPrefix("Press ") }

    public func isQueueHint(_ box: String) -> Bool { box.hasPrefix("Press up to edit") }

    /// From the line under the message box.
    public func permissionMode(in screen: String?) -> PermissionMode? { PermissionMode(screen: screen) }

    /// The folder Claude Code is asking you to trust ("" if it can't be
    /// read). Nil when it isn't asking.
    public func trustFolder(in screen: String) -> String? {
        guard screen.contains("Yes, I trust this folder"), screen.contains("No, exit") else { return nil }
        let lines = screen.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Still asking, not left on screen after Claude Code quit.
        guard lines.last(where: { !$0.isEmpty })?.hasPrefix("Enter to confirm") == true else { return nil }
        // A long path wraps onto more lines, up to the blank line after it.
        guard let heading = lines.firstIndex(where: { $0.hasPrefix("Accessing workspace") }) else { return "" }
        let rest = lines[(heading + 1)...].drop { $0.isEmpty }
        return rest.prefix { !$0.isEmpty }.joined()
    }

    public func startupPrompt(in screen: String) -> StartupPrompt? {
        guard let folder = trustFolder(in: screen) else { return nil }
        let name = folder.isEmpty ? "this folder" : Self.withTilde(folder)
        let question = CompanionQuestion(
            question: "Do you trust the files in \(name)?",
            options: [.init(label: "Yes, I trust this folder", description: "Claude Code can read, edit and run files here. Only say yes for your own code or a project you know."),
                      .init(label: "No, exit", description: "Claude Code quits without opening the folder.")],
            allowsOther: false)
        // The cursor starts on "No, exit", so yes is Down first.
        return StartupPrompt(question: question, blocker: "is asking whether to trust this folder",
                             answers: [.init(moves: [.downArrow], picked: "Yes, I trust this folder"), .init()])
    }

    /// A path with the home folder written as `~`, as Finder and shells show it.
    static func withTilde(_ path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    public func showsMessageBox(in screen: String?) -> Bool { false }

    /// The plan picker's choices from a screen of Claude Code: the numbered
    /// lines after "Would you like to proceed?", while its cursor is on one.
    /// A last choice like "Type here to tell Claude what to change" becomes
    /// your own words rather than an option.
    public func planApproval(in screen: String?) -> CompanionQuestion? {
        guard let lines = screen?.components(separatedBy: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }),
              let heading = lines.lastIndex(where: { $0.contains("Would you like to proceed?") }) else { return nil }
        var labels: [String] = []
        var hasCursor = false
        for line in lines[(heading + 1)...] {
            var text = Substring(line)
            if text.hasPrefix("❯") {
                hasCursor = true
                text = text.dropFirst().drop { $0 == " " }
            }
            let number = text.prefix { $0.isNumber }
            guard let value = Int(number), text.dropFirst(number.count).hasPrefix(". ") else { continue }
            // Numbers count up from 1; anything else is past the picker.
            guard value == labels.count + 1 else { break }
            var label = String(text.dropFirst(number.count + 2)).trimmingCharacters(in: .whitespaces)
            // Key hints like "(shift+tab)" mean nothing on another device.
            if let hint = label.range(of: #"\s*\((shift|ctrl|alt|cmd|opt|option)\+[^)]*\)$"#, options: .regularExpression) {
                label.removeSubrange(hint)
            }
            labels.append(label)
        }
        guard hasCursor, labels.count >= 2 else { return nil }
        let typesWords = labels.last?.lowercased().hasPrefix("type here") == true
        if typesWords { labels.removeLast() }
        return CompanionQuestion(question: CompanionQuestion.planApprovalText,
                                 options: labels.map { .init(label: $0) },
                                 allowsOther: typesWords)
    }

    /// The keys that answer Claude's picker. A number picks an option (or
    /// ticks one, where several are allowed), Right moves on from a
    /// multiple-choice question, and the last Return confirms the review
    /// screen that several questions get. Writing your own answer picks
    /// "Type something" and types it.
    ///
    /// A question with previews is laid out side by side, where a number
    /// only moves to an option and Return picks it. There's no "Type
    /// something" there: N opens notes on the option instead, and Return
    /// from the notes picks the option with them.
    public func answerSteps(questions: [CompanionQuestion], answers: [CompanionAnswer]) -> Result<[AnswerStep], AnswerProblem> {
        guard answers.count == questions.count else { return .failure(.init(message: "Those answers don't match Claude's questions.")) }
        var steps: [AnswerStep] = []
        for (question, answer) in zip(questions, answers) {
            let valid = answer.selected.allSatisfy { question.options.indices.contains($0) }
            guard valid, answer.other != nil || !answer.selected.isEmpty else { return .failure(.init(message: "Answer every question first.")) }
            if question.hasPreviews {
                // A phone that doesn't know about previews sends its notes as
                // your own answer, alongside the option.
                guard answer.selected.count == 1 else {
                    return .failure(.init(message: "Pick one of the options for that question. You can add a note to it."))
                }
                steps.append(.key(.digit(answer.selected[0] + 1)))
                let note = (answer.note ?? answer.other)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !note.isEmpty { steps += [.key(.notes), .text(note)] }
                steps.append(.key(.returnKey))
                continue
            }
            if answer.other != nil, question.multiSelect { return .failure(.init(message: "Pick from the options for that question.")) }
            if let other = answer.other {
                steps += [.key(.digit(question.options.count + 1)), .text(other), .key(.returnKey)]
            } else if question.multiSelect {
                steps += answer.selected.map { .key(.digit($0 + 1)) } + [.key(.rightArrow)]
            } else {
                steps.append(.key(.digit(answer.selected[0] + 1)))
            }
        }
        // With several questions, the picker ends on "Submit answers".
        if questions.count > 1 { steps.append(.key(.returnKey)) }
        return .success(steps)
    }
}
