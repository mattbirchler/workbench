import BenchKit
import Foundation

/// A choice Claude Code asks for in its terminal that no hook reports, like
/// "Make auto mode your default permission mode?" on a new machine. With
/// no window to answer it in, the session would sit there. This reads the
/// picker off the screen so the apps can show it as a question.
enum TerminalPicker {
    /// The picker at the bottom of a screen, or nil if there isn't one.
    static func prompt(in screen: String) -> StartupPrompt? {
        var lines = screen.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        // A picker is the last thing on the screen, sometimes with a line
        // of key hints under it (Claude Code adds it after a key press).
        if let last = lines.last, isHints(last) { lines.removeLast() }
        // The lines above that, up to a blank line or a rule.
        var block: [String] = []
        var index = lines.count - 1
        while index >= 0, lines[index].trimmingCharacters(in: .whitespaces).isEmpty { index -= 1 }
        while index >= 0 {
            let text = lines[index].trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text.allSatisfy({ $0 == "─" }) { break }
            block.insert(lines[index], at: 0)
            index -= 1
        }
        guard let cursorLine = block.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("❯ ") }),
              let cursorColumn = column(of: "❯", in: block[cursorLine]) else { return nil }
        // Options line up with the words after the cursor.
        let textColumn = cursorColumn + 2
        func option(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("❯ ") { return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
            return line.prefix { $0 == " " }.count == textColumn && !trimmed.isEmpty ? trimmed : nil
        }
        var first = cursorLine, last = cursorLine
        while first > 0, option(block[first - 1]) != nil { first -= 1 }
        while last + 1 < block.count, option(block[last + 1]) != nil { last += 1 }
        let labels = (first...last).compactMap { option(block[$0]) }
        // Nothing may follow the options: a status line under them means
        // this is Claude's message box, not a picker.
        guard last == block.count - 1, labels.count >= 2, labels.count <= 8 else { return nil }
        var heading = block[..<first].map { $0.trimmingCharacters(in: .whitespaces) }
        if heading.isEmpty {
            // The question is often a paragraph of its own above the options.
            // Take the paragraphs back to the rule that starts the picker.
            while index >= 0, heading.count < 10 {
                let text = lines[index].trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, text.allSatisfy({ $0 == "─" }) { break }
                if !text.isEmpty { heading.insert(text, at: 0) }
                index -= 1
            }
            // No rule above: it wasn't a picker's own heading.
            if index < 0 { heading = [] }
        }
        let question = heading.first ?? "Claude Code is asking something in its terminal."
        let detail = heading.dropFirst().joined(separator: " ")
        let cursor = cursorLine - first
        let answers = labels.indices.map { choice -> StartupPrompt.Answer in
            let moves = Array(repeating: choice > cursor ? AgentKey.downArrow : .upArrow, count: abs(choice - cursor))
            return .init(moves: moves, picked: labels[choice])
        }
        return StartupPrompt(
            question: CompanionQuestion(
                question: question,
                options: labels.enumerated().map { .init(label: $1, description: $0 == 0 && !detail.isEmpty ? detail : nil) },
                allowsOther: false),
            blocker: "is asking a question in its terminal",
            answers: answers)
    }

    private static func isHints(_ line: String) -> Bool {
        line.contains("Esc to cancel") || line.contains("to choose") || line.contains("Enter to confirm")
    }

    private static func column(of mark: Character, in line: String) -> Int? {
        line.firstIndex(of: mark).map { line.distance(from: line.startIndex, to: $0) }
    }
}
