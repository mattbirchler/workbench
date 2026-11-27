import BenchKit
import Foundation
import Testing
@testable import Bench

/// Claude restarted by hand in a tab has none of Bench's hooks. The chat
/// can still follow its transcript, so it should still be able to reply.
struct ClaudeWithoutHooksTests {
    private let rule = String(repeating: "─", count: 40)

    private func screen(_ box: String) -> String {
        "Some output\n\(rule)\n\(box)\n\(rule)\n  ? for shortcuts"
    }

    @Test func findsClaudeInFrontOfItsTab() throws {
        let tab = UUID()
        let snapshot = TerminalSnapshot.parse("""
            100 ttys001 Ss   login -flp me /bin/zsh # bench-tab=\(tab.uuidString)
            101 ttys001 S    -zsh
            102 ttys001 S+   claude --continue
            """)
        #expect(snapshot.tabsWithClaudeInFront == [tab])
    }

    @Test func ignoresClaudeInTheBackgroundOrOneShot() {
        let tab = UUID()
        let snapshot = TerminalSnapshot.parse("""
            100 ttys001 Ss   login -flp me /bin/zsh # bench-tab=\(tab.uuidString)
            101 ttys001 S    claude
            102 ttys001 S+   claude -p hello
            """)
        #expect(snapshot.tabsWithClaudeInFront.isEmpty)
    }

    @Test func recognizesClaudeRunByNode() {
        #expect(TerminalSnapshot.isInteractiveClaude(["node", "/usr/local/bin/claude", "--continue"]))
        #expect(!TerminalSnapshot.isInteractiveClaude(["node", "/usr/local/bin/server"]))
    }

    @Test func canTypeAtTheMessageBox() {
        #expect(TerminalManager.canTypeWithoutHooks(claudeInFront: true, screen: screen("❯ "), driver: ClaudeTerminalDriver()))
    }

    @Test func wontTypeIntoAChoiceOrWithoutClaude() {
        #expect(!TerminalManager.canTypeWithoutHooks(claudeInFront: true, screen: screen("❯ 1. Yes\n  2. No"), driver: ClaudeTerminalDriver()))
        #expect(!TerminalManager.canTypeWithoutHooks(claudeInFront: true, screen: "Do you want to proceed?", driver: ClaudeTerminalDriver()))
        #expect(!TerminalManager.canTypeWithoutHooks(claudeInFront: false, screen: screen("❯ "), driver: ClaudeTerminalDriver()))
    }
}
