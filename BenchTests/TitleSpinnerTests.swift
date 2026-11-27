import BenchKit
import Testing
@testable import Bench

/// Claude Code animates its terminal title while it works. A title Bench
/// doesn't recognize as Claude's reads as Claude having left the terminal,
/// which ends the turn and drops any question it's asking from the chat.
struct TitleSpinnerTests {
    private func spins(_ title: String) -> Bool {
        title.unicodeScalars.first.map(ClaudeTerminalDriver().isWorkingMark) ?? false
    }

    @Test func olderBrailleSpinnerCounts() {
        #expect(spins("⠋ Fixing the build"))
        #expect(spins("⣿ Fixing the build"))
    }

    @Test func newerHalfCircleSpinnerCounts() {
        #expect(spins("◐ Tea or coffee preference"))
        #expect(spins("◑ Tea or coffee preference"))
    }

    @Test func idleTitlesAndShellTitlesDont() {
        #expect(!spins("✳ Tea or coffee preference"))
        #expect(!spins("matt@mac: ~/Apps"))
        #expect(!spins(""))
    }
}
