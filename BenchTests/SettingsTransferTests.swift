import BenchKit
import Foundation
import Testing
@testable import Bench

/// Settings > General > Move to Another Mac.
struct SettingsTransferTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsTransferTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "SettingsTransferTests-\(UUID().uuidString)")!
    }

    /// A Mac with a project, shortcuts, a paired Mac, and a few settings.
    private func oldMac() throws -> (support: URL, defaults: UserDefaults) {
        let support = try folder()
        let state = #"{"projects":[{"id":"A","path":"\/Users\/old\/Apps\/Thing"},{"id":"B","path":"\/Users\/old\/Gone"}]}"#
        try state.write(to: support.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        try #"[{"title":"Build"}]"#.write(to: support.appendingPathComponent("shortcuts.json"), atomically: true, encoding: .utf8)
        try #"[{"host":"mini","token":"secret"}]"#.write(to: support.appendingPathComponent("remote-macs.json"), atomically: true, encoding: .utf8)
        let defaults = defaults()
        defaults.set(true, forKey: "newClaudeTabsShowChat")
        defaults.set("claude --permission-mode plan", forKey: "claudeCommand")
        defaults.set("/Users/old/Worktrees", forKey: "worktreesFolder")
        defaults.set(1.25, forKey: "chatTextScale")
        defaults.set(30, forKey: "usage.days")
        defaults.set("not exported", forKey: "NSWindow Frame main")
        return (support, defaults)
    }

    private func export(_ sections: Set<SettingsTransfer.Section>, from mac: (support: URL, defaults: UserDefaults)) throws -> SettingsTransfer.Archive {
        let data = try SettingsTransfer.export(sections, support: mac.support, defaults: mac.defaults,
                                               home: "/Users/old", fromMac: "Old Mac", appVersion: "1.0 (1)")
        return try SettingsTransfer.read(data)
    }

    @Test func onlyTheChosenSectionsAreExported() throws {
        let archive = try export([.projects, .settings], from: try oldMac())
        #expect(Set(archive.sections.keys) == [.projects, .settings])
        #expect(archive.sections[.settings]?.preferences["claudeCommand"] == .string("claude --permission-mode plan"))
        #expect(archive.sections[.settings]?.preferences["newClaudeTabsShowChat"] == .bool(true))
        #expect(archive.sections[.settings]?.preferences["usage.days"] == .int(30))
        // Nothing outside the lists, like window sizes.
        #expect(archive.sections.values.allSatisfy { $0.preferences["NSWindow Frame main"] == nil })
    }

    @Test func pairedMacsAreLeftOutUnlessChosen() {
        #expect(!SettingsTransfer.Section.pairedMacs.isOnByDefault)
        #expect(SettingsTransfer.Section.allCases.filter(\.isOnByDefault).count == SettingsTransfer.Section.allCases.count - 1)
    }

    @Test func importPutsEverythingInPlaceAtTheNewHome() throws {
        let archive = try export(Set(SettingsTransfer.Section.allCases), from: try oldMac())
        let support = try folder()
        let defaults = defaults()
        defaults.set("dark", forKey: "appearanceMode")
        try SettingsTransfer.stage(archive, sections: Set(SettingsTransfer.Section.allCases), support: support)
        #expect(SettingsTransfer.hasPending(support: support))

        let applied = SettingsTransfer.applyPending(support: support, defaults: defaults, home: "/Users/new")
        #expect(applied?.count == SettingsTransfer.Section.allCases.count)
        #expect(!SettingsTransfer.hasPending(support: support))

        let state = try String(contentsOf: support.appendingPathComponent("state.json"), encoding: .utf8)
        #expect(state.contains(#"\/Users\/new\/Apps\/Thing"#))
        #expect(!state.contains("old"))
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("remote-macs.json").path))
        #expect(defaults.string(forKey: "claudeCommand") == "claude --permission-mode plan")
        #expect(defaults.string(forKey: "worktreesFolder") == "/Users/new/Worktrees")
        #expect(defaults.bool(forKey: "newClaudeTabsShowChat"))
        #expect(defaults.double(forKey: "chatTextScale") == 1.25)
        // Not set on the old Mac, so back to the default here.
        #expect(defaults.object(forKey: "appearanceMode") == nil)
    }

    @Test func sectionsNotChosenOnImportAreLeftAlone() throws {
        let archive = try export(Set(SettingsTransfer.Section.allCases), from: try oldMac())
        let support = try folder()
        try "mine".write(to: support.appendingPathComponent("shortcuts.json"), atomically: true, encoding: .utf8)
        let defaults = defaults()
        defaults.set("claude", forKey: "claudeCommand")
        try SettingsTransfer.stage(archive, sections: [.projects], support: support)
        SettingsTransfer.applyPending(support: support, defaults: defaults, home: "/Users/old")

        #expect(try String(contentsOf: support.appendingPathComponent("shortcuts.json"), encoding: .utf8) == "mine")
        #expect(defaults.string(forKey: "claudeCommand") == "claude")
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("remote-macs.json").path))
        #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("state.json").path))
    }

    @Test func whatGetsReplacedIsBackedUp() throws {
        let archive = try export([.projects], from: try oldMac())
        let support = try folder()
        try "previous".write(to: support.appendingPathComponent("state.json"), atomically: true, encoding: .utf8)
        try SettingsTransfer.stage(archive, sections: [.projects], support: support)
        SettingsTransfer.applyPending(support: support, defaults: defaults(), home: "/Users/old")

        let backups = try FileManager.default.contentsOfDirectory(at: support.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 1)
        #expect(try String(contentsOf: backups[0].appendingPathComponent("state.json"), encoding: .utf8) == "previous")
    }

    @Test func missingProjectFoldersAreCounted() throws {
        let archive = try export([.projects], from: try oldMac())
        let found = SettingsTransfer.missingProjectFolders(in: archive, home: "/Users/new") { $0 == "/Users/new/Apps/Thing" }
        #expect(found.missing == 1)
        #expect(found.total == 2)
    }

    @Test func otherFilesAreRejected() {
        #expect(throws: SettingsTransfer.TransferError.self) { try SettingsTransfer.read(Data(#"{"projects":[]}"#.utf8)) }
        let newer = #"{"format":"workbench-settings","version":99,"exportedAt":"2026-11-09T00:00:00Z","appVersion":"9","fromMac":"x","home":"/Users/x","sections":{}}"#
        #expect(throws: SettingsTransfer.TransferError.self) { try SettingsTransfer.read(Data(newer.utf8)) }
    }

    @Test func homeRewritesOnlyWholeFolders() {
        #expect(SettingsTransfer.rewriteHome("/Users/matt/Apps", from: "/Users/matt", to: "/Users/m") == "/Users/m/Apps")
        #expect(SettingsTransfer.rewriteHome("/Users/matthew/Apps", from: "/Users/matt", to: "/Users/m") == "/Users/matthew/Apps")
        #expect(SettingsTransfer.rewriteHome("/Users/matt", from: "/Users/matt", to: "/Users/m") == "/Users/m")
    }

    /// The lists name settings by their keys. These are the app's own names
    /// for them, so a renamed key fails here instead of quietly not moving.
    @MainActor @Test func theListsUseTheAppsKeys() {
        let all = Set(SettingsTransfer.Section.allCases.flatMap(\.preferenceKeys))
        let appKeys: [String] = [
            SidebarGrouping.key, SidebarLayout.key,
            AppAppearance.key, AppIconManager.key, FocusRingColor.key, MotionLevel.key,
            Chime.enabledKey, Chime.Kind.finished.key, Chime.Kind.needsYou.key,
            TerminalTheme.sourceKey, TerminalTheme.lightThemeKey, TerminalTheme.darkThemeKey, TerminalTheme.matchKey,
            ChatTypography.textFontKey, ChatTypography.codeFontKey, ChatTypography.scaleKey,
            AppStore.newTabsShowChatKey, Agents.claude.commandKey, Recaps.enabledKey, SessionKeeper.enabledKey,
            TerminalManager.resumesAtLaunchKey, WorktreeCleaner.autoCleanKey, Worktrees.chosenFolderKey, Editors.chosenKey,
            Updater.installsWhenIdleKey, PlanUsageMonitor.budgetKey, PlanUsageMonitor.shownKey, PlanUsageMonitor.paceKey,
            MacActivity.shownKey, SimulatorWatch.shownKey, Analytics.optedOutKey,
            Dictation.enabledKey, Dictation.keyKey, Dictation.fixesTermsKey,
        ]
        for key in appKeys { #expect(all.contains(key), "\(key) isn't in any section") }
    }
}
