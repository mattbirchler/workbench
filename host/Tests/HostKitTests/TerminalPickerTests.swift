import BenchKit
import XCTest
@testable import HostKit

final class TerminalPickerTests: XCTestCase {
    /// What Claude Code 2.1 shows on a machine whose default mode is accept edits.
    private let autoMode = """
         ▐▛███▛█   Claude Code v2.1.332
        ▝▜██████▀  Fable 5.2 · Claude Ultra
         ▝▝   ▝▝   ~/code/website
        ────────────────────────────────────────────────────────────
          Make auto mode your default permission mode?
          Auto mode lets Claude handle permission prompts automatically. Claude checks each tool call for risky actions and
          prompt injection before executing, runs the ones it assesses as lower-risk, and blocks the rest.
          ❯ Yes, set auto mode as my default permission mode
            No, keep accept edits
          Not answered yet · ↑/↓ to choose · Esc to cancel

        """

    func testReadsThePickerOffTheScreen() throws {
        let prompt = try XCTUnwrap(TerminalPicker.prompt(in: autoMode))
        XCTAssertEqual(prompt.question.question, "Make auto mode your default permission mode?")
        XCTAssertEqual(prompt.question.options.map(\.label), ["Yes, set auto mode as my default permission mode", "No, keep accept edits"])
        XCTAssertEqual(prompt.question.options[0].description?.hasPrefix("Auto mode lets Claude"), true)
        // The cursor is on the first, so the second is one Down away.
        XCTAssertEqual(prompt.answers.map(\.moves), [[], [.downArrow]])
        XCTAssertEqual(prompt.answers[1].picked, "No, keep accept edits")
    }

    /// The hints only appear once a key has been pressed.
    func testWorksBeforeTheHintsAppear() throws {
        let screen = autoMode.components(separatedBy: "\n").filter { !$0.contains("Not answered yet") }.joined(separator: "\n")
        XCTAssertEqual(try XCTUnwrap(TerminalPicker.prompt(in: screen)).question.options.count, 2)
    }

    func testFindsTheQuestionAcrossABlankLine() throws {
        let screen = autoMode.replacingOccurrences(of: "  ❯ Yes", with: "\n  ❯ Yes")
            .replacingOccurrences(of: "  Auto mode lets", with: "\n  Auto mode lets")
        let prompt = try XCTUnwrap(TerminalPicker.prompt(in: screen))
        XCTAssertEqual(prompt.question.question, "Make auto mode your default permission mode?")
        XCTAssertEqual(prompt.question.options.count, 2)
    }

    func testMovesUpWhenTheCursorIsBelow() throws {
        let screen = """
              Pick one
                First
                Second
              ❯ Third
              Enter to confirm · Esc to cancel
            """
        let prompt = try XCTUnwrap(TerminalPicker.prompt(in: screen))
        XCTAssertEqual(prompt.answers.map(\.moves), [[.upArrow, .upArrow], [.upArrow], []])
    }

    func testAnOrdinaryScreenIsNotAPicker() {
        let idle = """
            ────────────────────────────────
            ❯ Try "how does <filepath> work?"
            ────────────────────────────────
              ◆ Haiku 5.5 ▏ proj2 ⑂ main
              ⏵⏵ accept edits on (shift+tab to cycle)
            """
        XCTAssertNil(TerminalPicker.prompt(in: idle))
        XCTAssertNil(TerminalPicker.prompt(in: ""))
    }
}
