import AppKit
import Testing
@testable import Bench

/// The ⌘ hints stay up through the shortcuts they're for, and only those.
struct SidebarShortcutHintTests {
    @Test func commandDigitsKeepTheHints() {
        for digit in 1...9 {
            #expect(SidebarShortcuts.keepsHints(characters: "\(digit)", modifiers: .command))
        }
        #expect(SidebarShortcuts.keepsHints(characters: "4", modifiers: [.command, .numericPad]))
    }

    @Test func otherKeysHideThem() {
        #expect(!SidebarShortcuts.keepsHints(characters: "0", modifiers: .command))
        #expect(!SidebarShortcuts.keepsHints(characters: "t", modifiers: .command))
        #expect(!SidebarShortcuts.keepsHints(characters: "4", modifiers: [.command, .shift]))
        #expect(!SidebarShortcuts.keepsHints(characters: "4", modifiers: [.command, .option]))
        #expect(!SidebarShortcuts.keepsHints(characters: "4", modifiers: []))
        #expect(!SidebarShortcuts.keepsHints(characters: "12", modifiers: .command))
        #expect(!SidebarShortcuts.keepsHints(characters: nil, modifiers: .command))
    }
}
